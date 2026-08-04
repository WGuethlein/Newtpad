# Reported, not yet scheduled

Bugs Wyatt reports from daily use **between** live passes. A live-pass checklist covers one release;
this file catches everything else, so a report made mid-batch is not lost to a chat transcript.

The other two lists: [requested-features.md](requested-features.md) for what is owed or asked for, and
[features.md](features.md) for what already works.

**How to use it:** when a batch is being scoped, read this file. When an item ships, delete it from here
and record it in the HANDOFF entry instead — this file is a queue, not a history.

---

## The 2026-08-04 full-repo audit

Six parallel read-only passes over the whole tree, one per subsystem. Full reports with mechanism,
failure scenario and fix sketch for every item are in **[audits/2026-08-04/](audits/2026-08-04/)** —
this section is the triage index, not the evidence. **Read the report before scheduling any item**;
each entry there states whether it was CONFIRMED (the path was traced end to end) or PLAUSIBLE, and
the ones below are all CONFIRMED unless marked.

**77 findings: 8 CRITICAL, 22 HIGH, 23 MEDIUM, 24 LOW.** Five are already fixed (below). Every
finding was cross-checked against this file, `requested-features.md` and HANDOFF §5/§6 first, so
nothing here is a re-report — but **three are worse than what was already recorded** and say so.

**Standing caveat on all of it:** these came from reading, not from running. The headless sweep was
green before the audit and green after (95 modes, zero FAIL), which is exactly the point — every
item below is in territory no test observes. That cuts both ways: it is why they survived, and it is
why each one needs its own failing test before anyone believes the fix.

### Fixed in this pass (2026-08-04)

| Was | Where | Now |
|---|---|---|
| **CRITICAL** — `Ctrl+C` crashes the process on any document holding a stray high byte | `platform/clipboard.odin:13` | `utf8_to_wstring` returns nil on invalid UTF-8 (it passes `MB_ERR_INVALID_CHARS`); the next line dereferenced it. Guarded, and the proc now returns `ok` |
| **CRITICAL** — `Cut` deletes the selection even when the clipboard write failed | `program/commands.odin:1456` | Deletes only on a successful copy, and says so when it refuses. Also fixes a leaked `HGLOBAL` on two paths |
| **CRITICAL** — a middle-click in the document body latches `mouse_middle_pressed` forever, so **session autosave never runs again** | `program/main.odin:996` | Cleared unconditionally once per frame, like the right button. All five existing clears were region-conditional and none covered the document body |
| **HIGH** — whole-word search accepts `cat` inside `cats` at every 256 KB block edge | `program/find.odin:771,792` | Block overlap was `len(q)-1` — enough to *find* the last candidate, one byte short of *judging* it, so `after` defaulted to 0 and read as a word boundary |
| **HIGH** — a find match spanning two visual rows is highlighted on the first row only | `program/find.odin:1661` | Emitted one rect per match and advanced; now emits per row the match touches, which is the range rule `doc_selection_rects` already uses on the same iterator |

~~**Owed on all five: a test that fails without the fix.**~~ **PAID 2026-08-04 (v0.69.0, HANDOFF
§6ci).** All five now have a sabotage-verified case. Writing them found a **sixth defect on the same
path**: `clipboard_set_text` called `EmptyClipboard()` before attempting the conversion, so a copy it
could not perform destroyed what the user already had. Also worth knowing — the whole-word fixture
took **four attempts and the first three passed while proving nothing**; §6ci records all three
mistakes, because each is easy to repeat.

### CRITICAL, still open

| # | Item | Where |
|---|---|---|
| 1 | A mapped original that **faults mid-save writes zero-filled pages into the user's file** and commits them atomically. `doc_sort_lines` guards this exact hazard; the save does not | `doc.odin:2158` |
| 2 | **`Ctrl+S` never re-stats the target or consults `disk_changed`** — an externally rewritten file is silently overwritten, and the save then clears the only warning that existed | `commands.odin:1469` → `doc.odin:2144` |
| 3 | `doc_detach_mapping` does an **uncapped whole-file private copy on the input thread**; a failed allocation repoints `pt.original` at an empty slice → out-of-range slice in `piece_src` | `doc.odin:3054` |
| 4 | **`css_format` silently corrupts any stylesheet with an unquoted `url(...)`** — `//` takes the SCSS comment branch and eats the closing `)`, so every later rule is mangled | `css_format.odin:13` |
| 5 | **A column filter with no sort disables `table_sort_shift`** (`nkeys == 0`), so one length-changing cell edit desyncs every row offset below it and a later edit splices at the wrong bytes | `table.odin:2432` |

