import AppKit
import IslandKit

/// Quick notes as cards: type one and press Return, or drop text, links or files on the tab. Tap a card to copy
/// it; pin, change or delete it from its actions
@main
struct NotesPlugin: IslandPlugin {
    static let id = "notes"
    static let name = "Notes"
    static let symbol = "note.text"
    static let version = "1.0.0"
    static let description: String? = "Quick notes: type or drop text, links and files, tap one to copy it"
    /// Runs only while you use its tab: notes change only then
    static let lifecycle = Lifecycle.onDemand
    static let acceptsDrops = true

    struct Note: Codable, Equatable {
        var id: String
        var text: String
        var created: Date
        var pinned = false
        /// A dropped file the note stands for: its card shows it and drags out as it
        var file: String? = nil
    }

    @Stored("notes") var notes: [Note] = []
    /// The note in the text field, being changed
    @State var editing: String? = nil

    var body: some IslandContent {
        for note in shown {
            // A file's card is titled with its name; its preview is the file itself
            Card(note.file != nil ? note.text : label(note.created), subtitle: note.file != nil ? label(note.created) : nil,
                 symbol: symbol(note),
                 preview: note.file.map { .image(.file($0)) } ?? .text(note.text), file: note.file, id: note.id,
                 actions: actions(note)) {
                copy(note)
            }
        }

        if let note = notes.first(where: { $0.id == editing }) {
            TextField("Change the note, then Return", text: note.text, id: "edit-\(note.id)") { text in
                change(note.id, to: text)
            }
            Button("Cancel", symbol: "xmark") { editing = nil }
        } else {
            TextField("New note, then Return") { add($0) }
            if notes.contains(where: { !$0.pinned }) {
                Button("Clear", symbol: "trash", confirm: "Delete every note that isn't pinned?") {
                    notes.removeAll { !$0.pinned }
                }
            }
        }
    }

    /// "Today" and "Yesterday" move on at midnight, without the plugin
    var timeline: [Date] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Island.now)
        return [1, 2].compactMap { calendar.date(byAdding: .day, value: $0, to: today) }
    }

    /// Pinned first, then the newest; the island shows up to 50
    var shown: [Note] {
        Array(notes.sorted { ($0.pinned ? 1 : 0, $0.created) > ($1.pinned ? 1 : 0, $1.created) }.prefix(50))
    }

    func actions(_ note: Note) -> [RowAction] {
        var actions = [RowAction(note.pinned ? "Unpin" : "Pin", symbol: note.pinned ? "pin.slash" : "pin") { togglePin(note.id) }]
        if let url = link(note) {
            actions.append(RowAction("Open", symbol: "safari") { NSWorkspace.shared.open(url) })
        } else if let file = note.file {
            actions.append(RowAction("Show in Finder", symbol: "folder") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: file)])
            })
        } else {
            actions.append(RowAction("Edit", symbol: "pencil") { editing = note.id })
        }
        actions.append(RowAction("Delete", symbol: "trash") { delete(note.id) })
        return actions
    }

    func symbol(_ note: Note) -> String {
        if note.pinned { return "pin.fill" }
        if note.file != nil { return "doc" }
        return link(note) != nil ? "link" : "note.text"
    }

    /// The note as a web link, if that's all it is
    func link(_ note: Note) -> URL? {
        guard note.file == nil, !note.text.contains(where: \.isWhitespace),
              let url = URL(string: note.text), let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme) else { return nil }
        return url
    }

    func label(_ date: Date) -> String {
        let calendar = Calendar.current
        let time = date.formatted(date: .omitted, time: .shortened)
        if calendar.isDate(date, inSameDayAs: Island.now) { return time }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: Island.now), calendar.isDate(date, inSameDayAs: yesterday) {
            return "Yesterday"
        }
        return date.formatted(.dateTime.month(.abbreviated).day())
    }

    // MARK: - Changes

    func add(_ text: String, file: String? = nil) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        notes.append(Note(id: UUID().uuidString, text: text, created: Island.now, file: file))
    }

    func change(_ id: String, to text: String) {
        editing = nil
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let index = notes.firstIndex(where: { $0.id == id }) else { return }
        notes[index].text = text
    }

    func togglePin(_ id: String) {
        guard let index = notes.firstIndex(where: { $0.id == id }) else { return }
        notes[index].pinned.toggle()
    }

    func delete(_ id: String) {
        if editing == id { editing = nil }
        notes.removeAll { $0.id == id }
    }

    func copy(_ note: Note) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        if let file = note.file {
            pasteboard.writeObjects([URL(fileURLWithPath: file) as NSURL])
        } else {
            pasteboard.setString(note.text, forType: .string)
        }
        Island.popup("Copied", symbol: "doc.on.doc", seconds: 1.5)
    }

    /// Dropped text arrives as a file in Drops/ (read and removed); other files are kept by path, links as text
    func onDrop(paths: [String], urls: [URL]) {
        let drops = Island.dataDirectory?.appendingPathComponent("Drops", isDirectory: true).standardizedFileURL.path
        for path in paths {
            if let drops, URL(fileURLWithPath: path).standardizedFileURL.path.hasPrefix(drops + "/") {
                if let text = try? String(contentsOfFile: path, encoding: .utf8) { add(text) }
                try? FileManager.default.removeItem(atPath: path)
            } else {
                add(URL(fileURLWithPath: path).lastPathComponent, file: path)
            }
        }
        for url in urls { add(url.absoluteString) }
    }
}
