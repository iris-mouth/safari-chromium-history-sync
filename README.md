# Safari Chromium History Sync

Safari Chromium History Sync keeps **new** history visits synchronized in both directions between Safari and exactly one active Google Chrome Stable or Microsoft Edge Stable profile on macOS. Safari remains the iCloud path to iPhone and iPad.

Version 6 is a history-only rewrite. It intentionally does not sync bookmarks, Reading List, tabs, tab groups, deletions, or old history. It does not use Chrome as an Edge hub. A Safari visit delivered to Chrome/Edge is a new delivery-time visit because Chromium cannot preserve an external visit timestamp.

## Download

[Download v6.0.0 and read the release notes](https://github.com/iris-mouth/safari-chromium-history-sync/releases/tag/v6.0.0).

This is an **experimental prerelease for Apple silicon Macs**, requiring macOS 26.6.2 or later and a compatible Safari history database. OS/Safari version changes alone do not block synchronization. The app distinguishes **tested environments** from **compatible, unverified environments** in its Compatibility diagnostics. Intel binaries are not included.

Download `Safari-Chromium-History-Sync-v6.0.0-arm64.pkg` and `SHA256SUMS.txt` into the same folder. To check the download, run `shasum -a 256 -c SHA256SUMS.txt` from that folder, then follow the installation steps below.

The PKG is unsigned and the apps are ad-hoc signed, without Developer ID signing or Apple notarization. macOS may block installation or first launch. If you trust this release, follow [Apple's instructions for opening an app from an unidentified developer](https://support.apple.com/en-us/102445). This release has not been validated through a fresh download/install on a separate Mac.

## Safety and threat boundary

The installation contains two app bundles and three separately signed executables:

- `SafariSyncMenu`: menu UI and profile selection; no Full Disk Access.
- `Safari Chromium History Sync Agent.app`: an independent sibling app and the only process granted Full Disk Access; its internal executable remains `SafariSyncAgent` and it owns Safari DB access and durable state.
- `SafariSyncBridge`: Native Messaging stdin/stdout bridge; no Full Disk Access.

Bridge and Menu requests use role-bound HMAC authentication over a mode-`0600` Unix socket. The IPC key is a random mode-`0600` file owned by the current user; Bridge and Menu never access Keychain. This rejects malformed, unauthenticated, and replayed traffic, but it is not an identity boundary against other processes already running as the same macOS user: such a process can read the shared IPC key. Agent state, including URLs and recovery records, is sealed with AES-GCM using an Agent-only Keychain root secret. The extension requests only `history`, `storage`, `nativeMessaging`, and `alarms`.

The design protects against accidental cross-profile delivery, browser-sandbox callers without the native host connection, corrupted input, unsupported Safari database layouts, and processes belonging to another macOS user. It does not claim to protect history from an attacker who already controls the current macOS account. The fixed unpacked-extension key makes its extension ID stable for Native Messaging configuration; it identifies the extension origin but does not prove that unpacked source is trustworthy.

Compatibility is determined from runtime requirements, the structure of `history_items`, `history_visits`, and `metadata`, and valid sync-generation values. Unknown version numbers or history-service hashes do not prevent an otherwise compatible environment from running. Incompatible structures or state stop both directions and retain pending work.

Structural checks compare columns, types, defaults, keys, constraints, and table properties using SQLite metadata. Cosmetic SQL changes, column order, and ordinary nonunique index changes are allowed. A matching structure does not guarantee unchanged Safari/iCloud behavior or confirm iCloud arrival. See [the compatibility policy](docs/COMPATIBILITY.md) for the precise supported conditions.

The development reference is macOS 27.0 (26A428), Safari 22625.1.29.11.27. The revised build still needs an installed-app/end-to-end check before receiving a tested label; until then eligible environments are labeled compatible but unverified. Public release remains on hold for the reference-environment check, not for exhaustive testing of every OS version.

## Build

Requirements are Apple command-line build tools and Node.js for development tests. Python and Node.js are not runtime dependencies.

```sh
./scripts/check.sh
./scripts/package-app.sh
```

The packaging script creates both standalone app bundles and a payload-only PKG that installs both apps under `/Applications`. It contains no preinstall or postinstall scripts. It produces ad-hoc-signed app bundles and an unsigned local PKG. The unpacked extension keeps its fixed ID; store distribution, Developer ID signing, and notarization are outside this distribution.

## Install

1. Install the downloaded `Safari-Chromium-History-Sync-v6.0.0-arm64.pkg` (or `Safari-Chromium-History-Sync.pkg` from a local build). For a local development build, you may instead move both generated app bundles beside each other in `/Applications`.
2. Open **Safari Chromium History Sync** and choose **Start Setup**.
3. Select Chrome Stable, Edge Stable, or both. Setup writes a Native Messaging manifest only for browsers you explicitly select; it does not create files for an installed but unused browser.
4. Setup opens each selected browser's extensions page and reveals the bundled `ChromiumExtension` folder. Turn on Developer mode, choose **Load unpacked**, and select that folder. Extension and profile IDs are detected automatically; there is nothing to copy and paste.
5. Approve Open at Login if macOS requests it, then grant Full Disk Access to `/Applications/Safari Chromium History Sync Agent.app` only. Do not grant it to Chrome, Edge, the Menu app, or the Bridge.
6. If one browser profile connects, it becomes active automatically. If several connect, choose one in the setup window.

Setup is safe to run again. It checks the installed components and changes only product-owned settings for the selected browsers. Deselecting a browser removes only this product's matching manifest. The setup and diagnostics screen reports actionable problems instead of requiring command-line scripts.

Do not run version 6 beside the legacy Python writer. Setup reports known `com.local.safari_bookmark_sync` manifests or launch items and waits for you to remove them before synchronization starts.

## Runtime behavior

- Browser `onVisited` events only mark a URL dirty. A resolver reads the most recent 64 visits ordered by `visitTime DESC, visitId DESC`, then assigns durable random event IDs.
- Browser-to-Safari inserts run under `BEGIN IMMEDIATE`, use `origin=0`, advance `current_generation` from `max(current_generation,last_synced_generation)+1`, and never modify `last_synced_generation`.
- At UTC five-minute boundaries, a pending Safari upload launches Safari with `open -gj` only when Safari is stopped. The Agent never terminates Safari.
- Safari-to-browser delivery is globally single-flight. `chrome.history.addUrl` is followed by fresh `getVisits` evidence at cumulative 1/3/8/18/30-second deadlines.
- A confirmed Safari-imported Chromium visit becomes that URL's visit marker, so its `onVisited` callback is not echoed back to Safari; a later real visit remains eligible for sync.
- A delivery gets at most two immediate attempts. Unconfirmed outcomes enter the encrypted profile-scoped recovery ledger at 5m/15m/30m/2h/6h intervals, capped at 20 retries and retained when exhausted.
- Changing the active browser profile is immediate. Pending outbox and recovery work remains scoped to the profile that created it and resumes only when that profile is selected again; it is never moved to the new profile.
- Database replacement or an arrival-anchor mismatch stops scanning. The Menu can reset only the Safari arrival cursor after explicit confirmation; this advances to the current baseline while preserving the active profile, outbox, recovery work, and delivery ledger.
- If sealed Agent state is unreadable, the Menu can reset only `state.sealed` and its unresolved-count sidecar after warning that pending work and profile selection can be lost. Safari and Chromium history plus the delivery ledger are preserved. State reset is not offered when Keychain access itself is unavailable.

Runtime files live in `~/Library/Application Support/Safari Chromium History Sync` and can contain private browsing URLs. This release intentionally starts from a clean baseline rather than migrating the prior local state directory. Use **Setup & Diagnostics** in the Menu app to inspect the installation without exposing URLs.

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for protocol and failure semantics.

## Project lineage

This project is derived from [brycemcole/chrome-to-safari-sync](https://github.com/brycemcole/chrome-to-safari-sync) and retains its MIT license and Git history. Version 6 is a purpose-built history synchronization redesign.
