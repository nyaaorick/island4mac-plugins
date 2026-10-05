import Foundation
import IslandKit

/// A countdown beside the notch: presets, a custom length, pause and resume, and a popup when time is up
@main
struct TimerPlugin: IslandPlugin {
    static let id = "timer"
    static let name = "Timer"
    static let symbol = "timer"
    static let version = "2.0.0"
    static let description: String? = "Countdown beside the notch, with presets and pause"
    /// The island runs the countdown and wakes the timer when it ends, so it runs only while you use its tab
    static let lifecycle = Lifecycle.onDemand

    @State var end: Date? = nil
    /// Time left while paused
    @State var paused: TimeInterval? = nil
    @State var total: TimeInterval = 0
    @Stored("last-minutes") var lastMinutes: Int? = nil

    var body: some IslandContent {
        if let end {
            Countdown(to: end, total: total, symbol: "timer")
            Alarm(at: end) {
                Island.popup("Time's up", symbol: "bell.fill", seconds: 4)
                Island.open()
                stop()
            }
        } else if let paused {
            Compact(symbol: "pause.fill", text: clock(paused), progress: paused / total)
        }

        for minutes in presets {
            Row("\(minutes) min", subtitle: subtitle(minutes), symbol: "play.circle", id: "start-\(minutes)") {
                start(minutes: minutes)
            }
        }
        TextField("Minutes, then Return") { text in
            if let minutes = Int(text.trimmingCharacters(in: .whitespaces)) { start(minutes: minutes) }
        }

        if let end {
            Button("Pause", symbol: "pause.fill") {
                paused = max(0, end.timeIntervalSince(Island.now))
                self.end = nil
            }
        } else if let paused {
            Button("Resume", symbol: "play.fill") {
                end = Island.now.addingTimeInterval(paused)
                self.paused = nil
            }
        }
        if end != nil || paused != nil {
            Button("Stop", symbol: "stop.fill", confirm: "Stop the timer?") { stop() }
        }
    }

    var presets: [Int] {
        var presets = [5, 15, 25]
        if let lastMinutes, !presets.contains(lastMinutes) { presets.insert(lastMinutes, at: 0) }
        return presets
    }

    func subtitle(_ minutes: Int) -> String {
        minutes == lastMinutes ? "Last used" : (minutes == 25 ? "Pomodoro" : "Countdown")
    }

    func start(minutes: Int) {
        guard minutes > 0, minutes <= 24 * 60 else { return }
        total = TimeInterval(minutes * 60)
        end = Island.now.addingTimeInterval(total)
        paused = nil
        lastMinutes = minutes
    }

    func stop() {
        end = nil
        paused = nil
    }

    func clock(_ seconds: TimeInterval) -> String {
        let whole = Int(seconds.rounded(.up))
        return String(format: "%02d:%02d", whole / 60, whole % 60)
    }
}
