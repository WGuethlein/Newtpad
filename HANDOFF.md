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

**How work gets done here is written down: [docs/development-loop.md](docs/development-loop.md).**
Read it before starting a batch. It is the loop batches 1–4 (§6s–§6w) converged on — ask the
outcome-changing questions, spec, plan, a fresh subagent per task, a review after every task, a
whole-branch review at the end, sabotage every test, then HANDOFF entry → version bump → merge →
`install.ps1`. It also carries the two bug *shapes* this codebase keeps producing and the
operational traps that have each cost a session real time. Unlike `CLAUDE.md`, it is committed.

### Where things stand — read this first (2026-07-26)

**Batch 6 is merged; v0.16.0 tagged, released and installed.** `v0.13.0` through `v0.16.0` are all
tagged with the exe attached. The installed binary is v0.16.0 — **1.01 MB, down from 1.43 MB**,
because the headless harness no longer ships inside it (§6z).

**The road to V1 is sequenced in §6aa (2026-07-26), which supersedes §6u's batch table.** The V1
feature list is *done* — five of research §G's six V1 decisions shipped and the sixth was deferred
to V2 — so what remains is hard-rule debt, one batch of promises from CLAUDE.md's own principles,
and distribution. The UI overhaul moved to V2; a free public beta precedes the paid V1.

**Batch 7 is merged; v0.17.0.** Tab stops, `\\?\` long paths, CSS/SQL line comments, and the five
findings batch 6 carried — see §6ab. Two of its five planned items turned out **not to be real**
(glyph-atlas eviction was refuted by measurement, and tabs were already 4 cells, not 1), which is
worth reading before trusting any other "X is missing" claim in this file.

**The installed binary is still v0.16.0.** Batch 7 merged under Wyatt's overnight policy: merge, do
not `install.ps1`. Run it after the live pass in §6ab's "Owed".

**Live-pass checklist for everything since v0.16.0:
[docs/live-pass-batches-7-11.md](docs/live-pass-batches-7-11.md).** Five batches, ~120 commits, none
of it verified against real GUI input. Section 1 is the six that would be worst to ship broken.

**Batch 11 is merged; v0.20.0 — ship-readiness, the last batch before the beta.** Check for Updates,
a crash-report path, LICENSE (PolyForm Internal Use 1.0.0), and an Inno Setup installer. §6af ends
with the **beta checklist**: what is buildable, and what is Wyatt's. Two items there block a beta —
the license grants a hobbyist tester nothing, and the installer has never been compiled.

**Batch 10 is merged; v0.19.0 — the last feature batch before the beta.** Sort lines, remove
duplicate lines, and `rules.txt` keyword colouring. §6ae's "what it got wrong" is the useful half:
a column rectangle silently escalated a sort to the whole file, and the colour rules' own seeded
header promised something the precedence order does not deliver on `.log` files.

**Batch 9 is merged; v0.18.0.** Keys and navigation — `keys.txt` rebinding, bookmarks, scrollbar
match marks, filter click-to-jump, and filter's first paint. See §6ad, whose "what this batch got
wrong" section is the useful half: six tests that could not fail, two correct functions composing
wrongly, and two draw-order defects no per-task review could see.

**Batch 8 is specced and its scope halved** — `docs/superpowers/specs/2026-07-27-batch-8-design.md`.
Build time turned out already resolved (measured: 5.1 s, §5) and the arena decision was settled in
batch 7, leaving precompiled `.cso` shaders (which the 2026-07-25 audit downgraded itself) and
**batching the text pipeline**, which is the only item that buys anything — it unblocks the
always-on line-number gutter.

**One batch-8 task is already merged: `drawcount` is now headless.** It renders a real frame
offscreen, prints draw calls plus an instance-stream digest, and exits — so the batching work has an
instrument for the first time, and a §6 trap is retired. **It is not yet sufficient to sign that work
off**, and the four limits are listed at the mode itself in `test_modes.odin`; the sharpest is that
the digest hashes UVs, which encode glyph first-use order, so a batching pass that regroups draws
moves the digest with zero pixel change. Read them before batch 8b.

**Both batch-8 questions answered by Wyatt, 2026-07-27:** (1) **yes to an always-on line-number
gutter, but as a toggle** — off by default, so the text-pipeline batching that unblocks it stays
justified and stays batch 8b; (2) grid horizontal scrolling should genuinely work rather than be
hidden, which is now fixed (see below). The pixel-harness question is still open and is the one that
decides whether 8b can be verified at all.

**Superseded — the two questions at the end of the batch-8 spec** — whether the
line-number gutter is actually wanted (it is batching's whole justification) and whether a pixel
readback harness is worth building, or whether Wyatt's live pass is the intended verification for
renderer work from here on.

**Three things Wyatt owes, all ranked in their own sections and none blocking:**

0. **§6z's live pass** on batch 6 — the `Encoding` menu on a real window, a reopen under a forced
   encoding, a `.md` left in Split surviving a restart, and one Ctrl+Z after a held column edit.

1. **§6x's theme-tuning pass.** v0.14.0 added *View → Edit Current Theme...*, which writes the active
   theme to a file, switches to it, and opens it as a tab — edit a colour, Ctrl+S, the window updates.
   Dark's syntax colours were chosen by arithmetic and have been seen once. Sample files for it are at
   `C:\Users\Wyatt\Newtpad-testfiles`.
2. **The rest of §6y's column-editing gesture list.** Items 1-3 and 5 were passed and their findings
   fixed in v0.15.1; items 4 and 6-8 are unconfirmed.

**Decided, deliberately not built:** the column-edit region-splice fix (§5). At the shipped 300-row
cap performance is fine (press 50 = 13.8 ms); what bites is the *limit*, and its failure mode is a
refusal, not damage. Wyatt's call was that it is not needed yet. §5 carries the measurements so
whoever picks it up does not re-derive them — **and does not re-diagnose it, which has now gone wrong
twice.**

**The `.superpowers/sdd/` ledger is complete through v0.15.1** and is scratch, not history — HANDOFF
§6v-§6y is the record.

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

- ~~**Arenas on VirtualAlloc: still zero implementation.**~~ **RESOLVED by amendment, 2026-07-27.**
  This entry was stale: CLAUDE.md's Memory row no longer specifies arenas. It records that the arena
  text described something which never existed in any form and had no measured problem behind it, and
  ends "build arenas only if a measurement asks for them, and amend this row again when you do." The
  decision and the code agree; nothing is owed. Left visible rather than deleted because *this entry*
  was cited as outstanding debt repeatedly after the amendment had already landed.
- ~~**`\?\` long paths: still zero implementation.**~~ **Platform layer DONE (2026-07-26, batch 7
  task 3.)** `src/platform/path.odin` — `long_path_form` / `wide_path`, every file-I/O call in
  `file.odin` converted, `longpathtest` covering the rule table plus a real 292-character round trip.
  **The program layer is not converted:** ~15 `os.*` filesystem calls in `session.odin`,
  `settings.odin`, `theme.odin` and `diag.odin` (`make_directory`, `read_entire_file`,
  `write_entire_file`, `exists`, `stat`, `remove`, `rename`, `open`) still inherit `core:os`'s
  `_fix_long_path`, which returns the path unchanged whenever HKLM `LongPathsEnabled` is set — the
  registry opt-in CLAUDE.md forbids depending on, and one that does nothing without the
  `longPathAware` manifest entry we deliberately do not ship. Not urgent: every one of those paths
  is under `%APPDATA%\Newtpad` and short. **It was reachable, though** — `NEWTPAD_SESSION_DIR`
  redirects the whole store, so a long override lost the session, the settings, the log and the crash
  artefacts, each silently.

  **DONE 2026-07-29 (§6an).** `plat.file_read_all` was added, because `core:os`'s `read_entire_file`
  goes through `_fix_long_path`, which returns the path unchanged without the HKLM opt-in — so every
  program-layer read had a silent 260-character ceiling. The directory creates, deletes, existence
  checks, reads and the theme write in `session.odin`, `settings.odin`, `theme.odin` and `diag.odin`
  now route through `plat`. What remains on `core:os` is `diag.odin`'s append-mode log handle
  (`os.open` / `os.stat` / `os.rename`), which needs a `plat` append primitive that does not exist —
  one file, and the least damaging of the set to lose.
- ~~**Test modes ship in the release binary.**~~ **DONE (2026-07-26, §6z.)** `NEWTPAD_TESTS`
  (`#config`, defaults to `ODIN_DEBUG`) gates the whole file; release went 1,494,528 → 1,055,744
  bytes. `build.bat release tests` puts it back for `-o:speed` measurements.
- ~~**Carried from batch 6 (§6z), none blocking**~~ — **all five DONE (2026-07-27, §6ab task 5.)**
  The reopen cap now stats at the reopen and refuses on a failed stat; Save/Save As/Paste are dead
  on the pseudo-tabs; `menutest` asserts the `checked` predicates flip; `session_restore` says why
  it skips `app_apply_view_defaults`; and a lone CR survives a paste. Two of them turned out bigger
  than the entry: the pseudo-tab gate was **menu-only and the command palette walked past it**, so
  the batch-6 encoding bug was still live by mouse, and the fix moved to one shared
  `command_allowed_on` predicate covering eight commands.
- **Carried from batch 7 (task 2, true tab stops):** `line_cell_col` (`doc.odin`) reads at most
  `VISIBLE_COLS * 4` = 8192 bytes from the row start and **silently truncates** past that — no
  `exact` flag, unlike `pt_line_start_cap`. Shape A, and `block_delete` is now subject to it: it
  measures the deleted run's column forward from the row start instead of subtracting the run's own
  width (the subtraction is circular under true tab stops), so a rectangle more than ~2048 cells into
  a row would get a too-small column. **Not currently reachable** — `cell_lo` comes from
  `caret_line_start_cell`, which has the *identical* bound, so the seed cannot outrun it — and
  deliberately **not** widened, because widening one of the two identical bounds would make them
  disagree. **The right fix, when it is done:** have `line_cell_col` return an `exact` flag and have
  `block_delete` refuse when it is false, matching the refusal contract `caret_line_start_cell`
  already has. Both bounds move together or neither does.
- **`keys.txt` can bind the plumbing commands the palette deliberately hides.** `command_from_name`
  (`keymap.odin`) accepts every `Command_Id`, including the ones `command_in_palette` (`palette.odin`)
  filters out precisely because they are not things a user invokes — `Menu_Activate`, `History_Jump`,
  `Settings_Close` and the rest. Audited during the batch 9 task 1 review: **every** dispatch case for
  those is either guarded by "is that surface open" or prompts, so nothing currently reachable
  misbehaves, and this is not a defect today. **Nothing enforces it, though**, and batch 9 adds
  commands: the class is a plumbing command becoming dispatchable from the Editor with no surface
  open. The fix, if a case ever needs one, is to reuse `command_in_palette` as the parse-time filter
  — one predicate, shared with the seed writer that already uses it — never a second list.
