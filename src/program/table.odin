// Layer: program — a read-only table view of a CSV/TSV, toggled per document
// (View menu / command palette / the Toggle Table View command). Like markdown's
// edit vs preview: the underlying text is untouched; this is just a different way
// to look at it. Bounded like every other viewport pass — only the visible rows
// are parsed and only their fields set the column widths, so a multi-GB CSV opens
// and scrolls the same as in text view.
//
// Scope (v1): fields quoted with " (with "" escaping) are parsed within a line;
// a quoted field that spans a newline is not (each visible line is one row).
// Editing happens in text view; toggle back to change anything.
package main

import "core:fmt"
import "core:strings"
import "core:unicode/utf8"
import base "src:base"
import plat "src:platform"

// --- §10's column-width rule, reconciled with what this file already did ----
//
// §10: "measure the first 200 rows, clamp each column to 8-40 characters,
// distribute leftover width proportionally." Three numbers, and the code
// disagreed with the spec on all three. Settled deliberately, and recorded here
// so the next audit does not "fix" the surviving divergence back:
//
//   sample    §10 says 200, this says 500 -- KEPT AT 500. §10's 200 is a budget,
//             not a result: it is there to bound the work, and 500 bounded rows
//             is the same bounded cost for strictly better information about a
//             file whose first 200 rows happen to be short. Nothing about the
//             rule changes at 500; only the sample's confidence does.
//   min       §10 says 8, this said 3 -- MOVED TO 8, and this is the one that
//             actually showed. A 3-cell column cannot hold its own header, so
//             every short column drew a truncated heading over data that fit.
//   leftover  §10 says distribute proportionally, this did not do it at all --
//             IMPLEMENTED, in table_cols_layout (see there for why it belongs in
//             the layout and not in the sample).
//
// NOT shared with markdown's md_table_fit_cells, and that is a considered answer
// to "two implementations of one rule is the shape this project keeps getting
// bitten by" rather than an oversight. The two surfaces want opposite things
// from the same sentence. md_table_fit_cells SHRINKS natural widths into a fixed
// measure and, under real pressure, drops columns -- correct for the markdown
// preview, which has no horizontal scroll and would otherwise paint a table over
// the scrollbar. The grid does have horizontal scroll (doc.table_col,
// table_start_col, the h-scrollbar), so a column too wide for the window is
// reached by scrolling, never by compression: shrinking a 40-cell column to 4
// because a CSV has thirty of them would make the data unreadable and the
// h-scrollbar pointless, and dropping one outright is the same instinct §10
// forbids for malformed rows. What the grid needs from that sentence is the
// EXPANSION case -- the one md_table_fit_cells returns early on ("if the clamped
// widths plus the gutters already fit, use them"). They are also mechanically
// incompatible: md_table_fit_cells is bounded to MD_TABLE_MAX_COLS (32) fixed
// arrays where a CSV routinely has more, its MD_TABLE_PAD is two cells of gap
// BETWEEN columns where the grid's padding is inside each cell in pixels, and
// its soft floor is 4 rather than §10's 8. Recorded in the HANDOFF entry too,
// not only here.
TABLE_COL_MAX :: 40 // widest a column grows to (cells); longer fields truncate
TABLE_COL_MIN :: 8 // §10's floor: narrower than this and a column loses its header
TABLE_SAMPLE :: 500 // rows scanned once to fix the column widths (§10 budgets 200)

// Which edge a column's cells are drawn against. §10: "Numeric and date columns
// right-align. Right-aligned numbers with tnum is the difference between a table
// and a text dump." Set once by table_compute_widths from the same bounded
// sample the widths come from, and carried on Table_Col so the draw and the link
// layout read it from the geometry rather than looking it up separately.
Table_Align :: enum u8 {
	Left,
	Right,
}

// An empty cell reads as broken parsing (UI spec §10: "in the screenshot the
// blank first column reads as broken parsing; a dash says 'empty, and we know
// it'"). Drawn in Text_Muted, not the Text_Dim §10 names: Text_Dim is
// theme.odin's disabled-only tier (2.9:1 Dark / 2.8:1 Light, below the AA
// floor), justified by WCAG's disabled-control exemption because a disabled
// control's dimness is "redundant with the control not responding" (§18). The
// dash is not that. Its entire job is to distinguish "empty, and we parsed
// it" from "missing / short row" -- the distinction group C's warning bar
// exists to give the OTHER case -- so a reader who cannot resolve the dash at
// 2.8:1 loses exactly the information it was added to convey. That is live
// content, not a disabled control, and it is a deviation from §10's literal
// text-dim call-out, recorded in HANDOFF.md §5. Text_Muted (4.9:1 / 5.4:1,
// §1.1's "accelerators, help lines, hints" tier) clears AA and is still
// quieter than every cell that holds real data, which is the property the
// dash actually needs.
//
// An EMPTY cell only. A row with FEWER fields than the table has columns is a
// different thing -- malformed, not empty -- and §10 gives that a warning bar on
// the row's left edge instead. The draw's `c >= len(row.fields)` skip is what
// keeps the two apart, so it stays.
TABLE_EMPTY_CELL :: "—"

// --- the grid's metrics (UI spec §10: "header 30px, rows 26px, cell padding
// 0 10") ------------------------------------------------------------------
//
// 96-DPI design values plus a live DPI-scaled global, the same shape every other
// metric in this file's neighbours uses (see doc.odin's block and
// metrics_recompute, which is their sole writer). The initialisers here must
// stay in step with metrics_recompute, since the headless test modes never call
// it -- the same caveat CONTENT_TOP carries.
TABLE_HEADER_H_96 :: f32(30)
TABLE_ROW_H_96 :: f32(26)
TABLE_CELL_PAD_X_96 :: f32(10)
TABLE_GUTTER_W_96 :: f32(56) // §10's row-number gutter, right-aligned, from x = 0

TABLE_HEADER_H := TABLE_HEADER_H_96
TABLE_ROW_H := TABLE_ROW_H_96
TABLE_CELL_PAD_X := TABLE_CELL_PAD_X_96
TABLE_GUTTER_W := TABLE_GUTTER_W_96

// Width of the row-number gutter. A procedure, not the global read directly, for
// the same reason table_row_h is one: it is an input to table_cols_layout -- the
// grid's single x-axis producer -- and every consumer of the x axis therefore
// picks it up without knowing it exists. A draw that offset by 56px while the
// hit-test did not would write a cell edit into the wrong column, which is the
// exact divergence table_cols_layout's block comment was written about.
//
// FIXED, not sized to the widest visible number. A content-sized gutter would
// move every column sideways the moment the view scrolled from row 9,999 to row
// 10,000, and "columns don't shift as you scroll" is the property
// table_compute_widths' one-time sample exists to hold. The cost is that a row
// number past ~5 digits does not fit inside 56px minus its padding; see the
// gutter pass in table_draw for what happens then, which is emphatically not
// truncation.
table_gutter_w :: #force_inline proc() -> f32 {return TABLE_GUTTER_W}

// --- the grid's vertical geometry: ONE producer ---------------------------
//
// table_cell_at maps a pixel to a field's BYTE RANGE and table_edit_commit
// writes that range, so this surface's pixel->row mapping is a data-loss seam,
// not a cosmetic one (CLAUDE.md, "one layout per widget"). Every consumer -- the
// draw, the hit-test, the link hit-test, the cell edit, the row budget and the
// wheel -- goes through the procedures below and none of them recomputes a row
// position or a row count of its own.
//
// The row height is max(design, line_height(px)) rather than the design value
// flat. 26px at 96 DPI holds a 16px font's 24px line box with 2px to spare, but
// the document font is the user's (BASE_PX from Settings, times zoom): at 150%
// zoom the line box is 36px and a fixed 26px row would draw every cell over its
// neighbours. Taking the max means the spec's number governs at the sizes it was
// drawn for and the grid degrades into a plain line-height grid past that,
// rather than into overlap. Same for the header.
table_row_h :: #force_inline proc(px: f32) -> f32 {return max(TABLE_ROW_H, line_height(px))}
table_header_h :: #force_inline proc(px: f32) -> f32 {return max(TABLE_HEADER_H, line_height(px))}

// Top of the header band -- the grid's origin. Shares CONTENT_TOP + TOP_INSET
// with the text view, so the find bar and the filter banner push the grid down
// by exactly what they push the text rows down by.
table_grid_top :: #force_inline proc() -> f32 {return CONTENT_TOP + TOP_INSET}

// Top of data row 0. The header is STICKY: it is not a scrolling row, it owns
// this band permanently, and the data rows begin below it.
table_rows_top :: #force_inline proc(px: f32) -> f32 {return table_grid_top() + table_header_h(px)}

// Top y of the full-width band for data row r.
table_row_rect_y :: #force_inline proc(px: f32, r: int) -> f32 {
	return table_rows_top(px) + f32(r) * table_row_h(px)
}

