# File Pilot engine — notes from Vjekoslav Krajačić's BSC 2025 talk

Source: "File Pilot: Inside the Engine" — Better Software Conference 2025 (YouTube, July 2025).
Condensed from the full transcript. These are the author's own statements about how File Pilot is built.

## Headline facts

- Written in **C** (not C++), ~**100,000 lines**, his **first native program** (15 yrs prior experience, ex-Unity game dev in Croatia).
- **~2 MB standalone exe**, no install required; optional installer is embedded in the exe (just copies the file).
- **Unity build** (single translation unit), one big C file per module; **2.5 s full debug rebuild** via a small batch script — faster than incremental linking. Fast iteration was critical to motivation/experimentation.
- ~**10% of code is generated**: a rebuild prepass emits typedefs + function declarations (so code can be written in any order within a module), plus hotkey/option/command-palette registration generated from plain txt files (avoids patching 5 places per new command).
- ~3.5 years of development; solo.

## Architecture (module layers)

1. **Base layer** — custom standard-library replacement (C stdlib considered useless/outdated). Short int typedefs, utility macros, sorting, byte/align helpers; memcpy/memset point at Windows versions.
2. **Platform layer** — Windows-only for now: files, thumbnails, windows, input. All Win32/COM ugliness isolated here. Porting = "write another box"; program/renderer/UI layers are platform-clean.
3. **Program layer** — >half the code. Builds UI, dispatches user requests to platform layer.
4. **Renderer** — very simple: **draws only colored quads**. OpenGL today (only API he knew); **rewriting to DirectX** — OpenGL driver bugs cause black-screen issues he can't fix. (Lesson: start on D3D11 on Windows.)
5. **UI framework** — fully from scratch, **immediate-mode API**, rewritten 2–3 times during development. Output of UI = list of render commands. This is the thing users notice most (responsiveness).
6. A handful of trusted single-header libraries.

## Memory strategy (his stated #1 reason for speed and stability)

- **Arenas / linear allocators** everywhere, backed by VirtualAlloc/VirtualFree; both chained and large-contiguous variants; commit page-by-page, bigger chunks when a big load is known (e.g., indexing).
- **Grouped lifetimes**: permanent (main state) / transient (frame arenas, per-popup/per-view arenas) / scratch (function-local, nestable). Dozens of arenas total instead of tens of thousands of mallocs.
- End-of-life options: **leak into the arena** (fine for transient data — e.g., renamed file's old string just stays until the folder arena is released; whole-drive index ≈ 1 MB per 200 GB), **split allocations** (separate arena for the array vs. elements), **recycle** via free-list pools.
- Batch allocation is why indexing is fast: thousands of files per frame pushed into one arena, no per-file malloc.
- **Zero-is-initialization** ("make the zero value useful"): every struct works uninitialized — arenas, arrays, strings, builders. Plus C designated initializers (zero everything else) and macro-based optional/named function args.
- Events (hotkeys, clicks) are **queued to the frame arena** and processed at one point in the frame — no heavy logic inside UI building or input handling.
- Stability outcome: arenas "eliminated most memory bugs"; remaining crashes mostly third-party/driver/kernel.

## Strings

- **Length-based strings (ptr + len), UTF-8 internally**; convert to null-terminated wide chars only at the platform boundary. Strings are immutable after creation; StringBuilder for construction; all arena-backed, no special ownership rules.
- Flag-parameterized find/split helpers designed so slicing works without if-checks on failure (return count instead of 0, pre-increment index, etc.).

## Data structures

- Macro-based **linked lists** (stack/queue/dlist — adapted from Ryan Fleury's, as is much of the arena discipline; see rfleury.com). Nodes live in arenas so cache locality is fine; a node can belong to multiple lists via named link fields.
- **Arrays**: macro-generic, header embedded at the front of the allocation (debugger-friendly, no hidden header à la stb).
- **Maps**: flat array of key/value pairs + hash table pointing into it — indexable, iterable without hashing, freed with the arena.

## Text rendering

- **DirectWrite used only as a glyph rasterizer**; glyphs then drawn as regular textured quads by his renderer. Batching still on his TODO list.

## Search = filtering (speed as a first-order effect)

- No traditional search. Indexes millions of files in seconds using **old Win32 enumeration APIs** (Windows caches aggressively); plans to read the **NTFS Master File Table** directly for near-instant indexing.
- Everything sits in flat arrays of pointers in memory; per-keystroke **brute-force filtering** — no clever index structure. "One reason it's so fast is I'm not trying to do anything too smart."
- Flatten-folder-hierarchy + filter = real-time whole-drive search. The speed *enabled* the feature — his core thesis: speed opens design space ("speed is the first-order effect").

## Threading

- Thread pool with background jobs. Pattern: **copy everything a job needs, job works in its own memory, results copied back to main memory once per frame**. Minimize synchronization points; abort via a flag workers poll. UI thread only builds UI and handles input; all I/O is background. No fork/join architecture.

## Startup

- Most boot time = OpenGL context init + Windows showing the window. He **preloads fonts/icons/files in parallel** during that window so content is ready at first paint.

## Extensibility philosophy (directly relevant to Newtpad's plugin plan)

- Fought against plugins, now conceding a **deliberately narrow API: file-format previewers only** (e.g., webp). Explicitly refuses generic scripting — "opening doors to a lot of stuff I don't want to deal with." Right-click context menu horror stories (third-party shell extensions initializing on the main thread) are his cautionary tale about hosting others' code.

## Product/business lessons

- 100k+ downloads with zero paid ads (Twitter build-in-public, HN front page, YouTube reviews).
- Priced high deliberately ("reflect the engineering effort") — already repaid his debts and sustains development. "You can give something away free, but if it doesn't stand out people won't take it."
- **No DRM, fully offline, no license checks** — pirates were never going to pay. Trial + nag popup planned.
- Code signing barely helps with SmartScreen/antivirus false positives ("worst money ever spent") — expect this pain for any small unknown exe.
- Config philosophy: the program should work right out of the box; every added option signals a leak in core design. Command palette (hidden until summoned, filters everything, rebindable) instead of chrome.
