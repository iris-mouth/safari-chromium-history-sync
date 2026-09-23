import CryptoKit
import Foundation

public struct NativeMessagingTarget: Hashable, Sendable {
    public let id: String
    public let directory: URL

    public init(id: String, directory: URL) {
        self.id = id
        self.directory = directory
    }
}

public enum NativeMessagingManifestStore {
    public static func extensionID(publicKey: Data) -> String {
        let alphabet = Array("abcdefghijklmnop")
        return SHA256.hash(data: publicKey).prefix(16).flatMap { byte in
            [alphabet[Int(byte >> 4)], alphabet[Int(byte & 0x0f)]]
        }.map(String.init).joined()
    }

    public static func ownsManifest(
        target: NativeMessagingTarget,
        hostName: String,
        bridgeSuffix: String
    ) -> Bool {
        let url = target.directory.appendingPathComponent("\(hostName).json")
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["name"] as? String == hostName,
              let path = object["path"] as? String else { return false }
        return path.hasSuffix(bridgeSuffix)
    }

    public static func reconcile(
        targets: [NativeMessagingTarget],
        selectedTargetIDs: Set<String>,
        hostName: String,
        bridgeURL: URL,
        extensionID: String,
        bridgeSuffix: String
    ) throws {
        for target in targets {
            let manifestURL = target.directory.appendingPathComponent("\(hostName).json")
            if selectedTargetIDs.contains(target.id) {
                try FileManager.default.createDirectory(
                    at: target.directory,
                    withIntermediateDirectories: true
                )
                let object: [String: Any] = [
                    "name": hostName,
                    "description": "Safari history sync bridge",
                    "path": bridgeURL.path,
                    "type": "stdio",
                    "allowed_origins": ["chrome-extension://\(extensionID)/"],
                ]
                let data = try JSONSerialization.data(
                    withJSONObject: object,
                    options: [.prettyPrinted, .sortedKeys]
                )
                try data.write(to: manifestURL, options: .atomic)
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o600],
                    ofItemAtPath: manifestURL.path
                )
            } else if ownsManifest(
                target: target,
                hostName: hostName,
                bridgeSuffix: bridgeSuffix
            ) {
                try FileManager.default.removeItem(at: manifestURL)
            }
        }
    }
}
