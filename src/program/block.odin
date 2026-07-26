// Layer: program -- rectangular (column) select-and-edit: the geometry.
//
// Newtpad renders on a monospace CELL grid (plat.text_cell_width classifies
// every rune as 0, 1 or 2 cells) but addresses the buffer in BYTES. A
// rectangle is dragged on screen, so it is naturally a (row, cell) region --
// and the moment any row in it holds a tab or a CJK character, its cell range
// and its byte range disagree. Every bug this codebase has shipped of the
// "correct function, wrong space" shape came from two consumers each deriving
// that mapping themselves and drifting apart.
//
// The vertical coordinate is a BYTE OFFSET -- the row's own first byte -- and
// never a line number. Newtpad has no line index, so a line number is not a
// cheap coordinate here: it costs O(depth in the file) to produce and the same
// again for every consumer that has to turn it back into an offset. Storing
// line numbers made an Alt+drag cost 48ms per frame on an ordinary log and
// made rectangles deeper than 512 KiB impossible to draw at all. Nothing in
// this file may reintroduce a line number, and nothing may walk to a row from
// the document's start.
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

import "core:strings"
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

// Bytes one VERTICAL step of a rectangle may scan looking for the adjacent
// row's start (block_step_lines), and the budget block_line_start_at spends
// resolving a fresh corner's own line start. One number for both directions
// rather than two, and it is STATUS_COL_CAP because that is already what the
// caret's own line start costs: doc_cursor_col (doc.odin) calls
// pt_line_start_cap with exactly this cap every frame, so seeding a corner
// from the caret adds no scan the status bar was not already paying for.
//
// This bounds ONE step. It is not a total budget for a walk, because after
// this change nothing walks a rectangle's rows from the document start any
// more -- the rectangle's rows ARE byte offsets, so the draw tests membership
// with a single byte read per visible row and the keyboard steps one row at a
// time. Cost scales with the rectangle, never with its depth in the file.
BLOCK_LINE_STEP_CAP :: STATUS_COL_CAP

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
	doc.block_anchor_line_start = 0
	doc.block_anchor_cell = 0
	doc.block_cursor_line_start = 0
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
// normalised form. Both axes normalise independently, which is what makes a
// rectangle a rectangle rather than a linear range.
//
// off_lo/off_hi, not line_lo/line_hi: the vertical coordinate is the BYTE
// OFFSET of a row's first byte (see Document's own field comment), and both
// returned values are line starts in the buffer -- never line numbers. The
// names carry that so no caller can read them as an index and quietly hand
// them to something that wants one; comparing offsets is the same min/max it
// always was, only the coordinate's meaning changed.
block_bounds :: proc(doc: ^Document) -> (off_lo, off_hi, cell_lo, cell_hi: int) {
	off_lo = min(doc.block_anchor_line_start, doc.block_cursor_line_start)
	off_hi = max(doc.block_anchor_line_start, doc.block_cursor_line_start)
	cell_lo = min(doc.block_anchor_cell, doc.block_cursor_cell)
	cell_hi = max(doc.block_anchor_cell, doc.block_cursor_cell)
	return
}

// One byte, by absolute offset. doc.odin's own byte_at is file-private, and
// this file needs the same single-byte peek to tell a real line boundary from
// a synthetic capped one -- an O(log n) tree lookup, not a scan.
@(private = "file")
block_byte_at :: proc(doc: ^Document, i: int) -> u8 {
	one: [1]u8
	base.pt_read(&doc.pt, i, one[:])
	return one[0]
}

// Is `off` the first byte of a logical line -- byte 0, or the byte after a
// '\n'? This is the whole of the draw's row-membership test, and it is what
// removed the per-frame line walk: a rectangle's rows are the logical line
// starts inside [off_lo, off_hi], so a visible row belongs to the rectangle
// exactly when its start falls in that range AND is a real line start.
//
// The second half matters because the viewport splits a logical line longer
// than RENDER_LINE_CAP into several screen rows, each with its own cell-0
// origin (visible_next, doc.odin). Those continuation rows are never preceded
// by a '\n' -- pt_line_end_cap only returns a non-newline offset when it hit
// its cap -- so this rejects them, where the old line-index model included
// them and drew the rectangle's cell range against the wrong 8 KiB of the row.
block_is_line_start :: proc(doc: ^Document, off: int) -> bool {
	return off <= 0 || block_byte_at(doc, off - 1) == '\n'
}

