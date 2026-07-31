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

**Questions to answer before building it** — the answer changes the fix:

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
