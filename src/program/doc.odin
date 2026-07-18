// Layer: program — an editable document: a piece-table buffer over the file's
// (immutable) original bytes, a caret, undo/redo via piece snapshots, and a
// background line index over the original for the scrollbar. The viewport reads
// through the piece table on demand, so it stays instant regardless of size.
// Save is a separate milestone; edits live in memory.
package main

import "base:intrinsics"
import "core:thread"
import "core:unicode/utf8"
import base "src:base"
import plat "src:platform"

ANCHOR_STRIDE :: 1024

// Background index over the immutable original bytes (no race with edits, which
// only touch the piece table's add arena). Line count during editing is this
// plus nl_delta (net newlines inserted/deleted).
Line_Index :: struct {
	content:      []u8,
	anchors:      []int,
	anchor_count: int, // atomic
	line_count:   int, // atomic
	indexed:      int, // atomic
	total:        int,
	done:         bool, // atomic
	cancel:       bool, // atomic
	th:           ^thread.Thread,
}

Snapshot :: struct {
	pieces:   []base.Piece,
	length:   int,
	cursor:   int,
	nl_delta: int,
}

Document :: struct {
	fv:         plat.File_View,
	original:   []u8,
	owned_orig: bool,
	enc:        base.Encoding,
	pt:         base.Piece_Table,
	top:        int, // byte offset of the top visible line
	cursor:     int, // caret byte offset
	modified:   bool,
	nl_delta:   int,
	undo:       [dynamic]Snapshot,
	redo:       [dynamic]Snapshot,
	idx:        Line_Index,
}

doc_open :: proc(path: string) -> (doc: Document, ok: bool) {
	fv, fok := plat.file_open_readonly(path)
	if !fok {
		return
	}
	doc.fv = fv
	enc, bom := base.detect_encoding(fv.bytes)
	doc.enc = enc
	doc.original, doc.owned_orig = base.decode_to_utf8(fv.bytes, enc, bom)
	doc.pt = base.pt_init(doc.original)

	doc.idx.content = doc.original
	doc.idx.total = len(doc.original)
	doc.idx.anchors = make([]int, len(doc.original) / (8 * ANCHOR_STRIDE) + 16)
	doc.idx.anchor_count = 1
	return doc, true
}

doc_index_start :: proc(doc: ^Document) {
	doc.idx.th = thread.create_and_start_with_data(&doc.idx, index_worker)
}

doc_close :: proc(doc: ^Document) {
	if doc.idx.th != nil {
		intrinsics.atomic_store(&doc.idx.cancel, true)
		thread.join(doc.idx.th)
		thread.destroy(doc.idx.th)
	}
	delete(doc.idx.anchors)
	for s in doc.undo {delete(s.pieces)}
	for s in doc.redo {delete(s.pieces)}
	delete(doc.undo)
	delete(doc.redo)
	base.pt_destroy(&doc.pt)
	if doc.owned_orig {
		delete(doc.original)
	}
	plat.file_close(&doc.fv)
}

@(private = "file")
index_worker :: proc(data: rawptr) {
	idx := (^Line_Index)(data)
	c := idx.content
	line, i := 0, 0
	for i < len(c) {
		if i & 0xFFFFF == 0 {
			if intrinsics.atomic_load(&idx.cancel) {return}
			intrinsics.atomic_store(&idx.indexed, i)
			intrinsics.atomic_store(&idx.line_count, line + 1)
		}
		if c[i] == '\n' {
			line += 1
			if line % ANCHOR_STRIDE == 0 {
				ai := line / ANCHOR_STRIDE
				if ai < len(idx.anchors) {
					idx.anchors[ai] = i + 1
					intrinsics.atomic_store(&idx.anchor_count, ai + 1)
				}
			}
		}
		i += 1
	}
	intrinsics.atomic_store(&idx.line_count, line + 1)
	intrinsics.atomic_store(&idx.indexed, len(c))
	intrinsics.atomic_store(&idx.done, true)
}

// Materialize the buffer as a string (debug/test only; leaks).
doc_debug_string :: proc(doc: ^Document) -> string {return string(base.pt_collect(&doc.pt))}

