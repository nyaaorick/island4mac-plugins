import Foundation

/// Runs one plugin: renders its `body` into protocol messages, sends what changed, routes the island's taps to
/// the closures behind them, fires alarms, keeps @Fetched values fresh, and for an `.onDemand` plugin hands the
/// island its timeline and quits once there's nothing left to do
@MainActor
final class IslandRuntime {
    /// The running plugin's runtime; @State and Island reach it through this
    static var current: IslandRuntime?

    let plugin: any IslandPlugin
    let environment: [String: String]
    let dataDirectory: URL?
    /// The protocol version the island speaks
    let islandProtocol: Int
    private let output: (Data) -> Void
    /// Taken for `now` (tests set it)
    var clock: () -> Date = Date.init
    /// Called once an `.onDemand` plugin has said `done` (quits the program; tests replace it)
    var onSettle: () -> Void = { exit(0) }

    private(set) var isTabVisible = false
    /// Set while `body` is rendered for a time in the timeline
    private var renderDate: Date?
    var now: Date { renderDate ?? clock() }

    let preferences: [(key: String, storage: any PreferenceStorage)]
    private let states: [(key: String, storage: any StateStorage)]
    private let fetches: [FetchBox]

    private var actions: [String: @MainActor () -> Void] = [:]
    private var submits: [String: @MainActor (String) -> Void] = [:]
    private var control: (@MainActor (MediaCommand) -> Void)?
    private var seek: (@MainActor (TimeInterval) -> Void)?
    private var alarms: [Alarm.Entry] = []
    private var firedAlarms: Set<String> = []
    private var timer: Timer?
    /// The last line sent of each kind, so only what changed goes out
    private var lastSent: [String: Data] = [:]
    private var renderScheduled = false
    private var reportedWarnings: Set<String> = []
    /// Preferences come first from an island that has them; fetching waits for them so it uses the right ones
    private var awaitingPreferences: Bool
    /// An `.onDemand` plugin quits only after the island said why it started it
    private var hasWoken = false
    private var settleScheduled = false

