// Layer: base — reformatting minified JSON into readable JSON.
//
// Wyatt, 2026-07-30: *"if a json comes in not following the typical formatting
// schema, I want to give an option to format it so that it no longer looks like
// the log file, but the tasks.json… vscode has a similar feature."* So: VS Code's
// Format Document, for JSON.
//
// A REWRITE, NOT A PARSE. There is no AST, no map, no value type — the input is
// walked token by token and re-emitted with newlines and indentation inserted
// between them. That is not a shortcut, it is the requirement: **key order must be
// preserved**, and parse-to-map-and-re-emit loses it (Odin's map has no insertion
// order, and neither does anyone else's). It also means a number is re-emitted as
// the bytes the file had, so `1.50` and `1e3` survive as written rather than being
// normalised through a float.
//
// IT SHARES THE LEXER'S SCANNERS (lj_scan_string, lj_scan_number,
// lj_scan_keyword). The highlighter and the formatter must agree byte for byte
// about where a string ends, or one would colour a span the other rewrote — an
// escape rule differing by a single byte is enough. Those three procedures went
// package-visible for this and nothing else.
//
// UNLIKE THE LEXER, THIS VALIDATES. lex_json's own header says it "colours, it
// does not validate": an unterminated string colours to the line's end, an
// unbalanced brace is just punctuation. That is right for colouring and wrong
// here, because the output replaces the user's file. Every malformed shape the
// lexer shrugs at is a refusal with a byte offset here.
package base

// How deep a nesting this will format.
//
// A bound rather than a [dynamic]u8 stack, because the bound is the useful part:
// JSON nested past a few hundred levels is either generated or hostile, and a
// formatter that happily recursed into it would be a stack overflow waiting on
// somebody's input. Refusing names its own reason and costs a real file nothing —
// the deepest hand-written config anyone has is single digits.
JSON_MAX_DEPTH :: 256

// Why a format failed, so the caller can say something better than "no".
Json_Error :: enum {
	None,
	Unterminated_String,
	Unexpected_Byte,
	Unbalanced, // a closer with no opener, or the wrong one
	Trailing_Content, // a second value after the first
	Too_Deep,
	Truncated, // ran out while a container was still open
}

