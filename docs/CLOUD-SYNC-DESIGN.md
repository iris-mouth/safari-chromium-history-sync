> Update 2026-10-15: build 610 Safari and Edge mobile probes were confirmed by the user. Build 611 implements opt-in ordinary Safari navigation using a dedicated helper tab; its mobile recheck was user-confirmed after manual navigation. Build 612 replaces daily ceilings with shared, durable 5/10/20/40/60-minute launch/navigation retries that continue hourly while eligible work remains. It alternates two owned control URLs in one tab and excludes both from relay. This supersedes the initial active-Safari deferral and illustrative daily cap below; no private force-upload API is used. See [ARCHITECTURE.md](ARCHITECTURE.md) and the [build-612 validation record](validation/build-612-assist-retry.md).

# Proposal: coordinating native account history sync

Date: 2026-10-03 (Asia/Tokyo). Original design baseline: `8648317499ddfe65358aaa04e83eb628d54b80be`.

Implementation update, 2026-10-11: development build 610 implements the encrypted journal, exact local receipts, owned-row Safari scheduling/monitoring, paged diagnostics, mobile user-reported arrival checks, owned-URL Safari export comparison, scoped replay plans, removal suppression, and account rebinds. See [ARCHITECTURE.md](ARCHITECTURE.md) for actual protocol, limits, and recovery behavior. Automated verification uses copied DBs and a mocked extension runtime; live account/iPhone qualification remains outstanding. Active-Safari force-upload, a read-only Chromium sync-metadata inspector, and an automatic desktop receiver observer remain unsupported future capabilities. Source visits remain identified by the existing resolver/cursor and stable logical event ID; the journal stores destination identity/time rather than claiming to reproduce all source metadata.

The aim is to improve delivery of relay-added visits through Safari/iCloud and Chrome/Google or Edge/Microsoft native synchronization, identify where progress stops, and offer a bounded repair. The user can confirm arrival on iPhone/iPad. The first implementation must work without an automatic second-Mac observer.

The evidence and primary-source links are in [cloud-history-sync-evidence.md](research/cloud-history-sync-evidence.md). Existing behavior remains documented in [ARCHITECTURE.md](ARCHITECTURE.md).

## Product contract

Monitor visits created by this relay after the feature is enabled, with exactly one active Chromium profile. Preserve the existing history-only, new-visit URL-signal contract. A signal can create a visit at the destination's delivery time; the product does not reproduce a complete source history database.

Account delivery is a separate obligation from local delivery. A local acknowledgement releases the existing stream for throughput while a cloud-delivery journal retains the event and its evidence. A missing remote observation does not cause repeated local insertion.

The initial implementation automatically detects observable local/native backlog and stalls. With iPhone/iPad as the receiving devices, arrival checks use explicit user observation and, where available, user-exported snapshots. It does not promise continuous, exhaustive comparison against a provider's authoritative account-history database. That would require a separately qualified account-side reader; an automatic second-device reader would instead prove receiving-device arrival.

## Evidence model

Store evidence as independent observations. Do not implement a single success boolean or require every provider to pass through identical states.

| Observation | Meaning | Does not establish |
| --- | --- | --- |
| `LOCAL_APPLIED` | Exact destination visit was observed | Native sync selected it |
| `NATIVE_ENQUEUED` | A qualified inspector observed this event registered with native sync | Server accepted it |
| `NATIVE_CHECKPOINT_COVERED` | Safari's checkpoint advanced past the event's generation | That particular visit exists on iCloud/iPhone |
| `NATIVE_COMMIT_ACK_OBSERVED` | A qualified adapter observed an event-correlated browser/server acknowledgement | Current receiving-device presence or permanent retention |
| `REMOTE_SEEN` | This event/probe was observed on a bound receiver, with provenance | All other events arrived |
| `REMOTE_NOT_OBSERVED` | The checked view/snapshot did not contain a match | The cloud record is absent |

`UNKNOWN`, `NOT_OBSERVABLE`, `SYNC_DISABLED`, `SYNC_PAUSED`, `EXCLUDED`, `POSSIBLE_STALL`, `SUPPRESSED`, and `EXPIRED_UNVERIFIED` are conditions, not delivery receipts. Missing observations remain unknown. A reported queue length without event correlation is aggregate diagnostic evidence.

Chrome's public extension interface establishes local insertion, not native enqueueing or commit acknowledgement. `is_known_to_sync` can support enqueue evidence under a qualified internal schema but is never an upload receipt. Safari's global generation checkpoint is likewise weaker than a per-event cloud acknowledgement. Start with the observations that can actually be obtained; leave the rest unsupported.

## Durable journal

Add a `CloudDeliveryCoordinator` module to the Agent. Its small interface is:

```text
recordLocalDelivery(receipt) -> recorded
reconcile(now, observations) -> health + repairPlans
executeRepair(planID) -> attemptReceipt | typedError
```

The implementation owns scheduling, evidence retention, attempt limits, profile/account scoping, and provider-specific policy. Safari and Chromium adapters form an internal seam because their capabilities genuinely differ. Each adapter reports capabilities and observation freshness; unsupported operations return a typed result rather than fabricating success.

