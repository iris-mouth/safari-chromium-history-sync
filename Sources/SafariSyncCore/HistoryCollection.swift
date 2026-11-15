import CSQLite
import Darwin
import Foundation
import HistoryViewCore

public struct HistoryCollectionSource: Codable, Equatable, Sendable {
    public var id: String
    public var browser: HistorySourceSnapshot.Browser
    public var browserType: String
    public var profileName: String
    public var path: String
    public init(id: String, browser: HistorySourceSnapshot.Browser, browserType: String, profileName: String, path: String) {
        self.id = id; self.browser = browser; self.browserType = browserType; self.profileName = profileName; self.path = path
    }
}

public struct HistoryCollectionStatus: Codable, Equatable, Sendable {
    public let id: String
    public let browserType: String
    public let profileName: String
    public let state: String
    public let lastSuccess: Double?
    public let error: String?
    public let count: Int64
}

public enum HistoryCollectionError: Error {
    case invalidSource
    case unsafeDirectory
    case incompatibleDatabase
    case invalidTime
    case sqlite(String)
}

/// Owns the viewing database. This object never accesses sync state or queues.
/// All mutations are serialized; each source can fail without affecting others.
public final class HistoryCollector: @unchecked Sendable {
    private let lock = NSLock()
    private let cancellationLock = NSLock()
    private var cancellationVersion: UInt64 = 0
    private let databasePath: String
    private let db: HistoryWriteDB
    private let viewerOrigins: [URL]

