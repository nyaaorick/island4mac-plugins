import Foundation

/// What plays, drawn with the island's own player: artwork, title, lyrics, progress, controls and spectrum, and
/// beside the notch. Say where the track is (`elapsed` as of `at`) and whether it plays; the island counts on by
/// itself, so there's no need to send the time every second. Taps on the player's controls and progress bar
/// come back to `control` and `seek`. The island also knows from `app` which app plays, to stay out of the way of
/// its full-screen video. Only one shows; the last one in `body` wins. Needs app protocol 5
public struct Media: IslandContent {
    let title: String
    let artist: String?
    let album: String?
    let artwork: IslandImage?
    let app: String?
    let playing: Bool
    let elapsed: TimeInterval?
    let at: Date
    let duration: TimeInterval?
    let rate: Double?
    let lyrics: [LyricLine]
    let control: @MainActor (MediaCommand) -> Void
    let seek: @MainActor (TimeInterval) -> Void

    /// - Parameters:
    ///   - app: The bundle id of the app that plays it
    ///   - elapsed: Seconds into the track, as of `at`
    ///   - duration: Seconds; unknown if nil
    ///   - rate: 1 is normal speed
    ///   - lyrics: The track's lyrics; lines with a time follow the song (up to 1000 lines)
    ///   - control: Play/pause, next or previous was tapped
    ///   - seek: The progress bar was dragged to this many seconds
    public init(_ title: String, artist: String? = nil, album: String? = nil, artwork: IslandImage? = nil, app: String? = nil,
                playing: Bool, elapsed: TimeInterval? = nil, at: Date = Island.now, duration: TimeInterval? = nil, rate: Double? = nil,
                lyrics: [LyricLine] = [], control: @escaping @MainActor (MediaCommand) -> Void = { _ in },
                seek: @escaping @MainActor (TimeInterval) -> Void = { _ in }) {
        self.title = title
        self.artist = artist
        self.album = album
        self.artwork = artwork
        self.app = app
        self.playing = playing
        self.elapsed = elapsed
        self.at = at
        self.duration = duration
        self.rate = rate
        self.lyrics = lyrics
        self.control = control
        self.seek = seek
    }

    public func _collect(into collector: Collector) {
        collector.setMedia(
            Wire.Media(title: Wire.cut(title), artist: Wire.cut(artist), album: Wire.cut(album), artwork: artwork?.wire, app: app,
                       playing: playing, elapsed: elapsed, at: at.timeIntervalSince1970, duration: duration, rate: rate),
            lyrics: lyrics.prefix(Wire.maxLyricLines).map { Wire.LyricLine(time: $0.time, text: Wire.cut($0.text)) },
            control: control, seek: seek)
    }
}

/// One line of a track's lyrics. With a time (seconds into the track) it follows the song
public struct LyricLine: Equatable, Sendable {
    public let time: TimeInterval?
    public let text: String

    public init(_ text: String, at time: TimeInterval? = nil) {
        self.text = text
        self.time = time
    }
}

/// A tap on the island's player
public enum MediaCommand: String, Sendable {
    case playPause, next, previous
}
