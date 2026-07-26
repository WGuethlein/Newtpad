// Layer: program -- rectangular (column) select-and-edit: the geometry.
//
// Newtpad renders on a monospace CELL grid (plat.text_cell_width classifies
// every rune as 0, 1 or 2 cells) but addresses the buffer in BYTES. A
// rectangle is dragged on screen, so it is naturally a (line, cell) region --
// and the moment any row in it holds a tab or a CJK character, its cell range
// and its byte range disagree. Every bug this codebase has shipped of the
// "correct function, wrong space" shape came from two consumers each deriving
// that mapping themselves and drifting apart.
//
// So this file gives the whole feature exactly one procedure that turns a
// row's cell range into bytes: block_row_range. The keyboard gesture, the
// mouse gesture, the draw, the copy and the edit (five later tasks) all call
// it; none of them may walk a row counting cells on their own. If a future
// change ever needs a sixth way to read a rectangle, it goes here too.
//
// The second rule this file exists to enforce: a bounded scan that cannot
// tell it was truncated must never answer as though it saw the whole row.
// block_row_range's ok=false is that refusal.
package main

import "core:unicode/utf8"
import base "src:base"
import plat "src:platform"

// Bytes a single row's cell-walk will scan before giving up rather than
// answer from a truncated read. Shared with the renderer's own per-row cap
// (RENDER_LINE_CAP, doc.odin) rather than inventing a second number: this
// bounds how much of one ROW's LENGTH the walk can afford to scan, not how
// many rows a rectangle spans -- whatever the renderer can already afford to
// scan for one row is exactly what this can afford too.
BLOCK_ROW_CAP :: RENDER_LINE_CAP

// Is a rectangular selection live? The four geometry fields below are only
// meaningful while this is true -- block_clear resets it rather than the
// caller having to remember to ignore stale coordinates.
block_active :: proc(doc: ^Document) -> bool {
	return doc.block
}

// End column select. Zeroing the geometry too (not strictly required by
// block_active's contract, but "zero is initialization" -- see CLAUDE.md)
// means a caller that forgets the block_active guard reads an empty
// rectangle at the origin, not a stale one from three edits ago.
block_clear :: proc(doc: ^Document) {
	doc.block = false
	doc.block_anchor_line = 0
	doc.block_anchor_cell = 0
	doc.block_cursor_line = 0
	doc.block_cursor_cell = 0
}

// Fresh-press state transition for a rectangle left over from an earlier
// gesture: main.odin's mouse-press handler calls this before it does
// anything else with the click. `alt` is whether Alt is held at THIS press
// -- and is deliberately NOT consulted below. Before this fix, the clear
// only ran on the branch that also established Alt was NOT held, so an
// Alt+click that never turned into a drag (never exceeded the slop in
// main.odin's drag-vs-click check) left the previous rectangle live: the
// click looked like it had been silently ignored. Every fresh press starts a
// new gesture regardless of Alt, and a press that DOES become a real
// Alt+drag rebuilds the rectangle from scratch via block_set_from_points
// (both corners, not an extension of whatever was here), so clearing
// unconditionally here costs nothing.
//
// Split out from main.odin's inline press handler -- which cannot be driven
// headlessly, there is no seam to simulate a real WM_LBUTTONDOWN -- so this
// one decision has a seam blocktest can exercise on its own.
block_press_clear :: proc(doc: ^Document, alt: bool) {
	if block_active(doc) {
		block_clear(doc)
	}
}

// The rectangle's four edges, normalised so lo <= hi on both axes regardless
// of which corner the drag started from -- dragging up-and-left must describe
// the identical rectangle as dragging down-and-right from the opposite
// corner, because the draw, the copy and the edit only ever want the
// normalised form.
block_bounds :: proc(doc: ^Document) -> (line_lo, line_hi, cell_lo, cell_hi: int) {
	line_lo = min(doc.block_anchor_line, doc.block_cursor_line)
	line_hi = max(doc.block_anchor_line, doc.block_cursor_line)
	cell_lo = min(doc.block_anchor_cell, doc.block_cursor_cell)
	cell_hi = max(doc.block_anchor_cell, doc.block_cursor_cell)
	return
}

