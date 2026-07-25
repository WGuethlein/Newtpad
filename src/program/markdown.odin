// Layer: program — a markdown renderer + preview, toggled per document (Ctrl+M
// cycles Off -> Preview -> Split). Like the table view, the underlying text is
// untouched; this lays the source out with headings, emphasis, code, lists,
// quotes, rules, links and simple tables. Bounded like every viewport pass:
// rendering walks source lines from a scroll offset and stops when the pane
// fills, so a huge markdown file previews without parsing all of it.
//
// Line-based, deliberately: a block is classified from its own prefix and its
// inline content is soft-wrapped to the pane. Consequences (v1): a paragraph's
// hard line breaks show as breaks (adjacent lines are not joined); there is no
// italic face loaded, so *italic* is shown as a tint, while **bold** is real via
// a double-draw; inline code is coloured, not boxed; tables are cell-split but
// not column-aligned across rows.
package main

import "core:fmt"
import "core:strings"
import base "src:base"
import plat "src:platform"

// Self-test for the pure parsing (block classifiers + inline runs); the rendering
// itself needs a live eye. Returns the failure count. Driven by `newtpad mdtest`.
md_selftest :: proc() -> (bad: int) {
	chk :: proc(bad: ^int, ok: bool, msg: string) {
		fmt.printfln("  %-40s %s", msg, "OK" if ok else "FAIL")
		if !ok {bad^ += 1}
	}
	chk(&bad, md_heading_level("# H") == 1, "# H -> h1")
	chk(&bad, md_heading_level("### H") == 3, "### H -> h3")
	chk(&bad, md_heading_level("####### H") == 0, "7 hashes -> not a heading")
	chk(&bad, md_heading_level("#nospace") == 0, "no space -> not a heading")
	chk(&bad, md_heading_level("plain") == 0, "plain -> not a heading")
	chk(&bad, md_is_rule("---"), "--- is a rule")
	chk(&bad, md_is_rule("***"), "*** is a rule")
	chk(&bad, !md_is_rule("- item"), "- item is not a rule")
	{
		q, c := md_quote("> hi there")
		chk(&bad, q && c == "hi there", "> hi -> quote 'hi there'")
	}
	{
		b, c, d := md_list("- item")
		chk(&bad, b == "•" && c == "item" && d == 0, "- item -> bullet depth 0")
	}
	{
		b, c, d := md_list("    - nested")
		chk(&bad, b == "•" && c == "nested" && d == 2, "4-space - nested -> depth 2")
	}
	{
		b, c, _ := md_list("3. third")
		chk(&bad, b == "3." && c == "third", "3. third -> ordered")
	}
	{
		runs := md_inline("a **b** c")
		ok := len(runs) == 3 && runs[0].text == "a " && runs[1].text == "b" && runs[1].bold && runs[2].text == " c"
		chk(&bad, ok, "a **b** c -> [a ][B:b][ c]")
	}
	{
		runs := md_inline("x `code` y")
		ok := len(runs) == 3 && runs[1].text == "code" && runs[1].code
		chk(&bad, ok, "x `code` y -> code run")
	}
	{
		runs := md_inline("see [label](http://u)")
		ok := len(runs) >= 2 && runs[len(runs) - 1].link && runs[len(runs) - 1].text == "label" && runs[len(runs) - 1].url == "http://u"
		chk(&bad, ok, "[label](url) -> link run")
	}
	return
}

Md_Mode :: enum u8 {
	Off,
	Preview, // full-window rendered view (read-only)
	Split, // editor left, live preview right
}

