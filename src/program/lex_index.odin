// Layer: program — the multi-line lexer-state machinery: a background
// per-line state index for small files, and a bounded backward resync for
// huge ones. See docs/superpowers/specs/2026-07-25-syntax-highlighting-design.md
// ("The hard problem") for why this exists at all: colouring the row at
// doc.top needs to know the lexer's state THERE, and doc.top can be any byte
// offset in a multi-GB file — lexing from byte 0 to find out would break the
// never-freeze rule outright.
package main

import "base:intrinsics"
import "core:thread"
import base "src:base"

// Background per-line lexer-state index for small files. Mirrors Line_Index
// (doc.odin:586) field-for-field and lifecycle-for-lifecycle: immutable
// `original`, atomics for done/cancel/fault, a guard flag for mapped content,
// cancel-store-then-join on teardown — see that struct's comment for the
// rationale, which applies here unchanged.
//
// Where it deliberately differs: Line_Index publishes a single running total
// that an edit can cheaply correct forward (nl_delta). A per-line STATE can't
// be patched that way — an edit invalidates every line's recorded state from
// the edit point on, not just a count — so this index is simply never
// trusted once `doc.revision` has moved past `built_for_revision` (see
// lex_index_valid) or the document's lexer has changed (a Save As across
// extensions). It is not rebuilt when that happens: doc_lex_state_at falls
// back to the bounded resync below instead, which reads through the LIVE
// piece table and is correct at any revision, just slower than an O(log n)
// lookup. A future task could add incremental rebuild; today "fall back to
// what the huge-file path already does" is the honest, simple answer.
Lex_State_Index :: struct {
	content:            []u8, // == doc.original; immutable, an edit never touches it
	total:              int,
	lexer:              Lexer_Proc, // which lexer these states were computed against
	built_for_revision: u64, // doc.revision at build time; a mismatch means stale
	scanned:            int, // atomic: bytes scanned so far (progress only, unused today)
	done:               bool, // atomic
	cancel:             bool, // atomic
	fault:              bool, // atomic: a guarded read faulted
	// Scan through the SEH guard, mirroring Line_Index.guard's purpose exactly.
	// Always false in the current build: lex_index_start refuses to run this
	// index over mapped content at all (see its comment) — huge/mapped files
	// use the resync path unconditionally instead. Kept, and checked in the
	// worker below, so a future change to that gating doesn't silently
	// reintroduce an unguarded read of memory that can be truncated out from
	// under the scan.
	guard: bool,
	th:    ^thread.Thread,

	// Published together, only meaningful once `done` is observed true: one
	// entry per source line, in ascending order by offset. line_starts[i] is
	// that line's byte offset in `content`; states[i] is the Lex_State
	// BEFORE line i's first byte (states[0] is always .Normal — byte 0 is
	// unambiguous). This costs more than Line_Index's bare counter: an int
	// AND a Lex_State per line, not zero extra bytes per line, because
	// unlike a running total, "the state at line N" cannot be recovered from
	// anything smaller than a per-line record — see the design doc's "must
	// stay one byte" note, which is about Lex_State itself, not this array.
	// Still bounded in practice: this index only exists for files under
	// plat.FILE_MMAP_THRESHOLD.
	line_starts: [dynamic]int,
	states:      [dynamic]base.Lex_State,
}

@(private = "file")
lex_index_worker :: proc(data: rawptr) {
	idx := (^Lex_State_Index)(data)
	c := idx.content
	priv: []u8
	if idx.guard {
		priv = make([]u8, len(c))
		if !base.safe_copy(priv, c) {
			intrinsics.atomic_store(&idx.fault, true)
			delete(priv)
			return
		}
		c = priv
	}
	defer if priv != nil {delete(priv)}

	tok_buf: [HL_MAX_ROW_TOKENS]base.Token
	state := base.Lex_State.Normal
	pos := 0
	for pos <= len(c) {
		if intrinsics.atomic_load(&idx.cancel) {return}
		append(&idx.line_starts, pos)
		append(&idx.states, state)
		nl := -1
		for k := pos; k < len(c); k += 1 {
			if c[k] == '\n' {
				nl = k
				break
			}
		}
		line_end := nl if nl >= 0 else len(c)
		_, state = idx.lexer(c[pos:line_end], state, tok_buf[:])
		intrinsics.atomic_store(&idx.scanned, line_end)
		if nl < 0 {break}
		pos = nl + 1
	}
	intrinsics.atomic_store(&idx.scanned, len(c))
	intrinsics.atomic_store(&idx.done, true)
}

