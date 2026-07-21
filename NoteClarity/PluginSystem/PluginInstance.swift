import Foundation
import AppKit
import JavaScriptCore

/// One loaded plugin: an isolated `JSContext` running the plugin's `main.js`,
/// with the `noteclarity` Host API injected. The bridge is built from
/// `@convention(block)` closures assigned onto plain JS objects so the JS-side
/// names match `noteclarity.d.ts` exactly.
///
/// Threading: all plugin JavaScript executes on the main thread; async work
/// (dialogs, network) resolves Promises back on main.
final class PluginInstance {
    let manifest: PluginManifest
    let directory: URL
    /// Validated entry point resolved by `PluginManifestValidator` — never
    /// derived from raw manifest text here (P1-02).
    let mainURL: URL
    let granted: Set<String>
    unowned let manager: PluginManager

    private(set) var context: JSContext?
    private(set) var commandCallbacks: [String: JSValue] = [:]
    private var eventListeners: [String: [JSValue]] = [:]
    private(set) var panels: [String: PanelController] = [:]
    private(set) var dynamicMenuItems: [PluginMenuItem] = []

    /// First exception raised while `load()` is on the stack; makes top-level
    /// and activate() failures deterministic load errors instead of toasts (P2-04).
    private var loadPhaseException: String?
    private var isLoading = false

    private var storageCache: [String: Any]?
    private var storageURL: URL {
        // The ID passed manifest validation (bounded, separator-free charset),
        // so it is safe as a single filename component.
        PluginManager.pluginDataDirectory.appendingPathComponent("\(manifest.id).json")
    }

    init(manifest: PluginManifest, directory: URL, mainURL: URL, granted: Set<String>,
         manager: PluginManager) {
        self.manifest = manifest
        self.directory = directory
        self.mainURL = mainURL
        self.granted = granted
        self.manager = manager
    }

    // MARK: Lifecycle

