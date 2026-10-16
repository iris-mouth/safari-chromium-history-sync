import CSQLite
import CryptoKit
import Foundation
import SafariSyncCore

enum ReviewRegressionTests {
    static func run() throws {
        let cases: [(String, () throws -> Void)] = [
            ("queued Safari writes reject a replaced database and invalid anchors", rejectsChangedHistoryBeforeQueuedWrites),
            ("legacy pending ACKs migrate without weakening tracked receipts", drainsLegacyPendingAcknowledgements),
            ("resolved backlog resets retry delay before another poll", resetsResolvedBacklogBeforeNewWork),
        ]
        var failures: [String] = []
        for (name, check) in cases {
            do { try check(); print("PASS: \(name)") }
            catch { failures.append("\(name): \(error)") }
        }
        if !failures.isEmpty { throw IntegrationFailure.assertion(failures.joined(separator: "\n")) }
    }

    private static func rewriteState(_ fixture: HistoryFixture, _ edit: (inout [String: Any]) throws -> Void) throws {
        let key = SymmetricKey(data: SHA256.hash(data: CloudDeliveryTests.secret + Data("agent-state-v1".utf8)))
        let box = try AES.GCM.SealedBox(combined: Data(contentsOf: fixture.stateURL))
        var state = try JSONSerialization.jsonObject(with: AES.GCM.open(box, using: key)) as! [String: Any]
        try edit(&state)
        try AES.GCM.seal(JSONSerialization.data(withJSONObject: state), using: key).combined!.write(to: fixture.stateURL)
    }

