# Newtpad — Session Handoff

Written 2026-07-18, handing off from a the author desktop session (deep research phase) to local tooling terminal (build phase). Read this fully before substantial work; PROJECT-RULES is the compressed version.

## 1. What Newtpad is

Wyatt's project: a **notepad replacement for Windows** that opens any text file natively — the text-editor analog of File Pilot (filepilot.tech). Identity: **ultra-fast, ultra-small, fully handmade, shipped commercial product.**

Wyatt's constraints, stated explicitly:
- **Shipped product** (like File Pilot itself — polish, portable exe, licensing all matter).
- Scope **closer to Windows Notepad than Notepad++** — but with **working plugin support post-V1** for code/markdown formatting and viewing.
- **Fully handmade**: own UI, own text pipeline, own lexers. Chosen over "pragmatic" and "ship fastest" options when offered.
- Wyatt directs the work ("I won't be doing the coding manually, you will — go with your recommendation").
- **Standing instruction: always ask clarifying questions before big work; never rubber-stamp.**

## 2. What happened so far

1. Deep-research workflow ran (102 agents, 20 sources, 97 claims extracted, 25 adversarially verified: 23 confirmed / 2 refuted). Full report: [research/newtpad-research-report.md](research/newtpad-research-report.md).
2. Wyatt supplied two primary-source transcripts of the File Pilot author (Vjekoslav Krajačić):
   - BSC 2025 "Inside the Engine" talk → [research/filepilot-engine-talk-notes.md](research/filepilot-engine-talk-notes.md) (engine: arenas, layers, strings, unity build, codegen, threading).
   - Wookash Podcast interview → [research/filepilot-wookash-interview-notes.md](research/filepilot-wookash-interview-notes.md) (product: five design rules, viewport-first streaming, file-locking trap, batch-rename-as-multi-cursor-spec, Windows API pain map). Raw transcript: [additional-transcripts/wookash.txt](additional-transcripts/wookash.txt).
3. ~~No code exists yet. Not a git repo yet.~~ **Build phase started 2026-07-18** — see §10 for toolchain + current state.

## 3. Decisions and *why* (the part PROJECT-RULES compresses away)

### Odin over C/Zig/Rust
The BSC talk is practically a spec for Odin's defaults: everything File Pilot's author hand-built in C (length-based UTF-8 strings, zero-is-initialization, designated initializers, arena allocators, declaration-order freedom via a codegen prepass) is native in Odin. Odin ships official thin D3D11/DXGI vendor bindings ("nearly the same as writing native C++"). Verified: all four languages have open paths; Rust rejected (fights arena lifetimes, slow compiles, its precedent Zed/GPUI is a retained-tree framework shaped nothing like our core); Zig viable but zigwin32's "complete bindings" claim was *refuted* in verification (1-2). **Known cost:** DirectWrite COM vtables must be hand-declared in Odin (bounded one-time work — File Pilot's "little C++" is likely exactly this seam). **Fallback:** C with the full File Pilot playbook if Odin tooling disappoints in practice.

### D3D11, never OpenGL
File Pilot's author's single clearest regret — an unfixable OpenGL driver black-screen bug shipped since his first release; he's rewriting to DirectX. D3D11 over D3D12 because we draw quads, not AAA scenes; Windows Terminal AtlasEngine and Zed-on-Windows both use D3D11.

### DirectWrite as rasterizer only → glyph atlas → instanced quads
Triple-validated: File Pilot (talk), refterm + Microsoft's AtlasEngine (shipped as Windows Terminal's default renderer), Zed's GPUI (alpha-only atlas, OS shaping, single instanced draw, 8.33 ms budget; shipped Windows port on DirectWrite + D3D11). **refterm is GPL-2.0 — study the pattern, never copy code.**

### Piece tree over the original + append arena — BENCHMARK-VALIDATED & LOCKED (2026-07-18)
Was the one open decision; now settled with data (`bench/`, full numbers in `bench/RESULTS.md`). Decision: **piece TREE (RB-balanced) over the original, copying small files into the add-arena and mmapping large ones; mapped reads are SEH-guarded and run on worker threads.**

