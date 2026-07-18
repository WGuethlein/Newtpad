// Layer: base — pure line navigation over a UTF-8 byte buffer. Used by the
// viewport to walk lines on demand from a byte offset (no full index needed to
// render). '\n' delimits; a trailing '\r' is a rendering concern, not here.
package base

// Index of the '\n' at or after pos, or len(b) if none (i.e. end of this line).
line_end :: proc(b: []u8, pos: int) -> int {
	i := pos
	for i < len(b) {
		if b[i] == '\n' {
			return i
		}
		i += 1
	}
	return len(b)
}

// Start of the next line after pos (one past the next '\n'); clamps to len(b).
next_line_start :: proc(b: []u8, pos: int) -> int {
	e := line_end(b, pos)
	return e + 1 if e < len(b) else len(b)
}

// Start of the line immediately above the line beginning at `pos`
// (pos is assumed to be a line start). Returns 0 at the top.
prev_line_start :: proc(b: []u8, pos: int) -> int {
	if pos <= 0 {
		return 0
	}
	i := pos - 1 // the '\n' ending the previous line (if pos is a line start)
	if i > 0 && b[i] == '\n' {
		i -= 1
	}
	for i >= 0 && b[i] != '\n' {
		i -= 1
	}
	return i + 1
}
