// Layer: base — the C-family lexer: one grammar shared by eleven extensions
// (.c .h .cpp .hpp .cs .java .js .ts .go .rs .odin), parameterized on a
// per-language Keyword_Set (data, not branching — see the tables at the
// bottom of this file and task-4-report.md for each list's source).
//
// Shares lex_xml's Lex_State TYPE exactly (lex.odin) — a block comment
// (`/* ... */`) is the only construct in any of these eleven grammars that
// genuinely needs to survive past its own line, which is what keeps the
// resync anchor sound (see lex_c_resync_valid's comment below, and
// EXT_LEXERS's warning comment in program/highlight.odin). For nine of the
// eleven languages that is a flat two-value split, same as lex_xml
// (In_Comment means exactly "inside an unterminated `/* ... */`"). Rust and
// Odin (Keyword_Set.nest_comments) genuinely NEST block comments — verified
// empirically for this task, not assumed (`odin check` and `rustc` both
// accept "/* outer /* inner */ still comment */" as one balanced comment and
// reject the residue "still comment */" alone as a syntax error) — so for
// those two, Lex_State's raw byte carries a nesting DEPTH (1..255) instead
// of a flat flag; see lc_find_block_comment_close_depth and Lex_State's own
// comment (lex.odin) for why this still fits the one-byte budget without
// widening the type. That is a deliberate scope cut, not an oversight:
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
//   - JS/TS regex literals (Keyword_Set.regex) are ALSO same-line-only —
//     real JS/TS grammar treats an unescaped literal newline inside one as a
//     syntax error — so lc_scan_regex needs no Lex_State either. Added after
//     a 2026-07 review found a regex containing the literal bytes "/*" (an
//     escaped "\/" immediately followed by a "*" quantifier) was mistaken
//     for a block-comment open by the plain '/'+'*' check: unlike every
//     other imprecision on this page, THAT mistake's blast radius was the
//     rest of the file, not one line or one token, because the resulting
//     phantom comment persists until the next literal "*/" anywhere at all.
//     Distinguishing a regex from division needs the previous significant
//     token — lc_scan_regex's caller tracks a same-line "does the last thing
//     I saw complete an expression" flag for exactly this, gated to JS/TS
//     only (Keyword_Set.regex).
//   - Preprocessor lines (`#include`, `#define`, ...) colour only the
//     directive word itself as Keyword, then fall through to the ordinary
//     scanner for the remainder of the line — so a string or comment after
//     the directive still colours normally. Only C/C++/C# opt in
//     (Keyword_Set.preproc); Odin's `#`-prefixed compiler directives are a
//     different shape entirely (inline, not line-anchored — see ODIN_KW's
//     comment) and are deliberately NOT recognized by this mechanism.
//   - The LINE-comment marker is per-language data
//     (Keyword_Set.line_comment), not the hardcoded "//" this lexer shipped
//     with: "//" for the eleven C-family languages, "--" for SQL, and the
//     empty string for CSS, which has no line-comment form at all. Only
//     "everything from the marker to the line's end is a Comment" is shared;
//     which bytes open one is data, like every other per-language fact here.
//     A block comment is still the only cross-line construct, so this adds
//     no Lex_State — a line comment ends with its line, by definition.
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
	keywords:      []string, // -> Token_Kind.Keyword
	types:         []string, // built-in primitive / well-known type names -> Token_Kind.Type
	type_intro:    []string, // the identifier right after one of these -> Token_Kind.Type (also Keyword itself)
	preproc:       bool, // a line starting (after leading whitespace) with '#' is a preprocessor directive
	digit_sep:     u8, // '_' or '\'' as a numeric-literal digit separator; 0 disables
	raw_string:    Raw_String_Kind,
	backtick:      bool, // Go/JS/TS backtick raw or template strings
	// Odin and Rust nest /* */ (verified empirically: `odin check` and
	// `rustc` both accept "/* outer /* inner */ still comment */" as ONE
	// comment, and reject "still comment */" alone as a syntax error --
	// see lex_c.odin's header). Every other language here follows C's rule
	// (the FIRST "*/" always closes, regardless of any "/*" seen since).
	// Honoured by lc_find_block_comment_close_depth, which tracks depth as
	// the RAW numeric value of Lex_State itself (see that type's comment,
	// lex.odin) rather than widening the enum.
	nest_comments: bool,
	// JS/TS: a leading '/' NOT immediately followed by '/' or '*', and not
	// immediately preceded (this scan) by something value-shaped, may open
	// a same-line /regex/ literal -- see lc_scan_regex and IMPORTANT 6 in
	// task-4-report.md for why this exists (a regex containing the literal
	// bytes "/*" was otherwise misread as a block-comment open that can
	// persist to the end of the FILE, not just the line).
	regex:         bool,
	// This language's line-comment marker: from it to the line's end is one
	// Comment token, and nothing after it on the line is scanned as code.
	// "//" for all eleven C-family languages, "--" for SQL, and EMPTY for
	// CSS, which genuinely has no line-comment form at all (CSS Syntax
	// Module Level 3 defines only `/* */`).
	//
	// EMPTY MEANS "THIS LANGUAGE HAS NO LINE COMMENT" -- never "the empty
	// string matches at every byte." A prefix compare written the obvious
	// way succeeds trivially on a zero-length needle, which would open a
	// comment at offset 0 of every line and colour a whole stylesheet solid;
	// lc_line_comment_at rejects a zero-length marker before comparing
	// anything, and that early return is the only reason "" is safe as the
	// zero value. Note that it IS the zero value: a Keyword_Set that omits
	// this field gets "no line comment," so every table below sets it
	// explicitly and test_lex_c_line_comment_marker_per_table asserts the
	// marker of each real table by name, so a twelfth language that forgets
	// it fails a test instead of silently losing its comments.
	line_comment:  string,
}

