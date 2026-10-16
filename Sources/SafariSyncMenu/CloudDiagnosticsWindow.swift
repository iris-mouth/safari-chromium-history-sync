import AppKit
import SafariSyncCore
import UniformTypeIdentifiers

@MainActor
final class CloudDiagnosticsWindow: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    let profileID: String
    private let request: (MenuCommand) async throws -> Data
    private let summary = NSTextField(wrappingLabelWithString: "読み込み中…")
    private let table = NSTableView()
    private var records: [CloudDelivery] = []
    private let advanced = NSStackView()
    private var selectionButtons: [NSButton] = []
    private var busy = false
    private var nextCursor: String?

    init(profileID: String, request: @escaping (MenuCommand) async throws -> Data) {
        self.profileID = profileID
        self.request = request
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1080, height: 620),
            styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "履歴同期の詳細な診断"
        window.minSize = NSSize(width: 1000, height: 620)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor),
            stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor),
            stack.bottomAnchor.constraint(equalTo: window.contentView!.bottomAnchor),
        ])
        stack.addArrangedSubview(summary)
        summary.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32).isActive = true
        let instructions = NSTextField(wrappingLabelWithString:
            "この画面では、配送した履歴と同期の進行状況を確認できます。端末への到達はiPhone／iPadの履歴で確認してください。テスト履歴の追加や再送などは「検証・詳細操作を表示」にまとめています。")
        stack.addArrangedSubview(instructions)
        instructions.widthAnchor.constraint(equalTo: summary.widthAnchor).isActive = true
        for (id, title, width) in [("provider", "同期先", 80.0), ("url", "URL", 380.0),
                                    ("time", "履歴への追加日時", 130.0), ("native", "同期の進行状況", 210.0),
                                    ("remote", "端末での到達確認", 170.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.title = title
            column.width = width
            table.addTableColumn(column)
        }
        table.delegate = self
        table.dataSource = self
        table.rowHeight = 26
        table.allowsMultipleSelection = false
        table.frame = NSRect(x: 0, y: 0, width: 1048, height: 300)
        table.autoresizingMask = [.width]
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.borderType = .bezelBorder
        stack.addArrangedSubview(scroll)
        scroll.widthAnchor.constraint(equalTo: summary.widthAnchor).isActive = true
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 260).isActive = true
        let browsing = NSStackView(views: [
            button("表示を更新", #selector(refresh)),
            button("以前の記録を表示", #selector(older)),
            selectionButton("選択URLをコピー", #selector(copyURL)),
        ])
        browsing.spacing = 8
        stack.addArrangedSubview(browsing)
        let disclosure = NSButton(checkboxWithTitle: "検証・詳細操作を表示", target: self, action: #selector(toggleAdvanced(_:)))
        stack.addArrangedSubview(disclosure)
        advanced.orientation = .vertical
        advanced.spacing = 8
        stack.addArrangedSubview(advanced)
        let explanation = NSTextField(wrappingLabelWithString:
            "テストURLの追加と再送は、新しい訪問を履歴に追加します。実行前に対象と変更内容を確認できます。到達確認は、端末の履歴で選択URLを検索してから記録してください。")
        advanced.addArrangedSubview(explanation)
        explanation.widthAnchor.constraint(equalTo: summary.widthAnchor).isActive = true
        let probes = NSStackView(views: [
            button("Safariにテスト履歴を追加…", #selector(probeSafari)),
            button("Chrome/Edgeにテスト履歴を追加…", #selector(probeBrowser)),
            selectionButton("端末での到達を記録", #selector(markSeen)),
            selectionButton("未確認として記録", #selector(markNotSeen)),
        ])
        probes.spacing = 8
        advanced.addArrangedSubview(probes)
        let actions = NSStackView(views: [
            selectionButton("選択URLをもう一度履歴に追加…", #selector(reviewReplay)),
            button("端末のSafari履歴ファイルと照合…", #selector(compareExport)),
            button("アカウント変更を記録…", #selector(rebind)),
        ])
        actions.spacing = 8
        advanced.addArrangedSubview(actions)
        advanced.isHidden = true
        updateSelectionButtons()
        window.center()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func button(_ title: String, _ action: Selector) -> NSButton {
        NSButton(title: title, target: self, action: action)
    }

    private func selectionButton(_ title: String, _ action: Selector) -> NSButton {
        let button = button(title, action)
        selectionButtons.append(button)
        return button
    }

    private func updateSelectionButtons() {
        for button in selectionButtons { button.isEnabled = selected != nil && !busy }
    }

    func tableViewSelectionDidChange(_ notification: Notification) { updateSelectionButtons() }

    @objc private func toggleAdvanced(_ sender: NSButton) {
        let show = sender.state == .on
        guard advanced.isHidden == show else { return }
        advanced.isHidden = !show
        guard let window else { return }
        var frame = window.frame
        frame.origin.y -= show ? 150 : -150
        frame.size.height += show ? 150 : -150
        window.setFrame(frame, display: true)
    }

    @objc private func copyURL() {
        guard let entry = selected else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(entry.url.absoluteString, forType: .string)
    }

    private func command(_ operation: String, provider: CloudProvider? = nil, deliveryID: String? = nil,
                         planID: String? = nil, result: String? = nil, snapshot: String? = nil) -> MenuCommand {
        MenuCommand(operation: operation, profileID: profileID, provider: provider,
            deliveryID: deliveryID, planID: planID, result: result,
            device: result == nil ? nil : "iPhone/iPad (user-reported)", snapshotJSON: snapshot)
    }

    private func perform(_ command: MenuCommand) async throws -> CloudDiagnostics {
        let data = try await request(command)
        if let failure = try? JSONDecoder().decode(TypedError.self, from: data), failure.type == "error" {
            throw failure
        }
        return try JSONDecoder().decode(CloudDiagnostics.self, from: data)
    }

    private func display(_ diagnostics: CloudDiagnostics) {
        let selectedID = selected?.id
        records = diagnostics.deliveries
        nextCursor = diagnostics.nextDeliveryID
        table.reloadData()
        if let selectedID, let row = records.firstIndex(where: { $0.id == selectedID }) {
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        updateSelectionButtons()
        let health = diagnostics.summary
        summary.stringValue = "表示中：\(records.count)件／\(diagnostics.totalDeliveries)件\n履歴への追加待ち：\(health.pendingLocal) · Safari側の同期待ち：\(health.safariPending) · 進行の遅れ：\(health.possibleStalls)\nSafari側で処理済み：\(health.checkpointCovered) · Chrome/Edgeの端末到達未確認：\(health.browserNotObservable) · 端末で到達確認済み：\(health.remoteSeen) · 削除／変更済み：\(health.suppressed)"
        if let assist = diagnostics.safariAssist {
            summary.stringValue += "\nSafariの自動同期補助：\(assist.enabled ? "有効" : "無効")（変更はメニューの「Safariの自動同期補助を設定…」から）"
            if let next = assist.nextAttemptAt, health.safariPending > 0 {
                summary.stringValue += "\n次に処理を試す時刻：\(next.formatted(date: .omitted, time: .standard))"
            }
        }
        if health.capacityReached { summary.stringValue += "\n記録数の上限に達したため、新しい配送は空きができるまで待機します。" }
    }

    private var selected: CloudDelivery? {
        records.indices.contains(table.selectedRow) ? records[table.selectedRow] : nil
    }

    private func run(_ work: @escaping () async throws -> Void) {
        guard !busy else { return }
        busy = true
        updateSelectionButtons()
        Task {
            defer { busy = false; updateSelectionButtons() }
            do { try await work() }
            catch {
                let alert = NSAlert()
                alert.messageText = "操作を完了できませんでした"
                if let typed = error as? TypedError {
                    switch typed.code {
                    case "CLOUD_EXTENSION_UPGRADE_REQUIRED":
                        alert.informativeText = "アプリに同梱したChrome/Edge拡張機能を読み込み直してから、表示を更新してください。"
                    case "PROFILE_NOT_ACTIVE", "STALE_CLOUD_REPAIR_PLAN":
                        alert.informativeText = "同期先のブラウザやアカウント情報が変わりました。この画面を閉じ、詳細な診断を開き直してください。"
                    case "INVALID_SAFARI_EXPORT":
                        alert.informativeText = "到達先の端末から書き出したSafariのHistory.json（32 MiB以下）を選んでください。"
                    case "CLOUD_REPLAY_NOT_ALLOWED":
                        alert.informativeText = "履歴への追加が確認でき、削除・変更やアカウント変更の影響を受けていない記録を選んでください。"
                    default: alert.informativeText = typed.code
                    }
                } else { alert.informativeText = "同期サービスに接続できないか、選択したファイルを読み取れません。接続とファイルを確認してください。" }
                alert.runModal()
            }
        }
    }

    @objc func refresh() {
        run { self.display(try await self.perform(self.command("cloudStatus"))) }
    }

    @objc private func older() {
        guard let cursor = nextCursor else { return }
        run { self.display(try await self.perform(self.command("cloudStatus", deliveryID: cursor))) }
    }

    private func probe(_ provider: CloudProvider) {
        let route = provider == .safari ? "このMacのSafari" : "選択中のChrome/Edge"
        let confirmation = NSAlert()
        confirmation.messageText = "\(route)にテスト履歴を追加しますか？"
        confirmation.informativeText = "example.comの一意なテストURLを通常の配送経路で履歴に追加します。同期が進むと他の端末にも表示される場合があります。追加後、iPhone／iPadの履歴でURLを検索して到達を確認できます。"
        confirmation.addButton(withTitle: "テスト履歴を追加")
        confirmation.addButton(withTitle: "キャンセル")
        guard confirmation.runModal() == .alertFirstButtonReturn else { return }
        run {
            let before = Set(self.records.map(\.id))
            let diagnostics = try await self.perform(self.command("cloudProbe", provider: provider))
            self.display(diagnostics)
            if let row = self.records.firstIndex(where: { !before.contains($0.id) && $0.kind == "probe" && $0.provider == provider }) {
                self.table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                let alert = NSAlert()
                alert.messageText = "端末のブラウザ履歴でURLを検索してください"
                alert.informativeText = "\(self.records[row].url.absoluteString)\n\n同じアカウントのiPhone／iPadで、SafariまたはChrome/Edgeの履歴を検索してください。到達確認の前にこのURLを開かず、履歴への表示だけを確認します。追加の完了後に表示を更新し、選択した記録の到達状況を記録できます。"
                alert.runModal()
            }
        }
    }

    @objc private func probeSafari() { probe(.safari) }
    @objc private func probeBrowser() { probe(.browser) }
    @objc private func markSeen() { observation("seen") }
    @objc private func markNotSeen() { observation("notObserved") }

    private func observation(_ result: String) {
        guard let entry = selected else { return }
        run { self.display(try await self.perform(self.command("cloudObserve", deliveryID: entry.id, result: result))) }
    }

    @objc private func reviewReplay() {
        guard let entry = selected else { return }
        run {
            let diagnostics = try await self.perform(self.command("cloudPrepareReplay", deliveryID: entry.id))
            self.display(diagnostics)
            guard let plan = diagnostics.plan else { throw TypedError(code: "STALE_CLOUD_REPAIR_PLAN") }
            let alert = NSAlert()
            alert.messageText = "選択URLをもう一度履歴に追加しますか？"
            alert.informativeText = "\(plan.url.absoluteString)\n\n追加先：\(plan.provider == .safari ? "Safari / iCloud" : "選択中のChrome/Edge")\n\n意図したアカウントにログインし、履歴の同期が有効なことを確認してください。現在時刻の訪問を1件追加します。端末への到達は、追加後に端末で確認してください。"
            alert.addButton(withTitle: "履歴にもう一度追加")
            alert.addButton(withTitle: "キャンセル")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            self.display(try await self.perform(self.command("cloudExecuteReplay", planID: plan.id)))
        }
    }

    @objc private func compareExport() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.message = "到達先のiPhone／iPadから書き出したSafariのHistory.json（32 MiB以下）を選んでください。"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let alert = NSAlert()
        alert.messageText = "到達先の端末のファイルですか？"
        alert.informativeText = "同じApple AccountとSafariプロファイルを使うiPhone／iPadのファイルを選んでください。URLと最新の訪問日時が一致する記録を到達確認済みにします。見つからない記録は未確認のまま残します。"
        alert.addButton(withTitle: "ファイルと照合")
        alert.addButton(withTitle: "キャンセル")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        run {
            let file = try FileHandle(forReadingFrom: url)
            defer { try? file.close() }
            let data = try file.read(upToCount: 32 * 1024 * 1024 + 1) ?? Data()
            // Extract only owned URLs locally. The complete receiving-device history never crosses IPC.
            var diagnostics = try await self.perform(self.command("cloudStatus"))
            var ownedURLs = Set(diagnostics.deliveries.filter { $0.provider == .safari }.map { $0.url.absoluteString })
            var pages = 1
            while let cursor = diagnostics.nextDeliveryID, pages < 128 {
                diagnostics = try await self.perform(self.command("cloudStatus", deliveryID: cursor))
                ownedURLs.formUnion(diagnostics.deliveries.filter { $0.provider == .safari }.map { $0.url.absoluteString })
                pages += 1
            }
            let urlsToCompare = ownedURLs
            let snapshots = try await Task.detached(priority: .userInitiated) {
                try SafariReceiverExport.comparisonBatches(data: data, ownedURLs: urlsToCompare)
            }.value
            for snapshot in snapshots {
                _ = try await self.perform(self.command("cloudCompareExport", snapshot: snapshot))
            }
            self.display(try await self.perform(self.command("cloudStatus")))
        }
    }

    @objc private func rebind() {
        let picker = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 260, height: 28))
        picker.addItems(withTitles: ["Safari / Apple Account", "Chrome/Edgeのアカウント"])
        let alert = NSAlert()
        alert.messageText = "変更済みのアカウントを同期記録に反映しますか？"
        alert.informativeText = "ブラウザやiCloudのアカウントを変更した後に使います。以前のアカウント向けの未完了テスト・再送を取り消し、古い到達記録を新しいアカウントとは分けて扱います。ログインするアカウント自体の変更は、ブラウザやシステム設定で行ってください。"
        alert.accessoryView = picker
        alert.addButton(withTitle: "アカウント変更を記録")
        alert.addButton(withTitle: "キャンセル")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let provider: CloudProvider = picker.indexOfSelectedItem == 0 ? .safari : .browser
        run { self.display(try await self.perform(self.command("cloudRebind", provider: provider))) }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { records.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard records.indices.contains(row), let id = tableColumn?.identifier.rawValue else { return nil }
        let entry = records[row]
        let value: String
        switch id {
        case "provider": value = entry.provider == .safari ? "Safari" : "Chrome/Edge"
        case "url": value = entry.url.absoluteString
        case "time": value = entry.destinationTime?.formatted(date: .abbreviated, time: .shortened) ?? "追加待ち"
        case "native":
            value = ["notObservable": "端末への到達確認待ち", "pending": "Safariの処理待ち",
                     "waitingForSafariActivity": "Safariの動作待ち", "possibleStall": "同期の進行が遅れています",
                     "checkpointCovered": "Safari側で処理済み", "localMissingOrChanged": "履歴が削除／変更されました",
                     "databaseChanged": "履歴DBが変更されました", "localRemoved": "履歴が削除されました",
                     "accountBindingChanged": "アカウント変更で取消済み"][entry.nativeState] ?? entry.nativeState
        default:
            value = ["unverified": "未確認", "seen": "到達を確認済み（申告）",
                     "notObserved": "まだ見つかっていません"][entry.remoteState] ?? entry.remoteState
        }
        let field = NSTextField(labelWithString: value)
        field.lineBreakMode = .byTruncatingMiddle
        field.toolTip = value
        return field
    }
}