// Lazily start the background index for `doc`, mirroring doc_index_start's
// call sites exactly (app_activate on first view, doc_reload after a
// discard-and-reopen) — same "don't spawn N threads restoring N tabs at
// once" reasoning. A no-op, cheap and repeatable, when the document's lexer
// isn't stateful (nothing to index) or the file is mapped (huge files never
// get this index; they always resync — the copy-vs-mmap threshold IS the
// small/huge split the design doc calls for).
lex_index_start :: proc(doc: ^Document) {
	if doc.lex_idx.th != nil {return}
	lexer, stateful, _ := highlight_lexer_for(doc.path)
	if !stateful || lexer == nil {return}
	if doc.fv.mapped {return}
	doc.lex_idx.content = doc.original
	doc.lex_idx.total = len(doc.original)
	doc.lex_idx.lexer = lexer
	doc.lex_idx.built_for_revision = doc.revision
	doc.lex_idx.guard = false // see the struct's comment: never mapped here
	doc.lex_idx.th = thread.create_and_start_with_data(&doc.lex_idx, lex_index_worker)
}

// Mirrors doc_index_done -- a poll helper so callers (headless test modes,
// a future status-bar hook) don't need their own atomic_load.
lex_index_done :: proc(doc: ^Document) -> bool {return intrinsics.atomic_load(&doc.lex_idx.done)}

lex_index_stop :: proc(doc: ^Document) {
	if doc.lex_idx.th == nil {return}
	intrinsics.atomic_store(&doc.lex_idx.cancel, true)
	thread.join(doc.lex_idx.th)
	thread.destroy(doc.lex_idx.th)
	doc.lex_idx.th = nil
}

// Whether doc.lex_idx can be trusted right now: built, finished, unfaulted,
// against the document's CURRENT revision and CURRENT lexer. Any edit (which
// bumps doc.revision) or a Save-As across extensions fails this — see the
// struct's comment for why that means "don't use it," not "rebuild it."
@(private = "file")
lex_index_valid :: proc(doc: ^Document) -> bool {
	idx := &doc.lex_idx
	if idx.th == nil {return false}
	if !intrinsics.atomic_load(&idx.done) {return false}
	if intrinsics.atomic_load(&idx.fault) {return false}
	if idx.built_for_revision != doc.revision {return false}
	cur_lexer, _, _ := highlight_lexer_for(doc.path)
	if cur_lexer != idx.lexer {return false}
	return true
}

// Binary search for the last recorded line whose start is <= offset, and the
// state before that line. Caller (doc_lex_state_at) guarantees the index is
// valid and non-empty and offset is in range before calling this.
@(private = "file")
lex_index_lookup :: proc(idx: ^Lex_State_Index, offset: int) -> base.Lex_State {
	lo, hi := 0, len(idx.line_starts) - 1
	for lo < hi {
		mid := (lo + hi + 1) / 2
		if idx.line_starts[mid] <= offset {
			lo = mid
		} else {
			hi = mid - 1
		}
	}
	return idx.states[lo]
}

// Resync windows. The normal contiguous viewport (doc.top downward) needs
// only ONE resync per frame — see doc_draw's bootstrap — so it can afford a
// generous window: a `<!-- -->` longer than this mis-colours until scrolled
// to (the documented failure mode; see lex_resync_state). The filter view
// needs a state resolved per VISIBLE ROW independently, because filtered
// rows are non-contiguous logical lines that can be arbitrarily far apart —
// at the normal window that would be O(rows * window), tens of MB per frame
// on a huge file in filter mode. So filtered rows get a much smaller window:
// bounded per-frame cost, traded against being more likely to bail to
// .Normal on a long comment. That trade is a documented limitation of the
// filter view on huge files, not something hidden — see task-3-report.md.
LEX_RESYNC_WINDOW :: 64 * 1024
LEX_FILTER_RESYNC_WINDOW :: 4 * 1024

