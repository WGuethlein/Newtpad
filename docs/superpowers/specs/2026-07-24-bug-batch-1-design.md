# Bug batch 1 — six live-use bugs

Date: 2026-07-24. Reported by Wyatt from daily driving 0.9.0.

Branch 1 of 2. This spec covers the six bugs only. The four features from the same report
(Alt+arrow line move, drag-and-drop open, per-file-family view memory, resizable split) get a
separate spec after this lands and Wyatt has taken a live pass.

Sequencing was chosen deliberately (CLAUDE.md priority order: correctness first) and so that the
live verification pass is small enough to be a real signal rather than a shrug.

## Summary of causes

All six were root-caused against the source before this spec was written, not inferred from
symptoms. Bug 2 was the last to fall and needed Wyatt's screenshot to pin: the caret drawn on row 1
at column 0 with the text on row 0 is what identified the phantom row.

Two of them — the most visible two — turn out to be the same seam: `visible_next` in
`src/program/doc.odin`, the shared capped line iterator that every screen pass reads.

| # | Symptom | Cause | Site |
|---|---|---|---|
| 2 | Caret one row below the text on untitled tabs | phantom trailing row emitted when the buffer has no trailing newline | `doc.odin:513`, `:1728` |
| 4 | Newlines counted as characters (4 symptoms) | `'\r'` is inside the row range; stripped only in the text draw | `doc.odin:1873` vs `:1906` |
| 5 | `(no matches)` flickers during rapid replace | status text tests `len(matches)==0` without consulting `find_busy` | `main.odin:949` |
| 3 | Extra space in the Ctrl+H find line | hardcoded leading `"  "` in `info` + caret slot that vanishes | `main.odin:954,957` |
| 8 | Markdown preview tables misaligned | each row advances `x` by its own cell widths | `markdown.odin:367` |
| 10 | Ctrl+Left/Right asymmetric | right lands on word ends, left on word starts | `doc.odin:1585-1599` |

## 1. The `visible_next` seam (bugs 2 and 4)

These two are specified together because they are edits to the same procedure and share one test.

### 1a. Bug 2 — the phantom trailing row

`next_row_start_capped` (`doc.odin:1726`) returns `doc.pt.length` for two different facts:

- "the next row starts at `length`" — true when the buffer ends with a newline, where that final
  empty row legitimately exists and must be rendered;
- "there is no next row" — true when the buffer's last line runs to EOF with no newline.

On buffer `"a"` with the caret at 1: `pt_line_end_cap` finds no `'\n'` and returns its limit, 1;
`next_row_start_capped` sees `e >= length` and returns 1. `visible_next`'s stop test is
`if nxt <= start`, and `1 <= 0` is false, so `it.pos = 1`. The following iteration's guard is
`it.pos > d.pt.length`, and `1 > 1` is false, so a phantom row with `start == end == 1` is emitted.

The caret loop (`doc.odin:1905`) assigns `cx`/`cy` on *every* matching row, so the phantom — which
matches, because `cursor >= start && cursor <= end && line_end` all hold — overwrites the correct
row-0 hit. `cprefix` is 0 there, which is why the caret sits at column 0 and never follows the text.

Opened files end with a trailing newline, so their phantom row coincides with the legitimate empty
last line and nothing looks wrong. A scratch buffer never ends with a newline, so it always has one.
That is the whole of the untitled/opened split Wyatt observed.

**Fix.** Make the "no next row" signal unambiguous rather than patching the one caller:

```
next_row_start_capped :: proc(doc: ^Document, pos: int) -> (start: int, ok: bool)
```

`ok == false` means the row beginning at `pos` was the last one. `eff_next_row` propagates both
returns. Every call site must then acknowledge the distinction.

This is wider than a one-line stop condition in `visible_next`, and that is the point.
`eff_next_row` (`doc.odin:368`) forwards to this helper unchanged, so `doc_max_top`, down-arrow and
page-down inherit the same ambiguity and can also step onto the phantom row on a buffer with no
trailing newline. Fixing the contract makes the bug unrepresentable; fixing `visible_next` alone
would leave the sibling walkers wrong and the next symptom looking unrelated.