- **A markdown table wider than the Preview pane is clipped with no way to reach the rest.**
  Surfaced 2026-07-27 while fixing the horizontal scrollbar: Preview lays prose out to the pane, so
  the pane itself correctly has no horizontal axis and the bar is now hidden there (Wyatt's call).
  A wide `| a | b | ... |` table is the one thing in a preview that genuinely overflows. The fix is
  to scroll the **table element**, not the pane — a different mechanism from either the text view's
  cell pan or the grid's column pan, which is why it was deliberately kept out of that fix.
- **The app redraws at vsync when idle** — no `WaitMessage` anywhere. A core burnt on a static
  screen, which also multiplies every other per-frame cost.
- **The text pipeline batches nothing** — one heap allocation, two buffer maps and one draw call
  per string, 74 call sites, several inside per-row loops. This is the prerequisite for an
  always-on line-number gutter (see `drawcount` in §6k).
- ~~**`build.bat release` is roughly 2x the ~5 s rule**~~ — **essentially resolved, measured
  2026-07-27 at v0.17.0.** Warm, consecutive runs on this machine: `build.bat release` **5.12 / 5.07 /
  5.07 / 5.31 / 5.08 s** (1,060,352 bytes); `build.bat release tests` **6.94 / 6.91 s**
  (1,594,880 bytes); debug 1.07 s. **The harness accounts for ~1.85 s**, so §6z's `NEWTPAD_TESTS`
  gating is what closed the gap — the old 10.2 s figure was measured at v0.13.0 with
  `test_modes.odin` (now ~11k lines) still compiled into the release. Nothing in batch 7 targeted
  build time. At 5.1 s the rule is met to within noise, so **do not spend a batch-8 task on this**;
  re-measure if it drifts back. The earlier entry's own history is the caution: the "5.8 s before
  this batch" figure it once carried was stale and made highlighting look like a 2.7 s regression.
  Still true from that entry: the `@(test)` corpus is not the cost (removing all twelve
  `src/base/*_test.odin` changed nothing), and the remainder is LLVM at `-o:speed`.
- **`pt_insert` never coalesces adjacent appends, so a multi-row edit fragments the tree and every
  subsequent READ pays for it.** This was misdiagnosed twice before being measured; the numbers below
  are instrumented, release build, 2,000-row rectangle, and the four phases sum to wall-clock within
  0.1%:

  | press | total | row-start walk | cell→byte resolve | snapshot | splice | pieces |
  |---|---|---|---|---|---|---|
  | 1 | 6.75 ms | 3.16 | 3.15 | 0.00 | 0.41 | 4,001 |
  | 20 | 63.97 ms | 30.42 | 30.46 | 2.27 | 0.81 | 42,001 |

  Piece count grows by exactly `rows` per press, and both `block_step_lines` and `block_row_range`
  read *through* the tree, so after N presses each row costs ~N times what it did on press 1. **The
  cost is 95% reads.** §6y blamed splice fragmentation (right about the cause, wrong that it bills to
  the writes — the splice itself is 1.3%); §6z then blamed the undo snapshot and proposed coalescing
  (wrong: forcing *zero* snapshots on presses 2..N, strictly better than coalescing, moved press 20
  by **0.9 ms — 1.4%**). Both corrections are recorded because the second was more confident and less
  right than the first.

  **The fix that follows from the measurement:** have `block_apply` read `[first_row_start,
  last_row_end)` once, edit it in a temp buffer, and issue **one** `pt_delete` + **one** `pt_insert`
  rather than 2N splices. Piece count then stays flat across a held key and every press costs what
  press 1 costs — 6.75 ms at 2,000 rows, inside a 25 ms budget, which would let
  `BLOCK_EDIT_MAX_LINES` go from **300** back to thousands. Two things it must handle: the region
  read needs its own byte cap (2,000 rows of long lines is unbounded), and `doc.nl_delta` plus find
  invalidation currently ride on the per-row `doc_replace_sel`.

  Note `pt_insert`'s missing coalescing is **not** block-specific — ordinary held-key typing also
  adds a piece per character.
- **Coalescing consecutive block edits into one undo entry is still worth doing**, but as correctness,
  not performance: 20 presses is currently 20 Ctrl+Z, and with `UNDO_MAX :: 200` a long hold evicts
  the pre-run state entirely, which is a small data-loss path. Do not attach a cap raise to it.
- **`Highlight_Row_Cache.cur_buf` is a row-sized token budget filled from a whole line.** On
  `doc_row_lex_spans`'s whole-line path the 512-span array covers a logical line of up to
  `RENDER_LINE_CAP` (8192) bytes, so a dense enough wrapped line — measured: a 4.5 KB minified-JS
  line at 200 columns — colours its first four visual rows and leaves the next nineteen bare.
  `state_out` stays correct (every lexer keeps scanning past a full `out`), so this is visual only,
  and it is 4x better than v0.12.0's 64-token budget. **The obvious fix is wrong:** setting
  `whole_line = false` on saturation makes the fall-through lex `[start,end)` with a `state_in`
  resolved at `lls`. Either re-lex the row's own extent for spans while keeping the cached state, or
  decide the refusal in `doc_row_lex_extent` before any state is resolved.
- **`a.docs` can now grow without bound within a session.** `app_add` (`app.odin`) used to reuse the
  first nil slot; it now only reclaims a *trailing* nil (see its comment) so tab display order stays
  the order tabs were added, per Wyatt: "I don't want random order tabs, unacceptable." The cost is
  one dead slot per middle-close/reopen cycle. Measured: 100 close/open cycles on a middle tab ->
  `slots=104 live=4`, order still monotonic, `active` and every `mru` entry still pointing at a live
  slot, and a restart (session save/restore) compacts back down. Carried deliberately, not fixed:
  8 bytes per dead slot plus one skipped nil check in the ~10-15 walks over `a.docs` per frame is
  unmeasurable at any session length a user would reach before restarting. **Constraint for whenever
  this is compacted:** it must be a re-indexing pass that walks `a.docs`, builds an old-slot ->
  new-slot map, and remaps `active`, every `mru` entry, and every in-flight `Watch_Entry.slot`
  (`watch.odin`) through it -- never a hole-fill (reusing a freed slot for the next add). A hole-fill
  is exactly the bug this entry exists because it was removed.

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
- ~~**Glyph-atlas eviction** (LRU/generational + atlas-full repack)~~ — **REFUTED, not deferred
  (2026-07-26, §6ab).** Measured before batch 7 spent a night on it: at 4096² the atlas holds
  **61,425** glyphs at 16px and **9,768** at 48px (300% DPI), growth 1024→4096 is observed against a
  real device, and `atlas_full` does not latch (`atlastest`, `atlasgrowtest`). Grow-then-recycle
  already exists from §6j. One screen of text is far fewer distinct glyphs than the capacity, so the
  "your text silently vanishes" failure the 2026-07-25 audit ranked Tier 2 is **not reachable by a
  real document.** The belief traced to one stale comment in `text.odin` that outlived its fix by
  seven months. Do not re-add this without a measurement that contradicts the above.
- **Non-local link targets never resolve** (`\\server\share\x`, `smb://`, and every link — even a
  relative one — inside a document opened from a UNC path or mapped network drive). Refusing to stat
  is what fixed the >100 s UI-thread freeze (§6aq); restoring the coverage needs an async resolver
  worker, `watch.odin`-shaped. See §6aq's Owed list for the full writeup.
- **reindex-on-edit** (line count/scrollbar drift approximately after big edits).
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

## 6m. Live-use bug pass (2026-07-20)

Wyatt spent a day daily-driving Newtpad and reported a batch of bugs. Four were fixed and
verified this pass; the two biggest (huge-file crash/lockup) were root-caused with evidence but
their fixes are involved enough to want Wyatt's sign-off first, so they are written up here rather
than shipped blind. Three feature requests are captured at the end.

### Fixed and committed

- **Filter banner drawn half under the menu bar (Ctrl+L).** The green `FILTER …` banner sat at
  `CONTENT_TOP − 20`, but the gap between the menu bar and the first content row is only
  `TEXT_MARGIN_Y` (10px), so half of it was hidden under the menu. Added a filter-only top inset
  (`FILTER_BANNER_H`, `doc_update_top_inset`): the row math — baseline, rect, hit-test and row
  count — all add it, so the document shifts down together and the banner gets a clean strip below
  the menu. Set once per frame in both layout sites (main loop + `render_frame`) so draw and
  hit-test agree. Zero unless filtering, so nothing else moves.
- **Markdown `[label](target)` not recognised.** `links_scan` took the whole run as one bogus
  relative path (parens are not delimiters — that is deliberate, so wiki URLs like `/a_(b)`
  survive). Added a markdown branch that pulls the target out of the parens; only it underlines and
  resolves. `linktest` covers URL, path-with-`:line`, and the negative (`[plain](word)`).
- **`smb://host/share/path` not recognised.** Rejected by `has_uri_scheme` (correctly — it is a
  URI, not a path), so it fell through every branch. Detect it explicitly and, in `link_resolve`,
  rewrite to the Windows UNC form `\\host\share\path` (Windows has no `smb:` handler), which then
  flows through the same stat-first path safety as any other path — text-ish opens in a tab,
  anything else reveals in Explorer. `:line` suffix survives the `smb:` colon (drive-letter guard).
- **Drag-select died at the bottom bar.** Dragging a selection down into the find/status strip
  zeroed `mouse_down` unconditionally, killing the drag and its auto-scroll the instant the pointer
  touched the bar — so a selection could never be dragged below the last visible line. Now only a
  *fresh press* in the strip is consumed; an in-progress drag continues, and auto-scroll fires
  across the whole bottom edge (into the bar, or past the window with capture held) instead of only
  the last row's height. **Unverified without a live mouse pass** — this environment can't inject
  drag input. The exact "stop when the mouse is off the screen" wish is still open (see questions).

### Root-caused, NOT yet fixed — the huge-file P0 (needs sign-off)

A background investigation reproduced against real multi-GB files (2.28 GB opened and indexed fine
on both the mmap and copy paths — no crash, no integer overflow; the build is 64-bit so
`int(info.size)` does not truncate at 2^31). Open and the steady frame are already capped
(`pt_line_end_cap`, status caps, O(1) scrollbar). The failures are on *interaction*:

1. **1 GB "lockup" — the viewport/nav scans are uncapped on the main thread.** `doc_scroll`,
   `doc_max_top`, `doc_ensure_cursor_visible`, `doc_scroll_to_fraction` and the cursor-movement
   helpers call the **uncapped** `pt_line_start`/`pt_line_end` (piecetable.odin:327,344), whose cost
   is O(line length). Measured strictly linear: **350 ms per `pt_line_start` at 1 GB** on heap, ~1.7×
   that through the SEH-guarded mmap read plus cold-page disk I/O — so **~0.5–1 s of UI-thread stall
   on every wheel tick / PageUp-Dn / arrow / scrollbar drag** on a long-line file. This is a direct
   violation of the "never freeze on huge files" hard rule. **It requires long lines** (minified
   JSON, a single-line log, long records); a normal short-line 1 GB file does not hit it, and there
   the lockup is more likely the index worker faulting all pages into the working set. Note this is
   almost certainly Wyatt's case: he asked for a horizontal scrollbar, i.e. word wrap is off, and
   the non-wrap scroll path is exactly the uncapped one (the wrap path already bounds by view width).
   **Fix (proposed): make `doc_scroll`/`doc_max_top`/`doc_ensure_cursor_visible`/`scroll_to_fraction`
   step by capped visual rows, the same way `doc_draw`'s `Visible_Iter` already does** — for
   short-line files behaviour is identical; on long lines scrolling then matches what is actually
   drawn (today the renderer shows a long line as capped 8192-byte rows while scroll steps a whole
   logical line, so they already disagree). This is a **navigation-semantics change on pathological
   lines** and touches the one-layout viewport core, which is why it wants sign-off + a headless
   perf/correctness test (extend `colperftest`) rather than a blind edit.

2. **2 GB "crash" — not reproduced; two live hypotheses.** No crashing path was found by inspection
   or headless runs. Most likely: **(a)** the same uncapped-scan stall, ~2× worse plus a ~2 GB mmap
   working set, leaves the app unresponsive long enough to be "not responding"/killed and *perceived*
   as a crash ("almost no resource usage" fits mmap — file-backed pages are standby, not private).
   **(b) The save/autosave path.** `doc_save_err` (doc.odin:638) and the ~2 s **session autosave**
   (`session_save` → `pt_collect` for every *modified* buffer, session.odin:114; gated on `d.modified`,
   which is why a fresh open doesn't hit it) do `pt_collect` **+** `encode_from_utf8` — two full-buffer
   allocations, **~4–6 GB transient for a 2 GB doc — on the main thread**. One accidental keystroke in
   a huge file therefore arms a guaranteed multi-second freeze, and a plausible OOM crash, ~2 s later
   on a timer. This fits "opened fast, then died" better than anything else. **Fix (proposed): move
   `pt_collect`+encode+write off the main thread (or stream to disk) for large buffers**, and/or a
   stopgap size-cap on the periodic autosave backup — but the backup is the only crash-safe copy of
   unsaved edits, so the trade-off (huge dirty buffer loses crash-protection) is Wyatt's call, not a
   blind edit. **To confirm which hypothesis:** does the 2 GB file die ~2 s after you touch/edit it
   (→ save path), or only when you scroll/navigate (→ scan path)? Machine RAM and a crash dump would
   settle it.

### Deferred, needs Wyatt input (not code-ready)

- **Blurry fonts at max zoom.** Not diagnosable without a screenshot. Glyphs are rasterized at the
  exact display px (`fontEmSize = px`, `Glyph_Key.px`) and point-sampled 1:1, so there is no obvious
  scaling blur in the code. Candidates: DirectWrite `.NATURAL` rendering mode (text.odin:904) is
  tuned for small sizes — `.NATURAL_SYMMETRIC` is Microsoft's recommendation for large/scaled text;
  or a sub-pixel quad-alignment issue at large px. Switching the mode affects *all* text and can't be
  verified blind, so it's held for a screenshot + a compare pass.

### Requested features to document (not built)

- **Horizontal scrollbar / horizontal viewport shift** (Wyatt's #1 ask). With word wrap off, long
  lines run off the right edge (clipped at `VISIBLE_COLS`=2048 and the window edge) and there is no
  way to pan right. **Design:** add a per-doc `left_col` (cells); `col_x`/`col_at_x`/`cell_at_x` are
  already the single source of column geometry, so subtracting/adding `left_col` there shifts the
  caret, selection, find rects, links and hit-test together — but `doc_draw` reads the raw line from
  column 0 and would need to skip `left_col` cells (cells ≠ bytes on CJK/tabs), and a new draggable
  horizontal scrollbar widget above the status bar is a fresh chrome seam. This is the exact
  one-layout surface HANDOFF §6j warns is bug-prone, and it can't be GUI-tested here, so it wants a
  dedicated pass with a drawn-vs-clickable seam test and a live loop with Wyatt. Interacts with the
  huge-file scan fix (panning a long line must stay capped).
- **`.csv`/`.db` table-view toggle** (like a markdown edit/preview toggle — note Newtpad has no
  markdown preview yet either, so this is a new "view mode" concept). A parsed, columnized read-only
  view of tabular data with a keystroke back to raw text. `Tab_Kind` already models non-text tabs
  (Settings/Font); a view-mode flag on a text doc is the lighter option. `.db` (SQLite) means a
  reader/parser dependency and edges toward the parked container/viewer plugin work (§6) — probably
  a V2 plugin, whereas `.csv`/`.tsv` table view is plausible V1. Open questions: editable or
  read-only; how wide columns/large tables are handled given the huge-file rules; is this the first
  use of the parked side-panel/view-mode chrome.
- **Tab drag — reorder within the strip, and tear off to a new window.** Reorder is contained
  (`ui_tabs.odin` + the `docs` slot array + MRU). Tear-off-to-new-window is much larger: Newtpad is
  deliberately single-instance with one process owning the session + backups (§6c), so a second
  window is either a second top-level window in the same process (new window/gfx/atlas plumbing) or a
  second process (which the single-instance mutex + shared session explicitly prevent). Reorder is a
  reasonable standalone task; tear-off needs a design decision about the process/window model first.

**Force-wrap long lines — DONE (v0.4.0).** A third layout between all-scroll and
all-wrap: with global wrap off, a line past `WRAP_LONG_CELLS` (1024) wraps to the window
while shorter lines stay single, horizontally-scrollable rows. `eff_wrap_at` decides per
line, **bounded to `RENDER_LINE_CAP`** so viewport/caret nav costs no more than the capped
no-wrap stepping — a multi-GB single line stays a capped no-wrap row and can't freeze
(`scrollperftest` <6ms on 128 MB; the earlier mixed-layout version scanned 256 KB per step
and blew the frame budget — the cap is load-bearing). The iterator carries a `wrapped` flag;
`col_x`/`col_at_x`/`cell_at_x` take a per-row offset so a wrapped row ignores the pan while
the lines around it keep it, and `doc_max_hscroll` excludes wrapped lines. `wraplongtest`
covers it. **Consequence:** a single line longer than `RENDER_LINE_CAP` (~8192 cells) doesn't
wrap — it still uses horizontal scroll (bounded). Raising that limit means making the wrap
decision cheaper than a full backward scan (cache per line), a follow-up. (Links on wrapped
rows are handled correctly as of v0.5.0 — see below.)

**Open questions carried forward (the ones from last night + this pass):**
- The 7 link questions in §6l (wrap-spanning links, selection-vs-Ctrl+click, underline-without-Ctrl,
  a binding for *Open Link Under Cursor*, byte-vs-cell column jump on CJK, the duplicated extension
  list, directories-as-tab-vs-Explorer).
- Drag-select: what should "stop when the mouse is off the screen" mean exactly — keep auto-scrolling
  while held past the edge (standard, what the fix now does), or halt once the pointer leaves the
  window/monitor?
- Huge-file P0: approve the two proposed fixes, and answer the 2 GB "when does it die" question above.

## 6n. Second pass — Wyatt's answers acted on (2026-07-20)

Wyatt answered the §6m open questions and the §6l link questions and said to use my
judgement on the huge-file fixes and the scrollbar. Cut as two releases:
**v0.2.0** (correctness + huge-file P0 + versioning) and **v0.3.0** (horizontal scroll +
remaining link work). Versioning is now real: `src/program/version.odin` is the single
source (`NEWTPAD_VERSION`), shown on the Settings page and by `newtpad --version`;
`release.ps1` builds the release exe, tags `v<version>`, and pushes (a GitHub Release with
the exe attached needs `gh`, which isn't installed — the exe upload is manual for now).

### Shipped this pass (all with a headless guard where testable)

- **Huge-file lockup (P0) — FIXED.** `doc_scroll`/`doc_max_top`/`doc_ensure_cursor_visible`/
  `doc_scroll_to_fraction` now step by capped rows (`row_start_capped`/`next_row_start_capped`/
  `prev_row_start_capped`, all bounded to `RENDER_LINE_CAP`, matching the renderer). Identical
  to before for any line < 8 KB; bounded on long lines. `scrollperftest`: the uncapped
  `pt_line_start` on 512 MB = 1151 ms, capped ops all < 3 ms; short-line scrolling still lands
  on real line starts.
- **Huge-file "2 GB crash" (P0) — mitigated.** The autosave/`session_save` `pt_collect`+write
  of a multi-GB dirty buffer (the prime suspect: multi-second freeze + OOM on the ~2 s timer)
  is now capped at `BACKUP_MAX` (128 MB). Above it a dirty buffer isn't backed up — the tab is
  still recorded (a saved file reopens from disk) and the status bar warns its unsaved edits
  aren't crash-protected. `doc_save_err`'s explicit-save `pt_collect`+encode is still on the
  main thread; streaming/off-thread serialize is the remaining owed work. **Wyatt's note:** the
  2 GB death was "pretty quick" after interaction, which is consistent with either the scan
  stall or this timer — both are now addressed.
- **Horizontal scrolling — DONE** (Wyatt's #1 ask). Per-doc `h_scroll` (cells) mirrored into an
  `H_SCROLL` global that `col_x` subtracts and `col_at_x`/`cell_at_x` add — so caret, selection,
  find, links, draw and hit-test shift through the one column primitive. Shift+wheel pans;
  caret-follow keeps a caret arrowed/typed off the right edge on screen; a draggable bottom
  scrollbar (`hscrollbar_geo` single-sources its draw + drag hit-test). Disabled while wrapping
  or filtering; bounded to the widest *visible* line (no whole-file scan). `hscrolltest` asserts
  drawn column == hit-tested column at both viewport edges across pan offsets, and the thumb
  round-trips. **Live pass owed** (no GUI input here). Known cosmetic cost: the bar overlays the
  bottom ~8 px of the last row rather than reserving a strip. Lines wider than `VISIBLE_COLS`
  (2048 cells) still can't be panned past that — the pre-existing draw clip, now the h-scroll cap.
- **Ctrl+F in filter view — FIXED.** It was bound to `Find_Close` in the find context, so it
  dropped to the viewport; now `Find_Open` (which also leaves filter mode and focuses the query).
  Escape still closes.
- **Link column jump on CJK (§6l Q5) — FIXED.** The `:line:col` jump added col−1 *bytes*; now it
  maps the 1-based *cell* column (what the status bar shows) through the line's glyph widths.
  `link_activate` takes the text pipeline.
- **Relative directory links (§6l Q7) — confirmed + tested.** `./dir` / `.\dir` resolve against
  the document folder and reveal in Explorer (never opened as a tab). `linktest` covers it.
- **One extension list (§6l Q6) — DONE.** `text_exts.txt` at the repo root is the single source:
  `links.odin` `#load`s it at compile time, `install.ps1` reads it at run time. The two
  hand-maintained copies that had drifted are gone.
- **Show-links setting (§6l Q3) — DONE.** Settings > Show links: On Ctrl (default) / Always
  underlined / Always tinted (colour, no underline). Activation stays Ctrl+click. Persisted.
- **Markdown + smb links, filter banner, drag-select** — from the first pass, all in v0.2.0.

### Still open (Wyatt wants these; deferred with a plan, not code)

- **Links spanning wrapped lines (§6l Q1) — DONE (v0.5.0).** `links_layout` scans a wrapped
  line's link on the *logical* line (once, cached across its rows) and splits it into per-row
  segments; `Link_Hit` now carries a row-relative draw span (`span_start`/`span_len`) decoupled
  from the full resolve target (`text`+`link`), plus a `wrapped` flag so the underline and click
  hit-test use the row's own offset. `linktest` plants a URL that char-breaks across three
  wrapped rows and checks the segments cover it and each resolves whole. Live pass still worth it.
- **Blurry text at high *zoom* — FIXED (v0.6.0).** It was ClearType subpixel fringing magnified:
  the swapchain is `SCALING_NONE` (1:1) and glyphs rasterize at the exact px, so it was never
  scaling blur — the 3-channel `CLEARTYPE_3x1` coverage's coloured subpixels read as soft/chromatic
  when a glyph is large. Now the same ClearType coverage is **averaged to one grayscale value**
  (`glyph_get`), the shader samples one channel and straight-alpha-blends (was dual-source), and the
  rendering mode is `NATURAL_SYMMETRIC`. Note: asking DirectWrite for an `ALIASED_1x1` texture under
  a ClearType rendering mode returns an *empty* glyph — the averaging trick is why this stays on the
  working `CLEARTYPE_3x1` path. `blurtest` compiles the shaders and checks glyphs rasterize inked
  16px–200px (headless — the look still wants a live eye). Also **Ctrl+wheel now scrolls** (Ctrl is
  the link-highlight modifier); zoom moved to Ctrl+= / Ctrl+- / Ctrl+0 and Settings. (§6l Q2 "selection vs
  link" and Q4 "a binding for Open Link Under Cursor" — Wyatt: keep link-wins; make the binding
  choosable once user keybind customization exists, which is separate future work.)

## 6o. Four-in-one-pass batch (2026-07-20, v0.7.0)

Wyatt asked for all four remaining options in one pass to bug-hunt the next day. All shipped
in v0.7.0; the two GUI-feel ones want a live pass (headless can't inject drags or judge a grid).

- **Streamed save (P1 data-safety) — DONE.** `doc_save_err` streamed in rune-aligned 1 MB chunks
  instead of `pt_collect` + `encode_from_utf8` (two whole-buffer allocs, the multi-GB OOM). UTF-8
  writes buffer bytes directly; other encodings transcode a chunk at a time and free it, so the
  peak is one chunk. New `Atomic_Write` begin/write/commit in `file.odin` (`file_write_atomic` is
  now a one-chunk wrapper, same `ReplaceFileW` durability); `encode_body_from_utf8` / `encoding_bom`
  / `utf8_complete_len` in `base`. `savestreamtest` proves byte-identical output vs the whole-buffer
  encoder across the 1 MB boundary for UTF-8/16LE/16BE/CP1252 with multibyte runes straddling it.
- **Tab drag to reorder — DONE (live pass owed).** Press a tab and drag; it bubbles past neighbours
  (adjacent swaps) so the active/highlighted tab follows the cursor, no floating render. `app_swap_tabs`
  swaps two slots' docs and remaps `active` + `mru` (both slot indices; the watcher's per-doc gen
  check discards a stale in-flight result). `tabreordertest` covers the bookkeeping. Tear-off-to-a-
  new-window still deferred (fights single-instance).
- **CSV/TSV table view (Ctrl+T) — DONE (live pass owed).** `table.odin`: toggle to a read-only
  columnized grid; bounded (only visible rows parsed, only their fields set column widths, so a
  multi-GB CSV is fine). Delimiter chosen on turn-on (tab for .tsv, else majority of the first line);
  Shift+wheel pans columns; header row banded when the file's first line is on screen. v1 limits:
  read-only, quotes parse within a line but not across a newline, columns past the window clip.
  `csvtest` covers the field parser.
- **Idle CPU — DONE.** The loop blocked at vsync (a pinned core). It now `MsgWaitForMultipleObjectsEx`
  (QS_ALLINPUT) when idle — waking instantly on input/events — spinning only for a held drag
  auto-scrolling past an edge, polling every 200 ms while a worker publishes and every 1 s otherwise
  (so a disk change still surfaces within the watcher's cadence). Hover/Ctrl-highlight still update
  because a move or Ctrl press is itself a waking message. **Can't be verified headlessly** — watch
  for any input lag or a stale frame after a background change during Wyatt's pass.

## 6p. Markdown views + table editing (2026-07-20, v0.8.0)

Wyatt asked for a markdown viewer/editor toggle with a live side-by-side split ("rich as
feasible"), then a batch of table fixes after live-driving the grid. All shipped; the visual
pieces (split layout, in-cell editing feel) want Wyatt's live pass.

- **Markdown preview + split (Ctrl+M) — DONE.** `markdown.odin`: `Md_Mode {Off, Preview, Split}`,
  cycled by Ctrl+M (and the View menu). Preview replaces the text pass with a line-based rendered
  view; Split draws the editor on the left and a live preview on the right of a divider
  (`doc_editor_right`, `MD_SPLIT_FRAC 0.5`), each with its own scroll (`md_top`, wheel routes to
  the half under the cursor). Inline parser (`md_inline`) handles `**`/`__` bold (synthetic, drawn
  twice offset a texel — no bold face in the atlas), `*`/`_` italic (tint), `` ` `` code, and
  `[label](url)` links; block level does headings, rules, block-quotes, lists, and table rows.
  `mdtest` covers the block classifiers and the inline parser (rendering itself needs a live eye).
- **Table view menu + palette — DONE.** Ctrl+T (Toggle Table View) and Ctrl+M (Toggle Markdown
  Preview) are in the View menu with their chords and in the palette, so neither is undiscoverable.
  Menu predicates `is_table` / `is_md_view` check/enable the rows.
- **Table columns no longer shift on scroll — DONE.** Column widths come from a one-time sample of
  the first `TABLE_SAMPLE` (500) rows (`table_compute_widths`), cached in `doc.table_widths`, not
  recomputed from the currently-visible rows — so scrolling a wider header off-screen and narrower
  data in no longer reflows the grid. Recomputed on open and after a cell edit.
- **Links inside table cells (Ctrl+click) — DONE.** Cells sit at arbitrary column x's, not the
  uniform text grid, so raw-line link detection lit the whole row. `table_links` positions each
  link in pixels to match `table_draw`'s layout and `table_link_hit` is a pixel-rect test; Ctrl+hover
  shows the hand and Ctrl+click activates only the link under the pointer.
- **Edit cells in place — DONE (live pass owed).** Click a cell to edit it: the buffer draws over
  the cell with a caret + highlight box, keeping the grid's exact look. Enter/Tab commit (Tab steps
  to the next cell), Esc cancels, click-away and scroll commit. The commit splices only the edited
  field's raw byte span (`csv_field_ranges`, quote-aware) with the re-serialized value
  (`csv_serialize`, quotes only when needed) through the document's undo as one step
  (`doc_replace_range`), then re-fits columns. An external reload mid-edit drops the pending edit so
  a commit never writes at a stale offset. `tablecellstest` covers the range parser, the serializer,
  and the full replace-a-field splice.

## 6q. Live-use fixes on the 0.8.0 batch (2026-07-20, v0.8.1)

Wyatt drove the 0.8.0 build and reported three things the same evening; all fixed.

- **Markdown Split showed one pane on top of the other, unreadable — FIXED.** The editor pass
  draws full window width and there is no scissor rect, so in Split its lines ran *under* the
  right-half preview. Now the right half `[er,w]x[pvtop,pvbot]` is painted back to the background
  before the divider + preview draw, giving two clean side-by-side panes. **Scroll is now shared:**
  both panes render from `doc.top` (the separate `md_top` and the `md_scroll_*` helpers are gone),
  and the preview's wheel and scrollbar drive `doc.top` too, so the halves stay anchored to the same
  source line. Divider position is the single `doc_editor_right(doc,w)` used by the editor scrollbar,
  the read-only-consume boundary, and the preview's `x0`. Needs a live eye on the visual result.
- **A stationary press highlighted lines and scrolled — FIXED.** The `mouse_down` branch treated
  any held button as an active drag: it re-extended the selection and auto-scrolled every frame, so
  holding still (especially near an edge) ran away. A selection drag now begins only once the pointer
  moves past `DRAG_SLOP` (3 px, DPI-scaled) from the press (`press_x/press_y`, `sel_dragging`); once
  dragging it stays dragging, so holding at an edge still auto-scrolls. A plain press-and-hold does
  nothing. Re-armed on every press.
- **Ctrl+T / Ctrl+M worked on any file — now gated by type.** Table view only opens on delimited
  files (`.csv/.tsv/.tab/.psv`), a markdown view only on markdown files (`.md` family) — but a
  new/**untitled** buffer (empty path) is allowed into either, since its type isn't decided yet
  (`doc_is_tabular` / `doc_is_markdownish` / `doc_can_table` / `doc_can_markdown` in doc.odin). The
  gate is in `command_dispatch`, so the hotkey, palette, and menu click all honour it; the menu rows
  grey out and the palette hides the command. **Toggling a mode OFF is always allowed**, so a file
  saved to a new extension while in a view can never get stuck in it.

### Red-team of the 0.8.x view features (2026-07-20)

A devils-advocate pass over the four view features (editable cells, split, drag threshold,
type gate) found one blocking bug and one cosmetic-but-real geometry bug; both fixed before
tagging 0.8.1. The other two verdicts were SURVIVES.

- **FATAL — table view was not actually read-only. FIXED.** Only *typed characters* were blocked
  in table view; every key that resolves to a command (Backspace, Delete, Enter, Cut, Paste, Undo,
  Redo) fell through to `command_dispatch` in the **editor** context and mutated the buffer at
  `doc.cursor` — a stale offset carried over from text view, because entering table view never
  resets the caret. The grid redraws from `doc.top`, so the edit was invisible: the "read-only"
  grid silently corrupted the CSV at an unrelated place. Fix: `command_mutates_doc(cmd)` + a guard
  at the top of `command_dispatch` that drops every mutating command while `doc.table` is set
  (the grid's only write is `table_edit_commit`'s single-field splice). This also closes the
  mid-edit hazard where an Undo/Paste shrank the buffer under an open cell edit and staled its
  captured span. `doc_replace_range` also clamps its range now (defence in depth — the piece tree
  already guards out-of-range `pt_delete`/`pt_insert` internally, so the hypothesised *crash* was
  not actually reachable, but a misplaced splice would have been). `tablereadonlytest` guards the
  classification and the clamp; falsified by removing `.Backspace` from the set and watching it fail.
- **Split hscrollbar bled over the preview. FIXED.** `hscrollbar_geo` was built from the full window
  width, so a long editor line ran its track and drag-mapping across the preview pane. Now both the
  draw and the hit-test pass `doc_editor_right` as the width, so it stays in the editor half.
- **Double-click-then-drag doesn't extend by word (SURVIVES, pre-existing).** The drag branch was
  already gated `mouse_count == 1` before the slop fix, so this never worked — not a regression from
  0.8.1. Minor UX nicety; left for later (would need word/line-granular extension).
- **Type gate edges (SURVIVES, cosmetic).** A saved file with *no extension* can't enter table view
  (only untitled buffers with an empty path are unrestricted); and a view persists after Save-As
  changes the type (still toggleable off, just not back on). Neither loses data.

## 6r. Logging + crash suite (2026-07-21, v0.9.0)

A comprehensive logging/debug layer so crashes and "random" bugs come with evidence. Three
pieces across the layers; the crash path is proven end-to-end by `crashtest` (below), but a
real save-on-crash with open tabs is only exercisable live.

- **`base/log.odin` — always-on ring logger.** A fixed 1024-line in-memory ring (`LOG_RING`,
  `LOG_LINE_MAX` 240 B/line) plus an optional sink. The ring *is* the breadcrumb trail; a crash
  report folds it in so a bug arrives with the sequence that produced it. Allocation-free hot path
  (format into a stack buffer, copy into the ring under a short mutex), safe from worker threads.
  Levels Debug/Info/Warn/Error; base stays filesystem/Win32-free (sink injected like `safe_copy`).
- **`platform/crash.odin` — the safety net.** `SetUnhandledExceptionFilter` → on a hard fault:
  (1) write a `.dmp` **minidump** (dbghelp, links automatically) *first*, before any log/alloc, so
  nothing downstream can cost us the forensics; (2) log the fault; (3) **save the user's work** via
  an injected hook; (4) write a `.txt` report — exception name/address **symbolized** when a PDB is
  present (debug build resolves e.g. `main::test_mode_dispatch +0x…`), a backtrace, and the log
  ring; (5) a friendly message box (suppressible via `crash_set_silent` for tests). Runs without an
  Odin context and can't trust the heap, so it leans on stack buffers + pure Win32. Re-entrancy
  guarded. Reports land in `%APPDATA%\Newtpad\crashes\`.
- **`program/diag.odin` — the wiring.** `diag_init` arms the logger with a **file sink**
  (`%APPDATA%\Newtpad\logs\newtpad.log`, append, rolled to `.old` past 2 MB) and installs the crash
  handler with `on_fatal = session_save(app, sweep=false)` — a crash must never sweep backups.
  **Odin panics/asserts route through the same path:** `context.assertion_failure_proc` (set on
  main's context so it flows down the whole loop) logs the reason and `intrinsics.trap()`s; the
  trap's illegal-instruction fault lands in the crash filter, so a panic gets the identical dump +
  report + save as an access violation. Every dispatched command drops a breadcrumb (`diag_cmd`).
- **Still to do (noted, not built):** a live debug overlay (frame time / doc state — GUI, can't be
  headless-tested), a "Copy Diagnostics" command, and a hang watchdog for the frozen-frame class.
  Symbolized offline analysis of a *release* `.dmp` needs the release PDB archived per version.

### Verifying the crash suite
- `logtest` — ring level-gating, oldest-first dump, wrap-around retention. Pure, headless.
- `crashtest <null|panic|assert|oob>` — **triggers a real fault** and confirms the whole path:
  silent (no dialog), writes a real `.dmp` + `.txt`, saves. The process then dies with the fault,
  so the harness checks the files exist and the exit code is the exception (0xC0000005 for `null`,
  0xC000001D for the trap-based panic/assert). **Set `NEWTPAD_SESSION_DIR` first** so artifacts land
  in a temp dir. Verified 2026-07-21: all four kinds produced a ~1.4 MB dump + a report with the
  faulting frame symbolized and the breadcrumb trail intact.

## 6s. Live-use bug batch 1 (2026-07-25, branch `fix/live-bug-batch-1`)

Six bugs Wyatt reported from daily-driving 0.9.0. Design in
`docs/superpowers/specs/2026-07-24-bug-batch-1-design.md`, task plan in
`docs/superpowers/plans/2026-07-24-bug-batch-1.md`. The four *features* from the same report
(Alt+arrow line move, drag-and-drop open, per-file-family view memory, resizable split) are
deliberately deferred to a second branch.

**Two of the six were the same seam** — `visible_next`, the capped line iterator every screen pass
reads. That is the third time this shape has produced multiple bugs (see §6j), and it is why the
fixes went in at the iterator rather than at the symptoms.

- **Bug 2, phantom trailing row.** `next_row_start_capped` returned `length` for two different
  facts: "the next row starts at `length`" (true after a trailing newline, where a final empty row
  legitimately renders) and "there is no next row" (true at EOF with no newline). So every buffer
  without a trailing newline — i.e. **every scratch buffer** — emitted a phantom row at
  `[length, length]`, and because the caret loop assigns on *every* matching row, the phantom
  overwrote the real hit. Caret one row below the text at column 0, never following it. Now
  `(start, ok)`, propagated through `next_visual_row` / `eff_next_row` and their four walkers.
  Watch out: `visible_next`'s wrap branch has its own inline EOF logic and never calls
  `eff_next_row`, so a test written against the iterator cannot exercise the stepper.
- **Bug 4, CRLF phantom cell.** A row is `[start, end)` with `end` at the LF, so on CRLF it held the
  trailing CR — and only the *text draw* stripped it. `visible_next` now reports `vis_end` (backed by
  `base.pt_row_vis_end`), consumed by the caret, hit-test, selection, link scan and h-scroll width.
  **CRLF is atomic for the caret** (Wyatt approved): `End` stops on the content end, the arrows cross
  the pair in one step, and one Delete or Backspace at a break consumes the whole pair. That last
  part was missed on the first pass: making `End` land on the CR silently changed what `doc_delete_fwd`
  does, so Delete removed only the CR, the document still rendered as two lines (the keystroke looked
  dead), and a lone LF went to disk in a CRLF file. All five consumers now share `base.pt_crlf_at`.
  `pt_row_vis_end` strips only a genuine pair — `line_end` is also true at EOF and at a synthetic
  `RENDER_LINE_CAP` boundary, and stripping there made `End`/click stop at one offset while
  `Ctrl+End` reached another.
  *Diagnosis correction worth keeping:* of the four symptoms Wyatt reported, only the positional ones
  (caret past EOL, selection extent, click clamp) reproduced. `plat.text_cells` is literally
  `text_cell_width` summed, and CR measures 0 cells, so "wrap breaks one column early" did not
  reproduce and "Col reads one too high" was never established (`doc_cursor_col` measures
  line-start→cursor and never touches the CR). **If a wrap-width issue shows up again it is a
  different bug.** C0 controls are now in `plat.is_zero_width` so that zero is true by construction
  rather than a DirectWrite accident, and the untestable wrap-budget skip that assumed otherwise is
  gone.
- **Bug 10, word nav asymmetry.** Ctrl+Right landed on word *ends*, Ctrl+Left on word *starts*. New
  `base/words.odin`: three classes (word / punct / space), both directions landing on token starts.
  It lives in `base` because the old predicate was file-private in `package main` where `odin test`
  could not reach it — which is why the asymmetry had no test. A line break is whitespace and is
  crossed, not stopped on. Non-ASCII punctuation still classes as a word character (needs rune
  decoding in the nav loop); recorded as an accepted limitation.
- **Bug 5, `(no matches)` flicker.** Every edit clears the match arrays and restarts the worker, and
  the status text tested only `len(matches) == 0`. Now a sticky last-published count shown while
  `search_running`. The reset belongs in the four *query-edit* paths only — `find_recompute` is also
  called by replace, so resetting there wipes the value that stops the flicker. And the sticky copy
  goes *after* `find_merge`'s jump block, or `f.current` is still -1 and the bar reads `(0/N)`.
  The test fixture must exceed `SEARCH_SYNC_MAX` (256 KiB) or the search runs inline and the
  assertion passes with the bug present.
- **Bug 3, Ctrl+H spacing.** The caret now marks the focused field and reserves nothing in the other.
  The first attempt gave it a fixed-width slot in both states, which made both agree at *two* spaces
  — the exact string from the bug report. The accepted trade: the count shifts one cell when focus
  moves. **No automated test, by Wyatt's decision** — asserting on glyph advances would test
  DirectWrite's metrics, not our layout.
- **Bug 8, markdown table columns.** Was: each row advanced `x` by its own cell widths, so columns
  could not line up by construction; the separator row was skipped instead of becoming a rule; and
  `strings.trim(line, "| ")` ate empty leading cells. Now a two-pass measure **cached per table
  block**, keyed on `{start, end, revision}`, four slots round-robin. Widths are a property of the
  block, not of the visible rows — measuring from visible rows makes them a function of scroll
  position, which Wyatt rejected outright. Hard-won details:
  - Bound both scans from the **entry point**, never from the moving `start`: `start - q` is
    invariantly zero (the loop assigns both), so a guard written that way is dead and the walk runs
    to byte 0 through the *uncapped* `pt_line_start`.
  - Derive `oversize` from the **window** (`trunc_back || trunc_fwd || (end-start) > budget ||
    total_rows > cap`), not from which guard fired. Deriving it from the guards made the flag — and
    therefore every column width — depend on where the viewport entered the block, which is the
    scroll shift the design exists to prevent. The same trap recurs in the row dimension.
  - Bound **iterations** as well as bytes: each scanned row costs two fixed 4 KB `pt_read`s
    regardless of row length, so a byte budget alone does not bound the work.
  - A non-line-start entry is forced oversize: `markdown_draw` walks a `>RENDER_LINE_CAP` line in
    capped segments, so `p` is not always a line start.
- **`Document.revision`** (new) is the cache key: monotonic, bumped in `push_undo` *before* the
  `doc.batch` early return. The comment claiming "every edit path routes through here" was **false** —
  `apply_snapshot`, `doc_absorb_append`, `doc_reload` and `doc_recover_from_fault` all bypass it and
  now bump directly. `doc_reload` replaces the whole `Document`, so it carries the old value forward
  and bumps rather than resetting to zero.

**The lesson this batch adds to §6j.** Not just "test the seam" — **confirm the symptom before
designing its fix.** Two of the six symptoms did not reproduce as reported, and the code written for
them shipped with assertions that passed either way. One line measuring the CR's cell width up front
would have removed nine lines of code and a round of review. Relatedly, three separate tests in this
batch could not fail as first written: one reused a `Document` so the cache short-circuited the very
property under test, one compared the two word-nav walks index-for-index (structurally impossible),
and one used a fixture below the async search threshold. **A test written from a plan is not a test
until it has been watched failing.**

**Owed, not done:** Wyatt's live pass on all six symptoms (this environment cannot inject GUI input);
the visual check on bug 3; and a real ≥100k-row pipe-delimited log in Split markdown mode with
keystroke frame timing, to confirm `MD_TABLE_MAX_ROWS = 1024` is the right number.

**Note:** release is now ~1.10 MB (was 0.87 MB at 0.9.0). `test_modes.odin` still ships in the
release binary and this batch added ~730 lines to it — the §5 debt item "gate the harness behind a
build flag" is now the largest single contributor to binary size.

## 6t. Live-feature batch 2 (2026-07-25, branch `feat/live-feature-batch-2`, v0.11.0)

The four *features* §6s deferred from the 0.9.0 live-use report, plus the prerequisite Enter/`doc.eol`
fix §6s's scope note called out. Design in `docs/superpowers/specs/2026-07-25-feature-batch-2-design.md`,
plan in `docs/superpowers/plans/2026-07-25-feature-batch-2.md`, per-task briefs/reports in
`.superpowers/sdd/task-{1..5}-{brief,report}.md`.

- **Enter writes the document's own line ending (prerequisite, task 1).** `doc_insert_newline` wrote a
  bare LF regardless of `doc.eol`, so every Enter in a CRLF file mixed the file's own endings, and
  since `doc.eol` is detected only at open, the status bar kept claiming CRLF while the bytes drifted
  to mixed. Flagged, not assumed, as priority-1 correctness and a hard prerequisite for task 2's
  terminator rule below — a line move that preserves terminator identity is meaningless if the newline
  it moved was already wrong.
- **Alt+Up/Alt+Down move the selected range (task 2).** One undo per press, no-op at the first/last
  line, byte-preserving. The real design work was the **terminator model**: carrying each line's own
  terminator forced synthesizing one when the piece landing first was the unterminated last line, and
  synthesis wrote `doc.eol` over a break the user never touched — on a `.Mixed` document that silently
  converted a CRLF to an LF elsewhere in the file. Terminators now keep their byte positions and the
  *lines* swap between them, so nothing is ever synthesized. Four scans plus a full-line temp
  alloc/copy/insert were uncapped; now bounded by `MOVE_LINE_BUDGET` (2 MB) with a bail — not a
  truncation — on a cap hit, since reverting the bail while keeping the capped scans corrupts the
  buffer. Table view is read-only, so line move joined `command_mutates_doc`'s guard list (a fixed,
  silent CSV-corruption path).
- **Files dropped onto the window open as tabs (task 3).** Reuses the existing `WM_COPYDATA`
  open-paths queue rather than standing up a second one; `app_consume_open_requests` is the one path
  both the frame loop and `droptest` drive. Fixed along the way: `DragQueryFileW` truncates an
  overlong path silently with no way to detect it from the return value, so `wbuf` (sized in wide
  chars, where `OPEN_PATH_MAX` bounds UTF-8 bytes) now queries the true length first and skips rather
  than opening a shorter, wrong path. Also fixed: `on_drop_files` called `runtime.default_context()`
  inside a window procedure, which silently discards `context.assertion_failure_proc` — the
  `diag_assert_fail` hook `main()` installs to route panics through the crash reporter — so a panic in
  that handler would have bypassed crash reporting entirely. **Same latent gap flagged, not fixed, in
  `on_resize`/`on_dpi`** (main.odin): both call `default_context()` and never restore the assertion
  hook.
- **The Markdown Split divider is draggable (task 4).** `doc_editor_right` stays the sole source of the
  split x (grep-confirmed repo-wide); `Settings.split_frac` is one global fraction, not per-file, per
  Wyatt's call. Three clamps (load, save, drag), `settings_save` fires on mouse-up only (not per
  frame). Fixed: `md_divider_rect` spanned the full window height below the chrome with no upper
  y-bound on the hit-test, so in Split mode a press in the find/status bar strip at the divider's x
  started a spurious drag and settings save — that strip had never been interactive before (the quad
  was decorative). The rect now stops at `winh - doc_bottom_bar_h(doc)`, tracking the find bar being
  open, and both the hit-test and the draw read the same rect fields.
- **Per-family view memory (task 5, this pass).** Wyatt's complaint: switch a `.md` to Split, open
  another `.md`, and it comes back plain. His call: one remembered default **per family** (markdown ->
  Off/Preview/Split, tabular -> Off/Table), learned implicitly from the last view toggled, with a
  `remember_views` Settings toggle that turns "learn" into "pin." Three new `Settings` fields
  (`md_default`, `table_default`, `remember_views`; `md_default` range-checked on load exactly like
  `link_style`/`font_style` — an out-of-range value degrades to `.Off`, never an invalid enum), three
  appended `SETTINGS_ROWS` (appended, not inserted — the value display is an index-based `switch i`
  against that array), and `app_apply_view_defaults(a, doc)`.
  - **The fresh-open/session-restore seam, checked before wiring anything up:** `app_open_path`
    (dialog, command-line arg, drag-drop, link-open — every route in main.odin/links.odin) is the one
    fresh-open entry point, and it alone now calls `app_apply_view_defaults` after `doc_open` succeeds.
    `session_restore` builds its Documents directly via `doc_open`/`doc_from_content` and calls neither
    `app_open_path` nor `app_apply_view_defaults` — the two paths already didn't share code, so no
    opt-out flag was needed. Sabotage-tested: wiring the call into `session_restore`'s restore loop
    made the restore assertion in `viewmemtest` fail exactly as expected (a restored `.md` tab flipped
    to the family default instead of staying as left); reverted before commit.
  - **Finding, not fixed — logged here as debt:** `session.txt` does not persist `md_mode`/`table` per
    tab today (only `wrap` is). A restored tab's view always comes back `.Off`/`false` regardless of
    what it was before the restart, independent of this feature. `viewmemtest`'s restore assertion
    therefore proves the property that actually matters — `app_apply_view_defaults` is unreachable from
    the restore path, so it can never overwrite a per-tab value — rather than a genuinely round-tripped
    one. Persisting `md_mode`/`table` in the session format is separate, future work; this task's
    protection holds either way.
  - Deliberately **not** wired into `app_new_scratch`: an untitled buffer's path is `""`, and
    `doc_is_markdownish("")`/`doc_is_tabular("")` both return true ("don't limit an unnamed buffer" —
    see doc.odin), so applying the family default there would silently open every new blank tab in
    Split/Table whenever a default was set, before the buffer has a file type at all. Family defaults
    apply only where the family is actually known: a path with an extension.

**Owed, not done:** Wyatt's live pass (Alt+arrow with real auto-repeat; an Explorer drag of several
files and of a folder; dragging the divider and confirming it survives a restart; opening a `.md`
after leaving the previous one in Split — this environment cannot inject GUI input). The
`on_resize`/`on_dpi` `default_context()` gap flagged under task 3. Persisting `md_mode`/`table` per tab
in the session format (task 5 finding above). The project-wide forgotten-feature audit that follows
this batch, per Wyatt's decision to keep it a separate written report rather than fold it in here.

**Found by the whole-branch review, recorded rather than fixed:**

- **Paste still writes clipboard bytes verbatim** (`commands.odin`). The Windows clipboard is CRLF by
  convention, so pasting multi-line text into an LF file produces exactly the silent line-ending
  mixing task 0 was justified by — via the most common way multi-line text enters a buffer. Task 0's
  sweep judged paste "correctly left alone" on the grounds that a paste should preserve what was
  copied. Defensible, but it is the opposite conclusion from task 0 on the same harm, so it is
  written down here rather than left as an undocumented split decision.
- **`doc_reload` loses the view.** It rebuilds via `doc_open` preserving `wrap` but not
  `md_mode`/`table`, so an external-change reload silently resets a tab's view. Pre-existing, but this
  batch makes it visible: with `md_default = .Split`, a reload now disagrees with what a fresh open of
  the same file would do.
- **`test_modes.odin` grew ~600 more lines** (five new modes). §6s already flagged it as the largest
  single contributor to release binary size, since it is `package main` and ships in the release exe.
  Gating the harness behind a build flag is now the highest-value size item by a wide margin.
- **Six test modes wrote real user state.** `splittest`, `viewmemtest`, `settingstest`, `sessiontest`,
  `diskstamptest` and `sessionlosstest` all wrote to `session_dir()`, which falls back to the real
  per-user Newtpad folder under `%APPDATA%` — so running any of them bare destroyed real settings and
  the session store including unsaved-tab backups. They now refuse to run without
  `NEWTPAD_SESSION_DIR`. A documented constraint that nothing enforced was not a constraint.

**Out of scope, confirmed still out:** rebindable keys, a duplicate-line command (offered and
declined), per-family split fractions, opening a folder's contents.

## 6u. Next up — the feature audit and the batch plan (2026-07-25)

After batches 1 and 2 shipped (§6s, §6t), Wyatt asked for a sweep of the whole tree for features
that were promised and never delivered. The result is
[docs/2026-07-25-forgotten-feature-audit.md](docs/2026-07-25-forgotten-feature-audit.md). **Read it
before starting anything below** — it is the evidence, this section is only the plan.

**The audit's first pass was wrong in a way worth remembering.** It swept for `TODO` markers and
deferred-work comments, which by construction cannot find a feature nobody ever started — and nobody
leaves a TODO for work they never began. Reading `research/demand-side-feature-research.md` and
CLAUDE.md's product principles *as commitments* is what actually surfaced the gaps. The largest:

- **There is no syntax highlighting at all.** Zero lexers; every "highlight" in the tree is a
  find-match or selection rectangle; `doc_draw` paints every byte of every file one colour. CLAUDE.md
  states lex/highlight as a hard rule and the viewport-first machinery was built to serve it.
- **Column/block editing was V1 decision #1** (research §G, the "consensus #1 gap" flagged by 4 of 6
  research lenses) and was never started.
- **Themes, rebindable keys and an embedded installer** are all named in CLAUDE.md's product
  principles and none exist. 107 hardcoded colour literals across 14 files.
- Logging *is* real (`%APPDATA%\Newtpad\logs\newtpad.log`, on by default since 0.9.0) — it is simply
  undiscoverable, with no command or menu entry.

### Decisions taken with Wyatt, 2026-07-25 — do not relitigate

1. **Theme model first, then syntax highlighting.** Highlighting introduces ~5 new colour roles per
   format; if themes come after, every one is hardcoded and then migrated. The colour model lands
   first so lexers emit *role names*, never RGB. (The audit's own suggested order had this backwards;
   this supersedes it.)
2. **Column editing = rectangular select + edit.** Alt+drag or Ctrl+Shift+arrows makes a rectangle;
   typing replaces across every row; Backspace/Delete work across it; a zero-width rectangle acts as N
   carets in one column so lines can be prefixed; copy/paste handles the block as rows. **Ctrl+D
   select-next-occurrence is explicitly out** — that is the multi-cursor work research §G deferred to
   V2.
3. **Installer: build it unsigned but signing-ready.** A real self-contained installer (no PowerShell
   execution policy, proper uninstall entry) plus a release script with the signing step stubbed and
   documented, so it becomes one command the day a certificate exists. **Signing itself is blocked on
   Wyatt** — it needs a purchased code-signing certificate (OV cert, or Azure Trusted Signing). Claude
   cannot produce one, and must never handle a certificate password.

### Batch plan

| Batch | Contents |
|---|---|
| **3** | Colour model + themes — the foundation; must precede highlighting |
| **4** | Syntax highlighting — lexers emitting theme roles |
| **5** | Column/block editing |
| **6** | Session persists `md_mode`/`table`; `doc_reload` keeps the view; the `on_resize`/`on_dpi` crash-reporter fix; an "Open Logs Folder" command; encoding commands in the menus |
| **7** | Ship-readiness: real installer, signing pipeline, gate `test_modes.odin` behind a build flag, glyph-atlas eviction |
| **8** | Tier-3 wins: rebindable keys, tab stops, sort/dedupe lines, keyword→colour rules, bookmarks, scrollbar match marks |

Each batch: spec in `docs/superpowers/specs/`, plan in `docs/superpowers/plans/`, executed one task at
a time with a fresh implementer and a review per task, then Wyatt's live pass. That loop caught a
data-integrity regression in each of the last two batches; do not skip the review round.

### Batch 3 design, as agreed

- `program/theme.odin`: a `Color_Role` enum covering every semantic slot, and
  `Theme :: [Color_Role][4]f32` — a **total array over the enum**, so a new role cannot be forgotten.
  Same compiler-enforced pattern as `[Command_Id]Command`, with a matching `#assert`. A global
  `g_theme` read by array index keeps the per-row draw cost to an index, not a lookup.
- **Roles** come from the existing 107 literals (text, caret, selection, find-match, gutter,
  scrollbar, tab active/inactive, menu, palette, status, link, the ten `MD_*`, table, history,
  divider) **plus the syntax roles batch 4 will need** — keyword, string, number, comment, type,
  punctuation. Declaring those now is the entire reason this batch goes first.
- `markdown.odin` already has the right shape (`MD_TEXT`, `MD_HEAD`, `MD_CODE`…) — named roles, just
  compile-time and per-file. Generalise that; do not invent a second pattern.
- **Theme files** at `%APPDATA%\Newtpad\themes\*.theme`, `role #rrggbb` lines — the same key/value
  shape as `settings.txt`, unknown keys ignored, so old and new builds interoperate. One Settings row
  to pick a theme. **Not** a colour picker per role; that is the "fight options" line.
- **Ship a light theme, not only the current dark one.** Building dark alone proves nothing — a light
  background is what exposes every colour that silently assumed dark (muted greys that vanish,
  overlays tuned against a dark base). It is the test that can actually fail.
- **Testing:** headless `themetest` — every role set in every built-in theme (no zero-value black
  holes), file round-trip, unknown role ignored, malformed colour degrades rather than corrupting.
  Plus the compile-time `#assert` on the array length.

### Repo state at handoff

`main` @ 0.11.0, working tree clean, both feature branches merged (`fix/live-bug-batch-1`,
`feat/live-feature-batch-2` — safe to delete). The installed binary at
`%LOCALAPPDATA%\Newtpad\newtpad.exe` is the merged build. **`main` is ~68 commits ahead of
`origin/main` — nothing has been pushed.**

**Live pass still owed** on batch 2: Alt+arrow with real auto-repeat, an Explorer drag of several
files and of a folder, dragging the split divider and confirming it survives a restart, and opening a
`.md` after leaving the previous one in Split. This environment cannot inject GUI input, so those are
Wyatt's to confirm.

## 6v. Colour model and themes (2026-07-25, v0.12.0, branch `feat/theme-model`)

Batch 3 of the six in §6u, and the first of them to ship. Themes are named in CLAUDE.md principle 4 and
had never existed: 107 hardcoded colour literals across 14 files, zero occurrences of "theme".

Design in `docs/superpowers/specs/2026-07-25-theme-model-design.md`, plan in
`docs/superpowers/plans/2026-07-25-theme-model.md`.

**Why this went before syntax highlighting.** Highlighting introduces ~5 colour roles per format; if
the model landed after it, every one would be written as RGB and migrated immediately. Batch 4's
lexers can now emit role names from their first line. Nine `Syn_*` roles are already declared and
deliberately unused — magenta in Dark as a "missing texture" marker, real values in Light. **Do not
delete them as dead code.**

### The model

`Color_Role` enum, `Theme :: [Color_Role][4]f32`, one global `g_theme` read by array index in the
per-frame path. The total-array-over-the-enum shape means a new role forces every theme to supply a
value — and note *why* that holds: **Odin rejects an incomplete keyed enumerated-array composite
literal at compile time**, verified empirically against this repo's compiler. The `#assert` next to it
guards something narrower (that `Theme` stays defined in terms of the enum rather than being
hand-rolled to a fixed size); the comment there says so.

### 66 roles became 25, and the guard changed with it

A faithful one-role-per-literal model came to 66 — a theme nobody would author. Clustering the 61
distinct values by chroma and luminance found the real structure: **ten neutral tiers absorbing 42
near-duplicate greys across 81 sites**, plus **fifteen semantic accents**. `Text_Muted` alone was seven
shades doing one job across 18 sites.

Consequence: **Dark is deliberately not pixel-identical to v0.11.0** — roughly 50 sites shift slightly.
That forfeited the original mechanical guard ("if any pixel changes, the migration is wrong"), replaced
by: every role must hold **one of the literals its row in the spec's merge table lists**, encoded as
data in `themetest` and transcribed from the spec rather than from `theme_dark`. A typo lands on no
list and fails; an intended merge passes.

Five of `markdown.odin`'s ten `MD_*` roles dissolved into generic neutrals, so **markdown body text is
no longer themeable independently of chrome text**. Each dissolved role is traced to its new home in
`theme.odin`'s per-role comments.

### The light theme is what made this worth doing

Every colour in the tree was chosen against a dark background over months. A dark-only model is
indistinguishable from a rename. Light, judged by arithmetic since nothing here can see a screen,
found four real defects that would otherwise have shipped:

- **The caret was invisible** — Dark's `#F2D959` computes to **1.42:1** on white. Light's is `#946200`
  at 5.30:1: deepened, not lightened.
- **Three highlight fills were near-invisible**, each a case where the fill is the *only* cue:
  `Find_Match_Bg` at **1.28:1**, `Selection_Doc` (in-document text selection) at **1.48:1**, and
  `Selection_List` (menu hover, history selection — keyboard menu navigation has no other indicator) at
  **1.12:1**. All now clear 1.6:1.

The first contrast audit measured text-on-background pairs exhaustively and **missed all three fills**,
because a fill sits on a surface rather than carrying text. The lesson worth keeping: *audit fills
against their surfaces, not just foregrounds against backgrounds.*

`Danger` is the only role deliberately shared between themes — a solid hover fill never blended with
chrome, and Windows renders that hover the same red under either system theme. The shared-role
mechanism defaults to "must differ", so a role that accidentally matches fails loudly.

### Theme files

`%APPDATA%\Newtpad\themes\*.theme`, `role #rrggbb` lines, mirroring `settings_load` — unknown keys
ignored, so old and new builds interoperate. A partial file overlays a built-in; a malformed colour
(`#zzz`, `#12`, no `#`, wrong length, empty, trailing garbage) leaves that role at its built-in value
and **never** at black, which would be an invisible hole rather than an obvious error.

A `base dark|light` key, recognised **anywhere in the file**, says which built-in a custom theme
extends. Without it a light-based custom theme was inexpressible at any level of partiality, and a
Light user selecting any partial custom theme silently got Dark's entire scheme back.

One Settings row picks a theme, by name rather than index. The row list now scrolls — the eighth row
overflowed at 150% DPI on a 1366×768 screen and overprinted the version string, while staying
keyboard-selectable off-screen.

### Two things the batch got wrong that are worth remembering

- **The document canvas survived all five task reviews.** `main.odin`'s `gfx_begin_frame` passed the
  clear colour as three loose `f32` arguments, not a `[4]f32` composite — invisible to every grep in
  the batch, all of which matched `{r, g, b, a}`. Under Light that was near-black text on a near-black
  canvas across the whole document body, with correct chrome around it. Caught only by the
  whole-branch review. **A migration grep is only as good as the shapes it looks for.**
- **`themetest` proves the palette, never the mapping.** Nothing checks that a call site uses the role
  the merge table assigned it; swapping two roles at any of the 107 sites still passes. The mapping
  rests entirely on human review, which is why each task's review re-derived every substitution by
  hand.

### Owed and open

- **Wyatt's live pass.** Ranked in the review; the top three: switch to Light and confirm the document
  body is actually white with readable text; open a menu and History in Light and confirm the selected
  row is visible; check Settings at 150% DPI on the 1366×768 laptop. Then the Dark regression sites that
  actually moved — disabled menu items (now brighter, may not read as greyed out), inactive tabs,
  the scrollbar thumb, markdown bullets.
- **Two role splits, deferred for Wyatt's decision.** `Border_Subtle` serves a table hairline *and* the
  active-tab elevated fill; on light, `Bg_Base` is `#FFFFFF` so nothing can be lighter and both jobs are
  forced to want "darker" — the argument is geometric, not numeric. `Text_Muted` is simultaneously
  gutter/hint text *and* the scrollbar thumb, so darkening it for legibility darkens the thumb. Both are
  the same underlying issue: the neutral ramp was clustered by luminance without separating fills from
  foregrounds.
- **`table.odin`'s header/body text cue is gone** — both land in `Text_Primary`. The header keeps its
  `Bg_Raised` band, so the row is still identifiable; only the text-weight difference went.
- Minor, carried: a `theme_name` clone per Settings cycle press with no free; a file named
  `Dark.theme`/`Light.theme` lists but can never load; custom-theme cycling follows directory order and
  is unstable between runs; a later invalid `base` line does not reset an earlier valid one.
- **Layer note for the `renderer`/`ui` extraction:** this makes it *easier* — 107 embedded design
  decisions left the draw code — but `Color_Role`/`Theme`/`g_theme` live in `package main` today. When
  `ui` becomes its own package it will need them, and `ui`→`program` is backwards, so `theme.odin` will
  have to **split**: type and built-ins down into `ui`, the loader staying in `program` because it
  depends on `session_dir()`. A split, not a move.

## 6w. Syntax highlighting (2026-07-26, v0.13.0, branch `feat/syntax-highlighting`)

Batch 4 of the six in §6u, following §6v's colour model. There was **no syntax highlighting at all**
before this batch — every "highlight" in the tree was a find-match or selection rectangle, and
`doc_draw` painted every byte of every file one colour. Design in
`docs/superpowers/specs/2026-07-25-syntax-highlighting-design.md`, five tasks executed one lexer-family
at a time with a review per task (`.superpowers/sdd/task-{1..5}-report.md`).

**The pipeline needed no renderer changes.** `plat.text_draw_spans` already existed and `links.odin`
already fed it `[]Text_Span` per row — highlighting is a second span producer on that same proven seam.
Every lexer is a pure function in `src/base` (`line []u8, state_in Lex_State -> tokens, state_out`),
mapped to a `Color_Role` only in `program/highlight.odin`, which is what keeps every lexer testable with
`odin test src\base` alone, no `Document`, no GPU.

### The state strategy, and its documented failure mode

Colouring the row at `doc.top` needs the lexer's state *there* (inside a block comment? a block
scalar?), and `doc.top` can be any byte offset in a multi-GB file. Two paths, mirroring the existing
copy-small/mmap-large split:

- **Small files**: a background per-line `Lex_State` index (`program/lex_index.odin`), built once,
  always exact — mirrors `Line_Index` field-for-field.
- **Huge (mapped) files**: a bounded backward resync — scan back up to a window (64 KiB, 4 KiB while
  filtering) for a position unambiguously `.Normal`, then lex forward. **Documented failure mode**: a
  construct longer than the window mis-colours until scrolled to its start.

Two lessons this batch paid for more than once and are worth restating for whoever adds an eighth
lexer: **(1)** a stateful lexer must keep *scanning* for state past its token-buffer cap even once it
stops *emitting* — shipped wrong twice (Task 3's `lex_xml`, Task 4's C-family resync validator) before
every stateful lexer got a small-`out` test proving it. **(2)** a keyword table nobody tests for a
*specific* word is a table with a hole in it — Task 4's Go table shipped missing `func` (the language's
single most common keyword) because its only fixture reached every coloured word through `type_intro`.
Every keyword table added since asserts at least one real word from the plain `keywords` list, not just
`type_intro`.

### Coverage — the seven lexers, and where `.sql`/`.css` landed

| Lexer | Extensions | State |
|---|---|---|
| Log (pattern, not grammar) | `.log` | none |
| JSON | `.json` | none |
| XML/HTML | `.xml .html` | `<!-- -->` (anchor `-->`, trusted unconditionally) |
| C-family (one grammar, keyword-set data) | `.c .h .cpp .hpp .cs .java .js .ts .go .rs .odin .css .sql` | `/* */`, nesting depth for Rust/Odin |
| Markdown (source view only) | `.md .markdown` | fenced code blocks |
| Delimited | `.csv .tsv` | none |
| Config | `.ini .toml .cfg .conf .env .gitignore` | none |
| YAML | `.yaml .yml` | block scalars (`|`/`>`) |
| Shell | `.sh .bat .ps1` | only `.ps1`'s `<# #>` |

**`.css` and `.sql` fold into the C-family grammar** rather than earning their own lexers (one more
`Keyword_Set` each, `CSS_KW`/`SQL_KW` in `lex_c.odin`) — both disclose a real, bounded gap from reusing
the grammar unmodified rather than teaching it a new comment marker: CSS has no `//` line comment at
all, so a stylesheet's `url(https://...)` mis-colours everything after the `//` to end-of-line (bounded
to that one line, self-correcting on the next); SQL's real line comment is `--`, which this grammar
doesn't recognize either, so a `-- SELECT the right index` comment has `SELECT` colour as a Keyword
*inside* the comment — the sharper of the two, since SQL comments routinely contain real SQL words.
Both are stated as a deliberate trade (fixing them means teaching the shared C-family matcher a
second, per-language line-comment marker — a change to reviewed matching logic, not a new data table)
rather than fixed unilaterally; a real follow-up candidate if it bites in practice.

**Markdown colours the SOURCE view.** `markdown.odin`'s Ctrl+M styled preview is a completely separate
feature, untouched.

**One config lexer honestly serves six of the eight `.ini`-family extensions** (`.ini .toml .cfg .conf
.env .gitignore`) — genuinely shared shape: an optional comment, an optional `[section]` header, an
optional `key = value` pair, otherwise plain pattern text. **YAML got its own, separate, stateful
lexer** rather than being squeezed in: significant indentation and multi-line block scalars are not
line-local the way the other six are.

**YAML's block scalar depth DOES fit `Lex_State`'s one byte** (verified by building it, not assumed —
same raw-byte-as-depth trick Task 4 proved for C-family comment nesting: the byte holds the introducing
key's indent + 1). What does **not** fit is a resync anchor for huge/mapped files: the scalar's end is
the *following* line's indentation relative to an arbitrarily distant key, which
`Resync_Validate_Proc`'s one-physical-line signature cannot express at all. Markdown's fenced code
block has an unrelated but similarly-shaped problem: ` ``` ` **toggles** state (same bytes open and
close it), so "the last occurrence in a window" doesn't say whether it opened or closed without knowing
parity since a genuinely unambiguous point. Both are registered stateful (so the small-file background
index — which never touches the anchor, it just scans from the true start — stays exact) with a
resync validator that **always rejects**, so a huge file of either kind always cap-hits to `.Normal` on
resync, not merely when a construct outgrows the window the way every other stateful entry's failure
mode works. Stated explicitly rather than approximated, per the task brief's own instruction.

**A real, unrelated gap the coverage test caught before this task even wrote a lexer**: `.py` is in
`text_exts.txt` (34 entries) and in the design doc's own "34 extensions" count, but no lexer was ever
assigned to it across any of the four earlier tasks — nobody had noticed. `program/highlight.odin` now
carries an explicit `DELIBERATELY_PLAIN_EXTS` list (`.txt`, `.py`) rather than leaving "no lexer" as an
absence nobody asserts over, and `newtpad lexcoveragetest` (new headless mode) asserts every extension
in the *actual* `text_exts.txt` resolves to one or the other — this is the check that outlives the
task: adding a 35th extension without a lexer or a plain-list entry now fails a test instead of being
noticed on screen.

### Verification

`odin test src\base` (192 tests, all passing, zero new leaks beyond the pre-existing `pt_collect`
warnings), `lexstatetest`/`highlighttest`/`lexcoveragetest`/`rowtest`/`crlftest`/`mdtabletest`/
`splittest`/`movelinetest`/`themetest`/`settingstest` all green. Every stateful lexer (markdown, yaml,
`.ps1`) has a zero-capacity-`out` test proving its state transition is computed before, and independent
of, whether a token could be written — the direct descendant of the Task 3/4 bug shape.

**`build.bat release` is past the ~5 s rule, but this batch is not why.** The first draft of this
entry said "5.8 s before this batch, ~8.3–8.7 s now," which would have sent someone hunting a 2.7 s
regression inside these five tasks. The 5.8 s came from the plan and was stale. Measured A/B on this
machine, same toolchain, warm, three runs each: **v0.12.0 8.1 s, v0.13.0 10.2 s**; debug 1.1 s at
both. So the rule was already breached by ~60% before batch 4 started and this adds ~2 s of LLVM at
`-o:speed` on ~4,000 new lines. Now in the §5 debt register, where it belongs. Removing all twelve
`src/base/*_test.odin` files changes nothing, so the `@(test)` corpus is not the cause.

### The whole-branch review, and the shape it kept finding

The final review's most useful finding was not a bug but a **pattern**: *a component reads a bounded
or truncated slice, cannot tell it was truncated, and returns a confident answer anyway.* Six
commits on this branch exist because of it — `lex_xml` at its row buffer, `lex_c_resync_valid` at
its 256-token buffer, the same again at a truncated line. Told to go looking for a fourth, the
review found it in `doc_row_lex_spans`; told to go looking for a fifth, the fix pass found it in
`links.odin` — pre-existing, nothing to do with highlighting, and the worse bug of the two: with
word wrap on, a URL past ~4 KB into a logical line was **neither underlined nor clickable**. Both
had the same root: `pt_line_start_cap` returns `(floor, exact)` and both call sites discarded
`exact`, so a scan floor that *slides with the row* was used as a line start.

The fix is one shared decision — `doc_row_lex_extent` (`doc.odin`) returns the byte range a row's
spans come from and whether that range is a whole logical line, and **both** consumers (the span
builder and `doc_draw`'s first-row state bootstrap) ask it. That is "one layout per widget" applied
to a lexing extent, and it removes the diverge-across-two-sites mechanism rather than patching one
side. `links_layout` got the same treatment.

Two things worth keeping from how that landed:

- **Two commits on this branch did not compile.** `git bisect` would have hit them. Both were
  "wire it up" commits where an interface change and its call-site updates were split across a
  commit boundary; both were fixed by the very next commit. Squashed before merge, and every one of
  the 25 commits now passes `odin check src/program`. Worth checking on any branch that changes a
  signature in one commit and its callers in another.
- **One guard cannot be sabotage-tested, and that is now asserted rather than left as a
  coincidence.** Removing `doc_row_lex_extent`'s `exact` check leaves every test green — because
  `WRAP_START_CAP == RENDER_LINE_CAP` means the *other* guard catches the same rows.
  `#assert(WRAP_START_CAP >= RENDER_LINE_CAP)` is what keeps that true; drop the cap below and the
  guard becomes load-bearing with nothing testing it.

### Owed and open

- **v0.13.0 release — DONE (2026-07-26).**
  [Release v0.13.0](https://github.com/WGuethlein/Newtpad/releases/tag/v0.13.0), tag on `main`,
  `newtpad.exe` (1.26 MB) attached. Wyatt's call: **just v0.13.0, no backfill** — v0.10.0–v0.12.0
  stay untagged, and the auto-generated notes span back to v0.9.0, so four batches appear as one
  release. Tag history is therefore permanently out of step with version history; that is known and
  accepted, not an oversight to "fix" later.
  - **The `gh`-not-on-PATH trap was live and is now fixed in the script.** `gh` 2.96.0 was installed
    but absent from this session's PATH, exactly as predicted. `release.ps1` no longer gates on
    `Get-Command gh` alone: it falls back to `C:\Program Files\GitHub CLI\gh.exe`, and if it still
    cannot find `gh` it **exits non-zero** instead of printing the manual-upload message as though
    the release had succeeded. It also checks `$LASTEXITCODE` after `gh release create`.
  - **The notes say the build is unsigned**, since the repo is public and every download trips
    SmartScreen. Signing is blocked on Wyatt buying a certificate (§6u batch 7) — Claude must never
    handle the certificate password.
  - **An em dash in `release.ps1` shipped as mojibake into the published notes.** PowerShell 5.1
    decodes a BOM-less `.ps1` as ANSI, so the character was already corrupt before `gh` was invoked;
    the release body was repaired and the note is now ASCII-only with a comment saying why. The
    general form of this trap is in `docs/development-loop.md` §6. Verifying by reading `gh`'s
    output in the console would not have caught it — the console mangles it identically. The check
    that worked was dumping the bytes GitHub actually stored.
  - **The release exe is 1.26 MB**, against the 0.90 MB recorded in §7 (2026-07-19). Growth is
    consistent with `test_modes.odin` shipping in `package main` (§5) plus batch 4's lexers. Not
    investigated; §7's figure is now stale.
- **Wyatt's live pass** — one file of each family, in both themes. The nine `Syn_*` roles were chosen
  by arithmetic in batch 3 (§6v) and have never been seen against real code, Light especially.
- The two "always cap-hit" resync gaps above (YAML, Markdown) are correct by construction but untested
  against a genuinely multi-GB file of either kind in the wild.
- `.py` has no lexer at all — a real follow-up task, not a guess this batch was willing to make (see
  `DELIBERATELY_PLAIN_EXTS`'s own comment, `program/highlight.odin`).
- SQL's `--` comment gap and CSS's `//`-in-`url()` gap (above) are both real, disclosed trade-offs, not
  fixed — see `CSS_KW`/`SQL_KW`'s own comments in `lex_c.odin`. One `line_comment` field on
  `Keyword_Set` closes both; the reason it wasn't done here is that it changes reviewed matching
  logic rather than adding a data table.
- **`cur_buf` saturation on the whole-line path** — now in the §5 debt register, with the reason the
  obvious fix is wrong. Visual only; state stays correct.
- The release-build overrun is in §5 now, correctly attributed. Not this batch's to fix.
- `links_layout`'s fragment fallback can emit a hit for text that is not a link in the document (a
  URL cut across a wrap point leaves a tail that scans as a `.Path`). It cannot become a different
  *site* — a URL needs a whitelisted scheme — and a spurious path only resolves if such a file
  exists beside the document, so the worst case is an underline that does nothing. Documented at the
  call site.

### What only Wyatt can check, ranked

Nothing in this environment can see a screen, and the nine `Syn_*` colours were chosen by arithmetic
in §6v and have never been rendered against real code.

1. **The `Syn_*` colours against real code, in Light and Dark.** Sharpest pairs: `Syn_Comment` vs
   `Text_Muted` (the gutter line numbers sit right beside it), `Syn_Punct` vs `Text_Primary` (if
   punctuation reads as body text, every `.Punct` token in this batch is wasted work), and
   `Syn_Json_Key`/`Syn_Xml_Attr`, two roles with no precedent in any editor's default theme.
2. **A minified `.json`, `.css` or `.xml` with word wrap on.** Where the `cur_buf` limit above shows:
   colour stops partway down the line. Confirm whether that reads as "unfinished" or just "long
   line."
3. **Scroll a large `.c` or `.xml` fast.** The documented resync failure mode looks, on screen, like
   *colour changing while you scroll* — the same byte coloured differently at different `doc.top`.
   Correct by design; only Wyatt can say whether it's tolerable or the 64 KiB window needs raising.
4. **Filter mode on a large `.c`/`.xml`/`.md`, typing live.** Per-row resync on every keystroke, and
   filter-as-you-type is a stated speed promise. The one path here that could break it.
5. **Ctrl-hover a URL inside a comment.** Links win by dropping the intersecting syntax span
   *whole*, so the entire comment loses its colour, not just the URL's bytes. Tested and correct;
   confirm it doesn't look like a glitch.
6. **A `.md` file in source view, then Ctrl+M.** Two features colouring one file — confirm they read
   as deliberate.

## 6x. Theme tuning loop (2026-07-26, v0.14.0, branch `feat/theme-tuning-loop`)

Wyatt's live pass on batch 4 found it in about a minute: **every syntax-highlighted file rendered
identically magenta in Dark** — JSON, YAML, CSV and Markdown all the same colour. Not a bad palette.
Dark's nine `Syn_*` roles were still literally `{1, 0, 1, 1}`, the "missing texture" marker §6v
planted for roles nothing consumed yet. Batch 4 shipped the lexers that consume them and **filled in
Light only**. It went out in v0.13.0 and was tagged, released and installed that way.

Design in `docs/superpowers/specs/2026-07-26-theme-tuning-loop-design.md`, plan in
`docs/superpowers/plans/2026-07-26-theme-tuning-loop.md`.

### Why this is a batch and not a one-line fix

Filling in nine values is trivial. What is not trivial is that the nine values were **chosen by
arithmetic and had never been seen by a human eye** — the same condition that produced the bug. Asked
how he wanted to tune them, Wyatt chose live-reloading a theme file over per-role inputs in Settings.
That is also the answer CLAUDE.md principle 3 wants: 34 colour pickers is precisely the chrome that
signals leakage in core design.

Two facts found while exploring turned that into real work:

- **The built-in themes have no file.** `theme_resolve` answers `Dark` and `Light` from
  `theme_dark()`/`theme_light()` without ever consulting disk. The theme Wyatt actually runs could
  not be reloaded, because there was nothing to reload.
- **No `.theme` file existed anywhere and nothing in the product created one.** The format shipped in
  batch 3 documented only in a source comment. A feature with no discoverable way to use it.

So the batch had to *supply* the file before it could watch it. **Edit Current Theme** exports the
active theme to `themes\Dark Custom.theme` (all 34 roles, with section comments), switches to it, and
opens it as a tab. Edit a colour, Ctrl+S, the window updates. Newtpad became the editor of its own
theme, which is the right shape for this product.

### What made the parser change worth doing

The nine `Syn_*` roles were also **unsettable from a file** — `theme_role_from_key` was a
hand-written 25-case switch and they were simply absent. So the file mechanism could not have worked
around the magenta even if a file had existed.

The fix is not "add nine cases". Export needs role→key and the parser needs key→role, and two
hand-maintained 34-entry mappings drift silently. Both now come from one `[Color_Role]string` **total
array**, so a role added without a key is a *compile error* — the same guarantee `Theme` and
`[Command_Id]Command` already carry. Sabotage-verified as a compile error, not a test failure:
`Unhandled enumerated array case: Syn_Xml_Attr`.

### Three things this batch got wrong

- **A test that could not fail, and the spec was the reason.** The export round-trip was guarded by a
  "second export is byte-identical" fixed-point check. Truncation is *idempotent*, so truncation is
  also a fixed point — the check was structurally incapable of catching the regression it was written
  for, and the drift bound of `1/255` admitted both. The property that separates them is accuracy:
  rounding errs by at most half a step. Bound tightened to `0.5/255`, which Dark's own `0.12` green
  channel (`30.6`) now separates. **The implementer found this by actually running the sabotage and
  reporting that nothing failed** — exactly what §3 of the development loop is for.
- **`delete()` on a static string literal, caught only by the whole-branch review.** `theme_edit_current`
  freed the old `settings.theme_name` before cloning the new one. But `settings_default` sets
  `theme_name = "Dark"` — a literal in `.rdata` — and `settings_load` only clones when `settings.txt`
  actually carries that key. **On a fresh install with no settings file, the first use of Edit Current
  Theme would `HeapFree` a pointer into read-only memory.** All six per-task reviews missed it because
  every test assigned `strings.clone("Dark")` on the line before the call, so the literal path was
  never executed. The free is gone (the site now matches the Settings cycle, which also does not free),
  and a test now drives it from a defaulted `Settings` with no clone.
- **A second test that did not observe the line it was named for.** The edit-loop case printed
  `reresolved=` but computed it from the test's *own* `theme_resolve` call, so deleting the real
  assignment in `theme_edit_current` left it green. Restructured to write the file first and assert
  `g_theme` moved with no intervening resolve; sabotage now yields `reresolved=false`.

The pattern across all three: **the tests were written by the same process that wrote the code, and
agreed with it.** Sabotage caught one, a reviewer with the whole branch in view caught the other two.

### Also in this batch

- Dark's nine syntax colours mirror Light's hue families (indigo→periwinkle, teal→cyan, rust→salmon…),
  ratios computed against `Bg_Base` rather than eyeballed. Two pairs are now **asserted** rather than
  left to Wyatt's eye: `Syn_Comment` must stay clear of `Text_Muted` (the gutter numbers sit right
  beside comments) and `Syn_Punct` clear of `Text_Primary`. Both were items 1 on §6w's
  "only Wyatt can check" list; they are tests now.
- A stray `Dark.theme` or `Light.theme` no longer lists in Settings. `theme_resolve` short-circuits on
  those names before touching disk, so such a file was an entry that silently did nothing — the
  "lists but can never load" defect §6v recorded and carried.
- The dropped-folder note was invisible for a findable reason: it is appended to the end of the status
  line and drawn in `Text_Dim` unless `warn` is set, which a notice did not set. Now the line goes
  amber for its four seconds and the message joins the `[BRACKETED CAPS]` idiom the other loud
  conditions use, counting folders and unreadable files separately.

### Owed and open

- **Wyatt's tuning pass is the point of the batch.** Run **Edit Current Theme** (View menu or the
  palette), tune, save. Sample files for it are at `C:\Users\Wyatt\Newtpad-testfiles` — `big.c`,
  `big.xml`, `big.md` (40/40/20 MB), `minified.json` and `minified.css` (single-line, for the
  `cur_buf` limit), and `links-in-comments.c`.
- **Light's `Syn_*` values are still provisional.** Deliberately untouched — the tuning loop is what
  settles them, and changing them blind would be guessing twice.
- **Carried, triaged CARRY by the whole-branch review:** `theme_export`'s `base` line defaults to
  `dark` for any non-`Light` name (unreachable via no-overwrite, and cosmetic since all 34 roles are
  written); the Settings theme cycle still leaks a `theme_name` clone per press (§6v already recorded
  it — now consistent with the export site rather than divergent); `themes_dir_ensure` swallows every
  `make_directory` error, not just "already exists"; and `theme_reapply_if_active` normalises case and
  separators but not relative or `..` paths.
- **`app_open_path` dedupes on a raw path compare** while this batch's theme comparison normalises. A
  theme file opened once by drop and once by the command can land in two tabs. Pre-existing dedupe
  behaviour, no data loss (the watcher marks the stale one), noted because the two comparisons are now
  visibly inconsistent.
- **For the `renderer`/`ui` extraction:** this made the split *easier* — replacing the switch with a
  data table removed a `program`-only dependency, and the App-coupled procs are grouped at the file
  tail. One concrete tidy-up: `theme_role_keys` and its two accessors are pure and belong with
  `Color_Role`, but sit below the `// --- theme files ---` banner. Move them above it and the eventual
  cut is one horizontal line.

## 6y. Column / block editing (2026-07-26, v0.15.0, branch `feat/column-editing`)

Batch 5 of §6u, and **V1 decision #1** — research §G's "consensus #1 gap", flagged by four of six
research lenses and never started until now. Alt+drag or Alt+Shift+arrows makes a rectangle; typing
replaces across every row; a zero-width rectangle acts as N carets so lines can be prefixed;
Backspace/Delete work across it; copy/cut yield the rows as lines. Ctrl+D stayed out, per §6u.

Design in `docs/superpowers/specs/2026-07-26-column-editing-design.md`, plan beside it.

### The fork that had to be answered first

A rectangle is defined over screen rows. With word wrap **on**, one logical line is many visual rows,
so "rows 10-13" means either four wrapped fragments of a single line or four whole lines — and those
produce different edits from the same gesture, with the visual reading depending on window width.
The spec stopped and asked rather than guessing. **Wyatt chose: column select requires wrap off.** It
is the only option where the same gesture on the same file always produces the same edit.

That answer is why `block_*` fields mean *logical* lines everywhere, and why four separate toggles
(wrap, markdown preview/split, filter, table) must clear a live rectangle.

**§6u's own gesture choice was wrong for this codebase and was overridden.** It named
Ctrl+Shift+arrows; but `default_bindings` matches on `(key, ctrl, alt, ctx)` with **shift read by the
action, not part of the chord** (`commands.odin:232`), so Ctrl+Shift+arrow is *already* word-wise
select-extend. Taking it would have broken word selection. Alt+Shift+arrows is the free equivalent,
and matches VS Code and Sublime.

### The model changed mid-batch, and that was the right call

The rectangle was first stored as `(logical line index, cell)`. It is now **`(byte offset of the
line's first byte, cell)`**, changed in `d69d85e` after task 4's review measured what a line number
actually costs here: **Newtpad has no line index.** Turning one back into a byte offset walks from
byte 0.

- A 10-row rectangle at line 28,000 of a 500 KiB log cost **48 ms per frame, steady state** — and
  `main.odin` does not wait for messages while `mouse_down`, so an Alt+drag paid it every frame.
  About 20 fps on an ordinary log file.
- Worse, `doc_line_start_of_index` capped at 512 KiB while creation allowed 4 MiB, so **a rectangle
  665 KiB deep created successfully and drew zero quads** — a selection the user can make and cannot
  see, which copy and edit would then have acted on.

Re-anchoring by byte offset took it to **0.079 ms**, and deleted `doc_line_start_of_index`,
`DOC_LINE_INDEX_CAP`, `block_lines_forward` and `caret_line_cell` outright. Doing it at task 4,
before copy and edit were written, is the only reason it was cheap. **The lesson generalises: a
coordinate that is cheap in one representation is not automatically cheap in this buffer, and the
piece tree makes byte offsets the natural currency.**

### One conversion point, and it held

`block_row_range` is the only place cell columns become byte ranges; the draw, the copy and the edit
all ask it. That is CLAUDE.md's "one layout per widget" applied to a non-widget, the same move batch 4
made with `doc_row_lex_extent`. The whole-branch review verified no second cell-counting walk exists
anywhere in the branch. It is why the drawn rectangle and the edited rectangle cannot disagree — and
every place they *did* disagree this batch was somewhere that bypassed it, never inside it.

### What this batch got wrong — nine defects, none found by the code's own tests

Every task passed its own tests and still carried a real defect. Each was found by a reviewer writing
independent probes rather than reading the report. In order:

- **A rune split at the 4096-byte chunk boundary, reported as success.** The refill guard was dead
  code: `utf8.decode_rune` returns `(RUNE_ERROR, 1)` for an incomplete tail, so `i + sz > n` could
  never be true. Copy would have emitted invalid UTF-8; edit would have corrupted the buffer.
- **Truncation refused on row *length***, so any rectangle over a minified JSON/CSS/log line resolved
  to nothing — and the test had baked that wrong expectation in for five successor tasks.
- **A 151 ms freeze**: `DOC_LINE_INDEX_CAP` bounded nothing, because the walk stepped through the
  *uncapped* `pt_line_end`. Now 1.16 ms.
- **A rectangle anchored at line 0 when the true line was 600000** — both axes fell back to 0 past
  their caps while still reporting success.
- **Every Alt+drag stranded the app in menu keyboard mode**, because `WM_LBUTTONDOWN` never set
  `alt_used`, so releasing Alt read as a bare Alt tap.
- **The wrap refusal checked `doc.wrap` instead of `doc_wraps()`**, so Markdown Split — which
  force-wraps — allowed a rectangle recording logical lines against wrapped rows.
- **A phantom undo entry that destroyed the redo stack:** an all-short rectangle's Cut changed no
  bytes but still opened a batch, setting `modified` and clearing redo.
- **A stale rectangle survived find-replace**, so the draw highlighted one row while Ctrl+X cut three
  — destroying text the user never saw selected.
- **An invisible linear selection coexisted with a rectangle.** `doc.anchor` was never collapsed on a
  successful Alt+drag, and the draw shows the rectangle *instead of* the linear span. Alt+drag down 50
  lines then Ctrl+V replaced all 50. Found only by the whole-branch review; the two models are now
  mutually exclusive by construction.

**The through-line: a test written by the same process that wrote the code agrees with it.** Two tests
on this branch were found structurally incapable of failing — one with a 450x margin, one measuring
press #0 of an operation whose cost climbs with every press. Sabotage caught some; independent probes
caught the rest. The reviewers that found the most were the ones told to *write a probe*, not to read.

### The cap is a workaround, and should be recorded as one

`BLOCK_EDIT_MAX_LINES` went **10,000 → 2,000 → 300** across the batch. Each keystroke issues N
independent splices, so the treap fragments and steady-state cost climbs with every press: at a
2,000-row cap, press 20 cost **69.5 ms**; at 300 it is 8.2 ms. Over the cap the edit is refused whole,
with a note — never a partial rectangular edit, which is unrecoverable-looking damage.

**300 rows is a real functional limit on a feature whose headline use is "prefix every line", and
1,000-line files are ordinary.** The cause is the per-press fragmentation, not the row count: a single
batched multi-range splice would remove the climb and let the cap go back to thousands. Added to §5 as
debt. The cap is the right call *today* — the failure mode is a refusal, not damage — but it is a
workaround.

### Owed and open

- **Wyatt's live pass, ranked** (this environment cannot inject GUI input, so every gesture claim is
  inference from source):
  1. **Alt+drag, then Ctrl+V / Enter / Tab.** The invisible-linear-selection fix. This was the merge
     blocker.
  2. **Alt+drag on a CSV → Ctrl+T → edit a cell → Ctrl+T → Ctrl+X.** The table-view hole.
  3. **Alt+drag, then Ctrl+M twice into Split.** Does the rectangle vanish, or draw somewhere wrong?
  4. **Held Backspace or a held character over a ~300-row rectangle**, in the *release* build. The
     headless cost test runs debug.
  5. **Alt+drag that never moves** (a click). Old rectangle clears, caret lands where clicked?
  6. **Alt+drag while wrapped, then Alt+Z.** Note appears once, not per frame; gesture works after.
  7. **Alt+Shift+Up/Down vs bare Alt+Up/Down** — the bare one must still move the line, with no
     menu-mode stranding on Alt release.
  8. **Ctrl+C from a CRLF file, pasted into another app.**
- **Padding applies to width-replaces**, so a rectangle dragged past a ragged right edge lengthens
  short rows on the first keystroke. Matches Sublime and VS Code, deliberate, one undo recovers — but
  it is the behaviour most likely to surprise.
- **Bisecting into this branch hits real runtime bugs.** All 16 commits compile, but commits before
  `d69d85e` ship the 48 ms freeze and undrawable rectangles, and before `88414e9` the phantom-undo Cut.
- **For the `renderer`/`ui` extraction:** `block.odin` never imports `App` and returns `[]plat.Quad`
  exactly as `doc_selection_rects` does, so it moves cleanly into `ui`. The drag latches were folded
  into one `Block_Drag` struct rather than left as a fourth group of loose locals in the frame loop.

### The live pass, and what it found (v0.15.1)

Wyatt used column editing at a real keyboard the day it shipped. Four findings, all real, none
visible to any headless test:

- **The test suite was destroying his clipboard.** `blocktest` wrote `"PP"` to the *real* Windows
  clipboard to prove Paste no longer wipes a rectangle; he hit Ctrl+V mid-pass and got the fixture.
  The first fix added save/restore to one case and left three others — **the unit restored while the
  mode still lost data**, which is exactly the seam-versus-unit failure §6j is about, committed by a
  round whose whole purpose was fixing that class of bug. Now the save/restore wraps the entire mode
  via `defer`, and a seam assertion sets a sentinel before any case and checks it after all of them.
  A reviewer proved the miss by setting a sentinel by hand and watching it die.
- **The wrap refusal named the wrong key.** `doc_wraps` is `doc.wrap || md_mode == .Split`, but the
  note always said "press Alt+Z" — which does nothing in Markdown Split, where Ctrl+M is the way out.
  Split now has its own refusal reason and its own note.
- **A refused Alt+drag left a linear selection behind.** The cursor moved before the refusal was
  checked, so a refused column gesture silently became an ordinary selection — Wyatt saw a full-row
  highlight that survived toggling wrap, because it had never been a rectangle. A previous round had
  called this "defensible, kept deliberately"; the live pass disagreed. A refused gesture now leaves
  the selection exactly as it found it.
- **Tab now acts across the rectangle** (Wyatt's decision), routed through `block_replace` so it
  inherits bottom-up ordering, the single undo entry, the row cap and virtual-space padding. Enter
  still clears, deliberately — splitting N lines from one keystroke is rarely what anyone wants.

Also: `blocktest` hit `STATUS_STACK_OVERFLOW` twice. The cause is total per-procedure frame size
(Odin gives each nested proc its own frame, and two `App` structs in one callee doubles a frame
already sitting on `test_mode_dispatch`'s), **not** the number of sibling blocks as first recorded.
`build.bat` now passes `/STACK:8388608` so the next person adding a case does not hit a crash with
an invisible cause.

**The per-keystroke cost was diagnosed twice by reading and both answers were wrong.** §6y blamed
splice fragmentation; a later session blamed the undo snapshot (`pt_snapshot` is `clone(pt.root)`,
taken per keystroke) and got as far as choosing "coalesce consecutive block edits" as the fix. An
implementer then instrumented it before building, per the falsifiers-before-fixes rule, and found the
snapshot is **3.5%** of press 20 — forcing zero snapshots on presses 2..N moved it by 0.9 ms. The
cost is 95% *reads*: `pt_insert` never coalesces adjacent appends, so pieces grow by one per row per
press and both row walks read through an ever-more-fragmented tree. Full table and the fix that
follows are in §5.

**The lesson is the process one.** The second diagnosis was more confident than the first and less
right, and it was written into this document as settled fact before anyone measured. The only reason
it did not ship is that the implementer's brief carried an explicit stop condition — *if the snapshot
is not dominant, report BLOCKED rather than build the wrong fix* — and they used it.

## 6z. View persistence, encoding surface, four debts (2026-07-26, v0.16.0, branch `feat/batch-6`)

Batch 6 of §6u. Ten tasks, 22 commits. §6u listed five items; three more came off the §5 debt
register when Wyatt scoped it. Design in `docs/superpowers/specs/2026-07-26-batch-6-design.md`,
plan beside it.

**Shipped:** a tab's view (`wrap` + `md_mode` + `table`) now survives both a restart and an
external-change reload; a mis-detected file can be reopened under a chosen encoding; the eight
encoding commands are in a new top-level `Encoding` menu instead of palette-only; `Open Logs
Folder` makes the log discoverable after seven months of it being written and unreachable; the
crash reporter stays armed inside `on_resize`/`on_dpi`; a held column edit is one undo step; paste
normalises line endings; and the headless harness no longer ships in the release exe.

### One value, one validator — and the spec was wrong about why

Session restore and `doc_reload` are the same problem twice: both put a view onto a `Document` they
did not create, both carried `wrap` open-coded, both dropped `md_mode`/`table` on the floor. They
now share `Doc_View` + `doc_view_apply` (`src/program/view.odin`) — the same move `block_row_range`
and `doc_row_lex_extent` made, for the same reason.

**The spec claimed that validator would degrade a view when a file stopped fitting it — a rotated
log falling out of Table view. That is false**, and writing the plan is what caught it:
`doc_can_table`/`doc_can_markdown` gate on the *extension*, and neither reload nor restore changes a
path, so a rotated `.csv` keeps its grid. The guard's real job is a view arriving from somewhere
else — another build's session file, a hand-edited one, an out-of-range enum. That distinction is
not pedantic: the test the spec originally called for could never have failed. The shipped test
hand-writes a v4 session line putting a table view on a `.txt`, which can.

Session format 3 → 4 (two appended fields, tolerant ladder, v1-v3 still load). `table_delim` is
deliberately not persisted — `doc_view_apply` re-derives it, which cannot go stale against the file.

### What this batch got wrong

Every task passed its own review; the failures are all in the seams between them.

- **A `viewmemtest` assertion went stale the moment format 4 landed, and nothing noticed for eight
  tasks.** "Session restore wins over the family default" asserted `md_mode == .Off` — and said so
  in its own comment, because `session.txt` carried only `wrap` when it was written, so the value
  was constant whether the restore path was buggy or not. Task 2 made it real and the assertion
  started failing. **Task 2 never ran the mode, and task 2's reviewer verified the property by
  reading the call graph instead of running it.** Task 10's implementer found the failure and
  reported it as pre-existing and unrelated. It now asserts `.Preview` against a `.Split` family
  default — strictly stronger — sabotage-verified by wiring `app_apply_view_defaults` into
  `session_restore` and watching it fail. **A test whose own comment admits its value is constant
  either way is a test to revisit the moment the thing it measures becomes variable.**
- **Two vacuous tests, one of them written by this session's controller.** `doc_batch_end_run`'s
  `continued` branch was dead code with a comment claiming an accumulation that never happened
  (`push_undo` zeroes the run token before the batch guard — that position *is* the break
  condition); a reviewer proved it by instrumenting the branch and watching it never fire once
  across the whole of `blocktest`. And the first `.History_Jump` test asserted that a live rectangle
  was cleared — which passed with the fix sabotaged, because `apply_snapshot` clears one itself. The
  property that actually depends on `command_mutates_doc` is the **table** guard, and the rewritten
  test fails correctly.
- **A comment that explained a hazard that cannot happen.** The plan's `doc_reload` ordering comment
  said the view must be applied after `doc.path` is restored or the gates would see an empty path.
  `doc_open` clones the path into `fresh`, so it is never empty. The implementer noticed when the
  sabotage failed through the wrong channel and left the comment as drafted anyway; the reviewer
  caught it. The ordering does matter — via the `top` clamp, not the path.
- **The `Encoding` menu made a pre-existing data-integrity hole reachable.** `.Eol_LF`/`.Eol_CRLF`
  were missing from `command_mutates_doc`, and `doc_set_line_ending` rewrites the entire buffer
  (`pt_delete(0, length)` + `pt_insert`). Both dispatch guards key on that predicate, so: Alt+drag a
  rectangle on an LF file, Encoding ▸ CRLF, Ctrl+X — every row start had shifted by one byte per
  preceding line and the cut took text never highlighted. Palette-reachable on `main` since the
  commands existed; **putting them in a menu is what turned it into something a user would actually
  do.** The whole-branch review found it, and its re-review then found `.History_Jump` missing for
  the identical reason. Both are now in the predicate. *A batch that only makes an existing
  capability easier to reach still owns the consequences of that reachability.*
- **A sabotage step opened a real Explorer window on the desktop.** Weakening `shell_open_folder`'s
  `is_dir` guard let a real path reach `ShellExecuteW`. The permanent tests now assert on pure
  argument-builder procs (`explorer_folder_arg`/`explorer_select_arg`) and cannot reach the shell —
  which also fixed the unquoted path that would have opened the wrong folder for any user whose
  profile name contains a space.

### Decisions taken with Wyatt during the batch

- **Reopen refuses above 64 MB rather than confirming.** A forced non-UTF-8 encoding on a mapped
  file transcodes synchronously on the UI thread — one menu click on a 500 MB log is a multi-second
  freeze, on the property Newtpad advertises. The failure mode is now a refusal that changes
  nothing, the same shape as `BLOCK_EDIT_MAX_LINES`. Scoped to `enc != .UTF8`, which exactly matches
  `doc_open`'s own transcode branch. **The cap reads `doc.disk_stamp.size` and therefore fails open
  when the stamp is absent or stale** — best-effort, tracked in §5.
- **The grid and the markdown views now exclude each other live.** Both gates let an *untitled*
  buffer into any view, so Ctrl+T then Ctrl+M produced `table && md_mode == .Split` — the state
  `view.odin` refuses to restore. Format 4 fixed the restart case and left the live one.
- **Line-ending conversion stayed out of the menu scope discussion** — the commands already existed;
  only the reopen trio is new.

### Release size

`build.bat release` **1,494,528 → 1,055,744 bytes (-29.4%)**, both numbers remeasured independently
by a reviewer rather than taken from the implementer. `build.bat release tests` is the way back in —
`-o:speed` with the harness and the console subsystem, because §6y's held-key column cost is a
release-build measurement and gating without that row would have made it impossible for good.

### Owed

- **Wyatt's live pass**, ranked: (1) the `Encoding` menu on a real window — four titles in the
  caption, the check mark tracking the active document, Reopen greyed on an untitled buffer;
  (2) Reopen as Windows-1252 on a mis-detected file, and the confirm on a dirty tab defaulting to
  Cancel; (3) a `.md` left in Split and a `.csv` left in Table, closed and reopened — the whole point
  of the batch; (4) a held character over a ~300-row rectangle, then **one** Ctrl+Z; (5) Ctrl+T then
  Ctrl+M on an untitled buffer; (6) View ▸ Open Logs Folder.
- **Nothing in this batch was verified against real GUI input.** Every claim about what happens when
  you click something is inference from source plus a headless assertion.
- Carried findings are in §5.

## 6aa. The road to V1 (2026-07-26)

Wyatt asked for the whole plan from v0.16.0 to a shipped V1 and answered the four forks that decide
its shape. **This supersedes §6u's batch table for batches 7-8** — the contents moved, and two
things left V1 entirely.

### Where V1 actually stands

Of `research/demand-side-feature-research.md` §G's six V1 decisions, **five have shipped**:
column/block editing (§6y), filter-to-matches (§6e, §6h), the scratch buffer as a hot-exit primitive
with a Settings toggle (§6b), per-monitor DPI (§6g), and the session-restore toggle. The sixth —
first-party JSON/CSV/XML reformat — was decided *out* of V1 and held to the V2 plugin proofs.

**The V1 feature list is done.** What separates v0.16.0 from a shippable product is hard-rule debt,
distribution machinery, and one batch of promises made in CLAUDE.md's own product principles. Worth
stating plainly, because it changes what the remaining batches are *for*: they are mostly not
feature work, and a session that opens this file looking for the next feature to build will
misread the state.

### The four forks, as answered

1. **The UI overhaul and the `renderer`/`ui` extraction move to V2, as its first item.** CLAUDE.md
   ranks them priority 2, but `research/newtpad-research-report.md:129` records File Pilot's own
   advice: budget exactly one UI rewrite and do it *after* V1, once real use cases exist. The
   research wins — shipping is what produces the use cases the rewrite is supposed to be informed
   by. It is also the difference between V1 being four batches away and ten.
2. **A free public beta precedes the paid V1.** "V1" is therefore two milestones, and the commerce
   work (trial, offline license key, storefront) sits *after* the beta rather than before it.
3. **Rebindable keys are in V1.** Named in CLAUDE.md principle 4; the hard half — the data-declared
   `[Command_Id]Command` table with its `#assert` — has existed since the tabs batch. Only the user
   overlay is missing.
4. **Accessibility rides with the UI refresh, i.e. V2.** High-contrast is blocked on the colour-token
   layer rather than on effort (§6k), and a UIA provider written against a UI about to be rewritten
   is work done twice. Note what this decides: **the beta and the paid V1 both ship with no
   screen-reader support.** A deliberate, dated choice — not an oversight to rediscover.

### The batches

| Batch | Theme | Contents |
|---|---|---|
| **7** | Silent failures | Glyph-atlas eviction · `\\?\` long paths · tab stops · CSS `//` + SQL `--` comment markers · the §5 findings carried out of batch 6 |
| **8** | Engine debt | Release build time back under the ~5 s rule · precompiled `.cso` shaders · batch the text pipeline · settle the VirtualAlloc-arena decision |
| **9** | Keys and navigation | Rebindable-key overlay · bookmarks · scrollbar match marks · filter click-to-jump · filter's first paint |
| **10** | Text operations | Sort lines / remove duplicates · keyword→colour rules · whatever live use has surfaced by then |
| **11** | Distribution | Real self-contained installer · signing pipeline built signing-*ready* · updater · LICENSE/EULA · a way for a beta tester to send a crash |
| — | **BETA** | Landing page, download, publish the price early and hold it (File Pilot precedent) |
| **12** | Commerce | Trial · offline license key · storefront — informed by beta feedback |
| — | **V1** | |

Batches 9 and 10 are one body of work split on a guess; the split is provisional and belongs to
whoever plans them.

**Batch 7 is the one to spec next.** Its four items are independent of each other, which makes it
the cleanest fan-out on the list, and every one of them is a wrong behaviour a user can hit today:
the atlas silently drops glyphs while the pen advances, a path over ~260 characters simply fails to
open, tabs render as one cell so indented code and `.tsv` are wrong, and a `--` SQL comment colours
its own contents as keywords.

**Batch 8's arena row is a decision, not an implementation.** CLAUDE.md's memory rule describes
arenas on VirtualAlloc that have never existed; the honest options are to build them or to amend the
rule. Recommendation on the evidence available: **amend.** There is no measured allocation problem,
the per-document arena was already refuted once on its own merits (§6b), and a locked decision that
describes code nobody has written is worse than no rule. Do not let a batch default into building it.

### Explicitly out of V1

Ruled out here, so the next audit does not resurface them as gaps: code folding, macros /
record-replay, file compare / diff, print and print preview, spellcheck, and global-hotkey quick
capture — all from research §C, none ever ruled in. Also out, by earlier decision: first-party
reformat, full multi-cursor, and plugins (all V2), and the container/archive tree viewer (§6).

### The gate on the beta that is not a batch

**Wyatt's live passes are now on the critical path, not beside it.** Nothing in this codebase has
ever been verified against real GUI input except by Wyatt — this environment cannot inject any. Two
are owed before strangers see the product: **§6x's theme-tuning pass** (Dark's syntax colours were
chosen by arithmetic and have been looked at once, and they are the first thing every beta tester
will see) and **§6z's list** on batch 6. A public beta is the mechanism that finally converts this
debt into other people's testing, which is an argument for reaching it sooner rather than for
skipping the two passes.

### Also worth doing, independent of any batch

`CLAUDE.md` is gitignored and exists only on Wyatt's disk (see the note at the top of this file,
still true). It defines every locked decision, the hard engineering rules and the git conventions,
and it has no backup, no history, and is invisible to a fresh clone. Tracking it costs nothing.

## 6ab. Tab stops, long paths, and two beliefs that were not true (2026-07-27, v0.17.0, branch `feat/batch-7`)

Batch 7 of §6aa, the first batch down the road to V1, executed overnight with Wyatt asleep. Six
tasks, 35 commits. Design in `docs/superpowers/specs/2026-07-26-batch-7-design.md`, plan beside it.

**Merge policy for this batch was different and deliberate:** merged to `main`, **`install.ps1` NOT
run.** Wyatt's call — unreviewed overnight code should not reach the daily driver before he has
looked at it. The standing "reinstall after every merge" rule resumes once he has done the live pass
below.

**Shipped:** tabs advance to real tab stops at a configurable width; paths over 260 characters open,
save and stat; `.css` and `.sql` get their own line-comment rules; the five findings batch 6 carried
are closed; and 131 lexer assertions can print their numbers when they fail.

### The headline is that two planned items were not real, and measuring cost twenty minutes

§6aa listed five items for this batch. **Two of them did not exist as described**, and both were
found by running a measurement rather than reading a comment.

- **Glyph-atlas eviction — refuted, dropped from the batch.** The 2026-07-25 audit ranked it Tier 2
  with the sharpest failure description on its list: *"the only item whose failure mode is 'your text
  silently vanishes.'"* HANDOFF §5 and the roadmap carried it too. All three traced to one comment in
  `text.odin` — *"Atlas is grow-only for now; eviction is required before ship"* — that **outlived the
  §6j fix by seven months.** Measured: at 4096² the atlas holds **61,425** glyphs at 16px and
  **9,768** at 48px (300% DPI), growth 1024→4096 is observed against a real device, and `atlas_full`
  never latches. One screen of text is nowhere near that many *distinct* glyphs. Nothing was built;
  the comment, §5, the roadmap and the audit were corrected instead.
- **"Tabs render as one cell" — wrong on the number.** `TAB_CELLS :: 4` was already there, and
  `text.odin` carried the stale claim *directly above* the live constant. The real gap was
  fixed-width vs true stops, which is what shipped.

**The generalisable lesson, and it is the most useful thing this batch produced: a claim of presence
is exercised by every build; a claim of absence is never re-tested.** Three sections of this file and
a whole audit document inherited two false beliefs from two comments, and no test could have caught
either, because nothing tests a sentence. When a doc says a thing is missing, the cheap move is to go
and measure before you go and build.

### True tab stops — the column is the whole difficulty

A tab's width depends on where it starts, which is exactly why `TAB_CELLS` was a constant: the
per-rune `text_cell_width` had no column to work with. Making tabs real meant threading a column
through every measurement, across ~21 sites — squarely the Shape-B class (*a correct, tested function
fed the wrong input*).

**The technique that made it safe was making the parameter required, not defaulted, and letting the
compiler enumerate the sites.** A defaulted `col := 0` would have compiled everywhere unchanged and
left the wrong behaviour at precisely the sites the task existed to find. Done twice: task 1 for
`text_cell_width_at`, task 2 for the three wrappers.

**Tab stops are measured from the visual row start.** With wrap off — the normal case, the only case
for `.tsv`, and the only case column editing permits (§6y) — a visual row *is* its logical line, so
this is exactly right. With wrap on, a tab on a *continuation* row aligns to that row rather than to
the logical line: bounded, rare (leading indentation lives on the first visual row), and now the one
behaviour in the tree with a test that can actually see it.

### What this batch got wrong

**The plan was wrong twice, and a reviewer caught it both times. The spec was right both times.**

- The plan's investigation concluded that no `col0` parameter was needed on the three wrapper procs,
  from an audit table of their *direct* callers. It missed that the wrappers hardcode an origin of 0
  internally, and that **two of their callers are reachable from a keystroke**: Tab inside a column
  selection, and Backspace on a rectangle after a tab, where the caret jumped to the row start on
  every row. The spec had proposed exactly the parameter the plan removed. Corrected in flight, in a
  box left in the plan rather than by a silent edit.
- The plan told task 2 to fix `block_delete` by passing the deleted run's starting column to
  `text_cells`. **That instruction is circular** — the column being passed is the value being
  computed. The implementer removed the call and measured forward with `line_cell_col` instead, which
  also fixed a right-edge straddle that was wrong even under fixed-width tabs.
- The plan's own arithmetic for its headline test case was wrong (`text_cells("a\tb")` is 5, not 6),
  and it declared that case unable to fail. It can, and does.
- **The pseudo-tab gate landed menu-only and the command palette walked straight past it.** Task 5
  gated Save/Save As/Paste in the `menus` table; `palette.odin` calls `command_dispatch` directly and
  never consults `item_enabled`. So Settings ▸ Ctrl+P ▸ `>Paste` still pasted into the settings page,
  which is the bug the commit message claimed to have removed. The fix moved to one shared
  `command_allowed_on` predicate that both routes consult — and it turned out to cover **eight**
  commands, not three: `Enc_*` and `Eol_*` had the identical bypass, meaning **the batch-6 encoding
  data-integrity bug was still reachable by mouse.** Two places enforcing one rule is how they
  diverge; this is CLAUDE.md's "one layout per widget" applied to a policy rather than a geometry.

**Three tests could not fail, and each was caught by sabotage rather than by review:**

- Task 1's acceptance criterion — "all ten suites pass unchanged" — was *met and nearly worthless*.
  Sabotaging the tab branch to true tab stops moved **two non-timing lines in the entire corpus**,
  both in `celltest`, because every tab in every fixture is a *leading* tab and a tab at column 0 is
  4 cells under both behaviours. Measured independently by the implementer and the reviewer. That
  finding is why task 2 added a fixture per uncovered consumer instead of trusting green.
- The controller's own seam test in `hscrolltest` passed under sabotage: `line_cell_col` and
  `line_offset_at_cell` are inverses *whatever a tab measures*, so a round-trip cannot see tab stops
  at all. It needed absolute-column assertions, which go red on seven rows.
- A `longpathtest` row sized its fixture from `LONG_PATH_THRESHOLD`, so sabotaging the threshold
  moved the fixture too and the row stayed green. It now writes the Win32 number out as the fact it
  is.

**And the evidence itself was broken.** `ctok_eq`/`tok_eq` in eight `src/base` test files formatted
failures as `"got {%d,%d,%v}"`. Odin's `fmt` reads a literal `{` as a brace-index verb, so it printed
`%!(MISSING CLOSE BRACE)` *and desynchronised the rest of the argument list*, mis-binding the `want`
triple too. **131 assertion sites across 109 tests have had unreadable failure output since each file
was written** — which is precisely the output the sabotage step depends on reading, and three of
those files' headers cite recorded sabotage transcripts that were garbled when recorded.

### Deliberately carried, each triaged by the whole-branch review

- `line_cell_col` silently truncates past 8192 bytes with no `exact` flag, and `block_delete` now
  depends on it. Verified harmless today: `caret_line_start_cell` computes the seed *through the same
  proc*, so the seed cannot outrun the bound, and `block_row_range` refuses rather than guessing. The
  recorded fix is an `exact` flag plus a refusal; widening one of two identical bounds would be the
  actual bug.
- ~21 `os.*` filesystem calls in the program layer are unconverted and inherit `core:os`'s
  registry-dependent long-path behaviour. All under `%APPDATA%\Newtpad`; reachable only via a long
  `NEWTPAD_SESSION_DIR`. Needs a `plat` read/write pair that does not exist yet.
- `zoom_pct` **and** `split_frac` carry the same save/load 0-handling asymmetry that `tab_width` just
  fixed — a hand-edited `settings.txt` with a `0` loads as the minimum but saves as the default.
  Third and fourth instances of the shape; both reachable only by hand-editing.
- CSS `url(https://x/a/*/b)` can now open a real block comment persisting to the next `*/`, because
  the old `//` swallow was accidentally shielding it. Judged worth it (a `/*` inside an unquoted URL
  path is essentially unheard of; quoted URLs are immune) and **pinned by a test asserting the losing
  behaviour**, so closing it later must be deliberate.
- `lex_yaml` has a Shape-A-*shaped* loop that is not a live bug — every `state_out` write happens
  above the capped loop and returns immediately. One edit from becoming real.
- 17 source comments across 8 files cite `.superpowers/sdd/task-N-report.md` paths, which are
  **gitignored and collide every batch**. Pre-existing; those citations were already dangling.

### Owed

- **Wyatt's live pass**, ranked: (1) a file with indented code and a ragged `.tsv`, and a mid-line
  click on a tabbed row — tab stops are the most visual change in the batch and *nothing here was
  verified against real GUI input*; (2) Settings ▸ Tab width 4 → 8 with a CSV grid and a markdown
  preview open; (3) Settings ▸ Ctrl+P ▸ `>Paste` ▸ Enter, then close the tab — it should close
  silently; (4) opening, saving and Save-As on a path over 260 characters, including from Explorer
  and by drag-drop; (5) Encoding ▸ Reopen on a mis-detected file.
- **Then `install.ps1`**, which this batch deliberately did not run.
- The two live passes still owed from before: §6x's theme tuning (Dark's syntax colours have been
  seen once) and §6z's batch-6 list.

### Unplanned finding: the release build time is no longer over the rule

§5 records `build.bat release` at **10.2 s** against the ~5 s rule, measured at v0.13.0, and §6aa
made fixing it batch 8's first item. Re-measured at the end of this batch, warm, three consecutive
runs: **5.12 / 5.07 / 5.07 s.** Release exe 1,060,352 bytes.

Nothing in batch 7 targeted build time, so the suspect was §6z's `NEWTPAD_TESTS` gating removing
`test_modes.odin` — now ~11k lines — from the release compile, with the 10.2 s figure predating it.
**A/B'd rather than assumed:** `build.bat release tests` is **6.94 / 6.91 s** against release's
**5.1 s**, so the harness is ~1.85 s of it and the gating is indeed what closed the gap. §5's entry
is updated with both series. **Batch 8 should not spend a task on this** — the rule is met to within
noise. Third time in this file that a debt entry outlived its cause; the entry now carries its
measurement so the next reader can tell.

### Operational traps found, for `docs/development-loop.md` §6

- **After `build.bat release`, `NEWTPAD_TESTS` gates out `test_modes.odin`, so *every* mode name
  falls through to opening the real GUI and hanging** — not just `drawcount`. More generally, **any
  unrecognized first argument does this**, which is how a typo'd mode name costs a timeout.
- **`build.bat` invoked through the Bash tool hangs**; run it through PowerShell.
- PowerShell 5.1's `Set-Content -Encoding UTF8` writes a **BOM into `.odin` source**. It did, to
  `menu.odin`, mid-batch. §6 already warns about the read direction; this is the write direction.
- The §5.3 bisectability loop **fails on every commit, including known-good ones**, unless
  `build\guarded.obj` and `build\newtpad.res` are copied into the extracted tree and the invocation
  carries `-resource:` and `/STACK:8388608`. Prove the harness on a known-good control first.

## 6ac. The horizontal scrollbar scrolled the wrong number (2026-07-27, v0.17.1)

Wyatt, from live use, within minutes of batch 7 merging: *"the horizontal scrollbar doesn't work when
in Ctrl+M and Ctrl+T views."* Both were real. Branch `fix/hscroll-grid-preview`.

**v0.17.0 was merged but never cut** — batch 7 landed under the overnight merge-don't-install policy
and no tag was made, so this release is the first one carrying it.

### What it was

The bar asked one question — how far can this pan? — of `doc_max_hscroll`, which only ever measures
the **widest source-text line**, and wrote its answer to `doc.h_scroll`. Neither is right outside the
plain text view:

- **The grid pans `doc.table_col`, by whole columns**, and has since before the bar existed —
  Shift+wheel drives it. `table.odin` contains **zero** references to `H_SCROLL`.
- **Markdown Preview has no horizontal axis at all**; it lays out to the pane width. Also zero
  references.

So in both views the bar appeared (source lines *are* long), dragged, and moved nothing. Markdown
**Split** was never affected — `doc_wraps` already returns true there, which the new tests confirm
rather than assume.

### The fix, and why it is shaped this way

`hscroll_model` (`main.odin`) is now the single authority for **which number the bar pans** —
`Cells` for text, `Columns` for the grid, `None` where the content lays out to fit — and the
geometry, the drag and the draw all ask it. `hscroll_set` is the only writer the drag uses, so it
cannot set a field the draw does not read. This is CLAUDE.md's "one layout per widget" applied to a
policy rather than a geometry, the same move `command_allowed_on` made in §6ab.

`table_cols_fitting` (`table.odin`) sizes the thumb using the same advance the draw uses, rather than
a second nearly-identical loop.

**One deliberate deviation from the option Wyatt picked.** He chose cell-level panning for the grid
over "scroll by whole columns"; the grid *already* pans by column via Shift+wheel, so cell-level
would have given one view two scroll models. Wired to the existing column pan instead, and told him.

### Worth keeping

- **The bug was reproduced before it was fixed.** Reverting the model prints the report back:
  `drag wrote h_scroll=152, which the grid never reads`. Nine assertions red sabotaged, zero clean.
- **Two self-inflicted errors caught by the discipline, not by luck.** The first grid fixture used the
  temp allocator for content `doc_from_content` takes ownership of (`owned_orig = true`), so
  `doc_close` freed temp memory — instant `0xC0000374` heap corruption, no output at all. And the
  first sabotage patched the *wrong occurrence* of an identical line elsewhere in `main.odin`, so the
  grid cases stayed green and looked vacuous when they were merely un-sabotaged. Both are arguments
  for reading which line the patch actually landed on.
- The new block reports through **its own counter**, not the shared `bad` — the pre-existing summary
  line beside it is `if bad == 0`, so an unrelated failure silently suppresses it. Same shared-counter
  smell §6ab fixed once already.

### The follow-up (v0.17.2): the bar moved on click and froze on drag

Wyatt, on the v0.17.1 build: *"it only moves when you click, not when you hold and drag."* A second,
independent bug that the first fix **made reachable** — the bar had to work before anyone could
notice it did not drag.

The read-only swallow (`main.odin`) consumes a press on the grid, a full Preview, or a Split's
preview half, because those take no caret. Consuming means zeroing `window.mouse_down` — **and that
is persistent platform state**, set on `WM_LBUTTONDOWN` and cleared on `WM_LBUTTONUP`. Zero it
mid-gesture and the drag dies twice over: the latch sees `!mouse_down` and clears itself, and
`WM_MOUSEMOVE` only updates `mouse_x` *while* `mouse_down` is set, so the pointer stops moving too.

The guard already excluded `scrollbar_drag`, `md_preview_drag` and `divider_drag`. **`hscrollbar_drag`
was simply missing from the list** — invisible for as long as the horizontal bar was dead in those
views, and invisible in the plain text view because `ro` is false there so nothing is swallowed.

Fixed by making the latch list a `Drag_Latches` struct behind one pure predicate,
`ro_surface_swallows`, so the list is a thing that can be tested rather than four `&&` clauses nobody
re-reads. The test asserts each latch vetoes the swallow **and** that an ordinary press still *is*
swallowed — without that second half a predicate returning `false` unconditionally would pass.
Sabotage (dropping `hscroll`) reddens exactly three cases.

**Checked for a second instance, per §4 of the loop:** the bottom-strip block ten lines below does the
same zeroing, but guards on `mouse_pressed` (a fresh press) rather than `mouse_down`, so a held drag
passes through it safely. One instance, not a class.

### Owed

Nothing was verified against real GUI input. Wyatt's pass: a wide CSV in Ctrl+T — **hold and drag**
the bar, not just click it — and confirm Shift+wheel still agrees with it; a long-lined `.md` in
Ctrl+M (no bar at all); and a plain long-lined text file (unchanged).

## 6ad. Keys and navigation (2026-07-27, v0.18.0, branch `feat/batch-9`)

Batch 9 of §6aa — the first of the two feature batches between here and the beta. Five items, 28
commits. Design in `docs/superpowers/specs/2026-07-27-batch-9-design.md`, plan beside it.

**Shipped:** a `keys.txt` user keymap overlay · bookmarks with `Ctrl+F2` / `F2` / `Shift+F2`,
persisted · find-match ticks on the scrollbar · click a filtered line to jump to it · and filter view
finally paints on the first frame.

### Decisions taken with Wyatt, 2026-07-27 — do not relitigate

- **Rebindable keys are a file, not a capture UI.** The UI is a whole widget (conflict detection,
  reserved chords, reset-to-default) and is its own batch; the file matches the shape `settings.txt`
  and the theme files already use. Revisit only if the file is painful in real use.
- **Bookmarks: simple toggle plus next/prev, persisted. No numbered bookmarks** — they would consume
  nine chords, and `Ctrl+1..9` is what most editors use for tab switching.
- Taken at the same time, for batch 11: **proprietary free-beta EULA**, and a **manual-check-only
  updater** (no background traffic — research §D lists no-telemetry as a hard expectation).

### What the batch had to work around

**Shift is not part of a chord.** `Binding` is `(key, ctrl, alt, ctx)`, and `commands.odin:252` and
`:294` both say so — §6y was caught by this once already. So bookmarks ship **one** cycle command
reading `ev.shift` for direction, and `keys.txt` **refuses** a `shift+` chord rather than silently
binding the `ctrl+` half. Silently binding something the user did not ask for is the worse failure.

**There were no F-keys in the tree.** `plat.Key` had none and `vk_to_key` no cases, so `VK_F2`
resolved to `.None` and every function key was swallowed. Adding F1–F12 **silently broke Alt+F4** —
the pump let Alt+F4 and F10 reach `DefWindowProc` only because `vk_to_key` returned `.None` for them,
an accident of the key set rather than a decision. Caught by the implementer, fixed via
`key_belongs_to_windows`, and rebased into the F-key commit so no commit in history carries the
regression.

### The lesson that generalises: what the compiler does and does not enforce

The implementer's first write-up said *"growing an enum puts zero pressure on code that switches on
values."* The reviewer tested Odin directly and that is **too strong** — a plain `switch` over an
enum *is* exhaustive, and compiler pressure did work here (the total `[plat.Key]string` array failed
to build until twelve rows were added). The accurate version, which is worth keeping:

> Odin's exhaustive `switch` and total array literals give **structural** pressure — every value has
> an entry. They give **no** pressure on **semantic** questions — which values must be treated
> specially. And none at all at the three sites that opt out: `#partial switch`, a `case:` default,
> and a **value comparison**, which is not a switch at all. `wnd_proc`'s `if key == .None` was the
> third kind, and `vk_to_key`'s switch is over `win.WPARAM`, not over `Key`. Growing an enum is a
> behavioural change at every `==`/`!=` site against it, and those are invisible by construction.

### The bound, and the plan's number being wrong

Filter's first paint adds a **synchronous** scan on the UI thread, which is a hard-rule violation if
the bound is wrong. The plan pointed at `SEARCH_SYNC_MAX` (256 KB) as the precedent. Measured, it
spends **13.90 ms of a 16.7 ms frame** on `[A-Za-z]+@[a-z]+` — a pattern someone might plausibly
type — and **fails outright in debug at 20.35 ms**. Shipped **`SEARCH_FIRST_PAINT = 64 KB`** instead.

Then the review found a **worse pattern**: `(the|fox|dog)+x` at 10.79 ms, and the budget was on bytes
*offered*, not consumed — `pt_line_end_cap` returns `p+cap` when it finds no newline, so a file with
no newline in its first 128 KB (minified JSON, a single-line dump) scanned **2×** the budget. Fixed
by reserving the run-on *inside* the budget, so regex first paint covers ~48 KB and literal still 64.
Re-measured worst case **10.98 ms release / 15.5 ms debug**. The falsifier is in the shipped test and
**gated** — it fails the suite over a frame — which is the "a test that has never failed proves
nothing" rule applied to a *number* rather than a branch.

**Also corrected: §6e's claim that "filter view shows an empty screen" was never literally true.**
`visible_next` falls back to the unfiltered document while `filter_lines` is empty, and has since
2026-07-19. The real defects were no rows on the first frame when the head of the file *did* match,
and a banner that said "searching" **forever** on a query with no matches. Both fixed.

### What this batch got wrong

**Six tests could not fail, and every one was found by sabotage rather than by reading.** One in
task 1, three in task 2, one in task 3 that the implementer found in their own test, and a sixth that
only the whole-branch review caught (`mark_bucket_h`, the entire shape-A guard against a track taller
than `MAX_QUADS` — every fixture used a 100–700 px track, so the guard could be deleted with the
suite green). The pattern across all six is the same: **the assertion measured the fixture, or the
buffer, or a value that was constant either way.**

**Two correct functions composed wrongly, and a structural invariant is exactly the check that could
not see it.** `bookmarks_shift_delete` collapsed a bookmark at `at+n` down to `at`; `bookmarks_shift_insert`
then declined to push it back out because its rule was `b > at`. Each half right alone. Result:
**bookmark a line, put the caret two lines above it, press Alt+Down, and the bookmark silently jumps
two lines up** — reachable also via replace-all on a newline-terminated pattern and paste over a line
selection. The invariant ("every entry is a real line start") held throughout, which is why 57
assertions saw nothing. Fixed by collapsing the two procs into **one** rule over one seam
(`pt_edit_replace`), so no pair of calls can express the old composition.

**Two draw-order defects that no per-task review could see**, both the batch-3 shape at a different
seam: every task reasoned about *one* neighbour in `render_frame` and none asked what runs *after* its
block or what else replaces the text pass. The bottom bar painted over the last 2.5% of the match
track — exactly the off-screen matches the ticks exist to show — and bookmark marks were drawn in
full Markdown Preview at source-line positions, pointing at nothing. Fixing the first meant collapsing
**five** copies of `h - CHROME_TOP` into one `scrollbar_track`.

**A test that asserted something the app did not honour.** `find_filter_click` set
`cursor == anchor` and the test agreed — but `find_merge` ran later in the same frame and converted
it into a selection, so clicking a filtered row and typing one character **overwrote the matched
word.** CLAUDE.md §6j's shape with the test on the wrong side of it.

### Deliberately carried

Regex first paint covers ~48 KB rather than 64 (the run-on is reserved inside the budget; both
alternatives were priced and worse). The debug timing gate uses a measured 1.4× multiplier, so the
release gate is the only real one and it sits at 67% used. `.Find_Open`/`.Filter_Open` still set
`doc.filter` directly, so "one path in and out" is not literally true. `doc_close` frees six other
`[dynamic]` fields without nilling them. `keys.txt` accepts plumbing commands the palette hides. No
marks on the Split preview bar and no bookmark marks on the scrollbar — the second mark kind is a
precedence-and-colour question, not free. §6d's block-boundary limitation gained one more instance.

### Owed

**Nothing in this batch was verified against real GUI input** — all five items are things you click or
press. Wyatt's pass, ranked: (1) **Alt+F4 still closes the window** — the regression that nearly
shipped; (2) `Ctrl+F2` / `F2` / `Shift+F2`, and a bookmark mark surviving a horizontal scroll;
(3) a refused `keys.txt` line showing `[KEYS.TXT: n LINES REFUSED ...]`, and `alt+f4 = Save_File`
being refused; (4) whether a 2 px amber tick reads on both the Dark and Light tracks, and whether a
dense set is informative or noise — if noise the fix is a taller bucket, not a dimmer colour;
(5) whether ~48 KB regex / 64 KB literal first paint is enough on his real logs; (6) click a filtered
row, then type.

## 6ae. Text operations (2026-07-27, v0.19.0, branch `feat/batch-10`)

Batch 10 of §6aa — **the last feature batch before the beta.** Three commands and a colour-rule file,
all from research §C's secondary list, all aimed at the log-and-data audience Newtpad courts.

**Shipped:** `Sort Lines` / `Sort Lines (descending)` / `Remove Duplicate Lines`, and
`%APPDATA%\Newtpad\rules.txt` keyword→colour rules.

### Decisions taken with Wyatt, 2026-07-27

Sort acts on the selected lines expanded to whole lines, or the whole document; ascending with a
descending variant; **no case-sensitivity or numeric-order options** (principle 3). Dedupe removes
**all** duplicates keeping the first, not `uniq`-style adjacent-only, which silently leaves
duplicates on unsorted input and reads as broken. Colour rules live in a file, global, naming
`Color_Role`s so a rule cannot invent a colour and reads correctly in both themes.

**Precedence was decided in the plan rather than at the keyboard: links > lexer > rules.** Rules are
lowest so they can never punch holes in real syntax colouring — a rule matching `error` inside a JSON
string would recolour part of a token and make correct code look broken, which is worse than a rule
not showing.

### The consequence of that precedence, and the honest fix

**On a `.log`, six of the nine rules the seeded file shipped as its own starter block did nothing.**
`lex_log` already colours `ERROR WARNING WARN INFO DEBUG TRACE`, so a rule for any of them is dropped
— measured one at a time against `drawcount`'s frame digest, six of nine byte-identical. The user's
first act after *Edit Colour Rules...* is to uncomment that block, and the file itself supplied the
expectation that then reads as broken.

The whole-branch review blocked the merge on it. **The precedence did not change** — it is right —
but the seeded header now names the six words `lex_log` owns, says plainly that a rule for them
changes nothing on a `.log`, and splits the starter block into "these show on a .log" and "these do
not, but do on a .txt". *A feature whose own documentation creates a false expectation is broken in
the only way the user can see.*

### What this batch got right, and it is worth copying

Sort and dedupe are **the strongest-verified feature of the last three batches**, and the reason is
one decision: **every assertion compares the whole buffer byte-for-byte**, never a line count or a
length. The reviewer drove 45 hand-built fixtures through it — empty document, `"\n"`, `"\n\n\n"`,
lone CR, CRLF without a trailing terminator, mid-line-to-mid-line selections, reverse selections,
mixed endings both orders — and found no path that corrupts a byte.

Two structural choices did the work. **`hi` lands at the last line's *content* end**, so the
trailing-newline question survives by construction rather than by a special case — those bytes are
never read and never written, and a CRLF region cannot end on half a terminator. And **the region is
read once and written once**, which is what actually delivers the single undo entry.

### What it got wrong

- **A live column rectangle turned "sort the selection" into "sort the whole file."** Every
  `command_mutates_doc` command not on an exception list gets `block_collapse_linear`, which is
  `anchor = cursor` — so sort then saw no selection and took the whole-document branch. Column-select
  five rows of a 200k-line log, sort, and the entire file reorders. Recoverable with one Ctrl+Z, and
  untested until the review found it. Now refuses with a note.
- **The plan named the wrong mechanism for the one-undo-entry property.** It credited
  `doc_batch_begin`/`end`; verified by deletion, that pair is **inert** here — remove it and five
  suites still pass, because `push_undo(.Replace)` never coalesces and both paths end identically.
  What delivers the property is the single write. Kept as the guard for when a second write appears,
  now commented as inert, and the plan is amended in place.
- **Two "cannot be falsified" claims were false.** A shipped comment said a stray `\r` cannot change
  sort order "because CR sorts before every printable byte" — TAB is 0x09, below CR's 0x0D, and
  `key` / `key\tvalue` in a CRLF file reorders. And `sort_split_lines`' count identity was justified
  by "`buf` never ends with a terminator", which is untrue when the region's last line is empty. Both
  conclusions survived; both reasons were wrong, and the reasons are what the next reader trusts.
- **`drawcount` never loaded `rules.txt`**, so the first before/after measurement was bit-identical
  and meaningless — a false green on the one instrument built to prevent exactly that.
- **The cost bound was aimed at the wrong lever.** The plan said cap the rule count; measured, cost
  at 64 rules spans **20,000×** depending on the *rules*, not their number. The bound that works is a
  second-byte index plus a per-row probe budget.

### Deliberately carried

The sort folds **ASCII case only**; non-ASCII compares by UTF-8 byte order, so `Ä`/`ä` do not fold —
defensible under principle 3, and bytewise UTF-8 *is* codepoint order so ordering stays sensible
within a script. A live column rectangle **refuses** rather than sorting the rectangle's row span
(sorting cells has two honest readings and principle 3 says offer neither). A rule pattern cannot
start with `#`; matching is case-sensitive; a match straddling a wrap boundary is not coloured; rules
do not reach Markdown preview or the grid. The per-row probe budget is a silent truncation, not a
refusal — the same shape as `HL_MAX_ROW_TOKENS`, with 10× headroom on the worst realistic row.

**Shape A, swept and confirmed, all pre-existing on `main` and none introduced here:**
`doc_move_lines`' `read_range` (`doc.odin`) ignores `pt_read`'s return and the fault flag across four
reads and then **writes** — a truncated mmap splices NULs into the document, and Alt+Up is a held key.
`block_text` is read-then-clipboard-then-delete on Cut. Sort's own instance was fixed here (it peeks
`pt_faulted` and refuses; **taking** the flag would have traded a corruption bug for a
recovery-never-runs bug). `doc.odin` first when this is picked up.

**Also carried from batch 9, still unmeasured:** `find_mark_rects` is O(matches) to 100,000 per
frame, the only non-viewport-proportional per-frame cost on the cumulative ledger. `drawcount` has no
timing yet — that is the natural next thing for it.

### Owed

Nothing was verified against real GUI input. Wyatt's pass: sort and dedupe on a real selection and on
a whole file (and confirm one Ctrl+Z restores it); the refusal when a column rectangle is live; and
*Edit Colour Rules...* — write `FATAL = Danger` on a `.log` and confirm it shows, then `ERROR` and
confirm it does not, which is the behaviour the header now explains rather than the bug it looks like.

## 6af. Ship-readiness (2026-07-27, v0.20.0, branch `feat/batch-11`)

Batch 11 of §6aa — the last batch before a public beta, and the first that is not about the editor.
It is about handing the editor to a stranger.

**Shipped:** the first HTTP in the tree (`platform/http.odin`, hand-declared WinHTTP) · `Help ▸ Check
for Updates` on a worker · a crash dialog that can open the crashes folder or a prefilled GitHub
issue · `LICENSE.txt` + `THIRD-PARTY-NOTICES.txt` · `installer/newtpad.iss` with `build-installer.ps1`
· a stubbed, documented signing step.

### Decisions taken with Wyatt, 2026-07-27

Installer: **Inno Setup**. Updater: **manual check only**, GitHub Releases API, no background traffic
— research §D lists phoning home as something this audience actively rejects. Crash reports: **open
the folder, offer a prefilled issue**, nothing sent automatically. **No beta expiry** — honour-system
per `research/newtpad-research-report.md:117`, which also removes the worst failure mode: a time bomb
that bricks every tester's editor if V1 slips.

**The license went round twice, and the second answer is the one to keep.** A hand-drafted EULA was
written, and Wyatt's call was that a bespoke AI-written license is the wrong artifact when standard
lawyer-drafted ones exist. It was dropped unpushed. Reading the actual PolyForm texts rather than
trusting memory then showed that **no single standard license covers all four constraints** — usable
at work, usable by hobbyists, plugins permitted, no redistribution:

| | commercial | hobby | new works | no redistribution |
|---|---|---|---|---|
| Strict | ✗ | ✓ | **✗** | ✓ |
| Internal Use | ✓ | **✗** | ✓ | ✓ |
| Shield / Perimeter | ✓ | ✓ | ✓ | **✗** |

**PolyForm Internal Use 1.0.0**, verbatim, on two grounds: it explicitly grants a *Changes and New
Works License*, so a community plugin is unambiguously permitted (Strict forbids new works outright
and is plugin-hostile), and it forbids distribution, which is what protects a product intended to be
sold. **Its hole is live and named below.**

### The finding that matters most, and it is about not losing work

Inno Setup's **default** `CloseApplications=yes` hands a running application to the Windows Restart
Manager, which asks via `WM_QUERYENDSESSION`/`WM_ENDSESSION` and **force-terminates anything that
does not comply**. `window.odin:539` handles `WM_CLOSE` and `WM_DESTROY` and nothing else — there is
no `WM_ENDSESSION` handler anywhere in the tree. So the default would have killed Newtpad, skipped
the hot-exit write at `main.odin:902`, and **lost every unsaved tab, silently, while the install
looked like it succeeded.**

`CloseApplications=no`, with `PrepareToInstall` posting a real `WM_CLOSE` to the
`NewtpadWindowClass` window and then waiting on the single-instance mutex for the *process* to exit
— not the window, because the process outlives the window during the session write. 60 s, then
abort with nothing written. **No `TerminateProcess` anywhere.** `AppMutex` is deliberately unset; it
would block before `PrepareToInstall` could run.

This is the requirement the whole task existed for: `install.ps1`'s answer has always been "close
Newtpad first, and never `-Force`."

### What this batch got wrong

- **The exit bound was misdocumented.** `UPDATE_TIMEOUT_MS` is **per WinHTTP phase**, not for the
  whole call — resolve, connect and send stack inside one `WinHttpSendRequest`, and
  `WINHTTP_OPTION_CONNECT_RETRIES` defaults to 5. The true worst case on a black-holed route is tens
  of seconds, not four. And there is **no `window_destroy` in this tree**, so the window sits on
  screen with a dead pump for the whole join and Windows ghosts it as "Not Responding". No data is at
  risk (`session_save` runs first). Comment corrected; the real fix is in §5.
- **A comment was backwards on the one call that works.** `WINHTTP_OPTION_DISABLE_FEATURE` is
  request-level only, so the session-level call silently fails — but the pair was commented as though
  the session set it and the request merely restated it, inviting someone to delete the working half.
- **`updatetest` reached the network on every run**, against a plan that asked for opt-in. Its
  sibling `httptest` complied and it did not. Now gated behind `updatetest live`.
- **A report claimed a `dropdown_w` regression that does not exist.** The new 35-char menu title was
  said to widen every dropdown; measured, the widest existing row is `Toggle_Preview` at 31 + `Ctrl+M`
  = 37. Worth recording because it is the one finding this session where the *implementer* was
  pessimistic rather than optimistic.

### Deliberately carried

- **The license grants a hobbyist tester nothing.** PolyForm Internal Use's only permitted purpose is
  *internal business operations*, and it is the installer's first page. Accepted knowingly as the
  cheapest of the four holes — but the beta audience is substantially hobbyists, so **this needs
  Wyatt's decision before the beta is announced, not after.** The standard fix is dual-licensing with
  PolyForm Noncommercial 1.0.0: two verbatim files, no bespoke text, hole closed.
- **The update worker is joined at exit, and should not be.** The join exists only because
  `Update_Check` lives in a local of `main` and `diag_shutdown` runs after `app_destroy`, so a
  detached worker would write into a dead frame and log into a closed sink. Move it to package-level
  storage and `update_stop` becomes `atomic_store(&cancel, true)` with no wait. ~15 lines.
- The updater goes permanently silent on any tag not exactly `vN.N.N` — correct code, an undocumented
  constraint on how releases must be named.
- `.iss` writes `REG_EXPAND_SZ` where `install.ps1` writes `REG_SZ` (same string, verified no
  duplicate PATH entry). No `.ico` yet. `install.ps1 -Force` still hard-kills, and that is the loop
  run after every merge.
- **Shape A, still open from §6ae:** `doc_move_lines`' `read_range` ignores `pt_read`'s return and the
  fault flag across four reads and then writes.

### Verified, and honestly not verified

Verified: 11/11 commits build (harness proven falsifiable first); 201 base tests; the ISCC-absent
skip exits 0; the `.iss` registration list matches `text_exts.txt` **exactly, 34 extensions** — the
plan said "~24" and `install.ps1` won; no certificate material anywhere; `build.bat` still one Odin
invocation.

**Not verified, and this is the batch where it matters most: the installer has never been compiled.**
Inno Setup is deliberately absent from this machine. `newtpad.iss` has never been run, and neither
has install, `/SILENT`, upgrade, upgrade-over-running, uninstall, the PATH code, the license page, or
the graceful-close path — **which is the single most important thing in the batch and the one whose
failure loses work.** Wyatt installing it on a real machine is the test.

### Owed — and this is now the beta checklist

**Wyatt's, and blocking a beta:** decide the hobbyist license hole; buy a code-signing certificate
(the pipeline is stubbed and ready; note `research/newtpad-research-report.md:116` — signing barely
helps SmartScreen for an unknown publisher, so budget reputation time, not just money); a storefront
and a landing page; and the two live passes — §6x's theme tuning, and a real pass over batches 7-11,
none of which has been verified against real GUI input.

**Buildable, not blocked:** `winget install JRSoftware.InnoSetup`, then compile the `.iss` and run it.

## 6ag. The two markdown views were never input surfaces (2026-07-28, v0.20.1, branch `fix/split-wrap-and-preview-readonly`)

The first two findings from the live pass §6af asked for. Wyatt: *"when i was in the rendered view even
though i cant see the cursor/flashing line i could still edit the file"* and *"on split view when i click
my cursor to somewhere on the raw / editable side, it moves my screen and then itll make me highlight the
entire page instantly."* Both were real, both were one bug written twice.

### The shape

Both views were built as **draw** paths and reviewed as draw paths. `markdown_draw` and `table_draw`
replace the text pass, `md_divider_rect` and `doc_editor_right` were tested against each other
(`splittest`), and `ro_surface_swallows` covers the mouse. Nothing asked what happens when you **type**
into them, or where a **click** lands. So the rule each needed was spelled out at its call site — 
`doc.table` at one guard, `doc.wrap` at another — instead of asked of the one procedure that owns it,
and the second view was simply forgotten at every site.

### Split: one widget, two row grids

`visible_next` decides wrapping twice. For the first visible row it asks `eff_wrap_at`, which asks
`doc_wraps` — word wrap **or** Markdown Split. For every logical line after that it asked
`line_wrap_decision`, which opened `if doc.wrap`: the raw field, blind to Split. So with Split on and
Alt+Z off, the draw and the hit-test laid out everything below the first row **unwrapped**, while
`doc_scroll`, `eff_row_start` and `doc_ensure_cursor_visible` — all of which go through `eff_wrap_at` —
kept wrapping.

The user-visible chain: a click low in the editor pane resolves through `doc_pos_at` (unwrapped grid) to
an offset the scroll machinery (wrapped grid) believes is below the viewport, so `doc_ensure_cursor_visible`
scrolls to "reveal" a line that was already on screen — *it moves my screen* — and with the button still
down, the next frame re-runs `doc_pos_at` against the moved view, giving a cursor far from the anchor —
*highlight the entire page*. `line_wrap_decision` now asks `doc_wraps`.

**§6ac asserted the opposite of this in writing**: *"Markdown Split was never affected — `doc_wraps`
already returns true there, which the new tests confirm rather than assume."* Both halves were true and
the conclusion was still wrong, because `doc_wraps` returning true says nothing about whether the layout
path **asks** it. That is worth more than the fix: a predicate being correct is not evidence that its
callers use it, and "the tests confirm rather than assume" was about a different test's subject.

The same bug explains the comment at `main.odin`'s Split draw — *"the editor pass above draws full-window
width, so its lines bleed into the right half"*. They bled because they were not being wrapped. The
repaint that hides it is still there and is now genuinely just a scissor stand-in.

### Preview: documented read-only, enforced nowhere

`markdown.odin` has called `.Preview` a *"full-window rendered view (read-only)"* since it was written.
The mouse honoured it (`ro_surface_swallows`); the keyboard never did. Typing ran `editor_input_rune`,
and Backspace, Delete, Enter, Tab, Paste, Cut, Undo, the sort commands and the whole-buffer line-ending
rewrite all reached the buffer through `command_dispatch` — every one of them editing at a caret that is
not drawn. `doc_read_only_view` (`doc.odin`) is now the single answer, consumed by the typed-character
loop and the mutating-command guard. Split is deliberately **not** in it: its left half is the editor.

**One extra hole found on the way, and it was already open in the grid.** Replace cannot go on
`command_mutates_doc` — in the search field that same `.Find_Confirm` is `find_next`, which a read-only
view must still allow — so the top-of-proc guard never saw it. It therefore has its own refusal in the
one arm that writes. Until this commit, the table guard's own comment claiming `table_edit_commit` is its
only buffer write was **false**, and had been for as long as it had been written. Ctrl+H, Enter in the
grid spliced the document.

### Verification

`mdviewtest`. The seam check compares the drawn row grid against the scrolled one row for row, then
asserts the consequence — a click on any visible row must leave `doc.top` put. Sabotage, one fix at a
time, rebuilt between each:

- `doc.wrap` restored → `drawn row grid == scrolled row grid` FAILs at row 3 (`drawn=1628 scrolled=1545`),
  and `a click ... leaves the view put` FAILs at row 27 (`top 1448 -> 1462`).
- guard restored to `doc.table` → `first through: Backspace`, length 41 → 40.
- Replace guard alone removed → length 41 → 39.

**Two things this got right that are worth copying.** The seam runs at *both* wrap settings: with wrap on
the two grids agreed even with the bug present, so a test covering only that case could never have caught
it — the passing configuration is part of the test, as the control. And the first Replace check used a
same-length replacement, so it rested entirely on the `modified` flag and would have missed a write that
forgot to set it; the replacement is now shorter than the query, and the sabotage output is what exposed
that, not review.

**What it got wrong:** the `doc.table`-sabotage run also reddened the Replace check, because the leaked
Backspace had already set `modified`. A contaminated signal is not a signal — it needed its own isolated
run to prove anything, and got one.

### Owed

- The **typed-character** half rests on `doc_read_only_view` being asserted directly; the loop it guards
  lives inside the frame loop and is not callable headless. Same arrangement as `ro_surface_swallows`,
  and it carries the same risk: `main.odin` can drift from the predicate without a test noticing.
- Wyatt's live pass over batches 7–11 is still owed; these were its first two findings.

## 6ah. UI foundation (2026-07-28, v0.21.0, branch `feat/batch-12-ui-foundation`)

The first batch of the UI overhaul (CLAUDE.md priority 2). Source material: a 21-section UI
specification produced with Claude Design, plus an HTML visual reference with the same content
rendered. Spec: `docs/superpowers/specs/2026-07-28-batch-12-ui-foundation-design.md`. Plan:
`docs/superpowers/plans/2026-07-28-batch-12-ui-foundation.md`.

**Shipped:** six new colour roles and both built-ins repainted warm · `hairline()` and `ui_px_even()`
· the §2 chrome metrics · a rounded-box SDF in the quad pipeline with a real-device readback test ·
the interface font separated from the document font.

### Read the specification the way it asks to be read

It says so itself, and it earns the caveat:

> This is a target state, not an audit of the codebase. It was written from screenshots,
> `Light Custom.theme`, and the colour-rules file — nothing else. **If the code and this document
> conflict on a fact, the code wins.**

Auditing it first is most of the value this batch produced, because **three of its sections describe
work that is already done**: §3 (DPI) is ~80% built — `newtpad.manifest` declares `PerMonitorV2` and
`window.odin:623` already does suggested-rect → resize → rebuild with *"Order matters"* written above
it; §4.1 (caption ownership) is complete; §14 (10 GB) is two-thirds built. Its 13 build steps are
about 8 batches, not 13, and the batch map is in the design spec's last section.

### Four values in the specification are wrong, and the tests are what said so

- **`scrollbar_thumb` is annotated "3.0 against bg_base" in both theme files and measures 1.42 (Dark)
  and 1.67 (Light).** Two themes, one mistake, so it is systematic rather than a typo — and §18 cites
  that 3.0 as a WCAG 1.4.11 compliance point, so shipping the literal values would have made an
  accessibility claim the palette does not meet. Replaced with values that measure 3.14 and 3.10, and
  `themetest` now asserts the pair so a later retune cannot quietly drop back under.
- **`syn_comment` is set to `text_muted`'s exact value in both files.** `themetest` has required those
  to differ since §6w, because the gutter line numbers are `Text_Muted` and sit immediately beside
  comment text — a fact no screenshot shows. Wyatt's call was to make comments green and keep the dark
  one muted; the check then caught the *first* green too (0.055 channel diff against a 0.10 floor).
- **`md_bold`, `md_list_mark` and `table_zebra` are aliases**, each set to the value of a role that
  already exists. Folded into `Text_Bright`, `Accent` and a derivation instead. Six roles, not nine.
- The §19 code shapes are illustrative and the spec says so; `Quad` keeps its name and
  `metrics_recompute` keeps its globals.

### The metrics work was smaller than the specification thought, for a good reason

§3 rule 3 — *"round every metric once, at the point of scaling, into a struct… never scale at the call
site"* — is a defect the spec correctly predicted from screenshots. But `metrics_recompute`
(`main.odin:1448`) **already writes 21 named globals in exactly one place**, and already carries the
incident: a value scaled at its call site *"was being scaled a second time by one of them, squaring it
and pushing the OS drag region into the content."* So this extended a working pattern rather than
introducing the spec's struct, per the spec's own §0.

The rule used for what earns a name: a value in §2.1–2.4, or one two procedures must agree on, or one
a hit-test and a draw both read. A genuinely local offset with one reader stays on `sx()` — 167
globals would be worse than 167 call sites, and `UI_SCALE`'s own comment says it exists for exactly
those.

**The scrollbar had one number doing two jobs** and nobody had noticed, because they were only ever
the same number: every "right edge of content" computation subtracts `SCROLLBAR_W`, and the track quad
used it as its width. Split into a 14px lane and the 8px bar drawn inside it, which is where §2.3's
6px inset comes from. Same shape as the `Border_Subtle` split `theme.odin` records as **still open**.

### The pipeline: three things the test found that reasoning had not

`quadsdftest` renders on a real offscreen D3D11 device and reads the pixels back — which needed a
readback path in `gfx.odin`. CLAUDE.md asks for a real device over arithmetic when the claim is about
the GPU, and this claim rests on `fwidth`, a hardware derivative no CPU port of the distance function
would exercise. It earned that:

1. **The pass bound no blend state at all** (*"opaque; don't inherit the text pass's blend"*), which
   was correct while every edge was hard. A distance field resolves its edge *in alpha*, so without
   blending every antialiased boundary wrote partial coverage as an opaque colour.
2. **A shadow's falloff lies outside the rectangle, and the pixel shader only runs where there is
   geometry.** Shadows rendered as *nothing whatsoever* until the vertex shader grew the quad by the
   blur radius.
3. **`fwidth` ramps coverage over the last pixel or two inside *any* edge**, so routing every quad
   through the field would have softened the border of every existing piece of chrome — measured at
   r=244 where it had been 255. `radius == 0 && softness == 0` therefore returns the colour and never
   touches the field. That bypass is the compatibility contract, not an optimisation, and it is what
   lets this land under the whole UI at once.

### Two things this batch got wrong

- **The plan's first draft cited three things that do not exist as described**: it invented
  `Font_Set.Ui` and a chrome-routing step when `Font_Set.UI`/`.Doc` have existed since the atlas was
  written (Task 5 shrank to one field and one load call); it told the implementer to "confirm" whether
  the theme key table is generated when it is keyed over `Color_Role` and therefore compile-enforced;
  and it described the metrics work as building a struct from nothing. All three were caught by
  checking the plan against the code *before* committing it — which is the plan self-review step
  earning its place, since `development-loop.md` §1 lists cited-but-nonexistent procedures as the
  characteristic plan failure.
- **The first `quadsdftest` read the wrong channel.** It asserted coverage on alpha, but the frame is
  cleared to *opaque* black, so every pixel returns `a=255` whether drawn over or not — three checks
  failed for that reason rather than for a defect in the shader. Coverage is the colour channel.

### Owed

- **The absorbed-set assertions in `themetest` are gone.** They required every role to still hold one
  of its pre-migration literals — the right guard while §6v's migration was in flight, and a lock on
  ever retuning the palette afterwards. All 25 fired at once here and not one reported a defect. The
  contrast pairs replace them.
- **§3.8's fourth alignment check is not asserted**, and `metricstest` says why: tabs start at
  `MENU_W` because the hamburger sits there, so the active tab's left edge is not meant to match the
  editor's left padding until batch 13 rebuilds the rail.
- **Monaspace embedding is batch 20.** Fonts resolve by filename from `%SystemRoot%\Fonts\`; embedding
  needs hand-written `IDWriteFontFileLoader`/`IDWriteFontFileStream` vtables and a rewrite of
  `THIRD-PARTY-NOTICES.txt`'s claim that the project *"bundles and redistributes no third-party
  components."*
- **Nothing passes a radius or a softness yet.** The pipeline is built and tested; the tab pills,
  menu panels, focus rings and shadows that use it are batch 13.
- **§19's gamma-correct linear blending is not done.** It changes every measured ratio in §1 and
  deserves its own before/after, not a line in a four-item batch.
- **No live pass yet.** Every claim here is a headless measurement; the chrome sizes, the warm palette
  and the green comments have not been looked at on screen.

## 6ai. Wyatt's first live pass on batch 12 (2026-07-28, v0.21.1)

Three reports, on branches `fix/scrollbar-grab` and the colour work merged with it. All three turned
out to be measurable defects rather than taste, which is the useful pattern: a live pass finds things
a headless suite is not looking for, and then the suite can be taught to look.

### "if i click and hold on one of the edges of the rectangle it shoots to make the cursor center"

Both scrollbars re-derived the scroll position from the raw pointer on **every frame of the drag**, so
a press-and-hold re-ran the rail-click jump continuously. Wyatt's own follow-up diagnosis was the
precise one: the rail-click jump is correct and *"it's overwriting the click, hold drag"*.

Two things had to change for the fix to be exact rather than approximate:

- **The vertical thumb's geometry lived inside `render_frame`, computed twice**, so the drag could not
  see the thumb at all — which is *why* it mapped the pointer instead. `vscrollbar_geo` is now the one
  layout, consumed by both draws and by the press hit-test. The hit-test reads the bar **as last
  drawn**, one frame stale, and that is the correct staleness: the question a press asks is whether
  the pointer was on the thumb the user can see.
- **The forward and inverse maps disagreed.** `geo` positioned the thumb across the whole track while
  the drag inverted across the thumb's *travel*, so pressing the thumb and holding perfectly still
  moved the document by ~3% of its length. A thumb travels the track minus its own height.

`hscrolltest` had a thumb round-trip and it passed throughout, because it round-tripped the thumb
**centre** through a `pos_at` that took a pointer and subtracted half a thumb — so it round-tripped
through the centring rather than through the geometry. **No test on either axis ever compared a drawn
thumb position against the position a drag recovers from it.** That is the gap, not the arithmetic.

### "as an orange/green colorblind person… not enough of a difference between the text and comments and strings"

Measured under simulation, exactly right: body text vs strings **dE 6.4**, strings vs numbers **12.8**.
Green strings beside amber numbers is the pair that collapses under red-green deficiency.

Red-green deficiency flattens the palette onto lightness × blue-yellow, so five hues cannot be told
apart by hue. **Strings moved to teal** (differing from amber on the axis that survives); **comments
stayed green** — the convention is worth keeping — but now carry their cue in being *dim*. Worst
adjacent pair: 6.4 → **15.7** (Dark), → **10.9** (Light).

**The values came from a search against the simulation, not from taste, and that mattered:** a
hand-tuned attempt at the same brief scored **7.9**, worse than the search *and* worse than it looked.
Chroma is capped so nothing turned neon, and contrast is capped at **both** ends — an unconstrained
search drove Light's comments to near-black to win on lightness, which is precisely the
"contrastmaxxed" outcome Wyatt asked to avoid.

`themetest` now simulates deuteranopia and protanopia (Viénot-Brettel-Mollon) and scores the worse of
the two. It checks only pairs that sit adjacent in real code: requiring *every* pair to differ is
unachievable under a deficiency that removes a dimension, and chasing it is what produces garish
palettes.

### "on light/dark it's a bit hard to see the text"

Not perceived weight — **live chrome text was drawn in `Text_Dim`**, the disabled-only tier at 2.9:1
(Dark) and 2.8:1 (Light), below the AA floor by design. `theme.odin` labels that role, in as many
words, *"DISABLED ONLY -- never live text."* It was carrying inactive tab labels, the close button,
the menu and palette accelerator chords, and a setting reading "Off". An inactive tab is not a
disabled control; it is a document you can click, carrying the filename you are looking for.

The decorative `Text_Dim` uses were left alone (scroll-hint arrows, markdown bullets and the quote
bar) — batch 14 re-picks those against new layouts.

### "it wasn't toggling in the viewport" (v0.21.2)

Reported as everything word-wrapping with no horizontal scrollbar, then withdrawn as unreproducible
with the detail that mattered: Alt+Z was not taking effect until the files were closed and reopened.

**Most likely not a defect in what it did, but in what it said.** Wyatt's `settings.txt` carries
`md_default 1` — `.Preview` — so every `.md` file opens rendered. In that view `hscroll_model` returns
early (a preview has no horizontal axis), `markdown_draw` lays out to the pane, and nothing reads
`doc.wrap`. All three symptoms, all designed.

What was **not** designed: `.Toggle_Wrap` flipped `doc.wrap` unconditionally in three views that
ignore it — the grid, Preview and Split — so the key did nothing, silently, with no way to tell that
from a broken build. It now refuses and names the key that leaves the view, matching block.odin's
`Wrap_On`/`Split_On` refusals. Refusing rather than flipping quietly is the point: a flip you cannot
see leaves the setting somewhere you did not choose, and you find out later in a different file.

**The diagnosis is unconfirmed and the hole is worth recording**: the status bar reads
`Markdown Preview (Ctrl+M)` throughout, so it should have said so the whole time. If a later report
describes the same symptoms on a plain `.txt`, this fix is not the cause and the search starts again.

**And this class is not reachable from here.** This environment cannot press Alt+Z, so "the key did
nothing visible" is invisible to every headless test. What is checkable — and now checked, with plain
text as the control — is that the command leaves the flag alone and posts a reason.

### Owed

- **`Text_Dim` misuse has no guard.** Nothing stops the next widget reaching for it; the roles carry
  the contract only in a comment. A draw-time assertion would need the text pass to know which role it
  was handed, which it does not.
- The batch-12 owed list (§6ah) is unchanged: nothing passes a radius yet, gamma-correct blending, and
  Monaspace embedding.

## 6aj. The shell (2026-07-29, v0.22.0, branch `feat/batch-13-shell`)

Batch 13 of the UI overhaul: the tab rail, the focus ring, caption geometry and the window floor.
Spec: `docs/superpowers/specs/2026-07-29-batch-13-shell-design.md`.

**Motion is dropped deliberately, and the reason is in the spec so it is not re-added by someone
reading §18.** 50ms fades mean waking the message loop per hover, which trades away the idle-cost-zero
property CLAUDE.md and §19 both state outright. For a notepad whose whole pitch is instant, it is the
least valuable thing in the specification and the only one that costs an architectural property.

### Six walkers, agreeing by coincidence

The rail had **six** places computing their own `x` from `MENU_W - tab_scroll` and stepping by
`TAB_W`. They agreed because the width was a constant. Two were already wrong in ways that hid:

- `tabs_drag_update` recovered a tab index with `int(rel / (TAB_W + TAB_GAP))` — meaningless the moment
  widths differ.
- `tabs_right` ignored `tab_scroll` entirely, **and it feeds the non-client hit-test that decides where
  the window can be dragged.** Wrong there is either a dead strip of rail or a tab you cannot click
  because the OS took the press as a window drag.

`tabs_layout` is now the one geometry. The extraction landed first, with widths still fixed, so
anything that moved on screen was a bug; variable width came second, on top of it.

### What the audit corrected about the spec — and about me

- **§4.2's dirty marker existed**, as a `*` prepended to the label in `tab_title`. I told Wyatt it did
  not exist at all; that was wrong, and the correction matters because prepending is *precisely* what
  §4.2 says not to do — it moves the truncation point the moment a file is modified. It is now a mark
  in a slot reserved on every tab whether occupied or not.
- **End-elision was losing the extension.** Middle elision keeps both ends, and sabotage shows why
  directly: two different files both render as `2026-07-27-batch-…`.

### Two places the specification was not followed, both deliberate

- **The focus ring is four edge quads, not one annular SDF instance.** §18 asks for the latter; the
  pipeline resolves a *filled* rounded box and has no annular term, and adding one changes every quad's
  shader for a shape a handful of widgets use. Recorded rather than silently substituted — swap it if
  the ring ever needs a radius that reads.
- **The `×` in the close button and the `>_` are still glyphs**, while minimise/maximise/close became
  geometry. The caption buttons had to change because they sit in the non-client strip and had to
  follow §2.1's sizing; the rest can wait for a reason.

### What this batch got wrong

**The first sabotage passed.** Reintroducing the uniform-width division in the seam test did not fail,
because with fixed widths the old arithmetic still agrees — the test was vacuous for the check that
mattered most. Rather than record it as covered, `tabseamtest` gained a hand-built *non-uniform*
layout where sabotage does fail. That case then failed immediately, and it was the **test's** arithmetic
that was wrong, not the code (a tab at `x=100, w=132` ends at 231, not 232).

The focus-ring test also failed for the wrong reason first: `g_theme` is filled at startup by the
product and is all-zero in a headless mode, so "is the ring drawn" answered no because every role was
transparent black.

### Wyatt's live pass on v0.22.0 (v0.22.1)

*"13 looks good other than the tabs not actually being pills"*, then a screenshot, then the palette
bug he had been chasing for days.

- **The tabs were never pills.** `TAB_H_96` was written into the batch-12 plan and never into the
  code, so a tab stayed `TAB_STRIP_H - sx(4)` — 36 tall in a 40 rail, hard against the bottom, rounded
  on its top two corners. **The radius was drawing the whole time; the shape was the browser tab it had
  always been.** Now 30 tall, centred with 5px above and below, rounded on all four, and `TAB_GAP` is
  the specified 3 rather than 1 (at 1px the pills read as one bar).
- **The orange line under the active tab was the focus ring escaping the rail.** It draws *outside* its
  element, so an element flush against its container pushes it past — bottom edge at y=43 in a 40px
  rail, painting over the menu bar. Wyatt read it as a highlighting bug, which is a fair reading of an
  accent line where nothing is focused. It now clamps to its surface.
- **The ring was lighting on every keystroke**, because it was gated on the platform's "last input was
  a key" latch — and typing a character is a key. Focus is about where input is *going*, and a
  character goes to the document.
- **The palette drew its text on half pixels.** Its origin is `(width - w) / 2`; at the panel's maximum
  width an odd window width put `x0` on a half pixel, so every glyph sampled between texels in the
  alpha atlas and the run came out smeared. That is the whole reason it looked intermittent, and why
  *"if i move the left edge of the window 1 pixel it goes to look normal"*. `snap()` now exists for
  coordinates text is positioned from.

**Two tests were passing on paths they never exercised.** The per-corner radius selection had only ever
been checked with `{10,10,10,10}` — which a mapping returning one corner for all four would also pass —
while the tab shipped a release on `{6,6,0,0}`. And `metricstest` now checks **both window-width
parities**: testing one proves nothing about a bug whose entire shape is parity.

### Owed

- **The palette's category and accelerator columns collide** (`CursorCtrl+Home`, `FileCtrl+Alt+S`) —
  visible in Wyatt's screenshot and already named in UI spec §7. Batch 14.
- **Nothing enforces the §5 drop order above the floor.** `WM_GETMINMAXINFO` stops the overlap, but
  status cells, the `+` and the menu bar do not yet drop in order as the window narrows — they simply
  stop being drawn when they no longer fit.
- **The rail does not scroll to follow the active tab** when it is off-screen; the overflow count opens
  the palette instead, which reaches it but does not show it in place.
- **No live pass.** Pills, the ring, the caption geometry and the elision are all unverified on screen.

## 6ak. The chrome surfaces (2026-07-29, v0.23.0, branch `feat/batch-14-surfaces`)

Batch 14: menus (§6), the command palette (§7), Settings (§11) and the status bar (§13).

### What the spec got right, and the one thing it did not

**§6's first complaint is already fixed here.** *"The check mark shifts the label — ✓ is drawn in the
text run"* — it is not; `menu_draw_dropdown` draws the mark and the label as separate calls, the label
at a fixed `x0 + sx(28)` gutter. The specification was written from a screenshot of an older build.
The other three §6 defects were all real.

**The palette collision Wyatt photographed** (`CursorCtrl+Home`, `FileCtrl+Alt+S`) was a column drawn
**left-aligned at a fixed 130px from the right** while the accelerator beside it was right-aligned — so
the gap between them was whatever the category's length left over. Both are now right-aligned into
columns sized from the widest value in the whole table, so neither moves as you type and the
accelerators line up vertically. That last part is the only reason to draw them in a mono face at all.

### The width budget, which is where this could have gone wrong quietly

Giving disabled rows a reason means the accelerator column sometimes holds `Markdown files only`
instead of `Ctrl+M`. `dropdown_w` budgeted for the accelerator alone, so the reason would have been
clipped **by exactly the width the shortcut used to need** — a defect that only appears on the rows
that are disabled, which are the rows nobody clicks. The wording is therefore a pure function of the
command (`command_disabled_hint`), separate from the decision about whether to *show* it, so the sizing
can see it. `menutest` asserts every dropdown fits its own widest row; sabotaging the budget back to
the accelerator alone fails on View at 304 against 344 needed.

Dropdowns are also sized **per menu** now. Every one used to inherit the widest row in the entire menu
bar, so File was as wide as View's longest item.

### Text_Dim again

The status bar was drawn in `Text_Dim` — the disabled-only tier at 2.9:1, labelled *"never live text"*
in `theme.odin` — on every frame. That is the third surface carrying it (tab labels and the accelerator
chords were the first two, §6ai). **The role still has no guard**, and this is the evidence that a
comment is not one.

### Owed

- **The status bar's cells are not clickable** (§13: *"Encoding opens the encoding menu, LF toggles
  line endings"*), and there are no dividers between them — it is two text runs, not cells.
- **§7's ranking is unchanged**: still the existing filter, not the spec's exact-prefix >
  word-start > anywhere with recency tie-breaks.
- **§11's page margins and row padding** are untouched; only the selected-row treatment changed.
- **No live pass.**

## 6al. Find, replace and filter (2026-07-29, v0.24.0, branch `feat/batch-15-find`)

Batch 15: UI spec §12. Decisions taken with Wyatt — move the bar to the top rather than fixing its
content in place, build the two missing search modes, and fold the filter band into `Accent_Wash`.

### The bar was hiding the status line

Find and the status line shared the bottom strip through **one `if/else`**, so opening find removed the
file's encoding, line endings and cursor position from the window entirely. They are independent now.
`doc_bottom_bar_h` answered two different questions depending on state; it answers one.

**`TOP_INSET` is deliberately a single value.** The filter banner and the find bar both inset the
content, and `row_baseline_y`, `row_rect_y`, `row_at_y`, `doc_visible_rows`, the markdown panes and the
table all measure from it. Two addends is how a hit-test ends up one bar out of step with the draw —
the §6j shape, on the one change most able to produce it.

### Moving the bar moved a hazard with it

The bottom strip has always swallowed a fresh press, because `doc_pos_at` clamps an out-of-range row
onto the last visible one. The **top had no such guard**, and `row_at_y` goes *negative* above the
content — so a click in the search field would have clamped to row 0 and silently moved the caret. The
guard moved with the bar. It swallows only a fresh press, leaving an in-progress selection drag to keep
auto-scrolling, for the same reason the bottom one does.

### Two search modes that did not exist

Search was **always case-folded**, with no way to ask for exact case, and there was **no whole-word mode
at all** — so §12's "three toggles, always visible" was showing one. Both are in the literal scan now.

Whole-word carries **one byte across block boundaries** rather than re-reading: the scan's buffer
overlaps *forward* by `len(q)-1` so a match spanning a boundary is found, but the character *before* a
match at a block's first byte lives in the previous block. Underscore counts as a word character, which
is what stops `cat` matching inside `cat_x` — and is precisely what a naive alphanumeric test lets
through. That is the case the test pins.

### The three holes, filled before moving on (v0.24.1)

All three were shipped visible and inert, which is the worst shape for a defect: it looks finished.

- **Regex ignored two of the three modes.** `{.Case_Insensitive}` was hardcoded into
  `create_iterator`, and there was no word handling at all. Whole-word is a **post-filter** on the
  regex path rather than wrapping the pattern in ``: the pattern is the user's, and splicing anchors
  into it changes what alternation means (`a|b` becomes `a|b`). Filtering the *result* asks the
  same question the literal path asks, through the same `is_word_byte`, so the two agree by
  construction.
- **An uncompilable pattern reported "no matches"** — indistinguishable from a pattern that compiled
  and matched nothing, and meaning something entirely different. It says so where the count goes, and
  the flag clears on the next search so a corrected pattern is not still marked invalid.
- **The chips were computed inside `render_frame`**, so they were drawn to look pressable with nothing
  to hit-test against. `find_toggles` is one geometry consumed by the draw and the click.

### Owed

- **No live pass.**

## 6am. Clearing the orphaned debt (2026-07-29, v0.25.0, branch `fix/orphaned-debt`)

Wyatt asked for everything outstanding that no future batch would pick up. Batches 16–20 cover §8, §9,
§10, §14, §15, §16, §17 and Monaspace; everything below belonged to a batch that had already closed.

### `Text_Dim` finally has a guard, and it needed one

The disabled-only tier at 2.9:1 was drawn as **live text three separate times** — tab labels (§6ai),
the accelerator chords (§6ai), the whole status bar (§6ak) — while `theme.odin` said *"DISABLED ONLY —
never live text"* on that role the entire time. **A comment is not a mechanism.**

`themetest` now `#load`s the program sources at compile time and counts `g_theme[.Text_Dim]` against a
per-file allowlist. That is the only mechanism available: Odin cannot introspect a package, and the
draw call takes a *colour*, not a role, so nothing at runtime can know which tier it was handed.

Seven of the eight remaining uses were misuse and are fixed (markdown bullets → `Accent`, the quote bar
→ `Md_Quote`, four "there is more" indicators and a palette hint → `Text_Muted`). **One survives and is
correct**: the guillemet dimmed at the end of a settings range — a control that genuinely cannot step
further, which is what §11.1 asks for.

### A dead field, and the bug hiding under it

`app.tab_scroll` was **declared, read in four places, and never written**. The rail had never scrolled,
so Ctrl+Tab could land on a tab that was simply not drawn — the overflow count said "+3" and the
palette was the only way to reach one.

Fixing it exposed a second bug: `place` **stopped advancing `x`** at the first tab that did not fit, so
every overflowing tab shared one position and the strip's total width was unknowable — which makes any
scroll offset computed from it nonsense. Positions are absolute now; visibility is a separate question.
Invisible for as long as the rail never scrolled, which was always.

### The rest

- **Status cells** (§13): dividers, each clickable to the command it names, and §5's drop order
  enforced — measured against what the left group actually needs, so it holds at any DPI and font.
  Previously the right group kept drawing until it collided with the left one.
- **Palette ranking** (§7): exact prefix beats any subsequence score, ties break by recency. Recorded
  in `command_dispatch`, where every route converges, so a command run from a *menu* teaches the
  palette too.
- **Settings page margin** 32 → 28, matching its own value column (§11).
- **The stale worktree is gone.** Its one unique commit was byte-identical to one already on `main`
  under a different SHA. The branch is kept — deleting that is the half that cannot be undone.

### What this batch got wrong

The palette ranking test dispatched `.Save_As` to seed recency. That command **opens a file dialog**,
which is modal, so the headless run hung with no output — the fall-through trap `development-loop.md`
§6 documents, reached from a direction it does not mention. The counter is seeded directly now.

### Still owed, deliberately

- **`src/renderer` and `src/ui` are still stubs.** I described §19's SDF pipeline as "the renderer
  extraction" during batch 12; it is not. It was built in `platform/quads.odin` and is a *prerequisite*
  for the extraction, not the extraction. CLAUDE.md's as-built caveat stands unchanged.
- **§19's gamma-correct blending** — it changes every measured ratio in §1 and wants its own
  before/after.
- **`\?\` long paths, program layer** — ~15 `os.*` calls under `%APPDATA%`, reachable via
  `NEWTPAD_SESSION_DIR`.
- **Arenas on VirtualAlloc** — CLAUDE.md's locked-decision row says build them or amend the row.
- **§3.8's tab-edge alignment check** — still not meaningful; tabs start at `MENU_W`.
- **No live pass on batches 12–15** beyond two screenshots.

## 6an. Gamma, and the last of the orphaned debt (2026-07-29, v0.26.0, branch `fix/remaining-orphans`)

The remainder of what no batch would pick up. Wyatt chose to ship gamma directly rather than behind a
setting or after a live pass.

### Blending now happens in linear light

Text was composited as `text*cov + dst*(1-cov)` on **gamma-encoded** values. That weights
partially-covered pixels wrongly and thins light glyphs on a dark page — §19 says so outright, and it
is one honest candidate for the chrome text Wyatt reported as hard to read.

The render-target **view** is sRGB-typed and both pixel shaders decode their colour. Two properties
make this safe to land under everything at once:

- **Opaque fills are unchanged by construction.** The shader decodes, the hardware encodes, so a solid
  quad lands on the bytes it always did.
- **Only blended pixels move** — glyph antialiasing and the SDF's edges. Measured: a square corner's
  antialiased pixel 215 → 236, the focus ring 183 → 201. Heavier, which is the fix.

The type is on the **view**, not the buffer: a view may only reinterpret a *typeless* resource, so the
offscreen texture became `TYPELESS`. An sRGB view over a typed UNORM texture is `E_INVALIDARG`, which
is what it returned first.

**A test was asserting the wrong answer.** `quadsdftest` demanded 100..155 for a half-alpha blend and
passed at 128. Half of linear 1.0 encodes to about 186; 128 is what you get by blending gamma-encoded
values, which is exactly the defect. The check now expects the right figure and names the wrong one.

### The program layer is off `core:os` paths

`read_entire_file` goes through `_fix_long_path`, which returns the path **unchanged** without the HKLM
opt-in — the registry dependency CLAUDE.md forbids relying on, and one that does nothing without a
manifest entry this app deliberately does not ship. So every program-layer read had a silent
260-character ceiling, reachable through `NEWTPAD_SESSION_DIR`.

`plat.file_read_all` closes it; the creates, deletes, existence checks and the theme write route
through `plat`. **`diag.odin`'s append-mode log handle remains** — it needs a `plat` append primitive
that does not exist, and it is the least damaging of the set to lose.

### Two debt entries were stale, not outstanding

- **Arenas.** CLAUDE.md's Memory row was amended on 2026-07-27 and no longer specifies them. §5 kept
  listing it as owed, and it was cited as outstanding several times after the amendment landed. The
  entry is now marked resolved rather than deleted, because the failure mode was re-reporting it.
- **§3.8's tab-edge alignment check** does not apply to this layout: the rail opens with the `>_`
  button by deliberate choice (§7.1), so the tab edge and the text margin were never two views of one
  measurement. Recorded as **declined**, not pending — it had been carried as "belongs with batch 13",
  and batch 13 has been and gone.

## 6ao. The gamma change shipped washed out (2026-07-29, v0.26.1)

Wyatt, within minutes of v0.26.0, with a screenshot: *"all washed out"*.

`ClearRenderTargetView` on an sRGB-typed view treats its colour as **linear** and encodes it on write —
exactly as a shader return value is treated. The caller hands it an sRGB value, because a theme file
says `#221F1C`. So the canvas came out a full gamma stop bright while everything drawn *on top of it*
was correct. Measured: `#221F1C` landed as `#66625D`.

**I asserted "opaque fills are unchanged by construction" in §6an and it was false.** It held for the
two shaders, and I never looked at the clear. That is the failure mode of moving a pipeline's colour
space: every producer has to move, and the one that is not a shader is the one you forget.

`quadsdftest` now reads the cleared canvas back and requires the bytes the theme asked for. It asserts
the **round trip** rather than a computed constant, because the property is that an opaque colour
survives the pipeline unchanged — which is what makes an authored hex the hex you see. Sabotage
reproduces `#66625D`.

It is the only such producer; every other colour reaches the target through a shader.

## 6ap. Markdown, part one (2026-07-29, v0.27.0, branch `feat/batch-16-markdown` + `feat/batch-16-rest`)

Batch 16 of the UI overhaul: §9.2's construct list, in the parser and the preview. Wyatt scoped it to
the 13 numbered items and skipped the four dashed ones (images, footnotes, raw HTML, setext).

### What landed

**Inline:** strikethrough (`~~`), backslash escapes, task list items, YAML front matter.
**Block:** nested blockquotes, fenced code coloured by its language tag.

**The escape fix reaches past markdown.** `C:	empile.txt` used to toggle italics and restyle the
rest of the line, and `\*` never produced a literal asterisk. The escapable set is restricted to
CommonMark's punctuation on purpose — escaping a letter is not an escape, it is a backslash followed by
a letter, and treating it as one eats backslashes out of Windows paths.

**Nested blockquotes were silently wrong**, not missing: `md_quote` stripped one `>` and returned the
rest verbatim, so `>> two` put the second marker into the quoted *text* and a reply inside a reply
rendered identically to a single quote.

**Fenced code resolves its lexer through `highlight_lexer_for`** by building a pseudo-path, rather than
growing a second tag→lexer table. One mapping means a lexer added for a file extension works inside a
fence for free, and the two cannot drift on what `cs` means.

### Caught on the way

The table column separator had been moved onto `Md_Quote` during the `Text_Dim` sweep. It is a table
border, which §1 assigns to `Md_Rule`. Fixed.

### Owed — and the largest item is deliberate

- **Concealment is NOT done.** Wyatt chose §9.4's "hide the marks on non-caret lines, like Obsidian"
  over dimming them. It is not built, and the reason is recorded rather than glossed: hiding characters
  makes the *drawn* column stop matching the *byte* column, and `line_cell_col` / `line_offset_at_cell`
  are the documented seam between those two. Concealment has to go **inside that pair and nowhere
  else**, with the seam test extended — which is a batch's work, not a tail-end addition to a long
  session that had already shipped one visibly broken release.
- **Links, autolinks and reference links** (§9.2 item 8) are unchanged — inline `[a](b)` works, the
  other two forms do not.
- **Lists do not nest visually** beyond their indent; `md_list` reports depth and the preview indents,
  but there is no per-level bullet cycling.
- **§9.3's preview type scale and proportional face** are batch 17 and untouched.

## 6aq. The first live pass on the UI overhaul — part one (2026-07-28, v0.28.0, branch `fix/live-pass-0.27`)

Wyatt ran [the v0.27.0 checklist](docs/live-pass-v0.27.0.md) against his daily driver and annotated it.
Seventeen defects. **This release carries the first three**, cut mid-batch at his request so the fixes
reach his daily driver; the remaining thirteen are specced, planned and next. The spec is
[2026-07-28-live-pass-0.27-fixes-design.md](docs/superpowers/specs/2026-07-28-live-pass-0.27-fixes-design.md),
the plan is [2026-07-28-live-pass-0.27-fixes.md](docs/superpowers/plans/2026-07-28-live-pass-0.27-fixes.md),
and the live ledger is `.superpowers/sdd/progress.md`.

### What landed

**Chrome glyphs were drawn at fractional pixel positions.** An integer-sized glyph quad at a
fractional origin resamples across texel boundaries, which put a seam through every character in the
tabs and menus. Document text was never affected, because `text_char_width` rounds the advance so
column *n* starts exactly at *n·cell_w* — the chrome had no equivalent discipline
(`tab_base_y = ty + TAB_H*0.5 + UI_SMALL_PX*0.35`, and tab x positions off a fractional shrink step).
Fixed in one place, `text_draw_spans`, rather than in the dozens of callers.

**The viewport wasted a row, and the markdown preview overhung the status bar.** Both are row-budget
bugs but not the same one, and the *reported* cause was wrong: both `markdown_draw` call sites already
subtracted the status bar height. The real fault was that the loop bound compared a **baseline**
against the content bottom and then drew a full line height below it. Separately, `doc_visible_rows`
truncated the partial row away entirely.

**Fenced code blocks lost their state above the viewport.** `markdown_draw` began at `top_byte` with
`in_fence := false`, so scrolling past an opening fence rendered the block as prose *and* let the
closing fence toggle the state ON — turning the rest of the file into a code block. Wyatt reported
those as two defects; they are one lost bit. The plain editor had already solved this
(`doc_lex_state_at`), and the preview simply never asked.

### What this batch got wrong

**The plan's test code was wrong in all three tasks, in the way that matters.** Task 1's measured an
empty list (a device-less `Text` reports its atlas full, so nothing was recorded and "all positions
are integral" was vacuously true). Task 2's permitted a full row of overflow, and a second assertion
would have *failed a correct implementation*. Task 3's read lexer state directly — nothing it asserted
changed when the bug was reintroduced, so its own sabotage step would have printed `0 failures`.
Every one was caught downstream, none by the plan's self-review. **The lesson is narrower than "write
better tests": ask what value each assertion would reject.** Two of these asserted a property the bug
also satisfied.

**Two of the plan's root-cause hypotheses were wrong**, and the investigate-first steps are what caught
them — Task 2's `ybot` premise, and Task 3's "binary search the index", which is not implementable
over an alternating run sequence (no monotone predicate; galloping backward can step over a nearer
transition). The latter needed a sorted `opens` array of fence-open offsets instead.

**Task 2 introduced a regression and fixed it before merge.** Making the partial row clickable meant
`doc_pos_at` moved to the drawn budget while `doc_ensure_cursor_visible` stayed on the visible one, so
a click in the bottom sliver scrolled the view one line and a drag there scrolled one row *per frame* —
inside the band the code explicitly reserves as non-auto-scrolling. Exactly the §6j shape, inside the
task that had been warned about §6j.

**The plan cited four test modes that do not exist.** `seltest` fell through to the GUI path, opened a
window, and locked the exe against the next build. Verify a mode before citing it:
`grep -o 'os.args\[1\] == "[a-z]*"' src/program/test_modes.odin | sort -u`.

### Found on the way, unreported by anyone

- **The markdown lexer never recognised `~~~` fences** — only backticks. Seeding the preview from the
  lexer is sound only if both agree what a fence is, so tilde fences would have kept the bug intact.
- **Six of the eight extensions `doc_is_markdownish` admits had no lexer registered.** `.mkd`, `.mdx`,
  `.mdown`, `.mdwn`, `.mdtext` and `.mtext` reach Ctrl+M preview but resolved to a nil lexer, so the
  fence fix would not have applied to them at all. Both lists are now guarded against drifting again.
- **The drawer and the lexer disagreed about indented fences** in a way that is *parity*, not set
  membership: an odd number of 4-space-indented fence lines above the viewport flipped the seed the
  wrong way and painted code background over prose. That would have been a **new** wrong answer
  introduced by the fix. The two now share one indent rule.

### Owed

- **The fence fix has no end-to-end coverage.** Reverting `markdown_draw` to `in_fence := false` while
  leaving `md_fence_seed` intact leaves every suite green — a reviewer proved it. The draw needs a D3D
  device, so the seam is verified by reading code only. Closing it means driving `markdown_draw`
  through a headless GPU and inspecting the emitted `Md_Code_Bg` quads.
- **Keyboard navigation past the drawn boundary is untested.** Correct by inspection (the landing
  calculation is unchanged), but no assertion covers "cursor moves beyond `drawn` → view scrolls".
- **`fence_state` is not seeded**, so scrolling into the middle of a `json`/`c` fence whose content has
  an open `/* */` colours the visible remainder wrong. Bounded to the viewport; better than pre-fix.
- **Markdown headings can still overhang** the content box and are now clipped mid-glyph. Better than
  painting over the status bar, but the loop needs per-row height measurement to do properly.
- **The grid/CSV view still wastes its last row** — it stayed wholly on `doc_visible_rows`.
- **There is no scissor-rect facility anywhere in the renderer.** Task 2 used a cover strip, matching
  two existing precedents. A real scissor is its own renderer task.
- **Thirteen live-pass defects remain**, including both scrollbars, tab ordering, the link
  over-capture, and Replace All. See the ledger.
- **Non-local link targets are not resolved on the UI thread** (task 9 of this batch, commit
  `97f92fb` + a re-review fixup). `GetFileAttributesW` on an unreachable UNC host was measured
  blocking the caller for over 100 seconds, and `links_layout` runs on the UI thread every frame
  Ctrl is held or Show-links is "always" — so a single dead `\\host\share\out.log` in a pasted
  build log froze the editor. `plat.path_is_local` (`file.odin`) now refuses to stat anything on a
  `DRIVE_REMOTE` letter or a bare UNC path, and `links.odin`'s `link_stat` is the one place link
  resolution touches the filesystem, so the refusal cannot be bypassed by any of the three routes
  (Ctrl+click, the table view, the Open Link command). **What it costs the user:** `\\server\share\x`
  and `smb://server/share/x` targets are permanently plain text — never underlined, never openable —
  and so is every link (including a plain relative one) inside a document opened *from* a UNC path
  or a mapped network drive, because the anchor folder fails the same check. Removable drives (USB)
  and RAM disks are unaffected; only `DRIVE_REMOTE` (and `DRIVE_NO_ROOT_DIR`/`DRIVE_UNKNOWN`/
  `DRIVE_CDROM`) are refused, not "anything but `DRIVE_FIXED`" — a re-review caught the broader
  version. **The real fix** is an async resolver: a worker that stats off the UI thread and feeds
  answers back into `link_cache` between frames, the same shape `watch.odin` already uses for
  external-change polling (copy inputs, work in private memory, merge once per frame, poll a cancel
  flag). Deliberately kept out of this batch as a design change, not a bug fix.

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
    `celltest`, `blurtest`, `drawcount <file>`
  - Logging / crash: `logtest`, `crashtest <null|panic|assert|oob>` (triggers a real fault; set
    `NEWTPAD_SESSION_DIR` first — writes .dmp/.txt to its crashes dir, then exits with the fault)
  - UI surfaces: `menutest`, `menuseam`, `palettetest`, `settingstest`, `fonttest`, `historytest`,
    `linktest`, `tabreordertest`
  - Document / editing: `vnavtest`, `wraptest`, `wraplongtest`, `colperftest <mb>`,
    `scrollperftest <mb>`, `hscrolltest`, `csvtest`, `tablecellstest`, `tablereadonlytest`,
    `mdtest`, `mdviewtest`, `splittest`, `replacetest`, `findtest`, `regextest <mb>`, `metricstest`,
    `quadsdftest`, `scrollgrabtest`, `tabseamtest`
  - Files / session: `savepathtest <dir>`, `savestreamtest`, `savefailtest <dir>`, `resavetest <file>`,
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