// Byte offset of the line start containing `off`, bounded. This is the ONE way
// a rectangle corner is seeded from a caret or a click -- both gestures call
// it so neither can invent its own resolution.
//
// `ok` is false when pt_line_start_cap reports exact=false: the scan hit
// BLOCK_LINE_STEP_CAP without finding a '\n', so the offset it returned is a
// scan floor and not a line start at all. Callers must refuse
// (.Caret_Unresolved), never guess -- the whole point of anchoring by offset
// is that the anchor is a fact about the buffer, and a floor is not one.
block_line_start_at :: proc(doc: ^Document, off: int) -> (line_start: int, ok: bool) {
	return base.pt_line_start_cap(&doc.pt, off, BLOCK_LINE_STEP_CAP)
}

// Step `d` rows up (negative) or down (positive) from the row starting at
// `from`, returning the row start landed on. Each step is a SINGLE bounded
// scan of at most BLOCK_LINE_STEP_CAP bytes, so the cost is O(|d|) -- the
// rectangle's own height in this call -- and never O(depth in the file).
//
// `ok` is false when a step could not be resolved: pt_line_end_cap stopped at
// a synthetic cap break (the row is longer than one step's budget and its real
// end was never seen), or pt_line_start_cap could not find the previous
// newline within the budget. Refuse rather than answer from a truncated scan,
// the same contract block_row_range's own ok carries.
//
// Running out of DOCUMENT is not truncation and does not refuse: stepping down
// past the last row, or up past the first, simply stops there and reports
// success, exactly as an arrow key at the edge of the buffer does nothing.
@(private = "file")
block_step_lines :: proc(doc: ^Document, from, d: int) -> (start: int, ok: bool) {
	p := from
	for _ in 0 ..< abs(d) {
		if d > 0 {
			e := base.pt_line_end_cap(&doc.pt, p, BLOCK_LINE_STEP_CAP)
			if e >= doc.pt.length {
				break // last row; stop here rather than refuse
			}
			// pt_line_end_cap returns min(length, p+cap) both when it found no
			// '\n' and when a real '\n' sits exactly at the cap boundary (it
			// never reads the byte AT the limit). One byte read tells the two
			// apart exactly, so this neither refuses a row that ends precisely
			// at the budget nor accepts a synthetic break as a line boundary --
			// the same disambiguation next_row_start_capped (doc.odin) makes.
			if block_byte_at(doc, e) != '\n' {
				return from, false
			}
			p = e + 1
		} else {
			if p <= 0 {
				break // first row
			}
			s, exact := base.pt_line_start_cap(&doc.pt, p - 1, BLOCK_LINE_STEP_CAP)
			if !exact {
				return from, false
			}
			p = s
		}
	}
	return p, true
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
// row. `line_start` is the row's byte offset (from block_bounds, a visible-row
// iterator, or block_line_start_at -- never derived here); `cell_lo`/`cell_hi` are the
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

// Caret's own (line start offset, cell) position, for seeding a fresh
// rectangle. Both values come out of the SAME pt_line_start_cap call that
// doc_cursor_col (doc.odin, around line 1847) already makes every frame: the
// line start is the vertical coordinate, and it is also the origin
// line_cell_col needs for the horizontal one. Nothing here counts newlines or
// walks from the document start -- under the old line-number model this proc
// called doc_cursor_line, up to STATUS_LINE_CAP (4 MiB) of count_newlines, to
// produce a coordinate every consumer then had to walk back into an offset.
//
// `ok` is false when pt_line_start_cap reports exact=false: the caret sits
// further than BLOCK_LINE_STEP_CAP from its own line start, so neither the row
// nor the column is a fact. Falling back to 0 while reporting success seeds a
// rectangle at the top of the file instead of at the caret -- a confident
// wrong answer on a large file. The caller must refuse.
@(private = "file")
caret_line_start_cell :: proc(doc: ^Document, t: ^plat.Text) -> (line_start, cell: int, ok: bool) {
	ls, exact := block_line_start_at(doc, doc.cursor)
	if !exact {
		return 0, 0, false
	}
	return ls, line_cell_col(doc, t, ls, doc.cursor), true
}

// Why block_extend refuses, distinct from whether it refused: the two
// refusal reasons need two different user-facing notes (command_dispatch's
// dispatcher, commands.odin), and a bare bool can't carry that. Wrap_On is
// the pre-existing "word-wrap is on" refusal (checked via doc_wraps, so it
// also covers Markdown Split forcing the editor half to wrap); Caret_Unresolved
// covers every endpoint a bounded scan could not turn into a real line start
// -- the caret further than BLOCK_LINE_STEP_CAP from its own line start, or a
// vertical step that ran into a row longer than one step's budget. Filter_On is
// its own variant rather than folding into Wrap_On: in filter mode the visible
// rows are a non-contiguous subset of the document's lines, so a rectangle's
// rows mean something different again -- and telling the user to
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
// state at all) rather than .None in three cases:
//
//   - .Filter_On / .Wrap_On when the view cannot hold a rectangle at all.
//     Wrap turns one logical line into many visual rows, so a (row, cell)
//     rectangle stops describing anything stable the instant it is toggled
//     (see this file's package comment and Document's own field comment) --
//     the gesture must refuse up front rather than build a rectangle whose
//     meaning is about to change under it.
//   - .Caret_Unresolved when an endpoint is not a fact: either there is no
//     rectangle yet and caret_line_start_cell could not resolve the caret's
//     own line start, or the vertical step ran into a row whose end lies past
//     one step's budget. Refusing is correct; guessing is not, because the
//     copy and the edit run through this rectangle.
//
// Nothing is written until BOTH the seed and the step have resolved -- the
// refusal contract is "changes no state at all", and seeding first would leave
// a zero-height rectangle behind when the step then refused.
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
	anchor_off, anchor_cell := doc.block_anchor_line_start, doc.block_anchor_cell
	cursor_off, cursor_cell := doc.block_cursor_line_start, doc.block_cursor_cell
	if !doc.block {
		// No rectangle yet: seed BOTH corners at the caret's own (line start,
		// cell). This call's own delta is then applied to the cursor corner
		// below, same as every later call once the rectangle already exists
		// -- so the very first Alt+Shift+arrow both starts the rectangle at
		// the caret AND moves one step, rather than requiring two presses.
		ls, cell, ok := caret_line_start_cell(doc, t)
		if !ok {
			return .Caret_Unresolved
		}
		anchor_off, anchor_cell = ls, cell
		cursor_off, cursor_cell = ls, cell
	}
	stepped, step_ok := block_step_lines(doc, cursor_off, dline)
	if !step_ok {
		return .Caret_Unresolved
	}
	doc.block = true
	doc.block_anchor_line_start = anchor_off
	doc.block_anchor_cell = anchor_cell
	doc.block_cursor_line_start = stepped
	// Clamp the cell axis at 0 -- there is no column left of the start of a
	// row to extend into, and going negative would make block_bounds' min/max
	// normalisation paper over an already-wrong value rather than the
	// rectangle simply stopping at the edge. The vertical axis needs no clamp
	// of its own: block_step_lines stops at the first and last row of the
	// document by construction, so it can never hand back an offset outside
	// the buffer.
	doc.block_cursor_cell = max(0, cursor_cell + dcell)
	return .None
}

