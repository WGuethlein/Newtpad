# Batch 17 — the preview shaper, the type scale, and the app icon

Branch `feat/batch-17-preview`, target **v0.31.0**.

Two pieces of work, deliberately in one batch: the markdown preview stops being a monospace document
([UI spec §9.1](../../ui-spec/newtpad-ui-spec-v1.md), §9.3), and Newtpad gets an application icon
(§16). They share nothing technically — the icon is here because it is a **beta blocker** and small,
and there is no reason to make it wait behind a layout rewrite.

Wyatt's decisions, 2026-07-29: **full §9.1 rewrite** over an incremental type scale; **Georgia** as the
body face rather than embedding one; **16a Caret on paper** for the icon; icon folded into this batch.

---

## Part one — the preview drops the grid

### Why a rewrite rather than an increment

§9.1 states the case better than a summary can:

> **The preview pane does not need the grid at all.** The grid exists to make caret arithmetic, column
> selection and hit-testing O(1). The preview has no caret, no selection anchor, no column and no
> editing — it is read-only output.

That is already true in the code: `doc_read_only_view` covers `.Preview` and the table view, and batch
16's follow-up made both non-input surfaces. So the grid is being paid for and not used.

The incremental option — proportional spans on the existing line walk — was rejected because it keeps a
*line-oriented* model under proportional text. Soft wrap and scrolling both stay approximations, and
§9.1's cache (per-block layout keyed on width) has nowhere to live. We would pay for the rewrite later,
on top of more code.

### What replaces `markdown_draw`'s loop

Four things, per §9.1:

```
Block :: struct { kind, level, spans: []Span, indent }
Span  :: struct { text, style_flags, colour_role }
```

1. **A block list.** Source lines classify into blocks once, not per frame.
2. **A span list per block**, carrying style flags and colour role.
3. **One text shaper** — given a face and a max width, emit positioned glyphs and a height. **This is
   the only genuinely new code.** Per-glyph advances come from `IDWriteFontFace::GetDesignGlyphMetrics`,
   cached in the same atlas map the grid already uses. Line breaking is **greedy**: accumulate advances,
   break at the last space before max width. No Knuth-Plass, no hyphenation — greedy is what browsers do
   for body text.
4. **A scroll offset in pixels, not lines.**

Preview glyphs go into **the same atlas and the same instanced draw call** as everything else. No new
pipeline. That constraint is what keeps this a layout change rather than a renderer change.

### The one pixel→content mapping that survives

§9.1: *"you never map a pixel back to a character except for one case: click-to-sync-scroll, which only
needs the nearest **block**, not the nearest glyph. Store each block's y range and binary-search it."*

**But links are Ctrl+clickable in the preview today, and that is a real feature we are not dropping.**
So there is a second mapping the spec does not mention: a link's span needs a pixel rect. That falls out
of the shaper for free — it already produces positioned glyphs — provided `links_layout`'s preview path
consumes shaped positions instead of cell arithmetic. **This is the seam of the batch.** CLAUDE.md's rule
applies without modification: the shaper is the single producer, and the draw, the link hit-test, the
link underline and the hand cursor all consume its output. No procedure may both compute a glyph
position and consume it.

### Cost, and the cache

§9.1 again: layout only the visible blocks plus a screen above and below; cache each block's laid-out
glyph positions **keyed by (block index, pane width)**; invalidate a block on edit, invalidate all on
resize or zoom. A 778-line document lays out ~40 visible blocks — microseconds, once, per width.

Viewport-first is preserved by construction: the block list is built lazily over the visible range, not
over the document.

### The type scale — §9.3, verbatim

Sizes are multiples of the base document size `S`, so the preview scales with Ctrl+= for free.
**Compute every size as `round(k * S)` into the metrics struct once** — not per draw.

| | size | weight | face | colour | space above / below |
|---|---|---|---|---|---|
| h1 | 1.85 S | 700 | body | `md_heading` | 0 / 0.6 S + `md_rule` |
| h2 | 1.50 S | 700 | body | `md_heading` | 1.6 S / 0.5 S + `md_rule` |
| h3 | 1.25 S | 700 | body | `md_heading` | 1.4 S / 0.4 S |
| h4 | 1.10 S | 700 | body | `md_heading` | 1.2 S / 0.3 S |
| h5 / h6 | 1.00 S | 700 | body | `md_heading` | 1.0 S / 0.3 S (h6 caps) |
| paragraph | 1.00 S | 400 | body | `text_primary` | 0 / 0.8 S, line 1.65 |
| list item | 1.00 S | 400 | body | `text_primary` | 0.25 S between items |
| blockquote | 1.00 S | 400 | body | `md_quote` | 0.8 S / 0.8 S |
| code, inline | 0.92 S | 400 | mono | `md_code` | `md_code_bg`, 3px radius |
| code, fenced | 0.92 S | 400 | mono | `syn_*` | 1.0 S / 1.0 S, 6px, 12 pad |
| table | 0.95 S | 400 | mono | `text_primary` | always mono: columns align |
| caption / meta | 0.88 S | 400 | body | `text_muted` | |

**Measure: 72ch max, left-aligned, 40px left padding.** h6 is body size, distinguished by caps and
tracking, not size.

### Which faces

