import AppKit

enum TokenType: String, CaseIterable {
    case keyword, string, comment, number, type, function, tag, key
}

/// All editor colors come from the asset catalog so light/dark adapt automatically;
/// system-color fallbacks only guard against a missing catalog entry.
enum EditorTheme {
    private static func color(_ name: String, _ fallback: NSColor) -> NSColor {
        NSColor(named: name) ?? fallback
    }

    static var background: NSColor { color("EditorBackground", .textBackgroundColor) }
    static var text: NSColor { color("EditorText", .textColor) }
    static var currentLine: NSColor { color("EditorCurrentLine", .quaternaryLabelColor) }
    static var chromeSurface: NSColor { color("ChromeSurface", .windowBackgroundColor) }
    static var textMuted: NSColor { color("TextMuted", .secondaryLabelColor) }
    static var hairline: NSColor { color("Hairline", .separatorColor) }
    static var gutterBackground: NSColor { color("GutterBackground", .windowBackgroundColor) }
    static var gutterText: NSColor { color("GutterText", .secondaryLabelColor) }
    static var accent: NSColor { color("NppGreen", .controlAccentColor) }
    static var changedUnsaved: NSColor { color("EditorChangedUnsaved", .systemOrange) }
    static var changedSaved: NSColor { color("EditorChangedSaved", .systemGreen) }
    static var bookmark: NSColor { color("EditorBookmark", .systemBlue) }

    static func tokenColor(_ token: TokenType) -> NSColor {
        switch token {
        case .keyword: return color("TokenKeyword", .systemBlue)
        case .string: return color("TokenString", .systemRed)
        case .comment: return color("TokenComment", .systemGreen)
        case .number: return color("TokenNumber", .systemOrange)
        case .type: return color("TokenType", .systemTeal)
        case .function: return color("TokenFunction", .systemBrown)
        case .tag: return color("TokenTag", .systemPurple)
        case .key: return color("TokenKey", .systemIndigo)
        }
    }
}
