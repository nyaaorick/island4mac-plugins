import XCTest
@testable import IslandKit

/// Shows the next of two events; runs on demand
struct Agenda: IslandPlugin {
    static let id = "agenda"
    static let name = "Agenda"
    static let symbol = "calendar"
    static let lifecycle = Lifecycle.onDemand

    static let lunch = Date(timeIntervalSince1970: 2000)
    static let review = Date(timeIntervalSince1970: 3000)

    @State var taps = 0
    @State var reminded = false

    var timeline: [Date] { [Self.lunch, Self.review] }

    var body: some IslandContent {
        if Island.now < Self.lunch {
            Compact(symbol: "fork.knife", text: "Lunch")
        } else if Island.now < Self.review {
            Compact(symbol: "person.2", text: "Review")
        }
        Row("Tapped \(taps)") { taps += 1 }
        if !reminded {
            Alarm(at: Date(timeIntervalSince1970: 2500)) { reminded = true }
        }
    }
}

struct Forecast: Decodable, Equatable {
    let temperature: Int
}

struct Weather2: IslandPlugin {
    static let id = "weather2"
    static let name = "Weather"
    static let symbol = "sun.max"

    @Preference("City") var city = "Paris"
    @Fetched(Forecast.self, from: "https://example.com/{city}", headers: ["X-City": "{city}"], every: .minutes(30)) var forecast

    var body: some IslandContent {
        if let forecast {
            Compact(symbol: "sun.max", text: "\(forecast.temperature)°")
        }
    }
}

@MainActor
final class OnDemandTests: XCTestCase {
    private var lines: [String] = []
    private var settled = 0

    private func folder() -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("IslandKitTests-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return folder
    }

    private func runtime<P: IslandPlugin>(_ plugin: P, data: URL, islandProtocol: Int = 3, now: Date) -> IslandRuntime {
        lines = []
        let runtime = IslandRuntime(plugin: plugin, environment: ["ISLAND_DATA_DIR": data.path, "ISLAND_PROTOCOL": "\(islandProtocol)"]) { [unowned self] in
            lines.append(String(decoding: $0, as: UTF8.self).trimmingCharacters(in: .newlines))
        }
        runtime.clock = { now }
        runtime.onSettle = { [unowned self] in settled += 1 }
        return runtime
    }

    private func spin() { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }

    func testItHandsOverItsTimelineAndQuitsAfterAWake() throws {
        let data = folder()
        let runtime = runtime(Agenda(), data: data, now: Date(timeIntervalSince1970: 1000))
        runtime.start()
        spin()
        XCTAssertEqual(settled, 0, "not before the island says why it started it")

        runtime.handle(#"{"type":"action","id":"row-0-Tapped 0"}"#)
        runtime.handle(#"{"type":"wake","reason":"action"}"#)
        spin()
        XCTAssertEqual(settled, 1)
        XCTAssertEqual(lines.suffix(2).last, #"{"type":"done"}"#)
        let timeline = try XCTUnwrap(lines.first { $0.contains(#""type":"timeline""#) })
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(timeline.utf8)) as? [String: Any])
        let entries = try XCTUnwrap(object["entries"] as? [[String: Any]])
        XCTAssertEqual(entries.map { $0["at"] as? Double }, [2000, 3000])
        XCTAssertEqual(((entries[0]["show"] as? [[String: Any]])?.first)?["text"] as? String, "Review")
        XCTAssertEqual(((entries[1]["show"] as? [[String: Any]])?.first)?["target"] as? String, "compact", "nothing after the review: cleared")
        XCTAssertEqual(object["wake"] as? Double, 2500, "woken for its alarm")

        // The next run starts where this one stopped
        let again = self.runtime(Agenda(), data: data, now: Date(timeIntervalSince1970: 2600))
        XCTAssertEqual((again.plugin as! Agenda).taps, 1, "@State is kept between runs")
        again.start()
        again.handle(#"{"type":"wake","reason":"timeline"}"#)
        let deadline = Date().addingTimeInterval(2)
        while !(again.plugin as! Agenda).reminded && Date() < deadline { spin() }
        XCTAssertTrue((again.plugin as! Agenda).reminded, "the alarm it was woken for fires")
    }

    func testItStaysWhileItsTabShowsAndOnOlderIslands() {
        let open = runtime(Agenda(), data: folder(), now: Date(timeIntervalSince1970: 1000))
        open.start()
        open.handle(#"{"type":"visible","tab":true}"#)
        open.handle(#"{"type":"wake","reason":"visible"}"#)
        spin()
        XCTAssertEqual(settled, 0, "its tab is open")
        open.handle(#"{"type":"visible","tab":false}"#)
        spin()
        XCTAssertEqual(settled, 1, "closed: it quits")

        settled = 0
        let old = runtime(Agenda(), data: folder(), islandProtocol: 2, now: Date(timeIntervalSince1970: 1000))
        old.start()
        old.handle(#"{"type":"wake","reason":"launch"}"#)
        spin()
        XCTAssertEqual(settled, 0, "an island before protocol 3 can't start it again, so it keeps running")
    }

    func testFetchedShowsTheCacheThenRefreshes() throws {
        let data = folder()
        let requests = RequestLog()
        FetchBox.load = { request in
            requests.add(request)
            return (Data(#"{"temperature":21}"#.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let now = Date(timeIntervalSince1970: 10_000)
        let runtime = runtime(Weather2(), data: data, now: now)
        runtime.start()
        XCTAssertFalse(lines.contains { $0.contains("status") }, "it waits for the island's preferences before fetching")
        runtime.handle(#"{"type":"preferences","values":{"city":"São Paulo"}}"#)
        XCTAssertTrue(lines.last?.contains(#""state":"loading""#) == true, "nothing to show yet: the standard loading row")
        let deadline = Date().addingTimeInterval(2)
        while !lines.contains(where: { $0.contains("21°") }) && Date() < deadline { spin() }
        XCTAssertTrue(lines.contains { $0.contains("21°") })
        XCTAssertTrue(lines.contains(#"{"state":"idle","type":"status"}"#), "loaded: the row goes")
        let request = try XCTUnwrap(requests.all.first)
        XCTAssertEqual(request.url?.absoluteString, "https://example.com/S%C3%A3o%20Paulo")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-City"), "São Paulo")

        // Later, offline: the cache shows at once and the failure says why
        FetchBox.load = { _ in throw URLError(.notConnectedToInternet) }
        let later = self.runtime(Weather2(), data: data, now: now.addingTimeInterval(3600))
        later.start()
        XCTAssertTrue(lines.contains { $0.contains("21°") }, "the last result, before any request")
        later.handle(#"{"type":"preferences","values":{"city":"São Paulo"}}"#)
        let failDeadline = Date().addingTimeInterval(2)
        while !(lines.last?.contains(#""state":"error""#) ?? false) && Date() < failDeadline { spin() }
        XCTAssertTrue(lines.last?.contains(#""state":"error""#) == true)
    }
}

/// The requests @Fetched made, from whatever thread made them
final class RequestLog: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [URLRequest] = []
    var all: [URLRequest] { lock.withLock { requests } }
    func add(_ request: URLRequest) { lock.withLock { requests.append(request) } }
}
