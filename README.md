# Safari Bookmark Sync

Local bookmark sync for Safari and Chromium-based browsers on macOS.

This is an unpacked Manifest V3 extension plus a small native messaging host. It watches Chromium bookmarks, Safari's bookmark plist, tab groups, and open tabs, then reconciles them into a shared bookmark structure.

It is not a Chrome Web Store extension and it does not use a cloud service.

## What It Syncs

- Safari bookmarks <-> Chromium bookmarks
- Safari Favorites <-> Chromium Bookmarks Bar
- Safari regular bookmarks <-> Chromium Other Bookmarks
- Chromium tab groups -> Safari folders under `Tab Groups`
- Chromium open tabs -> Safari folders under `Open Tabs / <Browser>`

`Open Tabs` and `Tab Groups` are generated Safari folders. They are intentionally not pushed back into Chromium as normal bookmarks.

## Supported Browsers

The installer includes native messaging paths for:

- Google Chrome
- Google Chrome Beta
- Google Chrome Canary
- Chromium
- Brave
- Microsoft Edge
- Arc
- Helium

Other Chromium browsers may work if you add their native messaging host directory to `setup.sh`.

## Requirements

- macOS
- Safari
- Python 3
- Node.js only for development checks
- A Chromium-based browser with unpacked extension support and native messaging

## Install

Clone the repo:

```sh
git clone https://github.com/brycemcole/chrome-to-safari-sync.git
cd chrome-to-safari-sync
```

Load the extension:

1. Open `chrome://extensions` in your Chromium browser.
2. Enable Developer Mode.
3. Click **Load unpacked**.
4. Select this repository directory.
5. Copy the extension ID shown by the browser.

Install the native messaging host:

```sh
./setup.sh
```

Paste the extension ID when prompted, then reload the extension from `chrome://extensions`.

## Files It Touches

Safari stores bookmarks here:

```text
~/Library/Safari/Bookmarks.plist
```

The native host reads and writes that file. Before each write, it saves a backup next to the original plist.

Runtime state is stored beside the scripts by default:

```text
state.json
sync.log
```

These files contain private URLs and are ignored by Git.

## Configuration

Most installs do not need configuration. The native host supports these environment variables:

```sh
SAFARI_SYNC_STATE_DIR=/path/to/state
SAFARI_BOOKMARKS_PATH=/path/to/Bookmarks.plist
```

## Notes

- This cannot publish Chromium tabs into Safari's real iCloud Tabs UI. Apple does not expose an API for that.
- Duplicate copies of the same URL are usually treated as one bookmark. Generated tab mirrors and tab-group folders intentionally allow duplicates.
- If a browser is open while you edit native messaging setup, reload the extension afterward.
- If Chromium refuses to load the unpacked extension because of `__pycache__`, remove that directory from the repo root.

## Development

Syntax checks:

```sh
node --check background.js
python3 - <<'PY'
import ast
ast.parse(open("safari_sync.py").read())
print("python syntax ok")
PY
```

Avoid `python -m py_compile` in the extension root; it creates `__pycache__`, and Chromium rejects unpacked extensions containing that directory.

## Privacy

Do not commit runtime files. In particular:

- `state.json`
- `sync.log`
- Safari plist backups

They can reveal bookmark URLs, open tabs, folder names, and browsing history.
