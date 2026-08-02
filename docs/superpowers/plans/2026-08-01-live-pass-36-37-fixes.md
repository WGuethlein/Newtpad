# Live-pass fixes — v0.36.0 / v0.37.0 reports

Wyatt completed both live-pass checklists on 2026-08-01. This plan covers the three table/sort
defects he confirmed (A, B, C) plus the two design calls he settled in the same pass (D, E).

Scope decided with him: **A, B, C first**, then D, then E. D and E are decisions, not reports —
the behaviour they change is working as written today.

Root causes below were derived by reading, before any fix (`systematic-debugging` phase 1). Two of
the three are already named in the code as unfinished, which is corroboration rather than a guess.

---

## A — a second sort key truncates EVERY header label

**Report** (§2, and `reported-bugs.md`): *"it does clash like my previous bug mentioned, where its
cutting the name off, only to be brought back with a manual resize"* — headers truncate on sort
while the column's own width does not change.

**Root cause.** `table_draw`'s header pass (`table.odin:3370`) asks
`table_sort_digits_shown(doc)` once — a **document-wide** predicate, true when `nkeys > 1` — and
feeds that single answer to `table_header_label_col` for every column in the loop. The precedence
digit is drawn on at most two columns (`table_sort_mark` gives `rank > 0` only to live keys), but
the *reserve* is paid by all of them, so every header name that filled its column loses a cell plus
a gap the moment a second key exists. Widening the column restores it.

**Not the cause, checked:** `table_compute_widths` walks the piece tree in file order (`p` advances
through the buffer, `table.odin:2667`), so column widths are sort-independent — consistent with his
"the column doesn't change horizontal size".

**Why the uniform rule is still right for the chevron and wrong for the digit.**
`table_header_label_col`'s comment argues reservation must be uniform so the label does not
re-truncate under the pointer. That holds for the chevron: it follows hover, so a per-column reserve
would make text shuffle as the mouse crosses the header. It does not hold for the digit: a digit
appears on a column only when *that column* becomes a key, which is a deliberate gesture on that
column that already re-sorts the whole grid (`table_sort_mark`'s own comment says exactly this about
the sorted column, then the reserve is applied to the unsorted ones anyway).

**Fix.** Make the digit half of the reserve per-column: a column reserves the digit slot only when
it is a live key under a digits-shown sort. The chevron half stays uniform. One predicate, asked per
column, consumed by the label reserve and by `table_sort_mark`'s existing `rank` gate.

**Test.** `tablesorttest`. Assert an unsorted column's label keeps its full cell count under a
2-key sort, and that a key column's label still stops before its digit (the existing
`label_right <= m0.digit_x` check must keep passing).

**Sabotage.** Restore the document-wide `dgts` at the label call and watch the unsorted-column
assertion fail.

---

## B — the header menu is unreachable on a short window

**Report** (§3): *"it does not scroll, there is no scroll bar in this instance, and the menu is
behind the bottom of window menu items"*.

**Root cause**, stated by the code (`menu.odin:848`): *"A flip-up is owed if a context-menu anchor
is ever near the bottom; it is not implemented. Column headers (the intended caller) sit at the top
of the grid, so today's only caller of ctx_x/ctx_y does not reach this case."* The assumption fails
when the window is short enough that the top of the grid **is** near the bottom of the window.
`menu_dropdown_rect` caps `h` from the origin downward and floors it at one row.

Not a safety bug: `menu_item_at` requires `my < height`, so the clipped rows are not clickable.

**Fix (his call): flip up.** When the space below the anchor cannot hold the menu and the space
above it is larger, place the menu's bottom edge at the anchor instead of its top.

**The seam this has to respect.** `menu_dropdown_rect` returns `(x0, w, h)` — no y — and the draw
(`menu.odin:766`) and the hit-test (`menu.odin:923`) each call `menu_origin` for y independently.
A flip computed in one of them and not the other is precisely CLAUDE.md's one-layout violation, and
the failure mode is a menu drawn in one place and clickable in another. So the flip goes **inside
`menu_dropdown_rect`**, which grows to return `(x0, y0, w, h)`; both consumers stop deriving y.

