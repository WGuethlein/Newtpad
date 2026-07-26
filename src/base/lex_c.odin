// Layer: base — the C-family lexer: one grammar shared by eleven extensions
// (.c .h .cpp .hpp .cs .java .js .ts .go .rs .odin), parameterized on a
// per-language Keyword_Set (data, not branching — see the tables at the
// bottom of this file and task-4-report.md for each list's source).
//
// Shares lex_xml's two-state shape exactly: Lex_State stays {Normal,
// In_Comment} (lex.odin) — In_Comment here means "inside an unterminated
// `/* ... */`", the only construct in any of these eleven grammars that
// genuinely needs to survive past its own line. That is a deliberate scope
// cut, not an oversight, and it is what keeps the resync anchor sound (see
// lex_c_resync_valid's comment below, and EXT_LEXERS's warning comment in
// program/highlight.odin):
//
//   - Double-quoted strings and char literals are LINE-LOCAL, same contract
//     as lex_json: an unterminated one colours to the line's end rather than
//     carrying any state forward. Real C-family strings don't legitimately
//     cross a physical line (that needs a line-continuation backslash, which
//     this lexer does not track — an unclosed string is simply a broken
//     line, coloured as far as it plausibly extends).
//   - Raw/backtick string forms (Go/JS/TS backtick, Rust `r"...#"`/
//     `r#"...#"#`, C++ `R"delim(...)delim"`) are supported ONLY when they
//     open AND close on the same physical line — that is pure line-local
//     scanning, no Lex_State needed at all. A form that does NOT close by
//     the line's end is deliberately left PLAIN (no token for the
//     unterminated tail): unlike an unterminated double-quoted string, an
//     unclosed raw/backtick literal is very often genuinely valid code
//     (multi-line raw strings and template literals are exactly what these
//     forms exist for), so colouring it "to the line's end" the way an
//     unterminated ordinary string does would assert an error that isn't
//     there. This is the "leave it plain" case the task brief calls for:
//     supporting the cross-line form soundly would need a new Lex_State
//     value (which language, which delimiter?), and this batch does not
//     spend one on it.
//   - Preprocessor lines (`#include`, `#define`, ...) colour only the
//     directive word itself as Keyword, then fall through to the ordinary
//     scanner for the remainder of the line — so a string or comment after
//     the directive still colours normally. Only C/C++/C# opt in
//     (Keyword_Set.preproc); Odin's `#`-prefixed compiler directives are a
//     different shape entirely (inline, not line-anchored — see ODIN_KW's
//     comment) and are deliberately NOT recognized by this mechanism.
//
// `Syn_Type` is lexical only, per the task brief: a built-in primitive name
// (Keyword_Set.types) colours Type unconditionally, and the identifier
// immediately following a Keyword_Set.type_intro word (struct/class/...)
// colours Type once, on the shape "a name follows a type-introducing
// keyword" — never a symbol table, never resolved across lines or files.
// Where even that shape is ambiguous for a language (Odin: see ODIN_KW's
// comment), type_intro is left empty rather than guessed.
package base

// Which raw-string PREFIX shape (if any) this language recognizes. Both
// forms are scanned same-line only — see the header's "leave it plain" note.
Raw_String_Kind :: enum u8 {
	None,
	Rust, // r"...", r#"...#"#, r##"...(...)"## — hash count must match on both ends
	Cpp, // R"delim(...)delim" — delim is whatever precedes the '(', matched verbatim on close
}

// One language's vocabulary, as data — never branching logic. See the
// per-language tables below for what's in each slice and where it came from.
Keyword_Set :: struct {
	keywords:   []string, // -> Token_Kind.Keyword
	types:      []string, // built-in primitive / well-known type names -> Token_Kind.Type
	type_intro: []string, // the identifier right after one of these -> Token_Kind.Type (also Keyword itself)
	preproc:    bool, // a line starting (after leading whitespace) with '#' is a preprocessor directive
	digit_sep:  u8, // '_' or '\'' as a numeric-literal digit separator; 0 disables
	raw_string: Raw_String_Kind,
	backtick:   bool, // Go/JS/TS backtick raw or template strings
}

@(private = "file")
lc_is_digit :: #force_inline proc(b: u8) -> bool {return b >= '0' && b <= '9'}

@(private = "file")
lc_is_hex :: #force_inline proc(b: u8) -> bool {
	return lc_is_digit(b) || (b >= 'a' && b <= 'f') || (b >= 'A' && b <= 'F')
}

@(private = "file")
lc_is_ident_start :: #force_inline proc(b: u8) -> bool {
	return (b >= 'a' && b <= 'z') || (b >= 'A' && b <= 'Z') || b == '_'
}

@(private = "file")
lc_is_ident_char :: #force_inline proc(b: u8) -> bool {return lc_is_ident_start(b) || lc_is_digit(b)}

@(private = "file")
lc_is_sep :: #force_inline proc(b, sep: u8) -> bool {return sep != 0 && b == sep}

@(private = "file")
lc_is_punct :: #force_inline proc(b: u8) -> bool {
	switch b {
	case '{', '}', '(', ')', '[', ']', ';', ',', ':':
		return true
	}
	return false
}