// Text baseline for data row r. `px` from the top of the row's LINE BOX, which
// is the editor's own baseline relationship (row_baseline_y), plus half of
// whatever slack the taller table row adds -- so the line box is centred in the
// row and the glyphs sit exactly where they would in text view when the row has
// no slack left (a zoomed font, where table_row_h == line_height).
table_row_baseline_y :: #force_inline proc(px: f32, r: int) -> f32 {
	return table_row_rect_y(px, r) + px + f32(int((table_row_h(px) - line_height(px)) * 0.5))
}
table_header_baseline_y :: #force_inline proc(px: f32) -> f32 {
	return table_grid_top() + px + f32(int((table_header_h(px) - line_height(px)) * 0.5))
}

// The INVERSE, and the only one: a client-space y to a data row index. ok=false
// for anything at or above the first data row -- the header band and the chrome
// above it -- so a press on the sticky header can never resolve to row 0 and
// start editing the first data row's cell. That is the specific way a sticky
// header breaks an editing grid, and refusing here (rather than in the caller)
// is what makes it impossible for one caller to forget.
//
// Deliberately NOT bounded above: the caller knows its own row budget
// (table_visible_rows) and both callers already check `r < rows`. A second bound
// here would be a second opinion about how many rows exist.
table_row_at_y :: #force_inline proc(px, my: f32) -> (r: int, ok: bool) {
	ty := table_rows_top(px)
	if my < ty {return 0, false}
	return int((my - ty) / table_row_h(px)), true
}

// Data rows that fit below the sticky header. The grid's answer to
// doc_visible_rows, which cannot serve here: it divides the content box by the
// editor's line_height and knows nothing about the header band, so it over-counts
// the grid's rows by roughly the header's height plus the row-height difference.
// Feeds the draw, both hit-tests and -- through doc_scroll -- the scroll clamp,
// which is why it exists rather than each of them trimming `rows` by eye.
table_visible_rows :: proc(doc: ^Document, height, px: f32) -> int {
	_, bot := doc_content_box(doc, height)
	return max(0, int((bot - table_rows_top(px)) / table_row_h(px)))
}

// --- the grid's row set: ONE producer ------------------------------------
//
// The header is line 0 and it is sticky, so line 0 is NOT a data row. The data
// rows are lines 1..N, and doc.top -- shared with text view, written by the
// wheel, the page keys, Ctrl+Home, session restore and find -- indexes into
// them. That makes doc.top == 0 and doc.top == <start of line 1> the SAME scroll
// position expressed two ways, and this proc is where they become one number.
//
// ok=false when the document has no data row at all (empty, or a header with no
// newline after it). Callers draw the header and no rows rather than treating
// the header as row 0, which would put the same line on screen twice.
table_data_start :: proc(doc: ^Document) -> (start: int, ok: bool) {
	if doc == nil || doc.pt.length == 0 {return 0, false}
	e0 := base.pt_line_end_cap(&doc.pt, 0, RENDER_LINE_CAP)
	if e0 >= doc.pt.length {return 0, false} // header only: nothing below it
	return max(doc.top, e0 + 1), true
}

// Byte offset of the start of visible data row r. The row-index -> byte half of
// the seam; table_row_at_y is the pixel -> row-index half, and between them they
// are the whole pixel -> byte mapping the edit path writes through. The draw
// walks the same lines sequentially from r = 0 rather than calling this per row,
// which is the same walk this performs -- both start at table_data_start.
table_row_start :: proc(doc: ^Document, r: int) -> (p: int, ok: bool) {
	s, sok := table_data_start(doc)
	if !sok || r < 0 {return 0, false}
	p = s
	for _ in 0 ..< r {
		e := base.pt_line_end_cap(&doc.pt, p, RENDER_LINE_CAP)
		if e >= doc.pt.length {return 0, false} // no such row
		p = e + 1
	}
	if p > doc.pt.length {return 0, false}
	return p, true
}

// Absolute data-row index of each visible row -- the row's position in the FILE
// rather than in the viewport. THE producer for the grid's row numbering: §10's
// row-number gutter draws it and the zebra's parity rides on it, and neither
// derives it a second way.
//
// Entry r is TABLE_ABS_NONE when the file's numbering cannot answer for that row.
// doc_line_no_at refuses when the background index has not reached the offset,
// when the buffer has been edited at or below it, and after a faulted read of a
// mapped original; all three arrive here as the same refusal. A caller draws
// NOTHING for a refused row (development-loop.md §4, Shape A) -- not a zero, not
// a guess. The zebra is the single exception and only because a band carries no
// information; see table_draw.
//
// The header is line 0 and is not a data row, so data row 0 is line 1 and the
// answer is doc_line_no_at(<the first data row's byte>) - 1 + r. The lookup is
// taken at table_data_start rather than at table_row_start(doc, r): visible rows
// are consecutive lines by construction -- table_row_start's own walk is r
// line-ends forward from exactly that offset -- so the two agree, and asking at
// the fixed offset does not walk r lines to find a byte whose line number is
// already implied.
//
// A RUN rather than one row at a time, and that is a MEASURED cost decision, not
// a style one. doc_line_no_at is bounded but not cheap: it counts newlines
// forward from the checkpoint at or below the offset, up to LINE_CKPT_STRIDE
// (64 KiB) of it. Measured on a 1.16 MB fixture whose first visible row sat
// 65,482 bytes past its checkpoint -- the worst case at that stride -- one call
// costs 153.3 us in a debug build, so a per-row producer spends 6.1 ms of a
// full 40-row screen's repaint on it. Every one of those calls scans the SAME
// bytes, because `at` is table_data_start for all of them and only the `+ r`
// differs. Asking once and adding r is the same answer for a fortieth of the
// work, and it leaves exactly one place that turns a line number into a row
// index.
//
// One call per frame rather than a memo, deliberately. A cache would have to key
// on every input doc_line_no_at reads -- the offset, edit_floor, ckpt_n, done,
// pt.fault, idx.fault, and the identity of the ckpts array doc_index_start swaps
// out from under it -- and a key that misses one of those is a stale row number
// presented to the reader as fact. That is the failure this whole two-result
// contract exists to prevent.
//
// NOT bounded above, deliberately, exactly as table_row_at_y is not: the caller
// owns its row budget (table_visible_rows) and a second opinion here about how
// many rows exist would be a second producer. Entries past the end of the file
// carry confident numbers, so read only the entries you have rows for.
TABLE_ABS_NONE :: -1

table_abs_rows :: proc(doc: ^Document, rows: int, allocator := context.temp_allocator) -> []int {
	out := make([]int, max(0, rows), allocator)
	for i in 0 ..< len(out) {out[i] = TABLE_ABS_NONE}
	if doc == nil || len(out) == 0 {return out}
	s, sok := table_data_start(doc)
	if !sok {return out}
	ln, exact := doc_line_no_at(doc, s)
	// ln == 0 would mean the first data row IS line 0, which table_data_start
	// exists to make impossible; refuse rather than hand back -1 + r and have it
	// read as the refusal sentinel by accident.
	if !exact || ln < 1 {return out}
	for i in 0 ..< len(out) {out[i] = ln - 1 + i}
	return out
}

// The header's fields: line 0, always, whatever doc.top is. That last clause IS
// the sticky-header rule, stated as a procedure so it can be asserted rather than
// only looked at -- the band drew "the first line if it happens to be on screen"
// before, which is a different function of the same inputs and looks identical
// until the view is scrolled.
table_header_fields :: proc(doc: ^Document, allocator := context.temp_allocator) -> []string {
	if doc == nil || doc.pt.length == 0 {return nil}
	delim := doc.table_delim if doc.table_delim != 0 else ','
	buf: [RENDER_LINE_CAP]u8
	e0 := base.pt_line_end_cap(&doc.pt, 0, RENDER_LINE_CAP)
	n := base.pt_read(&doc.pt, 0, buf[:min(e0, len(buf))])
	if n > 0 && buf[n - 1] == '\r' {n -= 1}
	return csv_fields(strings.clone(string(buf[:n]), allocator), delim, allocator)
}

// --- the grid's horizontal geometry: ONE producer ------------------------

// A visible column's cell rectangle. `x` is the LEFT EDGE of the cell (the band
// the zebra and the edit highlight fill), `w` its full width including both
// paddings; the text inside starts at table_cell_text_x and is clipped to
// `cells`.
Table_Col :: struct {
	c:     int, // column index into doc.table_widths
	x, w:  f32,
	// The width the cell is LAID OUT at, in cells -- the sampled width plus this
	// column's share of any leftover (§10's proportional distribution). It is
	// what the text is truncated to, and it is carried here rather than read back
	// out of doc.table_widths by each consumer: `w` and this are two views of one
	// number, and a consumer truncating to the SAMPLED width inside a WIDENED
	// rectangle would leave a gap it had no reason to leave.
	cells: int,
	align: Table_Align,
}

