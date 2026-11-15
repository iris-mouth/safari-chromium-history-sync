# Contributing

Contributions should keep the project local, inspectable, and reversible.

## Build

Source builds require Apple command-line build tools and Node.js for the tests.
Python and Node.js are not runtime dependencies. Node.js is also used to build
the React assets; Python is used only to create synthetic development fixtures. Run checks before packaging or
opening a PR:

```sh
npm --prefix web ci
./scripts/check.sh
./scripts/package-app.sh
```

The generated app bundles and `Safari-Chromium-History-Sync.pkg` are in `dist/`.

## Setup

Build the app, open it, and use **Set Up Extensions & Login… → Start Setup** to select only the browser under test. Load the extension from the app's bundled `ChromiumExtension` folder. Do not start synchronization until the legacy writer is stopped.

`./scripts/package-app.sh` creates ad-hoc-signed app bundles and an unsigned, payload-only PKG for local testing. The PKG must continue to contain only the two sibling app bundles under `/Applications`; do not add installer scripts, store-distribution machinery, or user-specific Native Messaging files to it.

`scripts/check-menu.sh` checks the real AppKit controllers with in-memory replies,
including read-only status opening and initially collapsed test actions. It
excludes the app entry point so it cannot launch or contact the installed Agent.
It is part of `scripts/check.sh` and does not navigate any real browser.

Keep product-authored menu and dialog text in English. Action labels should
describe what happens when selected; test and repair actions stay in the
initially collapsed section of Detailed Diagnostics.

## Testing Safely

Do not test new Safari write behavior against live Safari history first. The Swift integration executable creates an exact-schema temporary SQLite database and exercises the public Agent interfaces:

The schema-only fixture in `tests/fixtures/safari-history-v1.sql` is captured evidence. Do not simplify its constraints to make tests pass. Follow [the compatibility policy](docs/COMPATIBILITY.md) when changing structural checks or recording tested environments. New version numbers do not require allowlist entries; only verified end-to-end results earn a tested label. Test both equivalent structures that should pass and behavioral changes that must fail.

Use copied files:

```sh
./scripts/check.sh
```

For a manual copied-DB test, set `SAFARI_SYNC_HISTORY_PATH`, `SAFARI_SYNC_STATE_DIR`, and `SAFARI_SYNC_SOCKET_PATH` before launching `SafariSyncAgent`. Keep the socket and state in a newly created temporary directory. Never run a copied-DB Agent concurrently with the installed Agent.

## Pull Request Expectations

Include:

- What changed
- Why it is useful
- Any Safari or Chromium API limitation involved
- How you tested it
- Whether live Safari files were touched

Avoid committing sealed state, delivery ledgers, Safari databases, browser profile files, or screenshots that reveal private URLs.

When changing setup behavior, verify Chrome-only, Edge-only, and both-browser selections. An unselected browser must not gain a Native Messaging directory or manifest. Use the app's **Set Up Extensions & Login…** screen for installation checks rather than introducing a second shell implementation.

## Integrated viewer validation

The Swift integration executable uses synthetic browser databases and exercises
the Collector, Reader, and (where loopback sockets are permitted) HTTP boundary.
The browser tests require a built Viewer and Web assets, and bind only to
`127.0.0.1:18766`:

```sh
swift build --product SafariSyncViewer
npm --prefix web run build
npm --prefix web test
```

The tests use synthetic data under the temporary directory. A sandbox that
forbids loopback sockets must grant the test process local bind permission for
the HTTP and Playwright checks. Do not point the test server at live history.

The opt-in process-lifetime tests must be run only while the installed Agent is
stopped. They start a debug Agent with an isolated temporary state directory,
synthetic history and a test-only secret; release builds cannot use that secret.
Build both executables first and provide their absolute paths as
`HISTORY_TEST_AGENT` and `HISTORY_TEST_VIEWER` when running
`SafariSyncCoreIntegrationTests`. The test also needs permission to bind a
loopback socket. It exercises interrupted collection, restart, owner death and
Viewer pipe closure without starting the installed app.
