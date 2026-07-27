package base

import "core:strings"
import "core:testing"

// CSS_KW and SQL_KW (lex_c.odin) are Task 5's additions to the C-family
// grammar, folding .css and .sql into "nearest fit" per the task brief. A
// SEPARATE file rather than appended to lex_c_test.odin: lex_c_test.odin is
// Task 4's approved, reviewed test file, and this batch's scope note is to
// touch existing lexers/tests as little as possible — these two new tables
// get their own smoke tests here instead. See lex_c.odin's own CSS_KW/SQL_KW
// comments for the disclosed imprecisions each fold accepts.

@(private = "file")
csql_word_kind :: proc(line: string, kw: ^Keyword_Set, word: string) -> Token_Kind {
	out: [32]Token
	n, _ := lex_c(transmute([]u8)line, .Normal, kw, out[:])
	start := strings.index(line, word)
	for i in 0 ..< n {
		if out[i].start == start {return out[i].kind}
	}
	return .None
}

@(test)
test_lex_c_css_keywords_and_block_comment :: proc(t: ^testing.T) {
	kw := CSS_KW
	line := `.box { display: none !important; } /* note */`
	testing.expectf(t, csql_word_kind(line, &kw, "none") == .Keyword, "CSS: 'none' is a Keyword")
	testing.expectf(t, csql_word_kind(line, &kw, "important") == .Keyword, "CSS: 'important' is a Keyword")

	out: [8]Token
	n, _ := lex_c(transmute([]u8)line, .Normal, &kw, out[:])
	comment_start := strings.index(line, "/*")
	found_comment := false
	for i in 0 ..< n {
		if out[i].start == comment_start && out[i].kind == .Comment {found_comment = true}
	}
	testing.expectf(t, found_comment, "CSS: '/* note */' is a Comment (block comments match this grammar exactly)")
}

// A unit-suffixed number ("10px") is already one Number token via
// lc_scan_number_suffix's existing trailing-alnum absorption -- no
// CSS-specific code needed at all. Confirms that's really true for CSS,
// since this is a 12th consumer of that mechanism, not one it was written
// for.
@(test)
test_lex_c_css_number_with_unit_suffix :: proc(t: ^testing.T) {
	kw := CSS_KW
	line := `margin: 10px;`
	out: [8]Token
	n, _ := lex_c(transmute([]u8)line, .Normal, &kw, out[:])
	num_start := strings.index(line, "10px")
	found := false
	for i in 0 ..< n {
		if out[i].start == num_start && out[i].len == len("10px") && out[i].kind == .Number {found = true}
	}
	testing.expectf(t, found, "CSS: '10px' lexes as one Number token including its unit suffix")
}

// WAS the disclosed CSS gap (§6w), CLOSED 2026-07-26: "//" inside a url()
// value used to be mistaken for a line comment, because lex_c hardcoded "//"
// for every language. CSS_KW.line_comment is now "" -- CSS has no
// line-comment form -- so this is an ordinary declaration again. The
// assertion is inverted from the version this replaces; if it ever passes in
// its old form again, the marker has been hardcoded back.
@(test)
test_lex_c_css_url_double_slash_is_not_a_comment :: proc(t: ^testing.T) {
	kw := CSS_KW
	line := `a { background: url(https://x/y); display: none }`
	out: [16]Token
	n, state := lex_c(transmute([]u8)line, .Normal, &kw, out[:])
	testing.expectf(t, state == .Normal, "a url() is not a comment and opens no state, got %v", state)
	for i in 0 ..< n {
		testing.expectf(t, out[i].kind != .Comment, "CSS has no line comment: want no Comment token at all, got one at %d len %d", out[i].start, out[i].len)
	}
	// The declaration AFTER the "//" must still lex -- this is the part the
	// old behaviour swallowed, and a "no Comment token" check alone would
	// still pass if the scan simply stopped at the "//" without emitting.
	testing.expectf(t, csql_word_kind(line, &kw, "none") == .Keyword, "CSS: the declaration after the url() still lexes ('none' is a Keyword)")
}

// The OPPOSITE trade the "//" fix makes, pinned rather than left as prose in
// CSS_KW's comment -- same discipline the two "documented gap" tests this
// file used to carry were written with. The old "//" behaviour incidentally
// swallowed the rest of the line and so shielded any later "/*" on it; now a
// URL containing the literal bytes "/*" really does open a block comment
// that persists until the next "*/" anywhere in the file. Judged clearly
// worth it (url() is in most stylesheets, "/*" inside a URL path is close to
// nonexistent), but it IS a behaviour change in the losing direction, so it
// gets a test that will notice if anyone ever closes it.
@(test)
test_lex_c_css_slash_star_inside_url_does_open_a_block_comment :: proc(t: ^testing.T) {
	kw := CSS_KW
	line := `background: url(https://x/a/*/b);`
	out: [16]Token
	_, state := lex_c(transmute([]u8)line, .Normal, &kw, out[:])
	testing.expectf(t, state == .In_Comment, "disclosed consequence: '/*' in a URL path opens a real block comment (see CSS_KW's comment), got %v", state)
}

