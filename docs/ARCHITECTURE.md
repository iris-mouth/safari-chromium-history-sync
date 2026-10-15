# Architecture

## Modules and interfaces

The system exposes three behavior-level interfaces:

- `browserExchange(message) -> receipt | page | typedError`
- `selectProfile(profileId) -> switchStatus`
- `status() -> healthSnapshot`

The extension implementation is in `extension/sync_controller.js`; the FDA implementation is `AgentService`. Both use protocol version 1 and bounded pages of at most 128 events. Tests exercise the extension through these interfaces rather than its internal queue representation.

The deep modules are:

1. **Browser StateCoordinator** — a single-writer promise chain over immutable copy-on-write generations in `chrome.storage.local`.
2. **Safari history adapter** — structural compatibility validation, arrival cursors, crash reconciliation, and `BEGIN IMMEDIATE` inserts.
3. **Agent service** — atomic active-profile selection, Safari arrival stream, profile-scoped encrypted outbox, and recovery ledger.
4. **Local IPC adapter** — Native Messaging framing at the browser boundary and authenticated Unix-socket framing at the FDA boundary.
5. **Setup coordinator** — browser opt-in, product-owned Native Messaging manifests, login-item state, Agent launch, and focused diagnostics; it runs in the no-FDA Menu process.

## Processes and trust

```text
Chrome/Edge extension
        │ Native Messaging (JSON, ≤1 MiB)
        ▼
SafariSyncBridge — no FDA
        │ role + nonce + HMAC, Unix socket 0600
        ▼
Safari Chromium History Sync Agent.app sibling process — FDA only
        │ structural schema adapter
        ▼
Safari History.db ── Safari CloudHistory ── iPhone Safari

SafariSyncMenu — no FDA ── authenticated menu role ──┘
```

The Menu app is the registered login item. On launch it starts the sibling Agent app; keeping the Agent as a top-level bundle ensures macOS TCC attributes Safari database access to the Agent identifier rather than to the outer Menu app.

The Bridge cannot open Safari's database directly, but it relays bounded Safari history pages to the selected Extension. The Menu cannot use browser transport. The Agent accepts only `bridge` and `menu` roles with valid HMACs and rejects replayed nonces. The HMAC key is stored in an owner-only mode-`0600` file so separately signed local-development executables do not trigger Keychain authorization prompts. This authenticates messages against accidental or cross-user callers, not against arbitrary code already executing as the current user, which can read the key. Only the Agent reads the Keychain root secret used for the AES-GCM sealed state document. Delivery idempotency is kept in a separate Agent-owned SQLite ledger rather than adding tables to Safari's database.

The threat boundary assumes the current macOS account is not already compromised. The system does defend the FDA boundary, validates untrusted browser input, separates profiles, and fails closed before unknown Safari layouts are written. It deliberately does not add XPC identity infrastructure or privileged installer helpers. The Extension's fixed manifest key stabilizes the unpacked extension ID for `allowed_origins`; it is identification, not code-signing or a trust guarantee.

## Streams

Each direction is a durable monotonic stream with random source event IDs:

- `browserToSafari`: browser resolver → Agent insert receipt.
- `safariToBrowser`: Safari arrival cursor → browser evidence receipt.

Pages and receipts are bounded and cumulative. The active browser applies at most one Safari event at a time, preventing a later evidence result from cumulatively acknowledging an earlier unresolved event.

No historical backfill occurs. The first Safari scan establishes an authenticated maximum-visit baseline. Browser history is observed only after `onVisited`. A DB identity change, missing anchor, or row-HMAC mismatch fails closed.

## Browser delivery evidence

`chrome.history.addUrl` means request acceptance, not successful history creation. Before any retry, the extension performs a fresh `getVisits` outcome query. Evidence checks are durably scheduled for cumulative `+1,+3,+8,+18,+30` seconds and examine the deterministic recent 64 visits (`visitTime DESC, visitId DESC`). Worker restart resumes overdue checks from persisted state.

While delivery evidence is pending, the same URL is excluded from browser-to-Safari resolution. Once confirmed, the exact imported Chromium visit ID becomes the URL's marker. Its `onVisited` callback is therefore consumed as an echo, while any genuinely newer browser visit remains outbound.

After two unconfirmed delivery requests the browser reports `FINALIZED_UNCONFIRMED`. The Agent removes the event from the live delivery stream and retains it in the encrypted, profile-scoped recovery ledger. Retry delays are 5 minutes, 15 minutes, 30 minutes, 2 hours, then 6 hours, with 20 automatic retries maximum. Exhaustion remains visible in status; it is never treated as success.

