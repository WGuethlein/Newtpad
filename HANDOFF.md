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

### Where things stand — read this first (2026-08-01)

**v0.37.0 is merged, tagged, released and installed.** Newtpad is Wyatt's daily Notepad replacement and
has been all along. Everything below `§6` is a dated log of how it got here; **§6bd is the newest**,
§6bc was earlier the same day, and §6ax–§6bb were the day before.

**v0.37.0 made the markdown preview use CommonMark's paragraph model.** It had been rendering **one
source line as one paragraph**, so every hard-wrapped document — HANDOFF.md, a README, a spec — read as
a wall of one-line paragraphs while the blank line that actually separates two of them contributed
nothing. That is the bug Wyatt reported twice. Consecutive prose lines now join and re-flow, hard breaks
survive, an unmarked line after a bullet or a `>` continues that block, and setext headings work. §6bd
has the entry; four things from it matter before touching anything nearby:

- **A joined paragraph starts ABOVE its own line**, and the fixed 24-line run-up could not find its
  start. That broke Split scroll sync — the preview drew from line 0 while the editor sat at line 100.
  **`md_block_start_at` is the fix and every byte-to-block resolver goes through it.** It also cured the
  front-matter run-up imprecision open since batch 17.
- **`md_para_run` is a byte-WINDOW memo** — it answers for bytes it has never seen, on the premise that
  `md_para_bounds` is entry-independent. That premise is heavily probed but not proved, and it is what
  an 8× speedup is bought with (a 2000-line paragraph went 13.4 → 1.6 ms/frame).
- **`md_classify` is still pure and must stay that way.** Both predecessor-dependent features — lazy
  continuation and setext — live in the bounds layer, as *extent* decisions rather than kind decisions.
- **`mdtest` silently went 0 → 20 failures mid-batch** because it printed `FAIL` and exited 0. Six modes
  had that; 60 of 86 still do (see §5).

**Two live passes are outstanding and both are Wyatt's** — this environment cannot inject GUI input, so
everything about how these two releases *look* is an inference from source:

| Checklist | Covers | Why it matters |
|---|---|---|
| [docs/live-pass-v0.37.0.md](docs/live-pass-v0.37.0.md) | the preview's paragraph model | it changed how **every** markdown document looks, and setext changes documents that already exist |
| [docs/live-pass-v0.36.0.md](docs/live-pass-v0.36.0.md) | multi-column sort | §1 is the data-loss seam — edit a moved row while sorted, save, verify elsewhere |

**Next batch is 20, Excel-style column filtering** — the other half of what Wyatt asked for on
2026-07-31. Two decisions are already taken (it refuses past `TABLE_SORT_MAX`; it is exclusive with
`Ctrl+L`), the header menu exists to hang a `Filter` row on, and `table_header_layout` is the one
producer of header geometry. See `requested-features.md` §1.

**Batch 19 shipped multi-column sort** — the table view sorts by up to two columns, first-selected-wins,
through a header menu (hover chevron or right-click), Ctrl+click, and the plain click that already
existed. **Column filtering is batch 20 and is not built.** §6bc has the full entry; four things from it
are worth knowing before touching anything nearby:

- **The key cap is 2, and it is a measurement, not a preference.** Three keys at the 100,000-row ceiling
  cost ~460 ms of release freeze against one key's ~258 ms. Changing it needs a fresh measurement *and* a
  decision about the summary row's wording.
- **`ctx_col` is valid only between a `menu_open_ctx` and the dispatch of the row it produced.** It
  deliberately survives `menu_close`; that is what makes a menu row picked on column N act on column N.
- **`menutest` and `settingstest` printed `FAIL` and exited 0** until this batch. **`menuseam` still
  exits 0 whatever it finds and always will** — it is a falsifier, so sweep it by diffing its printed
  line, never by exit code.
- **Eleven comments in one batch claimed evidence they did not have**, every one caught by review and
  none by a test. See §6bc — the pattern matters more than the instances.

**The three live queues are the entry point for new work, not this file:**

| File | Holds |
|---|---|
| [docs/reported-bugs.md](docs/reported-bugs.md) | bugs reported from daily use, not yet fixed |
| [docs/requested-features.md](docs/requested-features.md) | everything owed or asked for, with the decisions already taken |
| [docs/features.md](docs/features.md) | what already works — check here before believing "X is missing" |

They are **queues, not histories**: when an item ships it is deleted from them and recorded in a `§6`
entry here. If one of them and this file disagree about what is owed, the queue is newer.

**What shipped on 2026-07-31 (v0.33.0 → v0.35.0, six releases in a day):**

- **Batch 18 finished** — §10's table view is complete: row numbers, click-to-sort, numeric/date
  right-align, drag-to-resize and double-click-to-fit, malformed-row marking, a summary row. **The sort
  is view-only and never rewrites the file**, and editing a cell while sorted still writes to that
  cell's own line (§6ax).
- **A sparse line index** (§14's owed piece) — `doc_line_no_at(byte) -> (line_no, exact)`, bounded, with
  checkpoints repaired on every edit so row numbers survive editing *and* saving. Three table features
  were blocked on this and nobody had named it (§6ax).
- **Six live-use defects** across two passes (§6ay, §6az), including the grid's horizontal scroll, which
  was panning by *column index* while its scrollbar thumb was sized in *pixels*.
- **The window no longer flashes white on launch** — it was 196 ms of empty window in front of
  `gfx_init`, present since long before it was noticed (§6ba).
- **`Ctrl+A` no longer selects the trailing blank rows**, a deliberate divergence from VS Code, Notepad
  and Sublime (§6bb).
- **The exe finally has a version resource.** It shipped with empty `FileVersion`/`CompanyName`/
  `ProductName` for its entire life, which is one half of why a GitHub download tripped Defender.

**Verified by Wyatt on real pixels, 2026-07-31:** Ctrl+A, the launch change (focus is correct from the
shortcut and from Explorer), and the table view. Those live-pass items are closed; do not re-raise them.

**The one thing outstanding that needs a person, not code:** a **Defender false-positive submission**,
which needs Wyatt's account. VirusTotal on v0.33.0 returned **1 detection of ~40** — Microsoft
`Trojan:Win32/Wacatac.B!ml`, the `!ml` suffix being their own marker for a machine-learning verdict —
while every other ML engine on the panel returned clean. Nothing is vendored and the updater cannot
download or execute anything; both were verified. Details in `requested-features.md` §3.

**Where the roadmap stands.** §6aa is still the plan of record: the V1 feature list is done, the UI
overhaul and the `renderer`/`ui` extraction are V2, and a free public beta precedes the paid V1. Two
things still block a beta and both are Wyatt's: **code signing** (the pipeline is signing-*ready*;
never handle a certificate or its password) and a licence that grants a tester something.

**The `renderer`/`ui` extraction got measurably harder today and this is the moment to know it.**
`doc.odin` → `table.odin` went from **1 call site to 8**, all pointing upward under the planned
boundary; the sharpest is `pt_edit_replace` → `table_sort_shift`, the buffer-write primitive now calling
into a view module beside `ckpt_repair` and `bookmarks_shift_replace`. That was the right call — "hook
the one procedure nothing can avoid" is why the sort's lifetime is correct by construction rather than
by seven remembered call sites — but **design the observer list before extracting, not during** (§6ax).

**Two claims that were checked and found false, recorded so they are not re-derived:**

- `odin check src/program` **does** catch undeclared names and exit 1, so development-loop §5's
  per-commit bisectability sweep is not vacuous. A fixing agent reported the opposite (§6az).
- `WATCH_MAX` 32 → 64 was named as the likely cause of a startup/shutdown regression. Measured, the old
  value was *slower*, and **there was no regression at all** — five tagged builds timed identically
  (§6ba). Fixing that by inspection would have reverted a good change and left the symptom.

**The recurring failure this project has not solved.** Eleven consecutive batches have shipped draft
test code that **could not fail** — an assertion whose fixture never reaches the condition it names.
Today alone: `palettetest`, `hscrolltest` and `tablegridtest` each printed `FAIL` and exited **0**, and
several freshly written assertions were found vacuous by sabotage, including ones written minutes
earlier by the agent that then caught them. **Sabotage discipline (development-loop.md §3) is the only
thing that has ever caught these.** Do not skip it, and record the actual failure output — "I verified
it fails" without the output has been wrong more than once.

**Traps that cost real time today**, beyond those already in development-loop.md §6:

- `Set-Content -Encoding UTF8` adds a **BOM** and corrupted two source files. Use the Write/Edit tools.
- A sabotage that **fails to compile** is indistinguishable from a sabotage that breaks nothing — the
  stale exe runs and prints `0 failures`. Check the build's exit code before believing a green run.
- `build.bat` prints a harmless `'vswhere.exe' is not recognized` line. It is **not** a failure.

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

**Note:** §2 describes the first day and is kept as a snapshot of it, not as current state. Much more
has shipped since — tabs, session restore, command palette, menu bar, settings, font selection, undo
history, zoom, word wrap, external-change detection, per-monitor DPI, single-instance, an installer,
multi-column sort, column filtering. **§6b onward is the accurate record; read the LAST `§6<letter>`
section for the most recent state** rather than a section named here, which is a pointer that goes
stale every batch and has done so repeatedly.

Verified: **229 `odin test` cases** in `src/base` (encoding, line-nav, piece tree, lossy-encoding
detection) plus the headless modes in `test_modes.odin` — see §7 for the list that a sweep must
cover, and read it rather than a shorter one carried in a batch plan: `hscrolltest` was dropped from
one such list and the seam it owns went unrun for two releases (§6bu). Wyatt daily-drives the editor,
which is now the main source of bugs, because this environment cannot inject GUI input.

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

- ~~**60 of 86 headless mode entry points print `FAIL` with no `os.exit` on any path.**~~ **DONE
  2026-08-02 (§6bv), and the pass was smaller than this entry made it sound.** The scan was right
  about the count and wrong about the shape: **396 of the 403 `FAIL` lines were correctness
  assertions and only 7 were wall-clock gates**, and **55 of the 60 modes already kept a counter and
  printed the verdict** — they computed the answer and threw it away. Every mode now ends at a shared
  `mode_done`, and **`modeguardtest` fails the build's sweep if a new one does not.** Four modes were
  found asserting nothing at all (`sehtest` printed whether the SEH guard caught a page fault and
  never checked it; `vnavtest`'s seven assertions; `dpitest`'s linearity check; `regextest`'s planted
  needle), which is the *other* half of the disease this entry only named half of: an exit code
  cannot fail on an assertion that was never counted. `menuseam`, `drawcount` and `jsonperf` stay at
  exit 0 by name and with a stated reason.
- ~~**`md_table_ensure`'s cache key omits `md_table_budget` / `md_table_max_rows`.**~~ **FIXED
  2026-08-02 (§6bw).** Real, reachable and measured: without the key a lowered budget read back the
  production-budget entry — `oversize=false, window=9313` where the correct answer is a bounded
  ~4.9 KB window. `mdtabletest` had been defending against it by hand, clearing `doc.md_table` before
  every budget change; the guarantee lived in seven copies at the call sites instead of in the cache.
  The key now carries it and four of those clears are gone, so removing the key check fails
  `mdtabletest` in three places.
- ~~**`md_table_bounds` has the same coverage gap `md_para_bounds` had.**~~ **WITHDRAWN 2026-08-02 —
  the claim was false, and how it got here matters more than the claim.** The covering assertion
  (*"bounds() trips oversize with a bounded window"*) has existed since **2026-07-25**, six days
  before this entry said it was missing. Deleting `if r - p > md_table_budget` today fails
  `mdtabletest` on exactly that assertion.
  **The entry is an artefact of the bug §6bv fixed.** On 2026-08-01 `mdtabletest` ended
  `fmt.println("mdtabletest: FAILURES" …)` / `return true` — no exit code. Reproduced at that commit
  in a worktree: with the guard deleted the assertion **fired and printed FAIL, and the process
  exited 0**. A reviewer sabotaging the guard and reading the exit code saw 0 and concluded "not
  covered". The method was broken, not the coverage, and the conclusion was recorded here as
  *verified*.
  **The generalisation, which is the reason to keep this text rather than delete the entry: any
  "X is not covered, confirmed by sabotage" reached before 2026-08-02 was reached with an instrument
  that could not read.** Re-verify such a claim before scheduling work off it — the whole cost of
  this one was two days of a debt register carrying an item that never existed.
- **Scroll resolution still happens inside the draw**, against CLAUDE.md's hard rule ("a widget's
  geometry is produced by exactly one `*_layout()` procedure… scroll resolution must not happen
  inside the draw"). `menu_draw_dropdown` calls `menu_scroll_to_item`, which writes `menu.top`.
  Made edge-triggered in §6bt after it silently reverted every scrollbar drag — **that removed the
  bug, not the violation**, and the violation is what let a second writer of `top` go unnoticed for
  as long as there was only one. The fix is to call it from the places that MOVE the highlight
  (`menu_step`, the keyboard handlers), which need the dropdown height and therefore the rect;
  worth doing with the `renderer`/`ui` extraction rather than alone. This entry exists because the
  same shape cost three consecutive releases (§6br → §6bt → §6bu), each one a different procedure
  claiming state the drag needed.

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
- **`replace_sel_raw` (`doc.odin:2183`) does not clamp its range.** Pre-existing, shared with
  `find_replace_current`, and out of scope for the Task 15 review that surfaced it (batch's live-pass
  0.27.0 pass on Replace All). Until now the only caller reachable from the UI was a single-splice
  path; making `find_replace_all` reachable from a button and a menu row means the same unclamped
  range is now exercised up to `MAX_MATCHES` times per press instead of once, widening the blast
  radius of any future out-of-range bug from one splice to a saturated pass's worth. Not fixed here —
  the clamp belongs to whoever owns `replace_sel_raw`'s contract, not to the task that merely gave it
  more callers.
- **~274 unchecked `make` calls on `context.temp_allocator` across the tree, all subject to the same
  trap the resize crash used.** `#optional_allocator_error` silently drops the allocator error on every
  one of them, so a genuine process-level out-of-memory anywhere else in a frame still produces a
  zero-length slice fed to the next line, not a graceful degrade. §6au fixed the resize path's own
  arena (which cannot refuse short of process OOM); it did not fix the shape everywhere. No plan to
  audit all ~274 at once — the fix, if this is ever worth doing broadly, is a checked-alloc helper that
  fails a frame instead of trapping it, applied where a reviewer next finds this shape.
- **`markdown.odin:2154` passes `context.temp_allocator` as `shape_run`'s PERSISTENT allocator
  argument** (the parameter is `allocator := context.allocator` at `shape.odin:184`, not a scratch
  param). Benign today — only `.line_h` is read off the returned `Shaped`, the rest is discarded — but
  `plat.shaped_free` called on a value built this way would `delete` temp-arena memory through the heap
  allocator. Same shape as `shape.odin:397`, which indexes `boxes` allocated on `shape_spans`'
  caller-supplied `allocator`, not a stray temp `make` inside `shape.odin` itself: whoever hands
  `shape_spans`/`shape_run` a resize-scoped temp allocator and then persists or frees the result owns
  this footgun. §6au.
- **The growing resize arena (§6au) made a new invariant load-bearing that nothing enforces.**
  `resize_temp_end` calls `arena_destroy`, which returns its block to the heap — unlike the old shared
  `@(static)` buffer, which stayed mapped for the process's life. Any pointer that escapes a resize
  repaint's temp arena and is dereferenced later is now a REAL use-after-free (freed, unmapped memory),
  not a stale-but-readable value. Clear today: `Md_Layout`'s persisted fields are all on
  `context.allocator` and `md_layout_free` deletes them through it. Audit-only, not enforced by any
  assertion or type.
- **Deviation from the UI spec, decided in review (batch 18, F5): the table view's empty-cell em dash
  is `Text_Muted`, not the `text_dim` §10 literally names.** `theme.odin` labels `Text_Dim` "DISABLED
  ONLY — never live text" at 2.9:1 Dark / 2.8:1 Light, below the AA floor; §18 justifies that exemption
  as WCAG's disabled-control exemption, "redundant with the control not responding." The dash is
  neither disabled nor redundant — its entire job is to distinguish "empty, and we parsed it" from
  "missing / short row," a distinction group C's warning bar exists to give the *other* case — so a
  reader who cannot resolve the dash loses exactly the information it was added to convey. That is
  live content. `table.odin`'s `TABLE_EMPTY_CELL` comment and `themetest`'s allowlist (`test_modes.odin`,
  the `Text_Dim` guard) were both reverted to reflect this: the guard is back to 0 uses in `table.odin`,
  same as every file without a genuinely disabled control. The one real exemption left in the tree is
  `settings.odin`'s range-end guillemet, which is dim *because* it is a control that cannot be stepped
  further — the case the WCAG exemption actually describes.

  **This decision settles three sites, not one** — §10 also names `text_dim` for group B's row-number
  gutter (not yet built) and §15 for the empty-tab hints (ditto). Both should follow the same reasoning
  (a hint or a row number a reader cannot resolve is lost information, not a disabled affordance) unless
  whoever builds them finds a reason the dash's argument doesn't transfer. Overturn here, in one place,
  rather than re-litigating per site.
- ~~**Carried from batch 18 review (F4): scrolling or resizing while a table cell edit is open
  desynchronises the edit box from the bytes it writes.**~~ **FIXED** in batch 18 (`table_edit_hold` /
  `table_edit_anchored`, `table.odin`; one call per frame in `main.odin`). One guard rather than a
  commit bolted onto each scroll route: it asks the seam directly — does the drawn row still name the
  line the captured span lies on, and does that row still fit under the sticky header — so the
  scrollbar drag, Page Up/Down, a find jump, a session restore and a window resize are all covered.
  Covered by `tablegridtest`'s `tg_edit_anchor`; both halves of the guard were sabotaged separately and
  each failed exactly the routes it owns. **Its Wheel route was never evidence for the guard**: the
  wheel arm commits inline in the frame loop and the test replays that arm by hand, so those four
  assertions stay green with the guard deleted — verified 2026-07-30, and the entry used to claim the
  test *"drives all five routes."* It drives five; four of them were the guard's. A sixth route,
  `Wheel_Bare`, now runs the same scroll with the inline commit omitted, which is what the frame loop
  would look like if that line were ever removed: with the guard sabotaged, `Wheel` stays green on all
  four assertions and `Wheel_Bare` fails all four. The wheel is covered by something falsifiable now,
  and `Wheel` stays as documentation of the inline commit, whose hand-copy can drift.
- **A REORDER under a live cell edit needed a third compare, and the first version of the guard did
  not have it** (reviewed 2026-07-30). The entry above used to claim the row-start compare caught a
  sort as well. **It did not, and the claim was the trap:** the compare was `table_row_start(doc, r) ==
  doc.table_edit_line`, two *byte offsets*, and a permutation of lines that all have the same byte
  length leaves the r-th line starting at the r-th offset. That is not a contrived fixture — it is what
  an export looks like (`00012,2026-01-14,ACTIVE`: zero-padded ids, ISO dates, fixed status codes).
  Edit row 11's id, sort, rows 11 and 12 swap, the compare reads "nothing moved", and `[s,e)` now spans
  row 12's id field, which `table_edit_commit` then splices the typed value over. Not live — no sort
  exists and `Sort_Lines` is refused in table view — but it was owed to the task that builds the sort,
  in the exact document that task would have read.
  **Fixed by making the identity the line's own bytes** (`table_edit_snap`, `table_edit_line_intact`):
  the line, capped at `RENDER_LINE_CAP`, is copied at edit start and compared each frame. A reordering
  cannot forge that — any line differing in one byte fails — and the one thing it cannot distinguish,
  a swap of two *byte-identical* lines, is the case where it does not need to: the value lands on a row
  indistinguishable from the one clicked and no other row's data is touched. A generation counter was
  the alternative and was rejected because whoever writes the sort has to remember to bump it, which is
  the exact class of miss the one-guard design exists to close.
  **`table_edit_commit` now refuses a stale span outright rather than committing it** — the one case
  where the user's keystrokes are dropped instead of kept, because a rewrite leaves nowhere safe to
  write. It is in the *write*, not in the frame guard, because Enter, the wheel arm, `leave_table_view`
  and `.Toggle_Table` all reach the splice without passing the guard. Covered by `tg_edit_permute`
  (Guard / Enter / Control routes, equal-length fixture); with the byte-offset compare restored it
  fails 5 assertions, and the Enter route loses row 12's id outright (`"00013,…" appears 0 time(s)`).
- ~~**Reported by Wyatt 2026-07-29 (D1): Ctrl+V with the find bar focused pasted into the DOCUMENT.**~~
  **FIXED** in batch 18 (`resolve_key` / `find_fallback_writes_doc`, `commands.odin`; `.Find_Paste`,
  `find_paste`, `find.odin`). Recorded here because `docs/reported-bugs.md`'s own rule says a shipped
  item is deleted from the queue and written up here instead, and the first pass deleted it without
  writing anything — the widest-blast-radius fix in the branch existed only in a commit message.
  **It was never only about paste.** `resolve_key` falls the `.Find` context back to the `.Editor`
  bindings for *modified* chords, which is deliberate and right for reads (Ctrl+S, Ctrl+P, the tab
  chords should not die because a bar is open) — but it handed the find bar **six writers**: Ctrl+V
  pasted, Ctrl+X cut the document's selection, Ctrl+Z/Ctrl+Y undid and redid it, Ctrl+Backspace deleted
  a word behind an invisible caret, and Alt+Up/Down moved document lines. All of them under a bar whose
  viewport takes no keystrokes, so **nothing typed there could be taken back without closing the bar
  first.**
  **The document really did become dirty**, which is what makes this data loss rather than a curiosity:
  dirty tab, save prompt on close, and no undo reachable while the bar is open. Measured by walking
  `pt.length` through the chords: **18 → 6 → 18 → 6 → 0**.
  **And the filter bar IS the find bar** (`find_open(doc, …)` plus `doc.filter`), which is the surface
  Wyatt reported it on — so plain Find and Replace had exactly the same hole on exactly the same chords.
  **Fixed as a class, not as six chords**: `find_fallback_writes_doc` refuses the fallback for anything
  `command_mutates_doc` names, with `.Find_Replace_One` / `.Find_Replace_All` as the two stated
  exceptions (they are declared in `.Editor` and not in `.Find`, so the fallback is the only way they
  reach the replace row). Ctrl+V then got a real binding, `.Find_Paste` → `find_paste`, which takes the
  clipboard's first line into the focused field. **Read `find_fallback_writes_doc`'s own comment before
  trusting the word "class"** — the predicate it composes from is the table-view read-only set, not the
  buffer writers, and the difference is written up there.
  **Two asymmetries were left behind on purpose, and they are the ones to look at first if this comes
  back:** `Alt+Shift+Left/Right` still extends a **column rectangle** from the find bar while
  `Alt+Shift+Up/Down` no longer does (the vertical pair are on the mutating predicate, the horizontal
  pair are not — a column selection is not a write, so neither is wrong, but the pair now behaves
  differently); and `Ctrl+C`/`Ctrl+A` still act on the **document**, not on the query, because the find
  fields have no selection model at all (`find_backspace` deletes from the end; there is no caret). Both
  are reads. A `Find_Select_All` / `Find_Copy` pair would close the second, and `keytest` pins both as
  deliberate so the next reader knows nobody forgot them.
- **Carried from batch 18 review (F6): table zebra-band parity is viewport-anchored, so every
  odd-row scroll inverts every band.** Documented and accepted as shippable in `table_draw`'s own
  comment (parity by visible row index, not absolute file position, because the absolute index needs an
  unbounded newline count from byte 0). The reviewer's correction, recorded for whoever builds group B:
  **parity needs one bit, not a count.** `doc.top` only ever moves by known row deltas from a known-even
  anchor (the wheel, the page keys, the scrollbar), so a parity bit maintained alongside `doc.top` costs
  nothing and needs no walk from byte 0 — unlike group B's row-number gutter, which needs the real
  absolute row number and *is* unbounded. Decide count-on-demand-with-a-cache vs. viewport-relative
  numbering once, in group B, and let the zebra's parity ride on whichever it picks rather than solving
  the cheaper problem twice.
