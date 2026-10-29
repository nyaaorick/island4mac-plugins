import Foundation

/// What a program said when it ran
public struct ShellResult: Sendable {
    public let status: Int32
    public let output: String
    public let error: String

    public var succeeded: Bool { status == 0 }
    /// The output's lines, without the trailing newline
    public var lines: [String] { output.split(separator: "\n", omittingEmptySubsequences: false).map(String.init).dropLast(output.hasSuffix("\n") ? 1 : 0) }
}

/// Runs programs for a plugin (docker, brew, git, shortcuts) off the main thread, and hands the result back on it.
/// An on-demand plugin isn't stopped while a run is under way
public enum Shell {
    /// Where Homebrew and the system put programs, searched after PATH
    public static let commonPaths = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]

    /// The program's path: as given if absolute, else the first on PATH or in `commonPaths`. nil if it isn't installed
    public static func which(_ program: String) -> String? {
        if program.hasPrefix("/") { return FileManager.default.isExecutableFile(atPath: program) ? program : nil }
        let path = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        for folder in path + commonPaths {
            let candidate = "\(folder)/\(program)"
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    /// Runs `program` (a path, or a name found with `which`) with `arguments`, in `directory` if given, and waits
    /// for it. Its output is read as it comes, so a chatty program doesn't stall. A program that isn't installed
    /// comes back with status 127
    @MainActor
    public static func run(_ program: String, _ arguments: [String] = [], in directory: String? = nil,
                           environment: [String: String] = [:]) async -> ShellResult {
        guard let executable = which(program) else {
            return ShellResult(status: 127, output: "", error: "\(program): not found")
        }
        IslandRuntime.current?.workBegan()
        defer { IslandRuntime.current?.workEnded() }
        return await Task.detached { runAndWait(executable, arguments, in: directory, environment: environment) }.value
    }

    /// The run itself, on whichever thread calls it
    nonisolated private static func runAndWait(_ executable: String, _ arguments: [String], in directory: String?,
                                               environment: [String: String]) -> ShellResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let directory { process.currentDirectoryURL = URL(fileURLWithPath: directory) }
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = ([env["PATH"] ?? ""] + commonPaths).joined(separator: ":")
        for (key, value) in environment { env[key] = value }
        process.environment = env
        let output = Pipe(), error = Pipe()
        process.standardOutput = output
        process.standardError = error
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return ShellResult(status: 126, output: "", error: "\(executable): \(error.localizedDescription)")
        }
        // Read both before waiting, or a full pipe stalls the program
        let group = DispatchGroup()
        nonisolated(unsafe) var outData = Data()
        group.enter()
        DispatchQueue.global().async { outData = output.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        let errData = error.fileHandleForReading.readDataToEndOfFile()
        group.wait()
        process.waitUntilExit()
        return ShellResult(status: process.terminationStatus, output: String(decoding: outData, as: UTF8.self),
                           error: String(decoding: errData, as: UTF8.self))
    }
}
