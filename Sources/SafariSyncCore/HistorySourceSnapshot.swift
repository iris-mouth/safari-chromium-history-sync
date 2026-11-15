import CSQLite
import Darwin
import Foundation

/// Native visit identifiers and timestamps are retained without rounding.
public struct HistorySourceSnapshot: Sendable {
    public enum Browser: String, Codable, Sendable { case safari, chromium }
    public struct Visit: Sendable, Equatable {
        public let id: Int64
        public let url: String
        public let title: String?
        public let nativeTime: NativeTime
    }
    public enum NativeTime: Sendable, Equatable {
        case safari(Double)       // seconds since 2001
        case chromium(Int64)      // microseconds since 1601
    }
    public let databaseIdentity: String
    public let visits: [Visit]
}

public enum HistorySourceReadError: Error {
    case unavailable(String)
    case sqlite(code: Int32, message: String)
    case replacedDuringRead
    case invalidRow
    case snapshotUnavailable(String)
}

public enum HistorySourceReader {
    public static func read(path: String, browser: HistorySourceSnapshot.Browser) throws -> HistorySourceSnapshot {
        var visits: [HistorySourceSnapshot.Visit] = []
        let identity = try scan(path: path, browser: browser, onStart: { _, _ in }, onBatch: { visits += $0 })
        return HistorySourceSnapshot(databaseIdentity: identity, visits: visits)
    }

    /// Delivers bounded batches from one consistent read-only source transaction.
    /// Batches do not constitute a complete scan until this function returns.
    @discardableResult
    public static func scan(path: String, browser: HistorySourceSnapshot.Browser,
                            viewerOrigins: [URL] = [], batchSize: Int = 500,
                            onStart: (String, Bool) throws -> Void,
                            onBatch: ([HistorySourceSnapshot.Visit]) throws -> Void) throws -> String {
        do {
            return try scanOnce(path: path, browser: browser, viewerOrigins: viewerOrigins, batchSize: batchSize, immutable: false, onStart: onStart, onBatch: onBatch)
        } catch HistorySourceReadError.sqlite(let code, _) where code & 0xff == SQLITE_CANTOPEN && walIsAbsent(path) {
            // A closed WAL-mode browser can lack -wal/-shm. Immutable mode does
            // not create sidecars, but its results must stay staged until the
            // source and sidecar absence have been checked after the full scan.
            return try scanOnce(path: path, browser: browser, viewerOrigins: viewerOrigins, batchSize: batchSize, immutable: true, onStart: onStart, onBatch: onBatch)
        } catch HistorySourceReadError.sqlite(let code, _) where browser == .chromium && (code & 0xff == SQLITE_BUSY || code & 0xff == SQLITE_LOCKED) {
            // Chromium may retain an exclusive lock for its whole session. A
            // tightly checked, in-memory rollback-mode snapshot is used only
            // before the journal has been synced and neither file changes.
            return try scanExclusiveChromium(path: path, viewerOrigins: viewerOrigins, batchSize: batchSize, onStart: onStart, onBatch: onBatch)
        }
    }

    private static func scanOnce(path: String, browser: HistorySourceSnapshot.Browser,
                                 viewerOrigins: [URL], batchSize: Int, immutable: Bool,
                                 onStart: (String, Bool) throws -> Void,
                                 onBatch: ([HistorySourceSnapshot.Visit]) throws -> Void) throws -> String {
        guard batchSize > 0 else { throw HistorySourceReadError.invalidRow }
        let before = try identity(path)
        let metadata = try stamp(path)
        guard !immutable || walIsAbsent(path) else { throw HistorySourceReadError.replacedDuringRead }
        let sqlitePath = immutable ? URL(fileURLWithPath: path).absoluteString + "?immutable=1" : path
        let flags = SQLITE_OPEN_READONLY | (immutable ? SQLITE_OPEN_URI : 0)
        var handle: OpaquePointer?
        guard sqlite3_open_v2(sqlitePath, &handle, flags, nil) == SQLITE_OK, let db = handle else {
            if let handle { sqlite3_close(handle) }
            throw HistorySourceReadError.unavailable(path)
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 1000)
        try execute(db, "PRAGMA query_only=ON")
        try execute(db, "BEGIN")
        defer { sqlite3_exec(db, "ROLLBACK", nil, nil, nil) }
        try scanRows(db: db, browser: browser, viewerOrigins: viewerOrigins, batchSize: batchSize,
                     onStart: { try onStart(before, !immutable) }, onBatch: onBatch)
        guard try identity(path) == before, try stamp(path) == metadata,
              !immutable || walIsAbsent(path) else { throw HistorySourceReadError.replacedDuringRead }
        try execute(db, "COMMIT")
        return before
    }

