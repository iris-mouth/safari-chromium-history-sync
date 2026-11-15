import AppKit
import Darwin
import SafariSyncCore
import ServiceManagement

@MainActor
final class MenuDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let agentBundleIdentifier = ProductIdentity.agentBundleIdentifier
    private let setupCoordinator = SetupCoordinator()
    private var statusItem: NSStatusItem?
    private var healthItem = NSMenuItem(title: "Checking Sync Status…", action: nil, keyEquivalent: "")
    private var compatibilityItem = NSMenuItem(title: "View Compatibility…", action: #selector(showCompatibility), keyEquivalent: "")
    private var profileItem = NSMenuItem(title: "Choose Browser to Sync…", action: #selector(changeProfile), keyEquivalent: "")
    private var recoveryItem = NSMenuItem(title: "Resolve Sync Issue…", action: #selector(resolveBlockedIssue), keyEquivalent: "")
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
                catch { showMessage(title: "Web Viewer Unavailable", detail: "Check the viewer settings and whether local port 8766 is already in use.") }
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
        menu.addItem(healthItem)
        menu.addItem(.separator())
        menu.addItem(withTitle: "View Sync Status…", action: #selector(showSyncStatus), keyEquivalent: "")
        menu.addItem(profileItem)
        menu.addItem(withTitle: "Configure Safari Sync Assist…", action: #selector(configureSafariAssist), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Configure History Collection…", action: #selector(configureCollection), keyEquivalent: "")
        menu.addItem(withTitle: "Collect History Now", action: #selector(collectNow), keyEquivalent: "")
        menu.addItem(withTitle: "Configure Web Viewer…", action: #selector(configureViewer), keyEquivalent: "")
        menu.addItem(withTitle: "Open History on the Web", action: #selector(openWeb), keyEquivalent: "")
        menu.addItem(withTitle: "Turn Sync On or Off…", action: #selector(toggleSync), keyEquivalent: "")
        menu.addItem(withTitle: "Set Up Extensions & Login…", action: #selector(showSetup), keyEquivalent: "")
        let troubleshooting = NSMenu()
        troubleshooting.addItem(compatibilityItem)
        troubleshooting.addItem(recoveryItem)
        troubleshooting.addItem(withTitle: "Open Detailed Diagnostics…", action: #selector(showCloudDiagnostics), keyEquivalent: "")
        let troubleshootingItem = NSMenuItem(title: "Troubleshooting", action: nil, keyEquivalent: "")
        troubleshootingItem.submenu = troubleshooting
        menu.addItem(troubleshootingItem)
        menu.addItem(withTitle: "Refresh Status", action: #selector(refreshStatus), keyEquivalent: "r")
        menu.addItem(.separator())
        let quit = menu.addItem(withTitle: "Quit History Sync", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        for item in menu.items + troubleshooting.items where item.action != nil { item.target = self }
        quit.target = NSApp
        menu.items.first(where: { $0.action == #selector(showSyncStatus) })?.toolTip = "View sync status without adding history or changing settings."
        profileItem.toolTip = "View connected browsers. Confirm a choice to sync that browser's history with Safari."
        recoveryItem.toolTip = "View the cause and recovery options. Review the changes before applying them."
        profileItem.isHidden = true
        recoveryItem.isHidden = true
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
            showMessage(title: "No Supported Browser Found", detail: "Install Google Chrome Stable or Microsoft Edge Stable, then run setup again.")
            return
        }

        let alert = NSAlert()
        alert.messageText = "Set Up Extensions & Login"
        alert.informativeText = "Choose the browsers you want to sync. Start Setup registers their connection settings and Open at Login, restarts the sync service, and opens their extension pages.\n\n" + compatibilityDescription()
        alert.addButton(withTitle: "Start Setup")
        alert.addButton(withTitle: "Cancel")
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
                title: "Load the Browser Extension",
                detail: "On the browser's extensions page, enable Developer mode, choose Load unpacked, and select the ChromiumExtension folder shown in Finder."
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
        alert.messageText = "Open at Login Needs Approval"
        alert.informativeText = "Allow the app in System Settings to start syncing automatically when you log in."
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Later")
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
                userInfo: [NSLocalizedDescriptionKey: "\(ProductIdentity.agentBundleName) must be installed beside \(ProductIdentity.productName).app."]
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
            showMessage(title: "Sync Service Unavailable", detail: "Check the connection using Set Up Extensions & Login… in the menu.")
            await refreshStatusAsync()
            return
        }
        if health.runtimeState == "blocked" {
            showBlockedIssue(health.issueCode)
            await refreshStatusAsync()
            return
        }
        if health.activeProfileID == nil, health.connectedProfiles.count == 1,
           let profile = health.connectedProfiles.first {
            do {
                try await selectProfile(profile.profileID)
                showMessage(title: "Setup Complete", detail: "Connected to \(profile.displayName).")
            } catch {
                NSAlert(error: error).runModal()
            }
        } else if health.activeProfileID == nil, health.connectedProfiles.count > 1 {
            latestHealth = health
            changeProfile()
        } else if health.connectedProfiles.isEmpty {
            showMessage(title: "Waiting for the Extension", detail: "Load the extension, then choose Refresh Status in the menu.")
        } else {
            showMessage(title: "Setup Complete", detail: "History sync is ready.")
        }
        await refreshStatusAsync()
    }

    @objc private func changeProfile() {
        guard let health = latestHealth, !health.connectedProfiles.isEmpty else {
            showMessage(title: "No Browser Connected", detail: "Open a browser with the extension enabled, then choose Refresh Status in the menu.")
            return
        }
        let alert = NSAlert()
        alert.messageText = "Choose a Browser to Sync with Safari"
        alert.informativeText = "Sync with This Browser switches two-way history sync to the selected profile. Pending deliveries stay with their original profile and are not sent to another profile."
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 360, height: 28))
        for profile in health.connectedProfiles {
            popup.addItem(withTitle: profile.displayName)
        }
        if let active = health.connectedProfiles.firstIndex(where: \.active) { popup.selectItem(at: active) }
        alert.accessoryView = popup
        alert.addButton(withTitle: "Sync with This Browser")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let profile = health.connectedProfiles[popup.indexOfSelectedItem]
        Task {
            do {
                try await selectProfile(profile.profileID)
                showMessage(title: "Sync Browser Changed", detail: "Syncing with \(profile.displayName).")
                await refreshStatusAsync()
            } catch {
                NSAlert(error: error).runModal()
            }
        }
    }

    @objc private func refreshStatus() { Task { await refreshStatusAsync() } }

    private func refreshStatusAsync() async {
        do {
            var health = try await requestHealth()
            if health.runtimeState == "ready",
               health.activeProfileID == nil,
               health.connectedProfiles.count == 1,
               let profile = health.connectedProfiles.first {
                try await selectProfile(profile.profileID)
                health = try await requestHealth()
            }
            latestHealth = health
            profileItem.isHidden = health.connectedProfiles.isEmpty
            recoveryItem.isHidden = health.runtimeState != "blocked"
            if health.runtimeState == "initializing" {
                healthItem.title = "Starting Sync Service…"
            } else if health.runtimeState == "blocked" {
                healthItem.title = message(for: health.issueCode)
            } else if let active = health.activeProfileID,
                      let profile = health.connectedProfiles.first(where: { $0.profileID == active }) {
                healthItem.title = "Syncing · \(profile.displayName)"
            } else if health.activeProfileID != nil {
                healthItem.title = "Waiting for Browser Extension"
            } else if health.connectedProfiles.isEmpty {
                healthItem.title = "Waiting for Browser Extension"
            } else {
                healthItem.title = "Choose a Browser to Sync"
            }
        } catch {
            latestHealth = nil
            profileItem.isHidden = true
            recoveryItem.isHidden = true
            healthItem.title = "Sync Service Unavailable"
        }
    }

    private func requestHealth() async throws -> HealthSnapshot {
        let response = try await requestAsync(MenuCommand(operation: "status"))
        return try JSONDecoder().decode(HealthSnapshot.self, from: response)
    }

    @objc private func showSyncStatus() {
        if statusWindow == nil {
            statusWindow = SyncStatusWindow { [weak self] command in
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
                    showMessage(title: "Cannot Configure Sync Assist", detail: "Check that the sync service is connected and a browser is selected.")
                    return
                }
                let data = try await requestAsync(MenuCommand(operation: "cloudStatus", profileID: profile))
                let diagnostics = try JSONDecoder().decode(CloudDiagnostics.self, from: data)
                let enabled = diagnostics.safariAssist?.enabled == true
                let alert = NSAlert()
                alert.messageText = "Safari Sync Assist"
                alert.informativeText = "When added Safari history is waiting to sync, load example.com in a dedicated tab to prompt Safari's native sync. This adds browsing history that may reach other devices. Safari Automation permission is required on first use.\n\nAttempts start after 90 seconds. Without progress, retries back off from 5 minutes to 1 hour. Other tabs are left alone."
                let checkbox = NSButton(checkboxWithTitle: "Enable automatic sync assist in a dedicated tab", target: nil, action: nil)
                checkbox.state = enabled ? .on : .off
                checkbox.frame = NSRect(x: 0, y: 0, width: 420, height: 24)
                alert.accessoryView = checkbox
                alert.addButton(withTitle: "Save Settings")
                alert.addButton(withTitle: "Cancel")
                guard alert.runModal() == .alertFirstButtonReturn, (checkbox.state == .on) != enabled else { return }
                let response = try await requestAsync(MenuCommand(operation: "cloudSafariAssist", profileID: profile,
                    result: checkbox.state == .on ? "enable" : "disable"))
                if let failure = try? JSONDecoder().decode(TypedError.self, from: response), failure.type == "error" { throw failure }
                _ = try JSONDecoder().decode(CloudDiagnostics.self, from: response)
                statusWindow?.refresh()
            } catch {
                showMessage(title: "Could Not Save Settings", detail: "Check the sync service connection and try again.")
            }
        }
    }

    @objc private func showCloudDiagnostics() {
        Task { [self] in
            do {
                let health = try await requestHealth()
                guard health.runtimeState == "ready", let profile = health.activeProfileID else {
                    showMessage(title: "Cannot Open Detailed Diagnostics", detail: "Resolve the sync issue and select a browser to sync.")
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
                showMessage(title: "Sync Service Unavailable", detail: "Check the connection using Refresh Status or Set Up Extensions & Login… in the menu.")
            }
        }
    }

    private func selectProfile(_ profileID: String) async throws {
        let response = try await requestAsync(MenuCommand(operation: "selectProfile", profileID: profileID))
        if let failure = try? JSONDecoder().decode(TypedError.self, from: response),
           failure.type == "error" {
            throw failure
        }
        let status = try JSONDecoder().decode(ProfileSwitchStatus.self, from: response)
        guard status.state == "ACTIVE" else {
            throw TypedError(code: "PROFILE_SELECTION_FAILED", retryable: true)
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
            alert.informativeText = "Check Full Disk Access for \(ProductIdentity.agentBundleName) in System Settings. Then restart the sync service using Set Up Extensions & Login… in the menu."
            alert.addButton(withTitle: "Open Access Settings")
            alert.addButton(withTitle: "Later")
            if alert.runModal() == .alertFirstButtonReturn,
               let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
                NSWorkspace.shared.open(url)
            }
        case AgentIssueCode.runtimeUnsupported:
            alert.informativeText = "The macOS runtime, Safari history database structure, or sync state is unsupported. Pending deliveries are preserved. Check for a compatible app update."
            alert.runModal()
        case AgentIssueCode.historyIdentityChanged, AgentIssueCode.historyAnchorInvalid:
            alert.informativeText = "Safari history was replaced or changed. Resume from the current end of history to sync new visits without importing older history again. The selected browser, pending deliveries, and retry records are preserved."
            alert.addButton(withTitle: "Resume from Current History")
            alert.addButton(withTitle: "Cancel")
            if alert.runModal() == .alertFirstButtonReturn {
                Task { await runRecoveryCommand(RecoveryCommandPolicy.resetSafariCursor) }
            }
        case AgentIssueCode.stateUnreadable:
            alert.informativeText = "Saved sync state could not be read. Resetting it may discard pending deliveries and the browser selection. Safari and Chrome/Edge browsing history is preserved, and sync restarts from the current end of history."
            alert.addButton(withTitle: "Reset Sync State & Resume")
            alert.addButton(withTitle: "Cancel")
            if alert.runModal() == .alertFirstButtonReturn {
                Task { await runRecoveryCommand(RecoveryCommandPolicy.resetAgentState) }
            }
        case AgentIssueCode.keychainUnavailable:
            alert.informativeText = "Check the Keychain lock and access permissions, then restart the sync service using Set Up Extensions & Login… in the menu."
            alert.runModal()
        default:
            alert.informativeText = "Check the connection settings using Set Up Extensions & Login… in the menu."
            alert.runModal()
        }
    }

    private func message(for issue: String?) -> String {
        switch issue {
        case AgentIssueCode.runtimeUnsupported: "Sync Stopped: Compatibility Check Failed"
        case AgentIssueCode.historyIdentityChanged: "Sync Stopped: Safari History Database Replaced"
        case AgentIssueCode.historyAnchorInvalid: "Sync Stopped: Safari History Changed"
        case AgentIssueCode.safariAccessUnavailable: "Safari History Access Required"
        case AgentIssueCode.keychainUnavailable: "Sync Stopped: Keychain Unavailable"
        case AgentIssueCode.stateUnreadable: "Sync Stopped: Saved State Unreadable"
        case "agentVersionMismatch": "Restart the Updated Sync Service"
        case "legacyWriterDetected": "Sync Stopped: Legacy Writer Detected"
        case "extensionNotConnected": "Waiting for the Extension"
        default: "Sync Service Unavailable"
        }
    }

    private func showLegacyBlock(_ paths: [String]) {
        showMessage(title: "Legacy Sync Writer Detected", detail: "Stop the legacy sync writer before running setup.\n\n" + paths.joined(separator: "\n"))
    }

    @objc private func resolveBlockedIssue() {
        showBlockedIssue(latestHealth?.issueCode)
    }

    @objc private func showCompatibility() {
        Task {
            latestHealth = try? await requestHealth()
            showMessage(title: "Compatibility on This Mac", detail: compatibilityDescription())
        }
    }

    private func compatibilityDescription() -> String {
        guard let health = latestHealth else { return "Compatibility is not yet known. Connect to the sync service to check it." }
        if health.issueCode == AgentIssueCode.runtimeUnsupported {
            return "Sync is stopped because compatibility checks failed. Pending deliveries are preserved."
        }
        guard let compatibility = health.compatibility else { return "Compatibility has not been checked yet." }
        let runtime = compatibility.runtime
        let evidence = compatibility.status == .tested
            ? "This version has a verified receiving-device sync result in this environment."
            : "Compatibility checks passed. Receiving-device sync with this version has not been verified in this environment."
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
                ? "Sync resumed from the current end of Safari history. Pending deliveries are preserved."
                : "Sync state was reset and sync resumed from the current end of Safari history. Safari and Chrome/Edge browsing history is preserved."
            showMessage(title: "Sync Resumed", detail: detail)
        } catch {
            NSAlert(error: error).runModal()
            await refreshStatusAsync()
        }
    }

    @objc private func configureCollection() {
        Task {
            do {
                let data = try await requestAsync(MenuCommand(operation: "collectionStatus"))
                if let error = try? JSONDecoder().decode(TypedError.self, from: data), error.type == "error" { throw error }
                let reply = try JSONDecoder().decode(CollectionReply.self, from: data)
                let candidateData = try await requestAsync(MenuCommand(operation: "collectionCandidates"))
                if let error = try? JSONDecoder().decode(TypedError.self, from: candidateData), error.type == "error" { throw error }
                let discovery = try JSONDecoder().decode(CollectionCandidates.self, from: candidateData)
                let candidates = discovery.candidates
                let selected = Set(reply.sources.map(\.id))
                let alert = NSAlert()
                alert.messageText = "History Collection"
                alert.informativeText = "Choose the browsers and profiles to keep in the history viewer. Removing a source removes its collected records. Pausing collection keeps them."
                if !discovery.unavailableBrowsers.isEmpty {
                    alert.informativeText += "\n\nCould not read profiles for \(discovery.unavailableBrowsers.joined(separator: ", ")). Check Full Disk Access for the Agent."
                }
                alert.addButton(withTitle: "Save")
                alert.addButton(withTitle: "Cancel")
                let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 5
                let enabled = NSButton(checkboxWithTitle: "Collect history", target: nil, action: nil)
                enabled.state = reply.enabled ? .on : .off; stack.addArrangedSubview(enabled)
                var controls: [(HistoryCollectionSource, NSButton)] = []
                for candidate in candidates {
                    let status = reply.statuses.first { $0.id == candidate.id }
                    let state = status.map { item in
                        let last = item.lastSuccess.map { Date(timeIntervalSince1970: $0).formatted(date: .abbreviated, time: .shortened) } ?? "never"
                        return " — \(item.state), \(item.count) saved, last success: \(last)"
                    } ?? ""
                    let button = NSButton(checkboxWithTitle: "\(candidate.browserType) · \(candidate.profileName)\(state)", target: nil, action: nil)
                    button.state = selected.contains(candidate.id) ? .on : .off
                    stack.addArrangedSubview(button); controls.append((candidate, button))
                }
                stack.frame = NSRect(x: 0, y: 0, width: 440, height: max(54, CGFloat(candidates.count + 1) * 27))
                let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 455, height: min(350, stack.frame.height)))
                scroll.hasVerticalScroller = true; scroll.documentView = stack; alert.accessoryView = scroll
                guard alert.runModal() == .alertFirstButtonReturn else { return }
                let chosen = controls.filter { $0.1.state == .on }.map(\.0)
                let shouldCollect = enabled.state == .on
                let json = String(decoding: try JSONEncoder().encode(chosen), as: UTF8.self)
                try await checkCommand(MenuCommand(operation: "setCollectionSources", snapshotJSON: json))
                try await checkCommand(MenuCommand(operation: "setCollectionEnabled", result: shouldCollect ? "enable" : "disable"))
                try registerLoginItemIfNeeded()
            } catch { NSAlert(error: error).runModal() }
        }
    }

    private func checkCommand(_ command: MenuCommand) async throws {
        let data = try await requestAsync(command)
        if let error = try? JSONDecoder().decode(TypedError.self, from: data), error.type == "error" { throw error }
    }

    @objc private func collectNow() {
        Task {
            do { try await checkCommand(MenuCommand(operation: "collectNow")); showMessage(title: "Collection Started", detail: "Selected sources will be checked in the background.") }
            catch { NSAlert(error: error).runModal() }
        }
    }

    @objc private func toggleSync() {
        Task {
            do {
                let data = try await requestAsync(MenuCommand(operation: "syncPreference"))
                if let error = try? JSONDecoder().decode(TypedError.self, from: data), error.type == "error" { throw error }
                let enabled = try JSONDecoder().decode(SyncPreferenceStatus.self, from: data).enabled
                let alert = NSAlert(); alert.messageText = enabled ? "Turn Off Browser Sync?" : "Turn On Browser Sync?"
                alert.informativeText = "History collection and Web viewing have separate settings. Pending sync work is retained."
                alert.addButton(withTitle: enabled ? "Turn Off" : "Turn On"); alert.addButton(withTitle: "Cancel")
                guard alert.runModal() == .alertFirstButtonReturn else { return }
                try await checkCommand(MenuCommand(operation: "setSyncEnabled", result: enabled ? "disable" : "enable"))
                await refreshStatusAsync()
            } catch { NSAlert(error: error).runModal() }
        }
    }

    @objc private func configureViewer() {
        let defaults = UserDefaults.standard
        let alert = NSAlert(); alert.messageText = "Web Viewer"
        alert.informativeText = "Enter your Tailscale login and the HTTPS URL served by Tailscale Serve. Only requests from this login are accepted. Configure Serve separately before opening the viewer."
        alert.addButton(withTitle: "Save"); alert.addButton(withTitle: "Cancel")
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 8
        let enabled = NSButton(checkboxWithTitle: "Enable Web viewer", target: nil, action: nil)
        enabled.state = defaults.bool(forKey: "viewerEnabled") ? .on : .off
        let owner = NSTextField(string: defaults.string(forKey: "viewerOwner") ?? ""); owner.placeholderString = "Tailscale login"
        let origin = NSTextField(string: defaults.string(forKey: "viewerOrigin") ?? ""); origin.placeholderString = "https://your-device.tailnet.ts.net/"
        owner.widthAnchor.constraint(equalToConstant: 420).isActive = true; origin.widthAnchor.constraint(equalToConstant: 420).isActive = true
        stack.addArrangedSubview(enabled); stack.addArrangedSubview(owner); stack.addArrangedSubview(origin)
        stack.frame = NSRect(x: 0, y: 0, width: 430, height: 100); alert.accessoryView = stack
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let login = owner.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let address = origin.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let shouldEnable = enabled.state == .on
        if shouldEnable {
            guard !login.isEmpty, let url = URL(string: address), url.scheme?.lowercased() == "https", url.host != nil,
                  url.user == nil, url.password == nil, url.fragment == nil, url.query == nil,
                  (url.path.isEmpty || url.path == "/") else {
                showMessage(title: "Viewer Settings Incomplete", detail: "Enter a Tailscale login and an HTTPS URL."); return
            }
        }
        Task {
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
            } catch { NSAlert(error: error).runModal() }
        }
    }

    @objc private func openWeb() {
        guard UserDefaults.standard.bool(forKey: "viewerEnabled"),
              let address = UserDefaults.standard.string(forKey: "viewerOrigin"), let url = URL(string: address) else {
            showMessage(title: "Web Viewer Is Off", detail: "Configure and enable the Web viewer first."); return
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
        let process = Process(); process.executableURL = executable
        process.arguments = ["--database", db.path, "--assets", bundle.appendingPathComponent("Contents/Resources/Web").path, "--owner", owner, "--port", "8766", "--owned-stdin"]
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
        Bundle.main.bundleURL.deletingLastPathComponent()
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
