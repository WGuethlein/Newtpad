# Plan — the markdown preview, rebuilt against Obsidian

**Spec:** [`../specs/2026-09-03-preview-obsidian-design.md`](../specs/2026-09-03-preview-obsidian-design.md)
**Scope (Wyatt, 2026-09-03):** W1–W6, W7a, W8. **W7b (easing) is deferred** — see spec §4.1.
**Branch:** cut `feat/preview-obsidian` from `fix/preview-inert` (which already carries `mdhittest`
and the press diagnostic).

Every number below comes from spec §3, which came from Obsidian's own `app.css`. Every claim about our
code below was checked against the file and line named — where a claim is an inference, it says so.

---

## Preconditions, run once before task 1

```
set NEWTPAD_SESSION_DIR=%TEMP%\newtpad-plan
build.bat
build\newtpad.exe modeguardtest
odin test src\base -collection:src=src
odin test src\ui   -collection:src=src
```

`modeguardtest` first, always — it is the check that the rest of the suite can fail at all. Record the
**baseline** of `mdperftest` here too: W1 changes block heights and W7a changes how often the layout is
walked, and its gate is in the exit code.

---

## Task order and why it is this order

W1 → W5 first: they are constants in one procedure, they are what Wyatt judges by eye, and they change
block heights that W7a's scroll assertions will then be written against. W6 and W8 are independent and
could go anywhere. **W7a goes last** because it is the only task whose test depends on final block
geometry.

| | Task | Risk | Needs review |
|---|---|---|---|
| 1 | W1 — type scale, heading leading, vertical rhythm | low (constants, one proc) | yes |
| 2 | W2 — Segoe UI body face | low (a reorder) | yes |
| 3 | W5 — block geometry | low (constants) | yes |
| 4 | W8 — the three fence defects | low | yes |
| 5 | W3 — measure, pad, four-state column, **cache key** | **high — hit-test seam + cache** | yes, hardest |
| 6 | W4 — the segmented control | medium (new `ui` geometry) | yes |
| 7 | W6 — `press_route` extraction + context menu | **high — frame-loop routing** | yes, hardest |
| 8 | W7a — pixel wheel, within-block sync | **high — scroll model** | yes |

---

## Task 1 — W1: type scale, heading leading, vertical rhythm

**File:** `src/program/markdown.odin`

### 1a. `md_metrics` (line 1830) — the constants

Replace the scale and rhythm assignments. `md_scale(s, k)` is
`max(1, f32(int(s*k + 0.5)))` (line 1824), so every value stays `round(k·S)` and `metricstest`'s
structural assertion is untouched.

```odin
m.head = {0, md_scale(s, 1.618), md_scale(s, 1.462), md_scale(s, 1.318), md_scale(s, 1.188), md_scale(s, 1.076), md_scale(s, 1.000)}
m.body      = md_scale(s, 1.00)
m.code      = md_scale(s, 0.80)   // was 0.92 -- Obsidian's --font-smallest
m.table     = md_scale(s, 1.00)   // was 0.95 -- Obsidian's table text is full size
m.caption   = md_scale(s, 0.88)   // unchanged, still reserved
m.body_lead = md_scale(s, 1.50)   // was 1.65
```

**The rhythm becomes uniform** (spec §3.4). Both arrays keep their `[7]f32` shape so nothing downstream
re-indexes:

```odin
// Obsidian gives every heading the same space, and the LEVEL does not enter it:
// `h1..h6 { margin-block-start: 1rem; margin-block-end: 1rem }`, with
// `:is(p,pre,table,ul,ol) + :is(h1..h6) { margin-top: 2.5rem }` on top. So the
// 2.5 S is a property of the PAIR, applied in md_pass (1c below); what lives
// here is the 1.0 S a heading carries on its own.
m.head_above = {0, md_scale(s, 1.00), md_scale(s, 1.00), md_scale(s, 1.00), md_scale(s, 1.00), md_scale(s, 1.00), md_scale(s, 1.00)}
m.head_below = {0, md_scale(s, 1.00), md_scale(s, 1.00), md_scale(s, 1.00), md_scale(s, 1.00), md_scale(s, 1.00), md_scale(s, 1.00)}
m.para_below = md_scale(s, 1.00)  // was 0.80
m.list_gap   = md_scale(s, 0.15)  // was 0.25 -- --list-spacing 0.075em, top AND bottom
m.quote_above, m.quote_below = md_scale(s, 1.00), md_scale(s, 1.00)
m.fence_above, m.fence_below = md_scale(s, 1.00), md_scale(s, 1.00)  // unchanged
```

