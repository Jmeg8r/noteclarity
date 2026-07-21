import SwiftUI
import AppKit

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralPane()
                .tabItem { Label("General", systemImage: "gearshape") }
            EditorPane()
                .tabItem { Label("Editor", systemImage: "textformat") }
            FilesPane()
                .tabItem { Label("Files", systemImage: "doc") }
            PluginsPane()
                .tabItem { Label("Plugins", systemImage: "puzzlepiece.extension") }
        }
        .frame(width: 600, height: 460)
    }
}

private struct GeneralPane: View {
    @EnvironmentObject var settings: AppSettings

    var body: some View {
        Form {
            Picker("Appearance:", selection: $settings.appearance) {
                ForEach(AppearanceMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 280)

            Toggle("Use the system accent color", isOn: $settings.useSystemAccent)
            Text("Off uses NoteClarity's Notepad++-inspired green.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Divider()
            Toggle("Check for updates weekly", isOn: $settings.autoCheckForUpdates)
            Text("One anonymous request to the GitHub releases feed. NoteClarity ▸ Check for Updates works either way.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(24)
    }
}

private struct EditorPane: View {
    @EnvironmentObject var settings: AppSettings

    var body: some View {
        Form {
            Picker("Font:", selection: $settings.fontName) {
                Text("System Mono (SF Mono)").tag("")
                Divider()
                ForEach(AppSettings.monospacedFamilies, id: \.self) { family in
                    Text(family).tag(family)
                }
            }
            HStack {
                Text("Size:")
                Slider(value: $settings.fontSize, in: 8...32, step: 1)
                    .frame(width: 200)
                Text("\(Int(settings.fontSize)) pt")
                    .monospacedDigit()
                    .frame(width: 44, alignment: .trailing)
            }
            Stepper("Tab width: \(settings.tabWidth)", value: $settings.tabWidth, in: 1...16)
            Picker("Indent using:", selection: $settings.insertSpaces) {
                Text("Spaces").tag(true)
                Text("Tabs").tag(false)
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 280)
            Toggle("Word wrap", isOn: $settings.wordWrap)
            Divider()
            Toggle("Complete words from the document (⌥Esc)",
                   isOn: $settings.documentWordCompletionEnabled)
            Toggle("Show completions automatically while typing",
                   isOn: $settings.documentWordAutoPopupEnabled)
                .disabled(!settings.documentWordCompletionEnabled)
                .padding(.leading, 18)
        }
        .padding(24)
    }
}

private struct FilesPane: View {
    @EnvironmentObject var settings: AppSettings

    var body: some View {
        Form {
            Picker("Default encoding:", selection: $settings.defaultEncoding) {
                ForEach(FileEncoding.allCases) { encoding in
                    Text(encoding.displayName).tag(encoding)
                }
            }
            Picker("Default line endings:", selection: $settings.defaultLineEnding) {
                ForEach(LineEnding.allCases) { eol in
                    Text(eol.menuName).tag(eol)
                }
            }
            Text("Defaults apply to new documents; existing files keep their detected values.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Divider()
            Toggle("Automatically reload documents with no unsaved changes when their file changes on disk",
                   isOn: $settings.autoReloadCleanDocuments)
            Text("Documents with unsaved changes always ask before reloading.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(24)
    }
}

// MARK: - Plugins pane

private struct PluginsPane: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var plugins: PluginManager

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if plugins.records.isEmpty {
                VStack {
                    Spacer()
                    Text("No plugins installed.")
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                List(plugins.records) { record in
                    PluginRowView(record: record)
                        .padding(.vertical, 4)
                }
            }
            HStack {
                Button("Reload Plugins") { app.reloadPlugins() }
                Button("Reveal Plugins Folder in Finder") { plugins.revealPluginsFolder() }
                Spacer()
            }
            Text("To install a plugin, drop its folder (containing plugin.json and main.js) into the Plugins directory and click Reload Plugins. The API contract lives beside it in noteclarity.d.ts.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
    }
}

private struct PluginRowView: View {
    let record: PluginManager.PluginRecord
    @EnvironmentObject var plugins: PluginManager

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(record.manifest.name)
                    .fontWeight(.semibold)
                Text("v\(record.manifest.version)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let author = record.manifest.author {
                    Text("· \(author)")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                Toggle("", isOn: Binding(
                    get: { plugins.isEnabled(record.id) },
                    set: { plugins.setEnabled(record.id, $0) }
                ))
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
            }
            if let description = record.manifest.description {
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("Permissions: " + (record.granted.isEmpty
                                    ? (record.manifest.permissions?.joined(separator: ", ") ?? "none")
                                    : record.granted.joined(separator: ", ")))
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            if let error = record.loadError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }
}
