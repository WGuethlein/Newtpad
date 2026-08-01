# Preview paragraph join — implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development` to
> implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the markdown preview use CommonMark's paragraph model — consecutive prose lines join
into one re-flowed paragraph — plus lazy continuation for lists/quotes and setext headings.

**Architecture:** One new bounds function, `md_para_bounds`, modelled directly on the existing
`md_table_bounds`, becomes the single producer of a paragraph's start and end. `md_layout_build`'s
`.Para` case uses it to absorb the run and hand the joined text to the existing span/shape path
through `e.cls.content`. Nothing downstream changes: spans, wrapping, span boxes, links, admit and
height all already handle a block that occupies many visual lines.

**Tech stack:** Odin `dev-2026-07a`, `build.bat` (debug, console subsystem), headless test modes in
`src/program/test_modes.odin`, `odin test src\base` for pure logic.

**Spec:** [2026-08-01-preview-paragraph-join-design.md](../specs/2026-08-01-preview-paragraph-join-design.md)

## Global constraints

- **Every commit is authored solely by Wyatt Guethlein.** Never `Co-Authored-By: Claude`, never
  "Generated with Claude Code", never a robot emoji, never any other AI attribution — in commits,
  merges, tags or PR bodies. This applies to every subagent.
- **Branch:** `fix/preview-paragraph-join`, already created, spec already committed.
- **Build:** `build.bat` only. A bare `odin build` omits the DPI manifest and the SEH shim.
  `build.bat` prints a harmless `'vswhere.exe' is not recognized` line — that is **not** a failure.
- **Always set `NEWTPAD_SESSION_DIR` to a temp dir before running any test mode.**
- **A test that has never failed proves nothing.** Every task below names its sabotage. Run it, watch
  the test fail, **paste the actual failure output into the task report**, then restore. "I verified
  it fails" without the output is not evidence.
- **Check the build's exit code before believing a green test run.** A sabotage that fails to compile
  leaves the stale exe in place, which prints `0 failures` and looks like a sabotage that broke
  nothing.
- **Comments must not claim evidence they do not have.** Batch 19 shipped eleven that did — a
  measured-sounding number that was never measured, a procedure named that does not exist, an API
  behaviour stated wrongly. If a comment asserts a number, an API's behaviour, or another
  procedure's name, verify it or do not write it.
- **Never use `Set-Content -Encoding UTF8`** (adds a BOM, has corrupted source here). Use Write/Edit.
- **Check `git diff --stat` before committing** and confirm the line count matches what you changed —
  the Write/Edit tools have silently rewritten whole files CRLF→LF twice.
- Use `git commit -F <file>` for multi-line messages; PowerShell 5.1 re-parses quotes passed to
  native commands and breaks `-m`.
- The preview is **read-only**. No task here may touch a write path, the piece tree, or `doc_save`.

## File structure

| File | Responsibility | Tasks |
|---|---|---|
| `src/program/markdown.odin` | all of it: constants, `md_para_bounds`, `md_classify`, `md_layout_build`, `md_layout_extern_dep`, `Md_Layout` | 1–5 |
| `src/program/test_modes.odin` | the new `mdjointest` mode | 1–6 |
| `HANDOFF.md`, `docs/development-loop.md`, `docs/reported-bugs.md`, `docs/features.md`, `src/program/version.odin` | landing | 7 |

---

## Task 1: `md_para_bounds` and the `mdjointest` harness

**Files:**
- Modify: `src/program/markdown.odin` — add constants beside the table ones (~line 576), add
  `md_para_bounds` after `md_table_bounds` (which ends at line 757)
- Modify: `src/program/test_modes.odin` — new mode

