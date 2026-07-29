# Reported, not yet scheduled

Bugs Wyatt reports from daily use **between** live passes. A live-pass checklist covers one release;
this file catches everything else, so a report made mid-batch is not lost to a chat transcript.

**How to use it:** when a batch is being scoped, read this file. When an item ships, delete it from here
and record it in the HANDOFF entry instead — this file is a queue, not a history.

---

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
