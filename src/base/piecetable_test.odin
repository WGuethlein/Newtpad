package base

import "core:testing"

@(private = "file")
str :: proc(pt: ^Piece_Table) -> string {
	b := pt_collect(pt)
	return string(b) // leaked in test; fine
}

@(private = "file")
ins :: proc(pt: ^Piece_Table, pos: int, s: string) {pt_insert(pt, pos, transmute([]u8)s)}

@(test)
test_pt_init_read :: proc(t: ^testing.T) {
	pt := pt_init(transmute([]u8)string("hello"))
	defer pt_destroy(&pt)
	testing.expect_value(t, pt_len(&pt), 5)
	testing.expect_value(t, str(&pt), "hello")

	dst := make([]u8, 3);defer delete(dst)
	n := pt_read(&pt, 1, dst)
	testing.expect_value(t, n, 3)
	testing.expect_value(t, string(dst), "ell")
}

@(test)
test_pt_insert :: proc(t: ^testing.T) {
	pt := pt_init(transmute([]u8)string("hello"))
	defer pt_destroy(&pt)
	ins(&pt, 2, "XY") // middle
	testing.expect_value(t, str(&pt), "heXYllo")
	ins(&pt, 0, ">>") // start
	testing.expect_value(t, str(&pt), ">>heXYllo")
	ins(&pt, pt_len(&pt), "<<") // end
	testing.expect_value(t, str(&pt), ">>heXYllo<<")
	testing.expect_value(t, pt_len(&pt), 11)
}

@(test)
test_pt_insert_into_empty :: proc(t: ^testing.T) {
	pt := pt_init(nil)
	defer pt_destroy(&pt)
	testing.expect_value(t, pt_len(&pt), 0)
	ins(&pt, 0, "abc")
	ins(&pt, 3, "def")
	ins(&pt, 3, "-")
	testing.expect_value(t, str(&pt), "abc-def")
}

@(test)
test_pt_delete_within :: proc(t: ^testing.T) {
	pt := pt_init(transmute([]u8)string("hello"))
	defer pt_destroy(&pt)
	pt_delete(&pt, 1, 3) // remove "ell"
	testing.expect_value(t, str(&pt), "ho")
	testing.expect_value(t, pt_len(&pt), 2)
}

@(test)
test_pt_delete_spanning :: proc(t: ^testing.T) {
	pt := pt_init(transmute([]u8)string("abcXYZghi"))
	defer pt_destroy(&pt)
	ins(&pt, 3, "123") // "abc123XYZghi" (introduces an add piece in the middle)
	testing.expect_value(t, str(&pt), "abc123XYZghi")
	pt_delete(&pt, 2, 6) // remove "c123XY" -> "abZghi"
	testing.expect_value(t, str(&pt), "abZghi")
	testing.expect_value(t, pt_len(&pt), 6)
}

@(test)
test_pt_delete_whole_and_edges :: proc(t: ^testing.T) {
	pt := pt_init(transmute([]u8)string("hello"))
	defer pt_destroy(&pt)
	pt_delete(&pt, 0, 5) // delete everything
	testing.expect_value(t, pt_len(&pt), 0)
	testing.expect_value(t, str(&pt), "")
	ins(&pt, 0, "world")
	pt_delete(&pt, 4, 10) // over-delete past end clamps
	testing.expect_value(t, str(&pt), "worl")
	pt_delete(&pt, 0, 1) // delete at start
	testing.expect_value(t, str(&pt), "orl")
}

@(test)
test_pt_line_nav :: proc(t: ^testing.T) {
	pt := pt_init(transmute([]u8)string("alpha\nbeta\ngamma"))
	defer pt_destroy(&pt)
	testing.expect_value(t, pt_line_end(&pt, 0), 5) // '\n' after alpha
	testing.expect_value(t, pt_next_line_start(&pt, 0), 6) // start of beta
	testing.expect_value(t, pt_line_start(&pt, 8), 6) // pos in beta -> beta start
	testing.expect_value(t, pt_prev_line_start(&pt, 6), 0) // above beta -> alpha
	testing.expect_value(t, pt_prev_line_start(&pt, 11), 6) // above gamma -> beta
	testing.expect_value(t, pt_line_end(&pt, 11), 16) // last line ends at length

	// nav still correct after an edit that fragments pieces
	ins(&pt, 6, "XYZ\n") // "alpha\nXYZ\nbeta\ngamma"
	testing.expect_value(t, str(&pt), "alpha\nXYZ\nbeta\ngamma")
	testing.expect_value(t, pt_next_line_start(&pt, 0), 6) // beta shifted; next after alpha is XYZ line
	testing.expect_value(t, pt_line_start(&pt, 7), 6) // inside XYZ line
}

