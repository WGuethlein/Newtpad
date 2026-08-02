# Column filtering — batch 20

*"would also be nice to filter columns, and have a dropdown list of all items in the column to filter
like powerbi/excel has."* (Wyatt, 2026-07-31). The multi-column sort half shipped as v0.36.0; this is
what was left.

## Decisions, all taken with Wyatt

| | |
|---|---|
| Selection | **Checkboxes with Select All**, Excel/PowerBI style. All ticked by default; untick what you don't want. |
| Past `TABLE_SORT_MAX` (100k rows) | **Refuse and say so** — the same answer and the same limit the sort gives. A partial list of distinct values reads as complete once you are scrolling it. |
| Filter + sort | **Compose.** The filter narrows the row set, the sort orders what is left. |
| Filter + `Ctrl+L` | **Exclusive.** Opening one clears the other (settled when the batch was split). |

## The risk, stated first

**Everything the cell editor writes through resolves via `table_row_start`.** A filter changes which
data row a visible row index means, exactly as the sort did — and `table_edit_commit` splices at a
byte range derived from that. Getting this wrong writes a value onto the wrong row.

The protection already exists and must keep working: `table_edit_line_intact` compares the line's own
BYTES, captured at edit start. A filter that hides the edited row must therefore either commit first
or be caught by that guard. **The batch is not done until a test drives an edit across a filter
change.**

## The model

```odin
Table_Filter :: struct {
    col:     int,              // TABLE_SORT_NONE = inactive
    values:  [dynamic]string,  // distinct values, in first-seen order, OWNED
    on:      [dynamic]bool,    // parallel to values
    view:    [dynamic]i32,     // data-row indices in DISPLAY order (post-sort)
    vrank:   [dynamic]i32,     // data row -> display position, -1 when hidden
    refused: bool,             // too many rows to list
}
```

`view` is the whole trick: it is the sort's `perm` with the hidden rows removed, so **every existing
consumer keeps working by reading one more indirection**. Filter-without-sort is the same array built
from file order instead.

### What changes, and nowhere else

Three producers, the same three the headerless work went through:

- `table_sort_rows` → `len(view)` when filtered.
- `table_sort_row_at(pos)` → `offs[view[pos]]`.
- `table_sort_pos(off)` → the display position of the row containing `off`, or the next VISIBLE one
  when that row is hidden (the forgiving answer it already gives for a mid-line offset).

`table_row_start`'s sorted branch is taken when `table_sorted(doc) || table_filtered(doc)` — one new
predicate, one changed condition.

`offs` is currently built only by `table_sort_build`. A filter needs it with no sort, so the row-index
pass is extracted and both call it.

## Tasks

| | Task | Test |
|---|---|---|
| 1 | `Table_Filter`, `table_row_index_build` extracted from `table_sort_build`, `table_filtered` | `tablefiltertest` |
| 2 | `table_filter_values` — distinct values, bounded, refuses past `TABLE_SORT_MAX` | distinct/order/refusal |
| 3 | `table_filter_apply` — build `view`/`vrank` from `perm` (or file order), compose with the sort | compose with a 2-key sort |
| 4 | The three producers read `view`; `table_row_start` branches on the new predicate | **an edit across a filter change** |
| 5 | The header menu's `Filter…` row, the dropdown with checkboxes and Select All | menu states |
| 6 | Summary row says the filter, and clicking it clears — as it does for the sort | summary text |

Task 4 is the data-loss seam. Its test must reintroduce the bug (make `table_row_start` ignore the
filter) and show a commit landing on the wrong row.

## Notes

- The distinct-value scan is the same shape as `table_sort_build`'s: one line read per row, the key
  cut from it, bounded by `TABLE_SORT_MAX`, refusing rather than truncating.
- Values are stored in **first-seen order**, not sorted: the list is a picture of the column, and
  sorting it hides whether the data is grouped.
- Clearing the filter must put the scroll somewhere sane, the same argument `table_sort_scroll_top`
  settled for the sort.
