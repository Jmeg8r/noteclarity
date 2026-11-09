---
change: 2026-11-09-adopt-gate-kit
status: accepted
track: T3
intent: ./intent.md
accepted_by: james (2026-11-09)
linear: pending
skills_in_force: []      # no UI change; security review is the adversarial panel + Codex
sovereign_forge_sha: a5f5ff0
template_sha: 9ff77bd    # divtrack forge origin/main
---
# Spec: forge AI review gate in noteclarity

Evidence marked **[recon]** was read on 2026-11-09 while drafting. **[panel]** marks a
point added after the adversarial review (correctness and evidence seats, 2026-11-09).

## Requirements
- **R1. The gate workflow.** `.forgejo/workflows/ai-review.yml` is divtrack's consumer
  workflow with only its header and standards comment changed, as in llm-lab and
  agentic-os: `pull_request_target` against `main`, arm64 review lane, 70-minute timeout,
  SHA-pinned checkout, gate scripts read from `origin/main` at run time.
  **[recon]** `main` exists and is the default; its rule has push disabled.
- **R2. The gate scripts.** `bin/review-pr.sh` and `bin/blast-radius.py` are byte-identical
  to sovereign-forge `origin/main`, re-read at execution time (a5f5ff0 today).
- **R3. Forge CI for what Linux can check.** `.forgejo/workflows/ci.yml` runs on
  `pull_request` and `push` to `main` on `ubuntu-latest` with a 10-minute timeout:
  - `plugin-contracts`: the two `noteclarity.d.ts` copies are byte-identical and every
    bundled plugin typechecks with TypeScript 5.5.4 (the checks `main`'s macOS job runs
    today). Pinned checkout and `setup-node`, as in PR 18's job that passed on this runner
    (task 3818).
  - **[panel]** `workflow-placement`: fails if `.github/workflows/` holds anything but
    `ci.yml`. Forgejo silently ignores that directory once `.forgejo/workflows/` exists and
    `forge-pr` cannot see a missing check, so a workflow added there (PR 17 adds
    `secret-scan.yml`) would otherwise stop running unnoticed.
- **R4. Xcode stays off the forge, and that is written down.** `.github/workflows/ci.yml`
  keeps its jobs for GitHub Actions on the mirror. `CLAUDE.md` makes a local `xcodebuild
  test` run a pre-merge requirement for PRs that touch app code, tests, the project or
  bundled plugins, with its output on the PR. **[recon]** Forge runs 1 to 4 (all PRs) had
  `build` cancelled with no task. **[panel]** The GitHub backstop is unproven: its last
  `main` run was 2026-07-21, before the forge and its push mirror existed (2026-08-15),
  and `main` has not moved since. The first merge after this change is its first test.
- **R5. Standards.** `CLAUDE.md` gets numbered sections with a `## 3. Standards` section of
  bold bullets ending at `## 4.`, grounded in this repo's record and worded as rules for
  changes. **[recon]** Today's `CLAUDE.md` yields 0 from the extractor.
- **R6. Kill switch.** The gate runs only while `AI_REVIEW_ENABLED` is exactly `true`.
  **[recon]** `BROKER_TOKEN` is set. **[panel]** `AI_REVIEW_ENABLED` is already `true`
  (it was unset at first check on 2026-11-09 and set later the same day), so the gate goes
  live the moment the bootstrap merges.

## Standards (approved by James, 2026-11-09)

Source notes in italics are not copied into `CLAUDE.md`. **[panel]** Two rules (2 and 3)
describe behaviour `main` does not fully have yet; PR 18 brings it. They are worded as
rules for changes, so PR 18 is judged against them as intended.

- **UI changes follow `DESIGN.md` ("Ink & Phosphor").** Fonts, colors, spacing, chrome
  metrics and icon rules come from it; a deviation needs James's approval and an entry in
  its Decisions Log. *(CLAUDE.md Design System; DESIGN.md:4)*
- **Tests and headless runs must never write the real profile.** Code that reads or writes
  app state (support directory, update API, `UserDefaults`) is isolatable through a seam,
  added the first time isolation matters; a `HOME` override redirects neither the support
  directory nor the defaults domain. *(learnings 2026-07-20 v2 train #1, 2026-07-21 #6;
  CLAUDE.md Verification. Gap on `main`: `UserDefaults.standard` is not isolated; PR 18
  adds a per-run bundle id.)*
- **Opening and saving a file never loses bytes silently.** A decode counts as clean only
  if re-encoding gives identical bytes; otherwise the file takes a lossless path (Latin-1)
  or the loss is reported. The NUL-parity UTF-16 check runs before the strict UTF-8 check.
  *(learnings 2026-07-21 #3; `TextModel.swift`. Gap on `main`: a UTF-8 BOM with a bad body
  decodes lossily; PR 18 changes it to the Latin-1 fallback.)*
