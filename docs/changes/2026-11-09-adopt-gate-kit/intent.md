---
change: 2026-11-09-adopt-gate-kit
status: accepted
track: T3
author: james
accepted_by: james (2026-11-09)
linear: pending
source: session 2026-11-09 (Tier 1 review of the coding-principles PRs)
---
# Intent: adopt the forge AI review gate in noteclarity

## Problem
noteclarity has no `ai-review.yml`, so the forge AI review gate never runs here, and
`forge-pr merge` fails closed without a gate verdict. PR 18 (data-integrity and plugin
lifecycle fixes) has Codex PASS (comment 30520) and cannot merge.

Its CI is also broken in a way that hides itself. `.github/workflows/ci.yml` pins its
Xcode `build` job to `macos-15`, and the forge's runners are Linux only (`arm64` review
lane, `ubuntu-latest` CI lane). All four forge CI runs so far (PRs 18 and 19; `main` has
not moved since the cutover) had their `build` job cancelled without ever being
scheduled, so no forge run has built or tested the app. Adding `.forgejo/workflows/` would also make Forgejo ignore `.github/workflows/`
entirely, so the existing CI would stop running on the forge.

## Outcome wanted
- Every PR to `main` gets a forge AI review verdict judged against noteclarity's own
  written standards, and `forge-pr merge` works here.
- The checks that can run on Linux (plugin API contract and bundled-plugin typecheck)
  gate every PR from `.forgejo/workflows/`.
- The Xcode build and tests are a required local check before merge, with the output
  recorded on the PR (James, 2026-11-09). GitHub Actions on the mirror keeps running
  `.github/workflows/ci.yml` after merge as a backstop.
- The workflow stays the template with header and standards comment changed, and the
  gate scripts stay byte-identical to sovereign-forge.

## Out of scope
- A macOS runner on the forge (a sovereign-forge infrastructure change).
- PR 17 (the local lefthook/gitleaks kit), which must move its `.github/workflows/`
  files to `.forgejo/workflows/` before it merges.
- Merging PR 18. That stays James's decision after its new head passes.
