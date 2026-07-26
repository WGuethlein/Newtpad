// Layer: base — the shell lexer: .sh (POSIX/bash), .bat (Windows batch),
// .ps1 (PowerShell). One parameterized grammar (Shell_Set), mirroring
// lex_c's Keyword_Set shape — same judgement call the task brief asked for
// with config: these three genuinely share almost nothing beyond "there is
// a comment form, a variable-reference form, a quoted-string form, and some
// reserved words," but that shared SHAPE is real, not a stretch, once each
// dialect's actual markers are data (Shell_Set fields) rather than assumed:
//
//   - Comments: bash/PowerShell use '#' anywhere on the line; batch uses
//     "REM " (case-insensitive, must be followed by whitespace or the
//     line's end — "REMOVE" is not a comment) or "::", BOTH valid only at
//     the line's true start (a command position), never mid-line.
//   - Variables: bash/PowerShell use `$name` / `${name}`; batch uses
//     `%name%` or the positional forms `%1`.."%9"/`%*`.
//   - Quoting: bash gives single-quoted strings NO escape mechanism at all
//     (the next `'` always ends it); PowerShell escapes an embedded quote
//     by DOUBLING it (`''`), like SQL. Double-quoted strings are scanned
//     with backslash-escaping for bash and (an approximation — PowerShell's
//     real escape lead-in is the backtick, `` ` ``, not backslash) for
//     PowerShell too; batch's `"..."` gets no escape processing at all.
//     Disclosed rather than silently wrong: a PowerShell double-quoted
//     string containing a literal `\"` (rare — PS scripts overwhelmingly
//     use backtick-escaping or single quotes for this) would close one
//     character early. Batch barely has a real quoting grammar in the same
//     sense; `"..."` is mostly used for paths containing spaces, and no
//     escape convention exists for it at all.
//   - Only PowerShell's `<# ... #>` block comment is genuinely multi-line —
//     see Lex_State usage below. Bash and batch have no block comment
//     construct; a "$(: <<'EOF' ... EOF" heredoc-as-comment trick some bash
//     scripts use is NOT recognized (see the general heredoc note below).
//   - PowerShell's dash-prefixed comparison/logical operators (`-eq`,
//     `-and`, `-not`, ...) are a distinctive, common real feature, coloured
//     as one Keyword token for the whole "-xxx" run.
//
// Heredocs (`bash <<EOF ... EOF`) are NOT tracked — the terminator is an
// ARBITRARY identifier chosen per heredoc, not a fixed marker, so unlike a
// block comment's nesting DEPTH (which fits Lex_State's raw byte, see
// lex_c.odin/lex_yaml.odin), remembering WHICH string to watch for doesn't
// fit in one byte at all. A heredoc's body is simply re-lexed line by line
// as ordinary top-level shell content — the same bounded, self-correcting
// imprecision lex_config.odin accepts for TOML's multi-line strings: wrong
// only for the lines the heredoc spans, never propagating past it, because
// nothing here carries a "still in a heredoc" fact forward.
//
// Case sensitivity: bash keywords are lowercase-only and genuinely
// case-SENSITIVE (a real POSIX shell). Batch and PowerShell are both fully
// case-INSENSITIVE languages — Shell_Set.case_insensitive selects a
// case-folded comparison for keyword AND REM/"::" matching accordingly.
//
// Only .ps1 is registered stateful in EXT_LEXERS (program/highlight.odin):
// bash and batch's Shell_Set has block_comment=false, so lex_shell for
// those two dialects NEVER produces or consumes anything but .Normal —
// same "never consulted" contract lex_log/lex_json have, just reached by
// parameter rather than by a separate proc.
package base

