package base

import "core:strings"
import "core:testing"

// Written before lex_markdown's real implementation, same discipline as
// every lexer in this batch. See lex_markdown.odin's header for scope: this
// colours the SOURCE view (Ctrl+M's rendered preview, markdown.odin, is a
// completely different feature this lexer never touches or references).

@(private = "file")
mtok_eq :: proc(t: ^testing.T, got: Token, want_start, want_len: int, want_kind: Token_Kind, label: string) {
	testing.expectf(
		t,
		got.start == want_start && got.len == want_len && got.kind == want_kind,
		// No literal '{' in this format string: Odin's fmt reads "{%d," as a
		// brace-index verb, which not only hides the first number but
		// desynchronises the whole argument list -- so the want triple was
		// mis-bound too. That garbles the one output sabotage discipline
		// (docs/development-loop.md §3) depends on reading. Fixed tree-wide
		// 2026-07-26; it had mangled every failure here since the file was
		// written. See lex_c_test.odin for where it was found.
		"%s: got start=%d len=%d kind=%v, want start=%d len=%d kind=%v",
		label,
		got.start,
		got.len,
		got.kind,
		want_start,
		want_len,
		want_kind,
	)
}

// A heading line: the whole "# text" run is one Keyword token.
@(test)
test_lex_markdown_heading :: proc(t: ^testing.T) {
	line := `## Section Title`
	bytes := transmute([]u8)line
	out: [8]Token
	n, state := lex_markdown(bytes, .Normal, out[:])
	testing.expectf(t, n == 1, "want 1 token, got %d", n)
	testing.expectf(t, state == .Normal, "heading doesn't change state, got %v", state)
	if n != 1 {return}
	mtok_eq(t, out[0], 0, len(line), .Keyword, "whole heading line")
}

// A '#' not followed by a space (or immediately at line end) is NOT a
// heading marker -- "#tag" is ordinary text, ATX headings require the space.
@(test)
test_lex_markdown_hash_without_space_not_heading :: proc(t: ^testing.T) {
	line := `#tag not a heading`
	bytes := transmute([]u8)line
	out: [8]Token
	n, _ := lex_markdown(bytes, .Normal, out[:])
	testing.expectf(t, n == 0, "want 0 tokens (no heading, no other construct), got %d", n)
}

// A blockquote marker colours just the '>' as Comment; the rest of the line
// still gets ordinary inline scanning (bold survives inside a blockquote).
@(test)
test_lex_markdown_blockquote_with_inline_bold :: proc(t: ^testing.T) {
	line := `> **important**`
	bytes := transmute([]u8)line
	out: [8]Token
	n, _ := lex_markdown(bytes, .Normal, out[:])
	testing.expectf(t, n == 2, "want 2 tokens, got %d", n)
	if n != 2 {return}
	mtok_eq(t, out[0], 0, 1, .Comment, "'>' marker")
	bold_start := strings.index(line, "**important**")
	mtok_eq(t, out[1], bold_start, len("**important**"), .Keyword, "bold span")
}

// EVERY '>' in a nested blockquote prefix takes the same kind.
//
// The defect (live pass 0.27, source view): only the first marker was
// tokenized, so `>> nested` drew one green '>' and one default-coloured one --
// Wyatt: "the first `>` is green, where the rest are white". Written as "find
// the token covering each '>' in the prefix and assert its kind", not "expect
// exactly 2 Comment tokens": the assertion has to be about coverage of the
// markers, or a future change that merged the prefix into one span would fail
// a test it actually satisfies.
@(test)
test_lex_markdown_nested_blockquote_markers_share_one_kind :: proc(t: ^testing.T) {
	// Both spellings of depth 2, plus a depth-3 case, plus the depth-1 control
	// (which passed before the fix -- if it ever fails, the fixture is wrong,
	// not the lexer).
	for line in ([]string{`> one`, `>> two`, `> > spaced`, `>>> three`}) {
		bytes := transmute([]u8)line
		out: [16]Token
		n, _ := lex_markdown(bytes, .Normal, out[:])
		// The prefix is the leading run of '>' and spaces; content starts after
		// the last marker.
		last := strings.last_index_byte(line, '>')
		markers := 0
		covered := 0
		for k in 0 ..= last {
			if line[k] != '>' {continue}
			markers += 1
			for j in 0 ..< n {
				if k >= out[j].start && k < out[j].start + out[j].len {
					if out[j].kind == .Comment {covered += 1}
					break
				}
			}
		}
		testing.expectf(t, markers > 0, "%q: fixture has markers", line)
		testing.expectf(t, covered == markers, "%q: %d of %d quote markers are .Comment", line, covered, markers)
	}
}

