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
	chunk:    i32, // index into add_chunks (add pieces only)
	start:    int, // offset within `original`, or within add_chunks[chunk]
	len:      int,
}

Node :: struct {
	piece:       Piece,
	left, right: ^Node,
	priority:    u32,
	sub:         int, // total byte length of this subtree
}

// The add arena is a list of chunks that are allocated once and never moved,
// resized, or freed until pt_destroy. A single insert always lands entirely in
// one chunk, so a piece never spans chunks. This is what makes a piece tree
// readable from a worker thread: a `[dynamic]u8` arena reallocs on append and
// frees the old block, so any slice a reader held became dangling the moment the
// user typed. Chunks don't move, so they don't.
//
// Note the header array itself is still a [dynamic] and does realloc when a
// chunk is added — a reader must not index it concurrently. pt_view hands a
// worker its own copy of the headers (16 bytes each, not the bytes).
ADD_CHUNK_MIN :: 4 << 10
ADD_CHUNK_MAX :: 1 << 20

Piece_Table :: struct {
	original:   []u8,
	add_chunks: [dynamic][]u8,
	add_used:   int, // bytes used in the last chunk (only the last is ever written)
	root:       ^Node,
	length:     int,
	fault:      bool, // a read out of `original` faulted (see pt_take_fault)
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

// Set on the Piece_Table whose read faulted; the owning document polls it once
// per frame (pt_take_fault) and detaches from the mapping.
//
// This is per-table, not global: each document has its own `original`, and a
// worker reading a pt_view gets the flag on its own copy of the struct. A global
// would let one document's fault trigger recovery on whichever document happened
// to be active — unmapping a file that never faulted and marking it modified,
// while the real fault went unnoticed.
//
// Only ever touched by the one thread reading that table, so it needs no atomic;
// a worker mirrors it into its own atomic flag for the main thread to observe.
pt_take_fault :: proc(pt: ^Piece_Table) -> bool {
	f := pt.fault
	pt.fault = false
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
	lp := Piece{t.piece.from_add, t.piece.chunk, t.piece.start, local}
	rp := Piece{t.piece.from_add, t.piece.chunk, t.piece.start + local, t.piece.len - local}
	tl, tr := t.left, t.right
	free(t)
	return merge(tl, mk(lp)), merge(mk(rp), tr)
}

pt_init :: proc(original: []u8) -> (pt: Piece_Table) {
	pt.original = original
	pt.add_chunks = make([dynamic][]u8, 0, 8)
	if len(original) > 0 {
		pt.root = mk(Piece{false, 0, 0, len(original)})
		pt.length = len(original)
	}
	return
}

pt_destroy :: proc(pt: ^Piece_Table) {
	free_tree(pt.root)
	for c in pt.add_chunks {delete(c)}
	delete(pt.add_chunks)
}

// Reserve `n` contiguous bytes in the add arena, growing by a new chunk when the
// last one can't hold them. Chunk sizes double up to ADD_CHUNK_MAX so a scratch
// buffer doesn't pay a megabyte for one keystroke; an insert larger than the max
// gets an exact-size chunk of its own, so an insert never spans chunks.
@(private = "file")
add_reserve :: proc(pt: ^Piece_Table, n: int) -> (chunk: i32, start: int) {
	if len(pt.add_chunks) > 0 {
		last := pt.add_chunks[len(pt.add_chunks) - 1]
		if pt.add_used + n <= len(last) {
			chunk, start = i32(len(pt.add_chunks) - 1), pt.add_used
			pt.add_used += n
			return
		}
	}
	size := ADD_CHUNK_MIN
	if len(pt.add_chunks) > 0 {
		size = min(len(pt.add_chunks[len(pt.add_chunks) - 1]) * 2, ADD_CHUNK_MAX)
	}
	append(&pt.add_chunks, make([]u8, max(size, n)))
	pt.add_used = n
	return i32(len(pt.add_chunks) - 1), 0
}

pt_len :: proc(pt: ^Piece_Table) -> int {return pt.length}

pt_insert :: proc(pt: ^Piece_Table, pos: int, text: []u8) {
	if len(text) == 0 {return}
	p := clamp(pos, 0, pt.length)
	chunk, start := add_reserve(pt, len(text))
	copy(pt.add_chunks[chunk][start:], text)
	l, r := split(pt.root, p)
	pt.root = merge(merge(l, mk(Piece{true, chunk, start, len(text)})), r)
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
	if p.from_add {
		return pt.add_chunks[p.chunk][p.start:p.start + p.len]
	}
	return pt.original[p.start:p.start + p.len]
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
			pt.fault = true // read faulted on the mapped original
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

// --- worker views ---

// An immutable read-only view of the buffer as it is right now, safe to hand to
// another thread and to keep reading while the main thread edits. Cloning the
// tree is not sufficient on its own: pieces name bytes in `original` and in the
// add chunks, and readers reach the chunks *through* the header array, which
// reallocs when a chunk is added. So the view copies the tree and the headers —
// both proportional to piece/chunk count, never to file size — while the bytes
// themselves are aliased, because neither `original` nor a chunk ever moves.
//
// The view therefore stays valid across any number of edits. It does NOT survive
// pt_destroy (frees the chunks) or the owning document detaching from a mapped
// `original`; a worker holding one must be cancelled and joined before either.
pt_view :: proc(pt: ^Piece_Table, allocator := context.allocator) -> Piece_Table {
	v: Piece_Table
	v.original = pt.original
	v.add_chunks = make([dynamic][]u8, len(pt.add_chunks), allocator)
	copy(v.add_chunks[:], pt.add_chunks[:])
	v.add_used = pt.add_used
	v.root = clone(pt.root)
	v.length = pt.length
	return v
}

// Free a view. Releases only what pt_view allocated — the cloned tree and the
// header array — never the chunks or `original`, which the document owns.
pt_view_destroy :: proc(v: ^Piece_Table) {
	free_tree(v.root)
	delete(v.add_chunks)
	v.root = nil
	v.length = 0
}

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

// pt_line_start, bounded, mirroring pt_line_end_cap. `exact` is false when the
// cap was reached without finding a newline, so the returned offset is a scan
// floor rather than a real line start and the caller must not present a column
// derived from it as fact.
//
// Needed because pt_line_start scans backward to the previous newline with no
// bound: on a minified JSON or a single-line log with the caret near the end,
// one call walks the whole document, and the status bar made that call every
// frame.
pt_line_start_cap :: proc(pt: ^Piece_Table, pos, cap: int) -> (start: int, exact: bool) {
	buf: [4096]u8
	q := clamp(pos, 0, pt.length)
	floor := max(0, q - cap)
	for q > floor {
		chunk := min(len(buf), q - floor)
		s := q - chunk
		pt_read(pt, s, buf[:chunk])
		for k := chunk - 1; k >= 0; k -= 1 {
			if buf[k] == '\n' {
				return s + k + 1, true
			}
		}
		q = s
	}
	// Reaching offset 0 is a real line start; stopping at the cap is not.
	return floor, floor == 0
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
