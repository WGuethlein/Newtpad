// Layer: base — the Markdown SOURCE lexer (.md .markdown).
//
// This colours the raw source text in the editor's normal view. It is a
// completely different feature from markdown.odin's Ctrl+M styled preview,
// which renders a rendered approximation of the document in its own draw
// path — that file is not touched, referenced, or in any way coupled to this
// one. Confusing the two would be a real regression: this lexer must never
// try to reproduce the preview's rendering, and the preview must never be
// asked to double as syntax colouring.
//
// Scope, deliberately narrow (say so rather than silently half-implementing,
// same discipline as every other lexer in this batch):
//   - ATX headings (`# ... ######`), blockquote markers (`>`), list markers
//     (`- `/`* `/`+ `/`N.`/`N)`), thematic breaks (`---`/`***`/`___`), fenced
//     code blocks (``` ```), inline code spans, bold (`**`/`__`), italic
//     (`*`/`_`), and links/images (`[text](url)`/`![alt](url)`).
//   - Setext headings (a line of text followed by a line of `===`/`---`)
//     are NOT recognized — that needs looking at the FOLLOWING line, which
//     doesn't fit this lexer's "one line at a time, forward-threaded state"
//     shape any more than it fits lex_xml's. Left plain.
//   - Indented (4-space) code blocks are NOT specially recognized —
//     unlike a fenced block, there is no delimiter to key off, so treating
//     one specially would need tracking paragraph/blank-line context this
//     lexer doesn't carry. Left to ordinary inline scanning, which is a
//     little too eager on such a block but never wrong in a persistent way.
//   - Reference-style links (`[text][ref]` / `[ref]: url`) are not
//     recognized as such — `[text][ref]` still gets its brackets coloured
//     Punct by the same bracket scan a real link uses, just without a URL to
//     colour, and a `[ref]: url` definition line isn't specially detected.
//   - HTML embedded directly in markdown (CommonMark permits raw HTML) is
//     not recognized — falls through to ordinary inline scanning.
//   - Nested emphasis, nested blockquotes, and nested lists are not
//     tracked — this is lexical colouring, not a parser (CLAUDE.md's
//     out-of-scope note: "no symbol tables... lexers, not parsers").
//
// Reuses Lex_State (lex.odin) exactly like lex_xml/lex_c: `.In_Comment` here
// means "inside an unterminated ``` fenced code block", nothing to do with
// an actual comment — the type's own comment says its two named values mean
// whatever a given lexer says they mean. While inside a fence, NOTHING is
// parsed: no heading, no emphasis, no link — the fence's entire point is
// "this is opaque content in some other language," so trying to apply
// markdown's own inline grammar to it would be exactly backwards.
//
// Fence matching is deliberately loose: ANY run of 3+ backticks OR 3+ tildes
// at (up to 3 spaces of) a line's start toggles the state, regardless of
// whether the closing run's length or its MARKER CHARACTER matches the
// opener's (real CommonMark requires the closer to be at least as long as the
// opener and to use the same character). This matches the Ctrl+M preview's own
// toggle exactly, which matters because the preview seeds its fence state from
// this lexer -- see mk_match_fence. This is a toggle, not a
// counted-nesting construct — see EXT_LEXERS's registration comment
// (program/highlight.odin) for why that shape defeats the bounded backward
// resync used for huge/mapped files specifically (unlike XML's "-->" or
// C's validated "*/", the SAME marker opens and closes here, so knowing
// "the last occurrence in a window" doesn't tell you whether that occurrence
// opened or closed — you need the PARITY of every occurrence since a known
// point, which a bounded window can't give you). The background per-line
// index (program/lex_index.odin), which always scans a small/medium file
// from its true start, is completely unaffected by this — parity is exact
// there. Only the huge-file bounded resync pays for it, and it pays by
// always falling back to the documented cap-hit .Normal, never by producing
// a wrong ACCEPT.
package base

