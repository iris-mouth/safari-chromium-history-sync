# Changelog

## 6.1.2 development / build 612 — unreleased

- Replace Safari's six-attempt daily ceilings with shared, persisted launch/navigation retries: 5/10/20/40/60 minutes while checkpoints remain unchanged, capped at one attempt per hour without a daily stop.
- Reset backoff on native progress or a resolved backlog followed by new visits; keep the five-minute minimum through restarts, crashes, permission failures, and feature toggles.
- Migrate exhausted build-610/611 budgets automatically without resetting the last cooldown or the opted-in helper tab.
- Alternate two owned control URLs in the same Safari tab so each attempt performs an ordinary navigation; exclude both from relay.
- Show the next automatic attempt and keep observation scheduling independent of action backoff. Navigation acceptance remains distinct from native progress and receiving-device arrival.

## 6.1.1 development / build 611 — unreleased

- Record build 610 iPhone Safari and Edge arrival as user-reported evidence, separate from automatic qualification.
- Add opt-in Safari Sync Assist using one reusable helper tab, normal navigation, durable cooldown/budget, and visible permission/failure state.
- Keep slow Safari events outside the service lock; exclude the helper URL from relay to prevent feedback.
- Preserve existing schema-3 journals with assist disabled until explicitly enabled.

## 6.1.0 development / build 610 — unreleased

- Persist relay-owned account-delivery obligations independently of local ACKs;
  migrate Agent state schemas 1/2 to 3 without inferring historical cloud receipts.
- Coalesce Safari writes and monitor exact rows/checkpoint progress, with durable
  launch reservations, backoff, cooldown, and rolling launch limits.
- Save browser insertion intents and exact evidence before writes/ACKs; recover
  lost responses without duplicate visits and retain later real visits.
- Add Account Sync & Arrival Checks with per-route probes, user-reported mobile
  observations, bounded owned-URL Safari export comparison, replay plans, and
  user-declared account binding changes.
- Cancel removed owned work using deletion timestamps; never treat receiver
  non-observation or a Safari checkpoint as proof of cloud arrival.
- Bound transport payloads by bytes as well as events and page diagnostics.
- Keep the new build compatible-unverified pending its own live E2E validation;
  the build-601 manual result remains historical evidence. No live history or
  account changes are part of the automated checks.
- Older Agents cannot read schema 3; preserve state before an intentional rollback.

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