// One shell dialect's vocabulary and lexical markers, as data — never
// branching logic, same discipline as lex_c's Keyword_Set.
Shell_Set :: struct {
	keywords:           []string,
	case_insensitive:   bool, // batch, PowerShell; bash is case-sensitive
	line_comment_hash:  bool, // '#' anywhere on the line (bash, PowerShell)
	line_comment_batch: bool, // "REM " / "::" at the line's true start only (batch)
	block_comment:      bool, // "<# ... #>" (PowerShell only)
	var_dollar:         bool, // $name / ${name} (bash, PowerShell)
	var_percent:        bool, // %name% / %1../%* (batch)
	sq_doubled_escape:  bool, // '' escapes a quote inside '...' (PowerShell); false: no escape at all (bash)
	dq_backslash_escape: bool, // "..." uses backslash escapes (bash, PowerShell approximation); false: no escape (batch)
	dash_operators:     bool, // "-eq"/"-and"/... colour as one Keyword run (PowerShell)
}

@(private = "file")
sh_is_digit :: #force_inline proc(b: u8) -> bool {return b >= '0' && b <= '9'}

@(private = "file")
sh_is_alpha :: #force_inline proc(b: u8) -> bool {
	return (b >= 'a' && b <= 'z') || (b >= 'A' && b <= 'Z')
}

@(private = "file")
sh_is_ident_char :: #force_inline proc(b: u8) -> bool {
	return sh_is_alpha(b) || sh_is_digit(b) || b == '_'
}

@(private = "file")
sh_is_ws :: #force_inline proc(b: u8) -> bool {return b == ' ' || b == '\t'}

@(private = "file")
sh_lower :: #force_inline proc(b: u8) -> u8 {
	if b >= 'A' && b <= 'Z' {return b + 32}
	return b
}

@(private = "file")
sh_word_eq :: proc(word: string, w: string, ci: bool) -> bool {
	if len(word) != len(w) {return false}
	if !ci {return word == w}
	for k in 0 ..< len(w) {
		if sh_lower(word[k]) != sh_lower(w[k]) {return false}
	}
	return true
}

@(private = "file")
sh_word_in :: proc(word: string, list: []string, ci: bool) -> bool {
	for w in list {
		if sh_word_eq(word, w, ci) {return true}
	}
	return false
}

// Index just past the line's first "#>" at or after `from`, or -1.
@(private = "file")
sh_find_block_close :: proc(line: []u8, from: int) -> int {
	j := from
	for j + 2 <= len(line) {
		if line[j] == '#' && line[j + 1] == '>' {return j + 2}
		j += 1
	}
	return -1
}

// Length of a $name / ${name} / $1 / $? variable reference starting at
// line[i] (line[i] == '$'), or 0. `${...}` left uncoloured to the line's end
// when it never closes on this line -- the "leave it plain" contract every
// other same-line-only construct in this batch uses (see lex_c.odin's
// header), since an unclosed "${" is exactly as likely to be a genuinely
// multi-line construct this lexer doesn't track (rare in practice for a
// variable reference, but the same principle: don't assert brokenness a
// simple lexer can't actually confirm).
@(private = "file")
sh_scan_dollar_var :: proc(line: []u8, i: int) -> int {
	if i + 1 >= len(line) {return 0}
	c := line[i + 1]
	if c == '{' {
		j := i + 2
		for j < len(line) && line[j] != '}' {j += 1}
		if j < len(line) {return j + 1 - i}
		return 0 // unterminated: leave plain
	}
	if sh_is_ident_char(c) {
		j := i + 1
		for j < len(line) && sh_is_ident_char(line[j]) {j += 1}
		return j - i
	}
	switch c {
	case '?', '_', '@', '#', '!', '$', '*', '-':
		return 2
	}
	return 0
}

// Length of a %name% / %1.."%9" / %* batch variable reference starting at
// line[i] (line[i] == '%'), or 0.
@(private = "file")
sh_scan_percent_var :: proc(line: []u8, i: int) -> int {
	if i + 1 >= len(line) {return 0}
	c := line[i + 1]
	if c == '*' || (c >= '0' && c <= '9') {return 2}
	j := i + 1
	for j < len(line) && line[j] != '%' && !sh_is_ws(line[j]) {j += 1}
	if j < len(line) && line[j] == '%' && j > i + 1 {return j + 1 - i}
	return 0
}

