import SwiftUI
import AppKit

/// DESIGN.md type stack, one type DNA all the way down: Iosevka Term in the
/// buffer, Iosevka Aile in the chrome. The bundled faces load from
/// Resources/Fonts via ATSApplicationFontsPath; whenever they are absent the
/// documented fallback applies — SF Mono (editor) / SF Pro (chrome), never a
/// third family.
enum Typography {
    static let editorFamily = "Iosevka Term"
    static let chromeFamily = "Iosevka Aile"

    static func editorFont(size: CGFloat) -> NSFont {
        NSFont(name: editorFamily, size: size)
            ?? .monospacedSystemFont(ofSize: size, weight: .regular)
    }

    /// Chrome text for SwiftUI surfaces (tabs, status bar, labels, toasts).
    static func chrome(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        if NSFont(name: chromeFamily, size: size) != nil {
            return .custom(chromeFamily, size: size).weight(weight)
        }
        return .system(size: size, weight: weight)
    }
}
