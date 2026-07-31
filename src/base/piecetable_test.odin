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

	// Mixed input normalises cleanly. The lone CR in "c\rd" is NOT a break and
	// must survive byte-for-byte: Newtpad counts lines by '\n' alone, so a bare
	// CR is content (a CSV field, terminal output), and paste routes through
	// here. Written as an explicit \r in the expectation, not a copy of the
	// input, so the assertion states the byte rather than assuming it.
	mixed := convert_line_endings(transmute([]u8)string("a\r\nb\nc\rd"), .LF)
	defer delete(mixed)
	testing.expect_value(t, string(mixed), "a\nb\nc\rd")

	// The same in the CRLF direction: the CRLF gains nothing (it already is
	// one), the LF becomes CRLF, and the lone CR must NOT collect an '\n' --
	// that is how a bare CR turns into a visible new row.
	to_crlf2 := convert_line_endings(transmute([]u8)string("a\r\nb\nc\rd"), .CRLF)
	defer delete(to_crlf2)
	testing.expect_value(t, string(to_crlf2), "a\r\nb\r\nc\rd")

	// The paste case from the report, minimal: "a\rb" is one line in Newtpad's
	// model and must stay one line, under either target.
	lone_lf := convert_line_endings(transmute([]u8)string("a\rb"), .LF)
	defer delete(lone_lf)
	testing.expect_value(t, string(lone_lf), "a\rb")
	lone_crlf := convert_line_endings(transmute([]u8)string("a\rb"), .CRLF)
	defer delete(lone_crlf)
	testing.expect_value(t, string(lone_crlf), "a\rb")

	// A CR at the very end of the buffer: the CRLF lookahead runs off the end
	// there, which is the branch an "i + 1 < len" ordering slip gets wrong.
	tail := convert_line_endings(transmute([]u8)string("ab\r"), .CRLF)
	defer delete(tail)
	testing.expect_value(t, string(tail), "ab\r")
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

@(test)
test_pt_row_vis_end :: proc(t: ^testing.T) {
	// CRLF: the CR belongs to the break, not to the line's content.
	pt := pt_init(transmute([]u8)string("ab\r\ncd\r\n"))
	defer pt_destroy(&pt)
	testing.expect_value(t, pt_row_vis_end(&pt, 0, 2, true), 2) // "ab", end at the CR
	testing.expect_value(t, pt_row_vis_end(&pt, 0, 3, true), 2) // end past the CR: strip it
	testing.expect_value(t, pt_row_vis_end(&pt, 4, 7, true), 6) // "cd"

	// LF only: nothing to strip.
	lf := pt_init(transmute([]u8)string("ab\ncd"))
	defer pt_destroy(&lf)
	testing.expect_value(t, pt_row_vis_end(&lf, 0, 2, true), 2)
	testing.expect_value(t, pt_row_vis_end(&lf, 3, 5, true), 5)

	// A wrap point is not a line end, so a CR there is real content.
	cr := pt_init(transmute([]u8)string("a\rb"))
	defer pt_destroy(&cr)
	testing.expect_value(t, pt_row_vis_end(&cr, 0, 2, false), 2)
	// ... and a CR with no LF after it is content even at a line end.
	testing.expect_value(t, pt_row_vis_end(&cr, 0, 2, true), 2)

	// A row ending at EOF on a bare CR: nothing follows, so nothing is stripped.
	// Stripping here let End and a click clamp to 3 while Ctrl+End reached 4.
	eof := pt_init(transmute([]u8)string("abc\r"))
	defer pt_destroy(&eof)
	testing.expect_value(t, pt_row_vis_end(&eof, 0, 4, true), 4)

	// Degenerate ranges must not underflow.
	testing.expect_value(t, pt_row_vis_end(&pt, 2, 2, true), 2)
	testing.expect_value(t, pt_row_vis_end(&pt, 5, 4, true), 4)
}

@(test)
test_pt_crlf_at :: proc(t: ^testing.T) {
	pt := pt_init(transmute([]u8)string("a\r\nb\rc"))
	defer pt_destroy(&pt)
	// pair present: the CR at 1 is followed by the LF at 2.
	testing.expect(t, pt_crlf_at(&pt, 1), "CRLF pair at 1")
	// lone CR (not followed by LF) is not a pair.
	testing.expect(t, !pt_crlf_at(&pt, 4), "lone CR at 4")
	// lone LF: `at` itself must be the CR, not the LF.
	testing.expect(t, !pt_crlf_at(&pt, 2), "LF byte is not a pair start")
	// both bounds: negative offset and one-past-the-end.
	testing.expect(t, !pt_crlf_at(&pt, -1), "negative offset")
	testing.expect(t, !pt_crlf_at(&pt, pt_len(&pt)), "at length")

	// CR at EOF: no byte follows it, so it can never be a pair.
	eof := pt_init(transmute([]u8)string("ab\r"))
	defer pt_destroy(&eof)
	testing.expect(t, !pt_crlf_at(&eof, 2), "CR at EOF has no LF to pair with")

	// Empty buffer: every offset is out of bounds.
	empty := pt_init(nil)
	defer pt_destroy(&empty)
	testing.expect(t, !pt_crlf_at(&empty, 0), "empty buffer")
}