    func load() throws {
        guard let ctx = JSContext() else {
            throw NSError(domain: "NoteClarity.Plugin", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Could not create JSContext"])
        }
        ctx.name = manifest.id
        let pluginName = manifest.name
        ctx.exceptionHandler = { [weak self] _, exception in
            let message = exception?.toString() ?? "unknown error"
            if let self, self.isLoading {
                if self.loadPhaseException == nil { self.loadPhaseException = message }
                return
            }
            NSLog("[NoteClarity] plugin '%@' exception: %@", pluginName, message)
            DispatchQueue.main.async {
                self?.manager.host?.pluginToast("Plugin \(pluginName): \(message)")
            }
        }
        installConsole(ctx)
        installAPI(ctx)
        // CommonJS-style shims so `exports.activate = …` also works.
        ctx.evaluateScript("var exports = {}; var module = { exports: exports };")

        let source = try String(contentsOf: mainURL, encoding: .utf8)
        context = ctx
        isLoading = true
        defer { isLoading = false }

        ctx.evaluateScript(source, withSourceURL: mainURL)
        try failLoadIfScriptThrew("evaluating \(manifest.main)")

        if let activate = function(named: "activate", in: ctx) {
            activate.call(withArguments: [makeExtensionContext(ctx)])
            try failLoadIfScriptThrew("activate()")
        }
    }

    private func failLoadIfScriptThrew(_ phase: String) throws {
        guard let message = loadPhaseException else { return }
        // Roll back anything the partial load registered before failing.
        for panel in panels.values { panel.teardown() }
        panels.removeAll()
        commandCallbacks.removeAll()
        eventListeners.removeAll()
        dynamicMenuItems.removeAll()
        context = nil
        loadPhaseException = nil
        throw NSError(domain: "NoteClarity.Plugin", code: 2,
                      userInfo: [NSLocalizedDescriptionKey: "Error \(phase): \(message)"])
    }

    func unload() {
        if let ctx = context, let deactivate = function(named: "deactivate", in: ctx) {
            deactivate.call(withArguments: [])
        }
        for panel in panels.values { panel.teardown() }
        panels.removeAll()
        commandCallbacks.removeAll()
        eventListeners.removeAll()
        dynamicMenuItems.removeAll()
        context = nil
    }

    func dispatch(_ event: PluginEvent, _ payload: [String: Any]) {
        guard context != nil, let listeners = eventListeners[event.rawValue], !listeners.isEmpty else { return }
        for callback in listeners {
            callback.call(withArguments: [payload])
        }
    }

    func invokeCommand(_ id: String) -> Bool {
        guard let callback = commandCallbacks[id] else { return false }
        callback.call(withArguments: [])
        return true
    }

    // MARK: Helpers

    private func function(named name: String, in ctx: JSContext) -> JSValue? {
        let candidates: [JSValue?] = [
            ctx.globalObject.objectForKeyedSubscript(name),
            ctx.globalObject.objectForKeyedSubscript("exports")?.objectForKeyedSubscript(name),
            ctx.globalObject.objectForKeyedSubscript("module")?
                .objectForKeyedSubscript("exports")?.objectForKeyedSubscript(name),
        ]
        for candidate in candidates {
            if let v = candidate, Self.isFunction(v, in: ctx) { return v }
        }
        return nil
    }

    private static func isFunction(_ value: JSValue, in ctx: JSContext) -> Bool {
        guard let ctxRef = ctx.jsGlobalContextRef, let ref = value.jsValueRef else { return false }
        return JSValueIsObject(ctxRef, ref) && JSObjectIsFunction(ctxRef, ref)
    }

    private func has(_ permission: PluginPermission) -> Bool {
        granted.contains(permission.rawValue)
    }

    /// Raises a JS exception in the plugin's context; JavaScriptCore surfaces it
    /// to the calling script as a thrown error.
    private func deny(_ permission: PluginPermission) {
        guard let ctx = context else { return }
        ctx.exception = JSValue(newErrorFromMessage:
            "NoteClarity: permission '\(permission.rawValue)' is not granted to plugin '\(manifest.id)'",
            in: ctx)
    }

    private func throwError(_ message: String) {
        guard let ctx = context else { return }
        ctx.exception = JSValue(newErrorFromMessage: "NoteClarity: \(message)", in: ctx)
    }

    private var editor: EditorController? { manager.host?.activeEditor }

    private func set(_ object: JSValue, _ key: String, _ block: Any) {
        object.setObject(block, forKeyedSubscript: key as NSString)
    }

    // MARK: Console

    private func installConsole(_ ctx: JSContext) {
        let pluginID = manifest.id
        let log: @convention(block) (JSValue?) -> Void = { value in
            NSLog("[NoteClarity plugin %@] %@", pluginID, value?.toString() ?? "")
        }
        guard let console = JSValue(newObjectIn: ctx) else { return }
        set(console, "log", log)
        set(console, "warn", log)
        set(console, "error", log)
        set(console, "info", log)
        ctx.setObject(console, forKeyedSubscript: "console" as NSString)
    }

    // MARK: Extension context (`activate` argument)

    private func makeExtensionContext(_ ctx: JSContext) -> JSValue {
        let obj = JSValue(newObjectIn: ctx)!
        obj.setObject(manifest.id, forKeyedSubscript: "pluginId" as NSString)
        obj.setObject(directory.path, forKeyedSubscript: "pluginPath" as NSString)
        obj.setObject(storageURL.path, forKeyedSubscript: "storagePath" as NSString)
        obj.setObject(manager.host?.appVersion ?? "1.0", forKeyedSubscript: "appVersion" as NSString)

        // Reads a file bundled inside the plugin's own folder (ungated: the plugin
        // ships those files itself). Containment is symlink-resolved (P1-02), so
        // neither `..` nor a planted symlink can reach outside the folder.
        let dir = directory
        let readResource: @convention(block) (String) -> String = { [weak self] relative in
            guard let self else { return "" }
            guard let target = PluginPathPolicy.containedURL(root: dir, relative: relative) else {
                self.throwError("readResource: path escapes the plugin folder")
                return ""
            }
            guard let contents = try? String(contentsOf: target, encoding: .utf8) else {
                self.throwError("readResource: could not read '\(relative)'")
                return ""
            }
            return contents
        }
        set(obj, "readResource", readResource)
        return obj
    }

    // MARK: API installation

    private func installAPI(_ ctx: JSContext) {
        let api = JSValue(newObjectIn: ctx)!
        api.setObject(manager.host?.appVersion ?? "1.0", forKeyedSubscript: "version" as NSString)
        api.setObject(PluginManager.apiVersion, forKeyedSubscript: "apiVersion" as NSString)

        api.setObject(makeEditorAPI(ctx), forKeyedSubscript: "editor" as NSString)
        api.setObject(makeCommandsAPI(ctx), forKeyedSubscript: "commands" as NSString)
        api.setObject(makeMenuAPI(ctx), forKeyedSubscript: "menu" as NSString)
        api.setObject(makeUIAPI(ctx), forKeyedSubscript: "ui" as NSString)
        api.setObject(makeEventsAPI(ctx), forKeyedSubscript: "events" as NSString)
        api.setObject(makeStorageAPI(ctx), forKeyedSubscript: "storage" as NSString)
        api.setObject(makeFSAPI(ctx), forKeyedSubscript: "fs" as NSString)
        api.setObject(makeNetAPI(ctx), forKeyedSubscript: "net" as NSString)

        ctx.setObject(api, forKeyedSubscript: "noteclarity" as NSString)
    }

    private func makeEditorAPI(_ ctx: JSContext) -> JSValue {
        let editorAPI = JSValue(newObjectIn: ctx)!

        let getText: @convention(block) () -> String = { [weak self] in
            guard let self else { return "" }
            guard self.has(.editorRead) else { self.deny(.editorRead); return "" }
            return self.editor?.text ?? ""
        }
        set(editorAPI, "getText", getText)

        let setText: @convention(block) (String) -> Void = { [weak self] text in
            guard let self else { return }
            guard self.has(.editorWrite) else { self.deny(.editorWrite); return }
            self.editor?.replaceAllUndoable(text)
        }
        set(editorAPI, "setText", setText)

        let getSelection: @convention(block) () -> NSDictionary = { [weak self] in
            guard let self else { return [:] }
            guard self.has(.editorRead) else { self.deny(.editorRead); return [:] }
            guard let ed = self.editor else { return ["text": "", "start": 0, "end": 0] }
            let sel = ed.textView.selectedRange()
            let text = (ed.text as NSString).substring(with: sel)
            return ["text": text, "start": sel.location, "end": NSMaxRange(sel)]
        }
        set(editorAPI, "getSelection", getSelection)

        let replaceSelection: @convention(block) (String) -> Void = { [weak self] text in
            guard let self else { return }
            guard self.has(.editorWrite) else { self.deny(.editorWrite); return }
            guard let ed = self.editor else { return }
            let sel = ed.textView.selectedRange()
            ed.replaceRangeUndoable(sel, with: text)
            ed.jump(to: sel.location + (text as NSString).length)
        }
        set(editorAPI, "replaceSelection", replaceSelection)

        let getCursor: @convention(block) () -> Int = { [weak self] in
            guard let self else { return 0 }
            guard self.has(.editorRead) else { self.deny(.editorRead); return 0 }
            return self.editor?.caretOffset ?? 0
        }
        set(editorAPI, "getCursor", getCursor)

        let setCursor: @convention(block) (Double) -> Void = { [weak self] offset in
            guard let self else { return }
            guard self.has(.editorWrite) else { self.deny(.editorWrite); return }
            self.editor?.jump(to: Int(offset))
        }
        set(editorAPI, "setCursor", setCursor)

        let insertAt: @convention(block) (Double, String) -> Void = { [weak self] offset, text in
            guard let self else { return }
            guard self.has(.editorWrite) else { self.deny(.editorWrite); return }
            guard let ed = self.editor else { return }
            let loc = max(0, min(Int(offset), ed.utf16Length))
            ed.replaceRangeUndoable(NSRange(location: loc, length: 0), with: text)
        }
        set(editorAPI, "insertAt", insertAt)

        let getLineCount: @convention(block) () -> Int = { [weak self] in
            guard let self else { return 0 }
            guard self.has(.editorRead) else { self.deny(.editorRead); return 0 }
            return self.editor?.lineStarts.count ?? 1
        }
        set(editorAPI, "getLineCount", getLineCount)

        let getFilePath: @convention(block) () -> Any = { [weak self] in
            guard let self else { return NSNull() }
            guard self.has(.editorRead) else { self.deny(.editorRead); return NSNull() }
            return self.manager.host?.activeDoc?.url?.path ?? NSNull()
        }
        set(editorAPI, "getFilePath", getFilePath)

        let getLanguage: @convention(block) () -> String = { [weak self] in
            guard let self else { return Language.plaintext.id }
            guard self.has(.editorRead) else { self.deny(.editorRead); return Language.plaintext.id }
            return self.manager.host?.activeDoc?.language.id ?? Language.plaintext.id
        }
        set(editorAPI, "getLanguage", getLanguage)

        let setLanguage: @convention(block) (String) -> Void = { [weak self] id in
            guard let self else { return }
            guard self.has(.editorWrite) else { self.deny(.editorWrite); return }
            if self.manager.host?.setDocumentLanguage(id) != true {
                self.throwError("setLanguage: unknown language id '\(id)'")
            }
        }
        set(editorAPI, "setLanguage", setLanguage)

        return editorAPI
    }

    private func makeCommandsAPI(_ ctx: JSContext) -> JSValue {
        let commandsAPI = JSValue(newObjectIn: ctx)!

        let register: @convention(block) (String, JSValue) -> Void = { [weak self] id, callback in
            guard let self else { return }
            guard self.has(.commands) else { self.deny(.commands); return }
            guard let ctx = self.context, Self.isFunction(callback, in: ctx) else {
                self.throwError("commands.register: callback must be a function")
                return
            }
            self.commandCallbacks[id] = callback
        }
        set(commandsAPI, "register", register)

        let execute: @convention(block) (String) -> Void = { [weak self] id in
            guard let self else { return }
            guard self.has(.commands) else { self.deny(.commands); return }
            if !self.manager.executeCommand(id, preferring: self.manifest.id) {
                self.throwError("commands.execute: no command registered with id '\(id)'")
            }
        }
        set(commandsAPI, "execute", execute)

        return commandsAPI
    }

    private func makeMenuAPI(_ ctx: JSContext) -> JSValue {
        let menuAPI = JSValue(newObjectIn: ctx)!

        let addItem: @convention(block) (JSValue) -> Void = { [weak self] item in
            guard let self else { return }
            guard self.has(.menu) else { self.deny(.menu); return }
            guard let dict = item.toDictionary(),
                  let title = dict["title"] as? String,
                  let command = dict["command"] as? String
            else {
                self.throwError("menu.addItem: expected { title, command }")
                return
            }
            self.dynamicMenuItems.append(PluginMenuItem(title: title, command: command,
                                                        pluginID: self.manifest.id))
            self.manager.contributionsDidChange()
        }
        set(menuAPI, "addItem", addItem)

        return menuAPI
    }

    private func makeUIAPI(_ ctx: JSContext) -> JSValue {
        let uiAPI = JSValue(newObjectIn: ctx)!

        let registerPanel: @convention(block) (JSValue) -> JSValue? = { [weak self] descriptor in
            guard let self, let ctx = self.context else { return nil }
            guard self.has(.uiPanel) else { self.deny(.uiPanel); return JSValue(undefinedIn: ctx) }
            guard let dict = descriptor.toDictionary(),
                  let panelID = dict["id"] as? String, !panelID.isEmpty,
                  let title = dict["title"] as? String,
                  let locationRaw = dict["location"] as? String,
                  let location = PanelLocation(rawValue: locationRaw),
                  let html = dict["html"] as? String
            else {
                self.throwError("ui.registerPanel: expected { id, title, location: left|right|bottom, html }")
                return JSValue(undefinedIn: ctx)
            }

            if let existing = self.panels[panelID] { existing.teardown() }
            let panel = PanelController(pluginID: self.manifest.id, panelID: panelID,
                                        title: title, location: location,
                                        html: html, baseURL: self.directory, instance: self,
                                        networkAllowed: self.has(.network))
            self.panels[panelID] = panel
            self.manager.contributionsDidChange()
            return self.makePanelHandle(ctx, panel: panel)
        }
        set(uiAPI, "registerPanel", registerPanel)

        let showNotification: @convention(block) (String) -> Void = { [weak self] message in
            self?.manager.host?.pluginToast(message)
        }
        set(uiAPI, "showNotification", showNotification)

        let showDialog: @convention(block) (JSValue) -> JSValue? = { [weak self] options in
            guard let self, let ctx = self.context else { return nil }
            guard self.has(.uiDialog) else { self.deny(.uiDialog); return JSValue(undefinedIn: ctx) }
            let dict = options.toDictionary() ?? [:]
            let title = dict["title"] as? String ?? self.manifest.name
            let message = dict["message"] as? String ?? ""
            let buttons = (dict["buttons"] as? [String]).flatMap { $0.isEmpty ? nil : $0 } ?? ["OK"]
            return JSValue(newPromiseIn: ctx) { resolve, _ in
                DispatchQueue.main.async {
                    let alert = NSAlert()
                    alert.messageText = title
                    alert.informativeText = message
                    for label in buttons { alert.addButton(withTitle: label) }
                    let response = alert.runModal()
                    let index = response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
                    resolve?.call(withArguments: [max(0, index)])
                }
            }
        }
        set(uiAPI, "showDialog", showDialog)

        return uiAPI
    }

    private func makePanelHandle(_ ctx: JSContext, panel: PanelController) -> JSValue {
        let handle = JSValue(newObjectIn: ctx)!

        let post: @convention(block) (JSValue?) -> Void = { [weak panel] message in
            panel?.postToWebview(message?.toObject())
        }
        set(handle, "postMessage", post)

        let onMessage: @convention(block) (JSValue) -> Void = { [weak self, weak panel] callback in
            guard let self, let ctx = self.context else { return }
            guard Self.isFunction(callback, in: ctx) else {
                self.throwError("PanelHandle.onMessage: callback must be a function")
                return
            }
            panel?.onMessageCallbacks.append(callback)
        }
        set(handle, "onMessage", onMessage)

        let reveal: @convention(block) () -> Void = { [weak self, weak panel] in
            guard let self, let panel else { return }
            self.manager.host?.revealPanel(panel)
        }
        set(handle, "reveal", reveal)

        let dispose: @convention(block) () -> Void = { [weak self, weak panel] in
            guard let self, let panel else { return }
            panel.teardown()
            self.panels.removeValue(forKey: panel.panelID)
            self.manager.contributionsDidChange()
        }
        set(handle, "dispose", dispose)

        return handle
    }

    private func makeEventsAPI(_ ctx: JSContext) -> JSValue {
        let eventsAPI = JSValue(newObjectIn: ctx)!

        let on: @convention(block) (String, JSValue) -> Void = { [weak self] name, callback in
            guard let self, let ctx = self.context else { return }
            guard PluginEvent(rawValue: name) != nil else {
                self.throwError("events.on: unknown event '\(name)'")
                return
            }
            guard Self.isFunction(callback, in: ctx) else {
                self.throwError("events.on: callback must be a function")
                return
            }
            self.eventListeners[name, default: []].append(callback)
        }
        set(eventsAPI, "on", on)

        let off: @convention(block) (String, JSValue) -> Void = { [weak self] name, callback in
            guard let self, let ctx = self.context, let ctxRef = ctx.jsGlobalContextRef else { return }
            guard var listeners = self.eventListeners[name] else { return }
            listeners.removeAll { existing in
                guard let a = existing.jsValueRef, let b = callback.jsValueRef else { return false }
                return JSValueIsStrictEqual(ctxRef, a, b)
            }
            self.eventListeners[name] = listeners
        }
        set(eventsAPI, "off", off)

        return eventsAPI
    }

    private func makeStorageAPI(_ ctx: JSContext) -> JSValue {
        let storageAPI = JSValue(newObjectIn: ctx)!

        let get: @convention(block) (String) -> Any = { [weak self] key in
            guard let self else { return NSNull() }
            guard self.has(.storage) else { self.deny(.storage); return NSNull() }
            return self.loadedStorage()[key] ?? NSNull()
        }
        set(storageAPI, "get", get)

        let setValue: @convention(block) (String, JSValue) -> Void = { [weak self] key, value in
            guard let self else { return }
            guard self.has(.storage) else { self.deny(.storage); return }
            var cache = self.loadedStorage()
            if value.isUndefined || value.isNull {
                cache.removeValue(forKey: key)
            } else {
                guard let object = value.toObject(),
                      JSONSerialization.isValidJSONObject([object])
                else {
                    self.throwError("storage.set: value must be JSON-serializable")
                    return
                }
                cache[key] = object
            }
            self.storageCache = cache
            do {
                try self.persistStorage()
            } catch {
                // A silently failed write would let the plugin believe the
                // value is durable (P2-07) — surface it to the caller.
                self.throwError("storage.set: could not persist (\(error.localizedDescription))")
            }
        }
        set(storageAPI, "set", setValue)

        return storageAPI
    }

    private func loadedStorage() -> [String: Any] {
        if let cached = storageCache { return cached }
        var loaded: [String: Any] = [:]
        if let data = try? Data(contentsOf: storageURL) {
            if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                loaded = object
            } else {
                // Malformed is not the same as absent (P2-07): quarantine the
                // bytes instead of silently overwriting them on the next set.
                let quarantine = storageURL.appendingPathExtension("corrupt")
                try? FileManager.default.removeItem(at: quarantine)
                try? FileManager.default.moveItem(at: storageURL, to: quarantine)
                NSLog("[NoteClarity] plugin %@ storage was malformed; moved to %@",
                      manifest.id, quarantine.lastPathComponent)
            }
        }
        storageCache = loaded
        return loaded
    }