// Seed or replace a column rectangle from BOTH ends at once -- the mouse drag's
// shape, as opposed to block_extend's keyboard shape of stepping the cursor
// corner one delta at a time from wherever the rectangle already is. The
// caller (main.odin's drag path) has already resolved both corners' (line start
// offset, cell) itself -- via cell_at_x for the cell and block_line_start_at for
// the row -- so this proc does no resolution of its own; it only applies the
// refusals block_extend applies, then writes the geometry straight through.
//
// `t` is accepted for the same reason every other block.odin proc takes it
// (interface symmetry with block_extend/block_row_range) even though this
// particular proc has no cell-space walk of its own to do with it -- both ends
// arrive pre-resolved.
//
// A negative offset (either end) is the caller's signal that it could not
// resolve that point: block_line_start_at reported exact=false, so what it
// returned is a scan floor and not a row. Every real line start is >= 0, which
// is what makes -1 available as the sentinel. Cells never carry this signal:
// cell_at_x floors at 0 and cannot fail.
block_set_from_points :: proc(doc: ^Document, t: ^plat.Text, a_off, a_cell, c_off, c_cell: int) -> Block_Refusal {
	if doc.filter {
		return .Filter_On
	}
	if doc_wraps(doc) {
		return .Wrap_On
	}
	if a_off < 0 || c_off < 0 {
		return .Caret_Unresolved
	}
	doc.block = true
	doc.block_anchor_line_start = a_off
	doc.block_anchor_cell = max(0, a_cell)
	doc.block_cursor_line_start = c_off
	doc.block_cursor_cell = max(0, c_cell)
	return .None
}

