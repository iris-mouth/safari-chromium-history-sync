# Integration implementation status

This tracks issue #1. The owner authorized the cutover after device validation,
with the actual logout/login check deferred.

- [x] Independent Swift source scanning, staged reconciliation, source-scoped
  visit identity, last-success/failure state and owner-only integrated SQLite.
  Initial scans publish committed batches; replacement scans publish only after
  successful completion. Source removal and pause have distinct effects. The
  exclusive-lock fallback is an observational snapshot and has the limits
  recorded in `docs/validation/chromium-exclusive-lock.md`.
- [x] Swift Reader and separately packaged, sandboxed loopback Viewer; owner
  identity header required, local Chromium icons with fallback, API bounds,
  date/search/pagination/detail/revalidation and cancellation support.
- [x] React UI port and desktop/mobile Playwright coverage; source state shown.
- [x] Menu controls for collection sources, sync/collection/viewer switches,
  manual collection and Web opening; menu quit requests Agent and Viewer exit.
- [x] Extension source-visit recheck for identifiable queued browser visits.
  Legacy queued entries without a native source identity are retained rather
  than replayed without verification; a recovery UI for those is still needed.
- [x] Synthetic Collector → Reader → HTTP tests, existing sync/extension tests,
  and local 100,000/1,000,000-record measurements. See `docs/validation/`.
- [x] Isolated Agent and Viewer processes restored settings after restart,
  recovered an interrupted scan without removing the previous successful data,
  and exited when their synthetic Menu owner disappeared. Home-relative sandbox
  access and read-only WAL access were exercised with synthetic data.
- [ ] Verify the installed Menu's quit and login restoration end to end on this
  Mac, including pending extension work. Safari icons currently fall
  back to the generic icon.
- [x] Build and verify the ad-hoc-signed development package in an isolated
  temporary checkout. The owner installed candidate 620 and granted the Agent
  Full Disk Access; after restarting Menu, the Agent reports `ready`. Candidate
  621 fixes profile discovery and Viewer-origin cutover. Its Agent discovered
  Safari, Chrome and Edge, and selected Safari and Edge sources completed their
  first scans. Candidate 622 added read-only Safari cursor diagnostics.
  Candidate 623 completed scans of the selected Safari and Edge sources; one
  Edge test visit and its deletion were reflected while Edge was open. A login
  registration defect was reproduced and fixed for candidate 624. The owner
  installed 624; both sources and the Viewer continued working without another
  Full Disk Access re-registration. The app appears in macOS login items.
- [x] Measure synthetic 100,000- and 1,000,000-record browsing on iPhone Safari
  through the owner's Tailscale Serve; device and cache limitations are recorded.
- [ ] Finish validation of the installed app, including actual login restoration.
  Mac and iPhone viewing of selected real sources was checked on candidate 621;
  candidate 624's Viewer responds through Tailscale on the Mac. The owner chose
  to keep browser sync disabled after reviewing the changed Safari cursor, so
  an active live sync exchange is intentionally not being performed.
- [x] With the owner's explicit decision to defer the logout test, switch the
  current viewer URL to the new viewer and disable the old independent service.
  Mac and iPhone checks passed, and the temporary mapping was stopped.

The 443 → 8766 Serve mapping now targets the integrated Viewer; the temporary
foreground mapping on port 8443 has been stopped. Fixture tests do
not touch live browser history; the installed-app validation added one unique
test URL to Edge and the owner deleted that test URL afterward. Separate
iPhone/Tailscale observations and their limits are recorded in the device
validation document.
