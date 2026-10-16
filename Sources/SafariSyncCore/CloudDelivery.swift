import Foundation

public struct SafariReceiverExport: Codable, Sendable {
    private struct Metadata: Codable, Sendable {
        let browser_name: String
        let data_type: String
        let export_time_usec: Double
        let schema_version: Int
    }
    private struct Item: Codable, Sendable { let url: String; let time_usec: Double }
    private let metadata: Metadata
    private let history: [Item]

    private func validate(now: Date) throws {
        guard metadata.browser_name == "Safari", metadata.data_type == "history",
              metadata.schema_version == 1, history.count <= 200_000,
              metadata.export_time_usec.isFinite, metadata.export_time_usec > 0,
              metadata.export_time_usec / 1_000_000 <= now.timeIntervalSince1970 + 60,
              history.allSatisfy({ $0.time_usec.isFinite && $0.time_usec > 0
                  && $0.time_usec <= metadata.export_time_usec }) else {
            throw TypedError(code: "INVALID_SAFARI_EXPORT")
        }
    }

    /// Filter a full receiver export locally, before passing bounded owned-URL snapshots over IPC.
    public static func comparisonBatches(data: Data, ownedURLs: Set<String>, now: Date = .now) throws -> [String] {
        guard data.count <= 32 * 1024 * 1024,
              let export = try? JSONDecoder().decode(Self.self, from: data) else {
            throw TypedError(code: "INVALID_SAFARI_EXPORT")
        }
        try export.validate(now: now)
        var latest: [String: Double] = [:]
        for item in export.history where ownedURLs.contains(item.url) {
            guard item.url.utf8.count <= 8192 else { throw TypedError(code: "INVALID_SAFARI_EXPORT") }
            latest[item.url] = max(latest[item.url] ?? 0, item.time_usec)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        func encoded(_ items: [Item]) throws -> String {
            String(decoding: try encoder.encode(Self(metadata: export.metadata, history: items)), as: UTF8.self)
        }
        var result: [String] = []
        var batch: [Item] = []
        for url in latest.keys.sorted() {
            let item = Item(url: url, time_usec: latest[url]!)
            let candidate = batch + [item]
            if try encoded(candidate).utf8.count > 256 * 1024, !batch.isEmpty {
                result.append(try encoded(batch))
                batch = [item]
            } else { batch = candidate }
        }
        result.append(try encoded(batch))
        return result
    }

    fileprivate static func latestVisits(data: Data, now: Date) throws -> (exportedAt: Double, visits: [String: Double]) {
        guard data.count <= 256 * 1024, let export = try? JSONDecoder().decode(Self.self, from: data),
              export.history.count <= 4096, export.history.allSatisfy({ $0.url.utf8.count <= 8192 }) else {
            throw TypedError(code: "INVALID_SAFARI_EXPORT")
        }
        try export.validate(now: now)
        let latest = Dictionary(export.history.map { ($0.url, $0.time_usec / 1_000_000) }, uniquingKeysWith: max)
        return (export.metadata.export_time_usec / 1_000_000, latest)
    }
}

public enum CloudProvider: String, Codable, Sendable {
    case safari, browser
}

public struct BrowserLocalReceipt: Codable, Equatable, Sendable {
    public let eventID: String
    public let sequence: Int64
    public let visitID: String
    public let visitTime: Double