- **Carried from batch 18 review (F10): a header line longer than `RENDER_LINE_CAP` puts
  `table_data_start` inside line 0**, so "data row 0" becomes the header's own tail instead of the
  first real data line. The draw and the hit-test still agree (both read through `table_data_start`), so
  this is not a wrong-row write — but `table_data_start` is the single normalisation point the wheel
  routes `doc.top` through on both sides of a scroll (§10's group A design), so a capped offset becomes
  a *persisted* scroll position rather than a one-frame glitch. Not fixed: `RENDER_LINE_CAP` headers are
  not a real CSV shape, and the fix (an `exact` flag on `pt_line_end_cap`, matching the `line_cell_col`
  entry above) is shared infrastructure, not table-specific.
- **Two brittle assertions from batch 18's `tablegridtest`, flagged in review for whoever touches
  their neighbourhood next:** `nnorm == 2` (the wheel-normalisation check) counts occurrences of the
  literal substring `"table_data_start(doc)"` across the whole of `main.odin`, so any unrelated third
  call site — added for any reason — fails the test with no connection to what it is meant to guard.
  `nsep == 0` rejects *any* `Border_Subtle` use in `table.odin` on the theory that the column rules are
  gone for good; group C's planned malformed-row bar is exactly the kind of addition that would trip it
  for a reason unrelated to column rules reappearing. Neither is wrong today; both are counting
  substrings as a proxy for an intent the count cannot actually distinguish from an unrelated match.

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

## 6aq. The first live pass on the UI overhaul (2026-07-28/29, v0.28.0 + v0.29.0, branch `fix/live-pass-0.27`)

**Read §6ar for the second release's summary and its cross-cutting findings.** This section grew as the
batch ran, so it carries per-task detail for tasks 1–3 (shipped as v0.28.0) and, from "Part two"
onward, for tasks 10–13 as well. §6ar covers the batch as a whole.

Wyatt ran [the v0.27.0 checklist](docs/live-pass-v0.27.0.md) against his daily driver and annotated it.
Seventeen defects. **v0.28.0 carried the first three**, cut mid-batch at his request so the fixes
reached his daily driver; the remaining thirteen shipped as v0.29.0. The spec is
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
- **The horizontal scrollbar's range never shrinks within a session.** `Document.max_cells_seen` is a
  high-water mark: `doc_max_hscroll` scans only the visible rows (viewport-first) and raises the mark,
  never lowers it. That is what fixed *"the horizontal scrollbar only allows expanding if the large row
  is on screen"* — the range used to collapse the moment the wide line scrolled off. **The cost, which
  Wyatt accepted (2026-07-28) rather than pay for a background full-document scan:** delete the longest
  line and the bar keeps offering pan into content that no longer exists, for the rest of the session.
  Measured — one 400-cell line plus 50 short ones gives `doc_max_hscroll` = 323; after deleting the long
  line through `doc_replace_sel` it is still 323. Only a reload (`doc_reload_forced` replaces the whole
  struct) clears it. A correct reset would have to know the new widest line, i.e. rescan the document on
  every edit, which is exactly the work the high-water mark exists to avoid. **If this is ever revisited,
  the shape is the async resolver's**: a worker that scans off the UI thread and lowers the mark between
  frames. Note also that `doc_max_hscroll` is a getter that **mutates the `Document` from the draw path**
  — main-thread only, not idempotent, not job-safe.
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
- **And the async resolver is owed as a TIME bound, not just as network coverage.** `links_layout`
  still performs filesystem stats **on the frame path** — up to three times per frame while Ctrl is
  held, every frame when Show-links is "always", and `doc.top` is part of the cache generation, so
  every scroll step re-stats the whole screen. The only bound today is `LINK_RESOLVE_BUDGET`, which
  caps a **count of stats, not the time they take**, and `path_is_local` only excludes `DRIVE_REMOTE` /
  `DRIVE_NO_ROOT_DIR` / `DRIVE_UNKNOWN` / `DRIVE_CDROM`. A **fixed** volume that happens to be slow —
  a OneDrive/Dropbox sync root, a filesystem filter driver from an AV product, a cold spinning disk —
  passes `path_is_local` and blocks the UI thread anyway. Measured: **3.32 ms/frame** scrolling a
  document with 200 missing local targets. Nothing in the tree makes that impossible; only the async
  resolver does, because it is the only design where a slow stat cannot be on the frame path at all.

### Part two: tasks 10–13 — checkbox tick, done-item colour, quote markers, front matter (2026-07-29, branch `fix/live-pass-0.27`)

Four more items off [the v0.27.0 checklist](docs/live-pass-v0.27.0.md), each its own commit
(`.superpowers/sdd/task-10-13-report.md` has the full per-task writeup: what the brief got wrong, the
test, the sabotage).

**What landed:**
- **Task 10 — the task-list checkbox's tick is centred on the box**, not low-and-right. It is now
  geometry (`md_tick_quads`, a stepped X of small quads) rather than a glyph, so the centring is exact
  by construction and mdtest asserts it to 0.05px.
- **Task 11 — a completed task item mutes every colour, not just the base-coloured prose.** Themed runs
  (bold, code, links, italics) used to ignore the mute entirely; `md_run_color` now applies it after role
  resolution, and `MD_DONE_MUTE :: 0.26` is a *derived* placeholder (solves `mute(Text_Primary) ==
  Text_Muted` for both themes, doesn't land exactly on either).
- **Task 12 — every `>` in a nested blockquote gets the same syntax-colour role**, not just the first
  marker (`src/base/lex_markdown.odin`).
- **Task 13 — YAML front matter draws as one card**, not a 2px bar per line (the old bar was the
  blockquote's own decoration, borrowed by accident).

**A 2026-07 review found eight defects in that landing**, fixed in the same branch:

- **A done item's prose was muted TWICE.** The done branch set the base colour to `Text_Muted` *and*
  handed it to `md_run_color`'s mute step, which lerps toward the page a second time — contrast against
  `Bg_Base` measured 5.4:1 → 3.58:1 in Dark and 6.0:1 → 3.28:1 in Light, both under the 4.5:1 floor every
  text role in `theme.odin` is annotated against. Fixed by keeping the base at `Text_Primary` and letting
  the mute step do the only muting (`md_task_prose_style`, `markdown.odin`).
- **The fix for that bug had no test coverage at the call site.** Sabotaging `markdown_draw`'s task
  branch directly (not the shared procedures underneath it) printed `0 failures` — mdtest only ever drove
  `md_run_color`/`md_mute` with hand-picked arguments, never asked what the draw itself passes. Closed two
  ways: `md_task_prose_style` is now the ONE procedure both the draw and mdtest call, and `mdtest` gained
  a draw-level pass (`md_draw_selftest`, `test_modes.odin`) that renders through a real offscreen D3D11
  device (the `quadsdftest`/`Headless_Gpu` precedent) and reads back actual pixels — the done-item prose
  colour and the front-matter card's row-advance are both verified against a REAL render, not a copy of
  the logic. **That claim originally read "sabotaging either call site now fails a test", and it was
  false in one direction** — the whole-branch review restored the *original* Task 11 defect
  (`task_col = g_theme[.Text_Muted]` with `task_mute` left at 0) and the whole suite still printed
  `mdtest: 0 failures`. The draw-level pass sampled only the **plain prose** glyph, and asserted
  `near(mute(Text_Primary, 0.26))` — which, by `MD_DONE_MUTE`'s own derivation, *is* ≈ `Text_Muted`,
  i.e. the pre-fix colour. It rejected "muted twice" and could not tell "muted once" from "not muted at
  all". Closed 2026-07-29 by sampling a **styled** run as well: the fixture is now ``- [x] IIII `II` ``
  and its undone twin, and the code span is asserted muted relative to the undone item's identical
  span. A styled run's colour does not depend on the base at all, so only the mute step can move it.
  Verified by re-running the sabotage: **2 failures**. The front-matter call site was already covered
  and still is.
- **The `MD_DONE_MUTE` self-test pinned an exact tier** (0.05 per channel) when the true dual-theme
  intersection is roughly [0.232, 0.264] — 0.003 from the shipped value, so a plausible eye-tune (0.30)
  already failed it with a message that said nothing about the constant being tunable. Reframed as
  direction/ordering assertions (mutes strictly toward the page, lands in the ballpark of `Text_Muted`,
  widened and explicitly labelled as bounding a placeholder) plus a new assertion on the PLAIN prose run
  specifically, which is the one the double-mute bug actually broke and the old test never reached.
- **The checkbox tick could leave a sub-pixel gap along its diagonal** (spacing `span/(steps-1)` came out
  to 1.15px against a 1px square) and, at a small enough box (`bs < 4·st`), **could escape the box
  entirely** (`arm` exceeding `bs`). Both fixed in `md_tick_quads`; the escape case is now in mdtest too.
- **Two `quads_draw` calls per done checkbox** (border, then tick) merged into one instance list and one
  call.
- **`md_front_matter_end`'s fence check read a shorter buffer (512B) than `markdown_draw`'s own**
  (`RENDER_LINE_CAP`, 8192B), so a line that trims to `` --- `` within the short buffer but not in full
  would be a fence to one and a plain row to the other, oversizing the card. Both now read the same
  amount.

**Placeholders, still awaiting Wyatt's eye** (unchanged from Task 11/13's own landing, restated here since
this is the entry that was owed): `MD_DONE_MUTE` and the front-matter card's surface/radius/inset are
first drafts, not tuned values — see their doc comments in `markdown.odin`. **The specific question for
the next live pass:** Wyatt's original report on front matter was "I don't know what this is supposed to
look like... it shows as muted, **I see the start and end `---`**, and I see like a quote bar on the side
but it's thinner" (`docs/live-pass-v0.27.0.md`). The card fix intentionally removes those visible `---`
delimiters — the card IS the delimiter now, per UI spec 9.2. Confirm that's what he meant, not just "stop
drawing the quote bar."

## 6ar. The live pass, finished (2026-07-29, v0.29.0, branch `fix/live-pass-0.27`)

The remaining thirteen of Wyatt's seventeen. Per-task detail for tasks 1–3 and 10–13 is in §6aq; this
section is the batch as a whole and the cross-cutting findings a per-task review structurally could not
see. Wyatt was asleep for most of it, having granted control to finish and continue.

### The defects he reported, and what they actually were

Four of the thirteen were not what the report or the plan said they were, and finding that out was worth
more than the fixes:

- **The vertical scrollbar stopping at 80%** was the thumb mapped against `doc.pt.length` instead of the
  scrollable range. `doc.top` peaks at `doc_max_top`, never the file length, so the thumb fell short by
  exactly the visible fraction of the file. The real defect was in `doc_scroll_to_fraction`, not
  `vbar_drag_to` where the plan pointed.
- **"Ctrl+H has no replace all"** — Replace All *existed* and was **dead code**. It hung off `ev.ctrl`
  inside `.Find_Confirm`, but `lookup_binding` matches `(key, ctrl, alt, ctx)` exactly and every `.Enter`
  row is `ctrl=false`, so the branch was unreachable from every route. The symptom is fully explained.
- **"The first `>` is green"** was not the table-separator role drift the plan suspected; `lex_markdown`
  tokenised only the first marker. And `Md_Quote` is unreachable from a lexer at all — it is a
  program-layer `Color_Role`, and lexers emit `Token_Kind`.
- **Tabs appearing mid-rail** was `app_add` reusing the first nil slot. The plan's premise that session
  restore stored slot indices was wrong — it already stored display order — but restore was still a
  second route, by *persisting and re-serving* a scrambled order.

### Found on the way, unreported by anyone

- **Replace All corrupted the buffer while reporting success.** `"aa"` over `"aaaa"` publishes three
  overlapping matches for four bytes; the loop applied all three, each splicing into what the last had
  written, producing `"b"` instead of `"bb"` — and returning 3. A wrong document with a plausible count
  is the worst combination there is. `find_keep_set` now takes the leftmost non-overlapping subset.
- **The link resolve-gate introduced a content-triggered denial of service.** Gating decoration on
  `link_resolve` put a `stat` on the frame path — up to three times per frame while Ctrl is merely held.
  A single dead UNC path in a pasted stack trace froze the UI thread for **over 100 seconds**, measured.
  Ctrl is held during Ctrl+S, so the unsaved buffer was held hostage. `watch.odin`'s own header records
  why: "the main thread must never block on the filesystem." Fixed by refusing non-local targets without
  any filesystem call.
- **The silent no-op on link activation existed at three sites**, not the one the plan named — the
  editor, the table view's Ctrl+click, and the `Open_Link` palette command. Neither of the latter two has
  a decoration gate, so Wyatt's report may well have come from there.
- **A done task item's prose was muted twice**, dropping contrast to 3.58:1 Dark and 3.28:1 Light —
  under the 4.5 floor every text role in `theme.odin` is annotated against.

### What this batch got wrong, and it is the same thing eight times

**The plan's draft test code was wrong in every single task.** Not occasionally — every one. The shapes:

- measured an **empty list** (a device-less `Text` reports its atlas full, so nothing was recorded and
  "all positions are integral" was vacuously true);
- asserted **integrality** when the bug was a 1px shift *between* integers;
- **subtracted the same global** production added, so a wrong value cancelled out of both sides;
- asserted a property **the bug also satisfies**;
- used a tolerance **loose enough to admit the defect** (1px, where the error was 0.34px);
- was verified only by **the number the function chose to report**;
- **would not have compiled** — six of seven procedure names in one task did not exist;
- and **would have failed a correct implementation** (an arithmetic error in the controller's own
  derivation of `MD_DONE_MUTE`: the real factors are 0.298/0.220, not 0.28/0.24).

Two survived to the whole-branch review and were caught only there: `mdtest` could not reject the
done-item colour defect, and `tabseamtest` could not reject the tab-gap defect — **the exact bugs Wyatt
reported, reintroducible with the whole suite green.** Worse, HANDOFF affirmatively claimed the coverage
existed. Both are fixed and both now bite under sabotage.

**The operational lesson, stated so the next session can use it:** "write a test" is not the discipline.
The discipline is *ask what value this assertion would reject*, and then prove it by reintroducing the
bug. Six of the eight above pass that question trivially once it is asked out loud.

### Also worth knowing

- **The plan cited four test modes that do not exist** (`seltest`, `keytest`, `scrollbartest`,
  `tablayouttest`). `seltest` fell through to the GUI path, opened a window, and locked the exe against
  the next build. List them with
  `grep -o 'os.args\[1\] == "[a-z]*"' src/program/test_modes.odin | sort -u`.
- **A headless-GPU markdown test now exists.** `md_draw_selftest` drives `markdown_draw` through
  `Headless_Gpu` + `gfx_readback_bgra` and samples pixels. That closes a class of blindness the project
  carried for two batches, and it is reusable — the fence-seed coverage gap §6aq lists as owed can now be
  closed with it rather than carried further. **That is the highest-value follow-up on the list.**
- **Task 16 correctly produced no code.** The encoding dropdown's width was measured against its own
  longest row and they match; the labels are simply long. "No defect, here are the numbers" is a
  successful outcome.

### Owed (in addition to §6aq's list)

- **The batch made the `renderer`/`ui` extraction harder in five places**, none fatal, all worth having
  before that work is planned: `find_actions` is UI geometry in a program-layer file that now depends on
  `UI_SCALE`, the text metrics, the keymap *and* document state at once; `vscrollbar_geo` stopped being
  arithmetic and became a document query (it walks the piece tree); `doc_max_hscroll` writes to the
  `Document` from the draw path, so the draw is no longer idempotent; `links_layout` performs filesystem
  I/O and owns a process-global cache, and the draw calls it; and `render_frame` now queries the live OS
  cursor inside the draw for a hover fill, against "events queue to the frame arena".
- **The front-matter card is a third consumer of the no-scissor cover strip.** Measured at 2170px tall
  for a 60-line block, drawn as one unclipped quad. A real scissor facility is its own renderer task.
- **`Replace All`'s Edit-menu row draws enabled and no-ops in table view and full Preview.** `item_enabled`
  consults `command_allowed_on` but not `doc_read_only_view`. Pre-existing pattern (`.Paste` has it too),
  but it is the same defect Task 15 deliberately fixed for the buttons, in the same commit that added the
  row.
- **Literal `$1` in a regex replacement writes the characters `$1`.** Pinned by a test so it cannot change
  silently, but Replace All made it far more reachable — it now has a key, a palette entry and a button.
  Product call for Wyatt.
- **`replace_sel_raw` does not clamp its range**, unlike `doc_replace_range`. Pre-existing and shared with
  `find_replace_current`, but making `find_replace_all` reachable widens the blast radius from one splice
  to many.

## 6as. The regressions the live pass created, and regex to a standard (2026-07-29, v0.30.0, branch `fix/live-pass-regressions`)

Five defects v0.28.0/v0.29.0 introduced or made reachable, plus one feature Wyatt asked for by name:
*"fix the bugs these generated that you mentioned… regex should be true to a standard."*
Spec: [2026-07-29-live-pass-regressions-design.md](docs/superpowers/specs/2026-07-29-live-pass-regressions-design.md).

### Regex replacement now implements the .NET / JavaScript substitution standard

`$1`–`$9`, `${n}`, `$0`/`$&`, `$$`. The standard was chosen because the find bar already matches VS Code
deliberately — Wyatt picked all-Alt toggles for that reason — so a user who knows one knows the other.

**Two things made this much harder than it looks, and both are worth knowing before touching it.**

**Odin's `regex.Capture` compacts unset groups out and silently renumbers everything after them.** With
`x(y)?(z)`, `pos[1]` is group 2. All three capture-building paths in the stdlib `continue` past every
unset pair and pack. There is no way to recover true numbering through the public API, so **Newtpad
drives the regex VM directly**. That couples us to non-public stdlib internals: a signature change
breaks the build (fine), but a *semantic* change to the `saved` layout would be silent. The `${9}` and
`\B` tests are the guard.

**The engine cannot anchor a match at an offset** — the compiler injects a forward scan and
`Assert_Start` is literally `sp == 0`. Captures are therefore recovered by re-matching over a window read
from the piece table, then **verifying the re-match reproduces the published span**. The window carries
one byte of left context (what `\b`/`\B` need) and runs to and *including* the line's newline (what `$`
needs).

**That last clause was a shipped data-loss bug for one commit.** Excluding the newline made `Assert_End`
true at every ordinary line end where the scan, over a 256 KB block, had it false. `/(a)$|(a)/` wrote the
wrong group on every line, and `/(ab)$|(a)/` fell back to empty groups and **deleted the captured text
from the document**. The span check does not save you: it accepts any *route* to the same span,
including a different alternation branch with different groups.

**Owed:** `$` is still window-relative on a line longer than `REGEX_SUBST_TAIL` (64 bytes past the match).
Bounded — verification rejects, groups go empty, `$0`/`$&` stay correct, no wrong bytes — but real. `^`
has the same shape and needs a 256 KB block boundary. A proper fix needs the engine to distinguish
end-of-window from end-of-string, which `core:text/regex` cannot express.

### The other five

- **Mutating menu rows now grey out in table view and Preview.** `item_enabled` consulted
  `command_allowed_on` but not `doc_read_only_view`, so `Replace All` painted live and no-opped — *the
  same defect the Replace All task had deliberately fixed for the buttons*, in the commit that added the
  row. `.Paste` had the identical hole; fixing the predicate fixed both.
- **The horizontal scroll range shrinks again when you delete the longest line.** The high-water mark is
  now keyed on `doc.revision`. Every revision bump is a genuine content change — nothing bumps it on a
  repaint, scroll, resize, tab switch or settings change — with one benign exception: `doc_set_line_ending`
  bumps it without changing any measured width, so LF↔CRLF momentarily collapses the range and it re-grows.
- **A non-local link now reveals in Explorer on Ctrl+click** instead of doing nothing. `explorer.exe
  /select` resolves the path in *its own process*, off our UI thread, so it costs nothing. Decoration
  stays off — we still cannot promise it will open.
- **Front matter shows its `---` delimiters again**, as muted text inside the card. Wyatt had said "i see
  the start and end `---`"; the card removed them and he was never asked. The card is `2 × line_h` taller
  for it. Still a placeholder.
- **Markdown rows are admitted against their own height**, so a heading is no longer let in against the
  body line height and then clipped through the middle of its glyphs. `md_row_geom` produces `ink` and
  `adv` once, consumed by the fit decision and the advance — the two-producers shape §6j records sixteen
  instances of.

### What this batch got wrong

**Two more tests that could not fail**, both caught only by the reviewer deleting the fix and watching
the suite stay green:

- The non-local-link fix had **no seam coverage at all** — the whole branch could be removed with
  `linktest` reporting zero failures, because the test only exercised the pure helper.
- The menu fix and its test both enumerated through **the same classifier**, so removing
  `.Find_Replace_All` from `command_mutates_doc` — the exact command the bug was reported for — broke
  nothing.

**An implementer caught themselves writing a third**, and their generalisation is the useful artifact:
*any test expression that calls the code under test is suspect.* Theirs located a row via the same
procedure that sized the card, so shrinking the card moved the expectation with it.

**A security coupling was left undocumented and is now recorded.** Dropping the stat means
`explorer_select_arg` builds `/select,"<path>"` by plain concatenation from arbitrary document text.
That is safe **only** because `is_delim` lists `"` as a token boundary, so a scanned token can never
contain a quote. Relax `is_delim` later to support quoted paths with spaces — a plausible request — and a
Ctrl+click becomes argument injection. A test now pins `"` as a delimiter.

**Process note, mine:** a sabotage experiment ended in `git checkout` on a file whose fix was still
uncommitted, and destroyed it. Commit the fix *before* verifying that removing it breaks something.

### Owed

- **Soft wrap is still not in the admit budget**, so a wrapped block at the bottom can overhang by its
  continuation rows. Affects every block kind equally. Producing that height ahead of the draw needs
  either a second walk of `md_draw_inline`'s word loop or a bound passed into it.
- **`render_frame` still mutates the `Document`** via `hscroll_model`'s `.Columns` branch and
  `md_table_ensure`. This batch removed one mutation, not the class.
- **`hscroll_model`'s `rows` parameter is unused** in the whole procedure.
- **Front-matter rows are no longer individually admitted** — the block draws whole (bounded at 64 lines)
  and the cover strip trims it on a very short pane.

## 6at. The preview stops being a monospace document, and Newtpad gets an icon (2026-07-29, v0.31.0, branch `feat/batch-17-preview`)

Batch 17: [UI spec](docs/ui-spec/newtpad-ui-spec-v1.md) §9.1's block/span/shaper model, §9.3's type scale,
§9.4's Split sync, and §16's application icon — the last of which was a **beta blocker**, since no `.ico`
existed in the tree at all. Thirty commits, all bisectable.

**The spec landed in the tree this session** (`docs/ui-spec/`). It had lived in a chat upload folder, so
batches 12–16 all cited it *secondhand* through each other's design docs and no session ever read the
source. That is how §9.3's "serif, **deliberately**" got carried forward as an unqualified "proportional
face", and how §16 stayed an unspecified TODO when it names a recommended direction and its exact
palette. Read `docs/ui-spec/README.md` before designing any UI change.

### What landed

**The preview no longer uses the character grid.** §9.1's argument is that it never needed to: the grid
exists to make caret arithmetic, column selection and hit-testing O(1), and the preview has no caret, no
selection anchor, no column and no editing. So it now has a block list, a span list per block, a real
proportional shaper, a layout cache, and a scroll offset in **pixels**.

**§9.3's type scale in full** — all seven heading sizes as `round(k * S)`, weight 700 from **real Georgia
bold** rather than the synthetic double-draw, the colour roles, body-vs-mono faces, all eleven
space-above/below values, 1.65 line height, the 72ch measure and 40px padding. Georgia because §9.3 says
serif deliberately — *"it is what separates 'document' from 'UI'"* — and because Wyatt chose not to embed
a face this batch. Source Serif 4 and Monaspace Neon ride with batch 20's in-memory font path.

**The icon: §16's "Caret on paper"**, seven sizes each drawn at its own size (the 16px and 20px variants
drop the third text line, because three 2px bars inside 16px mush), fixed warm paper in both themes
because Windows caches the icon and one that flickers looks broken.

### What this batch got wrong

**Three tasks refused to half-land work and proposed splits. Two were right, and that is the batch's best
outcome.** Task 2 was dispatched to do the whole rewrite and came back `NEEDS_CONTEXT` having found two
prerequisites nobody had scoped: `shape_run` took one face and one size per call, so §9.3's inline code
at 0.92 S mono *inside* 1.00 S prose was inexpressible — and it cannot be composed per-span, because
greedy breaking reaches **backwards** and rewrites already-placed glyphs when a word straddles a span
boundary. Separately there was no bold body face at all, so the type scale would have shipped its size
column and silently dropped its weight column. Both became task 2a.

**The whole-branch review found four blockers, and the worst was in the headline feature.** Scrolling up
inside the document's **first block** teleported to the top — 100% reproducible on any file whose first
block is taller than one wheel notch, which is any heading, any fence, any front-matter card, any
wrapping paragraph. `md_probe_back` returns `n == 0` exactly when the anchor is in block 0, and that
branch discarded the target it had just computed.

**And the assertion covering that region asserted the buggy value.** *"900px back up returns to the top
exactly (0/0.0)"* — the fixture only ever scrolled up from a position where `{0,0}` was correct. This is
the batch's sharpest lesson: **a point assertion at a convenient position is how a 100%-reproducible bug
ships.** What found it was a *sweep* — wheel reversibility over many positions and six fixtures — and the
same sweep found a second defect nobody had reported: `md_at_offset`'s clamp was inclusive, so it emitted
`px == gap + h`, a position that is really the next block's origin expressed in the previous block's
coordinates. 18–45% of wheel round-trips were not the identity, and the scrollbar could read a full block
ahead of the content.

**Ten sabotages came back green.** The review sabotaged 28 properties; 15 failed with assertions naming
the actual defect, and ten passed — among them §9.3's 72ch measure for *indented* blocks, the cover strip
without which the anchor block paints over the tab rail, `md_pane_owns`'s left bound (without which
Split's *editor* half routes to the preview), and `.Blank`'s revision key. All four now have tests. The
link seam was verified in x and **not in y**: the rect's `y` could move a pixel and the underline's
`base_y` nine, with the suite green.

**A guard that credited itself with a fix, twice.** `md_layout_slot`'s live-entry check was dead code —
LRU already provided the property — and the branch correctly found and deleted it. Then the branch's own
final commit added `md_split_click_gate`'s pane bound, which duplicated the identical predicate inside
`md_block_at_y`; removing either alone left the suite green. Deleted, and the two mis-named assertions
renamed to say what they actually test.

