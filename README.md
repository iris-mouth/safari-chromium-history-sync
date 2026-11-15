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

## Install

1. Install the PKG. It places the app and its Agent in `/Applications`.
2. Open **Safari Chromium History Sync**, then choose **Set Up Extensions & Login…
   → Start Setup**.
3. Select Chrome Stable, Edge Stable, or both.
4. Setup opens each selected browser's extensions page and reveals the bundled
   `ChromiumExtension` folder. Enable **Developer mode**, choose **Load unpacked**,
   and select that folder.
5. Approve **Open at Login** if requested. Grant **Full Disk Access** only to
   **Safari Chromium History Sync Agent.app**.
6. If several browser profiles connect, choose the one to sync with Safari.
   A single connected profile is selected automatically.

When upgrading, quit the menu app, install the new PKG, reopen the app, and reload
its unpacked browser extension. macOS may ask you to restore the Agent's existing
permissions. Stop the legacy Python writer before using version 6.

## Use

- **View Sync Status…** shows the active browser and pending deliveries.
- **Choose Browser to Sync…** switches the active browser profile.
- **Configure Safari Sync Assist…** enables automatic help for pending Safari
  sync using a dedicated tab. This requires Safari Automation permission and
  creates real browsing history for the helper page.
- **Troubleshooting** contains compatibility checks, recovery options, and
  detailed diagnostics.

For history to reach your iPhone or iPad, enable the browser's built-in history
sync and use the matching account on each device. Arrival can take time; check
the receiving device's history to confirm it. The Mac's status alone does not
prove arrival.

## Integrated viewer in the development build

The development PKG adds a separate history collector and Web viewer; these are
not included in the v6.1.4 release linked above. Grant Full Disk Access to
**Safari Chromium History Sync Agent.app**, then use **Configure History
Collection…** to choose the Safari, Chrome and Edge profiles to collect. These
selections are independent of the single browser profile used for sync. Pausing
collection keeps the collected records; removing a source removes its records
from the viewer, without deleting the browser's history.

In **Configure Web Viewer…**, enable the viewer and enter your Tailscale login
and the HTTPS root URL for this Mac's Tailscale name. Configure Tailscale Serve
to forward that URL to the local viewer on `127.0.0.1:8766`. For example, when
HTTPS port 443 is available or you have deliberately chosen to replace its
existing mapping:

```sh
tailscale serve status
tailscale serve --bg --https=443 http://127.0.0.1:8766
```

Connect the other device to Tailscale using the same account, then open the
configured HTTPS URL. The viewer accepts requests for the configured Tailscale
login. **Open History on the Web** opens that URL on the Mac. Sync, collection
and the viewer have separate controls; quitting the menu app stops its Agent
and viewer. The app can be configured to start again at login.

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