@(private = "file")
lc_word_in :: proc(word: string, list: []string) -> bool {
	for w in list {
		if w == word {return true}
	}
	return false
}

// Index just past the line's first "*/" at or after `i`, or -1 if none.
// Bounded by len(line), mirroring lx_find_comment_close (lex_xml.odin) —
// same shape, different two-byte marker. Finding the FIRST occurrence (not
// scanning past an inner "/*") is exactly what makes "/* /* */" close at the
// first "*/" instead of nesting: a block comment's scan never looks at
// what's inside it beyond hunting for this marker.
@(private = "file")
lc_find_block_comment_close :: proc(line: []u8, i: int) -> int {
	j := i
	for j + 2 <= len(line) {
		if line[j] == '*' && line[j + 1] == '/' {return j + 2}
		j += 1
	}
	return -1
}

// Length of a quoted run starting at line[i] (line[i] == q), or 0 if the
// closing `q` never appears before the line ends. `\x` (any escape) never
// ends it early. Shared by double-quoted strings and char literals — same
// shape as lex_json's lj_scan_string and lex_log's lg_scan_string.
@(private = "file")
lc_scan_quoted :: proc(line: []u8, i: int, q: u8) -> int {
	j := i + 1
	for j < len(line) {
		if line[j] == '\\' && j + 1 < len(line) {
			j += 2
			continue
		}
		if line[j] == q {return j + 1 - i}
		j += 1
	}
	return 0 // unterminated
}

// Length of a backtick run starting at line[i] (line[i] == '`'), or 0 if it
// doesn't close on this line -- see the file header's "leave it plain" note:
// an unclosed backtick is NOT coloured to the line's end the way an
// unterminated ordinary string is, because it usually means a legitimate
// multi-line construct this lexer doesn't track, not broken code. No escape
// processing at all (correct for Go; an approximation for JS/TS, which do
// allow `\`` inside a template literal -- see lex_c's header/report for the
// trade-off).
@(private = "file")
lc_scan_backtick :: proc(line: []u8, i: int) -> int {
	j := i + 1
	for j < len(line) {
		if line[j] == '`' {return j + 1 - i}
		j += 1
	}
	return 0
}

// Length of a raw-string literal starting at line[i], per `kind`, or 0 if
// line[i] doesn't actually begin one OR it doesn't close on this line (see
// the header's "leave it plain" note -- same policy as the backtick form
// above: a same-line raw string is fully, soundly supported; one that
// crosses a line is simply not matched at all, so the opening bytes fall
// through to ordinary scanning rather than being coloured as if closed).
//
//   - Rust: 'r' (never 'R'), zero or more '#', then '"'; the close is '"'
//     followed by the SAME number of '#'. "r#foo" (a raw IDENTIFIER, using a
//     keyword as a name -- a different, rarer Rust feature) is not a raw
//     STRING at all: no '"' follows the hashes, so this returns 0 and the
//     caller's ordinary scanning takes over (imprecisely -- see the report).
//   - C++: 'R' (never 'r'), then '"', then an arbitrary delimiter (any bytes
//     up to the next '('), then the body, then ')' + the SAME delimiter +
//     '"'. The delimiter is matched verbatim, not assumed empty -- a bare
//     search for the next ')"' would close early on a delimiter containing
//     ')' or on a body that happens to contain ')"'.
@(private = "file")
lc_scan_raw_string :: proc(line: []u8, i: int, kind: Raw_String_Kind) -> int {
	switch kind {
	case .None:
		return 0
	case .Rust:
		if line[i] != 'r' {return 0}
		j := i + 1
		hashes := 0
		for j < len(line) && line[j] == '#' {
			hashes += 1
			j += 1
		}
		if j >= len(line) || line[j] != '"' {return 0}
		j += 1
		for j < len(line) {
			if line[j] == '"' {
				k := j + 1
				m := 0
				for m < hashes && k < len(line) && line[k] == '#' {
					k += 1
					m += 1
				}
				if m == hashes {return k - i}
			}
			j += 1
		}
		return 0
	case .Cpp:
		if line[i] != 'R' {return 0}
		j := i + 1
		if j >= len(line) || line[j] != '"' {return 0}
		j += 1
		delim_start := j
		for j < len(line) && line[j] != '(' {j += 1}
		if j >= len(line) {return 0} // no '(' on this line: not a raw string we can close
		delim := line[delim_start:j]
		j += 1 // past '('
		for j < len(line) {
			if line[j] == ')' && j + 1 + len(delim) < len(line) {
				match := true
				for k in 0 ..< len(delim) {
					if line[j + 1 + k] != delim[k] {
						match = false
						break
					}
				}
				if match && line[j + 1 + len(delim)] == '"' {
					return (j + 1 + len(delim) + 1) - i
				}
			}
			j += 1
		}
		return 0
	}
	return 0
}

