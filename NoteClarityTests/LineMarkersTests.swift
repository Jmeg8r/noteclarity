import XCTest
@testable import NoteClarity

/// Marker-shift regression coverage. Base fixture: "aaa\nbbb\nccc\n" with
/// line starts [0, 4, 8, 12]. Inputs mirror what `didProcessEditing` supplies:
/// pre-edit line starts, post-edit-coordinate edited range, and the new-text
/// newline facts.
final class LineMarkersTests: XCTestCase {
    private let baseStarts = [0, 4, 8, 12]

    func testInsertLineAboveShiftsMarkersDown() {
        var markers = LineMarkers()
        markers.bookmarks = [1]
        markers.changedSaved = [2]
        // Insert "X\n" at offset 0.
        markers.applyEdit(oldLineStarts: baseStarts,
                          editedRange: NSRange(location: 0, length: 2),
                          delta: 2, newNewlines: 1, newTextEndsWithNewline: true)
        XCTAssertEqual(markers.bookmarks, [2])
        XCTAssertEqual(markers.changedSaved, [3])
        XCTAssertEqual(markers.changedUnsaved, [0])
    }

    func testDeleteWholeLineKeepsPositionAnchoredMarker() {
        var markers = LineMarkers()
        markers.bookmarks = [1]
        // Delete "bbb\n" (old range {4,4} → edited {4,0}, delta -4).
        markers.applyEdit(oldLineStarts: baseStarts,
                          editedRange: NSRange(location: 4, length: 0),
                          delta: -4, newNewlines: 0, newTextEndsWithNewline: false)
        // Position-anchored semantics: the marker stays on "the line that
        // starts where this line used to start" (deliberate Notepad++ parity).
        XCTAssertEqual(markers.bookmarks, [1])
        XCTAssertEqual(markers.changedUnsaved, [1])
    }

    func testDeleteLineShiftsLaterMarkersUp() {
        var markers = LineMarkers()
        markers.bookmarks = [2]
        markers.applyEdit(oldLineStarts: baseStarts,
                          editedRange: NSRange(location: 4, length: 0),
                          delta: -4, newNewlines: 0, newTextEndsWithNewline: false)
        XCTAssertEqual(markers.bookmarks, [1])
    }

    func testMultiLineReplacementDropsInsideAndShiftsAfter() {
        var markers = LineMarkers()
        markers.bookmarks = [1, 2]
        // Replace "aaa\nbbb" ({0,7}) with "Z" → edited {0,1}, delta -6.
        markers.applyEdit(oldLineStarts: baseStarts,
                          editedRange: NSRange(location: 0, length: 1),
                          delta: -6, newNewlines: 0, newTextEndsWithNewline: false)
        // Line 1 (inside the merged span) is dropped; line 2 shifts up by one.
        XCTAssertEqual(markers.bookmarks, [1])
        XCTAssertEqual(markers.changedUnsaved, [0])
    }

    func testSingleLineEditKeepsThatLinesMarker() {
        var markers = LineMarkers()
        markers.bookmarks = [1]
        // Type one character inside "bbb" ({5,1}, delta 1).
        markers.applyEdit(oldLineStarts: baseStarts,
                          editedRange: NSRange(location: 5, length: 1),
                          delta: 1, newNewlines: 0, newTextEndsWithNewline: false)
        XCTAssertEqual(markers.bookmarks, [1])
        XCTAssertEqual(markers.changedUnsaved, [1])
    }

    func testMarkSavedPromotesUnsavedAndKeepsBookmarks() {
        var markers = LineMarkers()
        markers.bookmarks = [3]
        markers.changedUnsaved = [0, 1]
        markers.changedSaved = [5]
        markers.markSaved()
        XCTAssertEqual(markers.changedSaved, [0, 1, 5])
        XCTAssertTrue(markers.changedUnsaved.isEmpty)
        XCTAssertEqual(markers.bookmarks, [3])
    }
}