// Row end for the cell-walk, bounded to BLOCK_ROW_CAP, with the exact-flag
// discipline pt_line_end_cap itself doesn't give you for free: the proc
// returns min(length, line_start+cap) BOTH when no '\n' turned up inside the
// cap AND, indistinguishably, when a real '\n' sits exactly at the cap
// boundary. doc_row_lex_extent (doc.odin) resolves the same ambiguity the
// same way: treat it as truncated.
//
// `truncated` does NOT by itself mean the caller must refuse -- it only means
// row_end might be a synthetic cap break rather than the row's real end.
// block_row_range only turns this into ok=false if its cell-walk actually ran
// off the end of [line_start, row_end) without finding cell_hi: a short
// rectangle near the start of an arbitrarily long row (a minified-JSON or log
// line) must still succeed, because the walk never needed to see past the
// cap to answer. Refusing on row length alone -- before the walk even starts
// -- was the bug: it fails every rectangle on a long row, not just the ones
// that actually reach past the cap.
@(private = "file")
block_row_end :: proc(doc: ^Document, line_start: int) -> (row_end: int, truncated: bool) {
	row_end = base.pt_line_end_cap(&doc.pt, line_start, BLOCK_ROW_CAP)
	truncated = row_end == line_start + BLOCK_ROW_CAP && row_end < doc.pt.length
	return
}