// Consume trailing letters/digits directly following a number's numeric
// body (C/C++ 'f'/'L'/'u'/"ULL", Rust "i32"/"u8"/"usize", ...) -- bounded to
// a handful of bytes so it can't run away consuming an unrelated identifier
// that happens to immediately follow a number with no separating space (rare
// and already invalid in every one of these languages).
@(private = "file")
lc_scan_number_suffix :: proc(line: []u8, j: int) -> int {
	k := j
	for k < len(line) && k < j + 5 && ((line[k] >= 'a' && line[k] <= 'z') || (line[k] >= 'A' && line[k] <= 'Z') || lc_is_digit(line[k])) {
		k += 1
	}
	return k
}

// Length of a number-ish token starting at line[i], or 0. Leniently accepts
// every base this batch's eleven languages use, plus digit separators --
// same "colour the plausible shape, don't validate it" philosophy as
// lj_scan_number (lex_json.odin). `sep` is the language's digit-separator
// byte (0 disables): '_' for most of these languages, '\'' for C++ (its
// separator has used a single quote since C++14, distinct from the char-
// literal quote -- see lex_c's main dispatch, which only tries a char
// literal when a run of digits hasn't already consumed the `'`).
//
//   - 0x/0X: hex digits, then an optional ".hexdigits" fraction, then an
//     optional 'p'/'P' exponent (C99/C++17 hex floats -- 'p' specifically,
//     because 'e' is itself a valid hex digit and would be ambiguous).
//   - 0b/0B, 0o/0O: binary / octal digits.
//   - otherwise: a plain decimal run, optional ".fraction", optional
//     'e'/'E' exponent with an optional sign -- a legacy C octal like
//     "0755" is simply a decimal digit run for colouring purposes; nothing
//     downstream cares that it's semantically octal.
@(private = "file")
lc_scan_number :: proc(line: []u8, i: int, sep: u8) -> int {
	if i + 1 < len(line) && line[i] == '0' {
		c := line[i + 1]
		if c == 'x' || c == 'X' {
			k := i + 2
			saw := false
			for k < len(line) && (lc_is_hex(line[k]) || lc_is_sep(line[k], sep)) {
				if line[k] != sep {saw = true}
				k += 1
			}
			if !saw {return 1} // bare "0"; caller's loop resumes at 'x'
			if k < len(line) && line[k] == '.' {
				k2 := k + 1
				fsaw := false
				for k2 < len(line) && (lc_is_hex(line[k2]) || lc_is_sep(line[k2], sep)) {
					if line[k2] != sep {fsaw = true}
					k2 += 1
				}
				if fsaw {k = k2}
			}
			if k < len(line) && (line[k] == 'p' || line[k] == 'P') {
				m := k + 1
				if m < len(line) && (line[m] == '+' || line[m] == '-') {m += 1}
				if m < len(line) && lc_is_digit(line[m]) {
					for m < len(line) && (lc_is_digit(line[m]) || lc_is_sep(line[m], sep)) {m += 1}
					k = m
				}
			}
			return lc_scan_number_suffix(line, k) - i
		}
		if c == 'b' || c == 'B' {
			k := i + 2
			saw := false
			for k < len(line) && ((line[k] == '0' || line[k] == '1') || lc_is_sep(line[k], sep)) {
				if line[k] != sep {saw = true}
				k += 1
			}
			if saw {return lc_scan_number_suffix(line, k) - i}
			return 1
		}
		if c == 'o' || c == 'O' {
			k := i + 2
			saw := false
			for k < len(line) && ((line[k] >= '0' && line[k] <= '7') || lc_is_sep(line[k], sep)) {
				if line[k] != sep {saw = true}
				k += 1
			}
			if saw {return lc_scan_number_suffix(line, k) - i}
			return 1
		}
	}

	j := i
	if lc_is_digit(line[j]) {
		for j < len(line) && (lc_is_digit(line[j]) || lc_is_sep(line[j], sep)) {j += 1}
	} else if line[j] == '.' && j + 1 < len(line) && lc_is_digit(line[j + 1]) {
		j += 1
		for j < len(line) && (lc_is_digit(line[j]) || lc_is_sep(line[j], sep)) {j += 1}
		return lc_scan_number_suffix(line, j) - i // ".5" shape: no second '.' possible
	} else {
		return 0
	}

	if j < len(line) && line[j] == '.' && j + 1 < len(line) && lc_is_digit(line[j + 1]) {
		j += 1
		for j < len(line) && (lc_is_digit(line[j]) || lc_is_sep(line[j], sep)) {j += 1}
	}

	if j < len(line) && (line[j] == 'e' || line[j] == 'E') {
		k := j + 1
		if k < len(line) && (line[k] == '+' || line[k] == '-') {k += 1}
		if k < len(line) && lc_is_digit(line[k]) {
			for k < len(line) && (lc_is_digit(line[k]) || lc_is_sep(line[k], sep)) {k += 1}
			j = k
		}
	}

	return lc_scan_number_suffix(line, j) - i
}

@(private = "file")
lc_scan_ident :: proc(line: []u8, i: int) -> int {
	j := i
	for j < len(line) && lc_is_ident_char(line[j]) {j += 1}
	return j - i
}

