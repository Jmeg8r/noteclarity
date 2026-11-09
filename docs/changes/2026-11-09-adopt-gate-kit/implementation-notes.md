# Implementation notes: 2026-11-09-adopt-gate-kit

## Decisions
- **Xcode build and tests run locally, not on the forge (James, 2026-11-09).** The forge
  has no macOS runner, so every forge `build` job was cancelled unscheduled. Linux-safe
  checks move to `.forgejo/workflows/ci.yml`; `xcodebuild test` is a required local check
  with its output on the PR; GitHub Actions keeps `.github/workflows/ci.yml` as a
  post-merge backstop. A forge macOS runner was considered and left for a separate
  sovereign-forge change.
- **Workflow copied from divtrack's consumer, adapted like llm-lab's and agentic-os's.**
- **Gate kit plus the Linux CI job only.** No Loop kit; PR 17's local kit stays separate.

## Adversarial panel (2026-11-09, before approval)
- **Correctness seat.** A local `xcodebuild test` on `main` writes the real defaults
  domain (production bundle id, `UserDefaults.standard`, plugin seeding re-enables bundled
  plugins), so the bootstrap's own Xcode run was dropped. Every open PR needs a new head
  (cancelled statuses on 18 and 19, none on 17), in the order 18, then 19 and 17. A
  `workflow-placement` job now fails if `.github/workflows/` grows beyond `ci.yml`,
  because Forgejo ignores that directory and `forge-pr` cannot see a missing check.
  The GitHub backstop is now verified at each merge SHA. Tailnet addresses in the
  public mirror are recorded in the threat model.
- **Evidence seat.** Standards 2 and 3 described PR 18's end state, not `main`; they are
  worded as rules for changes with the `main` gaps named. 4, 5, 7, 8 and 10 were narrowed
  to what the code does (grant disable lives in `PluginManager`; the rule list is skipped
  under the `network` permission; two bridge blocks capture no instance; one existing
  assert). Recon fixes: `AI_REVIEW_ENABLED` is already `true`; all four forge runs were
  PRs; the GitHub backstop has never run on a mirror push.
- **Check made in this session:** James's real defaults
  (`~/Library/Preferences/com.jmeg8r.noteclarity.plist`) were last modified 2026-11-08,
  before this session; the evidence seat's test run used its own bundle id.

## Deviations
_None yet._
