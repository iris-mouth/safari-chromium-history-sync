import CSQLite
import Foundation

public enum HistoryReaderError: Error {
    case invalid(String)
    case unavailable
    case notFound
}

public final class HistoryReadCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    public init() {}
    public func cancel() { lock.withLock { cancelled = true } }
    fileprivate var isCancelled: Bool { lock.withLock { cancelled } }
    var isCancelledForHTTP: Bool { lock.withLock { cancelled } }
}

public struct HistoryRecord: Codable, Equatable, Sendable {
    public let id: Int64
    public let url: String
    public let title: String
    public let visitTime: Double
    public let browserType: String
    public let profileName: String
    public let site: String?
    public let device: String?
    public let time: String
    public let day: String
    public let sourceID: String
    public let nativeVisitID: Int64
}
public struct HistoryPage: Codable, Sendable {
    public let items: [HistoryRecord]
    public let valid: [HistoryRecord]
    public let cursor: String?
    public let icons: [String: String]
}
public struct HistoryReaderSource: Codable, Sendable {
    public let id: String
    public let browserType: String
    public let profileName: String
    public let state: String
    public let lastSuccess: Double?
    public let error: String?
    public let count: Int64
}
public struct HistoryReaderStatus: Codable, Sendable {
    public let day: String
    public let today: String
    public let timezone: String
    public let empty: Bool
    public let latestTime: String?
    public let sources: [HistoryReaderSource]
    public let collectionEnabled: Bool
}

/// Stateless read-only boundary shared by all HTTP operations.
public struct HistoryReader: Sendable {
    public enum Scope: Sendable {
        case all
        case range(start: String?, end: String?)
    }

    public let databasePath: String
    public init(databasePath: String) { self.databasePath = databasePath }
    private static let zone = TimeZone(identifier: "Asia/Tokyo")!
    private static let select = """
        SELECT v.id,v.url,COALESCE(v.title,''),v.visit_seconds,v.visit_fraction,
               s.browser_type,s.profile_name,s.id,v.native_id
        FROM visits v JOIN sources s ON s.id=v.source_id
        """

    func verifyAvailability(cancellation: HistoryReadCancellation) throws {
        try snapshot(cancellation) { db in
            let settings = try db.query("SELECT value FROM collection_settings WHERE key='enabled'")
            guard try settings.step() else { throw HistoryReaderError.unavailable }
            _ = try db.query(Self.select + " LIMIT 1").step()
        }
    }

    public func status(cancellation: HistoryReadCancellation? = nil) throws -> HistoryReaderStatus {
        try snapshot(cancellation) { db in
            let today = Self.day(Date())
            let s = try db.query(Self.select + " ORDER BY v.visit_seconds DESC,v.visit_fraction DESC,v.id DESC LIMIT 1")
            let latest = try s.step() ? try Self.record(s) : nil
            let sources = try db.query("""
                SELECT s.id,s.browser_type,s.profile_name,s.state,s.last_success,s.error,
                    (SELECT count(*) FROM visits v WHERE v.source_id=s.id)
                FROM sources s ORDER BY s.id
                """)
            var result: [HistoryReaderSource] = []
            while try sources.step() {
                guard let id = sources.text(0), let browser = sources.text(1), let profile = sources.text(2), let state = sources.text(3) else { throw HistoryReaderError.unavailable }
                result.append(.init(id: id, browserType: browser, profileName: profile, state: state,
                    lastSuccess: sources.optionalDouble(4), error: sources.text(5) == nil ? nil : "sourceUnavailable", count: sources.int64(6)))
            }
            let enabled = try db.query("SELECT value='1' FROM collection_settings WHERE key='enabled'")
            guard try enabled.step() else { throw HistoryReaderError.unavailable }
            return HistoryReaderStatus(day: latest?.day ?? today, today: today, timezone: "Asia/Tokyo",
                                       empty: latest == nil, latestTime: latest?.time, sources: result, collectionEnabled: enabled.int64(0) != 0)
        }
    }

