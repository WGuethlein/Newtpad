# §13, finished: the status bar becomes cells

2026-08-05. Branch `fix/tab-overflow-and-status-cells`. Closes the three remaining §13 items plus
the `Status_Cell`-onto-`ui.Button` refactor §6cy deliberately left out.

Built from the **mockup DOM** (`newtpad-ui-spec-v1.html` §13, `id="s13"`), not the prose. Two things
the prose alone would have got wrong are recorded under "Corrections to the register" below.

## What the mockup actually specifies

Two rendered bar rows. Every cell is `padding: 0 12px`, `border-left: 1px solid #322d28`
(`border_subtle`) — **on every cell except the very first in the bar**.

| Row | Left group | Right group |
|---|---|---|
| 1 | `Ln 124, Col 94` · `778 lines` · `42.1 KB` | `Markdown` · `UTF-8` · `LF` · `Tab 4` |
| 2 | `Ln 124, Col 94` · `42 selected, 3 lines` **in accent `#d99b62`** | `Saved` **in `#9dc9a0`** · `Markdown` · `UTF-8` |

Prose rules that matter: *"Save confirmation lives here. `Saved` for 1.5s in `success`, then gone. No
toast, no dialog, no sound."* · *"Errors take the whole bar in `danger` until dismissed — Could not
save: file is read-only. **Nothing in this app should ever need a modal dialog.**"* · *"Every cell is
clickable."*

## Corrections to the register

1. **"the first cell in each group has none" is wrong.** The right group's first cell (`Markdown`)
   carries a `border-left` in the DOM. Only `Ln 124, Col 94`, the first cell in the bar, has none.
   The rule is "a divider at every cell's left edge except the bar's first", which is also simpler to
   state and to test.
2. **§13's ⚠ is stale and should be struck.** *"`status_cells` guards on `len(out) < 2` and callers
   pass `[4]Status_Cell`. Three more cells overflow it silently."* It takes
   `^[STATUS_CELL_MAX]Status_Cell` as of §6cq, so an undersized buffer is a **compile** error.

## Decisions taken with Wyatt (2026-08-05)

| | Decision |
|---|---|
| **Error dismissal** | **Any keystroke or a click on the bar.** The error answers something you just did, so the next thing you do clears it. No dead state a user cannot get out of. |
| **Selection cell** | **Mockup's text, and the size cell stays**: `42 selected, 3 lines` in accent, replacing the line count only — which is what the prose says. The mockup's row 2 omits `42.1 KB`, but that reads as a two-cell illustration, and a file's size does not stop being true because something is selected. |
| **Left-group clicks** | **`Ln, Col` → `Goto_Line`; the other two inert.** The line count and the size have no honest verb, and inventing one is the hidden cycle the register already rejected for language and tab width. |

## The notice model

One severity on the existing transient rather than a parallel mechanism:

```odin
Notice_Kind :: enum u8 { Info, Success, Error }
```

| Kind | Lifetime | Drawn as |
|---|---|---|
| `Info` | `NOTICE_SECONDS` (4.0), unchanged | centred, `Warning` — every existing `[BRACKETED CAPS]` note |
| `Success` | **`SAVED_SECONDS` (1.5)**, per §13 | the **head cell of the right group**, in `Success` |
| `Error` | **none — until dismissed** | **the whole bar**, in `Danger`, cells suppressed |

`[SAVED]` becomes `Saved` and a `Success`. **`report_save`'s modal message box becomes an `Error`**,
which is the point of the rule: §13 names the modal it is replacing.

**Only the save failure converts in this batch.** The other `[BRACKETED CAPS]` notes stay `Info` —
a sticky red bar for `[NO MATCHES TO REPLACE]` would be worse than what ships. The mechanism is there
for the rest; converting them is owed work, one judgement per message.

**`Saved` drops last of all**, ahead even of the language, which §5 makes the longest-lived cell. §5
never ranked it because it did not exist. The reasoning: it is transient and self-clearing, so keeping
it costs at most 1.5s of one other cell, while dropping it loses the confirmation entirely on exactly
the narrow window where the tab's asterisk is hardest to see.

## The geometry

**`Status_Cell` becomes `ui.Button`.** It already has the box, the label origin and an `int` tag; the
tag carries the `Command_Id`. `status_cell_at` becomes `ui.button_hit`. `pad = sx(12)` is the mockup's
padding, so the box and the divider both derive from one metric.

**One producer for the whole bar,** left group and right group together, because the divider rule
("every cell except the bar's first") spans both and the drop rule needs the left group's true width.
The draw, the hit-test, the hover and the cursor all consume that one list — CLAUDE.md's one-layout
rule, which the right group already honoured and the left group could not, being a single text run.

The drop stays where §6cq put it: **decide survival first, place second**, so the right group stays
flush and a dropped cell leaves no hole.

## Test plan

`statusbartest`, one argument, non-zero on failure, in HANDOFF §7 — the rules that file gives for a
new mode. Cases:

| # | Asserts |
|---|---|
| 1 | the left group is three cells, and `Ln, Col` is the only one with a command |
| 2 | **the divider rule as a value**: a divider at every cell's left edge except index 0 — counted, not bounded |
| 3 | the selection cell replaces the line count, carries both numbers, and is the only accent cell |
| 4 | the size cell survives a selection (the decision above), and drops on an empty buffer |
| 5 | `Saved` appears as the right group's head cell, in `Success`, and is gone after 1.5s |
| 6 | `Saved` outlives every other cell under `pack` at a narrow width |
| 7 | an `Error` suppresses every cell and takes the full bar width |
| 8 | a keystroke clears an `Error`; **a keystroke in the same frame that raises one does not** |
| 9 | **the seam**: every drawn cell hit-tests to its own command, sampled at both edges and the middle |

Sabotages to run, each alone: drop the divider-suppression on cell 0; give `Saved` an ordinary drop
priority; clear the error *after* dispatch instead of before; shift one cell's box against its label.