// The Lex_State in effect at byte offset `at` (expected to be a logical
// line's start) for whichever lexer doc's path selects — .Normal at zero
// cost if that lexer isn't stateful. Otherwise: the background index if it
// is built, valid, and covers `at` (an O(log line_count) lookup — "always
// correct, instant" per the design doc); else the bounded resync, correct at
// any revision (including mid-edit) because it reads the LIVE piece table,
// just slower than the index.
doc_lex_state_at :: proc(doc: ^Document, at: int, window: int) -> base.Lex_State {
	lexer, stateful, anchor := highlight_lexer_for(doc.path)
	if !stateful || lexer == nil {return .Normal}
	if lex_index_valid(doc) && len(doc.lex_idx.line_starts) > 0 && at <= doc.lex_idx.total {
		return lex_index_lookup(&doc.lex_idx, at)
	}
	state, _ := lex_resync_state(doc, at, window, lexer, anchor)
	return state
}

// Scan backward from `target` (a byte offset, expected to be a logical
// line's start) up to `window` bytes for the end of `anchor` — a byte
// sequence whose completion is unambiguously .Normal for this lexer's
// grammar (see EXT_LEXERS's resync_anchor comment, highlight.odin) — then
// lex forward from there to `target`, threading state one (possibly
// partial, for the anchor's own line) line at a time. Byte 0 is ALSO
// unambiguously .Normal on its own, so reaching it counts as finding an
// anchor even if the marker itself never occurs.
//
// If the window is exhausted without finding the anchor and without
// reaching byte 0, that is a CAP HIT: bail to .Normal rather than guess
// further back or truncate the scan silently — the documented failure mode
// (a comment/string longer than `window` mis-colours until scrolled to its
// start). `cap_hit` is returned so a test can assert on it directly instead
// of inferring it from a wrong colour.
//
// Bounded to `window` bytes of forward lexing: the anchor (or byte 0) is
// found at or after target-window, so lexing from there to target visits at
// most `window` bytes of the buffer, regardless of the document's size.
lex_resync_state :: proc(
	doc: ^Document,
	target: int,
	window: int,
	lexer: Lexer_Proc,
	anchor: string,
) -> (
	state: base.Lex_State,
	cap_hit: bool,
) {
	if target <= 0 || len(anchor) == 0 {return .Normal, false}
	win_start := max(0, target - window)
	scan_len := target - win_start
	if scan_len <= 0 {return .Normal, false}

	buf := make([]u8, scan_len, context.temp_allocator)
	got := base.pt_read(&doc.pt, win_start, buf)
	scan := buf[:got]

	// Last occurrence of `anchor` in the scanned window, if any -- its END
	// position (index within `scan`) is where .Normal becomes provable.
	found_at := -1
	al := len(anchor)
	scan_loop: for k := 0; k + al <= len(scan); k += 1 {
		for j := 0; j < al; j += 1 {
			if scan[k + j] != anchor[j] {continue scan_loop}
		}
		found_at = k + al
	}

	from := 0
	if found_at >= 0 {
		from = found_at
	} else if win_start == 0 {
		from = 0 // never found the marker, but byte 0 is unambiguous on its own
	} else {
		return .Normal, true // cap hit
	}

	state = .Normal
	pos := win_start + from
	tok_buf: [HL_MAX_ROW_TOKENS]base.Token
	for pos < target {
		line_end := base.pt_line_end_cap(&doc.pt, pos, RENDER_LINE_CAP)
		if line_end > pos {
			lb := make([]u8, line_end - pos, context.temp_allocator)
			n := base.pt_read(&doc.pt, pos, lb)
			_, state = lexer(lb[:n], state, tok_buf[:])
		}
		nxt := line_end
		if nxt < doc.pt.length {
			one: [1]u8
			base.pt_read(&doc.pt, nxt, one[:])
			if one[0] == '\n' {nxt += 1}
		}
		if nxt <= pos {break} // never spin without making progress
		pos = nxt
	}
	return state, false
}
