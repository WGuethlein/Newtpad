# Batch 19 — multi-column sort: implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement
> this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The table view sorts by up to two columns, first-selected-wins, through a discoverable header
menu — without changing the sort's data-safety machinery.

**Amended 2026-07-31, after Task 2's measurement:** the cap was 3 when this plan was written. Three keys
at the 100,000-row ceiling measured ~460 ms release against one key's ~258 ms, and Wyatt chose **two**.
The spec's §3 and §4 carry the numbers and the honest caveat that the cap is a weak lever. Tasks below
still read `TABLE_SORT_KEYS_MAX` symbolically, so only the constant, the test cases and the prose moved.

**Architecture:** `Table_Sort.col`/`desc` become a fixed key vector (`keys[3]`, `nkeys`). `offs`/`perm`/
`rank`, `doc.top`'s byte-offset invariant and both lifetime hooks are untouched — only *how `perm` is
computed* changes. The header gains a second hit region (a chevron) produced by one `table_header_layout()`
and consumed by draw, hit-test, hover and cursor. The existing menu-bar dropdown is generalised to take an
anchor and an item slice; no second dropdown is written.

**Tech stack:** Odin `dev-2026-07a`, `core:slice` (`sort_by_with_data`), D3D11 via `src/platform`.
Build: `build.bat`. Tests: `odin test src\base` + headless modes in `src/program/test_modes.odin`.

**Spec:** [docs/superpowers/specs/2026-07-31-batch-19-multi-sort-design.md](../specs/2026-07-31-batch-19-multi-sort-design.md).
Read it before Task 1. Every task below implements part of it; where this plan and the spec disagree, the
spec wins and the plan is what gets fixed.

## Global constraints

- **Odin, `package main` under `src/program`.** One package per directory; no new directories.
- **`TABLE_SORT_KEYS_MAX = 2`** (measured down from 3 — see the amendment above). `TABLE_SORT_MAX =
  100_000` does **not** change.
- **Never change the meaning of `offs` / `perm` / `rank`, or `doc.top`'s byte-offset invariant.**
- **Never remove or weaken** `pt_edit_replace → table_sort_shift`, or `doc_index_start` /
  `apply_snapshot → table_sort_clear`.
- **Comments carry arguments, not descriptions.** This file's existing comments state *why* a rule exists
  and what it rules out. Match that register; do not write `// sort the items`.
- **Commits are authored solely by Wyatt Guethlein.** No `Co-Authored-By`, no "Generated with", no AI
  attribution anywhere in a commit message, tag or PR body. This applies to every subagent.
- **Every commit must build.** `odin check src/program -collection:src=src` exits 0 at every commit.
- **Sabotage every test before believing it** (development-loop §3), and **check the build's exit code
  before believing a green run** — a sabotage that fails to compile leaves the stale exe printing
  `0 failures`.
- `Select-String "FAIL"` is case-insensitive and matches `0 failures`. Use `-CaseSensitive`.
- Set `NEWTPAD_SESSION_DIR` before running any headless mode.

**Standard commands** (PowerShell, from the repo root):

```
build.bat
```

```
odin test src\base -collection:src=src
```

```
$env:NEWTPAD_SESSION_DIR = "$env:TEMP\np-b19"; build\newtpad.exe tablesorttest
```

---

## File structure

| File | Change |
|---|---|
| `src/program/table.odin` | `Table_Sort` key vector, the build, the comparator, the key operations, `table_header_layout`, the arrows, the summary row |
| `src/program/menu.odin` | `Menu_State` gains an anchor + item source; the bar becomes one caller |
| `src/program/commands.odin` | six new `Command_Id`s + `command_table` rows + dispatch |
| `src/program/palette.odin` | the six commands excluded from the palette |
| `src/program/main.odin` | Ctrl+click and right-click routed into the header |
| `src/program/test_modes.odin` | new `tablesorttest`; existing sort assertions migrated |
| `HANDOFF.md`, `docs/development-loop.md` | `tablesorttest` added to both required lists |

No new files. `table.odin` is 3,180 lines and grows by roughly 300; splitting it is **not** in scope —
propose it in the HANDOFF entry if it becomes unwieldy, do not do it here.

---

### Task 1: The key vector, with single-key behaviour unchanged

A pure refactor. **No behaviour changes in this task at all** — `nkeys` is only ever 0 or 1 when it ends,
and every existing test must pass untouched. That is what makes it independently reviewable: a reviewer
can reject Task 2's ordering logic while approving this.

**Files:**
- Modify: `src/program/table.odin` — `Table_Sort` (`:813`), `table_sorted` (`:838`), `table_sort_clear`
  (`:892`), `table_sort_build` (`:1005`), `table_sort_click` (`:1138`), `table_sort_shift` (`:1213`),
  `table_summary_parts` (`:382`), header arrow draw (`:2621`, `:2647`)
- Modify: `src/program/test_modes.odin` — the sites listed by
  `grep -n "table_sort\.\(col\|desc\)" src/program/test_modes.odin`

