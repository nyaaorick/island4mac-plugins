import XCTest
@testable import IslandKit

struct MediaOnly: IslandPlugin {
    static let id = "player"
    static let name = "MediaOnly"
    static let symbol = "music.note"

    var body: some IslandContent {
        Media("Song", playing: true)
    }
}

struct Keeper: IslandPlugin {
    static let id = "keeper"
    static let name = "Keeper"
    static let symbol = "clock"

    @Preference("Keep for", options: [(24, "A day"), (168, "A week"), (0, "Forever")]) var hours = 24

    var body: some IslandContent {
        Row("\(hours)")
    }
}

@MainActor
final class DescriptionTests: XCTestCase {
    func testABodyWithMediaNeedsProtocolFive() {
        XCTAssertEqual(PluginDescription(of: MediaOnly.self).protocol, 5, "an older island shows nothing for Media")
        XCTAssertEqual(PluginDescription(of: Counter.self).protocol, 1, "rows, buttons and a text field work everywhere")
    }

    func testLabelledOptionsAreShownByTheirLabel() throws {
        let preferences = try XCTUnwrap(PluginDescription(of: Keeper.self).preferences)
        XCTAssertEqual(preferences[0].kind, "choice")
        XCTAssertEqual(preferences[0].options?.map(\.title), ["A day", "A week", "Forever"])
        XCTAssertEqual(preferences[0].options?.map(\.value), [.number(24), .number(168), .number(0)])
        XCTAssertEqual(preferences[0].default, .number(24))

        var lines: [String] = []
        let runtime = IslandRuntime(plugin: Keeper(), environment: ["ISLAND_PROTOCOL": "7"]) { lines.append(String(decoding: $0, as: UTF8.self)) }
        runtime.start()
        runtime.handle(#"{"type":"preferences","values":{"hours":168}}"#)
        XCTAssertTrue(lines.last?.contains("168") == true, "the value, not the label, reaches the plugin")
    }
}
