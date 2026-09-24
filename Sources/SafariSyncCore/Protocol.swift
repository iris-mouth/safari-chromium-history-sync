import Foundation

public let safariSyncProtocolVersion = 1
public let safariSyncMaximumPageSize = 128

public struct SyncEvent: Codable, Equatable, Sendable {
    public let eventID: String
    public let sequence: Int64
    public let url: URL
    public let title: String?

    public init(eventID: String, sequence: Int64, url: URL, title: String? = nil) {
        self.eventID = eventID
        self.sequence = sequence
        self.url = url
        self.title = title
    }

    enum CodingKeys: String, CodingKey {
        case eventID = "eventId"
        case sequence, url, title
    }
}

public struct BrowserMessage: Codable, Sendable {
    public let version: Int
    public let operation: String
    public let profileID: String
    public let events: [SyncEvent]?
    public let afterSequence: Int64?
    public let throughSequence: Int64?
    public let limit: Int?
    public let stream: String?
    public let eventID: String?
    public let outcome: String?
    public let browserFamily: String?
    public let extensionVersion: String?

    enum CodingKeys: String, CodingKey {
        case version, operation, events, limit, stream, outcome, browserFamily, extensionVersion
        case eventID = "eventId"
        case profileID = "profileId"
        case afterSequence, throughSequence
    }
}

public struct BrowserProfileDescriptor: Codable, Equatable, Sendable {
    public let profileID: String
    public let browserFamily: String
    public let displayName: String
    public let extensionVersion: String?
    public let lastSeen: Date
    public let active: Bool

    public init(
        profileID: String,
        browserFamily: String,
        displayName: String,
        extensionVersion: String?,
        lastSeen: Date,
        active: Bool
    ) {
        self.profileID = profileID
        self.browserFamily = browserFamily
        self.displayName = displayName
        self.extensionVersion = extensionVersion
        self.lastSeen = lastSeen
        self.active = active
    }

    enum CodingKeys: String, CodingKey {
        case browserFamily, displayName, extensionVersion, lastSeen, active
        case profileID = "profileId"
    }
}

public struct TypedError: Codable, Error, Equatable, Sendable, LocalizedError {
    public let type: String
    public let code: String
    public let retryable: Bool

    public init(code: String, retryable: Bool = false) {
        self.type = "error"
        self.code = code
        self.retryable = retryable
    }

    public var errorDescription: String? { code }
}

public struct HealthSnapshot: Codable, Equatable, Sendable {
    public let protocolVersion: Int
    public let enabled: Bool
    public let activeProfileID: String?
    public let runtimeState: String
    public let issueCode: String?
    public let agentBuild: String?
    public let compatibility: RuntimeCompatibility?
    public let connectedProfiles: [BrowserProfileDescriptor]
    public let pendingBrowserToSafari: Int
    public let pendingSafariToBrowser: Int
    public let recoveryCount: Int
    public let unrecoverableCount: Int

    enum CodingKeys: String, CodingKey {
        case protocolVersion, enabled, runtimeState, issueCode, agentBuild, connectedProfiles, compatibility
        case activeProfileID = "activeProfileId"
        case pendingBrowserToSafari, pendingSafariToBrowser
        case recoveryCount, unrecoverableCount
    }

    public init(
        protocolVersion: Int = safariSyncProtocolVersion,
        enabled: Bool,
        activeProfileID: String?,
        runtimeState: String,
        issueCode: String? = nil,
        agentBuild: String? = nil,
        compatibility: RuntimeCompatibility? = nil,
        connectedProfiles: [BrowserProfileDescriptor] = [],
        pendingBrowserToSafari: Int,
        pendingSafariToBrowser: Int,
        recoveryCount: Int,
        unrecoverableCount: Int
    ) {
        self.protocolVersion = protocolVersion
        self.enabled = enabled
        self.activeProfileID = activeProfileID
        self.runtimeState = runtimeState
        self.issueCode = issueCode
        self.agentBuild = agentBuild
        self.compatibility = compatibility
        self.connectedProfiles = connectedProfiles
        self.pendingBrowserToSafari = pendingBrowserToSafari
        self.pendingSafariToBrowser = pendingSafariToBrowser
        self.recoveryCount = recoveryCount
        self.unrecoverableCount = unrecoverableCount
    }
}

public struct MenuCommand: Codable, Sendable {
    public let operation: String
    public let profileID: String?

    public init(operation: String, profileID: String? = nil) {
        self.operation = operation
        self.profileID = profileID
    }

    enum CodingKeys: String, CodingKey {
        case operation
        case profileID = "profileId"
    }
}

public struct ProfileSwitchStatus: Codable, Sendable {
    public let state: String
    public let profileID: String

    public init(state: String, profileID: String) {
        self.state = state
        self.profileID = profileID
    }

    enum CodingKeys: String, CodingKey {
        case state
        case profileID = "profileId"
    }
}

public struct RecoveryCommandStatus: Codable, Equatable, Sendable {
    public let state: String
    public let operation: String

    public init(state: String, operation: String) {
        self.state = state
        self.operation = operation
    }
}

public enum ExchangeResponse: Encodable, Sendable {
    case receipt(status: String, throughSequence: Int64? = nil)
    case page(stream: String, events: [SyncEvent], hasMore: Bool)
    case failure(TypedError)

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: DynamicKey.self)
        switch self {
        case let .receipt(status, throughSequence):
            try container.encode("receipt", forKey: DynamicKey("type"))
            try container.encode(status, forKey: DynamicKey("status"))
            try container.encodeIfPresent(throughSequence, forKey: DynamicKey("throughSequence"))
        case let .page(stream, events, hasMore):
            try container.encode("page", forKey: DynamicKey("type"))
            try container.encode(stream, forKey: DynamicKey("stream"))
            try container.encode(events, forKey: DynamicKey("events"))
            try container.encode(hasMore, forKey: DynamicKey("hasMore"))
        case let .failure(error):
            try error.encode(to: encoder)
        }
    }
}

private struct DynamicKey: CodingKey {
    let stringValue: String
    let intValue: Int? = nil
    init(_ value: String) { stringValue = value }
    init?(stringValue: String) { self.init(stringValue) }
    init?(intValue: Int) { return nil }
}
