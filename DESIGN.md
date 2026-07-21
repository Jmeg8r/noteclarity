# Design System — NoteClarity · "Ink & Phosphor"

Source of truth for every visual decision in NoteClarity. Read this before any
UI change. Deviations require explicit approval and a Decisions Log entry.

## Product Context
- **What this is:** Native macOS text/code editor — a spiritual Notepad++ clone
  with macOS craft (SwiftUI shell, TextKit 2, JavaScriptCore plugin system).
- **Who it's for:** Developers and power users who miss Notepad++ on the Mac.
- **The memorable thing (every decision serves this):** *Serious plain-text
  power tool* — visible capability, no toy aesthetics.
- **Project type:** Native macOS app (not web). Tokens live in the asset
  catalog, not CSS.

## Aesthetic Direction
- **Direction:** Industrial/utilitarian with a phosphor undertone — "lab
  equipment for text." Two registers: **Ink** (light) and **Phosphor** (dark).
- **Decoration level:** Minimal. Typography, hairlines, and one green signal do
  all the work. The only glow in the entire system is the icon's caret bloom.
- **Mood:** Quiet confidence. First-3-seconds target is *recognition*
  ("someone who does this for a living made these calls"), never cuteness.
- **The landscape this positions against:** CotEditor owns friendly light
  green; Zed owns austere monochrome; Nova owns dark maximalism. NoteClarity
  is the instrument panel — BBEdit's attitude, modern craft.
- **Hard rules:** No gradients in chrome. No vibrancy/translucency in
  density-critical chrome (tab bar, status bar, gutter). No mascots, no
  letter-mark. Hairlines are the only structuring device.

## Color

**Rule: tint the furniture, not the ink.** Surfaces may carry low-saturation
green; body text stays near-neutral. Green *means* something — caret, active
tab, saved state, focus — and is never decorative. Warnings are amber, errors
red, always.

| Token (asset catalog) | Ink (light) | Phosphor (dark) | Role |
|---|---|---|---|
| `EditorBackground` | `#FAFBFA` | `#161A16` | The buffer |
| `ChromeSurface`* | `#F1F3F1` | `#1E221E` | Tab bar, status bar, gutter, sidebar — ONE tone |
| `EditorText` | `#16181A` | `#E4E6E3` | Primary text |
| `TextMuted`* | `#6E766F` | `#7C8A7E` | Line numbers, secondary labels |
| `NppGreen` (accent) | `#157A46` | `#3FE28A` | THE signal. Dark gets brighter, not grayer |
| `Hairline`* | `#D8DCD6` | `#353A35` | All dividers, 1px |
| `EditorCurrentLine` | surface @ ~55% | surface @ ~55% | Current-line wash |
| `EditorChangedUnsaved` | `#B08030` | `#C9A05A` | Amber change bars |
| `EditorChangedSaved` | `#157A46` @ 75% | `#3FE28A` @ 75% | Green change bars |
| `EditorBookmark` | `#3A78B8` | `#4A90D9` | Bookmark dots |

\* new colorsets to add; existing `GutterBackground`/`GutterText` collapse into
`ChromeSurface`/`TextMuted` values (names may stay, values unify).

**Syntax tokens** (muted so user content never outshines the accent):

| Token | Ink | Phosphor |
|---|---|---|
| Keyword | `#157A46` | `#6CC894` |
| String | `#8A6A28` | `#C9A66B` |
| Comment (italic) | `#8A928B` | `#7C8A7E` |
| Number | `#4A6E96` | `#8FB8D8` |
| Type | `#3A6E58` | `#A0C4B0` |

## Typography
- **Editor buffer:** **Iosevka** (Term build), 13pt default, line-height ~1.7.
  Real italics for comments. Bundled (SIL OFL — an asset, not a code
  dependency). SF Mono remains in the font picker as fallback/choice.
- **Chrome (tabs, status bar, labels):** **Iosevka Aile** 11–12pt — the
  editor's proportional sibling. One type DNA all the way down; this is
  deliberate departure #3 (nobody in the category does it).
- **Fallback stack:** SF Pro (chrome) / SF Mono (editor) whenever the bundled
  faces are unavailable. Never a third family.
- **Numerals:** tabular everywhere data lives (gutter, status bar) — layout
  must never shift as values change.
- **Loading:** bundle WOFF-free TTFs under `Resources/Fonts/`, register via
  `ATSApplicationFontsPath` in Info.plist.
- **Scale:** editor 13pt · chrome 12pt · status detail 11pt · settings body
  13pt. No display sizes inside the app; the app is not a poster.

## Spacing & Chrome Metrics
- **Base unit:** 4pt, compact density.
- **Tab bar:** 30pt tall, text-forward, filename-first, dirty dot 6px, close
  on hover. Active tab = 2pt accent top rule + editor-background fill. No pills.
- **Status bar:** 22–24pt, hairline-segmented; every segment with an action is
  clickable; INS/OVR state renders in accent when active.
- **Gutter:** ChromeSurface fill, hairline right edge, tabular numerals in
  TextMuted, current line's number in EditorText. Change bars 3px at the left
  edge; bookmark dot 7px. Markers never grow.
- **Editor insets:** 16pt horizontal, 6–8pt vertical.
- **Hovers:** immediate, subtle (opacity/underline) — nothing moves.

## App Icon — "The Caret"
- **Concept:** the act of editing, not the container. A hard-edged phosphor
  caret (`#3FE28A`) left-of-center like text at a margin, three trailing
  dimmer text bars, restrained bloom behind the caret only, on a flat
  `#161A16` field (the app's own dark editor color). **No letter, no document,
  no pen.**
- **16px test:** survives as one green stroke + trailing mass on near-black.
  Bloom drops below 32px.
- **Formats:** classic 10-size AppIcon iconset now (artwork generated by
  script, see `Scripts/`); macOS 26 Icon Composer `.icon` (Liquid Glass
  layers: field / bars / caret+bloom) as an additive follow-up — the flat
  artwork is layered so Tahoe support is never a redo.
- **Fixed appearance:** one icon for light and dark systems (recognition over
  adaptation — VS Code/iTerm2 precedent).

## Motion
- **Approach:** minimal-functional. Native transitions only; the single
  sanctioned animation is the caret blink. Nothing bounces, nothing floats.

## Release/Web Branding (README, GitHub releases)
- Renders like a terminal, not a SaaS page: `#161A16` panels, Iosevka Aile
  headings, changelog-terse copy, hairline rules, real app chrome as the hero
  image. No lifestyle imagery, no gradient blobs.

## Decisions Log
| Date | Decision | Rationale |
|------|----------|-----------|
| 2026-07-20 | System created via /design-consultation (research + Codex + Claude voices, all three risks accepted) | Convergent finding: green-as-signal instrument panel is the open lane; CotEditor owns friendly light green |
| 2026-07-20 | Accent evolved `#2E9E44`→`#157A46` (ink) / `#4CC763`→`#3FE28A` (phosphor) | Escape Bootstrap-success-green; dark mode brightens rather than grays |
| 2026-07-20 | Icon = The Caret (no letter) | Ownable pictogram; survives 16px; Xcode-isn't-an-X principle |
| 2026-07-20 | Chrome set in Iosevka Aile (risk accepted) | The whole window announces the tool; category first |