// Column widths depend on the whole table block, so measuring them from the
// visible rows only would make them a function of scroll position — columns that
// shift as you scroll. The measure is therefore hoisted out of the draw and
// cached per block, keyed on the buffer revision. Within a block the widths are
// constant by construction, which is what makes shift-free scrolling a property
// of the design rather than something to test for.
//
// A block is bounded by content (it ends at the first non-table line), so this
// is O(block), not O(file). Past MD_TABLE_BUDGET the block draws on fixed
// columns instead — deterministic per row, so still shift-free, just not
// content-sized. Content-sizing an arbitrarily large block would need a
// background worker; see the batch-1 spec for why that is deferred.
MD_TABLE_BUDGET :: 1 * 1024 * 1024
MD_TABLE_MAX_COLS :: 32
MD_TABLE_FIXED_CELLS :: 16 // fixed column width past the budget
MD_TABLE_PAD :: 2 // cells of gap between columns

Md_Align :: enum u8 {
	Left,
	Center,
	Right,
}

Md_Table_Cache :: struct {
	valid:    bool,
	start:    int, // byte offset of the block's first row
	end:      int, // just past the block's last row
	revision: u64,
	oversize: bool, // block exceeded MD_TABLE_BUDGET: fixed columns
	sep_at:   int, // byte offset of the separator row, or -1
	ncols:    int,
	widths:   [MD_TABLE_MAX_COLS]int, // cells, excluding padding
	align:    [MD_TABLE_MAX_COLS]Md_Align,
}

// A markdown table row, by the same test the renderer already used.
md_is_table_row :: proc(line: string) -> bool {
	return strings.contains(line, "|") && strings.count(line, "|") >= 2
}

// Split a row into cells, preserving empty ones. Strips at most one leading and
// one trailing pipe rather than trimming a character set from both ends — the
// old strings.trim(line, "| ") ate empty leading cells outright.
md_split_cells :: proc(line: string, allocator := context.temp_allocator) -> []string {
	s := strings.trim_right(line, " \t")
	if strings.has_prefix(s, "|") {s = s[1:]}
	if strings.has_suffix(s, "|") {s = s[:len(s) - 1]}
	parts := strings.split(s, "|", allocator)
	for &p in parts {p = strings.trim_space(p)}
	return parts
}

// Alignment markers on a separator cell: :--- / :--: / ---: / ---
@(private = "file")
md_cell_align :: proc(cell: string) -> Md_Align {
	c := strings.trim_space(cell)
	left := strings.has_prefix(c, ":")
	right := strings.has_suffix(c, ":")
	switch {
	case left && right:
		return .Center
	case right:
		return .Right
	}
	return .Left
}

// Read one line at `p` into `buf`, trailing CR removed. Returns the line and the
// offset of its end (at the newline, or the buffer end).
@(private = "file")
md_line_at :: proc(doc: ^Document, p: int, buf: []u8) -> (line: string, end: int) {
	end = base.pt_line_end_cap(&doc.pt, p, RENDER_LINE_CAP)
	n := base.pt_read(&doc.pt, p, buf[:min(end - p, len(buf))])
	if n > 0 && buf[n - 1] == '\r' {n -= 1}
	return string(buf[:n]), end
}

// The contiguous run of table rows containing `p`. Scans backward to the block's
// true start and forward to its end, both bounded by MD_TABLE_BUDGET so a file
// that is one enormous table cannot stall a frame.
@(private = "file")
md_table_bounds :: proc(doc: ^Document, p: int) -> (start, end: int, oversize, ok: bool) {
	buf: [RENDER_LINE_CAP]u8
	line, lend := md_line_at(doc, p, buf[:])
	if !md_is_table_row(line) {return 0, 0, false, false}
	start, end = p, lend

	// Backward.
	q := p
	for q > 0 {
		if start - q > MD_TABLE_BUDGET {oversize = true;break}
		ps := base.pt_line_start(&doc.pt, q - 1)
		pl, _ := md_line_at(doc, ps, buf[:])
		if !md_is_table_row(pl) {break}
		start = ps
		q = ps
	}

	// Forward.
	r := lend
	for r < doc.pt.length {
		if r - start > MD_TABLE_BUDGET {oversize = true;break}
		ns := r + 1
		if ns > doc.pt.length {break}
		nl, ne := md_line_at(doc, ns, buf[:])
		if !md_is_table_row(nl) {break}
		end = ne
		r = ne
	}
	return start, end, oversize, true
}

