import CSQLite
import CryptoKit
import Darwin
import Foundation

public enum DeliveryDisposition: String, Codable, Sendable {
    case applied
    case alreadyApplied
}

public struct DeliveryReceipt: Codable, Equatable, Sendable {
    public let eventID: String
    public let visitID: Int64
    public let generation: Int64
    public let disposition: DeliveryDisposition
}

public struct SafariArrivalCursor: Codable, Equatable, Sendable {
    public let databaseIdentity: String
    public let visitID: Int64
    public let rowAuthenticator: Data
}

public struct SafariVisit: Codable, Equatable, Sendable {
    public let visitID: Int64
    public let url: URL
}

public enum SafariHistoryError: Error, Equatable {
    case databaseUnavailable(String)
    case incompatibleSchema(String)
    case sqlite(code: Int32, message: String)
    case invalidURL
}

public final class SafariHistoryStore: @unchecked Sendable {
    private let databaseURL: URL
    private let ledger: DeliveryLedger
    private let lock = NSLock()

    public init(databaseURL: URL, ledgerURL: URL? = nil) {
        self.databaseURL = databaseURL
        let resolvedLedger = ledgerURL ?? databaseURL
            .deletingLastPathComponent()
            .appendingPathComponent("SafariSync-delivery-ledger.sqlite")
        self.ledger = DeliveryLedger(url: resolvedLedger)
    }

    public func arrivalBaseline(authenticationKey: Data) throws -> SafariArrivalCursor {
        try lock.withLock {
            let db = try Connection(path: databaseURL.path)
            defer { db.close() }
            try validateSchema(db)
            let query = try db.prepare("""
              SELECT hv.id, hi.url, hv.visit_time
              FROM history_visits hv JOIN history_items hi ON hi.id = hv.history_item
              ORDER BY hv.id DESC LIMIT 1
              """)
            defer { sqlite3_finalize(query) }
            if sqlite3_step(query) == SQLITE_ROW {
                let id = sqlite3_column_int64(query, 0)
                let url = columnText(query, index: 1)
                let time = sqlite3_column_double(query, 2)
                return SafariArrivalCursor(
                    databaseIdentity: try databaseIdentity(),
                    visitID: id,
                    rowAuthenticator: rowHMAC(id: id, url: url, time: time, key: authenticationKey)
                )
            }
            return SafariArrivalCursor(
                databaseIdentity: try databaseIdentity(),
                visitID: 0,
                rowAuthenticator: rowHMAC(id: 0, url: "EMPTY", time: 0, key: authenticationKey)
            )
        }
    }

    public func newVisits(
        after cursor: SafariArrivalCursor,
        authenticationKey: Data,
        limit: Int = 128
    ) throws -> (events: [SafariVisit], cursor: SafariArrivalCursor) {
        try lock.withLock {
            let currentIdentity = try databaseIdentity()
            guard cursor.databaseIdentity == currentIdentity else {
                throw SafariHistoryError.incompatibleSchema("history database identity changed")
            }
            let db = try Connection(path: databaseURL.path)
            defer { db.close() }
            try validateSchema(db)
            try validateAnchor(cursor, db: db, key: authenticationKey)
            let query = try db.prepare("""
              SELECT hv.id, hi.url, hv.visit_time
              FROM history_visits hv JOIN history_items hi ON hi.id = hv.history_item
              WHERE hv.id > ? ORDER BY hv.id ASC LIMIT ?
              """)
            defer { sqlite3_finalize(query) }
            sqlite3_bind_int64(query, 1, cursor.visitID)
            sqlite3_bind_int(query, 2, Int32(max(1, min(limit, 128))))
            var events: [SafariVisit] = []
            var next = cursor
            while sqlite3_step(query) == SQLITE_ROW {
                let id = sqlite3_column_int64(query, 0)
                let source = columnText(query, index: 1)
                let time = sqlite3_column_double(query, 2)
                if let url = URL(string: source), ["http", "https"].contains(url.scheme ?? "") {
                    events.append(SafariVisit(visitID: id, url: url))
                }
                next = SafariArrivalCursor(
                    databaseIdentity: cursor.databaseIdentity,
                    visitID: id,
                    rowAuthenticator: rowHMAC(id: id, url: source, time: time, key: authenticationKey)
                )
            }
            return (events, next)
        }
    }