**Interfaces produced:**

```odin
TABLE_SORT_KEYS_MAX :: 2

Sort_Key :: struct {
    col:     int,
    desc:    bool,
    numeric: bool,
}

Table_Sort :: struct {
    keys:    [TABLE_SORT_KEYS_MAX]Sort_Key,
    nkeys:   int,
    offs:    [dynamic]int,
    perm:    [dynamic]i32,
    rank:    [dynamic]i32,
    refused: bool,
}

table_sorted    :: proc(doc: ^Document) -> bool          // doc != nil && doc.table && nkeys > 0 && len(perm) > 0
table_sort_key  :: proc(doc: ^Document, col: int) -> (k: int, ok: bool)  // index into keys, or ok = false
```

- [ ] **Step 1: Read the ground truth before touching anything**

Read `table.odin:700–930` in full — the `Table_Sort` block comment. It is the argument for every
invariant this task must not break, and it is the only place the lifetime model is written down.

- [ ] **Step 2: Replace the struct and add the lookup**

Replace `col`/`desc` with the `keys`/`nkeys` shape above. `TABLE_SORT_NONE` stays (it is still what an
*unset* `Sort_Key.col` is, and the `#assert` beside `TABLE_SORT_MAX` stays).

Keep the existing block comment and **extend it**: state that precedence is array order, and that array
order is append order, so "first column selected wins" is a property of the data structure rather than a
rule anything enforces.

```odin
// The sorted column's key index, for the callers that ask "is this column part of
// the sort, and where". Linear over at most TABLE_SORT_KEYS_MAX -- a binary search
// over three entries would be slower and would imply the array is ordered by
// column, which it is not: it is ordered by PRECEDENCE, which is the whole point.
table_sort_key :: proc(doc: ^Document, col: int) -> (k: int, ok: bool) {
    if doc == nil {return 0, false}
    s := &doc.table_sort
    for i in 0 ..< s.nkeys {
        if s.keys[i].col == col {return i, true}
    }
    return 0, false
}
```

- [ ] **Step 3: Migrate the seven call sites, one at a time**

Each keeps its behaviour exactly:

| Site | Was | Becomes |
|---|---|---|
| `table_sorted:839` | `s.col != TABLE_SORT_NONE` | `s.nkeys > 0` (**keep the `doc.table` term** — `:827` says why) |
| `table_sort_clear:895` | `s.col, s.desc, s.refused = ...` | `s.nkeys, s.refused = 0, false`; zero `s.keys` |
| `table_sort_build:1007-9` | saves/restores `s.desc` | takes the direction from the key it is handed |
| `table_sort_build:1099-1114` | four comparators on `s.desc` | unchanged this task — read `keys[0].desc` |
| `table_sort_build:1114` | `s.col = col` | `s.keys[0] = {col, desc, numeric}; s.nkeys = 1` |
| `table_sort_click:1149-54` | `s.col == col`, `s.desc` | `table_sort_key` + `keys[0].desc` |
| `table_sort_shift:1213` | `s.col == TABLE_SORT_NONE` | `s.nkeys == 0` |
| `table_summary_parts:382` | `.col`, `.desc` | `keys[0].col`, `keys[0].desc` — wording unchanged this task |
| header arrow `:2621`,`:2647` | `doc.table_sort.col`, `.desc` | `keys[0].col`, `keys[0].desc` — one arrow still |

- [ ] **Step 4: Build, and confirm the existing suite is untouched**

```
build.bat
```

Expected: exit code 0. The `'vswhere.exe' is not recognized` line is **not** a failure.

```
$env:NEWTPAD_SESSION_DIR = "$env:TEMP\np-b19"; build\newtpad.exe tablegridtest; echo "exit=$LASTEXITCODE"
```

Expected: `exit=0` and no `FAIL` line. Also run `odin test src\base -collection:src=src` (211 cases,
0 failures) and `build\newtpad.exe csvtest`, `tablecellstest`, `tablereadonlytest`.

- [ ] **Step 5: Sabotage — prove the migration is observed**

Change `table_sorted` to `s.nkeys >= 0`. Rebuild (**check the exit code**), run `tablegridtest`. Record
the exact failure output in the task report. Restore.

- [ ] **Step 6: Commit**

```bash
git add src/program/table.odin src/program/test_modes.odin && git commit -m "Give the table sort a key vector, still one key deep"
```

---

### Task 2: The multi-key build and one comparator

**Files:**
- Modify: `src/program/table.odin` — `Sort_Item` (`:916`), `sort_less_*` (`:939-961`), `table_sort_build`
  (`:1005-1116`)
- Modify: `src/program/test_modes.odin` — new `tablesorttest` mode

**Interfaces consumed:** `Sort_Key`, `Table_Sort`, `table_sort_key` (Task 1).

**Interfaces produced:**

