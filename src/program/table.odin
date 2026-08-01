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
import "core:slice"
import "core:strconv"
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
//   leftover  §10 says distribute proportionally -- IMPLEMENTED, then DELIBERATELY
//             REVERSED on 2026-07-31 by Wyatt's decision on live evidence. See
//             table_cols_layout: a column is now laid out at its CONTENT width and
//             the spare width is left empty on the right. This is a deviation from
//             §10's literal rule and is recorded as one -- CLAUDE.md gives the spec
//             the last word about what SHOULD exist, and the product owner
//             overruled it here after seeing the result. Do not "fix" it back.
//
// NOT shared with markdown's md_table_fit_cells, and that is a considered answer
// to "two implementations of one rule is the shape this project keeps getting
// bitten by" rather than an oversight. The two surfaces want opposite things
// from the same sentence. md_table_fit_cells SHRINKS natural widths into a fixed
// measure and, under real pressure, drops columns -- correct for the markdown
// preview, which has no horizontal scroll and would otherwise paint a table over
// the scrollbar. The grid does have horizontal scroll (doc.table_hscroll_px,
// table_scroll_x, the h-scrollbar), so a column too wide for the window is
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

// §10's "a row with the wrong field count gets a 2px warning bar on its left
// edge". Through sx() at its one use site rather than as a scaled global beside
// TABLE_GUTTER_W, and the distinction is TABLE_RESIZE_HIT_96's: the gutter is
// LAYOUT -- five consumers of the x axis have to agree on it to the pixel -- while
// this is a decoration nothing hit-tests, wanted by the draw alone. sx() rounds
// to whole device pixels, so the bar is 2/3/3 at 100/125/150% rather than
// straddling two and rasterising as a smear.
TABLE_WARN_W_96 :: f32(2)

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

// Height of §10's summary row -- "row count, column count, active sort" -- which
// owns the bottom of the grid the way the header owns the top.
//
// The data row's height, not a number of its own. §10 gives the summary no metric,
// and reusing table_row_h keeps the band on the grid's own rhythm at every zoom and
// DPI without a second constant to keep in step with it. It is chrome rather than
// data, which the fill and the rule below it say (table_draw); the height is only
// asked to be the same size as a row, and it is.
table_summary_h :: #force_inline proc(px: f32) -> f32 {return table_row_h(px)}

// EVERYTHING the grid reserves along its bottom edge: the summary row AND the
// horizontal scrollbar's strip. THE producer -- the row budget subtracts it, the
// summary's own y is measured off it, and the tests size their windows with it.
//
// The two used to be laid out independently and they collided: hscrollbar_geo
// pins the bar to `winh - doc_bottom_bar_h - h` and table_summary_y pinned the
// summary to `doc_content_box's bot - summary_h`, which is the same bottom edge,
// so the bar was painted across the bottom 8px of the summary text (Wyatt, live
// use, v0.34.0, with a screenshot). Neither band is optional -- a grid wider than
// its window has to be pannable, and §10's summary answers the questions a reader
// has about a CSV -- so the newer arrival yields and the summary sits ABOVE the
// bar.
//
// FIXED IN THE ONE PRODUCER, not by nudging the summary's y in the draw. The
// h-scrollbar's drag hit-test reads hscrollbar_geo, so a draw-side nudge would
// leave the painted summary and the clickable bar disagreeing about which strip
// is which -- CLAUDE.md's "one layout per widget" in its most expensive form,
// since the disagreement is invisible until somebody drags.
//
// The bar's strip is reserved UNCONDITIONALLY, even on a table narrow enough that
// hscrollbar_geo returns shown = false (one column, or a window too narrow for a
// 30px track). Making the reservation conditional would mean asking hscroll_model
// -- which needs a ^plat.Text and a char_w that neither this procedure nor
// doc_scroll_rows has -- and would make the grid's ROW COUNT change when a column
// is dragged wide enough to need panning, i.e. the number of visible rows would
// depend on a horizontal gesture. A permanently empty 8px strip under a
// single-column CSV is the cheaper answer by a wide margin.
table_bottom_band_h :: #force_inline proc(px: f32) -> f32 {
	return table_summary_h(px) + hscrollbar_h()
}

// Top y of the summary band: pinned to the bottom of the content box less the
// h-scrollbar's strip, not to the last row. Anchored to the row grid it would
// jitter up and down by the viewport's remainder as the window is resized, and a
// strip whose position depends on how the rows happened to divide is not a bar.
table_summary_y :: #force_inline proc(doc: ^Document, height, px: f32) -> f32 {
	_, bot := doc_content_box(doc, height)
	return bot - table_bottom_band_h(px)
}

// Data rows that fit below the sticky header. The grid's answer to
// doc_visible_rows, which cannot serve here: it divides the content box by the
// editor's line_height and knows nothing about the header band, so it over-counts
// the grid's rows by roughly the header's height plus the row-height difference.
// Feeds the draw, both hit-tests and -- through doc_scroll -- the scroll clamp,
// which is why it exists rather than each of them trimming `rows` by eye.
//
// The bottom band -- the summary row AND the h-scrollbar's strip -- is subtracted
// HERE, in the one producer, for exactly that reason. Trimming it in the draw
// alone would leave the hit-test resolving a click on the summary strip to a data
// row underneath it -- and in this view that is a cell edit started on a row the
// user cannot see, which is the data-loss shape the whole file is arranged
// against.
table_visible_rows :: proc(doc: ^Document, height, px: f32) -> int {
	_, bot := doc_content_box(doc, height)
	return max(0, int((bot - table_bottom_band_h(px) - table_rows_top(px)) / table_row_h(px)))
}

// --- §10's summary row: "row count, column count, active sort" ------------

// Data rows in the FILE, and whether that number is settled.
//
// exact = false means Line_Index is still counting, and §10's summary must then
// read as approximate ("~4.2M rows") rather than as a number that silently changes
// while the reader is looking at it. That is the same two-result contract
// doc_line_no_at has and for the same reason (development-loop.md §4, Shape A): a
// partial count is not a small error, it is a confident wrong answer.
//
// Two subtractions from the line count, and both are about what a "line" is:
//   - the HEADER is line 0 and is not a data row (table_first_data_row);
//   - a file ending in '\n' leaves a zero-length final line, which is the file's
//     terminator and not a row. The unsorted grid still draws it as a blank row at
//     the bottom (a pre-existing artefact tracked separately) and the sort's own
//     pass already excludes it; the count agrees with the sort.
table_row_count :: proc(doc: ^Document) -> (n: int, exact: bool) {
	if doc == nil || doc.pt.length == 0 {return 0, true}
	n = doc_line_count(doc) - 1
	last: [1]u8
	if got := base.pt_read(&doc.pt, doc.pt.length - 1, last[:]); got == 1 && last[0] == '\n' {n -= 1}
	exact = doc_index_done(doc) && !doc_index_faulted(doc) && !base.pt_faulted(&doc.pt)
	return max(0, n), exact
}

// Thousands-grouped decimal, for the settled count. `12438201` -> `12,438,201`.
// Hand-rolled because fmt has no grouping verb and a CSV's row count is the one
// number in this app a reader compares against another tool's.
@(private = "file")
group_int :: proc(v: int, allocator := context.temp_allocator) -> string {
	if v < 1000 {return fmt.tprintf("%d", v)}
	digits := fmt.tprintf("%d", v)
	sb := strings.builder_make(allocator)
	for i in 0 ..< len(digits) {
		if i > 0 && (len(digits) - i) % 3 == 0 {strings.write_byte(&sb, ',')}
		strings.write_byte(&sb, digits[i])
	}
	return strings.to_string(sb)
}

// §10's summary line.
//
// THE APPROXIMATE COUNT IS THE POINT OF THIS PROCEDURE. While Line_Index is still
// scanning, the row count is whatever the worker has reached so far -- a number
// that grows every frame. Printing it grouped and exact ("2,113,904 rows") is a
// settled-looking fact that is wrong and will be different in a moment, and a
// reader who glances at it once carries the wrong number away. `~4.2M rows` cannot
// be mistaken for a total, and the tilde is doing the work: it is rounded on
// purpose so that it does not appear to change either.
//
// The COLUMN count is the grid's (doc.table_cols), not the header's, and they can
// differ -- table_compute_widths takes the maximum column index over its sample, so
// one row with a stray delimiter adds a column the header never declared. The
// summary describes what is on screen, and the disagreement itself is already being
// reported by the warning bars on the rows that cause it (table_row_malformed).
//
// The REFUSAL is here rather than left silent, and that is the honest half of
// "a file too large to index refuses the sort". A header that does nothing when
// clicked is indistinguishable from a broken build; a summary that says
// "12,438,201 rows - too large to sort" is a product decision the reader can see.
// THE SORT CLAUSE SAYS THE UNDO IN WORDS, and that is the second half of the
// answer to "there is no discoverable way to reset the sort" (Wyatt, live use,
// v0.34.0). table_sort_cycle has cycled ascending -> descending -> the file's own
// order since the sort shipped; nothing anywhere said so, and Wyatt rejected three
// proposals that added another unlabelled target with *"how will the person know
// what to click and where to reset."* He is right, and the principle generalises:
// **a bare three-click cycle cannot be made discoverable, only labelled.** So the
// sentence reads `sorted by Date desc  ·  click to clear`, and the run of text
// that says it is itself the target (table_summary_layout).
//
// The WORDS are the point. Not an icon, not an ×, not a tooltip: the two questions
// a first-time reader has are "can I click this?" -- answered by the header's
// hover state (table_header_hover_col) -- and "how do I undo it?", which is this,
// and only prose answers the second one without the reader already knowing.
//
// `clear_s`/`clear_e` bound that run inside the returned string so the layout can
// measure it. They are a byte span into `text`, zero-length when there is no sort,
// and they are produced HERE, beside the sbprintf that writes the words, because a
// second procedure computing "where does the sort clause start" from the finished
// string would be re-deriving what this one already knows -- and would silently
// name the wrong bytes the first time the wording changed.
table_summary_parts :: proc(doc: ^Document, allocator := context.temp_allocator) -> (text: string, clear_s, clear_e: int) {
	n, exact := table_row_count(doc)
	sb := strings.builder_make(allocator)
	if exact {
		fmt.sbprintf(&sb, "%s row%s", group_int(n, allocator), "" if n == 1 else "s")
	} else if n <= 0 {
		// The worker has published nothing yet, which is the FIRST frame of every
		// large file -- exactly when this row is most looked at. "~0 rows" is a
		// number, and a wrong one; naming the state instead is the only reading that
		// is true at the moment it is drawn.
		fmt.sbprint(&sb, "counting rows…")
	} else if n >= 1_000_000 {
		fmt.sbprintf(&sb, "~%.1fM rows", f64(n) / 1_000_000)
	} else if n >= 1_000 {
		fmt.sbprintf(&sb, "~%.1fK rows", f64(n) / 1_000)
	} else {
		fmt.sbprintf(&sb, "~%d rows", n)
	}
	c := doc.table_cols
	fmt.sbprintf(&sb, "  ·  %d column%s", c, "" if c == 1 else "s")
	switch {
	case doc.table_sort.refused:
		fmt.sbprintf(&sb, "  ·  too large to sort (over %s rows)", group_int(TABLE_SORT_MAX, allocator))
	case table_sorted(doc):
		// The separator stays OUTSIDE the clickable run: it is punctuation between
		// two facts, not part of the sentence that offers the action, and a target
		// that starts on a middle dot would extend three characters left of the
		// first word that explains it.
		fmt.sbprint(&sb, "  ·  ")
		clear_s = strings.builder_len(sb)
		fmt.sbprintf(&sb, "sorted by %s %s  ·  click to clear", table_col_name(doc, doc.table_sort.keys[0].col, allocator), "desc" if doc.table_sort.keys[0].desc else "asc")
		clear_e = strings.builder_len(sb)
	}
	return strings.to_string(sb), clear_s, clear_e
}

// The line alone, for every reader that only wants the words.
table_summary_text :: proc(doc: ^Document, allocator := context.temp_allocator) -> string {
	t, _, _ := table_summary_parts(doc, allocator)
	return t
}

// --- the summary band's geometry: ONE producer ----------------------------
//
// The band's rect, the text's origin, and the rect of the `sorted by ... · click
// to clear` run -- produced once, consumed by the draw AND by the press
// (main.odin). The run is a NEW HIT REGION at the bottom of the grid, immediately
// above the horizontal scrollbar's strip, so the two are laid out from the one
// bottom-band producer (table_bottom_band_h) and cannot overlap the way the
// summary and the bar themselves did.
//
// Measured in CELLS and multiplied by char_w, which is exact rather than
// approximate: the summary draws in the document face on the same fixed cell grid
// every other measurement in this file uses, so the x this returns is the x the
// glyphs land on and not an estimate of it.
//
// `clearable` is false whenever there is no sort, and then the rect is zero -- a
// dead region cannot be clicked into by a caller that forgets to check, because
// there is nothing there to hit.
Table_Summary :: struct {
	text:             string, // the whole line
	head:             string, // everything before the clickable run (== text when there is none)
	clear_text:       string, // the run itself, empty when nothing is sorted
	x, y, h:          f32, // the band: y/h, and the text's left origin
	clear_x, clear_w: f32, // the clickable run's rect, empty when nothing is sorted
	clearable:        bool,
}

table_summary_layout :: proc(doc: ^Document, t: ^plat.Text, height, px, char_w: f32, allocator := context.temp_allocator) -> (sm: Table_Summary) {
	text, cs, ce := table_summary_parts(doc, allocator)
	sm.text, sm.head = text, text
	sm.x = TABLE_CELL_PAD_X
	sm.y = table_summary_y(doc, height, px)
	sm.h = table_summary_h(px)
	if ce <= cs || char_w <= 0 {return}
	sm.head, sm.clear_text = text[:cs], text[cs:ce]
	hcells := plat.text_cells(t, transmute([]u8)sm.head, 0, .Doc)
	run := plat.text_cells(t, transmute([]u8)sm.clear_text, hcells, .Doc)
	sm.clear_x = sm.x + f32(hcells) * char_w
	sm.clear_w = f32(run) * char_w
	sm.clearable = true
	return
}

// Is this point on the run that says `click to clear`? The hit-test half of the
// producer above, so the pixels that carry the words are the pixels that clear the
// sort -- and no others. The whole band is deliberately NOT the target: at the
// left end it reads `30 rows`, which promises nothing and should do nothing.
table_summary_clear_hit :: proc(sm: Table_Summary, mx, my: f32) -> bool {
	if !sm.clearable {return false}
	return my >= sm.y && my < sm.y + sm.h && mx >= sm.clear_x && mx < sm.clear_x + sm.clear_w
}

// A column's name for the summary: its header cell, or a positional fallback when
// the header cell is blank. 1-based in the fallback, because the summary is prose
// for a reader and the row-number gutter counts from one for the same reason.
@(private = "file")
table_col_name :: proc(doc: ^Document, c: int, allocator := context.temp_allocator) -> string {
	head := table_header_fields(doc, allocator)
	if c >= 0 && c < len(head) && len(strings.trim_space(head[c])) > 0 {return head[c]}
	return fmt.tprintf("column %d", c + 1)
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
	f, fok := table_first_data_row(doc)
	if !fok {return 0, false}
	return max(doc.top, f), true
}

// Byte offset of the FILE's first data row -- line 1, whatever doc.top is.
//
// Split out of table_data_start because the sort needs the file's own starting
// point and table_data_start answers a different question (where the VIEW starts,
// which is doc.top normalised against it). Two callers, one definition of "the
// header owns line 0 and is not a data row"; deriving it a second time inside the
// sort is how the sort would come to disagree with the grid about which line is
// row 0, and every offset in the permutation would be one row out.
table_first_data_row :: proc(doc: ^Document) -> (start: int, ok: bool) {
	if doc == nil || doc.pt.length == 0 {return 0, false}
	e0 := base.pt_line_end_cap(&doc.pt, 0, RENDER_LINE_CAP)
	if e0 >= doc.pt.length {return 0, false} // header only: nothing below it
	return e0 + 1, true
}

