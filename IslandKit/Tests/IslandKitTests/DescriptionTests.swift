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

struct Flusher: IslandPlugin {
    static let id = "flusher"
    static let name = "Flusher"
    static let symbol = "arrow.triangle.2.circlepath"
    static let needsAdmin = true

    @State var result = ""

    var body: some IslandContent {
        Row(result.isEmpty ? "Idle" : result)
        Button("Flush") {
            Task { @MainActor in
                let answer = await Island.sudo("dscacheutil", ["-flushcache"])
                result = answer.succeeded ? "flushed" : answer.error
            }
        }
    }
}

@MainActor
final class AdminTests: XCTestCase {
    func testAPluginThatNeedsAdminSaysSoAndNeedsProtocolEight() {
        let description = PluginDescription(of: Flusher.self)
        XCTAssertEqual(description.needs, ["admin"])
        XCTAssertEqual(description.protocol, 8)
        XCTAssertNil(PluginDescription(of: Counter.self).needs)
    }

    func testSudoGoesToTheIslandAndTheAnswerComesBack() async {
        var lines: [String] = []
        let runtime = IslandRuntime(plugin: Flusher(), environment: ["ISLAND_PROTOCOL": "8"]) { lines.append(String(decoding: $0, as: UTF8.self)) }
        runtime.start()
        runtime.handle(#"{"type":"action","id":"button-0-Flush"}"#)
        // The button's Task sends the request on the next turn, under an id of its own
        try? await Task.sleep(for: .milliseconds(50))
        let request = lines.last { $0.contains(#""type":"sudo""#) }
        XCTAssertEqual(request, #"{"command":["dscacheutil","-flushcache"],"id":"sudo-1","timeout":60,"type":"sudo"}"# + "\n")
        runtime.handle(#"{"type":"sudo","id":"sudo-1","status":0,"output":"","error":""}"#)
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(lines.last?.contains("flushed") == true, "\(lines.last ?? "")")
    }

    func testAnOlderIslandRefusesWithoutAsking() async {
        var lines: [String] = []
        let runtime = IslandRuntime(plugin: Flusher(), environment: ["ISLAND_PROTOCOL": "7"]) { lines.append(String(decoding: $0, as: UTF8.self)) }
        runtime.start()
        runtime.handle(#"{"type":"action","id":"button-0-Flush"}"#)
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertFalse(lines.contains { $0.contains(#""type":"sudo""#) })
        XCTAssertTrue(lines.last?.contains("needs protocol 8") == true, "\(lines.last ?? "")")
    }
}
