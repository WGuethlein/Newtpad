// Layer: program — an editable document: a piece-table buffer over the file's
// (immutable) original bytes, a caret, undo/redo via piece snapshots, and a
// background line index over the original for the scrollbar. The viewport reads
// through the piece table on demand, so it stays instant regardless of size.
// Every screen pass shares one capped line iterator (visible_begin/next) and the
// layout helpers below, so geometry stays consistent and bounded.
package main

import "base:intrinsics"
import "core:fmt"
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

// Chrome text comes in exactly two sizes. Every distinct px is an independent
// set of rasterized glyphs in the atlas, and glyph area grows with the square of
// the DPI scale — six chrome sizes (15/17/14/13/12 plus the body's 16) meant six
// copies of ASCII, which at 300% is most of a 1024^2 atlas before a single CJK
// character. Two is also simply less to keep consistent.
BASE_PX_96 :: f32(16) // default document text size at 96 DPI
BASE_PX := BASE_PX_96 // current, from settings (see settings.odin)
UI_PX_96 :: f32(15) // chrome: menu/caption glyphs, palette rows, find bar
UI_SMALL_PX_96 :: f32(13) // secondary: tab labels, status bar, category labels
TEXT_MARGIN_X_96 :: f32(12) // left gutter before text
TEXT_MARGIN_Y_96 :: f32(10) // top gutter above the first line
TAB_STRIP_H_96 :: f32(36) // height of the custom title bar (tabs + window buttons)

LINE_SPACING :: f32(1.5) // line height = font px * this (a ratio; DPI-independent)

// --- the same values at the current DPI ---
//
// These are variables, not constants, because every one of them is a pixel
// measurement and the window's DPI is only known at runtime — and can change
// while running, when the window is dragged to another monitor. They are written
// in exactly one place (metrics_recompute, main.odin) before any frame is drawn,
// and read everywhere else. Newtpad is a single-window app, so there is exactly
// one DPI in play at a time and no need to thread a context object through every
// draw call.
// One width for the scrollbar. It used to be three disagreeing numbers — the
// hit-test gutter, the drawn track, and the width reserved when wrapping — which
// merely looked sloppy at 96 DPI but would have rendered wrapped text underneath
// the bar once they scaled independently.
SCROLLBAR_W_96 :: f32(16)

UI_PX := UI_PX_96
UI_SMALL_PX := UI_SMALL_PX_96
TEXT_MARGIN_X := TEXT_MARGIN_X_96
TEXT_MARGIN_Y := TEXT_MARGIN_Y_96
TAB_STRIP_H := TAB_STRIP_H_96
SCROLLBAR_W := SCROLLBAR_W_96

// Bottom edge of the chrome: below the tab strip AND the menu bar. Anything
// positioned against the top of the content area (the scrollbar, its drag
// mapping) must use this, not TAB_STRIP_H — using the strip alone let the
// scrollbar gutter extend up into the menu row and swallow clicks meant for it.
CHROME_TOP := TAB_STRIP_H_96 + MENU_BAR_H_96

// Content-area top edge. Derived, so it is recomputed with the rest; the
// initialiser here must stay in step with metrics_recompute, since the headless
// test modes never call that.
CONTENT_TOP := TAB_STRIP_H_96 + MENU_BAR_H_96 + TEXT_MARGIN_Y_96

// window DPI / 96, written by metrics_recompute. Lets the small one-off offsets
// inside a widget scale without every draw proc taking a context parameter.
UI_SCALE: f32 = 1

// Scale a 96-DPI offset. Sign-preserving, and never rounds a non-zero value away
// to nothing (a 1px gap must stay visible).
sx :: #force_inline proc(v: f32) -> f32 {
	if v == 0 {return 0}
	r := f32(int(v * UI_SCALE + (0.5 if v > 0 else -0.5)))
	return r if r != 0 else (1 if v > 0 else -1)
}

// Rounded to a whole pixel for the same reason cell width is (see
// plat.text_char_width): row r's top is r*line_height, and every pass that
// positions against rows — draw, caret, selection, find rects, hit-testing, and
// the `rows` count in the frame loop — must agree exactly. At an odd px (105%
// scale gives px=17) an unrounded px*1.5 is fractional, drifting half a pixel
// per row: a full row off by row 40.
line_height :: #force_inline proc(px: f32) -> f32 {return f32(int(px * LINE_SPACING + 0.5))}
// Text baseline y for visible row r (what text_draw wants).
row_baseline_y :: #force_inline proc(px: f32, r: int) -> f32 {return px + CONTENT_TOP + f32(r) * line_height(px)}
// Top y of a line-height-tall highlight box for row r.
row_rect_y :: #force_inline proc(px: f32, r: int) -> f32 {return CONTENT_TOP + f32(r) * line_height(px)}
// Left x of column `col` (monospace).
// Width of the line-number gutter, 0 when there isn't one. Set once per frame
// (doc_update_gutter) and added by BOTH col_x and col_at_x, so the drawn column
// and the hit-tested column cannot disagree about where text begins.
GUTTER_W: f32 = 0

// Recompute the gutter for the active document. Only the filter view has one:
// its whole purpose is showing lines out of context, which is meaningless
// without saying which lines they are.
doc_update_gutter :: proc(doc: ^Document, char_w: f32) {
	GUTTER_W = 0
	if doc == nil || !doc_filtering(doc) || len(doc.filter_line_nos) == 0 {return}
	biggest := doc.filter_line_nos[len(doc.filter_line_nos) - 1]
	digits := 1
	for v := biggest; v >= 10; v /= 10 {digits += 1}
	GUTTER_W = f32(digits + 2) * char_w
}

