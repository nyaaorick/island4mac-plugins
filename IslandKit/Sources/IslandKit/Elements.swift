import Foundation

/// Shown beside the notch while the island is collapsed: a symbol, a short text and an optional ring
/// (`progress`, 0 to 1). Only one shows; the last one in `body` wins
public struct Compact: IslandContent {
    let symbol: String?
    let text: String?
    let progress: Double?
    let image: IslandImage?

    /// - Parameter image: Shown in place of the symbol (an album cover, an avatar)
    public init(symbol: String? = nil, text: String? = nil, progress: Double? = nil, image: IslandImage? = nil) {
        self.symbol = symbol
        self.text = text
        self.progress = progress
        self.image = image
    }

    public func _collect(into collector: Collector) {
        collector.setCompact(Wire.Compact(symbol: symbol, text: Wire.cut(text), progress: progress.map { min(max($0, 0), 1) },
                                          image: image?.wire))
    }
}

/// A picture on a row or beside the notch. Say where it comes from; the island sizes, crops and caches it
public enum IslandImage: Equatable, Sendable {
    /// A thumbnail of a file, made by the island
    case file(String)
    /// An app's icon, by its bundle id
    case app(String)
    /// A picture on the web (https only, up to 5 MB)
    case url(String)

    var wire: Wire.Image {
        switch self {
        case .file(let path): return Wire.Image(file: path)
        case .app(let bundleID): return Wire.Image(app: bundleID)
        case .url(let url): return Wire.Image(url: url)
        }
    }
}

/// A row's secondary action: shown when the pointer is over the row, and in its context menu
public struct RowAction {
    let title: String
    let symbol: String?
    let perform: @MainActor () -> Void

    public init(_ title: String, symbol: String? = nil, perform: @escaping @MainActor () -> Void) {
        self.title = title
        self.symbol = symbol
        self.perform = perform
    }
}

/// A countdown beside the notch that the island runs itself, so the plugin needn't update every second. With
/// `total` (seconds) the ring shows the share left. Takes the place of a Compact
public struct Countdown: IslandContent {
    let end: Date
    let total: TimeInterval?
    let symbol: String?

    public init(to end: Date, total: TimeInterval? = nil, symbol: String? = nil) {
        self.end = end
        self.total = total
        self.symbol = symbol
    }

    public func _collect(into collector: Collector) {
        collector.setCompact(Wire.Compact(symbol: symbol, until: end.timeIntervalSince1970, total: total.flatMap { $0 > 0 ? $0 : nil }))
    }
}

/// A row in the plugin's tab. With an action it can be tapped. Up to 50 rows show
public struct Row: IslandContent {
    let title: String
    let subtitle: String?
    let symbol: String?
    let image: IslandImage?
    let id: String?
    let actions: [RowAction]
    let action: (@MainActor () -> Void)?

    /// - Parameters:
    ///   - subtitle: Up to 3 lines show
    ///   - image: Shown in place of the symbol (a thumbnail, an app icon)
    ///   - id: Give rows made in a loop an id of their own (e.g. the item's), so a tap always reaches the row
    ///     that was tapped even when the list changes
    ///   - actions: Secondary actions, such as Delete or Archive (up to 4)
    public init(_ title: String, subtitle: String? = nil, symbol: String? = nil, image: IslandImage? = nil, id: String? = nil,
                actions: [RowAction] = [], action: (@MainActor () -> Void)? = nil) {
        self.title = title
        self.subtitle = subtitle
        self.symbol = symbol
        self.image = image
        self.id = id
        self.actions = actions
        self.action = action
    }

    public func _collect(into collector: Collector) {
        collector.addRow(Wire.Row(id: id, title: Wire.cut(title), subtitle: subtitle.map { String($0.prefix(Wire.maxSubtitleLength)) },
                                  symbol: symbol, image: image?.wire),
                         action: action, actions: Array(actions.prefix(Wire.maxRowActions)))
    }
}

/// A button under the rows. With `confirm`, the island asks that question first and runs the action only on yes
public struct Button: IslandContent {
    let title: String
    let symbol: String?
    let confirm: String?
    let id: String?
    let action: @MainActor () -> Void

    public init(_ title: String, symbol: String? = nil, confirm: String? = nil, id: String? = nil,
                action: @escaping @MainActor () -> Void) {
        self.title = title
        self.symbol = symbol
        self.confirm = confirm
        self.id = id
        self.action = action
    }

    public func _collect(into collector: Collector) {
        collector.addButton(Wire.Button(id: id ?? "", title: Wire.cut(title), symbol: symbol, confirm: Wire.cut(confirm)),
                            explicitID: id != nil, action: action)
    }
}

/// The tab's one text field, above its buttons. Return hands its text to `onSubmit`
public struct TextField: IslandContent {
    let placeholder: String
    let text: String?
    let id: String
    let onSubmit: @MainActor (String) -> Void

    /// - Parameter text: What it starts with
    public init(_ placeholder: String, text: String? = nil, id: String = "input",
                onSubmit: @escaping @MainActor (String) -> Void) {
        self.placeholder = placeholder
        self.text = text
        self.id = id
        self.onSubmit = onSubmit
    }

    public func _collect(into collector: Collector) {
        collector.setInput(Wire.Input(id: id, placeholder: Wire.cut(placeholder), text: text.map { String($0.prefix(Wire.maxInputLength)) }),
                           onSubmit: onSubmit)
    }
}

/// Runs `perform` once when `date` comes, while it is still in `body`. Shows nothing. Take it out of `body`
/// (or change its date) to call it off
public struct Alarm: IslandContent {
    let date: Date
    let id: String?
    let perform: @MainActor () -> Void

    public init(at date: Date, id: String? = nil, perform: @escaping @MainActor () -> Void) {
        self.date = date
        self.id = id
        self.perform = perform
    }

    struct Entry {
        /// Its id and date together: the same alarm moved to another date is a new one
        let key: String
        let date: Date
        let perform: @MainActor () -> Void
    }

    public func _collect(into collector: Collector) {
        let name = id ?? "alarm-\(collector.alarms.count)"
        collector.addAlarm(Entry(key: "\(name)@\(date.timeIntervalSince1970)", date: date, perform: perform))
    }
}