## Safari insertion and iCloud trigger

The Agent checks the minimum OS requirements and then the live database structure and generation values. Version/build identifiers and the optional history-service hash identify end-to-end test evidence; they are not an allowlist. Eligible unknown environments run as `compatibleUnverified`. A `tested` label requires an exact recorded environment for the revised release. Diagnostic labels are attached only after database checks pass.

The schema adapter compares SQLite column, foreign-key, unique-index, and table metadata. It ignores DDL formatting, column order, and index names that do not change semantics, while rejecting unmodeled constraints and triggers. Generation values must be present, nonnegative integers within range. See [COMPATIBILITY.md](COMPATIBILITY.md) for the contract and remaining uncertainty.

The adapter checks the selected schema on history operations. Each new insert:

1. records an Agent-owned `APPLYING` intent;
2. opens `History.db` with a busy timeout;
3. starts `BEGIN IMMEDIATE` and validates the schema while holding the write transaction;
4. reconciles an existing exact URL/delivery-time visit after a crash;
5. inserts with `origin=0` and generation `max(current,last_synced)+1`;
6. updates `current_generation`, never `last_synced_generation`;
7. commits, then marks the intent applied.

The cloud coordinator polls every 15 seconds, coalesces newly recorded own deliveries for 15 seconds, and reads a consistent snapshot of their exact URL/visit-time/generation rows. Matching records are compared to `last_synced_generation`; missing/changed rows or a DB identity mismatch suppress further automatic prompting. Unrelated global generations do not create launch work.

Due own records can use `open -gj -a Safari` only while Safari is stopped. One launch covers a batch. Build 612 shares a durable retry schedule with opted-in navigations: 5/10/20/40/60 minutes without native progress, then hourly while eligible records remain; there is no daily stop. The reservation is persisted before acting. Pending automatic work is observed at most 60 seconds apart; otherwise native observation retains its 30/60/90/300/900/1800/7200/21600-second backoff. An action deadline can advance an old observation deadline, including after migration, without bypassing exact-row checks. A launch result is not an upload receipt. A running Safari is never quit or recycled. Historical hidden-launch evidence does not qualify every current release failure mode.

## Account delivery evidence and repairs

`CloudDeliveryCoordinator` lives inside encrypted schema-3 Agent state. Provisional obligations precede Safari writes; local receipts precede stream ACKs. Restart reconciliation uses the existing insertion ledger's original delivery timestamp, preserving echo suppression without duplicating Safari inserts. Browser intents precede `addUrl`, and exact visit ID/time receipts and markers precede ACK transmission. Cumulative local ACKs require evidence for every covered tracked event; persisted per-profile ACK sequences also make lost-response retries safe after journal expiry.

Protocol 1 negotiates optional `cloud-delivery-v1` capabilities and local receipts. Older untracked streams still use local ACKs; a tracked stream requires the updated extension. Payloads are bounded by both event count and bytes, leaving room for authenticated framing. Incoming account-synced visits are not accepted as evidence of the extension's local insertion when `isLocal` is available.

Safari checkpoint coverage, public-browser delivery not observable, and user-reported receiver Seen/Not Observed are independent observations. Snapshot comparison confirms only unique exact URL/latest-time matches. The Menu parses up to 32 MiB of a receiver export locally, filters owned URLs, deduplicates latest times before dividing it into at most 256 KiB snapshots, and never forwards unrelated receiver history. Absent entries do not establish cloud absence. Diagnostics page at most 32 records per response.

Authenticated Menu commands can create unique per-route probes, record receiver evidence, compare receiver snapshots, prepare/execute a single-event replay, or record an account rebind. Prepared plans expire after five minutes and bind the profile/account epoch. A durable repair-attempt ID prevents repeated plan execution from creating multiple replacements. Safari rows are rechecked before planning/execution. Replay through the regular writer creates a new destination-time visit; it does not requeue an existing native record or claim cloud arrival.

Explicit browser removals cancel matching owned queued/recovery work and suppress replay, scoped to the notification time. Later genuine source visits and explicit attempts remain independent. Previously confirmed missing/changed Safari rows are suppressed rather than recreated. Account epochs are user-declared; public interfaces do not establish automatic account identity or HISTORY readiness. Rebinding freezes previous evidence and cancels pending probes/replays for the old binding without editing history or settings.