// Per-column maxima across the whole block, plus the separator row's alignments.
// Returns the populated cache; caller owns storage.
//
// Package-visible rather than file-private so the mdtabletest mode can drive the
// oversized path directly, without needing a >1 MB fixture to trip the budget.
md_table_measure :: proc(doc: ^Document, t: ^plat.Text, start, end: int, oversize: bool) -> Md_Table_Cache {
	c := Md_Table_Cache {
		valid    = true,
		start    = start,
		end      = end,
		revision = doc.revision,
		oversize = oversize,
		sep_at   = -1,
	}
	buf: [RENDER_LINE_CAP]u8
	for p := start; p <= end && p < doc.pt.length; {
		line, lend := md_line_at(doc, p, buf[:])
		if !md_is_table_row(line) {break}
		cells := md_split_cells(line, context.temp_allocator)
		if len(cells) > c.ncols {c.ncols = min(len(cells), MD_TABLE_MAX_COLS)}
		if md_is_table_sep(strings.trim_left(line, " \t")) {
			if c.sep_at < 0 {c.sep_at = p}
			for cell, i in cells {
				if i >= MD_TABLE_MAX_COLS {break}
				c.align[i] = md_cell_align(cell)
			}
		} else if !oversize {
			for cell, i in cells {
				if i >= MD_TABLE_MAX_COLS {break}
				w := plat.text_cells(t, transmute([]u8)cell, .Doc)
				if w > c.widths[i] {c.widths[i] = w}
			}
		}
		if lend >= doc.pt.length {break}
		p = lend + 1
	}
	// Past the budget every column is the same fixed width: it depends on nothing
	// outside the row being drawn, so it cannot shift with scroll either.
	if oversize {
		for i in 0 ..< max(c.ncols, 1) {c.widths[i] = MD_TABLE_FIXED_CELLS}
	}
	return c
}

// Cached measure for the block containing `p`, or nil if `p` is not a table row.
// The per-frame cost is the containment test; a scan happens only when the
// viewport enters a different block or the buffer changed.
md_table_ensure :: proc(doc: ^Document, t: ^plat.Text, p: int) -> ^Md_Table_Cache {
	c := &doc.md_table
	if c.valid && c.revision == doc.revision && p >= c.start && p < c.end {
		return c
	}
	start, end, oversize, ok := md_table_bounds(doc, p)
	if !ok {return nil}
	c^ = md_table_measure(doc, t, start, end, oversize)
	return c
}

// x offset of column `i`, in pixels from x0.
@(private = "file")
md_col_x :: proc(c: ^Md_Table_Cache, i: int, char_w: f32) -> f32 {
	cells := 0
	for k in 0 ..< min(i, c.ncols) {cells += c.widths[k] + MD_TABLE_PAD}
	return f32(cells) * char_w
}

// Colours.
@(private = "file")
MD_TEXT :: [4]f32{0.86, 0.90, 0.96, 1}
@(private = "file")
MD_HEAD :: [4]f32{0.72, 0.85, 1.0, 1}
@(private = "file")
MD_BOLD :: [4]f32{0.98, 0.99, 1.0, 1}
@(private = "file")
MD_ITALIC :: [4]f32{0.80, 0.86, 0.78, 1}
@(private = "file")
MD_CODE :: [4]f32{0.95, 0.80, 0.65, 1}
@(private = "file")
MD_QUOTE :: [4]f32{0.66, 0.72, 0.62, 1}
@(private = "file")
MD_MUTED :: [4]f32{0.55, 0.60, 0.70, 1}
@(private = "file")
MD_CODEBG :: [4]f32{0.12, 0.14, 0.18, 1}
@(private = "file")
MD_RULE :: [4]f32{0.30, 0.34, 0.42, 1}

// One styled run of a line's inline content.
@(private = "file")
Md_Run :: struct {
	text:            string,
	bold, ital, code, link: bool,
	url:             string,
}