    enum CodingKeys: String, CodingKey {
        case eventID = "eventId", visitID = "visitId"
        case sequence, visitTime
    }
}

public struct CloudDelivery: Codable, Equatable, Sendable {
    public let id: String
    public let profileID: String
    public let provider: CloudProvider
    public let bindingEpoch: String
    public let url: URL
    public let queuedAt: Date
    public let kind: String
    public let parentID: String?
    public var title: String?
    public var localAppliedAt: Date?
    public var destinationVisitID: String?
    public var destinationTime: Date?
    public var databaseIdentity: String?
    public var generation: Int64?
    public var nativeState = "notObservable"
    public var remoteState = "unverified"
    public var remoteDevice: String?
    public var remoteObservedAt: Date?
    public var nextCheckAt: Date?
    public var checks = 0
    public var lastCheckpoint: Int64?
    public var lastProgressAt: Date?
    public var lastTrigger: String?
    public var suppressed = false
}

public struct CloudSummary: Codable, Equatable, Sendable {
    public let monitored: Int
    public let pendingLocal: Int
    public let safariPending: Int
    public let possibleStalls: Int
    public let checkpointCovered: Int
    public let browserNotObservable: Int
    public let remoteSeen: Int
    public let suppressed: Int
    public let expiredUnverified: Int
    public let capacityReached: Bool
}

public struct CloudRepairPlan: Codable, Equatable, Sendable {
    public let id: String
    public let deliveryID: String
    public let attemptID: String
    public let profileID: String
    public let provider: CloudProvider
    public let bindingEpoch: String
    public let url: URL
    public let expiresAt: Date
    public var executed = false
}

public struct CloudDiagnostics: Codable, Sendable {
    public let summary: CloudSummary
    public let deliveries: [CloudDelivery]
    public let totalDeliveries: Int
    public let plan: CloudRepairPlan?
    public let nextDeliveryID: String?
    public let safariAssist: SafariSyncAssist?
}

public struct SafariCloudSnapshot: Sendable {
    public let databaseIdentity: String
    public let checkpoint: Int64
    public let matchingVisitIDs: Set<String>

    public init(databaseIdentity: String, checkpoint: Int64, matchingVisitIDs: Set<String>) {
        self.databaseIdentity = databaseIdentity
        self.checkpoint = checkpoint
        self.matchingVisitIDs = matchingVisitIDs
    }
}

/// Persisted with the Agent state, so a local ACK cannot discard cloud evidence.
public struct CloudDeliveryCoordinator: Codable, Equatable, Sendable {
    public static let capacity = 4096
    public static let retention: TimeInterval = 7 * 24 * 60 * 60
    public private(set) var deliveries: [CloudDelivery] = []
    public private(set) var plans: [CloudRepairPlan] = []
    private var bindings: [String: String] = [:]
    private var expiredUnverified = 0
    private var safariLaunches: [Date] = [] // Build 610/611 migration only; never replenished.
    private var safariAssist: SafariSyncAssist?

    public init() {}

    private func scope(_ provider: CloudProvider, _ profileID: String) -> String {
        provider == .safari ? "safari" : "browser:\(profileID)"
    }

    public mutating func binding(provider: CloudProvider, profileID: String) -> String {
        let key = scope(provider, profileID)
        if let existing = bindings[key] { return existing }
        let created = UUID().uuidString
        bindings[key] = created
        return created
    }

    public func isCurrent(_ delivery: CloudDelivery) -> Bool {
        bindings[scope(delivery.provider, delivery.profileID)] == delivery.bindingEpoch
    }

    public mutating func rebind(provider: CloudProvider, profileID: String) {
        let key = scope(provider, profileID)
        let previous = bindings[key]
        for index in deliveries.indices where scope(deliveries[index].provider, deliveries[index].profileID) == key
            && deliveries[index].bindingEpoch == previous && deliveries[index].kind != "relay"
            && deliveries[index].localAppliedAt == nil {
            deliveries[index].suppressed = true
            deliveries[index].nativeState = "accountBindingChanged"
        }
        bindings[scope(provider, profileID)] = UUID().uuidString
        resetSafariRetryIfResolved()
    }

