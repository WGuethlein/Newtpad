# Newtpad — Handoff & State

Rewritten 2026-07-18 after a mid-project audit (devil's-advocate + code review). This is the
living state doc: what Newtpad is, what works now, how it's built, the debt we're carrying, and
the roadmap. The compressed constitution — principles, hard rules, locked decisions, git
conventions — is kept locally, outside the repo. Research corpus in [research/](research/);
buffer benchmark in [bench/](bench/).

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

Verified: 13 `odin test` cases (encoding, line-nav, piece tree); headless mode dispatch
(`newtpad <file> <count|edittest|savetest|seltest|findtest|repltest|filtertest>`); screenshots.
Wyatt confirmed live: open/save/undo/mouse-select.

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
- `program/` (frame loop + document): `main.odin` (loop, input dispatch, render, headless test
  modes), `doc.odin` (Document: buffer + cursor + selection + undo + viewport + line index +
  filter), `find.odin` (find/replace/regex/filter).

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
   sehtest` (catches a real page fault; process survives). **Remaining sliver:** regex still
   materializes the whole buffer (`find.odin`) — the read is guarded now (won't crash) but can still
   stall; size-gate/background it before regex-on-huge-files is comfortable.
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

## 6d. Regex on large files — bounded, not fixed (2026-07-19)

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

## 6e. NEXT TASK — background the search worker (spec, 2026-07-19)

Approved approach; closes §6d and the last of roadmap item 1. Implement this first.

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

## 7. Build environment (Windows, this machine)

- **Odin** `dev-2026-07a` at `C:\Users\Wyatt\odin\dist`, on user PATH. **MSVC** from VS Community
  2026 (v18). **Windows SDK** `10.0.28000.0` (had to be added via the VS Installer — VS shipped
  without the C++ desktop SDK; Odin needs the import libs, else "Windows SDK not found").
- `src/{base,platform,renderer,ui,program}` — one Odin package per dir (Odin compiles a package
  at once → free "unity build"). `program` is `package main`.
- `build.bat` — the one build script: `odin build src\program -out:build\newtpad.exe -debug
  -collection:src=src` (append `run` to launch). Imports use the `src:` collection. Tests:
  `odin test src\base -collection:src=src`. Debug exe ~950 KB (well under the 2-3 MB target).
- Note: this environment can't inject GUI keyboard/focus, so interactive features are verified via
  headless test-modes + screenshots; a live pass by Wyatt is still worth it per feature.

## 8. Working agreements

- **Ask the 2-4 outcome-changing questions first; never rubber-stamp.** Surface locked-decision
  impacts explicitly.
- Distill Wyatt's source material into `research/`; keep the report the single source of truth.
- Flag verified vs judgment; run devil's-advocate on significant designs before recommending.
- **Git identity:** every commit/push/merge under Wyatt Guethlein's account only — no third-party
  attribution anywhere. History reads like a human engineer's: incremental logical commits, plain
  imperative messages.
