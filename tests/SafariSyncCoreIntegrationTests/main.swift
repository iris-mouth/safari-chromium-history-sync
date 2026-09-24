import CSQLite
import CryptoKit
import Darwin
import Foundation
import SafariSyncCore

enum IntegrationFailure: Error, CustomStringConvertible {
    case assertion(String)
    var description: String {
        switch self { case let .assertion(message): return message }
    }
}

func expect<T: Equatable>(_ actual: T, _ expected: T, _ message: String) throws {
    guard actual == expected else {
        throw IntegrationFailure.assertion("\(message): expected \(expected), got \(actual)")
    }
}

struct SafariSyncCoreIntegrationTests {
    static func main() throws {
        try validatesHistoryAccessAndSchema()
        try insertsOutboundVisitWithoutAcknowledgingICloud()
        try insertsDistinctOutboundVisits()
        try preservesBrowserPageTitle()
        try sourceEventIsIdempotent()
        try observesProfilesWithoutActivatingThem()
        try boundsObservedProfiles()
        try agentInterfacesPersistProfileAndExchangeState()
        try recoveryOutcomeIsIdempotent()
        try classifiesHistoryCursorFailures()
        try gatesRecoveryCommandsByRoleStateAndIssue()
        try cursorResetPreservesProfileAndQueues()
        try stateResetPreservesHistoryAndDeliveryLedger()
        try classifiesOnlySQLiteContentionAsTransient()
        try migratesVersionOneAgentState()
        try rejectsFutureAgentState()
        try keyLossReportsUnrecoverableWork()
        try ipcSecretRequiresOwnerOnlyRegularFile()
        try partialIPCFrameTimesOut()
        try slowIPCFrameHasTotalDeadline()
        try detectsLegacyManifest()
        try reconcilesOnlySelectedBrowserManifests()
        print("SafariSyncCoreIntegrationTests passed")
    }

    static func validatesHistoryAccessAndSchema() throws {
        let fixture = try HistoryFixture()
        let store = SafariHistoryStore(databaseURL: fixture.url, ledgerURL: fixture.ledgerURL)
        try store.validateAccessAndSchema()
    }

