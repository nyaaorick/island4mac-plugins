import XCTest
@testable import IslandKit

/// A plugin with one of everything, for the tests
struct Counter: IslandPlugin {
    static let id = "counter"
    static let name = "Counter"
    static let symbol = "number"
    static let version = "1.2.0"

    @State var count = 0
    @State var alarmAt: Date? = nil
    @State var rang = 0
    @Stored("saved") var saved = 0

    var body: some IslandContent {
        if count > 0 {
            Compact(symbol: "number", text: "\(count)")
        }
        for step in [1, 5] {
            Row("Add \(step)", symbol: "plus") { count += step }
        }
        Row("Not tappable")
        TextField("Set to") { text in count = Int(text) ?? count }
        Button("Reset", confirm: "Reset it?", id: "reset") { count = 0 }
        if let alarmAt {
            Alarm(at: alarmAt) { rang += 1 }
        }
    }
}

@MainActor
final class IslandKitTests: XCTestCase {
    private var lines: [String] = []

    private func makeRuntime(environment: [String: String] = [:]) -> IslandRuntime {
        lines = []
        return IslandRuntime(plugin: Counter(), environment: environment) { [unowned self] data in
            lines.append(String(decoding: data, as: UTF8.self).trimmingCharacters(in: .newlines))
        }
    }

    private func objects() -> [[String: Any]] {
        lines.compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
    }

    func testTheFirstRenderSendsWhatShows() {
        let runtime = makeRuntime()
        runtime.start()
        let types = objects().map { $0["type"] as? String }
        XCTAssertEqual(types, ["list", "buttons", "input"], "nothing compact yet, so no compact and no clear")
        let rows = objects()[0]["rows"] as? [[String: Any]]
        XCTAssertEqual(rows?.count, 3)
        XCTAssertEqual(rows?[0]["id"] as? String, "row-0-Add 1")
        XCTAssertNil(rows?[2]["id"], "a row without an action can't be tapped")
        let buttons = objects()[1]["buttons"] as? [[String: Any]]
        XCTAssertEqual(buttons?[0]["id"] as? String, "reset")
        XCTAssertEqual(buttons?[0]["confirm"] as? String, "Reset it?")
    }

    func testOnlyWhatChangedIsSentAgain() {
        let runtime = makeRuntime()
        runtime.start()
        lines = []
        runtime.handle(#"{"type":"action","id":"row-1-Add 5"}"#)
        XCTAssertEqual(lines, [#"{"symbol":"number","text":"5","type":"compact"}"#])
        lines = []
        runtime.handle(#"{"type":"action","id":"reset"}"#)
        XCTAssertEqual(lines, [#"{"target":"compact","type":"clear"}"#], "gone from body: cleared")
        lines = []
        runtime.render()
        XCTAssertEqual(lines, [], "nothing changed")
    }

    func testSubmitsAndUnknownTapsAndEvents() {
        let runtime = makeRuntime()
        runtime.start()
        runtime.handle(#"{"type":"submit","id":"input","text":"42"}"#)
        XCTAssertEqual((runtime.plugin as? Counter)?.count, 42)
        runtime.handle(#"{"type":"action","id":"row-0-Something else"}"#)
        runtime.handle(#"{"type":"something-new"}"#)
        runtime.handle("not json")
        XCTAssertEqual((runtime.plugin as? Counter)?.count, 42, "unknown taps and lines are ignored")
        runtime.handle(#"{"type":"visible","tab":true}"#)
        XCTAssertTrue(Island.isTabVisible)
    }

    func testAlarmsFireOnceWhenDue() {
        let runtime = makeRuntime()
        var now = Date(timeIntervalSince1970: 1000)
        runtime.clock = { now }
        let counter = runtime.plugin as! Counter
        counter.alarmAt = Date(timeIntervalSince1970: 1060)
        runtime.render()
        XCTAssertEqual(runtime.nextAlarmDate, Date(timeIntervalSince1970: 1060))
        runtime.fireDueAlarms()
        XCTAssertEqual(counter.rang, 0, "not yet")
        now = Date(timeIntervalSince1970: 1061)
        runtime.fireDueAlarms()
        runtime.fireDueAlarms()
        XCTAssertEqual(counter.rang, 1, "once")
        XCTAssertNil(runtime.nextAlarmDate)
        counter.alarmAt = Date(timeIntervalSince1970: 1120)
        runtime.render()
        XCTAssertEqual(runtime.nextAlarmDate, Date(timeIntervalSince1970: 1120), "moved: a new alarm")
    }

    func testAnAlarmFiresOnTheRunLoop() {
        let runtime = makeRuntime()
        let counter = runtime.plugin as! Counter
        counter.alarmAt = Date().addingTimeInterval(0.2)
        runtime.render()
        let deadline = Date().addingTimeInterval(2)
        while counter.rang == 0 && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertEqual(counter.rang, 1)
    }

    func testStoredValuesSurviveARestart() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("IslandKitTests-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let runtime = makeRuntime(environment: ["ISLAND_DATA_DIR": folder.path])
        (runtime.plugin as! Counter).saved = 7
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("stored.json").path))
        let again = makeRuntime(environment: ["ISLAND_DATA_DIR": folder.path])
        XCTAssertEqual((again.plugin as! Counter).saved, 7)
    }

    func testLimitsAreKept() {
        struct Many: IslandPlugin {
            static let id = "many", name = "Many", symbol = "list.bullet"
            var body: some IslandContent {
                for index in 0..<60 { Row("Row \(index)") }
                Compact(text: String(repeating: "x", count: 300))
            }
        }
        lines = []
        let runtime = IslandRuntime(plugin: Many(), environment: [:]) { [unowned self] in lines.append(String(decoding: $0, as: UTF8.self)) }
        runtime.start()
        let list = objects().first { $0["type"] as? String == "list" }
        XCTAssertEqual((list?["rows"] as? [Any])?.count, Wire.maxItems)
        let compact = objects().first { $0["type"] as? String == "compact" }
        XCTAssertEqual((compact?["text"] as? String)?.count, Wire.maxTextLength)
    }

    func testTheDescriptionIsAPluginJSON() throws {
        let description = PluginDescription(of: Counter.self)
        let object = try JSONSerialization.jsonObject(with: description.json) as? [String: Any]
        XCTAssertEqual(object?["id"] as? String, "counter")
        XCTAssertEqual(object?["command"] as? [String], ["./counter"])
        XCTAssertEqual(object?["protocol"] as? Int, 1)
        XCTAssertEqual(object?["version"] as? String, "1.2.0")
        XCTAssertNil(object?["description"])
    }

    func testCountdownsAreRunByTheIsland() {
        struct Clock: IslandPlugin {
            static let id = "clock", name = "Clock", symbol = "timer"
            var body: some IslandContent { Countdown(to: Date(timeIntervalSince1970: 2000), total: 300, symbol: "timer") }
        }
        lines = []
        let runtime = IslandRuntime(plugin: Clock(), environment: [:]) { [unowned self] in lines.append(String(decoding: $0, as: UTF8.self)) }
        runtime.start()
        XCTAssertEqual(lines, [#"{"symbol":"timer","total":300,"type":"compact","until":2000}"# + "\n"])
    }
}
