import Foundation

/// `island-plugin dev`: builds the plugin, installs it into the app's plugins folder, and does both again
/// whenever a source file changes. The app restarts a plugin whose program changed
enum DevCommand {
    static let pluginsFolder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("MacDynamicIsland/Plugins", isDirectory: true)

    static func run(_ package: PluginPackage) throws -> Never {
        var installedOnce = false
        var snapshot = sourceSnapshot(package.folder)
        func rebuild() {
            do {
                let built = try package.assemble(release: false)
                let target = try install(built.folder, id: built.manifest.id)
                say("Installed \(built.manifest.name) \(built.manifest.version) in \(target.path)")
                if !installedOnce {
                    say("Turn its tab on in the app under Settings > Tabs. Watching for changes (Ctrl-C to stop)...")
                    installedOnce = true
                }
            } catch {
                say("error: \(error)")
            }
        }
        rebuild()
        while true {
            Thread.sleep(forTimeInterval: 0.5)
            let now = sourceSnapshot(package.folder)
            guard now != snapshot else { continue }
            snapshot = now
            say("Changed; rebuilding...")
            rebuild()
        }
    }

    /// Copies the built plugin into the plugins folder. The program is swapped in whole, by rename, so the app
    /// never runs a half-written one; plugin.json is only written when it changed
    static func install(_ built: URL, id: String) throws -> URL {
        let target = pluginsFolder.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let manifest = try Data(contentsOf: built.appendingPathComponent("plugin.json"))
        let manifestTarget = target.appendingPathComponent("plugin.json")
        if (try? Data(contentsOf: manifestTarget)) != manifest {
            try manifest.write(to: manifestTarget, options: .atomic)
        }
        let staging = target.appendingPathComponent(".\(id).installing")
        try? FileManager.default.removeItem(at: staging)
        try FileManager.default.copyItem(at: built.appendingPathComponent(id), to: staging)
        guard rename(staging.path, target.appendingPathComponent(id).path) == 0 else {
            throw CLIError("couldn't install the program: \(String(cString: strerror(errno)))")
        }
        return target
    }

    /// Modification dates of Package.swift and everything under Sources/
    static func sourceSnapshot(_ folder: URL) -> [String: Date] {
        var snapshot: [String: Date] = [:]
        let manifest = folder.appendingPathComponent("Package.swift")
        snapshot[manifest.path] = modified(manifest)
        let enumerator = FileManager.default.enumerator(at: folder.appendingPathComponent("Sources"),
                                                        includingPropertiesForKeys: [.contentModificationDateKey])
        while let file = enumerator?.nextObject() as? URL {
            snapshot[file.path] = modified(file)
        }
        return snapshot
    }

    private static func modified(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }
}