### 1b. Per-level heading leading — a new field, because `line_height` is the editor's

`md_layout_build`'s `.Heading` case (line 3533) currently does `lead = line_height(px)`, and
`line_height` (`doc.odin:224`) is `int(px * LINE_SPACING + 0.5)` with `LINE_SPACING :: 1.5` — the
**editor grid's** ratio, shared with every row in the document surface. Obsidian gives h1/h2 1.2, h3
1.3, h4 1.4, h5/h6 1.5.

Add to `Md_Metrics`, beside `head`:

```odin
// Obsidian's per-level heading leading (--h1-line-height … --h6-line-height).
// NOT line_height(): that is LINE_SPACING, the editor grid's 1.5, and a heading
// is not on the grid. head_lead[0] is unused so head_lead[level] indexes directly,
// exactly as `head` does.
//
// Rounded through the same int() the grid's is, and for the same reason
// (doc.odin:224): an unrounded fractional leading drifts half a pixel per line,
// which is a full line by line 40. A heading is rarely 40 lines, but the block
// HEIGHT feeds the scroll anchor, so a fractional one drifts the anchor instead.
head_lead: [7]f32,
```

```odin
m.head_lead = {0,
    f32(int(m.head[1] * 1.2 + 0.5)), f32(int(m.head[2] * 1.2 + 0.5)),
    f32(int(m.head[3] * 1.3 + 0.5)), f32(int(m.head[4] * 1.4 + 0.5)),
    f32(int(m.head[5] * 1.5 + 0.5)), f32(int(m.head[6] * 1.5 + 0.5))}
```

and at line 3533:

```odin
lead = m.head_lead[clamp(e.cls.level, 1, 6)]
```

### 1c. The pair rule — 2.5 S above a heading that follows content

The gap between two blocks is already `max(prev.below, next.above)` (`Md_Metrics`' header, and the
collapse is implemented in `md_pass` around line 4278). The pair rule is therefore expressible without
a second mechanism: **a heading's `above` becomes 2.5 S when the previous block is content.**

Implement it where the collapse already happens, not in `md_layout_build` — `md_layout_build` sees one
block and cannot know its predecessor, and a cached entry must not bake in a neighbour. Concretely, at
the collapse site, when `next.kind == .Heading` and `prev.kind` is one of
`.Para .Fence_Close .Table .List .Quote .Rule`, use `md_scale(m.s, 2.50)` in place of `next.above`.

**A heading following another heading, and a heading opening the document, keep 1.0 S** — which is what
Obsidian's `+` combinator does, since a heading is not in its `:is(p,pre,table,ul,ol)` set.

> **Implementer:** read `md_pass`'s collapse block before writing this. The claim that the collapse
> lives there is read from `Md_Metrics`' header comment and the `prev_below` references at lines
> 4246/4278/4297; verify the exact site. If the collapse turns out to be somewhere else, put the rule
> where the collapse is — do not add a second collapse.

### Test — `metricstest`

