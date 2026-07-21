import SwiftUI
import AppKit
import Combine

// MARK: - Document

enum DocumentFileState: Equatable { case onDisk, missing }

final class Document: ObservableObject, Identifiable {
    /// Stable across relaunches (persisted in session.json) so draft-backup
    /// filenames survive the restore boundary.
    let id: UUID
    @Published var url: URL?
    @Published var isDirty = false
    @Published var fileState: DocumentFileState = .onDisk
    @Published var encoding: FileEncoding
    @Published var lineEnding: LineEnding
    @Published var language: Language
    var languageIsManual = false
    var fileWatcher: FileWatcher?
    var lastKnownModificationDate: Date?
    var isHandlingExternalChange = false

    /// Per-document undo history, kept across tab switches.
    let undoManager = UndoManager()

    /// Bookmarks + changed-line markers; mutated synchronously by the
    /// controller's didProcessEditing and read by the ruler.
    var lineMarkers = LineMarkers()

    /// Text held before the editor controller exists (open / session restore).
    var pendingText: String
    var pendingCursor = 0
    var controller: EditorController?

    private static var untitledCounter = 0
    private let untitledName: String

    var displayName: String { url?.lastPathComponent ?? untitledName }

    var currentText: String { controller?.text ?? pendingText }

    init(url: URL?, text: String, encoding: FileEncoding, lineEnding: LineEnding, language: Language,
         id: UUID = UUID()) {
        self.id = id
        self.url = url
        self.pendingText = text
        self.encoding = encoding
        self.lineEnding = lineEnding
        self.language = language
        if url == nil {
            Document.untitledCounter += 1
            untitledName = Document.untitledCounter == 1 ? "Untitled" : "Untitled \(Document.untitledCounter)"
        } else {
            untitledName = "Untitled"
        }
    }
}

// MARK: - Toasts

struct Toast: Identifiable, Equatable {
    let id = UUID()
    let text: String
}

enum SidebarTab: Hashable {
    case functions, files
    case plugin(String)
}

// MARK: - AppState

/// Application hub: owns documents, the active tab, the plugin manager, session
/// persistence, and all cross-cutting editor operations.
final class AppState: ObservableObject {
    static let shared = AppState()

    let settings = AppSettings.shared
    let plugins = PluginManager()
    let findState = FindState()

    @Published var documents: [Document] = []
    @Published var activeID: Document.ID?
    @Published var status = EditorStatus()
    @Published var overwriteMode = false
    @Published var sidebarVisible = true
    @Published var rightPanelVisible = false
    @Published var bottomPanelVisible = false
    @Published var selectedSidebarTab: SidebarTab = .functions
    @Published var selectedRightPanelID: String?
    @Published var selectedBottomPanelID: String?
    @Published var findBarVisible = false
    @Published var findFocusToken = UUID()
    @Published var findFocusReplace = false
    @Published var symbols: [Symbol] = []
    @Published var toasts: [Toast] = []
    @Published var recentFiles: [String] = []

    private var lastWordCount = 0
    private let highlightDebouncer = Debouncer(0.15)
    private let symbolsDebouncer = Debouncer(0.45)
    private let wordsDebouncer = Debouncer(0.3)
    private let changedEventDebouncer = Debouncer(0.25)
    private let selectionEventDebouncer = Debouncer(0.12)
    private let sessionDebouncer = Debouncer(2.0)
    private let activeRecheckDebouncer = Debouncer(0.25)
    private var settingsSink: AnyCancellable?

    var activeDocument: Document? { documents.first { $0.id == activeID } }

    var activeController: EditorController? {
        activeDocument.map { controller(for: $0) }
    }

    private static let recentsKey = "nc.recentFiles"