Items 1–3 are the data-loss set and should lead the next batch. Item 5 is a one-predicate fix.

### HIGH, still open — 20 items

Summarised by area; the reports carry each one.

- **Save / session** (6) — unbounded `doc_absorb_append` read; a silent backup-write failure that
  loses unsaved edits at restore; BOM-less UTF-16 gaining a BOM on save; orphan-store deletion
  taking its backups with it. See [02-doc-session.md](audits/2026-08-04/02-doc-session.md).
- **UI shell** (5) — the status bar drops right-hand cells from the *draw* but `status_cell_at`
  still walks them, so a click on a narrow window fires `.Eol_CRLF`, a whole-buffer rewrite;
  `command_in_palette` excludes six commands where `command_needs_menu_target` names fourteen, so
  palette "Close Tab" closes the wrong tab; palette keyboard selection walks past the drawn rows;
  `palette_hover` overwrites keyboard selection every frame, making arrow keys inert. See
  [06-ui-shell.md](audits/2026-08-04/06-ui-shell.md).
- **Markdown / table** (4) — preview selection hit-test drops `lay.indent`, so clicking a list item
  selects ~3 characters to the right; `html_format` refuses every real HTML page (void elements
  parse as unclosed) **and is documented DONE, so this is worse than recorded**; preview table copy
  emits a tab per *span* not per *column*. See [04-markdown-table.md](audits/2026-08-04/04-markdown-table.md).
- **Platform** (3) — the crash filter allocates and takes a non-recursive lock *before* saving work,
  so a fault inside the logger or the allocator self-deadlocks it; the release exe is
  `-subsystem:windows`, so every graphics-init failure path prints to nowhere and a machine with no
  D3D11 hardware device launches and vanishes silently. See [05-platform.md](audits/2026-08-04/05-platform.md).
- **Buffer** (1) — `pt_word_left`/`pt_word_right` are uncapped one-byte-`pt_read`-per-byte scans on
  the input thread; a 4 MB base64 line is one token, so one `Ctrl+→` freezes the UI for ~0.2–0.4 s
  and the key auto-repeats. Missed by the `*_cap` sweep. See [01-buffer-core.md](audits/2026-08-04/01-buffer-core.md).
- **Find / lex** (1) — one keystroke permanently invalidates the lex-state index and it is never
  rebuilt; for Markdown/YAML/Rust/Odin the fallback resync's validator *always* rejects, so
  everything past 64 KiB lexes as `.Normal`. The header comment claiming the fallback is "correct at
  any revision" is false. See [03-find-lex.md](audits/2026-08-04/03-find-lex.md).

### Worse than already recorded

Three items where an existing entry understates the problem. These matter more than new findings,
because something already said "handled".

1. **`base`'s own scanners drop `pt_read`'s return and never check `pt.fault`**
   (`piecetable.odin:341,440,508`). HANDOFF §6af/§6ba records this shape as *swept and confirmed*
   for `doc.odin` — **the sweep never reached `base`.** On a faulting mapped read `safe_copy`
   zero-fills and still returns a full count, so `pt_line_start` walks back to offset 0 and
   `pt_content_end_cap` stops at the first NUL claiming `exact=true`.
2. **`html_format` refuses every real HTML page** — void elements (`<meta>`, `<br>`, `<img>`) parse
   as unclosed. `features.md` documents HTML reformat as working.
3. **The `\\?\` long-path debt has regrown** into `keymap.odin`, `rules.odin` and `perf.odin` while
   HANDOFF §5 still says only `diag.odin`'s append handle remains.

### Stale docs found while auditing (all fixed 2026-08-04)

- `features.md` claimed the exe was 1.21 MB (it is 1.38 MB), that the preview "cannot be selected or
  copied" (it has been selectable since v0.62.0, documented two sections earlier in the same file),
  and that the caret misaligns on CJK and emoji (v0.66.0 measured that as false and corrected
  `requested-features.md` §4, but not this file).
- HANDOFF §7's binary sizes were from 2026-07-19, 33 minor versions stale.
- **CLAUDE.md says `\\?\` long paths are "unimplemented — there is not one `\\?\` in the tree".**
  They are implemented (`platform/path.odin:189`, `wide_path`, used throughout `file.odin`). Not yet
  corrected, because CLAUDE.md is Wyatt's file — flagged for him rather than edited.
- `requested-features.md` is **missing its `## 2` heading**, so ~100 lines of UI-spec debt currently
  read as though they sit under "Asked for directly by Wyatt".

