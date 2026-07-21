import Foundation
import AppKit

/// What the plugin runtime needs from the application. Implemented by AppState.
protocol PluginHostContext: AnyObject {
    var activeEditor: EditorController? { get }
    var activeDoc: Document? { get }
    var appVersion: String { get }
    func pluginToast(_ text: String)
    func setDocumentLanguage(_ id: String) -> Bool
    func revealPanel(_ panel: PanelController)
    func panelsChanged()
}

/// Scans `~/Library/Application Support/NoteClarity/Plugins`, seeds the bundled
/// plugins on first run, and owns the loaded `PluginInstance`s.
///
/// Loading is gated on `PluginManifestValidator` (P1-02) and on an
/// identity-bound grant (P1-03): a stored grant is honored only while the
/// on-disk manifest + entry point still hash to the digest the user approved
/// AND the manifest requests exactly the granted permission set.
final class PluginManager: ObservableObject {
    static let apiVersion = "\(PluginManifestValidator.supportedAPIMajor).\(PluginManifestValidator.supportedAPIMinor)"

    weak var host: PluginHostContext?

    struct PluginRecord: Identifiable {
        let manifest: PluginManifest
        let directory: URL
        /// nil → failed validation (or duplicate ID); `loadError` says why.
        var validated: ValidatedPlugin?
        var enabled: Bool
        var granted: [String]
        var loadError: String?
        /// List identity is the directory, not the manifest ID — duplicate IDs
        /// must both be representable in the manager UI.
        var id: String { directory.path }
    }

    @Published private(set) var records: [PluginRecord] = []
    /// Bumped whenever menus/panels change so SwiftUI menus rebuild.
    @Published private(set) var contributionsVersion = 0

    /// Keyed by manifest ID; duplicates never load, so the key is unique.
    private(set) var instances: [String: PluginInstance] = [:]

    let grantStore = PluginGrantStore()

    private static let enabledKey = "nc.plugin.enabled"

    // MARK: Directories

