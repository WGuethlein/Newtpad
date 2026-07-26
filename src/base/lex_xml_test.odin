package base

import "core:strings"
import "core:testing"

// Written before lex_xml's real implementation (see lex_xml.odin's header) --
// run against a STUB (always returns 0, state_in unchanged) first and watch
// every case that expects a token or a state change fail, then again after
// the implementation lands and watch them all pass. See task-3-report.md for
// both runs' output.

@(private = "file")
xtok_eq :: proc(t: ^testing.T, got: Token, want_start, want_len: int, want_kind: Token_Kind, label: string) {
	testing.expectf(
		t,
		got.start == want_start && got.len == want_len && got.kind == want_kind,
		"%s: got {%d,%d,%v} want {%d,%d,%v}",
		label,
		got.start,
		got.len,
		got.kind,
		want_start,
		want_len,
		want_kind,
	)
}

// A tag with an attribute and a quoted value, all on one line: no state
// carried anywhere, the shape every non-comment construct in this file
// exercises. "<tag" and the two lone '>' /'</tag' delimiters are Xml_Tag,
// "attr" is Xml_Attr, the quoted value is a String -- reusing the generic
// String kind rather than inventing a new one, same call lex_json made for
// its own values.
@(test)
test_lex_xml_tag_attr_value :: proc(t: ^testing.T) {
	line := `<tag attr="value">text</tag>`
	bytes := transmute([]u8)line
	out: [8]Token
	n, state := lex_xml(bytes, .Normal, out[:])
	testing.expectf(t, n == 6, "want 6 tokens, got %d", n)
	testing.expectf(t, state == .Normal, "want state Normal after a one-line tag, got %v", state)
	if n != 6 {return}
	xtok_eq(t, out[0], 0, len("<tag"), .Xml_Tag, "opening delimiter + name")
	attr_start := strings.index(line, "attr")
	xtok_eq(t, out[1], attr_start, len("attr"), .Xml_Attr, "attribute name")
	val_start := strings.index(line, `"value"`)
	xtok_eq(t, out[2], val_start, len(`"value"`), .String, "quoted attribute value")
	close1 := strings.index(line, `">`) + 1
	xtok_eq(t, out[3], close1, 1, .Xml_Tag, "opening tag's closing '>'")
	close_tag_start := strings.index(line, "</tag")
	xtok_eq(t, out[4], close_tag_start, len("</tag"), .Xml_Tag, "closing tag delimiter + name")
	xtok_eq(t, out[5], len(line) - 1, 1, .Xml_Tag, "closing tag's '>'")
}

// A self-closing tag: "<br" then "/>" as its own two-byte delimiter token,
// never split across two Punct-ish tokens.
@(test)
test_lex_xml_self_closing_tag :: proc(t: ^testing.T) {
	line := `<br/>`
	bytes := transmute([]u8)line
	out: [8]Token
	n, state := lex_xml(bytes, .Normal, out[:])
	testing.expectf(t, n == 2, "want 2 tokens, got %d", n)
	testing.expectf(t, state == .Normal, "self-closing tag leaves state Normal, got %v", state)
	if n != 2 {return}
	xtok_eq(t, out[0], 0, len("<br"), .Xml_Tag, "opening delimiter + name")
	xtok_eq(t, out[1], 3, 2, .Xml_Tag, "self-closing '/>'")
}

// A named entity ref and a numeric one, both inside plain text -- mapped to
// Keyword (the closest existing Token_Kind bucket; see lex_xml.odin's header
// for why no new kind was added).
@(test)
test_lex_xml_entity_refs :: proc(t: ^testing.T) {
	line := `A &amp; B &#169; C`
	bytes := transmute([]u8)line
	out: [8]Token
	n, state := lex_xml(bytes, .Normal, out[:])
	testing.expectf(t, n == 2, "want 2 tokens, got %d", n)
	testing.expectf(t, state == .Normal, "entity refs don't change state, got %v", state)
	if n != 2 {return}
	amp_start := strings.index(line, "&amp;")
	xtok_eq(t, out[0], amp_start, len("&amp;"), .Keyword, "&amp;")
	num_start := strings.index(line, "&#169;")
	xtok_eq(t, out[1], num_start, len("&#169;"), .Keyword, "&#169;")
}

// A bare '&' not part of any entity ref (no ';' within a bounded scan)
// matches nothing -- not a token, not a hang, not a run past the line.
@(test)
test_lex_xml_bare_ampersand_not_entity :: proc(t: ^testing.T) {
	line := `Smith & Wesson`
	bytes := transmute([]u8)line
	out: [8]Token
	n, _ := lex_xml(bytes, .Normal, out[:])
	testing.expectf(t, n == 0, "want 0 tokens (no entity, no other construct), got %d", n)
}

