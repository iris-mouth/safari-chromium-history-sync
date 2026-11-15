# Integrated viewer validation

The initial synthetic measurements are local baselines, not the device acceptance
result. `integrated-local-benchmark.json` records a separate Collector process,
Viewer process and loopback HTTP, using warm filesystem caches. It does not
include a browser render or a Tailscale network hop. The reported search API time
also excludes the UI's 300 ms debounce. `integrated-local-delay.json` measures
source-commit-to-API delay with a synthetic Chromium DB and a benchmark worker
using the Agent's 30-second interval; it is not a live browser measurement.

For device acceptance, use a separate foreground Tailscale Serve mapping and
synthetic databases. Preserve the existing Viewer and its Serve mapping. Confirm
the expected Tailscale identity is required; a tagged or other user's request
must not receive history. Record the device, OS/browser version, network path,
cache state, 100,000/1,000,000-record dataset, day navigation and the search
latency from the last input through first rendered results (including 300 ms).
Only after the new product and its shutdown/restart behavior are verified should
the existing independent Viewer be retired and its Serve mapping changed.

## First iPhone Safari observation

The owner reported the following using the temporary Tailscale HTTPS viewer and
synthetic data. The device model, OS version, network type and cache state have
not yet been supplied. The temporary Viewer was running with periodic collection
active; the on-screen test timer included the 300 ms search debounce.

| Dataset | Day to render | Search to first render |
| --- | ---: | ---: |
| 100,000 | 310 ms | 1,169 ms |
| 1,000,000 | 540 ms | Failed with a read error |

The 1,000,000-record search failure was reproduced from the Mac: the Reader's
8-second deadline expired while the synthetic collector was active. The search
index was subsequently added; the remeasurement is recorded below.

After adding a literal trigram candidate index, the Mac made five 1,000,000-row
search requests through its own Tailscale HTTPS endpoint while the synthetic
collector was running. All returned HTTP 200; observed API times were 137–160 ms.
The index is only a candidate filter: the original normalized literal substring
checks remain authoritative, including for short terms.

## Existing Viewer on this Mac

Read-only inspection found the `local.historysyncweb` LaunchAgent with both
`KeepAlive` and `RunAtLoad` enabled, and Tailscale HTTPS port 443 forwarding to
local port 8765. The new Viewer uses local port 8766. The temporary synthetic
checks use separate foreground HTTPS ports; they do not replace the existing
mapping. The old LaunchAgent has not been disabled or removed. Cutover must
change both the Serve target and the old LaunchAgent's startup state, with a
reversible rollback, only after the new installed app has passed validation.

## Indexed-search iPhone remeasurement — 2026-11-15

The owner remeasured the 1,000,000-record synthetic dataset in iPhone Safari on
an iPhone Air running iOS 27.2 over Wi-Fi and the owner's Tailscale connection.
After reloading the page and entering `abc がっこう 1 kg`, the test overlay
reported **613 ms** and **572 ms** from the last input to the first rendered
results; the 300 ms debounce is included. The Mac server was Apple silicon on
macOS 27.2.1, with the synthetic Collector continuing its 30-second scan cycle.
The database had just been generated and the endpoint checked from the Mac;
neither OS nor network caches were cleared. These are two observed runs, not a
cold-cache percentile or a measurement of actual private browser history.

The earlier 100,000-record observations (day 310 ms, search 1,169 ms) and the
1,000,000-record day observation (540 ms) were supplied in the preceding test;
the network and device configuration for those individual observations was not
separately recorded. The old 1,000,000-record failure was resolved before the
remeasurement above. The previous persistent HTTPS 443 → local 8765 mapping was
not modified.

## Installed candidate — 2026-11-15

The owner installed build 620, granted Full Disk Access to the Agent and
restarted Menu. The Agent reported ready and completed its first collection of
the selected real Safari database; no browsing contents are recorded here.
The collection enable preference was set through the Agent after the first
settings save left it off, so the settings UI needs an end-to-end recheck.

The installed candidate's profile list showed no Chrome or Edge entries.
Those profile directories deny enumeration to a process without Full Disk
Access on this Mac. The candidate currently discovers profiles in Menu, which
does not have that permission; move discovery into the authorized Agent and
verify the installed result before drawing conclusions about available profiles.

Candidate 621 moves discovery into the Agent and reports access failures. Its
synthetic menu and collection tests pass. It also retains earlier configured
Viewer origins when an origin changes; a synthetic cutover test first exposed
the prior behavior and passes with that fix. With the installed candidate
stopped, an isolated Agent IPC test failed against the previous build and
passed against candidate 621. The replacement package has been built and
signature-checked. After installation and a Menu restart, the installed Agent
reported ready and discovered one Safari, one Chrome and one Edge candidate
without access errors; the previously selected Safari source remained complete.
The owner then selected Safari and Edge, and both sources completed. The
installed, sandboxed Viewer listened only on 127.0.0.1:8766: missing and
incorrect owner headers returned 403, while the actual owner's header returned
200 for the page and status. A temporary foreground Tailscale Serve on 8443
returned 200 and replaced a forged identity header with the actual owner's
identity. The previous 443 → 8765 mapping remained unchanged. Visual Mac and
iPhone checks of Safari/Edge records, date changes, search and details were
confirmed by the owner. The first iPhone attempt could not find the server;
after checking the Tailscale connection and retrying, both the temporary and
previous Viewer opened. No private browsing content was recorded here.

