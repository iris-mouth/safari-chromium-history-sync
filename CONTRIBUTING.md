# Contributing

## Build and test

Use macOS with Apple command-line tools, Go, Node.js 22.18 or later, and Python 3.
The installed app does not require Node.js or Python.

```sh
npm --prefix web ci
web/node_modules/.bin/playwright install chromium webkit
./scripts/check.sh
swift build --disable-sandbox
npm --prefix web run build
npm --prefix web test
./scripts/package-app.sh
```

The package is written to `dist/`. Follow the [app setup](README.md#install).
Update Japanese and English strings together when changing the interface.

## Test data

Use synthetic histories for routine tests. The independent
[Safari schema fixture](tests/fixtures/safari-history-v1.sql) was captured from a
local Safari backup on 2026-09-22 without browsing rows or metadata values;
keep it independent of the production schema definition.

Optional process tests require the installed Agent to be stopped. Set
`HISTORY_TEST_AGENT` and `HISTORY_TEST_VIEWER` to isolated debug executable paths
when running `SafariSyncCoreIntegrationTests`. The fixtures use temporary state
and local sockets. For a manual copied-database test, also isolate
`SAFARI_SYNC_HISTORY_PATH`, `SAFARI_SYNC_STATE_DIR`, and `SAFARI_SYNC_SOCKET_PATH`.

For Viewer performance changes, measure physical iPhone Safari over Tailscale
with synthetic data. At 100,000 visits, target 1 second for dates and 2 seconds
from search submission to results; compare 1,000,000 visits under the same
conditions. Record device, network, cache state, and query in the issue or release.
Report local insertion, native sync progress, and receiving-device arrival separately.

## Changes

Explain the problem, why the change is needed, and how it was verified in the PR
and commits. Keep enduring setup guidance here; use issues and releases for
work logs and validation results. Do not add documents that repeat code or history.
Share only sanitized evidence; see [Security](SECURITY.md).