### Performance, measured rather than inferred

`md_preview_frac` was doing **two anchor-resolving walks inside the draw** — 1.95 ms of a 3.4 ms scroll
frame, more than `markdown_draw` itself, re-deriving geometry the draw had produced three lines earlier.
Against CLAUDE.md's *"scroll resolution must not happen inside the draw."* Now cached: **3.322 → 0.001
ms**, whole scroll frame **7.24 → 4.17 ms**.

Everything else inside budget: cold first pass 2.26 ms, warm 1.10, theme change 0.32, DPI 100→150% 0.31,
resize 0.42 per width step, edit 0.84.

### Size

Release **1,249,792** bytes against `main`'s 1,206,272 — **+43,520 (+3.6%)** for a shaper, a block model,
a layout cache, a pixel scroll model and an icon. The icon's first version was **+296 KB** on its own,
because its 256px entry was an *uncompressed* PNG — a quarter-megabyte for five rectangles, against
product principle 5. A hand-rolled DEFLATE took that entry 262 KB → 3.1 KB, and a later pass stored the
48 and 64 entries as PNG too, taking 24 KB off the branch.

### Owed

- **§9.3:** h6 caps and tracking (h6 is currently identical to h5); the *Preview font* setting §9.3 asks
  for; the caption/meta row (computed, deliberately unread).
- **§9.4:** preview selection and copy — **a silent omission, not a recorded deferral**; the heading
  tick-mark rail; the divider's `border_subtle` colour and 320px minimum pane.
- **§9.1:** the screen *below* the viewport is laid out; the screen *above* only on the scroll-up gesture.
  Disclosed and defensible — three screens per pass, three passes a frame, thrashes the cache — but not
  what §9.1 says.
- **An untagged or unknown-tag fence body draws on the proportional body face**, because the
  `fence_lex == nil` path falls through to `md_inline` whose runs carry no `.Code` style. There is no
  `odin` lexer, so most fences in this project's own docs render proportional. A product decision.
- **And a stronger suspicion worth its own task:** a fence body's slot heights came out pixel-identical
  under two font families with materially different advances, while inline code moved as expected — so
  something on the fence-body path is not advance-aware, and if so its wrap points are wrong.
- **`Md_Walk_Block.lay`'s pointer-safety argument holds only for `md_pass`**, the sole incrementer of
  `md_layout_pass`. Every `md_scroll_ctx`-based walk stamps entries with the *previous* pass id, so a full
  table can evict entries those walks hold. Safe today only because none of them dereferences `lay` — the
  first scroll-path consumer that does gets a use-after-free.
- **`MD_RUNUP_LINES :: 24` does not reliably clear front matter** (`MD_FM_MAX_LINES` is 64). Self-disclosed.
  **HANDOFF §4 Shape A, instance eight.**
- **"An edit rebuilds exactly ONE block" is fixture-specific.** Measured on the UI spec it is ~22 blocks
  per keystroke, because every `Blank`, `Table` and `Front_Matter` block keys on `doc.revision`.
- **What this added to the `renderer`/`ui` extraction debt:** `shape.odin` is three layers in one file (a
  pure line breaker, a GPU submit path that touches `g_draw`, and a DirectWrite metrics query);
  `Document.md_layout` puts a platform type permanently in the document model, ~75 KB per markdown
  document freed only by `doc_close`; `markdown.odin` went 1,113 → 3,214 lines and is now parser plus
  layout engine plus cache plus widget; `main.odin` gained four more widget procedures.
- **Links inside markdown tables are not clickable.** Disclosed, with the right reason: a table row's
  glyphs are placed in character cells, so emitting rects today means a second producer of the same
  positions — the defect this batch exists to remove. Owed: route a table row through `shape_spans`.

## 6au. The Split-resize crash, and the review that closed the gaps in the fix (2026-07-29, v0.31.1, branch `fix/split-resize-crash`)

Wyatt's daily driver: drag the right window edge in markdown Split view and Newtpad died with
`STATUS_ARRAY_BOUNDS_EXCEEDED` inside `plat.shape_spans`. §6at's shaper made every visible preview
block rebuild on every width change (`measure` is part of the `Md_Layout` cache key), and `on_resize`
ran that whole repaint on a **fixed 64 KB `mem.Arena`** over a **shared `@(static)` buffer**. Past the
arena's end `make`'s `#optional_allocator_error` drops the allocator error, the caller gets a
zero-length slice, and `shape.odin:246` indexes it. The fix — swap the fixed `mem.Arena` for a
per-invocation, growing `runtime.Arena` (`resize_temp_begin`/`resize_temp_end`, `main.odin`) — is
correct and genuinely cannot refuse short of process OOM. A review of that fix found four things
needing a fix and two claims needing correction; this entry is that review closing out.

### The test that documented the bug without preventing it

`resizetemptest` compared demand against the *old* 64 KB constant, so it would go on passing whatever
the new arena did — it never observed **growth**, the property the fix actually delivers. Proof: a
reviewer sabotage restored a fixed 256 KB `mem.Arena` over a shared `@(static)` buffer (reinstating
both original defects) and the suite stayed green. The test now also asks the allocator
`resize_temp_begin` actually produces for `RESIZE_TEMP_BLOCK + 1` bytes in one request and asserts it
succeeds — impossible on any fixed buffer, trivially true for a growing one. Sabotaged and confirmed:

```
  ok   the resize temp allocator refused nothing (0 refusals over 63 widths)
  ok   one repaint outgrows v0.31.0's fixed 64 KB arena, so 1 is not vacuous (102865 > 65536)
  ok   resize_temp_begin (growth probe) produced an allocator
  FAIL a single 262145-byte request (RESIZE_TEMP_BLOCK + 1) succeeds -- impossible on any fixed-size buffer (err=Out_Of_Memory)
resizetemptest: 1 failures
```

restored, and green again with `err=None`.

### A failed `arena_init` used to permanently desync the swapchain

`on_resize` returned before `plat.gfx_resize` whenever the arena failed to grow. v0.31.0 called
`gfx_resize` unconditionally (its `arena_init` could not fail). `window.resized` is only set
pre-callback (startup); once `main.odin` installs `on_resize`, nothing else ever re-syncs
`gfx.width`/`gfx.height` to the window. Under memory pressure, an `arena_init` failing on the *last*
`WM_SIZE` of a drag would leave the swapchain permanently mismatched with the window — content drawn
outside the viewport, hit-tests disagreeing with the draw, until the next resize that happened to
succeed. Fixed by hoisting `gfx_resize` above `resize_temp_begin`: `gfx_resize`/`gfx_create_rtv`
allocate no Odin memory, so this is free and can no longer be the thing that fails.

### A skipped test used to report success

`rt_run` returned `0` on a missing fixture or a failed `headless_gpu_init`, so the mode printed
`resizetemptest: 0 failures` with no `FAIL` token — a `Select-String -CaseSensitive "FAIL"` harness
would record that as a pass. Any machine without the fixture, or without a D3D device (RDP, CI), got a
permanent silent green on the one test guarding this crash. Same class as the fixture-below-
`SEARCH_SYNC_MAX` incident (`docs/development-loop.md` §3). **Decision: a skip now fails loudly rather
than passing silently** — both skip paths route through `rchk` with `ok=false`, so they print `FAIL
... UNVERIFIED` and count against `bad`. Verified from a directory without the fixture:

```
resizetemptest:
  FAIL could not open fixture -- resize regression UNVERIFIED (run from the repo root)
resizetemptest: 1 failures
```

### Two claims the review corrected

**The "one block" sizing claim was wrong.** `RESIZE_TEMP_BLOCK`'s comment said 256 KB covers "the
measured 100.5 KB preview plus the rest of the frame in one block." Measured at a realistic pane
height (the shipped harness pins pane height 900 and `UI_SCALE` 1, which cannot see this): the preview
alone asks for **174.7 KB at 2100px** and **210.7 KB at 3200px**. The rest of the frame draws out of
the same arena *before* the preview does, so the common case takes a **second** block, not one — 1–2
mallocs per resize frame. The judgment call holds regardless: `arena_init(256 KB)` + `arena_destroy`
measures **3.31 µs/frame** steady state (**6.41 µs** when a second block is taken) against 16,666 µs
at 60 Hz — 0.02–0.04% of budget either way. Comment corrected in `main.odin`.

**The "independent use-after-free from re-entrant `on_resize`" claim was not demonstrated.** The old
comment stated as fact that a DPI change resizes the window from inside `on_dpi`, causing `WM_SIZE` to
arrive nested with an outer `on_resize` still on the stack, and cited a comment line as if it were
code proving it. It is not: `on_dpi` only calls `metrics_recompute` and `text_reset_atlas`; the
`SetWindowPos` that actually resizes lives in `window.odin`'s `WM_DPICHANGED` handler and runs *after*
`on_dpi` returns — so the real sequence is `WM_DPICHANGED → on_dpi (returns) → WM_SIZE → one
on_resize`, not a nested one. The only message pump is `window_pump_events`, called only from the main
loop, never from inside `render_frame`. A fault-stack review found exactly one `on_resize` frame. The
aliasing bug in the old shared-`@(static)`-buffer design was real, and removing the static buffer
closes it regardless of reachability — but the comment now says what is actually known: a closed
latent defect, not a demonstrated crash mechanism. Hedged in `main.odin`.

### The three trap sites, and what removing the static buffer changed about them

All three ultimately trace to the same shape — an unchecked `make` past the arena's end returning a
zero-length slice that the next line indexes — but they are not identical:

1. `shape.odin:246` — the shipped crash. Indexes a `Span_Metrics` array built from an unchecked `make`.
2. `shape.odin:397` — indexes `boxes`, which is allocated on the **caller-supplied** `allocator`
   parameter to `shape_spans`, not a stray temp `make` inside `shape.odin` itself. Same shape, different
   producer: whoever calls `shape_spans` with a resize-scoped temp allocator and then dereferences the
   result owns this one.
3. `markdown.odin:2154` — `plat.shape_run`'s **persistent** allocator argument is passed
   `context.temp_allocator`, so a `Shaped`'s `glyphs`/`line_boxes` land on the resize arena. Benign
   today (only `.line_h` is read), documented in place as the adjacent footgun it is.

**A new invariant the growing arena creates, and nothing enforces it:** `resize_temp_end` calls
`arena_destroy`, which returns the block to the **heap** — unlike the old shared `@(static)` buffer,
which stayed mapped for the process's life. Any pointer that escapes a resize repaint's temp arena and
is dereferenced later is now a **real** use-after-free (freed, unmapped memory), not a stale-but-
readable value. Clear today — `Md_Layout`'s persisted fields are all on `context.allocator` and
`md_layout_free` deletes them through it — but it is load-bearing and audit-only. Documented at the
markdown.odin:2154 site.

### The systemic residual, unfixed on purpose

This batch fixed the resize path's OWN arena. It did not fix the shape everywhere: roughly 274 `make`
calls across the tree run on `context.temp_allocator` with `#optional_allocator_error` silently
discarding the result, unchecked. A genuine process-level OOM anywhere else in the frame still becomes
a bounds trap identical in kind to the one this batch fixed — this batch narrowed the blast radius of
*this* crash to zero, not the class of crash. Added to the §5 debt register.

### Amending CLAUDE.md's Memory row

The Memory row says *"Build arenas only if a measurement asks for them, and amend this row again when
you do."* v0.31.0's fixed `mem.Arena` was itself an unamended arena that row would have forbidden —
nobody amended it then, and that arena is what shipped the crash. `resize_temp_begin` needs its own
arena because it must not share the main loop's: an outer frame may be mid-way through that one when
`WM_SIZE` arrives. Measured (above): 174.7–210.7 KB real demand, 3.31–6.41 µs/frame cost. Amended in
CLAUDE.md (gitignored — will not appear in this commit).

### Owed

- **The 274-unchecked-`make` exposure** (above) — added to §5.
- **`markdown.odin:2154`'s temp-allocator-as-persistent-allocator footgun** — documented in place, not
  fixed; added to §5.
- **The persisted-temp-pointer use-after-free invariant** the growing arena introduces — documented in
  place, not enforced by anything; added to §5.

## 6av. Four live-use defects in the new preview (2026-07-30, v0.32.0, branch `fix/preview-partial-blocks`)

Wyatt's first real pass over batch 17's preview, all four reported with screenshots. Spec:
[2026-07-29-preview-partial-blocks-design.md](docs/superpowers/specs/2026-07-29-preview-partial-blocks-design.md).

### What broke, and why each was invisible to the suite

**A block that did not fit was refused whole, so the pane showed emptiness.** A heading rendered, then
~200px of blank; expanding the window **one pixel** made the entire following paragraph appear. Blocks
were atomic because `md_block_fits`'s own comment says *"there is no scissor rect in this renderer… so
the only way a block is not cut through the middle of its glyphs is for it not to be ADMITTED."* True for
a one-line heading; wrong for a paragraph of N shaped lines, and a violation of CLAUDE.md's *"No frame
ever shows emptiness."* The pre-batch-17 renderer admitted per source line and simply stopped
mid-paragraph. Now it admits per shaped line, which the shaper already had the boxes for.

**Preview tables ignored the measure entirely** and ran off the pane edge, because `md_layout_build`'s
`case .Table` returned *before* the span-building section — so a table got no spans, no shaping, and
nothing in its path knew the measure existed. Cells now wrap inside columns fitted to the measure, and a
row's height is its tallest cell.

**Clicking the preview in Split shifted the editor.** That was §9.1's click-to-sync working as designed;
**binding it to a plain single press was the defect.** A single click is how people focus a pane. Moved to
a double press. `mouse_count` turned out to be the *press index* within a double-click cluster, wrapping
3→1 — not a gesture count.

**"It's not respecting the spaces all the time"** was **none of the three things it looked like.** Runs of
spaces do not collapse (the preview is *more* literal than CommonMark), indentation is preserved, and the
shaper drops nothing — 0 space drops across 175 blocks. The real cause: `md_table_cols` was fed
`text_char_width`, which rounds the mono advance to a whole pixel **for the editor's grid**, while table
cells are laid out by the proportional shaper at the font's *real* advance. 8.0000 against 8.2471 at 16px,
so every table cell at its natural width broke at its last space and dropped a word onto a second line.
**The rounding error changes sign with document size** — which is exactly why `mdtest`'s `px_=24` table
sections were all green while the shipped 16px default was broken. The new test sweeps sizes and asserts
its own precondition that the sweep covers the broken side.

### Found on the way

**An `_` inside a word opened emphasis and ate itself.** `(stb_sprintf aside)` drew as
`(stbsprintf aside)` and italicised the rest of the block. CommonMark specifies that `_` cannot open or
close emphasis intraword — the asymmetry with `*` exists so identifiers survive — and this repo's own docs
are full of snake_case. Fixed with a flanking test at the two `_` branches.

### What this batch got wrong

**A guard was armed for a predicted failure, and it fired.** Batch 17's review found that
`md_kind_lines`' divisible set had to be *exactly* the kinds reaching `shaped_draw`, with nothing
enforcing it, and predicted the failure verbatim: shaping table cells would make `.Table` reach
`shaped_draw`, and if it were not simultaneously added to the divisible side a wrapped table would
**silently render one line** while `mdtabletest` stayed green. A deferred panic was added for exactly that.
The tables task then hit it. **This is the first time a predicted-and-guarded failure was caught by its own
guard rather than by a user** — worth repeating as a technique.

**Two more vacuous tests, both proven by sabotage rather than argument.** The per-line task shipped a
thumb that pinned at its 24px floor for the whole traversal of a paragraph taller than the pane and then
snapped — nothing in the suite read `thumb_h`. And the tables task's entire column-alignment section
rejected nothing: neither fixture row actually wrapped, so the assertion reading *"though one row's other
cell wraps"* compared two identical one-line rows, and a real "columns don't align" sabotage passed green.
**That is eight batches in a row where the draft test code was wrong**, and the recurring shape is the
same: an assertion whose fixture does not reach the condition it names.

**A report claimed a perf fixture change was reverted when it was not**, so a published baseline moved
silently. `mdperftest` also had no threshold at all — it printed and unconditionally reported `0 failures`.
It has one now.

### Owed

- **§9.2 item 6 asks for zebra rows in the preview table.** Still unimplemented, and the tables work
  doubled down on per-column rules instead. Pre-existing, not introduced here.
- **The oversize table fallback drops real columns as a first resort** — a >1 MB table is bounded to 4
  columns at 16 cells, while the measured path squeezes toward 1 cell before dropping anything. The cheap
  honest fix keeps the O(1) property: scan the entry row for its own cell count so the count is not
  invented.
- ~~**`md_link_at` has no y bound**, and neither call site applies one, so a `forced` oversized block's
  link rects stay clickable past the status bar.~~ **FIXED** in batch 18. `md_preview_link_at`
  (`markdown.odin`) is now the one entry point for both the hand cursor and the Ctrl+click, and the
  bound is inside it, applied to the POINT rather than to the rectangles — one bound, and a straddling
  rect keeps exactly its visible half clickable. Bounding the rects in `markdown_links` was rejected:
  it needs the pane box in a second place, and it would make `mdtest`'s partial-admission sweep pass
  by construction (its "no drawn line's bottom exceeds `ybot`" is only a real assertion while that
  producer still reports overflow). Covered by `mdtest`'s `md_link_bound_selftest`, which measures the
  overflow before probing it.
- **Every source line is its own `.Para`**, so two adjacent prose lines look like two paragraphs.
  CommonMark joins them with a space at the break. **A design question, not a bug** — and the one remaining
  reading of Wyatt's "spaces" report if the table fix turns out not to be what he saw.
- **The intraword fix is a per-delimiter open/close test, not a delimiter stack.** An unmatched `_` opener
  still leaks italics to the end of the block — the same pre-existing gap `*` has.
- Partial table admission is correct but untested; `mdtabletest` still cannot fail for any
  table-*rendering* reason at all.

## 6aw. The table view's appearance, and three data paths that wrote to the wrong place (2026-07-30, v0.33.0, branch `feat/batch-18-table-view`)

**Batch 18 is partial and shipped anyway**, on Wyatt's call, because one of the defects in it modified
files. Spec: [2026-07-30-batch-18-table-view-design.md](docs/superpowers/specs/2026-07-30-batch-18-table-view-design.md).
Tasks 1–2 of six are done; row numbers, column fit, numeric alignment, sort, malformed-row marking and
the summary row are still owed, along with §15's empty tab and §8's editor details.

### The table view got §10's appearance

Wyatt asked directly whether the CSV work had shipped. It had not — the view had cell machinery, editing
and links, but none of §10's treatment.

