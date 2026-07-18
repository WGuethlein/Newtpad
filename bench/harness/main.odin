// Buffer benchmark harness (targeted). Three cores behind one interface:
//   naive  - whole file in a growable array (memmove edits)
//   gap    - gap buffer (whole file in RAM, gap at the cursor)
//   piece  - piece table over an mmapped, never-locked original + add arena
// Measures the decision-movers identified by the devil's-advocate pass:
//   open time vs size, self-reported private memory, local typing latency,
//   random viewport-extract latency, whole-buffer scan, and a never-lock test.
// The RB-tree piece-tree is deferred; the piece core uses a linear piece list
// (fine for open/read/scan on lightly-edited files; heavy-edit is settled by
// bench/frag). Build: odin build bench/harness -out:build\bench.exe -o:speed
package main

import "core:fmt"
import "core:os"
import "core:slice"
import "core:time"
import win "core:sys/windows"

DATA_DIR :: "bench/data"
SIZES := [?]int{10 * MB, 100 * MB, 1024 * MB}
MB :: 1024 * 1024

// ------------------------------------------------------------------ interface

Core :: struct {
	name:   string,
	open:   proc(path: string) -> rawptr,
	length: proc(h: rawptr) -> int,
	insert: proc(h: rawptr, pos: int, ch: u8),
	read:   proc(h: rawptr, pos: int, dst: []u8), // copy logical [pos,pos+len(dst)) into dst
	count:  proc(h: rawptr, needle: u8) -> int, // walk every logical byte
	mem:    proc(h: rawptr) -> int, // private/committed bytes (excludes file-backed mmap)
	close:  proc(h: rawptr),
}

CORES := [?]Core {
	{"naive", naive_open, naive_len, naive_insert, naive_read, naive_count, naive_mem, naive_close},
	{"gap", gap_open, gap_len, gap_insert, gap_read, gap_count, gap_mem, gap_close},
	{"piece", piece_open, piece_len, piece_insert, piece_read, piece_count, piece_mem, piece_close},
}

// ------------------------------------------------------------------ naive

Naive :: struct {
	buf: [dynamic]u8,
}
naive_open :: proc(path: string) -> rawptr {
	n := new(Naive)
	data, _ := os.read_entire_file(path, context.allocator)
	n.buf = make([dynamic]u8, len(data))
	copy(n.buf[:], data)
	delete(data)
	return n
}
naive_len :: proc(h: rawptr) -> int {return len((^Naive)(h).buf)}
naive_insert :: proc(h: rawptr, pos: int, ch: u8) {inject_at(&(^Naive)(h).buf, pos, ch)}
naive_read :: proc(h: rawptr, pos: int, dst: []u8) {copy(dst, (^Naive)(h).buf[pos:pos + len(dst)])}
naive_count :: proc(h: rawptr, needle: u8) -> (c: int) {
	for b in (^Naive)(h).buf {if b == needle {c += 1}}
	return
}
naive_mem :: proc(h: rawptr) -> int {return cap((^Naive)(h).buf)}
naive_close :: proc(h: rawptr) {delete((^Naive)(h).buf);free(h)}

// ------------------------------------------------------------------ gap buffer

