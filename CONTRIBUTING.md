# Contributing

Contributions should keep the project local, inspectable, and reversible.

## Setup

Build the app, open it, and use **Start Setup** to select only the browser under test. Load the extension from the app's bundled `ChromiumExtension` folder. Do not start synchronization until the legacy writer is stopped.

Run checks before opening a PR:

```sh
./scripts/check.sh
```

`./scripts/package-app.sh` creates ad-hoc-signed app bundles and an unsigned, payload-only PKG for local testing. The PKG must continue to contain only the two sibling app bundles under `/Applications`; do not add installer scripts, store-distribution machinery, or user-specific Native Messaging files to it.

## Testing Safely

Do not test new Safari write behavior against live Safari history first. The Swift integration executable creates an exact-schema temporary SQLite database and exercises the public Agent interfaces:

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

When changing setup behavior, verify Chrome-only, Edge-only, and both-browser selections. An unselected browser must not gain a Native Messaging directory or manifest. Use the app's **Setup & Diagnostics** screen for installation checks rather than introducing a second shell implementation.
