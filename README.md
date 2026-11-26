# Safari Chromium History Sync

Collect and search Safari history and one Chrome or Edge profile on your Mac.
View it from your iPhone over Tailscale, and optionally sync new visits between
the two browsers. Collection and viewing work while browser sync is off.

## Install

Download the installer and checksums from [GitHub Releases](https://github.com/iris-mouth/safari-chromium-history-sync/releases).
Release notes describe the supported environment, signing, and verification limits.
The current distribution requires an Apple silicon Mac with macOS 26.6.2 or later.

```sh
shasum -a 256 -c SHA256SUMS.txt
```

1. Quit History Sync before upgrading, install the PKG, then open
   **Safari Chromium History Sync.app** in `/Applications`.
2. In **Settings… → General**, select your browsers and choose
   **Register and open extension pages**. Enable **Developer mode**, choose
   **Load unpacked**, and select the revealed `ChromiumExtension` folder.
   Reload the existing extension after an upgrade.
3. Allow **Open at Login** if requested. Grant **Full Disk Access** to the parent
   **Safari Chromium History Sync.app** only. Use **Show App for Full Disk Access**
   to locate it; the embedded Agent needs no separate entry.
4. In **History Collection**, select a Chrome or Edge profile and enable
   collection. In **Browser Sync**, connect that profile. For a first scan waiting
   on the database, quit the selected browser once and choose **Collect History Now**.
5. Enable browser sync only if you want to copy new visits between browsers.
   Collection must be enabled and both initial scans must finish first.

If collection loses access after an upgrade, quit the app, remove its old Full
Disk Access entry, add the installed parent app again, and reopen it. Approve the
**SafariSyncAgent** Keychain request if macOS asks to read saved sync settings.

## Use

The menu shows **History Collection**, **Browser Sync**, and **Web Viewer**.
Select a status row to open its settings. Detailed status and manual collection
are in those tabs; shared access and service-restart controls are in **General**.
Quitting History Sync stops collection, sync, and the Viewer.

In **Web Viewer**, enter your Tailscale login and HTTPS root URL and enable it.
Check existing Serve mappings before assigning port 443:

```sh
tailscale serve status
tailscale serve --bg --proxy-protocol=2 --tcp=443 tcp://127.0.0.1:8767
```

Open the HTTPS root from a device signed in as that Tailscale user. Enter start
and end dates and optional keywords, then choose **Search**. Empty dates leave
those bounds open. A field's × clears it and applies the visible conditions.
Dates use Tokyo time. Mac and Web interfaces support Japanese and English.

**日本語**　メニューの収集・同期・Viewerの状態を選ぶと、対応する設定を開きます。
手動収集は収集タブ、権限確認とサービス再起動は一般タブにあります。
閲覧だけなら同期はオフで使えます。検索の日付は空欄なら制限なしです。

## Limits

- Browser sync copies new visits, not existing history, deletions, bookmarks, or tabs.
  Safari visits copied to Chromium use delivery time.
- Delete history in its source browser; the viewing database follows successful
  collection scans. Changing the selected profile removes its collected copies
  and cancels its pending deliveries after confirmation.
- iPhone history must first reach the Mac through the browser's own cloud sync.
  Collection does not force iCloud delivery. Local readiness does not prove
  receiving-device arrival.
- Pending-delivery login restoration remains tracked in
  [issue #2](https://github.com/iris-mouth/safari-chromium-history-sync/issues/2).

[Development](CONTRIBUTING.md) · [Private data and security](SECURITY.md)

Derived from [brycemcole/chrome-to-safari-sync](https://github.com/brycemcole/chrome-to-safari-sync).
Licensed under [MIT](LICENSE).
