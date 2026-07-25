# Feature Batch 2 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship the four features from the 0.9.0 live-use report — Alt+arrow line move, drag-and-drop open, resizable split, per-family view memory — plus one correctness fix found while designing them.

**Architecture:** Alt+arrows need no platform work (`WM_SYSKEYDOWN` already carries Alt combos). Drag-and-drop reuses the `open_paths` queue that already exists for single-instance handoff. The split fraction and the view defaults both become `Settings` fields, which the existing `key value` settings format absorbs without migration because unknown keys are already ignored.

**Tech Stack:** Odin; Win32/D3D11/DirectWrite behind `src/platform`; `odin test` for `src/base`; headless modes in `src/program/test_modes.odin` for anything needing a `Document` or a window.

**Spec:** [docs/superpowers/specs/2026-07-25-feature-batch-2-design.md](../specs/2026-07-25-feature-batch-2-design.md)

**Branch:** `feat/live-feature-batch-2` (already created; spec already committed).

## Global Constraints

- **Layer boundaries:** `base` → `platform` → `program`. Pure logic in `base`; all Win32/COM in `platform`; platform types never leak upward. UTF-8 internally, wide chars only at the platform seam.
- **Never lock the user's file.** Share-everything opens; external change detection by timestamp polling, never a held handle.
- **Never freeze on huge files.** Uncapped document scans on the UI thread are a hard-rule violation; `pt_line_start_cap` / `pt_line_end_cap` exist for this.
- **One layout per widget.** A widget's geometry is produced by exactly one procedure, consumed by the draw *and* the hit-test *and* the hover *and* the cursor. No procedure may both compute a coordinate and consume it.
- **Main thread builds UI and handles input, nothing else.**
- **Zero-is-initialization everywhere** (Odin default — don't fight it).
- **Fight options.** Every added setting signals leakage in core design; this batch adds four and each must justify itself.
- **Build:** `build.bat` (debug, console — headless modes print there); `build.bat release` for the shipped exe. A bare `odin build` omits the DPI manifest and is wrong. Full rebuild under ~5 s.
- **Unit tests:** `odin test src\base -collection:src=src`.
- **Headless modes:** set `NEWTPAD_SESSION_DIR` to a temp dir first, or session modes write to the real store under `%APPDATA%\Newtpad`. `keytest` needs a path argument **first**; `watchtest` needs a directory. Run bare they fall through to GUI startup and hang, leaving a process that locks the exe against the next build.
- **A test that has never failed proves nothing.** Reintroduce the bug, watch the test fail, restore. Not optional.
- **Prefer a check that cannot pass with the bug present.** Compare consumers against each other, not against a constant. Assert whole-buffer bytes where the failure mode is a byte in the wrong place.
- **Git:** commits authored solely by the repo owner. **Never** add `Co-Authored-By: Claude`, "Generated with Claude Code", robot emoji, or any AI attribution. Imperative-mood subject under 65 chars; body only when the *why* isn't obvious.

---

## File Structure

**Modified:**
- `src/program/commands.odin` — `.Insert_Newline` honours `doc.eol`; two new line-move commands, their table rows and bindings; view-toggle handlers learn the family default.
- `src/program/doc.odin` — `doc_move_lines`; `doc_editor_right` reads the split fraction.
- `src/program/main.odin` — drop-path consumer gains folder skipping and first-tab focus; divider hover/drag; the transient notice in the status bar.
- `src/program/settings.odin` — four new fields, their load/save keys, and their settings-page rows.
- `src/program/app.odin` — `App.notice`; apply the family default on a fresh open.
- `src/platform/window.odin` — `DragAcceptFiles` + `WM_DROPFILES`; a `.SizeWE` cursor kind.
- `src/platform/file.odin` — `path_is_directory`.
- `src/program/test_modes.odin` — five new modes.

**No new files.** Nothing here is pure enough to earn a `base` module: line move needs a `Document`, and the rest is platform or UI.

**Task order.** Task 1 first because it is a correctness fix and Task 2's terminator logic depends on knowing what Enter writes. Task 4 before Task 5 because it establishes the settings-extension pattern the larger one follows.

---

## Task 1: Make Enter honour the document's line ending

Found while designing Task 2, not in the original report. `commands.odin:571` is `doc_insert_rune(doc, '\n')` — a bare LF regardless of `doc.eol`. So **every Enter pressed in a CRLF file writes an LF-only line**, silently mixing line endings in the file. `doc.eol` is detected once at open and never recomputed, so the status bar keeps reporting CRLF and nothing tells the user.

This is the same class as the `doc_delete_fwd` corruption batch 1 fixed, and Task 2 cannot be specified coherently without settling it: if Enter writes LF, an eol-aware line move would be inconsistent with it, and if line move writes LF it propagates the bug.

**Files:**
- Modify: `src/program/commands.odin` (the `.Insert_Newline` case)
- Modify: `src/program/doc.odin` (add `doc_insert_newline`)
- Modify: `src/program/test_modes.odin` (extend `edittest`)

**Interfaces:**
- Produces: `doc_insert_newline(doc: ^Document)` — inserts `doc.eol`'s bytes, replacing any selection exactly as `doc_insert_rune` does.

- [ ] **Step 1: Write the failing assertion**

Extend the existing `edittest` mode. Build a CRLF document, press Enter mid-line, and assert the **whole buffer's bytes**:

```odin
		// Enter must write the document's own terminator. A bare '\n' in a CRLF
		// file silently mixes line endings, and doc.eol is only detected at open,
		// so the status bar keeps saying CRLF and nothing tells the user.
		nl: Document
		nl.pt = base.pt_init(transmute([]u8)string("hello\r\nworld\r\n"))
		defer base.pt_destroy(&nl.pt)
		nl.eol = .CRLF
		nl.cursor, nl.anchor = 5, 5
		doc_insert_newline(&nl)
		got := doc_debug_string(&nl)
		want := "hello\r\n\r\nworld\r\n"
		ok := got == want
		fmt.printfln("  %-6s Enter on CRLF -> %q (want %q)", "ok" if ok else "FAIL", got, want)
```

Add the LF mirror (`nl.eol = .LF`, expecting a single `\n`) so the fix cannot be a hardcoded CRLF.

- [ ] **Step 2: Build and watch it fail**

```bash
build.bat && build\newtpad.exe some.txt edittest
```

Expected: compile error first (`doc_insert_newline` undefined). Stub it as `doc_insert_rune(doc, '\n')` and re-run: the CRLF case must print `FAIL` with `got="hello\n\r\nworld\r\n"`. That failure **is** the bug.

- [ ] **Step 3: Implement it**

In `src/program/doc.odin`, beside the other insert helpers:

```odin
// Enter. Writes the document's own terminator rather than a bare LF: on a CRLF
// file a lone '\n' mixes line endings for good, and doc.eol is detected once at
// open, so nothing downstream notices or reports it.
doc_insert_newline :: proc(doc: ^Document) {
	if doc.eol == .CRLF {
		doc_insert_text(doc, transmute([]u8)string("\r\n"))
		return
	}
	doc_insert_rune(doc, '\n')
}
```

`.Mixed` deliberately falls through to LF: the file already disagrees with itself, so there is no right answer, and LF is the harmless default `detect_line_ending` already uses.

Check `doc_insert_text`'s exact name and signature before using it (grep `doc_insert_text ::`); if the codebase's selection-replacing insert is named differently, use that one — the requirement is that it replaces a selection the same way `doc_insert_rune` does.

- [ ] **Step 4: Point the command at it**

`src/program/commands.odin`, the `.Insert_Newline` case:

```odin
	case .Insert_Newline:
		doc_insert_newline(doc)
```

- [ ] **Step 5: Verify, then check the tab sibling**

```bash
build.bat && build\newtpad.exe some.txt edittest && build\newtpad.exe crlftest && odin test src\base -collection:src=src
```

Expected: both new cases `ok`, `crlftest` still `all ok`, unit tests pass.

Then grep for other places that insert a line break with a hardcoded `'\n'` (`doc_insert_rune(doc, '\n')`, `"\n"` literals in edit paths — **not** in the renderer or the line-scanners, which correctly look for LF). Report each with a judgement: is it an edit that should honour `doc.eol`, or a scan that should not? Fix the edits; leave the scans.

- [ ] **Step 6: Re-verify it can fail, then commit**

Revert `doc_insert_newline` to a bare `'\n'`, confirm the CRLF case fails, restore.

```bash
git add src/program/doc.odin src/program/commands.odin src/program/test_modes.odin
git commit -m "Make Enter write the document's own line ending" -m "It inserted a bare LF regardless of doc.eol, so every Enter in a CRLF file
mixed the file's line endings -- and since doc.eol is only detected at open,
the status bar kept reporting CRLF and nothing surfaced it."
```

---

## Task 2: Alt+Up/Down move line(s)

**Files:**
- Modify: `src/program/commands.odin` (`Command_Id`, `command_table`, `default_bindings`, the dispatch cases)
- Modify: `src/program/doc.odin` (`doc_move_lines`)
- Modify: `src/program/test_modes.odin` (new `movelinetest`)

**Interfaces:**
- Consumes: `doc_insert_newline` and the `doc.eol`-awareness established in Task 1.
- Produces: `doc_move_lines(doc: ^Document, delta: int)` — `delta` is `-1` (up) or `+1` (down).

**No platform work.** `WM_SYSKEYDOWN` is handled alongside `WM_KEYDOWN` and explicitly carries Alt combos (`window.odin:617-618`); `alt_used` is set whenever Alt is held with another key (`:625`), so the bare-Alt menu-mode toggle cannot fire. Verified before design — do not add anything to the platform layer for this.

- [ ] **Step 1: Write the failing mode**

Add `movelinetest` to `test_modes.odin` in the path-less block beside `rowtest`. Every case asserts the **whole buffer**, because the failure mode is a terminator in the wrong place and a cursor check cannot see it:

```odin
	// `newtpad movelinetest` — Alt+Up/Down. Terminators live BETWEEN lines and the
	// last line often has none, so a naive cut-and-paste either duplicates one or
	// drops it; on a CRLF file that leaves a bare LF, the corruption batch 1 fixed
	// in doc_delete_fwd. Hence whole-buffer assertions, and the last line as an
	// explicit case rather than one the general path is assumed to cover.
	if os.args[1] == "movelinetest" {
		fail := false
		chk :: proc(label, got, want: string, fail: ^bool) {
			ok := got == want
			if !ok {fail^ = true}
			fmt.printfln("  %-6s %-34s got=%q want=%q", "ok" if ok else "FAIL", label, got, want)
		}
		one :: proc(content: string, eol: base.Line_Ending, at, delta: int) -> string {
			doc: Document
			doc.pt = base.pt_init(transmute([]u8)content)
			defer base.pt_destroy(&doc.pt)
			doc.eol = eol
			doc.cursor, doc.anchor = at, at
			doc_move_lines(&doc, delta)
			return strings.clone(doc_debug_string(&doc), context.temp_allocator)
		}
		fmt.println("movelinetest:")
		// LF, middle of the file
		chk("LF: move line 2 up", one("a\nb\nc\n", .LF, 2, -1), "b\na\nc\n", &fail)
		chk("LF: move line 1 down", one("a\nb\nc\n", .LF, 0, 1), "b\na\nc\n", &fail)
		// no-ops at the bounds: the buffer must come back byte-identical
		chk("LF: first line up is a no-op", one("a\nb\n", .LF, 0, -1), "a\nb\n", &fail)
		chk("LF: last line down is a no-op", one("a\nb\n", .LF, 2, 1), "a\nb\n", &fail)
		// the last line WITHOUT a trailing newline -- which line lacks one changes
		chk("LF: unterminated last up", one("a\nb", .LF, 2, -1), "b\na", &fail)
		chk("LF: into unterminated last", one("a\nb", .LF, 0, 1), "b\na", &fail)
		// CRLF must never yield a bare LF anywhere
		chk("CRLF: move line 2 up", one("a\r\nb\r\nc\r\n", .CRLF, 3, -1), "b\r\na\r\nc\r\n", &fail)
		chk("CRLF: unterminated last up", one("a\r\nb", .CRLF, 3, -1), "b\r\na", &fail)
		chk("CRLF: into unterminated last", one("a\r\nb", .CRLF, 0, 1), "b\r\na", &fail)
		fmt.println("movelinetest: FAILURES" if fail else "movelinetest: all ok")
		return true
	}
```

Hand-check every `at` offset against its string before trusting these expectations, and hand-check each `want`. If your derivation disagrees with a number here, use yours and show the arithmetic in your report — **never** adjust an expectation to match what the code prints.

- [ ] **Step 2: Build and watch it fail**

```bash
build.bat && build\newtpad.exe movelinetest
```

Expected: compile error (`doc_move_lines` undefined).

- [ ] **Step 3: Implement `doc_move_lines`**

In `src/program/doc.odin`, near the other line operations. Shape, not verbatim code — the terminator bookkeeping is the substance of this task and must be reasoned through, not transcribed:

- Compute the moving span as **logical** lines: `lo = pt_line_start(min(anchor, cursor))`, `hi = pt_line_end(max(anchor, cursor))`. Logical, not visual, so wrap changes nothing.
- Bail early (no edit at all, so no undo entry) when there is no neighbour. Upward that is `lo == 0`. Downward it is **not** `hi >= pt.length`: on a buffer ending with a newline, the last content line's `pt_line_end` is strictly less than `length`, so that test lets the move swap with the phantom empty final row instead of doing nothing. Test the span *including its terminator* against the buffer end — the line is last when nothing follows its own break.
- Register the two commands in `command_mutates_doc` as well. Table view is read-only (a silent CSV corruption was fixed by making it so), and a command that edits without being listed there bypasses that guard.
- Think in terms of *"line plus its following terminator"*. Moving down swaps `[lo, hi+term)` with the following line and its terminator; moving up swaps with the preceding one. When one of the two pieces is the final line and has no terminator, the swap must **synthesise** one for the piece that is no longer last and **remove** the one from the piece that now is — using `doc.eol`'s bytes, never a hardcoded `"\n"`.
- Do it as a single `doc_replace_range` over the whole affected region rather than several edits, so intermediate states never exist and offsets cannot drift mid-operation.
- Wrap in `doc_batch_begin(doc, .Replace)` / `doc_batch_end(doc, 1)` so one press is one undo entry.
- Shift `anchor` and `cursor` by the byte delta so the selection follows and the keys repeat sensibly.

- [ ] **Step 4: Register the commands**

`Command_Id` gains `Move_Line_Up`, `Move_Line_Down`. `command_table` gains:

```odin
	.Move_Line_Up             = {"Move Line Up", "Edit"},
	.Move_Line_Down           = {"Move Line Down", "Edit"},
```

`default_bindings` gains, in the editor block:

```odin
	{.Up, false, true, .Editor, .Move_Line_Up}, // Alt+Up
	{.Down, false, true, .Editor, .Move_Line_Down}, // Alt+Down
```

And the dispatch:

```odin
	case .Move_Line_Up:
		doc_move_lines(doc, -1)
	case .Move_Line_Down:
		doc_move_lines(doc, 1)
```

The `#assert` on the command table's length is what makes registration compiler-enforced — if it fires, a row is missing, not the assert being wrong.

- [ ] **Step 5: Verify**

```bash
build.bat && build\newtpad.exe movelinetest && build\newtpad.exe some.txt keytest && build\newtpad.exe crlftest && build\newtpad.exe rowtest
```

Expected: `movelinetest: all ok`; `keytest` shows Alt+Up/Down resolving to the new commands (add two `key_chk` lines for them); the others unchanged.

Also confirm in `keytest` that `Alt+Z` still resolves to `.Toggle_Wrap` — the new Alt bindings must not have disturbed the existing one.

- [ ] **Step 6: Re-verify it can fail, then commit**

Two sabotages, because two different things can be wrong:
1. Make the synthesised terminator a hardcoded `"\n"` — the three CRLF cases must fail.
2. Remove the `hi >= pt.length` bail — the "last line down is a no-op" case must fail.

Restore after each and report both outputs.

```bash
git add src/program/doc.odin src/program/commands.odin src/program/test_modes.odin
git commit -m "Move lines with Alt+Up and Alt+Down"
```

---

## Task 3: Drag-and-drop open

**Files:**
- Modify: `src/platform/window.odin` (`DragAcceptFiles`, `WM_DROPFILES`)
- Modify: `src/platform/file.odin` (`path_is_directory`)
- Modify: `src/program/app.odin` (`App.notice`, `App.notice_frames`)
- Modify: `src/program/main.odin` (the open-request consumer; draw the notice)
- Modify: `src/program/test_modes.odin` (new `droptest`)

**Interfaces:**
- Produces: `plat.path_is_directory(path: string) -> bool`
- Produces: `app_note(app: ^App, msg: string)` — a transient status-bar notice.

`core/sys/windows/shell32.odin` already declares `DragAcceptFiles` and `DragQueryFileW`. Verified before design — do **not** hand-declare them.

- [ ] **Step 1: Accept drops and queue the paths**

In `window_create`, after the window exists:

```odin
	// Explorer drag-and-drop. Dropped paths join the same queue the
	// single-instance handoff uses (WM_COPYDATA below), so there is one producer
	// contract and one consumer rather than two to keep in sync.
	win.DragAcceptFiles(w.hwnd, true)
```

Add the message case beside `WM_COPYDATA`:

```odin
	case win.WM_DROPFILES:
		hdrop := win.HDROP(uintptr(wparam))
		n := int(win.DragQueryFileW(hdrop, 0xFFFFFFFF, nil, 0))
		for i in 0 ..< n {
			if w.open_count >= OPEN_QUEUE {break} // overflow is dropped, as documented
			wbuf: [OPEN_PATH_MAX]u16
			got := win.DragQueryFileW(hdrop, u32(i), &wbuf[0], u32(len(wbuf)))
			if got == 0 {continue}
			u8buf, uok := win.wstring_to_utf8(win.wstring(&wbuf[0]), int(got), context.temp_allocator)
			if !uok || len(u8buf) == 0 || len(u8buf) > OPEN_PATH_MAX {continue}
			copy(w.open_paths[w.open_count][:], u8buf)
			w.open_lens[w.open_count] = len(u8buf)
			w.open_count += 1
		}
		win.DragFinish(hdrop)
		return 0
```

Check `wstring_to_utf8`'s actual name and signature in `core:sys/windows` before using it — the codebase already converts wide paths somewhere in `platform/file.odin`, so **follow whatever helper that uses** rather than introducing a second conversion idiom.

- [ ] **Step 2: Add the directory check**

In `src/platform/file.odin`, following the file's existing wide-path idiom:

```odin
// Whether `path` names a directory. Used by the drop handler: a dropped folder is
// skipped rather than opened, since a project tree is out of scope.
path_is_directory :: proc(path: string) -> bool
```

- [ ] **Step 3: Add the transient notice**

`App` gains:

```odin
	notice:        string, // transient status-bar message (dropped folder, etc.)
	notice_frames: int, // counts down; 0 means nothing to show
```

and in `app.odin`:

```odin
// A short-lived status-bar message. Frames rather than wall-clock: the app
// redraws at vsync, so a frame count is stable and needs no timer.
NOTICE_FRAMES :: 240

app_note :: proc(a: ^App, msg: string) {
	a.notice = strings.clone(msg) // caller's msg is often temp-allocated
	a.notice_frames = NOTICE_FRAMES
}
```

`notice` is heap-cloned each time, so free the previous one before replacing it or it leaks. Confirm how the codebase handles other cloned strings on `App` and match it.

In `render_frame`'s status-bar branch, append the notice when `notice_frames > 0` and decrement it once per frame.

- [ ] **Step 4: Extend the consumer**

`main.odin:165-174` currently opens every queued path and prints failures to stderr. It becomes: skip directories with a note, open the rest, focus the **first** successfully opened tab, and note anything that failed.

```odin
		if window.open_count > 0 {
			reqs: [plat.OPEN_QUEUE]string
			first := -1
			skipped := 0
			for p in reqs[:plat.window_open_requests(window, reqs[:])] {
				if plat.path_is_directory(p) {
					skipped += 1
					continue // a folder is not a document; project trees are out of scope
				}
				if !app_open_path(&app, p) {
					fmt.eprintfln("Newtpad: could not open %q", p)
					skipped += 1
					continue
				}
				if first < 0 {first = app.active}
			}
			if first >= 0 {app_activate(&app, first)} // focus the first, not the last
			if skipped > 0 {
				app_note(&app, fmt.tprintf("%d item%s skipped (folders and unreadable files are not opened)", skipped, "" if skipped == 1 else "s"))
			}
			plat.window_clear_open_requests(window)
			session_dirty = true
		}
```

Check `app_activate`'s real name and the field that holds the active index (grep `app_activate\|a.active`) — the names above are the intent, not verified signatures.

- [ ] **Step 5: Write the mode**

`droptest` cannot inject a drop, but the consumer is ordinary code. It creates two real temp files and a temp directory, pushes all three plus a nonexistent path through the same logic, and asserts: two tabs opened, focus on the first, the directory produced no tab, `skipped == 2`, and a notice was set. Then push one of the same paths again and assert it activates the existing tab rather than opening a second — pinning `app_open_path`'s existing behaviour rather than changing it.

Because this writes real files, it must use a temp directory and clean up after itself.

- [ ] **Step 6: Verify, sabotage, commit**

Sabotage: remove the `path_is_directory` skip and confirm `droptest` fails (a tab opens for the folder, or `app_open_path` errors and the count is wrong). Restore.

```bash
build.bat && build\newtpad.exe droptest && odin test src\base -collection:src=src
git add src/platform src/program
git commit -m "Open files dropped onto the window"
```

**Wyatt must confirm the real gesture** — an actual Explorer drag of several files, and of a folder. The mode covers the handler, not the OS plumbing.

---

## Task 4: Resizable split

**Files:**
- Modify: `src/program/settings.odin` (`split_frac` + its load/save keys + clamping)
- Modify: `src/program/doc.odin` (`doc_editor_right` reads the setting; `md_divider_rect`)
- Modify: `src/program/main.odin` (hover cursor, drag)
- Modify: `src/platform/window.odin` (a `.SizeWE` cursor kind)
- Modify: `src/program/test_modes.odin` (new `splittest`)

**Interfaces:**
- Produces: `Settings.split_frac: f32`, clamped to `[SPLIT_MIN, SPLIT_MAX]` = `[0.15, 0.85]`
- Produces: `md_divider_rect(doc: ^Document, winw, winh: f32) -> plat.Quad` — the one geometry source for the divider, consumed by draw, hover and hit-test
- Produces: `plat.Cursor_Kind.SizeWE`

- [ ] **Step 1: Move the constant into Settings**

`MD_SPLIT_FRAC :: f32(0.5)` at `doc.odin:158` becomes `Settings.split_frac`. Keep a `SPLIT_DEFAULT :: f32(0.5)` for `settings_default`, and add `SPLIT_MIN :: f32(0.15)` / `SPLIT_MAX :: f32(0.85)`.

Clamp in **three** places, because each catches a different bad input: `settings_load` (a hand-edited or corrupt file), `settings_save` (a bad in-memory value never reaches disk), and the drag itself.

`doc_editor_right` reads it. Note it is already the single source that the wrap width, the editor's scrollbar and the editor's click region derive from — so this is one change, not four. Do not add a second place that computes the split x.

`settings_load`/`settings_save` gain a `split_frac` key. The format is `key value` lines and unknown keys are already ignored, so no migration.

- [ ] **Step 2: One geometry procedure**

```odin
// The draggable divider between the editor and the preview. Produced here and
// consumed by the draw, the hover cursor and the drag hit-test -- one layout per
// widget, so what is drawn is exactly what is grabbable.
MD_DIVIDER_W :: 6 // logical px; the visible line is thinner than the grab band

md_divider_rect :: proc(doc: ^Document, winw, winh: f32) -> plat.Quad
```

Return a zero-size quad when the document is not in Split, so callers need no second condition.

- [ ] **Step 3: Add the cursor kind**

`Cursor_Kind` gains `.SizeWE`; `window_create` loads `IDC_SIZEWE` into `w.cursors[.SizeWE]` beside the existing three.

- [ ] **Step 4: Hover and drag**

In `main.odin`'s mouse handling: when the pointer is inside `md_divider_rect`, `window_set_cursor(window, .SizeWE)`. On press inside it, start a divider drag (a new `bool` beside the existing `sel_dragging`); on move while dragging, set `settings.split_frac = clamp(mx / winw, SPLIT_MIN, SPLIT_MAX)`; on release, `settings_save`.

**Save on release only.** Saving per `WM_MOUSEMOVE` is hundreds of file writes per drag.

The divider drag must be checked **before** the text-selection drag, or a press on the divider starts selecting text instead.

- [ ] **Step 5: Write the mode**

`splittest` asserts:
- `md_divider_rect`'s x and `doc_editor_right` agree — at a 1 px window, a very wide window, and a normal one. Compare the two consumers against each other, not against a constant.
- a simulated drag to 0.01 and to 0.99 clamps to `SPLIT_MIN` / `SPLIT_MAX` and never inverts the panes.
- `doc_view_cols` (wrap columns) and the editor scrollbar x both change when the fraction changes — proving nothing still reads a hardcoded half.
- `settings_load` clamps an out-of-range `split_frac` from a file rather than trusting it.

- [ ] **Step 6: Verify, sabotage, commit**

Sabotage: make `md_divider_rect` compute its x independently (e.g. `winw * 0.5`) instead of from `doc_editor_right`, and confirm the agreement assertions fail at non-default fractions. Restore. This is the one-layout rule under test.

```bash
build.bat && build\newtpad.exe splittest && build\newtpad.exe mdtabletest && build\newtpad.exe crlftest
git add src/platform src/program
git commit -m "Make the markdown split divider draggable"
```

---

## Task 5: View memory per file family

**Files:**
- Modify: `src/program/settings.odin` (three fields, keys, rows, toggle handling)
- Modify: `src/program/commands.odin` (view toggles learn the default)
- Modify: `src/program/app.odin` (apply on a fresh open)
- Modify: `src/program/test_modes.odin` (new `viewmemtest`)

**Interfaces:**
- Consumes: the settings load/save/clamp pattern from Task 4.
- Produces: `Settings.md_default: Md_Mode`, `Settings.table_default: bool`, `Settings.remember_views: bool`
- Produces: `app_apply_view_defaults(a: ^App, doc: ^Document)` — called on a fresh open only.

- [ ] **Step 1: Add the fields and their persistence**

Three fields on `Settings`, defaults `.Off` / `false` / `true` (remembering is on by default — it is what Wyatt asked for; the toggle exists to pin a default, not to opt in).

`settings_load` gains the three keys, and **`md_default` must be range-checked** the way `link_style` and `font_style` already are:

```odin
		case "md_default":
			if n, pok := strconv.parse_int(parts[1]); pok && n >= 0 && n <= int(max(Md_Mode)) {
				s.md_default = Md_Mode(n)
			}
```

An out-of-range value degrades to the default rather than producing an invalid enum.

- [ ] **Step 2: Learn on toggle**

In the view-toggle command handlers in `commands.odin` (the `.Toggle_Table` and markdown-mode cases — grep `md_mode = ` for the exact sites, `commands.odin:686-691`), after the mode changes:

```odin
			// Learn the family default so the next file of this type opens the same
			// way. Gated on remember_views: with it off the Settings value is a pin,
			// not a running average of what you last did.
			if app.settings.remember_views {
				if doc_is_markdownish(doc) {
					app.settings.md_default = doc.md_mode
					settings_save(app.settings)
				}
			}
```

and the tabular mirror. Note this writes `settings.txt` on every view toggle — acceptable (it is a keystroke, not a mouse-move), but do not also save on every frame.

- [ ] **Step 3: Apply on a fresh open**

```odin
// Apply the remembered per-family view to a newly opened document. Fresh opens
// only: session restore carries its own per-tab view state, and overriding that
// would silently change a view the user had deliberately left set. The existing
// doc_can_* gating still applies, so a stored default can never force a view onto
// a file that cannot hold it.
app_apply_view_defaults :: proc(a: ^App, doc: ^Document) {
	if doc == nil || doc.kind != .Text {return}
	if a.settings.md_default != .Off && doc_can_markdown(doc) {doc.md_mode = a.settings.md_default}
	if a.settings.table_default && doc_can_table(doc) {doc.table = true}
}
```

Call it from the fresh-open path only. **Find where session restore opens documents and confirm it does not route through the same call** — if both share one function, the restore path needs an explicit opt-out parameter, and that is the single most likely way this task goes wrong.

- [ ] **Step 4: Settings page rows**

`SETTINGS_ROWS` gains three entries and `settings_draw`'s value `switch i` gains their cases. Note that switch is index-based against a parallel array — append rather than inserting, or every existing row's value shifts to the wrong label.

- [ ] **Step 5: Write the mode**

`viewmemtest` asserts:
- a fresh `.md` open with `md_default = .Split` comes up in Split; a `.csv` with `table_default` comes up in Table;
- a `.txt` is unaffected by `md_default` (the gating holds);
- toggling a view with `remember_views = true` updates the setting; with `false` it does not;
- a session-restored tab keeps its own stored view even when the family default differs — **this is the assertion that protects the rule most likely to be broken**;
- `settings_load` degrades an out-of-range `md_default` to `.Off`.

**Set `NEWTPAD_SESSION_DIR` and point the settings path at a temp location** before running, or this writes Wyatt's real settings and session.

- [ ] **Step 6: Verify, sabotage, commit**

Sabotage: call `app_apply_view_defaults` from the session-restore path too, and confirm the restore assertion fails. Restore. That is the rule with the worst failure mode — silently changing views on tabs the user had set deliberately.

```bash
build.bat && build\newtpad.exe viewmemtest && build\newtpad.exe sessiontest
git add src/program
git commit -m "Remember the last view used per file type"
```

---

## Final verification

- [ ] `odin test src\base -collection:src=src` — all green.
- [ ] Every headless mode, with `NEWTPAD_SESSION_DIR` set: the five new ones plus `rowtest crlftest revtest stickytest mdtabletest wraptest wraplongtest vnavtest hscrolltest seltest edittest sessiontest`, and `keytest`/`watchtest` with their required arguments.
- [ ] `build.bat release` — clean, under ~5 s.
- [ ] Bump `src/program/version.odin`.
- [ ] Update `HANDOFF.md` with a §6t entry: the four features, the Enter/`doc.eol` fix and why it was in scope, the deferred items, and any new debt.
- [ ] **Run `install.ps1`** so Wyatt's daily driver is the new build — standing instruction. Check `Get-Process newtpad` first and do **not** use `-Force` if it is running; a hard kill can skip the hot-exit session write.
- [ ] **Wyatt's live pass:** Alt+arrow with real auto-repeat; an Explorer drag of several files and of a folder; dragging the divider and confirming it survives a restart; opening a `.md` after leaving the previous one in Split.

## Out of scope

Rebindable keys; a duplicate-line command (offered and declined); per-family split fractions; opening a folder's contents; and the project-wide forgotten-feature audit, which follows this batch as a written report.
