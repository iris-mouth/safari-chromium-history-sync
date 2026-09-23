import AppKit
import SafariSyncCore
import ServiceManagement

@MainActor
final class MenuDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let agentBundleIdentifier = "com.local.safari-history-sync.agent"
    private let setupCoordinator = SetupCoordinator()
    private var statusItem: NSStatusItem?
    private var healthItem = NSMenuItem(title: "Checking status…", action: nil, keyEquivalent: "")
    private var profileItem = NSMenuItem(title: "Change Profile…", action: #selector(changeProfile), keyEquivalent: "")
    private var browserCheckboxes: [SupportedBrowser: NSButton] = [:]
    private var setupStartButton: NSButton?
    private var latestHealth: HealthSnapshot?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "Safari Chromium History Sync"
        let menu = NSMenu()
        menu.delegate = self
        menu.addItem(healthItem)
        menu.addItem(profileItem)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Setup & Diagnostics…", action: #selector(showSetup), keyEquivalent: "")
        menu.addItem(withTitle: "Refresh Status", action: #selector(refreshStatus), keyEquivalent: "r")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Menu (Sync Continues)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu
        statusItem = item
        profileItem.isHidden = true

        let setupState = setupCoordinator.inspect()
        if !setupState.legacyArtifacts.isEmpty {
            stopAgent()
            showLegacyBlock(setupState.legacyArtifacts)
        } else if setupState.selectedBrowsers.isEmpty {
            showSetup()
        } else {
            Task {
                let health = try? await requestHealth()
                let expectedBuild = expectedAgentBuild()
                let runningAtExpectedPath = NSRunningApplication
                    .runningApplications(withBundleIdentifier: agentBundleIdentifier)
                    .allSatisfy { $0.bundleURL?.standardizedFileURL == agentURL().standardizedFileURL }
                let needsRestart = health == nil
                    || health?.agentBuild != expectedBuild
                    || health?.protocolVersion != safariSyncProtocolVersion
                    || !runningAtExpectedPath
                try? await launchAgent(forceRestart: needsRestart)
                await refreshStatusAsync()
            }
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        Task { await refreshStatusAsync() }
    }

    @objc private func showSetup() {
        let inspected = setupCoordinator.inspect()
        if !inspected.legacyArtifacts.isEmpty {
            stopAgent()
            showLegacyBlock(inspected.legacyArtifacts)
            return
        }
        let browsers = setupCoordinator.availableBrowsers()
        guard !browsers.isEmpty else {
            showMessage(title: "No supported browser found", detail: "Install Google Chrome Stable or Microsoft Edge Stable, then run setup again.")
            return
        }

        let alert = NSAlert()
        alert.messageText = "Set up Safari Chromium History Sync"
        alert.informativeText = "Choose only the browsers you want to sync. No settings are created for unselected browsers."
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
                title: "Load the extension",
                detail: "Turn on Developer mode, choose Load unpacked, and select the revealed ChromiumExtension folder. The app will detect connected profiles automatically."
            )
            await finishSetup(with: await waitForHealth())
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    private func registerLoginItemIfNeeded() throws {
        let loginItem = SMAppService.mainApp
        switch loginItem.status {
        case .notRegistered:
            try loginItem.register()
            if loginItem.status == .requiresApproval { showLoginItemApproval() }
        case .requiresApproval:
            showLoginItemApproval()
        case .enabled, .notFound:
            break
        @unknown default:
            break
        }
    }

    private func showLoginItemApproval() {
        let alert = NSAlert()
        alert.messageText = "Approval is required for Open at Login."
        alert.informativeText = "Sync can run now, but it will not restart automatically after login until you approve it in System Settings."
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
        let executable = agentURL.appendingPathComponent("Contents/MacOS/SafariSyncAgent")
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw NSError(
                domain: "SafariHistorySync",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "SafariSyncAgent.app must be installed beside Safari Chromium History Sync.app."]
            )
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.addsToRecentItems = false
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
            showMessage(title: "Agent unavailable", detail: "The Agent did not respond. Run Setup & Diagnostics again.")
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
                showMessage(title: "Setup complete", detail: "Connected \(profile.browserFamily) profile \(shortID(profile.profileID)).")
            } catch {
                NSAlert(error: error).runModal()
            }
        } else if health.activeProfileID == nil, health.connectedProfiles.count > 1 {
            latestHealth = health
            changeProfile()
        } else if health.connectedProfiles.isEmpty {
            showMessage(title: "Extension not connected", detail: "Finish loading the unpacked extension, then choose Refresh Status.")
        } else {
            showMessage(title: "Setup complete", detail: "History sync is ready.")
        }
        await refreshStatusAsync()
    }

    @objc private func changeProfile() {
        guard let health = latestHealth, !health.connectedProfiles.isEmpty else {
            showMessage(title: "No connected profiles", detail: "Open a selected browser profile with the extension enabled, then refresh status.")
            return
        }
        let alert = NSAlert()
        alert.messageText = "Choose the active browser profile"
        alert.informativeText = "Pending history remains with its original profile when you switch."
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 360, height: 28))
        for profile in health.connectedProfiles {
            popup.addItem(withTitle: "\(profile.browserFamily.capitalized) · \(shortID(profile.profileID))")
        }
        if let active = health.connectedProfiles.firstIndex(where: \.active) { popup.selectItem(at: active) }
        alert.accessoryView = popup
        alert.addButton(withTitle: "Use Profile")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let profile = health.connectedProfiles[popup.indexOfSelectedItem]
        Task {
            do {
                try await selectProfile(profile.profileID)
                showMessage(title: "Profile selected", detail: "Using \(profile.browserFamily) profile \(shortID(profile.profileID)).")
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
            if health.runtimeState == "initializing" {
                healthItem.title = "Agent starting…"
            } else if health.runtimeState == "blocked" {
                healthItem.title = message(for: health.issueCode)
            } else if let active = health.activeProfileID,
                      health.connectedProfiles.contains(where: { $0.profileID == active }) {
                healthItem.title = "Active · \(shortID(active)) · recovery \(health.recoveryCount)"
            } else if health.activeProfileID != nil {
                healthItem.title = "Active profile disconnected · waiting for extension"
            } else if health.connectedProfiles.isEmpty {
                healthItem.title = "Waiting for extension"
            } else {
                healthItem.title = "Choose an active profile"
            }
        } catch {
            latestHealth = nil
            profileItem.isHidden = true
            healthItem.title = "Agent not connected"
        }
    }

    private func requestHealth() async throws -> HealthSnapshot {
        let response = try await requestAsync(MenuCommand(operation: "status"))
        return try JSONDecoder().decode(HealthSnapshot.self, from: response)
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
            .appendingPathComponent("Library/Application Support/Safari History Sync")
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
        case "safariAccessUnavailable":
            alert.informativeText = "Verify that SafariSyncAgent.app has Full Disk Access, then run Setup & Diagnostics again. If access is already enabled, reinstall a qualified app update."
            alert.addButton(withTitle: "Open Full Disk Access")
            alert.addButton(withTitle: "Later")
            if alert.runModal() == .alertFirstButtonReturn,
               let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
                NSWorkspace.shared.open(url)
            }
        case "runtimeUnsupported":
            alert.informativeText = "Sync stopped because the compatibility check failed. Install a qualified app update before resuming."
            alert.runModal()
        case "stateUnreadable":
            alert.informativeText = "The encrypted Agent state could not be opened. Existing recovery data was not deleted."
            alert.runModal()
        default:
            alert.informativeText = "Run Setup & Diagnostics again."
            alert.runModal()
        }
    }

    private func message(for issue: String?) -> String {
        switch issue {
        case "runtimeUnsupported": "Compatibility check failed · sync stopped"
        case "safariAccessUnavailable": "Safari history unavailable · check Full Disk Access"
        case "stateUnreadable": "Encrypted state unavailable · sync stopped"
        case "agentVersionMismatch": "Agent update requires restart"
        case "legacyWriterDetected": "Legacy writer detected · sync stopped"
        case "extensionNotConnected": "Extension not connected"
        default: "Agent unavailable"
        }
    }

    private func showLegacyBlock(_ paths: [String]) {
        showMessage(title: "Legacy sync writer detected", detail: "Disable the legacy writer before setup. No files were removed.\n\n" + paths.joined(separator: "\n"))
    }

    private func stopAgent() {
        for application in NSRunningApplication.runningApplications(
            withBundleIdentifier: agentBundleIdentifier
        ) {
            application.terminate()
        }
    }

    private func agentURL() -> URL {
        Bundle.main.bundleURL.deletingLastPathComponent()
            .appendingPathComponent("SafariSyncAgent.app", isDirectory: true)
    }

    private func expectedAgentBuild() -> String? {
        let info = NSDictionary(contentsOf: agentURL().appendingPathComponent("Contents/Info.plist"))
        return info?["CFBundleVersion"] as? String
    }

    private func showMessage(title: String, detail: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.runModal()
    }

    private func shortID(_ value: String) -> String { String(value.suffix(8)) }
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
