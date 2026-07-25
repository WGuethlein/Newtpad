// Layer: base (pure) — character classification and word-boundary walking.
//
// Lives here rather than in program/doc.odin so it is reachable by `odin test`:
// the previous two-class predicate was file-private in package main, and the
// asymmetry it caused therefore had no unit test to catch it.
package base

// Three classes, which is what makes the two directions agree. With only
// word/non-word, a rightward walk skipped punctuation runs into the next word
// and stopped at its END, while a leftward walk stopped at word STARTS — so
// Ctrl+Right and Ctrl+Left visited different offsets in the same text.
Char_Class :: enum u8 {
	Space,
	Word,
	Punct,
}

// Byte-level classification. Every byte >= 0x80 classes as Word, which keeps
// CJK and accented text behaving as words but also lumps non-ASCII punctuation
// (curly quotes, em dashes) in with them. Fixing that means decoding runes in
// the nav loop; recorded as a known limitation in the batch-1 spec rather than
// silently inherited.
char_class :: proc(b: u8) -> Char_Class {
	switch {
	case b == ' ', b == '\t', b == '\r', b == '\n':
		return .Space
	case b >= '0' && b <= '9', b >= 'A' && b <= 'Z', b >= 'a' && b <= 'z', b == '_', b >= 0x80:
		return .Word
	}
	return .Punct
}

@(private = "file")
class_at :: proc(pt: ^Piece_Table, pos: int) -> Char_Class {
	b: [1]u8
	if pt_read(pt, pos, b[:]) != 1 {return .Space}
	return char_class(b[0])
}

// Start of the next token at or after `pos`: skip the current run, then any
// whitespace. Lands on a token START, which is what makes it the mirror of
// pt_word_left.
pt_word_right :: proc(pt: ^Piece_Table, pos: int) -> int {
	L := pt.length
	p := clamp(pos, 0, L)
	if p >= L {return L}
	if c := class_at(pt, p); c != .Space {
		for p < L && class_at(pt, p) == c {p += 1}
	}
	for p < L && class_at(pt, p) == .Space {p += 1}
	return p
}

// Start of the token before `pos`: skip whitespace backwards, then the run that
// ends there, stopping at its first byte.
pt_word_left :: proc(pt: ^Piece_Table, pos: int) -> int {
	p := clamp(pos, 0, pt.length)
	for p > 0 && class_at(pt, p - 1) == .Space {p -= 1}
	if p == 0 {return 0}
	c := class_at(pt, p - 1)
	for p > 0 && class_at(pt, p - 1) == c {p -= 1}
	return p
}
