// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "InstaSync",
    platforms: [.macOS(.v14)],
    targets: [
        // Pure logic (handles, phone numbers, matching, cleanup rules, data files). Unit-tested.
        .target(name: "InstaSyncCore", swiftSettings: [.swiftLanguageMode(.v5)]),
        // The app: SwiftUI, Contacts, the in-app Instagram browser, jobs.
        .executableTarget(
            name: "InstaSync",
            dependencies: ["InstaSyncCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "InstaSyncCoreTests",
            dependencies: ["InstaSyncCore"],
            resources: [.copy("golden.json")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