GAP_SLACK :: 1 * MB
Gap :: struct {
	buf:       []u8,
	gap_start: int, // gap is [gap_start, gap_end)
	gap_end:   int,
}
gap_open :: proc(path: string) -> rawptr {
	g := new(Gap)
	data, _ := os.read_entire_file(path, context.allocator)
	g.buf = make([]u8, len(data) + GAP_SLACK)
	copy(g.buf[:len(data)], data)
	g.gap_start = len(data)
	g.gap_end = len(g.buf)
	delete(data)
	return g
}
gap_len :: proc(h: rawptr) -> int {g := (^Gap)(h);return len(g.buf) - (g.gap_end - g.gap_start)}
@(private = "file")
gap_move :: proc(g: ^Gap, pos: int) {
	if pos == g.gap_start {return}
	if pos < g.gap_start {
		// shift [pos, gap_start) up to the end of the gap
		n := g.gap_start - pos
		copy(g.buf[g.gap_end - n:g.gap_end], g.buf[pos:g.gap_start])
		g.gap_start = pos
		g.gap_end -= n
	} else {
		n := pos - g.gap_start
		copy(g.buf[g.gap_start:g.gap_start + n], g.buf[g.gap_end:g.gap_end + n])
		g.gap_start += n
		g.gap_end += n
	}
}
gap_insert :: proc(h: rawptr, pos: int, ch: u8) {
	g := (^Gap)(h)
	gap_move(g, pos)
	if g.gap_start == g.gap_end {return} // gap exhausted (skip growth for the bench)
	g.buf[g.gap_start] = ch
	g.gap_start += 1
}
gap_read :: proc(h: rawptr, pos: int, dst: []u8) {
	g := (^Gap)(h)
	gap_size := g.gap_end - g.gap_start
	for i in 0 ..< len(dst) {
		lp := pos + i
		dst[i] = g.buf[lp] if lp < g.gap_start else g.buf[lp + gap_size]
	}
}
gap_count :: proc(h: rawptr, needle: u8) -> (c: int) {
	g := (^Gap)(h)
	for b in g.buf[:g.gap_start] {if b == needle {c += 1}}
	for b in g.buf[g.gap_end:] {if b == needle {c += 1}}
	return
}
gap_mem :: proc(h: rawptr) -> int {return len((^Gap)(h).buf)}
gap_close :: proc(h: rawptr) {delete((^Gap)(h).buf);free(h)}

// ------------------------------------------------------------------ piece table (mmap)

Piece :: struct {
	from_add: bool,
	start:    int,
	len:      int,
}
PieceTable :: struct {
	hmap:     win.HANDLE,
	view:     rawptr,
	original: []u8,
	add:      [dynamic]u8,
	pieces:   [dynamic]Piece,
	length:   int,
	path:     string,
}
piece_open :: proc(path: string) -> rawptr {
	pt := new(PieceTable)
	pt.path = path
	wpath := win.utf8_to_wstring(path)
	// Share EVERYTHING so we never lock the user's file.
	hfile := win.CreateFileW(
		wpath,
		win.GENERIC_READ,
		win.FILE_SHARE_READ | win.FILE_SHARE_WRITE | win.FILE_SHARE_DELETE,
		nil,
		win.OPEN_EXISTING,
		win.FILE_ATTRIBUTE_NORMAL,
		nil,
	)
	if hfile == win.INVALID_HANDLE_VALUE {
		fmt.eprintln("piece_open: CreateFileW failed")
		return pt
	}
	size: win.LARGE_INTEGER
	win.GetFileSizeEx(hfile, &size)
	pt.hmap = win.CreateFileMappingW(hfile, nil, win.PAGE_READONLY, 0, 0, nil)
	pt.view = win.MapViewOfFile(pt.hmap, win.FILE_MAP_READ, 0, 0, 0)
	win.CloseHandle(hfile) // mapping keeps its own reference; file can now be renamed/deleted
	n := int(size)
	pt.original = (cast([^]u8)pt.view)[:n]
	pt.add = make([dynamic]u8, 0, 1 * MB)
	pt.pieces = make([dynamic]Piece, 0, 64)
	append(&pt.pieces, Piece{false, 0, n})
	pt.length = n
	return pt
}
piece_len :: proc(h: rawptr) -> int {return (^PieceTable)(h).length}
@(private = "file")
piece_bytes :: proc(pt: ^PieceTable, p: Piece) -> []u8 {
	return pt.original[p.start:p.start + p.len] if !p.from_add else pt.add[p.start:p.start + p.len]
}
piece_insert :: proc(h: rawptr, pos: int, ch: u8) {
	pt := (^PieceTable)(h)
	add_start := len(pt.add)
	append(&pt.add, ch)
	newp := Piece{true, add_start, 1}
	off, i := 0, 0
	for ; i < len(pt.pieces); i += 1 {
		if off + pt.pieces[i].len >= pos {break}
		off += pt.pieces[i].len
	}
	if i >= len(pt.pieces) {
		append(&pt.pieces, newp)
		pt.length += 1
		return
	}
	local := pos - off
	p := pt.pieces[i]
	if local == 0 {
		inject_at(&pt.pieces, i, newp)
	} else if local == p.len {
		inject_at(&pt.pieces, i + 1, newp)
	} else {
		pt.pieces[i] = Piece{p.from_add, p.start, local}
		inject_at(&pt.pieces, i + 1, newp, Piece{p.from_add, p.start + local, p.len - local})
	}
	pt.length += 1
}
piece_read :: proc(h: rawptr, pos: int, dst: []u8) {
	pt := (^PieceTable)(h)
	// find start piece
	off, i := 0, 0
	for ; i < len(pt.pieces); i += 1 {
		if off + pt.pieces[i].len > pos {break}
		off += pt.pieces[i].len
	}
	need := len(dst)
	d := 0
	local := pos - off
	for i < len(pt.pieces) && d < need {
		b := piece_bytes(pt, pt.pieces[i])
		avail := len(b) - local
		take := min(avail, need - d)
		copy(dst[d:d + take], b[local:local + take])
		d += take
		i += 1
		local = 0
	}
}
piece_count :: proc(h: rawptr, needle: u8) -> (c: int) {
	pt := (^PieceTable)(h)
	for p in pt.pieces {
		for b in piece_bytes(pt, p) {if b == needle {c += 1}}
	}
	return
}
piece_mem :: proc(h: rawptr) -> int {
	pt := (^PieceTable)(h)
	return len(pt.add) + len(pt.pieces) * size_of(Piece) // mmap'd original is file-backed, not private
}
piece_close :: proc(h: rawptr) {
	pt := (^PieceTable)(h)
	if pt.view != nil {win.UnmapViewOfFile(pt.view)}
	if pt.hmap != nil {win.CloseHandle(pt.hmap)}
	delete(pt.add);delete(pt.pieces);free(h)
}

