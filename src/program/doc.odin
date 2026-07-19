// Layer: program — an editable document: a piece-table buffer over the file's
// (immutable) original bytes, a caret, undo/redo via piece snapshots, and a
// background line index over the original for the scrollbar. The viewport reads
// through the piece table on demand, so it stays instant regardless of size.
// Every screen pass shares one capped line iterator (visible_begin/next) and the
// layout helpers below, so geometry stays consistent and bounded.
package main

import "base:intrinsics"
import "core:strings"
import "core:thread"
import "core:unicode/utf8"
import base "src:base"
import plat "src:platform"

// Max bytes scanned per visible line for its end (bounds per-frame work).
RENDER_LINE_CAP :: 8192
// Max columns any screen pass computes geometry for; caret/selection/text are
// all clipped to this so a long line can't produce off-screen quads or place the
// caret past the rendered glyphs. Real horizontal scroll is a later feature.
VISIBLE_COLS :: 2048

// --- shared screen layout (one home for the margins/spacing every pass used to
// hardcode as 12 / 10 / 1.5) ---

TEXT_MARGIN_X :: f32(12) // left gutter before text (px)
TEXT_MARGIN_Y :: f32(10) // top gutter above the first line (px)
LINE_SPACING :: f32(1.5) // line height = font px * this

line_height :: #force_inline proc(px: f32) -> f32 {return px * LINE_SPACING}
// Text baseline y for visible row r (what text_draw wants).
row_baseline_y :: #force_inline proc(px: f32, r: int) -> f32 {return px + TEXT_MARGIN_Y + f32(r) * line_height(px)}
// Top y of a line-height-tall highlight box for row r.
row_rect_y :: #force_inline proc(px: f32, r: int) -> f32 {return TEXT_MARGIN_Y + f32(r) * line_height(px)}
// Left x of column `col` (monospace).
col_x :: #force_inline proc(char_w: f32, col: int) -> f32 {return TEXT_MARGIN_X + f32(col) * char_w}
// Inverse mappings for hit-testing a client-space pixel.
row_at_y :: #force_inline proc(px, my: f32) -> int {return int((my - TEXT_MARGIN_Y) / line_height(px))}
col_at_x :: #force_inline proc(char_w, mx: f32) -> int {return max(0, int((mx - TEXT_MARGIN_X) / char_w + 0.5))}

// Walks the visible lines (filter view or consecutive) yielding each row's
// [start, end) byte range, with `end` capped to RENDER_LINE_CAP so no screen
// pass ever scans a pathological long line. Every pass (draw, selection, find
// highlights) shares this so they agree on geometry and stay bounded.
Visible_Iter :: struct {
	doc:  ^Document,
	rows: int,
	r:    int,
	pos:  int,
	done: bool,
}

visible_begin :: proc(doc: ^Document, rows: int) -> Visible_Iter {
	return {doc = doc, rows = rows, pos = doc.top}
}

visible_next :: proc(it: ^Visible_Iter) -> (row, start, end: int, ok: bool) {
	if it.done || it.r >= it.rows {return}
	d := it.doc
	if d.filter {
		fi := d.filter_top + it.r
		if fi >= len(d.filter_lines) {return}
		start = d.filter_lines[fi]
		end = base.pt_line_end_cap(&d.pt, start, RENDER_LINE_CAP)
	} else {
		if it.pos > d.pt.length {return}
		start = it.pos
		end = base.pt_line_end_cap(&d.pt, start, RENDER_LINE_CAP)
		if end >= d.pt.length {
			it.done = true // last line: yield it, then stop
		} else {
			it.pos = end + 1
		}
	}
	row = it.r
	it.r += 1
	ok = true
	return
}

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
	fault:      bool, // atomic: a read faulted (mapped file changed underneath)
	guard:      bool, // scan through the SEH guard (content is mapped, not private)
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
	recovered:  bool, // a mapped read faulted; buffer is now a private copy, not the file
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
	// Guard the scan only when content aliases the mapping (UTF-8, no transcode);
	// a transcoded or copied original is private memory and can't fault.
	doc.idx.guard = doc.fv.mapped && !doc.owned_orig
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
	CHUNK :: 64 * 1024
	buf: [CHUNK]u8
	line, i := 0, 0
	for i < len(c) {
		if intrinsics.atomic_load(&idx.cancel) {return}
		end := min(i + CHUNK, len(c))
		scan := c[i:end]
		if idx.guard {
			// c aliases a memory map: copy through the SEH guard first, so a
			// truncated/decompression-broken page stops the scan instead of
			// crashing. The main thread sees idx.fault and detaches the mapping.
			if !base.safe_copy(buf[:end - i], scan) {
				intrinsics.atomic_store(&idx.fault, true)
				return
			}
			scan = buf[:end - i]
		}
		for b in scan {if b == '\n' {line += 1}}
		i = end
		intrinsics.atomic_store(&idx.indexed, i)
		intrinsics.atomic_store(&idx.line_count, line + 1)
	}
	intrinsics.atomic_store(&idx.line_count, line + 1)
	intrinsics.atomic_store(&idx.indexed, len(c))
	intrinsics.atomic_store(&idx.done, true)
}

