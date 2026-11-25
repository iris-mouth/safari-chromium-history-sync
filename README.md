# Safari Chromium History Sync

Sync **new browsing history** between Safari and one active Google Chrome or
Microsoft Edge profile on your Mac. Other devices receive history through each
browser's built-in account sync.

The development tree also contains an integrated history viewer. Its current
scope and outstanding validation are tracked in
[the integration status](docs/INTEGRATION-IMPLEMENTATION-STATUS.md). The release
linked below remains the previously published sync-only version.

## Download

[Download v6.1.4 / build 614](https://github.com/iris-mouth/safari-chromium-history-sync/releases/tag/v6.1.4)
— experimental prerelease for **Apple silicon Macs running macOS 26.6.2 or later**.
The app's interface is in English.

Download the `.pkg` installer and `SHA256SUMS.txt` into the same folder, then verify:

```sh
shasum -a 256 -c SHA256SUMS.txt
```

The installer is unsigned and the apps are ad-hoc signed, without Apple
notarization. See the [release notes](docs/RELEASE-v6.1.4.md) before installing.

## Install the development build

1. Install the PKG. It places one app in `/Applications`, with internal helpers.
2. Open **Safari Chromium History Sync**, then open **Settings… → General**.
3. Select Chrome Stable, Edge Stable, or both, then click **Register and open extension pages**.
4. Setup opens each selected browser's extensions page and reveals the bundled
   `ChromiumExtension` folder. Enable **Developer mode**, choose **Load unpacked**,
   and select that folder.
5. Approve **Open at Login** if requested. Grant **Full Disk Access** only to
   **Safari Chromium History Sync.app**.
6. In the development build, select a profile under **Settings… → History Collection**, enable collection, then choose **Browser Sync → Connect Selected Profile**. After initial collection completes, enable browser sync if desired.

When upgrading, quit the menu app, install the new PKG, reopen the app, and reload
its unpacked browser extension. macOS may ask you to restore the parent app's Full Disk Access registration after its ad-hoc signature changes. Stop the legacy Python writer before using version 6.

## Use

- **View Status** shows history collection, the Web Viewer, and browser sync. **Open History** opens the configured Viewer.
- **Collect Now** refreshes the two selected sources. **Settings… → History Collection** changes the Chromium profile.
- **Settings… → Browser Sync → Enable automatic sync assist in a dedicated tab** enables automatic help for pending Safari
  sync using a dedicated tab. This requires Safari Automation permission and
  creates real browsing history for the helper page.
- **Settings… → General** shows compatibility and offers recovery when an issue is detected. Detailed diagnostics are in **Browser Sync**.

For history to reach your iPhone or iPad, enable the browser's built-in history
sync and use the matching account on each device. Arrival can take time; check
the receiving device's history to confirm it. The Mac's status alone does not
prove arrival.

## Integrated viewer in the development build

The development PKG adds a separate history collector and Web viewer; these are
not included in the v6.1.4 release linked above. Grant Full Disk Access to
**Safari Chromium History Sync.app**, then use **Settings… → History Collection** to collect Safari and one Chrome or Edge profile. The Agent routes new visits from this database when browser sync is enabled. Pausing collection also pauses sync. Switching profiles removes the previous Chromium records from the Viewer and cancels pending deliveries after confirmation. Browser history and Safari’s collected records are preserved.

**Show App for Full Disk Access** reveals the parent app to authorize. Separate permission for the embedded Agent is unnecessary on the validated Mac. While Chrome or Edge holds an exclusive database lock, existing records remain visible; connect the selected profile’s extension for new visits while the browser is open.

Enable the viewer in **Settings… → Web Viewer** with the owner's Tailscale login and the HTTPS root URL. The gateway obtains a certificate for that host and checks the forwarded client identity with Tailscale. For a dedicated HTTPS port, configure raw TCP forwarding with PROXY protocol v2. Check the existing mapping before replacing it.

```sh
tailscale serve status
tailscale serve --bg --proxy-protocol=2 --tcp=443 tcp://127.0.0.1:8767
```

Open the HTTPS URL from a device signed in as the configured Tailscale owner. The viewer's language selector applies to the current browser. Closing the menu app stops the gateway, viewer and Agent.

**日本語**　更新前にメニューから終了し、インストール後に本体を開いてください。フルディスクアクセスは親アプリに許可します。内蔵 Agent への個別許可は不要です。設定した各プロフィールで拡張を再読み込みしてください。「設定… → Web Viewer」でログイン名と HTTPS URL を保存します。指定した Tailscale アカウントで接続すると、ブラウザから直接履歴を開けます。日付の基準は日本語・英語ともに東京です。

## Limits

- Only new visits are synced, with one active Chrome/Edge profile at a time.
  Existing history, deletions, bookmarks, Reading List, and tabs are not synced.
- Safari visits added to Chrome/Edge use the delivery time rather than the
  original visit time.
- This is experimental software. Compatibility checks do not guarantee cloud
  delivery. See [supported conditions and validation](docs/COMPATIBILITY.md).

## More information

- [Release notes and upgrade details](docs/RELEASE-v6.1.4.md)
- [Build and contribute](CONTRIBUTING.md)
- [Architecture and sync behavior](docs/ARCHITECTURE.md)
- [Security and handling private history](SECURITY.md)

Derived from [brycemcole/chrome-to-safari-sync](https://github.com/brycemcole/chrome-to-safari-sync).
Licensed under [MIT](LICENSE).
