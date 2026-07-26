// Layer: base -- the XML/HTML lexer, and the first one that needs Lex_State.
//
// Everything else in this batch so far (lex_log, lex_json) is entirely
// line-local: nothing about "am I inside a string" survives past the end of
// one call. XML breaks that the moment a `<!-- -->` comment crosses a line,
// which is why it is this task's lexer rather than a later one -- the
// simplest real multi-line construct there is, per the design doc.
//
// Scope, deliberately narrow (say so rather than silently half-implementing):
//   - Only `<!-- -->` carries state across lines. A tag or an attribute value
//     that itself contains a literal newline (legal XML, rare in practice) is
//     NOT tracked -- an unterminated tag simply stops matching at the line's
//     end, the same "never read past the line, never invent a second kind of
//     state" choice lex_json made for an unterminated string, just applied to
//     tags instead. If that turns out to matter for real files, it is a
//     second Lex_State value to add deliberately, not a reason to widen this
//     lexer's ambition quietly.
//   - `<!DOCTYPE ...>`, `<![CDATA[ ... ]]>` and `<? ... ?>` processing
//     instructions are not specially recognized. They fall through the
//     generic tag scanner below and colour approximately (name-shaped runs
//     inside them land as Xml_Attr) -- never a crash or a hang, just an
//     imprecise result on a construct the brief didn't ask for.
//   - Entity refs (`&amp;`, `&#169;`, `&#xA9;`) map to Token_Kind.Keyword.
//     There is no dedicated Entity kind -- theme.odin's nine Syn_* roles are
//     locked for this batch (CLAUDE.md's scope note) -- and Keyword is the
//     closest existing bucket to "a reserved lexical form embedded in text."
//   - '=' between an attribute name and its value is not itself tokenized;
//     colouring the name and the value is what actually reads, and adding a
//     Punct token for every '=' would just be noise.
package base

@(private = "file")
lx_is_name_start :: #force_inline proc(b: u8) -> bool {
	return (b >= 'a' && b <= 'z') || (b >= 'A' && b <= 'Z') || b == '_' || b == ':'
}

@(private = "file")
lx_is_name_char :: #force_inline proc(b: u8) -> bool {
	return lx_is_name_start(b) || (b >= '0' && b <= '9') || b == '-' || b == '.'
}

@(private = "file")
lx_is_alnum :: #force_inline proc(b: u8) -> bool {
	return (b >= 'a' && b <= 'z') || (b >= 'A' && b <= 'Z') || (b >= '0' && b <= '9')
}

// Length of a name run (tag name or attribute name) starting at line[i], or 0.
@(private = "file")
lx_scan_name :: proc(line: []u8, i: int) -> int {
	j := i
	for j < len(line) && lx_is_name_char(line[j]) {j += 1}
	return j - i
}

// Index just past the line's first "-->" at or after `i`, or -1 if none.
// Bounded by len(line) -- never reads past it, mirroring every other
// lexer's unterminated-construct guard.
@(private = "file")
lx_find_comment_close :: proc(line: []u8, i: int) -> int {
	j := i
	for j + 3 <= len(line) {
		if line[j] == '-' && line[j + 1] == '-' && line[j + 2] == '>' {return j + 3}
		j += 1
	}
	return -1
}

// Length of an entity ref starting at line[i] (line[i] is '&'), or 0 if what
// follows isn't one: "&name;", "&#123;" or "&#x1F;", bounded to a short scan
// (LX_ENTITY_SCAN_CAP bytes) so a bare '&' in prose -- "Smith & Wesson" --
// can't turn the rest of the line into a false match.
@(private = "file")
LX_ENTITY_SCAN_CAP :: 32

@(private = "file")
lx_scan_entity :: proc(line: []u8, i: int) -> int {
	cap := min(len(line), i + LX_ENTITY_SCAN_CAP)
	j := i + 1
	if j < cap && line[j] == '#' {
		j += 1
		if j < cap && (line[j] == 'x' || line[j] == 'X') {j += 1}
	}
	body_start := j
	for j < cap && lx_is_alnum(line[j]) {j += 1}
	if j == body_start {return 0} // "&;" or "&" at line end: nothing between
	if j < len(line) && line[j] == ';' {return j + 1 - i}
	return 0
}

