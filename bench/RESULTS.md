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
