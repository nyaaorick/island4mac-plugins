// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "notes",
    platforms: [.macOS(.v26)],
    dependencies: [.package(path: "..")],
    targets: [
        .executableTarget(
            name: "notes",
            dependencies: [.product(name: "IslandKit", package: "island4mac-plugins")],
            path: "Sources"
        ),
    ]
)
