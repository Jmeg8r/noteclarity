# NoteClarity

A native macOS text/code editor — a spiritual clone of Windows **Notepad++**, rebuilt with
macOS conventions: SwiftUI shell, TextKit 2 editor, an information-dense status bar, the
signature green accent, and a **real, extensible plugin system** running community plugins
in JavaScriptCore with WKWebView panels.

Zero third-party dependencies. Apple system frameworks only.

- **Minimum OS:** macOS 14 (Sonoma) · **Xcode:** 16 or newer
- **Bundle id:** `com.jmeg8r.noteclarity`

---

## Build & run

1. Open `NoteClarity.xcodeproj` in Xcode.
2. Select the **NoteClarity** scheme (auto-created) and press **Run** (⌘R).

That's it — no packages to resolve, no scripts, no network. Debug signing is
ad-hoc ("Sign to Run Locally"), so no team account is needed. Release archives
sign with Developer ID + hardened runtime via `Scripts/release.sh` (see the
script header for the one-time notarization setup).

Command line equivalent:

```sh
xcodebuild -project NoteClarity.xcodeproj -scheme NoteClarity -configuration Debug build
```

On first launch the app copies the three bundled plugins into
`~/Library/Application Support/NoteClarity/Plugins/` and enables them. The Markdown
Preview (right panel) and Document Statistics (bottom panel) open automatically;
JSON Formatter adds commands to the **Plugins** menu.

---

## Feature overview

| Area | What ships |
|---|---|
| Tabs | Multi-tab editing, dirty indicators, close-others, drag-and-drop file open, Finder/dock open, Recent Files |
| Editor | TextKit 2, line-number gutter, current-line highlight, monospaced fonts, zoom (25–400 %), word wrap, spaces-or-tabs indentation, overwrite (OVR) mode via the Insert key or status bar |
| Highlighting | Rule/regex tokenizers for Plain Text, JSON, Markdown, JavaScript, TypeScript, Python, Swift, XML, HTML, Shell — auto-detected by extension/shebang, overridable per document |
| Find & Replace | Regex (with `$1…$n` templates), match case, whole word, in-selection scope, next/prev, Find All (multi-select), Replace All with match count |
| Encodings | UTF-8, UTF-8 BOM, UTF-16 LE/BE (BOM-correct read *and* write), ISO-8859-1 read fallback; convert from the status bar |
| Line endings | LF / CRLF / CR detect, display, convert (buffer is LF internally; the ending is applied on save) |
| Session | Reopens previous tabs, unsaved (draft) buffers, cursor positions, bookmarks, and panel layout on launch; drafts are rewritten crash-safely (no destructive wipe) |
| File watching | Clean documents auto-reload when their file changes on disk (setting, default on); dirty documents get a Reload / Keep Mine prompt; deleted files keep the buffer with a tab warning badge; File ▸ Reload from Disk |
| Bookmarks & change bars | Gutter bookmarks — click the gutter or ⌘F2 to toggle, F2/⇧F2 to cycle — plus Notepad++-style changed-line bars (orange = unsaved edit, green = saved) |
| Autocomplete | Document-word completion via the native popup (⌥Esc; optional auto-popup while typing) — Settings ▸ Editor, off by default |
| Updates | NoteClarity ▸ Check for Updates…, plus a weekly auto-check against GitHub releases (opt-out in Settings ▸ General) |
| Sidebar | Function List (regex symbol extraction for Swift, Python, JS/TS; click to jump) + open/recent files; hosts plugin panels declaring `location: "left"` |
| Status bar | Ln/Col · selection chars+lines · length/words/lines · language · encoding · EOL · INS/OVR · zoom — the last five are clickable |
| Theming | Light + Dark first-class via asset-catalog semantic colors; System/Light/Dark override in Settings, the View menu, and the toolbar; Notepad++-green accent (or follow the system accent) |
| Plugins | JavaScriptCore extension host, WKWebView panels, permission gating, Plugin Manager UI — see below |

---

## Architecture

```
NoteClarity/
├── App/            NoteClarityApp (scenes, menus), AppDelegate, AppState (hub), AppSettings
├── Models/         FileEncoding, LineEnding, Language, Debouncer
├── Editor/         CodeTextView (TextKit 2 NSTextView), EditorController (per-tab stack),
│                   LineNumberRulerView, EditorTheme (asset-catalog colors)
├── Highlighting/   SyntaxHighlighter protocol, RegexHighlighter, LanguageRules (+ symbols)
├── Search/         SearchEngine + FindState + find/replace operations
├── UI/             MainWindowView, TabBarView, StatusBarView, FindBarView, SidebarView, SettingsView
└── PluginSystem/   PluginManager, PluginInstance (JSContext bridge), PanelController (WKWebView),
                    PluginModels (manifest/permissions/events)
```