@(private = "file")
sh_scan_dquote :: proc(line: []u8, i: int, backslash_escape: bool) -> int {
	j := i + 1
	for j < len(line) {
		if backslash_escape && line[j] == '\\' && j + 1 < len(line) {
			j += 2
			continue
		}
		if line[j] == '"' {return j + 1 - i}
		j += 1
	}
	return 0
}

@(private = "file")
sh_scan_squote :: proc(line: []u8, i: int, doubled_escape: bool) -> int {
	j := i + 1
	for j < len(line) {
		if line[j] == '\'' {
			if doubled_escape && j + 1 < len(line) && line[j + 1] == '\'' {
				j += 2
				continue
			}
			return j + 1 - i
		}
		j += 1
	}
	return 0
}

@(private = "file")
sh_scan_number :: proc(line: []u8, i: int) -> int {
	j := i
	for j < len(line) && sh_is_digit(line[j]) {j += 1}
	if j == i {return 0}
	if j < len(line) && line[j] == '.' && j + 1 < len(line) && sh_is_digit(line[j + 1]) {
		j += 1
		for j < len(line) && sh_is_digit(line[j]) {j += 1}
	}
	return j - i
}

@(private = "file")
PS_OPERATORS :: []string{
	"eq", "ne", "gt", "lt", "ge", "le",
	"and", "or", "not", "xor",
	"like", "notlike", "match", "notmatch",
	"contains", "notcontains", "in", "notin",
	"is", "isnot", "replace", "join", "split",
}