    private static func scanRows(db: OpaquePointer, browser: HistorySourceSnapshot.Browser,
                                 viewerOrigins: [URL], batchSize: Int, onStart: () throws -> Void,
                                 onBatch: ([HistorySourceSnapshot.Visit]) throws -> Void) throws {
        let sql: String
        switch browser {
        case .safari:
            sql = "SELECT v.id, i.url, v.title, v.visit_time FROM history_visits v LEFT JOIN history_items i ON i.id=v.history_item"
        case .chromium:
            sql = "SELECT v.id, u.url, u.title, v.visit_time FROM visits v LEFT JOIN urls u ON u.id=v.url"
        }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw HistorySourceReadError.sqlite(code: sqlite3_extended_errcode(db), message: String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }
        try onStart()
        var visits: [HistorySourceSnapshot.Visit] = []
        visits.reserveCapacity(batchSize)
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { break }
            guard result == SQLITE_ROW else { throw HistorySourceReadError.sqlite(code: sqlite3_extended_errcode(db), message: String(cString: sqlite3_errmsg(db))) }
            guard sqlite3_column_type(statement, 0) == SQLITE_INTEGER,
                  let urlString = text(statement, 1), sqlite3_column_type(statement, 3) != SQLITE_NULL else {
                throw HistorySourceReadError.invalidRow
            }
            guard let url = URL(string: urlString), let scheme = url.scheme?.lowercased(),
                  (scheme == "http" || scheme == "https"), url.host != nil else { continue }
            if isProductURL(url, viewerOrigins: viewerOrigins) { continue }
            let title = text(statement, 2)
            if sqlite3_column_type(statement, 2) != SQLITE_NULL && title == nil { throw HistorySourceReadError.invalidRow }
            let time: HistorySourceSnapshot.NativeTime
            switch browser {
            case .safari:
                let type = sqlite3_column_type(statement, 3)
                guard type == SQLITE_FLOAT || type == SQLITE_INTEGER else { throw HistorySourceReadError.invalidRow }
                let value = sqlite3_column_double(statement, 3)
                guard value.isFinite else { throw HistorySourceReadError.invalidRow }
                time = .safari(value)
            case .chromium:
                guard sqlite3_column_type(statement, 3) == SQLITE_INTEGER else { throw HistorySourceReadError.invalidRow }
                time = .chromium(sqlite3_column_int64(statement, 3))
            }
            visits.append(.init(id: sqlite3_column_int64(statement, 0), url: urlString, title: title, nativeTime: time))
            if visits.count >= batchSize { try onBatch(visits); visits.removeAll(keepingCapacity: true) }
        }
        if !visits.isEmpty { try onBatch(visits) }
    }

    private static func scanExclusiveChromium(path: String, viewerOrigins: [URL], batchSize: Int,
                                               onStart: (String, Bool) throws -> Void,
                                               onBatch: ([HistorySourceSnapshot.Visit]) throws -> Void) throws -> String {
        guard batchSize > 0 else { throw HistorySourceReadError.invalidRow }
        guard walIsAbsent(path) else { throw HistorySourceReadError.snapshotUnavailable("active WAL") }
        let source = open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard source >= 0 else { throw HistorySourceReadError.unavailable(path) }
        defer { Darwin.close(source) }
        let journalPath = path + "-journal"
        let journal = open(journalPath, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard journal >= 0 else { throw HistorySourceReadError.snapshotUnavailable("journal unavailable") }
        defer { Darwin.close(journal) }
        let sourceStamp = try stamp(source)
        let journalStamp = try stamp(journal)
        guard try stamp(path) == sourceStamp, try stamp(journalPath) == journalStamp else { throw HistorySourceReadError.replacedDuringRead }
        guard try inactiveJournal(journal, size: journalStamp[2]) else { throw HistorySourceReadError.snapshotUnavailable("transaction active") }
        let size = sourceStamp[2]
        let maxBytes = min(Int64(ProcessInfo.processInfo.physicalMemory / 4), Int64(2_147_483_648))
        guard size >= 100, size <= maxBytes, size <= Int64(Int.max),
              let buffer = sqlite3_malloc64(UInt64(size)) else { throw HistorySourceReadError.snapshotUnavailable("snapshot exceeds memory budget") }
        defer { sqlite3_free(buffer) }
        var offset = 0
        while offset < Int(size) {
            let readCount = Darwin.read(source, buffer.advanced(by: offset), min(1_048_576, Int(size) - offset))
            if readCount < 0 && errno == EINTR { continue }
            guard readCount > 0 else { throw HistorySourceReadError.replacedDuringRead }
            offset += readCount
        }
        // A second byte-for-byte pass also rejects a torn copy if the browser
        // writes while it is being read. Metadata and journal checks below
        // still have to match; structural validation alone is insufficient.
        var verify = [UInt8](repeating: 0, count: min(1_048_576, Int(size)))
        offset = 0
        while offset < Int(size) {
            let amount = min(verify.count, Int(size) - offset)
            let readCount = verify.withUnsafeMutableBytes { pread(source, $0.baseAddress, amount, off_t(offset)) }
            if readCount < 0 && errno == EINTR { continue }
            guard readCount == amount,
                  verify.withUnsafeBytes({ memcmp($0.baseAddress, buffer.advanced(by: offset), amount) == 0 }) else {
                throw HistorySourceReadError.replacedDuringRead
            }
            offset += readCount
        }
        let bytes = buffer.assumingMemoryBound(to: UInt8.self)
        let signature = Array(UnsafeBufferPointer(start: bytes, count: 16))
        guard signature == Array("SQLite format 3\0".utf8), bytes[18] == 1, bytes[19] == 1 else {
            throw HistorySourceReadError.snapshotUnavailable("not a rollback-mode database")
        }
        guard try stamp(source) == sourceStamp, try stamp(path) == sourceStamp,
              try stamp(journal) == journalStamp, try stamp(journalPath) == journalStamp,
              try inactiveJournal(journal, size: journalStamp[2]), walIsAbsent(path) else {
            throw HistorySourceReadError.replacedDuringRead
        }
        var memory: OpaquePointer?
        guard sqlite3_open_v2(":memory:", &memory, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK, let db = memory else {
            if let memory { sqlite3_close(memory) }
            throw HistorySourceReadError.unavailable(path)
        }
        defer { sqlite3_close(db) }
        let result = sqlite3_deserialize(db, "main", bytes, size, size, UInt32(SQLITE_DESERIALIZE_READONLY))
        guard result == SQLITE_OK else { throw HistorySourceReadError.sqlite(code: result, message: "snapshot unavailable") }
        let checkSQL = "PRAGMA quick_check(1)"
        var check: OpaquePointer?
        guard sqlite3_prepare_v2(db, checkSQL, -1, &check, nil) == SQLITE_OK, let check else {
            throw HistorySourceReadError.sqlite(code: sqlite3_extended_errcode(db), message: String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(check) }
        guard sqlite3_step(check) == SQLITE_ROW, text(check, 0) == "ok", sqlite3_step(check) == SQLITE_DONE else {
            throw HistorySourceReadError.replacedDuringRead
        }
        let sourceIdentity = "\(sourceStamp[0]):\(sourceStamp[1])"
        // The source has been checked before opening this independent in-memory
        // image. Subsequent browser writes cannot change the scanned image, so
        // initial batches may be displayed just like a locked read transaction.
        try scanRows(db: db, browser: .chromium, viewerOrigins: viewerOrigins, batchSize: batchSize,
                     onStart: { try onStart(sourceIdentity, true) }, onBatch: onBatch)
        return sourceIdentity
    }

    private static func inactiveJournal(_ descriptor: Int32, size: Int64) throws -> Bool {
        if size == 0 { return true }
        guard size >= 28 else { return false }
        var header = [UInt8](repeating: 0, count: 28)
        let count = header.withUnsafeMutableBytes { pread(descriptor, $0.baseAddress, $0.count, 0) }
        guard count == header.count else { throw HistorySourceReadError.replacedDuringRead }
        // SQLite leaves the magic and record count zero until journal pages
        // have been synced; it does not spill database pages before then.
        // The remaining header contains ordinary transaction metadata.
        return header.prefix(12).allSatisfy { $0 == 0 }
    }

    private static func stamp(_ descriptor: Int32) throws -> [Int64] {
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { throw HistorySourceReadError.replacedDuringRead }
        return [Int64(info.st_dev), Int64(info.st_ino), info.st_size,
                Int64(info.st_mtimespec.tv_sec), Int64(info.st_mtimespec.tv_nsec),
                Int64(info.st_ctimespec.tv_sec), Int64(info.st_ctimespec.tv_nsec)]
    }

    private static func isProductURL(_ url: URL, viewerOrigins: [URL]) -> Bool {
        if SafariSyncAssist.isControlURL(url) { return true }
        if url.scheme?.lowercased() == "https", url.host?.lowercased() == "example.com",
           url.user == nil, url.password == nil, url.port == nil, url.query == nil, url.fragment == nil {
            let parts = url.path.split(separator: "/")
            if parts.count == 2, parts[0] == "safari-history-sync-probe", UUID(uuidString: String(parts[1])) != nil { return true }
        }
        func effectivePort(_ value: URL) -> Int? {
            value.port ?? (value.scheme?.lowercased() == "https" ? 443 : value.scheme?.lowercased() == "http" ? 80 : nil)
        }
        return (url.path.isEmpty || url.path == "/") && viewerOrigins.contains {
            $0.scheme?.lowercased() == url.scheme?.lowercased() && $0.host?.lowercased() == url.host?.lowercased() && effectivePort($0) == effectivePort(url)
        }
    }

    private static func text(_ statement: OpaquePointer, _ column: Int32) -> String? {
        guard sqlite3_column_type(statement, column) == SQLITE_TEXT, let bytes = sqlite3_column_text(statement, column) else { return nil }
        return String(bytes: UnsafeBufferPointer(start: bytes, count: Int(sqlite3_column_bytes(statement, column))), encoding: .utf8)
    }
    private static func walIsAbsent(_ path: String) -> Bool {
        var info = stat()
        return lstat(path + "-wal", &info) != 0 && errno == ENOENT
    }
    private static func stamp(_ path: String) throws -> [Int64] {
        var info = stat()
        guard stat(path, &info) == 0 else { throw HistorySourceReadError.unavailable(path) }
        return [Int64(info.st_dev), Int64(info.st_ino), info.st_size,
                Int64(info.st_mtimespec.tv_sec), Int64(info.st_mtimespec.tv_nsec),
                Int64(info.st_ctimespec.tv_sec), Int64(info.st_ctimespec.tv_nsec)]
    }
    private static func identity(_ path: String) throws -> String {
        var info = stat()
        guard stat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { throw HistorySourceReadError.unavailable(path) }
        return "\(info.st_dev):\(info.st_ino)"
    }
    private static func execute(_ db: OpaquePointer, _ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw HistorySourceReadError.sqlite(code: sqlite3_extended_errcode(db), message: String(cString: sqlite3_errmsg(db))) }
    }
}
