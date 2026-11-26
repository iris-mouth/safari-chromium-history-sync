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
        let collectionData = Data(#"{"enabled":true,"pair":{"source":"edge:preview","revision":"revision","extensionID":"edge:preview"},"sources":[{"id":"safari:default","browser":"safari","browserType":"Safari","profileName":"Default","state":"complete","lastScan":1730000000},{"id":"edge:preview","browser":"chromium","browserType":"Edge","profileName":"Work","state":"waiting","lastScan":1730000000,"lastLiveVisit":1730000030}]}"#.utf8)
        let collection = try JSONDecoder().decode(CollectionOverview.self, from: collectionData)
        let off = HealthSnapshot(enabled: false, syncRequested: false, activeProfileID: "edge:preview", runtimeState: "blocked",
            issueCode: AgentIssueCode.safariAccessUnavailable, pendingBrowserToSafari: 0,
            pendingSafariToBrowser: 2, recoveryCount: 1, unrecoverableCount: 0)
        let snapshot = MenuStatusSnapshot(collection: collection, sync: off, extensionUpdateRequired: false)
        var statusRequests: [String] = []
        let delegate = MenuDelegate { command in
            statusRequests.append(command.operation)
            return try JSONEncoder().encode(snapshot)
        }
        let menu = delegate.makeMenu()
        let topActions = menu.items.filter { !$0.isHidden }.compactMap { $0.action.map(NSStringFromSelector) }
        precondition(topActions == ["openViewerSettings", "showSettings", "terminate:"])
        precondition(menu.items.first { $0.keyEquivalent == "," }?.action == NSSelectorFromString("showSettings"))
        precondition(MenuDelegate.statusImage(attention: false, description: "History Sync")?.isTemplate == true)
        precondition(MenuDelegate.statusImage(attention: true, description: "History Sync")?.isTemplate == true)
        delegate.menuWillOpen(menu)
        for _ in 0..<20 { try await Task.sleep(for: .milliseconds(10)) }
        precondition(statusRequests == ["menuStatus"], "menu loads one read-only overview")
        let visible = menu.items.filter { !$0.isHidden }.map { $0.title }
        precondition(visible.contains("Browser Sync · Off"))
        precondition(visible.contains("Pending browser deliveries 2 · Automatic retries 1"))
        precondition(visible.contains("History Collection · Waiting for Database"))
        precondition(visible.contains { $0.contains("Edge · Work") })
        precondition(visible.contains { $0.hasPrefix("Last visit received from extension") && !$0.contains("Unverified") })
        precondition(visible.contains("Collect History Now"))
        precondition(!visible.contains("Resolve Sync Issue…"), "an intentional OFF preference suppresses sync recovery")
        let now = Date()
        let localReady = MenuStatusPresentation(snapshot: snapshot, viewer: .ready(now), loading: false)
        precondition(!localReady.collection.attention && !localReady.sync.attention && !localReady.viewer.attention)
        precondition(localReady.viewer.actions == [.openHistory])
        precondition(localReady.viewer.details.contains("Access from other devices is unverified"))
        let unavailable = MenuStatusPresentation(snapshot: nil, viewer: .unavailable(lastReady: now), loading: false)
        precondition(unavailable.viewer.actions == [.retryViewer, .viewerSettings] && unavailable.viewer.attention)
        precondition(!unavailable.sync.attention)
        let blocked = HealthSnapshot(enabled: false, syncRequested: true, activeProfileID: "edge:preview", runtimeState: "blocked",
            issueCode: AgentIssueCode.historyIdentityChanged, pendingBrowserToSafari: 0,
            pendingSafariToBrowser: 2, recoveryCount: 1, unrecoverableCount: 0)
        let needsRecovery = MenuStatusPresentation(snapshot: .init(collection: collection, sync: blocked,
            extensionUpdateRequired: false), viewer: .off, loading: false)
        precondition(needsRecovery.sync.actions == [.resolveSync] && needsRecovery.sync.attention)
        let syncSwitch = NSSwitch()
        precondition(MenuDelegate.displaySyncPreference(blocked, canEnable: false, on: syncSwitch)
            == "Browser sync is on. Delivery is paused.")
        precondition(syncSwitch.state == .on && syncSwitch.isEnabled && !syncSwitch.isHidden,
                     "a blocked delivery leaves the saved preference on and lets the user switch it off")
        precondition(MenuDelegate.displaySyncPreference(off, canEnable: false, on: syncSwitch) == nil)
        precondition(syncSwitch.state == .off && !syncSwitch.isEnabled && !syncSwitch.isHidden)
        precondition(MenuDelegate.displaySyncPreference(off, canEnable: true, on: syncSwitch) == nil)
        precondition(syncSwitch.state == .off && syncSwitch.isEnabled && !syncSwitch.isHidden)
        precondition(MenuDelegate.displaySyncPreference(nil, canEnable: true, on: syncSwitch)
            == "Saved browser sync setting is unavailable.")
        precondition(!syncSwitch.isEnabled && syncSwitch.isHidden, "an unknown saved setting cannot be presented as off")
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
        var cloud = CloudDeliveryCoordinator()
        for index in 1...3 {
            try cloud.reserve(id: "synthetic-\(index)", profileID: "edge:preview", provider: .safari,
                url: URL(string: "https://example.com/preview/\(index)")!, now: now)
            try cloud.recordLocalDelivery(id: "synthetic-\(index)", visitID: String(index), time: now,
                now: now, generation: Int64(index + 40), databaseIdentity: "preview")
        }
        cloud.setSafariAssist(enabled: true, now: now)
        let diagnostics = cloud.diagnostics(profileID: "edge:preview")
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
        detailed.close()
        print("PASS: three menu domains, independent statuses and direct actions; menu and diagnostics use read-only commands")
    }
}
