# Plan — the column filter's five reported defects

Design: [2026-08-02-filter-dropdown-fixes-design.md](../specs/2026-08-02-filter-dropdown-fixes-design.md).
Branch: `filter-fixes`. Target version: **v0.51.0** (behaviour change + a removed constant).

**Execution model: inline, not subagent-per-task.** Six localised fixes across three files, five of
them under twenty lines. A fan-out would re-derive the same investigation six times and cost more
than the work; per Wyatt's standing "scale process to risk". The parts that keep their full rigour
are §3 sabotage discipline (every fix gets a test watched to fail) and the whole-branch review,
because T3 touches `table_filter_apply`, which feeds `view`/`vrank` and therefore the cell-editor
data-loss seam.

---

## T1 — the wheel scrolls the dropdown the wrong way

**File:** `src/program/menu.odin`, `menu_wheel`.

```odin
app.menu.top = clamp(app.menu.top - delta, 0, last)   // before
app.menu.top = clamp(app.menu.top + delta, 0, last)   // after
```

Comment gains the reason: `scroll_delta` is `+down / -up` and every other consumer adds it.

**Test:** new case in `tablesorttest` — open a filter dropdown taller than its cap, assert a
positive delta *increases* `top` and a negative one decreases it, and that it clamps at both ends.

**Sabotage:** restore the `-`. The direction assertions must fail. A test that only checked "top
changed" would pass with the bug present, so it must check the sign.

---

## T2 — a click on dead space inside the dropdown closes it

**File:** `src/program/menu.odin`.

New consumer of the existing geometry producer, beside `menu_item_at`:

```odin
menu_dropdown_hit :: proc(t: ^plat.Text, app: ^App, mx, my, width, height: f32) -> bool {
	if !menu_dropdown_active(app) {return false}
	x0, oy, w, h := menu_dropdown_rect(t, app, width, height)
	y0 := oy + sx(1)                       // the same y0 menu_item_at derives
	return mx >= x0 && mx < x0 + w && my >= y0 && my < y0 + h
}
```

`menu_hit_test`'s dropdown branch becomes a three-way decision instead of a two-way one:

```odin
picked := Command_Id.None
inside := menu_dropdown_hit(t, app, mx, my, w, h)
if idx := menu_item_at(t, app, mx, my, w, h); idx >= 0 { ... picked = it.cmd ... }

close := true
if command_keeps_menu_open(picked) {close = false}   // a checkbox row: ticking must not dismiss
else if inside && picked == .None {close = false}    // dead space INSIDE: swallow, stay open
if close {menu_close(app)}
```

A disabled row also lands in the second branch and keeps the menu open, which is what native menus
do.

**Test:** `tablesorttest` — drive `menu_hit_test` at the separator's own y (row index 2, derived
from `item_h`, not a literal), assert `.None` + consumed + **still open**; then at a point outside
the rect, assert still-consumed but **closed**; then at a real value row, assert the toggle command
and that it stays open.

**Sabotage:** drop the `inside` term. The separator case must close and fail.

---

## T3 — remove the value cap (fixes D2/D3)

**File:** `src/program/table.odin`.

1. `Table_Filter` gains `index: map[string]int` — value → its slot in `values`/`on`. Keys **borrow**
   the clones in `values`; the map owns nothing.
2. `table_filter_open`: the linear `seen` loop becomes a map probe. **The map key must be the
   clone**, never the trimmed `t` — `t` points into the reused stack buffer `key` and is overwritten
   by the next row.

   ```odin
   t := strings.trim_space(csv_field_into(string(buf[:n]), delim, col, key[:]))
   if _, seen := f.index[t]; !seen {
       v := strings.clone(t)
       f.index[v] = len(f.values)
       append(&f.values, v)
       append(&f.on, true)
   }
   ```
3. Delete `TABLE_FILTER_VALUES_MAX` and the `len(f.values) < ...` guard.
4. `table_filter_apply`'s `keep()` becomes a map probe. Its fail-open branch **stays**, with its
   comment rewritten: it is now a "the bytes changed under us" guard, not a cap escape hatch.
