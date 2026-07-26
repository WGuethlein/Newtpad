package base

import "core:strings"
import "core:testing"

// Written before lex_log's real implementation (see lex_log.odin's header) —
// run against the STUB (always returns 0) first and watch every non-empty
// case fail, then again after the implementation lands and watch them all
// pass. See task-1-report.md for both runs' output.

@(private = "file")
tok_eq :: proc(t: ^testing.T, got: Token, want_start, want_len: int, want_kind: Token_Kind, label: string) {
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

// A line carrying all four patterns: an ISO-8601 timestamp at line start, a
// level word, a double-quoted string (with an escaped backslash inside it,
// the shape a Windows path produces), and a bare number. Offsets are found
// with strings.index rather than hand-counted, so a miscount in the test
// can't quietly agree with a miscount in the lexer.
@(test)
test_lex_log_all_patterns :: proc(t: ^testing.T) {
	line := `2026-07-25T10:23:45Z ERROR failed to open "C:\log.txt" after 42 retries`
	bytes := transmute([]u8)line
	out: [8]Token
	n := lex_log(bytes, out[:])
	testing.expectf(t, n == 4, "want 4 tokens, got %d", n)
	if n != 4 {return}

	ts_len := len("2026-07-25T10:23:45Z")
	tok_eq(t, out[0], 0, ts_len, .Number, "timestamp")

	lvl_start := strings.index(line, "ERROR")
	tok_eq(t, out[1], lvl_start, len("ERROR"), .Keyword, "level")

	str_start := strings.index(line, `"C:\log.txt"`)
	tok_eq(t, out[2], str_start, len(`"C:\log.txt"`), .String, "string")

	num_start := strings.index(line, " 42 ") + 1
	tok_eq(t, out[3], num_start, len("42"), .Number, "number")
}

// A bracketed timestamp is the other recognized shape (syslog-style), also
// anchored at line start.
@(test)
test_lex_log_bracketed_timestamp :: proc(t: ^testing.T) {
	line := "[2026-07-25 10:23:45] INFO started"
	bytes := transmute([]u8)line
	out: [8]Token
	n := lex_log(bytes, out[:])
	testing.expectf(t, n == 2, "want 2 tokens, got %d", n)
	if n != 2 {return}
	tok_eq(t, out[0], 0, len("[2026-07-25 10:23:45]"), .Number, "bracketed timestamp")
	lvl_start := strings.index(line, "INFO")
	tok_eq(t, out[1], lvl_start, len("INFO"), .Keyword, "level")
}

// No recognizable pattern anywhere: zero tokens, not a crash, not a spurious
// match.
@(test)
test_lex_log_none :: proc(t: ^testing.T) {
	line := "just a plain line with no markers at all"
	bytes := transmute([]u8)line
	out: [8]Token
	n := lex_log(bytes, out[:])
	testing.expectf(t, n == 0, "want 0 tokens, got %d", n)
}

// A level word appearing only as a substring of a larger word must not
// match — "PREINFO" contains "INFO", "ERRORCODE" contains "ERROR", neither
// is a level word. The bare number after "=" still must match, proving the
// non-match isn't from bailing out of the whole line.
@(test)
test_lex_log_level_inside_larger_word :: proc(t: ^testing.T) {
	line := "PREINFO nothing happens then ERRORCODE=5"
	bytes := transmute([]u8)line
	out: [8]Token
	n := lex_log(bytes, out[:])
	testing.expectf(t, n == 1, "want 1 token (just the bare number), got %d", n)
	if n != 1 {return}
	num_start := strings.index(line, "=5") + 1
	tok_eq(t, out[0], num_start, 1, .Number, "bare number after ERRORCODE=")
}

// A quote that never closes must not be read as a string running past the
// line's end, and must not cause the scan to run off the end of `line`
// (which would be an out-of-bounds read on a real buffer, not just a wrong
// answer).
@(test)
test_lex_log_unterminated_quote :: proc(t: ^testing.T) {
	line := `unterminated: "abc`
	bytes := transmute([]u8)line
	out: [8]Token
	n := lex_log(bytes, out[:])
	testing.expectf(t, n == 0, "want 0 tokens (no closing quote), got %d", n)
}

// Empty input: no tokens, no crash.
@(test)
test_lex_log_empty :: proc(t: ^testing.T) {
	out: [8]Token
	n := lex_log(nil, out[:])
	testing.expectf(t, n == 0, "want 0 tokens on empty line, got %d", n)
}

// A line producing more matches than `out` can hold must stop at capacity,
// not overflow it. Five level words, an `out` of 2.
@(test)
test_lex_log_stops_at_capacity :: proc(t: ^testing.T) {
	line := "ERROR WARN INFO DEBUG TRACE"
	bytes := transmute([]u8)line
	out: [2]Token
	n := lex_log(bytes, out[:])
	testing.expectf(t, n == 2, "want exactly 2 tokens (out's capacity), got %d", n)
	if n != 2 {return}
	tok_eq(t, out[0], 0, len("ERROR"), .Keyword, "first level word")
	warn_start := strings.index(line, "WARN")
	tok_eq(t, out[1], warn_start, len("WARN"), .Keyword, "second level word")
}

// ---------------------------------------------------------------------------
// lex_json
//
// Written before lex_json's real implementation (see lex_json.odin's header)
// -- run against a stub (always returns 0) first and watch every non-empty
// case fail, then again after the implementation lands and watch them all
// pass. See task-2-report.md for both runs' output.

// A string immediately followed by ':' (no whitespace) is a Json_Key, not a
// String -- the one distinction that makes JSON highlighting worth having
// over generic string colouring.
@(test)
test_lex_json_key_vs_value :: proc(t: ^testing.T) {
	line := `{"name": "Alice"}`
	bytes := transmute([]u8)line
	out: [8]Token
	n := lex_json(bytes, out[:])
	testing.expectf(t, n == 5, "want 5 tokens, got %d", n)
	if n != 5 {return}
	tok_eq(t, out[0], 0, 1, .Punct, "{")
	name_start := strings.index(line, `"name"`)
	tok_eq(t, out[1], name_start, len(`"name"`), .Json_Key, "\"name\" is a key")
	colon_start := strings.index(line, ":")
	tok_eq(t, out[2], colon_start, 1, .Punct, ":")
	val_start := strings.index(line, `"Alice"`)
	tok_eq(t, out[3], val_start, len(`"Alice"`), .String, "\"Alice\" is a value")
	tok_eq(t, out[4], len(line) - 1, 1, .Punct, "}")
}

// The ':' need not be adjacent to the closing quote -- whitespace between a
// key's string and its colon must not turn the key into a plain String.
@(test)
test_lex_json_key_with_whitespace_before_colon :: proc(t: ^testing.T) {
	line := `{"name"   : "Alice"}`
	bytes := transmute([]u8)line
	out: [8]Token
	n := lex_json(bytes, out[:])
	testing.expectf(t, n == 5, "want 5 tokens, got %d", n)
	if n != 5 {return}
	name_start := strings.index(line, `"name"`)
	tok_eq(t, out[1], name_start, len(`"name"`), .Json_Key, "\"name\" is still a key across whitespace")
}

// A colon appearing *inside* a string's contents must not make that string
// look like a key -- only a ':' found after the closing quote counts.
@(test)
test_lex_json_string_value_containing_colon :: proc(t: ^testing.T) {
	line := `{"a": "x:y"}`
	bytes := transmute([]u8)line
	out: [8]Token
	n := lex_json(bytes, out[:])
	testing.expectf(t, n == 5, "want 5 tokens, got %d", n)
	if n != 5 {return}
	val_start := strings.index(line, `"x:y"`)
	tok_eq(t, out[3], val_start, len(`"x:y"`), .String, "\"x:y\" is a value despite its internal ':'")
}

// Negative integer.
@(test)
test_lex_json_number_negative :: proc(t: ^testing.T) {
	line := `[-3]`
	bytes := transmute([]u8)line
	out: [8]Token
	n := lex_json(bytes, out[:])
	testing.expectf(t, n == 3, "want 3 tokens, got %d", n)
	if n != 3 {return}
	tok_eq(t, out[1], 1, 2, .Number, "-3")
}

// Fractional number, no exponent.
@(test)
test_lex_json_number_fraction :: proc(t: ^testing.T) {
	line := `[0.5]`
	bytes := transmute([]u8)line
	out: [8]Token
	n := lex_json(bytes, out[:])
	testing.expectf(t, n == 3, "want 3 tokens, got %d", n)
	if n != 3 {return}
	tok_eq(t, out[1], 1, 3, .Number, "0.5")
}

// Exponent with an explicit sign.
@(test)
test_lex_json_number_exponent_signed :: proc(t: ^testing.T) {
	line := `[3.14e-2]`
	bytes := transmute([]u8)line
	out: [8]Token
	n := lex_json(bytes, out[:])
	testing.expectf(t, n == 3, "want 3 tokens, got %d", n)
	if n != 3 {return}
	tok_eq(t, out[1], 1, 7, .Number, "3.14e-2")
}

// Exponent with no sign.
@(test)
test_lex_json_number_exponent_unsigned :: proc(t: ^testing.T) {
	line := `[1e10]`
	bytes := transmute([]u8)line
	out: [8]Token
	n := lex_json(bytes, out[:])
	testing.expectf(t, n == 3, "want 3 tokens, got %d", n)
	if n != 3 {return}
	tok_eq(t, out[1], 1, 4, .Number, "1e10")
}

// Malformed: a leading '.' with no integer part is invalid JSON, but it is
// plausibly a number and must be coloured as one, not refused.
@(test)
test_lex_json_number_malformed_leading_dot :: proc(t: ^testing.T) {
	line := `.5`
	bytes := transmute([]u8)line
	out: [8]Token
	n := lex_json(bytes, out[:])
	testing.expectf(t, n == 1, "want 1 token, got %d", n)
	if n != 1 {return}
	tok_eq(t, out[0], 0, 2, .Number, ".5")
}

// Malformed: an exponent marker with no digits after it must not be
// consumed -- "1e" colours "1" and leaves the bare "e" unlexed, rather than
// running past the line or refusing the leading digit too.
@(test)
test_lex_json_number_malformed_dangling_exponent :: proc(t: ^testing.T) {
	line := `1e`
	bytes := transmute([]u8)line
	out: [8]Token
	n := lex_json(bytes, out[:])
	testing.expectf(t, n == 1, "want 1 token, got %d", n)
	if n != 1 {return}
	tok_eq(t, out[0], 0, 1, .Number, "1")
}

// Malformed: a run of dashes with a digit only at the end. The first '-' is
// not a number (nothing plausible follows it) and is skipped; the second
// '-' starts a genuine "-3".
@(test)
test_lex_json_number_malformed_double_dash :: proc(t: ^testing.T) {
	line := `--3`
	bytes := transmute([]u8)line
	out: [8]Token
	n := lex_json(bytes, out[:])
	testing.expectf(t, n == 1, "want 1 token, got %d", n)
	if n != 1 {return}
	tok_eq(t, out[0], 1, 2, .Number, "-3")
}

// Malformed: a hex-looking literal. JSON has no hex numbers, so this
// colours the two plausible decimal runs either side of the 'x' and skips
// the 'x' itself -- not a single wrong token spanning "0x10", not a crash.
@(test)
test_lex_json_number_malformed_hex_prefix :: proc(t: ^testing.T) {
	line := `0x10`
	bytes := transmute([]u8)line
	out: [8]Token
	n := lex_json(bytes, out[:])
	testing.expectf(t, n == 2, "want 2 tokens, got %d", n)
	if n != 2 {return}
	tok_eq(t, out[0], 0, 1, .Number, "0")
	tok_eq(t, out[1], 2, 2, .Number, "10")
}

// true/false/null are Keyword; nothing else is.
@(test)
test_lex_json_keywords :: proc(t: ^testing.T) {
	line := `[true, false, null]`
	bytes := transmute([]u8)line
	out: [8]Token
	n := lex_json(bytes, out[:])
	testing.expectf(t, n == 7, "want 7 tokens, got %d", n)
	if n != 7 {return}
	true_start := strings.index(line, "true")
	tok_eq(t, out[1], true_start, len("true"), .Keyword, "true")
	false_start := strings.index(line, "false")
	tok_eq(t, out[3], false_start, len("false"), .Keyword, "false")
	null_start := strings.index(line, "null")
	tok_eq(t, out[5], null_start, len("null"), .Keyword, "null")
}

// Structural characters are Punct and nothing more.
@(test)
test_lex_json_structural_punct :: proc(t: ^testing.T) {
	line := `{}[],:`
	bytes := transmute([]u8)line
	out: [8]Token
	n := lex_json(bytes, out[:])
	testing.expectf(t, n == 6, "want 6 tokens, got %d", n)
	if n != 6 {return}
	for i in 0 ..< 6 {
		tok_eq(t, out[i], i, 1, .Punct, "structural char")
	}
}

// An escaped quote inside a string must not end it early.
@(test)
test_lex_json_string_escaped_quote :: proc(t: ^testing.T) {
	line := `"a\"b"`
	bytes := transmute([]u8)line
	out: [8]Token
	n := lex_json(bytes, out[:])
	testing.expectf(t, n == 1, "want 1 token, got %d", n)
	if n != 1 {return}
	tok_eq(t, out[0], 0, len(line), .String, `"a\"b" as one token`)
}

// Unlike lex_log's unterminated quote (0 tokens -- no match), a JSON
// unterminated string colours to the line's end: "the lexer colours, it
// does not validate" (task-2 brief), and an unterminated string is exactly
// when you're staring at broken JSON and most want the colour.
@(test)
test_lex_json_unterminated_string :: proc(t: ^testing.T) {
	line := `"abc`
	bytes := transmute([]u8)line
	out: [8]Token
	n := lex_json(bytes, out[:])
	testing.expectf(t, n == 1, "want 1 token, got %d", n)
	if n != 1 {return}
	tok_eq(t, out[0], 0, len(line), .String, "unterminated string runs to line end")
}

// A malformed fixture -- an unbalanced opening brace -- must not crash or
// hang, and the lone '{' is just a Punct.
@(test)
test_lex_json_unbalanced_brace :: proc(t: ^testing.T) {
	line := `{"a": 1`
	bytes := transmute([]u8)line
	out: [8]Token
	n := lex_json(bytes, out[:])
	testing.expectf(t, n == 4, "want 4 tokens, got %d", n)
	if n != 4 {return}
	tok_eq(t, out[0], 0, 1, .Punct, "{")
	a_start := strings.index(line, `"a"`)
	tok_eq(t, out[1], a_start, len(`"a"`), .Json_Key, "\"a\" is a key")
	colon_start := strings.index(line, ":")
	tok_eq(t, out[2], colon_start, 1, .Punct, ":")
	tok_eq(t, out[3], len(line) - 1, 1, .Number, "1")
}

// Empty input: no tokens, no crash.
@(test)
test_lex_json_empty :: proc(t: ^testing.T) {
	out: [8]Token
	n := lex_json(nil, out[:])
	testing.expectf(t, n == 0, "want 0 tokens on empty line, got %d", n)
}

// A line producing more matches than `out` can hold must stop at capacity.
@(test)
test_lex_json_stops_at_capacity :: proc(t: ^testing.T) {
	line := `[1,2,3,4,5]`
	bytes := transmute([]u8)line
	out: [2]Token
	n := lex_json(bytes, out[:])
	testing.expectf(t, n == 2, "want exactly 2 tokens (out's capacity), got %d", n)
	if n != 2 {return}
	tok_eq(t, out[0], 0, 1, .Punct, "[")
	tok_eq(t, out[1], 1, 1, .Number, "1")
}