// CSS's real and only comment form still works, including the case that
// needs Lex_State: an unterminated "/*" carries to the next line, and the
// close on that next line returns to .Normal with real code after it lexed.
// "" as a line-comment marker must not have disturbed the block-comment path
// at all.
@(test)
test_lex_c_css_block_comment_threads_across_lines :: proc(t: ^testing.T) {
	kw := CSS_KW
	line1 := `a { /* note about`
	line2 := `this rule */ display: none }`
	out: [16]Token

	n1, s1 := lex_c(transmute([]u8)line1, .Normal, &kw, out[:])
	testing.expectf(t, s1 == .In_Comment, "CSS: an unterminated /* must carry In_Comment forward, got %v", s1)
	c1 := strings.index(line1, "/*")
	found1 := false
	for i in 0 ..< n1 {
		if out[i].start == c1 && out[i].kind == .Comment && out[i].len == len(line1) - c1 {found1 = true}
	}
	testing.expectf(t, found1, "CSS: the open comment runs to the line's end as one Comment token")

	n2, s2 := lex_c(transmute([]u8)line2, s1, &kw, out[:])
	testing.expectf(t, s2 == .Normal, "CSS: the close returns to Normal, got %v", s2)
	close_end := strings.index(line2, "*/") + 2
	found2 := false
	none_start := strings.index(line2, "none")
	none_kw := false
	for i in 0 ..< n2 {
		if out[i].start == 0 && out[i].kind == .Comment && out[i].len == close_end {found2 = true}
		if out[i].start == none_start && out[i].kind == .Keyword {none_kw = true}
	}
	testing.expectf(t, found2, "CSS: line 2 is comment up to and including the '*/'")
	testing.expectf(t, none_kw, "CSS: real code after the close still lexes")
}

// SHAPE A, the named risk for this change (docs/development-loop.md §4): a
// stateful lexer must keep SCANNING for state past its token-buffer cap even
// once it stops EMITTING. A new line-comment marker is a new way to stop
// early, and for CSS the marker is EMPTY -- the case where an inverted
// zero-length check ("" matches at every byte) would end the scan at offset
// 0 and report .Normal. `out` holds 2 tokens; the eight braces fill it long
// before the "//" and the "/*" that follows it are reached.
@(test)
test_lex_c_css_empty_marker_keeps_scanning_past_out_capacity :: proc(t: ^testing.T) {
	kw := CSS_KW
	line := `{}{}{}{}//x/*`
	out: [2]Token
	n, state := lex_c(transmute([]u8)line, .Normal, &kw, out[:])
	testing.expectf(t, n == 2, "want exactly 2 tokens (out's capacity), got %d", n)
	testing.expectf(t, state == .In_Comment, "CSS: '//' opens nothing, so the later '/*' must still be SEEN past the emit cap, got %v", state)
}

@(test)
test_lex_c_sql_keywords_and_block_comment :: proc(t: ^testing.T) {
	kw := SQL_KW
	line := `SELECT * FROM users WHERE id = 1; /* note */`
	testing.expectf(t, csql_word_kind(line, &kw, "SELECT") == .Keyword, "SQL: 'SELECT' is a Keyword")
	testing.expectf(t, csql_word_kind(line, &kw, "FROM") == .Keyword, "SQL: 'FROM' is a Keyword")
	testing.expectf(t, csql_word_kind(line, &kw, "WHERE") == .Keyword, "SQL: 'WHERE' is a Keyword")

	line2 := `select * from users`
	testing.expectf(t, csql_word_kind(line2, &kw, "select") == .Keyword, "SQL: lowercase 'select' is ALSO a Keyword (both cases listed)")
}

@(test)
test_lex_c_sql_types_and_string :: proc(t: ^testing.T) {
	kw := SQL_KW
	line := `CREATE TABLE t (name VARCHAR(255), note TEXT);`
	testing.expectf(t, csql_word_kind(line, &kw, "VARCHAR") == .Type, "SQL: 'VARCHAR' is a known Type")
	testing.expectf(t, csql_word_kind(line, &kw, "TEXT") == .Type, "SQL: 'TEXT' is a known Type")

	line2 := `WHERE name = 'O''Brien'`
	out: [8]Token
	n, _ := lex_c(transmute([]u8)line2, .Normal, &kw, out[:])
	found_string := false
	for i in 0 ..< n {
		if out[i].kind == .String {found_string = true}
	}
	testing.expectf(t, found_string, "SQL: a quoted string literal is coloured (SQL's own '' escape isn't modelled -- see file header on the unmodified grammar)")
}

