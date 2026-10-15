# Build 612 Safari automatic retry validation

Date: 2026-10-15 (Asia/Tokyo). Development version 6.1.2. This is project verification evidence.

## Reproduction and implementation

The previous build's six-attempt rolling-day ceiling stopped automatic work while owned Safari visits remained below their generations. A regression through `AgentService.pollCloud`, using a fixture database and persisted Agent state, failed with `pending Safari retries beyond six attempts without manual action: expected 7, got 6`. The command was `CLANG_MODULE_CACHE_PATH=/private/tmp/schs-612-clang-cache SWIFTPM_MODULECACHE_OVERRIDE=/private/tmp/schs-612-swift-cache swift run --disable-sandbox --scratch-path /private/tmp/schs-612-tests SafariSyncCoreIntegrationTests`.

Build 612 replaces daily ceilings for hidden launches and opted-in navigations with a shared, crash-persistent schedule: 5/10/20/40/60 minutes without checkpoint progress, then hourly while eligible pending work remains. Native progress or new work after a resolved backlog resets backoff, but preserves the five-minute floor. New arrivals during a stall, successful navigation alone, toggles, and restarts do not reset it. Exhausted build-611 budgets migrate automatically; their last cooldown, opt-in and dedicated control URL survive. Legacy launch deadlines can bring forward old six-hour observation delays.

The Safari driver alternates two exact owned control URLs in one tab. Both are excluded from outgoing relay. It uses standard Apple events; navigation success remains distinct from checkpoint progress or receiving-device arrival.

## Automated checks

The focused command adds `--cloud-delivery` to the command above. It passes after the fix. It covers attempts seven/eight across restart, exact backoff boundaries, failed navigation, partial checkpoint progress and the cooldown floor, new arrivals during a stall, shared failed-launch/navigation cooldown, receiver-confirmation stop, new work after a resolved backlog, old exhausted-budget migration, old six-hour observation deadlines, persistence before external work, both control-URL exclusions, and rejection of unrelated/malformed control URLs.

- `./scripts/check.sh`: JavaScript 30/30, all Swift integration checks, and syntax checks passed.
- All three release products built. The Safari Apple-event source compiled through `--validate-safari-assist-script` without performing navigation.
- Both original app signatures and the two apps extracted from the PKG verified; both report version 6.1.2 / build 612.
- Local PKG SHA-256: `7afff78e08b6c17ff9bdcb7247649193c63c8810213875633edd914d18610dbc`.

## Live Mac check

Before the update, build 611 was ready and enabled, with Edge extension 6.1 connected, six persisted helper attempts in its rolling-day budget, 12 pending Safari records, checkpoint-covered count 224, and five receiver-confirmed records. Its helper opt-in was on. The installed 611 apps and encrypted Agent state were backed up in an owner-only temporary folder before replacing both apps with verified build 612. Only product processes were normally terminated; Safari and Edge were left running.

Build 612's authenticated health interface responded with the new build number. Initialization then waited inside `KeychainRootSecret.load` / `SecItemCopyMatching`; SecurityAgent was running. The user completed macOS authentication on screen. Health subsequently reported `safariAccessUnavailable`; System Settings showed this Agent's existing Full Disk Access switch off after the ad-hoc app update. The user authenticated restoration of that same permission, and the switch was observed on. Only the product Agent was normally restarted to apply it. The user completed the resulting Keychain confirmation. Health then returned ready/enabled, build 612, the same active Edge profile and extension 6.1, with both local transport queues empty and no recovery/unrecoverable work.

At 22:54:53 JST the normal Agent timer automatically recorded `tabReused`, retry count 1, native checkpoint 681 and next-attempt time 22:59:53. The old opted-in control URL was retained. No manual enable, daily-counter reset, or manual trigger was used to recover the previously exhausted six-attempt budget. Immediately before the new probe there were 23 pending Safari deliveries.

At 22:54:56 a single Safari probe was created through the normal authenticated writer:

- Delivery: `probe:38CDCFD3-3697-4480-A108-C6A0054C8CA7`.
- URL: `https://example.com/safari-history-sync-probe/EF4A037A-3B55-48D4-B47B-929CB03AC847`.
- Local generation: 706. Receiving-device state remained unverified.

The same-probe observer first returned exit 1 with checkpoint 681, then exit 0 with checkpoint 706 / `checkpointCovered`. Its progress observation was recorded at 22:56:53; the final read was at 22:57:28. Checkpoint-covered count rose 224→248, Safari pending fell 24→0, and possible stalls fell to zero. The shared retry state then had `hasPending: false`, retry count zero and no next-attempt time, confirming that the resolved backlog stopped automatic work. Five existing receiver confirmations were retained; the new probe was not marked receiver-seen.

The assistant did not focus, navigate, reload, restart or inspect Safari's UI during this automatic check. The control action came from the normal 15-second timer. No account settings or native synchronization acknowledgements were edited. A query for CloudHistory 4099/failure messages during the check returned none. This is a narrow live check of automatic Mac native progress after an exhausted daily budget; simulated-time fixture tests separately qualify repeated attempts, failure backoff and restarts. Offline/sleep cycles, Safari helper disconnection recovery and iPad arrival were not newly qualified.

The build-611 Safari `D26BAFB4` and Edge `99E17CDD` probes were both reported visible by the user after manual Safari activity; those observations remain separate from build 612's automatic navigation and its later mobile observation below. The release remains compatible-unverified; this narrow result does not qualify every failure mode or runtime.

## User-reported iPhone Safari arrival

Later on 2026-10-15, after being given the new probe's identifier `EF4A037A`, the user reported: 「iPhoneのSafariにもテストURLが届いています。」 This confirms user-observed arrival of that specific build-612 Safari probe on iPhone Safari following the automatic Mac check above. The assistant did not independently observe the iPhone. This does not establish iPad arrival or confirm all other pending/history records individually.

That single delivery was recorded through the authenticated `cloudObserve` interface as receiver-seen on `iPhone Safari (user-reported 2026-10-15)`, preserving its separate checkpoint evidence. No other delivery was marked seen from this report.