Key decisions:

- **One `EditorController` per document.** Each tab owns its own `NSScrollView` +
  TextKit 2 `NSTextView` + ruler + `UndoManager`. Tab switches re-parent the scroll view,
  so undo history, caret, and scroll position survive for free.
- **`SyntaxHighlighter` is a protocol** taking a string and returning colored spans.
  The shipped `RegexHighlighter` computes off the main thread (generation-checked); a
  tree-sitter implementation can be swapped in later without touching the editor.
- **The buffer is always LF.** Endings are detected on open and re-applied on save,
  which makes EOL conversion a metadata flip.
- **Plugins are isolated.** Each plugin gets its own `JSContext`; the `noteclarity`
  API is built from native blocks so the JS surface matches `Plugins/noteclarity.d.ts`
  exactly. Permission checks run on every call and throw into the plugin's context.

---

## The plugin system

### Package layout

A plugin is a folder in `~/Library/Application Support/NoteClarity/Plugins/<plugin-id>/`:

```
plugin.json      # manifest
main.js          # compiled extension-host entry (from TypeScript)
panel.html       # optional, if the plugin contributes a webview panel
src/             # optional TypeScript sources (for reference / community devs)
```

### Manifest (`plugin.json`)

```json
{
  "id": "com.example.jsonformatter",
  "name": "JSON Formatter",
  "version": "1.0.0",
  "apiVersion": "1.0",
  "author": "Community Dev",
  "description": "Pretty-print or minify JSON in the current selection or document.",
  "main": "main.js",
  "permissions": ["editor.read", "editor.write", "commands", "menu"],
  "contributes": {
    "commands": [{ "id": "jsonFormatter.pretty", "title": "Format JSON" }],
    "menus":    [{ "command": "jsonFormatter.pretty", "location": "plugins" }],
    "panels":   []
  }
}
```

### Permissions

Calls into a capability the manifest didn't request (or the user didn't grant) **throw**
inside the plugin. Grants are surfaced on first enable and stored **bound to the
plugin's code identity** (a digest of `plugin.json` + the entry point): if either file
or the requested permission set changes, the plugin is disabled until you review and
re-enable it. Manifests are validated before load — IDs are ASCII reverse-DNS style
(letters/digits joined by `.`/`-`/`_`), `main` must be a relative path inside the
plugin folder, `apiVersion` must be supported, and duplicate plugin IDs refuse to load.

| Permission | Gates |
|---|---|
| `editor.read` | `editor.getText/getSelection/getCursor/getLineCount/getFilePath/getLanguage` |
| `editor.write` | `editor.setText/replaceSelection/setCursor/insertAt/setLanguage` |
| `commands` | `commands.register/execute` |
| `menu` | `menu.addItem` |
| `ui.panel` | `ui.registerPanel` |
| `ui.dialog` | `ui.showDialog` |
| `fs.read` / `fs.write` | `fs.readFile` / `fs.writeFile` |
| `network` | `net.fetch` — **https only** (plus http to localhost for dev tools) |
| `storage` | `storage.get/set` |

Ungated: `ui.showNotification`, `events.on/off`, `console.log`, and
`context.readResource` (reads only inside the plugin's own folder; containment is
symlink-resolved).

Panels render the plugin's local HTML and nothing else: without the `network`
permission all http(s)/websocket subresource loads are blocked, in-panel navigation
is refused, and clicked `https` links open in the default browser. Bridge messages
are accepted only from the panel's own main frame.

### Lifecycle

1. On launch (and on **Plugins ▸ Reload Plugins**) the host scans the Plugins directory
   and reads each `plugin.json`.
2. For each *enabled* plugin it creates a `JSContext`, injects `noteclarity`, evaluates
   `main.js`, and calls `activate(context)`.
3. Manifest `contributes.commands`/`menus` populate the **Plugins** menu; runtime
   `menu.addItem` and `ui.registerPanel` contributions appear immediately.
4. Disabling calls `deactivate()` (if exported), tears down the context, and removes
   panels/menu items live.

`activate` may be a top-level function, `exports.activate`, or `module.exports.activate`.

#### The activate context

```ts
interface ExtensionContext {
  pluginId: string;
  pluginPath: string;     // the plugin's install folder
  storagePath: string;    // the plugin's persisted-storage JSON file
  appVersion: string;
  readResource(relativePath: string): string;  // read a file shipped in the plugin folder
}
```

### Events

