// Layer: program — an editable document: a piece-table buffer over the file's
// (immutable) original bytes, a caret, undo/redo via piece snapshots, and a
// background line index over the original for the scrollbar. The viewport reads
// through the piece table on demand, so it stays instant regardless of size.
// Save is a separate milestone; edits live in memory.
package main

import "base:intrinsics"
import "core:strings"
import "core:thread"
import "core:unicode/utf8"
import base "src:base"
import plat "src:platform"

// Max bytes scanned per visible line for its end (bounds per-frame work).
RENDER_LINE_CAP :: 8192

// Background job that counts total lines over the immutable original bytes (no
// race with edits, which only touch the add arena). The status bar shows this
// plus nl_delta (net newlines from edits). Published via atomics.
Line_Index :: struct {
	content:    []u8,
	line_count: int, // atomic
	indexed:    int, // atomic (bytes scanned, for progress)
	total:      int,
	done:       bool, // atomic
	cancel:     bool, // atomic
	th:         ^thread.Thread,
}

Snapshot :: struct {
	root:     ^base.Node, // cloned piece tree
	length:   int,
	cursor:   int,
	anchor:   int,
	nl_delta: int,
}

Document :: struct {
	fv:         plat.File_View,
	original:   []u8,
	owned_orig: bool,
	enc:        base.Encoding,
	pt:         base.Piece_Table,
	path:       string, // "" for an unnamed scratch buffer
	path_owned: bool, // doc.path is heap-owned (freed on close/re-save)
	had_bom:    bool, // whether the file opened with a BOM (preserved on save)
	top:        int, // byte offset of the top visible line
	cursor:     int, // caret byte offset
	anchor:     int, // other end of the selection (== cursor when none)
	modified:   bool,
	nl_delta:   int,
	undo:       [dynamic]Snapshot,
	redo:       [dynamic]Snapshot,
	idx:        Line_Index,
	find:       Find,
	// filter-to-matching-lines view (only while find is active)
	filter:       bool,
	filter_lines: [dynamic]int, // deduped matching-line starts
	filter_top:   int, // index into filter_lines
}

// Incremental find/replace state (see find.odin).
Find :: struct {
	active:       bool,
	replace_mode: bool, // Ctrl+H shows the replace field
	field:        int, // 0 = query field, 1 = replace field (Tab toggles)
	regex:        bool, // regex vs literal substring
	query:        [dynamic]u8, // UTF-8
	replace:      [dynamic]u8,
	matches:      [dynamic]int, // sorted match start offsets
	match_len:    [dynamic]int, // length of each match (regex matches vary)
	current:      int, // index into matches, or -1
}

// A new empty scratch document (no file). This is what opens when Newtpad is
// launched with no argument — never fail to a closed window.
doc_new :: proc() -> (doc: Document) {
	doc.enc = .UTF8
	doc.pt = base.pt_init(nil)
	return
}

doc_open :: proc(path: string) -> (doc: Document, ok: bool) {
	fv, fok := plat.file_open_readonly(path)
	if !fok {
		return
	}
	doc.fv = fv
	doc.path = strings.clone(path)
	doc.path_owned = true
	enc, bom := base.detect_encoding(fv.bytes)
	doc.enc = enc
	doc.had_bom = bom > 0
	doc.original, doc.owned_orig = base.decode_to_utf8(fv.bytes, enc, bom)
	doc.pt = base.pt_init(doc.original)

	doc.idx.content = doc.original
	doc.idx.total = len(doc.original)
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
	for s in doc.undo {base.pt_free_node_tree(s.root)}
	for s in doc.redo {base.pt_free_node_tree(s.root)}
	delete(doc.undo)
	delete(doc.redo)
	delete(doc.find.query)
	delete(doc.find.replace)
	delete(doc.find.matches)
	delete(doc.find.match_len)
	delete(doc.filter_lines)
	base.pt_destroy(&doc.pt)
	if doc.owned_orig {
		delete(doc.original)
	}
	if doc.path_owned {
		delete(doc.path)
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
		}
		i += 1
	}
	intrinsics.atomic_store(&idx.line_count, line + 1)
	intrinsics.atomic_store(&idx.indexed, len(c))
	intrinsics.atomic_store(&idx.done, true)
}

