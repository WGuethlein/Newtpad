# Column / block editing — design

**Date:** 2026-07-26
**Batch:** 5 of the plan in HANDOFF §6u
**Target version:** 0.15.0
**Status:** SPEC ONLY — not planned, not implemented. One decision needs Wyatt (see "The
open fork"). Three further decisions are recorded as *stated assumptions*, made in his
absence and overturnable.

## Why

Rectangular select-and-edit was **V1 decision #1** — research §G's "consensus #1 gap",
flagged by four of six research lenses — and has never been started. HANDOFF §6u locked its
shape on 2026-07-25: rectangular select plus edit, with **Ctrl+D select-next-occurrence
explicitly out of scope** (that is the multi-cursor work research §G deferred to V2). This
spec does not relitigate either.

## Decisions taken with Wyatt

1. **Ctrl+D is out.** Locked, §6u decision 2.
2. **A zero-width rectangle acts as N carets in one column**, so lines can be prefixed. This
   is the single most-wanted case, not a side effect.

## Stated assumptions — made without Wyatt, overturnable

These were put to him with recommendations on 2026-07-26; he authorised continuing before
answering, so they are recorded here as assumptions rather than decisions.

1. **Gesture: Alt+drag (mouse) and Alt+Shift+arrows (keyboard).** §6u's text names
   Ctrl+Shift+arrows, and that is wrong for this codebase — the keymap matches on
   `(key, ctrl, alt)` with **shift read by the action, not part of the chord**
   (`commands.odin:232`). `Ctrl+Shift+arrow` is therefore *already* word-wise select-extend,
   and taking it for column select would break word selection. `Alt+Shift+Left/Right` are
   free; `Alt+Shift+Up/Down` land on the existing `Move_Line_Up`/`Down` binding with shift
   set, so those two actions branch on shift. This also matches VS Code and Sublime.
2. **Short lines: pad on edit only.** A line shorter than the rectangle's left edge
   contributes nothing to the selection, but an edit pads it with spaces out to the column so
   the edit lands in the right column on every row. Without padding, block-prefixing a ragged
   file silently skips rows, which is the whole use case. Full virtual space — a caret that
   can sit past end-of-line anywhere — was rejected: it touches every existing caret and
   navigation path, not just the new code.
3. **Clipboard: rows as lines, plain text, no private block flag.** Round-tripping a block
   through the clipboard needs a custom format *and* a rule for pasting a 5-row block into a
   3-row target, which is the kind of option CLAUDE.md principle 3 says to fight. Plain text
   interoperates with every other application and is predictable in both directions. Block
   paste is additive later if wanted.

## The open fork — word wrap

**This is the question that needs Wyatt, and it is why this spec stops here.**

A rectangle is defined over screen rows. With word wrap **off**, one visual row is exactly one
logical line and a rectangle is unambiguous. With wrap **on**, one logical line becomes many
visual rows, and "the rectangle spans rows 10–13" can mean two irreconcilable things:

- **Visual rows** — the rectangle covers four wrapped fragments, possibly all of the *same*
  logical line. Editing then inserts text into the middle of one line at four points chosen by
  where the renderer happened to break it. The result depends on the window width, and
  resizing the window changes what a repeat of the same gesture does.
- **Logical lines** — the rectangle covers four whole lines, but it no longer matches what is
  drawn on screen: the user dragged across four visual rows and got an edit spanning a page.

Neither is defensible as a silent default. The three real options:

| Option | Behaviour | Cost |
|---|---|---|
| **A. Require wrap off (recommended)** | Alt+drag while wrapped posts a status note saying column select needs wrap off. | Honest and unambiguous; costs Wyatt a Alt+Z when he wants both. |
| **B. Auto-disable wrap** | Entering block mode turns wrap off for that document. | No dead gesture, but silently changes the view out from under the user — and the view is a persisted per-document setting. |
| **C. Operate on visual rows** | The rectangle is exactly what is drawn. | Edits become window-width dependent. Rejected unless Wyatt wants it. |

**Recommendation: A.** It is the only option where the same gesture on the same file always
produces the same edit.

## The model, and the risk that dominates it

A rectangle is **not** expressible in the existing selection model. Selection today is a
single `cursor`/`anchor` pair of **byte offsets** (`doc.odin:645`). A rectangle needs:

```odin
block:              bool, // a rectangular selection is active
block_anchor_line:  int,
block_anchor_cell:  int,
block_cursor_line:  int,
block_cursor_cell:  int,
```

Lines are logical line indices; **columns are cells, not bytes and not codepoints.** Newtpad
renders on a monospace cell grid (roadmap item 3): `text_cell_width` classifies each codepoint
as 0, 1 or 2 cells, and the caret, selection, hit-test and find rects all map offset↔cell
through that primitive. A rectangle drawn on screen is a *cell* range, so every row must
convert that cell range to its own byte range independently — a CJK character or a tab makes
those conversions differ per row.

**This is Shape B territory, and it is the whole risk of the batch.** The codebase's recurring
bug is "a correct, tested function fed the wrong input, or its result read in the wrong space",
and this feature has two coordinate spaces (cells and bytes) crossed with two line spaces
(logical and visual). The countermeasure is CLAUDE.md's **one layout per widget**, applied to a
non-widget exactly as batch 4 applied it to `doc_row_lex_extent`:

> **One procedure — `block_row_range(doc, line, cell_lo, cell_hi) -> (byte_start, byte_end, pad_cells)` — makes the cell→byte decision for a row, and the draw, the hit-test, the copy and the edit all ask it.** No caller may derive a row's byte range itself. The test compares what is *drawn* against what is *edited*, at boundary sizes, with a tab and a CJK character in the fixture.

`pad_cells` is how virtual space stays in one place too: it reports how many spaces a short
line needs to reach `cell_lo`, so the edit path pads and the draw path knows the row
contributes nothing.

## Operations

All of these mutate text on many lines at once, which is why they are specified together.

- **Typing a character** replaces `[cell_lo, cell_hi)` on every spanned line; on a zero-width
  rectangle it inserts at `cell_lo` on every spanned line.
- **Backspace / Delete** delete the rectangle; on a zero-width rectangle they delete the cell
  before / after the column on every spanned line.
- **Copy / Cut** produce the rows joined with the document's own line ending (CRLF is
  preserved per the existing save contract, so the clipboard must not hardcode LF).
