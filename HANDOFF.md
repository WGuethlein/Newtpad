# Newtpad — Handoff & State

Rewritten 2026-07-18 after a mid-project audit (devil's-advocate + code review). This is the
living state doc: what Newtpad is, what works now, how it's built, the debt we're carrying, and
the roadmap. Research corpus in [research/](research/); buffer benchmark in [bench/](bench/).

**The constitution (`CLAUDE.md`) is gitignored and exists only on Wyatt's disk.** That is a
deliberate choice, but it means the document defining the locked decisions, the hard engineering
rules and the git conventions has no backup, no history, and is invisible to a fresh clone — while
this file, which repeatedly defers to it, is committed. Losing it loses the *why* behind every
decision here. Worth revisiting: tracking it costs nothing and the reasons for keeping it out are
worth restating if they still hold.

## 1. What Newtpad is

Wyatt's project: a **notepad replacement for Windows** — the text-editor analog of File Pilot
(filepilot.tech). Identity: **ultra-fast, ultra-small, fully handmade, shipped commercial
product.** Scope closer to Windows Notepad than Notepad++, with working plugins post-V1. Wyatt
directs the work. Standing rule: **ask the outcome-changing questions before substantial work;
never rubber-stamp.**

## 2. Current state — what works (30+ commits, one day)

A genuinely usable editor, built end-to-end:
- **Open** any file: copy small (<16 MB) into private memory, mmap large (instant, ~0 private
  memory, never-lock verified). Encoding detect/decode (UTF-8 / UTF-16 LE+BE via BOM). No-arg
  launch = empty scratch buffer.
- **View**: D3D11 + DXGI flip-model; DirectWrite→ClearType glyph atlas→instanced quads;
  byte-offset viewport that walks lines on demand (instant at any size); byte-proportional
  scrollbar; background thread counts total lines for the status bar.
- **Edit**: piece-tree buffer (treap) with insert/delete/undo/redo; caret; text input; arrows/
  Home/End/Page/word-nav (Ctrl+arrows, Ctrl+Backspace); selection (shift + mouse, double-click
  word, triple-click line); clipboard (Ctrl+C/X/V, Ctrl+A) via CF_UNICODETEXT.
- **Save**: Ctrl+S; native Save-As dialog for scratch/unnamed; re-encodes to the file's original
  encoding; atomic (temp + rename, never-lock); CRLF preserved.
- **Find/Replace**: Ctrl+F find, Ctrl+H replace, incremental highlight + next/prev (wrap),
  Ctrl+R regex (via `core:text/regex`), Ctrl+L filter-to-matching-lines.
- **Multilingual**: per-codepoint font fallback (Consolas + Microsoft YaHei CJK + Segoe UI
  Symbol + Segoe UI). Latin/Cyrillic/Greek/CJK/accents/symbols render.

**Note:** §2 describes the first day. Much more has shipped since — tabs, session restore, command
palette, menu bar, settings, font selection, undo history, zoom, word wrap, external-change
detection, per-monitor DPI, single-instance, an installer. §6b onward is the accurate record, and
§6k is the most recent state.

Verified: **20 `odin test` cases** (encoding, line-nav, piece tree, lossy-encoding detection) plus
~28 headless test modes — see §7 for the full list. Wyatt daily-drives the editor, which is now the
main source of bugs, because this environment cannot inject GUI input.

## 3. Architecture as-built

Layers (dependency order): **base → platform → program**. (`renderer`/`ui` are empty stubs; the
planned `renderer (quads)` and `ui (immediate-mode)` split hasn't been extracted — their work
lives in `platform/{quads,text}.odin` and `program/{doc,main,find}.odin`. **The boundary that
matters — all Win32/COM/D3D isolated in `platform`, plain-data types exposed upward — is genuinely
clean and verified by the audit.**)

- `base/` (pure, no platform): `piecetable.odin` (treap piece tree + line-nav), `encoding.odin`
  (detect/decode/encode), `lines.odin`. Tests alongside.
- `platform/` (all Win32/COM): `window.odin` (window + input queue), `gfx.odin` (device/
  swapchain/frame), `quads.odin` (instanced solid-quad pipeline), `text.odin` (DirectWrite +
  ClearType glyph atlas + font fallback), `dwrite.odin` (hand-declared DirectWrite COM),
  `file.odin` (mmap/copy open, atomic write, Save dialog), `clipboard.odin`.
- `program/` (frame loop, documents, all UI). Fourteen files — this list was three for a long
  time while eleven more shipped, so keep it current:
  - `main.odin` — frame loop, input dispatch, `render_frame`, status bar, device-lost handling.
  - `app.odin` — the tab model: slot array of `^Document` (stable addresses), MRU, activate.
  - `doc.odin` — `Document`: buffer, cursor, selection, undo/redo, viewport, line index, wrap,
    filter, gutter, external-change state, history helpers.
  - `find.odin` — find/replace/regex/filter and the background search worker.
  - `commands.odin` — the `[Command_Id]Command` table, keymap, and `command_dispatch`.
  - `menu.odin` — menu bar, dropdowns, mnemonics, scroll resolution.
  - `palette.odin` — Ctrl+P overlay, prefix modes, fzf-style scoring.
  - `ui_tabs.odin` — the tab strip in the custom caption.
  - `settings.odin` / `fontpage.odin` — Settings and Font, which are tabs, not modal takeovers.
  - `history.odin` — the undo-history panel.
  - `session.odin` — hot exit: `session.txt` plus per-buffer backups.
  - `watch.odin` — external-change detection on a worker (timestamp polling, never a held handle).
  - `links.odin` — clickable URLs and file paths: detection, resolution, safety (§6l).
  - `test_modes.odin` — the headless harness. **Note it is `package main`, so it ships inside the
    release exe;** moving it behind a build flag is tracked in §5.

Key mechanisms: buffer = treap keyed by byte position (O(log n)); undo = tree clone/restore;
one background job (line-count worker, cancel flag + atomics); frame = `gfx_begin_frame` (clear +
reset blend) → find/selection highlight quads → text → caret/scrollbar quads → find bar/status →
`gfx_end_frame` → `free_all(temp_allocator)`.

## 4. Locked decisions (do not relitigate without new evidence)

Odin; D3D11 + DXGI flip-model; DirectWrite-as-rasterizer → alpha/ClearType atlas → instanced
quads; handmade immediate-mode UI; **buffer = piece tree over copy-small / mmap-large**
(benchmark-validated, `bench/RESULTS.md`; treap chosen over red-black — same O(log n), less
code); plugins post-V1 (narrow C-ABI). Refuted claims recorded in `research/`.

## 5. Debt register (from the 2026-07-18 audit)

**Status: P0 and P1 below are DONE** (see §6 items 1–2 for how, and §6k for a second, larger sweep
on 2026-07-19). The list is kept because the reasoning is still the best statement of *why* these
were the priorities. Read P2 as the live list, with these amendments:

- **Arenas on VirtualAlloc: still zero implementation.** Heap plus `free_all(context.temp_allocator)`
  per frame. Either build it or amend the locked decision — do not keep citing it as though it
  describes the code.
- **`\?\` long paths: still zero implementation.** Not one in the tree.
- **Test modes ship in the release binary.** `test_modes.odin` is `package main`; the harness grew
  a lot on 2026-07-19 and release went 0.69 → 0.87 MB. Gate it behind a build flag.
- **The app redraws at vsync when idle** — no `WaitMessage` anywhere. A core burnt on a static
  screen, which also multiplies every other per-frame cost.
- **The text pipeline batches nothing** — one heap allocation, two buffer maps and one draw call
  per string, 74 call sites, several inside per-row loops. This is the prerequisite for an
  always-on line-number gutter (see `drawcount` in §6k).

Ranked. P0 = fix before building more; P1 = cheap correctness/cleanliness now; P2 = deferred but
tracked.

**P0 — live hard-rule violations (break the "never freeze/crash on huge files" promise):**
1. **Unguarded mapped-page reads on the UI thread.** `decode_to_utf8` aliases the mmap for large
   UTF-8 files (no copy), so `pt_read`/`pt_line_end`/find/nav touch mapped pages on the UI
   thread. NTFS-compressed files fault routinely; network/USB disconnect → UI freezes for the
   SMB timeout then crashes (`EXCEPTION_IN_PAGE_ERROR`). No SEH guard exists. `bench/RESULTS.md`
   called this "not optional." Fix: SEH `__try/__except` around mapped reads and/or copy-into-
   private on a worker; never fault a mapped page on the UI thread.
2. **`pt_line_end` scans to EOF uncapped, every frame** (`base/piecetable.odin`). A multi-GB
   single-line file freezes (scans gigabytes/frame). Same shape: regex `pt_collect` materializes
   the whole buffer per keystroke (`find.odin`). Fix: cap the forward scan to viewport-width +
   margin; treat "no newline within N" as a long line; gate regex by size / background it.

**P1 — real bugs + cleanups, cheap now:**
3. **Save-As path leak / inconsistent ownership** (`main.odin`/`doc.odin`): dialog returns a heap
   path, repeated saves leak, `doc.path` is sometimes borrowed (`args[1]`) sometimes heap, never
   freed. Fix: `path_owned` flag, free in `doc_close`.
4. **Dead line-index anchors** (`doc.odin`): `anchors`/`anchor_count` are written but never read
   (goto-line was removed; scrollbar is byte-proportional). Delete them (keep `line_count`).
5. **Atlas-full writes out of bounds** (`text.odin`): only logs, keeps packing past 1024². Real
   GPU corruption on a big multilingual doc. Fix: stop caching / clamp when full (real eviction
   is P2).
6. `CreateFileMappingW` result unchecked before `MapViewOfFile` (`file.odin`).
7. **Duplicated viewport-line-walk** in `doc_draw`/`doc_selection_rects`/`find_match_rects`/
   `doc_pos_at` with magic constants (`12`,`10`,`1.5`). Extract a `visible_lines` iterator +
   shared layout constants.
8. **7 headless test-modes clutter `main.odin`** (~125 lines) and pull `doc_debug_string` (leaks)
   into the product path. Move to a gated harness / `tools`.
9. **Long-line rendering**: `line_buf[2048]` truncates draw but caret/selection use true `end` →
   caret misplaced on minified JSON/logs.

**P2 — deferred, tracked (mostly locked decisions not yet needed):**
- **Arenas on VirtualAlloc + grouped lifetimes** — unimplemented (heap + `free_all(temp)`/frame).
  Fine now, but **decide before tabs**: the `&doc.idx`→worker + single-`defer doc_close` pattern
  is correct only for one never-moved Document; tabs (Documents in a reallocating array) break it.
  Establish heap-boxed, stable-address Documents + the per-document arena together, before tabs.
- **Complex-script shaping** (Arabic/Indic/ligatures via `IDWriteTextAnalyzer`) — the chosen
  follow-up to per-codepoint fallback. Related: the caret/hit-test/selection/find rects assume a
  **monospace column** (4 sites) → misaligned on CJK/emoji. Real fix needs per-glyph x positions
  (comes with shaping).
- **Color emoji** (needs a color-glyph path).
- **Command/hotkey/option codegen from a data file** — hardcoded now (VK→cmd in `window.odin`,
  cmd→action in `main.odin`). Cheap retrofit; do it with the command palette (shared registry).
- **Glyph-atlas eviction** (LRU/generational + atlas-full repack) and **reindex-on-edit** (line
  count/scrollbar drift approximately after big edits).
- **Precompiled `.cso` shaders** (drop the `d3dcompiler_47.dll` runtime dep) — before ship.
- **Per-frame allocations** in `text_draw` (make/delete per line) — reuse a scratch buffer.
- **`renderer`/`ui` layer extraction** — do it during the planned V1 UI rewrite, not before.

## 6. Roadmap (prioritized)

1. **[P0] Mapped-read safety — DONE (2026-07-18).** `doc_draw` uses `pt_line_end_cap` (bounded
   per-frame scan); mmap only for large files on a local fixed drive (network/removable/UNC copy).
   **SEH guard shipped:** a C shim (`src/platform/guarded_copy.c` → `build/guarded.obj`) wraps reads
   of the mapped original in `__try/__except`, installed into `base` via the `safe_copy` proc hook;
   `read_rec` and the index worker both route through it. On a fault the document detaches into a
   private copy, re-indexes, and flags itself RECOVERED in the status line. Proven by `newtpad
   sehtest` (catches a real page fault; process survives). **Sliver closed (2026-07-19):** search now
   runs on a worker (§6e), so nothing on the main thread scans unboundedly. Roadmap item 1 is fully
   done.
2. **[P1] Correctness + cleanliness sweep — DONE.** Save-As leak, dead anchors, atlas guard,
   `CreateFileMapping` null-check, mid-index line-count all fixed. Cleanliness landed: the four screen
   passes now share one capped `Visible_Iter` + layout helpers (killing the `12`/`10`/`1.5` magic and
   two more lingering uncapped-scan hazards in selection/find-match rects); the 8 headless test-modes
   moved to `test_modes.odin`; caret/selection/matches clip to `VISIBLE_COLS`.
3. **[feature] Monospace cell grid + fixed caret — DONE (2026-07-18).** Chose the terminal-style
   cell grid (refterm precedent) over `IDWriteTextAnalyzer` shaping — keeps "DirectWrite as rasterizer
   only" intact and suits the LTR log/csv/json/code files. `text_cell_width` classifies each codepoint
   as 0/1/2 cells (wide by measured advance, zero-width by codepoint block); the renderer advances by
   cells and the editor's caret/selection/hit-test map offset↔cell through the same primitive, so they
   agree with the glyphs. Verified by `celltest` + a CJK/kana screenshot. **Deferred:** ligatures,
   proportional fonts, RTL/bidi, tab stops, Indic spacing/nonspacing marks.
4. **[feature] Tabs + session restore** — see the sequenced plan in §Decisions (2026-07-18).
   Documents become heap-boxed (stable addresses), NOT arena-owned; full session restore incl.
   crash-safe unsaved buffers.
5. **[feature] UI chrome** — command palette (Sublime-style), status bar, filename in title,
   draggable scrollbar; commands become a runtime enumerated table (no codegen). See §Decisions.
6. **[polish] Atlas eviction, reindex-on-edit, precompiled shaders, per-frame alloc cleanup,
   renderer/ui extraction** — before/as-part-of the V1 UI rewrite.

Beyond V1 core (from the validated feature list): column/block edit, zoom, themes, Explorer
"Open with" + drag-drop + `file.txt:123`. (Go-to-line and word wrap have since landed.) Then the
V2 plugin API + first-party proofs.

**Container/archive tree viewer (post-V1, plugin-shaped)** — parked as a V2 plugin proof, not V1
scope. Open a container (JAR/ZIP, and by extension tar, .docx/.xlsx, .pak) and show a tree of its
entries; clicking one opens that member in a tab. This is the canonical exercise of the *viewer*
half of the locked C-ABI: the plugin reads a file and yields (a) a tree of named entries and (b) a
byte range/stream per entry, with the core never learning the format. Two things to keep straight:
**decompilation is not part of it** (jd-gui's `.class` → Java source would be a separate, much
heavier formatter/decompiler plugin, optional and later); and it introduces Newtpad's **first side
panel**, which cuts against Product Principle #2 — so the tree must be toggleable and present only
while a container is open, never permanent chrome.

## 6b. Decisions — Tabs + UI chrome (2026-07-18)

Preceded by a precedent-scout sweep (4coder/File Pilot/Sublime/VS Code/Notepad++ multi-doc memory,
session restore, command palette, command codegen, huge-file scrollbar) and a devil's-advocate pass
on the architecture. Two locked decisions were refined **with that DA as the new evidence**:

- **Per-document arena → deferred.** A bump arena can't own a Document: `pt.add` grows for the life
  of the doc (geometric realloc series abandoned into the arena = leak) and undo/redo snapshots are
  freed individually mid-session (an arena frees only wholesale). Tabs actually need **stable
  Document addresses** — heap-box Documents (slot array of `^Document`); keep the audited `doc_close`
  frees. Arena is used only for the immutable original-bytes copy. Memory rule updated to match.
- **Command codegen → runtime enumerated table.** `[Command_Id]Command` enumerated array (compiler
  forces a row per variant) + `#assert` discharges "declare once, register once" and collapses the
  two switches (VK→cmd in platform, cmd→action in program) without a second build-time toolchain
  step. Command rule updated to match. Rebindable keys = a runtime user-keymap overlay, not codegen.
- **Generational handles → deferred** (plain slot array): V1's single cancel-join-on-close index
  worker has no cross-frame stale-resolve bug; add handles when a job re-resolves a handle across a
  frame boundary (deferred-merge reindex, background-save-then-notify).
- **Indexer threads → capped pool (2–4) landing WITH tabs**, and restore indexes lazily (on first
  view), so reopening N tabs doesn't spawn N workers all faulting mmap pages at once.
- **Session restore = full & crash-safe:** tiny `%APPDATA%\Newtpad\session.json` (paths + cursor +
  scroll + encoding + mtime/size + active tab); one backup file per dirty/untitled buffer in
  `backups\` with an embedded first-line header, written via atomic temp+rename, snapshotted on the
  main thread (`pt_snapshot`) and serialized **off-thread** (no periodic `pt_collect` hitch);
  startup sweeps orphan `*.tmp`; clean tabs reopen lazily; missing→placeholder; changed→trust disk
  for clean, keep backup+flag for dirty; huge/network→defer mmap. Cleanly disable-able.

**Build sequence** (revised per DA; commit incrementally):
1. **Command table — DONE.** Platform emits OS-neutral `plat.Key` codes; `commands.odin` holds the
   `[Command_Id]Command` metadata table, `default_bindings` keymap (chord+context→command), and one
   `command_dispatch`. `keytest` verifies resolution + dispatch.
2. **Multi-document core + tab strip — DONE (core).** `app.odin` = slot array of `^Document` (stable
   addresses, nil slots reused), MRU-on-close, lazy-on-activate indexing. Tab commands (Ctrl+N/O/W,
   Ctrl+Tab, Ctrl+PageUp/Dn) in the table. `ui_tabs.odin` strip: click-switch, ×/middle-click close,
   elided titles, active highlight; content offset below the strip. **Deferred:** overflow
   horizontal scroll, MRU-on-hold (needs key-up), "+" new-tab button.
3. **Session restore — DONE (hot-exit).** `session.odin`: hand-rolled `session.txt` (one line/tab:
   cursor/anchor/top/wrap/enc/backup-idx/path) + per-buffer content backups for dirty/untitled;
   atomic writes, referenced-backups-before-pointer ordering, `*.tmp` startup sweep; saves on close +
   debounced ~2s autosave. **Deferred:** off-thread serialize (still main-thread `pt_collect` — hitch
   only on a very large dirty buffer), `had_bom` persistence, placeholder tab for a deleted file.
   Also **word wrap — DONE** (Alt+Z, per-doc, window-edge, live re-flow) landed alongside tabs.
4. **Command palette + fuzzy finder — DONE.** `palette.odin`: Ctrl+P overlay, prefix modes
   (none=tabs, `>`=commands, `:`=go-to-line), fzf-style scoring, `.Palette` input context, lists from
   the command table. **Deferred:** matched-char highlighting; O(n) goto line walk.
5. **Chrome — DONE.** Status bar (Ln/Col + encoding + lines/*/Wrap; line number cached + 4MB-capped
   so no unbounded per-frame scan), window title = `[*]filename - Newtpad`, draggable scrollbar
   (byte-proportional, snap to line start). **Deferred:** O(log n) line numbers via treap newline
   counts (currently capped); line-proportional scrollbar after index; matched-char highlight in
   palette.

**Tabs + UI-chrome roadmap COMPLETE (2026-07-19).** Command table · tabs (strip, MRU, session) ·
word wrap · command palette · chrome. Landed after the roadmap closed: scrolling bound to real
content (no over-scroll past the bottom), and a **custom Win11 title bar** — tabs live in the
caption alongside menu/+/window buttons, no OS caption at all. Then a live-use fix: Down on the
last line did nothing instead of clamping to the document end, so shift+Down never selected to the
end of the last line (`newtpad vnavtest` covers both wrapped and unwrapped edges).

**Next up (2026-07-19):** Wyatt is daily-driving Newtpad as his Notepad replacement, so the
priority order is (1) make it installable/usable as the default text editor — **DONE**, (2) pay
down the deferred items above, (3) fresh feature pass, (4) ship-readiness. Live use is now the main
bug source — this environment can't inject GUI input, so Wyatt's real-world passes are the signal.

## 6c. Daily-driver install (2026-07-19)

**Single instance.** A second launch used to fork a second process, and two processes race on the
one `session.txt` + shared `backups\` — last writer wins and the other's unsaved buffers are gone
(`session_save` deletes unreferenced backups). Now `platform/instance.odin` takes a session-local
named mutex; a non-owner resolves its path to absolute (the running instance has a different CWD),
hands it over via `WM_COPYDATA`, focuses that window and exits. `main` drains the queue each frame
into `app_open_path`, which activates an existing tab if the file is already open. Hand-off failure
(owner starting/stopping) falls through to running normally but **skips session save**, so the
primary keeps sole ownership. Verified: 3 launches → 1 process/3 tabs, relative paths, bare
relaunch = focus only, reopen = no duplicate.

**`install.ps1`** — builds release (**0.69 MB**), copies to `%LOCALAPPDATA%\Newtpad`, registers
`HKCU\...\Applications\newtpad.exe` (command / FriendlyAppName / DefaultIcon / SupportedTypes +
per-extension `OpenWithList`) for ~24 text-ish extensions, adds the dir to user PATH. Installing
to a separate dir from `build\` matters: a rebuild can't yank the binary out from under the running
copy. `-Uninstall` fully reverses (verified: keys, dir, PATH all gone); `-Force` stops a running
instance; `-SkipBuild` reuses `build\`. **Deliberately does not seize the default `.txt` handler** —
Win10/11 tamper-check the UserChoice hash, so "Open with → Always" is a manual one-time click per
extension. IFEO `notepad.exe` hijack was considered and rejected (system-wide HKLM).

**Known gap:** if a Newtpad instance is elevated and a launch isn't (or vice versa), UIPI blocks
the `SendMessage`, and the second launch falls through to its own non-session-owning process.

**GUI subsystem.** Release builds with `-subsystem:windows` — Odin defaults to console, so
launching the app also opened a console window. Debug stays console so `test_modes.odin` can print;
**run headless modes against the debug exe**, not the installed one.

## 6d. Regex on large files — bounded, not fixed (2026-07-19) — SUPERSEDED by §6e

Kept for the measurements (~16–19 ms/MB for `core:text/regex`, which is why no synchronous cap could
be both responsive and useful). `REGEX_SCAN_CAP` and the block-scan cap are gone; the line-aligned
block structure survives inside the worker, so the block-boundary caveat below still applies.

`recompute_regex` called `pt_collect` per keystroke, materializing the whole document to hand
`core:text/regex` a string — a full copy per keypress, and on a multi-GB file the allocation itself
is the failure. Now it scans **line-aligned blocks** (`REGEX_BLOCK` 1 MB, `REGEX_LINE_SLACK` 64 KB
to reach a line end, keeping the newline with its line), bounded by `REGEX_SCAN_CAP`. Partial
results set `find.truncated`, shown as a trailing `+` on the match counter. Cost: a pattern
spanning a block boundary won't match; line-scoped patterns are unaffected.

**This bounds the stall; it does not make regex fast.** `newtpad regextest <mb>` measures
**~16–19 ms/MB** for the Odin regex engine, so one 16 ms frame buys ~1 MB — no cap is both
responsive and useful. 8 MB was chosen as a latency budget (~130 ms worst keystroke, down from
~620 ms at a 32 MB cap). Verified correct where fully scanned (needle at 4 MB / 8 MB found; 64 MB
correctly reports truncated).

**The actual fix, still open:** run the search on a worker over a `pt_snapshot`, cancel on query
change, merge results once per frame — the locked job pattern, and the same shape as the existing
line-count indexer. The open design question is snapshot cost vs. reading a piece table that the
main thread may be editing. Literal search is chunked and fast, and regex is opt-in (Ctrl+R), so
the exposure is narrow — but it's the last live piece of roadmap item 1.

## 6e. Background search worker — DONE (2026-07-19)

Closed §6d and the last of roadmap item 1. Landed as three commits, because a devil's-advocate pass
on the spec below found that three of its mechanisms didn't hold. **The spec as written would have
shipped a use-after-free and a P0 regression** — worth remembering as evidence for why the
red-team step is not optional.

**What the DA overturned:**
- *"Clone the piece tree"* protected nothing. `piece_src` indexes `pt.add`, a `[dynamic]u8` whose
  `append` reallocs and frees the old block; cloning `root` clones nodes only. Add-sourced reads also
  bypass `safe_copy`, so the SEH guard wouldn't have caught it. The cited precedent was false too:
  `index_worker` never calls `pt_read` — it scans the immutable `original`, which is exactly why it
  needs no join. **Fix: chunk the add arena** (commit 1). Chunks are allocated once and never move,
  an insert never spans one, and `pt_view` copies the tree + chunk *headers* while aliasing the bytes.
  A view now stays valid across any number of edits, so the worker is safe by construction rather
  than by auditing join sites forever.
- *"Append to dynamic arrays, publish an atomic count"* is not a valid protocol — `append` moves the
  base pointer under the reader. **Fix:** arrays preallocated at `MAX_MATCHES`, written by index.
- *"Delete `REGEX_SCAN_CAP`"* would have un-bounded the **main thread**: `find_recompute` built
  `filter_lines` with `pt_line_start`/`pt_next_line_start`, both uncapped backward scans, and the
  8 MB cap had been bounding them by accident. A match at 2 GB in a single-line file would scan 2 GB
  backward on the main thread — re-opening the P0 roadmap item 1 had just closed. **Fix:** the worker
  computes each match's line start during its linear pass, and the merge is incremental.
- `orig_fault` was a non-atomic **global**, so a background tab's fault recovered whichever document
  was active — unmapping an innocent file and marking it modified. Pre-existing tabs bug; fixed
  per-`Piece_Table` in commit 2, which also gives the worker its own fault sink.
- `truncated` **cannot** be deleted: `MAX_MATCHES` is orthogonal to the scan cap and still saturates.
  Only `REGEX_SCAN_CAP` is gone. §6e's original done-criterion was wrong on this point.

**As built.** Buffers ≤ `SEARCH_SYNC_MAX` (256 KB) scan inline — a thread spawn plus a tree clone per
keystroke would cost more than the scan. Larger ones scan on a worker over a `pt_view`, publishing
per 256 KB block. Every edit path (`push_undo`, `apply_snapshot`) stops the worker and sets `dirty`;
the restart happens once at the next `find_merge`, so replace-all's edit-per-match loop costs one
restart, not one per match. Auto-select fires once per query, so late results never yank the
viewport. Regex churn goes to a private `Dynamic_Arena` reset per block — `core:text/regex` allocates
its `saved` arrays from the ambient allocator and never frees them, which on a 64 MB scan would both
leak and contend with the UI thread's heap lock.

**Measured (`newtpad regextest 64`):** worst keystroke **0.45 ms** (was ~130 ms at the cap), needle at
64 MB **found** (was not found at all), 200 edits mid-search survive and the needle re-finds at the
correct shifted offset. `newtpad findtest` covers the literal path's block-boundary overlap and the
worker-computed line starts.

**Known gaps, deliberately deferred:**
- **No viewport-first synchronous pass** (the spec's pass 1). Chosen to keep the concurrency change
  reviewable on its own. Consequence: on a large file, matches stream in rather than appearing
  instantly, and **filter view (Ctrl+L) shows an empty screen** until the worker finds the first
  match — it renders `filter_lines`, so a viewport-scoped pass wouldn't help it anyway; it needs a
  from-offset-0 pass that fills `rows`. This is the main thing still owed against "no frame ever
  shows emptiness."
- **A background tab's worker keeps running** after a tab switch. Harmless (it terminates on its own
  and its results merge when you return) but it burns a core.
- **`pt_view` clones the tree per restart**, i.e. per find-bar keystroke. Proportional to piece count,
  so a session with tens of thousands of scattered edits makes this expensive; debouncing the restart
  by ~50 ms of idle is the fix if it ever shows up.

<details><summary>Original spec, for the record</summary>

**Shape: viewport-first + background fill.** Two passes, because they solve different problems.
1. *Synchronous, bounded:* search the visible byte range + a margin and publish immediately, so
   highlights are never absent for a frame. This is the existing capped path, just scoped to the
   viewport instead of the file head.
2. *Worker:* full linear pass from offset 0, publishing incrementally. Linear (not viewport-outward)
   keeps `matches` sorted, which next/prev, `find_match_rects` and the filter view all assume.
   Viewport-outward would need a sort before every merge — not worth it.

**Mirror `Line_Index` (`doc.odin:172`), do not invent a second pattern.** Same fields and lifecycle:
`done`/`cancel`/`fault` as atomics, `th: ^thread.Thread`, cancel-store + join + destroy on teardown,
and `guard: bool` to route reads through the SEH shim when the buffer is a live mapping.

**The real hazard — do not skip this.** Pieces point into the original mapping *and* the append
arena, and `pt.add` reallocs as the user types, freeing the block a worker may be mid-read on. So:
- **Cancel + join the search worker before any document mutation.** Editing invalidates results
  anyway. Typing in the *find bar* doesn't mutate the document, so the common incremental-find case
  never joins — the join only costs on a real edit.
- Do **not** `pt_collect` a snapshot for the worker: that is the multi-GB copy §6d just removed.
  Clone the piece tree instead (cheap — proportional to piece count, not bytes) and read via
  `pt_read`, exactly as `index_worker` does.

**Merge once per frame, single-writer.** Worker appends to its own arrays and publishes an atomic
`count`; the main thread reads `count` with acquire semantics and consumes only indices `< count`.
Append-only + one writer means no lock. Never mutate the worker's arrays from the main thread.

**Cancel on:** query change, document edit, find close, tab switch, document close. Restart on
query change rather than trying to reuse partial results.

**Done when:** `find.truncated` and `REGEX_SCAN_CAP` are gone (the cap exists only because search was
synchronous); a 64 MB buffer keeps keystrokes at frame rate; the needle planted at the end of the
file is found. Extend `newtpad regextest <mb>` — it already plants a needle past every block
boundary and prints per-keystroke latency, so it's the natural acceptance test. Add a case that
edits the document mid-search to prove the cancel-join path.

**Worth doing first:** run `/devils-advocate` on this design before writing code. It is a
concurrency change against a buffer the main thread mutates, which is exactly where an unchallenged
plan ships a use-after-free.

</details>

## 6f. Session data loss + input fixes (2026-07-19)

**Data loss, fixed.** Launching with a file argument skipped `session_restore` entirely; the exit
save then wrote a one-tab session and **deleted every backup it didn't reference**. Leaving a dirty
scratch tab, closing, then opening any file from Explorer destroyed that scratch. The
single-instance hand-off masked it whenever an instance was already running, so it was
*intermittent*. Now: restore first, then open the argument as an extra tab (matching what the
hand-off path always did). A session that exists but fails to load also suppresses the backup
sweep — those backups belong to tabs we never adopted. `newtpad sessionlosstest <file> [old]`
reproduces both behaviours.

**Tests no longer stomp the real session.** `session_dir` honours `NEWTPAD_SESSION_DIR`; without it
`sessiontest` wrote to, and then reset, `%APPDATA%\Newtpad` — i.e. a daily driver's live tabs.

**Find swallowed every editor chord.** `resolve_key` had no context fallback, so with the find bar
open Ctrl+S/P/A/C/Z/N all resolved to `.None` — which is why Ctrl+A and Ctrl+P looked broken.
Find now falls back to the editor keymap **for ctrl/alt chords only**: an unmodified fallback would
send plain Delete to `Delete_Fwd` and the arrows to the caret, so typing a query would quietly edit
the document. The palette deliberately does not fall back at all — it is a text field first.

## 6g. Per-monitor DPI v2 (2026-07-19)

Roadmap/V1 item: "crisp per-monitor DPI as an explicit V1 quality goal." The process was
DPI-unaware, so on any non-96-DPI display the compositor bitmap-stretched the window — swapchain
included — and every glyph the ClearType atlas rasterizes was resampled to mush.

**Verified on hardware:** dragging between monitors of different DPI works. `newtpad dpitest`
covers 100–300% plus clamping from `dpi=0` to `dpi=100000`.

**What the red-team pass overturned in the design** (it found a fatal flaw *in the plan*, not the
code — the second time that has paid for itself):
- **Integer `char_w` computed program-side was a regression at every scale, including 100%.**
  `text_draw` advances its own pen by `t.char_em * px` and takes no cell-width parameter; the
  program's `col_x` grid used `text_char_width`. They agreed only because both were the same
  unrounded fraction. Rounding one side drifts them ~0.2px/column for Consolas at 16px — ~400px
  across a full `VISIBLE_COLS` line, sliding find highlights and the caret off the glyphs.
  **Fix: round inside `text_char_width` and have `text_draw` call it**, so there is one definition.
  `line_height` rounds for the same reason (at 105%, px=17 makes px*1.5 fractional → half a pixel
  of drift per row, a full row by row 40).
- **`dpi == 0` crashes.** `GetDpiForWindow` returns 0 for a bad HWND; a zero scale divides into
  `+Inf`, and Odin's f32→int on Inf is poison — negative `rows` indexing the visible-line iterator.
  Clamped to [96, 960]; `dp()` floors at 1px.
- **Atlas discard does not defuse exhaustion, it amplifies it.** Glyph area grows with scale², and
  six distinct chrome font sizes meant six independent ASCII sets — most of a 1024² atlas at 300%
  before one CJK character. Chrome collapsed to **two** sizes (`UI_PX`, `UI_SMALL_PX`). A full
  atlas no longer caches the miss (so a reset recovers) and sets a flag instead of silently
  drawing holes while the pen advances.
- **`WM_NCCREATE` DPI capture was unnecessary**; capture after `CreateWindowExW` instead, avoiding
  the `CW_USEDEFAULT` quirk and `w.hwnd` still being nil that early.
- **Virtual-screen swapchain sizing would cost ~199 MB** on triple-4K, for a bug `gfx_resize`
  already handles by growing. Dropped.

**As built.** Manifest (`src/platform/newtpad.manifest` → `.rc` → `.res` via `-resource:`) declares
`PerMonitorV2` — the manifest applies before the loader, and the API form is refused once a
manifest sets it. `build.bat` builds the `.res` beside the SEH shim under one vcvars call.
**A bare `odin build` skips `-resource:` and produces a DPI-unaware exe** — fine for headless
modes, wrong for anything you look at. `WM_DPICHANGED` updates the DPI and runs the program
callback *before* honouring the suggested rect, because that `SetWindowPos` sends a nested
`WM_SIZE` that repaints; ignoring the suggested rect breaks cursor-relative drag and risks a
recursive DPI-change cycle. Non-client metrics are computed in the platform from `w.dpi` rather
than mirrored from the program, so they're right during window creation instead of zero for a
frame. `WM_NCCALCSIZE` uses `GetSystemMetricsForDpi` — the plain call returns primary-monitor
values once per-monitor aware, so a window maximized on a second monitor inset wrongly.

Layout constants became **runtime variables** written once in `metrics_recompute` (single window →
one DPI in play, so no context object threaded through every draw call). The scrollbar's three
disagreeing widths (16 hit-test / 14+12 drawn / 18 reserved) collapsed to one `SCROLLBAR_W`;
scaled independently the reservation would have let wrapped text render under the bar.

**Still open:** `WM_GETDPISCALEDSIZE` for cell-aligned window sizing (a partial cell column at the
edge is cosmetic); atlas dimension still fixed at 1024² regardless of DPI; per-DPI atlas
coexistence deliberately not done (discard-and-rebuild instead).

**Process note:** editing source through shell `Get-Content`/`Set-Content` pipelines re-encoded
three files (UTF-8 read as CP1252, written back as UTF-8), double-encoding every non-ASCII
character and adding a BOM — the tab close glyph `×` rendered as `Ã—`. Use the editor for files
with non-ASCII content.

## 6j. UI build-out + the seam-bug class (2026-07-19)

24 commits: menu bar, settings, font selection, undo history, zoom, external-change
detection, encoding. Most of the *bugs* found were one class, which is the part worth
carrying forward.

**Shipped:** menu bar (File/Edit/View + gear, full Alt mnemonics, scrolling dropdowns,
hover-to-switch); Settings and Font as **tabs**, not full-window takeovers; font
family/style/size from a curated list; undo history panel with jump-to-state; Ctrl+/- zoom;
external-change detection + log tailing; Windows-1252 and BOM-less UTF-16 detection; filter
line numbers; palette showing shortcuts, `?` help, and clickable results.

### The seam-bug class — read this before adding a widget

Sixteen bugs this session were **the same shape: a correct, tested function fed the wrong
input, or its result read in the wrong space.** Never a wrong algorithm. Examples:

- `menu_item_at` had **no x parameter** — every point at a row's height was a live menu row
  across the whole window, so clicking into the document to dismiss a menu ran Save/Reload/Exit.
- Menu draw measured its bottom from the box origin, hit-test from the items origin (1px apart).
  A dropdown that fit exactly lost its last row on screen while it stayed clickable — Edit > Font
  was an invisible live strip.
- `metrics_recompute` scaled `TAB_STRIP_H`, then two call sites `dp()`'d the result. Scale
  squared. Invisible at 100%.
- `history_row_at` returned a screen-relative index while the panel scrolls by `top`.
- `doc_absorb_append` derived a file offset from `len(original)+appended`, which is wrong after a
  save — it re-read the user's own saved edits and duplicated them into their file.
- Hover read `win.mouse_y`, which `WM_MOUSEMOVE` only updates **while a button is held**.

**Countermeasure, now applied:** one `*_layout()` per widget, consumed by the draw *and* the
hit-test *and* the hover. `menu_dropdown_rect`, `palette_layout`, `history` (stored `rows`/`top`),
`doc_visible_rows`/`doc_filter_max_top`/`GUTTER_W`. If you add a widget, do this first.

**And test the seam, not the unit.** These tests all passed while the bugs shipped, because they
verified one function against another *that already agreed*. The menu test compared the hit-test
to `rows_fitting` — but there were **three** expressions for "rows that fit" and the draw was the
odd one out. A seam test must compare *what is drawn* to *what is clickable*, at boundary sizes,
and be verified by reintroducing the divergence and watching it fail. `menutest` does this now.

### Also fixed (live bugs, found by red-teaming designs not yet written)

- **Save failures were silent** in release: reported via `eprintfln`, but release is
  `-subsystem:windows` so stderr is discarded. Ctrl+S on a file held open by another process did
  nothing and said nothing. Now a dialog naming the cause.
- **Glyph atlas dropped glyphs silently** — text vanished while the pen advanced. A CJK page needs
  ~3000 glyphs and 1024² held 1196: reachable before any font work. **Correction (2026-07-19): only
  the status-bar clause of this actually shipped.** The growth and recycling did not work at all.
  `atlas_relieve` refuses while `t.drawing`, and its only caller was inside `text_draw`, so the
  guard was always true: the atlas stayed at 1024² for the life of the process and `ATLAS_MAX` was
  dead code. Fixed by deferring relief to `text_frame_begin`, the one point per frame with no
  instance queue live. **Why it went unnoticed for a day:** `atlastest` only exercises
  `text_atlas_fit_count`, which is arithmetic that *assumes* growth works — it passed throughout.
  `atlasgrowtest` now drives real glyphs through a real device and watches 1024 → 4096. This is the
  cleanest example in the repo of a fix that existed in the commit message and not in the binary.
- **mmap locks the file** (`ERROR_USER_MAPPED_FILE`), so a service could not rotate a log we had
  open — a silent violation of "never lock the user's file". Detaches to a private copy on any
  detected change.
- `WM_CAPTURECHANGED` never cleared `mouse_down`, so a drag interrupted by a dialog left the caret
  being dragged every frame.

### Known-good process notes

- **Never edit source through shell text round-trips.** `Get-Content`/`Set-Content` re-encoded three
  files (UTF-8 read as CP1252, written back as UTF-8), double-encoding every non-ASCII character —
  the tab close glyph `×` became `Ã—`. It was committed and rode along for two more commits. Use the
  editor for anything with non-ASCII content.
- Odin's exhaustive `switch` over an enum is a genuine safety net — adding a `Command_Id`,
  `Palette_Mode` or `Encoding` fails the build at every site that must handle it. Don't reach for
  `#partial` to silence it.

## 6h. Filter view — wanted next (Wyatt, 2026-07-19)

Filter-to-matching-lines is a V1 headline feature and the one Wyatt singled out as liking. Three
requests from live use, none urgent:

1. ~~**Line numbers in a gutter.**~~ **DONE (2026-07-19).** The search worker counts newlines during
   the pass it already makes, so the numbers are free; `filter_line_nos` parallels `filter_lines`.
   `GUTTER_W` is one value added by both `col_x` and `col_at_x`, so the drawn column and the
   hit-tested column cannot disagree. Generalising it to normal editing is now a small step.
2. **Select a line to jump to it** in the unfiltered document. Cheap: `filter_lines[i]` is already
   the byte offset of the line start, so it is a click-to-`set_cursor` plus leaving filter mode.
3. **Edit text while filtered.** Genuinely harder: edits shift every offset after them, so
   `filter_lines` and the match list both invalidate on each keystroke — the same invalidation the
   search worker already handles (`find_invalidate`), but the *view* must also stay stable so the
   line you are typing on doesn't move out from under you. Needs a design pass.

Also fixed in passing (2026-07-19): filter used to scroll to the caret-nearest match unclamped, so
a match near the end of the file showed two or three lines above a screen of empty rows.

## 6i. Requested features — BOTH SHIPPED (Wyatt, 2026-07-19)

Kept because the design notes were the plan these were built to, and the hygiene problems named
here were real. **This section said "not yet built" for two features that had already landed, and
cited a grep for `mtime`/`GetFileTime`/reload that returns plenty of hits.** Stale docs that
confidently assert absence are worse than no docs: they send the next session off to build a
second copy of something.

**1. Undo history list, Photoshop-style — DONE.** `history.odin`: a panel listing undo states with
jump-to-state, driven by `doc_history_len`/`doc_history_current`/`doc_history_goto`. Covered by
`historytest`.

The buffer supported this better than most editors would: `doc.undo` is a `[dynamic]Snapshot` and
each holds a **cloned piece tree**, so every past state was already materialised — jumping to state
*n* is `apply_snapshot` plus moving everything after it to the redo stack.

The two hygiene problems this exposed:
- **Coalescing** — `push_undo` continues a run for consecutive `.Type` edits with no caret jump, so
  typing a paragraph is not hundreds of entries.
- **`doc.undo` is capped** at `UNDO_MAX` (200), oldest evicted. That cap has a sharp edge worth
  remembering: it is why Replace All had to become a single batched entry (2026-07-19). Replacing
  more than 200 occurrences pushed the pre-replace state off the end of the stack and made the
  original unreachable by any number of Ctrl+Z. `replacetest` runs 300 matches to hold that line.

**2. Auto-reload when a file changes on disk — DONE.** `watch.odin` polls `GetFileAttributesExW`
(size + last-write) per open tab on a worker thread — never a held handle, per the never-lock rule.
`main.odin` drains the results once per frame: a clean tab that grew absorbs the append, a clean
tab that changed otherwise reloads preserving position by byte offset, and a modified tab is
flagged rather than silently discarded. mmap detaches to a private copy on any detected change,
because a mapping locks the file against a rotating writer.

Three bugs found in this area later (2026-07-19, all fixed — see §6k):
- A restored dirty tab carried no disk stamp, so the watcher reported a change within a second of
  every launch and told the user to reload away the work hot exit had just restored.
- Nothing recorded the stamp once a change was reported and not acted on, so the same change was
  re-reported every second forever, rewriting the session and every dirty buffer's backup each time.
- `doc_reload` never restarted the line index, so the status bar read "0 lines, indexing 0%" from
  the first reload onward — on the log-tailing path the feature exists for.

## 6k. Audit, then the correctness sweep (2026-07-19)

A multi-agent audit read the code, docs and goals against two bars — daily-driver completeness and
commercial ship-readiness — and every finding went through three-vote adversarial verification
(2 of 3 refutes killed it). 85 raw findings, **61 confirmed, 16 refuted**. The full report is a
working artifact, not committed; what matters is distilled here.

### Falsifiers before fixes

Two claims the plan leaned on were measured rather than assumed, and one of them was wrong:

- **`menuseam`** — would a `LAYOUT → INPUT → COMMIT → DRAW` frame resolve scroll twice and diverge?
  **Yes, in 9 of 9 scrolling cases.** Resolving with the highlighted item at *k* gives `top=0`, at
  *k+1* gives `top=1`: the hit-test would accept rows `[0,6)` while the draw painted `[1,7)`. That
  is the seam-bug class reintroduced at frame granularity by the very design meant to prevent it.
  **One layout call per frame is therefore mandatory** in the extraction. Today's code is fine — it
  resolves once inside the draw and the hit-test reads the cached `top`, deliberately one frame
  stale and self-consistent.
- **`drawcount`** — does an always-on gutter double per-frame draw calls? **No: ×1.68** at
  1280×720 (26 rows, 38 `text_draw`, 4 `quads_draw`). It approaches ×2 only as the window grows,
  since per-row work is already 68% of `text_draw`. The ordering conclusion survives — batch before
  the gutter — but on a real number.

### Fixed this session

Data loss and correctness, each with a headless test, and where there was an observable failure
mode the test was verified by reintroducing the bug and watching it fail:

- **Ctrl+S read a freed path.** `doc_save_err` clones the incoming path, then frees `doc.path` —
  which the caller's slice aliased on a re-save. The failure dialog, whose whole job is naming the
  file that would not save, was the one reading freed memory. `savepathtest` pins it by pointer
  identity, because the freed bytes usually still read back correctly and a content check would
  pass with the bug present.
- **Replace All destroyed undo.** One entry per match, against `UNDO_MAX` 200: replacing 300
  occurrences pushed 200 entries, evicted 100, and left the original unreachable by any number of
  Ctrl+Z. Now one batched entry. With the batching removed `replacetest` reports exactly that.
- **Replace with an empty string was a silent no-op** — it went through `doc_insert_text`, which
  returns early on empty input before deleting the selection.
- **The watcher fought session restore**: a restored dirty tab carried no disk stamp, so within a
  second of every launch it told the user to reload away the work hot exit had just restored; and
  an unacknowledged change was re-reported every second forever, rewriting the session and every
  backup each time. Session format 3 carries mtime/size (and `had_bom`/`eol`, which restore also
  forgot); formats 1 and 2 still read.
- **`doc_reload` never restarted the line index** — "0 lines, indexing 0%" from the first reload
  onward, on the log-tailing path the feature exists for.
- **The glyph atlas could never grow.** See the correction in §6j; this is the important one.
- **The caret column scanned the whole buffer every frame.** `doc_cursor_col` called the uncapped
  `pt_line_start`, measured at **223 ms** on a 100 MB single-line file in a debug build (the
  audit's `-o:speed` harness said 27.9 ms). Now capped and cached: 2.3 ms on a cursor move, 0 after.
  Past the cap the column is reported as unknown rather than wrong.
- **The atomic write was neither durable nor faithful.** No `FlushFileBuffers` before the rename,
  so a power loss could commit the rename with the data still in cache — strictly worse than the
  plain overwrite the scheme replaced. And `MoveFileExW` substitutes a *new* file: forcing the old
  path showed a Hidden file with an alternate data stream come back Archive with the stream gone.
  **`Zone.Identifier` is an ADS**, so every save silently stripped mark-of-the-web from downloaded
  files. Existing files now go through `ReplaceFileW`.
- **Saving as Windows-1252 silently substituted `?`.** `rune_to_cp1252` always reported this per
  character; the encoder discarded the answer. Now counted first, and the user is offered UTF-8.
- **`WM_CHAR` treated a UTF-16 code unit as a rune**, so emoji inserted two lone surrogates that
  cannot encode as valid UTF-8. **`SetFilePointer`** was compared against a value that is legal at
  every 4 GB boundary, hiding the tail of large logs. Both fixed; both rest on reasoning, not an
  executed test (see §7).
- **The GPU going away froze the editor.** `Present`'s HRESULT was discarded, so a driver update or
  TDR left a window that never updated while the loop called into dead COM objects, holding every
  unsaved buffer. Now detected; the session is saved first, the reason named, and the process
  exits. **Transparent recovery was deliberately not attempted** — a real removal cannot be
  provoked here, and an untested recovery path that runs only during a GPU fault is a worse failure
  mode than a clean exit that preserves the work.
- **`doc_open` sniffed and transcoded straight out of the mapping**, outside the SEH guard, on the
  main thread. `EXCEPTION_IN_PAGE_ERROR` is not catchable in Odin: a log rotated mid-open killed
  the process and every other tab's unsaved work.
- Smaller: the history panel's selected row indexed the active document's undo stack but lived on
  `App`, so a tab switch pointed it at the wrong buffer; `text_draw` classified cell widths against
  the UI font while drawing document text; `view_cols` had two definitions in one frame.

### What the audit got wrong, and the lesson that generalises

16 findings were refuted, including one that mattered: **"no IME support, CJK users cannot type" is
false** — `window.odin` falls through to `DefWindowProcW`, so IMM32 handles composition and commit.
The real gap is only composition-window positioning. Others: the `HWND` "leak" into the program
layer is a disclosed, deliberate seam; the atlas-warning-latches finding had accurate mechanics but
a false premise.

The generalisable lesson is the atlas: **a fix can exist in the commit message and not in the
binary, and a passing test suite will not tell you.** `atlastest` exercised arithmetic that assumed
growth worked. Prefer a check that cannot pass with the bug present.

### Deferred, with reasons

- **High-contrast support** is blocked on the colour token layer, not on effort. There are ~51
  hardcoded colour literals; routing them through `GetSysColor` *is* the UI overhaul's token work.
  A partial job would leave some elements readable and others not, which for an accessibility
  feature is worse than none because it claims support it does not deliver. It should land as the
  first consumer of the token layer.
- **Replace All still acts on the match list as it stands** — but now says so when the search was
  truncated or still running, instead of replacing a prefix in silence.
- Still open from the audit: no syntax highlighting, no line-number gutter outside filter view, no
  drag-and-drop open, Shift cannot be part of a chord, no theme/light mode, no recent files, no
  crash reporting, unsigned binary, no updater, no LICENSE, no UIA provider, no `\?\` long paths,
  no VirtualAlloc arenas, and the app still redraws at vsync when idle with no `WaitMessage`.

## 6l. Clickable links and file paths — DONE (2026-07-19)

Ctrl+click a URL or a file path in a document and go there. Built unsupervised in one pass along
with its prerequisite; `linktest` covers the parts that are testable without GUI input, and the
parts that are not are listed at the end of this section.

**As built.** Ctrl+hover underlines links in blue and turns the pointer into a hand; Ctrl+click
opens. Plain click still places the caret, so you can click into the middle of a URL to edit it.
`Open Link Under Cursor` is in the command table, so this is not mouse-only and appears in the
palette by name — deliberately left unbound, because Shift cannot currently be part of a chord
(audit finding F4) and every sensible single-modifier chord is taken.

Detected: URLs (`http`, `https`, `mailto`), absolute drive paths, UNC paths, relative paths, and
any of those with a `:123` or `:123:45` suffix.

**The prerequisite, `text_draw_spans`.** `text_draw` took one flat colour per call, so no part of a
line could be recoloured or underlined. The new primitive walks the runes and a sorted span list
together — one pass, no per-rune search — and `text_draw` is now a wrapper that passes no spans.
**Syntax highlighting (audit finding F1) wants exactly this primitive**, and should be its second
consumer. `text_span_cells` gives a byte range's cell range, for placing decorations on the same
grid the glyphs advance along.

**Safety, which is most of the design.** Text the user is reading may have been written by anyone,
so a link in it is untrusted input:

- URL schemes are **whitelisted**, not blacklisted. `search-ms:`, `ms-msdt:` (Follina) and
  `ms-officecmd:` are delivered exactly this way and the list of dangerous handlers grows.
- Paths are **stat'd first** — a broken link reaches no handler at all.
- A text-ish file opens as a tab; **anything else is revealed in Explorer**, so nothing we did
  executed it. `shell_open_url` re-checks the whitelist itself, so a caller that forgets cannot
  open a handler URL by accident.
- Relative paths anchor to the document's own folder and nothing else: no process CWD (which is
  wherever Explorer launched us), no `PATH`, and **a parent walk is refused rather than resolved**.
  An untitled buffer has no anchor, so relative links do not resolve there.

**Where links end** is the whole difficulty, and the rules are heuristics — say so rather than
pretending otherwise. Trailing sentence punctuation is trimmed; a closing bracket is kept when it
is balanced within the run, so `A_(b)` in a wiki URL survives while `(see http://x)` does not.
A token carrying a URI scheme is refused outright: `ms-msdt:/id` contains a slash and sailed
straight through the path heuristic, and although `link_resolve` would never have opened it, it
rendered **underlined** — advertising a target we would decline. A whitelist on the URL branch does
not help if the path branch picks the same string up.

**`WM_SETCURSOR` is now handled at all**, which it never was — the window class set one `IDC_ARROW`
for the life of the process. That also unblocks the I-beam over text (audit finding F5); the
plumbing is there and only the policy is missing.

### The seam this produced, and what caught it

`links_layout` is the single producer of link geometry: the underline, the glyph colouring, the
hover and the click all read the same `Link_Hit`. That is supposed to make divergence impossible —
and it still shipped a bug, until the test caught it.

The hit-test used `col_at_x`, which **rounds to the nearest caret boundary**, because that is what
click-to-place-caret needs. The underline is drawn from the cell index. Half a cell of shift meant
a link's **first cell was clickable from outside it and its last cell was not clickable at all**.
`cell_at_x` is the inside-the-cell version and now sits beside `col_at_x` with the distinction
written down.

Right function, wrong space — the §6j class exactly, in code written specifically to avoid it. It
was caught only because `linktest` compares the drawn span to the clickable span **at both edges**,
which is the shape §6j says a seam test must have. Sharing one struct was not sufficient; the two
consumers still read it through different transforms.

### Open questions for the next session

Design questions I could not settle alone, in rough priority:

1. **Word wrap is not handled.** A link spanning two visual rows currently gets one `Link_Hit` for
   whatever lands on each row, since `links_layout` scans per visual row — so the halves underline
   independently and each resolves the partial text, which usually fails. Wrapped rows need the
   link detected on the *logical* line and then split into per-row segments. Filter view is
   excluded for the same reason (it renders `filter_lines` through a different path).
2. **Should a link inside a selection still activate on Ctrl+click, or does selection win?**
   Currently the link wins, because the check runs before the caret handling.
3. **Should the underline show without Ctrl?** It is Ctrl-gated now, which keeps the document clean
   and costs nothing, but it also means links are invisible until you know to hold Ctrl. VS Code
   has the same property and people do not discover it.
4. **No binding for `Open Link Under Cursor`.** Worth one once Shift-in-chords lands (F4).
5. **`link_activate` jumps to a column in bytes, not cells** — wrong for a CJK line. Nothing points
   at it today because compiler output is ASCII, but it is inconsistent with the rest of the grid.
6. **Extension list is duplicated.** `TEXT_EXTS` in `links.odin` restates what `install.ps1`
   registers. Two lists that must agree and nothing enforces it.
7. Whether directories should open as a *tab* listing contents rather than revealing in Explorer —
   that edges toward the parked container/tree viewer (§6), so it was left alone.

**Not covered by any test, because this environment cannot inject input:** the Ctrl+hover cursor
change, the actual Ctrl+click gesture, and whether the underline lands where it looks like it
should on screen. `linktest` covers detection, resolution, the scheme whitelist, and the
drawn-vs-clickable span agreement. **A live pass is owed on this feature specifically** — try a
wrapped line, a CJK line, and a path with spaces.

## 7. Build environment (Windows, this machine)

- **`build.bat` is the one build script.** `build.bat` = debug, **console subsystem** so the
  headless modes can print. `build.bat release` = `-o:speed -subsystem:windows`, the shipped exe.
  Append `run` to launch. Both embed `newtpad.res` (the per-monitor-v2 DPI manifest) and link
  `guarded.obj` (the SEH shim). **A bare `odin build` omits both.** If you edit `guarded_copy.c` or
  `newtpad.manifest`, delete the matching file in `build\` to force a rebuild.
- Sizes as of 2026-07-19: **debug ~1.3 MB, release 0.90 MB** (target 2-3 MB). Release grew from
  0.69 MB when the headless harness expanded — `test_modes.odin` is `package main`, so every test
  mode ships inside the customer's binary. Tracked in §5.
- Tests: `odin test src\base -collection:src=src` (20 cases: encoding, line-nav, piece tree,
  lossy-encoding detection).
- **Headless test modes** (debug exe). **Set `NEWTPAD_SESSION_DIR` to a temp dir first** or the
  session modes write to, and reset, the real store under `%APPDATA%\Newtpad`:
  - Rendering / platform: `sehtest`, `dpitest`, `atlastest`, `atlasgrowtest`, `devicelosttest`,
    `celltest`, `drawcount <file>`
  - UI surfaces: `menutest`, `menuseam`, `palettetest`, `settingstest`, `fonttest`, `historytest`,
    `linktest`
  - Document / editing: `vnavtest`, `wraptest`, `colperftest <mb>`, `replacetest`, `findtest`,
    `regextest <mb>`
  - Files / session: `savepathtest <dir>`, `savefailtest <dir>`, `resavetest <file>`,
    `diskstamptest`, `sessiontest`, `sessionlosstest <file> [old]`, `watchtest <dir>`
  - File-argument modes: `<file> count|keytest|findtest|filtertest|repltest|edittest|seltest|savetest`
  - Two are **falsifiers**, not regression tests — they measure a claim rather than guard a
    behaviour: `menuseam` (does resolving scroll twice in one frame diverge? yes, in every case
    where the dropdown does not fit) and `drawcount` (what does a frame actually cost? 26 rows,
    38 `text_draw`, 4 `quads_draw`).
- **Odin** `dev-2026-07a` at `C:\Users\Wyatt\odin\dist`, on user PATH. **MSVC** from VS Community
  2026 (v18). **Windows SDK** `10.0.28000.0` (had to be added via the VS Installer — VS shipped
  without the C++ desktop SDK; Odin needs the import libs, else "Windows SDK not found").
- `src/{base,platform,renderer,ui,program}` — one Odin package per dir (Odin compiles a package
  at once → free "unity build"). `program` is `package main`. `renderer` and `ui` are still stubs.
- **This environment cannot inject GUI keyboard or mouse input.** Interactive behaviour is verified
  by headless modes plus screenshots, and every claim about what happens when you click something
  is an inference from source. A live pass by Wyatt is still worth it per feature. Two fixes
  currently rest on reasoning rather than an executed test: non-BMP input (`WM_CHAR` surrogate
  pairing) and the 4 GB `SetFilePointerEx` boundary.

## 8. Working agreements

- **Ask the 2-4 outcome-changing questions first; never rubber-stamp.** Surface locked-decision
  impacts explicitly.
- Distill Wyatt's source material into `research/`; keep the report the single source of truth.
- Flag verified vs judgment; run devil's-advocate on significant designs before recommending.
- **Git identity:** every commit/push/merge under Wyatt Guethlein's account only — no third-party
  attribution anywhere. History reads like a human engineer's: incremental logical commits, plain
  imperative messages.