// Heading pixel scale by level (1..6).
@(private = "file")
md_head_px :: proc(px: f32, level: int) -> f32 {
	switch level {
	case 1:
		return px * 1.7
	case 2:
		return px * 1.45
	case 3:
		return px * 1.25
	case 4:
		return px * 1.12
	case:
		return px * 1.03
	}
}

@(private = "file")
is_space :: proc(b: u8) -> bool {return b == ' ' || b == '\t'}

// Parse a line's inline content into styled runs. Small state machine: ** / __
// bold, * / _ italic, ` code, [text](url) links. Non-nested (a link's label is
// plain), which is enough for a preview.
@(private = "file")
md_inline :: proc(s: string, allocator := context.temp_allocator) -> []Md_Run {
	out := make([dynamic]Md_Run, 0, 8, allocator)
	bold, ital, code := false, false, false
	sb := strings.builder_make(allocator)
	flush := proc(out: ^[dynamic]Md_Run, sb: ^strings.Builder, bold, ital, code: bool) {
		if strings.builder_len(sb^) == 0 {return}
		append(out, Md_Run{text = strings.clone(strings.to_string(sb^), context.temp_allocator), bold = bold, ital = ital, code = code})
		strings.builder_reset(sb)
	}
	i, n := 0, len(s)
	for i < n {
		c := s[i]
		if code { // inside inline code: only ` ends it
			if c == '`' {
				flush(&out, &sb, false, false, true)
				code = false
				i += 1
			} else {
				strings.write_byte(&sb, c)
				i += 1
			}
			continue
		}
		switch {
		case c == '`':
			flush(&out, &sb, bold, ital, false)
			code = true
			i += 1
		case c == '*' && i + 1 < n && s[i + 1] == '*', c == '_' && i + 1 < n && s[i + 1] == '_':
			flush(&out, &sb, bold, ital, false)
			bold = !bold
			i += 2
		case c == '*' || c == '_':
			flush(&out, &sb, bold, ital, false)
			ital = !ital
			i += 1
		case c == '[':
			// [label](url)
			rb := strings.index_byte(s[i:], ']')
			if rb > 0 && i + rb + 1 < n && s[i + rb + 1] == '(' {
				us := i + rb + 2
				j := us
				for j < n && s[j] != ')' {j += 1}
				if j < n {
					flush(&out, &sb, bold, ital, false)
					append(&out, Md_Run{text = s[i + 1:i + rb], bold = bold, ital = ital, link = true, url = s[us:j]})
					i = j + 1
					continue
				}
			}
			strings.write_byte(&sb, c)
			i += 1
		case:
			strings.write_byte(&sb, c)
			i += 1
		}
	}
	flush(&out, &sb, bold, ital, code)
	return out[:]
}

// Draw inline runs word-wrapped from (x,y) within [xind, x1]; new rows indent to
// xind. Advances y per wrapped row. Synthetic bold via a second draw one px over.
@(private = "file")
md_draw_inline :: proc(gfx: ^plat.Gfx, text: ^plat.Text, runs: []Md_Run, xind, x1: f32, x, y: ^f32, px, char_w, line_h: f32, base_col: [4]f32) {
	boff := max(sx(1), 1)
	for run in runs {
		col := base_col
		if run.code {col = MD_CODE}
		if run.ital {col = MD_ITALIC}
		if run.link {col = LINK_COL}
		if run.bold && !run.code && !run.link {col = MD_BOLD}
		// Split into words, keeping each word's trailing space so wrapping is by word.
		w := run.text
		for len(w) > 0 {
			// take one word (up to and including trailing spaces)
			e := 0
			for e < len(w) && !is_space(w[e]) {e += 1}
			for e < len(w) && is_space(w[e]) {e += 1}
			word := w[:e]
			w = w[e:]
			ww := f32(plat.text_cells(text, transmute([]u8)word, .Doc)) * char_w
			if x^ + ww > x1 && x^ > xind { // wrap
				x^ = xind
				y^ += line_h
			}
			plat.text_draw(gfx, text, word, x^, y^, px, col, .Doc)
			if run.bold {plat.text_draw(gfx, text, word, x^ + boff, y^, px, col, .Doc)}
			x^ += ww
		}
	}
}

