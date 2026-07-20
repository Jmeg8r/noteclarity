import SwiftUI

/// Notepad++-density status bar: caret position, selection size, document
/// length/words/lines, then clickable language, encoding, EOL, INS/OVR and zoom.
struct StatusBarView: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var settings: AppSettings

    var body: some View {
        HStack(spacing: 0) {
            Group {
                item("Ln \(app.status.line), Col \(app.status.column)")
                divider
                item("Sel: \(app.status.selectionChars) ch | \(app.status.selectionLines) ln")
                divider
                item("Length: \(app.status.totalChars)  Words: \(app.status.words)  Lines: \(app.status.lineCount)")
            }
            Spacer(minLength: 12)
            Group {
                languageMenu
                divider
                encodingMenu
                divider
                eolMenu
                divider
                insOvrButton
                divider
                zoomMenu
            }
        }
        .font(.system(size: 11))
        .monospacedDigit()
        .padding(.horizontal, 10)
        .frame(height: 25)
        .background(.bar)
    }

    private var divider: some View {
        Rectangle()
            .fill(Color.secondary.opacity(0.25))
            .frame(width: 1, height: 13)
            .padding(.horizontal, 8)
    }

    private func item(_ text: String) -> some View {
        Text(text)
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }

    private var languageMenu: some View {
        Menu {
            ForEach(Language.allCases) { lang in
                Button {
                    app.setLanguageManual(lang)
                } label: {
                    if app.activeDocument?.language == lang {
                        Label(lang.displayName, systemImage: "checkmark")
                    } else {
                        Text(lang.displayName)
                    }
                }
            }
        } label: {
            Text(app.activeDocument?.language.displayName ?? "Plain Text")
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Language (click to change)")
    }

    private var encodingMenu: some View {
        Menu {
            ForEach(FileEncoding.allCases) { encoding in
                Button {
                    app.setEncoding(encoding)
                } label: {
                    if app.activeDocument?.encoding == encoding {
                        Label(encoding.displayName, systemImage: "checkmark")
                    } else {
                        Text(encoding.displayName)
                    }
                }
            }
        } label: {
            Text(app.activeDocument?.encoding.displayName ?? "UTF-8")
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Encoding (click to convert)")
    }

    private var eolMenu: some View {
        Menu {
            ForEach(LineEnding.allCases) { eol in
                Button {
                    app.setLineEnding(eol)
                } label: {
                    if app.activeDocument?.lineEnding == eol {
                        Label(eol.menuName, systemImage: "checkmark")
                    } else {
                        Text(eol.menuName)
                    }
                }
            }
        } label: {
            Text(app.activeDocument?.lineEnding.displayName ?? "LF")
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Line endings (click to convert)")
    }

    private var insOvrButton: some View {
        Button {
            app.toggleOverwrite()
        } label: {
            Text(app.overwriteMode ? "OVR" : "INS")
                .fontWeight(app.overwriteMode ? .bold : .regular)
                .foregroundStyle(app.overwriteMode ? settings.accentColor : Color.secondary)
        }
        .buttonStyle(.plain)
        .help("Insert / overwrite mode (click or press the Insert key)")
    }

    private var zoomMenu: some View {
        Menu {
            Button("Zoom In") { settings.zoomIn() }
            Button("Zoom Out") { settings.zoomOut() }
            Button("Reset Zoom") { settings.zoomReset() }
            Divider()
            ForEach([50, 75, 100, 125, 150, 200], id: \.self) { pct in
                Button("\(pct)%") { settings.zoomPercent = pct }
            }
        } label: {
            Text("\(settings.zoomPercent)%")
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Zoom")
    }
}