    public mutating func reserve(id: String, profileID: String, provider: CloudProvider,
                                 url: URL, now: Date, kind: String = "relay", parentID: String? = nil,
                                 title: String? = nil) throws {
        prune(now: now)
        resetSafariRetryIfResolved()
        if let existing = deliveries.first(where: { $0.id == id }) {
            guard existing.profileID == profileID, existing.provider == provider, existing.url == url else {
                throw TypedError(code: "CLOUD_RECEIPT_CONFLICT")
            }
            return
        }
        guard deliveries.count < Self.capacity else {
            throw TypedError(code: "CLOUD_JOURNAL_FULL", retryable: true)
        }
        let epoch = binding(provider: provider, profileID: profileID)
        deliveries.append(CloudDelivery(id: id, profileID: profileID, provider: provider,
            bindingEpoch: epoch, url: url, queuedAt: now, kind: kind, parentID: parentID))
        deliveries[deliveries.count - 1].title = title
    }

    public mutating func recordLocalDelivery(id: String, visitID: String, time: Date,
                                             now: Date, generation: Int64? = nil,
                                             databaseIdentity: String? = nil) throws {
        guard let index = deliveries.firstIndex(where: { $0.id == id }) else {
            throw TypedError(code: "CLOUD_DELIVERY_NOT_FOUND")
        }
        if let existingID = deliveries[index].destinationVisitID {
            guard existingID == visitID, deliveries[index].destinationTime == time else {
                throw TypedError(code: "CLOUD_RECEIPT_CONFLICT")
            }
            return
        }
        deliveries[index].destinationVisitID = visitID
        deliveries[index].destinationTime = time
        deliveries[index].localAppliedAt = now
        deliveries[index].generation = generation
        deliveries[index].databaseIdentity = databaseIdentity
        if deliveries[index].provider == .safari {
            deliveries[index].nativeState = "pending"
            deliveries[index].nextCheckAt = now.addingTimeInterval(15)
            deliveries[index].lastProgressAt = now
        }
    }

    public func safariBatch(profileID: String, now: Date, isRunning: Bool = true) -> [CloudDelivery] {
        let canTrigger = !isRunning || safariAssist?.enabled == true
        let actionDue = safariAssist?.nextAttemptAt
            ?? safariAssist?.lastAttempt?.addingTimeInterval(SafariSyncAssist.minimumInterval)
            ?? safariLaunches.max()?.addingTimeInterval(SafariSyncAssist.minimumInterval)
        let candidates = deliveries.filter {
            $0.profileID == profileID && $0.provider == .safari && isCurrent($0)
                && $0.localAppliedAt != nil && !$0.suppressed
                && (($0.nextCheckAt ?? .distantPast) <= now
                    || (canTrigger && $0.remoteState != "seen" && $0.nativeState != "checkpointCovered"
                        && now.timeIntervalSince($0.localAppliedAt!) >= 15
                        && actionDue.map { $0 <= now } == true))
        }
        return Array(candidates.sorted {
            if ($0.nativeState == "checkpointCovered") != ($1.nativeState == "checkpointCovered") {
                return $0.nativeState != "checkpointCovered"
            }
            return ($0.nextCheckAt ?? .distantPast) < ($1.nextCheckAt ?? .distantPast)
        }.prefix(128))
    }