// Render markdown source from `top_byte`, laid out in [x0,x1] x [ytop,ybot].
// Returns the byte offset just past the last line drawn (for scroll clamping).
markdown_draw :: proc(gfx: ^plat.Gfx, qp: ^plat.Quad_Pipeline, text: ^plat.Text, doc: ^Document, px, char_w: f32, x0, x1, ytop, ybot: f32, top_byte: int) -> (bottom: int) {
	bottom = top_byte
	line_h := line_height(px)
	buf: [RENDER_LINE_CAP]u8
	y := ytop + px // first baseline
	p := top_byte
	in_fence := false
	for y < ybot && p <= doc.pt.length {
		end := base.pt_line_end_cap(&doc.pt, p, RENDER_LINE_CAP)
		n := base.pt_read(&doc.pt, p, buf[:min(end - p, len(buf))])
		if n > 0 && buf[n - 1] == '\r' {n -= 1}
		line := string(buf[:n])
		trimmed := strings.trim_left(line, " \t")

		if strings.has_prefix(trimmed, "```") || strings.has_prefix(trimmed, "~~~") {
			in_fence = !in_fence
			y += line_h
		} else if in_fence {
			plat.quads_draw(gfx, qp, []plat.Quad{{pos = {x0, y - px}, size = {x1 - x0, line_h}, color = MD_CODEBG}})
			plat.text_draw(gfx, text, line, x0 + char_w, y, px, MD_CODE, .Doc)
			y += line_h
		} else if len(strings.trim_space(line)) == 0 {
			y += line_h * 0.5 // blank line: a little gap
		} else if md_is_rule(trimmed) {
			plat.quads_draw(gfx, qp, []plat.Quad{{pos = {x0, y - px * 0.5}, size = {x1 - x0, max(sx(1), 1)}, color = MD_RULE}})
			y += line_h
		} else if lvl := md_heading_level(trimmed); lvl > 0 {
			hpx := md_head_px(px, lvl)
			hh := line_height(hpx)
			by := y + (hpx - px) // sink the larger baseline so it sits on the row
			x := x0
			yy := by
			runs := md_inline(strings.trim_left(trimmed[lvl:], " "))
			// force bold heading colour
			for &r in runs {r.bold = true}
			md_draw_inline(gfx, text, runs, x0, x1, &x, &yy, hpx, plat.text_char_width(text, hpx, .Doc), hh, MD_HEAD)
			y = yy + hh - px * 0.3
		} else if q, qcontent := md_quote(trimmed); q {
			plat.quads_draw(gfx, qp, []plat.Quad{{pos = {x0, y - px}, size = {max(sx(3), 2), line_h}, color = MD_QUOTE}})
			x := x0 + char_w * 2
			yy := y
			md_draw_inline(gfx, text, md_inline(qcontent), x0 + char_w * 2, x1, &x, &yy, px, char_w, line_h, MD_QUOTE)
			y = yy + line_h
		} else if bullet, content, depth := md_list(line); bullet != "" {
			ind := x0 + f32(depth) * char_w * 2
			plat.text_draw(gfx, text, bullet, ind, y, px, MD_MUTED, .Doc)
			x := ind + char_w * f32(len(bullet) + 1)
			yy := y
			md_draw_inline(gfx, text, md_inline(content), ind + char_w * 2, x1, &x, &yy, px, char_w, line_h, MD_TEXT)
			y = yy + line_h
		} else if md_is_table_row(line) {
			if c := md_table_ensure(doc, text, p); c != nil {
				md_draw_table_row(gfx, qp, text, c, line, x0, x1, y, px, char_w, md_is_table_sep(trimmed))
			}
			y += line_h
		} else {
			x := x0
			yy := y
			md_draw_inline(gfx, text, md_inline(line), x0, x1, &x, &yy, px, char_w, line_h, MD_TEXT)
			y = yy + line_h
		}

		bottom = end
		if end >= doc.pt.length {break}
		p = end + 1
	}
	return
}