// Lex one line of a C-family language, threading Lex_State across calls
// exactly like lex_xml (state_in/state_out mean the same thing: whether an
// unterminated block comment is still open). No allocation; stops at `out`'s
// capacity but keeps SCANNING past it, so state_out is always correct even
// on a line denser than `out` can hold -- see this file's header and the
// capacity test in lex_c_test.odin for why that distinction matters (Task
// 3 shipped exactly this bug once, for lex_xml).
lex_c :: proc(line: []u8, state_in: Lex_State, kw: ^Keyword_Set, out: []Token) -> (n: int, state_out: Lex_State) {
	state := state_in
	i := 0
	n = 0

	if state == .In_Comment {
		close := lc_find_block_comment_close(line, 0)
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

	// Preprocessor directive: only at the true start of the line (past
	// leading whitespace) and only when we didn't just fall out of a carried
	// comment onto real code -- a '#' appearing right after a comment closes
	// mid-line is not a fresh line start. Colours just the directive word;
	// the rest of the line falls through to ordinary scanning below, so
	// `#include "foo.h"` still colours its string.
	if kw.preproc && i == 0 {
		j := i
		for j < len(line) && (line[j] == ' ' || line[j] == '\t') {j += 1}
		if j < len(line) && line[j] == '#' {
			k := j + 1
			for k < len(line) && lc_is_ident_char(line[k]) {k += 1}
			if n < len(out) {
				out[n] = Token{j, k - j, .Keyword}
				n += 1
			}
			i = k
		}
	}

	// true right after a type_intro keyword: the NEXT identifier (only) is
	// coloured Type. Any other token in between (a number, punctuation, an
	// unrelated keyword) breaks the chain.
	pending_type := false

	for i < len(line) {
		b := line[i]

		if b == ' ' || b == '\t' || b == '\r' {
			i += 1
			continue
		}

		if b == '/' && i + 1 < len(line) && line[i + 1] == '/' {
			if n < len(out) {
				out[n] = Token{i, len(line) - i, .Comment}
				n += 1
			}
			i = len(line)
			continue
		}

		if b == '/' && i + 1 < len(line) && line[i + 1] == '*' {
			close := lc_find_block_comment_close(line, i + 2)
			if close < 0 {
				if n < len(out) {
					out[n] = Token{i, len(line) - i, .Comment}
					n += 1
				}
				return n, .In_Comment // NOTE: unconditional -- see header
			}
			if n < len(out) {
				out[n] = Token{i, close - i, .Comment}
				n += 1
			}
			i = close
			pending_type = false
			continue
		}

		if kw.raw_string != .None && (b == 'r' || (kw.raw_string == .Cpp && b == 'R')) {
			if l := lc_scan_raw_string(line, i, kw.raw_string); l > 0 {
				if n < len(out) {
					out[n] = Token{i, l, .String}
					n += 1
				}
				i += l
				pending_type = false
				continue
			}
		}

		if kw.backtick && b == '`' {
			if l := lc_scan_backtick(line, i); l > 0 {
				if n < len(out) {
					out[n] = Token{i, l, .String}
					n += 1
				}
				i += l
				pending_type = false
				continue
			}
			// Doesn't close on this line: left plain (see file header).
			i += 1
			continue
		}

		if b == '"' {
			l := lc_scan_quoted(line, i, '"')
			if l == 0 {l = len(line) - i} // unterminated: colour to EOL, like lex_json
			if n < len(out) {
				out[n] = Token{i, l, .String}
				n += 1
			}
			i += l
			pending_type = false
			continue
		}

		if b == '\'' {
			if l := lc_scan_quoted(line, i, '\''); l > 0 {
				if n < len(out) {
					out[n] = Token{i, l, .String}
					n += 1
				}
				i += l
				pending_type = false
				continue
			}
			i += 1 // an unterminated char literal (or a stray quote) -- skip just this byte
			continue
		}

		if lc_is_digit(b) || (b == '.' && i + 1 < len(line) && lc_is_digit(line[i + 1])) {
			if l := lc_scan_number(line, i, kw.digit_sep); l > 0 {
				if n < len(out) {
					out[n] = Token{i, l, .Number}
					n += 1
				}
				i += l
				pending_type = false
				continue
			}
		}

		if lc_is_ident_start(b) {
			l := lc_scan_ident(line, i)
			word := string(line[i:i + l])
			kind := Token_Kind.None
			next_pending := false
			if lc_word_in(word, kw.type_intro) {
				kind = .Keyword
				next_pending = true
			} else if lc_word_in(word, kw.keywords) {
				kind = .Keyword
			} else if lc_word_in(word, kw.types) {
				kind = .Type
			} else if pending_type {
				kind = .Type
			}
			if kind != .None && n < len(out) {
				out[n] = Token{i, l, kind}
				n += 1
			}
			pending_type = next_pending
			i += l
			continue
		}

		if lc_is_punct(b) {
			if n < len(out) {
				out[n] = Token{i, 1, .Punct}
				n += 1
			}
			i += 1
			pending_type = false
			continue
		}

		pending_type = false
		i += 1
	}
	return n, state
}

// Re-lexes the single physical `line` (the one containing a resync
// candidate) from a fresh .Normal, and reports whether `candidate_end` --
// the offset just past a "*/" occurrence within that line -- is a position
// the real state machine would call unambiguously .Normal.
//
// Why this exists: `*/` alone is NOT a sound resync anchor for a C-family
// grammar, unlike XML's "-->". `char *s = "*/";` and `// look, */` both put
// the literal bytes "*/" at a position that is inside a string or a line
// comment, not a genuine comment close -- see EXT_LEXERS's warning comment
// (program/highlight.odin) and this file's header. Blindly trusting the LAST
// textual occurrence of "*/" in a resync window, the way lex_resync_state
// treats XML's anchor, would land the resync inside a string on perfectly
// ordinary code and mis-colour every row from there to the viewport -- the
// exact failure mode the task brief warns about.
//
// This validator is sound given lex_c's actual state shape: Lex_State only
// ever carries ONE fact across a physical line boundary for this grammar --
// whether a block comment is still open (see this file's header: strings,
// char literals, and same-line-only raw/backtick forms are all line-local).
// So re-lexing THIS line alone, assuming .Normal at its start, reproduces
// every String/Comment span a real forward lex would need to judge this
// candidate — with one asymmetry, and it is always the SAFE one: if the line
// actually starts inside a carried-over block comment (so the .Normal
// assumption here is technically wrong), the only way that can change the
// verdict is by mistaking some of that comment's prose for a spurious
// String/Comment span, which can only make this proc REJECT a candidate a
// full-context lex would have accepted (safe: the caller just tries an
// earlier occurrence, or bails to the documented cap-hit .Normal fallback).
// It can never manufacture an ACCEPT that full context would reject: block
// comments don't nest, so the first "*/" after a real "/*" always closes it
// regardless of what came before on the line -- a candidate that genuinely
// closes a real (possibly-prior-context) comment is correctly accepted
// whether or not the Normal-start assumption matches the true state.
//
// A String token can never legitimately end in the byte '/' (it always ends
// in a quote/delimiter), so any candidate strictly touching a String span
// (up to and including its very end) is rejected outright. A Comment token
// CAN legitimately end exactly at the candidate (that is the accept case),
// so only a STRICTLY interior overlap rejects it -- which can only happen
// for a `//` line comment that continues past the candidate to the true
// line end (a same-line block comment's own close is never interior to
// itself, by construction: lc_find_block_comment_close stops at the first
// "*/" it finds).
lex_c_resync_valid :: proc(kw: ^Keyword_Set, line: []u8, candidate_end: int) -> bool {
	toks: [256]Token
	n, _ := lex_c(line, .Normal, kw, toks[:])
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

// ---------------------------------------------------------------------------
// Per-language keyword sets, as data. Step 3 of the task brief: "report the
// source used for each -- an invented keyword list is worse than none."
// Every list below was checked against a primary or near-primary source
// (a language spec, standard-library reference, or the compiler's own docs)
// during this task; the exact source is on each table. Where a fetch was
// blocked or a page didn't enumerate something exhaustively, that is noted
// rather than silently patched over with a guess -- see task-4-report.md for
// the full account, including the handful of items deliberately DROPPED for
// lack of confidence (see ODIN_KW below).
//
// type_intro lists only include a word when the language actually puts a
// type-shaped name immediately after it; a language where that shape is
// ambiguous (Odin) gets an empty type_intro rather than a guessed one -- see
// ODIN_KW's own comment.

// --- C (.c, .h) --------------------------------------------------------
// Source: Wikipedia "C syntax" § reserved keywords (cppreference's own
// keyword page returned HTTP 403 to the fetch tool; the Wikipedia table is
// itself sourced from the C11/C17/C23 standard and cross-checked against
// general knowledge of the language during this task). stdint.h/stddef.h
// typedefs (size_t, intN_t, ...) are listed as `types` even though they are
// library typedefs, not language keywords -- extremely standard, unlike an
// invented list, and the brief's "colour by shape" already permits "a known
// primitive" to include the fixed-width integer family everyone in C reaches
// for.
C_KW := Keyword_Set {
	keywords = {
		"auto",
		"break",
		"case",
		"const",
		"continue",
		"default",
		"do",
		"else",
		"extern",
		"for",
		"goto",
		"if",
		"inline",
		"register",
		"restrict",
		"return",
		"sizeof",
		"static",
		"switch",
		"typedef",
		"volatile",
		"while",
		"alignas",
		"alignof",
		"static_assert",
		"thread_local",
		"_Alignas",
		"_Alignof",
		"_Atomic",
		"_BitInt",
		"_Complex",
		"_Generic",
		"_Noreturn",
		"_Static_assert",
		"_Thread_local",
		"asm",
		"true",
		"false",
		"nullptr",
		"typeof",
		"typeof_unqual",
	},
	types = {
		"void",
		"char",
		"short",
		"int",
		"long",
		"float",
		"double",
		"signed",
		"unsigned",
		"bool",
		"_Bool",
		"_Decimal32",
		"_Decimal64",
		"_Decimal128",
		"size_t",
		"ssize_t",
		"ptrdiff_t",
		"wchar_t",
		"intptr_t",
		"uintptr_t",
		"int8_t",
		"int16_t",
		"int32_t",
		"int64_t",
		"uint8_t",
		"uint16_t",
		"uint32_t",
		"uint64_t",
	},
	type_intro = {"struct", "union", "enum"},
	preproc    = true,
	digit_sep  = '_',
	raw_string = .None,
	backtick   = false,
}

// --- C++ (.cpp, .hpp) ---------------------------------------------------
// Source: Microsoft Learn "Keywords (C++)" (learn.microsoft.com/en-us/cpp/
// cpp/keywords-cpp), Standard C++ keywords section only -- Microsoft-
// specific double-underscore extensions and C++/CLI-only keywords on that
// same page are deliberately excluded, since they aren't standard C++. Digit
// separator is `'` (single quote), standard since C++14 -- distinct from a
// char literal's quote; lex_c's dispatch only attempts a char literal when a
// digit run hasn't already consumed the `'` (see lc_scan_number). Raw
// strings use the `R"delim(...)delim"` form (lc_scan_raw_string, .Cpp).
CPP_KW := Keyword_Set {
	keywords = {
		"alignas",
		"alignof",
		"and",
		"and_eq",
		"asm",
		"bitand",
		"bitor",
		"break",
		"case",
		"catch",
		"compl",
		"concept",
		"const",
		"const_cast",
		"consteval",
		"constexpr",
		"constinit",
		"continue",
		"co_await",
		"co_return",
		"co_yield",
		"decltype",
		"default",
		"delete",
		"do",
		"dynamic_cast",
		"else",
		"explicit",
		"export",
		"extern",
		"false",
		"final",
		"for",
		"friend",
		"goto",
		"if",
		"inline",
		"mutable",
		"namespace",
		"new",
		"noexcept",
		"not",
		"not_eq",
		"nullptr",
		"operator",
		"or",
		"or_eq",
		"override",
		"private",
		"protected",
		"public",
		"register",
		"reinterpret_cast",
		"requires",
		"return",
		"sizeof",
		"static",
		"static_assert",
		"static_cast",
		"switch",
		"template",
		"this",
		"thread_local",
		"throw",
		"true",
		"try",
		"typedef",
		"typeid",
		"virtual",
		"volatile",
		"while",
		"xor",
		"xor_eq",
	},
	types = {"void", "bool", "char", "char8_t", "char16_t", "char32_t", "wchar_t", "short", "int", "long", "float", "double", "signed", "unsigned", "auto"},
	type_intro = {"class", "struct", "union", "enum", "typename", "using"},
	preproc    = true,
	digit_sep  = '\'',
	raw_string = .Cpp,
	backtick   = false,
}

// --- C# (.cs) -------------------------------------------------------------
// Source: Microsoft Learn "C# Keywords and contextual keywords"
// (learn.microsoft.com/en-us/dotnet/csharp/language-reference/keywords/) --
// the reserved-keyword table plus the full contextual-keyword table on that
// same page. `null` is a genuine C# reserved word (it has its own linked
// page from that same index) even though the page's extracted text didn't
// spell it out in the reserved-keyword table; included on that basis rather
// than omitted.
CS_KW := Keyword_Set {
	keywords = {
		"abstract",
		"as",
		"base",
		"break",
		"case",
		"catch",
		"checked",
		"const",
		"continue",
		"default",
		"delegate",
		"do",
		"else",
		"event",
		"explicit",
		"extern",
		"false",
		"finally",
		"fixed",
		"for",
		"foreach",
		"goto",
		"if",
		"implicit",
		"in",
		"internal",
		"is",
		"lock",
		"namespace",
		"new",
		"null",
		"operator",
		"out",
		"override",
		"params",
		"private",
		"protected",
		"public",
		"readonly",
		"ref",
		"return",
		"sealed",
		"sizeof",
		"stackalloc",
		"static",
		"switch",
		"this",
		"throw",
		"true",
		"try",
		"typeof",
		"unchecked",
		"unsafe",
		"using",
		"virtual",
		"volatile",
		"while",
		// contextual (from the same page's second table)
		"add",
		"alias",
		"allows",
		"and",
		"args",
		"ascending",
		"async",
		"await",
		"by",
		"closed",
		"descending",
		"equals",
		"extension",
		"field",
		"file",
		"from",
		"get",
		"global",
		"group",
		"init",
		"into",
		"join",
		"let",
		"managed",
		"nameof",
		"not",
		"notnull",
		"on",
		"or",
		"orderby",
		"partial",
		"remove",
		"required",
		"safe",
		"scoped",
		"select",
		"set",
		"unmanaged",
		"value",
		"var",
		"when",
		"where",
		"with",
		"yield",
	},
	types = {"bool", "byte", "char", "decimal", "double", "float", "int", "long", "object", "sbyte", "short", "string", "uint", "ulong", "ushort", "void", "dynamic", "nint", "nuint"},
	type_intro = {"class", "struct", "interface", "enum", "record"},
	preproc    = true,
	digit_sep  = '_',
	raw_string = .None,
	backtick   = false,
}

// --- Java (.java) ----------------------------------------------------------
// Source: Oracle Java Language Specification SE17 §3.9 "Keywords"
// (docs.oracle.com/javase/specs/jls/se17/html/jls-3.html#jls-3.9) -- both the
// reserved-word table and the contextual-keyword list on that page.
// "non-sealed" (a genuine JLS contextual keyword) contains a hyphen, which
// lc_scan_ident can never produce as a single identifier run, so it is
// omitted rather than listed uselessly.
JAVA_KW := Keyword_Set {
	keywords = {
		"abstract",
		"assert",
		"break",
		"case",
		"catch",
		"const",
		"continue",
		"default",
		"do",
		"else",
		"final",
		"finally",
		"for",
		"goto",
		"if",
		"import",
		"instanceof",
		"native",
		"new",
		"package",
		"private",
		"protected",
		"public",
		"return",
		"static",
		"strictfp",
		"super",
		"switch",
		"synchronized",
		"this",
		"throw",
		"throws",
		"transient",
		"try",
		"volatile",
		"while",
		"true",
		"false",
		"null",
		"var",
		"yield",
		"sealed",
		"permits",
		"module",
		"requires",
		"exports",
		"opens",
		"uses",
		"provides",
		"transitive",
		"open",
		"to",
		"with",
	},
	types = {"boolean", "byte", "char", "double", "float", "int", "long", "short", "void"},
	type_intro = {"class", "interface", "enum", "record", "extends", "implements"},
	preproc    = false,
	digit_sep  = '_',
	raw_string = .None,
	backtick   = false,
}

// --- JavaScript (.js) -------------------------------------------------------
// Source: MDN "Lexical grammar" § Keywords
// (developer.mozilla.org/en-US/docs/Web/JavaScript/Reference/Lexical_grammar)
// -- always-reserved words, strict-mode/module-only reserved words, and the
// future-reserved-words tables on that page. No `types` list: JS has no
// primitive type keywords.
JS_KW := Keyword_Set {
	keywords = {
		"break",
		"case",
		"catch",
		"const",
		"continue",
		"debugger",
		"default",
		"delete",
		"do",
		"else",
		"export",
		"false",
		"finally",
		"for",
		"function",
		"if",
		"import",
		"in",
		"instanceof",
		"new",
		"null",
		"return",
		"super",
		"switch",
		"this",
		"throw",
		"true",
		"try",
		"typeof",
		"var",
		"void",
		"while",
		"with",
		"let",
		"static",
		"yield",
		"await",
		"enum",
		"implements",
		"interface",
		"package",
		"private",
		"protected",
		"public",
		"async",
		"get",
		"set",
		"of",
		"as",
		"from",
	},
	type_intro = {"class", "extends"},
	preproc    = false,
	digit_sep  = '_',
	raw_string = .None,
	backtick   = true,
}

// --- TypeScript (.ts) --------------------------------------------------
// Source: composited from the TypeScript Handbook's own vocabulary (type
// annotations, `keyof`/`infer`/`satisfies`/`readonly`, module/namespace
// syntax) layered on top of JS_KW's reserved words above -- the handbook
// does not publish one single exhaustive keyword table the way the JLS or
// the Go spec do, so this list has lower single-source confidence than the
// others; flagged here and in task-4-report.md rather than presented as
// equally authoritative.
TS_KW := Keyword_Set {
	keywords = {
		"break",
		"case",
		"catch",
		"const",
		"continue",
		"debugger",
		"default",
		"delete",
		"do",
		"else",
		"export",
		"false",
		"finally",
		"for",
		"function",
		"if",
		"import",
		"in",
		"instanceof",
		"new",
		"null",
		"return",
		"super",
		"switch",
		"this",
		"throw",
		"true",
		"try",
		"typeof",
		"var",
		"void",
		"while",
		"with",
		"let",
		"static",
		"yield",
		"await",
		"async",
		"get",
		"set",
		"of",
		"as",
		"from",
		"declare",
		"abstract",
		"is",
		"keyof",
		"infer",
		"readonly",
		"satisfies",
		"asserts",
		"out",
		"override",
		"unique",
		"global",
		"private",
		"protected",
		"public",
	},
	types = {"string", "number", "boolean", "any", "unknown", "never", "object", "symbol", "bigint", "undefined"},
	type_intro = {"class", "interface", "type", "enum", "namespace", "module", "extends", "implements"},
	preproc    = false,
	digit_sep  = '_',
	raw_string = .None,
	backtick   = true,
}

// --- Go (.go) --------------------------------------------------------------
// Source: the Go language specification, "Keywords" and "Predeclared
// identifiers" sections (go.dev/ref/spec). Go's 25 reserved keywords are
// exhaustively enumerated by the spec itself (unlike most of the other
// languages here); `types` is the predeclared-identifier type list from the
// same page. Go's raw string literal is backtick-delimited with no escapes
// at all -- the single most exact fit of any language for lc_scan_backtick.
GO_KW := Keyword_Set {
	keywords = {
		"break",
		"case",
		"chan",
		"const",
		"continue",
		"default",
		"defer",
		"else",
		"fallthrough",
		"for",
		"go",
		"goto",
		"if",
		"import",
		"package",
		"range",
		"return",
		"select",
		"switch",
		"var",
		"true",
		"false",
		"iota",
		"nil",
	},
	types = {"any", "bool", "byte", "comparable", "complex64", "complex128", "error", "float32", "float64", "int", "int8", "int16", "int32", "int64", "rune", "string", "uint", "uint8", "uint16", "uint32", "uint64", "uintptr"},
	type_intro = {"type", "struct", "interface"},
	preproc    = false,
	digit_sep  = '_',
	raw_string = .None,
	backtick   = true,
}

// --- Rust (.rs) ------------------------------------------------------------
// Source: The Rust Reference, "Keywords" (doc.rust-lang.org/reference/
// keywords.html) -- strict keywords and reserved keywords tables, both
// included (a reserved keyword can't be used as an identifier either, so it
// belongs in the same coloured bucket). Primitive type names are from
// general knowledge of `std` (the fetched page didn't enumerate them); this
// list is unusually stable and uncontroversial across Rust's history.
RUST_KW := Keyword_Set {
	keywords = {
		"_",
		"as",
		"async",
		"await",
		"break",
		"const",
		"continue",
		"crate",
		"dyn",
		"else",
		"extern",
		"false",
		"fn",
		"for",
		"if",
		"in",
		"let",
		"loop",
		"match",
		"mod",
		"move",
		"mut",
		"pub",
		"ref",
		"return",
		"self",
		"Self",
		"static",
		"super",
		"true",
		"unsafe",
		"use",
		"where",
		"while",
		"abstract",
		"become",
		"box",
		"do",
		"final",
		"gen",
		"macro",
		"override",
		"priv",
		"try",
		"typeof",
		"unsized",
		"virtual",
		"yield",
		"union",
		"macro_rules",
	},
	types = {"i8", "i16", "i32", "i64", "i128", "isize", "u8", "u16", "u32", "u64", "u128", "usize", "f32", "f64", "bool", "char", "str"},
	type_intro = {"struct", "enum", "trait", "impl", "type"},
	preproc    = false,
	digit_sep  = '_',
	raw_string = .Rust,
	backtick   = false,
}

// --- Odin (.odin) -----------------------------------------------------------
// Source: odin-lang.org/docs/overview, cross-checked directly against this
// very codebase (the strongest available source: Newtpad IS an Odin
// project, and every word below has been observed in src/ during this task).
// A handful of candidates the fetched page suggested were DROPPED for lack
// of confidence rather than included on a single uncertain source: "and",
// "or", "not" (Odin uses `&&`/`||`/`!`, not word-operators -- not observed
// anywhere in this tree) and a bare "private" keyword (Odin spells this as
// the `@(private)` attribute, not a keyword).
//
// type_intro is deliberately EMPTY: Odin's type-declaration shape is
// `Name :: struct { ... }` -- the identifier comes BEFORE `struct`, not
// after it, the opposite of every other language in this batch. The
// "identifier after struct/class" heuristic this file uses everywhere else
// would, for Odin, colour the first FIELD name inside the braces as if it
// were a type -- wrong, not just imprecise. Per the task brief's Step 4,
// this is exactly the "genuinely ambiguous -- emit None rather than guess"
// case: struct/union/enum/bit_set/bit_field/distinct still colour as plain
// Keywords, just never trigger a next-identifier Type guess.
//
// Odin's own `#`-prefixed directives (`#force_inline`, `#assert`, ...) are
// inline, not line-anchored, so Keyword_Set.preproc (which models a C-style
// "whole line starts with '#'" directive) does not apply to them and is left
// false; they are simply not recognized by this lexer.
ODIN_KW := Keyword_Set {
	keywords = {
		"package",
		"import",
		"foreign",
		"using",
		"when",
		"if",
		"else",
		"for",
		"switch",
		"case",
		"break",
		"continue",
		"fallthrough",
		"defer",
		"return",
		"in",
		"not_in",
		"do",
		"where",
		"asm",
		"matrix",
		"proc",
		"struct",
		"union",
		"enum",
		"bit_set",
		"bit_field",
		"distinct",
		"map",
		"dynamic",
		"true",
		"false",
		"nil",
		"cast",
		"transmute",
		"or_else",
		"or_return",
		"or_continue",
		"or_break",
		"context",
	},
	types = {
		"int",
		"i8",
		"i16",
		"i32",
		"i64",
		"i128",
		"uint",
		"u8",
		"u16",
		"u32",
		"u64",
		"u128",
		"uintptr",
		"f16",
		"f32",
		"f64",
		"bool",
		"b8",
		"b16",
		"b32",
		"b64",
		"string",
		"cstring",
		"rune",
		"rawptr",
		"byte",
		"complex32",
		"complex64",
		"complex128",
		"quaternion64",
		"quaternion128",
		"quaternion256",
		"any",
		"typeid",
	},
	type_intro = {},
	preproc    = false,
	digit_sep  = '_',
	raw_string = .None,
	backtick   = false,
}
