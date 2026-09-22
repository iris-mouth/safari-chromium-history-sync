import AppKit
import SafariSyncCore
import ServiceManagement

@MainActor
final class MenuDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var healthItem = NSMenuItem(title: "Agent not connected", action: nil, keyEquivalent: "")

    private var socketPath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Safari History Sync/agent.sock").path
    }

    private var ipcSecretURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Safari History Sync/ipc.secret")
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "Safari Sync"
        let menu = NSMenu()
        menu.addItem(healthItem)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Enable Agent", action: #selector(enableAgent), keyEquivalent: "")
        menu.addItem(withTitle: "Select Chrome / Edge Profile…", action: #selector(selectProfile), keyEquivalent: "")
        menu.addItem(withTitle: "Refresh Status", action: #selector(refreshStatus), keyEquivalent: "r")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu
        statusItem = item
        launchAgent(showErrors: false)
        refreshStatus()
    }

    @objc private func enableAgent() {
        let service = SMAppService.mainApp
        Task { @MainActor in
            do {
                if service.status != .notRegistered {
                    try await service.unregister()
                }
                try service.register()
                launchAgent(showErrors: true)
            } catch {
                NSAlert(error: error).runModal()
            }
        }
    }

    private func launchAgent(showErrors: Bool) {
        let agentURL = Bundle.main.bundleURL
            .deletingLastPathComponent()
            .appendingPathComponent("SafariSyncAgent.app", isDirectory: true)
        let executable = agentURL.appendingPathComponent("Contents/MacOS/SafariSyncAgent")
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            if showErrors {
                let error = NSError(
                    domain: "SafariHistorySync",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "SafariSyncAgent.app must be installed beside Safari History Sync.app."]
                )
                NSAlert(error: error).runModal()
            }
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.addsToRecentItems = false
        NSWorkspace.shared.openApplication(at: agentURL, configuration: configuration) { [weak self] _, error in
            Task { @MainActor in
                if let error, showErrors {
                    NSAlert(error: error).runModal()
                }
                try? await Task.sleep(for: .milliseconds(500))
                self?.refreshStatus()
            }
        }
    }

    @objc private func selectProfile() {
        let alert = NSAlert()
        alert.messageText = "Select active browser profile"
        alert.informativeText = "Paste the profile ID shown in the extension popup. The current profile is frozen before the new one becomes active."
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
        alert.accessoryView = input
        alert.addButton(withTitle: "Select")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn, !input.stringValue.isEmpty else { return }
        do {
            let response = try request(MenuCommand(operation: "selectProfile", profileID: input.stringValue))
            let status = try JSONDecoder().decode(ProfileSwitchStatus.self, from: response)
            healthItem.title = "Profile switch: \(status.state)"
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    @objc private func refreshStatus() {
        do {
            let response = try request(MenuCommand(operation: "status"))
            let health = try JSONDecoder().decode(HealthSnapshot.self, from: response)
            if health.switchState == "KEY_UNAVAILABLE" {
                healthItem.title = "Key unavailable · unrecoverable \(health.unrecoverableCount)"
            } else {
                healthItem.title = health.activeProfileID.map {
                    "\($0) · \(health.switchState) · recovery \(health.recoveryCount)"
                } ?? "No active browser profile"
            }
        } catch {
            healthItem.title = "Agent not connected"
        }
    }

    private func request(_ command: MenuCommand) throws -> Data {
        let secret = try IPCSecretStore.load(from: ipcSecretURL, createIfMissing: false)
        let body = try JSONEncoder().encode(command)
        let authenticated = SharedSecret.authenticate(body: body, role: "menu", secret: secret)
        return try LocalIPCClient(socketPath: socketPath).request(JSONEncoder().encode(authenticated))
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
