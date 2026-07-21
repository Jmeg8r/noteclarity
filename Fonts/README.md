# Bundled fonts — Iosevka

DESIGN.md specifies **Iosevka Term** (editor buffer) and **Iosevka Aile**
(chrome) as the app's type stack, bundled as TTFs under SIL OFL 1.1.

Drop the static TTFs here (no build-step needed — this folder ships verbatim
as `Contents/Resources/Fonts`, which `ATSApplicationFontsPath` registers at
launch):

- `IosevkaTerm-Regular.ttf`, `IosevkaTerm-Italic.ttf`, `IosevkaTerm-Bold.ttf`
- `IosevkaAile-Regular.ttf`, `IosevkaAile-Medium.ttf`, `IosevkaAile-SemiBold.ttf`

Download: <https://github.com/be5invis/Iosevka/releases> (the `PkgTTF-IosevkaTerm`
and `PkgTTF-IosevkaAile` packages). Include the OFL license file alongside.

Until the TTFs are present, `Typography` falls back to the documented stack —
SF Mono (editor) / SF Pro (chrome). Nothing else changes.