// Right edge of the grid: the window minus the vertical scrollbar.
table_right :: #force_inline proc(width: f32) -> f32 {return width - SCROLLBAR_W}

// The leftmost visible column, clamped. One expression, because the draw, both
// hit-tests and the horizontal scrollbar all need the same answer and
// doc.table_col can be stale by a frame after a resize narrows the grid.
table_start_col :: #force_inline proc(doc: ^Document) -> int {
	return clamp(doc.table_col, 0, table_max_col(doc))
}

// Every visible column's cell rectangle, left to right from `start_col`. THE
// producer for the grid's x axis: consumed by the draw, the cell hit-test, the
// link layout, the in-cell edit box and the horizontal scrollbar's thumb
// (table_cols_fitting). Four of those five used to advance their own copy of
// `cx += (colw[c] + TABLE_COL_PAD) * char_w` from their own origin, which is
// precisely the divergence that writes an edit into the wrong column.
//
// Cells tile from table_gutter_w(), not from x = 0 and not from TEXT_MARGIN_X.
// §10's "cell padding 0 10" is the grid's own left inset, and §10's row-number
// gutter takes its 56px from the origin ahead of the first cell. The gutter is
// added HERE, inside the one producer, precisely so that the draw, the cell
// hit-test, the link layout, the in-cell edit box and the horizontal scrollbar
// all move by it together -- four of those five once advanced their own copy of
// this axis, and a gutter added to the draw alone would have re-created that
// divergence in its worst form (a click resolving to the column to its left, and
// an edit committing there).
//
// The zebra band and the header band still span from x = 0 and cover the gutter:
// a band has to reach the window edge to read as a row at all -- one starting
// 56px in reads as a box around the data.
//
// A column that STARTS before the right edge is included even if it runs past
// it, so a partly-visible column is drawn and clickable rather than dead; the
// text inside it is clipped to the edge by the draw.
table_cols_layout :: proc(doc: ^Document, char_w, width: f32, start_col: int, allocator := context.temp_allocator) -> []Table_Col {
	out := make([dynamic]Table_Col, 0, 16, allocator)
	colw := doc.table_widths
	if len(colw) == 0 {return out[:]}
	right := table_right(width)
	extra := table_leftover_cells(doc, char_w, width, allocator)
	x := table_gutter_w()
	for c := clamp(start_col, 0, max(0, len(colw) - 1)); c < len(colw); c += 1 {
		if x >= right {break}
		cells := colw[c] + (extra[c] if c < len(extra) else 0)
		w := f32(cells) * char_w + TABLE_CELL_PAD_X * 2
		al := doc.table_align[c] if c < len(doc.table_align) else Table_Align.Left
		append(&out, Table_Col{c = c, x = x, w = w, cells = cells, align = al})
		x += w
	}
	return out[:]
}

// §10's "distribute leftover width proportionally", as extra CELLS per column.
//
// In the LAYOUT rather than in table_compute_widths, and that placement is the
// whole of the design. The leftover depends on the window width, and
// table_compute_widths runs when the grid opens and after an edit -- never on a
// resize -- so a distribution baked into the sample would be stale from the
// first drag of the window's edge, silently, with no route to notice. Computed
// here it is correct on every frame by construction and costs one pass over the
// column list.
//
// Applies ONLY when every column already fits. There is no leftover otherwise,
// and the grid answers overflow by scrolling horizontally rather than by
// shrinking (see the reconciliation note at TABLE_COL_MIN for why the grid must
// not borrow md_table_fit_cells' compression). `start_col` is deliberately not a
// parameter: the leftover belongs to the table, not to whatever part of it
// happens to be scrolled into view, so a column keeps the same width whether or
// not it is the first one on screen.
//
// Proportional to each column's own sampled width, with the integer remainder
// handed out one cell at a time from the left so the widened columns sum to the
// leftover EXACTLY -- md_table_fit_cells does the same for the same reason, and
// the shape is worth mirroring even though the direction is opposite: rounding
// drift left over at the right edge is a ragged column boundary that moves with
// the window width.
@(private = "file")
table_leftover_cells :: proc(doc: ^Document, char_w, width: f32, allocator := context.temp_allocator) -> []int {
	colw := doc.table_widths
	out := make([]int, len(colw), allocator)
	if len(colw) == 0 || char_w <= 0 {return out}
	avail := table_right(width) - table_gutter_w()
	total, sum := f32(0), 0
	for w in colw {
		total += f32(w) * char_w + TABLE_CELL_PAD_X * 2
		sum += w
	}
	if total >= avail || sum <= 0 {return out}
	leftover := int((avail - total) / char_w)
	if leftover <= 0 {return out}
	given := 0
	for w, i in colw {
		out[i] = leftover * w / sum
		given += out[i]
	}
	for i := 0; given < leftover; i = (i + 1) %% len(out) {
		out[i] += 1
		given += 1
	}
	return out
}

// Left x of a cell's TEXT -- the LEFT inner edge, whatever the column's
// alignment. Split out so the draw, the link layout and the edit box cannot each
// apply the padding differently.
table_cell_text_x :: #force_inline proc(col: Table_Col) -> f32 {return col.x + TABLE_CELL_PAD_X}

// How far right a string of `cells` columns is nudged inside its cell by the
// column's alignment (§10: "Numeric and date columns right-align").
//
// A NUDGE added to table_cell_text_x rather than a second x producer, and it is
// zero for a left-aligned column -- so every consumer adds it unconditionally,
// a left column is laid out exactly as it was before this existed, and there is
// still only one procedure that decides where a cell's left inner edge is.
//
// Clamped at zero, which is what keeps TRUNCATION LEFT-ANCHORED. A field wider
// than its column is cut from the RIGHT by the draw and then measures exactly
// col.cells, so the nudge collapses to zero and the surviving text starts at the
// left inner edge. Cutting a right-aligned number from the LEFT instead would
// not shorten a label, it would change the value -- 10432 becoming 432 -- and no
// ellipsis can rescue that.
table_cell_align_dx :: #force_inline proc(col: Table_Col, cells: int, char_w: f32) -> f32 {
	if col.align != .Right {return 0}
	return max(0, col.w - TABLE_CELL_PAD_X * 2 - f32(cells) * char_w)
}

// Compute the per-column widths AND alignments from the first TABLE_SAMPLE rows
// (bounded), so they stay fixed as the user scrolls. Recomputed when the view
// opens and after an edit; cheap relative to a frame.
//
// One pass produces both, because they are answers about the same sampled cells
// and two passes would be two chances to sample different rows.
table_compute_widths :: proc(doc: ^Document, text: ^plat.Text) {
	clear(&doc.table_widths)
	clear(&doc.table_align)
	delim := doc.table_delim if doc.table_delim != 0 else ','
	// Per-column evidence for the type decision, grown alongside the widths.
	// `nonempty` is what stops a vacuous all-true: a column whose sampled cells
	// are ALL empty satisfies "every non-empty cell is a number" trivially, and
	// calling it numeric on that basis is development-loop.md §4 Shape A wearing
	// a different hat -- a bounded scan that saw no evidence reporting a
	// confident answer. Empty cells alone do not disqualify a column, though: a
	// sparse numeric column is still a numeric column.
	nonempty := make([dynamic]int, 0, 16, context.temp_allocator)
	num_all := make([dynamic]bool, 0, 16, context.temp_allocator)
	date_all := make([dynamic]bool, 0, 16, context.temp_allocator)
	buf: [RENDER_LINE_CAP]u8
	p := 0
	for row in 0 ..< TABLE_SAMPLE {
		if p > doc.pt.length {break}
		end := base.pt_line_end_cap(&doc.pt, p, RENDER_LINE_CAP)
		n := base.pt_read(&doc.pt, p, buf[:min(end - p, len(buf))])
		if n > 0 && buf[n - 1] == '\r' {n -= 1}
		for f, c in csv_fields(string(buf[:n]), delim) {
			// col0 = 0: a grid field is measured from ITS OWN start, because
			// that is where table_draw draws it (text_draw's own column origin
			// is the string it is handed). A tab inside a field therefore
			// aligns to the field, not to the row -- the choice the batch-7
			// spec left open, settled this way because it is the only one where
			// the measured width and the drawn width are the same number.
			w := plat.text_cells(text, transmute([]u8)f, 0, .Doc)
			for c >= len(doc.table_widths) {
				append(&doc.table_widths, 0)
				append(&nonempty, 0)
				append(&num_all, true)
				append(&date_all, true)
			}
			if w > doc.table_widths[c] {doc.table_widths[c] = w}
			// Row 0 is the HEADER. It counts toward the width -- a column has to
			// be able to show its own name -- and not toward the type, or every
			// numeric column in every CSV ever written would be disqualified by
			// the word above it.
			if row == 0 {continue}
			t := strings.trim_space(f)
			if len(t) == 0 {continue}
			nonempty[c] += 1
			if !table_is_number(t) {num_all[c] = false}
			if !table_is_date(t) {date_all[c] = false}
		}
		if end >= doc.pt.length {break}
		p = end + 1
	}
	for &w in doc.table_widths {w = clamp(w, TABLE_COL_MIN, TABLE_COL_MAX)}
	// Same length as the widths, always: table_cols_layout indexes both by column
	// and a short align array would silently left-align the tail.
	for c in 0 ..< len(doc.table_widths) {
		right := c < len(nonempty) && nonempty[c] > 0 && (num_all[c] || date_all[c])
		append(&doc.table_align, Table_Align.Right if right else Table_Align.Left)
	}
}

