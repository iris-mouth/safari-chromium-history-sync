# Changelog

## 6.0.0 prerelease — 2026-09-24

- Advance both app bundle build numbers to 601 so the Menu restarts an older Agent.
- Permit otherwise compatible environments without an OS/Safari version or binary
  hash allowlist; show tested and compatible-but-unverified states separately.
- Compare SQLite structural metadata instead of exact SQL text, permitting cosmetic
  changes, reordered columns, and ordinary nonunique index changes.
- Reject incompatible constraints, triggers, and invalid or overflowing generation
  values before writes; retain pending work when blocked.
- Add tests for equivalent structures, rejected behavioral changes, metadata
  validation, and compatibility diagnostic serialization.
- Record maintainer-confirmed build 601 bidirectional sync and iPhone propagation
  on the macOS 27 reference environment; distinguish this user-reported result
  from automated checks and unrecorded scenarios.

- Prepared the first GitHub download as an unsigned Apple silicon PKG, with
  SHA-256 verification and explicit runtime and distribution limitations.
- Included the MIT license in both distributed app bundles.
- Displayed browser profile labels and preserved page titles for new history
  visits sent from Chrome or Edge to Safari.

- Replaced manual `setup.sh`, `doctor.sh`, Extension-ID entry, profile-ID entry,
  and the ambiguous Enable Agent action with an app-driven setup and focused
  runtime diagnostics flow.
- Made Chrome and Edge configuration explicit opt-in so unused browsers receive
  no Native Messaging directory or manifest.
- Simplified profile changes to an atomic active-profile switch while retaining
  pending delivery and recovery data under its originating profile.
- Added a payload-only unsigned local PKG that installs the ad-hoc-signed Menu
  and Agent sibling apps under `/Applications`.
- Standardized bundle, package, Keychain, logger, Native Messaging, and runtime
  identifiers under `io.github.irismouth`, and renamed the Agent bundle to
  `Safari Chromium History Sync Agent.app` while retaining its executable name.
- Added focused, Menu-authenticated recovery for Safari cursor identity/anchor
  failures and unreadable sealed state without adding a generic repair command.
- Documented that owner-only shared-key IPC and a fixed unpacked Extension ID do
  not establish trust against code already running as the current macOS user.
- Qualified macOS 27.0 (26A428), Safari 22625.1.29.11.27, and its exact
  `com.apple.Safari.History` binary fingerprint.
- Disabled SwiftPM's build sandbox for this dependency-free local package because
  macOS 27 rejects the nested sandbox used by the check and packaging scripts.
- Made the Agent validate Full Disk Access and the exact Safari history schema at
  startup instead of appearing healthy until its first sync request.

## 6.0

- Renamed the product and extension to Safari Chromium History Sync.
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
