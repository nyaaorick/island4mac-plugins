import Foundation

/// A plugin.json, as `<program> --describe` prints it
struct Manifest: Codable, Equatable {
    let id: String
    let name: String
    let symbol: String
    let command: [String]
    let `protocol`: Int
    let version: String
    var description: String?

    /// Problems that would stop the app or the plugins repo from taking it
    func problems(folderName: String?) -> [String] {
        var problems: [String] = []
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789-_")
        if id.isEmpty || !id.allSatisfy(allowed.contains) {
            problems.append("id \"\(id)\" must be lowercase letters, digits, \"-\" and \"_\"")
        }
        if let folderName, folderName != id { problems.append("id \"\(id)\" doesn't match its folder \"\(folderName)\"") }
        if name.trimmingCharacters(in: .whitespaces).isEmpty { problems.append("name is empty") }
        if symbol.trimmingCharacters(in: .whitespaces).isEmpty { problems.append("symbol is empty") }
        let parts = version.split(separator: ".", omittingEmptySubsequences: false)
        if parts.isEmpty || parts.count > 3 || !parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) {
            problems.append("version \"\(version)\" must look like 1.2.3")
        }
        return problems
    }

    var json: Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = (try? encoder.encode(self)) ?? Data()
        data.append(UInt8(ascii: "\n"))
        return data
    }
}