    public func insertBrowserVisit(
        eventID: String,
        url: URL,
        title: String?,
        deliveredAt: Date
    ) throws -> DeliveryReceipt {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
            throw SafariHistoryError.invalidURL
        }
        return try lock.withLock {
            if let receipt = try ledger.completed(eventID: eventID) {
                return DeliveryReceipt(
                    eventID: eventID,
                    visitID: receipt.visitID,
                    generation: receipt.generation,
                    disposition: .alreadyApplied
                )
            }

            let safariTime = try ledger.begin(
                eventID: eventID,
                safariTime: deliveredAt.timeIntervalSinceReferenceDate
            )
            let db = try Connection(path: databaseURL.path)
            defer { db.close() }
            try validateSchema(db)
            try db.exec("BEGIN IMMEDIATE")
            do {
                if let existing = try existingVisit(db, url: url.absoluteString, safariTime: safariTime) {
                    let generation = try generationForVisit(db, visitID: existing)
                    try db.exec("COMMIT")
                    try ledger.complete(eventID: eventID, visitID: existing, generation: generation)
                    return DeliveryReceipt(
                        eventID: eventID,
                        visitID: existing,
                        generation: generation,
                        disposition: .alreadyApplied
                    )
                }

                let itemID = try ensureHistoryItem(db, url: url.absoluteString)
                let generation = try nextGeneration(db)
                let statement = try db.prepare("""
                    INSERT INTO history_visits (
                      history_item, visit_time, title, load_successful, http_non_get,
                      synthesized, redirect_source, redirect_destination, origin,
                      generation, attributes, score
                    ) VALUES (?, ?, ?, 1, 0, 0, NULL, NULL, 0, ?, 0, 0)
                    """)
                defer { sqlite3_finalize(statement) }
                sqlite3_bind_int64(statement, 1, itemID)
                sqlite3_bind_double(statement, 2, safariTime)
                bindText(statement, index: 3, value: title ?? url.absoluteString)
                sqlite3_bind_int64(statement, 4, generation)
                try stepDone(statement, db: db)
                let visitID = sqlite3_last_insert_rowid(db.handle)

                let update = try db.prepare("""
                    UPDATE history_items
                    SET visit_count = visit_count + 1,
                        should_recompute_derived_visit_counts = 1
                    WHERE id = ?
                    """)
                defer { sqlite3_finalize(update) }
                sqlite3_bind_int64(update, 1, itemID)
                try stepDone(update, db: db)
                try db.exec("COMMIT")
                try ledger.complete(eventID: eventID, visitID: visitID, generation: generation)
                return DeliveryReceipt(
                    eventID: eventID,
                    visitID: visitID,
                    generation: generation,
                    disposition: .applied
                )
            } catch {
                try? db.exec("ROLLBACK")
                throw error
            }
        }
    }

    public func needsCloudTrigger() throws -> Bool {
        try lock.withLock {
            let db = try Connection(path: databaseURL.path)
            defer { db.close() }
            try validateSchema(db)
            let query = try db.prepare("""
              SELECT
                COALESCE(MAX(CASE WHEN key = 'current_generation' THEN CAST(value AS INTEGER) END), 0),
                COALESCE(MAX(CASE WHEN key = 'last_synced_generation' THEN CAST(value AS INTEGER) END), 0)
              FROM metadata
              """)
            defer { sqlite3_finalize(query) }
            guard sqlite3_step(query) == SQLITE_ROW else { throw db.error() }
            return sqlite3_column_int64(query, 0) > sqlite3_column_int64(query, 1)
        }
    }

    private func validateSchema(_ db: Connection) throws {
        let required: [String: Set<String>] = [
            "history_items": [
                "id", "url", "domain_expansion", "visit_count", "daily_visit_counts",
                "weekly_visit_counts", "autocomplete_triggers",
                "should_recompute_derived_visit_counts", "visit_count_score", "status_code",
            ],
            "history_visits": [
                "id", "history_item", "visit_time", "title", "load_successful", "http_non_get",
                "synthesized", "redirect_source", "redirect_destination", "origin", "generation",
                "attributes", "score",
            ],
            "metadata": ["key", "value"],
        ]
        for (table, columns) in required {
            let actual = try db.columns(table: table)
            guard actual == columns else {
                throw SafariHistoryError.incompatibleSchema("\(table) fingerprint mismatch")
            }
        }
    }

    private func validateAnchor(_ cursor: SafariArrivalCursor, db: Connection, key: Data) throws {
        if cursor.visitID == 0 {
            let expected = rowHMAC(id: 0, url: "EMPTY", time: 0, key: key)
            guard expected == cursor.rowAuthenticator else {
                throw SafariHistoryError.incompatibleSchema("empty history anchor changed")
            }
            return
        }
        let query = try db.prepare("""
          SELECT hi.url, hv.visit_time FROM history_visits hv
          JOIN history_items hi ON hi.id = hv.history_item WHERE hv.id = ?
          """)
        defer { sqlite3_finalize(query) }
        sqlite3_bind_int64(query, 1, cursor.visitID)
        guard sqlite3_step(query) == SQLITE_ROW else {
            throw SafariHistoryError.incompatibleSchema("history anchor is missing")
        }
        let url = columnText(query, index: 0)
        let time = sqlite3_column_double(query, 1)
        guard rowHMAC(id: cursor.visitID, url: url, time: time, key: key) == cursor.rowAuthenticator else {
            throw SafariHistoryError.incompatibleSchema("history anchor changed")
        }
    }

    private func databaseIdentity() throws -> String {
        var info = stat()
        guard stat(databaseURL.path, &info) == 0 else {
            throw SafariHistoryError.databaseUnavailable(databaseURL.path)
        }
        return "\(info.st_dev):\(info.st_ino)"
    }

    private func rowHMAC(id: Int64, url: String, time: Double, key: Data) -> Data {
        let value = Data("\(id)\n\(url)\n\(time.bitPattern)".utf8)
        return Data(HMAC<SHA256>.authenticationCode(for: value, using: SymmetricKey(data: key)))
    }

    private func ensureHistoryItem(_ db: Connection, url: String) throws -> Int64 {
        let insert = try db.prepare("""
          INSERT OR IGNORE INTO history_items (
            url, domain_expansion, visit_count, daily_visit_counts,
            weekly_visit_counts, autocomplete_triggers,
            should_recompute_derived_visit_counts, visit_count_score, status_code
          ) VALUES (?, NULL, 0, X'', NULL, NULL, 1, 0, 0)
          """)
        bindText(insert, index: 1, value: url)
        try stepDone(insert, db: db)
        sqlite3_finalize(insert)

        let query = try db.prepare("SELECT id FROM history_items WHERE url = ?")
        defer { sqlite3_finalize(query) }
        bindText(query, index: 1, value: url)
        guard sqlite3_step(query) == SQLITE_ROW else { throw db.error() }
        return sqlite3_column_int64(query, 0)
    }

    private func existingVisit(_ db: Connection, url: String, safariTime: Double) throws -> Int64? {
        let query = try db.prepare("""
          SELECT hv.id
          FROM history_visits hv JOIN history_items hi ON hi.id = hv.history_item
          WHERE hi.url = ? AND ABS(hv.visit_time - ?) < 0.001
          ORDER BY hv.id DESC LIMIT 1
          """)
        defer { sqlite3_finalize(query) }
        bindText(query, index: 1, value: url)
        sqlite3_bind_double(query, 2, safariTime)
        let result = sqlite3_step(query)
        if result == SQLITE_DONE { return nil }
        guard result == SQLITE_ROW else { throw db.error() }
        return sqlite3_column_int64(query, 0)
    }

    private func generationForVisit(_ db: Connection, visitID: Int64) throws -> Int64 {
        let query = try db.prepare("SELECT generation FROM history_visits WHERE id = ?")
        defer { sqlite3_finalize(query) }
        sqlite3_bind_int64(query, 1, visitID)
        guard sqlite3_step(query) == SQLITE_ROW else { throw db.error() }
        return sqlite3_column_int64(query, 0)
    }

    private func nextGeneration(_ db: Connection) throws -> Int64 {
        let query = try db.prepare("""
          SELECT MAX(CAST(value AS INTEGER)) FROM metadata
          WHERE key IN ('current_generation', 'last_synced_generation')
          """)
        defer { sqlite3_finalize(query) }
        guard sqlite3_step(query) == SQLITE_ROW else { throw db.error() }
        let next = sqlite3_column_int64(query, 0) + 1
        let update = try db.prepare("""
          INSERT INTO metadata(key, value) VALUES ('current_generation', ?)
          ON CONFLICT(key) DO UPDATE SET value = excluded.value
          """)
        defer { sqlite3_finalize(update) }
        sqlite3_bind_int64(update, 1, next)
        try stepDone(update, db: db)
        return next
    }
}

