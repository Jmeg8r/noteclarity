import AppKit

struct EditorStatus {
    var line = 1
    var column = 1
    var selectionChars = 0
    var selectionLines = 0
    var totalChars = 0
    var lineCount = 1
    var words = 0
}

/// Owns one document's complete AppKit editing stack (scroll view, TextKit 2 text
/// view, line-number ruler). One controller per open tab, so undo history, caret,
/// and scroll position survive tab switches for free.
final class EditorController: NSObject {
    let textView: CodeTextView
    let scrollView: NSScrollView
    let ruler: LineNumberRulerView
    unowned let document: Document

    /// UTF-16 offsets of every line start; rebuilt on each character edit and
    /// shared by the ruler, status bar, and symbol jumps.
    private(set) var lineStarts: [Int] = [0]
    /// Bumped on every character edit; guards stale async highlight results.
    private(set) var generation = 0

    var onEdit: (() -> Void)?
    var onSelectionChange: (() -> Void)?

    /// True while text is being set programmatically (initial load, session
    /// restore) so the edit callback doesn't mark the document dirty.
    private var suppressEditCallbacks = false

    /// Documents beyond this size skip token coloring to stay responsive.
    static let highlightSizeLimit = 1_500_000

    init(document: Document, initialText: String) {
        self.document = document
        let tv = CodeTextView(usingTextLayoutManager: true)
        textView = tv
        scrollView = NSScrollView()
        ruler = LineNumberRulerView(textView: tv, scrollView: scrollView)
        super.init()

        tv.isRichText = false
        tv.importsGraphics = false
        tv.usesFontPanel = false
        tv.allowsUndo = true
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.isAutomaticLinkDetectionEnabled = false
        tv.isAutomaticDataDetectionEnabled = false
        tv.isContinuousSpellCheckingEnabled = false
        tv.isGrammarCheckingEnabled = false
        tv.smartInsertDeleteEnabled = false
        tv.drawsBackground = true
        tv.backgroundColor = EditorTheme.background
        tv.textContainerInset = NSSize(width: 0, height: 6)
        tv.isVerticallyResizable = true
        tv.minSize = NSSize(width: 0, height: 0)
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.autoresizingMask = [.width]

        scrollView.documentView = tv
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = EditorTheme.background
        scrollView.hasVerticalRuler = true
        scrollView.verticalRulerView = ruler
        scrollView.rulersVisible = true

        tv.delegate = self
        tv.textStorage?.delegate = self

        suppressEditCallbacks = true
        tv.string = initialText
        suppressEditCallbacks = false
        recomputeLineStarts()

        ruler.onGutterClick = { [weak self] line in
            self?.toggleBookmark(atLine: line)
        }
    }

    // MARK: Text access

    var text: String { textView.string }

    var caretOffset: Int { textView.selectedRange().location }

    var utf16Length: Int { (textView.string as NSString).length }

    /// Non-undoable full replacement for initial load / session restore.
    func setTextProgrammatic(_ s: String) {
        suppressEditCallbacks = true
        textView.string = s
        suppressEditCallbacks = false
        textView.undoManager?.removeAllActions()
        generation += 1
        // A full-buffer replacement has no diffable old/new line correspondence;
        // stale marker indices would silently point at the wrong content.
        document.lineMarkers = LineMarkers()
        recomputeLineStarts()
        highlightNow()
    }

    /// Undoable replacement routed through the standard NSTextView change pipeline.
    func replaceRangeUndoable(_ range: NSRange, with s: String) {
        let clamped = NSIntersectionRange(range, NSRange(location: 0, length: utf16Length))
        guard textView.shouldChangeText(in: clamped, replacementString: s) else { return }
        textView.textStorage?.replaceCharacters(in: clamped, with: s)
        textView.didChangeText()
    }

    func replaceAllUndoable(_ s: String) {
        replaceRangeUndoable(NSRange(location: 0, length: utf16Length), with: s)
    }

    func jump(to offset: Int, length: Int = 0) {
        let total = utf16Length
        let loc = max(0, min(offset, total))
        let len = max(0, min(length, total - loc))
        let range = NSRange(location: loc, length: len)
        textView.setSelectedRange(range)
        textView.scrollRangeToVisible(range)
        textView.window?.makeFirstResponder(textView)
    }

    // MARK: Configuration

    func applySettings(_ settings: AppSettings) {
        let font = settings.editorNSFont
        textView.font = font
        textView.insertSpacesForTab = settings.insertSpaces
        textView.tabWidth = settings.tabWidth
        textView.insertionPointColor = settings.accentNSColor

        let paragraph = NSMutableParagraphStyle()
        let charWidth = ("0" as NSString).size(withAttributes: [.font: font]).width
        paragraph.defaultTabInterval = charWidth * CGFloat(max(1, settings.tabWidth))
        paragraph.tabStops = []
        textView.defaultParagraphStyle = paragraph
        textView.typingAttributes = [
            .font: font,
            .foregroundColor: EditorTheme.text,
            .paragraphStyle: paragraph,
        ]

        if let storage = textView.textStorage {
            let full = NSRange(location: 0, length: storage.length)
            storage.beginEditing()
            storage.addAttribute(.font, value: font, range: full)
            storage.addAttribute(.paragraphStyle, value: paragraph, range: full)
            storage.endEditing()
        }
        setWordWrap(settings.wordWrap)
        ruler.refresh(lineStarts: lineStarts, currentLine: status().line - 1,
                      markers: document.lineMarkers)
    }