// ------------------------------------------------------------------ stats

Stat :: struct {
	median_ns: f64,
	p99_ns:    f64,
}
@(require_results)
percentiles :: proc(samples: []f64) -> Stat {
	slice.sort(samples)
	return {samples[len(samples) / 2], samples[int(f64(len(samples)) * 0.99)]}
}

// deterministic xorshift
rng: u64 = 0x2545F4914F6CDD1D
rnd :: proc(n: int) -> int {
	rng ~= rng << 13;rng ~= rng >> 7;rng ~= rng << 17
	return int(rng % u64(n))
}

// ------------------------------------------------------------------ test files

ensure_file :: proc(size: int) -> string {
	path := fmt.aprintf("%s/test_%dMB.txt", DATA_DIR, size / MB)
	if info, err := os.stat(path, context.allocator); err == nil && int(info.size) == size {
		return path
	}
	fmt.printfln("  generating %s (%d MB)...", path, size / MB)
	os.make_directory(DATA_DIR)
	line := "the quick brown fox jazz buzz over the lazy dog 0123456789\n"
	chunk := make([]u8, MB)
	defer delete(chunk)
	for i in 0 ..< MB {chunk[i] = line[i % len(line)]}
	f, _ := os.open(path, os.O_WRONLY | os.O_CREATE | os.O_TRUNC)
	written := 0
	for written < size {
		w := min(MB, size - written)
		os.write(f, chunk[:w])
		written += w
	}
	os.close(f)
	return path
}

// ------------------------------------------------------------------ workloads