// Lex one line of shell script per `sh`'s dialect. `state_in`/`state_out`
// mean "inside an unterminated PowerShell <# ... #> block comment" — never
// anything else, and never touched at all when `sh.block_comment` is false
// (bash, batch). No allocation, stops EMITTING at `out`'s capacity but keeps
// SCANNING for the block-comment state past it — see the zero-capacity
// tests in lex_shell_test.odin, the same lesson-1 proof every stateful
// lexer in this batch carries.
lex_shell :: proc(line: []u8, state_in: Lex_State, sh: ^Shell_Set, out: []Token) -> (n: int, state_out: Lex_State) {
	state := state_in
	i := 0
	n = 0

	if state == .In_Comment {
		close := sh_find_block_close(line, 0)
		if close < 0 {
			if len(line) > 0 && n < len(out) {
				out[n] = Token{0, len(line), .Comment}
				n += 1
			}
			return n, .In_Comment
		}
		if n < len(out) {
			out[n] = Token{0, close, .Comment}
			n += 1
		}
		i = close
		state = .Normal
	}

	// Batch's REM/"::" comment is only ever valid as the line's very first
	// token (a command position) -- checked once, up front, never mid-line.
	if sh.line_comment_batch && i == 0 {
		lead := 0
		for lead < len(line) && sh_is_ws(line[lead]) {lead += 1}
		is_colon_comment := lead + 1 < len(line) && line[lead] == ':' && line[lead + 1] == ':'
		is_rem := lead + 2 < len(line) &&
			sh_lower(line[lead]) == 'r' &&
			sh_lower(line[lead + 1]) == 'e' &&
			sh_lower(line[lead + 2]) == 'm' &&
			(lead + 3 == len(line) || sh_is_ws(line[lead + 3]))
		if is_colon_comment || is_rem {
			if n < len(out) {
				out[n] = Token{lead, len(line) - lead, .Comment}
				n += 1
			}
			return n, state
		}
	}

	for i < len(line) {
		b := line[i]

		if sh.block_comment && b == '<' && i + 1 < len(line) && line[i + 1] == '#' {
			close := sh_find_block_close(line, i + 2)
			if close < 0 {
				if n < len(out) {
					out[n] = Token{i, len(line) - i, .Comment}
					n += 1
				}
				return n, .In_Comment
			}
			if n < len(out) {
				out[n] = Token{i, close - i, .Comment}
				n += 1
			}
			i = close
			continue
		}

		if sh.line_comment_hash && b == '#' {
			if n < len(out) {
				out[n] = Token{i, len(line) - i, .Comment}
				n += 1
			}
			i = len(line)
			continue
		}

		if sh.var_dollar && b == '$' {
			if l := sh_scan_dollar_var(line, i); l > 0 {
				if n < len(out) {
					out[n] = Token{i, l, .Type}
					n += 1
				}
				i += l
				continue
			}
		}

		if sh.var_percent && b == '%' {
			if l := sh_scan_percent_var(line, i); l > 0 {
				if n < len(out) {
					out[n] = Token{i, l, .Type}
					n += 1
				}
				i += l
				continue
			}
		}

		if b == '"' {
			l := sh_scan_dquote(line, i, sh.dq_backslash_escape)
			if l == 0 {l = len(line) - i}
			if n < len(out) {
				out[n] = Token{i, l, .String}
				n += 1
			}
			i += l
			continue
		}

		if b == '\'' {
			l := sh_scan_squote(line, i, sh.sq_doubled_escape)
			if l == 0 {l = len(line) - i}
			if n < len(out) {
				out[n] = Token{i, l, .String}
				n += 1
			}
			i += l
			continue
		}

		if sh_is_digit(b) {
			if l := sh_scan_number(line, i); l > 0 {
				if n < len(out) {
					out[n] = Token{i, l, .Number}
					n += 1
				}
				i += l
				continue
			}
		}

		if sh.dash_operators && b == '-' && i + 1 < len(line) && sh_is_alpha(line[i + 1]) {
			j := i + 1
			for j < len(line) && sh_is_alpha(line[j]) {j += 1}
			word := string(line[i + 1:j])
			if sh_word_in(word, PS_OPERATORS, true) {
				if n < len(out) {
					out[n] = Token{i, j - i, .Keyword}
					n += 1
				}
				i = j
				continue
			}
		}

		if sh_is_alpha(b) || b == '_' {
			j := i
			for j < len(line) && sh_is_ident_char(line[j]) {j += 1}
			word := string(line[i:j])
			if sh_word_in(word, sh.keywords, sh.case_insensitive) {
				if n < len(out) {
					out[n] = Token{i, j - i, .Keyword}
					n += 1
				}
			}
			i = j
			continue
		}

		switch b {
		case '|', '<', '>', ';', '&', '(', ')', '{', '}', '[', ']':
			if n < len(out) {
				out[n] = Token{i, 1, .Punct}
				n += 1
			}
			i += 1
			continue
		}

		i += 1
	}
	return n, state
}

// The bounded backward resync's validator for PowerShell (registered in
// EXT_LEXERS, program/highlight.odin) -- mirrors base.lex_c_resync_valid
// exactly: re-lex the candidate's own physical line from a fresh .Normal
// and check whether the position right after "#>" sits inside a String or
// a '#' line-comment token, the two constructs whose literal bytes could
// contain "#>" without it being a genuine block-comment close (a
// double-quoted path containing "#>", or a trailing '# ... #>' single-line
// comment). Bash and batch never register a resync_validate at all -- they
// aren't stateful (Shell_Set.block_comment is false for both), so nothing
// ever calls this for them.
lex_shell_resync_valid :: proc(sh: ^Shell_Set, line: []u8, candidate_end: int) -> bool {
	toks: [256]Token
	n, _ := lex_shell(line, .Normal, sh, toks[:])
	if n == len(toks) {return false} // truncated: cannot know, see base.lex_c_resync_valid
	for k in 0 ..< n {
		tk := toks[k]
		if tk.kind == .String {
			if tk.start < candidate_end && candidate_end <= tk.start + tk.len {return false}
		} else if tk.kind == .Comment {
			if tk.start < candidate_end && candidate_end < tk.start + tk.len {return false}
		}
	}
	return true
}

