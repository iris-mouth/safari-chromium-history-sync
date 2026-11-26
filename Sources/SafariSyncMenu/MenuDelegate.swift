import AppKit
import Darwin
import SafariSyncCore
import ServiceManagement

@MainActor
final class MenuDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate {
    private let agentBundleIdentifier = ProductIdentity.agentBundleIdentifier
    private let setupCoordinator = SetupCoordinator()
    private var statusItem: NSStatusItem?
    private var settingsWindow: NSWindow?
    private var settingsTabs: NSTabView?
    private let viewerEnabled = NSButton(checkboxWithTitle: NSLocalizedString("Enable Web viewer", comment: ""), target: nil, action: nil)
    private let viewerOwner = NSTextField()
    private let viewerOrigin = NSTextField()
    private let viewerFeedback = NSTextField(wrappingLabelWithString: "")
    private var browserCheckboxes: [SupportedBrowser: NSButton] = [:]
    private var setupStartButton: NSButton?
    private var latestHealth: HealthSnapshot? { statusSnapshot?.sync }
    private var cloudWindow: CloudDiagnosticsWindow?
    private var statusSnapshot: MenuStatusSnapshot?
    private var statusLoading = true
    private var statusTask: Task<Void, Never>?
    private let requestOverride: ((MenuCommand) async throws -> Data)?
    private var agentRestarting = false
    private var openHistoryItem: NSMenuItem?
    private var collectionItem: NSMenuItem?
    private var syncItem: NSMenuItem?
    private var viewerItem: NSMenuItem?
    private var settingsStatusTask: Task<Void, Never>?
    private var collectionFormLoading = false
    private var collectBusy = false
    private var syncBusy = false
    private var assistBusy = false
    private var connectBusy = false
    private let collectionStatusLabel = NSTextField(wrappingLabelWithString: "")
    private let syncStatusLabel = NSTextField(wrappingLabelWithString: "")
    private let viewerStatusLabel = NSTextField(wrappingLabelWithString: "")
    private let syncIssueLabel = NSTextField(wrappingLabelWithString: "")
    private let collectButton = NSButton()
    private let restartButton = NSButton()
    private let connectButton = NSButton()
    private let viewerRetryButton = NSButton()
    private let collectionGeneralButton = NSButton()
    private let syncGeneralButton = NSButton()

    private struct ViewerSession {
        let id: UUID
        let process: Process
        let input: FileHandle
        var lastReady: Date?
        var pendingRequest: UInt64?
        var nextRequest: UInt64 = 1
        var lastChecked: TimeInterval?
    }

    private struct ViewerReply: Decodable, Sendable {
        let request: UInt64
        let ready: Bool
    }

    private var viewerSession: ViewerSession?
    private var viewerReadiness: ViewerReadiness = .off
    private var viewerChanging = false

