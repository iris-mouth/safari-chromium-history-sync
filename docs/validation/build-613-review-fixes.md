# Build 613 review fixes and menu validation

Date: 2026-10-16 (Asia/Tokyo). Development version 6.1.3, app build 613,
extension 6.1.3. This record covers source/fixture validation, not new mobile arrival.
The baseline is commit `3396ef351290d1dcb8280a709e776a9b69b5061d` (builds 610–612).

## Reviewed defects

Seven P2 findings were reproduced before the fixes. Four worker cases failed in
`node --test tests/worker_cloud.test.js`: saved ACK evidence older than 64 later
visits, a cancelled account probe's second insertion, removal of the second URL
in an Agent-reserved page, and a delayed removal callback's cutoff. Three Swift
cases failed through the real `AgentService`/coordinator: writing to a replacement
DB before detecting identity drift, rejecting a capable worker's pre-upgrade
untracked ACK, and carrying an hourly retry deadline into new work after receiver
confirmation resolved the backlog.

The fixes validate the saved cursor's identity/anchor inside the Safari write
transaction, capture removal time before the worker queue, let the Agent match
all removed web URLs against owned work, compare ACK evidence against full visit
results, re-pull an exact pending event before a second insertion, determine
receipt requirements from tracked events, and clear resolved retry state while
preserving the last-action timestamp.

Regression checks are in `tests/worker_cloud.test.js` and
`tests/SafariSyncCoreIntegrationTests/ReviewRegressionTests.swift`. They also
cover missing/changed anchors, both publish and queued writes, preservation of
new tracked receipt requirements, all 65 post-marker real visits, a genuine
retry, inactive-Agent preservation, evidence arriving during authorization, and
byte-bounded removal messages.

The first independent re-review found one incomplete cancellation edge: with
129 removed URLs, the worker sent only the first batch before resuming delivery
of a queued URL in batch two. The regression failed for both 129 and 1025 URLs,
and for a failed cancellation response. Reporting is now a barrier for both
exchange and evidence callbacks, bounded to eight batches per turn without
allowing writes past remaining batches. Negotiation refetches a page after old
notifications are reported. All focused worker cases pass after this correction.

## Menu behavior

The normal menu uses Japanese action descriptions and opens a read-only status
window. Safari helper configuration is separate and writes only after saving.
Compatibility and recovery are grouped under troubleshooting. Test URLs,
receiver evidence, export comparison, replay and account change are initially
collapsed inside detailed diagnostics. Probe/replay dialogs describe their
destination and added history entry before execution. Reopening the app opens
status rather than the verification screen.

`scripts/check-menu.sh` compiles the actual controllers against in-memory
replies, excluding the app entry point. It verifies normal-menu actions,
read-only status/diagnostic opening, and advanced-control visibility without
launching or contacting the installed Agent. It is included in `scripts/check.sh`.

## Checks

- `./scripts/check.sh`: passed on the final executable sources.
- JavaScript: 42/42 passed, including the new worker cases.
- Swift integration suite: passed, including the three reviewed regression groups.
- AppKit controller/interaction checks: passed with in-memory replies.
- `git diff --check`: passed.
- All three release products built; both original app bundles passed signature verification.
- The PKG was expanded into a new temporary directory; both extracted apps passed
  strict/deep signature verification and report 6.1.3 / build 613. The bundled
  extension reports 6.1.3 and its files match the reviewed source. Installer
  scripts are absent.
- PKG SHA-256: `04923d15ad40c0d6ecf07e92760d3d6c0b5db834ce7d8a160deff54b66748f4c`.

The restricted build initially could not write its compiler cache or generate a
dSYM. Temporary module caches and an approved local packaging run completed the
build without installing either app. The package tool emitted provenance/xattr
permission messages but exited successfully; extraction, source comparison and
signature verification above independently checked the resulting payload.

## Standards

Independent re-review: no actionable findings, zero documented-standard
violations and zero new heuristic findings. Both original P2s are resolved.
The reviewer reran the original identity-replacement fixture (zero writes,
`historyIdentityChanged`) and delayed-notification fixture (the original
callback cutoff is preserved), then checked the final cancellation barrier and
read-only compatibility action. The final 42 JavaScript checks and AppKit
controller check also passed independently.

## Spec

Independent final re-review: no actionable findings, zero remaining P2s.
All five original specification findings are resolved, including the
multiple-batch cancellation issue found in the first re-review. The reviewer
checked the original minimal counterexample plus independent cases covering
notification failure, lost-response/restart recovery, negotiation refetch and
older-Agent ACK compatibility. The menu changes match the requested separation
of daily operations from advanced verification.

The final executable sources were frozen as 66 project files with a SHA-256
manifest and a WIP patch relative to the baseline. Reviewers checked that copy
without modifying code or accessing live history. Before this record was
finalized, all reviewed file hashes matched the packaged source. Only this
validation report was completed after their verdicts; executable sources did
not change.

Findings: Standards 0 (no worst issue); Spec 0 (no worst issue).

No live Safari or Chromium history, account settings, Keychain items, privacy
permissions or installed app bundles were changed by these checks. The tests
use data-free temporary SQLite fixtures and mocked browser/native transports.
Build 612's user-reported iPhone arrival remains historical evidence for build
612. Build 613 has no newly verified iPhone/iPad arrival and retains the
compatible-unverified label.