// Does this cell hold a number? Deliberately narrow, because the cost of a false
// positive is a whole column of prose shoved to the right: an optional sign,
// digits with optional ',' group separators in the integer part only, an
// optional fraction, and an optional exponent. No currency symbols, no trailing
// '%', no unit suffixes -- each of those is a column that is only sometimes a
// number, and §10 asks for the columns that always are.
table_is_number :: proc(s: string) -> bool {
	if len(s) == 0 {return false}
	i := 0
	if s[i] == '+' || s[i] == '-' {i += 1}
	digits, frac_digits, exp_digits := 0, 0, 0
	dot, exp := false, false
	for ; i < len(s); i += 1 {
		c := s[i]
		switch {
		case c >= '0' && c <= '9':
			if exp {exp_digits += 1} else if dot {frac_digits += 1} else {digits += 1}
		case c == ',':
			// A group separator, and only where one can appear: never after the
			// decimal point, never inside an exponent, never leading.
			if dot || exp || digits == 0 {return false}
		case c == '.':
			if dot || exp {return false}
			dot = true
		case c == 'e' || c == 'E':
			if exp || (digits == 0 && frac_digits == 0) {return false}
			exp = true
			if i + 1 < len(s) && (s[i + 1] == '+' || s[i + 1] == '-') {i += 1}
		case:
			return false
		}
	}
	if exp && exp_digits == 0 {return false}
	return digits + frac_digits > 0
}

// Does this cell hold a date? Shape only -- 2026-13-45 passes, and that is the
// right trade: this decides an ALIGNMENT, not a validation, and a column of
// dates with one impossible day in it is still a column of dates. Calendar
// validation would reject real data (some exports write 0000-00-00 for "no
// date") and buy nothing the reader can see.
//
// An optional time tail is accepted after 'T' or a space so an ISO timestamp
// column right-aligns with a plain date column; the tail is only checked for
// looking like a clock, since the head has already proved the field is a date.
table_is_date :: proc(s: string) -> bool {
	MASKS :: [?]string{"dddd-dd-dd", "dddd/dd/dd", "dd/dd/dddd", "dd-dd-dddd", "dd.dd.dddd"}
	head, tail := s, ""
	// `sep` is tracked separately from `len(tail)`, because the two are different
	// states and conflating them said yes to "2026-01-01T" -- a separator with
	// nothing after it, which is a truncated field, not a timestamp.
	sep := false
	if i := strings.index_any(s, "T "); i >= 0 {
		head, tail, sep = s[:i], s[i + 1:], true
	}
	matched := false
	for m in MASKS {
		if len(head) != len(m) {continue}
		good := true
		for k in 0 ..< len(m) {
			if m[k] == 'd' {
				if head[k] < '0' || head[k] > '9' {good = false;break}
			} else if head[k] != m[k] {
				good = false
				break
			}
		}
		if good {matched = true;break}
	}
	if !matched {return false}
	if !sep {return true}
	if len(tail) == 0 {return false}
	colons := 0
	for k in 0 ..< len(tail) {
		c := tail[k]
		switch {
		case c == ':':
			colons += 1
		case c >= '0' && c <= '9', c == '.', c == '+', c == '-', c == 'Z', c == 'z':
		case:
			return false
		}
	}
	return colons > 0
}

// Pick the delimiter when the table view is turned on: tab for .tsv, else
// whichever of tab/comma the first non-empty line has more of.
table_choose_delim :: proc(doc: ^Document) -> u8 {
	if strings.has_suffix(doc.path, ".tsv") {return '\t'}
	buf: [RENDER_LINE_CAP]u8
	n := base.pt_read(&doc.pt, 0, buf[:min(len(buf), doc.pt.length)])
	tabs, commas := 0, 0
	for b in buf[:n] {
		switch b {
		case '\t':
			tabs += 1
		case ',':
			commas += 1
		case '\n':
			if tabs + commas > 0 {return '\t' if tabs > commas else ','}
		}
	}
	return '\t' if tabs > commas else ','
}

// Split one line into fields on `delim`, honouring "..." quoting ("" is a literal
// quote). Unquoted fields alias `line`; quoted ones are rebuilt. Temp-allocated.
csv_fields :: proc(line: string, delim: u8, allocator := context.temp_allocator) -> []string {
	out := make([dynamic]string, 0, 8, allocator)
	i, n := 0, len(line)
	for {
		if i < n && line[i] == '"' {
			i += 1
			sb := strings.builder_make(allocator)
			for i < n {
				if line[i] == '"' {
					if i + 1 < n && line[i + 1] == '"' {
						strings.write_byte(&sb, '"')
						i += 2
					} else {
						i += 1
						break
					}
				} else {
					strings.write_byte(&sb, line[i])
					i += 1
				}
			}
			append(&out, strings.to_string(sb))
			for i < n && line[i] != delim {i += 1} // ignore anything after the close quote
		} else {
			s := i
			for i < n && line[i] != delim {i += 1}
			append(&out, line[s:i])
		}
		if i >= n {break}
		i += 1 // skip the delimiter
		if i >= n {append(&out, "");break} // a trailing delimiter means a final empty field
	}
	return out[:]
}

// Largest table_col that still shows content (keeps the last column reachable).
table_max_col :: proc(doc: ^Document) -> int {
	return max(0, doc.table_cols - 1)
}

// How many columns fit on screen starting at `start_col`. Now literally the
// length of the draw's own layout rather than a second loop that advances the
// same way -- the divergence CLAUDE.md's "one layout per widget" exists to
// prevent, and this proc's previous comment claimed the two loops matched while
// they were free to drift. Always at least 1, so a single column wider than the
// window still yields a sane thumb rather than a zero-width one.
table_cols_fitting :: proc(doc: ^Document, char_w, width: f32, start_col: int) -> int {
	return max(1, len(table_cols_layout(doc, char_w, width, start_col)))
}

// A link inside a table cell, positioned in pixels (cells sit at arbitrary
// column x's, not the uniform text grid, so links here can't use Link_Hit).
Table_Link :: struct {
	x, y, w: f32, // underline rect; y is the text baseline
	text:    string, // the cell text the link offsets index (for resolution)
	link:    Link,
}

// Links in the visible cells, positioned to match table_draw's layout. Rebuilt
// per frame while Ctrl is held (or Show-links is on), like the editor's links.
table_links :: proc(doc: ^Document, text: ^plat.Text, px, char_w: f32, rows: int, width: f32, allocator := context.temp_allocator) -> []Table_Link {
	out := make([dynamic]Table_Link, 0, 8, allocator)
	if len(doc.table_widths) == 0 {return out[:]}
	// Data rows only. The sticky header's cells are not scanned: §10 gives the
	// header click to sort, so a link there could never be reached anyway, and
	// producing one would put an underline in a band this proc's consumers
	// position by data-row index.
	p, pok := table_row_start(doc, 0)
	if !pok {return out[:]}
	delim := doc.table_delim if doc.table_delim != 0 else ','
	cols := table_cols_layout(doc, char_w, width, table_start_col(doc), allocator)
	right := table_right(width)
	buf: [RENDER_LINE_CAP]u8
	for r in 0 ..< rows {
		if p > doc.pt.length {break}
		end := base.pt_line_end_cap(&doc.pt, p, RENDER_LINE_CAP)
		n := base.pt_read(&doc.pt, p, buf[:min(end - p, len(buf))])
		if n > 0 && buf[n - 1] == '\r' {n -= 1}
		fields := csv_fields(string(buf[:n]), delim, allocator)
		ry := table_row_baseline_y(px, r)
		for col in cols {
			if col.c >= len(fields) {continue}
			field := strings.clone(fields[col.c], allocator)
			// Both the cell's clip edge and the underline's origin come from
			// col.cells, the width the LAYOUT gave this column -- not from
			// doc.table_widths[col.c], which is the pre-distribution sample and is
			// narrower whenever §10's leftover has been handed out. Reading the
			// sample here would have left every link in a widened column clipped
			// short of where the draw actually put its glyphs.
			//
			// ...and the same alignment nudge the draw applies, so an underline in
			// a right-aligned column sits under its text rather than beside it.
			// Measured on the FULL field for both, which is what the draw draws
			// when the field fits; a field that does not fit is truncated by the
			// draw and the nudge collapses to zero for it either way.
			fcells := plat.text_cells(text, transmute([]u8)field, 0, .Doc)
			tx := table_cell_text_x(col) + table_cell_align_dx(col, fcells, char_w)
			cellright := min(table_cell_text_x(col) + f32(col.cells) * char_w, right)
			for l in links_scan(field, allocator) {
				// col0 = 0: `field` is the fragment, and `lcol` is used as an
				// offset from the field's own text x just below.
				lcol, lcells := plat.text_span_cells(text, field, l.start, l.len, 0, .Doc)
				lx := tx + f32(lcol) * char_w
				if lx < cellright {
					append(&out, Table_Link{x = lx, y = ry, w = min(f32(lcells) * char_w, cellright - lx), text = field, link = l})
				}
			}
		}
		if end >= doc.pt.length {break}
		p = end + 1
	}
	return out[:]
}

