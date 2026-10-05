// swift-tools-version: 6.2
import PackageDescription

// IslandKit, the Swift SDK for island plugins, and `island-plugin`, the command line tool that creates, runs,
// builds and publishes them. Each plugin in this repo is its own package in its own folder, depending on this one.
let package = Package(
    name: "island4mac-plugins",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "IslandKit", targets: ["IslandKit"]),
        .executable(name: "island-plugin", targets: ["island-plugin"]),
    ],
    targets: [
        .target(name: "IslandKit", path: "IslandKit/Sources/IslandKit"),
        .executableTarget(name: "island-plugin", path: "IslandKit/Sources/island-plugin"),
        .testTarget(name: "IslandKitTests", dependencies: ["IslandKit"], path: "IslandKit/Tests/IslandKitTests", exclude: ["Fixtures"]),
    ]
)