// --- Task 4: drawing the rectangle ---

// Selection highlight rectangles for a column rectangle's visible rows -- the
// block-select counterpart to doc_selection_rects (doc.odin), same shape, so
// main.odin's draw call picks between the two on block_active(doc). Every
// byte range drawn here comes from block_row_range -- never a second,
// independently-derived cell walk -- because the edit calls the exact same
// procedure on the exact same rows: if this draw and that edit each worked out
// their own byte ranges, they could drift apart, and the user would edit
// something other than what they saw highlighted. See this file's package
// comment for why that single-source rule is the whole point of the feature.
//
// Cost is O(visible rows) and nothing else. Under the line-NUMBER model this
// proc had to turn the rectangle's top line index back into a byte offset by
// walking from byte 0 -- measured at 48ms per frame for a ten-row rectangle at
// line 28,000 of a 500 KiB log, every frame of an Alt+drag, because main.odin's
// frame loop does not wait for messages while the mouse is down. Worse, that
// walk was capped at 512 KiB while a rectangle could be seeded up to 4 MiB
// deep, so a rectangle could be created and then never drawn at all: the user
// got a selection they could not see. Anchoring the rectangle by byte offset
// removes the walk instead of budgeting it -- the rows ARE offsets, so
// membership is a range test plus one byte read (block_is_line_start).
block_selection_rects :: proc(doc: ^Document, t: ^plat.Text, px, char_w: f32, rows: int, out: []plat.Quad) -> int {
	if !block_active(doc) {return 0}
	off_lo, off_hi, cell_lo, cell_hi := block_bounds(doc)

	col := g_theme[.Selection_Doc]
	lh := line_height(px)
	it := visible_begin(doc, t, rows)
	n := 0
	for n < len(out) {
		row, start, _, _, _, wrapped, ok := visible_next(&it)
		if !ok {break}
		// A visible row belongs to the rectangle when its start falls inside
		// the rectangle's own vertical span AND is a real logical line start.
		// The second half is not redundant: a logical line longer than
		// RENDER_LINE_CAP is shown as several capped rows (visible_next,
		// doc.odin), each restarting its cell numbering at 0, so highlighting
		// cells [cell_lo, cell_hi) on a continuation row would paint bytes
		// 8 KiB further along the same line than the rectangle covers. Neither
		// test is line-number arithmetic ("visible row r is line off_lo + r"),
		// so doc.top need not sit at the rectangle's own top row.
		if start < off_lo || start > off_hi {continue}
		if !block_is_line_start(doc, start) {continue}

		byte_lo, byte_hi, pad_cells, rok := block_row_range(doc, t, start, cell_lo, cell_hi)
		if !rok {
			// The row's cell walk ran off the end of BLOCK_ROW_CAP without
			// resolving cell_hi -- block_row_range's own refusal. Drawing
			// this row anyway (as empty, or as far as the walk got) would
			// show a boundary that isn't actually where the rectangle ends
			// on this row; skipping it is the same "a bounded scan that
			// cannot tell it was truncated must never answer as though it
			// saw the whole row" rule the rest of this file follows. The edit
			// must make the identical call and will refuse the row the same
			// way, so nothing is ever edited that wasn't shown selected.
			continue
		}
		if pad_cells > 0 {
			// The row never reached cell_lo -- requirement 2: it
			// contributes nothing to the selection. Padding is reported for
			// an edit to use later, never drawn or applied here.
			continue
		}

		rhs := 0 if wrapped else H_SCROLL
		startcol := min(line_cell_col(doc, t, start, byte_lo), VISIBLE_COLS)
		endcol := min(line_cell_col(doc, t, start, byte_hi), VISIBLE_COLS)
		x0 := col_x(char_w, startcol, rhs)
		x1 := col_x(char_w, endcol, rhs)
		// A zero-width rectangle (cell_lo == cell_hi) resolves byte_lo ==
		// byte_hi on every row it reaches -- the "N carets in one column"
		// affordance (requirement 1) -- and a non-zero rectangle can still
		// collapse to zero width on a row that runs out exactly at cell_lo.
		// The floor turns that into a visible bar rather than an invisible
		// 0-px quad, and it is sx(2) rather than a raw 2 because here the bar
		// IS the affordance for the feature's most-used case: it must match
		// the real caret (main.odin's `size = {sx(2), line_h}`) or at 200% DPI
		// the N carets render half the width of the one they stand in for.
		// doc_selection_rects (doc.odin) uses a raw 2 for its own floor -- but
		// there the floor is a degenerate case nobody looks at, not the point
		// of the draw, which is why copying the number here was wrong.
		out[n] = {pos = {x0, row_rect_y(px, row)}, size = {max(x1 - x0, sx(2)), lh}, color = col}
		n += 1
	}
	return n
}

