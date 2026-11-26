# Integrated app validation

These records identify the build and test conditions for each observation.

| What was checked | Evidence |
| --- | --- |
| Collector reconciliation, interrupted scans, extension visits during a Chromium lock, and profile changes using synthetic databases | [Build 630](validation/build-630.md) and [Chromium lock behavior](validation/chromium-exclusive-lock.md) |
| Owner access through the Tailscale gateway on port 8767 and rejection of a direct local connection | [Build 627](validation/build-626.md#build-627) |
| Date and search timings on physical iPhone Safari with 100,000 and 1,000,000 synthetic visits | [Build 630 comparison](validation/build-630.md#physical-iphone-safari) and [earlier device measurements](validation/integrated-device-validation.md) |
| Date controls on physical iPhone Safari, Japanese Mac settings, and collection while browser sync was off | [Build 631-r3](validation/build-631-r3.md) |
| Parent-only Full Disk Access, Safari and Edge scans, and a visit reported by the extension while Edge was open | [Extension 632 with native build 631](validation/extension-632.md) |

For extension 632, the owner chose to discard legacy outbound entries without
source visit identity and previously held entries. The installed Edge store
contained no entries eligible for deletion. The [extension validation record](validation/extension-632.md)
distinguishes the synthetic deletion test from that observation.

The owner approved the Viewer cutover with browser sync off and deferred an
actual logout and login with pending extension work. [Cutover record](validation/integration-cutover.md).

## Candidate 633 local API measurements

On November 26, 2026, the benchmark ran on an arm64 Mac with macOS 27.2.1.
Each value is the median of four localhost requests in milliseconds, after
fixture generation warmed the filesystem cache.

| Visits | Revision | One day | All dates with keywords | All dates | One day with keywords |
| ---: | --- | ---: | ---: | ---: | ---: |
| 100,000 | `5d25b9d` baseline | 106 | 54 | Not measured | Not measured |
| 100,000 | 633 | 129 | 56 | 112 | 5 |
| 1,000,000 | `5d25b9d` baseline | 113 | 114 | Not measured | Not measured |
| 1,000,000 | 633 | 109 | 112 | 108 | 32 |

These timings cover only the API. Physical iPhone timings for the new search
interaction are pending. Earlier device timings include a 300 ms input delay.
[Viewer test conditions](../CONTRIBUTING.md#verify-history-and-viewer-changes).

Candidate 633 also passed the extension, Go gateway, Swift integration and AppKit
checks, all 48 Playwright cases, and isolated Agent/Viewer process tests. The
process tests cover collection failure without changing the saved sync preference
and recovery after the database returns. The final package passed deep signature
verification. After installation and parent-app Full Disk Access re-registration,
Safari and Edge scans completed and the normal HTTPS page and API returned 200.
After Keychain approval, the Agent reported ready with saved and effective sync
off. The owner confirmed iPhone search, date layout and the fixed URL. The owner
also reported missing recent iPhone Safari visits, then confirmed those visits
were visible after Safari was opened on the Mac and collection completed.
The Viewer initially contained Safari visits only through November 16. The
native cursor diagnostic also reported that date, but its maximum is limited to
IDs after the saved sync cursor and does not prove the whole native DB maximum.
After opening Safari, 2,105 additional visits were collected, advancing the
Viewer through November 25 at 16:58:35 JST. Both devices had iCloud Safari on.
The new iPhone test visit was still absent from Mac Safari search and the Viewer
at the last check; immediate iPhone-to-Mac arrival remains unverified.

Additional iCloud prompting was deferred because its benefit has not been
established; existing delivery-triggered Sync Assist is unchanged.
