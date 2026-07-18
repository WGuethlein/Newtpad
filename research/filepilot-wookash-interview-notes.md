# File Pilot — notes from the Wookash Podcast interview (Vjekoslav Krajačić)

Source: Wookash Podcast episode with the File Pilot author (transcript in [additional-transcripts/wookash.txt](../additional-transcripts/wookash.txt)).
Complements the [BSC 2025 engine talk notes](filepilot-engine-talk-notes.md) — this interview covers product design, indexing details, and Windows API pitfalls the talk skipped.

## The five core design rules (his words, applied to every part of the program)

1. **Speed** — not just file operations: clicking, opening tabs, splitting panes, previews — all instant. #1 compliment, "to the point of confusion."
2. **Modern, minimal UI** — content gets the screen, not chrome. Inspirations: **Sublime Text** (editors) and **Obsidian** (note-taking). Command palette as the universal access point (searchable, rebindable, from Sublime ~2010).
3. **Simplicity** — clean UX with powerful features summoned when needed; batch rename replacing whole walls of toggle-laden UI.
4. **Personalization — but only at the edges** — dev decides core design; expose only subjective bits (font, colors, spacing, animations on/off, hotkeys). "Huge options windows = a program without strong design."
5. **Small standalone executable** — the size isn't the point; it *reflects* the absence of complexity/dependencies. "When I clicked install and it booted instantly" — users notice.

## Indexing & data details (new beyond the talk)

- Core indexing algorithm is only **a couple hundred lines**; everything on demand, in memory, no disk index (may add one later for HDDs/network drives).
- **Cache with eviction**: folder index kept ~1 minute after you leave it, then evicted.
- **Prefetching**: parent folder + folders under selection + their thumbnails/stats indexed before you click — goal: "not a single frame displaying emptiness." No flicker = users notice.
- **Viewport-only metadata streaming**: dates/sizes/icons/thumbnails fetched on background threads only for visible files; loading everything up front is what freezes Explorer in media folders. (If a sort requires full metadata, it still fetches on worker threads.)
- Index layout: tightly packed structs (name, size, dates, flags) in **chained memory blocks of ~1–10 MB**; separate lists of small references used for sorting/filtering.
- Every Windows fetch (icons, thumbnails — "five or six different thumbnail APIs, none performant") gets a cache with an eviction scheme on top.

## External change detection — a trap to avoid

Currently uses the Win32 directory-change-notification API, which **holds a handle to the folder — so other programs can't delete it**. He's moving to polling the folder's last-modified time and reload-and-merge on change, keeping no handles.
**Newtpad relevance (critical):** an editor must never hold a handle that blocks other programs from writing/renaming/deleting the file. Open, read/map, and share generously; detect external modification by timestamp polling (or a notification scheme that doesn't pin the file) and offer reload — including for the mmapped large-file path, which needs care since mapping pins content.

## Windows API pain map (his ranked list)

- **IContextMenu (right-click)**: "worst API I've ever worked with," beyond repair; he fetches items but renders his own popup (searchable, bookmarkable) — requiring separate testing on Win10 vs Win11; he resorted to reading leaked Windows Server source for answers. (Newtpad: keep our context menu 100% our own; only *optionally* shell out to Explorer's.)
- **Drag and drop**: second-worst, "occasionally glitches" but stable now.
- **IFileOperation** (copy/move/delete): works but old and single-threaded; he plans to replace it. (Low relevance for an editor.)
- **Long paths**: default 260-char MAX_PATH still the reality; the `LongPathsEnabled` registry value needs admin — he exposes it as an option. (Newtpad: use `\\?\` prefixed wide paths internally so we handle long paths regardless of the registry setting.)

## Batch rename = a multi-cursor spec

F2 on a multi-selection enters rename mode on **all** files at once: one cursor per entry, arrow keys move all cursors, changes visible live, insertable unique IDs/dates, and **each entry has its own copy/paste buffer**. Explicitly modeled on Sublime's multi-cursor. This is the closest thing to a written spec for Newtpad's V2 multi-cursor (including the per-cursor clipboard detail, which most editors get wrong).

## Development practice

- **UI was fully scrapped and rewritten once (maybe twice)**: first version deliberately hardcoded/basic to discover use cases; rewrite took ~2–3 months, informed by a 1–2 week reading spree (Ryan Fleury's UI series heavily used). Plan for this: V1 UI is a draft.
- "Non-pessimized code" (Casey Muratori's term): performance mostly comes from *not doing unnecessary work*, not from optimization passes. Profiled hard in one period (algorithmic wins), now only before releases. Very little SIMD.
- Whole codebase compiles from scratch in ~2 s → fast iteration is a feature of the codebase itself.
- Tightly integrated systems because he owns them all: strings on arenas, arenas on threads, UI on renderer.
- Toolchain: Vim + ctags (C11, no LSP), **RemedyBG + RAD Debugger** (MSVC PDBs), **Spall** profiler (handmade, cheap, easy to integrate — he ships profiler-enabled builds to users to debug slow machines).
- AI use: search-engine replacement + small snippets, always validated against official docs.
- Works with the internet literally unplugged for hours daily; checks community 2×/day.

## Business model (v1 plans as of the interview)

- Free beta + optional pre-orders funded continued full-time work.
- V1: fully paid, free trial, **perpetual licenses, no subscriptions, no feature-gating**; per-user across multiple devices; prices published early and held stable.
- Started because the market already proved people pay for file managers despite a free default — same logic applies to Notepad replacements (Sublime, UltraEdit, EmEditor all sell against free defaults).

## Newtpad takeaways ranked (what this interview adds)

1. **Never lock the user's file** — share-everything opens, timestamp-based external-change detection, reload-and-merge. Table stakes for a log viewer.
2. **Viewport-first everything** — lex/highlight/measure only visible lines + margin on background threads; prefetch around the viewport; "no frame shows emptiness."
3. Adopt the five design rules nearly verbatim as Newtpad's product principles.
4. The batch-rename mechanics are the multi-cursor spec (per-cursor clipboard included).
5. Long paths via `\\?\` internally; don't depend on the registry opt-in.
6. Budget one UI rewrite: ship V1 on a deliberately simple hardcoded UI, rewrite once real use cases exist (Ryan Fleury's UI series is the study material).
7. Cache + eviction over every OS call we repeat (font enumeration, file dialogs, icons).
8. Pricing: perpetual license, trial, no subscription — matches the audience's values and File Pilot's proven results.
9. Tooling for the build: RemedyBG / RAD Debugger + Spall profiler; keep full-rebuild seconds-fast forever.