**Interfaces:**
- Produces: `md_para_bounds :: proc(doc: ^Document, p: int) -> (start, end: int, capped: bool, ok: bool)`
  — `ok` is false when the line at `p` is not a `.Para` line. `start`/`end` use `pt_line_end_cap`
  semantics (`end` is the offset of the last line's newline), matching `md_table_bounds`.
- Produces: `md_para_budget`, `md_para_max_lines` — runtime copies the test lowers.
- Produces: `mdjointest` test mode, one argument, exits non-zero.

**Why this task is first and alone:** the bounds function is the only part of this design that can be
wrong in a way no rendered pixel reveals. `md_table_bounds`' comments record three traps that each
shipped once, and all three are entry-dependence bugs — the same block giving different answers
depending on where the viewport happened to land. Task 1 exists to make that testable before anything
consumes it.

- [ ] **Step 1: Add the constants**

In `src/program/markdown.odin`, immediately after the `md_table_max_rows` declaration (line 581):

```odin
// A paragraph's join budget, in bytes, and its line-count analogue. Mirrors
// MD_TABLE_BUDGET/MD_TABLE_MAX_ROWS and exists for the same reason: joining
// stops at the first blank or non-Para line, so a file with no blank line in it
// would otherwise be walked to EOF on the UI thread by the first block.
//
// 256 KB rather than the table's 1 MB because a paragraph is prose: at ~100
// columns a 256 KB run is ~2,600 source lines, which no document has, while a
// CSV that is one enormous table is an ordinary file.
MD_PARA_BUDGET :: 256 * 1024
MD_PARA_MAX_LINES :: 4096

// Required by the forward scan's guard, exactly as MD_TABLE_BUDGET's own assert
// requires: without it the first check could trip on the entry line's length
// alone, before a single neighbour line is examined, collapsing every paragraph
// to one line and making the whole join invisible.
#assert(MD_PARA_BUDGET > RENDER_LINE_CAP)

// Runtime copies, mirroring md_table_budget/md_table_max_rows: production code
// never changes them; mdjointest lowers them to drive the truncation path on a
// small fixture instead of building a 256 KB one.
md_para_budget := MD_PARA_BUDGET
md_para_max_lines := MD_PARA_MAX_LINES
```

- [ ] **Step 2: Add a Para-line predicate**

`md_classify` is the single answer to "what kind is this line", and the join must not grow a second
one. Add directly above `md_para_bounds`:

```odin
// Is this line a paragraph line -- the thing a join may absorb?
//
// Asks md_classify rather than testing anything itself, so there is exactly one
// definition of what a paragraph line is. Everything that already terminates a
// paragraph (blank, fence, rule, heading, quote, list, table row) keeps
// terminating it for free, because md_classify tests all of them ahead of the
// .Para fallthrough.
//
// `in_fence` is threaded through because inside a fence EVERY line is
// .Fence_Body, so a join must never cross a fence -- and the caller knows the
// fence state, this does not.
@(private = "file")
md_is_para_line :: proc(line: string, in_fence: bool) -> bool {
	if in_fence {return false}
	trimmed := strings.trim_left(line, " \t")
	return md_classify(line, trimmed, false).kind == .Para
}
```

- [ ] **Step 3: Write `md_para_bounds`**

Add after `md_table_bounds` ends (line 757). **Read `md_table_bounds` first** — this is its structure
with the row tests swapped for `md_is_para_line`, and its three trap comments apply here unchanged.

```odin
// The contiguous run of paragraph lines containing `p`. Scans backward to the
// run's true start and forward to its end, both bounded by md_para_budget.
//
// THE SINGLE PRODUCER of a paragraph's extent. It exists because a joined
// paragraph STARTS ABOVE ITS OWN LINE, which makes it the second construct with
// that property (a collapsed blank run and front matter are the others) -- and
// unlike those it occurs in every document. Two procedures ask where the block
// containing byte B starts: md_layout_build walking forward, and
// md_block_at_byte running MD_RUNUP_LINES back and walking forward. A fixed
// line run-up cannot answer that for a construct of unbounded length; see
// MD_RUNUP_LINES' own comment, which already records this failure for front
// matter and is honest that it is unproven.
//
// The three traps are md_table_bounds', in the same order, and each shipped once:
//   1. Both bounds measured from the ENTRY POINT `p`, never from the moving
//      `start`. `start - q` is invariantly 0 if written the other way, so the
//      guard is dead code and the backward walk runs to byte 0 on the UI thread.
//   2. The forward guard measured from `p` too, or it is already past budget the
//      moment the backward walk moved `start`, and every paragraph collapses to
//      its entry line.
//   3. `capped` derived ONCE, after both scans, from the window they produced --
//      never "did a guard fire while scanning". Which guard fires depends on
//      where within the run the entry landed, so an entry-dependent flag gives
//      one paragraph three different answers depending on scroll position.
@(private = "file")
md_para_bounds :: proc(doc: ^Document, p: int) -> (start, end: int, capped, ok: bool) {
	buf: [RENDER_LINE_CAP]u8
	line, lend, entry_capped := md_line_at(doc, p, buf[:])
	if !md_is_para_line(line, false) {return 0, 0, false, false}
	start, end = p, lend

	// A `p` that is not a real line start cannot establish the run's start, so
	// `start = p` above is not trustworthy and the block is forced capped even if
	// both scans complete within budget. markdown_draw walks a line longer than
	// RENDER_LINE_CAP in capped segments, and doc.top can land mid-line.
	entry_line_start, entry_line_start_exact := base.pt_line_start_cap(&doc.pt, p, RENDER_LINE_CAP)
	entry_is_line_start := entry_line_start_exact && entry_line_start == p

	trunc_back, trunc_fwd := !entry_is_line_start, entry_capped
	q := p
	back_lines := 0
	for q > 0 {
		if p - q > md_para_budget {trunc_back = true;break}
		ps, exact := base.pt_line_start_cap(&doc.pt, q - 1, RENDER_LINE_CAP)
		if !exact {trunc_back = true;break}
		pl, _, pl_capped := md_line_at(doc, ps, buf[:])
		if !md_is_para_line(pl, false) {break}
		if pl_capped {trunc_back = true}
		back_lines += 1
		start = ps
		q = ps
		if back_lines > md_para_max_lines {trunc_back = true;break}
	}

	r := lend
	fwd_lines := 0
	for r < doc.pt.length {
		if r - p > md_para_budget {trunc_fwd = true;break}
		ns := r + 1
		if ns > doc.pt.length {break}
		nl, ne, ne_capped := md_line_at(doc, ns, buf[:])
		if !md_is_para_line(nl, false) {break}
		if ne_capped {trunc_fwd = true}
		fwd_lines += 1
		end = ne
		r = ne
		if fwd_lines > md_para_max_lines {trunc_fwd = true;break}
	}

	// The line-count analogue of trap 3: if neither direction's cap tripped, both
	// scans reached the run's true edges, so back+fwd+1 IS the run's real line
	// count and must be checked too. Without it a 6000-line run with a 4096 cap
	// reports capped when entered near either edge and NOT when entered near the
	// middle -- the identical flip, one level down.
	total_lines := back_lines + fwd_lines + 1
	capped = trunc_back || trunc_fwd || (end - start) > md_para_budget || total_lines > md_para_max_lines
	return start, end, capped, true
}
```

- [ ] **Step 4: Write the failing test — entry independence**

In `src/program/test_modes.odin`, add near the other `*_test_run` procedures. This is the highest-value
case in the batch: it is the one that catches all three traps.

```odin
@(private = "file")
pj_doc :: proc(src: string) -> Document {
	c := make([]u8, len(src))
	copy(c, transmute([]u8)src)
	return doc_from_content(c, "fixture.md", .UTF8)
}

// Every line offset in `d`, in order.
@(private = "file")
pj_line_starts :: proc(d: ^Document, allocator := context.allocator) -> []int {
	out := make([dynamic]int, 0, 16, allocator)
	append(&out, 0)
	for i in 0 ..< d.pt.length {
		b: [1]u8
		base.pt_read(&d.pt, i, b[:])
		if b[0] == '\n' && i + 1 <= d.pt.length {append(&out, i + 1)}
	}
	return out[:]
}

@(private = "file")
pj_case_entry_independent :: proc(bad: ^int) {
	fmt.println("-- md_para_bounds gives one answer per paragraph, whatever byte you enter at --")
	// Three paragraphs of three lines each, blank-separated. Every line of the
	// middle paragraph must produce the SAME bounds.
	d := pj_doc("a1\na2\na3\n\nb1\nb2\nb3\n\nc1\nc2\nc3\n")
	defer doc_close(&d)
	starts := pj_line_starts(&d)
	defer delete(starts)
	// Lines 4,5,6 (0-based) are b1,b2,b3.
	want_start, want_end, want_capped, want_ok := md_para_bounds_for_test(&d, starts[4])
	li_chk(bad, want_ok, "the paragraph's first line resolves")
	li_chk(bad, !want_capped, "and is not capped")
	for li in 4 ..= 6 {
		s, e, c, o := md_para_bounds_for_test(&d, starts[li])
		li_chk(
			bad,
			o && s == want_start && e == want_end && c == want_capped,
			fmt.tprintf("entering at line %d gives (%d,%d,%v); line 4 gave (%d,%d,%v)", li, s, e, c, want_start, want_end, want_capped),
		)
	}
	// And it must not have swallowed a neighbour.
	li_chk(bad, want_start == starts[4], fmt.tprintf("the run starts at b1 (%d, want %d)", want_start, starts[4]))
	li_chk(bad, want_end == starts[7] - 1, fmt.tprintf("the run ends at b3's newline (%d, want %d)", want_end, starts[7] - 1))
}
```

`md_para_bounds` is `@(private = "file")`, so add a package-visible shim next to it in
`markdown.odin` — the same reason `md_table_measure` is package-visible for `mdtabletest`:

```odin
// Package-visible so mdjointest can drive the bounds function directly. The
// production callers all go through md_layout_build.
md_para_bounds_for_test :: proc(doc: ^Document, p: int) -> (start, end: int, capped, ok: bool) {
	return md_para_bounds(doc, p)
}
```

- [ ] **Step 5: Add the truncation case — the only thing that tests `capped`**

```odin
@(private = "file")
pj_case_budget_truncates :: proc(bad: ^int) {
	fmt.println("-- the budget truncates instead of scanning to EOF --")
	// 40 paragraph lines, no blank line anywhere: without a budget this is one
	// 40-line run. Lower the budget so a small fixture drives the real guard --
	// this drive-through is what actually tests truncation. Asserting `capped` on
	// a fixture that never reaches the guard would pass with the guard deleted.
	sb := strings.builder_make()
	defer strings.builder_destroy(&sb)
	for i in 0 ..< 40 {fmt.sbprintf(&sb, "line %d of one very long unbroken paragraph\n", i)}
	d := pj_doc(strings.to_string(sb))
	defer doc_close(&d)

	_, _, capped_full, _ := md_para_bounds_for_test(&d, 0)
	li_chk(bad, !capped_full, "at the production budget the run is not capped")

	old_budget, old_lines := md_para_budget, md_para_max_lines
	defer {md_para_budget, md_para_max_lines = old_budget, old_lines}
	md_para_budget = 64
	_, _, capped_small, _ := md_para_bounds_for_test(&d, 0)
	li_chk(bad, capped_small, "with a 64-byte budget the same run reports capped")

	md_para_budget = old_budget
	md_para_max_lines = 4
	_, _, capped_lines, _ := md_para_bounds_for_test(&d, 0)
	li_chk(bad, capped_lines, "with a 4-line cap the same run reports capped")
}
```

- [ ] **Step 6: Add the non-Para and boundary cases**

```odin
@(private = "file")
pj_case_terminators :: proc(bad: ^int) {
	fmt.println("-- everything that already ended a paragraph still ends it --")
	cases := []struct{src, label: string}{
		{"p1\np2\n\ntail\n", "a blank line"},
		{"p1\np2\n# head\n", "a heading"},
		{"p1\np2\n- item\n", "a list item"},
		{"p1\np2\n> quote\n", "a blockquote"},
		{"p1\np2\n```\n", "a fence"},
		{"p1\np2\n| a | b |\n", "a table row"},
	}
	for c in cases {
		d := pj_doc(c.src)
		defer doc_close(&d)
		s, e, _, ok := md_para_bounds_for_test(&d, 0)
		// "p1\np2\n" -- the run is bytes 0..5, ending at p2's newline (offset 5).
		li_chk(bad, ok && s == 0 && e == 5, fmt.tprintf("%s ends the run (got %d..%d)", c.label, s, e))
	}
	// A line that is not a paragraph line at all returns ok=false.
	dh := pj_doc("# heading\nbody\n")
	defer doc_close(&dh)
	_, _, _, ok_head := md_para_bounds_for_test(&dh, 0)
	li_chk(bad, !ok_head, "a heading line is not a paragraph run")
}
```

- [ ] **Step 7: Wire up the mode**

Add the runner near `table_sort_test_run`:

```odin
@(private = "file")
para_join_test_run :: proc() {
	bad := 0
	if !require_scratch_session("mdjointest") {
		// Counted as a FAILURE rather than skipped: a mode that quietly does
		// nothing when an environment variable is unset is a mode nothing runs.
		li_chk(&bad, false, "NEWTPAD_SESSION_DIR is set, so the mode could run")
	} else {
		pj_case_entry_independent(&bad)
		pj_case_budget_truncates(&bad)
		pj_case_terminators(&bad)
	}
	fmt.printfln("mdjointest: %d failures", bad)
	if bad > 0 {os.exit(1)}
}
```

And the dispatch, beside the other one-argument modes (`test_modes.odin:32245`):

```odin
// `newtpad mdjointest` -- one-argument, no path, sweepable. The preview's
// paragraph join: md_para_bounds, the joined text, hard breaks, lazy
// continuation and setext.
if os.args[1] == "mdjointest" {
	para_join_test_run()
	return true
}
```

- [ ] **Step 8: Build and run**

```bash
build.bat
```

Expected: compiles. A `'vswhere.exe' is not recognized` line is normal. **Check the exit code.**

```bash
set NEWTPAD_SESSION_DIR=%TEMP%\npjoin && build\newtpad.exe mdjointest
```

Expected: every line `ok`, final line `mdjointest: 0 failures`, exit code 0.

- [ ] **Step 9: SABOTAGE — prove the entry-independence case can fail**

Change the forward guard in `md_para_bounds` from `if r - p > md_para_budget` to
`if r - start > md_para_budget` (trap 2), and set `md_para_budget = 32` in
`pj_case_entry_independent` before the loop. Rebuild, rerun.

Expected: `FAIL` lines showing different bounds from different entry lines, and `os.exit(1)`.
**Paste the actual output into the report.** Then restore both.

- [ ] **Step 10: SABOTAGE — prove the truncation case can fail**

Delete the `if p - q > md_para_budget {trunc_back = true;break}` line. Rebuild, rerun.
Expected: the 64-byte-budget assertion fails. Paste the output. Restore.

- [ ] **Step 11: Commit**

```bash
git add src/program/markdown.odin src/program/test_modes.odin
git commit -F commit-msg.txt
```

Message: `Give a paragraph one producer of its bounds`

---

## Task 2: Join the run into one block

**Files:**
- Modify: `src/program/markdown.odin` — `Md_Layout` (line 2261), `md_layout_extern_dep` (line 2314),
  `md_layout_free` (line 2319), `md_layout_ensure` (line 2808), `md_layout_build`'s `.Para` case
  (line 2587)
- Modify: `src/program/test_modes.odin`

**Interfaces:**
- Consumes: `md_para_bounds` from Task 1.
- Produces: `Md_Layout.joined: string` (OWNED, freed by `md_layout_free`) and
  `Md_Layout.multiline: bool`. Tasks 3–5 set both through the same path.
- Produces: `md_layout_extern_dep :: proc(e: ^Md_Layout) -> bool` — **signature changed**, it now
  takes the layout, not the kind.

**The two things this task exists to get right**, both invisible until measured:

1. **`md_layout_ensure`'s cache key compares `e.end != line_end`** (line 2810), where `line_end` is
   the *first* line's end. A joined block's `end` is the paragraph's end, so every lookup would miss
   and every block would rebuild every frame. `.Blank`, `.Table` and `.Front_Matter` dodge this by
   being `md_layout_extern_dep` kinds, keyed on `doc.revision` instead.
2. **Kind alone is not enough.** Task 5 promotes a joined paragraph to `.Heading`, which is not an
   extern-dep *kind* but is absolutely an extern-dep *block*. So the flag goes on the layout:
   **any block that read bytes past its own first line is extern-dep**, which is true by construction.

- [ ] **Step 1: Add the fields**

In `Md_Layout`, after `cls` (line 2278):

```odin
	// OWNED, .Para-family only: the joined text of a multi-line block, which
	// `cls.content` then slices. A single-line block leaves this nil and
	// `cls.content` slices `src` as it always did.
	joined:      string,
	// Did this block read bytes past its own first line? Set by every construct
	// that joins (a paragraph run, a list/quote continuation, a setext underline).
	// THIS, not the kind, is what makes a block externally dependent: a setext
	// heading is a .Heading whose layout depends on the line below it, so a
	// kind-based test would cache it against text that cannot witness the change.
	multiline:   bool,
