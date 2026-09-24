import CSQLite
import CryptoKit
import Foundation

public enum SafariHistorySchema: String, Sendable {
    case historyV1 = "safari-history-v1"

    // Fingerprints cover exact SQLite DDL, including types, defaults, constraints,
    // indexes and triggers. Even formatting-only changes require qualification.
    // The independently captured, data-free fixture is tests/fixtures/safari-history-v1.sql.
    private var fingerprint: String {
        switch self {
        case .historyV1: "69bb534a23e7ebf4bb36942789367d7e3ccaf24008794d6bf103f3dba6ece48a"
        }
    }

    func validate(_ db: Connection) throws {
        let statement = try db.prepare("""
          SELECT type, name, sql FROM sqlite_schema
          WHERE tbl_name IN ('history_items', 'history_visits', 'metadata')
          ORDER BY type, name
          """)
        defer { sqlite3_finalize(statement) }
        var definitions: [[String?]] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { break }
            guard result == SQLITE_ROW else { throw db.error() }
            definitions.append((0..<3).map { index in
                guard let text = sqlite3_column_text(statement, Int32(index)) else { return nil }
                return String(cString: text)
            })
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        let data = try encoder.encode(definitions)
        let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard actual == fingerprint else {
            throw SafariHistoryError.incompatibleSchema("\(rawValue) definition fingerprint mismatch")
        }
    }
}
