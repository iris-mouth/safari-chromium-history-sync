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

public struct CollectionOverview: Codable, Sendable {
    public struct Source: Codable, Sendable {
        public let id: String
        public let browser: HistorySourceSnapshot.Browser
        public let browserType: String
        public let profileName: String
        public let state: String
        public let lastScan: Double?
        public let lastLiveVisit: Double?
    }

    public let enabled: Bool
    public let pair: HistoryCollector.Pair?
    public let sources: [Source]
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
        guard (0...5).contains(version) else { throw HistoryCollectionError.incompatibleDatabase }
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
        if version < 5 {
            try db.transaction {
                try db.exec("""
                    CREATE TABLE IF NOT EXISTS pair(id INTEGER PRIMARY KEY CHECK(id=1), source TEXT NOT NULL,
                      revision TEXT NOT NULL, extension_id TEXT, since REAL);
                    CREATE TABLE IF NOT EXISTS routing_baselines(source TEXT PRIMARY KEY REFERENCES sources(id) ON DELETE CASCADE, native_id INTEGER NOT NULL);
                    CREATE TABLE IF NOT EXISTS delivery_candidates(seq INTEGER PRIMARY KEY AUTOINCREMENT,
                      event TEXT NOT NULL UNIQUE, revision TEXT NOT NULL, destination TEXT NOT NULL, visit INTEGER NOT NULL UNIQUE REFERENCES visits(id) ON DELETE CASCADE);
                    CREATE TABLE IF NOT EXISTS api_visits(visit INTEGER PRIMARY KEY REFERENCES visits(id) ON DELETE CASCADE, observed REAL NOT NULL);
                    CREATE TABLE IF NOT EXISTS removal_cutoffs(source TEXT REFERENCES sources(id) ON DELETE CASCADE,url TEXT,cutoff REAL NOT NULL,PRIMARY KEY(source,url));
                    CREATE TRIGGER IF NOT EXISTS collect_delivery AFTER INSERT ON visits
                    WHEN EXISTS(SELECT 1 FROM pair WHERE since IS NOT NULL AND NEW.visit_seconds+NEW.visit_fraction>=since)
                      AND EXISTS(SELECT 1 FROM routing_baselines WHERE source=NEW.source_id AND NEW.native_id>native_id)
                      AND EXISTS(SELECT 1 FROM sources WHERE id=NEW.source_id AND last_success IS NOT NULL AND generation=NEW.generation)
                    BEGIN
                      INSERT INTO delivery_candidates(event,visit,revision,destination)
                      SELECT lower(hex(randomblob(16))),NEW.id,revision,CASE WHEN NEW.source_id=source THEN 'safari' ELSE 'chromium' END FROM pair;
                    END;
                    PRAGMA user_version=5;
                    """)
                let sources = try Self.readSources(db)
                if sources.count == 2, sources.contains(where: { $0.id == "safari:default" }),
                   let partner = sources.first(where: { $0.browser == .chromium }) {
                    try db.prepare("INSERT OR IGNORE INTO pair(id,source,revision) VALUES(1,?,?)")
                        .run([.text(partner.id), .text(UUID().uuidString)])
                } else {
                    try db.exec("UPDATE collection_settings SET value='0' WHERE key='enabled'")
                }
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
    public func configure(_ sources: [HistoryCollectionSource], pairEnabled: Bool? = nil, expectedRemoved: Int64? = nil, expectedPending: Int64? = nil, queued: Set<String> = []) throws {
        cancelCurrent()
        try lock.withLock {
            guard Set(sources.map(\.id)).count == sources.count,
                  sources.allSatisfy({ !$0.id.isEmpty && !$0.path.isEmpty && !$0.browserType.isEmpty }) else { throw HistoryCollectionError.invalidSource }
            try db.transaction {
                if let pairEnabled {
                    guard sources.count == 2, sources.contains(where: { $0.id == "safari:default" }),
                          let partner = sources.first(where: { $0.browser == .chromium }) else { throw HistoryCollectionError.invalidSource }
                    let old = try readPair(db)
                    if old?.source != partner.id {
                        let count = try db.prepare("SELECT count(*) FROM visits WHERE source_id NOT IN ('safari:default',?)")
                        try count.bind([.text(partner.id)])
                        guard try count.step(), count.int64(0) == (expectedRemoved ?? 0),
                              try Self.pendingCount(db, queued: queued) == (expectedPending ?? 0) else { throw TypedError(code: "PAIR_CHANGED") }
                        try db.exec("DELETE FROM delivery_candidates; DELETE FROM pair")
                        try db.prepare("INSERT INTO pair(id,source,revision) VALUES(1,?,?)").run([.text(partner.id), .text(UUID().uuidString)])
                    }
                    if !pairEnabled { try db.exec("UPDATE pair SET since=NULL") }
                    try db.prepare("UPDATE collection_settings SET value=? WHERE key='enabled'").run([.text(pairEnabled ? "1" : "0")])
                }
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

    public func overview() throws -> CollectionOverview {
        let reader = try HistoryWriteDB(path: databasePath, readOnly: true)
        sqlite3_busy_timeout(reader.handle, 150)
        try reader.exec("BEGIN")
        let enabled = try reader.scalarInt("SELECT value='1' FROM collection_settings WHERE key='enabled'") != 0
        let pair = try readPair(reader)
        let receipt = try reader.prepare("SELECT value FROM collection_settings WHERE key='last_live_visit'")
        let liveVisit = try receipt.step() ? receipt.text(0).flatMap {
            try? JSONDecoder().decode(LiveVisitReceipt.self, from: Data($0.utf8))
        } : nil
        let rows = try reader.prepare("""
            SELECT id,browser,browser_type,profile_name,state,last_success,generation
            FROM sources ORDER BY id
            """)
        var sources: [CollectionOverview.Source] = []
        while try rows.step() {
            guard let id = rows.text(0), let rawBrowser = rows.text(1),
                  let browser = HistorySourceSnapshot.Browser(rawValue: rawBrowser), let type = rows.text(2),
                  let name = rows.text(3), let state = rows.text(4) else { throw HistoryCollectionError.incompatibleDatabase }
            let lastLiveVisit = liveVisit.flatMap { evidence in
                pair?.source == id && pair?.revision == evidence.revision && rows.text(6) == evidence.generation
                    ? evidence.at : nil
            }
            sources.append(.init(id: id, browser: browser, browserType: type, profileName: name,
                                 state: state, lastScan: rows.optionalDouble(5), lastLiveVisit: lastLiveVisit))
        }
        try reader.exec("COMMIT")
        return .init(enabled: enabled, pair: pair, sources: sources)
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
    public func collectAll(onlyIfEnabled: Bool = false) throws {
        let version = cancellationLock.withLock { cancellationVersion }
        try lock.withLock {
            if onlyIfEnabled, try db.scalarInt("SELECT value='1' FROM collection_settings WHERE key='enabled'") == 0 { return }
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
        let scanStarted = Date().timeIntervalSince1970
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
                      WHERE n.source_id=? AND (n.url<>v.url OR n.native_real IS NOT v.native_real OR (n.native_int IS NOT v.native_int AND NOT EXISTS(SELECT 1 FROM api_visits a WHERE a.visit=v.id AND abs(n.native_int-v.native_int)<=1000))))
                    """)
                try mismatch.bind([.text(source.id)])
                guard try mismatch.step() else { throw HistoryCollectionError.incompatibleDatabase }
                let disjoint = try db.prepare("SELECT EXISTS(SELECT 1 FROM visits WHERE source_id=? AND NOT EXISTS(SELECT 1 FROM api_visits a WHERE a.visit=visits.id)) AND NOT EXISTS(SELECT 1 FROM visits v JOIN scan_visits n ON v.source_id=n.source_id AND v.native_id=n.native_id WHERE v.source_id=?)")
                try disjoint.bind([.text(source.id), .text(source.id)])
                guard try disjoint.step() else { throw HistoryCollectionError.incompatibleDatabase }
                if previousIdentity != scannedIdentity || mismatch.int64(0) != 0 || disjoint.int64(0) != 0 {
                    generation = UUID().uuidString
                    try db.prepare("DELETE FROM removal_cutoffs WHERE source=?").run([.text(source.id)])
                    try db.exec("UPDATE pair SET since=NULL,revision=lower(hex(randomblob(16))); DELETE FROM delivery_candidates")
                    try db.prepare("DELETE FROM visits WHERE source_id=?").run([.text(source.id)])
                }
            }
            if source.browser == .chromium, try db.scalarInt("SELECT EXISTS(SELECT 1 FROM removal_cutoffs)") != 0 {
                // Browser removal notifications can precede the native DB commit.
                // Retire a cutoff only after a complete snapshot confirms absence.
                try db.prepare("""
                    DELETE FROM removal_cutoffs WHERE source=? AND NOT EXISTS(
                      SELECT 1 FROM scan_visits n WHERE n.source_id=source AND (removal_cutoffs.url='' OR removal_cutoffs.url=n.url)
                      AND n.visit_seconds+n.visit_fraction<=cutoff)
                    """).run([.text(source.id)])
                try db.prepare("""
                    DELETE FROM scan_visits WHERE source_id=? AND EXISTS(SELECT 1 FROM removal_cutoffs r
                      WHERE r.source=source_id AND (r.url='' OR r.url=scan_visits.url) AND visit_seconds+visit_fraction<=r.cutoff)
                    """).run([.text(source.id)])
            }
            try mergeStaged(sourceID: source.id, generation: generation)
            try db.prepare("DELETE FROM visits WHERE source_id=? AND native_id NOT IN (SELECT native_id FROM scan_visits WHERE source_id=?) AND NOT EXISTS(SELECT 1 FROM api_visits a WHERE a.visit=visits.id AND a.observed>=?)")
                .run([.text(source.id), .text(source.id), .real(scanStarted - 60)])
            try db.prepare("DELETE FROM api_visits WHERE visit IN (SELECT v.id FROM visits v JOIN scan_visits n ON n.source_id=v.source_id AND n.native_id=v.native_id WHERE v.source_id=?)").run([.text(source.id)])
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

    public struct Pair: Codable, Sendable {
        public let source: String
        public let revision: String
        public let extensionID: String?
        public let since: Double?
    }
    private func readPair(_ connection: HistoryWriteDB) throws -> Pair? {
        let row = try connection.prepare("SELECT source,revision,extension_id,since FROM pair WHERE id=1")
        guard try row.step() else { return nil }
        return Pair(source: row.text(0)!, revision: row.text(1)!, extensionID: row.text(2), since: row.optionalDouble(3))
    }
    public func pair() throws -> Pair? { try readPair(HistoryWriteDB(path: databasePath, readOnly: true)) }
    public func bind(profile: String, revision: String) throws {
        try lock.withLock {
            guard let pair = try readPair(db), pair.revision == revision,
                  !profile.isEmpty, profile.utf8.count <= 128 else { throw TypedError(code: "PAIR_CHANGED") }
            try db.transaction {
                if let previous = pair.extensionID, previous != profile {
                    try db.exec("DELETE FROM delivery_candidates")
                    try db.prepare("UPDATE pair SET since=NULL,revision=?").run([.text(UUID().uuidString)])
                }
                try db.prepare("UPDATE pair SET extension_id=? WHERE id=1").run([.text(profile)])
            }
        }
    }
    public func startRouting(_ enabled: Bool) throws {
        try lock.withLock {
            if enabled {
                guard let pair = try readPair(db), pair.extensionID != nil,
                      try isEnabled(), try db.scalarInt("SELECT COUNT(*) FROM sources WHERE last_success IS NOT NULL")==2 else {
                    throw TypedError(code: "PAIR_NOT_READY")
                }
                if pair.since != nil { return }
                try db.transaction {
                    let since = Date().timeIntervalSince1970
                    let baseline = try db.prepare("INSERT OR REPLACE INTO routing_baselines VALUES(?,?)")
                    for source in try Self.readSources(db) {
                        let identity = try HistorySourceReader.identity(source.path)
                        let known = try db.prepare("SELECT 1 FROM sources WHERE id=? AND db_identity=? AND state='complete'")
                        try known.bind([.text(source.id), .text(identity)])
                        guard try known.step() else { throw TypedError(code: "SOURCE_NOT_READY") }
                        let sourceDB = try HistoryWriteDB(path: source.path, readOnly: true)
                        let table = source.browser == .safari ? "history_visits" : "visits"
                        let maximum = try sourceDB.scalarInt("SELECT COALESCE(MAX(id),0) FROM " + table)
                        guard try HistorySourceReader.identity(source.path) == identity else { throw TypedError(code: "SOURCE_NOT_READY") }
                        try baseline.run([.text(source.id), .integer(maximum)])
                    }
                    try db.prepare("UPDATE pair SET since=?").run([.real(since)])
                }
            } else { try db.exec("UPDATE pair SET since=NULL") }
        }
    }
    public struct Candidate: Codable {
        let seq: Int64
        let event: String
        let visitRow: Int64
        let visitTime: Double
        let nativeID: Int64
        public let browser: String
        let url: URL
        let title: String?
    }
    public func candidates() throws -> [Candidate] {
        let reader = try HistoryWriteDB(path: databasePath, readOnly: true)
        let rows = try reader.prepare("""
            SELECT c.seq,c.event,v.native_id,s.browser,v.url,v.title,v.id,(v.visit_seconds+v.visit_fraction)*1000 FROM delivery_candidates c
            JOIN visits v ON v.id=c.visit JOIN sources s ON s.id=v.source_id ORDER BY c.seq LIMIT 128
            """)
        var result: [Candidate] = []
        while try rows.step() {
            guard let url = URL(string: rows.text(4)!) else { throw HistoryCollectionError.invalidSource }
            result.append(Candidate(seq: rows.int64(0), event: rows.text(1)!, visitRow: rows.int64(6), visitTime: rows.optionalDouble(7)!, nativeID: rows.int64(2), browser: rows.text(3)!, url: url, title: rows.text(5)))
        }
        return result
    }
    public struct BrowserCandidate: Encodable {
        let event: String
        let nativeID: String
        let visitTime: Double
        let url: URL
    }

    public func browserCandidates() throws -> [BrowserCandidate] {
        var bytes = 512
        var result: [BrowserCandidate] = []
        for visit in try candidates() where visit.browser == "chromium" {
            let item = BrowserCandidate(event: visit.event, nativeID: String(visit.nativeID), visitTime: visit.visitTime, url: visit.url)
            bytes += try JSONEncoder().encode(item).count + 1
            if bytes > 512 * 1024 { break }
            result.append(item)
        }
        return result
    }

    func containsVisit(_ id: Int64) throws -> Bool {
        let reader = try HistoryWriteDB(path: databasePath, readOnly: true)
        let row = try reader.prepare("SELECT 1 FROM visits WHERE id=?")
        try row.bind([.integer(id)])
        return try row.step()
    }
    public func removeReported(profile: String, revision: String, urls: [String]?, before: Double) throws {
        try lock.withLock {
            guard let pair = try readPair(db), pair.extensionID == profile, pair.revision == revision,
                  before.isFinite, before <= Date().timeIntervalSince1970 * 1000 + 60000,
                  (urls?.count ?? 0) <= 128 else { throw TypedError(code: "PAIR_CHANGED") }
            let predicate = "source_id=? AND visit_seconds+visit_fraction<=?"
            try db.transaction {
                let cutoff = try db.prepare("INSERT INTO removal_cutoffs VALUES(?,?,?) ON CONFLICT(source,url) DO UPDATE SET cutoff=MAX(cutoff,excluded.cutoff)")
                for key in urls ?? [""] { try cutoff.run([.text(pair.source),.text(key),.real(before/1000)]) }
                let args: [HistorySQLValue] = [.text(pair.source),.real(before/1000)]
                if let urls {
                    let delete = try db.prepare("DELETE FROM visits WHERE " + predicate + " AND url=?")
                    for url in urls { try delete.run(args + [.text(url)]) }
                } else { try db.prepare("DELETE FROM visits WHERE " + predicate).run(args) }
            }
        }
    }

    func finishCandidate(_ event: String) throws {
        try lock.withLock { try db.prepare("DELETE FROM delivery_candidates WHERE event=?").run([.text(event)]) }
    }
    private static func pendingCount(_ reader: HistoryWriteDB, queued: Set<String>) throws -> Int64 {
        var total = try reader.scalarInt("SELECT COUNT(*) FROM delivery_candidates")
        let existing = try reader.prepare("SELECT 1 FROM delivery_candidates WHERE event=?")
        for id in queued {
            try existing.bind([.text(id)])
            if try !existing.step() { total += 1 }
        }
        return total
    }
    public func candidateCount(queued: Set<String> = []) throws -> Int64 {
        try Self.pendingCount(HistoryWriteDB(path: databasePath, readOnly: true), queued: queued)
    }

    private struct LiveVisitReceipt: Codable {
        let revision: String
        let generation: String
        let at: Double
    }

    public func collectReported(_ visits: [ReportedVisit], profile: String, revision: String) throws {
        try lock.withLock {
            guard try isEnabled(), let pair = try readPair(db), pair.extensionID == profile, pair.revision == revision,
                  let source = try Self.readSources(db).first(where: { $0.id == pair.source }) else { throw TypedError(code: "PAIR_CHANGED") }
            let row = try db.prepare("SELECT generation,db_identity FROM sources WHERE id=? AND last_success IS NOT NULL")
            try row.bind([.text(source.id)])
            guard try row.step(), let generation = row.text(0), try HistorySourceReader.identity(source.path) == row.text(1) else { throw TypedError(code: "SOURCE_NOT_READY") }
            let origins = viewerOrigins + (try storedViewerOrigins()).compactMap(URL.init(string:))
            let now = Date().timeIntervalSince1970
            try db.transaction {
                var accepted = false
                for visit in visits {
                    guard let id = Int64(visit.visitId), id > 0, let url = URL(string: visit.url),
                          ["https","http"].contains(url.scheme?.lowercased() ?? ""), url.host != nil,
                          visit.visitTime.isFinite, (0...32_503_680_000_000).contains(visit.visitTime) else { throw TypedError(code: "INVALID_VISIT") }
                    if HistorySourceReader.isProductURL(url, viewerOrigins: origins) { continue }
                    let deleted = try db.prepare("SELECT 1 FROM removal_cutoffs WHERE source=? AND url IN ('',?) AND cutoff>=?")
                    try deleted.bind([.text(source.id), .text(visit.url), .real(visit.visitTime/1000)])
                    if try deleted.step() { continue }
                    let raw = Int64((visit.visitTime * 1000).rounded()) + 11_644_473_600_000_000
                    let existing = try db.prepare("SELECT url,native_int FROM visits WHERE source_id=? AND native_id=?")
                    try existing.bind([.text(source.id), .integer(id)])
                    if try existing.step() {
                        guard existing.text(0) == visit.url, abs(Double(existing.int64(1)) - Double(raw)) <= 1000 else { throw TypedError(code: "VISIT_CONFLICT") }
                        accepted = true
                        continue
                    }
                    let t = try Self.time(.chromium(raw))
                    try db.prepare("""
                        INSERT INTO visits(source_id,generation,native_id,url,title,native_int,visit_seconds,visit_fraction,norm_title,norm_url)
                        VALUES(?,?,?,?,?,?,?,?,?,?)
                        """).run([.text(source.id),.text(generation),.integer(id),.text(visit.url),visit.title.map(HistorySQLValue.text) ?? .null,
                                 .integer(raw),.integer(t.seconds),.real(t.fraction),.text(HistorySearch.normalize(visit.title ?? "")),.text(HistorySearch.normalize(visit.url))])
                    try db.prepare("INSERT INTO api_visits VALUES(last_insert_rowid(),?)").run([.real(now)])
                    accepted = true
                }
                if accepted {
                    let receipt = LiveVisitReceipt(revision: revision, generation: generation, at: now)
                    let json = String(decoding: try JSONEncoder().encode(receipt), as: UTF8.self)
                    try db.prepare("""
                        INSERT INTO collection_settings VALUES('last_live_visit',?)
                        ON CONFLICT(key) DO UPDATE SET value=excluded.value
                        """).run([.text(json)])
                }
            }
        }
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