// --- pt_content_end_cap: where a trimming Ctrl+A stops ---

// Bigger than any fixture in this file, so a case that does not mean to exercise
// the cap never accidentally does. Named rather than inlined because "the cap is
// not what this case is about" is the point of it.
@(private = "file")
CE_BIG :: 1 << 30

@(private = "file")
ce :: proc(s: string, cap := CE_BIG) -> (end: int, exact: bool) {
	pt := pt_init(transmute([]u8)s)
	defer pt_destroy(&pt)
	return pt_content_end_cap(&pt, cap)
}

@(private = "file")
ce_bytes :: proc(b: []u8, cap := CE_BIG) -> (end: int, exact: bool) {
	pt := pt_init(b)
	defer pt_destroy(&pt)
	return pt_content_end_cap(&pt, cap)
}

// A fixture of `head` followed by `n` copies of `pad`. Used for the tails that
// have to cross pt_content_end_cap's 4096-byte read chunk, which is where an
// implementation that tracks the pending newline in a chunk-relative index
// instead of an absolute one goes wrong.
@(private = "file")
ce_fixture :: proc(head: string, pad: u8, n: int) -> []u8 {
	out := make([]u8, len(head) + n)
	copy(out, transmute([]u8)head)
	for i in len(head) ..< len(out) {out[i] = pad}
	return out
}

@(test)
test_pt_content_end_cap_paragraph :: proc(t: ^testing.T) {
	// THE case this whole proc exists for, and the one the bug report named: a
	// blank line BETWEEN two paragraphs is content and must stay inside the
	// selection; a RUN of blank lines after the last content is not.
	//
	//   0:o 1:n 2:e 3:\n 4:\n 5:t 6:w 7:o 8:\n 9:\n 10:\n
	//
	// The last non-blank byte is the 'o' at 7, so the answer is the end of ITS
	// row -- 9, one past the '\n' at 8. A forward scan that stops at the first
	// blank row answers 3 instead and eats the second paragraph; that is the
	// wrong implementation this case is written to catch.
	end, exact := ce("one\n\ntwo\n\n\n")
	testing.expect_value(t, end, 9)
	testing.expect(t, exact, "the whole buffer was scanned")
	// Stated the way doc_sel_range's consumers see it: the interior blank line at
	// offset 4 is inside [lo, hi).
	lo := 0
	testing.expect(t, lo <= 4 && 4 < end, "the interior blank line stays selected")
}

@(test)
test_pt_content_end_cap_terminators :: proc(t: ^testing.T) {
	// No trailing newline: the last content row has no terminator, so the answer
	// is the buffer end and Ctrl+A is unchanged.
	end, exact := ce("alpha\nbeta")
	testing.expect_value(t, end, 10)
	testing.expect(t, exact, "exact")

	// Exactly one trailing newline -- an ordinary POSIX-tidy file. The row's
	// terminator is INCLUDED (Wyatt's decision), which is what keeps a copy of a
	// file like this byte-identical to what it was before the trim existed.
	end, exact = ce("alpha\nbeta\n")
	testing.expect_value(t, end, 11)
	testing.expect(t, exact, "exact")

	// Several: one terminator stays, the rest of the run goes.
	end, _ = ce("alpha\nbeta\n\n\n\n")
	testing.expect_value(t, end, 11)

	// A single "\n" after content on offset 0.
	end, _ = ce("a\n\n\n")
	testing.expect_value(t, end, 2)

	// One row, no newline at all, nothing to trim.
	end, _ = ce("alpha")
	testing.expect_value(t, end, 5)
}

@(test)
test_pt_content_end_cap_whitespace_rows :: proc(t: ^testing.T) {
	// Decision 2: a trailing row of spaces/tabs is trailing whitespace, so the
	// scan tests for a non-WHITESPACE byte rather than merely a non-newline.
	//   0:a 1:\n 2:' ' 3:' ' 4:' ' 5:\n 6:\t 7:\n
	end, exact := ce("a\n   \n\t\n")
	testing.expect_value(t, end, 2)
	testing.expect(t, exact, "exact")

	// ... and the constraint that makes this a ROW rule rather than a whitespace
	// trim: the trailing spaces of "beta   " are content ON a content row, so
	// nothing is trimmed at all. A backward whitespace scan that forgot to take
	// the row's end would answer 10 and silently drop three of the user's bytes.
	end, _ = ce("alpha\nbeta   ")
	testing.expect_value(t, end, 13)

	// The same, with a terminator after it: the row end is one past the '\n', so
	// the trailing spaces are still inside the selection.
	end, _ = ce("alpha\nbeta   \n\n\n")
	testing.expect_value(t, end, 14)

	// Vertical tab and form feed are whitespace too; they are what a stray
	// control character in a log tail actually looks like.
	end, _ = ce("a\n\v\n\f\n")
	testing.expect_value(t, end, 2)
}

