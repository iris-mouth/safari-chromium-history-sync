# Cutover preparation and result

This record describes the build 624 migration. For the current gateway port and
Full Disk Access setup, use the [setup instructions](../../README.md#set-up-the-app).

Before cutover, the independently managed `local.historysyncweb` LaunchAgent
had `KeepAlive` and `RunAtLoad`, and the Tailscale Serve root on HTTPS 443
forwarded to local 8765. Read-only inspection found one persistent root handler.
Recheck live settings before a future cutover or rollback, since the user may
change them in the meantime.

1. Verify the candidate on synthetic data and on the owner's iPhone through a
   separate foreground Serve port. Preserve the current Viewer during this step.
2. The owner must install the candidate and grant Full Disk Access to the Agent
   through macOS. Configure the selected sources independently of the sync
   partner. Enable the Web Viewer with the owner's Tailscale login and an HTTPS
   origin. Confirm first collection, source status, Mac/iPhone reading, and the
   individual service switches. Do not send old collected visits to browsers.
3. Verify Menu quit, restart and login restoration with pending extension work.
4. Only after those checks, point the existing Serve root at local 8766 and
   disable/stop the old `local.historysyncweb` LaunchAgent so KeepAlive cannot
   restart it. Update the configured Viewer origin to the final HTTPS URL so
   the product excludes its own page from collection. Preserve old files and
   data until the owner decides whether to remove them.
5. Before uninstalling the old product, a rollback could point the Serve root
   back to local 8765, re-enable and bootstrap the old LaunchAgent, and quit the
   new product. Recheck current mappings before applying either direction to
   avoid overwriting unrelated user changes.

The candidate is ad-hoc signed and its installer is unsigned, matching the
existing local packaging policy. It is not a public release and has not yet
passed the actual logout/login check above. Candidate 624 is installed and its
login item is listed by System Settings. The owner deferred logging out and
explicitly approved cutover first. HTTPS 443 now forwards to 8766; the old
`local.historysyncweb` service is disabled and unloaded. The Menu origin was
changed to the root HTTPS URL, and both the old and new Viewer origins remain
excluded from collection. The owner
confirmed the final Viewer on iPhone and Mac. The foreground 8443 mapping was
stopped, and the final HTTPS 443 check passed. The owner confirmed the
Menu-opening command again after 8443 was stopped. Browser sync is deliberately
disabled at the owner's request and its cursor was not reset.

The owner later requested uninstalling the old Viewer and HistorySync. Their
installed files, old data, configuration and LaunchAgent were moved to Trash,
and their old access and background permissions were revoked. The old source
checkout remains. Reverting to the old service would require restoring and
reconfiguring those files first; they may no longer be available after Trash is
emptied.