    private func persistStorage() throws {
        guard let cache = storageCache else { return }
        let data = try JSONSerialization.data(withJSONObject: cache, options: [.sortedKeys])
        try data.write(to: storageURL, options: .atomic)
    }

    private func makeFSAPI(_ ctx: JSContext) -> JSValue {
        let fsAPI = JSValue(newObjectIn: ctx)!

        let readFile: @convention(block) (String) -> String = { [weak self] path in
            guard let self else { return "" }
            guard self.has(.fsRead) else { self.deny(.fsRead); return "" }
            let expanded = (path as NSString).expandingTildeInPath
            guard let contents = try? String(contentsOfFile: expanded, encoding: .utf8) else {
                self.throwError("fs.readFile: could not read '\(path)'")
                return ""
            }
            return contents
        }
        set(fsAPI, "readFile", readFile)

        let writeFile: @convention(block) (String, String) -> Void = { [weak self] path, data in
            guard let self else { return }
            guard self.has(.fsWrite) else { self.deny(.fsWrite); return }
            let expanded = (path as NSString).expandingTildeInPath
            do {
                try data.write(toFile: expanded, atomically: true, encoding: .utf8)
            } catch {
                self.throwError("fs.writeFile: \(error.localizedDescription)")
            }
        }
        set(fsAPI, "writeFile", writeFile)

        return fsAPI
    }

