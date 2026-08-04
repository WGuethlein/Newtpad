# Newtpad — complete inventory of unbuilt / owed / considered features

Compiled 2026-08-04 against working tree at `f65080f` (v0.66.0), branch `main`, clean.

**Method.** Swept `HANDOFF.md` (§4, §5, §6, §6aa, and all 45 `### Owed` sections),
`docs/requested-features.md`, `docs/reported-bugs.md`, `docs/ui-spec/newtpad-ui-spec-v1.md` (all 21
sections, read in full — not cited secondhand), `docs/2026-07-25-forgotten-feature-audit.md`,
`docs/live-pass-*.md` (4 files), `docs/features.md`, `research/*`, `CLAUDE.md`, `installer/newtpad.iss`,
`install.ps1`, and past session transcripts via `search_session_transcripts` / `list_events`.

**Every "not built" claim below was grepped against `src/`.** Where a doc said something was owed and
the code already had it, it is in **group H**, not in A–F. Sizes are estimates from reading, not from
building: **S** = under a day, **M** = a few days, **L** = a week or more.

**Counts:** A=9 · B=27 · C=32 · D=12 · E=10 · F=13 · G=6 · H=8.

---

## A. Asked for directly by Wyatt, unscheduled

Ranked by recency. Each is Wyatt's own words where recoverable.