// `row_h`, not the editor's line_h: the band a link is clickable in has to be the
// band its row was drawn in, and in the grid those are different numbers (26px
// design vs the font's line box). Passing line_h here made the top of a row's
// link band correct and the bottom of it short by the difference.
table_link_hit :: proc(links: []Table_Link, mx, my, px, row_h: f32) -> (Table_Link, bool) {
	for l in links {
		if mx >= l.x && mx < l.x + l.w && my >= l.y - px && my < l.y - px + row_h {
			return l, true
		}
	}
	return {}, false
}

// Draw the visible rows as a grid. `doc.table_cols` is set here (the column count
// this frame) so input can clamp horizontal scroll. Returns the byte offset just
// past the last visible row, for the byte-proportional scrollbar.
table_draw :: proc(gfx: ^plat.Gfx, qp: ^plat.Quad_Pipeline, text: ^plat.Text, doc: ^Document, px, char_w: f32, rows: int, width: f32) -> (bottom: int) {
	delim := doc.table_delim if doc.table_delim != 0 else ','
	row_h := table_row_h(px)
	right := table_right(width)
	bottom = doc.top

	// Column widths come from a one-time sample (table_compute_widths), NOT from
	// the currently-visible rows, so columns don't shift as you scroll different
	// rows (a wider header, then narrower data) into view.
	if len(doc.table_widths) == 0 {table_compute_widths(doc, text)}
	colw := doc.table_widths
	doc.table_cols = len(colw)
	cols := table_cols_layout(doc, char_w, width, table_start_col(doc))

	// Pass 1: parse the visible DATA rows. Starts at table_row_start(doc, 0), the
	// same producer the hit-test resolves through, so what is drawn at row r and
	// what a click at row r edits are the same line by construction rather than
	// by two walks agreeing.
	Row :: struct {
		fields: []string,
	}
	// The absolute data-row index of each visible row, from the one producer, for
	// the band's parity and (group B) the row-number gutter. Asked ONCE for the
	// whole screen -- see table_abs_rows for the measurement that made a per-row
	// call untenable. Indexed by visible row r, and len(absn) == rows >= len(vis)
	// by construction, so every row the passes below draw has an entry.
	absn := table_abs_rows(doc, rows)
	vis := make([dynamic]Row, 0, rows, context.temp_allocator)
	buf: [RENDER_LINE_CAP]u8
	if p, pok := table_row_start(doc, 0); pok {
		bottom = p
		for _ in 0 ..< rows {
			if p > doc.pt.length {break}
			end := base.pt_line_end_cap(&doc.pt, p, RENDER_LINE_CAP)
			n := base.pt_read(&doc.pt, p, buf[:min(end - p, len(buf))])
			vb := n
			if vb > 0 && buf[vb - 1] == '\r' {vb -= 1}
			line := strings.clone(string(buf[:vb]), context.temp_allocator)
			append(&vis, Row{csv_fields(line, delim)})
			bottom = end
			if end >= doc.pt.length {break}
			p = end + 1
		}
	} else {
		bottom = doc.pt.length // a header with nothing under it: the whole file is on screen
	}

	// Zebra banding, in place of the per-column vertical rules this draw used to
	// emit (§10: a rule per column is "8 extra quads per screen and it makes the
	// grid louder than the data"). One quad per banded row, spanning the full
	// grid width so the band reads as a row rather than as a box around the text.
	//
	// Parity rides the row's ABSOLUTE position in the file (table_abs_rows), not
	// its visible index. It used to ride the visible index because the absolute
	// one could not be had without counting newlines from byte 0 -- unbounded on a
	// multi-GB CSV, and exactly what the viewport-first rule forbids. Line_Index's
	// sparse checkpoints removed that constraint, and the visible symptom they
	// removed with it is the bands inverting whenever the view scrolled by an odd
	// number of rows (HANDOFF §6aw, "Owed").
	//
	// The FALLBACK to `r % 2` is the one place in this draw allowed to guess at a
	// refused row, and only because a band carries no information: a wrong band is
	// a cosmetic hiccup, where a wrong row NUMBER is a lie about which line the
	// reader is looking at. The gutter below therefore draws nothing on the same
	// refusal this line papers over -- deliberately different answers to the same
	// question, for two things with very different costs of being wrong.
	//
	// Either way the unbanded rows are the EVEN ones, so data row 0 -- directly
	// under the header rule -- sits on the page, which is the parity §10's
	// screenshot shows and the one tg_appearance pins.
	zebra := g_theme[.Table_Zebra]
	for _, r in vis {
		band := absn[r] % 2 if absn[r] != TABLE_ABS_NONE else r % 2
		if band == 0 {continue}
		plat.quads_draw(gfx, qp, []plat.Quad{{pos = {0, table_row_rect_y(px, r)}, size = {right, row_h}, color = zebra}})
	}

	// The row-number gutter (§10: "56px right-aligned gutter"). Over the bands,
	// under nothing -- it occupies the 56px table_cols_layout already stepped the
	// first cell past, so it cannot collide with any cell's text by construction
	// rather than by two numbers agreeing.
	//
	// A REFUSED row draws NO NUMBER. table_abs_rows hands back TABLE_ABS_NONE
	// when the file's numbering cannot be answered -- the background index has not
	// reached the row, the buffer was edited at or below it, or a mapped read
	// faulted -- and a plausible-looking wrong row number is worse than a blank,
	// because the reader has no way to tell it apart from a right one. This is
	// development-loop.md §4 Shape A, and blank is the honest answer.
	//
	// KNOWN, and accepted rather than papered over: nothing RAISES
	// Line_Index.edit_floor once an edit has lowered it, and doc_save does not
	// re-index, so after editing a cell the numbers at and below that row stay
	// blank for the life of the tab -- including after a save, which is the moment
	// a user would most expect them back. Guessing a number here would be exactly
	// the Shape A the flag exists to prevent; the real fix is doc_save restarting
	// the index over the saved bytes, which is a change to SAVE behaviour and
	// Wyatt's call, not a drive-by in the gutter. See the batch-18 plan, §3a.
	//
	// Text_Muted, not the Text_Dim §10 literally names, and the reasoning is
	// TABLE_EMPTY_CELL's applied to a second case. Text_Dim is theme.odin's
	// disabled-only tier (2.9:1 Dark / 2.8:1 Light, below the AA floor); the
	// exemption it rests on is that a disabled control's dimness is redundant with
	// the control not responding. A row number is not redundant with anything --
	// §10's own justification for the gutter is that "counting rows by hand is the
	// gap", so the number IS the information, and a reader who cannot resolve it
	// has lost the whole feature. themetest's Text_Dim allowlist already holds
	// table.odin at zero for precisely this argument (it was raised as a review
	// finding against the em dash and the dash was moved off Text_Dim), and the
	// editor's own line-number gutter has always drawn in Text_Muted. Three
	// precedents, one answer. Recorded here because the batch-18 plan recommended
	// Text_Dim and this deviates from it deliberately.
	//
	// Text_Secondary on the current row is §10's, kept as written: that role
	// clears AA in both themes, so it is a legitimate brightening rather than a
	// second dim tier. "Current" is the row with an open cell edit -- the grid
	// takes no caret, so that is the only row this surface ever calls current.
	{
		num_fg := g_theme[.Text_Muted]
		cur_fg := g_theme[.Text_Secondary]
		gw := table_gutter_w()
		for _, r in vis {
			if absn[r] == TABLE_ABS_NONE {continue}
			// 1-based, because a reader counts from one. It coincides with the
			// FILE's line number (data row 0 is line 1, the header being line 0),
			// which is a convenience rather than a second meaning: both readings
			// name the same row.
			label := fmt.tprintf("%d", absn[r] + 1)
			w := f32(plat.text_cells(text, transmute([]u8)label, 0, .Doc)) * char_w
			// Right-aligned to the gutter's inner edge, and CLAMPED AT 0 rather
			// than truncated. Cutting digits off a row number silently changes
			// which row it names -- 10432 truncated to 1043 is not a shortened
			// label, it is a different row -- so a number too wide for 56px runs
			// left to the window edge and then keeps its full value, encroaching
			// on the first cell's left padding instead. That is a cosmetic
			// collision at six digits and up; a truncated number would be a lie at
			// every zoom level.
			gx := max(f32(0), gw - TABLE_CELL_PAD_X - w)
			colour := num_fg
			if doc.table_editing && doc.table_edit_row == r {colour = cur_fg}
			plat.text_draw(gfx, text, label, gx, table_row_baseline_y(px, r), px, colour, .Doc)
		}
	}

	// Pass 2: the cell text, column by column.
	fg := g_theme[.Text_Primary]
	dim := g_theme[.Text_Muted] // TABLE_EMPTY_CELL's comment records why not Text_Dim
	for col in cols {
		for row, r in vis {
			// A field this row does not have is MISSING, not empty -- a malformed
			// row, which §10 marks with a warning bar on the row's left edge
			// (group C). Skipping it here is what keeps the em dash meaning
			// "empty, and we know it" instead of meaning "short row".
			if col.c >= len(row.fields) {continue}
			field := row.fields[col.c]
			colour := fg
			// Measured after any truncation, never before: the alignment nudge
			// below is computed from what is actually DRAWN. Truncating first is
			// also what keeps the cut LEFT-anchored in a right-aligned column --
			// see table_cell_align_dx.
			cells := 0
			if len(field) == 0 {
				field, colour = TABLE_EMPTY_CELL, dim
				cells = plat.text_cells(text, transmute([]u8)field, 0, .Doc)
			} else {
				fb := transmute([]u8)field
				// Both col0 = 0, and they must match each other: this is the
				// measure/inverse pair for the same field, and a tab inside it
				// would be cut at the wrong byte if the two disagreed.
				cells = plat.text_cells(text, fb, 0, .Doc)
				if cells > col.cells { // truncate an over-wide field
					cut := plat.text_bytes_for_cells(text, fb, col.cells, 0, .Doc)
					field = field[:cut]
					cells = col.cells
				}
			}
			tx := table_cell_text_x(col) + table_cell_align_dx(col, cells, char_w)
			plat.text_draw(gfx, text, field, tx, table_row_baseline_y(px, r), px, colour, .Doc)
		}
	}

	// The cell being edited: draw the buffer + a caret over a highlight box,
	// instead of the source value, so the grid keeps its exact look.
	if doc.table_editing {
		er := doc.table_edit_row
		ec := doc.table_edit_col
		if er >= 0 && er < len(vis) {
			for col in cols {
				if col.c != ec {continue}
				box := g_theme[.Selection_List]
				plat.quads_draw(gfx, qp, []plat.Quad{{pos = {col.x, table_row_rect_y(px, er)}, size = {min(col.w, right - col.x), row_h}, color = box}})
				// LEFT-aligned even in a right-aligned column, and no
				// table_cell_align_dx here on purpose: this is an input field, not
				// a value. Right-aligning it would walk the whole buffer -- and the
				// caret with it -- one cell left on every keystroke, which is the
				// worst place in the grid to put motion. The committed value takes
				// the column's alignment on the next frame.
				tx := table_cell_text_x(col)
				val := string(doc.table_edit_buf[:])
				plat.text_draw(gfx, text, val, tx, table_row_baseline_y(px, er), px, g_theme[.Text_Bright], .Doc)
				// col0 = 0: the edit buffer IS the fragment, drawn from `tx` on
				// the line above, and the caret offsets from that same x.
				caret_cells := plat.text_cells(text, doc.table_edit_buf[:doc.table_edit_caret], 0, .Doc)
				plat.quads_draw(gfx, qp, []plat.Quad{{pos = {tx + f32(caret_cells) * char_w, table_row_rect_y(px, er)}, size = {hairline(), row_h}, color = g_theme[.Text_Bright]}})
				break
			}
		}
	}

	// The sticky header, LAST -- after every content pass, which is what makes it
	// sticky. There is no scissor facility here (see md_preview_clip): clipping is
	// a cover strip painted over the content, so painting the band and its rule
	// after the rows is both the convention and the guarantee that no row's
	// ascenders can reach up into the header's band on a zoomed font.
	//
	// Line 0 is read every frame regardless of doc.top -- one bounded pt_read at
	// offset 0, which is what "sticky" costs. Fetched FIRST and checked before
	// anything is drawn (F9): table_header_fields returns nil for an empty
	// document, and the band + rule used to be emitted unconditionally ahead of
	// this check, so opening a zero-length .csv drew a bare 30px raised band with
	// a rule over a page that had nothing else on it. Nothing to be sticky ABOVE
	// is nothing to draw.
	head := table_header_fields(doc)
	if len(head) > 0 {
		plat.quads_draw(gfx, qp, []plat.Quad{{pos = {0, table_grid_top()}, size = {right, table_header_h(px)}, color = g_theme[.Bg_Raised]}})
		// A 1px Border_Strong rule beneath it (§10). Border_Strong and not
		// Border_Subtle: this is the one boundary in the grid now that the column
		// rules are gone, and §1.1 names "table header rule" as what Border_Strong is
		// for. hairline() so it stays one device pixel at 125%/150% instead of
		// straddling two and rasterising blurry.
		plat.quads_draw(gfx, qp, []plat.Quad{{pos = {0, table_grid_top() + table_header_h(px) - hairline()}, size = {right, hairline()}, color = g_theme[.Border_Strong]}})
		hy := table_header_baseline_y(px)
		for col in cols {
			if col.c >= len(head) {continue}
			field := head[col.c]
			if len(field) == 0 {continue} // a nameless column: leave it blank, don't dash a header
			fb := transmute([]u8)field
			hcells := plat.text_cells(text, fb, 0, .Doc)
			if hcells > col.cells {
				field = field[:plat.text_bytes_for_cells(text, fb, col.cells, 0, .Doc)]
				hcells = col.cells
			}
			// The header takes its column's alignment, so a right-aligned numeric
			// column reads as ONE column rather than as a left-aligned label with
			// right-aligned numbers wandering away underneath it.
			// Text_Bright, the role §1.1 gives to "active tab label, titles" --
			// the header is now a real header (§10) and the previous draw made no
			// distinction at all: both branches of its `hl` resolved to
			// Text_Primary, so the "highlighted" header row was a no-op.
			hx := table_cell_text_x(col) + table_cell_align_dx(col, hcells, char_w)
			plat.text_draw(gfx, text, field, hx, hy, px, g_theme[.Text_Bright], .Doc)
		}
	}
	return
}