`document.opened` (also fired when a tab becomes active), `document.changed`,
`document.saved`, `selection.changed`, `language.changed`. Payloads carry
`path`/`language`/`length` (document events) or `start`/`end`/`length` (selection).
Change and selection events are debounced (~250 ms / ~120 ms). All offsets across the
API are UTF-16 code units — the same units JavaScript strings use.

### Panel message protocol

Panels are WKWebViews. All messages must be JSON-serializable.

- **Panel → host:** call `window.noteclarity.postMessage(msg)` inside `panel.html`.
  Every callback the plugin registered via `PanelHandle.onMessage(cb)` receives `msg`.
- **Host → panel:** the plugin calls `PanelHandle.postMessage(msg)`; the host evaluates
  `window.__noteclarity_receive(msg)` in the webview. Define that global in your panel.
  Messages sent before the page finishes loading are queued, not dropped.

The conventional handshake (used by the bundled plugins): the panel posts
`{ type: "ready" }` from its inline script; the plugin responds with initial content.

---

## Write your first plugin

A minimal "Uppercase" plugin, from contract to working install:

1. **Create the folder** `~/Library/Application Support/NoteClarity/Plugins/com.you.uppercase/`
   (the Plugin Manager's "Reveal Plugins Folder in Finder" button takes you there —
   `noteclarity.d.ts` sits alongside for editor IntelliSense).

2. **`plugin.json`:**

   ```json
   {
     "id": "com.you.uppercase",
     "name": "Uppercase",
     "version": "1.0.0",
     "apiVersion": "1.0",
     "main": "main.js",
     "permissions": ["editor.read", "editor.write", "commands", "menu"],
     "contributes": {
       "commands": [{ "id": "uppercase.selection", "title": "Uppercase Selection" }],
       "menus":    [{ "command": "uppercase.selection", "location": "plugins" }]
     }
   }
   ```

3. **`src/main.ts`** (authored against the contract):

   ```ts
   /// <reference path="../../noteclarity.d.ts" />
   function activate(context: any): void {
     noteclarity.commands.register("uppercase.selection", () => {
       const sel = noteclarity.editor.getSelection();
       if (sel.text.length === 0) {
         noteclarity.ui.showNotification("Select some text first.");
         return;
       }
       noteclarity.editor.replaceSelection(sel.text.toUpperCase());
     });
   }
   function deactivate(): void {}
   ```

4. **Compile** (any tsc works; no bundler needed):

   ```sh
   tsc src/main.ts --outFile main.js --target ES2019 --lib es2019,dom
   ```

   No TypeScript installed? `main.js` can simply be hand-written JavaScript with the
   same shape — the host only ever loads `main.js`.

5. **Load it:** in NoteClarity choose **Plugins ▸ Reload Plugins**, then enable
   *Uppercase* in **Settings ▸ Plugins**. You'll be shown the requested permissions
   once; the grant is stored. Your command now lives in the Plugins menu.

Want a panel? Request `ui.panel`, ship a `panel.html`, and in `activate`:

```ts
const panel = noteclarity.ui.registerPanel({
  id: "mypanel",
  title: "My Panel",
  location: "right",                                // "left" | "right" | "bottom"
  html: context.readResource("panel.html"),
});
panel.onMessage((msg) => { /* from the webview */ });
panel.postMessage({ type: "hello" });               // to the webview
panel.reveal();
```

Study the three bundled plugins (each ships `src/main.ts`) — together they exercise
every API group: **Markdown Preview** (panels, events, bridge), **JSON Formatter**
(commands, menus, editor read/write), **Document Statistics** (panels, selection events).

---

## Notes & limits (v2.0)

- Syntax coloring is regex-based (fast, dependency-free) and intentionally not a full
  parser; token coloring pauses above ~1.5 MB per document.
- Bundled plugins are granted their manifest permissions at seed time (they ship inside
  the app); hand-installed plugins always get the permission prompt on first enable.
- The app is unsandboxed so plugins' `fs`/`network` capabilities behave as documented
  (this also rules out Mac App Store distribution — direct download only). The hardened
  runtime is enabled with a single entitlement (`allow-jit`, for the JavaScriptCore
  plugin host).
- Bare F2 is intercepted as brightness on most Mac keyboards unless "Use F1, F2, etc. as
  standard function keys" is enabled — use Fn+F2 or click the gutter.
- Changed-line bars are touch-tracked, not content-diffed (undo does not clear them —
  same as Notepad++), and reset on reload/restart.
- Still deferred (v2.1+): column/block selection & multi-cursor (beyond Find All's
  multi-selection), code folding, document map/minimap, macro record & replay, split view.
