# A CSV with no header row

*"csv's with no header are automatically assumed to have a header... not sure how we'd differentiate
this."* (Wyatt, live pass v0.36.0, "OTHER BUGS")

Line 0 is unconditionally the header today. `table_header_fields` reads it, `table_first_data_row`
returns the byte after it, and `table_row_count` subtracts one for it. So a headerless file shows its
first row of **real data** as column titles, in the sticky band, where it cannot be edited, sorted,
found or counted. §10's own rule — *"silently dropping data in a data viewer is the worst possible
failure"* — is what this violates, and it does it to exactly one row.

Decisions taken with Wyatt, 2026-08-01: **conservative heuristic plus an override**, and the override
is **remembered per file and teaches a family default**, the way `remember_views` already does for
the grid itself.

---

## What the spec says, and does not

§10 gives the header band its appearance, its stickiness and its gestures, and says nothing at all
about a table without one. So the band must keep existing when there is no header row — it carries
sort, resize and the column menu — and what it is LABELLED with is a choice this plan makes.

**Columns are named `A`, `B`, `C` … when there is no header row.** Spreadsheet convention, compact
enough for a 30px band and an 8-cell column, and — the deciding reason — it cannot be confused with
the **precedence digits** `1` and `2` that v0.36.0 put in that same band. A positional name of `1`
next to a sort arrow would be ambiguous with the thing that means "this is the first sort key".

One producer, `table_col_label`, used by the band AND by the summary row's prose, so "sorted by A
asc" and the `A` above the column are the same string. It replaces `table_col_name`'s existing
`column %d` fallback, which is a second convention for the same job.

## The heuristic — `table_detect_headerless`

Conservative means: **assume a header unless row 0 looks like data.** Never fires on an ordinary CSV
with text titles, and when it cannot tell, it does nothing.

The evidence is a **type disagreement**, per column, over the sample:

1. Sample the first `TABLE_SAMPLE` (500) rows below row 0, as `table_compute_widths` already does.
2. A column is *numeric-consistent* if every non-empty body cell in it parses as a number
   (`table_is_number`) and there is at least one.
3. If **any** numeric-consistent column has a row-0 cell that is also a number → **headerless**.
   A header cell is a name; a name is not a number.
4. Otherwise → has a header.

An all-text headerless file stays "has header", and that is the conservative direction rather than an
oversight: there is no signal in the bytes to distinguish `alice,london` as a title row from the same
bytes as data. The override is what covers it, which is why there is one.

A file with **no body rows at all** cannot be sampled and keeps a header — unchanged from today.

## The override

A checkable row in the column header menu: **First Row Is Data**. It sits with the sort rows because
that menu is already the per-table surface and this is per-table. Toggling it re-runs nothing: it
sets the flag, drops the width cache and clears the sort (the row set changed, so every offset in the
permutation is one row out — this is the same reason `table_sort_shift` drops a sort when a newline
moves).

## Persistence

- **Per document, in the session**, beside the view state already stored there.
- **Family default**, gated on `app.settings.remember_views` and on `doc.path != ""`, exactly as
  `.Toggle_Table` teaches `settings.table_default`. A user whose logs are all headerless stops
  re-answering.
- The heuristic runs only when there is **no remembered answer** for the file and no family default.
  Order: session value → family default → heuristic.

---

## Tasks

| | Task | Files |
|---|---|---|
| 1 | `doc.table_headerless`, and the three producers branch on it: `table_first_data_row`, `table_header_fields`, `table_row_count` | `doc.odin`, `table.odin` |
| 2 | `table_col_label` — one positional naming producer, replacing `table_col_name`'s fallback | `table.odin` |
| 3 | `table_detect_headerless`, run where the widths are computed | `table.odin` |
| 4 | The menu row, its command, and the invalidation it performs | `menu.odin`, `commands.odin` |
| 5 | Session field + family default | `session.odin`, `settings.odin`, `commands.odin` |

Task 1 is the one with the data-loss shape in it: every offset the sort holds, every row the gutter
numbers and every byte the cell editor splices is derived from `table_first_data_row`. The sort MUST
be cleared when the flag changes, and the test has to prove it — a permutation built over a row set
that has since gained a row at the front resolves every visible row to the line above the one drawn,
which is the commit-onto-the-wrong-row failure that `table_edit_line_intact` exists to catch.

## Tests

`tablesorttest` / `tablegridtest`, and a new `headertest` if the count grows past a handful:

- The heuristic: fires on a numeric-consistent file whose row 0 is numeric; does NOT fire on the same
  file with a text title row; does NOT fire on an all-text file; does NOT fire with no body rows.
- Row 0 is reachable when headerless: it is data row 0, `table_row_count` includes it, the gutter
  numbers it 1, and a cell edit on it lands on its own bytes.
- Toggling the flag with a sort live clears the sort. **Sabotage:** leave the sort standing and show a
  visible row resolving to the wrong line.
- `table_col_label` is the same string in the band and in the summary row.

Every step: `.\build.bat`, check `$LASTEXITCODE`, confirm the exe timestamp moved, set
`NEWTPAD_SESSION_DIR`, run the mode, **read its exit code**, then sabotage and record the failure.
