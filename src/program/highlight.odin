// Layer: program — dispatch from a document's file extension to a base-layer
// lexer, and the map from a lexer's Token_Kind to this layer's Color_Role.
//
// Both tables are DATA — an extension list, an indexed switch that is really
// just a lookup table — never a decision tree that grows a branch per lexer.
// See CLAUDE.md's "commands declared once" rule for [Command_Id]Command; the
// same shape applies here, just without the #assert-on-length machinery
// (there is no fixed "one entry per lexer" invariant to violate the way
// there is for commands).
//
// base must never import this file, or anything above base — lex.odin's
// header comment carries the actual rule; this file is where the mapping
// that rule exists to protect actually lives.
package main

import "core:strings"
import base "src:base"
import plat "src:platform"

Lexer_Proc :: proc(line: []u8, out: []base.Token) -> int

// Extension (with leading dot, case-insensitive) -> lexer. `.log` is Task
// 1's entry; `.json` is Task 2's. `.txt` and every other extension correctly
// map to no lexer at all — `.txt` has no grammar to find, and everything
// else is a later task's lexer landing in this same table.
@(private = "file")
EXT_LEXERS := [?]struct {
	ext:   string,
	lexer: Lexer_Proc,
}{{".log", base.lex_log}, {".json", base.lex_json}}

// The lexer for a document's path, or nil when the extension has none yet
// (or never will, like .txt).
highlight_lexer_for :: proc(path: string) -> Lexer_Proc {
	if path == "" {return nil}
	dot := strings.last_index_byte(path, '.')
	if dot < 0 {return nil}
	ext := path[dot:]
	for e in EXT_LEXERS {
		if strings.equal_fold(ext, e.ext) {return e.lexer}
	}
	return nil
}

// Token_Kind -> Color_Role. Data, not branching logic: every kind a lexer can
// produce maps to exactly one of the nine Syn_* roles theme.odin declared for
// this batch. A total enumerated array, not a #partial switch: Odin rejects
// an incomplete keyed enumerated-array composite literal at compile time
// (see theme.odin's Theme/#assert comment, and command_table's identical
// reasoning), so a Token_Kind a later task adds and forgets to map here is a
// build error, not a silent fallthrough. `.None` still needs an entry
// because the array is total over the whole enum, but it never actually
// reaches g_theme[...] — highlight_row_spans filters `.None` out before this
// map is consulted — so its value here is unreachable, not meaningful.
@(private = "file")
TOKEN_KIND_ROLE := [base.Token_Kind]Color_Role {
	.None     = .Syn_Punct, // unreachable -- see comment above
	.Keyword  = .Syn_Keyword,
	.String   = .Syn_String,
	.Number   = .Syn_Number,
	.Comment  = .Syn_Comment,
	.Type     = .Syn_Type,
	.Punct    = .Syn_Punct,
	.Json_Key = .Syn_Json_Key,
	.Xml_Tag  = .Syn_Xml_Tag,
	.Xml_Attr = .Syn_Xml_Attr,
}

highlight_kind_role :: proc(k: base.Token_Kind) -> Color_Role {
	return TOKEN_KIND_ROLE[k]
}

// Tokens per row a pattern lexer can produce before highlight_row_spans stops
// converting them. A screen row is bounded by VISIBLE_COLS cells; this is
// generous headroom without ever allocating.
HL_MAX_ROW_TOKENS :: 64

// Total bytes handed to a lexer, accumulated across calls. Exists only for
// highlighttest (test_modes.odin) to prove the per-frame cost is
// viewport-proportional rather than O(file) — see that mode's comment for
// why a plain package-level int, not a debug-only counter, is the right
// weight here: incrementing it costs less than the lex call it accounts for,
// the same shape draw_calls_text already carries unconditionally in the
// shipping text_draw_spans (platform/text.odin).
hl_bytes_examined: int

// Combine one row's raw lexer spans with its link spans into a single
// sorted, non-overlapping list — the shape text_draw_spans requires. Links
// always win: a lexer span that intersects a link anywhere is dropped
// WHOLE, never truncated, because text_draw_spans's own contract ("sorted…
// must not overlap") has no defined behaviour for overlapping input (see
// the comment at doc_draw's call site for the concrete example). Both
// inputs must already be sorted ascending by start with no internal
// overlaps of their own (lex_spans: tokens are found left to right;
// link_spans: links_layout scans the same way), so survivor selection plus
// a linear two-pointer merge is enough — no general sort — and the two
// inputs never contain an overlapping pair once the drop below has run,
// which is exactly the precondition being upheld.
//
// Factored out of doc_draw, which previously had this inlined, so
// highlighttest can call the literal proc doc_draw draws with rather than a
// second copy that could quietly diverge — "test the seam, not the unit"
// (CLAUDE.md). A 2026-07 review flagged this mechanism as untested; the
// "link precedence" checks in highlighttest exist to close that gap.
highlight_merge_spans :: proc(lex_spans, link_spans: []plat.Text_Span, out: []plat.Text_Span) -> int {
	survivors: [HL_MAX_ROW_TOKENS]plat.Text_Span
	sn := 0
	outer: for sp in lex_spans {
		for l in link_spans {
			if sp.start < l.start + l.len && l.start < sp.start + sp.len {
				continue outer // overlaps a link: drop it whole, link wins
			}
		}
		if sn >= len(survivors) {break}
		survivors[sn] = sp
		sn += 1
	}
	n := 0
	li, ri := 0, 0
	for (li < sn || ri < len(link_spans)) && n < len(out) {
		if ri >= len(link_spans) || (li < sn && survivors[li].start <= link_spans[ri].start) {
			out[n] = survivors[li]
			li += 1
		} else {
			out[n] = link_spans[ri]
			ri += 1
		}
		n += 1
	}
	return n
}

// Row-relative syntax spans for one row's bytes, through whichever lexer
// `doc`'s path selects (nil for an extension with none, e.g. .txt — in which
// case this returns 0 and draws nothing extra). No allocation: tokens land
// in a fixed-size local array, spans are written into the caller's `out`
// slice. Runs per visible row per frame, so this is the hot path
// highlighttest holds to viewport-proportional cost.
//
// `row_bytes` is whatever the caller decides represents "this row" — this
// proc has no opinion on word wrap. doc_draw (doc.odin) passes the row's own
// drawn bytes directly for an unwrapped or filtered row (which already IS
// the whole logical line, capped) and routes a wrapped row through
// doc_row_lex_spans, which lexes the cached whole logical line once and
// rebases the result onto each visual row — see that proc's comment.
highlight_row_spans :: proc(doc: ^Document, row_bytes: []u8, out: []plat.Text_Span) -> int {
	if doc == nil || len(row_bytes) == 0 || len(out) == 0 {return 0}
	lexer := highlight_lexer_for(doc.path)
	if lexer == nil {return 0}
	toks: [HL_MAX_ROW_TOKENS]base.Token
	n := lexer(row_bytes, toks[:])
	hl_bytes_examined += len(row_bytes)
	w := 0
	for i in 0 ..< n {
		if w >= len(out) {break}
		tok := toks[i]
		if tok.kind == .None {continue}
		out[w] = plat.Text_Span {
			start = tok.start,
			len   = tok.len,
			color = g_theme[highlight_kind_role(tok.kind)],
		}
		w += 1
	}
	return w
}
