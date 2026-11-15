import CSQLite
import Darwin
import Foundation
import SafariSyncCore

enum HistorySourceSnapshotTests {
    static func run() throws {
        let fixture = try HistoryFixture()
        try fixture.insertSafariVisit(url: "https://example.org/repeated")
        try fixture.exec("INSERT INTO history_visits(history_item, visit_time, title) VALUES (1, 899999999.125, NULL)")
        let safari = try HistorySourceReader.read(path: fixture.url.path, browser: .safari)
        try expect(safari.visits.count, 2, "same URL has separate visits")
        try expect(safari.visits[1].nativeTime, .safari(899999999.125), "Safari fractional time preserved")
        try expect(safari.visits[1].title, nil, "missing title preserved")
        try expect(try fixture.scalarInt("SELECT COUNT(*) FROM history_visits"), 2, "source unchanged")

        try fixture.exec("CREATE TABLE urls (id INTEGER PRIMARY KEY, url TEXT, title TEXT); CREATE TABLE visits (id INTEGER PRIMARY KEY, url INTEGER, visit_time INTEGER)")
        try fixture.exec("INSERT INTO urls VALUES (1, 'https://example.org/', 'Title'), (2, 'chrome://settings', 'Settings'); INSERT INTO visits VALUES (4, 1, 13300000000000001), (5, 2, 13300000000000002)")
        let chromium = try HistorySourceReader.read(path: fixture.url.path, browser: .chromium)
        try expect(chromium.visits.count, 1, "only web visits collected")
        try expect(chromium.visits[0].nativeTime, .chromium(13300000000000001), "Chromium microseconds preserved")
        try fixture.exec("DROP TABLE visits")
        do {
            _ = try HistorySourceReader.read(path: fixture.url.path, browser: .chromium)
            throw IntegrationFailure.assertion("failed read must not return an empty snapshot")
        } catch is HistorySourceReadError { }
        try readsClosedWALWithoutSourceWrites()
        try excludesOnlyDedicatedProductURLs()
        try readsAnExclusivelyLockedChromiumSource()
    }