// The add arena must survive being written past a chunk boundary: pieces from
// before the boundary still have to read back correctly.
@(test)
test_pt_add_chunk_growth :: proc(t: ^testing.T) {
	pt := pt_init(transmute([]u8)string("|"))
	defer pt_destroy(&pt)
	// Well past ADD_CHUNK_MIN, so several chunks get allocated.
	for i in 0 ..< 4000 {ins(&pt, pt_len(&pt), "abcdefghij")}
	testing.expect_value(t, pt_len(&pt), 1 + 4000 * 10)
	testing.expect(t, len(pt.add_chunks) > 1, "expected multiple add chunks")

	// A read spanning the very first add bytes and the latest ones.
	dst := make([]u8, 10);defer delete(dst)
	pt_read(&pt, 1, dst)
	testing.expect_value(t, string(dst), "abcdefghij")
	pt_read(&pt, pt_len(&pt) - 10, dst)
	testing.expect_value(t, string(dst), "abcdefghij")

	// An insert larger than a chunk gets its own chunk and stays contiguous.
	big := make([]u8, ADD_CHUNK_MAX + 777);defer delete(big)
	for i in 0 ..< len(big) {big[i] = u8('A' + i % 26)}
	pt_insert(&pt, 0, big)
	got := make([]u8, len(big));defer delete(got)
	pt_read(&pt, 0, got)
	testing.expect(t, string(got) == string(big), "oversized insert read back wrong")
}

// A view is the whole reason the add arena is chunked: a worker holds one while
// the main thread keeps editing, and it must keep reading the buffer as it was.
@(test)
test_pt_view_survives_edits :: proc(t: ^testing.T) {
	pt := pt_init(transmute([]u8)string("hello"))
	defer pt_destroy(&pt)
	ins(&pt, 5, " world")
	before := str(&pt)

	v := pt_view(&pt)
	defer pt_view_destroy(&v)
	testing.expect_value(t, v.length, pt_len(&pt))

	// Edit hard enough to allocate new chunks and to free tree nodes the view
	// also referenced. With a [dynamic]u8 arena this is where the view's bytes
	// got reallocated out from under it.
	for i in 0 ..< 5000 {ins(&pt, pt_len(&pt), "0123456789")}
	pt_delete(&pt, 0, 5)

	// The view still reads the pre-edit buffer.
	got := make([]u8, v.length);defer delete(got)
	n := pt_read(&v, 0, got)
	testing.expect_value(t, n, len(before))
	testing.expect_value(t, string(got), before)
}

// A Windows-1252 file must be recognised as such, not passed through as UTF-8.
// Read as UTF-8 its high bytes are invalid, so the text renders as garbage and —
// worse — saving writes that garbage back, corrupting the user's file.
@(test)
test_encoding_cp1252 :: proc(t: ^testing.T) {
	// "caf<e9> na<efve" — 0xE9/0xEF are valid CP1252 but invalid UTF-8.
	raw := []u8{'c', 'a', 'f', 0xE9, ' ', 'n', 'a', 0xEF, 'v', 'e'}
	enc, bom := detect_encoding(raw)
	testing.expect_value(t, enc, Encoding.CP1252)
	testing.expect_value(t, bom, 0)

	out, alloc := decode_to_utf8(raw, enc, bom)
	defer if alloc {delete(out)}
	testing.expect(t, alloc, "CP1252 must be transcoded, not aliased")
	testing.expect_value(t, string(out), "café naïve")

	// And it must round-trip back to the original bytes on save.
	back := encode_from_utf8(out, .CP1252, false)
	defer delete(back)
	testing.expect_value(t, len(back), len(raw))
	for b, i in back {testing.expect_value(t, b, raw[i])}
}