@(private = "file")
mk_is_space :: #force_inline proc(b: u8) -> bool {return b == ' ' || b == '\t'}

// Leading space count, capped at 3 (CommonMark: a block marker indented 4+
// spaces is an indented code block instead, which this lexer doesn't
// specially track — see header). Tabs count as one space here, an
// approximation; real tab-stop expansion isn't worth it for this check.
@(private = "file")
mk_leading_spaces :: proc(line: []u8) -> int {
	n := 0
	for n < len(line) && n < 4 && line[n] == ' ' {n += 1}
	return n
}

// Length of a run of `ch` starting at line[i].
@(private = "file")
mk_run_len :: proc(line: []u8, i: int, ch: u8) -> int {
	j := i
	for j < len(line) && line[j] == ch {j += 1}
	return j - i
}

// Whether `lead` is a valid fence-marker position (<=3, per header) and
// line[lead] starts a run of 3+ backticks OR 3+ tildes. Returns the run's
// length, or 0.
//
// Tildes are here because the Ctrl+M preview (program/markdown.odin) has always
// toggled on `~~~` as well as ``` -- md_fence_lexer even maps `~~~yaml` -- and
// the preview now SEEDS its fence state from this lexer (md_fence_seed). A
// marker one side treats as a fence and the other does not is a disagreement
// that shows up as "the rest of the file became a code block" the moment the
// opening fence scrolls off screen, which is the bug that seed exists to fix.
//
// Two tildes is `~~struck~~`, not a fence: the >= 3 run length is what keeps
// them apart, exactly as it does for an inline `` `code` `` span.
@(private = "file")
mk_match_fence :: proc(line: []u8, lead: int) -> int {
	if lead > 3 || lead >= len(line) {return 0}
	ch := line[lead]
	if ch != '`' && ch != '~' {return 0}
	l := mk_run_len(line, lead, ch)
	if l < 3 {return 0}
	return l
}

// Whether the line (from `lead` on) is a thematic break: after skipping
// leading spaces, every remaining non-space byte is the SAME one of
// '-'/'*'/'_', with at least 3 occurrences of it. Checked before list
// markers so "---" isn't mistaken for a dash bullet with no content.
@(private = "file")
mk_match_hr :: proc(line: []u8, lead: int) -> bool {
	if lead >= len(line) {return false}
	marker := line[lead]
	if marker != '-' && marker != '*' && marker != '_' {return false}
	count := 0
	for j := lead; j < len(line); j += 1 {
		b := line[j]
		if b == ' ' || b == '\t' || b == '\r' {continue}
		if b != marker {return false}
		count += 1
	}
	return count >= 3
}

// Length of an ATX heading's "######" marker run at `lead` (1..6, must be
// followed by a space or the line's end), or 0.
@(private = "file")
mk_match_heading :: proc(line: []u8, lead: int) -> int {
	if lead >= len(line) || line[lead] != '#' {return 0}
	l := mk_run_len(line, lead, '#')
	if l < 1 || l > 6 {return 0}
	if lead + l < len(line) && !mk_is_space(line[lead + l]) {return 0}
	return l
}

// Length of a bullet-list marker ('-'/'*'/'+' followed by a space) at `i`,
// or 0. Callers only reach this after mk_match_hr has already failed, so a
// lone "- " genuinely is a list marker here, not a thematic break.
@(private = "file")
mk_match_bullet :: proc(line: []u8, i: int) -> int {
	if i >= len(line) {return 0}
	b := line[i]
	if b != '-' && b != '*' && b != '+' {return 0}
	if i + 1 >= len(line) || !mk_is_space(line[i + 1]) {return 0}
	return 1
}