// --- Task 5: copy and cut ---

// Rows a rectangle's copy or cut may walk before refusing the whole
// operation rather than build an unbounded result on the main thread.
// block_row_range and block_step_lines already bound the cost of ONE row and
// ONE vertical step; this bounds how many of them a single Copy/Cut may add
// up, the same way BLOCK_ROW_CAP and BLOCK_LINE_STEP_CAP bound the other two
// axes. Task 6 uses the same constant for its own edit for the identical
// reason: whatever one rectangle-wide operation can afford, they all can --
// and an edit's per-row work (resolve, plus a splice that shifts every byte
// offset after it) is strictly more expensive than a delete's, so this cap
// is chosen against the delete measurement with headroom for that, not
// against the cheapest of the three operations that share it.
//
// Measured on this branch, line 45,000 of a ~1.8 MB file (100,000 rows of
// an 18-byte log line -- the shape of the reviewer's own fixture):
//
//   OLD cap (10,000 rows) + the double block_row_range resolve this task
//   removed:  release (-o:speed) 84.8ms, debug 150.4ms -- most of a frame's
//   worth of freeze on a single keypress. (The reviewer's own numbers, a
//   different file and line: 131ms release / 308ms debug -- same order.)
//
//   THIS cap (2,000 rows), single-pass resolve (block_row_range once per
//   row, not twice): release 9.0ms, debug 10.0ms -- see blocktest's own
//   MEDIUM 2 case (test_modes.odin), which asserts <60ms against this exact
//   fixture so a future regression in either the cap or the single-pass
//   change trips it.
//
// 2,000 was picked directly off the reviewer's measured curve (~13 us/row):
// the largest round number still comfortably under one frame at 60 Hz, with
// headroom left over for Task 6's edit, whose per-row work (resolve, plus a
// splice that shifts every byte offset after it) is strictly more expensive
// than a delete's -- it shares this cap rather than needing a smaller one of
// its own, but its own worst case should be re-measured against it when it
// lands, not assumed from the delete's numbers above.
BLOCK_EDIT_MAX_LINES :: 2_000

