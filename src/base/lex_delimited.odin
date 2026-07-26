// Layer: base — the delimited-values lexer (.csv .tsv).
//
// One grammar, one parameter (the delimiter byte: ',' for .csv, '\t' for
// .tsv) — same "one grammar, per-language data" shape as lex_c's
// Keyword_Set, just a single byte instead of a struct, because a delimiter
// is the only thing that differs between the two extensions.
//
// RFC4180 is the model, applied leniently (colour the plausible shape, don't
// validate it — same philosophy as lex_json's number scanning):
//   - A field beginning with '"' is a quoted field: `""` is an escaped quote
//     (does not end the field), the next unescaped '"' closes it. An
//     unterminated quoted field colours to the line's end rather than
//     producing nothing, matching lex_json/lex_c's unterminated-string
//     contract.
//   - An unquoted field is bounded by the delimiter or the line's end. It is
//     coloured Number only if the WHOLE field (not just a leading run) is
//     one plausible number — "3rd" must not colour its leading digits, since
//     that would assert the field is numeric when it plainly isn't. There is
//     no generic "this is a text cell" token: a 10th Syn_* role for "plain
//     data" isn't worth adding for this batch, so a non-numeric unquoted
//     field simply gets no token at all.
//   - The delimiter itself is Punct.
//
// Deliberately LINE-LOCAL — no Lex_State, unlike lex_xml/lex_c. RFC4180
// technically permits a quoted field to contain a literal embedded newline,
// which would need a Lex_State value ("still inside a quoted field") to
// track correctly across physical lines, same shape as lex_xml's In_Comment.
// This is a real, known gap: a multi-line quoted cell will lex as "quoted
// field runs to this physical line's end" and then restart eval as a fresh,
// unquoted line — WRONG for the continuation lines, which are really still
// inside the same field. It was left out rather than half-built: unlike
// lex_xml's comment (whose sole purpose IS to span lines) or lex_c's block
// comment, a genuinely multi-line CSV cell is comparatively rare in files
// Wyatt actually opens (exported spreadsheets more often escape newlines as
// literal "\n" or strip them), and the failure mode is bounded and
// self-correcting: it mis-colours only the lines the embedded newline
// spans, not "the rest of the file forever" the way an unclosed XML/C
// comment can. If this turns out to matter on real files, it is a second
// Lex_State value to add deliberately (see lex.odin's own comment on that
// budget), not a reason to have guessed here.
package base

@(private = "file")
ld_is_digit :: #force_inline proc(b: u8) -> bool {return b >= '0' && b <= '9'}

// Length of a quoted field starting at line[i] (line[i] == '"'), including
// both delimiting quotes, or 0 if it never closes before the line ends (the
// caller colours that remainder to the line's end instead — see header).
// `""` inside the field is an escaped quote, not a close.
@(private = "file")
ld_scan_quoted_field :: proc(line: []u8, i: int) -> int {
	j := i + 1
	for j < len(line) {
		if line[j] == '"' {
			if j + 1 < len(line) && line[j + 1] == '"' {
				j += 2
				continue
			}
			return j + 1 - i
		}
		j += 1
	}
	return 0 // unterminated
}

// Whether line[i:end] is, in its entirety, one plausible number (optional
// leading '-', digits, optional ".digits") — not just a prefix of it. Mirrors
// lj_scan_number's leniency (lex_json.odin) but requires FULL consumption of
// the field, which is the one thing that differs: "3rd" must not colour "3"
// as a Number when the rest of the field ("rd") is left dangling.
@(private = "file")
ld_field_is_number :: proc(line: []u8, i, end: int) -> bool {
	j := i
	if j < end && line[j] == '-' {j += 1}
	saw_digit := false
	for j < end && ld_is_digit(line[j]) {
		j += 1
		saw_digit = true
	}
	if j < end && line[j] == '.' {
		j += 1
		for j < end && ld_is_digit(line[j]) {
			j += 1
			saw_digit = true
		}
	}
	return saw_digit && j == end
}

// Lex one row of delimited data: quoted fields (String), the delimiter
// (Punct), and unquoted fields that are wholly numeric (Number) — everything
// else in an unquoted field is left plain (see header). No allocation, no
// state carried between calls (line-local — see header), stops at `out`'s
// capacity like every other lexer here.
lex_delimited :: proc(line: []u8, delim: u8, out: []Token) -> int {
	n := 0
	i := 0
	for i < len(line) && n < len(out) {
		b := line[i]

		if b == delim {
			out[n] = Token{i, 1, .Punct}
			n += 1
			i += 1
			continue
		}

		if b == '"' {
			l := ld_scan_quoted_field(line, i)
			if l == 0 {l = len(line) - i} // unterminated: colour to EOL, see header
			out[n] = Token{i, l, .String}
			n += 1
			i += l
			continue
		}

		// Unquoted field: bounded by the next delimiter or the line's end.
		field_end := i
		for field_end < len(line) && line[field_end] != delim {field_end += 1}
		if ld_field_is_number(line, i, field_end) {
			out[n] = Token{i, field_end - i, .Number}
			n += 1
		}
		i = field_end
	}
	return n
}
