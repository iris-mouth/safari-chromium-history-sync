# Security

The Agent handles private browser history on the Mac. The optional Web Viewer serves
the collected history over HTTPS to the configured Tailscale user.

## Sensitive data

These files contain private browsing data. SQLite journals can contain it too.

- `~/Library/Application Support/Safari Chromium History Sync/state.sealed`
- `~/Library/Application Support/Safari Chromium History Sync/delivery-ledger.sqlite`
- `~/Library/Application Support/Safari Chromium History Sync/Viewing/history.sqlite`
- `~/Library/Safari/History.db`
- A selected Chrome or Edge profile's `History` and `Favicons` databases

The viewing database contains URLs, titles, and icons in ordinary SQLite.
Reports can use synthetic rows or a schema-only fixture.

## Access boundaries

- Grant Full Disk Access to `/Applications/Safari Chromium History Sync.app`.
  The embedded Agent reads the selected browser databases and writes Safari
  visits when syncing. [Parent-only access validation](docs/validation/extension-632.md).
- The Bridge and Menu authenticate to the Agent over a mode-`0600` Unix socket.
  The Agent checks the caller's role, HMAC, and nonce. The IPC key in
  `ipc.secret` has mode `0600`, so this boundary trusts the current macOS user.
- The Agent seals its sync state with AES-GCM using its Keychain root secret.
- Safari history sync is intentionally narrow and insert-only.
- Incompatible runtime requirements, database structures, and sync-generation state fail closed. Unknown OS/Safari builds or binary hashes alone do not block use.
- Tested and compatible-but-unverified environments are distinguished in diagnostics. Structural compatibility does not prove unchanged Safari/iCloud semantics. See [compatibility policy](docs/COMPATIBILITY.md).
- Browser extension permissions are limited to history, storage, alarms, and native messaging.
- The gateway accepts forwarded connections from the signed Tailscale App Store
  network extension. It checks the kernel-reported sender, looks up the forwarded
  peer's Tailscale identity, and requires the configured owner. It obtains the
  TLS certificate in memory and proxies requests over a private Unix socket to
  the sandboxed, read-only Viewer.

## Reporting

Open a GitHub issue with a minimal reproduction that avoids private URLs when possible. If a private sample is required, describe the shape of the data instead of posting the raw file.
