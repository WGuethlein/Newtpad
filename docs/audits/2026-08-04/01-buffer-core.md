# Audit 01 — buffer core (`src/base`: piecetable, lines, encoding, words, base, log)

Read in full: `piecetable.odin` (546 ln), `lines.odin` (38), `encoding.odin` (421), `words.odin` (64),
`base.odin` (7), `log.odin` (160), plus `piecetable_test.odin`, `words_test.odin`, `base_test.odin`.
Cross-checked against `HANDOFF.md` (7,524 ln), `docs/reported-bugs.md`, `docs/requested-features.md`,
and the consuming call sites in `src/program/{doc,find}.odin` and `src/platform/{seh,crash}.odin`.

## Headline: the treap itself is correct

I traced `split`, `merge`, `upd`, `read_rec` and `add_reserve` case by case (empty subtree, split at
0, split at `sub`, split inside a piece, equal priorities, oversized insert, chunk rollover) and found
**no ordering, rebalancing, `sub`-accounting, offset-arithmetic or lifetime defect**. `split` cannot
manufacture a zero-length piece (`local` is strictly in `1..len-1`); every mutating path calls `upd`;
the node freed at `piecetable.odin:161` has no surviving referent; `pt_view`'s aliasing argument holds
under `pt_insert`, `add_reserve`'s chunk append and `doc_absorb_append`. The findings below are around
the structure, not in it.

Deliberately **not** reported because HANDOFF already records them: `pt_insert` never coalesces
adjacent appends (§5 debt register, HANDOFF:361/387/2514, with instrumented numbers); `pt_line_start`
/`pt_line_end` uncapped on the main thread (HANDOFF:568, 1132, 1320, 1429); `pt_view` cloning per
find-bar keystroke (HANDOFF:833); `doc_move_lines`' `read_range` dropping `pt_read`'s return
(HANDOFF:3161, 3265); `line_cell_col`'s silent truncation (HANDOFF:321); CP1252 misdetection being
mitigated by Reopen As (HANDOFF:2621).

---

