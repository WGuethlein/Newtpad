# Newtpad — Deep Research Report

**A Windows-first, ultra-fast, ultra-small notepad replacement in the spirit of File Pilot.**
Compiled 2026-07-18 from a 102-agent research workflow (20 sources fetched, 97 claims extracted, 25 adversarially verified: 23 confirmed / 2 refuted) plus the full BSC 2025 File Pilot engine talk transcript ([notes](filepilot-engine-talk-notes.md)).

Constraints from Wyatt: shipped product; scope closer to Windows Notepad than Notepad++; fully handmade (own UI, own text pipeline, own lexers); narrow plugin support (formatters/viewers) after V1; Wyatt directs the work.

---

## 1. Why File Pilot–class apps are fast and small (verified)

Every claim below survived 3-vote adversarial verification unless noted.

- **Systems language, no frameworks, no CRT.** File Pilot is C (with a little C++), essentially zero external libraries (stb_sprintf aside), and does not even link the C runtime — the author reimplemented what he needed. ~100k lines, full debug rebuild in 2.5 s via unity build. [filepilot.handmade.network, BSC 2025 talk, Hanselminutes]
- **Footprint:** ~2 MB single exe (1.8 MB at the 2025 talk → 2.45 MB at v0.8.1), no packing, installer embedded in the exe, only **14 DLL dependencies and ~312 imported OS functions** (Scott Hanselman's independent binary analysis). A "fits on a floppy" claim was **refuted 0-3** — the honest floor is ~2 MB. [talk, Hanselminutes]
- **Rendering:** fully custom immediate-mode GUI on a custom GPU renderer drawing only colored/textured quads — "it is a game effectively, it's a canvas." Text = DirectWrite used *only* as a glyph rasterizer, glyphs pushed as GPU quads. **Author is abandoning OpenGL for DirectX due to unfixable driver bugs** → a new project should start on D3D11. [talk, HN thread, Hanselminutes]
- **Memory:** arena/linear allocators directly on VirtualAlloc/VirtualFree — reserve big ranges, commit page-by-page (bigger chunks for known-large workloads), bump-allocate, free whole grouped lifetimes at once (permanent / frame / scratch). The author credits this as the single biggest factor in both speed and stability. [talk]
- **Startup:** boot time is dominated by GPU context init + window creation, not app code; File Pilot hides asset loading (fonts, icons, files) behind that window. Lesson: your startup floor is the OS/GPU layer — overlap everything with it. [talk]
- **RemedyBG (commercial handmade debugger)** confirms the pattern with a shortcut: only two dependencies — Dear ImGui for UI, Intel XED for decoding. Immediate-mode GPU UI is proven for paid production Windows tools. (We're going fully handmade, but this is the fallback if the custom UI stalls.) [remedybg.handmade.network, itch.io]
- **refterm + Windows Terminal AtlasEngine** validate the exact text pipeline: DirectWrite rasterizes a glyph **once** on cache miss into a GPU atlas; D3D11 + a simple HLSL shader composes everything. Microsoft shipped this same architecture as Windows Terminal's default renderer after refterm demonstrated it — production proof you don't need a custom font rasterizer to be fast. Caveats: refterm is GPL-2.0 (copy the pattern, never the code) and monospace-grid. [github.com/cmuratori/refterm, microsoft/terminal PR #11623]
- **Zed's GPUI** is the modern high-end reference: ~8.33 ms/frame budget, all UI reduced to a few primitives with specialized shaders, OS-level shaping, alpha-only glyph atlas, single instanced draw call — **and Zed's shipped Windows port runs exactly on DirectWrite + D3D11**, so this stack is demonstrated practice on Windows. [zed.dev/blog/videogame, zed.dev/blog/windows-progress-report]

## 2. Recommended build path

### Language: **Odin** (primary recommendation), C as the conservative alternative

All four candidate paths were verified open: Odin ships **official thin D3D11/D3D12/DXGI vendor bindings** ("nearly the same as writing it in native C++"); Zig reaches the whole pipeline via zigwin32's generated modules (though a "complete bindings, nothing hand-written" claim was **refuted 1-2** — gaps exist); Rust has the Zed/GPUI precedent; C has File Pilot/refterm/RemedyBG. [odin-lang.org/news/major-graphics-apis, github.com/odin-lang/Odin vendor/directx, github.com/marlersoft/zigwin32]

Why Odin over C: the File Pilot author spent significant effort building things Odin has natively — the talk is practically a spec for Odin's defaults:

| File Pilot hand-built in C | Odin built-in |
|---|---|
| Length-based UTF-8 strings | `string` is ptr+len UTF-8 |
| Zero-is-initialization discipline | Everything zero-initialized by language rule |
| Designated initializers + macro named-args | Native struct literals + named/default proc args |
| Codegen prepass for declaration order | No forward-declaration requirement |
| Hand-rolled arenas + context plumbing | `mem.Arena` + implicit `context.allocator`/`temp_allocator` |
| Macro-generic arrays/maps | Real parametric polymorphism, slices, `map` |
| Custom base layer replacing libc | `core:` library designed around these idioms |

Odin also matches the goals: fast compiles, small binaries, no GC/runtime, C ABI export for the future plugin boundary. Costs to accept: smaller ecosystem/tooling than C (debugging works via PDB + VS/RemedyBG/RAD Debugger, but less battle-tested), and **DirectWrite/COM bindings will be partly hand-rolled** (vendor:directx covers D3D11/DXGI; DirectWrite's COM vtables we declare ourselves — bounded, one-time work; File Pilot's "little C++" is likely exactly this seam). If that risk profile feels wrong, C with the File Pilot playbook (plus its codegen prepass) is the proven fallback; the architecture below is identical either way. Rust is *not* recommended here: it fights arena-style lifetimes, compiles slowly, and its advantage (Zed's reference code) is a retained-tree framework shaped nothing like our handmade core.

### Renderer: **D3D11 + DXGI flip-model swapchain**

Skip OpenGL entirely (File Pilot's stated regret; verified). D3D11 over D3D12: we draw quads, not a AAA scene — D3D11 is dramatically simpler, still fully supported, and is what Windows Terminal's AtlasEngine and Zed-on-Windows use. One vertex/pixel shader pair for solid quads, one for atlas-textured glyph quads is nearly the whole renderer.

### Text pipeline: **DirectWrite as rasterizer only → cached glyph atlas → instanced quads**

The triple-validated recipe (File Pilot + refterm/AtlasEngine + Zed): on glyph-cache miss, DirectWrite (IDWriteFontFace::GetGlyphRunOutline/rasterize via IDWriteGlyphRunAnalysis) renders the glyph into an alpha-only GPU atlas; frames then draw pure atlas quads in one instanced call. Cache shaping results per line; ClearType/grayscale AA per user setting. Proportional fonts are fine (Zed does it); monospace fast-path optional.

### Text buffer: **piece table over a memory-mapped original + append buffer**

⚠️ *Sourced but not adversarially verified this round — from fetched primary sources, flagged as an open question.*

- VS Code replaced its line array (which used ~20× file size in memory) with a **piece tree** — piece table with pieces indexed by a red-black tree, optimized for line lookup. [code.visualstudio.com/blogs/2018/03/23/text-buffer-reimplementation]
- 4coder chose a **gap buffer** — "the least sophisticated optimizations to achieve very good performance." [4coder.handmade.network]
- Gap buffers beat ropes ~7× on whole-buffer search (35 ms vs 250 ms over 1 GB) but require the whole file resident. [coredumped.dev]
- Zed uses a rope on a SumTree (B+ tree with summaries) — powerful, but built for collaborative editing we don't need. [zed.dev/blog/zed-decoded-rope-sumtree]

**Why piece table for Newtpad:** it's the only structure where *opening a 10 GB log is O(1)* — the original file stays memory-mapped and untouched; edits append to an arena-backed add buffer; a piece is just (which-buffer, offset, length). Undo falls out for free (pieces are immutable), save-as streams pieces, and the arena memory model fits perfectly. Keep a cached line-start index per piece (VS Code's key optimization) for scroll/goto-line. A gap buffer is simpler but caps us at RAM-sized files — that breaks a headline feature. Decision to validate with a prototype benchmark in week 1.

### Memory, layers, iteration speed

Adopt the File Pilot blueprint directly (all verified):
- **Layers:** `base` (custom stdlib-ish core) → `platform` (Win32: window, input, files, clipboard, DirectWrite seam) → `renderer` (D3D11 quads) → `ui` (immediate mode) → `program` (editor logic). Platform code never leaks upward.
- **Arenas:** permanent (app state), per-document (buffer + metadata, freed on close), per-frame (UI + queued events, cleared each frame), scratch (function-local). Free-list pools for recycled same-size objects.
- **Events queued to frame arena**, processed at one point per frame; no logic inside UI building.
- **Threading:** thread pool; jobs copy their inputs, work in private memory, results merged once per frame; abort via polled flag. No locks in the hot path.
- **Startup:** overlap font/session/file preload with D3D11 device + window creation.
- **Build:** unity build, single small build script, target <5 s debug rebuilds (Odin gives this by default).
- **Codegen (txt-file-driven):** command palette entries, hotkeys, and options declared once in a data file, generated into registration code — File Pilot's approach; keeps "add a command" a one-line change.

### Plugin boundary (designed now, shipped post-V1)

File Pilot's author independently converged on Wyatt's exact plan: extensibility **narrowly limited to format previewers/formatters, never generic scripting** (verified from talk Q&A). His context-menu horror stories (third-party code initializing on the main thread) dictate the rules:
- **C ABI, versioned struct of function pointers** — callable from any language, stable across compilers. Odin exports this natively.
- Two plugin kinds only: **formatter** (bytes in → bytes out, e.g. JSON pretty-print) and **viewer** (bytes in → simple draw-list/text-model out, e.g. Markdown preview, hex view).
- Plugins run **on worker threads (never the UI thread), with timeouts**; a misbehaving plugin degrades to "plugin failed," never a hang. Consider out-of-process later if the ecosystem grows.
- Core stays fully handmade; first-party "plugins" (JSON, Markdown) ship in-exe behind the same API to prove the interface.

## 3. Feature research: what Notepad lacks

⚠️ *The demand-side claims did not survive verification this round (the one fetched forum source: Notepad++ users hitting large-file slowness and hunting alternatives — community.notepad-plus-plus.org). Prioritization below is therefore judgment + the verified File Pilot product lessons, not cited user research. Marked as an open question.*

### V1 (MVP — "Notepad, but it never makes you leave")

| Feature | Notes |
|---|---|
| Instant open, single ~2–3 MB portable exe | The identity feature. No install; optional embedded installer à la File Pilot. |
| Multi-GB files open instantly | mmap + piece table; read-only until first edit. This is the #1 "Notepad/Notepad++ fails me" moment. |
| Encoding detection + conversion | UTF-8/UTF-16 LE/BE/ANSI, BOM handling, CRLF/LF detect + convert in status bar. Internally always UTF-8. |
| Tabs + session restore | Modern Notepad has both; users now expect unsaved-scratch-tab persistence. |
| Find/replace with regex + filter-as-you-type | File Pilot's thesis applied to text: incremental match highlighting as you type. |
| Unlimited undo | Free with piece table; survives save. |
| Syntax highlighting, hand-rolled lexers | txt/json/env/ini/md/csv/log/xml/yaml/toml + C-like catch-all. Line-incremental, no tree-sitter dependency in V1. |
| Command palette | Hidden until summoned; every command filterable + rebindable (generated from the data file). |
| Go to line, word wrap, zoom, light/dark theme | Table stakes. Minimal options — "too many options = leakage in core design" (verified File Pilot philosophy). |
| Explorer integration | "Open with," drag-drop, `newtpad file.txt:123` line syntax. |

### V2 (the plugin release)

- **Plugin API ships** with first-party proof plugins: JSON pretty-print/validate/minify, Markdown preview, hex viewer (auto-offered for binary files).
- Multi-cursor + column/block selection.
- .env awareness (highlight keys, optional value masking for screen shares).
- Large-log mode: tail/follow, filter-to-matching-lines view.
- CSV column-aware view (alignment/virtual columns via viewer plugin).

### V3+ / explicitly out of scope

- LSP, project trees, integrated terminal, git — that's an IDE; Notepad-first identity dies here.
- Tree-sitter: revisit only if plugin authors demand grammar-driven highlighting; philosophically compatible (C library) but binary-size/startup cost unmeasured (open question).
- Cross-platform: the layer split keeps the door open ("write another box"), but Windows-first until V2+.

### Ship-a-product realities (verified from File Pilot's experience)

- **Code signing won't stop SmartScreen** false positives for a small unknown exe ("worst money ever spent") — budget reputation-building time, consider EV cert, warn early users.
- No DRM/online checks: offline license key, honor-system trial — pirates were never customers.
- Quality-over-cheap pricing worked: File Pilot repaid the author's debts from beta pre-orders at "spicy" prices.

## 3b. Addendum — Wookash Podcast interview (added 2026-07-18)

A second primary source ([notes](filepilot-wookash-interview-notes.md)) supplied after the verification round; treat as author-self-reported. It adds four requirements to the plan above:

1. **Never lock the user's file.** File Pilot's directory-watch API holds a folder handle that blocks other programs from deleting it — the author is moving to timestamp polling + reload-and-merge. For an editor this is table stakes: share-everything opens, external-change detection without pinning the file, careful handling of the mmap large-file path (mapping pins content).
2. **Viewport-first work.** File Pilot fetches metadata/thumbnails only for visible items on background threads, and prefetches around the selection so "not a single frame displays emptiness." Newtpad: lex/highlight/measure visible lines + margin first; everything else is background fill.
3. **Product principles = his five design rules:** speed everywhere; minimal modern UI (Sublime/Obsidian as north stars, command palette as universal access); simplicity; personalization only at the edges; small standalone exe as a *reflection* of low complexity.
4. **Multi-cursor spec:** File Pilot's batch rename (one cursor per entry, live preview, per-cursor copy/paste buffers) is the concrete UX model for Newtpad's V2 multi-cursor.

Also noted: plan for one full UI rewrite (his V1 UI was a deliberate throwaway; rewrite took 2–3 months, informed by Ryan Fleury's UI series); long paths via `\\?\` internally rather than the admin-only registry opt-in; RemedyBG/RAD Debugger + Spall profiler as the toolchain; perpetual-license/no-subscription pricing proven viable.

## 4. Open questions (carried forward)

1. **Buffer benchmark:** piece table vs gap buffer under Newtpad's real workloads (typing latency, 1 GB regex search, multi-GB open) — build both cores in week 1 and measure; the search-speed gap (gap buffer 7× faster) may argue for a hybrid (piece table for huge files, gap buffer under a threshold).
2. **Demand-side validation:** no user-research source survived verification; V1 list should be sanity-checked against r/software, HN "notepad replacement" threads, and Notepad++ feature-request rankings before feature freeze.
3. **Tree-sitter cost:** measure binary/startup impact before ever admitting it into the plugin story.
4. **File Pilot's D3D migration status:** whether their OpenGL→DirectX rewrite shipped and changed the startup profile (informs how much D3D11 context init to expect; check post-v0.8 releases).

## 5. Source index

Primary: BSC 2025 talk (full transcript), filepilot.handmade.network, filepilot.tech, Hanselminutes interview (podscan.fm), remedybg.handmade.network, github.com/cmuratori/refterm, microsoft/terminal PR #11623, zed.dev engineering blog (×3), odin-lang.org, github.com/odin-lang/Odin, github.com/marlersoft/zigwin32, code.visualstudio.com text-buffer blog, 4coder.handmade.network.
Secondary/community: HN File Pilot thread, coredumped.dev gap-buffer-vs-rope benchmarks, cdacamar editor-data-structures benchmarks, min-sized-rust, Notepad++ community forum, handmade.network D3D11 text-rendering forum.

Refuted during verification (do not repeat): "File Pilot fits on a floppy" (0-3); "zigwin32 is complete, no hand-written declarations needed" (1-2).
