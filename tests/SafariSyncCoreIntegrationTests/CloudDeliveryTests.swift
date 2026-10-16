import Foundation
import CryptoKit
import SafariSyncCore

enum CloudDeliveryTests {
    static let profile = "edge:CloudTests"
    static let secret = Data(repeating: 17, count: 32)

    static func run() throws {
        try monitorsOnlyOwnedVisitsAndSeparatesCheckpointsFromArrival()
        try persistsBrowserReceiptsAcrossAckLoss()
        try recoversWriteAheadIntentWithoutDuplicatingSafari()
        try scopesAndDeduplicatesRepairPlans()
        try suppressesRemovedVisits()
        try comparesOnlyPositiveReceiverEvidence()
        try boundsSchedulingAndRetention()
        try migratesVersionTwoWithoutInventingEvidence()
        try browserReplayAndDelayedRemovalRespectNewAttempts()
        try filtersAndBoundsFullReceiverExports()
        try pagesDiagnosticsWithinIPCAndBackpressuresCapacity()
        try cancelsInFlightProbeOnAccountRebind()
        try automatesOnlyPendingOwnedSafariAndDoesNotRelayControlVisits()
        try retriesPendingSafariBeyondSixAttemptsAcrossRestart()
        try backsOffFailuresAndResetsOnlyOnNativeProgress()
        try sharesLaunchAndNavigationCooldownAndStopsOnReceiverEvidence()
        try migratesExhaustedAssistAndLaunchBudgets()
        try ReviewRegressionTests.run()
    }

    static func service(_ fixture: HistoryFixture) -> AgentService {
        AgentService(history: SafariHistoryStore(databaseURL: fixture.url, ledgerURL: fixture.ledgerURL),
            stateURL: fixture.stateURL, secret: secret)
    }

    static func exchange(_ service: AgentService, _ fields: [String: Any]) throws -> [String: Any] {
        var message = fields
        message["version"] = 1
        message["profileId"] = profile
        message["capabilities"] = ["cloud-delivery-v1"]
        return try JSONSerialization.jsonObject(with: service.browserExchange(
            JSONSerialization.data(withJSONObject: message))) as! [String: Any]
    }

    static func diagnostics(_ service: AgentService) throws -> CloudDiagnostics {
        try service.cloudCommand(MenuCommand(operation: "cloudStatus", profileID: profile))
    }

    static func publish(_ service: AgentService, id: String = "owned", url: String = "https://example.com/owned") throws {
        let reply = try exchange(service, ["operation": "publish", "stream": "browserToSafari",
            "events": [["eventId": id, "sequence": 1, "url": url, "title": "Preserved title"]]])
        try expect(reply["status"] as? String, "ACCEPTED", "local Safari ACK")
    }

    static func rejects(_ code: String, _ work: () throws -> Void) throws {
        do {
            try work()
            throw IntegrationFailure.assertion("expected \(code)")
        } catch let error as TypedError { try expect(error.code, code, "typed rejection") }
    }

    static func monitorsOnlyOwnedVisitsAndSeparatesCheckpointsFromArrival() throws {
        let fixture = try HistoryFixture()
        var agent = service(fixture)
        _ = try agent.selectProfile(profile)
        try fixture.insertSafariVisit(url: "https://example.com/unrelated")
        var launches = 0
        try agent.pollCloud(safariIsRunning: false) { launches += 1; return true }
        try expect(launches, 0, "unrelated global generation does not launch Safari")
        try publish(agent)
        try publish(agent, id: "owned-2", url: "https://example.com/owned-2")
        agent = service(fixture)
        let rows = try diagnostics(agent).deliveries
        let now = rows.map { $0.localAppliedAt! }.max()!
        try agent.pollCloud(now: now.addingTimeInterval(10), safariIsRunning: false) { launches += 1; return true }
        try expect(launches, 0, "new visits coalesce before launch")
        try agent.pollCloud(now: now.addingTimeInterval(20), safariIsRunning: false) { launches += 1; return true }
        try expect(launches, 1, "one coalesced launch")
        try agent.pollCloud(now: now.addingTimeInterval(55), safariIsRunning: true) { launches += 1; return true }
        try expect(launches, 1, "running Safari is not recycled or relaunched")
        try expect(try fixture.scalarInt("SELECT value FROM metadata WHERE key='last_synced_generation'"), 40,
            "app never acknowledges iCloud")
        try fixture.exec("UPDATE metadata SET value=44 WHERE key='last_synced_generation'")
        try agent.pollCloud(now: now.addingTimeInterval(200), safariIsRunning: true) { launches += 1; return true }
        let status = try diagnostics(agent)
        try expect(status.summary.checkpointCovered, 2, "own generations covered")
        try expect(status.summary.remoteSeen, 0, "checkpoint does not invent receiver evidence")
    }