// Byte offset of the start of visible data row r. The row-index -> byte half of
// the seam; table_row_at_y is the pixel -> row-index half, and between them they
// are the whole pixel -> byte mapping the edit path writes through.
//
// UNDER A SORT THIS IS NO LONGER A WALK, and that is the whole of group C's risk.
// The r-th visible row is not the r-th line after table_data_start any more; it is
// whatever the permutation puts at sorted position pos+r. table_cell_at resolves a
// pixel through here and table_edit_commit writes the byte range that comes out,
// so a version of this that ignored the permutation would splice the user's typed
// value onto a line they never clicked. Changed HERE and nowhere else: the
// hit-test, the Tab step, the link layout, the edit anchor and the draw all read
// through this one procedure.
//
// The draw does NOT call this per row. It takes row 0 from here and steps with
// table_row_next -- which is the same procedure this loop below calls, so the
// draw's step and this producer's step are one piece of code rather than two that
// have to agree. See table_row_next for why that mattered enough to restructure.
table_row_start :: proc(doc: ^Document, r: int) -> (p: int, ok: bool) {
	if r < 0 {return 0, false}
	s, sok := table_data_start(doc)
	if !sok {return 0, false}
	// Sorted: one binary search for where the top row sits in the sorted order,
	// then a lookup. O(log n) and no line walking at all, which is why the draw can
	// afford to ask per row in this mode.
	if table_sorted(doc) {
		pos, pok := table_sort_pos(doc, s)
		if !pok {return 0, false}
		return table_sort_row_at(doc, pos + r)
	}
	p = s
	for i in 0 ..< r {
		np, more, _ := table_row_next(doc, p, i + 1)
		if !more {return 0, false} // no such row
		p = np
	}
	if p > doc.pt.length {return 0, false}
	return p, true
}

// The start of the row AFTER the one starting at `p`, where `r` is the NEXT row's
// visible index.
//
// THE STEP, shared by table_row_start's loop and by every sequential pass over the
// visible rows (the draw's parse, the link layout). It exists because those passes
// used to advance with their own `p = pt_line_end_cap(p) + 1`, which was *the same
// walk* table_row_start performed -- true, stated in this file's comments, and
// false the moment a sort landed. Rather than leave the draw and the hit-test to
// agree by argument under a permutation, they now step through one procedure.
//
// `p` is ignored in the sorted case and `r` in the unsorted one, deliberately:
// each mode's answer is a function of the coordinate that mode actually has, and a
// caller that passes both cannot silently be right in one mode and wrong in the
// other.
//
// `line_end` is the third result and it is the one table_abs_rows rests on: false
// means the step landed on a SYNTHETIC cap break rather than on a real newline, so
// the row starting at `np` is the SAME logical line continued. pt_line_end_cap
// cannot say which of the two happened -- it returns min(length, p+cap) for both
// -- and a data row longer than RENDER_LINE_CAP is split across several visible
// rows for that reason. One byte read tells them apart exactly, the same
// disambiguation next_row_start_capped (doc.odin) and block_step_lines
// (block.odin) already make. Always true under a sort: every offset the
// permutation hands back comes out of `offs`, which holds real line starts only.
table_row_next :: proc(doc: ^Document, p, r: int) -> (np: int, ok: bool, line_end: bool) {
	if table_sorted(doc) {
		np, ok = table_row_start(doc, r)
		return np, ok, true
	}
	e := base.pt_line_end_cap(&doc.pt, p, RENDER_LINE_CAP)
	if e >= doc.pt.length {return 0, false, false}
	// A real newline is stepped PAST; a synthetic break is content, so the next row
	// starts ON it. This used to return e+1 either way, which dropped one byte per
	// 8 KiB of an over-long row out of the grid and put this step half a byte away
	// from next_row_start_capped -- the one doc_scroll writes doc.top with.
	if table_byte_at(doc, e) == '\n' {return e + 1, true, true}
	return e, true, false
}

// One byte, by absolute offset: an O(log n) tree lookup, not a scan. doc.odin's
// byte_at and block.odin's block_byte_at are the same three lines, both file-
// private; this is the third copy and they want one home in base.
@(private = "file")
table_byte_at :: proc(doc: ^Document, i: int) -> u8 {
	one: [1]u8
	base.pt_read(&doc.pt, i, one[:])
	return one[0]
}

// Absolute data-row index of each visible row -- the row's position in the FILE
// rather than in the viewport. THE producer for the grid's row numbering: §10's
// row-number gutter draws it and the zebra's parity rides on it, and neither
// derives it a second way.
//
// Entry r is TABLE_ABS_NONE when the file's numbering cannot answer for that row.
// doc_line_no_at refuses when the background index has not reached the offset,
// when an edit raced that initial scan and left the buffer diverged at or below
// it, when a huge paste left the nearest checkpoint further than CKPT_SCAN_CAP
// away, and after a faulted read of a mapped original; all of them arrive here as
// the same refusal. An ordinary edit is NOT one of them any more -- the
// checkpoints are repaired across it (Line_Index.ckpt_doc). A caller draws
// NOTHING for a refused row (development-loop.md §4, Shape A) -- not a zero, not
// a guess. The zebra is the single exception and only because a band carries no
// information; see table_draw.
//
// The header is line 0 and is not a data row, so data row 0 is line 1 and the
// answer is doc_line_no_at(<the first data row's byte>) - 1, WALKED forward one
// real newline at a time from there. It used to be a run -- `- 1 + r`, on the
// claim that "visible rows are consecutive lines by construction" -- and that
// claim was false: table_row_next steps with pt_line_end_cap, so a data row
// longer than RENDER_LINE_CAP (a description, JSON or log column: 8 KiB is not
// exotic) becomes several visible rows, and the run then numbered every row below
// it one too high per split, with exact = true. Shape A (development-loop.md §4)
// in the procedure whose second result exists to prevent it.
//
// So the line number advances only where table_row_next reports a real line end,
// and a CONTINUATION row lands as TABLE_ABS_NONE. Its head's number would be true
// -- it is the same logical line -- but the gutter would then print the same
// number on two adjacent rows, and a reader counting rows down the screen cannot
// tell that from two data rows sharing an index. One number per data row, on the
// row where that data row starts, nothing on its tail. Visible row 0 is itself a
// continuation whenever doc.top sits mid-line, which is exactly where scrolling
// through an over-long row leaves it (next_row_start_capped, doc.odin), so it is
// tested the same way rather than assumed to be a line start.
//
// ONE doc_line_no_at CALL for the whole screen, and that is a MEASURED cost
// decision, not a style one. It is bounded but not cheap: it counts newlines
// forward from the checkpoint at or below the offset, up to LINE_CKPT_STRIDE
// (64 KiB) of it. Measured on a 1.16 MB fixture whose first visible row sat
// 65,482 bytes past its checkpoint -- the worst case at that stride -- one call
// costs 153.3 us in a debug build, so a per-row producer spends 6.1 ms of a
// full 40-row screen's repaint on it. Every one of those calls would scan the
// SAME bytes, because `at` is table_data_start for all of them.
//
// The walk that replaced the run does NOT undo that. It is `rows` bounded steps
// -- the same pt_line_end_cap the draw's own pass already makes for every row it
// draws -- and still exactly one line-number lookup, so what the walk added is
// the cheap term and what the batching removed is the expensive one. tg_abs_cost
// measures both halves.
//
// One call per frame rather than a memo, deliberately. A cache would have to key
// on every input doc_line_no_at reads -- the offset, edit_floor, ckpt_doc, the
// CONTENTS of the ckpts array (every edit rewrites them now), ckpt_n, done,
// pt.fault, idx.fault, and the identity of the array doc_index_start swaps
// out from under it -- and a key that misses one of those is a stale row number
// presented to the reader as fact. That is the failure this whole two-result
// contract exists to prevent.
//
// NOT bounded above, deliberately, exactly as table_row_at_y is not: the caller
// owns its row budget (table_visible_rows) and a second opinion here about how
// many rows exist would be a second producer. The walk does stop at the last row
// -- entries past the end of the file stay TABLE_ABS_NONE now, where the run used
// to carry confident numbers off the end of the buffer -- but that is a side
// effect of stepping, not a row count, and a caller must still read only the
// entries it has rows for.
TABLE_ABS_NONE :: -1

table_abs_rows :: proc(doc: ^Document, rows: int, allocator := context.temp_allocator) -> []int {
	out := make([]int, max(0, rows), allocator)
	for i in 0 ..< len(out) {out[i] = TABLE_ABS_NONE}
	if doc == nil || len(out) == 0 {return out}
	s, sok := table_data_start(doc)
	if !sok {return out}
	// UNDER A SORT THE WALK BELOW IS WRONG, and it is wrong in the one way this
	// procedure exists to prevent. Counting newlines forward rests on visible rows
	// being successive lines; a permutation breaks that, so the gutter would count
	// 1, 2, 3 down a screen showing lines 4,113, 12 and 900 -- a confident number
	// naming the wrong line, which is what TABLE_ABS_NONE is for.
	//
	// The sort already knows the answer exactly, and for nothing: perm[pos] IS the
	// file-order data-row index of the row at sorted position pos. No line counting,
	// no checkpoint, no refusal -- and no doc_line_no_at call at all, so the sorted
	// path is cheaper than the unsorted one rather than costing the 153 us/row this
	// procedure's batching exists to avoid.
	if table_sorted(doc) {
		pos, pok := table_sort_pos(doc, s)
		if !pok {return out}
		for i in 0 ..< len(out) {
			if p, ok := table_sort_perm_row(doc, pos + i); ok {out[i] = p}
		}
		return out
	}
	ln, exact := doc_line_no_at(doc, s)
	// ln == 0 would mean the first data row IS line 0, which table_data_start
	// exists to make impossible; refuse rather than hand back -1 and have it read
	// as the refusal sentinel by accident.
	if !exact || ln < 1 {return out}
	// `head` is "this visible row begins a logical line", which is the whole of
	// what makes an entry a number rather than a refusal. It starts as a real test
	// of the byte before s rather than as `true`: doc.top lands mid-line whenever
	// the view has scrolled into a row longer than RENDER_LINE_CAP.
	line := ln
	head := s == 0 || table_byte_at(doc, s - 1) == '\n'
	p := s
	for i in 0 ..< len(out) {
		if head {out[i] = line - 1}
		np, more, line_end := table_row_next(doc, p, i + 1)
		if !more {break} // ran out of document: the rest stay refused
		p, head = np, line_end
		if line_end {line += 1}
	}
	return out
}

// Which zebra band visible row `r` belongs to: 1 = banded, 0 = on the page.
//
// ONE producer, because two passes now ask. The zebra pass paints the band and
// the gutter pass paints a COVER STRIP over the first 56px of the same row (the
// cells scroll under the sticky gutter and there is no scissor rect here), so
// the strip has to come back the same colour as what it covers. Two copies of
// `absn[r] % 2 if ... else r % 2` would be two chances for the gutter to end up
// a shade off the row it sits in, on alternating rows, which reads as a
// rendering fault rather than as a colour bug.
//
// The FALLBACK to `r % 2` on a refused row is the one place this draw is allowed
// to guess: a band carries no information, so a wrong band is a cosmetic hiccup,
// where a wrong row NUMBER is a lie about which line the reader is looking at.
// The gutter draws no number on the same refusal this papers over.
table_row_band :: #force_inline proc(absn: []int, r: int) -> int {
	return absn[r] % 2 if absn[r] != TABLE_ABS_NONE else r % 2
}

// --- §10's view-only sort: ONE producer for the row order -----------------
//
// "Header is a real header: ... click to sort with an accent arrow. Sorting is
// view-only and never rewrites the file."
//
// A PERMUTATION OVER ROW OFFSETS. The bytes never move, no line is rewritten, the
// document is not marked modified, and cell editing keeps working through it --
// Wyatt's decision, taken before this was planned. What the sort produces is a new
// answer to "which line is visible row r", and table_row_start is the single place
// that answers it, so the sort lands there and nowhere else.
//
// THE RISK IS DATA LOSS, NOT LAYOUT. table_cell_at maps a pixel through
// table_row_start to a field's byte range and table_edit_commit splices that range.
// A permutation that the hit-test honoured and the draw did not (or the reverse)
// would put the user's typed value on a line they never clicked, silently, with the
// right value in the wrong row -- which is worse than a crash because nothing says
// so. table_edit_line_intact is the backstop for the case where a reorder happens
// UNDER an open edit; the structure here is what stops the ordinary case needing
// one.
//
// THREE ARRAYS, and each answers a direction the grid actually asks for:
//
//   offs[j]   file order, ascending: the byte offset of data row j's line. The
//             search space for "which row is this offset", which is how doc.top --
//             a byte offset the wheel, the page keys, the scrollbar, Ctrl+Home and
//             a find jump all write in FILE terms -- is turned into a position in
//             the sorted order.
//   perm[pos] sorted position -> file-order row index. The draw and the hit-test
//             read this: offs[perm[pos]] is visible row pos's line.
//   rank[j]   file-order row index -> sorted position. perm's inverse, needed
//             because the offset->position direction has no other route.
//
// perm and rank are i32 because TABLE_SORT_MAX bounds the row count well below
// 2^31 (#assert-ed below), and at the ceiling the difference is 8 MB of resident
// memory rather than 16. offs stays `int`: a byte offset in a multi-GB file does
// not fit in 32 bits and the whole point of the ceiling is that the FILE may be
// huge even when the row count is not.
//
// DOC.TOP STAYS A REAL BYTE OFFSET at all times, and that is deliberate rather than
// incidental. It is what lets the edit anchor (table_edit_line), leaving the view,
// a session write and a find jump keep working with no knowledge that a sort
// exists: every one of them sees a genuine line start, because every value the
// sorted scroll writes into doc.top comes out of offs. The three procedures that
// MOVE doc.top by rows -- doc_scroll, doc_max_top, doc_scroll_to_fraction, which
// doc_scroll_rows' comment already names as the three that must hold the same
// number -- delegate to the four helpers at the bottom of this block, and the
// scrollbar's thumb reads the fourth.
//
// LIFETIME, which is the part that can lose data if it is wrong. Every offset in
// `offs` describes bytes that an edit can move. Two hooks outside this file keep
// that honest, and they are placed where every path has to pass rather than on the
// paths themselves:
//
//   pt_edit_replace  -> table_sort_shift. The one procedure every buffer write
//                       goes through (it already hosts ckpt_repair and
//                       bookmarks_shift_replace for exactly this reason). An edit
//                       that adds or removes a newline changes the ROW SET, which
//                       a shift cannot express, so that case drops the sort
//                       outright -- fail-closed, and unreachable from table view
//                       anyway since a cell edit cannot contain a newline.
//   doc_index_start,
//   apply_snapshot   -> table_sort_clear. Both replace the buffer wholesale (a
//                       reload, an encoding or line-ending change, fault recovery,
//                       undo/redo), after which no offset here describes anything.
//
// NOT a generation counter. HANDOFF §6aw rejected one for the edit anchor because
// it depends on the author of the sort remembering to bump it; the same argument
// applies to the sort's own validity, and the answer is the same -- hook the one
// procedure nothing can avoid.
TABLE_SORT_NONE :: -1

