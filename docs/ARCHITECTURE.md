# Architecture

## Modules and interfaces

The system exposes three behavior-level interfaces:

- `browserExchange(message) -> receipt | page | typedError`
- `selectProfile(profileId) -> switchStatus`
- `status() -> healthSnapshot`

The extension implementation is in `extension/sync_controller.js`; the FDA implementation is `AgentService`. Both use protocol version 1 and bounded pages of at most 128 events. Tests exercise the extension through these interfaces rather than its internal queue representation.

The deep modules are:

1. **Browser StateCoordinator** — a single-writer promise chain over immutable copy-on-write generations in `chrome.storage.local`.
2. **Safari history adapter** — exact-schema validation, arrival cursors, crash reconciliation, and `BEGIN IMMEDIATE` inserts.
3. **Agent service** — active-profile FSM, Safari arrival stream, encrypted outbox, and recovery ledger.
4. **Local IPC adapter** — Native Messaging framing at the browser boundary and authenticated Unix-socket framing at the FDA boundary.

## Processes and trust

```text
Chrome/Edge extension
        │ Native Messaging (JSON, ≤1 MiB)
        ▼
SafariSyncBridge — no FDA
        │ role + nonce + HMAC, Unix socket 0600
        ▼
SafariSyncAgent.app sibling process — FDA only
        │ exact schema adapter
        ▼
Safari History.db ── Safari CloudHistory ── iPhone Safari

SafariSyncMenu — no FDA ── authenticated menu role ──┘
```

The Menu app is the registered login item. On launch it starts the sibling Agent app; keeping the Agent as a top-level bundle ensures macOS TCC attributes Safari database access to the Agent identifier rather than to the outer Menu app.

The Bridge cannot read Safari data. The Menu cannot use browser transport. The Agent accepts only `bridge` and `menu` roles with valid HMACs and rejects replayed nonces. The HMAC key is stored in an owner-only mode-`0600` file so separately signed local-development executables do not trigger Keychain authorization prompts. Only the Agent reads the Keychain root secret used for the AES-GCM sealed state document. Delivery idempotency is kept in a separate Agent-owned SQLite ledger rather than adding tables to Safari's database.

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

The adapter validates the exact qualified schema before every session. Each insert:

1. records an Agent-owned `APPLYING` intent;
2. opens `History.db` with a busy timeout;
3. starts `BEGIN IMMEDIATE`;
4. reconciles an existing exact URL/delivery-time visit after a crash;
5. inserts with `origin=0` and generation `max(current,last_synced)+1`;
6. updates `current_generation`, never `last_synced_generation`;
7. commits, then marks the intent applied.

When `current_generation > last_synced_generation`, a timer aligned to UTC five-minute boundaries checks whether Safari is stopped. If so it uses `open -gj -a Safari`, the trigger proven in the qualification run. It never quits or recycles a user-owned Safari process.

## Profile switching

The Agent persists exactly one `ACTIVE` profile and at most one `STAGING` profile. Selecting a different profile enters `AWAITING_FREEZE_ACK`. The old extension first drains browser-to-Safari work, then receives `FREEZE_REQUIRED` on its pull and sends `freezeAck`. Only then is STAGING promoted. A staging or unrelated profile receives a typed retryable error.

## Migration and rollback

Version 6 must not run concurrently with the legacy Python writer. Installation order is: build and verify the app, pair extensions, stop the old writer, remove old manifests, establish current-point baselines, then enable the Agent. Rollback disables the Agent and removes only `com.local.safari_history_sync` manifests; it does not rewrite Safari history.