// The rectangle's rows as text, one line per spanned row, joined with the
// document's OWN line ending -- never a hard-coded '\n'. doc_insert_newline
// (doc.odin) writes doc.eol's own bytes for Enter for the identical reason: a
// CRLF file that ever picks up a bare '\n' mixes line endings for good, and
// that exact corruption shape has already shipped once here as a save-path
// bug. Copying rows out of a CRLF file and pasting them back must not
// reintroduce it one layer up.
//
// A row too short to reach cell_lo still contributes a line -- empty, not
// skipped -- so the rectangle's SHAPE survives the round trip: N spanned rows
// always produce N lines. This is deliberately the OPPOSITE of what
// block_selection_rects does with such a row (skips it -- nothing to paint);
// the draw and the copy have different jobs even though both call
// block_row_range for the same row, because only the copy has to hand back
// something a paste can reconstruct the rectangle's height from.
//
// Refuses (ok=false, "" text) rather than answer with a partial rectangle:
//
//   - any spanned row's own block_row_range refuses. A bounded scan that
//     could not resolve a row is not a fact this proc can hand to the
//     clipboard -- the project's rule is refuse, not guess, and a confident
//     wrong answer from a truncated scan is the shape that has shipped seven
//     times in this codebase already.
//   - the rectangle spans more than BLOCK_EDIT_MAX_LINES rows. Building an
//     unbounded string on the main thread is the same freeze class task 4
//     fixed for the draw (48ms/frame at line 28,000 of an ordinary log,
//     every frame of a live drag); the copy must not reintroduce it one
//     layer up just because it runs once per keypress instead of once per
//     frame -- a rectangle CAN span the whole file.
block_text :: proc(doc: ^Document, t: ^plat.Text, allocator := context.temp_allocator) -> (string, bool) {
	if !block_active(doc) {return "", false}
	off_lo, off_hi, cell_lo, cell_hi := block_bounds(doc)
	eol := "\r\n" if doc.eol == .CRLF else "\n"

	b := strings.builder_make(allocator)
	line_start := off_lo
	rows := 0
	for {
		rows += 1
		if rows > BLOCK_EDIT_MAX_LINES {return "", false}

		byte_lo, byte_hi, _, ok := block_row_range(doc, t, line_start, cell_lo, cell_hi)
		if !ok {return "", false}

		if rows > 1 {strings.write_string(&b, eol)}
		if byte_hi > byte_lo {
			buf := make([]u8, byte_hi - byte_lo, context.temp_allocator)
			base.pt_read(&doc.pt, byte_lo, buf)
			strings.write_string(&b, string(buf))
		}

		if line_start >= off_hi {break}
		next, step_ok := block_step_lines(doc, line_start, 1)
		if !step_ok {return "", false}
		line_start = next
	}
	return strings.to_string(b), true
}

