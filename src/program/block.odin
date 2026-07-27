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
	doc.last_block_run = 0 // ending the rectangle ends its undo run
}

// Fresh-press state transition for a rectangle left over from an earlier
// gesture: main.odin's mouse-press handler calls this before it does
// anything else with the click. Whether Alt is held at THIS press is
// deliberately NOT consulted -- this proc took an `alt` parameter until the
// whole-branch review pointed out no line of it ever read the value, which
// is exactly the shape of the bug it was written to fix and so worth saying
// once rather than carrying a parameter that reads as though it gates
// something. Before that fix the clear only ran on the branch that also
// established Alt was NOT held, so an Alt+click that never turned into a
// drag (never exceeded the slop in main.odin's drag-vs-click check) left the
// previous rectangle live: the click looked like it had been silently
// ignored. Every fresh press starts a new gesture regardless of Alt, and a
// press that DOES become a real Alt+drag rebuilds the rectangle from scratch
// via block_set_from_points (both corners, not an extension of whatever was
// here), so clearing unconditionally here costs nothing.
//
// Split out from main.odin's inline press handler -- which cannot be driven
// headlessly, there is no seam to simulate a real WM_LBUTTONDOWN -- so this
// one decision has a seam blocktest can exercise on its own.
block_press_clear :: proc(doc: ^Document) {
	if block_active(doc) {
		block_clear(doc)
	}
}

// Is the current view one in which a live rectangle no longer describes what
// the user can see? Belt and braces with the toggles that are supposed to
// clear the block outright (.Find_Toggle_Filter, .Toggle_Wrap, .Toggle_Preview,
// .Toggle_Table -- commands.odin), and the second line of defence for
// whichever of them ever fails to.
//
// doc.filter: the visible rows are a non-contiguous subset of the document's
// lines, while every consumer here resolves rows by walking the buffer's own
// logical lines (block_step_lines, block_row_range) -- so a rectangle made
// before Ctrl+L would read and edit rows the filtered view is currently
// hiding.
//
// doc_wraps: one logical line becomes several visual rows, so the rectangle
// is DRAWN against visual rows and EDITED against logical lines, and the two
// diverge past the first wrap point. Both gestures already refuse to create a
// rectangle under wrap (block_extend / block_set_from_points' .Wrap_On), but
// a rectangle made BEFORE wrap turned on survives unless something clears it
// -- and Markdown Split turns wrap on via doc_wraps without the user ever
// touching Alt+Z. That is the hole the whole-branch review found: .Toggle_Wrap
// cleared the block, .Toggle_Preview did not, and these four operations
// guarded only on doc.filter.
@(private = "file")
block_stale_view :: proc(doc: ^Document) -> bool {
	return doc.filter || doc_wraps(doc)
}

