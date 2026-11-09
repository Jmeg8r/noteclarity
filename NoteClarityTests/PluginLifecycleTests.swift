import XCTest
import JavaScriptCore
@testable import NoteClarity

private final class SuspendedRequest: URLProtocol {
    static var started: (() -> Void)?
    static var stopped: (() -> Void)?
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "fixture.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { Self.started?() }
    override func stopLoading() { Self.stopped?() }
}

final class PluginLifecycleTests: XCTestCase {
    private var root: URL!
    private var manager: PluginManager!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("nc-plugin-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        manager = PluginManager()
    }

    override func tearDownWithError() throws {
        SuspendedRequest.started = nil
        SuspendedRequest.stopped = nil
        try FileManager.default.removeItem(at: root)
        manager = nil
    }

    private func plugin(source: String = "", permissions: Set<String>) throws -> PluginInstance {
        let main = root.appendingPathComponent("main.js")
        try source.write(to: main, atomically: true, encoding: .utf8)
        let manifest = PluginManifest(id: "nc.fixture.\(UUID().uuidString)", name: "Fixture", version: "1", apiVersion: "1.0",
                                      author: nil, description: nil, main: "main.js",
                                      permissions: permissions.sorted(), contributes: nil)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SuspendedRequest.self]
        return PluginInstance(manifest: manifest, directory: root, mainURL: main,
                              granted: permissions, manager: manager, networkConfiguration: configuration)
    }

    func testUnloadCancelsRequestAndDoesNotResumePluginPromise() throws {
        let started = expectation(description: "request started")
        let stopped = expectation(description: "request cancelled")
        SuspendedRequest.started = { started.fulfill() }
        SuspendedRequest.stopped = { stopped.fulfill() }
        let instance = try plugin(permissions: ["network"])
        try instance.load()
        let context = try XCTUnwrap(instance.context)
        context.evaluateScript("var completed = false; noteclarity.net.fetch('https://fixture.invalid/').then(() => completed = true, () => completed = true);")
        wait(for: [started], timeout: 2)
        instance.unload()
        wait(for: [stopped], timeout: 2)
        let settled = expectation(description: "cancel callback drained")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { settled.fulfill() }
        wait(for: [settled], timeout: 1)
        XCTAssertNil(instance.context)
        XCTAssertFalse(context.evaluateScript("completed")!.toBool())
    }

    func testActualJavaScriptCursorAPIRejectsInvalidNumbersWithoutCrashing() throws {
        let instance = try plugin(permissions: ["editor.write"])
        try instance.load()
        defer { instance.unload() }
        let context = try XCTUnwrap(instance.context)
        for number in ["NaN", "Infinity", "-Infinity", "1e100", "1.5"] {
            for call in ["setCursor(\(number))", "insertAt(\(number), 'x')"] {
                XCTAssertEqual(context.evaluateScript("try { noteclarity.editor.\(call); 'bad'; } catch(e) { 'rejected'; }")?.toString(), "rejected")
            }
        }
    }

    func testUnreadablePluginStorageDoesNotBecomeAnEmptyWritableCache() throws {
        let instance = try plugin(permissions: ["storage"])
        let storage = PluginManager.pluginDataDirectory.appendingPathComponent("\(instance.manifest.id).json")
        try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: storage) }
        try instance.load()
        defer { instance.unload() }
        let context = try XCTUnwrap(instance.context)
        for call in ["get('x')", "set('x', 1)"] {
            XCTAssertEqual(context.evaluateScript("try { noteclarity.storage.\(call); 'bad'; } catch(e) { 'rejected'; }")?.toString(), "rejected")
        }
        XCTAssertTrue(try storage.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true)
    }

    func testActivationFailureRollsBackCommands() throws {
        let instance = try plugin(source: "function activate() { noteclarity.commands.register('x', () => {}); throw new Error('fixture'); }",
                                  permissions: ["commands"])
        XCTAssertThrowsError(try instance.load())
        XCTAssertNil(instance.context)
        XCTAssertTrue(instance.commandCallbacks.isEmpty)
    }

    func testDisposingOldPanelHandleKeepsReplacement() throws {
        let instance = try plugin(permissions: ["ui.panel"])
        try instance.load()
        defer { instance.unload() }
        let context = try XCTUnwrap(instance.context)
        context.evaluateScript("var old = noteclarity.ui.registerPanel({id:'same', title:'Old', location:'right', html:'<p>Old</p>'});")
        context.evaluateScript("var current = noteclarity.ui.registerPanel({id:'same', title:'New', location:'right', html:'<p>New</p>'}); old.dispose();")
        XCTAssertEqual(instance.panels["same"]?.title, "New")
    }

    func testShippedPluginEntrypointsLoadInJavaScriptCore() throws {
        let resources = try XCTUnwrap(Bundle.main.resourceURL).appendingPathComponent("BundledPlugins")
        for id in ["com.example.docstats", "com.example.jsonformatter", "com.example.markdownpreview"] {
            let directory = resources.appendingPathComponent(id)
            let manifest = try JSONDecoder().decode(PluginManifest.self,
                from: Data(contentsOf: directory.appendingPathComponent("plugin.json")))
            let instance = PluginInstance(manifest: manifest, directory: directory,
                mainURL: directory.appendingPathComponent(manifest.main),
                granted: Set(manifest.permissions ?? []), manager: manager)
            try instance.load()
            let context = try XCTUnwrap(instance.context)
            if id == "com.example.docstats" {
                XCTAssertEqual(context.evaluateScript("countText('one two').words")?.toInt32(), 2)
            } else if id == "com.example.markdownpreview" {
                XCTAssertEqual(context.evaluateScript("markdownToHtml('# Hello')")?.toString(), "<h1>Hello</h1>")
                XCTAssertNil(context.exception)
            } else {
                XCTAssertEqual(instance.commandCallbacks.count, 3)
            }
            instance.unload()
        }
    }
}
