# Safari Chromium History Sync

Safari Chromium History Sync keeps **new** history visits synchronized in both directions between Safari and exactly one active Google Chrome Stable or Microsoft Edge Stable profile on macOS. Safari remains the iCloud path to iPhone and iPad.

Version 6 is a history-only rewrite. It intentionally does not sync bookmarks, Reading List, tabs, tab groups, deletions, or old history. It does not use Chrome as an Edge hub. A Safari visit delivered to Chrome/Edge is a new delivery-time visit because Chromium cannot preserve an external visit timestamp.

## Safety boundary

The installation contains two app bundles and three separately signed executables:

- `SafariSyncMenu`: menu UI and profile selection; no Full Disk Access.
- `SafariSyncAgent.app`: an independent sibling app and the only process granted Full Disk Access; owns Safari DB access and durable state.
- `SafariSyncBridge`: Native Messaging stdin/stdout bridge; no Full Disk Access.

Bridge and Menu requests use role-bound HMAC authentication over a mode-`0600` Unix socket. The IPC key is a random mode-`0600` file owned by the current user; Bridge and Menu never access Keychain. Agent state, including URLs and recovery records, is sealed with AES-GCM using an Agent-only Keychain root secret. The extension requests only `history`, `storage`, `nativeMessaging`, and `alarms`.

The writer fails closed outside the qualified tuple:

- macOS 26.6.2 (25G83)
- Safari 21624.5.1.11.3
- the qualified `com.apple.Safari.History` binary hash
- the exact tested `history_items`, `history_visits`, and `metadata` schema

## Build

Requirements are Apple command-line build tools and Node.js for development tests. Python and Node.js are not runtime dependencies.

```sh
./scripts/check.sh
./scripts/package-app.sh
```

For Developer ID signing and notarization:

```sh
CODESIGN_IDENTITY='Developer ID Application: …' \
NOTARY_PROFILE='notary-profile' \
./scripts/package-app.sh
```

Without `CODESIGN_IDENTITY`, packaging uses an ad-hoc signature for local development only.

## Install

1. Build the apps and move both `dist/Safari Chromium History Sync.app` and `dist/SafariSyncAgent.app` to `/Applications`.
2. Load this repository as an unpacked extension in Chrome Stable and/or Edge Stable.
3. Install only the required Native Messaging manifests:

   ```sh
   ./setup.sh --chrome-id aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
              --edge-id bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb \
              --app '/Applications/Safari Chromium History Sync.app'
   ```

4. Open the Menu app and choose **Enable Agent**. This registers the Menu app as a login item and launches the sibling Agent. At login, the Menu app launches the Agent automatically.
5. Grant Full Disk Access to `/Applications/SafariSyncAgent.app` only. Do not grant it to Chrome, Edge, the Menu app, or the Bridge.
6. Use the menu to choose the single active profile. A switch does not complete until the old extension acknowledges its freeze.

Do not install version 6 beside the legacy Python writer. Remove the old `com.local.safari_bookmark_sync` manifests before enabling the Agent.

## Runtime behavior

- Browser `onVisited` events only mark a URL dirty. A resolver reads the most recent 64 visits ordered by `visitTime DESC, visitId DESC`, then assigns durable random event IDs.
- Browser-to-Safari inserts run under `BEGIN IMMEDIATE`, use `origin=0`, advance `current_generation` from `max(current_generation,last_synced_generation)+1`, and never modify `last_synced_generation`.
- At UTC five-minute boundaries, a pending Safari upload launches Safari with `open -gj` only when Safari is stopped. The Agent never terminates Safari.
- Safari-to-browser delivery is globally single-flight. `chrome.history.addUrl` is followed by fresh `getVisits` evidence at cumulative 1/3/8/18/30-second deadlines.
- A confirmed Safari-imported Chromium visit becomes that URL's visit marker, so its `onVisited` callback is not echoed back to Safari; a later real visit remains eligible for sync.
- A delivery gets at most two immediate attempts. Unconfirmed outcomes enter the encrypted profile-scoped recovery ledger at 5m/15m/30m/2h/6h intervals, capped at 20 retries and retained when exhausted.
- Database replacement or an arrival-anchor mismatch stops scanning. Resume from the current point only after explicit operator action.

Run `./doctor.sh` after installation. Runtime files live in `~/Library/Application Support/Safari History Sync` and can contain private browsing URLs. This legacy internal directory name is intentionally retained so upgrades keep the existing encrypted state and delivery ledger.

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for protocol and failure semantics.

## Project lineage

This project is derived from [brycemcole/chrome-to-safari-sync](https://github.com/brycemcole/chrome-to-safari-sync) and retains its MIT license and Git history. Version 6 is a purpose-built history synchronization redesign.
