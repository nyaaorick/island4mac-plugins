import Foundation

/// `island-plugin new <id>`: a plugin package that builds and runs as it is
enum NewCommand {
    static func run(id: String, name: String?, symbol: String?, in root: URL) throws {
        let folder = root.appendingPathComponent(id, isDirectory: true)
        guard !folder.exists else { throw CLIError("\(folder.path) already exists") }
        let typeName = id.split(whereSeparator: { $0 == "-" || $0 == "_" }).map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined()
        let manifest = Manifest(id: id, name: name ?? typeName, symbol: symbol ?? "puzzlepiece.extension", command: [], protocol: 1, version: "1.0.0")
        let problems = manifest.problems(folderName: nil)
        guard problems.isEmpty else { throw CLIError(problems.joined(separator: "\n")) }

        // Inside the plugins repo, depend on IslandKit there; anywhere else, on its releases
        let rootPackage = (try? String(contentsOf: root.appendingPathComponent("Package.swift"), encoding: .utf8)) ?? ""
        let dependency = rootPackage.contains("\"IslandKit\"")
            ? #".package(path: "..")"#
            : #".package(url: "https://github.com/nyaaorick/island4mac-plugins", from: "1.0.0")"#

        try FileManager.default.createDirectory(at: folder.appendingPathComponent("Sources"), withIntermediateDirectories: true)
        try """
        // swift-tools-version: 6.2
        import PackageDescription

        let package = Package(
            name: "\(id)",
            platforms: [.macOS(.v26)],
            dependencies: [\(dependency)],
            targets: [
                .executableTarget(
                    name: "\(id)",
                    dependencies: [.product(name: "IslandKit", package: "island4mac-plugins")],
                    path: "Sources"
                ),
            ]
        )

        """.write(to: folder.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        try """
        import Foundation
        import IslandKit

        @main
        struct \(typeName): IslandPlugin {
            static let id = "\(id)"
            static let name = "\(manifest.name)"
            static let symbol = "\(manifest.symbol)"
            static let version = "1.0.0"
            static let description: String? = "What it does, in one line"

            @State var taps = 0

            var body: some IslandContent {
                if taps > 0 {
                    Compact(symbol: Self.symbol, text: "\\(taps)")
                }
                Row("Tapped \\(taps) times", symbol: "hand.tap") { taps += 1 }
                Button("Reset", symbol: "arrow.counterclockwise") { taps = 0 }
            }
        }

        """.write(to: folder.appendingPathComponent("Sources/\(typeName).swift"), atomically: true, encoding: .utf8)
        try ".build/\nbuild/\n".write(to: folder.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
        say("Created \(folder.path)")
        say("Next: cd \(id) && island-plugin dev")
    }
}