// Length of an ordered-list marker (digits then '.' or ')' then a space) at
// `i`, or 0.
@(private = "file")
mk_match_ordered :: proc(line: []u8, i: int) -> int {
	j := i
	for j < len(line) && line[j] >= '0' && line[j] <= '9' {j += 1}
	if j == i {return 0} // no digits
	if j >= len(line) || (line[j] != '.' && line[j] != ')') {return 0}
	if j + 1 < len(line) && !mk_is_space(line[j + 1]) {return 0}
	return j + 1 - i
}

// Length of a same-line inline code span starting at line[i] (line[i] ==
// '`'), including both delimiter runs, or 0 if no CLOSING run of the exact
// same backtick count appears later on the line — real CommonMark rule
// (an inline code span's closer must match the opener's backtick count
// exactly, so a literal backtick can be embedded by opening with two).
@(private = "file")
mk_scan_code_span :: proc(line: []u8, i: int) -> int {
	open := mk_run_len(line, i, '`')
	j := i + open
	for j < len(line) {
		if line[j] == '`' {
			l := mk_run_len(line, j, '`')
			if l == open {return (j + l) - i}
			j += l
			continue
		}
		j += 1
	}
	return 0
}

// Length of a same-line "**text**" / "__text__" bold span starting at
// line[i] (line[i] == line[i+1] == marker), or 0 if it never closes on this
// line — left plain rather than coloured to the line's end, since a lone
// "**" or "__" is common, ordinary prose (see header).
@(private = "file")
mk_scan_bold :: proc(line: []u8, i: int, marker: u8) -> int {
	j := i + 2
	for j + 1 < len(line) {
		if line[j] == marker && line[j + 1] == marker {return (j + 2) - i}
		j += 1
	}
	return 0
}

// Length of a same-line "*text*" / "_text_" italic span starting at
// line[i], or 0 if it never closes on this line (same "leave it plain"
// contract).
@(private = "file")
mk_scan_italic :: proc(line: []u8, i: int, marker: u8) -> int {
	j := i + 1
	for j < len(line) {
		if line[j] == marker {return (j + 1) - i}
		j += 1
	}
	return 0
}

