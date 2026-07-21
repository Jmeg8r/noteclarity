# Shipping a 10-PR train against a live GUI app — seams, oracles, and GitHub traps

**Date:** 2026-07-20 · **Project:** NoteClarity v2.0 (10 PRs, brainstorm → plan → ship in one session)

## Problem
Extend v1's "verify a GUI app headlessly" approach to a multi-PR release train while the
app under test was RUNNING on the same machine, and while stacking PRs through
rebase-merges with an intermittently rate-limited review bot.

## What worked

1. **Environment seams beat environment tricks.** A `HOME` override does NOT redirect
   `FileManager.applicationSupportDirectory` — the first test run silently hit the real
   support dir (harmless only by luck: zero dirty docs). The fix that paid for itself ten
   times over: tiny env-var seams in the app (`NOTECLARITY_SUPPORT_DIR`,
   `NOTECLARITY_UPDATE_API`). Every subsequent feature's battery ran isolated from the
   live instance. Add the seam the FIRST time isolation matters, not the third.
2. **Chained oracles expose invisible behavior.** A clean-document silent reload leaves no
   session.json trace — indistinguishable from "watcher never fired." Chaining events
   (replace file → reload → DELETE file) forces the missing-state path to export the
   buffer as a draft, whose content proves what the reload put in memory.
3. **Test the algorithm before the wiring.** The marker-shift math (planned by a subagent)
   was wrong for deletions ending exactly on a newline — span-based deltas undercount by
   the trailing-boundary line. Caught in plan review by hand-tracing, pinned by a 20-assert
   `swiftc` battery BEFORE any AppKit wiring existed. Newline-count deltas
   (`newNewlines − oldNewlines` from the pre-edit lineStarts) are the correct invariant.
4. **Convert silent-failure risks into launch-time asserts.** An @objc-optional delegate
   method with a wrong signature compiles and never gets called. A `#if DEBUG`
   `responds(to: #selector(...))` assert in init made every headless battery launch prove
   the wiring. (The compiler also caught the optionality variant — near-miss signatures
   ARE diagnosed; wholly-wrong ones aren't.)
5. **Distinguish gate-blocked from behavior-proved.** First failure-path test "passed"
   only because the weekly gate suppressed the fetch entirely. Isolating the failure leg
   (delete the timestamp first) turned a vacuous pass into a real one. Ask of every green
   assert: what else would make this pass?

## GitHub traps (rebase-merge PR trains)
- Merging a base PR with `--delete-branch` **closes** stacked PRs (retarget is not
  guaranteed), and after a post-closure force-push the PR is **permanently unreopenable**.
  Safe order: merge base *without* delete → `gh pr edit <dep> --base main` → rebase +
  force-push dep → delete base branch.
- `pull_request` workflows filtered to `branches: [main]` never run for stack-internal
  PRs; CI first appears at retarget. Budget for it.
- Bot reviewers rate-limit; "fail" checks that read "Review rate limited" are noise, not
  verdicts — but say so explicitly in the record when merging past them.

## Signing/notarization facts worth keeping
- `xcodebuild build` injects `get-task-allow` even in Release — only the **archive** path
  produces the notarizable signature. Verify entitlements on the archived app.
- JSC plugin host under hardened runtime needs exactly `com.apple.security.cs.allow-jit`;
  proof = plugins activating (panel state) + zero AMFI log lines on a signed archive run.
- `notarytool store-credentials` needs the human (app-specific password) — surface that
  blocker early, not at ship time.
