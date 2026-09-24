# Compatibility and qualification policy

## Support grows by adding verified environments

Support is an explicit registry of runtime identities and database schemas, not a single version that is replaced whenever the development Mac is updated. Adding an environment must preserve existing supported entries unless a separately documented incompatibility requires withdrawing one.

Each entry in `CompatibilityGate.qualifiedRuntimes` binds the exact macOS version and build, Safari build, and SHA-256 of `com.apple.Safari.History` to a `SafariHistorySchema`. Runtime matching must identify exactly one entry. Unknown and ambiguous entries are rejected; there are no version ranges, user bypass switches, or automatic approvals based on a matching DB layout.

The runtime check runs when the Agent initializes. The selected schema is checked at startup and on subsequent history operations. Before a new Safari write, the schema check runs inside `BEGIN IMMEDIATE`, so a concurrent schema change cannot occur between validation and insertion. Completed delivery receipts can be returned without a new Safari write.

## Current support and evidence

| Environment | Registry status | Evidence and remaining work |
| --- | --- | --- |
| macOS 27.0.0 / 26A428, Safari 22625.1.29.11.27 | Existing enabled baseline, using `safari-history-v1` | Runtime identity inherited from commit `aaf2e0b`. The stricter schema check passes against the reconstructed schema-only fixture. Fresh installed-app validation is still required before public release. |
| macOS 26.6.2 / 25G83, Safari 21624.5.1.11.3 | Historical candidate; not enabled | Earlier implementation used this identity before `aaf2e0b`. It must pass the current implementation's qualification process before it can be added alongside 27.0. |
| Other macOS/Safari builds | Unsupported | Collect an identity and schema fixture, then complete qualification. A newer version is not automatically compatible. |

The enabled 27.0 history-service hash is `ab218c41abc06292969090580be6a3efa7e212595590df6e1e1328bfdec30b9a`. The historical 26.6.2 hash is `d95ed7bb6e30f3bb024abc937155d5009cf1d14e7ba70c4222adc71a786be5f6`; recording it here does not enable it.

The downloadable build targets arm64. This policy change does not add Intel support or claim additional verified OS versions.

## Schema evidence

`tests/fixtures/safari-history-v1.sql` contains only schema definitions extracted from a local pre-E2E Safari backup dated 2026-09-22. It contains no browsing rows or metadata values. The private source database is not distributed. The previous synthetic test fixture differed from that backup in declared types, NOT NULL/default constraints, foreign keys, and indexes; the tests now reconstruct the captured layout.

The fingerprint is SHA-256 of the compact UTF-8 JSON array returned from:

```sql
SELECT type, name, sql FROM sqlite_schema
WHERE tbl_name IN ('history_items', 'history_visits', 'metadata')
ORDER BY type, name;
```

SQL NULL is represented as JSON null. JSON slashes are not escaped. The `safari-history-v1` fingerprint is `69bb534a23e7ebf4bb36942789367d7e3ccaf24008794d6bf103f3dba6ece48a`.

This compares exact definitions, including column types, nullability, defaults, primary/unique/foreign-key constraints, indexes, and attached triggers. Missing objects, extra objects, generated columns, and even formatting-only DDL changes are rejected. That conservatism is intentional: a new known layout gets its own reviewed schema profile rather than weakening an existing fingerprint. Objects belonging to unrelated tables and database contents are not part of this fingerprint.

A schema match proves layout compatibility only. It does not prove iCloud behavior, source-event ordering, or that a new runtime is safe to enable.

## Adding an environment

1. Record the exact app commit, package SHA-256, CPU architecture, Xcode/SDK, macOS version/build, Safari build, and history-service SHA-256. Record the Chrome and Edge versions used in testing.
2. Read the three tables' schema from an authorized test machine. Keep live history read-only during capture. Store only data-free schema definitions in the repository. If Full Disk Access is unavailable, record the gap; do not grant it to a browser, Bridge, or Menu, or infer the schema from another runtime.
3. Reconstruct that schema in temporary SQLite databases. Run `./scripts/check.sh` against the intended adapter. Confirm wrong types/defaults/constraints, missing or extra indexes, unexpected triggers/columns, and schema changes after startup are rejected before Safari writes. Confirm generation advancement, idempotent retries, arrival cursors, and profile isolation still work.
4. On a designated test Mac with the legacy writer stopped, test the current packaged app through Setup & Diagnostics. Test Chrome-only, Edge-only, and both-browser setup; select exactly one active profile at a time. Confirm the other profile receives no history.
5. With synthetic test URLs, verify Chrome → Mac Safari → iPhone Safari and iPhone Safari → Mac Safari → Chrome, then repeat with Edge. Record local insertion, cloud trigger, and observed iPhone arrival separately. Local DB insertion or a successful build alone is not iCloud proof.
6. Check echo suppression, a later real visit to the same URL, offline/delayed arrivals, restart recovery, and Safari/Agent/Mac restarts. Confirm pending work remains associated with its original profile. Exercise failure and recovery cases on copies first; do not corrupt the live DB to test them.
7. Check at least 10 iPhone-origin visits in each normal, offline/delayed, Safari-restart, and Mac-restart scenario. Confirm their arrival IDs remain after the saved cursor. Track 10 browser-origin visits through three cloud ticks and the restart scenarios; confirm their identities and provenance remain stable.
8. Save a qualification report with observed results and explicit PASS/FAIL/NOT RUN statuses. Only then add an entry, preserving existing entries, and update the support table and release notes. Re-run the automated suite and package checks for the final commit. Publish only after the relevant release checks pass.

A qualification report must include the runtime identity, schema ID/fingerprint and fixture path, source commit and package hash, date and test environment, a result for each step above, sanitized evidence for observed transfers, and remaining limitations. Never attach raw History.db files, sealed state, delivery ledgers, personal URLs, or private account identifiers to a public report.

## Direction-specific support is a later change

This release still blocks both directions on an unsupported runtime or schema. It retains pending state rather than pretending synchronization succeeded. It does not silently fall back to Safari → Chromium only.

A future read-only Safari adapter may qualify Safari → Chromium independently of the Safari writer. That requires an actual read-only DB connection, independently tested arrival/cursor behavior, per-direction runtime capability checks, queue handling that preserves blocked browser → Safari work, and a UI that clearly reports partial support. Reading a known set of columns alone is insufficient evidence to enable that mode.

## Release hold after the 2026-09-24 changes

The registry and schema changes are preparation for broader support, not evidence that another runtime has been tested. The local automated suite uses the captured schema and synthetic data. Direct access to the current live Safari DB was unavailable in this session, so the new fingerprint check has not been exercised through the installed FDA Agent against the current live DB. A fresh installed-app compatibility and end-to-end run is required before publishing the revised PKG. The GitHub release remains a draft.