// Collapse the LINEAR selection (doc.anchor..doc.cursor) to a caret, so a
// rectangle and a linear span can never both be live.
//
// This is an invariant, not a tidy-up. Newtpad carries two selection models
// side by side, and exactly one of them is ever DRAWN: main.odin picks
// block_selection_rects when block_active(doc) and doc_selection_rects
// otherwise. So a linear span that coexists with a rectangle is a selection
// the user cannot see -- and the commands that drop the rectangle
// (.Insert_Newline, .Paste, .Delete_Word_Back, .Move_Line_*, via
// command_dispatch's block-clear branch) then run against doc.anchor..cursor,
// and doc_insert_text deletes the selection first. The whole-branch review's
// reproduction: Alt+drag a 4-cell-wide rectangle down 50 lines, then Ctrl+V.
// The mouse path set doc.cursor to the pointer on every drag frame while
// doc.anchor stayed at the press point, so all 50 lines were replaced by the
// clipboard. Shift-select, then Alt+Shift+Right, reached the same state from
// the keyboard.
//
// Every path that establishes a rectangle calls this, so the invariant holds
// by construction rather than by each command remembering to check. Neither
// gesture may DEGRADE to a linear selection when it refuses: block_extend's
// refusals never touch doc.cursor/anchor at all (command_dispatch's
// Block_Extend_* cases only ever call block_extend_dispatch, nothing else),
// and block_drag_update (this file) now owns the mouse drag's cursor commit
// for exactly this reason -- a refusal there leaves doc.cursor untouched
// too, rather than the pointer-tracking assignment main.odin used to make
// unconditionally before the refusal was even checked. A live pass caught the
// old mouse-side behaviour: Alt+drag under word wrap was refused as it should
// be, but doc.cursor kept tracking the pointer anyway, leaving a full linear
// selection behind that then outlived the gesture -- and even outlived
// toggling wrap back off, because a real selection had been drawn.
block_collapse_linear :: proc(doc: ^Document) {
	doc.anchor = doc.cursor
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
//
// The trailing CR of a CRLF break is peeled off with pt_row_vis_end -- the
// tree's single definition of where a rendered row's content stops, and the
// one every other consumer (the caret, the click, the wrap budget, the column
// readout) already uses. Without it a CRLF row's last cell was the CR itself:
// a phantom cell with no glyph that the rectangle could cover, so a column cut
// or a column edit at the end of a line deleted one half of the line break and
// left a bare LF in an otherwise-CRLF file. `line_end` is false when the scan
// stopped at the cap, because there a CR really is ordinary content -- exactly
// the distinction pt_row_vis_end's own comment draws, which is why `truncated`
// is computed from the raw end BEFORE the peel.
@(private = "file")
block_row_end :: proc(doc: ^Document, line_start: int) -> (row_end: int, truncated: bool) {
	raw := base.pt_line_end_cap(&doc.pt, line_start, BLOCK_ROW_CAP)
	truncated = raw == line_start + BLOCK_ROW_CAP && raw < doc.pt.length
	row_end = base.pt_row_vis_end(&doc.pt, line_start, raw, !truncated)
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
// the pre-existing "word-wrap is on" refusal; Caret_Unresolved
// covers every endpoint a bounded scan could not turn into a real line start
// -- the caret further than BLOCK_LINE_STEP_CAP from its own line start, or a
// vertical step that ran into a row longer than one step's budget. Filter_On is
// its own variant rather than folding into Wrap_On: in filter mode the visible
// rows are a non-contiguous subset of the document's lines, so a rectangle's
// rows mean something different again -- and telling the user to
// press Alt+Z (the word-wrap toggle) when the real problem is the filter view
// would send them chasing the wrong control.
//
// Split_On is its own variant for exactly the same reason, split out from
// Wrap_On rather than folded into it: doc_wraps (doc.odin) is one bool because
// every ordinary wrap-geometry check (H_SCROLL, doc_cursor_col, eff_wrap_at...)
// genuinely does not care which of the two forced wrapping -- but the refusal
// note does, because the two causes have two different fixes. A live-pass
// report caught the old single Wrap_On note ("press Alt+Z") being shown in
// Markdown Split, where Alt+Z does nothing at all -- Ctrl+M is the control
// that actually turns Split (and so the forced wrap) off. block_wrap_refusal
// below is the one place that decides between them, so the note-choosing
// switches in commands.odin and main.odin stay a plain one-to-one map and
// never re-derive the distinction themselves.
Block_Refusal :: enum {
	None,
	Wrap_On,
	Caret_Unresolved,
	Filter_On,
	Split_On,
}

// The single decision behind Wrap_On vs Split_On -- see Block_Refusal's own
// comment for why this must be made in exactly one place. Split is checked
// first: a document can have doc.wrap=true from before Ctrl+M was ever
// pressed, and Split is the more specific, more actionable cause to report
// when both happen to be true at once.
@(private = "file")
block_wrap_refusal :: proc(doc: ^Document) -> Block_Refusal {
	if doc.kind == .Text && doc.md_mode == .Split {
		return .Split_On
	}
	if doc.wrap {
		return .Wrap_On
	}
	return .None
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
	if r := block_wrap_refusal(doc); r != .None {
		return r
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
	doc.block_run += 1
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
	// A rectangle now exists, so no linear selection may -- see
	// block_collapse_linear. Shift-select some text and then press
	// Alt+Shift+Right and, before this, the invisible linear span survived
	// underneath the rectangle for the next Enter/Tab/Paste to delete.
	block_collapse_linear(doc)
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
	if r := block_wrap_refusal(doc); r != .None {
		return r
	}
	if a_off < 0 || c_off < 0 {
		return .Caret_Unresolved
	}
	doc.block_run += 1
	doc.block = true
	doc.block_anchor_line_start = a_off
	doc.block_anchor_cell = max(0, a_cell)
	doc.block_cursor_line_start = c_off
	doc.block_cursor_cell = max(0, c_cell)
	// Same invariant as block_extend's, and this is the path the reviewer's
	// own reproduction took: main.odin sets doc.cursor to the pointer on every
	// drag frame but leaves doc.anchor at the press point, so without this an
	// Alt+drag left a full linear span behind the rectangle -- unpainted,
	// because the draw swaps to block_selection_rects -- for the next Ctrl+V
	// to overwrite. See block_collapse_linear.
	block_collapse_linear(doc)
	return .None
}

// --- the Alt+drag gesture's own latched state ---

// Everything main.odin's frame loop has to remember BETWEEN the mouse press
// and the drag frames that follow it. These were four inline locals in that
// loop -- the third such latch group there -- and folding them into one named
// struct beside the procedures that consume them is what keeps the planned
// renderer/ui extraction from having to untangle them from the frame loop
// first (whole-branch review LOW 7).
//
// `alt` is latched at press time and never resampled per frame: sampling
// key_alt_down() every frame would mean releasing Alt mid-drag silently turns
// a rectangle into a linear selection, and pressing it mid-drag would turn a
// linear drag into a rectangle -- neither is how a held modifier behaves once
// a gesture has started.
//
// `anchor_off`/`anchor_cell` are the anchor corner's (line start byte offset,
// cell), resolved once at the press exactly the way the cursor corner is
// resolved on every drag frame. -1 in the offset means unresolved
// (block_line_start_at's exact=false), which block_set_from_points reads as
// its .Caret_Unresolved sentinel.
//
// `refusal_noted` is why a refused gesture posts its note once rather than on
// every mouse-move frame it continues: app_note (app.odin) does a delete plus
// a strings.clone per call.
Block_Drag :: struct {
	alt:           bool,
	anchor_off:    int,
	anchor_cell:   int,
	refusal_noted: bool,
}

// A fresh mouse press: latch the gesture's modifier, clear whatever rectangle
// the last gesture left, and -- only when Alt is held -- resolve the anchor
// corner. `cell` is the press's own column, from the caller's cell_at_x (the
// same primitive the draw and the hit-test use; this file does not reach for
// the pointer position itself). doc.cursor must already have been moved to the
// press point, which is what the row is resolved from.
block_drag_press :: proc(d: ^Block_Drag, doc: ^Document, alt: bool, cell: int) {
	d.alt = alt
	d.refusal_noted = false // fresh gesture, fresh right to one note
	// Every fresh press ends whatever rectangle came before, Alt or not --
	// see block_press_clear's own comment for why Alt held at press time must
	// not save a stale rectangle from a click that never becomes a drag.
	block_press_clear(doc)
	if alt {
		ls, ok := block_line_start_at(doc, doc.cursor)
		d.anchor_off = ls if ok else -1
		d.anchor_cell = cell
	}
}

// One frame of a drag, given the pointer's row-resolving byte offset
// (`cursor_at`, from the caller's doc_pos_at -- the same primitive that
// resolves a plain click) and its column cell. Does nothing at all when the
// gesture is not an Alt+drag beyond committing the cursor, so a plain drag
// pays neither the row resolve nor the rectangle write.
//
// This proc OWNS whether doc.cursor actually moves to the pointer this frame,
// not just whether a rectangle gets built -- a plain (non-Alt) drag always
// commits, tracking the pointer the way a linear selection always has; an
// Alt-drag commits ONLY when the rectangle build succeeds. That is the fix for
// a live-pass finding: main.odin used to set doc.cursor to the pointer before
// checking the refusal, so a refused Alt-drag (wrap on, filter on, an
// unresolvable row) still moved the cursor every frame and degraded into an
// ordinary linear selection nobody asked for -- one that then outlived the
// very gesture that produced it, surviving even after the refusing condition
// (e.g. wrap) was toggled back off. A refused Alt-drag must instead leave
// doc.cursor exactly where this proc found it: no rectangle (block_set_from_
// points already guarantees that on refusal) and now no cursor move either.
// The press itself still moves the caret unconditionally -- main.odin's
// mouse_pressed case does that, same as it does for a plain click -- only the
// DRAG's extension is withheld once Alt has been refused.
//
// Returns the refusal AND whether the caller should post a note for it --
// `note` is true only on the FIRST refusal of a gesture, which is the whole
// job of the latch. The two are separate because this file has never imported
// the App type (see the package comment's layering) and so cannot call
// app_note itself; the caller owns the wording, this owns the once-per-gesture
// decision.
//
// The row is resolved by the same block_line_start_at the press used, so both
// corners of a drag come from one procedure -- a bounded backward scan to the
// nearest newline, the same call doc_cursor_col already makes every frame for
// the status bar's "Col". It replaced a doc_cursor_line that counted newlines
// from byte 0 (up to STATUS_LINE_CAP = 4 MiB, measured ~3ms) on every
// mouse-move frame and produced a line NUMBER the draw then had to walk back
// into an offset.
block_drag_update :: proc(d: ^Block_Drag, doc: ^Document, t: ^plat.Text, cursor_at, cell: int) -> (refusal: Block_Refusal, note: bool) {
	if !d.alt {
		doc.cursor = cursor_at
		return .None, false
	}
	prev_cursor := doc.cursor
	// Tentative: block_set_from_points' block_collapse_linear reads doc.cursor
	// to decide where the (invisible) linear span collapses to on success, so
	// doc.cursor must already be at the pointer by the time that call runs --
	// rolled back below if the call refuses.
	doc.cursor = cursor_at
	ls, ok := block_line_start_at(doc, cursor_at)
	cur_off := ls if ok else -1
	refusal = block_set_from_points(doc, t, d.anchor_off, d.anchor_cell, cur_off, cell)
	if refusal != .None {
		doc.cursor = prev_cursor // undo the tentative move -- see the header comment
		if !d.refusal_noted {
			d.refusal_noted = true
			note = true
		}
	}
	return
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
	// Wrap is the same class of hazard as doc.filter, and the four operations
	// that share this guard say so in one place: see block_stale_view.
	if block_stale_view(doc) {return 0}
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
//   A LATER cap of 2,000 rows, single-pass resolve (block_row_range once per
//   row, not twice): release 9.0ms, debug 10.0ms for the FIRST press on a
//   pristine piece tree.
//
// That first-press number is the wrong thing to have sized this cap against.
// A held key -- Backspace, Delete, or retyping the same column repeatedly --
// sends the identical edit through this cap once per repeat, and each press
// splices every row in the rectangle again, fragmenting the piece tree
// further; every later press pays more to walk it. The 2,000-row cap's own
// COST TEST only ever measured press #0, so it could not see this. Re-measured
// as consecutive presses of block_replace over a live 2,000-row rectangle
// (same fixture, release build):
//
//   press 1: 7.9ms   press 5: 29.2ms   press 10: 50.2ms   press 20: 69.5ms
//   press 24: 77.0ms, still climbing -- against a ~25ms budget (one frame at
//   60Hz with headroom for everything else a frame does), a held key at 2,000
//   rows blows the budget by press 2 and is nearly triple it by press 20.
//
// DECISION: lower the cap rather than keep 2,000 and merely document the
// degradation -- the whole point of a cap here is that the user never feels
// it, and a documented-but-live 70ms stall on a held key fails that. Re-run
// at smaller caps (same fixture, same held-key loop, release build):
//
//   cap 500: press 1  2.0ms   press 10 12.6ms   press 20 16.1ms   press 30 26.8ms (over budget)
//   cap 300: press 1  1.1ms   press 10  4.9ms   press 20  8.2ms   press 50 13.6ms (still comfortably under)
//
// 300 is the chosen cap: press 20 -- a sustained-but-not-extreme held key --
// costs ~8ms (RELEASE build) at 300 rows, and even 50 consecutive presses (a
// key held for a second or two at typematic repeat rates) stay under 14ms,
// versus 500 rows crossing the 25ms budget by press 30 and 2,000 rows blowing
// through it by press 2. This does shrink the largest rectangle a single
// Copy/Cut/edit can span from 2,000 rows to 300 -- but 300 rows is already
// far more than a column edit is used for in practice (block_test_w's own
// comment: "typing '// ' down a column is three keystrokes"), and an
// unusable stall on every held key is a worse cost than refusing a rectangle
// nobody was going to hold a key over anyway.
//
// blocktest's own steady-state case (test_modes.odin, MEDIUM/AD) asserts on
// press 20, not press 1, so a future regression in either direction --
// raising the cap back up, or reverting to measuring only the first press --
// trips it. Its own threshold is 50ms, not the ~25ms release budget above:
// DEBUG is measurably slower per splice (press 20 at this cap measured
// 31.8ms debug against 8.2ms release on this machine -- the headless test
// modes only ever run as a debug build's console mode day to day), so the
// test's bound has to clear debug's real number with margin while still
// sitting below what press 20 costs at the OLD 2,000-row cap in either build
// (76.3ms release / 318.8ms debug, measured by temporarily restoring the old
// cap) -- otherwise a regression back to 2,000 would slip through in debug
// even though it demonstrably fails the actual budget. 50ms is comfortably
// inside that gap on both builds; the ~25ms figure above is the real,
// user-facing claim about the shipped (release) exe, which is what the
// comment's own curve was measured against.
BLOCK_EDIT_MAX_LINES :: 300

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
	// Belt and braces with the view toggles clearing the block (commands.odin):
	// both gestures already refuse to CREATE a rectangle in filter view or
	// under wrap (this file's own Filter_On / Wrap_On refusals), but a
	// rectangle made BEFORE the toggle survives unless something clears it,
	// and every consumer here resolves rows by walking the buffer's own
	// logical lines -- never the filtered or wrapped view -- so it would copy
	// rows the user cannot currently see, or cell ranges taken from a row that
	// is no longer what is drawn. See block_stale_view.
	if block_stale_view(doc) {return "", false}
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
	// See block_text's own comment and block_stale_view: refuse rather than
	// delete rows the filtered view is currently hiding from the user, or a
	// cell range that a wrapped view is drawing somewhere other than where
	// this would delete it.
	if block_stale_view(doc) {return false}
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

// --- Task 6: editing across the rectangle ---

// Every rectangle-wide edit -- typing over the rectangle, Backspace, Delete --
// runs through this one procedure, for the same reason block_row_range is the
// one place cells become bytes: the three entry points differ only in which
// cell range they touch, what they put back, and the column they leave the
// rectangle in. Two independent bottom-up splice loops would eventually
// disagree about the order they apply in, and the failure mode of that
// disagreement is a silently corrupted file, not a crash.
//
// `edit_lo`/`edit_hi` are the CELL range to replace on every spanned row --
// deliberately a parameter rather than block_bounds' own cells, because
// Backspace on a zero-width rectangle at cell c edits [c-1, c), which is not
// the rectangle. `text` is what replaces it (empty for a delete). `new_cell` is
// the column the rectangle is left sitting in afterwards.
//
// Three refusals, all of them leaving the buffer byte-identical and the
// rectangle untouched, because a rectangular edit that only partly happened is
// unrecoverable-looking damage spread across a file the user cannot easily
// inspect -- worse than the keystroke appearing to do nothing:
//
//   - more than BLOCK_EDIT_MAX_LINES rows. Checked while collecting the row
//     starts, so it costs one cheap step per row and refuses BEFORE any
//     cell-walk, let alone any write.
//   - any row block_row_range could not resolve. Same rule the copy and the
//     cut already follow: a bounded scan that cannot tell it was truncated
//     must never answer as though it saw the whole row.
//   - (not a refusal but the same discipline) nothing on any row would
//     actually change: no batch is opened at all. doc_batch_begin's push_undo
//     marks the document modified and clears the redo stack unconditionally,
//     so opening one for a no-op dirties a clean file and destroys the user's
//     redo history with nothing to show for it -- the exact bug the Cut path
//     shipped and fixed one task ago.
//
// ORDER. Writes are applied HIGHEST OFFSET FIRST, the identical rule
// block_cut_delete and find_replace_all (find.odin) apply: splicing a row
// shifts every byte offset after it and never one before it, so a top-down
// pass would hand every remaining row an offset that was a fact about the
// buffer before the pass started and is not one now. Bottom-up, each row's own
// range is still valid when its turn arrives. This is not a performance
// choice; top-down corrupts, and it corrupts silently.
//
// PADDING. A row too short to reach edit_lo reports pad_cells, and this is the
// ONLY place in the feature that acts on it: exactly that many spaces are
// written before the inserted text so the edit lands in the same column on
// every row. Without it, block-prefixing a ragged file silently skips every
// short row -- which is most of the point of the feature. Padding applies only
// when there is text to insert: a delete has no column to reach.
@(private = "file")
block_apply :: proc(doc: ^Document, t: ^plat.Text, edit_lo, edit_hi: int, text: []u8, new_cell: int, kind: Edit_Kind) -> bool {
	if !block_active(doc) {return false}
	// See block_text's own comment and block_stale_view. block_apply is the
	// single choke point block_replace and block_delete both funnel through,
	// so one guard here covers both.
	if block_stale_view(doc) {return false}
	off_lo, off_hi, _, _ := block_bounds(doc)

	// Row starts first, by the cheap vertical walk alone (no cell walk yet), so
	// the cap refuses before anything more expensive happens. block_step_lines
	// is the only row walk in this file and this is not allowed to become a
	// second one.
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

	// Every row resolved exactly ONCE, before any byte is written -- both the
	// refusal check and the range the write loop below reuses verbatim. Nothing
	// touches the buffer between the two loops, so a second resolve would
	// return identical answers for ~25% of the operation's cost (see
	// BLOCK_EDIT_MAX_LINES' own comment for the measurement that established
	// that).
	n := len(starts)
	los := make([]int, n, context.temp_allocator)
	his := make([]int, n, context.temp_allocator)
	pads := make([]int, n, context.temp_allocator)
	any_change := false
	for ls, i in starts {
		lo, hi, pad, ok := block_row_range(doc, t, ls, edit_lo, edit_hi)
		if !ok {return false}
		los[i], his[i] = lo, hi
		pads[i] = pad if len(text) > 0 else 0
		if hi > lo || len(text) > 0 {any_change = true}
	}
	if !any_change {
		// A delete whose cell range lies past the end of every spanned row.
		// Leave the rectangle exactly as it was: the keystroke did nothing, and
		// nothing is the honest result -- see this proc's own comment for why
		// no batch may be opened here.
		return true
	}

	// Net bytes the rows ABOVE the rectangle's last row add or remove. The top
	// row's own start can never move (every write is at or below it), so this
	// is the whole correction the bottom corner needs afterwards. Computed from
	// the pre-edit ranges rather than observed during the loop so it reads as
	// the arithmetic it is.
	shift := 0
	for i in 0 ..< n - 1 {
		if len(text) > 0 {
			shift += pads[i] + len(text) - (his[i] - los[i])
		} else {
			shift -= his[i] - los[i]
		}
	}

	doc_batch_begin_run(doc, kind, doc.block_run)
	edited := 0
	ins := make([dynamic]u8, 0, len(text) + 8, context.temp_allocator)
	for i := n - 1; i >= 0; i -= 1 {
		if len(text) == 0 {
			if his[i] <= los[i] {continue} // nothing of this row is in the rectangle
			doc.anchor, doc.cursor = los[i], his[i]
			doc_replace_sel(doc, nil)
			edited += 1
			continue
		}
		clear(&ins)
		for _ in 0 ..< pads[i] {append(&ins, ' ')}
		append(&ins, ..text)
		doc.anchor, doc.cursor = los[i], his[i]
		doc_replace_sel(doc, ins[:], kind)
		edited += 1
	}

	// The caret follows the TOP row, whose offsets nothing below it could
	// shift: just past what was inserted there, or at the resolved left edge
	// when this was a delete. Set unconditionally rather than left to whatever
	// the bottom-up loop's last row happened to leave behind -- when the top
	// row itself had nothing to edit, the loop never touched doc.cursor for it
	// at all (the LOW 3 finding, block_cut_delete's own comment).
	top_caret := los[0] + pads[0] + len(text) if len(text) > 0 else los[0]
	doc.cursor = top_caret
	doc.anchor = top_caret
	doc_batch_end_run(doc, edited, doc.block_run) // rows actually edited, not rows spanned

	// The rectangle SURVIVES the edit, collapsed to zero width at new_cell on
	// the same rows. Typing "// " down a column is three keystrokes, and
	// clearing the block here would make the second one an ordinary insert on
	// one line -- the feature's most-wanted use would need the rectangle
	// re-made between every character. See block_replace's own comment.
	//
	// Only the BOTTOM corner is corrected: the top row's start is still a fact.
	// The anchor/cursor orientation is preserved so a following Alt+Shift+arrow
	// keeps extending from the end the user built the rectangle from.
	new_hi := starts[n - 1] + shift
	if doc.block_anchor_line_start <= doc.block_cursor_line_start {
		doc.block_anchor_line_start = starts[0]
		doc.block_cursor_line_start = new_hi
	} else {
		doc.block_anchor_line_start = new_hi
		doc.block_cursor_line_start = starts[0]
	}
	doc.block_anchor_cell = new_cell
	doc.block_cursor_cell = new_cell
	return true
}

// Type over the rectangle: `text` replaces the rectangle's own cell range on
// every row it spans, as ONE undo step. A ZERO-WIDTH rectangle (cell_lo ==
// cell_hi, the "N carets in one column" affordance) replaces nothing and so
// simply inserts on every row -- which is how a column of lines gets prefixed.
//
// Afterwards the rectangle is still live, zero-width, at the column the insert
// finished in on every row: cell_lo plus the text's own cell width (never its
// byte length -- a tab is 4 cells and one byte, and CJK is 2 cells and 3).
// Padding guarantees every row really is at that same column, which is what
// makes the choice safe: the next keystroke's rectangle is a fact about all N
// rows, not just the longest.
//
// The three defensible post-edit states are collapse to a single caret, keep
// the rectangle, and this one. Collapsing loses the column after the first
// character, so "// " would need the rectangle re-made twice. Keeping the
// rectangle at its original width means the second character overwrites the
// first on every row -- typing "ab" leaves "b". A zero-width rectangle at the
// new column is the only one of the three where consecutive keystrokes compose
// the way typing does everywhere else in the editor.
//
// Returns false, having changed nothing at all, when block_apply refuses --
// see its comment for the three cases. The caller posts the note; this file
// has never imported the App type.
block_replace :: proc(doc: ^Document, t: ^plat.Text, text: []u8) -> bool {
	if !block_active(doc) {return false}
	// A line break in `text` has no rectangular meaning: it would split every
	// spanned row in two, so the row starts collected below stop naming line
	// starts the moment the first one is written, and the bottom corner's own
	// correction becomes arithmetic about a shape that no longer exists.
	// Nothing in the product can send one -- the platform char path filters
	// control characters and Enter is .Insert_Newline, which drops the
	// rectangle (command_dispatch) -- so this guards the precondition rather
	// than a reachable case, and refusing is the only safe answer for a future
	// caller (a column paste) that has not been designed yet.
	for b in text {
		if b == '\n' || b == '\r' {return false}
	}
	_, _, cell_lo, cell_hi := block_bounds(doc)
	return block_apply(doc, t, cell_lo, cell_hi, text, cell_lo + plat.text_cells(t, text, .Doc), .Paste)
}

// Backspace (forward=false) or Delete (forward=true) across the rectangle, as
// ONE undo step, leaving it live and zero-width at the column the deletion
// left off in -- same reasoning as block_replace, so held-down Backspace walks
// the whole column left one cell per press.
//
// A rectangle with width deletes its own cell range and collapses to its left
// edge; that is the "select a column and press Delete" gesture, and it is
// deliberately NOT block_cut_delete (which clears the rectangle, because a Cut
// ends the gesture the way it does on a linear selection).
//
// A ZERO-WIDTH rectangle is N carets: Backspace takes the cell to the left on
// every row, Delete the cell to the right. Neither ever joins rows. The right
// edge cannot: block_row_range's walk is bounded by the row's own visible end,
// so a row whose content stops before the deleted cell simply contributes
// nothing (no newline is reachable, let alone deletable). The left edge is
// handled here -- Backspace at column 0 is a no-op rather than N line joins,
// which is both what every other column editor does and the only answer that
// keeps the operation rectangular.
block_delete :: proc(doc: ^Document, t: ^plat.Text, forward: bool) -> bool {
	if !block_active(doc) {return false}
	off_lo, _, cell_lo, cell_hi := block_bounds(doc)
	if cell_lo != cell_hi {
		return block_apply(doc, t, cell_lo, cell_hi, nil, cell_lo, .Delete)
	}
	if forward {
		return block_apply(doc, t, cell_lo, cell_lo + 1, nil, cell_lo, .Delete)
	}
	if cell_lo == 0 {
		return true // nothing to the left on any row; see this proc's comment
	}
	// The column Backspace leaves the rectangle in is cell_lo MINUS THE CELL
	// WIDTH OF WHATEVER IT ACTUALLY DELETED -- not a flat -1, which assumes
	// every deleted cell is exactly one cell wide. It usually is (an ASCII
	// row), but block_row_range's own whole-rune-inclusion rule (this file's
	// central invariant: a straddled rune is never split) pulls a wider rune
	// in whole the moment cell_lo-1 lands inside its span -- a tab (4 cells,
	// TAB_CELLS) or a CJK character (2 cells) -- so the byte range deleted can
	// span more than one cell even though the EDIT range requested is always
	// exactly [cell_lo-1, cell_lo). LOW 1's probe: "\tabc\n" with the
	// rectangle at cell 4 deletes the whole leading tab (byte 0, the tab's
	// own start, to byte 1), and the caret lands at column 0 -- cell_lo-1
	// would report column 3, a column that does not exist on the row, and the
	// next keystroke would pad three stray spaces onto every row to reach it.
	//
	// Resolved via the rectangle's own TOP row (off_lo) -- the same row
	// top_caret is computed from elsewhere in this file, because that row's
	// start can never shift out from under this read -- through the same
	// block_row_range the edit itself calls a moment later inside
	// block_apply. This is one extra single-row resolve, not a second
	// cell-to-byte model: if this pre-read cannot resolve the row (ok=false),
	// block_apply's own identical resolve moments later will refuse the same
	// way and the whole edit aborts, so the fallback below is never observed
	// standing in for a value that mattered.
	new_cell := cell_lo - 1
	if lo, hi, _, ok := block_row_range(doc, t, off_lo, cell_lo - 1, cell_lo); ok && hi > lo {
		buf := make([]u8, hi - lo, context.temp_allocator)
		base.pt_read(&doc.pt, lo, buf)
		new_cell = cell_lo - plat.text_cells(t, buf, .Doc)
	}
	return block_apply(doc, t, cell_lo - 1, cell_lo, nil, new_cell, .Delete)
}
