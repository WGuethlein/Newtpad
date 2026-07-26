package base

import "core:strings"
import "core:testing"

// Written before lex_delimited's real implementation, same discipline as
// every other lexer in this batch: run against a stub first and watch these
// fail, then again once the implementation lands. See lex_delimited.odin's
// header for the grammar this covers.

@(private = "file")
dtok_eq :: proc(t: ^testing.T, got: Token, want_start, want_len: int, want_kind: Token_Kind, label: string) {
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

// A plain unquoted row: two text fields and one that looks like a number,
// comma-delimited. The delimiter itself is Punct; a purely-numeric field is
// Number; a text field gets no token at all (plain -- there is no generic
// "this is a text cell" colour, and inventing one isn't worth a 10th Syn_*
// role for this batch).
@(test)
test_lex_delimited_csv_basic_row :: proc(t: ^testing.T) {
	line := `Alice,42,Engineer`
	bytes := transmute([]u8)line
	out: [8]Token
	n := lex_delimited(bytes, ',', out[:])
	testing.expectf(t, n == 3, "want 3 tokens (2 commas + 1 number, text fields plain), got %d", n)
	if n != 3 {return}
	dtok_eq(t, out[0], strings.index(line, ","), 1, .Punct, "first comma")
	dtok_eq(t, out[1], strings.index(line, "42"), 2, .Number, "42")
	dtok_eq(t, out[2], strings.index(line, ",Engineer"), 1, .Punct, "second comma")
}

// A quoted field containing the delimiter must not be split by it -- the
// entire quoted span, delimiter included, is one String token.
@(test)
test_lex_delimited_quoted_field_contains_delimiter :: proc(t: ^testing.T) {
	line := `"Doe, John",30`
	bytes := transmute([]u8)line
	out: [8]Token
	n := lex_delimited(bytes, ',', out[:])
	testing.expectf(t, n == 3, "want 3 tokens, got %d", n)
	if n != 3 {return}
	dtok_eq(t, out[0], 0, len(`"Doe, John"`), .String, "quoted field spans the embedded comma")
	dtok_eq(t, out[1], len(`"Doe, John"`), 1, .Punct, "delimiter after the quoted field")
	dtok_eq(t, out[2], len(`"Doe, John",`), 2, .Number, "30")
}

// RFC4180 escapes an embedded quote by doubling it ("") -- that doubled pair
// must not end the field early.
@(test)
test_lex_delimited_escaped_quote_inside_field :: proc(t: ^testing.T) {
	line := `"she said ""hi""",1`
	bytes := transmute([]u8)line
	out: [8]Token
	n := lex_delimited(bytes, ',', out[:])
	testing.expectf(t, n == 3, "want 3 tokens, got %d", n)
	if n != 3 {return}
	field_len := len(`"she said ""hi"""`)
	dtok_eq(t, out[0], 0, field_len, .String, "doubled-quote escape doesn't end the field early")
}

// TSV: the delimiter is a tab, not a comma -- a bare comma inside a field is
// just ordinary field content (no token), while the tab is Punct.
@(test)
test_lex_delimited_tsv_uses_tab :: proc(t: ^testing.T) {
	line := "a,b\t7"
	bytes := transmute([]u8)line
	out: [8]Token
	n := lex_delimited(bytes, '\t', out[:])
	testing.expectf(t, n == 2, "want 2 tokens (tab + number; comma is plain content), got %d", n)
	if n != 2 {return}
	dtok_eq(t, out[0], 3, 1, .Punct, "tab delimiter")
	dtok_eq(t, out[1], 4, 1, .Number, "7")
}

// An unquoted field that is NOT purely numeric (e.g. "3rd") must not be
// coloured Number at all -- coluring just the leading digits would assert a
// number where the field is actually text.
@(test)
test_lex_delimited_partial_number_field_stays_plain :: proc(t: ^testing.T) {
	line := `3rd,ok`
	bytes := transmute([]u8)line
	out: [8]Token
	n := lex_delimited(bytes, ',', out[:])
	testing.expectf(t, n == 1, "want 1 token (just the comma), got %d", n)
	if n != 1 {return}
	dtok_eq(t, out[0], 3, 1, .Punct, "comma")
}

// An unterminated quoted field colours to the line's end rather than
// producing nothing -- same "colour, don't validate" contract as
// lex_json/lex_c's unterminated strings, and the same documented scope cut as
// lex_xml's unterminated tag: a quoted CSV field containing a literal
// embedded newline (legal per RFC4180) is NOT tracked across physical lines;
// it simply re-starts fresh, unquoted, on the next line. See this file's
// header for why that trade was taken over adding Lex_State here.
@(test)
test_lex_delimited_unterminated_quote_colours_to_eol :: proc(t: ^testing.T) {
	line := `"open field, no close`
	bytes := transmute([]u8)line
	out: [8]Token
	n := lex_delimited(bytes, ',', out[:])
	testing.expectf(t, n == 1, "want 1 token, got %d", n)
	if n != 1 {return}
	dtok_eq(t, out[0], 0, len(line), .String, "unterminated quoted field runs to line end")
}

// A negative decimal in an unquoted field is still a Number field.
@(test)
test_lex_delimited_negative_decimal_field :: proc(t: ^testing.T) {
	line := `-3.5,x`
	bytes := transmute([]u8)line
	out: [8]Token
	n := lex_delimited(bytes, ',', out[:])
	testing.expectf(t, n == 2, "want 2 tokens, got %d", n)
	if n != 2 {return}
	dtok_eq(t, out[0], 0, len("-3.5"), .Number, "-3.5")
	dtok_eq(t, out[1], len("-3.5"), 1, .Punct, "comma")
}

// Empty input: no tokens, no crash.
@(test)
test_lex_delimited_empty :: proc(t: ^testing.T) {
	out: [8]Token
	n := lex_delimited(nil, ',', out[:])
	testing.expectf(t, n == 0, "want 0 tokens on empty line, got %d", n)
}

// Empty fields between consecutive delimiters ("a,,b") must not confuse the
// scanner into skipping or double-counting a delimiter.
@(test)
test_lex_delimited_empty_fields :: proc(t: ^testing.T) {
	line := `a,,b`
	bytes := transmute([]u8)line
	out: [8]Token
	n := lex_delimited(bytes, ',', out[:])
	testing.expectf(t, n == 2, "want 2 tokens (both commas; text fields plain), got %d", n)
	if n != 2 {return}
	dtok_eq(t, out[0], 1, 1, .Punct, "first comma")
	dtok_eq(t, out[1], 2, 1, .Punct, "second comma")
}

// A row producing more matches than `out` can hold must stop at capacity,
// not overflow it.
@(test)
test_lex_delimited_stops_at_capacity :: proc(t: ^testing.T) {
	line := `1,2,3,4,5`
	bytes := transmute([]u8)line
	out: [2]Token
	n := lex_delimited(bytes, ',', out[:])
	testing.expectf(t, n == 2, "want exactly 2 tokens (out's capacity), got %d", n)
	if n != 2 {return}
	dtok_eq(t, out[0], 0, 1, .Number, "1")
	dtok_eq(t, out[1], 1, 1, .Punct, "first comma")
}
