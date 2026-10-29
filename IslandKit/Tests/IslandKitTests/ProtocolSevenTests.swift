import XCTest
@testable import IslandKit

/// Sections, toggles, progress rings and actions that ask first
struct Awake: IslandPlugin {
    static let id = "awake"
    static let name = "Awake"
    static let symbol = "cup.and.saucer"

    @State var isOn = false
    @State var removed = false

    var body: some IslandContent {
        Section("Power", symbol: "bolt", detail: "1")
        Toggle("Keep awake", subtitle: "Until you turn it off", symbol: "cup.and.saucer", isOn: isOn, id: "awake") { isOn = $0 }
        Row("Upgrading", progress: 0.4)
        Row("Container", id: "c1", actions: [
            RowAction("Logs", symbol: "doc") {},
            RowAction("Remove", symbol: "trash", confirm: "Remove the container?") { removed = true },
        ])
    }
}

@MainActor
final class ProtocolSevenTests: XCTestCase {
    private func run<Plugin: IslandPlugin>(_ plugin: Plugin, protocol version: Int) -> (IslandRuntime, () -> [String]) {
        var lines: [String] = []
        let runtime = IslandRuntime(plugin: plugin, environment: ["ISLAND_PROTOCOL": "\(version)"]) {
            lines.append(String(decoding: $0, as: UTF8.self))
        }
        runtime.start()
        return (runtime, { defer { lines = [] }; return lines })
    }

    func testSectionsTogglesProgressAndConfirmedActions() throws {
        let (runtime, output) = run(Awake(), protocol: 7)
        let list = try XCTUnwrap(output().first { $0.contains(#""type":"list""#) })
        XCTAssertTrue(list.contains(#"{"detail":"1","kind":"section","symbol":"bolt","title":"Power"}"#), list)
        XCTAssertTrue(list.contains(#""toggle":false"#) && list.contains(#""id":"awake""#), list)
        XCTAssertTrue(list.contains(#""progress":0.4"#), list)
        XCTAssertTrue(list.contains(#""confirm":"Remove the container?""#), list)

        runtime.handle(#"{"type":"action","id":"awake"}"#)
        XCTAssertEqual((runtime.plugin as! Awake).isOn, true, "a tap on the switch hands over the other value")
        XCTAssertTrue(output().contains { $0.contains(#""toggle":true"#) })

        runtime.handle(#"{"type":"action","id":"c1/1-Remove"}"#)
        XCTAssertEqual((runtime.plugin as! Awake).removed, true, "the island asked; the tap arrives once you said yes")
    }

    func testAnOlderIslandIsNotOfferedActionsThatAskFirst() throws {
        let (_, output) = run(Awake(), protocol: 6)
        let list = try XCTUnwrap(output().first { $0.contains(#""type":"list""#) })
        XCTAssertTrue(list.contains("Logs"), list)
        XCTAssertFalse(list.contains("Remove"), "it would run unasked there: \(list)")
        XCTAssertEqual(PluginDescription(of: Awake.self).protocol, 1, "nothing here needs a newer app to run")
    }
}
