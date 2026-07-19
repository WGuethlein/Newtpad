# Buffer benchmark — results

## Fragmentation spike (2026-07-18)

Purpose: the devil's-advocate pass identified the load-bearing assumption of the
whole buffer benchmark — *"a piece table measured fresh (1 piece) represents its
steady-state performance."* This spike falsifies or confirms it before building
the full harness. Source: `bench/frag_spike.odin` (64 MB in-memory original,
50k scattered single-char inserts, linear piece list).

### Numbers (Odin `-o:speed`, this machine)

| measurement | result |
|---|---|
| raw contiguous scan (64 MB, count 'z') | ~21 ms (cold, ran first) |
| piece scan, fresh (1 piece) | ~12 ms |
| piece scan, fragmented (100k pieces) | ~12 ms |
| **scan slowdown from fragmentation** | **1.03×** |
| insert batch, first 5k (→10k pieces) | 6.3 ms |
| insert batch, last 5k (→100k pieces) | 147 ms |
| **insert scaling (last/first batch)** | **23.6×** |
| avg bytes/piece at 100k pieces | 671 |

### Findings

1. **Fragmentation does NOT hurt whole-buffer scan (1.03×).** Walking a 100k-piece
   list to scan every byte is as fast as scanning one contiguous piece — the
   per-boundary overhead is negligible when average piece size is hundreds of
   bytes. **The A1 fear (search collapses after editing) is refuted** for
   sequential scan. Filter-as-you-type over a piece table is viable.
   - Caveat: not tested at pathological avg-piece << 100 bytes (would need
     millions of pieces on 64 MB), but insert cost (below) makes reaching that
     state impractical anyway.
   - The "fresh 0.58× vs raw" line is a cache-warming artifact (raw scan ran
     first, cold); both warm scans are ~12 ms. Not a real piece-table win.

2. **A naive linear-piece-list piece table has O(n²) insert (23.6× scaling).**
   Each insert does a linear find + `inject_at` shift, both O(pieces). Confirmed
   quadratic. A linear-list piece table is **dead for heavy/scattered editing.**
   To be a viable contender a piece table MUST be a **piece *tree*** (balanced /
   red-black, VS Code "piece tree" style) for O(log n) insert — the exact
   complexity HANDOFF §3 hoped to avoid, now confirmed mandatory.
   - Note: scattered random inserts are worst-case for *both* structures. A gap
     buffer also pays O(n) per *random* insert (gap move), but real typing is
     *local* (gap already at cursor → O(1)). The scattered case models
     multi-cursor / bulk edits.

### Decision impact

The benchmark's central question **changes**:
- OLD: "Does piece-table search collapse under fragmentation?" → **No.**
- NEW: "Is a piece-*tree*'s implementation complexity worth it over a gap
  buffer's simplicity?" — given gap buffer's O(n) gap-move and O(filesize) open
  vs piece table's O(1) open + never-lock + free undo.

Implication for the full harness: the piece-table contender must be implemented
as a **piece tree**, or it loses on insert by construction. That raises the cost
of the piece-table path and must weigh in the final call (and strengthens the
"gap buffer under a size threshold" hybrid option).

Still to measure in the full harness (per the revised methodology): random
viewport-extract (per-frame hot path), never-lock + file-changed-underneath
correctness (pass/fail), private/committed memory at open and post-scan, cold
open asymptotics, varied search selectivity + single-line file, controlled
allocators.

## Targeted harness (2026-07-18)

Source: `bench/harness/main.odin` (naive array, gap buffer, mmap piece table).
Real files 10/100/1024 MB. Odin `-o:speed`, this machine.

| workload | naive | gap | piece (mmap) |
|---|---|---|---|
| open 10 MB | 7.1 ms | 6.6 ms | **0.08 ms** |
| open 100 MB | 62.8 ms | 57.0 ms | **0.10 ms** |
| open 1 GB | 596 ms | 572 ms | **0.12 ms** |
| private mem after 1 GB | 1024 MB | 1025 MB | **0 MB** (file-backed) |
| local typing / insert (median) | 2.7 ms (dead) | **~0 ns** | 2.6 µs |
| local typing / insert (p99) | 6.7 ms | 0.65 ms | 9.1 µs |
| viewport 4 KB read (median) | 0.4 µs | 1.7 µs | 2.3 µs |
| whole 1 GB scan | 186 ms | 197 ms | 409 ms cold / 196 ms warm |
| rename while mapped | n/a | n/a | **PASS** |