```

- [ ] **Step 2: Change `md_layout_extern_dep` and its caller**

Replace lines 2314-2317:

```odin
// Does this block's layout depend on bytes outside its own `src`? Those take
// doc.revision as part of their key, since their own text cannot witness the
// change. See MD_LAYOUT_SLOTS.
//
// Takes the LAYOUT, not the kind: `multiline` is set by any block that absorbed
// lines below its first, and a setext heading is a .Heading that did exactly
// that -- so the kind is no longer sufficient to answer this.
@(private = "file")
md_layout_extern_dep :: #force_inline proc(e: ^Md_Layout) -> bool {
	return e.cls.kind == .Table || e.cls.kind == .Blank || e.cls.kind == .Front_Matter || e.multiline
}
```

At line 2808 in `md_layout_ensure`, change `md_layout_extern_dep(e.cls.kind)` to
`md_layout_extern_dep(&e)`.

- [ ] **Step 3: Free the new allocation**

In `md_layout_free`, after `delete(e.src)`:

```odin
	delete(e.joined)
```

`e.joined` is nil for every single-line block and `delete` of a nil string is a no-op, so this needs
no guard — the same way `delete(e.src)` handles an empty line today.

- [ ] **Step 4: Write the failing test**

```odin
@(private = "file")
pj_case_joins_text :: proc(bad: ^int) {
	fmt.println("-- two prose lines become one paragraph, with a space at the join --")
	h: Headless_Gpu
	if !headless_gpu_init(&h, 800, 600, "mdjointest") {
		li_chk(bad, false, "an offscreen device came up, so a layout could be built")
		return
	}
	defer headless_gpu_destroy(&h)
	m := md_metrics(&h.text, 16)

	d := pj_doc("alpha\nbeta\ngamma\n")
	defer doc_close(&d)
	lay := md_layout_build_for_test(&h.gfx, &h.text, &d, &m, 0, 600)
	defer md_layout_free(&lay)
	li_chk(bad, lay.cls.content == "alpha beta gamma", fmt.tprintf("content is %q (want \"alpha beta gamma\")", lay.cls.content))
	li_chk(bad, lay.multiline, "the block is marked multiline")
	li_chk(bad, lay.next == 17, fmt.tprintf("next is %d (want 17, past gamma's newline)", lay.next))

	// The control: a blank line still separates, and a single-line paragraph is
	// not marked multiline and does not allocate `joined`.
	d2 := pj_doc("a\n\nb\n")
	defer doc_close(&d2)
	lay2 := md_layout_build_for_test(&h.gfx, &h.text, &d2, &m, 0, 600)
	defer md_layout_free(&lay2)
	li_chk(bad, lay2.cls.content == "a", fmt.tprintf("a blank line still separates (content %q, want \"a\")", lay2.cls.content))
	li_chk(bad, !lay2.multiline, "a single-line paragraph is not multiline")
}
```

**One `Document` and one `Md_Layout` live at a time per local proc**, per development-loop §6's
stack-overflow rule — `test_mode_dispatch` already has a large frame and `blocktest` has hit a real
`STATUS_STACK_OVERFLOW` twice this way.

**Check `md_metrics`' actual signature before using it** (`markdown.odin:1175`) — it is
`md_metrics :: proc(t: ^plat.Text, s: f32) -> (m: Md_Metrics)`, and `Headless_Gpu`'s field names must
be read from its declaration rather than assumed.

**Write this against the real layout**, not against a re-derived string: build a `Md_Metrics` and call
the package-visible shim added here:

```odin
// Package-visible so mdjointest can assert on a built layout without a window.
md_layout_build_for_test :: proc(gfx: ^plat.Gfx, t: ^plat.Text, doc: ^Document, m: ^Md_Metrics, p: int, measure: f32) -> Md_Layout {
	buf: [RENDER_LINE_CAP]u8
	line, lend, _ := md_line_at(doc, p, buf[:])
	return md_layout_build(gfx, t, doc, m, p, lend, line, false, nil, {}, measure)
}
```

Assertions:
- `lay.cls.content == "alpha beta gamma"` for `"alpha\nbeta\ngamma\n"` — **the joined string itself,
  not the block count.** A block-count assertion passes with the space omitted.
- `lay.next` is past gamma's newline.
- `lay.multiline == true`.
- For `"a\n\nb\n"`, the block at 0 has `content == "a"` and `multiline == false`.

- [ ] **Step 5: Run it and watch it fail**

Expected: FAIL, `content` is `"alpha"` — the join does not exist yet. Paste the output.

- [ ] **Step 6: Implement the join**

Replace `md_layout_build`'s `.Para` case (line 2587-2588):

```odin
	case .Para:
		e.below = m.para_below
		// Join the run. CommonMark's paragraph model: consecutive prose lines are
		// ONE paragraph, re-flowed to the pane, with a space at each break -- which
		// is also the fix for "the preview does not always respect spaces", since
		// the space at the join is the one that was missing (there was no join).
		//
		// Bounds come from md_para_bounds and from nowhere else; see its comment
		// for why a second producer here would be entry-dependent.
		if ps, pe, _, pok := md_para_bounds(doc, p); pok && pe > line_end {
			sb := strings.builder_make(context.temp_allocator)
			q := ps
			buf: [RENDER_LINE_CAP]u8
			for q <= pe {
				l, le, _ := md_line_at(doc, q, buf[:])
				if strings.builder_len(&sb) > 0 {strings.write_byte(&sb, ' ')}
				strings.write_string(&sb, strings.trim_right(l, " \t"))
				q = le + 1
			}
			e.joined = strings.clone(strings.to_string(sb))
			e.cls.content = e.joined
			e.end, e.next = pe, pe + 1
			e.multiline = true
		}