    init(request: ((MenuCommand) async throws -> Data)? = nil) {
        requestOverride = request
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        viewerReadiness = UserDefaults.standard.bool(forKey: "viewerEnabled") ? .starting : .off
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem = item
        item.menu = makeMenu()

        let setupState = setupCoordinator.inspect()
        if !setupState.legacyArtifacts.isEmpty { showLegacyBlock(setupState.legacyArtifacts) }
        Task {
            try? await launchAgent(forceRestart: true)
            if UserDefaults.standard.bool(forKey: "viewerEnabled") { startConfiguredViewer() }
            await refreshStatusAsync()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        settingsStatusTask?.cancel()
        if let viewer = stopViewer() {
            for _ in 0..<20 where viewer.isRunning { usleep(100_000) }
            if viewer.isRunning { kill(viewer.processIdentifier, SIGKILL) }
        }
        stopAgent()
    }

    func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        func item(_ title: String, _ action: Selector, _ key: String = "") -> NSMenuItem {
            let item = menu.addItem(withTitle: NSLocalizedString(title, comment: ""), action: action, keyEquivalent: key)
            item.target = self
            return item
        }
        openHistoryItem = item("Open History", #selector(openWeb))
        menu.addItem(.separator())
        collectionItem = item("", #selector(openCollectionSettings))
        syncItem = item("", #selector(openSyncSettings))
        viewerItem = item("", #selector(openViewerSettings))
        menu.addItem(.separator())
        _ = item("Settings…", #selector(showSettings), ",")
        item("Quit History Sync", #selector(NSApplication.terminate(_:)), "q").target = NSApp
        renderStatus()
        return menu
    }

    private func renderStatus() {
        let status = MenuStatusPresentation(snapshot: statusSnapshot, viewer: viewerReadiness, loading: statusLoading)
        for (row, item, label) in [(status.collection, collectionItem, collectionStatusLabel),
                                   (status.sync, syncItem, syncStatusLabel),
                                   (status.viewer, viewerItem, viewerStatusLabel)] {
            item?.title = row.title
            label.stringValue = ([row.title] + row.details).joined(separator: "\n")
        }
        openHistoryItem?.isEnabled = status.canOpenHistory
        collectButton.isEnabled = statusSnapshot?.collection?.enabled == true && !collectBusy
            && statusSnapshot?.collection?.sources.contains(where: { $0.state == "collecting" }) != true
        collectionGeneralButton.isHidden = !status.collection.attention
        restartButton.isEnabled = !agentRestarting && !setupBusy
        if case .unavailable = viewerReadiness { viewerRetryButton.isHidden = false }
        else { viewerRetryButton.isHidden = true }
        viewerRetryButton.isEnabled = !viewerChanging
        updateSyncSettings()
        let attention = status.collection.attention || status.sync.attention || status.viewer.attention
        let description = attention ? NSLocalizedString("History Sync · Needs Attention", comment: "")
            : NSLocalizedString(ProductIdentity.menuBarLabel, comment: "")
        statusItem?.button?.image = Self.statusImage(attention: attention, description: description)
        statusItem?.button?.toolTip = description
        statusItem?.button?.setAccessibilityLabel(description)
    }

    static func statusImage(attention: Bool, description: String) -> NSImage? {
        let image = NSImage(systemSymbolName: attention ? "exclamationmark.circle" : "clock.arrow.circlepath",
                            accessibilityDescription: description)
        image?.isTemplate = true
        return image
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showSettings() }
        return true
    }

    func menuWillOpen(_ menu: NSMenu) {
        requestViewerReadiness()
        Task { await refreshStatusAsync() }
    }

    private let compatibilityInfo = NSTextField(wrappingLabelWithString: "")
    private let setupFeedback = NSTextField(wrappingLabelWithString: "")
    private let recoveryButton = NSButton()
    private var setupBusy = false

    private func populateGeneral(_ stack: NSStackView) {
        let inspected = setupCoordinator.inspect()
        let heading = NSTextField(labelWithString: NSLocalizedString("Set Up Extensions & Login", comment: ""))
        heading.font = .boldSystemFont(ofSize: 14)
        stack.addArrangedSubview(heading)
        for browser in setupCoordinator.availableBrowsers() {
            let checkbox = NSButton(checkboxWithTitle: browser.displayName, target: self, action: #selector(browserSelectionChanged))
            checkbox.state = inspected.selectedBrowsers.contains(browser) ? .on : .off
            browserCheckboxes[browser] = checkbox
            stack.addArrangedSubview(checkbox)
        }
        let start = NSButton(title: NSLocalizedString("Register and open extension pages", comment: ""), target: self, action: #selector(showSetup))
        setupStartButton = start
        stack.addArrangedSubview(start)
        updateSetupButton()
        stack.addArrangedSubview(setupFeedback)
        stack.addArrangedSubview(NSButton(title: NSLocalizedString("Show App for Full Disk Access", comment: ""), target: self, action: #selector(revealApp)))
        stack.addArrangedSubview(NSButton(title: NSLocalizedString("Open Full Disk Access Settings…", comment: ""), target: self, action: #selector(openAccessSettings)))
        stack.addArrangedSubview(NSButton(title: NSLocalizedString("Open Login Item Settings…", comment: ""), target: self, action: #selector(openLoginSettings)))
        restartButton.title = NSLocalizedString("Restart History Service", comment: "")
        restartButton.target = self
        restartButton.action = #selector(restartAgent)
        stack.addArrangedSubview(restartButton)
    }

    @objc private func openLoginSettings() { SMAppService.openSystemSettingsLoginItems() }

    @objc private func showSetup() {
        let selected = Set(browserCheckboxes.compactMap { browser, checkbox in
            checkbox.state == .on ? browser : nil
        })
        guard !setupBusy, !selected.isEmpty else { return }
        setupBusy = true
        updateSetupButton()
        Task {
            await runSetup(selectedBrowsers: selected)
            setupBusy = false
            updateSetupButton()
        }
    }

    @objc private func browserSelectionChanged() { updateSetupButton() }

    private func updateSetupButton() {
        setupStartButton?.isEnabled = !setupBusy && browserCheckboxes.values.contains { $0.state == .on }
        restartButton.isEnabled = !agentRestarting && !setupBusy
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
            setupFeedback.stringValue = NSLocalizedString("On the browser's extensions page, enable Developer mode, choose Load unpacked, and select the ChromiumExtension folder shown in Finder.", comment: "")
            _ = await waitForHealth()
            await refreshStatusAsync()
        } catch { setupFeedback.stringValue = error.localizedDescription }
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

    private func refreshStatusAsync() async {
        if let statusTask { await statusTask.value; return }
        let task = Task {
            let data = try? await requestAsync(MenuCommand(operation: "menuStatus"))
            statusSnapshot = data.flatMap { try? JSONDecoder().decode(MenuStatusSnapshot.self, from: $0) }
            statusLoading = statusSnapshot?.sync?.runtimeState == "initializing"
            renderStatus()
            if settingsWindow?.isVisible == true {
                if loadedRevision == nil { await loadCollectionForm() }
                await refreshPairLabel()
            }
        }
        statusTask = task
        await task.value
        statusTask = nil
    }

    private func requestHealth() async throws -> HealthSnapshot {
        let response = try await requestAsync(MenuCommand(operation: "status"))
        return try JSONDecoder().decode(HealthSnapshot.self, from: response)
    }

    @objc private func restartAgent() {
        guard !agentRestarting, !setupBusy else { return }
        agentRestarting = true
        renderStatus()
        Task {
            defer { agentRestarting = false; renderStatus() }
            do {
                try await launchAgent(forceRestart: true)
                _ = await waitForHealth()
            } catch { NSAlert(error: error).runModal() }
            await refreshStatusAsync()
        }
    }

    private let assistControl = NSButton(checkboxWithTitle: NSLocalizedString("Enable automatic sync assist in a dedicated tab", comment: ""), target: nil, action: nil)
    private var assistProfile: String?

    @objc private func configureSafariAssist() {
        guard let profile = assistProfile, !assistBusy else { return }
        assistBusy = true
        let result = assistControl.state == .on ? "enable" : "disable"
        assistControl.isEnabled = false
        Task {
            defer { assistBusy = false }
            do {
                try await checkCommand(MenuCommand(operation: "cloudSafariAssist", profileID: profile, result: result))
                syncFeedback.stringValue = ""
                await refreshStatusAsync()
            } catch { syncFeedback.stringValue = error.localizedDescription }
            assistBusy = false
            await refreshPairLabel()
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        if settingsWindow?.isVisible == true {
            requestViewerReadiness()
            Task { await refreshStatusAsync() }
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
            showMessage(title: NSLocalizedString("Sync Service Unavailable", comment: ""), detail: NSLocalizedString("Check the connection in the History Sync menu.", comment: ""))
            }
        }
    }

    private func requestAsync(_ command: MenuCommand) async throws -> Data {
        if let requestOverride { return try await requestOverride(command) }
        return try await Task.detached(priority: .userInitiated) { try Self.requestSync(command) }.value
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
            alert.informativeText = String(format: NSLocalizedString("Check Full Disk Access for %@ in System Settings, then restart the history service in Settings → General.", comment: ""), String(describing: ProductIdentity.productName))
            alert.addButton(withTitle: NSLocalizedString("Open Access Settings", comment: ""))
            alert.addButton(withTitle: NSLocalizedString("Later", comment: ""))
            if alert.runModal() == .alertFirstButtonReturn { openAccessSettings() }
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
            alert.informativeText = NSLocalizedString("Check the Keychain lock and access permissions, then restart the history service in Settings → General.", comment: "")
            alert.runModal()
        case AgentIssueCode.collectionUnavailable:
            presentSettings(tab: "General")
            return
        default:
            alert.informativeText = NSLocalizedString("Check the extension setup in Settings → General.", comment: "")
            alert.runModal()
        }
    }

    @objc private func openAccessSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
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
        case AgentIssueCode.collectionUnavailable: NSLocalizedString("Collection: Unavailable", comment: "")
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
        guard !connectBusy else { return }
        connectBusy = true
        updateSyncSettings()
        Task {
            defer { connectBusy = false; updateSyncSettings() }
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

    private let popup = NSPopUpButton()
    private let enabled = NSButton(checkboxWithTitle: NSLocalizedString("Collect history", comment: ""), target: nil, action: nil)
    private let syncSwitch = NSSwitch()
    private let feedback = NSTextField(wrappingLabelWithString: "")
    private let syncFeedback = NSTextField(wrappingLabelWithString: "")
    private var loadedRevision: String?

    private func loadCollectionForm() async {
        guard !collectionFormLoading else { return }
        collectionFormLoading = true
        defer { collectionFormLoading = false }
        do {
            let reply = try JSONDecoder().decode(CollectionReply.self, from: await requestAsync(MenuCommand(operation: "collectionStatus")))
            let discovery = try JSONDecoder().decode(CollectionCandidates.self, from: await requestAsync(MenuCommand(operation: "collectionCandidates")))
            popup.removeAllItems()
            popup.addItem(withTitle: NSLocalizedString("Select a profile", comment: ""))
            for partner in discovery.candidates where partner.browser == .chromium {
                popup.addItem(withTitle: "\(partner.browserType) · \(partner.profileName) (\(partner.id))")
                popup.lastItem?.representedObject = partner.id
                if partner.id == reply.pair?.source { popup.select(popup.lastItem) }
            }
            loadedRevision = reply.pair?.revision ?? ""
            enabled.state = reply.enabled ? .on : .off
        } catch { loadedRevision = nil; feedback.stringValue = error.localizedDescription }
    }

    @objc private func configureCollection(_ sender: NSButton) {
        guard let id = popup.selectedItem?.representedObject as? String,
              let loadedRevision else { feedback.stringValue = NSLocalizedString("Select a profile", comment: ""); return }
        let collect = enabled.state == .on
        sender.isEnabled = false
        Task {
            defer { sender.isEnabled = true }
            do {
                let reply = try JSONDecoder().decode(CollectionReply.self, from: await requestAsync(MenuCommand(operation: "collectionStatus")))
                guard (reply.pair?.revision ?? "") == loadedRevision else { await loadCollectionForm(); throw TypedError(code: "PAIR_CHANGED") }
                let removed = reply.statuses.filter { $0.id != id && $0.id != "safari:default" }.reduce(Int64(0)) { $0 + $1.count }
                if id != reply.pair?.source && (removed > 0 || reply.pair != nil || (reply.pendingCount ?? 0) > 0) {
                    let count = reply.pendingCount ?? 0
                    let confirm = NSAlert()
                    confirm.messageText = NSLocalizedString("Change collection profile?", comment: "")
                    confirm.informativeText = String(format: NSLocalizedString("Remove %@ collected visits and cancel %@ pending deliveries. Browser history is preserved.", comment: ""), String(removed), String(count))
                    confirm.addButton(withTitle: NSLocalizedString("Change Profile", comment: ""))
                    confirm.addButton(withTitle: NSLocalizedString("Cancel", comment: ""))
                    guard let window = settingsWindow, await confirm.beginSheetModal(for: window) == .alertFirstButtonReturn else { return }
                }
                try await checkCommand(MenuCommand(operation: "savePair", profileID: id, result: collect ? "enable" : "disable", snapshotJSON: reply.pair?.revision ?? "", expectedRemoved: removed, expectedPending: reply.pendingCount))
                try registerLoginItemIfNeeded()
                await loadCollectionForm()
                await refreshStatusAsync()
                feedback.stringValue = NSLocalizedString("Saved", comment: "")
            } catch { feedback.stringValue = error.localizedDescription }
        }
    }

    private func checkCommand(_ command: MenuCommand) async throws {
        let data = try await requestAsync(command)
        if let error = try? JSONDecoder().decode(TypedError.self, from: data), error.type == "error" { throw error }
    }

    @objc private func collectNow() {
        guard collectButton.isEnabled, !collectBusy else { return }
        collectBusy = true
        renderStatus()
        Task {
            defer { collectBusy = false; renderStatus() }
            do { try await checkCommand(MenuCommand(operation: "collectNow")) }
            catch { NSAlert(error: error).runModal() }
            await refreshStatusAsync()
        }
    }

    @objc private func toggleSync() {
        guard !syncBusy else { return }
        syncBusy = true
        let requested = syncSwitch.state == .on
        syncSwitch.isEnabled = false
        Task {
            defer { syncBusy = false; updateSyncSettings() }
            do {
                try await checkCommand(MenuCommand(operation: "setSyncEnabled", result: requested ? "enable" : "disable"))
                syncFeedback.stringValue = ""
                await refreshStatusAsync()
            } catch { syncFeedback.stringValue = error.localizedDescription }
            await refreshPairLabel()
        }
    }

    private let pairLabel = NSTextField(wrappingLabelWithString: "")

    static func displaySyncPreference(_ health: HealthSnapshot?, canEnable: Bool, on control: NSSwitch) -> String? {
        let requested = health?.syncRequested
        control.isHidden = requested == nil
        control.isEnabled = requested == true || (requested == false && canEnable)
        guard let requested else {
            return NSLocalizedString("Saved browser sync setting is unavailable.", comment: "")
        }
        control.state = requested ? .on : .off
        if requested, health?.enabled == false {
            return NSLocalizedString("Browser sync is on. Delivery is paused.", comment: "")
        }
        return nil
    }

    private func updateSyncSettings() {
        let health = statusSnapshot?.sync
        let collection = statusSnapshot?.collection
        let canEnable = collection?.enabled == true && collection?.pair?.extensionID != nil && health?.runtimeState == "ready"
        let notice = Self.displaySyncPreference(health, canEnable: canEnable, on: syncSwitch)
        if syncBusy { syncSwitch.isEnabled = false }
        if let pair = collection?.pair, let source = collection?.sources.first(where: { $0.id == pair.source }) {
            let state = NSLocalizedString(statusSnapshot?.extensionUpdateRequired == true ? "Reload the bundled extension in the selected profile." : (pair.extensionID == nil ? "Extension not connected" : "Extension connected"), comment: "")
            pairLabel.stringValue = "Safari ↔ " + source.browserType + " · " + source.profileName + "\n" + state
        } else {
            pairLabel.stringValue = NSLocalizedString("Select a profile in History Collection.", comment: "")
        }
        if collection?.enabled == false { pairLabel.stringValue += "\n" + NSLocalizedString("Turn on history collection to enable sync.", comment: "") }
        if let notice { pairLabel.stringValue += "\n" + notice }
        connectButton.isEnabled = collection?.pair != nil && !connectBusy
        compatibilityInfo.stringValue = compatibilityDescription()
        let issue = health?.issueCode
        let commonIssue = health == nil || [AgentIssueCode.safariAccessUnavailable, AgentIssueCode.keychainUnavailable,
                                            AgentIssueCode.collectionUnavailable, "agentVersionMismatch", "legacyWriterDetected"].contains(issue ?? "")
        syncIssueLabel.stringValue = issue.map { message(for: $0) } ?? ""
        syncIssueLabel.isHidden = issue == nil
        syncGeneralButton.isHidden = !commonIssue
        recoveryButton.isHidden = issue == nil || commonIssue
    }

    private func refreshPairLabel() async {
        updateSyncSettings()
        guard !assistBusy else { return }
        guard let health = statusSnapshot?.sync, health.enabled, health.runtimeState == "ready", let profile = health.activeProfileID else {
            assistControl.isEnabled = false
            assistControl.state = .off
            assistProfile = nil
            return
        }
        do {
            let data = try await requestAsync(MenuCommand(operation: "cloudStatus", profileID: profile))
            let diagnostics = try JSONDecoder().decode(CloudDiagnostics.self, from: data)
            guard !assistBusy, statusSnapshot?.sync?.activeProfileID == profile,
                  statusSnapshot?.sync?.enabled == true else { return }
            assistProfile = profile
            assistControl.state = diagnostics.safariAssist?.enabled == true ? .on : .off
            assistControl.isEnabled = true
        } catch { assistControl.isEnabled = false; assistProfile = nil }
    }

    @objc private func showSettings() { presentSettings(tab: nil) }
    @objc private func openGeneralSettings() { presentSettings(tab: "General") }
    @objc private func openCollectionSettings() { presentSettings(tab: "History Collection") }
    @objc private func openSyncSettings() { presentSettings(tab: "Browser Sync") }
    @objc private func openViewerSettings() { presentSettings(tab: "Web Viewer") }

    private func presentSettings(tab: String?) {
        if settingsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 580),
                                  styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.title = NSLocalizedString("Settings…", comment: "")
            window.contentMinSize = NSSize(width: 560, height: 460)
            window.isReleasedWhenClosed = false
            window.delegate = self
            let tabs = NSTabView()
            tabs.translatesAutoresizingMaskIntoConstraints = false
            let content = window.contentView!
            content.addSubview(tabs)
            NSLayoutConstraint.activate([
                tabs.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
                tabs.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
                tabs.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
                tabs.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12)
            ])
            settingsTabs = tabs
            var panes: [NSStackView] = []
            func pane(_ title: String) -> NSStackView {
                let page = NSTabViewItem(identifier: title)
                page.label = NSLocalizedString(title, comment: "")
                let scroll = NSScrollView()
                scroll.hasVerticalScroller = true
                scroll.autohidesScrollers = true
                scroll.drawsBackground = false
                let document = SettingsDocumentView()
                document.translatesAutoresizingMaskIntoConstraints = false
                let stack = NSStackView()
                stack.orientation = .vertical
                stack.alignment = .leading
                stack.spacing = 8
                stack.translatesAutoresizingMaskIntoConstraints = false
                document.addSubview(stack)
                scroll.documentView = document
                NSLayoutConstraint.activate([
                    document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
                    stack.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 16),
                    stack.topAnchor.constraint(equalTo: document.topAnchor, constant: 14),
                    stack.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -16),
                    stack.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -14)
                ])
                page.view = scroll
                tabs.addTabViewItem(page)
                panes.append(stack)
                return stack
            }
            func button(_ control: NSButton, title: String, action: Selector, in stack: NSStackView) {
                control.title = NSLocalizedString(title, comment: "")
                control.bezelStyle = .rounded
                control.target = self
                control.action = action
                stack.addArrangedSubview(control)
            }
            func heading(_ title: String, in stack: NSStackView) {
                let label = NSTextField(labelWithString: NSLocalizedString(title, comment: ""))
                label.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
                stack.addArrangedSubview(label)
            }
            populateGeneral(pane("General"))
            let collection = pane("History Collection")
            collection.addArrangedSubview(collectionStatusLabel)
            button(collectionGeneralButton, title: "Open General Settings…", action: #selector(openGeneralSettings), in: collection)
            button(collectButton, title: "Collect History Now", action: #selector(collectNow), in: collection)
            heading("Collection Settings", in: collection)
            collection.addArrangedSubview(NSTextField(wrappingLabelWithString: NSLocalizedString("Select the profile to collect and sync with Safari.", comment: "")))
            popup.identifier = NSUserInterfaceItemIdentifier("collectionProfile")
            enabled.identifier = NSUserInterfaceItemIdentifier("collectionEnabled")
            collection.addArrangedSubview(popup)
            collection.addArrangedSubview(enabled)
            collection.addArrangedSubview(NSButton(title: NSLocalizedString("Save", comment: ""), target: self, action: #selector(configureCollection(_:))))
            collection.addArrangedSubview(feedback)

            let sync = pane("Browser Sync")
            sync.addArrangedSubview(syncStatusLabel)
            sync.addArrangedSubview(pairLabel)
            let title = NSLocalizedString("Browser Sync", comment: "")
            syncSwitch.target = self
            syncSwitch.action = #selector(toggleSync)
            syncSwitch.setAccessibilityLabel(title)
            sync.addArrangedSubview(NSStackView(views: [NSTextField(labelWithString: title), syncSwitch]))
            button(connectButton, title: "Connect Selected Profile", action: #selector(connectPair), in: sync)
            sync.addArrangedSubview(syncIssueLabel)
            button(syncGeneralButton, title: "Open General Settings…", action: #selector(openGeneralSettings), in: sync)
            button(recoveryButton, title: "Resolve Sync Issue…", action: #selector(resolveBlockedIssue), in: sync)
            sync.addArrangedSubview(syncFeedback)
            heading("Compatibility on This Mac", in: sync)
            sync.addArrangedSubview(compatibilityInfo)
            assistControl.target = self
            assistControl.action = #selector(configureSafariAssist)
            sync.addArrangedSubview(assistControl)
            sync.addArrangedSubview(NSTextField(wrappingLabelWithString: NSLocalizedString("Sync assist opens example.com in Safari and adds a visit that can sync to other devices.", comment: "")))
            sync.addArrangedSubview(NSButton(title: NSLocalizedString("Open Detailed Diagnostics…", comment: ""), target: self, action: #selector(showCloudDiagnostics)))

            let web = pane("Web Viewer")
            web.addArrangedSubview(viewerStatusLabel)
            button(viewerRetryButton, title: "Retry Web Viewer", action: #selector(retryViewer), in: web)
            heading("Viewer Settings", in: web)
            let defaults = UserDefaults.standard
            viewerEnabled.state = defaults.bool(forKey: "viewerEnabled") ? .on : .off
            web.addArrangedSubview(viewerEnabled)
            for (label, field, key) in [("Tailscale login", viewerOwner, "viewerOwner"), ("Viewer URL", viewerOrigin, "viewerOrigin")] {
                web.addArrangedSubview(NSTextField(labelWithString: NSLocalizedString(label, comment: "")))
                field.setAccessibilityLabel(NSLocalizedString(label, comment: ""))
                field.identifier = NSUserInterfaceItemIdentifier(key)
                field.stringValue = defaults.string(forKey: key) ?? ""
                web.addArrangedSubview(field)
            }
            web.addArrangedSubview(NSButton(title: NSLocalizedString("Save", comment: ""), target: self, action: #selector(saveViewer(_:))))
            web.addArrangedSubview(viewerFeedback)
            for stack in panes {
                for view in stack.arrangedSubviews where view is NSTextField || view is NSPopUpButton {
                    view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
                }
            }
            window.center()
            settingsWindow = window
        }
        if let tab { settingsTabs?.selectTabViewItem(withIdentifier: tab) }
        renderStatus()
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        if settingsStatusTask == nil {
            settingsStatusTask = Task { [weak self] in
                while !Task.isCancelled {
                    guard let self, self.settingsWindow?.isVisible == true else { return }
                    self.requestViewerReadiness()
                    await self.refreshStatusAsync()
                    do { try await Task.sleep(for: .seconds(10)) } catch { return }
                }
            }
        }
    }

    func windowWillClose(_ notification: Notification) {
        settingsStatusTask?.cancel()
        settingsStatusTask = nil
    }

    private final class SettingsDocumentView: NSView {
        override var isFlipped: Bool { true }
    }

    @objc private func saveViewer(_ sender: NSButton) {
        guard !viewerChanging else { return }
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
        viewerChanging = true
        Task {
            defer { sender.isEnabled = true; viewerChanging = false; renderStatus() }
            do {
                if shouldEnable {
                    try await checkCommand(MenuCommand(operation: "setViewerOrigin", snapshotJSON: address))
                    defaults.set(login, forKey: "viewerOwner"); defaults.set(address, forKey: "viewerOrigin")
                }
                defaults.set(shouldEnable, forKey: "viewerEnabled")
                await restartConfiguredViewer()
                try registerLoginItemIfNeeded()
                viewerFeedback.stringValue = NSLocalizedString("Saved", comment: "")
            } catch { viewerFeedback.stringValue = error.localizedDescription }
        }
    }

    @objc private func revealApp() { NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL]) }

    @objc private func openWeb() {
        guard UserDefaults.standard.bool(forKey: "viewerEnabled"),
              let address = UserDefaults.standard.string(forKey: "viewerOrigin"), let url = URL(string: address) else {
            showMessage(title: NSLocalizedString("Web Viewer Is Off", comment: ""), detail: NSLocalizedString("Configure and enable the Web viewer first.", comment: "")); return
        }
        NSWorkspace.shared.open(url)
    }

    @objc private func retryViewer() {
        guard !viewerChanging else { return }
        viewerChanging = true
        renderStatus()
        Task {
            defer { viewerChanging = false; renderStatus() }
            await restartConfiguredViewer()
        }
    }

    private func restartConfiguredViewer() async {
        let shouldEnable = UserDefaults.standard.bool(forKey: "viewerEnabled")
        viewerReadiness = shouldEnable ? .starting : .off
        renderStatus()
        if let previous = stopViewer() {
            for _ in 0..<30 where previous.isRunning { try? await Task.sleep(for: .milliseconds(100)) }
            if previous.isRunning { kill(previous.processIdentifier, SIGKILL) }
        }
        if shouldEnable { startConfiguredViewer() }
    }

    private func startConfiguredViewer() {
        do { try startViewer() }
        catch {
            viewerReadiness = .unavailable(lastReady: nil)
            renderStatus()
        }
    }

    private func startViewer() throws {
        let defaults = UserDefaults.standard
        guard let owner = defaults.string(forKey: "viewerOwner"), !owner.isEmpty,
              let origin = defaults.string(forKey: "viewerOrigin") else { throw TypedError(code: "VIEWER_NOT_CONFIGURED") }
        guard viewerSession == nil else { return }
        let bundle = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/Safari Chromium History Sync Viewer.app")
        let executable = bundle.appendingPathComponent("Contents/MacOS/SafariSyncViewer")
        guard FileManager.default.isExecutableFile(atPath: executable.path) else { throw TypedError(code: "VIEWER_MISSING") }
        let db = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/\(ProductIdentity.applicationSupportDirectoryName)/Viewing/history.sqlite")
        let process = Process(); process.executableURL = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/HistoryGateway")
        process.arguments = ["--viewer", executable.path, "--origin", origin, "--database", db.path, "--assets", bundle.appendingPathComponent("Contents/Resources/Web").path, "--owner", owner, "--port", "8767"]
        let input = Pipe()
        let output = Pipe()
        let id = UUID()
        let writer = input.fileHandleForWriting
        guard fcntl(writer.fileDescriptor, F_SETNOSIGPIPE, 1) == 0 else { throw TypedError(code: "VIEWER_START_FAILED") }
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [weak self] _ in
            Task { @MainActor in self?.viewerExited(id) }
        }
        try process.run()
        try? input.fileHandleForReading.close()
        try? output.fileHandleForWriting.close()
        viewerSession = .init(id: id, process: process, input: writer)
        viewerReadiness = .starting
        renderStatus()
        let reader = output.fileHandleForReading
        Task.detached(priority: .utility) { [weak self] in
            defer { try? reader.close() }
            var buffer = Data()
            while let bytes = try? reader.read(upToCount: 512), !bytes.isEmpty {
                buffer.append(bytes)
                while let newline = buffer.firstIndex(of: 10) {
                    let frame = buffer.prefix(upTo: newline)
                    if let reply = try? JSONDecoder().decode(ViewerReply.self, from: frame) {
                        await self?.receiveViewerReadiness(reply, session: id)
                    }
                    buffer.removeSubrange(...newline)
                }
                if buffer.count > 512 { break }
            }
            await self?.viewerOutputEnded(id)
        }
        requestViewerReadiness()
    }

    private func requestViewerReadiness() {
        guard var session = viewerSession, session.process.isRunning, session.pendingRequest == nil else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if let lastChecked = session.lastChecked, now - lastChecked < 10 { return }
        let request = session.nextRequest
        let id = session.id
        session.pendingRequest = request
        session.nextRequest += 1
        session.lastChecked = now
        viewerSession = session
        do { try session.input.write(contentsOf: Data("\(request)\n".utf8)) }
        catch {
            receiveViewerReadiness(.init(request: request, ready: false), session: id)
            return
        }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            self?.receiveViewerReadiness(.init(request: request, ready: false), session: id)
        }
    }

    private func receiveViewerReadiness(_ reply: ViewerReply, session id: UUID) {
        guard var session = viewerSession, session.id == id, session.pendingRequest == reply.request else { return }
        session.pendingRequest = nil
        if reply.ready, session.process.isRunning {
            let time = Date()
            session.lastReady = time
            viewerReadiness = .ready(time)
        } else {
            viewerReadiness = .unavailable(lastReady: session.lastReady)
        }
        viewerSession = session
        renderStatus()
    }

    private func viewerOutputEnded(_ id: UUID) {
        guard let session = viewerSession, session.id == id else { return }
        viewerReadiness = .unavailable(lastReady: session.lastReady)
        renderStatus()
    }

    private func viewerExited(_ id: UUID) {
        guard let session = viewerSession, session.id == id else { return }
        try? session.input.close()
        viewerSession = nil
        viewerReadiness = .unavailable(lastReady: session.lastReady)
        renderStatus()
    }

    @discardableResult private func stopViewer() -> Process? {
        guard let session = viewerSession else { return nil }
        viewerSession = nil
        try? session.input.close()
        if session.process.isRunning { session.process.terminate() }
        return session.process
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

