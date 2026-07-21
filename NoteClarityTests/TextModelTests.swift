import XCTest
@testable import NoteClarity

/// Table-driven coverage of the exact-encoding contract (P1-04): decode
/// diagnostics, byte-preserving fallbacks, binary detection, and
/// exact-or-nil encoding with byte round-trips.
final class TextModelTests: XCTestCase {

    // MARK: Decode — clean paths

    func testStrictUTF8Decodes() {
        let decoded = FileEncoding.decode(Data("héllo\n".utf8))
        XCTAssertEqual(decoded.text, "héllo\n")
        XCTAssertEqual(decoded.encoding, .utf8)
        XCTAssertFalse(decoded.hadDecodingErrors)
        XCTAssertFalse(decoded.looksBinary)
    }

    func testUTF8BOMDecodes() {
        let decoded = FileEncoding.decode(Data([0xEF, 0xBB, 0xBF]) + Data("hi".utf8))
        XCTAssertEqual(decoded.text, "hi")
        XCTAssertEqual(decoded.encoding, .utf8bom)
        XCTAssertFalse(decoded.hadDecodingErrors)
    }

    func testUTF16BOMsDecode() {
        let le = FileEncoding.decode(Data([0xFF, 0xFE]) + "hi".data(using: .utf16LittleEndian)!)
        XCTAssertEqual(le.text, "hi")
        XCTAssertEqual(le.encoding, .utf16le)
        let be = FileEncoding.decode(Data([0xFE, 0xFF]) + "hi".data(using: .utf16BigEndian)!)
        XCTAssertEqual(be.text, "hi")
        XCTAssertEqual(be.encoding, .utf16be)
    }

    func testBOMlessUTF16ASCIIDetected() {
        // ASCII UTF-16 is byte-valid UTF-8 (every other byte NUL); the parity
        // heuristic must win or the file opens as NUL-riddled UTF-8 and the
        // next save silently converts it.
        let le = FileEncoding.decode("hello".data(using: .utf16LittleEndian)!)
        XCTAssertEqual(le.text, "hello")
        XCTAssertEqual(le.encoding, .utf16le)
        XCTAssertFalse(le.looksBinary)
        let be = FileEncoding.decode("hello".data(using: .utf16BigEndian)!)
        XCTAssertEqual(be.text, "hello")
        XCTAssertEqual(be.encoding, .utf16be)
    }

    func testBOMlessUTF16NonASCIIDetected() {
        let decoded = FileEncoding.decode("héllo wörld".data(using: .utf16LittleEndian)!)
        XCTAssertEqual(decoded.text, "héllo wörld")
        XCTAssertEqual(decoded.encoding, .utf16le)
    }

    func testLatin1Fallback() {
        let decoded = FileEncoding.decode(Data([0x63, 0x61, 0x66, 0xE9]))   // "café" in Latin-1
        XCTAssertEqual(decoded.text, "café")
        XCTAssertEqual(decoded.encoding, .latin1)
        XCTAssertFalse(decoded.hadDecodingErrors)
    }

    func testEmptyData() {
        let decoded = FileEncoding.decode(Data())
        XCTAssertEqual(decoded.text, "")
        XCTAssertEqual(decoded.encoding, .utf8)
        XCTAssertFalse(decoded.hadDecodingErrors)
        XCTAssertFalse(decoded.looksBinary)
    }

    // MARK: Decode — diagnostics

    func testMalformedUTF8BOMBodyIsFlagged() {
        let decoded = FileEncoding.decode(Data([0xEF, 0xBB, 0xBF, 0xFF]))
        XCTAssertEqual(decoded.encoding, .utf8bom)
        XCTAssertTrue(decoded.hadDecodingErrors)
        XCTAssertFalse(decoded.text.isEmpty, "recovery must never yield an empty string")
    }

    func testBrokenUTF16BOMFallsBackBytePreserving() {
        let original = Data([0xFF, 0xFE, 0x41])   // LE BOM + odd-length body
        let decoded = FileEncoding.decode(original)
        XCTAssertTrue(decoded.hadDecodingErrors)
        XCTAssertEqual(decoded.encoding, .latin1)
        // Latin-1 is a bijective byte map: an untouched buffer must round-trip
        // the original bytes exactly.
        XCTAssertEqual(decoded.encoding.encodeExact(decoded.text), original)
    }

    func testBinaryDetectionOnNULFreeControlDensity() {
        let decoded = FileEncoding.decode(Data(repeating: 0x01, count: 100))
        XCTAssertTrue(decoded.looksBinary)
    }

