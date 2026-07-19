// Layer: program — incremental find & replace. Literal (case-insensitive,
// ASCII-fold) or regex (core:text/regex over line-aligned blocks), scanned in
// blocks over the piece table. Small buffers scan inline; larger ones scan on a
// worker thread that publishes results incrementally, so a keystroke never waits
// on the file size. Replace reuses the doc's public edit path (undo + nl-delta
// handled). Group substitution ($1) is a follow-up.
package main

import "base:intrinsics"
import "core:mem"
import "core:text/regex"
import "core:thread"
import "core:unicode/utf8"
import base "src:base"
import plat "src:platform"

MAX_MATCHES :: 100_000

// Bytes read per block. Cancel is polled per block (and, for regex, per match),
// so this also sets how long a cancel takes to land — which is paid on any edit
// made while a search is running. 256 KB is ~5 ms of regex at the measured
// 16-19 ms/MB, comfortably inside a frame.
SEARCH_BLOCK :: 256 << 10
REGEX_LINE_SLACK :: 1 << 16 // extra bytes allowed to reach the block's line end

// At or below this, scan inline and finish before returning: a worker would cost
// a thread spawn and a pt_view (a tree clone) per keystroke to save well under a
// frame. Above it, the worker earns its keep.
SEARCH_SYNC_MAX :: 256 << 10

// A background search over a private view of the buffer.
//
// Mirrors Line_Index's lifecycle (done/cancel/fault as atomics, cancel-store +
// join + destroy on teardown) but differs in one way that matters: the line
// indexer scans the immutable `original`, while search must see edits, so it
// reads a pt_view — a cloned tree over aliased, never-moving bytes.
//
// The result arrays are allocated once at MAX_MATCHES and never grown. That is
// load-bearing, not a micro-optimisation: appending to a [dynamic] moves the
// base pointer and frees the old block, so a main thread reading match i while
// the worker appended would read freed memory. Fixed capacity makes the
// publication protocol — worker writes by index, then stores `count`; reader
// loads `count` and touches only indices below it — actually sound, with a
// single writer and no lock. (Odin's intrinsics.atomic_store/load are
// sequentially consistent, so the release/acquire pairing this needs is
// implied; the entries are written before the count that publishes them.)
Search :: struct {
	view:       base.Piece_Table, // worker's private read view (worker only)
	query:      []u8, // private copy; the find bar's buffer keeps mutating
	regex:      bool,
	matches:    []int, // fixed MAX_MATCHES capacity, written by index
	match_len:  []int,
	line_start: []int, // line start of each match, computed here (see below)
	count:      int, // atomic: how many entries are published
	scanned:    int, // atomic: bytes scanned, for progress
	total:      int,
	done:       bool, // atomic
	cancel:     bool, // atomic
	fault:      bool, // atomic: a read faulted (mapped file changed underneath)
	truncated:  bool, // atomic: hit MAX_MATCHES
	th:         ^thread.Thread,
}

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
	search_release(doc)
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

// --- search lifecycle ---

// Stop the worker and wait for it. Must complete before anything the worker's
// view points into goes away (pt_destroy's chunks, or a mapped `original` being
// detached), and before results are consumed as final.
@(private = "file")
search_stop :: proc(doc: ^Document) {
	s := &doc.search
	if s.th != nil {
		intrinsics.atomic_store(&s.cancel, true)
		thread.join(s.th)
		thread.destroy(s.th)
		s.th = nil
		base.pt_view_destroy(&s.view)
	}
	if s.query != nil {
		delete(s.query)
		s.query = nil
	}
}

// Stop the worker and free the result arrays. Only on find close / doc close —
// an edit must not free arrays that f.matches still slices.
search_release :: proc(doc: ^Document) {
	search_stop(doc)
	s := &doc.search
	delete(s.matches)
	delete(s.match_len)
	delete(s.line_start)
	s.matches, s.match_len, s.line_start = nil, nil, nil
	doc.find.matches, doc.find.match_len = nil, nil
	doc.find.merged = 0
}

// An edit invalidates every match offset. Stop the worker but defer the restart
// to the next frame, so find_replace_all's edit-per-match loop costs one restart
// instead of one per match.
// Deliberately not gated on find.active: doc_recover_from_fault calls this to
// guarantee the worker is joined before the mapping goes away, and that must
// hold regardless of what the find bar is doing.
find_invalidate :: proc(doc: ^Document) {
	search_stop(doc)
	doc.find.dirty = true
}

@(private = "file")
search_reset :: proc(doc: ^Document) {
	s := &doc.search
	search_stop(doc)
	if s.matches == nil {
		s.matches = make([]int, MAX_MATCHES)
		s.match_len = make([]int, MAX_MATCHES)
		s.line_start = make([]int, MAX_MATCHES)
	}
	intrinsics.atomic_store(&s.count, 0)
	intrinsics.atomic_store(&s.scanned, 0)
	intrinsics.atomic_store(&s.done, false)
	intrinsics.atomic_store(&s.cancel, false)
	intrinsics.atomic_store(&s.fault, false)
	intrinsics.atomic_store(&s.truncated, false)
	s.total = doc.pt.length
	s.regex = doc.find.regex

	f := &doc.find
	f.matches, f.match_len = s.matches[:0], s.match_len[:0]
	f.merged = 0
	f.jumped = false
	f.dirty = false
	f.current = -1
	clear(&doc.filter_lines)
	doc.filter_top = 0
}