- **Plugin grants are bound to the plugin's code.** A grant is stored with the SHA-256
  digest of `plugin.json` and `main.js`; when those bytes change the plugin is disabled
  until granted again. *(learnings 2026-07-21 #2; `PluginPolicy.swift:52-57`,
  `PluginManager.swift:239-301`)*
- **The plugin panel web view stays locked down and fails closed.** Non-persistent data
  store; only the initial local main-frame load is allowed; without the `network`
  permission, network subresources are blocked by a compiled rule list, and if it fails to
  compile the panel shows an unavailable page instead of plugin content; the bridge accepts
  only main-frame `file` origins. *(learnings 2026-07-21 #4; `PanelController.swift`)*
- **The plugin API declaration is one contract.** `Plugins/noteclarity.d.ts` and
  `BundledPlugins/noteclarity.d.ts` stay byte-identical, and every bundled plugin
  typechecks against it with TypeScript 5.5.4. *(ci.yml; learnings 2026-07-21)*
- **No JavaScriptCore bridge block strongly captures the plugin instance.** A block stored
  in a `JSContext` that holds the instance strongly keeps the plugin alive forever; use
  `[weak self]`. *(learnings 2026-07-20 headless gotchas; 28 of 30 blocks use it, the
  other 2 capture no instance)*
- **New wiring that would fail silently is proven at launch.** An `@objc` optional
  delegate method, which compiles and is never called when its signature is wrong, gets a
  `#if DEBUG` `responds(to:)` assert. *(learnings 2026-07-20 v2 train #4;
  `EditorController.swift:95`)*
- **A failure-path test proves the failure leg ran.** Isolate it from anything else that
  would make it pass, such as a gate that suppresses the call entirely. *(learnings
  2026-07-20 v2 train #5)*
- **Hardened-runtime entitlements stay exactly `com.apple.security.cs.allow-jit`,** which
  the JavaScriptCore plugin host needs. A change to entitlements or signing is verified on
  the archived app, since only the archive path produces the distributable signature.
  *(learnings 2026-07-20 signing facts; `NoteClarity.entitlements`)*

## Constraints and risks
- **Bootstrap PR is ungated by construction** (`pull_request_target` reads base). James
  merges it in the UI.
- **The Xcode check is enforced by people, not a machine.** Neither the forge nor the AI
  gate can run it; the gate reviews the diff, not the PR body. A forge macOS runner is the
  real fix and is out of scope.
- **Local Xcode runs on `main` write the real defaults.** **[panel]** `main`'s test host
  uses the production bundle id and `UserDefaults.standard`, and seeding re-enables
  bundled plugins in the real profile. So the bootstrap (which changes no Swift) carries no
  Xcode run, and Xcode evidence starts with PR 18's `Scripts/test.sh`, which uses a
  per-run bundle id. Until PR 18 merges, any local run on `main` needs the real domain
  exported and restored around it.
- **Every open PR needs a new head.** **[panel]** PR 18 and PR 19 carry a cancelled
  `CI / build` status at their heads, which keeps `forge-pr` blocked; reopening re-runs
  their own `.github` CI and is cancelled again. PR 17 has no forge status at all. Each
  needs `main` merged in. PRs 18 and 19 conflict in `README.md`, and PRs 17 and 18 both
  edit the Xcode-select step, so they go in order: 18 first, then 19 and 17 rebuilt on
  the new `main`.
- **PR 17's secret scan.** It adds `.github/workflows/secret-scan.yml`; R3's placement
  check fails PR 17 until the scan moves to `.forgejo/workflows/`. Note the push mirror
  copies every branch to the public GitHub repo, where that scan runs only on `main`.
- **Threat model.** Forge repo private, 0 collaborators, 0 forks. **The GitHub mirror is
  public** (0 forks, owner the only collaborator). No `.github` workflow uses
  `pull_request_target`, GitHub ignores `.forgejo/`, and fork PRs there get no secrets.
  **[panel]** New exposure: `ai-review.yml` names the forge and broker tailnet addresses
  (`100.88.14.2:3300`, `:3401`). They are not reachable off the tailnet, but this is the
  first public mirror to carry them. **[recon]** verified 2026-11-09.

## Verification
- `cmp` both scripts; diff the gate workflow against the template (comments only).
- Parse both new workflows; confirm triggers, lanes, timeouts and pinned actions; run the
  `plugin-contracts` and `workflow-placement` commands locally.
- Extractor awk over the new `CLAUDE.md`: count equals the approved bullets.
- After the merge: `check-gate-kit.sh --repo noteclarity` CURRENT; forge `ci.yml` green on
  the `main` push; `gh run list -R Jmeg8r/noteclarity -b main -L 1` shows a run at the
  merge SHA (records whether the backstop fires, and its result).
- PR 18 at its new head: forge CI green, a gate verdict bound to its run, Codex PASS,
  `Scripts/test.sh` output pasted.
