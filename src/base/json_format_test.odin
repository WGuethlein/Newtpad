package base

import "core:testing"

@(private = "file")
fmt_ok :: proc(t: ^testing.T, src: string, indent: int, want: string, label: string) {
	out, err, at := json_format(transmute([]u8)src, indent, context.temp_allocator)
	if err != .None {
		testing.expectf(t, false, "%s: refused with %v at %d", label, err, at)
		return
	}
	testing.expectf(t, string(out) == want, "%s:\n got %q\nwant %q", label, string(out), want)
}

@(private = "file")
fmt_bad :: proc(t: ^testing.T, src: string, want: Json_Error, label: string) {
	out, err, _ := json_format(transmute([]u8)src, 2, context.temp_allocator)
	testing.expectf(t, err == want, "%s: got %v, want %v", label, err, want)
	// The output must be NIL on every failure. A partial rewrite is the one
	// outcome worse than refusing, because the caller writes it over the file.
	testing.expectf(t, out == nil, "%s: refused, and produced no partial output", label)
}

@(test)
test_json_format_shapes :: proc(t: ^testing.T) {
	fmt_ok(t, `{"a":1}`, 2, "{\n  \"a\": 1\n}\n", "an object")
	fmt_ok(t, `[1,2]`, 2, "[\n  1,\n  2\n]\n", "an array")
	fmt_ok(t, `{"a":{"b":[1,{"c":null}]}}`, 2, "{\n  \"a\": {\n    \"b\": [\n      1,\n      {\n        \"c\": null\n      }\n    ]\n  }\n}\n", "nesting")

	// Empty containers stay on one line -- `{}` over three lines is noise.
	fmt_ok(t, `{"a":{},"b":[]}`, 2, "{\n  \"a\": {},\n  \"b\": []\n}\n", "empty containers stay compact")
	fmt_ok(t, `{}`, 2, "{}\n", "an empty object on its own")

	// A bare top-level value is valid JSON and must survive.
	fmt_ok(t, `  42  `, 2, "42\n", "a bare number")
	fmt_ok(t, `"hi"`, 2, "\"hi\"\n", "a bare string")
	fmt_ok(t, `true`, 2, "true\n", "a bare keyword")
}

@(test)
test_json_format_indent_follows_setting :: proc(t: ^testing.T) {
	fmt_ok(t, `{"a":1}`, 4, "{\n    \"a\": 1\n}\n", "four spaces")
	// Zero is a legal tab width and must not produce a hang or a stray space.
	fmt_ok(t, `{"a":1}`, 0, "{\n\"a\": 1\n}\n", "zero indent still emits the newlines")
}

@(test)
test_json_format_preserves_what_it_must :: proc(t: ^testing.T) {
	// KEY ORDER. The reason this is a rewrite and not a parse-to-map: a map has
	// no insertion order, so re-emitting from one silently reorders the file.
	fmt_ok(
		t,
		`{"z":1,"a":2,"m":3}`,
		2,
		"{\n  \"z\": 1,\n  \"a\": 2,\n  \"m\": 3\n}\n",
		"key order is the file's, not sorted",
	)
	// NUMBERS ARE BYTES. Round-tripping through a float turns 1.50 into 1.5 and
	// can lose precision on a big integer -- neither is the formatter's business.
	fmt_ok(t, `[1.50,1e3,-0.0,12345678901234567890]`, 2, "[\n  1.50,\n  1e3,\n  -0.0,\n  12345678901234567890\n]\n", "numbers survive as written")
	// STRINGS ARE BYTES. Re-encoding means deciding about \u escapes and lone
	// surrogates, and every answer there can change what the file means.
	fmt_ok(t, `{"a":"x\"y\\z\u00e9"}`, 2, "{\n  \"a\": \"x\\\"y\\\\z\\u00e9\"\n}\n", "escapes survive verbatim")
	// A brace or a colon INSIDE a string is text, not structure. This is the case
	// that fails the moment the formatter stops sharing the lexer's scanner.
	fmt_ok(t, `{"a":"{\"b\":1}"}`, 2, "{\n  \"a\": \"{\\\"b\\\":1}\"\n}\n", "structure inside a string is text")
}