```

**`e.cls.content` must point at `e.joined`, not at the builder** — the builder is on the temp
allocator and `free_all(context.temp_allocator)` runs once per frame, while a layout survives into
the next frame's draw. That is the same lifetime rule `menu_open_ctx`'s comment spells out for
`ctx_items`.

- [ ] **Step 7: Run the test**

Expected: PASS, `mdjointest: 0 failures`.

- [ ] **Step 8: Prove the cache does not thrash**

`md_layout_builds` is a package-level counter kept for exactly this ("a correct cache and no cache at
all return the same glyphs, so the only honest way to assert it is to count the builds"). Add:

```odin
@(private = "file")
pj_case_cache_holds :: proc(bad: ^int) {
	fmt.println("-- a joined block is not rebuilt every frame --")
	// Build the same block twice at the same width and revision. Without .Para
	// being extern-dep, md_layout_ensure's `e.end != line_end` test misses every
	// time and the second call rebuilds.
	// Assert: md_layout_builds increments by 1 across two md_layout_ensure calls.
}
```

This must go through `md_layout_ensure`, **not** `md_layout_build` — the cache is what is under test.
Add a package-visible shim for `md_layout_ensure` in the same style as Step 4's.

- [ ] **Step 9: SABOTAGE — prove Step 8 can fail**

Revert `md_layout_extern_dep` to the kind-only form. Rebuild, rerun. Expected: the build count is 2,
not 1, and the case FAILs. **This is the assertion that catches the whole-cache-miss regression, so
its failure output matters most.** Paste it. Restore.

- [ ] **Step 10: SABOTAGE — prove the join text assertion can fail**

Remove the `strings.write_byte(&sb, ' ')` line. Expected: `content` is `"alphabetagamma"` and the
case FAILs. Paste the output. Restore.

- [ ] **Step 11: Measure the cost of `.Para` being extern-dep**

Making `.Para` extern-dep means **every** cached paragraph layout is invalidated by any edit
(`doc.revision` bumps), so typing in Split view rebuilds every visible paragraph per keystroke.
`.Table` already behaves this way, so this is a known cost shape, not a new one — but it has not been
measured for a kind that appears in every document.

Run `build\newtpad.exe drawcount <a long .md>` before and after this task's change and record both
numbers in the report. **Do not report a release figure**: `build.bat release` is
`-subsystem:windows` and cannot print, so any release number would be converted, not measured — say
so if you convert one.

If the rebuild cost is material, **report it and stop rather than redesigning**: the fix is a
narrower invalidation key, and that is a decision for Wyatt, not for this task.

- [ ] **Step 12: Commit**

Message: `Join a paragraph's lines into one block`