doc_line_count :: proc(doc: ^Document) -> int {return intrinsics.atomic_load(&doc.idx.line_count) + doc.nl_delta}
doc_index_done :: proc(doc: ^Document) -> bool {return intrinsics.atomic_load(&doc.idx.done)}
doc_index_progress :: proc(doc: ^Document) -> f32 {
	if doc.idx.total == 0 {return 1}
	return f32(intrinsics.atomic_load(&doc.idx.indexed)) / f32(doc.idx.total)
}

// --- small buffer helpers ---

@(private = "file")
byte_at :: proc(doc: ^Document, i: int) -> u8 {
	one: [1]u8
	base.pt_read(&doc.pt, i, one[:])
	return one[0]
}

@(private = "file")
rune_size_lead :: proc(b: u8) -> int {
	switch {
	case b < 0x80:
		return 1
	case b < 0xE0:
		return 2
	case b < 0xF0:
		return 3
	case:
		return 4
	}
}

@(private = "file")
prev_rune :: proc(doc: ^Document, pos: int) -> int {
	if pos <= 0 {return 0}
	p := pos - 1
	for p > 0 && (byte_at(doc, p) & 0xC0) == 0x80 {p -= 1} // skip UTF-8 continuation bytes
	return p
}

@(private = "file")
next_rune :: proc(doc: ^Document, pos: int) -> int {
	if pos >= doc.pt.length {return doc.pt.length}
	return min(pos + rune_size_lead(byte_at(doc, pos)), doc.pt.length)
}

@(private = "file")
count_newlines :: proc(doc: ^Document, pos, count: int) -> (c: int) {
	buf: [4096]u8
	p, remaining := pos, count
	for remaining > 0 {
		n := base.pt_read(&doc.pt, p, buf[:min(len(buf), remaining)])
		if n == 0 {break}
		for k in 0 ..< n {if buf[k] == '\n' {c += 1}}
		p += n
		remaining -= n
	}
	return
}

// --- undo/redo ---

@(private = "file")
snapshot :: proc(doc: ^Document) -> Snapshot {
	pc := make([]base.Piece, len(doc.pt.pieces))
	copy(pc, doc.pt.pieces[:])
	return {pc, doc.pt.length, doc.cursor, doc.nl_delta}
}

@(private = "file")
restore :: proc(doc: ^Document, s: Snapshot) {
	clear(&doc.pt.pieces)
	append(&doc.pt.pieces, ..s.pieces)
	doc.pt.length = s.length
	doc.cursor = s.cursor
	doc.nl_delta = s.nl_delta
}

@(private = "file")
push_undo :: proc(doc: ^Document) {
	append(&doc.undo, snapshot(doc))
	for s in doc.redo {delete(s.pieces)}
	clear(&doc.redo)
	doc.modified = true
}

doc_undo :: proc(doc: ^Document) {
	if len(doc.undo) == 0 {return}
	append(&doc.redo, snapshot(doc))
	s := pop(&doc.undo)
	restore(doc, s)
	delete(s.pieces)
}

doc_redo :: proc(doc: ^Document) {
	if len(doc.redo) == 0 {return}
	append(&doc.undo, snapshot(doc))
	s := pop(&doc.redo)
	restore(doc, s)
	delete(s.pieces)
}

// --- edits ---

doc_insert_text :: proc(doc: ^Document, text: []u8) {
	if len(text) == 0 {return}
	push_undo(doc)
	base.pt_insert(&doc.pt, doc.cursor, text)
	for b in text {if b == '\n' {doc.nl_delta += 1}}
	doc.cursor += len(text)
}

doc_insert_rune :: proc(doc: ^Document, r: rune) {
	bytes, n := utf8.encode_rune(r)
	doc_insert_text(doc, bytes[:n])
}

doc_backspace :: proc(doc: ^Document) {
	if doc.cursor <= 0 {return}
	push_undo(doc)
	p := prev_rune(doc, doc.cursor)
	doc.nl_delta -= count_newlines(doc, p, doc.cursor - p)
	base.pt_delete(&doc.pt, p, doc.cursor - p)
	doc.cursor = p
}

