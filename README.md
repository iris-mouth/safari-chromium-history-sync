# Safari Chromium History Sync

Safari Chromium History Sync keeps **new** history visits synchronized in both directions between Safari and exactly one active Google Chrome Stable or Microsoft Edge Stable profile on macOS. Safari remains the iCloud path to iPhone and iPad.

Version 6 is a history-only rewrite. It intentionally does not sync bookmarks, Reading List, tabs, tab groups, deletions, or old history. It does not use Chrome as an Edge hub. A Safari visit delivered to Chrome/Edge is a new delivery-time visit because Chromium cannot preserve an external visit timestamp.

The working tree is **6.1.2 / build 612**, an unpublished development build adding persistent Safari Sync Assist retries without a daily stop. [Build 610 mobile arrival](docs/validation/build-610-arrival.md) and [build 611 recovery/arrival](docs/validation/build-611-assist.md) were confirmed by the user after manual Safari activity. Build 612's automatic retry behavior has its own [validation record](docs/validation/build-612-assist-retry.md) and remains compatible-unverified. The downloadable v6.0.0 release below does not include these features.

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

The historical tested reference for build 601 is macOS 27.0 (26A428), Safari 22625.1.29.11.27. See the [user-reported validation record](docs/validation/macos-27-build-601.md) for scope and limitations. Builds 610/611 have separate, narrowly scoped mobile-arrival records; build 612 retains the compatible-unverified label.

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
- An encrypted journal retains relay-owned local delivery receipts independently of stream ACKs. A 15-second monitor coalesces new Safari writes, observes matching rows and Safari's checkpoint, and launches stopped Safari with `open -gj` when due. Checks back off, with at most six launch attempts per rolling day and a five-minute launch cooldown. Running Safari is not restarted. Optional Safari Sync Assist can perform ordinary navigation in its dedicated helper tab when owned visits remain pending.
- Safari-to-browser delivery is globally single-flight. `chrome.history.addUrl` is followed by fresh `getVisits` evidence at cumulative 1/3/8/18/30-second deadlines.
- A confirmed Safari-imported Chromium visit becomes that URL's visit marker, so its `onVisited` callback is not echoed back to Safari; a later real visit remains eligible for sync.
- Browser insertion intents and exact local receipts are saved before the writer/ACK respectively. Explicit removal cancels owned pending imports and suppresses replay; removal timestamps prevent delayed notifications from cancelling later explicit attempts. This is cancellation of relay work, not cross-browser deletion synchronization.
- A delivery gets at most two immediate attempts. Unconfirmed outcomes enter the encrypted profile-scoped recovery ledger at 5m/15m/30m/2h/6h intervals, capped at 20 retries and retained when exhausted.
- Changing the active browser profile is immediate. Pending outbox and recovery work remains scoped to the profile that created it and resumes only when that profile is selected again; it is never moved to the new profile.
- Database replacement or an arrival-anchor mismatch stops scanning. The Menu can reset only the Safari arrival cursor after explicit confirmation; this advances to the current baseline while preserving the active profile, outbox, recovery work, and delivery ledger.
- If sealed Agent state is unreadable, the Menu can reset only `state.sealed` and its unresolved-count sidecar after warning that pending work and profile selection can be lost. Safari and Chromium history plus the delivery ledger are preserved. State reset is not offered when Keychain access itself is unavailable.

Runtime files live in `~/Library/Application Support/Safari Chromium History Sync` and can contain private browsing URLs. This release intentionally starts from a clean baseline rather than migrating the prior local state directory. Use **Setup & Diagnostics** in the Menu app to inspect the installation without exposing URLs.

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for protocol and failure semantics.

## Account sync and arrival checks

Open **Account Sync & Arrival Checks…** from the menu. Local delivery, Safari checkpoint progress, and receiving-device observations are shown separately. Public Chrome/Edge history interfaces do not expose per-visit account commit receipts; those deliveries remain unverified until receiver evidence is supplied. No direct account upload or automatic browser sign-in/settings changes are performed.

- **Check Safari Arrival** or **Check Chrome/Edge Arrival** adds a unique probe through the normal writer. Search that receiving browser's History on iPhone/iPad without opening the probe URL first, then record Seen or Not Observed. A probe confirms only itself. Reload the bundled extension after upgrading so it advertises cloud receipt support.
- **Enable Safari Sync Assist…** opts in to reuse one dedicated Safari helper tab/window. After 90 seconds of pending owned work, the Agent alternates two owned `example.com` control URLs in that tab to perform ordinary navigation. With no checkpoint progress, automatic attempts back off through 5, 10, 20, 40, then 60 minutes and continue hourly while eligible work remains, without a daily ceiling. Native progress or a resolved backlog followed by new work resets the backoff, always respecting a five-minute minimum. Hidden Safari launches use the same retry schedule; neither restarting nor toggling resets it. The new helper window is hidden; other user tabs are not changed. These are real navigations and history entries and can sync to other devices. Both helper URLs are excluded from Safari→Edge/Chrome relay. Grant Safari Automation permission when macOS asks. Denial disables navigation until explicitly enabled again; Disable Safari Sync Assist stops future navigations. Native throttling can still delay delivery. Account Sync shows the next automatic attempt.
- **Compare Safari Export…** accepts a supported Safari `History.json` from the receiving device (up to 32 MiB). The Menu filters it to owned URLs and passes bounded snapshots to the Agent. Only unique exact URL/latest-visit-time matches are confirmed; absent, older repeated, or ambiguous entries remain unverified.
- **Review Replay…** presents one selected URL, route, and profile. Confirm the intended account and enabled history sync before executing. Replay creates a new visit at the current time, with a distinct attempt ID; repeated execution of the same plan does not create another visit. Deleted/changed visits and expired/rebound plans cannot be replayed.
- **Rebind Account…** records a user-declared account change and invalidates prior repair plans and pending probes/replays for that binding. Account identity changes cannot be detected automatically through the public history interface.

Detailed applied records are retained for seven days, bounded to 4096 entries; live unapplied intents are preserved. A full journal backpressures new delivery and is visible in diagnostics. Old evidence expires as unverified, never as successful. Diagnostics are paged. This feature does not compare every cloud record, and Safari's checkpoint does not prove a particular iCloud/iPhone arrival. Safari Sync Assist requests native activity; it does not bypass throttling or directly acknowledge/upload any cloud record.

Agent state migrates from schemas 1/2 to 3 without inferring old cloud receipts. An older Agent cannot read schema 3. Preserve `state.sealed` and its sidecar before an intentional rollback; resetting state can discard pending work and cloud evidence. History databases and the insertion ledger are not rewritten by migration.

## Project lineage

This project is derived from [brycemcole/chrome-to-safari-sync](https://github.com/brycemcole/chrome-to-safari-sync) and retains its MIT license and Git history. Version 6 is a purpose-built history synchronization redesign.
