# Security

Safari Sync handles private browsing data locally. Reports involving data exposure, unsafe writes, or unexpected deletion should be treated as security-sensitive even though the project does not run a server.

## Sensitive Data

These files can contain private URLs, folder names, history, and open tabs:

- `~/Library/Application Support/Safari Sync/state.json`
- `~/Library/Application Support/Safari Sync/sync.log`
- `~/Library/Application Support/Safari Sync/backups/`
- `~/Library/Safari/Bookmarks.plist`
- `~/Library/Safari/History.db`

Do not attach those files publicly unless you have scrubbed them.

## Design Constraints

- The native host writes Safari's local files because Apple does not provide a supported public sync API for this use case.
- Safari history sync is intentionally narrow and insert-only.
- Browser extension permissions are broad because bookmarks, history, tabs, tab groups, Reading List, storage, alarms, and native messaging are all part of the sync surface.

## Reporting

Open a GitHub issue with a minimal reproduction that avoids private URLs when possible. If a private sample is required, describe the shape of the data instead of posting the raw file.