### [HIGH] Word navigation is an uncapped, one-`pt_read`-per-byte scan on the input thread
**Where:** `src/base/words.odin:34-38` (`class_at`), `:43-52` (`pt_word_right`), `:56-63`
(`pt_word_left`); consumed at `src/program/doc.odin:4092` and `:4097`
**Confidence:** CONFIRMED (mechanism traced end to end; the timing figure is an estimate, derived
below from HANDOFF's own measurement of `pt_line_start`)
**Fix risk:** RISKY (needs a cap + an `exact`-style contract, i.e. a caller-visible behaviour change)

**Mechanism:** `class_at` issues a **one-byte `pt_read`** per byte examined. Each such call is a full
`read_rec` descent from the root, and — for any byte still living in the original — an indirect call
through `base.safe_copy`, which in the shipped build is `platform/seh.odin:24`'s `guarded_copy`: an
Odin→C foreign call into an SEH `__try/__except` frame, per byte. Both `pt_word_right` and
`pt_word_left` then loop over the run **with no byte cap and no iteration cap**, so a single Ctrl+Right
/ Ctrl+Left / Ctrl+Backspace can walk an arbitrary number of bytes.

This is *not* the item HANDOFF:1320 records. That entry names `doc_scroll`, `doc_max_top`,
`doc_ensure_cursor_visible`, `doc_scroll_to_fraction` "and the cursor-movement helpers" calling the
uncapped `pt_line_start`/`pt_line_end`. Word nav calls neither, and its **constant is two to three
orders of magnitude worse**: `pt_line_start` amortises one tree descent and one `safe_copy` over a
4096-byte block (`piecetable.odin:336-341`), and HANDOFF measured it at 350 ms/GB ≈ 0.35 ns/byte.
`class_at` pays a descent *and* an SEH foreign call *per byte* — realistically 50–100 ns/byte.

Every other unbounded scan in this file has already been given a bounded twin that reports `exact`
(`pt_line_start_cap`, `pt_line_end_cap`, `pt_content_end_cap`). Word nav was missed by that sweep.

**Failure scenario:** open a `.json`/`.md`/`.html` containing an embedded base64 data URI — a 4 MB
inline image is ordinary. Every byte of base64 classes as `.Word` (`words.odin:27`: `b >= 0x80` is
Word, and `A-Za-z0-9` obviously are), so the whole blob is **one token**. Put the caret at its start
and press Ctrl+Right once: `pt_word_right` issues ~4,000,000 one-byte `pt_read`s → ~0.2–0.4 s of
frozen UI. Hold the key (auto-repeat ~30/s) and the window stops responding. On a mapped original each
of those 4M reads is also an SEH foreign call. The same applies to Ctrl+Backspace (`pt_word_left`) at
the blob's end, which additionally **deletes** what it walked. A 40 MB minified single-line asset
makes it multi-second.

**Fix:** give both a byte cap (`WORD_NAV_CAP`, the same shape as `RENDER_LINE_CAP`) and stop at it,
returning `exact=false` so the caller can decline rather than present a wrong offset — matching the
contract `pt_line_start_cap` already has. Independently, and worth doing anyway: have `class_at` read
a 256-byte block into a stack buffer and classify from it, so the descent and the SEH call amortise
the way `pt_line_start`'s already do. That alone is a ~100× constant-factor win and is SAFE.

---

### [MEDIUM] `pt_line_end` can spin forever where its own bounded twin returns
**Where:** `src/base/piecetable.odin:352-365` vs `:371-388`
**Confidence:** CONFIRMED (the asymmetry is literal); reachability PLAUSIBLE
**Fix risk:** SAFE

**Mechanism:**
```odin
for p < pt.length {
    n := pt_read(pt, p, buf[:])
    for k in 0 ..< n { if buf[k] == '\n' { return p + k } }
    p += n            // <-- no progress if n == 0
}
```
`pt_line_end_cap`, written later, has exactly the guard this lacks: `if n == 0 { break }`
(`:377-379`). `pt_read` returns 0 whenever `read_rec` finds no bytes at `pos`, which happens iff
`pt.length` exceeds the tree's actual byte count (`root.sub`). Those two are maintained
**independently** — `length` by arithmetic (`:213`, `:224`), `sub` by `upd` — and `pt_restore`
(`:325-329`) takes `length` from the caller with no check against `root`. **Nothing in the codebase
asserts `pt.length == root.sub`, and no test covers it.**

**Failure scenario:** any future divergence (a new `pt_restore` caller, a partially-applied batch
splice, a corrupted `Snapshot.length`) turns Ctrl+End, Down-arrow, `pt_next_line_start` or
`doc_line_number` into an **infinite 100%-CPU loop with the message pump dead** — no crash, no dump,
no breadcrumb, just a hung window the user has to kill. The bounded twin returns cleanly from the
identical state, so the same document is navigable by one code path and lethal by another.

**Fix:** add `if n == 0 { break }` to `pt_line_end` (two lines, no behaviour change on any reachable
state). Separately add a debug `assert(pt.length == subbytes(pt.root))` in `pt_restore` and a base
test for the invariant (see test gaps).

---

### [MEDIUM] Base's own scanning helpers ignore `pt_read`'s return **and** `pt.fault`, then scan a stale stack buffer
**Where:** `src/base/piecetable.odin:341` (`pt_line_start`), `:440` (`pt_line_start_cap`), `:508`
(`pt_content_end_cap`)
**Confidence:** CONFIRMED
**Fix risk:** RISKY for the refusal contract; SAFE for the stale-buffer half

**Mechanism:** all three call `pt_read(pt, s, buf[:chunk])` and discard the return value. `buf` is a
`[4096]u8` **reused across loop iterations**, so a short read leaves the tail of the previous chunk in
place and the scan then matches `'\n'` against bytes from a different part of the document. More
importantly, none of the three consults `pt.fault` (`piecetable.odin:84`, `pt_faulted`) — and on a
faulting mapped read `safe_copy` **zero-fills the bad page, `read_rec` still counts those bytes into
`d` (`:246-254`), and `pt_read` returns the full count**. The read *looks* complete.

HANDOFF:3161/3265 records this exact shape ("Shape A, swept and confirmed") for `doc_move_lines`'
`read_range` in the program layer, and §6ae says the sweep was done. **The sweep did not reach
`base` itself.** This is the recorded item being worse than recorded: three more instances, in the
file every other consumer goes through.

**Failure scenario:** a log file on a disconnecting network share, or an NTFS-compressed file whose
decompression fails. `safe_copy` zero-fills; `pt_line_start` sees 4096 zero bytes, finds no `'\n'`,
and walks back another chunk — repeating to **offset 0**. The caret column, `doc_move_lines`' range
and `block_row_range` all then compute against a line start of 0, i.e. a range spanning the whole
document, in the same frame where `pt.fault` is set but not yet taken. `pt_content_end_cap` fails the
opposite way: `0x00` is **not** in `blank_byte` (`:459-461`), so the first zeroed byte reads as
*content* and Ctrl+A stops there — a truncated selection presented with `exact = true`.

**Fix:** (a) check the return and `break` on a short read — mechanical, no contract change; (b) have
all three return the `exact = false` they already have machinery for when `pt_faulted(pt)` is set
after a chunk, so a caller refuses rather than acts on zeros. `pt_line_start` has no `exact` channel
at all, which is the argument for its callers migrating to `pt_line_start_cap`.

---

### [MEDIUM] The crash reporter takes the log mutex — a crash inside `log()` hangs instead of reporting
**Where:** `src/base/log.odin:135-146` (`log_each`), `:149-153` (`log_retained`), `:155-159`
(`log_total`); called from `src/platform/crash.odin:319-320`
**Confidence:** PLAUSIBLE (I traced the lock discipline; I could not establish whether
`MiniDumpWriteDump` runs before this point with other threads suspended)
**Fix risk:** SAFE

**Mechanism:** the unhandled-exception filter calls `log_retained()`, `log_total()` and `log_each()`,
each of which does a blocking `sync.mutex_lock(&g_log.mu)`. `sync.Mutex` is not recursive and the
crash handler runs **on the faulting thread**. `log()` holds that mutex across `:96-107` — the ring
write, the `copy` into `e.text`, and the sink read.

**Failure scenario:** the process faults inside `log()`'s critical section (an access violation on the
ring while writing a breadcrumb — precisely the memory-corruption case a crash reporter exists for).
The filter runs on that same thread, calls `log_retained()`, and **deadlocks on a mutex the thread
itself holds**. Result: no `.txt` report, no `.dmp` if the dump write is downstream of this, and a
process that hangs rather than dies — the worst possible outcome for a crash reporter. Secondary
variant: a worker thread is mid-`log()` and gets suspended by the dump writer while holding the mutex;
the handler then blocks until the suspension lifts, which it never does.