---

## From the v0.37.0 live pass (2026-08-01) — the preview half

The table half of that pass shipped as v0.38.0 (HANDOFF §6be); two of the three below shipped as
v0.39.0 (§6bf). **The tab glyph and the list-exit gap are fixed and deleted from this file.** The
scrollbar drag is what is left, and it is the one nothing here can observe.

### RESOLVED, cause unknown — dragging the scrollbar ghosted the Split-view sync

**Wyatt, 2026-08-01, on v0.41.0: *"scroll bar drag ghosting is gone now, looks normal."*** Kept rather
than deleted, because **nothing shipped between the report and the fix was aimed at it** and that is
worth knowing if it comes back.

The most likely explanation is not a fix at all: when he reported it he was running **v0.37.0**. The
v0.38.0 install was skipped that round because Newtpad was open, so the first build he actually ran
after reporting was two releases later. Which of the changes in between mattered — or whether the
original observation was of a build with something else wrong with it — is not established.

**If it returns, the investigation below is still the right one and its two dead ends still hold.**



*"grabbing the vertical scrollbar seems to have a ghosting type of thing on scrolling that way, with
the scroll wheel it looks fine"* (§5, and the same again for the preview half).

Both halves scroll to roughly the right place, so the sync itself is fine — it is specifically the
**drag** path.

**Two hypotheses were investigated in v0.39.0 and both died**, written down so the next pass does not
re-derive them:

- **The sync does not lag a frame behind the drag.** It resolves at one point per frame
  (`main.odin`), after every path that could have moved either side and before the draw reads them,
  and the drag handlers run well above it.
- **`g_vbar_preview` is not stale in Split.** There is a second draw site for exactly that case
  (`main.odin:2095`) which maintains the latch.

