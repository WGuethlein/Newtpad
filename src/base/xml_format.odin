// Layer: base — reformatting minified XML into readable XML.
//
// THIS ONE IS DIFFERENT FROM THE OTHER TWO, and the difference is the whole
// design. json_format and css_format can insert whitespace anywhere, because
// whitespace is never significant in either language. **In XML it can be**:
// `<name>Ada Lovelace</name>` and a re-indented version of it are not the same
// document, and no attribute in the file has to say so.
//
// So the rule here is narrower and it is the only one that cannot corrupt content:
//
//   * an element whose content is ONLY other elements, comments and whitespace is
//     laid out -- each child on its own line, indented;
//   * an element containing ANY non-whitespace text is copied BYTE FOR BYTE, from
//     its `<` to the `>` of its closing tag, and nothing inside it is touched.
//
// That second rule covers mixed content (`<p>Hello <b>world</b>!</p>`) as a whole
// subtree rather than trying to decide which of its spaces matter, because that
// decision cannot be made from the bytes.
//
// The alternative -- reflow everything and honour `xml:space="preserve"` -- was
// considered and rejected with Wyatt: almost no real document sets that attribute,
// so it amounts to rewriting significant whitespace in most files and calling it
// formatting. A hardcoded list of "text-ish" element names (pre, textarea) works
// for HTML and guesses wrong on every other vocabulary, where the elements that
// matter have names nobody here has heard of.
//
// The cost is honest and worth stating: a minified document that is mostly text
// comes back barely changed. A minified document that is mostly STRUCTURE -- which
// is what people are staring at when they ask for this -- becomes readable.
package base

XML_MAX_DEPTH :: 256

Xml_Error :: enum {
	None,
	Unterminated, // a tag, comment or CDATA that never closes
	Unbalanced, // a close tag that does not match the open one
	Too_Deep,
	Truncated, // ended with elements still open
	Empty,
}

// One token of XML, as far as this formatter cares.
@(private = "file")
Xml_Kind :: enum {
	Open, // <a ...>
	Close, // </a>
	Self, // <a ... />
	Decl, // <?xml ...?>  <!DOCTYPE ...>
	Comment, // <!-- ... -->
	Cdata, // <![CDATA[ ... ]]>
	Text,
}

// The token starting at `i`, or ok=false if it is unterminated. `end` is one past
// it. `name` is the element name for Open/Close/Self and empty otherwise.
@(private = "file")
xml_token :: proc(src: []u8, i: int) -> (kind: Xml_Kind, end: int, name: string, ok: bool) {
	if i >= len(src) {return .Text, i, "", false}
	if src[i] != '<' {
		j := i
		for j < len(src) && src[j] != '<' {j += 1}
		return .Text, j, "", true
	}
	// <!-- comment -->
	if has_at(src, i, "<!--") {
		j := i + 4
		for j + 2 < len(src) && !(src[j] == '-' && src[j + 1] == '-' && src[j + 2] == '>') {j += 1}
		if j + 2 >= len(src) {return .Comment, i, "", false}
		return .Comment, j + 3, "", true
	}
	// <![CDATA[ ... ]]>  -- its contents are text by definition and never touched.
	if has_at(src, i, "<![CDATA[") {
		j := i + 9
		for j + 2 < len(src) && !(src[j] == ']' && src[j + 1] == ']' && src[j + 2] == '>') {j += 1}
		if j + 2 >= len(src) {return .Cdata, i, "", false}
		return .Cdata, j + 3, "", true
	}
	if i + 1 < len(src) && (src[i + 1] == '?' || src[i + 1] == '!') {
		j := i + 2
		for j < len(src) && src[j] != '>' {j += 1}
		if j >= len(src) {return .Decl, i, "", false}
		return .Decl, j + 1, "", true
	}
	closing := i + 1 < len(src) && src[i + 1] == '/'
	// Scan to the '>', skipping quoted attribute values -- an attribute may
	// contain a '>' and a tag that stopped at it would cut the element in half.
	j := i + 1
	for j < len(src) && src[j] != '>' {
		if src[j] == '"' || src[j] == '\'' {
			q := src[j]
			j += 1
			for j < len(src) && src[j] != q {j += 1}
		}
		j += 1
	}
	if j >= len(src) {return .Open, i, "", false}
	self := j > i && src[j - 1] == '/'
	ns := i + 2 if closing else i + 1
	ne := ns
	for ne < len(src) && ne < j && !is_xml_name_end(src[ne]) {ne += 1}
	nm := string(src[ns:ne])
	if closing {return .Close, j + 1, nm, true}
	if self {return .Self, j + 1, nm, true}
	return .Open, j + 1, nm, true
}

@(private = "file")
has_at :: proc(src: []u8, i: int, s: string) -> bool {
	if i + len(s) > len(src) {return false}
	return string(src[i:i + len(s)]) == s
}

@(private = "file")
is_xml_name_end :: proc(b: u8) -> bool {
	return b == ' ' || b == '\t' || b == '\r' || b == '\n' || b == '>' || b == '/'
}

@(private = "file")
is_ws_only :: proc(s: string) -> bool {
	for i in 0 ..< len(s) {
		switch s[i] {
		case ' ', '\t', '\r', '\n':
		case:
			return false
		}
	}
	return true
}