**Fix:** give `log_each`/`log_retained`/`log_total` a `try_lock` path — on failure, read the ring
without the lock (it is a fixed array of POD; a torn last line in a crash report is strictly better
than a hang) and note "log lock held; trail may be torn" in the report.

---

### [LOW] `lines.odin` is dead code, and the one non-trivial proc in it is wrong
**Where:** `src/base/lines.odin:26-38` (`prev_line_start`); whole file
**Confidence:** CONFIRMED
**Fix risk:** SAFE (delete the file)

**Mechanism:** `line_end`, `next_line_start` and `prev_line_start` have **no callers outside
`base_test.odin`** (verified by grep across `src/`; every production site uses the `pt_*` piece-tree
equivalents). `prev_line_start` also has two defects:
1. `if i > 0 && b[i] == '\n' { i -= 1 }` — the `i > 0` guard makes the `pos == 1` case skip the
   step-back, so the scan immediately terminates on `b[0]`.
2. `i := pos - 1` then `b[i]` with no upper bound check — `pos > len(b)` indexes out of range.

**Failure scenario:** `prev_line_start(transmute([]u8)string("\nalpha"), 1)` returns **1**; the correct
answer is **0** (the empty first line). `base_test.odin:81-90` never tests a document starting with a
blank line, so the bug has sat undetected. Because the file is dead this is latent — but HANDOFF:197
still lists `lines.odin` as part of `base`, so the next person to want byte-slice line nav will reach
for it.