// Delete the rectangle's own cell range on every row it spans, as ONE undo
// step, then collapse the block to a caret at the vanished rectangle's own
// top-left corner -- off_lo's own resolved left edge, whether or not that
// row itself had anything to delete. This is `.Cut`'s other half
// (commands.odin) -- block_text supplies the clipboard text, this supplies
// the delete -- kept as two procs, called in that order, so a copy
// block_text itself refused (ok=false) never reaches this proc at all: the
// caller checks block_text's own result first and skips the delete entirely
// on refusal, exactly like every other refusal in this file changes no
// state. The block is cleared on every path out of this proc that doesn't
// refuse -- including the one where nothing was deleted -- so a Cut always
// collapses the rectangle to a caret, the same as it does on a normal
// linear selection; nothing here may fall through to a live, stale block.
//
// Row starts are collected FIRST via block_step_lines alone (cheap: no cell
// walk), and every one of them is resolved through block_row_range exactly
// ONCE, before any byte is deleted, into `ranges` -- both the refusal check
// block_text also makes (a row that cannot be resolved refuses the whole
// operation, nothing deleted -- a half-deleted rectangle would be worse
// than a refused copy, because there would be no surviving text to paste
// back over the gap) and the byte range the delete loop below then reuses
// verbatim. The old code resolved every row TWICE -- once to validate, once
// to delete -- for identical results both times, since nothing touches the
// buffer between the two passes; that redundant second pass was ~25% of a
// Cut's cost at the cap (see BLOCK_EDIT_MAX_LINES's own comment).
//
// Before opening the undo batch, `any_bytes` asks whether any row actually
// has something to remove. A rectangle that lies entirely past the end of
// every row it spans resolves byte_hi == byte_lo on all of them -- block_text
// still returns non-empty text for two or more such rows (an eol-joined run
// of empty lines), so `.Cut`'s `s != ""` clipboard guard passes and this proc
// still gets called. If it is called, an empty rectangle is still a legitimate
// thing to have copied (block_text's own contract: a too-short row
// contributes an empty line, not a skipped one, so the copy is arguably worth
// keeping on the clipboard) -- so the clipboard write in commands.odin is left
// alone. But doc_batch_begin unconditionally calls push_undo, which marks the
// document modified and clears the redo stack even when the batch that
// follows deletes nothing. Skipping the batch entirely when there is nothing
// to delete is the only way an accidental Cut on an all-short rectangle stays
// a no-op: the file is not dirtied, no phantom undo entry appears, and the
// redo stack survives.
//
// Deletion itself is applied HIGHEST OFFSET FIRST, the identical rule
// find_replace_all (find.odin) applies to Replace All: deleting a row shifts
// every byte offset AFTER it and never one before it, so processing top-down
// would invalidate every row still to come. Bottom-up, each row's own
// line_start is still a fact about the buffer when its turn arrives, because
// nothing touched so far has deleted anything before it. `ranges[0]` is
// off_lo's own row -- the rectangle's topmost -- and nothing below it can
// ever shift its offset, so it is read directly rather than relying on
// del_sel_raw's own cursor placement to land there: when off_lo's row is
// itself too short to have anything deleted, the bottom-up loop simply never
// touches doc.cursor/anchor for it, and the caret would otherwise be left
// wherever the last row WITH a deletion put it -- not the rectangle's
// top-left at all. Setting it explicitly after the loop is correct whether
// or not off_lo's own row had a deletion: when it did, del_sel_raw already
// put the caret at the same byte_lo, so this is a no-op; when it didn't, this
// is the only thing that puts the caret there.
block_cut_delete :: proc(doc: ^Document, t: ^plat.Text) -> bool {
	if !block_active(doc) {return false}
	off_lo, off_hi, cell_lo, cell_hi := block_bounds(doc)

	starts := make([dynamic]int, 0, 64, context.temp_allocator)
	line_start := off_lo
	for {
		if len(starts) >= BLOCK_EDIT_MAX_LINES {return false}
		append(&starts, line_start)
		if line_start >= off_hi {break}
		next, step_ok := block_step_lines(doc, line_start, 1)
		if !step_ok {return false}
		line_start = next
	}

	los := make([]int, len(starts), context.temp_allocator)
	his := make([]int, len(starts), context.temp_allocator)
	any_bytes := false
	for ls, i in starts {
		lo, hi, _, ok := block_row_range(doc, t, ls, cell_lo, cell_hi)
		if !ok {return false}
		los[i], his[i] = lo, hi
		if hi > lo {any_bytes = true}
	}

	if !any_bytes {
		// Nothing on any row falls in the rectangle -- refuse the batch
		// itself rather than open one that would delete zero bytes. See
		// this proc's own comment: doc_batch_begin's push_undo would dirty
		// a clean file and destroy the redo stack for a no-op Cut otherwise.
		block_clear(doc)
		return true
	}

	doc_batch_begin(doc, .Delete)
	edited := 0
	for i := len(starts) - 1; i >= 0; i -= 1 {
		if his[i] > los[i] {
			doc.anchor = los[i]
			doc.cursor = his[i]
			doc_replace_sel(doc, nil)
			edited += 1
		}
	}
	// off_lo's own row (index 0) never shifts from deletions below it --
	// see this proc's own comment for why this must be set unconditionally,
	// not left to del_sel_raw's cursor placement from whichever row the
	// bottom-up loop happened to touch last.
	doc.anchor = los[0]
	doc.cursor = los[0]
	doc_batch_end(doc, edited) // rows actually edited, not rows spanned
	block_clear(doc)
	return true
}
