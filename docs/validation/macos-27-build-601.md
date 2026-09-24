# macOS 27 / build 601 validation record

Date: 2026-09-24.

## Scope and provenance

The maintainer explicitly confirmed that build 601 had been tested on macOS 27 for bidirectional history synchronization and propagation to iPhone. This is a user-reported manual result, not an automated or independently observed end-to-end test by the release assistant.

- Tested implementation commit: `99dfc5423a0fcc1cdf5bbe8f117818f07850a78c`.
- App build: 601; app version: 6.0.
- Package tested before recording the result: `Safari-Chromium-History-Sync-v6.0.0-arm64.pkg`.
- That package's SHA-256: `c6f67de386e1fe1ddc24b851e182e26d568b459011f33169036f5702b5a16a48`.
- Reference environment: macOS 27.0 (26A428), Safari 22625.1.29.11.27; those versions were also read locally when recording this result.
- History-service identity: the existing reference runtime recorded in `CompatibilityGate.referenceRuntime`.

## Results

| Check | Result | Evidence source |
| --- | --- | --- |
| Bidirectional sync on build 601 | PASS, user-reported | Explicit maintainer confirmation |
| Propagation to iPhone | PASS, user-reported | Explicit maintainer confirmation |
| JavaScript and Swift integration tests | PASS | `./scripts/check.sh` on the tested implementation |
| App/PKG build and expanded signature checks | PASS | `./scripts/package-app.sh` and package inspection |
| Separate Chrome and Edge versions and per-browser results | NOT RECORDED | Not supplied in the confirmation |
| Exhaustive offline, delayed-arrival, and restart scenario matrix | NOT RECORDED | Not supplied in the confirmation |
| Fresh download/install on a separate Mac | NOT RECORDED | Not supplied in the confirmation |

The release records the confirmed runtime in `testedRuntimes` and rebuilds the package so the UI shows the tested label. That change affects the evidence label and documentation; synchronization and compatibility rules remain the tested implementation. The final distributed package therefore has its own SHA-256 in the release assets. No claim is made that the original package hash equals the rebuilt package hash, or that unrecorded scenarios passed.

Other environments may run when compatibility checks pass, with the compatible-unverified label. This result does not establish that every macOS 27 or Safari build has been tested.