---

## Task 3: Hard line breaks survive the join

**Files:** Modify `src/program/markdown.odin` (the `.Para` case from Task 2),
`src/program/test_modes.odin`

**Interfaces:** Consumes Task 2's join loop. Produces no new symbols.

Joining without this would **destroy** breaks the author asked for, so it is required by the join
rather than an extra feature. CommonMark: a line ending in two or more spaces, or in a backslash, ends
with a hard break. The shaper already breaks on `'\n'` (`src/platform/shape.odin:287`, and
`shape.odin:405` handles two in a row), so this costs one character in the joined string.

- [ ] **Step 1: Write the failing test**

```odin
@(private = "file")
pj_case_hard_breaks :: proc(bad: ^int) {
	fmt.println("-- a hard break survives the join --")
	// "alpha  \nbeta\n" -- two trailing spaces. One block, but TWO visual lines.
	// Asserting on len(lay.sh.line_boxes) rather than on the text, because the
	// text assertion cannot tell a hard break from a space.
	//   * "alpha  \nbeta\n" at a wide measure -> 2 line boxes
	//   * "alpha\nbeta\n"   at the same measure -> 1 line box
	//   * "alpha\\\nbeta\n" (backslash) -> 2 line boxes
}
```

The measure must be **wide enough that soft wrapping cannot occur**, or the case passes for the wrong
reason. Assert the no-break control gives exactly 1 line box at that same measure — that is what makes
the 2 meaningful.