5. `table_filter_clear`: `clear(&f.index)` before the string deletes.
6. New `table_filter_free` (values' clones, values, on, view, vrank, index), called from `doc_close`
   beside `table_sort_free` — **D6**, the leak the cap was hiding.

**Test:** the regression that cannot pass with the bug present — a fixture with **more than 512
distinct values in one column**, every value unticked, asserting `table_sort_rows == 0`. With the
cap present this returns the count of rows carrying an unlisted value, which is non-zero by
construction. Plus: the map and `values` agree in length, and every `index[v]` round-trips.

**Sabotage:** reinstate `if !seen && len(f.values) < 512`. The unticked-everything case must report
a non-zero row count.

---

## T4 — the value list ascends (D5)

**File:** `src/program/table.odin`, new file-private `filter_sort_values`, called once at the end of
`table_filter_open` **before `f.active` is set**.

- Numeric iff every non-empty value satisfies `table_is_number` — the sort's own predicate, so the
  two features cannot disagree about which column is numeric. Numeric compare via the existing
  file-private `sort_number`, falling through to the text compare on a numeric tie (`1.0` vs `1.00`)
  so the order stays total.
- Text: case-insensitive, with a case-sensitive tiebreak. Without the tiebreak `"ABC"` and `"abc"`
  are mutually not-less and their relative order is whatever the partitioning does — a list that
  reshuffles between opens.
- `""` last unconditionally. Deliberately **not** the sort's empty-follows-the-arrow rule: that
  exists because a sort has a direction and this list has none.
- After sorting, `index` is rebuilt and `on` is *re-established* as all-true rather than permuted —
  establishing the invariant instead of depending on it.

**Why reordering is safe here and nowhere else:** `Menu_Item.payload` indexes `values`/`on`, so a
reorder after a tick exists re-points every checkbox. This runs before `active`, hence before any
tick; and `Table_Filter_Open` deliberately does not rescan on reopen, so no live selection reaches
it. Both facts get comments, because either changing silently breaks the other.

**Amend, don't work around:** `Table_Filter.values`' comment currently argues *for* first-seen order,
and `ts_case_filter` asserts it. Both change.

**Test:** text ascending; numeric column ordering `2, 10, 1` → `1, 2, 10` (byte order would give
`1, 10, 2`); blanks last; mixed case adjacent and stable.

**Sabotage:** drop the numeric branch. The `1, 2, 10` case must fail.

---

## T5 — the distinct count in the search box

**Files:** `src/program/menu.odin` (`menu_filter_items`, `query_label`).

Fold into the existing label row rather than adding a row — a new row is a new index that `payload`,
the hit-test and the keyboard highlight all read, i.e. a fifth seam to buy a count.

`Type to search… (536 values)` / `Search: ann_ (12 of 536)`.

The label is written **last**, after the row loop that produces `shown`, into the placeholder
appended at index 0 — one pass, where computing the count up front would need a second fold-search
over every value on every keystroke.

`query_label` grows `[160]u8 → [224]u8`: `"Search: " + 128 query bytes + "_ (99999 of 99999)"` is
154 and `bprintf` truncates silently rather than overflowing, so the old size would have eaten the
count rather than crashing.

---

## T6 — update the existing assertions

`test_modes.odin`, fixture `"k,v\nb,1\na,2\nb,3\nc,4\n"`, column 0 distinct `b,a,c` → now `a,b,c`:

| line | was | becomes |
|---|---|---|
| `ts_case_filter` ~5949 | asserts first-seen `b,a,c` | asserts ascending `a,b,c` |
| ~5957 | `f.on[0] = false` "untick b" | `f.on[1] = false` — index 1 is now `b` |
| `ts_case_filter_ui` ~6022 | `menu_item_label(items[3]) == "b"` | `== "a"` |
| ~6032 | `ctx_payload = 0 // "b"` | `= 1` |
| ~6048 | `ctx_payload = 0` | `= 1`, so `2 hidden` still holds |

Row-count expectations (`2 left`, `2 hidden`, `4 rows`) are unchanged — `b` still appears twice.

---

## Verification

Per development-loop.md §6. Build through PowerShell and confirm `$LASTEXITCODE` **and** that
`build\newtpad.exe`'s `LastWriteTime` moved before believing any result — `cmd /c build.bat` can
report 0 on a failed compile and leave the stale exe printing `0 failures`.

`NEWTPAD_SESSION_DIR` to a temp dir first. Sweep: `tablesorttest`, `tablegridtest`, `menutest`,
`settingstest`, `keytest`, `selalltest`, `lineidxtest`, `resavetest`, `watchtest`, `mdjointest`,
plus `odin test src\base`. `menuseam` by **diffing its printed line**, never by exit code — it is a
falsifier and exits 0 whatever it finds.

Then: bisectability check over every commit, HANDOFF `§6br`, version bump in the same commit, merge,
`install.ps1` (only if `newtpad` is not running — never `-Force`), `release.ps1` **bare**.
