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

TABLE_COL_MAX :: 40 // widest a column grows to (cells); longer fields truncate
TABLE_COL_MIN :: 3
TABLE_COL_PAD :: 1 // cells of gap after a column
TABLE_SAMPLE :: 500 // rows scanned once to fix the column widths

// Compute the per-column widths from the first TABLE_SAMPLE rows (bounded), so
// they stay fixed as the user scrolls. Recomputed when the view opens and after
// an edit; cheap relative to a frame.
table_compute_widths :: proc(doc: ^Document, text: ^plat.Text) {
	clear(&doc.table_widths)
	delim := doc.table_delim if doc.table_delim != 0 else ','
	buf: [RENDER_LINE_CAP]u8
	p := 0
	for _ in 0 ..< TABLE_SAMPLE {
		if p > doc.pt.length {break}
		end := base.pt_line_end_cap(&doc.pt, p, RENDER_LINE_CAP)
		n := base.pt_read(&doc.pt, p, buf[:min(end - p, len(buf))])
		if n > 0 && buf[n - 1] == '\r' {n -= 1}
		for f, c in csv_fields(string(buf[:n]), delim) {
			w := plat.text_cells(text, transmute([]u8)f, .Doc)
			for c >= len(doc.table_widths) {append(&doc.table_widths, 0)}
			if w > doc.table_widths[c] {doc.table_widths[c] = w}
		}
		if end >= doc.pt.length {break}
		p = end + 1
	}
	for &w in doc.table_widths {w = clamp(w, TABLE_COL_MIN, TABLE_COL_MAX)}
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
	colw := doc.table_widths
	if len(colw) == 0 {return out[:]}
	delim := doc.table_delim if doc.table_delim != 0 else ','
	start_col := clamp(doc.table_col, 0, table_max_col(doc))
	right := width - SCROLLBAR_W
	buf: [RENDER_LINE_CAP]u8
	p := doc.top
	for r in 0 ..< rows {
		if p > doc.pt.length {break}
		end := base.pt_line_end_cap(&doc.pt, p, RENDER_LINE_CAP)
		n := base.pt_read(&doc.pt, p, buf[:min(end - p, len(buf))])
		if n > 0 && buf[n - 1] == '\r' {n -= 1}
		fields := csv_fields(string(buf[:n]), delim, allocator)
		ry := row_baseline_y(px, r)
		cx := TEXT_MARGIN_X
		for c := start_col; c < len(colw); c += 1 {
			if cx >= right {break}
			cellright := min(cx + f32(colw[c]) * char_w, right)
			if c < len(fields) {
				field := strings.clone(fields[c], allocator)
				for l in links_scan(field, allocator) {
					lcol, lcells := plat.text_span_cells(text, field, l.start, l.len, .Doc)
					lx := cx + f32(lcol) * char_w
					if lx < cellright {
						append(&out, Table_Link{x = lx, y = ry, w = min(f32(lcells) * char_w, cellright - lx), text = field, link = l})
					}
				}
			}
			cx += f32(colw[c] + TABLE_COL_PAD) * char_w
		}
		if end >= doc.pt.length {break}
		p = end + 1
	}
	return out[:]
}

