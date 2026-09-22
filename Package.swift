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
        .executable(name: "SafariSyncCoreIntegrationTests", targets: ["SafariSyncCoreIntegrationTests"]),
    ],
    targets: [
        .systemLibrary(name: "CSQLite"),
        .target(name: "SafariSyncCore", dependencies: ["CSQLite"]),
        .executableTarget(name: "SafariSyncAgent", dependencies: ["SafariSyncCore"]),
        .executableTarget(name: "SafariSyncBridge", dependencies: ["SafariSyncCore"]),
        .executableTarget(name: "SafariSyncMenu", dependencies: ["SafariSyncCore"]),
        .executableTarget(
            name: "SafariSyncCoreIntegrationTests",
            dependencies: ["SafariSyncCore", "CSQLite"],
            path: "Tests/SafariSyncCoreIntegrationTests"
        ),
    ]
)