```odin
table_sort_build :: proc(doc: ^Document, keys: []Sort_Key) -> bool
// keys is 1..TABLE_SORT_KEYS_MAX entries, in precedence order. Each entry's
// `numeric` is IGNORED on the way in and SETTLED here, over every row the sort
// orders. Returns false and leaves the doc unsorted on refusal.
```

- [ ] **Step 1: Grow `Sort_Item` to k keys**

```odin
// One row's sort keys, during the build only.
//
// ks/kl index the key arena rather than `key` being filled as the arena grows: a
// [dynamic]u8 REALLOCATES, and a string captured before a growth points into freed
// memory. Every key is spanned first and materialised in one pass once the arena
// has stopped moving. That bug is silent -- the comparator reads plausible garbage
// and produces a plausible ORDER -- and with two keys there are twice as many
// chances to make it.
@(private = "file")
Sort_Field :: struct {
    key:    string,
    num:    f64,
    ks, kl: i32,
    empty:  bool,
}

@(private = "file")
Sort_Item :: struct {
    f:   [TABLE_SORT_KEYS_MAX]Sort_Field,
    row: i32,
}
```

- [ ] **Step 2: Replace the four comparators with one**

`core/slice/sort.odin:151` provides `sort_by_with_data(data, less: proc(i, j: E, user_data: rawptr) -> bool, user_data)`.

```odin
// The key metadata rides in user_data rather than a file-scope global. A global
// read by a comparator is invisible state that outlives the call that set it, and
// this file already carries one hard-won lesson (Sort_Item's arena) about state
// that is valid only inside one procedure.
@(private = "file")
Sort_Ctx :: struct {
    keys:  [TABLE_SORT_KEYS_MAX]Sort_Key,
    nkeys: int,
}

// Keys in PRECEDENCE order; the first that separates two rows decides.
//
// EMPTY LAST IS PER KEY AND IGNORES DIRECTION, at every key, for the reason the
// single-key version already gives: "no value" is not the smallest value, so a
// blank must not migrate from one end to the other when the arrow flips, and in a
// numeric column an unparsed empty read as 0.0 is a wrong number rather than a
// missing one.
//
// The final tie-break is the row's FILE position, ascending, in every direction,
// so the order is total and does not depend on slice.sort_by's stability -- which
// this file cannot see.
@(private = "file")
sort_less_keys :: proc(a, b: Sort_Item, user_data: rawptr) -> bool {
    ctx := (^Sort_Ctx)(user_data)
    for i in 0 ..< ctx.nkeys {
        k := ctx.keys[i]
        af, bf := a.f[i], b.f[i]
        if af.empty != bf.empty {return bf.empty}
        if af.empty {continue} // both empty on this key: fall through to the next
        if k.numeric {
            if af.num != bf.num {return af.num > bf.num if k.desc else af.num < bf.num}
        } else {
            if af.key != bf.key {return af.key > bf.key if k.desc else af.key < bf.key}
        }
    }
    return a.row < b.row
}
```

- [ ] **Step 3: Extract k fields from the one line read**

In the row loop, replace the single `csv_field_into` with one per key against the **same** `buf`. Use one
`key` buffer per key (`[TABLE_SORT_KEYS_MAX][RENDER_LINE_CAP]u8` is 48 KB of stack — **too much**; use a
single `[RENDER_LINE_CAP]u8` reused per key, appending each extracted field into the arena immediately
before extracting the next). Accumulate `num_all[i]` / `nonempty[i]` per key.

Keep every existing guard: the `p >= doc.pt.length` terminator rule, the `len(items) >= TABLE_SORT_MAX`
check *inside* the loop, the settled-count early refusal, the `'\r'` trim, and the `base.pt_faulted`
fail-closed check.

- [ ] **Step 4: Settle `numeric` per key, then sort**

After the arena stops growing: materialise every `f[i].key`, set each key's `numeric` from its own
accumulators, parse `num` for numeric keys only, fill a `Sort_Ctx`, then

```odin
slice.sort_by_with_data(items[:], sort_less_keys, &ctx)
```

Write the settled keys into `s.keys` / `s.nkeys` **after** the sort succeeds, exactly where `s.col = col`
was written.

- [ ] **Step 5: Write `tablesorttest` — the failing test first**

New one-argument mode in `test_modes.odin`. **Pull each case into its own local proc** and keep each proc
to one `App`/`Document` at a time — `test_mode_dispatch` has a large frame and `blocktest` has hit a real
`STATUS_STACK_OVERFLOW` twice by holding two `App`s live in one callee.

It must count a missing `NEWTPAD_SESSION_DIR` as a **failure**, print `N failures` and **exit non-zero**.

Cases for this task (spec §10 items 1–5):

1. `perm`/`rank` are exact inverses and `offs` is ascending, at `nkeys` = 1 and 2.
2. **Precedence** — a fixture where sorting by column 0 alone and by column 1 alone give *different*
   orders, asserted against the full expected row order. A comparator that reads keys in the wrong order
   cannot pass this.