For the installed candidate, the owner quit Menu, waited and reopened it.
During the gap Menu, Agent and Viewer were absent, port 8766 was closed, and
the temporary Serve returned 502. After restart all three processes returned,
the temporary Serve returned 200, and both selected sources and collection
enablement remained intact. The pre-existing Edge sync preference remains
enabled, but no extension connection was observed after restart; investigate
that separately before claiming the installed sync path is verified. The owner
confirmed the Edge extension was absent, authorized loading the bundled 6.2.0
extension, and it connected with a new profile identity. The stored active
Edge identity had no current outbox or recovery items at that point. A full
macOS logout/login test has not yet been performed.

After the owner selected the newly connected Edge profile, sync stopped with
`historyIdentityChanged`. The owner requested further investigation, so no
cursor reset was performed. Candidate 622 adds an authenticated, read-only
diagnostic that compares the stored cursor's identity and anchor against the
current Safari DB and reports aggregate counts/dates without URLs or keys.
Fixture tests include a blocked Agent with a replaced DB and matching anchor;
inspection leaves the sync state and source history unchanged. After the owner
installed 622 and re-registered Full Disk Access, the installed diagnostic found
a changed database identity but a matching stored anchor and current rows with
greater native IDs. Some later Safari URLs also appeared in the selected Edge
source, while others did not. This URL-only comparison cannot establish whether
a specific visit was delivered: Edge records may have expired or been deleted,
the same URL may be visited more than once, and the earlier sync partner may
have had a different identity. The matching anchor alone does not prove that
the whole database generation is continuous. Sync remains blocked and its
cursor has not been reset or advanced. After reviewing these aggregates, the
owner chose to keep browser sync stopped. The sync preference was explicitly
switched off; a before/after diagnostic confirmed the cursor evidence and
queued-item counts were unchanged. Safari collection completed; Edge retained
its last successful data but encountered an active journal while open.

The owner installed candidate 623 and re-registered Full Disk Access. Both
selected sources then reported complete while Edge remained open, and the
temporary Tailscale Viewer returned 200 for the owner. A unique temporary
loopback page was opened in Edge: the selected Edge source's last successful
collection followed the browser visit by 23.07 seconds, and the record was
observed in the Viewer API 28.70 seconds after that browser visit. The owner
removed only that test URL through Edge's history UI. A monitor that had already
seen the record found it absent from the integrated DB 48.93 seconds after
monitoring began; the API search also returned no matching test record. The
monitor began before the owner confirmed deletion, so this is not a measurement
of the precise deletion-to-removal interval. Browser visits may precede their
arrival in the source DB, so the insertion figure is an observed upper bound
from the browser's visit timestamp, not a direct measurement of the DB commit.
Both sources remained complete. The separate temporary HTTP server was stopped.
The existing Viewer and HTTPS 443 mapping were not changed during that test.

The candidate was not listed under System Settings → General → Login Items
after saving collection settings. It was added there manually, and System
Settings then displayed it under apps opened at login. A separate ad-hoc-signed
diagnostic app reproduced the cause: `SMAppService.mainApp.status` returned
`notFound` for an app that had never been registered, while `register()`
succeeded and changed the status to `enabled`. The diagnostic registration was
removed immediately. Build 624 changes the Menu to attempt registration for
that state and to report an unresolved registration instead of treating it as
success. An independently signed temporary app compiled with the same Menu
registration helper reproduced `notFound`, registered successfully, and then
unregistered itself. The Menu tests also cover enabled, approval-required and
unresolved outcomes. The 624 package's Agent has the same ad-hoc code hash as
the installed 623 Agent. After the owner installed 624 and restarted Menu, both
selected sources completed without re-registering Full Disk Access, the Viewer
responded, and System Settings still listed the app under login items. A full
logout/login still needs verification. Both temporary diagnostic apps
unregistered successfully and their app bundles were removed. macOS initially
listed them under background app activity, but they later disappeared from the
list. The global background-item database was not reset.

The owner deferred the logout test and explicitly chose to cut over before it.
The persistent Tailscale HTTPS 443 root now forwards to local 8766. The old
`local.historysyncweb` LaunchAgent was disabled and unloaded. After the switch,
Mac-side checks returned 200 from the new page and status, showed both sources
complete, verified the Tailscale identity-header behavior and confirmed browser
sync remained off.
The new Viewer origin was saved and added to the collection exclusions.

The Safari source count decreased after the final origin was added to those
exclusions. The decrease matched the previous Viewer's aggregated Safari visit
count for that same HTTPS root. This supports the expected exclusion of visits
to the Viewer itself; the aggregated old data does not independently prove a
visit-by-visit correspondence. No Safari source history was deleted. The owner
confirmed that the final URL worked on iPhone and that the Menu's Web-opening
command worked on the Mac. The temporary
foreground 8443 mapping was then stopped; HTTPS 443 still returned the new
Viewer and both sources remained complete. The owner also confirmed that the
Menu-opening command worked after the temporary mapping was stopped.

At the owner's subsequent request, the old HistorySync app, its data and logs,
and the old Viewer's LaunchAgent, local configuration and virtual environment
were moved to the macOS Trash. The old app's Full Disk Access entry was removed,
and its Viewer background activity was switched off. The old Viewer source
checkout was retained. After removal, the integrated Viewer still returned 200
through HTTPS 443 and both selected sources remained complete.
