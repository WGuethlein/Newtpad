# Batch 10 — text operations (design)

Batch 10 of HANDOFF §6aa, the **last feature batch before the beta**. Three items from research §C's
secondary list, all named there as cheap and high-frequency for the log-and-data audience this
product is aimed at.

Decisions taken with Wyatt, 2026-07-27, before any code. **Do not relitigate.**

1. **Sort: selection first, whole document when there is no selection. Ascending, plus a descending
   variant.** No case-sensitivity or numeric-order options — principle 3, "every added option signals
   leakage in core design".
2. **Remove duplicates: all duplicates, keeping the first occurrence.** Not `uniq`-style adjacent-only,
   which silently leaves duplicates on unsorted input and reads as broken.
3. **Keyword→colour rules live in `%APPDATA%\Newtpad\rules.txt`**, global, reusing the theme's
   `Color_Role` names — the same shape `keys.txt` (§6ad) and the theme files already use.

## Item 1+2 — sort lines, and remove duplicate lines

Four commands: `Sort_Lines`, `Sort_Lines_Desc`, `Remove_Duplicate_Lines`. (Three, not four — the
descending variant is its own command because shift is not part of a chord, §6ad.)

**Scope:** the selected lines, expanded to whole lines at both ends; the whole document when the
selection is empty. Expanding is not optional — a sort that operated on a partial first and last line
would corrupt them, and the user's selection almost never lands exactly on line boundaries.

**These are document mutations, so three existing mechanisms constrain them:**

- **One seam.** `pt_edit_replace` is the single piece-table mutation point (§6ad collapsed the
  bookmark shifting onto it). Sort and dedupe must go through it, as **one** replace of the affected
  region — not a per-line edit loop. §5's `pt_insert` measurement is the precedent: 2,000 per-row
  splices cost 64 ms and fragment the tree, where one region replace costs what a single edit costs.
- **One undo entry.** A sort is one user action. `doc_batch_begin`/`end` already exist for exactly
  this (replace-all uses them, §6i), and getting it wrong means N Ctrl+Z — with `UNDO_MAX :: 200` a
  large sort would evict the pre-sort state entirely, which is a data-loss path.
- **Bookmarks.** §6ad's bookmarks are byte offsets of line starts, shifted by `bookmarks_shift_replace`.
  **A sort reorders lines, so every bookmark's offset becomes meaningless** — the shift rule cannot
  express "this line moved somewhere else". The honest behaviour is to **drop bookmarks inside the
  sorted region** and say so, exactly as `Reload from Disk` and EOL conversion already do. Silently
  leaving them pointing at whatever line landed on that offset is the §6ad Alt+Down bug again, and
  that one shipped.

**Read the region once, sort in a temp buffer, write once.** The region read needs its own byte cap
for the same reason §5's block-edit note gives — "2,000 rows of long lines is unbounded". Decide the
cap, state it, and make exceeding it a **refusal** that changes nothing, which is the shape
`BLOCK_EDIT_MAX_LINES` and the reopen cap already use.

**Line endings.** The document's `eol` is CRLF or LF and `detect_line_ending` counts only `\n`
(§6ab). Sort must not silently normalise; a CRLF file must come back CRLF. The trailing line —
whether the document ends with a newline — must survive too, or every sort appends or eats one.

**Testing:** `sortlinestest` — ascending, descending, selection-scoped, whole-document, stable for
equal lines, CRLF preserved, no-trailing-newline preserved, one undo entry restores everything,
bookmarks in the region dropped and bookmarks outside it kept, the cap refuses rather than truncates.
Dedupe: first occurrence kept, later ones dropped regardless of distance, dedupe of an already-unique
region is a no-op that still costs one undo entry or none at all (decide which and assert it).

## Item 3 — keyword→colour rules (`rules.txt`)

Research §C: *"disproportionately loved by log users"* and cheap given the renderer. It is the poor
man's highlighting that needs no lexer, and it is the one item on the list aimed squarely at the
audience Newtpad courts.

**Format:** one `pattern = role` per line, `#` comments, unknown roles and malformed lines ignored
with a logged warning, never fatal — the tolerance `settings.txt`, the themes and `keys.txt` all
share. **Roles are `Color_Role` names**, so a rule cannot invent a colour and every rule is themeable
for free: the same `rules.txt` reads correctly in Dark and Light because it names a role, not an RGB.
A `View ▸ Edit Colour Rules...` row seeds and opens the file, mirroring *Edit Keybindings...* and
*Edit Current Theme...* including reload-on-save.

**Literal substrings, not regex.** Regex costs 16–19 ms/MB (§6d) and this runs per visible row, per
frame. A literal multi-pattern scan over a row is what the renderer can afford. Say so in the seeded
header rather than letting someone discover it by writing `^ERROR`.

**The real design question is precedence**, and it must be answered in the plan, not at the keyboard.
`highlight_merge_spans` (`highlight.odin:455`) already merges two span producers — the lexer and
links — with a documented survivor rule, and its contract is strict: *sorted ascending by start, no
overlaps*, because `text_draw_spans` has no defined behaviour for overlapping input. Colour rules are
a **third** producer. Options, with the trade stated:

- Rules **under** the lexer: a `.log` file has no lexer worth speaking of, so rules win where they
  matter and never fight real syntax. But in a `.json` a rule for `ERROR` loses to the string token.
- Rules **over** the lexer: rules always show, at the cost of punching holes in syntax colouring.

**Whichever is chosen, it must go through `highlight_merge_spans` rather than beside it** — a third
producer merged by a second mechanism is how the "no overlaps" precondition gets violated, and the
failure mode is undefined rendering, not a wrong colour. Extending it to N producers with one
precedence order is the change; a parallel path is not.

**Cost per frame is the other constraint.** This runs for every visible row, every frame, inside the
same budget the lexer already spends. A naive "for each rule, scan the row" is O(rules × row) per row.
Bound it: cap the rule count, and state the measurement. `drawcount` is now headless and reports an
instance-stream digest (§6ab), so the before/after is measurable rather than argued.

**Testing:** `rulestest` — parse good/unknown-role/malformed/duplicate lines; a rule colours a match;
overlapping rules resolve deterministically; precedence against a lexer token and against a link is
asserted in both directions; an empty file changes nothing; the row-token cap is respected. Plus a
`drawcount` before/after on a file with rules active.

## Out of scope

Regex rules; per-extension scoping (global only — most people want ERROR red everywhere, and scoping
needs a syntax); sort with numeric/natural ordering or case sensitivity; `uniq`-style adjacent
collapse; a UI for any of the three files.

## Verification

Per `docs/development-loop.md`. The risks to name to reviewers, by item: **1+2** the bookmark drop,
one-undo-entry, CRLF and trailing-newline preservation, and the region cap being a refusal;
**3** the precedence order actually holding at the merge, the no-overlap precondition, and per-frame
cost at the rule cap.

**Nothing here can be verified against real GUI input.** Sort and dedupe are headless-testable end to
end, which makes them the strongest-verified items in the batch; the colour rules' *appearance* is
not, and Wyatt's pass is owed on whether the precedence reads correctly on a real log.
