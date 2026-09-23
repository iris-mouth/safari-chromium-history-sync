import AppKit
import Foundation
import SafariSyncCore

enum SupportedBrowser: String, CaseIterable, Hashable {
    case chrome
    case edge

    var displayName: String {
        switch self {
        case .chrome: "Google Chrome"
        case .edge: "Microsoft Edge"
        }
    }

    var bundleIdentifier: String {
        switch self {
        case .chrome: "com.google.Chrome"
        case .edge: "com.microsoft.edgemac"
        }
    }

    var nativeMessagingDirectory: URL {
        let suffix = switch self {
        case .chrome: "Library/Application Support/Google/Chrome/NativeMessagingHosts"
        case .edge: "Library/Application Support/Microsoft Edge/NativeMessagingHosts"
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(suffix)
    }
}

struct SetupState {
    let selectedBrowsers: Set<SupportedBrowser>
    let legacyArtifacts: [String]
    let extensionDirectory: URL?
}

struct SetupCoordinator {
    static let hostName = ProductIdentity.nativeMessagingHost
    private static let bridgeSuffix = "/Safari Chromium History Sync.app/Contents/MacOS/SafariSyncBridge"

    func availableBrowsers() -> [SupportedBrowser] {
        SupportedBrowser.allCases.filter {
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0.bundleIdentifier) != nil
        }
    }

    func inspect() -> SetupState {
        SetupState(
            selectedBrowsers: Set(SupportedBrowser.allCases.filter { browser in
                NativeMessagingManifestStore.ownsManifest(
                    target: target(for: browser),
                    hostName: Self.hostName,
                    bridgeSuffix: Self.bridgeSuffix
                )
            }),
            legacyArtifacts: LegacyWriterDetector.detect(),
            extensionDirectory: bundledExtensionDirectory()
        )
    }

    func reconcile(selectedBrowsers: Set<SupportedBrowser>) throws -> SetupState {
        let legacy = LegacyWriterDetector.detect()
        guard legacy.isEmpty else { return inspect() }
        guard let extensionDirectory = bundledExtensionDirectory() else {
            throw SetupError.extensionMissing
        }
        let extensionID = try extensionID(in: extensionDirectory)
        let bridgeURL = Bundle.main.bundleURL
            .appendingPathComponent("Contents/MacOS/SafariSyncBridge")
        let agentURL = Bundle.main.bundleURL.deletingLastPathComponent()
            .appendingPathComponent(ProductIdentity.agentBundleName, isDirectory: true)
        guard FileManager.default.isExecutableFile(atPath: bridgeURL.path) else {
            throw SetupError.bridgeMissing
        }
        guard FileManager.default.isExecutableFile(
            atPath: agentURL.appendingPathComponent("Contents/MacOS/SafariSyncAgent").path
        ) else { throw SetupError.agentMissing }
        try verifyInstalledBundles(agentURL: agentURL)

        try NativeMessagingManifestStore.reconcile(
            targets: SupportedBrowser.allCases.map(target(for:)),
            selectedTargetIDs: Set(selectedBrowsers.map(\.rawValue)),
            hostName: Self.hostName,
            bridgeURL: bridgeURL,
            extensionID: extensionID,
            bridgeSuffix: Self.bridgeSuffix
        )
        return SetupState(
            selectedBrowsers: selectedBrowsers,
            legacyArtifacts: [],
            extensionDirectory: extensionDirectory
        )
    }

    func openExtensionsPage(for browser: SupportedBrowser) {
        guard let appURL = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: browser.bundleIdentifier
        ) else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.arguments = ["chrome://extensions/"]
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: appURL, configuration: configuration)
    }

    private func bundledExtensionDirectory() -> URL? {
        guard let resources = Bundle.main.resourceURL else { return nil }
        let url = resources.appendingPathComponent("ChromiumExtension", isDirectory: true)
        return FileManager.default.fileExists(atPath: url.appendingPathComponent("manifest.json").path)
            ? url
            : nil
    }

    private func target(for browser: SupportedBrowser) -> NativeMessagingTarget {
        NativeMessagingTarget(id: browser.rawValue, directory: browser.nativeMessagingDirectory)
    }

    private func extensionID(in directory: URL) throws -> String {
        let data = try Data(contentsOf: directory.appendingPathComponent("manifest.json"))
        let manifest = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let encodedKey = manifest?["key"] as? String,
              let keyData = Data(base64Encoded: encodedKey) else {
            throw SetupError.extensionKeyMissing
        }
        return NativeMessagingManifestStore.extensionID(publicKey: keyData)
    }

    private func verifyInstalledBundles(agentURL: URL) throws {
        let menuVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        let agentInfo = NSDictionary(contentsOf: agentURL.appendingPathComponent("Contents/Info.plist"))
        guard let menuVersion,
              agentInfo?["CFBundleVersion"] as? String == menuVersion else {
            throw SetupError.bundleVersionMismatch
        }
        for bundleURL in [Bundle.main.bundleURL, agentURL] {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
            process.arguments = ["--verify", "--deep", "--strict", bundleURL.path]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw SetupError.invalidBundleSignature }
        }
    }

}

enum SetupError: LocalizedError {
    case bridgeMissing
    case agentMissing
    case extensionMissing
    case extensionKeyMissing
    case bundleVersionMismatch
    case invalidBundleSignature

    var errorDescription: String? {
        switch self {
        case .bridgeMissing: "The Native Messaging bridge is missing from the installed app."
        case .agentMissing: "\(ProductIdentity.agentBundleName) is missing beside the Menu app."
        case .extensionMissing: "The bundled Chromium extension is missing."
        case .extensionKeyMissing: "The bundled Chromium extension has no stable public key."
        case .bundleVersionMismatch: "The Menu and Agent app versions do not match. Reinstall the package."
        case .invalidBundleSignature: "An installed app failed signature verification. Reinstall the package."
        }
    }
}