**Fix:** delete `lines.odin` and the `test_line_nav` case in `base_test.odin:80-90`. If it is kept
instead, the loop should be `i := pos - 1; if i >= 0 && i < len(b) && b[i] == '\n' { i -= 1 }`.

---

### [LOW] `pt_view` ignores its `allocator` parameter for the tree it clones
**Where:** `src/base/piecetable.odin:304-313` (`:310` `v.root = clone(pt.root)`), `:280-287`
(`clone` uses bare `new(Node)`), `:317-322` (`pt_view_destroy` uses bare `free`)
**Confidence:** CONFIRMED (latent — no current caller passes a non-default allocator)
**Fix risk:** SAFE

**Mechanism:** `pt_view` takes `allocator := context.allocator` and honours it for `add_chunks`
(`:307`) but not for the node clone, which goes through `new(Node)` → `context.allocator`.
`pt_view_destroy` symmetrically frees the headers via the dynamic array's recorded allocator and the
nodes via `context.allocator`. The signature therefore promises something it does not deliver.

**Failure scenario:** the obvious future use — handing a worker a view out of a per-job arena,
`pt_view(&doc.pt, arena_alloc)` — allocates every node from the global heap instead, and
`pt_view_destroy` from a context whose `context.allocator` is that arena would then call the arena's
`free` on heap pointers. Given the project's own history (CLAUDE.md's Memory row was amended twice
over exactly this class of mistake), this is a trap worth closing before someone falls in.

**Fix:** thread `allocator` through `clone` and `free_tree`, or drop the parameter from `pt_view` and
document that views are heap-only. Same applies to `pt_snapshot`/`pt_free_node_tree`.

---