    /// Returns one launch obligation for the coalesced batch, not one per visit.
    public mutating func reconcileSafari(batch: [CloudDelivery], snapshot: SafariCloudSnapshot,
                                          now: Date, isRunning: Bool) -> Bool {
        guard !batch.isEmpty else { return false }
        if safariAssist == nil { safariAssist = SafariSyncAssist() }
        if let legacyLaunch = safariLaunches.max() { safariAssist?.inheritLegacyLaunch(legacyLaunch) }
        safariLaunches.removeAll()
        var pending = false
        let ids = Set(batch.map(\.id))
        let delays: [TimeInterval] = [30, 60, 90, 300, 900, 1800, 7200, 21600]
        for index in deliveries.indices where ids.contains(deliveries[index].id) {
            var entry = deliveries[index]
            guard entry.databaseIdentity == snapshot.databaseIdentity else {
                entry.nativeState = "databaseChanged"
                entry.suppressed = true
                deliveries[index] = entry
                continue
            }
            guard let visitID = entry.destinationVisitID, snapshot.matchingVisitIDs.contains(visitID) else {
                entry.nativeState = "localMissingOrChanged"
                entry.suppressed = true
                deliveries[index] = entry
                continue
            }
            if snapshot.checkpoint > (entry.lastCheckpoint ?? -1) {
                entry.lastProgressAt = now
                entry.lastCheckpoint = snapshot.checkpoint
            }
            if let generation = entry.generation, snapshot.checkpoint >= generation {
                entry.nativeState = "checkpointCovered"
                entry.nextCheckAt = now.addingTimeInterval(300)
            } else if entry.remoteState == "seen" {
                // Receiver evidence resolves the obligation without inventing a native ACK.
                entry.nextCheckAt = now.addingTimeInterval(300)
            } else {
                pending = true
                entry.nativeState = now.timeIntervalSince(entry.lastProgressAt ?? entry.queuedAt) >= 900
                    ? "possibleStall" : (isRunning ? "waitingForSafariActivity" : "pending")
                let delay = delays[min(entry.checks, delays.count - 1)]
                // Observation cadence must not suppress a separately scheduled action for hours.
                entry.nextCheckAt = now.addingTimeInterval(!isRunning || safariAssist?.enabled == true
                    ? min(delay, SafariSyncAssist.observationInterval) : delay)
                entry.checks += 1
            }
            deliveries[index] = entry
        }
        let profiles = Set(batch.map(\.profileID))
        let stillPending = deliveries.contains {
            profiles.contains($0.profileID) && $0.provider == .safari && isCurrent($0)
                && $0.localAppliedAt != nil && !$0.suppressed
                && $0.remoteState != "seen" && $0.nativeState != "checkpointCovered"
        }
        safariAssist?.observe(pending: stillPending, checkpoint: snapshot.checkpoint,
            databaseIdentity: snapshot.databaseIdentity)
        guard pending, !isRunning else { return false }
        // The caller persists this shared reservation before launching, including failed launches.
        return safariAssist?.reserveLaunch(now: now) == true
    }

    public mutating func setSafariAssist(enabled: Bool, now: Date = .now) {
        if safariAssist == nil { safariAssist = SafariSyncAssist() }
        safariAssist?.setEnabled(enabled)
        if enabled {
            for index in deliveries.indices where deliveries[index].provider == .safari
                && isCurrent(deliveries[index]) && !deliveries[index].suppressed
                && deliveries[index].nativeState != "checkpointCovered" {
                deliveries[index].nextCheckAt = now
            }
        }
    }

    public func isSafariAssistURL(_ url: URL) -> Bool { safariAssist?.owns(url) == true }

    /// Must be called with a freshly checked owned batch; persist before acting.
    public mutating func reserveSafariAssist(batch: [CloudDelivery], now: Date, isRunning: Bool) -> URL? {
        guard isRunning, safariAssist?.enabled == true else { return nil }
        let ids = Set(batch.map(\.id))
        var eligible = false
        for index in deliveries.indices {
            let entry = deliveries[index]
            guard ids.contains(entry.id), isCurrent(entry), !entry.suppressed,
                  entry.provider == .safari, let applied = entry.localAppliedAt,
                  entry.remoteState != "seen", entry.nativeState != "checkpointCovered" else { continue }
            if now.timeIntervalSince(applied) >= SafariSyncAssist.nativeActivityGrace { eligible = true }
        }
        guard eligible else { return nil }
        return safariAssist?.reserve(now: now)
    }

    public mutating func recordSafariAssist(result: String) {
        safariAssist?.record(result: result)
    }

