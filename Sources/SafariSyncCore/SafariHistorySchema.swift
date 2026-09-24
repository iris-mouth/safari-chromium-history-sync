import CSQLite
import Foundation

public enum SafariHistorySchema: String, Sendable {
    case historyV1 = "safari-history-v1"

    // Data-free reference captured independently in tests/fixtures/safari-history-v1.sql.
    // SQLite interprets this definition; runtime matching compares PRAGMA metadata,
    // not DDL text or SQL whitespace. Keep the original test fixture independent.
    private static let referenceSQL = """
    CREATE TABLE history_items (id INTEGER PRIMARY KEY AUTOINCREMENT,url TEXT NOT NULL UNIQUE,domain_expansion TEXT NULL,visit_count INTEGER NOT NULL,daily_visit_counts BLOB NOT NULL,weekly_visit_counts BLOB NULL,autocomplete_triggers BLOB NULL,should_recompute_derived_visit_counts INTEGER NOT NULL,visit_count_score INTEGER NOT NULL,status_code INTEGER NOT NULL DEFAULT 0);
    CREATE TABLE history_visits (id INTEGER PRIMARY KEY AUTOINCREMENT,history_item INTEGER NOT NULL REFERENCES history_items(id) ON DELETE CASCADE,visit_time REAL NOT NULL,title TEXT NULL,load_successful BOOLEAN NOT NULL DEFAULT 1,http_non_get BOOLEAN NOT NULL DEFAULT 0,synthesized BOOLEAN NOT NULL DEFAULT 0,redirect_source INTEGER NULL UNIQUE REFERENCES history_visits(id) ON DELETE CASCADE,redirect_destination INTEGER NULL UNIQUE REFERENCES history_visits(id) ON DELETE CASCADE,origin INTEGER NOT NULL DEFAULT 0,generation INTEGER NOT NULL DEFAULT 0,attributes INTEGER NOT NULL DEFAULT 0,score INTEGER NOT NULL DEFAULT 0);
    CREATE TABLE metadata (key TEXT NOT NULL UNIQUE, value);
    CREATE INDEX history_items__domain_expansion ON history_items (domain_expansion);
    CREATE INDEX history_visits__last_visit ON history_visits (history_item, visit_time DESC, synthesized ASC);
    CREATE INDEX history_visits__origin ON history_visits (origin, generation);
    """

    private static let reference: Result<[TableShape], Error> = Result {
        let db = try Connection(path: ":memory:", create: true)
        defer { db.close() }
        try db.exec(referenceSQL)
        return try shapes(db)
    }

    func validate(_ db: Connection) throws {
        guard try Self.shapes(db) == Self.reference.get() else {
            throw SafariHistoryError.incompatibleSchema("\(rawValue) structure mismatch")
        }
    }

    private struct TableShape: Equatable, Sendable {
        let columns: [[String?]]
        let foreignKeys: [[String?]]
        let uniqueIndexes: [[String?]]
        let flags: [[String?]]
        let autoincrementCount: Int
    }