col_x :: #force_inline proc(char_w: f32, col: int) -> f32 {return TEXT_MARGIN_X + GUTTER_W + f32(col) * char_w}
// Inverse mappings for hit-testing a client-space pixel.
row_at_y :: #force_inline proc(px, my: f32) -> int {return int((my - CONTENT_TOP) / line_height(px))}
col_at_x :: #force_inline proc(char_w, mx: f32) -> int {return max(0, int((mx - TEXT_MARGIN_X - GUTTER_W) / char_w + 0.5))}

// --- word wrap: break a logical line into visual rows at doc.view_cols cells ---

// End of the visual row starting at `p` (which must be a visual-row start).
// Returns the break offset and whether it's the logical line end. Breaks after
// the last word boundary that fits; a single word wider than the row char-breaks.
// When wrap is off, callers use pt_line_end_cap instead.
wrap_row_end :: proc(doc: ^Document, t: ^plat.Text, p, cols: int) -> (end: int, line_end: bool) {
	c := max(cols, 1)
	L := doc.pt.length
	buf: [512]u8
	pos := p
	col := 0
	last_break := -1 // offset just after the most recent space/tab that fit
	for pos < L {
		n := base.pt_read(&doc.pt, pos, buf[:min(len(buf), L - pos)])
		if n == 0 {break}
		i := 0
		for i < n {
			if buf[i] == '\n' {return pos + i, true}
			r, sz := utf8.decode_rune(buf[i:n])
			if sz == 0 {sz = 1}
			if i + sz > n && pos + n < L {break} // rune straddles the chunk; refill
			cw := plat.text_cell_width(t, r, .Doc)
			if col + cw > c && col > 0 {
				if last_break > p {return last_break, false}
				return pos + i, false // char-break an over-long word
			}
			col += cw
			if buf[i] == ' ' || buf[i] == '\t' {last_break = pos + i + sz}
			i += sz
		}
		if i == 0 {break}
		pos += i
	}
	return L, true
}

// Start of the visual row after the one starting at `p`.
next_visual_row :: proc(doc: ^Document, t: ^plat.Text, p, cols: int) -> int {
	e, le := wrap_row_end(doc, t, p, cols)
	if le {return e + 1 if e < doc.pt.length else doc.pt.length}
	return e
}

// Start of the visual row containing byte `off`.
visual_row_start :: proc(doc: ^Document, t: ^plat.Text, off, cols: int) -> int {
	s := base.pt_line_start(&doc.pt, off)
	for {
		e, le := wrap_row_end(doc, t, s, cols)
		if le || off < e {return s}
		s = e
	}
}

// Start of the visual row before the one starting at `p`.
prev_visual_row :: proc(doc: ^Document, t: ^plat.Text, p, cols: int) -> int {
	if p <= 0 {return 0}
	ls := base.pt_line_start(&doc.pt, p)
	if ls < p { // p is mid logical line: the segment just before it
		s := ls
		for {
			ns := next_visual_row(doc, t, s, cols)
			if ns >= p {return s}
			s = ns
		}
	}
	// p is a logical line start: last segment of the previous logical line
	s := base.pt_prev_line_start(&doc.pt, p)
	for {
		e, le := wrap_row_end(doc, t, s, cols)
		if le {return s}
		s = e
	}
}

// Walks the visible rows (filter view, wrapped, or consecutive) yielding each
// row's [start, end) byte range plus whether it ends a logical line. Wrap-aware,
// so every screen pass (draw, selection, find highlights) sharing it stays
// consistent; `end` is capped to RENDER_LINE_CAP when not wrapping so no pass
// scans a pathological long line.
Visible_Iter :: struct {
	doc:  ^Document,
	t:    ^plat.Text,
	rows: int,
	r:    int,
	pos:  int,
	done: bool,
}

visible_begin :: proc(doc: ^Document, t: ^plat.Text, rows: int) -> Visible_Iter {
	return {doc = doc, t = t, rows = rows, pos = doc.top}
}

// Filter view only actually filters once there are matching lines. With the
// filter armed but nothing matched yet — an empty query, or a worker that hasn't
// published — the document renders normally instead of showing a blank screen.
// That is what lets Ctrl+L arm the filter first and narrow as the user types.
// Height of the bar along the bottom: the find bar when find is open, otherwise
// the status line. Document rows must stop above it, or text is drawn behind the
// bar and clicks in that strip land on rows the user cannot see.
doc_bottom_bar_h :: proc(doc: ^Document) -> f32 {
	if doc != nil && doc.find.active {
		return sx(48) if doc.find.replace_mode else sx(26)
	}
	return sx(20) // status line
}

// Visible document rows, excluding the bottom bar.
doc_visible_rows :: proc(doc: ^Document, height, line_h: f32) -> int {
	return max(0, int((height - CONTENT_TOP - doc_bottom_bar_h(doc)) / line_h))
}

// Highest filter_top that still fills the screen. One definition: the wheel, the
// page keys and the match auto-scroll each had their own, so Page-Down could
// scroll to a single line above a screen of empty rows while the wheel refused
// to move at all.
doc_filter_max_top :: proc(doc: ^Document, rows: int) -> int {
	return max(0, len(doc.filter_lines) - max(1, rows))
}

