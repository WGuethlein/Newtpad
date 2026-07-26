// Layer: base — the config-file lexer: .ini .toml .cfg .conf .env
// .gitignore. Six of the task's eight config extensions — .yaml/.yml are
// deliberately NOT here; see lex_yaml.odin's header for why that grammar
// gets its own lexer instead of being squeezed into this one.
//
// Whether one lexer honestly serves even these six is worth stating plainly
// rather than assuming: .ini (`[section]`, `key = value`, `;`/`#`
// comments), .toml (`[table]`/`[[array]]`, `key = value`, `#` comments
// only), .cfg/.conf (treated as ini-shaped — the most common real-world
// shape for a generic ".conf" file a notepad user opens; an app with its own
// bespoke .conf grammar, e.g. nginx's block-directive syntax, will colour
// only the parts that happen to look like key/value pairs and comments,
// same "leave the rest plain" trade every other lexer here takes on a
// construct it doesn't recognize), .env (bare `KEY=value`, no sections, `#`
// comments), and .gitignore (glob patterns and `#` comments, no key/value
// at all) all reduce to the SAME small common shape: an optional comment
// line, an optional `[section]`/`[[section]]` header, an optional
// `key`(`=`|`:`)`value` pair, and otherwise plain pattern/text content. That
// shape is genuinely shared, not stretched — unlike trying to also fold
// YAML's indentation-driven, block-scalar-bearing grammar in here, which
// would NOT be honest (see lex_yaml.odin).
//
// Deliberately LINE-LOCAL (no Lex_State) for five of six. TOML permits
// triple-quoted multi-line strings (`"""..."""`, `'''...'''`), which this
// lexer does NOT track across lines — a known, disclosed gap, not an
// oversight. Unlike YAML's block scalar (whose entire reason for existing
// is to hold a many-line document fragment, so getting it wrong reads as a
// broken FILE) a TOML multi-line string is comparatively rare in the
// key/value-heavy files Wyatt actually opens, and the failure mode is
// bounded and self-correcting: a `#` appearing inside the string's body on
// some interior line would be mistaken for a fresh comment on THAT line
// only; the very next line resumes ordinary scanning correctly, because
// nothing here carries state forward. That is a real, stated imprecision —
// not "no gap" — but it does not compound the way an unclosed XML/C comment
// does, which is why this lexer doesn't reach for Lex_State to close it.
//
// A comment ('#' or ';') is recognized only at a line's true start, or
// anywhere it is immediately preceded by whitespace — not after any other
// byte. That specific rule (rather than "'#' anywhere") is deliberate: a
// literal '#' can appear inside legitimate unquoted data (a URL fragment in
// an .env value, `KEY=http://x#y`), and requiring whitespace (or line
// start) before it is the same practical heuristic real dotenv/ini parsers
// use to avoid treating that as a comment. A '#' inside a QUOTED value is
// never treated as a comment at all, regardless of what precedes it — the
// quote scan consumes it as ordinary string content first.
package base

@(private = "file")
cf_is_ws :: #force_inline proc(b: u8) -> bool {return b == ' ' || b == '\t'}

@(private = "file")
cf_is_digit :: #force_inline proc(b: u8) -> bool {return b >= '0' && b <= '9'}

@(private = "file")
cf_is_alpha :: #force_inline proc(b: u8) -> bool {
	return (b >= 'a' && b <= 'z') || (b >= 'A' && b <= 'Z')
}

// A key may contain letters, digits, '_', '-', or '.' (dotted TOML keys like
// "a.b.c", dashed ini/conf keys like "max-connections", plain .env
// SCREAMING_SNAKE_CASE — all three, one character class).
@(private = "file")
cf_is_key_char :: #force_inline proc(b: u8) -> bool {
	return cf_is_alpha(b) || cf_is_digit(b) || b == '_' || b == '-' || b == '.'
}

@(private = "file")
cf_leading_ws :: proc(line: []u8) -> int {
	n := 0
	for n < len(line) && cf_is_ws(line[n]) {n += 1}
	return n
}

@(private = "file")
cf_scan_key :: proc(line: []u8, i: int) -> int {
	j := i
	for j < len(line) && cf_is_key_char(line[j]) {j += 1}
	return j - i
}

// Length of a quoted value starting at line[i] (line[i] is '"' or '\''), or
// 0 if unterminated — caller colours the remainder to the line's end
// instead, same contract as every other lexer's quoted string.
@(private = "file")
cf_scan_quoted :: proc(line: []u8, i: int) -> int {
	q := line[i]
	j := i + 1
	for j < len(line) {
		if line[j] == '\\' && j + 1 < len(line) {
			j += 2
			continue
		}
		if line[j] == q {return j + 1 - i}
		j += 1
	}
	return 0
}

