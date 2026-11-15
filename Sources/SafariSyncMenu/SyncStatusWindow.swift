import AppKit
import SafariSyncCore

/// The normal entry point is read-only; testing and repair live in diagnostics.
@MainActor
final class SyncStatusWindow: NSWindowController {
    private let request: (MenuCommand) async throws -> Data
    private let status = NSTextField(wrappingLabelWithString: NSLocalizedString("Checking sync status…", comment: ""))
    private let browser = NSTextField(wrappingLabelWithString: "")
    private let pending = NSTextField(wrappingLabelWithString: "")
    private let safari = NSTextField(wrappingLabelWithString: "")
    private let assist = NSTextField(wrappingLabelWithString: "")
    private let collection = NSTextField(wrappingLabelWithString: "")
    private let viewer = NSTextField(wrappingLabelWithString: "")
    private let viewerStatus: () -> String
    private var busy = false

    init(viewerStatus: @escaping () -> String = { "Off" }, request: @escaping (MenuCommand) async throws -> Data) {
        self.request = request
        self.viewerStatus = viewerStatus
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 580, height: 540),
            styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = NSLocalizedString("History Sync Status", comment: "")
        window.isReleasedWhenClosed = false
        super.init(window: window)
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: window.contentView!.bottomAnchor, constant: -24),
        ])
        status.font = .boldSystemFont(ofSize: 17)
        let explanation = NSTextField(wrappingLabelWithString:
            NSLocalizedString("Check the browser history on your iPhone or iPad to confirm arrival. Safari's sync progress alone does not confirm that an individual visit reached another device.", comment: ""))
        explanation.textColor = .secondaryLabelColor
        for field in [collection, viewer, status, browser, pending, safari, assist, explanation] {
            stack.addArrangedSubview(field)
            field.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        let refresh = NSButton(title: NSLocalizedString("Refresh Status", comment: ""), target: self, action: #selector(refresh))
        refresh.toolTip = NSLocalizedString("Refresh the display without adding test history or changing settings.", comment: "")
        stack.addArrangedSubview(refresh)
        window.center()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc func refresh() {
        guard !busy else { return }
        busy = true
        Task {
            defer { busy = false }
            viewer.stringValue = String(format: NSLocalizedString("Web Viewer · %@", comment: ""), NSLocalizedString(viewerStatus(), comment: ""))
            do {
                let data = try await request(MenuCommand(operation: "collectionStatus"))
                let reply = try JSONDecoder().decode(CollectionReply.self, from: data)
                var lines = [NSLocalizedString(reply.enabled ? "History collection is on" : "History collection is off", comment: "")]
                for source in reply.statuses {
                    let last = source.lastSuccess.map { Date(timeIntervalSince1970: $0).formatted(date: .abbreviated, time: .shortened) } ?? NSLocalizedString("never", comment: "")
                    let state = NSLocalizedString("collection." + source.state, value: source.state, comment: "")
                    lines.append(String(format: NSLocalizedString("%@ · %@ — %@ (last collected: %@)", comment: ""), source.browserType, source.profileName, state, last))
                }
                collection.stringValue = lines.joined(separator: "\n")
            } catch {
                collection.stringValue = NSLocalizedString("Collection status unavailable", comment: "")
            }
            do {
                let data = try await request(MenuCommand(operation: "status"))
                let health = try JSONDecoder().decode(HealthSnapshot.self, from: data)
                var diagnostics: CloudDiagnostics?
                if health.enabled, health.runtimeState == "ready", let profile = health.activeProfileID {
                    let data = try await request(MenuCommand(operation: "cloudStatus", profileID: profile))
                    diagnostics = try JSONDecoder().decode(CloudDiagnostics.self, from: data)
                }
                display(health: health, diagnostics: diagnostics)
            } catch {
                status.stringValue = NSLocalizedString("Could not load sync status", comment: "")
                browser.stringValue = NSLocalizedString("Check the connection in Settings → General.", comment: "")
                pending.stringValue = ""
                safari.stringValue = ""
                assist.stringValue = ""
            }
        }
    }

    func display(health: HealthSnapshot, diagnostics: CloudDiagnostics?) {
        let profile = health.connectedProfiles.first { $0.profileID == health.activeProfileID }
        status.stringValue = health.runtimeState == "blocked" || !health.enabled ? NSLocalizedString("Sync is stopped", comment: "")
            : health.runtimeState == "initializing" ? NSLocalizedString("Starting sync service…", comment: "")
            : health.activeProfileID == nil && !health.connectedProfiles.isEmpty ? NSLocalizedString("Choose a browser to sync", comment: "")
            : profile == nil ? NSLocalizedString("Waiting for browser extension", comment: "") : NSLocalizedString("History sync is running", comment: "")
        browser.stringValue = String(format: NSLocalizedString("Browser to sync: %@", comment: ""), String(describing: profile?.displayName ?? (health.activeProfileID == nil ? NSLocalizedString("Not selected", comment: "") : NSLocalizedString("Waiting for connection", comment: ""))))
        pending.stringValue = String(format: NSLocalizedString("Pending browser deliveries: %@\nWaiting for automatic retry: %@", comment: ""), String(describing: health.pendingSafariToBrowser), String(describing: health.recoveryCount))
        for profile in health.connectedProfiles {
            if let count = profile.heldCount, count > 0 {
                pending.stringValue += String(format: NSLocalizedString("\n%@: %@ unverified visits on hold", comment: ""), String(describing: profile.displayName), String(describing: count))
            }
        }
        if let cloud = diagnostics?.summary {
            safari.stringValue = String(format: NSLocalizedString("Waiting for Safari sync: %@\nArrival confirmed on device: %@", comment: ""), String(describing: cloud.safariPending), String(describing: cloud.remoteSeen))
        } else {
            safari.stringValue = health.runtimeState == "blocked" ? NSLocalizedString("Open Settings → General → Resolve Sync Issue to review recovery options.", comment: "") : ""
        }
        if let diagnostics, let scheduler = diagnostics.safariAssist {
            assist.stringValue = String(format: NSLocalizedString("Automatic Safari sync assist (dedicated tab): %@", comment: ""), String(describing: scheduler.enabled ? NSLocalizedString("Enabled", comment: "") : NSLocalizedString("Disabled", comment: "")))
            if scheduler.enabled, let next = scheduler.nextAttemptAt, diagnostics.summary.safariPending > 0 {
                assist.stringValue += String(format: NSLocalizedString("\nNext automatic attempt: %@", comment: ""), String(describing: next.formatted(date: .abbreviated, time: .shortened)))
            }
        } else { assist.stringValue = NSLocalizedString("Automatic Safari sync assist (dedicated tab): Disabled", comment: "") }
    }
}
