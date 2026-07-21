import Foundation

/// One-time copy of every nc.* key from the v1 placeholder defaults domain
/// (com.example.noteclarity) into this app's own domain after the bundle-id
/// change. Must run before anything reads UserDefaults.standard — hooked as
/// the first line of AppSettings.init, which every other consumer follows.
///
/// Application Support (session.json, Drafts, Plugins) is path-named
/// "NoteClarity", not bundle-id-derived, and needs no migration.
enum DefaultsMigration {
    private static let migratedKey = "nc.migratedFromComExample"
    private static let oldDomain = "com.example.noteclarity"
    /// Explicit list, not a wildcard: the old domain also holds Apple/AppKit
    /// keys (NSWindow frames etc.) that must not be blindly copied.
    private static let keysToMigrate = [
        "nc.appearance", "nc.useSystemAccent", "nc.fontName", "nc.fontSize",
        "nc.tabWidth", "nc.insertSpaces", "nc.defaultEncoding", "nc.defaultLineEnding",
        "nc.wordWrap", "nc.zoomPercent", "nc.autoReloadCleanDocuments",
        "nc.documentWordCompletionEnabled", "nc.documentWordAutoPopupEnabled",
        "nc.recentFiles",
        "nc.plugin.enabled", "nc.plugin.grants",
    ]

    static func runOnce() {
        let standard = UserDefaults.standard
        guard !standard.bool(forKey: migratedKey) else { return }
        defer { standard.set(true, forKey: migratedKey) }
        // Reading another bundle id's domain works for unsandboxed apps.
        guard let old = UserDefaults(suiteName: oldDomain) else { return }
        for key in keysToMigrate {
            guard standard.object(forKey: key) == nil,
                  let value = old.object(forKey: key) else { continue }
            standard.set(value, forKey: key)
        }
    }
}