    static func insertsOutboundVisitWithoutAcknowledgingICloud() throws {
        let fixture = try HistoryFixture()
        let store = SafariHistoryStore(databaseURL: fixture.url, ledgerURL: fixture.ledgerURL)
        let receipt = try store.insertBrowserVisit(
            eventID: "b2a-1",
            url: URL(string: "https://example.com/from-edge")!,
            title: nil,
            deliveredAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
        try expect(receipt.generation, 42, "generation")
        try expect(try fixture.scalarInt("SELECT origin FROM history_visits"), 0, "origin")
        try expect(try fixture.scalarInt("SELECT generation FROM history_visits"), 42, "visit generation")
        try expect(
            try fixture.scalarInt("SELECT value FROM metadata WHERE key = 'last_synced_generation'"),
            40,
            "last synced generation"
        )
        try expect(try fixture.scalarInt("SELECT COUNT(*) FROM history_visits"), 1, "visit count")
    }

    static func sourceEventIsIdempotent() throws {
        let fixture = try HistoryFixture()
        let store = SafariHistoryStore(databaseURL: fixture.url, ledgerURL: fixture.ledgerURL)
        let url = URL(string: "https://example.com/once")!
        _ = try store.insertBrowserVisit(eventID: "same", url: url, title: nil, deliveredAt: .now)
        let retry = try store.insertBrowserVisit(eventID: "same", url: url, title: nil, deliveredAt: .now)
        try expect(retry.disposition, .alreadyApplied, "retry disposition")
        try expect(try fixture.scalarInt("SELECT COUNT(*) FROM history_visits"), 1, "idempotent visit count")
    }

    static func insertsDistinctOutboundVisits() throws {
        let fixture = try HistoryFixture()
        let store = SafariHistoryStore(databaseURL: fixture.url, ledgerURL: fixture.ledgerURL)
        _ = try store.insertBrowserVisit(
            eventID: "first",
            url: URL(string: "https://example.com/first")!,
            title: nil,
            deliveredAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
        _ = try store.insertBrowserVisit(
            eventID: "second",
            url: URL(string: "https://example.com/second")!,
            title: nil,
            deliveredAt: Date(timeIntervalSince1970: 1_800_000_001)
        )
        try expect(try fixture.scalarInt("SELECT COUNT(*) FROM history_visits"), 2, "distinct visit count")
        try expect(
            try fixture.scalarInt("SELECT COUNT(*) FROM history_visits WHERE redirect_source IS NULL"),
            2,
            "redirect source remains null"
        )
        try expect(
            try fixture.scalarInt("SELECT COUNT(*) FROM history_visits WHERE redirect_destination IS NULL"),
            2,
            "redirect destination remains null"
        )
    }

    static func preservesBrowserPageTitle() throws {
        let fixture = try HistoryFixture()
        let service = AgentService(
            history: SafariHistoryStore(databaseURL: fixture.url, ledgerURL: fixture.ledgerURL),
            stateURL: fixture.stateURL,
            secret: Data(repeating: 19, count: 32)
        )
        _ = try service.selectProfile("chrome:title-test")
        let publish = try JSONSerialization.data(withJSONObject: [
            "version": 1,
            "operation": "publish",
            "stream": "browserToSafari",
            "profileId": "chrome:title-test",
            "events": [[
                "eventId": "titled-event",
                "sequence": 1,
                "url": "https://example.com/titled",
                "title": "Readable page title",
            ]],
        ])
        _ = try service.browserExchange(publish)
        try expect(
            try fixture.scalarText("SELECT title FROM history_visits"),
            "Readable page title",
            "browser title is stored in Safari history"
        )
    }

    static func agentInterfacesPersistProfileAndExchangeState() throws {
        let fixture = try HistoryFixture()
        let history = SafariHistoryStore(databaseURL: fixture.url, ledgerURL: fixture.ledgerURL)
        let service = AgentService(
            history: history,
            stateURL: fixture.stateURL,
            secret: Data(repeating: 7, count: 32)
        )
        try expect(try service.selectProfile("edge:Default"), "ACTIVE", "initial profile")
        try expect(try service.status().activeProfileID, "edge:Default", "status active profile")

        let publish = try JSONSerialization.data(withJSONObject: [
            "version": 1,
            "operation": "publish",
            "stream": "browserToSafari",
            "profileId": "edge:Default",
            "events": [[
                "eventId": "agent-event",
                "sequence": 1,
                "url": "https://example.com/agent",
            ]],
        ])
        let receipt = try JSONSerialization.jsonObject(with: service.browserExchange(publish)) as! [String: Any]
        try expect(receipt["type"] as? String, "receipt", "agent receipt type")
        try expect(receipt["throughSequence"] as? Int, 1, "agent receipt sequence")
        try expect(try fixture.scalarInt("SELECT COUNT(*) FROM history_visits"), 1, "agent visit count")

        try expect(
            try service.selectProfile("chrome:Profile 1"),
            "ACTIVE",
            "switch state"
        )
        try expect(try service.status().activeProfileID, "chrome:Profile 1", "switched profile")
    }

    static func observesProfilesWithoutActivatingThem() throws {
        let fixture = try HistoryFixture()
        let service = AgentService(
            history: SafariHistoryStore(databaseURL: fixture.url, ledgerURL: fixture.ledgerURL),
            stateURL: fixture.stateURL,
            secret: Data(repeating: 5, count: 32)
        )
        let discovery = try JSONSerialization.data(withJSONObject: [
            "version": 1,
            "operation": "pull",
            "stream": "safariToBrowser",
            "profileId": "chrome:Candidate",
            "browserFamily": "chrome",
            "extensionVersion": "6.0",
            "afterSequence": 0,
            "limit": 128,
        ])
        let response = try JSONSerialization.jsonObject(with: service.browserExchange(discovery)) as! [String: Any]
        try expect(response["code"] as? String, "PROFILE_NOT_ACTIVE", "candidate remains inactive")
        let status = try service.status()
        try expect(status.activeProfileID, nil, "discovery does not select profile")
        try expect(status.connectedProfiles.map(\.profileID), ["chrome:Candidate"], "candidate is visible")
        try expect(status.connectedProfiles.map(\.displayName), ["Chrome profile 1"], "profile has readable label")
    }

    static func recoveryOutcomeIsIdempotent() throws {
        let fixture = try HistoryFixture()
        let secret = Data(repeating: 13, count: 32)
        let service = AgentService(
            history: SafariHistoryStore(databaseURL: fixture.url, ledgerURL: fixture.ledgerURL),
            stateURL: fixture.stateURL,
            secret: secret
        )
        _ = try service.selectProfile("chrome:Default")
        try fixture.insertSafariVisit(url: "https://example.com/recovery")
        let pull = try JSONSerialization.data(withJSONObject: [
            "version": 1,
            "operation": "pull",
            "stream": "safariToBrowser",
            "profileId": "chrome:Default",
            "afterSequence": 0,
            "limit": 128,
        ])
        let page = try JSONSerialization.jsonObject(with: service.browserExchange(pull)) as! [String: Any]
        let event = (page["events"] as! [[String: Any]]).first!
        let outcome = try JSONSerialization.data(withJSONObject: [
            "version": 1,
            "operation": "outcome",
            "profileId": "chrome:Default",
            "eventId": event["eventId"] as! String,
            "outcome": "FINALIZED_UNCONFIRMED",
        ])
        for attempt in 1...2 {
            let response = try JSONSerialization.jsonObject(with: service.browserExchange(outcome)) as! [String: Any]
            try expect(response["status"] as? String, "RECOVERY_RECORDED", "outcome replay \(attempt)")
        }
        try expect(try service.status().recoveryCount, 1, "single recovery record")

        let key = SymmetricKey(data: SHA256.hash(data: secret + Data("agent-state-v1".utf8)))
        let sealed = try AES.GCM.SealedBox(combined: Data(contentsOf: fixture.stateURL))
        var stored = try JSONSerialization.jsonObject(with: AES.GCM.open(sealed, using: key)) as! [String: Any]
        var recovery = stored["recovery"] as! [[String: Any]]
        recovery[0]["nextRetryAt"] = -1_000_000
        stored["recovery"] = recovery
        let updated = try JSONSerialization.data(withJSONObject: stored)
        try AES.GCM.seal(updated, using: key).combined!.write(to: fixture.stateURL)

        let retryPage = try JSONSerialization.jsonObject(with: service.browserExchange(pull)) as! [String: Any]
        try expect((retryPage["events"] as? [[String: Any]])?.count, 1, "scheduled recovery retry")
        let retryResponse = try JSONSerialization.jsonObject(with: service.browserExchange(outcome)) as! [String: Any]
        try expect(retryResponse["status"] as? String, "RECOVERY_RECORDED", "retry failure recorded")
        try expect(try service.status().pendingSafariToBrowser, 0, "failed retry removed from outbox")
        try expect(try service.status().recoveryCount, 1, "retry updates existing recovery")
    }

    static func classifiesOnlySQLiteContentionAsTransient() throws {
        try expect(
            SafariHistoryError.sqlite(code: SQLITE_BUSY, message: "busy").isTransientContention,
            true,
            "SQLite busy classification"
        )
        try expect(
            SafariHistoryError.sqlite(code: SQLITE_CORRUPT, message: "corrupt").isTransientContention,
            false,
            "SQLite corruption classification"
        )
    }

    static func classifiesHistoryCursorFailures() throws {
        let fixture = try HistoryFixture()
        let key = Data(repeating: 21, count: 32)
        let store = SafariHistoryStore(databaseURL: fixture.url, ledgerURL: fixture.ledgerURL)
        let baseline = try store.arrivalBaseline(authenticationKey: key)

        do {
            _ = try store.newVisits(after: SafariArrivalCursor(
                databaseIdentity: "different-database",
                visitID: baseline.visitID,
                rowAuthenticator: baseline.rowAuthenticator
            ), authenticationKey: key)
            throw IntegrationFailure.assertion("database identity change was accepted")
        } catch SafariHistoryError.historyIdentityChanged {
            try expect(
                AgentIssueCode.forHistoryError(.historyIdentityChanged),
                AgentIssueCode.historyIdentityChanged,
                "identity issue code"
            )
        }

        do {
            _ = try store.newVisits(after: SafariArrivalCursor(
                databaseIdentity: baseline.databaseIdentity,
                visitID: baseline.visitID,
                rowAuthenticator: Data(repeating: 0, count: 32)
            ), authenticationKey: key)
            throw IntegrationFailure.assertion("invalid history anchor was accepted")
        } catch SafariHistoryError.historyAnchorInvalid {
            try expect(
                AgentIssueCode.forHistoryError(.historyAnchorInvalid),
                AgentIssueCode.historyAnchorInvalid,
                "anchor issue code"
            )
        }
    }

    static func gatesRecoveryCommandsByRoleStateAndIssue() throws {
        try expect(RecoveryCommandPolicy.allows(
            role: "menu",
            operation: RecoveryCommandPolicy.resetSafariCursor,
            runtimeState: "blocked",
            issueCode: AgentIssueCode.historyIdentityChanged
        ), true, "menu identity cursor reset")
        try expect(RecoveryCommandPolicy.allows(
            role: "menu",
            operation: RecoveryCommandPolicy.resetSafariCursor,
            runtimeState: "blocked",
            issueCode: AgentIssueCode.historyAnchorInvalid
        ), true, "menu anchor cursor reset")
        try expect(RecoveryCommandPolicy.allows(
            role: "menu",
            operation: RecoveryCommandPolicy.resetAgentState,
            runtimeState: "blocked",
            issueCode: AgentIssueCode.stateUnreadable
        ), true, "menu state reset")
        try expect(RecoveryCommandPolicy.allows(
            role: "bridge",
            operation: RecoveryCommandPolicy.resetAgentState,
            runtimeState: "blocked",
            issueCode: AgentIssueCode.stateUnreadable
        ), false, "bridge cannot reset state")
        try expect(RecoveryCommandPolicy.allows(
            role: "menu",
            operation: RecoveryCommandPolicy.resetAgentState,
            runtimeState: "blocked",
            issueCode: AgentIssueCode.keychainUnavailable
        ), false, "keychain issue cannot expose state reset")
        try expect(RecoveryCommandPolicy.allows(
            role: "menu",
            operation: RecoveryCommandPolicy.resetSafariCursor,
            runtimeState: "ready",
            issueCode: AgentIssueCode.historyAnchorInvalid
        ), false, "ready runtime cannot reset cursor")
    }

    static func cursorResetPreservesProfileAndQueues() throws {
        let fixture = try HistoryFixture()
        let service = AgentService(
            history: SafariHistoryStore(databaseURL: fixture.url, ledgerURL: fixture.ledgerURL),
            stateURL: fixture.stateURL,
            secret: Data(repeating: 22, count: 32)
        )
        _ = try service.selectProfile("chrome:Default")
        let delivered = try browserMessage([
            "version": 1,
            "operation": "publish",
            "stream": "browserToSafari",
            "profileId": "chrome:Default",
            "events": [[
                "eventId": "cursor-reset-ledger",
                "sequence": 1,
                "url": "https://example.com/cursor-reset-ledger",
            ]],
        ])
        _ = try service.browserExchange(delivered)
        try fixture.insertSafariVisit(url: "https://example.com/recovery-before-reset")
        let pull = try browserMessage([
            "version": 1,
            "operation": "pull",
            "stream": "safariToBrowser",
            "profileId": "chrome:Default",
            "afterSequence": 0,
            "limit": 128,
        ])
        let firstPage = try JSONSerialization.jsonObject(with: service.browserExchange(pull)) as! [String: Any]
        let recoveryEvent = (firstPage["events"] as! [[String: Any]]).first!
        let outcome = try browserMessage([
            "version": 1,
            "operation": "outcome",
            "profileId": "chrome:Default",
            "eventId": recoveryEvent["eventId"] as! String,
            "outcome": "FINALIZED_UNCONFIRMED",
        ])
        _ = try service.browserExchange(outcome)
        try fixture.insertSafariVisit(url: "https://example.com/outbox-before-reset")
        _ = try service.browserExchange(pull)
        let before = try service.status()

        try service.resetSafariCursor()
        let after = try service.status()
        try expect(after.activeProfileID, before.activeProfileID, "cursor reset active profile")
        try expect(after.pendingSafariToBrowser, before.pendingSafariToBrowser, "cursor reset outbox")
        try expect(after.recoveryCount, before.recoveryCount, "cursor reset recovery")
        _ = try service.browserExchange(delivered)
        try expect(try fixture.scalarInt("SELECT COUNT(*) FROM history_visits"), 3, "cursor reset delivery ledger")
    }

    static func stateResetPreservesHistoryAndDeliveryLedger() throws {
        let fixture = try HistoryFixture()
        let secret = Data(repeating: 23, count: 32)
        let service = AgentService(
            history: SafariHistoryStore(databaseURL: fixture.url, ledgerURL: fixture.ledgerURL),
            stateURL: fixture.stateURL,
            secret: secret
        )
        _ = try service.selectProfile("edge:Default")
        let publish = try browserMessage([
            "version": 1,
            "operation": "publish",
            "stream": "browserToSafari",
            "profileId": "edge:Default",
            "events": [[
                "eventId": "ledger-survives-reset",
                "sequence": 1,
                "url": "https://example.com/ledger-survives-reset",
            ]],
        ])
        _ = try service.browserExchange(publish)
        let chromiumHistory = fixture.stateURL.appendingPathExtension("chromium-history")
        let unrelatedRuntimeFile = fixture.stateURL.appendingPathExtension("preserve")
        defer {
            try? FileManager.default.removeItem(at: chromiumHistory)
            try? FileManager.default.removeItem(at: unrelatedRuntimeFile)
        }
        try Data("browser history sentinel".utf8).write(to: chromiumHistory)
        try Data("runtime sentinel".utf8).write(to: unrelatedRuntimeFile)
        try Data("unreadable-state".utf8).write(to: fixture.stateURL)
        try expect(try service.status().issueCode, AgentIssueCode.stateUnreadable, "corrupt state status")

        try service.resetAgentState()
        try expect(try service.status().activeProfileID, nil, "state reset clears unreadable profile")
        _ = try service.selectProfile("edge:Default")
        let replay = try JSONSerialization.jsonObject(with: service.browserExchange(publish)) as! [String: Any]
        try expect(replay["status"] as? String, "ACCEPTED", "ledger replay receipt")
        try expect(try fixture.scalarInt("SELECT COUNT(*) FROM history_visits"), 1, "state reset preserves history and ledger idempotency")
        try expect(try Data(contentsOf: chromiumHistory), Data("browser history sentinel".utf8), "state reset preserves Chromium history")
        try expect(try Data(contentsOf: unrelatedRuntimeFile), Data("runtime sentinel".utf8), "state reset deletes only state files")
    }

    static func browserMessage(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object)
    }

    static func boundsObservedProfiles() throws {
        let fixture = try HistoryFixture()
        let service = AgentService(
            history: SafariHistoryStore(databaseURL: fixture.url, ledgerURL: fixture.ledgerURL),
            stateURL: fixture.stateURL,
            secret: Data(repeating: 6, count: 32)
        )
        for index in 0..<33 {
            let message = try JSONSerialization.data(withJSONObject: [
                "version": 1,
                "operation": "pull",
                "stream": "safariToBrowser",
                "profileId": "chrome:candidate-\(index)",
                "afterSequence": 0,
                "limit": 128,
            ])
            _ = try service.browserExchange(message)
        }
        try expect(try service.status().connectedProfiles.count, 32, "candidate profile cap")

        let oversized = try JSONSerialization.data(withJSONObject: [
            "version": 1,
            "operation": "pull",
            "stream": "safariToBrowser",
            "profileId": String(repeating: "x", count: 129),
            "afterSequence": 0,
            "limit": 128,
        ])
        let response = try JSONSerialization.jsonObject(with: service.browserExchange(oversized)) as! [String: Any]
        try expect(response["code"] as? String, "INVALID_MESSAGE", "oversized profile ID")
    }

    static func keyLossReportsUnrecoverableWork() throws {
        let fixture = try HistoryFixture()
        let history = SafariHistoryStore(databaseURL: fixture.url, ledgerURL: fixture.ledgerURL)
        let service = AgentService(
            history: history,
            stateURL: fixture.stateURL,
            secret: Data(repeating: 3, count: 32)
        )
        _ = try service.selectProfile("edge:Default")
        try fixture.insertSafariVisit(url: "https://example.com/unresolved")
        let pull = try JSONSerialization.data(withJSONObject: [
            "version": 1,
            "operation": "pull",
            "stream": "safariToBrowser",
            "profileId": "edge:Default",
            "afterSequence": 0,
            "limit": 128,
        ])
        _ = try service.browserExchange(pull)

        let serviceWithLostKey = AgentService(
            history: history,
            stateURL: fixture.stateURL,
            secret: Data(repeating: 9, count: 32)
        )
        let status = try serviceWithLostKey.status()
        try expect(status.issueCode, "stateUnreadable", "key loss status")
        try expect(status.unrecoverableCount, 1, "key loss unresolved count")
    }

    static func migratesVersionOneAgentState() throws {
        let fixture = try HistoryFixture()
        let secret = Data(repeating: 11, count: 32)
        let legacy: [String: Any] = [
            "enabled": true,
            "activeProfileID": "edge:Existing",
            "stagingProfileID": "chrome:Discarded",
            "switchState": "AWAITING_FREEZE_ACK",
            "nextSafariSequence": 1,
            "outbox": [],
            "deliveredSafariVisitIDs": [],
            "recovery": [],
            "unrecoverableCount": 0,
        ]
        let plaintext = try JSONSerialization.data(withJSONObject: legacy)
        let key = SymmetricKey(data: SHA256.hash(data: secret + Data("agent-state-v1".utf8)))
        let sealed = try AES.GCM.seal(plaintext, using: key).combined!
        try sealed.write(to: fixture.stateURL)

        let service = AgentService(
            history: SafariHistoryStore(databaseURL: fixture.url, ledgerURL: fixture.ledgerURL),
            stateURL: fixture.stateURL,
            secret: secret
        )
        try expect(try service.status().activeProfileID, "edge:Existing", "v1 active profile")
        _ = try service.selectProfile("edge:Existing")
        let migratedBox = try AES.GCM.SealedBox(combined: Data(contentsOf: fixture.stateURL))
        let migrated = try JSONSerialization.jsonObject(with: AES.GCM.open(migratedBox, using: key)) as! [String: Any]
        try expect(migrated["schemaVersion"] as? Int, 2, "migrated schema version")
        try expect(migrated["stagingProfileID"] as? String, nil, "staging state removed")
    }

    static func rejectsFutureAgentState() throws {
        let fixture = try HistoryFixture()
        let secret = Data(repeating: 12, count: 32)
        let future = try JSONSerialization.data(withJSONObject: [
            "schemaVersion": 3,
            "enabled": true,
            "activeProfileID": "chrome:Future",
        ])
        let key = SymmetricKey(data: SHA256.hash(data: secret + Data("agent-state-v1".utf8)))
        let sealed = try AES.GCM.seal(future, using: key).combined!
        try sealed.write(to: fixture.stateURL)
        let original = try Data(contentsOf: fixture.stateURL)
        let service = AgentService(
            history: SafariHistoryStore(databaseURL: fixture.url, ledgerURL: fixture.ledgerURL),
            stateURL: fixture.stateURL,
            secret: secret
        )
        try expect(try service.status().issueCode, "stateUnreadable", "future schema is rejected")
        try expect(try Data(contentsOf: fixture.stateURL), original, "future state is not rewritten")
    }

    static func ipcSecretRequiresOwnerOnlyRegularFile() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("safari-sync-ipc-\(UUID().uuidString)")
        let url = directory.appendingPathComponent("ipc.secret")
        defer { try? FileManager.default.removeItem(at: directory) }

        let created = try IPCSecretStore.load(from: url, createIfMissing: true)
        try expect(created.count, 32, "IPC secret length")
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        try expect(attributes[.posixPermissions] as? NSNumber, NSNumber(value: 0o600), "IPC secret mode")
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        do {
            _ = try IPCSecretStore.load(from: url, createIfMissing: false)
            throw IntegrationFailure.assertion("unsafe IPC secret permissions were accepted")
        } catch let failure as IntegrationFailure {
            throw failure
        } catch {
            // Expected: the Bridge and Menu must fail closed instead of reading a broad file.
        }
    }

