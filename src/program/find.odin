// Layer: program — incremental find & replace. Literal (case-insensitive,
// ASCII-fold) or regex (core:text/regex over line-aligned blocks), scanned in
// blocks over the piece table. Small buffers scan inline; larger ones scan on a
// worker thread that publishes results incrementally, so a keystroke never waits
// on the file size. Replace reuses the doc's public edit path (undo + nl-delta
// handled). In regex mode the replacement understands .NET/JavaScript capture
// substitution ($1, ${12}, $&, $$) — see find_subst_wanted.
package main

import "base:intrinsics"
import "core:fmt"
import "core:mem"
import "core:text/regex"
import rx_common "core:text/regex/common"
import rx_vm "core:text/regex/virtual_machine"
import "core:strings"
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

// ...and how much of a LARGER buffer the calling thread scans before handing the
// rest to that worker, so the frame a keystroke produces already holds whatever
// the head of the file contains. The worker resumes from the byte this stopped
// on (Scan_State), so nothing is scanned or emitted twice.
//
// This is HANDOFF §6e's owed "pass 1" and the last thing owed against CLAUDE.md's
// "no frame ever shows emptiness". The filter view is what needs it: it renders
// filter_lines, so it has nothing at all to show until the search publishes, and
// a viewport-scoped pass cannot help it because the filtered list is not
// viewport-relative.
//
// THE BUDGET IS IN BYTES SCANNED AND IT IS SPENT WHETHER OR NOT ANYTHING WAS
// FOUND. "Scan until the screen is full" is the unbounded main-thread scan that
// roadmap item 1 removed -- a sparse query would walk a multi-GB file looking
// for a sixtieth row. A partly filled first frame is the accepted outcome; a
// frozen one is not.
//
// Bytes SCANNED, not bytes offered: a regex block runs on to the next newline,
// and that run-on is scanned too, so on this bounded pass it is reserved out of
// the budget rather than added on top of it (see scan_regex). It used to be added
// on top, which made "64 KB" mean 131073 bytes on a file with no newline in it.
// The regex path therefore covers ~48 KB of a first paint where the literal path
// covers the whole 64 KB; the number is the cost, not the reach.
//
// **The number came from the measurement below, and the first number was wrong.**
// `newtpad findtest`, section "--- the synchronous first-paint pass ---", times
// find_recompute over two 8 MB buffers -- 60-byte lines, and the same filler with
// no newline in it at all -- and fails the suite if any case exceeds a frame.
// What it prints at this budget, -o:speed (the debug build is ~1.4x worse and
// prints its own numbers from the same run):
//
//	                              60 B lines   no newlines
//	literal, ordinary                0.10 ms       0.10 ms
//	literal, matches constantly      0.11 ms       0.11 ms
//	regex, ordinary                  0.29 ms       0.36 ms
//	regex, scans every byte          2.39 ms       3.17 ms   <- [A-Za-z]+@[a-z]+
//	regex, backtracks hard           7.80 ms      10.98 ms   <- (the|fox|dog)+x
//
// The rejected candidate was 256 KB -- the tidy answer, and the one this was
// first written with, since it makes SEARCH_SYNC_MAX the only number in the file.
// Set the constant to 256 KB and the same test reprints itself as (worst
// fixture, -o:speed then debug):
//
//	regex, scans every byte         14.05 ms   /  20.89 ms
//	regex, backtracks hard          47.19 ms   /  63.47 ms
//
// i.e. 84% of a frame for a pattern a person might plausibly type to find email
// addresses, and nearly three frames for one that backtracks -- on every find
// keystroke, on every file over 256 KB, and a held key delivers two or three
// keystrokes into one frame.
//
// 64 KB is comfortable for the literal path (0.17 ms, 1% of a frame) and AT THE
// EDGE for the regex one: a deliberately backtracking pattern is ~11 ms -o:speed
// and ~15.5 ms in the debug build. If a first screen ever looks too thin in live
// use, the two moves are opposite and both defensible -- raise the LITERAL budget
// (it is nowhere near its own share), or cut the REGEX one (it is what sizes the
// single number). Either one makes this a second, kind-dependent bound to keep
// honest, which is why neither is here yet.
//
// What this is NOT is a bound on regex time in general: core:text/regex
// backtracks, so a pathological pattern is slow per byte at any budget. That
// exposure is pre-existing -- every buffer at or below SEARCH_SYNC_MAX is scanned
// inline whole, and each of the worker's blocks costs the same per byte -- and
// this deliberately does not widen it: below SEARCH_SYNC_MAX nothing changes, and
// above it the inline share is a fraction of one block.
//
// The handoff is also one more BLOCK BOUNDARY per file, so HANDOFF 6d's "a
// pattern spanning a block boundary won't match" gains one more instance. The
// literal path cannot lose a match across it: the block is read with the
// len(query)-1 overlap and the worker resumes at exactly the byte this pass
// stopped issuing from (findtest plants a straddler at SEARCH_FIRST_PAINT - 4).
// The regex path's boundary is a line end, so it carries the same caveat every
// other block already does -- except on the no-newline shape above, where the
// clamp puts it mid-line, which is what REGEX_LINE_SLACK has always meant on a
// file whose lines are longer than the slack.
SEARCH_FIRST_PAINT :: 64 << 10
#assert(SEARCH_FIRST_PAINT <= SEARCH_SYNC_MAX) // or a "small" buffer would be split

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
// Where a bounded pass stopped, so the next one continues instead of starting
// over. The inline first-paint pass and the worker are two passes over one scan:
// no byte is read twice and no match is emitted twice, which is why the budget
// costs nothing but the handoff. Both halves are asserted, and they need
// different instruments: the emitted-twice half by the match counts in findtest,
// the read-twice half by Search.swept -- a worker that starts over writes the
// same values to the same indices and is invisible in the results.
//
// Both scans advance `pos` a whole block at a time and count newlines over
// exactly the bytes they advance past, so `last_nl` and `nlines` are complete
// for everything below `pos` and a resume needs nothing else. Plain fields, not
// atomics: the inline pass has returned before the worker is created, and
// nothing on the main thread reads these while the worker runs.
Scan_State :: struct {
	pos:     int, // first byte not yet scanned
	n:       int, // matches emitted so far (the worker's private count)
	last_nl: int, // offset of the last newline before pos, -1 if there is none
	nlines:  int, // newlines passed before pos
	// The byte immediately before `pos`, carried across blocks.
	//
	// Whole-word needs the character on EITHER side of a match, and the one
	// before a match at a block's first byte lives in the previous block -- the
	// read buffer only overlaps forward (len(q)-1 bytes, so a match spanning the
	// boundary is found), never backward. Carrying one byte is cheaper than
	// re-reading and cannot be got wrong by a budget that ends mid-block.
	prev:    u8,
}

// Word characters, for whole-word matching. ASCII only, deliberately: the
// literal scanner works on bytes and folds with `lower`, so pretending to know
// where a word boundary falls in UTF-8 would be a promise the rest of the path
// does not keep. A non-ASCII byte is treated as a word character, which makes
// "cafe" not match inside "café" -- the conservative direction.
@(private = "file")
is_word_byte :: proc(c: u8) -> bool {
	return c == '_' || (c >= '0' && c <= '9') || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c >= 0x80
}

