# Column / Block Editing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rectangular select-and-edit — Alt+drag or Alt+Shift+arrows makes a rectangle, typing replaces across every row, a zero-width rectangle acts as N carets so lines can be prefixed.

**Architecture:** Four integers on `Document` describe the rectangle in (logical line, cell column) space. **One procedure, `block_row_range`, converts a row's cell range to its byte range**, and the draw, the copy and the edit all ask it rather than each deriving it. Edits apply bottom-up inside one `doc_batch_begin`/`doc_batch_end` pair.

**Tech Stack:** Odin (`dev-2026-07a`), Win32, no new dependencies. All changes in `src/program/`, plus one accessor in `src/platform/window.odin`.

Spec: [`docs/superpowers/specs/2026-07-26-column-editing-design.md`](../specs/2026-07-26-column-editing-design.md). Read its "The model, and the risk that dominates it" section before Task 1 — the coordinate-space risk is the whole batch.

## Global Constraints

- **Git identity:** every commit authored solely by Wyatt Guethlein. Never `Co-Authored-By: Claude`, "Generated with Claude Code", a robot emoji, or any other AI attribution anywhere. `.claude/settings.json` sets `includeCoAuthoredBy: false` — do not override it.
- **Commit style:** imperative subject under ~65 chars; body only when the *why* isn't obvious.
- **Build:** `build.bat` from the repo root (debug, console subsystem). A bare `odin build` is wrong — it omits the DPI manifest and the SEH shim. Exe at `build\newtpad.exe`.
- **Tests:** set `NEWTPAD_SESSION_DIR` to a temp dir before every headless mode.
- **`Select-String "FAIL"` is case-insensitive** and matches "0 failures". Use `-CaseSensitive`.
- **Never run `drawcount`** — it opens a real window, hangs, and locks the exe.
- **Every commit must compile standalone.** Signature changes and their callers go in one commit.
- **Sabotage discipline:** for every test added, reintroduce the bug, run it, watch it fail, capture verbatim output, restore. "I verified it fails" without output is not evidence.
- **Odin comments use `--`, never em dashes.** User-visible strings are ASCII only.
- **Columns are CELLS, not bytes and not codepoints.** `plat.text_cell_width(t, r, .Doc)` classifies a rune as 0, 1 or 2 cells. A tab and a CJK character make byte↔cell differ per row. Every conversion goes through `block_row_range`.
- **Lines are LOGICAL line indices**, never visual rows. Column select requires word wrap off (spec, Option A).
- **`base.pt_line_start` is an UNCAPPED backward scan** and must never be called with an unbounded position on a large file — see `doc.odin:1853`. Use `base.pt_line_start_cap` and honour its `exact` flag; discarding that flag is a bug this codebase has shipped five times (HANDOFF §6w, Shape A).

---

## File Structure

| File | Responsibility | Change |
|---|---|---|
| `src/program/block.odin` | **New.** All block-selection state, geometry, clipboard and edits | Create |
| `src/program/doc.odin` | `Document` struct; selection; edits | Modify — five block fields, and clear-block hooks |
| `src/program/commands.odin` | Command table, keymap, dispatch | Modify — block commands, Alt+Shift bindings, Escape/wrap clearing |
| `src/program/main.odin` | Frame loop, input, draw | Modify — Alt+drag, block rects in the draw |
| `src/platform/window.odin` | Input | Modify — `key_alt_down` accessor |
| `src/program/test_modes.odin` | Headless harness | Modify — new `blocktest` mode |

A new file rather than more of `doc.odin`: `doc.odin` is already the largest file in the tree, and block editing is a self-contained subsystem with one entry point per operation. This also keeps the eventual `renderer`/`ui` extraction easier rather than harder.

---

## Task 1: The rectangle, and the one procedure that resolves it

**Files:**
- Create: `src/program/block.odin`
- Modify: `src/program/doc.odin` (`Document` struct, near `anchor` at line 645)
- Test: `src/program/test_modes.odin` (new `blocktest` mode)

