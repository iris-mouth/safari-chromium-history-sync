# Safari Chromium History Sync

Sync new visits between Safari and one Google Chrome or Microsoft Edge profile
on your Mac. The development build also lets you collect and search the history
in those browsers while browser sync is off.

## Download the sync-only release

The published v6.1.4 prerelease (build 614) runs on Apple silicon Macs with
macOS 26.6.2 or later. This release has an English interface.
[Download v6.1.4](https://github.com/iris-mouth/safari-chromium-history-sync/releases/tag/v6.1.4).

Download the `.pkg` installer and `SHA256SUMS.txt` into the same folder and check the download.

```sh
shasum -a 256 -c SHA256SUMS.txt
```

The installer is unsigned and the apps are ad-hoc signed, without Apple
notarization. See the [release notes](docs/RELEASE-v6.1.4.md) before installing.

## Set up the development build

1. Quit the menu app before upgrading. Install the development PKG. It places
   **Safari Chromium History Sync.app** in `/Applications` with its helpers inside.
2. Open **Safari Chromium History Sync**, then open **Settings… → General**.
3. Select Chrome Stable, Edge Stable, or both, then click **Register and open extension pages**.
4. Setup opens each selected browser's extensions page and reveals the bundled
   `ChromiumExtension` folder. Enable **Developer mode**, choose **Load unpacked**,
   and select that folder. On an upgrade, reload the existing extension.
5. Approve **Open at Login** if requested. Grant **Full Disk Access** only to
   **Safari Chromium History Sync.app**. **Show App for Full Disk Access**
   reveals the app to authorize. A new ad-hoc signature can require re-registration.
6. In **Settings… → History Collection**, select the Chrome or Edge profile and
   enable collection. In **Browser Sync**, choose **Connect Selected Profile**.
   If the first scan is waiting for the database, quit the selected browser
   once and choose **Collect History Now**. After that scan the extension can
   report new visits while the browser is open.
7. To sync new visits between browsers, stop any legacy Python writer, wait for
   both initial collections to finish, then enable **Browser Sync**.

## Use the menu

Click the menu bar icon to check **History Collection**, **Browser Sync**, and
**Web Viewer**. Collection shows each source's last successful scan and when the
Chromium extension last reported a visit. The Viewer reports readiness on the
Mac. Open its HTTPS address on another device to check access from that device.
When a section needs attention, choose its recovery action or open its settings.

- **Collect History Now** refreshes Safari and the selected Chromium profile.
  Pausing collection also pauses browser sync. Changing the profile removes the
  previous profile's collected records and cancels its pending deliveries after confirmation.
  The original browser histories and the collected Safari records are preserved.
- **Open History** opens the Viewer in your browser. Quitting the menu app stops
  collection, sync, and the Viewer.
- For delivery diagnostics or optional automatic Safari sync assistance, open
  **Settings… → Browser Sync**. Assistance uses a dedicated tab, requires Safari
  Automation permission, and creates a visit to the helper page.

To send new visits to your iPhone or iPad, use the matching browser account
and enable its built-in history sync on each device. Check the receiving
device's history to confirm arrival.

## Open the Viewer over Tailscale

In **Settings… → Web Viewer**, enter your Tailscale login and HTTPS root URL
and enable the Viewer. The gateway checks the Tailscale identity and serves
HTTPS on that hostname. Check the existing Serve mapping before assigning a
dedicated port to the gateway.

```sh
tailscale serve status
tailscale serve --bg --proxy-protocol=2 --tcp=443 tcp://127.0.0.1:8767
```

Open the HTTPS root in a new tab on a device signed in as that Tailscale user.
The Viewer starts on the most recent visit date in Tokyo time, or today if the
history is empty. Edit the start date, end date, and optional keywords, then
choose **Search**. An empty date leaves that boundary open; both empty dates
search all history. Each date has its own Previous, Today, and Next controls.
A field’s × clears that condition and searches with all the currently entered
values. The address stays at `/`. Back, Forward, and Reload restore only the
applied conditions in the same tab; unsubmitted edits are discarded.
Set the language for each browser in the Viewer.

**日本語**　メニューバーのアイコンから収集・同期・Viewer の状態を確認できます。
閲覧だけならブラウザ間同期はオフのまま使えます。Viewer は開始日・終了日・
キーワードを編集して「検索」で反映します。空の日付は制限なし、両方空なら全期間です。
欄内の×はその条件を解除し、現在の入力条件すべてで検索します。日付は東京時間です。

## Limits

- Only new visits are synced, with one active Chrome/Edge profile at a time.
  Existing history, deletions, bookmarks, Reading List, and tabs are not synced.
- Safari visits added to Chrome/Edge use the delivery time rather than the
  original visit time.
- This is experimental software. Compatibility checks do not guarantee cloud
  delivery. See [supported conditions and validation](docs/COMPATIBILITY.md).

## More information

- [Build and contribute](CONTRIBUTING.md)
- [Architecture and sync behavior](docs/ARCHITECTURE.md)
- [Mac and iPhone validation records](docs/INTEGRATION-IMPLEMENTATION-STATUS.md)
- [Security and handling private history](SECURITY.md)

Derived from [brycemcole/chrome-to-safari-sync](https://github.com/brycemcole/chrome-to-safari-sync).
Licensed under [MIT](LICENSE).