// Lex one line of Markdown SOURCE (not the Ctrl+M preview — see header).
// No allocation; stops at `out`'s capacity but keeps SCANNING for the fence
// state past it, exactly like every other stateful lexer in this batch (see
// the lesson-1 tests in lex_markdown_test.odin) — though for this grammar
// specifically, the fence toggle is decided BEFORE any inline token could
// ever be written for that line, so it is structurally immune to the
// Task-3/4 bug shape rather than merely tested against it (see header).
lex_markdown :: proc(line: []u8, state_in: Lex_State, out: []Token) -> (n: int, state_out: Lex_State) {
	n = 0
	state_out = state_in

	if state_in == .In_Comment {
		lead := mk_leading_spaces(line)
		if l := mk_match_fence(line, lead); l > 0 {
			if n < len(out) {
				out[n] = Token{lead, l, .Punct}
				n += 1
			}
			state_out = .Normal
		}
		// Whether or not a closing fence was found, nothing else on a
		// fenced-content line is ever parsed -- see header.
		return
	}

	lead := mk_leading_spaces(line)

	if l := mk_match_fence(line, lead); l > 0 {
		if n < len(out) {
			out[n] = Token{lead, l, .Punct}
			n += 1
		}
		state_out = .In_Comment
		return
	}

	if mk_match_hr(line, lead) {
		if n < len(out) {
			out[n] = Token{0, len(line), .Punct}
			n += 1
		}
		return
	}

	if l := mk_match_heading(line, lead); l > 0 {
		if n < len(out) {
			out[n] = Token{lead, len(line) - lead, .Keyword}
			n += 1
		}
		return
	}

	i := lead
	if i < len(line) && line[i] == '>' {
		if n < len(out) {
			out[n] = Token{i, 1, .Comment}
			n += 1
		}
		i += 1
		if i < len(line) && mk_is_space(line[i]) {i += 1}
	} else if l := mk_match_bullet(line, i); l > 0 {
		if n < len(out) {
			out[n] = Token{i, l, .Punct}
			n += 1
		}
		i += l
	} else if l := mk_match_ordered(line, i); l > 0 {
		if n < len(out) {
			out[n] = Token{i, l, .Punct}
			n += 1
		}
		i += l
	}

	for i < len(line) {
		b := line[i]

		if b == '\\' && i + 1 < len(line) {
			i += 2 // backslash-escaped punctuation: literal, no construct
			continue
		}

		if b == '`' {
			if l := mk_scan_code_span(line, i); l > 0 {
				if n < len(out) {
					out[n] = Token{i, l, .String}
					n += 1
				}
				i += l
				continue
			}
			i += mk_run_len(line, i, '`') // unmatched run: leave plain
			continue
		}

		if (b == '*' || b == '_') && i + 1 < len(line) && line[i + 1] == b {
			if l := mk_scan_bold(line, i, b); l > 0 {
				if n < len(out) {
					out[n] = Token{i, l, .Keyword}
					n += 1
				}
				i += l
				continue
			}
			i += 2 // unterminated: leave plain
			continue
		}

		if b == '*' || b == '_' {
			if l := mk_scan_italic(line, i, b); l > 0 {
				if n < len(out) {
					out[n] = Token{i, l, .Type}
					n += 1
				}
				i += l
				continue
			}
			i += 1 // unterminated: leave plain
			continue
		}

		if b == '!' || b == '[' {
			bang := b == '!'
			bracket_start := i
			link_start := i
			if bang {
				link_start += 1
				if link_start >= len(line) || line[link_start] != '[' {
					i += 1
					continue
				}
			}
			close_bracket := -1
			for j := link_start + 1; j < len(line); j += 1 {
				if line[j] == ']' {
					close_bracket = j
					break
				}
			}
			if close_bracket < 0 || close_bracket + 1 >= len(line) || line[close_bracket + 1] != '(' {
				i += 1
				continue
			}
			close_paren := -1
			for j := close_bracket + 2; j < len(line); j += 1 {
				if line[j] == ')' {
					close_paren = j
					break
				}
			}
			if close_paren < 0 {
				i += 1
				continue
			}
			if bang {
				if n < len(out) {
					out[n] = Token{bracket_start, 1, .Punct}
					n += 1
				}
			}
			if n < len(out) {
				out[n] = Token{link_start, 1, .Punct}
				n += 1
			}
			if n < len(out) {
				out[n] = Token{close_bracket, 1, .Punct}
				n += 1
			}
			url_start := close_bracket + 2
			url_len := close_paren - url_start
			if url_len > 0 && n < len(out) {
				out[n] = Token{url_start, url_len, .String}
				n += 1
			}
			if n < len(out) {
				out[n] = Token{close_paren, 1, .Punct}
				n += 1
			}
			i = close_paren + 1
			continue
		}

		i += 1
	}
	return
}

// The bounded backward resync's validator for Markdown (registered in
// EXT_LEXERS, program/highlight.odin): ALWAYS rejects. See this file's
// header for why — a "```" fence marker TOGGLES state rather than having a
// distinct open form and close form (unlike XML's "-->" or validated C's
// "*/"), so knowing the last occurrence in a window tells you nothing about
// whether it opened or closed without knowing the PARITY of every
// occurrence since a genuinely unambiguous point, which a bounded window
// cannot give. Mirrors base.lex_yaml_resync_valid's identical unconditional
// reject, for the same reason restated in different words: "the only
// answer that can never be wrong is 'no'" (see also
// base.lex_c_resync_valid's nest_comments carve-out, the first place this
// batch established the pattern). The small/medium-file background index
// is unaffected — it always scans from the file's true start, where parity
// is exact — only a huge/mapped markdown file's resync always cap-hits to
// .Normal.
lex_markdown_resync_valid :: proc(line: []u8, candidate_end: int) -> bool {
	return false
}
