import AppKit
import SafariSyncCore

enum ViewerReadiness: Equatable {
    case off
    case starting
    case ready(Date)
    case unavailable(lastReady: Date?)
}

struct MenuStatusPresentation {
    enum Action {
        case collectionSettings, collect, access, restartAgent, syncSettings, resolveSync, viewerSettings, retryViewer, openHistory
    }

    struct Row {
        let title: String
        var details: [String] = []
        var actions: [Action] = []
        var attention = false
    }

    let collection: Row
    let sync: Row
    let viewer: Row

    init(snapshot: MenuStatusSnapshot?, viewer: ViewerReadiness, loading: Bool) {
        collection = Self.collectionRow(snapshot, loading: loading)
        sync = Self.syncRow(snapshot, loading: loading)
        self.viewer = Self.viewerRow(viewer)
    }

    private static func stamp(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }

    private static func collectionRow(_ snapshot: MenuStatusSnapshot?, loading: Bool) -> Row {
        guard let collection = snapshot?.collection else {
            return Row(title: loading ? NSLocalizedString("History Collection · Checking…", comment: "")
                       : NSLocalizedString("History Collection · Unavailable", comment: ""),
                       actions: loading ? [] : [.restartAgent])
        }
        guard collection.enabled else {
            return Row(title: NSLocalizedString("History Collection · Off", comment: ""), actions: [.collectionSettings])
        }
        let sources = collection.sources.sorted { $0.browser == .safari && $1.browser == .chromium }
        let failed = sources.contains { $0.state == "failed" }
        let waiting = sources.contains { $0.state == "waiting" }
        let collecting = sources.contains { $0.state == "collecting" || $0.state == "pending" }
        let title: String
        if failed { title = NSLocalizedString("History Collection · Needs Attention", comment: "") }
        else if waiting { title = NSLocalizedString("History Collection · Waiting for Database", comment: "") }
        else if collecting { title = NSLocalizedString("History Collection · Collecting", comment: "") }
        else { title = NSLocalizedString("History Collection · On", comment: "") }

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
        var actions: [Action] = [.collect]
        if failed, snapshot?.sync?.issueCode == AgentIssueCode.safariAccessUnavailable,
           sources.contains(where: { $0.browser == .safari && $0.state == "failed" }) { actions.insert(.access, at: 0) }
        if failed { actions.append(.collectionSettings) }
        if snapshot?.extensionUpdateRequired == true {
            details.append(NSLocalizedString("Reload the bundled extension in the selected profile.", comment: ""))
            actions.append(.syncSettings)
        }
        return Row(title: title, details: details, actions: actions, attention: failed)
    }

    private static func syncRow(_ snapshot: MenuStatusSnapshot?, loading: Bool) -> Row {
        guard let health = snapshot?.sync else {
            return Row(title: loading ? NSLocalizedString("Browser Sync · Checking…", comment: "")
                       : NSLocalizedString("Browser Sync · Unavailable", comment: ""),
                       actions: !loading && snapshot?.collection != nil ? [.restartAgent] : [])
        }
        let pair = snapshot?.collection?.pair
        let profile = snapshot?.collection?.sources.first { $0.id == pair?.source }
        var details = profile.map { ["\($0.browserType) · \($0.profileName)"] } ?? []
        if health.runtimeState != "initializing", health.syncRequested != nil {
            details.append(String(format: NSLocalizedString("Pending browser deliveries %@ · Automatic retries %@", comment: ""),
                                  String(health.pendingSafariToBrowser), String(health.recoveryCount)))
        }
        if let lastDelivery = health.cloud?.lastLocalDeliveryAt {
            details.append(String(format: NSLocalizedString("Last local delivery · %@", comment: ""), stamp(lastDelivery)))
        }
        if health.syncRequested == false {
            return Row(title: NSLocalizedString("Browser Sync · Off", comment: ""), details: details)
        }
        if health.runtimeState == "initializing" {
            return Row(title: NSLocalizedString("Browser Sync · Checking…", comment: ""), details: details)
        }
        if health.runtimeState == "blocked" {
            let actions: [Action]
            switch health.issueCode {
            case AgentIssueCode.safariAccessUnavailable: actions = [.access, .restartAgent]
            case AgentIssueCode.keychainUnavailable: actions = [.resolveSync, .restartAgent]
            case AgentIssueCode.collectionUnavailable: actions = snapshot?.collection == nil ? [] : [.restartAgent]
            case nil: actions = [.restartAgent]
            default: actions = [.resolveSync]
            }
            return Row(title: NSLocalizedString("Browser Sync · Needs Attention", comment: ""),
                       details: details, actions: actions, attention: true)
        }
        if !health.enabled {
            return Row(title: NSLocalizedString("Browser Sync · Paused", comment: ""),
                       details: details, actions: [.syncSettings])
        }
        let connected = health.connectedProfiles.contains { $0.profileID == health.activeProfileID && $0.profileID == pair?.extensionID }
        if health.cloud?.lastLocalDeliveryAt == nil {
            details.append(String(format: NSLocalizedString("Last local delivery · %@", comment: ""), NSLocalizedString("Unverified", comment: "")))
        }
        return Row(title: connected ? NSLocalizedString("Browser Sync · On", comment: "")
                   : NSLocalizedString("Browser Sync · Waiting for Extension", comment: ""),
                   details: details, actions: connected ? [] : [.syncSettings])
    }

    private static func viewerRow(_ viewer: ViewerReadiness) -> Row {
        switch viewer {
        case .off:
            Row(title: NSLocalizedString("Web Viewer · Off", comment: ""), actions: [.viewerSettings])
        case .starting:
            Row(title: NSLocalizedString("Web Viewer · Checking…", comment: ""))
        case .ready(let date):
            Row(title: NSLocalizedString("Web Viewer · Ready on This Mac", comment: ""),
                details: [String(format: NSLocalizedString("Last local check · %@", comment: ""), stamp(date)),
                          NSLocalizedString("Access from other devices is unverified", comment: "")],
                actions: [.openHistory])
        case .unavailable(let lastReady):
            Row(title: NSLocalizedString("Web Viewer · Unavailable", comment: ""),
                details: lastReady.map { [String(format: NSLocalizedString("Last successful local check · %@", comment: ""), stamp($0))] } ?? [],
                actions: [.retryViewer, .viewerSettings], attention: true)
        }
    }
}