3. **Per-key numeric detection past the sample window** — a column whose first 500 rows are numeric and
   whose row 900 is `N/A`, used as the **secondary** key, must sort as text.
4. **Empty-last per key, both directions** — a blank in key 2 with key 1 tied, asserted at
   `desc = false` and `desc = true`, with the blank last in both.
5. **Total order** — three rows equal on every key come back in file order, under every direction
   combination.
6. **The refusal still holds at k keys** — a settled row count over `TABLE_SORT_MAX` refuses a 2-key
   sort before scanning, the in-loop `len(items) >= TABLE_SORT_MAX` check refuses an unsettled one,
   `refused` is recorded, and `table_summary_text` says `too large to sort (over 100,000 rows)`.

- [ ] **Step 6: Run it and watch it fail**

```
build.bat; $env:NEWTPAD_SESSION_DIR = "$env:TEMP\np-b19"; build\newtpad.exe tablesorttest; echo "exit=$LASTEXITCODE"
```

Expected before Steps 1–4 are complete: non-zero exit with named failures. Record the output.

- [ ] **Step 7: Make it pass, then measure**

Time `table_sort_build` at **k=3 over 100,000 rows** in a `release` build. Record the number in the task
report and in `TABLE_SORT_MAX`'s comment beside the existing 205 ms figure.

**RESOLVED 2026-07-31.** Measured: one key **387 ms debug / ~258 ms release**, three keys **696 ms debug
/ ~460 ms release**. `TABLE_SORT_KEYS_MAX` came down to **2** on Wyatt's decision. `TABLE_SORT_MAX` did
not move and the longer freeze was not accepted.

Two things the measurement turned up that belong in the HANDOFF entry:
- The cost is a **constant factor** (3× keys → 1.8× time), so the cap is a weak lever — 2 keys still
  costs ~360 ms. The case for stopping at two is that nobody asked for a third.
- **`TABLE_SORT_MAX`'s own comment is wrong**: it claims 205 ms at 100,000 rows, extrapolated linearly
  from a measured 2,046 ms at 1,000,000. Measured directly it is ~258 ms. Fix the comment, not the
  constant.

Prefer a *comparison* to a fixed threshold in the assertion (as `selalltest` does): a millisecond constant
drifts with the machine.

- [ ] **Step 8: Sabotage, four ways**

Run each, record the exact failure output, restore:

1. comparator `for i in 0 ..< 1` — ignores keys past the first
2. comparator walks keys in reverse precedence
3. `numeric` taken from `doc.table_align` instead of the per-key accumulator
4. `if af.empty != bf.empty {return bf.empty}` removed from all but key 0

**Check `build.bat`'s exit code each time before believing the run.**

- [ ] **Step 9: Commit**

```bash
git add src/program/table.odin src/program/test_modes.odin && git commit -m "Sort the table by up to three keys in one pass"
```

---

### Task 3: The key-vector operations and the Ctrl+click cycle

**Files:**
- Modify: `src/program/table.odin` — `table_sort_click` (`:1138`)
- Modify: `src/program/main.odin:717-740` — the header press
- Modify: `src/program/test_modes.odin` — `tablesorttest` case 6

**Interfaces consumed:** `table_sort_build(doc, keys)`, `table_sort_key` .

**Interfaces produced:** the **only** procedures that mutate the key vector. Nothing else may write
`s.keys` / `s.nkeys` except `table_sort_build` and `table_sort_clear`.

```odin
table_sort_set    :: proc(doc: ^Document, col: int, desc: bool)  // replace the vector with one key
table_sort_cycle  :: proc(doc: ^Document, col: int)              // plain click: asc -> desc -> clear
table_sort_add    :: proc(doc: ^Document, col: int, desc: bool)  // append, or set direction IN PLACE
table_sort_drop   :: proc(doc: ^Document, col: int)              // remove just this column's key
table_sort_toggle :: proc(doc: ^Document, col: int)              // Ctrl+click: asc -> desc -> removed
table_sort_can_add :: proc(doc: ^Document, col: int) -> bool     // for the menu's enabled state
```

- [ ] **Step 1: Commit the open cell edit in every one of them**

`table_sort_click:1122` records why, and it is a data-safety rule, not a nicety: committing while the
anchor is intact means `table_edit_line_intact` passes and the value lands on the row the user typed it
into. **Every entry point above must do it**, not just the plain click — a Ctrl+click that reorders while
a cell edit is open would drop the keystrokes.

- [ ] **Step 2: `table_sort_add` sets direction in place**

On a column already in the vector it changes that key's `desc` and **leaves its precedence alone**.
Remove-and-re-append would silently demote a primary key to last, which the user cannot see happen.

- [ ] **Step 3: `table_sort_toggle` is the three-state cycle, per key**

Not a key → append ascending. Ascending → descending. Descending → removed. Removing the last key leaves
the document unsorted. At `TABLE_SORT_KEYS_MAX`, appending is refused (and `table_sort_can_add` is false).

- [ ] **Step 4: Scroll to the top on every reorder**

