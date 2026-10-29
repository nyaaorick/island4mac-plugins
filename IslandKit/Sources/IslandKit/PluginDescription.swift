import Foundation

/// A plugin's plugin.json, made from its code, so the code is the one place it is written down. The program is
/// always `./<id>` in the plugin's folder
struct PluginDescription: Codable, Equatable {
    let id: String
    let name: String
    let symbol: String
    let command: [String]
    /// The oldest protocol version with everything the plugin uses, so it runs on as many versions of the app
    /// as it can
    let `protocol`: Int
    let version: String
    var description: String?
    /// Settings the island draws for it (protocol 2)
    var preferences: [Wire.Preference]?
    /// Only written when it runs on demand (protocol 3)
    var lifecycle: Lifecycle?
    /// Only written when true (protocol 4)
    var background: Bool?
    /// Only written when high (protocol 4)
    var priority: NotchPriority?
    /// ["files"] when it takes drops (protocol 5)
    var accepts: [String]?

    @MainActor
    init<Plugin: IslandPlugin>(of plugin: Plugin.Type) {
        id = Plugin.id
        name = Plugin.name
        symbol = Plugin.symbol
        command = ["./\(Plugin.id)"]
        version = Plugin.version
        description = Plugin.description
        let declared = Plugin().preferenceStorages.map { $0.storage.describe(key: $0.key) }
        preferences = declared.isEmpty ? nil : declared
        lifecycle = Plugin.lifecycle == .onDemand ? .onDemand : nil
        background = Plugin.background ? true : nil
        priority = Plugin.priority == .high ? .high : nil
        accepts = Plugin.acceptsDrops ? ["files"] : nil
        // Images, row actions, cards, states, sections and toggles need no newer app: an older one leaves them out or
        // shows rows. Media shows only on 5, so a body with it needs 5
        var needed = declared.isEmpty ? 1 : 2
        if lifecycle != nil { needed = max(needed, 3) }
        if background != nil || priority != nil { needed = max(needed, 4) }
        if accepts != nil || Self.bodyShowsMedia(of: plugin) { needed = max(needed, 5) }
        `protocol` = needed
    }

    /// Renders `body` once, as it is before the island says anything, to see whether it shows a Media. A body
    /// that shows one only later (once a track plays) declares `static let protocol = 5`... or sends nothing to
    /// an older island, which is the same for the user
    @MainActor
    private static func bodyShowsMedia<Plugin: IslandPlugin>(of plugin: Plugin.Type) -> Bool {
        let collector = Collector()
        plugin.init().body._collect(into: collector)
        return collector.media != nil
    }

    var json: Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = (try? encoder.encode(self)) ?? Data()
        data.append(UInt8(ascii: "\n"))
        return data
    }
}