The journal retains detailed applied records for seven days and bounds entries at 4096. Expiry increments an unverified count. Live unapplied intents are not expired; cancelled or suppressed intents expire after the retention window; a full journal backpressures writes with `CLOUD_JOURNAL_FULL` and exposes capacity status. Typed cloud errors do not masquerade as corrupted encrypted state. The unresolved sidecar includes unverified cloud obligations as well as live relay work.

## Profile switching

The Agent persists exactly one active profile. Selecting another connected profile changes that value atomically; there is no staging profile or freeze handshake. Browser outbox, Agent recovery entries, and delivery progress remain keyed by their originating profile. Pending work is not transferred during a switch and resumes only if that profile becomes active again. The global Safari arrival cursor continues from its current point, so newly observed Safari visits belong to the profile active when they are discovered.

The Agent learns candidate profile IDs from ordinary authenticated Extension traffic before touching Safari data. A single connected candidate is selected automatically when no active profile exists; multiple candidates require a Menu choice. Candidate presence is ephemeral and rebuilt after Agent restart, while the active profile remains in sealed state.

## Setup and distribution

The Menu app owns setup because it does not have Full Disk Access. The user explicitly selects Chrome Stable, Edge Stable, or both. The coordinator creates or repairs a Native Messaging manifest only for selected browsers and removes only product-owned matching manifests when a browser is deselected. It never creates a Native Messaging directory for an unselected browser.

The Agent recognizes separate blocked issue codes for an unsupported runtime, Safari database identity change, invalid Safari arrival anchor, unavailable Safari access, unavailable Keychain access, and unreadable sealed state. Only authenticated `menu` requests can invoke recovery, and only while the matching issue is blocked:

- `resetSafariCursor` is limited to identity or anchor failures. It establishes the current Safari baseline while preserving the active profile, outbox, recovery entries, and delivery ledger.
- `resetAgentState` is limited to unreadable sealed state. It removes only `state.sealed` and its unresolved-count sidecar, warns that pending work can be lost, and establishes the current Safari baseline. Safari and Chromium history and the delivery ledger remain untouched. It is never exposed for a Keychain failure.

There is no generic repair command.

The Extension is bundled as an unpacked-development artifact inside the Menu app. Setup opens the selected browser's extensions page and reveals that folder; browser approval and macOS privacy approval remain user actions. The ad-hoc-signed app bundles and unsigned local PKG are payload-only and install the Menu and Agent as sibling app bundles under `/Applications`. User-specific manifests and login-item state are created on first launch, never by privileged installer scripts. Store distribution, Developer ID signing, and notarization are not implemented.

## Migration and rollback

Version 6 must not run concurrently with the legacy Python writer. Setup detects the legacy host or writer and blocks synchronization until the user removes it; it does not silently delete legacy state. Rollback is an explicit operator procedure: quit the Menu app, stop the Agent, disable the Menu app under Open at Login, remove only product-owned `io.github.irismouth.safari_chromium_history_sync` manifests, then install the prior version. It does not rewrite Safari history or silently remove encrypted pending data.

## Safari Sync Assist (build 612)

The sealed cloud coordinator contains optional opt-in assist state. Schema-3 states without it keep navigation off; build-611 states retain their existing opt-in and control URL. Only freshly validated owned Safari rows still below the checkpoint and without receiver confirmation can reserve a navigation after 90 seconds. Reservations are saved before external work. Consecutive attempts without checkpoint progress back off through 5/10/20/40/60 minutes and then remain hourly, with no daily ceiling. Launches and navigations share this schedule. Native checkpoint progress, or a fully resolved backlog followed by new work, resets the backoff but never the five-minute floor. New arrivals during an unresolved stall do not reset it. A successful Apple event does not reset it either. The schedule survives crashes and toggles. Legacy launch/assist cooldowns migrate; exhausted daily counters are retired automatically. A denied Automation permission disables navigation without repeating prompts.

The Agent runs Safari’s standard Apple events on its main thread, outside the service lock. It reuses a tab whose URL exactly equals either its generated UUID control URL or that URL plus `&safari-sync-refresh=1`, and navigates to the other variant. This performs a normal cross-URL navigation without a blank-tab ownership gap. If neither exists it creates a dedicated document and hides only its new window. It never restarts Safari, changes arbitrary tab URLs, runs page JavaScript, or writes sync acknowledgements. Slow/failed events are recorded separately from progress. Both owned helper URLs are excluded while harvesting Safari visits so they cannot echo through Edge/Chrome and create their own work. Normal Safari throttling and receiver checks remain authoritative boundaries.
