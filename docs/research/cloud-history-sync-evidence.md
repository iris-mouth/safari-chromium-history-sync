# Native account history sync: evidence

Research date: 2026-10-03 (Asia/Tokyo). Local project baseline: `8648317499ddfe65358aaa04e83eb628d54b80be`. This is research, not a runtime qualification of the installed browsers.

## Chromium's current history path

The inspected upstream revision is [`d324ad7891122ca2777eedef10473eabd255a86b`](https://github.com/chromium/chromium/commit/d324ad7891122ca2777eedef10473eabd255a86b). The named source files were retrieved from Chromium's GitHub mirror through the GitHub API. Upstream evidence must not be presented as a test of Google Chrome Stable, Edge Stable, or either service's production server.

`HistoryAddUrlFunction::Run` passes the URL, the current time, and `SOURCE_EXTENSION` to `HistoryService::AddPage`. Its return does not wait for the history backend to finish. [history_api.cc, lines 350–364](https://github.com/chromium/chromium/blob/d324ad7891122ca2777eedef10473eabd255a86b/chrome/browser/extensions/api/history/history_api.cc#L350).

The three-argument `AddPage` overload constructs a LINK transition. This path does not add a FROM_API qualifier at this revision. The API therefore creates a new visit at delivery time; it does not reproduce the source browser's timestamp or typed navigation. [history_service.cc, lines 612–632](https://github.com/chromium/chromium/blob/d324ad7891122ca2777eedef10473eabd255a86b/components/history/core/browser/history_service.cc#L612).

`HistorySyncBridge::OnURLVisited` calls `MaybeCommit`. Committing requires a working sync metadata database, a transport that is neither disabled nor paused, and a processor tracking metadata. The visit must end a redirect chain, be locally originated, and convert successfully to sync data. `SOURCE_EXTENSION` is not excluded; `SOURCE_ACTOR` is. After processor `Put`, the bridge marks the included visits known to sync **before network delivery**. That flag is registration evidence, not an upload receipt. Incoming entries are also marked known to sync. Metadata for already synced entities can be cleared, so an absent metadata row is not independently an acknowledgement. [history_sync_bridge.cc](https://github.com/chromium/chromium/blob/d324ad7891122ca2777eedef10473eabd255a86b/components/history/core/browser/sync/history_sync_bridge.cc#L927).

`NonActorInitiatedVisitsAreSynced` explicitly includes `SOURCE_EXTENSION`. `DoesNotUploadIfSyncIsPausedAtStartup` shows that an event skipped during PAUSED does not enter the processor merely because sync later starts. These are upstream tests using a processor, not server E2E evidence. Offline delivery after a visit has entered the processor must be distinguished from an event never entering it. [history_sync_bridge_unittest.cc, paused test](https://github.com/chromium/chromium/blob/d324ad7891122ca2777eedef10473eabd255a86b/components/history/core/browser/sync/history_sync_bridge_unittest.cc#L923), [extension-source test](https://github.com/chromium/chromium/blob/d324ad7891122ca2777eedef10473eabd255a86b/components/history/core/browser/sync/history_sync_bridge_unittest.cc#L1948).

The HISTORY controller stops and clears this data type when encrypt-everything/custom passphrase is enabled. Transport-only support also depends on a feature setting. These prerequisites can change and require installed-build checks. [history_data_type_controller.cc](https://github.com/chromium/chromium/blob/d324ad7891122ca2777eedef10473eabd255a86b/components/history/core/browser/sync/history_data_type_controller.cc#L61).

The public history interface exposes history insertion/query/deletion and events. `VisitItem.isLocal` distinguishes locally originated and synchronized visits. This is useful for a future independently bound desktop observer, but it is not an upload acknowledgement on the writer. The documented interface has no account-sync trigger, account-history listing, or per-visit cloud receipt. This is a statement about the inspected interface, not proof that no private mechanism exists. [Chrome history reference](https://developer.chrome.com/docs/extensions/reference/api/history).

## iPhone/iPad observation

The user can check iPhone/iPad, and has not supplied a second Mac for an automatic observer.

Chrome's iOS help says its History view includes other-device pages when the user is signed in and syncing history. History is searchable and has a 90-day view; private, deleted, and internal browser pages are excluded. A missing item in that UI is therefore not an authoritative statement about every server record. [Chrome iPhone/iPad history help](https://support.google.com/chrome/answer/95589?co=GENIE.Platform%3DiOS&hl=en).

Chrome separately requires History and Tabs to be enabled for history synchronization. Its help also describes passphrase restrictions. Web & App Activity is a separate use of account history, so My Activity must not be assumed equivalent to the browser's sync store. [Chrome account/history settings](https://support.google.com/chrome/answer/165139?co=GENIE.Platform%3DiOS&hl=en).

Microsoft documents mobile account sync settings, selecting data items, a History view, and a user-operated Sync now action, including in the iOS section. This is a mobile UI operation; the FAQ does not establish a desktop extension interface or per-record delivery receipt. Validate current installed UI and history visibility before qualifying an Edge diagnostic. [Edge mobile FAQ](https://support.microsoft.com/en-us/microsoft-edge/microsoft-edge-for-mobile-faqs-29296eab-b76f-4a87-ac9c-9835da53465d).

Inspect a probe in the receiving browser's **History**, without opening the URL on that device. Opening it first creates a local visit and contaminates the observation. Positive observation confirms that particular probe's arrival through the tested route. It does not confirm every prior real visit or permanent server retention.

## Safari

Apple documents keeping Safari history up to date between devices using the same Apple Account and iCloud. This establishes the intended native route, not a third-party upload interface. [Safari on iPhone settings](https://support.apple.com/guide/iphone/customize-your-safari-settings-iphb3100d149/ios).

The reviewed public Safari application interface covers windows, tabs, extension messaging, and toolbar updates. It does not document a CloudHistory upload trigger or per-visit receipt. An extension message acknowledgement must not be treated as proof that history synchronization ran. [SFSafariApplication](https://developer.apple.com/documentation/safariservices/sfsafariapplication).

Apple documents user-operated Safari data exports on iOS/iPadOS/macOS, including profile-specific history files. The exported history schema describes the latest visit time for a history item, not a guaranteed lossless list of all visits. An export can support bounded URL/latest-visit comparisons where the installed device supports it; it cannot be assumed to equal the iCloud database. [Safari export format](https://developer.apple.com/documentation/safariservices/importing-data-exported-from-safari).

The project's writer already records destination visit IDs/generations in its separate delivery ledger, writes `origin=0`, advances `current_generation`, and leaves `last_synced_generation` to Safari. Its five-minute timer launches stopped Safari with `open -gj -a Safari`; it has no action for an already running Safari. The timer checks global generation state, not the set of visits owned by this relay. [SafariHistoryStore](../../Sources/SafariSyncCore/SafariHistoryStore.swift), [Agent runtime](../../Sources/SafariSyncAgent/main.swift), [architecture](../ARCHITECTURE.md).

The build-601 record confirms bidirectional synchronization and iPhone propagation on the recorded reference environment, as a maintainer-reported manual result. It does not separately establish Google/Edge account upload or qualify a new active-Safari trigger. [Validation record](../validation/macos-27-build-601.md).

## Design implications

- Preserve local delivery receipts after acknowledging the relay stream. Cloud observation must have its own durable lifecycle.
- Treat native enqueueing, native checkpoints, server acknowledgements, and receiving-device observations as different evidence.
- Diagnose disabled/paused sync separately from an offline queue. Resume alone is not a replay mechanism for all previously skipped events.
- Investigate active-Safari prompting with measurable E2E criteria; do not invent a notification name or assume app/extension responsiveness means upload.
- For the available iPhone/iPad setup, begin with automatic local/native progress checks plus explicit manual arrival diagnostics. Complete automatic cloud-store comparison is not established by these sources.