**Interfaces:**
- Consumes: `base.pt_line_start_cap`, `base.pt_line_end_cap`, `plat.text_cell_width`, `doc.pt`.
- Produces, relied on by every later task:
  - `Document.block: bool`, `.block_anchor_line`, `.block_anchor_cell`, `.block_cursor_line`, `.block_cursor_cell` (all `int`)
  - `block_active :: proc(doc: ^Document) -> bool`
  - `block_clear :: proc(doc: ^Document)`
  - `block_bounds :: proc(doc: ^Document) -> (line_lo, line_hi, cell_lo, cell_hi: int)` — normalised so `lo <= hi` on both axes
  - `block_row_range :: proc(doc: ^Document, t: ^plat.Text, line_start: int, cell_lo, cell_hi: int) -> (byte_lo, byte_hi, pad_cells: int, ok: bool)`

**The procedure that matters.** `block_row_range` takes a row's *byte offset of its line start* and the rectangle's cell range, and answers three things: the byte range that cell range covers on this row, how many spaces the row would need to reach `cell_lo` if it is too short (`pad_cells`), and whether the answer is trustworthy (`ok`). It is the only place cells become bytes. The draw, the copy and the edit all call it; **no other procedure may walk a row counting cells.**

`ok=false` means the row could not be resolved within its scan bound — the caller must refuse, not guess. This is the `exact`-flag discipline from HANDOFF §6w: a bounded scan that cannot tell it was truncated is the bug shape this codebase produces most.

- [ ] **Step 1: Write the failing test**

Create a `blocktest` mode in `src/program/test_modes.odin`, following the shape of the existing modes (an `if os.args[1] == "blocktest" {` block, a local `fail := false`, `ok`/`FAIL` lines via `fmt.printfln`, and a `blocktest: all ok` / `blocktest: FAILURES` summary at the end). Use `require_scratch_session("blocktest")` at the top exactly as `themetest` does.

The fixture must contain a tab and a CJK character, because those are what make cells and bytes disagree:

```odin
	if os.args[1] == "blocktest" {
		if !require_scratch_session("blocktest") {return true}
		fail := false
		fmt.println("blocktest:")

		t: plat.Text
		plat.text_init_headless(&t)

		// Rows chosen so byte offsets and cell columns disagree in three
		// different ways: a plain ASCII row, a row whose leading tab makes one
		// byte span several cells, and a row of CJK where one rune is 2 cells
		// and 3 bytes. A rectangle over cells [2, 6) must land on different
		// byte ranges in each -- that divergence IS the feature, and a version
		// of block_row_range that confused the two spaces would still pass a
		// pure-ASCII fixture.
		src := "abcdefgh\n\tindented\n你好世界 ok\nshort\n"
		doc: Document
		doc_open_from_bytes(&doc, transmute([]u8)src)
		defer doc_close(&doc)

		// Row 0 is pure ASCII: cells [2,6) is bytes [2,6).
		ls0 := 0
		b0lo, b0hi, pad0, ok0 := block_row_range(&doc, &t, ls0, 2, 6)
		c0 := ok0 && b0lo == 2 && b0hi == 6 && pad0 == 0
		if !c0 {fail = true}
		fmt.printfln("  %-6s ascii row: bytes [%d,%d) pad=%d ok=%v", "ok" if c0 else "FAIL", b0lo, b0hi, pad0, ok0)

		// "short" is 5 cells; a rectangle starting at cell 8 selects nothing on
		// it and reports the padding an edit would need. pad is reported, NOT
		// applied -- selection never mutates.
		ls3 := doc_line_start_of_index(&doc, 3)
		b3lo, b3hi, pad3, ok3 := block_row_range(&doc, &t, ls3, 8, 10)
		c3 := ok3 && b3lo == b3hi && pad3 == 3
		if !c3 {fail = true}
		fmt.printfln("  %-6s short row selects nothing, pad=%d (want 3)", "ok" if c3 else "FAIL", pad3)

		// The CJK row: cells [2,6) must NOT be bytes [2,6). If this assertion
		// ever reads "bytes == cells" the two spaces have been confused.
		ls2 := doc_line_start_of_index(&doc, 2)
		b2lo, b2hi, _, ok2 := block_row_range(&doc, &t, ls2, 2, 6)
		c2 := ok2 && !(b2lo == 2 && b2hi == 6)
		if !c2 {fail = true}
		fmt.printfln("  %-6s cjk row: bytes [%d,%d) differ from cells [2,6)", "ok" if c2 else "FAIL", b2lo, b2hi)
```