// Reformat `src`. `indent` is spaces per level.
//
// On failure `at` is the byte offset of the problem and `out` is nil — the caller
// must NOT write a partial result over the user's file. "Marked, not silently
// refused" (the rule §10 applies to malformed CSV rows) is served by handing back
// the offset so the caller can put the caret on it.
json_format :: proc(src: []u8, indent: int, allocator := context.allocator) -> (out: []u8, err: Json_Error, at: int) {
	// Worst case is roughly one newline plus `indent` spaces per token, and a
	// minified file is nearly all tokens. Two-and-a-bit times the input is a
	// generous first guess that avoids most regrowth; `append` handles the rest.
	buf := make([dynamic]u8, 0, len(src) * 2 + 64, allocator)
	stack: [JSON_MAX_DEPTH]u8 // the opener byte at each level, so a mismatch is nameable
	depth := 0
	// WHAT MAY COME NEXT. An explicit position rather than a "need a value" bool,
	// because an object has four positions and not two -- key, colon, value,
	// separator -- and a bool cannot tell a KEY from a VALUE. That is not academic:
	// with a bool, `{"a" 1}` reads as two values in a row and formats happily,
	// producing output that is not JSON. It is the case the tests caught.
	Expect :: enum {
		Value, // a value is required (start, after ':', after ',' in an array)
		Key, // a member name is required (after '{', after ',' in an object)
		Colon, // ':' is required (after a key)
		Sep, // ',' or the matching closer
	}
	expect := Expect.Value
	// Has the top-level value been closed? Anything after that is trailing content.
	done := false

	nl_indent :: proc(buf: ^[dynamic]u8, depth, indent: int) {
		append(buf, '\n')
		for _ in 0 ..< depth * indent {append(buf, ' ')}
	}

	// The next non-whitespace byte at or after i, or len(src).
	skip_ws :: proc(src: []u8, i: int) -> int {
		j := i
		for j < len(src) {
			switch src[j] {
			case ' ', '\t', '\r', '\n':
				j += 1
			case:
				return j
			}
		}
		return j
	}

	i := skip_ws(src, 0)
	for i < len(src) {
		b := src[i]
		if done {
			delete(buf)
			return nil, .Trailing_Content, i
		}
		switch b {
		case '{', '[':
			if expect != .Value {
				delete(buf)
				return nil, .Unexpected_Byte, i
			}
			if depth >= JSON_MAX_DEPTH {
				delete(buf)
				return nil, .Too_Deep, i
			}
			// An EMPTY container stays on one line. `{}` spread over three is
			// noise, and every formatter anyone has used keeps it compact.
			closer: u8 = '}' if b == '{' else ']'
			j := skip_ws(src, i + 1)
			if j < len(src) && src[j] == closer {
				append(&buf, b)
				append(&buf, closer)
				expect = .Sep
				if depth == 0 {done = true}
				i = skip_ws(src, j + 1)
				continue
			}
			append(&buf, b)
			stack[depth] = b
			depth += 1
			nl_indent(&buf, depth, indent)
			expect = .Key if b == '{' else .Value
			i = skip_ws(src, i + 1)
		case '}', ']':
			if depth == 0 {
				delete(buf)
				return nil, .Unbalanced, i
			}
			want: u8 = '}' if stack[depth - 1] == '{' else ']'
			if b != want {
				delete(buf)
				return nil, .Unbalanced, i
			}
			// Only after a complete member or element. Anything else here is a
			// trailing comma, a key with no value, or a colon with nothing after it.
			if expect != .Sep {
				delete(buf)
				return nil, .Unexpected_Byte, i
			}
			depth -= 1
			nl_indent(&buf, depth, indent)
			append(&buf, b)
			expect = .Sep
			if depth == 0 {done = true}
			i = skip_ws(src, i + 1)
		case ',':
			if expect != .Sep || depth == 0 {
				delete(buf)
				return nil, .Unexpected_Byte, i
			}
			append(&buf, ',')
			nl_indent(&buf, depth, indent)
			expect = .Key if stack[depth - 1] == '{' else .Value
			i = skip_ws(src, i + 1)
		case ':':
			if expect != .Colon {
				delete(buf)
				return nil, .Unexpected_Byte, i
			}
			// ": " -- a space after the colon and none before it, which is what
			// every JSON emitter produces and what the tasks.json example shows.
			append(&buf, ':')
			append(&buf, ' ')
			expect = .Value
			i = skip_ws(src, i + 1)
		case '"':
			if expect != .Value && expect != .Key {
				delete(buf)
				return nil, .Unexpected_Byte, i
			}
			l := lj_scan_string(src, i)
			if l == 0 {
				delete(buf)
				return nil, .Unterminated_String, i
			}
			// Emitted VERBATIM, escapes and all: re-encoding a string means
			// deciding what to do with \uXXXX, with lone surrogates and with the
			// bytes above ASCII, and every one of those answers can change what the
			// file means. The formatter's job is whitespace.
			append(&buf, ..src[i:i + l])
			// A string in KEY position is followed by a colon, not by a separator.
			// This is the distinction a "need a value" bool could not make, and
			// without it `{"a" 1}` formats as though it were valid.
			was_key := expect == .Key
			expect = .Colon if was_key else .Sep
			if depth == 0 && !was_key {done = true}
			i = skip_ws(src, i + l)
		case:
			if expect != .Value {
				delete(buf)
				return nil, .Unexpected_Byte, i
			}
			if l := lj_scan_number(src, i); l > 0 {
				append(&buf, ..src[i:i + l])
				expect = .Sep
				if depth == 0 {done = true}
				i = skip_ws(src, i + l)
				continue
			}
			if l := lj_scan_keyword(src, i); l > 0 {
				// The lexer's keyword scan is lenient by design -- it takes a run of
				// lower-case letters -- so `tru` reaches here as a keyword. JSON has
				// exactly three, and this is the layer that says so.
				w := string(src[i:i + l])
				if w != "true" && w != "false" && w != "null" {
					delete(buf)
					return nil, .Unexpected_Byte, i
				}
				append(&buf, ..src[i:i + l])
				expect = .Sep
				if depth == 0 {done = true}
				i = skip_ws(src, i + l)
				continue
			}
			delete(buf)
			return nil, .Unexpected_Byte, i
		}
	}
	if depth != 0 {
		delete(buf)
		return nil, .Truncated, len(src)
	}
	if !done {
		// Empty input, or nothing but whitespace: there is no value to format, and
		// rewriting the file to nothing would be the worst possible answer.
		delete(buf)
		return nil, .Truncated, 0
	}
	append(&buf, '\n') // a text file ends in a newline
	return buf[:], .None, 0
}

// What went wrong, in words a status line can show.
json_error_text :: proc(e: Json_Error) -> string {
	switch e {
	case .None:
		return ""
	case .Unterminated_String:
		return "unterminated string"
	case .Unexpected_Byte:
		return "unexpected character"
	case .Unbalanced:
		return "unbalanced bracket"
	case .Trailing_Content:
		return "extra content after the value"
	case .Too_Deep:
		return "nested too deeply"
	case .Truncated:
		return "incomplete JSON"
	}
	return "invalid JSON"
}