// The most data rows this will sort. Past it the click is REFUSED and the summary
// row says so (table_summary_text).
//
// Refusing is the point, and the alternative it rules out is the one this codebase
// keeps producing: sorting whatever happens to be sampled or visible and presenting
// it as "sorted" is development-loop.md §4's Shape A -- a bounded scan reporting a
// confident wrong answer -- and there are seven instances of that shape on record.
// A partial sort is worse than no sort here because the reader cannot see that it
// is partial: the rows are in order, so it looks right.
//
// The right long-term answer is a background sort index, which is queued rather
// than built (the batch-18 plan's "out of scope").
//
// THE NUMBER IS SET FROM A MEASUREMENT, not from a round figure. The build is a
// single synchronous pass on the main thread, so the ceiling is a freeze budget:
// at 1,000,000 rows it measured **2,046 ms at -o:speed** (3,075 ms debug), and a
// two-second stall on a header click is not a slow feature, it is a hung window.
// Product principle 1 is "speed everywhere -- clicking, tabs, find, open:
// instant", and nothing about a click on a column header exempts it. 100,000 rows
// is the most that can be sorted without breaking the promise the product is sold
// on: still the slowest thing in the app by a wide margin, but recoverable rather
// than alarming. This was 1,000,000 for exactly as long as it took to measure it.
//
// THIS PARAGRAPH USED TO END "the cost is near-linear in rows, so 100,000 lands
// near 205 ms". That 205 was never measured -- it was the 2,046 ms release figure
// above divided by ten. Batch 19 measured the same quantity DIRECTLY at 100,000
// rows (tablesorttest's C6): 370-395 ms debug over seven runs, ~258 ms release
// converted at the x0.665 ratio the two figures above establish (~246-263 ms across
// the spread). So the single-key sort at the ceiling costs about a quarter more than
// this comment claimed. Trust the 258: it is a direct measurement of this build,
// where the 205 was an extrapolation across a factor of ten from a different
// fixture. The ceiling does not move on it -- 258 ms is the same side of
// "recoverable rather than alarming" as 205 was -- and neither does the argument.
// What moved is the evidence. TABLE_SORT_KEYS_MAX's last paragraph below calls this
// the comment-outran-the-evidence shape, and this is what it looks like.
//
// AT THE KEY CAP the same 100,000 rows cost more again -- TABLE_SORT_KEYS_MAX's
// comment carries the numbers, what took the cap from three to two, and what the
// measurement does and does not settle. The ceiling is unchanged by it: the bound
// is a row count for the reason the paragraph below gives, and the key count
// multiplies the constant rather than the shape.
//
// It is a row count, not a file size: the bound that matters is the memory the
// permutation costs and the time the single pass takes, neither of which cares
// how wide the rows are.
//
// Raising it is a decision about how long a freeze is acceptable, so raise it
// only with a fresh measurement -- and prefer building the background index,
// which removes the trade rather than repricing it.
TABLE_SORT_MAX :: 100_000
#assert(TABLE_SORT_MAX < int(max(i32)))

// The most keys a sort can carry. Batch 19's "first column selected wins":
// PRECEDENCE IS ARRAY ORDER, and array order is append order, so first-wins is a
// property of the data structure and not a rule anything has to enforce -- there is
// no separate priority field to keep in step with it.
//
// TWO, AND IT WAS THREE UNTIL IT WAS MEASURED. The original cap was a spec-given
// three: Excel's classic sort dialog offers three, and the summary row
// (table_summary_parts) has to stay a sentence a reader takes in rather than a list
// they scan. Neither of those is a timing argument, and the timing is now measured:
//
//   100,000 rows, same file, same run (tablesorttest's C6), DEBUG build:
//   1 key 382-395 ms; 3 keys 690-702 ms, about 1.8x. Three recorded runs gave
//   1.78-1.80x and an independent run during review gave 1.86x. Read it as "about
//   1.8": four runs on one machine cannot carry a range to two decimal places, and
//   the reason this says so is that the same comment first claimed "five runs" with
//   three written down -- which is the shape this file has now corrected three times
//   in one batch.
//
// Debug because build.bat release is -subsystem:windows and a headless mode cannot
// print from it at all. CONVERTED, NOT MEASURED, with the ratio TABLE_SORT_MAX's own
// comment establishes (3,075 ms debug to 2,046 ms release at 1,000,000 rows, x0.665):
// three keys land near 460 ms of release-build freeze against roughly 258 ms for one
// key on the same fixture. A measured ratio on one machine and a converted absolute
// -- do not quote the 460 as though it were a release measurement.
//
// Wyatt's decision, 2026-07-31: two. And the honest shape of that decision, because
// the number does not make it obvious --
//
//   THE COST IS A CONSTANT FACTOR, NOT A NEW SHAPE. The line is read once and every
//   key is cut from that one read, so k multiplies the field extraction and the
//   comparator's depth, not the number of passes: 3x the keys buys 1.8x the time.
//   That also makes the cap a WEAK LEVER, and the cap it landed on was measured too
//   -- at two keys C6 reads 550-564 ms debug against 370-377 ms for one key over
//   four runs, 1.47-1.52x, so about 370 ms of release freeze converted against about
//   250 ms. Two keys is most of the way to three. Dropping the cap did not buy a
//   fast sort; it declined to pay for a key nobody asked for. "Sort by department,
//   then by name" is the query people actually have.
//
// What the measurement does NOT settle is whether even ~370 ms is an acceptable
// freeze. Product principle 1 is "speed everywhere -- clicking, tabs, find, open:
// instant". If that answer is ever no, THIS constant is the variable (spec §4) --
// TABLE_SORT_MAX does not rise and a longer freeze is not accepted -- and past that,
// the real answer is the background sort index TABLE_SORT_MAX's comment names, which
// removes the trade rather than repricing it.
//
// CHANGING IT -- in either direction -- takes two things, not one: a fresh
// measurement at the new count, AND a decision about how the summary row reads with
// that many keys in it. Whoever changes it should record both. A cap moved on only
// one of them is exactly the comment-outran-the-evidence shape this one used to be.
TABLE_SORT_KEYS_MAX :: 2

// One column's part of the sort. TABLE_SORT_NONE is what an unset key's `col` is --
// Odin zero-inits `col` to 0, a valid column index, so a slot that has never been
// written must be told to say TABLE_SORT_NONE rather than be trusted to.
Sort_Key :: struct {
	col:     int,
	desc:    bool,
	// Decided over every row the sort orders, same argument as table_sort_build's
	// numeric detection below -- now per key because one key can be numeric while
	// another in the same sort is text.
	numeric: bool,
}

Table_Sort :: struct {
	// keys[0] is the primary; every key after it is a tie-breaker, in the order it
	// was added. nkeys is the count that's live -- entries at or past it are
	// leftover from a previous sort and must not be read (table_sort_key stops at
	// nkeys for exactly this reason).
	keys:    [TABLE_SORT_KEYS_MAX]Sort_Key,
	nkeys:   int, // 0 == unsorted
	offs:    [dynamic]int,
	perm:    [dynamic]i32,
	rank:    [dynamic]i32,
	// A click that was refused because the file has more than TABLE_SORT_MAX data
	// rows. Kept so the summary row can SAY so rather than leaving the click
	// looking broken -- a header that does nothing when pressed is exactly the
	// "palette dispatch that silently does nothing" shape this batch already fixed
	// once. Cleared by the next click and by table_sort_clear.
	refused: bool,
}

// Is `col` part of the live sort, and at what precedence? Linear over at most
// TABLE_SORT_KEYS_MAX -- a binary search over that many entries would be slower AND
// would imply the array is ordered by column, which it is not: it is ordered by
// PRECEDENCE, which is the whole point (see TABLE_SORT_KEYS_MAX above).
table_sort_key :: proc(doc: ^Document, col: int) -> (k: int, ok: bool) {
	if doc == nil {return 0, false}
	s := &doc.table_sort
	for i in 0 ..< s.nkeys {
		if s.keys[i].col == col {return i, true}
	}
	return 0, false
}

// Is a sort live on this document? The predicate every consumer branches on.
//
// `doc.table` is part of it deliberately. doc_scroll and doc_max_top ask this on
// EVERY document, including ones that have never been a table, and a permutation
// left behind by a view that has since been switched off must not steer the text
// view's scroll. It used to be called a belt on the grounds that table_sort_clear
// runs whenever the view is left -- which was not true of .Toggle_Table's own
// off-branch, the primary way to leave, so for a Ctrl+T'd document this term was
// the only thing holding. All three leave paths clear now (leave_table_view,
// .Toggle_Table, doc_view_apply) and it is a belt again, but it stays: the cost is
// one field compare and what it guards is the text view's scroll model.
//
// `s.nkeys > 0` is REDUNDANT against `len(s.perm) > 0` in the code as it stands
// today -- the two are in exact lockstep, because there are only two places `nkeys`
// is ever written. table_sort_clear sets it to 0 in the same breath it clears
// `perm`. table_sort_build sets it to the key count it just built -- 1 to
// TABLE_SORT_KEYS_MAX -- exactly once, at its last line, only after
// `perm` has already been resized to a non-empty length on the success path above
// it (every earlier return leaves `nkeys` untouched at whatever table_sort_clear
// left it). Nothing else assigns `nkeys`, so there is no state the current code can
// construct where the two disagree. The term is kept anyway, not because it guards
// a reachable state that `len(perm) > 0` misses, but because it names the actual
// invariant this predicate is about -- "is a sort live" -- rather than a proxy for
// it; `len(perm)` is a size that happens to correlate with liveness today, and
// reading through it would be one more thing a future change to `perm`'s lifecycle
// could quietly break without anything here saying so. Same spirit as the
// `doc.table` belt above: cheap, and it names its own reason rather than someone
// else's.
table_sorted :: #force_inline proc(doc: ^Document) -> bool {
	return doc != nil && doc.table && doc.table_sort.nkeys > 0 && len(doc.table_sort.perm) > 0
}

// Data rows the live sort covers.
table_sort_rows :: #force_inline proc(doc: ^Document) -> int {
	return len(doc.table_sort.perm) if table_sorted(doc) else 0
}

// The FILE-ORDER data-row index at sorted position `pos` -- what the row-number
// gutter and the zebra's parity ride on (table_abs_rows). It is the permutation's
// own entry, so under a sort the absolute row index costs nothing at all and needs
// neither Line_Index nor a refusal path.
table_sort_perm_row :: proc(doc: ^Document, pos: int) -> (j: int, ok: bool) {
	s := &doc.table_sort
	if pos < 0 || pos >= len(s.perm) {return 0, false}
	return int(s.perm[pos]), true
}

// The line offset at sorted position `pos`. The lookup the draw and the hit-test
// both resolve through table_row_start to reach.
table_sort_row_at :: proc(doc: ^Document, pos: int) -> (off: int, ok: bool) {
	s := &doc.table_sort
	if pos < 0 || pos >= len(s.perm) {return 0, false}
	j := int(s.perm[pos])
	if j < 0 || j >= len(s.offs) {return 0, false}
	return s.offs[j], true
}

// The sorted position of the row whose line starts at `off` -- the direction the
// scroll model needs, since doc.top is written in file terms by six different
// routes and read here in sorted terms.
//
// Lower bound over `offs`, the same shape doc.odin's ckpt_at_or_below uses rather
// than a second idiom for the same job. An offset BETWEEN two row starts resolves
// to the row containing it, which is the forgiving answer and the right one: a
// find jump lands on a match's line start, but a session restore or a clamp can
// leave doc.top mid-line, and refusing there would blank the whole grid.
table_sort_pos :: proc(doc: ^Document, off: int) -> (pos: int, ok: bool) {
	s := &doc.table_sort
	if len(s.offs) == 0 || len(s.rank) != len(s.offs) {return 0, false}
	lo, hi := 0, len(s.offs)
	for lo < hi {
		mid := (lo + hi) / 2
		if s.offs[mid] <= off {lo = mid + 1} else {hi = mid}
	}
	j := lo - 1
	if j < 0 {return 0, false}
	return int(s.rank[j]), true
}

// Drop the sort. Idempotent, and safe on a zero-value Table_Sort (Odin's dynamic
// arrays delete cleanly when nil), which matters because doc_index_start calls it
// on documents that have never been a table.
table_sort_clear :: proc(doc: ^Document) {
	if doc == nil {return}
	s := &doc.table_sort
	s.nkeys, s.refused = 0, false
	// A zeroed Sort_Key.col is 0, a valid column -- Odin's zero-is-init gives an
	// UNSET key the same shape as "sorted by column 0". nkeys already stops every
	// reader at the live prefix (table_sort_key, the build below), so this can't be
	// read as live, but leaving `col` at 0 would still be a slot lying about what it
	// is the moment anyone reads the array directly instead of through nkeys.
	for &k in s.keys {k.col = TABLE_SORT_NONE}
	clear(&s.offs)
	clear(&s.perm)
	clear(&s.rank)
}

// ...and give the backing store back. doc_close only.
table_sort_free :: proc(doc: ^Document) {
	delete(doc.table_sort.offs)
	delete(doc.table_sort.perm)
	delete(doc.table_sort.rank)
}

// One row's value for ONE key, during the build only.
//
// `ks`/`kl` index the key arena rather than `key` being filled as the arena grows:
// a [dynamic]u8 REALLOCATES, and a string captured before a growth points into
// freed memory. Every key is spanned first and materialised in one pass once the
// arena has stopped moving. That bug is silent -- the comparator reads plausible
// garbage and produces a plausible ORDER -- and with TABLE_SORT_KEYS_MAX keys per
// row there are that many times as many chances to make it, so the shape is worth
// stating. It is also the one risk in this procedure that no small fixture can see
// from the outside: the arena is created with 64 KB of capacity and a five-row table
// never makes it move, so the sabotage that pins this rule has to run against the
// 100,000-row one (tablesorttest's C6).
@(private = "file")
Sort_Field :: struct {
	key:    string,
	num:    f64,
	ks, kl: i32,
	// Empty cells sort LAST in both directions, which is why this is a field rather
	// than falling out of an empty key or a zero value.
	//
	// "No value" is not the smallest value. In a text column an empty key would sort
	// before every letter ascending and after every letter descending, so the blanks
	// would move from one end to the other with the arrow; in a numeric column an
	// unparsed empty would read as 0.0 and land in the middle of the real data, which
	// is worse -- a blank presented as a zero is a wrong number, not a missing one.
	// Last in both directions is the one rule under which a blank never claims a value
	// it does not have.
	empty:  bool,
}

// One row's sort keys, during the build only. `f[i]` belongs to key i, so the
// comparator's precedence walk is an index walk and there is no second ordering to
// keep in step with the key vector's.
@(private = "file")
Sort_Item :: struct {
	f:   [TABLE_SORT_KEYS_MAX]Sort_Field,
	row: i32,
}

// The key metadata the comparator needs, passed through slice.sort_by_with_data's
// user_data rather than sitting at file scope. A global read by a comparator is
// invisible state that outlives the call that set it, and this file already carries
// one hard-won lesson (Sort_Field's arena, just above) about state that is valid
// only inside one procedure.
@(private = "file")
Sort_Ctx :: struct {
	keys:  [TABLE_SORT_KEYS_MAX]Sort_Key,
	nkeys: int,
}

// Keys in PRECEDENCE order; the first that separates two rows decides.
//
// EMPTY LAST IS PER KEY AND IGNORES DIRECTION, at every key, for the reason
// Sort_Field.empty gives. Two rows both blank on a key are not ordered by it at all
// -- they fall through to the next key rather than returning, because "both have no
// value here" says nothing about which comes first, and stopping there would leave
// the remaining keys unread for exactly the rows a tie-breaker exists to separate.
//
// The final tie-break is the row's FILE position, ascending, in every direction, so
// the order is total and does not depend on slice.sort_by_with_data's stability --
// which this file cannot see.
@(private = "file")
sort_less_keys :: proc(a, b: Sort_Item, user_data: rawptr) -> bool {
	ctx := (^Sort_Ctx)(user_data)
	for i in 0 ..< ctx.nkeys {
		k := ctx.keys[i]
		af, bf := a.f[i], b.f[i]
		if af.empty != bf.empty {return bf.empty}
		if af.empty {continue} // both empty on this key: fall through to the next
		if k.numeric {
			if af.num != bf.num {return af.num > bf.num if k.desc else af.num < bf.num}
		} else {
			if af.key != bf.key {return af.key > bf.key if k.desc else af.key < bf.key}
		}
	}
	return a.row < b.row
}

