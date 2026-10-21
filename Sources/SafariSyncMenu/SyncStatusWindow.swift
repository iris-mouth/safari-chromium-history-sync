import AppKit
import SafariSyncCore

/// The normal entry point is read-only; testing and repair live in diagnostics.
@MainActor
final class SyncStatusWindow: NSWindowController {
    private let request: (MenuCommand) async throws -> Data
    private let status = NSTextField(wrappingLabelWithString: "Checking sync status…")
    private let browser = NSTextField(wrappingLabelWithString: "")
    private let pending = NSTextField(wrappingLabelWithString: "")
    private let safari = NSTextField(wrappingLabelWithString: "")
    private let assist = NSTextField(wrappingLabelWithString: "")
    private var busy = false

    init(request: @escaping (MenuCommand) async throws -> Data) {
        self.request = request
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 420),
            styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "History Sync Status"
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
            "Check the browser history on your iPhone or iPad to confirm arrival. Safari's sync progress alone does not confirm that an individual visit reached another device.")
        explanation.textColor = .secondaryLabelColor
        for field in [status, browser, pending, safari, assist, explanation] {
            stack.addArrangedSubview(field)
            field.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        let refresh = NSButton(title: "Refresh Status", target: self, action: #selector(refresh))
        refresh.toolTip = "Refresh the display without adding test history or changing settings."
        stack.addArrangedSubview(refresh)
        window.center()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc func refresh() {
        guard !busy else { return }
        busy = true
        Task {
            defer { busy = false }
            do {
                let data = try await request(MenuCommand(operation: "status"))
                let health = try JSONDecoder().decode(HealthSnapshot.self, from: data)
                var diagnostics: CloudDiagnostics?
                if health.runtimeState == "ready", let profile = health.activeProfileID {
                    let data = try await request(MenuCommand(operation: "cloudStatus", profileID: profile))
                    diagnostics = try JSONDecoder().decode(CloudDiagnostics.self, from: data)
                }
                display(health: health, diagnostics: diagnostics)
            } catch {
                status.stringValue = "Could not load sync status"
                browser.stringValue = "Check the connection under Troubleshooting in the menu."
                pending.stringValue = ""
                safari.stringValue = ""
                assist.stringValue = ""
            }
        }
    }

    func display(health: HealthSnapshot, diagnostics: CloudDiagnostics?) {
        let profile = health.connectedProfiles.first { $0.profileID == health.activeProfileID }
        status.stringValue = health.runtimeState == "blocked" || !health.enabled ? "Sync is stopped"
            : health.runtimeState == "initializing" ? "Starting sync service…"
            : health.activeProfileID == nil && !health.connectedProfiles.isEmpty ? "Choose a browser to sync"
            : profile == nil ? "Waiting for browser extension" : "History sync is running"
        browser.stringValue = "Browser to sync: \(profile?.displayName ?? (health.activeProfileID == nil ? "Not selected" : "Waiting for connection"))"
        pending.stringValue = "Pending browser deliveries: \(health.pendingSafariToBrowser)\nWaiting for automatic retry: \(health.recoveryCount)"
        if let cloud = diagnostics?.summary {
            safari.stringValue = "Waiting for Safari sync: \(cloud.safariPending)\nArrival confirmed on device: \(cloud.remoteSeen)"
        } else {
            safari.stringValue = health.runtimeState == "blocked" ? "Open Troubleshooting to view the cause and recovery options." : ""
        }
        if let diagnostics, let scheduler = diagnostics.safariAssist {
            assist.stringValue = "Automatic Safari sync assist (dedicated tab): \(scheduler.enabled ? "Enabled" : "Disabled")"
            if scheduler.enabled, let next = scheduler.nextAttemptAt, diagnostics.summary.safariPending > 0 {
                assist.stringValue += "\nNext automatic attempt: \(next.formatted(date: .abbreviated, time: .shortened))"
            }
        } else { assist.stringValue = "Automatic Safari sync assist (dedicated tab): Disabled" }
    }
}
