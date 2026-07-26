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
// `original`, atomics for done/cancel/fault, cancel-store-then-join on
// teardown — see that struct's comment for the rationale, which applies here
// unchanged.
//
// Deliberately does NOT mirror Line_Index's `guard` field. lex_index_start
// (below) refuses to run this index over mapped content at all, so a guarded
// copy-through-SEH path can never execute — and unlike Line_Index's worker
// (a flat byte scan, trivially chunked through a fixed 64 KiB buffer), this
// worker is LINE- and TOKEN-oriented: a guarded version would need to carry a
// partial line's bytes across chunk boundaries and re-enter the lexer
// mid-line, real machinery this index has no way to exercise or verify while
// the mapped gate stays shut. A prior revision kept a `guard` field anyway,
// "for structural parity" — but it hardcoded `guard = false` and the field
// was never anything but dead weight: its branch did `make([]u8, len(c))`, a
// whole-file HEAP allocation, which is exactly what a guarded read exists to
// avoid, and it would have fired the first time anyone loosened the mapped
// gate, unreviewed and untested. Deleted rather than half-fixed: build the
// real (chunked, carry-over) guarded path together with whatever change
// actually lifts the mapped restriction, so it can be designed and tested
// against the scenario that motivates it, not shipped speculatively now.
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
	// atomic: never set true today (no guarded copy path exists — see the
	// struct comment above). Kept, and checked in lex_index_valid, purely so
	// that struct doesn't need touching again if a future guarded path is
	// added; it costs one bool and one always-false branch.
	fault: bool,
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
	lexer, stateful, _, _ := highlight_lexer_for(doc.path)
	if !stateful || lexer == nil {return}
	if doc.fv.mapped {return}
	doc.lex_idx.content = doc.original
	doc.lex_idx.total = len(doc.original)
	doc.lex_idx.lexer = lexer
	doc.lex_idx.built_for_revision = doc.revision
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
	cur_lexer, _, _, _ := highlight_lexer_for(doc.path)
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

// Bound on how many textual anchor occurrences lex_resync_state will try
// against a validator before giving up (see that proc's comment). A window
// is already capped (64 KiB, or 4 KiB in filter mode), so this is a second,
// independent bound: a pathological file whose window is packed with "*/"
// occurrences (e.g. binary-ish data, or genuinely thousands of tiny
// comments) still can't turn validation into unbounded per-candidate work —
// once this many tries have failed, it's treated exactly like "the anchor
// was never found" (cap-hit, or byte 0 if reached).
//
// IMPORTANT 5 (2026-07 review): this bounds candidate COUNT, not candidate
// COST. Each candidate's validation reads up to RENDER_LINE_CAP (8 KiB) of
// the piece table (see the candidate loop below), so 256 candidates could
// read up to 2 MiB per call before this bound ever engages — reachable
// EVERY FRAME in filter mode, where this whole proc runs once per visible
// row (~3,000 rows/frame while filtering, per LEX_FILTER_RESYNC_WINDOW's own
// comment). That is real, previously UNINSTRUMENTED cost: this reaches
// outside the resync window lex_resync_state's own header comment claims
// ("visits at most window bytes"), and nothing incremented
// hl_resync_bytes_examined for it, so lexstatetest's window-bounded
// assertion passed regardless of how much the validation loop actually
// read. See LEX_RESYNC_MAX_VALIDATE_BYTES immediately below for the
// independent byte budget that closes this, and lex_resync_state's header
// comment for the corrected total-cost claim.
LEX_RESYNC_MAX_CANDIDATES :: 256

// Independent BYTE budget on the candidate-validation loop (see IMPORTANT 5
// above): stops the loop once this many bytes have been read for
// validation, regardless of how many candidates that was or how far below
// LEX_RESYNC_MAX_CANDIDATES the try count still is. Chosen as roughly the
// size of one normal (non-filter) resync window — a validated resync's
// worst-case total cost is therefore on the order of THREE windows (the
// anchor's own textual scan, this budget, and the forward lex), not the
// unbounded-in-practice 2 MiB the try-count bound alone allowed.
LEX_RESYNC_MAX_VALIDATE_BYTES :: 64 * 1024

