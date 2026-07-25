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

**Dark** is today's appearance, consolidated per the merge table below — close enough that nothing
should look *wrong*, but deliberately not pixel-identical. **Light** is the second, and it is not a
bonus — it is the test that can fail.

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

## Consolidation, and what replaced the regression guard

**Revised 2026-07-25 after measurement.** A faithful one-role-per-literal model came to **66 roles**,
which is a theme nobody would author. Clustering the 61 distinct values by chroma and luminance showed
the real structure: the neutrals are a ramp with far more steps than anyone can distinguish, while the
accents are genuinely semantic.

- **Neutrals: 42 values across 81 sites collapse to 10 roles.** `text_muted` alone was seven shades
  doing one job — `#6B758A`, `#6B788F`, `#6B7A99`, `#737D91`, `#7A8599`, `#808A9E`, `#808CA3` —
  indistinguishable side by side.
- **Accents: 19 values to 15 roles.** These carry meaning; merging them loses information.
  (An earlier draft said 23 — that count came from the clustering script's chroma split, which filed
  several blue-tinted greys as accents before they were reassigned to the neutral ramp. The table
  below is authoritative.)

**Total: 25 roles**, plus the 9 syntax placeholders.

### The cost, and what the guard becomes

Consolidation changes rendered colour at roughly 50 sites. Each shift is small — `#6B758A` becoming
`#737D91` is imperceptible in isolation — but **Dark is therefore no longer pixel-identical to
v0.11.0**, which forfeits the original mechanical guard ("if any pixel changes, the migration is
wrong").

That guard was a means, not the goal. It is replaced by a weaker but still mechanical one:

> **Every colour change is an intended merge, enumerated in advance.** The role table below lists
> exactly which literals collapse into which role. A site whose colour changes to something *not* on
> that list is a bug; a site whose colour is unchanged when the table says it should merge is also a
> bug.

So the migration's check moves from "prove nothing changed" to "prove only the listed merges
happened" — which the test can still assert mechanically, because the mapping is data.

### The role table

Neutrals (10):

| Role | Absorbs | Sites |
|---|---|---|
| `bg_base` | `#171C29` `#1A1F29` `#1C212B` | 6 |
| `bg_panel` | `#1F242E` `#1F2430` `#212633` `#242933` `#242936` `#262B38` | 7 |
| `bg_raised` | `#292E38` `#293345` | 4 |
| `border_subtle` | `#333B4C` `#3D4554` | 4 |
| `border_strong` | `#475266` `#4C576B` | 7 |
| `text_muted` | `#6B758A` `#6B788F` `#6B7A99` `#737D91` `#7A8599` `#808A9E` `#808CA3` | 18 |
| `text_dim` | `#8C99B2` `#94A3C2` `#99A3B8` `#9EADCC` `#A8B2C7` | 8 |
| `text_secondary` | `#B8C2D6` `#B8C7E0` `#BFC9DB` `#BFCCE0` `#CCD6E6` | 7 |
| `text_primary` | `#DBE6F5` `#E0E8F5` `#E6EBF7` `#EBF0FA` `#F0F5FC` `#F2F5FC` | 15 |
| `text_bright` | `#F5F5FA` `#FAFCFF` `#FFFFFF` `#D1E6FA` | 5 |

Accents (15): `selection_doc` (`#334C7A`), `selection_list` (`#33476B` `#334C73` `#3D4C6B` `#2E3D57`),
`caret` (`#F2D959`), `accent` (`#F2E08C` `#CCC280`), `find_match_bg` (`#6B6129`), `link` (`#73B2FA`),
`warning` (`#F28C59`), `danger` (`#BF2929`), `success` (`#8CD999`), `filter_bg` (`#2E4233`),
`filter_text` (`#B2E6BD`), `md_heading` (`#B8D9FF`), `md_code` (`#F2CCA6`), `md_italic` (`#CCDBC7`),
`md_quote` (`#A8B89E`).

**Which member of a merged set becomes the role's value** is a judgement call to make and record per
role — generally the one with the most sites, so the fewest pixels move.

## Testing

Headless `themetest`:

- **every role is set in every built-in theme** — a zero-value entry is `{0,0,0,0}`, i.e. transparent
  black, which would render as an invisible hole rather than an obvious error. The total-array type
  guarantees a slot exists; it cannot guarantee somebody filled it in;
- Dark's value for each role is one of the literals the merge table says that role absorbs — so a
  role can only ever hold a colour that genuinely appeared in the pre-migration UI, and a typo'd
  digit produces a value on no list and fails;
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

This environment cannot see the screen. Dark is *deliberately* no longer pixel-identical to v0.11.0 —
roughly 50 sites shift slightly as part of the consolidation. So the check is not "did anything
change" but "does anything look **wrong**": a label that lost contrast against its background, a
border that vanished, two things that used to be distinguishable now reading as the same. Then switching to Light and looking for text that vanishes, borders
that disappear, or a caret that cannot be found.
