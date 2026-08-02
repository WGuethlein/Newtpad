package base

import "core:testing"

@(private = "file")
xml_ok :: proc(t: ^testing.T, src: string, indent: int, want: string, label: string) {
	out, err, at := xml_format(transmute([]u8)src, indent, context.temp_allocator)
	if err != .None {
		testing.expectf(t, false, "%s: refused with %v at %d", label, err, at)
		return
	}
	testing.expectf(t, string(out) == want, "%s:\n got %q\nwant %q", label, string(out), want)
}

@(test)
test_xml_format_structure :: proc(t: ^testing.T) {
	xml_ok(t, `<a><b/></a>`, 2, "<a>\n  <b/>\n</a>\n", "a structural element is laid out")
	xml_ok(t, `<a><b><c/></b></a>`, 2, "<a>\n  <b>\n    <c/>\n  </b>\n</a>\n", "nesting indents")
	xml_ok(t, `<a><b/><c/></a>`, 4, "<a>\n    <b/>\n    <c/>\n</a>\n", "four-space indent")
	xml_ok(t, `<?xml version="1.0"?><a><b/></a>`, 2, "<?xml version=\"1.0\"?>\n<a>\n  <b/>\n</a>\n", "a declaration gets its own line")
	xml_ok(t, `<a><!-- note --><b/></a>`, 2, "<a>\n  <!-- note -->\n  <b/>\n</a>\n", "a comment is laid out like a child")
}

@(test)
test_xml_format_never_touches_text :: proc(t: ^testing.T) {
	// THE RULE THIS FILE EXISTS FOR. Re-indenting text changes what the document
	// says, so an element containing any is copied byte for byte.
	xml_ok(t, `<a><n>Ada Lovelace</n></a>`, 2, "<a>\n  <n>Ada Lovelace</n>\n</a>\n", "a text element stays on one line")
	// Mixed content, the case that cannot be decided from the bytes: the whole
	// subtree is verbatim, spaces and all.
	xml_ok(t, `<a><p>Hello <b>world</b>!</p></a>`, 2, "<a>\n  <p>Hello <b>world</b>!</p>\n</a>\n", "mixed content is verbatim, as a whole subtree")
	// Text DEEPER DOWN does not freeze its ancestors, and it must not: laying out
	// `<a>` inserts whitespace into `<a>`'s content only, and `<c>`'s text is
	// inside `<c>`, which is protected by the same question asked about it. An
	// earlier version answered for the whole subtree and one `<name>Ada</name>`
	// anywhere made the whole document verbatim -- safe and useless.
	xml_ok(t, `<a><b><c>text</c></b></a>`, 2, "<a>\n  <b>\n    <c>text</c>\n  </b>\n</a>\n", "text deep down does not freeze its ancestors")
	// CDATA is text by definition.
	xml_ok(t, `<a><b><![CDATA[ raw  stuff ]]></b></a>`, 2, "<a>\n  <b><![CDATA[ raw  stuff ]]></b>\n</a>\n", "CDATA is text")
	// A '>' inside an attribute must not cut the tag in half.
	xml_ok(t, `<a><b c="x>y"/></a>`, 2, "<a>\n  <b c=\"x>y\"/>\n</a>\n", "a '>' inside an attribute value is not the tag's end")
}

@(test)
test_xml_format_idempotent :: proc(t: ^testing.T) {
	// Pressing it twice is the same as once -- including for the verbatim
	// branch, which is where a naive implementation drifts (the laid-out newlines
	// become "text" on the second pass and freeze the element).
	src := `<r><a><b/></a><n>Ada</n><p>Hi <b>x</b>!</p></r>`
	once, e1, _ := xml_format(transmute([]u8)src, 2, context.temp_allocator)
	testing.expect(t, e1 == .None)
	twice, e2, _ := xml_format(once, 2, context.temp_allocator)
	testing.expect(t, e2 == .None)
	testing.expectf(t, string(once) == string(twice), "idempotent:\n once %q\ntwice %q", string(once), string(twice))
}

@(test)
test_xml_format_refuses :: proc(t: ^testing.T) {
	bad :: proc(t: ^testing.T, src: string, want: Xml_Error, label: string) {
		out, err, _ := xml_format(transmute([]u8)src, 2, context.temp_allocator)
		testing.expectf(t, err == want, "%s: got %v, want %v", label, err, want)
		testing.expectf(t, out == nil, "%s: produced no partial output", label)
	}
	bad(t, `<a><b/>`, .Truncated, "an unclosed element")
	bad(t, `<a></b>`, .Unbalanced, "a mismatched closing tag")
	bad(t, `</a>`, .Unbalanced, "a closing tag with nothing open")
	bad(t, `<a`, .Unterminated, "an unterminated tag")
	bad(t, `<!-- oops`, .Unterminated, "an unterminated comment")
	bad(t, ``, .Empty, "empty input, which must not rewrite the file to nothing")
}
