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