// The marker run must not swallow the content: `>> two` still leaves "two"
// available to the inline scan, so a construct inside a nested quote is still
// coloured. Without this, "consume every '>'" could pass the test above by
// eating the whole line.
@(test)
test_lex_markdown_nested_blockquote_keeps_inline_content :: proc(t: ^testing.T) {
	line := `>> **important**`
	bytes := transmute([]u8)line
	out: [16]Token
	n, _ := lex_markdown(bytes, .Normal, out[:])
	testing.expectf(t, n == 3, "want 3 tokens (two markers + bold), got %d", n)
	if n != 3 {return}
	mtok_eq(t, out[0], 0, 1, .Comment, "first '>' marker")
	mtok_eq(t, out[1], 1, 1, .Comment, "second '>' marker")
	bold_start := strings.index(line, "**important**")
	mtok_eq(t, out[2], bold_start, len("**important**"), .Keyword, "bold span")
}

// A list marker ("- ") colours just the bullet as Punct.
@(test)
test_lex_markdown_list_marker :: proc(t: ^testing.T) {
	line := `- an item`
	bytes := transmute([]u8)line
	out: [8]Token
	n, _ := lex_markdown(bytes, .Normal, out[:])
	testing.expectf(t, n == 1, "want 1 token, got %d", n)
	if n != 1 {return}
	mtok_eq(t, out[0], 0, 1, .Punct, "bullet")
}

// An ordered list marker ("1. ") is also just Punct for the marker itself.
@(test)
test_lex_markdown_ordered_list_marker :: proc(t: ^testing.T) {
	line := `12. an item`
	bytes := transmute([]u8)line
	out: [8]Token
	n, _ := lex_markdown(bytes, .Normal, out[:])
	testing.expectf(t, n == 1, "want 1 token, got %d", n)
	if n != 1 {return}
	mtok_eq(t, out[0], 0, len("12."), .Punct, "ordered marker")
}

// A thematic break (horizontal rule) is one Punct token for the whole line,
// and must NOT be confused with a list marker despite sharing '-'/'*'.
@(test)
test_lex_markdown_horizontal_rule :: proc(t: ^testing.T) {
	line := `---`
	bytes := transmute([]u8)line
	out: [8]Token
	n, _ := lex_markdown(bytes, .Normal, out[:])
	testing.expectf(t, n == 1, "want 1 token, got %d", n)
	if n != 1 {return}
	mtok_eq(t, out[0], 0, len(line), .Punct, "whole hr line")
}

@(test)
test_lex_markdown_horizontal_rule_asterisks_with_spaces :: proc(t: ^testing.T) {
	line := `* * *`
	bytes := transmute([]u8)line
	out: [8]Token
	n, _ := lex_markdown(bytes, .Normal, out[:])
	testing.expectf(t, n == 1, "want 1 token, got %d", n)
	if n != 1 {return}
	mtok_eq(t, out[0], 0, len(line), .Punct, "whole hr line")
}

// Inline code span: backtick-delimited, coloured String.
@(test)
test_lex_markdown_inline_code :: proc(t: ^testing.T) {
	line := "see `code()` here"
	bytes := transmute([]u8)line
	out: [8]Token
	n, _ := lex_markdown(bytes, .Normal, out[:])
	testing.expectf(t, n == 1, "want 1 token, got %d", n)
	if n != 1 {return}
	c_start := strings.index(line, "`code()`")
	mtok_eq(t, out[0], c_start, len("`code()`"), .String, "inline code span")
}

// Bold (**) and italic (*) must not be confused: bold is checked first so a
// "**word**" run colours as ONE bold span, not two adjacent italics.
@(test)
test_lex_markdown_bold_vs_italic :: proc(t: ^testing.T) {
	line := `**bold** and *italic*`
	bytes := transmute([]u8)line
	out: [8]Token
	n, _ := lex_markdown(bytes, .Normal, out[:])
	testing.expectf(t, n == 2, "want 2 tokens, got %d", n)
	if n != 2 {return}
	mtok_eq(t, out[0], 0, len("**bold**"), .Keyword, "bold")
	it_start := strings.index(line, "*italic*")
	mtok_eq(t, out[1], it_start, len("*italic*"), .Type, "italic")
}

