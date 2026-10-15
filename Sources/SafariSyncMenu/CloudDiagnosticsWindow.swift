import AppKit
import SafariSyncCore
import UniformTypeIdentifiers

@MainActor
final class CloudDiagnosticsWindow: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    let profileID: String
    private let request: (MenuCommand) async throws -> Data
    private let summary = NSTextField(wrappingLabelWithString: "Loading…")
    private let table = NSTableView()
    private var records: [CloudDelivery] = []
    private var assistEnabled = false
    private let assistToggle = NSButton(title: "", target: nil, action: nil)
    private var busy = false
    private var nextCursor: String?

    init(profileID: String, request: @escaping (MenuCommand) async throws -> Data) {
        self.profileID = profileID
        self.request = request
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1080, height: 620),
            styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Account Sync & Arrival Checks"
        window.minSize = NSSize(width: 920, height: 540)
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
            "Check the same account on iPhone/iPad in the receiving browser’s History. Search for the probe URL without opening it. A probe confirms only that probe. Safari checkpoints are not per-visit cloud receipts; Chrome/Edge account delivery is not observable through the public history interface.")
        stack.addArrangedSubview(instructions)
        instructions.widthAnchor.constraint(equalTo: summary.widthAnchor).isActive = true
        for (id, title, width) in [("provider", "Route", 80.0), ("url", "URL", 380.0),
                                    ("time", "Added", 120.0), ("native", "Native progress", 220.0),
                                    ("remote", "Receiver evidence", 160.0)] {
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
        assistToggle.target = self
        assistToggle.action = #selector(toggleSafariAssist)
        assistToggle.title = "Enable Safari Sync Assist…"
        let probes = NSStackView(views: [
            button("Refresh", #selector(refresh)),
            assistToggle,
            button("Older Deliveries", #selector(older)),
            button("Check Safari Arrival", #selector(probeSafari)),
            button("Check Chrome/Edge Arrival", #selector(probeBrowser)),
        ])
        probes.spacing = 8
        stack.addArrangedSubview(probes)
        let actions = NSStackView(views: [
            button("Seen on iPhone/iPad", #selector(markSeen)),
            button("Not Observed", #selector(markNotSeen)),
            button("Review Replay…", #selector(reviewReplay)),
            button("Compare Safari Export…", #selector(compareExport)),
            button("Rebind Account…", #selector(rebind)),
        ])
        actions.spacing = 8
        stack.addArrangedSubview(actions)
        window.center()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func button(_ title: String, _ action: Selector) -> NSButton {
        NSButton(title: title, target: self, action: action)
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
        assistEnabled = diagnostics.safariAssist?.enabled == true
        assistToggle.title = assistEnabled ? "Disable Safari Sync Assist" : "Enable Safari Sync Assist…"
        let health = diagnostics.summary
        summary.stringValue = "Profile: \(profileID) · Showing \(records.count) of \(diagnostics.totalDeliveries) recent deliveries\nPending local: \(health.pendingLocal) · Safari waiting: \(health.safariPending) · Possible stalls: \(health.possibleStalls) · Safari checkpoint covered: \(health.checkpointCovered) · Chrome/Edge arrival unverified: \(health.browserNotObservable) · Receiver confirmed: \(health.remoteSeen) · Removed/changed: \(health.suppressed)"
        if let assist = diagnostics.safariAssist {
            summary.stringValue += "\nSafari Sync Assist: \(assist.enabled ? "on" : "off") · Last action: \(assist.lastResult ?? "none")"
            if let next = assist.nextAttemptAt, health.safariPending > 0 {
                summary.stringValue += " · Next automatic attempt: \(next.formatted(date: .omitted, time: .standard))"
            }
        }
        if health.capacityReached { summary.stringValue += "\nTracking capacity reached; new delivery is waiting for space." }
    }

    private var selected: CloudDelivery? {
        records.indices.contains(table.selectedRow) ? records[table.selectedRow] : nil
    }

    private func run(_ work: @escaping () async throws -> Void) {
        guard !busy else { return }
        busy = true
        Task {
            defer { busy = false }
            do { try await work() }
            catch {
                let alert = NSAlert()
                alert.messageText = "Account sync action could not complete"
                if let typed = error as? TypedError {
                    switch typed.code {
                    case "CLOUD_EXTENSION_UPGRADE_REQUIRED":
                        alert.informativeText = "Connect or reload the bundled Chrome/Edge extension, then refresh this window."
                    case "PROFILE_NOT_ACTIVE", "STALE_CLOUD_REPAIR_PLAN":
                        alert.informativeText = "The profile, account binding, or repair plan changed. Reopen Account Sync and review the current deliveries."
                    case "INVALID_SAFARI_EXPORT":
                        alert.informativeText = "Use a supported Safari History.json export from the receiving device, no larger than 32 MiB. Unsupported formats cannot establish arrival."
                    case "CLOUD_REPLAY_NOT_ALLOWED":
                        alert.informativeText = "Select a locally confirmed delivery that has not been removed, changed, or rebound to another account."
                    default: alert.informativeText = typed.code
                    }
                } else { alert.informativeText = "The Agent is unavailable or the selected file could not be read. Refresh the app’s status and try again." }
                alert.runModal()
            }
        }
    }

    @objc private func toggleSafariAssist() {
        if !assistEnabled {
            let alert = NSAlert()
            alert.messageText = "Enable Safari Sync Assist?"
            alert.informativeText = "When this app’s Safari visits remain pending, reuse a dedicated sync tab to load example.com in Safari. This creates ordinary history entries that can sync to your devices. Safari may ask for Automation permission. The helper waits at least 90 seconds, then retries while work remains. Without progress, retries slow from 5 minutes to at most once per hour. Progress restores the 5-minute interval. It stops when the visits are checkpoint-covered or confirmed on your device. It does not edit your other tabs. You can disable it here."
            alert.addButton(withTitle: "Enable")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        let action = assistEnabled ? "disable" : "enable"
        run { self.display(try await self.perform(self.command("cloudSafariAssist", result: action))) }
    }

    @objc func refresh() {
        run { self.display(try await self.perform(self.command("cloudStatus"))) }
    }

    @objc private func older() {
        guard let cursor = nextCursor else { return }
        run { self.display(try await self.perform(self.command("cloudStatus", deliveryID: cursor))) }
    }

    private func probe(_ provider: CloudProvider) {
        run {
            let before = Set(self.records.map(\.id))
            let diagnostics = try await self.perform(self.command("cloudProbe", provider: provider))
            self.display(diagnostics)
            if let row = self.records.firstIndex(where: { !before.contains($0.id) && $0.kind == "probe" && $0.provider == provider }) {
                self.table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                let alert = NSAlert()
                alert.messageText = "Search the receiving browser’s History"
                alert.informativeText = "\(self.records[row].url.absoluteString)\n\nUse Safari for the iCloud route, or the selected Chrome/Edge account for the browser route. Do not open this URL on the receiving device first. Refresh after local delivery, then record Seen or Not Observed. A missing item is not proof that the cloud record is absent."
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
            alert.messageText = "Replay this URL signal?"
            alert.informativeText = "\(plan.url.absoluteString)\n\nRoute: \(plan.provider == .safari ? "Safari / iCloud" : "Chrome/Edge account")\nProfile: \(plan.profileID)\n\nConfirm the browser/iCloud account is the intended account and history sync is enabled. This creates one new visit at the replay time. It does not confirm cloud arrival or remove the previous visit."
            alert.addButton(withTitle: "Replay URL")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            self.display(try await self.perform(self.command("cloudExecuteReplay", planID: plan.id)))
        }
    }

    @objc private func compareExport() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.message = "Choose Safari History.json exported from the receiving iPhone/iPad (up to 32 MiB)."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let alert = NSAlert()
        alert.messageText = "Confirm the export’s source"
        alert.informativeText = "This file must come from the receiving iPhone/iPad using the same Apple Account and Safari profile. A file exported from this Mac cannot prove remote arrival. Only exact URL/latest-visit-time matches are recorded; absent entries remain unverified."
        alert.addButton(withTitle: "Compare Receiver Export")
        alert.addButton(withTitle: "Cancel")
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
        picker.addItems(withTitles: ["Safari / Apple Account", "Chrome/Edge account"])
        let alert = NSAlert()
        alert.messageText = "Record an account change"
        alert.informativeText = "Use this after changing the corresponding account. Previous evidence remains in the journal, but is excluded from this binding. Pending probes/replays and old repair plans are invalidated. This does not change browser sign-in or history settings."
        alert.accessoryView = picker
        alert.addButton(withTitle: "Rebind")
        alert.addButton(withTitle: "Cancel")
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
        case "provider": value = entry.provider == .safari ? "iCloud" : "Browser"
        case "url": value = entry.url.absoluteString
        case "time": value = entry.destinationTime?.formatted(date: .abbreviated, time: .shortened) ?? "Queued"
        case "native":
            value = ["notObservable": "Account delivery not observable", "pending": "Waiting for Safari",
                     "waitingForSafariActivity": "Waiting for Safari activity", "possibleStall": "Possible stall",
                     "checkpointCovered": "Safari checkpoint covered", "localMissingOrChanged": "Local visit removed/changed",
                     "databaseChanged": "History database changed", "localRemoved": "Local history removed"][entry.nativeState] ?? entry.nativeState
        default:
            value = ["unverified": "Unverified", "seen": "Seen (user evidence)",
                     "notObserved": "Not observed (not absence)"][entry.remoteState] ?? entry.remoteState
        }
        let field = NSTextField(labelWithString: value)
        field.lineBreakMode = .byTruncatingMiddle
        field.toolTip = value
        return field
    }
}
