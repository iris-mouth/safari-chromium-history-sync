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
    private let advanced = NSStackView()
    private var selectionButtons: [NSButton] = []
    private var busy = false
    private var nextCursor: String?

    init(profileID: String, request: @escaping (MenuCommand) async throws -> Data) {
        self.profileID = profileID
        self.request = request
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1080, height: 620),
            styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "History Sync Diagnostics"
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
            "Review delivered history and sync progress here. Check arrival in your iPhone or iPad's history. Expand Show Tests & Advanced Actions to add test history or resend a visit.")
        stack.addArrangedSubview(instructions)
        instructions.widthAnchor.constraint(equalTo: summary.widthAnchor).isActive = true
        for (id, title, width) in [("provider", "Destination", 80.0), ("url", "URL", 380.0),
                                    ("time", "Added to History", 130.0), ("native", "Native Sync Progress", 210.0),
                                    ("remote", "Arrival on Device", 170.0)] {
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
            button("Refresh Display", #selector(refresh)),
            button("Show Older Records", #selector(older)),
            selectionButton("Copy Selected URL", #selector(copyURL)),
        ])
        browsing.spacing = 8
        stack.addArrangedSubview(browsing)
        let disclosure = NSButton(checkboxWithTitle: "Show Tests & Advanced Actions", target: self, action: #selector(toggleAdvanced(_:)))
        stack.addArrangedSubview(disclosure)
        advanced.orientation = .vertical
        advanced.spacing = 8
        stack.addArrangedSubview(advanced)
        let explanation = NSTextField(wrappingLabelWithString:
            "Adding a test URL or resending it creates a new history visit. Review the destination and changes before confirming. Search the device's history for the selected URL before recording arrival.")
        advanced.addArrangedSubview(explanation)
        explanation.widthAnchor.constraint(equalTo: summary.widthAnchor).isActive = true
        let probes = NSStackView(views: [
            button("Add Test History to Safari…", #selector(probeSafari)),
            button("Add Test History to Chrome/Edge…", #selector(probeBrowser)),
            selectionButton("Record Arrival on Device", #selector(markSeen)),
            selectionButton("Record as Unconfirmed", #selector(markNotSeen)),
        ])
        probes.spacing = 8
        advanced.addArrangedSubview(probes)
        let actions = NSStackView(views: [
            selectionButton("Add Selected URL to History Again…", #selector(reviewReplay)),
            button("Compare Device's Safari History…", #selector(compareExport)),
            button("Record Account Change…", #selector(rebind)),
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
        summary.stringValue = "Showing \(records.count) of \(diagnostics.totalDeliveries) records\nPending local delivery: \(health.pendingLocal) · Waiting for Safari sync: \(health.safariPending) · Possible stalls: \(health.possibleStalls)\nSafari checkpoint covered: \(health.checkpointCovered) · Chrome/Edge arrival unverified: \(health.browserNotObservable) · Arrival confirmed on device: \(health.remoteSeen) · Removed/changed: \(health.suppressed)"
        if let assist = diagnostics.safariAssist {
            summary.stringValue += "\nSafari sync assist: \(assist.enabled ? "Enabled" : "Disabled") (change via Configure Safari Sync Assist… in the menu)"
            if let next = assist.nextAttemptAt, health.safariPending > 0 {
                summary.stringValue += "\nNext automatic attempt: \(next.formatted(date: .omitted, time: .standard))"
            }
        }
        if health.capacityReached { summary.stringValue += "\nThe record limit was reached. New deliveries wait until space is available." }
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
                alert.messageText = "Could Not Complete the Action"
                if let typed = error as? TypedError {
                    switch typed.code {
                    case "CLOUD_EXTENSION_UPGRADE_REQUIRED":
                        alert.informativeText = "Reload the Chrome/Edge extension bundled with the app, then refresh the display."
                    case "PROFILE_NOT_ACTIVE", "STALE_CLOUD_REPAIR_PLAN":
                        alert.informativeText = "The sync browser or account binding changed. Close this window and reopen Detailed Diagnostics."
                    case "INVALID_SAFARI_EXPORT":
                        alert.informativeText = "Choose Safari's History.json exported from the receiving device (up to 32 MiB)."
                    case "CLOUD_REPLAY_NOT_ALLOWED":
                        alert.informativeText = "Choose a confirmed local delivery that has not been removed, changed, or affected by an account change."
                    default: alert.informativeText = typed.code
                    }
                } else { alert.informativeText = "The sync service is unavailable or the selected file could not be read. Check the connection and file." }
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
        let route = provider == .safari ? "Safari on this Mac" : "the selected Chrome/Edge profile"
        let confirmation = NSAlert()
        confirmation.messageText = "Add Test History to \(route)?"
        confirmation.informativeText = "A unique example.com test URL will be added through the normal delivery path. It may sync to other devices. After delivery, search for the URL in your iPhone or iPad's history to check arrival."
        confirmation.addButton(withTitle: "Add Test History")
        confirmation.addButton(withTitle: "Cancel")
        guard confirmation.runModal() == .alertFirstButtonReturn else { return }
        run {
            let before = Set(self.records.map(\.id))
            let diagnostics = try await self.perform(self.command("cloudProbe", provider: provider))
            self.display(diagnostics)
            if let row = self.records.firstIndex(where: { !before.contains($0.id) && $0.kind == "probe" && $0.provider == provider }) {
                self.table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                let alert = NSAlert()
                alert.messageText = "Search for This URL in the Device's History"
                alert.informativeText = "\(self.records[row].url.absoluteString)\n\nSearch Safari or Chrome/Edge history on an iPhone or iPad using the same account. Confirm that the URL is listed before opening it. Once delivery is complete, refresh the display and record arrival for the selected record."
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
            alert.messageText = "Add the Selected URL to History Again?"
            alert.informativeText = "\(plan.url.absoluteString)\n\nDestination: \(plan.provider == .safari ? "Safari / iCloud" : "Selected Chrome/Edge profile")\n\nCheck that the intended account is signed in and history sync is enabled. This adds one visit at the current time. Check arrival on the receiving device afterward."
            alert.addButton(withTitle: "Add to History Again")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            self.display(try await self.perform(self.command("cloudExecuteReplay", planID: plan.id)))
        }
    }

    @objc private func compareExport() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.message = "Choose Safari's History.json exported from the receiving iPhone or iPad (up to 32 MiB)."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let alert = NSAlert()
        alert.messageText = "Is This File from the Receiving Device?"
        alert.informativeText = "Use a file from an iPhone or iPad with the same Apple Account and Safari profile. Records with a matching URL and latest visit time will be marked as arrived. Missing records remain unverified."
        alert.addButton(withTitle: "Compare with File")
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
        picker.addItems(withTitles: ["Safari / Apple Account", "Chrome/Edge Account"])
        let alert = NSAlert()
        alert.messageText = "Record an Account Change for Sync?"
        alert.informativeText = "Use this after changing the browser or iCloud account. Pending tests and replays for the previous account are cancelled, and earlier arrival evidence stays separate from the new account. Change the signed-in account in the browser or System Settings."
        alert.accessoryView = picker
        alert.addButton(withTitle: "Record Account Change")
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
        case "provider": value = entry.provider == .safari ? "Safari" : "Chrome/Edge"
        case "url": value = entry.url.absoluteString
        case "time": value = entry.destinationTime?.formatted(date: .abbreviated, time: .shortened) ?? "Pending delivery"
        case "native":
            value = ["notObservable": "Waiting for device confirmation", "pending": "Waiting for Safari sync",
                     "waitingForSafariActivity": "Waiting for Safari activity", "possibleStall": "Sync progress is delayed",
                     "checkpointCovered": "Safari checkpoint covered", "localMissingOrChanged": "History removed or changed",
                     "databaseChanged": "History database changed", "localRemoved": "History removed",
                     "accountBindingChanged": "Cancelled after account change"][entry.nativeState] ?? entry.nativeState
        default:
            value = ["unverified": "Unverified", "seen": "Arrival confirmed (reported)",
                     "notObserved": "Not found yet"][entry.remoteState] ?? entry.remoteState
        }
        let field = NSTextField(labelWithString: value)
        field.lineBreakMode = .byTruncatingMiddle
        field.toolTip = value
        return field
    }
}