find_recompute :: proc(doc: ^Document) {
	search_reset(doc)
	f := &doc.find
	s := &doc.search
	if len(f.query) == 0 {
		intrinsics.atomic_store(&s.done, true)
		return
	}
	s.query = make([]u8, len(f.query))
	copy(s.query, f.query[:])

	if doc.pt.length <= SEARCH_SYNC_MAX {
		// Small buffer: scan the live tree inline. No view, no thread.
		scan_all(s, &doc.pt)
	} else {
		s.view = base.pt_view(&doc.pt)
		s.th = thread.create_and_start_with_data(s, search_worker)
	}
	find_merge(doc)
}

@(private = "file")
search_worker :: proc(data: rawptr) {
	s := (^Search)(data)
	scan_all(s, &s.view)
}

// Take whatever the worker has published into the document's view of the
// results. Runs once per frame; single reader, and it only ever reads indices
// the worker has released.
find_merge :: proc(doc: ^Document) {
	f := &doc.find
	s := &doc.search
	if !f.active {return}
	if f.dirty && s.th == nil {
		find_recompute(doc) // an edit landed; restart once, here
		return
	}
	if s.matches == nil {return}

	n := intrinsics.atomic_load(&s.count)
	f.truncated = intrinsics.atomic_load(&s.truncated)
	if n == f.merged {return}

	f.matches = s.matches[:n]
	f.match_len = s.match_len[:n]

	// Filter view: one entry per matching line. Built from line starts the
	// worker computed during its linear pass — deriving them here would mean
	// pt_line_start per match, an uncapped backward scan on the main thread.
	// Matches are sorted, so same-line matches are adjacent and dedupe is a
	// comparison against the last line appended.
	for i in f.merged ..< n {
		ls := s.line_start[i]
		if len(doc.filter_lines) == 0 || doc.filter_lines[len(doc.filter_lines) - 1] != ls {
			append(&doc.filter_lines, ls)
		}
	}
	f.merged = n

	// Select the caret-nearest match exactly once per query. Re-running this on
	// every merge would yank the viewport around as later results arrive while
	// the user is still typing.
	if !f.jumped && n > 0 {
		f.jumped = true
		f.current = 0
		// Reference the START of any selection, not the caret. Selecting a match
		// leaves the caret at its end, so re-running this after a toggle (Ctrl+R,
		// Ctrl+L) would pick the *next* match every time — the selection walked
		// forward one match per keypress.
		from := min(doc.cursor, doc.anchor)
		for m, i in f.matches {
			if m >= from {
				f.current = i
				break
			}
		}
		find_select_current(doc)
	}
}

// Block until the running search finishes, merging as it goes. Headless-test
// support only — the app never waits, it merges once per frame.
find_wait :: proc(doc: ^Document) {
	for !intrinsics.atomic_load(&doc.search.done) || doc.find.dirty {
		find_merge(doc)
	}
	find_merge(doc)
}

// Bytes scanned so far, for progress reporting.
find_scanned :: proc(doc: ^Document) -> int {
	return intrinsics.atomic_load(&doc.search.scanned)
}

search_faulted :: proc(doc: ^Document) -> bool {
	return intrinsics.atomic_load(&doc.search.fault)
}

// --- the scan itself (shared by the inline and worker paths) ---

// Scan `pt` for s.query, publishing after each block. Tracks the most recent
// newline as it goes so every match carries its line start; that costs nothing
// here (the bytes are already in hand) and saves the main thread an unbounded
// backward scan per match at merge time.
@(private = "file")
scan_all :: proc(s: ^Search, pt: ^base.Piece_Table) {
	if pt.length == 0 || len(s.query) == 0 {
		intrinsics.atomic_store(&s.done, true)
		return
	}
	if s.regex {
		scan_regex(s, pt)
	} else {
		scan_literal(s, pt)
	}
}

// Record a match; returns false when the result arrays are full.
@(private = "file")
emit :: proc(s: ^Search, n: ^int, at, length, line_start: int) -> bool {
	s.matches[n^] = at
	s.match_len[n^] = length
	s.line_start[n^] = line_start
	n^ += 1
	if n^ >= MAX_MATCHES {
		intrinsics.atomic_store(&s.truncated, true)
		intrinsics.atomic_store(&s.count, n^)
		intrinsics.atomic_store(&s.done, true)
		return false
	}
	return true
}

