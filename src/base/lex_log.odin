// Layer: base — the log-file pattern lexer.
//
// A log line has no grammar: colouring one means recognising *patterns* — a
// timestamp, a level word, a quoted string, a bare number — not tokens of a
// language. That makes it entirely line-local: nothing here carries state
// from one line to the next, which is exactly why the log lexer ships first
// (see .superpowers/sdd/task-1-brief.md) — it proves the span pipeline
// without needing the multi-line state index later lexers require.
package base

@(private = "file")
lg_is_digit :: #force_inline proc(b: u8) -> bool {return b >= '0' && b <= '9'}

@(private = "file")
lg_is_word :: #force_inline proc(b: u8) -> bool {
	return (b >= 'a' && b <= 'z') || (b >= 'A' && b <= 'Z') || (b >= '0' && b <= '9') || b == '_'
}

// Length of an ISO-8601-ish timestamp starting at line[0], or 0 if none.
// Recognizes YYYY-MM-DD, optionally followed by ('T' or ' ') HH:MM:SS,
// optionally ".fff" fractional seconds, optionally a "Z" or "+HH:MM"/"-HH:MM"
// offset. Deliberately not a full ISO-8601 parser — a pattern lexer only
// needs to recognize the shapes that actually show up in logs, not validate
// them against the spec.
@(private = "file")
lg_scan_iso :: proc(line: []u8) -> int {
	if len(line) < 10 {return 0}
	d := lg_is_digit
	if !(d(line[0]) && d(line[1]) && d(line[2]) && d(line[3]) && line[4] == '-' &&
		d(line[5]) && d(line[6]) && line[7] == '-' && d(line[8]) && d(line[9])) {
		return 0
	}
	n := 10
	if n < len(line) && (line[n] == 'T' || line[n] == ' ') {
		m := n + 1
		if m + 8 <= len(line) &&
			d(line[m]) && d(line[m + 1]) && line[m + 2] == ':' &&
			d(line[m + 3]) && d(line[m + 4]) && line[m + 5] == ':' &&
			d(line[m + 6]) && d(line[m + 7]) {
			n = m + 8
			if n < len(line) && line[n] == '.' {
				k := n + 1
				for k < len(line) && d(line[k]) {k += 1}
				if k > n + 1 {n = k}
			}
			if n < len(line) && (line[n] == 'Z' || line[n] == 'z') {
				n += 1
			} else if n + 5 < len(line) &&
				(line[n] == '+' || line[n] == '-') &&
				d(line[n + 1]) && d(line[n + 2]) && line[n + 3] == ':' &&
				d(line[n + 4]) && d(line[n + 5]) {
				n += 6
			}
		}
	}
	return n
}

// Length of a bracketed timestamp like "[2026-07-25 10:23:45]" starting at
// line[0], or 0 if none. Bounded scan for the closing ']' (at most 64 bytes)
// so a line missing it can't run the match past the line — the same shape
// as the unterminated-quote guard below.
@(private = "file")
lg_scan_bracketed :: proc(line: []u8) -> int {
	if len(line) == 0 || line[0] != '[' {return 0}
	cap := min(len(line), 64)
	saw_digit, saw_sep := false, false
	for j := 1; j < cap; j += 1 {
		b := line[j]
		if b == ']' {
			if saw_digit && saw_sep {return j + 1}
			return 0
		}
		if lg_is_digit(b) {saw_digit = true}
		if b == ':' || b == '-' {saw_sep = true}
	}
	return 0
}

@(private = "file")
LEVEL_WORDS :: []string{"ERROR", "WARNING", "WARN", "INFO", "DEBUG", "TRACE"}

// Whole-word match of a level keyword at line[i] (line[i] is already known
// uppercase-alpha), or 0 if none. Checks a word-boundary on both sides, so
// "PREINFO" and "ERRORCODE" don't match despite containing "INFO"/"ERROR" as
// substrings. "WARNING" is listed before "WARN" — it is a superstring of
// "WARN", so checking it first lets a genuine "WARNING" consume all 7 bytes
// instead of matching "WARN" and leaving "ING" an orphaned non-token.
@(private = "file")
lg_scan_level :: proc(line: []u8, i: int) -> int {
	if i > 0 && lg_is_word(line[i - 1]) {return 0}
	for w in LEVEL_WORDS {
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
		if i + wl < len(line) && lg_is_word(line[i + wl]) {continue} // e.g. ERRORCODE
		return wl
	}
	return 0
}

// Length of a quoted string starting at line[i] (line[i] is '"' or '\''), or
// 0 if the closing quote never appears before the line ends. An unterminated
// quote is simply not a match — never a token whose length would read past
// len(line) — because the scan only ever advances `j` while `j < len(line)`.
@(private = "file")
lg_scan_string :: proc(line: []u8, i: int) -> int {
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
	return 0 // unterminated
}

// Length of a bare number starting at line[i] (line[i] is a digit), or 0.
// Accepts one embedded '.' followed by another digit, so "3.14" lexes as one
// token instead of two separated by a Punct gap.
@(private = "file")
lg_scan_number :: proc(line: []u8, i: int) -> int {
	j := i
	saw_dot := false
	for j < len(line) {
		b := line[j]
		if lg_is_digit(b) {
			j += 1
			continue
		}
		if b == '.' && !saw_dot && j + 1 < len(line) && lg_is_digit(line[j + 1]) {
			saw_dot = true
			j += 1
			continue
		}
		break
	}
	return j - i
}

// Pattern-lex one line: a leading timestamp (ISO or bracketed) -> Number, a
// whole-word level -> Keyword, a quoted string -> String, a bare number ->
// Number. No allocation and no state carried between calls — this runs per
// visible row per frame (see program/highlight.odin's highlight_row_spans).
// Stops at `out`'s capacity rather than writing past it; a line producing
// more matches than `out` holds simply loses the tail, which is fine for a
// display-only span list — there is no "the rest of the line is wrong"
// consequence, just fewer coloured tokens on an already-pathological line.
lex_log :: proc(line: []u8, out: []Token) -> int {
	n := 0
	i := 0
	for i < len(line) && n < len(out) {
		b := line[i]

		if i == 0 {
			if l := lg_scan_bracketed(line); l > 0 {
				out[n] = Token{0, l, .Number}
				n += 1
				i += l
				continue
			}
			if l := lg_scan_iso(line); l > 0 {
				out[n] = Token{0, l, .Number}
				n += 1
				i += l
				continue
			}
		}

		if b >= 'A' && b <= 'Z' {
			if l := lg_scan_level(line, i); l > 0 {
				out[n] = Token{i, l, .Keyword}
				n += 1
				i += l
				continue
			}
		}

		if b == '"' || b == '\'' {
			if l := lg_scan_string(line, i); l > 0 {
				out[n] = Token{i, l, .String}
				n += 1
				i += l
				continue
			}
			i += 1
			continue
		}

		if lg_is_digit(b) {
			if l := lg_scan_number(line, i); l > 0 {
				out[n] = Token{i, l, .Number}
				n += 1
				i += l
				continue
			}
		}

		i += 1
	}
	return n
}
