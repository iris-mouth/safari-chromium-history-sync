import Darwin
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

    init(runtimeDirectory: URL, historyURL: URL, agentBuild: String?) {
        self.runtimeDirectory = runtimeDirectory
        self.historyURL = historyURL
        self.agentBuild = agentBuild
    }

    func initialize() {
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
        do {
            stateSecret = try KeychainRootSecret.load(createIfMissing: true)
        } catch {
            block(AgentIssueCode.keychainUnavailable)
            return
        }

        let history = SafariHistoryStore(
            databaseURL: historyURL,
            ledgerURL: runtimeDirectory.appendingPathComponent("delivery-ledger.sqlite"),
            schema: .historyV1
        )
        do {
            try history.validateAccessAndSchema()
        } catch SafariHistoryError.incompatibleSchema {
            block(AgentIssueCode.runtimeUnsupported)
            return
        } catch {
            block(AgentIssueCode.safariAccessUnavailable)
            return
        }

        let readyService = AgentService(
            history: history,
            stateURL: runtimeDirectory.appendingPathComponent("state.sealed"),
            secret: stateSecret,
            agentBuild: agentBuild,
            compatibility: compatibility
        )
        let timer = makeCloudTrigger(history: history)
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
                return blockedHealth(issue: issue(for: error))
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
        guard let service = lock.withLock({ runtimeState == "ready" ? service : nil }) else {
            let issue = lock.withLock { issueCode }
            return try JSONEncoder().encode(TypedError(
                code: issue ?? "AGENT_INITIALIZING",
                retryable: true
            ))
        }
        do {
            return try service.browserExchange(body)
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
            activeProfileID: status?.activeProfileID,
            runtimeState: "blocked",
            issueCode: issue,
            agentBuild: agentBuild,
            compatibility: status?.compatibility,
            connectedProfiles: status?.connectedProfiles ?? [],
            pendingBrowserToSafari: status?.pendingBrowserToSafari ?? 0,
            pendingSafariToBrowser: status?.pendingSafariToBrowser ?? 0,
            recoveryCount: status?.recoveryCount ?? 0,
            unrecoverableCount: status?.unrecoverableCount ?? 0
        )
    }

    private func makeCloudTrigger(history: SafariHistoryStore) -> DispatchSourceTimer {
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        let now = Date().timeIntervalSince1970
        let nextBoundary = (floor(now / 300) + 1) * 300
        timer.schedule(deadline: .now() + (nextBoundary - now), repeating: 300)
        timer.setEventHandler {
            guard (try? history.needsCloudTrigger()) == true else { return }
            let check = Process()
            check.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
            check.arguments = ["-x", "Safari"]
            try? check.run()
            check.waitUntilExit()
            guard check.terminationStatus != 0 else { return }
            let launch = Process()
            launch.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            launch.arguments = ["-gj", "-a", "Safari"]
            try? launch.run()
        }
        return timer
    }
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
                    } else if command.operation == "selectProfile", let profileID = command.profileID {
                        response = try JSONEncoder().encode(ProfileSwitchStatus(
                            state: runtime.selectProfile(profileID),
                            profileID: profileID
                        ))
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
} catch {
    FileHandle.standardError.write(Data("SafariSyncAgent: \(error)\n".utf8))
    exit(70)
}