Add `block_bounds` normalisation cases (drag up-and-left must give the same rectangle as drag down-and-right) and a `block_clear` case in the same mode.

If `doc_open_from_bytes`, `doc_line_start_of_index` or `plat.text_init_headless` are not the actual names in this tree, grep `test_modes.odin` for how existing modes stand up a `Document` and a `plat.Text` headlessly and copy that idiom exactly. **Do not invent a helper**; if a line-index→offset helper genuinely does not exist, add one to `block.odin` and name it in your report so later tasks can use it.

- [ ] **Step 2: Run to verify it fails**

```bash
build.bat
```

Expected: compile error, `undefined name 'block_row_range'`.

- [ ] **Step 3: Add the state**

In `src/program/doc.odin`, beside `anchor` (line 645), add:

```odin
	// --- rectangular (column) selection ---
	// Four integers, not a byte range: a rectangle is a (logical line, cell
	// column) region and cannot be expressed as cursor/anchor offsets. Lines are
	// LOGICAL line indices, never visual rows -- column select requires word wrap
	// off (see the design doc's wrap fork), and turning wrap on clears the block
	// rather than silently changing what the rectangle means.
	//
	// Cells, not bytes and not codepoints: the renderer is a monospace cell grid
	// (plat.text_cell_width classifies a rune as 0, 1 or 2 cells), so a tab or a
	// CJK character makes a row's byte range differ from its cell range. Every
	// conversion goes through block_row_range and nowhere else.
	block:             bool,
	block_anchor_line: int,
	block_anchor_cell: int,
	block_cursor_line: int,
	block_cursor_cell: int,
```

- [ ] **Step 4: Write `block.odin`**

Create `src/program/block.odin` with the package header comment (matching the house style of `links.odin` or `watch.odin`: a `// Layer: program -- ...` line, then *why* this file exists), and implement the five procedures above.

`block_row_range`'s body must:

1. Find the row's end with `base.pt_line_end_cap`, honouring its cap — the row may be arbitrarily long. If the scan was truncated before reaching `cell_hi`, **return `ok=false`**. Do not return a partial answer.
2. Walk the row's runes from `line_start`, accumulating `plat.text_cell_width(t, r, .Doc)`, recording the byte offset at which the accumulated cell count first reaches `cell_lo` and then `cell_hi`.
3. A rune straddling the boundary (a 2-cell CJK char half-inside the rectangle) is **included whole**. Record that choice in a comment: partial glyphs cannot be represented in the buffer, and including is the only option that round-trips.
4. If the row ends before `cell_lo`, return `byte_lo == byte_hi == row_end` and `pad_cells = cell_lo - row_cells`.
5. If the row ends between `cell_lo` and `cell_hi`, clamp `byte_hi` to the row end with `pad_cells = 0`.

- [ ] **Step 5: Run to verify it passes**

```bash
build.bat
```

```bash
set NEWTPAD_SESSION_DIR=%TEMP%\np_b1 && build\newtpad.exe blocktest
```

Expected: every line `ok`, `blocktest: all ok`.

- [ ] **Step 6: Sabotage-verify, and record the output**

Two sabotages, each restored before the next:

1. Make `block_row_range` treat cells as bytes (return `cell_lo`/`cell_hi` directly). Confirm the CJK case FAILS. This is the Shape B regression the whole batch guards against, so capture this output carefully.
2. Make the truncated-scan path return `ok=true` with its partial answer instead of `ok=false`. Add a fixture row longer than the cap if needed to reach it, and confirm a case FAILS.

