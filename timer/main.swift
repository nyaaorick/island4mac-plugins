// Timer: the sample island plugin, and the template for writing one.
//
// A plugin is a folder with a plugin.json and a program. The app runs the program in that folder and reads what
// to show from its stdout, one JSON object per line; what you do comes back on its stdin the same way. It quits
// when its stdin closes (the app quit, or you switched its tab off).
//
//   island -> plugin   {"type":"action","id":"..."}             a row or button with that id was tapped
//                      {"type":"submit","id":"...","text":"..."} Return in its text field
//                      {"type":"visible","tab":true}            its tab opened or closed; also sent right after start
//   plugin -> island   compact, list, buttons, input, popup, open, clear (see PluginMessage in the app)
//
// The island draws everything in its own look; a plugin says what to show, never how.
// Environment: ISLAND_PROTOCOL, ISLAND_PLUGIN_ID, ISLAND_APP_VERSION, and ISLAND_DATA_DIR, a folder of its own
// for what it keeps (kept when the plugin is updated).
//
// Build: swiftc -O main.swift -o timer
import Foundation

/// Writes one message. stdout is a pipe, so flush every line or the island sees nothing
func send(_ message: [String: Any]) {
    guard var data = try? JSONSerialization.data(withJSONObject: message) else { return }
    data.append(UInt8(ascii: "\n"))
    FileHandle.standardOutput.write(data)
}

// The minutes you last started with, kept in the plugin's data folder
let lastFile = ProcessInfo.processInfo.environment["ISLAND_DATA_DIR"].map { URL(fileURLWithPath: $0).appendingPathComponent("last-minutes") }
var lastMinutes: Int? = lastFile.flatMap { try? String(contentsOf: $0, encoding: .utf8) }.flatMap { Int($0) }

var total: TimeInterval = 0
var endDate: Date?
/// Time left while paused
var pausedRemaining: TimeInterval?
var finish: Timer?

var remaining: TimeInterval {
    if let pausedRemaining { return pausedRemaining }
    guard let endDate else { return 0 }
    return max(0, endDate.timeIntervalSinceNow)
}

func clock(_ seconds: TimeInterval) -> String {
    let whole = Int(seconds.rounded(.up))
    return String(format: "%02d:%02d", whole / 60, whole % 60)
}

func showTab() {
    var presets = [5, 15, 25]
    if let lastMinutes, !presets.contains(lastMinutes) { presets.insert(lastMinutes, at: 0) }
    send(["type": "list", "rows": presets.map { minutes in
        ["id": "start-\(minutes)", "title": "\(minutes) min",
         "subtitle": minutes == lastMinutes ? "Last used" : (minutes == 25 ? "Pomodoro" : "Countdown"),
         "symbol": "play.circle"]
    }])
    send(["type": "input", "id": "minutes", "placeholder": "Minutes, then Return"])
    if endDate == nil && pausedRemaining == nil {
        send(["type": "clear", "target": "buttons"])
    } else {
        let stop: [String: Any] = ["id": "stop", "title": "Stop", "symbol": "stop.fill", "confirm": "Stop the timer?"]
        let toggle: [String: Any] = pausedRemaining == nil
            ? ["id": "pause", "title": "Pause", "symbol": "pause.fill"]
            : ["id": "resume", "title": "Resume", "symbol": "play.fill"]
        send(["type": "buttons", "buttons": [toggle, stop]])
    }
}

/// The island counts down by itself from `until`; the plugin only speaks when something changes
func showCompact() {
    if let endDate {
        send(["type": "compact", "symbol": "timer", "until": endDate.timeIntervalSince1970, "total": total])
    } else if let pausedRemaining {
        send(["type": "compact", "symbol": "pause.fill", "text": clock(pausedRemaining), "progress": pausedRemaining / total])
    } else {
        send(["type": "clear", "target": "compact"])
    }
}

/// When it runs out: a popup, and the island opens on the timer
func scheduleFinish() {
    finish?.invalidate()
    guard let endDate else { return }
    finish = Timer.scheduledTimer(withTimeInterval: max(0, endDate.timeIntervalSinceNow), repeats: false) { _ in
        send(["type": "popup", "symbol": "bell.fill", "text": "Time's up", "seconds": 4])
        send(["type": "open"])
        stop()
    }
}

func start(minutes: Int) {
    guard minutes > 0, minutes <= 24 * 60 else { return }
    total = TimeInterval(minutes * 60)
    endDate = Date().addingTimeInterval(total)
    pausedRemaining = nil
    lastMinutes = minutes
    if let lastFile { try? String(minutes).write(to: lastFile, atomically: true, encoding: .utf8) }
}

func stop() {
    finish?.invalidate()
    endDate = nil
    pausedRemaining = nil
    showCompact()
    showTab()
}

func handle(_ line: String) {
    guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { return }
    switch (object["type"] as? String, object["id"] as? String) {
    case ("submit", "minutes"):
        guard let minutes = Int((object["text"] as? String ?? "").trimmingCharacters(in: .whitespaces)) else { return }
        start(minutes: minutes)
    case ("action", "pause"):
        pausedRemaining = remaining
        endDate = nil
    case ("action", "resume"):
        if let pausedRemaining { endDate = Date().addingTimeInterval(pausedRemaining) }
        pausedRemaining = nil
    case ("action", "stop"):
        stop()
        return
    case ("action", let id?) where id.hasPrefix("start-"):
        guard let minutes = Int(id.dropFirst("start-".count)) else { return }
        start(minutes: minutes)
    default:
        return
    }
    scheduleFinish()
    showCompact()
    showTab()
}

// What you do arrives on stdin; reading blocks, so it gets its own thread. End of input: the app wants us gone
Thread.detachNewThread {
    while let line = readLine() {
        DispatchQueue.main.async { handle(line) }
    }
    exit(0)
}

showTab()
RunLoop.main.run()
