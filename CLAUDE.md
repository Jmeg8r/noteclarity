# NoteClarity — project instructions

## Design System
Always read DESIGN.md before making any visual or UI decisions.
All font choices, colors, spacing, chrome metrics, icon rules, and aesthetic
direction are defined there ("Ink & Phosphor"). Do not deviate without
explicit user approval; record approved deviations in DESIGN.md's Decisions
Log. In QA mode, flag any code that doesn't match DESIGN.md.

## Verification
Headless verification uses the `NOTECLARITY_SUPPORT_DIR` and
`NOTECLARITY_UPDATE_API` env seams so test runs never touch the real session
or live instance. See `learnings/` for the established techniques.
