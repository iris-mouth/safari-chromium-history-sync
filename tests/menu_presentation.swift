// Compiled with the actual Menu view/controller sources by scripts/check-menu.sh.
import AppKit
import SafariSyncCore

@main @MainActor struct PresentationCheck {
    static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    static func main() async throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let delegate = MenuDelegate()
        let menu = delegate.makeMenu()
        let topActions = menu.items.compactMap { $0.action.map(NSStringFromSelector) }
        precondition(!topActions.contains("showCloudDiagnostics"))
        precondition(topActions.contains("showSyncStatus"))
        precondition(topActions.contains("configureSafariAssist"))
        precondition(!topActions.contains { $0.lowercased().contains("probe") })
        let now = Date()
        var cloud = CloudDeliveryCoordinator()
        for index in 1...3 {
            try cloud.reserve(id: "synthetic-\(index)", profileID: "edge:preview", provider: .safari,
                url: URL(string: "https://example.com/preview/\(index)")!, now: now)
            try cloud.recordLocalDelivery(id: "synthetic-\(index)", visitID: String(index), time: now,
                now: now, generation: Int64(index + 40), databaseIdentity: "preview")
        }
        cloud.setSafariAssist(enabled: true, now: now)
        let diagnostics = cloud.diagnostics(profileID: "edge:preview")
        let health = HealthSnapshot(enabled: true, activeProfileID: "edge:preview", runtimeState: "ready",
            connectedProfiles: [BrowserProfileDescriptor(profileID: "edge:preview", browserFamily: "edge",
                displayName: "Microsoft Edge · 個人用プロファイル", extensionVersion: "6.1.3", lastSeen: now, active: true)],
            pendingBrowserToSafari: 0, pendingSafariToBrowser: 2, recoveryCount: 1, unrecoverableCount: 0,
            cloud: diagnostics.summary)
        var statusRequests: [String] = []
        let status = SyncStatusWindow { command in
            statusRequests.append(command.operation)
            precondition(["status", "cloudStatus"].contains(command.operation))
            return try command.operation == "status" ? JSONEncoder().encode(health) : JSONEncoder().encode(diagnostics)
        }
        status.refresh()
        for _ in 0..<20 { try await Task.sleep(for: .milliseconds(10)) }
        precondition(statusRequests == ["status", "cloudStatus"])
        let blocked = HealthSnapshot(enabled: true, activeProfileID: "edge:preview", runtimeState: "blocked",
            issueCode: AgentIssueCode.historyIdentityChanged, pendingBrowserToSafari: 0,
            pendingSafariToBrowser: 2, recoveryCount: 1, unrecoverableCount: 0)
        status.display(health: blocked, diagnostics: nil)
        var diagnosticRequests: [String] = []
        let detailed = CloudDiagnosticsWindow(profileID: "edge:preview") { command in
            diagnosticRequests.append(command.operation)
            precondition(command.operation == "cloudStatus")
            return try JSONEncoder().encode(diagnostics)
        }
        detailed.refresh()
        for _ in 0..<20 { try await Task.sleep(for: .milliseconds(10)) }
        let nodes = descendants(detailed.window!.contentView!)
        let testButtons = nodes.compactMap { $0 as? NSButton }.filter { $0.title.contains("テスト履歴") }
        precondition(testButtons.count == 2 && testButtons.allSatisfy(\.isHiddenOrHasHiddenAncestor))
        let disclosure = nodes.compactMap { $0 as? NSButton }.first { $0.title == "検証・詳細操作を表示" }!
        disclosure.performClick(nil)
        precondition(testButtons.allSatisfy { !$0.isHiddenOrHasHiddenAncestor })
        precondition(diagnosticRequests == ["cloudStatus"], "expansion must not perform a test or repair")
        status.close()
        detailed.close()
        print("PASS: normal menu has status/settings and no test entry; status and diagnostics opening/expansion issued read-only commands; test actions are initially hidden")
    }
}