// Lenient number scan (leading '-', digits, optional ".digits", optional
// exponent) — same "colour the plausible shape" leniency as lex_json's
// lj_scan_number, duplicated rather than shared (see this batch's
// established per-file convention: each lexer's tiny scanners are
// self-contained, not cross-imported).
@(private = "file")
cf_scan_number :: proc(line: []u8, i: int) -> int {
	j := i
	if j < len(line) && line[j] == '-' {j += 1}
	saw := false
	for j < len(line) && cf_is_digit(line[j]) {
		j += 1
		saw = true
	}
	if !saw {return 0}
	if j < len(line) && line[j] == '.' && j + 1 < len(line) && cf_is_digit(line[j + 1]) {
		j += 1
		for j < len(line) && cf_is_digit(line[j]) {j += 1}
	}
	if j < len(line) && (line[j] == 'e' || line[j] == 'E') {
		k := j + 1
		if k < len(line) && (line[k] == '+' || line[k] == '-') {k += 1}
		if k < len(line) && cf_is_digit(line[k]) {
			for k < len(line) && cf_is_digit(line[k]) {k += 1}
			j = k
		}
	}
	return j - i
}

@(private = "file")
CONFIG_BOOL_WORDS :: []string{"true", "false"}

@(private = "file")
cf_word_in :: proc(word: string, list: []string) -> bool {
	for w in list {
		if w == word {return true}
	}
	return false
}

// Length of a `[section]` or `[[array-of-tables]]` header starting at
// line[i] (line[i] == '['), or 0 if the matching close never appears on this
// line. Matches 1 or 2 leading '[' and requires that many trailing ']',
// consecutively — approximate (a stray extra ']' inside is not specially
// handled) but sound for every real ini/toml header.
@(private = "file")
cf_scan_section :: proc(line: []u8, i: int) -> int {
	open := 1
	if i + 1 < len(line) && line[i + 1] == '[' {open = 2}
	j := i + open
	for j < len(line) {
		if line[j] == ']' {
			k := j
			cnt := 0
			for k < len(line) && line[k] == ']' && cnt < open {
				k += 1
				cnt += 1
			}
			if cnt == open {return k - i}
			return 0
		}
		j += 1
	}
	return 0
}

// Lex one line of config data. No allocation, line-local (see header), stops
// at `out`'s capacity like every other lexer here.
lex_config :: proc(line: []u8, out: []Token) -> int {
	n := 0
	lead := cf_leading_ws(line)
	i := lead

	// A comment or a section header can only start the line's real content —
	// checked once, up front, exactly like markdown's block-level checks.
	if i < len(line) && (line[i] == '#' || line[i] == ';') {
		if n < len(out) {
			out[n] = Token{i, len(line) - i, .Comment}
			n += 1
		}
		return n
	}
	if i < len(line) && line[i] == '[' {
		if l := cf_scan_section(line, i); l > 0 {
			if n < len(out) {
				out[n] = Token{i, l, .Type}
				n += 1
			}
			i += l
		}
	} else if i < len(line) && cf_is_key_char(line[i]) && !cf_is_digit(line[i]) {
		// A key never starts with a digit here -- distinguishes "key = 1"
		// from a bare numeric-looking pattern line (.gitignore has no
		// key/value shape at all, and a line starting with a digit is never
		// meant as a key in any of these six formats).
		kl := cf_scan_key(line, i)
		j := i + kl
		for j < len(line) && cf_is_ws(line[j]) {j += 1}
		if j < len(line) && (line[j] == '=' || line[j] == ':') {
			if n < len(out) {
				out[n] = Token{i, kl, .Json_Key}
				n += 1
			}
			if n < len(out) {
				out[n] = Token{j, 1, .Punct}
				n += 1
			}
			i = j + 1
		}
		// else: not actually a key (no '='/':' follows) -- leave `i` at the
		// start of this run and let the general scan below handle it as
		// ordinary content (e.g. a .gitignore pattern that happens to start
		// with a letter).
	}

	for i < len(line) && n < len(out) {
		b := line[i]

		if (b == '#' || b == ';') && (i == 0 || cf_is_ws(line[i - 1])) {
			out[n] = Token{i, len(line) - i, .Comment}
			n += 1
			i = len(line)
			continue
		}

		if b == '"' || b == '\'' {
			l := cf_scan_quoted(line, i)
			if l == 0 {l = len(line) - i} // unterminated: colour to EOL
			out[n] = Token{i, l, .String}
			n += 1
			i += l
			continue
		}

		if b == '-' || cf_is_digit(b) {
			if l := cf_scan_number(line, i); l > 0 {
				out[n] = Token{i, l, .Number}
				n += 1
				i += l
				continue
			}
		}

		if cf_is_alpha(b) {
			j := i
			for j < len(line) && (cf_is_alpha(line[j]) || cf_is_digit(line[j])) {j += 1}
			word := string(line[i:j])
			if cf_word_in(word, CONFIG_BOOL_WORDS) {
				out[n] = Token{i, j - i, .Keyword}
				n += 1
			}
			i = j
			continue
		}

		if b == '!' && (i == 0 || cf_is_ws(line[i - 1])) {
			out[n] = Token{i, 1, .Punct}
			n += 1
			i += 1
			continue
		}

		if b == '*' || b == '?' {
			out[n] = Token{i, 1, .Punct}
			n += 1
			i += 1
			continue
		}

		i += 1
	}
	return n
}
