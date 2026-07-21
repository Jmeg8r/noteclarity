import Foundation

/// Per-document line-index marker state: user bookmarks plus Notepad++-style
/// changed-line tracking (orange = edited since the last save, green = edited
/// earlier this session and since saved).
///
/// Markers are position-anchored, not content-anchored: a marker tracks "the
/// line that starts where this line used to start," not "my original text
/// wherever it moves." Undo re-runs `applyEdit` like any forward edit, so a
/// dropped marker does not return — deliberate Notepad++ parity.
///
/// Foundation-only on purpose: the whole type stays compilable with plain
/// `swiftc` for the standalone assert battery.
struct LineMarkers {
    var bookmarks: Set<Int> = []
    var changedUnsaved: Set<Int> = []
    var changedSaved: Set<Int> = []

    /// Reconcile all three sets for one text edit. Must run synchronously in
    /// `didProcessEditing`, while the controller's `lineStarts` still holds
    /// PRE-edit offsets and the storage already holds post-edit text.
    ///
    /// - Parameters:
    ///   - oldLineStarts: line-start table from before the edit.
    ///   - editedRange: post-edit-coordinate edited range from NSTextStorage.
    ///   - delta: changeInLength for that edit.
    ///   - newNewlines: count of "\n" inside `editedRange` in the new text.
    ///   - newTextEndsWithNewline: whether the new range's last character is
    ///     "\n" (false for empty ranges). An edit ending exactly on a line
    ///     boundary did not touch the following line's content.
    ///
    /// Line-count math uses newline counts, NOT touched-line spans: a deletion
    /// whose range ends exactly on a newline removes more line boundaries than
    /// it touches lines, and span arithmetic mis-shifts everything after it.
    mutating func applyEdit(oldLineStarts: [Int], editedRange: NSRange, delta: Int,
                            newNewlines: Int, newTextEndsWithNewline: Bool) {
        let loc = editedRange.location
        let oldLen = editedRange.length - delta
        let touchedFirst = LineIndex.of(loc, in: oldLineStarts)
        let touchedLast = LineIndex.of(max(loc, loc + oldLen - 1), in: oldLineStarts)
        // Newlines the old text in this range contained: one per line start
        // inside (loc, loc + oldLen].
        var oldNewlines = 0
        for start in oldLineStarts where start > loc && start <= loc + oldLen {
            oldNewlines += 1
        }
        let netDelta = newNewlines - oldNewlines
        let singleLine = touchedFirst == touchedLast

        func shift(_ set: Set<Int>) -> Set<Int> {
            var result = Set<Int>(minimumCapacity: set.count)
            for line in set {
                if line < touchedFirst {
                    result.insert(line)
                } else if line > touchedLast {
                    result.insert(line + netDelta)
                } else if singleLine {
                    // Editing within one line never drops that line's marker,
                    // even if the edit split it into several lines.
                    result.insert(touchedFirst)
                }
                // else: inside a multi-line span — boundaries merged, no
                // non-arbitrary surviving line; dropped.
            }
            return result
        }

        bookmarks = shift(bookmarks)
        changedSaved = shift(changedSaved)
        changedUnsaved = shift(changedUnsaved)

        // Mark the lines the new text occupies as changed-unsaved. An edit
        // ending exactly at a line start leaves the following line untouched.
        var lastChanged = touchedFirst + newNewlines
        if newTextEndsWithNewline { lastChanged -= 1 }
        for line in touchedFirst...max(touchedFirst, lastChanged) {
            changedUnsaved.insert(line)
            changedSaved.remove(line)
        }
    }

    /// On a successful save every unsaved-changed line becomes saved-changed.
    /// Bookmarks are not save-state and are untouched.
    mutating func markSaved() {
        changedSaved.formUnion(changedUnsaved)
        changedUnsaved.removeAll()
    }
}