`table_sort_click:1131` is the argument — the scroll goes to the top of the new order rather than
following a row, and it also guarantees `doc.top` is an offset the permutation contains. Apply it to every
operation that changes the order, including `drop` and `toggle`.

- [ ] **Step 5: Route Ctrl+click in `main.odin`**

At `main.odin:717`, the header press currently calls `table_sort_click(doc, c)` after
`table_edge_at` has been tested first. **Keep that ordering** — `table_header_col_at:1641` records why
(a sort fired by a slightly-off resize grab reorders the whole file). Ctrl-held routes to
`table_sort_toggle`, plain to `table_sort_cycle`.

- [ ] **Step 6: `tablesorttest` case 6**

Both cycles end to end: plain asc → desc → clear; Ctrl append order across two columns plus a third
whose append is refused at the cap, direction flip
**in place** (assert the precedence index is unchanged), third Ctrl+click removes only that key, removing
the last leaves `table_sorted(doc) == false`, and an append at the cap is refused.

- [ ] **Step 7: Sabotage**

Make `table_sort_add` remove-and-re-append on an existing key; assert the precedence-index check fails.
Record the output. Restore.

- [ ] **Step 8: Commit**

```bash
git add src/program/table.odin src/program/main.odin src/program/test_modes.odin && git commit -m "Cycle one sort key with Ctrl+click"
```

---

### Task 4: Generalise the dropdown to an anchor and an item slice

**No behaviour change to the menu bar.** This task ships with the bar working exactly as before and the
new anchor unused.

**Files:**
- Modify: `src/program/menu.odin` — `Menu_State` (`:263`), `menu_init`, `menu_close`, `menu_is_active`,
  `menu_hover_item` (`:335`), `menu_hit_test` (`:346`), `menu_draw_dropdown` (`:551`),
  `menu_dropdown_rect` (`:624`), `menu_visible_rows` (`:648`), `menu_item_at` (`:699`), `dropdown_w`

**Interfaces produced:**

```odin
// Added to Menu_State:
//   ctx:       bool         — true when this is a context menu, not a bar dropdown
//   ctx_items: []Menu_Item
//   ctx_x:     f32          — anchor, top-left, before clamping to the window
//   ctx_y:     f32
//   ctx_col:   int          — the table column this menu targets (Task 5)

menu_items  :: proc(app: ^App) -> []Menu_Item              // menus[open].items, or ctx_items
menu_origin :: proc(app: ^App) -> (x0, y0: f32)            // the bar's anchor, or ctx_x/ctx_y
menu_open_ctx :: proc(app: ^App, items: []Menu_Item, x, y: f32, col: int)
```

- [ ] **Step 1: Route every `menus[app.menu.open].items` through `menu_items`**

Sites: `menu_hover_item:339`, `menu_hit_test:371`, `menu_dropdown_rect:626`, `menu_visible_rows:651`,
`menu_item_at:705`, `menu_scroll_to_item`'s caller in `menu_draw_dropdown`. `grep -n "menus\[app.menu.open\]"`
must return nothing outside `menu_items` when this step is done.

- [ ] **Step 2: Route every `TAB_STRIP_H + MENU_BAR_H` origin through `menu_origin`**

Sites: `menu_dropdown_rect:629`, `menu_item_at:703`, and the draw. **The clamp stays** —
`menu_dropdown_rect:631` explains that a client-space quad cannot leave the window and items drawn outside
would be invisible but still clickable. A context menu anchored near the right or bottom edge is exactly
the case that clamp was written for, so it must apply to `ctx_x`/`ctx_y` too.

- [ ] **Step 3: `dropdown_w` takes items, not a menu index**

`menutest` asserts every dropdown is wide enough for its own widest row. Keep that seam: the width is
measured from the item slice.

- [ ] **Step 4: `menu_is_active` and `menu_close` cover the context menu**

`menu_close` clears `ctx`, `ctx_items` and `ctx_col`. If `menu_is_active` misses `ctx`, a click elsewhere
will not dismiss the header menu.

- [ ] **Step 5: Prove the bar is unchanged**

```
build.bat; $env:NEWTPAD_SESSION_DIR = "$env:TEMP\np-b19"; build\newtpad.exe menutest; build\newtpad.exe menuseam
```

Expected: both exit 0, no `FAIL`. `menuseam` is a **falsifier**, not a regression test — it measures
whether resolving scroll twice in one frame diverges. It must keep reporting the same answer.

- [ ] **Step 6: Sabotage**

Point `menu_origin` at `0, 0` for the bar. `menutest` must fail. Record the output. Restore.

- [ ] **Step 7: Commit**

```bash
git add src/program/menu.odin && git commit -m "Let the dropdown open at an arbitrary anchor"
```

---

### Task 5: Six commands and the header menu's contents