    static func automatesOnlyPendingOwnedSafariAndDoesNotRelayControlVisits() throws {
        let fixture = try HistoryFixture()
        var agent = service(fixture)
        _ = try agent.selectProfile(profile)
        try publish(agent)
        let applied = try diagnostics(agent).deliveries[0].localAppliedAt!
        var controls: [URL] = []
        func poll(_ seconds: Double, running: Bool = true) throws {
            try agent.pollCloud(now: applied.addingTimeInterval(seconds), safariIsRunning: running,
                assistSafari: { url in
                    // IPC remains responsive while Safari handles an application event.
                    _ = try? agent.status()
                    controls.append(url)
                    return "tabReused"
                }, launchSafari: { true })
        }
        try poll(20)
        try expect(controls.count, 0, "old state defaults assist off")
        let command = MenuCommand(operation: "cloudSafariAssist", profileID: profile, result: "enable")
        _ = try agent.cloudCommand(command, now: applied.addingTimeInterval(30))
        try poll(35)
        try expect(controls.count, 0, "give native sync 90 seconds before navigating")
        try poll(110)
        try expect(controls.count, 1, "pending owned visit triggers one control navigation")
        agent = service(fixture)
        try poll(210)
        try expect(controls.count, 1, "restart retains durable cooldown")
        try poll(420)
        try expect(controls.count, 2, "cooldown expiry retries despite accumulated native backoff")
        let assist = try diagnostics(agent).safariAssist!
        try fixture.insertSafariVisit(url: assist.controlURL.absoluteString)
        let alternate = SafariSyncAssist.alternateControlURL(for: assist.controlURL)!
        try fixture.insertSafariVisit(url: alternate.absoluteString)
        let page = try exchange(agent, ["operation": "pull", "stream": "safariToBrowser"])
        try expect((page["events"] as! [[String: Any]]).count, 0, "neither helper URL echoes into Edge")
        try fixture.exec("UPDATE metadata SET value=999 WHERE key='last_synced_generation'")
        try poll(600)
        try expect(controls.count, 2, "checkpoint coverage stops automatic navigations")
        try expect(try diagnostics(agent).summary.remoteSeen, 0, "navigation cannot assert mobile arrival")
        _ = try agent.cloudCommand(MenuCommand(operation: "cloudSafariAssist", profileID: profile, result: "disable"))
        try expect(try diagnostics(agent).safariAssist?.enabled, false, "can disable from diagnostics")

        var limiter = SafariSyncAssist()
        limiter.setEnabled(true)
        var at = applied
        for interval in [300.0, 600, 1200, 2400, 3600, 3600, 3600, 3600] {
            try expect(limiter.reserve(now: at) != nil, true, "retry continues without a daily cap")
            try expect(limiter.nextAttemptAt, at.addingTimeInterval(interval), "progress-dependent retry interval")
            limiter.record(result: "tabReused")
            limiter.setEnabled(false)
            limiter.setEnabled(true)
            limiter = try JSONDecoder().decode(SafariSyncAssist.self, from: JSONEncoder().encode(limiter))
            try expect(limiter.reserve(now: at.addingTimeInterval(interval - 1)), nil,
                "successful navigation, toggles and restarts cannot bypass native-progress backoff")
            at = at.addingTimeInterval(interval)
        }
        limiter.record(result: "permissionDenied")
        try expect(limiter.enabled, false, "denial suspends attempts")
        try expect(limiter.reserve(now: at.addingTimeInterval(90000)), nil, "no repeated permission prompts")
        try expect(SafariSyncAssist.isControlURL(URL(string: "https://example.com/?safari-sync-control=x")!), false,
            "never admit arbitrary text to script interpolation")
        try expect(SafariSyncAssist.isControlURL(alternate), true, "accept the generated refresh variant")
        try expect(assist.owns(SafariSyncAssist().controlURL), false, "do not claim another helper tab")
        for suffix in ["&other=1", "&safari-sync-refresh=2", "#fragment", "&safari-sync-refresh=1&extra=1"] {
            try expect(SafariSyncAssist.isControlURL(URL(string: assist.controlURL.absoluteString + suffix)!), false,
                "reject uncontrolled refresh URLs")
        }
    }

