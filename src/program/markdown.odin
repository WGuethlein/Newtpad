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
		} else if strings.contains(line, "|") && strings.count(line, "|") >= 2 {
			// A basic table row: cells split on |, no cross-row alignment (v1).
			if !md_is_table_sep(trimmed) {
				md_draw_table_row(gfx, text, line, x0, x1, y, px, char_w)
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

@(private = "file")
md_draw_table_row :: proc(gfx: ^plat.Gfx, text: ^plat.Text, line: string, x0, x1, y, px, char_w: f32) {
	cells := strings.split(strings.trim(line, "| "), "|", context.temp_allocator)
	x := x0
	for cell, i in cells {
		if x >= x1 {break}
		if i > 0 {
			plat.text_draw(gfx, text, "│", x - char_w, y, px, MD_MUTED, .Doc)
		}
		c := strings.trim_space(cell)
		plat.text_draw(gfx, text, c, x, y, px, MD_TEXT, .Doc)
		x += f32(max(plat.text_cells(text, transmute([]u8)c, .Doc) + 3, 8)) * char_w
	}
}
