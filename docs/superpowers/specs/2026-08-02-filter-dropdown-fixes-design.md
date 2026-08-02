# The column filter's five reported defects — design

2026-08-02. Wyatt, live use on `customers-1000.csv`, immediately after v0.50.0 shipped the
dropdown's cap, scrollbar and search box.

> *"scrollbar direction in the filter menu is wrong. when you filter, and deselect all it shows
> rows still, it should hide anything other than the filter. when you select something it does go
> to the top but there are the other unfiltered rows below there. in the filter menu if you click
> in between options it closes the modal. i think the names/numbers in the modal should be
> alphabetical/numerical ascending"*

Five complaints, four bugs — two of the five are one defect seen twice.

---

## 1. The defects, with root causes

### D1 — the wheel scrolls the list the wrong way

`menu_wheel` (menu.odin) resolves `app.menu.top = clamp(app.menu.top - delta, 0, last)`.

`Window.scroll_delta` is documented `+down / -up` (platform/window.odin) and **every other consumer
adds it**: `doc.filter_top + window.scroll_delta`, `doc.table_hscroll_px + ... * step`,
`doc.h_scroll + ... * 4`, `doc_scroll(doc, &text, window.scroll_delta, rows)`. The dropdown is the
only subtractor in the tree.

Not a scrollbar-rendering bug: the thumb's own position (`ty = y0 + (h - th) * top / span`) is the
right way round. The thumb moves correctly *for the `top` it is given*; `top` is what moves
backwards.

### D2/D3 — rows that no checkbox can hide (**one bug, two symptoms**)

`TABLE_FILTER_VALUES_MAX = 512` stops `table_filter_open` adding distinct values once 512 are
collected. `table_filter_apply`'s `keep()` then returns **true** for any value not in the list,
deliberately — the existing comment argues that hiding rows the user was never shown a checkbox for
is the worse failure.

Both halves are defensible in isolation. Together they mean: on any column with more than 512
distinct values, the rows carrying the 513th value onward are **permanently visible and
uncontrollable**.

Measured against Wyatt's actual file:

```
$ awk -F, 'NR>1{...}' customers-1000.csv
column 3 (First Name): 536 distinct
listed distinct:            512
rows with an unlisted value: 27
first such row: 925   last: 1000
```

His screenshot reads `1,000 rows · 12 columns · filtered by First Name (973 hidden)` over a grid of
27 rows numbered 925 → 1000. That is not a near match, it is the arithmetic. Deselect-all leaves
those 27; ticking one value puts its rows on top with the same 27 still underneath. Both reported
symptoms fall out of the one cause.

**Why the survivors cluster at the end of the file** is worth stating, because it is what made the
bug look like a *rendering* fault rather than a *membership* one: values are collected in first-seen
order, so the cap is reached partway through the file and every value discovered after that point is
unlisted. The unhideable rows are therefore always the file's tail, which reads exactly like "the
filter stopped being applied below a certain row."

### D4 — a click on dead space inside the dropdown closes it

`menu_item_at` returns `-1` for two different situations:

- the point is outside the dropdown, and
- the point is inside the dropdown but on a row with `cmd == .None` — the separator at index 2 and
  the search-box label at index 0.

> **Corrected during implementation.** This list originally also named the scrollbar strip, which was
> an unverified aside carried in from investigation. It is the opposite: the strip is drawn at
> `x0 + w - bw`, *inside* the dropdown's width, and `menu_item_at` bounded x by the full `w` — so a
> click on the strip resolved to the row behind it and **ticked a value**. That is a separate, worse
> defect than the one this section describes, it is aggravated by removing the value cap (a 536-value
> list always has a scrollbar; a 512-capped one often did not), and it is fixed in this batch via a
> shared `scrollbar_w` producer. See HANDOFF §6br.

`menu_hit_test` receives one `-1` and cannot tell them apart, so it takes the "clicked away" branch
and calls `menu_close`.

This is development-loop.md §4 **Shape B** exactly: a correct, tested function (`menu_item_at` does
precisely what it says) whose result is read in the wrong space by its consumer. The countermeasure
is the same one CLAUDE.md prescribes — make the geometry answer the question **once**, in the
producer, rather than have the consumer infer it from a sentinel that means two things.

### D5 — the value list is in first-seen order

Not a bug. A decision, stated in `Table_Filter.values`' comment ("the list is a picture of the
column, and sorting it hides whether the data is grouped") and pinned by an assertion in
`ts_case_filter`. Wyatt is overriding it. Both the comment and the assertion have to be amended, not
worked around — a locked comment that the code contradicts is worse than either.

