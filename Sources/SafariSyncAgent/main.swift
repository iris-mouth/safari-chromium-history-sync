import Darwin
import AppKit
import Foundation
import os
import SafariSyncCore

private final class AgentRuntime: @unchecked Sendable {
    private let runtimeDirectory: URL
    private let historyURL: URL
    private let agentBuild: String?
    private let lock = NSLock()
    private var service: AgentService?
    private var history: SafariHistoryStore?
    private var runtimeState = "initializing"
    private var issueCode: String?
    private var cloudTrigger: DispatchSourceTimer?
    private var connectionChallenge: (token: String, revision: String, expires: Date)?
    private var collector: HistoryCollector?
    private var collectionTimer: DispatchSourceTimer?
    private let collectionQueue = DispatchQueue(label: "io.github.irismouth.history-sync.collection", qos: .utility)

    init(runtimeDirectory: URL, historyURL: URL, agentBuild: String?) {
        self.runtimeDirectory = runtimeDirectory
        self.historyURL = historyURL
        self.agentBuild = agentBuild
    }

    func initialize() {
        initializeCollector()
        guard LegacyWriterDetector.detect().isEmpty else {
            block("legacyWriterDetected")
            return
        }
        let compatibility: RuntimeCompatibility
        do {
            compatibility = try CompatibilityGate.assess(CompatibilityGate.detect())
        } catch {
            block(AgentIssueCode.runtimeUnsupported)
            return
        }

        let stateSecret: Data
        #if DEBUG
        // Only isolated debug fixtures may bypass Keychain; release builds do
        // not contain this path and always use the existing Keychain boundary.
        let temporaryRoot = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path + "/"
        let testSecret = ProcessInfo.processInfo.environment["SAFARI_SYNC_SYNTHETIC_TEST"] == "1"
            && runtimeDirectory.resolvingSymlinksInPath().path.hasPrefix(temporaryRoot)
            && historyURL.resolvingSymlinksInPath().path.hasPrefix(temporaryRoot)
        if testSecret { stateSecret = Data(repeating: 73, count: 32) }
        else {
            do { stateSecret = try KeychainRootSecret.load(createIfMissing: true) }
            catch { block(AgentIssueCode.keychainUnavailable); return }
        }
        #else
        do { stateSecret = try KeychainRootSecret.load(createIfMissing: true) }
        catch { block(AgentIssueCode.keychainUnavailable); return }
        #endif

        let history = SafariHistoryStore(
            databaseURL: historyURL,
            ledgerURL: runtimeDirectory.appendingPathComponent("delivery-ledger.sqlite"),
            schema: .historyV1
        )
        let readyService = AgentService(
            history: history,
            stateURL: runtimeDirectory.appendingPathComponent("state.sealed"),
            secret: stateSecret,
            agentBuild: agentBuild,
            compatibility: compatibility, collector: collector
        )
        let pair: HistoryCollector.Pair?
        do {
            guard let collector else { throw TypedError(code: AgentIssueCode.collectionUnavailable) }
            pair = try collector.pair()
        } catch {
            lock.withLock {
                service = readyService
                runtimeState = "blocked"
                issueCode = AgentIssueCode.collectionUnavailable
            }
            return
        }
        do {
            if let pair { try readyService.reconcilePair(revision: pair.revision, onStartup: true) }
            if pair?.since == nil { try readyService.setSyncEnabled(false) }
        } catch {
            block(AgentIssueCode.stateUnreadable)
            return
        }
        // Keep the encrypted sync preference adjustable even if Safari access
        // is currently blocked; browser exchange still requires ready state.
        lock.withLock { service = readyService; self.history = history }
        do {
            try history.validateAccessAndSchema()
        } catch SafariHistoryError.incompatibleSchema {
            block(AgentIssueCode.runtimeUnsupported)
            return
        } catch {
            block(AgentIssueCode.safariAccessUnavailable)
            return
        }

        let timer = makeCloudTrigger(service: readyService)
        let initialHealth = try? readyService.status()
        lock.withLock {
            service = readyService
            self.history = history
            runtimeState = initialHealth?.issueCode == AgentIssueCode.stateUnreadable
                ? "blocked"
                : "ready"
            issueCode = initialHealth?.issueCode
            cloudTrigger = timer
        }
        timer.resume()
    }

    private var outdatedExtensionFamily: String?

