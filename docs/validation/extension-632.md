# Extension 632 validation

On November 24, 2026, extension 6.2.0.632 was installed and reloaded in Edge; native app/helpers remain build 631. The incremental update preserved Helpers bytes and passed deep strict signature verification. A full candidate 631-r4 package was built but not installed.

Before and after reload, two legacy generations contained zero unverifiable or held entries, 1,022 identifiable outbound entries (summed across generations, not unique visits), and zero inbound entries. The 22 worker tests passed, including synthetic legacy cleanup. No fixture was added to the real extension store.

TCC logs attributed Agent reads to the parent app and rejected its stale signature registration. Re-registering the parent fixed access. With the embedded Agent permission disabled and the app restarted, Safari completed a new scan. Temporarily quitting Edge allowed its scan to complete too; Edge was reopened. Parent-only Full Disk Access is verified on this Mac.

Agent was ready, Viewer returned HTTP 200, sync remained off, and the Safari cursor was unchanged (identity mismatch, matching anchor). On November 25, connecting the selected Edge profile enabled extension collection: one uniquely marked test visit appeared in the viewing DB while Edge remained open. The test visit remains in browser history. Actual logout/login restoration remains deferred.