### D6 — `doc_close` leaks the filter (found during investigation, not reported)

`doc_close` calls `table_sort_free`, which frees `offs`/`perm`/`rank`. Nothing frees
`Table_Filter.values` (one `strings.clone` per distinct value), `on`, `view` or `vrank`. Bounded at
512 small strings per closed table document today; **unbounded to 100k once D2's cap is removed**,
which is why it is in this batch rather than in the debt register.

---

## 2. Decisions taken with Wyatt

Asked before any code, per CLAUDE.md and development-loop.md §0.

| # | Decision | Chosen |
|---|---|---|
| 1 | How to bound the value list | **No cap.** Map-backed collection, search box as the coping mechanism. |
| 2 | Value list ordering | **Type-aware ascending**, blanks last. |
| 3 | `(Select All)` semantics | **Unchanged** — Excel tri-state. |
| 4 | Dead clicks inside the dropdown | **Swallowed, menu stays open** — for every dropdown, not just the filter's. |

### On decision 1

Wyatt proposed PowerBI's "default to 5k, then Load more". Argued against, and he agreed:

1. **The ceiling is already enforced upstream.** `TABLE_SORT_MAX = 100_000` refuses to filter a
   file over 100k rows at all, so a filterable file has at most 100k distinct values. There is no
   unbounded case to defend.
2. **Load-more reduces no cost we actually pay.** Every distinct value must be resident to apply
   the filter. Paging would gate the *rendered rows* only — cosmetic, against a cost that isn't
   there. PowerBI needs it because its list is a remote query over a dataset it does not hold;
   that constraint does not exist for a local scan of a mapped file.
3. **It reintroduces this batch's own bug shape.** A partial load is a value with no checkbox, and
   `(Select All)` becomes ambiguous — all of the loaded 5,000, or all 40,000? That ambiguity *is*
   D2, adopted deliberately.
4. Four new seams (load watermark × search query × scroll position × `(Select All)`) in the file
   whose history says seams are where the bugs come from.

Priced at the true worst case (100k distinct values, i.e. a 100k-row column of unique IDs):
collection is one O(n) pass with a map; ~4–5 MB of cloned strings; ~1–2 ms to rebuild the dropdown
rows per keystroke in the search box; ~1 ms per wheel notch for the clamp. Nothing there is a wall.

**The 512 cap was never buying performance headroom.** It was buying an escape from an O(n²)
`seen` scan in `table_filter_open` — and from a *second*, worse O(rows × values) scan in
`keep()`, which runs on every checkbox click. A map deletes both reasons, so the cap loses its
justification rather than merely being raised.

### On decision 2

Reuses the sort's own type evidence rather than inventing a second notion of "numeric": a column is
numeric iff every non-empty distinct value satisfies `table_is_number`, the same predicate
`table_sort_build` settles each key with. Text compares case-insensitively, with a case-sensitive
tiebreak so the order is total and therefore stable. `""` sorts last unconditionally — it is the
absence of a value, not a small one, and Excel puts it last.

Sorting happens **once, at the end of `table_filter_open`**, before `active` is set and before any
tick exists. That is what makes it safe: `Menu_Item.payload` is an index into `values`/`on`, and
reordering those after a tick exists would silently re-point every checkbox. Reopening the same
column deliberately does *not* rescan (commands.odin), so no live selection is ever reordered.

---

## 3. What is deliberately not changing

- **`(Select All)`'s tri-state.** Wyatt's "deselect all" complaint was D2 wearing a disguise; the
  control itself behaves as Excel's does.
- **`keep()`'s fail-open branch.** With no cap, an unseen value can only mean the document's bytes
  changed between `open` and `apply`. Showing a row is still the right answer there, so the branch
  stays — but its comment must stop describing a cap that no longer exists, or it becomes the next
  session's confident wrong explanation.
- **`menu_dropdown_rect` as the single geometry producer.** D4's fix adds a *consumer* of it, not a
  second copy of the rect.

## 4. The affordance added with decision 1

Wyatt accepted the option whose text included a distinct-value count "so a huge list announces
itself". Implemented by folding the count into the existing search-box label rather than adding a
row: `Type to search… (536 values)`, and `Search: ann_ (12 of 536)` once a query narrows it.

A new row would have been a new index in a list whose indices `payload`, the hit-test and the
keyboard highlight all read — i.e. a fifth seam to buy a count. The label row already exists, is
already un-pickable, and is already sized by `dropdown_w`.