**A `table_zebra` colour role had to exist first.** `grep Table src/program/theme.odin` returned nothing,
and §10's central claim is *"Column rules are gone. `table_zebra` carries the eye instead."* Then: column
rules deleted in favour of zebra banding (§10 — a line per column is *"8 extra quads per screen and it
makes the grid louder than the data"*), an em dash in empty cells so a blank column stops reading as
broken parsing, a real sticky header (`bg_raised` + a 1px `border_strong` rule), and §10's metrics —
header 30px, rows 26px, padding `0 10`.

**§10 was overruled on one colour, deliberately.** It names `text_dim` for the em dash, but `theme.odin`
labels that role "DISABLED ONLY — never live text" at 2.8:1, below the AA floor, and §18 justifies the
exemption as WCAG's *disabled-control* exemption. The em dash is live content whose entire job is
distinguishing "empty, and we parsed it" from "missing". `Text_Muted` (4.9/5.4) instead. **That one
decision also covers §10's row-number gutter and §15's empty-tab hints** — recorded in §5 so it can be
overturned in one place rather than three.

### Three data paths that wrote to the wrong place

**The find and filter bars were writing into the document.** Wyatt reported `Ctrl+V` pasting into the
viewport, unremovable while the bar had focus. The hole was `resolve_key`'s `.Find` → `.Editor` fallback
for **every** Ctrl/Alt chord, so `Ctrl+X`, `Ctrl+Z`, `Ctrl+Y`, `Ctrl+Backspace` and `Alt+Up/Down` wrote
too — and since the filter bar *is* the find bar, plain Find and Replace had the same hole. **The document
did become `modified`**: dirty tab, save prompt, no undo without closing the bar, with `pt.length`
measured walking 18 → 6 → 18 → 6 → 0 across six writers. Fixed at the context resolution, so the class
rather than the instance. Full detail in §5.

**A cell edit that scrolled off its own row wrote to the wrong line.** `doc.table_edit_row` is a *visible*
index while `table_edit_s/e` are absolute bytes captured at edit start. Seven scroll routes existed and
only two committed the edit. One per-frame guard now asks the seam directly rather than adding a commit
to each route — the resize is not a scroll route at all and would have been missed again.

**Link rects below the pane were invisible but clickable.** `md_link_at` had no y bound and neither call
site applied one, so Ctrl+clicking the status bar could open a link the user could not see.

### What this batch got wrong

**A guard shipped that could not do the job its own HANDOFF entry claimed.** The cell-edit anchor compared
byte *offsets*, so permuting equal-length lines — a fixed-width CSV with zero-padded IDs, ISO dates and
fixed status codes, which is what exports look like — left the r-th line starting at the same offset. The
guard passes and the edit writes onto the wrong row. **Not reachable today because no sort exists: it was
a trap laid precisely for the task that builds the sort, in the entry that task would read.** Now anchored
to the line's own bytes, and `table_edit_commit` refuses a stale span rather than committing it. A
generation counter was rejected because the sort's author has to remember to bump it — the exact class of
miss the one-guard design closes.

**A mode whose assertions could not fail, running nowhere.** `keytest` had the find-bar hole *asserted as
correct behaviour*, and its `key_chk` neither counted failures nor set an exit code — so it printed `FAIL`
and exited 0. It was also a two-argument mode, so no sweep ran it. All three fixed. The question it
raises is the useful one: **what else does the suite pin that nobody decided?**

**Two more tests that rejected nothing**, both proven by sabotage rather than argument: the grid had two y
producers — `table_row_rect_y` for the band, `table_row_baseline_y` for the glyphs — and `tablegridtest`
probed only the band, so a **full-row** divergence between drawn and clickable passed every suite. And
§10's colours, the rule's thickness and the band's parity were entirely unasserted; changing all three at
once left everything green. **That is nine batches running where the draft test code was wrong**, and the
shape is the same every time: an assertion whose fixture never reaches the condition it names.

**Page Down in the grid scrolled backwards.** `doc_scroll_rows` was introduced because "three things have
to hold the same number." There were four; the page keys got the editor's count.

### Owed

- **Batch 18 tasks 3–6:** row numbers, column fit, numeric right-align, header resize; then sort,
  malformed-row marking and the summary row; then §15's empty tab and §8's editor details (of which the
  caret blink is the one item with a non-obvious interaction — it needs a wakeup the frame loop schedules).
- **Zebra parity is viewport-anchored**, so bands invert on an odd-row scroll. Parity needs one *bit*, not
  a count, and should ride on whatever group B decides for the row-number gutter's absolute index.
- **The sort inherits two constraints nothing enforces:** keystrokes are dropped on a reorder (a UX
  decision worth making deliberately rather than inheriting), and `Sort_Lines` is still refused in table
  view by `doc_read_only_view && command_mutates_doc`, so enabling it means loosening that guard.
- **`keytest`, `palettetest`, `lineidxtest` and `resavetest` exit non-zero; nothing else does** — notably
  not `tablegridtest`, which asserts a hundred things about a data-loss seam and still only prints them.
  Correct in each case that has one, but the suite's failure signalling is inconsistent and a sweep that
  greps for `FAIL` case-insensitively matches "0 failures"; worth deciding once for all modes.
- Two asymmetries left by the find-bar fix: `Alt+Shift+Left/Right` still extends a column rectangle from
  the find bar while `Alt+Shift+Up/Down` no longer does, and `Ctrl+C`/`Ctrl+A` still act on the document.
- `find_paste` truncates silently at 1024 bytes — defensible for a one-row query field, but nobody was
  asked.

## 6ax. The rest of the table view, and the index that three features were waiting on (2026-07-31, v0.34.0, branch `feat/batch-18-rest`)

Batch 18 finished — §10 groups B and C — plus three of the four queued bugs and the exe's missing
version resource. 34 commits. Plan:
[2026-07-31-batch-18-rest.md](docs/superpowers/plans/2026-07-31-batch-18-rest.md). Wyatt's scope call
kept §15's empty tab and §8's editor details owed.

### The blocker nobody had named: there was no absolute row index

Three separate §10 rules were unbuilt for the same reason, and `table.odin` said so in its own words —
zebra parity rode the *visible* row index because *"a data row's absolute index is not knowable without
counting newlines from byte 0, which is unbounded on a multi-GB CSV"*. Row numbers need it, the sort
needs it to enumerate rows at all, and §6aw had already deferred parity to *"whatever group B decides
for the row-number gutter's absolute index"*. `Line_Index` walked every newline on a worker thread and
published **only a total**.

So the first task was §14's owed sparse index, which `requested-features.md` had listed as two-thirds
built: checkpoints every 64 KiB plus `doc_line_no_at(at) -> (line_no, exact)`, bounded by a binary
search plus one stride of forward scanning.

**The plan specified a 4096-*line* stride and was wrong.** A line stride makes the array's size
unknowable up front, forcing a `[dynamic]` the worker grows — **which reallocates and frees the backing
store under a reader mid-lookup**, and no amount of ordering the published count fixes a moved base
pointer. A byte stride makes the size exact, so it is allocated once before the worker exists. Worth
recording because the plan was reviewed and shipped that defect anyway; the implementer caught it.

### The gutter blanked after every save, and that was not acceptable

The first version gated on an `edit_floor` that only ever *falls*, and `doc_save` does not restart the
index — so editing one cell near the top of a CSV blanked every row number below it and **saving did
not bring them back**. Wyatt rejected it directly.

The root cause is a coordinate-space split: checkpoints record `(offset, line_no)` in the **original
file's** coordinates while `doc_line_no_at` is asked in **document** offsets, and those coincide only
while the document is unedited. A save writes bytes to disk and reconciles nothing.

The fix is a second mode. Before the worker is `done`, the old scheme byte-for-byte. After, the array
moves into **document coordinates** and is repaired on every edit — shift the entries above, compact
out the destroyed, leave `offset <= at` alone — found by binary search and bounded by an explicit
`CKPT_SCAN_CAP`. Undo, redo and history-jump carry a cloned array on the `Snapshot`; every other
tree-swapping path routes through `doc_index_start`, which clears the flag. **Ten such paths were
enumerated by grep, not by memory**, because a missed one returns a confidently wrong line number
rather than a blank. Cost: 4.99 ns/entry, ~5 µs per edit at 64 MB.

### What group C got right, and the bug the enumeration found

The sort is a permutation over row offsets landing in `table_row_start` **and nowhere else**. The draw
no longer walks lines itself — it takes row 0 from the producer and steps with `table_row_next`, which
*is* that producer's own step, so "what is drawn == what is clickable" is construction rather than two
walks agreeing. `doc.top` stays a real byte offset in every mode, which is what leaves the edit anchor,
view exit, session and find jumps working untouched.

**Walking the consumer list found a real bug that no test had.** `table_abs_rows` built a *run* of
consecutive line numbers from a single lookup — correct only while visible rows are consecutive lines.
Under a sort the gutter would have printed 1 2 3 4 5 over lines 5 1 3 2 4, with the zebra parity
following it. That is the whole argument for the enumeration being a required step and not a
formality.

### What this batch got wrong

**The sort's ceiling was a round number pretending to be a measurement.** `TABLE_SORT_MAX` was
1,000,000 and the comment claimed that was *"where a synchronous build stops being instant"*. Measured:
**2,046 ms at `-o:speed`**. A two-second stall on a header click is not a slow feature, it is a hung
window, and product principle 1 does not exempt a click on a column header. Now 100,000, which measures
285 ms — **and the number is in the comment, so the next person to raise it has to argue with a
measurement instead of a vibe.** The refusal test spelled the old ceiling out as a literal and went red
on a change it should have had no opinion about; it now parses the number back out of the message and
compares it to the constant, which is strictly stronger — a literal cannot tell "the ceiling changed"
from "the message stopped naming a ceiling at all".

**The row-number gutter shipped an eighth instance of Shape A and the whole-branch review caught it.**
`table_abs_rows` asserted *"visible rows are consecutive lines by construction"*. False:
`pt_line_end_cap` returns a synthetic break at `RENDER_LINE_CAP`, so a CSV row over 8 KB — a
description or JSON column, not an exotic file — becomes several visible rows, and every row below it
was numbered wrongly **with `exact = true`**, in the one procedure whose second result exists to
prevent exactly that. `table_row_next` now reports whether the step was a real newline, and
continuation rows land as `TABLE_ABS_NONE`. The same byte peek exposed a smaller pre-existing defect:
the step returned `e + 1` at a synthetic break, swallowing one content byte per 8 KiB.

**`Ctrl+T` off did not clear the sort, while a comment nearby said it did.** `leave_table_view` clears
it with a written policy — *"the sort is a property of the VIEW"* — and `.Toggle_Table`'s own
off-branch cleared the column widths, called `table_user_widths_clear`, and stopped. So the sort
silently reappeared on the next toggle, and worse, `table_sort_shift` gates on `s.col` rather than on
`doc.table`, so a document that had *once* been in the grid ran an O(rows) pass per keystroke **in the
plain text editor**. The fix also found a third leave path the review had not named (`doc_view_apply`).

**Roughly ten assertions across this branch could not fail**, most of them in freshly written test
code, and three separate agents caught their *own* vacuous sabotages — one used a scope-scoped `defer`
that ran before the mutation it was meant to sabotage; one asserted a substring that matched the
original line inside the damaged one; one wrote a "no sort in the summary" check that stayed green
because a stale refusal clause hid the stale sort. That is ten consecutive batches in which draft test
code was wrong, and the shape has not changed: **an assertion whose fixture never reaches the condition
it names.**

### Also landed

- **The exe had no version resource at all** — empty `FileVersion`, `CompanyName`, `ProductName`,
  `FileDescription` on every build ever shipped. Generated from `NEWTPAD_VERSION` so a bump still
  touches one file, with `version.odin` added to `res-stale.ps1`'s sources, and `release.ps1` now
  refuses to tag when the built exe's `FileVersion` disagrees with the version it derived. Context in
  §5: a GitHub download failed with "Virus detected" and VirusTotal returned **1 of ~40**, Microsoft's
  `Wacatac.B!ml`, while every other ML engine on the panel returned clean.
- **`command_named`** — palette/menu/status-bar/find-bar dispatch passes a zero `Key_Event`, so two
  `Block_Extend` rows that gate on `ev.shift` were listed, matched, highlighted, run, and did nothing.
  Fixed at the class: a modifier gate written to preserve a *bare chord* must not apply to an
  invocation the user named.
- **The watcher cap.** `MAX_TABS :: 32` was the watcher's budget and its own comment had to say so
  because the name claimed otherwise. Now `WATCH_MAX :: 64` in `watch.odin`, and **the active document
  is published first regardless of slot** — a cap has to fall somewhere but not on the buffer the user
  is about to save over.
- **Four modes given real exit codes** (`palettetest`, `lineidxtest`, `resavetest`, `tablegridtest`),
  and `resavetest`/`watchtest` made one-argument. `palettetest` printed `FAIL` from four places and
  exited 0 from all of them.

### Owed

- **A live pass on the mouse work.** `table_edge_at`, `table_col_resize`, `table_col_fit` and the
  `Drag_Latches` entry are all tested directly, but the drag/double-click/cursor wiring in `main.odin`
  is verified **by reading source only** — this environment cannot inject GUI input. Also worth a look:
  a CSV whose first data row has a >8 KB field (the tail row should show no number, rows below should
  read correctly), and edit → save → gutter.
- **`Ctrl+A` trailing blank rows is investigated and decided but not built.** Measured: the rows are
  real bytes. Wyatt's three decisions are in `docs/reported-bugs.md`, along with the two constraints
  that will otherwise be missed — the rule is row-aware rather than a whitespace trim, and the backward
  scan needs a cap or it freezes on a huge blank tail.
- **The `renderer`/`ui` extraction got measurably harder.** `doc.odin` → `table.odin` went from **1 call
  site to 8**, all pointing upward under the planned boundary; the sharpest is `pt_edit_replace` →
  `table_sort_shift`, the buffer-write primitive now calling into a view module beside `ckpt_repair` and
  `bookmarks_shift_replace`. This was the right call here — "hook the one procedure nothing can avoid"
  is why the sort's lifetime is correct by construction — but **design the observer list before
  extracting, not during.**
- A growing log's tail loses its row numbers past `CKPT_SCAN_CAP`: `ckpt_repair` shifts and compacts but
  never *adds* a checkpoint, so an append over 128 KiB outruns the scan. It refuses rather than guessing.
- `Replace All` pays the checkpoint repair per match (~0.4 s for 10k matches on 512 MB, **estimated, not
  measured** — the one number on the branch that is arithmetic).
- `table_byte_at` is a **third** copy of the same three-line byte peek (`doc.odin`'s `byte_at`,
  `block.odin`'s `block_byte_at`). Promote one to `base`.
- HANDOFF §7's mode list is materially incomplete against the ~80 modes actually dispatched.
- The zebra parity on a continuation row falls back to `r % 2`, so a split row can band oddly.

## 6ay. The first live pass on the table view (2026-07-31, v0.34.1, branch `fix/table-live-pass-0.34`)

Wyatt found four defects within an hour of v0.34.0 installing. **Two of them were not what they looked
like, and that is the useful part of this entry.**

**The column stretching was §10 working exactly as written.** *"Distribute leftover width
proportionally"* is implemented faithfully in `table_leftover_cells`, and on a wide window it hands the
spare width to the columns — making a 10-character date column ~400px. Nothing was broken. **Wyatt
overruled §10 on live evidence:** columns now default to their content width and the leftover is not
distributed at all, with drag-to-resize and double-click-to-fit unchanged as the override. The
deviation is recorded in the code in `TABLE_EMPTY_CELL`'s style so an audit does not restore it.
`table_leftover_cells` was deleted rather than left uncalled — a dead procedure whose comments describe
a rule the file no longer follows is worse than no procedure.

**The sort reset already existed.** `table_sort_click` has always cycled ascending → descending → the
file's own order. The defect was that nothing said so. Three affordances were proposed and Wyatt
rejected all three with the question that actually matters: *"how will the person know what to click
and where to reset."* **The generalisable answer: a bare 3-click cycle cannot be made discoverable,
only labelled** — either the interface says the words, or the user must already know. So it split into
the two questions a first-time user has: *"can I click this?"* is answered by a header hover state with
a 45%-alpha ghost arrow in the slot the solid one will occupy, and *"how do I undo it?"* is answered by
the summary row reading `sorted by Date desc · click to clear`, with those words as the hit target.

The other two were ordinary: the summary row and the h-scrollbar shared a band and overlapped (fixed by
making `table_bottom_band_h` reserve both as one number, rather than nudging a constant in the draw —
the scrollbar's drag hit-test reads the same geometry and would have diverged), and the sort arrow drew
underneath the header label. The arrow now has **one producer** consumed by both the hover and the
sorted draw, and its slot is reserved *before* the label is truncated **and** feeds the right-alignment
nudge — §10 right-aligns date columns into exactly the pixels the arrow occupies.

### What this pass got wrong, or nearly did

**A sabotage revealed that two of the new arrow-overlap assertions would have been vacuous on
v0.34.0**: under the stretching layout no header ever filled its column, so an arrow could not overlap
a label no matter what. The precondition is now asserted rather than assumed. That is the eleventh
consecutive batch in which draft test code could not fail, and the shape has not changed.

**The header now carries three behaviours on one rect** — sort click, resize drag, hover — in a surface
whose hit-testing is a data-loss seam. Precedence is explicit (resize edge ±4px beats hover beats
nothing) and swept every 3px across the header band at 100/125/150% asserting `hover == (!edge &&
header_cell)`, 0 disagreements. At the bottom the h-scrollbar wins the shared pixel with the summary
row, on the grounds that a drag lost mid-motion is unrecoverable while a missed click costs one click.

### Owed

- ~~**None of the appearance has been rendered.**~~ **CONFIRMED by Wyatt on real pixels, 2026-07-31:
  *"table looks good"*.** Closed. The open sub-items it listed — `Bg_Hover` against `Bg_Raised` in
  **Light**, the ghost arrow's legibility, and whether the ~2-cell arrow slot truncates a real header —
  were not individually enumerated back, so treat them as passing in Dark at 96 DPI and no more than
  that.
- **The per-column dropdown supersedes the item-3 fix.** Wyatt asked for multi-column sort and
  Excel-style column filtering in the same message; a labelled dropdown (Sort ascending / Sort
  descending / Clear sort / Filter) is the real answer to discoverability rather than a patch. The
  hover state survives it; the summary-row wording would become redundant. See `requested-features.md`,
  which also flags that a distinct-value list is **the first UI here that cannot be viewport-bounded**.

## 6az. The grid gets a right edge and a real horizontal scroll (2026-07-31, v0.34.2, branch `fix/table-hscroll`)

Two more from Wyatt minutes after v0.34.1, and the first is **fallout from v0.34.1's own fix**.

**The table had no right edge.** Bands were drawn to `table_right(width)` — the whole window — which
was invisible while columns stretched to meet it. The moment columns became content-width, that became
hundreds of pixels of banded emptiness and the table read as broken rather than narrow. New producer
`table_content_right(cols, width)` takes the **layout slice** rather than re-summing widths, and the
zebra, header band, header rule and hover lift all end there. `table_cols_layout`'s "a band starting
24px in reads as a box" argument is now explicitly scoped to the *left* edge, with the opposite rule
stated for the right, so the two no longer read as contradictory. The summary strip deliberately stays
full width — it is chrome, and a one-column CSV's `click to clear` run would hang off a clipped band.

**The horizontal scroll snapped in two units at once**, and Wyatt's read of it was literally correct:
*"it's like it's trying to snap to two different things."* `doc.table_col` was a **column index** while
the thumb's `span` came from `table_cols_fitting`, a **column count derived from a pixel measurement**.
Those agree only when every column is the same width, so the thumb resized as it moved. He also called
the fix: *"i'm not sure the horizontal scroll should snap at all, maybe just act like any other view."*

`doc.table_col` → `doc.table_hscroll_px`; `table_start_col`, `table_max_col` and `table_cols_fitting`
deleted rather than adapted; `table_cols_layout` **no longer takes a scroll parameter at all** — it
reads it from the document, so no caller can lay out a different axis than the hit-test beside it. That
is the seam defence, and it is stronger than the old signature was.

Two side effects worth knowing: the old `max = table_cols - 1` gave *any* table with 2+ columns a
scrollbar even when it fit — now shown only on real overflow. And session migration turned out to be a
non-issue, **verified rather than assumed**: `table_col` was never persisted in any unit, and
`doc_view_apply` zeroes the field on every restore.

### What this pass got wrong

**`hscrolltest` printed `FAIL` and exited 0** — the `keytest` shape for the fourth time this week,
found only because a sabotage produced a failure line and a zero status. And its 40-column fixture had
**uniform widths**, so a column-count span and a pixel span were the same number scaled: the thumb-size
check was structurally incapable of failing, which is precisely why the bug it should have caught
shipped. Both fixed.

**A claim in the fixing agent's report did not survive checking.** It reported that
`odin check src/program` exits 0 with undefined identifiers in the tree, and therefore that
development-loop §5's per-commit bisectability sweep "may not be checking anything". **That is false**
— tested directly with an undeclared call appended to `version.odin`, `odin check` reports
`Error: Undeclared name` and exits 1. There may be a narrower real gap (the sweep passes no
`-define:NEWTPAD_TESTS`, so it checks a third configuration that neither `build.bat` invocation does),
but the sweep is not vacuous. Recorded because an unchallenged claim of that size would have had
someone rewrite a working process.

### Owed

- ~~**None of this has been rendered.**~~ **CONFIRMED by Wyatt, 2026-07-31: *"table looks good"*.** The
  narrow-table right edge reads correctly and the pixel h-scroll is accepted. Closed.
- Confirm whether the `-define:NEWTPAD_TESTS` gap above is real, and if so make the bisectability sweep
  check the configuration that actually ships.

## 6ba. The white flash was real and the regression was not (2026-07-31, v0.34.3, branch `fix/startup-shutdown`)

Wyatt: *"when opening and closing the app it's no longer snappy... it'll show a white box for a split
second, then close/open."* Two reports in one sentence, and they turned out to be **one real defect and
one false alarm** — which is only knowable because this was measured before anything was changed.

### There is no regression, and the suspicion was mine

v0.32.0, v0.33.0, v0.34.0, v0.34.1 and v0.34.2 were each built from their tags and timed with the same
harness against Wyatt's real session (6 tabs including a 1.05 GB file): **white flash 196 ms and
WM_CLOSE→exit 89–157 ms in all five**, flat within noise. Nothing that shipped that day made it slower.
The flash had been there all along and was noticed for the first time.

**The prime suspect was wrong, and wrong in the interesting direction.** `WATCH_MAX` had gone 32 → 64
that morning (§6ax) and the entry named it *"the most likely regression and it is ours"*. At 40 open
tabs, where the values actually differ, `watcher_stop` measured **26.9 ms at 32** and **18.2 ms at
64** — the old value was *slower*. Had this been fixed by inspection, the change would have been
reverted, the symptom would have remained, and the revert would have looked like a fix that failed for
some other reason. **This is the argument for the measure-first rule in one paragraph.**

The other three suspects: line-index join **0.00 ms** (including the 1.05 GB tab, and including closing
300 ms after launch mid-scan — `index_worker` polls cancel every 64 KB); snapshot checkpoint frees
**0.00 ms** (a restored session has an empty undo stack); `session_save` **33 ms**, the largest thing
left on the exit path and deliberately untouched, because it writes the backups that are the only copy
of an unsaved buffer.

### What was actually wrong

**`CreateWindowExW` passed `WS_VISIBLE`**, so an empty window went up 20 ms into startup and DWM
composited it long before D3D presented anything — solid `FFFFFF` on real desktop pixels by ~85 ms,
still white at ~200 ms, first Newtpad frame at ~220 ms. What filled the gap was **`gfx_init` at 133 ms**
of D3D11 device and swapchain creation: nothing wasteful in it, it simply must not be watched. The
window is now created hidden, shown after the first present, and hidden again the instant the loop
exits. **The non-obvious part: a hidden window is sent no `WM_PAINT`**, so the first loop iteration has
to skip the idle wait or startup becomes 1220 ms.

**And `watch_worker` slept its poll interval in twenty 50 ms naps**, so exit paid out whatever was left
of one — 24 ms median, 58 ms worst. Now a posted `sync.Sema`: **0.13 ms**.

| | before | after |
|---|---|---|
| white box on screen | **196 ms** | **0 ms** |
| WM_CLOSE → exit | 129 ms | **77 ms** |
| `watcher_stop` | 24.2 ms (4–58) | **0.13 ms** |
| window starts vanishing | 40–105 ms | ~7 ms |

**Wyatt signed off the trade** this makes: nothing on screen for ~220 ms and then a finished window,
where before an empty white one appeared at 28 ms. Time to a *usable* window is unchanged either way.
He also chose to keep `perf.odin` — an environment-gated (`NEWTPAD_PERF`) mark timeline, free when
unset, added because a GUI-subsystem exe cannot print and this project keeps needing numbers it has no
way to take.

### Owed

- ~~**Does the window still take focus on launch?**~~ **CONFIRMED by Wyatt, 2026-07-31: *"launch is
  better"*.** This was the batch's one real risk — `WS_VISIBLE` at creation got activation from the
  shell's launch rules for free, and a window shown 220 ms later does not, so `window_show` calls
  `SetForegroundWindow` explicitly. Verified from a real shell launch, which this environment cannot
  reproduce. Closed. Original note kept below for the mechanism: one line to
  reverse.
- **High DPI is unverified**; everything was measured at 96 DPI.
- **220 ms to first frame is 133 ms of `D3D11CreateDevice`.** Getting on screen sooner means painting a
  themed placeholder before the GPU is ready — a design decision, not a bug fix, and Wyatt was offered
  it and chose the blank.

## 6bb. Ctrl+A stops selecting the blank tail (2026-07-31, v0.35.0, branch `feat/ctrl-a-trim`)

Wyatt, 2026-07-29: *"if you ctrl+A on a document with a lot of blank rows at the end, it captures those
rows in the Ctrl+A, I don't think it should do this. One failure spot for this though is spaces between
paragraphs, those should be captured."*

**A deliberate divergence from VS Code, Notepad and Sublime**, all of which select the entire buffer.
Recorded as a decision rather than left to look like an accident, because someone will eventually ask
why Newtpad differs.

### The investigation that preceded it, kept because it settled the kind of bug this was

Measured against a real build on nine fixtures with known trailing-newline counts: **the trailing rows
are real bytes in the file.** `rows == newlines + 1` in every one — including the no-trailing-newline
case that would have exposed a phantom row — and `Select_All` set `cursor == pt.length` every time.
Sabotage-verified by reintroducing the historical `next_row_start_capped` phantom-row bug, which made
the no-trailing-newline fixture emit phantom rows. **So this was a select-all policy question, not a
rendering bug** — and that answer is what decided the whole shape of the fix. Two things found on the
way: `doc_visible_rows` is pure viewport geometry rather than a content count (it returned 20 for every
fixture including the empty one), and `doc_selection_rects` skips the final empty row, so N trailing
newlines highlight N−1 blank rows — which is what the report described seeing, and is a faithful
drawing of real bytes.

### The rule, and Wyatt's four decisions

**It is row-aware, not a whitespace trim.** `base.pt_content_end_cap` scans back to the last non-blank
byte and then returns **that row's** end. A naive backward whitespace scan would eat the trailing spaces
of `"alpha\nbeta   "`, which is content on a content line.

1. **A second `Ctrl+A` extends to the whole buffer.** Measured first: a trimming select-all leaves 5
   bytes and 6 blank rows on the five-newline fixture after Delete, so delete-all had to stay reachable
   rather than being quietly lost.
2. **Whitespace-only rows count as blank.**
3. **An all-blank document selects everything** — so `Ctrl+A` never visibly does nothing and Cut/Copy
   stay live.
4. **The selection includes the last content line's terminator**, both bytes of a CRLF, so copying an
   ordinary newline-terminated file stays byte-identical to before. Only files with a *run* of trailing
   blanks change at all.

### Two design calls worth reading

**The second-press state is derived, not stored.** One line — `if doc.anchor == 0 && doc.cursor == end
{end = doc.pt.length}`. A stored `select_all_trimmed` flag would need clearing from every caret move,
edit, `apply_snapshot`, reload, EOL conversion and tab switch: the same maintenance shape as
`command_mutates_doc`, which this file records being patched three times for three separate misses.
Deriving it makes the reset rule *"anything that changes the selection"* with no list to forget. Three
consequences, each asserted rather than left implicit: a third press trims again (Ctrl+A toggles); a tab
switch away and back does **not** reset, because the trim is still what is on screen; and undo extends,
because `apply_snapshot` restores the trimmed selection.

**The backward scan is capped at 1 MiB** (`SELECT_ALL_TRIM_CAP`, matching `STATUS_COL_CAP`). An
unbounded scan on the input thread is §4's Shape A, which this codebase has produced eight times, and a
multi-GB log with a huge blank tail would have frozen `Ctrl+A` with no way to tell it had been
truncated. `exact = false` means the cap ran out, and the fallback is today's `pt.length`. Reaching
offset 0 is a *real* answer, so decision 3's whole-buffer result is a finding rather than a fallback.
Measured: a 16 MB blank tail costs 2.522 ms against a 1 MB tail's 2.506 ms — and that comparison is the
assertion, rather than a fixed threshold that would drift with the machine.

### What this found on the way

**`doc_sort_lines` IS selection-scoped**, correcting the investigation's own "not affected" list. So
`Ctrl+A` then Sort changed behaviour: `"b\na\n\n\n"` now sorts to `"a\nb\n\n\n"` where it previously
gave `"\n\na\nb\n"` with the blank rows floating to the top. An improvement, and now pinned by a test
rather than left to be rediscovered.

**A sabotage that looked like the fix holding.** One formulation put a bare `return` above live code;
Odin rejected it, `build.bat` failed, and the *stale* exe ran and printed `0 failures`. Echoing the
build's exit code is what caught it. Worth knowing generally: **a sabotage that fails to compile is
indistinguishable from a sabotage that fails to break anything**, unless the build status is checked.

Base tests 204 → **211**; `selalltest` is one-argument, exits non-zero, and is in §7 and
development-loop §6.

### Owed

- ~~**No live GUI pass.**~~ **CONFIRMED by Wyatt, 2026-07-31: *"ctrl+a wworks"*.** Closed.
- The 1 MiB cap is judgement matched to an existing constant, not a measurement of what users have.
- Wrapped documents are not covered by the selection-rect and scroll assertions.

## 6bc. Multi-column sort (2026-08-01, v0.36.0, branch `feat/batch-19-multi-sort`)

Wyatt, 2026-07-31: *"multiple sort of columns, first column selected to sort takes precedence. would
also be nice to filter columns, and have a dropdown list of all items in the column to filter like
powerbi/excel has."* **Split in two on his decision: this is the sort half. Column filtering is batch 20**
— the sort is a key vector over machinery that already existed, while filtering changes the visible row
*set*, which every consumer of the grid reads.

Eight tasks, 28 commits, a fresh implementer and an independent reviewer per task.

### What it does

`Table_Sort.col`/`desc` became a key vector — `keys: [TABLE_SORT_KEYS_MAX]Sort_Key` + `nkeys`, where
**array order IS precedence**, so "first column selected wins" is a property of the data structure rather
than a rule anything enforces. Three gestures: a plain header click still cycles that column alone
asc → desc → clear; **Ctrl+click** cycles one key asc → desc → removed; and a **header menu** — a hover
chevron or a right-click — carries Sort ascending / descending / Then by ascending / descending / Remove
from sort / Clear sort, with disabled states that tell the truth.

**`offs`/`perm`/`rank` never changed meaning, `doc.top` is still a real byte offset in every mode, and
both lifetime hooks are untouched.** Only *how `perm` is computed* changed. That was the design's central
bet and it paid: the data-loss seam of the feature needed no new machinery.

### The measurement moved the design, which is why it came before the cap

The plan required timing k=3 at the 100,000-row ceiling **before** the cap was fixed, with the cap named
as the variable — because the tempting response to a slow number is to keep the feature as designed and
accept the stall. Measured at 100,000 rows, debug: **1 key 371–395 ms, 2 keys ~556 ms (1.50×), 3 keys
690–702 ms (~1.8×)**. Converted at the tree's own ×0.665 ratio: roughly 258 / 370 / 460 ms of release
freeze. `build.bat release` is `-subsystem:windows` and cannot print, so **every release figure here is
converted, never measured**, and the constants say so.

**Wyatt's call: two keys, not three.** Recorded with the honest caveat that the number does not make the
choice obvious — the cost is a **constant factor** (3× the keys buys 1.8× the time), so the cap is a weak
lever, and two keys still costs ~360 ms. The case for stopping at two is that "sort by department, then
by name" is the query people actually have and nobody asked for a third key.

**A pre-existing error the measurement exposed:** `TABLE_SORT_MAX`'s comment claimed 205 ms at 100,000
rows, extrapolated *linearly* from a measured 2,046 ms at 1,000,000. Measured directly it is ~258 ms — the
shipped single-key sort was already ~26% slower than its own comment said. The comment is fixed; the
constant was right.

### The bug that would have looked like someone else's fault

`menu_close` zeroed `ctx_col` **before** the picked command read it, so all six commands would have acted
on **column 0** whatever column opened the menu — while `item_enabled` was still evaluated *before* the
close and so greyed correctly for the real column. **Draw and effect disagreeing**, which is the exact
thing `Menu_Item.enabled`'s own comment and CLAUDE.md's one-layout rule exist to prevent.

It was caught in task 5's review, in the task that *chose* the read, while nothing could yet reach it.
Had it survived one more task it would have surfaced as "task 6's right-click is broken". **The fix — stop
clearing `ctx_col` in `menu_close` — creates a constraint worth knowing: `ctx_col` is valid only between
a `menu_open_ctx` and the dispatch of the row it produced.** `command_from_name` now refuses the six via
`command_needs_menu_target`, so a hand-written `keys.txt` chord cannot reach them from outside a menu and
sort whatever column was last touched.

### What this batch got wrong

**Eleven comments claimed evidence they did not have.** Not one was caught by a test; every one was
caught by a reviewer. They were: a cap presented as measured before the comparator that would produce the
measurement existed; a 205 ms figure left standing 37 lines from a directly-measured 258 ms for the same
quantity; a ratio quoted "over five runs" with three written down; a lifetime rule stated as a fact about
what an unwritten task *would* do; a Win32 claim that `DefWindowProc` synthesises `WM_CONTEXTMENU` from
`WM_RBUTTONDOWN` (it is `WM_RBUTTONUP`); a comment naming `table_header_col_at` where the code calls
`table_header_cell_at`; a "the one menu whose widest row is a reason" contradicted by output the same test
prints two lines above; a claim that a predicate was the single definition of the key cap while a second
definition sat 112 lines away with dead code attached; a "the only mode that exits non-zero" that was
false before the batch started and more false after it; a `#assert` cited as "below" from ~900 lines away;
and a `tg_sort's C4` pointer that now resolves to a real but wrong test case.

**This is the same shape as the CLAUDE.md rows that had to be amended twice, and it is a review-only
defect class.** The countermeasure that worked was naming it in every reviewer prompt with a running
count. Worth carrying forward: **a comment asserting a number, an API's behaviour, or another
procedure's name is a claim, and this codebase gets those wrong roughly once per task.**

**Two test modes printed their failure counts and exited 0** — `menutest` and `settingstest`, the same
defect §7 already recorded for three others. Any sweep run against those two before 2026-08-01 was
non-diagnostic. Both now follow `palettetest`'s guard. Separately, **`menuseam` legitimately exits 0
whatever it finds** — it is a falsifier, its answer moved 14/14 → 12/12 under a sabotage with the exit
code unchanged, and it must be swept by diffing its printed line.

**`odin check src/program -collection:src=src` was reported as exiting 0 with real errors for the second
time**, by a second agent. Tested directly with three deliberate type errors: it reports all three and
exits 1. §6az already recorded the first false claim. The likely cause is reading PowerShell's `$?`
instead of `$LASTEXITCODE` after a native command. **The bisectability sweep is not vacuous** — all 28
commits pass it.

**Two brief-level defects made it into dispatches.** Task 6's brief specified a right-click step when
**no right-button plumbing existed anywhere in the tree** — no `WM_RBUTTONDOWN`, no `mouse_right_pressed`
— so the task had to add it to `src/platform/window.odin`, outside its stated file list. And task 7's
brief simultaneously required the arrows to come out of `table_header_layout` and forbade changing what
`table_header_layout` produces; the arrow was never in it. Both were reported rather than papered over,
which is the behaviour the "a cited procedure that does not exist is a plan defect" rule was written for.

### What the sabotage caught that review did not

**The arena sabotage crashes the process.** Materialising a sort key's string inside the row loop instead
of after the arena stops growing kills it with an access violation on the 100,000-row fixture. Strong
evidence the rule is load-bearing — with a caveat worth keeping: the crash is incidental to heap layout,
and the same bug on a smaller fixture would be **silent wrong-order corruption** instead.

**Two assertions were vacuous in ways only sabotage could show.** `table_sort_drop`'s scroll-to-top had
*zero* coverage — deleting the line left every mode green — and the naive fix would also have been
vacuous, because the row at sorted position 0 is the same physical row before and after that particular
drop, so `doc.top` was coincidentally correct either way. A poisoned sentinel is what made it real. And
the DPI sweep for label/mark overlap was passing a sort-state predicate on a document with **no sort**,
so it tested `false` at every scale.

### The `renderer`/`ui` extraction got harder again, and here is the list

§6ax recorded batch 18 taking `doc.odin` → `table.odin` from 1 call site to 8. This branch adds **16 more
upward call sites**, concentrated in one file:

- **`menu.odin` → `table.odin`: 0 → 9.** `table_sorted`, `table_sort_key`, `table_sort_can_add` and
  `TABLE_SORT_KEYS_MAX`, plus **`table_header_menu_items`** — a table-specific menu table declared inside
  the menu widget, naming six `Command_Id`s. **That slice is the hardest single item**: extracting `ui`
  gives it no home that knows about both menus and tables.
- **`commands.odin` → `app.menu.ctx_col`: 5 new reads.** Transient widget state is now the argument
  channel for six commands, and by design it must outlive `menu_close`. Enforced by three comments and
  `command_needs_menu_target` — nothing structural.
- **Header geometry now depends on document sort state.** `table_header_layout` →
  `table_sort_digits_shown` → `doc.table_sort.nkeys`. Before this branch the header's geometry was a
  function of columns and DPI alone.
- **`main.odin` → `menu_open_ctx`: 2 new sites** in the table input branch.
- **Platform: no new upward pressure.** The right-button addition crosses upward as a plain `bool`, the
  same shape as the existing `mouse_middle_pressed`.

Same direction as batch 18, roughly double the volume. **Design the observer list before extracting.**

### Owed

- **No live GUI pass.** This environment cannot inject GUI input, so the chevron's hover, the right-click,
  Ctrl+click, the menu's placement against a window edge and the `.Hand` cursor are all inferences from
  source. Every task report says so plainly and none claimed otherwise.
- **The summary row does not fit a minimum-width window (318px).** The 2-key line ends at 850px and its
  clickable run at 730px — but **the one-key line already ended at 602px before this branch**, so the
  threshold moved rather than being created. Not a correctness bug: the hit rect and the glyphs share one
  x, and Clear Sort in the header menu works at any width. What to do about it is a product call and it
  is Wyatt's.
- **The cap note is the clause that gets cut** between 730 and 850px, deliberately — the control was
  protected ahead of the explanation. Reversible in one line.
- The precedence digit is drawn as a glyph rather than quads. The quads rule is about U+25B2/U+25BC not
  being guaranteed in an arbitrary monospace face; a face that cannot draw `'1'` cannot draw the CSV
  either.
- **If the active tab changes while a context menu is open**, a row greyed for document A dispatches
  against document B. Pre-existing for every menu in the app, not introduced here, and not fixed here.
- Release timings are converted from debug, never measured.

Base tests unchanged at 211. `tablesorttest` is new, one-argument, exits non-zero, and is in §7 and
development-loop §6.

## 6bd. The preview stops being a line-per-paragraph document (2026-08-01, v0.37.0, branch `fix/preview-paragraph-join`)

Wyatt reported this twice — 2026-07-29 with a side-by-side screenshot (*"it looks like it's not
respecting the spaces all the time"*), and again on v0.35.0 after a fix that turned out to be a
different bug: *"still see it… it's like it's messing up the formatting of sentences, etc."*
`reported-bugs.md` had already named the leading candidate and it was right.

### The root cause, and why the earlier fix missed

`md_classify` classified **one source line at a time**. `.Para`'s content was that whole line and every
one got `e.below = m.para_below` (0.80 × S), while `.Blank` collapsed to **zero** height. So in any
hard-wrapped document — HANDOFF.md, a README, a spec — every source line rendered as its own paragraph
with a full paragraph gap under it, and the blank line that actually separates two paragraphs
contributed nothing on top of that. A sentence spanning two source lines became two visible paragraphs.

"Not respecting the spaces" is the same defect from the other side: CommonMark inserts a space when it
joins two lines of a paragraph, and there was no join for a space to be inserted into.

### What it does now

CommonMark's paragraph model in the preview: consecutive prose lines join into one paragraph re-flowed
to the pane width, blank lines are the real separator, and **hard breaks are honoured** (two or more
trailing spaces, or a trailing backslash → `'\n'`, which the shaper already broke on). Wyatt also chose
two additions: **lazy continuation** — an unmarked line after a list item or blockquote continues *that*
block with its indent and marker instead of becoming a stray un-indented paragraph — and **setext
headings**, `Title` over `===` or `---`.

### The design bet, and where it was wrong

The spec's bet was that this was small: a block could already span many visual lines and be taller than
the pane (`Md_Anchor` carries a sub-block offset, `md_block_admit` admits per line), so joining should
need no new scroll machinery. **Spans, wrapping, span boxes, links, admit and height did all follow with
no change** — that half held.

**What it missed is that a joined paragraph starts ABOVE its own line.** `md_layout_build` is reached
not only from a forward walk, where the entry byte is always a real block start, but from
`md_block_at_byte` and `md_anchor_walk`, whose entry is `MD_RUNUP_LINES` (24) of run-up back from an
arbitrary byte. On a hard-wrapped document that lands *inside* the paragraph. Measured on
`md_scroll_selftest`'s 200-line fixture: editor top at byte 1200, `md_anchor_from_top` answered block
**912** — 1200 minus 24 lines of 12 bytes, exactly — and **the preview drew from line 0 while the editor
half sat at line 100.** Split-view scroll sync, broken on any long prose document.

That became an unplanned task on Wyatt's decision: `md_block_start_at` snaps every byte-to-block
resolver to the containing block's true start, so a walk always enters a block at its real beginning.
Two alternatives were refuted rather than deferred — setting `e.start = ps` breaks the cache lookup,
which is keyed by the entry byte, and refusing to join on mid-run entry reintroduces exactly the
scroll-dependent rendering the design exists to prevent.

**It also cured something older.** `MD_RUNUP_LINES`' own comment had recorded since batch 17 that a
run-up landing inside 25–65 lines of front matter misreads it, and was honest that a clean 30-line
fixture was *"an absence of a demonstrated defect, not a proof the case is handled."* The snap closes
it: `md_wheel_selftest`'s 30- and 50-line front-matter fixtures each went from a documented one-failure
exception to strict, and removing only that branch reverts them byte-for-byte.

**A sibling is still open:** a collapsed blank run longer than 24 lines is the same defect class. Its
block is chunked at `MD_BLANK_RUN_MAX`, so "the run's first blank line" is not the containing block's
start, and answering properly means modelling the chunking. Bounded, unmeasured, and named in
`md_block_start_at`'s comment rather than left silent.

### The performance regression, and the fixture that could not see it

The snap asks `md_para_bounds` per resolver call. `mdperftest`'s fixture was blank-separated
**single-line** paragraphs, so each scan covered ~1 line and the mode reported "unchanged". On
hard-wrapped prose with no blank lines, measured in debug:

| fixture | before the snap | after | after the memo |
|---|---|---|---|
| 20 × 100-line paragraphs | 5.414 ms | 6.117 ms | 5.193 ms |
| one 2000-line paragraph | 6.134 ms | **13.431 ms** (over the 11.7 ms gate) | **1.633 ms** |
| one 4000-line paragraph | 35.0 ms | 39.3 ms | **1.615 ms** |

`md_para_run` — a four-slot **byte-window** memo keyed on `doc.revision` plus both runtime budgets —
fixed it, and paid off the join's own debt as well as the snap's: the 4000-line case is back to what it
cost before the join existed (1.73 ms, reconstructed directly). **The hard-wrapped fixtures are now in
`mdperftest`**, which was the actual root cause — without them the regression is invisible to the next
person who measures. All figures are **measured debug**; `build.bat release` is `-subsystem:windows` and
cannot print, so no release number is claimed.

**The memo's soundness rests on `md_para_bounds` being entry-independent** — it answers for bytes it has
never seen. That is asserted by several `mdjointest` cases and was probed by a reviewer over ~15k byte
positions × 10 call orders × 40 fixtures with zero divergences, but it is not *proved*. It is the
assumption the 8× is bought with.

### Two decisions worth not relitigating

**Lazy continuation is an EXTENT problem, not a KIND problem.** The plan specified that `md_para_bounds`
grow an `owner: Md_Class` return so a continuation line could inherit its predecessor's kind. The
implementer refused, correctly: because the snap means `md_layout_build` is *always* entered on the
marker line, `md_classify` already yields the right kind, level and bullet there. An `owner` return
would have been a second producer of a block's kind with no consumer. **`md_classify` stays pure** — one
line in, one class out — and the predecessor dependency lives entirely in the bounds layer.

**The setext underline had to go into the bounds layer too**, for the same reason the snap exists: the
underline byte belongs to the heading block, so an anchor landing on it must resolve to the paragraph's
start or a walk renders a heading while an anchor renders a rule. The plan's recipe (extend `e.end` in
`md_layout_build`) would have reintroduced the divergence.

### What this batch got wrong

**Comments claiming evidence they did not have, in six consecutive review rounds.** §6bc recorded eleven
in one batch and named it a review-only defect class; it recurred here immediately, including in text
written by a round whose explicit job was fixing a wrong comment. The worst was a commit message saying
a probe had *confirmed* a branch unreachable — a later reviewer reached it with two probes. The source
is corrected; the message stands, and is recorded here rather than rewritten.

**Nine assertions that could not fail**, every one found by sabotage rather than by review-by-reading.
Three hid the same way: they asserted a value that a **redundant code path also produced**, so deleting
the guard they were named for left them green. Worth carrying forward as a named sub-pattern.

**My own plan was wrong four times, and every subagent that caught it was right.** Both of Task 1's
sabotage recipes were vacuous — they did not catch the bugs they named. One fix instruction said "fix
the comment" when the comment was a symptom and the coverage gap was the defect, costing a whole round.
Task 4's `owner` return and Task 5's promotion site were both refuted by their implementers. **A plan's
sabotage steps need re-deriving by the implementer, exactly like its test code.**

**And I shipped one myself.** The scroll round-trip test's first draft scrolled 480 px, which stayed
inside the *first* block where the snap is the identity — deleting `md_block_start_at` from
`md_runup_start` left the whole mode green. It now has to reach a later block and visit three of them.

**`mdtest` went from 0 to 20 failures and nothing noticed**, because it printed `FAIL` and exited 0.
Six modes had that defect and were fixed here (`mdtest`, `linktest`, `mdviewtest`, `splittest`,
`mdfencetest`, `mdtabletest`, plus `mdperftest`). **60 of 86 mode entry points still do** — see §5.

**`cmd.exe /c build.bat` can report exit 0 while the compile failed**, leaving a stale exe that prints
`0 failures`. Hit for real twice, once by me. Build through PowerShell and check that
`(Get-Item build\newtpad.exe).LastWriteTime` moved. This is a sharper form of the trap the "where things
stand" section already records.

### Owed

- **No live GUI pass.** This environment cannot inject input, so how the re-flowed prose actually reads,
  whether the paragraph gaps are now right, and whether a wrapped bullet looks correct are all
  inferences from source. **A live pass is required before this is called done.**
- **Split sync over a long hard-wrapped paragraph is now coarse** — the preview pins to the paragraph's
  top. This is `docs/ui-spec` §9.4 (*"scroll sync by block, not by line"*) being honoured for the first
  time; the finer old behaviour was an artefact of every line accidentally being its own block.
  Sub-block sync is achievable — `Md_Anchor` already carries a within-block pixel offset and
  `lay.sh.line_boxes` already gives per-visual-line geometry. The missing piece is a map from a source
  byte to an offset in `e.joined`, and **the hard half is the inverse**, which `md_scroll_scalar`'s own
  comment calls hard-won.
- **A blockquote written with `>` on every line still renders as N stacked blocks with a segmented bar**
  (13 px gaps between 26 px segments, measured). Pre-existing — but this batch makes it *inconsistent*,
  because the lazily-continued form now renders as one clean bar. Joining a run of *marked* quote lines
  is its own small task.
- **Setext changes existing documents**: prose directly over `---` now renders as an h2 rather than a
  paragraph plus a rule. No file in this repo is affected (the one hit is front matter at byte 0).
- `md_para_bounds`' `!trunc_fwd` term on the setext promotion is unfalsifiable — removing it leaves five
  modes green. Honest defensive code, documented as such so a later "simplification" knows the green
  suite is not evidence.

Base tests unchanged at 211. `mdjointest` is new, one-argument, exits non-zero, and is in §7 and
development-loop §6. 46 headless modes clean; all 18 commits pass the bisectability sweep.

## 6be. What the two live passes actually found (2026-08-01, v0.38.0, branch `live-pass-fixes-v0.38`)

v0.36.0 (multi-column sort) and v0.37.0 (the preview's paragraph model) both shipped with **no live
GUI pass at all** — this environment cannot inject input — so both went out with a checklist attached.
Wyatt drove both end to end on 2026-08-01. This entry is the table half of what came back; the
preview half is queued, not built.

**The single most useful outcome is not a fix.** §2's Ctrl+click cycle — the core of v0.36.0, three
gestures no test can observe — was left unchecked with no note, which read as a failure and was
scoped as one. It was "I missed that section but they all worked." A blank checkbox is not a report,
and asking cost one question where guessing would have cost a batch.

### The four table defects, and what each one really was

**A. A second sort key truncated every header in the grid.** `table_draw`'s header pass asked
`table_sort_digits_shown` — a *document-wide* predicate — once outside its loop and handed that one
answer to `table_header_label_col` for every column. The precedence digit is drawn on at most two
columns; the reserve was paid by all of them, so a second key cost every header name **two cells**
(measured: 8 → 6). Wyatt reported it as "the column headers truncate and don't show the rest of the
text until you expand the columns, but the column doesn't change horizontal size" — and the column
genuinely does not, which is what made it confusing. `table_sort_digit_col` answers per column now.

The interesting part is *why the uniform rule was right and still is, for the chevron*. Reserving a
mark's slot only where it is drawn makes the label re-truncate as the pointer crosses the header —
text moving under the mouse. That argument is sound for the chevron, which follows hover, and vacuous
for the digit, which changes only when its own column becomes a key. **One comment covering two marks
let the weaker case inherit the stronger case's justification.** Worth watching for elsewhere.

**B. The header menu was unreachable on a short window.** `menu_dropdown_rect` capped height downward
only. Its own comment said a flip-up was owed *"if a context-menu anchor is ever near the bottom"* and
then argued the case was unreachable because column headers sit at the top of the grid. They do. On a
short enough window the top of the grid **is** near the bottom of the window. The unreachability
argument was about the anchor being unusual; what made it reachable was the window being small.

The fix is small and the seam is not: the draw and the hit-test each called `menu_origin` for their
own y and asked the rect only for x/w/h, so a flip in either alone paints the menu in one place and
accepts clicks in another. `menu_dropdown_rect` returns `y0` now and both consumers read it.
Sabotaging exactly that — leaving `menu_item_at` on `menu_origin` — makes all six selectable rows
hit-test as `-1`, and **the pre-existing drawn-rows-equal-clickable-rows case does not catch it**,
because nothing in it ever flips. A seam test only covers the states it visits.

**C. Clearing a sort dropped the reader at an arbitrary row.** Every transition except the two that
*clear* set `doc.top` to the top of the new order. The clear paths deliberately did not, reasoning
that `doc.top` was "already a real byte offset in the file's own order". It is — the offset of
whichever row happened to be on top **in sorted order**, which in file order is nowhere in
particular. Hence "sometimes the bottom, sometimes the middle". *Being valid was never the property
that mattered; being predictable was.* All four in-grid clear routes go through one producer,
`table_sort_scroll_top`; the three that clear because the grid is being **left** keep their place,
which is what the text view wants.

**D. Blanks now follow the arrow** — first ascending, last descending (Wyatt's call). The old comment
argued "no value is not the smallest value" at length. Half of that argument was always the real one
and survives: the flag keeps an empty cell out of the *comparison*, which is what stops a numeric key
parsing it as `0.0` and dropping a blank into the middle of the data. Only which end has changed.

### Two things this batch got wrong

- **A and C share a commit.** Both are `table.odin` and both land against `tablesorttest`; splitting
  them needed hunk surgery that risked a non-building intermediate, which §5.3 forbids outright. The
  commit says so. If this recurs, do the two fixes in two passes over the file rather than one.
- **The header-seam sweep in `tablegridtest` mirrored bug A rather than catching it.** It passed
  `table_sort_digits_shown(&d)` to `table_header_label_col` for every column — the same document-wide
  answer the draw used — so it measured the unsorted columns against a label a cell *narrower* than
  the draw gave them, and the reserve those columns were wrongly paying was invisible to it. **A test
  that reproduces the production expression cannot falsify it.** It now asks the per-column predicate
  and counts how many columns the digit checks actually covered, so a predicate that never reserves
  fails the precondition instead of passing everything.

### Owed

- **E — a sorted cell should re-sort on commit** (Wyatt's call, same pass). Deliberately not in this
  batch: it touches `table_edit_commit`, the data-loss seam §1 of the live pass exists to cover, and
  it gets its own spec and its own review.
- **F — a headerless CSV is still assumed to have a header.** Reported in the same pass. Needs a
  heuristic and probably a toggle; it is a task, not a fix.
- **The preview half of the v0.37.0 pass**: a Tab inside a fenced code block draws `.notdef`;
  dragging the scrollbar ghosts the Split sync while the wheel is clean; a blank line may no longer
  visibly end a list item. All three are in `docs/reported-bugs.md`.
- Two items were **answered, not fixed**: trailing-two-spaces for a hard break, and setext turning
  prose over `---` into a heading. Both are CommonMark and both are what v0.37.0 intended.

Sabotage run on all four fixes, output recorded in the commit messages. 46 headless modes clean; all
five commits pass the bisectability sweep.

## 6bf. The edit re-sorts, and two preview defects (2026-08-01, v0.39.0, branch `feat/resort-on-commit`)

The rest of the two live passes. v0.38.0 (§6be) took the four table defects; this takes the decision
that was held back from it and two of the three preview reports.

### E — an edited row moves to where its new value belongs

`table_sort_shift` kept the permutation's **offsets** true across a commit. Nothing kept its **order**
true, so a cell edit left its row sitting where the old value had put it.

**One row moves; the file is not re-scanned.** `table_sort_build` is a full pass over every sorted row
— ~250 ms at the 100,000-row ceiling, ~360 ms with two keys — and paying that on every Enter would
make editing a large sorted CSV unusable. `table_sort_reposition` pulls the row out of the
permutation, binary-searches its slot and reinserts: about seventeen line reads at that ceiling.

Three things about it are worth carrying forward:

- **The comparator is not restated.** The search calls `sort_less_keys`, the same procedure the sort
  itself calls. A second comparison written out for the search would have been the fifth copy of the
  empty-and-direction rules.
- **Probe keys come from the temp allocator, not a shared arena.** `table_sort_build` materialises its
  keys only after its arena stops growing, because a realloc leaves earlier keys pointing into freed
  blocks — the ACCESS VIOLATION recorded in its own comment. A binary search compares each probe
  immediately, so it would meet that hazard on *every* probe.
- **It refuses the edit that makes a numeric key non-numeric**, and falls back to a full rebuild —
  the only thing that can re-decide a column's type. Sabotaging that refusal is not subtle: `N/A`
  reaches `sort_number`, reads as `0.0`, and sorts ahead of `2` and `10`. A typo presented as a
  number, which is what `Sort_Field.empty` exists to prevent for blanks.

**Tab commits without reordering** (Wyatt's call), and it is a decision twice over. Tab means "the
next cell in this row", and a row that jumped on every Tab would slide out from under a held key — but
it also captures a **visible row index** before the commit and consumes it after, so a reorder there
would open the next cell on a different row entirely. Shape B, in a gesture nobody would think to test.

**And a fourth sabotage caught something the other three could not.** Rebuilding `rank` off by one
leaves `perm` looking like a perfectly plausible order; no assertion about row order can see it. It
was caught only by the structural check — perm is a permutation of every row *and* rank is its exact
inverse — which is the shape worth copying whenever a procedure rewrites two arrays that mean the
same thing twice.

### A bug found while building it: `doc.top` was not carried across a cell splice

Older than E, and not in any report. An edit that inserts or removes bytes moves every offset after
it; `table_sort_shift` fixes the permutation's, and nothing fixed the scroll's.

Barely reachable in the **text** view — an edit happens at a caret, and a caret off the top of the
screen has already scrolled `doc.top` to itself. Constant in the **grid** once a sort is live, because
sorted order is not file order: editing any visible cell whose row sits *above* the top-of-screen row
**in the file** left `doc.top` one byte short of a line start, and `table_sort_pos` — deliberately
forgiving about a mid-line offset — resolved it to the row before. The grid slid up by one row on an
edit that had nothing to do with the scroll.

Found because a test asserted where a row was *after* two commits rather than one. The single-commit
version of the same test passes with the bug present.

### A tab in a fenced code block drew `.notdef`

No font has a glyph for U+0009. `text_cell_width_at`'s comment says exactly this for the grid — *"a
tab must never reach the glyph-metrics path"* — and the shaper computed the advance correctly
(`text_advance`) and then queued the glyph anyway, so `rune_face` resolved it to index 0 and the draw
rasterized a hollow rectangle.

Dropped in the shaper rather than skipped at the draw: one answer instead of one per draw path, and it
is what the zero-width branch beside it already does. **Only the tab** — other control characters keep
their box, which is the honest rendering of a byte with no business being there.

Verified on a real device, because the claim is about what reaches the GPU: three tabs put no ink on
an offscreen surface that an `X` through the identical path does ink.

### A list ended with an item's gap instead of a paragraph's

§9.3 gives a list item *"0.25 S **between items**"*. The layout spent it as the `below` of every item
including the last, so leaving a list was 4 px where entering one was 13 px — measured, before
anything was touched, with a throwaway probe over `md_walk`.

Wyatt reported this as *"a blank line still ends a list item"* failing. **The first half of that was
fine**: the prose after a list really is its own `.Para` block and was never swallowed into the item.
Only the space was wrong. Worth recording because the report named a correctness bug and the defect
was cosmetic — the probe is what told them apart, and guessing from the report would have sent the fix
into the join.

The override is a **look back** in `md_walk`, not a look ahead: a block cannot know whether its list
has ended, but the walk knows what it just passed. It fires on **prose and blanks only**. Every other
kind carries its own space-above from §9.3 and is already at least a paragraph's worth — except an
**h1, whose space-above is 0 on purpose**, and raising that would be this fix second-guessing the spec
on a case nobody reported. `mdtest`'s list-then-h1 pair caught exactly that, which is why the rule is
narrow rather than "any block after a list".

A **loose** list — items separated by blank lines — now takes a paragraph gap between its items too.
That is what CommonMark means by loose and what a browser renders. Tight lists are untouched.

### Not fixed: the scrollbar drag "ghosts" the Split sync

*"Grabbing the vertical scrollbar seems to have a ghosting type of thing on scrolling that way, with
the scroll wheel it looks fine"* — reported for both halves.

**Investigated and deliberately not fixed, because nothing was proven.** Two hypotheses were checked
and both died:

- *The sync lags a frame behind the drag.* It does not. The 9.4 sync resolves at one point per frame
  (`main.odin`), after every path that could move either side and before the draw reads them, and the
  drag handlers run well above it.
- *`g_vbar_preview` is never written in Split, so the drag maps through stale geometry.* It is
  written — there is a second draw site for the Split case (`main.odin:2095`) that maintains it.

What remains is a **cost** hypothesis with real evidence behind it but no proof of the symptom:
`md_preview_frac` is measured at **3.322 ms** per call (markdown.odin's own note), and a drag pays
that every frame while a wheel notch pays it once. That would read as stutter under a continuous
gesture and be invisible under a discrete one, which matches the report exactly — and would equally be
explained by half a dozen other things. **This environment cannot inject GUI input**, so "ghosting" is
a word nothing here can observe.

**What it needs is one observation**: does the *content* trail the thumb, or does the thumb itself
stutter under the cursor? The first points at the sync, the second at the frame cost, and they are
different fixes. Do not guess at this one — the scroll model is where this project has been burned
most.

Sabotage run on all four fixes (six sabotages: no reposition, no numeric refusal, rank off by one,
`doc.top` unshifted, tab requeued, gap override removed). 46 headless modes clean; `shapetest` and
`mdjointest` grow cases, and `md_block_gaps_for_test` exposes the walk's gaps as a plain shape so
spacing can be asserted as a sum over blocks rather than read back out of `Md_Metrics` — which would
pass with the walk broken.

## 6bg. Headerless CSVs, and tearing a tab into its own window (2026-08-01, v0.40.0, branch `feat/headerless-csv`)

The last two items from Wyatt's reported-bugs list. One turned out smaller than its entry claimed and
one turned out much smaller, for the same reason: **the entry was written from a few minutes of
reading and both guessed at the hard part.** Worth remembering before scoping off that file again.

### A CSV with no header row

Line 0 was unconditionally the header, so a headerless file showed its first row of **real data** in
the sticky band — where it could not be edited, sorted, found or counted. §10's *"silently dropping
data in a data viewer is the worst possible failure"*, happening to exactly one row.

**Three producers branch on `doc.table_headerless` and nothing else may**: `table_first_data_row`,
`table_header_fields`, `table_row_count`. Every other consumer in the grid already resolves through
one of those three, which is what made this a small change rather than a sweep — and is the payoff
from the one-producer discipline the sort work has been paying into.

**The heuristic answers only on positive evidence.** A column is numeric-consistent when every
non-empty cell *below* line 0 parses as a number and there is at least one; if any such column also
has a number on line 0, line 0 is data, because a title is a name and a name is not a number. It
cannot recognise an all-text headerless file and says so rather than guessing. **Three of its five
test cases exist to pin that it stays quiet** — a detector that fired too eagerly would take the
titles off every ordinary CSV, which is far worse than the bug being fixed.

Columns are labelled `A`, `B`, `C` when there is no header — **not `1`, `2`, `3`**, because a bare
digit in that band is ambiguous with the precedence digits v0.36.0 draws in the same cell, and the two
can appear together. One producer (`table_col_label`) so the summary row's prose and the band agree by
construction.

**Three-valued mode, not a bool.** `Auto` is not a third answer about the file, it is the absence of
an answer *from a person*, and the two persist differently: an answer is worth remembering and
teaching a family default from, a guess is worth re-deciding. The family default is **adopted** rather
than consulted, which is what lets `doc_view_apply` resolve without knowing about `App`.

Flipping the flag **clears the sort** — the row set gains or loses a row at the front, so every offset
in the permutation is one row out and a visible row would resolve to the line beside the one drawn,
which the cell editor writes through.

### Tearing a tab off — much closer to supported than its entry assumed

`reported-bugs.md` recorded the design question as *"tear-off means a new process… both windows would
be writing the same `%APPDATA%\Newtpad` session."* **That is already solved.** `main.odin`'s `primary`
flag gates every session interaction there is — restore, autosave, hot-exit save, crash binding — so a
non-primary process already runs a complete editor that does not touch the session store. The entry
had identified the right risk and not checked whether the code already handled it.

What was actually missing was three small things: the drag never detached, there was no process-spawn
helper, and a spawned `newtpad.exe <path>` would have handed its path **straight back** to the primary
via `instance_send_open` and exited — the single-instance hand-off doing exactly its job at the one
moment it is not wanted. Hence `--detach`, whose only effect is to skip that hand-off.

Decisions taken with Wyatt: **saved, unmodified tabs only** (a torn-off window has no crash
protection, so handing it unsaved work would remove protection at the moment the user is moving
something they care about); **release outside the window** as the gesture; **at the pointer, sized
like the source**.

`tab_detach` **spawns before it closes**. A close-then-spawn loses the tab outright whenever
`CreateProcessW` fails, and the tab is the only record of where the user was in that file.

**Verified end to end for real, not just headlessly**: launching `--detach 300 200 700 500 <path>`
with another Newtpad already running produced a window at exactly `300,200 700x500` with the file
loaded and the process still alive — i.e. it did not hand off. The gesture itself is the only part no
test here can reach.

### `teartest` is new, and `bookmarktest` was lying

`teartest` — one argument, exits non-zero, in §7's list. It deliberately does **not** test the success
path: detaching for real puts a window on the desktop, and a suite that does that on every sweep is a
suite nobody runs. Everything up to the spawn is covered.

**`bookmarktest` printed `FAIL` and exited 0 for its whole life.** It pinned session format 5, which
this batch bumped to 6, and the sweep called it green because the sweep reads exit codes. That is the
**tenth** mode caught this way in one day (development-loop §6 counted nine). It was found by widening
the sweep to grep for the `FAIL` *string* as well as the exit code — which is now the only honest way
to run one, and the earlier sweeps in this session were weaker for not doing it.

### Owed

- The **scrollbar-drag ghosting** from §6bf is still open and still needs one observation from Wyatt.
- The **menu/Ctrl+F focus complaint** is untouched. It needs a driven session or a focus-transition
  audit, not a guess.
- A torn-off window's tabs are outside hot-exit. Acceptable today because only saved files can be torn
  off; if that restriction is ever lifted, this is the thing that has to be solved first.

## 6bh. Any tab can be torn off now (2026-08-01, v0.41.0, branch `feat/headerless-csv`)

Wyatt, from live use of v0.40.0: *"i can only drag tabs that don't have edits, you should be able to
drag all tabs."* He is right, and the restriction was **solving the problem the wrong way round**.

The reasoning behind saved-only was sound as far as it went: a torn-off window is a second process,
a second process is not the primary instance, so it has nowhere to put a crash backup — therefore
don't let unsaved work go there. The mistake was treating "it has nowhere to put a backup" as a fact
about the architecture rather than as the thing to fix. **Give the new window a store of its own and
the restriction evaporates.**

### What travels, and what does not

A path could not carry a dirty or untitled tab, so the whole document does: `handover_write` puts
encoding, BOM, line ending, caret, scroll, path and bytes into one file under the session directory
and the child rebuilds from it. One file rather than a longer command line, so argv stays five numbers
and a filename and cannot lose a field to quoting — and it is the same shape `session.txt` already
uses, so there is one reader idiom in that file rather than two.

**A clean tab carries no bytes.** It has a file on disk that says the same thing, and the receiving
window reopens from it — which also puts a large file back on the mmap path. This matters more than it
sounds: `BACKUP_MAX` guards the *dirty* case only (a clean buffer is never backed up because it never
needs to be), so without this a clean multi-GB file would have been collected into memory and written
out to move its tab. The size ceiling and the byte payload answer the same question from two
directions and neither is redundant.

The one refusal left is a **dirty** buffer past `BACKUP_MAX`, for the measured reason `session_save`
already refuses it: a full in-memory copy plus a full write on the main thread is a multi-second
freeze and a real OOM risk at multi-GB.

### The store, and who picks it up

A `--detach` process claims `windows\<pid>` under the session root and owns it exactly as the primary
owns the shared one — same `session_save`, same autosave timer, same backups. `primary` was doing two
jobs and has been split: `owns_store` (may write *a* store) is what the session paths gate on now,
while `primary` still means "owns the *shared* session" and is still what keeps a torn-off window out
of it.

**Liveness is a lock file, not a pid.** Pids are reused, and adopting a live window's store would take
its tabs out from under it. The lock handle is held open for the process's life and Windows closes it
on death *by any means* — so "can this file be opened exclusively" is an exact test for "the owning
window is gone", including a hard kill, which is the case the whole thing exists for.

**The store survives a clean exit on purpose.** It is tempting to delete it so that "a store exists"
means "a window crashed" — and that would be wrong, because closing a window here is a **hot exit and
not a prompt**: `session_save` has just written the unsaved buffers into it precisely so they are not
lost. Deleting them would make closing a torn-off window the one way to destroy work in this editor.

### Two things this batch got wrong, both caught by looking

- **A test started launching a real window.** `teartest`'s refusal case used an untitled buffer with
  content — refused when it was written, and detachable the moment dirty tabs were allowed out. So the
  suite silently began spawning a second Newtpad on every run, and the sweep hung. The fixture is now
  the empty scratch, which is refused for a structural reason that will not drift, and the case says
  so. **A test whose fixture depends on the rule under test will rot when the rule changes.**
- **The adopter deleted a store whose restore had failed.** A store that could not be read may still
  hold backups — the unsaved work of the window that died — and removing it on a transient read error
  would destroy exactly what the mechanism exists to preserve. It now deletes only on a successful
  adoption, or when there is no `session.txt` at all (backups written before the file that names them,
  recoverable by nobody). Found while cleaning up after a manual probe, not by a test.

And one piece of vacuous coverage caught by sabotage: the first version of the adoption test asserted
`lock_try` directly, which proves the lock is held and **nothing about whether the adopter consults
it** — removing the liveness check left it green. It now drives `session_adopt_orphans` against a
store that is still open and asserts nothing is taken.

### Verified by hand, since no test can drag

A hand-written handover launched through `--detach` produced a window titled `*untitled` — dirty, no
path — with the handover file consumed. The gesture itself is still the only part nothing here can
reach.

### Owed

**A torn-off window's tabs come back at the next primary *startup*, not immediately.** Close a
torn-off window with unsaved edits while the main window is still running and that work is safe on
disk but invisible until Newtpad is restarted, which will read as lost. The fix is a live hand-back
over the existing `WM_COPYDATA` channel — the primary already receives messages on it — and it is
maybe 30 lines. It was left out to stop this batch growing further; it is the first thing to do if
tear-off gets used in anger.

## 6bi. The first UI-spec debt batch (2026-08-01, v0.42.0)

Wyatt's order for what remains: **UI debt, then the small user-reported gaps, then JSON formatting,
then column filtering.** This is the first of those. Scoped as "daily-visible polish": small,
self-contained, and things he looks at every day. Five of six shipped; the sixth is scoped and
deliberately not built, below.

### The caret blinks (§8), and it is the app's only timer

There was no blink of any kind — the caret was simply always drawn. §8 asks for 500ms, *"stop blinking
while typing and for 500ms after"*, and §10 constrains **how**: *"the caret blink is the one timer —
its own 500ms tick, redraw only on phase change."*

That constraint is the whole design. This frame loop does not spin; it blocks on the message queue and
wakes on input. So the loop asks `caret_blink_wait_ms` how long it may sleep, wakes for the phase
change and nothing else. `elapsed` is milliseconds since the last input, which is where "solid while
typing" falls out for free.

**Two things gate the timer off**, and both matter for the "idle cost zero" claim: a view that draws no
caret (asked through `doc_read_only_view`, whose own comment already says the grid and Preview have
none), and an **inactive window** — which needed a new `Window.active`, because a blink that keeps
running in the background wakes the process twice a second forever to redraw a window nobody is
looking at.

The phase is computed **once per frame into `Render_Ctx`** and read by both the sleep and the draw. If
each sampled the clock itself they would sample it at different instants — the loop waking for a
change the draw had already made.

On by default with a setting to turn it off (Wyatt's call). §12's Reduce-motion row already names the
caret as a thing that stops moving when motion is reduced, so this is one of the few options that
earns its place against principle 3.

### Current-line tint (§8), off by default

`Text_Primary` at 3% rather than a new theme role: a role would have to be authored into every theme
file for a surface whose entire definition is "the text colour, nearly invisible", and deriving it
follows the theme into Light automatically.

**The caret's visual row, not its logical line.** §8's warning — *"more turns a wrapped paragraph into
a stripe"* — is about opacity, but the same argument settles the extent: tinting every row of a
wrapped paragraph paints a block, which is that stripe arriving by another route.

Drawn **first**, under the find-match and selection quads: at 3% it would otherwise wash the brighter
marks it sits over, and those are the ones the reader is looking for.

### The split divider (§9.4): `Border_Subtle`, and a real 320px minimum

The colour was `Border_Strong`, which is what the table header's rule and the menu borders use — at
that weight the split reads as two windows rather than two halves of one document.

**The 320px minimum pane could not be a fraction, and that is the interesting half.** `SPLIT_MIN`/
`SPLIT_MAX` are 0.15/0.85, and on a 3440px monitor 0.15 is 516px so the minimum never bites, while on
a 900px window it is 135px — a preview two words wide. The rule is now pixels, enforced in
`doc_editor_right`, which every pane boundary in the app already resolves through (`md_pane_box`,
`md_pane_owns`, `md_divider_rect`, the scrollbar's hit x). One producer, so the draw, the hit-test, the
wrap width and the drag all get it at once. The fraction clamp survives as a sanity bound on a value
read off disk, where there is no window to measure against.

A window too narrow for two minimum panes splits down the middle rather than refusing — the user asked
for a split and must see one.

### h6 is caps (§9.3)

The one heading level with no size of its own: §9.3 gives h5 and h6 the same 1.00 S and weight, so
without this an h6 was indistinguishable from an h5. Uppercased on the block's **text**, not at the
draw — the shaper measures what it is given, and a draw-time transform would size every line against
lower-case metrics and paint wider glyphs into the box, which is §6j's seam in its narrowest form.

§9.3 also asks for **tracking** on h6 and this does not add it: the shaper has no letter-spacing
parameter. Recorded rather than quietly dropped.

### NOT built: joining a `>`-marked blockquote — and the estimate in the queue was wrong

`requested-features.md` called this *"the same `md_join_run` machinery, a different predicate. **Small
and self-contained.**"* **It is not**, and the next person should not start it believing that.

Both scans in `md_para_bounds` continue a run on `md_is_run_line`, which is `.Para` only. Accepting a
`>`-marked line means the predicate depends on **the run's kind**, and the kind is established by the
entry line — while the whole contract of `md_para_bounds` is that its answer is **entry-independent**
(any byte in the run yields the same bounds, which is what `md_block_start_at`'s snap and the layout
memo both rest on). It also has to compose with the existing lazy continuation, because `> a` / `b` /
`> c` is one quote in CommonMark, so the rule is "marked lines at the same depth **plus** lazily
continued unmarked ones" — a change to the run model, interacting with the budget guards, the memo key
and the setext promotion.

It is worth doing and it needs its own spec, a fixture set covering mixed marked/unmarked runs, and
the entry-independence property asserted from several bytes of the same run. **Do not treat it as a
predicate tweak.**

### `surfacetest` is new

One argument, exits non-zero, in §7's list. The blink's phase **and its wait** are asserted together
and then walked across twelve phases to prove they agree — a phase that changes at a time the loop
never wakes for is a caret that blinks only when something else nudges the app, and neither assertion
states that on its own.

The blink cases were briefly written into `teartest`, which is named for the tear-off; they were moved
rather than left there.

## 6bj. The two user-reported gaps (2026-08-01, v0.43.0)

Second item in Wyatt's order. Both were relayed from a user on 2026-07-31 and both turned out to be
*surfaces missing for actions that already existed*, which is why they are one small batch.

### Open Themes Folder

*"i want to create a new .theme file but not sure where the themes folder is on my machine."*

The cause was sharper than "undiscoverable": **for that user the folder did not exist.** `theme.odin`
deliberately does not create `%APPDATA%\Newtpad\themes` at startup — a bare read of `settings.txt` was
`mkdir`-ing it for everyone who had never touched a theme — so someone following the Settings row's
advice found nothing there and could not tell a wrong path from an empty right one.

So the fix is `themes_dir_**ensure**`, not `themes_dir`: asking for the folder is exactly the moment
it should come into existence, which is the distinction those two procedures were split over. This is
their first caller that is a user action rather than a write. Modelled on `Open_Logs_Folder`, which
exists for the same reason — the 2026-07-25 audit found logging on by default with no way to reach it.

Placed next to `Theme_Edit` in the View menu rather than at the end: someone who has just edited a
theme is the person who needs to know where theme files live.

### The tab strip's context menu

*"if you could right click the tabs to open the folder it's located in."* The action already existed —
`plat.shell_reveal` is what a non-text link resolves to — and there was **no right-click on the strip
at all**.

**Four rows, decided once with Wyatt before building**, because `requested-features.md` warned that a
tab menu invites every other per-tab command and principle 3 says fight options: Reveal in Explorer,
Copy Full Path, Close Tab, Close Other Tabs. Pin and Close to the Right were considered and left out —
pin is real state with its own ordering rules, not another row.

**The target is the whole design.** A right-click does **not** activate the tab it opens on, so every
row and every command resolves through `app.menu.ctx_tab` and never through the active document. A
menu that read the active document would explain, grey out and act on the wrong file whenever the two
differ — and closing the wrong tab is the version of that mistake that costs something. `ctx_tab` is a
**slot**, not a display index, because two of the four rows close tabs and a display index does not
survive that.

`Tab_Close_This` is deliberately a separate command from `Tab_Close` (Ctrl+W): the same words mean
different tabs. Both are in `command_needs_menu_target`, so a keymap line naming one is refused for
having no target — the same rule the six sort commands follow.

The file rows are **greyed with a reason** rather than hidden. A menu that changes shape per tab
defeats muscle memory, and the disabled-reason column already existed for exactly this.

### A latent crash found by the test, not by the feature

`request_close_tab` dereferenced `w.hwnd` with no nil guard, while its neighbours in the same file
(the lossy-encoding confirm, the reopen confirm) all use `w.hwnd if w != nil else nil`. Every
production caller passes a window so it was unreachable in the product — and driving it from a test
mode with a dirty tab is an **access violation**, which is how it surfaced. Fixed to match its
neighbours.

Two fixture lessons came with it, both recorded because they will recur: a test that closes tabs must
**activate** them first (`app_close` picks the next tab off the MRU and opens a fresh scratch when
that list empties, so a fixture where only one tab was activated grows a third tab on the first
close), and a test that closes tabs must use **clean** documents unless it means to answer a discard
dialog — `doc_from_content` marks every buffer it builds as modified.

### Owed, and reported during this batch

Two tear-off defects from live use, in `reported-bugs.md` and **not fixed at Wyatt's direction**:
dragging a tab into the viewport does nothing (the detach gesture only fires outside the *window*,
which was the option chosen at scoping and is the wrong one in use), and dragging the **only** tab
spawns a second window and leaves an empty scratch behind (the refusal asks about the document and
never about the strip). They interact: making the viewport a detach region without fixing the
single-tab count makes the second far easier to hit.

## 6bk. Format JSON (2026-08-02, v0.44.0)

Third in Wyatt's order. Requested 2026-07-30 with a `.log` file that is one unreadable line and a
`tasks.json` showing the wanted result: **VS Code's Format Document, for JSON.**

### It reopens a locked decision, deliberately

HANDOFF §6aa put first-party JSON/CSV/XML reformat **out** of V1 and held it as the V2 plugin proof —
the thing that demonstrates the C-ABI formatter boundary works. Wyatt's call, asked directly:
**build it into V1.** The plugin system can prove itself on a viewer, or on a formatter for a
language Newtpad has no lexer for. A feature he wants beats a demo that does not exist yet.

### A rewrite, not a parse

There is no AST, no map, no value type. The input is walked token by token and re-emitted with
newlines and indentation between them, and that is the **requirement** rather than a shortcut: key
order must be preserved, and parse-to-map-and-re-emit loses it. It also means a number is re-emitted
as the bytes the file had, so `1.50` and `1e3` survive as written instead of round-tripping through a
float, and a string is emitted verbatim rather than re-escaped — `\uXXXX`, lone surrogates and
everything above ASCII are decisions that can change what the file means, and the formatter's job is
whitespace.

**It shares the lexer's scanners.** `lj_scan_string`, `lj_scan_number` and `lj_scan_keyword` went
package-visible for this and nothing else. The highlighter and the formatter must agree byte for byte
about where a string ends — an escape rule differing by one byte is enough to colour one span and
rewrite another. That is what makes *"do not write a second JSON parser"* true rather than
aspirational, and the test that pins it is `{"a":"{\"b\":1}"}`: structure inside a string is text.

**Unlike the lexer, it validates.** `lex_json`'s header says it *"colours, it does not validate"* —
an unterminated string colours to the line's end, an unbalanced brace is just punctuation. Right for
colouring, wrong when the output replaces the user's file.

**Four positions, not a bool.** The state is `Value | Key | Colon | Sep`, because an object has four
and a bool cannot tell a key from a value — with a bool, `{"a" 1}` reads as two values in a row and
formats happily into something that is not JSON. That was caught by a test, not by reading.

### Edit, with a ceiling

Wyatt's call again: format the buffer, not a view. **64 MB**, not `BACKUP_MAX`'s 128, because the
output is *larger* than the input by exactly what the command adds, and the peak holds the source, the
output and the piece tree's copy at once. Refusing loudly is the house style — `table_sort_build`
refuses past 100,000 rows and the summary row says so.

Invalid JSON is **marked, not silently refused** (§10's rule for malformed CSV rows): the buffer is
untouched, the caret moves to the offending byte, and the note names what is wrong there.

### Two things a sabotage pass found, and neither was the thing being sabotaged

- **The format buffers were on the frame's temp allocator.** Removing the ceiling to check the test
  could fail revealed the refusal coming back as *"unexpected character"* rather than a size refusal —
  the temp arena could not serve the allocation. Both buffers are on the heap with explicit frees now,
  which is the argument `table_sort_build`'s comment already makes: the temp arena is freed but never
  **shrunk**, so one format of a 60 MB file would leave a ~190 MB high-water mark for the process's
  life.
- **The ceiling test was vacuous**, twice over. "The buffer is untouched" is satisfied by *any*
  refusal, so it passed with the ceiling deleted; it now asserts the **note**, which says which guard
  fired. And its fixture was built on the temp allocator, so it was over the ceiling by length while
  being malformed by content — over-the-ceiling for the wrong reason. Built on the heap now, and with
  the ceiling removed all three of its assertions fail.

Also caught, and worth repeating because it is in development-loop §6 and I did it anyway: piping
`build.bat` through `Out-Null` without checking `$LASTEXITCODE` ran a **stale exe** and made a
sabotage look uncaught.

### `jsontest` is new

One argument, exits non-zero, in §7's list. The **formatter** is unit-tested in `src/base` (shapes,
key order, escapes, idempotence, every refusal, the depth bound, error offsets) — 218 base tests now.
`jsontest` covers only what those cannot see: that the command writes the buffer, that it undoes, that
an invalid file survives with the caret on the fault, and that the ceiling refuses.

One behaviour worth knowing: an **untitled** buffer is offered the command. `path_has_ext` answers
true for an empty path on the stated rule that a new buffer *"is allowed into any view — you don't
know what it will become"*, and JSON pasted into a scratch tab is exactly when someone reaches for
this. `.jsonc` is deliberately excluded: it permits comments the formatter refuses.

## 6bl. The JSON ceiling was argued, not measured — and the tab menu's dead first row (2026-08-02, v0.45.0)

Both from Wyatt within minutes of v0.44.0.

### *"how realistic is the 64MB limit... i feel like we often have double that size as average"*

He is right, and the failure is a process one worth naming: **`JSON_FORMAT_MAX` was picked by
reasoning about allocation and never measured.** The reasoning was coherent — the output is bigger
than the input, the piece tree copies it, so be conservative — and it produced a number that refuses
his *typical* file.

`newtpad jsonperf <file>` now answers the question instead. On a realistic 128 MB minified export:

```
input 128.0 MB  ->  output 264.5 MB (2.07x),  format 2126 ms,  peak 529 MB
```

So his average file costs about **two seconds and half a gigabyte**. That is a real pause and an
acceptable one for a deliberate action on a file that size; it is not a reason to refuse. The ceiling
is **256 MB**, giving that average 2x headroom and putting the worst case near four seconds and a
gigabyte.

**The peak dropped by 128 MB for one moved line.** `src` was freed by `defer`, so it stayed live
across `doc_replace_range` — which makes the piece tree's own copy of the output — putting
`src + 2*out` in memory at once. Freeing it the instant the format returns takes the 128 MB case from
657 MB to 529 MB.

**The ceiling test had to change shape.** It drove the command end to end through a fixture built just
over the limit, which was honest at 64 MB and is not at 256: padding, concatenation and the
document's copy come to roughly three quarters of a gigabyte of transient allocation *on every
sweep*. The boundary is now asserted on `json_format_too_large`, the predicate the command itself
calls, at exactly the limit and one byte past it.

### The tab context menu's first row was dead

*"the right click on tab does not open explorer to the path"*

**`menu_hit_test` claims the whole band `[TAB_STRIP_H, TAB_STRIP_H + MENU_BAR_H)` for the menu BAR
before it looks at any open dropdown.** The tab menu was anchored at `TAB_STRIP_H`, so its first row
sat inside that band: clicking it read as "empty bar area", closed the menu and ran nothing. It was
always the first row, whichever row that was — Reveal happened to be first.

The anchor moved to `TAB_STRIP_H + MENU_BAR_H`, and — the part that matters for next time — **the y
is now `menu_open_tab_ctx`'s, not the caller's.** It was a constant at a call site no test could
reach; it is a property of the menu, and `surfacetest` asserts it. Sabotaging it back to
`TAB_STRIP_H` fails that assertion with `40, needs >= 70`.

### Right-click now activates the tab

*"if you right click a different, non-active tab i think it should swap to that tab as a visual
queue"* — which reverses §6bj's decision that "a right-click is a question, not a switch". He is
right: a menu whose rows say *Close Tab* and *Reveal in Explorer* while a **different** tab is
highlighted gives the reader nothing to bind those words to.

**The `ctx_tab` targeting stays and is not now redundant.** It is what makes the rows correct in the
frame before the activation lands, and it keeps the four commands honest about which tab they act on
rather than depending on a side effect of opening the menu.

### The recurring process failure, twice in one batch

`development-loop.md` §6 says to build through PowerShell and check `$LASTEXITCODE`, because a piped
build can leave a stale exe and make a sabotage look uncaught. **It happened twice here** — once
piping through `Out-Null`, once building from Bash with output discarded — and both times the
conclusion drawn from the stale binary was wrong. The rule is not about the shell; it is that a
sabotage result is only evidence if the binary is known to be new.

## 6bm. Format JSON gets a chord, and stops being gated on `.json` (2026-08-02, v0.46.0)

*"json formatting worked, it needs a keybind though"* — **Ctrl+Alt+F**.

VS Code's Format Document is Shift+Alt+F and **that cannot be expressed here**: `Binding` has no
`shift` field, which is the same reason Save As is Ctrl+Alt+S rather than Ctrl+Shift+S. Ctrl+Alt+F is
its nearest expressible neighbour and keeps the F. Only Ctrl+Alt+Enter and Ctrl+Alt+S were taken.

### The extension gate was wrong, and the request said so

Adding the chord surfaced it: the command was gated on `doc_can_json`, which meant `.json` only — and
Wyatt's original request was illustrated with **a `.log` file that is one enormous unreadable line**.
The gate excluded the motivating example.

An extension is a good gate for a **view**, where entering the wrong one wastes a keystroke and
nothing else. It is the wrong gate for a command whose failure is already informative: pressing this
on something that is not JSON says so and puts the caret on the first byte that is not. JSON turns up
in `.log`, in `.txt`, in a scratch buffer pasted from a terminal, and in files with no extension.
`doc_can_json` is now "any text document", the `.jsonc` carve-out is gone with it, and the disabled
reason it carried is deleted rather than left saying something untrue.

### A latent hazard noticed while sabotaging

Binding Format to Ctrl+F (to check the test could fail) did **not** shadow Find — `resolve_key`
returns the FIRST match and Find_Open is declared earlier, so the duplicate was simply dead. That is
a silent outcome either way: a hand-written keymap that duplicates an existing chord gets no
diagnostic, it just does nothing. Not fixed, and worth knowing before someone debugs a binding that
"does not work".

## 6bn. Format Document: CSS, SCSS and XML join JSON (2026-08-02, v0.47.0)

*"go ahead and all css/scss and xml... add js for later future request"*.

**One command, three formatters.** `Format_Json` became `Format_Document`, still on Ctrl+Alt+F, and
`format_kind_for` picks: extension first, then the first non-space byte of the buffer. The sniff is
the original request — the `.log` file that motivated JSON has no extension to go on — and it also
covers a scratch buffer pasted from a terminal. **Extension wins over content**, so a broken `.json`
still gets the JSON error pointing at the byte that is wrong, rather than "I don't know what this is".

**CSS is guessed from content only by its extension, never by sniffing.** A stylesheet can begin with
a letter, a dot, a hash, an `@` or a comment, none exclusive to it — claiming every file that is not
JSON or XML is how a formatter comes to rewrite somebody's prose.

### CSS/SCSS: one lookahead, and SCSS comes free

Whitespace is never significant in CSS, so the same token-re-emitter shape as JSON works. SCSS is not
a second mode: nesting is more `{}`, `$vars` and `&` are ordinary tokens, and the only real addition
is the `//` comment.

**The one hard part is that `:` and `,` each do two jobs.** `a:hover` must not become `a: hover`,
while `color:red` must. The rule is a bounded forward scan at paren depth 0: a declaration ends at
`;` or `}`, a selector ends at `{`, and whichever comes first decides. SCSS sharpens it, because
there a selector and a declaration live in the same block. Similarly `,` breaks a selector list onto
separate lines but must stay inline inside `rgba(0, 0, 0, .5)` — paren depth answers that one.

**Only comments read the source's newlines.** Everything else is deliberately reflowed, but a
comment's placement is authorship: a licence header sits on its own line because someone put it
there, and `color: /* was blue */ red` is inline for the same reason.

### XML: the rule is narrower on purpose

This is the one where whitespace **can** be significant, and no attribute has to say so. The rule
Wyatt chose: an element whose own content is only elements/comments/whitespace is laid out; an element
with any non-whitespace text in **its own content** is copied byte for byte, whole subtree.

**Immediate level, not the whole subtree** — and the first version got that wrong. Asking about the
entire subtree meant one `<name>Ada</name>` anywhere made the whole document verbatim: perfectly safe
and completely useless. Laying an element out inserts whitespace *into that element's content and
nowhere else*, so only text directly inside it can be harmed; text three levels down is protected by
the same question being asked about its own parent.

The rejected alternatives are recorded in the file: honouring `xml:space="preserve"` amounts to
rewriting significant whitespace in the ~all documents that never set it, and a hardcoded
`pre`/`textarea` list works for HTML and guesses wrong on every other vocabulary.

### A use-after-free I introduced two versions earlier

The "already formatted" check compared `out` against `src` **after** `delete(src)` — added in v0.45.0
when the source was freed early to cut the peak. Freed memory usually still holds its bytes, so the
test could not see it. The comparison is computed before the free now.

### Not built, and it is not about effort: JavaScript

Recorded in `requested-features.md` with the reasoning. ASI, the regex-versus-division ambiguity and
nested template literals each make a token-level rewrite **unsafe rather than imperfect** — the
failure mode is silently changing what the code does, on a command that edits the buffer. It needs a
real parser and a differential test that re-parses to prove the AST is unchanged. It is now the
plugin system's best motivating example, which is what §6aa wanted a formatter for in the first place.

229 base tests (up from 218): the three formatters are unit-tested there, including idempotence for
each — pressing the command twice must equal pressing it once, and for XML that is where a naive
implementation drifts, because the newlines it just wrote look like text on the second pass.

## 6bo. Both tear-off defects (2026-08-02, v0.48.0)

The two reported against v0.41.0 and documented at Wyatt's direction. They interacted, and were fixed
together for that reason.

### Dropping into the viewport now detaches

The gesture was "the pointer left the window", chosen at scoping over "drag below the strip by a
clear margin". In use it is the wrong one: dragging a tab down into the document is what every
browser treats as a tear-off, and **on a maximised window there is barely anywhere to go that IS
outside**. Both rules are live now — the window one still catches a drag onto another monitor.

The threshold is one tab's height below the strip: far enough that a sloppy reorder cannot reach it,
near enough that dragging into the document obviously qualifies. `teartest` brackets it on both sides,
because the rule this has to stay out of the way of is the ordinary reorder.

### The only tab goes nowhere

Tearing off the last tab spawned a second window holding the document and then closed the only tab
here — which, because a window never fails to a closed state, left a **fresh empty scratch** behind.
Two windows where there was one, and the original blank.

The count is asked in `tab_detach` rather than in `tab_can_detach`, because it is a question about the
**strip** and not about the document, and it is asked before the spawn so the "spawn before you close"
ordering is undisturbed.

**The sabotage for this one spawned a real window and hung the test run** — the detached child
inherits stdout, so the pipe never closed. That is worth knowing before someone sabotages it again:
the hang IS the evidence. The stray window and the store it left behind were cleaned up by hand.

### A third thing, found while cleaning up after that

`%APPDATA%\Newtpad\windows` held an **immortal orphan**: a torn-off window's store with a valid
header, zero tabs and no backups. `session_adopt_orphans` removed a store only when the restore
*succeeded* or when `session.txt` was *absent*, so a readable-but-empty one was retried on every
launch forever.

The distinction that matters is **"could we read it"**, not "did it give us anything". A store whose
file cannot be read may still hold the unsaved work of a window that died, and deleting it on a
transient read error would destroy exactly what the mechanism exists to preserve. A store that reads
fine and holds nothing is finished business. Both cases are now explicit.

## 6bp. Column filtering — batch 20 (2026-08-02, v0.49.0)

*"would also be nice to filter columns, and have a dropdown list of all items in the column to filter
like powerbi/excel has."* The sort half shipped in v0.36.0; this is the rest, and it closes §10's
table work.

Decisions with Wyatt: **checkboxes with Select All**, **refuse past `TABLE_SORT_MAX`** (the sort's
answer and the sort's limit), **filter and sort compose**, **exclusive with `Ctrl+L`**.

### `view` is the whole design

`Table_Filter.view` is the sort's `perm` **with the hidden rows removed** — data-row indices in
display order. So the filter composes with the sort rather than being a second row model beside it,
and every consumer that already resolved a visible row through `table_sort_row_at` keeps working by
reading one more indirection. With no sort it is the same array built from file order, which is what
lets a filter exist without one.

Three producers changed and nothing else: `table_sort_rows`, `table_sort_perm_row`, `table_sort_pos`.
`table_row_start` gained one new predicate — `table_indexed` (sorted **or** filtered) — because a
filter also resolves rows through the index, and leaving it walking lines would resolve a visible row
to a **hidden** one. That is the cell editor writing to a row the user cannot see, and it is what the
seam test drives.

**The sabotage is the proof:** point `table_row_start` back at `table_sorted` and an edit to visible
row 1 lands on `a,2` instead of `c,4` — a value written to the wrong row, exactly the shape
`table_edit_line_intact` exists to catch.

### Three real bugs the tests found, none of them the feature itself

- **Zero-is-init, again.** `Table_Filter.col` started at 0, which is **a valid column**, so every
  fresh document read as "filtered by column 0", built a view over every row, and sent every row-set
  consumer down the filter path. `Sort_Key.col` records this exact trap and pays for it with an
  explicit `TABLE_SORT_NONE` reset; the filter uses an explicit `active` bool, which cannot be got
  wrong.
- **The filter outlived its own index.** `doc_index_start` clears the sort — which empties `offs` —
  and `view` indexes into `offs`. A live filter over an empty index is every row resolving to nothing.
  Every site that invalidates the row index now clears the filter with it: the two share `offs`, so
  they share a lifetime.
- **A re-sort left a stale view.** `perm` is rebuilt and `offs` with it, so a live filter is
  re-applied at the one place `perm` is produced — not in each of `table_sort_set/add/drop/cycle`,
  which is four chances to miss the fifth.

### The dropdown is the context menu, not a new widget

`Menu_Item` gained a `payload`, and `checked` now takes the item — so a **generated** row set can say
which value each row is. The filter's dropdown is then the same draw, hit-test, scroll, keyboard and
edge clamp the header and tab menus already use, instead of a second scrolling list with its own bugs.

The rows live in an **App-owned** buffer, not the frame's temp allocator: `menu_open_ctx` keeps the
slice and a menu survives into the next frame, which its own comment names as the trap for exactly
this kind of caller.

`(Select All)` is a **three-way** control: ticked means everything shows, so pressing it while ticked
hides everything — which is what you press before picking two values out of two hundred.

### The summary row says how many are HIDDEN

Not a filtered count, because `table_row_count` walks lines and knows nothing about a filter. A grid
showing 12 rows under a line reading "4,000 rows" reports a different file; "4,000 rows · filtered by
status (3,988 hidden)" is two facts that reconcile. It sits outside the clickable run, which already
means "clear the sort" — one target cannot mean two things.

### Owed

- The filter is **not persisted** in the session. The sort is not either, and for the same reason
  (`Doc_View` carries neither), so this is consistent rather than an oversight — but a filter is more
  expensive to rebuild by hand than a sort.
- ~~A value list is capped at `TABLE_FILTER_VALUES_MAX` (512) and the scan is linear over the distinct
  set, so a column with thousands of unique values stops adding rather than degrading. Values past
  the cap are **kept**, never hidden — hiding rows on the strength of a list that stopped early would
  remove data the user was never shown a checkbox for.~~ **Paid off in §6br, one day later, after it
  turned out to be reachable on a 1,000-row CSV.** This entry is the reason the bug survived review:
  it reads as a bounded, deliberate trade, and the number that makes it a *defect* rather than a
  trade — how many rows a truncated list leaves uncontrollable — is not in it.

## 6bq. The filter dropdown, made usable (2026-08-02, v0.50.0)

Four complaints against v0.49.0, all about the dropdown rather than the filtering under it:

> *"on the filter, there's no scroll bar, it shouldn't be the full vertical height of the window...
> something reasonable"* — *"when you click it the menu goes away and it doesn't look like it actually
> filters anything"* — *"there should also be a search bar of sorts in this menu of the column
> choices... it's annoying to scroll to find the one you need"*

### The click bug was a reopen bug

`.Table_Filter_Open` re-scanned the column and re-ticked every value **on every invocation**, and the
command that ticks a row reopens the dropdown. So a tick was applied and then immediately erased by
the reopen — the grid really did filter, for less than a frame. It now early-returns when the same
column already has a live filter, and only the dropdown is reopened.

The other half was `menu_hit_test` closing the menu on any pick. `command_keeps_menu_open` names the
two commands that must not (`.Table_Filter_Toggle`, `.Table_Filter_All`) — a checkbox list you have to
reopen after every tick is not a checkbox list.

### The row cap applies to generated lists only, and menutest is why

`MENU_MAX_ROWS` (12) shipped unconditional in the first build of this fix. The **Edit** menu is twelve
commands and five separators — fourteen rows' worth — so Font became an unreachable row again, which
is the precise bug the `more_above`/`more_below` arrows were added for. `menutest`'s hover probe caught
it within the same sweep.

The cap now applies only when `menu_is_filter_dropdown` holds. A hand-written menu cannot run away —
a person typed every row of it — and only the window-height clamp has ever applied there. Both halves
are pinned: `menutest` asserts every bar menu gets its full height on a tall window, `tablesorttest`
asserts a sixty-value list is capped at twelve rows on a 2000px one. Reapplying the cap
unconditionally fails the first; removing it fails the second.

With a cap there is finally something to scroll, so the dropdown grew a proportional scrollbar
(drawn, not draggable — the wheel and arrows are how you move) and `menu_wheel`, which is the mouse
route into `menu.top` that the scroll state had lacked since the day it was written.

### The search box is an ITEM, not a band

`Menu_Item.text` makes a `.None` row a **label** instead of a rule. That one field is the whole
mechanism: `item_enabled` already refuses `.None`, `menu_item_at` already returns −1 for it, and
`menu_step` already walks past it — so the search box is un-pickable, un-highlightable and correctly
clipped without a line of new machinery.

A band above the rows was the alternative and would have threaded its height through
`menu_dropdown_rect`, the draw, the hit-test, `rows_fitting`, `menu_wheel` and `menu_scroll_to_item`.
Six consumers of one coordinate is the shape of every seam bug in this file. `item_h` is the only
procedure that learned anything, and sabotaging it back to separator height fails four assertions —
including *a click on the first value row hit-tests to it (4, want 3)*, which is a tick landing on the
wrong value.

**The payload is the true value index, never the row's position.** A search that hides rows therefore
cannot make a click tick the wrong value. Sabotaged to a running position, five assertions fail.

Typing routes through `menu_filter_query_rune`, checked **first** in main.odin's character drain — the
dropdown is on top of everything and, unlike a bar menu, has a field. Backspace needs its own
`.Menu_Search_Back` command rather than a `.Menu`-context binding of `.Backspace`: main.odin closes the
menu on any non-menu chord, so binding the editor's Backspace here would dismiss the dropdown *and*
delete a character from the document behind it. Both refuse when there is nothing to take, so an open
menu never silently eats an edit.

`(Select All)` is deliberately **not** filtered by the query — "type three letters, Select All" means
all of the matches, which is the operation the search exists to make possible. The query is cleared on
every open and close; a stale one would silently pre-filter the next column with a word that has
nothing to do with it, and `tablesorttest` fails on one leftover byte.

### Owed

- The search row scrolls off the top like any other row. Pinning it would mean the draw emitting a row
  the hit-test computes differently, which is the trade this design exists to refuse. Revisit only if
  a long list makes it actually annoying.
- The match is ASCII case folding, hand-rolled. A Unicode fold is a table this layer has no business
  carrying; the values are the column's own text.

## 6br. Five filter-dropdown defects, and the one that was two (2026-08-02, v0.51.0)

v0.50.0 shipped that morning. Wyatt drove it on `customers-1000.csv` and came back with five
complaints:

> *"scrollbar direction in the filter menu is wrong. when you filter, and deselect all it shows rows
> still, it should hide anything other than the filter. when you select something it does go to the
> top but there are the other unfiltered rows below there. in the filter menu if you click in between
> options it closes the modal. i think the names/numbers in the modal should be alphabetical/numerical
> ascending"*

### Two of the five were one bug, and the arithmetic identified it before any code was read

`TABLE_FILTER_VALUES_MAX` stopped the distinct list at 512; `keep()` deliberately **kept** any value
the list never saw. Together: on a column with more than 512 distinct values, rows carrying the 513th
onward are visible under **every** selection, including none of it.

```
customers-1000.csv, column "First Name":  536 distinct
listed distinct:              512
rows with an unlisted value:   27
first such row: 925    last: 1000
```

His screenshot read `1,000 rows · 12 columns · filtered by First Name (973 hidden)` over 27 rows
numbered 925 → 1000. Not a near match — the arithmetic. "Deselect all still shows rows" and "the other
unfiltered rows below there" are the same defect seen twice: values are collected in first-seen order,
so the cap is hit partway through the file and every unlisted value lives in its **tail**. That is why
it read as the grid giving up below a certain row rather than as a membership bug, and it is the most
useful thing in this entry — *where* the survivors clustered was the evidence that named the cause.

### The cap is gone, not raised, and the reason is that it never bought what it claimed

Its comment said it existed because the distinct scan is quadratic. True, and it bounded a **second**
scan nobody had noticed: `keep()` was also linear over `values`, and `keep()` runs on every checkbox
click rather than once per open. One `map[string]int` deletes both, and with it the cap's entire
justification. The remaining ceiling is the one already doing the work — `TABLE_SORT_MAX` refuses to
filter past 100,000 rows, and a 100,000-row file has at most 100,000 distinct values, so there is no
unbounded case to defend.

Wyatt proposed PowerBI's "5k then Load more" and was talked out of it, which is worth recording
because the argument generalises: **load-more would have reintroduced this exact defect as a design
feature.** A partial load is a value with no checkbox, and `(Select All)` becomes ambiguous about
whether it means the loaded 5,000 or all 40,000. PowerBI needs paging because its list is a remote
query over a dataset it does not hold; ours is a local scan of a file already mapped, so the pattern
would have been imported without the constraint that produced it.

### The list ascends now, which overrules a comment that argued the other way

`Table_Filter.values` said first-seen order was deliberate — "the list is a picture of the column, and
sorting it hides whether the data is grouped" — and `ts_case_filter` asserted it. Both were amended
rather than worked around. The old argument was not wrong about what first-seen order *shows*; it was
wrong about what the list is *for*. Nobody reads a 536-row checkbox list as a picture of a column;
they look for one name in it.

Numeric columns compare numerically, decided by `table_is_number` over every non-empty value — the
same predicate `table_sort_build` settles each sort key with, deliberately, so the two features cannot
come to disagree about which column is a number column. Text folds case with a case-sensitive
tiebreak, because without it `"ABC"` and `"abc"` are mutually not-less and the list reshuffles between
two opens for no visible reason. Blanks last, which is **not** the sort's empty-follows-the-arrow rule:
that exists because a sort has a direction, and this list has none.

It happens once, at the end of `table_filter_open`, **before `f.active` is set**. That ordering is
load-bearing and is written down in both places that depend on it: `Menu_Item.payload` indexes
`values`/`on`, so a reorder after a tick existed would re-point every checkbox — tick `Alvin`, hide
`Andrew`. The other half of the guarantee is in commands.odin, where reopening an already-filtered
column deliberately does not rescan. Either fact changing alone breaks the other.

### Two seam bugs, both the same shape, and the second was found reviewing the first

`menu_item_at` returns −1 for two unrelated situations — outside the menu, and on a row that cannot be
picked. `menu_hit_test` had only that one sentinel, so a click on the separator was read as a click on
the document and dismissed the menu. `menu_dropdown_hit` answers the second question from the same
`menu_dropdown_rect`, and the dropdown branch became three outcomes instead of two.

Writing that comment produced the claim that the **scrollbar strip** was one of the regions reaching
the dead-space path. Checking it before shipping the sentence showed the opposite: the strip is drawn
at `x0 + w - bw`, *inside* the dropdown's width, and `menu_item_at` bounded x by the full `w` — so a
click aimed at the thumb resolved to the row behind it and **ticked a value**. Sabotaged, that click
returns `.Table_Filter_Toggle` instead of `.None`.

Latent because it needs a list long enough to scroll, which the value list rarely was at 512 and
always is now — the same shape as the `doc_close` leak below. `scrollbar_w` is now one producer for
"is there a strip and how wide", consumed by the draw that paints it and the hit-test that refuses it.

**The lesson is not about scrollbars.** A comment asserting something about a *sibling* region of the
widget it documents is a claim, and checking it cost two minutes and found a real defect. Both bugs in
this section are development-loop.md §4 Shape B.

### `doc_close` never freed the filter

`table_sort_free` sat alone on that line for the whole life of the feature: `offs`, `perm` and `rank`
were released, and the filter's clone-per-distinct-value, three arrays and map were not. Bounded at
512 small strings while the cap existed; unbounded to `TABLE_SORT_MAX` the moment it came off. Fixed
in this batch rather than filed, because this batch is what made it matter.

### The wheel

`plat.Window.scroll_delta` is `+down / −up`, and every other consumer in the tree adds it —
`doc.filter_top`, `doc.h_scroll`, `doc.table_hscroll_px`, `doc_scroll`'s row step. `menu_wheel` was the
one subtractor. The thumb was never wrong; it tracks `menu.top` faithfully, and `menu.top` ran
backwards. The test asserts the **sign**, because one asserting only "top changed" passes against the
bug — and under the sabotage one of its four assertions did pass by coincidence, which is the argument
for asserting more than one point on a scroll range.

### What this batch got wrong

- **The design doc shipped a claim about the scrollbar that was false**, and it was only caught because
  writing the same claim into a code comment prompted a check. The doc is corrected, but the lesson is
  that a spec written from investigation carries investigation's unverified asides into the code.
- **The uncapped-values test crashed rather than failed under its own sabotage.** With the cap
  restored, `f.on[599]` on a 512-entry array faults with `0xC000008C` — so the four FAIL lines printed
  and then the run died before the rest of the suite. Now guarded. A test whose failure mode is a
  bounds fault reports less than one whose failure mode is a message, even though neither is green.

### Owed

- **The `▲`/`▼` arrows have the scrollbar's old problem and keep it deliberately.** They are drawn at
  `x0 + dw - sx(16)`, left of the strip and over row text, so clicking one ticks the row behind it.
  Left alone because they are muted `UI_SMALL_PX` glyphs with no button affordance — a click there
  reads as aimed at the row — and excluding them would carve a dead notch out of the middle-right of
  two rows, which is worse than what it fixes. Revisit only if they ever become clickable controls.
- **The filter is still not persisted in the session**, unchanged from §6bq.
- `dropdown_w` and `menu_dropdown_rect` walk every item to find the widest row, and are called several
  times a frame. At the old 512 cap that was invisible; at 100,000 values it is ~1 ms/frame of pure
  measurement. Not measured under load yet, and the fix if it bites is a width memoised on
  `menu.ctx_items` (the only two places it changes are `menu_open_ctx` and `menu_filter_requery`).

## 6bs. The dropdown's scrollbar becomes a control (2026-08-02, v0.52.0)

> *"scroll wheel works, scrollbar doesn't in that modal"* (Wyatt, live use of v0.51.0)

### §6br removed the objection that was blocking this

The bar shipped in v0.50.0 as **drawn, not draggable**, and its comment gave the reason: a drag
*"would need its own hit-test inside a surface whose every other pixel already means 'pick this
row'"*. That was true when it was written and stopped being true one release later — §6br excluded
the strip from the row hit-test to stop it ticking checkboxes, which is precisely the "own hit-test"
the objection said was missing. **The blocker had already been removed as a side effect of fixing
something else, and nobody noticed until Wyatt tried to drag it.** Worth watching for: a
*"deliberately not done"* comment can be invalidated by an unrelated change, and nothing re-reads it.

### It reuses the document's bar rather than deriving a second one

`vbar_grab_at` and `vbar_frac_at` are used verbatim on a `Vbar` built by `menu_vbar`. Their
exact-inverse property — press the thumb, hold perfectly still, the list does not move — was paid for
once on the editor's bar after an earlier version disagreed with its own inverse by
`track_h / (track_h - thumb_h)`. Re-deriving it here in row units would have been re-buying it, and
main.odin's comment on `vbar_frac_at` asks for exactly this: the bars map onto different models, and
the only thing keeping them honest is that the pointer-to-fraction half is identical. Sabotaged
(`scroll_grab = 0`), pressing the thumb jumps the list six rows.

A press on the bare track **jumps** rather than paging, because that is what `vbar_grab_at` returning
0 already means for the document's bar — Wyatt asked for it to *"act like the regular vertical
scrollbar"*, and one bar in the app behaving differently is worse than either rule.

### `menu_vbar` is now the one producer, and it fixed a latent disagreement

Four consumers: the draw, `menu_item_at`'s lane exclusion, the drag's press, and the drag's step.
Building it exposed that the thumb's position was derived in the draw from `total - app.menu.rows`,
which is **not** the range a drag can reach — rows are not all one height (a separator is 0.4 of one),
so the reachable last-top depends on where you start. `menu_scroll_last` is now the single definition
that `menu_wheel`, the thumb's position and the drag's mapping all use, so "the thumb hits the bottom
exactly when the last row is on screen" is a property rather than an arithmetic coincidence.

The bar is 8 wide in a 12 lane (`MENU_SCROLLBAR_W_96` / `MENU_SCROLLBAR_LANE_96`), the same
drawn-versus-grabbable split `SCROLLBAR_W_96` (14) and `SCROLLBAR_TRACK_W_96` (8) make for the
document. 4px was unhittable; collapsing the two numbers means choosing between an ugly bar and an
unhittable one.

### The one trap, and it is documented in the file it came from

`menu_scroll_mouse` clears `window.mouse_pressed` and **never** `window.mouse_down`. `mouse_down` is
persistent platform state, and zeroing it mid-gesture kills the drag twice over: the latch sees
`!mouse_down` next frame and clears itself, and `WM_MOUSEMOVE` only updates the pointer while the
button is held, so the coordinate stops moving too. That is verbatim the bug `Drag_Latches`' comment
records for the grid's horizontal bar (v0.17.1). Sabotaged by adding the clear, the drag moves on the
press frame and then freezes — `top 0 + 12 visible` after dragging to the bottom — which is exactly
how Wyatt described that older bug.

The consequence is that `app.menu.scroll_drag` has to be excluded **at** main.odin's caret branch
rather than by consuming the event, joining the four latches already listed there. It also joins the
`polling` set, or the list only moves when some other event happens to wake the frame loop.

The latch lives on `Menu_State`, not as a main.odin local like `scrollbar_drag`, so `menu_close` can
end it: Escape mid-drag would otherwise leave it set with no dropdown under it.

### Owed

- **`menu_scroll_last` is O(n · rows) and is now called several times a frame** (the draw, the
  hit-test, and each drag step), joining `dropdown_w`'s existing per-frame walk. At Wyatt's 536-value
  list that is ~28k operations a frame — nothing. At the 100,000-value ceiling the filter now permits
  it is several milliseconds, and it would be the first thing to fix if a huge column ever feels
  sticky. Both are the same fix: memoise on `menu.ctx_items`, which changes in exactly two places
  (`menu_open_ctx` and `menu_filter_requery`). Not done now because nothing has measured it.
- The `▲`/`▼` arrows still hit-test to the row behind them, unchanged from §6br and for the same
  reason.

## 6bt. The draw owned `top`, so the drag did nothing (2026-08-02, v0.53.0)

> *"the scrollbar still does not work on that modal"* (Wyatt, live use of v0.52.0)

**§6bs shipped broken with every one of its assertions green.** That is the whole value of this
entry, and the failure is not the scrollbar — it is what the tests were allowed to skip.

### What was actually wrong

`menu_draw_dropdown` calls `menu_scroll_to_item` on **every frame**, which pulls `top` to wherever it
must be for `menu.item` to stay visible. `menu_open_ctx` sets `item` to the first enabled row —
`(Select All)`, index 1. So a drag to row 51 was reverted to 1 before the frame reached the screen,
every frame, forever.

**The wheel escaped it by luck, which is why the bug looked like it was about the scrollbar.**
Wheeling holds the pointer over a row, and `menu_hover_item` retargets `item` to that row each frame,
so the pull is a no-op against a highlight that is visible by construction. Dragging holds the pointer
on the scrollbar's *lane* — which §6br had just taught `menu_item_at` to refuse — so `item` stayed
stale and the pull was not a no-op. **§6br's fix is what exposed §6bs's bug**, and neither is wrong on
its own.

### The rule that was already written down

CLAUDE.md: *"scroll resolution must not happen inside the draw."* It was, and had been since the
dropdown first outgrew a short window. Nothing noticed while the only thing that moved `top` was the
highlight itself — the draw and the input phase agreed because there was only one writer. The moment
a second writer existed, the draw won every argument.

`menu_scroll_to_item` is now **edge-triggered**: it fires when the highlight *moves*, not on every
frame it is drawn. "Keep the highlighted row visible" is a rule about a transition; applied every
frame it silently becomes "the highlight must be visible at all times", and those are different rules
with the same name. `item_scrolled` records what `top` was last resolved against, with `-2` as the
never-resolved sentinel at each of the five places that reset the highlight.

### Why the tests passed, and what they now do

Every assertion in §6bs drove `menu_scroll_mouse` and **never drew**. The drag worked perfectly in a
world with no draw. Three things came out of fixing that:

1. The regression test calls `menu_scroll_to_item` — what the draw calls — not `menu_resolve_top`.
   The pure resolver still answers *"pull it back to 1"*, correctly; the question was never what it
   returns, it was whether the draw is entitled to ask. A test that could only reach the resolver
   could not see the bug at all, so the procedure lost its `@(private = "file")`.
2. The test has to **model a frame having already drawn** before the drag. Without that it opens and
   drags before anything rendered, which no user can do, and it fails on the legitimately-owed first
   resolve rather than on the bug.
3. It asserts **both directions**. "The draw leaves a dragged list alone" is satisfied just as well by
   deleting the feature, which would break arrow-key navigation through any list taller than its box —
   so it also asserts that moving the highlight still scrolls it into view.

Sabotaged back to level-triggered: `top 1, dragged to 51`.

### What this batch got wrong

- **Shipping §6bs at all.** The gap between "menu_scroll_mouse sets `top`" and "the list moves on
  screen" is a whole frame's worth of code, and nothing in the suite crossed it. I told Wyatt the
  untested case was main.odin's *ordering*; it was the draw, one layer further on.
- **The pattern to take from this:** when a change adds a second writer to a piece of state, the test
  that matters is not "does my writer write" — it is "who else writes this, and who wins". `top` had
  exactly one other writer and it ran later every frame.

### Owed

- **`menu_scroll_to_item` still runs inside the draw.** Edge-triggering removes the bug, not the
  CLAUDE.md violation. The real fix is calling it from the places that move the highlight — `menu_step`
  and the keyboard handlers — which need the dropdown height, hence the rect, hence `t` and the window
  dimensions. Worth doing with the renderer/ui extraction rather than alone.
- `menu_scroll_last`'s cost, unchanged from §6bs.

## 6bu. The grid ate the drag, and the arrows sat on the bar (2026-08-02, v0.54.0)

> *"clicking the bar works not but not hold and drag, also it looks liek the arrows are underneath
> it?"* (Wyatt, live use of v0.53.0)

### The drag: a latch that lived outside the struct built to catch it

`ro_surface_swallows` zeroes `window.mouse_down` on every press over a read-only surface, and
**the grid is one**. `Drag_Latches` exists precisely so a cross-frame drag can veto that — its
comment records the v0.17.1 bug where `hscroll` was missing from the list and the grid's horizontal
bar *"moved on click and froze on drag"*. That is verbatim this report, one latch later.

`app.menu.scroll_drag` was never a field of `Drag_Latches`. The press frame worked (the scrollbar runs
before the swallow), and the swallow killed `mouse_down` before the next frame, so the drag ended
after exactly one frame. **The filter dropdown only ever opens over the grid, so this was not an edge
case for it — it was the only path**, which is why the feature looked completely dead rather than
flaky.

**The guard that should have caught this is real and did not fire, and that is the lesson.**
`hscrolltest` enumerates every latch and is protected by `#assert(size_of(Drag_Latches) == 5)`, so a
new *field* cannot go untested. But the assert only fires when the struct changes, and v0.52.0 added
the latch as `app.menu.scroll_drag` and never touched the struct. **The invariant enforced is "every
field is tested"; the one needed is "every cross-frame drag latch is a field."** The assert (now 6)
and the enumeration say so in as many words now. Sabotaged by dropping `menu_scroll` from the
predicate: `hscrolltest` fails 3/3 and exits 1.

I also swept the wrong list. `hscrolltest` is named in §7's required modes and was not in the
ten-mode list I had been running from the batch's own plan — so the one mode that covers this exact
seam went unrun for two releases. The sweep for this batch was the full §7 list, 48 modes.

### The arrows are gone, and that is subtraction rather than relocation

They were drawn at `dw - sx(16)` while the bar's lane starts at `dw - sx(12)`: a muted glyph sitting
across the thumb's travel, exactly as Wyatt saw. Moving them left would have put them back over row
text, which is where they already hit-tested to the row behind them (§6br's Owed).

Removing them costs nothing, and that is **checkable rather than a matter of taste**: an arrow drew
when `top > 0` or `top + rows < len(items)`, and either makes `len(items) > rows` true, which is
exactly when the scrollbar draws. The arrow set was a strict subset of the bar's, so the bar says
everything they said and adds how much and where — and now it can be grabbed. They existed because
for one release there was nothing else to say it.

### What this batch got wrong

- **Three releases to fix one feature**, and each fix exposed the next layer: the row hit-test
  (§6br) → the draw owning `top` (§6bt) → the frame owning `mouse_down` (here). Each was a different
  procedure claiming the state the drag needed. A dropdown scrollbar touches the hit-test, the draw
  and the input phase, and I tested it against one of the three at a time.
- **The pattern, stated once more because it keeps recurring in this feature:** every one of these
  was another owner of shared state — `menu.item` vs `top`, the draw vs the input phase, the grid vs
  the drag. The question that would have found all three on the first pass is *"what else writes
  this, and who runs last?"*

## 6bv. The headless modes can fail now (2026-08-02, v0.55.0, branch `fix/test-mode-exit-codes`)

§5 had carried this for two days as *"60 of 86 modes print `FAIL` with no `os.exit`… **nobody has
done that pass**"*. This is that pass. It is the first batch in a while aimed at the harness rather
than the product, and the reason to do it before anything else was that **every other verification
in this project rests on it.**

### The entry overstated the work and understated the problem

Both halves are worth recording, because the entry is what deterred anyone from starting.

**Overstated:** it read as 60 bespoke judgment calls. A scan of the actual `FAIL` sites says
otherwise — **396 of the 403 were correctness assertions and 7 were wall-clock gates**, and **55 of
the 60 modes already kept a `bad` counter or a `fail` flag and already printed the verdict.** Two
idioms covered nearly everything (`"csvtest: 0 failures"` and `"themetest: all ok"`), so for most
modes the missing piece was one line. The pass was mechanical for 53 of them.

**Understated, and this is the part that mattered:** an exit code cannot fail on an assertion nobody
counted, and **four modes were asserting into the void.**

- **`sehtest` printed whether the SEH guard caught a real page fault and never checked the bool.**
  That guard is what stands between a mapped-file page fault and a hard crash. The worst thing this
  mode could possibly discover, it would have reported at exit 0.
- **`vnavtest`'s `chk` printed and did not count** — all seven caret-edge assertions were decorative,
  the identical shape to `key_chk`, which had a live FAIL sitting in the tree for a year.
- **`dpitest`'s column-grid linearity check** printed `FAIL` and never touched `bad`.
- **`regextest` never counted its planted needle at all** — neither "found" nor "re-found after
  editing mid-search", the second of which is the use-after-free guard.

So the static scan that produced "60" was measuring the symptom. **A mode with no exit code and a
mode with an uncounted assertion look identical from outside and need different fixes**, and only
one of them was written down.

### The fix is a shared exit, not 60 tails

Every mode now ends at `mode_done(name, bad)` or `mode_done_flag(name, fail)`, which prints the
summary and exits 1. The point of routing it through one procedure is that the exit is part of the
single statement that ends the mode — `return mode_done(...)` — rather than a line underneath it
that the next mode's author has to remember. The 20 modes that were *already* correct were converted
too, so the invariant is "every mode ends here" rather than "most do".

**`modeguardtest` is what makes that true of the next mode rather than only of today's.** It reads
`test_modes.odin` and fails if a dispatch arm returns without routing through the shared exit, if a
name handed to `mode_done` matches no arm (a typo silently unguards the mode it meant to name), or if
an exemption has gone stale. Exemptions are a struct with a mandatory reason, because an exemption
list is how a rule quietly stops applying.

**It is a source-text check, which §7 rightly flags as brittle** (`tablegridtest` is the cautionary
tale). The difference is that the thing being guarded *is* source text — "no arm returns without the
shared exit" is a property of how the file is written — and Odin's `#assert` takes constants, so
there is no compile-time form. It also does **not** claim `mode_done` is on every *path* through a
mode, only that each mode names itself to it. That is the shape of the regression that produced the
60.

**The guard found two things on its first run**, which is the argument for it existing:
`mdtabletest` and `splittest` used `if fail {os.exit(1)}` and so were behaviourally correct but
outside the invariant, and `raw`/`live` had been put in the exemption list by hand — except they are
two-argument modes (`newtpad <file> raw`) that no `os.args[1]` arm dispatches, so the entries read as
coverage and were not. The stale-exemption check caught the exemption list I had just written.

### Timing gates stay out of the exit code, and that is a decision

Wyatt's call, and the reason is the same one this batch exists to serve: a bare millisecond
threshold on a debug build reddens when the machine is busy, and **a sweep that cries wolf is one
people learn to ignore** — which is precisely how 60 modes drifted. `colperftest`, `scrollperftest`
and `regextest` now print `WARN` and do not fail. **`mdperftest` and `rulestest` keep theirs**, and
the distinction is not taste: both carry a *measured* debug multiplier (`DEBUG_MULT`, and rulestest's
8.5× debug-vs-release figure) rather than a bare number, and both exist to be that gate — demoting
them would leave a mode named "perf" incapable of failing, recreating the disease.

Grep `FAIL` for correctness, `WARN` for timing. §7 says so now.

### Verification

87 modes swept green, 229 `odin test` cases pass, and **seven sabotages were applied in one build
and every one produced exit 1**: the SEH guard forced to report it did not catch, a wrong expectation
in `vnavtest`, a non-linear column grid in `dpitest`, `regextest`'s needle forced missing, an
injected count in `csvtest`, a forced flag in `crlftest`, and `blurtest` reverted to a bare
`return true` — which `modeguardtest` named by mode. `sessionlosstest` needed no fixture at all: it
ships its own sabotage switch (`sessionlosstest <file> old` reproduces the data loss), and it now
exits 1 there, which is the check on the check.

### What this batch did not do

- **`celltest` prints a cell/byte round trip it never asserts on.** It is exempt *by name with the
  reason written as owed work*, not because it earned an exemption. Giving it a real assertion is a
  different job from wiring up exit codes and was not smuggled into this one.
- **`modeguardtest` cannot see the two-argument modes** (`<file> count|filtertest|repltest|…`), which
  are switch cases rather than `os.args[1]` arms. They are outside the invariant today.
- **Nothing was fixed in the product.** The sweep was green before and after; this batch changed only
  what the harness is able to notice.

## 6bw. One of the two md_table debts was real (2026-08-02, v0.56.0, branch `fix/md-table-test-gaps`)

Both §5 items were reproduced before either was fixed. **One was real; the other never existed**, and
the second is the more useful finding.

### `md_table_ensure`'s cache key — real, and the fix moves a guarantee out of the call sites

`md_table_budget` and `md_table_max_rows` are runtime variables so a test can drive
`md_table_bounds` into the oversize path on a 9 KB fixture instead of a >1 MB one. They were inputs
to the scan and **not part of the cache key**, so a lowered budget read back an entry measured at the
production one — same revision, same containing range, wrong bounds. Measured by deleting one
`doc.md_table = {}`: `md_table_ensure` returned **`oversize=false, start=0, window=9313`** where the
lowered budget's answer is a bounded ~4.9 KB window.

**`mdtabletest` was already defending against this, by hand, in seven places.** Every budget change
was paired with a manual cache clear. That worked, and it could not scale — the guarantee lived in
seven copies at the call sites rather than in the cache, so the first case that forgot one would
assert against stale numbers and pass. `Md_Para_Cache` keyed on its own budget from the start
(`md_para_run`); this is the same fix one cache later, which is where §5 found it.

Four of the seven clears are now gone — the ones that existed only for staleness. **Three stay and
are not redundant**: they force a *cold re-measure from a different entry offset*, which is the
entry-independence property, and the budget is identical across those calls so the key cannot help.
Sabotaged by dropping the key check: `mdtabletest` fails in **three** places, one per removed clear.

### `md_table_bounds`' "coverage gap" — the claim was false, and the instrument was the reason

§5 said deleting `if r - p > md_table_budget` left `mdtabletest` at exit 0, *verified by a reviewer*.
It does not: it fails on the assertion *"bounds() trips oversize with a bounded window"*, which
`git log -S` dates to **2026-07-25**, six days before the entry claimed the coverage was missing.

**The entry is an artefact of the bug §6bv fixed the day before.** On 2026-08-01 `mdtabletest` ended
with `fmt.println("mdtabletest: FAILURES" …)` and `return true`. Checked out that commit in a
worktree, deleted the same guard, built and ran it: **the assertion fired and printed FAIL, and the
process exited 0.** A reviewer who sabotaged and read the exit code saw exactly what the entry
records, and drew the only conclusion that reading was consistent with.

So a broken instrument did not merely hide defects — **it manufactured one**, and the false item then
sat in the debt register for two days with "verified" attached to it, which is the thing that makes
it expensive rather than merely wrong. §5 now carries the generalisation: **any "not covered,
confirmed by sabotage" conclusion reached before 2026-08-02 was reached with an instrument that could
not read.** Re-verify before scheduling work off one.

**What this says about the method, and it is not "sabotage is unreliable":** sabotage is still the
only way to know a test can fail. The lesson is narrower and sharper — **read the mode's output, not
just its exit code**, which is what §7 has always said about the falsifiers and what this batch had
to learn about everything else. The assertion was printing `FAIL` the whole time. Nobody looked.

### What this batch did not do

Nothing in the product changed. `md_table_budget` is constant in the shipped exe, so the stale-key
read was unreachable outside the harness — this is a **test-integrity** fix, and the sweep was green
before and after. It is the second batch in a row aimed at whether verification works rather than at
what Newtpad does, and that is now finished; the next batch is product work.

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
  - The harness itself: `modeguardtest [path]` — run it first; it is the check that the rest of
    this list can fail at all.
  - Rendering / platform: `sehtest`, `dpitest`, `atlastest`, `atlasgrowtest`, `devicelosttest`,
    `celltest`, `blurtest`, `drawcount <file>`
  - Logging / crash: `logtest`, `crashtest <null|panic|assert|oob>` (triggers a real fault; set
    `NEWTPAD_SESSION_DIR` first — writes .dmp/.txt to its crashes dir, then exits with the fault)
  - UI surfaces: `menutest`, `menuseam`, `palettetest`, `settingstest`, `fonttest`, `historytest`,
    `linktest`, `tabreordertest`
  - Document / editing: `vnavtest`, `wraptest`, `wraplongtest`, `colperftest <mb>`,
    `scrollperftest <mb>`, `hscrolltest`, `csvtest`, `tablecellstest`, `tablereadonlytest`,
    `tablegridtest`,
    `mdtest`, `mdviewtest`, `splittest`, `replacetest`, `findtest`, `regextest <mb>`, `metricstest`,
    `quadsdftest`, `scrollgrabtest`, `tabseamtest`, `lineidxtest [file]`, `selalltest`,
    `tablesorttest`, `mdjointest`, `mdfencetest`, `mdperftest`, `mdtabletest`, `blocktest`,
    `teartest`, `surfacetest`, `jsontest`
  - Files / session: `savepathtest <dir>`, `savestreamtest`, `savefailtest <dir>`, `resavetest [file]`,
    `diskstamptest`, `sessiontest`, `sessionlosstest <file> [old]`, `watchtest [dir]`,
    `bookmarktest`
  - **Exit codes are now load-bearing (2026-08-02, §6bv).** Every mode that reports a verdict ends at
    `mode_done` / `mode_done_flag`, which prints the summary and exits 1 on any failure, so
    `newtpad <mode>; echo $LASTEXITCODE` is a real check. **Run `modeguardtest` in every sweep** — it
    reads `src/program/test_modes.odin` and fails if a mode returns without routing through the
    shared exit, if a name handed to `mode_done` matches no dispatch arm, or if an exemption has gone
    stale. It needs the repo root as the working directory, or a path argument.
  - **Grepping `FAIL` is still correct and still worth doing**, because the three exempt modes report
    nothing to an exit code: `menuseam` and `drawcount` are falsifiers and `jsonperf` is a
    measurement. **`WARN` is the other string to grep** — it marks the wall-clock gates that are
    deliberately outside the exit code (`colperftest`, `scrollperftest`, `regextest`), because a
    bare ms threshold on a debug build reddens on machine load and a sweep that cries wolf is one
    people stop reading. `mdperftest` and `rulestest` keep their gates in the exit code: both carry
    a *measured* debug multiplier rather than a bare number, and both exist to be that gate.
  - File-argument modes: `<file> count|keytest|findtest|filtertest|repltest|edittest|seltest|savetest`
  - `jsonperf <file.json>` is a **measurement**, not a test: it prints input/output size, format
    time and peak bytes for one file and always exits 0. It exists because `JSON_FORMAT_MAX` was
    first picked by reasoning and the reasoning was wrong (§6bl). Re-measure with it before moving
    that constant.
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
