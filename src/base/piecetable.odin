// Layer: base — a mutable text buffer as a balanced PIECE TREE (an implicit
// treap keyed by byte position) over an immutable original + append-only add
// arena. O(log n) insert/delete/read via split/merge; each node caches its
// subtree byte count. Replaces the earlier linear piece list, whose insert was
// O(n^2) for scattered edits (the frag spike). Same public API as before, so
// the document code and the existing tests are unchanged. Undo snapshots the
// tree by cloning it (see pt_snapshot/pt_restore).
package base

Piece :: struct {
	from_add: bool,
	start:    int,
	len:      int,
}

Node :: struct {
	piece:       Piece,
	left, right: ^Node,
	priority:    u32,
	sub:         int, // total byte length of this subtree
}

Piece_Table :: struct {
	original: []u8,
	add:      [dynamic]u8,
	root:     ^Node,
	length:   int,
}

// Copy hook for reads out of the immutable `original`. Defaults to a plain copy;
// the platform layer overrides it (seh.odin) with an SEH-guarded copy so a read
// from a memory-mapped file that faults - truncated or decompression-broken
// underneath us - is caught instead of crashing. Returns false if any source
// bytes were unreadable (they come back zero-filled); the owning document then
// detaches from the mapping. Reads out of the `add` arena are always plain (heap
// memory can't fault). The proc value is set once at startup, before threads, so
// concurrent reads of it are safe.
safe_copy: proc(dst, src: []u8) -> bool = default_copy

default_copy :: proc(dst, src: []u8) -> bool {
	copy(dst, src)
	return true
}

// Set when a read from `original` faulted; the document polls this once per frame
// (pt_take_fault) and detaches from the mapping. Written only by the main thread
// (read_rec); the index worker tracks its own fault flag.
@(private = "file")
orig_fault: bool

pt_take_fault :: proc() -> bool {
	f := orig_fault
	orig_fault = false
	return f
}

@(private = "file")
rng: u64 = 0x243F6A8885A308D3

@(private = "file")
rprio :: proc() -> u32 {
	rng ~= rng << 13
	rng ~= rng >> 7
	rng ~= rng << 17
	return u32(rng)
}

@(private = "file")
subbytes :: proc(n: ^Node) -> int {return n.sub if n != nil else 0}

@(private = "file")
upd :: proc(n: ^Node) {
	if n != nil {
		n.sub = subbytes(n.left) + n.piece.len + subbytes(n.right)
	}
}

@(private = "file")
mk :: proc(p: Piece) -> ^Node {
	n := new(Node)
	n.piece = p
	n.priority = rprio()
	n.sub = p.len
	return n
}

@(private = "file")
free_tree :: proc(t: ^Node) {
	if t == nil {return}
	free_tree(t.left)
	free_tree(t.right)
	free(t)
}

// merge two treaps: all of `a`'s bytes come before all of `b`'s.
@(private = "file")
merge :: proc(a, b: ^Node) -> ^Node {
	if a == nil {return b}
	if b == nil {return a}
	if a.priority > b.priority {
		a.right = merge(a.right, b)
		upd(a)
		return a
	}
	b.left = merge(a, b.left)
	upd(b)
	return b
}

// split so `l` holds the first `pos` bytes and `r` the rest (may split a piece).
@(private = "file")
split :: proc(t: ^Node, pos: int) -> (l, r: ^Node) {
	if t == nil {return nil, nil}
	lb := subbytes(t.left)
	if pos <= lb {
		a, b := split(t.left, pos)
		t.left = b
		upd(t)
		return a, t
	}
	if pos >= lb + t.piece.len {
		a, b := split(t.right, pos - lb - t.piece.len)
		t.right = a
		upd(t)
		return t, b
	}
	// split point falls inside this node's piece
	local := pos - lb
	lp := Piece{t.piece.from_add, t.piece.start, local}
	rp := Piece{t.piece.from_add, t.piece.start + local, t.piece.len - local}
	tl, tr := t.left, t.right
	free(t)
	return merge(tl, mk(lp)), merge(mk(rp), tr)
}

pt_init :: proc(original: []u8) -> (pt: Piece_Table) {
	pt.original = original
	pt.add = make([dynamic]u8, 0, 1024)
	if len(original) > 0 {
		pt.root = mk(Piece{false, 0, len(original)})
		pt.length = len(original)
	}
	return
}

pt_destroy :: proc(pt: ^Piece_Table) {
	free_tree(pt.root)
	delete(pt.add)
}

pt_len :: proc(pt: ^Piece_Table) -> int {return pt.length}

pt_insert :: proc(pt: ^Piece_Table, pos: int, text: []u8) {
	if len(text) == 0 {return}
	p := clamp(pos, 0, pt.length)
	add_start := len(pt.add)
	append(&pt.add, ..text)
	l, r := split(pt.root, p)
	pt.root = merge(merge(l, mk(Piece{true, add_start, len(text)})), r)
	pt.length += len(text)
}

