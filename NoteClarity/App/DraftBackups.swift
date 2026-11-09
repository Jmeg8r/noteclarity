import Foundation

/// Only drafts successfully read or written in this session may be pruned.
/// Unreferenced files can be the only surviving copies after a corrupt session
/// index. Keep them for recovery, including across later clean launches.
final class DraftBackups {
    let directory: URL
    private var managed = Set<String>()

    init(directory: URL) { self.directory = directory }

    private func url(for name: String) throws -> URL {
        guard !name.isEmpty, name == (name as NSString).lastPathComponent,
              name.hasSuffix(".txt"),
              let url = PluginPathPolicy.containedURL(root: directory, relative: name)
        else { throw CocoaError(.fileReadInvalidFileName) }
        return url
    }

    func read(_ name: String) throws -> String {
        let text = try String(contentsOf: url(for: name), encoding: .utf8)
        managed.insert(name)
        return text
    }

    func write(_ text: String, named name: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try text.write(to: url(for: name), atomically: true, encoding: .utf8)
        managed.insert(name)
    }

    /// Call only after the new session index has committed successfully.
    func prune(keeping names: Set<String>) throws {
        for name in managed.subtracting(names) {
            let target = try url(for: name)
            if FileManager.default.fileExists(atPath: target.path) {
                try FileManager.default.removeItem(at: target)
            }
            managed.remove(name)
        }
    }
}