    private struct CollectionReply: Codable {
        let extensionUpdateRequired: Bool
        let enabled: Bool
        let sources: [HistoryCollectionSource]
        let pair: HistoryCollector.Pair?
        let pendingCount: Int64
        let statuses: [HistoryCollectionStatus]
    }

    private func initializeCollector() {
        do {
            let instance = try HistoryCollector(databaseURL: runtimeDirectory.appendingPathComponent("Viewing/history.sqlite"))
            let timer = DispatchSource.makeTimerSource(queue: collectionQueue)
            timer.schedule(deadline: .now() + 1, repeating: 30, leeway: .seconds(1))
            timer.setEventHandler {
                try? instance.collectAll(onlyIfEnabled: true)
            }
            lock.withLock { collector = instance; collectionTimer = timer }
            timer.resume()
        } catch { return }
    }

    func collectionCommand(_ command: MenuCommand) throws -> Data {
        guard let collector = lock.withLock({ self.collector }) else { throw TypedError(code: "COLLECTION_UNAVAILABLE", retryable: true) }
        switch command.operation {
        case "collectionStatus": break
        case "collectionCandidates":
            return try JSONEncoder().encode(discover(collector))
        case "savePair":
            guard let partnerID = command.profileID, let expected = command.snapshotJSON,
                  (try collector.pair()?.revision ?? "") == expected,
                  ["enable", "disable"].contains(command.result ?? "") else { throw TypedError(code: "PAIR_CHANGED") }
            let candidates = try discover(collector).candidates
            guard let safari = candidates.first(where: { $0.id == "safari:default" }),
                  let partner = candidates.first(where: { $0.id == partnerID && $0.browser == .chromium }),
                  let service = lock.withLock({ self.service }) else { throw TypedError(code: "PAIR_NOT_READY") }
            if try collector.pair()?.source != partnerID {
                connectionChallenge = nil
            } else if command.result == "disable" {
                try collector.startRouting(false)
                try service.setSyncEnabled(false)
            }
            try collector.configure([safari, partner], pairEnabled: command.result == "enable", expectedRemoved: command.expectedRemoved, expectedPending: command.expectedPending, queued: service.pendingPairEvents())
            if expected != (try collector.pair()?.revision ?? ""), let pair = try collector.pair() { try service.reconcilePair(revision: pair.revision) }
        case "connectPair":
            guard let pair = try collector.pair() else { throw TypedError(code: "PAIR_NOT_READY") }
            let token = UUID().uuidString
            connectionChallenge = (token, pair.revision, Date().addingTimeInterval(120))
            return try JSONEncoder().encode(["source": pair.source, "token":token])
        case "setViewerOrigin":
            try collector.setViewerOrigin(command.snapshotJSON)
        case "collectNow":
            guard try collector.isEnabled() else { throw TypedError(code: "COLLECTION_PAUSED") }
            collectionQueue.async { try? collector.collectAll(onlyIfEnabled: true) }
            return Data("{\"accepted\":true}".utf8)
        default: throw TypedError(code: "INVALID_OPERATION")
        }
        let current = try collector.pair()
        let outdated = needsExtensionUpdate(current)
        return try JSONEncoder().encode(CollectionReply(extensionUpdateRequired: outdated, enabled: collector.isEnabled(), sources: collector.sources(), pair: collector.pair(), pendingCount: collector.candidateCount(queued: lock.withLock { self.service }?.pendingPairEvents() ?? []), statuses: collector.statuses()))
    }

    private func needsExtensionUpdate(_ pair: HistoryCollector.Pair?) -> Bool {
        guard let pair, pair.extensionID == nil, let outdatedExtensionFamily else { return false }
        return pair.source.split(separator: ":").first == Substring(outdatedExtensionFamily)
    }

    func menuStatus() -> MenuStatusSnapshot {
        let collector = lock.withLock { self.collector }
        let collection = try? collector?.overview()
        return .init(collection: collection, sync: try? health(),
                     extensionUpdateRequired: needsExtensionUpdate(collection?.pair))
    }

    private func discover(_ collector: HistoryCollector) throws -> CollectionCandidates {
            var home = FileManager.default.homeDirectoryForCurrentUser
            #if DEBUG
            // Process tests use an isolated synthetic home, never real profiles.
            let temporaryRoot = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path + "/"
            if ProcessInfo.processInfo.environment["SAFARI_SYNC_SYNTHETIC_TEST"] == "1",
               runtimeDirectory.resolvingSymlinksInPath().path.hasPrefix(temporaryRoot),
               historyURL.resolvingSymlinksInPath().path.hasPrefix(temporaryRoot) {
                home = runtimeDirectory
            }
            #endif
        return CollectionProfiles.discover(home: home, selected: try collector.sources())
    }