- [ ] **Step 2: Run it and watch it fail.** Expected: 1 line box where 2 is wanted. Paste output.

- [ ] **Step 3: Implement**

In Task 2's join loop, replace the `strings.write_string` line:

```odin
				// A hard break (CommonMark: two or more trailing spaces, or a
				// trailing backslash) becomes a real newline instead of a space.
				// The shaper breaks on '\n' already (platform/shape.odin:287), so
				// this is the whole implementation. Trailing whitespace is stripped
				// either way -- it is markup, not content.
				raw := strings.trim_right(l, " \t")
				hard := strings.has_suffix(l, "  ") || strings.has_suffix(raw, "\\")
				if strings.has_suffix(raw, "\\") {raw = raw[:len(raw) - 1]}
				if strings.builder_len(&sb) > 0 {
					strings.write_byte(&sb, '\n' if prev_hard else ' ')
				}
				strings.write_string(&sb, raw)
				prev_hard = hard
```

with `prev_hard := false` declared before the loop. **The break belongs to the line that ends with the
marker**, so it is written before the *next* line, not after the current one — writing it after would
put a break at the end of the paragraph's last line.

- [ ] **Step 4: Run the test.** Expected: PASS.

- [ ] **Step 5: SABOTAGE.** Change `'\n' if prev_hard else ' '` to always `' '`. Expected: the hard-break
cases drop to 1 line box and FAIL. Paste output. Restore.

- [ ] **Step 6: Commit.** Message: `Keep a hard break through the join`

---

## Task 4: Lazy continuation for lists and blockquotes

**Files:** Modify `src/program/markdown.odin`, `src/program/test_modes.odin`

**Interfaces:**
- Consumes: `md_para_bounds`, `Md_Layout.joined`/`.multiline`.
- Produces: **`md_para_bounds`'s signature changes** to
  `proc(doc: ^Document, p: int) -> (start, end: int, capped, ok: bool, owner: Md_Class)` — `owner` is
  the class of the block the run continues, with `owner.kind == .Para` when the run stands alone.

**This is a breaking change to Task 1's interface, and it is your job to carry it.** Task 1 created
`md_para_bounds_for_test` returning four values and three test cases that destructure four values
(`pj_case_entry_independent`, `pj_case_budget_truncates`, `pj_case_terminators`), and Task 2's `.Para`
case destructures four. **Update all five call sites in this task** — do not add a second bounds
function to avoid touching them. If the reviewer finds Task 1's tests still compiling against a stale
shim, that is a defect in this task, not in Task 1.

**This is the riskiest task in the batch** and the reviewer must be told so: it is the only part of the
design that makes a block's *kind* depend on its predecessor. `md_classify` is deliberately pure — one
line in, one class out — and it **must stay that way**. The dependency lives in `md_para_bounds`,
which is already looking backward.

Today a wrapped list item's continuation line has no bullet, so `md_classify` calls it `.Para` and it
renders as a stray un-indented paragraph under the bullet. Same for a blockquote continuation without
a `>`.

- [ ] **Step 1: Write the failing test**

