# Build 614 English UI validation

Date: 2026-10-21 (Asia/Tokyo). Development version 6.1.4, app build 614,
extension 6.1.4.

## Scope

Restore English product-authored menu labels, status and diagnostics windows,
setup, recovery explanations, and confirmation dialogs. Keep explicit action
names, a read-only normal status window, and initially collapsed test actions.
The status window and assist checkbox allow more room for the English text.
README and contributor instructions use the same labels and document English
as the product UI language. Browser-supplied profile names are preserved.

No sync-engine, permission-scope, protocol, history schema, account binding,
or retry-policy changes are included.

## Automated and package checks

- `scripts/check.sh`: PASS. JavaScript 42/42, Swift integration executable,
  and the real AppKit controller checks passed. The AppKit checks use in-memory
  replies and verify read-only opening/expansion and initially hidden tests.
- The existing SDK macro/sandbox warning did not prevent the AppKit check from
  completing successfully. Packaging required normal Swift cache access;
  rebuilding outside the file sandbox succeeded.
- `scripts/package-app.sh`: PASS. Both app bundles report 6.1.4 / build 614.
  Strict/deep signatures passed before and after full PKG extraction.
- Expanded executables match the packaged apps. Bundled extension 6.1.4 matches
  source; the PKG contains only the sibling app bundles and no installer scripts.
- PKG SHA-256:
  `70fd7102cc298e1c3be55d8c8b0e14816d21254f3d5bef349431f663662d8530`.

## Installed Mac checks

Environment reported by Agent: macOS 27.0.1 (26A434), Safari
22625.1.29.11.28, history-service SHA-256
`cc2dc5cd98ccef56864b8043efa8c207a030b592fa82fbb89f9ffbca06d257eb`.
Compatibility checks passed; the runtime is compatible-unverified.

- The product Menu and Agent were stopped normally. Their previous bundles and
  private runtime state were backed up before replacement under `/Applications`.
- Both installed app signatures, versions, and executable bytes match the
  verified package. Only the existing History Sync extension was reloaded in
  Edge; its management card reports 6.1.4 and enabled.
- macOS required Keychain authentication and restoration of the existing Full
  Disk Access grant. The user completed native authentication. Full Disk Access
  is on for the Agent; its existing Safari Automation permission remained on.
- Agent IPC reports build 614, ready, enabled, no issue, active Edge extension
  6.1.4, and Safari sync assist enabled. Before new probes, both relay queues,
  recovery, unrecoverable work, and pending Safari cloud processing were zero.
- The installed History Sync Status window visibly uses English. Refreshing it
  shows the active Edge profile, running sync, zero waiting work, and enabled
  assist. Its English explanation and Refresh Status button fit the window.
  No live setup/recovery confirmation was executed to test translated text.

## Receiving-device check in progress

Two new example.com probes were created through authenticated Menu commands and
normal delivery paths, without manually operating Safari:

| Intended receiving browser | Search token | Local outcome |
| --- | --- | --- |
| Safari | `8260349A` | Added to Safari; waiting for native progress |
| Edge | `0DD9ED10` | Exact browser visit receipt received |

Full test URLs use `/safari-history-sync-probe/` followed by
`8260349A-3EB8-4FDA-88F8-C67F1C904946` and
`0DD9ED10-414B-4BCC-94BA-D1974CE87F65`, respectively.
The Agent automatically reused its dedicated Safari tab about 97 seconds after
the Safari probe was added (`lastTrigger=tabReused`). No manual Safari navigation
or explicit helper trigger was used. At that observation, the native checkpoint
was still 950 versus the probe generation 956; helper execution is not treated
as a native sync completion or a receiving-device receipt.

The user was asked to search receiving-device history without opening either URL
first. Receiver evidence is pending; no arrival has been inferred from local
insertion, helper activity, or Safari's checkpoint. Earlier mobile observations
do not qualify build 614. The compatibility allowlist remains unchanged.