    public func detail(id: Int64, cancellation: HistoryReadCancellation? = nil) throws -> HistoryRecord {
        guard id > 0 else { throw HistoryReaderError.invalid("履歴IDが不正です。") }
        return try snapshot(cancellation) { db in
            let s = try db.query(Self.select + " WHERE v.id=?", [.integer(id)])
            guard try s.step() else { throw HistoryReaderError.notFound }
            return try Self.record(s)
        }
    }

    public func page(scope: Scope, query: String = "", cursor: String? = nil,
                     limit: Int = 200, ids: [Int64] = [], anchor: Int64? = nil,
                     cancellation: HistoryReadCancellation? = nil) throws -> HistoryPage {
        guard query.count <= 1000, (1...500).contains(limit), ids.count <= 2000,
              ids.allSatisfy({ $0 > 0 }), anchor == nil || anchor! > 0,
              cursor == nil || cursor!.count <= 128 else { throw HistoryReaderError.invalid("入力条件を確認してください。") }
        let terms = HistorySearch.normalize(query).split(whereSeparator: { $0.isWhitespace }).map(String.init)
        var whereSQL = "1=1"
        var args: [ReadValue] = []
        let candidate = terms.filter { $0.unicodeScalars.count >= 3 && !$0.unicodeScalars.contains(where: { $0.value == 0 }) }
            .max { $0.unicodeScalars.count < $1.unicodeScalars.count }
        if case let .range(start, end) = scope {
            guard start != nil || end != nil else { throw HistoryReaderError.invalid("日付が必要です。") }
            let startDate = try start.map(Self.parseDay)
            let endDate = try end.map(Self.parseDay)
            if let startDate, let endDate, endDate < startDate {
                throw HistoryReaderError.invalid("終了日は開始日以降にしてください。")
            }
            if let startDate {
                whereSQL += " AND v.visit_seconds>=?"
                args.append(.integer(Int64(startDate.timeIntervalSince1970)))
            }
            if let endDate {
                guard let upper = Self.calendar.date(byAdding: .day, value: 1, to: endDate) else { throw HistoryReaderError.invalid("日付が不正です。") }
                whereSQL += " AND v.visit_seconds<?"
                args.append(.integer(Int64(upper.timeIntervalSince1970)))
            }
        }
        for term in terms {
            whereSQL += " AND (instr(v.norm_title,?)>0 OR instr(v.norm_url,?)>0)"
            args += [.text(term), .text(term)]
        }
        let decoded = try cursor.map(Self.decodeCursor)
        return try snapshot(cancellation) { db in
            var valid: [HistoryRecord] = []
            for first in stride(from: 0, to: ids.count, by: 400) {
                let slice = Array(ids[first..<min(first + 400, ids.count)])
                let s = try db.query(Self.select + " WHERE " + whereSQL + " AND v.id IN (" + Array(repeating: "?", count: slice.count).joined(separator: ",") + ")", args + slice.map(ReadValue.integer))
                while try s.step() { valid.append(try Self.record(s)) }
            }
            var pageSQL = whereSQL
            var pageArgs = args
            // Revalidating explicit IDs above uses direct primary-key lookups.
            // Only the open-ended page query needs an FTS candidate set.
            if let candidate {
                pageSQL += " AND v.id IN (SELECT rowid FROM visit_search WHERE visit_search MATCH ?)"
                pageArgs.append(.text("\"" + candidate.replacingOccurrences(of: "\"", with: "\"\"") + "\""))
            }
            if let anchor {
                let target = try db.query("SELECT v.visit_seconds,v.visit_fraction,v.id FROM visits v JOIN sources s ON s.id=v.source_id WHERE " + whereSQL + " AND v.id=?", args + [.integer(anchor)])
                guard try target.step() else { throw HistoryReaderError.notFound }
                let key = (target.int64(0), target.double(1), target.int64(2))
                let before = try db.query("SELECT v.visit_seconds,v.visit_fraction,v.id FROM visits v JOIN sources s ON s.id=v.source_id WHERE " + whereSQL + " AND (v.visit_seconds,v.visit_fraction,v.id)>(?,?,?) ORDER BY v.visit_seconds,v.visit_fraction,v.id LIMIT 15", args + [.integer(key.0), .real(key.1), .integer(key.2)])
                var edge = key
                while try before.step() { edge = (before.int64(0), before.double(1), before.int64(2)) }
                pageSQL += " AND (v.visit_seconds,v.visit_fraction,v.id)<=(?,?,?)"
                pageArgs += [.integer(edge.0), .real(edge.1), .integer(edge.2)]
            }
            if let decoded {
                pageSQL += " AND (v.visit_seconds,v.visit_fraction,v.id)<(?,?,?)"
                pageArgs += [.integer(decoded.seconds), .real(decoded.fraction), .integer(decoded.id)]
            }
            let s = try db.query(Self.select + " WHERE " + pageSQL + " ORDER BY v.visit_seconds DESC,v.visit_fraction DESC,v.id DESC LIMIT ?", pageArgs + [.integer(Int64(limit + 1))])
            var rows: [(HistoryRecord, Cursor)] = []
            while try s.step() {
                let record = try Self.record(s)
                rows.append((record, Cursor(seconds: s.int64(3), fraction: s.double(4), id: record.id)))
            }
            let next = rows.count > limit ? try Self.encodeCursor(rows[limit - 1].1) : nil
            let items = Array(rows.prefix(limit)).map(\.0)
            let icons = try Self.icons(db, records: items + valid)
            return HistoryPage(items: items, valid: valid, cursor: next, icons: icons)
        }
    }