    static var pluginsDirectory: URL = {
        let dir = AppState.supportDirectory.appendingPathComponent("Plugins", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static var pluginDataDirectory: URL = {
        let dir = AppState.supportDirectory.appendingPathComponent("PluginData", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    // MARK: Persistence of enable state

    private var enabledMap: [String: Bool] {
        get { UserDefaults.standard.dictionary(forKey: Self.enabledKey) as? [String: Bool] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: Self.enabledKey) }
    }

    private func setEnabledFlag(_ pluginID: String, _ on: Bool) {
        var enabled = enabledMap
        enabled[pluginID] = on
        enabledMap = enabled
    }

    // MARK: Loading

    func loadAll() {
        seedBundledPlugins()
        scan()
        for record in records where record.enabled && record.validated != nil {
            loadInstance(recordKey: record.id)
        }
        contributionsDidChange()
    }

    func reload() {
        unloadAll()
        loadAll()
    }

    func unloadAll() {
        for instance in instances.values { instance.unload() }
        instances.removeAll()
        contributionsDidChange()
    }

    /// Copies bundled plugin folders into the user's Plugins directory on first
    /// run. Bundled trust derives from the signed app resources we copy from:
    /// each seeded copy is validated, digested, and granted its manifest
    /// permissions bound to that digest. Anything installed by hand still goes
    /// through the explicit permission prompt on first enable.
    private func seedBundledPlugins() {
        guard let resourceRoot = Bundle.main.resourceURL?
            .appendingPathComponent("BundledPlugins", isDirectory: true),
            FileManager.default.fileExists(atPath: resourceRoot.path)
        else { return }

        var seeded: [String] = []
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: resourceRoot, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        for item in contents {
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: item.path, isDirectory: &isDir)
            if isDir.boolValue {
                let destination = Self.pluginsDirectory.appendingPathComponent(item.lastPathComponent)
                guard !FileManager.default.fileExists(atPath: destination.path) else { continue }
                do {
                    try FileManager.default.copyItem(at: item, to: destination)
                } catch {
                    NSLog("[NoteClarity] plugin seed failed for %@: %@", item.lastPathComponent,
                          error.localizedDescription)
                    continue
                }
                guard case .success(let manifest) = Self.readManifest(in: destination),
                      case .success(let validated) = PluginManifestValidator.validate(manifest, directory: destination),
                      let identity = PluginIdentity.digest(directory: validated.directory, mainURL: validated.mainURL)
                else {
                    NSLog("[NoteClarity] seeded bundled plugin %@ failed validation; leaving disabled",
                          item.lastPathComponent)
                    continue
                }
                setEnabledFlag(manifest.id, true)
                grantStore.setGrant(PluginGrant(permissions: Set(manifest.permissions ?? []),
                                                identity: identity),
                                    for: manifest.id)
                seeded.append(manifest.name)
            } else if item.lastPathComponent == "noteclarity.d.ts" {
                // Keep the API contract next to the plugins for community devs.
                let dest = Self.pluginsDirectory.appendingPathComponent("noteclarity.d.ts")
                try? FileManager.default.removeItem(at: dest)
                try? FileManager.default.copyItem(at: item, to: dest)
            }
        }
        if !seeded.isEmpty {
            let names = seeded.joined(separator: ", ")
            DispatchQueue.main.async { [weak self] in
                self?.host?.pluginToast("Installed bundled plugins: \(names)")
            }
        }
    }

    private static func readManifest(in directory: URL) -> Result<PluginManifest, Error> {
        let manifestURL = directory.appendingPathComponent("plugin.json")
        do {
            let data = try Data(contentsOf: manifestURL)
            return .success(try JSONDecoder().decode(PluginManifest.self, from: data))
        } catch {
            return .failure(error)
        }
    }

    private func scan() {
        let fm = FileManager.default
        let contents = (try? fm.contentsOfDirectory(
            at: Self.pluginsDirectory, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        var found: [PluginRecord] = []
        var unreadable: [String] = []
        for item in contents.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            var isDir: ObjCBool = false
            fm.fileExists(atPath: item.path, isDirectory: &isDir)
            guard isDir.boolValue else { continue }
            switch Self.readManifest(in: item) {
            case .failure(let error):
                // Only folders that attempt to be plugins are worth surfacing.
                if fm.fileExists(atPath: item.appendingPathComponent("plugin.json").path) {
                    unreadable.append(item.lastPathComponent)
                    NSLog("[NoteClarity] plugin manifest unreadable in %@: %@",
                          item.lastPathComponent, error.localizedDescription)
                }
            case .success(let manifest):
                var record = PluginRecord(manifest: manifest, directory: item,
                                          validated: nil, enabled: false,
                                          granted: [], loadError: nil)
                switch PluginManifestValidator.validate(manifest, directory: item) {
                case .success(let validated):
                    record.validated = validated
                    record.enabled = enabledMap[manifest.id] ?? false
                    record.granted = grantStore.grant(for: manifest.id)?.permissions.sorted()
                        ?? grantStore.legacyPermissions(for: manifest.id) ?? []
                case .failure(let failure):
                    record.loadError = "Invalid manifest: \(failure.localizedDescription)"
                }
                found.append(record)
            }
        }

        // Duplicate IDs are rejected wholesale (P1-03): a "first wins" rule is
        // gameable by folder naming, and the winner would silently inherit the
        // loser's stored grant.
        let duplicated = Dictionary(grouping: found.filter { $0.validated != nil },
                                    by: { $0.manifest.id }).filter { $1.count > 1 }
        for idx in found.indices where duplicated[found[idx].manifest.id] != nil {
            found[idx].validated = nil
            found[idx].enabled = false
            found[idx].loadError = "Duplicate plugin ID '\(found[idx].manifest.id)' — not loaded. Remove the extra copy and reload."
        }

        records = found.sorted { $0.manifest.name.localizedCaseInsensitiveCompare($1.manifest.name) == .orderedAscending }
        if !unreadable.isEmpty {
            let names = unreadable.joined(separator: ", ")
            DispatchQueue.main.async { [weak self] in
                self?.host?.pluginToast("Skipped plugin folder(s) with unreadable plugin.json: \(names)")
            }
        }
    }

    private func loadInstance(recordKey: String) {
        guard let idx = records.firstIndex(where: { $0.id == recordKey }),
              let validated = records[idx].validated
        else { return }
        let pluginID = validated.manifest.id
        guard instances[pluginID] == nil else { return }

        // Grant gate (P1-03): the stored grant must match the code on disk
        // right now AND the permission set the manifest requests today.
        guard let identity = PluginIdentity.digest(directory: validated.directory,
                                                   mainURL: validated.mainURL) else {
            markLoadFailure(idx, "Could not read plugin files to verify identity.")
            return
        }
        var grant = grantStore.grant(for: pluginID)
        if grant == nil, let legacy = grantStore.legacyPermissions(for: pluginID) {
            grant = grantStore.adoptLegacyGrant(for: pluginID, permissions: legacy, identity: identity)
        }
        let requested = Set(validated.manifest.permissions ?? [])
        guard let grant, grant.identity == identity, grant.permissions == requested else {
            markLoadFailure(idx, "Plugin code or requested permissions changed since approval — re-enable to review.")
            return
        }
        records[idx].granted = grant.permissions.sorted()

        let instance = PluginInstance(manifest: validated.manifest,
                                      directory: validated.directory,
                                      mainURL: validated.mainURL,
                                      granted: grant.permissions,
                                      manager: self)
        do {
            try instance.load()
            instances[pluginID] = instance
            records[idx].loadError = nil
        } catch {
            records[idx].loadError = error.localizedDescription
            records[idx].enabled = false
            setEnabledFlag(pluginID, false)
            host?.pluginToast("Plugin \(validated.manifest.name) failed to load: \(error.localizedDescription)")
        }
        contributionsDidChange()
    }

    private func markLoadFailure(_ idx: Int, _ message: String) {
        records[idx].loadError = message
        records[idx].enabled = false
        setEnabledFlag(records[idx].manifest.id, false)
        host?.pluginToast("Plugin \(records[idx].manifest.name): \(message)")
        contributionsDidChange()
    }

    // MARK: Enable / disable

    func isEnabled(_ recordKey: String) -> Bool {
        records.first { $0.id == recordKey }?.enabled ?? false
    }

    func setEnabled(_ recordKey: String, _ on: Bool) {
        guard let idx = records.firstIndex(where: { $0.id == recordKey }) else { return }
        guard let validated = records[idx].validated else {
            records[idx].enabled = false
            return
        }
        let pluginID = validated.manifest.id
        if on {
            guard let identity = PluginIdentity.digest(directory: validated.directory,
                                                       mainURL: validated.mainURL) else {
                markLoadFailure(idx, "Could not read plugin files to verify identity.")
                return
            }
            let requested = Set(validated.manifest.permissions ?? [])
            var grant = grantStore.grant(for: pluginID)
            if grant == nil, let legacy = grantStore.legacyPermissions(for: pluginID) {
                grant = grantStore.adoptLegacyGrant(for: pluginID, permissions: legacy, identity: identity)
            }
            let stale = grant.map { $0.identity != identity || $0.permissions != requested } ?? true
            if stale {
                guard promptForPermissions(records[idx].manifest, isRegrant: grant != nil) else {
                    records[idx].enabled = false
                    return
                }
                grantStore.setGrant(PluginGrant(permissions: requested, identity: identity), for: pluginID)
            }
            records[idx].granted = requested.sorted()
            records[idx].enabled = true
            setEnabledFlag(pluginID, true)
            loadInstance(recordKey: recordKey)
            if instances[pluginID] != nil, let doc = host?.activeDoc {
                emit(.documentOpened, [
                    "path": doc.url?.path as Any? ?? NSNull(),
                    "language": doc.language.id,
                    "length": doc.controller?.utf16Length ?? 0,
                ])
            }
        } else {
            records[idx].enabled = false
            setEnabledFlag(pluginID, false)
            if let instance = instances.removeValue(forKey: pluginID) {
                instance.unload()
            }
            contributionsDidChange()
        }
    }

    private func promptForPermissions(_ manifest: PluginManifest, isRegrant: Bool) -> Bool {
        let alert = NSAlert()
        alert.messageText = isRegrant
            ? "“\(manifest.name)” has changed — review before enabling"
            : "Enable “\(manifest.name)”?"
        let permissions = manifest.permissions ?? []
        let list = permissions.isEmpty ? "(no permissions requested)"
            : permissions.map { "•  \($0)" }.joined(separator: "\n")
        let changeNote = isRegrant
            ? "\n\nIts code or requested permissions differ from what you previously approved."
            : ""
        alert.informativeText = "Version \(manifest.version)"
            + (manifest.author.map { " by \($0)" } ?? "")
            + changeNote
            + "\n\nThis plugin requests the following permissions:\n\n\(list)"
        alert.addButton(withTitle: "Enable")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    // MARK: Events / commands / contributions

    func emit(_ event: PluginEvent, _ payload: [String: Any]) {
        // Sorted for deterministic listener ordering across launches.
        for key in instances.keys.sorted() {
            instances[key]?.dispatch(event, payload)
        }
    }

    /// Menu items dispatch directly to the plugin that contributed them —
    /// another plugin registering the same command ID can never intercept.
    @discardableResult
    func executeMenuCommand(_ item: PluginMenuItem) -> Bool {
        instances[item.pluginID]?.invokeCommand(item.command) ?? false
    }

    /// `commands.execute` API path: the calling plugin's own registration wins,
    /// then remaining instances in deterministic (sorted-ID) order.
    @discardableResult
    func executeCommand(_ id: String, preferring pluginID: String? = nil) -> Bool {
        if let pluginID, let own = instances[pluginID], own.invokeCommand(id) {
            return true
        }
        for key in instances.keys.sorted() where key != pluginID {
            if let instance = instances[key], instance.invokeCommand(id) { return true }
        }
        return false
    }

    func contributionsDidChange() {
        contributionsVersion += 1
        host?.panelsChanged()
    }

    func panels(at location: PanelLocation) -> [PanelController] {
        instances.values
            .flatMap { $0.panels.values }
            .filter { $0.location == location }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    struct MenuGroup: Identifiable {
        let id: String
        let pluginName: String
        let items: [PluginMenuItem]
    }

    /// Plugins menu content: manifest-declared items (location "plugins" or
    /// unspecified) plus runtime `menu.addItem` contributions, grouped per plugin.
    var menuGroups: [MenuGroup] {
        var groups: [MenuGroup] = []
        for record in records where record.enabled {
            guard let instance = instances[record.manifest.id] else { continue }
            var items: [PluginMenuItem] = []
            let commandTitles = Dictionary(uniqueKeysWithValues:
                (record.manifest.contributes?.commands ?? []).map { ($0.id, $0.title) })
            for menu in record.manifest.contributes?.menus ?? [] where (menu.location ?? "plugins") == "plugins" {
                let title = commandTitles[menu.command] ?? menu.command
                items.append(PluginMenuItem(title: title, command: menu.command, pluginID: record.manifest.id))
            }
            for dynamic in instance.dynamicMenuItems where !items.contains(dynamic) {
                items.append(dynamic)
            }
            if !items.isEmpty {
                groups.append(MenuGroup(id: record.manifest.id, pluginName: record.manifest.name, items: items))
            }
        }
        return groups
    }

    func revealPluginsFolder() {
        NSWorkspace.shared.activateFileViewerSelecting([Self.pluginsDirectory])
    }
}