**Body: Georgia.** §9.3 names it as the no-embedding fallback and is explicit about why serif: *"Serif
over sans, deliberately — it is what separates 'document' from 'UI'."* Georgia is on every Windows
install. Wyatt chose not to embed a face this batch; §9.3's preferred Source Serif 4 subset (~120 KB,
OFL) rides with batch 20's in-memory font path.

**Code and tables: the existing mono face** (Cascadia Mono today). §9.3 specifies Monaspace Neon, which
is not embedded — batch 20 again. Nothing in this batch should assume Neon.

**A `Preview font` setting**, per §9.3: defaults to the body serif, with the editor font as an option
"for people who want the preview to match the source". Small, and it is the escape hatch if Georgia
reads wrong on someone's machine.

### What this reworks from the last two batches — stated plainly

The preview loop has been touched three times in a week. Being honest about what survives:

- **Fence-state seeding survives unchanged.** `md_fence_seed` answers a *lexer-state* question about a
  byte offset; it does not care how the result is drawn.
- **`md_row_geom` / per-row height admission is replaced.** Block heights come from the shaper now.
  Its lesson does not go away: **height is produced once and consumed by both the fit decision and the
  advance.** Carry that property into the block model or the sixteen-bug shape returns.
- **The front-matter card is reworked** into a block kind. Its current two-producer height risk
  disappears with it.
- **Preview scrolling stops sharing the editor's byte-offset model.** `doc.top` stays the editor's; the
  preview needs its own pixel offset. Split view has both panes on screen at once, so **the sync between
  them is now a mapping, not an identity** — that is the highest-risk consequence of this change and
  §9.4 governs it.

---

## Part two — the app icon (§16)

**16a Caret on paper**, Wyatt's choice. §16's rationale: it says "type here" with no letterform, so it
needs no localisation and reads at 16px where a letter would mush, and it reuses the app's own warm
white and accent — *"which is what makes an icon feel like it belongs to its window."*

### The artwork is rectangles, which is why this is cheap

The spec encodes it geometrically. Ratios, taken from the spec's own 96px rendering:

| Element | Colour | x | y | w | h |
|---|---|---|---|---|---|
| paper | `#F2EBE0` | 0 | 0 | 96 | 96, radius 14 |
| caret | `#D99B62` | 26 | 24 | 6 | 48 |
| line 1 | `#B3A897` | 44 | 30 | 26 | 5 |
| line 2 | `#B3A897` | 44 | 46 | 26 | 5 |
| line 3 | `#CDC3B4` | 44 | 62 | 16 | 5 |

The spec also gives 48, 32 and 16 hand-tuned rather than scaled — and at 16px **the third line is
dropped**, because three 2px bars in 16px mush. That is the whole reason for the next rule.

### Rules that are not negotiable

- **Ship 16, 20, 24, 32, 48, 64, 256 in one `.ico`, each drawn at its own size.** §16: *"do not scale
  one bitmap."* The 16px variant drops the third text line; the others carry all three.
- **The icon does not change with the theme.** §16: *"Windows caches it, and an icon that flickers
  between light and dark looks broken."* Warm paper in both themes.
- Also owed by §16 but **out of scope here**, to be recorded rather than silently skipped: a document
  icon per associated extension (same shape, extension label in the corner) and a monochrome variant for
  the notification area.

### Wiring

The `.ico` goes into `newtpad.rc` beside the existing manifest, so it becomes the exe icon, the window
icon, the taskbar icon and the Alt+Tab icon in one step. `install.ps1` already registers extensions;
the document-icon association is where the per-extension icons would later attach.

---

## Testing, and the honest limit of it

This environment cannot inject GUI input and cannot judge whether Georgia at 1.85 S *looks* right. What
can be tested headlessly:

- **The shaper** — advances accumulate, greedy breaks land at the last space before max width, a word
  longer than the measure does not loop forever, and the height returned equals the height drawn.
- **The type scale** — every size is `round(k * S)` for the specified k, at several S values and DPI
  scales. This is arithmetic and should be pinned exactly.
- **The seam** — a link's rect from the shaper equals the rect the hit-test accepts, at the measure's
  edge and across a soft-wrapped line. `md_draw_selftest`'s headless-GPU readback (built in the
  live-pass batch) is the tool: assert pixels, not intentions.
- **The cache** — a second layout at the same width returns the identical result and does no work; a
  width change invalidates; an edit invalidates only the edited block.
- **The icon** — every required size is present in the `.ico`, each has its own bitmap (not an upscale),
  and the 16px variant has two text bars rather than three.

**What only Wyatt can confirm:** whether the preview now reads as a document, whether Georgia is the
right face, and whether the icon works in a real taskbar next to real icons. A live-pass checklist ships
with the release, as it has for every batch since v0.27.0.

## Out of scope

- Embedding Source Serif 4 or Monaspace Neon — batch 20's in-memory font path.
- Markdown concealment (§9.4's "hide the marks on non-caret lines") — still its own batch; it makes the
  drawn column stop matching the byte column, which is the editor's seam, not the preview's.
- The table view, the empty tab, editor details — batch 18.
- Complex-script shaping. The shaper here is greedy Latin line breaking, not `IDWriteTextAnalyzer`
  bidi/shaping, which HANDOFF §5 tracks separately.