    private init() {
        recentFiles = UserDefaults.standard.stringArray(forKey: Self.recentsKey) ?? []
        settings.apply()
        plugins.host = self
        settingsSink = settings.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.applySettingsToEditors() }
        }
        plugins.loadAll()
        restoreSession()
        if documents.isEmpty { newDocument() }
        // Backstop for the kqueue watchers: files changed while the app was
        // in the background are caught the moment it becomes active again.
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            self?.activeRecheckDebouncer.call { self?.recheckAllDocumentsForExternalChanges() }
        }
    }

    // MARK: Support directories

    static var supportDirectory: URL = {
        // Testing seam: headless verification runs point this at a scratch
        // directory so they never collide with the real session (a HOME
        // override does not redirect applicationSupportDirectory).
        if let override = ProcessInfo.processInfo.environment["NOTECLARITY_SUPPORT_DIR"],
           !override.isEmpty {
            let dir = URL(fileURLWithPath: override, isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("NoteClarity", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private static var draftsDirectory: URL = {
        let dir = supportDirectory.appendingPathComponent("Drafts", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private static var sessionURL: URL {
        supportDirectory.appendingPathComponent("session.json")
    }

    // MARK: Editor controllers

    func controller(for document: Document) -> EditorController {
        if let c = document.controller { return c }
        let c = EditorController(document: document, initialText: document.pendingText)
        document.controller = c
        document.pendingText = ""
        c.applySettings(settings)
        c.textView.overwriteMode = overwriteMode
        c.onEdit = { [weak self, weak document] in
            guard let self, let document else { return }
            self.documentEdited(document)
        }
        c.onSelectionChange = { [weak self, weak document] in
            guard let self, let document, document.id == self.activeID else { return }
            self.selectionChanged()
        }
        c.textView.onOverwriteModeChange = { [weak self, weak c] in
            guard let self, let c else { return }
            self.setOverwriteMode(c.textView.overwriteMode)
        }
        c.onBookmarksChanged = { [weak self] in self?.scheduleSessionSave() }
        c.highlightNow()
        // Setting the initial string leaves the caret at the end; restore the
        // session position (0 for freshly opened files).
        c.jump(to: document.pendingCursor)
        return c
    }

    // MARK: Document lifecycle

    @discardableResult
    func newDocument() -> Document {
        let d = Document(url: nil, text: "",
                         encoding: settings.defaultEncoding,
                         lineEnding: settings.defaultLineEnding,
                         language: .plaintext)
        documents.append(d)
        activate(d)
        return d
    }

    func openViaPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        open(urls: panel.urls)
    }

    func open(urls: [URL]) {
        for url in urls { openOne(url) }
    }

    private func openOne(_ url: URL) {
        let std = url.standardizedFileURL
        if let existing = documents.first(where: { $0.url?.standardizedFileURL == std }) {
            activate(existing)
            return
        }
        do {
            let data = try Data(contentsOf: std)
            let (raw, encoding) = FileEncoding.decode(data)
            let eol = LineEnding.detect(in: raw, default: settings.defaultLineEnding)
            let text = LineEnding.normalizeToLF(raw)
            let firstLine = text.prefix(300).components(separatedBy: "\n").first ?? ""
            let language = Language.detect(url: std, firstLine: firstLine)
            let d = Document(url: std, text: text, encoding: encoding, lineEnding: eol, language: language)

            // Notepad++ behavior: an untouched lone Untitled tab is replaced by the opened file.
            let replaceable = documents.count == 1 ? documents.first : nil
            documents.append(d)
            if let r = replaceable, r.url == nil, !r.isDirty, r.currentText.isEmpty {
                documents.removeAll { $0.id == r.id }
            }
            startWatching(d)
            activate(d)
            addRecent(std)
        } catch {
            showToast("Could not open \(std.lastPathComponent): \(error.localizedDescription)")
        }
    }

    func activate(_ document: Document) {
        activeID = document.id
        _ = controller(for: document)
        findState.scopeRange = nil
        findState.options.inSelection = false
        refreshStatus()
        refreshSymbols()
        // "Opened" doubles as buffer-activated so panels track the visible document.
        emitDocumentEvent(.documentOpened, document)
        scheduleSessionSave()
    }

    enum SaveChoice { case save, dontSave, cancel }

    func promptSave(for document: Document) -> SaveChoice {
        let alert = NSAlert()
        alert.messageText = "Do you want to save the changes made to “\(document.displayName)”?"
        alert.informativeText = "Your changes will be lost if you don't save them."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Don't Save")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .save
        case .alertThirdButtonReturn: return .dontSave
        default: return .cancel
        }
    }

    func requestClose(_ document: Document) {
        if document.isDirty {
            activate(document)
            switch promptSave(for: document) {
            case .save:
                guard save(document) else { return }
            case .dontSave:
                document.isDirty = false
            case .cancel:
                return
            }
        }
        forceClose(document)
    }

    func closeActive() {
        if let d = activeDocument { requestClose(d) }
    }

    func closeOthers(keeping document: Document) {
        for d in documents where d.id != document.id {
            requestClose(d)
        }
    }

    private func forceClose(_ document: Document) {
        guard let idx = documents.firstIndex(where: { $0.id == document.id }) else { return }
        document.fileWatcher = nil   // deterministic fd cleanup on rapid open/close
        documents.remove(at: idx)
        if activeID == document.id {
            let next = idx < documents.count ? documents[idx] : documents.last
            if let next { activate(next) }
        }
        if documents.isEmpty { newDocument() }
        scheduleSessionSave()
    }

    // MARK: Saving

    @discardableResult
    func save(_ document: Document) -> Bool {
        guard let url = document.url else { return saveAs(document) }
        return write(document, to: url)
    }

    @discardableResult
    func saveAs(_ document: Document) -> Bool {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = document.url?.lastPathComponent ?? "\(document.displayName).txt"
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        guard write(document, to: url) else { return false }
        document.url = url
        startWatching(document)   // re-point (or first-arm) the watcher at the new path
        if !document.languageIsManual {
            let detected = Language.detect(url: url, firstLine: "")
            if detected != .plaintext, detected != document.language {
                setLanguage(detected, for: document, manual: false)
            }
        }
        addRecent(url)
        return true
    }

    func saveActive() { if let d = activeDocument { save(d) } }
    func saveActiveAs() { if let d = activeDocument { saveAs(d) } }

    private func write(_ document: Document, to url: URL) -> Bool {
        let payload = document.encoding.encode(document.lineEnding.serialize(document.currentText))
        // Bracket the atomic write: it replaces the inode, so the watcher must
        // re-arm afterwards anyway, and tearing it down first guarantees our
        // own save is never reported as an external change.
        document.fileWatcher?.pauseForOwnWrite()
        do {
            try payload.write(to: url, options: .atomic)
        } catch {
            document.fileWatcher?.resumeAfterOwnWrite()
            showToast("Save failed: \(error.localizedDescription)")
            return false
        }
        document.isDirty = false
        document.fileState = .onDisk
        document.lineMarkers.markSaved()
        document.lastKnownModificationDate = Self.modificationDate(of: url)
        document.fileWatcher?.resumeAfterOwnWrite()
        if document.id == activeID { refreshStatus() }   // repaint orange bars green
        emitDocumentEvent(.documentSaved, document)
        scheduleSessionSave()
        return true
    }

    private static func modificationDate(of url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    // MARK: External file changes

    private func startWatching(_ document: Document) {
        guard let url = document.url else { return }
        let watcher = FileWatcher(url: url)
        watcher.onChange = { [weak self, weak document] kind in
            guard let self, let document else { return }
            self.handleExternalChange(document, kind)
        }
        document.fileWatcher = watcher
        document.lastKnownModificationDate = Self.modificationDate(of: url)
        // A restored document's file may have vanished while the app was
        // closed — surface that now instead of waiting for an event.
        if !FileManager.default.fileExists(atPath: url.path) {
            document.fileState = .missing
            document.isDirty = true
        }
    }

    private func handleExternalChange(_ document: Document, _ kind: FileWatcher.ChangeKind) {
        guard !document.isHandlingExternalChange else { return }   // kqueue vs didBecomeActive double-fire
        document.isHandlingExternalChange = true
        defer { document.isHandlingExternalChange = false }
        guard let url = document.url else { return }

        switch kind {
        case .missing:
            document.fileState = .missing
            // No on-disk copy to be clean relative to; dirty also makes the
            // draft-backup system preserve the buffer.
            document.isDirty = true
            showToast("\(document.displayName) was deleted or moved.")
            scheduleSessionSave()
        case .modified:
            guard let data = try? Data(contentsOf: url) else { return }
            let (raw, _) = FileEncoding.decode(data)
            let diskText = LineEnding.normalizeToLF(raw)
            guard diskText != document.currentText else {
                // Byte-identical resave (build tools love these) — no nag.
                document.fileState = .onDisk
                document.lastKnownModificationDate = Self.modificationDate(of: url)
                return
            }
            let reload = (!document.isDirty && settings.autoReloadCleanDocuments)
                || promptReload(for: document)
            if reload {
                let controller = controller(for: document)
                let caret = controller.textView.selectedRange().location
                controller.setTextProgrammatic(diskText)
                controller.jump(to: min(caret, controller.utf16Length), length: 0)
                document.isDirty = false
                document.fileState = .onDisk
                if document.id == activeID { refreshStatus(); refreshSymbols() }
            } else {
                // "Keep Mine": the buffer now diverges from disk.
                document.isDirty = true
            }
            document.lastKnownModificationDate = Self.modificationDate(of: url)
            scheduleSessionSave()
        }
    }

    private func promptReload(for document: Document) -> Bool {
        activate(document)
        let alert = NSAlert()
        alert.messageText = "“\(document.displayName)” changed on disk."
        alert.informativeText = document.isDirty
            ? "You have unsaved changes. Reloading will discard them."
            : "Reload to match the file on disk, or keep the current buffer."
        alert.addButton(withTitle: "Reload")
        alert.addButton(withTitle: "Keep Mine")
        return alert.runModal() == .alertFirstButtonReturn
    }

    func reloadActiveFromDisk() {
        guard let d = activeDocument, d.url != nil else { return }
        handleExternalChange(d, .modified)
    }

    // MARK: Bookmarks

    func toggleBookmarkOnCurrentLine() {
        guard let c = activeController else { return }
        c.toggleBookmark(atLine: c.status().line - 1)
    }

    func jumpToBookmark(backwards: Bool = false) {
        guard let c = activeController else { return }
        let marks = c.document.lineMarkers.bookmarks.sorted()
        guard !marks.isEmpty else { showToast("No bookmarks"); return }
        let currentLine = c.status().line - 1
        // Cyclic, mirroring findNext's wrap behavior.
        let target = backwards
            ? (marks.last { $0 < currentLine } ?? marks.last!)
            : (marks.first { $0 > currentLine } ?? marks.first!)
        guard target < c.lineStarts.count else { return }
        c.jump(to: c.lineStarts[target])
    }

    private func recheckAllDocumentsForExternalChanges() {
        for d in documents {
            guard let url = d.url else { continue }
            guard FileManager.default.fileExists(atPath: url.path) else {
                if d.fileState != .missing { handleExternalChange(d, .missing) }
                continue
            }
            if d.fileState == .missing || Self.modificationDate(of: url) != d.lastKnownModificationDate {
                handleExternalChange(d, .modified)
            }
        }
    }

    // MARK: Edit plumbing

    private func documentEdited(_ document: Document) {
        if !document.isDirty { document.isDirty = true }
        guard document.id == activeID else { return }
        refreshStatus()
        highlightDebouncer.call { [weak self] in
            self?.activeController?.highlightNow()
        }
        symbolsDebouncer.call { [weak self] in
            self?.refreshSymbols()
        }
        changedEventDebouncer.call { [weak self] in
            guard let self, let d = self.activeDocument else { return }
            self.emitDocumentEvent(.documentChanged, d)
        }
        scheduleSessionSave()
    }

    private func selectionChanged() {
        refreshStatus()
        selectionEventDebouncer.call { [weak self] in
            guard let self, let c = self.activeController else { return }
            let sel = c.textView.selectedRange()
            self.plugins.emit(.selectionChanged, [
                "start": sel.location,
                "end": NSMaxRange(sel),
                "length": sel.length,
            ])
        }
    }

    func refreshStatus() {
        guard let c = activeController else { return }
        var s = c.status()
        s.words = lastWordCount
        status = s
        c.ruler.refresh(lineStarts: c.lineStarts, currentLine: s.line - 1,
                        markers: c.document.lineMarkers)
        wordsDebouncer.call { [weak self] in self?.recountWords() }
    }

    private static let wordRegex = try? NSRegularExpression(pattern: #"[\p{L}\p{N}_'-]+"#)

    private func recountWords() {
        guard let c = activeController, let regex = Self.wordRegex else { return }
        let snapshot = c.text
        let docID = activeID
        DispatchQueue.global(qos: .utility).async {
            let count = regex.numberOfMatches(in: snapshot, options: [],
                                              range: NSRange(location: 0, length: (snapshot as NSString).length))
            DispatchQueue.main.async { [weak self] in
                guard let self, self.activeID == docID else { return }
                self.lastWordCount = count
                self.status.words = count
            }
        }
    }

    func refreshSymbols() {
        guard let d = activeDocument, let c = d.controller else {
            symbols = []
            return
        }
        let snapshot = c.text
        let language = d.language
        let docID = d.id
        DispatchQueue.global(qos: .utility).async {
            let found = LanguageRules.extractSymbols(from: snapshot, language: language)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.activeID == docID else { return }
                self.symbols = found
            }
        }
    }

    func jumpToSymbol(_ symbol: Symbol) {
        activeController?.jump(to: symbol.offset, length: symbol.length)
    }

    // MARK: Document property changes

    func setLanguage(_ language: Language, for document: Document, manual: Bool) {
        guard document.language != language || manual != document.languageIsManual else { return }
        document.language = language
        document.languageIsManual = manual
        document.controller?.highlightNow()
        if document.id == activeID { refreshSymbols() }
        plugins.emit(.languageChanged, [
            "language": language.id,
            "path": document.url?.path as Any? ?? NSNull(),
        ])
        scheduleSessionSave()
    }

    func setLanguageManual(_ language: Language) {
        if let d = activeDocument { setLanguage(language, for: d, manual: true) }
    }

    func setEncoding(_ encoding: FileEncoding) {
        guard let d = activeDocument, d.encoding != encoding else { return }
        d.encoding = encoding
        d.isDirty = true
        showToast("Encoding set to \(encoding.displayName) — applied on save.")
        scheduleSessionSave()
    }

    func setLineEnding(_ eol: LineEnding) {
        guard let d = activeDocument, d.lineEnding != eol else { return }
        d.lineEnding = eol
        d.isDirty = true
        showToast("Line endings set to \(eol.displayName) — applied on save.")
        scheduleSessionSave()
    }

    func setOverwriteMode(_ on: Bool) {
        guard overwriteMode != on else { return }
        overwriteMode = on
        for d in documents {
            d.controller?.textView.overwriteMode = on
        }
    }

    func toggleOverwrite() { setOverwriteMode(!overwriteMode) }

    private func applySettingsToEditors() {
        for d in documents {
            d.controller?.applySettings(settings)
        }
        refreshStatus()
    }

    // MARK: Find bar

    func showFindBar(focusReplace: Bool) {
        findBarVisible = true
        findFocusReplace = focusReplace
        findFocusToken = UUID()
    }

    func useSelectionForFind() {
        guard let c = activeController else { return }
        let sel = c.textView.selectedRange()
        guard sel.length > 0 else { return }
        findState.query = (c.text as NSString).substring(with: sel)
    }

    // MARK: Recents

    func addRecent(_ url: URL) {
        var r = recentFiles.filter { $0 != url.path }
        r.insert(url.path, at: 0)
        recentFiles = Array(r.prefix(12))
        UserDefaults.standard.set(recentFiles, forKey: Self.recentsKey)
    }

    func clearRecents() {
        recentFiles = []
        UserDefaults.standard.set(recentFiles, forKey: Self.recentsKey)
    }

    // MARK: Toasts

    func showToast(_ text: String) {
        let toast = Toast(text: text)
        withAnimation { toasts.append(toast) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) { [weak self] in
            _ = withAnimation { self?.toasts.removeAll { $0.id == toast.id } }
        }
    }

    // MARK: Plugin events

    func emitDocumentEvent(_ event: PluginEvent, _ document: Document) {
        plugins.emit(event, [
            "path": document.url?.path as Any? ?? NSNull(),
            "language": document.language.id,
            "length": document.controller?.utf16Length ?? (document.pendingText as NSString).length,
        ])
    }

    func reloadPlugins() {
        plugins.reload()
        if let d = activeDocument { emitDocumentEvent(.documentOpened, d) }
    }

    // MARK: Session persistence

    private struct SessionDoc: Codable {
        var id: UUID?
        var path: String?
        var draft: String?
        var cursor: Int
        var encoding: FileEncoding
        var eol: LineEnding
        var language: Language?
        var dirty: Bool
        var bookmarks: [Int]?
    }

    private struct SessionState: Codable {
        var docs: [SessionDoc]
        var activeIndex: Int
        var sidebarVisible: Bool?
        var rightPanelVisible: Bool?
        var bottomPanelVisible: Bool?
    }

    func scheduleSessionSave() {
        sessionDebouncer.call { [weak self] in self?.saveSession() }
    }

    func saveSession() {
        try? FileManager.default.createDirectory(at: Self.draftsDirectory, withIntermediateDirectories: true)
        var docs: [SessionDoc] = []
        for d in documents {
            let text = d.currentText
            // A discarded (clean) untitled buffer with content was explicitly dropped.
            if d.url == nil && !d.isDirty && !text.isEmpty { continue }
            var entry = SessionDoc(id: d.id,
                                   path: d.url?.path,
                                   draft: nil,
                                   cursor: d.controller?.caretOffset ?? d.pendingCursor,
                                   encoding: d.encoding,
                                   eol: d.lineEnding,
                                   language: d.languageIsManual ? d.language : nil,
                                   dirty: d.isDirty,
                                   bookmarks: d.lineMarkers.bookmarks.isEmpty
                                       ? nil : d.lineMarkers.bookmarks.sorted())
            if d.isDirty {
                let name = d.id.uuidString + ".txt"
                let dest = Self.draftsDirectory.appendingPathComponent(name)
                if (try? text.write(to: dest, atomically: true, encoding: .utf8)) != nil {
                    entry.draft = name
                } else if FileManager.default.fileExists(atPath: dest.path) {
                    // This cycle's write failed; keep referencing the previous
                    // successful backup rather than orphaning it.
                    entry.draft = name
                }
            }
            docs.append(entry)
        }
        let active = documents.firstIndex { $0.id == activeID } ?? 0
        let state = SessionState(docs: docs,
                                 activeIndex: active,
                                 sidebarVisible: sidebarVisible,
                                 rightPanelVisible: rightPanelVisible,
                                 bottomPanelVisible: bottomPanelVisible)
        var sessionCommitted = false
        if let data = try? JSONEncoder().encode(state) {
            sessionCommitted = (try? data.write(to: Self.sessionURL, options: .atomic)) != nil
        }
        // Prune strays LAST, and only once the session state that stops
        // referencing them is durably committed; keyed off dirty membership —
        // not off which draft writes succeeded this cycle — so neither a
        // transient draft-write failure nor a failed session commit can
        // delete a backup something on disk still points to.
        if sessionCommitted {
            pruneStrayDrafts(keeping: Set(documents.filter(\.isDirty).map { $0.id.uuidString + ".txt" }))
        }
    }

    private func pruneStrayDrafts(keeping expected: Set<String>) {
        guard let items = try? FileManager.default.contentsOfDirectory(at: Self.draftsDirectory,
                                                                       includingPropertiesForKeys: nil) else { return }
        for item in items where !expected.contains(item.lastPathComponent) {
            try? FileManager.default.removeItem(at: item)
        }
    }

    private func restoreSession() {
        guard let data = try? Data(contentsOf: Self.sessionURL),
              let state = try? JSONDecoder().decode(SessionState.self, from: data)
        else { return }

        for entry in state.docs {
            var document: Document?
            let draftText: String? = entry.draft.flatMap {
                try? String(contentsOf: Self.draftsDirectory.appendingPathComponent($0), encoding: .utf8)
            }
            if let draft = draftText {
                let url = entry.path.map { URL(fileURLWithPath: $0) }
                document = Document(url: url,
                                    text: LineEnding.normalizeToLF(draft),
                                    encoding: entry.encoding,
                                    lineEnding: entry.eol,
                                    language: entry.language ?? Language.detect(url: url, firstLine: draft.prefix(300).components(separatedBy: "\n").first ?? ""),
                                    id: entry.id ?? UUID())
                document?.isDirty = true
            } else if let path = entry.path {
                let url = URL(fileURLWithPath: path)
                guard let data = try? Data(contentsOf: url) else { continue }
                let (raw, encoding) = FileEncoding.decode(data)
                let eol = LineEnding.detect(in: raw, default: settings.defaultLineEnding)
                let text = LineEnding.normalizeToLF(raw)
                let firstLine = text.prefix(300).components(separatedBy: "\n").first ?? ""
                document = Document(url: url,
                                    text: text,
                                    encoding: encoding,
                                    lineEnding: eol,
                                    language: entry.language ?? Language.detect(url: url, firstLine: firstLine),
                                    id: entry.id ?? UUID())
            } else {
                document = Document(url: nil, text: "",
                                    encoding: entry.encoding,
                                    lineEnding: entry.eol,
                                    language: entry.language ?? .plaintext,
                                    id: entry.id ?? UUID())
            }
            if let document {
                if entry.language != nil { document.languageIsManual = true }
                document.pendingCursor = entry.cursor
                document.lineMarkers.bookmarks = Set(entry.bookmarks ?? [])
                documents.append(document)
                if document.url != nil { startWatching(document) }
            }
        }

        sidebarVisible = state.sidebarVisible ?? true
        rightPanelVisible = state.rightPanelVisible ?? false
        bottomPanelVisible = state.bottomPanelVisible ?? false

        if !documents.isEmpty {
            let idx = min(max(0, state.activeIndex), documents.count - 1)
            activate(documents[idx])
        }
    }

    // MARK: Termination

    func handleTermination() -> NSApplication.TerminateReply {
        for d in documents where d.isDirty {
            activate(d)
            switch promptSave(for: d) {
            case .save:
                guard save(d) else { return .terminateCancel }
            case .dontSave:
                d.isDirty = false
            case .cancel:
                return .terminateCancel
            }
        }
        saveSession()
        plugins.unloadAll()
        return .terminateNow
    }
}

// MARK: - Plugin host conformance

extension AppState: PluginHostContext {
    var activeEditor: EditorController? { activeController }
    var activeDoc: Document? { activeDocument }

    var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    func pluginToast(_ text: String) { showToast(text) }

    func setDocumentLanguage(_ id: String) -> Bool {
        guard let lang = Language(rawValue: id) else { return false }
        setLanguageManual(lang)
        return true
    }

    func revealPanel(_ panel: PanelController) {
        switch panel.location {
        case .left:
            sidebarVisible = true
            selectedSidebarTab = .plugin(panel.id)
        case .right:
            rightPanelVisible = true
            selectedRightPanelID = panel.id
        case .bottom:
            bottomPanelVisible = true
            selectedBottomPanelID = panel.id
        }
    }

    func panelsChanged() {
        let right = plugins.panels(at: .right)
        if right.isEmpty {
            rightPanelVisible = false
            selectedRightPanelID = nil
        } else if selectedRightPanelID == nil || !right.contains(where: { $0.id == selectedRightPanelID }) {
            selectedRightPanelID = right.first?.id
        }
        let bottom = plugins.panels(at: .bottom)
        if bottom.isEmpty {
            bottomPanelVisible = false
            selectedBottomPanelID = nil
        } else if selectedBottomPanelID == nil || !bottom.contains(where: { $0.id == selectedBottomPanelID }) {
            selectedBottomPanelID = bottom.first?.id
        }
        if case .plugin(let pid) = selectedSidebarTab,
           !plugins.panels(at: .left).contains(where: { $0.id == pid }) {
            selectedSidebarTab = .functions
        }
    }
}
