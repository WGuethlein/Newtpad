package base

import "core:strings"
import "core:testing"

// Written before lex_c's real implementation (see lex_c.odin's header) — run
// against the STUB (always returns 0 tokens, state_in unchanged) first and
// watch every non-empty case fail, then again after the implementation lands
// and watch them all pass. See task-4-report.md for both runs' output.
//
// Grammar tests below use small ad-hoc Keyword_Sets built to exercise exactly
// one feature each, rather than always reaching for a real per-language
// table — keeps each test's cause and effect obvious. The per-language tables
// (further down in lex_c.odin) get their own, smaller set of tests later in
// this file, checking that the *data* is wired up, not re-testing the shared
// grammar again per language.

@(private = "file")
ctok_eq :: proc(t: ^testing.T, got: Token, want_start, want_len: int, want_kind: Token_Kind, label: string) {
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

@(private = "file")
LC_TEST_KW_C :: Keyword_Set {
	keywords   = {"return", "if", "else", "const"},
	types      = {"int", "char", "void"},
	type_intro = {"struct", "union", "enum"},
	preproc    = true,
	digit_sep  = '_',
	raw_string = .None,
	backtick   = false,
}

// --- comments ---------------------------------------------------------

@(test)
test_lex_c_line_comment :: proc(t: ^testing.T) {
	line := `int x = 1; // trailing remark`
	kw := LC_TEST_KW_C
	out: [8]Token
	n, state := lex_c(transmute([]u8)line, .Normal, &kw, out[:])
	testing.expectf(t, state == .Normal, "line comment doesn't change state, got %v", state)
	// find the comment token among the results
	c_start := strings.index(line, "//")
	found := false
	for i in 0 ..< n {
		if out[i].start == c_start {
			ctok_eq(t, out[i], c_start, len(line) - c_start, .Comment, "// to line end")
			found = true
		}
	}
	testing.expectf(t, found, "want a Comment token at %d, got none among %d tokens", c_start, n)
}

// Block comment opened and closed on the same line: one Comment token, state
// unaffected either side of it.
@(test)
test_lex_c_block_comment_single_line :: proc(t: ^testing.T) {
	line := `before /* a comment */ after`
	kw := LC_TEST_KW_C
	out: [8]Token
	n, state := lex_c(transmute([]u8)line, .Normal, &kw, out[:])
	testing.expectf(t, state == .Normal, "closed block comment leaves state Normal, got %v", state)
	c_start := strings.index(line, "/*")
	c_end := strings.index(line, "*/") + 2
	found := false
	for i in 0 ..< n {
		if out[i].start == c_start {
			ctok_eq(t, out[i], c_start, c_end - c_start, .Comment, "/* ... */ whole run")
			found = true
		}
	}
	testing.expectf(t, found, "want a Comment token at %d", c_start)
}

// THE non-nesting case: "/* /* */" must end at the FIRST "*/", not treat the
// inner "/*" as opening a nested comment. Getting this "helpfully" wrong is
// exactly the classic bug the task brief calls out.
@(test)
test_lex_c_block_comment_does_not_nest :: proc(t: ^testing.T) {
	line := `/* /* */ int x;`
	kw := LC_TEST_KW_C
	out: [8]Token
	n, state := lex_c(transmute([]u8)line, .Normal, &kw, out[:])
	testing.expectf(t, state == .Normal, "comment closes at the first */, want Normal, got %v", state)
	want_end := strings.index(line, "*/") + 2
	testing.expectf(t, n >= 1, "want at least 1 token, got %d", n)
	if n >= 1 {
		ctok_eq(t, out[0], 0, want_end, .Comment, "comment ends at the FIRST */, not the second")
	}
	// "int" and "x" after the comment must still be lexed as real code.
	int_start := strings.index(line, "int")
	int_found := false
	for i in 0 ..< n {
		if out[i].start == int_start {
			ctok_eq(t, out[i], int_start, 3, .Type, "int after the (non-nested) comment")
			int_found = true
		}
	}
	testing.expectf(t, int_found, "want 'int' lexed as Type after the comment closes")
}

// A block comment left open at the end of the line must report In_Comment,
// and every byte from the opener to the line's end is one Comment token.
@(test)
test_lex_c_block_comment_open_at_eol :: proc(t: ^testing.T) {
	line := `int x; /* still going`
	kw := LC_TEST_KW_C
	out: [8]Token
	n, state := lex_c(transmute([]u8)line, .Normal, &kw, out[:])
	testing.expectf(t, state == .In_Comment, "unterminated block comment -> In_Comment, got %v", state)
	c_start := strings.index(line, "/*")
	found := false
	for i in 0 ..< n {
		if out[i].start == c_start {
			ctok_eq(t, out[i], c_start, len(line) - c_start, .Comment, "comment runs to line end, still open")
			found = true
		}
	}
	testing.expectf(t, found, "want the still-open comment token")
}

// The three-line thread: opens, continues through a markerless middle line,
// closes on the third — mirrors lex_xml's proof of the same shape.
@(test)
test_lex_c_block_comment_spans_three_lines :: proc(t: ^testing.T) {
	line1 := `int x; /* start of`
	line2 := `a long comment with no markers at all`
	line3 := `the end */ int y;`
	kw := LC_TEST_KW_C
	out: [8]Token

	n1, s1 := lex_c(transmute([]u8)line1, .Normal, &kw, out[:])
	testing.expectf(t, s1 == .In_Comment, "line1: want In_Comment, got %v", s1)
	_ = n1

	n2, s2 := lex_c(transmute([]u8)line2, s1, &kw, out[:])
	testing.expectf(t, s2 == .In_Comment, "line2: still open, got %v", s2)
	testing.expectf(t, n2 == 1, "line2: want 1 token (whole line is comment), got %d", n2)
	if n2 == 1 {
		ctok_eq(t, out[0], 0, len(line2), .Comment, "line2: entirely inside the open comment")
	}

	n3, s3 := lex_c(transmute([]u8)line3, s2, &kw, out[:])
	testing.expectf(t, s3 == .Normal, "line3: comment closes here, want Normal, got %v", s3)
	c_end := strings.index(line3, "*/") + 2
	found := false
	for i in 0 ..< n3 {
		if out[i].start == 0 && out[i].kind == .Comment {
			ctok_eq(t, out[i], 0, c_end, .Comment, "line3: whole line up through the close")
			found = true
		}
	}
	testing.expectf(t, found, "want the closing comment token on line3")
}

// THE regression this task's brief calls out by name: when `out` fills
// before the line does, the scan must keep going for STATE even though it
// stops EMITTING — a dense line whose comment opener sits past the 64th
// token must still report In_Comment, not silently .Normal. Built with a
// tiny `out` (2 slots) and enough Punct-producing structural characters
// before the comment opener to exhaust it.
@(test)
test_lex_c_stops_emitting_but_not_scanning_at_capacity :: proc(t: ^testing.T) {
	line := `{}{}{}{}{}/*`
	kw := LC_TEST_KW_C
	out: [2]Token
	n, state := lex_c(transmute([]u8)line, .Normal, &kw, out[:])
	testing.expectf(t, n == 2, "want exactly 2 tokens (out's capacity), got %d", n)
	testing.expectf(t, state == .In_Comment, "want In_Comment (scan must continue past emit capacity), got %v", state)
}

// --- strings and char literals -----------------------------------------

@(test)
test_lex_c_string_with_escape :: proc(t: ^testing.T) {
	line := `char *s = "a\"b";`
	kw := LC_TEST_KW_C
	out: [8]Token
	n, _ := lex_c(transmute([]u8)line, .Normal, &kw, out[:])
	str_start := strings.index(line, `"a\"b"`)
	found := false
	for i in 0 ..< n {
		if out[i].start == str_start {
			ctok_eq(t, out[i], str_start, len(`"a\"b"`), .String, `escaped quote doesn't end the string early`)
			found = true
		}
	}
	testing.expectf(t, found, "want the string token")
}

@(test)
test_lex_c_unterminated_string_colours_to_eol :: proc(t: ^testing.T) {
	line := `x = "abc`
	kw := LC_TEST_KW_C
	out: [8]Token
	n, state := lex_c(transmute([]u8)line, .Normal, &kw, out[:])
	testing.expectf(t, state == .Normal, "an unterminated string is line-local, not carried state, got %v", state)
	str_start := strings.index(line, `"`)
	found := false
	for i in 0 ..< n {
		if out[i].start == str_start {
			ctok_eq(t, out[i], str_start, len(line) - str_start, .String, "unterminated string runs to line end")
			found = true
		}
	}
	testing.expectf(t, found, "want the unterminated string token")
}

@(test)
test_lex_c_char_literal :: proc(t: ^testing.T) {
	line := `char c = '\n';`
	kw := LC_TEST_KW_C
	out: [8]Token
	n, _ := lex_c(transmute([]u8)line, .Normal, &kw, out[:])
	lit_start := strings.index(line, `'\n'`)
	found := false
	for i in 0 ..< n {
		if out[i].start == lit_start {
			ctok_eq(t, out[i], lit_start, len(`'\n'`), .String, "char literal reuses the String bucket")
			found = true
		}
	}
	testing.expectf(t, found, "want the char literal token")
}

// --- raw / backtick strings, same-line only -----------------------------

@(test)
test_lex_c_rust_raw_string_same_line :: proc(t: ^testing.T) {
	line := `let re = r#"a"quote"b"#;`
	kw := Keyword_Set{raw_string = .Rust, digit_sep = '_'}
	out: [8]Token
	n, _ := lex_c(transmute([]u8)line, .Normal, &kw, out[:])
	rs_start := strings.index(line, `r#"`)
	rs_end := strings.index(line, `"#`) + len(`"#`)
	found := false
	for i in 0 ..< n {
		if out[i].start == rs_start {
			ctok_eq(t, out[i], rs_start, rs_end - rs_start, .String, "r#\"...\"# as one token, no escape processing")
			found = true
		}
	}
	testing.expectf(t, found, "want the raw string token")
}

@(test)
test_lex_c_cpp_raw_string_same_line :: proc(t: ^testing.T) {
	line := `auto re = R"delim(a)b)delim";`
	kw := Keyword_Set{raw_string = .Cpp, digit_sep = '\''}
	out: [8]Token
	n, _ := lex_c(transmute([]u8)line, .Normal, &kw, out[:])
	rs_start := strings.index(line, `R"delim(`)
	rs_end := strings.index(line, `)delim"`) + len(`)delim"`)
	found := false
	for i in 0 ..< n {
		if out[i].start == rs_start {
			ctok_eq(t, out[i], rs_start, rs_end - rs_start, .String, "R\"delim(...)delim\" matched by its own delimiter, not the first ')'")
			found = true
		}
	}
	testing.expectf(t, found, "want the C++ raw string token")
}

@(test)
test_lex_c_backtick_same_line :: proc(t: ^testing.T) {
	line := "x := `hello world`"
	kw := Keyword_Set{backtick = true}
	out: [8]Token
	n, _ := lex_c(transmute([]u8)line, .Normal, &kw, out[:])
	bt_start := strings.index(line, "`")
	found := false
	for i in 0 ..< n {
		if out[i].start == bt_start {
			ctok_eq(t, out[i], bt_start, len(line) - bt_start, .String, "backtick string, whole span")
			found = true
		}
	}
	testing.expectf(t, found, "want the backtick token")
}

// An unterminated backtick is deliberately left PLAIN (no token for the
// tail) rather than coloured "to line end" the way an unterminated ordinary
// string is -- see lex_c.odin's header for why: a multi-line raw/template
// literal is usually valid code, not an error, and this lexer doesn't track
// cross-line raw-string state at all (a Lex_State it doesn't have).
@(test)
test_lex_c_unterminated_backtick_left_plain :: proc(t: ^testing.T) {
	line := "x := `hello"
	kw := Keyword_Set{backtick = true}
	out: [8]Token
	n, state := lex_c(transmute([]u8)line, .Normal, &kw, out[:])
	testing.expectf(t, state == .Normal, "backtick state is never carried across lines, got %v", state)
	bt_start := strings.index(line, "`")
	for i in 0 ..< n {
		testing.expectf(t, out[i].start != bt_start || out[i].kind != .String, "unterminated backtick must not be coloured as a closed/EOL string")
	}
}

// --- numbers -------------------------------------------------------------

@(test)
test_lex_c_number_hex :: proc(t: ^testing.T) {
	line := `x = 0xFF_AA;`
	kw := LC_TEST_KW_C
	out: [8]Token
	n, _ := lex_c(transmute([]u8)line, .Normal, &kw, out[:])
	num_start := strings.index(line, "0x")
	found := false
	for i in 0 ..< n {
		if out[i].start == num_start {
			ctok_eq(t, out[i], num_start, len("0xFF_AA"), .Number, "hex literal with a separator")
			found = true
		}
	}
	testing.expectf(t, found, "want the hex number token")
}

@(test)
test_lex_c_number_hex_float :: proc(t: ^testing.T) {
	line := `x = 0x1p3;`
	kw := LC_TEST_KW_C
	out: [8]Token
	n, _ := lex_c(transmute([]u8)line, .Normal, &kw, out[:])
	num_start := strings.index(line, "0x")
	found := false
	for i in 0 ..< n {
		if out[i].start == num_start {
			ctok_eq(t, out[i], num_start, len("0x1p3"), .Number, "hex float with a 'p' exponent")
			found = true
		}
	}
	testing.expectf(t, found, "want the hex float token")
}

@(test)
test_lex_c_number_binary :: proc(t: ^testing.T) {
	line := `x = 0b1010_1100;`
	kw := LC_TEST_KW_C
	out: [8]Token
	n, _ := lex_c(transmute([]u8)line, .Normal, &kw, out[:])
	num_start := strings.index(line, "0b")
	found := false
	for i in 0 ..< n {
		if out[i].start == num_start {
			ctok_eq(t, out[i], num_start, len("0b1010_1100"), .Number, "binary literal with separators")
			found = true
		}
	}
	testing.expectf(t, found, "want the binary number token")
}

@(test)
test_lex_c_number_octal :: proc(t: ^testing.T) {
	line := `x = 0o755;`
	kw := LC_TEST_KW_C
	out: [8]Token
	n, _ := lex_c(transmute([]u8)line, .Normal, &kw, out[:])
	num_start := strings.index(line, "0o")
	found := false
	for i in 0 ..< n {
		if out[i].start == num_start {
			ctok_eq(t, out[i], num_start, len("0o755"), .Number, "0o-prefixed octal literal")
			found = true
		}
	}
	testing.expectf(t, found, "want the octal number token")
}

@(test)
test_lex_c_number_decimal_separator :: proc(t: ^testing.T) {
	line := `x = 1_000_000;`
	kw := LC_TEST_KW_C
	out: [8]Token
	n, _ := lex_c(transmute([]u8)line, .Normal, &kw, out[:])
	num_start := strings.index(line, "1_000_000")
	found := false
	for i in 0 ..< n {
		if out[i].start == num_start {
			ctok_eq(t, out[i], num_start, len("1_000_000"), .Number, "decimal with digit separators")
			found = true
		}
	}
	testing.expectf(t, found, "want the separated decimal token")
}

@(test)
test_lex_c_number_float_exponent :: proc(t: ^testing.T) {
	line := `x = 3.14e-2;`
	kw := LC_TEST_KW_C
	out: [8]Token
	n, _ := lex_c(transmute([]u8)line, .Normal, &kw, out[:])
	num_start := strings.index(line, "3.14e-2")
	found := false
	for i in 0 ..< n {
		if out[i].start == num_start {
			ctok_eq(t, out[i], num_start, len("3.14e-2"), .Number, "signed float exponent")
			found = true
		}
	}
	testing.expectf(t, found, "want the float token")
}

// --- preprocessor ---------------------------------------------------------

@(test)
test_lex_c_preprocessor_line_then_normal_scan_resumes :: proc(t: ^testing.T) {
	line := `#include "foo.h"`
	kw := LC_TEST_KW_C
	out: [8]Token
	n, state := lex_c(transmute([]u8)line, .Normal, &kw, out[:])
	testing.expectf(t, state == .Normal, "a preprocessor line doesn't change state, got %v", state)
	testing.expectf(t, n >= 2, "want at least 2 tokens (directive + string), got %d", n)
	if n >= 1 {
		ctok_eq(t, out[0], 0, len("#include"), .Keyword, "#include as one Keyword token")
	}
	str_start := strings.index(line, `"foo.h"`)
	found := false
	for i in 0 ..< n {
		if out[i].start == str_start {
			ctok_eq(t, out[i], str_start, len(`"foo.h"`), .String, "the rest of the line still lexes normally")
			found = true
		}
	}
	testing.expectf(t, found, "want the header string still coloured after the directive")
}

@(test)
test_lex_c_preprocessor_disabled_for_language_without_it :: proc(t: ^testing.T) {
	// A language with preproc=false must not treat a leading '#' specially at
	// all (e.g. a JS/TS private class field like "#count", or just stray
	// punctuation) -- this is Keyword_Set data, not a hardcoded C assumption.
	line := `#count = 1;`
	kw := Keyword_Set{preproc = false, digit_sep = '_'}
	out: [8]Token
	n, _ := lex_c(transmute([]u8)line, .Normal, &kw, out[:])
	for i in 0 ..< n {
		testing.expectf(t, out[i].start != 0 || out[i].kind != .Keyword, "leading '#' must not become a Keyword when preproc is false")
	}
}

// --- keywords, types, and the type_intro shape ---------------------------

@(test)
test_lex_c_keyword_and_type :: proc(t: ^testing.T) {
	line := `int main(void) { return 0; }`
	kw := LC_TEST_KW_C
	out: [8]Token
	n, _ := lex_c(transmute([]u8)line, .Normal, &kw, out[:])
	int_found, ret_found, void_found := false, false, false
	for i in 0 ..< n {
		if out[i].start == 0 && out[i].len == 3 {
			ctok_eq(t, out[i], 0, 3, .Type, "'int' is a known type")
			int_found = true
		}
		if out[i].start == strings.index(line, "return") {
			ctok_eq(t, out[i], out[i].start, len("return"), .Keyword, "'return' is a keyword")
			ret_found = true
		}
		if out[i].start == strings.index(line, "void") {
			ctok_eq(t, out[i], out[i].start, len("void"), .Type, "'void' is a known type")
			void_found = true
		}
	}
	testing.expectf(t, int_found && ret_found && void_found, "want int/return/void all classified, got int=%v return=%v void=%v", int_found, ret_found, void_found)
}

// The shape the brief itself gives as an example: an identifier right after
// a type-introducing keyword ("struct") colours Type, even though it is not
// in any hardcoded type list.
@(test)
test_lex_c_type_intro_colours_next_identifier :: proc(t: ^testing.T) {
	line := `struct Widget w;`
	kw := LC_TEST_KW_C
	out: [8]Token
	n, _ := lex_c(transmute([]u8)line, .Normal, &kw, out[:])
	struct_start := 0
	widget_start := strings.index(line, "Widget")
	struct_ok, widget_ok := false, false
	for i in 0 ..< n {
		if out[i].start == struct_start {
			ctok_eq(t, out[i], struct_start, len("struct"), .Keyword, "'struct' itself is a Keyword")
			struct_ok = true
		}
		if out[i].start == widget_start {
			ctok_eq(t, out[i], widget_start, len("Widget"), .Type, "identifier right after 'struct' is Type")
			widget_ok = true
		}
	}
	testing.expectf(t, struct_ok && widget_ok, "want both struct=%v and Widget=%v classified", struct_ok, widget_ok)
	// The chain must not run past one identifier: "w" (the variable) must
	// NOT also be coloured Type.
	w_start := strings.index(line, " w;") + 1
	for i in 0 ..< n {
		testing.expectf(t, out[i].start != w_start || out[i].kind != .Type, "the type_intro chain must stop after ONE identifier")
	}
}

// A plain identifier that is neither a keyword nor a type, and not preceded
// by a type_intro word, must be Token_Kind.None -- not emitted as a token at
// all (highlight_row_spans already drops .None; the point here is that
// lex_c doesn't invent a colour for it).
@(test)
test_lex_c_unknown_identifier_is_none :: proc(t: ^testing.T) {
	line := `frobnicate(widget);`
	kw := LC_TEST_KW_C
	out: [8]Token
	n, _ := lex_c(transmute([]u8)line, .Normal, &kw, out[:])
	for i in 0 ..< n {
		testing.expectf(t, out[i].kind != .None, "lex_c must never emit a .None token (callers rely on absence, not the kind)")
		testing.expectf(t, out[i].start != 0, "'frobnicate' is not a keyword/type and has no type_intro before it -- must not appear as a coloured token")
	}
}

// --- misc ------------------------------------------------------------------

@(test)
test_lex_c_empty_line :: proc(t: ^testing.T) {
	kw := LC_TEST_KW_C
	out: [8]Token
	n, state := lex_c(nil, .Normal, &kw, out[:])
	testing.expectf(t, n == 0, "want 0 tokens on empty line, got %d", n)
	testing.expectf(t, state == .Normal, "empty line preserves state_in, got %v", state)
}

@(test)
test_lex_c_empty_line_inside_comment_stays_open :: proc(t: ^testing.T) {
	kw := LC_TEST_KW_C
	out: [8]Token
	n, state := lex_c(nil, .In_Comment, &kw, out[:])
	testing.expectf(t, n == 0, "want 0 tokens, got %d", n)
	testing.expectf(t, state == .In_Comment, "empty line inside an open comment stays In_Comment, got %v", state)
}

// ---------------------------------------------------------------------------
// lex_c_resync_valid — the anchor-soundness fix.
//
// `*/` alone is not a safe resync anchor: it can occur inside a string or a
// line comment on an otherwise-Normal line, and naively trusting the LAST
// textual occurrence in a window (as the XML lexer's "-->" anchor does,
// safely, only because Lex_State there has no other tracked state) would
// resync into the middle of a string. These tests exercise the validator
// lex_resync_state (program/lex_index.odin) is meant to consult before
// trusting a candidate.

// THE motivating example from the task brief itself: a string containing the
// literal bytes "*/" must be REJECTED as a resync candidate.
@(test)
test_lex_c_resync_valid_rejects_string_contents :: proc(t: ^testing.T) {
	line := `char *s = "*/";`
	kw := LC_TEST_KW_C
	end := strings.index(line, `*/`) + 2
	ok := lex_c_resync_valid(&kw, transmute([]u8)line, end)
	testing.expectf(t, !ok, "a \"*/\" inside a string must not validate as a resync point")
}

// Also from the brief: "*/" inside a line comment must be rejected too.
@(test)
test_lex_c_resync_valid_rejects_line_comment_contents :: proc(t: ^testing.T) {
	line := `// look, */ right there`
	kw := LC_TEST_KW_C
	end := strings.index(line, `*/`) + 2
	ok := lex_c_resync_valid(&kw, transmute([]u8)line, end)
	testing.expectf(t, !ok, "a \"*/\" inside a // comment must not validate as a resync point")
}

// A genuine, self-contained block comment's own closing "*/" must validate.
@(test)
test_lex_c_resync_valid_accepts_real_comment_close :: proc(t: ^testing.T) {
	line := `int x; /* a real comment */ int y;`
	kw := LC_TEST_KW_C
	end := strings.index(line, `*/`) + 2
	ok := lex_c_resync_valid(&kw, transmute([]u8)line, end)
	testing.expectf(t, ok, "a real comment's own closing \"*/\" must validate")
}

// And the close of a comment that was ALREADY open at this line's start (the
// line itself has no "/*" of its own) must also validate -- checked by
// calling with a line that is comment prose up to the close, matching how
// lex_resync_state would present it (see that proc's comment for why the
// Normal-start assumption here is always safe in this direction).
@(test)
test_lex_c_resync_valid_accepts_close_of_already_open_comment :: proc(t: ^testing.T) {
	line := `the end of a long comment */`
	kw := LC_TEST_KW_C
	end := strings.index(line, `*/`) + 2
	ok := lex_c_resync_valid(&kw, transmute([]u8)line, end)
	testing.expectf(t, ok, "closing an already-open comment must validate even though this line has no '/*' of its own")
}

// ---------------------------------------------------------------------------
// Per-language keyword tables (EXT_LEXERS' actual data) — a light smoke test
// per language, not a re-test of the shared grammar: one real keyword, one
// real type, and (where the fixture needs it) the type_intro shape, each
// checked against the ACTUAL package-level table so a typo in the data (a
// word in the wrong bucket, a missing type_intro entry) fails here instead
// of only showing up looking "subtly wrong" in a real file later.

@(private = "file")
lc_word_kind :: proc(line: string, kw: ^Keyword_Set, word: string) -> Token_Kind {
	out: [32]Token
	n, _ := lex_c(transmute([]u8)line, .Normal, kw, out[:])
	start := strings.index(line, word)
	for i in 0 ..< n {
		if out[i].start == start {return out[i].kind}
	}
	return .None
}

@(test)
test_lex_c_kw_table_c :: proc(t: ^testing.T) {
	kw := C_KW
	line := `struct Foo { int x; };`
	testing.expectf(t, lc_word_kind(line, &kw, "struct") == .Keyword, "C: 'struct' is a Keyword")
	testing.expectf(t, lc_word_kind(line, &kw, "Foo") == .Type, "C: identifier after 'struct' is Type")
	testing.expectf(t, lc_word_kind(line, &kw, "int") == .Type, "C: 'int' is a known Type")
}

@(test)
test_lex_c_kw_table_cpp :: proc(t: ^testing.T) {
	kw := CPP_KW
	line := `class Foo : public Bar { virtual void f(); };`
	testing.expectf(t, lc_word_kind(line, &kw, "class") == .Keyword, "C++: 'class' is a Keyword")
	testing.expectf(t, lc_word_kind(line, &kw, "Foo") == .Type, "C++: identifier after 'class' is Type")
	testing.expectf(t, lc_word_kind(line, &kw, "virtual") == .Keyword, "C++: 'virtual' is a Keyword")
	testing.expectf(t, lc_word_kind(line, &kw, "void") == .Type, "C++: 'void' is a known Type")
}

@(test)
test_lex_c_kw_table_cs :: proc(t: ^testing.T) {
	kw := CS_KW
	line := `public class Widget { private readonly int count; }`
	testing.expectf(t, lc_word_kind(line, &kw, "class") == .Keyword, "C#: 'class' is a Keyword")
	testing.expectf(t, lc_word_kind(line, &kw, "Widget") == .Type, "C#: identifier after 'class' is Type")
	testing.expectf(t, lc_word_kind(line, &kw, "int") == .Type, "C#: 'int' is a known Type")
}

@(test)
test_lex_c_kw_table_java :: proc(t: ^testing.T) {
	kw := JAVA_KW
	line := `public class Widget implements Runnable { boolean ok; }`
	testing.expectf(t, lc_word_kind(line, &kw, "class") == .Keyword, "Java: 'class' is a Keyword")
	testing.expectf(t, lc_word_kind(line, &kw, "Widget") == .Type, "Java: identifier after 'class' is Type")
	testing.expectf(t, lc_word_kind(line, &kw, "boolean") == .Type, "Java: 'boolean' is a known Type")
}

@(test)
test_lex_c_kw_table_js :: proc(t: ^testing.T) {
	kw := JS_KW
	line := `class Widget extends Base {}`
	testing.expectf(t, lc_word_kind(line, &kw, "class") == .Keyword, "JS: 'class' is a Keyword")
	testing.expectf(t, lc_word_kind(line, &kw, "Widget") == .Type, "JS: identifier after 'class' is Type")
	testing.expectf(t, lc_word_kind(line, &kw, "const") == .None, "JS: unused word in this fixture is a control check")
	line2 := `const s = ` + "`hello`" + `;`
	testing.expectf(t, lc_word_kind(line2, &kw, "const") == .Keyword, "JS: 'const' is a Keyword")
}

@(test)
test_lex_c_kw_table_ts :: proc(t: ^testing.T) {
	kw := TS_KW
	line := `interface Widget { count: number; }`
	testing.expectf(t, lc_word_kind(line, &kw, "interface") == .Keyword, "TS: 'interface' is a Keyword")
	testing.expectf(t, lc_word_kind(line, &kw, "Widget") == .Type, "TS: identifier after 'interface' is Type")
	testing.expectf(t, lc_word_kind(line, &kw, "number") == .Type, "TS: 'number' is a known Type")
}

@(test)
test_lex_c_kw_table_go :: proc(t: ^testing.T) {
	kw := GO_KW
	line := `type Widget struct { Count int }`
	testing.expectf(t, lc_word_kind(line, &kw, "type") == .Keyword, "Go: 'type' is a Keyword")
	testing.expectf(t, lc_word_kind(line, &kw, "Widget") == .Type, "Go: identifier after 'type' is Type")
	testing.expectf(t, lc_word_kind(line, &kw, "int") == .Type, "Go: 'int' is a known Type")
}

@(test)
test_lex_c_kw_table_rust :: proc(t: ^testing.T) {
	kw := RUST_KW
	line := `struct Widget { count: u32 }`
	testing.expectf(t, lc_word_kind(line, &kw, "struct") == .Keyword, "Rust: 'struct' is a Keyword")
	testing.expectf(t, lc_word_kind(line, &kw, "Widget") == .Type, "Rust: identifier after 'struct' is Type")
	testing.expectf(t, lc_word_kind(line, &kw, "u32") == .Type, "Rust: 'u32' is a known Type")
}

@(test)
test_lex_c_kw_table_odin :: proc(t: ^testing.T) {
	kw := ODIN_KW
	line := `Widget :: struct { count: int }`
	testing.expectf(t, lc_word_kind(line, &kw, "struct") == .Keyword, "Odin: 'struct' is a Keyword")
	testing.expectf(t, lc_word_kind(line, &kw, "Widget") == .None, "Odin: the type name comes BEFORE 'struct' -- type_intro must not guess here")
	testing.expectf(t, lc_word_kind(line, &kw, "int") == .Type, "Odin: 'int' is a known Type")
}
