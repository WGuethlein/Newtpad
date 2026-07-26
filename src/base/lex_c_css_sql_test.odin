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

// The disclosed CSS gap, made concrete rather than left as a claim: a
// "//" inside a url() value is mistaken for a line comment, since lex_c
// unconditionally recognizes "//" for every language (see CSS_KW's own
// comment for why this is not fixed here). This test pins down the EXACT,
// documented behaviour rather than merely asserting "it doesn't crash" --
// per CLAUDE.md's testing discipline, a known limitation gets a test that
// proves it stays exactly this bounded, not a vague allowance.
@(test)
test_lex_c_css_url_double_slash_is_a_documented_gap :: proc(t: ^testing.T) {
	kw := CSS_KW
	line := `background: url(https://example.com/x.png);`
	out: [8]Token
	n, _ := lex_c(transmute([]u8)line, .Normal, &kw, out[:])
	slash_pos := strings.index(line, "//")
	found_comment := false
	for i in 0 ..< n {
		if out[i].start == slash_pos && out[i].kind == .Comment {found_comment = true}
	}
	testing.expectf(t, found_comment, "documented gap: '//' inside url() is mis-coloured as a comment to EOL (see CSS_KW's comment)")
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

// The disclosed SQL gap, made concrete: a "--" comment's contents are lexed
// as ordinary SQL, so a keyword-shaped word inside one still colours as a
// Keyword. Same discipline as the CSS gap test above -- pin down the exact
// documented behaviour, not just "doesn't crash".
@(test)
test_lex_c_sql_dash_comment_is_a_documented_gap :: proc(t: ^testing.T) {
	kw := SQL_KW
	line := `-- SELECT the right index`
	out: [8]Token
	n, _ := lex_c(transmute([]u8)line, .Normal, &kw, out[:])
	sel_start := strings.index(line, "SELECT")
	found_keyword := false
	for i in 0 ..< n {
		if out[i].start == sel_start && out[i].kind == .Keyword {found_keyword = true}
	}
	testing.expectf(t, found_keyword, "documented gap: 'SELECT' inside a '--' comment still colours as a Keyword (see SQL_KW's comment)")
}