Each journal entry retains:

- Logical source event ID, direction, source DB/profile epoch, and source visit key.
- Target browser/profile and a separate account-binding epoch. Profile identity alone is not account identity. Record a binding as unknown when it cannot be observed; a user-confirmed binding is not automatic identity verification.
- URL and source time when available, actual destination visit ID/time, and Safari generation when applicable.
- Local delivery time, provider capability identity, observations with scope/provenance, attempt history, next check, and repair suppression.

Keep URLs and operational state in the Agent's encrypted state storage, with bounded retention and derived keys. Store no account credentials. As an initial tunable budget, retain detailed comparison records for seven days with a fixed entry cap; archive only minimal counts/outcomes after expiry. Expiry becomes unverified, never successful. Capacity exhaustion pauses acquisition or reports incomplete coverage rather than silently dropping pending work. Native/account retention windows can be shorter and must further restrict the comparison range.

Use a write-ahead intent and idempotent reconciliation across existing delivery storage and the journal. There is no atomic transaction across Safari's DB and the Agent's encrypted document: after a crash, recover from the existing insertion ledger and reread local evidence. Persist browser destination evidence before sending its local receipt. A crash between local ACK and journal persistence must not lose the account-delivery obligation.

Extend the browser protocol with optional capability-negotiated local receipts containing destination visit ID/time. Preserve cumulative local ACK semantics. Bind receipts to authenticated traffic and the selected profile; old extensions report cloud tracking unavailable. Upgrades start a monitoring baseline and do not claim recovered cloud evidence for old acknowledged events.

## Safari scheduling

Replace the global five-minute launch check with scheduling driven by newly recorded Safari insertions and observed progress.

1. Coalesce new local deliveries for approximately 15 seconds. Recheck exact owned rows, DB identity, structural compatibility, Agent readiness, enabled state, and profile/account scope before acting.
2. When Safari is stopped, launch it once with the already qualified `open -gj -a Safari` route. Record launch acceptance/failure separately from sync progress.
3. Observe checkpoint/row state after approximately 30, 90, and 180 seconds. These are observation times, not promised upload deadlines.
4. Use a durable fallback schedule such as 5, 15, and 30 minutes, then 2 and 6 hours, with a daily cap. Sleep/offline periods do not count as proof of failure. A still-running Safari is not repeatedly relaunched as a supposed trigger.
5. Stop checking resolved/suppressed obligations; retain a low-frequency health check for remaining owned events. Unrelated Safari generation changes can be recorded as context but do not independently create work for this relay.

Continue leaving `last_synced_generation` entirely to Safari. Do not repair by lowering it, resetting native sync state, or claiming success after `open` exits.

### Safari already running

This is a feasibility task on the implementation's critical path. The current code skips it, and the reviewed public Safari interface does not provide a documented CloudHistory force-upload operation.

Investigate whether a legitimate native history-service insertion/notification path can both incorporate an external change into Safari's running state and schedule its normal save. Keep such knowledge inside a replaceable Safari adapter. Qualification must show that the specific injected row reaches iPhone/iPad while Safari stays running, without later browsing supplying the trigger. Repeat with batches, offline recovery, sleep/restart, and later genuine visits to the same URL. A responsive service, successful IPC call, or advanced checkpoint alone does not qualify this behavior.

If a dependable active-process route is unavailable, show that the row is locally applied and waiting for native activity. Offer a user-operated diagnostic or guidance to perform normal Safari browsing. Any diagnostic that opens a page must explain that it creates a real navigation/history entry. Automatic arbitrary page visits and restarting a user's active Safari are not the initial scheduling policy.

Adapter structure/state checks continue to determine eligibility. OS version/hash changes alone do not disable all compatible use. Record behavioral qualification separately, following the existing [compatibility policy](COMPATIBILITY.md).

## Chrome/Edge scheduling and inspection

Keep `chrome.history.addUrl` as the insertion path. It invokes the native history machinery; direct SQLite insertion would bypass the observer path needed by the inspected HISTORY bridge.

Handle two cases separately:

- **Registered while offline:** native sync can retain queued work; observe/retry progress without inserting another visit.
- **Added while history sync was disabled, paused, or not tracking:** resuming sync does not establish that the old event was queued. Keep its account-delivery outcome unconfirmed and offer a controlled repair after prerequisites are checked.

Check same-account binding, history selection, authentication/policy restrictions, and encryption limitations using capabilities that actually exist. Sign-in alone is insufficient evidence. Where public interfaces cannot report current transport readiness, mark it unknown and provide guided settings/diagnostics. Local relay delivery can continue; it must not acquire a false account-delivery label.

A later read-only `ChromiumSyncMetadataAdapter` can improve automatic diagnosis if the installed profile's DB structures, metadata encoding, storage-key mapping, and account/transport scope are independently qualified. It may report event registration and pending native metadata. Only a validated event-correlated acknowledgement can produce `NATIVE_COMMIT_ACK_OBSERVED`; absent metadata and `is_known_to_sync=true` cannot. This adapter writes neither Chromium history nor sync metadata. Public-extension-only operation remains available when the optional inspector is incompatible.

