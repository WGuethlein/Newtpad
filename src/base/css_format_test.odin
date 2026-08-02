package base

import "core:testing"

@(private = "file")
css_ok :: proc(t: ^testing.T, src: string, indent: int, want: string, label: string) {
	out, err, at := css_format(transmute([]u8)src, indent, context.temp_allocator)
	if err != .None {
		testing.expectf(t, false, "%s: refused with %v at %d", label, err, at)
		return
	}
	testing.expectf(t, string(out) == want, "%s:\n got %q\nwant %q", label, string(out), want)
}

@(test)
test_css_format_basic :: proc(t: ^testing.T) {
	css_ok(t, `a{color:red}`, 2, "a {\n  color: red\n}\n", "one rule")
	css_ok(t, `a{color:red;}`, 2, "a {\n  color: red;\n}\n", "...with the semicolon kept")
	css_ok(t, `a{color:red;background:blue}`, 2, "a {\n  color: red;\n  background: blue\n}\n", "two declarations")
	// A selector list breaks one per line; a comma inside a VALUE must not.
	css_ok(t, `h1,h2{margin:0}`, 2, "h1,\nh2 {\n  margin: 0\n}\n", "a selector list is one per line")
	css_ok(t, `a{color:rgba(0,0,0,.5)}`, 2, "a {\n  color: rgba(0, 0, 0, .5)\n}\n", "a comma inside a value stays inline")
}

@(test)
test_css_format_colon_is_ambiguous :: proc(t: ^testing.T) {
	// THE case this formatter has a lookahead for. A declaration colon takes a
	// space; a pseudo-class colon must not, or the selector stops matching.
	css_ok(t, `a:hover{color:red}`, 2, "a:hover {\n  color: red\n}\n", "a pseudo-class colon takes no space")
	css_ok(t, `a::before{content:""}`, 2, "a::before {\n  content: \"\"\n}\n", "...nor a pseudo-element's two")
	css_ok(t, `li:nth-child(2n+1){color:red}`, 2, "li:nth-child(2n+1) {\n  color: red\n}\n", "...even with parens in the selector")
	// Inside parens it is always a value.
	css_ok(t, `@media(min-width:600px){a{color:red}}`, 2, "@media(min-width: 600px) {\n  a {\n    color: red\n  }\n}\n", "a colon inside a media query is a value")
}

@(test)
test_css_format_nesting_and_scss :: proc(t: ^testing.T) {
	// SCSS nesting is just more braces -- and it is where the colon lookahead
	// earns its keep, because a selector and a declaration share one block.
	css_ok(t, `.a{color:red;&:hover{color:blue}}`, 2, ".a {\n  color: red;\n  &:hover {\n    color: blue\n  }\n}\n", "SCSS nesting")
	css_ok(t, `$c:red;a{color:$c}`, 2, "$c: red;\na {\n  color: $c\n}\n", "an SCSS variable is an ordinary declaration")
}

@(test)
test_css_format_preserves_content :: proc(t: ^testing.T) {
	// Strings, comments and url() are content and must survive byte for byte --
	// the same rule json_format applies to a JSON string.
	css_ok(t, `a{content:"a;b{c}"}`, 2, "a {\n  content: \"a;b{c}\"\n}\n", "structure inside a string is text")
	css_ok(t, `a{background:url(a b.png)}`, 2, "a {\n  background: url(a b.png)\n}\n", "a url keeps its spaces")
	css_ok(t, "/* keep  me */\na{color:red}", 2, "/* keep  me */\na {\n  color: red\n}\n", "a block comment is verbatim")
	css_ok(t, "// scss note\na{color:red}", 2, "// scss note\na {\n  color: red\n}\n", "an SCSS line comment is verbatim")
}

@(test)
test_css_format_indent_and_blank_lines :: proc(t: ^testing.T) {
	css_ok(t, `a{color:red}b{color:blue}`, 4, "a {\n    color: red\n}\n\nb {\n    color: blue\n}\n", "four-space indent, blank line between top-level rules")
	// ...and no blank line between NESTED rules, which would undo the grouping
	// the indent just created.
	css_ok(t, `@media screen{a{color:red}b{color:blue}}`, 2, "@media screen {\n  a {\n    color: red\n  }\n  b {\n    color: blue\n  }\n}\n", "no blank line between nested rules")
}

@(test)
test_css_format_idempotent :: proc(t: ^testing.T) {
	// Pressing it twice must be the same as once, or the command is not safe to
	// press again -- and pressing it again is what anyone does.
	src := `h1,h2{margin:0;color:rgba(0,0,0,.5)}a:hover{color:red}`
	once, e1, _ := css_format(transmute([]u8)src, 2, context.temp_allocator)
	testing.expect(t, e1 == .None)
	twice, e2, _ := css_format(once, 2, context.temp_allocator)
	testing.expect(t, e2 == .None)
	testing.expectf(t, string(once) == string(twice), "idempotent:\n once %q\ntwice %q", string(once), string(twice))
}

@(test)
test_css_format_refuses :: proc(t: ^testing.T) {
	bad :: proc(t: ^testing.T, src: string, want: Css_Error, label: string) {
		out, err, _ := css_format(transmute([]u8)src, 2, context.temp_allocator)
		testing.expectf(t, err == want, "%s: got %v, want %v", label, err, want)
		testing.expectf(t, out == nil, "%s: produced no partial output", label)
	}
	bad(t, `a{color:red`, .Truncated, "an unclosed block")
	bad(t, `a{color:red}}`, .Unbalanced, "one brace too many")
	bad(t, `a{content:"oops}`, .Unterminated, "an unterminated string")
	bad(t, `/* oops`, .Unterminated, "an unterminated comment")
	bad(t, ``, .Truncated, "empty input, which must not rewrite the file to nothing")
	bad(t, "  \n\t", .Truncated, "whitespace only")
}
