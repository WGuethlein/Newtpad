# Preview paragraph joining — design

**Date:** 2026-08-01
**Branch:** `fix/preview-paragraph-join`
**Closes:** the one open item in `docs/reported-bugs.md` — *"the preview does not always respect
spaces… it's like it's messing up the formatting of sentences"* (Wyatt, 2026-07-29 and again on
v0.35.0, 2026-07-31).

---

## 1. The defect, root-caused

`md_classify` (markdown.odin:1882) classifies **one source line at a time**, and `.Para`'s content is
that whole line. `md_layout_build`'s `.Para` case (markdown.odin:2587) then gives every one of them
`e.below = m.para_below` — 0.80 × S of paragraph gap. `.Blank` collapses to **zero** height
(markdown.odin:2487), because §9.3's space-above/below columns are what put air between blocks.

The consequence in any hard-wrapped document — HANDOFF.md, a README, a spec, which is most of what
Wyatt reads in the preview:

- every **source line** renders as its own paragraph, with a full paragraph gap beneath it
- the **blank line** that actually separates two paragraphs contributes nothing on top of that
- so a sentence spanning two source lines becomes two visually separate paragraphs, and real
  paragraph boundaries become indistinguishable from line boundaries

"Not respecting the spaces" is the same defect seen from the other side: CommonMark inserts a space
when it joins two lines of a paragraph, and today there is no join for a space to be inserted into.

The earlier investigation (recorded in `reported-bugs.md`) had already ruled out the alternatives with
evidence — runs of consecutive spaces do *not* collapse, leading indentation *is* preserved, and the
shaper drops no spaces over a 144-block corpus. It named the line-per-block model as the remaining
candidate. **That is confirmed here from the code, not inferred from the symptom.**

## 2. What we are building

CommonMark's paragraph model, in the preview only. Wyatt's decisions, 2026-08-01:

1. **Join.** Consecutive prose lines merge into one paragraph, re-flowed to the pane width. Blank
   lines become the real paragraph separator.
2. **Lazy continuation too.** An unmarked line following a list item or a blockquote continues *that*
   block — inheriting its indent and marker — rather than becoming a stray un-indented paragraph.
3. **Setext headings.** `Text` over `===` is an H1, over `---` is an H2.

Hard breaks are honoured: a line ending in two or more spaces, or in a backslash, keeps its break.
That is not a decision, it is a consequence — see §4.3.

**Out of scope, deliberately:** everything else CommonMark specifies. This is a fix to the paragraph
model, not a conformance project. No reference links, no autolinks, no HTML blocks — those are
already listed as owed in `requested-features.md` §2 and stay there.

## 3. Why this is much smaller than it looks

Three pieces of machinery this needs already exist and are already load-bearing:

**A block may already span many source lines and be taller than the pane.** `Md_Anchor` carries a
block plus a sub-block offset, `md_block_admit` (markdown.odin:1798) admits a block one visual line
at a time, and `md_block_lines` reads `len(lay.sh.line_boxes)`. Tables and fenced blocks already
exercise all of it. **Joining paragraphs adds no new scroll machinery whatsoever.**

**The shaper already breaks on `\n`** (shape.odin:287, and shape.odin:405 handles two in a row). So a
hard break inside a joined paragraph costs one character in the joined string, not a shaper change.

**The insertion point is one field.** The general span path builds from `e.cls.content` via
`md_inline(content)` (markdown.odin:2665-2666), then shapes it at `measure - e.indent`
(markdown.odin:2741) and reads the height back off the shaper. **Set `e.cls.content` to the joined
text and advance `e.end`/`e.next`, and spans, wrapping, span boxes, links, hit-testing, admit and
height all follow with no further change.** Emphasis spanning a line break (`**bold` / `text**`)
starts working as a side effect, which is also what CommonMark says should happen.

## 4. The design

### 4.1 One producer of a paragraph's bounds — `md_para_bounds`

The hazard is not the join. It is that a paragraph now **starts above its own line**, and two
different procedures answer "where does the block containing byte B start":

- `md_layout_build`, walking forward from a block start
- `md_block_at_byte` (markdown.odin:3516) and `md_anchor_from_top`, which run *backward*
  `MD_RUNUP_LINES` and then walk forward