private final class DeliveryLedger {
    private let url: URL
    init(url: URL) { self.url = url }

    func begin(eventID: String, safariTime: Double) throws -> Double {
        let db = try Connection(path: url.path, create: true)
        defer { db.close() }
        try create(db)
        let statement = try db.prepare("""
          INSERT OR IGNORE INTO deliveries(event_id, safari_time, state)
          VALUES (?, ?, 'APPLYING')
          """)
        defer { sqlite3_finalize(statement) }
        bindText(statement, index: 1, value: eventID)
        sqlite3_bind_double(statement, 2, safariTime)
        try stepDone(statement, db: db)
        let query = try db.prepare("SELECT safari_time FROM deliveries WHERE event_id = ?")
        defer { sqlite3_finalize(query) }
        bindText(query, index: 1, value: eventID)
        guard sqlite3_step(query) == SQLITE_ROW else { throw db.error() }
        return sqlite3_column_double(query, 0)
    }

    func complete(eventID: String, visitID: Int64, generation: Int64) throws {
        let db = try Connection(path: url.path, create: true)
        defer { db.close() }
        try create(db)
        let statement = try db.prepare("""
          UPDATE deliveries SET state = 'APPLIED', visit_id = ?, generation = ?
          WHERE event_id = ?
          """)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, visitID)
        sqlite3_bind_int64(statement, 2, generation)
        bindText(statement, index: 3, value: eventID)
        try stepDone(statement, db: db)
    }

    func completed(eventID: String) throws -> (visitID: Int64, generation: Int64)? {
        let db = try Connection(path: url.path, create: true)
        defer { db.close() }
        try create(db)
        let query = try db.prepare("""
          SELECT visit_id, generation FROM deliveries
          WHERE event_id = ? AND state = 'APPLIED'
          """)
        defer { sqlite3_finalize(query) }
        bindText(query, index: 1, value: eventID)
        let result = sqlite3_step(query)
        if result == SQLITE_DONE { return nil }
        guard result == SQLITE_ROW else { throw db.error() }
        return (sqlite3_column_int64(query, 0), sqlite3_column_int64(query, 1))
    }

    private func create(_ db: Connection) throws {
        try db.exec("""
          CREATE TABLE IF NOT EXISTS deliveries (
            event_id TEXT PRIMARY KEY,
            safari_time REAL NOT NULL,
            state TEXT NOT NULL,
            visit_id INTEGER,
            generation INTEGER
          )
          """)
    }
}