    func syncPreference() throws -> SyncPreferenceStatus {
        guard let service = lock.withLock({ self.service }) else { throw TypedError(code: "AGENT_INITIALIZING", retryable: true) }
        return SyncPreferenceStatus(enabled: try service.status().enabled)
    }

    func inspectSafariCursor() throws -> SafariCursorInspection? {
        guard let service = lock.withLock({ self.service }) else { throw TypedError(code: "AGENT_INITIALIZING", retryable: true) }
        return try service.inspectSafariCursor()
    }

    func setSyncEnabled(_ enabled: Bool) throws -> HealthSnapshot {
        guard let service = lock.withLock({ self.service }) else { throw TypedError(code: "AGENT_INITIALIZING", retryable: true) }
        guard let collector else { throw TypedError(code: "COLLECTION_UNAVAILABLE") }
        if enabled {
            guard let pair = try collector.pair(), let profile = pair.extensionID else { throw TypedError(code: "PAIR_NOT_CONNECTED") }
            try service.reconcilePair(revision: pair.revision)
            _ = try service.selectProfile(profile)
            if let inspection = try service.inspectSafariCursor(), !inspection.identityMatches || inspection.anchorState != "matches" {
                throw TypedError(code: "SAFARI_CURSOR_CHANGED")
            }
        }
        try collector.startRouting(enabled)
        do { try service.setSyncEnabled(enabled) } catch { try collector.startRouting(false); throw error }
        return try service.status()
    }

    func health() throws -> HealthSnapshot {
        let snapshot = lock.withLock { (service, history, runtimeState, issueCode) }
        if snapshot.2 == "blocked", let issue = snapshot.3 {
            return blockedHealth(issue: issue, service: snapshot.0)
        }
        if let service = snapshot.0, let history = snapshot.1 {
            do {
                try history.validateAccessAndSchema()
                let health = try service.status()
                if health.runtimeState == "blocked", let issue = health.issueCode {
                    block(issue)
                }
                return health
            } catch let error as SafariHistoryError {
                if error.isTransientContention { return try service.status() }
                block(issue(for: error))
                return blockedHealth(issue: issue(for: error), service: service)
            }
        }
        return HealthSnapshot(
            enabled: false,
            activeProfileID: nil,
            runtimeState: snapshot.2,
            issueCode: snapshot.3,
            agentBuild: agentBuild,
            pendingBrowserToSafari: 0,
            pendingSafariToBrowser: 0,
            recoveryCount: 0,
            unrecoverableCount: 0
        )
    }

