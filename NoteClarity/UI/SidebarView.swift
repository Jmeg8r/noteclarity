import SwiftUI
import AppKit

/// Left sidebar: Function List, open/recent files, and any plugin panels that
/// declare `location: "left"`.
struct SidebarView: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var plugins: PluginManager

    private var leftPanels: [PanelController] {
        plugins.panels(at: .left)
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $app.selectedSidebarTab) {
                Text("Functions").tag(SidebarTab.functions)
                Text("Files").tag(SidebarTab.files)
                ForEach(leftPanels) { panel in
                    Text(panel.title).tag(SidebarTab.plugin(panel.id))
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(8)
            Divider()
            switch app.selectedSidebarTab {
            case .functions:
                FunctionListView()
            case .files:
                FilesListView()
            case .plugin(let id):
                if let panel = leftPanels.first(where: { $0.id == id }) {
                    PanelWebView(controller: panel).id(panel.id)
                } else {
                    FunctionListView()
                }
            }
        }
    }
}

/// Regex-extracted symbols for the active document; click to jump.
struct FunctionListView: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var settings: AppSettings

    var body: some View {
        if app.symbols.isEmpty {
            VStack(spacing: 6) {
                Spacer()
                Image(systemName: "function")
                    .font(.system(size: 22))
                    .foregroundStyle(.tertiary)
                Text(emptyMessage)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        } else {
            List(app.symbols) { symbol in
                HStack(spacing: 6) {
                    Image(systemName: symbol.kind.systemImage)
                        .font(.system(size: 10))
                        .foregroundStyle(settings.accentColor)
                        .frame(width: 15)
                    Text(symbol.name)
                        .font(Typography.chrome(size: 12))
                        .lineLimit(1)
                    Spacer()
                    Text("\(symbol.line)")
                        .font(Typography.chrome(size: 10))
                        .monospacedDigit()
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
                .onTapGesture { app.jumpToSymbol(symbol) }
                .help("\(symbol.kind.rawValue) — line \(symbol.line)")
            }
            .listStyle(.sidebar)
        }
    }

    private var emptyMessage: String {
        let language = app.activeDocument?.language ?? .plaintext
        switch language {
        case .swift, .python, .javascript, .typescript:
            return "No symbols found in this document."
        default:
            return "Function List supports Swift, Python, JavaScript and TypeScript."
        }
    }
}

/// Open documents plus recent files.
struct FilesListView: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var settings: AppSettings

    var body: some View {
        List {
            Section("Open Files") {
                ForEach(app.documents) { document in
                    FileRow(document: document)
                }
            }
            Section("Recent") {
                ForEach(app.recentFiles.prefix(10), id: \.self) { path in
                    HStack(spacing: 6) {
                        Image(systemName: "clock")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text((path as NSString).lastPathComponent)
                                .font(Typography.chrome(size: 12))
                                .lineLimit(1)
                            Text((path as NSString).deletingLastPathComponent)
                                .font(Typography.chrome(size: 9))
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                                .truncationMode(.head)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        app.open(urls: [URL(fileURLWithPath: path)])
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }
}

private struct FileRow: View {
    @ObservedObject var document: Document
    @EnvironmentObject var app: AppState
    @EnvironmentObject var settings: AppSettings

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(document.isDirty ? settings.accentColor : Color.secondary.opacity(0.35))
                .frame(width: 6, height: 6)
                .accessibilityLabel(document.isDirty ? "Unsaved changes" : "Saved")
            Text(document.displayName)
                .font(Typography.chrome(size: 12, weight: app.activeID == document.id ? .semibold : .regular))
                .lineLimit(1)
            Spacer()
            Button {
                app.requestClose(document)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.tertiary)
            .help("Close")
            .accessibilityLabel("Close \(document.displayName)")
        }
        .contentShape(Rectangle())
        .onTapGesture { app.activate(document) }
    }
}