**Files:**
- Modify: `src/program/commands.odin` — `Command_Id`, `command_table`, `command_dispatch`
- Modify: `src/program/palette.odin` — `command_in_palette:103`
- Modify: `src/program/menu.odin` — the header menu's `[]Menu_Item` and its `enabled` predicates
- Modify: `src/program/test_modes.odin` — `tablesorttest` case 7

**Interfaces consumed:** Task 3's six operations; Task 4's `menu_open_ctx`, `Menu_State.ctx_col`.

**Interfaces produced:** `Command_Id.Table_Sort_Asc`, `.Table_Sort_Desc`, `.Table_Sort_Then_Asc`,
`.Table_Sort_Then_Desc`, `.Table_Sort_Remove`, `.Table_Sort_Clear`; `table_header_menu_items: []Menu_Item`.

- [ ] **Step 1: Add the enum rows and the `command_table` entries**

`command_table` is total over the enum and `#assert`-ed, so a missing row is a compile error. Titles:
`"Sort Ascending"`, `"Sort Descending"`, `"Then by Ascending"`, `"Then by Descending"`,
`"Remove from Sort"`, `"Clear Sort"`; category `"Table"`.

- [ ] **Step 2: Dispatch against `app.menu.ctx_col`**

The target column is the menu's, set when it opened. There is no persistent current column in the table
view — only `table_edit_col`, and only while a cell is being edited.

- [ ] **Step 3: Exclude all six from the palette**

Add them to `command_in_palette`'s `#partial switch` at `palette.odin:103`, with a comment stating the
reason: they act on a column the palette has no way to name. This is a real cost, accepted knowingly.

- [ ] **Step 4: The item table and its predicates**

```
Sort ascending        always enabled
Sort descending       always enabled
--- separator ---
Then by ascending     enabled: table_sorted(doc) && (table_sort_key(doc,c).ok || table_sort_can_add(doc,c))
Then by descending    same
Remove from sort      enabled: table_sort_key(doc, c).ok
--- separator ---
Clear sort            enabled: table_sorted(doc)
```

Disabled rows are **greyed, not hidden** — `Menu_Item.enabled`'s own comment gives the reason (a menu that
offers commands which silently no-op is lying about what it does). Give the full-vector case an
`item_disabled_reason`, or it reads as a broken row.

- [ ] **Step 5: `tablesorttest` case 7**

Every row of that table, in each of: unsorted; sorted by this column; sorted by another column; vector
full and this column not in it. Assert `item_enabled` directly — do not infer it from a click.

- [ ] **Step 6: Sabotage**

Make `Remove from sort` always enabled; the unsorted case must fail. Record the output. Restore.

- [ ] **Step 7: Commit**

```bash
git add src/program/commands.odin src/program/palette.odin src/program/menu.odin src/program/test_modes.odin && git commit -m "Add the header menu's six sort commands"
```

---

### Task 6: `table_header_layout()` — the chevron, and the seam

**This is the task most likely to produce a bug, and the bug has a name:** development-loop §4 Shape B —
a correct, tested function fed the wrong input, or its result read in the wrong space. Sixteen bugs in one
session were this shape. The header goes from one hit region to two.

**Files:**
- Modify: `src/program/table.odin` — new `table_header_layout`; `table_edge_at` (`:1608`),
  `table_header_col_at` (`:1645`), `table_header_hover_col` (`:1682`), `table_sort_arrow_rect`, the header
  draw (`:2556-2665`)
- Modify: `src/program/main.odin:717-740` (press) and `:1824` (hover/cursor)
- Modify: `src/program/test_modes.odin` — `tablesorttest` case 9

**Interfaces produced:**

There is **no generic `Rect` type in this codebase** — `table_sort_arrow_rect` returns `Table_Arrow`
(`table.odin:1809`, fields `x, y, w, h`) and the tab strip has its own `Tab_Rect`. Add one shared shape
here rather than a third ad-hoc struct:

```odin
Table_Rect :: struct {x, y, w, h: f32}

Table_Header_Cell :: struct {
    c:        int,
    body:     Table_Rect, // the cell, minus the chevron slot when one is shown
    chevron:  Table_Rect, // zero-size when suppressed
    has_chev: bool,
}

table_header_layout :: proc(doc: ^Document, char_w, width, px: f32, hover_col: int,
                            allocator := context.temp_allocator) -> []Table_Header_Cell
```

- [ ] **Step 1: One producer, four consumers**

The draw, the hit-test, the hover *and* the cursor read this. **No procedure may both compute one of these
coordinates and consume it**, and nothing may re-derive "where is the chevron" from `col.x + col.w`.
`table_sort_arrow_rect` already exists as a per-column slot producer — the chevron slot sits beside it, and
both come out of this one procedure.

- [ ] **Step 2: The chevron is hover-only and right-aligned**

Drawn only on the hovered column. §10 deleted the per-column rules because they made "the grid louder than
the data"; a chevron on every column is that chrome returning.

- [ ] **Step 3: Suppress it when the column is too narrow**

`has_chev = false` when the chevron would collide with the label. **Right-click still opens the menu**, so
the command is never unreachable.