| # | Item | Source | Status | Size |
|---|---|---|---|---|
| A1 | **Complex-script shaping** — *"it should be able to handle any language"* (2026-08-02), then *"spec this tomorrow, skip it for now"* the same day. Arabic contextual forms, RTL (Arabic/Hebrew), Indic matra reordering. Collides with the locked monospace cell grid; the **preview** half is unblocked (`shape.odin` names `IDWriteTextAnalyzer` as the missing piece). | `requested-features.md:405-431`; session `local_786dc776` (2026-08-03) | **SPEC-FIRST**, not scheduled. Verified absent: no `IDWriteTextAnalyzer` in tree. | L |
| A2 | **Format minified JavaScript** — *"add js for later future request"* (2026-08-02). | `requested-features.md:65-101` | **Deliberately not built.** ASI + `/`-ambiguity + nested template literals mean a token re-emitter is unsafe; needs a real parser + printer + differential AST test. Grepped: `src/base/` has `json_format`, `css_format`, `xml_format`, `html_format`, no `js_format`. | L |
| A3 | **Markdown concealment** — hide `#`/`**` on non-caret lines, Obsidian-style. Wyatt chose this over dimming; dimming shipped instead in v0.60.0. | `requested-features.md:276-284`; HANDOFF §6bz `### What is still owed` (L7127) | **Extra-spec** (§9.2's "marks hidden" is the *preview* column; the editor column says *dimmed*). Not cancelled. Needs its own spec: it makes the drawn column stop matching the byte column, so caret/selection/find rects/link underlines/hit-test/h-scroll/wrap/Home-End all learn about hidden runs. **Worth re-deciding now the dimming has shipped.** | M |
| A4 | **Closing the last tab of one window among several should close that window**, not spawn an untitled scratch. *"if an A instance only has one tab and another B instance is open... it should close A instance instead of creating the unititled file"* (2026-08-02). | `reported-bugs.md:98-121` | **Not investigated.** Two open questions first: which windows count (mutex vs class enumeration), and what closing does to hot exit. | S–M |
| A5 | **Ctrl+click on a web link in the CSV table view does not open the browser** (works in text/JSON). Reported 2026-08-01. | `reported-bugs.md:142-212`; `live-pass-v0.60.0.md:124-132` | **Everything from pixel to `plat.shell_open_url` verified correct by `gridlinktest` (green).** Blocked on ONE observation from Wyatt: does a dialog appear, or nothing? | S (once observed) |
| A6 | **Menu and Ctrl+F interactions "feel awkward"** — *"there are a lot of interactions in and out of menus like Ctrl+F that are awkward but it's hard to expalin these now"* (2026-08-01). | `reported-bugs.md:214-229` | **Deliberately vague, recorded not guessed.** Needs a driven session or a focus-transition audit. Plausible structural cause: CLAUDE.md's event rule is only partially honoured. | M |
| A7 | **Scrollbar-drag ghosting in Split view** — reported 2026-08-01, then *"scroll bar drag ghosting is gone now, looks normal"*. | `reported-bugs.md:20-59` | **RESOLVED, cause unknown.** Nothing shipped between report and fix was aimed at it. Kept because if it returns the two dead hypotheses are already written down. Live cost hypothesis: `md_preview_frac` at 3.322 ms/call. | S |
| A8 | **A "treat single newlines as breaks" setting** (GitHub-comment style) — the answer *if* CommonMark soft-break behaviour keeps costing him in real notes. | `reported-bugs.md:72-76` | Conditional. Not a defect; v0.37.0 working as intended. | S |
| A9 | **A live hand-back of a torn-off window's tabs** — closing a torn-off window with unsaved edits while the primary runs leaves the work on disk but invisible until restart, *"which will read as lost"*. | HANDOFF §6bh Owed (L5827) | Fix is `WM_COPYDATA` over the existing channel, *"maybe 30 lines"*. *"The first thing to do if tear-off gets used in anger."* | S |

---

## B. Specified in the UI spec, not built

Every section number below was opened and read. Items are grouped by spec section.

| # | Item | Spec § | Verified absent by | Size |
|---|---|---|---|---|
| B1 | **Embed Monaspace Neon (document) + Argon (chrome).** Requires an in-memory font path: hand-written `IDWriteFontFileLoader`/`IDWriteFontFileStream` vtables, plus a rewrite of `THIRD-PARTY-NOTICES.txt`'s "bundles and redistributes no third-party components" claim. Retires the Georgia fallback. | §2.5, §20 step 3 | `grep -i monaspace src/` → only comments at `text.odin:72`, `settings.odin:61`, `markdown.odin:3056` | L |
| B2 | **Narrow-window drop order above the 318px floor** — rail scroll + chevrons at 560, `>_` and new-tab drop at 460, menu bar → ☰ at 360. | §5 | Only `MIN_W_96 :: 318` exists (`window.odin:85`); no 560/460/360 breakpoints anywhere. Status cells *do* drop right-to-left (built). Tab rail has a `+N` overflow count that opens the palette instead of scrolling. | M |
| B3 | **The rail does not scroll to follow the active tab** when it is off-screen. | §5 | HANDOFF §6aj Owed (L3665); `ui_tabs.odin:428` confirms the overflow count opens the palette instead | S |
| B4 | **Autolinks (`<http://…>`) and reference links (`[a][b]`)** — only inline `[a](b)` works. | §9.2 item 8 | `grep -i "autolink\|reference link" src/program/markdown.odin` → 0 | M |
| B5 | **Images** — placeholder box with the alt text. | §9.2 (— row) | `grep "md_image\|alt text\|placeholder box" markdown.odin` → 0 | S |
| B6 | **Footnotes** — superscript + a list at the end. | §9.2 (— row) | `grep -i footnote markdown.odin` → only `markdown.odin:1701` saying it is in the unimplemented list | M |
| B7 | **Lists do not nest visually** beyond their indent — no per-level bullet cycling. | §9.2 item 5, §9.3 | `requested-features.md:304`; HANDOFF §6ap Owed | S |
| B8 | **h6 tracking.** Caps shipped v0.42.0; the shaper has no letter-spacing parameter, so tracking needs one threaded through `shape_spans`. | §9.3 | `requested-features.md:286-287` | S |
| B9 | **The caption/meta row (0.88 S)** — computed and deliberately unread. | §9.3 | `markdown.odin:1699-1707` — the field `caption` exists, is set at `:1802`, and no draw site reads it | S |
| B10 | **The heading tick-mark rail** — 8px mini-map of `md_heading` ticks down the preview's right edge (and the same for find hits in the editor). | §9.4 | `grep -i "tick_rail\|minimap\|mini-map" src/program/` → 0 | M |
| B11 | **Rich-text clipboard flavour (`CF_HTML`)** for preview copy, so pasting into Word keeps bold/headings. Plain-text copy shipped v0.62.0. | §9.4 (implied by "copy yields the rendered text") | `requested-features.md:296-300`; second serializer, not built | M |
| B12 | **Sub-block scroll sync** — over a long hard-wrapped paragraph the preview pins to the paragraph's top. Two of three pieces exist (`Md_Anchor` carries a within-block pixel offset; `lay.sh.line_boxes` gives per-visual-line geometry). **The hard half is the inverse map** (`md_anchor_top_byte`). | §9.4 | `requested-features.md:263-270`; HANDOFF §6bd Owed | M |
| B13 | **A screen *above* the viewport** is laid out only on the scroll-up gesture, not per pass. | §9.1 | HANDOFF §6ap Owed (L4429) — disclosed and defensible, but not what §9.1 says | S |
| B14 | **Settings group headers** (SESSION / APPEARANCE / VIEWS). Thirteen ungrouped rows today. | §11 | `grep "SESSION\|APPEARANCE\|VIEWS\|group_header" settings.odin` → 0 | S |
| B15 | **"Show menu bar" setting** — when off, Alt reveals it and the hamburger opens the same menus. | §11, §0 shell decision | `grep -i "show_menu_bar\|menu_bar_visible" src/` → 0 | M |
| B16 | **"Reduce motion" setting**, defaulting to `SystemParametersInfo(SPI_GETCLIENTAREAANIMATION)`, re-read on `WM_SETTINGCHANGE`. | §11, §18 | `grep -i "CLIENTAREAANIMATION\|reduce_motion" src/` → 0 | S |
| B17 | **§11's 28px page margins and row padding** — untouched; only the selected-row treatment changed. | §11 | HANDOFF §6al Owed (L3713) | S |
| B18 | **A Ligatures row** on the Font screen. | §11.1 (NEW) | `grep -i "ligature\|calt" settings.odin fontpage.odin text.odin` → 0 | S |
| B19 | **Status-bar cells for Tab width and language** (opening tab width / the lexer list). Encoding and LF cells *are* clickable. Also: "Saved" as a 1.5s `success` cell rather than a centred transient. | §13 | `status_cell_at` (`doc.odin:1050`) covers encoding + line endings only; `features.md:610` confirms | S |
| B20 | **Progress hairline + the sparse (every-1024th-line) index** for the 10 GB filter story — two-thirds built. | §14 | `requested-features.md:307-308` | M |
| B21 | **The 2px accent inset drop ring** on drag-over. Needs OLE `IDropTarget` (`OleInitialize` + `RegisterDragDrop` + a hand-rolled COM vtable); `WM_DROPFILES` gives **no drag-over notification at all**. | §15 | `window.odin:462` uses `DragAcceptFiles`; `grep IDropTarget src/` → 0. **Deliberately deferred 2026-08-02.** | M |
| B22 | **A document icon per associated extension** (same shape, extension label in the corner). | §16 | `requested-features.md:322` | S |
| B23 | **A monochrome icon variant** for the notification area. | §16 | `requested-features.md:323` | S |
| B24 | **Theme contrast warnings** (six pairs, status bar, dismissible, once per save) and **`Follow Windows`** as a theme choice; **high contrast** (`SPI_GETHIGHCONTRAST` → `GetSysColor`) is blocked on the colour-token layer. Also: a 20px swatch in the gutter beside each colour line, and "ship three themes, not one". | §17 | `grep -i "follow.windows\|HIGHCONTRAST\|high_contrast" src/` → 0 | M |
| B25 | **Surface colour-rule rule 3** ("syntax highlighting wins, including `.log`") in the status bar when a rule is skipped; and **validate `Bg_*` roles on save**. | §17.1 | `rules.odin` implements the rules and documents rule 3 in the seeded header, but nothing surfaces a *skipped* rule at runtime | S |
| B26 | **A UIA provider / screen-reader support.** | §18 | `grep -i "UIAutomation\|IRawElementProvider\|narrator" src/` → 0. Deliberate: see E7. | L |
| B27 | **The 50ms motion budget** — hover fills, active-tab pill move on reorder, menu/palette opacity. Nothing in the product animates. Also §18's **annular-SDF focus ring** (currently four edge quads, a recorded deliberate deviation). | §18 | `grep -i "ease_out\|animation" src/program/` → only `block.odin` timing comments; HANDOFF §6aj `### Two places the specification was not followed` (L3615) | S–M |

---

## C. Owed engineering debt — stated as a rule, absent from the code

Ranked roughly by user-visible consequence.

| # | Item | Source | Verified | Size |
|---|---|---|---|---|
| C1 | **An async link resolver worker** (`watch.odin`-shaped). Today **no non-local link target ever resolves** — `\\server\share\x`, `smb://`, and *every* link (even a relative one) inside a document opened from a UNC path or mapped drive. Also owed as a **time bound**: `links_layout` stats on the frame path, and a slow *fixed* volume (OneDrive sync root, AV filter driver, cold spindle) passes `path_is_local` and blocks the UI thread anyway. Measured 3.32 ms/frame scrolling 200 missing targets. | HANDOFF §5 (L611), §6aq Owed (L4021); `requested-features.md:443-446` | `links.odin` `link_stat` refuses `DRIVE_REMOTE`; no worker exists | L |
| C2 | **`src/renderer` and `src/ui` are empty stubs** (7 and 6 lines). CLAUDE.md's layer rule names them; their work lives in `platform/{quads,text}.odin` and across `program/`. Recent batches made the extraction measurably harder in ~10 named places. | CLAUDE.md "Layer boundaries" as-built caveat; HANDOFF §3, §5 (L618), §6am `### Still owed, deliberately` | `cat src/renderer/*.odin src/ui/*.odin` → package declarations and a comment | L |
| C3 | **`\\?\` long paths, program layer — and it has REGROWN.** HANDOFF §5 says only `diag.odin`'s append-mode log handle remains on `core:os`. **That is now stale:** `keymap.odin:480,648,650`, `rules.odin:440,597`, and `perf.odin:80` also use `os.read_entire_file` / `os.exists` / `os.write_entire_file` directly. All inherit `core:os`'s `_fix_long_path`, which depends on the HKLM registry opt-in CLAUDE.md forbids depending on, and does nothing without the `longPathAware` manifest entry we deliberately do not ship. Reachable via `NEWTPAD_SESSION_DIR`. | CLAUDE.md hard rule; HANDOFF §5 (L289-308) | Grepped 2026-08-04 | S |
| C4 | **No scissor-rect facility anywhere in the renderer.** Clipping is a cover strip painted after the content, with at least three consumers. Blocks clean preview clipping and is a prerequisite for a diagram pane. | HANDOFF §6aq Owed; `requested-features.md:447-449` | 10 comments across `main.odin`, `markdown.odin`, `table.odin`, `shape.odin` saying "there is no scissor rect" | M |
| C5 | **The text pipeline batches nothing** — one heap allocation, two buffer maps and one draw call per string, 74 call sites, several inside per-row loops. §19 asks for two draw calls per frame, total. This is the prerequisite for an always-on gutter. | HANDOFF §5 (L347); ui-spec §19 | `text.odin:1159` `make([dynamic]Text_Instance…)` per call | M |
| C6 | **Scroll resolution still happens inside the draw** — `menu_draw_dropdown` calls `menu_scroll_to_item`, which writes `menu.top`. Against CLAUDE.md's one-layout rule. Edge-triggering in §6bt removed the bug, not the violation. **This shape cost three consecutive releases** (§6br → §6bt → §6bu). | CLAUDE.md one-layout rule; HANDOFF §5 (L272), §6bu Owed | Still present | S–M |
| C7 | **"Events queue to the frame arena, processed at one point per frame" is only partially honoured.** `render_frame` mutates the `Document` (`hscroll_model`'s `.Columns` branch, `md_table_ensure`, `doc_max_hscroll`), `links_layout` performs filesystem I/O from the draw and owns a process-global cache, and `render_frame` queries the live OS cursor inside the draw. | CLAUDE.md hard rule (self-flagged as partial); HANDOFF §6ar Owed (L4229), §6at Owed | Confirmed by the cited call sites | M |
| C8 | **`pt_insert` never coalesces adjacent appends**, so a multi-row edit fragments the tree and every subsequent READ pays. Instrumented: press 1 = 6.75 ms / 4,001 pieces; press 20 = 63.97 ms / 42,001 pieces, **95% reads**. Fix is one `pt_delete` + one `pt_insert` in `block_apply`; would let `BLOCK_EDIT_MAX_LINES` go from 300 back to thousands. | HANDOFF §5 (L361-388) | Measured, not fixed | M |
| C9 | **Coalesce consecutive block edits into one undo entry.** Correctness, not cosmetics: 20 presses is 20 Ctrl+Z, and `UNDO_MAX :: 200` evicts the pre-run state on a long hold — a small data-loss path. | HANDOFF §5 (L389) | | S |
| C10 | **~274 unchecked `make` calls on `context.temp_allocator`.** `#optional_allocator_error` drops the error, so a genuine process OOM becomes a bounds trap. **One instance of this shipped the v0.31.0 Split-resize crash.** | HANDOFF §5 (L421) | | M |
| C11 | **Precompiled `.cso` shaders** — drops the `d3dcompiler_47.dll` runtime dependency. "Wanted before ship." | HANDOFF §5 (L616); `requested-features.md:452` | `quads.odin:6-8` — comment only, still compiles embedded HLSL at startup | S |
| C12 | **reindex-on-edit** — line count and scrollbar drift after big edits. | HANDOFF §5 (L615) | | M |
| C13 | **`Highlight_Row_Cache.cur_buf` is a row-sized token budget filled from a whole line.** Measured: a 4.5 KB minified-JS line at 200 columns colours its first four visual rows and leaves nineteen bare. **The obvious fix is wrong** (setting `whole_line = false` resolves `state_in` at the wrong offset). | HANDOFF §5 (L392) | Visual only; state stays correct | M |
| C14 | **`line_cell_col` silently truncates past `VISIBLE_COLS * 4` = 8192 bytes** — no `exact` flag, unlike `pt_line_start_cap`. `block_delete` is now subject to it. Not currently reachable (`caret_line_start_cell` has the identical bound). **Both bounds move together or neither does.** | HANDOFF §5 (L319) | | S |
| C15 | **`replace_sel_raw` (`doc.odin:2183`) does not clamp its range**, unlike `doc_replace_range`. Shared with `find_replace_current`; `find_replace_all` widened the blast radius from one splice to `MAX_MATCHES`. | HANDOFF §5 (L413), §6ar Owed | | S |
| C16 | **A markdown table wider than the Preview pane is clipped with no way to reach the rest.** The fix is to scroll the *table element*, not the pane. | HANDOFF §5 (L339) | | M |
| C17 | **Links inside markdown tables are not clickable** — a table row's glyphs are placed in character cells, so emitting rects today means a second producer of the same positions. Owed: route a table row through `shape_spans`. | HANDOFF §6ap Owed (L4429) | | M |
| C18 | **A blockquote written with `>` on every line renders as N stacked blocks with a segmented bar** (13px gaps between 26px segments, measured), while the lazily-continued form renders as one clean bar — so the way nearly everyone writes a blockquote looks worse. **Not the small predicate change it was once claimed to be** (`md_para_bounds`'s entry-independence contract). Needs its own spec + entry-independence fixtures. | `requested-features.md:251-261`; HANDOFF §6bd Owed | | M |
| C19 | **Soft wrap is not in the markdown admit budget**, so a wrapped block at the pane bottom can overhang by its continuation rows. | HANDOFF §6at Owed (L4333) | | S |
| C20 | **Markdown headings can still overhang the content box** and are clipped mid-glyph; the loop needs per-row height measurement. | HANDOFF §6aq Owed (L4021) | | S |
| C21 | **`fence_state` is not seeded**, so scrolling into the middle of a `json`/`c` fence whose content has an open `/* */` colours the visible remainder wrong. | HANDOFF §6aq Owed | | S |
| C22 | **An untagged or unknown-tag fence body draws on the proportional body face** (there is no `odin` lexer, so most fences in this repo's own docs render proportional). Plus a stronger suspicion: fence-body slot heights came out pixel-identical under two font families with different advances, so **something on that path may not be advance-aware and its wrap points may be wrong**. | HANDOFF §6ap Owed (L4429) | | S–M |
| C23 | **The grid/CSV view still wastes its last row** — it stayed on the fully-visible row count. | HANDOFF §6aq Owed; `requested-features.md:460` | | S |
| C24 | **A find match starting exactly ON a wrap point highlights the row above the text it marks.** `find_match_rects` uses `f.matches[mi] <= end` where `end` is the row's break offset. Fix is `< end` for a wrapped non-line-end row. Narrow and pre-existing. | `reported-bugs.md:78-96` (found 2026-08-02) | Selection code uses the correct half-open form | S |
| C25 | **The table filter and the sort are not persisted in the session** — `Doc_View` carries neither. Consistent rather than an oversight, but a filter is expensive to rebuild by hand. | HANDOFF §6bp Owed (L6344), §6bs Owed | | S |
| C26 | **The horizontal scrollbar's range never shrinks within a session.** `Document.max_cells_seen` is a high-water mark; delete the longest line and the bar keeps offering pan into content that no longer exists. Accepted by Wyatt 2026-07-28; the fix has the async-resolver shape. Note `doc_max_hscroll` **mutates the Document from the draw path**. | HANDOFF §6aq Owed | Measured: 323 before and after deleting the long line | M |
| C27 | **A growing log's tail loses its row numbers past `CKPT_SCAN_CAP`** — `ckpt_repair` shifts and compacts but never *adds* a checkpoint, so an append over 128 KiB outruns the scan. Refuses rather than guessing. | HANDOFF §6ax Owed (L4881) | | S |
| C28 | **`menu_scroll_last` is O(n·rows) and `dropdown_w` walks every item**, both several times a frame. At the 100,000-value filter ceiling that is several ms/frame. Same fix for both: memoise on `menu.ctx_items` (changes in exactly two places). Not measured under load. | HANDOFF §6bs/§6bt Owed | | S |
| C29 | **`a.docs` can grow without bound within a session** — one dead slot per middle-close/reopen cycle. Deliberate (tab order stability). Constraint if ever compacted: a re-indexing pass that remaps `active`, every `mru` entry and every in-flight `Watch_Entry.slot` — **never** a hole-fill. | HANDOFF §5 (L401) | Measured: 100 cycles → `slots=104 live=4` | S |
| C30 | **`keys.txt` can bind the plumbing commands the palette deliberately hides** (`Menu_Activate`, `History_Jump`, `Settings_Close`…). Nothing enforces the filter; the fix is to reuse `command_in_palette` at parse time. Not a defect today. | HANDOFF §5 (L330) | | S |
| C31 | **`markdown.odin:2154` passes `context.temp_allocator` as `shape_run`'s PERSISTENT allocator argument**, and the growing resize arena made "any pointer that escapes a resize repaint's temp arena" a **real** use-after-free. Both documented in place, enforced by nothing. | HANDOFF §5 (L428, L436), §6au Owed | | S |
| C32 | **`install.ps1 -Force` hard-kills the running Newtpad** (`Stop-Process -Force`, line 41) — no graceful hot exit — **and it is the loop run after every merge** (standing memory rule). A daily-driven editor with unsaved tabs is force-killed on every install. | `install.ps1:37-41`; HANDOFF §6af Owed (L3263) | Read 2026-08-04 | S |

Also owed and shared with §5's own carried notes: `table_byte_at` is a **third** copy of the same three-line byte peek (promote one to `base`); HANDOFF §7's headless-mode list is materially incomplete against the ~93 modes actually dispatched; two brittle substring-counting assertions in `tablegridtest` (`nnorm == 2`, `nsep == 0`) that will fail for reasons unrelated to what they guard.

---

## D. Ship-readiness gaps

| # | Item | Source | Status | Size |
|---|---|---|---|---|
| D1 | **Code-signing certificate.** The pipeline is built signing-*ready* and reports `signing: skipped, no certificate configured`. **Blocked on Wyatt purchasing one — never handle a certificate or its password.** Note `research/newtpad-research-report.md:116`: signing barely helps SmartScreen for an unknown publisher, so budget reputation time as well as money. | `requested-features.md:344-346`; HANDOFF §6af Owed | Blocked on Wyatt | S once unblocked |
| D2 | **Defender false-positive submission to Microsoft** (needs Wyatt's account, <https://www.microsoft.com/en-us/wdsi/filesubmission>, as "Software developer"). Evidence 2026-07-31: a GitHub download of v0.33.0 failed with *"Failed - Virus detected"*; VirusTotal returned **1/40**, Microsoft `Trojan:Win32/Wacatac.B!ml` — sole-ML-dissenter, the false-positive signature. One of the two reputation signals (missing version resource) is already fixed. | `requested-features.md:347-365` | Blocked on Wyatt | S |
| D3 | **The installer has never been RUN.** `newtpad.iss` compiles (`build\newtpad-0.20.0-setup.exe`, 2.61 MB) but install, `/SILENT`, upgrade, **upgrade-over-running**, uninstall, the PATH code and the license page have never executed. **The graceful-close path is the one whose failure loses a user's work.** | HANDOFF §6af (L3275-3279); session `local_662875ea` | **The largest untested surface in the product.** Deliberately not attached to any release. | S–M |
| D4 | **The installer has no `SetupIconFile`** — `newtpad.iss:110` says *"the tree has no .ico yet"*, but `src/platform/newtpad.ico` (13,640 bytes) has existed since 2026-07-29 (§6at). Stale comment, one-line fix. | `installer/newtpad.iss:110` vs `ls src/platform/newtpad.ico` | Verified 2026-08-04 | S |
| D5 | **Landing page + download page**, and **publish the price early and hold it** (File Pilot precedent). | `requested-features.md:343` | Not started | L |
| D6 | **Storefront.** | `requested-features.md:369` | Post-beta (§6aa fork 2) | M |
| D7 | **Trial mechanism.** | `requested-features.md:369` | Post-beta | M |
| D8 | **Offline license key / activation.** No `license`/`trial`/`activation` code in the tree. | `requested-features.md:369` | Post-beta | M |
| D9 | **The update worker is joined at exit and should not be** — it exists only because `Update_Check` lives in a local of `main` and `diag_shutdown` runs after `app_destroy`. Move to package-level storage and `update_stop` becomes an atomic store with no wait. **~15 lines, written fix, never applied.** Also: the updater goes permanently silent on any tag not exactly `vN.N.N` — correct code, an undocumented release-naming constraint. | HANDOFF §6af Owed (L3256-3261) | **Not in `requested-features.md` or `reported-bugs.md`** — see G3 | S |
| D10 | **Two live passes still owed.** (a) §6x's **theme-tuning pass** — Dark's nine `Syn_*` roles were chosen by arithmetic and have been looked at once; Light's are still provisional. First thing every beta tester sees. (b) **`docs/live-pass-v0.60.0.md`** — twelve releases (v0.49.0 → v0.60.0) never walked systematically. | `requested-features.md`; `live-pass-v0.60.0.md`; HANDOFF §6aa "the gate on the beta that is not a batch" | **On the critical path, not beside it.** | M (Wyatt's time) |
| D11 | **Rebindable keys were listed as a V1 gap** — they are **built**. See H1. | — | — | — |
| D12 | **`doc_move_lines`' `read_range` ignores `pt_read`'s return and the fault flag across four reads and then writes** (Shape A, open since §6ae). The sort's version was fixed; this one was not. A faulted mapped read writes garbage. | HANDOFF §6af Owed (L3265), §6ae | **Not in `requested-features.md` or `reported-bugs.md`** — see G3 | S |

---

## E. Explicitly deferred to V2+ / post-V1

| # | Item | Decided by / when | Note |
|---|---|---|---|
| E1 | **The UI overhaul and the `renderer`/`ui` extraction** | Wyatt, 2026-07-26 (§6aa fork 1) | Moved to V2 as its **first** item, on File Pilot's own advice: budget exactly one UI rewrite and do it after real use. CLAUDE.md still ranks them priority 2 — the two documents disagree. |
| E2 | **Plugins** — narrow C-ABI, formatters + viewers, worker threads, timeouts, never generic scripting | Locked decision (CLAUDE.md) | The ABI is scoped on the unexamined assumption that a viewer returns text or a bitmap; mermaid needs far more (see E3). |
| E3 | **Mermaid diagrams in the markdown preview, as the first plugin** | Wyatt, 2026-08-02: *"drop mermaid … for v2+"* | Requested 2026-07-31 for spec-driven design work. **Deferred on COST, not scope** — a Sugiyama layered layout is 1,500–2,500 lines before parsing, in an ~11k-line product. Three sub-decisions still open and all day-one: static / live / click-to-jump (the third needs source byte offsets carried through every node). **Consequence accepted: the preview shows raw mermaid source indefinitely.** |
| E4 | **Explorer preview handler (`IPreviewHandler`) + thumbnail handler (`IThumbnailProvider`)** | Wyatt, 2026-08-02: *"drop … Explorer preview for v2+"*, the same day he asked | *"i want to be able to use newtpad as the text previewer in explorer"*, framed by him as *"it's just a thought doesn't need to be now."* **Blocked on a product question, not a technical one:** it needs a DLL and a registration step — the first thing here that cannot work without an installer, ending "no install required". Decide it together with the thumbnail handler or the DLL gets built twice. |
| E5 | **First-party JSON/CSV/XML reformat** as the V2 plugin proof | Research §G, 2026-07-18 | **Superseded — JSON/CSS/SCSS/XML/HTML all shipped first-party v0.44.0–v0.57.0.** See H2. |
| E6 | **Full multi-cursor** | Research §G, 2026-07-18 | Column/block editing shipped in V1 (§6y); the File-Pilot batch-rename per-cursor-buffer model is V2. |
| E7 | **Accessibility / a UIA provider** | Wyatt, 2026-07-26 (§6aa fork 4) | *"the beta and the paid V1 both ship with no screen-reader support"* — a deliberate, dated choice. High contrast is blocked on the colour-token layer rather than on effort. |
| E8 | **Container/archive tree viewer** (JAR/ZIP/tar/.docx/.pak → tree of entries, click to open a member in a tab) | HANDOFF §6, parked | The canonical exercise of the *viewer* half of the C-ABI. Introduces Newtpad's **first side panel**, which cuts against Product Principle #2 — so it must be toggleable and present only while a container is open. Decompilation is explicitly not part of it. |
| E9 | **Complex-script shaping** | Wyatt, 2026-08-02: *"spec this tomorrow, skip it for now"* | Spec-first. See A1. |
| E10 | **Commerce (trial, offline license key, storefront)** | Wyatt, 2026-07-26 (§6aa fork 2) | Sits *after* the free public beta, informed by its feedback. |

---

## F. Decided AGAINST — do not reopen by accident

| # | Item | Reason recorded | Where |
|---|---|---|---|
| F1 | **Colour emoji** | Wyatt, 2026-08-02: *"don't put color emoji only the basic ones supported"*. Monochrome outlines only; no COLR/CPAL layer compositing. | `requested-features.md:432` |
| F2 | **Glyph-atlas eviction** | **Refuted by measurement, not deferred.** At 4096² the atlas holds 61,425 glyphs at 16px and 9,768 at 48px (300% DPI); `atlas_full` never latches. The belief traced to one stale comment in `text.odin` that outlived its own fix by seven months. **Do not re-add without a contradicting measurement.** | HANDOFF §5 (L603), §6ab |
| F3 | **Arenas on VirtualAlloc with grouped lifetimes** | The CLAUDE.md row was **amended twice**. The text described code that never existed and had no measured problem behind it. Build an arena only when a measurement asks, and amend the row again when you do. | CLAUDE.md Memory row; HANDOFF §5 (L283) |
| F4 | **Beta expiry / DRM / online checks** | Honour-system, per research §D (this audience rejects telemetry and account-gating outright). | `requested-features.md:483` |
| F5 | **LSP, project trees, terminal** | CLAUDE.md scope row: Notepad-first, not an IDE. | CLAUDE.md |
| F6 | **Minified-JavaScript formatting** | The token-re-emitter technique **cannot be made safe** for JS (ASI, `/` ambiguity, nested template literals). A partial formatter is worse than none because it silently changes what the code does. | `requested-features.md:65-101` |
| F7 | **Mermaid in the core exe** | Deferred on **price**, and deliberately **not** filed as ruled out. The first framing ("it is an IDE feature") was **withdrawn on review** because that test would equally have cut the markdown preview and the table view. It is live as an add-on. | `requested-features.md:479-485` |
| F8 | **Double-click-to-select-a-word in the preview** | One input cannot mean two things: the second press of a cluster is already Split's click-to-sync-scroll gesture (§6ao), and that gesture shipped first. | `requested-features.md:301-302` |
| F9 | **Pinning the filter dropdown's search row** | Would mean the draw emitting a row the hit-test computes differently — **the exact trade that design exists to refuse.** Revisit only if a long list becomes annoying. | HANDOFF §6bq Owed (L6423) |
| F10 | **Widening `line_cell_col`'s 8192-byte bound alone** | Widening one of two identical bounds would make them disagree. Both move together or neither does. | HANDOFF §5 (L319) |
| F11 | **`Text_Dim` for live content** (table em dash, row-number gutter, empty-tab hints) | Overturned in review: `Text_Dim` is 2.9:1/2.8:1, disabled-only. A hint or a row number a reader cannot resolve is lost information, not a disabled affordance. **Settled once, in one place, for all three sites.** The only real exemption in the tree is `settings.odin`'s range-end guillemet. | HANDOFF §5 (L443-460) |
| F12 | **Excluding the filter dropdown's `▲`/`▼` arrows from the row hit-test** | Would carve a dead notch out of the middle-right of two rows, which is worse than what it fixes. They are muted glyphs with no button affordance. | HANDOFF §6br/§6bt Owed |
| F13 | **Code folding, macros/record-replay, file compare/diff, print & print preview, spellcheck, global-hotkey quick capture** | **Out of V1** (§6aa, 2026-07-26) — but note the distinction the queue itself draws: these were *never ruled in*, and never ruled **out** either. They remain in `requested-features.md` §4 "Never decided either way". | HANDOFF §6aa; `requested-features.md:388-402, 469-471` |

---

## G. Transcript-only / fell through the cracks

**Honest headline: the transcript sweep found almost nothing new.** Doc discipline on this project is
unusually good — the three-file queue (`requested-features.md` / `reported-bugs.md` / `features.md`)
plus HANDOFF's `### Owed` sections capture essentially every ask I could find in session history.
Searches for `it would be nice`, `can you add`, `i want to be able to`, `always on top`, `recent files`,
`minimap`, `insert date`, `trim trailing whitespace`, `auto indent`, `explorer context menu`,
`default text editor` returned **no hits at all**. What follows are cracks in the **doc-to-doc**
transcription rather than transcript-only asks, plus one genuine transcript item.

| # | Item | Where it lives | Where it is missing | Size |
|---|---|---|---|---|
| G1 | **`requested-features.md` has no `## 2` heading.** Sections run 1, 3, 4, 5, 6. The entire UI-spec block (lines 227–334: §8, §9, §10, §14, §15, §16, §17, §18, §20) sits **under §1 "Asked for directly, unscheduled"**, which is a category error — those are spec obligations, not Wyatt asks. A reader scanning §1 for Wyatt's requests gets 100 lines of §9 markdown debt. | `docs/requested-features.md` | The heading itself | S (edit) |
| G2 | **Research §C's "In-buffer block separators (Heynote-style)" and "Chord/multi-key hotkeys" were dropped in transcription.** `requested-features.md` §4's "Never decided either way" table reproduces research §C — minus these two rows. Block separators are described by the scratchpad lens as *"Scratchpad-native alternative to tabs; beloved"*; chords as *"Low cost; fits our data-declared command system"*. `keymap.odin` uses "chord" to mean a modifier combo, **not** a multi-key sequence — so multi-key chords are genuinely unbuilt and genuinely unqueued. | `research/demand-side-feature-research.md:112-113` | `requested-features.md` §4 | M each |
| G3 | **Two HANDOFF §6af owed items never reached the queue files:** the **update worker's exit join** (~15-line written fix, D9) and **`doc_move_lines`' Shape-A faulted-read hole** (D12). Both were named again in the 2026-07-28 session's closing summary as "not blocking, I can do them whenever", and then nobody did. | HANDOFF §6af Owed (L3256, L3265); session `local_662875ea` | `requested-features.md`, `reported-bugs.md` | S each |
| G4 | **`install.ps1 -Force` hard-kills a running Newtpad** and is the standing post-merge loop. Named once in HANDOFF §6af Owed as an aside (*"`install.ps1 -Force` still hard-kills, and that is the loop run after every merge"*) and never queued anywhere. See C32. | HANDOFF §6af Owed (L3263) | Both queue files | S |
| G5 | **The `\\?\` long-path debt has regrown into three new files** (`keymap.odin`, `rules.odin`, `perf.odin`) since the §6an fix, and HANDOFF §5 still says only `diag.odin` remains. Nothing tracks it. See C3. | Grepped 2026-08-04 | HANDOFF §5, both queue files | S |
| G6 | **`installer/newtpad.iss` still says "the tree has no .ico yet"** — false since 2026-07-29. See D4. | `installer/newtpad.iss:110` | Everywhere | S |

---

## H. ALREADY BUILT — the docs are stale

These are things a doc currently describes as owed, missing, or deferred, where the code has them.
**Each was confirmed by grep or by `docs/features.md`, not by inference.**

| # | Doc claim | Reality | Evidence |
|---|---|---|---|
| H1 | **`requested-features.md:370-371` (V1 roadmap): *"Rebindable keys are in V1… The data-declared command table exists; only the user overlay is missing."*** Also `2026-07-25-forgotten-feature-audit.md`: *"The overlay that would consume it does not exist."* | **The overlay is fully built and shipped.** `src/program/keymap.odin` is 657 lines: parses `%APPDATA%\Newtpad\keys.txt`, seeds it with every default binding, re-reads on save, refuses shift-chords / unmodified printables / reserved chords / Windows-owned chords with a per-line reason, and reports `[KEYS.TXT: n LINE(S) REFUSED]`. Reachable from **View ▸ Edit Keybindings…**. | `src/program/keymap.odin`; `docs/features.md:562-585` |
| H2 | **`requested-features.md:383` (V2 roadmap): *"First-party JSON/CSV/XML reformat — see item 1; Wyatt may have just moved this."*** And HANDOFF §6aa: reformat *"was decided out of V1 and held to the V2 plugin proofs."* | **Shipped first-party as `Format Document` (Ctrl+Alt+F): JSON (v0.44.0), CSS/SCSS/XML (v0.47.0), HTML (v0.57.0).** Language picked by extension *then* by first non-space byte. XML/HTML never rewrite content, only structure. | `src/base/{json,css,xml,html}_format.odin`; `docs/features.md:196-228` |
| H3 | **`requested-features.md:449-450`: *"`WaitMessage` when idle — the app redraws at vsync with nothing happening, burning a core on a static window."*** Same claim in HANDOFF §5 (L345): *"no `WaitMessage` anywhere."* | **False, and it has been false since at least 2026-07-25** — the forgotten-feature audit already refuted it and the claim survived into a queue compiled five days later. `main.odin:403-423` blocks in `plat.window_wait_message` with a 200 ms poll when a worker is publishing, 1000 ms otherwise, shortened to the caret's next phase change, and skipped only for a live drag auto-scroll. `window.odin:28` wraps `MsgWaitForMultipleObjectsEx`. | `src/program/main.odin:399-423`; `src/platform/window.odin:28` |
| H4 | **HANDOFF §6al Owed (L3713): *"The status bar's cells are not clickable (§13)… it is two text runs, not cells."*** | **Built.** `status_cells` / `status_cell_at` (`doc.odin:1029,1050`) return a `Command_Id`, dispatched at `main.odin:1117`. Encoding and line-ending cells open their menus. Cells also drop right-to-left as the window narrows, measured against the left group. *(Still owed: cells for Tab width and the lexer list — B19.)* | `src/program/doc.odin:1029-1060`; `docs/features.md:591,610-613` |
| H5 | **HANDOFF §6al Owed (L3713): *"§7's ranking is unchanged: still the existing filter, not the spec's exact-prefix > word-start > anywhere with recency tie-breaks."*** | **Built.** fzf-style bonuses, an exact-prefix boost, and a recency tie-break — *and a command run from a menu teaches the palette exactly as one run from the palette does*. Matched characters carry the accent, per §7. | `docs/features.md:548-551`; `src/program/palette.odin` |
| H6 | **UI spec §6 item 4: *"Disabled items give no reason."*** | **Built.** `menu.odin:607-609` — greyed rows replace their shortcut with the reason where there is one worth giving. | `src/program/menu.odin:607-625`; `docs/features.md:559-560` |
| H7 | **`2026-07-25-forgotten-feature-audit.md` Tier 2 item 4 and HANDOFF's priority-3 list: signing, updater, crash reporting, installer.** | **Three of four exist.** Crash reporting: minidump + human-readable report + log breadcrumbs + prefilled GitHub issue, plus GPU-loss handling (`platform/crash.odin`, 402 lines). Updater: `Help ▸ Check for Updates`, one HTTPS GET on a worker, numeric version compare (`program/update.odin`, 398 lines). Installer: `installer/newtpad.iss` compiles to a 2.61 MB setup.exe. **Only signing is genuinely absent** — and it is a *stub wired in and working*, blocked on a certificate. *(But see D3: the installer has never been run.)* | `src/platform/crash.odin`; `src/program/update.odin`; `installer/newtpad.iss`; `docs/features.md:619-632` |
| H8 | **`requested-features.md:416-425` used to claim (and the entry now corrects) that *"the caret/hit-test/selection/find rects assume a monospace column, so they misalign on CJK and emoji."*** HANDOFF §5 P2 (L596-599) **still carries the old claim verbatim.** | **They do not misalign.** `text_walk_glyphs` advances by `cells * cell_w` using the same `text_cell_width_at` the caret, selection and hit-test read — one origin, no second arithmetic. Verified 2026-08-02 by `emojitest`: 😀👍🔥❤ resolve through `seguisym.ttf`, rasterize with ink, occupy 2 cells, and round-trip cell↔byte past the surrogate pair. CJK likewise. **`requested-features.md` was corrected; HANDOFF §5 was not.** | HANDOFF §6cf; `src/platform/text.odin`; `requested-features.md:410-421` |

---

## Cross-cutting note on doc reliability

Three of the eight group-H entries (H1, H3, H8) are claims of **absence** that survived a prior
refutation. This is the exact failure mode `docs/2026-07-25-forgotten-feature-audit.md` names in its
own header and generalises as the most useful thing it produced:

> a claim of presence gets exercised by every build; a claim of absence is never re-tested.

H3 is the sharpest case — the `WaitMessage` claim was refuted on 2026-07-25, and was re-copied into a
queue compiled on 2026-07-30. Any list assembled by sweeping the docs will therefore over-report.
Every item in groups A–F above was grepped; the ones that failed the grep are in H.
