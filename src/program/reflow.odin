// Layer: program — Unwrap Selected Lines and Reflow Paragraph at Wrap Column.
//
// UI spec 7's palette mockup lists both by name and neither existed. They are one
// operation with two settings of the same dial: unwrap joins a paragraph's lines
// into one, reflow joins them and then breaks the result at a column.
//
// THE COLUMN IS A SETTING, NOT THE VIEW. §6cw removed the editor's 100-column wrap
// cap so wrap follows the window — which makes the window a bad target for an
// EDIT: the same paragraph would reflow differently after a resize, and the
// command would not be repeatable. `reflow_col` (settings.odin, default 80) gives
// it a stable number the user can see and change. Wyatt's call, 2026-08-06.
package main

import "core:fmt"
import base "src:base"
import plat "src:platform"

REFLOW_COL_DEFAULT :: 80
REFLOW_COL_MIN :: 20
REFLOW_COL_MAX :: 200

// Same shape as tab_width_normalise: one reading of the value, shared by the
// loader and the saver, so a 0 (or a settings.txt from a build that predates this
// setting, which has no such line) means the default in both directions rather
// than a paragraph reflowed onto one column.
reflow_col_normalise :: proc(n: int) -> int {
	if n <= 0 {return REFLOW_COL_DEFAULT}
	return clamp(n, REFLOW_COL_MIN, REFLOW_COL_MAX)
}

// The same byte ceiling the sort commands use, and for the same reason: the whole
// region is read into one buffer, rewritten, and written back as a single edit, so
// the cost is bounded by refusing rather than by streaming.
REFLOW_MAX_BYTES :: SORT_MAX_BYTES

Reflow_Result :: enum u8 {
	Ok,
	Unchanged, // nothing to join or break; no undo entry pushed
	No_Paragraph, // the caret is on a blank line and nothing is selected
	Too_Big,
	Unresolved, // a line runs longer than the scan can resolve
	Faulted, // the file changed on disk mid-read
}

// Does this line START a block, rather than continue the one above?
//
// DELIBERATELY NOT md_para_bounds, and this is the one design call in the file
// worth arguing. That proc answers the PREVIEW's question: it works from a byte
// position, carries RENDER_LINE_CAP budget guards, reports `capped`, and resolves
// setext underlines and lazy continuation because CommonMark says a rendered
// paragraph swallows them. This is an EDIT over a region already read into a
// buffer, and it needs the opposite bias: never silently merge two things the user
// sees as separate. A lazy-continuation line under a list item renders as part of
// that item and is still, on screen, its own line that someone may have meant to
// keep.
//
// So: a blank line ends a paragraph, and any line whose own leading marker starts
// something ends it too. Reflowing one list item leaves the next alone; reflowing
// a paragraph under a heading does not eat the heading.
@(private = "file")
reflow_block_start :: proc(line: string) -> bool {
	i := 0
	for i < len(line) && (line[i] == ' ' || line[i] == '\t') {i += 1}
	if i >= len(line) {return true} // blank (or whitespace-only): ends the run
	// Four spaces or a tab of indent is an indented code block in every markdown
	// dialect, and in plain text it is a deliberate hang. Either way, not prose to
	// be rewrapped.
	if i >= 4 || (i > 0 && line[0] == '\t') {return true}
	c := line[i]
	switch c {
	case '#', '>', '=', '-', '*', '+', '|', '`', '~', '_':
		// `-`, `*`, `+` are bullets AND thematic breaks AND (for `-`/`=`) setext
		// underlines; `|` is a table row; backtick/tilde a fence; `_` a break.
		// Every one of them means "this line is structural", which is the only
		// question being asked here.
		return true
	}
	// `1. ` / `1) ` — an ordered list item.
	j := i
	for j < len(line) && line[j] >= '0' && line[j] <= '9' {j += 1}
	if j > i && j < len(line) && (line[j] == '.' || line[j] == ')') {return true}
	return false
}

// The leading whitespace of a line, as a slice of it. Reflow gives every line it
// produces the FIRST line's indent, so an indented paragraph stays indented
// instead of being flattened to column 0.
@(private = "file")
reflow_indent :: proc(line: string) -> string {
	i := 0
	for i < len(line) && (line[i] == ' ' || line[i] == '\t') {i += 1}
	return line[:i]
}

// Split a region into lines without allocating per line: returns the [start, end)
// byte offsets of the line containing `at`, walking `buf` only.
@(private = "file")
reflow_line_at :: proc(buf: []u8, at: int) -> (start, end: int) {
	start = at
	for start > 0 && buf[start - 1] != '\n' {start -= 1}
	end = at
	for end < len(buf) && buf[end] != '\n' {end += 1}
	return
}

// Trim a line's trailing CR (so CRLF files join without embedding carriage
// returns) and any trailing spaces the join would otherwise double up.
@(private = "file")
reflow_trim :: proc(s: string) -> string {
	e := len(s)
	for e > 0 && (s[e - 1] == '\r' || s[e - 1] == ' ' || s[e - 1] == '\t') {e -= 1}
	return s[:e]
}