- [ ] **Step 4: The resize edge wins**

The ±4px edge zone and the chevron share the cell's right edge. `table_edge_at` is tested first today and
`table_header_hover_col:1665` states the precedence; extend that comment to cover the chevron and keep the
edge winning. It is the narrower target and the older gesture, and a resize grab that opened a menu would
be the "affordance where the gesture is not" failure with an extra insult.

- [ ] **Step 5: Right-click opens the menu**

Right-click anywhere in the header cell → `menu_open_ctx(app, table_header_menu_items, x, y, col)`.
Left-click on the chevron → the same. Left-click on the body → Task 3's cycle.

- [ ] **Step 6: `tablesorttest` case 9 — test the seam, not the unit**

Compare what is **drawn** against what is **clickable**, at boundary sizes:

- a column narrower than the chevron (expect `has_chev == false`, and a right-click still resolves)
- a column exactly the chevron's width
- the last column against `table_content_right`
- a column scrolled part-way under the sticky gutter
- hovered vs. unhovered (the chevron exists only on the hovered one)
- a point inside the ±4px edge zone resolves to the **edge**, not the chevron and not a sort

- [ ] **Step 7: Sabotage — this is the one that matters**

Shift the drawn chevron rect one pixel from the hit-tested one. The seam test **must** fail. Record the
exact output. Restore. A seam test that survives this proves nothing and the whole task rests on it.

- [ ] **Step 8: Commit**

```bash
git add src/program/table.odin src/program/main.odin src/program/test_modes.odin && git commit -m "Give the table header one layout and a chevron"
```

---

### Task 7: The summary row and the per-key arrows

**Files:**
- Modify: `src/program/table.odin` — `table_summary_parts` (`:352-386`), header arrow draw (`:2620-2651`)
- Modify: `src/program/test_modes.odin` — `tablesorttest` case 10

- [ ] **Step 1: The key list**

`sorted by Date asc, Name desc  ·  click to clear`. The clickable run still starts at `sorted by` and ends
at `click to clear`, and `clear_s`/`clear_e` are still produced **beside the `sbprintf` that writes the
words** — `:346` gives the reason and it still holds: a second procedure deriving "where does the sort
clause start" from the finished string would name the wrong bytes the first time the wording changed.

- [ ] **Step 2: Check it against the band at a small window**

Measure the longest 2-key line
(`120,000 rows · 8 columns · sorted by Department asc, Last Name desc · click to clear`)
against the summary band at the narrowest supported window. **Decide the behaviour if it does not fit and
implement that decision** — do not leave it to be discovered. The cap is already at 2 for a separate
reason (Task 2's measurement), so lowering it further is not the answer here; if the line does not fit,
the answer is in the wording or the band, and it goes to Wyatt.

- [ ] **Step 2b: Say the cap refusal (added 2026-07-31, Wyatt's decision on Task 3's review)**

At `TABLE_SORT_KEYS_MAX` a Ctrl+click on a third column does nothing, silently. `table.odin` argues twice
that *"a header that does nothing when clicked is indistinguishable from a broken build"* — the reason the
row-ceiling refusal is in this row at all. Give the cap the same treatment: when the vector is full, the
summary row says so.

Follow the ceiling refusal's own shape (`table_summary_parts`'s `refused` branch) rather than inventing a
second mechanism, and keep the wording a fact rather than an error — the user has a working two-key sort,
they just cannot add a third. **Do not add a second flag to `Table_Sort` if `nkeys == TABLE_SORT_KEYS_MAX`
already tells you** — a stored flag needs clearing from every path that changes the vector, which is the
`command_mutates_doc` maintenance shape this project has now patched three times.

- [ ] **Step 3: Per-key arrows with a precedence digit**

Every sorted column draws its arrow, at its own key's direction. **The digit is drawn only when
`nkeys > 1`** — a lone "1" beside a single sort is noise. Keep the ghost-arrow preview on the hovered
unsorted column and keep the quads-not-a-glyph rule (`:2631` — nothing guarantees the user's monospace
face has U+25B2).

- [ ] **Step 4: `tablesorttest` case 10**

The wording at 1 and 2 keys; `clear_s`/`clear_e` naming exactly the drawn run (assert the byte span
against the string, not against a literal); the digit absent at `nkeys == 1` and present at 2.

- [ ] **Step 5: Sabotage**

Compute `clear_s` in a second pass over the finished string with the wording changed by one word. The span
assertion must fail. Record the output. Restore.

- [ ] **Step 6: Full regression sweep**

```
odin test src\base -collection:src=src
```

```
$env:NEWTPAD_SESSION_DIR = "$env:TEMP\np-b19"; foreach ($m in @("tablesorttest","tablegridtest","tablecellstest","tablereadonlytest","csvtest","menutest","menuseam","selalltest","keytest","resavetest","lineidxtest","watchtest","hscrolltest","palettetest","settingstest")) { build\newtpad.exe $m; if ($LASTEXITCODE -ne 0) { echo "FAILED: $m" } }
```

