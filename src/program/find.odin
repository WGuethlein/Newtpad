// Layer: program — incremental find & replace. Literal (case-insensitive,
// ASCII-fold, chunked scan over the piece table) or regex (core:text/regex over
// a materialized snapshot). Replace reuses the doc's public edit path (undo +
// nl-delta handled). Group substitution ($1) and background search for huge
// files are follow-ups.
package main

import "core:text/regex"
import "core:unicode/utf8"
import base "src:base"
import plat "src:platform"

MAX_MATCHES :: 100_000
FIND_CHUNK :: 1 << 16

@(private = "file")
lower :: proc(b: u8) -> u8 {return b + 32 if b >= 'A' && b <= 'Z' else b}

find_open :: proc(doc: ^Document, replace_mode: bool) {
	doc.find.active = true
	doc.find.replace_mode = replace_mode
	doc.find.field = 0
	if doc_has_sel(doc) { // seed with the current selection
		lo, hi := doc_sel_range(doc)
		if hi - lo < 256 {
			clear(&doc.find.query)
			buf := make([]u8, hi - lo, context.temp_allocator)
			base.pt_read(&doc.pt, lo, buf)
			append(&doc.find.query, ..buf)
		}
	}
	find_recompute(doc)
}

find_close :: proc(doc: ^Document) {
	doc.find.active = false
	doc.filter = false
}
find_toggle_field :: proc(doc: ^Document) {doc.find.field = 1 - doc.find.field}
find_toggle_regex :: proc(doc: ^Document) {doc.find.regex = !doc.find.regex;find_recompute(doc)}

@(private = "file")
active_buf :: proc(doc: ^Document) -> ^[dynamic]u8 {
	return &doc.find.query if doc.find.field == 0 else &doc.find.replace
}

find_input_rune :: proc(doc: ^Document, r: rune) {
	bytes, n := utf8.encode_rune(r)
	append(active_buf(doc), ..bytes[:n])
	if doc.find.field == 0 {find_recompute(doc)}
}

find_backspace :: proc(doc: ^Document) {
	buf := active_buf(doc)
	if len(buf) == 0 {return}
	i := len(buf) - 1
	for i > 0 && (buf[i] & 0xC0) == 0x80 {i -= 1} // whole rune
	resize(buf, i)
	if doc.find.field == 0 {find_recompute(doc)}
}

find_recompute :: proc(doc: ^Document) {
	f := &doc.find
	clear(&f.matches)
	clear(&f.match_len)
	f.current = -1
	if len(f.query) == 0 {return}

	if f.regex {
		recompute_regex(doc)
	} else {
		recompute_literal(doc)
	}

	// Rebuild the filter-view line list: one entry per matching line (deduped).
	clear(&doc.filter_lines)
	last_end := -1
	for m in f.matches {
		if m < last_end {
			continue // same line as the previous match
		}
		append(&doc.filter_lines, base.pt_line_start(&doc.pt, m))
		last_end = base.pt_next_line_start(&doc.pt, m)
	}
	if doc.filter_top >= len(doc.filter_lines) {
		doc.filter_top = 0
	}

	if len(f.matches) > 0 {
		f.current = 0
		for m, i in f.matches { // first match at/after the caret
			if m >= doc.cursor {
				f.current = i
				break
			}
		}
		find_select_current(doc)
	}
}

@(private = "file")
recompute_literal :: proc(doc: ^Document) {
	f := &doc.find
	q := f.query[:]
	ql := make([]u8, len(q), context.temp_allocator)
	for i in 0 ..< len(q) {ql[i] = lower(q[i])}

	L := doc.pt.length
	buf := make([]u8, FIND_CHUNK + len(q) - 1, context.temp_allocator)
	pos := 0
	for pos < L {
		readlen := base.pt_read(&doc.pt, pos, buf[:min(len(buf), L - pos)])
		last := pos + FIND_CHUNK >= L
		scan_end := readlen - len(q) + 1
		limit := scan_end if last else min(FIND_CHUNK, scan_end)
		for k := 0; k < limit; k += 1 {
			hit := true
			for j in 0 ..< len(q) {
				if lower(buf[k + j]) != ql[j] {
					hit = false
					break
				}
			}
			if hit {
				append(&f.matches, pos + k)
				append(&f.match_len, len(q))
				if len(f.matches) >= MAX_MATCHES {
					return
				}
			}
		}
		pos += FIND_CHUNK
	}
}