// A mapped read faulted (the file was truncated or its NTFS decompression failed
// underneath us). Copy whatever pages are still readable into private memory,
// detach from the mapping, and mark the document recovered so the user knows the
// content is no longer the file on disk. Main thread only; idempotent.
doc_recover_from_fault :: proc(doc: ^Document) {
	if doc.recovered || !doc.fv.mapped {return}
	// Stop the index worker before touching/unmapping the shared mapped bytes.
	if doc.idx.th != nil {
		intrinsics.atomic_store(&doc.idx.cancel, true)
		thread.join(doc.idx.th)
		thread.destroy(doc.idx.th)
		doc.idx.th = nil
	}
	// Guarded copy of the mapped original into private memory (bad pages -> zeros).
	priv := make([]u8, len(doc.original))
	base.safe_copy(priv, doc.original)
	doc.original = priv
	doc.owned_orig = true
	doc.pt.original = priv // pieces index by offset, so this repoint is transparent
	plat.file_close(&doc.fv) // unmaps and zeroes fv
	doc.recovered = true
	doc.modified = true // buffer differs from disk; don't let a save look clean

	// Re-index over the now-private buffer for a correct final line count.
	doc.idx.content = priv
	doc.idx.total = len(priv)
	doc.idx.guard = false
	intrinsics.atomic_store(&doc.idx.done, false)
	intrinsics.atomic_store(&doc.idx.fault, false)
	intrinsics.atomic_store(&doc.idx.cancel, false)
	intrinsics.atomic_store(&doc.idx.indexed, 0)
	intrinsics.atomic_store(&doc.idx.line_count, 0)
	doc_index_start(doc)
}

// True if a mapped read faulted on either the main thread or the index worker.
doc_fault_pending :: proc(doc: ^Document) -> bool {
	return base.pt_take_fault() || intrinsics.atomic_load(&doc.idx.fault)
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
doc_index_faulted :: proc(doc: ^Document) -> bool {return intrinsics.atomic_load(&doc.idx.fault)}
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

// Cell column of byte offset `off` measured from line start `ls` (off >= ls),
// via the text layer's per-codepoint cell widths. Bounded to the drawn extent.
line_cell_col :: proc(doc: ^Document, t: ^plat.Text, ls, off: int) -> int {
	if off <= ls {return 0}
	buf: [VISIBLE_COLS * 4]u8 // <=4 bytes per cell, <=VISIBLE_COLS cells
	n := min(off - ls, len(buf))
	got := base.pt_read(&doc.pt, ls, buf[:n])
	return plat.text_cells(t, buf[:got])
}

// Inverse: byte offset within line [ls, le] at cell column `col` (rune-rounded).
@(private = "file")
line_offset_at_cell :: proc(doc: ^Document, t: ^plat.Text, ls, le, col: int) -> int {
	buf: [VISIBLE_COLS * 4]u8
	n := min(le - ls, len(buf))
	got := base.pt_read(&doc.pt, ls, buf[:n])
	return min(ls + plat.text_bytes_for_cells(t, buf[:got], col), le)
}

// Byte offset under a client-space pixel (cell-grid column mapping).
doc_pos_at :: proc(doc: ^Document, t: ^plat.Text, mx, my: i32, px, char_w: f32, rows: int) -> int {
	target := clamp(row_at_y(px, f32(my)), 0, rows - 1)
	col := col_at_x(char_w, f32(mx))
	it := visible_begin(doc, rows)
	last_start, last_end := doc.top, doc.top
	for {
		row, start, end, ok := visible_next(&it)
		if !ok {break}
		last_start, last_end = start, end
		if row == target {
			return line_offset_at_cell(doc, t, start, end, col)
		}
	}
	return line_offset_at_cell(doc, t, last_start, last_end, col) // click below last line
}

// Selection highlight rectangles for the visible lines (opaque; drawn behind
// text). Fills `out`, returns the count.
doc_selection_rects :: proc(doc: ^Document, t: ^plat.Text, px, char_w: f32, rows: int, out: []plat.Quad) -> int {
	lo, hi := doc_sel_range(doc)
	if lo == hi {return 0}
	col := [4]f32{0.20, 0.30, 0.48, 1}
	lh := line_height(px)
	it := visible_begin(doc, rows)
	n := 0
	for n < len(out) {
		row, start, end, ok := visible_next(&it)
		if !ok {break}
		if lo <= end && hi > start { // selection overlaps [start, end]
			startcol := min(line_cell_col(doc, t, start, max(start, lo)), VISIBLE_COLS)
			endcol := min(line_cell_col(doc, t, start, min(end, hi)), VISIBLE_COLS)
			sx := col_x(char_w, startcol)
			ex := col_x(char_w, endcol)
			if hi > end {ex += char_w * 0.4} // continues past EOL: hint the newline
			out[n] = {pos = {sx, row_rect_y(px, row)}, size = {max(ex - sx, 2), lh}, color = col}
			n += 1
		}
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
	// A line longer than the cap renders as successive capped rows and columns
	// past VISIBLE_COLS aren't drawn (crude long-line handling; proper horizontal
	// scroll is a follow-up).
	line_buf: [VISIBLE_COLS]u8
	bottom = doc.top
	it := visible_begin(doc, rows)
	for {
		row, start, end, ok := visible_next(&it)
		if !ok {break}
		bottom = end
		row_y := row_baseline_y(px, row)

		draw_len := min(end - start, len(line_buf))
		n := base.pt_read(&doc.pt, start, line_buf[:draw_len])
		vis := n
		if vis > 0 && line_buf[vis - 1] == '\r' {vis -= 1}
		if vis > 0 {
			plat.text_draw(gfx, t, string(line_buf[:vis]), col_x(char_w, 0), row_y, px, fg)
		}

		if doc.cursor >= start && doc.cursor <= end {
			cprefix := min(doc.cursor - start, n) // caret column = cells before it, clipped to drawn text
			cx = col_x(char_w, plat.text_cells(t, line_buf[:cprefix]))
			cy = row_y
			caret = true
		}
	}
	return
}
