import CSQLite
import Foundation
import SafariSyncCore

enum IntegrationFailure: Error, CustomStringConvertible {
    case assertion(String)
    var description: String {
        switch self { case let .assertion(message): return message }
    }
}

func expect<T: Equatable>(_ actual: T, _ expected: T, _ message: String) throws {
    guard actual == expected else {
        throw IntegrationFailure.assertion("\(message): expected \(expected), got \(actual)")
    }
}

struct SafariSyncCoreIntegrationTests {
    static func main() throws {
        try validatesHistoryAccessAndSchema()
        try insertsOutboundVisitWithoutAcknowledgingICloud()
        try insertsDistinctOutboundVisits()
        try sourceEventIsIdempotent()
        try agentInterfacesPersistProfileAndExchangeState()
        try keyLossReportsUnrecoverableWork()
        try ipcSecretRequiresOwnerOnlyRegularFile()
        print("SafariSyncCoreIntegrationTests passed")
    }

    static func validatesHistoryAccessAndSchema() throws {
        let fixture = try HistoryFixture()
        let store = SafariHistoryStore(databaseURL: fixture.url, ledgerURL: fixture.ledgerURL)
        try store.validateAccessAndSchema()
    }

    static func insertsOutboundVisitWithoutAcknowledgingICloud() throws {
        let fixture = try HistoryFixture()
        let store = SafariHistoryStore(databaseURL: fixture.url, ledgerURL: fixture.ledgerURL)
        let receipt = try store.insertBrowserVisit(
            eventID: "b2a-1",
            url: URL(string: "https://example.com/from-edge")!,
            title: nil,
            deliveredAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
        try expect(receipt.generation, 42, "generation")
        try expect(try fixture.scalarInt("SELECT origin FROM history_visits"), 0, "origin")
        try expect(try fixture.scalarInt("SELECT generation FROM history_visits"), 42, "visit generation")
        try expect(
            try fixture.scalarInt("SELECT value FROM metadata WHERE key = 'last_synced_generation'"),
            40,
            "last synced generation"
        )
        try expect(try fixture.scalarInt("SELECT COUNT(*) FROM history_visits"), 1, "visit count")
    }

    static func sourceEventIsIdempotent() throws {
        let fixture = try HistoryFixture()
        let store = SafariHistoryStore(databaseURL: fixture.url, ledgerURL: fixture.ledgerURL)
        let url = URL(string: "https://example.com/once")!
        _ = try store.insertBrowserVisit(eventID: "same", url: url, title: nil, deliveredAt: .now)
        let retry = try store.insertBrowserVisit(eventID: "same", url: url, title: nil, deliveredAt: .now)
        try expect(retry.disposition, .alreadyApplied, "retry disposition")
        try expect(try fixture.scalarInt("SELECT COUNT(*) FROM history_visits"), 1, "idempotent visit count")
    }

    static func insertsDistinctOutboundVisits() throws {
        let fixture = try HistoryFixture()
        let store = SafariHistoryStore(databaseURL: fixture.url, ledgerURL: fixture.ledgerURL)
        _ = try store.insertBrowserVisit(
            eventID: "first",
            url: URL(string: "https://example.com/first")!,
            title: nil,
            deliveredAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
        _ = try store.insertBrowserVisit(
            eventID: "second",
            url: URL(string: "https://example.com/second")!,
            title: nil,
            deliveredAt: Date(timeIntervalSince1970: 1_800_000_001)
        )
        try expect(try fixture.scalarInt("SELECT COUNT(*) FROM history_visits"), 2, "distinct visit count")
        try expect(
            try fixture.scalarInt("SELECT COUNT(*) FROM history_visits WHERE redirect_source IS NULL"),
            2,
            "redirect source remains null"
        )
        try expect(
            try fixture.scalarInt("SELECT COUNT(*) FROM history_visits WHERE redirect_destination IS NULL"),
            2,
            "redirect destination remains null"
        )
    }

    static func agentInterfacesPersistProfileAndExchangeState() throws {
        let fixture = try HistoryFixture()
        let history = SafariHistoryStore(databaseURL: fixture.url, ledgerURL: fixture.ledgerURL)
        let service = AgentService(
            history: history,
            stateURL: fixture.stateURL,
            secret: Data(repeating: 7, count: 32)
        )
        try expect(try service.selectProfile("edge:Default"), "ACTIVE", "initial profile")
        try expect(try service.status().activeProfileID, "edge:Default", "status active profile")

        let publish = try JSONSerialization.data(withJSONObject: [
            "version": 1,
            "operation": "publish",
            "stream": "browserToSafari",
            "profileId": "edge:Default",
            "events": [[
                "eventId": "agent-event",
                "sequence": 1,
                "url": "https://example.com/agent",
            ]],
        ])
        let receipt = try JSONSerialization.jsonObject(with: service.browserExchange(publish)) as! [String: Any]
        try expect(receipt["type"] as? String, "receipt", "agent receipt type")
        try expect(receipt["throughSequence"] as? Int, 1, "agent receipt sequence")
        try expect(try fixture.scalarInt("SELECT COUNT(*) FROM history_visits"), 1, "agent visit count")

        try expect(
            try service.selectProfile("chrome:Profile 1"),
            "AWAITING_FREEZE_ACK",
            "switch state"
        )
        let freeze = try JSONSerialization.data(withJSONObject: [
            "version": 1,
            "operation": "freezeAck",
            "profileId": "edge:Default",
        ])
        _ = try service.browserExchange(freeze)
        try expect(try service.status().activeProfileID, "chrome:Profile 1", "promoted profile")
    }

    static func keyLossReportsUnrecoverableWork() throws {
        let fixture = try HistoryFixture()
        let history = SafariHistoryStore(databaseURL: fixture.url, ledgerURL: fixture.ledgerURL)
        let service = AgentService(
            history: history,
            stateURL: fixture.stateURL,
            secret: Data(repeating: 3, count: 32)
        )
        _ = try service.selectProfile("edge:Default")
        try fixture.insertSafariVisit(url: "https://example.com/unresolved")
        let pull = try JSONSerialization.data(withJSONObject: [
            "version": 1,
            "operation": "pull",
            "stream": "safariToBrowser",
            "profileId": "edge:Default",
            "afterSequence": 0,
            "limit": 128,
        ])
        _ = try service.browserExchange(pull)

        let serviceWithLostKey = AgentService(
            history: history,
            stateURL: fixture.stateURL,
            secret: Data(repeating: 9, count: 32)
        )
        let status = try serviceWithLostKey.status()
        try expect(status.switchState, "KEY_UNAVAILABLE", "key loss status")
        try expect(status.unrecoverableCount, 1, "key loss unresolved count")
    }

    static func ipcSecretRequiresOwnerOnlyRegularFile() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("safari-sync-ipc-\(UUID().uuidString)")
        let url = directory.appendingPathComponent("ipc.secret")
        defer { try? FileManager.default.removeItem(at: directory) }

        let created = try IPCSecretStore.load(from: url, createIfMissing: true)
        try expect(created.count, 32, "IPC secret length")
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        try expect(attributes[.posixPermissions] as? NSNumber, NSNumber(value: 0o600), "IPC secret mode")
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        do {
            _ = try IPCSecretStore.load(from: url, createIfMissing: false)
            throw IntegrationFailure.assertion("unsafe IPC secret permissions were accepted")
        } catch let failure as IntegrationFailure {
            throw failure
        } catch {
            // Expected: the Bridge and Menu must fail closed instead of reading a broad file.
        }
    }
}

try SafariSyncCoreIntegrationTests.main()

private final class HistoryFixture {
    let url: URL
    let ledgerURL: URL
    let stateURL: URL
    private var db: OpaquePointer?

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("safari-sync-\(UUID().uuidString).db")
        ledgerURL = url.appendingPathExtension("ledger")
        stateURL = url.appendingPathExtension("state")
        guard sqlite3_open(url.path, &db) == SQLITE_OK else { throw FixtureError.open }
        try exec("""
          CREATE TABLE history_items (
            id INTEGER PRIMARY KEY AUTOINCREMENT, url TEXT UNIQUE NOT NULL,
            domain_expansion TEXT, visit_count INTEGER NOT NULL DEFAULT 0,
            daily_visit_counts BLOB, weekly_visit_counts BLOB,
            autocomplete_triggers BLOB,
            should_recompute_derived_visit_counts INTEGER NOT NULL DEFAULT 0,
            visit_count_score REAL NOT NULL DEFAULT 0, status_code INTEGER NOT NULL DEFAULT 0
          );
          CREATE TABLE history_visits (
            id INTEGER PRIMARY KEY AUTOINCREMENT, history_item INTEGER NOT NULL,
            visit_time REAL NOT NULL, title TEXT,
            load_successful INTEGER NOT NULL DEFAULT 1,
            http_non_get INTEGER NOT NULL DEFAULT 0,
            synthesized INTEGER NOT NULL DEFAULT 0,
            redirect_source INTEGER NULL UNIQUE,
            redirect_destination INTEGER NULL UNIQUE,
            origin INTEGER NOT NULL DEFAULT 0, generation INTEGER NOT NULL,
            attributes INTEGER NOT NULL DEFAULT 0, score REAL NOT NULL DEFAULT 0
          );
          CREATE TABLE metadata (key TEXT PRIMARY KEY, value INTEGER NOT NULL);
          INSERT INTO metadata(key, value)
            VALUES ('current_generation', 41), ('last_synced_generation', 40);
        """)
    }

    deinit {
        sqlite3_close(db)
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(at: ledgerURL)
        try? FileManager.default.removeItem(at: stateURL)
        try? FileManager.default.removeItem(at: stateURL.appendingPathExtension("unresolved-count"))
    }

    func scalarInt(_ sql: String) throws -> Int64 {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw FixtureError.query
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw FixtureError.query }
        return sqlite3_column_int64(statement, 0)
    }

    func insertSafariVisit(url: String) throws {
        let escaped = url.replacingOccurrences(of: "'", with: "''")
        try exec("""
          INSERT INTO history_items(url, visit_count, should_recompute_derived_visit_counts)
            VALUES ('\(escaped)', 1, 1);
          INSERT INTO history_visits(history_item, visit_time, title, origin, generation)
            VALUES (last_insert_rowid(), 900000000, '\(escaped)', 0, 42);
          UPDATE metadata SET value = 42 WHERE key = 'current_generation';
        """)
    }

    private func exec(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw FixtureError.query }
    }

    private enum FixtureError: Error { case open, query }
}