// Parse a cell that table_is_number has already accepted. Group separators are
// stripped first because strconv does not know about them and table_is_number
// does -- the two have to agree about what a number is, and this is the seam
// between them.
@(private = "file")
sort_number :: proc(s: string, scratch: ^[64]u8) -> f64 {
	n := 0
	for i in 0 ..< len(s) {
		if s[i] == ',' {continue}
		if n >= len(scratch) {break}
		scratch[n] = s[i]
		n += 1
	}
	v, _ := strconv.parse_f64(string(scratch[:n]))
	return v
}

// Build the permutation for `keys` -- 1..TABLE_SORT_KEYS_MAX columns in PRECEDENCE
// order, keys[0] first. Returns false and leaves the document unsorted when it
// refuses; `refused` distinguishes "too large" from "there is nothing to sort".
//
// Each key's `numeric` is IGNORED on the way in and SETTLED here, over the rows this
// sort orders. A caller cannot know a column's type -- the only place that evidence
// exists is the pass below -- so accepting the caller's guess would be an input this
// procedure has to distrust anyway. The settled vector is what lands in s.keys.
//
// ONE BOUNDED PASS over the data rows, on the main thread, because a sort the user
// asked for by clicking has to be there when they look up. Still one pass at the key
// cap: the line is read once and every key's field is cut from that one read, so
// the row count -- not the key count -- is what the ceiling has to bound. The bound
// is TABLE_SORT_MAX rows, checked as the rows are counted rather than afterwards, so
// a 12M-row file pays for 100,000 rows of scanning and then stops -- not for twelve
// million followed by a refusal.
//
// EACH COLUMN'S TYPE IS DECIDED HERE, over the rows being sorted, and NOT read from
// doc.table_align. That is the difference between a bounded scan that knows its own
// bound and one that does not. table_compute_widths decides alignment from the
// first TABLE_SAMPLE (500) rows, which is the right scope for a cosmetic
// right-align: being wrong costs a column drawn against the wrong edge. Sorting a
// column numerically because its first 500 cells were numbers, when row 900 holds
// "N/A", would put that row wherever 0.0 happens to fall and present it as sorted.
// The evidence for a NUMERIC sort has to cover every row the sort orders, so it is
// gathered from every row the sort orders -- and per key, because one key can be
// numeric while another in the same sort is text.
//
// Dates deliberately sort as BYTES, not as a third key type. An ISO date sorts
// correctly as text, which is most of what §10's date detection matches; the
// d/m/Y masks do not sort correctly under any byte order, and parsing them would
// need a calendar this file explicitly refuses to grow (see table_is_date). Text
// is the honest answer for a shape whose ordering is not knowable from the shape.
table_sort_build :: proc(doc: ^Document, keys: []Sort_Key) -> bool {
	if doc == nil {return false}
	// The caller's vector is copied out BEFORE table_sort_clear runs, and the order
	// is load-bearing: `keys` is allowed to alias s.keys -- a caller cycling the live
	// sort holds the current vector and hands back a modified one -- and the clear
	// rewrites every `col` in that array to TABLE_SORT_NONE. Reading `keys` afterwards
	// would read the reset, not the request.
	//
	// Trailing slots get TABLE_SORT_NONE rather than Odin's zero: 0 is a valid column
	// index, and kv is written into s.keys wholesale on success, so a zeroed tail
	// would undo exactly the reset table_sort_clear performs (see its comment).
	kv: [TABLE_SORT_KEYS_MAX]Sort_Key
	for &k in kv {k.col = TABLE_SORT_NONE}
	nk := len(keys)
	usable := nk > 0 && nk <= TABLE_SORT_KEYS_MAX
	if usable {
		for i in 0 ..< nk {
			// `numeric` is dropped on the floor here, not copied: it is settled below.
			if keys[i].col < 0 {usable = false;break}
			kv[i] = {keys[i].col, keys[i].desc, false}
		}
	}
	s := &doc.table_sort
	// Cleared before the first refusal rather than after the last, so that every
	// `return false` below -- including the two the caller can provoke with a bad
	// vector -- leaves the document genuinely unsorted rather than half-sorted.
	table_sort_clear(doc)
	if !usable {return false}
	first, fok := table_first_data_row(doc)
	if !fok {return false}
	// Refuse before scanning when the row count is already SETTLED and over the
	// ceiling. Without this every click on a 12M-row file pays for a full
	// TABLE_SORT_MAX-row pass -- 285 ms in a debug build, which tg_sort's C4 prints
	// -- to arrive at the same refusal, so the header would cost a visible hitch on
	// every press and never do anything. Only on an EXACT count: a partial one is
	// smaller than the truth
	// by construction, so refusing off it would refuse files that fit.
	if n, exact := table_row_count(doc); exact && n > TABLE_SORT_MAX {
		s.refused = true
		return false
	}
	delim := doc.table_delim if doc.table_delim != 0 else ','

	// The key bytes, and one item per row. Heap, with explicit frees, rather than
	// the frame's temp allocator: at the ceiling this is tens of megabytes and the
	// temp arena would keep the high-water mark for the process's life, while a
	// sort's scratch is wanted for exactly the length of this procedure.
	arena := make([dynamic]u8, 0, 64 * 1024)
	defer delete(arena)
	items := make([dynamic]Sort_Item, 0, 1024)
	defer delete(items)

	// Two line-sized buffers rather than one, and the second is not a convenience:
	// the key has to be extracted somewhere, and every alternative was worse. A
	// SMALLER key buffer would truncate a long field and hand back a confident wrong
	// ORDER -- development-loop.md §4 Shape A with the key rather than the scan
	// truncated -- and a field cannot exceed the line, which RENDER_LINE_CAP already
	// bounds. 16 KB on the stack of a procedure the input phase calls once per click.
	//
	// ONE key buffer, reused by every key, NOT one per key. A
	// [TABLE_SORT_KEYS_MAX][RENDER_LINE_CAP]u8 is 16 KB of its own at today's cap of 2,
	// and it would REPLACE the 8 KB `key` below rather than sit beside it, so the extra
	// cost is 8 KB and it grows by another RENDER_LINE_CAP (8 KB) per key the cap ever
	// gains. This line used to say "24 KB more", which was the whole array at a cap of
	// three rather than the difference it costs. On a stack frame
	// that test_mode_dispatch already enters deep, and `blocktest` has hit a real
	// STATUS_STACK_OVERFLOW twice in this tree from exactly that kind of growth. Reuse
	// is safe because each field is appended to the arena immediately, before the next
	// extraction overwrites the buffer.
	buf: [RENDER_LINE_CAP]u8
	key: [RENDER_LINE_CAP]u8
	p := first
	// Per key, because the numeric decision is per key. num_all[i] starts true and
	// only ever falls: one non-numeric cell anywhere in the sorted rows settles that
	// key as text.
	num_all: [TABLE_SORT_KEYS_MAX]bool
	nonempty: [TABLE_SORT_KEYS_MAX]int
	for i in 0 ..< nk {num_all[i] = true}
	for {
		// The file's TERMINATOR is not a row. A file ending in '\n' leaves a
		// zero-length line after the last real one, and the unsorted walk shows it as
		// a blank row at the bottom (a pre-existing artefact, tracked separately).
		// Sorting it in would move that blank into the middle of the data, where it
		// reads as a hole in the file rather than as the end of it -- so the sorted
		// row set is the file's data rows and nothing else. This is the one place the
		// sorted and unsorted row sets differ, it differs by that one phantom row at
		// the very bottom, and it goes away when the sort is cleared.
		if p >= doc.pt.length {break}
		if len(items) >= TABLE_SORT_MAX {
			table_sort_clear(doc)
			s.refused = true
			return false
		}
		end := base.pt_line_end_cap(&doc.pt, p, RENDER_LINE_CAP)
		n := base.pt_read(&doc.pt, p, buf[:min(end - p, len(buf))])
		if n > 0 && buf[n - 1] == '\r' {n -= 1}
		// ONE line read, k fields cut from it -- the reason the key count does not
		// multiply the pass. Each field is spanned into the arena and appended before
		// the next extraction, because `key` is the same buffer every time round.
		line := string(buf[:n])
		it := Sort_Item {
			row = i32(len(items)),
		}
		for i in 0 ..< nk {
			t := strings.trim_space(csv_field_into(line, delim, kv[i].col, key[:]))
			it.f[i] = {ks = i32(len(arena)), kl = i32(len(t)), empty = len(t) == 0}
			append(&arena, ..transmute([]u8)t)
			if !it.f[i].empty {
				nonempty[i] += 1
				if !table_is_number(t) {num_all[i] = false}
			}
		}
		append(&items, it)
		append(&s.offs, p)
		if end >= doc.pt.length {break}
		p = end + 1
	}
	// A short read through the SEH shim (a mapped original that changed underneath)
	// zero-fills what it could not read and says so on the piece tree, so the keys
	// above may describe bytes the file no longer has. Refusing is the same
	// fail-closed answer doc_line_no_at gives for the same event -- an order derived
	// from zeroes is not a partial answer, it is a wrong one.
	if base.pt_faulted(&doc.pt) || len(items) == 0 {
		table_sort_clear(doc)
		return false
	}
	// The arena has stopped growing: materialise every key now, never before.
	//
	// SABOTAGED AND WATCHED TO FAIL, because this rule's violation is invisible at any
	// fixture small enough to read: moving these two lines up into the row loop took
	// tablesorttest's 100,000-row case from a pinned order to an ACCESS VIOLATION
	// (0xC0000005) mid-sort, and every case before it still passed unchanged. By then
	// the arena has grown past its 64 KB capacity many times over, so most keys point
	// into blocks that have been freed. At that size the heap gives the read back a
	// fault; at a size where it does not, the same bug is a plausible wrong order that
	// nothing in the output would flag.
	for &it in items {
		for i in 0 ..< nk {it.f[i].key = string(arena[it.f[i].ks:it.f[i].ks + it.f[i].kl])}
	}
	// Each key's type settles against ITS OWN accumulators. A key that is numeric in
	// this sort tells the next key nothing, which is why these are not one flag.
	for i in 0 ..< nk {kv[i].numeric = nonempty[i] > 0 && num_all[i]}
	scratch: [64]u8
	for &it in items {
		for i in 0 ..< nk {
			if kv[i].numeric && !it.f[i].empty {it.f[i].num = sort_number(it.f[i].key, &scratch)}
		}
	}
	// One comparator for every direction and every key count: the four it replaced
	// were four copies of the same empty-last and file-order rules, and a fifth would
	// have been a fifth chance for them to drift apart.
	ctx := Sort_Ctx {
		keys  = kv,
		nkeys = nk,
	}
	slice.sort_by_with_data(items[:], sort_less_keys, &ctx)
	resize(&s.perm, len(items))
	resize(&s.rank, len(items))
	for it, pos in items {
		s.perm[pos] = it.row
		s.rank[it.row] = i32(pos)
	}
	// The SETTLED vector lands, and only now -- after the last refusal, in the same
	// place `s.keys[0]` used to be written -- so that `nkeys > 0` and a non-empty
	// `perm` become true together and table_sorted cannot see a half-built sort.
	s.keys = kv
	s.nkeys = nk
	return true
}

// Is there room for `col` in the live sort? Already-a-key columns are always
// "yes" -- changing a key's direction costs no slot, only appending a NEW one
// does -- so this is not simply `nkeys < TABLE_SORT_KEYS_MAX`. The one predicate
// table_sort_add, table_sort_toggle and the header menu's enabled state (Task 5)
// all branch on, so the cap has exactly one definition rather than three that
// could drift apart.
table_sort_can_add :: proc(doc: ^Document, col: int) -> bool {
	if doc == nil {return false}
	if _, ok := table_sort_key(doc, col); ok {return true}
	return doc.table_sort.nkeys < TABLE_SORT_KEYS_MAX
}

// Replace the live sort with exactly this one key, discarding whatever else was
// live. Where table_sort_add composes onto the existing vector, this is for a
// caller that means "this column and only this column" regardless of what came
// before -- table_sort_cycle below, and Task 5's header-menu "Sort Ascending" /
// "Sort Descending" rows, which name a single column and a single direction and
// have no reason to inherit a tie-breaker the menu never mentioned.
//
// THE OPEN CELL EDIT IS COMMITTED FIRST, and this is HANDOFF §6aw's "keystrokes are
// dropped on a reorder" turned from an inherited constraint into a decision.
// Committing here happens while the anchor is still intact -- nothing has moved
// yet, so table_edit_line_intact passes and the value lands on the row the user
// typed it into. The drop path in table_edit_commit survives as the fail-closed
// guard for a reorder this code did not initiate; it is no longer what happens when
// a user types into a cell and then clicks a header, which was the case that made
// the constraint worth deciding. table_sort_add, table_sort_drop and
// table_sort_toggle below commit the same way, for the same reason: a Ctrl+click
// that reorders while a cell edit is open would drop the keystrokes exactly as a
// plain click would. table_sort_cycle below reaches this commit by delegating to
// this procedure for its ascending/descending transitions; the commit call at the
// top of table_sort_cycle itself is only needed for the branch that does NOT
// delegate here (its own descending -> clear).
//
// The scroll goes to the TOP of the new order rather than trying to keep the row
// that was under the pointer. Following a row through a re-sort sounds friendlier
// and is not: the row the reader is looking for after sorting by Name is at the
// name they are looking for, which is at the top or found by scrolling, while
// "keep row 4,113 on screen" leaves them somewhere arbitrary in an order they have
// not seen yet. It also guarantees doc.top is an offset the permutation contains,
// which table_sort_pos then never has to be forgiving about. table_sort_add and
// table_sort_drop below apply the same rule to every reorder they make, including
// a drop that merely shortens the vector. An operation that CLEARS the sort
// entirely -- table_sort_cycle's descending -> clear branch, and table_sort_drop's
// last key -- does NOT touch doc.top: it is already a real byte offset in the
// file's own order (the block comment opening this section), and once no
// permutation exists there is nothing left for the scroll to be forgiving about.
table_sort_set :: proc(doc: ^Document, col: int, desc: bool) {
	if doc == nil || col < 0 {return}
	if doc.table_editing {table_edit_commit(doc)}
	kv := [1]Sort_Key{{col = col, desc = desc}}
	if !table_sort_build(doc, kv[:]) {return}
	if off, ok := table_sort_row_at(doc, 0); ok {doc.top = off}
}

// A click on the sorted column's header. §10's cycle: ascending, then descending,
// then back to the file's own order -- so the gesture that turned the sort on is
// the gesture that turns it off, and there is no second control to find. Always a
// SINGLE key, replacing whatever was live -- table_sort_toggle below is the
// gesture that composes a tie-breaker onto an existing sort instead of replacing
// it.
//
// The ascending and descending transitions delegate to table_sort_set above,
// whose own comment carries the argument for why the open cell edit is committed
// first and why the scroll lands on the top of the new order rather than
// following a row. The commit call directly below runs unconditionally -- ahead
// of the branch below it -- because it is the only commit on the path that clears
// the sort instead of delegating to table_sort_set; on the other path it is a
// harmless repeat of the commit table_sort_set performs itself.
table_sort_cycle :: proc(doc: ^Document, col: int) {
	if doc == nil || col < 0 {return}
	if doc.table_editing {table_edit_commit(doc)}
	// table_sort_key already stops at nkeys, so a zero-value Document (keys[0].col
	// == 0, Odin's zero-is-initialization, which CLAUDE.md says not to fight)
	// cannot read as "column 0 already sorted" the way a raw `s.keys[0].col == col`
	// compare could. table_sorted is still composed in rather than dropped: its
	// other two terms, doc.table and len(perm) > 0, are not things table_sort_key
	// checks, and this is the gesture that has to tell "sorted, click again" from
	// "not sorted, first click" apart correctly for every one of them.
	//
	// Reads `s.keys[k].desc`, not `s.keys[0]`. A plain click can now land on a
	// column that is a Ctrl+click tie-breaker rather than the primary -- Task 3 is
	// what made a multi-key sort reachable at all -- and keys[0] would then read a
	// DIFFERENT column's direction to decide this one's next state.
	s := &doc.table_sort
	k, is_key := table_sort_key(doc, col)
	live := table_sorted(doc) && is_key
	if live && s.keys[k].desc {
		table_sort_clear(doc) // descending -> the file's own order
		return
	}
	table_sort_set(doc, col, live) // ascending -> descending; anything else -> ascending
}