```odin
@(private = "file")
pj_case_lazy_continuation :: proc(bad: ^int) {
	fmt.println("-- a wrapped list item and a wrapped quote keep their block --")
	//   "- item text\n  continues here\n"     -> ONE .List block, content joined,
	//                                            indent == the list's, one bullet
	//   "> quoted text\ncontinues here\n"     -> ONE .Quote block, quote indent
	//   "- item\n\nloose para\n"              -> still TWO blocks (blank ends it)
	// Assert on lay.indent and lay.marker, not just on kind: the bug this fixes is
	// the continuation losing the INDENT, and kind alone would pass with indent 0.
}
```

- [ ] **Step 2: Run it and watch it fail.** Expected: the continuation is a separate `.Para` at indent
0. Paste output.

- [ ] **Step 3: Implement**

Extend `md_para_bounds` to look one line *above* `start` after the backward scan settles, classify it,
and return it as `owner` when it is `.List` or `.Quote`. In `md_layout_build`, when `owner.kind` is
`.List` or `.Quote`, the block takes that kind, that `level`, and that `bullet` — and the continuation
run is appended to the owner's own content.

**The owner line's own text must be part of the joined content**, or the item's first line and its
continuation become two blocks again. Extend `start` to the owner's line start when an owner is found.

- [ ] **Step 4: Run the test.** Expected: PASS.

- [ ] **Step 5: SABOTAGE.** Drop the `indent`/`marker` inheritance so the continuation keeps the
paragraph's zero indent. Expected: the indent assertions FAIL while the kind assertions still pass —
which is the point of asserting both. Paste output. Restore.

- [ ] **Step 6: Re-run the whole mode plus `mdtest`, `mdviewtest`, `splittest`, `linktest`.**

A change to what a `.List` block contains is exactly the kind of thing that moves the preview's link
rectangles. Expected: all pass. Record any that do not **before** fixing them.

- [ ] **Step 7: Commit.** Message: `Continue a list item or quote across a wrapped line`

---

## Task 5: Setext headings

**Files:** Modify `src/program/markdown.odin`, `src/program/test_modes.odin`

**Interfaces:** Consumes Task 4's `owner` return. Produces no new symbols.

`md_classify` keeps returning `.Rule` for a `---` line in isolation — **do not change it.**
`md_para_bounds` already looks at the line that terminates the run; when that line is all `=` or all
`-` (and the run is a plain paragraph, not a list/quote continuation), the block is promoted.

- [ ] **Step 1: Write the failing test**

```odin
@(private = "file")
pj_case_setext :: proc(bad: ^int) {
	fmt.println("-- setext headings --")
	//   "Title\n===\n"      -> ONE .Heading level 1, extent past the underline
	//   "Title\n---\n"      -> ONE .Heading level 2
	//   "Title\n\n---\n"    -> a paragraph and a .Rule (blank line between)
	//   "- item\n---\n"     -> a list item and a .Rule (not a setext heading)
	// The extent assertion is the one that matters: a promoted block whose `next`
	// stops before the underline draws the rule TOO.
}
```

- [ ] **Step 2: Run it and watch it fail.** Paste output.

- [ ] **Step 3: Implement.** Promote in `md_layout_build`; set `e.cls.kind = .Heading`,
`e.cls.level = 1 or 2`, `e.multiline = true`, and extend `e.end`/`e.next` past the underline.
The heading's own metrics (`m.head[...]`, `head_above`/`head_below`, the h1/h2 rule) are applied by
the existing `.Heading` branch — **do not duplicate them.** Restructure so the promotion happens
before the kind switch rather than copying the branch.

- [ ] **Step 4: Run the test.** Expected: PASS.

- [ ] **Step 5: SABOTAGE.** Leave `e.next` at the paragraph's end rather than past the underline.
Expected: the extent case FAILs and a rule is drawn under the heading. Paste output. Restore.

- [ ] **Step 6: Commit.** Message: `Read a setext underline as its heading`

---

## Task 6: The scroll seam

**Files:** Modify `src/program/test_modes.odin` only. **If this task needs a source change, that is a
finding — report it before writing one.**

**Interfaces:** Consumes everything above.

A joined paragraph starts above its own line, which is exactly the input that made front matter's
run-up imprecise (`MD_RUNUP_LINES`, markdown.odin:3028). Four procedures resolve a byte to a block:
`md_block_at_byte`, `md_anchor_from_top`, `md_slot_at`, `md_max_anchor`.

- [ ] **Step 1: Write the round-trip test**

```odin
@(private = "file")
pj_case_scroll_round_trip :: proc(bad: ^int) {
	fmt.println("-- scrolling into a long paragraph and back lands on the same anchor --")
	h: Headless_Gpu
	if !headless_gpu_init(&h, 800, 600, "mdjointest") {
		li_chk(bad, false, "an offscreen device came up, so the anchor could be resolved")
		return
	}
	defer headless_gpu_destroy(&h)

	// THREE paragraphs of 40 source lines each, blank-separated. 40 > 24 is the
	// whole point: MD_RUNUP_LINES cannot clear one of these paragraphs, so a
	// run-up that lands inside one is the case under test. A 10-line fixture
	// would pass with the run-up broken.
	sb := strings.builder_make()
	defer strings.builder_destroy(&sb)
	for para in 0 ..< 3 {
		for i in 0 ..< 40 {fmt.sbprintf(&sb, "paragraph %d line %d of prose\n", para, i)}
		strings.write_string(&sb, "\n")
	}
	d := pj_doc(strings.to_string(sb))
	defer doc_close(&d)
	d.md_mode = .Preview

	c, cok := md_scroll_ctx(&h.gfx, &h.text, &d, 16, 800, 600, 0.5)
	if !cok {
		li_chk(bad, false, "a scroll context came up")
		return
	}
	start := md_anchor_from_top(&c, 0)
	a := start
	for _ in 0 ..< 12 {a = md_scroll_px(&c, a, 40)}
	for _ in 0 ..< 12 {a = md_scroll_px(&c, a, -40)}
	li_chk(
		bad,
		md_anchor_top_byte(&c, a) == md_anchor_top_byte(&c, start),
		fmt.tprintf("down 12 and back up 12 returns to byte %d (got %d)", md_anchor_top_byte(&c, start), md_anchor_top_byte(&c, a)),
	)
}
```

