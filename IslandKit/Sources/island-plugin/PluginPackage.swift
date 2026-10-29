import Foundation

/// One plugin's package: builds it, asks the program for its plugin.json, and lays out the plugin folder
/// the app runs (`build/<id>/`: the program as `<id>`, and plugin.json). A Swift package (Package.swift, on
/// IslandKit) or a Go module (go.mod, speaking the protocol itself); the program must answer `--describe`
/// with its plugin.json either way
struct PluginPackage {
    enum Kind {
        case swift, go
    }

    let folder: URL
    let kind: Kind

    init(folder: URL) throws {
        if folder.appendingPathComponent("Package.swift").exists {
            kind = .swift
        } else if folder.appendingPathComponent("go.mod").exists {
            kind = .go
        } else {
            throw CLIError("no Package.swift or go.mod in \(folder.path); run this in a plugin's folder")
        }
        self.folder = folder
    }

    /// The executable it builds: a declared executable product, or else its executable target; for a Go module,
    /// the folder's name (`./cmd/<name>` when there is one, else the module's root package)
    func productName() throws -> String {
        switch kind {
        case .go:
            return folder.lastPathComponent
        case .swift:
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
    }

    /// Builds the program and returns it. Release builds are universal (arm64 and x86_64)
    func build(release: Bool) throws -> URL {
        switch kind {
        case .swift: try buildSwift(release: release)
        case .go: try buildGo(release: release)
        }
    }

    private func buildSwift(release: Bool) throws -> URL {
        let product = try productName()
        let configuration = release ? ["-c", "release", "--arch", "arm64", "--arch", "x86_64"] : []
        try check("swift", ["build", "--product", product] + configuration, in: folder, "Building \(product)")
        let binPath = try check("swift", ["build", "--show-bin-path"] + configuration, in: folder, capture: true, "Finding the build")
        return URL(fileURLWithPath: binPath.trimmingCharacters(in: .whitespacesAndNewlines)).appendingPathComponent(product)
    }

    /// `go build` into `.build/`, once per architecture for a release, joined with lipo. The module decides
    /// what the plugin does with its build (its own ldflags belong in its code or a `//go:build` tag, not here)
    private func buildGo(release: Bool) throws -> URL {
        let product = try productName()
        let main = folder.appendingPathComponent("cmd/\(product)").exists ? "./cmd/\(product)" : "."
        let output = folder.appendingPathComponent(".build", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let program = output.appendingPathComponent(product)
        guard release else {
            try check("go", ["build", "-o", program.path, main], in: folder, "Building \(product)")
            return program
        }
        var slices: [URL] = []
        for arch in ["arm64", "amd64"] {
            let slice = output.appendingPathComponent("\(product)-\(arch)")
            try check("env", ["GOOS=darwin", "GOARCH=\(arch)", "CGO_ENABLED=0", "go", "build", "-trimpath", "-ldflags", "-s -w",
                              "-o", slice.path, main],
                      in: folder, "Building \(product) for \(arch)")
            slices.append(slice)
        }
        try check("lipo", ["-create", "-output", program.path] + slices.map(\.path), "Joining the architectures")
        for slice in slices { try? FileManager.default.removeItem(at: slice) }
        return program
    }

    func describe(_ program: URL) throws -> (manifest: Manifest, json: Data) {
        let output = try check(program.path, ["--describe"], capture: true, "Running \(program.lastPathComponent) --describe")
        let data = Data(output.utf8)
        do {
            return (try JSONDecoder().decode(Manifest.self, from: data), data)
        } catch {
            throw CLIError("\(program.lastPathComponent) --describe didn't print a plugin.json; is it an island plugin? (\(error))")
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

    /// The files `dev` watches: Package.swift and Sources/ for a Swift package; everything but builds and git
    /// for a Go module
    func sources() -> [URL] {
        switch kind {
        case .swift:
            return [folder.appendingPathComponent("Package.swift"), folder.appendingPathComponent("Sources", isDirectory: true)]
        case .go:
            let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
            return names.filter { ![".build", "build", ".git", ".DS_Store"].contains($0) }.map { folder.appendingPathComponent($0) }
        }
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
