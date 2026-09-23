import Foundation

public enum LegacyWriterDetector {
    public static let hostName = "com.local.safari_bookmark_sync"

    public static func detect(
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> [String] {
        var artifacts: [String] = []
        let hostDirectories = [
            "Library/Application Support/Google/Chrome/NativeMessagingHosts",
            "Library/Application Support/Google/Chrome Beta/NativeMessagingHosts",
            "Library/Application Support/Google/Chrome Canary/NativeMessagingHosts",
            "Library/Application Support/Chromium/NativeMessagingHosts",
            "Library/Application Support/BraveSoftware/Brave-Browser/NativeMessagingHosts",
            "Library/Application Support/Microsoft Edge/NativeMessagingHosts",
            "Library/Application Support/Arc/User Data/NativeMessagingHosts",
            "Library/Application Support/net.imput.helium/NativeMessagingHosts",
        ]
        for directory in hostDirectories {
            let url = home.appendingPathComponent(directory)
                .appendingPathComponent("\(hostName).json")
            if FileManager.default.fileExists(atPath: url.path) { artifacts.append(url.path) }
        }

        let launchAgents = home.appendingPathComponent("Library/LaunchAgents")
        if let files = try? FileManager.default.contentsOfDirectory(
            at: launchAgents,
            includingPropertiesForKeys: nil
        ) {
            for file in files where file.pathExtension == "plist" {
                let contents = try? String(contentsOf: file, encoding: .utf8)
                if file.lastPathComponent.contains(hostName)
                    || contents?.contains(hostName) == true
                    || contents?.contains("safari_sync.py") == true {
                    artifacts.append(file.path)
                }
            }
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        process.arguments = ["-f", "\(hostName)|safari_sync[.]py"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        if (try? process.run()) != nil {
            process.waitUntilExit()
            if process.terminationStatus == 0 {
                artifacts.append("running process containing \(hostName)")
            }
        }
        return artifacts.sorted()
    }
}