    private func snapshot<T>(_ cancellation: HistoryReadCancellation?, body: (ReadDB) throws -> T) throws -> T {
        let deadline = ReadDeadline(cancellation: cancellation)
        let db = try ReadDB(path: databasePath, deadline: deadline)
        try db.exec("BEGIN")
        defer { try? db.exec("ROLLBACK") }
        let version = try db.query("PRAGMA user_version")
        guard try version.step(), (4...5).contains(version.int64(0)) else { throw HistoryReaderError.unavailable }
        return try body(db)
    }

    private static func icons(_ db: ReadDB, records: [HistoryRecord]) throws -> [String:String] {
        let sites = Set(records.compactMap { $0.site?.lowercased() })
        var result: [String:String] = [:]
        var total = 0
        for site in sites.sorted() {
            let s = try db.query("SELECT mime,image FROM icons WHERE site=? LIMIT 1", [.text(site)])
            guard try s.step(), let mime = s.text(0), ["image/png", "image/jpeg", "image/gif", "image/x-icon", "image/webp"].contains(mime), let data = s.blob(1), data.count <= 32768 else { continue }
            let value = "data:\(mime);base64,\(data.base64EncodedString())"
            guard total + value.utf8.count <= 262_144 else { break }
            result[site] = value; total += value.utf8.count
        }
        return result
    }

    private static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone; return calendar
    }
    private static func formatter() -> DateFormatter {
        let f = DateFormatter(); f.calendar = calendar; f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = zone; f.dateFormat = "yyyy-MM-dd"; f.isLenient = false; return f
    }
    private static func day(_ date: Date) -> String { formatter().string(from: date) }
    private static func parseDay(_ text: String) throws -> Date {
        let f = formatter()
        guard text.count == 10, let date = f.date(from: text), f.string(from: date) == text,
              text <= "9999-12-30" else { throw HistoryReaderError.invalid("日付が不正です。") }
        return date
    }
    private static func record(_ s: ReadStatement) throws -> HistoryRecord {
        guard let url = s.text(1), let title = s.text(2), let browser = s.text(5), let profile = s.text(6), let source = s.text(7) else { throw HistoryReaderError.unavailable }
        let stamp = Double(s.int64(3)) + s.double(4)
        guard stamp.isFinite, abs(stamp) < 253_402_300_800 else { throw HistoryReaderError.unavailable }
        let date = Date(timeIntervalSince1970: stamp)
        let iso = ISO8601DateFormatter(); iso.timeZone = zone; iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return HistoryRecord(id: s.int64(0), url: url, title: title, visitTime: stamp,
            browserType: browser, profileName: profile, site: URL(string: url)?.host?.lowercased(), device: nil,
            time: iso.string(from: date), day: day(date), sourceID: source, nativeVisitID: s.int64(8))
    }
    private struct Cursor: Codable { let seconds: Int64; let fraction: Double; let id: Int64 }
    private static func encodeCursor(_ cursor: Cursor) throws -> String {
        try JSONEncoder().encode(cursor).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    private static func decodeCursor(_ text: String) throws -> Cursor {
        let value = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        guard let data = Data(base64Encoded: value + String(repeating: "=", count: (4 - value.count % 4) % 4)),
              let result = try? JSONDecoder().decode(Cursor.self, from: data), result.id > 0,
              result.fraction.isFinite, result.fraction >= 0, result.fraction < 1 else { throw HistoryReaderError.invalid("継続位置が不正です。") }
        return result
    }
}