main :: proc() {
	fmt.println("=== Newtpad buffer benchmark (targeted) ===")
	fmt.println("generating test files if needed...")
	paths: [len(SIZES)]string
	for s, i in SIZES {paths[i] = ensure_file(s)}
	big := paths[len(SIZES) - 1] // 1 GB

	// (1) OPEN TIME vs SIZE
	fmt.println("\n--- open time (ms) ---")
	fmt.printf("%-8s", "size")
	for c in CORES {fmt.printf("%12s", c.name)}
	fmt.println()
	for s, si in SIZES {
		fmt.printf("%-8s", fmt.tprintf("%dMB", s / MB))
		for c in CORES {
			t := time.tick_now()
			h := c.open(paths[si])
			ms := time.duration_milliseconds(time.tick_since(t))
			_ = c.length(h) // consume
			c.close(h)
			fmt.printf("%12.2f", ms)
		}
		fmt.println()
	}

	// (2) MEMORY after opening 1 GB (self-reported private/committed bytes)
	fmt.println("\n--- private/committed memory after opening 1GB (MB) ---")
	for c in CORES {
		h := c.open(big)
		fmt.printf("  %-8s %8.1f MB\n", c.name, f64(c.mem(h)) / MB)
		c.close(h)
	}

	// (3) LOCAL TYPING latency (100 MB file, 20k inserts near a moving cursor)
	fmt.println("\n--- local typing latency, per insert (100MB, 20k inserts) ---")
	for c in CORES {
		h := c.open(paths[1])
		cursor := c.length(h) / 2
		samples := make([]f64, 20_000)
		defer delete(samples)
		for k in 0 ..< 20_000 {
			cursor += 1
			if k % 80 == 0 {cursor = rnd(c.length(h))} // occasional jump to a new line
			t := time.tick_now()
			c.insert(h, cursor, '~')
			samples[k] = f64(time.duration_nanoseconds(time.tick_since(t)))
		}
		st := percentiles(samples)
		fmt.printf("  %-8s median %8.0f ns   p99 %10.0f ns\n", c.name, st.median_ns, st.p99_ns)
		c.close(h)
	}

	// (4) VIEWPORT EXTRACT latency (1 GB, 50k random 4KB reads ~= a 60-line viewport)
	fmt.println("\n--- viewport extract, per 4KB read (1GB, 50k random reads) ---")
	VP :: 4096
	dst := make([]u8, VP)
	defer delete(dst)
	for c in CORES {
		h := c.open(big)
		limit := c.length(h) - VP
		samples := make([]f64, 50_000)
		defer delete(samples)
		checksum: u64
		for k in 0 ..< 50_000 {
			pos := rnd(limit)
			t := time.tick_now()
			c.read(h, pos, dst)
			samples[k] = f64(time.duration_nanoseconds(time.tick_since(t)))
			checksum += u64(dst[0]) + u64(dst[VP - 1]) // consume
		}
		st := percentiles(samples)
		fmt.printf("  %-8s median %8.0f ns   p99 %10.0f ns   (chk %d)\n", c.name, st.median_ns, st.p99_ns, checksum)
		c.close(h)
	}

	// (5) WHOLE-BUFFER SCAN (1 GB): frequent byte vs rare byte
	fmt.println("\n--- whole-buffer scan (1GB), time ms + count ---")
	for c in CORES {
		h := c.open(big)
		t := time.tick_now()
		freq := c.count(h, 'z') // frequent
		ms1 := time.duration_milliseconds(time.tick_since(t))
		t = time.tick_now()
		rare := c.count(h, '~') // absent (worst case: full scan, no early out)
		ms2 := time.duration_milliseconds(time.tick_since(t))
		fmt.printf("  %-8s frequent %7.1f ms (%d)   rare %7.1f ms (%d)\n", c.name, ms1, freq, ms2, rare)
		c.close(h)
	}

	// (6) NEVER-LOCK: with the 1GB file mmapped, can another handle rename/delete it?
	fmt.println("\n--- never-lock test (piece table holds 1GB mmapped) ---")
	never_lock_test(big)

	fmt.println("\n=== done ===")
}

never_lock_test :: proc(path: string) {
	h := piece_open(path)
	defer piece_close(h)

	renamed := fmt.tprintf("%s.renamed", path)
	wsrc := win.utf8_to_wstring(path)
	wdst := win.utf8_to_wstring(renamed)
	ok := win.MoveFileExW(wsrc, wdst, win.MOVEFILE_REPLACE_EXISTING)
	if ok {
		fmt.println("  rename-while-mapped: PASS (file renamed while we hold the mapping)")
		// move it back so the test file persists
		win.MoveFileExW(wdst, wsrc, win.MOVEFILE_REPLACE_EXISTING)
	} else {
		fmt.printfln("  rename-while-mapped: FAIL (err %d) - we are locking the file", win.GetLastError())
	}
	fmt.println("  note: truncate-underneath still faults on access (EXCEPTION_IN_PAGE_ERROR);")
	fmt.println("        production mitigation = VEH-guarded reads or copy-on-open below a size threshold.")
}
