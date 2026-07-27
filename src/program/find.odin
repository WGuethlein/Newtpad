// Layer: program — incremental find & replace. Literal (case-insensitive,
// ASCII-fold) or regex (core:text/regex over line-aligned blocks), scanned in
// blocks over the piece table. Small buffers scan inline; larger ones scan on a
// worker thread that publishes results incrementally, so a keystroke never waits
// on the file size. Replace reuses the doc's public edit path (undo + nl-delta
// handled). Group substitution ($1) is a follow-up.
package main

import "base:intrinsics"
import "core:fmt"
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
	line_no:    []int, // 1-based line number of each match, counted in the same pass
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
	find_query_changed(doc)
}

find_close :: proc(doc: ^Document) {
	doc.find.active = false
	doc.filter = false
	search_release(doc)
}

find_toggle_field :: proc(doc: ^Document) {doc.find.field = 1 - doc.find.field}
find_toggle_regex :: proc(doc: ^Document) {doc.find.regex = !doc.find.regex;find_query_changed(doc)}

@(private = "file")
active_buf :: proc(doc: ^Document) -> ^[dynamic]u8 {
	return &doc.find.query if doc.find.field == 0 else &doc.find.replace
}

find_input_rune :: proc(doc: ^Document, r: rune) {
	bytes, n := utf8.encode_rune(r)
	append(active_buf(doc), ..bytes[:n])
	if doc.find.field == 0 {find_query_changed(doc)}
}

find_backspace :: proc(doc: ^Document) {
	buf := active_buf(doc)
	if len(buf) == 0 {return}
	i := len(buf) - 1
	for i > 0 && (buf[i] & 0xC0) == 0x80 {i -= 1} // whole rune
	resize(buf, i)
	if doc.find.field == 0 {find_query_changed(doc)}
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
	delete(s.line_no)
	s.matches, s.match_len, s.line_start, s.line_no = nil, nil, nil, nil
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
		s.line_no = make([]int, MAX_MATCHES)
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
	clear(&doc.filter_line_nos)
	doc.filter_top = 0
}

