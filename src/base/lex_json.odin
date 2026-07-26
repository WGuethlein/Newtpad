// Layer: base — the JSON lexer.
//
// JSON strings cannot span lines, so this stays entirely line-local like
// lex_log — no state carried between calls, and no multi-line index needed
// (that is Task 3's problem for other lexers, not this one).
//
// This lexer colours, it does not validate: an unterminated string colours
// to the line's end rather than producing nothing (unlike lex_log's
// unterminated quote, which is simply "no match" — a bare apostrophe in log
// prose usually isn't a string at all, but in JSON an open quote almost
// certainly *is* one, and an unterminated string is exactly when you are
// staring at broken JSON and most want it coloured). An unbalanced brace is
// just a Punct. A malformed number (`.5`, `1e`, `--3`, `0x10`) is coloured
// as far as it plausibly extends and the lexer moves on — never a crash, a
// hang, or a read past `line`'s end. See lex_json's own comment for exactly
// what each malformed shape produces.
package base

@(private = "file")
lj_is_digit :: #force_inline proc(b: u8) -> bool {return b >= '0' && b <= '9'}

@(private = "file")
lj_is_lower_alpha :: #force_inline proc(b: u8) -> bool {return b >= 'a' && b <= 'z'}

@(private = "file")
lj_is_ident :: #force_inline proc(b: u8) -> bool {
	return (b >= 'a' && b <= 'z') || (b >= 'A' && b <= 'Z') || lj_is_digit(b)
}

// Length of a double-quoted JSON string starting at line[i] (line[i] is
// '"'), or 0 if the closing quote never appears before the line ends — the
// caller colours that whole remainder as String rather than treating it as
// no match at all (see header comment). `\"` (and any other `\x` escape)
// does not end the string, mirroring lex_log's lg_scan_string.
@(private = "file")
lj_scan_string :: proc(line: []u8, i: int) -> int {
	j := i + 1
	for j < len(line) {
		if line[j] == '\\' && j + 1 < len(line) {
			j += 2
			continue
		}
		if line[j] == '"' {return j + 1 - i}
		j += 1
	}
	return 0 // unterminated
}

// Length of a number-ish token starting at line[i], or 0 if line[i] cannot
// plausibly begin one. Handles the valid JSON shapes (optional leading '-',
// integer part, optional ".fraction", optional exponent) but leniently
// rather than validating them:
//   - a leading '.' immediately followed by a digit is accepted as a
//     fraction with no integer part (".5") — invalid JSON, but plausibly a
//     number, which is the whole point (see header comment);
//   - an exponent marker ('e'/'E', optional sign) not followed by a digit
//     is simply not consumed, so "1e" colours "1" and leaves the bare "e"
//     for the main loop to skip, rather than swallowing the line or
//     rejecting the digit that came before it;
//   - a lone '-' not followed by a digit or ".digit" matches nothing (0),
//     so "--3" leaves the first '-' for the main loop to skip and starts
//     the number at the second '-'.
// Every successful branch consumes at least one digit beyond any leading
// '-'/'.' , so a non-zero return always advances the caller — no
// zero-progress success that could stall the main loop.
@(private = "file")
lj_scan_number :: proc(line: []u8, i: int) -> int {
	j := i
	if j < len(line) && line[j] == '-' {j += 1}

	saw_dot := false
	if j < len(line) && lj_is_digit(line[j]) {
		for j < len(line) && lj_is_digit(line[j]) {j += 1}
	} else if j < len(line) && line[j] == '.' && j + 1 < len(line) && lj_is_digit(line[j + 1]) {
		saw_dot = true
		j += 1
		for j < len(line) && lj_is_digit(line[j]) {j += 1}
	} else {
		return 0 // nothing plausible after the optional '-'
	}

	if !saw_dot && j < len(line) && line[j] == '.' && j + 1 < len(line) && lj_is_digit(line[j + 1]) {
		j += 1
		for j < len(line) && lj_is_digit(line[j]) {j += 1}
	}

	if j < len(line) && (line[j] == 'e' || line[j] == 'E') {
		k := j + 1
		if k < len(line) && (line[k] == '+' || line[k] == '-') {k += 1}
		if k < len(line) && lj_is_digit(line[k]) {
			for k < len(line) && lj_is_digit(line[k]) {k += 1}
			j = k
		}
		// else: exponent marker not followed by a digit -- leave it
		// unconsumed, matching the header comment's "1e" example.
	}

	return j - i
}

@(private = "file")
JSON_KEYWORDS :: []string{"true", "false", "null"}

// Whole-word match of a JSON literal keyword at line[i], or 0. Boundary
// checks on both sides so "truest" or "xtrue" don't match "true" and strand
// an orphan suffix/prefix, mirroring lex_log's lg_scan_level.
@(private = "file")
lj_scan_keyword :: proc(line: []u8, i: int) -> int {
	if i > 0 && lj_is_ident(line[i - 1]) {return 0}
	for w in JSON_KEYWORDS {
		wl := len(w)
		if i + wl > len(line) {continue}
		match := true
		for k in 0 ..< wl {
			if line[i + k] != w[k] {
				match = false
				break
			}
		}
		if !match {continue}
		if i + wl < len(line) && lj_is_ident(line[i + wl]) {continue}
		return wl
	}
	return 0
}

// Lex one line of JSON: a double-quoted string, coloured Json_Key if,
// after skipping spaces/tabs, the byte following its closing quote is ':'
// (distinguishing "a key before a colon" from "a string used as a value" is
// the one thing this lexer has over generic string colouring); a number; a
// true/false/null literal as Keyword; and structural {}[],: as Punct. No
// allocation, no state carried between calls — this runs per visible row
// per frame (see program/highlight.odin's highlight_row_spans). Stops at
// `out`'s capacity rather than writing past it, same contract as lex_log.
lex_json :: proc(line: []u8, out: []Token) -> int {
	n := 0
	i := 0
	for i < len(line) && n < len(out) {
		b := line[i]

		if b == '"' {
			l := lj_scan_string(line, i)
			if l == 0 {
				// Unterminated: colour to the line's end rather than
				// emitting nothing -- see header comment.
				l = len(line) - i
				out[n] = Token{i, l, .String}
				n += 1
				i = len(line)
				continue
			}
			kind := Token_Kind.String
			j := i + l
			for j < len(line) && (line[j] == ' ' || line[j] == '\t') {j += 1}
			if j < len(line) && line[j] == ':' {kind = .Json_Key}
			out[n] = Token{i, l, kind}
			n += 1
			i += l
			continue
		}

		if b == '{' || b == '}' || b == '[' || b == ']' || b == ',' || b == ':' {
			out[n] = Token{i, 1, .Punct}
			n += 1
			i += 1
			continue
		}

		if b == '-' || lj_is_digit(b) || (b == '.' && i + 1 < len(line) && lj_is_digit(line[i + 1])) {
			if l := lj_scan_number(line, i); l > 0 {
				out[n] = Token{i, l, .Number}
				n += 1
				i += l
				continue
			}
		}

		if lj_is_lower_alpha(b) {
			if l := lj_scan_keyword(line, i); l > 0 {
				out[n] = Token{i, l, .Keyword}
				n += 1
				i += l
				continue
			}
		}

		i += 1
	}
	return n
}
