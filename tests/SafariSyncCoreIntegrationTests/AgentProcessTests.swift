import Darwin
import Foundation
import SafariSyncCore

/// Opt-in: run only after confirming the installed Agent is stopped.
enum AgentProcessTests {
    static func run(agentPath: String) throws {
        let fixture = try HistoryFixture()
        try fixture.insertSafariVisit(url: "https://synthetic-agent.example/")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("agent-lifetime-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        // The debug Agent treats its isolated runtime directory as the home
        // directory for discovery; it must not read real browser profiles.
        let chrome = directory.appendingPathComponent("Library/Application Support/Google/Chrome")
        try FileManager.default.createDirectory(at: chrome.appendingPathComponent("Default"), withIntermediateDirectories: true)
        try Data(#"{"profile":{"info_cache":{"Default":{"name":"Synthetic profile"}}}}"#.utf8)
            .write(to: chrome.appendingPathComponent("Local State"))
        // Darwin UNIX-domain socket paths are much shorter than TMPDIR paths.
        let socket = "/tmp/sas-test-\(UUID().uuidString.prefix(12)).sock"
        defer { unlink(socket) }
        func start(owner: Int32? = nil, historyPath: String? = nil) throws -> Process {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: agentPath)
            if let owner { process.arguments = ["--menu-pid", "\(owner)"] }
            var env = ProcessInfo.processInfo.environment
            env["SAFARI_SYNC_STATE_DIR"] = directory.path
            env["SAFARI_SYNC_HISTORY_PATH"] = historyPath ?? fixture.url.path
            env["SAFARI_SYNC_SOCKET_PATH"] = socket
            env["SAFARI_SYNC_SYNTHETIC_TEST"] = "1"
            process.environment = env
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            return process
        }
        func stop(_ process: Process) throws {
            if process.isRunning { process.terminate() }
            for _ in 0..<50 where process.isRunning { usleep(100_000) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL); throw IntegrationFailure.assertion("Agent did not exit") }
        }
        func command(_ value: MenuCommand) throws -> Data {
            let secret = try IPCSecretStore.load(from: directory.appendingPathComponent("ipc.secret"), createIfMissing: false)
            let body = try JSONEncoder().encode(value)
            let envelope = SharedSecret.authenticate(body: body, role: "menu", secret: secret)
            return try LocalIPCClient(socketPath: socket).request(JSONEncoder().encode(envelope))
        }
        func browserRequest(_ body: Data) throws -> Data {
            let secret = try IPCSecretStore.load(from: directory.appendingPathComponent("ipc.secret"), createIfMissing: false)
            let envelope = SharedSecret.authenticate(body: body, role: "bridge", secret: secret)
            return try LocalIPCClient(socketPath: socket).request(JSONEncoder().encode(envelope))
        }
        func waitForCollection() throws {
            for _ in 0..<100 {
                if let data = try? command(MenuCommand(operation: "collectionStatus")),
                   let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   object["enabled"] != nil { return }
                usleep(100_000)
            }
            throw IntegrationFailure.assertion("isolated Agent collection did not become ready")
        }
        var process = try start()
        defer { if process.isRunning { process.terminate() } }
        try waitForCollection()
        let candidateData = try command(MenuCommand(operation: "collectionCandidates"))
        let candidateReply = try JSONSerialization.jsonObject(with: candidateData) as? [String: Any]
        let candidates = candidateReply?["candidates"] as? [[String: Any]] ?? []
        try expect(candidates.contains { $0["id"] as? String == "chrome:Default" && $0["profileName"] as? String == "Synthetic profile" }, true,
            "Agent discovers profiles using its own browser access")
        try expect(candidates.contains { $0["id"] as? String == "safari:default" }, true,
            "Agent exposes the standard Safari source")
        var selected = false
        for _ in 0..<100 {
            if let reply = try? command(MenuCommand(operation: "selectProfile", profileID: "edge:fixture")),
               let status = try? JSONDecoder().decode(ProfileSwitchStatus.self, from: reply), status.state == "ACTIVE" {
                selected = true; break
            }
            usleep(100_000)
        }
        guard selected else { throw IntegrationFailure.assertion("isolated Agent sync did not become ready") }
        let cursorData = try command(MenuCommand(operation: "inspectSafariCursor"))
        let cursorInspection = try JSONDecoder().decode(SafariCursorInspection.self, from: cursorData)
        try expect(cursorInspection.identityMatches, true, "Agent exposes read-only cursor evidence")
        try expect(cursorInspection.anchorState, "matches", "Agent confirms the synthetic anchor")
        try stop(process)
        let replacement = try HistoryFixture()
        try replacement.insertSafariVisit(url: "https://synthetic-agent.example/")
        process = try start(historyPath: replacement.url.path)
        try waitForCollection()
        let pull = Data(#"{"version":1,"operation":"pull","stream":"safariToBrowser","profileId":"edge:fixture"}"#.utf8)
        var blocked = false
        for _ in 0..<100 {
            if let data = try? browserRequest(pull), let failure = try? JSONDecoder().decode(TypedError.self, from: data),
               failure.code == AgentIssueCode.historyIdentityChanged { blocked = true; break }
            usleep(100_000)
        }
        guard blocked else { throw IntegrationFailure.assertion("replaced synthetic Safari source did not block sync") }
        let blockedInspection = try JSONDecoder().decode(SafariCursorInspection.self, from: command(MenuCommand(operation: "inspectSafariCursor")))
        try expect(blockedInspection.identityMatches, false, "blocked Agent reports replaced identity")
        try expect(blockedInspection.anchorState, "matches", "blocked Agent can inspect the old anchor without resetting it")
        try stop(process)
        process = try start()
        try waitForCollection()
        let source = HistoryCollectionSource(id: "fixture", browser: .safari, browserType: "Safari", profileName: "Default", path: fixture.url.path)
        let json = String(decoding: try JSONEncoder().encode([source]), as: UTF8.self)
        let configured = try command(MenuCommand(operation: "setCollectionSources", snapshotJSON: json))
        guard let response = try JSONSerialization.jsonObject(with: configured) as? [String: Any], response["enabled"] != nil else { throw IntegrationFailure.assertion("collection configuration failed") }
        _ = try command(MenuCommand(operation: "setCollectionEnabled", result: "enable"))
        _ = try command(MenuCommand(operation: "collectNow"))
        var complete = false
        for _ in 0..<100 {
            if let data = try? command(MenuCommand(operation: "collectionStatus")),
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let statuses = object["statuses"] as? [[String: Any]], statuses.first?["state"] as? String == "complete" {
                complete = true; break
            }
            usleep(100_000)
        }
        guard complete else { throw IntegrationFailure.assertion("isolated Agent did not finish collection") }
        try stop(process)
        process = try start()
        try waitForCollection()
        let data = try command(MenuCommand(operation: "collectionStatus"))
        let status = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        try expect(status["enabled"] as? Bool, true, "collection setting survives Agent restart")
        let sources = status["statuses"] as? [[String: Any]] ?? []
        try expect(sources.first?["count"] as? Int, 1, "collection survives Agent restart")
        // Interrupt a later complete-source scan. Previously committed data must
        // remain available until the restarted Agent finishes reconciliation.
        try fixture.exec("DELETE FROM history_visits; WITH RECURSIVE n(x) AS (SELECT 1 UNION ALL SELECT x+1 FROM n WHERE x<100000) INSERT INTO history_visits(history_item,visit_time) SELECT 1,100000000+x FROM n")
        _ = try command(MenuCommand(operation: "collectNow"))
        var observedScan = false
        for _ in 0..<100 {
            if let data = try? command(MenuCommand(operation: "collectionStatus")),
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let rows = object["statuses"] as? [[String: Any]], rows.first?["state"] as? String == "collecting" {
                observedScan = true; break
            }
            usleep(20_000)
        }
        guard observedScan else { throw IntegrationFailure.assertion("could not observe a running collection") }
        try stop(process)
        do {
            let saved = try HistoryCollector(databaseURL: directory.appendingPathComponent("Viewing/history.sqlite"))
            try expect(try saved.statuses().first?.count, 1, "interrupted reconciliation retains last successful data")
        }
        process = try start()
        try waitForCollection()
        var recovered = false
        for _ in 0..<300 {
            if let data = try? command(MenuCommand(operation: "collectionStatus")),
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let rows = object["statuses"] as? [[String: Any]], rows.first?["state"] as? String == "complete",
               rows.first?["count"] as? Int == 100000 { recovered = true; break }
            usleep(100_000)
        }
        guard recovered else { throw IntegrationFailure.assertion("interrupted collection did not recover") }
        try stop(process)
        let parent = Process(); parent.executableURL = URL(fileURLWithPath: "/bin/sleep"); parent.arguments = ["30"]
        try parent.run()
        defer { if parent.isRunning { parent.terminate() } }
        process = try start(owner: parent.processIdentifier)
        try waitForCollection()
        parent.terminate(); parent.waitUntilExit()
        for _ in 0..<50 where process.isRunning { usleep(100_000) }
        guard !process.isRunning else { throw IntegrationFailure.assertion("Agent outlived its Menu owner") }
        process = try start(historyPath: directory.appendingPathComponent("missing-history.sqlite").path)
        try waitForCollection()
        var preferenceAvailable = false
        for _ in 0..<100 {
            if let data = try? command(MenuCommand(operation: "syncPreference")),
               let value = try? JSONDecoder().decode(SyncPreferenceStatus.self, from: data), value.enabled {
                preferenceAvailable = true; break
            }
            usleep(100_000)
        }
        guard preferenceAvailable else { throw IntegrationFailure.assertion("sync preference unavailable during blocked Safari access") }
        _ = try command(MenuCommand(operation: "setSyncEnabled", result: "disable"))
        try stop(process)
        process = try start()
        try waitForCollection()
        let preferenceData = try command(MenuCommand(operation: "syncPreference"))
        try expect(try JSONDecoder().decode(SyncPreferenceStatus.self, from: preferenceData).enabled, false, "blocked sync preference persists")
        try stop(process)
        if let viewer = ProcessInfo.processInfo.environment["HISTORY_TEST_VIEWER"] {
            try viewerExitsWhenOwnerClosesPipe(viewer, directory: directory)
        }
        print("PASS: isolated Agent and Viewer recover and exit with their owner")
    }
    static func viewerExitsWhenOwnerClosesPipe(_ path: String, directory: URL) throws {
        let socketFD = socket(AF_INET, SOCK_STREAM, 0)
        guard socketFD >= 0 else { throw IntegrationFailure.assertion("viewer test socket") }
        var address = sockaddr_in(); address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET); address.sin_addr = in_addr(s_addr: in_addr_t(0x7f000001).bigEndian)
        let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(socketFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        guard bound == 0, withUnsafeMutablePointer(to: &address, { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(socketFD, $0, &length) } }) == 0 else { Darwin.close(socketFD); throw IntegrationFailure.assertion("viewer test bind") }
        let port = UInt16(bigEndian: address.sin_port); Darwin.close(socketFD)
        let process = Process(); process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["--database", directory.appendingPathComponent("Viewing/history.sqlite").path,
            "--assets", directory.path, "--owner", "owner@example.test", "--port", "\(port)", "--owned-stdin"]
        let lifetime = Pipe(); process.standardInput = lifetime
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run(); defer { if process.isRunning { process.terminate() } }
        try lifetime.fileHandleForReading.close()
        usleep(300_000)
        guard process.isRunning else { throw IntegrationFailure.assertion("viewer failed to start") }
        try lifetime.fileHandleForWriting.close()
        for _ in 0..<50 where process.isRunning { usleep(100_000) }
        guard !process.isRunning else { throw IntegrationFailure.assertion("viewer outlived its Menu owner") }
    }
}
