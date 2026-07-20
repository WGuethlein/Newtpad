package base

import "core:testing"

@(test)
test_detect_encoding :: proc(t: ^testing.T) {
	utf8_bom := []u8{0xEF, 0xBB, 0xBF, 'h', 'i'}
	e, n := detect_encoding(utf8_bom)
	testing.expect_value(t, e, Encoding.UTF8)
	testing.expect_value(t, n, 3)

	le := []u8{0xFF, 0xFE, 'h', 0}
	e, n = detect_encoding(le)
	testing.expect_value(t, e, Encoding.UTF16LE)
	testing.expect_value(t, n, 2)

	be := []u8{0xFE, 0xFF, 0, 'h'}
	e, n = detect_encoding(be)
	testing.expect_value(t, e, Encoding.UTF16BE)
	testing.expect_value(t, n, 2)

	plain := []u8{'h', 'e', 'l', 'l', 'o'}
	e, n = detect_encoding(plain)
	testing.expect_value(t, e, Encoding.UTF8)
	testing.expect_value(t, n, 0)
}

@(test)
test_decode_utf16le :: proc(t: ^testing.T) {
	// "Aß" in UTF-16LE with BOM: A=0x0041, ß=0x00DF, plus an emoji surrogate pair
	// U+1F600 = D83D DE00
	data := []u8{0xFF, 0xFE, 0x41, 0x00, 0xDF, 0x00, 0x3D, 0xD8, 0x00, 0xDE}
	enc, bom := detect_encoding(data)
	out, alloc := decode_to_utf8(data, enc, bom)
	defer if alloc {delete(out)}
	testing.expect(t, alloc)
	testing.expect_value(t, string(out), "Aß😀")
}

@(test)
test_decode_utf8_nocopy :: proc(t: ^testing.T) {
	data := []u8{0xEF, 0xBB, 0xBF, 'h', 'i'}
	enc, bom := detect_encoding(data)
	out, alloc := decode_to_utf8(data, enc, bom)
	testing.expect(t, !alloc)
	testing.expect_value(t, string(out), "hi")
}

@(test)
test_encode_roundtrip :: proc(t: ^testing.T) {
	orig := "Aß😀 hi\nx" // ASCII + 2-byte + 4-byte (surrogate) + newline
	utf8_bytes := transmute([]u8)orig

	// UTF-16LE round-trip
	le := encode_from_utf8(utf8_bytes, .UTF16LE, true)
	defer delete(le)
	testing.expect(t, le[0] == 0xFF && le[1] == 0xFE) // BOM
	enc, bom := detect_encoding(le)
	testing.expect_value(t, enc, Encoding.UTF16LE)
	back, alloc := decode_to_utf8(le, enc, bom)
	defer if alloc {delete(back)}
	testing.expect_value(t, string(back), orig)

	// UTF-16BE round-trip
	be := encode_from_utf8(utf8_bytes, .UTF16BE, true)
	defer delete(be)
	testing.expect(t, be[0] == 0xFE && be[1] == 0xFF)
	e2, b2 := detect_encoding(be)
	back2, a2 := decode_to_utf8(be, e2, b2)
	defer if a2 {delete(back2)}
	testing.expect_value(t, string(back2), orig)

	// UTF-8 with BOM
	u8b := encode_from_utf8(utf8_bytes, .UTF8, true)
	defer delete(u8b)
	testing.expect(t, u8b[0] == 0xEF && u8b[1] == 0xBB && u8b[2] == 0xBF)
	testing.expect_value(t, string(u8b[3:]), orig)
}

@(test)
test_line_nav :: proc(t: ^testing.T) {
	b := transmute([]u8)string("alpha\nbeta\ngamma")
	testing.expect_value(t, line_end(b, 0), 5) // '\n' after alpha
	testing.expect_value(t, next_line_start(b, 0), 6) // start of beta
	testing.expect_value(t, next_line_start(b, 6), 11) // start of gamma
	testing.expect_value(t, prev_line_start(b, 11), 6) // back to beta
	testing.expect_value(t, prev_line_start(b, 6), 0) // back to alpha
	testing.expect_value(t, prev_line_start(b, 0), 0) // clamp at top
	testing.expect_value(t, line_end(b, 11), 16) // last line ends at len
}

// Windows-1252 cannot hold an em-dash, a curly quote or an emoji. The encoder
// substituted '?' for each and said nothing, so pasting modern text into a
// legacy file destroyed it on save while the app reported success. The count is
// what lets the save path ask the user first.
@(test)
test_encode_lossy_count :: proc(t: ^testing.T) {
	// Plain ASCII is representable everywhere.
	testing.expect_value(t, encode_lossy_count(transmute([]u8)string("hello"), Encoding.CP1252), 0)

	// These have CP1252 slots even though they are non-ASCII.
	testing.expect_value(t, encode_lossy_count(transmute([]u8)string("café — “quoted”"), Encoding.CP1252), 0)

	// These do not.
	testing.expect_value(t, encode_lossy_count(transmute([]u8)string("\U0001F600"), Encoding.CP1252), 1)
	testing.expect_value(t, encode_lossy_count(transmute([]u8)string("中文"), Encoding.CP1252), 2)
	testing.expect_value(t, encode_lossy_count(transmute([]u8)string("a\U0001F600b中c"), Encoding.CP1252), 2)

	// Unicode encodings can represent everything, so nothing is ever lost.
	for enc in ([]Encoding{.UTF8, .UTF16LE, .UTF16BE}) {
		testing.expect_value(t, encode_lossy_count(transmute([]u8)string("\U0001F600中"), enc), 0)
	}

	// And the loss the count predicts is the loss that actually happens.
	lossy := transmute([]u8)string("a\U0001F600b")
	out := encode_from_utf8(lossy, .CP1252, false, context.temp_allocator)
	testing.expect_value(t, string(out), "a?b")
}
