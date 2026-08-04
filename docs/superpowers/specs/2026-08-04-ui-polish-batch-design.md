# UI polish batch — design

From [the full sweep](../../ui-spec-gaps/2026-08-04-full-sweep.md). Wyatt, 2026-08-04: polish batch
first, then status-bar cells → find bar → Show Menu Bar.

This batch is the ~20 single-surface items the sweep found: labels, colours, glyphs, two small
controls. It deliberately excludes anything structural — the status-bar cells, the find bar's missing
controls, Show Menu Bar and markdown table *rendering* are their own jobs.

## Decisions this batch encodes

Taken with Wyatt during the sweep; reasoning lives in the sweep doc under "Decisions taken".

- **C4 — Monaspace Argon is rejected.** Chrome stays monospace. This batch does **not** touch chrome
  type, and §13's "numbers in Neon, words in Argon" rule is dead.
- **C5 — `Open Themes Folder` stays**, though the mockup omits it.
- **C6 — regex keeps `Alt+R`**, label shortens to `Find: Regex`. All three find toggles are Alt
  (`commands.odin:512-514`), matching VS Code's find widget; moving one off Alt breaks the set.
- **Approved:** drop the settings gear, put the mockup's `│ Commands  Ctrl+P` in its place.
- **Not approved:** moving the `>_` button. It stays at the left of the tab rail.

## Two things that are NOT bugs, found while specing

- `FIND_BAR_H_96 :: f32(38)` (`doc.odin:992`) already matches the mockup's 38px. An earlier draft of
  the sweep claimed ~30px from a screenshot estimate. Corrected there.
- The settings gear is deliberate — `menu.odin:2` says it matches Windows 11 Notepad's chrome. Wyatt
  approved removing it anyway, but it is a design reversal, not a defect, and the HANDOFF entry should
  say so in case the reasoning matters later.

---

## Phase 1 — labels and chords (no layout risk)

| # | Item | Site |
|---|---|---|
| P1 | `Find: Regular Expression` → `Find: Regex` | `commands.odin:359` |
| P2 | Zoom In accelerator renders `Ctrl++`; mockup shows `Ctrl+=`. The binding already accepts both (`keymap` row `{.Plus, true, false…}`) — this is display only | chord formatter |
| P3 | `...` → `…` in six labels (`Save As`, `Go to Line`, `Open File`, `Edit Current Theme`, `Edit Keybindings`, `Edit Colour Rules`) | `commands.odin:240,244,303,331-333` |
| P4 | Palette footer → the mockup's `:  124   go to line · type a number` form | `palette.odin:460` |

**Risk:** low. P3 is the one to watch — a wider glyph in a label feeds `dropdown_w`, which sizes a
panel from its widest row. `…` is *narrower* than `...` in a monospace cell grid (1 cell vs 3), so
panels get narrower, not wider. Verify no menu reflows badly.

## Phase 2 — the gear → Commands swap (layout, one seam)

| # | Item | Site |
|---|---|---|
| P5 | Remove the settings gear: metric, draw, hit-test | `menu.odin:65, 959-964, 1313` |
| P6 | Add `Commands  Ctrl+P` + a 1px `Border_Subtle` separator at the menu bar's right end, opening the palette | `menu.odin` menu-bar layout |

**Risk: this is the one real seam in the batch.** The gear has a draw site *and* a hit-test site that
already agree; replacing it with a text item whose width depends on the measured label means the new
control's box must come from **one** producer consumed by draw, hit-test and hover — CLAUDE.md's one
layout per widget, and §6j's whole bug class. Do not compute the `Commands` box twice.

**Seam test required.** Compare the drawn box against the clickable box at boundary widths, then
sabotage it (shift one by a few px) and watch the test fail before restoring.

## Phase 3 — colour and glyph polish (markdown + table + settings)

| # | Item | Site |
|---|---|---|
| P7 | Inline code gets its `Md_Code_Bg` fill + 3px radius in the preview (role exists, unused there) | `markdown.odin` |
| P8 | Blockquote bar → `Accent` (currently reads muted); mockup is a 2px accent bar | `markdown.odin` |
| P9 | List bullets → `•` / `◦` per level | `markdown.odin` |
| P10 | Task checkbox → 14px box, accent tick, done text dimmed (currently a box with `✕`) | `markdown.odin` |
| P11 | Table view zebra striping using `Table_Zebra` (defined, unused) | `table.odin` |
| P12 | Table header band `Bg_Raised` + `Border_Strong` bottom rule | `table.odin` |
| P13 | Settings hint row: add `←→ adjust`, use arrow glyphs not words | `settings.odin:663` |
| P14 | Font page breadcrumb `Settings › Editor font` | `fontpage.odin` |
| P15 | Font page `PREVIEW` in caps | `fontpage.odin` |

**Risk:** low-moderate. P7 and P10 add *quads* to the preview, which has a per-block layout cache —
a fill drawn from the wrong cached rect is exactly Shape B. P11's zebra must key off the **display**
row index, not the source row, or it will stripe wrongly once sorting is on.

## Phase 4 — font enumeration (platform layer, separate risk profile)

Wyatt chose off-thread enumeration excluding symbol charsets.

Replace the curated `FONT_FAMILIES` table (`text.odin:176`) as the *only* source of choices with:

1. Enumerate the system font collection **on a worker thread**, so nothing costs the first frame and
   nothing stalls opening Settings › Editor font.
2. Filter: keep monospaced faces, **exclude symbol/dingbat charsets** (Marlett, Wingdings, AutoCAD
   shape fonts). Do **not** filter on Latin coverage — that would exclude the CJK monospace faces
   (Sarasa Mono, Noto Sans Mono CJK, MS Gothic) Wyatt wants later, and the grid already handles
   full-width: `text_cell_width_at` (`text.odin:896`) returns 0/1/**2** cells, width 2 decided by the
   glyph's real advance, and a CJK fallback is already in the chain (`text.odin:235`).
3. Merge with the curated table so known families keep their exact bold/italic/bolditalic files
   rather than relying on synthesis.

**`text.odin:164`'s comment becomes stale and must be rewritten, not left.** It currently argues
against enumeration on three grounds; two are addressed here (cost → off-thread, filtering → charset
exclusion) and one — localized family names — still needs handling and should be named as owed work
if it is not solved.

**Risk: highest in the batch, and different in kind.** COM lifetime on a worker thread, a font list
that can change under the settings page while it is open, and the `font_choices_refresh` call site
that currently assumes a synchronous rebuild. This phase should land as its own commits and get its
own review pass; it is separable from phases 1–3 and should not block them.

---

## Verification

Per `development-loop.md`: `modeguardtest` first, then HANDOFF §7's full mode list — not a shorter
list this spec invents. Modes this batch can reach: `menutest`, `menuseam` (diff the printed line —
it exits 0 regardless), `settingstest`, `mdtest`, `mdtabletest`, `mdviewtest`, `splittest`,
`tablegridtest`, `tablesorttest`, `keytest`, `palettetest` if present.

**Sabotage every new assertion** and put the FAIL output in the report — not "I verified it fails".
Read the mode's output, not just its exit code.

Build through PowerShell (`.\build.bat`, check `$LASTEXITCODE`) and confirm
`(Get-Item build\newtpad.exe).LastWriteTime` moved before believing any result.

## Deliberately out of scope

Status-bar cells · the find bar's bordered input, `↑`/`↓`, `Filter Ctrl+L` pill and `✕` · Show Menu
Bar · markdown **table rendering** (the broken one) · table sorting · settings group headers and NEW
badges · the focus-ring extension · §16 icon · §17 contrast warnings.