What is left is a **cost** hypothesis with real evidence behind it but no proof of the symptom:
`md_preview_frac` is measured at **3.322 ms** per call (markdown.odin's own note), and a drag pays
that on every frame where a wheel notch pays it once. That would read as stutter under a continuous
gesture and be invisible under a discrete one, which matches the report — and so would several other
things.

**One observation splits it, and only a person can make it:** does the *content* trail the thumb, or
does the *thumb itself* stutter under the cursor? The first points at the sync, the second at frame
cost, and they are different fixes. **Do not guess at this one** — the scroll model is where this
project has been burned most.

### FIXED in v0.39.0 — a blank line does end a list item; only the gap was wrong

Kept as a note rather than deleted, because the *report* and the *defect* were different things and
that is worth remembering. Wyatt filed it under "a blank line still ends a list item" failing. The
list ending was fine — the prose after a list really is its own block and was never swallowed. What
was wrong was that §9.3's "0.25 S **between items**" was being spent below the *last* item too, so
leaving a list was 4px where entering one was 13px. A probe over `md_walk` is what told the two apart;
reading the report at face value would have sent the fix into the paragraph join. See HANDOFF §6bf.

### Also from that pass, deliberately not queued

Two items Wyatt flagged are **CommonMark working as v0.37.0 intended**, not defects: a soft line
break inside a paragraph renders as a space unless the line ends in two spaces or a backslash (so
address blocks and blockquote continuations need them), and `---` directly under a line of prose is a
setext underline that makes it a heading. If the first one keeps costing him in real notes, the
answer is a setting — "treat single newlines as breaks", GitHub-comment style — not a parser change.

## Found 2026-08-02 while testing the wrap indent — a find match ON a wrap point highlights the wrong row

**Not reported from use; found by a fixture that happened to land on the boundary** (HANDOFF §6ce), and
recorded here rather than left in a test comment.

With word wrap on, `find_match_rects` walks visible rows and takes a match into a row when
`f.matches[mi] <= end`, where `end` is that row's **break offset**. A match starting at exactly that
byte therefore attributes to the **earlier** row — but the character at that byte is *drawn* on the
next one, because the break offset is also the following row's start. The highlight lands at the far
right of the row above the text it marks.

**Narrow, and pre-existing:** it needs a match to begin at the precise wrap point, and nothing about
the hanging indent caused it (it was found with the indent working correctly). The equivalent
selection code (`doc_selection_rects`) uses `lo <= end && hi > start`, so a *range* spanning the
boundary matches both rows and draws on both — visibly fine.

**The fix is a bound, not a redesign:** attribute a match to the row where its first byte is *drawn*,
i.e. `< end` rather than `<= end` for a wrapped row that is not a line end. Worth checking what else
reads a row's `end` inclusively while the row's own text stops before it.

## Reported 2026-08-02 — closing the last tab of one window among several

*"if an A instance only has one tab and another B instance is open... it should close A instance
instead of creating the unititled file"*

**Not yet investigated; recorded during the filtering batch.** `app_close` ends with *"last tab closed
-> fresh scratch"* (`app.odin`), which is right for the only window — a window that fails to a closed
state is worse than an empty one — and wrong once a second window exists, where the empty scratch is
just a window nobody wanted.

Two things to settle before building it, because they are not the same question:

- **Which windows count.** A second Newtpad is a separate process (§6bg), so "is another window open"
  means asking the OS, not the App. `plat.instance_claim`'s mutex says whether *any* other instance
  exists; enumerating them by window class is the other option and is what a "close me if I am not the
  last" rule actually needs.
- **What closing the window does to unsaved work.** Closing a window here is a **hot exit**, not a
  prompt (§6bh) — so "close A" must still write A's store, or the rule turns closing the last tab into
  the way to lose a buffer. A torn-off window's store is adopted by the next primary; a *primary* that
  closes itself is a different case and needs checking.

Related and already fixed, so do not re-derive it: dragging the only tab of a window is refused
outright (§6bo). If this rule lands, that refusal may want revisiting for the two-window case — they
are the same question asked from opposite ends.

## Reported 2026-08-01 — documented for a later pass, not investigated

Wyatt's list, recorded verbatim at his direction: *"just document them for a further pass later."* Each
entry separates **what he said** from **what the code says**, and the code notes below are from a few
minutes of reading, not from a real investigation. Nothing here has been reproduced.

### BUILT in v0.40.0 — tab tear-off, and what this entry got wrong

Kept as a note because the entry's own reasoning was the expensive part. It said the design question
was that *"both windows would be writing the same `%APPDATA%\Newtpad` session."* **That was already
solved** and the entry had not checked: `main.odin`'s `primary` flag gates restore, autosave,
hot-exit save and crash binding, so a second process already ran a full editor that never touched the
session store. The real missing pieces were three small ones, and the largest was that a spawned
`newtpad.exe <path>` handed its path straight back to the primary — which is why `--detach` exists.

**The lesson for this file:** an entry written from a few minutes of reading names a plausible risk,
not a verified one. Check whether the code already handles it before scoping the work off the note.
See HANDOFF §6bg.

### Web links do not open from the CSV table view (they work in text and JSON)

*"web links highlight on click but dont open the default broswer tab on click"* — then, corrected:
*"i slightly lied on the links, i'd always tested it on the csv table view... it works in a regular
text/json but not in table view."*

**So this is specific to the grid, and the document path is fine.** That is a much sharper report and it
kills most of the obvious candidates. Four things were checked in the code and are NOT the cause — written
down so the next pass does not re-derive them:

- **The path exists and is ordered correctly.** `main.odin:685` handles Ctrl+click on a link in a table
  cell, and it runs *before* the column-resize, header-sort and read-only-consume branches, so none of
  those swallows the press first.
- **The sort permutation is handled.** `table_links` steps rows with `table_row_next` (`table.odin:3012`),
  the same step the draw and `table_row_start` take, specifically so an underline positioned by data-row
  index lands on the line that index resolves to under a sort. The comment at `table.odin:594` records
  this being got wrong once already.
- **The draw/hit-test geometry seam has already been fought.** `table_link_hit`'s own comment
  (`table.odin:3019`) records a fixed bug of exactly that shape — `line_h` instead of `row_h` made the top
  of the band right and the bottom short.
- **`doc.kind == .Text` holds for a CSV**, or the header sort at `main.odin:705` would be dead too, and
  sorting works.

**The leading candidate is now resolution, and it is a real asymmetry between the two views.** The table
path is **explicitly not resolution-gated** (`main.odin:687-690`): `table_links` decorates whatever
`links_scan` finds in a cell, so a dead target in the grid *still underlines*, while the document view
only decorates links that resolve — "an underline is a promise" (`features.md:365`) is true of the
document and **not** of the grid. A cell link that fails to resolve therefore reaches `link_follow`,
which is loud on every failure path (`links.odin:975`) and should raise a `Could not resolve` box.

**UPDATE 2026-08-02 — the owed test now exists (`gridlinktest`) and it is GREEN, which eliminates the
geometry hypothesis entirely.** This was the "worth a headless test either way" item below; it is
built, and it compares what the grid *draws* as a link against what the grid treats as *clickable*.
Every one of these passes on a 3-link fixture:

- **5 points along every drawn underline hit-test**, and **3 points through every link's glyph box** —
  so `table_link_hit` does *not* return false at the pixels a person clicks. The suspected band
  mismatch (`[l.y - px, l.y - px + row_h]` against the underline at `tl.y + sx(2)`) is real in the
  sense that the band is offset down by the row's centring pad, but it still **covers** both the rule
  and the glyphs.
- **No link is clickable from another row's middle**, so the offset does not bleed into a neighbour.
- **`tl.text` is still a valid http(s) URL after `table_links` returns** — it is `strings.clone`d into
  the frame allocator, so the dangling-stack-slice theory is dead too.
- **All three links `link_resolve` successfully, to `is_url` http targets**, and **none is mistaken by
  `link_bare_reveal_target` for a bare path to reveal in Explorer.**

Also checked by reading and NOT the cause: `trows` is assigned at `main.odin:481`, before the click
site at 855, so the click and the draw size the grid identically; nothing between the frame's first
press handler and 855 consumes `mouse_pressed` outside the palette, history panel, scrollbars and
divider; `ro_surface_swallows` runs at 1047, *after* the link branch; and the document view's own link
click requires `key_ctrl_down()` too, so there is no Ctrl-vs-Show-links asymmetry between the two
views.

**Everything from the pixel to `plat.shell_open_url` is therefore verified correct.** What cannot be
exercised here is the real click arriving and `shell_open_url` itself — and the document view already
uses that same function successfully on the same schemes.

**So the question below is now the ONLY thing left, and it is sharper than when it was written:**
`link_follow` is loud on *every* failure path — three separate `message_error` calls — so if the click
reaches it at all, a dialog is guaranteed. *Does a dialog appear when you Ctrl+click a link in the
grid?*

- **A dialog** → the click is arriving and the failure is in `link_resolve` or in `plat.shell_open_url`'s
  scheme whitelist (`file.odin:725`, HANDOFF §6l). Read the dialog text; it names which.
- **Silently nothing** → the click never reached `link_follow`, which means `table_link_hit` returned
  false at the pixel he clicked, and the suspect is the band `[l.y - px, l.y - px + row_h]` at
  `table.odin:3025` against the underline the draw puts at `tl.y + sx(2)` (`main.odin:1906`) — the two
  read the same `Table_Link.y` (a *baseline*) but derive different vertical extents from it.

Worth a headless test either way: nothing currently compares what the grid *draws* as a link against what
the grid treats as *clickable*, which is precisely the seam CLAUDE.md's one-layout rule is about.

### Menu and Ctrl+F interactions feel awkward

*"there are a lot of interactions in and out of menus like Ctrl+F that are awkward but it's hard to
expalin these now."*

**Deliberately left vague — he could not pin it down and said so.** Recorded so it is not lost, and
because a vague report from daily use has been right before.

Do not guess at a fix from this. What it needs is a session where he drives and narrates, or a
focused live pass on focus transitions specifically: what has keyboard focus after opening and closing
the find bar, after Esc, after a menu opens over the find bar, and what happens to the caret and to the
selection at each of those. The find bar moved to the top in batch 12 and twelve call sites read its
inset (HANDOFF §6aq), and CLAUDE.md's own event rule is only *partially* honoured — "input is drained
from the platform queue but acted on at several points in the frame, and some widgets still resolve
state during the draw" — so there is a plausible structural cause here, which is a reason to look
properly rather than to patch a symptom.