table_link_hit :: proc(links: []Table_Link, mx, my, px, line_h: f32) -> (Table_Link, bool) {
	for l in links {
		if mx >= l.x && mx < l.x + l.w && my >= l.y - px && my < l.y - px + line_h {
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
	lh := line_height(px)
	bottom = doc.top

	// Pass 1: parse the visible rows and measure each column.
	Row :: struct {
		fields: []string,
	}
	vis := make([dynamic]Row, 0, rows, context.temp_allocator)
	// Column widths come from a one-time sample (table_compute_widths), NOT from
	// the currently-visible rows, so columns don't shift as you scroll different
	// rows (a wider header, then narrower data) into view.
	if len(doc.table_widths) == 0 {table_compute_widths(doc, text)}
	colw := doc.table_widths
	buf: [RENDER_LINE_CAP]u8
	p := doc.top
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
	doc.table_cols = len(colw)

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

	// The cell being edited: draw the buffer + a caret over a highlight box,
	// instead of the source value, so the grid keeps its exact look.
	if doc.table_editing {
		er := doc.table_edit_row
		ec := doc.table_edit_col
		if er >= 0 && er < len(vis) && ec >= start_col {
			ex := TEXT_MARGIN_X
			for c := start_col; c < ec && c < len(colw); c += 1 {ex += f32(colw[c] + TABLE_COL_PAD) * char_w}
			if ex < right {
				cw := f32(colw[ec] + TABLE_COL_PAD) * char_w if ec < len(colw) else char_w
				box := [4]f32{0.20, 0.30, 0.45, 1}
				plat.quads_draw(gfx, qp, []plat.Quad{{pos = {ex - char_w * 0.5, row_rect_y(px, er)}, size = {min(cw, right - ex), lh}, color = box}})
				val := string(doc.table_edit_buf[:])
				plat.text_draw(gfx, text, val, ex, row_baseline_y(px, er), px, {1, 1, 1, 1}, .Doc)
				caret_cells := plat.text_cells(text, doc.table_edit_buf[:doc.table_edit_caret], .Doc)
				cxp := ex + f32(caret_cells) * char_w
				plat.quads_draw(gfx, qp, []plat.Quad{{pos = {cxp, row_rect_y(px, er)}, size = {max(sx(1), 1), lh}, color = {1, 1, 1, 1}}})
			}
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

// The cell under a client-space point, and its source byte range + unquoted
// value. Mirrors table_draw's layout (fixed column widths).
table_cell_at :: proc(doc: ^Document, mx, my, px, char_w: f32, rows: int, width: f32) -> (ok: bool, r, col, fs, fe: int, val: string) {
	colw := doc.table_widths
	if len(colw) == 0 {return}
	top := CONTENT_TOP + FILTER_BANNER_H
	if my < top {return}
	r = int((my - top) / line_height(px))
	if r < 0 || r >= rows {return}
	start_col := clamp(doc.table_col, 0, table_max_col(doc))
	right := width - SCROLLBAR_W
	col = -1
	cx := TEXT_MARGIN_X
	for c := start_col; c < len(colw); c += 1 {
		cw := f32(colw[c] + TABLE_COL_PAD) * char_w
		if mx >= cx && mx < cx + cw {col = c;break}
		cx += cw
		if cx >= right {break}
	}
	if col < 0 {return}
	delim := doc.table_delim if doc.table_delim != 0 else ','
	p := doc.top
	for _ in 0 ..< r {
		e := base.pt_line_end_cap(&doc.pt, p, RENDER_LINE_CAP)
		if e >= doc.pt.length {return} // no such row
		p = e + 1
	}
	if p > doc.pt.length {return}
	end := base.pt_line_end_cap(&doc.pt, p, RENDER_LINE_CAP)
	buf := make([]u8, end - p, context.temp_allocator)
	got := base.pt_read(&doc.pt, p, buf)
	ln := got
	if ln > 0 && buf[ln - 1] == '\r' {ln -= 1}
	line := string(buf[:ln])
	ranges := csv_field_ranges(line, delim)
	if col >= len(ranges) {return} // clicked past the last field on the row
	fs = p + ranges[col].s
	fe = p + ranges[col].e
	fields := csv_fields(line, delim)
	val = strings.clone(fields[col] if col < len(fields) else "", context.temp_allocator)
	ok = true
	return
}

// A cell by (visible row, column) rather than by point — for Tab stepping to
// the next cell. Returns the same source range + value as table_cell_at.
table_cell_at_index :: proc(doc: ^Document, r, col, rows: int) -> (ok: bool, rr, cc, fs, fe: int, val: string) {
	if r < 0 || r >= rows || col < 0 || col >= doc.table_cols {return}
	delim := doc.table_delim if doc.table_delim != 0 else ','
	p := doc.top
	for _ in 0 ..< r {
		e := base.pt_line_end_cap(&doc.pt, p, RENDER_LINE_CAP)
		if e >= doc.pt.length {return}
		p = e + 1
	}
	if p > doc.pt.length {return}
	end := base.pt_line_end_cap(&doc.pt, p, RENDER_LINE_CAP)
	buf := make([]u8, end - p, context.temp_allocator)
	got := base.pt_read(&doc.pt, p, buf)
	ln := got
	if ln > 0 && buf[ln - 1] == '\r' {ln -= 1}
	line := string(buf[:ln])
	ranges := csv_field_ranges(line, delim)
	if col >= len(ranges) {return}
	fs = p + ranges[col].s
	fe = p + ranges[col].e
	fields := csv_fields(line, delim)
	val = strings.clone(fields[col] if col < len(fields) else "", context.temp_allocator)
	rr, cc, ok = r, col, true
	return
}

table_edit_start :: proc(doc: ^Document, r, col, fs, fe: int, val: string) {
	doc.table_editing = true
	doc.table_edit_row = r
	doc.table_edit_col = col
	doc.table_edit_s = fs
	doc.table_edit_e = fe
	clear(&doc.table_edit_buf)
	append(&doc.table_edit_buf, ..transmute([]u8)val)
	doc.table_edit_caret = len(doc.table_edit_buf)
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