    private static func shapes(_ db: Connection) throws -> [TableShape] {
        try ["history_items", "history_visits", "metadata"].map { table in
            let quoted = quote(table)
            let definitions = try rows(db, "SELECT type, sql FROM sqlite_schema WHERE name = \(quoted) COLLATE NOCASE")
            guard definitions.count == 1, definitions[0][0] == "table", let ddl = definitions[0][1] else {
                throw SafariHistoryError.incompatibleSchema("missing ordinary table \(table)")
            }
            let words = try sqlWords(ddl)
            // PRAGMA metadata does not expose these clauses completely. Reject
            // unfamiliar behavior instead of silently ignoring a constraint.
            guard Set(words).isDisjoint(with: ["check", "collate", "conflict", "deferrable", "match"]) else {
                throw SafariHistoryError.incompatibleSchema("unsupported constraint on \(table)")
            }
            let triggers = try rows(db, "SELECT name FROM sqlite_schema WHERE type = 'trigger' AND tbl_name = \(quoted) COLLATE NOCASE")
            guard triggers.isEmpty else {
                throw SafariHistoryError.incompatibleSchema("unexpected trigger on \(table)")
            }
            let columns = try rows(db, "PRAGMA table_xinfo(\(quoted))").map { row -> [String?] in
                // cid is presentation order, not a column's meaning.
                [row[1]?.lowercased(), row[2]?.uppercased(), row[3], normalizedDefault(row[4]), row[5], row[6]]
            }
            let foreignKeys = try rows(db, "PRAGMA foreign_key_list(\(quoted))").map { row in
                // Ignore SQLite's enumeration ID, preserve composite-key sequence.
                Array(row.dropFirst()).map { $0?.lowercased() }
            }
            var uniqueIndexes: [[String?]] = []
            for index in try rows(db, "PRAGMA index_list(\(quoted))") {
                guard let name = index[1] else { throw SafariHistoryError.incompatibleSchema("unnamed index") }
                let keys = try rows(db, "PRAGMA index_xinfo(\(quote(name)))").filter { $0[5] == "1" }
                // Plain nonunique indexes may be added, renamed or removed. They
                // affect performance, not accepted writes. Expressions/partial
                // indexes remain unsupported because they add unmodeled behavior.
                guard index[4] == "0", keys.allSatisfy({ $0[1] != "-2" && $0[2] != nil }) else {
                    throw SafariHistoryError.incompatibleSchema("unsupported index on \(table)")
                }
                if index[2] == "1" {
                    var signature: [String?] = [index[3]]
                    for key in keys {
                        signature += [key[2]?.lowercased(), key[3], key[4]?.lowercased()]
                    }
                    uniqueIndexes.append(signature)
                }
            }
            let flags = try rows(db, "SELECT type, ncol, wr, strict FROM pragma_table_list WHERE schema = 'main' AND name = \(quoted) COLLATE NOCASE")
            return TableShape(
                columns: sorted(columns), foreignKeys: sorted(foreignKeys),
                uniqueIndexes: sorted(uniqueIndexes), flags: flags,
                autoincrementCount: words.filter { $0 == "autoincrement" }.count
            )
        }
    }

    private static func normalizedDefault(_ value: String?) -> String? {
        guard var value else { return nil }
        value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        while value.hasPrefix("("), value.hasSuffix(")") {
            value = String(value.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let number = Int64(value) { return String(number) }
        return value
    }

    private static func sorted(_ values: [[String?]]) -> [[String?]] {
        values.sorted { lhs, rhs in
            lhs.map { $0 ?? "" }.lexicographicallyPrecedes(rhs.map { $0 ?? "" })
        }
    }

    private static func quote(_ identifier: String) -> String {
        "'" + identifier.replacingOccurrences(of: "'", with: "''") + "'"
    }

    private static func sqlWords(_ sql: String) throws -> [String] {
        // Remove comments and quoted tokens before identifying DDL-only features.
        let ignored = try NSRegularExpression(pattern: #"(?s)--[^\n]*(?:\n|$)|/\*.*?\*/|'(?:''|[^'])*'|"(?:""|[^"])*"|`(?:``|[^`])*`|\[[^\]]*\]"#)
        let stripped = ignored.stringByReplacingMatches(in: sql, range: NSRange(sql.startIndex..., in: sql), withTemplate: " ")
        return stripped.lowercased().split { !$0.isLetter && $0 != "_" }.map(String.init)
    }

    private static func rows(_ db: Connection, _ sql: String) throws -> [[String?]] {
        let statement = try db.prepare(sql)
        defer { sqlite3_finalize(statement) }
        var result: [[String?]] = []
        while true {
            let code = sqlite3_step(statement)
            if code == SQLITE_DONE { return result }
            guard code == SQLITE_ROW else { throw db.error() }
            result.append((0..<sqlite3_column_count(statement)).map { column in
                guard let text = sqlite3_column_text(statement, column) else { return nil }
                return String(cString: text)
            })
        }
    }
}