private final class ReadDeadline {
    let deadline = ProcessInfo.processInfo.systemUptime + 8
    let cancellation: HistoryReadCancellation?
    init(cancellation: HistoryReadCancellation?) { self.cancellation = cancellation }
    var expired: Bool { ProcessInfo.processInfo.systemUptime > deadline || (cancellation?.isCancelled ?? false) }
}
private enum ReadValue { case text(String), integer(Int64), real(Double) }
private final class ReadDB {
    let handle: OpaquePointer
    let deadline: ReadDeadline
    init(path: String, deadline: ReadDeadline) throws {
        self.deadline = deadline
        var ptr: OpaquePointer?
        guard sqlite3_open_v2(path, &ptr, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let ptr else { if let ptr { sqlite3_close(ptr) }; throw HistoryReaderError.unavailable }
        handle = ptr; sqlite3_busy_timeout(ptr, 2000)
        sqlite3_progress_handler(ptr, 1000, { context in
            guard let context else { return 1 }
            return Unmanaged<ReadDeadline>.fromOpaque(context).takeUnretainedValue().expired ? 1 : 0
        }, Unmanaged.passUnretained(deadline).toOpaque())
        try exec("PRAGMA query_only=ON")
    }
    deinit { sqlite3_progress_handler(handle, 0, nil, nil); sqlite3_close(handle) }
    func exec(_ sql: String) throws { guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else { throw HistoryReaderError.unavailable } }
    func query(_ sql: String, _ args: [ReadValue] = []) throws -> ReadStatement { try ReadStatement(db: handle, sql: sql, args: args) }
}
private final class ReadStatement {
    let handle: OpaquePointer
    init(db: OpaquePointer, sql: String, args: [ReadValue]) throws {
        var ptr: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &ptr, nil) == SQLITE_OK, let ptr else { throw HistoryReaderError.unavailable }
        handle = ptr
        for (n, value) in args.enumerated() {
            let index = Int32(n + 1)
            let result: Int32
            switch value {
            case .text(let s): result = s.withCString { sqlite3_bind_text(ptr, index, $0, Int32(s.utf8.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
            case .integer(let i): result = sqlite3_bind_int64(ptr, index, i)
            case .real(let d): result = sqlite3_bind_double(ptr, index, d)
            }
            guard result == SQLITE_OK else { sqlite3_finalize(ptr); throw HistoryReaderError.unavailable }
        }
    }
    deinit { sqlite3_finalize(handle) }
    func step() throws -> Bool {
        let result = sqlite3_step(handle)
        if result == SQLITE_ROW { return true }; if result == SQLITE_DONE { return false }; throw HistoryReaderError.unavailable
    }
    func text(_ n: Int32) -> String? {
        guard sqlite3_column_type(handle, n) == SQLITE_TEXT, let p = sqlite3_column_text(handle, n) else { return nil }
        return String(bytes: UnsafeBufferPointer(start: p, count: Int(sqlite3_column_bytes(handle, n))), encoding: .utf8)
    }
    func blob(_ n: Int32) -> Data? {
        guard sqlite3_column_type(handle, n) == SQLITE_BLOB, let p = sqlite3_column_blob(handle, n) else { return nil }
        return Data(bytes: p, count: Int(sqlite3_column_bytes(handle, n)))
    }
    func int64(_ n: Int32) -> Int64 { sqlite3_column_int64(handle, n) }
    func double(_ n: Int32) -> Double { sqlite3_column_double(handle, n) }
    func optionalDouble(_ n: Int32) -> Double? { sqlite3_column_type(handle, n) == SQLITE_NULL ? nil : double(n) }
}