// The one procedure that turns a rectangle's cell range into bytes for one
// row. `line_start` is the row's byte offset (from doc_line_start_of_index or
// a visible-row iterator, never derived here); `cell_lo`/`cell_hi` are the
// rectangle's normalised cell edges (block_bounds). Returns:
//
//   - byte_lo, byte_hi: the byte range on this row the cell range covers.
//   - pad_cells: how many spaces an edit would need to type to reach cell_lo,
//     when the row is too short to reach it. Reported, never applied --
//     resolving a rectangle never mutates the buffer.
//   - ok: false when the row could not be resolved within BLOCK_ROW_CAP. The
//     caller must refuse the row, not guess from a partial scan.
//
// Precondition: cell_lo <= cell_hi (block_bounds' normalised form). A rune
// whose cell span straddles either edge is included whole rather than split
// -- a partial glyph has no byte representation, and including it is the
// only choice that round-trips through the buffer. The two edges are NOT
// symmetric because of this: the left edge is inclusive of any rune it
// touches (its own start is the answer whether the rune starts exactly there
// or straddles in from the left), but the right edge only extends past
// cell_hi when a rune actually straddles it -- a rune that merely starts
// exactly at cell_hi is excluded, because there is no partial glyph to
// protect there.
block_row_range :: proc(doc: ^Document, t: ^plat.Text, line_start: int, cell_lo, cell_hi: int) -> (byte_lo, byte_hi, pad_cells: int, ok: bool) {
	row_end, truncated := block_row_end(doc, line_start)

	// Both default to line_start, not 0: line_start is an absolute offset
	// into the document, and 0 is only correct for the very first row. If
	// hi_found ever fires without lo_found -- a zero-width rune sitting
	// exactly at cell_lo, or cell_lo == cell_hi -- byte_lo must stay a valid
	// offset ON THIS ROW rather than leak an offset belonging to row zero.
	byte_lo = line_start
	byte_hi = line_start

	buf: [4096]u8
	p := line_start
	cell := 0
	lo_found, hi_found := false, false

	outer: for p < row_end {
		n := base.pt_read(&doc.pt, p, buf[:min(len(buf), row_end - p)])
		if n == 0 {break}
		i := 0
		for i < n {
			if !utf8.full_rune(buf[i:n]) {
				// decode_rune can't tell "chunk boundary split a valid
				// multi-byte lead byte's tail off" apart from "this lead byte
				// is simply invalid" -- both return (RUNE_ERROR, 1). full_rune
				// can: it returns false only when the bytes seen so far are
				// still a plausible PREFIX of a longer encoding, which is
				// exactly the boundary-split case.
				if p + n < row_end {
					// More of the row exists past this chunk: refill starting
					// at this rune's own lead byte so the next read begins
					// with the complete encoding, then decode before counting
					// anything. Nothing has been counted for this rune yet.
					// Safe against the `if i == 0 {break}` guard below: this
					// always advances p (i is the position of the incomplete
					// rune's lead byte within the current, non-empty buffer),
					// and pt_read never short-reads below pt.length, so the
					// next iteration is guaranteed to make progress.
					p += i
					continue outer
				}
				// The row's own real end cut the rune off, not a chunk
				// boundary -- there is nothing left to refill with. Fall
				// through to decode_rune, which can't tell "truncated by
				// chunk" apart from "truncated for real" and returns
				// (RUNE_ERROR, 1) either way. That is the right answer here:
				// every other row walk in this tree (line_wrap_decision,
				// wrap_row_end) counts these bytes as RUNE_ERROR and the
				// renderer draws them, so this walk must agree rather than
				// refuse the whole row over its last one or two bytes.
			}
			r, sz := utf8.decode_rune(buf[i:n])
			if sz == 0 {sz = 1}
			w := plat.text_cell_width(t, r, .Doc)

			if !lo_found && cell + w > cell_lo {
				// This rune's span reaches into or past cell_lo, whether it
				// starts exactly there or straddles in from the left. Either
				// way the rectangle's left edge is this rune's own start.
				byte_lo = p + i
				lo_found = true
			}
			if !hi_found {
				if cell == cell_hi {
					// No straddle: this rune starts exactly at the right
					// edge, so it is entirely outside the rectangle.
					byte_hi = p + i
					hi_found = true
					break outer
				}
				if cell + w > cell_hi {
					// Straddles the right edge: included whole, same rule as
					// the left edge above.
					byte_hi = p + i + sz
					hi_found = true
					break outer
				}
			}
			cell += w
			i += sz
		}
		if i == 0 {break}
		p += i
	}

	if !hi_found {
		if truncated {
			// The walk ran off the end of the capped scan window without
			// finding cell_hi -- and row_end might only be a synthetic cap
			// break, not the row's real end. There is no way to tell whether
			// cell_hi (or even cell_lo) sits just past what was scanned, so
			// refuse rather than guess. A rectangle that DID find cell_hi
			// within the cap (above) never reaches this branch, however long
			// the row actually is.
			return line_start, line_start, 0, false
		}
		if !lo_found {
			// The row ran out before reaching cell_lo at all: nothing on it
			// falls in the rectangle, and an edit would need pad_cells spaces
			// to reach the left edge before it could type anything.
			return row_end, row_end, cell_lo - cell, true
		}
		// The row ran out between cell_lo and cell_hi: clamp to what it has.
		return byte_lo, row_end, 0, true
	}
	return byte_lo, byte_hi, 0, true
}

// Byte budget for doc_line_start_of_index's forward walk. This is a BOUNDED
// STOPGAP, not a real line index: the walk below costs O(bytes before line
// n), so calling it once per mouse-move frame (tasks 2/3) or once per row of
// a rectangle (tasks 4/5) is quadratic over a rectangle that sits deep in a
// large file -- exactly the "forward scanning is safe" mistake this codebase
// has frozen on before (see pt_line_start_cap). This bounds the walk's TOTAL
// cost across every line it steps through, not just the count of lines --
// each step is itself capped (via pt_line_end_cap) so a single pathologically
// long line can't blow the budget before the per-iteration guard gets a
// chance to fire. Capping the walk and refusing past the cap keeps one call's
// cost bounded and honest instead of silently going quadratic (or, on one
// long enough line, silently going linear in the whole document); it does
// not remove the cost. If a later task needs this per-frame against a
// realistically large document, the real answer is a row iterator or a
// cached line index, not a bigger number here.
DOC_LINE_INDEX_CAP :: BLOCK_ROW_CAP * 64

