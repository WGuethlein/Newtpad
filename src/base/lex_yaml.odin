// Layer: base — the YAML lexer (.yaml .yml), split out from lex_config.odin
// rather than folded in.
//
// Why separate: lex_config's six extensions (see that file's header) are
// all genuinely line-local — nothing about them needs Lex_State. YAML is
// not. Two things make that true, and the task brief asked specifically
// whether the block-scalar case fits Lex_State's one-byte budget rather
// than being approximated — the answer, verified by actually building it
// (not merely asserted), is YES, it fits, with one further limitation
// disclosed below that is a DIFFERENT kind of gap than "doesn't fit a
// byte":
//
//   - Significant indentation: a mapping's nesting is expressed by column,
//     not a delimiter. This lexer does not attempt to track or colour
//     indentation structure itself (no fold/nesting-depth display) — only
//     the ONE place indentation is load-bearing for correctness is used
//     below, which is the next point.
//   - Block scalars (`|` literal, `>` folded, each with optional `+`/`-`
//     chomping and an optional explicit indent digit) hold a raw, many-line
//     text blob whose EXTENT is determined purely by indentation: it runs
//     until a non-blank line whose indentation is no deeper than the
//     introducing key's own. That is exactly the shape lex_c's nested-
//     comment depth already proved fits in Lex_State's raw byte (lex.odin's
//     own comment invites exactly this: "reinterpret a non-Normal value's
//     raw byte as an integer... entirely within this same one-byte
//     budget") — here the byte holds (introducing key's indent + 1),
//     saturated at YM_MAX_SCALAR_INDENT so a pathologically deep file can
//     never wrap into a small, wrong depth. `.Normal` (0) means exactly
//     what it always means; every OTHER lexer's own Normal/In_Comment usage
//     is completely unaffected, per that same header comment.
//
// So the byte-width fear in the brief does NOT materialize. What DOES is a
// separate, real limitation worth being just as explicit about: the bounded
// BACKWARD RESYNC this batch built for huge/mapped files (lex_resync_state,
// program/lex_index.odin) has NO way to express "unambiguously Normal" for
// this grammar. Every other stateful lexer's resync_anchor is either a
// fixed byte sequence that can only ever CLOSE a construct (XML's "-->",
// validated C's "*/") — so finding the last occurrence in a window and
// checking it locally is sound — or (this lexer) has no such marker at
// all, because a block scalar's END is defined by the FOLLOWING line's
// indentation relative to a key arbitrarily far above it, which
// Resync_Validate_Proc's signature (one physical line, one offset within
// it) cannot express. Rather than approximate that unsoundly, YAML's
// registration (program/highlight.odin's EXT_LEXERS) supplies a
// resync_validate that ALWAYS rejects — see lex_yaml_resync_valid below —
// so a huge/mapped yaml file's bounded resync always falls back to the
// documented .Normal cap-hit, on every call, not merely when a scalar
// outgrows the window. Small and medium files (the overwhelming majority
// of yaml Wyatt would ever open) are unaffected: the background per-line
// index (lex_index_start) never consults resync_anchor at all — it walks
// the whole file from its true, unambiguous start, so its per-line state is
// always exactly correct.
//
// Further, deliberately out of scope (say so rather than guess):
//   - Multi-line FLOW collections (`[...]`/`{...}` spanning several lines)
//     are not tracked — real yaml overwhelmingly uses block style for
//     anything that would otherwise need this, and adding a second,
//     independent multi-line construct competing for the same one-byte
//     state was a real trade this task chose not to spend on.
//   - Anchors (`&name`), aliases (`*name`), and explicit tags (`!!str`) are
//     not recognized as their own construct — no clean Token_Kind fits
//     "anchor" or "tag" without stretching one of the nine Syn_* roles past
//     what it visually means elsewhere, so these are left plain.
//   - The block scalar's PARENT INDENT is approximated as the introducing
//     LINE's own leading-whitespace count, even when that line begins with
//     a "- " sequence marker (e.g. "- key: |") — real YAML measures from
//     the key's own column in that case, a couple of columns deeper. This
//     lexer's approximation is conservative in the safe direction (it
//     accepts a couple of columns of indentation MORE than YAML strictly
//     requires as "still inside the scalar" before it fully bites), not a
//     source of a false early accept.
package base

@(private = "file")
ym_is_ws :: #force_inline proc(b: u8) -> bool {return b == ' ' || b == '\t'}

@(private = "file")
ym_is_digit :: #force_inline proc(b: u8) -> bool {return b >= '0' && b <= '9'}