    private static func visitCount(_ url: URL) throws -> Int64 {
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK else { throw IntegrationFailure.assertion("fixture open") }
        defer { sqlite3_close(db) }
        var query: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM history_visits", -1, &query, nil) == SQLITE_OK else {
            throw IntegrationFailure.assertion("fixture count")
        }
        defer { sqlite3_finalize(query) }
        guard sqlite3_step(query) == SQLITE_ROW else { throw IntegrationFailure.assertion("fixture row") }
        return sqlite3_column_int64(query, 0)
    }

    static func rejectsChangedHistoryBeforeQueuedWrites() throws {
        for mutation in ["replacement", "missingAnchor", "changedAnchor"] {
            let fixture = try HistoryFixture()
            try fixture.insertSafariVisit(url: "https://example.com/anchor")
            let original = CloudDeliveryTests.service(fixture)
            _ = try original.selectProfile(CloudDeliveryTests.profile)
            // The durable state at a crash immediately before the external write.
            try rewriteState(fixture) { state in
                var cloud = CloudDeliveryCoordinator()
                try cloud.reserve(id: "pending-at-crash", profileID: CloudDeliveryTests.profile, provider: .safari,
                    url: URL(string: "https://example.com/pending-at-crash")!, now: .now)
                state["cloud"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(cloud))
            }
            let previous = fixture.url.appendingPathExtension("previous")
            defer { try? FileManager.default.removeItem(at: previous) }
            if mutation == "replacement" {
                let replacement = try HistoryFixture()
                try FileManager.default.moveItem(at: fixture.url, to: previous)
                try FileManager.default.copyItem(at: replacement.url, to: fixture.url)
            } else if mutation == "missingAnchor" {
                try fixture.exec("DELETE FROM history_visits")
            } else {
                try fixture.exec("UPDATE history_visits SET visit_time=visit_time+1")
            }
            let count = try visitCount(fixture.url)
            let restarted = CloudDeliveryTests.service(fixture)
            let expected: SafariHistoryError = mutation == "replacement" ? .historyIdentityChanged : .historyAnchorInvalid
            for operation in ["poll", "publish", "probe"] {
                do {
                    switch operation {
                    case "poll": try restarted.pollCloud(safariIsRunning: true) { false }
                    case "publish": try CloudDeliveryTests.publish(restarted, id: "new-publish")
                    default:
                        _ = try restarted.cloudCommand(MenuCommand(operation: "cloudProbe",
                            profileID: CloudDeliveryTests.profile, provider: .safari))
                    }
                    throw IntegrationFailure.assertion("\(operation) accepted \(mutation)")
                } catch let error as SafariHistoryError { try expect(error, expected, "write guard") }
                try expect(try visitCount(fixture.url), count, "\(operation) never writes after \(mutation)")
            }
        }
    }

    static func drainsLegacyPendingAcknowledgements() throws {
        let fixture = try HistoryFixture()
        let original = CloudDeliveryTests.service(fixture)
        let profile = CloudDeliveryTests.profile
        _ = try original.selectProfile(profile)
        try rewriteState(fixture) { state in
            state["schemaVersion"] = 2
            state.removeValue(forKey: "cloud")
            state.removeValue(forKey: "browserACKSequences")
            state["nextSafariSequence"] = 2
            state["outbox"] = [["eventID": "legacy-pending", "sequence": 1,
                "url": "https://example.com/legacy-pending", "profileID": profile]]
        }
        let upgraded = CloudDeliveryTests.service(fixture)
        let reply = try CloudDeliveryTests.exchange(upgraded, ["operation": "ack", "stream": "safariToBrowser",
            "throughSequence": 1])
        try expect(reply["status"] as? String, "ACKNOWLEDGED", "capable worker may drain an untracked legacy ACK")
        try expect(try upgraded.status().pendingSafariToBrowser, 0, "upgrade releases legacy pending work")
        try expect(try CloudDeliveryTests.diagnostics(upgraded).summary.monitored, 0, "legacy ACK never fabricates cloud evidence")
        try fixture.insertSafariVisit(url: "https://example.com/new-tracked")
        let page = try CloudDeliveryTests.exchange(upgraded, ["operation": "pull", "stream": "safariToBrowser"])
        let event = (page["events"] as! [[String: Any]])[0]
        let invalid = try CloudDeliveryTests.exchange(upgraded, ["operation": "ack", "stream": "safariToBrowser",
            "throughSequence": event["sequence"]!])
        try expect(invalid["code"] as? String, "INVALID_LOCAL_RECEIPT", "tracked events still require exact evidence")
        try expect(try upgraded.status().pendingSafariToBrowser, 1, "invalid tracked ACK retains work")
    }

    static func resetsResolvedBacklogBeforeNewWork() throws {
        var cloud = CloudDeliveryCoordinator()
        let profile = CloudDeliveryTests.profile
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        try cloud.reserve(id: "old", profileID: profile, provider: .safari,
            url: URL(string: "https://example.com/old")!, now: start)
        try cloud.recordLocalDelivery(id: "old", visitID: "1", time: start, now: start,
            generation: 10, databaseIdentity: "fixture")
        cloud.setSafariAssist(enabled: true, now: start)
        let snapshot = SafariCloudSnapshot(databaseIdentity: "fixture", checkpoint: 0, matchingVisitIDs: ["1", "2"])
        for elapsed in [110.0, 410, 1010, 2210, 4610] {
            let now = start.addingTimeInterval(elapsed)
            let batch = cloud.safariBatch(profileID: profile, now: now)
            _ = cloud.reconcileSafari(batch: batch, snapshot: snapshot, now: now, isRunning: true)
            try expect(cloud.reserveSafariAssist(batch: batch, now: now, isRunning: true) != nil, true, "setup attempt")
        }
        try cloud.observeRemote(id: "old", profileID: profile, result: "seen", device: "fixture",
            now: start.addingTimeInterval(4620))
        try cloud.reserve(id: "new", profileID: profile, provider: .safari,
            url: URL(string: "https://example.com/new")!, now: start.addingTimeInterval(4621))
        try cloud.recordLocalDelivery(id: "new", visitID: "2", time: start.addingTimeInterval(4621),
            now: start.addingTimeInterval(4621), generation: 11, databaseIdentity: "fixture")
        cloud = try JSONDecoder().decode(CloudDeliveryCoordinator.self, from: JSONEncoder().encode(cloud))
        let now = start.addingTimeInterval(4720)
        let batch = cloud.safariBatch(profileID: profile, now: now)
        _ = cloud.reconcileSafari(batch: batch, snapshot: snapshot, now: now, isRunning: true)
        let assist = cloud.diagnostics(profileID: profile).safariAssist!
        try expect(assist.attemptsWithoutProgress, 0, "resolved backlog clears stalled attempt count")
        try expect(assist.nextAttemptAt, start.addingTimeInterval(4910), "new backlog uses five-minute floor")
        try expect(cloud.reserveSafariAssist(batch: batch, now: now, isRunning: true), nil, "never bypass floor")
        try expect(cloud.reserveSafariAssist(batch: batch, now: start.addingTimeInterval(4910), isRunning: true) != nil,
            true, "new work resumes without hourly delay")
    }
}