    func browserExchange(_ body: Data) throws -> Data {
        let message = try JSONDecoder().decode(BrowserMessage.self, from: body)
        guard message.version == safariSyncProtocolVersion else { throw TypedError(code: "UNSUPPORTED_PROTOCOL") }
        guard let collector else { throw TypedError(code: "COLLECTION_UNAVAILABLE") }
        if ["pull", "publish"].contains(message.operation), message.capabilities?.contains("collected-visits-v1") != true {
            outdatedExtensionFamily = message.browserFamily ?? message.profileID.split(separator: ":").first.map(String.init)
            throw TypedError(code: "EXTENSION_UPDATE_REQUIRED")
        }
        if message.operation == "connectPair" {
            guard let challenge = connectionChallenge, challenge.expires > Date(), challenge.token == message.token,
                  let pair = try collector.pair(), pair.revision == challenge.revision,
                  let family = pair.source.split(separator: ":").first,
                  message.profileID.hasPrefix(String(family) + ":"), message.browserFamily == String(family) else { throw TypedError(code: "PAIR_CHANGED") }
            try collector.bind(profile: message.profileID, revision: pair.revision)
            if let bound = try collector.pair(), let service = lock.withLock({ self.service }) { try service.reconcilePair(revision: bound.revision) }
            connectionChallenge = nil
            return try JSONEncoder().encode(["state":"connected"])
        }
        guard let pair = try collector.pair(), pair.extensionID == message.profileID else { throw TypedError(code: "PAIR_NOT_CONNECTED") }
        if message.operation == "collectionPolicy" {
            return try JSONSerialization.data(withJSONObject: ["revision":pair.revision, "collect":try collector.isEnabled(), "sync":pair.since != nil])
        }
        if message.operation == "candidateVisits" {
            guard pair.since != nil, pair.revision == message.revision else { throw TypedError(code: "PAIR_CHANGED") }
            return try JSONEncoder().encode(collector.browserCandidates())
        }
        if message.operation == "collectRemoval", let revision = message.revision, let before = message.removedAt {
            try collector.removeReported(profile: message.profileID, revision: revision, urls: message.allHistoryRemoved == true ? nil : message.removedURLs ?? [], before: before)
            return try JSONEncoder().encode(["state":"removed"])
        }
        if message.operation == "collectVisits" {
            guard let visits = message.visits, visits.count <= 128, let revision = message.revision else { throw TypedError(code: "INVALID_PAGE") }
            try collector.collectReported(visits, profile: message.profileID, revision: revision)
            return try JSONEncoder().encode(["state":"collected"])
        }
        guard let service = lock.withLock({ runtimeState == "ready" ? service : nil }) else {
            let issue = lock.withLock { issueCode }
            return try JSONEncoder().encode(TypedError(
                code: issue ?? "AGENT_INITIALIZING",
                retryable: true
            ))
        }
        do {
            return try service.browserExchange(body)
        } catch let error as TypedError {
            return try JSONEncoder().encode(error)
        } catch let error as SafariHistoryError {
            if error.isTransientContention {
                return try JSONEncoder().encode(TypedError(code: "SAFARI_BUSY", retryable: true))
            }
            let code = issue(for: error)
            if code != "INVALID_MESSAGE" { block(code) }
            return try JSONEncoder().encode(TypedError(
                code: code,
                retryable: code == AgentIssueCode.safariAccessUnavailable
            ))
        } catch {
            block(AgentIssueCode.stateUnreadable)
            return try JSONEncoder().encode(TypedError(code: AgentIssueCode.stateUnreadable))
        }
    }

    func selectProfile(_ profileID: String) throws -> String {
        guard let service = lock.withLock({ runtimeState == "ready" ? service : nil }) else {
            throw TypedError(code: lock.withLock { issueCode } ?? "AGENT_INITIALIZING", retryable: true)
        }
        do {
            return try service.selectProfile(profileID)
        } catch let error as SafariHistoryError {
            if error.isTransientContention {
                throw TypedError(code: "SAFARI_BUSY", retryable: true)
            }
            let code = issue(for: error)
            block(code)
            throw TypedError(code: code, retryable: code == AgentIssueCode.safariAccessUnavailable)
        } catch {
            block(AgentIssueCode.stateUnreadable)
            throw TypedError(code: AgentIssueCode.stateUnreadable)
        }
    }

    func performRecovery(operation: String, role: String) throws -> RecoveryCommandStatus {
        let snapshot = lock.withLock { (service, runtimeState, issueCode) }
        guard RecoveryCommandPolicy.allows(
            role: role,
            operation: operation,
            runtimeState: snapshot.1,
            issueCode: snapshot.2
        ), let service = snapshot.0 else {
            throw TypedError(code: "RECOVERY_NOT_ALLOWED")
        }
        do {
            switch operation {
            case RecoveryCommandPolicy.resetSafariCursor:
                try service.resetSafariCursor()
            case RecoveryCommandPolicy.resetAgentState:
                try service.resetAgentState()
            default:
                throw TypedError(code: "RECOVERY_NOT_ALLOWED")
            }
            lock.withLock {
                runtimeState = "ready"
                issueCode = nil
            }
            return RecoveryCommandStatus(state: "READY", operation: operation)
        } catch let error as SafariHistoryError {
            let code = issue(for: error)
            block(code)
            throw TypedError(code: code, retryable: code == AgentIssueCode.safariAccessUnavailable)
        } catch let error as TypedError {
            throw error
        } catch {
            block(AgentIssueCode.stateUnreadable)
            throw TypedError(code: AgentIssueCode.stateUnreadable)
        }
    }

    private func block(_ issue: String) {
        lock.withLock {
            runtimeState = "blocked"
            issueCode = issue
        }
    }

    private func issue(for error: SafariHistoryError) -> String {
        AgentIssueCode.forHistoryError(error)
    }

