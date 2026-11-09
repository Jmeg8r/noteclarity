# NoteClarity — project instructions

## 1. Design System
Always read DESIGN.md before making any visual or UI decisions.
All font choices, colors, spacing, chrome metrics, icon rules, and aesthetic
direction are defined there ("Ink & Phosphor"). Do not deviate without
explicit user approval; record approved deviations in DESIGN.md's Decisions
Log. In QA mode, flag any code that doesn't match DESIGN.md.

## 2. Verification
Headless verification uses the `NOTECLARITY_SUPPORT_DIR` and
`NOTECLARITY_UPDATE_API` env seams so test runs never touch the real session
or live instance. Those seams do not cover `UserDefaults`: the test host uses the
production bundle id, so a test run writes the real defaults domain (see section 4).
See `learnings/` for the established techniques.

## 3. Standards
The forge AI review gate (`.forgejo/workflows/ai-review.yml`) checks every PR to `main`
against these bullets, read from `main`'s copy of this file.

- **UI changes follow `DESIGN.md` ("Ink & Phosphor").** Fonts, colors, spacing, chrome
  metrics and icon rules come from it; a deviation needs James's approval and an entry in
  its Decisions Log.
- **Tests and headless runs must never write the real profile.** Code that reads or writes
  app state (support directory, update API, `UserDefaults`) is isolatable through a seam,
  added the first time isolation matters; a `HOME` override redirects neither the support
  directory nor the defaults domain.
- **Opening and saving a file never loses bytes silently.** A decode counts as clean only
  if re-encoding gives identical bytes; otherwise the file takes a lossless path (Latin-1)
  or the loss is reported. The NUL-parity UTF-16 check runs before the strict UTF-8 check.
- **Plugin grants are bound to the plugin's code.** A grant is stored with the SHA-256
  digest of `plugin.json` and `main.js`; when those bytes change the plugin is disabled
  until granted again.
- **The plugin panel web view stays locked down and fails closed.** Non-persistent data
  store; only the initial local main-frame load is allowed; without the `network`
  permission, network subresources are blocked by a compiled rule list, and if it fails to
  compile the panel shows an unavailable page instead of plugin content; the bridge accepts
  only main-frame `file` origins.
- **The plugin API declaration is one contract.** `Plugins/noteclarity.d.ts` and
  `BundledPlugins/noteclarity.d.ts` stay byte-identical, and every bundled plugin
  typechecks against it with TypeScript 5.5.4.
- **No JavaScriptCore bridge block strongly captures the plugin instance.** A block stored
  in a `JSContext` that holds the instance strongly keeps the plugin alive forever; use
  `[weak self]`.
- **New wiring that would fail silently is proven at launch.** An `@objc` optional
  delegate method, which compiles and is never called when its signature is wrong, gets a
  `#if DEBUG` `responds(to:)` assert.
- **A failure-path test proves the failure leg ran.** Isolate it from anything else that
  would make it pass, such as a gate that suppresses the call entirely.
- **Hardened-runtime entitlements stay exactly `com.apple.security.cs.allow-jit`,** which
  the JavaScriptCore plugin host needs. A change to entitlements or signing is verified on
  the archived app, since only the archive path produces the distributable signature.

## 4. CI and merging
- **Forge checks.** `.forgejo/workflows/ci.yml` runs `plugin-contracts` and
  `workflow-placement` on every PR and push to `main`; `ai-review.yml` posts the gate
  verdict. Merge with `forge-pr merge`, which needs both green at the PR head.
- **Workflows live in `.forgejo/workflows/`.** Forgejo ignores `.github/workflows/`; only
  `ci.yml` stays there, for GitHub Actions on the mirror. `workflow-placement` fails a PR
  that adds anything else there.
- **Xcode build and tests are a required local check.** The forge has no macOS runner.
  A PR that touches app code, tests, the Xcode project or bundled plugins runs
  `xcodebuild test -project NoteClarity.xcodeproj -scheme NoteClarity -destination
  'platform=macOS' CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO` locally before merge
  and posts the result on the PR.
- **Protect the real defaults during a local test run.** Until the test host gets its own
  bundle id, wrap the run in `defaults export com.jmeg8r.noteclarity <backup.plist>` and
  `defaults import com.jmeg8r.noteclarity <backup.plist>`; seeding otherwise re-enables
  bundled plugins in the real profile.
- **GitHub backstop.** The forge push-mirrors `main` to GitHub, where
  `.github/workflows/ci.yml` builds, tests and archive-dry-runs on `macos-15` after merge.
  Check that run at the merge SHA; it is a backstop, not a merge gate.