// Scan one tag's attributes starting right after its name (or right after
// "<" for a nameless/malformed open like "<!DOCTYPE" or "<?xml", where the
// generic name scan below finds nothing and this loop absorbs the rest).
// Emits an Xml_Attr token per name-shaped run and a String token per quoted
// value, and stops at (consuming) the tag's closing ">" or "/>". Returns the
// index just past the tag, which may be len(line) if the tag never closes on
// this line -- an unterminated tag is simply not further tracked (see the
// header's scope note), so the caller does not need a Lex_State for it.
@(private = "file")
lx_scan_tag_rest :: proc(line: []u8, start: int, out: []Token, n: ^int) -> int {
	i := start
	for i < len(line) {
		b := line[i]
		if b == ' ' || b == '\t' || b == '\r' {
			i += 1
			continue
		}
		if b == '/' && i + 1 < len(line) && line[i + 1] == '>' {
			if n^ < len(out) {
				out[n^] = Token{i, 2, .Xml_Tag}
				n^ += 1
			}
			return i + 2
		}
		if b == '>' {
			if n^ < len(out) {
				out[n^] = Token{i, 1, .Xml_Tag}
				n^ += 1
			}
			return i + 1
		}
		if lx_is_name_start(b) {
			l := lx_scan_name(line, i)
			if n^ < len(out) {
				out[n^] = Token{i, l, .Xml_Attr}
				n^ += 1
			}
			i += l
			// Optional "=value"; skip the '=' itself (see header note) and
			// colour a quoted value as a String, same shape as lj_scan_string.
			j := i
			for j < len(line) && (line[j] == ' ' || line[j] == '\t') {j += 1}
			if j < len(line) && line[j] == '=' {
				j += 1
				for j < len(line) && (line[j] == ' ' || line[j] == '\t') {j += 1}
				if j < len(line) && (line[j] == '"' || line[j] == '\'') {
					q := line[j]
					k := j + 1
					for k < len(line) && line[k] != q {k += 1}
					vl := k + 1 - j if k < len(line) else 0
					if vl > 0 {
						if n^ < len(out) {
							out[n^] = Token{j, vl, .String}
							n^ += 1
						}
						j += vl
					}
				}
			}
			i = j
			continue
		}
		// Unrecognized byte inside a tag (stray punctuation, an unquoted
		// value, ...): skip it, never stall the loop.
		i += 1
	}
	return len(line) // unterminated: ran off the line without a '>'
}

// Lex one line of XML/HTML, threading Lex_State across calls so a `<!-- -->`
// spanning many lines colours correctly on every one of them: a caller
// re-lexing a document line by line passes each call's state_out back in as
// the next line's state_in (see program/doc.odin's doc_row_lex_spans for the
// in-viewport case and program/lex_index.odin for the background index that
// makes an arbitrary line's state_in available in the first place).
//
// No allocation, stops at `out`'s capacity rather than overflowing it --
// same contract as lex_log and lex_json.
lex_xml :: proc(line: []u8, state_in: Lex_State, out: []Token) -> (n: int, state_out: Lex_State) {
	state := state_in
	i := 0

	if state == .In_Comment {
		close := lx_find_comment_close(line, 0)
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

	// NOTE: scanning runs to len(line) regardless of `out`'s capacity -- only
	// the WRITES below are guarded by `n < len(out)`. state_out must reflect
	// the whole line even once `out` is full: a `<!--` past the 64th token
	// (HL_MAX_ROW_TOKENS) on a dense line is still real and still opens a
	// comment that the NEXT line's state_in must know about. Stopping the
	// scan at capacity (the original bug here) silently reports whatever
	// state was reached so far as if it were the line's true end state --
	// wrong, and wrong on every subsequent line too, since state threads
	// forward. lx_scan_tag_rest already had this shape (its own `n^ <
	// len(out)` guards, unconditional scan); the outer loop just hadn't
	// matched it.
	for i < len(line) {
		b := line[i]

		if b == '<' && i + 4 <= len(line) && line[i + 1] == '!' && line[i + 2] == '-' && line[i + 3] == '-' {
			close := lx_find_comment_close(line, i + 4)
			if close < 0 {
				if n < len(out) {
					out[n] = Token{i, len(line) - i, .Comment}
					n += 1
				}
				return n, .In_Comment // still open at end of line
			}
			if n < len(out) {
				out[n] = Token{i, close - i, .Comment}
				n += 1
			}
			i = close
			continue
		}

		if b == '<' {
			j := i + 1
			if j < len(line) && line[j] == '/' {j += 1}
			l := lx_scan_name(line, j)
			delim_len := (j + l) - i
			if n < len(out) {
				out[n] = Token{i, delim_len, .Xml_Tag}
				n += 1
			}
			i = lx_scan_tag_rest(line, i + delim_len, out, &n)
			continue
		}

		if b == '&' {
			if l := lx_scan_entity(line, i); l > 0 {
				if n < len(out) {
					out[n] = Token{i, l, .Keyword}
					n += 1
				}
				i += l
				continue
			}
		}

		i += 1
	}

	return n, state
}