// Underscore-delimited bold/italic work the same way as asterisk-delimited.
@(test)
test_lex_markdown_underscore_emphasis :: proc(t: ^testing.T) {
	line := `__bold__ and _italic_`
	bytes := transmute([]u8)line
	out: [8]Token
	n, _ := lex_markdown(bytes, .Normal, out[:])
	testing.expectf(t, n == 2, "want 2 tokens, got %d", n)
	if n != 2 {return}
	mtok_eq(t, out[0], 0, len("__bold__"), .Keyword, "bold")
	it_start := strings.index(line, "_italic_")
	mtok_eq(t, out[1], it_start, len("_italic_"), .Type, "italic")
}

// An unterminated emphasis marker is left plain -- same "leave it plain"
// contract as lex_c's raw/backtick strings, since a lone '*' in prose
// (a bullet-less asterisk, a footnote mark, ...) is common and NOT an error
// the way an unterminated quoted string is.
@(test)
test_lex_markdown_unterminated_emphasis_left_plain :: proc(t: ^testing.T) {
	line := `just a * lonely star`
	bytes := transmute([]u8)line
	out: [8]Token
	n, _ := lex_markdown(bytes, .Normal, out[:])
	testing.expectf(t, n == 0, "want 0 tokens (no closing '*'), got %d", n)
}

// A link: brackets/parens are Punct, the URL is String, the link text is
// left plain (no dedicated "link text" role in this batch's vocabulary).
@(test)
test_lex_markdown_link :: proc(t: ^testing.T) {
	line := `see [docs](https://example.com) here`
	bytes := transmute([]u8)line
	out: [8]Token
	n, _ := lex_markdown(bytes, .Normal, out[:])
	testing.expectf(t, n == 4, "want 4 tokens, got %d", n)
	if n != 4 {return}
	mtok_eq(t, out[0], strings.index(line, "["), 1, .Punct, "[")
	mtok_eq(t, out[1], strings.index(line, "]"), 1, .Punct, "]")
	url_start := strings.index(line, "https://")
	mtok_eq(t, out[2], url_start, len("https://example.com"), .String, "url")
	mtok_eq(t, out[3], strings.index(line, ")"), 1, .Punct, ")")
}

// An image reference additionally colours the leading '!' as Punct.
@(test)
test_lex_markdown_image :: proc(t: ^testing.T) {
	line := `![alt](img.png)`
	bytes := transmute([]u8)line
	out: [8]Token
	n, _ := lex_markdown(bytes, .Normal, out[:])
	testing.expectf(t, n == 5, "want 5 tokens, got %d", n)
	if n != 5 {return}
	mtok_eq(t, out[0], 0, 1, .Punct, "!")
}

// A fenced code block opens on one line and its content is entirely
// UNPARSED (no inline scanning inside it -- a stray "**" inside example code
// must not be coloured as bold) until the closing fence.
@(test)
test_lex_markdown_fence_spans_lines :: proc(t: ^testing.T) {
	line1 := "```odin"
	line2 := "x := 1 ** not bold, this is code"
	line3 := "```"

	out: [8]Token

	n1, s1 := lex_markdown(transmute([]u8)line1, .Normal, out[:])
	testing.expectf(t, n1 == 1, "line1: want 1 token (the fence marker), got %d", n1)
	testing.expectf(t, s1 == .In_Comment, "line1: want In_Comment (fence open), got %v", s1)
	if n1 == 1 {mtok_eq(t, out[0], 0, 3, .Punct, "opening fence")}

	n2, s2 := lex_markdown(transmute([]u8)line2, s1, out[:])
	testing.expectf(t, n2 == 0, "line2: want 0 tokens (fence content is not parsed), got %d", n2)
	testing.expectf(t, s2 == .In_Comment, "line2: still inside the fence, got %v", s2)

	n3, s3 := lex_markdown(transmute([]u8)line3, s2, out[:])
	testing.expectf(t, n3 == 1, "line3: want 1 token (the closing fence marker), got %d", n3)
	testing.expectf(t, s3 == .Normal, "line3: fence closes here, got %v", s3)
	if n3 == 1 {mtok_eq(t, out[0], 0, 3, .Punct, "closing fence")}
}

