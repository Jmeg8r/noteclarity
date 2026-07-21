import AppKit

/// Line-number gutter for the TextKit 2 editor. Numbers one entry per paragraph
/// (wrapped continuation lines are unnumbered), with the caret's line accented.
/// Also draws line markers — bookmark dots and changed-line bars — and toggles
/// bookmarks on click.
final class LineNumberRulerView: NSRulerView {
    private weak var codeView: CodeTextView?
    private var lineStarts: [Int] = [0]
    private var currentLine = 0
    private var lineMarkers = LineMarkers()

    /// Fixed extra column so bookmark dots never overlap the numbers.
    static let markerGutterWidth: CGFloat = 14
    /// Width of the changed-line bar at the gutter's leading edge.
    static let changeBarWidth: CGFloat = 3

    var onGutterClick: ((Int) -> Void)?

    init(textView: CodeTextView, scrollView: NSScrollView) {
        codeView = textView
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = 46 + Self.markerGutterWidth
    }

    required init(coder: NSCoder) {
        fatalError("LineNumberRulerView is never decoded")
    }

    func refresh(lineStarts: [Int], currentLine: Int, markers: LineMarkers) {
        self.lineStarts = lineStarts
        self.currentLine = currentLine
        self.lineMarkers = markers
        let digits = max(3, String(lineStarts.count).count)
        let size = max(9, ((codeView?.font?.pointSize) ?? 13) * 0.82)
        let font = NSFont.monospacedDigitSystemFont(ofSize: size, weight: .regular)
        let charWidth = ("8" as NSString).size(withAttributes: [.font: font]).width
        let needed = ceil(CGFloat(digits) * charWidth) + 18 + Self.markerGutterWidth
        if abs(needed - ruleThickness) > 0.5 { ruleThickness = needed }
        needsDisplay = true
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        EditorTheme.gutterBackground.setFill()
        bounds.fill()
        // DESIGN.md: hairline right edge — the shared Hairline token, not an
        // ad-hoc alpha of the text color.
        EditorTheme.hairline.setFill()
        NSRect(x: bounds.maxX - 1, y: rect.minY, width: 1, height: rect.height).fill()

        guard let tv = codeView, let lm = tv.textLayoutManager else { return }

        let visible = tv.visibleRect
        let insetY = tv.textContainerInset.height
        let size = max(9, (tv.font?.pointSize ?? 13) * 0.82)
        let font = NSFont.monospacedDigitSystemFont(ofSize: size, weight: .regular)
        let normalAttrs: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: EditorTheme.gutterText,
        ]
        // DESIGN.md: the current line's number renders in EditorText (green is
        // reserved for caret/active-tab/saved/focus signals, not the gutter).
        let currentAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: size, weight: .semibold),
            .foregroundColor: EditorTheme.text,
        ]

        let startLocation = lm.textViewportLayoutController.viewportRange?.location
            ?? lm.documentRange.location
        var lastDrawnLine = -1

        lm.enumerateTextLayoutFragments(from: startLocation, options: [.ensuresLayout]) { frag in
            let frame = frag.layoutFragmentFrame
            let top = frame.minY + insetY
            if top > visible.maxY { return false }
            if frame.maxY + insetY < visible.minY { return true }

            let offset = lm.offset(from: lm.documentRange.location, to: frag.rangeInElement.location)
            let line = LineIndex.of(offset, in: self.lineStarts)
            guard line != lastDrawnLine else { return true }
            lastDrawnLine = line

            let firstLineHeight = frag.textLineFragments.first?.typographicBounds.height ?? frame.height
            let yInRuler = self.convert(NSPoint(x: 0, y: top), from: tv).y

            if self.lineMarkers.changedUnsaved.contains(line) || self.lineMarkers.changedSaved.contains(line) {
                let color = self.lineMarkers.changedUnsaved.contains(line)
                    ? EditorTheme.changedUnsaved : EditorTheme.changedSaved
                color.setFill()
                NSRect(x: 0, y: yInRuler, width: Self.changeBarWidth, height: firstLineHeight).fill()
            }
            if self.lineMarkers.bookmarks.contains(line) {
                EditorTheme.bookmark.setFill()
                let d: CGFloat = 7
                NSBezierPath(ovalIn: NSRect(x: Self.changeBarWidth + 3,
                                            y: yInRuler + (firstLineHeight - d) / 2,
                                            width: d, height: d)).fill()
            }

            let attrs = line == self.currentLine ? currentAttrs : normalAttrs
            let label = "\(line + 1)" as NSString
            let labelSize = label.size(withAttributes: attrs)
            label.draw(at: NSPoint(x: self.bounds.maxX - labelSize.width - 9,
                                   y: yInRuler + (firstLineHeight - labelSize.height) / 2),
                       withAttributes: attrs)
            return true
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard let tv = codeView, let lm = tv.textLayoutManager else {
            super.mouseDown(with: event)
            return
        }
        let localPoint = convert(event.locationInWindow, from: nil)
        var pointInText = convert(localPoint, to: tv)
        pointInText.y -= tv.textContainerInset.height
        guard let frag = lm.textLayoutFragment(for: pointInText) else { return }
        let offset = lm.offset(from: lm.documentRange.location, to: frag.rangeInElement.location)
        onGutterClick?(LineIndex.of(offset, in: lineStarts))
    }
}