The non-wrapping branch of `visible_next` gains the stop its wrapping sibling already has
(`doc.odin:500` gets it right today): stop when the row consumed the last byte and there was no
newline to step past. A trailing-newline buffer still emits its final empty row, because there
`end` is the `'\n'` offset, which is strictly less than `length`.

Call sites to audit as part of this change: `visible_next`, `eff_next_row` and its callers
(`doc_max_top`, `eff_row_start`, vertical nav, page nav), and anything comparing a row start
against `pt.length`.

### 1b. Bug 4 — CRLF inside the row range

A rendered row is `[start, end)` where `end` is the offset **of** the `'\n'` — the renderer reaches
it via `pt_line_end_cap` (`piecetable.odin:363`), which returns the newline's offset exactly as the
uncapped `pt_line_end` (`:344`) does, or a synthetic cap boundary on a pathologically long line. On
a CRLF file that range still contains the trailing `'\r'`. The text draw
strips it — `doc.odin:1873`, `if vis > 0 && line_buf[vis-1] == '\r' {vis -= 1}` — and nothing else
does. The caret at `:1906` clips `cprefix` to `n` (bytes read) rather than `vis` (visible cells);
the selection quads, `wrap_row_end`, and `line_cell_col` never strip.

That single fact produces all four symptoms Wyatt reported:

1. selection paints an extra cell at EOL — the `'\r'` cell;
2. the caret can sit one column past the last character — on the `'\r'`;
3. `Col` reads one too high at end of line — `line_cell_col` counts the `'\r'`;
4. wrap breaks a line one column early — the `'\r'` consumes wrap budget.

`'\r'` renders as no glyph while the pen still advances, which is why it reads as a phantom cell
rather than as visible garbage.

**Fix.** Move the strip into `visible_next` so there is exactly one definition of a line's visible
extent. It returns both:

- `end` — structural, unchanged: still the `'\n'` offset, so `it.pos = end + 1` keeps working;
- `vis_end` — content end, trailing `'\r'` excluded.

Delete the special case at `:1873`. Route the caret, the selection quads, `wrap_row_end`, the
click hit-test, and `line_cell_col` through `vis_end`.

**Approved behaviour change (Wyatt, 2026-07-24): CRLF becomes atomic for the caret.** The caret can
never sit between CR and LF. `End` lands before the `'\r'`; Left-arrow from a line start crosses
both bytes in one step; shift-selection to end of line selects to `vis_end`. This is visible on
every Windows file, which is why it was raised explicitly rather than assumed.

**Why one seam and not four fixes.** Four symptoms, five consumers. Patching the symptoms leaves
whichever consumer is missed still wrong — which is exactly how this bug reached daily use, since
the draw was already correct. This is the "One layout per widget" rule from CLAUDE.md and the
sixteen-bugs-one-shape lesson in HANDOFF §6j.

## 2. Bug 5 — `(no matches)` flicker

`find_replace_current` (`find.odin:510`) edits the buffer, which calls `find_invalidate` →
`search_stop` + `dirty = true`, then `find_recompute`, which clears the match arrays. For the frames
between the clear and the worker's first publish, `len(f.matches) == 0`. The status text at
`main.odin:949` tests only that, and never consults `find_busy` (`find.odin:297`), which already
reports exactly this state (`search.th != nil || find.dirty`).

**Fix.** Store the last published match count and index on `Find`. While `find_busy(doc)` is true,
keep displaying them. Render `(no matches)` only when a search has *completed* with zero matches.

Not a `(searching…)` indicator: that replaces one flicker with a different one. The count is stable
across a rapid replace because the previous count stays on screen until a real result replaces it.

## 3. Bug 3 — Ctrl+H find-line spacing

`main.odin:954` builds `info` with a hardcoded leading `"  "`, and `:957` inserts the caret slot
`" _"` only when `f.field == 0`. With focus on Replace the caret slot vanishes and the gap before
`(1/24)` changes width.