// Byte offset of the start of 0-based logical line `n`. Walks FORWARD from 0
// by a known, small line count -- the doc_goto_line idiom (doc.odin) -- which
// is why this is safe where base.pt_line_start is not: pt_line_start scans
// BACKWARD from an arbitrary offset with no bound, the exact hazard
// doc.odin:1853 documents, while stepping forward via the CAPPED
// pt_line_end_cap costs only the lines actually walked, bounded by
// DOC_LINE_INDEX_CAP total regardless of how long any one of those lines is.
// Added here because no "line N -> byte offset" helper existed anywhere in
// the tree before this task, and the keyboard and mouse gestures (later
// tasks) both need one to turn a target logical line into the line_start
// block_row_range takes.
//
// `ok` is false when the walk passed DOC_LINE_INDEX_CAP bytes before reaching
// line n -- the same refuse-rather-than-guess contract as block_row_range's
// own ok. Callers must not use `start` when ok is false. If n is at or past
// the document's last line, the walk simply runs out of newlines first (the
// real end of the document, not a cap break) and returns (pt.length, true) --
// there is no line n to refuse, so clamping to the document's end is the
// honest answer, not a guess. This clamp is silent by design, the same as
// pt_next_line_start's own EOF behaviour; it is not itself a bug.
//
// Measured at ~2.9ms per call at the cap (debug build). Fine for a one-shot
// click; NOT for a per-row loop or once per mouse-move frame -- 40 rows would
// be ~120ms of main-thread work in one frame. Callers needing many rows must
// resolve line_start ONCE here and then step forward row-by-row from that
// already-resolved offset (block_row_end / a visible-row iterator), never by
// calling this once per row.
// Caret's own (logical line, cell) position, for seeding a fresh rectangle.
// Reuses doc_cursor_line's cached, capped line count and the same
// pt_line_start_cap -> line_cell_col path doc_cursor_col takes (doc.odin,
// around line 1829) rather than hand-rolling a byte-to-cell walk here --
// this file's own rule (the package comment above) is that every cell<->byte
// conversion goes through one procedure, and a second walk here would be
// exactly the Shape B bug the rule exists to prevent.
//
// `ok` is false whenever either axis could not be resolved within its own
// cap -- doc_cursor_line returning 0 (caret beyond STATUS_LINE_CAP, an
// unknown line) or pt_line_start_cap returning exact=false (caret beyond
// STATUS_COL_CAP from its own line start). Both used to fall back to 0
// silently while the caller still reported success, which seeds a rectangle
// at line/cell 0 instead of refusing -- a confident wrong answer on a large
// file. The caller must refuse rather than use `line`/`cell` when ok is
// false.
@(private = "file")
caret_line_cell :: proc(doc: ^Document, t: ^plat.Text) -> (line, cell: int, ok: bool) {
	cl := doc_cursor_line(doc)
	if cl == 0 {
		return 0, 0, false
	}
	// doc_cursor_line is 1-based; block_anchor_line/block_cursor_line are
	// 0-based, the same convention doc_line_start_of_index's own `n` uses.
	line = cl - 1
	ls, exact := base.pt_line_start_cap(&doc.pt, doc.cursor, STATUS_COL_CAP)
	if !exact {
		return line, 0, false
	}
	cell = line_cell_col(doc, t, ls, doc.cursor)
	return line, cell, true
}

// Why block_extend refuses, distinct from whether it refused: the two
// refusal reasons need two different user-facing notes (command_dispatch's
// dispatcher, commands.odin), and a bare bool can't carry that. Wrap_On is
// the pre-existing "word-wrap is on" refusal (checked via doc_wraps, so it
// also covers Markdown Split forcing the editor half to wrap); Caret_Unresolved
// is new -- the caret sits far enough into a large file that caret_line_cell
// could not resolve one or both axes within its own scan cap. Filter_On is
// its own variant rather than folding into Wrap_On: in filter mode the visible
// rows are a non-contiguous subset of the document's lines, so a rectangle's
// line indices mean something different again -- and telling the user to
// press Alt+Z (the word-wrap toggle) when the real problem is the filter view
// would send them chasing the wrong control.
Block_Refusal :: enum {
	None,
	Wrap_On,
	Caret_Unresolved,
	Filter_On,
}