// Join a run of lines into words separated by single spaces, then optionally break
// at `cols` cells. `cols <= 0` means unwrap: one line, no breaking.
//
// Measured in CELLS via plat.text_cells, not bytes and not runes: a reflow column
// is a visual width, and a document with CJK or emoji in it would otherwise wrap
// at roughly half the requested column. This is the only reason the operation
// needs a ^plat.Text at all.
@(private = "file")
reflow_join :: proc(t: ^plat.Text, lines: []string, indent: string, cols: int, out: ^[dynamic]u8) {
	ind_cells := 0
	if t != nil {ind_cells = plat.text_cells(t, transmute([]u8)indent, 0)}
	append(out, ..transmute([]u8)indent)
	line_cells := ind_cells
	first := true
	for ln in lines {
		s := reflow_trim(ln)
		// Words, split on runs of spaces and tabs.
		i := 0
		for i < len(s) {
			for i < len(s) && (s[i] == ' ' || s[i] == '\t') {i += 1}
			if i >= len(s) {break}
			j := i
			for j < len(s) && s[j] != ' ' && s[j] != '\t' {j += 1}
			word := s[i:j]
			i = j
			wc := len(word)
			if t != nil {wc = plat.text_cells(t, transmute([]u8)word, 0)}
			if first {
				append(out, ..transmute([]u8)word)
				line_cells += wc
				first = false
				continue
			}
			// The break decision, and NO GUARD AGAINST AN OVER-LONG WORD, because
			// none is reachable. This carried `&& line_cells > ind_cells`, with a
			// comment claiming it stopped a word wider than the column from breaking
			// onto an empty line forever. Deleting it left every assertion green --
			// and the reason is structural, not a gap in the test: the word is
			// appended AFTER this branch unconditionally, so a continuation line
			// always holds at least one word by the time the next word is checked,
			// and `line_cells > ind_cells` is invariantly true here. A dead check, of
			// the shape development-loop §1 lists among the defects that got through
			// plan review. The sabotage found it; reasoning is what put it there.
			//
			// An over-long word therefore overhangs the column, which is what every
			// reflow implementation does and what the user wants for a URL. There is
			// no loop to guard against either way: `i` advances over the word.
			if cols > 0 && line_cells + 1 + wc > cols {
				append(out, '\n')
				append(out, ..transmute([]u8)indent)
				line_cells = ind_cells
			} else {
				append(out, ' ')
				line_cells += 1
			}
			append(out, ..transmute([]u8)word)
			line_cells += wc
		}
	}
}

