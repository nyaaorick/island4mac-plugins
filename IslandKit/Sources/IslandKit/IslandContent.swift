import Foundation

/// Something a plugin shows: one of the elements (Compact, Countdown, Row, Button, TextField, Alarm), a group of
/// them, or a component of your own. The island draws all of it in its own look
@MainActor
public protocol IslandContent {
    /// Adds this content to a render. Called by IslandKit; you don't call or implement it
    func _collect(into collector: Collector)
}

/// Your own piece of content, built from the elements, like a plugin's `body`
@MainActor
public protocol IslandComponent: IslandContent {
    associatedtype Body: IslandContent
    @IslandBuilder var body: Body { get }
}

extension IslandComponent {
    public func _collect(into collector: Collector) { body._collect(into: collector) }
}

/// Several pieces of content, in order
public struct IslandGroup: IslandContent {
    let parts: [any IslandContent]

    init(_ parts: [any IslandContent]) { self.parts = parts }

    public func _collect(into collector: Collector) {
        for part in parts { part._collect(into: collector) }
    }
}

/// Builds a `body` from elements, `if`, `if let`, `switch` and `for` loops
@resultBuilder
@MainActor
public enum IslandBuilder {
    public static func buildExpression(_ content: some IslandContent) -> IslandGroup { IslandGroup([content]) }
    public static func buildBlock(_ groups: IslandGroup...) -> IslandGroup { IslandGroup(groups.flatMap(\.parts)) }
    public static func buildOptional(_ group: IslandGroup?) -> IslandGroup { group ?? IslandGroup([]) }
    public static func buildEither(first group: IslandGroup) -> IslandGroup { group }
    public static func buildEither(second group: IslandGroup) -> IslandGroup { group }
    public static func buildArray(_ groups: [IslandGroup]) -> IslandGroup { IslandGroup(groups.flatMap(\.parts)) }
    public static func buildLimitedAvailability(_ group: IslandGroup) -> IslandGroup { group }
}

/// What one render of `body` adds up to: the protocol messages, and the closures behind their ids
@MainActor
public final class Collector {
    var compact: Wire.Compact?
    var rows: [Wire.Row] = []
    var buttons: [Wire.Button] = []
    var input: Wire.Input?
    var actions: [String: @MainActor () -> Void] = [:]
    var submits: [String: @MainActor (String) -> Void] = [:]
    var alarms: [Alarm.Entry] = []
    var warnings: [String] = []

    init() {}

    func setCompact(_ compact: Wire.Compact) {
        if self.compact != nil { warnings.append("more than one Compact or Countdown; the last one shows") }
        self.compact = compact
    }

    func addRow(_ row: Wire.Row, action: (@MainActor () -> Void)?, actions rowActions: [RowAction] = []) {
        guard rows.count < Wire.maxItems else {
            warnings.append("more than \(Wire.maxItems) rows; the rest are dropped")
            return
        }
        var row = row
        let id = row.id ?? Self.automaticID("row", index: rows.count, title: row.title)
        if let action {
            row.id = id
            actions[id] = action
        }
        if !rowActions.isEmpty {
            row.actions = rowActions.enumerated().map { index, rowAction in
                // Under the row's own id, so it follows the row when the list changes
                let actionID = "\(id)/\(index)-\(rowAction.title.prefix(40))"
                actions[actionID] = rowAction.perform
                return Wire.RowAction(id: actionID, title: Wire.cut(rowAction.title), symbol: rowAction.symbol)
            }
        }
        rows.append(row)
    }

    func addButton(_ button: Wire.Button, explicitID: Bool, action: @escaping @MainActor () -> Void) {
        guard buttons.count < Wire.maxItems else {
            warnings.append("more than \(Wire.maxItems) buttons; the rest are dropped")
            return
        }
        var button = button
        if !explicitID { button.id = Self.automaticID("button", index: buttons.count, title: button.title) }
        actions[button.id] = action
        buttons.append(button)
    }

    func setInput(_ input: Wire.Input, onSubmit: @escaping @MainActor (String) -> Void) {
        guard self.input == nil else {
            warnings.append("more than one TextField; only the first shows")
            return
        }
        self.input = input
        submits[input.id] = onSubmit
    }

    func addAlarm(_ entry: Alarm.Entry) {
        alarms.append(entry)
    }

    /// An id from the element's place and title, so a tap that arrives after the list changed under it finds
    /// nothing rather than the wrong closure
    static func automaticID(_ kind: String, index: Int, title: String) -> String {
        "\(kind)-\(index)-\(title.prefix(40))"
    }
}