// Seed or extend a column rectangle from the keyboard. `dline`/`dcell` are
// the step this call adds to the rectangle's CURSOR corner only -- the
// anchor never moves once set, exactly like a normal shift-extend leaves
// doc.anchor alone (set_cursor, doc.odin). Returns a refusal (changing no
// state at all) rather than .None in two cases:
//
//   - .Wrap_On when the document is word-wrapped: wrap turns one logical
//     line into many visual rows, so a (line, cell) rectangle stops
//     describing anything stable the instant it's toggled (see this file's
//     package comment and doc.odin's block_anchor_line field comment) -- the
//     gesture must refuse up front rather than build a rectangle whose
//     meaning is about to change under it.
//   - .Caret_Unresolved when there is no rectangle yet and caret_line_cell
//     could not resolve the caret's (line, cell) within its own caps. The
//     old code let both axes fall back to 0 silently while still reporting
//     success -- seeding a rectangle at line/cell 0 instead of wherever the
//     caret actually is, on a document large enough to matter. Refusing is
//     correct here; guessing is not, because Task 5/6 copy and edit through
//     this rectangle.
//
// This takes no ^App and does not call app_note itself: block.odin has never
// imported the App type (see the package comment's layering), and the one
// caller with `app` already in scope is command_dispatch, which turns each
// refusal into its own status note.
block_extend :: proc(doc: ^Document, t: ^plat.Text, dline, dcell: int) -> Block_Refusal {
	if doc.filter {
		return .Filter_On
	}
	if doc_wraps(doc) {
		return .Wrap_On
	}
	if !doc.block {
		// No rectangle yet: seed BOTH corners at the caret's own (line,
		// cell). This call's own delta is then applied to the cursor corner
		// below, same as every later call once the rectangle already exists
		// -- so the very first Alt+Shift+arrow both starts the rectangle at
		// the caret AND moves one step, rather than requiring two presses.
		line, cell, ok := caret_line_cell(doc, t)
		if !ok {
			return .Caret_Unresolved
		}
		doc.block = true
		doc.block_anchor_line = line
		doc.block_anchor_cell = cell
		doc.block_cursor_line = line
		doc.block_cursor_cell = cell
	}
	// Clamp at 0 on both axes -- there is no line or cell before the start
	// of the document to extend into, and going negative would make
	// block_bounds' min/max normalisation paper over an already-wrong value
	// rather than the rectangle simply stopping at the edge.
	doc.block_cursor_line = max(0, doc.block_cursor_line + dline)
	doc.block_cursor_cell = max(0, doc.block_cursor_cell + dcell)
	return .None
}

// Seed or replace a column rectangle from BOTH ends at once -- the mouse drag's
// shape, as opposed to block_extend's keyboard shape of stepping the cursor
// corner one delta at a time from wherever the rectangle already is. The
// caller (main.odin's drag path) has already resolved both corners' (logical
// line, cell) itself -- via cell_at_x for the cell and the same doc_cursor_line
// the status bar draws from for the line -- so this proc does no resolution of
// its own; it only applies the two refusals block_extend applies, then writes
// the geometry straight through.
//
// `t` is accepted for the same reason every other block.odin proc takes it
// (interface symmetry with block_extend/block_row_range) even though this
// particular proc has no cell-space walk of its own to do with it -- both ends
// arrive pre-resolved.
//
// A negative line (either end) is the caller's signal that it could not
// resolve that point -- doc_cursor_line's own "0 = beyond STATUS_LINE_CAP"
// contract, shifted to 0-based and re-expressed as "unresolved" rather than
// "unknown line number", the same sentinel caret_line_cell would have refused
// on. Cells never carry this signal: cell_at_x floors at 0 and cannot fail.
block_set_from_points :: proc(doc: ^Document, t: ^plat.Text, a_line, a_cell, c_line, c_cell: int) -> Block_Refusal {
	if doc.filter {
		return .Filter_On
	}
	if doc_wraps(doc) {
		return .Wrap_On
	}
	if a_line < 0 || c_line < 0 {
		return .Caret_Unresolved
	}
	doc.block = true
	doc.block_anchor_line = a_line
	doc.block_anchor_cell = max(0, a_cell)
	doc.block_cursor_line = c_line
	doc.block_cursor_cell = max(0, c_cell)
	return .None
}