Why (measured on real 10/100/1024 MB files, Odin `-o:speed`):
- Only mmap opens multi-GB instantly (O(1), ~0.1 ms at any size) with ~0 private memory. Gap/naive are O(filesize): ~0.57 ms/MB open + the whole file committed to private RAM (1 GB → 0.6 s + 1 GB; 8 GB → ~5 s + 8 GB). That disqualifies gap/naive for the "opens anything instantly, multi-GB" identity. Gap's only win — 0 ns local typing vs piece's 2.6 µs — is imperceptible.
- Fragmentation spike: a linear piece *list* is O(n²) insert (dead) → must be a piece *tree*; whole-buffer scan is unaffected by fragmentation (1.03×), so filter-as-you-type over a piece table is fine.
- Never-lock: **verified** — with the file mmapped, another program can delete AND rename it (modern NTFS POSIX-unlink, Win10 1709+), and our view keeps reading the unlinked data without crashing. The old "mapping blocks delete" claim is false on target Windows. (Caveat: verify FAT32/USB/SMB; treat those as copy-on-open.)

Mandatory mitigations (adversarial pass, `bench/RESULTS.md`), to bake into the real impl:
- **SEH `__try/__except`-guarded mapped reads on worker threads only** — never fault a mapped page on the UI thread (truncate/shrink-underneath and NTFS-*compressed* files fault routinely; network-drive stalls block the faulting thread for the SMB timeout). Not `AddVectoredExceptionHandler` (global, can't cleanly resume, would see D3D/DWrite COM exceptions).
- **Empty/zero-byte floor case** (`CreateFileMapping` fails on 0 bytes → copy path).
- **Remap-on-grow protocol** for live-appended files (feeds the V2 log-tail feature).
- **Separate background/cancellable line-index subsystem** — the "instant open" *product* promise depends on it (scrollbar extent, go-to-line, viewport line layout), not on the buffer structure; the 1 GB single-line file is its acceptance test.
- Define save + undo uniformly across the copy-small / mmap-large boundary.

### Plugin architecture (designed now, shipped V2)
File Pilot's author independently converged on Wyatt's exact plan and his context-menu horror stories (third-party code initializing on his main thread, users blaming him for hangs) define the rules: **C-ABI versioned function-pointer struct; two plugin kinds only (formatter: bytes→bytes; viewer: bytes→draw-list/text-model); worker threads, never UI thread; timeouts; misbehavior degrades to "plugin failed," never a hang; no generic scripting, ever.** First-party JSON/Markdown tools ship in-exe behind the same API to prove it.

### Refuted claims — do not repeat
- "File Pilot fits on a floppy" — refuted 0-3. Honest floor ~2 MB (1.8→2.45 MB across versions; 14 DLL deps, ~312 imports per Hanselman's binary analysis).
- "zigwin32 is complete, nothing hand-written needed" — refuted 1-2.

## 4. Feature plan

**Validated 2026-07-18** against the demand-side research round that was previously missing (six-lens sweep: narrative switch posts, Reddit/forum recs, competitor pages, incumbent wishlists, large-file/log crowd, everyday scratchpad users — full findings in [research/demand-side-feature-research.md](research/demand-side-feature-research.md)). The research strongly *validated* the core identity (no-AI / no-account / instant / tiny / plain-text is a marketable tailwind — users are actively fleeing Win11 Notepad's AI+bloat) and surfaced six convergent gaps. Wyatt's scope decisions on those gaps are folded in below.

**V1 (MVP):**
- instant open; single portable ~2–3 MB exe
- multi-GB files via mmap
- **fast, never-freeze search *inside* huge files** — a first-order, benchmarked promise, not a footnote (users sharply separate "opens the 30 GB file" from "searches near EOF without a freeze/crash"; this is what actually drove people off Notepad++). Interacts with the pending buffer benchmark (§3).
- encoding detect/convert (UTF-8/16/ANSI, BOM, CRLF/LF)
- tabs + session restore (incl. unsaved scratch tabs) — **with a clean disable toggle** (a vocal cohort wants restore *off*; forcing it reproduces the exact complaint driving people to us)
- **first-class scratch buffer** (NEW headline primitive): always-there on open with cursor restored; **continuous autosave to a recoverable, discoverable local store; never a save-nag for untitled scratch content** — while carefully avoiding Microsoft's silent-data-loss and hidden-plaintext-artifact mistakes (named files still prompt/save normally)
- regex find/replace with filter-as-you-type
- **filter-to-matching-lines** (pulled from V2): collapse a file to just the matches, ideally a separate pane preserving ±N context — the log/sysadmin crowd's single most-praised feature; reuses the find regex engine, so incremental cost is UI not core
- **column/block (rectangular) editing** (pulled from V2): the strip-log-timestamps / prefix-many-lines workflow. Full multi-cursor stays V2.
- hand-rolled incremental lexers (txt/json/env/ini/md/csv/log/xml/yaml/toml + C-like)
- command palette (generated from data file, rebindable)
- go-to-line, word wrap, zoom, themes
- **crisp per-monitor DPI / multi-monitor scaling** as an explicit V1 quality goal (highest-engagement Notepad++ complaint; a near-free D3D11/DXGI win if built in from the start, costly to retrofit)
- Explorer "Open with" + drag-drop + `file.txt:123` syntax

**V2:** plugin API ships with first-party proofs (JSON pretty-print/validate, **XML pretty-print**, **CSV column view** (sort/filter/dedupe), Markdown preview, hex viewer) — first-party structured-data reformat is deliberately held here to prove the plugin boundary, since V1 already *highlights* these formats; **full multi-cursor** (spec = File Pilot's batch rename: cursor per entry, live preview, **per-cursor copy/paste buffers**); .env value masking; log tail/follow (a *minimal* follow-the-tail is nearly free atop the mandatory grow-aware mmap, but low-latency follow is the bar — ship it right or not at all).

**Out of scope (identity-protecting):** LSP, project trees, integrated terminal, git integration, **AI of any kind (not even opt-in), telemetry, account/cloud requirement** (the anti-features the target market most loudly rejects — omitting them is a positioning asset). Tree-sitter only if plugin demand forces it, after measuring binary/startup cost.

**Fast-follow candidates (considered, not committed — do not relitigate as V1):** file compare/diff, sort/dedupe lines, keyword→color highlighting rules (cheap given the renderer; loved by log users), scrollbar match marks, macros/record-replay, code folding, bookmarks, global-hotkey/always-on-top quick-capture, Heynote-style in-buffer block separators, chord hotkeys, print/preview, spellcheck. Rationale and evidence strength for each in the research note (§C).

## 5. Ship-a-product realities (verified from File Pilot's experience)

- Code signing barely helps SmartScreen false positives for small unknown exes ("worst money ever spent") — budget reputation time; consider EV cert; warn early users.
- Pricing: perpetual license, free trial, no subscriptions, no feature gating, offline (no license server). Quality-over-cheap worked — beta pre-orders repaid the author's debts.
- Startup: overlap font/session/file preload with D3D11 device + window creation; the OS/GPU layer sets the startup floor, not app code.
- Expect one full UI rewrite: V1 UI is a deliberate draft; his rewrite took 2–3 months informed by Ryan Fleury's UI series (read before designing ours: rfleury.com).
- Toolchain that fits: RemedyBG / RAD Debugger (MSVC PDBs — Odin emits these), Spall profiler (handmade, integrable, can ship in builds to users).

## 6. Open questions (ranked)

1. ~~Buffer benchmark~~ **DONE 2026-07-18** — piece tree over copy-small/mmap-large, validated with data (§3, bench/RESULTS.md).
2. **Demand-side validation** of V1 list before feature freeze.
3. **DirectWrite-from-Odin spike** — hand-declare the minimal COM surface (IDWriteFactory → IDWriteFontFace → IDWriteGlyphRunAnalysis) early; it's the recommendation's main risk.
4. Tree-sitter cost measurement — only if/when plugin story demands it.
5. Has File Pilot's D3D migration shipped post-v0.8 (informs expected D3D11 init cost)?

## 7. FIRST SESSION AGENDA — feature research with Wyatt (his explicit request)

**Wyatt has said the first thing he wants to do in the terminal is go over and research important features — before any building.** Do not start scaffolding or benchmarks until this has happened. Shape of that session:

1. Walk the current V1/V2/out-of-scope list (§4) with him item by item — it is *judgment, not evidence* (the demand-side research round didn't survive verification), so treat every line as challengeable.
2. Run the demand-side research that's still missing: `/delegate` pattern 2 (multi-modal sweep — user threads on HN/Reddit/Notepad++ forums, competitor feature/pricing pages for EmEditor/UltraEdit/Sublime/Notepad++, "why I switched editors" posts), plus `precedent-scout` agents for features where mechanism matters (large-file handling claims, session restore behaviors, encoding handling).
3. Use `/ideate` on the features Wyatt cares most about; `/devils-advocate` on anything that threatens scope creep or the five principles.
4. Ask Wyatt the outcome-changing questions as they surface (per standing instruction) — e.g., which V1 features are identity vs negotiable, what he'd cut first, what his own daily notepad pain points are (he's a primary user).
5. End state: a validated, Wyatt-approved V1 feature list recorded here (replacing §4's caveat), then and only then move to the build sequence below.

## 8. Suggested build sequence (after the feature session; not yet approved — ask first)

1. ✅ **DONE (2026-07-18).** `git init`; scaffold layer skeleton, build script, D3D11 window clearing to a color. Next sub-step: the actual instanced colored quad (shaders + vertex/instance buffers).
2. ✅ **DONE (2026-07-18).** Buffer benchmark → locked piece tree over copy-small/mmap-large (§3, bench/RESULTS.md).
3. DirectWrite COM spike → glyph atlas → draw "Hello, 世界" proportionally.
4. Read-only file viewing end-to-end (mmap, viewport-first layout, scrolling) — the "opens anything instantly" demo.
5. Editing (piece table mutations, undo), then save pipeline (encodings, atomic write, never-lock rules).
6. Find/filter-as-you-type; command palette + data-file codegen; tabs/session.

## 9. Working agreements with Wyatt (carry these forward)

- **Ask questions first — never rubber-stamp.** When a request is big, surface the 2–4 outcome-changing decisions via structured questions before running.
- Wyatt supplies source material (transcripts etc.) — distill into `research/` notes and fold deltas into the report; keep the report the single source of truth.
- Flag which claims are verified vs judgment. Use the devil's advocate skill on significant designs before presenting them as recommendations.
- Wyatt's answers to the original scoping questions: touched all candidate languages remotely, the author codes → the author's recommendation stands; shipped product; Notepad-like with post-V1 plugins; fully handmade.
- **Git identity:** every commit/push/merge is under Wyatt Guethlein's account only — no third-party attribution anywhere (no Co-Authored-By, no "Generated with" footers; `.local-settings.json` enforces `includeCoAuthoredBy: false`). History should read like a human engineer's: incremental logical commits, plain imperative messages, normal branching. See "Git conventions" in PROJECT-RULES.

## 10. Build environment & current state (as of 2026-07-18)

**Toolchain (Windows, this machine):**
- **Odin** `dev-2026-07a` installed at `C:\Users\Wyatt\odin\dist`, on user PATH. Prebuilt release (bundles LLVM). `odin root` = that dir.
- **MSVC** from Visual Studio Community 2026 (v18, `C:\Program Files\Microsoft Visual Studio\18\Community`), toolset 14.51.
- **Windows SDK** `10.0.28000.0` — was **not** installed with VS initially (Unity bootstrapper skipped the C++ desktop SDK); added later via the VS Installer. Odin needs it for the import libs (`kernel32/user32/d3d11/dxgi/d3dcompiler.lib`). If setting up a fresh machine, install the "Windows 11 SDK" component or the "Desktop development with C++" workload first, or Odin fails with "Windows SDK not found."
- Note: VS-Installer `modify` needs elevation from the start; `--wait` is not a valid flag on this installer version. Manual install via the VS Installer GUI is the reliable path.

**Repo layout:**
- `src/{base,platform,renderer,ui,program}` — one Odin package per layer (Odin compiles a package at once → free "unity build"). `program` is `package main`.
- `build.bat` — the one build script: `odin build src\program -out:build\newtpad.exe -debug -collection:src=src`. Append `run` to launch. Output in `build/` (gitignored).
- Imports use the `src:` collection (e.g. `import plat "src:platform"`).

**TEXT RENDERING WORKS (2026-07-18) - supersedes the "next sub-steps" note below.**
DirectWrite-from-Odin is de-risked; text renders end to end (verified by screenshot).
- `src/platform/dwrite.odin` hand-declares the minimal DirectWrite COM (IDWriteFactory / IDWriteFontFace / IDWriteGlyphRunAnalysis). Vtable method ORDER is taken from the on-disk SDK `dwrite.h` (10.0.28000.0), NOT MS Learn (whose method tables are alphabetized and would call the wrong slot). Unused slots are `rawptr` placeholders to keep offsets correct.
- `src/platform/text.odin`: loads a font face (Consolas), reads metrics for advances, rasterizes glyphs to ClearType coverage, packs into a shared `R8G8B8A8` atlas with a shelf packer, caches by `(glyph, px)`, draws cached glyphs as instanced quads. ClearType via DUAL-SOURCE blend (PS emits `SV_Target1` = per-channel coverage; blend `SRC1_COLOR`/`INV_SRC1_COLOR`), so result = ink*coverage + dst*(1-coverage). `gfx_begin_frame` now resets to opaque blend so per-pass state never leaks frames.
- Spike learning: glyph bounds can be negative (an 'A' returned `L-1`), so the atlas uses the returned bearings; never assume origin (0,0).

**Flagged follow-ups (from the devil's-advocate pass - address before they bite):**
1. SHAPING + FONT FALLBACK: current text uses `GetGlyphIndices` (cmap 1:1), NOT shaping - no CJK / combining marks / ligatures / bidi / emoji yet. Next real text milestone = `IDWriteTextAnalyzer` shaping + `IDWriteFontFallback`. The glyph-run is already fed by an explicit index list so this slots in without reworking the raster/atlas.
2. ATLAS EVICTION: atlas is grow-only (violates the PROJECT-RULES "caches need eviction" rule). Add LRU/generational + atlas-full handling before ship. `atlas_pack` currently just logs when full.
3. PER-FRAME GLYPH WORK: `text_draw` calls `GetGlyphIndices` per char per frame and rasterizes on first sight synchronously - fine now, must be bounded/backgrounded for large files (viewport-first rule).
4. `quads.odin` (solid rects) is currently unused by `main` but kept for UI backgrounds/cursor/selection.

**Next options:** (a) shaping + font fallback (real multilingual text); (b) resume the build sequence with the week-1 buffer benchmark (piece table vs gap buffer), now higher-stakes since fast never-freeze search-in-huge-files is a first-order V1 promise; (c) read-only file viewing (mmap -> viewport layout -> scroll) toward the "opens anything instantly" demo.

**What works:** `build.bat` produces a ~635 KB `newtpad.exe`; it opens a 1280×720 window, creates a D3D11 device + DXGI flip-model swapchain (`B8G8R8A8_UNORM`, `FLIP_DISCARD`, 2 buffers, BGRA_SUPPORT), handles resize (ResizeBuffers + RTV recreate), and clears to slate at vsync. On top of that, an **instanced quad pipeline** (`src/platform/quads.odin`) draws arbitrary pixel-space rectangles in a single `DrawInstanced` call: embedded HLSL compiled at startup via `vendor:directx/d3d_compiler`, a dynamic per-instance buffer (`Quad{pos,size,color}`), an `SV_VertexID` triangle-strip quad (no vertex buffer), and a screen-size constant buffer. Frame is split `gfx_begin_frame` (clear) → draws → `gfx_end_frame` (present). Win32 is isolated in `window.odin`, all D3D11/COM in `gfx.odin`+`quads.odin`; COM methods called via Odin's `->`.

**Architecture decision (2026-07-18):** the GPU quad pipeline lives in **platform** (honoring the locked "all Win32/COM isolated in platform" rule). The `renderer` package will be the *CPU-side* glyph→quad builder + atlas packer with no COM. Revisit if this split chafes once text lands.

**Shader note:** HLSL is compiled at runtime for dev speed → **d3dcompiler_47.dll** runtime dependency. Locked plan: switch to precompiled `.cso` bytecode (fxc/dxc at build time, embedded via `#load`) before V1 ships to drop that dep.

**NOTE:** the "What works / Architecture / Shader / Immediate next" paragraphs just
above are historical (pre-text-rendering). Current state is the newer blocks higher
in section 10 plus this one.

**FILE VIEWER WORKS (2026-07-18) — read-only, instant multi-GB.**
`newtpad.exe [path] [scrollLines]` opens a real file and renders it.
- `src/platform/file.odin`: `file_open_readonly` — copies files < 16 MB into private
  memory, mmaps larger ones (share-everything, never-lock). A 1 GB file opens in
  ~0.1 ms (mmap); whole-app cold start on it is ~267 ms.
- `src/base/encoding.odin` + `lines.odin` (pure, tested in `base_test.odin`, `odin test src/base`):
  BOM-detect UTF-8 / UTF-16 LE/BE, decode UTF-16 (incl. surrogate pairs) to internal
  UTF-8; line navigation over bytes.
- `src/program/doc.odin`: byte-offset viewport that walks line breaks ON DEMAND — no
  full index needed to render, which is why open is instant at any size. Visible lines
  draw through the ClearType `text_draw`. `window.odin` queues wheel / arrows / Page /
  Home-End scroll to per-frame state.
- Verified by screenshot: HANDOFF.md renders and scrolls (top vs pre-scrolled to §4).

**BACKGROUND LINE INDEX DONE (2026-07-18).** The viewport renders via scan-on-demand
(instant, no index), and a background worker thread now builds a SPARSE line index (a
line-start anchor every 1024 lines + exact total count) published via atomics; anchors[]
is pre-sized so it never reallocates, so the main thread reads it lock-free. This is the
project's first background job (`src/program/doc.odin`: `Line_Index`, `index_worker`).
It gives an exact scrollbar (track + thumb drawn with the solid-quad pipeline, now in
use) and a status line ("line X of N, indexing %"), and `doc_goto_line` jumps to the
nearest anchor then scans the remainder. Verified headless (`newtpad <file> count`): exact
line counts (HANDOFF.md 189 = newline count; 1 GB file 18,198,529 lines, ~0.3 s in a
release build, off the UI thread). Threading gotchas fixed: start the worker only after
the Document is at its final address (it holds `&doc.idx`), and only clamp goto to the
total once the index is DONE (a partial count clamps toward 0).

**Deferred:** horizontal scroll / wrap (long lines clamped to 2000 chars); a real UI
chrome (draggable scrollbar, filename header, tabs); interactive goto (needs a text-input
box). Memory note: the sparse index pre-allocates `total/(8*1024)` ints (~1 MB per GB,
graceful overflow guard) — a block-list would trim that further later.

**Next options:** (a) editing — the real RB piece-tree + insert/undo per the locked buffer
decision (turns viewer into editor); (b) shaping + font fallback for multilingual text;
(c) UI chrome — draggable scrollbar / tabs / status bar via the solid-quad pipeline;
(d) find / filter-as-you-type over the buffer (a V1 headline feature).