// Unwrap (cols <= 0) or reflow (cols > 0) the paragraph at the caret, or every
// paragraph the selection touches.
//
// One doc_replace_range for the whole region, so the operation is ONE undo entry
// however many paragraphs it rewrites -- the property doc_sort_lines' own comment
// identifies as coming from the single write rather than from the batch pair.
doc_reflow :: proc(doc: ^Document, t: ^plat.Text, cols: int) -> Reflow_Result {
	if doc == nil || doc.kind != .Text || doc.pt.length == 0 {return .Unchanged}

	sel_lo, sel_hi := doc_sel_range(doc)
	if !doc_has_sel(doc) {sel_lo, sel_hi = doc.cursor, doc.cursor}

	// Line-align the region, exactly as doc_sort_lines does.
	lo, lo_exact := base.pt_line_start_cap(&doc.pt, sel_lo, REFLOW_MAX_BYTES)
	if !lo_exact {return .Unresolved}
	end_pos := sel_hi
	{
		// byte_at is file-private to doc.odin and this is its only use here, so the
		// one byte is read directly rather than widening that helper too.
		one: [1]u8
		if end_pos > lo && end_pos > 0 && base.pt_read(&doc.pt, end_pos - 1, one[:]) == 1 && one[0] == '\n' {
			end_pos -= 1
		}
	}
	last_start, last_exact := base.pt_line_start_cap(&doc.pt, end_pos, REFLOW_MAX_BYTES)
	if !last_exact {return .Unresolved}
	hi, _, span_ok := line_span_cap(&doc.pt, last_start, REFLOW_MAX_BYTES)
	if !span_ok {return .Unresolved}

	// WITH NO SELECTION, GROW THE REGION TO THE WHOLE PARAGRAPH (Wyatt, 2026-08-06:
	// "the paragraph at the caret"). Bounded by REFLOW_MAX_BYTES in both
	// directions, so a caret inside a 40 MB single-line file refuses rather than
	// walking it.
	if !doc_has_sel(doc) {
		for lo > 0 {
			ps, pe := base.pt_line_start_cap(&doc.pt, lo - 1, REFLOW_MAX_BYTES)
			if !pe {return .Unresolved}
			pl, _, pok := line_span_cap(&doc.pt, ps, REFLOW_MAX_BYTES)
			if !pok {return .Unresolved}
			prev := make([]u8, pl - ps, context.temp_allocator)
			if base.pt_read(&doc.pt, ps, prev) != len(prev) {return .Faulted}
			if reflow_block_start(string(prev)) {break}
			lo = ps
			if hi - lo > REFLOW_MAX_BYTES {return .Too_Big}
		}
		for hi < doc.pt.length {
			ns := hi + 1 // past the terminator
			if ns > doc.pt.length {break}
			nl, _, nok := line_span_cap(&doc.pt, ns, REFLOW_MAX_BYTES)
			if !nok {return .Unresolved}
			next := make([]u8, nl - ns, context.temp_allocator)
			if base.pt_read(&doc.pt, ns, next) != len(next) {return .Faulted}
			if reflow_block_start(string(next)) {break}
			hi = nl
			if hi - lo > REFLOW_MAX_BYTES {return .Too_Big}
		}
	}

	if hi <= lo {return .No_Paragraph}
	if hi - lo > REFLOW_MAX_BYTES {return .Too_Big}

	buf := make([]u8, hi - lo)
	defer delete(buf)
	// The same refusal doc_sort_lines carries, for the same reason: a faulted read
	// out of a mapped original leaves the tail ZEROED, and this proc would write
	// those NULs back as a real edit.
	if base.pt_read(&doc.pt, lo, buf) != len(buf) || base.pt_faulted(&doc.pt) {return .Faulted}

	// Split into lines, then into runs at every block start.
	lines := make([dynamic]string, 0, 64, context.temp_allocator)
	{
		i := 0
		for i <= len(buf) {
			_, e := reflow_line_at(buf, i)
			append(&lines, string(buf[i:e]))
			if e >= len(buf) {break}
			i = e + 1
		}
	}
	if len(lines) == 0 {return .No_Paragraph}

	out := make([dynamic]u8, 0, len(buf))
	defer delete(out)
	run := make([dynamic]string, 0, 32, context.temp_allocator)
	emitted := false
	flush :: proc(t: ^plat.Text, run: ^[dynamic]string, cols: int, out: ^[dynamic]u8, emitted: ^bool) {
		if len(run) == 0 {return}
		if emitted^ {append(out, '\n')}
		reflow_join(t, run[:], reflow_indent(run[0]), cols, out)
		emitted^ = true
		clear(run)
	}
	for ln in lines {
		if reflow_block_start(ln) {
			// A structural or blank line ends the run and is COPIED THROUGH
			// UNCHANGED. That is what keeps a selection spanning a list, a heading
			// and two paragraphs from being flattened into one block: only the prose
			// runs between them are rewritten.
			flush(t, &run, cols, &out, &emitted)
			if emitted {append(&out, '\n')}
			append(&out, ..transmute([]u8)reflow_trim(ln))
			emitted = true
			continue
		}
		append(&run, ln)
	}
	flush(t, &run, cols, &out, &emitted)

	// Checked BEFORE doc_batch_begin, whose push_undo would otherwise mark the
	// document modified and push an entry restoring the state it is already in.
	if len(out) == len(buf) {
		same := true
		for b, i in out {
			if buf[i] != b {
				same = false
				break
			}
		}
		if same {return .Unchanged}
	}

	doc_batch_begin(doc, .Replace)
	doc_replace_range(doc, lo, hi - lo, out[:]) // a COUNT, not an end offset
	doc_batch_end(doc, 1) // one write, so one undo entry
	// The caret lands at the end of what was rewritten, and the selection is
	// dropped: the old range's offsets do not survive a rewrite that changes the
	// region's length, and leaving an anchor pointing into moved bytes is the
	// stale-index shape development-loop §4 calls Shape B.
	doc.cursor = min(lo + len(out), doc.pt.length)
	doc.anchor = doc.cursor
	return .Ok
}

// The one place both commands report from, so their refusals cannot drift apart.
reflow_dispatch :: proc(app: ^App, doc: ^Document, t: ^plat.Text, cols: int) {
	what := "REFLOW" if cols > 0 else "UNWRAP"
	// A rectangle is a COLUMN and these commands only speak paragraphs -- the same
	// refusal sort_lines_dispatch makes, and for the same reason: "reflow the
	// rectangle" has two honest readings and principle 3's answer is to offer
	// neither. Left live, so a refusal does not also destroy the gesture.
	if doc != nil && block_active(doc) {
		app_note(app, fmt.tprintf("[%s UNAVAILABLE - column selection is live; press Escape first]", what))
		return
	}
	switch doc_reflow(doc, t, cols) {
	case .Ok:
	// Visibly changed; a note would be noise.
	case .Unchanged:
		if doc != nil && doc.kind == .Text {
			app_note(app, fmt.tprintf("[NOTHING TO %s - the paragraph is already like that]", what))
		}
	case .No_Paragraph:
		app_note(app, fmt.tprintf("[NOTHING TO %s - the caret is not in a paragraph]", what))
	case .Too_Big:
		app_note(app, fmt.tprintf("[%s REFUSED - over the %d MB limit]", what, REFLOW_MAX_BYTES / (1024 * 1024)))
	case .Unresolved:
		app_note(app, fmt.tprintf("[%s UNAVAILABLE HERE - a line runs longer than it can scan]", what))
	case .Faulted:
		app_note(app, fmt.tprintf("[%s REFUSED - the file changed on disk while it was being read]", what))
	}
}
