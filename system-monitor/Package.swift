// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "system-monitor",
    platforms: [.macOS(.v26)],
    dependencies: [.package(path: "..")],
    targets: [
        .executableTarget(
            name: "system-monitor",
            dependencies: [.product(name: "IslandKit", package: "island4mac-plugins")],
            path: "Sources"
        ),
    ]
)
