import AppKit
import SafariSyncCore

enum ViewerReadiness: Equatable {
    case off
    case starting
    case ready(Date)
    case unavailable(lastReady: Date?)
}

struct MenuStatusPresentation {
    struct Row {
        let title: String
        var details: [String] = []
        var attention = false
    }

    let collection: Row
    let sync: Row
    let viewer: Row
    let canOpenHistory: Bool

    init(snapshot: MenuStatusSnapshot?, viewer: ViewerReadiness, loading: Bool) {
        collection = Self.collectionRow(snapshot, loading: loading)
        sync = Self.syncRow(snapshot, loading: loading)
        self.viewer = Self.viewerRow(viewer)
        if case .ready = viewer { canOpenHistory = true } else { canOpenHistory = false }
    }

    private static func stamp(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }

    private static func collectionRow(_ snapshot: MenuStatusSnapshot?, loading: Bool) -> Row {
        guard let collection = snapshot?.collection else {
            return Row(title: loading ? NSLocalizedString("Collection: Checking…", comment: "")
                       : NSLocalizedString("Collection: Unavailable", comment: ""),
                       attention: !loading)
        }
        guard collection.enabled else {
            return Row(title: NSLocalizedString("Collection: Off", comment: ""))
        }
        let sources = collection.sources.sorted { $0.browser == .safari && $1.browser == .chromium }
        let failed = sources.contains { $0.state == "failed" }
        let waiting = sources.contains { $0.state == "waiting" }
        let collecting = sources.contains { $0.state == "collecting" || $0.state == "pending" }
        let title: String
        if failed { title = NSLocalizedString("Collection: Needs Attention", comment: "") }
        else if waiting { title = NSLocalizedString("Collection: Waiting for Database", comment: "") }
        else if collecting { title = NSLocalizedString("Collection: Collecting", comment: "") }
        else { title = NSLocalizedString("Collection: On", comment: "") }

        var details = sources.map { source in
            let name = source.browser == .safari ? source.browserType : "\(source.browserType) · \(source.profileName)"
            let state = NSLocalizedString("collection." + source.state, value: source.state, comment: "")
            let scan = source.lastScan.map { stamp(Date(timeIntervalSince1970: $0)) } ?? NSLocalizedString("None", comment: "")
            return String(format: NSLocalizedString("%@ · %@ · Last scan %@", comment: ""), name, state, scan)
        }
        if let partner = sources.first(where: { $0.id == collection.pair?.source }) {
            let live = partner.lastLiveVisit.map { stamp(Date(timeIntervalSince1970: $0)) } ?? NSLocalizedString("Unverified", comment: "")
            details.append(String(format: NSLocalizedString("Last visit received from extension · %@", comment: ""), live))
            if waiting, partner.state == "waiting", partner.lastScan == nil {
                details.append(NSLocalizedString("Quit the selected browser to allow the first scan, then collect again.", comment: ""))
            }
        }
        if failed {
            details.append(NSLocalizedString("Check access and restart the service in General.", comment: ""))
        }
        if snapshot?.extensionUpdateRequired == true {
            details.append(NSLocalizedString("Reload the bundled extension in the selected profile.", comment: ""))
        }
        return Row(title: title, details: details, attention: failed || snapshot?.extensionUpdateRequired == true)
    }

    private static func syncRow(_ snapshot: MenuStatusSnapshot?, loading: Bool) -> Row {
        guard let health = snapshot?.sync else {
            return Row(title: loading ? NSLocalizedString("Sync: Checking…", comment: "")
                       : NSLocalizedString("Sync: Unavailable", comment: ""),
                       attention: !loading && snapshot?.collection != nil)
        }
        let pair = snapshot?.collection?.pair
        var details: [String] = []
        if health.runtimeState != "initializing", health.syncRequested != nil {
            details.append(String(format: NSLocalizedString("Pending browser deliveries %@ · Automatic retries %@", comment: ""),
                                  String(health.pendingSafariToBrowser), String(health.recoveryCount)))
        }
        if let lastDelivery = health.cloud?.lastLocalDeliveryAt {
            details.append(String(format: NSLocalizedString("Last local delivery · %@", comment: ""), stamp(lastDelivery)))
        }
        if health.syncRequested == false {
            return Row(title: NSLocalizedString("Sync: Off", comment: ""), details: details)
        }
        if health.runtimeState == "initializing" {
            return Row(title: NSLocalizedString("Sync: Checking…", comment: ""), details: details)
        }
        if health.runtimeState == "blocked" {
            return Row(title: NSLocalizedString("Sync: Needs Attention", comment: ""),
                       details: details, attention: true)
        }
        if !health.enabled {
            return Row(title: NSLocalizedString("Sync: Paused", comment: ""),
                       details: details)
        }
        let connected = health.connectedProfiles.contains { $0.profileID == health.activeProfileID && $0.profileID == pair?.extensionID }
        if health.cloud?.lastLocalDeliveryAt == nil {
            details.append(String(format: NSLocalizedString("Last local delivery · %@", comment: ""), NSLocalizedString("Unverified", comment: "")))
        }
        return Row(title: connected ? NSLocalizedString("Sync: On", comment: "")
                   : NSLocalizedString("Sync: Waiting for Extension", comment: ""),
                   details: details)
    }

    private static func viewerRow(_ viewer: ViewerReadiness) -> Row {
        switch viewer {
        case .off:
            Row(title: NSLocalizedString("Viewer: Off", comment: ""))
        case .starting:
            Row(title: NSLocalizedString("Viewer: Checking…", comment: ""))
        case .ready(let date):
            Row(title: NSLocalizedString("Viewer: Ready on This Mac", comment: ""),
                details: [String(format: NSLocalizedString("Last local check · %@", comment: ""), stamp(date)),
                          NSLocalizedString("Access from other devices is unverified", comment: "")])
        case .unavailable(let lastReady):
            Row(title: NSLocalizedString("Viewer: Unavailable", comment: ""),
                details: lastReady.map { [String(format: NSLocalizedString("Last successful local check · %@", comment: ""), stamp($0))] } ?? [],
                attention: true)
        }
    }
}
