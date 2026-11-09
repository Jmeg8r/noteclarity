import XCTest
import Darwin
@testable import NoteClarity

final class ProfileAndRecoveryTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("nc-recovery-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    func testPreferencesPersistOnlyInChosenProfile() throws {
        let file = root.appendingPathComponent("settings.plist")
        let preferences = try ProfilePreferences(url: file)
        XCTAssertNil(preferences.object(forKey: "nc.recentFiles"))
        preferences.set(["synthetic.txt"], forKey: "nc.recentFiles")
        let store = PluginGrantStore(defaults: preferences)
        let grant = PluginGrant(permissions: ["storage"], identity: "fixture")
        store.setGrant(grant, for: "test")
        let reopened = try ProfilePreferences(url: file)
        XCTAssertEqual(reopened.stringArray(forKey: "nc.recentFiles"), ["synthetic.txt"])
        XCTAssertEqual(PluginGrantStore(defaults: reopened).grant(for: "test"), grant)
        let unrelated = try ProfilePreferences(url: root.appendingPathComponent("other.plist"))
        XCTAssertNil(unrelated.object(forKey: "nc.recentFiles"))
        XCTAssertNil(PluginGrantStore(defaults: unrelated).grant(for: "test"))
    }

    func testFreshProfilePreservesExistingEvidence() throws {
        let sentinel = root.appendingPathComponent("session.json")
        try Data("keep".utf8).write(to: sentinel)
        let first = AppProfile.verificationDirectory(root: root, fresh: true)
        let second = AppProfile.verificationDirectory(root: root, fresh: true)
        XCTAssertNotEqual(first, second)
        XCTAssertNotEqual(first, root)
        XCTAssertEqual(try String(contentsOf: sentinel, encoding: .utf8), "keep")
    }

    func testHostedTestProfileDoesNotUseProductionIdentity() {
        XCTAssertTrue(AppProfile.isIsolated)
        XCTAssertTrue(AppProfile.isTesting)
        XCTAssertTrue(AppProfile.defaults is ProfilePreferences)
        XCTAssertNotEqual(Bundle.main.bundleIdentifier, "com.jmeg8r.noteclarity",
                          "Run Scripts/test.sh so AppKit's own preferences are isolated too")
    }

    func testOrphanDraftSurvivesCleanupAcrossLaunches() throws {
        let orphan = root.appendingPathComponent("old-draft.txt")
        try "irreplaceable".write(to: orphan, atomically: true, encoding: .utf8)
        let backups = DraftBackups(directory: root)
        try backups.write("active", named: "active.txt")
        try backups.prune(keeping: [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("active.txt").path))
        XCTAssertEqual(try String(contentsOf: orphan, encoding: .utf8), "irreplaceable")
        try DraftBackups(directory: root).prune(keeping: [])
        XCTAssertEqual(try String(contentsOf: orphan, encoding: .utf8), "irreplaceable")
    }

    func testUnreadableDraftIsNotPruned() throws {
        let damaged = root.appendingPathComponent("damaged.txt")
        try Data([0xFF, 0xC0]).write(to: damaged)
        let backups = DraftBackups(directory: root)
        XCTAssertThrowsError(try backups.read("damaged.txt"))
        try backups.prune(keeping: [])
        XCTAssertEqual(try Data(contentsOf: damaged), Data([0xFF, 0xC0]))
        XCTAssertThrowsError(try backups.read("../other.txt"))
    }

    func testSessionSaveDoesNotPruneUnreferencedRecoveryDraft() throws {
        let directory = AppState.supportDirectory.appendingPathComponent("Drafts")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let draft = directory.appendingPathComponent("orphan-\(UUID().uuidString).txt")
        try "recovery".write(to: draft, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: draft) }
        AppState.shared.saveSession()
        XCTAssertEqual(try String(contentsOf: draft, encoding: .utf8), "recovery")
    }

    func testTextReadBoundsAndSpecialFileRejection() throws {
        let file = root.appendingPathComponent("sample.txt")
        try Data("12345".utf8).write(to: file)
        XCTAssertEqual(try TextFileReader.read(file, limit: 5), Data("12345".utf8))
        XCTAssertThrowsError(try TextFileReader.read(file, limit: 4))
        XCTAssertThrowsError(try TextFileReader.read(root))
        let fifo = root.appendingPathComponent("fifo")
        XCTAssertEqual(fifo.path.withCString { mkfifo($0, 0o600) }, 0)
        XCTAssertThrowsError(try TextFileReader.read(fifo), "FIFO must fail without waiting for a writer")
    }

    func testInvalidJavaScriptOffsetsCannotTrap() {
        for value in [Double.nan, .infinity, -.infinity, 1e100, -1e100, 1.5, Double(Int.max)] {
            XCTAssertNil(PluginInstance.editorOffset(value))
        }
        XCTAssertEqual(PluginInstance.editorOffset(0), 0)
        XCTAssertEqual(PluginInstance.editorOffset(-1), -1)
        XCTAssertEqual(PluginInstance.editorOffset(42), 42)
    }
}
