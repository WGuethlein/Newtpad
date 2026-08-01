# Batch 19 — multi-column sort in the table view

**Date:** 2026-07-31
**Branch:** `feat/batch-19-multi-sort`
**Requested by Wyatt, 2026-07-31:** *"multiple sort of columns, first column selected to sort takes
precedence. would also be nice to filter columns, and have a dropdown list of all items in the column to
filter like powerbi/excel has."*

**This batch is the sort half only.** Column filtering is batch 20, by Wyatt's decision — the sort is a
key vector over machinery that already exists, while filtering changes the visible row *set*, which every
consumer of the grid reads. They are separate specs, separate plans and separate whole-branch reviews.

---

## 1. The decisions taken with Wyatt before this was written

Recorded first because each one closed off work that would otherwise look reasonable later.

| Decision | Answer | What it rules out |
|---|---|---|
| How a second sort column is added | Plain click unchanged; a **header menu** adds the rest; **Ctrl+click** is the accelerator | Replacing the one-click sort with a two-click menu |
| Precedence | **First column selected wins** (PowerBI / Windows Explorer) | Excel's last-applied-becomes-primary. Opposite of Excel *on purpose* — see §7 |
| Distinct-value dropdown past `TABLE_SORT_MAX` | Refuse, as the sort already does | (Batch 20's decision, recorded here so it is not re-litigated) |
| Column filter vs. `Ctrl+L` | Exclusive — opening one clears the other | (Batch 20) |
| Scope | Two batches: sort now, filter next | One large batch carrying two invariant changes into one review |

Wyatt reviewed and approved the design below on 2026-07-31 before it was written to disk.

---

## 2. What already exists, and what this must not break

The sort shipped in v0.34.0 (HANDOFF §6ax). Its machinery is **correct and stays exactly as it is** —
this is the single most important sentence in the spec, because the temptation in a "multi-key sort" task
is to rewrite the sort.

- **`offs` / `perm` / `rank` keep their meanings.** `offs[j]` is data row *j*'s line offset in file order;
  `perm[pos]` is sorted position → file-order row; `rank[j]` is its inverse. A second sort key changes
  *how `perm` is computed* and nothing about what it means.
- **`doc.top` stays a real byte offset in every mode.** That invariant is what lets the edit anchor, a
  session write, a find jump and leaving the view work with no knowledge that a sort exists. Untouched.
- **The lifetime hooks are untouched.** `pt_edit_replace → table_sort_shift` and
  `doc_index_start` / `apply_snapshot → table_sort_clear` are the reason the sort cannot outlive the bytes
  it describes. Neither reads the sort column, so neither changes. `table_sort_shift`'s one guard
  (`s.col == TABLE_SORT_NONE`) becomes `s.nkeys == 0` and is otherwise identical.
- **`TABLE_SORT_MAX` (100,000 rows) and the refusal stay.** The number is a freeze budget derived from a
  measurement, not a round figure. See §4 for what multi-key does to it.
- **Empty-last, and the file-position final tie-break, stay.** Both become per-key; the reasoning in
  `sort_less_*`'s comments applies unchanged to key 2 and key 3.

The complete set of places that read the sort's *column or direction* today is small, and every one is in
scope for this batch:

| Site | Today | Becomes |
|---|---|---|
| `table_summary_parts` (`table.odin:382`) | `sorted by X asc` | a key list — §7 |
| `table_sort_clear` (`:895`) | resets `col`, `desc` | resets `nkeys`, the key array |
| `table_sort_build` (`:1007-1009`, `:1099-1114`) | one key, four comparators | a key vector, one comparator — §4 |
| `table_sort_click` (`:1141-1154`) | asc → desc → clear | unchanged for plain click; §5 adds the rest |
| `table_sort_shift` (`:1213`) | `col == TABLE_SORT_NONE` guard | `nkeys == 0` |
| header arrow draw (`:2647`) | `up = !desc` | per-key arrow + precedence digit — §6 |
| `test_modes.odin` (several) | `d.table_sort.desc` etc. | updated with the tests |

`table_sorted()` — the predicate the whole file branches on — changes from `col != TABLE_SORT_NONE` to
`nkeys > 0`. **Its `doc.table` term stays.** The comment at `table.odin:827` explains why (a permutation
left behind by a view that has been switched off must not steer the text view's scroll), and that argument
is unaffected by the key count.

---

## 3. Data model

```odin
TABLE_SORT_KEYS_MAX :: 3

Sort_Key :: struct {
    col:     int,
    desc:    bool,
    numeric: bool, // decided over every row the sort orders — see §4
}

Table_Sort :: struct {
    keys:    [TABLE_SORT_KEYS_MAX]Sort_Key,
    nkeys:   int, // 0 == unsorted; keys[0] is the primary
    offs:    [dynamic]int,
    perm:    [dynamic]i32,
    rank:    [dynamic]i32,
    refused: bool,
}
```

**Precedence is array order, and the array is append-order.** "First column selected wins" is therefore
not a rule anything has to enforce — it is what the data structure already is. That is the point of
storing keys in a fixed array rather than, say, a priority field per column.

**Why the cap is 3.** Three is what Excel's classic sort dialog offered, it keeps §7's summary row a
sentence a person reads rather than a list they scan, and the build pays per key. **It is reversible**,
and its comment must say so in the same terms `TABLE_SORT_MAX`'s does: raising it needs a fresh
measurement (§4) *and* a decision about the summary row's wording, and whoever raises it should record
both. A cap that is silently raised is how the summary row starts overflowing its band.

**`numeric` moves onto the key.** Today it is a local in `table_sort_build`. With three keys, one column
may sort numerically while another sorts as text in the same order, so the flag belongs to the key. It is
stored rather than recomputed because the comparator runs O(n log n) times and the detection is O(n).

---

## 4. The build — one pass, k keys

`table_sort_build(doc, keys)` replaces `table_sort_build(doc, col)`.

**The row scan does not multiply.** Each line is read into `buf` exactly once, as today, and all *k*
fields are extracted from that one read. The extra cost is *k* `csv_field_into` calls per row against a
line already in memory, not *k* passes over the piece tree.

**Key storage.** `Sort_Item` grows from one `{ks, kl, num, empty}` to a fixed array of *k* of them. The
arena discipline is unchanged and is the part most likely to be got wrong by someone who has not read the
existing comment: **`ks`/`kl` are offsets into the arena, and every `key` string is materialised in one
pass only after the arena has stopped growing.** A `[dynamic]u8` reallocates; a string captured before a
growth points into freed memory, the comparator reads plausible garbage, and the result is a plausible
wrong order. With three keys there are three times as many chances to make that mistake.

**Type detection is per key, over every row the sort orders.** The existing comment's argument is
load-bearing and applies identically to keys 2 and 3: `doc.table_align` decides alignment from the first
500 rows, which is the right scope for a cosmetic right-align and the wrong scope for an ordering.
Sorting a column numerically because its first 500 cells were numbers, when row 900 holds `N/A`, puts that
row wherever `0.0` falls and presents it as sorted. So `num_all` / `nonempty` become per-key accumulators
gathered in the same pass, and each key's `numeric` is settled before the comparator runs.

**One comparator, via `slice.sort_by_with_data`.** `core/slice/sort.odin:151` provides
`sort_by_with_data(data, less: proc(i, j: E, user_data: rawptr) -> bool, user_data)`. The key metadata
(the `[3]Sort_Key` and `nkeys`) rides in `user_data`. **This is why there is no file-scope global**, which
was the obvious shape and the wrong one: a global read by a comparator is invisible state that outlives
the call that set it, and this file already carries one hard-won lesson (`Sort_Item.key`) about state that
is only valid inside one procedure.

The comparator walks keys in order:

```
for each key k in 0 ..< nkeys:
    if a.empty[k] != b.empty[k]: return b.empty[k]   // empty last, both directions
    if key k is numeric:  if a.num[k] != b.num[k]: return desc ? a.num[k] > b.num[k] : a.num[k] < b.num[k]
    else:                 if a.key[k] != b.key[k]: return desc ? a.key[k] > b.key[k] : a.key[k] < b.key[k]
return a.row < b.row   // total order, independent of the sort's stability
```

**Empty-last is per key and is not affected by direction**, exactly as today. The reason is worth
restating because it looks like an inconsistency at each key: "no value" is not the smallest value, so a
blank must not migrate from one end to the other when the arrow flips, and in a numeric column an unparsed
empty read as `0.0` is a wrong number rather than a missing one.

**The final tie-break stays `a.row < b.row`** — the row's file position — so the order is total and does
not depend on `slice.sort_by`'s stability, which this file cannot see.

### The freeze budget is the gate on the key cap

`TABLE_SORT_MAX = 100_000` is a measurement: 205 ms at one key at `-o:speed`, extrapolated from a measured
2,046 ms at 1,000,000 rows, chosen because "a two-second stall on a header click is not a slow feature, it
is a hung window."

**The plan must measure k=3 at 100,000 rows and record the number.** Multi-key adds two extra
`csv_field_into` calls per row plus a comparator that may look at three keys instead of one — real cost on
top of a budget that is already the slowest thing in the app.

- If it lands near the single-key figure, the cap stays at 3 and the number goes in the comment.
- If it does not, **`TABLE_SORT_KEYS_MAX` comes down; `TABLE_SORT_MAX` does not go up and the freeze is
  not accepted.** Product principle 1 is "speed everywhere — clicking, tabs, find, open: instant", and
  nothing about a header click exempts it.

This ordering is deliberate. The tempting response to a slow measurement is to keep three keys and accept
a longer stall, because the feature was the thing that was asked for. The cap is the variable.

---

## 5. Interaction

### The three gestures

- **Plain click on a header — unchanged.** Sort by this column *alone*: ascending → descending → the
  file's own order. It stays one click because it is the most common action in the view, and it stays a
  three-state cycle because that behaviour shipped and works. Clicking any header replaces the whole key
  vector, which is what Windows Explorer does.
- **Ctrl+click — asc → desc → removed from the key vector.** The same three-state shape as the plain
  click, applied to one key instead of the whole sort. If the column is not yet a key it is **appended**
  ascending (so precedence follows the order columns were clicked); if it is already a key its direction
  flips; a third Ctrl+click removes just that key. Removing the last key leaves the document unsorted.
  At `TABLE_SORT_KEYS_MAX` an append is refused — see the disabled state below.
- **The header menu**, §5's real work, opened by a hover chevron *or* a right-click anywhere in the
  header cell.

### The menu

| Row | Effect | Disabled when |
|---|---|---|
| Sort ascending | replaces the vector with this column, ascending | never |
| Sort descending | replaces the vector with this column, descending | never |
| *(separator)* | | |
| Then by ascending | appends this column ascending, or sets its direction if already a key | unsorted, or the vector is full and this column is not in it |
| Then by descending | as above, descending | as above |
| Remove from sort | drops just this column's key | this column is not a key |
| *(separator)* | | |
| Clear sort | drops the whole vector | unsorted |

**"Then by" is Excel's own wording** and describes the operation exactly. On a column already in the
vector it sets that key's direction **in place, without changing its precedence** — the alternative
(remove and re-append) would silently demote a primary key to last, which is the kind of quiet reordering
a user cannot see happen.

**Disabled rows are greyed, not hidden.** `Menu_Item.enabled` already exists for exactly this, and the
comment on it states the reason: a menu that offers commands which silently no-op is lying about what it
does. `item_disabled_reason` carries the explanation where one helps — notably the full-vector case, which
otherwise looks like a broken row.

**Eight rows is the ceiling.** Principle 3 says fight options; these are commands rather than options, but
the count is still the thing to watch. The trim, if one is wanted later, is **Remove from sort** — Ctrl+click
already does it. It is in because discoverability was the entire reason for building the menu.

**Batch 20's Filter row lands after a final separator**, and no space is reserved for it now.

### What this fixes as a side effect

`reported-bugs.md` carried *"there is no discoverable way to reset the sort"*. v0.34.0's answer was to say
it in words in the summary row (`sorted by Date desc · click to clear`), which Wyatt accepted after
rejecting three proposals that added another unlabelled target — *"how will the person know what to click
and where to reset."* **The menu is the real answer**, and the summary row's clickable run stays as well:
they are two labelled routes to one command, not two mechanisms.

---

## 6. Geometry — one `table_header_layout()`

**This is the section most likely to produce a bug, and it has a name.** The header cell goes from one hit
region to two. Development-loop §4's Shape B — *a correct, tested function fed the wrong input, or its
result read in the wrong space* — accounts for sixteen bugs in one session, and CLAUDE.md's countermeasure
is one layout per widget.

`table_header_layout(doc, char_w, width, px)` produces, per column: the **body rect**, the **chevron
rect**, and whether the chevron is **suppressed**. Every consumer reads it — the draw, the hit-test, the
hover, and the cursor. No procedure may both compute one of these coordinates and consume it, and nothing
may re-derive "where is the chevron" from a column's `x + w`.

- The chevron is **right-aligned inside the header cell**, sized in DPI-scaled units like every other
  metric in the file (§10's metrics: header 30px, cell padding 0 10).
- It is drawn **only on the hovered column**. §10 deleted the per-column rules because they made "the grid
  louder than the data"; a chevron drawn permanently on every column is that same chrome returning.
- It is **suppressed when the column is too narrow to hold it** without colliding with the label.
  Right-click still opens the menu in that case, so the command is never unreachable.
- The **resize edge already exists** (`table_edge_at`, drag to resize / double-click to fit) and sits at
  the same right edge as the chevron. **The precedence between them must be decided in the layout and
  asserted in a test**, not discovered by a user who tries to resize a column and gets a menu. The edge
  wins: it is the narrower target and the older gesture.

**The seam test compares what is drawn against what is clickable**, at boundary sizes — a column narrower
than the chevron, a column exactly the chevron's width, the last column against the grid's right edge
(`table_content_right`), and the hovered-vs-unhovered pair. It is sabotage-verified by shifting one rect
by a pixel and watching it fail.

### Header arrows

Each sorted column draws its arrow. **A precedence digit is drawn only when `nkeys > 1`** — a lone "1"
beside a single sort is noise, and the arrow alone already says everything a one-key sort has to say.

---

## 7. The summary row

`sorted by Date asc, Name desc · click to clear`

The clickable run still starts at `sorted by` and ends at `click to clear`, and `clear_s`/`clear_e` are
still produced **beside the `sbprintf` that writes the words** — the existing comment's reason holds and
is worth restating: a second procedure computing "where does the sort clause start" from the finished
string would re-derive what this one already knows and would name the wrong bytes the first time the
wording changed.

At the 3-key cap the longest realistic line is roughly
`120,000 rows · 8 columns · sorted by Department asc, Last Name asc, Hire Date desc · click to clear`.
**The plan must check that against the band at a small window width** and decide the behaviour if it does
not fit, rather than leaving it to be discovered. That check is also the argument that keeps the key cap
at 3.

The refusal wording (`too large to sort (over 100,000 rows)`) is unchanged.

---

## 8. Commands

Six new `Command_Id`s — one per menu row, so the menu stays what `menu.odin`'s header comment says it is:
`Table_Sort_Asc`, `Table_Sort_Desc`, `Table_Sort_Then_Asc`, `Table_Sort_Then_Desc`, `Table_Sort_Remove`,
`Table_Sort_Clear`. *"a discoverability surface, not a second command system: every item names a
Command_Id and dispatches through command_dispatch."*

**They act on a target column carried in the menu's own state**, set when the menu opens. There is no
persistent "current column" in the table view — only `table_edit_col`, and only while a cell is being
edited — so there is no meaningful target when these are invoked from anywhere else.

**They are therefore excluded from the palette** via `command_in_palette`'s existing list, alongside the
menu navigation verbs. This is a real cost and is accepted knowingly: it means multi-sort is not reachable
from `Ctrl+P`. The alternative — palette entries that act on "the column under the caret" — would require
inventing a current-column concept that the view does not have, for one entry point.

`command_table` is total over the enum (`#assert`-ed), so the new rows cannot be forgotten.

---

## 9. The menu surface — generalise `Menu_State`, do not write a second one

`Menu_State` today is anchored to the menu bar: `open` indexes `menus`, and the dropdown's x comes from
`menu_title_rect`. A header menu is the same dropdown at an arbitrary anchor.

**Add an anchor and an item source to `Menu_State`; keep the bar as one caller.** The bar's behaviour must
not change.

The alternative — a private popup inside `table.odin` — duplicates the dropdown draw, the hit-test, the
keyboard navigation, the scroll-when-it-does-not-fit and the item-height rules. `menuseam` exists as a
**falsifier** proving that resolving scroll twice in one frame diverges *in every case where the dropdown
does not fit*, and a second implementation is a second chance to make that mistake. It also doubles the
work of the `renderer`/`ui` extraction, which recent batches have already made measurably harder in ~10
named places.

**Risk this carries, to be named in the task brief:** this touches a shipped surface that every menu in
the app goes through. The per-task reviewer must be told so explicitly, and `menutest` / `menuseam` must
both pass unchanged.

---

## 10. Tests

**A new headless mode, `tablesorttest`.** One argument (`newtpad tablesorttest`, no path), exits non-zero
on failure, counts a missing `NEWTPAD_SESSION_DIR` as a failure rather than skipping. **It goes in
HANDOFF §7's list *and* development-loop §6** — the rule `selalltest` was the first to be built under,
because *"a mode nothing runs is worse than no mode."*

What it must cover:

1. **The key vector** — build with 1, 2 and 3 keys; `perm`/`rank` are exact inverses; `offs` is ascending.
2. **Precedence is first-selected-wins** — a fixture where key 1 alone and key 2 alone give *different*
   orders, so a comparator that reads them in the wrong order cannot pass.
3. **Per-key numeric detection past the sample window** — a column whose first 500 rows are numeric and
   whose row 900 is `N/A` must sort as **text**, on the secondary key as well as the primary.
4. **Empty-last per key, in both directions** — including a blank in key 2 with key 1 tied.
5. **Total order** — equal on all three keys falls back to file position, ascending, in both directions.
6. **Both cycles** — plain click asc → desc → clear; Ctrl+click asc → desc → removed, including append
   order, direction flip in place, and removing the last key.
7. **The menu's disabled states** — every row of §5's table, including the full-vector refusal.
8. **The refusal at `TABLE_SORT_MAX` with k keys** — and that `refused` is recorded for the summary row.
9. **The header seam** — drawn chevron rect vs. clickable chevron rect, at the boundary widths in §6,
   plus the chevron-vs-resize-edge precedence.
10. **The summary row** — the key list wording, and `clear_s`/`clear_e` naming exactly the run drawn.

**The measurement** (§4) is recorded in the HANDOFF entry. Following `selalltest`'s precedent, prefer a
*comparison* to a fixed threshold where possible — a fixed millisecond number in an assertion drifts with
the machine.

### Sabotage

Per development-loop §3, every one of these gets the bug reintroduced, the failure output recorded, then
the fix restored:

- comparator ignores keys past the first
- comparator reads keys in reverse precedence
- `numeric` decided from the sample rather than from every sorted row
- empty-last dropped on secondary keys only
- the chevron rect shifted one pixel from the drawn one
- `table_sorted()` left reading `col` instead of `nkeys`

**Check the build's exit code before believing a green run.** A sabotage that fails to compile is
indistinguishable from one that breaks nothing — the stale exe runs and prints `0 failures`. That cost
real time on 2026-07-31 and is now in three places, including this one.

Eleven consecutive batches have shipped draft test code that *could not fail*. Three modes printed `FAIL`
and exited **0** on 2026-07-31 alone. Assume this batch's first draft has the same defect until sabotage
proves otherwise.

---

## 11. Out of scope — named so it is not discovered mid-batch

- **Column filtering and the distinct-value dropdown** — batch 20. The header menu is built so its Filter
  row is an addition rather than a redesign, and that is the only accommodation made for it.
- **A background sort index** — the standing right answer to `TABLE_SORT_MAX`, queued since batch 18. It
  would remove the freeze trade rather than repricing it, and it is its own batch.
- **Session persistence of the sort** — the sort does not survive a reload today (`doc_index_start` clears
  it) and this batch does not change that.
- **Sorting in any view but the table.**

---

## 12. Owed, expected to be carried out of this batch

- **No live GUI pass.** This environment cannot inject GUI keyboard or mouse input, so the chevron's hover
  behaviour, the right-click, Ctrl+click and the menu's placement against a window edge are all
  inferences from source until Wyatt uses them. A live pass is worth one.
- The 3-key cap is judgement plus a measurement, not evidence about what users want.