    static func partialIPCFrameTimesOut() throws {
        var descriptors = [Int32](repeating: -1, count: 2)
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0 else {
            throw IntegrationFailure.assertion("socketpair failed")
        }
        defer {
            Darwin.close(descriptors[0])
            Darwin.close(descriptors[1])
        }
        configureSocketTimeouts(descriptor: descriptors[0], seconds: 1)
        var byte: UInt8 = 1
        _ = Darwin.write(descriptors[1], &byte, 1)
        let started = Date()
        do {
            _ = try readFrame(descriptor: descriptors[0], timeoutSeconds: 1)
            throw IntegrationFailure.assertion("partial frame was accepted")
        } catch let failure as IntegrationFailure {
            throw failure
        } catch {
            try expect(Date().timeIntervalSince(started) < 2.0, true, "partial frame timeout")
        }
    }

    static func slowIPCFrameHasTotalDeadline() throws {
        var descriptors = [Int32](repeating: -1, count: 2)
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0 else {
            throw IntegrationFailure.assertion("socketpair failed")
        }
        defer {
            Darwin.close(descriptors[0])
            Darwin.close(descriptors[1])
        }
        let bytes: [UInt8] = [8, 0, 0, 0] + Array(repeating: 1, count: 8)
        let writerDescriptor = descriptors[1]
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            for byte in bytes {
                usleep(200_000)
                var value = byte
                _ = Darwin.send(writerDescriptor, &value, 1, Int32(MSG_NOSIGNAL))
            }
            group.leave()
        }
        let started = Date()
        do {
            _ = try readFrame(descriptor: descriptors[0], timeoutSeconds: 1)
            throw IntegrationFailure.assertion("slow frame bypassed total deadline")
        } catch let failure as IntegrationFailure {
            throw failure
        } catch {
            try expect(Date().timeIntervalSince(started) < 1.5, true, "total frame deadline")
        }
        group.wait()
    }

    static func detectsLegacyManifest() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("safari-sync-legacy-\(UUID().uuidString)")
        let directory = home.appendingPathComponent(
            "Library/Application Support/Google/Chrome/NativeMessagingHosts"
        )
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let manifest = directory.appendingPathComponent("\(LegacyWriterDetector.hostName).json")
        try Data("{}".utf8).write(to: manifest)
        try expect(
            LegacyWriterDetector.detect(home: home).contains(manifest.path),
            true,
            "legacy manifest detection"
        )
    }

    static func reconcilesOnlySelectedBrowserManifests() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("safari-sync-manifests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let chrome = NativeMessagingTarget(
            id: "chrome",
            directory: root.appendingPathComponent("chrome")
        )
        let edge = NativeMessagingTarget(
            id: "edge",
            directory: root.appendingPathComponent("edge")
        )
        let hostName = ProductIdentity.nativeMessagingHost
        let bridgeURL = URL(fileURLWithPath: "/Applications/Safari Chromium History Sync.app/Contents/MacOS/SafariSyncBridge")
        let bridgeSuffix = "/Safari Chromium History Sync.app/Contents/MacOS/SafariSyncBridge"

        try NativeMessagingManifestStore.reconcile(
            targets: [chrome, edge],
            selectedTargetIDs: [chrome.id],
            hostName: hostName,
            bridgeURL: bridgeURL,
            extensionID: "abcdefghijklmnopabcdefghijklmnop",
            bridgeSuffix: bridgeSuffix
        )
        let chromeManifest = chrome.directory.appendingPathComponent("\(hostName).json")
        let edgeManifest = edge.directory.appendingPathComponent("\(hostName).json")
        try expect(FileManager.default.fileExists(atPath: chromeManifest.path), true, "selected browser manifest")
        try expect(FileManager.default.fileExists(atPath: edge.directory.path), false, "unselected browser directory")
        let attributes = try FileManager.default.attributesOfItem(atPath: chromeManifest.path)
        try expect(attributes[.posixPermissions] as? NSNumber, NSNumber(value: 0o600), "manifest mode")

        try NativeMessagingManifestStore.reconcile(
            targets: [chrome, edge],
            selectedTargetIDs: [edge.id],
            hostName: hostName,
            bridgeURL: bridgeURL,
            extensionID: "abcdefghijklmnopabcdefghijklmnop",
            bridgeSuffix: bridgeSuffix
        )
        try expect(FileManager.default.fileExists(atPath: chromeManifest.path), false, "Chrome-only manifest removed")
        try expect(FileManager.default.fileExists(atPath: edgeManifest.path), true, "Edge-only manifest created")

        try NativeMessagingManifestStore.reconcile(
            targets: [chrome, edge],
            selectedTargetIDs: [chrome.id, edge.id],
            hostName: hostName,
            bridgeURL: bridgeURL,
            extensionID: "abcdefghijklmnopabcdefghijklmnop",
            bridgeSuffix: bridgeSuffix
        )
        try expect(FileManager.default.fileExists(atPath: chromeManifest.path), true, "both browsers Chrome manifest")
        try expect(FileManager.default.fileExists(atPath: edgeManifest.path), true, "both browsers Edge manifest")

        try Data("{\"name\":\"someone.else\",\"path\":\"/tmp/foreign\"}".utf8).write(to: edgeManifest)
        try NativeMessagingManifestStore.reconcile(
            targets: [chrome, edge],
            selectedTargetIDs: [],
            hostName: hostName,
            bridgeURL: bridgeURL,
            extensionID: "abcdefghijklmnopabcdefghijklmnop",
            bridgeSuffix: bridgeSuffix
        )
        try expect(FileManager.default.fileExists(atPath: chromeManifest.path), false, "owned manifest removal")
        try expect(FileManager.default.fileExists(atPath: edgeManifest.path), true, "foreign manifest preservation")
    }
}