Use sync-internals as a version-sensitive support tool. A refresh/get-updates action is not proof of upload or a rescan of all unregistered visits. Do not build automatic repair around undocumented internal-page handlers. Edge's documented mobile Sync now can be a user-operated diagnostic step, followed by actual History inspection.

## Reconciliation with iPhone/iPad

Provide an explicit **Check arrival** action with a unique random diagnostic URL for each provider route. Add the probe through the same writer as real visits, record its local identity, and display the token and receiving browser to inspect. Instruct the user to search that browser's History without opening the probe first. Save the result as user-reported evidence with device, provider, binding epoch, token, and observation time.

A probe checks the route at that time. Real deliveries remain independently tracked. A later probe arriving does not automatically acknowledge earlier visits, especially those inserted during a Chromium sync pause.

For actual visits, show a bounded batch of owned URLs and their destination delivery times for manual comparison. Where supported, accept a user-shared Safari history export, validate the format and profile scope, and compare only the overlapping window. Safari exports can summarize the latest visit per URL: do not label repeated individual visits confirmed merely because a matching URL exists.

Matching uses destination time, exact provider URL serialization, receiver scope, and actual available precision. Avoid dropping query strings or equating redirects/domains. IDs are local to each browser/device; never join devices by numeric visit ID. Ambiguous repeated-URL matches stay ambiguous. Receiver snapshots record coverage, age, truncation, and format; incomplete snapshots cannot establish absence.

Do not use Google My Activity or Microsoft privacy dashboards as interchangeable account-sync databases without first proving their relationship to the exact data type and settings.

## Repair policy

| Condition | Default action |
| --- | --- |
| Original local request unconfirmed | Reread exact local evidence, then use existing bounded delivery retry |
| Own row present; native progress pending | Retry a qualified native nudge, without creating another visit |
| Sync prerequisites disabled/paused/excluded | Explain the specific prerequisite; keep work and offer guided correction |
| Checkpoint progressed; receiver not observed | Preserve uncertainty; refresh receiver/check binding and scope |
| Own previously confirmed row disappeared | Suppress automatic resurrection; classify deletion/expiry/identity change or unknown disappearance |
| User selects confirmed/intended missing URL signals for replay | Show a concrete repair plan and create one explicitly requested replacement attempt |

A repair plan lists provider/profile/binding, logical event IDs, affected URLs, observed evidence, expected changes, and expiry. Revalidate it immediately before execution. It is scoped to this relay's owned events, with a batch limit and duplicate/echo controls. Profile/account changes invalidate the plan.

Replaying with `addUrl` creates a new visit at the repair time. Expose that effect. Reusing the original event ID would only return the existing local idempotency receipt; use a repair-attempt ID linked to the same logical event and preserve previous receipts. Persist the intent before invoking the writer. An ambiguous result after a crash stays uncertain and is reread before another attempt.

Cloud non-observation alone does not authorize infinite replays. Preserve deletion suppression without implementing cross-browser deletion sync. Later genuine source visits remain new events and can be relayed normally. Internal generation/origin changes to an existing Safari row are a separate experimental repair method requiring behavioral qualification, not a default substitute for a native nudge.

## User-visible health

Report local delivery, observed native progress, and receiving-device evidence separately. Examples:

- “Safari added: 12. Waiting for Safari sync progress: 3.”
- “Chrome added: 8. Account delivery not observable from this interface.”
- “iPhone arrival check: probe confirmed at 10:42; other visits not yet checked.”
- “History sync was paused: 4 visits may need replay after settings are corrected.”

Unknown/unobservable is neutral; an observed stall or blocked prerequisite is actionable. Show the oldest actionable event, last observed progress, next check, and a focused Check arrival/Review repair action. A healthy local relay can coexist with unknown account delivery.

## Implementation order and acceptance

1. Add durable local receipts, the cloud journal, scoped health, and crash recovery. Replace the Safari timer with owned-event scheduling and bounded observation. This yields useful automatic backlog diagnosis.
2. Validate installed Chrome and Edge separately with mobile arrival probes. Run the active-Safari feasibility test before promising automatic prompting while it is running. Add optional qualified read-only Chromium inspection when it provides demonstrable evidence.
3. Add mobile confirmation/export comparison and concrete replay plans. Only then enable repair execution with account/profile epoch checks and recovery of uncertain attempts.
4. If continuous receiving-device comparison becomes necessary, add a separately bound read-only desktop observer. Its evidence proves receiver arrival; authoritative cloud-store comparison remains a different capability.

Meaningful verification covers local-ACK/journal crash points, one active profile, account rebind, repeated real visits/echo suppression, sleeping/offline Safari, active Safari without later navigation, Chromium pause versus offline registration, observed deletion, expired/incomplete snapshots, and replay interrupted before/after insertion. Live qualification records local application, native progress, and iPhone/iPad observation separately. No live account or browser-history changes were performed for this design request.
