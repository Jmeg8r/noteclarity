import AppKit

/// TextKit 2 code editor view. Adds overwrite (OVR) mode, current-line
/// highlighting, spaces-for-tab insertion, and CRLF-normalizing paste.
///
/// No initializers are declared so the class inherits
/// `init(usingTextLayoutManager:)` and always builds a TextKit 2 stack.
final class CodeTextView: NSTextView {

    var overwriteMode = false {
        didSet { if oldValue != overwriteMode { onOverwriteModeChange?() } }
    }
    var onOverwriteModeChange: (() -> Void)?

    var highlightCurrentLine = true
    var insertSpacesForTab = true
    var tabWidth = 4

    var autocompleteEnabled = false
    var autoPopupEnabled = false
    private let autoPopupDebouncer = Debouncer(0.35)

    // MARK: Completion

    /// The gate lives here, not in the key handler: `complete(_:)` is also
    /// AppKit's own binding for bare Escape, so gating only ⌥Esc would let
    /// the popup through with the feature off.
    override func complete(_ sender: Any?) {
        guard autocompleteEnabled else { return }
        super.complete(sender)
    }

    // MARK: Overwrite mode

    override func insertText(_ string: Any, replacementRange: NSRange) {
        var repl = replacementRange
        if overwriteMode,
           repl.location == NSNotFound,
           let s = string as? String, !s.isEmpty, !s.contains("\n"),
           selectedRange().length == 0 {
            let loc = selectedRange().location
            let ns = self.string as NSString
            if loc < ns.length {
                let next = ns.rangeOfComposedCharacterSequence(at: loc)
                let c = ns.character(at: loc)
                // Never overwrite the line break; typing at end-of-line inserts.
                if c != 10 && c != 13 {
                    repl = NSRange(location: loc, length: next.length)
                }
            }
        }
        super.insertText(string, replacementRange: repl)

        // Auto-popup rides the typing chokepoint (paste never triggers it).
        if autocompleteEnabled, autoPopupEnabled,
           let s = string as? String, s.count == 1,
           let scalar = s.unicodeScalars.first,
           CharacterSet.alphanumerics.contains(scalar) || scalar == "_" {
            autoPopupDebouncer.call { [weak self] in self?.complete(nil) }
        }
    }

    override func keyDown(with event: NSEvent) {
        // 114 is the Insert/Help key; classic Notepad++ overwrite toggle.
        if event.keyCode == 114 {
            overwriteMode.toggle()
            return
        }
        // 53 is Escape; ⌥Esc triggers word completion. Every other Escape
        // combination falls through to AppKit (incl. popup dismissal).
        if event.keyCode == 53,
           event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .option {
            complete(nil)
            return
        }
        super.keyDown(with: event)
    }

    // MARK: Tabs

    override func insertTab(_ sender: Any?) {
        guard insertSpacesForTab, tabWidth > 0 else {
            super.insertTab(sender)
            return
        }
        let sel = selectedRange()
        let ns = string as NSString
        let lineStart = ns.lineRange(for: NSRange(location: min(sel.location, ns.length), length: 0)).location
        let column = sel.location - lineStart
        let count = tabWidth - (column % tabWidth)
        insertText(String(repeating: " ", count: count), replacementRange: sel)
    }

    // MARK: Paste

    override func paste(_ sender: Any?) {
        // Keep the buffer LF-only even when the clipboard carries CRLF/CR text.
        if let s = NSPasteboard.general.string(forType: .string), s.contains("\r") {
            insertText(LineEnding.normalizeToLF(s), replacementRange: selectedRange())
            return
        }
        super.paste(sender)
    }

    // MARK: Current line highlight

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard highlightCurrentLine,
              selectedRange().length == 0,
              let lm = textLayoutManager
        else { return }

        let caret = selectedRange().location
        guard let caretLocation = lm.location(lm.documentRange.location, offsetBy: caret) else { return }

        var fragment: NSTextLayoutFragment?
        lm.enumerateTextLayoutFragments(from: caretLocation, options: [.ensuresLayout]) { frag in
            fragment = frag
            return false
        }
        guard let frag = fragment else { return }

        var lineRect = frag.layoutFragmentFrame
        // Narrow the highlight to the caret's visual line within a wrapped paragraph.
        let fragStart = lm.offset(from: lm.documentRange.location, to: frag.rangeInElement.location)
        let local = caret - fragStart
        let lineFragments = frag.textLineFragments
        for (i, lf) in lineFragments.enumerated() {
            let r = lf.characterRange
            let isLast = i == lineFragments.count - 1
            if local >= r.location && (local < r.location + r.length || (isLast && local <= r.location + r.length)) {
                lineRect = lf.typographicBounds.offsetBy(dx: frag.layoutFragmentFrame.minX,
                                                         dy: frag.layoutFragmentFrame.minY)
                break
            }
        }

        let draw = NSRect(x: 0,
                          y: lineRect.minY + textContainerInset.height,
                          width: bounds.width,
                          height: lineRect.height)
        guard draw.intersects(rect) else { return }
        EditorTheme.currentLine.setFill()
        draw.fill()
    }
}
