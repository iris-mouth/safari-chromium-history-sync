import CSQLite
import Darwin
import Foundation
import HistoryViewCore
import SafariSyncCore

enum HistoryCollectionTests {
    static func run() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("history-collection-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let dbURL = dir.appendingPathComponent("history.sqlite")
        let safari = try HistoryFixture()
        let chrome = try HistoryFixture()
        try safari.insertSafariVisit(url: "https://example.org/repeated")
        try safari.exec("UPDATE history_visits SET title='ＡＢＣ ｶﾞｯｺｳ ① ㎏' WHERE id=1")
        try safari.exec("INSERT INTO history_visits(history_item,visit_time,title) VALUES (1,899913600,'yesterday'), (1,900000000,'same time')")
        try chrome.exec("CREATE TABLE urls(id INTEGER PRIMARY KEY,url TEXT,title TEXT); CREATE TABLE visits(id INTEGER PRIMARY KEY,url INTEGER,visit_time INTEGER); INSERT INTO urls VALUES(1,'https://example.org/repeated','chrome'); INSERT INTO visits VALUES(10,1,13300000000000001)")
        let source = HistoryCollectionSource(id: "safari", browser: .safari, browserType: "Safari", profileName: "", path: safari.url.path)
        let other = HistoryCollectionSource(id: "chrome", browser: .chromium, browserType: "Chrome", profileName: "Profile 1", path: chrome.url.path)
        let collector = try HistoryCollector(databaseURL: dbURL)
        var directoryInfo = stat(), databaseInfo = stat()
        guard stat(dir.path, &directoryInfo) == 0, stat(dbURL.path, &databaseInfo) == 0 else { throw IntegrationFailure.assertion("collection permissions") }
        try expect(Int(directoryInfo.st_mode & 0o777), 0o700, "collection directory owner only")
        try expect(Int(databaseInfo.st_mode & 0o777), 0o600, "collection database owner only")
        try collector.configure([source, other])
        try collector.collectAll()
        try expect(try count(dbURL, "SELECT count(*) FROM visits"), 4, "separate visits and sources")
        try expect(try collector.statuses().map(\.state), ["complete", "complete"], "both complete")
        try collector.setEnabled(true)
        try collector.setEnabled(false)
        let reopened = try HistoryCollector(databaseURL: dbURL)
        try expect(try reopened.isEnabled(), false, "collection pause persists")
        try expect(try reopened.statuses().reduce(0) { $0 + $1.count }, 4, "pause retains collected data")
        let reader = HistoryReader(databasePath: dbURL.path)
        try httpBoundary(reader: reader, directory: dir)
        let first = try reader.page(start: "2000-01-01", end: "2099-12-31", limit: 2)
        try expect(first.items.count, 2, "reader page limit")
        guard let cursor = first.cursor else { throw IntegrationFailure.assertion("missing page cursor") }
        let second = try reader.page(start: "2000-01-01", end: "2099-12-31", cursor: cursor, limit: 2, ids: first.items.map(\.id))
        try expect(second.items.count, 2, "reader returns remaining equal-time rows")
        try expect(Set(first.items.map(\.id)).isDisjoint(with: Set(second.items.map(\.id))), true, "stable page does not duplicate")
        try expect(second.valid.count, 2, "loaded IDs revalidated")
        try expect(try reader.detail(id: first.items[0].id), first.items[0], "detail shares record semantics")
        try expect(try reader.page(start: "2000-01-01", end: "2000-01-01", query: "REPEATED").items.count, 4, "search spans all dates")
        try expect(try reader.page(start: "2000-01-01", end: "2000-01-01", query: "abc がっこう 1 kg").items.count, 1, "collector and reader normalize search identically")
        try expect(try reader.status().sources.count, 2, "reader status exposes both sources")
        do { _ = try reader.page(start: "not-a-day", end: "2000-01-01"); throw IntegrationFailure.assertion("invalid day accepted") }
        catch HistoryReaderError.invalid { }
        try collector.collectAll()
        try expect(try count(dbURL, "SELECT count(*) FROM visits"), 4, "repeat scan idempotent")
        let oldRecord = try count(dbURL, "SELECT id FROM visits WHERE source_id='safari' AND native_id=1")
        try safari.exec("UPDATE history_visits SET visit_time=900000001 WHERE id=1")
        try collector.collectAll()
        let newRecord = try count(dbURL, "SELECT id FROM visits WHERE source_id='safari' AND native_id=1")
        try expect(oldRecord != newRecord, true, "reused native ID starts a new source generation")
        try expect(try count(dbURL, "SELECT count(*) FROM visits WHERE source_id='chrome'"), 1, "generation change leaves other sources")
        try safari.exec("DELETE FROM history_visits WHERE id=2; INSERT INTO history_visits(history_item,visit_time,title) VALUES(1,800000000,'late')")
        try chrome.exec("DROP TABLE visits")
        try collector.collectAll()
        try expect(try count(dbURL, "SELECT count(*) FROM visits WHERE source_id='safari'"), 3, "delete only missing visit, accept late arrival")
        try expect(try count(dbURL, "SELECT count(*) FROM visits WHERE source_id='chrome'"), 1, "failed source retained")
        try expect(try collector.statuses().first(where: { $0.id == "chrome" })?.state, "failed", "failure is visible")
        let replacement = try HistoryFixture()
        try replacement.insertSafariVisit(url: "https://replacement.example/")
        var moved = source
        moved.path = replacement.url.path
        try replacement.exec("WITH RECURSIVE n(x) AS (SELECT 1 UNION ALL SELECT x+1 FROM n WHERE x<500) INSERT INTO history_visits(history_item,visit_time) SELECT 1,2000+x FROM n")
        try replacement.exec("UPDATE history_visits SET visit_time='bad' WHERE id=501")
        try collector.configure([moved, other])
        try collector.collectAll()
        try expect(try count(dbURL, "SELECT count(*) FROM visits WHERE source_id='safari'"), 3, "failed replacement retains old data")
        try replacement.exec("UPDATE history_visits SET visit_time=1234 WHERE id=501")
        try collector.collectAll()
        try expect(try count(dbURL, "SELECT count(*) FROM visits WHERE source_id='safari'"), 501, "successful replacement atomically replaces source")
        try expect(try count(dbURL, "SELECT count(*) FROM visits WHERE source_id='chrome'"), 1, "replacement leaves other source")
        try collector.configure([other])
        try expect(try count(dbURL, "SELECT count(*) FROM visits WHERE source_id='safari'"), 0, "deselection removes only its source")
        try collector.configure([moved, other])
        try collector.collectAll()
        try expect(try count(dbURL, "SELECT count(*) FROM visits WHERE source_id='safari'"), 501, "reselection reimports")
        try expect(HistorySearch.normalize("ｶﾀｶﾅ Straße"), "かたかな strasse", "NFKC casefold kana")
        try expect(Array(HistorySearch.normalize("ｶﾞｯｺｳ").unicodeScalars.map(\.value)), Array(HistorySearch.normalize("がっこう").unicodeScalars.map(\.value)), "voiced kana normalization must match at the scalar level")
        try expect(Array(HistorySearch.normalize("ǰ").unicodeScalars.map(\.value)), [0x6a, 0x30c], "casefold retains decomposed Unicode result")
        try collectsLockedExtensionVisits(dir: dir)
        try firstImportCanBeReadBeforeCompletion(dir: dir)
        try localIcons(dir: dir)
        try collectionDoesNotChangeSyncCursor(dir: dir)
        try searchIndexPreservesLiteralSemantics(dir: dir)
        try viewerOriginChangesRemainExcluded(dir: dir)
    }

