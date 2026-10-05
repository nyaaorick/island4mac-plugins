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
        // Images and row actions need no newer app: an older one leaves them out
        if background != nil || priority != nil {
            `protocol` = 4
        } else if lifecycle != nil {
            `protocol` = 3
        } else {
            `protocol` = declared.isEmpty ? 1 : 2
        }
    }

    var json: Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = (try? encoder.encode(self)) ?? Data()
        data.append(UInt8(ascii: "\n"))
        return data
    }
}
