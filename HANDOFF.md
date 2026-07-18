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

### Piece table over mmapped original + append arena — PENDING BENCHMARK
The one major decision not locked. Piece table: O(1) open of multi-GB files (original stays mmapped, untouched), free undo, streams on save, arena-friendly. But the extracted (unverified-round) benchmarks say gap buffers beat ropes ~7× on whole-buffer search (35 ms vs 250 ms over 1 GB), and 4coder chose gap buffer for simplicity. **Week-1 task: build both minimal cores, benchmark typing latency / 1 GB regex search / multi-GB open, then lock.** A hybrid (gap buffer under a size threshold, piece table above) is a live option.

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

1. **Buffer benchmark** (blocks core architecture) — see §3.
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
2. Week-1 buffer benchmark (piece table vs gap buffer minimal cores) → lock the decision with data.
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

**What works:** `build.bat` produces a ~630 KB `newtpad.exe`; it opens a 1280×720 window, creates a D3D11 device + DXGI flip-model swapchain (`B8G8R8A8_UNORM`, `FLIP_DISCARD`, 2 buffers, BGRA_SUPPORT), handles resize (ResizeBuffers + RTV recreate), and clears to slate at vsync. Win32 is isolated in `src/platform/window.odin`; D3D11/COM in `src/platform/gfx.odin`; both use the Odin `core:sys/windows` + `vendor:directx/{d3d11,dxgi}` bindings. COM methods are called via Odin's `->` operator; `D3D11CreateDeviceAndSwapChain` is the one free foreign proc.

**Immediate next sub-steps (renderer layer):** vertex/pixel shaders (compile via `vendor:directx/d3d_compiler` or ship precompiled), a vertex buffer + instance buffer, input layout, and one instanced draw of a colored quad — then the glyph atlas. After that, the §8 build sequence resumes (buffer benchmark, DirectWrite spike).
