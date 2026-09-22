# Security

Safari Chromium History Sync handles private browsing data locally. Reports involving data exposure, unsafe writes, or unexpected deletion should be treated as security-sensitive even though the project does not run a server.

## Sensitive Data

These files contain private history state:

- `~/Library/Application Support/Safari History Sync/state.sealed`
- `~/Library/Application Support/Safari History Sync/delivery-ledger.sqlite`
- `~/Library/Safari/History.db`

Do not attach those files publicly unless you have scrubbed them.

## Design Constraints

- Only `SafariSyncAgent` receives Full Disk Access and writes Safari's history database.
- The no-FDA Bridge and Menu authenticate to the Agent over a mode-`0600` Unix socket using a random owner-only mode-`0600` IPC key.
- Sensitive Agent state is sealed with AES-GCM using an Agent-only Keychain root secret; Bridge and Menu never access Keychain.
- Safari history sync is intentionally narrow and insert-only.
- Unknown OS, Safari, CloudHistory binary, and database-schema tuples fail closed.
- Browser extension permissions are limited to history, storage, alarms, and native messaging.

## Reporting

Open a GitHub issue with a minimal reproduction that avoids private URLs when possible. If a private sample is required, describe the shape of the data instead of posting the raw file.
