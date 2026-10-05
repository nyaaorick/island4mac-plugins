// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "github-status",
    platforms: [.macOS(.v26)],
    dependencies: [.package(path: "..")],
    targets: [
        .executableTarget(
            name: "github-status",
            dependencies: [.product(name: "IslandKit", package: "island4mac-plugins")],
            path: "Sources"
        ),
    ]
)