@(test)
test_pt_content_end_cap_crlf :: proc(t: ^testing.T) {
	// Decision 4 on a CRLF file: BOTH bytes of the last content row's terminator
	// are inside the selection. Answering 2 here would leave a lone CR at the end
	// of a copy, and a paste of it into anything CRLF-aware is a visible defect.
	//   0:a 1:\r 2:\n 3:\r 4:\n 5:\r 6:\n
	end, exact := ce("a\r\n\r\n\r\n")
	testing.expect_value(t, end, 3)
	testing.expect(t, exact, "exact")

	// An ordinary CRLF file with one terminator is unchanged.
	end, _ = ce("a\r\nb\r\n")
	testing.expect_value(t, end, 6)

	// A lone CR is whitespace like any other -- Newtpad does not open classic-Mac
	// files as CR-terminated, so a bare CR run at the end is a blank tail either
	// way and never content.
	end, _ = ce("a\n\r\r")
	testing.expect_value(t, end, 2)
}

@(test)
test_pt_content_end_cap_all_blank :: proc(t: ^testing.T) {
	// Decision 3: with no non-blank byte anywhere, fall back to the whole buffer
	// so Ctrl+A never visibly does nothing and Cut/Copy stay live. `exact` is
	// TRUE here -- the scan really did see everything -- which is what
	// distinguishes this from the cap case below, where the same `end` is a
	// confessed guess.
	end, exact := ce("\n\n\n")
	testing.expect_value(t, end, 3)
	testing.expect(t, exact, "the whole buffer was scanned, so this answer is fact")

	end, exact = ce("   \n \t \n")
	testing.expect_value(t, end, 8)
	testing.expect(t, exact, "exact")

	// Empty buffer: 0, and not a special case in the caller.
	end, exact = ce("")
	testing.expect_value(t, end, 0)
	testing.expect(t, exact, "exact")

	// One byte of content and nothing else.
	end, _ = ce("a")
	testing.expect_value(t, end, 1)
}

@(test)
test_pt_content_end_cap_chunk_boundary :: proc(t: ^testing.T) {
	// A blank tail LONGER than the 4096-byte read chunk. The pending-newline
	// index has to be absolute: a chunk-relative one is re-based on every chunk
	// and lands somewhere in the middle of the tail.
	big := ce_fixture("abc\n", '\n', 9000)
	defer delete(big)
	end, exact := ce_bytes(big)
	testing.expect_value(t, end, 4)
	testing.expect(t, exact, "exact")

	// The same shape with the content byte sitting exactly on a chunk boundary,
	// so the content byte and its terminator are read in different chunks.
	edge := ce_fixture("x", '\n', 4096)
	defer delete(edge)
	end, _ = ce_bytes(edge)
	testing.expect_value(t, end, 2)
}

@(test)
test_pt_content_end_cap_bounded :: proc(t: ^testing.T) {
	// development-loop.md §4 Shape A: the scan is backward and unbounded by
	// nature, so on a multi-GB log with a huge blank tail it would freeze the
	// input thread. It stops at `cap` and SAYS SO -- `exact` false -- rather than
	// returning a confident wrong answer.
	big := ce_fixture("abc\n", '\n', 9000)
	defer delete(big)

	end, exact := ce_bytes(big, 100)
	testing.expect(t, !exact, "the cap was hit before any content byte")
	// And what it returns when it gives up is today's whole-buffer answer, never
	// a trimmed one: a caller that ignores `exact` still gets correct-if-untrimmed
	// behaviour rather than a selection that stops in the middle of the tail.
	testing.expect_value(t, end, len(big))

	// The exact boundary, one byte either side of it. `big` is "abc\n" + 9000
	// '\n' = 9004 bytes and its last content byte is the 'c' at 2, so a cap of
	// 9002 puts the floor ON it and a cap of 9001 stops one byte above it. Off by
	// one in the floor and one of these two flips.
	end, exact = ce_bytes(big, 9001)
	testing.expect(t, !exact, "a cap one byte short of the content is still a miss")
	testing.expect_value(t, end, len(big))

	end, exact = ce_bytes(big, 9002)
	testing.expect(t, exact, "the cap reached the content")
	testing.expect_value(t, end, 4)

	// Cap == length: the floor is offset 0, which is a real buffer start, so an
	// all-blank buffer scanned to its floor is exact (decision 3) rather than a
	// cap miss.
	blank := ce_fixture("", '\n', 5000)
	defer delete(blank)
	end, exact = ce_bytes(blank, len(blank))
	testing.expect(t, exact, "reaching offset 0 is a real answer")
	testing.expect_value(t, end, 5000)

	// One byte short of the length, on the same all-blank buffer: the floor is
	// offset 1, which is not a buffer start, so this is a cap miss.
	end, exact = ce_bytes(blank, len(blank) - 1)
	testing.expect(t, !exact, "stopping short of offset 0 is not")
	testing.expect_value(t, end, 5000)

	// A zero or negative cap can only ever be a miss on a non-empty buffer, and
	// must not underflow into a negative floor.
	end, exact = ce_bytes(big, 0)
	testing.expect(t, !exact, "zero cap")
	testing.expect_value(t, end, len(big))
	end, exact = ce_bytes(big, -5)
	testing.expect(t, !exact, "negative cap")
	testing.expect_value(t, end, len(big))
}

