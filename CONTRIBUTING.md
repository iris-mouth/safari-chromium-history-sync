# Contributing

## Build and test on macOS

Install the Apple command-line tools, Go, Node.js 22.18 or later, and Python 3.
The installed app runs without Node.js or Python. Run the checks and build the
package from the repository root.

```sh
npm --prefix web ci
./scripts/check.sh
swift build --product SafariSyncViewer
npm --prefix web run build
npm --prefix web test
./scripts/package-app.sh
```

If Playwright needs browser binaries, run
`web/node_modules/.bin/playwright install chromium webkit` after `npm ci`.
Playwright serves a temporary synthetic database on `127.0.0.1:18766`.
The project checks exercise AppKit with in-memory replies, the gateway, the
extension, and the public Agent and Reader interfaces.

The unsigned PKG in `dist/` installs one ad-hoc-signed app in `/Applications`
with its Agent, gateway, and sandboxed Viewer inside. Follow the
[setup instructions](README.md#set-up-the-app).
For setup changes, exercise Chrome only, Edge only, and both browsers. Check
that an unselected browser receives no Native Messaging directory or manifest.
Update the Japanese and English strings together when changing the interface.

## Verify history and Viewer changes

Use synthetic browser histories for routine tests. The Safari SQL fixture
records real table constraints without browsing data. When changing the
adapter, check both equivalent layouts and layouts the writer must reject.
[Schema fixture](tests/fixtures/safari-history-v1.sql) and
[compatibility policy](docs/COMPATIBILITY.md).

The optional process tests exercise an isolated debug Agent and Viewer,
including interrupted collection, restart, and owner shutdown. Run these on a
test Mac with the installed Agent stopped. Set `HISTORY_TEST_AGENT` and
`HISTORY_TEST_VIEWER` to their absolute debug executable paths when running
`SafariSyncCoreIntegrationTests`. The fixture uses temporary state and needs
permission to bind local sockets.

For a manual copied-database test, stop the installed Agent first. Set `SAFARI_SYNC_HISTORY_PATH`,
`SAFARI_SYNC_STATE_DIR`, and `SAFARI_SYNC_SOCKET_PATH` to isolated test paths.

Measure Viewer changes on physical iPhone Safari through Tailscale with
synthetic data. At 100,000 visits the targets are 1 second for a date view and
2 seconds from search submission to the first results. Compare 1,000,000 visits
under the same conditions. Record device, cache state, network, and query.
Older device timings started at the last keystroke and included a 300 ms wait.
For local API timings, set `HISTORY_BENCH_BIN` and `HISTORY_VIEWER_BIN` to the
built `HistoryBenchmark` and `SafariSyncViewer` executables. Run
`scripts/benchmark-integrated.py --output /tmp/history-benchmark.json`.
[Previous device measurements](docs/validation/build-630.md).

## Open a pull request

Describe what changed, why, and how you verified it. Identify any browser API
limitation and whether the test touched live history. Share sanitized evidence.
[Private data and reporting](SECURITY.md).
