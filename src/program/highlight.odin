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

// Extension (with leading dot, case-insensitive) -> lexer. `.log` is the only
// entry Task 1 adds; `.txt` and every other extension correctly map to no
// lexer at all — `.txt` has no grammar to find, and everything else is a
// later task's lexer landing in this same table.
@(private = "file")
EXT_LEXERS := [?]struct {
	ext:   string,
	lexer: Lexer_Proc,
}{{".log", base.lex_log}}

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
// this batch. `.None` never reaches here — highlight_row_spans skips it below
// — so its fallthrough value is never actually drawn.
highlight_kind_role :: proc(k: base.Token_Kind) -> Color_Role {
	#partial switch k {
	case .Keyword:
		return .Syn_Keyword
	case .String:
		return .Syn_String
	case .Number:
		return .Syn_Number
	case .Comment:
		return .Syn_Comment
	case .Type:
		return .Syn_Type
	case .Punct:
		return .Syn_Punct
	case .Json_Key:
		return .Syn_Json_Key
	case .Xml_Tag:
		return .Syn_Xml_Tag
	case .Xml_Attr:
		return .Syn_Xml_Attr
	}
	return .Syn_Punct
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
