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
        let chromium = try HistoryFixture()
        try chromium.exec("CREATE TABLE urls(id INTEGER PRIMARY KEY,url TEXT,title TEXT); CREATE TABLE visits(id INTEGER PRIMARY KEY,url INTEGER,visit_time INTEGER)")
        try FileManager.default.createSymbolicLink(at: chrome.appendingPathComponent("Default/History"), withDestinationURL: chromium.url)
        let safari = directory.appendingPathComponent("Library/Safari")
        try FileManager.default.createDirectory(at: safari, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: safari.appendingPathComponent("History.db"), withDestinationURL: fixture.url)
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
        func object(_ data: Data) throws -> [String: Any] {
            try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        }
        func browser(_ operation: String, _ fields: [String: Any] = [:]) throws -> Data {
            var payload: [String: Any] = ["version": 1, "operation": operation, "profileId": "chrome:fixture", "browserFamily": "chrome", "capabilities": ["collected-visits-v1","cloud-delivery-v1"]]
            payload.merge(fields) { _, new in new }
            return try browserRequest(JSONSerialization.data(withJSONObject: payload))
        }
        let paused = try JSONDecoder().decode(TypedError.self, from: command(MenuCommand(operation: "collectNow")))
        try expect(paused.code, "COLLECTION_PAUSED", "manual collection requires collection to be enabled")
        var revision: String?
        for _ in 0..<100 {
            let result = try object(command(MenuCommand(operation: "savePair", profileID: "chrome:Default", result: "enable", snapshotJSON: "")))
            revision = (result["pair"] as? [String: Any])?["revision"] as? String
            if revision != nil { break }
            usleep(100_000)
        }
        guard let revision else { throw IntegrationFailure.assertion("isolated pair not configured") }
        let challenge = try object(command(MenuCommand(operation: "connectPair")))
        let bound = try object(browser("connectPair", ["token":challenge["token"] as? String ?? ""]))
        try expect(bound["state"] as? String, "connected", "selected extension binds to the pair")
        _ = try command(MenuCommand(operation: "collectNow"))
        var complete = false
        for _ in 0..<100 {
            let rows = try object(command(MenuCommand(operation: "collectionStatus")))["statuses"] as? [[String: Any]] ?? []
            if rows.count == 2 && rows.allSatisfy({ $0["state"] as? String == "complete" }) { complete = true; break }
            usleep(100_000)
        }
        guard complete else { throw IntegrationFailure.assertion("isolated pair did not finish collection") }
        // Already on disk when sync starts, but not yet collected. A future timestamp
        // alone must never qualify a pre-existing visit for delivery.
        try chromium.exec("INSERT INTO urls VALUES(7,'https://synthetic-before-enable.example/','Older'); INSERT INTO visits VALUES(7,7,14500000000000000)")
        let enabled = try object(command(MenuCommand(operation: "setSyncEnabled", result: "enable")))
        try expect(enabled["enabled"] as? Bool, true, "explicit opt-in after both baselines")
        let cursorInspection = try JSONDecoder().decode(SafariCursorInspection.self, from: command(MenuCommand(operation: "inspectSafariCursor")))
        try expect(cursorInspection.identityMatches, true, "Agent exposes read-only cursor evidence")
        let fields: [String:Any] = ["revision":revision, "stream":"safariToBrowser"]
        try expect(try object(browser("pull", fields))["events"] as? [[String:String]] != nil, true, "initial import has no deliveries")
        try fixture.insertSafariVisit(url: "https://synthetic-new.example/")
        let now = Date().timeIntervalSince1970
        try fixture.exec("UPDATE history_visits SET visit_time=\(now-978307200) WHERE id=(SELECT max(id) FROM history_visits)")
        try chromium.exec("INSERT INTO urls VALUES(1,'https://synthetic-other.example/','Fixture'); INSERT INTO visits VALUES(8,1,\(Int64((now+11644473600)*1000000)))")
        _ = try command(MenuCommand(operation: "collectNow"))
        var candidate: String?
        for _ in 0..<100 {
            let data = try browser("candidateVisits", ["revision":revision])
            candidate = ((try JSONSerialization.jsonObject(with: data)) as? [[String:Any]])?.first?["event"] as? String
            if candidate != nil { break }
            usleep(100_000)
        }
        let checked = try JSONSerialization.jsonObject(with: browser("candidateVisits", ["revision":revision])) as? [[String:Any]]
        try expect(checked?.map { $0["nativeID"] as? String }, ["8"], "native baseline excludes not-yet-collected pre-enable records")
        guard let candidate else { throw IntegrationFailure.assertion("no collected Chromium visit") }
        var confirmed = fields
        confirmed["confirmed"] = [candidate]
        let page = try object(browser("pull", confirmed))
        try expect((page["events"] as? [[String: Any]])?.first?["url"] as? String, "https://synthetic-new.example/", "only newly collected Safari visit delivered")
        try expect(try fixture.scalarInt("SELECT count(*) FROM history_items WHERE url='https://synthetic-other.example/'"), 1, "confirmed Chromium candidate delivered to Safari")
        let fastTime = Date().timeIntervalSince1970 * 1000
        let fastURL = "https://synthetic-fast.example/"
        let report: [String:Any] = ["revision":revision, "visits":[["visitId":"9", "visitTime":fastTime, "url":fastURL]]]
        for _ in 0..<2 {
            try expect(try object(browser("collectVisits", report))["state"] as? String, "collected", "extension notification can be retried")
        }
        let fast = try JSONSerialization.jsonObject(with: browser("candidateVisits", ["revision":revision])) as? [[String:Any]]
        try expect(fast?.count, 1, "duplicate notifications create one candidate")
        try expect(fast?.first?["nativeID"] as? String, "9", "extension input is committed before delivery")
        let removed = try object(browser("collectRemoval", ["revision":revision,"removedURLs":[fastURL],"removedAt":fastTime+1]))
        try expect(removed["state"] as? String, "removed", "source deletion cancels an undelivered notification")
        try fixture.exec("DELETE FROM history_visits WHERE history_item=(SELECT id FROM history_items WHERE url='https://synthetic-new.example/')")
        let afterDeletion = try object(browser("pull", fields))
        try expect((afterDeletion["events"] as? [[String:Any]])?.count, 0, "Safari deletion before ACK cancels the pending delivery")
        try expect(try fixture.scalarInt("SELECT count(*) FROM history_items WHERE url='https://synthetic-fast.example/'"), 0, "deleted Chromium visit stays undelivered")
        try stop(process)
        let replacement = try HistoryFixture()
        try replacement.insertSafariVisit(url: "https://synthetic-agent.example/")
        process = try start(historyPath: replacement.url.path)
        try waitForCollection()
        let blockedInspection = try JSONDecoder().decode(SafariCursorInspection.self, from: command(MenuCommand(operation: "inspectSafariCursor")))
        try expect(blockedInspection.identityMatches, false, "blocked Agent reports replaced identity")
        try expect(blockedInspection.anchorState, "matches", "Agent preserves the old anchor")
        try stop(process)
        process = try start()
        try waitForCollection()
        let data = try command(MenuCommand(operation: "collectionStatus"))
        let status = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        try expect(status["enabled"] as? Bool, true, "collection setting survives Agent restart")
        let sources = status["statuses"] as? [[String: Any]] ?? []
        try expect(sources.first(where: { $0["id"] as? String == "safari:default" })?["count"] as? Int ?? 0 >= 2, true, "collection survives Agent restart")
        // Interrupt a later complete-source scan. Previously committed data must
        // remain available until the restarted Agent finishes reconciliation.
        try fixture.exec("DELETE FROM history_visits; WITH RECURSIVE n(x) AS (SELECT 1 UNION ALL SELECT x+1 FROM n WHERE x<100000) INSERT INTO history_visits(history_item,visit_time) SELECT 1,100000000+x FROM n")
        _ = try command(MenuCommand(operation: "collectNow"))
        var observedScan = false
        for _ in 0..<100 {
            if let data = try? command(MenuCommand(operation: "collectionStatus")),
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let rows = object["statuses"] as? [[String: Any]], rows.first(where: { $0["id"] as? String == "safari:default" })?["state"] as? String == "collecting" {
                observedScan = true; break
            }
            usleep(20_000)
        }
        guard observedScan else { throw IntegrationFailure.assertion("could not observe a running collection") }
        try stop(process)
        do {
            let saved = try HistoryCollector(databaseURL: directory.appendingPathComponent("Viewing/history.sqlite"))
            try expect(try saved.statuses().first(where: { $0.id == "safari:default" })!.count >= 2, true, "interrupted reconciliation retains last successful data")
        }
        process = try start()
        try waitForCollection()
        var recovered = false
        for _ in 0..<300 {
            if let data = try? command(MenuCommand(operation: "collectionStatus")),
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let rows = object["statuses"] as? [[String: Any]], rows.first(where: { $0["id"] as? String == "safari:default" })?["state"] as? String == "complete",
               rows.first(where: { $0["id"] as? String == "safari:default" })?["count"] as? Int == 100000 { recovered = true; break }
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
               let value = try? JSONDecoder().decode(SyncPreferenceStatus.self, from: data), !value.enabled {
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
        try FileManager.default.createDirectory(at: chrome.appendingPathComponent("Profile 1"), withIntermediateDirectories: true)
        let outdated = try object(command(MenuCommand(operation: "savePair", profileID: "chrome:Profile 1", result: "disable", snapshotJSON: revision)))
        try expect(outdated["code"] as? String, "PAIR_CHANGED", "generation replacement invalidates stale settings")
        let current = try object(command(MenuCommand(operation: "collectionStatus")))["pair"] as? [String:Any]
        let switched = try object(command(MenuCommand(operation: "savePair", profileID: "chrome:Profile 1", result: "disable", snapshotJSON: current?["revision"] as? String, expectedRemoved: 2, expectedPending: 0)))
        let switchedRows = switched["statuses"] as? [[String:Any]]
        try expect(switchedRows?.contains { $0["id"] as? String == "chrome:Default" }, false, "previous profile removed from viewing DB")
        try expect(switchedRows?.first(where: { $0["id"] as? String == "safari:default" })?["count"] as? Int, 100000, "switch preserves Safari rows")
        try expect(try object(browser("pull", fields))["code"] as? String, "PAIR_NOT_CONNECTED", "old extension cannot fetch retained or new deliveries")
        try expect(try chromium.scalarInt("SELECT count(*) FROM visits"), 2, "switch preserves native Chromium history")
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