Call sites to update: `menu.odin` ×4 (`menu_draw_dropdown`, `menu_visible_rows`, `menu_item_at`,
plus the rect itself), `test_modes.odin` ×4 (8788, 8835, 9208, 9249).

**Test.** `menuseam` / `menutest`. Assert that at a window height too short for the menu below the
anchor, the drawn box and the hit-test agree, every row is on screen, and the row the hit-test
returns at a given y is the row drawn there.

**Sabotage.** Compute the flip in the draw only (leave the hit-test on `menu_origin`) and watch the
draw/hit-test agreement assertion fail — this is the check that must not be able to pass with the
bug present.

---

## C — clearing a sort leaves the view at an arbitrary offset

**Report** (§6): *"on cycling through sorts, it will take you to the bottom of the table on reset
sometimes, others it'll be the middle"*.

**Root cause.** Every sort transition except the two that CLEAR resets the scroll:
`table_sort_set` ends with `doc.top = table_sort_row_at(doc, 0)` (`table.odin:1452`), and so does
`table_sort_add`. `table_sort_cycle`'s descending→clear branch (`table.odin:1488`) and
`table_sort_drop`'s last-key path deliberately do not, on the reasoning at `table.odin:1443` that
`doc.top` "is already a real byte offset in the file's own order". It is — it is the offset of
whichever row happened to be at the top *in sorted order*, which in file order is an arbitrary
position. Hence bottom, middle, or anywhere, depending on the row.

**Fix (his call): top of the file.** Both clear paths set `doc.top` to the first data row, matching
every other transition. Rewrite the block comment at `table.odin:1439-1446`, which currently argues
for the behaviour being removed.

**Test.** `tablesorttest`. Scroll a fixture deep, clear via the third click, assert `doc.top` is the
first data row; same via `table_sort_drop` of the last key.

**Sabotage.** Remove the assignment on the cycle path and watch it fail.

---

## D — blank cells follow the sort direction (decision, 2026-08-01)

Wyatt: blanks first when ascending, last when descending. Today `Sort_Field.empty` is compared
before direction (`table.odin:1161`) so blanks are last in both, and `table.odin:1111-1121` argues
at length for that rule. **The decision overrides the comment**; rewrite it rather than leaving two
claims in the tree. Per key, unchanged: `af.empty != bf.empty` still decides that key alone.

## E — a sorted cell re-sorts on commit (decision, 2026-08-01)

Wyatt: when an edit is committed the row moves to its new sorted position. Highest-risk item in the
batch — it touches `table_edit_commit`, which is the data-loss seam §1 of the live pass covers — so
it gets its own spec, its own subagent and its own review rather than riding along with A–C.

---

## Order and ledger

| | Item | Files | Test | Done |
|---|---|---|---|---|
| 1 | A — per-column digit reserve | `table.odin` | `tablesorttest` | |
| 2 | C — clear scrolls to top | `table.odin` | `tablesorttest` | |
| 3 | B — menu flip-up | `menu.odin`, `test_modes.odin` | `menuseam`, `menutest` | |
| 4 | D — blanks follow direction | `table.odin` | `tablesorttest` | |
| 5 | E — re-sort on commit | own spec | own plan | |

A and C are both `table.odin` and both land against `tablesorttest`, so they go first and together.
B is the only signature change in the batch and is kept on its own commit for bisectability.

Every step: build via PowerShell (`.\build.bat`, check `$LASTEXITCODE`, confirm
`build\newtpad.exe` LastWriteTime moved), set `NEWTPAD_SESSION_DIR` to a temp dir, run the mode,
**read its exit code**, then sabotage and watch it fail with the output recorded.
