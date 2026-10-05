import Foundation

/// `index.json` in the plugins repo, and publishing what `build --all` made: a GitHub release per new version,
/// then the index pointing at it
enum PublishCommand {
    struct Entry: Codable, Equatable {
        let id: String
        let name: String
        let symbol: String
        let version: String
        let `protocol`: Int
        var description: String?
        let archive: String
    }

    struct Index: Codable {
        var plugins: [Entry]
    }

    /// The built plugins under `root`: each one's plugin.json and zip
    static func built(in root: URL) throws -> [(manifest: Manifest, archive: URL)] {
        try PluginPackage.all(in: root).compactMap { package in
            let id = package.folder.lastPathComponent
            let manifestFile = package.folder.appendingPathComponent("build/\(id)/plugin.json")
            let archive = package.folder.appendingPathComponent("build/\(id).zip")
            guard manifestFile.exists, archive.exists else {
                say("\(id): not built; run island-plugin build --all first. Skipped")
                return nil
            }
            return (try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: manifestFile)), archive)
        }
    }

    static func tag(_ manifest: Manifest) -> String { "\(manifest.id)-\(manifest.version)" }

    /// Rewrites index.json from what is built; returns whether it changed
    @discardableResult
    static func writeIndex(in root: URL, repo: String) throws -> Bool {
        let file = root.appendingPathComponent("index.json")
        let old = try? Data(contentsOf: file)
        var index = old.flatMap { try? JSONDecoder().decode(Index.self, from: $0) } ?? Index(plugins: [])
        for (manifest, archive) in try built(in: root) {
            let entry = Entry(id: manifest.id, name: manifest.name, symbol: manifest.symbol, version: manifest.version,
                              protocol: manifest.protocol, description: manifest.description,
                              archive: "https://github.com/\(repo)/releases/download/\(tag(manifest))/\(archive.lastPathComponent)")
            index.plugins.removeAll { $0.id == entry.id }
            index.plugins.append(entry)
        }
        index.plugins.sort { $0.id < $1.id }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(index)
        data.append(UInt8(ascii: "\n"))
        guard data != old else { return false }
        try data.write(to: file, options: .atomic)
        return true
    }

    /// Releases every built version that has no release yet, then updates index.json, and with `commit`
    /// commits and pushes it. Needs `gh`, signed in (GH_TOKEN in CI)
    static func run(in root: URL, repo: String, commit: Bool) throws {
        for (manifest, archive) in try built(in: root) {
            let tag = tag(manifest)
            if try island_plugin.run("gh", ["release", "view", tag, "--repo", repo], capture: true).status == 0 {
                say("\(tag): already released")
                continue
            }
            try check("gh", ["release", "create", tag, archive.path, "--repo", repo,
                             "--title", "\(manifest.name) \(manifest.version)", "--notes", manifest.description ?? ""],
                      "Releasing \(tag)")
            say("\(tag): released")
        }
        guard try writeIndex(in: root, repo: repo) else {
            say("index.json is up to date")
            return
        }
        say("index.json updated")
        guard commit else { return }
        try check("git", ["add", "index.json"], in: root, "git add")
        try check("git", ["commit", "-m", "Update index.json"], in: root, "git commit")
        try check("git", ["push"], in: root, "git push")
    }
}