    func testBinaryDetectionOnPNGHeader() {
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D])
        let decoded = FileEncoding.decode(png)
        XCTAssertTrue(decoded.looksBinary)
    }

    func testANSILogIsNotBinary() {
        let ansi = "\u{1B}[31mred\u{1B}[0m plain text with\ttabs\n"
        XCTAssertFalse(FileEncoding.looksBinary(Data(ansi.utf8)))
    }

    // MARK: Encode — exact or nil

    func testEncodeExactLatin1RejectsUnmappable() {
        XCTAssertNotNil(FileEncoding.latin1.encodeExact("héllo"))
        XCTAssertNil(FileEncoding.latin1.encodeExact("hi 🙂"))
    }

    func testEncodeLossyLatin1AlwaysProduces() {
        XCTAssertNotNil(FileEncoding.latin1.encodeLossy("hi 🙂"))
    }

    func testRoundTripsPreserveTextAndEncoding() {
        // (encoding, text chosen so detection re-identifies the encoding)
        let cases: [(FileEncoding, String)] = [
            (.utf8, "plain ascii\n"),
            (.utf8, "unicode 🙂 text\n"),
            (.utf8bom, "with bom\n"),
            (.utf16le, "sixteen le\n"),
            (.utf16be, "sixteen be\n"),
            (.latin1, "café au lait\n"),
        ]
        for (encoding, text) in cases {
            guard let data = encoding.encodeExact(text) else {
                XCTFail("\(encoding) failed to encode \(text)"); continue
            }
            let decoded = FileEncoding.decode(data)
            XCTAssertEqual(decoded.text, text, "\(encoding) round-trip text")
            XCTAssertEqual(decoded.encoding, encoding, "\(encoding) round-trip detection")
            XCTAssertFalse(decoded.hadDecodingErrors)
        }
    }

    func testUTF16EncodesCarryBOM() {
        XCTAssertEqual(Array(FileEncoding.utf16le.encodeExact("A")!.prefix(2)), [0xFF, 0xFE])
        XCTAssertEqual(Array(FileEncoding.utf16be.encodeExact("A")!.prefix(2)), [0xFE, 0xFF])
        XCTAssertEqual(Array(FileEncoding.utf8bom.encodeExact("A")!.prefix(3)), [0xEF, 0xBB, 0xBF])
    }

    // MARK: Line endings

    func testEOLDetection() {
        XCTAssertEqual(LineEnding.detect(in: "a\r\nb\r\n", default: .lf), .crlf)
        XCTAssertEqual(LineEnding.detect(in: "a\nb", default: .crlf), .lf)
        XCTAssertEqual(LineEnding.detect(in: "a\rb", default: .lf), .cr)
        XCTAssertEqual(LineEnding.detect(in: "a\r\nb\nc\n", default: .crlf), .lf)   // majority
        XCTAssertEqual(LineEnding.detect(in: "no endings", default: .crlf), .crlf)  // default
    }

    func testEOLNormalizeAndSerialize() {
        XCTAssertEqual(LineEnding.normalizeToLF("a\r\nb\rc\nd"), "a\nb\nc\nd")
        XCTAssertEqual(LineEnding.crlf.serialize("a\nb"), "a\r\nb")
        XCTAssertEqual(LineEnding.cr.serialize("a\nb"), "a\rb")
        XCTAssertEqual(LineEnding.lf.serialize("a\nb"), "a\nb")
    }

    func testEOLRoundTrip() {
        for eol in LineEnding.allCases {
            let buffer = "one\ntwo\nthree"
            XCTAssertEqual(LineEnding.normalizeToLF(eol.serialize(buffer)), buffer, "\(eol)")
        }
    }

    // MARK: SemVer

    func testSemVerParsing() {
        XCTAssertEqual(SemVer.parse("v2.1.0"), [2, 1, 0])
        XCTAssertEqual(SemVer.parse("2.1"), [2, 1, 0])
        XCTAssertEqual(SemVer.parse("2.1.0-beta+5"), [2, 1, 0])
        XCTAssertNil(SemVer.parse("garbage"))
        XCTAssertNil(SemVer.parse(""))
    }

    func testSemVerComparison() {
        XCTAssertTrue(SemVer.isNewer("2.0.1", than: "2.0.0"))
        XCTAssertTrue(SemVer.isNewer("v3", than: "2.9.9"))
        XCTAssertFalse(SemVer.isNewer("2.0.0", than: "2.0.0"))
        XCTAssertFalse(SemVer.isNewer("1.9.9", than: "2.0.0"))
        XCTAssertFalse(SemVer.isNewer("garbage", than: "1.0"))
    }

    // MARK: Word completion + line index

    func testWordCompletionMatching() {
        let cache = ["prefix", "PREface", "pre", "xpre"]
        XCTAssertEqual(WordCompletion.matches(for: "pre", in: cache), ["prefix", "PREface"])
        XCTAssertEqual(WordCompletion.matches(for: "", in: cache), [])
    }

    func testLineIndexLookup() {
        let starts = [0, 4, 8, 12]
        XCTAssertEqual(LineIndex.of(0, in: starts), 0)
        XCTAssertEqual(LineIndex.of(3, in: starts), 0)
        XCTAssertEqual(LineIndex.of(4, in: starts), 1)
        XCTAssertEqual(LineIndex.of(11, in: starts), 2)
        XCTAssertEqual(LineIndex.of(100, in: starts), 3)
    }
}
