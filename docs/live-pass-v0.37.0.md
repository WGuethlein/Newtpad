# Live pass checklist — v0.37.0 (the preview's paragraph model)

v0.37.0 changed **how every markdown document in the preview looks**. It shipped with 46 headless modes
green and **no live GUI pass at all** — this environment cannot inject input, so whether the re-flowed
prose actually *reads* better is the one thing only you can answer.

Ordered by how likely it is to be wrong. **⚠** marks items where something load-bearing changed and no
test can see the result.

**What to open:** a long hard-wrapped `.md` — HANDOFF.md is the ideal input, since it is exactly the
shape that was broken. Use **Split** (the divider) so you can compare source and preview side by side.

---

## 1. The thing you reported — does it actually read as prose now?

This is the whole point of the release. Before, every source line was its own paragraph with a full
paragraph gap under it, and the blank line between real paragraphs added nothing.

- [ ] Open HANDOFF.md in Preview. Do paragraphs read as **paragraphs**, filling the pane width, rather
      than as one short line per source line?
- [ ] Is there now a **visible difference** between a line break inside a paragraph (none) and a real
      paragraph break (a gap)?
- [ ] Does the text **re-flow when you resize the window**, rather than staying wrapped at the source's
      column?
- [ ] Are the paragraph gaps the right *size* — not too tight, not too airy? This is a judgement call
      and the number (0.80 × font size) is easy to change if it reads wrong.
- [ ] **Is anything worse than before?** That is the question that matters most.

## 2. Hard breaks — where a break was deliberate

CommonMark: a line ending in **two or more spaces**, or in a **backslash**, keeps its break.

- [ ] Type a line ending in two spaces, then another line. The break is kept, and the two lines are
      still one paragraph (no paragraph gap between them)
- [ ] A line ending in a single space does **not** break — it joins normally
- [ ] Address-style blocks and poetry written with trailing spaces still look right

## 3. ⚠ Wrapped list items and blockquotes

A continuation line has no bullet and no `>`. It used to render as a stray un-indented paragraph under
the marker; it should now continue the item.

- [ ] A bullet whose text wraps: the continuation sits **indented under the item's text**, not at the
      left margin, and there is **no second bullet**
- [ ] A numbered item does the same
- [ ] A task-list item (`- [ ]`) does the same, and the checkbox is not duplicated
- [ ] A nested item's continuation keeps the **nested** indent, not the top level's
- [ ] A blockquote written `> first line` then unmarked lines: one continuous bar down the left
- [ ] A **blank line** still ends a list item — the next paragraph is not swallowed into it

**Known, not worth reporting:** a blockquote with `>` on **every** line still renders as several stacked
blocks with a broken bar. It is queued (`requested-features.md` §9) and is the one place the common way
of writing looks worse than the unusual way.

## 4. ⚠ Setext headings — this changes existing documents

`Title` over `===` is now an h1, and over `---` an h2. Before, that rendered as a paragraph plus a
horizontal rule.

- [ ] `Title` then `===` on the next line renders as a **large heading**, with no rule under it
- [ ] `Title` then `---` renders as an h2, again with **no leftover rule**
- [ ] A `---` **after a blank line** is still a plain horizontal rule
- [ ] YAML **front matter** at the top of a file still renders as its card, not as a heading
- [ ] A `---` directly under a **bullet** is still a rule, not that item's underline
- [ ] **Look through your own notes for a `---` sitting right under a line of prose.** That is the one
      case whose appearance changed, and it is the likeliest surprise in this release.

## 5. ⚠ Split view — scroll sync

This is the part with the most inference behind it. A bug here drew the preview from line 0 while the
editor sat at line 100; it is fixed, but only headless tests have seen it.

- [ ] Scroll the **editor** half through a long document. Does the preview follow to roughly the right
      place, and stay there?
- [ ] Scroll the **preview** half. Does the editor follow?
- [ ] Scroll deep into the document and back to the top. Do both halves end up where they started?
- [ ] Double-click a block in the preview — the editor jumps to it
- [ ] Resize the window mid-scroll; nothing jumps to a wrong place

**Expected and not a bug:** over a long hard-wrapped paragraph the preview now moves **a paragraph at a
time** rather than a line at a time, because a paragraph is now one block. That matches the UI spec, but
it is a visible change from what you were used to — **tell me if it feels wrong in real use**, because
finer sync is buildable and is already scoped in the queue.

## 6. Speed

A whole-paragraph scan runs while you scroll, so this is worth a sanity check on real files.

- [ ] Scrolling the preview on a large `.md` is smooth, not steppy
- [ ] **Typing in Split view** is responsive — the preview re-renders per keystroke
- [ ] Typing a continuation line under a bullet: it joins the item **as you type**, without a stale frame
- [ ] Nothing hangs on a file with very long paragraphs

## 7. Nothing else broke

- [ ] Fenced code blocks still highlight, and a `---` or `===` **inside** a fence is still code
- [ ] Tables, links (Ctrl+click), task checkboxes, front matter all still render
- [ ] The editor half is unchanged — this release touched the preview only

---

## Reporting

A sentence per item is plenty. Screenshots help most for §1 (does it read right), §3 (wrapped bullets)
and §5 (sync), since those three are pure appearance and I cannot see any of them.
