import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Hosts a document's AppKit editor stack, swapping the active controller's
/// scroll view in place when the tab selection changes.
struct EditorContainerView: NSViewRepresentable {
    let controller: EditorController?

    func makeNSView(context: Context) -> NSView {
        NSView()
    }

    func updateNSView(_ view: NSView, context: Context) {
        guard let controller else {
            view.subviews.forEach { $0.removeFromSuperview() }
            return
        }
        let scrollView = controller.scrollView
        guard scrollView.superview !== view else { return }
        view.subviews.forEach { $0.removeFromSuperview() }
        scrollView.frame = view.bounds
        scrollView.autoresizingMask = [.width, .height]
        view.addSubview(scrollView)
        DispatchQueue.main.async {
            scrollView.window?.makeFirstResponder(controller.textView)
        }
    }
}

/// Renders a plugin panel's WKWebView; the web view instance is owned by the
/// PanelController and survives re-parenting.
struct PanelWebView: NSViewRepresentable {
    let controller: PanelController

    func makeNSView(context: Context) -> NSView { controller.webView }
    func updateNSView(_ view: NSView, context: Context) {}
}

/// A right/bottom plugin panel host with a tab picker when several plugins
/// contribute to the same area.
struct PluginPanelArea: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var plugins: PluginManager
    let location: PanelLocation

    private var panels: [PanelController] {
        plugins.panels(at: location)
    }

    private var selectionBinding: Binding<String?> {
        switch location {
        case .right: return $app.selectedRightPanelID
        case .bottom: return $app.selectedBottomPanelID
        case .left: return .constant(nil)
        }
    }

    private var selected: PanelController? {
        let id = selectionBinding.wrappedValue
        return panels.first { $0.id == id } ?? panels.first
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                if panels.count > 1 {
                    Picker("", selection: Binding(
                        get: { selected?.id ?? "" },
                        set: { selectionBinding.wrappedValue = $0 }
                    )) {
                        ForEach(panels) { panel in
                            Text(panel.title).tag(panel.id)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                } else {
                    Text(selected?.title ?? "Panel")
                        .font(Typography.chrome(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    if location == .right { app.rightPanelVisible = false }
                    else { app.bottomPanelVisible = false }
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Hide panel")
                .accessibilityLabel("Hide panel")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            Divider()
            if let panel = selected {
                PanelWebView(controller: panel)
                    .id(panel.id)
            } else {
                Spacer()
            }
        }
        .background(Color("ChromeSurface"))
    }
}

// MARK: - Main window

struct MainWindowView: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var plugins: PluginManager

    var body: some View {
        VStack(spacing: 0) {
            TabBarView()
            Divider()
            if app.findBarVisible {
                FindBarView()
                Divider()
            }
            HSplitView {
                if app.sidebarVisible {
                    SidebarView()
                        .frame(minWidth: 190, idealWidth: 240, maxWidth: 420)
                }
                centerColumn
                    .frame(minWidth: 360, maxWidth: .infinity)
                    .layoutPriority(1)
                if app.rightPanelVisible && !plugins.panels(at: .right).isEmpty {
                    PluginPanelArea(location: .right)
                        .frame(minWidth: 250, idealWidth: 340, maxWidth: 640)
                }
            }
            Divider()
            StatusBarView()
        }
        .overlay(alignment: .bottomTrailing) { toastStack }
        .toolbar { toolbarContent }
        .navigationTitle(app.activeDocument?.displayName ?? "NoteClarity")
        .navigationSubtitle(app.activeDocument?.url?.deletingLastPathComponent().path ?? "")
        .onDrop(of: [UTType.fileURL], isTargeted: nil) { providers in
            handleDrop(providers)
        }
        .frame(minWidth: 900, minHeight: 560)
        .tint(settings.accentColor)
    }

    private var centerColumn: some View {
        VSplitView {
            EditorContainerView(controller: app.activeController)
                .frame(minHeight: 220, maxHeight: .infinity)
                .layoutPriority(1)
            if app.bottomPanelVisible && !plugins.panels(at: .bottom).isEmpty {
                PluginPanelArea(location: .bottom)
                    .frame(minHeight: 130, idealHeight: 210, maxHeight: 440)
            }
        }
    }

    private var toastStack: some View {
        // DESIGN.md motion rule: nothing moves — toasts fade only. Chrome is
        // opaque ChromeSurface with a hairline border; no materials, no pills.
        VStack(alignment: .trailing, spacing: 8) {
            ForEach(app.toasts) { toast in
                Text(toast.text)
                    .font(Typography.chrome(size: 12))
                    .lineLimit(4)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(Color("ChromeSurface"))
                    .overlay(
                        Rectangle()
                            .strokeBorder(Color("Hairline"), lineWidth: 1)
                    )
                    .transition(.opacity)
            }
        }
        .padding(.trailing, 16)
        .padding(.bottom, 40)
        .allowsHitTesting(false)
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button {
                app.sidebarVisible.toggle()
            } label: {
                Image(systemName: "sidebar.left")
            }
            .help("Toggle Sidebar")
            .accessibilityLabel("Toggle Sidebar")
        }
        ToolbarItemGroup {
            Button {
                app.showFindBar(focusReplace: false)
            } label: {
                Image(systemName: "magnifyingglass")
            }
            .help("Find (⌘F)")
            .accessibilityLabel("Find")

            Toggle(isOn: $settings.wordWrap) {
                Image(systemName: "text.wrap")
            }
            .toggleStyle(.button)
            .help("Word Wrap")
            .accessibilityLabel("Word Wrap")

            Menu {
                Picker("Appearance", selection: $settings.appearance) {
                    ForEach(AppearanceMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } label: {
                Image(systemName: "circle.lefthalf.filled")
            }
            .help("Appearance")
            .accessibilityLabel("Appearance")

            Button {
                app.bottomPanelVisible.toggle()
            } label: {
                Image(systemName: "rectangle.bottomthird.inset.filled")
            }
            .disabled(plugins.panels(at: .bottom).isEmpty)
            .help("Toggle Bottom Panel")
            .accessibilityLabel("Toggle Bottom Panel")

            Button {
                app.rightPanelVisible.toggle()
            } label: {
                Image(systemName: "sidebar.right")
            }
            .disabled(plugins.panels(at: .right).isEmpty)
            .help("Toggle Right Panel")
            .accessibilityLabel("Toggle Right Panel")
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        var accepted = false
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            accepted = true
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                var url: URL?
                if let data = item as? Data {
                    url = URL(dataRepresentation: data, relativeTo: nil)
                } else if let u = item as? URL {
                    url = u
                }
                if let url {
                    DispatchQueue.main.async {
                        AppState.shared.open(urls: [url])
                    }
                }
            }
        }
        return accepted
    }
}
