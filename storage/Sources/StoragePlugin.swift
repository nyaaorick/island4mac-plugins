import AppKit
import IslandKit

/// What macOS hides behind "System Data", named and rated by risk: each item measured, explained, and cleaned from
/// the island (safe ones for good, careful ones to the Trash), with free space beside the notch
@main
struct StoragePlugin: IslandPlugin {
    static let id = "storage"
    static let name = "Storage"
    static let symbol = "internaldrive"
    static let version = "1.0.0"
    static let description: String? = "What fills System Data, rated by risk, explained and cleaned from the island"
    /// Root-owned folders (system logs, diagnostics) are measured as an administrator when the user allows it
    static let needsAdmin = true

    @Preference("Beside the notch", options: [("free", "Free space"), ("used", "Used share"), ("off", "Off")]) var compact = "free"
    @Preference("Measure again after", options: [(15, "15 minutes"), (60, "An hour"), (0, "Only when asked")]) var rescanMinutes = 15
    @Preference("Show what must not be cleaned") var showNever = true

    @State var disk: DiskUsage? = nil
    @State var measurements: [String: Measurement] = [:]
    /// The target being measured, while a scan runs
    @State var scanning: String? = nil
    @State var scanned: Date? = nil
    /// The target open on its own, with its explanation and what is inside
    @State var opened: String? = nil
    /// Folders inside targets that aren't measured one level deep by the scan, read when one is opened
    @State var insides: [String: [Entry]] = [:]
    @State var busy: String? = nil
    @State var message: String? = nil
    @State var messageFailed = false
    @State var messageAt: Date? = nil

    var body: some IslandContent {
        if let besideNotch {
            besideNotch
        }
        if let message, let messageAt {
            Row(message, symbol: messageFailed ? "exclamationmark.triangle" : "checkmark.circle", state: messageFailed ? .failed : .done)
            Alarm(at: messageAt.addingTimeInterval(8), id: "message") { self.message = nil }
        }
        if let busy {
            Row(busy, symbol: "trash", state: .working)
        }
        if let target = opened.flatMap(Catalog.target) {
            Detail(target: target, measurement: measurements[target.id] ?? Measurement(), inside: insides[target.id] ?? [], plugin: self)
        } else {
            overview
        }
    }

    // MARK: - Overview

    @IslandBuilder var overview: some IslandContent {
        if let disk {
            Row("\(bytes(disk.free)) free", subtitle: "\(bytes(disk.used)) used of \(bytes(disk.total))", symbol: "internaldrive",
                progress: disk.usedShare)
        }
        if needsFullDiskAccess {
            Row("Give island4mac Full Disk Access", subtitle: "Messages, Mail and app containers can't be measured without it",
                symbol: "lock.open", state: .attention) { Self.openFullDiskAccessSettings() }
        }
        for tier in Tier.allCases where tier != .never || showNever {
            let targets = targets(in: tier)
            if !targets.isEmpty {
                Section(tier.title, symbol: tier.symbol, detail: bytes(targets.reduce(0) { $0 + (measurements[$1.id]?.bytes ?? 0) }))
                for target in targets {
                    row(target)
                }
            }
        }
        if scanning == nil {
            Button("Measure again", symbol: "arrow.clockwise") { scan() }
            let safe = cleanable(.safe)
            if !safe.isEmpty {
                Button("Clean everything safe", symbol: "trash",
                       confirm: "Delete everything in \(safe.count) safe item\(safe.count == 1 ? "" : "s") (\(bytes(safe.reduce(0) { $0 + (measurements[$1.id]?.bytes ?? 0) })))? This can't be undone.") {
                    clean(safe.map { ($0, nil) })
                }
            }
        }
    }

    func row(_ target: Target) -> Row {
        let measurement = measurements[target.id]
        var detail: String? = measurement.map { $0.bytes == 0 ? "Empty" : bytes($0.bytes) } ?? "…"
        if target.snapshots { detail = nil }
        return Row(target.label, subtitle: status(target, measurement).map { $0 + "\n" + target.what } ?? target.what, symbol: target.symbol,
                   state: scanning == target.id ? .working : nil, detail: detail, progress: share(measurement), id: target.id,
                   actions: actions(target, path: nil)) {
            open(target)
        }
    }

    /// A first subtitle line that says what kept the number from being whole
    func status(_ target: Target, _ measurement: Measurement?) -> String? {
        guard let measurement else { return nil }
        if let note = measurement.note { return note }
        if measurement.elevated { return "Measured as an administrator" }
        if measurement.denied { return target.requiresRoot ? "Owned by root: measured as far as allowed" : "Part of it couldn't be read" }
        return nil
    }

