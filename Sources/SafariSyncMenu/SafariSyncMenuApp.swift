import AppKit
import SafariSyncCore
import ServiceManagement

@MainActor
final class MenuDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let agentBundleIdentifier = ProductIdentity.agentBundleIdentifier
    private let setupCoordinator = SetupCoordinator()
    private var statusItem: NSStatusItem?
    private var healthItem = NSMenuItem(title: "Checking status…", action: nil, keyEquivalent: "")
    private var compatibilityItem = NSMenuItem(title: "Compatibility…", action: #selector(showCompatibility), keyEquivalent: "")
    private var profileItem = NSMenuItem(title: "Change Profile…", action: #selector(changeProfile), keyEquivalent: "")
    private var recoveryItem = NSMenuItem(title: "Resolve Sync Issue…", action: #selector(resolveBlockedIssue), keyEquivalent: "")
    private var browserCheckboxes: [SupportedBrowser: NSButton] = [:]
    private var setupStartButton: NSButton?
    private var latestHealth: HealthSnapshot?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = ProductIdentity.menuBarLabel
        let menu = NSMenu()
        menu.delegate = self
        menu.addItem(healthItem)
        menu.addItem(compatibilityItem)
        menu.addItem(profileItem)
        menu.addItem(recoveryItem)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Setup & Diagnostics…", action: #selector(showSetup), keyEquivalent: "")
        menu.addItem(withTitle: "Refresh Status", action: #selector(refreshStatus), keyEquivalent: "r")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Menu (Sync Continues)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu
        statusItem = item
        profileItem.isHidden = true
        recoveryItem.isHidden = true

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
        alert.informativeText = "Choose only the browsers you want to sync. No settings are created for unselected browsers.\n\n" + compatibilityDescription()
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
                showMessage(title: "Setup complete", detail: "Connected \(profile.displayName).")
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
            popup.addItem(withTitle: profile.displayName)
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
                showMessage(title: "Profile selected", detail: "Using \(profile.displayName).")
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
            compatibilityItem.title = health.issueCode == AgentIssueCode.runtimeUnsupported
                ? "Compatibility checks failed…"
                : (health.compatibility?.summary ?? "Compatibility not checked") + "…"
            profileItem.isHidden = health.connectedProfiles.isEmpty
            recoveryItem.isHidden = health.runtimeState != "blocked"
            if health.runtimeState == "initializing" {
                healthItem.title = "Agent starting…"
            } else if health.runtimeState == "blocked" {
                healthItem.title = message(for: health.issueCode)
            } else if let active = health.activeProfileID,
                      let profile = health.connectedProfiles.first(where: { $0.profileID == active }) {
                healthItem.title = "Active · \(profile.displayName) · recovery \(health.recoveryCount)"
            } else if health.activeProfileID != nil {
                healthItem.title = "Active profile disconnected · waiting for extension"
            } else if health.connectedProfiles.isEmpty {
                healthItem.title = "Waiting for extension"
            } else {
                healthItem.title = "Choose an active profile"
            }
        } catch {
            latestHealth = nil
            compatibilityItem.title = "Compatibility not checked…"
            profileItem.isHidden = true
            recoveryItem.isHidden = true
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
            alert.informativeText = "Verify that \(ProductIdentity.agentBundleName) has Full Disk Access, then run Setup & Diagnostics again. If access is already enabled, reinstall a qualified app update."
            alert.addButton(withTitle: "Open Full Disk Access")
            alert.addButton(withTitle: "Later")
            if alert.runModal() == .alertFirstButtonReturn,
               let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
                NSWorkspace.shared.open(url)
            }
        case AgentIssueCode.runtimeUnsupported:
            alert.informativeText = "Sync stopped because the runtime requirements, Safari database structure, or sync metadata are incompatible. Pending work is retained. An OS or Safari version change alone does not block sync. Check for an app update supporting the changed structure."
            alert.runModal()
        case AgentIssueCode.historyIdentityChanged, AgentIssueCode.historyAnchorInvalid:
            alert.informativeText = "Safari's history identity or saved arrival anchor changed. Resetting the Safari cursor starts scanning at the current Safari baseline. It preserves the active profile, pending outbox, recovery work, and delivery ledger."
            alert.addButton(withTitle: "Reset Safari Cursor")
            alert.addButton(withTitle: "Cancel")
            if alert.runModal() == .alertFirstButtonReturn {
                Task { await runRecoveryCommand(RecoveryCommandPolicy.resetSafariCursor) }
            }
        case AgentIssueCode.stateUnreadable:
            alert.informativeText = "The encrypted Agent state cannot be opened. Resetting it can lose pending sync work and the active-profile selection. It deletes only state.sealed and its unresolved-count sidecar, preserves Safari and Chromium history plus the delivery ledger, and restarts from the current Safari baseline."
            alert.addButton(withTitle: "Reset Agent State")
            alert.addButton(withTitle: "Cancel")
            if alert.runModal() == .alertFirstButtonReturn {
                Task { await runRecoveryCommand(RecoveryCommandPolicy.resetAgentState) }
            }
        case AgentIssueCode.keychainUnavailable:
            alert.informativeText = "The Agent-only Keychain item is unavailable. Unlock or repair Keychain access, then restart the Agent. Agent state reset is intentionally unavailable because it cannot fix Keychain access."
            alert.runModal()
        default:
            alert.informativeText = "Run Setup & Diagnostics again."
            alert.runModal()
        }
    }

    private func message(for issue: String?) -> String {
        switch issue {
        case AgentIssueCode.runtimeUnsupported: "Compatibility check failed · sync stopped"
        case AgentIssueCode.historyIdentityChanged: "Safari history was replaced · cursor reset required"
        case AgentIssueCode.historyAnchorInvalid: "Safari history anchor changed · cursor reset required"
        case AgentIssueCode.safariAccessUnavailable: "Safari history unavailable · check Full Disk Access"
        case AgentIssueCode.keychainUnavailable: "Keychain unavailable · sync stopped"
        case AgentIssueCode.stateUnreadable: "Encrypted state unavailable · state reset available"
        case "agentVersionMismatch": "Agent update requires restart"
        case "legacyWriterDetected": "Legacy writer detected · sync stopped"
        case "extensionNotConnected": "Extension not connected"
        default: "Agent unavailable"
        }
    }

    private func showLegacyBlock(_ paths: [String]) {
        showMessage(title: "Legacy sync writer detected", detail: "Disable the legacy writer before setup. No files were removed.\n\n" + paths.joined(separator: "\n"))
    }

    @objc private func resolveBlockedIssue() {
        showBlockedIssue(latestHealth?.issueCode)
    }

    @objc private func showCompatibility() {
        Task {
            await refreshStatusAsync()
            showMessage(title: "Compatibility", detail: compatibilityDescription())
        }
    }

    private func compatibilityDescription() -> String {
        guard let health = latestHealth else { return "Compatibility has not been checked. Connect the Agent to see its status." }
        if health.issueCode == AgentIssueCode.runtimeUnsupported {
            return "Compatibility checks failed. Sync is stopped and pending work is retained."
        }
        guard let compatibility = health.compatibility else { return "Compatibility has not been checked yet." }
        let runtime = compatibility.runtime
        let evidence = compatibility.status == .tested
            ? "This environment has an end-to-end test record for this release."
            : "Compatibility checks passed, but this release has not been end-to-end tested in this environment. Sync is permitted; iCloud arrival is not confirmed by the local checks."
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
                ? "The Safari arrival cursor now starts at the current baseline. Pending queues and the delivery ledger were preserved."
                : "Agent state now starts at the current Safari baseline. Safari and Chromium history plus the delivery ledger were preserved."
            showMessage(title: "Sync recovery complete", detail: detail)
        } catch {
            NSAlert(error: error).runModal()
            await refreshStatusAsync()
        }
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
            .appendingPathComponent(ProductIdentity.agentBundleName, isDirectory: true)
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