- **Paste** is unchanged — plain lines, inserted at the caret, per assumption 3.
- **Escape** clears the block, like `Clear_Selection` does for a normal selection.

Two properties are non-negotiable:

1. **One undo step.** `doc_batch_begin` / `doc_batch_end` already exist for exactly this
   (`doc.odin:1188-1200`) and are what Replace All uses. A block edit that lands as N undo
   entries both is wrong and overflows the undo stack.
2. **Edits apply bottom-up, highest line first.** Editing line 10 invalidates every byte offset
   below it. Applying top-down with pre-computed offsets is the classic form of this bug, and
   it corrupts silently rather than failing.

## The cap, and saying so

A rectangle over a multi-GB file can span millions of lines. An unbounded block edit is both a
freeze and a data hazard.

This is **Shape A** — "a bounded scan reports a confident wrong answer" — which this codebase
has produced seven times. A block edit must have an explicit line cap, and on hitting it must
**refuse the whole edit and say so in the status bar**, never perform part of it. A partial
rectangular edit is unrecoverable-looking damage across a file the user cannot easily inspect.
Refusing is recoverable; half-editing is not.

The same applies to the selection itself: dragging a rectangle across a million lines must not
walk a million lines per frame. The rectangle is stored as four integers, so the *selection* is
O(1); only the draw (bounded to the viewport already) and the edit (capped, above) touch lines.

## Testing

This environment cannot inject GUI input, so every claim about the gesture is an inference from
source and Wyatt's live pass is mandatory before merge. What *can* be tested headlessly, in a
new `blocktest` mode:

1. **The seam:** for a fixture containing a tab and a CJK character, the byte range
   `block_row_range` reports for each row equals the range the draw highlights *and* the range
   the edit replaces. Compare drawn against edited, not each against a hand-computed constant.
2. **Ragged lines:** a rectangle spanning lines shorter than `cell_lo` pads exactly those lines
   and only on edit, never on selection.
3. **Zero-width prefix:** inserting `// ` on a zero-width rectangle across N lines prefixes
   every line at the same column, including short ones.
4. **One undo step:** a block edit across N lines, then one undo, restores the original bytes
   exactly — compared as bytes, not as a line count.
5. **Bottom-up ordering:** an edit whose rows change length must produce identical output to
   applying the same edits individually in reverse order. Sabotage: apply top-down and watch it
   corrupt.
6. **The cap refuses whole:** a rectangle over more than the cap leaves the buffer **byte-identical**
   and posts the note. Sabotage: let it perform a partial edit and watch the byte comparison fail.
7. **CRLF preserved:** copy from a CRLF document yields CRLF-joined rows.

Every one of these is sabotage-verified per CLAUDE.md — reintroduce, watch it fail, capture the
output, restore.

## Out of scope

- **Ctrl+D / multi-cursor.** Locked out in §6u.
- **Block paste** (re-inserting a copied block as a rectangle). Assumption 3; additive later.
- **Full virtual space.** Assumption 2.
- **Column select under word wrap**, pending the fork above.

## What has to happen before this is planned

1. **Wyatt answers the wrap fork.** It changes the gesture handling, the model (`line` means
   logical or visual), and three of the seven tests. Planning before it is answered would mean
   writing code twice.
2. **Wyatt confirms or overturns the three stated assumptions.** The gesture one in particular
   contradicts §6u's own text, for a reason §6u could not have known.