// Does this language's line-comment marker begin at line[i]? A zero-length
// marker NEVER matches -- see Keyword_Set.line_comment for why that guard is
// load-bearing rather than defensive.
@(private = "file")
lc_line_comment_at :: #force_inline proc(line: []u8, i: int, mark: string) -> bool {
	if len(mark) == 0 {return false} // the language has no line comment at all (CSS)
	if i + len(mark) > len(line) {return false}
	for k in 0 ..< len(mark) {
		if line[i + k] != mark[k] {return false}
	}
	return true
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

// Max representable nesting depth: Lex_State is one byte (lex.odin's hard
// #assert), and depth is threaded across lines AS that byte's raw value (see
// lc_find_block_comment_close_depth below), so 255 is the hard ceiling, not
// a tunable. Incrementing SATURATES here rather than wrapping — a plain
// `+= 1` on a u8 at 255 wraps to 0, which would masquerade as
// Lex_State.Normal and silently declare a still-very-much-open comment
// closed. 255 levels of genuine nesting is not a realistic file; this only
// guards against that wraparound ever being reachable at all.
LC_MAX_COMMENT_DEPTH :: 255

// Where a block comment closes, honouring nesting when `nest` (see
// Keyword_Set.nest_comments): `depth_in` is the count of currently-open "/*"
// markers on entry (>=1 — the one that got us here always counts), and the
// scan increments on every "/*" it sees (only when `nest`) and decrements on
// every "*/", closing (returning depth 0) the moment depth reaches zero.
// Bounded by len(line), mirroring lx_find_comment_close (lex_xml.odin).
// Returns (-1, depth) if the line ends first — the comment is still open,
// at whatever depth it ended at (this is exactly the byte lex_c threads
// forward as Lex_State; see that type's comment, lex.odin).
//
// When !nest, this degenerates to the ORIGINAL (pre-Task-4-review)
// lc_find_block_comment_close's exact shape: no "/*" is ever counted, so the
// very first "*/" always drives depth_in (always 1 for a non-nesting
// grammar — see lex_c's two call sites below) to 0 and closes, regardless of
// any "/*" seen since — C's rule, unchanged, and exactly what makes
// "/* /* */" close at the first "*/" instead of nesting for those nine
// languages. depth_in is only ever handed in as either the literal 1 (a
// comment just opened this scan) or int(state_in) (a comment carried over
// from a previous line, whose raw byte IS the depth for both nesting and
// non-nesting grammars alike — a non-nesting grammar's state_in is never
// anything but Normal(0) or In_Comment(1) by construction, so int(state_in)
// is always exactly 1 there too).
@(private = "file")
lc_find_block_comment_close_depth :: proc(line: []u8, i: int, depth_in: int, nest: bool) -> (close: int, depth_out: int) {
	depth := depth_in
	j := i
	for j + 2 <= len(line) {
		if nest && line[j] == '/' && line[j + 1] == '*' {
			if depth < LC_MAX_COMMENT_DEPTH {depth += 1} // saturate, never wrap — see LC_MAX_COMMENT_DEPTH
			j += 2
			continue
		}
		if line[j] == '*' && line[j + 1] == '/' {
			depth -= 1
			j += 2
			if depth == 0 {return j, 0}
			continue
		}
		j += 1
	}
	return -1, depth
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

// Length of a same-line JS/TS regex literal starting at line[i] (line[i] ==
// '/'), or 0 if it doesn't plausibly close on this line -- same "leave it
// plain" policy as the backtick/raw-string forms above: a regex is always
// genuinely line-local in real JS/TS grammar (an unescaped literal newline
// inside one is a syntax error there too), so this is pure same-line
// scanning, no Lex_State needed, and failing to find a close just means
// "not a regex after all" rather than "broken code."
//
// Honours a backslash escape (`\/` never closes it) and a `[...]` character
// class (an unescaped '/' inside brackets doesn't close it either -- e.g.
// `/[a/b]/` is one regex matching 'a', '/', or 'b', not two divisions).
// Absorbs trailing flag letters (g, i, m, s, u, y, ...) into the same token,
// same shape as lc_scan_number_suffix.
//
// See IMPORTANT 6 in task-4-report.md for why this exists: without it, a
// regex containing the literal bytes "/*" (e.g. an escaped "\/" immediately
// followed by a "*" quantifier, as in `/^https?:\/\/*/`) was mistaken for a
// block-comment OPEN by the ordinary '/'+'*' check, which then hunts for a
// "*/" that may not exist anywhere else in the file -- unlike every other
// imprecision in this lexer (bounded to one token or one line), that mistake
// mis-colours every line from there to the end of the document. Consuming
// the whole regex as one token here means its interior bytes are never
// independently re-examined by that check at all.
@(private = "file")
lc_scan_regex :: proc(line: []u8, i: int) -> int {
	j := i + 1
	in_class := false
	for j < len(line) {
		b := line[j]
		if b == '\\' && j + 1 < len(line) {
			j += 2
			continue
		}
		if b == '[' {
			in_class = true
			j += 1
			continue
		}
		if b == ']' {
			in_class = false
			j += 1
			continue
		}
		if b == '/' && !in_class {
			k := j + 1
			for k < len(line) && lc_is_ident_char(line[k]) {k += 1} // trailing flags
			return k - i
		}
		j += 1
	}
	return 0 // doesn't close on this line -- not a regex we can confidently claim
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

	if state != .Normal {
		// int(state) IS the depth: for a non-nesting grammar state_in is
		// never anything but .Normal(0)/.In_Comment(1) by construction, so
		// this is exactly 1 there too -- see
		// lc_find_block_comment_close_depth's comment for why reusing the
		// raw byte this way is sound for every language, nesting or not.
		close, depth_out := lc_find_block_comment_close_depth(line, 0, int(state), kw.nest_comments)
		if close < 0 {
			if len(line) > 0 && n < len(out) {
				out[n] = Token{0, len(line), .Comment}
				n += 1
			}
			return n, Lex_State(u8(depth_out))
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

	// true when the last significant thing this scan saw completes an
	// expression (a value, or a ')'/']' closing one) -- i.e. a following '/'
	// more likely means DIVISION than the start of a regex literal. Only
	// consulted when kw.regex; see lc_scan_regex and IMPORTANT 6 in
	// task-4-report.md. Starts false: nothing precedes the first byte of a
	// line, which is itself a position a regex may legitimately start.
	expr_complete := false

	for i < len(line) {
		b := line[i]

		if b == ' ' || b == '\t' || b == '\r' {
			i += 1
			continue
		}

		// The language's own line-comment marker (Keyword_Set.line_comment):
		// "//" for the C family, "--" for SQL, none at all for CSS. Checked
		// BEFORE the "/*" and regex branches, exactly as the hardcoded "//"
		// test it replaces was, so a C-family "//" still wins over both. For
		// a marker that isn't slash-shaped this ordering is what keeps SQL's
		// "--" ahead of the number scan, so "-- 1" is a comment rather than a
		// dash and a Number. `i = len(line)` runs whether or not the token was
		// emitted -- a line comment swallows the rest of the line, so there is
		// no state left to find past it, and stopping the scan here is not the
		// Shape-A "stopped scanning at the buffer cap" mistake (see lex_c's
		// own comment and the capacity tests in lex_c_test.odin).
		if lc_line_comment_at(line, i, kw.line_comment) {
			if n < len(out) {
				out[n] = Token{i, len(line) - i, .Comment}
				n += 1
			}
			i = len(line)
			continue
		}

		if b == '/' && i + 1 < len(line) && line[i + 1] == '*' {
			// A regex literal can NEVER genuinely start with "/*" -- a bare
			// '*' with nothing to repeat is itself a regex syntax error --
			// so this is always a real block-comment open (or, for a
			// non-regex language, always was). lc_scan_regex is only
			// attempted below, for a '/' NOT immediately followed by '*' or
			// '/'.
			close, depth_out := lc_find_block_comment_close_depth(line, i + 2, 1, kw.nest_comments)
			if close < 0 {
				if n < len(out) {
					out[n] = Token{i, len(line) - i, .Comment}
					n += 1
				}
				return n, Lex_State(u8(depth_out)) // NOTE: unconditional -- see header
			}
			if n < len(out) {
				out[n] = Token{i, close - i, .Comment}
				n += 1
			}
			i = close
			pending_type = false
			expr_complete = false
			continue
		}

		if kw.regex && b == '/' && !expr_complete {
			if l := lc_scan_regex(line, i); l > 0 {
				if n < len(out) {
					out[n] = Token{i, l, .String}
					n += 1
				}
				i += l
				pending_type = false
				expr_complete = true // a regex literal IS a value
				continue
			}
			// Doesn't close on this line, or line[i] wasn't really a regex
			// open after all: falls through to ordinary scanning below,
			// same "leave it plain" contract as the backtick/raw-string
			// forms -- see the file header.
		}

		if kw.raw_string != .None && (b == 'r' || (kw.raw_string == .Cpp && b == 'R')) {
			if l := lc_scan_raw_string(line, i, kw.raw_string); l > 0 {
				if n < len(out) {
					out[n] = Token{i, l, .String}
					n += 1
				}
				i += l
				pending_type = false
				expr_complete = true
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
				expr_complete = true
				continue
			}
			// Doesn't close on this line: left plain (see file header).
			i += 1
			expr_complete = false
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
			expr_complete = true
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
				expr_complete = true
				continue
			}
			i += 1 // an unterminated char literal (or a stray quote) -- skip just this byte
			expr_complete = false
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
				expr_complete = true
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
			// A Keyword is usually followed by an operand (return/typeof/
			// case/new/... in the languages that have kw.regex), so treat
			// it like an operator for the regex heuristic; a plain
			// identifier or a known Type name is a value.
			expr_complete = kind != .Keyword
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
			expr_complete = b == ')' || b == ']' // closes a call/subscript -> a value; every other punct (`{}(;,:`) opens an expression
			continue
		}

		pending_type = false
		expr_complete = false // an operator byte this lexer doesn't tokenize (+ - = < ...): an operand should follow
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
// CORRECTNESS NOTE (2026-07 review): an earlier version of this comment
// claimed this proc "can never manufacture an ACCEPT that full context would
// reject." That is FALSE AS STATED, in two ways a later review caught, both
// now closed -- but load-bearing enough to spell out for whoever adds the
// next stateful lexer, rather than just quietly fixing the code and leaving
// the old, false claim standing:
//
//   1. `toks` below is a FIXED [256]Token buffer. lex_c stops EMITTING at
//      capacity but keeps SCANNING (by design -- see lex_c's own comment),
//      so on a line dense enough to exceed 256 tokens (400-800 bytes of
//      real code is enough), a String or Comment token that would have
//      covered `candidate_end` could simply never have been WRITTEN, and
//      the loop below would find nothing to reject on. Fixed by checking
//      `n == len(toks)` (truncation) and rejecting outright: truncation
//      means "this call cannot know," and the safe answer to "can I trust
//      this candidate" is no, same as a cap hit in lex_resync_state itself.
//   2. The CALLER (lex_resync_state, lex_index.odin) used to hand this proc
//      a `line` read via `pt_line_start_cap(..., RENDER_LINE_CAP)` while
//      discarding that call's own `exact` flag. On a line longer than
//      RENDER_LINE_CAP (8 KiB), the returned start is a scan FLOOR, not the
//      line's real start -- so a string or comment opener further back on
//      the true line is invisible to this proc, and on a sufficiently long
//      line the buffer doesn't even reach `candidate_end` at all, which
//      made every call return true unconditionally. Fixed at the caller:
//      it now skips validating a candidate at all when `exact` is false,
//      rather than handing this proc a line it cannot trust.
//
// With both closed, the argument below is accurate again FOR A NON-NESTING
// GRAMMAR (nine of these eleven languages -- see the nest_comments carve-out
// immediately below, which this proc takes BEFORE reaching any of this):
// Lex_State only ever carries ONE fact across a physical line boundary for
// a non-nesting C-family grammar -- whether a block comment is still open
// (see this file's header: strings, char literals, and same-line-only
// raw/backtick forms are all line-local). So re-lexing THIS line alone,
// assuming .Normal at its start, reproduces every String/Comment span a real
// forward lex would need to judge this candidate — with one asymmetry, and
// it is always the SAFE one: if the line actually starts inside a
// carried-over block comment (so the .Normal assumption here is technically
// wrong), the only way that can change the verdict is by mistaking some of
// that comment's prose for a spurious String/Comment span, which can only
// make this proc REJECT a candidate a full-context lex would have accepted
// (safe: the caller just tries an earlier occurrence, or bails to the
// documented cap-hit .Normal fallback). It can never manufacture an ACCEPT
// that full context would reject: for a NON-NESTING grammar, block comments
// don't nest, so the first "*/" after a real "/*" always closes it
// regardless of what came before on the line -- a candidate that genuinely
// closes a real (possibly-prior-context) comment is correctly accepted
// whether or not the Normal-start assumption matches the true state.
//
// A String token can never legitimately end in the byte '/' (it always ends
// in a quote/delimiter), so any candidate strictly touching a String span
// (up to and including its very end) is rejected outright. A Comment token
// CAN legitimately end exactly at the candidate (that is the accept case),
// so only a STRICTLY interior overlap rejects it -- which can only happen
// for a LINE comment (Keyword_Set.line_comment: "//" for the C family, "--"
// for SQL) that continues past the candidate to the true line end (a
// same-line block comment's own close is never interior to itself, by
// construction). A language with no line comment at all (CSS) simply never
// produces that shape, so this arm is unreachable there -- correctly: in CSS
// a "*/" that a stylesheet author wrote after a "//" really IS at a .Normal
// position, because CSS's "//" opens nothing.
//
// NESTING GRAMMARS (Rust, Odin -- Keyword_Set.nest_comments) BREAK THIS
// ARGUMENT, and NOT just in the two ways above: the "first */ always
// closes" invariant the accept-case proof depends on is specifically false
// once "/*" can appear INSIDE an already-open comment and genuinely deepen
// it. Concrete counterexample: true state_in is already In_Comment at depth
// 1 (opened on some earlier line this proc never sees), and THIS line reads
// `/* comment */ real code`. The true forward lex (nest-aware, starting at
// depth 1) sees the "/*" as a NESTED open (depth -> 2), then the "*/" only
// brings it back to depth 1 -- still open, "real code" is still comment
// prose. This proc's wrong .Normal-assumed re-lex instead sees the same
// bytes as a fresh, self-contained "/* comment */" (depth 0 -> 1 -> 0) and
// reports the candidate at that "*/" as a clean close -- a genuine FALSE
// ACCEPT, not merely an over-cautious reject, and there is no way to tell
// the two situations apart from this one line: the true incoming depth is
// exactly the fact this proc does not have. So for a nest_comments language
// the only answer that can never be wrong is "no" -- see the check at the
// top of the function body below.
lex_c_resync_valid :: proc(kw: ^Keyword_Set, line: []u8, candidate_end: int) -> bool {
	if kw.nest_comments {return false} // see "NESTING GRAMMARS" above

	toks: [256]Token
	n, _ := lex_c(line, .Normal, kw, toks[:])
	if n == len(toks) {return false} // truncated: see "CORRECTNESS NOTE" point 1 above
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
	type_intro    = {"struct", "union", "enum"},
	preproc       = true,
	digit_sep     = '_',
	raw_string    = .None,
	backtick      = false,
	nest_comments = false,
	regex         = false,
	line_comment  = "//",
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
	type_intro    = {"class", "struct", "union", "enum", "typename", "using"},
	preproc       = true,
	digit_sep     = '\'',
	raw_string    = .Cpp,
	backtick      = false,
	nest_comments = false,
	regex         = false,
	line_comment  = "//",
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
	type_intro    = {"class", "struct", "interface", "enum", "record"},
	preproc       = true,
	digit_sep     = '_',
	raw_string    = .None,
	backtick      = false,
	nest_comments = false,
	regex         = false,
	line_comment  = "//",
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
	type_intro    = {"class", "interface", "enum", "record", "extends", "implements"},
	preproc       = false,
	digit_sep     = '_',
	raw_string    = .None,
	backtick      = false,
	nest_comments = false,
	regex         = false,
	line_comment  = "//",
}

// --- JavaScript (.js) -------------------------------------------------------
// Source: MDN "Lexical grammar" § Keywords
// (developer.mozilla.org/en-US/docs/Web/JavaScript/Reference/Lexical_grammar)
// -- always-reserved words, strict-mode/module-only reserved words, and the
// future-reserved-words tables on that page. No `types` list: JS has no
// primitive type keywords.
//
// regex = true (2026-07 review, IMPORTANT 6): JS has a /regex/ literal
// syntax lex_c did not recognize at all until this fix -- see lc_scan_regex
// and Keyword_Set.regex's own comment for the mechanism, and
// task-4-report.md for the motivating bug (a regex containing the literal
// bytes "/*" was mistaken for a block-comment open that persists to the end
// of the file, not just the line).
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
	type_intro    = {"class", "extends"},
	preproc       = false,
	digit_sep     = '_',
	raw_string    = .None,
	backtick      = true,
	nest_comments = false,
	regex         = true,
	line_comment  = "//",
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
	type_intro    = {"class", "interface", "type", "enum", "namespace", "module", "extends", "implements"},
	preproc       = false,
	digit_sep     = '_',
	raw_string    = .None,
	backtick      = true,
	nest_comments = false,
	regex         = true,
	line_comment  = "//",
}

// --- Go (.go) --------------------------------------------------------------
// Source: the Go language specification, "Keywords" and "Predeclared
// identifiers" sections (go.dev/ref/spec). Go's 25 reserved keywords are
// exhaustively enumerated by the spec itself: break, case, chan, const,
// continue, default, defer, else, fallthrough, for, func, go, goto, if,
// import, interface, map, package, range, return, select, struct, switch,
// type, var. `type`/`struct`/`interface` are colour-equivalent Keywords via
// type_intro below (see that field's own comment), not missing from this
// list -- they belong there instead because Go's declaration shape puts a
// type NAME right after each of them, which this list alone can't express.
//
// CORRECTION (2026-07 review): this table originally listed 24 entries and
// claimed "all 25, exhaustively enumerated" -- but four of those 24
// (true/false/iota/nil, still present below) are PREDECLARED IDENTIFIERS
// per the spec's own "Predeclared identifiers" section, not keywords, and
// the table was actually missing two real keywords outright: `func` (the
// single most frequent keyword in any Go file -- every function
// declaration starts with it) and `map`. Both are added below. true/false/
// iota/nil are left in `keywords` rather than removed: every other
// language's table in this file also colours its "true/false/null-ish"
// literals as Keyword for the same reason (see CPP_KW, JS_KW, JAVA_KW,
// RUST_KW) -- "colour by shape," not by the spec's own part-of-speech label
// -- so this is a deliberate, consistent choice, not the bug. The bug was
// the two missing entries, and `test_lex_c_kw_table_go` below now asserts
// `func`/`map` directly (a fixture built only from type_intro words, as the
// original test was, cannot catch an omission in the plain keywords list --
// exactly how this slipped through the first time).
//
// `types` is the predeclared-identifier TYPE list from the same page. Go's
// raw string literal is backtick-delimited with no escapes at all -- the
// single most exact fit of any language for lc_scan_backtick.
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
		"func",
		"go",
		"goto",
		"if",
		"import",
		"map",
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
	type_intro    = {"type", "struct", "interface"},
	preproc       = false,
	digit_sep     = '_',
	raw_string    = .None,
	backtick      = true,
	nest_comments = false,
	regex         = false,
	line_comment  = "//",
}

// --- Rust (.rs) ------------------------------------------------------------
// Source: The Rust Reference, "Keywords" (doc.rust-lang.org/reference/
// keywords.html) -- strict keywords and reserved keywords tables, both
// included (a reserved keyword can't be used as an identifier either, so it
// belongs in the same coloured bucket). Primitive type names are from
// general knowledge of `std` (the fetched page didn't enumerate them); this
// list is unusually stable and uncontroversial across Rust's history.
//
// nest_comments = true (2026-07 review, IMPORTANT 2): Rust's block comments
// NEST -- The Rust Reference's "Comments" section states this directly, and
// it was confirmed empirically for this task by actually compiling both
// halves with the rustc available in this environment (1.87.0):
// "/* outer /* inner */ still comment */" compiles clean as a whole
// program, while "still comment */" alone (the residue C's non-nesting rule
// would leave behind) fails with a parse error -- the same shape of check
// already done for Odin below, just with rustc instead of odin check.
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
	type_intro    = {"struct", "enum", "trait", "impl", "type"},
	preproc       = false,
	digit_sep     = '_',
	raw_string    = .Rust,
	backtick      = false,
	nest_comments = true,
	regex         = false,
	line_comment  = "//",
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
// nest_comments = true (2026-07 review, IMPORTANT 2): confirmed empirically
// with the odin toolchain available in this environment, not asserted from
// memory -- `odin check` accepts a file whose entire content is
// "/* outer /* inner */ still comment */" (one balanced, nested comment),
// and separately rejects "still comment */" alone (the residue C's
// non-nesting rule would leave behind) as a syntax error. This codebase's
// OWN source is Odin, so a non-nesting lexer would mis-colour a real file in
// this very tree the first time Wyatt opened one containing a commented-out
// block that itself contains a comment.
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
	type_intro    = {},
	preproc       = false,
	digit_sep     = '_',
	raw_string    = .None,
	backtick      = false,
	nest_comments = true,
	regex         = false,
	line_comment  = "//",
}

// --- CSS (.css) — folded here, not given its own lexer ---------------------
// Task 5's brief: fold .sql and .css into their nearest fit rather than
// building dedicated lexers, and state which and why. CSS is the C-family
// grammar almost exactly: `/* */` block comments (CSS Syntax Module Level 3
// defines NO line-comment form at all — verified against the spec's own
// "Comments" section, not assumed), single/double-quoted strings, numeric
// literals, and `{}();,:` structural punctuation all match this file's
// existing, UNMODIFIED matching logic with zero changes. Unit suffixes
// ("10px", "1.5em") need no CSS-specific handling either:
// lc_scan_number_suffix already absorbs trailing alnum runs onto every
// language's number token, so "10px" is already one Number token today.
//
// CLOSED 2026-07-26 (batch 7 task 4): the "//" gap this table used to
// disclose. lex_c no longer hardcodes "//" — the marker is per-language data
// (Keyword_Set.line_comment), and CSS's is EMPTY, because CSS Syntax Module
// Level 3 defines no line-comment form at all. So `url(https://x/y)` now
// lexes as an ordinary declaration instead of colouring everything after the
// "//" as a Comment to end of line, which was a real, visible cost on an
// extremely common CSS pattern (font/background/@import URLs). `/* */` is
// unaffected and is still handled by the shared block-comment path, carried
// across lines through Lex_State exactly as before — that is CSS's real and
// only comment form.
//
// One consequence worth stating, because it is the opposite trade rather
// than a pure win: the old "//" behaviour incidentally swallowed the rest of
// the line, which shielded any later "/*" on it. A URL containing the
// literal bytes "/*" (`url(https://x/a/*/b)`) will now open a genuine block
// comment that persists until the next "*/" anywhere in the file. That is
// the same shape as the JS regex bug IMPORTANT 6 fixed, but the trade is
// clearly right: `url(https://...)` occurs in most real stylesheets and
// "/*" inside a URL path is close to nonexistent, whereas the old behaviour
// mis-coloured the common case every time.
//
// Keywords: common global/property-value keywords and at-rule names, from
// general knowledge of CSS (MDN's CSS reference) rather than one exhaustive
// spec table — CSS has no small enumerable "reserved word" list the way a
// programming language does; these are the handful that show up
// constantly in real stylesheets. `types` is left empty (no primitive type
// keywords in CSS); `type_intro` likewise (no "identifier after a
// type-introducing keyword" shape exists here at all).
CSS_KW := Keyword_Set {
	keywords = {
		"important",
		"inherit", "initial", "unset", "revert",
		"none", "auto", "normal",
		"block", "inline", "flex", "grid", "contents", "table",
		"absolute", "relative", "fixed", "sticky", "static",
		"solid", "dashed", "dotted", "double", "groove", "ridge",
		"bold", "italic", "underline", "uppercase", "lowercase", "capitalize",
		"center", "left", "right", "top", "bottom", "middle",
		"hidden", "visible", "scroll", "collapse",
		"media", "import", "keyframes", "supports", "charset",
		"page", "namespace", "document", "font-face",
		"nowrap", "wrap", "pointer", "transparent", "currentColor",
	},
	types         = {},
	type_intro    = {},
	preproc       = false,
	digit_sep     = 0,
	raw_string    = .None,
	backtick      = false,
	nest_comments = false,
	regex         = false,
	// EMPTY ON PURPOSE, and the one value in this file that means "absent"
	// rather than "default": CSS has no line comment. See
	// Keyword_Set.line_comment and lc_line_comment_at for why "" can never
	// degenerate into "matches everywhere."
	line_comment  = "",
}

// --- SQL (.sql) — folded here, not given its own lexer ---------------------
// Same "nearest fit, state which and why" instruction as CSS above.
// Keywords, quoted string literals, numeric literals, `/* */` block
// comments (ANSI SQL and every mainstream dialect — T-SQL, MySQL, Postgres,
// SQLite — all support this form identically to C's), and structural
// punctuation all match this grammar's shape well.
//
// CLOSED 2026-07-26 (batch 7 task 4): the "--" gap this table used to
// disclose — the sharper of §6w's two, because SQL comments routinely
// contain ordinary SQL words ("-- SELECT the right index" coloured SELECT as
// a Keyword INSIDE the comment). lex_c's line-comment marker is now
// per-language data (Keyword_Set.line_comment) and SQL's is "--", so the
// whole run from "--" to the line's end is one Comment token and nothing in
// it is lexed as code.
//
// Two things that follow from where the check sits in lex_c's dispatch, both
// tested rather than assumed (lex_c_css_sql_test.odin):
//
//   - It is ahead of the number scan, so "-- 1" is a comment, not a dash
//     followed by a Number. Ordinary arithmetic is untouched, because "--"
//     is matched as a two-byte run: "a - -1" has a space between the two
//     dashes and never matches. "a--1" with no space IS a comment, which is
//     also what every real dialect does.
//   - It is behind the string scan in effect, because a string literal is
//     consumed whole as one token, so a "--" inside 'a--b' is never examined
//     as a potential marker at all.
//
// ONE disclosed imprecision remains from reusing the grammar AS-IS (see
// CSS_KW's comment immediately above):
//
//   1. SQL keywords are case-INSENSITIVE (SELECT/select/Select all valid),
//      but lc_word_in (this grammar's shared matching function) does an
//      exact, case-SENSITIVE compare, same as every other C-family
//      language here (none of which are case-insensitive). Both UPPERCASE
//      and lowercase forms are listed explicitly below, covering the two
//      dominant real styles; a mixed/title-case style ("Select", "From")
//      will not colour. Disclosed rather than silently incomplete.
//
// Keywords/types: common vocabulary shared across the dialects Wyatt is
// likely to actually open (T-SQL, MySQL, Postgres, SQLite), from general
// knowledge of SQL rather than one single spec table — there is no one
// canonical "reserved word list" the way C99 or the Go spec has; every real
// database's own reference diverges slightly at the edges. `type_intro` is
// left empty: "CREATE TABLE name" puts a TABLE name after the keyword
// TABLE, not a TYPE in the sense this batch's Type role means elsewhere —
// guessing here would be the same kind of wrong guess ODIN_KW's own comment
// declines to make for Odin's `Name :: struct`.
SQL_KW := Keyword_Set {
	keywords = {
		"select", "from", "where", "join", "inner", "left", "right", "outer", "on",
		"group", "by", "order", "having", "insert", "into", "values", "update", "set", "delete",
		"create", "table", "alter", "drop", "index", "view", "trigger", "procedure", "function",
		"begin", "end", "if", "else", "while", "declare", "as", "distinct", "limit", "offset",
		"union", "all", "exists", "in", "not", "and", "or", "null", "is", "like", "between",
		"case", "when", "then", "primary", "key", "foreign", "references", "constraint",
		"default", "check", "unique", "cascade", "transaction", "commit", "rollback",
		"grant", "revoke", "with", "asc", "desc", "top", "exec", "execute", "return", "returns",
		"SELECT", "FROM", "WHERE", "JOIN", "INNER", "LEFT", "RIGHT", "OUTER", "ON",
		"GROUP", "BY", "ORDER", "HAVING", "INSERT", "INTO", "VALUES", "UPDATE", "SET", "DELETE",
		"CREATE", "TABLE", "ALTER", "DROP", "INDEX", "VIEW", "TRIGGER", "PROCEDURE", "FUNCTION",
		"BEGIN", "END", "IF", "ELSE", "WHILE", "DECLARE", "AS", "DISTINCT", "LIMIT", "OFFSET",
		"UNION", "ALL", "EXISTS", "IN", "NOT", "AND", "OR", "NULL", "IS", "LIKE", "BETWEEN",
		"CASE", "WHEN", "THEN", "PRIMARY", "KEY", "FOREIGN", "REFERENCES", "CONSTRAINT",
		"DEFAULT", "CHECK", "UNIQUE", "CASCADE", "TRANSACTION", "COMMIT", "ROLLBACK",
		"GRANT", "REVOKE", "WITH", "ASC", "DESC", "TOP", "EXEC", "EXECUTE", "RETURN", "RETURNS",
	},
	types = {
		"int", "integer", "bigint", "smallint", "tinyint", "float", "double", "decimal", "numeric",
		"varchar", "char", "text", "nchar", "nvarchar", "date", "datetime", "timestamp", "time",
		"boolean", "bool", "blob", "binary", "real", "serial", "uuid", "json", "xml",
		"INT", "INTEGER", "BIGINT", "SMALLINT", "TINYINT", "FLOAT", "DOUBLE", "DECIMAL", "NUMERIC",
		"VARCHAR", "CHAR", "TEXT", "NCHAR", "NVARCHAR", "DATE", "DATETIME", "TIMESTAMP", "TIME",
		"BOOLEAN", "BOOL", "BLOB", "BINARY", "REAL", "SERIAL", "UUID", "JSON", "XML",
	},
	type_intro    = {},
	preproc       = false,
	digit_sep     = 0,
	raw_string    = .None,
	backtick      = false,
	nest_comments = false,
	regex         = false,
	line_comment  = "--", // NOT "//" -- see this table's comment above
}
