# Architecture

Safari Sync has two pieces:

- `background.js`: the Manifest V3 service worker that observes Chromium state and talks to the native host.
- `safari_sync.py`: the native messaging host that reads and writes Safari local data.

The browser extension cannot access Safari files directly. The native host cannot use Chromium extension APIs directly. Native messaging is the boundary between them.

## Data Flow

Chromium to Safari:

1. The service worker snapshots bookmarks, Reading List, tab groups, open tabs, and history.
2. It normalizes URLs and compares them with the previous Chromium snapshot in extension storage.
3. It sends `add`, `remove`, `reorder`, and `history_add` messages to the native host.
4. The native host updates `Bookmarks.plist` or inserts history visits into `History.db`.

Safari to Chromium:

1. The native host polls Safari bookmarks and history.
2. It snapshots Safari bookmarks into canonical paths: `BAR` for Favorites and `OTHER` for regular bookmarks.
3. It sends new Safari items back to the extension.
4. The extension applies them with Chromium bookmark, Reading List, or history APIs.

## Canonical Paths

The native host and extension share two logical roots:

- `BAR`: Safari Favorites / Chromium Bookmarks Bar
- `OTHER`: Safari regular bookmarks / Chromium Other Bookmarks

Generated folders such as `Open Tabs` and `Tab Groups` are skipped when walking Safari back toward Chromium so generated mirrors do not become normal bookmarks.

## URL Identity

The sync logic normalizes URLs before comparing them. It lowercases scheme and host, strips default ports, removes fragments, trims trailing slashes, and drops common tracking parameters. This prevents most accidental duplicates from URLs that point at the same page.

Do not broaden normalization casually. Over-aggressive normalization can merge distinct pages.

## History

Chromium to Safari history sync writes directly to Safari's `History.db`. It inserts history items if needed, inserts a visit row, increments visit counts, and advances Safari's history generation metadata.

Safari to Chromium history sync is best-effort. Chromium's `chrome.history.addUrl` records a visit at the time the extension receives it, so old Safari visit timestamps cannot be preserved in that direction.

## State

Runtime state lives in:

```text
~/Library/Application Support/Safari Sync
```

`state.json` stores sent Safari URLs, folder order snapshots, history cursors, and recent echo-suppression keys. `sync.log` stores operational logs and can contain private URLs.

## Extension UI

- `popup.html`, `popup.css`, `popup.js`: status, pause/resume, manual sync, and recent activity.
- `options.html`, `options.css`, `options.js`: sync direction and feature toggles.

The UI talks only to the service worker through `chrome.runtime.sendMessage`.

## Adding a Browser

To add another Chromium-family browser, add its native messaging host directory to `HOST_DIRS` in `setup.sh` and `doctor.sh`. The extension code should not need browser-specific branches unless that browser uses unusual bookmark root titles or disables APIs.