Search :: struct {
	view:       base.Piece_Table, // worker's private read view (worker only)
	at:         Scan_State, // resume point (see Scan_State)
	query:      []u8, // private copy; the find bar's buffer keeps mutating
	regex:      bool,
	case_sens:  bool,
	whole_word: bool,
	matches:    []int, // fixed MAX_MATCHES capacity, written by index
	match_len:  []int,
	line_start: []int, // line start of each match, computed here (see below)
	line_no:    []int, // 1-based line number of each match, counted in the same pass
	count:      int, // atomic: how many entries are published
	// The pattern would not compile. Atomic because the worker sets it and the
	// UI thread reads it once a frame, exactly like `fault`.
	bad_pattern: bool,
	scanned:    int, // atomic: how far the scan has reached, for progress
	// atomic: bytes the scans actually advanced over, ACCUMULATED across both
	// passes. scanned is a position and a resume-from-zero would simply retrace
	// it, so it cannot see one; this can, and "no byte is scanned twice" is
	// otherwise a performance claim with nothing checking it (findtest asserts
	// swept == pt.length once the search is done). One atomic add per 256 KB
	// block is the whole cost.
	swept:      int,
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
// The find bar's three mode chips, as rects. ONE geometry, consumed by the draw
// and by the click -- CLAUDE.md's rule, and the reason this exists at all: the
// chips were computed inside render_frame, so they were drawn to look like
// buttons and there was nothing to hit-test them against. A control that looks
// pressable and is not is worse than one that was never drawn.
Find_Toggle :: struct {
	label:  string,
	x, w:   f32,
	on:     bool,
	cmd:    Command_Id,
}

find_toggles :: proc(doc: ^Document, winw: f32, out: []Find_Toggle) -> []Find_Toggle {
	if doc == nil || !doc.find.active || len(out) < 3 {return out[:0]}
	f := &doc.find
	tw := sx(30)
	gap := sx(4)
	x := winw - sx(12) - 3 * (tw + gap)
	set := [3]Find_Toggle {
		{"Aa", 0, tw, f.case_sens, .Find_Toggle_Case},
		{"ab|", 0, tw, f.whole_word, .Find_Toggle_Word},
		{".*", 0, tw, f.regex, .Find_Toggle_Regex},
	}
	for t, i in set {
		out[i] = t
		out[i].x = x + f32(i) * (tw + gap)
	}
	return out[:3]
}

// The chip a click at (mx, my) landed on, or .None. The bar occupies its own
// strip at the top (doc_top_bar_h), and only the FIRST row carries the chips --
// the replace row below has no controls of its own.
find_toggle_at :: proc(doc: ^Document, winw, mx, my: f32) -> Command_Id {
	if doc == nil || !doc.find.active {return .None}
	row_h := sx(FIND_BAR_H_96)
	if my < CHROME_TOP || my >= CHROME_TOP + row_h {return .None}
	buf: [3]Find_Toggle
	for t in find_toggles(doc, winw, buf[:]) {
		if mx >= t.x && mx < t.x + t.w {return t.cmd}
	}
	return .None
}

// --- the replace row's action buttons ---

// One labelled button on the replace row, with the accelerator that runs it.
//
// The replace row shipped as two text fields and nothing else: no button, no
// verb, no key named anywhere on it. Wyatt, live use 2026-07-28: "Ctrl+H has no
// replace all button/keybind, also no explanation of what you're to do on this
// menu." The fix is not a tooltip -- it is the two actions, drawn where the
// thing they act on is, with their chords beside them the way every menu row
// already shows one.
//
// ONE geometry, exactly like Find_Toggle above and for the same reason. This
// struct carries the label origins too (`tx`, `ty`, `cx`), not just the box:
// find_actions is the only procedure in the program that computes a coordinate
// on this row, and the draw, the click, the hover fill and the pointer cursor
// all consume what it returns. A draw that positioned its own text would be a
// second producer, which is the shape HANDOFF 6j is a list of.
Find_Action :: struct {
	label:  string,
	chord:  string, // from command_chord: the keymap is the only place that knows
	x, y:   f32, // box origin
	w, h:   f32,
	tx, ty: f32, // label origin (ty is the baseline)
	cx:     f32, // chord origin, same baseline
	cmd:    Command_Id,
}

FIND_ACTION_PAD_96 :: f32(9) // inside a button, either side of its text
FIND_ACTION_GAP_96 :: f32(6) // between buttons
FIND_ACTION_EDGE_96 :: f32(12) // from the window's right edge
// Left margin the row keeps clear for "Replace: ..." even when nothing is typed
// into it. Below this the buttons are DROPPED rather than clipped or overlapped
// -- a button half off the window is a control the user can see and cannot
// press, and one drawn over the replace field is worse.
FIND_ACTION_MIN_LEFT_96 :: f32(150)

// The replace row's buttons, as boxes with their text already placed. Empty
// when the replace row is not on screen, or when the window is too narrow to
// hold them clear of the field (see FIND_ACTION_MIN_LEFT_96) -- so "is this
// drawn?" and "is this clickable?" are the same question at every width.
find_actions :: proc(doc: ^Document, t: ^plat.Text, winw: f32, out: []Find_Action) -> []Find_Action {
	if doc == nil || !doc.find.active || !doc.find.replace_mode || len(out) < 2 {return out[:0]}
	// A read-only view (table grid, full Preview) takes no caret and the mouse
	// press never reaches find_action_at -- ro_surface_swallows eats it in
	// main.odin. Refusing here, at the one producer of this row's geometry,
	// means the draw, the hover fill, the hand cursor and the hit-test all
	// agree in one change instead of four call sites separately guarding
	// against a control that looks live and does nothing. Split is NOT
	// included: doc_read_only_view deliberately excludes it because Split's
	// left half is the real editor.
	if doc_read_only_view(doc) {return out[:0]}
	cw := plat.text_char_width(t, UI_SMALL_PX)
	row_h := sx(FIND_BAR_H_96)
	pad := sx(FIND_ACTION_PAD_96)
	gap := sx(FIND_ACTION_GAP_96)
	set := [2]Find_Action {
		{label = "Replace", cmd = .Find_Replace_One},
		{label = "Replace All", cmd = .Find_Replace_All},
	}
	total := gap
	for &a in set {
		a.chord = command_chord(a.cmd)
		cells := len(a.label)
		if a.chord != "" {cells += 2 + len(a.chord)}
		a.w = f32(int(f32(cells) * cw + pad * 2 + 0.5)) // whole pixels: text is drawn from these
		a.h = f32(int(row_h - sx(12)))
		total += a.w
	}
	x := winw - sx(FIND_ACTION_EDGE_96) - total
	if x < sx(FIND_ACTION_MIN_LEFT_96) {return out[:0]}
	x = f32(int(x))
	y := f32(int(CHROME_TOP + row_h + (row_h - set[0].h) * 0.5))
	for a, i in set {
		out[i] = a
		out[i].x = x
		out[i].y = y
		out[i].tx = f32(int(x + pad))
		// Baseline inside the box, the same 0.35-of-the-size drop the find bar's
		// own rows use (main.odin's `fbase`), snapped so the glyphs land on whole
		// pixels rather than sampling between texels in the alpha atlas.
		out[i].ty = f32(int(y + a.h * 0.5 + UI_SMALL_PX * 0.35))
		out[i].cx = f32(int(x + pad + f32(len(a.label) + 2) * cw))
		x += a.w + gap
	}
	return out[:2]
}

// The button a click at (mx, my) landed on, or .None.
//
// Reads find_actions' boxes and nothing else -- no row arithmetic of its own,
// which is what stops it drifting from the draw when the bar moves again (it
// moved from the bottom of the window to the top earlier in this release, and
// twelve call sites had to follow).
find_action_at :: proc(doc: ^Document, t: ^plat.Text, winw, mx, my: f32) -> Command_Id {
	buf: [2]Find_Action
	for a in find_actions(doc, t, winw, buf[:]) {
		if mx >= a.x && mx < a.x + a.w && my >= a.y && my < a.y + a.h {return a.cmd}
	}
	return .None
}

find_toggle_regex :: proc(doc: ^Document) {doc.find.regex = !doc.find.regex;find_query_changed(doc)}
find_toggle_case :: proc(doc: ^Document) {doc.find.case_sens = !doc.find.case_sens;find_query_changed(doc)}
find_toggle_word :: proc(doc: ^Document) {doc.find.whole_word = !doc.find.whole_word;find_query_changed(doc)}

@(private = "file")
active_buf :: proc(doc: ^Document) -> ^[dynamic]u8 {
	return &doc.find.query if doc.find.field == 0 else &doc.find.replace
}

find_input_rune :: proc(doc: ^Document, r: rune) {
	bytes, n := utf8.encode_rune(r)
	append(active_buf(doc), ..bytes[:n])
	if doc.find.field == 0 {find_query_changed(doc)}
}

// Ctrl+V into whichever field has focus. Pure over the clipboard's text so the
// decision below can be driven headlessly -- the HWND read lives in the dispatch.
//
// ONE LINE ONLY, and this is a decision rather than a limitation. Both fields are
// a single row of the find bar: there is no second row to draw a newline onto, so
// pasting a multi-line clipboard would leave a query whose tail is invisible and,
// in the search field, one that matches nothing on a line-oriented scan. The
// first line is what a user copying a word out of the document meant, and it is
// what VS Code's find box takes too.
//
// THE SPLIT IS ON EITHER TERMINATOR, not on LF. It was `index_byte('\n')` plus a
// trailing-\r trim, which handles LF and CRLF and quietly fails on CR alone: a
// classic-Mac or old-Excel clipboard ("one\rtwo") has no LF at all, so the whole
// thing became one field value with a raw control byte inside it -- drawn as
// whatever the font has for U+000D and carried into the search pattern. Whichever
// terminator comes first ends the line; the \r trim stays for the CRLF case, where
// the split lands after the \r.
//
// AND IT IS CAPPED. find_input_rune is bounded by how fast a human types; a paste
// is bounded by the clipboard, and a copied log file is megabytes. Every byte
// appended to field 0 goes through find_query_changed, which restarts the search
// worker with the new pattern, so an uncapped paste hands a multi-megabyte pattern
// to the scan in one keystroke. Latency, not data loss -- but the cap costs a
// comparison, and the field cannot display a hundredth of what it admits anyway.
// Truncation backs off to a rune boundary so a clipped multi-byte character is
// never appended as a fragment.
FIND_PASTE_CAP :: 1024 // ~10x what the widest find bar can ever show

find_paste :: proc(doc: ^Document, s: string) {
	if doc == nil || !doc.find.active {return}
	line := s
	if i := strings.index_any(line, "\n\r"); i >= 0 {line = line[:i]}
	line = strings.trim_right(line, "\r")
	if len(line) > FIND_PASTE_CAP {
		n := FIND_PASTE_CAP
		for n > 0 && (line[n] & 0xC0) == 0x80 {n -= 1} // don't split a rune
		line = line[:n]
	}
	if len(line) == 0 {return}
	append(active_buf(doc), ..transmute([]u8)line)
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
	intrinsics.atomic_store(&s.swept, 0)
	intrinsics.atomic_store(&s.done, false)
	intrinsics.atomic_store(&s.cancel, false)
	intrinsics.atomic_store(&s.fault, false)
	// Cleared with every other per-search flag. Left set, one bad pattern would
	// mark every later search invalid -- including the corrected one the user
	// just typed, which is the moment it matters most.
	intrinsics.atomic_store(&s.bad_pattern, false)
	intrinsics.atomic_store(&s.truncated, false)
	s.at = {pos = 0, n = 0, last_nl = -1, nlines = 0, prev = 0} // scan from the top again
	s.total = doc.pt.length
	s.regex = doc.find.regex
	s.case_sens = doc.find.case_sens
	s.whole_word = doc.find.whole_word

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

	// One pass on this thread first, always, over the live tree — no view, no
	// thread. A buffer at or below SEARCH_SYNC_MAX is finished outright by it,
	// exactly as before; a larger one gets SEARCH_FIRST_PAINT bytes and leaves
	// s.at at the byte the worker picks up from. Either way the find_merge below
	// publishes what it found into this very frame. See SEARCH_FIRST_PAINT for
	// the budget and the measurement behind it.
	scan_all(s, &doc.pt, max(int) if doc.pt.length <= SEARCH_SYNC_MAX else SEARCH_FIRST_PAINT)
	if !intrinsics.atomic_load(&s.done) {
		if intrinsics.atomic_load(&s.fault) {
			// The mapping changed underneath the inline pass. doc_fault_pending
			// picks the flag up and recovers the document; handing the same
			// buffer to a worker would only fault it again. Nothing further is
			// coming, so say so rather than leave the UI polling (and find_wait
			// spinning) for a search that will never publish.
			intrinsics.atomic_store(&s.done, true)
		} else {
			s.view = base.pt_view(&doc.pt)
			s.th = thread.create_and_start_with_data(s, search_worker)
		}
	}
	find_merge(doc)
}

@(private = "file")
search_worker :: proc(data: rawptr) {
	s := (^Search)(data)
	// Unbounded: resumes at s.at.pos and runs to the end of the buffer.
	scan_all(s, &s.view, max(int))
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

	// `scanned` and `done` are read BEFORE `count`, and the order is load-bearing.
	// A scan stores count first and scanned/done after it, so a scanned read
	// taken first is always covered by the count read that follows. Taken the
	// other way round — or with `scanned` read where it is USED, with the whole
	// merge body in between — a merge sees a count from before a block and a
	// scanned from after it: a short prefix the jump below then treats as
	// complete up to the caret, so it picks the match above instead of the one
	// below. Measured, not theorised: reading them at the point of use put
	// findtest's auto-select section red in 3 runs out of 10.
	scanned := intrinsics.atomic_load(&s.scanned)
	done := intrinsics.atomic_load(&s.done)
	n := intrinsics.atomic_load(&s.count)
	f.truncated = intrinsics.atomic_load(&s.truncated)
	// Nothing new AND nothing owed. The auto-select below can be waiting on the
	// SCAN rather than on a result (see there), and the merge that finally makes
	// it eligible may carry no new matches at all — a single match above the
	// caret is published once and never again — so "no progress" is not on its
	// own a reason to return while the jump is still pending.
	if n == f.merged && f.jumped {return}

	if n != f.merged {
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
	}

	// Select the caret-nearest match exactly once per query. Re-running this on
	// every merge would yank the viewport around as later results arrive while
	// the user is still typing.
	// Never in filter view. The jump exists to bring the caret-nearest match on
	// screen while stepping through matches; in a filtered list the point is to
	// see all of them, so it must start and stay at the top. Setting `jumped` at
	// open was not enough — every keystroke restarts the search, and the restart
	// clears it.
	//
	// Reference the START of any selection, not the caret. Selecting a match
	// leaves the caret at its end, so re-running this after a toggle (Alt+R,
	// Ctrl+L) would pick the *next* match every time — the selection walked
	// forward one match per keypress.
	//
	// And not until the scan has actually reached the caret. Matches publish in
	// order, so a prefix that stops short of the caret CANNOT contain the match
	// below it: firing there picks the last match above the caret and locks it
	// in, which on screen is the viewport yanked to the top of a file the user
	// had scrolled into. That used to be masked rather than handled — the first
	// non-empty publication came from the worker's first 256 KB block — and the
	// bounded first-paint pass (SEARCH_FIRST_PAINT) exposed it by publishing a
	// 64 KB prefix first. So the wait is now explicit.
	//
	// Capped at SEARCH_BLOCK: a caret 200 MB down would otherwise hold the jump
	// until the whole file had been scanned, and a jump that lands seconds after
	// the keystroke is the very thing "once per query" exists to prevent. `done`
	// is the other way out, for a scan that ended early (a fault): pick from
	// whatever it managed to publish rather than never pick at all.
	from := min(doc.cursor, doc.anchor)
	reached := scanned >= min(from, SEARCH_BLOCK) || done
	if !f.jumped && n > 0 && !doc.filter && reached {
		f.jumped = true
		f.current = 0
		for m, i in f.matches {
			if m >= from {
				f.current = i
				break
			}
		}
		find_select_current(doc)
	}

	// Sticky copy for the status text. Guarded on n > 0, so a cleared array
	// during a restart cannot overwrite these with zero — the guard, not the
	// early return above, is what carries that: this is now also reached on a
	// merge with no new results while the jump is still pending.
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

// Bytes the two passes actually swept, which equals the buffer length exactly
// when the handoff worked. Test instrument; see Search.swept.
find_swept :: proc(doc: ^Document) -> int {
	return intrinsics.atomic_load(&doc.search.swept)
}

search_faulted :: proc(doc: ^Document) -> bool {
	return intrinsics.atomic_load(&doc.search.fault)
}

// The regex would not compile. Only meaningful in regex mode, and only once
// something has been typed -- a half-finished pattern is invalid on the way to
// being valid, and calling that an error while the user is still typing would
// paint the field red on almost every keystroke.
search_bad_pattern :: proc(doc: ^Document) -> bool {
	return doc.find.regex && len(doc.find.query) > 0 && intrinsics.atomic_load(&doc.search.bad_pattern)
}

// A background search worker is alive (or a restart is pending), so the main loop
// should keep polling for results rather than sleeping.
search_running :: proc(doc: ^Document) -> bool {
	return doc.search.th != nil || doc.find.dirty
}

// --- the scan itself (shared by the inline and worker paths) ---

// Scan `pt` for s.query from s.at, publishing after each block, and stop once
// `upto` bytes of the buffer have been covered — `max(int)` for "all of it".
// Tracks the most recent newline as it goes so every match carries its line
// start; that costs nothing here (the bytes are already in hand) and saves the
// main thread an unbounded backward scan per match at merge time.
//
// `done` is set only when the buffer really ran out, never when the budget did:
// find_recompute reads it to decide whether a worker is still needed, and
// find_wait spins on it.
@(private = "file")
scan_all :: proc(s: ^Search, pt: ^base.Piece_Table, upto: int) {
	if pt.length == 0 || len(s.query) == 0 {
		intrinsics.atomic_store(&s.done, true)
		return
	}
	if s.regex {
		scan_regex(s, pt, upto)
	} else {
		scan_literal(s, pt, upto)
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
scan_literal :: proc(s: ^Search, pt: ^base.Piece_Table, upto: int) {
	q := s.query
	L := pt.length
	// Folded copy, or the query as typed when the search is case-sensitive.
	ql := make([]u8, len(q))
	defer delete(ql)
	for i in 0 ..< len(q) {ql[i] = q[i] if s.case_sens else lower(q[i])}

	// Overlap by len(q)-1 so a match spanning a block boundary is still found.
	buf := make([]u8, SEARCH_BLOCK + len(q) - 1)
	defer delete(buf)

	// Resume where the last pass stopped. nlines counts newlines passed, so the
	// 1-based line number of a match is nlines+1. Counted here because the scan
	// is already walking every byte — deriving it later would mean re-scanning
	// the file per match.
	n, last_nl, nlines := s.at.n, s.at.last_nl, s.at.nlines
	prev := s.at.prev
	pos := s.at.pos
	halted := false // cancel / fault / MAX_MATCHES: nothing more to publish here
	ended := false // a read returned nothing: treat the buffer as exhausted
	scan: for pos < L && pos < upto {
		if intrinsics.atomic_load(&s.cancel) {
			halted = true
			break scan
		}
		// This pass's block, shortened when the budget ends inside one — so a
		// budget that isn't a multiple of SEARCH_BLOCK is the budget and not the
		// next multiple up.
		bs := min(SEARCH_BLOCK, upto - pos)
		got := base.pt_read(pt, pos, buf[:min(bs + len(q) - 1, L - pos)])
		if got == 0 {
			ended = true
			break scan
		}
		if pt.fault {
			pt.fault = false
			intrinsics.atomic_store(&s.fault, true)
			halted = true
			break scan
		}
		last := pos + bs >= L
		limit := got - len(q) + 1
		if !last {limit = min(bs, limit)}
		for k := 0; k < limit; k += 1 {
			hit := true
			for j in 0 ..< len(q) {
				c := buf[k + j] if s.case_sens else lower(buf[k + j])
				if c != ql[j] {
					hit = false
					break
				}
			}
			// Whole word: neither side may be a word character. The byte BEFORE
			// the match is buf[k-1] within this block, or the carried `prev` at
			// the block's first byte. The byte after is inside the forward
			// overlap; past what was read counts as a boundary, which is right
			// at end-of-file.
			if hit && s.whole_word {
				before := prev if k == 0 else buf[k - 1]
				after: u8 = 0
				if k + len(q) < got {after = buf[k + len(q)]}
				if is_word_byte(before) || is_word_byte(after) {hit = false}
			}
			// Check before updating last_nl: a match starting on a '\n' belongs
			// to the line that newline terminates, not the one it begins.
			if hit && !emit(s, &n, pos + k, len(q), last_nl + 1, nlines + 1) {
				halted = true // emit published count/done/truncated itself
				break scan
			}
			if buf[k] == '\n' {
				last_nl = pos + k
				nlines += 1
			}
		}
		// Carry the last byte this block covered, for the next block's k == 0.
		if bs > 0 && bs - 1 < got {prev = buf[bs - 1]}
		was := pos
		pos += bs
		intrinsics.atomic_add(&s.swept, min(pos, L) - was) // see Search.swept
		intrinsics.atomic_store(&s.count, n)
		intrinsics.atomic_store(&s.scanned, min(pos, L))
	}
	s.at = {pos = pos, n = n, last_nl = last_nl, nlines = nlines, prev = prev}
	if halted {return}
	intrinsics.atomic_store(&s.count, n)
	if ended || pos >= L {
		intrinsics.atomic_store(&s.scanned, L)
		intrinsics.atomic_store(&s.done, true)
	} else {
		intrinsics.atomic_store(&s.scanned, pos) // budget spent; a worker resumes
	}
}

@(private = "file")
scan_regex :: proc(s: ^Search, pt: ^base.Piece_Table, upto: int) {
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

	// Resume where the last pass stopped; see scan_literal for the same fields.
	n, last_nl, nlines := s.at.n, s.at.last_nl, s.at.nlines
	pos := s.at.pos
	halted := false // cancel / fault / MAX_MATCHES: nothing more to publish here
	ended := false // no bytes read, or an unusable pattern: the scan is over

	// A block runs on past its end to the next newline so that a line is never
	// split -- and THOSE BYTES ARE SCANNED TOO. On a bounded pass they therefore
	// have to come OUT of the budget rather than sit on top of it: pt_line_end_cap
	// returns pos+cap when it finds no '\n', so a file with no newline in its
	// first 128 KB (minified JSON, a single-line log dump) made a 65536-byte
	// budget read 131073 bytes -- twice the work the number was chosen against,
	// and on a backtracking pattern twice a frame. The reservation is taken once,
	// up front, so the loop keeps its whole-block shape instead of growing a tail
	// of ever-smaller blocks at the budget's edge.
	//
	// A quarter of the budget, capped at REGEX_LINE_SLACK: enough for any line a
	// log or a CSV has, and it scales if the budget is ever changed. The unbounded
	// worker pass is untouched -- it has no budget to overrun, and leaving its
	// block boundaries exactly where they were keeps every existing test's premise
	// about them true.
	slack := REGEX_LINE_SLACK
	target := upto // where blocks stop being issued
	if upto < L {
		slack = min(REGEX_LINE_SLACK, (upto - pos) / 4)
		target = upto - slack
	}
	scan: for pos < L && pos < target {
		if intrinsics.atomic_load(&s.cancel) {
			halted = true
			break scan
		}
		// Shortened when the budget ends inside a block (scan_literal has the
		// same line and the same reason). min(target, L) so max(int) can't
		// overflow the addition below.
		end := pos + min(SEARCH_BLOCK, min(target, L) - pos)
		if end < L {
			// Never split a line: run on to the next newline (bounded by the
			// slack reserved above), and keep that newline with its line so
			// end-of-line patterns still match. A partial line would give this
			// block's pattern a different answer than the resumed one.
			//
			// The clamp to `upto` is what makes the budget exact, and it bites
			// only on the no-newline shape -- where the block was ending mid-line
			// whatever we did, because there is no line end to find.
			end = min(base.pt_line_end_cap(pt, end, slack) + 1, L, upto)
		}
		got := base.pt_read(pt, pos, buf[:end - pos])
		if got == 0 {
			ended = true
			break scan
		}
		if pt.fault {
			pt.fault = false
			intrinsics.atomic_store(&s.fault, true)
			halted = true
			break scan
		}

		// Recompiled per block: compilation scales with the pattern, not the
		// file, so it stays negligible next to the scan itself.
		// Case-insensitivity used to be hardcoded here, so the Aa toggle did
		// nothing in regex mode -- a toggle that is drawn, labelled and inert.
		flags: regex.Flags
		if !s.case_sens {flags += {.Case_Insensitive}}
		it, err := regex.create_iterator(string(buf[:got]), string(s.query), flags, context.temp_allocator, context.temp_allocator)
		if err != nil {
			// Say so, rather than reporting "no matches" for a pattern that never
			// compiled. Those two look identical from the find bar and mean
			// completely different things: one is "your search found nothing",
			// the other is "your search is not a search yet".
			intrinsics.atomic_store(&s.bad_pattern, true)
			ended = true // invalid pattern -> no matches, and none are coming
			break scan
		}
		c := 0 // newline-tracking cursor, walked forward to each match
		for {
			if intrinsics.atomic_load(&s.cancel) {
				halted = true
				break scan
			}
			cap, _, ok := regex.match_iterator(&it)
			if !ok || len(cap.pos) == 0 {
				break
			}
			ms, me := cap.pos[0][0], cap.pos[0][1]
			// Whole word, applied to the regex path as a post-filter rather than
			// by wrapping the pattern in : the user's pattern is their own, and
			// splicing anchors into it changes what alternation and anchoring mean
			// ("a|b" becomes "a|b", which is not what anyone typed). Filtering
			// the RESULT asks the same question the literal path asks, with the
			// same is_word_byte, so both modes agree by construction.
			if s.whole_word {
				before: u8 = 0
				if ms > 0 {before = buf[ms - 1]} else if pos > 0 {before = s.at.prev}
				after: u8 = 0
				if me < got {after = buf[me]}
				if is_word_byte(before) || is_word_byte(after) {
					// Advance the newline cursor past it anyway, or the line
					// numbers of later matches in this block drift.
					for ; c < ms; c += 1 {
						if buf[c] == '\n' {
							last_nl = pos + c
							nlines += 1
						}
					}
					continue
				}
			}
			for ; c < ms; c += 1 {
				if buf[c] == '\n' {
					last_nl = pos + c
					nlines += 1
				}
			}
			if !emit(s, &n, pos + ms, me - ms, last_nl + 1, nlines + 1) {
				halted = true // emit published count/done/truncated itself
				break scan
			}
		}
		for ; c < got; c += 1 {
			if buf[c] == '\n' {
				last_nl = pos + c
				nlines += 1
			}
		}
		if got > 0 {s.at.prev = buf[got - 1]} // carried for whole-word at a block's first byte
		was := pos
		pos += got
		intrinsics.atomic_add(&s.swept, min(pos, L) - was) // see Search.swept
		intrinsics.atomic_store(&s.count, n)
		intrinsics.atomic_store(&s.scanned, min(pos, L))
		mem.dynamic_arena_free_all(&arena)
	}
	s.at = {pos = pos, n = n, last_nl = last_nl, nlines = nlines, prev = s.at.prev}
	if halted {return}
	intrinsics.atomic_store(&s.count, n)
	if ended || pos >= L {
		intrinsics.atomic_store(&s.scanned, L)
		intrinsics.atomic_store(&s.done, true)
	} else {
		intrinsics.atomic_store(&s.scanned, pos) // budget spent; a worker resumes
	}
}

// --- capture-group substitution in the replacement ---
//
// THE STANDARD IS .NET / JAVASCRIPT `String.replace`, which is what VS Code's
// find widget implements — the same reference the find bar's chips and its
// all-Alt toggles were built against, so a user who knows one knows the other.
// PCRE's `\1` was the other candidate and is rejected: backslash already means
// escape inside the PATTERN, and giving it a second meaning in the REPLACEMENT
// invites exactly the confusion this feature exists to remove.
//
//	$1 … $9   capture group n
//	$12       group 12 where the pattern has one, else group 1 then a literal 2
//	${12}     group 12, unambiguously — the escape hatch for the line above
//	$0, $&    the whole match
//	$$        a literal $
//	$x        literal, emitted as typed (and so is a trailing $)
//
// AN OUT-OF-RANGE OR UNSET GROUP SUBSTITUTES EMPTY, not an error. A pattern
// with an optional group legitimately produces an unset capture, and refusing
// the whole replace over one would be worse than the alternative — the same
// call .NET makes.
//
// How the captures are recovered, and why not by storing them: `Search` keeps
// matches as parallel arrays with no capture data, and adding some would cost
// MAX_MATCHES x groups x 2 ints on EVERY search whether or not a replacement
// ever reads one. Instead the pattern is re-matched at replace time, and only
// when the replacement actually references a group — find_subst_wanted decides
// that once, before the loop, so a plain replacement takes the byte-for-byte
// path it took before any of this existed.

// How far past a match the re-match window may reach. Bounds the per-match cost
// on a pathologically long line (a multi-GB single-line JSON dump); ordinary
// text stops at the line end long before this.
//
// 64, NOT 4096, AND THE DIFFERENCE IS A SECOND AND A HALF OF FROZEN UI. This is
// a per-match ceiling on a main-thread loop, and rx_vm.run walks the WHOLE window
// for every match, not just up to the match end: the injected opening (a `.*?`
// or a self-requeueing `Wait_For_*`) keeps a thread alive to the last byte, and
// `case .Match` breaks the thread loop rather than returning. So the cost of one
// substitution is O(window), and on a single-line file the window is always the
// full cap. Measured on the debug build, 100k matches on one 480 KB line
// (findtest's own fixture): 1423 ms at 4096, 362 ms at 64. The cap is the only
// term that moves, because everything else is per-match.
//
// Nothing reads past the match end except `$` and the trailing `\b`/`\B`, and
// both need exactly one byte — the newline the window now includes (see
// find_subst_one (3)). 64 leaves that an order of magnitude of slack for a line
// end that lands just past the match, at 1/64th of the ceiling.
REGEX_SUBST_TAIL :: 64

// Does this replacement reference a capture group at all?
//
// Deliberately over-inclusive rather than exact: every token starts with `$`
// followed by one of these four, so a false positive costs one regex run on a
// path the user explicitly invoked, while a false negative would silently write
// `$1` into the file. `$$` is in the set because it too expands (to one `$`).
find_subst_wanted :: proc(repl: []u8) -> bool {
	for i := 0; i + 1 < len(repl); i += 1 {
		if repl[i] != '$' {continue}
		c := repl[i + 1]
		if c == '$' || c == '&' || c == '{' || (c >= '0' && c <= '9') {return true}
	}
	return false
}

// Write `repl` into `out` with its `$` tokens expanded.
//
// `pos[g]` is group g's {start, end} within `src`, or a negative start when the
// group exists and did not capture. LEN(POS) IS LOAD-BEARING: it is the number of
// groups the pattern declares, plus one for the whole match, and it is the whole
// of how a group that did not capture is told apart from a group that does not
// exist. The two are NOT the same thing and the standards are explicit about it:
//
//   - .NET: "If number doesn't specify a valid capturing group in the pattern
//     ... $number is interpreted as a literal character sequence."
//   - ECMA-262 GetSubstitution: for `$n` with n greater than the group count, no
//     replacement is performed and the token stays literal; for a declared group
//     that is `undefined`, the empty String is used.
//
// So: INSIDE the range and unset -> empty; OUTSIDE it -> the characters as typed.
// The design doc originally specified empty for both, which was simply wrong
// about both standards it named, and meant `$5` against a two-group pattern
// deleted two bytes the user had typed instead of writing them.
//
// Pure: no document, no regex, no allocation beyond `out` — which is what lets
// findtest drive it directly with hand-written capture positions and check the
// token grammar on its own, separately from the re-match that produces those
// positions. Hand-written positions are also the only way to express an UNSET
// MIDDLE group: the engine's own `regex.Capture` compacts the -1 entries out and
// silently renumbers everything after them, which is why find_subst_one drives
// the VM directly rather than calling regex.match.
//
// A group's own text is copied out verbatim and never re-scanned, so a capture
// containing a `$` cannot introduce a second round of substitution.
find_subst_expand :: proc(repl: []u8, src: []u8, pos: [][2]int, out: ^[dynamic]u8) {
	// The pattern HAS this group (whether or not it captured). This, not `set`,
	// is what decides literal-versus-substitution.
	exists :: proc(pos: [][2]int, g: int) -> bool {
		return g >= 0 && g < len(pos)
	}
	set :: proc(pos: [][2]int, g: int) -> bool {
		return exists(pos, g) && pos[g][0] >= 0 && pos[g][1] >= pos[g][0]
	}
	emit :: proc(src: []u8, pos: [][2]int, g: int, out: ^[dynamic]u8) {
		if !set(pos, g) || pos[g][1] > len(src) {return} // declared but unset -> empty
		append(out, ..src[pos[g][0]:pos[g][1]])
	}
	i := 0
	for i < len(repl) {
		if repl[i] != '$' || i + 1 >= len(repl) {
			append(out, repl[i])
			i += 1
			continue
		}
		n := repl[i + 1]
		switch {
		case n == '$':
			append(out, '$')
			i += 2
		case n == '&':
			emit(src, pos, 0, out)
			i += 2
		case n == '{':
			// ${digits}. Anything else — no digits, a non-digit inside, no
			// closing brace, or digits naming a group the pattern does not have
			// — is not a group reference and is emitted as typed.
			j, v := i + 2, 0
			for j < len(repl) && repl[j] >= '0' && repl[j] <= '9' && j - i <= 8 {
				v = v * 10 + int(repl[j] - '0')
				j += 1
			}
			if j > i + 2 && j < len(repl) && repl[j] == '}' && exists(pos, v) {
				emit(src, pos, v, out)
				i = j + 1
			} else {
				append(out, '$')
				i += 1
			}
		case n >= '0' && n <= '9':
			// The longest run of digits that names a group THE PATTERN HAS,
			// falling back to fewer digits — .NET's and JavaScript's rule, and
			// the whole reason `${n}` exists. "$12" is group 12 in a pattern that
			// has one and group 1 followed by a literal 2 in a pattern that does
			// not. Existence, not capturedness: an optional group that did not
			// participate still consumes its digits and expands to nothing, or
			// `x(y)?z` with "[$1]" would emit "[$1]" on the lines where the
			// group is absent and "[y]" on the ones where it is not.
			j, v, best, best_end := i + 1, 0, -1, i + 2
			for j < len(repl) && repl[j] >= '0' && repl[j] <= '9' && j - i <= 8 {
				v = v * 10 + int(repl[j] - '0')
				j += 1
				if exists(pos, v) {best, best_end = v, j}
			}
			if best >= 0 {
				emit(src, pos, best, out)
				i = best_end
			} else {
				// No prefix names a group the pattern has. The whole token is
				// literal (.NET/ECMA-262 both), and emitting just the '$' gets
				// there: the digits fall through as ordinary bytes next pass.
				append(out, '$')
				i += 1
			}
		case:
			append(out, '$') // "$x" is literal
			i += 1
		}
	}
}

// A compiled pattern plus the memory the re-matches run in, held across one
// replace operation.
//
// TWO arenas, and the split is the point. core:text/regex allocates its
// per-match `saved` arrays from the ambient allocator and NEVER frees them
// (scan_regex carries the same note and the same fix), so every re-match must
// be able to drop its garbage — but the compiled program has to outlive all of
// them, or the pattern would be recompiled once per match. `pat` owns the
// program for the whole operation; `run` is reset before each match.
//
// Private arenas rather than context.temp_allocator because this runs on the
// main thread, where temp holds other live allocations for the frame — and in
// find_replace_all the expansions themselves live in temp across the whole loop.
Subst :: struct {
	live:    bool, // arenas initialised (find_subst_end is safe on a zero value)
	pat:     mem.Dynamic_Arena, // owns `re` for the whole operation
	run:     mem.Dynamic_Arena, // reset per match
	re:      regex.Regular_Expression,
	ok:      bool, // the pattern compiled; false means fall back to a literal splice
	ngroups: int, // capture groups the pattern declares, NOT counting the whole match
}

// How many capture groups the compiled pattern declares.
//
// This is the number find_subst_expand needs to tell `$2` against a two-group
// pattern (a group that exists and happens not to have captured -> empty) from
// `$5` against the same pattern (no such group -> the characters `$5`, literally,
// which is what .NET and ECMA-262 both specify). Collapsing the two was a real
// defect: a user typing `$5` had those two bytes silently deleted where VS Code,
// .NET and JavaScript would all have written them.
//
// Read off the PROGRAM rather than counted from the query text, and the
// difference matters: `\(` is not a group, `(?:` is not a group, and a query
// scanner would have to reimplement the tokenizer to agree with the thing that
// actually compiled. `compile` emits `Save 2*id` / `Save 2*id+1` per capturing
// group (compiler.odin), wrapping the whole match as group 0, so the highest Save
// operand halved IS the group count. `iterate_opcodes` is the engine's own walker
// and knows every operand width, so an operand byte can never be mistaken for an
// opcode.
find_subst_groups :: proc(program: []rx_vm.Opcode) -> int {
	hi := 0
	iter := rx_vm.Opcode_Iterator{program, 0}
	for op, pc in rx_vm.iterate_opcodes(&iter) {
		if op != .Save || pc + 1 >= len(program) {continue}
		if g := int(program[pc + 1]) / 2; g > hi {hi = g}
	}
	return min(hi, rx_common.MAX_CAPTURE_GROUPS - 1)
}

// `query` must be search.query — the pattern the published matches were found
// with, not whatever is in the find bar now.
find_subst_begin :: proc(sub: ^Subst, query: []u8, case_sens: bool) {
	mem.dynamic_arena_init(&sub.pat)
	mem.dynamic_arena_init(&sub.run)
	sub.live = true
	flags: regex.Flags
	if !case_sens {flags += {.Case_Insensitive}} // exactly scan_regex's flags
	a := mem.dynamic_arena_allocator(&sub.pat)
	re, err := regex.create(string(query), flags, a, a)
	if err != nil {return} // cannot happen with matches published; falls back to literal
	sub.re = re
	sub.ngroups = find_subst_groups(re.program)
	sub.ok = true
}

find_subst_end :: proc(sub: ^Subst) {
	if !sub.live {return}
	mem.dynamic_arena_destroy(&sub.run)
	mem.dynamic_arena_destroy(&sub.pat)
	sub^ = {}
}

// Expand `repl` for the match at [m, m+mlen) of `pt`, appending to `out`.
//
// THE ANCHOR TRAP, AND WHAT IS ACTUALLY DONE ABOUT IT. Re-matching a freshly
// copied slice of the matched bytes changes what `^`, `$` and `\b` can see, so
// a pattern like `\Bcat` would behave differently at replace time than it did
// at search time and the user would get a replacement for a match that was
// never really there. core:text/regex has no way to say "match starting exactly
// at this offset": every compiled program is a forward SCAN from wherever the VM
// is started, and the VM's `Assert_Start` is literally `sp == 0` of
// `Machine.memory` — there is no notion of text before the string. (The scan is
// spelled two ways, and it is worth being exact because the earlier version of
// this comment was not: `compile` first tries `optimize_opening`, and a pattern
// beginning with a literal byte/rune/class gets a `Wait_For_*` opcode instead —
// which re-queues itself on a mismatch and so scans forward too. Only when the
// opening is unpredictable, e.g. an alternation, is an unconditional `.*?`
// injected; a pattern opening with `^` gets neither.)
// So four things are done here instead, in descending order of how much they
// matter:
//
//  1. The window is read FROM THE PIECE TABLE and runs on to the end of the
//     match's line, so everything to the right of the match — which is what
//     greedy quantifiers, `$` and the trailing `\b` read — is the real document,
//     not a truncation at the match's last byte.
//  2. The window STARTS ONE BYTE BEFORE the match (whenever there is one) and
//     the VM is started at offset 1 inside it, with `current_rune` seeded to
//     that byte and `current_rune_size` left at 0 — exactly the state add_thread
//     reads when it seeds the first thread. That is what makes the LEADING `\b`
//     / `\B` see the real preceding byte. Seeding `current_rune` alone is NOT
//     enough and the test for it caught that: the VM's boundary check is
//     `sp > 0 && is_word_class(current_rune)`, so at offset 0 it decides there
//     is no left context whatever `current_rune` says. The byte has to actually
//     be in the string. (The scan runs the VM in byte mode — no .Unicode flag —
//     so the previous byte is the previous rune by construction.)
//  3. The window RUNS ONE BYTE PAST the line's last text byte whenever there is
//     one, i.e. it INCLUDES the '\n'. `$` compiles to `Assert_End`, which is
//     `sp == len(memory)` — a pure window-relative test — so a window ending at
//     the newline makes `$` TRUE at every ordinary line end, where the scan
//     (reading a 256 KB block that runs on past that newline) had it FALSE.
//     That is not the conservative direction and it is not rare: it fires on
//     every line. See the residual note below for what this does and does not
//     buy.
//  4. The result is VERIFIED: the captures are used only if the re-match lands
//     on exactly [at, at+mlen) of the window, i.e. reproduces the span the scan
//     published. If it does not, every group substitutes empty and `$0`/`$&`
//     still give the real matched bytes, which are known without matching
//     anything. Nothing is ever spliced from a match that was not reproduced.
//
// WHAT REMAINS, stated rather than glossed — and stated carefully, because the
// version of this comment that shipped claimed a safety property the code did
// not have. (4) alone is NOT enough: a span check accepts any route to the same
// span, so an alternation whose branches cover the same bytes — `(a)$|(a)` —
// can be resolved differently by the scan and by the re-match and hand back a
// DIFFERENT GROUP for a span that verified. (3) is what closes that for `$`;
// nothing closes it for `^`.
//
//   - `^` is still window-relative against the scan's block-relative one (the
//     flags carry no .Multiline, so `^` means start-of-block, not start-of-line).
//     A match at offset 0 of the buffer keeps it; everywhere else `^` is simply
//     false here. That direction only ever costs a match, so the worst case is a
//     rejection: `(^a)|(a)` at a block start reports group 2 where the scan
//     reported group 1. Genuinely rare — it needs the match to sit at a 256 KB
//     block boundary — which is why it is left alone.
//   - `$` is fixed for every line SHORT ENOUGH to reach its newline inside
//     REGEX_SUBST_TAIL. On a longer line the window still ends at a synthetic
//     cap break, so `$` is true there and the scan had it false. That cannot
//     write a wrong group — reaching the false end costs REGEX_SUBST_TAIL more
//     bytes than the published span, so (4) rejects it — but it does cost the
//     groups (they all come out empty while `$0`/`$&` stay right). Ordinary
//     text, source and config never see it; a minified single-line JSON with a
//     `$` in the pattern can.
//   - The engine has no lookaround at all, so that side of the trap does not
//     arise.
find_subst_one :: proc(sub: ^Subst, pt: ^base.Piece_Table, m, mlen: int, repl: []u8, out: ^[dynamic]u8) {
	ctx := context
	ctx.allocator = mem.dynamic_arena_allocator(&sub.run)
	ctx.temp_allocator = ctx.allocator
	context = ctx
	defer mem.dynamic_arena_free_all(&sub.run)

	// [w0, w1): one byte of left context (see (2)) and everything up to and
	// INCLUDING the newline that ends the match's line (see (3)), bounded by
	// REGEX_SUBST_TAIL so a multi-GB single-line file cannot turn one replacement
	// into a whole-file scan.
	at := 1 if m > 0 else 0
	w0 := m - at
	w1 := max(base.pt_line_end_cap(pt, m + mlen, REGEX_SUBST_TAIL), m + mlen)
	// ...AND ONE BYTE PAST IT, which is the whole of `$`'s correctness (see (3)).
	// pt_line_end_cap returns the offset OF the '\n', so without this the window
	// would end exactly where the line's text ends and `Assert_End` (`sp ==
	// len(memory)`) would be TRUE at a position where the scan -- reading a 256 KB
	// block that runs on past the newline -- had it FALSE. At end of buffer w1 is
	// already pt.length and there is nothing to add, which is also right: `$` is
	// true there in both.
	if w1 < pt.length {w1 += 1}
	win := make([]u8, max(w1 - w0, 0))
	win = win[:base.pt_read(pt, w0, win)]

	// `pos` is sized to the groups the pattern ACTUALLY DECLARES, not to the
	// engine's ceiling, because its length is what tells find_subst_expand a group
	// apart from a typo: an index inside it that never captured expands empty, one
	// past the end is not a group reference at all and stays literal. See
	// find_subst_groups.
	//
	// Group 0 is seeded from the offsets the scan published, so `$&` and `$0`
	// are right whatever the re-match does. Everything else starts unset.
	pos := make([][2]int, sub.ngroups + 1)
	for i in 0 ..< len(pos) {pos[i] = {-1, -1}}
	pos[0] = {at, min(at + mlen, len(win))}

	// `at < len(win)` is not belt and braces: rx_vm.run reads memory[sp] with
	// bounds checking off, so starting it at the very end of the window would
	// read past it. Only reachable from a zero-length match at end of buffer.
	if sub.ok && at < len(win) && len(win) >= at + mlen {
		vm := rx_vm.create(sub.re.program, string(win))
		vm.class_data = sub.re.class_data
		vm.string_pointer = at
		if at > 0 {
			vm.current_rune = rune(win[at - 1]) // see (2)
			// The SECOND thing add_thread's seed carries, and free to get right
			// while we are here. `Assert_Start_Multiline` is `sp == 0 ||
			// last_rune == '\n' || last_rune == '\r'`, so leaving last_rune at
			// zero would make `^` silently stop matching in the re-match the day
			// anyone adds .Multiline to scan_regex's flags. It never fires today
			// (the flag is never set, so the compiler emits Assert_Start), which
			// is exactly why it is worth one line now rather than a bug later.
			vm.last_rune = rune(win[at - 1])
		}
		// `false`, not a flag test: scan_regex never sets .Unicode, so the scan
		// itself runs in byte mode and matching in rune mode here would be the
		// divergence this whole procedure exists to avoid. UNICODE_MODE is a
		// compile-time parameter, so this has to be a literal either way.
		saved, ok := rx_vm.run(&vm, false)
		if ok && saved != nil && saved[0] == at && saved[1] == at + mlen { // (4)
			for g in 1 ..< len(pos) {
				a, b := saved[2 * g], saved[2 * g + 1]
				if a >= 0 && b >= a && b <= len(win) {pos[g] = {a, b}}
			}
		}
	}
	find_subst_expand(repl, win, pos, out)
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
	// BEFORE the edit, not inside doc_replace_sel's wake: doc_replace_sel ends in
	// find_invalidate -> search_stop, which frees search.query -- the pattern the
	// expansion has to be re-matched with.
	rep := find_replacement_for(doc, m, f.match_len[f.current])
	doc.anchor = m
	doc.cursor = m + f.match_len[f.current]
	doc_replace_sel(doc, rep) // handles an empty replacement as a delete
	find_recompute(doc)
}

// The bytes to splice in for the match at [m, m+mlen): f.replace as typed, or
// its `$` expansion when the search was a regex and the replacement references a
// group. The expansion is allocated from context.temp_allocator, so it outlives
// the Subst arenas it was copied out of and dies with the frame.
//
// The gate reads doc.search, not doc.find: the published matches were produced
// by search.query with search.case_sens, and the find bar's fields can already
// have moved on.
@(private = "file")
find_replacement_for :: proc(doc: ^Document, m, mlen: int) -> []u8 {
	f := &doc.find
	s := &doc.search
	if !s.regex || len(s.query) == 0 || !find_subst_wanted(f.replace[:]) {
		return f.replace[:] // the cheap path: byte-for-byte what it always was
	}
	sub: Subst
	find_subst_begin(&sub, s.query, s.case_sens)
	defer find_subst_end(&sub)
	if !sub.ok {return f.replace[:]}
	out := make([dynamic]u8, 0, len(f.replace) + 16, context.temp_allocator)
	find_subst_one(&sub, &doc.pt, m, mlen, f.replace[:], &out)
	return out[:]
}

// The indices of `matches` that Replace All will actually replace: the leftmost
// non-overlapping subset. `out` must be at least len(matches) long; returns how
// many entries were written.
//
// Its own procedure rather than a loop inside find_replace_all so the rule can
// be tested on inputs the scanner cannot easily be made to produce -- above all
// two ZERO-LENGTH matches at one offset, which regex mode can publish and which
// would otherwise insert the replacement there twice. The barrier advances by
// max(len, 1) for exactly that, which is the same rule a global regex replace
// uses everywhere else.
//
// `matches` is sorted ascending (both scans emit in order), which is what makes
// one forward pass with a single barrier sufficient.
find_keep_set :: proc(matches, lens: []int, out: []int) -> int {
	kept, next := 0, 0
	for m, i in matches {
		if i >= len(lens) || kept >= len(out) {break}
		if m < next {continue}
		out[kept] = i
		kept += 1
		next = m + max(lens[i], 1)
	}
	return kept
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
	s := &doc.search
	n := len(f.matches)
	complete = intrinsics.atomic_load(&doc.search.done) && !f.truncated
	if n == 0 {return 0, complete}

	// OVERLAPPING MATCHES ARE DROPPED BEFORE ANYTHING IS WRITTEN.
	//
	// The literal scanner steps one byte at a time, so it publishes overlapping
	// hits: "aa" over "aaaa" is three matches (0, 1, 2) covering four bytes, and
	// three replacements cannot fit in them. Applying all three last->first
	// spliced each one into the text the previous one had just written --
	// "aaaa" with "aa" -> "b" came out "b" where it should be "bb". The count
	// this proc returned was 3 and the document was wrong, which is the worst
	// available combination: the report agreed with the user's expectation while
	// the buffer did not.
	//
	// The kept set is chosen LEFT TO RIGHT, which is the order find_next steps
	// through matches and therefore the order the user would have watched them
	// being replaced one at a time -- so Replace All and repeated Enter produce
	// the same document. (Choosing right-to-left instead would be equally
	// "non-overlapping" and would disagree with the button next to it.)
	//
	// max(len, 1) advances the barrier past a ZERO-LENGTH match, which regex
	// mode can produce ("x*", an empty alternative). Without it, two empty
	// matches at the same offset both pass `>= next` and the replacement is
	// inserted there twice. This is the same rule a global regex replace uses
	// everywhere else for the same reason.
	keep := make([]int, n, context.temp_allocator)
	kept := find_keep_set(f.matches, f.match_len, keep)
	if kept == 0 {return 0, complete}

	// EVERY EXPANSION IS COMPUTED BEFORE THE FIRST SPLICE, IN MATCH ORDER,
	// AGAINST THE UNTOUCHED BUFFER. Two independent reasons, either one on its
	// own sufficient:
	//
	//   - the apply loop below runs last->first, so by the time it reaches match
	//     j every later match has already been rewritten -- and the re-match
	//     window runs on to the end of the match's line, so a window read down
	//     there would be reading text this very operation had just changed;
	//   - doc_replace_sel ends in find_invalidate -> search_stop, which FREES
	//     search.query. The pattern is gone after the first edit.
	//
	// One `blob` with one end offset per match, rather than a slice per match:
	// at MAX_MATCHES that is one allocation instead of a hundred thousand, and
	// the apply loop indexes it with the same j it already has.
	sub: Subst
	defer find_subst_end(&sub)
	blob: [dynamic]u8
	ends: []int
	use_sub := s.regex && len(s.query) > 0 && find_subst_wanted(f.replace[:])
	if use_sub {
		find_subst_begin(&sub, s.query, s.case_sens)
		use_sub = sub.ok
	}
	if use_sub {
		blob = make([dynamic]u8, 0, kept * (len(f.replace) + 8), context.temp_allocator)
		ends = make([]int, kept, context.temp_allocator)
		for j in 0 ..< kept {
			i := keep[j]
			find_subst_one(&sub, &doc.pt, f.matches[i], f.match_len[i], f.replace[:], &blob)
			ends[j] = len(blob)
		}
	}

	// Applied last->first so the offsets ahead of each edit are still the ones
	// the scan measured. Nothing is re-scanned in this pass, which is what makes
	// a replacement CONTAINING the search term terminate: "cat" -> "cat cat"
	// replaces the matches that existed when the button was pressed and stops,
	// rather than finding the ones it just wrote.
	doc_batch_begin(doc, .Replace)
	for j := kept - 1; j >= 0; j -= 1 {
		i := keep[j]
		m := f.matches[i]
		rep := f.replace[:]
		if use_sub {
			lo := 0 if j == 0 else ends[j - 1]
			rep = blob[lo:ends[j]]
		}
		doc.anchor = m
		doc.cursor = m + f.match_len[i]
		doc_replace_sel(doc, rep)
	}
	doc_batch_end(doc, kept)
	find_recompute(doc)
	return kept, complete
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
			// The row's hanging indent (§8), from the same producer the draw and
			// the click read -- a match highlight that ignored it would sit to the
			// left of the text it is supposed to be marking on a continuation row.
			ind := f32(row_indent_cells(doc, t, start, doc.view_cols)) * char_w
			sx := col_x(char_w, startcol, rhs) + ind
			ex := col_x(char_w, endcol, rhs) + ind
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

// The search that fills filter_lines has not finished: either the scan itself is
// still going, or an edit invalidated the results and the restart is pending.
//
// Deliberately NOT search_running: s.th stays non-nil after a worker finishes on
// its own (only search_stop nils it), so that one answers "should the main loop
// keep polling", which stays true for a while after the last result has landed.
// This one has to be able to say the search is over.
filter_searching :: proc(doc: ^Document) -> bool {
	return doc.find.dirty || !intrinsics.atomic_load(&doc.search.done)
}

// What the filter banner says. One producer, so the states it has to keep apart
// are something a test can hold rather than a format string inside render_frame.
//
// The middle state is the whole point. Filter view renders filter_lines, and an
// EMPTY filter_lines is two different facts: the search has not reached a match
// yet, or the file has none. This said "0 matching lines (searching...)" for
// both — so a query that genuinely matched nothing claimed to be searching
// forever, and a query whose first match sits 200 MB in looked exactly like one
// with no matches at all. The bounded first-paint pass (SEARCH_FIRST_PAINT)
// makes the second state far rarer; it cannot make it impossible, which is why
// the wording has to be honest rather than hopeful.
filter_banner_text :: proc(doc: ^Document) -> string {
	state: string
	switch {
	case doc_filtering(doc):
		state = fmt.tprintf("%d matching lines", len(doc.filter_lines))
	case len(doc.find.query) == 0:
		// Ctrl+L arms the filter before anything is typed; nothing is missing.
		state = "type to filter"
	case filter_searching(doc):
		state = "searching..."
	case:
		state = "no matching lines"
	}
	return fmt.tprintf("FILTER  %s   —   Ctrl+L shows the whole file", state)
}

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
//
// Leaving filter view also SPENDS the once-per-query auto-select, and that half
// is the one with a bug attached. find_merge gates the jump on !doc.filter, so a search
// that STARTED filtered (Ctrl+L, then type) has never fired it -- and the first
// merge after doc.filter goes false fires it, replacing the caret with a
// selection of a match somewhere else. main.odin runs that merge later in the
// very frame the click ran in, so find_filter_click's post-condition did not
// survive its own frame: click a filtered row while the search is still
// publishing, type one character, and it overwrites the matched word.
// Leaving filter view is itself a caret placement -- by the click, or by the
// user's own caret that Ctrl+L returns to -- so the jump is spent, not pending.
// (`.Filter_Open` already does this on the way in, for the same reason.)
find_set_filter :: proc(doc: ^Document, on: bool) {
	was := doc.filter
	doc.filter = on
	doc.filter_top = 0
	if was != on && block_active(doc) {block_clear(doc)}
	if was && !on {doc.find.jumped = true}
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
	case search_bad_pattern(doc):
		// UI spec 12: "Invalid regex is inline. The field's ring goes danger and
		// the reason replaces the count. Never a dialog, never silent." An
		// invalid pattern and a pattern with no matches look identical otherwise,
		// and they mean entirely different things.
		return " (invalid pattern)"
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