    public mutating func recordTrigger(batch: [CloudDelivery], result: String) {
        let ids = Set(batch.map(\.id))
        for index in deliveries.indices where ids.contains(deliveries[index].id)
            && !deliveries[index].suppressed && deliveries[index].nativeState != "checkpointCovered" {
            deliveries[index].lastTrigger = result
        }
    }

    @discardableResult
    public mutating func suppress(profileID: String, urls: Set<String>?, id: String? = nil,
                                   before: Date = .distantFuture) -> Set<String> {
        var affected = Set<String>()
        for index in deliveries.indices where deliveries[index].profileID == profileID
            && deliveries[index].provider == .browser
            && isCurrent(deliveries[index]) && deliveries[index].queuedAt <= before.addingTimeInterval(0.001)
            && (id.map { deliveries[index].id == $0 } ?? true)
            && (urls.map { $0.contains(deliveries[index].url.absoluteString) } ?? true) {
            deliveries[index].suppressed = true
            deliveries[index].nativeState = "localRemoved"
            affected.insert(deliveries[index].id)
        }
        return affected
    }

    public mutating func observeRemote(id: String, profileID: String, result: String,
                                       device: String, now: Date) throws {
        guard ["seen", "notObserved"].contains(result), !device.isEmpty, device.utf8.count <= 128,
              let index = deliveries.firstIndex(where: { $0.id == id && $0.profileID == profileID }),
              isCurrent(deliveries[index]), deliveries[index].localAppliedAt != nil else {
            throw TypedError(code: "INVALID_CLOUD_OBSERVATION")
        }
        deliveries[index].remoteState = result
        deliveries[index].remoteDevice = device
        deliveries[index].remoteObservedAt = now
        resetSafariRetryIfResolved()
    }

    public mutating func prepareRepair(id: String, profileID: String, now: Date) throws -> CloudRepairPlan {
        prune(now: now)
        guard let entry = deliveries.first(where: { $0.id == id && $0.profileID == profileID }),
              isCurrent(entry), entry.localAppliedAt != nil, !entry.suppressed else {
            throw TypedError(code: "CLOUD_REPLAY_NOT_ALLOWED")
        }
        guard plans.count < 128 else { throw TypedError(code: "CLOUD_REPAIR_PLAN_LIMIT") }
        let plan = CloudRepairPlan(id: UUID().uuidString, deliveryID: id,
            attemptID: "repair:\(UUID().uuidString)", profileID: profileID, provider: entry.provider,
            bindingEpoch: entry.bindingEpoch, url: entry.url, expiresAt: now.addingTimeInterval(300))
        plans.append(plan)
        return plan
    }

    public mutating func executeRepair(id: String, profileID: String, now: Date) throws -> CloudRepairPlan {
        prune(now: now)
        guard let index = plans.firstIndex(where: { $0.id == id && $0.profileID == profileID }),
              let original = deliveries.first(where: { $0.id == plans[index].deliveryID }),
              isCurrent(original), !original.suppressed,
              original.bindingEpoch == plans[index].bindingEpoch else {
            throw TypedError(code: "STALE_CLOUD_REPAIR_PLAN")
        }
        if plans[index].executed { return plans[index] }
        guard now <= plans[index].expiresAt else { throw TypedError(code: "STALE_CLOUD_REPAIR_PLAN") }
        let plan = plans[index]
        try reserve(id: plan.attemptID, profileID: profileID, provider: plan.provider,
            url: plan.url, now: now, kind: "repair", parentID: plan.deliveryID)
        guard let updatedIndex = plans.firstIndex(where: { $0.id == id }) else {
            throw TypedError(code: "STALE_CLOUD_REPAIR_PLAN")
        }
        plans[updatedIndex].executed = true
        return plans[updatedIndex]
    }

