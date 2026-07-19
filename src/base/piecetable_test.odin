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