// --- Task 4: drawing the rectangle ---

// Byte offset of the start of logical line `to_line`, walking FORWARD from
// `from` -- the already-resolved byte start of `from_line` -- rather than
// from the document's start. doc_line_start_of_index (above) always resolves
// relative to byte 0, spending its whole DOC_LINE_INDEX_CAP budget just
// reaching `from_line`; re-deriving the rectangle's BOTTOM edge the same way
// would spend a second cap's worth of budget reaching `to_line`'s ABSOLUTE
// position in the file, so a rectangle sitting deep in a large file would
// fail to draw even when it only covers a screenful of rows. Anchoring here
// at `from` instead makes the walk's cost proportional to (to_line -
// from_line) -- the rectangle's own height, which is what a per-frame draw
// can actually afford, not its depth.
//
// Same stepping (base.pt_line_end_cap) and the same refuse-rather-than-guess
// contract as doc_line_start_of_index: `ok` is false if the walk passes
// DOC_LINE_INDEX_CAP bytes past `from` before reaching `to_line`. If
// `to_line` is at or past the document's last line, clamps to pt.length (the
// real end, not a cap break) -- same reasoning as doc_line_start_of_index's
// own EOF clamp.
@(private = "file")
block_lines_forward :: proc(doc: ^Document, from, from_line, to_line: int) -> (start: int, ok: bool) {
	p := from
	budget := from + DOC_LINE_INDEX_CAP
	for _ in from_line ..< to_line {
		if p >= budget {
			return p, false
		}
		e := base.pt_line_end_cap(&doc.pt, p, budget - p)
		if e >= doc.pt.length {
			p = doc.pt.length
			break
		}
		if e >= budget {
			return p, false
		}
		p = e + 1
	}
	return p, true
}