// A query change invalidates the previous count; a buffer change (replace) does
// not. Deliberately not folded into find_recompute, which both call: keeping the
// last count across a replace is exactly what stops the flicker to zero.
@(private = "file")
find_query_changed :: proc(doc: ^Document) {
	doc.find.last_total = 0
	doc.find.last_current = -1
	find_recompute(doc)
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
			append(&doc.filter_line_nos, s.line_no[i]) // for the filter gutter
		}
	}
	f.merged = n

	// Select the caret-nearest match exactly once per query. Re-running this on
	// every merge would yank the viewport around as later results arrive while
	// the user is still typing.
	// Never in filter view. The jump exists to bring the caret-nearest match on
	// screen while stepping through matches; in a filtered list the point is to
	// see all of them, so it must start and stay at the top. Setting `jumped` at
	// open was not enough — every keystroke restarts the search, and the restart
	// clears it.
	if !f.jumped && n > 0 && !doc.filter {
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

	// Sticky copy for the status text. Reached only on real progress (the
	// n == f.merged guard above returns early otherwise), so a cleared array
	// during a restart cannot overwrite these with zero.
	//
	// After the jump block, not before it: search_reset clears f.current to -1
	// and f.jumped to false on every restart, so at the slice assignments above
	// f.current is still -1. When the whole result set publishes in one merge —
	// always true on the synchronous path — copying there froze last_current at
	// -1 and the bar read "(0/N)" for the rest of the busy window.
	if n > 0 {
		f.last_total = n
		f.last_current = f.current
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

// A background search worker is alive (or a restart is pending), so the main loop
// should keep polling for results rather than sleeping.
search_running :: proc(doc: ^Document) -> bool {
	return doc.search.th != nil || doc.find.dirty
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
emit :: proc(s: ^Search, n: ^int, at, length, line_start, line_no: int) -> bool {
	s.matches[n^] = at
	s.match_len[n^] = length
	s.line_start[n^] = line_start
	s.line_no[n^] = line_no
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

	// nlines counts newlines passed, so the 1-based line number of a match is
	// nlines+1. Counted here because the scan is already walking every byte —
	// deriving it later would mean re-scanning the file per match.
	n, last_nl, nlines := 0, -1, 0
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
			if hit && !emit(s, &n, pos + k, len(q), last_nl + 1, nlines + 1) {return}
			if buf[k] == '\n' {
				last_nl = pos + k
				nlines += 1
			}
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

	n, last_nl, nlines := 0, -1, 0
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
				if buf[c] == '\n' {
					last_nl = pos + c
					nlines += 1
				}
			}
			if !emit(s, &n, pos + ms, me - ms, last_nl + 1, nlines + 1) {return}
		}
		for ; c < got; c += 1 {
			if buf[c] == '\n' {
				last_nl = pos + c
				nlines += 1
			}
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
	// Bypasses set_cursor -- jumping to a find match must drop a stale
	// rectangle the same way a plain caret move does.
	if block_active(doc) {block_clear(doc)}
	if doc.filter { // keep the current match's line in the filtered view
		mls := base.pt_line_start(&doc.pt, m)
		for fl, i in doc.filter_lines {
			if fl == mls {
				// Clamp so the screen stays full. Scrolling to the match's index
				// directly meant a match near the end left the view showing the
				// last two or three lines with empty rows beneath.
				doc.filter_top = clamp(i, 0, doc_filter_max_top(doc, doc.view_rows))
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
//
// block_clear first: this mutates the buffer at the match's own offsets, not
// at a rectangle's, so a live column selection is describing rows this edit
// is about to shift underneath it. `.Find_Confirm` (commands.odin) is NOT in
// command_mutates_doc -- the dispatcher's own stale-rectangle guard never
// runs for it -- and command_dispatch is not this proc's only caller anyway
// (test_modes.odin calls find_replace_current directly, bypassing dispatch
// entirely). The genuine choke point is here, not the dispatcher: every path
// that can reach a buffer mutation through find must go through one of these
// two procs, so clearing here is the one place that actually guarantees it.
find_replace_current :: proc(doc: ^Document) {
	if block_active(doc) {block_clear(doc)}
	f := &doc.find
	if f.current < 0 || f.current >= len(f.matches) {
		return
	}
	m := f.matches[f.current]
	doc.anchor = m
	doc.cursor = m + f.match_len[f.current]
	doc_replace_sel(doc, f.replace[:]) // handles an empty replacement as a delete
	find_recompute(doc)
}

// Replace every match. Applied last->first so earlier offsets stay valid.
// Each edit invalidates the search, but find_invalidate only marks it dirty, so
// this costs one restart at the end rather than one per match.
//
// One undo entry for the whole operation, which is both what every other editor
// does and a correctness requirement here: per-match entries overflowed
// UNDO_MAX on any large replace and took the pre-replace state with them.
// `complete` is false when this pass could not have seen every match: the worker
// publishes incrementally and stops at MAX_MATCHES, so the list may be a prefix.
// Replacing a prefix is legitimate -- running it again continues -- but doing it
// silently was indistinguishable from replacing everything, which is how a user
// ends up believing a rename is finished when it is not.
//
// block_clear first, unconditionally, before even the n==0 check -- see
// find_replace_current's own comment for why this proc (not the dispatcher)
// is the genuine choke point. This one matters more: find_merge's own
// jump-to-match logic (find.odin, find_select_current) happens to clear a
// live block as a side effect of selecting the caret-nearest match after
// find_recompute below -- but ONLY when matches remain. Replace All is the
// one operation guaranteed to remove the very matches it just replaced, so
// the case that most needs the drop is exactly the case the incidental path
// does not cover: a Replace All that leaves zero matches never calls
// find_select_current at all, and the rectangle -- still naming rows the
// replacement has since moved -- survives to eat whatever Ctrl+X or the next
// keystroke touches next.
find_replace_all :: proc(doc: ^Document) -> (replaced: int, complete: bool) {
	if block_active(doc) {block_clear(doc)}
	f := &doc.find
	n := len(f.matches)
	complete = intrinsics.atomic_load(&doc.search.done) && !f.truncated
	if n == 0 {return 0, complete}
	doc_batch_begin(doc, .Replace)
	for i := n - 1; i >= 0; i -= 1 {
		m := f.matches[i]
		doc.anchor = m
		doc.cursor = m + f.match_len[i]
		doc_replace_sel(doc, f.replace[:])
	}
	doc_batch_end(doc, n)
	find_recompute(doc)
	return n, complete
}

// Highlight rectangles for visible matches (dim; behind text and the selection).
find_match_rects :: proc(doc: ^Document, t: ^plat.Text, px, char_w: f32, rows: int, out: []plat.Quad) -> int {
	f := &doc.find
	if !f.active || len(f.matches) == 0 {
		return 0
	}
	col := g_theme[.Find_Match_Bg]
	lh := line_height(px)

	mi := 0
	for mi < len(f.matches) && f.matches[mi] < doc.top {mi += 1}

	it := visible_begin(doc, t, rows)
	n := 0
	for n < len(out) {
		row, start, end, vis_end, _, wrapped, ok := visible_next(&it)
		if !ok {break}
		ry := row_rect_y(px, row)
		rhs := 0 if wrapped else H_SCROLL
		for mi < len(f.matches) && f.matches[mi] <= end && n < len(out) {
			m := f.matches[mi]
			startcol := min(line_cell_col(doc, t, start, max(m, start)), VISIBLE_COLS)
			endcol := min(line_cell_col(doc, t, start, min(m + f.match_len[mi], vis_end)), VISIBLE_COLS)
			sx := col_x(char_w, startcol, rhs)
			ex := col_x(char_w, endcol, rhs)
			out[n] = {pos = {sx, ry}, size = {max(ex - sx, 2), lh}, color = col}
			n += 1
			mi += 1
		}
	}
	return n
}

// --- scrollbar match marks ---

// Tick height, at 96 DPI. Two pixels, not one: sx() rounds and a one-pixel mark
// on a 150% display stays one pixel, which reads as a rendering artifact rather
// than as a mark.
MATCH_MARK_H_96 :: f32(2)

// The y of the tick for a match at byte `offset`, in window pixels.
//
// One producer for the mapping, and deliberately the SAME arithmetic the
// scrollbar thumb uses (render_frame: CHROME_TOP + doc.top/total * sb_h),
// including the same shape of clamp that keeps the thumb from running off the
// bottom of the track. That is the whole reason this feature is cheap: the bar
// is byte-proportional (HANDOFF 6b), so no line index is involved and a mark's
// position is a division. If the thumb's mapping ever changes, this must change
// with it or a tick will sit somewhere the thumb never travels.
//
// `total` is pt.length, so `offset == total` is a legal input and lands flush
// with the bottom of the track rather than one mark-height past it. Offsets
// outside [0, total] are clamped rather than trusted: between an edit and the
// next find_merge, f.matches still holds offsets measured against the buffer as
// it was, and one of them can exceed the buffer as it now is.
find_mark_y :: proc(offset, total: int, track_top, track_h, mark_h: f32) -> f32 {
	if total <= 0 {return track_top}
	frac := clamp(f64(offset) / f64(total), 0, 1)
	return clamp(track_top + f32(frac * f64(track_h)), track_top, track_top + track_h - mark_h)
}

// How many quads find_mark_rects can possibly emit for this track, and 0 when
// it would emit none.
//
// Both halves are load-bearing. The 0 lets the caller skip the per-frame
// allocation entirely when the find bar is shut or the query found nothing --
// which is almost every frame. The bound is what makes the buffer safe: marks
// are bucketed and the y is clamped into [track_top, track_top + track_h -
// mark_h], so the number of DISTINCT buckets cannot exceed the number of
// buckets in the track however many matches there are. A 200 MB log at
// MAX_MATCHES emits one quad per occupied bucket, not 100,000 quads. The +2
// covers the two truncations (track_top and the clamped bottom both rounding
// into their own bucket).
find_mark_cap :: proc(doc: ^Document, track_h: f32) -> int {
	if doc == nil || !doc.find.active || len(doc.find.matches) == 0 || doc.pt.length <= 0 {return 0}
	if track_h <= 0 {return 0}
	return min(int(track_h) + 2, plat.MAX_QUADS)
}

// Height of one bucket, in pixels.
//
// One pixel on every display that exists: quads_draw clamps a call to
// plat.MAX_QUADS (4096) instances, so a track taller than that would have its
// last marks silently dropped -- a bounded pass reporting a confident wrong
// answer, the shape that keeps recurring here (docs/development-loop.md 4).
// Rather than leave that as a comment about how tall a window can be, the
// bucket grows so the count cannot: at any real height this returns 1 and the
// bucketing is exactly per-pixel-row, and past ~4000 px of track it coarsens
// instead of losing marks off the bottom.
@(private = "file")
mark_bucket_h :: proc(track_h: f32) -> f32 {
	return f32(int(max(track_h, 0)) / (plat.MAX_QUADS - 2) + 1)
}

// One quad per occupied pixel row of the scrollbar track (see mark_bucket_h for
// the one case where a bucket is taller than a pixel), from however many matches
// are published right now.
//
// The bucketing is the point, not a nicety: quads_draw takes a slice per call
// and a 200 MB log with 50,000 matches would otherwise put 50,000 instances on
// a bar a few hundred pixels tall, every frame, to draw a few hundred distinct
// pixels. f.matches is sorted ascending and find_mark_y is monotonic in the
// offset, so the rows come out in order and collapsing them costs one integer
// compare against the last row emitted -- no set, no allocation.
//
// `partial` reports that the published set is a prefix (MAX_MATCHES saturated;
// HANDOFF 6e). Nothing is drawn differently for it and that is a decision, not
// an omission: the find bar's counter already appends "+" for exactly this
// state (find_status_info), the bar is on screen whenever these marks are --
// both require find.active -- and a second, wordless convention on the track
// would be the same sentence in a language the user has not been taught. It is
// returned so the caller and matchmarkstest can see the state rather than
// having to infer it from the mark count.
find_mark_rects :: proc(doc: ^Document, x, w, track_top, track_h: f32, out: []plat.Quad) -> (n: int, partial: bool) {
	if doc == nil {return 0, false}
	f := &doc.find
	partial = f.truncated
	if !f.active || len(f.matches) == 0 || doc.pt.length <= 0 || track_h <= 0 {return 0, partial}

	col := g_theme[.Match_Mark]
	mark_h := sx(MATCH_MARK_H_96)
	bucket := mark_bucket_h(track_h)
	last_row := min(i32)
	for m in f.matches {
		if n >= len(out) {break} // unreachable at find_mark_cap's size; see its comment
		y := find_mark_y(m, doc.pt.length, track_top, track_h, mark_h)
		row := i32((y - track_top) / bucket)
		if row == last_row {continue}
		last_row = row
		out[n] = {pos = {x, y}, size = {w, mark_h}, color = col}
		n += 1
	}
	return n, partial
}

// --- the filter view ---

// Turn the filter view on or off.
//
// One path, so "leaving filter mode" means exactly one thing wherever it is
// reached from -- the Ctrl+L command and find_filter_click below. A second
// teardown beside this one is how the two drift apart on what has to be reset.
//
// The block_clear is the half that is easy to leave out. A rectangle made before
// the toggle names rows by the buffer's own logical lines (block.odin never
// walks the filtered view), which is a different, non-contiguous set of rows the
// instant filter view turns on -- and, coming back the other way, a rectangle
// built while filtered would name rows the unfiltered document interleaves with
// everything between them. block_extend already refuses to CREATE a rectangle
// while doc.filter is set; this is the other half: drop one that already exists
// rather than let it silently edit rows the user can no longer see. block.odin's
// own edit paths refuse under doc.filter too (belt and braces), but this is the
// one place that actually removes the stale selection the user would otherwise
// still see highlighted. Gated on the state actually changing so that setting
// the filter to what it already is stays a no-op.
find_set_filter :: proc(doc: ^Document, on: bool) {
	was := doc.filter
	doc.filter = on
	doc.filter_top = 0
	if was != on && block_active(doc) {block_clear(doc)}
}

// A press in the filter view jumps to the line it landed on, in the unfiltered
// document (HANDOFF 6h item 2). Reports whether it did: false means the press
// fell on the empty area past the last matching row, where there is no line to
// jump to and the caller must not fall through to placing a caret in a view it
// is about to leave.
//
// `mx` is taken and deliberately unused. A filter row is chosen by its ROW
// alone, so a press in the line-number gutter selects the same line as a press
// in the text -- which is the assertion (findtest) that goes red the moment
// anyone reintroduces an x -> column step here, e.g. by reaching for doc_pos_at,
// whose answer is an offset INTO the row rather than the line start this jumps
// to. Taking the parameter is what lets the test press at both x positions and
// demand the same answer.
find_filter_click :: proc(doc: ^Document, t: ^plat.Text, mx, my, px: f32, rows: int) -> bool {
	ls, hit := doc_filter_line_at(doc, t, my, px, rows)
	if !hit {return false}
	doc.cursor, doc.anchor = ls, ls
	// Leaves filter mode through the one path (which also drops a live
	// rectangle). The caret is brought on screen by the main loop's existing
	// doc_ensure_cursor_visible, which fires because the cursor moved on this
	// tab this frame and doc.filter is now false.
	find_set_filter(doc, false)
	return true
}

// --- the find bar's status text ---

// The trailing "(current/total)" the find bar draws after the query.
//
// Extracted from render_frame so the "+" that marks an incomplete result set
// has exactly one producer. The scrollbar match marks are drawn from the same
// partial list and deliberately add no second indicator of their own, so this
// string is the only thing on screen saying the set is a prefix -- which makes
// it something a test can hold the marks against instead of a comment.
find_status_info :: proc(doc: ^Document) -> string {
	f := &doc.find
	switch {
	case len(f.query) == 0:
		return ""
	case len(f.matches) > 0:
		// "+" marks a partial result: we stopped at the match limit, so there
		// may be more further down the file.
		return fmt.tprintf(" (%d/%d%s)", f.current + 1, len(f.matches), "+" if f.truncated else "")
	case search_running(doc) && f.last_total > 0:
		// Mid-restart after an edit: the matches are cleared but the search is
		// still running, so the last published figure is the honest one. Saying
		// "(no matches)" here made every replace flicker to zero.
		return fmt.tprintf(" (%d/%d%s)", f.last_current + 1, f.last_total, "+" if f.truncated else "")
	case search_running(doc):
		return ""
	}
	return " (no matches)"
}