// Save the buffer to `path`, re-encoded to the file's original encoding
// (UTF-16 files round-trip; UTF-8 keeps/omits its BOM as opened). Atomic write.
doc_save :: proc(doc: ^Document, path: string) -> bool {
	body := base.pt_collect(&doc.pt, context.temp_allocator) // internal UTF-8
	out := base.encode_from_utf8(body, doc.enc, doc.had_bom, context.temp_allocator)
	if !plat.file_write_atomic(path, out) {
		return false
	}
	newpath := strings.clone(path) // clone first: path may alias doc.path (re-save)
	if doc.path_owned {
		delete(doc.path)
	}
	doc.path = newpath
	doc.path_owned = true
	doc.modified = false
	return true
}

// Materialize the buffer as a string (debug/test only; leaks).
doc_debug_string :: proc(doc: ^Document) -> string {return string(base.pt_collect(&doc.pt))}

// The text of the line starting at `start` (no trailing newline).
doc_line_text :: proc(doc: ^Document, start: int, allocator := context.allocator) -> string {
	end := base.pt_line_end(&doc.pt, start)
	buf := make([]u8, end - start, allocator)
	base.pt_read(&doc.pt, start, buf)
	return string(buf)
}

doc_line_count :: proc(doc: ^Document) -> int {
	lc := intrinsics.atomic_load(&doc.idx.line_count)
	// nl_delta is only meaningful once the base count over the original is done.
	return lc + doc.nl_delta if intrinsics.atomic_load(&doc.idx.done) else lc
}
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
	return {base.pt_snapshot(&doc.pt), doc.pt.length, doc.cursor, doc.anchor, doc.nl_delta}
}

@(private = "file")
apply_snapshot :: proc(doc: ^Document, s: Snapshot) {
	base.pt_restore(&doc.pt, s.root, s.length) // takes ownership of s.root
	doc.cursor = s.cursor
	doc.anchor = s.anchor
	doc.nl_delta = s.nl_delta
}

@(private = "file")
push_undo :: proc(doc: ^Document) {
	append(&doc.undo, snapshot(doc))
	for s in doc.redo {base.pt_free_node_tree(s.root)}
	clear(&doc.redo)
	doc.modified = true
}

doc_undo :: proc(doc: ^Document) {
	if len(doc.undo) == 0 {return}
	append(&doc.redo, snapshot(doc)) // clone current for redo
	s := pop(&doc.undo)
	apply_snapshot(doc, s) // s.root becomes the live tree
}

doc_redo :: proc(doc: ^Document) {
	if len(doc.redo) == 0 {return}
	append(&doc.undo, snapshot(doc))
	s := pop(&doc.redo)
	apply_snapshot(doc, s)
}

// --- selection ---
// Selection is [min(anchor,cursor), max(anchor,cursor)); active when anchor != cursor.

doc_sel_range :: proc(doc: ^Document) -> (lo, hi: int) {
	if doc.anchor <= doc.cursor {
		return doc.anchor, doc.cursor
	}
	return doc.cursor, doc.anchor
}

doc_has_sel :: proc(doc: ^Document) -> bool {return doc.anchor != doc.cursor}

@(private = "file")
set_cursor :: proc(doc: ^Document, pos: int, select: bool) {
	doc.cursor = pos
	if !select {
		doc.anchor = pos
	}
}

@(private = "file")
del_sel_raw :: proc(doc: ^Document) {
	lo, hi := doc_sel_range(doc)
	doc.nl_delta -= count_newlines(doc, lo, hi - lo)
	base.pt_delete(&doc.pt, lo, hi - lo)
	doc.cursor = lo
	doc.anchor = lo
}

// Selected text as a freshly-allocated UTF-8 string (empty if no selection).
doc_selected_text :: proc(doc: ^Document, allocator := context.allocator) -> string {
	lo, hi := doc_sel_range(doc)
	if lo == hi {
		return ""
	}
	buf := make([]u8, hi - lo, allocator)
	base.pt_read(&doc.pt, lo, buf)
	return string(buf)
}

// --- edits (an active selection is replaced/deleted first, as one undo step) ---

doc_insert_text :: proc(doc: ^Document, text: []u8) {
	if len(text) == 0 {return}
	push_undo(doc)
	if doc_has_sel(doc) {del_sel_raw(doc)}
	base.pt_insert(&doc.pt, doc.cursor, text)
	for b in text {if b == '\n' {doc.nl_delta += 1}}
	doc.cursor += len(text)
	doc.anchor = doc.cursor
}

