import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        AppState.shared.handleTermination()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        AppState.shared.open(urls: urls)
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppState.shared.saveSession()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

@main
struct NoteClarityApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var app = AppState.shared
    @StateObject private var settings = AppSettings.shared

    var body: some Scene {
        Window("NoteClarity", id: "main") {
            MainWindowView()
                .environmentObject(app)
                .environmentObject(settings)
                .environmentObject(app.plugins)
        }
        .defaultSize(width: 1160, height: 740)
        .commands {
            AppCommands(app: app, settings: settings, plugins: app.plugins)
        }

        Settings {
            SettingsView()
                .environmentObject(app)
                .environmentObject(settings)
                .environmentObject(app.plugins)
        }
    }
}

/// Menu bar. Declared as its own Commands type so menus observe AppState /
/// PluginManager and rebuild when documents, recents, or plugin contributions change.
struct AppCommands: Commands {
    @ObservedObject var app: AppState
    @ObservedObject var settings: AppSettings
    @ObservedObject var plugins: PluginManager

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Tab") { app.newDocument() }
                .keyboardShortcut("n", modifiers: .command)
            Button("Open…") { app.openViaPanel() }
                .keyboardShortcut("o", modifiers: .command)
            Menu("Open Recent") {
                ForEach(app.recentFiles, id: \.self) { path in
                    Button((path as NSString).lastPathComponent) {
                        app.open(urls: [URL(fileURLWithPath: path)])
                    }
                }
                if app.recentFiles.isEmpty {
                    Button("No Recent Files") {}.disabled(true)
                } else {
                    Divider()
                    Button("Clear Menu") { app.clearRecents() }
                }
            }
        }

        CommandGroup(replacing: .saveItem) {
            Button("Save") { app.saveActive() }
                .keyboardShortcut("s", modifiers: .command)
            Button("Save As…") { app.saveActiveAs() }
                .keyboardShortcut("s", modifiers: [.command, .shift])
            Divider()
            Button("Close Tab") { app.closeActive() }
                .keyboardShortcut("w", modifiers: .command)
            Button("Close Window") { NSApp.keyWindow?.performClose(nil) }
                .keyboardShortcut("w", modifiers: [.command, .shift])
        }

        CommandGroup(after: .pasteboard) {
            Divider()
            Menu("Find") {
                Button("Find…") { app.showFindBar(focusReplace: false) }
                    .keyboardShortcut("f", modifiers: .command)
                Button("Find Next") { app.findNext() }
                    .keyboardShortcut("g", modifiers: .command)
                Button("Find Previous") { app.findNext(backwards: true) }
                    .keyboardShortcut("g", modifiers: [.command, .shift])
                Button("Find All") { app.findAll() }
                Divider()
                Button("Use Selection for Find") { app.useSelectionForFind() }
                    .keyboardShortcut("e", modifiers: .command)
                Button("Replace…") { app.showFindBar(focusReplace: true) }
                    .keyboardShortcut("f", modifiers: [.command, .option])
            }
        }

        CommandGroup(before: .toolbar) {
            Button(settings.wordWrap ? "Disable Word Wrap" : "Enable Word Wrap") {
                settings.wordWrap.toggle()
            }
            .keyboardShortcut("w", modifiers: [.command, .option])
            Divider()
            Button("Zoom In") { settings.zoomIn() }
                .keyboardShortcut("=", modifiers: .command)
            Button("Zoom Out") { settings.zoomOut() }
                .keyboardShortcut("-", modifiers: .command)
            Button("Reset Zoom") { settings.zoomReset() }
                .keyboardShortcut("0", modifiers: .command)
            Divider()
            Picker("Appearance", selection: $settings.appearance) {
                ForEach(AppearanceMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            Divider()
            Button(app.sidebarVisible ? "Hide Sidebar" : "Show Sidebar") {
                app.sidebarVisible.toggle()
            }
            .keyboardShortcut("l", modifiers: [.command, .shift])
            Button(app.rightPanelVisible ? "Hide Right Panel" : "Show Right Panel") {
                app.rightPanelVisible.toggle()
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])
            .disabled(plugins.panels(at: .right).isEmpty)
            Button(app.bottomPanelVisible ? "Hide Bottom Panel" : "Show Bottom Panel") {
                app.bottomPanelVisible.toggle()
            }
            .keyboardShortcut("j", modifiers: [.command, .shift])
            .disabled(plugins.panels(at: .bottom).isEmpty)
        }

        CommandMenu("Language") {
            Picker("Language", selection: Binding(
                get: { app.activeDocument?.language ?? .plaintext },
                set: { app.setLanguageManual($0) }
            )) {
                ForEach(Language.allCases) { language in
                    Text(language.displayName).tag(language)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        }

        CommandMenu("Plugins") {
            let groups = plugins.menuGroups
            if groups.isEmpty {
                Button("No Plugin Commands") {}.disabled(true)
            } else {
                ForEach(groups) { group in
                    Menu(group.pluginName) {
                        ForEach(group.items) { item in
                            Button(item.title) { plugins.executeCommand(item.command) }
                        }
                    }
                }
            }
            Divider()
            Button("Reload Plugins") { app.reloadPlugins() }
            Button("Open Plugins Folder") { plugins.revealPluginsFolder() }
            SettingsLink {
                Text("Manage Plugins…")
            }
        }
    }
}