    /// Clean, Move to Trash and Show in Finder, for the whole target or one folder inside it
    func actions(_ target: Target, path: String?) -> [RowAction] {
        var actions: [RowAction] = []
        if target.canClean, path != nil || (measurements[target.id]?.bytes ?? 0) > 0 {
            let name = path.map { ($0 as NSString).lastPathComponent } ?? target.label
            let verb = target.tier.trashes ? "Move \(name) to the Trash?" : "Delete everything in \(name)? This can't be undone."
            actions.append(RowAction(target.tier.trashes ? "Move to Trash" : "Clean", symbol: "trash", confirm: path == nil ? "\(verb) \(target.ifDeleted)" : verb) {
                clean([(target, path)])
            })
        }
        if let where_ = path ?? target.paths.first.map(Catalog.expand) {
            actions.append(RowAction("Show in Finder", symbol: "folder") { Self.reveal(where_) })
        }
        return actions
    }

    /// Targets of a tier that exist on this Mac, largest first; not yet measured ones last
    func targets(in tier: Tier) -> [Target] {
        Catalog.targets
            .filter { $0.tier == tier && measurements[$0.id]?.missing != true }
            .sorted { (measurements[$0.id]?.bytes ?? 0, measurements[$0.id] == nil ? 0 : 1) > (measurements[$1.id]?.bytes ?? 0, measurements[$1.id] == nil ? 0 : 1) }
    }

    func cleanable(_ tier: Tier) -> [Target] {
        targets(in: tier).filter { $0.canClean && (measurements[$0.id]?.bytes ?? 0) > 0 }
    }

    /// Its share of the largest item measured, for the ring
    func share(_ measurement: Measurement?) -> Double? {
        guard let measurement, measurement.bytes > 0 else { return nil }
        let largest = measurements.values.map(\.bytes).max() ?? 0
        return largest > 0 ? Double(measurement.bytes) / Double(largest) : nil
    }

    var needsFullDiskAccess: Bool {
        measurements.contains { id, measurement in measurement.denied && !measurement.elevated && Catalog.target(id)?.requiresRoot == false }
    }

    var besideNotch: Compact? {
        guard let disk, compact != "off" else { return nil }
        switch compact {
        case "free": return Compact(symbol: "internaldrive", text: short(disk.free), progress: disk.usedShare)
        case "used": return Compact(symbol: "internaldrive", text: "\(Int((disk.usedShare * 100).rounded()))%", progress: disk.usedShare)
        default: return nil
        }
    }

    // MARK: - Measuring

    func onStart() {
        disk = Scanner.diskUsage()
        scan()
        var lastDisk = Date()
        let timer = Timer(timeInterval: 1, repeats: true) { _ in
            MainActor.assumeIsolated {
                let now = Date()
                if now.timeIntervalSince(lastDisk) >= 30 {
                    lastDisk = now
                    disk = Scanner.diskUsage()
                }
                // A stale scan is redone when the tab opens, not while nobody looks
                guard Island.isTabVisible, scanning == nil, busy == nil, rescanMinutes > 0,
                      let scanned, now.timeIntervalSince(scanned) >= Double(rescanMinutes) * 60 else { return }
                scan()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
    }

    func scan() {
        guard scanning == nil else { return }
        Scanner.adminRefused = false
        Task {
            for target in Catalog.targets {
                scanning = target.id
                measurements[target.id] = await Scanner.measure(target)
            }
            scanning = nil
            scanned = Island.now
            disk = Scanner.diskUsage()
        }
    }

    func open(_ target: Target) {
        opened = target.id
        // What is inside a target the scan didn't look into
        guard !target.breakdown, target.paths.count == 1, !target.snapshots, insides[target.id] == nil else { return }
        let path = Catalog.expand(target.paths[0])
        Task {
            insides[target.id] = await Scanner.children(of: path, excluding: target.excludes)
        }
    }

    // MARK: - Cleaning

    /// Cleans each target (or the one folder inside it), one after another, then measures them again and says
    /// what it came to
    func clean(_ jobs: [(Target, String?)]) {
        guard busy == nil, !jobs.isEmpty else { return }
        Task {
            var outcome = Cleaner.Outcome()
            var freed: UInt64 = 0
            var trashed = false
            for (target, path) in jobs {
                busy = "Cleaning \(target.label)…"
                let trash = target.tier.trashes
                trashed = trashed || trash
                let paths = path.map { [$0] } ?? target.paths.map(Catalog.expand)
                let excludes = Set(target.excludes)
                let one = await Task.detached {
                    var total = Cleaner.Outcome()
                    for folder in paths where FileManager.default.fileExists(atPath: folder) {
                        let result = path == nil ? Cleaner.empty(folder, excluding: excludes, trash: trash) : Cleaner.remove(folder, trash: trash)
                        total.removed += result.removed
                        total.failed += result.failed
                    }
                    return total
                }.value
                outcome.removed += one.removed
                outcome.failed += one.failed
                let before = measurements[target.id]?.bytes ?? 0
                let after = await Scanner.measure(target)
                measurements[target.id] = after
                freed += before > after.bytes ? before - after.bytes : 0
                if insides[target.id] != nil, let folder = target.paths.first {
                    insides[target.id] = await Scanner.children(of: Catalog.expand(folder), excluding: target.excludes)
                }
            }
            disk = Scanner.diskUsage()
            busy = nil
            var text = trashed ? "Moved \(bytes(freed)) to the Trash" : "Freed \(bytes(freed))"
            if !outcome.failed.isEmpty {
                text += "; \(outcome.failed.count) couldn't be removed: \(outcome.failed.prefix(2).joined(separator: ", "))"
                Island.log(outcome.failed.joined(separator: "\n"))
            }
            show(text, failed: !outcome.failed.isEmpty)
            Island.popup(trashed ? "Moved \(bytes(freed)) to the Trash" : "Freed \(bytes(freed))", symbol: "internaldrive", seconds: 4)
        }
    }

    func show(_ text: String, failed: Bool = false) {
        message = text
        messageFailed = failed
        messageAt = Island.now
    }

    // MARK: - Helpers

    static func reveal(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    static func openFullDiskAccessSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }

    func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        show("Copied")
    }

    func bytes(_ count: UInt64) -> String {
        Int64(clamping: count).formatted(.byteCount(style: .file))
    }

    /// "42 GB", "850 MB": short enough to sit beside the notch
    func short(_ count: UInt64) -> String {
        let gigabytes = Double(count) / 1_000_000_000
        switch gigabytes {
        case ..<1: return "\(Int(Double(count) / 1_000_000)) MB"
        case ..<10: return String(format: "%.1f GB", gigabytes)
        default: return "\(Int(gigabytes.rounded())) GB"
        }
    }
}

/// One target on its own: what it is, what deleting it costs, the advice, and what is inside it, each folder
/// with its own Clean or Move to Trash
struct Detail: IslandComponent {
    let target: Target
    let measurement: Measurement
    /// Folders inside, read when the target was opened (breakdown targets bring theirs from the scan)
    let inside: [Entry]
    let plugin: StoragePlugin

