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