    static func retriesPendingSafariBeyondSixAttemptsAcrossRestart() throws {
        let fixture = try HistoryFixture()
        var agent = service(fixture)
        _ = try agent.selectProfile(profile)
        try publish(agent)
        let applied = try diagnostics(agent).deliveries[0].localAppliedAt!
        _ = try agent.cloudCommand(MenuCommand(operation: "cloudSafariAssist", profileID: profile,
            result: "enable"), now: applied)
        var attempts = 0
        for index in 0..<8 {
            if index == 6 { agent = service(fixture) }
            try agent.pollCloud(now: applied.addingTimeInterval(110 + Double(index) * 3601),
                safariIsRunning: true, assistSafari: { _ in
                    attempts += 1
                    return "tabReused"
                }, launchSafari: { true })
            try expect(attempts, index + 1, "pending Safari retries beyond six attempts without manual action")
        }
        try expect(try diagnostics(agent).deliveries[0].remoteState, "unverified",
            "automatic retries never claim receiving-device arrival")
    }

    static func backsOffFailuresAndResetsOnlyOnNativeProgress() throws {
        let fixture = try HistoryFixture()
        var agent = service(fixture)
        _ = try agent.selectProfile(profile)
        try publish(agent)
        let applied = try diagnostics(agent).deliveries[0].localAppliedAt!
        _ = try agent.cloudCommand(MenuCommand(operation: "cloudSafariAssist", profileID: profile,
            result: "enable"), now: applied)
        var attempts = 0
        var reservationSavedBeforeWork = true
        func poll(_ seconds: TimeInterval) throws {
            try agent.pollCloud(now: applied.addingTimeInterval(seconds), safariIsRunning: true,
                assistSafari: { _ in
                    let saved = try? diagnostics(service(fixture)).safariAssist
                    reservationSavedBeforeWork = reservationSavedBeforeWork && saved?.lastResult == "reserved"
                    attempts += 1
                    return "navigationTimedOut"
                }, launchSafari: { true })
        }
        try poll(110)
        try poll(420)
        try poll(740)
        try expect(attempts, 2, "unchanged checkpoint backs off a failed navigation")
        agent = service(fixture)
        try poll(1050)
        try expect(attempts, 3, "failed navigation retries automatically after restart")
        try fixture.exec("UPDATE metadata SET value=41 WHERE key='last_synced_generation'")
        try poll(1120)
        try expect(attempts, 3, "partial progress cannot bypass the five-minute floor")
        try poll(1420)
        try expect(attempts, 4, "native checkpoint progress restores a prompt retry")
        try poll(1750)
        try publish(agent, id: "new-during-stall", url: "https://example.com/new-during-stall")
        try poll(2080)
        try expect(attempts, 5, "new arrivals during a stall do not reset backoff")
        try fixture.exec("UPDATE metadata SET value=999 WHERE key='last_synced_generation'")
        try poll(2500)
        try expect(attempts, 5, "resolved work stops retrying after failures")
        try expect(reservationSavedBeforeWork, true, "reserve before slow or failed external work")
    }

    static func sharesLaunchAndNavigationCooldownAndStopsOnReceiverEvidence() throws {
        let fixture = try HistoryFixture()
        var agent = service(fixture)
        _ = try agent.selectProfile(profile)
        try publish(agent)
        let applied = try diagnostics(agent).deliveries[0].localAppliedAt!
        _ = try agent.cloudCommand(MenuCommand(operation: "cloudSafariAssist", profileID: profile,
            result: "enable"), now: applied)
        var actions = 0
        func poll(_ seconds: TimeInterval, running: Bool) throws {
            try agent.pollCloud(now: applied.addingTimeInterval(seconds), safariIsRunning: running,
                assistSafari: { _ in actions += 1; return "tabReused" },
                launchSafari: { actions += 1; return false })
        }
        try poll(20, running: false)
        try poll(110, running: true)
        try expect(actions, 1, "a failed hidden launch and navigation share their cooldown")
        agent = service(fixture)
        try poll(330, running: true)
        try expect(actions, 2, "navigation retries after the failed launch without manual action")
        _ = try agent.cloudCommand(MenuCommand(operation: "cloudObserve", profileID: profile,
            deliveryID: "owned", result: "seen", device: "fixture"), now: applied.addingTimeInterval(340))
        try poll(1000, running: true)
        try expect(actions, 2, "receiving-device evidence stops automatic work")
        try publish(agent, id: "new-episode", url: "https://example.com/new-episode")
        try poll(1070, running: true)
        try expect(actions, 3, "new pending work after a resolved episode can retry promptly")
        try expect(try diagnostics(agent).summary.remoteSeen, 1, "do not transfer prior receiver evidence")
    }

