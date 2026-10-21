# Safari Chromium History Sync v6.1.4 / build 614 — Experimental prerelease

English menus and dialogs are restored, with clearer action names, a read-only
sync status window, and test-history and replay actions kept in detailed diagnostics.
Both app bundles and the bundled Chromium extension are version 6.1.4.

## Changes since v6.0.0

- Track local delivery, Safari's native sync progress, and user-reported
  receiving-device arrival separately. A checkpoint is not an iCloud receipt.
- Optional Safari Sync Assist reuses one dedicated tab to prompt native sync.
  Pending work retries automatically with a five-minute minimum, backing off to
  hourly attempts without the former six-attempt daily stop.
- Retain durable browser insertion evidence across lost acknowledgements and
  restarts. Cancel pending relay work when its owned history is removed, and
  invalidate old tests and replay plans after a declared account change.
- Fix reviewed database-replacement, cancellation, migration, and retry defects.
- Use **View Sync Status…** for daily checks and **Troubleshooting → Open
  Detailed Diagnostics…** for advanced tests. History-changing actions explain
  their destination and effect before confirmation.

## Download and install

1. Download `Safari-Chromium-History-Sync-v6.1.4-arm64.pkg` and `SHA256SUMS.txt`.
2. In the download folder, run `shasum -a 256 -c SHA256SUMS.txt` and confirm `OK`.
3. Install the PKG. It places **Safari Chromium History Sync.app** and **Safari
   Chromium History Sync Agent.app** beside each other under `/Applications`.
4. Open the app and choose **Set Up Extensions & Login… → Start Setup**. Select
   Chrome Stable, Edge Stable, or both; only one profile is active at a time.
5. On each selected browser's extensions page, enable Developer mode, choose
   **Load unpacked**, and select the revealed `ChromiumExtension` folder.
6. Approve Open at Login if requested. Grant Full Disk Access only to **Safari
   Chromium History Sync Agent.app**. Safari Sync Assist also needs the Agent's
   Safari Automation permission when enabled.

For an upgrade, quit the menu app before installing, then reopen it and reload
the existing unpacked extension to 6.1.4. The extension ID is unchanged. macOS may
ask again for Keychain access or require restoring the Agent's existing Full
Disk Access grant. If necessary, restart the sync service through setup after
restoring access.

The installer is unsigned and the apps are ad-hoc signed, without Developer ID
signing or Apple notarization. This is an experimental prerelease for Apple
silicon (arm64), requiring macOS 26.6.2 or later and a structurally compatible
Safari history database. Other eligible environments can run as
compatible-unverified. A fresh download/install on a separate Mac has not been
validated.

## Verification

JavaScript 42/42, Swift integration, and the real AppKit controller checks passed.
The PKG was fully expanded: both apps passed strict/deep signature checks, their
executables matched the built apps, the extension matched source, and no installer scripts
were present. This download is byte-for-byte the locally installed and verified
build 614 package, renamed for distribution.

On macOS 27.0.1 (26A434), Safari 22625.1.29.11.28, the Agent automatically reused
its dedicated Safari tab without manual Safari navigation. Safari's checkpoint
subsequently covered the test visit, and the user reported the new Safari and
Edge tests present on the receiving device. Both observations were recorded.
This is scoped, user-reported arrival evidence, not certification of all visits
or of both iPhone and iPad hardware separately. Runtime diagnostics remain
compatible-unverified.

See the [build 614 validation record](https://github.com/iris-mouth/safari-chromium-history-sync/blob/v6.1.4/docs/validation/build-614-english-ui.md)
and [reviewed recovery fixes](https://github.com/iris-mouth/safari-chromium-history-sync/blob/v6.1.4/docs/validation/build-613-review-fixes.md).

## Limitations and state compatibility

- Syncs new visits with one active Chrome/Edge profile; no old-history backfill,
  deletion propagation, bookmarks, Reading List, tabs, or tab groups.
- Chromium receives Safari history as new delivery-time visits. Original Safari
  visit times cannot be preserved through the public Chromium history API.
- Public browser interfaces provide no per-visit Google/Microsoft cloud commit
  receipt. Receiving-device history must be checked to confirm arrival.
- Sync Assist creates real browsing history for its dedicated control URLs;
  those URLs are excluded from the relay. It does not force or bypass cloud sync.
- Agent state migrates from schemas 1/2 to 3. Older Agents cannot read schema 3;
  preserve state and its unresolved-count sidecar before an intentional rollback.
  Resetting sync state can discard pending work. History databases are not
  rewritten by state migration. Stop the legacy Python writer before setup.

Read the [README](https://github.com/iris-mouth/safari-chromium-history-sync/blob/v6.1.4/README.md)
and [security documentation](https://github.com/iris-mouth/safari-chromium-history-sync/blob/v6.1.4/SECURITY.md)
before reporting issues involving private history.
