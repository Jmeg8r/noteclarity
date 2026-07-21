import SwiftUI

/// In-window Find & Replace bar: regex, case, whole-word, in-selection scopes,
/// next/prev/all navigation, replace and replace-all with a live match count.
struct FindBarView: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var settings: AppSettings
    @ObservedObject private var find: FindState

    @FocusState private var focusedField: Field?

    private enum Field { case find, replace }

    init() {
        find = AppState.shared.findState
    }

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .font(.system(size: 11))
                TextField("Find", text: $find.query)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                    .frame(minWidth: 160, idealWidth: 240, maxWidth: 340)
                    .focused($focusedField, equals: .find)
                    .onSubmit { app.findNext() }

                toggleChip(".*", isOn: $find.options.useRegex, help: "Regular expression")
                toggleChip("Aa", isOn: $find.options.caseSensitive, help: "Match case")
                toggleChip("W", isOn: $find.options.wholeWord, help: "Whole word")
                toggleChip("Sel", isOn: Binding(
                    get: { find.options.inSelection },
                    set: { app.setFindInSelection($0) }
                ), help: "Search within the selection")

                Button { app.findNext(backwards: true) } label: { Image(systemName: "chevron.up") }
                    .help("Find Previous (⇧⌘G)")
                Button { app.findNext() } label: { Image(systemName: "chevron.down") }
                    .help("Find Next (⌘G)")
                Button("Find All") { app.findAll() }

                Text(find.message)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(minWidth: 90, alignment: .leading)

                Spacer()

                Button {
                    app.findBarVisible = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Close (Esc)")
                .accessibilityLabel("Close Find Bar")
            }
            HStack(spacing: 8) {
                Image(systemName: "arrow.2.squarepath")
                    .foregroundStyle(.secondary)
                    .font(.system(size: 11))
                TextField("Replace", text: $find.replacement)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                    .frame(minWidth: 160, idealWidth: 240, maxWidth: 340)
                    .focused($focusedField, equals: .replace)
                    .onSubmit { app.replaceCurrent() }
                Button("Replace") { app.replaceCurrent() }
                Button("Replace All") { app.replaceAll() }
                if find.options.useRegex {
                    Text("$1…$n for captures")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
                Spacer()
            }
        }
        .controlSize(.small)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Color("ChromeSurface"))
        .onAppear { focusInitialField() }
        .onChange(of: app.findFocusToken) { _, _ in focusInitialField() }
        .onExitCommand { app.findBarVisible = false }
    }

    private func focusInitialField() {
        DispatchQueue.main.async {
            focusedField = app.findFocusReplace ? .replace : .find
        }
    }

    private func toggleChip(_ label: String, isOn: Binding<Bool>, help: String) -> some View {
        Button {
            isOn.wrappedValue.toggle()
        } label: {
            Text(label)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(isOn.wrappedValue ? settings.accentColor.opacity(0.28) : Color.secondary.opacity(0.12))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(isOn.wrappedValue ? settings.accentColor : Color.clear, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
        .accessibilityAddTraits(isOn.wrappedValue ? [.isSelected] : [])
    }
}
