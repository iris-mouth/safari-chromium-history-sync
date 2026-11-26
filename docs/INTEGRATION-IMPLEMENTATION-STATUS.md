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

The owner approved the Viewer cutover with browser sync off. Login restoration
was subsequently verified on build 635 with sync off and empty delivery queues;
restoration with pending extension work remains untested and is tracked in
[issue #2](https://github.com/iris-mouth/safari-chromium-history-sync/issues/2).
[Cutover record](validation/integration-cutover.md).

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

These timings cover only the API. No physical iPhone timings were recorded for
build 633; build 635 measurements appear below. Earlier device timings include a 300 ms input delay.
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
The new iPhone test visit was absent at the initial check. The owner subsequently
confirmed new visits arriving through iCloud in the Viewer; arrival latency was
not measured.

Additional iCloud prompting was deferred because its benefit has not been
established; existing delivery-triggered Sync Assist is unchanged.

## Candidate 634

Candidate 634 offered a single date, an optional end date, and all history.
Clearing keywords preserves applied dates. Dates use ISO calendar-date notation
with a localized weekday. The final assets passed all 51 Playwright cases,
including WebKit, mobile/desktop Chromium, 320 px layouts, and enlarged text.
The package passed deep signature verification. Installation and restart succeeded;
the normal HTTPS URL then served the final assets. The owner confirmed the iPhone
controls work, but rejected the layout for inconsistent alignment and spacing;
candidate 635 replaces that layout. Parent-app Full
Disk Access initially appeared enabled, but TCC rejected its stale code
requirement. Removing and re-adding the installed parent app, followed by the
system restart action, restored complete Safari and Edge scans. After Keychain
approval, the Agent reported ready without an issue; saved and effective browser
sync remained off. The normal HTTPS status endpoint responded successfully.

## Candidate 635

The search form has three fixed regions: two independently editable dates,
optional keywords, and Search with application state. Empty dates leave the
corresponding bounds open. Clearing any field submits all current inputs.
Requests preserve the previous results and later edits; only a successful
response changes the applied conditions and browser history. Back, Forward,
and browser Reload discard unsubmitted edits.

The extension, Go gateway, Swift integration and AppKit checks passed, as did
all 60 browser cases across WebKit and mobile/desktop Chromium. Coverage includes
open date bounds, IME confirmation, delayed and failed requests, empty results,
history restoration, Japanese/English, 320–1000 px widths and 200% text sizing.
The candidate package passed deep signature verification.

The November 26 comparison used release binaries, the same synthetic SQLite
fixtures, warmed filesystem cache, and medians of four localhost API requests
in milliseconds. Keywords were `abc がっこう 1 kg`; the date was 2026-11-10 JST.
These values exclude browser rendering and the Tailscale network.

| Visits | 634 date / search | 635 date / search |
| ---: | ---: | ---: |
| 100,000 | 105 / 52 | 104 / 53 |
| 1,000,000 | 106 / 110 | 106 / 110 |

The owner measured the initial 635 preview on iPhone Safari over Wi-Fi:
100,000 visits took 350 ms for date and 217 ms for search; 1,000,000 took
1,151 ms and 1,034 ms. These are single reports, with cache state unspecified.
The preview helper measures submission through rendered results and two frames.
The owner requested a denser layout and removal of weekdays. The current
revision uses ISO dates throughout, one-line date fields, 40 px control frames,
and at least 44 px touch targets. Spacing keeps adjacent hit areas separate.
At 390 px, the first row begins at 413 CSS px, compared with 475 in the
previous compact preview and 590 in the initial preview.
The controls, collection summary, and result tools remain aligned in Japanese
and English. The preview used a temporary user service with Interactive
scheduling; Background scheduling had throttled the large synthetic fixture.

The owner approved the final compact preview, including the revised reload icon.
Build 635 was installed and passed deep signature verification. The normal HTTPS
URL serves assets identical to the installed package. WebKit checks passed for
date and keyword searches, each field's clear action, reload, the fixed URL, and
the 390 px layout. The temporary preview service and ports 8443/8444 were removed;
the normal port 443 mapping is unchanged. After installation, both collection
sources reported access unavailable. TCC still held an older parent-app code
requirement after the first re-registration. Stopping the app and renewing that
registration restored complete Safari and Edge scans. Agent initialization also
completed after its Keychain wait: runtime ready, no issue, and saved/effective
browser sync off. The normal HTTPS status endpoint returned 200.

On November 26, the owner logged out and back in without manually opening the app.
New Menu, Agent, gateway and Viewer processes started at 23:14 JST, and both
collection sources completed fresh scans. Agent was ready with no issue, sync off
and empty delivery queues. The first HTTPS check failed DNS resolution; Tailscale
DNS recovered without intervention, after which the normal page, status and
records endpoints returned 200. This verifies automatic restoration with sync
off, not delivery recovery with pending work.