// Append `col` to the live sort, or -- if it is already a key -- change ITS
// direction and leave every key's precedence exactly where it was.
//
// REMOVE-AND-RE-APPEND WAS THE TRAP this task's brief carried in from Task 2's
// review: precedence is array order, first-wins by construction
// (TABLE_SORT_KEYS_MAX's comment), so popping an existing key out and pushing it
// back on at the end would silently demote a primary key to a tie-breaker on
// every direction flip, with nothing on screen saying it happened. Composing the
// next vector with the key rewritten AT ITS OWN INDEX is what keeps precedence
// where the user put it.
//
// THE CAP IS CHECKED HERE, before table_sort_build ever sees the vector -- not
// delegated to it. table_sort_build clears the live sort before it validates
// (documented on table_sort_build's own comment, and pinned there by Task 2's
// tests), so handing it an oversized vector to learn that it refuses would erase
// every key already live just to answer a question this procedure can answer for
// free by comparing `col`'s membership and `nkeys` first.
table_sort_add :: proc(doc: ^Document, col: int, desc: bool) {
	if doc == nil || col < 0 {return}
	if doc.table_editing {table_edit_commit(doc)}
	s := &doc.table_sort
	kv: [TABLE_SORT_KEYS_MAX]Sort_Key
	nk := s.nkeys
	for i in 0 ..< nk {kv[i] = s.keys[i]}
	if k, ok := table_sort_key(doc, col); ok {
		kv[k].desc = desc // in place -- k, its precedence, does not move
	} else {
		if nk >= TABLE_SORT_KEYS_MAX {return} // full: refused, live sort untouched
		kv[nk] = {col = col, desc = desc}
		nk += 1
	}
	if !table_sort_build(doc, kv[:nk]) {return}
	if off, ok := table_sort_row_at(doc, 0); ok {doc.top = off}
}

// Remove `col`'s key and rebuild with what is left, preserving the relative
// precedence of every other live key -- the loop below copies them in their
// existing order, skipping only the dropped one.
//
// Removing the LAST key rebuilds from an empty slice, which is table_sort_build's
// own "nothing to sort" refusal (`usable := nk > 0 ...` on its first lines) -- the
// same clear-and-stay-unsorted outcome table_sort_clear performs, reached without
// a separate branch for it here. That build call returns false, so the
// scroll-to-top below does not run for it either, matching table_sort_cycle's own
// descending-to-clear branch: doc.top is left alone because there is no
// permutation left for it to be an offset into.
table_sort_drop :: proc(doc: ^Document, col: int) {
	if doc == nil || col < 0 {return}
	if doc.table_editing {table_edit_commit(doc)}
	s := &doc.table_sort
	k, ok := table_sort_key(doc, col)
	if !ok {return} // not a key -- nothing to drop
	kv: [TABLE_SORT_KEYS_MAX]Sort_Key
	nk := 0
	for i in 0 ..< s.nkeys {
		if i == k {continue}
		kv[nk] = s.keys[i]
		nk += 1
	}
	if !table_sort_build(doc, kv[:nk]) {return}
	if off, ok := table_sort_row_at(doc, 0); ok {doc.top = off}
}

// Ctrl+click: the three-state cycle PER KEY that composes onto a live sort
// instead of replacing it -- table_sort_cycle's job -- because "sort by
// department, then by name" (TABLE_SORT_KEYS_MAX's comment) needs a gesture that
// adds a tie-breaker without disturbing the key already there.
//
// NOT A KEY -> append ascending, through table_sort_add -- but only when
// table_sort_can_add says there is room. At the cap this does nothing at all,
// silently, and the two live keys and their order are exactly what they were:
// the trap this task's brief named by name, delegating the cap check to
// table_sort_build here would clear the live sort just to learn it should have
// stayed clear. ASCENDING -> DESCENDING flips in place through table_sort_add,
// which is what keeps a Ctrl+click on the primary key from demoting it
// (table_sort_add's own comment carries that argument). DESCENDING -> REMOVED
// drops just this key through table_sort_drop; removing the last live key leaves
// the document unsorted.
table_sort_toggle :: proc(doc: ^Document, col: int) {
	if doc == nil || col < 0 {return}
	if doc.table_editing {table_edit_commit(doc)}
	k, is_key := table_sort_key(doc, col)
	switch {
	case !is_key:
		if table_sort_can_add(doc, col) {table_sort_add(doc, col, false)}
	case !doc.table_sort.keys[k].desc:
		table_sort_add(doc, col, true)
	case:
		table_sort_drop(doc, col)
	}
}

// Keep the offsets describing the bytes they were built from, across an edit of
// [at, at+n) with `text`. Called from pt_edit_replace, BEFORE the mutation, beside
// ckpt_repair and bookmarks_shift_replace for the same reason all three are there:
// it is the one procedure every buffer write passes through.
//
// A NEWLINE ON EITHER SIDE DROPS THE SORT. A row start is the byte after a '\n', so
// removing a newline destroys a row and inserting one creates a row -- either
// changes the row SET, which a shift over a fixed-length array cannot express, and
// a permutation with a stale row count resolves visible rows to lines that are no
// longer there. Dropping is the fail-closed answer and it costs nothing in
// practice: the only buffer write table view has is table_edit_commit's
// single-field splice, and a cell's value can never contain a newline (table_edit_rune
// refuses every rune below 32 and csv_serialize only ever wraps what is there).
//
// Otherwise every offset strictly after `at` moves by len(text) - n. An offset
// EQUAL to `at` does not: an insert at a line's first byte pushes that line's old
// bytes right, and the line still begins where it began. Same rule, same reason, as
// ckpt_repair's `offset <= at` case.
// Do the bytes about to be removed contain a newline? Read from the LIVE buffer,
// which is why table_sort_shift has to run before the mutation. doc.odin's own
// count_newlines is file-private there and this needs a predicate rather than a
// count, so it is stated here; 512-byte chunks for the same reason
// table_edit_line_intact uses them (nothing on the frame loop's stack that a
// RENDER_LINE_CAP buffer would put there). A SHORT read is treated as "yes":
// having failed to see the bytes, the only safe conclusion is the one that drops
// the sort.
@(private = "file")
sort_range_has_newline :: proc(doc: ^Document, at, n: int) -> bool {
	buf: [512]u8
	off := 0
	for off < n {
		c := min(len(buf), n - off)
		got := base.pt_read(&doc.pt, at + off, buf[:c])
		for b in buf[:got] {if b == '\n' {return true}}
		if got != c {return true}
		off += c
	}
	return false
}

// NOT gated on doc.table, and that is a decision rather than an omission. The
// whole-branch review found this pass running per keystroke in the plain text
// editor for any document that had once been in the grid, and the tempting fix
// was a `!doc.table` early return. It would be the wrong one: this procedure's
// job is to keep `offs` describing the bytes it was built from, and skipping it
// while the grid is off would leave a permutation that resolves visible rows to
// lines that have moved -- and the next Ctrl+T would commit a cell edit onto one
// of them. That is the data-loss failure this whole block exists to prevent,
// traded for a saved pass. table_sorted gates the VIEW on doc.table; this gates
// the DATA, and the data has to stay honest for exactly as long as it exists. The
// real fix was to stop it existing: every leave path clears the sort now, so
// there is nothing here to shift.
table_sort_shift :: proc(doc: ^Document, at, n: int, text: []u8) {
	s := &doc.table_sort
	if s.nkeys == 0 || len(s.offs) == 0 {return}
	for b in text {
		if b == '\n' {table_sort_clear(doc);return}
	}
	if n > 0 && sort_range_has_newline(doc, at, n) {table_sort_clear(doc);return}
	d := len(text) - n
	if d == 0 {return}
	// The everyday case first, for the same reason ckpt_repair takes it first: an
	// edit past the last row moves nothing, and a tailing log would otherwise pay a
	// full pass per append.
	if s.offs[len(s.offs) - 1] <= at {return}
	for &o in s.offs {
		if o > at {o += d}
	}
}

// --- the sorted grid's scroll model ---------------------------------------
//
// doc.top is a BYTE OFFSET in every mode, sorted or not (see this block's opening
// comment for why that is the invariant worth paying for). What changes under a
// sort is what "the next row" means, so these four are the sorted answers to the
// four questions the scroll model asks, and each has exactly one call site in
// doc.odin / main.odin. They return `ok = false` when there is no sort, which is
// what makes each of those call sites a single guarded line rather than a branch.

// Highest sorted position that still fills the screen.
@(private = "file")
sort_max_pos :: #force_inline proc(doc: ^Document, rows: int) -> int {
	return max(0, table_sort_rows(doc) - max(1, rows))
}

// Put doc.top back on a row the permutation contains, and inside the scrollable
// range. ONE GUARD, once per frame, from main.odin's update phase beside
// table_edit_hold -- the same argument that put that one there rather than a
// commit in each of seven scroll handlers.
//
// The four helpers above cover the routes that move doc.top BY ROWS. They do not
// cover the routes that write it as a plain byte offset without any idea a grid is
// on screen: doc_ensure_cursor_visible (which is how Ctrl+Home reaches doc.top --
// it sets the cursor to 0 and the view follows), a find jump, a session restore,
// and any clamp. Branching inside each of those would be four more places to miss
// the fifth, and the failure is not cosmetic: doc.top between two rows leaves
// table_sort_pos naming the row that CONTAINS it, so the whole screen would be one
// row out and a cell edit would commit there.
//
// Ctrl+Home comes out CORRECT rather than merely safe, and by construction:
// doc.top = 0 is below every row offset, table_sort_pos finds no checkpoint at or
// below it and refuses, and the refusal lands on sorted position 0 -- which is
// exactly what "go to the top" means in a sorted view. Ctrl+End does not: it puts
// doc.top near the end of the FILE, whose sorted position is wherever the file's
// last row happens to have gone. It is clamped into range here and it is a known
// gap, recorded rather than papered over.
table_sort_snap :: proc(doc: ^Document, rows: int) {
	if !table_sorted(doc) {return}
	pos, ok := table_sort_pos(doc, doc.top)
	if !ok {pos = 0}
	if off, ok2 := table_sort_row_at(doc, clamp(pos, 0, sort_max_pos(doc, rows))); ok2 {doc.top = off}
}

// The wheel and the page keys: move by `delta` SORTED rows.
table_sort_scroll :: proc(doc: ^Document, delta, rows: int) -> bool {
	if !table_sorted(doc) {return false}
	pos, pok := table_sort_pos(doc, doc.top)
	if !pok {pos = 0}
	if off, ok := table_sort_row_at(doc, clamp(pos + delta, 0, sort_max_pos(doc, rows))); ok {doc.top = off}
	return true
}

// Ctrl+End, and the clamp every other scroll ends with.
table_sort_max_top :: proc(doc: ^Document, rows: int) -> (off: int, ok: bool) {
	if !table_sorted(doc) {return 0, false}
	return table_sort_row_at(doc, sort_max_pos(doc, rows))
}

// The scrollbar drag's inverse. ROW-proportional rather than the editor's
// byte-proportional, and that is not a compromise: under a permutation the bytes
// are in no order at all, so a byte fraction names nothing a reader could aim at.
table_sort_scroll_frac :: proc(doc: ^Document, frac: f32, rows: int) -> bool {
	if !table_sorted(doc) {return false}
	mx := sort_max_pos(doc, rows)
	if off, ok := table_sort_row_at(doc, clamp(int(frac * f32(mx) + 0.5), 0, mx)); ok {doc.top = off}
	return true
}

// ...and the forward direction, for the thumb. `frac` positions it, `size` is the
// visible fraction of the row count. Must stay the exact inverse of the proc above
// -- vscrollbar_geo's comment records what a mismatched pair costs (the document
// creeping while the thumb is held perfectly still).
table_sort_thumb :: proc(doc: ^Document, rows: int) -> (frac, size: f32, ok: bool) {
	if !table_sorted(doc) {return 0, 0, false}
	n := table_sort_rows(doc)
	mx := sort_max_pos(doc, rows)
	pos, pok := table_sort_pos(doc, doc.top)
	if !pok {pos = 0}
	return f32(pos) / f32(max(1, mx)), f32(max(1, rows)) / f32(max(1, n)), true
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

// Does this row disagree with the header about how many fields a row has?
//
// §10: "Malformed rows are marked, not hidden. A row with the wrong field count
// gets a 2px warning bar on its left edge and stays in place. Silently dropping
// data in a data viewer is the worst possible failure."
//
// The reference is the HEADER's field count, not len(doc.table_widths). Those two
// are different numbers and the difference is the whole reason this takes an
// argument rather than reading the widths: table_compute_widths takes the MAXIMUM
// column index over its whole 500-row sample, so one row with an extra comma adds
// a column to the grid that the header does not have. Judged against the widths,
// every well-formed row in that file would be "missing" the phantom column and the
// entire table would be striped with warnings -- the mark would name the majority
// and stay silent about the one row that is actually wrong.
//
// AND THIS MUST AGREE WITH THE DRAW'S MISSING-FIELD SKIP BY CONSTRUCTION, which is
// the property to hold onto rather than the two rules separately. The draw skips a
// cell when `col.c >= len(row.fields)` (a MISSING field -- distinct from an EMPTY
// one, which gets TABLE_EMPTY_CELL's dash). Take any skipped cell whose column the
// header has, i.e. col.c < ncols: then len(row.fields) <= col.c < ncols, so
// nfields != ncols and the row is marked. So *every row with a hole inside the
// header's columns carries the bar*, with no second rule to keep in step. A skip at
// col.c >= ncols is a column the header never declared -- it exists only because
// some OTHER row had extra fields, and the rows lacking it are the well-formed
// ones. tablegridtest asserts the implication by enumerating columns rather than by
// re-deriving this expression.
//
// ncols == 0 (an empty document, or a header line that would not read) marks
// nothing: with no header there is nothing to disagree with, and marking every row
// on screen would be a confident answer from no evidence.
table_row_malformed :: #force_inline proc(nfields, ncols: int) -> bool {
	return ncols > 0 && nfields != ncols
}

// --- the grid's horizontal geometry: ONE producer ------------------------

// A visible column's cell rectangle. `x` is the LEFT EDGE of the cell (the band
// the zebra and the edit highlight fill), `w` its full width including both
// paddings; the text inside starts at table_cell_text_x and is clipped to
// `cells`.
Table_Col :: struct {
	c:     int, // column index into doc.table_widths
	x, w:  f32,
	// The width the cell is LAID OUT at, in cells. Equal to doc.table_widths[c]
	// now that the leftover distribution is gone (see table_cols_layout), and
	// still carried here rather than read back out of doc.table_widths by each
	// consumer: `w` and this are two views of one number, and every consumer that
	// truncates, clips or nudges asks the LAYOUT rather than the sample, so a
	// future change to how a column's width is chosen reaches all of them at once.
	// That is not hypothetical -- while the distribution existed, a consumer
	// reading the sample inside a widened rectangle clipped short of where the
	// draw put its glyphs, and this field is what fixed it.
	cells: int,
	align: Table_Align,
}

