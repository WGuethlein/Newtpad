# Reported, not yet scheduled

Bugs Wyatt reports from daily use **between** live passes. A live-pass checklist covers one release;
this file catches everything else, so a report made mid-batch is not lost to a chat transcript.

The other two lists: [requested-features.md](requested-features.md) for what is owed or asked for, and
[features.md](features.md) for what already works.

**How to use it:** when a batch is being scoped, read this file. When an item ships, delete it from here
and record it in the HANDOFF entry instead — this file is a queue, not a history.

---

## Only the first 32 open files get external-change detection

**Found 2026-07-30** while compiling `features.md`. `MAX_TABS :: 32` (`app.odin:122`) is **not** a tab
limit — its own comment says it is the watcher's budget, *"independent of the session's tab limit
(MAX_SESSION_TABS, currently 64)"* — and `app_add` caps nothing. So the real behaviour is:

- tabs are **unlimited**,
- a session restores at most **64**,
- and **only the first 32 watched files are polled for external changes.** The rest are silently
  unwatched.

A file edited by another program in tab 33 will not show the disk-changed indicator and will not offer
to reload. Given "never lock the user's file" is a hard rule and timestamp polling is the whole
mechanism that makes it safe, a silent cap on which files are covered is worth a decision rather than a
constant. Either raise it, make it dynamic, or surface which tabs are unwatched.

## "The preview does not always respect spaces" — one defect fixed, needs Wyatt's confirmation

**Reported 2026-07-29** with a side-by-side screenshot of the editor and the preview: *"it looks like it's
not respecting the spaces all the time."* **A defect matching that description was found and fixed**
(table columns were fitted at `text_char_width`'s whole-pixel grid cell while the cells were shaped at
the font's real advance, so at the default 16px size every table cell at its natural width broke at its
last space and dropped the last word onto a second line — `md_table_char_w`, `md_table_fit_selftest`).

**Left here because it is not certain that is what he saw.** What was ruled out, with evidence, in case
the report survives the fix:

- **Runs of consecutive spaces do NOT collapse** — the preview draws every space with its own advance
  (verified on rendered pixels: `AAAA    BBBB` keeps its four-space gap). It is *more* literal than
  CommonMark here, not less.
- **Leading indentation is preserved** — an indented paragraph line keeps its spaces, and nested list
  items get their depth from the indent. It is drawn in proportional spaces, so it is visibly *narrower*
  than the same indent in the monospace editor half, which may be what looked wrong.
- **The shaper is not losing spaces** — every space in a block's classified content survives into the
  spans and into the glyph stream (0 drops over the 144 blocks of `research/newtpad-research-report.md`
  plus a 31-block fixture), and `shaped_draw` positions each glyph at the shaper's own `x`, so the draw
  cannot collapse a run either.

**If he still sees it, the remaining candidate is the line-per-block model:** every source line is its own
`.Para` with a full `para_below` gap, so two adjacent prose lines look like two paragraphs and a blank
line between them adds nothing (blank runs are zero height, margins collapse). CommonMark joins those
lines into one paragraph with a space at the break. That is a design question, not a bug — ask before
changing it.

## Ctrl+A includes trailing blank rows

**Reported 2026-07-29.** Wyatt: *"if you ctrl+A on a document with a lot of blank rows at the end, it
captures those rows in the Ctrl+A, I don't think it should do this. One failure spot for this though is
spaces between paragraphs, those should be captured."*

**What makes this a real specification rather than "skip blank lines":** the rule is about **position**,
not about blankness. A blank line *between* two paragraphs is content and must stay selected; a run of
blank lines *after the last non-blank content* is trailing whitespace and should not be. Any
implementation that filters blank lines generally will break the paragraph case, and that case is the
one worth testing first.

## INVESTIGATED 2026-07-31, and all four questions are now answered

**Question 1 is settled by measurement: the trailing rows are REAL BYTES in the file.** Nine fixtures
with known trailing-newline counts, run against a real `build\newtpad.exe` rather than reasoned from
the code: `rows == newlines + 1` in every one, including the no-trailing-newline case that would have
exposed a phantom row, and `Select_All` sets `cursor == pt.length` every time. Sabotage-verified by
reintroducing the historical `next_row_start_capped` phantom-row bug, which made the
no-trailing-newline fixture emit phantom rows. **So this is a select-all policy change, not a
rendering bug.** Full evidence: `.superpowers/sdd/reports/task8-ctrl-a-investigation.md`.

