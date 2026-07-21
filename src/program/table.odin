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

import "core:strings"
import base "src:base"
import plat "src:platform"

TABLE_COL_MAX :: 40 // widest a column grows to (cells); longer fields truncate
TABLE_COL_MIN :: 3
TABLE_COL_PAD :: 1 // cells of gap after a column

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

// Draw the visible rows as a grid. `doc.table_cols` is set here (the column count
// this frame) so input can clamp horizontal scroll. Returns the byte offset just
// past the last visible row, for the byte-proportional scrollbar.
table_draw :: proc(gfx: ^plat.Gfx, qp: ^plat.Quad_Pipeline, text: ^plat.Text, doc: ^Document, px, char_w: f32, rows: int, width: f32) -> (bottom: int) {
	delim := doc.table_delim if doc.table_delim != 0 else ','
	lh := line_height(px)
	bottom = doc.top

	// Pass 1: parse the visible rows and measure each column.
	Row :: struct {
		fields: []string,
	}
	vis := make([dynamic]Row, 0, rows, context.temp_allocator)
	colw := make([dynamic]int, 0, 16, context.temp_allocator)
	buf: [RENDER_LINE_CAP]u8
	p := doc.top
	for _ in 0 ..< rows {
		if p > doc.pt.length {break}
		end := base.pt_line_end_cap(&doc.pt, p, RENDER_LINE_CAP)
		n := base.pt_read(&doc.pt, p, buf[:min(end - p, len(buf))])
		vb := n
		if vb > 0 && buf[vb - 1] == '\r' {vb -= 1}
		line := strings.clone(string(buf[:vb]), context.temp_allocator)
		fields := csv_fields(line, delim)
		append(&vis, Row{fields})
		for f, c in fields {
			w := plat.text_cells(text, transmute([]u8)f, .Doc)
			for c >= len(colw) {append(&colw, 0)}
			if w > colw[c] {colw[c] = w}
		}
		bottom = end
		if end >= doc.pt.length {break}
		p = end + 1
	}
	doc.table_cols = len(colw)
	for &w in colw {w = clamp(w, TABLE_COL_MIN, TABLE_COL_MAX)}

	start_col := clamp(doc.table_col, 0, table_max_col(doc))
	right := width - SCROLLBAR_W
	fg := [4]f32{0.86, 0.90, 0.96, 1}
	sep := [4]f32{0.24, 0.27, 0.33, 1}
	head_bg := [4]f32{0.16, 0.20, 0.27, 1}
	top := row_rect_y(px, 0)
	bot := row_rect_y(px, len(vis))

	// Header row (only when the real first line is on screen) gets a band.
	if doc.top == 0 && len(vis) > 0 {
		plat.quads_draw(gfx, qp, []plat.Quad{{pos = {0, row_rect_y(px, 0)}, size = {right, lh}, color = head_bg}})
	}

	// Columns: separators (full height) + clipped cell text.
	cx := TEXT_MARGIN_X
	for c := start_col; c < len(colw); c += 1 {
		if cx >= right {break}
		if c > start_col {
			plat.quads_draw(gfx, qp, []plat.Quad{{pos = {cx - char_w * 0.5, top}, size = {max(sx(1), 1), bot - top}, color = sep}})
		}
		cellcells := colw[c] + TABLE_COL_PAD
		for row, r in vis {
			if c >= len(row.fields) {continue}
			field := row.fields[c]
			fb := transmute([]u8)field
			if plat.text_cells(text, fb, .Doc) > colw[c] { // truncate an over-wide field
				cut := plat.text_bytes_for_cells(text, fb, colw[c], .Doc)
				field = field[:cut]
			}
			hl := [4]f32{0.94, 0.96, 0.99, 1} if (doc.top == 0 && r == 0) else fg
			plat.text_draw(gfx, text, field, cx, row_baseline_y(px, r), px, hl, .Doc)
		}
		cx += f32(cellcells) * char_w
	}
	return
}
