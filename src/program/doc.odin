// Layer: program — a read-only document view. Holds the file bytes (mapped or
// copied), decoded to UTF-8, and a byte-offset viewport that walks lines on
// demand (no full index needed to render → instant on any size). A background
// line index for exact scrollbar/goto-line is a follow-up.
package main

import base "src:base"
import plat "src:platform"

Document :: struct {
	fv:      plat.File_View,
	content: []u8, // UTF-8
	owned:   bool, // content is a decoded copy we must free
	enc:     base.Encoding,
	top:     int, // byte offset of the top visible line (always a line start)
	path:    string,
}

doc_open :: proc(path: string) -> (doc: Document, ok: bool) {
	fv, fok := plat.file_open_readonly(path)
	if !fok {
		return
	}
	doc.fv = fv
	doc.path = path
	enc, bom := base.detect_encoding(fv.bytes)
	doc.enc = enc
	doc.content, doc.owned = base.decode_to_utf8(fv.bytes, enc, bom)
	return doc, true
}

doc_close :: proc(doc: ^Document) {
	if doc.owned {
		delete(doc.content)
	}
	plat.file_close(&doc.fv)
}

doc_scroll :: proc(doc: ^Document, delta: int) {
	if delta > 0 {
		for _ in 0 ..< delta {
			nt := base.next_line_start(doc.content, doc.top)
			if nt == doc.top {break} // at end
			doc.top = nt
		}
	} else if delta < 0 {
		for _ in 0 ..< -delta {
			pt := base.prev_line_start(doc.content, doc.top)
			if pt == doc.top {break} // at top
			doc.top = pt
		}
	}
}

// Draw the visible lines starting at doc.top. Reuses the ClearType text pipeline
// line by line. Long lines are clamped (horizontal scroll/wrap is separate).
doc_draw :: proc(gfx: ^plat.Gfx, t: ^plat.Text, doc: ^Document, px: f32, rows: int) {
	fg := [4]f32{0.86, 0.90, 0.96, 1}
	x: f32 = 12
	line_h := px * 1.5
	y := px + 10 // baseline of the first line

	pos := doc.top
	for _ in 0 ..< rows {
		if pos >= len(doc.content) {
			break
		}
		end := base.line_end(doc.content, pos)
		line := doc.content[pos:end]
		if len(line) > 0 && line[len(line) - 1] == '\r' {
			line = line[:len(line) - 1] // trim CR of a CRLF line
		}
		if len(line) > 2000 {
			line = line[:2000] // clamp pathological long lines for now
		}
		if len(line) > 0 {
			plat.text_draw(gfx, t, string(line), x, y, px, fg)
		}
		y += line_h
		pos = end + 1 if end < len(doc.content) else len(doc.content)
	}
}