    static func collectsLockedExtensionVisits(dir: URL) throws {
        let safari = try HistoryFixture()
        let edge = try HistoryFixture()
        let database = dir.appendingPathComponent("pair/visits.sqlite")
        let collector = try HistoryCollector(databaseURL: database)
        try edge.exec("CREATE TABLE urls(id INTEGER PRIMARY KEY,url TEXT,title TEXT); CREATE TABLE visits(id INTEGER PRIMARY KEY,url INTEGER,visit_time INTEGER)")
        let url = "https://pair-fixture.example/revisit"
        try edge.exec("INSERT INTO urls VALUES(1,'\(url)','Native title'); INSERT INTO visits VALUES(1,1,13300000000000001)")
        try collector.configure([
            HistoryCollectionSource(id:"safari:default", browser:.safari, browserType:"Safari", profileName:"Default", path:safari.url.path),
            HistoryCollectionSource(id:"edge:Profile 1", browser:.chromium, browserType:"Edge", profileName:"Synthetic", path:edge.url.path)
        ], pairEnabled:true)
        try collector.collectAll()
        guard let revision = try collector.pair()?.revision else { throw IntegrationFailure.assertion("missing pair") }
        try collector.bind(profile:"edge:synthetic", revision:revision)
        try collector.startRouting(true)
        let ms = ceil(Date().timeIntervalSince1970 * 1000) + 1
        let nativeTime = Int64(ms * 1000) + 11_644_473_600_000_000 + 437
        try edge.exec("BEGIN EXCLUSIVE; INSERT INTO visits VALUES(2,1,\(nativeTime))")
        let encoded = try JSONSerialization.data(withJSONObject:[["visitId":"2","visitTime":ms,"url":url]])
        let reports = try JSONDecoder().decode([ReportedVisit].self, from:encoded)
        try collector.collectReported(reports, profile:"edge:synthetic", revision:revision)
        let record = try count(database,"SELECT id FROM visits WHERE native_id=2")
        try expect(try collector.candidateCount(), 1, "locked Edge fast path creates one routable revisit")
        try edge.exec("COMMIT")
        try collector.collectAll()
        try expect(try count(database,"SELECT id FROM visits WHERE native_id=2"), record, "DB scan preserves fast-path record")
        try expect(try count(database,"SELECT native_int FROM visits WHERE native_id=2"),nativeTime,"disk reconciliation supplies exact Chromium microseconds")
        try expect(try collector.candidateCount(),1,"duplicate observation does not create a second delivery")
        try collector.removeReported(profile:"edge:synthetic",revision:revision,urls:[url],before:ms+1)
        try collector.collectAll()
        try expect(try count(database,"SELECT count(*) FROM visits"),0,"stale on-disk snapshot cannot resurrect notified removals")
        try expect(try collector.candidateCount(),0,"removal cancels pending delivery")
        try collector.bind(profile:"edge:reinstalled",revision:revision)
        guard let rebound = try collector.pair() else { throw IntegrationFailure.assertion("pair disappeared after reinstall") }
        try expect(rebound.since,nil,"reinstalled extension requires fresh opt-in")
        try expect(rebound.revision != revision,true,"stale worker cannot reuse the previous revision")
    }

