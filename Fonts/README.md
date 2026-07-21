# Bundled fonts — Iosevka (SIL OFL 1.1)

DESIGN.md's type stack, shipped verbatim as `Contents/Resources/Fonts` and
registered at launch via `ATSApplicationFontsPath`. License: `LICENSE-OFL.md`.

Bundled (Iosevka v34.7.0, trimmed to ~31 MB by decision 2026-07-21):

- `IosevkaTerm-Regular.ttf` — editor buffer
- `IosevkaTerm-Italic.ttf` — real italics for comments
- `IosevkaAile-Regular.ttf` — chrome (tabs, status bar, labels)

Chrome Medium/SemiBold emphasis currently falls back to the nearest bundled
weight. To restore full emphasis, drop in `IosevkaAile-Medium.ttf`,
`IosevkaAile-SemiBold.ttf` (and `IosevkaTerm-Bold.ttf` for editor bold) from
the `PkgTTF-IosevkaAile`/`PkgTTF-IosevkaTerm` packages at
<https://github.com/be5invis/Iosevka/releases> — no build changes needed.

If the folder is emptied, `Typography` falls back to the documented stack:
SF Mono (editor) / SF Pro (chrome).