- [ ] **Step 7: Commit**

```bash
git add src/program/block.odin src/program/doc.odin src/program/test_modes.odin
git commit -m "Resolve a block rectangle's rows through one procedure"
```

---

## Task 2: The keyboard gesture

**Files:**
- Modify: `src/program/commands.odin` (`Command_Id`, `command_table`, `default_bindings`, `command_dispatch`), `src/program/block.odin`
- Test: `src/program/test_modes.odin` (`blocktest`)

**Interfaces:**
- Consumes from Task 1: `block_active`, `block_clear`, `block_bounds`, the five `Document` fields.
- Produces: `Command_Id.Block_Extend_Left/Right/Up/Down`, and `block_extend :: proc(doc: ^Document, t: ^plat.Text, dline, dcell: int) -> bool` (false when refused).

**Context.** The keymap matches on `(key, ctrl, alt, ctx)` and **shift is read by the action, not part of the chord** (`commands.odin:232`). So `Alt+Shift+Up` and `Alt+Up` dispatch to the *same* binding — the existing `.Move_Line_Up`. Those two actions must branch on `ev.shift`. `Alt+Shift+Left/Right` need new bindings, since `Alt+Left/Right` are currently unbound.

**Refusal when wrapped.** If `doc.wrap` is true, `block_extend` posts `[COLUMN SELECT NEEDS WRAP OFF - press Alt+Z]` via `app_note` and returns false, changing no state.

- [ ] **Step 1: Write the failing tests**

In `blocktest`, add cases asserting: a first `block_extend` with no block active seeds the anchor at the caret's (line, cell) and moves the cursor end; `wrap = true` refuses and leaves `block` false; `block_clear` on `Toggle_Wrap`; and that extending left past cell 0 clamps rather than going negative.

- [ ] **Step 2: Run to verify it fails**

Expected: compile error, `undefined name 'block_extend'`.

- [ ] **Step 3: Add the commands**

Four `Command_Id` members after `.Move_Line_Down`, four `command_table` entries labelled `{"Extend Column Selection Left", "Edit"}` (and Right/Up/Down), and two `default_bindings` rows:

```odin
	{.Left, false, true, .Editor, .Block_Extend_Left},   // Alt+Left  (Shift read in the action)
	{.Right, false, true, .Editor, .Block_Extend_Right}, // Alt+Right
```

`Alt+Up`/`Alt+Down` keep their existing `.Move_Line_Up`/`.Move_Line_Down` bindings; those two dispatch cases branch on `ev.shift` and call `block_extend(doc, t, -1, 0)` / `(+1, 0)` when set.

For `.Block_Extend_Left`/`Right`, the action must ALSO branch on `ev.shift` — bare `Alt+Left` must keep doing nothing, as it does today. State that in a comment; a reviewer will otherwise read the binding as unconditional.

- [ ] **Step 4: Implement `block_extend`, clear the block where it must be cleared**