// --- in-cell editing -------------------------------------------------------

@(private = "file")
Field_Range :: struct {
	s, e: int, // raw byte span [s,e) of the field within its line (between delimiters)
}

// Raw byte spans of each field in `line` (quotes included), so an edit can
// replace exactly one field's source text.
@(private = "file")
csv_field_ranges :: proc(line: string, delim: u8, allocator := context.temp_allocator) -> []Field_Range {
	out := make([dynamic]Field_Range, 0, 8, allocator)
	i, n, s := 0, len(line), 0
	in_q := false
	for i < n {
		c := line[i]
		if in_q {
			if c == '"' {
				if i + 1 < n && line[i + 1] == '"' {i += 2;continue}
				in_q = false
			}
			i += 1
		} else {
			switch c {
			case '"':
				in_q = true
				i += 1
			case delim:
				append(&out, Field_Range{s, i})
				s = i + 1
				i += 1
			case:
				i += 1
			}
		}
	}
	append(&out, Field_Range{s, n})
	return out[:]
}

// Serialize a cell value back to CSV: quote (and "" -escape) only if it contains
// the delimiter, a quote, or a newline.
@(private = "file")
csv_serialize :: proc(value: string, delim: u8, allocator := context.temp_allocator) -> string {
	needs := false
	for i in 0 ..< len(value) {
		if value[i] == delim || value[i] == '"' || value[i] == '\n' || value[i] == '\r' {needs = true;break}
	}
	if !needs {return value}
	sb := strings.builder_make(allocator)
	strings.write_byte(&sb, '"')
	for i in 0 ..< len(value) {
		if value[i] == '"' {strings.write_byte(&sb, '"')}
		strings.write_byte(&sb, value[i])
	}
	strings.write_byte(&sb, '"')
	return strings.to_string(sb)
}

