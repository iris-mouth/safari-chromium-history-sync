import CryptoKit
import Foundation

public final class EncryptedStateStore<State: Codable>: @unchecked Sendable {
    private let url: URL
    private let recoveryCountURL: URL
    private let key: SymmetricKey
    private let lock = NSLock()

    public init(url: URL, secret: Data) {
        self.url = url
        self.recoveryCountURL = url.appendingPathExtension("unresolved-count")
        self.key = SymmetricKey(data: SHA256.hash(data: secret + Data("agent-state-v1".utf8)))
    }

    public func load() throws -> State? {
        try lock.withLock {
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            let sealed = try AES.GCM.SealedBox(combined: Data(contentsOf: url))
            return try JSONDecoder().decode(State.self, from: AES.GCM.open(sealed, using: key))
        }
    }

    public func save(_ state: State) throws {
        try lock.withLock {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let encoded = try JSONEncoder().encode(state)
            guard let combined = try AES.GCM.seal(encoded, using: key).combined else {
                throw IPCError.invalidFrame
            }
            let temporary = url.appendingPathExtension("new")
            try combined.write(to: temporary, options: [.atomic, .completeFileProtection])
            if FileManager.default.fileExists(atPath: url.path) {
                _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
            } else {
                try FileManager.default.moveItem(at: temporary, to: url)
            }
        }
    }

    public func saveLastKnownUnresolvedCount(_ count: Int) throws {
        try Data(String(max(0, count)).utf8).write(
            to: recoveryCountURL,
            options: [.atomic, .completeFileProtection]
        )
    }

    public func lastKnownUnresolvedCount() -> Int {
        guard let data = try? Data(contentsOf: recoveryCountURL),
              let text = String(data: data, encoding: .utf8),
              let count = Int(text) else { return 0 }
        return max(0, count)
    }
}
