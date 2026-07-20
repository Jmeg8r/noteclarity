import SwiftUI
import AppKit

/// Notepad++-style document tab strip rendered with native SwiftUI controls.
/// The active tab carries the signature green top accent.
struct TabBarView: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 1) {
                    ForEach(app.documents) { document in
                        TabItemView(document: document)
                    }
                }
            }
            Button {
                app.newDocument()
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("New Tab (⌘N)")
            .padding(.trailing, 4)
        }
        .frame(height: 34)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

private struct TabItemView: View {
    @ObservedObject var document: Document
    @EnvironmentObject var app: AppState
    @EnvironmentObject var settings: AppSettings
    @State private var hovering = false

    private var isActive: Bool { app.activeID == document.id }

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(document.isDirty ? settings.accentColor : Color.clear)
                .overlay(
                    Circle().strokeBorder(Color.secondary.opacity(document.isDirty ? 0 : 0.4),
                                          lineWidth: 1)
                )
                .frame(width: 7, height: 7)
                .help(document.isDirty ? "Unsaved changes" : "No unsaved changes")

            Text(document.displayName)
                .font(.system(size: 12, weight: isActive ? .medium : .regular))
                .lineLimit(1)
                .foregroundStyle(isActive ? Color.primary : Color.secondary)

            Button {
                app.requestClose(document)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .frame(width: 14, height: 14)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .opacity(hovering || isActive ? 1 : 0)
            .help("Close Tab (⌘W)")
        }
        .padding(.horizontal, 11)
        .frame(height: 34)
        .background(isActive ? Color(nsColor: EditorTheme.background) : Color.clear)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(isActive ? settings.accentColor : Color.clear)
                .frame(height: 2)
        }
        .contentShape(Rectangle())
        .onTapGesture { app.activate(document) }
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Close Tab") { app.requestClose(document) }
            Button("Close Other Tabs") { app.closeOthers(keeping: document) }
            Divider()
            Button("Reveal in Finder") {
                if let url = document.url {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            }
            .disabled(document.url == nil)
            Button("Copy Path") {
                if let path = document.url?.path {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(path, forType: .string)
                }
            }
            .disabled(document.url == nil)
        }
    }
}
