# Changelog

## 2.0.0 — 2026-07-20

Daily-driver hardening + distribution. Zero third-party dependencies, as ever.

### Added
- **External file-change detection**: clean documents silently reload when their file
  changes on disk (setting, default on); dirty documents prompt Reload / Keep Mine;
  deleted/moved files keep the buffer, flagged with a tab warning badge. Plus a
  `File ▸ Reload from Disk` command and a foreground re-check when the app activates.
- **Bookmarks**: toggle via gutter click or ⌘F2, cycle with F2/⇧F2, persisted in the
  session.
- **Changed-line bars**: Notepad++-style gutter markers — orange for lines edited since
  the last save, green once saved.
- **Document-word autocompletion**: native completion popup fed by the words already in
  the document (⌥Esc; optional auto-popup) — off by default, Settings ▸ Editor.
- **Check for Updates**: manual menu command plus a weekly auto-check against GitHub
  releases (opt-out in Settings ▸ General). Silent on failure; only alerts when it has
  something to say.
- **App icon** (generated placeholder — brand-green tile).
- **CI** (GitHub Actions: Debug + Release builds and an archive dry-run on every PR) and
  a committed shared Xcode scheme.
- **Release pipeline**: `Scripts/release.sh` — archive → Developer ID export → notarize →
  staple → DMG, with publishing gated behind an explicit `--publish` flag.

### Fixed
- **Draft backups are crash-safe**: the session writer no longer wipes the drafts
  directory before rewriting it (a crash in that window silently lost unsaved buffers),
  stray cleanup runs only after the session file commits, and a failed rewrite keeps the
  previous good backup referenced. Document identity now persists across relaunches so
  backup filenames stay stable.

### Changed
- Bundle id is now `com.jmeg8r.noteclarity` (was the `com.example` placeholder), with a
  one-time automatic migration of settings, recents, and plugin permission grants.
- Release builds sign with Developer ID under the hardened runtime (single entitlement:
  `allow-jit` for the JavaScriptCore plugin host). Debug ⌘R builds are unchanged.
- Version numbers are single-sourced from the Xcode project.

## 1.0 — 2026-07-20

Initial release: native macOS Notepad++-style editor — tabs, TextKit 2 editor with
line-number gutter and OVR mode, regex syntax highlighting for 10 languages,
find/replace with regex, encoding and line-ending conversion, session restore, function
list, information-dense status bar, light/dark theming, and a JavaScriptCore plugin
system with WKWebView panels and three bundled plugins.
