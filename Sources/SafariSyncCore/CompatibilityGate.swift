import CryptoKit
import Darwin
import Foundation

public struct CompatibilityTuple: Codable, Equatable, Sendable {
    public let macOSVersion: String
    public let macOSBuild: String
    public let safariBuild: String
    public let historyServiceSHA256: String

    public init(macOSVersion: String, macOSBuild: String, safariBuild: String, historyServiceSHA256: String) {
        self.macOSVersion = macOSVersion
        self.macOSBuild = macOSBuild
        self.safariBuild = safariBuild
        self.historyServiceSHA256 = historyServiceSHA256
    }
}

public struct QualifiedRuntime: Equatable, Sendable {
    public let runtime: CompatibilityTuple
    public let schema: SafariHistorySchema

    public init(runtime: CompatibilityTuple, schema: SafariHistorySchema) {
        self.runtime = runtime
        self.schema = schema
    }
}

public enum CompatibilityGate {
    // Add independently qualified entries; do not replace older supported runtimes.
    // Historical observations alone are not current-release qualification.
    public static let qualifiedRuntimes: [QualifiedRuntime] = [
        QualifiedRuntime(
            runtime: CompatibilityTuple(
                macOSVersion: "27.0.0",
                macOSBuild: "26A428",
                safariBuild: "22625.1.29.11.27",
                historyServiceSHA256: "ab218c41abc06292969090580be6a3efa7e212595590df6e1e1328bfdec30b9a"
            ),
            schema: .historyV1
        ),
    ]

    public static func verify() throws -> QualifiedRuntime {
        try verify(detect(), against: qualifiedRuntimes)
    }

    public static func verify(
        _ detected: CompatibilityTuple,
        against registry: [QualifiedRuntime]
    ) throws -> QualifiedRuntime {
        let matches = registry.filter { $0.runtime == detected }
        guard matches.count == 1, let match = matches.first else {
            throw SafariHistoryError.incompatibleSchema(
                "unqualified or ambiguous runtime: \(detected.macOSVersion)/\(detected.macOSBuild)/\(detected.safariBuild)"
            )
        }
        return match
    }

    public static func detect() throws -> CompatibilityTuple {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let safariInfo = NSDictionary(contentsOfFile: "/Applications/Safari.app/Contents/Info.plist")
        guard let safariBuild = safariInfo?["CFBundleVersion"] as? String else {
            throw SafariHistoryError.databaseUnavailable("Safari Info.plist")
        }
        let historyService = URL(fileURLWithPath: "/System/Cryptexes/App/usr/libexec/com.apple.Safari.History")
        let serviceData = try Data(contentsOf: historyService, options: .mappedIfSafe)
        return CompatibilityTuple(
            macOSVersion: "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)",
            macOSBuild: try systemString(name: "kern.osversion"),
            safariBuild: safariBuild,
            historyServiceSHA256: SHA256.hash(data: serviceData).map { String(format: "%02x", $0) }.joined()
        )
    }

    private static func systemString(name: String) throws -> String {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0 else {
            throw SafariHistoryError.databaseUnavailable(name)
        }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &bytes, &size, nil, 0) == 0 else {
            throw SafariHistoryError.databaseUnavailable(name)
        }
        return String(
            decoding: bytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) },
            as: UTF8.self
        )
    }
}