// --- Per-dialect Shell_Set tables, as data. -------------------------------
// Sources: general knowledge of each language's own reserved-word/reserved-
// operator vocabulary, cross-checked mentally against real scripts rather
// than fetched from one canonical spec page -- there isn't a single such
// page for any of the three the way the JLS or the Go spec serve C-family
// (see lex_c.odin's own lower-confidence tables, e.g. TS_KW, for the same
// disclosed shape of sourcing). "echo"/"pause" (batch) and "echo" (bash)
// are deliberately EXCLUDED from `keywords`: they are ordinary builtin
// COMMANDS, not reserved/control-flow words, the same "keyword vs builtin"
// line lex_c.odin already draws for every C-family language.

// --- bash / POSIX sh (.sh) -------------------------------------------------
// Reserved words: POSIX Shell Command Language's own reserved-word list
// (if/then/elif/else/fi/do/done/case/esac/while/until/for/in/function) plus
// bash's own extensions (select, time). declare/local/readonly/typeset/
// export/unset are technically builtin commands, not reserved words, but
// are control-flow/declaration-shaped enough that every real editor colours
// them the same way a keyword is coloured; included on that basis.
BASH_SH := Shell_Set {
	keywords = {
		"if", "then", "elif", "else", "fi",
		"for", "in", "do", "done", "while", "until",
		"case", "esac", "function", "select", "time",
		"return", "break", "continue", "exit",
		"export", "local", "readonly", "declare", "typeset", "unset",
		"trap", "exec", "eval", "set", "source",
	},
	case_insensitive     = false,
	line_comment_hash     = true,
	line_comment_batch    = false,
	block_comment         = false,
	var_dollar            = true,
	var_percent           = false,
	sq_doubled_escape     = false,
	dq_backslash_escape   = true,
	dash_operators        = false,
}

// --- Windows batch (.bat) --------------------------------------------------
// Reserved/control-flow words from cmd.exe's own grammar. Fully
// case-insensitive, like every batch keyword and command.
BATCH := Shell_Set {
	keywords = {
		"if", "else", "for", "in", "do",
		"goto", "call", "exit",
		"setlocal", "endlocal", "shift",
		"exist", "not", "defined", "errorlevel", "cmdextversion",
	},
	case_insensitive     = true,
	line_comment_hash     = false,
	line_comment_batch    = true,
	block_comment         = false,
	var_dollar            = false,
	var_percent           = true,
	sq_doubled_escape     = false,
	dq_backslash_escape   = false,
	dash_operators        = false,
}

// --- PowerShell (.ps1) ------------------------------------------------------
// Reserved words from PowerShell's own language keyword set (the
// control-flow/declaration words `about_Language_Keywords` documents), not
// its enormous, ever-growing cmdlet (Verb-Noun) vocabulary, which is data
// no lexer table could hope to stay current with -- same "colour the
// language, not the standard library" line lex_c.odin draws for every
// C-family language's own builtin functions. Fully case-insensitive, like
// every other PowerShell identifier.
POWERSHELL := Shell_Set {
	keywords = {
		"if", "elseif", "else", "foreach", "for", "while", "do", "until",
		"switch", "function", "filter", "workflow", "param",
		"return", "break", "continue", "exit", "throw", "trap",
		"try", "catch", "finally",
		"begin", "process", "end",
		"class", "enum", "using", "data", "in", "dynamicparam",
	},
	case_insensitive     = true,
	line_comment_hash     = true,
	line_comment_batch    = false,
	block_comment         = true,
	var_dollar            = true,
	var_percent           = false,
	sq_doubled_escape     = true,
	dq_backslash_escape   = true,
	dash_operators        = true,
}