// The Windows-1252 range 0x80..0x9F is where it differs from Latin-1 — those
// bytes are punctuation, not control codes.
@(test)
test_encoding_cp1252_high :: proc(t: ^testing.T) {
	testing.expect_value(t, cp1252_to_rune(0x80), rune(0x20AC)) // euro
	testing.expect_value(t, cp1252_to_rune(0x93), rune(0x201C)) // left double quote
	testing.expect_value(t, cp1252_to_rune(0xE9), rune(0xE9)) // e-acute, Latin-1 range
	b, ok := rune_to_cp1252('€')
	testing.expect(t, ok, "euro is representable")
	testing.expect_value(t, b, u8(0x80))
	_, no := rune_to_cp1252('中') // outside the codepage
	testing.expect(t, !no, "CJK is not representable in CP1252")
}

// PowerShell's `>` redirection writes BOM-less UTF-16LE, which read as UTF-8
// displays as "h\0e\0l\0l\0o\0".
@(test)
test_encoding_bomless_utf16 :: proc(t: ^testing.T) {
	le: [dynamic]u8;defer delete(le)
	for c in "hello world, a longer line to sniff" {
		append(&le, u8(c), 0)
	}
	enc, bom := detect_encoding(le[:])
	testing.expect_value(t, enc, Encoding.UTF16LE)
	testing.expect_value(t, bom, 0)

	be: [dynamic]u8;defer delete(be)
	for c in "hello world, a longer line to sniff" {
		append(&be, 0, u8(c))
	}
	enc2, _ := detect_encoding(be[:])
	testing.expect_value(t, enc2, Encoding.UTF16BE)

	// Plain ASCII must NOT be mistaken for UTF-16.
	enc3, _ := detect_encoding(transmute([]u8)string("just ordinary ascii text here"))
	testing.expect_value(t, enc3, Encoding.UTF8)
	// Nor must valid UTF-8 with multi-byte characters.
	enc4, _ := detect_encoding(transmute([]u8)string("héllo wörld — em dash and 中文"))
	testing.expect_value(t, enc4, Encoding.UTF8)
}

@(test)
test_line_endings :: proc(t: ^testing.T) {
	testing.expect_value(t, detect_line_ending(transmute([]u8)string("a\nb\nc")), Line_Ending.LF)
	testing.expect_value(t, detect_line_ending(transmute([]u8)string("a\r\nb\r\n")), Line_Ending.CRLF)
	testing.expect_value(t, detect_line_ending(transmute([]u8)string("a\r\nb\nc")), Line_Ending.Mixed)
	testing.expect_value(t, detect_line_ending(transmute([]u8)string("no breaks")), Line_Ending.LF)

	to_crlf := convert_line_endings(transmute([]u8)string("a\nb\nc"), .CRLF)
	defer delete(to_crlf)
	testing.expect_value(t, string(to_crlf), "a\r\nb\r\nc")

	to_lf := convert_line_endings(transmute([]u8)string("a\r\nb\r\nc"), .LF)
	defer delete(to_lf)
	testing.expect_value(t, string(to_lf), "a\nb\nc")

	// Mixed input normalises cleanly, and a lone CR counts as a break.
	mixed := convert_line_endings(transmute([]u8)string("a\r\nb\nc\rd"), .LF)
	defer delete(mixed)
	testing.expect_value(t, string(mixed), "a\nb\nc\nd")
}

@(test)
test_pt_mixed_sequence :: proc(t: ^testing.T) {
	pt := pt_init(transmute([]u8)string("The quick fox"))
	defer pt_destroy(&pt)
	ins(&pt, 10, "brown ") // "The quick brown fox"
	testing.expect_value(t, str(&pt), "The quick brown fox")
	pt_delete(&pt, 4, 6) // remove "quick " -> "The brown fox"
	testing.expect_value(t, str(&pt), "The brown fox")
	ins(&pt, pt_len(&pt), "!") // append
	testing.expect_value(t, str(&pt), "The brown fox!")
	// spot-check a mid read
	dst := make([]u8, 5);defer delete(dst)
	pt_read(&pt, 4, dst)
	testing.expect_value(t, string(dst), "brown")
}