    static func viewerOriginChangesRemainExcluded(dir: URL) throws {
        let fixture = try HistoryFixture()
        try fixture.insertSafariVisit(url: "https://viewer.example.test:8443/?day=1")
        try fixture.insertSafariVisit(url: "https://viewer.example.test/?day=2")
        try fixture.insertSafariVisit(url: "https://viewer.example.test/ordinary")
        let target = dir.appendingPathComponent("origin.sqlite")
        let collector = try HistoryCollector(databaseURL: target)
        try collector.configure([.init(id: "origin", browser: .safari, browserType: "Safari", profileName: "Default", path: fixture.url.path)])
        try collector.setViewerOrigin("https://viewer.example.test:8443/")
        try collector.collectAll()
        try expect(try count(target, "SELECT count(*) FROM visits"), 2, "current viewer URL is excluded")
        // Simulate the existing schema, which stores only the current origin.
        var db: OpaquePointer?
        guard sqlite3_open(target.path, &db) == SQLITE_OK, let db else { throw IntegrationFailure.assertion("open origin fixture") }
        guard sqlite3_exec(db, "DELETE FROM collection_settings WHERE key='viewer_origin_history'", nil, nil, nil) == SQLITE_OK,
              sqlite3_close(db) == SQLITE_OK else { throw IntegrationFailure.assertion("prepare origin migration fixture") }
        try collector.setViewerOrigin("https://viewer.example.test/")
        try collector.collectAll()
        try expect(try count(target, "SELECT count(*) FROM visits"), 1, "previous and current viewer URLs stay excluded after cutover")
        try HistoryCollector(databaseURL: target).collectAll()
        try expect(try count(target, "SELECT count(*) FROM visits"), 1, "viewer exclusions survive Agent restart")
    }

