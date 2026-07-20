import AppKit

/// Line-number gutter for the TextKit 2 editor. Numbers one entry per paragraph
/// (wrapped continuation lines are unnumbered), with the caret's line accented.
final class LineNumberRulerView: NSRulerView {
    private weak var codeView: CodeTextView?
    private var lineStarts: [Int] = [0]
    private var currentLine = 0

    init(textView: CodeTextView, scrollView: NSScrollView) {
        codeView = textView
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = 46
    }

    required init(coder: NSCoder) {
        fatalError("LineNumberRulerView is never decoded")
    }

    func refresh(lineStarts: [Int], currentLine: Int) {
        self.lineStarts = lineStarts
        self.currentLine = currentLine
        let digits = max(3, String(lineStarts.count).count)
        let size = max(9, ((codeView?.font?.pointSize) ?? 13) * 0.82)
        let font = NSFont.monospacedDigitSystemFont(ofSize: size, weight: .regular)
        let charWidth = ("8" as NSString).size(withAttributes: [.font: font]).width
        let needed = ceil(CGFloat(digits) * charWidth) + 18
        if abs(needed - ruleThickness) > 0.5 { ruleThickness = needed }
        needsDisplay = true
    }

    /// Index of the line containing `offset` (largest start <= offset), binary search.
    static func lineIndex(for offset: Int, in starts: [Int]) -> Int {
        var lo = 0, hi = starts.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if starts[mid] <= offset { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        EditorTheme.gutterBackground.setFill()
        bounds.fill()
        EditorTheme.gutterText.withAlphaComponent(0.25).setFill()
        NSRect(x: bounds.maxX - 1, y: rect.minY, width: 1, height: rect.height).fill()

        guard let tv = codeView, let lm = tv.textLayoutManager else { return }

        let visible = tv.visibleRect
        let insetY = tv.textContainerInset.height
        let size = max(9, (tv.font?.pointSize ?? 13) * 0.82)
        let font = NSFont.monospacedDigitSystemFont(ofSize: size, weight: .regular)
        let normalAttrs: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: EditorTheme.gutterText,
        ]
        let currentAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: size, weight: .semibold),
            .foregroundColor: EditorTheme.accent,
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
            let line = Self.lineIndex(for: offset, in: self.lineStarts)
            guard line != lastDrawnLine else { return true }
            lastDrawnLine = line

            let attrs = line == self.currentLine ? currentAttrs : normalAttrs
            let label = "\(line + 1)" as NSString
            let labelSize = label.size(withAttributes: attrs)
            let firstLineHeight = frag.textLineFragments.first?.typographicBounds.height ?? frame.height
            let yInRuler = self.convert(NSPoint(x: 0, y: top), from: tv).y
            label.draw(at: NSPoint(x: self.bounds.maxX - labelSize.width - 9,
                                   y: yInRuler + (firstLineHeight - labelSize.height) / 2),
                       withAttributes: attrs)
            return true
        }
    }
}
