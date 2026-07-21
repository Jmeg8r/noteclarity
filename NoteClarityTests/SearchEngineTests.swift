import XCTest
@testable import NoteClarity

final class SearchEngineTests: XCTestCase {

    private func ranges(of pattern: String, in text: String,
                        options: SearchOptions) throws -> [NSRange] {
        let regex = try SearchEngine.regex(for: pattern, options: options)
        return regex.matches(in: text, options: [],
                             range: NSRange(location: 0, length: (text as NSString).length))
            .map(\.range)
    }

    // MARK: Pattern building

    func testLiteralQueryIsEscaped() throws {
        var options = SearchOptions()
        options.useRegex = false
        XCTAssertEqual(try ranges(of: "a.b", in: "a.b axb", options: options),
                       [NSRange(location: 0, length: 3)])
    }

    func testWholeWordBoundaries() throws {
        var options = SearchOptions()
        options.wholeWord = true
        XCTAssertEqual(try ranges(of: "cat", in: "cat catalog concat", options: options),
                       [NSRange(location: 0, length: 3)])
    }

    func testCaseSensitivity() throws {
        var sensitive = SearchOptions()
        sensitive.caseSensitive = true
        XCTAssertEqual(try ranges(of: "Cat", in: "cat Cat", options: sensitive).count, 1)
        XCTAssertEqual(try ranges(of: "Cat", in: "cat Cat", options: SearchOptions()).count, 2)
    }

    // MARK: Zero-length navigation (P2-06)

    func testZeroLengthAnchorProgressesAndWraps() {
        // "^" on "a\nb\n" matches at 0, 2 and 4 (start of the empty last line).
        let matches = [NSRange(location: 0, length: 0),
                       NSRange(location: 2, length: 0),
                       NSRange(location: 4, length: 0)]
        let text = "a\nb\n" as NSString

        // First press from a plain caret selects the match under it…
        var target = SearchEngine.nextMatch(in: matches, caret: NSRange(location: 0, length: 0),
                                            backwards: false, afterZeroLengthAt: nil, text: text)
        XCTAssertEqual(target, matches[0])
        // …the second press must advance, not re-select (the stuck case).
        target = SearchEngine.nextMatch(in: matches, caret: NSRange(location: 0, length: 0),
                                        backwards: false, afterZeroLengthAt: 0, text: text)
        XCTAssertEqual(target, matches[1])
        target = SearchEngine.nextMatch(in: matches, caret: NSRange(location: 2, length: 0),
                                        backwards: false, afterZeroLengthAt: 2, text: text)
        XCTAssertEqual(target, matches[2])
        // At EOF the next press wraps to the first match.
        target = SearchEngine.nextMatch(in: matches, caret: NSRange(location: 4, length: 0),
                                        backwards: false, afterZeroLengthAt: 4, text: text)
        XCTAssertEqual(target, matches[0])
    }

    func testZeroLengthAdvanceRespectsComposedCharacters() {
        // "😀" is one composed character but two UTF-16 units; the step past a
        // zero-length match must not land inside the surrogate pair.
        let matches = [NSRange(location: 0, length: 0),
                       NSRange(location: 1, length: 0),
                       NSRange(location: 2, length: 0)]
        let text = "😀x" as NSString
        let target = SearchEngine.nextMatch(in: matches, caret: NSRange(location: 0, length: 0),
                                            backwards: false, afterZeroLengthAt: 0, text: text)
        XCTAssertEqual(target, matches[2], "must skip the mid-surrogate match at offset 1")
    }

    func testNonZeroSelectionAdvancesAndWraps() {
        let matches = [NSRange(location: 0, length: 3), NSRange(location: 5, length: 3)]
        let text = "abc  abc" as NSString
        var target = SearchEngine.nextMatch(in: matches, caret: NSRange(location: 0, length: 3),
                                            backwards: false, afterZeroLengthAt: nil, text: text)
        XCTAssertEqual(target, matches[1])
        target = SearchEngine.nextMatch(in: matches, caret: NSRange(location: 5, length: 3),
                                        backwards: false, afterZeroLengthAt: nil, text: text)
        XCTAssertEqual(target, matches[0])
    }

    func testBackwardsNavigation() {
        let matches = [NSRange(location: 0, length: 3), NSRange(location: 5, length: 3)]
        let text = "abc  abc" as NSString
        var target = SearchEngine.nextMatch(in: matches, caret: NSRange(location: 5, length: 3),
                                            backwards: true, afterZeroLengthAt: nil, text: text)
        XCTAssertEqual(target, matches[0])
        target = SearchEngine.nextMatch(in: matches, caret: NSRange(location: 0, length: 0),
                                        backwards: true, afterZeroLengthAt: nil, text: text)
        XCTAssertEqual(target, matches[1], "backwards from the top wraps to the last match")
    }

    func testEmptyMatchListReturnsNil() {
        XCTAssertNil(SearchEngine.nextMatch(in: [], caret: NSRange(location: 0, length: 0),
                                            backwards: false, afterZeroLengthAt: nil, text: ""))
    }
}