@(private = "file")
md_heading_level :: proc(s: string) -> int {
	n := 0
	for n < len(s) && s[n] == '#' {n += 1}
	if n >= 1 && n <= 6 && n < len(s) && s[n] == ' ' {return n}
	return 0
}

@(private = "file")
md_is_rule :: proc(s: string) -> bool {
	t := strings.trim_space(s)
	if len(t) < 3 {return false}
	c := t[0]
	if c != '-' && c != '*' && c != '_' {return false}
	for i in 0 ..< len(t) {
		if t[i] != c && t[i] != ' ' {return false}
	}
	return true
}

@(private = "file")
md_quote :: proc(s: string) -> (bool, string) {
	if strings.has_prefix(s, ">") {
		return true, strings.trim_left(s[1:], " ")
	}
	return false, ""
}

// A list item: returns the bullet to draw ("•" or "1."), the content, and the
// nesting depth from the leading indent.
@(private = "file")
md_list :: proc(line: string) -> (bullet, content: string, depth: int) {
	i := 0
	for i < len(line) && (line[i] == ' ' || line[i] == '\t') {
		depth += 2 if line[i] == '\t' else 1
		i += 1
	}
	depth /= 2
	rest := line[i:]
	if len(rest) >= 2 && (rest[0] == '-' || rest[0] == '*' || rest[0] == '+') && rest[1] == ' ' {
		return "•", strings.trim_left(rest[2:], " "), depth
	}
	// ordered: digits then '.' or ')'
	j := 0
	for j < len(rest) && rest[j] >= '0' && rest[j] <= '9' {j += 1}
	if j > 0 && j + 1 < len(rest) && (rest[j] == '.' || rest[j] == ')') && rest[j + 1] == ' ' {
		return strings.clone(rest[:j + 1], context.temp_allocator), strings.trim_left(rest[j + 2:], " "), depth
	}
	return "", "", 0
}

@(private = "file")
md_is_table_sep :: proc(s: string) -> bool {
	for i in 0 ..< len(s) {
		switch s[i] {
		case '|', '-', ':', ' ', '\t':
		case:
			return false
		}
	}
	return strings.contains(s, "-")
}

// One row of a table, drawn at the block's cached column positions so every row
// lines up. `qp` is needed for the header rule under the separator row, which
// the old renderer skipped entirely.
@(private = "file")
md_draw_table_row :: proc(
	gfx: ^plat.Gfx,
	qp: ^plat.Quad_Pipeline,
	text: ^plat.Text,
	c: ^Md_Table_Cache,
	line: string,
	x0, x1, y, px, char_w: f32,
	is_sep: bool,
) {
	if is_sep {
		// The separator row becomes a rule, not text.
		w := min(md_col_x(c, c.ncols, char_w), x1 - x0)
		plat.quads_draw(gfx, qp, []plat.Quad{{pos = {x0, y - px * 0.5}, size = {w, max(sx(1), 1)}, color = MD_RULE}})
		return
	}
	cells := md_split_cells(line, context.temp_allocator)
	for cell, i in cells {
		if i >= c.ncols {break}
		cx := x0 + md_col_x(c, i, char_w)
		if cx >= x1 {break}
		if i > 0 {
			plat.text_draw(gfx, text, "│", cx - char_w, y, px, MD_MUTED, .Doc)
		}
		cw := plat.text_cells(text, transmute([]u8)cell, .Doc)
		pad := 0
		switch c.align[i] {
		case .Left:
		case .Center:
			pad = max(0, (c.widths[i] - cw) / 2)
		case .Right:
			pad = max(0, c.widths[i] - cw)
		}
		plat.text_draw(gfx, text, cell, cx + f32(pad) * char_w, y, px, MD_TEXT, .Doc)
	}
}
