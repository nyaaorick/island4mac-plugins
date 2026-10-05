import Foundation

/// A card in the plugin's tab: a row turned on its side, with a large preview. Cards sit in one row above the
/// rows and scroll sideways. With an action it can be tapped; with a `file` it drags out as that file. Up to 50
/// show. Needs app protocol 5; an older app shows them as rows
public struct Card: IslandContent {
    let title: String
    let subtitle: String?
    let symbol: String?
    let image: IslandImage?
    let preview: CardPreview?
    let file: String?
    let id: String?
    let actions: [RowAction]
    let action: (@MainActor () -> Void)?

    /// - Parameters:
    ///   - image: Small, beside the title (an app icon)
    ///   - preview: The large part of the card; without one, the image or symbol shows there
    ///   - file: A file the card stands for: it can be dragged out as that file
    ///   - id: Give cards made in a loop an id of their own (e.g. the item's), so a tap always reaches the card
    ///     that was tapped even when the cards change
    ///   - actions: Secondary actions, such as Delete (up to 4)
    public init(_ title: String, subtitle: String? = nil, symbol: String? = nil, image: IslandImage? = nil,
                preview: CardPreview? = nil, file: String? = nil, id: String? = nil, actions: [RowAction] = [],
                action: (@MainActor () -> Void)? = nil) {
        self.title = title
        self.subtitle = subtitle
        self.symbol = symbol
        self.image = image
        self.preview = preview
        self.file = file
        self.id = id
        self.actions = actions
        self.action = action
    }

    public func _collect(into collector: Collector) {
        collector.addCard(Wire.Card(id: id, title: Wire.cut(title), subtitle: Wire.cut(subtitle), symbol: symbol, image: image?.wire,
                                    preview: preview?.wire, file: file),
                          action: action, actions: Array(actions.prefix(Wire.maxRowActions)))
    }
}

/// What a card shows large
public enum CardPreview: Equatable, Sendable {
    /// A few lines of text
    case text(String)
    /// A picture: a file's thumbnail, an app's icon, or one from the web
    case image(IslandImage)

    var wire: Wire.CardPreview {
        switch self {
        case .text(let text): return Wire.CardPreview(text: String(text.prefix(Wire.maxSubtitleLength)))
        case .image(let image): return Wire.CardPreview(image: image.wire)
        }
    }
}
