# Changelog

## 6.0

- Renamed the product and extension to Safari Chromium History Sync while retaining compatible internal identifiers and state paths.
- Replaced the Python multi-feature host with a Swift history-only installation containing a no-FDA Menu app, independent FDA-only Agent app, and no-FDA Native Messaging Bridge.
- Added bidirectional new-visit sync for exactly one active Chrome Stable or Edge Stable profile.
- Added immutable extension generations, monotonic streams, evidence-based Chromium delivery, encrypted recovery state, and a durable profile-switch FSM.
- Added visit-ID echo suppression so Safari-imported Chromium visits are not written back to Safari.
- Added exact compatibility gating for the qualified macOS 26.6.2 / Safari 21624.5.1.11.3 tuple.
- Removed bookmark, Reading List, open-tab, tab-group, deletion, and backfill synchronization.

## 5.9

- Added full bookmark reconciliation support for Safari-to-Chromium replay after stale sync state.
- Added normalized URL matching before moving or creating Safari-origin bookmarks in Chromium.
- Preserved per-visit Chromium history timestamps when writing Safari history.
- Added popup and options pages for sync status, manual sync, pause/resume, direction, and feature toggles.
- Added `doctor.sh` for native host and local data diagnostics.
- Moved default runtime state, logs, and backups to `~/Library/Application Support/Safari Sync`.
