# Remediating a 16-finding code review in one focused pass

**Date:** 2026-07-21 · **Project:** NoteClarity (branch `fix/code-review-remediation`)

## Problem
CODE_REVIEW_REPORT.md landed 6 P1s (plugin-boundary bypasses, silent data loss,
design nonconformance), 7 P2s, 3 P3s. Fix what's fixable without a rewrite, prove it.

## Approach that worked
1. **Work the report's own remediation order, commit per remediation step.** Security
   boundary → data loss → tests → design → CI. Each commit message names the finding
   IDs it closes — the PR review maps 1:1 back to the report.
2. **Grants bound to code identity, verified adversarially.** Permissions persist as
   {permission set, SHA-256(plugin.json + main.js)}. The proof wasn't the unit test —
   it was the live tamper test: headless-launch the app (NOTECLARITY_SUPPORT_DIR seam),
   `echo "// tampered" >> main.js`, relaunch, and watch `defaults read` show the plugin
   auto-disabled while its siblings stayed enabled.
3. **Writing the tests found two real bugs the review missed** (both P1-04-class):
   - BOM-less UTF-16 ASCII is byte-valid UTF-8 (every other byte is NUL), so a
     strict-UTF-8-first detection order silently opened UTF-16 files as NUL-riddled
     UTF-8 — and the next save converted the file. The NUL-parity heuristic must run
     BEFORE the UTF-8 check.
   - Foundation's UTF-16 decoder is *lenient* (odd-length bodies, lone surrogates
     decode "successfully"), so "String(data:) != nil" does NOT mean a save will
     round-trip. Require a byte-identical re-encode before calling a decode clean;
     otherwise fall back to Latin-1, which is bijective per byte and therefore
     round-trips anything exactly.
4. **WKWebView lockdown recipe** (panel = local document, nothing else): nonpersistent
   data store + navigation policy (allow only the initial `.other` main-frame load;
   open https link-activations externally; cancel the rest) + compiled
   WKContentRuleList blocking `^https?://`/`^wss?://` subresources — and FAIL CLOSED
   if rule-list compilation errors. Bridge handler checks `frameInfo.isMainFrame` and
   `securityOrigin.protocol == "file"`.
5. **Hand-authoring a test target in a modern pbxproj is ~9 objects**: synchronized
   root group, native target (product-type bundle.unit-test) with TEST_HOST/
   BUNDLE_LOADER, container proxy + dependency, 2 configs + list, product ref — plus
   a scheme Testable. Gotcha: also add the new group to the main group's children, or
   Xcode quietly rewrites the project with a "Recovered References" group.
6. **Cleaning up after headless verification matters.** The smoke test wrote v2 grants
   (bound to the *scratch* seed's digests) into the real defaults domain; left there,
   they would have disabled James's real plugins at next launch (his on-disk bytes ≠
   scratch digests). Restore: delete the v2 key, keep v1 — the designed legacy-adoption
   path then binds to his real bytes on first launch.

## Gotchas worth remembering
- `npx typescript` fails on npm ≥9 ("could not determine executable") because the
  package's bins are `tsc`/`tsserver`; use `npx -y -p typescript@<ver> tsc …`.
- macOS icon "bloom" discipline: a radial NSGradient at 0.85× glyph height reads as a
  wash over the whole tile; 0.45× at α0.22 reads as a glow. Check the rendered PNG,
  not the code.
- `lineHeightMultiple` multiplies the font's *natural* line height, not the em size —
  to land on a spec like "line-height 1.7", normalize: `1.7 * pointSize /
  NSLayoutManager().defaultLineHeight(for: font)`.
