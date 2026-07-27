package base

import "core:strings"
import "core:testing"

// Written before lex_yaml's real implementation, same discipline as every
// lexer in this batch. See lex_yaml.odin's header for the block-scalar
// state machinery this exists to prove, and for why YAML gets its own
// lexer rather than folding into lex_config.odin.

@(private = "file")
ytok_eq :: proc(t: ^testing.T, got: Token, want_start, want_len: int, want_kind: Token_Kind, label: string) {
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

@(test)
test_lex_yaml_key_value :: proc(t: ^testing.T) {
	line := `name: Newtpad`
	bytes := transmute([]u8)line
	out: [8]Token
	n, state := lex_yaml(bytes, .Normal, out[:])
	testing.expectf(t, n == 2, "want 2 tokens, got %d", n)
	testing.expectf(t, state == .Normal, "plain key/value doesn't change state, got %v", state)
	if n != 2 {return}
	ytok_eq(t, out[0], 0, len("name"), .Json_Key, "key")
	ytok_eq(t, out[1], strings.index(line, ":"), 1, .Punct, ":")
}

// A colon NOT followed by whitespace is not a key separator at all -- this
// is what keeps "url: http://example.com" from treating "http" as a second
// key. The real YAML spec draws this same line for exactly this reason.
@(test)
test_lex_yaml_colon_without_space_not_key :: proc(t: ^testing.T) {
	line := `url: http://example.com`
	bytes := transmute([]u8)line
	out: [8]Token
	n, _ := lex_yaml(bytes, .Normal, out[:])
	testing.expectf(t, n == 2, "want 2 tokens (the real key/colon only), got %d", n)
	if n != 2 {return}
	ytok_eq(t, out[0], 0, len("url"), .Json_Key, "key")
	ytok_eq(t, out[1], strings.index(line, ":"), 1, .Punct, "the real ':' after \"url\"")
}

@(test)
test_lex_yaml_quoted_value :: proc(t: ^testing.T) {
	line := `title: "hello world"`
	bytes := transmute([]u8)line
	out: [8]Token
	n, _ := lex_yaml(bytes, .Normal, out[:])
	testing.expectf(t, n == 3, "want 3 tokens, got %d", n)
	if n != 3 {return}
	ytok_eq(t, out[2], strings.index(line, `"hello world"`), len(`"hello world"`), .String, "quoted value")
}

@(test)
test_lex_yaml_number_value :: proc(t: ^testing.T) {
	line := `port: 8080`
	bytes := transmute([]u8)line
	out: [8]Token
	n, _ := lex_yaml(bytes, .Normal, out[:])
	testing.expectf(t, n == 3, "want 3 tokens, got %d", n)
	if n != 3 {return}
	ytok_eq(t, out[2], strings.index(line, "8080"), 4, .Number, "8080")
}

// true/false/null are the representative keywords this table must colour.
@(test)
test_lex_yaml_boolean_and_null :: proc(t: ^testing.T) {
	line := `enabled: true`
	bytes := transmute([]u8)line
	out: [8]Token
	n, _ := lex_yaml(bytes, .Normal, out[:])
	testing.expectf(t, n == 3, "want 3 tokens, got %d", n)
	if n != 3 {return}
	ytok_eq(t, out[2], strings.index(line, "true"), len("true"), .Keyword, "true")
}

@(test)
test_lex_yaml_tilde_null :: proc(t: ^testing.T) {
	line := `value: ~`
	bytes := transmute([]u8)line
	out: [8]Token
	n, _ := lex_yaml(bytes, .Normal, out[:])
	testing.expectf(t, n == 3, "want 3 tokens, got %d", n)
	if n != 3 {return}
	ytok_eq(t, out[2], strings.index(line, "~"), 1, .Keyword, "~ (null shorthand)")
}

@(test)
test_lex_yaml_full_line_comment :: proc(t: ^testing.T) {
	line := `# a comment`
	bytes := transmute([]u8)line
	out: [8]Token
	n, _ := lex_yaml(bytes, .Normal, out[:])
	testing.expectf(t, n == 1, "want 1 token, got %d", n)
	if n != 1 {return}
	ytok_eq(t, out[0], 0, len(line), .Comment, "whole comment line")
}

@(test)
test_lex_yaml_document_marker :: proc(t: ^testing.T) {
	line := `---`
	bytes := transmute([]u8)line
	out: [8]Token
	n, _ := lex_yaml(bytes, .Normal, out[:])
	testing.expectf(t, n == 1, "want 1 token, got %d", n)
	if n != 1 {return}
	ytok_eq(t, out[0], 0, 3, .Punct, "document start marker")
}

@(test)
test_lex_yaml_list_marker_with_nested_key :: proc(t: ^testing.T) {
	line := `- name: Alice`
	bytes := transmute([]u8)line
	out: [8]Token
	n, _ := lex_yaml(bytes, .Normal, out[:])
	testing.expectf(t, n == 3, "want 3 tokens, got %d", n)
	if n != 3 {return}
	ytok_eq(t, out[0], 0, 1, .Punct, "list marker '-'")
	key_start := strings.index(line, "name")
	ytok_eq(t, out[1], key_start, len("name"), .Json_Key, "nested key")
}

// THE multi-line case this file exists to prove: a block scalar opened with
// "|", continuing untouched through indented lines (even a blank one), and
// ending the moment a line's indentation drops back to the introducing
// key's own level -- each call threading the previous call's state_out into
// the next, exactly as doc_row_lex_spans/the background index worker would.
@(test)
test_lex_yaml_block_scalar_spans_lines :: proc(t: ^testing.T) {
	line1 := "description: |"
	line2 := "  line one of the block"
	line3 := "" // blank line inside the scalar must NOT end it
	line4 := "  line two, still inside"
	line5 := "next_key: value" // indentation back to 0: this ends the scalar

	out: [8]Token

	n1, s1 := lex_yaml(transmute([]u8)line1, .Normal, out[:])
	testing.expectf(t, n1 == 3, "line1: want 3 tokens (key, ':', '|'), got %d", n1)
	testing.expectf(t, s1 != .Normal, "line1: want a non-Normal (in-scalar) state after '|', got %v", s1)

	n2, s2 := lex_yaml(transmute([]u8)line2, s1, out[:])
	testing.expectf(t, n2 == 0, "line2: want 0 tokens (scalar content isn't parsed), got %d", n2)
	testing.expectf(t, s2 == s1, "line2: still inside the scalar, state must be unchanged, got %v want %v", s2, s1)

	n3, s3 := lex_yaml(transmute([]u8)line3, s2, out[:])
	testing.expectf(t, n3 == 0, "line3 (blank): want 0 tokens, got %d", n3)
	testing.expectf(t, s3 == s1, "line3 (blank): a blank line must NOT end the scalar, got %v want %v", s3, s1)

	n4, s4 := lex_yaml(transmute([]u8)line4, s3, out[:])
	testing.expectf(t, n4 == 0, "line4: want 0 tokens, got %d", n4)
	testing.expectf(t, s4 == s1, "line4: still inside the scalar, got %v want %v", s4, s1)

	n5, s5 := lex_yaml(transmute([]u8)line5, s4, out[:])
	testing.expectf(t, n5 == 2, "line5: want 2 tokens (key/colon), got %d", n5)
	testing.expectf(t, s5 == .Normal, "line5: indentation dropped to the key's own level, scalar must end, got %v", s5)
	if n5 == 2 {
		ytok_eq(t, out[0], 0, len("next_key"), .Json_Key, "key after scalar ends")
	}
}

// Empty input: no tokens, no crash, state_in honoured.
@(test)
test_lex_yaml_empty :: proc(t: ^testing.T) {
	out: [8]Token
	n, state := lex_yaml(nil, .Normal, out[:])
	testing.expectf(t, n == 0, "want 0 tokens on empty line, got %d", n)
	testing.expectf(t, state == .Normal, "empty line preserves state_in, got %v", state)
}

// THE lesson-1 test: the block-scalar state transition must be computed
// correctly even when `out` has zero capacity -- the state must never
// depend on whether a token could actually be written. Mirrors
// lex_markdown_test's identical check for the fence toggle.
@(test)
test_lex_yaml_block_scalar_open_state_survives_zero_capacity_out :: proc(t: ^testing.T) {
	line := "description: |"
	out: [0]Token
	n, state := lex_yaml(transmute([]u8)line, .Normal, out[:])
	testing.expectf(t, n == 0, "want 0 tokens written (capacity 0), got %d", n)
	testing.expectf(t, state != .Normal, "want a non-Normal (in-scalar) state even though no token could be written, got %v", state)
}

@(test)
test_lex_yaml_block_scalar_close_state_survives_zero_capacity_out :: proc(t: ^testing.T) {
	line1 := "description: |"
	out8: [8]Token
	_, s1 := lex_yaml(transmute([]u8)line1, .Normal, out8[:])

	line2 := "next_key: value"
	out0: [0]Token
	n2, s2 := lex_yaml(transmute([]u8)line2, s1, out0[:])
	testing.expectf(t, n2 == 0, "want 0 tokens written (capacity 0), got %d", n2)
	testing.expectf(t, s2 == .Normal, "want state Normal (scalar ended) even though no token could be written, got %v", s2)
}

// A line producing more matches than `out` can hold must stop at capacity.
@(test)
test_lex_yaml_stops_at_capacity :: proc(t: ^testing.T) {
	line := `a: 1, b: 2, c: 3`
	bytes := transmute([]u8)line
	out: [2]Token
	n, state := lex_yaml(bytes, .Normal, out[:])
	testing.expectf(t, n == 2, "want exactly 2 tokens (out's capacity), got %d", n)
	testing.expectf(t, state == .Normal, "want state Normal (no block scalar involved), got %v", state)
}
