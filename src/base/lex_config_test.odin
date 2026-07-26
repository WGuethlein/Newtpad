package base

import "core:strings"
import "core:testing"

// Written before lex_config's real implementation, same discipline as every
// lexer in this batch. See lex_config.odin's header for which of the eight
// extensions this actually covers and why (.yaml/.yml are NOT among them —
// that grammar is lex_yaml.odin's, a deliberately separate lexer).

@(private = "file")
cftok_eq :: proc(t: ^testing.T, got: Token, want_start, want_len: int, want_kind: Token_Kind, label: string) {
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

// The core ini/toml/cfg/conf/env shape: "key = value".
@(test)
test_lex_config_key_value :: proc(t: ^testing.T) {
	line := `max_connections = 10`
	bytes := transmute([]u8)line
	out: [8]Token
	n := lex_config(bytes, out[:])
	testing.expectf(t, n == 3, "want 3 tokens, got %d", n)
	if n != 3 {return}
	cftok_eq(t, out[0], 0, len("max_connections"), .Json_Key, "key")
	eq_pos := strings.index(line, "=")
	cftok_eq(t, out[1], eq_pos, 1, .Punct, "=")
	cftok_eq(t, out[2], strings.index(line, "10"), 2, .Number, "10")
}

// .env bare assignment, no whitespace around '='.
@(test)
test_lex_config_env_bare_assignment :: proc(t: ^testing.T) {
	line := `DATABASE_URL=postgres://localhost/db`
	bytes := transmute([]u8)line
	out: [8]Token
	n := lex_config(bytes, out[:])
	testing.expectf(t, n == 2, "want 2 tokens (key + '='; the URL value has no digits-only shape), got %d", n)
	if n != 2 {return}
	cftok_eq(t, out[0], 0, len("DATABASE_URL"), .Json_Key, "key")
	cftok_eq(t, out[1], strings.index(line, "="), 1, .Punct, "=")
}

// An INI-style section header, whole bracket run coloured Type.
@(test)
test_lex_config_ini_section :: proc(t: ^testing.T) {
	line := `[database]`
	bytes := transmute([]u8)line
	out: [8]Token
	n := lex_config(bytes, out[:])
	testing.expectf(t, n == 1, "want 1 token, got %d", n)
	if n != 1 {return}
	cftok_eq(t, out[0], 0, len(line), .Type, "section header")
}

// TOML array-of-tables: doubled brackets, matched as one run.
@(test)
test_lex_config_toml_array_of_tables :: proc(t: ^testing.T) {
	line := `[[servers]]`
	bytes := transmute([]u8)line
	out: [8]Token
	n := lex_config(bytes, out[:])
	testing.expectf(t, n == 1, "want 1 token, got %d", n)
	if n != 1 {return}
	cftok_eq(t, out[0], 0, len(line), .Type, "array-of-tables header")
}

// A quoted value.
@(test)
test_lex_config_quoted_value :: proc(t: ^testing.T) {
	line := `name = "Newtpad"`
	bytes := transmute([]u8)line
	out: [8]Token
	n := lex_config(bytes, out[:])
	testing.expectf(t, n == 3, "want 3 tokens, got %d", n)
	if n != 3 {return}
	cftok_eq(t, out[2], strings.index(line, `"Newtpad"`), len(`"Newtpad"`), .String, "quoted value")
}

// true/false are the representative keyword this table must colour --
// lesson from task 4's missing "func": assert a real value, not just
// structure.
@(test)
test_lex_config_boolean_keyword :: proc(t: ^testing.T) {
	line := `enabled = true`
	bytes := transmute([]u8)line
	out: [8]Token
	n := lex_config(bytes, out[:])
	testing.expectf(t, n == 3, "want 3 tokens, got %d", n)
	if n != 3 {return}
	cftok_eq(t, out[2], strings.index(line, "true"), len("true"), .Keyword, "true")
}

// A '#' comment consumes the rest of the line -- nothing after it, including
// what would otherwise look like a key, is coloured.
@(test)
test_lex_config_hash_comment :: proc(t: ^testing.T) {
	line := `# a full-line comment`
	bytes := transmute([]u8)line
	out: [8]Token
	n := lex_config(bytes, out[:])
	testing.expectf(t, n == 1, "want 1 token, got %d", n)
	if n != 1 {return}
	cftok_eq(t, out[0], 0, len(line), .Comment, "whole comment line")
}

// Classic INI also allows ';' as a comment marker.
@(test)
test_lex_config_semicolon_comment :: proc(t: ^testing.T) {
	line := `; classic ini comment`
	bytes := transmute([]u8)line
	out: [8]Token
	n := lex_config(bytes, out[:])
	testing.expectf(t, n == 1, "want 1 token, got %d", n)
	if n != 1 {return}
	cftok_eq(t, out[0], 0, len(line), .Comment, "whole comment line")
}

// A '#' inside a quoted value must NOT start a comment -- only a '#'
// genuinely outside any string counts.
@(test)
test_lex_config_hash_inside_quoted_value_not_comment :: proc(t: ^testing.T) {
	line := `tag = "release #42"`
	bytes := transmute([]u8)line
	out: [8]Token
	n := lex_config(bytes, out[:])
	testing.expectf(t, n == 3, "want 3 tokens, got %d", n)
	if n != 3 {return}
	cftok_eq(t, out[2], strings.index(line, `"release #42"`), len(`"release #42"`), .String, "quoted value contains '#' harmlessly")
}

// .gitignore: a '!' negation prefix and glob wildcards are Punct; the
// pattern itself (no '=' or ':' anywhere) produces no key/value tokens at
// all.
@(test)
test_lex_config_gitignore_negation_and_glob :: proc(t: ^testing.T) {
	line := `!*.keep`
	bytes := transmute([]u8)line
	out: [8]Token
	n := lex_config(bytes, out[:])
	testing.expectf(t, n == 2, "want 2 tokens ('!' and '*'), got %d", n)
	if n != 2 {return}
	cftok_eq(t, out[0], 0, 1, .Punct, "negation '!'")
	cftok_eq(t, out[1], 1, 1, .Punct, "glob '*'")
}

// A plain .gitignore pattern with no special characters produces no tokens
// at all -- correctly plain, not a crash.
@(test)
test_lex_config_gitignore_plain_pattern :: proc(t: ^testing.T) {
	line := `build/output`
	bytes := transmute([]u8)line
	out: [8]Token
	n := lex_config(bytes, out[:])
	testing.expectf(t, n == 0, "want 0 tokens, got %d", n)
}

// An unterminated quoted value colours to the line's end rather than
// producing nothing, same "colour, don't validate" contract as lex_json.
@(test)
test_lex_config_unterminated_quote :: proc(t: ^testing.T) {
	line := `name = "no close`
	bytes := transmute([]u8)line
	out: [8]Token
	n := lex_config(bytes, out[:])
	testing.expectf(t, n == 3, "want 3 tokens, got %d", n)
	if n != 3 {return}
	q_start := strings.index(line, `"no close`)
	cftok_eq(t, out[2], q_start, len(line) - q_start, .String, "unterminated value runs to line end")
}

// Empty input: no tokens, no crash.
@(test)
test_lex_config_empty :: proc(t: ^testing.T) {
	out: [8]Token
	n := lex_config(nil, out[:])
	testing.expectf(t, n == 0, "want 0 tokens on empty line, got %d", n)
}

// A line producing more matches than `out` can hold must stop at capacity.
@(test)
test_lex_config_stops_at_capacity :: proc(t: ^testing.T) {
	line := `k = "a" "b" "c" "d" "e"`
	bytes := transmute([]u8)line
	out: [2]Token
	n := lex_config(bytes, out[:])
	testing.expectf(t, n == 2, "want exactly 2 tokens (out's capacity), got %d", n)
	if n != 2 {return}
	cftok_eq(t, out[0], 0, 1, .Json_Key, "k")
	cftok_eq(t, out[1], strings.index(line, "="), 1, .Punct, "=")
}
