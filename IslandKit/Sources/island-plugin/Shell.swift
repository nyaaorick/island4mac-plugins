import Foundation

struct CLIError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// Runs a tool from PATH. Its stderr goes to ours; its stdout too, unless `capture` keeps it
@discardableResult
func run(_ tool: String, _ arguments: [String], in folder: URL? = nil, capture: Bool = false) throws -> (status: Int32, output: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = [tool] + arguments
    if let folder { process.currentDirectoryURL = folder }
    let pipe = Pipe()
    if capture { process.standardOutput = pipe }
    try process.run()
    // Read before waiting, or a full pipe stalls the tool
    let data = capture ? pipe.fileHandleForReading.readDataToEndOfFile() : Data()
    process.waitUntilExit()
    return (process.terminationStatus, String(decoding: data, as: UTF8.self))
}

/// Runs a tool and fails with `what` unless it succeeds
@discardableResult
func check(_ tool: String, _ arguments: [String], in folder: URL? = nil, capture: Bool = false, _ what: String) throws -> String {
    let result = try run(tool, arguments, in: folder, capture: capture)
    guard result.status == 0 else { throw CLIError("\(what) failed (\(tool) exit \(result.status))") }
    return result.output
}

func say(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

extension URL {
    var exists: Bool { FileManager.default.fileExists(atPath: path) }
}