    public mutating func compareSafariExport(_ data: Data, profileID: String, now: Date) throws {
        let export = try SafariReceiverExport.latestVisits(data: data, now: now)
        var matches: [String: [Int]] = [:]
        for index in deliveries.indices where deliveries[index].profileID == profileID
            && deliveries[index].provider == .safari && isCurrent(deliveries[index]) {
            guard let time = deliveries[index].destinationTime,
                  time.timeIntervalSince1970 <= export.exportedAt else { continue }
            // Positive, exact URL/latest-time matches only. Absence and older repeated visits stay unknown.
            if let exportedTime = export.visits[deliveries[index].url.absoluteString],
               abs(exportedTime - time.timeIntervalSince1970) < 0.000001 {
                matches[deliveries[index].url.absoluteString, default: []].append(index)
            }
        }
        for indexes in matches.values where indexes.count == 1 {
            let index = indexes[0]
            deliveries[index].remoteState = "seen"
            deliveries[index].remoteDevice = "User-supplied Safari export"
            deliveries[index].remoteObservedAt = now
        }
        resetSafariRetryIfResolved()
    }

    private mutating func resetSafariRetryIfResolved() {
        let pending = deliveries.contains { $0.provider == .safari && isCurrent($0)
            && $0.localAppliedAt != nil && !$0.suppressed
            && $0.remoteState != "seen" && $0.nativeState != "checkpointCovered" }
        if !pending { safariAssist?.resolveBacklog() }
    }

    public func summary(profileID: String?) -> CloudSummary {
        let records = deliveries.filter { $0.profileID == profileID && isCurrent($0) }
        return CloudSummary(monitored: records.count,
            pendingLocal: records.filter { $0.localAppliedAt == nil && !$0.suppressed }.count,
            safariPending: records.filter { $0.provider == .safari && $0.localAppliedAt != nil
                && !$0.suppressed && $0.nativeState != "checkpointCovered" && $0.remoteState != "seen" }.count,
            possibleStalls: records.filter { $0.nativeState == "possibleStall" }.count,
            checkpointCovered: records.filter { $0.nativeState == "checkpointCovered" }.count,
            browserNotObservable: records.filter { $0.provider == .browser && $0.localAppliedAt != nil
                && !$0.suppressed && $0.remoteState != "seen" }.count,
            remoteSeen: records.filter { $0.remoteState == "seen" }.count,
            suppressed: records.filter(\.suppressed).count, expiredUnverified: expiredUnverified,
            capacityReached: deliveries.count >= Self.capacity)
    }

    public func diagnostics(profileID: String?, plan: CloudRepairPlan? = nil, afterID: String? = nil) -> CloudDiagnostics {
        let records = deliveries.filter { $0.profileID == profileID && isCurrent($0) }.sorted {
            $0.queuedAt == $1.queuedAt ? $0.id > $1.id : $0.queuedAt > $1.queuedAt
        }
        let offset = afterID.flatMap { id in records.firstIndex { $0.id == id } }.map { $0 + 1 } ?? 0
        // Leave room for framing, URL escaping, and account diagnostics within the 1 MiB IPC limit.
        let page = Array(records.dropFirst(offset).prefix(32)).map { entry in
            var visible = entry
            visible.title = nil
            return visible
        }
        return CloudDiagnostics(summary: summary(profileID: profileID),
            deliveries: page, totalDeliveries: records.count, plan: plan,
            nextDeliveryID: offset + page.count < records.count ? page.last?.id : nil, safariAssist: safariAssist)
    }

    public mutating func maintenance(now: Date) { prune(now: now) }

    private mutating func prune(now: Date) {
        let removed = deliveries.filter { ($0.localAppliedAt != nil || $0.suppressed)
            && now.timeIntervalSince($0.queuedAt) > Self.retention }
        expiredUnverified += removed.filter { $0.remoteState != "seen" }.count
        let ids = Set(removed.map(\.id))
        deliveries.removeAll { ids.contains($0.id) }
        plans.removeAll { ids.contains($0.deliveryID) || (!$0.executed && now > $0.expiresAt) }
    }
}
