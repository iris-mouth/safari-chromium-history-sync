# Changelog

## 5.9

- Added full bookmark reconciliation support for Safari-to-Chromium replay after stale sync state.
- Added normalized URL matching before moving or creating Safari-origin bookmarks in Chromium.
- Preserved per-visit Chromium history timestamps when writing Safari history.
- Added popup and options pages for sync status, manual sync, pause/resume, direction, and feature toggles.
- Added `doctor.sh` for native host and local data diagnostics.
- Moved default runtime state, logs, and backups to `~/Library/Application Support/Safari Sync`.
