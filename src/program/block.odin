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
// (RENDER_LINE_CAP, doc.odin) rather than inventing a second number: a block
// rectangle is only ever drawn over visible rows, so whatever the renderer
// can already afford to scan for one row is exactly what this can afford too.
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
// same way: treat it as truncated. A wrong "this is truncated" costs one row
// the answer once; a wrong "this is the real end" is the confident-wrong-
// answer shape this task exists to rule out.
@(private = "file")
block_row_end :: proc(doc: ^Document, line_start: int) -> (row_end: int, ok: bool) {
	row_end = base.pt_line_end_cap(&doc.pt, line_start, BLOCK_ROW_CAP)
	if row_end == line_start + BLOCK_ROW_CAP && row_end < doc.pt.length {
		return row_end, false
	}
	return row_end, true
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
	row_end, resolved := block_row_end(doc, line_start)
	if !resolved {
		return 0, 0, 0, false
	}

	buf: [4096]u8
	p := line_start
	cell := 0
	lo_found, hi_found := false, false

	outer: for p < row_end {
		n := base.pt_read(&doc.pt, p, buf[:min(len(buf), row_end - p)])
		if n == 0 {break}
		i := 0
		for i < n {
			r, sz := utf8.decode_rune(buf[i:n])
			if sz == 0 {sz = 1}
			if i + sz > n && p + n < row_end {break} // rune straddles the chunk; refill
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

// Byte offset of the start of 0-based logical line `n`. Walks FORWARD from 0
// by a known, small line count -- the doc_goto_line idiom (doc.odin) -- which
// is why this is safe where base.pt_line_start is not: pt_line_start scans
// BACKWARD from an arbitrary offset with no bound, the exact hazard
// doc.odin:1853 documents, while stepping forward through pt_next_line_start
// costs only the lines actually walked. Added here because no "line N -> byte
// offset" helper existed anywhere in the tree before this task, and the
// keyboard and mouse gestures (later tasks) both need one to turn a target
// logical line into the line_start block_row_range takes.
doc_line_start_of_index :: proc(doc: ^Document, n: int) -> int {
	p := 0
	for _ in 0 ..< n {
		np := base.pt_next_line_start(&doc.pt, p)
		if np == p {break}
		p = np
	}
	return p
}
