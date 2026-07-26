package base

import "core:strings"
import "core:testing"

// Written before lex_shell's real implementation, same discipline as every
// lexer in this batch. See lex_shell.odin's header for why one parameterized
// grammar (mirroring lex_c's Keyword_Set shape) serves .sh/.bat/.ps1, and
// which of the three actually carries Lex_State.

@(private = "file")
shtok_eq :: proc(t: ^testing.T, got: Token, want_start, want_len: int, want_kind: Token_Kind, label: string) {
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

// --- bash (.sh) --------------------------------------------------------

// "if" is the representative keyword this table must colour -- lesson from
// task 4's missing "func": assert a real value from the table, not just
// structure.
@(test)
test_lex_shell_bash_keyword :: proc(t: ^testing.T) {
	line := `if [ -f x ]; then`
	bytes := transmute([]u8)line
	out: [8]Token
	n, _ := lex_shell(bytes, .Normal, &BASH_SH, out[:])
	testing.expectf(t, n >= 1, "want at least 1 token, got %d", n)
	if n < 1 {return}
	shtok_eq(t, out[0], 0, 2, .Keyword, "if")
}

@(test)
test_lex_shell_bash_variable_forms :: proc(t: ^testing.T) {
	line := `echo $HOME ${USER}`
	bytes := transmute([]u8)line
	out: [8]Token
	n, _ := lex_shell(bytes, .Normal, &BASH_SH, out[:])
	testing.expectf(t, n == 2, "want 2 tokens (both variables; 'echo' is not in the keyword table), got %d", n)
	if n != 2 {return}
	shtok_eq(t, out[0], strings.index(line, "$HOME"), len("$HOME"), .Type, "$HOME")
	shtok_eq(t, out[1], strings.index(line, "${USER}"), len("${USER}"), .Type, "${USER}")
}

// Double-quoted strings honour backslash escapes; single-quoted strings do
// NOT (real bash: nothing, not even a backslash, ends a single-quoted
// string early except the next literal quote).
@(test)
test_lex_shell_bash_quotes :: proc(t: ^testing.T) {
	line := `echo "a\"b" 'c\'`
	bytes := transmute([]u8)line
	out: [8]Token
	n, _ := lex_shell(bytes, .Normal, &BASH_SH, out[:])
	testing.expectf(t, n == 2, "want 2 tokens, got %d", n)
	if n != 2 {return}
	shtok_eq(t, out[0], strings.index(line, `"a\"b"`), len(`"a\"b"`), .String, `double-quoted, backslash escape honoured`)
	// The single-quoted field ends at the very first "'" after the opener --
	// bash gives single quotes no escape mechanism at all.
	sq_start := strings.index(line, `'c\'`)
	shtok_eq(t, out[1], sq_start, len(`'c\'`), .String, "single-quoted, no escape")
}

@(test)
test_lex_shell_bash_hash_comment :: proc(t: ^testing.T) {
	line := `x=1 # a comment`
	bytes := transmute([]u8)line
	out: [8]Token
	n, _ := lex_shell(bytes, .Normal, &BASH_SH, out[:])
	testing.expectf(t, n == 2, "want 2 tokens (number + comment), got %d", n)
	if n != 2 {return}
	shtok_eq(t, out[1], strings.index(line, "#"), len("# a comment"), .Comment, "comment runs to EOL")
}

// --- batch (.bat) --------------------------------------------------------

// Batch is fully case-insensitive; "GOTO" (uppercase) must still colour as
// the same keyword as lowercase "goto".
@(test)
test_lex_shell_batch_keyword_case_insensitive :: proc(t: ^testing.T) {
	line := `GOTO end`
	bytes := transmute([]u8)line
	out: [8]Token
	n, _ := lex_shell(bytes, .Normal, &BATCH, out[:])
	testing.expectf(t, n >= 1, "want at least 1 token, got %d", n)
	if n < 1 {return}
	shtok_eq(t, out[0], 0, 4, .Keyword, "GOTO")
}

@(test)
test_lex_shell_batch_rem_comment_any_case :: proc(t: ^testing.T) {
	line := `rem this whole line is a comment`
	bytes := transmute([]u8)line
	out: [8]Token
	n, _ := lex_shell(bytes, .Normal, &BATCH, out[:])
	testing.expectf(t, n == 1, "want 1 token, got %d", n)
	if n != 1 {return}
	shtok_eq(t, out[0], 0, len(line), .Comment, "rem comment (lowercase)")
}

@(test)
test_lex_shell_batch_double_colon_comment :: proc(t: ^testing.T) {
	line := `:: also a comment`
	bytes := transmute([]u8)line
	out: [8]Token
	n, _ := lex_shell(bytes, .Normal, &BATCH, out[:])
	testing.expectf(t, n == 1, "want 1 token, got %d", n)
	if n != 1 {return}
	shtok_eq(t, out[0], 0, len(line), .Comment, "'::' comment")
}

@(test)
test_lex_shell_batch_percent_variables :: proc(t: ^testing.T) {
	line := `echo %PATH% %1 %*`
	bytes := transmute([]u8)line
	out: [8]Token
	n, _ := lex_shell(bytes, .Normal, &BATCH, out[:])
	testing.expectf(t, n == 3, "want 3 tokens, got %d", n)
	if n != 3 {return}
	shtok_eq(t, out[0], strings.index(line, "%PATH%"), len("%PATH%"), .Type, "%PATH%")
	shtok_eq(t, out[1], strings.index(line, "%1"), 2, .Type, "%1 positional")
	shtok_eq(t, out[2], strings.index(line, "%*"), 2, .Type, "%* all-args")
}

// A REM must be followed by a space or the line's end -- "REMOVE" is an
// ordinary word, not a comment.
@(test)
test_lex_shell_batch_rem_prefix_not_comment :: proc(t: ^testing.T) {
	line := `REMOVE file.txt`
	bytes := transmute([]u8)line
	out: [8]Token
	n, _ := lex_shell(bytes, .Normal, &BATCH, out[:])
	testing.expectf(t, n == 0, "want 0 tokens (REMOVE is not REM, not a keyword either), got %d", n)
}

// --- PowerShell (.ps1) -----------------------------------------------------

@(test)
test_lex_shell_ps1_keyword :: proc(t: ^testing.T) {
	line := `foreach ($x in $y) { }`
	bytes := transmute([]u8)line
	out: [16]Token
	n, _ := lex_shell(bytes, .Normal, &POWERSHELL, out[:])
	testing.expectf(t, n >= 1, "want at least 1 token, got %d", n)
	if n < 1 {return}
	shtok_eq(t, out[0], 0, len("foreach"), .Keyword, "foreach")
}

// PowerShell's dash-prefixed comparison operators (-eq, -and, ...) are a
// distinctive real feature -- coloured Keyword as a whole "-xxx" run.
@(test)
test_lex_shell_ps1_dash_operator :: proc(t: ^testing.T) {
	line := `if ($a -eq $b) { }`
	bytes := transmute([]u8)line
	out: [16]Token
	n, _ := lex_shell(bytes, .Normal, &POWERSHELL, out[:])
	found := false
	op_start := strings.index(line, "-eq")
	for i in 0 ..< n {
		if out[i].start == op_start && out[i].len == len("-eq") && out[i].kind == .Keyword {found = true}
	}
	testing.expectf(t, found, "want '-eq' coloured as a Keyword operator among %d tokens", n)
}

@(test)
test_lex_shell_ps1_hash_comment :: proc(t: ^testing.T) {
	line := `$x = 1 # trailing comment`
	bytes := transmute([]u8)line
	out: [8]Token
	n, _ := lex_shell(bytes, .Normal, &POWERSHELL, out[:])
	testing.expectf(t, n >= 1, "want at least 1 token, got %d", n)
	found := false
	for i in 0 ..< n {
		if out[i].kind == .Comment && out[i].start == strings.index(line, "#") {found = true}
	}
	testing.expectf(t, found, "want the trailing '#' comment recognized")
}

// Single-line block comment, opens and closes without touching state.
@(test)
test_lex_shell_ps1_block_comment_single_line :: proc(t: ^testing.T) {
	line := `$x = 1 <# inline note #> $y = 2`
	bytes := transmute([]u8)line
	out: [16]Token
	n, state := lex_shell(bytes, .Normal, &POWERSHELL, out[:])
	testing.expectf(t, state == .Normal, "closed block comment leaves state Normal, got %v", state)
	found := false
	c_start := strings.index(line, "<#")
	c_end := strings.index(line, "#>") + len("#>")
	for i in 0 ..< n {
		if out[i].start == c_start && out[i].len == c_end - c_start && out[i].kind == .Comment {found = true}
	}
	testing.expectf(t, found, "want the whole <# ... #> run coloured Comment")
}

// THE multi-line case: a block comment opened on one line, continuing
// through a middle line untouched, and closed on a third.
@(test)
test_lex_shell_ps1_block_comment_spans_lines :: proc(t: ^testing.T) {
	line1 := "<# start of"
	line2 := "a long comment"
	line3 := "the end #> Write-Host done"

	out: [8]Token

	n1, s1 := lex_shell(transmute([]u8)line1, .Normal, &POWERSHELL, out[:])
	testing.expectf(t, s1 == .In_Comment, "line1: want In_Comment after an unclosed block comment, got %v", s1)
	testing.expectf(t, n1 == 1, "line1: want 1 token, got %d", n1)

	n2, s2 := lex_shell(transmute([]u8)line2, s1, &POWERSHELL, out[:])
	testing.expectf(t, s2 == .In_Comment, "line2: still inside, got %v", s2)
	testing.expectf(t, n2 == 1, "line2: want 1 token (whole line is comment), got %d", n2)

	n3, s3 := lex_shell(transmute([]u8)line3, s2, &POWERSHELL, out[:])
	testing.expectf(t, s3 == .Normal, "line3: comment closes here, got %v", s3)
	testing.expectf(t, n3 >= 1, "line3: want at least 1 token (the comment run), got %d", n3)
}

// THE lesson-1 test: block-comment state must be computed correctly even
// when `out` has zero capacity.
@(test)
test_lex_shell_ps1_block_comment_state_survives_zero_capacity_out :: proc(t: ^testing.T) {
	line := "<# unterminated"
	out: [0]Token
	n, state := lex_shell(transmute([]u8)line, .Normal, &POWERSHELL, out[:])
	testing.expectf(t, n == 0, "want 0 tokens written (capacity 0), got %d", n)
	testing.expectf(t, state == .In_Comment, "want state In_Comment even though no token could be written, got %v", state)
}

// PowerShell single-quoted strings escape an embedded quote by DOUBLING it
// (''), not with a backslash.
@(test)
test_lex_shell_ps1_single_quote_doubled_escape :: proc(t: ^testing.T) {
	line := `'it''s here'`
	bytes := transmute([]u8)line
	out: [8]Token
	n, _ := lex_shell(bytes, .Normal, &POWERSHELL, out[:])
	testing.expectf(t, n == 1, "want 1 token (the doubled '' must not end the string early), got %d", n)
	if n != 1 {return}
	shtok_eq(t, out[0], 0, len(line), .String, "whole doubled-quote string")
}

// Empty input across all three dialects: no tokens, no crash, state
// preserved.
@(test)
test_lex_shell_empty :: proc(t: ^testing.T) {
	out: [8]Token
	n, state := lex_shell(nil, .Normal, &BASH_SH, out[:])
	testing.expectf(t, n == 0, "want 0 tokens on empty line, got %d", n)
	testing.expectf(t, state == .Normal, "empty line preserves state_in, got %v", state)
}

// A line producing more matches than `out` can hold must stop at capacity.
@(test)
test_lex_shell_stops_at_capacity :: proc(t: ^testing.T) {
	line := `$a $b $c $d $e`
	bytes := transmute([]u8)line
	out: [2]Token
	n, state := lex_shell(bytes, .Normal, &BASH_SH, out[:])
	testing.expectf(t, n == 2, "want exactly 2 tokens (out's capacity), got %d", n)
	testing.expectf(t, state == .Normal, "want state Normal (bash never carries state), got %v", state)
}