try SafariSyncCoreIntegrationTests.main()

private final class HistoryFixture {
    let url: URL
    let ledgerURL: URL
    let stateURL: URL
    private var db: OpaquePointer?

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("safari-sync-\(UUID().uuidString).db")
        ledgerURL = url.appendingPathExtension("ledger")
        stateURL = url.appendingPathExtension("state")
        guard sqlite3_open(url.path, &db) == SQLITE_OK else { throw FixtureError.open }
        try exec("""
          CREATE TABLE history_items (
            id INTEGER PRIMARY KEY AUTOINCREMENT, url TEXT UNIQUE NOT NULL,
            domain_expansion TEXT, visit_count INTEGER NOT NULL DEFAULT 0,
            daily_visit_counts BLOB, weekly_visit_counts BLOB,
            autocomplete_triggers BLOB,
            should_recompute_derived_visit_counts INTEGER NOT NULL DEFAULT 0,
            visit_count_score REAL NOT NULL DEFAULT 0, status_code INTEGER NOT NULL DEFAULT 0
          );
          CREATE TABLE history_visits (
            id INTEGER PRIMARY KEY AUTOINCREMENT, history_item INTEGER NOT NULL,
            visit_time REAL NOT NULL, title TEXT,
            load_successful INTEGER NOT NULL DEFAULT 1,
            http_non_get INTEGER NOT NULL DEFAULT 0,
            synthesized INTEGER NOT NULL DEFAULT 0,
            redirect_source INTEGER NULL UNIQUE,
            redirect_destination INTEGER NULL UNIQUE,
            origin INTEGER NOT NULL DEFAULT 0, generation INTEGER NOT NULL,
            attributes INTEGER NOT NULL DEFAULT 0, score REAL NOT NULL DEFAULT 0
          );
          CREATE TABLE metadata (key TEXT PRIMARY KEY, value INTEGER NOT NULL);
          INSERT INTO metadata(key, value)
            VALUES ('current_generation', 41), ('last_synced_generation', 40);
        """)
    }

    deinit {
        sqlite3_close(db)
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(at: ledgerURL)
        try? FileManager.default.removeItem(at: stateURL)
        try? FileManager.default.removeItem(at: stateURL.appendingPathExtension("unresolved-count"))
    }

    func scalarInt(_ sql: String) throws -> Int64 {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw FixtureError.query
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw FixtureError.query }
        return sqlite3_column_int64(statement, 0)
    }

    func scalarText(_ sql: String) throws -> String? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw FixtureError.query
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw FixtureError.query }
        guard let bytes = sqlite3_column_text(statement, 0) else { return nil }
        return String(cString: bytes)
    }

    func insertSafariVisit(url: String) throws {
        let escaped = url.replacingOccurrences(of: "'", with: "''")
        try exec("""
          INSERT INTO history_items(url, visit_count, should_recompute_derived_visit_counts)
            VALUES ('\(escaped)', 1, 1);
          INSERT INTO history_visits(history_item, visit_time, title, origin, generation)
            VALUES (last_insert_rowid(), 900000000, '\(escaped)', 0, 42);
          UPDATE metadata SET value = 42 WHERE key = 'current_generation';
        """)
    }

    private func exec(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw FixtureError.query }
    }

    private enum FixtureError: Error { case open, query }
}