doc_delete_fwd :: proc(doc: ^Document) {
	if doc.cursor >= doc.pt.length {return}
	push_undo(doc)
	n := next_rune(doc, doc.cursor) - doc.cursor
	doc.nl_delta -= count_newlines(doc, doc.cursor, n)
	base.pt_delete(&doc.pt, doc.cursor, n)
}

// --- cursor movement ---

doc_cursor_left :: proc(doc: ^Document) {doc.cursor = prev_rune(doc, doc.cursor)}
doc_cursor_right :: proc(doc: ^Document) {doc.cursor = next_rune(doc, doc.cursor)}
doc_cursor_home :: proc(doc: ^Document) {doc.cursor = base.pt_line_start(&doc.pt, doc.cursor)}
doc_cursor_end :: proc(doc: ^Document) {doc.cursor = base.pt_line_end(&doc.pt, doc.cursor)}

doc_cursor_up :: proc(doc: ^Document) {
	ls := base.pt_line_start(&doc.pt, doc.cursor)
	if ls == 0 {return}
	col := doc.cursor - ls
	prev := base.pt_prev_line_start(&doc.pt, doc.cursor)
	doc.cursor = min(prev + col, base.pt_line_end(&doc.pt, prev))
}

doc_cursor_down :: proc(doc: ^Document) {
	ls := base.pt_line_start(&doc.pt, doc.cursor)
	col := doc.cursor - ls
	nl := base.pt_next_line_start(&doc.pt, doc.cursor)
	if nl == doc.pt.length && base.pt_line_end(&doc.pt, nl) == nl && ls == base.pt_line_start(&doc.pt, nl) {
		return // already on the last line
	}
	doc.cursor = min(nl + col, base.pt_line_end(&doc.pt, nl))
}

// --- viewport ---

doc_scroll :: proc(doc: ^Document, delta: int) {
	if delta > 0 {
		for _ in 0 ..< delta {
			nt := base.pt_next_line_start(&doc.pt, doc.top)
			if nt == doc.top {break}
			doc.top = nt
		}
	} else if delta < 0 {
		for _ in 0 ..< -delta {
			if doc.top == 0 {break}
			doc.top = base.pt_prev_line_start(&doc.pt, doc.top)
		}
	}
}

// Keep the caret on screen: scroll so cursor's line is within [top, top+rows).
doc_ensure_cursor_visible :: proc(doc: ^Document, rows: int) {
	cls := base.pt_line_start(&doc.pt, doc.cursor)
	if cls < doc.top {
		doc.top = cls
		return
	}
	// walk `rows` lines from top; if we pass cursor's line, it's visible
	p := doc.top
	for _ in 0 ..< rows {
		if p >= cls {return} // cursor line at/above bottom edge -> visible
		p = base.pt_next_line_start(&doc.pt, p)
	}
	// cursor is below the viewport: put its line at the bottom row
	doc.top = cls
	doc_scroll(doc, -(rows - 1))
}

// Draw visible lines; return the caret's screen rect (if visible) and the byte
// offset just past the last visible line (for the scrollbar).
doc_draw :: proc(gfx: ^plat.Gfx, t: ^plat.Text, doc: ^Document, px, char_w: f32, rows: int) -> (cx, cy: f32, caret: bool, bottom: int) {
	fg := [4]f32{0.86, 0.90, 0.96, 1}
	x0: f32 = 12
	line_h := px * 1.5
	y0 := px + 10

	line_buf: [2048]u8
	pos := doc.top
	bottom = doc.top
	for r in 0 ..< rows {
		if pos > doc.pt.length {break}
		end := base.pt_line_end(&doc.pt, pos)
		bottom = end
		row_y := y0 + f32(r) * line_h

		draw_len := min(end - pos, len(line_buf))
		n := base.pt_read(&doc.pt, pos, line_buf[:draw_len])
		vis := n
		if vis > 0 && line_buf[vis - 1] == '\r' {vis -= 1}
		if vis > 0 {
			plat.text_draw(gfx, t, string(line_buf[:vis]), x0, row_y, px, fg)
		}

		if doc.cursor >= pos && doc.cursor <= end {
			cx = x0 + f32(doc.cursor - pos) * char_w
			cy = row_y
			caret = true
		}
		if end >= doc.pt.length {break}
		pos = end + 1
	}
	return
}