// Total bytes lex_resync_state reads from the piece table, accumulated
// across calls: its backward anchor scan, its candidate-validation loop, and
// its forward walk -- the same three terms that proc's header comment names
// as its worst case, so the counter and the claim cover the same ground.
// (The forward walk was the only one counted originally; the other two were
// each added by the review that found the assertion depending on them was
// vacuous without them.) The counterpart to highlight.odin's
// hl_bytes_examined, but deliberately a SEPARATE counter rather than reusing
// that one: hl_bytes_examined is only ever touched inside highlight_row_spans,
// and lex_resync_state calls the lexer directly, never through
// highlight_row_spans — so extending highlighttest's viewport-proportional
// assertion to a stateful lexer without this counter would pass even if the
// resync scanned the whole file, because the assertion would be watching a
// path this code never runs through. Exists for lexstatetest to prove the
// resync's cost is bounded, not just by the forward walk but by the WHOLE
// proc — see IMPORTANT 5's history: a counter that only watched the forward
// walk is exactly what let the validation loop's cost go unnoticed the
// first time. Not touched by lex_index_worker (the background index) — that
// runs on its own thread, and a worker incrementing a plain global here
// would race the main thread's reads of it, the same reason
// hl_bytes_examined is main-thread-only today.
hl_resync_bytes_examined: int

// The Lex_State in effect at byte offset `at` for whichever lexer doc's path
// selects — .Normal at zero cost if that lexer isn't stateful. Otherwise: the
// background index if it is built, valid, and covers `at` (an O(log
// line_count) lookup — "always correct, instant" per the design doc); else
// the bounded resync, correct at any revision (including mid-edit) because it
// reads the LIVE piece table, just slower than the index.
//
// `at` need NOT be a logical line's start. lex_resync_state's forward walk
// (below) is target-relative, not line-start-relative, so it lexes correctly
// forward to any `at` — this is what lets doc_draw's contiguous-viewport
// bootstrap ask for the state at a RENDER_LINE_CAP-split continuation row's
// own start (mid-logical-line) rather than hunting for the true line start
// first (see doc_draw's comment on hl_state).
//
// The background index does NOT share that property, and this IS a known
// gap: it only records state before each raw newline-delimited line, so `at`
// landing inside a line longer than one RENDER_LINE_CAP chunk (rather than at
// one of the index's recorded line_starts) returns the state before that
// whole line, not the true state at `at`. In practice this only bites a
// SMALL (unmapped, indexed) file containing a single logical line longer
// than RENDER_LINE_CAP scrolled into its middle — a narrower case than the
// huge/mapped one this task's resync fix targets, since the index only
// exists at all for small files. Not fixed here: closing it means either
// making the index record RENDER_LINE_CAP-granularity split points too (more
// per-line-that-happens-to-be-huge bookkeeping) or having doc_lex_state_at
// notice `at` doesn't land on a recorded line_starts entry and fall through
// to resync in that case specifically. Flagging rather than leaving it
// implicit, same as this file's other documented trade-offs.
doc_lex_state_at :: proc(doc: ^Document, at: int, window: int) -> base.Lex_State {
	lexer, stateful, anchor, validate := highlight_lexer_for(doc.path)
	if !stateful || lexer == nil {return .Normal}
	if lex_index_valid(doc) && len(doc.lex_idx.line_starts) > 0 && at <= doc.lex_idx.total {
		return lex_index_lookup(&doc.lex_idx, at)
	}
	state, _ := lex_resync_state(doc, at, window, lexer, anchor, validate)
	return state
}