    static func firstImportCanBeReadBeforeCompletion(dir: URL) throws {
        let sourceDB = try HistoryFixture()
        try sourceDB.insertSafariVisit(url: "https://partial.example/")
        try sourceDB.exec("WITH RECURSIVE n(x) AS (SELECT 1 UNION ALL SELECT x+1 FROM n WHERE x<500) INSERT INTO history_visits(history_item,visit_time) SELECT 1,1000+x FROM n")
        try sourceDB.exec("UPDATE history_visits SET visit_time='bad' WHERE id=501")
        let target = dir.appendingPathComponent("partial.sqlite")
        let collector = try HistoryCollector(databaseURL: target)
        let source = HistoryCollectionSource(id: "partial", browser: .safari, browserType: "Safari", profileName: "", path: sourceDB.url.path)
        try collector.configure([source])
        try collector.collectAll()
        try expect(try count(target, "SELECT count(*) FROM visits"), 500, "committed initial batch remains visible after failure")
        try expect(try collector.statuses()[0].state, "failed", "partial failure distinct from complete")
        try sourceDB.exec("UPDATE history_visits SET visit_time=1500 WHERE id=501")
        try collector.collectAll()
        try expect(try count(target, "SELECT count(*) FROM visits"), 501, "resume imports all visits")
        try expect(try collector.statuses()[0].state, "complete", "resumed import completes")
    }

