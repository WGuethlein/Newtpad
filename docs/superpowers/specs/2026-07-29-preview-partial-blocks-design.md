# Preview: partial blocks and wrapping tables — design

Two defects Wyatt reported from live use of v0.31.x, both introduced by batch 17's block model.
Branch `fix/preview-partial-blocks`, target **v0.32.0** (table wrapping is a new capability).

---

## 1. A block that does not fit is refused whole, so the pane shows emptiness

**Reported with screenshots.** A heading renders, then ~200px of blank pane. Expand the window by
**one pixel** and the entire following paragraph appears at once.

**Cause, and it is deliberate.** `md_block_fits` (`markdown.odin:1320`) is `ytop + h <= ybot`, and the
admit site (`markdown.odin:2604`) refuses the block outright. The comment states the reason:

> there is no scissor rect in this renderer (clipping is the cover strip main.odin paints afterwards),
> so the only way a block is not cut through the middle of its glyphs is for it not to be ADMITTED.

That trade is defensible for a *heading* — one line, either it fits or it does not. It is wrong for a
paragraph, because a block is now an arbitrary number of shaped lines. The pre-batch-17 renderer had no
such problem: it admitted **per source line**, so it simply stopped mid-paragraph.

**This violates a hard rule.** CLAUDE.md: *"Viewport-first: … No frame ever shows emptiness."* A pane
that ends in 200px of blank because the next paragraph is 210px tall is showing emptiness.

### The fix: admit per line, within the block

The shaper already produces what is needed — `Shaped` carries per-line boxes, and every glyph knows its
line. So the block's lines can be admitted individually: draw while `line_top + line_h <= ybot`, stop at
the first line that does not fit. No new measurement, and no scissor.

**Four things this touches, each of which is where it can go wrong:**

1. **`md_block_fits` stops being the admit test for multi-line blocks.** It stays for the single-line
   case and as the *shape* of the question, but the per-line rule must be **one producer** consumed by
   the draw and by everything that mirrors it. It currently has a second consumer at
   `markdown.odin:3099` — `md_block_at_y`, the click-to-sync map — whose comment says it exists to
   "mirror md_pass's own fit test". If the draw admits three lines of a paragraph and the map still
   thinks the whole block was refused, a click maps to a block that is not there. **That is the seam of
   this task.**
2. **`bottom`.** `md_pass` returns the byte offset past the last block drawn, and the scroll clamp reads
   it. A partially drawn block must not report `b.end`, or the clamp believes lines the user has never
   seen are already behind them. Since the preview now scrolls in pixels (`Md_Anchor{block, px}`), the
   honest answer is that a partially drawn block leaves `bottom` at its *start* — it is not finished —
   and the pixel anchor is what advances into it. Verify that against `md_max_anchor`, which derives the
   scroll ceiling.
3. **`forced`.** The first block waives the fit test so a pane too short for its first block still shows
   something. With per-line admission the waiver narrows to the first *line*, which is strictly better —
   but it is behaviour change and needs stating.
4. **The cover strip stays.** It is still the backstop for a block whose own last line overshoots by a
   sub-pixel, and for the front-matter card, which draws whole.

**Explicitly not doing:** a real scissor rect. It is genuinely owed (three consumers of the cover-strip
hack now), but it is a renderer change, and even with one you would still want per-line admission —
clipping a paragraph mid-glyph is a worse answer than stopping at a line boundary.

### Test

Sweep pane heights across a paragraph's line boundaries and assert: the number of lines drawn increases
by exactly one per line-height of pane, **no drawn line's bottom exceeds `ybot`**, and there is never
more than one line-height of unused pane below the last drawn line (that last one is the assertion that
actually catches the reported bug — the current code fails it by an entire paragraph).

Then the seam: every line the draw emits must be hit-testable back to its own block, at the pane's
bottom edge. `md_draw_selftest`'s headless-GPU readback is the tool — assert pixels, not intentions.

**Sabotage:** restore whole-block admission and confirm the unused-pane assertion fails.

---

## 2. Preview tables ignore the measure and run off the right edge

**Reported with a screenshot** — a wide table's rightmost column is cut by the pane edge.

**Cause.** `md_layout_build`'s `case .Table` (`markdown.odin:2007`) returns **before** the span-building
section, so a table gets no spans, no shaping and no measure. The draw (`markdown.odin:3168`) uses
`md_table_ensure` plus `text_char_width` — fixed-width cells on the character grid. Nothing in that path
knows the measure exists.

### The fix: wrap cell text within its column

Wyatt's choice, and what GitHub, Obsidian and VS Code all do. Each cell wraps inside its column width;
a row's height is the tallest cell in it.

**§9.3 keeps tables on the mono face** — *"always mono: columns align"* — and that is unchanged. Mono is
about the face, not about refusing to wrap.

**Column widths** are a property of the whole block, which `md_table_ensure` already computes. They now
have to be fitted to the measure rather than taken as natural: distribute the measure across columns,
and give a column that needs less than its share the remainder back. §10 has a directly applicable rule
for the *table view* — *"measure the first 200 rows, clamp each column to 8–40 characters, distribute
leftover width proportionally"* — and the same shape applies here even though §10 governs a different
surface. Say in the report whether you reused it or diverged, and why.

**A row's height is the tallest cell.** That is a per-row `max` over shaped cell heights, and it must be
produced **once** and consumed by both the admit decision and the advance — the same single-producer rule
as every other block kind, and the rule whose violation the batch-17 review caught twice.

### What this also fixes, for free

`case .Table`'s early return is why **links inside table cells are not clickable** — a regression batch
17 disclosed but did not fix, on the grounds that emitting rects would need a second producer of cell
geometry. Once cells are shaped, that second producer no longer exists: the shaper places the glyphs, so
the link rects come from it like every other block's. **Close that regression in this task and say so.**

### Test

A table wider than the measure fits inside it; a cell whose text exceeds its column wraps rather than
overflowing; a row's height equals its tallest cell; column alignment holds across rows (the property
mono exists for). Then the link seam: a link in a table cell is clickable where it is drawn.

**Sabotage:** remove the measure fit and confirm the table overflows; break the row-height `max` and
confirm a tall cell is clipped.

---

## Out of scope

- A real scissor rect. Owed, recorded, its own task.
- §9.3's remaining rows: h6 caps and tracking, the *Preview font* setting, the caption/meta row.
- §9.4's preview selection and copy, and the heading tick-mark rail.
- The systemic unchecked-`make`-on-temp exposure (~274 sites) from v0.31.1's crash.
- The suspicion that a fence body's heights are not advance-aware — separate, and still owed.
