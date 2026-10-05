import Foundation

/// One plugin's Swift package: builds it, asks the program for its plugin.json, and lays out the plugin folder
/// the app runs (`build/<id>/`: the program as `<id>`, and plugin.json)
struct PluginPackage {
    let folder: URL

    init(folder: URL) throws {
        guard folder.appendingPathComponent("Package.swift").exists else {
            throw CLIError("no Package.swift in \(folder.path); run this in a plugin's folder")
        }
        self.folder = folder
    }

    /// The executable it builds: a declared executable product, or else its executable target
    func productName() throws -> String {
        let json = try check("swift", ["package", "dump-package"], in: folder, capture: true, "Reading Package.swift")
        guard let package = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else {
            throw CLIError("couldn't read Package.swift")
        }
        let products = package["products"] as? [[String: Any]] ?? []
        if let product = products.first(where: { ($0["type"] as? [String: Any])?["executable"] != nil }),
           let name = product["name"] as? String {
            return name
        }
        let targets = package["targets"] as? [[String: Any]] ?? []
        if let target = targets.first(where: { $0["type"] as? String == "executable" }), let name = target["name"] as? String {
            return name
        }
        throw CLIError("Package.swift has no executable target")
    }

    /// Builds the program and returns it. Release builds are universal (arm64 and x86_64)
    func build(release: Bool) throws -> URL {
        let product = try productName()
        let configuration = release ? ["-c", "release", "--arch", "arm64", "--arch", "x86_64"] : []
        try check("swift", ["build", "--product", product] + configuration, in: folder, "Building \(product)")
        let binPath = try check("swift", ["build", "--show-bin-path"] + configuration, in: folder, capture: true, "Finding the build")
        return URL(fileURLWithPath: binPath.trimmingCharacters(in: .whitespacesAndNewlines)).appendingPathComponent(product)
    }

    func describe(_ program: URL) throws -> (manifest: Manifest, json: Data) {
        let output = try check(program.path, ["--describe"], capture: true, "Running \(program.lastPathComponent) --describe")
        let data = Data(output.utf8)
        do {
            return (try JSONDecoder().decode(Manifest.self, from: data), data)
        } catch {
            throw CLIError("\(program.lastPathComponent) --describe didn't print a plugin.json; is it an IslandKit plugin? (\(error))")
        }
    }

    /// Builds and checks it, then writes `build/<id>/`. Returns that folder and its manifest
    @discardableResult
    func assemble(release: Bool) throws -> (folder: URL, manifest: Manifest) {
        let program = try build(release: release)
        let (manifest, json) = try describe(program)
        let problems = manifest.problems(folderName: folder.lastPathComponent)
        guard problems.isEmpty else { throw CLIError(problems.joined(separator: "\n")) }

        let output = folder.appendingPathComponent("build/\(manifest.id)", isDirectory: true)
        try? FileManager.default.removeItem(at: output)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: program, to: output.appendingPathComponent(manifest.id))
        try json.write(to: output.appendingPathComponent("plugin.json"))
        if release {
            try check("codesign", ["-s", "-", "-f", output.appendingPathComponent(manifest.id).path], "Signing")
        }
        return (output, manifest)
    }

    /// `build/<id>.zip`: the plugin folder, as the plugins repo publishes it
    func zip(_ pluginFolder: URL) throws -> URL {
        let archive = pluginFolder.deletingLastPathComponent().appendingPathComponent("\(pluginFolder.lastPathComponent).zip")
        try? FileManager.default.removeItem(at: archive)
        try check("ditto", ["-c", "-k", "--norsrc", "--noextattr", "--keepParent", pluginFolder.path, archive.path], "Zipping")
        return archive
    }

    /// The plugin folders under `root` (each a package of its own), for --all
    static func all(in root: URL) -> [PluginPackage] {
        let folders = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey],
                                                                    options: [.skipsHiddenFiles])) ?? []
        return folders
            .filter { !["build", "IslandKit"].contains($0.lastPathComponent) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { try? PluginPackage(folder: $0) }
    }
}
