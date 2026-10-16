import AppKit
import SafariSyncCore
import ServiceManagement

@MainActor
final class MenuDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let agentBundleIdentifier = ProductIdentity.agentBundleIdentifier
    private let setupCoordinator = SetupCoordinator()
    private var statusItem: NSStatusItem?
    private var healthItem = NSMenuItem(title: "同期状況を確認中…", action: nil, keyEquivalent: "")
    private var compatibilityItem = NSMenuItem(title: "このMacの対応状況を見る…", action: #selector(showCompatibility), keyEquivalent: "")
    private var profileItem = NSMenuItem(title: "同期するブラウザを選ぶ…", action: #selector(changeProfile), keyEquivalent: "")
    private var recoveryItem = NSMenuItem(title: "停止中の同期を復旧…", action: #selector(resolveBlockedIssue), keyEquivalent: "")
    private var browserCheckboxes: [SupportedBrowser: NSButton] = [:]
    private var setupStartButton: NSButton?
    private var latestHealth: HealthSnapshot?
    private var cloudWindow: CloudDiagnosticsWindow?
    private var statusWindow: SyncStatusWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = ProductIdentity.menuBarLabel
        item.menu = makeMenu()
        statusItem = item

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

    func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self
        menu.addItem(healthItem)
        menu.addItem(.separator())
        menu.addItem(withTitle: "同期状況を見る…", action: #selector(showSyncStatus), keyEquivalent: "")
        menu.addItem(profileItem)
        menu.addItem(withTitle: "Safariの自動同期補助を設定…", action: #selector(configureSafariAssist), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "拡張機能と自動起動を設定…", action: #selector(showSetup), keyEquivalent: "")
        let troubleshooting = NSMenu()
        troubleshooting.addItem(compatibilityItem)
        troubleshooting.addItem(recoveryItem)
        troubleshooting.addItem(withTitle: "詳細な診断を開く…", action: #selector(showCloudDiagnostics), keyEquivalent: "")
        let troubleshootingItem = NSMenuItem(title: "問題を調べる", action: nil, keyEquivalent: "")
        troubleshootingItem.submenu = troubleshooting
        menu.addItem(troubleshootingItem)
        menu.addItem(withTitle: "状態表示を更新", action: #selector(refreshStatus), keyEquivalent: "r")
        menu.addItem(.separator())
        let quit = menu.addItem(withTitle: "メニューを終了（同期は継続）", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        for item in menu.items + troubleshooting.items where item.action != nil { item.target = self }
        quit.target = NSApp
        menu.items.first(where: { $0.action == #selector(showSyncStatus) })?.toolTip = "同期状況を表示します。履歴の追加や設定変更は行いません。"
        profileItem.toolTip = "候補を表示します。選択を確定すると、そのブラウザの履歴をSafariと同期します。"
        recoveryItem.toolTip = "停止原因と復旧方法を表示します。実行前に変更内容を確認できます。"
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
            stopAgent()
            showLegacyBlock(inspected.legacyArtifacts)
            return
        }
        let browsers = setupCoordinator.availableBrowsers()
        guard !browsers.isEmpty else {
            showMessage(title: "対応ブラウザが見つかりません", detail: "Google ChromeまたはMicrosoft Edgeの安定版をインストールしてから設定してください。")
            return
        }

        let alert = NSAlert()
        alert.messageText = "拡張機能と自動起動の設定"
        alert.informativeText = "同期に使うブラウザを選んでください。「設定を開始」を押すと、選択したブラウザの接続設定とログイン時の自動起動を登録し、同期サービスを再起動します。拡張機能の読み込み画面も開きます。\n\n" + compatibilityDescription()
        alert.addButton(withTitle: "設定を開始")
        alert.addButton(withTitle: "キャンセル")
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
                title: "ブラウザの拡張機能を読み込んでください",
                detail: "ブラウザの拡張機能画面で「開発者モード」を有効にし、「パッケージ化されていない拡張機能を読み込む」から、表示したChromiumExtensionフォルダを選んでください。"
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
        alert.messageText = "ログイン時の自動起動に許可が必要です"
        alert.informativeText = "システム設定で許可すると、次回のログイン時にも同期を自動で開始できます。"
        alert.addButton(withTitle: "システム設定を開く")
        alert.addButton(withTitle: "あとで")
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
            showMessage(title: "同期サービスに接続できません", detail: "「拡張機能と自動起動を設定…」から設定を確認してください。")
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
                showMessage(title: "設定が完了しました", detail: "\(profile.displayName)と接続しました。")
            } catch {
                NSAlert(error: error).runModal()
            }
        } else if health.activeProfileID == nil, health.connectedProfiles.count > 1 {
            latestHealth = health
            changeProfile()
        } else if health.connectedProfiles.isEmpty {
            showMessage(title: "拡張機能の接続待ちです", detail: "拡張機能を読み込んでから、メニューの「状態表示を更新」を選んでください。")
        } else {
            showMessage(title: "設定が完了しました", detail: "履歴を同期する準備ができました。")
        }
        await refreshStatusAsync()
    }

    @objc private func changeProfile() {
        guard let health = latestHealth, !health.connectedProfiles.isEmpty else {
            showMessage(title: "接続中のブラウザがありません", detail: "拡張機能を有効にしたブラウザを開き、メニューの「状態表示を更新」を選んでください。")
            return
        }
        let alert = NSAlert()
        alert.messageText = "Safariと履歴を同期するブラウザを選ぶ"
        alert.informativeText = "「このブラウザと同期」を押すと、選択したプロファイルとの双方向同期に切り替わります。切り替え前の配送待ち履歴は元のプロファイルに残り、別のプロファイルには送られません。"
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 360, height: 28))
        for profile in health.connectedProfiles {
            popup.addItem(withTitle: profile.displayName)
        }
        if let active = health.connectedProfiles.firstIndex(where: \.active) { popup.selectItem(at: active) }
        alert.accessoryView = popup
        alert.addButton(withTitle: "このブラウザと同期")
        alert.addButton(withTitle: "キャンセル")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let profile = health.connectedProfiles[popup.indexOfSelectedItem]
        Task {
            do {
                try await selectProfile(profile.profileID)
                showMessage(title: "同期するブラウザを変更しました", detail: "\(profile.displayName)と同期します。")
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
                healthItem.title = "同期サービスを起動中…"
            } else if health.runtimeState == "blocked" {
                healthItem.title = message(for: health.issueCode)
            } else if let active = health.activeProfileID,
                      let profile = health.connectedProfiles.first(where: { $0.profileID == active }) {
                healthItem.title = "同期中 · \(profile.displayName)"
            } else if health.activeProfileID != nil {
                healthItem.title = "ブラウザ拡張機能の接続待ち"
            } else if health.connectedProfiles.isEmpty {
                healthItem.title = "ブラウザ拡張機能の接続待ち"
            } else {
                healthItem.title = "同期するブラウザを選んでください"
            }
        } catch {
            latestHealth = nil
            profileItem.isHidden = true
            recoveryItem.isHidden = true
            healthItem.title = "同期サービスに接続できません"
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
                    showMessage(title: "同期補助を設定できません", detail: "同期サービスの接続と、同期するブラウザの選択を確認してください。")
                    return
                }
                let data = try await requestAsync(MenuCommand(operation: "cloudStatus", profileID: profile))
                let diagnostics = try JSONDecoder().decode(CloudDiagnostics.self, from: data)
                let enabled = diagnostics.safariAssist?.enabled == true
                let alert = NSAlert()
                alert.messageText = "Safariの自動同期補助"
                alert.informativeText = "Safariへの追加済み履歴が同期待ちのとき、専用タブでexample.comを読み込み、Safari標準の同期処理を促します。通常の閲覧履歴が追加され、他の端末にも同期される場合があります。初回はSafariの操作許可が必要です。\n\n90秒待ってから処理を試し、進まない間は間隔を5分から最大1時間まで延ばして再試行します。別のタブは変更しません。"
                let checkbox = NSButton(checkboxWithTitle: "専用タブを使った自動同期補助を有効にする", target: nil, action: nil)
                checkbox.state = enabled ? .on : .off
                checkbox.frame = NSRect(x: 0, y: 0, width: 360, height: 24)
                alert.accessoryView = checkbox
                alert.addButton(withTitle: "設定を保存")
                alert.addButton(withTitle: "キャンセル")
                guard alert.runModal() == .alertFirstButtonReturn, (checkbox.state == .on) != enabled else { return }
                let response = try await requestAsync(MenuCommand(operation: "cloudSafariAssist", profileID: profile,
                    result: checkbox.state == .on ? "enable" : "disable"))
                if let failure = try? JSONDecoder().decode(TypedError.self, from: response), failure.type == "error" { throw failure }
                _ = try JSONDecoder().decode(CloudDiagnostics.self, from: response)
                statusWindow?.refresh()
            } catch {
                showMessage(title: "設定を保存できませんでした", detail: "同期サービスの接続を確認し、もう一度お試しください。")
            }
        }
    }

    @objc private func showCloudDiagnostics() {
        Task { [self] in
            do {
                let health = try await requestHealth()
                guard health.runtimeState == "ready", let profile = health.activeProfileID else {
                    showMessage(title: "詳細な診断を開けません", detail: "停止中の同期を復旧し、同期するブラウザを選択してください。")
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
                showMessage(title: "同期サービスに接続できません", detail: "メニューの「状態表示を更新」や「拡張機能と自動起動を設定…」で接続を確認してください。")
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
            alert.informativeText = "システム設定で\(ProductIdentity.agentBundleName)の「フルディスクアクセス」を確認してください。その後、「拡張機能と自動起動を設定…」から同期サービスを再起動できます。"
            alert.addButton(withTitle: "アクセス許可の設定を開く")
            alert.addButton(withTitle: "あとで")
            if alert.runModal() == .alertFirstButtonReturn,
               let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
                NSWorkspace.shared.open(url)
            }
        case AgentIssueCode.runtimeUnsupported:
            alert.informativeText = "macOSの動作条件、Safari履歴DBの構造、または同期状態が対応条件を満たしていません。配送待ちの履歴は保持しています。対応したアプリの更新を確認してください。"
            alert.runModal()
        case AgentIssueCode.historyIdentityChanged, AgentIssueCode.historyAnchorInvalid:
            alert.informativeText = "Safari履歴の置換または変更を検出しました。読み取り開始位置を現在の履歴末尾に設定し直すと、以後の新しい履歴から同期を再開します。過去の履歴は取り込み直しません。選択中のブラウザ、配送待ちの履歴、再試行待ちの記録は保持します。"
            alert.addButton(withTitle: "現在の履歴末尾から再開")
            alert.addButton(withTitle: "キャンセル")
            if alert.runModal() == .alertFirstButtonReturn {
                Task { await runRecoveryCommand(RecoveryCommandPolicy.resetSafariCursor) }
            }
        case AgentIssueCode.stateUnreadable:
            alert.informativeText = "保存した同期状態を読み込めません。初期化すると、配送待ちの履歴やブラウザの選択設定を失う場合があります。SafariとChrome/Edgeの閲覧履歴は保持し、現在の履歴末尾から同期をやり直します。"
            alert.addButton(withTitle: "同期状態を初期化して再開")
            alert.addButton(withTitle: "キャンセル")
            if alert.runModal() == .alertFirstButtonReturn {
                Task { await runRecoveryCommand(RecoveryCommandPolicy.resetAgentState) }
            }
        case AgentIssueCode.keychainUnavailable:
            alert.informativeText = "キーチェーンのロックやアクセス許可を確認してから、「拡張機能と自動起動を設定…」で同期サービスを再起動してください。"
            alert.runModal()
        default:
            alert.informativeText = "「拡張機能と自動起動を設定…」から接続設定を確認してください。"
            alert.runModal()
        }
    }

    private func message(for issue: String?) -> String {
        switch issue {
        case AgentIssueCode.runtimeUnsupported: "この環境の対応確認に失敗したため同期を停止中"
        case AgentIssueCode.historyIdentityChanged: "Safariの履歴DBが置換されたため同期を停止中"
        case AgentIssueCode.historyAnchorInvalid: "Safariの履歴が変更されたため同期を停止中"
        case AgentIssueCode.safariAccessUnavailable: "Safari履歴へのアクセス許可を確認してください"
        case AgentIssueCode.keychainUnavailable: "キーチェーンにアクセスできないため同期を停止中"
        case AgentIssueCode.stateUnreadable: "保存した同期状態を読み込めないため同期を停止中"
        case "agentVersionMismatch": "更新した同期サービスの再起動が必要です"
        case "legacyWriterDetected": "旧版の同期処理を検出したため同期を停止中"
        case "extensionNotConnected": "拡張機能の接続待ちです"
        default: "同期サービスに接続できません"
        }
    }

    private func showLegacyBlock(_ paths: [String]) {
        showMessage(title: "旧版の同期処理を検出しました", detail: "旧版の同期処理を停止してから設定してください。\n\n" + paths.joined(separator: "\n"))
    }

    @objc private func resolveBlockedIssue() {
        showBlockedIssue(latestHealth?.issueCode)
    }

    @objc private func showCompatibility() {
        Task {
            latestHealth = try? await requestHealth()
            showMessage(title: "このMacの対応状況", detail: compatibilityDescription())
        }
    }

    private func compatibilityDescription() -> String {
        guard let health = latestHealth else { return "対応状況は未確認です。同期サービスとの接続後に確認できます。" }
        if health.issueCode == AgentIssueCode.runtimeUnsupported {
            return "対応確認に失敗したため同期を停止しています。配送待ちの履歴は保持しています。"
        }
        guard let compatibility = health.compatibility else { return "対応状況はまだ確認できていません。" }
        let runtime = compatibility.runtime
        let evidence = compatibility.status == .tested
            ? "このバージョンには、この環境で端末まで同期を確認した記録があります。"
            : "動作条件の確認には合格しています。このバージョンで端末まで同期できるかは、この環境では未検証です。"
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
                ? "現在のSafari履歴末尾から同期を再開しました。配送待ちの履歴は保持しています。"
                : "同期状態を初期化し、現在のSafari履歴末尾から再開しました。SafariとChrome/Edgeの閲覧履歴は保持しています。"
            showMessage(title: "同期を再開しました", detail: detail)
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