**Verify `md_scroll_px`'s sign convention and `md_anchor_from_top`'s argument before writing this** —
both are `@(private = "file")` in `markdown.odin` (lines 3658 and 3781) and will need a package-visible
shim, and a scroll that silently clamps at the top would make this pass trivially. **Assert that the
midpoint anchor is not the start anchor**, or a no-op scroll passes the round trip.

- [ ] **Step 2: Run it.** If it fails, **that is the expected outcome of this task** — it means the
run-up is insufficient for joined paragraphs. Report the failure with its output and **stop**; the fix
(a paragraph-aware run-up, replacing the fixed line count) is a design change and needs Wyatt.

- [ ] **Step 3: If it passes**, sabotage it: set `MD_RUNUP_LINES` to 1 and confirm the case fails.
A round-trip test that passes at a run-up of 1 is not testing the run-up. Paste output. Restore.

- [ ] **Step 4: Commit.** Message: `Test the preview's anchor across a joined paragraph`

---

## Task 7: Land it

**Files:** `HANDOFF.md`, `docs/development-loop.md`, `docs/reported-bugs.md`, `docs/features.md`,
`src/program/version.odin`

- [ ] **Step 1: Full regression sweep.** Set `NEWTPAD_SESSION_DIR` first. Run `odin test src\base
-collection:src=src` and every mode in HANDOFF §7's list, including `mdjointest`. Use
`Select-String -CaseSensitive "FAIL"` — the case-insensitive form matches "0 failures".
Record the output. **`menuseam` legitimately exits 0 whatever it finds** — diff its printed line.

- [ ] **Step 2: Bisectability sweep.** Every commit on the branch must build:

```bash
for c in $(git rev-list --reverse main..HEAD); do d=$(mktemp -d); git archive "$c" | tar -x -C "$d"; ( cd "$d" && odin check src/program -collection:src=src >/dev/null 2>&1 ) && echo "ok   $c" || echo "FAIL $c"; done
```

Archive the **whole tree**, not just `src/` — `links.odin` does `#load("../../text_exts.txt")`.
Note: `odin check src/program` **does** catch undeclared names and exit 1; two agents have reported
otherwise and both were wrong (HANDOFF §6az, §6bc). The likely cause is reading PowerShell's `$?`
instead of `$LASTEXITCODE` after a native command.

- [ ] **Step 3: HANDOFF entry.** A new `§6bd`. Not a changelog: what was built, **why it was built
that way**, what it got wrong, and what is owed. Must state plainly that **there was no live GUI pass**
and that the appearance is unverified. Include the Step 11 measurement from Task 2.

- [ ] **Step 4: Version bump.** `src/program/version.odin`, **same commit as the HANDOFF entry** —
`release.ps1` greps this file, so the tag and the binary cannot disagree. A feature batch is a minor
bump: `0.37.0`.

- [ ] **Step 5: Queue hygiene.** Delete the preview-spaces entry from `docs/reported-bugs.md` (it is a
queue, not a history) and add the new behaviour to `docs/features.md` §Markdown, replacing the line
that currently reads "Each source line is its own paragraph". Register `mdjointest` in **HANDOFF §7's
mode list** and in **development-loop.md §6**.

- [ ] **Step 6: Commit, merge, install, release.**

Merge to `main`. Then `install.ps1` — **check `Get-Process newtpad` first and never use `-Force`
while it is running**; a hard kill skips the hot-exit session write and loses unsaved tabs. If it is
running, say so and leave it to Wyatt. Then run `release.ps1` **bare** — never piped through `2>&1`,
which aborts it after tagging and pushing the branch but before pushing the tag.

---

## Review focus per task

Each task gets a fresh implementer and an independent reviewer. Tell every reviewer, in substance:
*do not trust the implementer's report; re-derive its claims from the code.* Then name the risk:

| Task | The risk to name |
|---|---|
| 1 | Entry dependence. Does every byte in one paragraph give one answer? Is `capped` derived after both scans, or during? Is any guard measured from `start` rather than `p`? |
| 2 | Does the layout cache actually hit? Is `cls.content` pointing at owned memory or at a temp builder that `free_all` reclaims each frame? Is `joined` freed exactly once? |
| 3 | Is the break attributed to the line that carries the marker, or off by one? Is the control case wide enough that soft wrap cannot fake the result? |
| 4 | This makes a block's kind depend on its predecessor. Does `md_classify` stay pure? Does the continuation inherit indent **and** marker, or only kind? |
| 5 | Does the promoted block's extent cover the underline, or is a rule still drawn under the heading? Are the heading metrics reused or duplicated? |
| 6 | Does the fixture actually exceed `MD_RUNUP_LINES`? A round-trip test on short paragraphs passes for the wrong reason. |
| 7 | Do the claimed test results match the pasted output? Is anything in the HANDOFF entry asserted without evidence? |

**The whole-branch review, on the most capable model**, gets what per-task reviews structurally cannot
see: whether the app is correct at every commit, whether any assertion is vacuous, whether the batch
made the `renderer`/`ui` extraction harder, and every finding carried deliberately — triaged as carry
or block.
