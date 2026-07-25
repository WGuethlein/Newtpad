# Batch 3 — colour model and themes

Date: 2026-07-25. Branch `feat/theme-model`, on top of v0.11.0.

First of the six batches in HANDOFF §6u. Themes are named in CLAUDE.md principle 4 (*"Personalization
only at the edges — fonts, theme, hotkeys, animations"*) and have never existed: there are **107
hardcoded colour literals across 14 files** and zero occurrences of "theme" in the tree.

## Why this goes before syntax highlighting

**Decided with Wyatt, 2026-07-25.** Syntax highlighting introduces roughly five new colour roles per
format. If the theme model lands after it, every one of those is written as RGB and then migrated —
paying twice on the newest and largest chunk of code in the project. Building the colour model first
means batch 4's lexers emit *role names* and are theme-aware from their first line.

The audit's own suggested order had this backwards; this supersedes it.

## The model

```odin
Color_Role :: enum { ... }              // every semantic slot
Theme :: [Color_Role][4]f32             // total array over the enum
g_theme: Theme                          // one global, read by array index
```

A **total array over the enum** is the same compiler-enforced pattern as `[Command_Id]Command`: a new
role cannot be added without every theme being forced to give it a value, and an `#assert` on the
length keeps it honest. That property is the reason to use an array rather than a struct of named
fields or a map.

Reads are a plain array index on a global. `doc_draw` runs per visible row and the chrome redraws
every frame, so the lookup must not allocate, hash, or call through anything.

### Roles come from what the code actually does

Not invented. Derived from the 107 existing literals, which already show the role structure —
`{0.16, 0.18, 0.22}` is the scrollbar track in three separate files, `{0.42, 0.48, 0.60}` the thumb in
three, `{0.95, 0.88, 0.55}` the find-bar accent in three. `ui_tabs.odin:27-29` is already a small
theme array with `// strip background` / `// inactive tab` / `// active tab` comments, and
`markdown.odin` already names ten roles (`MD_TEXT`, `MD_HEAD`, `MD_CODE`…). **Generalise that
pattern; do not invent a second one.**

Categories: document (text, caret, selection, find match, find current, gutter, gutter text), chrome
(background, border, scrollbar track/thumb, split divider), tabs, menu, palette, find bar, status
(normal and warning), filter banner, the ten markdown roles, table, history, and link.

**Plus the syntax roles batch 4 will need** — keyword, string, number, comment, type, punctuation,
and the format-specific ones (JSON key, XML tag, XML attribute). Declaring these now, unused, is the
entire reason this batch goes first. They will be visibly unused until batch 4; that is intended and
should be commented as such so nobody deletes them as dead.

## Two built-in themes, and the light one is the point

**Dark** reproduces today's appearance exactly. **Light** is the second, and it is not a bonus — it
is the test that can fail.

Building only a dark theme proves nothing: every colour in the tree was chosen against a dark
background, so a dark-only theme model is indistinguishable from a rename. A light background is what
exposes the colours that silently assumed dark — muted greys that vanish against white, overlays
tuned for a dark base, a caret that disappears. Those discoveries are the value of this batch, and
they should be reported as they surface rather than quietly adjusted.

## Theme files

`%APPDATA%\Newtpad\themes\*.theme`, one `role #rrggbb` per line. Deliberately the same key/value
shape as `settings.txt`, which already ignores unknown keys so *"an older build reading a newer file
degrades instead of failing"*. Same property here: an unknown role name is skipped, a malformed
colour falls back to the built-in value for that role rather than producing black.

One Settings row selects the theme by name. **Not a colour picker per role** — that is exactly the
option-count leakage CLAUDE.md principle 3 warns about. Editing a `.theme` file is the power-user
path; the UI stays one choice.

## The regression guard

**The Dark theme must reproduce today's rendering exactly.** That turns a 107-site migration from
"trust the diff" into a mechanical check: if any pixel changes, the migration is wrong. Every role's
value in Dark equals the literal it replaced, and that is asserted rather than eyeballed.

This matters because a 107-literal migration across 14 files is precisely the kind of change where
one transposed digit is invisible in review and obvious in use.

## Testing

Headless `themetest`:

- **every role is set in every built-in theme** — a zero-value entry is `{0,0,0,0}`, i.e. transparent
  black, which would render as an invisible hole rather than an obvious error. The total-array type
  guarantees a slot exists; it cannot guarantee somebody filled it in;
- Dark's value for each role equals the literal it replaced (the regression guard above);
- a `.theme` file round-trips;
- an unknown role name in a file is ignored, not fatal;
- a malformed colour (`#zzz`, `#12`, missing `#`) falls back to the built-in rather than to black;
- Light differs from Dark in every role that is not deliberately shared — a light theme that
  accidentally inherits a dark value is the failure this catches.

Plus the compile-time `#assert` on the array length.

## Out of scope

- Per-role colour pickers in Settings.
- Animations and rebindable keys — the other two items in CLAUDE.md principle 4. Rebindable keys are
  batch 8; animations are not planned.
- Theme hot-reload on file change.
- Anything in `src/platform` — the two colour literals there (`window.odin`, `text.odin`) are a
  window-frame colour and a glyph-atlas clear value, neither of which is a themeable UI surface.
  Leave them.

## Verification owed to Wyatt

This environment cannot see the screen. After the migration, the Dark theme should be pixel-identical
to what he uses today — if anything looks different, the migration is wrong, and that is the single
most useful thing he can check. Then switching to Light and looking for text that vanishes, borders
that disappear, or a caret that cannot be found.
