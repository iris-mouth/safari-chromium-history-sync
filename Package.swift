// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SafariHistorySync",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "SafariSyncCore", targets: ["SafariSyncCore"]),
        .executable(name: "SafariSyncAgent", targets: ["SafariSyncAgent"]),
        .executable(name: "SafariSyncBridge", targets: ["SafariSyncBridge"]),
        .executable(name: "SafariSyncMenu", targets: ["SafariSyncMenu"]),
        .executable(name: "SafariSyncViewer", targets: ["SafariSyncViewer"]),
        .executable(name: "SafariSyncCoreIntegrationTests", targets: ["SafariSyncCoreIntegrationTests"]),
        .executable(name: "HistoryBenchmark", targets: ["HistoryBenchmark"]),
    ],
    targets: [
        .systemLibrary(name: "CSQLite"),
        .systemLibrary(name: "CUnicode"),
        .target(name: "HistoryViewCore", dependencies: ["CSQLite", "CUnicode"]),
        .target(name: "SafariSyncCore", dependencies: ["CSQLite", "HistoryViewCore"]),
        .executableTarget(name: "SafariSyncAgent", dependencies: ["SafariSyncCore"]),
        .executableTarget(name: "SafariSyncBridge", dependencies: ["SafariSyncCore"]),
        .executableTarget(name: "SafariSyncMenu", dependencies: ["SafariSyncCore"]),
        .executableTarget(name: "SafariSyncViewer", dependencies: ["HistoryViewCore"]),
        .executableTarget(name: "HistoryBenchmark", dependencies: ["SafariSyncCore"], path: "tests/HistoryBenchmark"),
        .executableTarget(
            name: "SafariSyncCoreIntegrationTests",
            dependencies: ["SafariSyncCore", "HistoryViewCore", "CSQLite"],
            path: "Tests/SafariSyncCoreIntegrationTests"
        ),
    ]
)