Expected: no `FAILED:` line. **`Select-String "FAIL"` is case-insensitive** — do not grep for it, check
exit codes as above.

**`menuseam` is NOT in that list and must not be, because an exit code cannot see it.** It is a falsifier
with no pass/fail: it measures whether resolving scroll twice in one frame diverges, and it exits 0 no
matter what it finds. Task 4's review watched its answer move from `14/14` to `12/12` under a sabotage
while the exit code stayed 0 throughout. **Check its printed line instead**, and expect exactly:

```
14/14 scrolling cases diverge across one selection move; idempotent-for-fixed-item=true
```

Task 4 also fixed `menutest` and `settingstest`, both of which printed their failure count and then
exited **0** — so any sweep run before that fix was non-diagnostic for those two. If a sweep in a later
session finds a third mode with the same shape, the fix is `palettetest`'s pattern in the same file.

- [ ] **Step 7: Commit**

```bash
git add src/program/table.odin src/program/test_modes.odin && git commit -m "Say the whole sort in the summary row"
```

---

### Task 8: Landing

- [ ] **Step 1: `tablesorttest` into both required lists**

`HANDOFF.md` §7's headless-mode list **and** `docs/development-loop.md` §6. The rule that produced
`selalltest`: *"a mode nothing runs is worse than no mode."* One-argument, exits non-zero, counts a missing
`NEWTPAD_SESSION_DIR` as a failure.

- [ ] **Step 2: HANDOFF entry `§6bc`**

Not a changelog. What was built, **why it was built that way**, what it got wrong, and what is owed. The
"two things this batch got wrong" sections have been more useful to later sessions than any success
description. Include the k=3 measurement, and whether it moved the key cap.

- [ ] **Step 3: Version bump to `0.36.0` in `src/program/version.odin`, same commit as the HANDOFF entry**

`release.ps1` greps this file, so the tag and the binary cannot disagree. A feature batch is a minor bump.

- [ ] **Step 4: Every commit builds**

```bash
for c in $(git rev-list --reverse main..HEAD); do d=$(mktemp -d); git archive "$c" | tar -x -C "$d"; ( cd "$d" && odin check src/program -collection:src=src >/dev/null 2>&1 ) && echo "ok   $c" || echo "FAIL $c"; done
```

Archive the **whole tree** — `links.odin` does `#load("../../text_exts.txt")` and a partial archive fails
for that reason alone, which looks exactly like a real failure.

- [ ] **Step 5: Whole-branch review, on the most capable model**

Point it at what the per-task reviews **structurally could not see**: whether the key vector's invariants
hold across every consumer of `perm`/`rank`; whether the lifetime hooks are still the only route;
whether any assertion is vacuous; whether this batch made the planned `renderer`/`ui` extraction harder,
and where. Hand it every finding carried deliberately and make it triage each: carry, or block?

- [ ] **Step 6: Merge, install, release**

Merge to `main`. Check `Get-Process newtpad` before `install.ps1` — **never `-Force` while it is running**,
a hard kill skips the hot-exit session write and loses unsaved tabs. Then run `.\release.ps1` **bare** —
never piped through `2>&1`, or the push "fails" after tagging and before the Release is created.

- [ ] **Step 7: Update the queues**

Delete the multi-column-sort half of `docs/requested-features.md` §1's entry (the filtering half stays for
batch 20), and add the shipped behaviour to `docs/features.md`. These are queues, not histories.

---

## Self-review against the spec

| Spec section | Task |
|---|---|
| §2 what must not break | 1 (migration table), 8 (whole-branch review) |
| §3 data model | 1 |
| §4 build, comparator, freeze budget | 2 |
| §5 three gestures + menu contents | 3 (gestures), 5 (menu) |
| §6 one layout, chevron, edge precedence | 6 |
| §7 summary row | 7 |
| §8 commands, palette exclusion | 5 |
| §9 generalise `Menu_State` | 4 |
| §10 tests 1–5, 8 / 6 / 7 / 9 / 10 | 2 / 3 / 5 / 6 / 7 |
| §10 sabotage | every task, own step |
| §11 out of scope | not implemented anywhere — verify in the whole-branch review |
| §12 owed | 8 (HANDOFF entry) |

Two gaps found on review and fixed above rather than left as notes: spec §10 item 8 (the refusal at
`TABLE_SORT_MAX` with k keys) had no test step and is now Task 2's case 6; and Task 6 named a `Rect` type
this codebase does not have.

**One thing this plan deliberately does not decide:** Task 7 Step 2 can conclude that a 2-key summary line
does not fit the band at a small window. The answer would be in the wording or the band, and it is a
product decision — it goes to Wyatt, not to the implementer.

**Amendment log.** `TABLE_SORT_KEYS_MAX` 3 → 2 on 2026-07-31, after Task 2's measurement and Wyatt's
decision. Task 2's commit message says "up to three keys" because it predates the change; the constant
moves in Task 2's fix round.
