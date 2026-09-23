# Changelog

## Unreleased

- Replaced manual `setup.sh`, `doctor.sh`, Extension-ID entry, profile-ID entry,
  and the ambiguous Enable Agent action with an app-driven setup and focused
  runtime diagnostics flow.
- Made Chrome and Edge configuration explicit opt-in so unused browsers receive
  no Native Messaging directory or manifest.
- Simplified profile changes to an atomic active-profile switch while retaining
  pending delivery and recovery data under its originating profile.
- Added a payload-only PKG that installs the signed Menu and Agent sibling apps
  under `/Applications`, with optional Installer signing and PKG notarization.
- Documented that owner-only shared-key IPC and a fixed unpacked Extension ID do
  not establish trust against code already running as the current macOS user.
- Qualified macOS 27.0 (26A428), Safari 22625.1.29.11.27, and its exact
  `com.apple.Safari.History` binary fingerprint.
- Disabled SwiftPM's build sandbox for this dependency-free local package because
  macOS 27 rejects the nested sandbox used by the check and packaging scripts.
- Made the Agent validate Full Disk Access and the exact Safari history schema at
  startup instead of appearing healthy until its first sync request.

## 6.0

- Renamed the product and extension to Safari Chromium History Sync while retaining compatible internal identifiers and state paths.
- Replaced the Python multi-feature host with a Swift history-only installation containing a no-FDA Menu app, independent FDA-only Agent app, and no-FDA Native Messaging Bridge.
- Added bidirectional new-visit sync for exactly one active Chrome Stable or Edge Stable profile.
- Added immutable extension generations, monotonic streams, evidence-based Chromium delivery, encrypted recovery state, and a durable profile-switch FSM.
- Added visit-ID echo suppression so Safari-imported Chromium visits are not written back to Safari.
- Avoided reopening an already-running Agent when enabling the login item, preventing a misleading macOS launch error.
- Added exact compatibility gating for the qualified macOS 26.6.2 / Safari 21624.5.1.11.3 tuple.
- Removed bookmark, Reading List, open-tab, tab-group, deletion, and backfill synchronization.

## 5.9

- Added full bookmark reconciliation support for Safari-to-Chromium replay after stale sync state.
- Added normalized URL matching before moving or creating Safari-origin bookmarks in Chromium.
- Preserved per-visit Chromium history timestamps when writing Safari history.
- Added popup and options pages for sync status, manual sync, pause/resume, direction, and feature toggles.
- Added `doctor.sh` for native host and local data diagnostics.
- Moved default runtime state, logs, and backups to `~/Library/Application Support/Safari Sync`.
