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
        var schemaVersion = 2
        var enabled = true
        var activeProfileID: String?
        var cursor: SafariArrivalCursor?
        var nextSafariSequence: Int64 = 1
        var outbox: [OutboxEvent] = []
        var deliveredSafariVisitIDs: Set<Int64> = []
        var recovery: [RecoveryEntry] = []
        var unrecoverableCount = 0

        private enum CodingKeys: String, CodingKey {
            case schemaVersion, enabled, activeProfileID, cursor, nextSafariSequence
            case outbox, deliveredSafariVisitIDs, recovery, unrecoverableCount
        }

        init() {}

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            let sourceVersion = try values.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
            guard sourceVersion == 1 || sourceVersion == 2 else {
                throw DecodingError.dataCorruptedError(
                    forKey: .schemaVersion,
                    in: values,
                    debugDescription: "unsupported Agent state schema \(sourceVersion)"
                )
            }
            schemaVersion = 2
            enabled = try values.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
            activeProfileID = try values.decodeIfPresent(String.self, forKey: .activeProfileID)
            cursor = try values.decodeIfPresent(SafariArrivalCursor.self, forKey: .cursor)
            nextSafariSequence = try values.decodeIfPresent(Int64.self, forKey: .nextSafariSequence) ?? 1
            outbox = try values.decodeIfPresent([OutboxEvent].self, forKey: .outbox) ?? []
            deliveredSafariVisitIDs = try values.decodeIfPresent(Set<Int64>.self, forKey: .deliveredSafariVisitIDs) ?? []
            recovery = try values.decodeIfPresent([RecoveryEntry].self, forKey: .recovery) ?? []
            unrecoverableCount = try values.decodeIfPresent(Int.self, forKey: .unrecoverableCount) ?? 0
        }
    }

    private struct ObservedProfile: Sendable {
        var browserFamily: String
        var displayName: String
        var extensionVersion: String?
        var lastSeen: Date
    }

    private let history: SafariHistoryStore
    private let persistence: EncryptedStateStore<State>
    private let authenticationKey: Data
    private let agentBuild: String?
    private let lock = NSLock()
    private var observedProfiles: [String: ObservedProfile] = [:]

    public init(history: SafariHistoryStore, stateURL: URL, secret: Data, agentBuild: String? = nil) {
        self.history = history
        self.persistence = EncryptedStateStore(url: stateURL, secret: secret)
        self.authenticationKey = secret
        self.agentBuild = agentBuild
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

            switch message.operation {
            case "publish" where message.stream == "browserToSafari":
                let events = message.events ?? []
                guard events.count <= safariSyncMaximumPageSize else {
                    return try encode(.failure(TypedError(code: "INVALID_PAGE")))
                }
                var through: Int64 = 0
                for event in events {
                    let receipt = try history.insertBrowserVisit(
                        eventID: event.eventID,
                        url: event.url,
                        title: event.title,
                        deliveredAt: .now
                    )
                    state.deliveredSafariVisitIDs.insert(receipt.visitID)
                    through = max(through, event.sequence)
                }
                try persist(state)
                return try encode(.receipt(status: "ACCEPTED", throughSequence: through))

            case "pull" where message.stream == "safariToBrowser":
                let now = Date()
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
                let events = pending.map { SyncEvent(eventID: $0.eventID, sequence: $0.sequence, url: $0.url) }
                let last = events.last?.sequence ?? after
                let hasMore = state.outbox.contains {
                    $0.profileID == message.profileID && $0.sequence > last
                }
                try persist(state)
                return try encode(.page(stream: "safariToBrowser", events: events, hasMore: hasMore))

            case "ack" where message.stream == "safariToBrowser":
                guard let through = message.throughSequence, through >= 0 else {
                    return try encode(.failure(TypedError(code: "INVALID_RECEIPT")))
                }
                let acknowledgedRecoveryIDs = Set(state.outbox.filter {
                    $0.profileID == message.profileID && $0.sequence <= through
                }.map(\.eventID))
                state.outbox.removeAll {
                    $0.profileID == message.profileID && $0.sequence <= through
                }
                state.recovery.removeAll {
                    $0.profileID == message.profileID && acknowledgedRecoveryIDs.contains($0.eventID)
                }
                try persist(state)
                return try encode(.receipt(status: "ACKNOWLEDGED", throughSequence: through))

            case "outcome":
                guard let eventID = message.eventID, let outcome = message.outcome else {
                    return try encode(.failure(TypedError(code: "INVALID_OUTCOME")))
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
                connectedProfiles: descriptors(activeProfileID: state.activeProfileID),
                pendingBrowserToSafari: 0,
                pendingSafariToBrowser: state.outbox.count,
                recoveryCount: state.recovery.count,
                unrecoverableCount: state.unrecoverableCount
            )
        }
    }

    private func encode(_ response: ExchangeResponse) throws -> Data {
        try JSONEncoder().encode(response)
    }

    private func persist(_ state: State) throws {
        try persistence.save(state)
        try persistence.saveLastKnownUnresolvedCount(state.outbox.count + state.recovery.count)
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
            lastSeen: now
        )
    }

    private func validCandidateMessage(_ message: BrowserMessage) -> Bool {
        guard !message.profileID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              message.profileID.utf8.count <= 128,
              (message.browserFamily?.utf8.count ?? 0) <= 16,
              (message.extensionVersion?.utf8.count ?? 0) <= 64 else { return false }
        switch message.operation {
        case "publish":
            return message.stream == "browserToSafari"
                && message.events != nil
                && message.events!.count <= safariSyncMaximumPageSize
        case "pull":
            return message.stream == "safariToBrowser"
        case "ack":
            return message.stream == "safariToBrowser" && message.throughSequence != nil
        case "outcome":
            return message.eventID != nil && message.outcome != nil
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
        for visit in arrival.events where !state.deliveredSafariVisitIDs.contains(visit.visitID) {
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
}
