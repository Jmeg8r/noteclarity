import Foundation

/// Settings and data must select the same profile, before singleton startup.
/// A fresh verification run gets a child directory; it never deletes the
/// caller's directory (which may contain evidence from a previous run).
enum AppProfile {
    static let isIsolated = !(ProcessInfo.processInfo.environment["NOTECLARITY_SUPPORT_DIR"] ?? "").isEmpty
    static let isTesting = ProcessInfo.processInfo.environment["NOTECLARITY_TEST_MODE"] == "1"

    static let supportDirectory: URL = {
        let environment = ProcessInfo.processInfo.environment
        let root: URL
        if let override = environment["NOTECLARITY_SUPPORT_DIR"], !override.isEmpty {
            root = verificationDirectory(root: URL(fileURLWithPath: override, isDirectory: true),
                                         fresh: environment["NOTECLARITY_FRESH_SUPPORT"] == "1")
        } else {
            root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("NoteClarity", isDirectory: true)
        }
        do { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) }
        catch {
            if isIsolated { preconditionFailure("Could not create verification profile: \(error)") }
            // Editing still works without session storage. saveSession surfaces
            // the persistence failure, rather than crashing the production app.
            NSLog("[NoteClarity] Could not create support directory: %@", error.localizedDescription)
        }
        return root
    }()

    static func verificationDirectory(root: URL, fresh: Bool) -> URL {
        fresh ? root.appendingPathComponent("run-\(UUID().uuidString)", isDirectory: true) : root
    }

    static let defaults: PreferencesStore = {
        precondition(!isTesting || isIsolated, "Tests require NOTECLARITY_SUPPORT_DIR")
        guard isIsolated else { return UserDefaults.standard }
        do { return try ProfilePreferences(url: supportDirectory.appendingPathComponent("preferences.plist")) }
        catch { preconditionFailure("Could not read verification preferences: \(error)") }
    }()
}

protocol PreferencesStore {
    func object(forKey key: String) -> Any?
    func set(_ value: Any?, forKey key: String)
    func removeObject(forKey key: String)
}

extension UserDefaults: PreferencesStore {}

extension PreferencesStore {
    func string(forKey key: String) -> String? { object(forKey: key) as? String }
    func stringArray(forKey key: String) -> [String]? { object(forKey: key) as? [String] }
    func dictionary(forKey key: String) -> [String: Any]? { object(forKey: key) as? [String: Any] }
    func bool(forKey key: String) -> Bool { object(forKey: key) as? Bool ?? false }
}

/// Verification preferences stay entirely in the selected scratch profile.
/// They cannot inherit production recents or grants through defaults domains.
final class ProfilePreferences: PreferencesStore {
    private let url: URL
    private var values: [String: Any]

    init(url: URL) throws {
        self.url = url
        if FileManager.default.fileExists(atPath: url.path) {
            let data = try Data(contentsOf: url)
            guard let values = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
                throw CocoaError(.propertyListReadCorrupt)
            }
            self.values = values
        } else { values = [:] }
    }

    func object(forKey key: String) -> Any? { values[key] }

    func set(_ value: Any?, forKey key: String) {
        var next = values
        next[key] = value
        do {
            let data = try PropertyListSerialization.data(fromPropertyList: next, format: .binary, options: 0)
            try data.write(to: url, options: .atomic)
            values = next
        } catch { preconditionFailure("Could not persist verification preferences: \(error)") }
    }

    func removeObject(forKey key: String) { set(nil, forKey: key) }
}