// Does the element opening at `i` have non-whitespace text in its OWN content --
// the level directly inside it -- and where does it end?
//
// IMMEDIATE LEVEL, not the whole subtree, and the distinction is the difference
// between a safe rule and a useless one. Laying an element out inserts whitespace
// **into that element's content and nowhere else**. So the only text that can be
// corrupted by laying out `<a>` is text that is directly inside `<a>`; text three
// levels down is inside some descendant, and that descendant is protected by this
// same question being asked about it in turn.
//
// A first version asked about the whole subtree and was over-conservative to the
// point of doing nothing: one `<name>Ada</name>` anywhere made the entire document
// verbatim, which is every real document.
//
// `<p>Hello <b>x</b>!</p>` is the case that matters: the text and the `<b>` are
// siblings, so laying the `<p>` out would move "Hello" onto its own line and
// change what the document says. That is caught here, at `<p>`, and the whole
// subtree goes out verbatim.
// `has_text` is really "must go out verbatim". In HTML mode it also becomes true
// when an element directly inside this one is INLINE, because laying this element
// out would insert a line break beside that child and HTML renders it as a space.
// See html_format.odin for why the two cases share one answer.
@(private = "file")
xml_elem_extent :: proc(src: []u8, i: int, html := false) -> (end: int, has_text: bool, err: Xml_Error) {
	kind, e, name, tok_ok := xml_token(src, i)
	if !tok_ok {return i, false, .Unterminated}
	if kind != .Open {return e, false, .None}
	// An element that is ITSELF inline (or is `pre`/`textarea`) is verbatim
	// whatever it contains -- the break would land beside it, or inside something
	// whose own whitespace is significant.
	if html && html_is_inline(name) {has_text = true}
	depth := 1
	p := e
	for p < len(src) {
		k, ne, nm, k_ok := xml_token(src, p)
		if !k_ok {return p, has_text, .Unterminated}
		#partial switch k {
		case .Open:
			if html && depth == 1 && html_is_inline(nm) {has_text = true}
			depth += 1
		case .Self:
			// A self-closing inline child (`<br/>`, `<img/>`) is just as much a
			// break site as a paired one; the .Open case above never sees it.
			if html && depth == 1 && html_is_inline(nm) {has_text = true}
		case .Close:
			depth -= 1
			if depth == 0 {
				if nm != name {return ne, has_text, .Unbalanced}
				return ne, has_text, .None
			}
		case .Text:
			if depth == 1 && !is_ws_only(string(src[p:ne])) {has_text = true}
		case .Cdata:
			if depth == 1 {has_text = true} // CDATA is text by definition
		}
		p = ne
	}
	return p, has_text, .Truncated // ran out with the element still open
}

xml_format :: proc(src: []u8, indent: int, allocator := context.allocator) -> (out: []u8, err: Xml_Error, at: int) {
	return xml_format_impl(src, indent, false, allocator)
}

// The shared body. `html` adds the inline rule and changes nothing else -- one
// formatter with one extra predicate, rather than a second copy of the tokeniser
// that would drift from this one.
xml_format_impl :: proc(src: []u8, indent: int, html: bool, allocator := context.allocator) -> (out: []u8, err: Xml_Error, at: int) {
	buf := make([dynamic]u8, 0, len(src) + len(src) / 3 + 64, allocator)
	depth := 0
	wrote := false

	nl_pad :: proc(buf: ^[dynamic]u8, wrote: ^bool, depth, indent: int) {
		if wrote^ {append(buf, '\n')}
		for _ in 0 ..< depth * indent {append(buf, ' ')}
		wrote^ = true
	}

	i := 0
	for i < len(src) {
		kind, e, name, ok := xml_token(src, i)
		if !ok {
			delete(buf)
			return nil, .Unterminated, i
		}
		switch kind {
		case .Text:
			// Text between elements at a laid-out level is whitespace by
			// construction -- an element with real text was copied whole by the
			// .Open branch and never reaches here -- so it is dropped, which is
			// exactly the indentation this procedure is replacing.
			i = e
			continue
		case .Decl, .Comment, .Cdata:
			nl_pad(&buf, &wrote, depth, indent)
			append(&buf, ..src[i:e])
			i = e
			continue
		case .Self:
			nl_pad(&buf, &wrote, depth, indent)
			append(&buf, ..src[i:e])
			i = e
			continue
		case .Close:
			if depth == 0 {
				delete(buf)
				return nil, .Unbalanced, i
			}
			depth -= 1
			nl_pad(&buf, &wrote, depth, indent)
			append(&buf, ..src[i:e])
			i = e
			continue
		case .Open:
			if depth >= XML_MAX_DEPTH {
				delete(buf)
				return nil, .Too_Deep, i
			}
			ee, has_text, eerr := xml_elem_extent(src, i, html)
			if eerr != .None {
				// The reason comes FROM the scan rather than being guessed from how
				// far it got -- an unclosed element and a mismatched close tag are
				// different mistakes and the reader is told which.
				delete(buf)
				return nil, eerr, i
			}
			if has_text {
				// VERBATIM, the whole subtree. This is the rule the file exists for.
				nl_pad(&buf, &wrote, depth, indent)
				append(&buf, ..src[i:ee])
				i = ee
				continue
			}
			nl_pad(&buf, &wrote, depth, indent)
			append(&buf, ..src[i:e])
			depth += 1
			i = e
			continue
		}
	}
	if depth != 0 {
		delete(buf)
		return nil, .Truncated, len(src)
	}
	if len(buf) == 0 {
		delete(buf)
		return nil, .Empty, 0
	}
	append(&buf, '\n')
	return buf[:], .None, 0
}

xml_error_text :: proc(e: Xml_Error) -> string {
	switch e {
	case .None:
		return ""
	case .Unterminated:
		return "unterminated tag or comment"
	case .Unbalanced:
		return "mismatched closing tag"
	case .Too_Deep:
		return "nested too deeply"
	case .Truncated:
		return "incomplete XML"
	case .Empty:
		return "nothing to format"
	}
	return "invalid XML"
}
