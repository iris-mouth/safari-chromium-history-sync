import Darwin
import Foundation
import os
import SafariSyncCore

let logger = Logger(subsystem: "com.local.safari-history-sync.agent", category: "requests")

let environment = ProcessInfo.processInfo.environment
let home = FileManager.default.homeDirectoryForCurrentUser
let runtimeDirectory = URL(fileURLWithPath: environment["SAFARI_SYNC_STATE_DIR"] ??
    home.appendingPathComponent("Library/Application Support/Safari History Sync").path)
let historyURL = URL(fileURLWithPath: environment["SAFARI_SYNC_HISTORY_PATH"] ??
    home.appendingPathComponent("Library/Safari/History.db").path)
let socketPath = environment["SAFARI_SYNC_SOCKET_PATH"] ??
    runtimeDirectory.appendingPathComponent("agent.sock").path
let ipcSecretURL = runtimeDirectory.appendingPathComponent("ipc.secret")

do {
    _ = try CompatibilityGate.verify()
    try FileManager.default.createDirectory(
        at: runtimeDirectory,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700]
    )
    let stateSecret = try KeychainRootSecret.load(createIfMissing: true)
    let ipcSecret = try IPCSecretStore.load(from: ipcSecretURL, createIfMissing: true)
    let history = SafariHistoryStore(
        databaseURL: historyURL,
        ledgerURL: runtimeDirectory.appendingPathComponent("delivery-ledger.sqlite")
    )
    let service = AgentService(
        history: history,
        stateURL: runtimeDirectory.appendingPathComponent("state.sealed"),
        secret: stateSecret
    )

    let cloudTrigger = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
    let now = Date().timeIntervalSince1970
    let nextBoundary = (floor(now / 300) + 1) * 300
    cloudTrigger.schedule(deadline: .now() + (nextBoundary - now), repeating: 300)
    cloudTrigger.setEventHandler {
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
    cloudTrigger.resume()

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

    var seenNonces = Set<String>()
    while true {
        let client = accept(server, nil, nil)
        if client < 0 { continue }
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
                    response = try service.browserExchange(request.body)
                } else {
                    let command = try JSONDecoder().decode(MenuCommand.self, from: request.body)
                    if command.operation == "status" {
                        response = try JSONEncoder().encode(service.status())
                    } else if command.operation == "selectProfile", let profileID = command.profileID {
                        response = try JSONEncoder().encode(ProfileSwitchStatus(
                            state: service.selectProfile(profileID),
                            profileID: profileID
                        ))
                    } else {
                        response = try JSONEncoder().encode(TypedError(code: "INVALID_OPERATION"))
                    }
                }
                try writeFrame(response, descriptor: client)
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
