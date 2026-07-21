import SwiftUI
import AppKit

enum AppearanceMode: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
}

/// UserDefaults-backed app settings. Plain @Published + didSet persistence keeps
/// change propagation deterministic (AppState re-applies editor config on any change).
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    private enum K {
        static let appearance = "nc.appearance"
        static let useSystemAccent = "nc.useSystemAccent"
        static let fontName = "nc.fontName"
        static let fontSize = "nc.fontSize"
        static let tabWidth = "nc.tabWidth"
        static let insertSpaces = "nc.insertSpaces"
        static let defaultEncoding = "nc.defaultEncoding"
        static let defaultLineEnding = "nc.defaultLineEnding"
        static let wordWrap = "nc.wordWrap"
        static let zoomPercent = "nc.zoomPercent"
        static let autoReloadCleanDocuments = "nc.autoReloadCleanDocuments"
        static let documentWordCompletionEnabled = "nc.documentWordCompletionEnabled"
        static let documentWordAutoPopupEnabled = "nc.documentWordAutoPopupEnabled"
    }

    static let minZoom = 25
    static let maxZoom = 400
    static let zoomStep = 10

    @Published var appearance: AppearanceMode { didSet { save(); apply() } }
    @Published var useSystemAccent: Bool { didSet { save() } }
    /// Empty string means the system monospaced font (SF Mono).
    @Published var fontName: String { didSet { save() } }
    @Published var fontSize: Double { didSet { save() } }
    @Published var tabWidth: Int { didSet { save() } }
    @Published var insertSpaces: Bool { didSet { save() } }
    @Published var defaultEncoding: FileEncoding { didSet { save() } }
    @Published var defaultLineEnding: LineEnding { didSet { save() } }
    @Published var wordWrap: Bool { didSet { save() } }
    @Published var zoomPercent: Int { didSet { save() } }
    /// Documents with no unsaved changes silently reload when their file
    /// changes on disk (Xcode/VS Code convention); dirty documents always prompt.
    @Published var autoReloadCleanDocuments: Bool { didSet { save() } }
    /// Notepad++-style document-word completion (⌥Esc). Off by default, like
    /// Notepad++ itself — opinionated behavior in a plaintext-first editor.
    @Published var documentWordCompletionEnabled: Bool { didSet { save() } }
    @Published var documentWordAutoPopupEnabled: Bool { didSet { save() } }

    private init() {
        // Must precede every UserDefaults read; AppState's stored
        // `settings = AppSettings.shared` guarantees this runs before
        // AppState.init touches recents or plugin maps.
        DefaultsMigration.runOnce()
        let d = UserDefaults.standard
        appearance = AppearanceMode(rawValue: d.string(forKey: K.appearance) ?? "") ?? .system
        useSystemAccent = d.object(forKey: K.useSystemAccent) as? Bool ?? false
        fontName = d.string(forKey: K.fontName) ?? ""
        fontSize = d.object(forKey: K.fontSize) as? Double ?? 13
        tabWidth = min(16, max(1, d.object(forKey: K.tabWidth) as? Int ?? 4))
        insertSpaces = d.object(forKey: K.insertSpaces) as? Bool ?? true
        defaultEncoding = FileEncoding(rawValue: d.string(forKey: K.defaultEncoding) ?? "") ?? .utf8
        defaultLineEnding = LineEnding(rawValue: d.string(forKey: K.defaultLineEnding) ?? "") ?? .lf
        wordWrap = d.object(forKey: K.wordWrap) as? Bool ?? true
        zoomPercent = min(Self.maxZoom, max(Self.minZoom, d.object(forKey: K.zoomPercent) as? Int ?? 100))
        autoReloadCleanDocuments = d.object(forKey: K.autoReloadCleanDocuments) as? Bool ?? true
        documentWordCompletionEnabled = d.object(forKey: K.documentWordCompletionEnabled) as? Bool ?? false
        documentWordAutoPopupEnabled = d.object(forKey: K.documentWordAutoPopupEnabled) as? Bool ?? false
    }

    private func save() {
        let d = UserDefaults.standard
        d.set(appearance.rawValue, forKey: K.appearance)
        d.set(useSystemAccent, forKey: K.useSystemAccent)
        d.set(fontName, forKey: K.fontName)
        d.set(fontSize, forKey: K.fontSize)
        d.set(tabWidth, forKey: K.tabWidth)
        d.set(insertSpaces, forKey: K.insertSpaces)
        d.set(defaultEncoding.rawValue, forKey: K.defaultEncoding)
        d.set(defaultLineEnding.rawValue, forKey: K.defaultLineEnding)
        d.set(wordWrap, forKey: K.wordWrap)
        d.set(zoomPercent, forKey: K.zoomPercent)
        d.set(autoReloadCleanDocuments, forKey: K.autoReloadCleanDocuments)
        d.set(documentWordCompletionEnabled, forKey: K.documentWordCompletionEnabled)
        d.set(documentWordAutoPopupEnabled, forKey: K.documentWordAutoPopupEnabled)
    }

    func apply() {
        NSApp.appearance = appearance.nsAppearance
    }

    func zoomIn() { zoomPercent = min(Self.maxZoom, zoomPercent + Self.zoomStep) }
    func zoomOut() { zoomPercent = max(Self.minZoom, zoomPercent - Self.zoomStep) }
    func zoomReset() { zoomPercent = 100 }

    var accentNSColor: NSColor {
        useSystemAccent ? .controlAccentColor : EditorTheme.accent
    }

    var accentColor: Color {
        useSystemAccent ? Color(nsColor: .controlAccentColor) : Color("NppGreen")
    }

    var editorNSFont: NSFont {
        let size = max(6, fontSize * Double(zoomPercent) / 100.0)
        if fontName.isEmpty {
            return .monospacedSystemFont(ofSize: size, weight: .regular)
        }
        return NSFont(name: fontName, size: size) ?? .monospacedSystemFont(ofSize: size, weight: .regular)
    }

    /// Installed font families whose regular face is fixed-pitch, for the Settings picker.
    static let monospacedFamilies: [String] = {
        let fm = NSFontManager.shared
        return fm.availableFontFamilies.filter { family in
            guard !family.hasPrefix("."),
                  let font = fm.font(withFamily: family, traits: [], weight: 5, size: 12)
            else { return false }
            return font.isFixedPitch
        }.sorted()
    }()
}
