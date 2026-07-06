# Contributing

Contributions should keep the project local, inspectable, and reversible.

## Setup

Load the extension unpacked, run `./setup.sh`, then reload the extension from `chrome://extensions`.

Run checks before opening a PR:

```sh
./scripts/check.sh
./doctor.sh
```

## Testing Safely

Do not test new Safari write behavior against your live Safari files first.

Use copied files:

```sh
mkdir -p /tmp/safari-sync-test
cp ~/Library/Safari/Bookmarks.plist /tmp/safari-sync-test/Bookmarks.plist
sqlite3 ~/Library/Safari/History.db ".backup '/tmp/safari-sync-test/History.db'"

SAFARI_SYNC_STATE_DIR=/tmp/safari-sync-test/state \
SAFARI_BOOKMARKS_PATH=/tmp/safari-sync-test/Bookmarks.plist \
SAFARI_HISTORY_PATH=/tmp/safari-sync-test/History.db \
./run.sh
```

Then validate the copied plist with `plutil` and the copied history database with `sqlite3`.

## Pull Request Expectations

Include:

- What changed
- Why it is useful
- Any Safari or Chromium API limitation involved
- How you tested it
- Whether live Safari files were touched

Avoid committing logs, state files, Safari backups, browser profile files, or screenshots that reveal private URLs.