    static func searchIndexPreservesLiteralSemantics(dir: URL) throws {
        let fixture = try HistoryFixture()
        try fixture.insertSafariVisit(url: "https://search.example/a+b")
        try fixture.exec(#"INSERT INTO history_visits(history_item,visit_time,title) VALUES(1,1001,'prefix abc+*"end'),(1,1002,'カタカナばなな'),(1,1003,'😀😅😆テスト'),(1,1004,'tiny a')"#)
        let target = dir.appendingPathComponent("search.sqlite")
        let collector = try HistoryCollector(databaseURL: target)
        try collector.configure([.init(id: "search", browser: .safari, browserType: "Safari", profileName: "Default", path: fixture.url.path)])
        try collector.collectAll()
        let reader = HistoryReader(databasePath: target.path)
        let terms = ["abc+*\"", "かたかな", "😀😅😆", "a", "ab", "a+b", "not-present"]
        for term in terms {
            let actual = Set(try reader.page(start: "2000-01-01", end: "2099-12-31", query: term).items.map(\.id))
            let expected = try rawSubstringMatches(target, term: HistorySearch.normalize(term))
            try expect(actual, expected, "FTS candidate and literal scan must agree for \(term)")
        }
        try fixture.exec("DELETE FROM history_visits WHERE id=2")
        try collector.collectAll()
        try expect(try reader.page(start: "2000-01-01", end: "2099-12-31", query: "abc+*\"").items.count, 0, "search index removes deleted visits")
        var old: OpaquePointer?
        guard sqlite3_open(target.path, &old) == SQLITE_OK, let old else { throw IntegrationFailure.assertion("open migration fixture") }
        let reset = "DROP TRIGGER visits_search_insert; DROP TRIGGER visits_search_delete; DROP TRIGGER visits_search_update; DROP TABLE visit_search; PRAGMA user_version=3"
        guard sqlite3_exec(old, reset, nil, nil, nil) == SQLITE_OK, sqlite3_close(old) == SQLITE_OK else { throw IntegrationFailure.assertion("prepare migration fixture") }
        _ = try HistoryCollector(databaseURL: target)
        try expect(try HistoryReader(databasePath: target.path).page(start: "2000-01-01", end: "2099-12-31", query: "かたかな").items.count, 1, "migration rebuilds existing search index")
        try collector.configure([])
        try expect(try count(target, "SELECT count(*) FROM visit_search WHERE visit_search MATCH 'かたかな'"), 0, "deselection removes source search entries")
    }
    static func rawSubstringMatches(_ url: URL, term: String) throws -> Set<Int64> {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else { throw IntegrationFailure.assertion("open raw search") }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT id FROM visits WHERE instr(norm_title,?)>0 OR instr(norm_url,?)>0", -1, &statement, nil) == SQLITE_OK, let statement else { throw IntegrationFailure.assertion("prepare raw search") }
        defer { sqlite3_finalize(statement) }
        term.withCString { ptr in
            sqlite3_bind_text(statement, 1, ptr, Int32(term.utf8.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            sqlite3_bind_text(statement, 2, ptr, Int32(term.utf8.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        }
        var ids = Set<Int64>()
        while sqlite3_step(statement) == SQLITE_ROW { ids.insert(sqlite3_column_int64(statement, 0)) }
        return ids
    }

    static func collectionDoesNotChangeSyncCursor(dir: URL) throws {
        let fixture = try HistoryFixture()
        try fixture.insertSafariVisit(url: "https://before.example/")
        let store = SafariHistoryStore(databaseURL: fixture.url, ledgerURL: fixture.ledgerURL)
        let agent = AgentService(history: store, stateURL: fixture.stateURL, secret: Data(repeating: 23, count: 32))
        _ = try agent.selectProfile("chrome:sync")
        let collector = try HistoryCollector(databaseURL: dir.appendingPathComponent("independent.sqlite"))
        try collector.configure([.init(id: "safari", browser: .safari, browserType: "Safari", profileName: "Default", path: fixture.url.path)])
        try collector.collectAll()
        try agent.setSyncEnabled(false)
        try fixture.insertSafariVisit(url: "https://after.example/")
        try collector.collectAll()
        let pull = try JSONSerialization.data(withJSONObject: ["version": 1, "operation": "pull", "stream": "safariToBrowser", "profileId": "chrome:sync"])
        let paused = try JSONSerialization.jsonObject(with: agent.browserExchange(pull)) as! [String: Any]
        try expect(paused["code"] as? String, "SYNC_PAUSED", "sync can be paused independently")
        let restarted = AgentService(history: store, stateURL: fixture.stateURL, secret: Data(repeating: 23, count: 32))
        try expect(try restarted.status().enabled, false, "sync pause persists across restart")
        try restarted.setSyncEnabled(true)
        let page = try JSONSerialization.jsonObject(with: restarted.browserExchange(pull)) as! [String: Any]
        let events = page["events"] as? [[String: Any]] ?? []
        try expect(events.count, 1, "collection never rewinds the sync cursor")
        try expect(events.first?["url"] as? String, "https://after.example/", "only post-baseline sync event delivered")
    }

    static func localIcons(dir: URL) throws {
        let profile = dir.appendingPathComponent("profile")
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        let browser = profile.appendingPathComponent("History")
        var native: OpaquePointer?
        guard sqlite3_open(browser.path, &native) == SQLITE_OK, let native else { throw IntegrationFailure.assertion("icon history fixture") }
        defer { sqlite3_close(native) }
        guard sqlite3_exec(native, "CREATE TABLE urls(id INTEGER PRIMARY KEY,url TEXT,title TEXT); CREATE TABLE visits(id INTEGER PRIMARY KEY,url INTEGER,visit_time INTEGER); INSERT INTO urls VALUES(1,'https://icons.example/page','icon'); INSERT INTO visits VALUES(1,1,13300000000000000)", nil, nil, nil) == SQLITE_OK else { throw IntegrationFailure.assertion("icon history SQL") }
        var iconDB: OpaquePointer?
        guard sqlite3_open(profile.appendingPathComponent("Favicons").path, &iconDB) == SQLITE_OK, let iconDB else { throw IntegrationFailure.assertion("icon fixture") }
        defer { sqlite3_close(iconDB) }
        guard sqlite3_exec(iconDB, "CREATE TABLE icon_mapping(page_url TEXT,icon_id INTEGER); CREATE TABLE favicon_bitmaps(icon_id INTEGER,image_data BLOB); INSERT INTO icon_mapping VALUES('https://icons.example/page',1); INSERT INTO favicon_bitmaps VALUES(1,X'89504E470D0A1A0A00000000')", nil, nil, nil) == SQLITE_OK else { throw IntegrationFailure.assertion("icon SQL") }
        let target = dir.appendingPathComponent("icons.sqlite")
        let collector = try HistoryCollector(databaseURL: target)
        try collector.configure([.init(id: "icons", browser: .chromium, browserType: "Chrome", profileName: "Default", path: browser.path)])
        try collector.collectAll()
        let page = try HistoryReader(databasePath: target.path).page(start: "2000-01-01", end: "2099-12-31")
        try expect(page.icons["icons.example"]?.hasPrefix("data:image/png;base64,"), true, "local Chromium icon exposed")
        try collector.configure([])
        try expect(try count(target, "SELECT count(*) FROM icons"), 0, "deselection removes source icons")
    }

    static func httpBoundary(reader: HistoryReader, directory: URL) throws {
        let server = try HistoryHTTPServer(reader: reader, assets: directory, owner: "owner@example.test")
        do { try server.start(port: 0) }
        catch HistoryHTTPServerError.listen(let code) where code == EPERM {
            print("SKIP: loopback HTTP test requires permission to bind a local socket")
            return
        }
        defer { server.stop() }
        let forbidden = try request(server.port, path: "/api/status", owner: nil)
        try expect(forbidden.status, 403, "identity is mandatory")
        let status = try request(server.port, path: "/api/status", owner: "owner@example.test")
        try expect(status.status, 200, "status is public through HTTP")
        try expect((status.body["sources"] as? [[String: Any]])?.count, 2, "HTTP status sources")
        let page = try request(server.port, path: "/api/records?start=2000-01-01&end=2099-12-31&limit=2", owner: "owner@example.test")
        try expect(page.status, 200, "HTTP records succeeds")
        try expect((page.body["items"] as? [[String: Any]])?.count, 2, "HTTP page limit")
        let search = try request(server.port, path: "/api/records?start=2000-01-01&end=2000-01-01&q=abc+%E3%81%8C%E3%81%A3%E3%81%93%E3%81%86+1+kg", owner: "owner@example.test")
        try expect((search.body["items"] as? [[String: Any]])?.count, 1, "HTTP form-encoded AND search")
        try expect(try request(server.port, path: "/api/records?start=bad&end=2099-12-31", owner: "owner@example.test").status, 422, "invalid HTTP input")
        try expect(try request(server.port, path: "/history.sqlite", owner: "owner@example.test").status, 404, "database is never served")
    }

    static func request(_ port: UInt16, path: String, owner: String?) throws -> (status: Int, body: [String: Any]) {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw IntegrationFailure.assertion("HTTP test socket") }
        defer { Darwin.close(fd) }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr = in_addr(s_addr: in_addr_t(0x7f000001).bigEndian)
        let connected = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard connected == 0 else { throw IntegrationFailure.assertion("HTTP test connect") }
        let header = owner.map { "Tailscale-User-Login: \($0)\r\n" } ?? ""
        let data = Data("GET \(path) HTTP/1.1\r\nHost: localhost\r\n\(header)Connection: close\r\n\r\n".utf8)
        let sent = data.withUnsafeBytes { send(fd, $0.baseAddress!, $0.count, 0) }
        guard sent == data.count else { throw IntegrationFailure.assertion("HTTP test send") }
        var response = Data(); var buf = [UInt8](repeating: 0, count: 4096)
        while true { let n = recv(fd, &buf, buf.count, 0); if n <= 0 { break }; response.append(contentsOf: buf[0..<n]) }
        guard let separator = response.range(of: Data("\r\n\r\n".utf8)),
              let head = String(data: response[..<separator.lowerBound], encoding: .utf8),
              let code = Int(head.split(separator: " ")[1]),
              let body = try JSONSerialization.jsonObject(with: response[separator.upperBound...]) as? [String: Any] else {
            throw IntegrationFailure.assertion("HTTP test response")
        }
        return (code, body)
    }

    static func count(_ url: URL, _ sql: String) throws -> Int64 {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else { throw IntegrationFailure.assertion("open collection DB") }
        defer { sqlite3_close(db) }
        var s: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &s, nil) == SQLITE_OK, let s else { throw IntegrationFailure.assertion("query collection DB") }
        defer { sqlite3_finalize(s) }
        guard sqlite3_step(s) == SQLITE_ROW else { throw IntegrationFailure.assertion("read collection DB") }
        return sqlite3_column_int64(s, 0)
    }
}
