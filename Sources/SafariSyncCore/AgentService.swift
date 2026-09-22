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
        var enabled = true
        var activeProfileID: String?
        var stagingProfileID: String?
        var switchState = "STABLE"
        var cursor: SafariArrivalCursor?
        var nextSafariSequence: Int64 = 1
        var outbox: [OutboxEvent] = []
        var deliveredSafariVisitIDs: Set<Int64> = []
        var recovery: [RecoveryEntry] = []
        var unrecoverableCount = 0
    }

    private let history: SafariHistoryStore
    private let persistence: EncryptedStateStore<State>
    private let authenticationKey: Data
    private let lock = NSLock()

    public init(history: SafariHistoryStore, stateURL: URL, secret: Data) {
        self.history = history
        self.persistence = EncryptedStateStore(url: stateURL, secret: secret)
        self.authenticationKey = secret
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
            var state = try persistence.load() ?? State()
            if state.activeProfileID == nil {
                state.activeProfileID = message.profileID
                if state.cursor == nil {
                    state.cursor = try history.arrivalBaseline(authenticationKey: authenticationKey)
                }
            }

            if message.operation == "freezeAck" {
                guard message.profileID == state.activeProfileID,
                      state.switchState == "AWAITING_FREEZE_ACK",
                      !state.outbox.contains(where: { $0.profileID == message.profileID }),
                      let staging = state.stagingProfileID else {
                    return try encode(.failure(TypedError(code: "UNEXPECTED_FREEZE_ACK")))
                }
                state.activeProfileID = staging
                state.stagingProfileID = nil
                state.switchState = "STABLE"
                try persist(state)
                return try encode(.receipt(status: "PROFILE_ACTIVATED"))
            }

            if state.switchState == "AWAITING_FREEZE_ACK" {
                if message.profileID != state.activeProfileID {
                    return try encode(.failure(TypedError(code: "PROFILE_STAGING", retryable: true)))
                }
                if message.operation == "pull" && !state.outbox.contains(where: {
                    $0.profileID == message.profileID
                }) {
                    return try encode(.failure(TypedError(code: "FREEZE_REQUIRED", retryable: true)))
                }
            }

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
                        title: nil,
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
                if state.switchState == "STABLE" {
                    try harvestSafariVisits(state: &state, profileID: message.profileID)
                }
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
            if state.activeProfileID == nil || state.activeProfileID == profileID {
                state.activeProfileID = profileID
                state.stagingProfileID = nil
                state.switchState = "STABLE"
                if state.cursor == nil {
                    state.cursor = try history.arrivalBaseline(authenticationKey: authenticationKey)
                }
                try persist(state)
                return "ACTIVE"
            }
            if let current = state.activeProfileID {
                try harvestSafariVisits(state: &state, profileID: current)
            }
            state.stagingProfileID = profileID
            state.switchState = "AWAITING_FREEZE_ACK"
            try persist(state)
            return state.switchState
        }
    }

    public func status() throws -> HealthSnapshot {
        lock.withLock {
            let state: State
            do {
                state = try persistence.load() ?? State()
            } catch {
                return HealthSnapshot(
                    protocolVersion: safariSyncProtocolVersion,
                    enabled: false,
                    activeProfileID: nil,
                    stagingProfileID: nil,
                    switchState: "KEY_UNAVAILABLE",
                    pendingBrowserToSafari: 0,
                    pendingSafariToBrowser: 0,
                    recoveryCount: 0,
                    unrecoverableCount: persistence.lastKnownUnresolvedCount()
                )
            }
            return HealthSnapshot(
                protocolVersion: safariSyncProtocolVersion,
                enabled: state.enabled,
                activeProfileID: state.activeProfileID,
                stagingProfileID: state.stagingProfileID,
                switchState: state.switchState,
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
