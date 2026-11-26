# Safari Chromium History Sync v6.2.0 / build 635 — Experimental prerelease

History collection and Web viewing are now part of the Mac app. Collect Safari
and one Chrome or Edge profile, then browse and search from your iPhone or PC
through your own Tailscale account. Browser sync can stay off.

## Changes since v6.1.4

- One app in `/Applications`, with its Agent and read-only Viewer embedded.
  Grant Full Disk Access to the parent app only.
- A menu bar icon with separate collection, browser sync, and Viewer status;
  settings are edited in tabs. Mac and Web interfaces support Japanese and English.
- Visit-level collection follows browser deletions and late arrivals. Failed or
  incomplete reads retain the last successful data. Sync uses collected visits,
  requires collection, and does not backfill historical imports.
- A compact search form with independent start/end dates, optional keywords,
  and explicit Search. Blank dates leave bounds open; each × clears that field
  and applies the visible inputs. Dates use `YYYY-MM-DD` in Tokyo time.
- A fixed Viewer URL, IME-safe submission, stable pagination, and Back/Forward
  restoration. A later response does not overwrite newer edits.

## Install or upgrade

Download `Safari-Chromium-History-Sync-v6.2.0-arm64.pkg` and `SHA256SUMS.txt` to
the same directory, then run `shasum -a 256 -c SHA256SUMS.txt`.
Quit History Sync before installing, reopen it afterward, and follow the
[setup instructions](https://github.com/iris-mouth/safari-chromium-history-sync/blob/v6.2.0/README.md#set-up-the-app).
Reload the existing unpacked extension; its version is **6.2.0.632** and its ID
is unchanged. Menu and Viewer are build **635**; the embedded Agent's build
identifier remains **633**. All native app versions are **6.2.0**.

Upgrading from v6.1.4 changes Full Disk Access from the separate Agent app to
**Safari Chromium History Sync.app**. If an old permission entry does not match
the new signature, quit the app, remove that entry, add the installed parent
app again, and reopen it. Approve the Agent's Keychain request when prompted.
Collection and the Tailscale Viewer need configuration on a sync-only upgrade.

The PKG is unsigned; the apps are ad-hoc signed and not notarized. It targets
Apple silicon and requires macOS 26.6.2 or later with a compatible Safari history
database. The packaged app does not require Python or Node.js at runtime.

## Verification and limits

The distributed PKG is byte-for-byte the installed and verified candidate 635,
renamed for download. Its expanded app matches the installed app; deep signature
and installer-script checks passed. CI passed extension, Go gateway, Swift and
AppKit checks, builds, and 60 browser cases across WebKit and Chromium.

Mac Safari/Edge collection, normal HTTPS viewing, iPhone layout and operation,
and login restoration were checked. The initial 635 iPhone preview over Wi-Fi
measured date/search at **350/217 ms** for 100,000 synthetic visits and
**1,151/1,034 ms** for 1,000,000. These are single reports, not guaranteed limits.
[Full validation record](https://github.com/iris-mouth/safari-chromium-history-sync/blob/v6.2.0/docs/INTEGRATION-IMPLEMENTATION-STATUS.md).

Login restoration was tested with sync off and empty queues; pending-delivery
restoration is tracked in [issue #2](https://github.com/iris-mouth/safari-chromium-history-sync/issues/2).
Tailscale DNS briefly lagged behind login and recovered without intervention.
End-to-end cloud delivery on this release and installation on a separate clean
Mac remain unverified. Runtime diagnostics retain **compatible-unverified**.

Browser sync handles new visits only, with one Chrome/Edge profile. It does not
sync browser deletions, bookmarks, or tabs. Safari visits delivered to Chromium
use delivery time. iPhone history must first reach the Mac through the browser's
own cloud sync. No new iCloud receive-prompting mechanism was added.
See the [compatibility](https://github.com/iris-mouth/safari-chromium-history-sync/blob/v6.2.0/docs/COMPATIBILITY.md)
and [security](https://github.com/iris-mouth/safari-chromium-history-sync/blob/v6.2.0/SECURITY.md) notes.