// A comment that both opens and closes on the same line behaves exactly like
// a line-local construct: one Comment token spanning the delimiters, state
// unaffected on either side of it.
@(test)
test_lex_xml_comment_single_line :: proc(t: ^testing.T) {
	line := `before <!-- a comment --> after`
	bytes := transmute([]u8)line
	out: [8]Token
	n, state := lex_xml(bytes, .Normal, out[:])
	testing.expectf(t, n == 1, "want 1 token, got %d", n)
	testing.expectf(t, state == .Normal, "closed comment leaves state Normal, got %v", state)
	if n != 1 {return}
	c_start := strings.index(line, "<!--")
	c_end := strings.index(line, "-->") + len("-->")
	xtok_eq(t, out[0], c_start, c_end-c_start, .Comment, "whole <!-- ... --> run")
}

// THE multi-line case this whole task exists to prove: a comment opened on
// one line, continuing untouched through a middle line, and closed on a
// third -- each call receiving the previous call's state_out as its own
// state_in, exactly how doc_row_lex_spans (doc.odin) or the background index
// worker (program/lex_index.odin) would thread it, one line at a time.
@(test)
test_lex_xml_comment_spans_three_lines :: proc(t: ^testing.T) {
	line1 := `before <!-- start of`
	line2 := `a long comment with no markers at all`
	line3 := `the end --> after`

	out: [8]Token

	n1, s1 := lex_xml(transmute([]u8)line1, .Normal, out[:])
	testing.expectf(t, n1 == 1, "line1: want 1 token, got %d", n1)
	testing.expectf(t, s1 == .In_Comment, "line1: want state In_Comment after an unclosed comment, got %v", s1)
	if n1 == 1 {
		c_start := strings.index(line1, "<!--")
		xtok_eq(t, out[0], c_start, len(line1)-c_start, .Comment, "line1: comment runs to line end, still open")
	}

	n2, s2 := lex_xml(transmute([]u8)line2, s1, out[:])
	testing.expectf(t, n2 == 1, "line2: want 1 token (the whole line is comment), got %d", n2)
	testing.expectf(t, s2 == .In_Comment, "line2: still inside the comment, got %v", s2)
	if n2 == 1 {
		xtok_eq(t, out[0], 0, len(line2), .Comment, "line2: entirely inside the open comment")
	}

	n3, s3 := lex_xml(transmute([]u8)line3, s2, out[:])
	testing.expectf(t, n3 == 1, "line3: want 1 token (the comment run through its close; trailing text has none), got %d", n3)
	testing.expectf(t, s3 == .Normal, "line3: comment closes here, want state Normal, got %v", s3)
	if n3 == 1 {
		c_end := strings.index(line3, "-->") + len("-->")
		xtok_eq(t, out[0], 0, c_end, .Comment, "line3: whole line up through the close, already inside the comment at line start")
	}
}

// Empty input: no tokens, no state change, no crash.
@(test)
test_lex_xml_empty :: proc(t: ^testing.T) {
	out: [8]Token
	n, state := lex_xml(nil, .Normal, out[:])
	testing.expectf(t, n == 0, "want 0 tokens on empty line, got %d", n)
	testing.expectf(t, state == .Normal, "empty line preserves state_in, got %v", state)
}

// state_in is honored even on an empty line: an empty line in the middle of
// an open comment must still report itself as still-open, not silently reset
// to Normal.
@(test)
test_lex_xml_empty_line_inside_comment :: proc(t: ^testing.T) {
	out: [8]Token
	n, state := lex_xml(nil, .In_Comment, out[:])
	testing.expectf(t, n == 0, "want 0 tokens, got %d", n)
	testing.expectf(t, state == .In_Comment, "empty line inside an open comment stays In_Comment, got %v", state)
}

// A line producing more matches than `out` can hold must stop EMITTING at
// capacity (same contract as lex_log/lex_json) but must NOT stop SCANNING:
// the trailing `<!--` here opens a comment after the 2nd token, past `out`'s
// capacity of 2, and state_out must still report .In_Comment. Before the fix
// this test asserted only `n == 2` and threw away state with `n, _ :=` --
// passing even though the real implementation silently returned .Normal here
// (the token-capacity exit doubled as a scan-capacity exit). See lex_xml.odin's
// header comment on the outer loop.
@(test)
test_lex_xml_stops_at_capacity :: proc(t: ^testing.T) {
	line := `<a><b><c><!--`
	bytes := transmute([]u8)line
	out: [2]Token
	n, state := lex_xml(bytes, .Normal, out[:])
	testing.expectf(t, n == 2, "want exactly 2 tokens (out's capacity), got %d", n)
	testing.expectf(t, state == .In_Comment, "want In_Comment (scan must continue past emit capacity), got %v", state)
}