    func setWordWrap(_ wrap: Bool) {
        guard let container = textView.textContainer else { return }
        if wrap {
            textView.isHorizontallyResizable = false
            container.widthTracksTextView = true
            container.size = NSSize(width: scrollView.contentSize.width,
                                    height: CGFloat.greatestFiniteMagnitude)
            textView.frame.size.width = scrollView.contentSize.width
            textView.autoresizingMask = [.width]
        } else {
            container.widthTracksTextView = false
            container.size = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                    height: CGFloat.greatestFiniteMagnitude)
            textView.isHorizontallyResizable = true
            textView.autoresizingMask = []
        }
        textView.needsLayout = true
    }

    // MARK: Status

    func status() -> EditorStatus {
        var s = EditorStatus()
        let sel = textView.selectedRange()
        s.totalChars = utf16Length
        s.lineCount = lineStarts.count
        let lineIdx = LineIndex.of(sel.location, in: lineStarts)
        s.line = lineIdx + 1
        s.column = sel.location - lineStarts[lineIdx] + 1
        s.selectionChars = sel.length
        if sel.length > 0 {
            let endIdx = LineIndex.of(max(sel.location, NSMaxRange(sel) - 1), in: lineStarts)
            s.selectionLines = endIdx - lineIdx + 1
        }
        return s
    }

    // MARK: Bookmarks

    var onBookmarksChanged: (() -> Void)?

    func toggleBookmark(atLine line: Int) {
        guard line >= 0, line < lineStarts.count else { return }
        if document.lineMarkers.bookmarks.contains(line) {
            document.lineMarkers.bookmarks.remove(line)
        } else {
            document.lineMarkers.bookmarks.insert(line)
        }
        ruler.refresh(lineStarts: lineStarts, currentLine: status().line - 1,
                      markers: document.lineMarkers)
        onBookmarksChanged?()
    }

    // MARK: Line starts

    private func recomputeLineStarts() {
        let ns = textView.string as NSString
        var starts = [0]
        var search = NSRange(location: 0, length: ns.length)
        while true {
            let r = ns.range(of: "\n", options: [], range: search)
            if r.location == NSNotFound { break }
            starts.append(r.location + 1)
            search = NSRange(location: r.location + 1, length: ns.length - r.location - 1)
        }
        lineStarts = starts
    }

    // MARK: Highlighting

    func highlightNow() {
        guard utf16Length <= Self.highlightSizeLimit else {
            applySpans([])
            return
        }
        let gen = generation
        let snapshot = textView.string
        let language = document.language
        DispatchQueue.global(qos: .userInitiated).async {
            let spans = HighlighterRegistry.highlighter(for: language).highlight(snapshot)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == gen else { return }
                self.applySpans(spans)
            }
        }
    }

    private func applySpans(_ spans: [HighlightSpan]) {
        guard let storage = textView.textStorage else { return }
        let full = NSRange(location: 0, length: storage.length)
        storage.beginEditing()
        storage.addAttribute(.foregroundColor, value: EditorTheme.text, range: full)
        for span in spans where NSMaxRange(span.range) <= storage.length {
            storage.addAttribute(.foregroundColor,
                                 value: EditorTheme.tokenColor(span.token),
                                 range: span.range)
        }
        storage.endEditing()
    }
}

// MARK: - Delegates

extension EditorController: NSTextViewDelegate, NSTextStorageDelegate {

    func textStorage(_ textStorage: NSTextStorage,
                     didProcessEditing editedMask: NSTextStorageEditActions,
                     range editedRange: NSRange,
                     changeInLength delta: Int) {
        guard editedMask.contains(.editedCharacters) else { return }
        generation += 1
        // Captured synchronously: the flag is only true for the duration of a
        // programmatic set, but the reaction below runs on the next runloop turn.
        let suppressed = suppressEditCallbacks
        if !suppressed {
            // Must run synchronously: lineStarts still holds PRE-edit offsets
            // here (recomputed only in the deferred block below), which is
            // exactly what the marker math needs. Mutating a plain struct is
            // fine — the "illegal in the edit pass" rule covers layout and
            // attribute mutation only.
            let ns = textStorage.string as NSString
            let newNewlines = Self.newlineCount(in: ns, range: editedRange)
            let endsWithNewline = editedRange.length > 0
                && ns.character(at: NSMaxRange(editedRange) - 1) == 0x0A
            document.lineMarkers.applyEdit(oldLineStarts: lineStarts,
                                           editedRange: editedRange,
                                           delta: delta,
                                           newNewlines: newNewlines,
                                           newTextEndsWithNewline: endsWithNewline)
        }
        // Deferred: mutating layout/attributes inside the edit pass is illegal.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.recomputeLineStarts()
            if !suppressed { self.onEdit?() }
        }
    }

    private static func newlineCount(in ns: NSString, range: NSRange) -> Int {
        guard range.length > 0 else { return 0 }
        var count = 0
        var search = range
        while true {
            let r = ns.range(of: "\n", options: [], range: search)
            if r.location == NSNotFound { break }
            count += 1
            let next = r.location + 1
            let remaining = NSMaxRange(range) - next
            if remaining <= 0 { break }
            search = NSRange(location: next, length: remaining)
        }
        return count
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        textView.needsDisplay = true
        onSelectionChange?()
    }

    func undoManager(for view: NSTextView) -> UndoManager? {
        document.undoManager
    }
}
