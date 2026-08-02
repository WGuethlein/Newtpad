// Layer: base — reformatting minified CSS and SCSS into readable CSS.
//
// The same shape as json_format.odin and for the same reason: **whitespace is
// never significant in CSS**, so the file can be walked token by token and
// re-emitted with newlines and indentation between them, with no AST and no
// parser. That property is the whole reason this is ~200 lines rather than a
// project; it is also why JavaScript is not here (see requested-features.md).
//
// SCSS comes free rather than as a second mode. Nesting is just more `{}`, `$vars`
// and `&` are ordinary tokens, and the one real addition is the `//` line comment.
// Nothing else in SCSS's grammar changes how whitespace may be inserted.
//
// WHAT IT NEVER TOUCHES: the bytes inside a string, a comment, or a `url(...)`.
// Those are copied verbatim, exactly as json_format copies a string, because they
// are the three places in CSS where the file's own spacing is content.
package base

CSS_MAX_DEPTH :: 128

Css_Error :: enum {
	None,
	Unterminated, // a string or a /* comment that never closes
	Unbalanced, // a '}' with no '{'
	Too_Deep,
	Truncated, // ended inside a block
}

// Reformat `src`. `indent` is spaces per level.
//
// On failure `out` is nil and `at` is the byte offset -- the caller must not write
// a partial result over the user's file.
css_format :: proc(src: []u8, indent: int, allocator := context.allocator) -> (out: []u8, err: Css_Error, at: int) {
	buf := make([dynamic]u8, 0, len(src) + len(src) / 2 + 64, allocator)
	depth := 0
	// Parenthesis depth. It is what tells a `,` inside `rgba(1,2,3)` from a `,`
	// between two selectors, and a `:` inside `(min-width: 600px)` from a
	// pseudo-class -- the two places CSS reuses a character for both jobs.
	paren := 0
	// Has anything been written on the current output line? Cheaper and more honest
	// than looking backwards through `buf` for a '\n', and it is what stops a
	// leading newline, a doubled newline, or an indent on an empty line.
	line_open := false

	nl :: proc(buf: ^[dynamic]u8, line_open: ^bool, depth, indent: int) {
		if !line_open^ {return} // never two newlines in a row from structure alone
		append(buf, '\n')
		line_open^ = false
	}
	pad :: proc(buf: ^[dynamic]u8, line_open: ^bool, depth, indent: int) {
		if line_open^ {return}
		for _ in 0 ..< depth * indent {append(buf, ' ')}
		line_open^ = true
	}
	// Trailing spaces are never wanted: `sel {` must not become `sel  {`.
	trim_trailing :: proc(buf: ^[dynamic]u8) {
		for len(buf) > 0 && buf[len(buf) - 1] == ' ' {pop(buf)}
	}

	// Is the ':' at `i` a DECLARATION colon (`color: red`) or part of a selector
	// (`a:hover`)? Scan forward at paren depth 0: a declaration ends at ';' or the
	// block's '}', a selector ends at '{'. Whichever comes first decides.
	//
	// This is the one lookahead in the file and it is not optional. Without it
	// either every `a:hover` becomes `a: hover` (breaking the selector) or every
	// `color:red` stays jammed together. SCSS makes it sharper, because there a
	// selector and a declaration can sit in the same block.
	decl_colon :: proc(src: []u8, i: int) -> bool {
		p := i + 1
		d := 0
		for p < len(src) {
			switch src[p] {
			case '(':
				d += 1
			case ')':
				if d > 0 {d -= 1}
			case '"', '\'':
				q := src[p]
				p += 1
				for p < len(src) && src[p] != q {
					if src[p] == '\\' {p += 1}
					p += 1
				}
			case ';', '}':
				if d == 0 {return true}
			case '{':
				if d == 0 {return false}
			}
			p += 1
		}
		return true // ran out: treat as a declaration, which only affects spacing
	}

	// Was there a newline in the whitespace just consumed? ONLY COMMENTS READ IT.
	//
	// Every other token is deliberately reflowed -- that is what formatting is --
	// but a comment's placement is authorship, not layout: a licence header or a
	// section marker sits on its own line because someone put it there, while
	// `color: /* was blue */ red` is inline for the same reason. Honouring the
	// source's newline around a comment, and nowhere else, keeps both.
	saw_nl := false

	i := 0
	for i < len(src) {
		b := src[i]
		switch b {
		case ' ', '\t', '\r', '\n':
			// Collapse a run of whitespace to at most one space, and only where
			// something is already on the line -- so indentation is this
			// procedure's, never the input's.
			if b == '\n' {saw_nl = true}
			if line_open && len(buf) > 0 && buf[len(buf) - 1] != ' ' {append(&buf, ' ')}
			i += 1
			continue
		case '/':
			if i + 1 < len(src) && src[i + 1] == '*' {
				// A block comment, verbatim. It may span lines and its own layout is
				// content -- a licence header is the obvious case.
				j := i + 2
				for j + 1 < len(src) && !(src[j] == '*' && src[j + 1] == '/') {j += 1}
				if j + 1 >= len(src) {
					delete(buf)
					return nil, .Unterminated, i
				}
				// On its own line if it was on its own line.
				if saw_nl {
					trim_trailing(&buf)
					nl(&buf, &line_open, depth, indent)
				}
				pad(&buf, &line_open, depth, indent)
				append(&buf, ..src[i:j + 2])
				i = j + 2
				// ...and it ends the line if a newline followed it, so the next rule
				// does not ride up beside a header comment.
				k := i
				for k < len(src) && (src[k] == ' ' || src[k] == '\t' || src[k] == '\r' || src[k] == '\n') {
					if src[k] == '\n' {
						nl(&buf, &line_open, depth, indent)
						break
					}
					k += 1
				}
				saw_nl = false
				continue
			}
			if i + 1 < len(src) && src[i + 1] == '/' {
				// SCSS line comment, to the end of the line, verbatim.
				j := i
				for j < len(src) && src[j] != '\n' {j += 1}
				if saw_nl {
					trim_trailing(&buf)
					nl(&buf, &line_open, depth, indent)
				}
				pad(&buf, &line_open, depth, indent)
				append(&buf, ..src[i:j])
				trim_trailing(&buf)
				nl(&buf, &line_open, depth, indent)
				i = j
				saw_nl = false
				continue
			}
			pad(&buf, &line_open, depth, indent)
			append(&buf, b)
			i += 1
		case '"', '\'':
			// A string, verbatim -- content, not layout.
			q := b
			j := i + 1
			for j < len(src) && src[j] != q {
				if src[j] == '\\' {j += 1}
				j += 1
			}
			if j >= len(src) {
				delete(buf)
				return nil, .Unterminated, i
			}
			pad(&buf, &line_open, depth, indent)
			append(&buf, ..src[i:j + 1])
			i = j + 1
		case '{':
			if depth >= CSS_MAX_DEPTH {
				delete(buf)
				return nil, .Too_Deep, i
			}
			trim_trailing(&buf)
			pad(&buf, &line_open, depth, indent)
			append(&buf, ..transmute([]u8)string(" {"))
			depth += 1
			nl(&buf, &line_open, depth, indent)
			i += 1
		case '}':
			if depth == 0 {
				delete(buf)
				return nil, .Unbalanced, i
			}
			depth -= 1
			trim_trailing(&buf)
			nl(&buf, &line_open, depth, indent)
			pad(&buf, &line_open, depth, indent)
			append(&buf, '}')
			nl(&buf, &line_open, depth, indent)
			// A blank line between top-level rules, and only there: inside a block
			// it would separate every nested rule from its siblings and undo the
			// grouping the indentation just created.
			if depth == 0 {append(&buf, '\n')}
			i += 1
		case ';':
			trim_trailing(&buf)
			pad(&buf, &line_open, depth, indent)
			append(&buf, ';')
			nl(&buf, &line_open, depth, indent)
			i += 1
		case ':':
			pad(&buf, &line_open, depth, indent)
			append(&buf, ':')
			// A space after a declaration colon, none after a pseudo-class one.
			// Inside parens it is always a value (`(min-width: 600px)`).
			if paren > 0 || decl_colon(src, i) {append(&buf, ' ')}
			i += 1
		case ',':
			trim_trailing(&buf)
			pad(&buf, &line_open, depth, indent)
			append(&buf, ',')
			if paren > 0 {
				append(&buf, ' ') // inside a value: `rgba(0, 0, 0, .5)`
			} else {
				nl(&buf, &line_open, depth, indent) // a selector list: one per line
			}
			i += 1
		case '(':
			paren += 1
			pad(&buf, &line_open, depth, indent)
			append(&buf, b)
			i += 1
		case ')':
			if paren > 0 {paren -= 1}
			trim_trailing(&buf)
			pad(&buf, &line_open, depth, indent)
			append(&buf, b)
			i += 1
		case:
			pad(&buf, &line_open, depth, indent)
			append(&buf, b)
			i += 1
		}
		// Any real token consumes the pending newline: only a comment reads it, and
		// only the one directly after the whitespace that carried it.
		saw_nl = false
	}
	if depth != 0 {
		delete(buf)
		return nil, .Truncated, len(src)
	}
	trim_trailing(&buf)
	// Exactly one trailing newline: the blank line after the last top-level rule
	// is trimmed back rather than left as a gap at the end of the file.
	for len(buf) > 0 && buf[len(buf) - 1] == '\n' {pop(&buf)}
	if len(buf) == 0 {
		delete(buf)
		return nil, .Truncated, 0 // nothing but whitespace: no file to write
	}
	append(&buf, '\n')
	return buf[:], .None, 0
}

css_error_text :: proc(e: Css_Error) -> string {
	switch e {
	case .None:
		return ""
	case .Unterminated:
		return "unterminated string or comment"
	case .Unbalanced:
		return "unbalanced brace"
	case .Too_Deep:
		return "nested too deeply"
	case .Truncated:
		return "incomplete CSS"
	}
	return "invalid CSS"
}
