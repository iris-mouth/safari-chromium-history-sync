# Integration implementation status

This tracks issue #1. The owner authorized the cutover after device validation,
with the actual logout/login check deferred.

- [x] Independent Swift source scanning, staged reconciliation, source-scoped
  visit identity, last-success/failure state and owner-only integrated SQLite.
  Initial scans publish committed batches; replacement scans publish only after
  successful completion. Source removal and pause have distinct effects.
  [Chromium lock validation](validation/chromium-exclusive-lock.md) covers native reads;
  [build 630 validation](validation/build-630.md) covers extension ingestion and later reconciliation.
- [x] Swift Reader and separately packaged, sandboxed loopback Viewer; owner
  identity header required, local Chromium icons with fallback, API bounds,
  date/search/pagination/detail/revalidation and cancellation support.
- [x] React UI port and desktop/mobile Playwright coverage; source state shown.
- [x] Menu controls for collection sources, sync/collection/viewer switches,
  manual collection and Web opening; menu quit requests Agent and Viewer exit.
- [x] The owner chose to discard legacy outbound extension entries without source visit identity. The updated worker removes these and previously held entries on its next exchange. Extension 632 was installed and reloaded in Edge; no discardable real entries were present, and identifiable entries were retained. See [extension 632 validation](validation/extension-632.md) for the synthetic deletion test and device evidence.
- [x] Synthetic Collector → Reader → HTTP tests, existing sync/extension tests,
  and local 100,000/1,000,000-record measurements. See `docs/validation/`.
- [x] Isolated Agent and Viewer processes restored settings after restart,
  recovered an interrupted scan without removing the previous successful data,
  and exited when their synthetic Menu owner disappeared. Home-relative sandbox
  access and read-only WAL access were exercised with synthetic data.
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
- [x] Installed settings, iPhone date selection, normal Viewer URL, Safari and Edge collection, and sync-off status were verified through [631-r3](validation/build-631-r3.md).
- [ ] Actual logout/login restoration on this Mac, including pending extension work, is deferred by the owner.
- [x] With the owner's explicit decision to defer the logout test, switch the
  current viewer URL to the new viewer and disable the old independent service.
  Mac and iPhone checks passed, and the temporary mapping was stopped.

The 443 → 8767 Serve mapping now targets the integrated Viewer; the temporary
foreground mapping on port 8443 has been stopped. Fixture tests do
not touch live browser history; the installed-app validation added one unique
test URL to Edge and the owner deleted that test URL afterward. Separate
iPhone/Tailscale observations and their limits are recorded in the device
validation document.