// A `~~~` fence opens and closes exactly like a ``` one, and `~~struck~~`
// (a run of TWO) is not a fence at all. The preview has always toggled on
// `~~~` (md_fence_lexer maps `~~~yaml`); the lexer must agree, because the
// preview now seeds its fence state from it -- a marker only one side counts
// is what turns "the opening fence scrolled off screen" into "the rest of the
// file is a code block".
@(test)
test_lex_markdown_tilde_fence :: proc(t: ^testing.T) {
	out: [8]Token
	line_open := "~~~yaml"
	line_body := "key: **not bold, this is code**"
	line_close := "~~~"
	line_strike := "~~struck~~ and more prose"

	n1, s1 := lex_markdown(transmute([]u8)line_open, .Normal, out[:])
	testing.expectf(t, n1 == 1, "open: want 1 token (the fence marker), got %d", n1)
	testing.expectf(t, s1 == .In_Comment, "open: want In_Comment (fence open), got %v", s1)
	if n1 == 1 {mtok_eq(t, out[0], 0, 3, .Punct, "opening tilde fence")}

	n2, s2 := lex_markdown(transmute([]u8)line_body, s1, out[:])
	testing.expectf(t, n2 == 0, "body: want 0 tokens inside the fence, got %d", n2)
	testing.expectf(t, s2 == .In_Comment, "body: still inside the fence, got %v", s2)

	_, s3 := lex_markdown(transmute([]u8)line_close, s2, out[:])
	testing.expectf(t, s3 == .Normal, "close: fence closes here, got %v", s3)

	// Two tildes is strikethrough, not a fence: this must NOT change state, or
	// every `~~struck~~` line would grey out the rest of the document.
	_, s4 := lex_markdown(transmute([]u8)line_strike, .Normal, out[:])
	testing.expectf(t, s4 == .Normal, "`~~struck~~` is not a fence, got %v", s4)
}

// Empty input: no tokens, no state change, no crash.
@(test)
test_lex_markdown_empty :: proc(t: ^testing.T) {
	out: [8]Token
	n, state := lex_markdown(nil, .Normal, out[:])
	testing.expectf(t, n == 0, "want 0 tokens on empty line, got %d", n)
	testing.expectf(t, state == .Normal, "empty line preserves state_in, got %v", state)
}

// state_in is honoured on an empty line inside an open fence: it must stay
// In_Comment, not silently reset to Normal.
@(test)
test_lex_markdown_empty_line_inside_fence :: proc(t: ^testing.T) {
	out: [8]Token
	n, state := lex_markdown(nil, .In_Comment, out[:])
	testing.expectf(t, n == 0, "want 0 tokens, got %d", n)
	testing.expectf(t, state == .In_Comment, "empty line inside an open fence stays In_Comment, got %v", state)
}

// THE lesson-1 test: the fence STATE transition must be computed and
// reported correctly even when `out` has NO room to hold the token at all
// (capacity 0) -- proving the state doesn't depend on whether the token
// could be written, the exact shape of bug Task 3 shipped once for lex_xml
// and Task 4 repeated one layer up. A zero-length buffer is the strongest
// version of this check: not "a dense line exhausts a 64-slot buffer" but
// "even a SINGLE token can't be written," and the state must still come out
// right.
@(test)
test_lex_markdown_fence_state_survives_zero_capacity_out :: proc(t: ^testing.T) {
	line := "```"
	out: [0]Token
	n, state := lex_markdown(transmute([]u8)line, .Normal, out[:])
	testing.expectf(t, n == 0, "want 0 tokens written (capacity 0), got %d", n)
	testing.expectf(t, state == .In_Comment, "want state In_Comment even though no token could be written, got %v", state)
}

// Same check on the closing side: a fence-closing line lexed with a
// zero-capacity buffer must still report state Normal.
@(test)
test_lex_markdown_fence_close_state_survives_zero_capacity_out :: proc(t: ^testing.T) {
	line := "```"
	out: [0]Token
	n, state := lex_markdown(transmute([]u8)line, .In_Comment, out[:])
	testing.expectf(t, n == 0, "want 0 tokens written (capacity 0), got %d", n)
	testing.expectf(t, state == .Normal, "want state Normal even though no token could be written, got %v", state)
}

// A dense inline line (more emphasis spans than `out` can hold) must stop
// EMITTING at capacity without corrupting state_out -- mirrors
// lex_xml_test's/lex_c_test's capacity tests, applied here even though (see
// lex_markdown.odin's header) this lexer's state is structurally immune to
// the Task 3/4 bug shape, since a fence toggle is only ever evaluated once,
// at the true start of a line, before any inline emission happens.
@(test)
test_lex_markdown_stops_at_capacity :: proc(t: ^testing.T) {
	line := `*a* *b* *c* *d* *e*`
	bytes := transmute([]u8)line
	out: [2]Token
	n, state := lex_markdown(bytes, .Normal, out[:])
	testing.expectf(t, n == 2, "want exactly 2 tokens (out's capacity), got %d", n)
	testing.expectf(t, state == .Normal, "want state Normal (no fence involved), got %v", state)
}
