import Foundation

/// An island plugin. Say who it is and what it shows; IslandKit runs it, renders `body` after every change and
/// sends the island only what changed.
///
///     @main
///     struct Hello: IslandPlugin {
///         static let id = "hello"
///         static let name = "Hello"
///         static let symbol = "hand.wave"
///
///         @State var taps = 0
///
///         var body: some IslandContent {
///             Compact(symbol: "hand.wave", text: "\(taps)")
///             Button("Wave") { taps += 1 }
///         }
///     }
@MainActor
public protocol IslandPlugin {
    associatedtype Body: IslandContent

    /// Lowercase letters, digits, "-" and "_". Also its folder name, so it can't change once published
    static var id: String { get }
    /// Shown on its tab and in Settings
    static var name: String { get }
    /// SF Symbol for its tab
    static var symbol: String { get }
    /// Compared with the plugins repo's index to offer updates. "1.0.0" if you don't say
    static var version: String { get }
    /// One line for the plugins list in Settings
    static var description: String? { get }
    /// Whether it runs while its tab is on (`.persistent`, the default) or only when needed (`.onDemand`)
    static var lifecycle: Lifecycle { get }
    /// Runs while it's turned on in the app's Settings > Plugins, even when its tab isn't one of the user's
    /// (an agent's status, now playing). Needs app protocol 4
    static var background: Bool { get }
    /// Where its compact content goes beside the notch: `.high` ahead of popups and now playing. Needs app
    /// protocol 4
    static var priority: NotchPriority { get }
    /// Whether you can drop files, text and links on its tab. The island does the dragging part (it opens on the
    /// tab and shows where to drop) and hands over what was dropped, in `onDrop`. Needs app protocol 5
    static var acceptsDrops: Bool { get }

    init()

    @IslandBuilder var body: Body { get }

    /// Called once when the plugin starts in the island (not for `--describe`): start servers, timers or
    /// subscriptions here, and call `Island.refresh()` when what they track changes
    func onStart()

    /// Times when `body` will look different without anything happening (an event starts, a day turns). The
    /// island switches to each one at its time by itself, so an `.onDemand` plugin needn't run for it.
    /// `Island.now` is that time while `body` is rendered for it
    var timeline: [Date] { get }

    /// Something was dropped on its tab (`acceptsDrops`): files and folders as paths, text the island saved as a
    /// file in the plugin's data folder (Drops/), also a path, and links
    func onDrop(paths: [String], urls: [URL])
}

/// Where a plugin's compact content goes beside the notch
public enum NotchPriority: String, Codable, Sendable {
    /// Ahead of popups and now playing: something to see even while music plays
    case high
    /// After now playing
    case normal
}

/// When a plugin runs
public enum Lifecycle: String, Codable, Sendable {
    /// While its tab is on
    case persistent
    /// Only when needed: its tab opens, a row or button is tapped, an Alarm or a @Fetched refresh is due, or a
    /// preference changes. It shows what it has, hands the island its `timeline`, and quits; @State is kept
    /// until next time. Needs app protocol 3; on older apps it runs persistent
    case onDemand
}

extension IslandPlugin {
    public static var version: String { "1.0.0" }
    public static var description: String? { nil }
    public static var lifecycle: Lifecycle { .persistent }
    public static var background: Bool { false }
    public static var priority: NotchPriority { .normal }
    public static var acceptsDrops: Bool { false }
    public func onDrop(paths: [String], urls: [URL]) {}
    public var timeline: [Date] { [] }
    public func onStart() {}

    /// Runs the plugin: reads the island's events on stdin until it closes, and writes what to show on stdout.
    /// With `--describe` it prints its plugin.json instead (island-plugin uses that)
    public static func main() {
        if CommandLine.arguments.dropFirst().contains("--describe") {
            FileHandle.standardOutput.write(PluginDescription(of: Self.self).json)
            exit(0)
        }
        // A closed stdout must not kill us mid-write; we quit when stdin closes instead
        signal(SIGPIPE, SIG_IGN)
        let runtime = IslandRuntime(plugin: Self(), environment: ProcessInfo.processInfo.environment, output: StandardOutput.write)
        runtime.start()
        // Reading blocks, so it gets its own thread. End of input: the island wants us gone
        Thread.detachNewThread {
            while let line = readLine() {
                DispatchQueue.main.async { MainActor.assumeIsolated { IslandRuntime.current?.handle(line) } }
            }
            exit(0)
        }
        RunLoop.main.run()
    }
}

/// stdout is a pipe: every line goes out at once, whole
enum StandardOutput {
    static func write(_ data: Data) {
        data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let written = Darwin.write(1, buffer.baseAddress! + offset, buffer.count - offset)
                if written <= 0 {
                    if written < 0 && errno == EINTR { continue }
                    return
                }
                offset += written
            }
        }
    }
}