// The furthest right anything in this view may be DRAWN: the window minus the
// vertical scrollbar. Not where the table ends -- that is table_content_right,
// and conflating the two is what left the bands running into empty space.
table_right :: #force_inline proc(width: f32) -> f32 {return width - SCROLLBAR_W}

// The width the horizontal scroll actually pans: everything between the sticky
// row-number gutter and the grid's right edge.
//
// The gutter is EXCLUDED because it does not scroll. It carries the row's
// identity rather than its content (table_gutter_w), so it stays put while the
// cells slide under it, and a pannable width that included it would let the last
// column stop 56px short of the right edge at full scroll.
table_view_w :: #force_inline proc(width: f32) -> f32 {
	return max(0, table_right(width) - table_gutter_w())
}

// One column's laid-out width in pixels: its cells plus §10's padding on both
// sides. THE definition, so table_cols_layout (which places the columns) and
// table_content_w (which measures all of them for the scroll range) cannot come
// to disagree about how wide a column is -- the scroll range would then either
// refuse to reach the last column or pan past the end of the table.
table_col_w :: #force_inline proc(cells: int, char_w: f32) -> f32 {
	return f32(cells) * char_w + TABLE_CELL_PAD_X * 2
}

// Every column's width added up -- the full extent of the pannable axis.
//
// A SUM, and it has to be: table_cols_layout only knows about the columns that
// are on screen, so it cannot answer "how much is there in total". That is the
// one thing the layout is not the producer of, and the two are kept honest by
// both going through table_col_w rather than by both spelling out the same
// expression.
table_content_w :: proc(doc: ^Document, char_w: f32) -> f32 {
	w := f32(0)
	for cells in doc.table_widths {w += table_col_w(cells, char_w)}
	return w
}

// The furthest right the grid may be panned, in PIXELS. Zero when the whole
// table fits, which is also what makes the h-scrollbar hide itself
// (hscrollbar_geo refuses on max <= 0).
//
// Rounded UP (the +0.5 is a round-to-nearest on a value that is then used as an
// inclusive bound) so that full scroll puts the last column's right edge AT the
// grid's right edge rather than a fraction of a pixel short of it -- char_w is
// fractional, so a truncated bound leaves a sliver of the last column
// permanently unreachable.
table_max_scroll_x :: proc(doc: ^Document, char_w, width: f32) -> int {
	over := table_content_w(doc, char_w) - table_view_w(width)
	if over <= 0 {return 0}
	return int(over + 0.5)
}

// The grid's horizontal scroll offset, clamped. One expression, because the
// draw, all three hit-tests and the horizontal scrollbar need the same answer
// and doc.table_hscroll_px can be stale by a frame after a resize widens the
// grid or after a column is dragged narrower.
//
// This is table_start_col's replacement and it answers in PIXELS. The old one
// answered with a column INDEX, which is why panning jumped a whole column at a
// time; see doc.table_hscroll_px for the report and the decision.
table_scroll_x :: proc(doc: ^Document, char_w, width: f32) -> f32 {
	return f32(clamp(doc.table_hscroll_px, 0, table_max_scroll_x(doc, char_w, width)))
}

// Every visible column's cell rectangle, left to right. THE producer for the
// grid's x axis: consumed by the draw, the cell hit-test, the header hit-test,
// the resize-edge hit-test, the link layout, the in-cell edit box and the
// horizontal scrollbar. Four of those used to advance their own copy of
// `cx += (colw[c] + TABLE_COL_PAD) * char_w` from their own origin, which is
// precisely the divergence that writes an edit into the wrong column.
//
// THE SCROLL OFFSET IS NOT A PARAMETER, as of 2026-07-31. It used to take a
// `start_col` and every caller passed `table_start_col(doc)`; taking the pixel
// offset from doc directly (through table_scroll_x, which clamps) removes the
// last way a caller could lay out one x axis while the hit-test beside it laid
// out another. There is no caller that wants a scroll position other than the
// document's own.
//
// Cells tile from table_gutter_w() MINUS the scroll, not from x = 0 and not
// from TEXT_MARGIN_X.
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
// a band has to reach the LEFT window edge to read as a row at all -- one
// starting 56px in reads as a box around the data.
//
// **That argument is about the LEFT edge only, and the opposite holds on the
// right.** A band drawn to table_right on a table narrower than its window is
// hundreds of pixels of banded emptiness, and the table reads as broken rather
// than as narrow (Wyatt, live use, v0.34.1: *"table doesn't end on the right"*).
// So the bands stop at table_content_right and plain canvas follows. The two
// rules are not in tension: on the left the band ends where the WINDOW does, and
// on the right it ends where the DATA does, because that is the edge the reader
// is looking for in each case.
//
// A column that STARTS before the right edge is included even if it runs past
// it, so a partly-visible column is drawn and clickable rather than dead; the
// text inside it is clipped to the edge by the draw. Symmetrically, a column
// whose right edge is still past the gutter is included even though its left
// edge has scrolled under it -- pixel scrolling means the leftmost column is
// usually partly hidden, and dropping it would blank a column the reader can
// see most of. The gutter re-covers it: see the gutter pass in table_draw.
//
// --- §10's "distribute leftover width proportionally" IS DELIBERATELY NOT DONE
//
// A column is laid out at its CONTENT width -- doc.table_widths[c], the widest
// sampled cell clamped to 8-40, or the user's own width if they dragged one --
// and any spare window width is left EMPTY on the right.
//
// **This is a deviation from §10's literal rule, decided by Wyatt on 2026-07-31
// from live evidence, and it must not be "fixed" back.** CLAUDE.md says the spec
// wins about what should exist; this is the product owner overruling it after
// seeing the result, the same way TABLE_EMPTY_CELL's dash colour deviates from
// §10's `text_dim` call-out and records why above. §10's sentence reads perfectly
// sensibly and only looks wrong once it runs: three narrow columns on a wide
// display gave a 10-character date column ~400px, because proportional
// distribution has nothing to divide BY except the columns that exist, so a table
// with few columns hands each of them an enormous share. A column stretched five
// times past anything in it is not using the space, it is hiding the data at the
// two ends of a mostly-empty rectangle.
//
// The distribution's implementation (table_leftover_cells) was DELETED rather
// than left unused. It was file-private with exactly one caller, so keeping it
// would have meant an untestable, uncalled procedure whose comments describe a
// rule the file no longer follows -- which is worse than absent, because the next
// reader has to work out that it is dead before they can trust anything it says.
// The rule it implemented is recorded here, where the decision lives, and in git.
//
// WHAT DID NOT CHANGE, and Wyatt asked for this explicitly: drag-a-header-edge to
// resize and double-click-to-fit both still work exactly as they did.
// table_col_resize measures against the LAID-OUT rectangle, which is still the
// rectangle on screen; it is simply no longer wider than the sample. §10's other
// two column rules -- the 8-40 clamp and the bounded sample -- are untouched.
table_cols_layout :: proc(doc: ^Document, char_w, width: f32, allocator := context.temp_allocator) -> []Table_Col {
	out := make([dynamic]Table_Col, 0, 16, allocator)
	colw := doc.table_widths
	if len(colw) == 0 {return out[:]}
	right := table_right(width)
	gw := table_gutter_w()
	x := gw - table_scroll_x(doc, char_w, width)
	for c in 0 ..< len(colw) {
		if x >= right {break}
		cells := colw[c]
		w := table_col_w(cells, char_w)
		// Scrolled entirely under the sticky gutter: stepped over, not laid out.
		// At most ONE column can straddle the gutter's edge, so the columns this
		// skips are behind the reader and the walk is the cheapest way to reach
		// the first visible one -- an add per column, no allocation.
		if x + w > gw {
			al := doc.table_align[c] if c < len(doc.table_align) else Table_Align.Left
			append(&out, Table_Col{c = c, x = x, w = w, cells = cells, align = al})
		}
		x += w
	}
	return out[:]
}

// Where the TABLE ends on screen -- the last laid-out column's right edge, never
// past the grid's own right edge.
//
// THE producer for the bands' right edge, and it takes the LAYOUT rather than
// the document, deliberately: re-summing the widths here would be a second
// expression for a number table_cols_layout has already produced, and a draw
// that sums while a hit-test lays out is exactly the divergence this file is
// arranged against. Every caller already has the layout in hand.
//
// With no columns at all (an empty document, or the frame before
// table_compute_widths has run) the table is just its gutter, so that is where
// it ends. A band the full width of the window at that moment would be a
// promise of content that is not there.
table_content_right :: proc(cols: []Table_Col, width: f32) -> f32 {
	if len(cols) == 0 {return min(table_gutter_w(), table_right(width))}
	last := cols[len(cols) - 1]
	return min(last.x + last.w, table_right(width))
}

// --- §10's "drag a header edge to resize; double-click to fit content" ------
//
// Half-width of the grab zone straddling a header edge, at 96 DPI. Through sx()
// at each use rather than as a scaled global beside TABLE_GUTTER_W, and the
// difference is the point: the gutter is LAYOUT -- every consumer of the x axis
// has to agree on it to the pixel, so it lives with the other metrics and is set
// once by metrics_recompute -- while this is a TOLERANCE on a hit-test, wanted
// by one producer. A global for it would be six more places to forget to scale
// for no shared reader.
TABLE_RESIZE_HIT_96 :: f32(4)

// Upper bound on a column width the user dragged to, in cells.
//
// NOT TABLE_COL_MAX, and the difference is a real defect rather than a
// preference. §10's 40 bounds the AUTOMATIC sizing: it stops one 300-character
// cell claiming the whole window before anybody has asked for it. A drag is the
// gesture whose entire purpose is to override that bound, so clamping it at 40
// would mean a user with a wide window and a long field simply cannot see the
// field -- the automatic guard reaching back through the manual escape from it.
//
// This used to be argued from the leftover distribution as well ("§10's own
// distribution routinely lays a column out past 40, so a drag clamped at 40 would
// snap the column twenty cells narrower the moment it was grabbed"). That half of
// the argument retired with the distribution on 2026-07-31 -- automatic widths are
// now never above 40 -- and the number stays where it is on the first half alone.
// What is left is a guard against absurdity, not a design opinion; the pointer
// cannot leave the window, so a real drag never approaches it.
TABLE_COL_DRAG_MAX :: 500

// The header edge under a point, and the column that edge RESIZES (its left
// neighbour, which is the one whose width the drag changes).
//
// THE producer for that zone. The press, the double-click and the resize cursor
// all ask this one procedure, so the pixel that shows a resize cursor is exactly
// the pixel that starts a drag -- a hover zone and a press zone derived
// separately is CLAUDE.md's "one layout per widget" broken in its most annoying
// form, where the affordance appears somewhere the gesture does not work.
//
// Gated to the header band, because that is where §10 puts the affordance and
// because the same x inside the ROWS must keep starting a cell edit. Edges are
// taken from table_cols_layout, so they move with the gutter, with a user's
// dragged width, and with any future change to how a column's width is chosen,
// without this knowing any of them exists.
table_edge_at :: proc(doc: ^Document, char_w, width, mx, my, px: f32) -> (c: int, ok: bool) {
	if doc == nil || len(doc.table_widths) == 0 {return 0, false}
	top := table_grid_top()
	if my < top || my >= top + table_header_h(px) {return 0, false}
	tol := sx(TABLE_RESIZE_HIT_96)
	right := table_right(width)
	gw := table_gutter_w()
	if mx < gw {return 0, false} // the sticky gutter is not the table's x axis
	for col in table_cols_layout(doc, char_w, width) {
		e := col.x + col.w
		if e > right {break} // an edge past the grid's right edge is not on screen
		// ...and an edge scrolled under the gutter is not on screen either. The
		// gutter covers it (table_draw's gutter pass), so grabbing it would be a
		// drag on a divider the user cannot see -- the "affordance where the
		// gesture is not" failure in reverse.
		if e <= gw {continue}
		if mx >= e - tol && mx <= e + tol {return col.c, true}
	}
	return 0, false
}

// The column whose HEADER CELL is under a point -- §10's "click to sort".
//
// Through table_cols_layout, so the cell a click sorts is the cell the header text
// was drawn in, and through the same header-band gate table_edge_at uses, so the
// same x inside the rows keeps starting a cell edit. The gutter is not a column
// and this refuses inside it, so a press on a row number resolves to nothing and
// sorts nothing -- which is the wanted answer: the numbering is not data and has
// no order of its own. That refusal is EXPLICIT now rather than falling out of
// the layout starting at the gutter's edge: with pixel scrolling a column's
// rectangle genuinely extends under the gutter, and the pixels the gutter covers
// must not sort the column hiding behind them.
//
// The EDGE zone wins where the two overlap, and the caller (main.odin) tests it
// first for that reason: within ±4px of a boundary the user is aiming at the
// divider, and a sort fired by a slightly-off resize grab would reorder the whole
// file on a gesture meant to widen a column.
table_header_col_at :: proc(doc: ^Document, char_w, width, mx, my, px: f32) -> (c: int, ok: bool) {
	if doc == nil || len(doc.table_widths) == 0 {return 0, false}
	top := table_grid_top()
	if my < top || my >= top + table_header_h(px) {return 0, false}
	if mx < table_gutter_w() {return 0, false}
	for col in table_cols_layout(doc, char_w, width) {
		if mx >= col.x && mx < col.x + col.w {return col.c, true}
	}
	return 0, false
}

// The header cell the pointer is hovering FOR THE SORT GESTURE, or ok = false.
//
// §10 gives the header a click-to-sort and gives no discoverable sign of it.
// Wyatt, rejecting three proposals that added a second control: *"how will the
// person know what to click and where to reset."* The answer is not another hidden
// target, it is to LABEL the one that exists -- so the header lifts under the
// pointer and shows the arrow it would gain, and the summary row says the undo in
// words (table_summary_layout). This is the producer for the first half.
//
// PRECEDENCE, stated once here rather than left to each consumer:
//
//   the ±4px RESIZE EDGE ZONE WINS. Inside it this returns nothing -- no lift, no
//   ghost arrow -- because that is exactly where the press does not sort either
//   (main.odin tests table_edge_at first, and its own comment records why:
//   reordering a whole file on a slightly-off resize grab is not a recoverable
//   surprise). The cursor there is already .SizeWE. Showing a sort affordance over
//   a pixel that resizes would be the "affordance appears where the gesture does
//   not work" failure table_edge_at's comment was written about, with the added
//   insult that the gesture it advertises is the destructive-looking one.
//
// THREE BEHAVIOURS ON ONE RECT -- sort click, resize drag, and now hover -- and
// all three resolve through table_cols_layout and this file's two band gates, so
// the ordering above is the whole of the interaction. Note the DATA rows are
// unaffected in every case: table_edge_at and table_header_col_at both refuse
// outside the header band, which is what keeps the same x one row down a cell
// edit.
table_header_hover_col :: proc(doc: ^Document, char_w, width, mx, my, px: f32) -> (c: int, ok: bool) {
	if _, on_edge := table_edge_at(doc, char_w, width, mx, my, px); on_edge {return 0, false}
	return table_header_col_at(doc, char_w, width, mx, my, px)
}

// The boolean form, for the hover cursor -- which wants "is there an edge here"
// and has no use for which column it is. Through table_edge_at rather than
// beside it, so there is still exactly one definition of the zone.
table_edge_at_cursor :: #force_inline proc(doc: ^Document, char_w, width, mx, my, px: f32) -> bool {
	_, ok := table_edge_at(doc, char_w, width, mx, my, px)
	return ok
}

