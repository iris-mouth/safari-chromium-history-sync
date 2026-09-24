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

public enum CompatibilityStatus: String, Codable, Sendable {
    case tested
    case compatibleUnverified
}

public struct RuntimeCompatibility: Codable, Equatable, Sendable {
    public let runtime: CompatibilityTuple
    public let status: CompatibilityStatus

    public var summary: String {
        switch status {
        case .tested: "Compatible · tested environment"
        case .compatibleUnverified: "Compatible · not end-to-end tested"
        }
    }
}

public enum CompatibilityGate {
    // Historical reference, not a restriction on other OS/Safari versions.
    public static let referenceRuntime = CompatibilityTuple(
        macOSVersion: "27.0.0", macOSBuild: "26A428", safariBuild: "22625.1.29.11.27",
        historyServiceSHA256: "ab218c41abc06292969090580be6a3efa7e212595590df6e1e1328bfdec30b9a"
    )

    // User-confirmed build-601 evidence: docs/validation/macos-27-build-601.md.
    // This registry changes the evidence label, not runtime eligibility.
    public static let testedRuntimes: [CompatibilityTuple] = [referenceRuntime]

    public static func assess(
        _ detected: CompatibilityTuple,
        testedRuntimes: [CompatibilityTuple] = testedRuntimes
    ) throws -> RuntimeCompatibility {
        let components = detected.macOSVersion.split(separator: ".", omittingEmptySubsequences: false)
        let parts = components.compactMap { Int($0) }
        guard components.count == 3, parts.count == 3, parts.allSatisfy({ $0 >= 0 }),
              !parts.lexicographicallyPrecedes([26, 6, 2]),
              !detected.safariBuild.isEmpty else {
            throw SafariHistoryError.incompatibleSchema("minimum runtime requirements not met")
        }
        // This label must only be exposed after the live schema/state checks pass.
        return RuntimeCompatibility(
            runtime: detected,
            status: testedRuntimes.contains(detected) ? .tested : .compatibleUnverified
        )
    }

    public static func detect() throws -> CompatibilityTuple {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let safariInfo = NSDictionary(contentsOfFile: "/Applications/Safari.app/Contents/Info.plist")
        guard let safariBuild = safariInfo?["CFBundleVersion"] as? String else {
            throw SafariHistoryError.databaseUnavailable("Safari Info.plist")
        }
        let historyService = URL(fileURLWithPath: "/System/Cryptexes/App/usr/libexec/com.apple.Safari.History")
        let serviceData = try? Data(contentsOf: historyService, options: .mappedIfSafe)
        return CompatibilityTuple(
            macOSVersion: "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)",
            macOSBuild: try systemString(name: "kern.osversion"),
            safariBuild: safariBuild,
            historyServiceSHA256: serviceData.map { SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() } ?? "unavailable"
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