final class Connection {
    fileprivate var handle: OpaquePointer?
    init(path: String, create: Bool = false) throws {
        let flags = SQLITE_OPEN_READWRITE | (create ? SQLITE_OPEN_CREATE : 0)
        guard sqlite3_open_v2(path, &handle, flags, nil) == SQLITE_OK else {
            throw SafariHistoryError.databaseUnavailable(path)
        }
        sqlite3_busy_timeout(handle, 5_000)
    }
    func close() { sqlite3_close(handle); handle = nil }
    func exec(_ sql: String) throws {
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else { throw error() }
    }
    func prepare(_ sql: String) throws -> OpaquePointer? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else { throw error() }
        return statement
    }
    func columns(table: String) throws -> Set<String> {
        let statement = try prepare("PRAGMA table_info(\(table))")
        defer { sqlite3_finalize(statement) }
        var result = Set<String>()
        while sqlite3_step(statement) == SQLITE_ROW {
            if let raw = sqlite3_column_text(statement, 1) {
                result.insert(String(cString: raw))
            }
        }
        return result
    }
    func error() -> SafariHistoryError {
        SafariHistoryError.sqlite(
            code: sqlite3_errcode(handle),
            message: String(cString: sqlite3_errmsg(handle))
        )
    }
}

private func bindText(_ statement: OpaquePointer?, index: Int32, value: String) {
    sqlite3_bind_text(statement, index, value, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
}

private func stepDone(_ statement: OpaquePointer?, db: Connection) throws {
    guard sqlite3_step(statement) == SQLITE_DONE else { throw db.error() }
}

private func columnText(_ statement: OpaquePointer?, index: Int32) -> String {
    guard let raw = sqlite3_column_text(statement, index) else { return "" }
    return String(cString: raw)
}