Two things found on the way:

- **`doc_visible_rows` is pure viewport geometry**, not a content count — it returned 20 for every
  fixture including the empty one. The original question conflated it with the row walk.
- **`doc_selection_rects` skips the final empty row**, so N trailing newlines highlight N−1 blank
  rows. That is what the report describes seeing, and it is a faithful drawing of real bytes.

**Wyatt's decisions, 2026-07-31 — build to these:**

1. **A second `Ctrl+A` extends to the whole buffer.** The first trims trailing blanks; pressing it
   again selects everything including them. This is the answer to "what does Ctrl+A then Delete
   leave" — measured, a trimming select-all leaves 5 bytes / 6 blank rows on the five-newline
   fixture, so delete-all stays reachable rather than being quietly lost. **This is the only part
   with real implementation risk:** `doc_select_all` bypasses `set_cursor`, so the "already trimmed"
   state will latch if the reset is placed carelessly.
2. **Whitespace-only rows count as blank.** A trailing row of three spaces is trailing whitespace by
   any reading. The scan tests for a non-whitespace byte, not merely a non-newline.
3. **An all-blank document selects everything.** With no non-blank content the rule falls back to
   today's whole-buffer behaviour, so `Ctrl+A` never visibly does nothing and Cut/Copy stay live.

**And the selection includes the last content line's terminator** (both bytes of a CRLF) — chosen so
that copying an ordinary newline-terminated file stays byte-identical to today, and only files with a
*run* of trailing blanks change at all.

**Two implementation constraints from the investigation:**

- **The rule is row-aware, not a whitespace trim.** A naive backward whitespace scan eats the
  trailing spaces of `"alpha\nbeta   "` — content on a content line. Scan back to the last non-blank
  byte, then take *that row's* content end.
- **The backward scan is unbounded**, and a multi-GB log with a huge blank tail would freeze `Ctrl+A`
  on the input thread with no way to tell it was truncated. That is development-loop §4 Shape A; it
  needs a cap, an `exact` flag, and a fallback to today's `pt.length`.

**Write this test first:** the paragraph case `"one\n\ntwo\n\n\n"`, asserting `lo <= 4 && 4 < hi` (the
interior blank line stays selected) and `hi == 9`. Sabotage it with a forward scan that stops at the
first blank row (`hi == 3`) — the exact wrong implementation this entry warns about.

**Not affected, verified:** Replace All is not selection-scoped (it runs on whole-document
`find.matches`); block/column selection is cleared by `doc_select_all`; sort/dedupe already step back
over one trailing newline for their own reasons. **Affected:** Copy, Cut, Delete/Backspace, Paste,
Tab-over-selection, the status bar's byte count, the highlight rects, and the post-`Ctrl+A` scroll.

---

**Original questions, kept for the reasoning** — the answer changes the fix:

1. **Are the trailing rows in the file, or are they Newtpad's?** If the file genuinely ends with several
   `\n`, they are real content and this is a select-all policy question. If Newtpad is *rendering* rows
   past the last newline, that is a different and more serious bug, and select-all is only where it
   became visible. Check `doc_visible_rows` / the row walk against a file with a known trailing-newline
   count before assuming.
2. **Does the selection stop before or after the final newline** of the last content line? Copying
   `"a\nb"` and copying `"a\nb\n"` are different pastes, and the difference is what people notice.
3. **What does Ctrl+A then Delete leave behind?** If select-all deliberately excludes the trailing rows,
   delete leaves them, and the document is not empty after "select all, delete" — which is likely to be
   reported as its own bug. Decide the interaction deliberately.
4. **Does it apply to the other consumers of select-all** — Ctrl+A then Replace All, the status bar's
   selection count, block/column selection — or only to the copy?

**Worth knowing:** most editors (VS Code, Notepad, Sublime) select the entire buffer including trailing
blank lines. This is a deliberate divergence, which is fine — Wyatt is the product owner and the
annoyance is real — but it should be a recorded decision rather than an accident, because someone will
eventually ask why Newtpad differs.
