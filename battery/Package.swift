// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "battery",
    platforms: [.macOS(.v26)],
    dependencies: [.package(path: "..")],
    targets: [
        .executableTarget(
            name: "battery",
            dependencies: [.product(name: "IslandKit", package: "island4mac-plugins")],
            path: "Sources"
        ),
    ]
)