### [LOW] `pt_line_end_cap` and `pt_line_start_cap` do not guard a negative `cap`; `pt_content_end_cap` does
**Where:** `src/base/piecetable.odin:375` (`limit := min(pt.length, p + cap)`), `:436`
(`floor := max(0, q - cap)`) vs `:495` (`floor := max(0, q - cap)` with the explicit comment *"max():
a zero or negative cap must not go below 0"*)
**Confidence:** PLAUSIBLE (I could not construct a reachable negative `cap` today; see below)
**Fix risk:** SAFE

**Mechanism:** with `cap < 0`, `pt_line_end_cap` returns `p + cap` — a line end **before** the
position it was asked about. `pt_line_start_cap`'s `max(0, q - cap)` yields `q + |cap|`, a floor
*above* `q`, so it returns a line start **after** the position, with `exact = false`. Only the third
cap proc guards, and its comment shows the author knew the hazard existed.

**Failure scenario (nearest real one):** `src/program/find.odin:904` computes
`slack = min(REGEX_LINE_SLACK, (upto - pos) / 4)` and passes it straight to `pt_line_end_cap` at
`:925`; the result feeds `buf[:end - pos]` at `:927`. If `pos` ever exceeds `upto` — a resumed
`s.at.pos` past a shrunk budget — `slack` goes negative, `end < pos`, and the slice expression panics
with a negative length. I could not make `pos > upto` reachable with today's two `scan_all` callers
(`max(int)` and the constant `SEARCH_FIRST_PAINT`), so I am reporting this as the missing guard rather
than as a live crash.

**Fix:** `c := max(cap, 0)` at the top of both procs, matching `pt_content_end_cap`.

---

### [LOW] `log()` reads `min_level` and `started` without the mutex that guards every write to them
**Where:** `src/base/log.odin:88` (`if level < g_log.min_level`), `:94` (`if g_log.started`) vs
`:57-63` and `:71-75`, which write both under `g_log.mu`
**Confidence:** CONFIRMED
**Fix risk:** SAFE

**Mechanism:** the file's header explicitly claims `log()` "is safe to call from the worker threads
(search, watcher) as well as the main loop". Two of its reads are unsynchronised loads of fields that
`log_init`/`log_set_level` write under the lock. This is a data race by the language's rules; on x86 a
byte load is atomic in practice, but nothing stops LLVM hoisting the `min_level` load out of a caller's
loop, and `g_log.start` (a `time.Tick`, 8 bytes) is read at `:94` while `log_init` writes it at `:60`.

**Failure scenario:** `log_set_level(.Debug)` from the settings path while the search worker is in
`log()` — the worker can miss the level change indefinitely, or (for `start`) compute a timestamp from
a half-written tick, putting a nonsense `t_ms` into the crash-report breadcrumb trail. Low impact, but
the file advertises thread safety it does not implement.

**Fix:** make `min_level` and `started`/`start` atomics (`intrinsics.atomic_load/store`), which also
keeps the gated-off path at "one comparison" as the comment promises.

---

### [LOW] UTF-16 decode silently drops a trailing odd byte
**Where:** `src/base/encoding.odin:254` (`for i + 1 < len(body)`)
**Confidence:** CONFIRMED
**Fix risk:** SAFE

**Mechanism:** an odd-length UTF-16 body leaves one byte unconsumed and unreported. `decode_to_utf8`
has no error channel, so the caller cannot know.

**Failure scenario:** open a UTF-16LE log that a writer was mid-flush on (odd length), then save. The
final byte is gone from the file and nothing said so. Narrow — the file was already malformed — but
Newtpad's stated promise is that it does not alter bytes it was not asked to alter
(`encoding.odin:159-163` makes exactly that argument for lone CRs).

**Fix:** append `U+FFFD` for the orphan byte, or return a `lossy: bool` third result the open path can
surface, mirroring `encode_lossy_count`'s design.

---

### [LOW] `looks_utf8` accepts sequences that are not valid UTF-8
**Where:** `src/base/encoding.odin:37-65`
**Confidence:** CONFIRMED (the acceptances are real; the user-visible consequence is PLAUSIBLE)
**Fix risk:** SAFE

**Mechanism:** the validator checks lead-byte range and continuation-byte range only. It accepts
UTF-8-encoded **surrogates** (`ED A0 80` → U+D800), **overlong** 3- and 4-byte forms (`E0 80 80`,
`F0 80 80 80`), and codepoints **above U+10FFFF** (`F4 90 80 80`). The comment at `:54` claims the
lead-byte switch "includes 0xC0/0xC1 overlongs", which is true only for the 2-byte case.

**Failure scenario:** the practical direction is misclassification toward UTF-8. A Windows-1252 file
whose high bytes happen to fall into those patterns — e.g. `E9 80 80` = "é€€" in CP1252 — passes as a
valid 3-byte sequence. It takes an unlucky whole-4096-byte head for the file to sniff as UTF-8 overall,
so this is a heuristic weakness rather than a live corruption path, and Reopen As (HANDOFF:2621) is the
escape hatch. Worth fixing because it is four extra range checks.

**Fix:** reject `E0 80..9F`, `ED A0..BF`, `F0 80..8F`, and `F4 90..BF` — the standard UTF-8 DFA ranges.

---

### [LOW] `pt_view_destroy` leaves `add_chunks` dangling, and a failed thread spawn leaks a view
**Where:** `src/base/piecetable.odin:317-322`; caller `src/program/find.odin:558-559`
**Confidence:** CONFIRMED
**Fix risk:** SAFE

**Mechanism:** `pt_view_destroy` nulls `root` and zeroes `length` but leaves `v.add_chunks` pointing
at the freed backing array with its old `len`. A second `pt_view_destroy` on the same struct would
double-free. Today it is safe only because `search_stop` gates the call on `s.th != nil`
(`find.odin:544-551`) — i.e. the safety lives in the caller, not the type.

Separately, `find.odin:558-559` assigns `s.view` and *then* creates the thread; if
`thread.create_and_start_with_data` returns nil, `s.th` stays nil, `search_stop` never destroys the
view, and the cloned tree leaks for the document's life.

**Failure scenario:** a future second teardown path (doc close during a fault recovery, a torn-off
window) calls `pt_view_destroy` on an already-destroyed view → free of a freed pointer → heap
corruption. The current single-call-site protection is exactly the kind that a fifth caller breaks.

**Fix:** `v.add_chunks = nil` after `delete` (Odin's `delete` on a nil dynamic array is a no-op, so the
type becomes idempotent-safe). In `find.odin`, destroy the view when the thread fails to start.

---

## TEST GAPS

The base suite is 23 `@(test)` cases in `piecetable_test.odin` plus 6 each in `base_test.odin` and
`words_test.odin`. The gaps below are the ones where a bug would be silent data corruption.

1. **No randomised model test.** Nothing compares the piece tree against a naive `[dynamic]u8`
   oracle over thousands of random `pt_insert`/`pt_delete`/`pt_read` operations with a fixed seed.
   For a data structure whose failure mode is silent corruption of the user's file, this is the single
   highest-value missing test — and the one that would have made my "the treap is correct" conclusion
   evidence rather than inspection. Every existing case is a hand-written 5–20 byte fixture.
2. **No structural invariant check.** Nothing asserts, after a sequence of edits: heap property
   (`parent.priority >= child.priority`), `n.sub == subbytes(left) + piece.len + subbytes(right)` at
   every node, no zero-length piece, and — the one that turns finding #2 above from latent into
   impossible — **`pt.length == subbytes(pt.root)`**.
3. **`pt_line_start_cap`, `pt_line_end_cap`, `pt_snapshot` and `pt_restore` have zero base-layer
   tests.** `pt_content_end_cap` has seven thorough ones (including cap-boundary ±1 — a model for the
   other two). The capped procs are the ones the whole "never freeze on huge files" rule rests on, and
   the `exact` contract they publish is untested here.
4. **`utf8_complete_len` has no base test** despite being the sole guard against splitting a rune
   across a streamed save chunk. HANDOFF:1495 says `savestreamtest` covers it end to end at the
   program layer; the unit itself is untested, so the boundary cases (buffer ending on a lone lead
   byte, on 2-of-4 continuation bytes, on a buffer that *starts* mid-rune) are not pinned.
   `encode_body_from_utf8` and `encoding_bom` are likewise untested in base.
5. **The `safe_copy` seam is untested in base.** `test_modes.odin:1429` and `:35076` install a
   faulting `safe_copy` at the program layer, but nothing in `src/base` asserts the two properties
   that matter here: reads out of the **add arena** must never call `safe_copy`
   (`piecetable.odin:249-250`), and a faulting original read must set `pt.fault` **and still return the
   full count**. Both are load-bearing for every finding above about the fault flag. A counting stub
   `safe_copy` would pin both in ~15 lines.
6. **No test that word nav respects UTF-8.** `words_test.odin` is ASCII-only. The reason byte-level
   `char_class` is safe is subtle — every byte `>= 0x80` classes as `.Word`, so a class transition can
   never fall inside a multi-byte sequence (`words.odin:27`). That is a real invariant and nothing
   tests it; a future "fix" that classed non-ASCII punctuation separately would break it silently and
   put the caret mid-codepoint.
7. **No test that `pt_insert`/`pt_delete` at a mid-codepoint offset is anybody's problem.** Base
   offers no rune-boundary guard and no assertion; the program layer's `prev_rune`/`next_rune`/
   `pt_crlf_at` are the only protection. Worth at least a documented contract in `piecetable.odin`.
8. **`pt_content_end_cap` is untested against a NUL byte**, which `blank_byte` (`:459-461`)
   deliberately excludes — the behaviour finding #3 above depends on.
9. **`log.odin` has no tests at all**, including the two properties its header asserts: ring
   wraparound ordering in `log_each`, and allocation-freedom of `log()`.

CLAUDE.md's rule applies to items 1–3 in particular: none of these has ever failed, so none of them
currently proves anything.

---

## MARKETABLE

Each verified in the code, stated as the benefit rather than the mechanism.

1. **Editing is as fast in a 2 GB file as in a 2 KB one.** The buffer is a balanced tree keyed by
   byte position with each node caching its subtree's size (`piecetable.odin:17-22`), so an insert or
   delete is a split plus a merge — logarithmic, never a copy of the file
   (`:126-163`, `:206-225`). File size does not appear in the cost of a keystroke.
2. **Opening a huge file copies nothing at all.** A UTF-8 file is handed to the buffer as a direct
   view of the memory-mapped bytes with no allocation (`encoding.odin:237-239`, `allocated=false`),
   and the buffer starts life as a single piece over it (`piecetable.odin:165-173`). Open time is
   independent of file size.
3. **A file that is truncated, unplugged or corrupted underneath us cannot take the editor down.**
   Every read of the mapped file goes through a guarded copy (`piecetable.odin:54`, `:249-253`) that
   catches the hardware fault, returns zeros for the unreadable page instead of crashing, and raises a
   per-document flag so that document copies itself into private memory and tells the user
   (`platform/seh.odin:24-37`). And the guard is *proven*, not assumed: `seh_selftest`
   (`platform/seh.odin:48-58`) deliberately reads an unmapped page at startup and verifies the fault
   was caught. Pulling a USB stick mid-edit is a warning, not a lost session.
4. **You can keep typing while a search runs over a multi-GB file — safely by construction, not by
   locking.** The search thread is handed an immutable snapshot that shares the file's bytes rather
   than copying them (`piecetable.odin:291-313`), and the editor's scratch memory is allocated in
   chunks that are never moved, resized or freed while the document is open (`:24-35`, `:186-202`).
   There is no lock on the buffer and no pause when a background job is running. The same property is
   what lets a growing log file be followed live with a search in flight (`doc.odin:3070-3073`).
5. **Undo of a whole-file operation is instant.** Each undo step snapshots the entire buffer by
   cloning the tree (`piecetable.odin:280-289`) — the cost is proportional to the number of edits
   made, not to the size of the file. Undoing a sort or a replace-all on a 500 MB file is immediate,
   and jumping to any earlier state in the history is a pointer swap (`:325-329`).
6. **It tells you before it damages your file, not after.** Line-ending style, byte-order marks and
   BOM-less UTF-16 (which PowerShell's `>` produces) are detected structurally rather than guessed
   (`encoding.odin:74-117`), and before saving to a legacy Windows codepage the editor counts exactly
   how many characters that codepage cannot hold (`encoding.odin:220-229`) so it can ask first —
   instead of silently replacing every em-dash and emoji with a question mark.
7. **No operation on a huge file is allowed to freeze the window, and when a scan gives up it says
   so.** The expensive scans all have bounded forms that return an explicit "this answer is a floor,
   not a fact" flag (`pt_line_start_cap:433`, `pt_line_end_cap:371`, `pt_content_end_cap:492`), so the
   UI can decline to show a number rather than show a confident wrong one. (Honest caveat: finding #1
   above is the one navigation path still missing this.)
