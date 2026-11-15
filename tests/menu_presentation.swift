// Compiled with the actual Menu view/controller sources by scripts/check-menu.sh.
import AppKit
import SafariSyncCore
import ServiceManagement

@main @MainActor struct PresentationCheck {
    static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    static func main() async throws {
        var loginStatus = SMAppService.Status.notFound
        var registrations = 0
        let registered = try LoginItemRegistration.ensure(status: { loginStatus }, register: {
            registrations += 1; loginStatus = .enabled
        })
        precondition(registered == .ready && registrations == 1, "a previously unseen app must be registered")
        let ready = try LoginItemRegistration.ensure(status: { .enabled }, register: { registrations += 1 })
        precondition(ready == .ready && registrations == 1, "an enabled app must not be registered again")
        let approval = try LoginItemRegistration.ensure(status: { .requiresApproval }, register: { registrations += 1 })
        precondition(approval == .requiresApproval && registrations == 1, "a disabled app must request approval")
        loginStatus = .notFound
        let newApproval = try LoginItemRegistration.ensure(status: { loginStatus }, register: { loginStatus = .requiresApproval })
        precondition(newApproval == .requiresApproval, "registration requiring approval is not reported as ready")
        enum SyntheticLoginError: Error { case failed }
        do {
            _ = try LoginItemRegistration.ensure(status: { .notFound }, register: { throw SyntheticLoginError.failed })
            preconditionFailure("registration errors cannot be swallowed")
        } catch SyntheticLoginError.failed { }
        do {
            _ = try LoginItemRegistration.ensure(status: { .notFound }, register: {})
            preconditionFailure("an unresolved status cannot be reported as registered")
        } catch is LoginItemRegistration.Unavailable { }
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let delegate = MenuDelegate()
        let menu = delegate.makeMenu()
        let topActions = menu.items.compactMap { $0.action.map(NSStringFromSelector) }
        precondition(!topActions.contains("showCloudDiagnostics"))
        precondition(topActions.contains("showSyncStatus"))
        precondition(topActions.contains("configureSafariAssist"))
        precondition(topActions.contains("configureCollection"))
        precondition(topActions.contains("configureViewer"))
        precondition(topActions.contains("toggleSync"))
        precondition(menu.items.contains { $0.title == "Quit History Sync" })
        let fakeHome = FileManager.default.temporaryDirectory.appendingPathComponent("profile-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: fakeHome) }
        let chrome = fakeHome.appendingPathComponent("Library/Application Support/Google/Chrome")
        try FileManager.default.createDirectory(at: chrome.appendingPathComponent("Default"), withIntermediateDirectories: true)
        try Data(#"{"profile":{"info_cache":{"Default":{"name":"Personal"}}}}"#.utf8).write(to: chrome.appendingPathComponent("Local State"))
        let missing = HistoryCollectionSource(id: "edge:Profile 8", browser: .chromium, browserType: "Edge", profileName: "Away", path: "/synthetic/missing")
        let discovery = CollectionProfiles.discover(home: fakeHome, selected: [missing])
        let candidates = discovery.candidates
        precondition(candidates.contains { $0.id == "chrome:Default" && $0.profileName == "Personal" })
        precondition(candidates.contains { $0.id == missing.id }, "temporarily missing selections remain available")
        precondition(candidates.contains { $0.id == "safari:default" })
        precondition(discovery.unavailableBrowsers.isEmpty, "missing browser installations are not access failures")
        let edge = fakeHome.appendingPathComponent("Library/Application Support/Microsoft Edge")
        try FileManager.default.createDirectory(at: edge, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: edge.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: edge.path) }
        let inaccessible = CollectionProfiles.discover(home: fakeHome, selected: [missing])
        precondition(inaccessible.unavailableBrowsers.contains("Edge"), "access failures are reported")
        precondition(inaccessible.candidates.contains { $0.id == missing.id }, "an inaccessible source remains selected")
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
                displayName: "Microsoft Edge · 個人用プロファイル", extensionVersion: "6.1.4", lastSeen: now, active: true)],
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
        let testButtons = nodes.compactMap { $0 as? NSButton }.filter { $0.title.contains("Add Test History") }
        precondition(testButtons.count == 2 && testButtons.allSatisfy(\.isHiddenOrHasHiddenAncestor))
        let disclosure = nodes.compactMap { $0 as? NSButton }.first { $0.title == "Show Tests & Advanced Actions" }!
        disclosure.performClick(nil)
        precondition(testButtons.allSatisfy { !$0.isHiddenOrHasHiddenAncestor })
        precondition(diagnosticRequests == ["cloudStatus"], "expansion must not perform a test or repair")
        status.close()
        detailed.close()
        print("PASS: normal menu has status/settings and no test entry; status and diagnostics opening/expansion issued read-only commands; test actions are initially hidden")
    }
}