// Scan backward from `target` (any byte offset — need NOT be a logical
// line's start; see doc_lex_state_at's comment) up to `window` bytes for the
// end of `anchor` — a byte sequence whose completion is unambiguously
// .Normal for this lexer's grammar (see EXT_LEXERS's resync_anchor comment,
// highlight.odin) — then lex forward from there to `target`, threading state
// one (possibly partial, for the anchor's own line) RENDER_LINE_CAP-or-
// newline-delimited chunk at a time. Byte 0 is ALSO unambiguously .Normal on
// its own, so reaching it counts as finding an anchor even if the marker
// itself never occurs. The forward walk doesn't care whether `target` (or
// any chunk boundary it passes through) lines up with a real newline: it
// just keeps chunking until `pos` reaches `target`, which is what makes it
// safe to call with a synthetic RENDER_LINE_CAP split point as `target`.
//
// If the window is exhausted without finding the anchor and without
// reaching byte 0, that is a CAP HIT: bail to .Normal rather than guess
// further back or truncate the scan silently — the documented failure mode
// (a comment/string longer than `window` mis-colours until scrolled to its
// start). `cap_hit` is returned so a test can assert on it directly instead
// of inferring it from a wrong colour.
//
// The FORWARD-LEXING half of this proc is bounded to `window` bytes: the
// anchor (or byte 0) is found at or after target-window, so lexing from
// there to target visits at most `window` bytes of the buffer, regardless of
// the document's size.
//
// CORRECTED CLAIM (2026-07 review, IMPORTANT 5): an earlier version of this
// comment stopped there and said this proc "visits at most window bytes" —
// true of the forward walk alone, but false of the proc as a WHOLE once
// `validate` is non-nil. Each candidate the walk below tries reads up to
// RENDER_LINE_CAP (8 KiB) more from the piece table, entirely OUTSIDE
// `window`, up to LEX_RESYNC_MAX_CANDIDATES times — a real cost this
// comment used to claim couldn't exist, and hl_resync_bytes_examined used to
// not count at all, so lexstatetest's window-bounded assertion passed
// regardless of how much the validation loop actually read. Both are fixed
// now: the candidate loop is ALSO capped by total bytes read
// (LEX_RESYNC_MAX_VALIDATE_BYTES, independent of candidate count), and every
// byte it reads is tallied into hl_resync_bytes_examined too — see that
// counter's own comment. The real total worst case, honestly: `window`
// (anchor scan) + LEX_RESYNC_MAX_VALIDATE_BYTES (validation, only when
// `validate` is non-nil) + `window` (forward lex) — bounded, but no longer
// just `window`. All three terms are counted into hl_resync_bytes_examined
// now; the anchor scan was the last one still invisible to it, and it is the
// term that actually separates a small file from a huge one. hl_resync_bytes_examined is a separate counter from
// highlight_row_spans's hl_bytes_examined because this proc is called
// directly by doc_draw's bootstrap and by the filter view, never through
// highlight_row_spans, so nothing else would ever see this path's cost.
//
// `validate`, when non-nil, is consulted before ANY candidate occurrence of
// `anchor` is trusted (see Resync_Validate_Proc's comment, highlight.odin,
// and base.lex_c_resync_valid for the concrete C-family case this exists
// for). nil preserves the original behaviour exactly — trust the LAST
// textual occurrence in the window unconditionally — which is what every
// existing XML/HTML call site still gets, and is sound there only because
// Lex_State has nothing else "-->" could be catching (see EXT_LEXERS's
// comment, highlight.odin). With a validator, candidates are walked from the
// LAST occurrence backward, each checked against the single physical line
// that contains it, and the first (i.e. latest) one that validates wins —
// so a "*/" inside a string or line comment is skipped in favour of an
// earlier, real comment-close, rather than corrupting the resync.
//
// IMPORTANT 4 (2026-07 review): each candidate's physical line is located
// via pt_line_start_cap, which — on a line longer than RENDER_LINE_CAP —
// returns a scan FLOOR, not the true line start, and says so via its own
// `exact` return value. This proc used to discard that flag (`ls, _ :=`),
// so a front-truncated read got handed to `validate` as if it were the real
// line: a string/comment opener further back on the true line becomes
// invisible, and once the candidate sits >= RENDER_LINE_CAP bytes past the
// true start, the read buffer doesn't even reach the candidate at all —
// which made lex_c_resync_valid return true unconditionally (see that
// proc's own corrected comment). Fixed below: a candidate is now SKIPPED
// entirely (not validated, not accepted) whenever `exact` is false, exactly
// like "I cannot know" everywhere else in this fix.
lex_resync_state :: proc(
	doc: ^Document,
	target: int,
	window: int,
	lexer: Lexer_Proc,
	anchor: string,
	validate: Resync_Validate_Proc = nil,
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
	// The anchor scan's own read is a THIRD cost term, named in this proc's
	// header comment from the start and never instrumented: up to a full
	// window from the piece table plus an O(window * len(anchor)) backward
	// walk over it, per call. Bounded by construction (scan_len <= window),
	// but a guard-rail that cannot see the thing it guards is how the
	// candidate loop's cost went unnoticed (IMPORTANT 5 above), and it made
	// lexstatetest's "window-bounded, not file-bounded" check vacuous: it
	// asserted a small and a huge file examine EQUAL bytes, and they did --
	// because the one term that genuinely differs between them (a few hundred
	// bytes of scan versus a saturated 64 KiB window) was the term nothing
	// counted.
	hl_resync_bytes_examined += got
	scan := buf[:got]

	al := len(anchor)
	from := -1

	if validate == nil {
		// Original behaviour: the LAST occurrence in the window, trusted
		// unconditionally.
		found_at := -1
		scan_loop: for k := 0; k + al <= len(scan); k += 1 {
			for j := 0; j < al; j += 1 {
				if scan[k + j] != anchor[j] {continue scan_loop}
			}
			found_at = k + al
		}
		from = found_at
	} else {
		// Walk candidates from the last occurrence backward; the physical
		// line containing each one is read fresh (bounded to RENDER_LINE_CAP,
		// same cap the forward walk below already respects) so `validate`
		// sees real line content, not an arbitrary window-relative slice.
		tries := 0
		validate_bytes := 0 // IMPORTANT 5: independent byte budget, see LEX_RESYNC_MAX_VALIDATE_BYTES
		k := len(scan) - al
		// Declared once, outside the loop: pt_read below always fills exactly
		// `ln` bytes from index 0 and every read only ever looks at `lb[:ln]`,
		// so reusing the buffer across candidates is safe, and it avoids
		// re-zeroing an 8 KiB stack array up to LEX_RESYNC_MAX_CANDIDATES
		// times per call -- real weight in filter mode, where this whole
		// proc runs once per visible row.
		lb: [RENDER_LINE_CAP]u8
		cand_loop: for k >= 0 {
			match := true
			for j := 0; j < al; j += 1 {
				if scan[k + j] != anchor[j] {
					match = false
					break
				}
			}
			if match {
				tries += 1
				cand_start_abs := win_start + k
				cand_end_abs := win_start + k + al
				// IMPORTANT 4: `exact` false means `ls` is a scan FLOOR, not
				// the candidate's true physical line start -- validating
				// against that (possibly front-truncated, possibly not even
				// reaching the candidate at all) buffer is exactly how a
				// front-truncated read used to manufacture a false ACCEPT
				// (see base.lex_c_resync_valid's corrected comment). Skip
				// this candidate entirely rather than hand it a line it
				// cannot trust; the walk just tries an earlier occurrence.
				ls, exact := base.pt_line_start_cap(&doc.pt, cand_start_abs, RENDER_LINE_CAP)
				if exact {
					le := base.pt_line_end_cap(&doc.pt, ls, RENDER_LINE_CAP)
					ln := base.pt_read(&doc.pt, ls, lb[:min(le - ls, len(lb))])
					hl_resync_bytes_examined += ln // IMPORTANT 5: count validation reads too
					validate_bytes += ln
					if validate(lb[:ln], cand_end_abs - ls) {
						from = k + al
						break cand_loop
					}
				}
				if tries >= LEX_RESYNC_MAX_CANDIDATES || validate_bytes >= LEX_RESYNC_MAX_VALIDATE_BYTES {break cand_loop}
			}
			k -= 1
		}
	}

	if from < 0 {
		if win_start != 0 {return .Normal, true} // cap hit
		from = 0 // never found (or never validated) a marker, but byte 0 is unambiguous on its own
	}

	state = .Normal
	pos := win_start + from
	tok_buf: [HL_MAX_ROW_TOKENS]base.Token
	// A fixed stack buffer, not a context.temp_allocator make() per chunk: in
	// filter mode this loop runs once per visible row (LEX_FILTER_RESYNC_WINDOW
	// is small, but ~3,000 rows/frame while filtering is real), and a bounded
	// array reused across iterations costs nothing extra per chunk.
	lb: [RENDER_LINE_CAP]u8
	for pos < target {
		line_end := base.pt_line_end_cap(&doc.pt, pos, RENDER_LINE_CAP)
		if line_end > pos {
			n := base.pt_read(&doc.pt, pos, lb[:line_end - pos])
			_, state = lexer(lb[:n], state, tok_buf[:])
			hl_resync_bytes_examined += n
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