// The field at (visible data row r, column col): its source byte range and its
// unquoted value. The tail both hit-tests share, so a click and a Tab step
// resolve one line through one walk. `p` comes from table_row_start, never from
// a walk of this proc's own.
@(private = "file")
table_field_at :: proc(doc: ^Document, r, col: int) -> (ok: bool, fs, fe: int, val: string) {
	p, pok := table_row_start(doc, r)
	if !pok {return}
	delim := doc.table_delim if doc.table_delim != 0 else ','
	end := base.pt_line_end_cap(&doc.pt, p, RENDER_LINE_CAP)
	buf := make([]u8, end - p, context.temp_allocator)
	got := base.pt_read(&doc.pt, p, buf)
	ln := got
	if ln > 0 && buf[ln - 1] == '\r' {ln -= 1}
	line := string(buf[:ln])
	ranges := csv_field_ranges(line, delim)
	if col >= len(ranges) {return} // past the last field on the row
	fs = p + ranges[col].s
	fe = p + ranges[col].e
	fields := csv_fields(line, delim)
	val = strings.clone(fields[col] if col < len(fields) else "", context.temp_allocator)
	ok = true
	return
}

// The cell under a client-space point, and its source byte range + unquoted
// value. Resolves through table_row_at_y and table_cols_layout -- the same two
// producers table_draw positions with -- so the byte range this returns is the
// range under the pointer by construction. The edit path writes it, so a
// divergence here is a write to the wrong row, not a misplaced pixel.
//
// A press on the sticky header returns ok=false (table_row_at_y refuses it), so
// the header is inert for now rather than editing the first data row's cell.
// §10 gives that click to sort, which is group C.
table_cell_at :: proc(doc: ^Document, mx, my, px, char_w: f32, rows: int, width: f32) -> (ok: bool, r, col, fs, fe: int, val: string) {
	if len(doc.table_widths) == 0 {return}
	rr, rok := table_row_at_y(px, my)
	if !rok || rr >= rows {return}
	r = rr
	col = -1
	for c in table_cols_layout(doc, char_w, width, table_start_col(doc)) {
		if mx >= c.x && mx < c.x + c.w {col = c.c;break}
	}
	if col < 0 {return}
	ok, fs, fe, val = table_field_at(doc, r, col)
	return
}

// A cell by (visible row, column) rather than by point — for Tab stepping to
// the next cell. Returns the same source range + value as table_cell_at.
table_cell_at_index :: proc(doc: ^Document, r, col, rows: int) -> (ok: bool, rr, cc, fs, fe: int, val: string) {
	if r < 0 || r >= rows || col < 0 || col >= doc.table_cols {return}
	ok, fs, fe, val = table_field_at(doc, r, col)
	if ok {rr, cc = r, col}
	return
}

table_edit_start :: proc(doc: ^Document, r, col, fs, fe: int, val: string) {
	doc.table_editing = true
	doc.table_edit_row = r
	doc.table_edit_col = col
	doc.table_edit_s = fs
	doc.table_edit_e = fe
	// Through table_row_start, the same producer table_field_at derived fs from,
	// so the anchor is the line [fs,fe) lies on by construction rather than by
	// two walks agreeing. Recorded here because this is the only place an edit
	// begins; table_edit_anchored below is the only place it is read.
	doc.table_edit_line, _ = table_row_start(doc, r)
	// ...and the line's BYTES, which is the identity a reordering cannot forge.
	// Same capped extent table_field_at derived fs/fe from, so [fs,fe) is a
	// sub-range of what is copied here by construction.
	//
	// A SHORT read (a mapped original that faulted mid-copy, via safe_copy)
	// leaves fewer bytes than the line's extent, and table_edit_line_intact then
	// refuses on the length compare for the rest of the edit's life. That is
	// deliberate and fail-closed: if the bytes could not be read at capture there
	// is no identity to check a commit against, and refusing to splice is the
	// only answer that cannot write over the wrong row.
	clear(&doc.table_edit_snap)
	{
		e := base.pt_line_end_cap(&doc.pt, doc.table_edit_line, RENDER_LINE_CAP)
		if n := e - doc.table_edit_line; n > 0 {
			resize(&doc.table_edit_snap, n)
			if got := base.pt_read(&doc.pt, doc.table_edit_line, doc.table_edit_snap[:]); got != n {
				resize(&doc.table_edit_snap, got)
			}
		}
	}
	clear(&doc.table_edit_buf)
	append(&doc.table_edit_buf, ..transmute([]u8)val)
	doc.table_edit_caret = len(doc.table_edit_buf)
}

// Is the open cell edit still ON the cell it was started on?
//
// THE SEAM, stated as a predicate. doc.table_edit_row is a VISIBLE row index and
// doc.table_edit_s/e are ABSOLUTE byte offsets captured at edit start, so the two
// only agree while the view has not moved. Scroll the grid and the highlight box,
// the caret and the drawn buffer all stay at table_row_rect_y(px, table_edit_row)
// over whatever line is now that row, while a commit still splices at [s,e) --
// a write to a row the user is not looking at.
//
// commands.odin:939 already reasoned this through for BUFFER writes invalidating
// a captured span (the line-ending rewrite, undo, history jump, find/replace).
// This is the same shape one level out: the span stays valid, its ON-SCREEN
// IDENTITY does not. It was never covered.
//
// Three halves, and they are three different questions:
//
//   rows  -- the row must still EXIST on screen. Shrinking the window past the
//            edited row stops the box being drawn (table_draw's `er < len(vis)`)
//            while doc.table_editing stays true, so keystrokes keep accumulating
//            into a buffer nothing shows and a later Enter still commits it.
//   line  -- the row must still name the SAME OFFSET. This is the scroll case,
//            and the compare is against table_row_start rather than against
//            doc.top because table_data_start normalises doc.top (the header is
//            sticky and owns line 0), so two different doc.top values can be the
//            same scroll position and must not read as a move.
//   bytes -- the offset must still hold the SAME LINE. Offsets are not identities:
//            a buffer REWRITE can leave the r-th line starting exactly where it
//            started before, and then the two compares above both pass while
//            [s,e) has come to span a different row's field. See
//            table_edit_line_intact -- this is the half that catches a sort.
table_edit_anchored :: proc(doc: ^Document, rows: int) -> bool {
	if doc == nil || !doc.table_editing {return false}
	if doc.table_edit_row < 0 || doc.table_edit_row >= rows {return false}
	p, ok := table_row_start(doc, doc.table_edit_row)
	if !ok || p != doc.table_edit_line {return false}
	return table_edit_line_intact(doc)
}

// Does doc.table_edit_line still hold the bytes it held when the edit began?
//
// THE ANCHOR'S FORGERY-PROOF HALF, and the reason the two offset compares above
// are not enough on their own. A byte offset is not a row identity: permute lines
// that all have the SAME BYTE LENGTH -- a fixed-width export, which is what
// exports look like: `00012,2026-01-14,ACTIVE`, zero-padded ids, ISO dates, fixed
// status codes -- and the r-th line still starts at the r-th offset. Edit row 11's
// first cell, sort, and rows 11 and 12 swap: table_row_start(doc, 11) still equals
// doc.table_edit_line, the offset compare reads "nothing moved", and a commit
// splices the user's typed value over row 12's id.
//
// So the identity is the line's OWN BYTES, copied at edit start (table_edit_start)
// and compared here. A reordering cannot forge that: any line whose bytes differ
// anywhere -- a different id, a different date, one different status code, a
// different length -- fails the compare and the edit is refused. What it CANNOT
// distinguish is a permutation that swaps two BYTE-IDENTICAL lines, and that is
// the one case where it does not need to: both rows held the same value, the
// commit writes the value the user typed into a row indistinguishable from the one
// they clicked, and no other row's data is touched. Nothing is lost, which is the
// property being defended.
//
// Chosen over the two alternatives on offer:
//   - a generation counter bumped by any reordering -- whoever writes the sort has
//     to remember to bump it, which is the exact class of miss this guard exists
//     to close (seven scroll routes, two of them handled). The bytes need nobody
//     to remember anything.
//   - a hash of the line -- smaller, but only probabilistically unforgeable, and
//     the line is already capped at RENDER_LINE_CAP so the exact bytes are cheap.
//
// Cost: one capped read per frame while a cell edit is open, in 512-byte chunks
// so nothing here puts an 8 KB buffer on the frame loop's stack. table_row_start
// already walks the same lines every frame; this walks one of them again.
@(private = "file")
table_edit_line_intact :: proc(doc: ^Document) -> bool {
	if doc.table_edit_line < 0 || doc.table_edit_line > doc.pt.length {return false}
	e := base.pt_line_end_cap(&doc.pt, doc.table_edit_line, RENDER_LINE_CAP)
	n := e - doc.table_edit_line
	if n != len(doc.table_edit_snap) {return false}
	buf: [512]u8
	off := 0
	for off < n {
		c := min(len(buf), n - off)
		if got := base.pt_read(&doc.pt, doc.table_edit_line + off, buf[:c]); got != c {return false}
		if string(buf[:c]) != string(doc.table_edit_snap[off:off + c]) {return false}
		off += c
	}
	return true
}

