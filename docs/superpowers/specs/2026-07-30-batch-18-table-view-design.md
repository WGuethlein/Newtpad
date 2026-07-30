# Batch 18 — the table view, the empty tab, and the editor surface

Branch `feat/batch-18-table-view`, target **v0.33.0**.

[UI spec](../../ui-spec/newtpad-ui-spec-v1.md) **§10** (table view), **§15** (the empty tab) and **§8**
(editor surface details). Wyatt asked directly whether the CSV table work had shipped — it had not; this
is it.

---

## Prerequisite — the palette has no table roles at all

`grep Table src/program/theme.odin` returns nothing. §10's central claim is *"Column rules are gone.
`table_zebra` carries the eye instead"*, so **`table_zebra` must exist before any of §10 can be built.**
Adding a `Color_Role` touches the enum, both built-in themes, the key/name tables `theme_load_file` and
`theme_export` read, and the `#assert`-style completeness checks — the theme model was built to make this
routine, so follow its existing shape rather than inventing one.

Check while there whether §10 needs any other role that does not exist (the malformed-row bar wants
`warning`; the header wants `bg_raised` + `border_strong`, both of which do exist).

---

## §10 — the table view

Ten rules. Grouped by what they touch, because they are not independent:

### Group A — appearance, no new state

- **Column rules are gone**, replaced by `table_zebra`. §10's reasoning: a vertical line per column is
  *"8 extra quads per screen and it makes the grid louder than the data."*
- **Empty cells show an em dash** in `text_dim`. §10: in the screenshot a blank first column *"reads as
  broken parsing; a dash says 'empty, and we know it'."*
- **Header is a real header:** `bg_raised` plus a 1px `border_strong` rule beneath, **sticky on scroll**.
- **Metrics:** header 30px, rows 26px, cell padding `0 10`.

### Group B — new layout, still no persistent state

- **Row numbers:** a 56px right-aligned gutter in `text_dim`, `text_secondary` on the current row. §10:
  *"Where there is no row-number gutter, counting rows by hand is the gap."* Note the editor already has
  a `GUTTER_W` concept defaulting to 0 — decide deliberately whether to reuse it or keep the table's
  separate, and say which.
- **Column widths from a sample:** measure the first 200 rows, clamp each column to 8–40 characters,
  distribute leftover width proportionally. **Batch 17's preview tables already implement exactly this
  rule** (`md_table_fit_cells`) — reuse it or say why the surfaces genuinely differ. Two implementations
  of one rule is the shape this project keeps getting bitten by.
- **Numeric and date columns right-align**, detected by sampling the first 200 rows. §10: *"Right-aligned
  numbers with `tnum` is the difference between a table and a text dump."*
- **Drag a header edge to resize; double-click to fit content.**

### Group C — new state, and the two that carry real risk

- **Click the header to sort, with an accent arrow. Sorting is view-only and never rewrites the file.**
  That last clause is the whole design: the sort is a permutation over row indices, not an edit. **The
  table view is already an editing surface** (`table_edit_start`/`commit` exist), so a sorted view must
  map a visible row back to its real byte range or an edit will write to the wrong line. That is the
  seam, and it is a data-loss seam — test it as one.
- **Malformed rows are marked, not hidden.** A row with the wrong field count gets a 2px `warning` bar on
  its left edge and stays in place. §10: *"Silently dropping data in a data viewer is the worst possible
  failure."*
- **Summary row at the bottom:** row count, column count, active sort.

### The seam, stated once

`table_cell_at` maps a pixel to `(row, col, field_start, field_end)` and the edit path writes that byte
range. Sorting, row numbers and the sticky header all change the mapping from pixel to row. **One
producer must own that mapping**, consumed by the draw, the hit-test, the edit and the link hit-test —
CLAUDE.md's rule, and this surface has a live editing path so the cost of getting it wrong is a write to
the wrong row.

**Test the seam, not the unit:** with a sort active, click a cell, assert the byte range it resolves to is
the one under the cursor, and assert an edit lands there. Do it at the first and last visible row, with a
malformed row in the set.

---

## §15 — the empty tab

Small, and mostly about restraint:

- **The caret is already there,** top-left, blinking. *"The page is empty because it is an empty document,
  not because the app has not loaded."*
- **Three hints, bottom-left, `text_dim`:** `Ctrl+O` open a file / `Ctrl+P` commands / `drop` a file
  anywhere in this window. They **vanish on the first keystroke — never fade, never animate.**
- **No logo, no welcome, no recent-files grid.** §15 is explicit: *"A splash screen would undo the one
  thing the app is best at."*
- **Drop target:** dragging a file over the window draws a 2px accent inset ring on the **editor area
  only** — no overlay, no text, no dimming.

---

## §8 — editor surface details

Audited: several of these are absent rather than rough, and one is the single highest feel-per-line item
in the spec.

- **16px of top padding.** §8: *"Text starting flush against the menu bar is the clearest 'unfinished'
  signal in the screenshots. This one change does more for the feel than any colour."* `TEXT_MARGIN_Y`
  exists — verify what it actually is before assuming this is missing.
- **Caret 2px, `caret` role, 500ms blink, stops while typing and for 500ms after.** `grep` finds **no
  blink implementation at all**. §8's reason for 2px: *"1px carets disappear at 150% on a bright line."*
  A blink needs a timer the frame loop reads, and the loop currently wakes on input — check how the
  polling path (`session_dirty`, `search_running`) already schedules wakeups and reuse it, or a blinking
  caret will either not blink when idle or burn a wakeup every 500ms forever.
- **Gutter 44px right-aligned + 12px gap, off by default**, current line `text_primary`, others
  `text_muted`. `GUTTER_W` exists and is 0 — check whether the rest is built.
- **Current-line tint off by default, 3% when on.** §8: *"More turns a wrapped paragraph into stripes."*
- **Wrap indent:** a wrapped line continues at the original indent + 2 columns.
- **Wrap column cap:** cap the text column at 100 characters in wrap mode and left-align. §8: *"On a
  maximised 1440p window an uncapped wrap gives 200-character lines."*
- Already believed done, verify rather than rebuild: selection as a run of rects per visual line, the 8px
  scrollbar with a 24px minimum thumb, find/bookmark tick marks, the link underline at 35% alpha
  thickening on Ctrl-hover.

---

## Sequencing

1. **The `table_zebra` role** — nothing in §10 group A can start without it.
2. **§10 group A** — appearance only, no state, immediately visible to Wyatt.
3. **§10 group B** — layout. Reuse batch 17's column-fit rule.
4. **§10 group C** — sort, malformed marking, summary. **The sort/edit seam is the batch's real risk**;
   it lands last and gets its own review.
5. **§15 and §8** — independent of all the above, and §8's caret blink is the one item there with a
   non-obvious interaction (the wakeup schedule).

## Out of scope

- Complex-script shaping, colour emoji.
- §9.2 item 6's zebra rows in the **markdown preview** table — a different surface from §10's table view,
  and still owed from batch 17.
- The async link resolver; the systemic unchecked-`make`-on-temp exposure; the `md_link_at` y-bound.
- §9.3's h6 caps, the *Preview font* setting; §9.4's preview selection and the heading tick rail.
- Whether preview paragraphs should join soft-broken lines — a design question in
  [reported-bugs.md](../../reported-bugs.md), for Wyatt.
