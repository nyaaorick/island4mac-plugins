import Foundation

/// What a plugin can ask of the island outside its `body`, and what it can learn about where it runs
@MainActor
public enum Island {
    /// Shows `text` beside the notch for a few seconds (1 to 10; 3 if you don't say), ahead of music
    public static func popup(_ text: String, symbol: String? = nil, seconds: Double? = nil) {
        IslandRuntime.current?.send(.popup(Wire.Popup(symbol: symbol, text: Wire.cut(text), seconds: seconds)))
    }

    /// Opens the island on this plugin's tab. The island allows it at most every 10 seconds, only if the user
    /// lets plugins do it, and never over something they're using.
    /// - Parameter hold: Keeps it open, without closing on its own, until `close()` (something waiting for an
    ///   answer). Needs app protocol 4; older apps open it as usual
    public static func open(hold: Bool = false) {
        IslandRuntime.current?.send(.open(hold: hold))
    }

    /// Closes the island open on this plugin's tab: one `open(hold: true)` kept open closes unless the pointer is
    /// on it; one opened for the user closes at once (after a paste). Needs app protocol 4 (protocol 5 for the second)
    public static func close() {
        IslandRuntime.current?.send(.close)
    }

    /// Shows `body` again on the next turn. @State, @Preference and @Fetched do this by themselves; call it when
    /// something else that `body` reads changes (an object of your own, a server's state)
    public static func refresh() {
        IslandRuntime.current?.setNeedsRender()
    }

    /// Whether the plugin's tab is open on any display. Update often only while it is
    public static var isTabVisible: Bool { IslandRuntime.current?.isTabVisible ?? false }

    /// The time `body` is rendered for. Use it rather than `Date()` in `body`
    public static var now: Date { IslandRuntime.current?.now ?? Date() }

    /// A folder of the plugin's own for anything it keeps; it survives updates. nil outside the island
    public static var dataDirectory: URL? { IslandRuntime.current?.dataDirectory }

    /// Writes to stderr; the island shows the last lines as the reason if the plugin stops
    public static func log(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
}
