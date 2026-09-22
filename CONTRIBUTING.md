# Contributing

Contributions should keep the project local, inspectable, and reversible.

## Setup

Build the app, load the extension unpacked, and install a manifest only for the browser under test. Do not enable the Agent until the legacy writer is stopped.

Run checks before opening a PR:

```sh
./scripts/check.sh
./doctor.sh
```

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