// WAS the disclosed SQL gap (§6w), CLOSED 2026-07-26, and the sharper of the
// two: SQL comments routinely contain ordinary SQL words, so "-- SELECT the
// right index" coloured SELECT as a Keyword INSIDE what a human reads as a
// comment. SQL_KW.line_comment is now "--".
//
// The word asserted is SELECT specifically, not "some keyword somewhere":
// §6w's other lesson is that GO_KW shipped without `func` because every
// fixture reached its words indirectly. This is §6w's own stated symptom,
// pinned by name.
@(test)
test_lex_c_sql_dash_dash_is_a_line_comment :: proc(t: ^testing.T) {
	kw := SQL_KW
	line := `-- SELECT the right index`
	out: [16]Token
	n, state := lex_c(transmute([]u8)line, .Normal, &kw, out[:])
	testing.expectf(t, state == .Normal, "a line comment never carries state, got %v", state)
	testing.expectf(t, n == 1, "the whole run from '--' to EOL is ONE Comment token, got %d tokens", n)
	if n >= 1 {
		testing.expectf(
			t,
			out[0].start == 0 && out[0].len == len(line) && out[0].kind == .Comment,
			"want start=0 len=%d kind=Comment, got start=%d len=%d kind=%v",
			len(line),
			out[0].start,
			out[0].len,
			out[0].kind,
		)
	}
	testing.expectf(t, csql_word_kind(line, &kw, "SELECT") == .None, "SQL: 'SELECT' inside a '--' comment must NOT colour as a Keyword")
}

// A "--" inside a string literal must not start a comment: the string is
// consumed whole as one token, so its interior bytes are never examined as a
// marker. Asserted through a keyword AFTER the string -- if the "--" had
// fired, 'AND' would be comment prose instead.
@(test)
test_lex_c_sql_dash_dash_inside_string_is_not_a_comment :: proc(t: ^testing.T) {
	kw := SQL_KW
	line := `WHERE note = 'a -- b' AND x = 1`
	out: [16]Token
	n, state := lex_c(transmute([]u8)line, .Normal, &kw, out[:])
	testing.expectf(t, state == .Normal, "no state should be opened here, got %v", state)
	for i in 0 ..< n {
		testing.expectf(t, out[i].kind != .Comment, "a '--' inside a string literal must not open a comment, got one at %d", out[i].start)
	}
	testing.expectf(t, csql_word_kind(line, &kw, "AND") == .Keyword, "SQL: code after the string still lexes ('AND' is a Keyword)")
}

// The numeric path: "a - -1" is subtraction of a negative literal, not a
// comment. "--" is matched as a two-byte RUN, so the space between the
// dashes means neither position matches. (`a--1`, with no space, IS a
// comment in ANSI SQL, Postgres, SQLite and T-SQL -- though not in MySQL,
// which requires whitespace after the "--". See SQL_KW's comment: the
// majority reading is the chosen default, not a claim of unanimity.)
@(test)
test_lex_c_sql_minus_minus_with_space_is_arithmetic :: proc(t: ^testing.T) {
	kw := SQL_KW
	line := `SELECT a - -1 FROM t`
	out: [16]Token
	n, _ := lex_c(transmute([]u8)line, .Normal, &kw, out[:])
	for i in 0 ..< n {
		testing.expectf(t, out[i].kind != .Comment, "'a - -1' is arithmetic, not a comment, got a Comment at %d", out[i].start)
	}
	testing.expectf(t, csql_word_kind(line, &kw, "FROM") == .Keyword, "SQL: 'FROM' after 'a - -1' must still be a Keyword")
	num_start := strings.index(line, "1 FROM")
	found_num := false
	for i in 0 ..< n {
		if out[i].start == num_start && out[i].kind == .Number {found_num = true}
	}
	testing.expectf(t, found_num, "SQL: the '1' in '- -1' is still a Number")
}

// MARKER PRECEDENCE past the emit cap -- NOT a Shape A test, which is what
// this comment used to claim. Shape A is "the scan stopped when the token
// buffer filled"; a scan that stopped here would report .Normal, and .Normal
// is also the correct answer, so this case cannot go red from a Shape A
// regression. (The CSS case above is the real Shape A one: there the correct
// answer is .In_Comment and a truncated scan says .Normal.) It was absent
// from the sabotage failure list for that reason.
//
// What it does guard is worth keeping: `out` fills on the braces, then "--"
// fires and swallows the rest of the line INCLUDING a "/*", so the line
// comment must WIN over the block-comment open that follows it. Revert SQL's
// marker to the hardcoded "//" and the "--" no longer fires, the "/*" is seen
// as an ordinary block open, and state comes back .In_Comment -- which is the
// failure this case does catch. The n == 2 assertion holds the emit cap
// alongside it.
@(test)
test_lex_c_sql_line_comment_hides_block_open_past_out_capacity :: proc(t: ^testing.T) {
	kw := SQL_KW
	line := `{}{}{}{} -- /*`
	out: [2]Token
	n, state := lex_c(transmute([]u8)line, .Normal, &kw, out[:])
	testing.expectf(t, n == 2, "want exactly 2 tokens (out's capacity), got %d", n)
	testing.expectf(t, state == .Normal, "a '/*' inside a '--' comment must not open block state, got %v", state)
}