    var children: [Entry] { measurement.children.isEmpty ? inside : measurement.children }

    var body: some IslandContent {
        Section(target.label, symbol: target.symbol, detail: target.snapshots ? nil : plugin.bytes(measurement.bytes))
        if measurement.denied, !measurement.elevated {
            if target.requiresRoot {
                Row("Owned by root", subtitle: "Allow Storage administrator access under Settings > Plugins to measure all of it",
                    symbol: "lock", state: .attention)
            } else {
                Row("Part of it couldn't be read", subtitle: "Give island4mac Full Disk Access to measure all of it", symbol: "lock.open",
                    state: .attention) { StoragePlugin.openFullDiskAccessSettings() }
            }
        }
        if let note = measurement.note {
            Row(note, symbol: "clock.arrow.circlepath")
        }
        Row("What it is", subtitle: target.what, symbol: "info.circle")
        Row("If you delete it", subtitle: target.ifDeleted, symbol: "exclamationmark.triangle")
        Row("Advice", subtitle: target.advice, symbol: "lightbulb")
        if let command = target.command {
            Row("Better from the Terminal", subtitle: command, symbol: "terminal", detail: "Copy") { plugin.copy(command) }
        }

        if !children.isEmpty {
            Section("Inside", symbol: "folder", detail: "\(children.count) item\(children.count == 1 ? "" : "s")")
            for child in children.prefix(20) {
                Row(child.name, subtitle: Catalog.collapse(child.path), symbol: "folder", detail: plugin.bytes(child.bytes),
                    progress: measurement.bytes > 0 ? Double(child.bytes) / Double(measurement.bytes) : nil, id: "inside-\(child.path)",
                    actions: plugin.actions(target, path: child.path)) {
                    StoragePlugin.reveal(child.path)
                }
            }
        } else if !target.paths.isEmpty {
            Section("Where", symbol: "folder")
            for path in target.paths {
                Row(path, symbol: "folder", id: "where-\(path)") { StoragePlugin.reveal(Catalog.expand(path)) }
            }
        }

        Button("Back", symbol: "chevron.left") { plugin.opened = nil }
        if target.canClean, measurement.bytes > 0, plugin.busy == nil {
            Button(target.tier.trashes ? "Move to Trash" : "Clean", symbol: "trash",
                   confirm: (target.tier.trashes ? "Move everything in \(target.label) to the Trash? " : "Delete everything in \(target.label)? This can't be undone. ") + target.ifDeleted) {
                plugin.clean([(target, nil)])
            }
        }
    }
}