    private func blockedHealth(issue: String, service: AgentService? = nil) -> HealthSnapshot {
        let status = try? service?.status()
        return HealthSnapshot(
            enabled: false,
            syncRequested: status?.syncRequested,
            activeProfileID: status?.activeProfileID,
            runtimeState: "blocked",
            issueCode: issue,
            agentBuild: agentBuild,
            compatibility: status?.compatibility,
            connectedProfiles: status?.connectedProfiles ?? [],
            pendingBrowserToSafari: status?.pendingBrowserToSafari ?? 0,
            pendingSafariToBrowser: status?.pendingSafariToBrowser ?? 0,
            recoveryCount: status?.recoveryCount ?? 0,
            unrecoverableCount: status?.unrecoverableCount ?? 0,
            cloud: status?.cloud
        )
    }

    func cloudCommand(_ command: MenuCommand) throws -> CloudDiagnostics {
        guard let service = lock.withLock({ runtimeState == "ready" ? service : nil }) else {
            throw TypedError(code: lock.withLock { issueCode } ?? "AGENT_INITIALIZING")
        }
        do { return try service.cloudCommand(command) }
        catch let error as SafariHistoryError {
            if !error.isTransientContention { block(issue(for: error)) }
            throw error
        }
    }

    private func makeCloudTrigger(service: AgentService) -> DispatchSourceTimer {
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + 15, repeating: 15, leeway: .seconds(1))
        timer.setEventHandler { [weak self] in
            guard let self, self.lock.withLock({ self.runtimeState == "ready" }) else { return }
            do {
                try service.pollCloud(safariIsRunning: !NSRunningApplication
                    .runningApplications(withBundleIdentifier: "com.apple.Safari").isEmpty,
                    assistSafari: SafariSyncAssistDriver.perform) {
                    // Never quit/recycle a running user-owned Safari process.
                    guard NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Safari").isEmpty else {
                        return false
                    }
                    let launch = Process()
                    launch.executableURL = URL(fileURLWithPath: "/usr/bin/open")
                    launch.arguments = ["-gj", "-a", "Safari"]
                    try launch.run()
                    let deadline = ProcessInfo.processInfo.systemUptime + 5
                    while launch.isRunning && ProcessInfo.processInfo.systemUptime < deadline {
                        Thread.sleep(forTimeInterval: 0.02)
                    }
                    if launch.isRunning { launch.terminate(); return false }
                    return launch.terminationStatus == 0
                }
            } catch let error as SafariHistoryError {
                if !error.isTransientContention { self.block(self.issue(for: error)) }
            } catch {
                self.block(AgentIssueCode.stateUnreadable)
            }
        }
        return timer
    }
}

if CommandLine.arguments.contains("--validate-safari-assist-script") {
    exit(SafariSyncAssistDriver.validate() ? 0 : 1)
}

// A Menu-owned Agent cannot outlive a quit, crash, or delayed app launch.
// Debug fixtures may omit this argument; packaged builds always require it.
let ownerIndex = CommandLine.arguments.firstIndex(of: "--menu-pid")
let ownerPID: Int32? = ownerIndex.flatMap { index in
    guard index + 1 < CommandLine.arguments.count, let value = Int32(CommandLine.arguments[index + 1]), value > 1, value != getpid() else { return nil }
    return value
}
#if !DEBUG
guard ownerPID != nil else { exit(64) }
#endif
var ownerTimer: DispatchSourceTimer?
if let ownerPID {
    guard kill(ownerPID, 0) == 0 else { exit(0) }
    let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
    timer.schedule(deadline: .now() + 1, repeating: 1)
    timer.setEventHandler { if kill(ownerPID, 0) != 0 { exit(0) } }
    timer.resume()
    ownerTimer = timer
}

let logger = Logger(subsystem: ProductIdentity.agentBundleIdentifier, category: "requests")
let environment = ProcessInfo.processInfo.environment
let home = FileManager.default.homeDirectoryForCurrentUser
let runtimeDirectory = URL(fileURLWithPath: environment["SAFARI_SYNC_STATE_DIR"] ??
    home.appendingPathComponent(
        "Library/Application Support/\(ProductIdentity.applicationSupportDirectoryName)"
    ).path)
let historyURL = URL(fileURLWithPath: environment["SAFARI_SYNC_HISTORY_PATH"] ??
    home.appendingPathComponent("Library/Safari/History.db").path)
let socketPath = environment["SAFARI_SYNC_SOCKET_PATH"] ??
    runtimeDirectory.appendingPathComponent("agent.sock").path
let ipcSecretURL = runtimeDirectory.appendingPathComponent("ipc.secret")
let agentBuild = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String

