import AppKit
import SafariSyncCore
import ServiceManagement

@main @MainActor struct PresentationCheck {
    static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        Task {
            do { try await runChecks(); exit(0) }
            catch {
                FileHandle.standardError.write(Data("AppKit tests failed: \(error)\n".utf8))
                exit(1)
            }
        }
        app.run()
        preconditionFailure("AppKit stopped before the tests completed")
    }

    static func runChecks() async throws {
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
        var statusUnavailable = false
        let formData = Data(#"{"enabled":true,"pair":{"source":"edge:preview","revision":"revision","extensionID":"edge:preview"},"sources":[{"id":"edge:preview","browser":"chromium","browserType":"Edge","profileName":"Work","path":"/synthetic/History"}],"statuses":[]}"#.utf8)
        let candidatesData = Data(#"{"candidates":[{"id":"edge:preview","browser":"chromium","browserType":"Edge","profileName":"Work","path":"/synthetic/History"}],"unavailableBrowsers":[]}"#.utf8)
        let delegate = MenuDelegate { command in
            statusRequests.append(command.operation)
            switch command.operation {
            case "menuStatus":
                if statusUnavailable { throw SyntheticLoginError.failed }
                return try JSONEncoder().encode(snapshot)
            case "collectionStatus": return formData
            case "collectionCandidates": return candidatesData
            case "collectNow":
                try await Task.sleep(for: .milliseconds(50))
                return Data(#"{"accepted":true}"#.utf8)
            default: preconditionFailure("Viewing settings must not perform a write: \(command.operation)")
            }
        }
        let menu = delegate.makeMenu()
        let topActions = menu.items.filter { !$0.isHidden }.compactMap { $0.action.map(NSStringFromSelector) }
        precondition(topActions == ["openWeb", "openCollectionSettings", "openSyncSettings", "openViewerSettings", "showSettings", "terminate:"])
        precondition(menu.items.filter { !$0.isSeparatorItem }.count == 6)
        precondition(menu.items.first?.isEnabled == false, "Open History stays visible while Viewer is off")
        precondition(menu.items.first { $0.keyEquivalent == "," }?.action == NSSelectorFromString("showSettings"))
        precondition(MenuDelegate.statusImage(attention: false, description: "History Sync")?.isTemplate == true)
        precondition(MenuDelegate.statusImage(attention: true, description: "History Sync")?.isTemplate == true)
        delegate.menuWillOpen(menu)
        for _ in 0..<20 { try await Task.sleep(for: .milliseconds(10)) }
        precondition(statusRequests == ["menuStatus"], "menu loads one read-only overview")
        let visible = menu.items.filter { !$0.isHidden }.map { $0.title }
        precondition(visible.contains("Sync: Off"))
        precondition(!visible.contains("Pending browser deliveries 2 · Automatic retries 1"))
        precondition(visible.contains("Collection: Waiting for Database"))
        precondition(!visible.contains { $0.contains("Edge · Work") })
        precondition(!visible.contains { $0.hasPrefix("Last visit received from extension") })
        precondition(!visible.contains("Collect History Now"))
        precondition(!visible.contains("Resolve Sync Issue…"), "an intentional OFF preference suppresses sync recovery")
        let now = Date()
        let localReady = MenuStatusPresentation(snapshot: snapshot, viewer: .ready(now), loading: false)
        precondition(!localReady.collection.attention && !localReady.sync.attention && !localReady.viewer.attention)
        precondition(localReady.canOpenHistory)
        precondition(localReady.viewer.details.contains("Access from other devices is unverified"))
        let unavailable = MenuStatusPresentation(snapshot: nil, viewer: .unavailable(lastReady: now), loading: false)
        precondition(!unavailable.canOpenHistory && unavailable.viewer.attention && unavailable.collection.attention)
        precondition(!unavailable.sync.attention)
        let blocked = HealthSnapshot(enabled: false, syncRequested: true, activeProfileID: "edge:preview", runtimeState: "blocked",
            issueCode: AgentIssueCode.historyIdentityChanged, pendingBrowserToSafari: 0,
            pendingSafariToBrowser: 2, recoveryCount: 1, unrecoverableCount: 0)
        let needsRecovery = MenuStatusPresentation(snapshot: .init(collection: collection, sync: blocked,
            extensionUpdateRequired: false), viewer: .off, loading: false)
        precondition(needsRecovery.sync.attention)
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
        for state in [ViewerReadiness.off, .starting, .unavailable(lastReady: nil)] {
            precondition(!MenuStatusPresentation(snapshot: snapshot, viewer: state, loading: false).canOpenHistory)
        }
        statusUnavailable = true
        delegate.menuWillOpen(menu)
        try await Task.sleep(for: .milliseconds(100))
        precondition(menu.items.filter { !$0.isSeparatorItem && !$0.isHidden }.count == 6)
        precondition(menu.items.contains { $0.title == "Collection: Unavailable" })
        statusUnavailable = false
        let routes = [("openCollectionSettings", "History Collection"), ("openSyncSettings", "Browser Sync"), ("openViewerSettings", "Web Viewer")]
        for (action, tab) in routes {
            precondition(NSApp.sendAction(NSSelectorFromString(action), to: delegate, from: nil))
            try await Task.sleep(for: .milliseconds(100))
            let window = app.windows.first { $0.title == "Settings…" }!
            let tabs = descendants(window.contentView!).compactMap { $0 as? NSTabView }.first!
            precondition(tabs.selectedTabViewItem?.identifier as? String == tab)
        }
        let settings = app.windows.first { $0.title == "Settings…" }!
        defer { settings.close() }
        let tabs = descendants(settings.contentView!).compactMap { $0 as? NSTabView }.first!
        precondition(tabs.tabViewItems.map { $0.identifier as! String } == ["General", "History Collection", "Browser Sync", "Web Viewer"])
        func pane(_ name: String) -> [NSView] {
            descendants(tabs.tabViewItems.first { $0.identifier as? String == name }!.view!)
        }
        let collectionViews = pane("History Collection")
        let profile = collectionViews.compactMap { $0 as? NSPopUpButton }.first!
        precondition(profile.selectedItem?.representedObject as? String == "edge:preview")
        profile.selectItem(at: 0)
        let collectEnabled = collectionViews.compactMap { $0 as? NSButton }.first { $0.identifier?.rawValue == "collectionEnabled" }!
        collectEnabled.state = .off
        let viewerFields = pane("Web Viewer").compactMap { $0 as? NSTextField }
        let origin = viewerFields.first { $0.identifier?.rawValue == "viewerOrigin" }!
        origin.stringValue = "https://draft.example.test/"
        delegate.applicationDidBecomeActive(Notification(name: NSApplication.didBecomeActiveNotification))
        try await Task.sleep(for: .seconds(10.2))
        precondition(statusRequests.filter { $0 == "menuStatus" }.count >= 4, "visible settings refresh without a manual action")
        precondition(statusRequests.filter { $0 == "collectionStatus" }.count == 1, "polling does not reload the editable form")
        precondition(profile.indexOfSelectedItem == 0 && collectEnabled.state == .off)
        precondition(origin.stringValue == "https://draft.example.test/")
        precondition(collectionViews.compactMap { $0 as? NSTextField }.contains { $0.stringValue.contains("Last visit received from extension") })
        precondition(pane("Browser Sync").compactMap { $0 as? NSTextField }.contains { $0.stringValue.contains("Pending browser deliveries 2") })
        for (action, owner) in [("collectNow", "History Collection"), ("restartAgent", "General"), ("openAccessSettings", "General"), ("resolveBlockedIssue", "Browser Sync"), ("retryViewer", "Web Viewer")] {
            let owners = tabs.tabViewItems.filter { item in
                descendants(item.view!).compactMap { $0 as? NSButton }.contains { $0.action == NSSelectorFromString(action) }
            }.map { $0.identifier as! String }
            precondition(owners == [owner], "operation must have a single settings owner: \(action)")
        }
        precondition(statusRequests.allSatisfy { ["menuStatus", "collectionStatus", "collectionCandidates"].contains($0) })
        tabs.selectTabViewItem(withIdentifier: "History Collection")
        let collect = collectionViews.compactMap { $0 as? NSButton }.first { $0.action == NSSelectorFromString("collectNow") }!
        precondition(collect.isEnabled)
        collect.performClick(nil)
        collect.performClick(nil)
        try await Task.sleep(for: .milliseconds(150))
        precondition(statusRequests.filter { $0 == "collectNow" }.count == 1, "only the explicit action collects, with no concurrent duplicate")
        precondition(profile.indexOfSelectedItem == 0 && origin.stringValue == "https://draft.example.test/")
        settings.setContentSize(NSSize(width: 560, height: 460))
        for item in tabs.tabViewItems {
            tabs.selectTabViewItem(item)
            settings.contentView!.layoutSubtreeIfNeeded()
            let scroll = item.view as! NSScrollView
            precondition(scroll.documentView!.frame.height > 0)
            precondition(abs(scroll.documentView!.frame.width - scroll.contentView.bounds.width) < 1)
        }
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
        print("PASS: compact menu, settings navigation and ownership, read-only refresh, drafts and isolated actions")
    }
}