`MD_RUNUP_LINES :: 24` is a fixed line count, and the code **already documents this exact failure**
for front matter (markdown.odin:3028-3032: `MD_FM_MAX_LINES` is 64, so a run-up landing inside a
25–65 line front matter reads its lines as rules and paragraphs instead of reaching byte 0, and the
comment is honest that a 30-line fixture showing no divergence "is an absence of a demonstrated
defect, not a proof the case is handled"). A joined paragraph would be the **second** construct with
that property, and unlike front matter it occurs in every document.

**This is CLAUDE.md's one-layout rule applied to a block instead of a widget**, and the fix is the one
this file already uses for the same problem: `md_table_bounds` (markdown.odin:664).

`md_para_bounds(doc, p) -> (start, end, capped, ok)` is modelled directly on it, including its three
documented traps, each of which shipped once:

- **Both bounds measured from the entry point `p`, never from the moving `start`.** `start - q` is
  invariantly zero if written the other way, so the guard is dead code and the backward walk runs to
  byte 0 — on the UI thread.
- **The forward guard measured from `p` too**, or it trips on the first iteration the moment the
  backward walk has moved `start`, collapsing the window to one line.
- **`capped` derived once, after both scans, from the window they produced** — never "did a guard
  fire during scanning". Which guard fires depends on where within the block the viewport landed, so
  an entry-dependent flag gives the same block three different answers depending on scroll position.
  That is precisely the scroll-dependent shift this whole cache exists to prevent.

A mid-line entry point is handled the same way `md_table_bounds` handles it: `p` need not be a line
start — `markdown_draw` walks a line longer than `RENDER_LINE_CAP` in capped segments, and `doc.top`
can land mid-line — so `pt_line_start_cap`'s `exact` flag seeds the truncation state rather than
`start = p` being trusted.

**Budget.** `MD_PARA_BUDGET :: 256 * 1024` with `#assert(MD_PARA_BUDGET > RENDER_LINE_CAP)`, plus
`MD_PARA_MAX_LINES` as the row-count analogue, mirroring `MD_TABLE_BUDGET`/`MD_TABLE_MAX_ROWS`
exactly. Both get the **runtime-copy pattern** (`md_para_budget := MD_PARA_BUDGET`,
markdown.odin:576) so a test can lower them and drive the truncation path on a small fixture instead
of building a 256 KB one. That pattern exists because two Criticals once hid behind a test that
bypassed the bounds function entirely; the drive-through is what actually tests truncation.

**The honest residual.** In a document with an unbroken run of non-blank prose longer than the budget,
the backward and forward scans can truncate at different places depending on entry point, so the block
boundary becomes scroll-dependent. `md_table_bounds` has the identical residual and bounds it the same
way. It is a spacing and scroll-position artifact in a read-only preview — **not** a data path, and
the file is never rewritten. It gets a comment saying so rather than a claim that it cannot happen.

### 4.2 The join predicate

**Join while the next line classifies as `.Para`.** One predicate, reusing `md_classify` itself, so
there is no second definition of what a paragraph line is. Everything that already terminates a
paragraph keeps terminating it — blank, fence, rule, heading, quote, list, table row, EOF — because
`md_classify` already tests all of them ahead of the `.Para` fallthrough.

Note what this correctly does *not* do: a line that looks like a list item, following a paragraph
line, still **starts a list**, because `md_classify` returns `.List` for it and the join stops. That
is CommonMark's rule and it falls out of reusing the classifier rather than needing a rule of its own.

### 4.3 Hard breaks

A line ending in two or more spaces, or in a backslash, ends with a hard break. Since we now join, not
honouring these would *destroy* breaks the author asked for — so this is required by the join, not an
extra feature. The joined string gets `\n` at that point instead of a space, and the shaper does the
rest (shape.odin:287). The trailing spaces or backslash are stripped from the emitted text.

### 4.4 Lazy continuation (decision 2)

An unmarked line whose previous block is a `.List` item or a `.Quote` continues it. This makes a
block's kind depend on its predecessor, which `md_classify` — deliberately pure, one line in, one
class out — cannot express on its own.

**So the dependency goes in `md_para_bounds`, not in `md_classify`.** The bounds function is already
looking backward; it reports which block kind owns the run it found, and `md_layout_build` uses that
to pick the indent and marker. `md_classify` stays pure and stays the single answer to "what kind is
this *line*". A continuation line inherits the owning block's `e.indent` and `e.level` and draws no
second bullet.

This is the piece most likely to be wrong, because it is the only part of the design that adds a
backward dependency between blocks. It gets its own task and its own reviewer risk note.

### 4.5 Setext headings (decision 3)

A `---` or `===` line is `.Rule` today. It is a setext underline only when the **previous** line is a
`.Para` line — the same backward dependency as §4.4, and it is resolved in the same place for the same
reason: **`md_classify` stays pure and keeps returning `.Rule` for that line in isolation.**
`md_para_bounds`, which is already looking forward from the paragraph, sees the underline as the line
that terminates the run and reports it; `md_layout_build` then promotes the block to a `.Heading` of
level 1 (`===`) or 2 (`---`) and extends the block's `end`/`next` past the underline so it is not also
drawn as a rule. One mechanism for both backward dependencies, not two.

**The known risk, accepted:** a document with a divider immediately after a line of prose and no blank
line between them renders differently than it does today. That is what every other renderer already
does with that input, and the blank line before a divider is the overwhelmingly common way it is
written — including in this repo's own docs.

## 5. What has to be tested, and how it can fail

Newtpad's testing rule is that a test which has never failed proves nothing, and eleven consecutive
batches have shipped assertions that could not fail. Every item below names the sabotage that must
make it fail, and the sabotage output goes in the task report.

New headless mode `mdjointest`, **one argument, exits non-zero, builds its own fixture**, per the rule
in development-loop §6 that a mode nothing runs is worse than no mode. Added to HANDOFF §7 and
development-loop §6 in the same commit that creates it.

| Claim | Sabotage that must break it |
|---|---|
| Two prose lines join into one paragraph with a space at the join | Remove the space at the join — assert the joined text, not just the block count |
| The block's extent covers both source lines | Leave `e.next` at the first line's end; the second line must not appear twice |
| A blank line still separates two paragraphs | Make `.Blank` non-terminating; the two paragraphs must merge and the test must catch it |
| **`md_para_bounds` is entry-independent** | Enter the same paragraph at its first, middle and last line — all three must return identical `start`/`end`/`capped`. Sabotage: measure the forward guard from `start` instead of `p` |
| A hard break survives the join | Strip the two trailing spaces; the paragraph must lose a line box |
| A wrapped list item stays indented under its bullet | Drop the inheritance in §4.4; the continuation must fall to zero indent |
| Setext only fires after a Para line | Feed `---` after a blank line; it must stay a `.Rule` |
| The budget truncates rather than scanning to EOF | Lower `md_para_budget` on a fixture that exceeds it and assert `capped` — this is the drive-through, and it is the *only* thing that tests truncation |

Plus the existing suite, unchanged: `mdtest`, `mdviewtest`, `splittest`, `linktest`, and
`odin test src\base`. `md_selftest` (markdown.odin:24) gets the new cases for `md_para_bounds`.

**The scroll seam is the one to watch in review.** `md_block_at_byte`, `md_anchor_from_top`,
`md_slot_at` and `md_max_anchor` all resolve a byte to a block; a paragraph that starts above its own
line is exactly the input that made front matter's run-up imprecise. Test that scrolling into the
middle of a long paragraph and back out lands on the same pixel.

## 6. Live pass

Everything above is headless. The preview's appearance — whether the re-flowed prose actually reads
better, whether the paragraph gaps are now right, whether a wrapped bullet looks correct — can only be
judged on real pixels by Wyatt. This environment cannot inject GUI input. **A live pass on a real
document is required before this is called done**, and HANDOFF will say so rather than claiming the
appearance was verified.

## 7. What this touches

`src/program/markdown.odin` almost entirely: `md_classify`, `md_layout_build`, a new
`md_para_bounds`, new constants beside the table ones. `src/program/test_modes.odin` for `mdjointest`.
No change to `src/base`, the platform layer, the piece tree, or any write path — **the preview is
read-only and this design does not go near a byte that gets saved.**

**Effect on the `renderer`/`ui` extraction: none.** No new upward call sites, no new cross-module
dependency. Recorded because the last two batches each made the extraction measurably harder and
HANDOFF now tracks it per batch.