Add `block_extend` to `block.odin`. Then clear the block in three places, each with a comment saying why: `Clear_Selection` (Escape), `Toggle_Wrap` (the rectangle's meaning is about to change), and any existing caret move that collapses a normal selection — grep `set_cursor` and add the clear where a plain arrow key lands, so a rectangle does not survive an unrelated cursor move.

- [ ] **Step 5–7: Verify, sabotage, commit**

Run `blocktest`, `keytest`, `menutest`, `palettetest`. Sabotage: remove the `doc.wrap` refusal and confirm the wrapped case FAILS. Commit:

```bash
git commit -m "Extend a column selection with Alt+Shift+arrows"
```

---

## Task 3: The mouse gesture

**Files:**
- Modify: `src/platform/window.odin` (add `key_alt_down`), `src/program/main.odin` (the drag path at ~line 631-655)
- Test: `src/program/test_modes.odin` (`blocktest`)

**Interfaces:**
- Consumes: `plat.key_alt_down()`, `block_extend`, `doc_pos_at`, `cell_at_x`.
- Produces: `block_set_from_points :: proc(doc: ^Document, t: ^plat.Text, a_line, a_cell, c_line, c_cell: int)`.

**Context.** `window.odin` already has `key_ctrl_down` and `key_shift_down` (lines 343-349), both `GetKeyState`-based. Add `key_alt_down` on `win.VK_MENU` in the same shape — do not invent a different mechanism.

The existing drag path sets `doc.cursor = doc_pos_at(...)` while `sel_dragging`. The block path is the same gesture with Alt held: convert the press point and the current point to (line, cell) and call `block_set_from_points`. Whether Alt was held is latched **at press time**, not sampled per frame — otherwise releasing Alt mid-drag silently converts a rectangle into a linear selection.

**This is the seam.** `cell_at_x` is the same primitive the draw and the hit-test use, so the rectangle the user sees and the rectangle recorded must come from it — do not compute a column from `doc_pos_at`'s byte offset.

- [ ] **Step 1–7**

Test `block_set_from_points` normalisation headlessly (the drag itself cannot be tested — this environment cannot inject mouse input, and the report must say so plainly rather than implying the gesture was exercised). Sabotage: sample Alt per frame instead of latching at press, and assert a test that releasing Alt mid-drag preserves the block. Commit:

```bash
git commit -m "Start a column selection with Alt+drag"
```

---

## Task 4: Drawing the rectangle

**Files:**
- Modify: `src/program/main.odin` (beside the `doc_selection_rects` call at line 893), `src/program/block.odin`
- Test: `src/program/test_modes.odin` (`blocktest`)

**Interfaces:**
- Consumes from Task 1: `block_row_range`, `block_bounds`.
- Produces: `block_selection_rects :: proc(doc: ^Document, t: ^plat.Text, px, char_w: f32, rows: int, out: []plat.Quad) -> int` — same shape as `doc_selection_rects` (`doc.odin:2000`), so the call site swaps between them on `block_active`.

**Context.** Rows are already clipped to the viewport by the existing `Visible_Iter`; use it rather than walking lines. Fill colour is `g_theme[.Selection_Doc]`, the same role the linear selection uses — a rectangle is still a selection.

A zero-width rectangle must draw a **caret-width bar on every spanned row**, not nothing: that is the N-carets affordance, and with no visible cue the feature looks broken.

- [ ] **Step 1–7**

Test that the emitted quad count equals the number of visible spanned rows, that a row too short to reach `cell_lo` emits no quad, and that a zero-width rectangle emits one thin quad per row. Sabotage: emit quads for short rows and confirm the count assertion fails. Commit:

```bash
git commit -m "Draw the column selection"
```

---

## Task 5: Copy and cut

**Files:**
- Modify: `src/program/block.odin`, `src/program/commands.odin` (`.Copy`/`.Cut` dispatch)
- Test: `src/program/test_modes.odin` (`blocktest`)

**Interfaces:**
- Consumes: `block_row_range`, `base.line_ending_name`/`doc.eol`.
- Produces: `block_text :: proc(doc: ^Document, t: ^plat.Text, allocator) -> (string, bool)`.

**Context.** Rows are joined with **the document's own line ending**, not a hardcoded `\n` — `doc.eol` carries it and the save path preserves CRLF. Getting this wrong means copying from a CRLF file and pasting back produces mixed endings, which is the corruption class batch 1 already fixed once.

`.Cut` is `block_text` followed by the Task 6 delete, inside one undo batch.

- [ ] **Step 1–7**

Test CRLF and LF fixtures separately and compare the exact bytes. Sabotage: hardcode `\n` and watch the CRLF case fail. Commit:

```bash
git commit -m "Copy a column selection as rows"
```

---

## Task 6: The edits

**Files:**
- Modify: `src/program/block.odin`, `src/program/commands.odin` (text input, `.Backspace`, `.Delete_Fwd` dispatch)
- Test: `src/program/test_modes.odin` (`blocktest`)

**Interfaces:**
- Consumes: `block_row_range`, `doc_batch_begin`/`doc_batch_end` (`doc.odin:1188-1200`), `doc.pt` edit primitives.
- Produces: `block_replace :: proc(doc: ^Document, t: ^plat.Text, text: []u8) -> bool`, `block_delete :: proc(doc: ^Document, t: ^plat.Text, forward: bool) -> bool`.

**This task carries the batch's two hardest requirements. Both are stated in the spec and neither is optional:**

1. **Edits apply bottom-up, highest line first.** Editing line 10 invalidates every byte offset below it. Computing all ranges up front and applying top-down is the classic form of this bug and it corrupts silently rather than failing.
2. **The cap refuses the whole edit.** `BLOCK_EDIT_MAX_LINES :: 10_000`. A rectangle spanning more than that must leave the buffer **byte-identical** and post `[COLUMN EDIT TOO LARGE - <n> lines, limit 10000]`. A partial rectangular edit across a large file is unrecoverable-looking damage; refusing is recoverable. This is Shape A — a bounded operation must never report success for a job it only partly did.

Virtual space: a row whose `pad_cells > 0` is padded with exactly that many spaces before the inserted text, so the edit lands in the right column on every row. Padding happens **only here**, never in selection or drawing.

The whole operation is wrapped in `doc_batch_begin(doc, .Paste)` / `doc_batch_end(doc, n_lines)` so it is one undo step.

- [ ] **Step 1: Write the failing tests** — these five, all comparing **bytes**, not line counts:

1. **Prefix:** zero-width rectangle at cell 0 across 4 lines, type `// ` — every line prefixed, including a short one.
2. **Replace:** rectangle over cells [2,5) across 3 ragged lines, type `X` — exact expected buffer.
3. **One undo step:** after any of the above, a single `doc_undo` restores the original bytes exactly.
4. **Bottom-up:** a rectangle whose rows change length by different amounts produces the same bytes as applying the same per-row edits individually in reverse order.
5. **Cap refuses whole:** a rectangle over `BLOCK_EDIT_MAX_LINES + 1` lines leaves the buffer byte-identical.

- [ ] **Steps 2–6: implement, verify, sabotage**

Three sabotages, each restored: apply top-down (test 4 must corrupt); drop the batch pair (test 3 must show N undo steps); let the cap perform a partial edit (test 5's byte comparison must fail).

- [ ] **Step 7: Commit**

```bash
git commit -m "Edit across a column selection as one undo step"
```

---

## Final verification (controller, after all six tasks)

- [ ] `odin test src\base -collection:src=src`, then every headless mode: `blocktest`, `keytest`, `edittest`, `seltest`, `findtest`, `replacetest`, `wraptest`, `vnavtest`, `menutest`, `palettetest`, `sessiontest`, `themetest`, `droptest`, `highlighttest`. Grep `Select-String -CaseSensitive "FAIL"`.
- [ ] Every commit compiles:

```bash
for c in $(git rev-list --reverse main..HEAD); do d=$(mktemp -d); git archive "$c" | tar -x -C "$d"; ( cd "$d" && odin check src/program -collection:src=src >/dev/null 2>&1 ) && echo "ok   $c" || echo "FAIL $c"; done
```

Archive the whole tree — `links.odin` does `#load("../../text_exts.txt")`.

- [ ] `build.bat release` succeeds; record the exe size (v0.14.0 shipped 1.29 MB).
- [ ] **Whole-branch review on the most capable model.** Point it at: whether cells and bytes are ever confused outside `block_row_range`; whether any path can leave `block` true with stale line indices after an edit, an undo, a reload, or an external change; whether block state must be cleared on document close, tab switch, and filter mode; and whether `session.odin` should persist or discard it.
- [ ] **DO NOT MERGE.** This mutates text across many lines at once and this environment cannot inject GUI input. Wyatt's live pass comes first — see the handoff note.