@(private = "file")
ym_is_alpha :: #force_inline proc(b: u8) -> bool {
	return (b >= 'a' && b <= 'z') || (b >= 'A' && b <= 'Z')
}

@(private = "file")
ym_is_key_char :: #force_inline proc(b: u8) -> bool {
	return ym_is_alpha(b) || ym_is_digit(b) || b == '_' || b == '-' || b == '.'
}

@(private = "file")
ym_leading_ws :: proc(line: []u8) -> int {
	n := 0
	for n < len(line) && ym_is_ws(line[n]) {n += 1}
	return n
}

@(private = "file")
ym_scan_key :: proc(line: []u8, i: int) -> int {
	j := i
	for j < len(line) && ym_is_key_char(line[j]) {j += 1}
	return j - i
}

@(private = "file")
ym_scan_quoted :: proc(line: []u8, i: int) -> int {
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

// Same lenient shape as lex_config's cf_scan_number/lex_json's
// lj_scan_number, duplicated per this batch's established per-file
// convention.
@(private = "file")
ym_scan_number :: proc(line: []u8, i: int) -> int {
	j := i
	if j < len(line) && line[j] == '-' {j += 1}
	saw := false
	for j < len(line) && ym_is_digit(line[j]) {
		j += 1
		saw = true
	}
	if !saw {return 0}
	if j < len(line) && line[j] == '.' && j + 1 < len(line) && ym_is_digit(line[j + 1]) {
		j += 1
		for j < len(line) && ym_is_digit(line[j]) {j += 1}
	}
	return j - i
}

@(private = "file")
YAML_KEYWORDS :: []string{
	"true", "false", "null",
	"True", "False", "Null",
	"TRUE", "FALSE", "NULL",
	"yes", "no", "on", "off",
	"Yes", "No", "On", "Off",
	"YES", "NO", "ON", "OFF",
}

@(private = "file")
ym_word_in :: proc(word: string, list: []string) -> bool {
	for w in list {
		if w == word {return true}
	}
	return false
}

// A document marker ("---" start-of-document, "..." end-of-document) is
// only ever valid at column 0 (never indented), and only when followed by
// whitespace, a comment, or the line's end.
@(private = "file")
ym_match_doc_marker :: proc(line: []u8, i: int) -> int {
	if i != 0 || len(line) - i < 3 {return 0}
	is_dashes := line[i] == '-' && line[i + 1] == '-' && line[i + 2] == '-'
	is_dots := line[i] == '.' && line[i + 1] == '.' && line[i + 2] == '.'
	if !is_dashes && !is_dots {return 0}
	if i + 3 < len(line) && !ym_is_ws(line[i + 3]) && line[i + 3] != '#' {return 0}
	return 3
}

// Block sequence marker: '-' followed by whitespace or the line's end.
// Checked only after ym_match_doc_marker has already failed, so this never
// mistakes "---" for a sequence marker.
@(private = "file")
ym_match_seq_marker :: proc(line: []u8, i: int) -> bool {
	if i >= len(line) || line[i] != '-' {return false}
	return i + 1 >= len(line) || ym_is_ws(line[i + 1])
}

// Saturation cap on the block-scalar indent depth carried in Lex_State's raw
// byte — mirrors lex_c's LC_MAX_COMMENT_DEPTH exactly, same reasoning:
// Lex_State is one byte (lex.odin's #assert), depth is threaded across
// lines AS that byte's raw value, and a plain `+1` at 255 would wrap to 0
// and silently masquerade as .Normal. 254 columns of real indentation is
// not a file that exists; this only guards the theoretical case.
YM_MAX_SCALAR_INDENT :: 254

// Whether line[val_start:] opens a block scalar ("|" or ">" optionally
// followed by chomping "+"/"-" and/or an explicit indent digit, then only
// whitespace or a comment to the line's end), and if so, the indicator
// run's length (for colouring only — the actual indent tracked is the
// introducing line's own leading whitespace, see header).
@(private = "file")
ym_match_block_scalar :: proc(line: []u8, val_start: int) -> (ind_len: int, ok: bool) {
	if val_start >= len(line) {return 0, false}
	if line[val_start] != '|' && line[val_start] != '>' {return 0, false}
	j := val_start + 1
	for j < len(line) && (line[j] == '+' || line[j] == '-' || ym_is_digit(line[j])) {j += 1}
	k := j
	for k < len(line) && ym_is_ws(line[k]) {k += 1}
	if k < len(line) && line[k] != '#' {return 0, false}
	return j - val_start, true
}

// Lex one line of YAML. `state_in`/`state_out` mean "inside an open block
// scalar, whose introducing key was indented at int(state)-1" for any
// non-.Normal value — see header. No allocation, stops emitting at `out`'s
// capacity but the state decision always happens before the general
// (capacity-bounded) scan begins, so it is never gated by how many tokens
// fit — see the zero-capacity tests in lex_yaml_test.odin, the direct
// equivalent of lex_xml/lex_c/lex_markdown's own capacity-vs-state proofs.
lex_yaml :: proc(line: []u8, state_in: Lex_State, out: []Token) -> (n: int, state_out: Lex_State) {
	state_out = state_in
	n = 0
	lead := ym_leading_ws(line)
	blank := lead == len(line)

	if state_in != .Normal {
		parent_indent := int(state_in) - 1
		if blank || lead > parent_indent {
			return // still inside the scalar: no tokens, state unchanged
		}
		state_out = .Normal // scalar ends here; re-lex this line fresh below
	}

	i := lead

	if l := ym_match_doc_marker(line, i); l > 0 {
		if n < len(out) {
			out[n] = Token{i, l, .Punct}
			n += 1
		}
		return
	}

	if ym_match_seq_marker(line, i) {
		if n < len(out) {
			out[n] = Token{i, 1, .Punct}
			n += 1
		}
		i += 1
		if i < len(line) && ym_is_ws(line[i]) {i += 1}
	}

	if i < len(line) && ym_is_key_char(line[i]) && !ym_is_digit(line[i]) {
		kl := ym_scan_key(line, i)
		if kl > 0 {
			j := i + kl
			for j < len(line) && ym_is_ws(line[j]) {j += 1}
			if j < len(line) && line[j] == ':' && (j + 1 >= len(line) || ym_is_ws(line[j + 1])) {
				if n < len(out) {
					out[n] = Token{i, kl, .Json_Key}
					n += 1
				}
				if n < len(out) {
					out[n] = Token{j, 1, .Punct}
					n += 1
				}
				val_start := j + 1
				for val_start < len(line) && ym_is_ws(line[val_start]) {val_start += 1}
				if ind_len, ok := ym_match_block_scalar(line, val_start); ok {
					if n < len(out) {
						out[n] = Token{val_start, ind_len, .Punct}
						n += 1
					}
					depth := min(lead + 1, YM_MAX_SCALAR_INDENT)
					state_out = Lex_State(u8(depth))
					return
				}
				i = val_start
			}
		}
	}

	for i < len(line) && n < len(out) {
		b := line[i]

		if b == '#' && (i == 0 || ym_is_ws(line[i - 1])) {
			out[n] = Token{i, len(line) - i, .Comment}
			n += 1
			i = len(line)
			continue
		}

		if b == '"' || b == '\'' {
			l := ym_scan_quoted(line, i)
			if l == 0 {l = len(line) - i}
			out[n] = Token{i, l, .String}
			n += 1
			i += l
			continue
		}

		if b == '-' || ym_is_digit(b) {
			if l := ym_scan_number(line, i); l > 0 {
				out[n] = Token{i, l, .Number}
				n += 1
				i += l
				continue
			}
		}

		if b == '~' {
			out[n] = Token{i, 1, .Keyword}
			n += 1
			i += 1
			continue
		}

		if ym_is_alpha(b) {
			j := i
			for j < len(line) && (ym_is_alpha(line[j]) || ym_is_digit(line[j])) {j += 1}
			word := string(line[i:j])
			if ym_word_in(word, YAML_KEYWORDS) {
				out[n] = Token{i, j - i, .Keyword}
				n += 1
			}
			i = j
			continue
		}

		if b == '[' || b == ']' || b == '{' || b == '}' || b == ',' {
			out[n] = Token{i, 1, .Punct}
			n += 1
			i += 1
			continue
		}

		i += 1
	}
	return
}

// The bounded backward resync's validator for YAML (registered in
// EXT_LEXERS, program/highlight.odin): ALWAYS rejects. See this file's
// header for why no candidate can ever be soundly validated here — the
// termination condition is the FOLLOWING line's indentation relative to an
// arbitrarily-distant key, which Resync_Validate_Proc's one-line signature
// cannot see. Mirrors base.lex_c_resync_valid's identical unconditional-
// reject for Rust/Odin's nest_comments case: "the only answer that can
// never be wrong is 'no'" applies here for a different structural reason
// (no expressible anchor at all, rather than an anchor whose accept case
// can't be told apart from a false one), but the shape of the trade — the
// small-file background index stays exact; only the huge-file resync always
// cap-hits to .Normal — is the same one already precedented in this batch.
lex_yaml_resync_valid :: proc(line: []u8, candidate_end: int) -> bool {
	return false
}