doc_insert_rune :: proc(doc: ^Document, r: rune) {
	bytes, n := utf8.encode_rune(r)
	doc_insert_text(doc, bytes[:n])
}

doc_backspace :: proc(doc: ^Document) {
	if doc_has_sel(doc) {
		push_undo(doc)
		del_sel_raw(doc)
		return
	}
	if doc.cursor <= 0 {return}
	push_undo(doc)
	p := prev_rune(doc, doc.cursor)
	doc.nl_delta -= count_newlines(doc, p, doc.cursor - p)
	base.pt_delete(&doc.pt, p, doc.cursor - p)
	set_cursor(doc, p, false)
}

doc_delete_fwd :: proc(doc: ^Document) {
	if doc_has_sel(doc) {
		push_undo(doc)
		del_sel_raw(doc)
		return
	}
	if doc.cursor >= doc.pt.length {return}
	push_undo(doc)
	n := next_rune(doc, doc.cursor) - doc.cursor
	doc.nl_delta -= count_newlines(doc, doc.cursor, n)
	base.pt_delete(&doc.pt, doc.cursor, n)
	doc.anchor = doc.cursor
}

// --- cursor movement (select=true extends the selection) ---

doc_cursor_left :: proc(doc: ^Document, select: bool) {
	if !select && doc_has_sel(doc) {
		lo, _ := doc_sel_range(doc)
		set_cursor(doc, lo, false) // collapse to selection start
		return
	}
	set_cursor(doc, prev_rune(doc, doc.cursor), select)
}

doc_cursor_right :: proc(doc: ^Document, select: bool) {
	if !select && doc_has_sel(doc) {
		_, hi := doc_sel_range(doc)
		set_cursor(doc, hi, false) // collapse to selection end
		return
	}
	set_cursor(doc, next_rune(doc, doc.cursor), select)
}

doc_cursor_home :: proc(doc: ^Document, select: bool) {set_cursor(doc, base.pt_line_start(&doc.pt, doc.cursor), select)}
doc_cursor_end :: proc(doc: ^Document, select: bool) {set_cursor(doc, base.pt_line_end(&doc.pt, doc.cursor), select)}

doc_cursor_up :: proc(doc: ^Document, select: bool) {
	ls := base.pt_line_start(&doc.pt, doc.cursor)
	if ls == 0 {
		set_cursor(doc, 0, select)
		return
	}
	col := doc.cursor - ls
	prev := base.pt_prev_line_start(&doc.pt, doc.cursor)
	set_cursor(doc, min(prev + col, base.pt_line_end(&doc.pt, prev)), select)
}

doc_cursor_down :: proc(doc: ^Document, select: bool) {
	ls := base.pt_line_start(&doc.pt, doc.cursor)
	col := doc.cursor - ls
	nl := base.pt_next_line_start(&doc.pt, doc.cursor)
	if nl == doc.pt.length && base.pt_line_end(&doc.pt, nl) == nl && ls == base.pt_line_start(&doc.pt, nl) {
		return
	}
	set_cursor(doc, min(nl + col, base.pt_line_end(&doc.pt, nl)), select)
}

// --- word boundaries, word nav, click selection, hit-test ---

@(private = "file")
is_word :: proc(b: u8) -> bool {
	return(b >= '0' && b <= '9') || (b >= 'A' && b <= 'Z') || (b >= 'a' && b <= 'z') || b == '_' || b >= 0x80
}

@(private = "file")
word_left_of :: proc(doc: ^Document, pos: int) -> int {
	p := pos
	for p > 0 && !is_word(byte_at(doc, p - 1)) {p -= 1}
	for p > 0 && is_word(byte_at(doc, p - 1)) {p -= 1}
	return p
}

@(private = "file")
word_right_of :: proc(doc: ^Document, pos: int) -> int {
	L := doc.pt.length
	p := pos
	for p < L && !is_word(byte_at(doc, p)) {p += 1}
	for p < L && is_word(byte_at(doc, p)) {p += 1}
	return p
}

doc_word_left :: proc(doc: ^Document, select: bool) {set_cursor(doc, word_left_of(doc, doc.cursor), select)}
doc_word_right :: proc(doc: ^Document, select: bool) {set_cursor(doc, word_right_of(doc, doc.cursor), select)}

doc_delete_word_back :: proc(doc: ^Document) {
	if doc_has_sel(doc) {
		doc_backspace(doc)
		return
	}
	p := word_left_of(doc, doc.cursor)
	if p == doc.cursor {return}
	push_undo(doc)
	doc.nl_delta -= count_newlines(doc, p, doc.cursor - p)
	base.pt_delete(&doc.pt, p, doc.cursor - p)
	set_cursor(doc, p, false)
}

