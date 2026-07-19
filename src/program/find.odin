// Layer: program — incremental literal find (case-insensitive, ASCII-fold).
// Scans the piece table in overlapping chunks (no full materialization), so it
// stays low-memory; a background search for huge files is a follow-up.
package main

import "core:unicode/utf8"
import base "src:base"
import plat "src:platform"

MAX_MATCHES :: 100_000
FIND_CHUNK :: 1 << 16

@(private = "file")
lower :: proc(b: u8) -> u8 {return b + 32 if b >= 'A' && b <= 'Z' else b}

find_open :: proc(doc: ^Document) {
	doc.find.active = true
	if doc_has_sel(doc) { // seed with the current selection
		clear(&doc.find.query)
		lo, hi := doc_sel_range(doc)
		if hi - lo < 256 {
			buf := make([]u8, hi - lo, context.temp_allocator)
			base.pt_read(&doc.pt, lo, buf)
			append(&doc.find.query, ..buf)
		}
	}
	find_recompute(doc)
}

find_close :: proc(doc: ^Document) {doc.find.active = false}

find_input_rune :: proc(doc: ^Document, r: rune) {
	bytes, n := utf8.encode_rune(r)
	append(&doc.find.query, ..bytes[:n])
	find_recompute(doc)
}

find_backspace :: proc(doc: ^Document) {
	q := &doc.find.query
	if len(q) == 0 {
		return
	}
	i := len(q) - 1
	for i > 0 && (q[i] & 0xC0) == 0x80 {i -= 1} // whole rune
	resize(q, i)
	find_recompute(doc)
}

find_recompute :: proc(doc: ^Document) {
	f := &doc.find
	clear(&f.matches)
	f.current = -1
	q := f.query[:]
	if len(q) == 0 {
		return
	}
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
				if len(f.matches) >= MAX_MATCHES {
					pos = L
					break
				}
			}
		}
		pos += FIND_CHUNK
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
find_select_current :: proc(doc: ^Document) {
	f := &doc.find
	if f.current < 0 || f.current >= len(f.matches) {
		return
	}
	m := f.matches[f.current]
	doc.anchor = m // select the match so it highlights + the view scrolls to it
	doc.cursor = m + len(f.query)
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

// Highlight rectangles for visible matches (dim; behind text and the selection).
find_match_rects :: proc(doc: ^Document, px, char_w: f32, rows: int, out: []plat.Quad) -> int {
	f := &doc.find
	if !f.active || len(f.matches) == 0 || len(f.query) == 0 {
		return 0
	}
	qlen := len(f.query)
	x0: f32 = 12
	line_h := px * 1.5
	y0 := px + 10
	col := [4]f32{0.42, 0.38, 0.16, 1} // muted amber

	mi := 0
	for mi < len(f.matches) && f.matches[mi] < doc.top {mi += 1}

	pos, n := doc.top, 0
	for r in 0 ..< rows {
		if pos > doc.pt.length {break}
		end := base.pt_line_end(&doc.pt, pos)
		for mi < len(f.matches) && f.matches[mi] <= end && n < len(out) {
			m := f.matches[mi]
			sx := x0 + f32(m - pos) * char_w
			ex := x0 + f32(min(m + qlen, end) - pos) * char_w
			ry := y0 + f32(r) * line_h - px
			out[n] = {pos = {sx, ry}, size = {max(ex - sx, 2), line_h}, color = col}
			n += 1
			mi += 1
		}
		if end >= doc.pt.length {break}
		pos = end + 1
	}
	return n
}
