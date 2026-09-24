# Compatibility policy

## Eligibility and verification are separate

The app can run on environments that meet its runtime, database-structure, and sync-state requirements without requiring every macOS/Safari version to be individually tested. OS version/build, Safari build, and history-service hash identify test evidence; an unknown identity alone does not block synchronization.

| Status | Meaning | Behavior |
| --- | --- | --- |
| Tested | Compatibility checks pass and this exact environment has a current-release end-to-end test record | Sync permitted; diagnostics show tested |
| Compatible, unverified | Compatibility checks pass, but there is no matching current-release test record | Sync permitted; diagnostics show not end-to-end tested |
| Incompatible | Minimum runtime requirements, DB structure, or generation-state checks fail | Both directions stop; pending work is retained |

Runtime requirements are macOS 26.6.2 or later and a detectable Safari installation. The distributed binary targets Apple silicon. An unreadable history-service binary hash is recorded as unavailable and cannot establish tested status; it does not independently deny use.

`CompatibilityGate.assess` determines runtime eligibility and the evidence label. The Agent exposes the label only after the live database checks pass. Compatibility diagnostics show the OS/Safari identity and explain the distinction without requiring a bypass switch or repeated approval.

## Structural contract

The `safari-history-v1` adapter compares SQLite's interpreted metadata with a known data-free reference. It uses `table_xinfo`, `foreign_key_list`, `index_list`, `index_xinfo`, and `table_list`. It checks:

- The three required objects are ordinary tables: `history_items`, `history_visits`, and `metadata`.
- Column names, declared types (case-insensitive), nullability, default values, primary-key positions, and generated/hidden-column flags match. Missing or extra columns are rejected.
- Foreign-key destinations, column pairs, sequence, and update/delete actions match.
- Unique indexes, their key-column order, sort direction, collation, and primary/unique-constraint role match. New unique restrictions are rejected.
- Table mode (including STRICT and WITHOUT ROWID) and AUTOINCREMENT behavior match.
- No attached triggers or unmodeled CHECK, COLLATE, ON CONFLICT, DEFERRABLE, or MATCH clauses are introduced. Comments and quoted tokens are removed before checking these DDL-only features, since SQLite's PRAGMAs do not expose all of their semantics.

SQL whitespace, keyword case, column order, unique/NOT NULL clause order, numeric default parentheses, and index names do not determine compatibility. Ordinary nonunique indexes may be added, renamed, or removed; expression and partial indexes remain unsupported. This is a bounded structural comparison, not a general SQL-equivalence engine: unrecognized structures stop rather than being guessed compatible.

The independent captured fixture is `tests/fixtures/safari-history-v1.sql`, extracted from a local pre-E2E Safari backup dated 2026-09-22. It contains no browsing rows or metadata values. The private source database is not distributed. The production reference is interpreted by SQLite once in memory; tests independently reconstruct the fixture and mutate its structures to prove accepted and rejected behavior.

## Generation-state contract

Both `current_generation` and `last_synced_generation` must exist and contain nonnegative integers smaller than Int64.max. SQLite INTEGER values and losslessly parsed integer text are accepted; NULL, BLOB, fractional, negative, malformed, missing, and out-of-range values are rejected. The next local generation is `max(current, last_synced) + 1`; the app never acknowledges iCloud by writing `last_synced_generation`.

Schema and state validation run at startup and on history operations. New Safari writes validate inside `BEGIN IMMEDIATE`, holding the write transaction through insertion. A mismatch rolls back the transaction and stops synchronization. Already-completed delivery receipts can be returned without a new Safari write.

## What compatibility cannot prove

Identical structures do not prove unchanged Safari/iCloud behavior. The meaning of `origin`, generation scheduling, arrival ordering, or cloud upload behavior could change without changing the DB layout. Compatible-unverified use explicitly accepts that uncertainty. Local insertion and a cloud-trigger attempt are not proof that a visit reached iPhone Safari.

The existing arrival-anchor, database-identity, idempotency, and delivery-evidence checks remain active. They catch the anomalies they model; they do not detect every possible change in Apple's internal behavior. Compatibility failure preserves queues and does not silently switch to one-way synchronization. Independently qualifying a read-only Safari adapter remains future work.

## Reference environment and test evidence

The development reference is macOS 27.0.0 (26A428), Safari 22625.1.29.11.27, with history-service SHA-256 `ab218c41abc06292969090580be6a3efa7e212595590df6e1e1328bfdec30b9a`. Historical code also recorded macOS 26.6.2 (25G83), Safari 21624.5.1.11.3. Neither historical record alone proves the revised build's end-to-end behavior.

`CompatibilityGate.testedRuntimes` is currently empty because the revised build has not completed a new installed-app/end-to-end run. All eligible environments, including the reference Mac, therefore receive the honest compatible-unverified label. They can run. Adding a tested record changes the evidence label, not eligibility.

To record an environment as tested:

1. Record the source commit/package hash, date, CPU, Xcode/SDK, macOS/Safari identity, and tested Chrome/Edge versions. Include the schema reference and any fixture changes.
2. Run `./scripts/check.sh` and package verification. On a designated Mac with the legacy writer stopped, install the current package and complete Setup & Diagnostics.
3. Test Chrome and Edge separately, keeping exactly one active profile; confirm the inactive profile receives no visits. Verify browser → Mac Safari → iPhone Safari and iPhone Safari → Mac Safari → browser with synthetic URLs.
4. Verify echo suppression, later real visits to the same URL, offline/delayed arrivals, profile-scoped pending work, and Safari/Agent/Mac restart recovery. Record local commits, trigger attempts, and observed iPhone arrivals separately.
5. Save a sanitized report with PASS/FAIL/NOT RUN outcomes. Add only completed evidence to `testedRuntimes`. Do not publish raw DBs, sealed state, delivery ledgers, personal URLs, or account identifiers.

This procedure is for earning a tested label and checking the reference release. It is not a prerequisite for every compatible OS version to be usable.

## Current release status

The revised code is tested against temporary databases and simulated runtime identities. The session could not directly access the live Safari DB, and no new installed-app/iPhone end-to-end test has been completed. Public release remains on hold for that reference-environment check and the separately pending repository-publication approval. The GitHub release remains a draft. Exhaustively testing all macOS/Safari versions is not a release requirement.