**Fix.** Give the caret a fixed-width slot in both focus states, and let a single separator own the
space before the count. `info` stops carrying leading whitespace.

## 4. Bug 8 — markdown preview tables

`md_draw_table_row` (`markdown.odin:357`) advances `x` by *each cell's own* measured width
(`max(cells+3, 8)`), so every row computes different column positions — columns cannot line up by
construction, and the `│` separators land mid-text. Two further defects in the same function: the
separator row is skipped entirely (`markdown.odin:275`) so no header rule is drawn, and
`strings.trim(line, "| ")` trims both ends of that character set, which eats empty leading cells.

**Fix.** Replace the streaming per-row draw with two passes over a contiguous table block:

1. **Measure** — walk the block, split each row into cells, take the per-column maximum cell width.
2. **Draw** — draw every row at fixed column x positions; honour the separator row's alignment
   markers (`:--` left, `:-:` centre, `--:` right); draw a real header rule where the separator row
   was; clip to `x1`.

Empty cells are preserved: split on `|` after stripping at most one leading and one trailing
delimiter, rather than trimming the character set.

### Column widths must not depend on scroll position

The markdown draw is today a single forward walk over visible lines (`p = end + 1`), so it cannot
know column widths without looking ahead — and a table can begin above the viewport. Measuring from
the visible rows only would make the widths a function of scroll position, i.e. **columns that shift
as you scroll. That is not acceptable** (Wyatt, 2026-07-24) and no part of this design permits it.

Note the cost is bounded by content, not by file size: a table block ends at the first non-table
line, so measuring one is O(block), not O(file).

**Hoist the measure out of the draw and cache it per block.** Each frame:

1. locate the first visible table row;
2. O(1) test — is it inside the cached block's `[start, end)` and does `revision` match? If so use
   the cached widths and do not scan at all;
3. on a miss, scan backward to the block's true start and forward to its end, measure the
   per-column maxima, and cache `{start, end, revision, widths}`.

So a scan happens only when the viewport enters a *different* block or after an edit — never per
frame and never per scroll step. Within a block the widths are constant by construction, which is
what makes shift-free scrolling a property of the design rather than something to be tested for.

**Cache key.** `Document` gains a monotonic `revision: u64`, bumped in `push_undo`
(`doc.odin:1054`) alongside the existing `find_invalidate` call — before the `doc.batch` early
return, so every edit in a batch counts. That comment already asserts "every edit path routes
through here"; the implementation must verify that claim rather than trust it, since a mutation path
that bypasses `push_undo` would leave stale widths on screen. A test that edits through each public
mutator and asserts `revision` advanced is the check.

**The pathological block.** A block so large that even one measure pass is too slow — a database
dump, or a `.csv` renamed `.md`. Measurement is capped at a byte budget generous enough to cover any
hand-authored table (1 MB is roughly 12k rows; 4 MB roughly 50k). Within budget: content-sized,
cached, no shift. Beyond it, that block draws on **fixed N-cell columns** — column `i` at `i*N`,
with each row's cell count taken as drawn.

The fallback is deliberately fixed-width rather than available-width-divided-by-column-count:
the latter derives the count from a visible row, which reintroduces scroll dependence on a malformed
table whose rows have differing cell counts. Fixed columns depend on nothing outside the row being
drawn, so they are shift-free by construction too, and rows with different cell counts still align
on the columns they share.

A background measure worker (the existing line-count-worker pattern) would give content-sized
columns at any size, at the price of one snap when it publishes plus debounced re-measure on every
edit. Rejected for now as unjustified complexity for a file no human authors by hand — but the
per-block cache above is its prerequisite, so choosing it later costs nothing already built here.

## 5. Bug 10 — Ctrl+Left/Right asymmetry

`word_right_of` (`doc.odin:1593`) skips non-word then word, landing on a word **end**;
`word_left_of` (`:1585`) skips non-word then word backwards, landing on a word **start**. Hence
Wyatt's `"blender-mcp"` walk: rightward stops differ from leftward stops for the same text.

