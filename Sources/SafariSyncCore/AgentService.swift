import Foundation

public final class AgentService: @unchecked Sendable {
    private struct OutboxEvent: Codable, Sendable {
        let eventID: String
        let sequence: Int64
        let url: URL
        let profileID: String
    }

    private struct RecoveryEntry: Codable, Sendable {
        let eventID: String
        let profileID: String
        let url: URL
        let outcome: String
        var attempt: Int
        var nextRetryAt: Date
    }

    private struct State: Codable, Sendable {
        var schemaVersion = 3
        var enabled = true
        var activeProfileID: String?
        var cursor: SafariArrivalCursor?
        var nextSafariSequence: Int64 = 1
        var outbox: [OutboxEvent] = []
        var deliveredSafariVisitIDs: Set<Int64> = []
        var recovery: [RecoveryEntry] = []
        var unrecoverableCount = 0
        var cloud = CloudDeliveryCoordinator()
        var browserACKSequences: [String: Int64] = [:]

        private enum CodingKeys: String, CodingKey {
            case schemaVersion, enabled, activeProfileID, cursor, nextSafariSequence
            case outbox, deliveredSafariVisitIDs, recovery, unrecoverableCount, cloud, browserACKSequences
        }

        init() {}

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            let sourceVersion = try values.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
            guard (1...3).contains(sourceVersion) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .schemaVersion,
                    in: values,
                    debugDescription: "unsupported Agent state schema \(sourceVersion)"
                )
            }
            schemaVersion = 3
            enabled = try values.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
            activeProfileID = try values.decodeIfPresent(String.self, forKey: .activeProfileID)
            cursor = try values.decodeIfPresent(SafariArrivalCursor.self, forKey: .cursor)
            nextSafariSequence = try values.decodeIfPresent(Int64.self, forKey: .nextSafariSequence) ?? 1
            outbox = try values.decodeIfPresent([OutboxEvent].self, forKey: .outbox) ?? []
            deliveredSafariVisitIDs = try values.decodeIfPresent(Set<Int64>.self, forKey: .deliveredSafariVisitIDs) ?? []
            recovery = try values.decodeIfPresent([RecoveryEntry].self, forKey: .recovery) ?? []
            unrecoverableCount = try values.decodeIfPresent(Int.self, forKey: .unrecoverableCount) ?? 0
            cloud = try values.decodeIfPresent(CloudDeliveryCoordinator.self, forKey: .cloud) ?? CloudDeliveryCoordinator()
            browserACKSequences = try values.decodeIfPresent([String: Int64].self, forKey: .browserACKSequences) ?? [:]
        }
    }

    private struct ObservedProfile: Sendable {
        var browserFamily: String
        var displayName: String
        var extensionVersion: String?
        var lastSeen: Date
        var cloudTracking: Bool
    }

    private let history: SafariHistoryStore
    private let persistence: EncryptedStateStore<State>
    private let authenticationKey: Data
    private let agentBuild: String?
    private let compatibility: RuntimeCompatibility?
    private let lock = NSLock()
    private var observedProfiles: [String: ObservedProfile] = [:]

    public init(history: SafariHistoryStore, stateURL: URL, secret: Data, agentBuild: String? = nil, compatibility: RuntimeCompatibility? = nil) {
        self.history = history
        self.persistence = EncryptedStateStore(url: stateURL, secret: secret)
        self.authenticationKey = secret
        self.agentBuild = agentBuild
        self.compatibility = compatibility
    }

    public func browserExchange(_ data: Data) throws -> Data {
        let message: BrowserMessage
        do {
            message = try JSONDecoder().decode(BrowserMessage.self, from: data)
        } catch {
            return try encode(.failure(TypedError(code: "INVALID_MESSAGE")))
        }
        guard message.version == safariSyncProtocolVersion else {
            return try encode(.failure(TypedError(code: "UNSUPPORTED_PROTOCOL")))
        }
        return try lock.withLock {
            guard validCandidateMessage(message) else {
                return try encode(.failure(TypedError(code: "INVALID_MESSAGE")))
            }
            observe(message)
            var state = try persistence.load() ?? State()

            guard message.profileID == state.activeProfileID else {
                return try encode(.failure(TypedError(code: "PROFILE_NOT_ACTIVE", retryable: true)))
            }
            let claimedIDs = Set((message.localReceipts ?? []).map(\.eventID)
                + (message.eventID.map { [$0] } ?? []))
            if ["ack", "outcome"].contains(message.operation), state.cloud.deliveries.contains(where: {
                claimedIDs.contains($0.id) && $0.profileID == message.profileID
                    && $0.kind != "relay" && !state.cloud.isCurrent($0)
            }) {
                // A rebind can cancel a probe/replay while the worker is awaiting its ACK.
                return try encode(.failure(TypedError(code: "CLOUD_DELIVERY_CANCELLED")))
            }

            switch message.operation {
            case "publish" where message.stream == "browserToSafari":
                let events = message.events ?? []
                guard events.count <= safariSyncMaximumPageSize else {
                    return try encode(.failure(TypedError(code: "INVALID_PAGE")))
                }
                var through: Int64 = 0
                for event in events {
                    try state.cloud.reserve(id: event.eventID, profileID: message.profileID,
                        provider: .safari, url: event.url, now: .now, title: event.title)
                }
                // Keep the cloud obligation even if insertion succeeds just before a crash.
                try persist(state)
                let identity = try history.cloudSnapshot(deliveries: []).databaseIdentity
                for event in events {
                    let receipt = try history.insertBrowserVisit(
                        eventID: event.eventID,
                        url: event.url,
                        title: event.title,
                        deliveredAt: .now
                    )
                    state.deliveredSafariVisitIDs.insert(receipt.visitID)
                    try state.cloud.recordLocalDelivery(id: event.eventID, visitID: String(receipt.visitID),
                        time: receipt.deliveredAt, now: .now, generation: receipt.generation,
                        databaseIdentity: identity)
                    through = max(through, event.sequence)
                }
                try persist(state)
                return try encode(.receipt(status: "ACCEPTED", throughSequence: through))

            case "pull" where message.stream == "safariToBrowser":
                let now = Date()
                try applyQueuedSafariDeliveries(state: &state, now: now)
                for index in state.recovery.indices
                    where state.recovery[index].profileID == message.profileID
                    && state.recovery[index].attempt < 20
                    && state.recovery[index].nextRetryAt <= now
                    && !state.outbox.contains(where: { $0.eventID == state.recovery[index].eventID }) {
                    state.recovery[index].attempt += 1
                    let retry = state.recovery[index]
                    state.outbox.append(OutboxEvent(
                        eventID: retry.eventID,
                        sequence: state.nextSafariSequence,
                        url: retry.url,
                        profileID: retry.profileID
                    ))
                    state.nextSafariSequence += 1
                    state.recovery[index].nextRetryAt = now.addingTimeInterval(
                        recoveryDelay(afterAttempt: retry.attempt)
                    )
                }
                try harvestSafariVisits(state: &state, profileID: message.profileID)
                let after = message.afterSequence ?? 0
                let limit = max(1, min(message.limit ?? safariSyncMaximumPageSize, safariSyncMaximumPageSize))
                let pending = state.outbox
                    .filter { $0.profileID == message.profileID && $0.sequence > after }
                    .prefix(limit)
                var events: [SyncEvent] = []
                var pageBytes = 512
                for entry in pending {
                    let event = SyncEvent(eventID: entry.eventID, sequence: entry.sequence, url: entry.url)
                    let size = try JSONEncoder().encode(event).count + 1
                    if pageBytes + size > 512 * 1024 {
                        if events.isEmpty { throw TypedError(code: "EVENT_EXCEEDS_TRANSPORT_LIMIT") }
                        break
                    }
                    events.append(event)
                    pageBytes += size
                }
                if message.capabilities?.contains("cloud-delivery-v1") == true {
                    for event in events {
                        try state.cloud.reserve(id: event.eventID, profileID: message.profileID,
                            provider: .browser, url: event.url, now: now)
                    }
                }
                let last = events.last?.sequence ?? after
                let hasMore = state.outbox.contains {
                    $0.profileID == message.profileID && $0.sequence > last
                }
                try persist(state)
                return try encode(.page(stream: "safariToBrowser", events: events, hasMore: hasMore,
                    capabilities: ["cloud-delivery-v1"]))

            case "ack" where message.stream == "safariToBrowser":
                guard let through = message.throughSequence, through >= 0 else {
                    return try encode(.failure(TypedError(code: "INVALID_RECEIPT")))
                }
                if through <= (state.browserACKSequences[message.profileID] ?? -1) {
                    return try encode(.receipt(status: "ACKNOWLEDGED", throughSequence: through))
                }
                let hasPendingPrefix = state.outbox.contains { $0.profileID == message.profileID && $0.sequence <= through }
                let hasClaimedRecovery = state.recovery.contains { $0.profileID == message.profileID
                    && (claimedIDs.isEmpty || claimedIDs.contains($0.eventID)) }
                if !hasPendingPrefix, !hasClaimedRecovery, through < state.nextSafariSequence {
                    // Handled/cancelled prefix after detailed evidence expired: no new receipt is inferred.
                    return try encode(.receipt(status: "ACKNOWLEDGED", throughSequence: through))
                }
                let acknowledgedRecoveryIDs = Set(state.outbox.filter {
                    $0.profileID == message.profileID && $0.sequence <= through
                }.map(\.eventID))
                if message.capabilities?.contains("cloud-delivery-v1") == true {
                    let expected = state.outbox.filter { $0.profileID == message.profileID && $0.sequence <= through }
                    let receipts = message.localReceipts ?? []
                    guard receipts.count <= 128, Set(receipts.map(\.eventID)).count == receipts.count,
                          Set(expected.map(\.eventID)).isSubset(of: Set(receipts.map(\.eventID))),
                          receipts.allSatisfy({ receipt in
                              (expected.contains { $0.eventID == receipt.eventID && $0.sequence == receipt.sequence }
                                  || state.cloud.deliveries.contains { $0.id == receipt.eventID
                                      && $0.profileID == message.profileID && $0.provider == .browser
                                      && $0.destinationVisitID == receipt.visitID
                                      && $0.destinationTime == Date(timeIntervalSince1970: receipt.visitTime / 1000) })
                                  && !receipt.visitID.isEmpty && receipt.visitID.utf8.count <= 128
                                  && receipt.visitTime.isFinite && receipt.visitTime > 0
                                  && state.cloud.deliveries.contains { $0.id == receipt.eventID
                                      && receipt.visitTime >= $0.queuedAt.timeIntervalSince1970 * 1000 - 1000 }
                                  && receipt.visitTime <= Date().timeIntervalSince1970 * 1000 + 60_000
                          }) else { return try encode(.failure(TypedError(code: "INVALID_LOCAL_RECEIPT"))) }
                    for receipt in receipts {
                        try state.cloud.recordLocalDelivery(id: receipt.eventID, visitID: receipt.visitID,
                            time: Date(timeIntervalSince1970: receipt.visitTime / 1000), now: .now)
                    }
                } else if acknowledgedRecoveryIDs.contains(where: { id in state.cloud.deliveries.contains { $0.id == id } }) {
                    return try encode(.failure(TypedError(code: "CLOUD_EXTENSION_UPGRADE_REQUIRED")))
                }
                state.outbox.removeAll {
                    $0.profileID == message.profileID && $0.sequence <= through
                }
                state.recovery.removeAll {
                    $0.profileID == message.profileID && acknowledgedRecoveryIDs.contains($0.eventID)
                }
                state.browserACKSequences[message.profileID] = max(through, state.browserACKSequences[message.profileID] ?? -1)
                try persist(state)
                return try encode(.receipt(status: "ACKNOWLEDGED", throughSequence: through))

            case "outcome":
                guard let eventID = message.eventID, let outcome = message.outcome else {
                    return try encode(.failure(TypedError(code: "INVALID_OUTCOME")))
                }
                if outcome == "LOCAL_REMOVED" {
                    state.cloud.suppress(profileID: message.profileID, urls: nil, id: eventID)
                    state.outbox.removeAll { $0.profileID == message.profileID && $0.eventID == eventID }
                    state.recovery.removeAll { $0.profileID == message.profileID && $0.eventID == eventID }
                    try persist(state)
                    return try encode(.receipt(status: "RECOVERY_RECORDED"))
                }
                if state.recovery.contains(where: {
                    $0.profileID == message.profileID && $0.eventID == eventID
                }) && !state.outbox.contains(where: {
                    $0.profileID == message.profileID && $0.eventID == eventID
                }) {
                    return try encode(.receipt(status: "RECOVERY_RECORDED"))
                }
                guard let failed = state.outbox.first(where: {
                    $0.profileID == message.profileID && $0.eventID == eventID
                }) else {
                    return try encode(.failure(TypedError(code: "OUTCOME_NOT_FOUND")))
                }
                state.outbox.removeAll { $0.profileID == message.profileID && $0.eventID == eventID }
                if let index = state.recovery.firstIndex(where: {
                    $0.profileID == message.profileID && $0.eventID == eventID
                }) {
                    state.recovery[index].nextRetryAt = state.recovery[index].attempt >= 20
                        ? .distantFuture
                        : Date().addingTimeInterval(recoveryDelay(afterAttempt: state.recovery[index].attempt))
                } else {
                    state.recovery.append(RecoveryEntry(
                        eventID: eventID,
                        profileID: message.profileID,
                        url: failed.url,
                        outcome: outcome,
                        attempt: 0,
                        nextRetryAt: Date().addingTimeInterval(5 * 60)
                    ))
                }
                try persist(state)
                return try encode(.receipt(status: "RECOVERY_RECORDED"))

            case "cloudRemoval":
                let affected = state.cloud.suppress(profileID: message.profileID,
                    urls: message.allHistoryRemoved == true ? nil : Set(message.removedURLs ?? []),
                    before: Date(timeIntervalSince1970: message.removedAt! / 1000))
                state.outbox.removeAll { $0.profileID == message.profileID && affected.contains($0.eventID) }
                state.recovery.removeAll { $0.profileID == message.profileID && affected.contains($0.eventID) }
                try persist(state)
                return try encode(.receipt(status: "REMOVAL_RECORDED"))

            default:
                return try encode(.failure(TypedError(code: "INVALID_OPERATION")))
            }
        }
    }

    public func selectProfile(_ profileID: String) throws -> String {
        try lock.withLock {
            var state = try persistence.load() ?? State()
            state.activeProfileID = profileID
            if state.cursor == nil {
                state.cursor = try history.arrivalBaseline(authenticationKey: authenticationKey)
            }
            try persist(state)
            return "ACTIVE"
        }
    }

    public func resetSafariCursor() throws {
        try lock.withLock {
            var state = try persistence.load() ?? State()
            state.cursor = try history.arrivalBaseline(authenticationKey: authenticationKey)
            try persist(state)
        }
    }

    public func resetAgentState() throws {
        try lock.withLock {
            let baseline = try history.arrivalBaseline(authenticationKey: authenticationKey)
            try persistence.removeStateAndUnresolvedCount()
            var state = State()
            state.cursor = baseline
            try persist(state)
        }
    }

    public func status() throws -> HealthSnapshot {
        lock.withLock {
            let state: State
            do {
                state = try persistence.load() ?? State()
            } catch {
                return HealthSnapshot(
                    enabled: false,
                    activeProfileID: nil,
                    runtimeState: "blocked",
                    issueCode: AgentIssueCode.stateUnreadable,
                    agentBuild: agentBuild,
                    compatibility: compatibility,
                    connectedProfiles: descriptors(activeProfileID: nil),
                    pendingBrowserToSafari: 0,
                    pendingSafariToBrowser: 0,
                    recoveryCount: 0,
                    unrecoverableCount: persistence.lastKnownUnresolvedCount()
                )
            }
            return HealthSnapshot(
                enabled: state.enabled,
                activeProfileID: state.activeProfileID,
                runtimeState: "ready",
                agentBuild: agentBuild,
                compatibility: compatibility,
                connectedProfiles: descriptors(activeProfileID: state.activeProfileID),
                pendingBrowserToSafari: 0,
                pendingSafariToBrowser: state.outbox.count,
                recoveryCount: state.recovery.count,
                unrecoverableCount: state.unrecoverableCount,
                cloud: state.cloud.summary(profileID: state.activeProfileID)
            )
        }
    }

    private func encode(_ response: ExchangeResponse) throws -> Data {
        try JSONEncoder().encode(response)
    }

    private func persist(_ state: State) throws {
        try persistence.save(state)
        let cloudIDs = state.cloud.deliveries.filter { $0.remoteState != "seen" && !$0.suppressed }.map(\.id)
        try persistence.saveLastKnownUnresolvedCount(Set(state.outbox.map(\.eventID)
            + state.recovery.map(\.eventID) + cloudIDs).count)
    }

    private func observe(_ message: BrowserMessage) {
        let now = Date()
        observedProfiles = observedProfiles.filter {
            $0.value.lastSeen > now.addingTimeInterval(-10 * 60)
        }
        if observedProfiles[message.profileID] == nil, observedProfiles.count >= 32 { return }
        let inferredFamily = message.profileID.split(separator: ":", maxSplits: 1).first.map(String.init)
        let family = ["chrome", "edge"].contains(message.browserFamily ?? "")
            ? message.browserFamily!
            : inferredFamily ?? "chromium"
        let existingName = observedProfiles[message.profileID]?.displayName
        let familyOrdinal = observedProfiles.values.filter { $0.browserFamily == family }.count + 1
        observedProfiles[message.profileID] = ObservedProfile(
            browserFamily: family,
            displayName: existingName ?? "\(family.capitalized) profile \(familyOrdinal)",
            extensionVersion: message.extensionVersion,
            lastSeen: now,
            cloudTracking: message.capabilities?.contains("cloud-delivery-v1") == true
        )
    }

    private func validCandidateMessage(_ message: BrowserMessage) -> Bool {
        guard !message.profileID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              message.profileID.utf8.count <= 128,
              (message.browserFamily?.utf8.count ?? 0) <= 16,
              (message.extensionVersion?.utf8.count ?? 0) <= 64,
              (message.capabilities?.count ?? 0) <= 16,
              (message.capabilities ?? []).allSatisfy({ $0.utf8.count <= 64 }) else { return false }
        switch message.operation {
        case "publish":
            return message.stream == "browserToSafari"
                && message.events != nil
                && message.events!.count <= safariSyncMaximumPageSize
                && message.events!.allSatisfy { !$0.eventID.isEmpty && $0.eventID.utf8.count <= 128
                    && $0.url.absoluteString.utf8.count <= 8192
                    && ($0.title?.utf8.count ?? 0) <= 16_384
                    && ["http", "https"].contains($0.url.scheme?.lowercased() ?? "") }
        case "pull":
            return message.stream == "safariToBrowser"
        case "ack":
            return message.stream == "safariToBrowser" && message.throughSequence != nil
        case "outcome":
            return message.eventID != nil && message.outcome != nil
        case "cloudRemoval":
            return (message.removedURLs?.count ?? 0) <= 128
                && (message.removedURLs ?? []).allSatisfy { $0.utf8.count <= 8192 }
                && message.removedAt.map { $0.isFinite && $0 > 0
                    && $0 <= Date().timeIntervalSince1970 * 1000 + 60_000 } == true
        default:
            return false
        }
    }

    private func descriptors(activeProfileID: String?) -> [BrowserProfileDescriptor] {
        let cutoff = Date().addingTimeInterval(-10 * 60)
        return observedProfiles.compactMap { profileID, observed in
            guard observed.lastSeen > cutoff else { return nil }
            return BrowserProfileDescriptor(
                profileID: profileID,
                browserFamily: observed.browserFamily,
                displayName: observed.displayName,
                extensionVersion: observed.extensionVersion,
                lastSeen: observed.lastSeen,
                active: profileID == activeProfileID
            )
        }.sorted { lhs, rhs in
            if lhs.active != rhs.active { return lhs.active }
            if lhs.browserFamily != rhs.browserFamily { return lhs.browserFamily < rhs.browserFamily }
            return lhs.profileID < rhs.profileID
        }
    }

    private func harvestSafariVisits(state: inout State, profileID: String) throws {
        if state.cursor == nil {
            state.cursor = try history.arrivalBaseline(authenticationKey: authenticationKey)
            return
        }
        guard let cursor = state.cursor else { return }
        let arrival = try history.newVisits(
            after: cursor,
            authenticationKey: authenticationKey,
            limit: safariSyncMaximumPageSize
        )
        for visit in arrival.events where !state.deliveredSafariVisitIDs.contains(visit.visitID)
            && !state.cloud.isSafariAssistURL(visit.url) {
            state.outbox.append(OutboxEvent(
                eventID: UUID().uuidString.lowercased(),
                sequence: state.nextSafariSequence,
                url: visit.url,
                profileID: profileID
            ))
            state.nextSafariSequence += 1
        }
        state.cursor = arrival.cursor
        state.deliveredSafariVisitIDs = Set(state.deliveredSafariVisitIDs.filter {
            $0 > arrival.cursor.visitID
        })
    }

    private func recoveryDelay(afterAttempt attempt: Int) -> TimeInterval {
        let schedule: [TimeInterval] = [5 * 60, 15 * 60, 30 * 60, 2 * 60 * 60, 6 * 60 * 60]
        return schedule[min(max(attempt, 0), schedule.count - 1)]
    }

    public func pollCloud(now: Date = .now, safariIsRunning: Bool,
                          assistSafari: (URL) -> String = { _ in "unavailable" },
                          launchSafari: () throws -> Bool) throws {
        // Reserve durably under the lock; slow application events must not block IPC.
        let work: (batch: [CloudDelivery], launch: Bool, assist: URL?)? = try lock.withLock {
            var state = try persistence.load() ?? State()
            guard state.enabled, let profile = state.activeProfileID else { return nil }
            let previous = state.cloud
            state.cloud.maintenance(now: now)
            try applyQueuedSafariDeliveries(state: &state, now: now)
            let batch = state.cloud.safariBatch(profileID: profile, now: now, isRunning: safariIsRunning)
            guard !batch.isEmpty else {
                if previous != state.cloud { try persist(state) }
                return nil
            }
            let snapshot = try history.cloudSnapshot(deliveries: batch)
            let launch = state.cloud.reconcileSafari(batch: batch, snapshot: snapshot,
                now: now, isRunning: safariIsRunning)
            let assist = state.cloud.reserveSafariAssist(batch: batch, now: now, isRunning: safariIsRunning)
            try persist(state)
            return (batch, launch, assist)
        }
        guard let work else { return }
        let result: String
        if work.launch { result = (try? launchSafari()) == true ? "launchAccepted" : "launchFailed" }
        else if let url = work.assist { result = assistSafari(url) }
        else { return }
        try lock.withLock {
            var state = try persistence.load() ?? State()
            state.cloud.recordTrigger(batch: work.batch, result: result)
            state.cloud.recordSafariAssist(result: result)
            try persist(state)
        }
    }

    /// Runtime dispatch exposes this interface only to authenticated Menu requests.
    public func cloudCommand(_ command: MenuCommand, now: Date = .now) throws -> CloudDiagnostics {
        try lock.withLock {
            var state = try persistence.load() ?? State()
            guard state.enabled, let profile = state.activeProfileID,
                  command.profileID == profile else { throw TypedError(code: "PROFILE_NOT_ACTIVE") }
            var plan: CloudRepairPlan?
            switch command.operation {
            case "cloudStatus": break
            case "cloudSafariAssist":
                guard let enabled = command.result, ["enable", "disable"].contains(enabled) else {
                    throw TypedError(code: "INVALID_MESSAGE")
                }
                state.cloud.setSafariAssist(enabled: enabled == "enable", now: now)
            case "cloudProbe":
                guard let provider = command.provider else { throw TypedError(code: "INVALID_MESSAGE") }
                if provider == .browser, observedProfiles[profile]?.cloudTracking != true {
                    throw TypedError(code: "CLOUD_EXTENSION_UPGRADE_REQUIRED")
                }
                let id = "probe:\(UUID().uuidString)"
                let url = URL(string: "https://example.com/safari-history-sync-probe/\(UUID().uuidString)")!
                try state.cloud.reserve(id: id, profileID: profile, provider: provider,
                    url: url, now: now, kind: "probe")
                if provider == .browser { enqueueCloudDelivery(id: id, url: url, profileID: profile, state: &state) }
                // Durable intent precedes Safari writes and survives Menu/Agent restart.
                try persist(state)
                try applyQueuedSafariDeliveries(state: &state, now: now)
            case "cloudObserve":
                guard let id = command.deliveryID, let result = command.result, let device = command.device else {
                    throw TypedError(code: "INVALID_MESSAGE")
                }
                try state.cloud.observeRemote(id: id, profileID: profile, result: result, device: device, now: now)
            case "cloudPrepareReplay", "cloudExecuteReplay":
                // Recheck owned Safari rows before presenting or executing a replay.
                let rows = state.cloud.deliveries.filter { $0.profileID == profile && $0.provider == .safari
                    && $0.localAppliedAt != nil && state.cloud.isCurrent($0) }
                if !rows.isEmpty {
                    let snapshot = try history.cloudSnapshot(deliveries: rows)
                    _ = state.cloud.reconcileSafari(batch: rows, snapshot: snapshot, now: now, isRunning: true)
                    try persist(state)
                }
                if command.operation == "cloudPrepareReplay", let id = command.deliveryID {
                    plan = try state.cloud.prepareRepair(id: id, profileID: profile, now: now)
                } else if command.operation == "cloudExecuteReplay", let id = command.planID {
                    plan = try state.cloud.executeRepair(id: id, profileID: profile, now: now)
                    if let plan, plan.provider == .browser,
                       state.cloud.deliveries.first(where: { $0.id == plan.attemptID })?.localAppliedAt == nil {
                        guard observedProfiles[profile]?.cloudTracking == true else {
                            throw TypedError(code: "CLOUD_EXTENSION_UPGRADE_REQUIRED")
                        }
                        enqueueCloudDelivery(id: plan.attemptID, url: plan.url, profileID: profile, state: &state)
                    }
                    try persist(state)
                    try applyQueuedSafariDeliveries(state: &state, now: now)
                } else { throw TypedError(code: "INVALID_MESSAGE") }
            case "cloudCompareExport":
                guard let json = command.snapshotJSON else { throw TypedError(code: "INVALID_MESSAGE") }
                try state.cloud.compareSafariExport(Data(json.utf8), profileID: profile, now: now)
            case "cloudRebind":
                guard let provider = command.provider else { throw TypedError(code: "INVALID_MESSAGE") }
                state.cloud.rebind(provider: provider, profileID: profile)
                let stale = Set(state.cloud.deliveries.filter { !state.cloud.isCurrent($0) && $0.kind != "relay" }.map(\.id))
                state.outbox.removeAll { stale.contains($0.eventID) }
                state.recovery.removeAll { stale.contains($0.eventID) }
            default: throw TypedError(code: "INVALID_MESSAGE")
            }
            try persist(state)
            return state.cloud.diagnostics(profileID: profile, plan: plan,
                afterID: command.operation == "cloudStatus" ? command.deliveryID : nil)
        }
    }

    private func enqueueCloudDelivery(id: String, url: URL, profileID: String, state: inout State) {
        guard !state.outbox.contains(where: { $0.eventID == id }) else { return }
        state.outbox.append(OutboxEvent(eventID: id, sequence: state.nextSafariSequence, url: url, profileID: profileID))
        state.nextSafariSequence += 1
    }

    private func applyQueuedSafariDeliveries(state: inout State, now: Date) throws {
        let queued = state.cloud.deliveries.filter { $0.profileID == state.activeProfileID
            && $0.provider == .safari && $0.localAppliedAt == nil && !$0.suppressed && state.cloud.isCurrent($0) }
        guard !queued.isEmpty else { return }
        let identity = try history.cloudSnapshot(deliveries: []).databaseIdentity
        for entry in queued.prefix(128) {
            let receipt = try history.insertBrowserVisit(eventID: entry.id, url: entry.url, title: entry.title, deliveredAt: now)
            state.deliveredSafariVisitIDs.insert(receipt.visitID)
            try state.cloud.recordLocalDelivery(id: entry.id, visitID: String(receipt.visitID), time: receipt.deliveredAt,
                now: now, generation: receipt.generation, databaseIdentity: identity)
        }
    }
}
