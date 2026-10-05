import XCTest
@testable import IslandKit

/// Pictures, row actions and a place beside the notch
struct Inbox: IslandPlugin {
    static let id = "inbox"
    static let name = "Inbox"
    static let symbol = "tray"
    static let background = true
    static let priority = NotchPriority.high

    @State var items = ["a", "b"]
    @State var archived: [String] = []

    var body: some IslandContent {
        Compact(text: "\(items.count)", image: .app("com.apple.mail"))
        for item in items {
            Row(item, image: .file("/tmp/\(item).png"), id: item, actions: [
                RowAction("Archive", symbol: "archivebox") {
                    archived.append(item)
                    items.removeAll { $0 == item }
                },
            ])
        }
    }
}

@MainActor
final class ProtocolFourTests: XCTestCase {
    func testPicturesAndRowActions() throws {
        var lines: [String] = []
        let runtime = IslandRuntime(plugin: Inbox(), environment: [:]) { lines.append(String(decoding: $0, as: UTF8.self)) }
        runtime.start()
        XCTAssertTrue(lines.contains { $0.contains(#""image":{"app":"com.apple.mail"}"#) })
        let list = try XCTUnwrap(lines.first { $0.contains(#""type":"list""#) })
        XCTAssertTrue(list.contains(#"{"actions":[{"id":"b/0-Archive","symbol":"archivebox","title":"Archive"}],"id":"b","image":{"file":"/tmp/b.png"},"title":"b"}"#), list)

        runtime.handle(#"{"type":"action","id":"b/0-Archive"}"#)
        let inbox = runtime.plugin as! Inbox
        XCTAssertEqual(inbox.archived, ["b"], "the action follows its row's own id")
        XCTAssertEqual(inbox.items, ["a"])
    }

    func testBackgroundAndPriorityNeedProtocolFour() throws {
        let description = PluginDescription(of: Inbox.self)
        XCTAssertEqual(description.protocol, 4)
        let json = String(decoding: description.json, as: UTF8.self)
        XCTAssertTrue(json.contains(#""background" : true"#))
        XCTAssertTrue(json.contains(#""priority" : "high""#))
        XCTAssertFalse(String(decoding: PluginDescription(of: Counter.self).json, as: UTF8.self).contains("background"),
                       "left out unless used, so older apps still take the plugin")
    }
}
