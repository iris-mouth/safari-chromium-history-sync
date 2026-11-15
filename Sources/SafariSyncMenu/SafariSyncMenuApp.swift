import AppKit
import Darwin
import SafariSyncCore
import ServiceManagement

@MainActor
final class MenuDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let agentBundleIdentifier = ProductIdentity.agentBundleIdentifier
    private let setupCoordinator = SetupCoordinator()
    private var statusItem: NSStatusItem?
    private var settingsWindow: NSWindow?
    private let viewerEnabled = NSButton(checkboxWithTitle: NSLocalizedString("Enable Web viewer", comment: ""), target: nil, action: nil)
    private let viewerOwner = NSTextField()
    private let viewerOrigin = NSTextField()
    private let viewerFeedback = NSTextField(wrappingLabelWithString: "")
    private var browserCheckboxes: [SupportedBrowser: NSButton] = [:]
    private var setupStartButton: NSButton?
    private var latestHealth: HealthSnapshot?
    private var cloudWindow: CloudDiagnosticsWindow?
    private var statusWindow: SyncStatusWindow?
    private var viewerProcess: Process?
    private var viewerLifetime: FileHandle?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = ProductIdentity.menuBarLabel
        item.menu = makeMenu()
        statusItem = item

        let setupState = setupCoordinator.inspect()
        if !setupState.legacyArtifacts.isEmpty { showLegacyBlock(setupState.legacyArtifacts) }
        Task {
            // Any previous Agent belonged to an earlier Menu process. Restart it
            // so the new Menu's ownership token governs its entire lifetime.
            try? await launchAgent(forceRestart: true)
            if UserDefaults.standard.bool(forKey: "viewerEnabled") {
                do { try await startViewer() }
                catch { showMessage(title: NSLocalizedString("Web Viewer Unavailable", comment: ""), detail: NSLocalizedString("Check the viewer settings and whether local port 8767 is already in use.", comment: "")) }
            }
            await refreshStatusAsync()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let viewer = stopViewer() {
            for _ in 0..<20 where viewer.isRunning { usleep(100_000) }
            if viewer.isRunning { kill(viewer.processIdentifier, SIGKILL) }
        }
        stopAgent()
    }

    func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self
        for (name, action) in [("Open History", #selector(openWeb)), ("View Status", #selector(showSyncStatus)), ("Collect History Now", #selector(collectNow))] {
            menu.addItem(withTitle: NSLocalizedString(name, comment: ""), action: action, keyEquivalent: "").target = self
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: NSLocalizedString("Settings…", comment: ""), action: #selector(showSettings), keyEquivalent: ",").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: NSLocalizedString("Quit History Sync", comment: ""), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q").target = NSApp
        return menu
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showSyncStatus() }
        return true
    }

    func menuWillOpen(_ menu: NSMenu) {
        Task { await refreshStatusAsync() }
    }

    @objc private func showSetup() {
        let inspected = setupCoordinator.inspect()
        if !inspected.legacyArtifacts.isEmpty {
            showLegacyBlock(inspected.legacyArtifacts)
            return
        }
        let browsers = setupCoordinator.availableBrowsers()
        guard !browsers.isEmpty else {
            showMessage(title: NSLocalizedString("No Supported Browser Found", comment: ""), detail: NSLocalizedString("Install Google Chrome Stable or Microsoft Edge Stable, then run setup again.", comment: ""))
            return
        }

        let alert = NSAlert()
        alert.messageText = NSLocalizedString("Set Up Extensions & Login", comment: "")
        alert.informativeText = NSLocalizedString("Choose the browsers you want to sync. Start Setup registers their connection settings and Open at Login, restarts the sync service, and opens their extension pages.\n\n", comment: "") + compatibilityDescription()
        alert.addButton(withTitle: NSLocalizedString("Start Setup", comment: ""))
        alert.addButton(withTitle: NSLocalizedString("Cancel", comment: ""))
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        browserCheckboxes.removeAll()
        for browser in browsers {
            let checkbox = NSButton(checkboxWithTitle: browser.displayName, target: self, action: #selector(browserSelectionChanged))
            checkbox.state = inspected.selectedBrowsers.contains(browser) ? .on : .off
            browserCheckboxes[browser] = checkbox
            stack.addArrangedSubview(checkbox)
        }
        stack.frame = NSRect(x: 0, y: 0, width: 360, height: CGFloat(browsers.count * 28))
        alert.accessoryView = stack
        setupStartButton = alert.buttons.first
        updateSetupButton()
        guard alert.runModal() == .alertFirstButtonReturn else {
            setupStartButton = nil
            browserCheckboxes.removeAll()
            return
        }
        let selected = Set(browserCheckboxes.compactMap { browser, checkbox in
            checkbox.state == .on ? browser : nil
        })
        setupStartButton = nil
        browserCheckboxes.removeAll()
        Task { await runSetup(selectedBrowsers: selected) }
    }

    @objc private func browserSelectionChanged() { updateSetupButton() }

    private func updateSetupButton() {
        setupStartButton?.isEnabled = browserCheckboxes.values.contains { $0.state == .on }
    }

    private func runSetup(selectedBrowsers: Set<SupportedBrowser>) async {
        do {
            let state = try setupCoordinator.reconcile(selectedBrowsers: selectedBrowsers)
            guard state.legacyArtifacts.isEmpty else {
                showLegacyBlock(state.legacyArtifacts)
                return
            }
            try registerLoginItemIfNeeded()
            try await launchAgent(forceRestart: true)
            if let extensionDirectory = state.extensionDirectory {
                NSWorkspace.shared.activateFileViewerSelecting([extensionDirectory])
            }
            for browser in selectedBrowsers { setupCoordinator.openExtensionsPage(for: browser) }
            showMessage(
                title: NSLocalizedString("Load the Browser Extension", comment: ""),
                detail: NSLocalizedString("On the browser's extensions page, enable Developer mode, choose Load unpacked, and select the ChromiumExtension folder shown in Finder.", comment: "")
            )
            await finishSetup(with: await waitForHealth())
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    private func registerLoginItemIfNeeded() throws {
        let loginItem = SMAppService.mainApp
        if try LoginItemRegistration.ensure(status: { loginItem.status }, register: { try loginItem.register() }) == .requiresApproval {
            showLoginItemApproval()
        }
    }

    private func showLoginItemApproval() {
        let alert = NSAlert()
        alert.messageText = NSLocalizedString("Open at Login Needs Approval", comment: "")
        alert.informativeText = NSLocalizedString("Allow the app in System Settings to start syncing automatically when you log in.", comment: "")
        alert.addButton(withTitle: NSLocalizedString("Open System Settings", comment: ""))
        alert.addButton(withTitle: NSLocalizedString("Later", comment: ""))
        if alert.runModal() == .alertFirstButtonReturn { SMAppService.openSystemSettingsLoginItems() }
    }

    private func launchAgent(forceRestart: Bool) async throws {
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: agentBundleIdentifier)
        if forceRestart {
            for application in running { application.terminate() }
            for _ in 0..<20 where running.contains(where: { !$0.isTerminated }) {
                try await Task.sleep(for: .milliseconds(100))
            }
            for application in running where !application.isTerminated { application.forceTerminate() }
            if running.contains(where: { !$0.isTerminated }) {
                try await Task.sleep(for: .milliseconds(250))
            }
        } else if !running.isEmpty {
            return
        }
        let agentURL = agentURL()
        let executable = agentURL.appendingPathComponent(
            "Contents/MacOS/\(ProductIdentity.agentExecutableName)"
        )
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw NSError(
                domain: "SafariHistorySync",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "\(ProductIdentity.agentBundleName) must be installed inside \(ProductIdentity.productName).app."]
            )
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.addsToRecentItems = false
        configuration.arguments = ["--menu-pid", "\(ProcessInfo.processInfo.processIdentifier)"]
        try await NSWorkspace.shared.openApplication(at: agentURL, configuration: configuration)
    }

    private func waitForHealth() async -> HealthSnapshot? {
        for _ in 0..<20 {
            if let health = try? await requestHealth(), health.runtimeState != "initializing" {
                return health
            }
            try? await Task.sleep(for: .milliseconds(500))
        }
        return nil
    }

    private func finishSetup(with health: HealthSnapshot?) async {
        guard let health else {
            showMessage(title: NSLocalizedString("Sync Service Unavailable", comment: ""), detail: NSLocalizedString("Check the connection using Set Up Extensions & Login… in the menu.", comment: ""))
            await refreshStatusAsync()
            return
        }
        if health.runtimeState == "blocked" {
            showBlockedIssue(health.issueCode)
            await refreshStatusAsync()
            return
        }
        showMessage(title: NSLocalizedString("Setup Complete", comment: ""), detail: NSLocalizedString("Connect the selected profile in Settings → Browser Sync.", comment: ""))
        await refreshStatusAsync()
    }

    private func refreshStatusAsync() async {
        latestHealth = try? await requestHealth()
    }

    private func requestHealth() async throws -> HealthSnapshot {
        let response = try await requestAsync(MenuCommand(operation: "status"))
        return try JSONDecoder().decode(HealthSnapshot.self, from: response)
    }

    @objc private func showSyncStatus() {
        if statusWindow == nil {
            statusWindow = SyncStatusWindow(viewerStatus: { [weak self] in
                if self?.viewerProcess?.isRunning == true { return "Running" }
                return UserDefaults.standard.bool(forKey: "viewerEnabled") ? "Unavailable" : "Off"
            }) { [weak self] command in
                guard let self else { throw TypedError(code: "MENU_UNAVAILABLE") }
                return try await self.requestAsync(command)
            }
        }
        statusWindow?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        statusWindow?.refresh()
    }

    @objc private func configureSafariAssist() {
        Task {
            do {
                let health = try await requestHealth()
                guard health.runtimeState == "ready", let profile = health.activeProfileID else {
                    showMessage(title: NSLocalizedString("Cannot Configure Sync Assist", comment: ""), detail: NSLocalizedString("Check that the sync service is connected and a browser is selected.", comment: ""))
                    return
                }
                let data = try await requestAsync(MenuCommand(operation: "cloudStatus", profileID: profile))
                let diagnostics = try JSONDecoder().decode(CloudDiagnostics.self, from: data)
                let enabled = diagnostics.safariAssist?.enabled == true
                let alert = NSAlert()
                alert.messageText = NSLocalizedString("Safari Sync Assist", comment: "")
                alert.informativeText = NSLocalizedString("When added Safari history is waiting to sync, load example.com in a dedicated tab to prompt Safari's native sync. This adds browsing history that may reach other devices. Safari Automation permission is required on first use.\n\nAttempts start after 90 seconds. Without progress, retries back off from 5 minutes to 1 hour. Other tabs are left alone.", comment: "")
                let checkbox = NSButton(checkboxWithTitle: NSLocalizedString("Enable automatic sync assist in a dedicated tab", comment: ""), target: nil, action: nil)
                checkbox.state = enabled ? .on : .off
                checkbox.frame = NSRect(x: 0, y: 0, width: 420, height: 24)
                alert.accessoryView = checkbox
                alert.addButton(withTitle: NSLocalizedString("Save Settings", comment: ""))
                alert.addButton(withTitle: NSLocalizedString("Cancel", comment: ""))
                guard alert.runModal() == .alertFirstButtonReturn, (checkbox.state == .on) != enabled else { return }
                let response = try await requestAsync(MenuCommand(operation: "cloudSafariAssist", profileID: profile,
                    result: checkbox.state == .on ? "enable" : "disable"))
                if let failure = try? JSONDecoder().decode(TypedError.self, from: response), failure.type == "error" { throw failure }
                _ = try JSONDecoder().decode(CloudDiagnostics.self, from: response)
                statusWindow?.refresh()
            } catch {
                showMessage(title: NSLocalizedString("Could Not Save Settings", comment: ""), detail: NSLocalizedString("Check the sync service connection and try again.", comment: ""))
            }
        }
    }

    @objc private func showCloudDiagnostics() {
        Task { [self] in
            do {
                let health = try await requestHealth()
                guard health.runtimeState == "ready", let profile = health.activeProfileID else {
                    showMessage(title: NSLocalizedString("Cannot Open Detailed Diagnostics", comment: ""), detail: NSLocalizedString("Resolve the sync issue and select a browser to sync.", comment: ""))
                    return
                }
                if cloudWindow?.profileID != profile {
                    cloudWindow?.close()
                    cloudWindow = CloudDiagnosticsWindow(profileID: profile) { [weak self] command in
                        guard let self else { throw TypedError(code: "MENU_UNAVAILABLE") }
                        return try await self.requestAsync(command)
                    }
                }
                cloudWindow?.showWindow(nil)
                NSApp.activate(ignoringOtherApps: true)
                cloudWindow?.refresh()
            } catch {
                showMessage(title: NSLocalizedString("Sync Service Unavailable", comment: ""), detail: NSLocalizedString("Check the connection using Refresh Status or Set Up Extensions & Login… in the menu.", comment: ""))
            }
        }
    }

    private func requestAsync(_ command: MenuCommand) async throws -> Data {
        try await Task.detached(priority: .userInitiated) { try Self.requestSync(command) }.value
    }

    nonisolated private static func requestSync(_ command: MenuCommand) throws -> Data {
        let runtime = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(
                "Library/Application Support/\(ProductIdentity.applicationSupportDirectoryName)"
            )
        let secret = try IPCSecretStore.load(from: runtime.appendingPathComponent("ipc.secret"), createIfMissing: false)
        let body = try JSONEncoder().encode(command)
        let authenticated = SharedSecret.authenticate(body: body, role: "menu", secret: secret)
        return try LocalIPCClient(socketPath: runtime.appendingPathComponent("agent.sock").path)
            .request(JSONEncoder().encode(authenticated))
    }

    private func showBlockedIssue(_ issue: String?) {
        let alert = NSAlert()
        alert.messageText = message(for: issue)
        switch issue {
        case AgentIssueCode.safariAccessUnavailable:
            alert.informativeText = String(format: NSLocalizedString("Check Full Disk Access for %@ in System Settings. Then restart the sync service using Set Up Extensions & Login… in the menu.", comment: ""), String(describing: ProductIdentity.agentBundleName))
            alert.addButton(withTitle: NSLocalizedString("Open Access Settings", comment: ""))
            alert.addButton(withTitle: NSLocalizedString("Later", comment: ""))
            if alert.runModal() == .alertFirstButtonReturn,
               let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
                NSWorkspace.shared.open(url)
            }
        case AgentIssueCode.runtimeUnsupported:
            alert.informativeText = NSLocalizedString("The macOS runtime, Safari history database structure, or sync state is unsupported. Pending deliveries are preserved. Check for a compatible app update.", comment: "")
            alert.runModal()
        case AgentIssueCode.historyIdentityChanged, AgentIssueCode.historyAnchorInvalid:
            alert.informativeText = NSLocalizedString("Safari history was replaced or changed. Resume from the current end of history to sync new visits without importing older history again. The selected browser, pending deliveries, and retry records are preserved.", comment: "")
            alert.addButton(withTitle: NSLocalizedString("Resume from Current History", comment: ""))
            alert.addButton(withTitle: NSLocalizedString("Cancel", comment: ""))
            if alert.runModal() == .alertFirstButtonReturn {
                Task { await runRecoveryCommand(RecoveryCommandPolicy.resetSafariCursor) }
            }
        case AgentIssueCode.stateUnreadable:
            alert.informativeText = NSLocalizedString("Saved sync state could not be read. Resetting it may discard pending deliveries and the browser selection. Safari and Chrome/Edge browsing history is preserved, and sync restarts from the current end of history.", comment: "")
            alert.addButton(withTitle: NSLocalizedString("Reset Sync State & Resume", comment: ""))
            alert.addButton(withTitle: NSLocalizedString("Cancel", comment: ""))
            if alert.runModal() == .alertFirstButtonReturn {
                Task { await runRecoveryCommand(RecoveryCommandPolicy.resetAgentState) }
            }
        case AgentIssueCode.keychainUnavailable:
            alert.informativeText = NSLocalizedString("Check the Keychain lock and access permissions, then restart the sync service using Set Up Extensions & Login… in the menu.", comment: "")
            alert.runModal()
        default:
            alert.informativeText = NSLocalizedString("Check the connection settings using Set Up Extensions & Login… in the menu.", comment: "")
            alert.runModal()
        }
    }

    private func message(for issue: String?) -> String {
        switch issue {
        case AgentIssueCode.runtimeUnsupported: NSLocalizedString("Sync Stopped: Compatibility Check Failed", comment: "")
        case AgentIssueCode.historyIdentityChanged: NSLocalizedString("Sync Stopped: Safari History Database Replaced", comment: "")
        case AgentIssueCode.historyAnchorInvalid: NSLocalizedString("Sync Stopped: Safari History Changed", comment: "")
        case AgentIssueCode.safariAccessUnavailable: NSLocalizedString("Safari History Access Required", comment: "")
        case AgentIssueCode.keychainUnavailable: NSLocalizedString("Sync Stopped: Keychain Unavailable", comment: "")
        case AgentIssueCode.stateUnreadable: NSLocalizedString("Sync Stopped: Saved State Unreadable", comment: "")
        case "agentVersionMismatch": NSLocalizedString("Restart the Updated Sync Service", comment: "")
        case "legacyWriterDetected": NSLocalizedString("Sync Stopped: Legacy Writer Detected", comment: "")
        case "extensionNotConnected": NSLocalizedString("Waiting for the Extension", comment: "")
        default: NSLocalizedString("Sync Service Unavailable", comment: "")
        }
    }

    private func showLegacyBlock(_ paths: [String]) {
        showMessage(title: NSLocalizedString("Legacy Sync Writer Detected", comment: ""), detail: "Stop the legacy sync writer before running setup.\n\n" + paths.joined(separator: "\n"))
    }

    @objc private func resolveBlockedIssue() {
        Task {
            do {
                let health = try await requestHealth()
                if let issue = health.issueCode { showBlockedIssue(issue) }
                else { showMessage(title: NSLocalizedString("No sync issue reported", comment: ""), detail: "") }
            } catch { NSAlert(error: error).runModal() }
        }
    }

    @objc private func showCompatibility() {
        Task {
            latestHealth = try? await requestHealth()
            showMessage(title: NSLocalizedString("Compatibility on This Mac", comment: ""), detail: compatibilityDescription())
        }
    }

    private func compatibilityDescription() -> String {
        guard let health = latestHealth else { return NSLocalizedString("Compatibility is not yet known. Connect to the sync service to check it.", comment: "") }
        if health.issueCode == AgentIssueCode.runtimeUnsupported {
            return NSLocalizedString("Sync is stopped because compatibility checks failed. Pending deliveries are preserved.", comment: "")
        }
        guard let compatibility = health.compatibility else { return NSLocalizedString("Compatibility has not been checked yet.", comment: "") }
        let runtime = compatibility.runtime
        let evidence = compatibility.status == .tested
            ? NSLocalizedString("This version has a verified receiving-device sync result in this environment.", comment: "")
            : NSLocalizedString("Compatibility checks passed. Receiving-device sync with this version has not been verified in this environment.", comment: "")
        return "macOS \(runtime.macOSVersion) (\(runtime.macOSBuild)) · Safari \(runtime.safariBuild)\n\n\(evidence)"
    }

    private func runRecoveryCommand(_ operation: String) async {
        do {
            let response = try await requestAsync(MenuCommand(operation: operation))
            if let failure = try? JSONDecoder().decode(TypedError.self, from: response),
               failure.type == "error" {
                throw failure
            }
            let status = try JSONDecoder().decode(RecoveryCommandStatus.self, from: response)
            guard status.state == "READY", status.operation == operation else {
                throw TypedError(code: "RECOVERY_FAILED")
            }
            await refreshStatusAsync()
            let detail = operation == RecoveryCommandPolicy.resetSafariCursor
                ? NSLocalizedString("Sync resumed from the current end of Safari history. Pending deliveries are preserved.", comment: "")
                : NSLocalizedString("Sync state was reset and sync resumed from the current end of Safari history. Safari and Chrome/Edge browsing history is preserved.", comment: "")
            showMessage(title: NSLocalizedString("Sync Resumed", comment: ""), detail: detail)
        } catch {
            NSAlert(error: error).runModal()
            await refreshStatusAsync()
        }
    }

    @objc private func connectPair() {
        Task {
            do {
                let configuration = try JSONDecoder().decode(CollectionReply.self, from: await requestAsync(MenuCommand(operation: "collectionStatus")))
                let health = try await requestHealth()
                if configuration.pair?.extensionID != nil || health.pendingSafariToBrowser + health.recoveryCount > 0 {
                    let alert = NSAlert()
                    alert.messageText = NSLocalizedString("Reconnect selected profile?", comment: "")
                    alert.informativeText = NSLocalizedString("If the extension was reinstalled, connecting its new identity pauses sync and cancels deliveries for the previous identity.", comment: "")
                    alert.addButton(withTitle: NSLocalizedString("Connect Selected Profile", comment: ""))
                    alert.addButton(withTitle: NSLocalizedString("Cancel", comment: ""))
                    guard alert.runModal() == .alertFirstButtonReturn else { return }
                }
                let data = try await requestAsync(MenuCommand(operation: "connectPair"))
                if let error = try? JSONDecoder().decode(TypedError.self, from: data) { throw error }
                let reply = try JSONDecoder().decode([String:String].self, from: data)
                guard let source = reply["source"], let token = reply["token"],
                      let split = source.firstIndex(of: ":"), let browser = SupportedBrowser(rawValue: String(source[..<split])),
                      let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: browser.bundleIdentifier),
                      let binary = Bundle(url: app)?.executableURL, let directory = setupCoordinator.inspect().extensionDirectory else { throw TypedError(code: "PAIR_NOT_READY") }
                let id = try setupCoordinator.extensionID(in: directory)
                let launch = Process()
                launch.executableURL = binary
                launch.arguments = ["--profile-directory=" + String(source[source.index(after: split)...]), "chrome-extension://\(id)/extension/connect.html#\(token)"]
                try launch.run()
            } catch { NSAlert(error: error).runModal() }
        }
    }

    @objc private func configureCollection() {
        Task {
            do {
                let reply = try JSONDecoder().decode(CollectionReply.self, from: await requestAsync(MenuCommand(operation: "collectionStatus")))
                let discovery = try JSONDecoder().decode(CollectionCandidates.self, from: await requestAsync(MenuCommand(operation: "collectionCandidates")))
                let partners = discovery.candidates.filter { $0.browser == .chromium }
                let alert = NSAlert()
                alert.messageText = NSLocalizedString("History Collection", comment: "")
                alert.informativeText = NSLocalizedString("Select the profile to collect and sync with Safari.", comment: "")
                let popup = NSPopUpButton()
                popup.addItem(withTitle: NSLocalizedString("Select a profile", comment: ""))
                for partner in partners {
                    let entry = NSMenuItem(title: "\(partner.browserType) · \(partner.profileName) (\(partner.id))", action: nil, keyEquivalent: "")
                    popup.menu?.addItem(entry)
                }
                if let index = partners.firstIndex(where: { $0.id == reply.pair?.source }) { popup.selectItem(at: index + 1) }
                let enabled = NSButton(checkboxWithTitle: NSLocalizedString("Collect history", comment: ""), target: nil, action: nil)
                enabled.state = reply.enabled ? .on : .off
                let form = NSStackView(views: [popup,enabled])
                form.orientation = .vertical
                form.alignment = .leading
                form.frame = NSRect(x: 0,y: 0,width: 420,height: 65)
                alert.accessoryView = form
                alert.addButton(withTitle: NSLocalizedString("Save", comment: ""))
                alert.addButton(withTitle: NSLocalizedString("Cancel", comment: ""))
                guard alert.runModal() == .alertFirstButtonReturn else { return }
                guard popup.indexOfSelectedItem > 0 else { throw TypedError(code:"PAIR_NOT_READY") }
                let selected = partners[popup.indexOfSelectedItem-1]
                let removed = reply.statuses.filter { $0.id != selected.id && $0.id != "safari:default" }.reduce(Int64(0)) { $0 + $1.count }
                if selected.id != reply.pair?.source && (removed > 0 || reply.pair != nil || (reply.pendingCount ?? 0) > 0) {
                    let count = reply.pendingCount ?? 0
                    let confirm = NSAlert()
                    confirm.messageText = NSLocalizedString("Change collection profile?", comment: "")
                    confirm.informativeText = String(format: NSLocalizedString("Remove %@ collected visits and cancel %@ pending deliveries. Browser history is preserved.", comment: ""), String(removed), String(count))
                    confirm.addButton(withTitle: NSLocalizedString("Change Profile", comment: ""))
                    confirm.addButton(withTitle: NSLocalizedString("Cancel", comment: ""))
                    guard confirm.runModal() == .alertFirstButtonReturn else { return }
                }
                try await checkCommand(MenuCommand(operation: "savePair", profileID: selected.id, result: enabled.state == .on ? "enable" : "disable", snapshotJSON: reply.pair?.revision ?? "", expectedRemoved: removed, expectedPending: reply.pendingCount))
                try registerLoginItemIfNeeded()
                await refreshPairLabel()
            } catch { NSAlert(error: error).runModal() }
        }
    }

    private func checkCommand(_ command: MenuCommand) async throws {
        let data = try await requestAsync(command)
        if let error = try? JSONDecoder().decode(TypedError.self, from: data), error.type == "error" { throw error }
    }

    @objc private func collectNow() {
        Task {
            do { try await checkCommand(MenuCommand(operation: "collectNow")); showMessage(title: NSLocalizedString("Collection Started", comment: ""), detail: NSLocalizedString("Selected sources will be checked in the background.", comment: "")) }
            catch { NSAlert(error: error).runModal() }
        }
    }

    @objc private func toggleSync() {
        Task {
            do {
                let data = try await requestAsync(MenuCommand(operation: "syncPreference"))
                if let error = try? JSONDecoder().decode(TypedError.self, from: data), error.type == "error" { throw error }
                let enabled = try JSONDecoder().decode(SyncPreferenceStatus.self, from: data).enabled
                let alert = NSAlert(); alert.messageText = enabled ? NSLocalizedString("Turn Off Browser Sync?", comment: "") : NSLocalizedString("Turn On Browser Sync?", comment: "")
                alert.informativeText = NSLocalizedString("Sync requires collection and a connected profile. Pausing sync keeps pending deliveries.", comment: "")
                alert.addButton(withTitle: enabled ? NSLocalizedString("Turn Off", comment: "") : NSLocalizedString("Turn On", comment: "")); alert.addButton(withTitle: NSLocalizedString("Cancel", comment: ""))
                guard alert.runModal() == .alertFirstButtonReturn else { return }
                try await checkCommand(MenuCommand(operation: "setSyncEnabled", result: enabled ? "disable" : "enable"))
                await refreshStatusAsync()
            } catch { NSAlert(error: error).runModal() }
        }
    }

    private let pairLabel = NSTextField(wrappingLabelWithString: "")

    private func refreshPairLabel() async {
        do {
            let reply = try JSONDecoder().decode(CollectionReply.self, from: await requestAsync(MenuCommand(operation: "collectionStatus")))
            if let pair = reply.pair, let source = reply.sources.first(where: { $0.id == pair.source }) {
                let state = NSLocalizedString(reply.extensionUpdateRequired == true ? "Reload the bundled extension in the selected profile." : (pair.extensionID == nil ? "Extension not connected" : "Extension connected"), comment: "")
                pairLabel.stringValue = "Safari ↔ " + source.browserType + " · " + source.profileName + " (" + source.id + ")\n" + state
            } else {
                pairLabel.stringValue = NSLocalizedString("Select a profile in History Collection.", comment: "")
            }
        } catch { pairLabel.stringValue = NSLocalizedString("Collection status unavailable", comment: "") }
    }

    @objc private func showSettings() {
        if settingsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 375),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = NSLocalizedString("Settings…", comment: "")
            window.isReleasedWhenClosed = false
            let tabs = NSTabView(frame: window.contentView!.bounds.insetBy(dx: 16, dy: 16))
            window.contentView!.addSubview(tabs)
            func pane(_ title: String, _ actions: [(String, Selector)]) -> NSStackView {
                let page = NSTabViewItem(identifier: title)
                page.label = NSLocalizedString(title, comment: "")
                let container = NSView()
                let stack = NSStackView()
                stack.orientation = .vertical
                stack.alignment = .leading
                stack.spacing = 8
                stack.translatesAutoresizingMaskIntoConstraints = false
                container.addSubview(stack)
                NSLayoutConstraint.activate([
                    stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
                    stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 14),
                    stack.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -16)
                ])
                for (name, action) in actions {
                    stack.addArrangedSubview(NSButton(title: NSLocalizedString(name, comment: ""), target: self, action: action))
                }
                page.view = container
                tabs.addTabViewItem(page)
                return stack
            }
            _ = pane("General", [("Set Up Extensions & Login…", #selector(showSetup)), ("Show Agent for Full Disk Access", #selector(revealAgent)), ("View Compatibility…", #selector(showCompatibility)), ("Resolve Sync Issue…", #selector(resolveBlockedIssue)), ("Open Detailed Diagnostics…", #selector(showCloudDiagnostics))])
            _ = pane("History Collection", [("Configure History Collection…", #selector(configureCollection))])
            let web = pane("Web Viewer", [])
            let defaults = UserDefaults.standard
            viewerEnabled.state = defaults.bool(forKey: "viewerEnabled") ? .on : .off
            web.addArrangedSubview(viewerEnabled)
            for (label, field, key) in [("Tailscale login", viewerOwner, "viewerOwner"), ("Viewer URL", viewerOrigin, "viewerOrigin")] {
                web.addArrangedSubview(NSTextField(labelWithString: NSLocalizedString(label, comment: "")))
                field.setAccessibilityLabel(NSLocalizedString(label, comment: ""))
                field.stringValue = defaults.string(forKey: key) ?? ""
                field.widthAnchor.constraint(equalToConstant: 410).isActive = true
                web.addArrangedSubview(field)
            }
            web.addArrangedSubview(NSButton(title: NSLocalizedString("Save", comment: ""), target: self, action: #selector(saveViewer(_:))))
            web.addArrangedSubview(viewerFeedback)
            let sync = pane("Browser Sync", [("Turn Sync On or Off…", #selector(toggleSync)), ("Connect Selected Profile", #selector(connectPair)), ("Configure Safari Sync Assist…", #selector(configureSafariAssist))])
            sync.insertArrangedSubview(pairLabel, at: 0)
            window.center()
            settingsWindow = window
        }
        Task { await refreshPairLabel() }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func saveViewer(_ sender: NSButton) {
        let defaults = UserDefaults.standard
        let login = viewerOwner.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let address = viewerOrigin.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let shouldEnable = viewerEnabled.state == .on
        if shouldEnable {
            guard !login.isEmpty, let url = URL(string: address), url.scheme?.lowercased() == "https", url.host != nil,
                  url.user == nil, url.password == nil, url.fragment == nil, url.query == nil,
                  (url.path.isEmpty || url.path == "/") else {
                viewerFeedback.stringValue = NSLocalizedString("Enter a Tailscale login and an HTTPS URL.", comment: "")
                return
            }
        }
        sender.isEnabled = false
        Task {
            defer { sender.isEnabled = true }
            do {
                if shouldEnable {
                    try await checkCommand(MenuCommand(operation: "setViewerOrigin", snapshotJSON: address))
                    defaults.set(login, forKey: "viewerOwner"); defaults.set(address, forKey: "viewerOrigin")
                }
                defaults.set(shouldEnable, forKey: "viewerEnabled")
                let previous = stopViewer()
                if let previous {
                    for _ in 0..<30 where previous.isRunning { try await Task.sleep(for: .milliseconds(100)) }
                }
                if shouldEnable { try await startViewer() }
                try registerLoginItemIfNeeded()
                viewerFeedback.stringValue = NSLocalizedString("Saved", comment: "")
            } catch { viewerFeedback.stringValue = error.localizedDescription }
        }
    }

    @objc private func revealAgent() { NSWorkspace.shared.activateFileViewerSelecting([agentURL()]) }

    @objc private func openWeb() {
        guard UserDefaults.standard.bool(forKey: "viewerEnabled"),
              let address = UserDefaults.standard.string(forKey: "viewerOrigin"), let url = URL(string: address) else {
            showMessage(title: NSLocalizedString("Web Viewer Is Off", comment: ""), detail: NSLocalizedString("Configure and enable the Web viewer first.", comment: "")); return
        }
        NSWorkspace.shared.open(url)
    }

    private func startViewer() async throws {
        let defaults = UserDefaults.standard
        guard let owner = defaults.string(forKey: "viewerOwner"), !owner.isEmpty,
              defaults.string(forKey: "viewerOrigin") != nil else { throw TypedError(code: "VIEWER_NOT_CONFIGURED") }
        if viewerProcess?.isRunning == true { return }
        let bundle = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/Safari Chromium History Sync Viewer.app")
        let executable = bundle.appendingPathComponent("Contents/MacOS/SafariSyncViewer")
        guard FileManager.default.isExecutableFile(atPath: executable.path) else { throw TypedError(code: "VIEWER_MISSING") }
        let db = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/\(ProductIdentity.applicationSupportDirectoryName)/Viewing/history.sqlite")
        let process = Process(); process.executableURL = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/HistoryGateway")
        process.arguments = ["--viewer", executable.path, "--origin", defaults.string(forKey: "viewerOrigin")!, "--database", db.path, "--assets", bundle.appendingPathComponent("Contents/Resources/Web").path, "--owner", owner, "--port", "8767"]
        let lifetime = Pipe(); process.standardInput = lifetime
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run()
        try lifetime.fileHandleForReading.close()
        viewerLifetime = lifetime.fileHandleForWriting; viewerProcess = process
        try await Task.sleep(for: .milliseconds(250))
        guard process.isRunning else { viewerProcess = nil; throw TypedError(code: "VIEWER_START_FAILED") }
    }

    @discardableResult private func stopViewer() -> Process? {
        let previous = viewerProcess
        try? viewerLifetime?.close(); viewerLifetime = nil
        if previous?.isRunning == true { previous?.terminate() }
        viewerProcess = nil
        return previous
    }

    private func stopAgent() {
        let applications = NSRunningApplication.runningApplications(withBundleIdentifier: agentBundleIdentifier)
        for application in applications { application.terminate() }
        for _ in 0..<20 where applications.contains(where: { !$0.isTerminated }) { usleep(100_000) }
        for application in applications where !application.isTerminated { application.forceTerminate() }
    }

    private func agentURL() -> URL {
        Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers")
            .appendingPathComponent(ProductIdentity.agentBundleName, isDirectory: true)
    }

    private func showMessage(title: String, detail: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.runModal()
    }

}

@main
@MainActor
struct SafariSyncMenuApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = MenuDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
