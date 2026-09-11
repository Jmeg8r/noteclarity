import XCTest
import JavaScriptCore
@testable import NoteClarity

final class IntegrityRegressionTests: XCTestCase {
    func testMalformedUTF8RetainsEveryOriginalByte() {
        let original = Data([0xEF, 0xBB, 0xBF, 0x61, 0xFF, 0xC0])
        let decoded = FileEncoding.decode(original)
        XCTAssertTrue(decoded.hadDecodingErrors)
        XCTAssertEqual(decoded.encoding.encodeExact(decoded.text), original)
    }

    func testLatin1MapsEveryByteExactly() throws {
        let bytes = Data(0...255)
        let text = String(String.UnicodeScalarView(bytes.map { UnicodeScalar(Int($0))! }))
        XCTAssertEqual(FileEncoding.latin1.encodeExact(text), bytes)
    }

    func testProgrammaticEditMarksDirtyBeforeReturning() {
        let doc = Document(url: nil, text: "first", encoding: .utf8, lineEnding: .lf, language: .plaintext)
        let editor = EditorController(document: doc, initialText: doc.pendingText)
        doc.controller = editor
        editor.replaceAllUndoable("unsaved")
        XCTAssertTrue(doc.isDirty, "closing in the same run-loop must prompt to save")
    }

    func testTwoEditsInOneRunLoopKeepLineIndexCurrent() {
        let doc = Document(url: nil, text: "a\nb\nc", encoding: .utf8, lineEnding: .lf, language: .plaintext)
        let editor = EditorController(document: doc, initialText: doc.pendingText)
        doc.controller = editor
        doc.lineMarkers.bookmarks = [2]
        editor.replaceRangeUndoable(NSRange(location: 0, length: 0), with: "x\n")
        editor.replaceRangeUndoable(NSRange(location: 0, length: 0), with: "y\n")
        XCTAssertEqual(editor.lineStarts, [0, 2, 4, 6, 8])
        XCTAssertEqual(doc.lineMarkers.bookmarks, [4])
    }

    func testPluginStorageFailureRetainsCommittedCache() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let id = "nc.test.\(UUID().uuidString)"
        let main = root.appendingPathComponent("main.js")
        try "".write(to: main, atomically: true, encoding: .utf8)
        let manifest = PluginManifest(id: id, name: "Test", version: "1", apiVersion: "1.0",
                                      author: nil, description: nil, main: "main.js",
                                      permissions: ["storage"], contributes: nil)
        let manager = PluginManager()
        let plugin = PluginInstance(manifest: manifest, directory: root, mainURL: main,
                                    granted: ["storage"], manager: manager)
        try plugin.load()
        defer { plugin.unload() }
        let context = try XCTUnwrap(plugin.context)
        context.evaluateScript("noteclarity.storage.set('key', 'committed')")
        let storage = PluginManager.pluginDataDirectory.appendingPathComponent("\(id).json")
        let backup = root.appendingPathComponent("original.json")
        try FileManager.default.moveItem(at: storage, to: backup)
        try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: storage) }
        XCTAssertEqual(context.evaluateScript("try { noteclarity.storage.set('key', 'failed'); 'bad' } catch(e) { 'rejected' }")?.toString(), "rejected")
        XCTAssertEqual(context.evaluateScript("noteclarity.storage.get('key')")?.toString(), "committed")
    }
}