Reads:
- **Open + memory are decisive.** naive/gap open is O(filesize) (~0.57 ms/MB) and
  commits the whole file to *private* RAM. At 1 GB: 0.6 s + 1 GB; at 8 GB: ~5 s +
  8 GB. The piece table (mmap) opens in O(1) at any size with ~0 private memory
  (original is file-backed, reclaimable). **Only the mmap approach meets "opens
  any file instantly incl. multi-GB, low memory."** Gap/naive are disqualified
  for large files.
- **Typing:** gap ~0 ns (O(1) at cursor) is its one real win; piece 2.6 µs is
  imperceptible; naive 2.7 ms/keystroke (memmoves half the file) is dead.
- **Viewport extract** (the per-frame hot path) is trivially sub-frame for all
  three (piece 2.3 µs on a fresh/lightly-edited buffer).
- **Scan:** piece cold 409 ms is the lazy page-fault-in (the read cost naive/gap
  paid at open); warm it's 196 ms ≈ the others. Piece defers the read to
  touch-time — the viewport-first win: only visible pages fault in.

## Adversarial "break the winner" pass + verification (2026-07-18)

Spawned a devils-advocate agent on the emerging winner (piece-tree over
lifetime-mmap). It raised 7 attacks; the headline one was **empirically tested
and REFUTED**, the rest stand as needs-mitigation:

- **[REFUTED by direct test]** "A live mapping blocks DELETE → never-lock
  violation." `bench/lock_test/main.odin` on this Win11 (26200): `DeleteFileW`
  while mapped **succeeds**, the file is removed from the namespace, and the
  mapped view keeps reading the unlinked data (no crash) — modern NTFS
  POSIX-unlink semantics (Win10 1709+). Rename also succeeds. **Never-lock is
  honored for delete AND rename.** Caveat: verify on FAT32/USB and SMB paths
  (older/remote filesystems may differ) — treat those as copy-on-open.
- **[valid, needs-mitigation]** Truncate/shrink-underneath (or NTFS-*compressed*
  files, which is routine) faults on access (`EXCEPTION_IN_PAGE_ERROR`). Mechanism
  fix: guard mapped reads with **frame-scoped SEH `__try/__except`** (NOT global
  `AddVectoredExceptionHandler` — wrong tool, can't cleanly resume, and would see
  D3D/DWrite COM exceptions), and/or do all mapped reads on **worker threads that
  copy into private memory** so the UI thread never faults a mapped page.
- **[valid]** Network-drive/USB stall: a page fault on a mapped view blocks the
  faulting thread for the SMB timeout (tens of seconds). Never fault mapped memory
  on the UI thread → same worker-copy rule.
- **[valid]** Live-append (log tail): the view is frozen at map-time size; growth
  needs an explicit remap-on-grow protocol (feeds the V2 tail feature).
- **[valid]** 1 GB single-line file: the buffer open is O(1), but the **line-index**
  (scrollbar extent, go-to-line, viewport line layout) is the hidden O(n) cost —
  a separate background/cancellable subsystem, not a buffer concern. Its acceptance
  test is the single-line file.
- **[valid]** Empty/zero-byte file: `CreateFileMapping` fails on 0 bytes → need a
  floor case (copy/empty-buffer path).
- **[valid]** Two paths (copy small / mmap large): define save + undo uniformly to
  avoid mode-boundary bugs.

## DECISION (recommended)

**Buffer = piece TREE (RB-balanced) over the original, with the original mmapped
for large files and copied into the add-arena for small ones.**
- Piece *tree* (not linear list) — frag spike settled this (linear = O(n^2)).
- mmap large / copy small — copy below a generous threshold is crash-immune and
  simple; the mmap's only real payoff (instant open, ~0 memory) matters only for
  big files. Mmap honors never-lock (delete + rename verified).
- Mitigations to bake in (not optional): SEH-guarded mapped reads on worker threads
  only; empty-file floor case; remap-on-grow for tails; a separate background
  line-index subsystem for the "instant open" product promise.

This upgrades the locked decision "Piece table over mmapped original + append arena —
*pending week-1 benchmark*" line from PENDING to **DATA-VALIDATED**, with the
piece-tree + copy-small-mmap-large + SEH-worker-reads refinements.