**Fix.** Replace the two-class `is_word` with three classes — word / punctuation / whitespace — and
stop at every class transition, with both directions landing on token **starts**. End of line is a
stop. `"blender-mcp"` then yields the same stops in both directions:
`| " | blender | - | mcp | " |`.

`doc_delete_word_back` (Ctrl+Backspace) shares `word_left_of` and inherits the new classifier;
that is intended and matches other editors.

**Known limitation, retained deliberately.** `is_word` classes every byte `>= 0x80` as a word
character, so non-ASCII punctuation (curly quotes, em dashes) classes as word. Fixing it properly
means decoding runes inside the nav loop. Out of scope for this batch; recorded here so it is an
accepted limitation rather than a silently inherited one.

## Testing

Pure logic, `odin test src\base -collection:src=src`:

- the three-class word classifier: class transitions, both directions, ASCII punctuation runs,
  `"blender-mcp"` symmetry as a named case;
- the visible-extent helper: CRLF, LF, bare CR, empty line, EOF with and without trailing newline.

Headless modes in `test_modes.odin` (set `NEWTPAD_SESSION_DIR` to a temp dir first):

- **The #2 repro**, written before the fix: a scratch document, one rune typed, assert the caret's
  row and column against the drawn row, and assert the emitted row count. Must reproduce the
  screenshot — caret row 1, column 0 — before anything is changed.
- **The #4 seam test**: on a CRLF buffer, assert drawn extent == caret-reachable extent ==
  selection extent == wrap-measured extent. A test that checks only the draw passes with the bug
  fully present, so it must compare consumers against each other, not against a constant.
- **EOF row count**: buffers with and without a trailing newline emit the correct number of rows;
  `doc_max_top` and down-arrow do not step past the last real row.
- **Table columns**: every row of a markdown table draws its cells at identical x positions, and
  alignment markers place text correctly.
- **Table columns do not shift with scroll** — the property Wyatt rejected the first design over, so
  it gets a direct test rather than an argument. Measure the drawn column x positions for a table
  taller than the viewport with the block entered from the top, then from the middle, then from the
  bottom, and assert all three are byte-identical. This must be watched failing against a
  visible-rows-only measure, because that is the implementation it exists to rule out.
- **Oversized fallback is deterministic**: a block past the measurement budget draws identical
  column positions from any scroll offset, including when consecutive rows have differing cell
  counts.
- **`revision` covers every mutation**: drive each public mutator (insert, backspace, delete word,
  replace selection, replace all, set line ending, undo, redo) and assert `revision` advanced. Stale
  widths on screen is the failure this prevents.
- **Find count stability**: a replace on a document with many matches never shows zero while
  `find_busy` is true.

Per CLAUDE.md, every one of these is watched failing with the bug reintroduced before the fix is
called done. This matters most for #4, where the pre-existing draw-side strip means a naive test
passes against the unfixed code.

Build with `build.bat` (debug, console) throughout; `build.bat release` once at the end. A bare
`odin build` omits the DPI manifest and is wrong for anything visual.

## Commit plan

One logical commit per bug, in this order. #2 and #4 lead because they are correctness bugs in the
shared iterator and everything else renders through it.

1. `next_row_start_capped` contract + phantom-row stop (#2), with its repro test.
2. `vis_end` on the iterator; route caret/selection/wrap/hit-test/col through it (#4).
3. Three-class word classifier and symmetric word nav (#10).
4. Sticky find count while a search is in flight (#5).
5. Find-line spacing (#3).
6. `Document.revision`, bumped in `push_undo`, with the mutator-coverage test. Split out because the
   table cache depends on it and it is the one change here that touches every edit path.
7. Two-pass markdown table layout on a cached per-block measure (#8).

## Out of scope

Deferred to branch 2: Alt+arrow line move, drag-and-drop open, per-file-family view memory with a
Settings override, resizable split divider.

Not addressed here, and not silently absorbed: rune-level classification of non-ASCII punctuation
for word nav (bug 10); content-sized table columns for blocks past the measurement budget, which
would need the background measure worker described in §4 and is rejected as unjustified for now.