@(private = "file")
recompute_regex :: proc(doc: ^Document) {
	f := &doc.find
	str := string(base.pt_collect(&doc.pt, context.temp_allocator))
	it, err := regex.create_iterator(str, string(f.query[:]), {.Case_Insensitive}, context.temp_allocator, context.temp_allocator)
	if err != nil {
		return // invalid pattern -> no matches
	}
	// iterator allocations are in the temp allocator; freed at frame end.
	for {
		cap, _, ok := regex.match_iterator(&it)
		if !ok || len(cap.pos) == 0 {
			break
		}
		s, e := cap.pos[0][0], cap.pos[0][1]
		append(&f.matches, s)
		append(&f.match_len, e - s)
		if len(f.matches) >= MAX_MATCHES {
			break
		}
	}
}

@(private = "file")
find_select_current :: proc(doc: ^Document) {
	f := &doc.find
	if f.current < 0 || f.current >= len(f.matches) {
		return
	}
	m := f.matches[f.current]
	doc.anchor = m // select the match: highlights it + scrolls it into view
	doc.cursor = m + f.match_len[f.current]
	if doc.filter { // keep the current match's line in the filtered view
		mls := base.pt_line_start(&doc.pt, m)
		for fl, i in doc.filter_lines {
			if fl == mls {
				doc.filter_top = i
				break
			}
		}
	}
}

find_next :: proc(doc: ^Document) {
	f := &doc.find
	if len(f.matches) == 0 {return}
	f.current = (f.current + 1) % len(f.matches)
	find_select_current(doc)
}

find_prev :: proc(doc: ^Document) {
	f := &doc.find
	if len(f.matches) == 0 {return}
	f.current = (f.current - 1 + len(f.matches)) % len(f.matches)
	find_select_current(doc)
}

// Replace the current match with the replace text, then re-find.
find_replace_current :: proc(doc: ^Document) {
	f := &doc.find
	if f.current < 0 || f.current >= len(f.matches) {
		return
	}
	m := f.matches[f.current]
	doc.anchor = m
	doc.cursor = m + f.match_len[f.current]
	doc_insert_text(doc, f.replace[:]) // deletes the selected match, inserts replacement (undo-aware)
	find_recompute(doc)
}

// Replace every match. Applied last->first so earlier offsets stay valid.
find_replace_all :: proc(doc: ^Document) {
	f := &doc.find
	for i := len(f.matches) - 1; i >= 0; i -= 1 {
		m := f.matches[i]
		doc.anchor = m
		doc.cursor = m + f.match_len[i]
		doc_insert_text(doc, f.replace[:])
	}
	find_recompute(doc)
}

// Highlight rectangles for visible matches (dim; behind text and the selection).
find_match_rects :: proc(doc: ^Document, t: ^plat.Text, px, char_w: f32, rows: int, out: []plat.Quad) -> int {
	f := &doc.find
	if !f.active || len(f.matches) == 0 {
		return 0
	}
	col := [4]f32{0.42, 0.38, 0.16, 1} // muted amber
	lh := line_height(px)

	mi := 0
	for mi < len(f.matches) && f.matches[mi] < doc.top {mi += 1}

	it := visible_begin(doc, rows)
	n := 0
	for n < len(out) {
		row, start, end, ok := visible_next(&it)
		if !ok {break}
		ry := row_rect_y(px, row)
		for mi < len(f.matches) && f.matches[mi] <= end && n < len(out) {
			m := f.matches[mi]
			startcol := min(line_cell_col(doc, t, start, max(m, start)), VISIBLE_COLS)
			endcol := min(line_cell_col(doc, t, start, min(m + f.match_len[mi], end)), VISIBLE_COLS)
			sx := col_x(char_w, startcol)
			ex := col_x(char_w, endcol)
			out[n] = {pos = {sx, ry}, size = {max(ex - sx, 2), lh}, color = col}
			n += 1
			mi += 1
		}
	}
	return n
}