    static func migratesExhaustedAssistAndLaunchBudgets() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let control = SafariSyncAssist().controlURL
        let legacy = try JSONSerialization.data(withJSONObject: ["enabled": true, "lastResult": "tabReused",
            "lastAttempt": now.timeIntervalSinceReferenceDate, "controlURL": control.absoluteString,
            "attempts": (0..<6).map { now.addingTimeInterval(-Double($0) * 301).timeIntervalSinceReferenceDate }])
        var assist = try JSONDecoder().decode(SafariSyncAssist.self, from: legacy)
        try expect(assist.controlURL, control, "build 611 migration retains the dedicated tab")
        try expect(assist.reserve(now: now.addingTimeInterval(299)), nil, "migration preserves last cooldown")
        try expect(assist.reserve(now: now.addingTimeInterval(300)), control, "exhausted daily budget resumes automatically")

        var coordinator = CloudDeliveryCoordinator()
        try coordinator.reserve(id: "legacy", profileID: profile, provider: .safari,
            url: URL(string: "https://example.com/legacy")!, now: now)
        try coordinator.recordLocalDelivery(id: "legacy", visitID: "1", time: now, now: now,
            generation: 1, databaseIdentity: "fixture")
        var state = try JSONSerialization.jsonObject(with: JSONEncoder().encode(coordinator)) as! [String: Any]
        state["safariLaunches"] = [now.timeIntervalSinceReferenceDate]
        var deliveries = state["deliveries"] as! [[String: Any]]
        deliveries[0]["nextCheckAt"] = now.addingTimeInterval(21600).timeIntervalSinceReferenceDate
        state["deliveries"] = deliveries
        coordinator = try JSONDecoder().decode(CloudDeliveryCoordinator.self, from: JSONSerialization.data(withJSONObject: state))
        let snapshot = SafariCloudSnapshot(databaseIdentity: "fixture", checkpoint: 0, matchingVisitIDs: ["1"])
        for (delay, expected) in [(100.0, false), (300, true)] {
            let at = now.addingTimeInterval(delay)
            let batch = coordinator.safariBatch(profileID: profile, now: at, isRunning: false)
            try expect(coordinator.reconcileSafari(batch: batch, snapshot: snapshot, now: at, isRunning: false),
                expected, "legacy hidden launches retain cooldown while dropping the daily cap")
        }
    }

    static func persistsBrowserReceiptsAcrossAckLoss() throws {
        let fixture = try HistoryFixture()
        var agent = service(fixture)
        _ = try agent.selectProfile(profile)
        try fixture.insertSafariVisit(url: "https://example.com/from-safari")
        let page = try exchange(agent, ["operation": "pull", "stream": "safariToBrowser"])
        let event = (page["events"] as! [[String: Any]])[0]
        let time = Date().timeIntervalSince1970 * 1000
        var ack: [String: Any] = ["operation": "ack", "stream": "safariToBrowser",
            "throughSequence": event["sequence"]!, "localReceipts": [["eventId": event["eventId"]!,
            "sequence": event["sequence"]!, "visitId": "", "visitTime": time]]]
        try expect(try exchange(agent, ack)["code"] as? String, "INVALID_LOCAL_RECEIPT", "invalid evidence rejected")
        try expect(try agent.status().pendingSafariToBrowser, 1, "invalid ACK preserves queue")
        ack["localReceipts"] = [["eventId": event["eventId"]!, "sequence": event["sequence"]!,
            "visitId": "browser-101", "visitTime": time]]
        try expect(try exchange(agent, ack)["status"] as? String, "ACKNOWLEDGED", "first ACK")
        agent = service(fixture)
        try expect(try exchange(agent, ack)["status"] as? String, "ACKNOWLEDGED", "lost ACK is idempotent after restart")
        let status = try diagnostics(agent)
        try expect(status.summary.monitored, 1, "local ACK keeps journal")
        try expect(status.summary.browserNotObservable, 1, "public interface cannot claim account upload")
        try expect(status.deliveries[0].destinationTime, Date(timeIntervalSince1970: time / 1000), "actual target timestamp")
        _ = try exchange(agent, ["operation": "cloudRemoval", "removedURLs": ["https://example.com/from-safari"],
            "removedAt": Date().timeIntervalSince1970 * 1000])
        try expect(try diagnostics(agent).summary.suppressed, 1, "browser deletion suppresses repair")
    }

    static func recoversWriteAheadIntentWithoutDuplicatingSafari() throws {
        let fixture = try HistoryFixture()
        let first = service(fixture)
        _ = try first.selectProfile(profile)
        try publish(first)
        let original = try diagnostics(first).deliveries[0]
        // Reconstruct the saved intent at the DB-commit/journal-commit crash boundary.
        let key = SymmetricKey(data: SHA256.hash(data: secret + Data("agent-state-v1".utf8)))
        let box = try AES.GCM.SealedBox(combined: Data(contentsOf: fixture.stateURL))
        var state = try JSONSerialization.jsonObject(with: AES.GCM.open(box, using: key)) as! [String: Any]
        var cloud = state["cloud"] as! [String: Any]
        var entries = cloud["deliveries"] as! [[String: Any]]
        for key in ["localAppliedAt", "destinationVisitID", "destinationTime", "databaseIdentity", "generation"] {
            entries[0].removeValue(forKey: key)
        }
        cloud["deliveries"] = entries
        state["cloud"] = cloud
        state["deliveredSafariVisitIDs"] = []
        try AES.GCM.seal(JSONSerialization.data(withJSONObject: state), using: key).combined!.write(to: fixture.stateURL)
        let restarted = service(fixture)
        try restarted.pollCloud(now: Date().addingTimeInterval(120), safariIsRunning: true) { false }
        try expect(try fixture.scalarInt("SELECT COUNT(*) FROM history_visits"), 1, "ledger prevents crash duplication")
        try expect(try diagnostics(restarted).deliveries[0].destinationTime, original.destinationTime, "ledger recovers original delivery time")
        let page = try exchange(restarted, ["operation": "pull", "stream": "safariToBrowser"])
        try expect((page["events"] as! [[String: Any]]).count, 0, "recovered insert does not echo")
        try expect(try fixture.scalarText("SELECT title FROM history_visits"), "Preserved title", "intent preserves title")
    }

    static func scopesAndDeduplicatesRepairPlans() throws {
        let fixture = try HistoryFixture()
        let agent = service(fixture)
        _ = try agent.selectProfile(profile)
        try publish(agent)
        let plan = try agent.cloudCommand(MenuCommand(operation: "cloudPrepareReplay", profileID: profile,
            deliveryID: "owned")).plan!
        let execute = MenuCommand(operation: "cloudExecuteReplay", profileID: profile, planID: plan.id)
        _ = try agent.cloudCommand(execute)
        _ = try service(fixture).cloudCommand(execute)
        try expect(try fixture.scalarInt("SELECT COUNT(*) FROM history_visits"), 2, "repair request replay creates only one replacement")
        let repaired = try diagnostics(agent).deliveries.first { $0.id == plan.attemptID }!
        try expect(repaired.parentID, "owned", "repair retains logical parent")
        try expect(repaired.remoteState, "unverified", "replacement does not inherit cloud success")
        let stale = try agent.cloudCommand(MenuCommand(operation: "cloudPrepareReplay", profileID: profile,
            deliveryID: "owned")).plan!
        _ = try agent.cloudCommand(MenuCommand(operation: "cloudRebind", profileID: profile, provider: .safari))
        try rejects("STALE_CLOUD_REPAIR_PLAN") {
            _ = try agent.cloudCommand(MenuCommand(operation: "cloudExecuteReplay", profileID: profile, planID: stale.id))
        }
        try expect(try diagnostics(agent).summary.monitored, 0, "old account evidence is excluded")
        _ = try agent.selectProfile("chrome:Another")
        try rejects("PROFILE_NOT_ACTIVE") { _ = try diagnostics(agent) }
        try expect(try fixture.scalarInt("SELECT COUNT(*) FROM history_visits"), 2, "scope changes never rewrite history")
    }

    static func suppressesRemovedVisits() throws {
        let fixture = try HistoryFixture()
        let agent = service(fixture)
        _ = try agent.selectProfile(profile)
        try publish(agent)
        try fixture.exec("DELETE FROM history_visits")
        try agent.pollCloud(now: Date().addingTimeInterval(30), safariIsRunning: false) {
            throw IntegrationFailure.assertion("deleted visit must not trigger launch")
        }
        try expect(try diagnostics(agent).summary.suppressed, 1, "disappearance is recorded")
        try rejects("CLOUD_REPLAY_NOT_ALLOWED") {
            _ = try agent.cloudCommand(MenuCommand(operation: "cloudPrepareReplay", profileID: profile, deliveryID: "owned"))
        }
        try expect(try fixture.scalarInt("SELECT COUNT(*) FROM history_visits"), 0, "no resurrection")
    }

    static func comparesOnlyPositiveReceiverEvidence() throws {
        var coordinator = CloudDeliveryCoordinator()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let url = URL(string: "https://example.com/repeated?keep=1")!
        for (id, time) in [("older", now.addingTimeInterval(-10)), ("latest", now)] {
            try coordinator.reserve(id: id, profileID: profile, provider: .safari, url: url, now: time)
            try coordinator.recordLocalDelivery(id: id, visitID: id, time: time, now: time,
                generation: 1, databaseIdentity: "fixture")
        }
        let export = try JSONSerialization.data(withJSONObject: [
            "metadata": ["browser_name": "Safari", "data_type": "history", "schema_version": 1,
                "export_time_usec": now.addingTimeInterval(5).timeIntervalSince1970 * 1_000_000] as [String: Any],
            "history": [["url": url.absoluteString, "time_usec": now.timeIntervalSince1970 * 1_000_000]],
        ])
        try coordinator.compareSafariExport(export, profileID: profile, now: now.addingTimeInterval(10))
        try expect(coordinator.summary(profileID: profile).remoteSeen, 1, "latest visit export does not confirm every repeated visit")
        try coordinator.observeRemote(id: "older", profileID: profile, result: "notObserved", device: "iPhone", now: now)
        try expect(coordinator.deliveries.first { $0.id == "older" }!.remoteState, "notObserved", "non-observation is not cloud absence")
        try rejects("INVALID_SAFARI_EXPORT") { try coordinator.compareSafariExport(Data("{}".utf8), profileID: profile, now: now) }
    }

    static func boundsSchedulingAndRetention() throws {
        var coordinator = CloudDeliveryCoordinator()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        try coordinator.reserve(id: "owned", profileID: profile, provider: .safari,
            url: URL(string: "https://example.com/owned")!, now: now)
        try coordinator.recordLocalDelivery(id: "owned", visitID: "1", time: now, now: now,
            generation: 1, databaseIdentity: "fixture")
        let snapshot = SafariCloudSnapshot(databaseIdentity: "fixture", checkpoint: 0, matchingVisitIDs: ["1"])
        var launches = 0
        for delay in [20.0, 400, 1400, 3500, 12000, 36000, 80000] {
            let at = now.addingTimeInterval(delay)
            let batch = coordinator.safariBatch(profileID: profile, now: at)
            if coordinator.reconcileSafari(batch: batch, snapshot: snapshot, now: at, isRunning: false) { launches += 1 }
        }
        try expect(launches, 7, "pending hidden launches continue beyond six with bounded frequency")
        try coordinator.reserve(id: "new", profileID: profile, provider: .browser,
            url: URL(string: "https://example.com/new")!, now: now.addingTimeInterval(CloudDeliveryCoordinator.retention + 1))
        try expect(coordinator.summary(profileID: profile).expiredUnverified, 1, "expiry is never success")
        try expect(coordinator.summary(profileID: profile).remoteSeen, 0, "expiry creates no arrival evidence")
    }

    static func migratesVersionTwoWithoutInventingEvidence() throws {
        let fixture = try HistoryFixture()
        let key = SymmetricKey(data: SHA256.hash(data: secret + Data("agent-state-v1".utf8)))
        let legacy = try JSONSerialization.data(withJSONObject: ["schemaVersion": 2,
            "activeProfileID": profile, "enabled": true])
        try AES.GCM.seal(legacy, using: key).combined!.write(to: fixture.stateURL)
        let agent = service(fixture)
        try expect(try agent.status().activeProfileID, profile, "v2 profile survives migration")
        try expect(try agent.status().cloud?.monitored, 0, "migration starts at a cloud monitoring baseline")
        _ = try agent.selectProfile(profile)
        try expect(try diagnostics(agent).summary.remoteSeen, 0, "no inferred old cloud receipts")
    }

    static func browserReplayAndDelayedRemovalRespectNewAttempts() throws {
        let fixture = try HistoryFixture()
        let agent = service(fixture)
        _ = try agent.selectProfile(profile)
        try fixture.insertSafariVisit(url: "https://example.com/browser-replay")
        let page = try exchange(agent, ["operation": "pull", "stream": "safariToBrowser"])
        let event = (page["events"] as! [[String: Any]])[0]
        _ = try exchange(agent, ["operation": "ack", "stream": "safariToBrowser", "throughSequence": event["sequence"]!,
            "localReceipts": [["eventId": event["eventId"]!, "sequence": event["sequence"]!,
                "visitId": "real-browser-visit", "visitTime": Date().timeIntervalSince1970 * 1000]]])
        let removedAt = Date()
        let plan = try agent.cloudCommand(MenuCommand(operation: "cloudPrepareReplay", profileID: profile,
            deliveryID: event["eventId"] as? String), now: removedAt.addingTimeInterval(2)).plan!
        let execute = MenuCommand(operation: "cloudExecuteReplay", profileID: profile, planID: plan.id)
        _ = try agent.cloudCommand(execute, now: removedAt.addingTimeInterval(3))
        _ = try agent.cloudCommand(execute, now: removedAt.addingTimeInterval(4))
        try expect(try agent.status().pendingSafariToBrowser, 1, "browser replay is enqueued once")
        _ = try agent.cloudCommand(MenuCommand(operation: "cloudProbe", profileID: profile, provider: .browser),
            now: removedAt.addingTimeInterval(5))
        _ = try exchange(agent, ["operation": "cloudRemoval", "allHistoryRemoved": true,
            "removedAt": removedAt.timeIntervalSince1970 * 1000])
        try expect(try diagnostics(agent).summary.suppressed, 1, "delayed deletion applies only to older obligations")
        try expect(try agent.status().pendingSafariToBrowser, 2, "post-deletion explicit replay and probe survive")
        let next = try exchange(agent, ["operation": "pull", "stream": "safariToBrowser"])
        let nextEvents = next["events"] as! [[String: Any]]
        try expect(nextEvents.count, 2, "only new attempts are delivered")
        let last = nextEvents.last!
        let invalidPrefix = try exchange(agent, ["operation": "ack", "stream": "safariToBrowser",
            "throughSequence": last["sequence"]!, "localReceipts": [["eventId": last["eventId"]!,
                "sequence": last["sequence"]!, "visitId": "unrelated", "visitTime": Date().timeIntervalSince1970 * 1000]]])
        try expect(invalidPrefix["code"] as? String, "INVALID_LOCAL_RECEIPT", "cumulative ACK cannot skip earlier evidence")
        try expect(try agent.status().pendingSafariToBrowser, 2, "invalid cumulative ACK preserves both jobs")
    }

    static func filtersAndBoundsFullReceiverExports() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var owned = Set<String>()
        var items: [[String: Any]] = []
        for index in 0..<350 {
            let url = "https://example.com/\(index)/" + String(repeating: "a", count: 900)
            owned.insert(url)
            items.append(["url": url, "time_usec": now.timeIntervalSince1970 * 1_000_000])
        }
        let repeated = items[0]["url"] as! String
        items.append(["url": repeated, "time_usec": now.addingTimeInterval(-10).timeIntervalSince1970 * 1_000_000])
        items.append(["url": "https://example.com/unowned", "time_usec": now.timeIntervalSince1970 * 1_000_000])
        let input = try JSONSerialization.data(withJSONObject: [
            "metadata": ["browser_name": "Safari", "data_type": "history", "schema_version": 1,
                "export_time_usec": now.timeIntervalSince1970 * 1_000_000] as [String: Any], "history": items])
        let batches = try SafariReceiverExport.comparisonBatches(data: input, ownedURLs: owned, now: now)
        try expect(batches.count > 1, true, "full export is divided into bounded snapshots")
        var count = 0
        for batch in batches {
            try expect(batch.utf8.count <= 256 * 1024, true, "IPC snapshot byte bound")
            try expect(batch.contains("unowned"), false, "unrelated receiver history stays in Menu")
            let parsed = try JSONSerialization.jsonObject(with: Data(batch.utf8)) as! [String: Any]
            count += (parsed["history"] as! [[String: Any]]).count
        }
        try expect(count, owned.count, "deduplication uses the latest URL time before splitting")
    }

    static func pagesDiagnosticsWithinIPCAndBackpressuresCapacity() throws {
        var coordinator = CloudDeliveryCoordinator()
        let now = Date()
        for index in 0..<50 {
            let url = URL(string: "https://example.com/\(index)/" + String(repeating: "/", count: 7800))!
            try coordinator.reserve(id: "large-\(index)", profileID: profile, provider: .browser,
                url: url, now: now.addingTimeInterval(Double(index)))
        }
        let first = coordinator.diagnostics(profileID: profile)
        try expect(try JSONEncoder().encode(first).count < 1_048_576, true, "diagnostics fit IPC with escaped long URLs")
        let second = coordinator.diagnostics(profileID: profile, afterID: first.nextDeliveryID!)
        try expect(Set(first.deliveries.map(\.id)).isDisjoint(with: Set(second.deliveries.map(\.id))), true, "diagnostic pages do not repeat")
        try expect(first.deliveries.count + second.deliveries.count, 50, "paging covers the journal")
        for index in 50..<CloudDeliveryCoordinator.capacity {
            try coordinator.reserve(id: "queued-\(index)", profileID: profile, provider: .browser,
                url: URL(string: "https://example.com/queued")!, now: now)
        }
        try rejects("CLOUD_JOURNAL_FULL") {
            try coordinator.reserve(id: "overflow", profileID: profile, provider: .browser,
                url: URL(string: "https://example.com/overflow")!, now: now.addingTimeInterval(CloudDeliveryCoordinator.retention + 100))
        }
        try expect(coordinator.deliveries.count, CloudDeliveryCoordinator.capacity, "unapplied intents are not expired to make space")
    }

    static func cancelsInFlightProbeOnAccountRebind() throws {
        let fixture = try HistoryFixture()
        let agent = service(fixture)
        _ = try agent.selectProfile(profile)
        _ = try exchange(agent, ["operation": "pull", "stream": "safariToBrowser"])
        _ = try agent.cloudCommand(MenuCommand(operation: "cloudProbe", profileID: profile, provider: .browser))
        let page = try exchange(agent, ["operation": "pull", "stream": "safariToBrowser"])
        let event = (page["events"] as! [[String: Any]])[0]
        _ = try agent.cloudCommand(MenuCommand(operation: "cloudRebind", profileID: profile, provider: .browser))
        let reply = try exchange(agent, ["operation": "ack", "stream": "safariToBrowser",
            "throughSequence": event["sequence"]!, "localReceipts": [["eventId": event["eventId"]!,
                "sequence": event["sequence"]!, "visitId": "probe-visit", "visitTime": Date().timeIntervalSince1970 * 1000]]])
        try expect(reply["code"] as? String, "CLOUD_DELIVERY_CANCELLED", "in-flight cancellation is explicit")
        try expect(try agent.status().pendingSafariToBrowser, 0, "rebind cancels queued probe")
        try expect(try diagnostics(agent).summary.monitored, 0, "old binding evidence is not relabeled")
        try agent.pollCloud(now: Date().addingTimeInterval(CloudDeliveryCoordinator.retention + 100),
            safariIsRunning: true) { false }
        let expiredReply = try exchange(agent, ["operation": "ack", "stream": "safariToBrowser",
            "throughSequence": event["sequence"]!, "localReceipts": [["eventId": event["eventId"]!,
                "sequence": event["sequence"]!, "visitId": "probe-visit", "visitTime": Date().timeIntervalSince1970 * 1000]]])
        try expect(expiredReply["status"] as? String, "ACKNOWLEDGED", "expired cancelled prefix still releases worker")
        try expect(try diagnostics(agent).summary.remoteSeen, 0, "terminal prefix does not fabricate evidence")
    }
}
