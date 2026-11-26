# Security

The app handles private browser history. Its files under
`~/Library/Application Support/Safari Chromium History Sync/`, browser databases,
and SQLite journals can contain URLs, titles, icons, or delivery records.
The viewing database is ordinary SQLite, not encrypted by this app. Sync state
is encrypted using a Keychain secret; this does not encrypt the viewing database.

Grant Full Disk Access to the parent app only. The embedded Agent reads browser
databases and writes Safari visits when browser sync is enabled. The separate,
sandboxed Viewer reads only collected data. Local IPC trusts the current macOS
user; it is not a boundary against other programs running as that user.

The HTTPS gateway requires the configured Tailscale identity. Its local health
check does not verify access from another device. Compatibility checks likewise
do not prove that Safari or Chromium delivered history through its cloud service.

For a report, provide a minimal reproduction with synthetic URLs and sanitized
status messages. Do not attach browser databases, sealed state, delivery ledgers,
account identifiers, or screenshots containing private history. Describe the data's
shape when an issue cannot be reproduced with a synthetic sample.
