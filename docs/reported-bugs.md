# Reported, not yet scheduled

Bugs Wyatt reports from daily use **between** live passes. A live-pass checklist covers one release;
this file catches everything else, so a report made mid-batch is not lost to a chat transcript.

**How to use it:** when a batch is being scoped, read this file. When an item ships, delete it from here
and record it in the HANDOFF entry instead — this file is a queue, not a history.

---

## Clicking the markdown preview in Split shifts the editor pane

**Reported 2026-07-29.** Wyatt: *"when you click in the markdown preview on split mode it shifts the
edit side up/down."*

**This is batch 17's click-to-sync working as designed, and he is reporting it as a bug.** UI spec §9.1
asks for it by name — *"click-to-sync-scroll, which only needs the nearest BLOCK"* — and §9.4 lists
scroll sync as a Split rule. So the capability is wanted; **binding it to a plain single press is what is
wrong.** A single click is what people use to focus a pane or dismiss something, and having the other
half of the window jump in response is hostile.

**Recommended fix, needs his confirmation:** move it to **double-click**. That keeps the spec'd
capability, makes it a deliberate gesture, and stops a stray click moving the editor. Alternatives worth
putting to him: Ctrl+click (but Ctrl is already the link modifier), or a command in the palette with no
mouse binding at all.

**Do not simply delete it** — it is a spec'd feature, and the mapping underneath it is also what the
scrollbar and the pane sync use.

## The preview does not always respect spaces

**Reported 2026-07-29** with a side-by-side screenshot of the editor and the preview. Wyatt: *"it looks
like it's not respecting the spaces all the time."*

**Needs reproduction before diagnosis** — the screenshot shows a markdown table and prose, and the
statement could mean at least three different things:

1. **Runs of consecutive spaces collapse in the preview.** That is what HTML/CommonMark actually
   specifies, so it may be correct-but-unwanted rather than a defect. If that is what he means it is a
   product decision, not a bug.
2. **The shaper is losing or mis-measuring spaces.** `shape_spans` has deliberate space handling — a
   space run moves the break point, trailing spaces at a break are allowed to hang past the measure, and
   `ink` is recorded at the start of a space run. A bug in any of those shows up as wrong wrap points or
   a missing gap between words. This is the one to check first, because it would be a real defect in new
   code.
3. **Leading indentation is not preserved** where markdown says it should be (a nested list, a code
   block indented by four spaces — note the fence-indent rule changed in a recent batch).

Ask him which, or find a fixture that shows it. Do not guess a fix.

## Ctrl+V with the filter bar open pastes into the document, not the filter

**Reported 2026-07-29.** Wyatt: *"ctrl+V when the filter menu is open doesn't paste into the filter menu,
it adds it to the viewport. also you aren't able to edit/remove it from the viewport while that menu is
open."*

**Two defects, and the second is what makes this urgent.** The paste is routed to the wrong target — but
the text then lands in the document *and cannot be removed*, because the viewport is not editable while
the filter bar has focus. So an accidental Ctrl+V silently modifies the file and leaves the user with no
way to undo it without first closing the filter. That is a data-modification bug wearing a focus-routing
bug's clothes, and it should be triaged as the former.

**Where to look:** the filter bar is a focused input surface, like the find and replace fields. Those
route `Ctrl+V` correctly, so the question is why the filter does not — most likely the paste command is
dispatched against the document context rather than the focused-field context. Compare against how
`Find` and `Replace` claim the key, and check whether the fix belongs in the keymap's context resolution
rather than in the filter itself. If it is the context resolution, **the same hole probably exists for
other editing keys** — check Ctrl+X, Ctrl+Z and Delete while the filter is focused before calling it
fixed.

**Also confirm:** does the document actually become `modified` (a dirty tab, a save prompt on close)?
If so the blast radius is larger than a stray paste, and this jumps the queue.

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