pt_delete :: proc(pt: ^Piece_Table, pos, count: int) {
	p := clamp(pos, 0, pt.length)
	n := min(count, pt.length - p)
	if n <= 0 {return}
	l, m := split(pt.root, p)
	mid, r := split(m, n)
	free_tree(mid)
	pt.root = merge(l, r)
	pt.length -= n
}

@(private = "file")
piece_src :: proc(pt: ^Piece_Table, p: Piece) -> []u8 {
	return pt.original[p.start:p.start + p.len] if !p.from_add else pt.add[p.start:p.start + p.len]
}

@(private = "file")
read_rec :: proc(pt: ^Piece_Table, t: ^Node, pos: int, dst: []u8, d: ^int) {
	if t == nil || d^ >= len(dst) {return}
	lb := subbytes(t.left)
	if pos < lb {
		read_rec(pt, t.left, pos, dst, d)
	}
	if d^ >= len(dst) {return}
	piece_off := max(pos, lb) - lb
	if piece_off < t.piece.len {
		src := piece_src(pt, t.piece)
		take := min(t.piece.len - piece_off, len(dst) - d^)
		dsub := dst[d^:d^ + take]
		ssub := src[piece_off:piece_off + take]
		if t.piece.from_add {
			copy(dsub, ssub)
		} else if !safe_copy(dsub, ssub) {
			orig_fault = true // read faulted on the mapped original
		}
		d^ += take
	}
	if d^ >= len(dst) {return}
	read_rec(pt, t.right, max(pos - lb - t.piece.len, 0), dst, d)
}

// Copy up to len(dst) logical bytes starting at pos into dst; returns bytes copied.
pt_read :: proc(pt: ^Piece_Table, pos: int, dst: []u8) -> int {
	if pos < 0 || pos >= pt.length || len(dst) == 0 {
		return 0
	}
	d := 0
	read_rec(pt, pt.root, pos, dst, &d)
	return d
}

pt_collect :: proc(pt: ^Piece_Table, allocator := context.allocator) -> []u8 {
	out := make([]u8, pt.length, allocator)
	pt_read(pt, 0, out)
	return out
}

// --- undo support: clone/restore the tree (nodes reference the append-only add
// arena, which is never truncated, so a cloned old tree stays valid) ---

@(private = "file")
clone :: proc(t: ^Node) -> ^Node {
	if t == nil {return nil}
	n := new(Node)
	n^ = t^
	n.left = clone(t.left)
	n.right = clone(t.right)
	return n
}

pt_snapshot :: proc(pt: ^Piece_Table) -> ^Node {return clone(pt.root)}

// Replace the tree with `root` (takes ownership), freeing the old one.
pt_restore :: proc(pt: ^Piece_Table, root: ^Node, length: int) {
	free_tree(pt.root)
	pt.root = root
	pt.length = length
}

pt_free_node_tree :: proc(root: ^Node) {free_tree(root)}

// --- line navigation over the buffer (chunked scans via pt_read) ---

pt_line_start :: proc(pt: ^Piece_Table, pos: int) -> int {
	buf: [4096]u8
	q := clamp(pos, 0, pt.length)
	for q > 0 {
		chunk := min(len(buf), q)
		start := q - chunk
		pt_read(pt, start, buf[:chunk])
		for k := chunk - 1; k >= 0; k -= 1 {
			if buf[k] == '\n' {
				return start + k + 1
			}
		}
		q = start
	}
	return 0
}

pt_line_end :: proc(pt: ^Piece_Table, pos: int) -> int {
	buf: [4096]u8
	p := clamp(pos, 0, pt.length)
	for p < pt.length {
		n := pt_read(pt, p, buf[:])
		for k in 0 ..< n {
			if buf[k] == '\n' {
				return p + k
			}
		}
		p += n
	}
	return pt.length
}

// Like pt_line_end but scans at most `cap` bytes; if no '\n' is found within
// cap, returns pos+cap (a synthetic break). Keeps per-frame work bounded on
// pathologically long lines (multi-GB single-line files). Rendering uses this;
// navigation uses the uncapped pt_line_end.
pt_line_end_cap :: proc(pt: ^Piece_Table, pos, cap: int) -> int {
	buf: [4096]u8
	p := clamp(pos, 0, pt.length)
	limit := min(pt.length, p + cap)
	for p < limit {
		n := pt_read(pt, p, buf[:min(len(buf), limit - p)])
		if n == 0 {
			break
		}
		for k in 0 ..< n {
			if buf[k] == '\n' {
				return p + k
			}
		}
		p += n
	}
	return limit
}

pt_next_line_start :: proc(pt: ^Piece_Table, pos: int) -> int {
	e := pt_line_end(pt, pos)
	return e + 1 if e < pt.length else pt.length
}

pt_prev_line_start :: proc(pt: ^Piece_Table, pos: int) -> int {
	ls := pt_line_start(pt, pos)
	if ls == 0 {
		return 0
	}
	return pt_line_start(pt, ls - 1)
}
