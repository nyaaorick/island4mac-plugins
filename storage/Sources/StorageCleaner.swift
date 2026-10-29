import Foundation

/// The only code here that removes anything. Two ways, both best-effort: to the Trash (undone from Finder) or
/// for good. A folder that can't be removed is emptied as far as it goes, and what stays is reported, so one
/// protected entry never abandons the job. Symbolic links are removed, never followed. Nothing is ever handed
/// to a shell
enum Cleaner {
    struct Outcome: Sendable {
        var removed = 0
        /// Paths that stayed, with why
        var failed: [String] = []
    }

    /// Removes everything inside `folder` but the folder itself (some, like ~/Library/Caches, carry an ACL that
    /// forbids deleting the folder and apps expect it to exist), leaving `excluding` alone
    nonisolated static func empty(_ folder: String, excluding: Set<String> = [], trash: Bool) -> Outcome {
        var outcome = Outcome()
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder) else {
            outcome.failed.append("\(Catalog.collapse(folder)): can't be read")
            return outcome
        }
        for name in names where !excluding.contains(name) {
            let path = (folder as NSString).appendingPathComponent(name)
            let one = remove(path, trash: trash)
            outcome.removed += one.removed
            outcome.failed += one.failed
        }
        return outcome
    }

    /// Removes one file or folder
    nonisolated static func remove(_ path: String, trash: Bool) -> Outcome {
        var outcome = Outcome()
        let url = URL(fileURLWithPath: path)
        if trash {
            do {
                try FileManager.default.trashItem(at: url, resultingItemURL: nil)
                outcome.removed = 1
            } catch {
                outcome.failed.append("\(Catalog.collapse(path)): \(reason(error))")
            }
            return outcome
        }
        if (try? FileManager.default.removeItem(at: url)) != nil {
            outcome.removed = 1
            return outcome
        }
        // The fast path stopped at something protected: salvage whatever is reachable underneath
        walk(path, into: &outcome)
        return outcome
    }

    private nonisolated static func walk(_ path: String, into outcome: inout Outcome) {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else {
            outcome.removed += 1   // gone meanwhile: a success, not a failure
            return
        }
        let isLink = (try? FileManager.default.destinationOfSymbolicLink(atPath: path)) != nil
        if isDirectory.boolValue, !isLink {
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: path) else {
                outcome.failed.append("\(Catalog.collapse(path)): can't be read")
                return
            }
            let before = outcome.failed.count
            for name in names { walk((path as NSString).appendingPathComponent(name), into: &outcome) }
            guard outcome.failed.count == before else { return }   // a folder with something left in it stays
        }
        do {
            try FileManager.default.removeItem(atPath: path)
            outcome.removed += 1
        } catch {
            outcome.failed.append("\(Catalog.collapse(path)): \(reason(error))")
        }
    }

    private nonisolated static func reason(_ error: Error) -> String {
        let code = (error as NSError).code
        switch code {
        case NSFileWriteNoPermissionError, Int(EACCES), Int(EPERM): return "no permission"
        case NSFileNoSuchFileError: return "already gone"
        default: return error.localizedDescription
        }
    }
}
