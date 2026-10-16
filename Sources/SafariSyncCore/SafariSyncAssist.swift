import Foundation

/// Opt-in state stored in the same sealed journal as delivery obligations.
public struct SafariSyncAssist: Codable, Equatable, Sendable {
    public static let minimumInterval: TimeInterval = 300
    public static let observationInterval: TimeInterval = 60
    public static let nativeActivityGrace: TimeInterval = 90
    private static let retryIntervals: [TimeInterval] = [300, 600, 1200, 2400, 3600]

    public private(set) var enabled = false
    public private(set) var lastResult: String?
    public private(set) var lastAttempt: Date?
    public private(set) var nextAttemptAt: Date?
    public private(set) var attemptsWithoutProgress = 0
    public let controlURL: URL
    private var hasPending = false
    private var checkpoint: Int64?
    private var databaseIdentity: String?

    private enum CodingKeys: String, CodingKey {
        case enabled, lastResult, lastAttempt, nextAttemptAt, attemptsWithoutProgress, controlURL
        case hasPending, checkpoint, databaseIdentity
    }

    public init() {
        controlURL = URL(string: "https://example.com/?safari-sync-control=\(UUID().uuidString.lowercased())")!
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try values.decode(Bool.self, forKey: .enabled)
        lastResult = try values.decodeIfPresent(String.self, forKey: .lastResult)
        lastAttempt = try values.decodeIfPresent(Date.self, forKey: .lastAttempt)
        controlURL = try values.decode(URL.self, forKey: .controlURL)
        attemptsWithoutProgress = max(0, min(try values.decodeIfPresent(Int.self,
            forKey: .attemptsWithoutProgress) ?? 0, Self.retryIntervals.count))
        hasPending = try values.decodeIfPresent(Bool.self, forKey: .hasPending) ?? false
        checkpoint = try values.decodeIfPresent(Int64.self, forKey: .checkpoint)
        databaseIdentity = try values.decodeIfPresent(String.self, forKey: .databaseIdentity)
        // Build 611's daily reservation array is deliberately retired, but its cooldown survives.
        nextAttemptAt = try values.decodeIfPresent(Date.self, forKey: .nextAttemptAt)
            ?? (values.contains(.attemptsWithoutProgress) ? nil : lastAttempt?.addingTimeInterval(Self.minimumInterval))
    }

    public mutating func setEnabled(_ enabled: Bool) {
        self.enabled = enabled
        if enabled && lastResult == "permissionDenied" { lastResult = nil }
    }

    public mutating func reserve(now: Date) -> URL? {
        guard enabled, lastResult != "permissionDenied" else { return nil }
        guard reserveAttempt(now: now) else { return nil }
        return controlURL
    }

    /// Hidden launches and opted-in navigations share one durable retry schedule.
    public mutating func reserveLaunch(now: Date) -> Bool { reserveAttempt(now: now) }

    private mutating func reserveAttempt(now: Date) -> Bool {
        guard nextAttemptAt.map({ now >= $0 }) ?? true,
              lastAttempt.map({ now.timeIntervalSince($0) >= Self.minimumInterval }) ?? true else { return false }
        let delay = Self.retryIntervals[min(attemptsWithoutProgress, Self.retryIntervals.count - 1)]
        attemptsWithoutProgress = min(attemptsWithoutProgress + 1, Self.retryIntervals.count)
        lastAttempt = now
        nextAttemptAt = now.addingTimeInterval(delay)
        lastResult = "reserved"
        return true
    }

    public mutating func observe(pending: Bool, checkpoint: Int64, databaseIdentity: String) {
        let progressed = self.databaseIdentity == databaseIdentity
            && self.checkpoint.map({ checkpoint > $0 }) == true
        if !pending {
            resolveBacklog()
        } else if !hasPending || progressed || self.databaseIdentity != databaseIdentity {
            attemptsWithoutProgress = 0
            nextAttemptAt = lastAttempt?.addingTimeInterval(Self.minimumInterval)
        }
        hasPending = pending
        self.checkpoint = checkpoint
        self.databaseIdentity = databaseIdentity
    }

    /// Receiver evidence may resolve the last obligation between native polls.
    public mutating func resolveBacklog() {
        hasPending = false
        attemptsWithoutProgress = 0
        nextAttemptAt = nil
        // Keep lastAttempt so new work cannot bypass the shared five-minute floor.
    }

    public mutating func inheritLegacyLaunch(_ date: Date) {
        guard lastAttempt.map({ date > $0 }) ?? true else { return }
        lastAttempt = date
        nextAttemptAt = date.addingTimeInterval(Self.minimumInterval)
    }

    public mutating func record(result: String) {
        lastResult = result
        // A denied permission needs a deliberate enable action, not repeated prompts.
        if result == "permissionDenied" { enabled = false }
    }

    public static func isControlURL(_ url: URL) -> Bool {
        guard url.scheme == "https", url.host == "example.com", url.path == "/",
              url.fragment == nil, url.user == nil, url.password == nil, url.port == nil,
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              (items.count == 1 || (items.count == 2 && items[1].name == "safari-sync-refresh" && items[1].value == "1")),
              items[0].name == "safari-sync-control",
              let value = items[0].value, UUID(uuidString: value) != nil else { return false }
        return true
    }

    public static func alternateControlURL(for url: URL) -> URL? {
        guard isControlURL(url), URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.count == 1 else { return nil }
        return URL(string: url.absoluteString + "&safari-sync-refresh=1")
    }

    public func owns(_ url: URL) -> Bool {
        url == controlURL || url == Self.alternateControlURL(for: controlURL)
    }
}
