import AppKit
import SafariSyncCore
import UniformTypeIdentifiers

@MainActor
final class CloudDiagnosticsWindow: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    let profileID: String
    private let request: (MenuCommand) async throws -> Data
    private let summary = NSTextField(wrappingLabelWithString: NSLocalizedString("Loading…", comment: ""))
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
        window.title = NSLocalizedString("History Sync Diagnostics", comment: "")
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
            NSLocalizedString("Review delivered history and sync progress here. Check arrival in your iPhone or iPad's history. Expand Show Tests & Advanced Actions to add test history or resend a visit.", comment: ""))
        stack.addArrangedSubview(instructions)
        instructions.widthAnchor.constraint(equalTo: summary.widthAnchor).isActive = true
        for (id, title, width) in [("provider", NSLocalizedString("Destination", comment: ""), 80.0), ("url", "URL", 380.0),
                                    ("time", NSLocalizedString("Added to History", comment: ""), 130.0), ("native", NSLocalizedString("Native Sync Progress", comment: ""), 210.0),
                                    ("remote", NSLocalizedString("Arrival on Device", comment: ""), 170.0)] {
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
            button(NSLocalizedString("Refresh Display", comment: ""), #selector(refresh)),
            button(NSLocalizedString("Show Older Records", comment: ""), #selector(older)),
            selectionButton(NSLocalizedString("Copy Selected URL", comment: ""), #selector(copyURL)),
        ])
        browsing.spacing = 8
        stack.addArrangedSubview(browsing)
        let disclosure = NSButton(checkboxWithTitle: NSLocalizedString("Show Tests & Advanced Actions", comment: ""), target: self, action: #selector(toggleAdvanced(_:)))
        stack.addArrangedSubview(disclosure)
        advanced.orientation = .vertical
        advanced.spacing = 8
        stack.addArrangedSubview(advanced)
        let explanation = NSTextField(wrappingLabelWithString:
            NSLocalizedString("Adding a test URL or resending it creates a new history visit. Review the destination and changes before confirming. Search the device's history for the selected URL before recording arrival.", comment: ""))
        advanced.addArrangedSubview(explanation)
        explanation.widthAnchor.constraint(equalTo: summary.widthAnchor).isActive = true
        let probes = NSStackView(views: [
            button(NSLocalizedString("Add Test History to Safari…", comment: ""), #selector(probeSafari)),
            button(NSLocalizedString("Add Test History to Chrome/Edge…", comment: ""), #selector(probeBrowser)),
            selectionButton(NSLocalizedString("Record Arrival on Device", comment: ""), #selector(markSeen)),
            selectionButton(NSLocalizedString("Record as Unconfirmed", comment: ""), #selector(markNotSeen)),
        ])
        probes.spacing = 8
        advanced.addArrangedSubview(probes)
        let actions = NSStackView(views: [
            selectionButton(NSLocalizedString("Add Selected URL to History Again…", comment: ""), #selector(reviewReplay)),
            button(NSLocalizedString("Compare Device's Safari History…", comment: ""), #selector(compareExport)),
            button(NSLocalizedString("Record Account Change…", comment: ""), #selector(rebind)),
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
        summary.stringValue = String(format: NSLocalizedString("Showing %@ of %@ records\nPending local delivery: %@ · Waiting for Safari sync: %@ · Possible stalls: %@\nSafari checkpoint covered: %@ · Chrome/Edge arrival unverified: %@ · Arrival confirmed on device: %@ · Removed/changed: %@", comment: ""), String(describing: records.count), String(describing: diagnostics.totalDeliveries), String(describing: health.pendingLocal), String(describing: health.safariPending), String(describing: health.possibleStalls), String(describing: health.checkpointCovered), String(describing: health.browserNotObservable), String(describing: health.remoteSeen), String(describing: health.suppressed))
        if let assist = diagnostics.safariAssist {
            summary.stringValue += String(format: NSLocalizedString("\nSafari sync assist: %@ (change via Configure Safari Sync Assist… in the menu)", comment: ""), String(describing: assist.enabled ? NSLocalizedString("Enabled", comment: "") : NSLocalizedString("Disabled", comment: "")))
            if let next = assist.nextAttemptAt, health.safariPending > 0 {
                summary.stringValue += String(format: NSLocalizedString("\nNext automatic attempt: %@", comment: ""), String(describing: next.formatted(date: .omitted, time: .standard)))
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
                alert.messageText = NSLocalizedString("Could Not Complete the Action", comment: "")
                if let typed = error as? TypedError {
                    switch typed.code {
                    case "CLOUD_EXTENSION_UPGRADE_REQUIRED":
                        alert.informativeText = NSLocalizedString("Reload the Chrome/Edge extension bundled with the app, then refresh the display.", comment: "")
                    case "PROFILE_NOT_ACTIVE", "STALE_CLOUD_REPAIR_PLAN":
                        alert.informativeText = NSLocalizedString("The sync browser or account binding changed. Close this window and reopen Detailed Diagnostics.", comment: "")
                    case "INVALID_SAFARI_EXPORT":
                        alert.informativeText = NSLocalizedString("Choose Safari's History.json exported from the receiving device (up to 32 MiB).", comment: "")
                    case "CLOUD_REPLAY_NOT_ALLOWED":
                        alert.informativeText = NSLocalizedString("Choose a confirmed local delivery that has not been removed, changed, or affected by an account change.", comment: "")
                    default: alert.informativeText = typed.code
                    }
                } else { alert.informativeText = NSLocalizedString("The sync service is unavailable or the selected file could not be read. Check the connection and file.", comment: "") }
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
        let route = provider == .safari ? NSLocalizedString("Safari on this Mac", comment: "") : NSLocalizedString("the selected Chrome/Edge profile", comment: "")
        let confirmation = NSAlert()
        confirmation.messageText = String(format: NSLocalizedString("Add Test History to %@?", comment: ""), String(describing: route))
        confirmation.informativeText = NSLocalizedString("A unique example.com test URL will be added through the normal delivery path. It may sync to other devices. After delivery, search for the URL in your iPhone or iPad's history to check arrival.", comment: "")
        confirmation.addButton(withTitle: NSLocalizedString("Add Test History", comment: ""))
        confirmation.addButton(withTitle: NSLocalizedString("Cancel", comment: ""))
        guard confirmation.runModal() == .alertFirstButtonReturn else { return }
        run {
            let before = Set(self.records.map(\.id))
            let diagnostics = try await self.perform(self.command("cloudProbe", provider: provider))
            self.display(diagnostics)
            if let row = self.records.firstIndex(where: { !before.contains($0.id) && $0.kind == "probe" && $0.provider == provider }) {
                self.table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                let alert = NSAlert()
                alert.messageText = NSLocalizedString("Search for This URL in the Device's History", comment: "")
                alert.informativeText = String(format: NSLocalizedString("%@\n\nSearch Safari or Chrome/Edge history on an iPhone or iPad using the same account. Confirm that the URL is listed before opening it. Once delivery is complete, refresh the display and record arrival for the selected record.", comment: ""), String(describing: self.records[row].url.absoluteString))
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
            alert.messageText = NSLocalizedString("Add the Selected URL to History Again?", comment: "")
            alert.informativeText = String(format: NSLocalizedString("%@\n\nDestination: %@\n\nCheck that the intended account is signed in and history sync is enabled. This adds one visit at the current time. Check arrival on the receiving device afterward.", comment: ""), String(describing: plan.url.absoluteString), String(describing: plan.provider == .safari ? "Safari / iCloud" : "Selected Chrome/Edge profile"))
            alert.addButton(withTitle: NSLocalizedString("Add to History Again", comment: ""))
            alert.addButton(withTitle: NSLocalizedString("Cancel", comment: ""))
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            self.display(try await self.perform(self.command("cloudExecuteReplay", planID: plan.id)))
        }
    }

    @objc private func compareExport() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.message = NSLocalizedString("Choose Safari's History.json exported from the receiving iPhone or iPad (up to 32 MiB).", comment: "")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let alert = NSAlert()
        alert.messageText = NSLocalizedString("Is This File from the Receiving Device?", comment: "")
        alert.informativeText = NSLocalizedString("Use a file from an iPhone or iPad with the same Apple Account and Safari profile. Records with a matching URL and latest visit time will be marked as arrived. Missing records remain unverified.", comment: "")
        alert.addButton(withTitle: NSLocalizedString("Compare with File", comment: ""))
        alert.addButton(withTitle: NSLocalizedString("Cancel", comment: ""))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        run {
            let file = try FileHandle(forReadingFrom: url)
            defer { try? file.close() }
            let data = try file.read(upToCount: 32 * 1024 * 1024 + 1) ?? Data()
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
        picker.addItems(withTitles: [NSLocalizedString("Safari / Apple Account", comment: ""), NSLocalizedString("Chrome/Edge Account", comment: "")])
        let alert = NSAlert()
        alert.messageText = NSLocalizedString("Record an Account Change for Sync?", comment: "")
        alert.informativeText = NSLocalizedString("Use this after changing the browser or iCloud account. Pending tests and replays for the previous account are cancelled, and earlier arrival evidence stays separate from the new account. Change the signed-in account in the browser or System Settings.", comment: "")
        alert.accessoryView = picker
        alert.addButton(withTitle: NSLocalizedString("Record Account Change", comment: ""))
        alert.addButton(withTitle: NSLocalizedString("Cancel", comment: ""))
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
        case "time": value = entry.destinationTime?.formatted(date: .abbreviated, time: .shortened) ?? NSLocalizedString("Pending delivery", comment: "")
        case "native":
            value = ["notObservable": NSLocalizedString("Waiting for device confirmation", comment: ""), "pending": NSLocalizedString("Waiting for Safari sync", comment: ""),
                     "waitingForSafariActivity": NSLocalizedString("Waiting for Safari activity", comment: ""), "possibleStall": NSLocalizedString("Sync progress is delayed", comment: ""),
                     "checkpointCovered": NSLocalizedString("Safari checkpoint covered", comment: ""), "localMissingOrChanged": NSLocalizedString("History removed or changed", comment: ""),
                     "databaseChanged": NSLocalizedString("History database changed", comment: ""), "localRemoved": NSLocalizedString("History removed", comment: ""),
                     "accountBindingChanged": NSLocalizedString("Cancelled after account change", comment: "")][entry.nativeState] ?? entry.nativeState
        default:
            value = ["unverified": NSLocalizedString("Unverified", comment: ""), "seen": NSLocalizedString("Arrival confirmed (reported)", comment: ""),
                     "notObserved": NSLocalizedString("Not found yet", comment: "")][entry.remoteState] ?? entry.remoteState
        }
        let field = NSTextField(labelWithString: value)
        field.lineBreakMode = .byTruncatingMiddle
        field.toolTip = value
        return field
    }
}
