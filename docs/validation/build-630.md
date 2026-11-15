# Candidate 630 validation

Candidate 630 was installed over 627 on the validation Mac. The installed Menu and embedded Agent executables matched the packaged binaries. After restoring the embedded Agent's Full Disk Access and restarting, Safari and Edge each reported a completed collection. The normal Tailscale Viewer status endpoint returned HTTP 200. After measurement, 443 was the only configured Serve port. After Keychain authorization the Agent reported ready with no issue. The selected family was Edge, the extension binding was empty and routing was disabled. Read-only Safari cursor inspection reported the existing identity mismatch with a matching anchor. Browser sync stayed off throughout real-data testing.

## Profile selection and delivery

Using temporary user-data directories for the installed Chrome and Edge, the launch command opened the intended directory in both directions between two profiles with the same display name, including when the other profile was active. Chromium for Testing also opened the extension connection page in the intended profile in both directions.

The isolated Agent/Viewer process test exercised the authenticated Menu and bridge protocols with synthetic Safari and Chromium databases. Coverage includes initial opt-in, both delivery directions, stale selection rejection, API notifications, source deletion before delivery, switching profiles, retention of Safari records and native browser history, recovery after interruption, and shutdown with the Menu. The collector test exercises extension ingestion during an exclusive write lock, repeated visits to one URL, native timestamp reconciliation without a duplicate delivery, stale snapshots after a deletion notification, and extension reinstallation.

The project check script passed. The Viewer passed all 45 Playwright tests across WebKit, desktop Chromium and mobile Chromium.

## Physical iPhone Safari

Both builds used synthetic data on the same temporary Tailscale routes and the same timing control. Each cell shows elapsed milliseconds for the date filter and search. Each build has one reported sample per operation. The 630 fixture was measured during validation before the final changes to removal reconciliation. The Viewer UI and query implementation were the same.

| Visits | 627 date | 630 date | 627 search | 630 search |
| ---: | ---: | ---: | ---: | ---: |
| 100,000 | 370 | 339 | 501 | 594 |
| 1,000,000 | 408 | 355 | 693 | 999 |

The local Swift API benchmark used the final source and four requests per operation. Median responses for 100,000 visits were 134 ms for date and 57 ms for search. At 1,000,000 visits they were 108 ms and 111 ms. The physical-device search measurement includes the UI debounce and network. The local measurements and initial import times are in [the benchmark record](integrated-local-benchmark.json).