do {
    try FileManager.default.createDirectory(
        at: runtimeDirectory,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700]
    )
    let ipcSecret = try IPCSecretStore.load(from: ipcSecretURL, createIfMissing: true)
    unlink(socketPath)
    let server = socket(AF_UNIX, SOCK_STREAM, 0)
    guard server >= 0 else { throw IPCError.socket("socket") }
    defer { Darwin.close(server); unlink(socketPath) }
    var address = try unixAddress(path: socketPath)
    let bindResult = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.bind(server, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    guard bindResult == 0 else { throw IPCError.socket("bind") }
    chmod(socketPath, 0o600)
    guard listen(server, 16) == 0 else { throw IPCError.socket("listen") }

    let runtime = AgentRuntime(
        runtimeDirectory: runtimeDirectory,
        historyURL: historyURL,
        agentBuild: agentBuild
    )
    DispatchQueue.global(qos: .userInitiated).async { runtime.initialize() }

    DispatchQueue(label: "io.github.irismouth.history-sync.ipc").async {
        var seenNonces = Set<String>()
        while true {
            let client = accept(server, nil, nil)
            if client < 0 { continue }
            configureSocketTimeouts(descriptor: client)
            autoreleasepool {
                defer { Darwin.close(client) }
                do {
                    let framed = try readFrame(descriptor: client)
                    let request = try JSONDecoder().decode(AuthenticatedRequest.self, from: framed)
                    guard ["bridge", "menu"].contains(request.role),
                          !seenNonces.contains(request.nonce),
                          SharedSecret.verify(request, secret: ipcSecret) else {
                        throw IPCError.authenticationFailed
                    }
                    seenNonces.insert(request.nonce)
                    if seenNonces.count > 4_096 { seenNonces.removeAll(keepingCapacity: true) }
                    let response: Data
                    if request.role == "bridge" {
                        response = try runtime.browserExchange(request.body)
                    } else {
                        let command = try JSONDecoder().decode(MenuCommand.self, from: request.body)
                        if command.operation == "status" {
                            response = try JSONEncoder().encode(runtime.health())
                        } else if command.operation == "menuStatus" {
                            response = try JSONEncoder().encode(runtime.menuStatus())
                        } else if command.operation == "inspectSafariCursor" {
                            response = try JSONEncoder().encode(runtime.inspectSafariCursor())
                        } else if ["collectionStatus", "collectionCandidates", "savePair", "connectPair", "collectNow", "setViewerOrigin"].contains(command.operation) {
                            response = try runtime.collectionCommand(command)
                        } else if command.operation == "syncPreference" {
                            response = try JSONEncoder().encode(runtime.syncPreference())
                        } else if command.operation == "setSyncEnabled", let value = command.result, ["enable", "disable"].contains(value) {
                            response = try JSONEncoder().encode(runtime.setSyncEnabled(value == "enable"))
                        } else if [
                            "cloudStatus", "cloudProbe", "cloudObserve", "cloudPrepareReplay",
                            "cloudExecuteReplay", "cloudCompareExport", "cloudRebind", "cloudSafariAssist",
                        ].contains(command.operation) {
                            response = try JSONEncoder().encode(runtime.cloudCommand(command))
                        } else if [
                            RecoveryCommandPolicy.resetSafariCursor,
                            RecoveryCommandPolicy.resetAgentState,
                        ].contains(command.operation) {
                            response = try JSONEncoder().encode(runtime.performRecovery(
                                operation: command.operation,
                                role: request.role
                            ))
                        } else {
                            response = try JSONEncoder().encode(TypedError(code: "INVALID_OPERATION"))
                        }
                    }
                    try writeFrame(response, descriptor: client)
                } catch let error as TypedError {
                    let response = try? JSONEncoder().encode(error)
                    if let response { try? writeFrame(response, descriptor: client) }
                } catch {
                    logger.error("Request failed: \(String(describing: error), privacy: .public)")
                    let response = try? JSONEncoder().encode(TypedError(code: "AGENT_ERROR", retryable: true))
                    if let response { try? writeFrame(response, descriptor: client) }
                }
            }
        }
    }
    // Keep the main run loop free for Safari Apple events and macOS consent UI.
    NSApplication.shared.setActivationPolicy(.accessory)
    NSApplication.shared.run()
} catch {
    FileHandle.standardError.write(Data("SafariSyncAgent: \(error)\n".utf8))
    exit(70)
}