Assert the **values**, not bounds (the register: *"where a value is derivable, assert the value, not a
bound"* — four slack assertions admitted defects last session). At `S = 16`: `head` = `{0,26,23,21,19,17,16}`,
`body_lead` = 24, `code` = 13, `para_below` = 16, `head_lead` = `{0,31,28,27,27,26,24}`. Compute these in
the test from `md_scale`, do not paste them — the point is the ratio.

Add a case for the pair rule: build `para → h2` and `h2 → h3`, assert the first gap is `2.50 S` and the
second `1.00 S`.

**Sabotage:** set `m.head[1]` back to `1.85`; set the pair rule to fire unconditionally. Both must go
red. Restore.

---

## Task 2 — W2: Segoe UI body face

**File:** `src/platform/text.odin`, `BODY_FAMILIES` (line 238)

Segoe UI is **already the fourth row with all four styles** — this is a reorder, not font loading:

```odin
// Segoe UI first, not Georgia: C7 (docs/ui-spec-gaps/README.md) measures the
// preview against Obsidian and Obsidian wins where it and 9.3 conflict, and
// 9.3's serif is named in scope. Obsidian's --font-default is
// `ui-sans-serif, …, "Segoe UI", …`, which resolves to Segoe UI on Windows --
// so this is the face Wyatt's Obsidian is actually drawing, not a sans chosen
// to be sans. The serifs stay below it: Settings > Preview font still offers
// them, and 9.3's "on every Windows install" argument is why they remain the
// fallback rather than being deleted.
BODY_FAMILIES := [?]Font_Family {
    {"Segoe UI",        "segoeui.ttf",  "segoeuib.ttf",  "segoeuii.ttf",  "segoeuiz.ttf",  {}},
    {"Georgia",         "georgia.ttf",  "georgiab.ttf",  "georgiai.ttf",  "georgiaz.ttf",  {}},
    {"Constantia",      "constan.ttf",  "constanb.ttf",  "constani.ttf",  "constanz.ttf",  {}},
    {"Times New Roman", "times.ttf",    "timesbd.ttf",   "timesi.ttf",    "timesbi.ttf",   {}},
}

```

Also update the comment at line 234 (*"Georgia first because §9.3 names it"*) — it becomes wrong the
moment this lands, and a stale rationale comment is worse than none.

**Then re-measure the leading.** Spec §3.3: `body_lead` is a **floor**, and the shaper clamps up for a
face whose ascent+descent exceeds it. Georgia's is 1.136 em; Segoe UI's is different. Read
`Shaped.line_h` back at `S = 16` and record the actual value in the task report. **If it exceeds
`1.50 · S = 24`, say so and stop** — `head_lead`'s tight heading values would be silently clamped too,
and the whole rhythm is then not what §3 specifies. That is a finding, not something to work around.

**Check `settings.odin:312`** — `preview_font = ""` is documented as *"no preference: the curated serif
order decides"*. The comment is now wrong; the order is no longer serif-first.

**Test:** `fonttest`, `settingstest`. **Sabotage:** put Georgia back at the head and assert the mode
that names the resolved body family goes red. If no mode asserts the resolved family, add that
assertion — otherwise this task has no test at all.

---

## Task 3 — W5: block geometry

**File:** `src/program/markdown.odin`, `md_metrics` (line 1846-ish, the `sx()` block)

```odin
m.rule_gap     = sx(24)   // unchanged
m.fence_pad    = sx(12)   // vertical; see fence_pad_x below
m.fence_pad_x  = sx(16)   // NEW -- Obsidian's `padding: var(--size-4-3) var(--size-4-4)`
m.code_radius  = sx(4)    // was 3 -- --radius-s
m.fence_radius = sx(4)    // was 6 -- --radius-s, the same token
m.code_pad_x   = md_scale(s, 0.30)  // NEW -- inline code `padding: 0.15em 0.3em`
m.code_pad_y   = md_scale(s, 0.15)  // NEW
m.quote_inset  = sx(24)   // was 16 -- --size-4-6
m.quote_bar_w  = sx(2)    // NEW -- --blockquote-border-thickness
m.rule_h       = sx(2)    // NEW -- --hr-thickness
m.list_indent  = sx(24)   // unchanged at the first level; see below
m.list_hang    = md_scale(s, 0.80)  // NEW -- .list-bullet margin-inline-start: -0.8em
m.table_pad_x  = sx(8)    // NEW -- --size-4-2
m.table_pad_y  = sx(4)    // NEW -- --size-2-2
m.task_box     = sx(14)   // unchanged
```

**The list indent is the one judgement call in this task.** Obsidian uses `3ch` at the first level and
`2.25em` deeper. `ch` in a proportional face is the advance of `0`, which we can measure
(`plat.text_advance(nil, t, '0', m.body, .Body)` — `md_metrics` already calls exactly this for
`m.measure` at line 1852). Prefer the measured `3ch` over keeping 24px: the first level is the one the
eye reads as "how indented is a list", and `2.25 · S` for deeper levels.

`fence_pad` is currently one value used for both axes — check every read before splitting it, and give
the horizontal one its own name rather than overloading the existing field.

**Test:** `metricstest` for the values; `mdtest` / `mdfencetest` / `mdtabletest` for the blocks that
consume them. **Sabotage:** restore `fence_radius` to 6 and `quote_inset` to 16; both must go red.

---

## Task 4 — W8: the three fence defects

**File:** `src/program/markdown.odin`

**4a — `md_fence_lexer` (line 2018), add the PowerShell aliases.** `EXT_LEXERS` carries a real
PowerShell lexer at `.ps1` (`lex_shell_ps1_adapt`, stateful, `#>` resync). Add beside the existing
alias arms at line 2029:

```odin
case "powershell", "pwsh", "ps1":
    tag = "ps1"
```

**4b — `.Fence_Body` must set `fallback_set`.** The case sets `px`, `lead` and `base_col` but not
`fallback_set`, which defaults to `plat.Font_Set.Body` at the top of the proc; only `.Table` overrides
it. So a fence whose language has no lexer renders in the **proportional** face. After task 2 that is
proportional *sans* rather than proportional serif — no better, and the single largest reason a
screenshot of ours looks unlike Obsidian's.

Set `fallback_set = .Doc` in `.Fence_Body` (and check `.Fence_Open` / `.Fence_Close`, which draw the
fence's own line and may have the same hole).

**4c — the language label.** Obsidian shows the fence's language; §9 asks for one. Draw the tag from
`md_fence_lexer`'s already-parsed first word, top-right inside the fence card, in `text_dim` at
`m.caption`. **`caption` is currently reserved and unread** (its comment says so explicitly) — this is
its first consumer, so update that comment: it stops being reserved.

**Test:** `mdfencetest`. Assert (i) ` ```powershell ` resolves a non-nil lexer, (ii) a fence with an
**unknown** language draws in `.Doc`, not `.Body` — this is 4b's assertion and it must name the set,
not the look, (iii) the label renders for a known and an unknown language alike.

**Sabotage:** remove the `powershell` arm; remove the `fallback_set` line. Both red.

---

## Task 5 — W3: measure, pad, four-state column, and the cache key

**The highest-risk task in the batch.** Read spec §3.5 and **§3.5.1** in full before starting.

### 5a — the state

```odin
// Preview column placement. Full is the default because it is what Wyatt's own
// Obsidian does: his app.json has `readableLineLength: false`, so the reading
// view he compared us against runs the full pane width (spec 1.1).
//
// Full and Left share an ORIGIN and differ in WIDTH -- Full stretches to the
// pane, Left caps at the measure. They are not the same state and must not be
// folded into one.
Md_Align :: enum u8 { Full, Left, Centre, Right }
```

`Md_Align` is already taken by the table's cell alignment (line 660) — **pick a different name**
(`Md_Column`) rather than overloading it.

### 5b — `md_content_span` (line 4013) becomes the four-state producer

It is already the single producer of `(origin, pane)` for the whole preview and has exactly one reader
of `m.pad_left`. Its `pad` becomes a symmetric 20 px (`sx(20)`), replacing `sx(40)`.

**It must keep returning the UNCAPPED pane.** Its own comment (line 4010) is the reason:

> keyed on the capped value, a table's layout would not invalidate when the pane grew from 100ch to
> 140ch, because the key never moved

The cap stays inside `md_layout_build` (line 3377), where the block's kind is known and tables are
exempt. So `md_content_span` returns the origin for the chosen state and the uncapped pane; the cap is
applied per-kind downstream exactly as it is today.

### 5c — the cache key, and this is the part that would ship a bug

Switching Full → Centre at an unchanged window moves **none** of `Md_Slot_Key`'s terms
(`{block, rev, measure, px, ui_scale, faces}`) while changing the wrap width, so the cache returns the
Full layout for the Centre state.

Add the column state to `Md_Metrics`' **last section** — the one whose header already says *"the state
OUTSIDE this struct that a block's layout also depends on, sampled ONCE per pass here… All three are
cache-key terms"* — beside `ui_scale`, `theme` and `faces`, and add it to **`Md_Slot_Key`** and
**`Md_Max_Key`**.

`Md_Max_Key` matters as much as `Md_Slot_Key`: the max anchor is *"the anchor at which the document's
last block ends at the pane's bottom edge"*, a function of block heights, and capping the measure
changes every one of them.

### Test — three assertions, and the third exists because I got this wrong once

1. **Seam.** For each of the four states, at a pane **wider** than the measure and one **narrower**,
   assert the x the draw uses equals the x the hit-test resolves from, **and that the wrap widths
   agree**. Both terms: Full and Left share an `x` and differ only in width, so an assertion on `x`
   alone passes with the two states confused.
2. **Cache.** Build at pane `P` in Full, then the same `P` in Centre; assert the second did **not**
   reuse the first's entry — **by pointer identity**, not by comparing content. The bug is stale reuse
   and content comparison can pass with it present.
3. **Table invalidation.** A table at Centre must re-layout when the pane grows 100ch → 140ch, because
   a table ignores the cap. This goes red against the "pass the capped column as the pane" fix that
   §3.5.1 rejects, which is why it is written down rather than assumed.

**Sabotage:** offset one side of the seam by the alignment delta; make Full cap at the measure; remove
the new key term. Three separate reds.

---

## Task 6 — W4: the Full/Left/Centre/Right control

**Geometry in `src/ui`, appearance in `program`** — the split that makes `ui` testable without a
device (`src/ui/control.odin` is 209 lines, `control_test.odin` 217, and `odin test src\ui` runs today).

- A `segmented_layout(...) -> [4]Button`-shaped producer in `src/ui`, pure `f32` and strings. `Button.tag`
  is an `int`, not an enum, so nothing in `ui` names a type that lives upward — keep that.
- **One producer for draw and hit-test.** Same `*_layout()` call, per CLAUDE.md.
- **Drawn on hover over the preview pane; hit-tested unconditionally** (spec §5.1). A control that only
  becomes clickable after a hover is registered loses the first click of every interaction.
- Persist through `settings.odin` — it needs a stable `Setting_Id`, per the v0.87.0 move off index-based
  switch cases — and through `session.odin` if it is per-document rather than global. **Decide which and
  say why in the task report**: §11's *Remember last view used* is per file type, which argues for
  per-document, and `md_mode` is already stored that way.

**Test:** `odin test src\ui` for the geometry (positions, the four boxes, no overlap, right-edge
alignment at several widths); `settingstest` for the round trip. **Sabotage:** shift the hit boxes one
slot; drop the persisted value.

---

## Task 7 — W6: `press_route`, then the fix, then a context menu

**Read spec §4 B1.** Do not start by guessing at the routing.

### 7a — extract, exactly as `key_route` was extracted

HANDOFF §6cz: the whole per-event keyboard decision became `key_route` in `commands.odin`, driven by
`keytest` and `metricstest`. The press routing gets the same treatment: a **pure** predicate over the
gates — `md_mode`, `ro_surface_swallows`'s inputs, the drag latches, the x-gate, `mouse_count`, ctrl —
returning what the press *means*, with `main.odin` and a new test mode both calling it.

Extract **first, with no behaviour change**, and prove that: the suite must be green before the fix.

### 7b — the fix

The new mode drives every gate combination for Preview and Split. **Whatever it names is the bug.** If
it names nothing, the defect is upstream of the gates and the live diagnostic (spec §7) is the next
evidence — say so in the report rather than inventing a cause.

### 7c — right-click, which needs no diagnosis

`main.odin:987` calls `plat.window_clear_oneshot_presses(window)`, which zeroes `mouse_right_pressed`,
and the only reader is the table-header branch immediately above it. The preview's press block is ~50
lines below. **There is no preview context menu at all.**

Add one — Copy, Select All, and the view-mode toggle at minimum — hit-tested **before** the clear, in
the preview block's own region. `menu_open_ctx` already exists (`main.odin:966` uses it for the table
header) and is the mechanism.

**Watch the ordering rule** the clear's comment states: a right press has no terminal consumer, so one
that lands on the canvas must not still be pending next frame. Read it before moving anything.

**Test:** the new `press_route` mode. **Sabotage:** restore whichever gate the fix moved; assert red.

---

## Task 8 — W7a: pixel wheel, within-block sync

### 8a — the wheel

`md_wheel_px` (line 5227) returns `c.m.body_lead` — one body line per notch, in one frame. Return a
pixel delta instead. `Md_Anchor` already carries a sub-block `px`, so the model expresses this already;
`md_scroll_px` is the consumer (`main.odin:1406`).

Match Windows: `SPI_GETWHEELSCROLLLINES` × the line height is the OS-sanctioned delta, and honouring it
is why a wheel feels right rather than merely smooth.

### 8b — the sync, and here is the constraint that scopes it honestly

`md_preview_scroll` (`main.odin:2096`) does:

```odin
doc.top = min(md_anchor_top_byte(c, a), doc_max_top(doc, t, rows))
```

and `md_anchor_top_byte` (line 5512) is `pt_line_start(&doc.pt, a.block)`. **It discards `a.px`
entirely** — the anchor's pixel offset within the block never reaches the editor. That is the
blockiness, exactly.

**But the editor cannot scroll by pixels.** `doc.top` is *"byte offset of the top visible (visual) row"*
(`doc.odin:1843`), and every editor coordinate — `row_baseline_y`, `row_rect_y`, the caret, selection
rects, find rects, the hit-test — derives from whole rows. Making the editor pixel-scrollable is a much
larger change than this batch and is **not** in scope.

**So the sync resolves to the editor's natural granularity, one visual row, instead of a whole block:**
advance from the block's line start by `int(a.px / line_h)` visual rows, then take that row's start
byte. Block-anchored (so §9.4's drift argument still holds — the identity is still the block, spec §4.2)
and row-resolved rather than block-resolved. A paragraph is many rows; this is the improvement.

**Say the residual plainly in the task report:** the editor pane still steps by one row. The preview
pane is pixel-smooth. Whether that reads as smooth enough is Wyatt's call, and it is the question spec
§4.1 says to ask before costing W7b.

### Test

- Wheel: a delta of *n* pixels moves the anchor by exactly *n* pixels.
- Sync: assert the editor lands on a row that is **not** the block's first row for an anchor scrolled
  into the middle of a tall block. **That assertion cannot pass with block quantisation present**,
  which is the property to aim for over comparing content.

**Sabotage:** restore `md_wheel_px`'s `body_lead`; drop `a.px` from the sync. Both red.

**Re-run `mdperftest` against the preconditions baseline** and record the delta. Its gate is in the exit
code and this task changes how often the layout is walked.

---

## Closing the branch

1. `modeguardtest`, then the reachable modes: `mdtest`, `mdviewtest`, `mdjointest`, `mdfencetest`,
   `mdtabletest`, `mdperftest`, `mdhittest`, `splittest`, `metricstest`, `linktest`, `blocktest`,
   `wraptest`, `settingstest`, `menutest`, `fonttest`, plus `odin test src\base` and `odin test src\ui`.
   **Sweep what the change can reach, not this list** — `gutterseamtest` and `rulestest` each went red
   for releases by trusting a written-down list.
2. Exit codes, not just `grep FAIL`. `WARN` marks the wall-clock gates that sit outside the exit code.
3. Whole-branch review on the most capable model.
4. **Sabotage every new assertion** and watch it fail. A test that has never failed proves nothing.
5. HANDOFF entry; **C8 and C9 into `docs/ui-spec-gaps/README.md`'s decisions table** (spec §7.1); strike
   C7's items from the sweep.
6. **The 1:1 pass**: `docs/preview-compare.md` open in both applications, side by side. Everything in
   spec §3 is a reading of a stylesheet until that happens.
7. Merge, `install.ps1`, `release.ps1`.

## What is deferred, and is not forgotten

- **W7b — easing.** Needs UI spec §17's `scroll → 0ms` row amended and §11's Reduce motion setting
  (`SPI_GETCLIENTAREAANIMATION`, re-read on `WM_SETTINGCHANGE`) built first. Costed only if Wyatt says
  W7a is still blocky.
- **Images and footnotes** — §9.2's unimplemented list, and `preview-compare.md` §8's known gaps.
- **The graduated heading weights** — refused in spec §3.2; four discrete faces, no variable axis.
