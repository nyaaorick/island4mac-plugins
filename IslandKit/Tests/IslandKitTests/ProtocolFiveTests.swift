import XCTest
@testable import IslandKit

/// Cards, drops and a player
struct Shelf: IslandPlugin {
    static let id = "shelf"
    static let name = "Shelf"
    static let symbol = "tray"
    static let acceptsDrops = true

    @State var files: [String] = ["/tmp/a.pdf"]
    @State var links: [String] = []

    var body: some IslandContent {
        for file in files {
            Card(URL(fileURLWithPath: file).lastPathComponent, preview: .image(.file(file)), file: file, id: file, actions: [
                RowAction("Remove", symbol: "xmark") { files.removeAll { $0 == file } },
            ])
        }
    }

    func onDrop(paths: [String], urls: [URL]) {
        files += paths
        links += urls.map(\.absoluteString)
    }
}

struct Player: IslandPlugin {
    static let id = "player"
    static let name = "Player"
    static let symbol = "music.note"

    @State var playing = true
    @State var position = 10.0
    @State var track = "One"

    var body: some IslandContent {
        Media(track, artist: "Artist", artwork: .url("https://example.com/a.jpg"), app: "com.spotify.client", playing: playing,
              elapsed: position, at: Date(timeIntervalSince1970: 1000), duration: 200,
              lyrics: track == "One" ? [LyricLine("Hello", at: 0)] : [],
              control: { command in
                  switch command {
                  case .playPause: playing.toggle()
                  case .next: track = "Two"
                  case .previous: track = "One"
                  }
              },
              seek: { position = $0 })
    }
}

@MainActor
final class ProtocolFiveTests: XCTestCase {
    private func run<Plugin: IslandPlugin>(_ plugin: Plugin, protocol version: Int = 5) -> (IslandRuntime, () -> [String]) {
        var lines: [String] = []
        let runtime = IslandRuntime(plugin: plugin, environment: ["ISLAND_PROTOCOL": "\(version)"]) {
            lines.append(String(decoding: $0, as: UTF8.self))
        }
        runtime.start()
        return (runtime, { defer { lines = [] }; return lines })
    }

    func testCardsAndDrops() throws {
        let (runtime, output) = run(Shelf())
        let cards = try XCTUnwrap(output().first { $0.contains(#""type":"cards""#) })
        XCTAssertTrue(cards.contains(#""file":"/tmp/a.pdf""#), cards)
        XCTAssertTrue(cards.contains(#""preview":{"image":{"file":"/tmp/a.pdf"}}"#), cards)
        XCTAssertTrue(cards.contains(#""actions":[{"id":"/tmp/a.pdf/0-Remove","symbol":"xmark","title":"Remove"}]"#), cards)

        runtime.handle(#"{"type":"drop","paths":["/tmp/b.pdf"],"urls":["https://example.com"]}"#)
        let shelf = runtime.plugin as! Shelf
        XCTAssertEqual(shelf.files, ["/tmp/a.pdf", "/tmp/b.pdf"])
        XCTAssertEqual(shelf.links, ["https://example.com"])
        XCTAssertTrue(output().contains { $0.contains("/tmp/b.pdf") }, "what was dropped shows")

        runtime.handle(#"{"type":"action","id":"/tmp/a.pdf/0-Remove"}"#)
        XCTAssertEqual((runtime.plugin as! Shelf).files, ["/tmp/b.pdf"])

        let description = PluginDescription(of: Shelf.self)
        XCTAssertEqual(description.protocol, 5)
        XCTAssertEqual(description.accepts, ["files"])
    }

    func testAnOlderIslandGetsCardsAsRows() throws {
        let (_, output) = run(Shelf(), protocol: 4)
        let lines = output()
        XCTAssertFalse(lines.contains { $0.contains(#""type":"cards""#) })
        let list = try XCTUnwrap(lines.first { $0.contains(#""type":"list""#) })
        XCTAssertTrue(list.contains(#""title":"a.pdf""#), list)
    }

    func testThePlayerSendsWhatPlaysAndHearsItsControls() throws {
        let (runtime, output) = run(Player())
        let lines = output()
        let media = try XCTUnwrap(lines.firstIndex { $0.contains(#""type":"media""#) })
        let lyrics = try XCTUnwrap(lines.firstIndex { $0.contains(#""type":"lyrics""#) })
        XCTAssertLessThan(media, lyrics, "the track goes first, then its lyrics")
        XCTAssertTrue(lines[media].contains(#""app":"com.spotify.client""#))
        XCTAssertTrue(lines[media].contains(#""elapsed":10"#))
        XCTAssertTrue(lines[lyrics].contains(#"{"text":"Hello","time":0}"#), lines[lyrics])

        runtime.handle(#"{"type":"control","command":"playPause"}"#)
        XCTAssertFalse((runtime.plugin as! Player).playing)
        XCTAssertTrue(output().contains { $0.contains(#""playing":false"#) })

        runtime.handle(#"{"type":"seek","position":80}"#)
        XCTAssertEqual((runtime.plugin as! Player).position, 80)

        runtime.handle(#"{"type":"control","command":"next"}"#)
        let next = output()
        XCTAssertTrue(next.contains { $0.contains(#""title":"Two""#) })
        XCTAssertTrue(next.contains(#"{"target":"lyrics","type":"clear"}"# + "\n"), "no lyrics for the next track")

        runtime.handle(#"{"type":"control","command":"rewind"}"#)
        XCTAssertTrue(output().isEmpty, "an unknown command does nothing")
    }

    func testAnOlderIslandGetsNoMedia() {
        let (_, output) = run(Player(), protocol: 4)
        XCTAssertFalse(output().contains { $0.contains(#""type":"media""#) })
    }
}
