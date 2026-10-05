import XCTest
@testable import IslandKit

struct Weather: IslandPlugin {
    static let id = "weather"
    static let name = "Weather"
    static let symbol = "sun.max"

    @Preference("API key", secure: true, required: true) var apiKey = ""
    @Preference("Refresh every", options: [1, 5, 15]) var minutes = 5
    @Preference("Days", range: 1...7) var days = 3
    @Preference("Celsius") var celsius = true

    var body: some IslandContent {
        Row("\(apiKey.isEmpty ? "no key" : "key") \(minutes) \(days) \(celsius)")
    }
}

@MainActor
final class PreferenceTests: XCTestCase {
    func testPreferencesAreDescribedFromTheCode() throws {
        let description = PluginDescription(of: Weather.self)
        XCTAssertEqual(description.protocol, 2, "preferences need protocol 2")
        let preferences = try XCTUnwrap(description.preferences)
        XCTAssertEqual(preferences.map(\.key), ["apiKey", "minutes", "days", "celsius"])
        XCTAssertEqual(preferences.map(\.kind), ["secure", "choice", "number", "toggle"])
        XCTAssertEqual(preferences[0].required, true)
        XCTAssertEqual(preferences[1].options?.map(\.title), ["1", "5", "15"])
        XCTAssertEqual(preferences[1].default, .number(5))
        XCTAssertEqual(preferences[2].minimum, 1)
        XCTAssertEqual(preferences[2].maximum, 7)
        XCTAssertNil(PluginDescription(of: Counter.self).preferences, "none declared: protocol 1, no key")
    }

    /// The same JSON is in the app's tests (PluginTests.testIslandKitsPluginJSONLoads): the app must read what
    /// IslandKit writes. Delete the fixture to write it again after a deliberate change, and copy it there
    func testThePluginJSONMatchesTheFixture() throws {
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/weather.plugin.json")
        let json = PluginDescription(of: Weather.self).json
        guard let expected = try? Data(contentsOf: fixture) else {
            try json.write(to: fixture)
            return XCTFail("wrote \(fixture.path); run again")
        }
        XCTAssertEqual(String(decoding: json, as: UTF8.self), String(decoding: expected, as: UTF8.self))
    }

    func testTheIslandsValuesReachThePlugin() {
        var lines: [String] = []
        let runtime = IslandRuntime(plugin: Weather(), environment: [:]) { lines.append(String(decoding: $0, as: UTF8.self)) }
        runtime.start()
        XCTAssertTrue(lines.last?.contains("no key 5 3 true") == true, "defaults until the island says")
        runtime.handle(#"{"type":"preferences","values":{"apiKey":"k","minutes":15,"days":6.6,"celsius":false}}"#)
        XCTAssertTrue(lines.last?.contains("key 15 7 false") == true, "\(lines.last ?? "")")
        runtime.handle(#"{"type":"preferences","values":{"minutes":"oops"}}"#)
        XCTAssertTrue(lines.last?.contains("no key 5 3 true") == true, "missing or wrong values fall back to the defaults")
    }
}