    private func makeNetAPI(_ ctx: JSContext) -> JSValue {
        let netAPI = JSValue(newObjectIn: ctx)!

        let fetch: @convention(block) (String, JSValue?) -> JSValue? = { [weak self] urlString, options in
            guard let self, let ctx = self.context else { return nil }
            guard self.has(.network) else { self.deny(.network); return JSValue(undefinedIn: ctx) }
            let dict = options?.toDictionary() ?? [:]
            return JSValue(newPromiseIn: ctx) { resolve, reject in
                guard let url = URL(string: urlString), url.scheme != nil else {
                    reject?.call(withArguments: ["net.fetch: invalid URL '\(urlString)'"])
                    return
                }
                // ATS is no longer globally disabled (P1-01): cleartext is
                // allowed only to loopback, so fail with a clear message
                // instead of an opaque transport-security error.
                guard Self.isAllowedFetchURL(url) else {
                    reject?.call(withArguments: ["net.fetch: only https URLs (or http to localhost) are allowed"])
                    return
                }
                var request = URLRequest(url: url)
                request.httpMethod = dict["method"] as? String ?? "GET"
                if let headers = dict["headers"] as? [String: String] {
                    for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
                }
                if let body = dict["body"] as? String {
                    request.httpBody = Data(body.utf8)
                }
                let task = URLSession.shared.dataTask(with: request) { data, response, error in
                    DispatchQueue.main.async {
                        if let error {
                            reject?.call(withArguments: [error.localizedDescription])
                            return
                        }
                        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                        let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                        resolve?.call(withArguments: [["status": status, "body": body]])
                    }
                }
                task.resume()
            }
        }
        set(netAPI, "fetch", fetch)

        return netAPI
    }

    static func isAllowedFetchURL(_ url: URL) -> Bool {
        switch url.scheme?.lowercased() {
        case "https":
            return true
        case "http":
            let host = url.host?.lowercased() ?? ""
            return host == "localhost" || host == "127.0.0.1" || host == "::1"
        default:
            return false
        }
    }
}
