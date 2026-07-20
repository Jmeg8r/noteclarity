# Verifying a GUI macOS app without ever seeing its window

**Date:** 2026-07-20 · **Project:** NoteClarity (Notepad++ clone, one-session build)

## Problem
Ship a complete Xcode project (SwiftUI + TextKit 2 + JavaScriptCore plugin host) and
*prove* it works — from a terminal session with no click-through testing.

## Approach that worked
1. **Hand-author the modern pbxproj (objectVersion 77).** A
   `PBXFileSystemSynchronizedRootGroup` means zero per-file bookkeeping — new Swift
   files are picked up from disk. Two escape hatches needed: a
   `PBXFileSystemSynchronizedBuildFileExceptionSet` with `membershipExceptions =
   (Info.plist)` so the custom plist isn't double-processed, and a classic *blue folder
   reference* (`lastKnownFileType = folder`) for `BundledPlugins/` so plugin folders are
   copied into Resources with structure preserved (synced groups flatten loose files).
2. **Make app state the test oracle.** Launch the binary directly, `kill -0` after N
   seconds for liveness, then read what the app *wrote*: `session.json`, seeded plugin
   folders, `defaults read` for grants. The session file caught a real bug — a fresh
   untitled doc had a draft file, proving programmatic `tv.string =` was tripping the
   dirty flag via `NSTextStorageDelegate`. Fix: a suppress flag captured *synchronously*
   in `didProcessEditing` (the reaction is async; reading the flag later races).
3. **Test pure logic with `swiftc` directly.** Encoding/EOL round-trips compiled as
   `swiftc TextModel.swift main.swift` (top-level statements require the file be named
   `main.swift`) — 14 asserts, seconds to run, no XCTest target needed.
4. **Parse-check embedded JS with the system engine it will run under:**
   `/System/Library/Frameworks/JavaScriptCore.framework/Versions/Current/Helpers/jsc`.
5. **Exercise Launch Services with `open -a <absolute path> file.md`** — verifies the
   `application(_:open:)` path, language detection, recents, and session capture.

## Gotchas worth remembering
- Swift raw strings: `#"""` is a *multiline raw string opener*. A regex needing three
  literal quotes must be written `"{3}` inside `#"…"#`.
- JSExport renames multi-arg methods (`insertAt:text:` → `insertAtText`). Building the
  JS API from `@convention(block)` closures assigned via `setObject(_:forKeyedSubscript:)`
  keeps JS names exactly matching the published `.d.ts`.
- Blocks stored in a `JSContext` retain it; the context retains the instance through
  captures → always `[weak self]` in bridge blocks or the plugin never deallocates.
