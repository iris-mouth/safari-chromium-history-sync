# Build 626 on macOS

The installer upgraded the existing build 624 installation in place. The installed Menu, Agent and Viewer bundles report build 626. Only the main app is installed directly under Applications. The Agent and sandboxed Viewer are in Contents/Helpers. After registering the embedded Agent for Full Disk Access, collection reported complete for the selected Safari and Edge sources. Agent status reported ready, with browser sync disabled. Normal Menu quit closed the local TLS listener; reopening the Menu restored it.

A private Unix socket did not work as a Tailscale Serve backend on this Mac. The installed gateway receives raw TCP with PROXY protocol v2 on loopback port 8767 and terminates TLS for the existing HTTPS hostname. Certificates and keys are obtained in memory. The previous port 8766 handler was replaced only after testing the signed viewer on a separate port. At the normal URL an unapproved browser receives the enrollment page; an unapproved history request returns HTTP 403.

Synthetic browser tests on the actual Tailscale route covered WebKit and Chromium requesting enrollment, matching the displayed code, opening history after approval, and rejection after revocation. Safari form submission requires the enrollment page to preserve same-origin referrer information. The general viewer suite passed all 45 browser tests. The 44 JavaScript tests, Go authorization test, Swift integration and AppKit presentation checks also passed.

The local Mac WebKit reference measurements used Tailscale, synthetic data and a warm filesystem cache. For 100,000 visits, day results took 151 ms and search took 433 ms. For 1,000,000 visits the results were 150 ms and 566 ms. Search includes the 300 ms input delay. These measurements do not substitute for iPhone results.

The actual logout and login check remains deferred.

## Build 627

Build 627 replaces browser enrollment with direct access for the configured Tailscale owner. The gateway checks that the signed Tailscale App Store network extension owns the forwarding socket before it accepts the PROXY address for the owner lookup. A real forwarded request to the packaged gateway and sandboxed reader returned HTTP 200 at both the home page and the status API without a cookie. A local non-Tailscale connection failed the sender check. The embedded Agent executable is byte-identical to build 626.

After installation the normal URL served the Viewer HTML and returned HTTP 200 for the status API without a cookie. The full check script passed and all 45 browser tests passed. On this upgrade the running Agent reported safariAccessUnavailable despite the identical Agent executable. Both collection sources require a fresh access check after restoring Full Disk Access.

After re-registering the embedded Agent, Safari collection completed. Edge reported waiting for its database to unlock, with the previously confirmed history retained. Edge's extensions page showed the bundled extension enabled at 6.2.0.626. Browser sync stayed off.

On physical iPhone Safari with no browser enrollment, the 100,000-visit fixture took 370 ms for day results and 501 ms for search. The 1,000,000-visit fixture took 408 ms and 693 ms respectively. The connection type was not recorded for this run. After removing both temporary routes, only the normal port 443 remained and the status API returned HTTP 200 without a cookie.
After the existing Keychain item was allowed, the Agent reported ready with no issue code and browser sync disabled. The normal status API still returned HTTP 200.