// Set column `c`'s width from a dragged edge position, in the same cells the
// layout speaks. The floor is §10's 8, the same one the sample obeys, so a
// dragged column can never end up narrower than one table_compute_widths would
// produce; the ceiling is TABLE_COL_DRAG_MAX rather than §10's 40, for the
// reason recorded there.
//
// The edge is measured against the column's LAID-OUT rectangle -- whatever that
// rectangle is made of -- because it is what the user grabbed. Drag the visible
// edge five cells right and the column becomes five cells wider than it looked,
// which is the only reading under which the edge follows the pointer. The layout
// and the sample used to be different numbers (the leftover distribution widened
// the one but not the other) and measuring against the sample put the edge a
// hand's width from the pointer; they coincide again since 2026-07-31, and this
// still asks the layout so that it stays right if they ever diverge a second time.
//
// Recorded in table_user_w, NOT only in table_widths, and that is the whole
// difficulty of this feature. table_compute_widths reruns whenever the widths
// are cleared -- which table_edit_commit does after every cell edit, so that the
// columns re-fit the new value -- and a width written only into table_widths is
// gone the next time the user edits any cell in the table. table_user_w survives
// that, and table_compute_widths reapplies it at the end of its own pass.
table_col_resize :: proc(doc: ^Document, c: int, edge_x, char_w, width: f32) {
	if doc == nil || c < 0 || c >= len(doc.table_widths) || char_w <= 0 {return}
	col, found := Table_Col{}, false
	for k in table_cols_layout(doc, char_w, width) {
		if k.c == c {col, found = k, true;break}
	}
	if !found {return} // scrolled out from under the drag
	cells := int((edge_x - col.x - TABLE_CELL_PAD_X * 2) / char_w + 0.5)
	table_col_set_width(doc, c, clamp(cells, TABLE_COL_MIN, TABLE_COL_DRAG_MAX))
}

table_col_set_width :: proc(doc: ^Document, c, cells: int) {
	if c < 0 || c >= len(doc.table_widths) {return}
	for c >= len(doc.table_user_w) {append(&doc.table_user_w, 0)}
	doc.table_user_w[c] = cells
	doc.table_widths[c] = cells
}

// §10's "double-click to fit content": drop the user's width and go back to the
// measured one.
//
// Clearing the override IS the fit, rather than a second measurement pass that
// would have to re-derive what table_compute_widths already knows. Clearing the
// widths makes table_draw re-sample on the next frame (its own "refit when
// empty" line), and with the override gone this column comes back at its widest
// sampled cell clamped to 8-40 -- which is the definition of fitting the
// content, taken from the one procedure that defines it.
table_col_fit :: proc(doc: ^Document, c: int) {
	if doc == nil || c < 0 {return}
	if c < len(doc.table_user_w) {doc.table_user_w[c] = 0}
	clear(&doc.table_widths)
	clear(&doc.table_align)
}

