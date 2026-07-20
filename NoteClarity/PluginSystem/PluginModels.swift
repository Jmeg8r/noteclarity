import Foundation

/// Decoded `plugin.json`. Mirrors the community contract in `noteclarity.d.ts`.
struct PluginManifest: Codable, Identifiable {
    var id: String
    var name: String
    var version: String
    var apiVersion: String
    var author: String?
    var description: String?
    var main: String
    var permissions: [String]?
    var contributes: Contributes?

    struct Contributes: Codable {
        var commands: [CommandContribution]?
        var menus: [MenuContribution]?
        var panels: [PanelContribution]?
    }

    struct CommandContribution: Codable, Identifiable {
        var id: String
        var title: String
    }

    struct MenuContribution: Codable {
        var command: String
        var location: String?
    }

    /// Declarative panel metadata; runtime `ui.registerPanel` is authoritative.
    struct PanelContribution: Codable {
        var id: String?
        var title: String?
        var location: String?
    }
}

enum PluginPermission: String, CaseIterable {
    case editorRead = "editor.read"
    case editorWrite = "editor.write"
    case commands
    case menu
    case uiPanel = "ui.panel"
    case uiDialog = "ui.dialog"
    case fsRead = "fs.read"
    case fsWrite = "fs.write"
    case network
    case storage
}

enum PluginEvent: String, CaseIterable {
    case documentOpened = "document.opened"
    case documentChanged = "document.changed"
    case documentSaved = "document.saved"
    case selectionChanged = "selection.changed"
    case languageChanged = "language.changed"
}

enum PanelLocation: String, Codable {
    case left, right, bottom
}

/// A Plugins-menu entry: either declared in the manifest or added at runtime
/// via `noteclarity.menu.addItem`.
struct PluginMenuItem: Identifiable, Equatable {
    let id: String
    let title: String
    let command: String
    let pluginID: String

    init(title: String, command: String, pluginID: String) {
        self.title = title
        self.command = command
        self.pluginID = pluginID
        self.id = pluginID + "|" + command + "|" + title
    }
}
