# Newtpad — Handoff & State

Rewritten 2026-07-18 after a mid-project audit (devil's-advocate + code review). This is the
living state doc: what Newtpad is, what works now, how it's built, the debt we're carrying, and
the roadmap. PROJECT-RULES is the compressed constitution (principles, hard rules, locked decisions,
git conventions). Research corpus in [research/](research/); buffer benchmark in [bench/](bench/).

## 1. What Newtpad is

Wyatt's project: a **notepad replacement for Windows** — the text-editor analog of File Pilot
(filepilot.tech). Identity: **ultra-fast, ultra-small, fully handmade, shipped commercial
product.** Scope closer to Windows Notepad than Notepad++, with working plugins post-V1. the author
writes the code; Wyatt directs. Standing rule: **ask the outcome-changing questions before
substantial work; never rubber-stamp.**

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

## 4. Locked decisions (see PROJECT-RULES; do not relitigate without new evidence)

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

Beyond V1 core (from the validated feature list, PROJECT-RULES/§4-of-old): column/block edit,
go-to-line, word wrap, zoom, themes, Explorer "Open with" + drag-drop + `file.txt:123`; then the
V2 plugin API + first-party proofs.

## 6b. Decisions — Tabs + UI chrome (2026-07-18)

Preceded by a precedent-scout sweep (4coder/File Pilot/Sublime/VS Code/Notepad++ multi-doc memory,
session restore, command palette, command codegen, huge-file scrollbar) and a devil's-advocate pass
on the architecture. Two locked decisions were refined **with that DA as the new evidence**:

- **Per-document arena → deferred.** A bump arena can't own a Document: `pt.add` grows for the life
  of the doc (geometric realloc series abandoned into the arena = leak) and undo/redo snapshots are
  freed individually mid-session (an arena frees only wholesale). Tabs actually need **stable
  Document addresses** — heap-box Documents (slot array of `^Document`); keep the audited `doc_close`
  frees. Arena is used only for the immutable original-bytes copy. PROJECT-RULES Memory row updated.
- **Command codegen → runtime enumerated table.** `[Command_Id]Command` enumerated array (compiler
  forces a row per variant) + `#assert` discharges "declare once, register once" and collapses the
  two switches (VK→cmd in platform, cmd→action in program) without a second build-time toolchain
  step. PROJECT-RULES rule updated. Rebindable keys = a runtime user-keymap overlay, not codegen.
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
1. **Command table** — collapse the two input switches into `[Command_Id]Command`; keybind lookup +
   dispatch read it. Foundation for tab commands and the palette; no new user feature.
2. **Multi-document core + tab strip** — slot array of `^Document`, active doc, tab strip (switch/
   close/new, MRU Ctrl+Tab, overflow shrink-then-scroll), tab commands into the table, indexer cap.
3. **Session restore (full)** — session.json + per-buffer backups + off-thread serialize + restore
   reconciliation + `*.tmp` sweep.
4. **Command palette + fuzzy finder** — one overlay; fzf-style scoring in a single-alloc matcher;
   prefix modes (none=files/tabs, `>`=commands, `:`=go-to-line); lists from the command table.
5. **Chrome** — status bar (line/col/enc/progress), filename in window title, draggable scrollbar
   (byte-proportional while indexing, line-proportional after; drag→byte→snap to next line start).

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
  attribution anywhere (`.local-settings.json` enforces `includeCoAuthoredBy: false`). History
  reads like a human engineer's: incremental logical commits, plain imperative messages. See
  PROJECT-RULES "Git conventions."