    public init(databaseURL: URL, viewerOrigins: [URL] = []) throws {
        self.viewerOrigins = viewerOrigins
        self.databasePath = databaseURL.path
        let directory = databaseURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var info = stat()
        guard lstat(directory.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR,
              info.st_uid == getuid(), chmod(directory.path, 0o700) == 0 else { throw HistoryCollectionError.unsafeDirectory }
        let fd = open(databaseURL.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        if fd >= 0 { Darwin.close(fd) }
        else if errno != EEXIST { throw HistoryCollectionError.unsafeDirectory }
        guard lstat(databaseURL.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == getuid(), chmod(databaseURL.path, 0o600) == 0 else { throw HistoryCollectionError.unsafeDirectory }
        db = try HistoryWriteDB(path: databaseURL.path)
        let version = try db.scalarInt("PRAGMA user_version")
        guard (0...4).contains(version) else { throw HistoryCollectionError.incompatibleDatabase }
        if version == 0 {
            // Refuse to initialize an unrelated or partially-created database.
            guard try db.scalarInt("SELECT count(*) FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'") == 0 else {
                throw HistoryCollectionError.incompatibleDatabase
            }
            try db.exec("""
                PRAGMA journal_mode=WAL;
                PRAGMA foreign_keys=ON;
                BEGIN IMMEDIATE;
                CREATE TABLE sources (
                  id TEXT PRIMARY KEY, browser TEXT NOT NULL, browser_type TEXT NOT NULL,
                  profile_name TEXT NOT NULL, path TEXT NOT NULL, state TEXT NOT NULL,
                  db_identity TEXT, generation TEXT, last_success REAL, error TEXT
                );
                CREATE TABLE visits (
                  id INTEGER PRIMARY KEY AUTOINCREMENT, source_id TEXT NOT NULL REFERENCES sources(id) ON DELETE CASCADE,
                  generation TEXT NOT NULL, native_id INTEGER NOT NULL, url TEXT NOT NULL, title TEXT,
                  native_real REAL, native_int INTEGER, visit_seconds INTEGER NOT NULL, visit_fraction REAL NOT NULL,
                  norm_title TEXT NOT NULL, norm_url TEXT NOT NULL,
                  UNIQUE(source_id, native_id)
                );
                CREATE INDEX visits_time ON visits(visit_seconds DESC, visit_fraction DESC, id DESC);
                CREATE TABLE scan_visits (
                  source_id TEXT NOT NULL, native_id INTEGER NOT NULL, url TEXT NOT NULL, title TEXT,
                  native_real REAL, native_int INTEGER, visit_seconds INTEGER NOT NULL, visit_fraction REAL NOT NULL,
                  norm_title TEXT NOT NULL, norm_url TEXT NOT NULL, PRIMARY KEY(source_id,native_id)
                );
                CREATE TABLE icons (source_id TEXT NOT NULL REFERENCES sources(id) ON DELETE CASCADE, site TEXT NOT NULL, mime TEXT NOT NULL, image BLOB NOT NULL, PRIMARY KEY(source_id,site));
                CREATE INDEX icons_site ON icons(site);
                CREATE TABLE collection_settings (key TEXT PRIMARY KEY, value TEXT NOT NULL);
                INSERT INTO collection_settings VALUES('enabled','0');
                CREATE VIRTUAL TABLE visit_search USING fts5(norm_title,norm_url,content='visits',content_rowid='id',tokenize='trigram case_sensitive 1');
                CREATE TRIGGER visits_search_insert AFTER INSERT ON visits BEGIN
                  INSERT INTO visit_search(rowid,norm_title,norm_url) VALUES(new.id,new.norm_title,new.norm_url);
                END;
                CREATE TRIGGER visits_search_delete AFTER DELETE ON visits BEGIN
                  INSERT INTO visit_search(visit_search,rowid,norm_title,norm_url) VALUES('delete',old.id,old.norm_title,old.norm_url);
                END;
                CREATE TRIGGER visits_search_update AFTER UPDATE OF norm_title,norm_url ON visits BEGIN
                  INSERT INTO visit_search(visit_search,rowid,norm_title,norm_url) VALUES('delete',old.id,old.norm_title,old.norm_url);
                  INSERT INTO visit_search(rowid,norm_title,norm_url) VALUES(new.id,new.norm_title,new.norm_url);
                END;
                PRAGMA user_version=4;
                COMMIT;
                """)
        } else {
            try db.exec("PRAGMA foreign_keys=ON; PRAGMA journal_mode=WAL")
            if version == 1 {
                try db.exec("BEGIN IMMEDIATE; CREATE TABLE collection_settings(key TEXT PRIMARY KEY,value TEXT NOT NULL); INSERT INTO collection_settings VALUES('enabled','0'); PRAGMA user_version=2; COMMIT")
            }
            if version < 3 {
                try db.exec("BEGIN IMMEDIATE; CREATE TABLE icons(source_id TEXT NOT NULL REFERENCES sources(id) ON DELETE CASCADE,site TEXT NOT NULL,mime TEXT NOT NULL,image BLOB NOT NULL,PRIMARY KEY(source_id,site)); CREATE INDEX icons_site ON icons(site); PRAGMA user_version=3; COMMIT")
            }
            if version < 4 {
                try db.exec("""
                    BEGIN IMMEDIATE;
                    CREATE VIRTUAL TABLE visit_search USING fts5(norm_title,norm_url,content='visits',content_rowid='id',tokenize='trigram case_sensitive 1');
                    CREATE TRIGGER visits_search_insert AFTER INSERT ON visits BEGIN
                      INSERT INTO visit_search(rowid,norm_title,norm_url) VALUES(new.id,new.norm_title,new.norm_url);
                    END;
                    CREATE TRIGGER visits_search_delete AFTER DELETE ON visits BEGIN
                      INSERT INTO visit_search(visit_search,rowid,norm_title,norm_url) VALUES('delete',old.id,old.norm_title,old.norm_url);
                    END;
                    CREATE TRIGGER visits_search_update AFTER UPDATE OF norm_title,norm_url ON visits BEGIN
                      INSERT INTO visit_search(visit_search,rowid,norm_title,norm_url) VALUES('delete',old.id,old.norm_title,old.norm_url);
                      INSERT INTO visit_search(rowid,norm_title,norm_url) VALUES(new.id,new.norm_title,new.norm_url);
                    END;
                    INSERT INTO visit_search(visit_search) VALUES('rebuild');
                    PRAGMA user_version=4;
                    COMMIT;
                    """)
            }
        }
    }

    public func setEnabled(_ enabled: Bool) throws {
        if !enabled { cancelCurrent() }
        try lock.withLock { try db.prepare("UPDATE collection_settings SET value=? WHERE key='enabled'").run([.text(enabled ? "1" : "0")]) }
    }
    public func isEnabled() throws -> Bool {
        let reader = try HistoryWriteDB(path: databasePath, readOnly: true)
        return try reader.scalarInt("SELECT value='1' FROM collection_settings WHERE key='enabled'") != 0
    }
    private func cancelCurrent() { cancellationLock.withLock { cancellationVersion &+= 1 } }
    private func cancelled(_ version: UInt64) -> Bool { cancellationLock.withLock { cancellationVersion != version } }
    public func setViewerOrigin(_ value: String?) throws {
        cancelCurrent()
        try lock.withLock {
            var origins = Set(try storedViewerOrigins())
            if let value, !value.isEmpty {
                guard let url = URL(string: value), ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else { throw HistoryCollectionError.invalidSource }
                origins.insert(value)
            }
            let history = String(decoding: try JSONEncoder().encode(origins.sorted()), as: UTF8.self)
            try db.transaction {
                if let value, !value.isEmpty {
                    try db.prepare("INSERT INTO collection_settings(key,value) VALUES('viewer_origin',?) ON CONFLICT(key) DO UPDATE SET value=excluded.value").run([.text(value)])
                } else { try db.exec("DELETE FROM collection_settings WHERE key='viewer_origin'") }
                try db.prepare("INSERT INTO collection_settings(key,value) VALUES('viewer_origin_history',?) ON CONFLICT(key) DO UPDATE SET value=excluded.value").run([.text(history)])
            }
        }
    }

    /// Keep earlier product addresses excluded after a Serve cutover. Including
    /// the current value also migrates databases made before this list existed.
    private func storedViewerOrigins() throws -> [String] {
        let statement = try db.prepare("SELECT key,value FROM collection_settings WHERE key IN ('viewer_origin','viewer_origin_history')")
        var origins = Set<String>()
        while try statement.step() {
            guard let key = statement.text(0), let value = statement.text(1) else { continue }
            if key == "viewer_origin" { origins.insert(value) }
            else if let data = value.data(using: .utf8), let history = try? JSONDecoder().decode([String].self, from: data) {
                origins.formUnion(history)
            }
        }
        return origins.sorted()
    }

    /// This is the sole operation that removes deselected sources. A temporarily
    /// missing browser/profile is not a selection change.
    public func configure(_ sources: [HistoryCollectionSource]) throws {
        cancelCurrent()
        try lock.withLock {
            guard Set(sources.map(\.id)).count == sources.count,
                  sources.allSatisfy({ !$0.id.isEmpty && !$0.path.isEmpty && !$0.browserType.isEmpty }) else { throw HistoryCollectionError.invalidSource }
            try db.transaction {
                try db.exec("CREATE TEMP TABLE IF NOT EXISTS selected_source_ids(id TEXT PRIMARY KEY); DELETE FROM selected_source_ids")
                let keep = try db.prepare("INSERT INTO selected_source_ids VALUES (?)")
                let insert = try db.prepare("""
                    INSERT INTO sources(id,browser,browser_type,profile_name,path,state)
                    VALUES(?,?,?,?,?,'pending') ON CONFLICT(id) DO UPDATE SET
                    browser=excluded.browser,browser_type=excluded.browser_type,
                    profile_name=excluded.profile_name,
                    state=CASE WHEN sources.path<>excluded.path OR sources.browser<>excluded.browser THEN 'pending' ELSE sources.state END,
                    path=excluded.path
                    """)
                for source in sources {
                    try keep.run([.text(source.id)])
                    try insert.run([.text(source.id), .text(source.browser.rawValue), .text(source.browserType), .text(source.profileName), .text(source.path)])
                }
                try db.exec("DELETE FROM scan_visits WHERE source_id NOT IN (SELECT id FROM selected_source_ids)")
                try db.exec("DELETE FROM sources WHERE id NOT IN (SELECT id FROM selected_source_ids)")
            }
        }
    }

    public func sources() throws -> [HistoryCollectionSource] {
        try Self.readSources(HistoryWriteDB(path: databasePath, readOnly: true))
    }

    public func statuses() throws -> [HistoryCollectionStatus] {
        let reader = try HistoryWriteDB(path: databasePath, readOnly: true)
        return try {
            let s = try reader.prepare("""
                SELECT s.id,s.browser_type,s.profile_name,s.state,s.last_success,s.error,
                       (SELECT count(*) FROM visits v WHERE v.source_id=s.id)
                FROM sources s ORDER BY s.id
                """)
            var result: [HistoryCollectionStatus] = []
            while try s.step() {
                result.append(.init(id: s.text(0)!, browserType: s.text(1)!, profileName: s.text(2)!,
                    state: s.text(3)!, lastSuccess: s.optionalDouble(4), error: s.text(5), count: s.int64(6)))
            }
            return result
        }()
    }

    /// Runs a full scan for every selected source. Failures are recorded and do
    /// not stop the other sources. Call again to retry.
    public func collectAll() throws {
        let version = cancellationLock.withLock { cancellationVersion }
        try lock.withLock {
            for source in try Self.readSources(db) {
                if cancelled(version) { return }
                do {
                    try collect(source, cancellationVersion: version)
                    if source.browser == .chromium && !cancelled(version) { try? collectChromiumIcons(source, cancellationVersion: version) }
                } catch HistorySourceReadError.waitingForUnlock {
                    try db.transaction {
                        try db.prepare("DELETE FROM scan_visits WHERE source_id=?").run([.text(source.id)])
                        try db.prepare("UPDATE sources SET state='waiting',error=NULL WHERE id=?").run([.text(source.id)])
                    }
                } catch HistoryScanInterrupted.cancelled {
                    try db.transaction {
                        try db.prepare("DELETE FROM scan_visits WHERE source_id=?").run([.text(source.id)])
                        try db.prepare("UPDATE sources SET state='interrupted',error=NULL WHERE id=?").run([.text(source.id)])
                    }
                    return
                } catch {
                    try db.transaction {
                        try db.prepare("DELETE FROM scan_visits WHERE source_id=?").run([.text(source.id)])
                        try db.prepare("UPDATE sources SET state='failed',error=? WHERE id=?")
                            .run([.text(String(describing: error)), .text(source.id)])
                    }
                }
            }
        }
    }

    private static func readSources(_ db: HistoryWriteDB) throws -> [HistoryCollectionSource] {
        let s = try db.prepare("SELECT id,browser,browser_type,profile_name,path FROM sources ORDER BY id")
        var result: [HistoryCollectionSource] = []
        while try s.step() {
            guard let id = s.text(0), let name = s.text(1), let browser = HistorySourceSnapshot.Browser(rawValue: name),
                  let type = s.text(2), let profile = s.text(3), let path = s.text(4) else { throw HistoryCollectionError.incompatibleDatabase }
            result.append(.init(id: id, browser: browser, browserType: type, profileName: profile, path: path))
        }
        return result
    }

    private func collect(_ source: HistoryCollectionSource, cancellationVersion: UInt64) throws {
        let state = try db.prepare("SELECT db_identity,generation,last_success FROM sources WHERE id=?")
        try state.bind([.text(source.id)])
        guard try state.step() else { throw HistoryCollectionError.invalidSource }
        let previousIdentity = state.text(0)
        var generation = state.text(1) ?? UUID().uuidString
        let firstImport = state.optionalDouble(2) == nil
        var scannedIdentity = ""
        var publishPartial = false
        let localOrigins = [URL(string: "http://127.0.0.1:8766")!, URL(string: "http://localhost:8766")!]
        let origins = viewerOrigins + localOrigins + (try storedViewerOrigins()).compactMap(URL.init(string:))
        try HistorySourceReader.scan(path: source.path, browser: source.browser, viewerOrigins: origins, onStart: { identity, stableSnapshot in
            scannedIdentity = identity
            publishPartial = firstImport && stableSnapshot
            try self.db.transaction {
                try self.db.prepare("DELETE FROM scan_visits WHERE source_id=?").run([.text(source.id)])
                if firstImport && previousIdentity != nil && previousIdentity != identity {
                    // An unfinished first import cannot combine two DB generations.
                    try self.db.prepare("DELETE FROM visits WHERE source_id=?").run([.text(source.id)])
                    generation = UUID().uuidString
                }
                try self.db.prepare("UPDATE sources SET state='collecting',error=NULL,db_identity=CASE WHEN last_success IS NULL THEN ? ELSE db_identity END,generation=CASE WHEN last_success IS NULL THEN ? ELSE generation END WHERE id=?")
                    .run([.text(identity), .text(generation), .text(source.id)])
            }
        }, onBatch: { batch in
            if self.cancelled(cancellationVersion) { throw HistoryScanInterrupted.cancelled }
            try self.db.transaction {
                let insert = try self.db.prepare("""
                    INSERT INTO scan_visits(source_id,native_id,url,title,native_real,native_int,visit_seconds,visit_fraction,norm_title,norm_url)
                    VALUES(?,?,?,?,?,?,?,?,?,?)
                    """)
                for visit in batch {
                    let time = try Self.time(visit.nativeTime)
                    try insert.run([.text(source.id), .integer(visit.id), .text(visit.url), visit.title.map(HistorySQLValue.text) ?? .null,
                                    time.nativeReal.map(HistorySQLValue.real) ?? .null, time.nativeInt.map(HistorySQLValue.integer) ?? .null,
                                    .integer(time.seconds), .real(time.fraction), .text(HistorySearch.normalize(visit.title ?? "")), .text(HistorySearch.normalize(visit.url))])
                }
                if publishPartial {
                    let merge = try self.db.prepare(Self.mergeSQL + " AND native_id=?" + Self.mergeConflictSQL)
                    for visit in batch { try merge.run([.text(generation), .text(source.id), .integer(visit.id)]) }
                }
            }
        })
        if cancelled(cancellationVersion) { throw HistoryScanInterrupted.cancelled }
        try db.transaction {
            if !firstImport {
                let mismatch = try db.prepare("""
                    SELECT EXISTS(SELECT 1 FROM scan_visits n JOIN visits v ON v.source_id=n.source_id AND v.native_id=n.native_id
                      WHERE n.source_id=? AND (n.url<>v.url OR n.native_real IS NOT v.native_real OR n.native_int IS NOT v.native_int))
                    """)
                try mismatch.bind([.text(source.id)])
                guard try mismatch.step() else { throw HistoryCollectionError.incompatibleDatabase }
                let disjoint = try db.prepare("SELECT EXISTS(SELECT 1 FROM visits WHERE source_id=?) AND NOT EXISTS(SELECT 1 FROM visits v JOIN scan_visits n ON v.source_id=n.source_id AND v.native_id=n.native_id WHERE v.source_id=?)")
                try disjoint.bind([.text(source.id), .text(source.id)])
                guard try disjoint.step() else { throw HistoryCollectionError.incompatibleDatabase }
                if previousIdentity != scannedIdentity || mismatch.int64(0) != 0 || disjoint.int64(0) != 0 {
                    generation = UUID().uuidString
                    try db.prepare("DELETE FROM visits WHERE source_id=?").run([.text(source.id)])
                }
            }
            try mergeStaged(sourceID: source.id, generation: generation)
            try db.prepare("DELETE FROM visits WHERE source_id=? AND native_id NOT IN (SELECT native_id FROM scan_visits WHERE source_id=?)")
                .run([.text(source.id), .text(source.id)])
            try db.prepare("DELETE FROM scan_visits WHERE source_id=?").run([.text(source.id)])
            try db.prepare("UPDATE sources SET state='complete',db_identity=?,generation=?,last_success=?,error=NULL WHERE id=?")
                .run([.text(scannedIdentity), .text(generation), .real(Date().timeIntervalSince1970), .text(source.id)])
        }
    }

    private func collectChromiumIcons(_ source: HistoryCollectionSource, cancellationVersion: UInt64) throws {
        let iconPath = URL(fileURLWithPath: source.path).deletingLastPathComponent().appendingPathComponent("Favicons").path
        var sourceDB: OpaquePointer?
        guard sqlite3_open_v2(iconPath, &sourceDB, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let sourceDB else {
            if let sourceDB { sqlite3_close(sourceDB) }; throw HistoryCollectionError.sqlite("icons unavailable")
        }
        defer { sqlite3_close(sourceDB) }
        sqlite3_busy_timeout(sourceDB, 1000)
        guard sqlite3_exec(sourceDB, "PRAGMA query_only=ON; BEGIN", nil, nil, nil) == SQLITE_OK else { throw HistoryCollectionError.sqlite("icons unavailable") }
        defer { sqlite3_exec(sourceDB, "ROLLBACK", nil, nil, nil) }
        var ptr: OpaquePointer?
        let sql = "SELECT m.page_url,b.image_data FROM icon_mapping m JOIN favicon_bitmaps b ON b.icon_id=m.icon_id WHERE length(b.image_data) BETWEEN 1 AND 32768"
        guard sqlite3_prepare_v2(sourceDB, sql, -1, &ptr, nil) == SQLITE_OK, let ptr else { throw HistoryCollectionError.sqlite("icons incompatible") }
        defer { sqlite3_finalize(ptr) }
        try db.transaction {
            try db.prepare("DELETE FROM icons WHERE source_id=?").run([.text(source.id)])
            let insert = try db.prepare("INSERT OR IGNORE INTO icons(source_id,site,mime,image) VALUES(?,?,?,?)")
            while true {
                if cancelled(cancellationVersion) { throw HistoryScanInterrupted.cancelled }
                let result = sqlite3_step(ptr)
                if result == SQLITE_DONE { break }
                guard result == SQLITE_ROW else { throw HistoryCollectionError.sqlite("icons interrupted") }
                guard let text = sqlite3_column_text(ptr, 0), let bytes = sqlite3_column_blob(ptr, 1) else { continue }
                let url = String(cString: text)
                guard let site = URL(string: url)?.host?.lowercased(), !site.isEmpty else { continue }
                let data = Data(bytes: bytes, count: Int(sqlite3_column_bytes(ptr, 1)))
                guard let mime = Self.iconMIME(data) else { continue }
                try insert.run([.text(source.id), .text(site), .text(mime), .blob(data)])
            }
        }
    }
    private static func iconMIME(_ data: Data) -> String? {
        let b = [UInt8](data.prefix(12))
        if b.starts(with: [0x89,0x50,0x4e,0x47,0x0d,0x0a,0x1a,0x0a]) { return "image/png" }
        if b.starts(with: [0xff,0xd8,0xff]) { return "image/jpeg" }
        if b.starts(with: Array("GIF87a".utf8)) || b.starts(with: Array("GIF89a".utf8)) { return "image/gif" }
        if b.starts(with: [0,0,1,0]) { return "image/x-icon" }
        if b.count >= 12 && Array(b[0..<4]) == Array("RIFF".utf8) && Array(b[8..<12]) == Array("WEBP".utf8) { return "image/webp" }
        return nil
    }

    private static let mergeSQL = """
        INSERT INTO visits(source_id,generation,native_id,url,title,native_real,native_int,visit_seconds,visit_fraction,norm_title,norm_url)
        SELECT source_id,?,native_id,url,title,native_real,native_int,visit_seconds,visit_fraction,norm_title,norm_url
        FROM scan_visits WHERE source_id=?
        """
    private static let mergeConflictSQL = """

        ON CONFLICT(source_id,native_id) DO UPDATE SET
        generation=excluded.generation,url=excluded.url,title=excluded.title,native_real=excluded.native_real,
        native_int=excluded.native_int,visit_seconds=excluded.visit_seconds,visit_fraction=excluded.visit_fraction,
        norm_title=excluded.norm_title,norm_url=excluded.norm_url
        WHERE visits.generation<>excluded.generation OR visits.url<>excluded.url OR visits.title IS NOT excluded.title
          OR visits.native_real IS NOT excluded.native_real OR visits.native_int IS NOT excluded.native_int
          OR visits.visit_seconds<>excluded.visit_seconds OR visits.visit_fraction<>excluded.visit_fraction
          OR visits.norm_title<>excluded.norm_title OR visits.norm_url<>excluded.norm_url
        """
    private func mergeStaged(sourceID: String, generation: String) throws {
        try db.prepare(Self.mergeSQL + Self.mergeConflictSQL).run([.text(generation), .text(sourceID)])
    }

    private static func time(_ time: HistorySourceSnapshot.NativeTime) throws -> (seconds: Int64, fraction: Double, nativeReal: Double?, nativeInt: Int64?) {
        switch time {
        case .safari(let raw):
            let whole = floor(raw)
            guard whole >= -62_000_000_000, whole <= 253_000_000_000 else { throw HistoryCollectionError.invalidTime }
            return (Int64(whole) + 978_307_200, raw - whole, raw, nil)
        case .chromium(let raw):
            var seconds = raw / 1_000_000
            var micro = raw % 1_000_000
            if micro < 0 { seconds -= 1; micro += 1_000_000 }
            return (seconds - 11_644_473_600, Double(micro) / 1_000_000, nil, raw)
        }
    }
}

private enum HistoryScanInterrupted: Error { case cancelled }
private enum HistorySQLValue {
    case text(String), integer(Int64), real(Double), blob(Data), null
}
private final class HistoryWriteDB {
    let handle: OpaquePointer
    init(path: String, readOnly: Bool = false) throws {
        var ptr: OpaquePointer?
        guard sqlite3_open_v2(path, &ptr, readOnly ? SQLITE_OPEN_READONLY : SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let ptr else {
            if let ptr { sqlite3_close(ptr) }; throw HistoryCollectionError.sqlite("open")
        }
        handle = ptr; sqlite3_busy_timeout(ptr, 5000)
    }
    deinit { sqlite3_close(handle) }
    func exec(_ sql: String) throws {
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else { throw HistoryCollectionError.sqlite(String(cString: sqlite3_errmsg(handle))) }
    }
    func prepare(_ sql: String) throws -> HistoryStatement { try HistoryStatement(db: handle, sql: sql) }
    func scalarInt(_ sql: String) throws -> Int64 { let s = try prepare(sql); guard try s.step() else { throw HistoryCollectionError.incompatibleDatabase }; return s.int64(0) }
    func transaction(_ body: () throws -> Void) throws {
        try exec("BEGIN IMMEDIATE")
        do { try body(); try exec("COMMIT") } catch { try? exec("ROLLBACK"); throw error }
    }
}
private final class HistoryStatement {
    let db: OpaquePointer
    let handle: OpaquePointer
    init(db: OpaquePointer, sql: String) throws {
        self.db = db
        var ptr: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &ptr, nil) == SQLITE_OK, let ptr else { throw HistoryCollectionError.sqlite(String(cString: sqlite3_errmsg(db))) }
        handle = ptr
    }
    deinit { sqlite3_finalize(handle) }
    func bind(_ values: [HistorySQLValue]) throws {
        sqlite3_reset(handle); sqlite3_clear_bindings(handle)
        for (index, value) in values.enumerated() {
            let i = Int32(index + 1)
            let status: Int32
            switch value {
            case .text(let str):
                status = str.withCString { sqlite3_bind_text(handle, i, $0, Int32(str.utf8.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
            case .integer(let v): status = sqlite3_bind_int64(handle, i, v)
            case .real(let v): status = sqlite3_bind_double(handle, i, v)
            case .blob(let data): status = data.withUnsafeBytes { sqlite3_bind_blob(handle, i, $0.baseAddress, Int32($0.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
            case .null: status = sqlite3_bind_null(handle, i)
            }
            guard status == SQLITE_OK else { throw HistoryCollectionError.sqlite(String(cString: sqlite3_errmsg(db))) }
        }
    }
    func step() throws -> Bool {
        let result = sqlite3_step(handle)
        if result == SQLITE_ROW { return true }
        if result == SQLITE_DONE { return false }
        throw HistoryCollectionError.sqlite(String(cString: sqlite3_errmsg(db)))
    }
    func run(_ values: [HistorySQLValue]) throws { try bind(values); guard try !step() else { throw HistoryCollectionError.incompatibleDatabase } }
    func text(_ i: Int32) -> String? {
        guard sqlite3_column_type(handle, i) == SQLITE_TEXT, let p = sqlite3_column_text(handle, i) else { return nil }
        return String(bytes: UnsafeBufferPointer(start: p, count: Int(sqlite3_column_bytes(handle, i))), encoding: .utf8)
    }
    func int64(_ i: Int32) -> Int64 { sqlite3_column_int64(handle, i) }
    func optionalDouble(_ i: Int32) -> Double? { sqlite3_column_type(handle, i) == SQLITE_NULL ? nil : sqlite3_column_double(handle, i) }
}
