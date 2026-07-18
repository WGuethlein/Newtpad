// Buffer-benchmark spike: does piece-table performance collapse under
// fragmentation? A fresh piece table is ~1 contiguous piece; heavy editing
// shatters it into many. This measures the two things that decide whether a
// naive (linear-piece-list) piece table is viable:
//   1. SCAN cost fresh (1 piece) vs fragmented (many pieces) — the "search
//      stays instant" promise.
//   2. INSERT cost scaling as the piece list grows — a linear list makes each
//      insert O(pieces) => O(n^2) total, which would be the real killer.
//
// In-memory original (mmap/never-lock is a separate axis, tested later). Build:
//   odin build bench -out:build\frag_spike.exe -o:speed && build\frag_spike.exe
package main

import "core:fmt"
import "core:time"

ORIG_SIZE :: 64 * 1024 * 1024 // 64 MB original
N_INSERTS :: 50_000
BATCH     :: 5_000

Piece :: struct {
	from_add: bool,
	start:    int,
	len:      int,
}

PT :: struct {
	original: []u8,
	add:      [dynamic]u8,
	pieces:   [dynamic]Piece,
	length:   int,
}

// deterministic xorshift so runs are comparable
rng: u64 = 0x9E3779B97F4A7C15
rand_int :: proc(n: int) -> int {
	rng ~= rng << 13
	rng ~= rng >> 7
	rng ~= rng << 17
	return int(rng % u64(n))
}

// Count occurrences of 'z' by walking every logical byte through the piece list.
pt_scan :: proc(pt: ^PT) -> (count: int) {
	for p in pt.pieces {
		data := pt.original[p.start:p.start + p.len] if !p.from_add else pt.add[p.start:p.start + p.len]
		for b in data {
			if b == 'z' {
				count += 1
			}
		}
	}
	return
}

pt_insert :: proc(pt: ^PT, pos: int, ch: u8) {
	add_start := len(pt.add)
	append(&pt.add, ch)
	newp := Piece{true, add_start, 1}

	// linear find: which piece contains pos
	off := 0
	i := 0
	for ; i < len(pt.pieces); i += 1 {
		if off + pt.pieces[i].len >= pos {
			break
		}
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
		left := Piece{p.from_add, p.start, local}
		right := Piece{p.from_add, p.start + local, p.len - local}
		pt.pieces[i] = left
		inject_at(&pt.pieces, i + 1, newp, right)
	}
	pt.length += 1
}

main :: proc() {
	fmt.printfln("=== piece-table fragmentation spike (orig %d MB, %d inserts) ===", ORIG_SIZE / 1024 / 1024, N_INSERTS)

	// Build the original: a repeated line with a couple 'z's per line.
	line := "the quick brown fox jazz buzz over the lazy dog 0123456789\n"
	orig := make([]u8, ORIG_SIZE)
	for i in 0 ..< ORIG_SIZE {
		orig[i] = line[i % len(line)]
	}

	pt := PT {
		original = orig,
		add      = make([dynamic]u8, 0, N_INSERTS),
		pieces   = make([dynamic]Piece, 0, N_INSERTS * 2 + 4),
		length   = ORIG_SIZE,
	}
	append(&pt.pieces, Piece{false, 0, ORIG_SIZE})

	// Baseline: raw contiguous scan of the original.
	t0 := time.tick_now()
	raw_count := 0
	for b in orig {
		if b == 'z' {
			raw_count += 1
		}
	}
	raw_ms := time.duration_milliseconds(time.tick_since(t0))
	fmt.printfln("raw contiguous scan : %8.2f ms  (%d 'z', %d pieces)", raw_ms, raw_count, 1)

	// Fresh piece-table scan (1 piece).
	t0 = time.tick_now()
	fresh_count := pt_scan(&pt)
	fresh_ms := time.duration_milliseconds(time.tick_since(t0))
	fmt.printfln("piece scan  (fresh) : %8.2f ms  (%d 'z', %d pieces)", fresh_ms, fresh_count, len(pt.pieces))

	// Fragment: scattered single-char inserts, timed in batches to expose scaling.
	fmt.println("--- inserting (batch timings expose O(pieces)-per-insert scaling) ---")
	first_batch_ms, last_batch_ms: f64
	for done := 0; done < N_INSERTS; done += BATCH {
		bt := time.tick_now()
		for _ in 0 ..< BATCH {
			pos := rand_int(pt.length)
			pt_insert(&pt, pos, '~')
		}
		batch_ms := time.duration_milliseconds(time.tick_since(bt))
		if done == 0 {
			first_batch_ms = batch_ms
		}
		last_batch_ms = batch_ms
		fmt.printfln("  inserts %6d..%-6d : %8.2f ms  (%d pieces)", done, done + BATCH, batch_ms, len(pt.pieces))
	}
	fmt.printfln("insert scaling      : last batch / first batch = %.1fx", last_batch_ms / first_batch_ms)

	// Fragmented scan (many pieces).
	t0 = time.tick_now()
	frag_count := pt_scan(&pt)
	frag_ms := time.duration_milliseconds(time.tick_since(t0))
	fmt.printfln("piece scan  (frag)  : %8.2f ms  (%d 'z', %d pieces)", frag_ms, frag_count, len(pt.pieces))

	fmt.println("=== verdict inputs ===")
	fmt.printfln("scan slowdown from fragmentation : %.2fx", frag_ms / fresh_ms)
	fmt.printfln("fresh piece scan vs raw scan     : %.2fx", fresh_ms / raw_ms)
	fmt.printfln("avg bytes per piece (fragmented) : %d", pt.length / len(pt.pieces))
}
