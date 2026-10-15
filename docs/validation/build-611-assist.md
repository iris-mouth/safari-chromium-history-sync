# Build 611 Safari Sync Assist validation

Date: 2026-10-15 (Asia/Tokyo). This is project verification evidence.

## Automated and packaging checks

- `./scripts/check.sh`: JavaScript 30/30 and Swift integration checks passed, including assist opt-in, crash-persistent cooldown and rolling budget, retry scheduling after native backoff, helper-URL echo exclusion, and stopping on checkpoint coverage.
- All three release products built. Safari operation script compiled through `--validate-safari-assist-script` without executing a navigation.
- Both app signatures and expanded PKG payload verified.
- Final local PKG SHA-256: `c6e1368b1dc83407b5fdbbc775b7f12d79ffc66cf1a523d827a3a9ff9e353a91`.

## Live Mac checks

Installed build 611 on the same macOS 27.0.1 / Safari environment as the build-610 arrival record. Keychain authentication and Full Disk Access were renewed after the ad-hoc update. The user explicitly approved Safari Automation access, and System Settings showed it on.

The Agent remained responsive through its authenticated IPC API during Safari events. The feature was enabled and its durable reservation/cooldown survived restarts. Before Automation was granted, two navigation attempts failed; these consumed their reserved budget rather than looping. A scheduling issue involving old delivery backoff was fixed and covered by a regression check before the final installation.

At 14:47 JST the normal timer recorded `tabCreated`, confirming that a dedicated helper document was created. At 14:52 JST a later normal timer attempt recorded `tabReused`, confirming that it reused the same control URL/tab after the five-minute cooldown rather than creating another window. The helper URL did not appear as an outgoing relay delivery. Safari subsequently reported a history-helper communication error (NSCocoaErrorDomain 4099), so this successful navigation was not represented as a cloud receipt or mobile arrival. Native progress and retry observations are separate from the action result. At the end of this initial check the helper remained enabled, with four budgeted attempts (two initial failures, creation, reuse); pending Safari records were retained for later checks. No per-visit cloud success or new mobile arrival was asserted.

These initial Mac checks were not a mobile end-to-end qualification. They were followed by the user-reported iPhone confirmation after recovery, recorded below. The build-610 probe confirmations remain separate. The current release retains its compatible-unverified label; these narrow manual results do not qualify all failure modes or iPad delivery.

## Recovery of Safari history-helper communication (same day)

At approximately 15:00 JST, the previously reported communication failure was investigated against the live Mac. This operation did not change application code, cloud settings, history rows, or sync-generation metadata.

Before recovery, an authenticated, paginated read of the Agent journal identified 37 unverified Safari deliveries still below their destination generations. The checkpoint was 462. A repeatable comparison over this fixed set reported 0/37 covered (exit 1). The comparison stored only delivery IDs/generations in a mode-0600 temporary baseline, with no URLs.

The Safari client (PID 23359) had been running for over 18 hours. The history service (PID 59083) was alive, its main thread was waiting in the normal run loop, and it had received iCloud push notifications. Safari logged NSCocoaErrorDomain 4099 failures when fetching, saving, and querying the next permitted save. Those facts favor a failed Safari-client connection over a dead history service; the exact internal Apple framework failure was not established.

The user performed a normal Safari quit and reopen after the UI automation could not obtain its window. The new Safari client was PID 91529, while the same history-service process remained running. The service then successfully fetched and merged iCloud changes. A normal navigation to the existing helper control URL was performed in the new Safari window, without changing other tabs or creating a new probe.

The same fixed-set comparison subsequently reported 37/37 checkpoint-covered and 0 remaining from the baseline (exit 0), first at checkpoint 501 and again with checkpoint 505 present. No new CloudHistory 4099/failure logs were returned for the interval beginning 15:00:10 through the final check. The native helper itself did not need restarting, and no account reset or history replay was used. This supports recovery by rebuilding Safari’s client connection. Safari Sync Assist remained enabled.

New visits continued arriving while the check ran, so this is not a claim that every current queue is empty. Checkpoint progress is native synchronization evidence, not per-visit server acknowledgement or independent iPhone arrival. The earlier user-confirmed mobile probes remain recorded separately.

## User-reported iPhone arrival after recovery

Later on 2026-10-15, after being asked to look for two or three remembered pages from Mac Edge in iPhone Safari’s history without opening their URLs, the user replied: 「届いています。」

Record this as user-reported arrival of the ordinary pages they checked after the build-611 helper recovery. The assistant did not independently observe the iPhone. The user did not supply the individual URLs or an exact count, so no individual delivery rows were changed and no claim was made that all 37 baseline visits had been separately verified on iPhone. The earlier 37/37 checkpoint result remains native progress evidence, distinct from this mobile confirmation.