    static func runExclusiveWriter(path: String) throws {
        var db: OpaquePointer?
        guard sqlite3_open(path, &db) == SQLITE_OK, let db else { throw IntegrationFailure.assertion("open exclusive fixture") }
        defer { sqlite3_close(db) }
        func execute(_ sql: String) throws {
            guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw IntegrationFailure.assertion("exclusive fixture SQL") }
        }
        func reply() { FileHandle.standardOutput.write(Data("ready\n".utf8)) }
        try execute("""
          PRAGMA locking_mode=EXCLUSIVE; PRAGMA journal_mode=PERSIST; PRAGMA cache_size=10;
          CREATE TABLE urls(id INTEGER PRIMARY KEY,url TEXT,title TEXT);
          CREATE TABLE visits(id INTEGER PRIMARY KEY,url INTEGER,visit_time INTEGER);
          CREATE TABLE padding(id INTEGER PRIMARY KEY,data BLOB);
          WITH RECURSIVE n(x) AS (SELECT 1 UNION ALL SELECT x+1 FROM n WHERE x<400)
            INSERT INTO padding SELECT x,zeroblob(3000) FROM n;
          INSERT INTO urls VALUES(1,'https://exclusive.example/one','One'),(2,'https://exclusive.example/two','Two');
          INSERT INTO visits VALUES(1,1,13300000000000001);
          """)
        reply()
        while let line = readLine() {
            switch line {
            case "add": try execute("INSERT INTO visits VALUES(2,2,13300000000000002)")
            case "delete": try execute("DELETE FROM visits WHERE id=1")
            case "invalid-bulk":
                try execute("WITH RECURSIVE n(x) AS (SELECT 2 UNION ALL SELECT x+1 FROM n WHERE x<501) INSERT INTO visits SELECT x,1,13300000000000000+x FROM n; INSERT INTO visits VALUES(502,1,'invalid')")
            case "remove-bulk": try execute("DELETE FROM visits WHERE id>1")
            case "begin": try execute("BEGIN IMMEDIATE; DELETE FROM visits WHERE id=2")
            case "spill":
                try execute("BEGIN IMMEDIATE; DELETE FROM visits WHERE id=2; UPDATE padding SET data=randomblob(3000)")
                guard sqlite3_db_cacheflush(db) == SQLITE_OK else { throw IntegrationFailure.assertion("flush exclusive fixture") }
            case "rollback": try execute("ROLLBACK")
            case "nosync": try execute("PRAGMA synchronous=OFF")
            case "sync": try execute("PRAGMA synchronous=FULL")
            case "churn":
                for index in 0..<3_000 {
                    try execute("BEGIN IMMEDIATE; DELETE FROM visits; INSERT INTO visits VALUES(\(index % 2 + 1),\(index % 2 + 1),13300000000000001); COMMIT")
                    usleep(1_000)
                }
            case "wal": try execute("PRAGMA journal_mode=WAL; INSERT OR REPLACE INTO visits VALUES(3,1,13300000000000003)")
            case "quit": return
            default: throw IntegrationFailure.assertion("unknown exclusive fixture command")
            }
            reply()
        }
    }

    static func readsAnExclusivelyLockedChromiumSource() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("exclusive-source-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("History").path
        let writer = Process(); writer.executableURL = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
        writer.arguments = ["--exclusive-history-fixture", path]
        let input = Pipe(), output = Pipe()
        writer.standardInput = input; writer.standardOutput = output; writer.standardError = FileHandle.nullDevice
        try writer.run()
        defer { if writer.isRunning { writer.terminate() } }
        func waitReady() throws {
            var bytes = Data()
            while bytes.last != 10 {
                guard let part = try output.fileHandleForReading.read(upToCount: 1), !part.isEmpty else { throw IntegrationFailure.assertion("exclusive writer exited") }
                bytes.append(part)
            }
            try expect(String(decoding: bytes, as: UTF8.self), "ready\n", "exclusive writer response")
        }
        func command(_ value: String) throws {
            try input.fileHandleForWriting.write(contentsOf: Data("\(value)\n".utf8)); try waitReady()
        }
        try waitReady()
        let destination = directory.appendingPathComponent("view.sqlite")
        let collector = try HistoryCollector(databaseURL: destination)
        try collector.configure([.init(id: "edge", browser: .chromium, browserType: "Edge", profileName: "fixture", path: path)])
        try command("add")
        try command("spill")
        try collector.collectAll()
        try expect(try collector.statuses().first?.state, "waiting", "exclusive source waits for committed read")
        try expect(try collector.statuses().first?.count, 0, "uncommitted source is never published")
        try command("rollback")
        try input.fileHandleForWriting.write(contentsOf: Data("quit\n".utf8))
        writer.waitUntilExit()
        try collector.collectAll()
        try expect(try collector.statuses().first?.count, 2, "unlock publishes committed visits after rollback")
    }

    static func excludesOnlyDedicatedProductURLs() throws {
        let fixture = try HistoryFixture()
        try fixture.insertSafariVisit(url: "https://example.com/ordinary")
        try fixture.insertSafariVisit(url: "https://example.com/safari-history-sync-probe/550e8400-e29b-41d4-a716-446655440000")
        try fixture.insertSafariVisit(url: "https://example.com/?safari-sync-control=550e8400-e29b-41d4-a716-446655440000")
        try fixture.insertSafariVisit(url: "https://private.example.test:8443/?start=2026-11-10")
        try fixture.insertSafariVisit(url: "https://private.example.test:443/?start=2026-11-10")
        try fixture.insertSafariVisit(url: "https://private.example.test:8443/ordinary")
        var urls: [String] = []
        _ = try HistorySourceReader.scan(path: fixture.url.path, browser: .safari,
            viewerOrigins: [URL(string: "https://private.example.test:8443/")!, URL(string: "https://private.example.test/")!],
            onStart: { _, _ in }, onBatch: { urls += $0.map(\.url) })
        try expect(Set(urls), Set(["https://example.com/ordinary", "https://private.example.test:8443/ordinary"]), "fixed exclusions preserve ordinary pages")
    }

    static func readsClosedWALWithoutSourceWrites() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("source-readonly-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { chmod(directory.path, 0o700); try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("History.db").path
        var db: OpaquePointer?
        guard sqlite3_open(path, &db) == SQLITE_OK, let db else { throw IntegrationFailure.assertion("source WAL fixture") }
        let sql = "PRAGMA journal_mode=WAL; CREATE TABLE history_items(id INTEGER PRIMARY KEY,url TEXT); CREATE TABLE history_visits(id INTEGER PRIMARY KEY,history_item INTEGER,visit_time REAL,title TEXT); INSERT INTO history_items VALUES(1,'https://closed.example/'); INSERT INTO history_visits VALUES(1,1,12345.5,NULL)"
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK,
              sqlite3_exec(db, "PRAGMA wal_checkpoint(TRUNCATE)", nil, nil, nil) == SQLITE_OK,
              sqlite3_close(db) == SQLITE_OK else { throw IntegrationFailure.assertion("source WAL fixture SQL") }
        try? FileManager.default.removeItem(atPath: path + "-wal")
        try? FileManager.default.removeItem(atPath: path + "-shm")
        guard chmod(directory.path, 0o500) == 0 else { throw IntegrationFailure.assertion("source directory permissions") }
        var count = 0
        _ = try HistorySourceReader.scan(path: path, browser: .safari, onStart: { _, _ in }, onBatch: { count += $0.count })
        try expect(count, 1, "closed WAL source remains readable")
        try expect(FileManager.default.fileExists(atPath: path + "-wal"), false, "source WAL not created")
        try expect(FileManager.default.fileExists(atPath: path + "-shm"), false, "source SHM not created")
    }
}