// Drop every manual width -- called where the grid re-samples from scratch (the
// view being turned off, a session restore), so a column the user narrowed in
// one file does not narrow a different column in the next.
table_user_widths_clear :: proc(doc: ^Document) {
	clear(&doc.table_user_w)
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

// --- the header's sort arrow: ONE producer for its rect AND its slot --------
//
// §10: "click to sort with an accent arrow." The arrow is drawn twice from two
// different states -- solid on the sorted column, dimmed on a HOVERED one, which
// is the affordance that says the header is clickable at all -- and it was
// positioned by an expression inlined in the draw. Two call sites deriving one
// rectangle is the divergence CLAUDE.md's "one layout per widget" names, and the
// dimmed preview has to land in EXACTLY the slot the solid one will occupy or it
// is a lie about what the click does.
//
// The width tracks the text (px * 0.6) and lands on whole pixels, so the stacked
// bars table_sort_arrow builds do not straddle two device pixels at 125%/150%.
// Height is half the width: the proportion that reads as an arrowhead rather than
// as a wedge at the sizes a header uses.
Table_Arrow :: struct {
	x, y, w, h: f32,
}

table_arrow_w :: #force_inline proc(px: f32) -> f32 {return f32(int(px * 0.6))}

// The gap between the header label and the arrow, in pixels. Half a cell pad --
// enough that the two read as separate marks, small enough that reserving it
// costs a narrow column no more than one extra character of its name.
table_arrow_gap :: #force_inline proc() -> f32 {return f32(int(TABLE_CELL_PAD_X * 0.5))}

// The arrow's rectangle inside a column's header cell: hard against the cell's
// right inner edge, vertically centred in the header band, and clamped so it
// stays on screen in a column that runs past the grid's right edge.
table_sort_arrow_rect :: proc(col: Table_Col, px, right: f32) -> Table_Arrow {
	w := table_arrow_w(px)
	h := w * 0.5
	return Table_Arrow {
		x = min(col.x + col.w - TABLE_CELL_PAD_X - w, right - w),
		y = table_grid_top() + f32(int((table_header_h(px) - h) * 0.5)),
		w = w,
		h = h,
	}
}

// The cells the arrow's slot takes out of a header cell -- the arrow plus its gap,
// rounded UP to a whole cell because the label is truncated in cells and half a
// cell of overlap is still overlap.
table_arrow_cells :: proc(char_w, px: f32) -> int {
	if char_w <= 0 {return 0}
	need := table_arrow_w(px) + table_arrow_gap()
	n := int(need / char_w)
	if f32(n) * char_w < need {n += 1}
	return n
}

// The header LABEL's own box: the column's cell with the arrow's slot taken off
// its right end. THE producer for where a header name is truncated AND for how
// far a right-aligned one is nudged -- both, because doing only the first is the
// bug this exists to fix in its other half.
//
// The arrow used to be drawn after the header text and on top of it, with the
// label truncated to the FULL cell width, so any name that filled its column had
// the triangle painted through it ("a smear below Date", Wyatt, live use,
// v0.34.0). Reserving the slot before the truncation is the fix, and the
// alignment nudge has to read the same narrowed box or a right-aligned header --
// which §10 pushes hard against the cell's right inner edge, precisely where the
// arrow lives -- would sit under the arrow however short it was.
//
// RESERVED ON EVERY COLUMN, sorted or not, hovered or not. The alternative is to
// reserve it only where an arrow is actually drawn, and that makes the header
// label re-truncate as the pointer crosses it: text that changes under the mouse,
// on the surface whose whole problem is that a click on it does something
// surprising. Every column is sortable, so every column is a column the arrow can
// appear in; paying the slot once, uniformly, keeps the header row still. The
// cost is at most one or two characters of a header name, and only for a name
// that already filled its column.
//
// x is unchanged, so table_cell_text_x still answers for the label; only the
// width narrows.
table_header_label_col :: proc(col: Table_Col, char_w, px: f32) -> Table_Col {
	lab := col
	n := min(table_arrow_cells(char_w, px), max(0, col.cells - 1)) // never below one cell of name
	lab.cells = col.cells - n
	lab.w = col.w - f32(n) * char_w
	return lab
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
	// A column the user dragged keeps the width they dragged it to, and this is
	// the line that makes drag-to-resize survive at all. This procedure reruns
	// whenever the widths are cleared, and table_edit_commit clears them after
	// every cell edit so the columns re-fit the new value -- so without this, a
	// resized column snaps back to its sampled width the next time any cell in
	// the table is edited. Applied AFTER the clamp because the override was
	// already clamped when it was set (table_col_resize); clamping it again here
	// would be a second opinion about the same bound.
	for c in 0 ..< len(doc.table_widths) {
		if c < len(doc.table_user_w) && doc.table_user_w[c] > 0 {doc.table_widths[c] = doc.table_user_w[c]}
	}
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

// The n-th field of `line`, unquoted, copied into `out`. ALLOCATION-FREE, and that
// is the whole reason it exists beside csv_fields rather than through it.
//
// The sort's pass runs over up to TABLE_SORT_MAX rows and wants exactly one field
// from each. csv_fields makes a [dynamic]string per line in the frame's temp
// arena, which nothing frees until the frame ends -- so at the ceiling one header
// click would leave well over a hundred megabytes of arena behind, permanently,
// since the temp allocator keeps its high-water mark. This walks the same grammar
// (quotes, "" escapes, a trailing delimiter meaning a final empty field) and writes
// one field.
//
// An absent field -- fewer fields on the line than `n` -- is EMPTY, matching what
// csv_fields' consumers see when they index past the end. For a sort key that is
// the right reading: a short row has no value in that column, and Sort_Item's
// `empty` then puts it at the end in both directions rather than sorting it as "".
//
// `out` must be able to hold a whole line; see table_sort_build's buffers for why
// a smaller one is not an option.
@(private = "file")
csv_field_into :: proc(line: string, delim: u8, n: int, out: []u8) -> string {
	i, ln := 0, len(line)
	for f := 0; ; f += 1 {
		want := f == n
		w := 0
		if i < ln && line[i] == '"' {
			i += 1
			for i < ln {
				if line[i] == '"' {
					if i + 1 < ln && line[i + 1] == '"' {
						if want && w < len(out) {out[w] = '"';w += 1}
						i += 2
						continue
					}
					i += 1
					break
				}
				if want && w < len(out) {out[w] = line[i];w += 1}
				i += 1
			}
			for i < ln && line[i] != delim {i += 1} // ignore anything after the close quote
		} else {
			s := i
			for i < ln && line[i] != delim {i += 1}
			if want {
				w = min(i - s, len(out))
				copy(out[:w], line[s:s + w])
			}
		}
		if want {return string(out[:w])}
		if i >= ln {return ""} // no such field on this line
		i += 1 // skip the delimiter
	}
}

// table_max_col and table_cols_fitting used to live here, and both were DELETED
// on 2026-07-31 rather than adapted, because both were column COUNTS answering
// questions the grid no longer asks in columns:
//
//   table_max_col      the largest column index the view could start at. Its
//                      replacement is table_max_scroll_x, in pixels -- the
//                      scroll's bound is now a distance, not an index.
//   table_cols_fitting the h-scrollbar's thumb span, "how many columns fit".
//                      **This is the second of the two things Wyatt's report
//                      said the scroll was snapping to.** It was a column COUNT
//                      derived from a pixel measurement, paired with a pos that
//                      was a column INDEX; the two only agree when every column
//                      has the same width, so the thumb changed size as it moved.
//                      Its replacement is table_view_w -- the same unit as the
//                      pos and the max, which is the whole fix.
//
// Deleted rather than left unused for table_leftover_cells' reason, recorded at
// table_cols_layout: an uncalled procedure whose comments describe a rule the
// file no longer follows is worse than an absent one.

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
	cols := table_cols_layout(doc, char_w, width, allocator)
	right := table_right(width)
	gw := table_gutter_w()
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
			// col.cells, the width the LAYOUT gave this column, rather than from
			// doc.table_widths[col.c] -- one producer for the x axis, as everywhere
			// else in this file. The two are the same number since the leftover
			// distribution was removed; while it existed the sample was the narrower
			// of the two, and reading it here left every link in a widened column
			// clipped short of where the draw put its glyphs.
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
				// Clipped at BOTH ends, and the left clip is new with pixel
				// scrolling: a cell scrolled under the sticky gutter is covered by
				// the gutter pass, but this rect is drawn by render_frame AFTER
				// table_draw returns, so an unclipped underline would be painted
				// over the row numbers -- and, worse, would still be clickable
				// there (table_link_hit reads exactly this rect). Clipping the rect
				// fixes the draw and the hit-test at once, which is why the rect is
				// clipped rather than the draw. `text`/`link` are untouched, so the
				// URL a partly-hidden link resolves to is still the whole URL.
				l0 := max(lx, gw)
				l1 := min(lx + f32(lcells) * char_w, cellright)
				if l1 > l0 {
					append(&out, Table_Link{x = l0, y = ry, w = l1 - l0, text = field, link = l})
				}
			}
		}
		// The same step the draw and table_row_start take, for the same reason: an
		// underline positioned by data-row index has to sit on the line that row
		// index resolves to, under a sort as much as without one.
		np, more, _ := table_row_next(doc, p, r + 1)
		if !more {break}
		p = np
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
//
// `hover_col` is the header cell under the pointer, or TABLE_SORT_NONE. Passed in
// rather than resolved here because the live cursor position lives on the platform
// window and this file is one layer below it -- and because the caller has to ask
// table_header_hover_col anyway for the cursor shape, so asking twice would be two
// chances for the drawn affordance and the pointer to disagree about the same
// pixel.
table_draw :: proc(gfx: ^plat.Gfx, qp: ^plat.Quad_Pipeline, text: ^plat.Text, doc: ^Document, px, char_w: f32, rows: int, width, height: f32, hover_col := TABLE_SORT_NONE) -> (bottom: int) {
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
	cols := table_cols_layout(doc, char_w, width)
	// Where the table ENDS, from the one x-axis producer rather than by re-summing
	// the widths here. Every band below stops at it; beyond it is plain canvas.
	// See table_content_right, and table_cols_layout for why the left edge and the
	// right edge answer this question differently.
	cright := table_content_right(cols, width)

	// The header's fields, fetched HERE rather than at the sticky-header pass at
	// the bottom of this proc, because two passes now need them and one bounded
	// pt_read at offset 0 is what "sticky" already costs -- paying it twice would
	// be two chances for the malformed test and the drawn header to disagree about
	// how many columns the file declares.
	head := table_header_fields(doc)

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
		for r in 0 ..< rows {
			if p > doc.pt.length {break}
			end := base.pt_line_end_cap(&doc.pt, p, RENDER_LINE_CAP)
			n := base.pt_read(&doc.pt, p, buf[:min(end - p, len(buf))])
			vb := n
			if vb > 0 && buf[vb - 1] == '\r' {vb -= 1}
			line := strings.clone(string(buf[:vb]), context.temp_allocator)
			append(&vis, Row{csv_fields(line, delim)})
			bottom = max(bottom, end)
			// Through table_row_next, which is table_row_start's own step. This
			// loop used to advance with `p = end + 1` and a comment saying it was
			// the same walk the hit-test performs -- true, and false the moment a
			// sort existed, since under a permutation the next visible row is not
			// the next line. Now the draw and the producer step through one
			// procedure and cannot disagree about it.
			np, more, _ := table_row_next(doc, p, r + 1)
			if !more {break}
			p = np
		}
	} else {
		bottom = doc.pt.length // a header with nothing under it: the whole file is on screen
	}

	// Zebra banding, in place of the per-column vertical rules this draw used to
	// emit (§10: a rule per column is "8 extra quads per screen and it makes the
	// grid louder than the data"). One quad per banded row, from the window's left
	// edge to the TABLE's right edge -- so the band reads as a row rather than as a
	// box around the text, and stops where the data does rather than trailing a few
	// hundred pixels of empty colour to the scrollbar (Wyatt, live use, v0.34.1).
	// table_cols_layout's comment has the full argument for why those two edges
	// answer differently.
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
		if table_row_band(absn, r) == 0 {continue}
		plat.quads_draw(gfx, qp, []plat.Quad{{pos = {0, table_row_rect_y(px, r)}, size = {cright, row_h}, color = zebra}})
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

	// The row-number gutter (§10: "56px right-aligned gutter"), LAST of the row
	// passes rather than first, and now a COVER STRIP.
	//
	// The reordering is what pixel scrolling costs. The gutter is sticky -- it
	// carries the row's identity, so it must not pan -- while the cells now slide
	// under it by any number of pixels (doc.table_hscroll_px), so the leftmost
	// column's glyphs genuinely land inside the gutter's 56px. There is no scissor
	// rect in this renderer (see md_preview_clip): clipping IS painting over, which
	// is the same convention the sticky header below rests on. Drawn first, as it
	// used to be, a scrolled cell's text was painted on top of the row numbers.
	//
	// Each row's strip is repainted in its OWN band colour, through table_row_band
	// -- the parity producer the zebra pass reads -- so a cover can never come back
	// a different colour from the band it covers. Bg_Base for an unbanded row is
	// the canvas the frame was cleared to (doc_canvas_clear), not a second opinion
	// about what the page colour is.
	//
	// §10's MALFORMED-ROW MARK rides along here for a mechanical reason: it is a
	// 2px bar at x = 0, inside the strip, so a cover painted after it would erase
	// it. It is still over the band and under nothing, which is all its placement
	// ever required.
	//
	// "a row with the wrong field count gets a 2px warning bar on its left edge and
	// stays in place. Silently dropping data in a data viewer is the worst possible
	// failure." STAYS IN PLACE is the load-bearing half -- nothing above filters
	// `vis`, and nothing may start.
	//
	// AT x = 0, the row's own left edge, and not at the gutter's right edge where it
	// would sit between the numbers and the first cell. Three reasons, in order of
	// weight:
	//
	//   - x = 0 IS the row's left edge. The zebra band and the header band both span
	//     from 0 for the same reason (a band that starts 56px in reads as a box
	//     around the data, not as a row), so the row the mark belongs to begins
	//     there. §10 says "on its left edge", and the gutter is part of the row.
	//   - a 2px vertical bar at the gutter/cell boundary, repeated down the screen,
	//     is a COLUMN RULE. §10 deleted those in this very view ("8 extra quads per
	//     screen and it makes the grid louder than the data"), and re-introducing one
	//     as the malformed mark would read as grid furniture -- exactly the thing a
	//     warning must not look like.
	//   - it cannot collide with the row number. The number is right-aligned to
	//     gutter_w - TABLE_CELL_PAD_X, so at 56px and 10px padding a label would have
	//     to be ~44px wide before its left edge reached the bar. The gutter's own
	//     comment records what happens past that (a six-digit number runs left to the
	//     window edge rather than truncating, which would change which row it names);
	//     at that point it overlaps the bar. A cosmetic overlap at a million rows,
	//     against a mark that is either at the row's edge or in the middle of it at
	//     every row count.
	//
	// A REFUSED row draws NO NUMBER. table_abs_rows hands back TABLE_ABS_NONE
	// when the file's numbering cannot be answered -- the background index has not
	// reached the row, the buffer was edited at or below it, or a mapped read
	// faulted -- and a plausible-looking wrong row number is worse than a blank,
	// because the reader has no way to tell it apart from a right one. This is
	// development-loop.md §4 Shape A, and blank is the honest answer.
	//
	// That refusal used to be MUCH wider than it is now, and the difference is
	// worth stating here because this gutter is what made it visible: nothing
	// raised Line_Index.edit_floor once an edit had lowered it, and doc_save does
	// not re-index, so editing one cell blanked every row number below it for the
	// life of the tab -- including after a save, the moment a user would most
	// expect them back. Fixed at the source rather than here: once the index is
	// finished the checkpoints are repaired into document coordinates on every
	// edit (Line_Index.ckpt_doc, doc.odin), so an edit and a save now leave the
	// numbering intact. What still refuses is genuinely unanswerable -- the worker
	// has not reached the row, the edit raced the initial scan, a huge paste left
	// two checkpoints further apart than CKPT_SCAN_CAP, or a mapped read faulted.
	// Guessing in any of those would be exactly the Shape A the flag exists to
	// prevent.
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
		warn := g_theme[.Warning]
		zeb := g_theme[.Table_Zebra]
		bg := doc_canvas_clear()
		ww := sx(TABLE_WARN_W_96)
		gw := min(table_gutter_w(), cright)
		for row, r in vis {
			ry := table_row_rect_y(px, r)
			plat.quads_draw(gfx, qp, []plat.Quad{{pos = {0, ry}, size = {gw, row_h}, color = zeb if table_row_band(absn, r) != 0 else bg}})
			if table_row_malformed(len(row.fields), len(head)) {
				plat.quads_draw(gfx, qp, []plat.Quad{{pos = {0, ry}, size = {ww, row_h}, color = warn}})
			}
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
			gx := max(f32(0), table_gutter_w() - TABLE_CELL_PAD_X - w)
			colour := num_fg
			if doc.table_editing && doc.table_edit_row == r {colour = cur_fg}
			plat.text_draw(gfx, text, label, gx, table_row_baseline_y(px, r), px, colour, .Doc)
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
	if len(head) > 0 {
		// To cright, not to `right`: the header band is a band like the zebra's and
		// stops where the table does. See table_cols_layout.
		plat.quads_draw(gfx, qp, []plat.Quad{{pos = {0, table_grid_top()}, size = {cright, table_header_h(px)}, color = g_theme[.Bg_Raised]}})
		// The HOVER LIFT, over the band and under the rule, the text and the arrow.
		// Bg_Hover is §1.1's role for exactly this ("hover fill for any tab, menu
		// row, settings row or palette row"), so a hovered header reads as the same
		// kind of thing as every other hoverable row in the app -- which is the
		// whole point: the reader has met this signal elsewhere. The cell rect is
		// the layout's, so the lift covers precisely the pixels that sort.
		if hover_col != TABLE_SORT_NONE {
			for col in cols {
				if col.c != hover_col {continue}
				plat.quads_draw(gfx, qp, []plat.Quad{{pos = {col.x, table_grid_top()}, size = {min(col.w, cright - col.x), table_header_h(px)}, color = g_theme[.Bg_Hover]}})
				break
			}
		}
		hy := table_header_baseline_y(px)
		for col in cols {
			if col.c >= len(head) {continue}
			field := head[col.c]
			if len(field) == 0 {continue} // a nameless column: leave it blank, don't dash a header
			// The LABEL's box, not the cell's: the arrow's slot is reserved off the
			// right end BEFORE the truncation, which is what stops a name that fills
			// its column having the triangle painted through it. See
			// table_header_label_col -- the nudge below reads the same narrowed box,
			// because a right-aligned header pushed to the cell's right inner edge
			// would otherwise land under the arrow no matter how short it was.
			lab := table_header_label_col(col, char_w, px)
			fb := transmute([]u8)field
			hcells := plat.text_cells(text, fb, 0, .Doc)
			if hcells > lab.cells {
				field = field[:plat.text_bytes_for_cells(text, fb, lab.cells, 0, .Doc)]
				hcells = lab.cells
			}
			// The header takes its column's alignment, so a right-aligned numeric
			// column reads as ONE column rather than as a left-aligned label with
			// right-aligned numbers wandering away underneath it.
			// Text_Bright, the role §1.1 gives to "active tab label, titles" --
			// the header is now a real header (§10) and the previous draw made no
			// distinction at all: both branches of its `hl` resolved to
			// Text_Primary, so the "highlighted" header row was a no-op.
			hx := table_cell_text_x(lab) + table_cell_align_dx(lab, hcells, char_w)
			plat.text_draw(gfx, text, field, hx, hy, px, g_theme[.Text_Bright], .Doc)
		}
		// §10's "click to sort with an accent arrow", and the DIMMED preview of it on
		// a hovered column. Both through table_sort_arrow_rect, so the ghost lands in
		// exactly the slot the solid arrow will occupy -- an affordance that moved
		// once the click landed would be worse than none.
		//
		// The sorted column wins where the two would coincide: hovering the column
		// that is already sorted shows its real arrow at full strength rather than
		// replacing it with a preview of itself. `up` is what the NEXT click
		// produces on an unsorted column, which is ascending (table_sort_cycle), so
		// the ghost is a prediction rather than a decoration.
		//
		// Drawn after the header text either way. It no longer overlaps it -- the
		// slot above is reserved -- but the ordering is free and a header whose name
		// somehow reached the slot would still lose to the mark rather than hide it.
		{
			sorted_col := doc.table_sort.keys[0].col if table_sorted(doc) else TABLE_SORT_NONE
			for col in cols {
				dim := false
				switch {
				case col.c == sorted_col:
				case col.c == hover_col:
					dim = true
				case:
					continue
				}
				// Quads, not a glyph. The document face is the user's monospace font
				// and nothing guarantees it has U+25B2/U+25BC -- a missing glyph is a
				// tofu box or nothing at all, and "nothing at all" would leave the
				// sorted column indistinguishable from the others, which is the one
				// thing this mark exists to prevent. Four stacked bars are a triangle
				// at any font, any DPI and any theme.
				a := table_sort_arrow_rect(col, px, right)
				colour := g_theme[.Accent]
				up := true
				if dim {
					// Straight alpha over whatever is behind it (quads.odin binds a
					// SRC_ALPHA blend), so the ghost is the accent at reduced weight
					// rather than a second colour role that would have to be added to
					// every theme and kept in step with Accent by hand.
					colour[3] *= TABLE_ARROW_GHOST_A
				} else {
					up = !doc.table_sort.keys[0].desc
				}
				table_sort_arrow(gfx, qp, a, up, colour)
			}
		}
		// The gutter's cover strip, in the header band -- the same clip the row pass
		// applies, for the same reason. A column scrolled part-way under the gutter
		// has its NAME and its sort arrow in the header band at the same negative
		// offset its cells have in the rows, and leaving the header uncovered would
		// make the sticky 56px look sticky on the data and porous on the heading.
		// Bg_Raised because that is what the band under it is.
		plat.quads_draw(gfx, qp, []plat.Quad{{pos = {0, table_grid_top()}, size = {min(table_gutter_w(), cright), table_header_h(px)}, color = g_theme[.Bg_Raised]}})
		// A 1px Border_Strong rule beneath it (§10), LAST so it survives both cover
		// strips and any descender from a tall header name. Border_Strong and not
		// Border_Subtle: this is the one boundary in the grid now that the column
		// rules are gone, and §1.1 names "table header rule" as what Border_Strong is
		// for. hairline() so it stays one device pixel at 125%/150% instead of
		// straddling two and rasterising blurry. To cright, with the band it underlines.
		plat.quads_draw(gfx, qp, []plat.Quad{{pos = {0, table_grid_top() + table_header_h(px) - hairline()}, size = {cright, hairline()}, color = g_theme[.Border_Strong]}})
	}

	// §10's summary row, LAST of all: "row count, column count, active sort -- the
	// questions you actually have about a CSV, in the place you already look for
	// file facts."
	//
	// A band of its own above the status bar rather than a cell IN the status bar.
	// The status bar is the document's (encoding, line ending, caret position) and
	// is the same in every view; these are the grid's, and they stop being true the
	// moment the view is toggled off. table_visible_rows already reserves this strip
	// out of the row budget, so nothing is drawn under it and nothing hit-tests into
	// it -- see that procedure for why the reservation is there and not here.
	//
	// It sits above the HORIZONTAL SCROLLBAR's strip now, not across it. Both bands
	// are pinned to the same bottom edge and both were laid out from it
	// independently, so the bar was painted through the summary's text (Wyatt, live
	// use, v0.34.0); table_bottom_band_h reserves the pair and table_summary_y is
	// measured off it.
	//
	// Bg_Raised and a rule ABOVE it, mirroring the sticky header's fill and its rule
	// BELOW: the two bands bracket the data, which is what makes a strip read as
	// chrome rather than as one more row of the table.
	//
	// THE ONE BAND THAT STILL SPANS THE FULL WIDTH, deliberately, while the zebra
	// and the header now stop at cright (2026-07-31). It is not a row of the table
	// -- it is a strip of chrome directly above the status bar, and it reads as one
	// only if it behaves like one. Two concrete consequences settle it: a
	// full-width strip matches the status bar it sits on top of, where a strip
	// clipped to the columns would read as a fourth row of a three-column table;
	// and its TEXT is not bounded by the columns at all (`1,000 rows · 1 column ·
	// sorted by Date desc · click to clear` is far wider than a one-column CSV), so
	// a band clipped to cright would leave its own words -- and the clickable run
	// among them -- hanging off the end of it.
	{
		sm := table_summary_layout(doc, text, height, px, char_w)
		plat.quads_draw(gfx, qp, []plat.Quad{{pos = {0, sm.y}, size = {right, sm.h}, color = g_theme[.Bg_Raised]}})
		plat.quads_draw(gfx, qp, []plat.Quad{{pos = {0, sm.y}, size = {right, hairline()}, color = g_theme[.Border_Strong]}})
		// Text_Muted, the same tier the row-number gutter and the em dash take, and
		// for the third time the same argument: this is live content that has to be
		// readable, not a disabled control, so Text_Dim's below-AA exemption does not
		// cover it.
		base_y := sm.y + px + f32(int((sm.h - line_height(px)) * 0.5))
		if !sm.clearable {
			plat.text_draw(gfx, text, sm.text, sm.x, base_y, px, g_theme[.Text_Muted], .Doc)
		} else {
			// The `sorted by ... · click to clear` run is a control, so it is drawn
			// as one: Text_Secondary against the muted rest of the line, the same
			// brightening the row-number gutter gives the current row, and a role
			// that clears AA in both themes.
			//
			// TWO DRAWS AT THE TWO x's THE LAYOUT PRODUCED, not one draw with the
			// bright run painted over it: glyph coverage alpha-blends, so overdrawing
			// would leave every antialiased edge carrying the muted colour underneath
			// and the run would read as slightly bolder than it is. Both origins come
			// out of sm, so the split cannot land anywhere the hit-test does not
			// expect -- sm.clear_x IS where the bright text starts, by construction.
			plat.text_draw(gfx, text, sm.head, sm.x, base_y, px, g_theme[.Text_Muted], .Doc)
			plat.text_draw(gfx, text, sm.clear_text, sm.clear_x, base_y, px, g_theme[.Text_Secondary], .Doc)
		}
	}
	return
}

// The sort direction mark: a solid triangle built from stacked bars, pointing up
// for ascending, drawn into the rectangle table_sort_arrow_rect produced.
//
// ARROW_STEPS bars rather than a real triangle because the renderer draws quads and
// only quads (CLAUDE.md's layer boundary: "renderer -- quads only"). Four is enough
// that the staircase is invisible at 10-16px and few enough that a sorted header
// costs four quads, not a mesh.
//
// It takes the RECT rather than an x/y/w triple so that the one producer's answer
// is passed around whole -- a caller cannot hand it three of the four numbers from
// the layout and the fourth from somewhere else -- and it takes the COLOUR because
// the hover ghost is the same triangle at a lower alpha, and a `dim: bool` here
// would put a second policy decision inside a drawing primitive.
@(private = "file")
TABLE_ARROW_STEPS :: 4

// The hover ghost's alpha, as a fraction of the solid arrow's. Low enough that it
// cannot be mistaken for a live sort at a glance -- the reader must be able to see
// which column IS sorted while hovering a different one -- and high enough to read
// against Bg_Hover in both themes.
TABLE_ARROW_GHOST_A :: f32(0.45)

@(private = "file")
table_sort_arrow :: proc(gfx: ^plat.Gfx, qp: ^plat.Quad_Pipeline, a: Table_Arrow, up: bool, col: [4]f32) {
	h := max(hairline(), f32(int(a.h / TABLE_ARROW_STEPS)))
	for i in 0 ..< TABLE_ARROW_STEPS {
		// Widest at the base, narrowest at the tip; `up` only decides which end the
		// tip is at, so one expression covers both directions.
		k := f32(i if up else TABLE_ARROW_STEPS - 1 - i)
		bw := a.w * (k + 1) / TABLE_ARROW_STEPS
		plat.quads_draw(gfx, qp, []plat.Quad{{pos = {a.x + (a.w - bw) * 0.5, a.y + f32(i) * h}, size = {bw, h}, color = col}})
	}
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
	// The sticky row-number gutter is not a cell, and it covers whatever cell has
	// scrolled under it. Without this an edit could be started -- and committed --
	// on a value the gutter is painted over, which is a write to a cell the user
	// cannot see. Explicit rather than implied by where the layout starts, for the
	// reason table_header_col_at's comment gives.
	if mx < table_gutter_w() {return}
	r = rr
	col = -1
	for c in table_cols_layout(doc, char_w, width) {
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
