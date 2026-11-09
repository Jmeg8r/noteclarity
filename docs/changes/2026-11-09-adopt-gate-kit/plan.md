---
change: 2026-11-09-adopt-gate-kit
status: accepted
track: T3
intent: ./intent.md
spec: ./spec.md
accepted_by: james (2026-11-09)
linear: pending
---
# Plan: forge AI review gate in noteclarity

Revised after the adversarial panel (see spec.md **[panel]** notes).

1. **Standards text.** James approved the 10 standards in spec.md as written (2026-11-09).
   → verify: approved text recorded in spec.md.
2. **Artifacts.** Commit intent, spec, plan and implementation notes on
   `chore/adopt-gate-kit` (from `main` `a3e73f2`).
   → verify: `git branch --show-current` before the commit.
3. **Gate kit.** `ai-review.yml` from divtrack forge `origin/main` 9ff77bd, header and
   standards comment changed; both `bin/` scripts from sovereign-forge `origin/main` after
   `git fetch` and a check of open PRs touching them.
   → verify: `cmp` clean; template diff only in comments; YAML parses.
4. **Forge CI.** `.forgejo/workflows/ci.yml` with `plugin-contracts` and
   `workflow-placement` (R3), 10-minute timeouts.
   → verify: YAML parses; both jobs' commands pass locally on this branch, and the
   placement check fails on a planted `.github/workflows/x.yml`.
5. **CLAUDE.md.** Number the sections; add `## 3. Standards` with the approved text and
   `## 4. CI and merging` (forge checks; required local Xcode run with evidence for app
   changes, and the real-defaults warning until PR 18 lands; GitHub backstop).
   → verify: extractor count equals the approved bullets.
6. **Codex.** Full branch against explicit `origin/main`, posted verbatim with PASS/FAIL.
   No local Xcode run: the bootstrap changes no Swift, and on `main` a run writes the
   real defaults.
7. **Bootstrap PR.** Open against `main`; James merges in the UI.
   `AI_REVIEW_ENABLED` is already `true`, so the gate is live on merge.
   → verify: `check-gate-kit.sh --repo noteclarity` CURRENT; forge `ci.yml` green on the
   `main` push; the GitHub run at the merge SHA, recorded whatever its result.
8. **PR 18 at a new head.** Merge `main` into it; keep its `plugin-contracts` change in
   `.github/workflows/ci.yml` for GitHub and mirror it in `.forgejo/workflows/ci.yml`
   (calling `Scripts/check-plugins.sh`); run `Scripts/test.sh` locally; re-run Codex; push.
   → verify: `forge-pr status 18` shows forge CI green and a gate verdict bound to its
   run; Codex and `Scripts/test.sh` output posted. Merging PR 18 is James's decision.
9. **PRs 19 and 17 afterwards.** Once PR 18 merges: merge `main` into PR 19 (or close it
   and let the doc refresh regenerate it), and tell PR 17's owner to move
   `secret-scan.yml` to `.forgejo/workflows/` (the placement check enforces it).
   → verify: neither has a cancelled status at its head.

## Deviations
Recorded in `./implementation-notes.md`.