doc_filtering :: proc(doc: ^Document) -> bool {
	return doc.filter && len(doc.filter_lines) > 0
}

visible_next :: proc(it: ^Visible_Iter) -> (row, start, end: int, line_end, ok: bool) {
	if it.done || it.r >= it.rows {return}
	d := it.doc
	if doc_filtering(d) {
		fi := d.filter_top + it.r
		if fi >= len(d.filter_lines) {return}
		start = d.filter_lines[fi]
		end = base.pt_line_end_cap(&d.pt, start, RENDER_LINE_CAP)
		line_end = true
	} else {
		if it.pos > d.pt.length {return}
		start = it.pos
		if d.wrap {
			end, line_end = wrap_row_end(d, it.t, start, d.view_cols)
			if line_end {
				if end >= d.pt.length {it.done = true} else {it.pos = end + 1}
			} else {
				it.pos = end // next visual row continues the same logical line
			}
		} else {
			end = base.pt_line_end_cap(&d.pt, start, RENDER_LINE_CAP)
			line_end = true
			if end >= d.pt.length {it.done = true} else {it.pos = end + 1}
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

// What produced an edit. Used to decide whether the next one continues it (so a
// typing run is one undo step, not one per character) and to label the entry in
// the history list.
Edit_Kind :: enum u8 {
	None,
	Type, // consecutive character inserts
	Delete,
	Paste,
	Replace, // find & replace
	Newline,
}

UNDO_MAX :: 200 // entries kept; oldest dropped. Each holds a cloned piece tree.

Snapshot :: struct {
	root:     ^base.Node, // cloned piece tree
	length:   int,
	cursor:   int,
	anchor:   int,
	nl_delta: int,
	kind:     Edit_Kind, // the edit that PRODUCED this state (.None = as opened)
	count:    int, // characters/edits involved, for the label
}

// A tab is usually a text document, but Settings and Font are tabs too. Making
// them tabs rather than a full-window takeover means they can be switched away
// from, closed with Ctrl+W, and shown in the tab strip like anything else —
// instead of trapping the window until you click the same button again.
Tab_Kind :: enum u8 {
	Text,
	Settings,
	Font,
}

Document :: struct {
	kind:       Tab_Kind,
	fv:         plat.File_View,
	original:   []u8,
	owned_orig: bool,
	enc:        base.Encoding,
	pt:         base.Piece_Table,
	path:       string, // "" for an unnamed scratch buffer
	path_owned: bool, // doc.path is heap-owned (freed on close/re-save)
	had_bom:    bool, // whether the file opened with a BOM (preserved on save)
	eol:        base.Line_Ending, // as opened; what a save writes back
	top:        int, // byte offset of the top visible (visual) row
	cursor:     int, // caret byte offset
	anchor:     int, // other end of the selection (== cursor when none)
	wrap:       bool, // word-wrap this document at view_cols
	view_cols:  int, // usable content width in cells (set per frame when wrapping)
	view_rows:  int, // visible row count (set per frame; filter scrolling clamps to it)
	status_cursor: int, // cursor pos the cached status line was computed for
	status_line:   int, // 1-based line of the cursor (0 = beyond the cap / unknown)
	modified:   bool,
	recovered:  bool, // a mapped read faulted; buffer is now a private copy, not the file
	// External-change detection (watch.odin). `gen` distinguishes this document
	// from a later one reusing the same tab slot, so a stat result that arrives
	// after a close is discarded instead of applied to a stranger.
	gen:          u64,
	disk_stamp:   plat.File_Stamp, // the file as we last saw it
	disk_changed: bool, // changed underneath us and we have not reconciled
	disk_gone:    bool, // it stopped existing
	appended:     int, // bytes absorbed from the file's tail since it was opened
	nl_delta:   int,
	undo:       [dynamic]Snapshot,
	redo:       [dynamic]Snapshot,
	// Coalescing state: what the last edit was and where it left the caret. A
	// run of typing continues only while both still match.
	last_edit:    Edit_Kind,
	last_edit_at: int,
	// What produced the CURRENT state, and how much of it. Each Snapshot carries
	// the same for the state it holds, so the description travels with a state as
	// it moves between the undo and redo stacks — otherwise a state that came
	// back via undo would lose its label.
	state_kind:  Edit_Kind,
	state_count: int,
	idx:        Line_Index,
	find:       Find,
	search:     Search, // background find worker (see find.odin)
	// filter-to-matching-lines view (only while find is active)
	filter:       bool,
	filter_lines: [dynamic]int, // deduped matching-line starts
	// 1-based line number for each entry above, counted by the search worker
	// during its pass. Without it a filtered view shows matching lines with no
	// indication of where in the file they came from.
	filter_line_nos: [dynamic]int,
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
	// Slices into the Search arrays, re-sliced once per frame to whatever the
	// worker has published. Not owned here — see Search.
	matches:      []int, // sorted match start offsets
	match_len:    []int, // length of each match (regex matches vary)
	merged:       int, // entries already folded into filter_lines
	current:      int, // index into matches, or -1
	jumped:       bool, // already auto-selected a match for this query
	dirty:        bool, // an edit invalidated the results; restart next frame
	truncated:    bool, // hit MAX_MATCHES; results are partial
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
	doc.eol = base.detect_line_ending(doc.original)
	doc.disk_stamp = plat.file_stamp(path) // baseline for change detection
	return doc, true
}

// Build an in-memory document from `content` (internal UTF-8, ownership taken)
// for session restore of a dirty/untitled buffer. `path` is the origin file
// ("" for untitled); the document is marked modified since it differs from disk.
doc_from_content :: proc(content: []u8, path: string, enc: base.Encoding) -> (doc: Document) {
	doc.original = content
	doc.owned_orig = true
	doc.enc = enc
	doc.pt = base.pt_init(content)
	if path != "" {
		doc.path = strings.clone(path)
		doc.path_owned = true
	}
	doc.modified = true
	doc.idx.content = content
	doc.idx.total = len(content)
	return
}

// Cancel and join the line indexer. Must happen before anything the worker's
// `content` slice points into is freed or unmapped.
doc_index_stop :: proc(doc: ^Document) {
	if doc.idx.th == nil {return}
	intrinsics.atomic_store(&doc.idx.cancel, true)
	thread.join(doc.idx.th)
	thread.destroy(doc.idx.th)
	doc.idx.th = nil
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
	// Before pt_destroy: the worker's view aliases the add chunks it frees.
	search_release(doc)
	for s in doc.undo {base.pt_free_node_tree(s.root)}
	for s in doc.redo {base.pt_free_node_tree(s.root)}
	delete(doc.undo)
	delete(doc.redo)
	delete(doc.find.query)
	delete(doc.find.replace)
	delete(doc.filter_lines)
	delete(doc.filter_line_nos)
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
	// Same for the search worker: its view aliases the mapping about to be
	// unmapped. Restart it next frame against the recovered buffer.
	find_invalidate(doc)
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
// The buffer flag is this document's own, so a fault on a background tab no
// longer recovers whichever document happens to be active.
doc_fault_pending :: proc(doc: ^Document) -> bool {
	return base.pt_take_fault(&doc.pt) || intrinsics.atomic_load(&doc.idx.fault) || search_faulted(doc)
}

// Save the buffer to `path`, re-encoded to the file's original encoding
// (UTF-16 files round-trip; UTF-8 keeps/omits its BOM as opened). Atomic write.
doc_save :: proc(doc: ^Document, path: string) -> bool {
	return doc_save_err(doc, path) == .None
}

// Returns why the save failed so the caller can tell the user. A save that fails
// silently is a data-loss bug: the user believes the file is written.
doc_save_err :: proc(doc: ^Document, path: string) -> plat.Write_Error {
	body := base.pt_collect(&doc.pt, context.temp_allocator) // internal UTF-8
	out := base.encode_from_utf8(body, doc.enc, doc.had_bom, context.temp_allocator)
	if err := plat.file_write_atomic_err(path, out); err != .None {
		return err
	}
	newpath := strings.clone(path) // clone first: path may alias doc.path (re-save)
	if doc.path_owned {
		delete(doc.path)
	}
	doc.path = newpath
	doc.path_owned = true
	doc.modified = false
	// Record the file as we just left it, or the watcher reports our own write
	// as an external change on its next pass.
	doc.disk_stamp = plat.file_stamp(path)
	doc.disk_changed = false
	doc.disk_gone = false
	doc.appended = 0
	return .None
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
	return {
		root = base.pt_snapshot(&doc.pt),
		length = doc.pt.length,
		cursor = doc.cursor,
		anchor = doc.anchor,
		nl_delta = doc.nl_delta,
	}
}

@(private = "file")
apply_snapshot :: proc(doc: ^Document, s: Snapshot) {
	find_invalidate(doc) // undo/redo don't go through push_undo
	base.pt_restore(&doc.pt, s.root, s.length) // takes ownership of s.root
	doc.cursor = s.cursor
	doc.anchor = s.anchor
	doc.nl_delta = s.nl_delta
}

@(private = "file")
// Record the state BEFORE an edit of `kind`.
//
// Consecutive typing coalesces into one entry: if the previous edit was also
// typing and the caret is exactly where it left off, the existing snapshot still
// describes the state before the whole run, so no new one is needed. Without
// this, "hello" is five undo steps and the history list is unreadable.
// A caret jump, a different kind of edit, or a newline breaks the run.
push_undo :: proc(doc: ^Document, kind: Edit_Kind = .Type) {
	find_invalidate(doc) // every edit path routes through here; match offsets shift
	doc.modified = true
	for s in doc.redo {base.pt_free_node_tree(s.root)}
	clear(&doc.redo)

	continues := kind == .Type &&
		doc.last_edit == .Type &&
		doc.cursor == doc.last_edit_at &&
		len(doc.undo) > 0 &&
		!doc_has_sel(doc)
	if continues {
		doc.state_count += 1 // the run grows the state we are about to reach
		return
	}

	// The snapshot holds the state we are leaving, labelled with whatever
	// produced it. The edit now happening labels the state we are moving to.
	s := snapshot(doc)
	s.kind = doc.state_kind
	s.count = doc.state_count
	doc.state_kind = kind
	doc.state_count = 1
	append(&doc.undo, s)
	// Bounded: this is a long-lived process and every entry holds a cloned tree.
	if len(doc.undo) > UNDO_MAX {
		base.pt_free_node_tree(doc.undo[0].root)
		ordered_remove(&doc.undo, 0)
	}
	doc.last_edit = kind
}

doc_undo :: proc(doc: ^Document) {
	if len(doc.undo) == 0 {return}
	cur := snapshot(doc) // the state we leave keeps its own description
	cur.kind, cur.count = doc.state_kind, doc.state_count
	append(&doc.redo, cur)
	s := pop(&doc.undo)
	doc.state_kind, doc.state_count = s.kind, s.count
	apply_snapshot(doc, s) // s.root becomes the live tree
	doc.last_edit = .None
}

doc_redo :: proc(doc: ^Document) {
	if len(doc.redo) == 0 {return}
	cur := snapshot(doc)
	cur.kind, cur.count = doc.state_kind, doc.state_count
	append(&doc.undo, cur)
	s := pop(&doc.redo)
	doc.state_kind, doc.state_count = s.kind, s.count
	apply_snapshot(doc, s)
	doc.last_edit = .None
}

// Change the encoding the document will be SAVED as. The buffer is already
// internal UTF-8, so nothing is re-decoded — only the target changes.
doc_set_encoding :: proc(doc: ^Document, enc: base.Encoding) {
	if doc.enc == enc {return}
	doc.enc = enc
	if enc != .UTF8 {doc.had_bom = enc == .UTF16LE || enc == .UTF16BE}
	doc.modified = true // it now differs from what is on disk
}

// Rewrite the buffer's line endings. A real edit, so it goes through the undo
// path and can be reverted.
doc_set_line_ending :: proc(doc: ^Document, eol: base.Line_Ending) {
	if eol == .Mixed || doc.eol == eol {return}
	body := base.pt_collect(&doc.pt, context.temp_allocator)
	converted := base.convert_line_endings(body, eol, context.temp_allocator)
	if len(converted) == len(body) {
		doc.eol = eol // nothing actually changed (no line breaks)
		return
	}
	push_undo(doc, .Replace)
	base.pt_delete(&doc.pt, 0, doc.pt.length)
	base.pt_insert(&doc.pt, 0, converted)
	doc.eol = eol
	doc.cursor = clamp(doc.cursor, 0, doc.pt.length)
	doc.anchor = doc.cursor
	doc.nl_delta = 0
	doc_index_stop(doc)
	doc.idx.content = doc.original
	doc.idx.total = len(doc.original)
	doc_index_start(doc)
}

// --- external changes ---

// Copy the mapped bytes into private memory and drop the mapping.
//
// This is the "never lock the user's file" rule made real. A user-mapped section
// makes Windows refuse truncation, deletion and replacement of the file
// (ERROR_USER_MAPPED_FILE), so a service cannot roll a log while we hold it
// mapped. As soon as the file starts changing we get out of the way.
//
// Also removes the moving-target problem: an external in-place write changes the
// bytes under a mapping with no size change and no fault, so every offset the
// buffer derived from them would silently describe different content.
doc_detach_mapping :: proc(doc: ^Document) {
	if !doc.fv.mapped {return}
	find_invalidate(doc) // the search worker holds a view aliasing the mapping
	doc_index_stop(doc)

	priv := make([]u8, len(doc.original))
	base.safe_copy(priv, doc.original)
	doc.original = priv
	doc.owned_orig = true
	doc.pt.original = priv // pieces index by offset, so the repoint is transparent
	plat.file_close(&doc.fv)

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

// Bytes appended to the file since we last looked, pulled in without remapping.
// Returns false if the change was not a pure append (the file shrank, or the
// read came up short because it is mid-write — retried on the next poll).
//
// Appending through the add arena rather than remapping is what makes this safe
// against the search worker: arena chunks never move, so a pt_view stays valid
// by construction. No cancel, no join, no unmap window.
doc_absorb_append :: proc(doc: ^Document, new_size: i64) -> bool {
	// Only for documents whose bytes correspond 1:1 with file bytes. A BOM
	// shifts every offset by 3 and UTF-16 is transcoded, so "file grew by N"
	// says nothing about how many document bytes to add.
	if doc.enc != .UTF8 || doc.had_bom {return false}
	// The real precondition is that the buffer IS the file's first `old` bytes.
	// Deriving `old` from len(original)+appended broke after a save: saving
	// writes pt.length bytes and clears `appended`, but leaves `original` at its
	// opening length, so the next append re-read the user's own saved edits and
	// inserted them a second time — silently duplicating text in their file.
	if i64(doc.pt.length) != doc.disk_stamp.size {return false}
	old := doc.disk_stamp.size
	if new_size <= old {return false}

	chunk, ok := plat.file_read_range(doc.path, old, int(new_size - old))
	defer delete(chunk)
	if !ok || len(chunk) == 0 {return false}

	// Appending at the end never disturbs earlier offsets, so the caret,
	// selection and search results all stay meaningful.
	at_end := doc.cursor >= doc.pt.length
	base.pt_insert(&doc.pt, doc.pt.length, chunk)
	for b in chunk {if b == '\n' {doc.nl_delta += 1}}
	doc.appended += len(chunk)
	if at_end { // follow the tail, like tail -f
		doc.cursor = doc.pt.length
		doc.anchor = doc.cursor
	}
	find_invalidate(doc) // match offsets past the old end are now stale
	return true
}

// Re-open from disk, discarding the buffer. Used when the change was not a
// simple append. Undo states describe a document that no longer exists, so they
// go; keeping them would let Ctrl+Z resurrect a file that was never on disk.
doc_reload :: proc(doc: ^Document) -> bool {
	if doc.path == "" {return false}
	fresh, ok := doc_open(doc.path)
	if !ok {return false}

	cursor, anchor, top := doc.cursor, doc.anchor, doc.top
	wrap := doc.wrap
	path := strings.clone(doc.path)

	doc_close(doc) // stops both workers, frees the trees and the old original
	doc^ = fresh
	if doc.path_owned {delete(doc.path)}
	doc.path = path
	doc.path_owned = true
	doc.wrap = wrap
	// Preserve position by byte offset, clamped — the file may have shrunk.
	L := doc.pt.length
	doc.cursor = clamp(cursor, 0, L)
	doc.anchor = clamp(anchor, 0, L)
	doc.top = clamp(top, 0, L)
	doc.disk_stamp = plat.file_stamp(doc.path)
	doc.disk_changed = false
	doc.disk_gone = false
	doc.recovered = false // freshly read; no longer a salvaged copy
	return true
}

// --- history list ---

// Total states the history can show: every undo entry, the current state, and
// everything on the redo stack (which is stored newest-last, so it reads
// backwards relative to the timeline).
doc_history_len :: proc(doc: ^Document) -> int {
	return len(doc.undo) + 1 + len(doc.redo)
}

// Index of the state the document is currently at.
doc_history_current :: proc(doc: ^Document) -> int {return len(doc.undo)}

// Label for history entry `i`: what produced that state. Every entry carries its
// own description, so a state keeps its label as it moves between the undo and
// redo stacks — deriving it from a neighbour made states rename themselves to
// "Opened" the moment you jumped to one.
doc_history_label :: proc(doc: ^Document, i: int) -> string {
	kind: Edit_Kind
	count := 0
	switch {
	case i < len(doc.undo):
		kind, count = doc.undo[i].kind, doc.undo[i].count
	case i == len(doc.undo):
		kind, count = doc.state_kind, doc.state_count
	case:
		// redo is stored newest-last, so it reads backwards against the timeline
		j := len(doc.redo) - 1 - (i - len(doc.undo) - 1)
		if j < 0 || j >= len(doc.redo) {return "?"}
		kind, count = doc.redo[j].kind, doc.redo[j].count
	}
	switch kind {
	case .Type:
		return fmt.tprintf("Typed %d character%s", count, "" if count == 1 else "s")
	case .Newline:
		return "New line"
	case .Delete:
		return fmt.tprintf("Deleted %d time%s", count, "" if count == 1 else "s")
	case .Paste:
		return "Inserted text"
	case .Replace:
		return "Replaced"
	case .None:
		return "As opened"
	}
	return "Edit"
}

// Move the document to history state `target` by walking undo/redo. Walking
// rather than jumping directly keeps both stacks consistent, and each step is a
// tree swap, not a copy of the text.
doc_history_goto :: proc(doc: ^Document, target: int) {
	t := clamp(target, 0, doc_history_len(doc) - 1)
	for doc_history_current(doc) > t && len(doc.undo) > 0 {doc_undo(doc)}
	for doc_history_current(doc) < t && len(doc.redo) > 0 {doc_redo(doc)}
	doc.last_edit = .None // a jump always breaks a typing run
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

// `kind` labels the entry in the history and decides coalescing: a single typed
// character continues a run, a paste or a newline always starts a new entry.
doc_insert_text :: proc(doc: ^Document, text: []u8, kind: Edit_Kind = .Paste) {
	if len(text) == 0 {return}
	push_undo(doc, kind)
	if doc_has_sel(doc) {del_sel_raw(doc)}
	base.pt_insert(&doc.pt, doc.cursor, text)
	for b in text {if b == '\n' {doc.nl_delta += 1}}
	doc.cursor += len(text)
	doc.anchor = doc.cursor
	doc.last_edit_at = doc.cursor
}

// A single typed character: the one case that coalesces into a run. A newline
// breaks the run so undo stops at line boundaries, which is what people expect.
doc_insert_rune :: proc(doc: ^Document, r: rune) {
	bytes, n := utf8.encode_rune(r)
	doc_insert_text(doc, bytes[:n], .Newline if r == '\n' else .Type)
}

doc_backspace :: proc(doc: ^Document) {
	if doc_has_sel(doc) {
		push_undo(doc, .Delete)
		del_sel_raw(doc)
		doc.last_edit_at = doc.cursor
		return
	}
	if doc.cursor <= 0 {return}
	push_undo(doc, .Delete)
	p := prev_rune(doc, doc.cursor)
	doc.nl_delta -= count_newlines(doc, p, doc.cursor - p)
	base.pt_delete(&doc.pt, p, doc.cursor - p)
	set_cursor(doc, p, false)
	doc.last_edit_at = doc.cursor
}

doc_delete_fwd :: proc(doc: ^Document) {
	if doc_has_sel(doc) {
		push_undo(doc, .Delete)
		del_sel_raw(doc)
		doc.last_edit_at = doc.cursor
		return
	}
	if doc.cursor >= doc.pt.length {return}
	push_undo(doc, .Delete)
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

enc_name :: proc(e: base.Encoding) -> string {return base.encoding_name(e)}

// 1-based line number of the caret, or 0 if it's beyond the scan cap (so the
// status bar never spends an unbounded scan on a huge file). Cached per cursor
// position, so it costs nothing when the caret isn't moving.
STATUS_LINE_CAP :: 4 * 1024 * 1024
doc_cursor_line :: proc(doc: ^Document) -> int {
	// Recompute on a cursor move, or on the first call (both fields start at 0).
	if doc.cursor != doc.status_cursor || (doc.status_line == 0 && doc.cursor <= STATUS_LINE_CAP) {
		doc.status_cursor = doc.cursor
		doc.status_line = 1 + count_newlines(doc, 0, doc.cursor) if doc.cursor <= STATUS_LINE_CAP else 0
	}
	return doc.status_line
}

// 1-based cell column of the caret within its line.
doc_cursor_col :: proc(doc: ^Document, t: ^plat.Text) -> int {
	ls := base.pt_line_start(&doc.pt, doc.cursor)
	return line_cell_col(doc, t, ls, doc.cursor) + 1
}

// Scroll so the top of the view is the line start at fraction `frac` of the
// buffer (byte-proportional; used by the draggable scrollbar), bounded so the
// last line stays at the bottom.
doc_scroll_to_fraction :: proc(doc: ^Document, t: ^plat.Text, frac: f32, rows: int) {
	target := int(clamp(frac, 0, 1) * f32(doc.pt.length))
	doc.top = min(base.pt_line_start(&doc.pt, target), doc_max_top(doc, t, rows))
}

// Move the caret to the start of 1-based line `n` (O(n) line walk from the top).
doc_goto_line :: proc(doc: ^Document, n: int) {
	p := 0
	for _ in 1 ..< max(n, 1) {
		np := base.pt_next_line_start(&doc.pt, p)
		if np == p {break}
		p = np
	}
	doc.cursor = p
	doc.anchor = p
}

doc_cursor_home :: proc(doc: ^Document, select: bool) {set_cursor(doc, base.pt_line_start(&doc.pt, doc.cursor), select)}
doc_cursor_end :: proc(doc: ^Document, select: bool) {set_cursor(doc, base.pt_line_end(&doc.pt, doc.cursor), select)}
// Ctrl+Home / Ctrl+End. Without these there is no keyboard way to reach the end
// of a large file at all.
doc_start :: proc(doc: ^Document, select: bool) {set_cursor(doc, 0, select)}
doc_end :: proc(doc: ^Document, select: bool) {set_cursor(doc, doc.pt.length, select)}

doc_cursor_up :: proc(doc: ^Document, t: ^plat.Text, select: bool) {
	if doc.wrap {
		vs := visual_row_start(doc, t, doc.cursor, doc.view_cols)
		if vs == 0 {
			set_cursor(doc, 0, select)
			return
		}
		col := line_cell_col(doc, t, vs, doc.cursor)
		pv := prev_visual_row(doc, t, vs, doc.view_cols)
		pe, _ := wrap_row_end(doc, t, pv, doc.view_cols)
		set_cursor(doc, line_offset_at_cell(doc, t, pv, pe, col), select)
		return
	}
	ls := base.pt_line_start(&doc.pt, doc.cursor)
	if ls == 0 {
		set_cursor(doc, 0, select)
		return
	}
	col := doc.cursor - ls
	prev := base.pt_prev_line_start(&doc.pt, doc.cursor)
	set_cursor(doc, min(prev + col, base.pt_line_end(&doc.pt, prev)), select)
}

doc_cursor_down :: proc(doc: ^Document, t: ^plat.Text, select: bool) {
	if doc.wrap {
		vs := visual_row_start(doc, t, doc.cursor, doc.view_cols)
		e, le := wrap_row_end(doc, t, vs, doc.view_cols)
		if le && e >= doc.pt.length { // already the last visual row
			set_cursor(doc, doc.pt.length, select) // clamp to the doc end, mirroring Up's clamp to 0
			return
		}
		col := line_cell_col(doc, t, vs, doc.cursor)
		nv := next_visual_row(doc, t, vs, doc.view_cols)
		ne, _ := wrap_row_end(doc, t, nv, doc.view_cols)
		set_cursor(doc, line_offset_at_cell(doc, t, nv, ne, col), select)
		return
	}
	ls := base.pt_line_start(&doc.pt, doc.cursor)
	col := doc.cursor - ls
	nl := base.pt_next_line_start(&doc.pt, doc.cursor)
	if nl == doc.pt.length && base.pt_line_end(&doc.pt, nl) == nl && ls == base.pt_line_start(&doc.pt, nl) {
		set_cursor(doc, doc.pt.length, select) // no line below: clamp to the doc end, mirroring Up's clamp to 0
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
	push_undo(doc, .Delete)
	doc.nl_delta -= count_newlines(doc, p, doc.cursor - p)
	base.pt_delete(&doc.pt, p, doc.cursor - p)
	set_cursor(doc, p, false)
	doc.last_edit_at = doc.cursor
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
	return plat.text_cells(t, buf[:got], .Doc)
}

// Inverse: byte offset within line [ls, le] at cell column `col` (rune-rounded).
@(private = "file")
line_offset_at_cell :: proc(doc: ^Document, t: ^plat.Text, ls, le, col: int) -> int {
	buf: [VISIBLE_COLS * 4]u8
	n := min(le - ls, len(buf))
	got := base.pt_read(&doc.pt, ls, buf[:n])
	return min(ls + plat.text_bytes_for_cells(t, buf[:got], col, .Doc), le)
}

// Byte offset under a client-space pixel (cell-grid column mapping).
doc_pos_at :: proc(doc: ^Document, t: ^plat.Text, mx, my: i32, px, char_w: f32, rows: int) -> int {
	target := clamp(row_at_y(px, f32(my)), 0, rows - 1)
	col := col_at_x(char_w, f32(mx))
	it := visible_begin(doc, t, rows)
	last_start, last_end := doc.top, doc.top
	for {
		row, start, end, _, ok := visible_next(&it)
		if !ok {break}
		last_start, last_end = start, end
		if row == target {
			return line_offset_at_cell(doc, t, start, end, col)
		}
	}
	return line_offset_at_cell(doc, t, last_start, last_end, col) // click below last row
}

// Selection highlight rectangles for the visible lines (opaque; drawn behind
// text). Fills `out`, returns the count.
doc_selection_rects :: proc(doc: ^Document, t: ^plat.Text, px, char_w: f32, rows: int, out: []plat.Quad) -> int {
	lo, hi := doc_sel_range(doc)
	if lo == hi {return 0}
	col := [4]f32{0.20, 0.30, 0.48, 1}
	lh := line_height(px)
	it := visible_begin(doc, t, rows)
	n := 0
	for n < len(out) {
		row, start, end, _, ok := visible_next(&it)
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

// The largest doc.top that still fills the viewport (keeps the last line at the
// bottom row); 0 if the whole document fits. Bounds scrolling to real content.
doc_max_top :: proc(doc: ^Document, t: ^plat.Text, rows: int) -> int {
	p := visual_row_start(doc, t, doc.pt.length, doc.view_cols) if doc.wrap else base.pt_line_start(&doc.pt, doc.pt.length)
	for _ in 0 ..< max(rows - 1, 0) {
		if p == 0 {break}
		p = prev_visual_row(doc, t, p, doc.view_cols) if doc.wrap else base.pt_prev_line_start(&doc.pt, p)
	}
	return p
}

// Scroll the viewport by `delta` visual rows (up when negative), clamped so the
// last line can't scroll above the bottom row.
doc_scroll :: proc(doc: ^Document, t: ^plat.Text, delta, rows: int) {
	if delta > 0 {
		for _ in 0 ..< delta {
			nt := next_visual_row(doc, t, doc.top, doc.view_cols) if doc.wrap else base.pt_next_line_start(&doc.pt, doc.top)
			if nt == doc.top {break}
			doc.top = nt
		}
	} else if delta < 0 {
		for _ in 0 ..< -delta {
			if doc.top == 0 {break}
			doc.top = prev_visual_row(doc, t, doc.top, doc.view_cols) if doc.wrap else base.pt_prev_line_start(&doc.pt, doc.top)
		}
	}
	doc.top = min(doc.top, doc_max_top(doc, t, rows))
}

// Keep the caret on screen: scroll so its visual row is within [top, top+rows).
doc_ensure_cursor_visible :: proc(doc: ^Document, t: ^plat.Text, rows: int) {
	cls := visual_row_start(doc, t, doc.cursor, doc.view_cols) if doc.wrap else base.pt_line_start(&doc.pt, doc.cursor)
	if cls < doc.top {
		doc.top = cls
		return
	}
	// walk `rows` visual rows from top; if we pass the caret's row, it's visible
	p := doc.top
	for _ in 0 ..< rows {
		if p >= cls {return}
		p = next_visual_row(doc, t, p, doc.view_cols) if doc.wrap else base.pt_next_line_start(&doc.pt, p)
	}
	// caret is below the viewport: put its row at the bottom
	doc.top = cls
	doc_scroll(doc, t, -(rows - 1), rows)
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
	it := visible_begin(doc, t, rows)
	for {
		row, start, end, line_end, ok := visible_next(&it)
		if !ok {break}
		bottom = end
		row_y := row_baseline_y(px, row)

		draw_len := min(end - start, len(line_buf))
		n := base.pt_read(&doc.pt, start, line_buf[:draw_len])
		vis := n
		if vis > 0 && line_buf[vis - 1] == '\r' {vis -= 1}
		if vis > 0 {
			// Line number, when the filter view is showing lines out of context.
			if GUTTER_W > 0 {
				fi := doc.filter_top + row
				if fi < len(doc.filter_line_nos) {
					num := fmt.tprintf("%d", doc.filter_line_nos[fi])
					// Right-aligned against the gutter's text edge.
					nx := TEXT_MARGIN_X + GUTTER_W - f32(len(num) + 1) * char_w
					plat.text_draw(gfx, t, num, nx, row_y, px, {0.42, 0.47, 0.56, 1})
				}
			}
			plat.text_draw(gfx, t, string(line_buf[:vis]), col_x(char_w, 0), row_y, px, fg, .Doc)
		}

		// Caret on this row: [start, end], but a wrap point (non-line-end `end`)
		// belongs to the next visual row's start, so exclude it here.
		if doc.cursor >= start && doc.cursor <= end && (line_end || doc.cursor < end) {
			cprefix := min(doc.cursor - start, n) // cells before caret, clipped to drawn text
			cx = col_x(char_w, plat.text_cells(t, line_buf[:cprefix], .Doc))
			cy = row_y
			caret = true
		}
	}
	return
}
