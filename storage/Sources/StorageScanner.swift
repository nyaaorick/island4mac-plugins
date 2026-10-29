import Foundation
import IslandKit

/// One folder inside a target, with its size
struct Entry: Codable, Equatable, Sendable {
    var name: String
    var path: String
    var bytes: UInt64
}

/// What one target measured to
struct Measurement: Codable, Equatable, Sendable {
    var bytes: UInt64 = 0
    /// Its folders one level down, largest first (breakdown targets, and any target once opened)
    var children: [Entry] = []
    /// None of its paths exist on this Mac
    var missing = false
    /// Part of it couldn't be read: Full Disk Access is missing, or it is owned by root
    var denied = false
    /// Measured as an administrator through the island
    var elevated = false
    /// Snapshots: what tmutil said
    var note: String? = nil
}

struct DiskUsage: Codable, Equatable, Sendable {
    var total: UInt64
    var free: UInt64
    var used: UInt64 { total > free ? total - free : 0 }
    var usedShare: Double { total > 0 ? Double(used) / Double(total) : 0 }
}

/// Measures targets with du, as the user, and as an administrator through the island for root-owned ones
@MainActor
enum Scanner {
    /// Whether the island refused administrator access this run, so the plugin stops asking for it
    static var adminRefused = false

    static func diskUsage() -> DiskUsage? {
        guard let values = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]),
              let total = values.volumeTotalCapacity, let free = values.volumeAvailableCapacityForImportantUsage else { return nil }
        return DiskUsage(total: UInt64(max(0, total)), free: UInt64(max(0, free)))
    }

    static func measure(_ target: Target) async -> Measurement {
        if target.snapshots { return await snapshots() }

        var result = Measurement()
        var existing = 0
        var children: [Entry] = []
        for raw in target.paths {
            let path = Catalog.expand(raw)
            guard FileManager.default.fileExists(atPath: path) || isDeniedStat(path) else { continue }
            existing += 1
            let depth = target.breakdown || target.paths.count > 1 ? 1 : 0
            var reading = await Task.detached { DiskReader.du(path, depth: depth) }.value
            if (reading.denied || reading.lines.isEmpty), target.requiresRoot, !adminRefused {
                let elevated = await Island.sudo("/usr/bin/du", DiskReader.arguments(path, depth: depth))
                if elevated.status == -1 {
                    adminRefused = true
                } else if !elevated.output.isEmpty {
                    reading = DiskReader.Reading(lines: elevated.output.split(separator: "\n").map(String.init), denied: false)
                    result.elevated = true
                }
            }
            let parsed = DiskReader.parse(reading.lines, root: path)
            result.bytes += parsed.total
            if reading.denied { result.denied = true }
            if target.breakdown {
                children += parsed.children
            } else if target.paths.count > 1 {
                children.append(Entry(name: (path as NSString).lastPathComponent, path: path, bytes: parsed.total))
            }
        }
        result.missing = existing == 0
        // Sub-targets rated on their own are left out, so nothing is counted twice
        for name in target.excludes {
            if let hit = children.first(where: { $0.name == name }) { result.bytes -= min(result.bytes, hit.bytes) }
        }
        children.removeAll { target.excludes.contains($0.name) }
        result.children = children.sorted { $0.bytes > $1.bytes }
        return result
    }

    /// The folders one level inside `path`, for a target opened in the tab
    static func children(of path: String, excluding: [String]) async -> [Entry] {
        let reading = await Task.detached { DiskReader.du(path, depth: 1) }.value
        return DiskReader.parse(reading.lines, root: path).children
            .filter { !excluding.contains($0.name) }
            .sorted { $0.bytes > $1.bytes }
    }

    private static func snapshots() async -> Measurement {
        let result = await Shell.run("tmutil", ["listlocalsnapshots", "/"])
        let names = result.lines.filter { $0.hasPrefix("com.apple.TimeMachine") }
        var measurement = Measurement()
        measurement.note = names.isEmpty
            ? "No local snapshots: they are not where the space went"
            : "\(names.count) local snapshot\(names.count == 1 ? "" : "s"). macOS thins them itself; their size can't be measured"
        return measurement
    }

    /// A folder that exists but can't even be looked at (Full Disk Access missing) is still a target
    private static func isDeniedStat(_ path: String) -> Bool {
        var info = stat()
        return stat(path, &info) != 0 && (errno == EACCES || errno == EPERM)
    }
}

/// Runs du and reads its output. du exits non-zero on any unreadable folder but still reports what it could
/// read, so partial output is a normal result, not a failure
enum DiskReader {
    struct Reading: Sendable {
        var lines: [String]
        var denied: Bool
    }

    static func arguments(_ path: String, depth: Int) -> [String] {
        depth > 0 ? ["-kx", "-d", "1", path] : ["-skx", path]
    }

    nonisolated static func du(_ path: String, depth: Int) -> Reading {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/du")
        process.arguments = arguments(path, depth: depth)
        let output = Pipe(), error = Pipe()
        process.standardOutput = output
        process.standardError = error
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return Reading(lines: [], denied: false)
        }
        // Read both before waiting, or a full pipe stalls du
        let group = DispatchGroup()
        nonisolated(unsafe) var outData = Data()
        group.enter()
        DispatchQueue.global().async { outData = output.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        let errData = error.fileHandleForReading.readDataToEndOfFile()
        group.wait()
        process.waitUntilExit()
        let errors = String(decoding: errData, as: UTF8.self)
        let denied = errors.contains("Permission denied") || errors.contains("Operation not permitted")
        return Reading(lines: String(decoding: outData, as: UTF8.self).split(separator: "\n").map(String.init), denied: denied)
    }

    /// The root's total and its children, from du's "kilobytes<tab>path" lines
    static func parse(_ lines: [String], root: String) -> (total: UInt64, children: [Entry]) {
        var total: UInt64 = 0
        var children: [Entry] = []
        let rootPath = root.hasSuffix("/") ? String(root.dropLast()) : root
        for line in lines {
            guard let tab = line.firstIndex(of: "\t"), let kilobytes = UInt64(line[..<tab]) else { continue }
            let path = String(line[line.index(after: tab)...])
            if path == rootPath || path == rootPath + "/" {
                total = kilobytes * 1024
            } else {
                children.append(Entry(name: (path as NSString).lastPathComponent, path: path, bytes: kilobytes * 1024))
            }
        }
        // du -s prints only the root; du -d 1 prints it last
        if total == 0, children.count == 1, lines.count == 1 { total = children[0].bytes; children = [] }
        return (total, children)
    }
}
