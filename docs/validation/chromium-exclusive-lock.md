# Chromium exclusive-lock validation

On the installed 621 candidate, the selected Edge source retained its last
successful data but repeatedly returned `SQLITE_BUSY` while Edge was open.
File metadata showed a rollback journal and no WAL, and the open-file owner was
Edge. Chromium's [history database](https://chromium.googlesource.com/chromium/src/+/5aed270e6d3303ca91a02910b558f614bddba299/components/history/core/browser/history_database.cc)
can switch to exclusive locking; [SQLite's locking documentation](https://www.sqlite.org/lockingv3.html)
explains why a separate normal reader then receives `SQLITE_BUSY`.

Candidate 622 adds an in-memory fallback for a narrow rollback-journal case.
It requires the main file and an inactive, zero-header or empty journal to be
unchanged before and after two identical reads, rejects WAL and unexpected
formats, and runs SQLite `quick_check` before publishing the scan. The fallback
does not write to the browser database or journal. A changed, active, missing,
unreadable or unsupported journal fails the scan and retains the last good
result. Build 623 additionally permits the SQLite rollback-journal header state
in which the first 12 bytes are zero while later header fields are populated:
SQLite uses that state before a synchronous journal is marked ready to protect
database writes. A synced header or a no-sync writer's header is rejected.
These checks assume SQLite's rollback-journal protocol and cannot establish the
browser's runtime settings; they do not support in-memory journals. The byte
and metadata checks are a conservative observation, not a
SQLite read lock: unlike SQLite's [backup API](https://sqlite.org/backup.html),
they cannot provide a formal transactional guarantee for arbitrary concurrent
writers. In particular, exclusive WAL remains unsupported by this fallback.

Synthetic tests hold an exclusive SQLite lock in another process, check exact
native timestamps, add and delete visits, leave a deletion uncommitted, roll it
back, perform repeated concurrent commits, and reject exclusive WAL. They check
that the browser DB and journal remain unchanged by reads and that failed scans
retain prior visits. The test explicitly flushes an uncommitted deletion into
the synthetic main DB, proves the main file alone exposes it, and confirms the
collector rejects it; a no-sync transaction is also rejected. On this Mac, an
idle, exclusively locked synthetic
100,000-visit rollback-mode DB collected in 2.346 seconds; the worker's resident
size after the scan was 23.3 MiB. This is a warm-cache local observation, not a
peak-memory measurement or iPhone benchmark. The installed 622 candidate
retained the previous successful Edge collection but reported an active journal
on repeated reads. After installing 623, the same selected Edge source completed
while Edge was open; a test visit and its deletion were reflected in the viewer.
Because the validated snapshot is frozen in memory before rows are scanned,
build 623 also permits completed first-import batches to be shown while marking
the source incomplete if a later row fails.