// Commit an edit that has stopped sitting on its own cell -- the single guard,
// called once per frame from the update phase (main.odin) after every path that
// could have moved the view and before the draw reads any of it.
//
// COMMIT, not cancel, and that is a decision. The wheel has committed since the
// grid shipped ("rows shift underfoot", main.odin) and leave_table_view commits
// too, so the user's typing has always survived a scroll on the one route that
// handled this at all; making the other routes cancel instead would mean the
// same keystrokes are kept or thrown away depending on WHICH scroll gesture was
// used. The commit goes to [table_edit_s, table_edit_e) -- the bytes the edit
// was started on -- which is the cell the user was looking at when they typed.
//
// One guard rather than a commit bolted onto each scroll path: the wheel, the
// scrollbar drag, Page Up/Down, Ctrl+Home/End, a find jump, a session restore
// and a resize are seven routes and only two of them had it. A per-route commit
// is seven chances to miss the eighth.
//
// COMMIT is right for the view-moved case and WRONG for the bytes-moved case, and
// table_edit_commit itself makes that distinction rather than this proc -- see its
// own refusal. A rewrite under [s,e) leaves nowhere safe to write, so the only
// answer is to drop the keystrokes; a scroll leaves [s,e) exactly where it was.
table_edit_hold :: proc(doc: ^Document, rows: int) {
	if doc == nil || !doc.table_editing {return}
	if !table_edit_anchored(doc, rows) {table_edit_commit(doc)}
}

table_edit_rune :: proc(doc: ^Document, rn: rune) {
	if rn < 32 {return}
	bytes, n := utf8.encode_rune(rn)
	inject_at(&doc.table_edit_buf, doc.table_edit_caret, ..bytes[:n])
	doc.table_edit_caret += n
}

table_edit_backspace :: proc(doc: ^Document) {
	if doc.table_edit_caret <= 0 {return}
	p := doc.table_edit_caret - 1
	for p > 0 && (doc.table_edit_buf[p] & 0xC0) == 0x80 {p -= 1}
	remove_range(&doc.table_edit_buf, p, doc.table_edit_caret)
	doc.table_edit_caret = p
}

table_edit_delete :: proc(doc: ^Document) {
	if doc.table_edit_caret >= len(doc.table_edit_buf) {return}
	e := doc.table_edit_caret + 1
	for e < len(doc.table_edit_buf) && (doc.table_edit_buf[e] & 0xC0) == 0x80 {e += 1}
	remove_range(&doc.table_edit_buf, doc.table_edit_caret, e)
}

table_edit_move :: proc(doc: ^Document, dir: int) {
	if dir < 0 {
		if doc.table_edit_caret <= 0 {return}
		p := doc.table_edit_caret - 1
		for p > 0 && (doc.table_edit_buf[p] & 0xC0) == 0x80 {p -= 1}
		doc.table_edit_caret = p
	} else {
		if doc.table_edit_caret >= len(doc.table_edit_buf) {return}
		p := doc.table_edit_caret + 1
		for p < len(doc.table_edit_buf) && (doc.table_edit_buf[p] & 0xC0) == 0x80 {p += 1}
		doc.table_edit_caret = p
	}
}

table_edit_home :: proc(doc: ^Document) {doc.table_edit_caret = 0}
table_edit_end :: proc(doc: ^Document) {doc.table_edit_caret = len(doc.table_edit_buf)}

// Write the edited value back into the source field and stop editing. Goes
// through the document's undo, and clears the width cache so the columns re-fit.
table_edit_commit :: proc(doc: ^Document) {
	if !doc.table_editing {return}
	doc.table_editing = false
	// GUARD THE WRITE, NOT THE ROUTES TO IT. If the bytes under [s,e) are no
	// longer the bytes the edit was started on, this splice would land the user's
	// typed value on somebody else's field, and there is no offset to redirect it
	// to -- the line it belonged to has been moved by a rewrite this proc cannot
	// see. Discard instead. That is the ONE case where the user's keystrokes are
	// thrown away rather than kept (see table_edit_hold's own note on why every
	// scroll route commits), and it is the only case where keeping them means
	// overwriting data the user never touched.
	//
	// Here rather than only in table_edit_hold because the hold guard is not on
	// every path in: Enter dispatches here directly, and so do the wheel arm
	// (main.odin), leave_table_view and .Toggle_Table. Four more chances to miss
	// the fifth -- the same argument that put one guard in the frame loop instead
	// of seven commits in seven scroll handlers, applied to the write itself.
	if !table_edit_line_intact(doc) {return}
	// The one buffer write table view has, and therefore the one place a
	// column rectangle can go stale without any command dispatch running.
	// command_dispatch's own block-clear branch is unreachable here twice
	// over: the table guard returns early for every mutating command while
	// doc.table is set, and cell editing is intercepted before dispatch
	// (main.odin) so no Command_Id is ever produced. The splice below shifts
	// every byte offset after the edited field, which is precisely what makes
	// a rectangle's row offsets stop naming the rows it was drawn over.
	// Clearing here rather than only at the .Toggle_Table seam is the same
	// argument that put the clear inside find.odin's replace procs: guard the
	// write, not the routes to it.
	//
	// Placed after the not-editing early return deliberately -- this proc is
	// called speculatively from several places (the wheel, the toggle) and
	// only the calls that actually splice may drop the user's selection.
	if block_active(doc) {block_clear(doc)}
	delim := doc.table_delim if doc.table_delim != 0 else ','
	ser := csv_serialize(string(doc.table_edit_buf[:]), delim)
	doc_replace_range(doc, doc.table_edit_s, doc.table_edit_e - doc.table_edit_s, transmute([]u8)ser)
	clear(&doc.table_widths) // re-fit columns next frame
}

table_edit_cancel :: proc(doc: ^Document) {
	doc.table_editing = false
}

// Exercises the byte-range parser and the serializer, and the edit as a whole:
// take a field's raw span, drop in a new (serialized) value, and check the
// resulting line. This is the exact splice table_edit_commit does through the
// piece tree, done here on a plain string so the round trip is unit-testable.
// Returns the failure count. Driven by `newtpad tablecellstest`.
table_selftest :: proc() -> (bad: int) {
	// 1. field ranges cover the raw fields exactly (quotes included).
	{
		line := `a,"b,c",d`
		r := csv_field_ranges(line, ',')
		want := []string{"a", `"b,c"`, "d"}
		ok := len(r) == len(want)
		if ok {for f, i in want {if line[r[i].s:r[i].e] != f {ok = false;break}}}
		fmt.printfln("  ranges %-14q -> %v", line, "OK" if ok else "FAIL")
		if !ok {bad += 1}
	}
	// 2. serialize quotes only when it must, and "" -escapes quotes.
	{
		Case :: struct {
			in_, want: string,
		}
		cases := []Case {
			{"plain", "plain"},
			{"has,comma", `"has,comma"`},
			{`has"quote`, `"has""quote"`},
			{"", ""},
			{"tab\tsep", "tab\tsep"}, // comma delim: a tab is not special
		}
		for c in cases {
			got := csv_serialize(c.in_, ',')
			ok := got == c.want
			fmt.printfln("  serial %-14q -> %-16q %s", c.in_, got, "OK" if ok else fmt.tprintf("FAIL want %q", c.want))
			if !ok {bad += 1}
		}
	}
	// 3. full edit splice: replace one field's raw span with the serialized new
	//    value, matching what table_edit_commit writes back.
	{
		Case :: struct {
			line:      string,
			col:       int,
			new_val:   string,
			want_line: string,
		}
		cases := []Case {
			{"a,b,c", 1, "X", "a,X,c"},
			{"a,b,c", 1, "x,y", `a,"x,y",c`}, // new value needs quoting
			{`a,"b,c",d`, 1, "plain", "a,plain,d"}, // quoted -> unquoted
			{"a,b,c", 0, "", ",b,c"},
			{"a,b,c", 2, `he said "hi"`, `a,b,"he said ""hi"""`},
		}
		for c in cases {
			r := csv_field_ranges(c.line, ',')
			ser := csv_serialize(c.new_val, ',')
			got := fmt.tprintf("%s%s%s", c.line[:r[c.col].s], ser, c.line[r[c.col].e:])
			ok := got == c.want_line
			fmt.printfln("  splice %-12q [%d]=%-10q -> %-16q %s", c.line, c.col, c.new_val, got, "OK" if ok else fmt.tprintf("FAIL want %q", c.want_line))
			if !ok {bad += 1}
		}
	}
	return
}
