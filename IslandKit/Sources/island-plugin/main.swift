import Foundation

// island-plugin: creates, runs, builds and publishes island plugins written with IslandKit

let usage = """
usage: island-plugin <command>

  new <id> [--name <name>] [--symbol <sf symbol>]
                    Create a plugin package in ./<id>
  dev               Build this plugin, install it into the app, and again on every change
  build [--all]     Build this plugin (or every plugin folder here) universal, into build/<id>/ and build/<id>.zip
  validate [--all]  Build and check, without writing build/
  index --repo <owner/name>
                    Rewrite index.json from what build --all made
  publish --repo <owner/name> [--commit]
                    Release new versions on GitHub, update index.json (and commit and push it)
"""

func option(_ name: String, in arguments: [String]) -> String? {
    guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
    return arguments[index + 1]
}

let arguments = Array(CommandLine.arguments.dropFirst())
let here = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)

do {
    switch arguments.first {
    case "new":
        guard arguments.count > 1, !arguments[1].hasPrefix("-") else { throw CLIError("new needs an id\n\n\(usage)") }
        try NewCommand.run(id: arguments[1], name: option("--name", in: arguments), symbol: option("--symbol", in: arguments), in: here)
    case "dev":
        try DevCommand.run(PluginPackage(folder: here))
    case "build", "validate":
        let packages = arguments.contains("--all") ? PluginPackage.all(in: here) : [try PluginPackage(folder: here)]
        guard !packages.isEmpty else { throw CLIError("no plugin folders here") }
        for package in packages {
            if arguments.first == "validate" {
                let manifest = try package.describe(package.build(release: false)).manifest
                let problems = manifest.problems(folderName: package.folder.lastPathComponent)
                guard problems.isEmpty else { throw CLIError("\(package.folder.lastPathComponent): " + problems.joined(separator: "\n")) }
                say("\(manifest.id) \(manifest.version): OK")
            } else {
                let built = try package.assemble(release: true)
                let archive = try package.zip(built.folder)
                say("\(built.manifest.id) \(built.manifest.version): \(archive.path)")
            }
        }
    case "index":
        guard let repo = option("--repo", in: arguments) else { throw CLIError("index needs --repo <owner/name>") }
        say(try PublishCommand.writeIndex(in: here, repo: repo) ? "index.json updated" : "index.json is up to date")
    case "publish":
        guard let repo = option("--repo", in: arguments) else { throw CLIError("publish needs --repo <owner/name>") }
        try PublishCommand.run(in: here, repo: repo, commit: arguments.contains("--commit"))
    case "help", "--help", "-h", nil:
        print(usage)
    default:
        throw CLIError("unknown command \"\(arguments[0])\"\n\n\(usage)")
    }
} catch {
    say("error: \(error)")
    exit(1)
}