doc_select_all :: proc(doc: ^Document) {
	doc.anchor = 0
	doc.cursor = doc.pt.length
}

doc_select_word_at :: proc(doc: ^Document, pos: int) {
	L := doc.pt.length
	if pos < L && is_word(byte_at(doc, pos)) {
		s, e := pos, pos
		for s > 0 && is_word(byte_at(doc, s - 1)) {s -= 1}
		for e < L && is_word(byte_at(doc, e)) {e += 1}
		doc.anchor, doc.cursor = s, e
	} else {
		doc.anchor = pos
		doc.cursor = next_rune(doc, pos)
	}
}

doc_select_line_at :: proc(doc: ^Document, pos: int) {
	doc.anchor = base.pt_line_start(&doc.pt, pos)
	doc.cursor = base.pt_next_line_start(&doc.pt, pos) // include the newline
}

// Byte offset under a client-space pixel (monospace column mapping).
doc_pos_at :: proc(doc: ^Document, mx, my: i32, px, char_w: f32, rows: int) -> int {
	line_h := px * 1.5
	row := int((f32(my) - 10) / line_h) // rows start at y=10 (see doc_draw)
	row = clamp(row, 0, rows - 1)
	pos := doc.top
	for _ in 0 ..< row {
		nt := base.pt_next_line_start(&doc.pt, pos)
		if nt == pos {break}
		pos = nt
	}
	end := base.pt_line_end(&doc.pt, pos)
	col := int((f32(mx) - 12) / char_w + 0.5)
	if col < 0 {col = 0}
	return min(pos + col, end)
}

// Selection highlight rectangles for the visible lines (opaque; drawn behind
// text). Fills `out`, returns the count.
doc_selection_rects :: proc(doc: ^Document, px, char_w: f32, rows: int, out: []plat.Quad) -> int {
	lo, hi := doc_sel_range(doc)
	if lo == hi {return 0}
	x0: f32 = 12
	line_h := px * 1.5
	y0 := px + 10
	col := [4]f32{0.20, 0.30, 0.48, 1}

	pos, n := doc.top, 0
	for r in 0 ..< rows {
		if pos > doc.pt.length {break}
		end := base.pt_line_end(&doc.pt, pos)
		if lo <= end && hi > pos && n < len(out) { // selection overlaps [pos, end]
			startcol := max(pos, lo) - pos
			endcol := min(end, hi) - pos
			sx := x0 + f32(startcol) * char_w
			ex := x0 + f32(endcol) * char_w
			if hi > end {ex += char_w * 0.4} // selection continues past EOL: show the newline
			ry := y0 + f32(r) * line_h - px
			out[n] = {pos = {sx, ry}, size = {max(ex - sx, 2), line_h}, color = col}
			n += 1
		}
		if end >= doc.pt.length {break}
		pos = end + 1
	}
	return n
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
	pos := doc.top // consecutive-line cursor (non-filter mode)
	bottom = doc.top
	for r in 0 ..< rows {
		start: int
		if doc.filter {
			fi := doc.filter_top + r
			if fi >= len(doc.filter_lines) {break}
			start = doc.filter_lines[fi]
		} else {
			if pos > doc.pt.length {break}
			start = pos
		}
		// Capped so a multi-GB single-line file doesn't scan gigabytes per frame.
		// A line longer than the cap renders as successive capped rows (crude
		// long-line handling; proper horizontal scroll is a follow-up).
		end := base.pt_line_end_cap(&doc.pt, start, RENDER_LINE_CAP)
		bottom = end
		row_y := y0 + f32(r) * line_h

		draw_len := min(end - start, len(line_buf))
		n := base.pt_read(&doc.pt, start, line_buf[:draw_len])
		vis := n
		if vis > 0 && line_buf[vis - 1] == '\r' {vis -= 1}
		if vis > 0 {
			plat.text_draw(gfx, t, string(line_buf[:vis]), x0, row_y, px, fg)
		}

		if doc.cursor >= start && doc.cursor <= end {
			cx = x0 + f32(doc.cursor - start) * char_w
			cy = row_y
			caret = true
		}
		if doc.filter {
			continue
		}
		if end >= doc.pt.length {break}
		pos = end + 1
	}
	return
}
