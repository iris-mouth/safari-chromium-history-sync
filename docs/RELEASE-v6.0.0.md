# Safari Chromium History Sync v6.0.0 — Experimental prerelease

**Draft — publication on hold.** The revised runtime registry and schema validation require an installed-app compatibility check and end-to-end run before release. See the [compatibility policy](https://github.com/iris-mouth/safari-chromium-history-sync/blob/main/docs/COMPATIBILITY.md). No additional OS versions have been enabled by this change.

Synchronize new history visits in both directions between Safari and one active Google Chrome Stable or Microsoft Edge Stable profile. Safari remains the iCloud path to iPhone and iPad.

## Supported environment

- Apple silicon (arm64); this download does not include Intel binaries.
- macOS 27.0, build 26A428.
- Safari build 22625.1.29.11.27.
- The exact qualified Safari history service binary and database schema. Other OS/Safari builds are rejected; a system update can stop synchronization until that environment is qualified.

## Download and install

1. Download `Safari-Chromium-History-Sync-v6.0.0-arm64.pkg` and `SHA256SUMS.txt` from this release.
2. In their download folder, run `shasum -a 256 -c SHA256SUMS.txt` and confirm `OK`.
3. Install the PKG. It installs **Safari Chromium History Sync.app** and **Safari Chromium History Sync Agent.app** under `/Applications`.
4. Open **Safari Chromium History Sync**, choose **Start Setup**, and select Chrome, Edge, or both.
5. Enable Developer mode on each selected browser's extensions page and load the `ChromiumExtension` folder revealed by Setup.
6. Approve Open at Login if prompted, grant Full Disk Access only to **Safari Chromium History Sync Agent.app**, and choose one active profile if multiple profiles connect.

The installer is unsigned; the apps are ad-hoc signed and are not Developer ID signed or notarized. macOS may block installation or first launch. If you trust this release, follow [Apple's instructions for opening apps from unidentified developers](https://support.apple.com/en-us/102445).

## Included

- App-driven setup, readable profile labels, and setup diagnostics.
- Bidirectional new-visit synchronization with browser page titles preserved when writing to Safari.
- Profile-scoped pending deliveries and encrypted recovery state.
- Focused recovery for a replaced Safari database or unreadable Agent state.
- Payload-only PKG containing the two app bundles and their MIT license notices, without installer scripts.
- An additive runtime registry and exact table/index/trigger schema validation, with a documented process for qualifying additional environments.

## Limitations

- No old-history backfill, deletion sync, bookmarks, Reading List, tabs, or tab groups.
- Exactly one Chrome or Edge profile is active at a time.
- Safari visits delivered to Chromium receive the delivery time, because Chromium cannot preserve the original external timestamp.
- The browser extension is loaded unpacked; it is not distributed through an extension store.
- Stop and remove the legacy Python writer before enabling this version. Previous local state is not migrated.
- This prerelease has not been validated through a fresh download/install on a separate Mac.

## Validation

The release was checked on Apple silicon with Xcode 27.0 (27A266a) and the qualified macOS 27.0 environment. JavaScript tests and the Swift integration suite passed. Integration tests use temporary databases rather than live Safari history.

The generated PKG was expanded and verified to contain only the two app bundles, their arm64 executables and license notices, and no installer scripts. Both expanded apps passed strict code-signature verification. This verifies the ad-hoc signatures, not Developer ID trust or notarization.

See the [README](https://github.com/iris-mouth/safari-chromium-history-sync/blob/v6.0.0/README.md) for installation details and the [security documentation](https://github.com/iris-mouth/safari-chromium-history-sync/blob/v6.0.0/SECURITY.md) before reporting issues involving private history.