@(private = "file")
scan_literal :: proc(s: ^Search, pt: ^base.Piece_Table) {
	q := s.query
	L := pt.length
	ql := make([]u8, len(q))
	defer delete(ql)
	for i in 0 ..< len(q) {ql[i] = lower(q[i])}

	// Overlap by len(q)-1 so a match spanning a block boundary is still found.
	buf := make([]u8, SEARCH_BLOCK + len(q) - 1)
	defer delete(buf)

	n, last_nl := 0, -1
	pos := 0
	for pos < L {
		if intrinsics.atomic_load(&s.cancel) {return}
		got := base.pt_read(pt, pos, buf[:min(len(buf), L - pos)])
		if got == 0 {break}
		if pt.fault {
			pt.fault = false
			intrinsics.atomic_store(&s.fault, true)
			return
		}
		last := pos + SEARCH_BLOCK >= L
		limit := got - len(q) + 1
		if !last {limit = min(SEARCH_BLOCK, limit)}
		for k := 0; k < limit; k += 1 {
			hit := true
			for j in 0 ..< len(q) {
				if lower(buf[k + j]) != ql[j] {
					hit = false
					break
				}
			}
			// Check before updating last_nl: a match starting on a '\n' belongs
			// to the line that newline terminates, not the one it begins.
			if hit && !emit(s, &n, pos + k, len(q), last_nl + 1) {return}
			if buf[k] == '\n' {last_nl = pos + k}
		}
		pos += SEARCH_BLOCK
		intrinsics.atomic_store(&s.count, n)
		intrinsics.atomic_store(&s.scanned, min(pos, L))
	}
	intrinsics.atomic_store(&s.count, n)
	intrinsics.atomic_store(&s.scanned, L)
	intrinsics.atomic_store(&s.done, true)
}

@(private = "file")
scan_regex :: proc(s: ^Search, pt: ^base.Piece_Table) {
	L := pt.length
	heap := context.allocator
	// One reusable block buffer: captures are slices into it, but the offsets are
	// copied out before the next block overwrites it. Deliberately NOT from the
	// arena below — it has to survive that arena's per-block reset.
	buf := make([]u8, SEARCH_BLOCK + REGEX_LINE_SLACK + 1, heap)
	defer delete(buf, heap)

	// core:text/regex allocates its per-match `saved` arrays from the ambient
	// context.allocator and never frees them. Give the scan a private arena and
	// reset it per block, so that churn neither leaks nor hammers the process
	// heap lock while the UI thread is trying to allocate. A private arena
	// rather than context.temp_allocator because the inline path runs on the
	// main thread, where temp holds other live allocations for the frame.
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	ctx := context
	ctx.allocator = mem.dynamic_arena_allocator(&arena)
	ctx.temp_allocator = ctx.allocator
	context = ctx

	n, last_nl := 0, -1
	pos := 0
	for pos < L {
		if intrinsics.atomic_load(&s.cancel) {return}
		end := pos + min(SEARCH_BLOCK, L - pos)
		if end < L {
			// Never split a line: run on to the next newline (bounded), and keep
			// that newline with its line so end-of-line patterns still match.
			end = min(base.pt_line_end_cap(pt, end, REGEX_LINE_SLACK) + 1, L)
		}
		got := base.pt_read(pt, pos, buf[:end - pos])
		if got == 0 {break}
		if pt.fault {
			pt.fault = false
			intrinsics.atomic_store(&s.fault, true)
			return
		}

		// Recompiled per block: compilation scales with the pattern, not the
		// file, so it stays negligible next to the scan itself.
		it, err := regex.create_iterator(string(buf[:got]), string(s.query), {.Case_Insensitive}, context.temp_allocator, context.temp_allocator)
		if err != nil {
			break // invalid pattern -> no matches
		}
		c := 0 // newline-tracking cursor, walked forward to each match
		for {
			if intrinsics.atomic_load(&s.cancel) {return}
			cap, _, ok := regex.match_iterator(&it)
			if !ok || len(cap.pos) == 0 {
				break
			}
			ms, me := cap.pos[0][0], cap.pos[0][1]
			for ; c < ms; c += 1 {
				if buf[c] == '\n' {last_nl = pos + c}
			}
			if !emit(s, &n, pos + ms, me - ms, last_nl + 1) {return}
		}
		for ; c < got; c += 1 {
			if buf[c] == '\n' {last_nl = pos + c}
		}
		pos += got
		intrinsics.atomic_store(&s.count, n)
		intrinsics.atomic_store(&s.scanned, min(pos, L))
		mem.dynamic_arena_free_all(&arena)
	}
	intrinsics.atomic_store(&s.count, n)
	intrinsics.atomic_store(&s.scanned, L)
	intrinsics.atomic_store(&s.done, true)
}

// --- navigation & replace ---

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
				// Clamp so the screen stays full. Scrolling to the match's index
				// directly meant a match near the end left the view showing the
				// last two or three lines with empty rows beneath.
				doc.filter_top = clamp(i, 0, max(0, len(doc.filter_lines) - max(1, doc.view_rows)))
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
// Each edit invalidates the search, but find_invalidate only marks it dirty, so
// this costs one restart at the end rather than one per match.
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

	it := visible_begin(doc, t, rows)
	n := 0
	for n < len(out) {
		row, start, end, _, ok := visible_next(&it)
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
