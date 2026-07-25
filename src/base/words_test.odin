package base

import "core:testing"

@(test)
test_char_class :: proc(t: ^testing.T) {
	testing.expect_value(t, char_class(' '), Char_Class.Space)
	testing.expect_value(t, char_class('\t'), Char_Class.Space)
	testing.expect_value(t, char_class('\n'), Char_Class.Space)
	testing.expect_value(t, char_class('a'), Char_Class.Word)
	testing.expect_value(t, char_class('Z'), Char_Class.Word)
	testing.expect_value(t, char_class('7'), Char_Class.Word)
	testing.expect_value(t, char_class('_'), Char_Class.Word)
	testing.expect_value(t, char_class(0x80), Char_Class.Word) // non-ASCII: word (see words.odin)
	testing.expect_value(t, char_class('-'), Char_Class.Punct)
	testing.expect_value(t, char_class('"'), Char_Class.Punct)
	testing.expect_value(t, char_class('('), Char_Class.Punct)
}

// Walk right to left and left to right across the same text and require the two
// stop sets to be identical. This is the bug: they were not.
@(test)
test_word_nav_is_symmetric :: proc(t: ^testing.T) {
	text := "\"blender-mcp\" and foo_bar()"
	pt := pt_init(transmute([]u8)text)
	defer pt_destroy(&pt)

	rightward: [dynamic]int
	defer delete(rightward)
	for p := 0; p < len(text); {
		np := pt_word_right(&pt, p)
		if np <= p {break}
		append(&rightward, np)
		p = np
	}

	leftward: [dynamic]int
	defer delete(leftward)
	for p := len(text); p > 0; {
		np := pt_word_left(&pt, p)
		if np >= p {break}
		append(&leftward, np)
		p = np
	}
	// leftward is the same set in reverse, minus the buffer end that only the
	// rightward walk produces and plus the 0 that only the leftward walk does:
	// rightward has nowhere to go but len(text) on its last step, and leftward
	// has nowhere to go but 0 on its last step, so those two boundary stops
	// never appear in both lists. Trim them and compare the shared interior.
	for i in 0 ..< len(leftward) / 2 {
		j := len(leftward) - 1 - i
		leftward[i], leftward[j] = leftward[j], leftward[i]
	}
	testing.expect_value(t, len(rightward), len(leftward))
	if len(rightward) == len(leftward) && len(rightward) > 0 {
		for i in 0 ..< len(rightward) - 1 {
			testing.expectf(
				t,
				rightward[i] == leftward[i + 1],
				"stop %d differs: right=%d left=%d in %q",
				i,
				rightward[i],
				leftward[i + 1],
				text,
			)
		}
	}
}

@(test)
test_word_right_stops :: proc(t: ^testing.T) {
	text := "\"blender-mcp\""
	pt := pt_init(transmute([]u8)text)
	defer pt_destroy(&pt)
	// " | blender | - | mcp | " -> starts of each token
	testing.expect_value(t, pt_word_right(&pt, 0), 1) // past the quote, onto "blender"
	testing.expect_value(t, pt_word_right(&pt, 1), 8) // onto the hyphen
	testing.expect_value(t, pt_word_right(&pt, 8), 9) // onto "mcp"
	testing.expect_value(t, pt_word_right(&pt, 9), 12) // onto the closing quote
	testing.expect_value(t, pt_word_right(&pt, 12), 13) // end of buffer
}

@(test)
test_word_left_stops :: proc(t: ^testing.T) {
	text := "\"blender-mcp\""
	pt := pt_init(transmute([]u8)text)
	defer pt_destroy(&pt)
	testing.expect_value(t, pt_word_left(&pt, 13), 12)
	testing.expect_value(t, pt_word_left(&pt, 12), 9)
	testing.expect_value(t, pt_word_left(&pt, 9), 8)
	testing.expect_value(t, pt_word_left(&pt, 8), 1)
	testing.expect_value(t, pt_word_left(&pt, 1), 0)
}

// A line break is whitespace like any other, so word nav walks over it onto
// the next line rather than stopping there -- matching the previous code and
// every other editor. (Renamed from test_word_nav_stops_at_line_end, which
// claimed the opposite of what this asserts.)
@(test)
test_word_nav_crosses_line_breaks :: proc(t: ^testing.T) {
	pt := pt_init(transmute([]u8)string("foo\nbar"))
	defer pt_destroy(&pt)
	testing.expect_value(t, pt_word_right(&pt, 0), 4) // over the break, onto "bar"
	testing.expect_value(t, pt_word_left(&pt, 7), 4)
	testing.expect_value(t, pt_word_left(&pt, 4), 0)
}

@(test)
test_word_nav_bounds :: proc(t: ^testing.T) {
	pt := pt_init(transmute([]u8)string("ab"))
	defer pt_destroy(&pt)
	testing.expect_value(t, pt_word_left(&pt, 0), 0)
	testing.expect_value(t, pt_word_right(&pt, 2), 2)
	empty := pt_init(nil)
	defer pt_destroy(&empty)
	testing.expect_value(t, pt_word_left(&empty, 0), 0)
	testing.expect_value(t, pt_word_right(&empty, 0), 0)
}
