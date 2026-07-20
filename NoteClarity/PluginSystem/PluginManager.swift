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
final class PluginManager: ObservableObject {
    static let apiVersion = "1.0"

    weak var host: PluginHostContext?

    struct PluginRecord: Identifiable {
        let manifest: PluginManifest
        let directory: URL
        var enabled: Bool
        var granted: [String]
        var loadError: String?
        var id: String { manifest.id }
    }

    @Published private(set) var records: [PluginRecord] = []
    /// Bumped whenever menus/panels change so SwiftUI menus rebuild.
    @Published private(set) var contributionsVersion = 0

    private(set) var instances: [String: PluginInstance] = [:]

    private static let enabledKey = "nc.plugin.enabled"
    private static let grantsKey = "nc.plugin.grants"

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

    // MARK: Persistence of enable/grant state

    private var enabledMap: [String: Bool] {
        get { UserDefaults.standard.dictionary(forKey: Self.enabledKey) as? [String: Bool] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: Self.enabledKey) }
    }

    private var grantsMap: [String: [String]] {
        get { UserDefaults.standard.dictionary(forKey: Self.grantsKey) as? [String: [String]] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: Self.grantsKey) }
    }

    // MARK: Loading

    func loadAll() {
        seedBundledPlugins()
        scan()
        for record in records where record.enabled {
            loadInstance(recordID: record.id)
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

    /// Copies bundled plugin folders into the user's Plugins directory on first run.
    /// Bundled plugins ship with the app, so their manifest permissions are granted
    /// and they are enabled at seed time; anything installed by hand still goes
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
                if let manifest = Self.readManifest(in: destination) {
                    var enabled = enabledMap
                    var grants = grantsMap
                    enabled[manifest.id] = true
                    grants[manifest.id] = manifest.permissions ?? []
                    enabledMap = enabled
                    grantsMap = grants
                    seeded.append(manifest.name)
                }
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

    private static func readManifest(in directory: URL) -> PluginManifest? {
        let manifestURL = directory.appendingPathComponent("plugin.json")
        guard let data = try? Data(contentsOf: manifestURL) else { return nil }
        return try? JSONDecoder().decode(PluginManifest.self, from: data)
    }

    private func scan() {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: Self.pluginsDirectory, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        var found: [PluginRecord] = []
        for item in contents {
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: item.path, isDirectory: &isDir)
            guard isDir.boolValue, let manifest = Self.readManifest(in: item) else { continue }
            found.append(PluginRecord(manifest: manifest,
                                      directory: item,
                                      enabled: enabledMap[manifest.id] ?? false,
                                      granted: grantsMap[manifest.id] ?? [],
                                      loadError: nil))
        }
        records = found.sorted { $0.manifest.name.localizedCaseInsensitiveCompare($1.manifest.name) == .orderedAscending }
    }

    private func loadInstance(recordID: String) {
        guard let idx = records.firstIndex(where: { $0.id == recordID }) else { return }
        let record = records[idx]
        guard instances[recordID] == nil else { return }
        let instance = PluginInstance(manifest: record.manifest,
                                      directory: record.directory,
                                      granted: Set(record.granted),
                                      manager: self)
        do {
            try instance.load()
            instances[recordID] = instance
            records[idx].loadError = nil
        } catch {
            records[idx].loadError = error.localizedDescription
            records[idx].enabled = false
            var enabled = enabledMap
            enabled[recordID] = false
            enabledMap = enabled
            host?.pluginToast("Plugin \(record.manifest.name) failed to load: \(error.localizedDescription)")
        }
        contributionsDidChange()
    }

    // MARK: Enable / disable

    func isEnabled(_ id: String) -> Bool {
        records.first { $0.id == id }?.enabled ?? false
    }

    func setEnabled(_ id: String, _ on: Bool) {
        guard let idx = records.firstIndex(where: { $0.id == id }) else { return }
        if on {
            // First enable of a hand-installed plugin: surface permissions and store the grant.
            if grantsMap[id] == nil {
                guard promptForPermissions(records[idx].manifest) else {
                    records[idx].enabled = false
                    return
                }
                var grants = grantsMap
                grants[id] = records[idx].manifest.permissions ?? []
                grantsMap = grants
                records[idx].granted = grants[id] ?? []
            }
            records[idx].enabled = true
            var enabled = enabledMap
            enabled[id] = true
            enabledMap = enabled
            loadInstance(recordID: id)
            if let doc = host?.activeDoc {
                emit(.documentOpened, [
                    "path": doc.url?.path as Any? ?? NSNull(),
                    "language": doc.language.id,
                    "length": doc.controller?.utf16Length ?? 0,
                ])
            }
        } else {
            records[idx].enabled = false
            var enabled = enabledMap
            enabled[id] = false
            enabledMap = enabled
            if let instance = instances.removeValue(forKey: id) {
                instance.unload()
            }
            contributionsDidChange()
        }
    }

    private func promptForPermissions(_ manifest: PluginManifest) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Enable “\(manifest.name)”?"
        let permissions = manifest.permissions ?? []
        let list = permissions.isEmpty ? "(no permissions requested)"
            : permissions.map { "•  \($0)" }.joined(separator: "\n")
        alert.informativeText = "Version \(manifest.version)"
            + (manifest.author.map { " by \($0)" } ?? "")
            + "\n\nThis plugin requests the following permissions:\n\n\(list)"
        alert.addButton(withTitle: "Enable")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    // MARK: Events / commands / contributions

    func emit(_ event: PluginEvent, _ payload: [String: Any]) {
        for instance in instances.values {
            instance.dispatch(event, payload)
        }
    }

    @discardableResult
    func executeCommand(_ id: String) -> Bool {
        for instance in instances.values where instance.invokeCommand(id) {
            return true
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
            guard let instance = instances[record.id] else { continue }
            var items: [PluginMenuItem] = []
            let commandTitles = Dictionary(uniqueKeysWithValues:
                (record.manifest.contributes?.commands ?? []).map { ($0.id, $0.title) })
            for menu in record.manifest.contributes?.menus ?? [] where (menu.location ?? "plugins") == "plugins" {
                let title = commandTitles[menu.command] ?? menu.command
                items.append(PluginMenuItem(title: title, command: menu.command, pluginID: record.id))
            }
            for dynamic in instance.dynamicMenuItems where !items.contains(dynamic) {
                items.append(dynamic)
            }
            if !items.isEmpty {
                groups.append(MenuGroup(id: record.id, pluginName: record.manifest.name, items: items))
            }
        }
        return groups
    }

    func revealPluginsFolder() {
        NSWorkspace.shared.activateFileViewerSelecting([Self.pluginsDirectory])
    }
}
