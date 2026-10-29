import XCTest
@testable import IslandKit

/// States and details: a plugin says what a row is up to, and the island draws it
struct Build: IslandPlugin {
    static let id = "build"
    static let name = "Build"
    static let symbol = "hammer"

    @State var failed = false

    var body: some IslandContent {
        Compact(symbol: "hammer", text: "1:23", state: failed ? .failed : .working)
        Row("Tests", subtitle: failed ? "3 failed\nRun again" : "Running\nmake test", symbol: "testtube.2",
            state: failed ? .failed : .working, detail: failed ? "2m" : "1:23", id: "tests") { failed.toggle() }
        Row("Lint", subtitle: "Clean", state: .done)
        Card("Report", subtitle: "Needs you", preview: .text("2 warnings"), state: .attention)
    }
}

@MainActor
final class ProtocolSixTests: XCTestCase {
    private func run<Plugin: IslandPlugin>(_ plugin: Plugin) -> (IslandRuntime, () -> [String]) {
        var lines: [String] = []
        let runtime = IslandRuntime(plugin: plugin, environment: ["ISLAND_PROTOCOL": "6"]) {
            lines.append(String(decoding: $0, as: UTF8.self))
        }
        runtime.start()
        return (runtime, { defer { lines = [] }; return lines })
    }

    func testStatesAndDetailsGoOnTheWire() throws {
        let (runtime, output) = run(Build())
        let first = output()
        let compact = try XCTUnwrap(first.first { $0.contains(#""type":"compact""#) })
        XCTAssertTrue(compact.contains(#""state":"working""#), compact)
        let list = try XCTUnwrap(first.first { $0.contains(#""type":"list""#) })
        XCTAssertTrue(list.contains(#""detail":"1:23""#), list)
        XCTAssertTrue(list.contains(#""state":"working""#), list)
        XCTAssertTrue(list.contains(#""title":"Lint""#) && list.contains(#""state":"done""#), list)
        XCTAssertFalse(list.contains(#""detail":null"#), "a row without a detail leaves it out: \(list)")
        let cards = try XCTUnwrap(first.first { $0.contains(#""type":"cards""#) })
        XCTAssertTrue(cards.contains(#""state":"attention""#), cards)

        runtime.handle(#"{"type":"action","id":"tests"}"#)
        let after = output()
        XCTAssertTrue(after.contains { $0.contains(#""state":"failed""#) && $0.contains(#""detail":"2m""#) }, "\(after)")
    }

    func testStatesNeedNoNewerApp() {
        // An older island leaves the state out and shows the row as it is, so the plugin runs on any version
        XCTAssertEqual(PluginDescription(of: Build.self).protocol, 1)
    }
}
