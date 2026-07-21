import XCTest
@testable import NoteClarity

/// Boundary coverage for the plugin policy layer (P1-02/P1-03): ID charset,
/// symlink-resolved containment, manifest validation, identity digests, and
/// the identity-bound grant store.
final class PluginPolicyTests: XCTestCase {
    private var fixtureRoot: URL!

    override func setUpWithError() throws {
        fixtureRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("nc-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: fixtureRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: fixtureRoot)
    }

    // MARK: ID charset

    func testValidIDs() {
        for id in ["com.example.docstats", "a", "A9", "a_b-c.d9", "x.y_z-1"] {
            XCTAssertTrue(PluginPathPolicy.isValidID(id), id)
        }
    }

    func testInvalidIDs() {
        let overlong = String(repeating: "a", count: PluginPathPolicy.maxIDLength + 1)
        for id in ["", ".", ".a", "a.", "-a", "a-", "a..b", "../../../../target",
                   "a/b", "a\\b", "a b", "é", "a\u{0}b", overlong] {
            XCTAssertFalse(PluginPathPolicy.isValidID(id), id)
        }
    }

    func testMaxLengthIDAccepted() {
        XCTAssertTrue(PluginPathPolicy.isValidID(String(repeating: "a", count: PluginPathPolicy.maxIDLength)))
    }

    // MARK: Containment

    func testRelativePathInsideRootIsAllowed() throws {
        let sub = fixtureRoot.appendingPathComponent("sub", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try "x".write(to: sub.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
        let url = PluginPathPolicy.containedURL(root: fixtureRoot, relative: "sub/file.txt")
        XCTAssertNotNil(url)
        XCTAssertEqual(try String(contentsOf: url!, encoding: .utf8), "x")
    }

    func testTraversalAndAbsolutePathsAreRefused() {
        XCTAssertNil(PluginPathPolicy.containedURL(root: fixtureRoot, relative: "../escape.txt"))
        XCTAssertNil(PluginPathPolicy.containedURL(root: fixtureRoot, relative: "a/../../escape.txt"))
        XCTAssertNil(PluginPathPolicy.containedURL(root: fixtureRoot, relative: "/etc/hosts"))
        XCTAssertNil(PluginPathPolicy.containedURL(root: fixtureRoot, relative: ""))
    }

    func testSymlinkEscapingRootIsRefused() throws {
        // outside/secret.txt  +  root/link -> outside
        let outside = fixtureRoot.appendingPathComponent("outside", isDirectory: true)
        let root = fixtureRoot.appendingPathComponent("root", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "secret".write(to: outside.appendingPathComponent("secret.txt"),
                           atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link"),
                                                   withDestinationURL: outside)
        XCTAssertNil(PluginPathPolicy.containedURL(root: root, relative: "link/secret.txt"),
                     "a symlink planted inside the plugin folder must not reach outside it")
    }

    func testSymlinkStayingInsideRootIsAllowed() throws {
        let root = fixtureRoot.appendingPathComponent("root", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "inside".write(to: root.appendingPathComponent("real.txt"),
                           atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("alias.txt"),
                                                   withDestinationURL: root.appendingPathComponent("real.txt"))
        XCTAssertNotNil(PluginPathPolicy.containedURL(root: root, relative: "alias.txt"))
    }

    // MARK: Manifest validation

    private func makeManifest(id: String = "com.example.test",
                              apiVersion: String = "1.0",
                              main: String = "main.js",
                              permissions: [String]? = ["editor.read"],
                              contributes: PluginManifest.Contributes? = nil) -> PluginManifest {
        PluginManifest(id: id, name: "Test", version: "1.0.0", apiVersion: apiVersion,
                       author: nil, description: nil, main: main,
                       permissions: permissions, contributes: contributes)
    }

    private func makePluginDir(mainName: String = "main.js") throws -> URL {
        let dir = fixtureRoot.appendingPathComponent("plugin-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "{}".write(to: dir.appendingPathComponent("plugin.json"), atomically: true, encoding: .utf8)
        try "// main".write(to: dir.appendingPathComponent(mainName), atomically: true, encoding: .utf8)
        return dir
    }

    func testValidManifestPasses() throws {
        let dir = try makePluginDir()
        let result = PluginManifestValidator.validate(makeManifest(), directory: dir)
        guard case .success(let validated) = result else {
            return XCTFail("expected success, got \(result)")
        }
        XCTAssertEqual(validated.mainURL.lastPathComponent, "main.js")
    }

    func testTraversalIDRejected() throws {
        let dir = try makePluginDir()
        let result = PluginManifestValidator.validate(
            makeManifest(id: "../../../../target"), directory: dir)
        guard case .failure(let failure) = result else { return XCTFail("expected failure") }
        XCTAssertTrue(failure.problems.contains { $0.contains("invalid plugin id") })
    }

    func testEscapingMainRejected() throws {
        let dir = try makePluginDir()
        for main in ["../outside.js", "/etc/hosts", "missing.js"] {
            let result = PluginManifestValidator.validate(makeManifest(main: main), directory: dir)
            guard case .failure = result else { return XCTFail("expected failure for \(main)") }
        }
    }

    func testUnsupportedAPIVersionRejected() throws {
        let dir = try makePluginDir()
        for version in ["2.0", "1.5", "banana", ""] {
            let result = PluginManifestValidator.validate(
                makeManifest(apiVersion: version), directory: dir)
            guard case .failure = result else { return XCTFail("expected failure for \(version)") }
        }
    }

    func testUnknownPermissionRejected() throws {
        let dir = try makePluginDir()
        let result = PluginManifestValidator.validate(
            makeManifest(permissions: ["editor.read", "root.everything"]), directory: dir)
        guard case .failure(let failure) = result else { return XCTFail("expected failure") }
        XCTAssertTrue(failure.problems.contains { $0.contains("root.everything") })
    }

    func testMenuReferencingUndeclaredCommandRejected() throws {
        let dir = try makePluginDir()
        let contributes = PluginManifest.Contributes(
            commands: [.init(id: "a.real", title: "Real")],
            menus: [.init(command: "a.ghost", location: "plugins")],
            panels: nil)
        let result = PluginManifestValidator.validate(
            makeManifest(contributes: contributes), directory: dir)
        guard case .failure(let failure) = result else { return XCTFail("expected failure") }
        XCTAssertTrue(failure.problems.contains { $0.contains("a.ghost") })
    }

    func testDuplicateCommandIDsRejected() throws {
        let dir = try makePluginDir()
        let contributes = PluginManifest.Contributes(
            commands: [.init(id: "dup", title: "One"), .init(id: "dup", title: "Two")],
            menus: nil, panels: nil)
        let result = PluginManifestValidator.validate(
            makeManifest(contributes: contributes), directory: dir)
        guard case .failure = result else { return XCTFail("expected failure") }
    }

    // MARK: Identity digest

    func testDigestChangesWithContent() {
        let a = PluginIdentity.digest(manifestData: Data("m1".utf8), mainData: Data("j1".utf8))
        let b = PluginIdentity.digest(manifestData: Data("m1".utf8), mainData: Data("j2".utf8))
        let c = PluginIdentity.digest(manifestData: Data("m1".utf8), mainData: Data("j1".utf8))
        XCTAssertEqual(a.count, 64)
        XCTAssertNotEqual(a, b)
        XCTAssertEqual(a, c)
    }

    // MARK: Grant store

    func testGrantRoundTripAndRemoval() throws {
        let suite = "nc.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = PluginGrantStore(defaults: defaults)

        XCTAssertNil(store.grant(for: "x"))
        let grant = PluginGrant(permissions: ["editor.read", "ui.panel"], identity: "abc")
        store.setGrant(grant, for: "x")
        XCTAssertEqual(store.grant(for: "x"), grant)
        store.removeGrant(for: "x")
        XCTAssertNil(store.grant(for: "x"))
    }

    func testLegacyAdoptionConsumesV1Entry() throws {
        let suite = "nc.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(["old.plugin": ["editor.read"]], forKey: PluginGrantStore.legacyKey)
        let store = PluginGrantStore(defaults: defaults)

        XCTAssertEqual(store.legacyPermissions(for: "old.plugin"), ["editor.read"])
        let adopted = store.adoptLegacyGrant(for: "old.plugin",
                                             permissions: ["editor.read"],
                                             identity: "digest1")
        XCTAssertEqual(adopted.identity, "digest1")
        XCTAssertEqual(store.grant(for: "old.plugin"), adopted)
        XCTAssertNil(store.legacyPermissions(for: "old.plugin"),
                     "adoption must consume the v1 entry so it cannot re-run against different bytes")
    }

    // MARK: net.fetch scheme gate

    func testFetchURLAllowlist() {
        XCTAssertTrue(PluginInstance.isAllowedFetchURL(URL(string: "https://example.com/x")!))
        XCTAssertTrue(PluginInstance.isAllowedFetchURL(URL(string: "http://localhost:3000/api")!))
        XCTAssertTrue(PluginInstance.isAllowedFetchURL(URL(string: "http://127.0.0.1:8080/")!))
        XCTAssertFalse(PluginInstance.isAllowedFetchURL(URL(string: "http://example.com/x")!))
        XCTAssertFalse(PluginInstance.isAllowedFetchURL(URL(string: "file:///etc/hosts")!))
        XCTAssertFalse(PluginInstance.isAllowedFetchURL(URL(string: "ftp://example.com")!))
    }
}