// Selection highlight rectangles for a column rectangle's visible rows -- the
// block-select counterpart to doc_selection_rects (doc.odin), same shape, so
// main.odin's draw call picks between the two on block_active(doc). Every
// byte range drawn here comes from block_row_range -- never a second,
// independently-derived cell walk -- because Task 6's edit calls the exact
// same procedure on the exact same rows: if this draw and that edit each
// worked out their own byte ranges, they could drift apart, and the user
// would edit something other than what they saw highlighted. See this file's
// package comment for why that single-source rule is the whole point of the
// feature.
block_selection_rects :: proc(doc: ^Document, t: ^plat.Text, px, char_w: f32, rows: int, out: []plat.Quad) -> int {
	if !block_active(doc) {return 0}
	line_lo, line_hi, cell_lo, cell_hi := block_bounds(doc)

	// Resolve the rectangle's vertical span to BYTES once per draw call, not
	// once per row -- doc_line_start_of_index costs ~2.9ms per call at its
	// cap (debug build), so calling it per visible row (~40/frame) would cost
	// ~120ms in a single frame. line_lo's own byte offset must come from
	// doc_line_start_of_index (the only anchor it has: doc start); line_hi's
	// is then found by walking FORWARD from that already-resolved point
	// (block_lines_forward above), not by a second doc-start-anchored call.
	span_lo, lo_ok := doc_line_start_of_index(doc, line_lo)
	if !lo_ok {
		// The rectangle's own top could not be resolved within
		// DOC_LINE_INDEX_CAP bytes of the document start -- refuse rather
		// than guess a span that might not actually bound the rectangle,
		// same rule as every other cap in this file. Known gap (see the
		// task-4 report): block_extend/block_set_from_points can seed a
		// corner up to STATUS_LINE_CAP (4 MiB) deep, larger than
		// DOC_LINE_INDEX_CAP (512 KiB) here, so a rectangle can exist that
		// far in and still fail to draw.
		return 0
	}
	span_hi, hi_ok := block_lines_forward(doc, span_lo, line_lo, line_hi + 1)
	if !hi_ok {
		return 0 // same refusal, for the rectangle's bottom edge
	}

	col := g_theme[.Selection_Doc]
	lh := line_height(px)
	it := visible_begin(doc, t, rows)
	n := 0
	for n < len(out) {
		row, start, _, _, _, wrapped, ok := visible_next(&it)
		if !ok {break}
		// Byte-range inclusion, not line-number arithmetic: a logical line
		// longer than RENDER_LINE_CAP is split into several capped rows by
		// the viewport iterator (doc.odin), each drawn as its own screen row
		// with its own cell-0 origin -- the same convention the ordinary
		// text draw already uses for such a line. Comparing byte ranges
		// (rather than assuming visible row r is logical line line_lo + r)
		// handles that split for free and also means doc.top need not sit at
		// the rectangle's own top line.
		if start < span_lo || start >= span_hi {continue}

		byte_lo, byte_hi, pad_cells, rok := block_row_range(doc, t, start, cell_lo, cell_hi)
		if !rok {
			// The row's cell walk ran off the end of BLOCK_ROW_CAP without
			// resolving cell_hi -- block_row_range's own refusal. Drawing
			// this row anyway (as empty, or as far as the walk got) would
			// show a boundary that isn't actually where the rectangle ends
			// on this row; skipping it is the same "a bounded scan that
			// cannot tell it was truncated must never answer as though it
			// saw the whole row" rule the rest of this file follows. Task 6
			// must make the identical call and will refuse the row the same
			// way, so nothing is ever edited that wasn't shown selected.
			continue
		}
		if pad_cells > 0 {
			// The row never reached cell_lo -- requirement 2: it
			// contributes nothing to the selection. Padding is reported for
			// an edit to use later (Task 6), never drawn or applied here.
			continue
		}

		rhs := 0 if wrapped else H_SCROLL
		startcol := min(line_cell_col(doc, t, start, byte_lo), VISIBLE_COLS)
		endcol := min(line_cell_col(doc, t, start, byte_hi), VISIBLE_COLS)
		sx := col_x(char_w, startcol, rhs)
		ex := col_x(char_w, endcol, rhs)
		// A zero-width rectangle (cell_lo == cell_hi) resolves byte_lo ==
		// byte_hi on every row it reaches -- the "N carets in one column"
		// affordance (requirement 1) -- and a non-zero rectangle can still
		// collapse to zero width on a row that runs out exactly at cell_lo.
		// Either way the floor below turns it into a visible thin bar rather
		// than an invisible 0-px quad -- the same floor doc_selection_rects
		// (doc.odin) already applies to its own rectangles, not a new rule.
		out[n] = {pos = {sx, row_rect_y(px, row)}, size = {max(ex - sx, 2), lh}, color = col}
		n += 1
	}
	return n
}

doc_line_start_of_index :: proc(doc: ^Document, n: int) -> (start: int, ok: bool) {
	p := 0
	for _ in 0 ..< n {
		if p >= DOC_LINE_INDEX_CAP {
			return p, false
		}
		// Step via the CAPPED primitive, not pt_next_line_start -- that proc
		// calls pt_line_end, which is uncapped, so a single pathologically
		// long line would already have been scanned in full before the guard
		// above ever got a chance to fire. (Measured: a 64MB single-line
		// document took 151ms and only THEN returned ok=false -- the walk
		// had scanned the whole line before checking the cap it claimed to
		// respect.) Passing DOC_LINE_INDEX_CAP - p as the per-step cap means
		// the absolute offset this step can reach is always exactly
		// DOC_LINE_INDEX_CAP, so no single step -- and therefore no single
		// line, however long -- can scan past the walk's total budget.
		e := base.pt_line_end_cap(&doc.pt, p, DOC_LINE_INDEX_CAP - p)
		if e >= doc.pt.length {
			// Real end of document, not a cap break: line n doesn't exist.
			// Clamp rather than refuse -- see the doc comment above.
			p = doc.pt.length
			break
		}
		if e >= DOC_LINE_INDEX_CAP {
			// Hit the cap without finding this line's '\n' -- or, per
			// pt_line_end_cap's own contract, found one exactly at the cap
			// boundary, indistinguishable from the truncated case. Either
			// way, refuse rather than guess: the same rule block_row_end
			// applies for BLOCK_ROW_CAP.
			return p, false
		}
		p = e + 1
	}
	return p, true
}