    init(plugin: any IslandPlugin, environment: [String: String], output: @escaping (Data) -> Void) {
        self.plugin = plugin
        self.environment = environment
        self.output = output
        dataDirectory = environment["ISLAND_DATA_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        islandProtocol = environment["ISLAND_PROTOCOL"].flatMap(Int.init) ?? 1
        preferences = plugin.preferenceStorages
        let children = plugin.reflectedChildren
        states = children.compactMap { child in (child.value as? any StateStorage).map { (child.key, $0) } }
        fetches = children.compactMap { child in
            (child.value as? any FetchStorage).map { storage in
                storage.fetchBox.key = child.key
                return storage.fetchBox
            }
        }
        awaitingPreferences = !preferences.isEmpty && islandProtocol >= 2
        IslandRuntime.current = self
        StoredValues.current = StoredValues(folder: dataDirectory)
        if runsOnDemand { restoreState() }
        for fetch in fetches { fetch.attach(key: fetch.key) }
    }

    /// `.onDemand`, and the island can run it that way
    var runsOnDemand: Bool {
        type(of: plugin).lifecycle == .onDemand && islandProtocol >= 3
    }

    func start() {
        plugin.onStart()
        render()
        if !awaitingPreferences { refreshFetches() }
    }

    // MARK: - Rendering

    /// A @State changed: render once on the next turn, however many changed
    func setNeedsRender() {
        guard !renderScheduled else { return }
        renderScheduled = true
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                guard let runtime = IslandRuntime.current, runtime.renderScheduled else { return }
                runtime.render()
            }
        }
    }

    func render() {
        renderScheduled = false
        let collector = collect(at: nil)
        actions = collector.actions
        submits = collector.submits
        control = collector.control
        seek = collector.seek
        alarms = collector.alarms
        // An alarm no longer in body may come back later as a new one
        firedAlarms.formIntersection(alarms.map(\.key))
        for message in changes(from: collector, against: &lastSent) { output(message.line) }
        scheduleTimer()
        scheduleSettle()
    }

    /// Renders `body`, for `date` in the timeline or for now
    private func collect(at date: Date?) -> Collector {
        renderDate = date
        defer { renderDate = nil }
        let collector = Collector()
        Self.collect(plugin, into: collector)
        for warning in collector.warnings where reportedWarnings.insert(warning).inserted {
            Island.log("IslandKit: \(warning)")
        }
        return collector
    }

    private static func collect<Plugin: IslandPlugin>(_ plugin: Plugin, into collector: Collector) {
        plugin.body._collect(into: collector)
    }

    /// The messages that take what `sent` shows to what `collector` holds, updating `sent`. A kind that went
    /// away is cleared; one never shown needs nothing
    private func changes(from collector: Collector, against sent: inout [String: Data]) -> [Wire.Message] {
        var messages: [Wire.Message] = []
        func update(_ kind: String, _ message: Wire.Message?, clear: Wire.Message) {
            guard let message else {
                if sent.removeValue(forKey: kind) != nil { messages.append(clear) }
                return
            }
            let line = message.line
            guard sent[kind] != line else { return }
            sent[kind] = line
            messages.append(message)
        }
        update("compact", collector.compact.map { .compact($0) }, clear: .clear(.compact))
        // Cards are protocol 5; an older island shows them as rows after the rows
        var rows = collector.rows
        if islandProtocol >= 5 {
            update("cards", collector.cards.isEmpty ? nil : .cards(collector.cards), clear: .clear(.cards))
        } else {
            rows += collector.cards.prefix(max(0, Wire.maxItems - rows.count)).map { card in
                Wire.Row(id: card.id, title: card.title, subtitle: card.subtitle ?? card.preview?.text, symbol: card.symbol,
                         image: card.image ?? card.preview?.image, actions: card.actions)
            }
        }
        update("list", rows.isEmpty ? nil : .list(rows), clear: .clear(.list))
        // Media is protocol 5. The track first: the island drops a new track's old lyrics, then takes these
        if islandProtocol >= 5 {
            update("media", collector.media.map { .media($0) }, clear: .clear(.media))
            update("lyrics", collector.media == nil || collector.lyrics.isEmpty ? nil : .lyrics(collector.lyrics), clear: .clear(.lyrics))
        }
        update("buttons", collector.buttons.isEmpty ? nil : .buttons(collector.buttons), clear: .clear(.buttons))
        update("input", collector.input.map { .input($0) }, clear: .clear(.input))
        // The standard loading and error row is protocol 3; older islands would only log it
        if islandProtocol >= 3 {
            update("status", status.map { .status($0) }, clear: .status(Wire.Status(state: "idle")))
        }
        return messages
    }

    /// Loading with nothing to show yet, or the first failure
    private var status: Wire.Status? {
        if let failed = fetches.first(where: { $0.error != nil }) {
            return Wire.Status(state: "error", text: Wire.cut(failed.error))
        }
        if fetches.contains(where: { $0.isLoading && $0.value == nil }) {
            return Wire.Status(state: "loading")
        }
        return nil
    }

    func send(_ message: Wire.Message) {
        output(message.line)
    }

    // MARK: - Events

    func handle(_ line: String) {
        guard let event = try? JSONDecoder().decode(Wire.Event.self, from: Data(line.utf8)) else { return }
        switch event.type {
        case "action":
            guard let id = event.id, let action = actions[id] else { return }
            action()
        case "submit":
            guard let id = event.id, let submit = submits[id] else { return }
            submit(event.text ?? "")
        case "visible":
            isTabVisible = event.tab ?? false
            if isTabVisible { refreshFetches() }
        case "preferences":
            let values = event.values ?? [:]
            for (key, storage) in preferences { storage.apply(values[key]) }
            awaitingPreferences = false
            refreshFetches()
        case "wake":
            hasWoken = true
            refreshFetches()
        case "drop":
            plugin.onDrop(paths: event.paths ?? [], urls: (event.urls ?? []).compactMap(URL.init(string:)))
        case "control":
            guard let command = event.command.flatMap(MediaCommand.init(rawValue:)) else { return }
            control?(command)
        case "seek":
            guard let position = event.position, position.isFinite else { return }
            seek?(max(0, position))
        default:
            return
        }
        render()
    }

    private func refreshFetches() {
        guard !awaitingPreferences else { return }
        for fetch in fetches { fetch.refreshIfNeeded(now: clock()) }
    }

    /// A request ended: an `.onDemand` plugin may be done now
    func fetchFinished() {
        scheduleSettle()
    }

    // MARK: - Time: alarms, the timeline, refreshes

    /// When the next alarm is due, if any
    var nextAlarmDate: Date? {
        alarms.filter { !firedAlarms.contains($0.key) }.map(\.date).min()
    }

    /// The next time in the timeline, after now
    private var nextTimelineDate: Date? {
        let now = clock()
        return plugin.timeline.filter { $0 > now }.min()
    }

    /// The next time anything is due while it runs: an alarm, a timeline change, a refresh
    private var nextDate: Date? {
        ([nextAlarmDate, nextTimelineDate] + fetches.map(\.nextRefresh)).compactMap { $0 }.min()
    }

    private func scheduleTimer() {
        timer?.invalidate()
        timer = nil
        guard let next = nextDate else { return }
        let timer = Timer(fire: max(next, clock()), interval: 0, repeats: false) { _ in
            MainActor.assumeIsolated { IslandRuntime.current?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Something came due: alarms fire, values refresh, and body shows what it shows now
    func tick() {
        fireDueAlarms()
    }

    /// Runs every alarm whose time has come, once each, then renders
    func fireDueAlarms() {
        let now = clock()
        let due = alarms.filter { $0.date <= now && !firedAlarms.contains($0.key) }
        for alarm in due {
            firedAlarms.insert(alarm.key)
            alarm.perform()
        }
        refreshFetches()
        render()
    }

    // MARK: - On demand

    /// An `.onDemand` plugin quits once it was woken, its tab is hidden, nothing is loading and no alarm is due.
    /// Checked on the next turn, after whatever else is queued
    private func scheduleSettle() {
        guard runsOnDemand, hasWoken, !settleScheduled else { return }
        settleScheduled = true
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                guard let runtime = IslandRuntime.current else { return }
                runtime.settleScheduled = false
                runtime.settleIfIdle()
            }
        }
    }

    func settleIfIdle() {
        guard runsOnDemand, hasWoken, !isTabVisible, !fetches.contains(where: \.isLoading) else { return }
        if let alarm = nextAlarmDate, alarm <= clock() { return }
        // Once per wake: the island stops us now, and starts us again with a new wake when needed
        hasWoken = false
        if renderScheduled { render() }
        saveState()
        send(.timeline(timeline()))
        send(.done)
        timer?.invalidate()
        onSettle()
    }

    /// What the island shows later without us: `body` at each time in the timeline, as changes from the one
    /// before, and when to wake us for an alarm or a refresh
    func timeline() -> Wire.Timeline {
        let now = clock()
        var sent = lastSent
        var entries: [Wire.Timeline.Entry] = []
        for date in Set(plugin.timeline).filter({ $0 > now }).sorted().prefix(50) {
            let messages = changes(from: collect(at: date), against: &sent)
            guard !messages.isEmpty else { continue }
            entries.append(Wire.Timeline.Entry(at: date.timeIntervalSince1970, show: messages.map { Wire.RawMessage(line: $0.line) }))
        }
        let wake = ([nextAlarmDate] + fetches.map(\.nextRefresh)).compactMap { $0 }.min()
        return Wire.Timeline(entries: entries, wake: wake?.timeIntervalSince1970)
    }

    private var stateFile: URL? { dataDirectory?.appendingPathComponent("state.json") }
    /// In state.json beside the @State values: alarms that already fired, so a new run doesn't fire them again
    private static let firedAlarmsKey = "_firedAlarms"

    /// @State as it was when the plugin last quit
    private func restoreState() {
        guard let file = stateFile, let data = try? Data(contentsOf: file),
              let values = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        firedAlarms = Set(values[Self.firedAlarmsKey] as? [String] ?? [])
        for (key, storage) in states {
            guard let value = values[key],
                  let encoded = try? JSONSerialization.data(withJSONObject: value, options: .fragmentsAllowed) else { continue }
            storage.restore(from: encoded)
        }
    }

    private func saveState() {
        guard let file = stateFile else { return }
        var values: [String: Any] = [Self.firedAlarmsKey: firedAlarms.sorted()]
        for (key, storage) in states {
            guard let encoded = storage.encoded(),
                  let value = try? JSONSerialization.jsonObject(with: encoded, options: .fragmentsAllowed) else { continue }
            values[key] = value
        }
        guard let data = try? JSONSerialization.data(withJSONObject: values, options: [.sortedKeys]) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }
}

extension IslandPlugin {
    /// Its property wrappers, by property name
    var reflectedChildren: [(key: String, value: Any)] {
        Mirror(reflecting: self).children.compactMap { child in
            guard let label = child.label, label.hasPrefix("_") else { return nil }
            return (String(label.dropFirst()), child.value)
        }
    }
}