@(test)
test_json_format_already_formatted :: proc(t: ^testing.T) {
	// Formatting twice must be the same as formatting once, or the command is not
	// safe to press again -- and pressing it again is what anyone does.
	src := `{"a":[1,2],"b":{"c":"d"}}`
	once, err1, _ := json_format(transmute([]u8)src, 2, context.temp_allocator)
	testing.expect(t, err1 == .None)
	twice, err2, _ := json_format(once, 2, context.temp_allocator)
	testing.expect(t, err2 == .None)
	testing.expectf(t, string(once) == string(twice), "idempotent:\n once %q\ntwice %q", string(once), string(twice))
}

@(test)
test_json_format_refuses_invalid :: proc(t: ^testing.T) {
	fmt_bad(t, `{"a":1`, .Truncated, "an unclosed object")
	fmt_bad(t, `{"a":"unterminated}`, .Unterminated_String, "an unterminated string")
	fmt_bad(t, `{"a":1,}`, .Unexpected_Byte, "a trailing comma")
	fmt_bad(t, `{"a":1]`, .Unbalanced, "the wrong closer")
	// A closer after the top-level value has already closed is reported as
	// trailing content, not as an imbalance -- both are true and that one says
	// more: the value ended, and there is something after it.
	fmt_bad(t, `{"a":1}}`, .Trailing_Content, "one closer too many, after the value ended")
	fmt_bad(t, `]`, .Unbalanced, "a closer with no opener at all")
	fmt_bad(t, `{"a":1} {"b":2}`, .Trailing_Content, "two top-level values")
	fmt_bad(t, `{"a":tru}`, .Unexpected_Byte, "a near-miss keyword the LEXER would happily colour")
	fmt_bad(t, `{"a":,}`, .Unexpected_Byte, "a missing value")
	fmt_bad(t, ``, .Truncated, "empty input, which must not rewrite the file to nothing")
	fmt_bad(t, "   \n\t ", .Truncated, "whitespace only")
	fmt_bad(t, `{"a" 1}`, .Unexpected_Byte, "a missing colon")
}

@(test)
test_json_format_error_offsets_point_at_the_problem :: proc(t: ^testing.T) {
	// The offset is what lets the caller put the caret on the fault instead of
	// saying "invalid" and leaving the user to find it.
	src := `{"a":1,"b":}`
	_, err, at := json_format(transmute([]u8)src, 2, context.temp_allocator)
	testing.expect_value(t, err, Json_Error.Unexpected_Byte)
	testing.expectf(t, at == 11, "the offset names the '}' that has no value before it (%d, want 11)", at)

	src2 := `[1,2,3`
	_, err2, at2 := json_format(transmute([]u8)src2, 2, context.temp_allocator)
	testing.expect_value(t, err2, Json_Error.Truncated)
	testing.expectf(t, at2 == len(src2), "a truncated file points at its end (%d, want %d)", at2, len(src2))
}

@(test)
test_json_format_depth_is_bounded :: proc(t: ^testing.T) {
	// Deep but legal: JSON_MAX_DEPTH levels must format.
	ok_src := make([dynamic]u8, 0, JSON_MAX_DEPTH * 2 + 4, context.temp_allocator)
	for _ in 0 ..< JSON_MAX_DEPTH {append(&ok_src, '[')}
	append(&ok_src, '1')
	for _ in 0 ..< JSON_MAX_DEPTH {append(&ok_src, ']')}
	_, err, _ := json_format(ok_src[:], 2, context.temp_allocator)
	testing.expectf(t, err == .None, "exactly JSON_MAX_DEPTH levels still formats (%v)", err)

	// One deeper refuses rather than recursing into a stack overflow.
	deep := make([dynamic]u8, 0, JSON_MAX_DEPTH * 2 + 8, context.temp_allocator)
	for _ in 0 ..< JSON_MAX_DEPTH + 1 {append(&deep, '[')}
	append(&deep, '1')
	for _ in 0 ..< JSON_MAX_DEPTH + 1 {append(&deep, ']')}
	_, err2, _ := json_format(deep[:], 2, context.temp_allocator)
	testing.expect_value(t, err2, Json_Error.Too_Deep)
}
