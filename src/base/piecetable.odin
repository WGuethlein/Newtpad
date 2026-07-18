// Layer: base — a mutable text buffer as a linear piece table over an immutable
// original + an append-only add arena. Pure (no platform). Edits never touch the
// original bytes (mmap-friendly, free undo via piece snapshots). Linear piece
// list is fine for local editing; an RB piece tree is the scale follow-up (the
// frag spike showed the linear list is O(n^2) only for scattered/bulk edits).
package base

Piece :: struct {
	from_add: bool,
	start:    int, // offset into original or add
	len:      int,
}

Piece_Table :: struct {
	original: []u8,
	add:      [dynamic]u8,
	pieces:   [dynamic]Piece,
	length:   int,
}

pt_init :: proc(original: []u8) -> (pt: Piece_Table) {
	pt.original = original
	pt.add = make([dynamic]u8, 0, 1024)
	pt.pieces = make([dynamic]Piece, 0, 16)
	if len(original) > 0 {
		append(&pt.pieces, Piece{false, 0, len(original)})
		pt.length = len(original)
	}
	return
}

pt_destroy :: proc(pt: ^Piece_Table) {
	delete(pt.add)
	delete(pt.pieces)
}

pt_len :: proc(pt: ^Piece_Table) -> int {return pt.length}

@(private = "file")
piece_src :: proc(pt: ^Piece_Table, p: Piece) -> []u8 {
	return pt.original[p.start:p.start + p.len] if !p.from_add else pt.add[p.start:p.start + p.len]
}

// Find the piece index and its starting logical offset such that the piece
// contains logical position `pos` (or the insertion point at pos).
@(private = "file")
locate :: proc(pt: ^Piece_Table, pos: int) -> (i, off: int) {
	for i < len(pt.pieces) {
		if off + pt.pieces[i].len > pos {
			return
		}
		off += pt.pieces[i].len
		i += 1
	}
	return
}

pt_insert :: proc(pt: ^Piece_Table, pos: int, text: []u8) {
	if len(text) == 0 {
		return
	}
	p := clamp(pos, 0, pt.length)
	add_start := len(pt.add)
	append(&pt.add, ..text)
	newp := Piece{true, add_start, len(text)}

	i, off := locate(pt, p)
	if i >= len(pt.pieces) {
		append(&pt.pieces, newp)
	} else {
		local := p - off
		pc := pt.pieces[i]
		if local == 0 {
			inject_at(&pt.pieces, i, newp)
		} else if local == pc.len {
			inject_at(&pt.pieces, i + 1, newp)
		} else {
			pt.pieces[i] = Piece{pc.from_add, pc.start, local}
			inject_at(&pt.pieces, i + 1, newp, Piece{pc.from_add, pc.start + local, pc.len - local})
		}
	}
	pt.length += len(text)
}

pt_delete :: proc(pt: ^Piece_Table, pos, count: int) {
	p := clamp(pos, 0, pt.length)
	n := min(count, pt.length - p)
	if n <= 0 {
		return
	}
	i, off := locate(pt, p)
	remaining := n
	local := p - off

	if local > 0 {
		pc := pt.pieces[i]
		deletable := pc.len - local
		take := min(deletable, remaining)
		right_len := pc.len - local - take
		pt.pieces[i] = Piece{pc.from_add, pc.start, local} // keep the left part
		remaining -= take
		i += 1
		if right_len > 0 {
			inject_at(&pt.pieces, i, Piece{pc.from_add, pc.start + local + take, right_len})
		}
	}

	for remaining > 0 && i < len(pt.pieces) {
		pc := pt.pieces[i]
		if pc.len <= remaining {
			remaining -= pc.len
			ordered_remove(&pt.pieces, i)
		} else {
			pt.pieces[i] = Piece{pc.from_add, pc.start + remaining, pc.len - remaining}
			remaining = 0
		}
	}
	pt.length -= n
}

// Copy up to len(dst) logical bytes starting at pos into dst; returns bytes copied.
pt_read :: proc(pt: ^Piece_Table, pos: int, dst: []u8) -> int {
	if pos < 0 || pos >= pt.length || len(dst) == 0 {
		return 0
	}
	i, off := locate(pt, pos)
	d := 0
	local := pos - off
	for i < len(pt.pieces) && d < len(dst) {
		src := piece_src(pt, pt.pieces[i])
		avail := len(src) - local
		take := min(avail, len(dst) - d)
		copy(dst[d:d + take], src[local:local + take])
		d += take
		i += 1
		local = 0
	}
	return d
}

// Materialize the whole buffer (mainly for tests / small-buffer use). Caller frees.
pt_collect :: proc(pt: ^Piece_Table, allocator := context.allocator) -> []u8 {
	out := make([]u8, pt.length, allocator)
	pt_read(pt, 0, out)
	return out
}
