# Batch 9 — keys and navigation (design)

Batch 9 of HANDOFF §6aa, the first of the two feature batches between here and the beta. Five items,
all user-visible, all independent of each other — which makes this the cleanest fan-out on the
remaining roadmap and a good batch to run tightly.

Decisions taken with Wyatt, 2026-07-27, before any code. **Do not relitigate.**

1. **Rebindable keys are a `keys.txt` file**, not an in-app capture UI. The UI is a whole widget —
   conflict detection, reserved chords, reset-to-default — and is realistically its own batch. The
   file matches the shape `settings.txt` and `*.theme` already use, and revisiting it is conditional
   on the file actually being painful in real use.
2. **Bookmarks: simple toggle plus next/prev, persisted.** No numbered bookmarks — they would consume
   nine chords, and `Ctrl+1..9` is what most editors use for tab switching, which is a plausible
   later want.
3. Batch-11 answers taken at the same time and recorded here so they are not lost: **proprietary
   free-beta EULA**, and **manual-check-only updater** (no background traffic).

## Item 1 — the user keymap overlay (`keys.txt`)

CLAUDE.md: *"Rebindable keys are a runtime user-keymap overlay, not codegen."* The hard half has
existed since the tabs batch: `commands.odin` holds `[Command_Id]Command` metadata and a separate
`default_bindings` table, deliberately split *"so keys are rebindable later (a user overlay)"*
(`commands.odin:4`). Only the overlay is missing.

**Shape.** `%APPDATA%\Newtpad\keys.txt`, one binding per line, `chord = command_name`. Unknown
command names and unparseable chords are **ignored with a logged warning**, never fatal — the same
tolerance `settings.txt` and the theme files have, and the reason old and new builds interoperate.
A `View ▸ Edit Keybindings...` row writes the file if absent (seeded with the full default list,
commented) and opens it as a tab, exactly like *Edit Current Theme...* does.

**Resolution order:** user overlay first, then `default_bindings`. An overlay entry binding a chord
that a default also uses **wins**; an overlay entry with an empty command **unbinds** the chord.

**The three things that will go wrong, so the plan must address them by name:**

- **Reserved chords.** Rebinding `Ctrl+C` in the `.Palette` context, or anything the find bar's
  ctrl/alt fallback depends on (§6f), can make the app unusable with no way back. Decide the reserved
  set explicitly rather than discovering it: at minimum whatever closes or cancels the surface you
  are in. A file that can brick the editor needs a documented escape (delete `keys.txt`), stated in
  the seeded header.
- **Context.** `default_bindings` matches on `(key, ctrl, alt, ctx)` and **shift is read by the
  action, not part of the chord** (`commands.odin:232`) — §6y already got caught by this when the
  plan proposed `Ctrl+Shift+arrow`. The file format must express context, and must not imply shift is
  bindable when it is not. Either expose `ctx` as a column or scope the file to `.Editor` only and
  say so.
- **Duplicate chords within the overlay.** Last-wins is fine but must be *chosen* and stated in the
  file header, not fall out of iteration order.

**Testing:** `keymaptest` — parse a good file, a file with an unknown command, a malformed chord, a
duplicate chord, an unbind, and one that rebinds a chord a default already owns. Assert
`resolve_key` returns the overlay's answer. The load path must be a pure function over file bytes so
none of this needs a window.

## Item 2 — bookmarks

`Ctrl+F2` toggles a bookmark on the caret's line; `F2` / `Shift+F2` jump to the next/previous one,
wrapping; a mark is drawn in the gutter. Persisted per tab.

**Store byte offsets of line starts, not line numbers.** Newtpad has no line index — §6y measured
what turning a line number back into an offset costs here (a walk from byte 0; 48 ms per frame at
line 28,000 of a 500 KiB log) and the whole column-editing model was re-anchored onto byte offsets
because of it. Bookmarks must use the same currency.

**Which means the hard question is what an edit does to them,** and it must be answered in the plan
rather than in the code:

- Text inserted or deleted *before* a bookmark shifts its offset. Anything else and every bookmark in
  a file drifts on the first edit above it.
- A bookmarked line that is *deleted* — the bookmark should die with it, not survive pointing at
  whatever moved into that offset.
- `doc.nl_delta` and the undo/redo snapshot path already carry this class of problem for the find
  results and the column rectangle; **look at how `find_invalidate` and `apply_snapshot` handle it and
  follow, do not invent a third pattern.**

**Persistence: session format 4 → 5**, one appended field per tab, same tolerant ladder (v1–v4 still
load). Offsets are only meaningful against the file the session recorded, so a tab whose disk stamp
changed underneath should drop its bookmarks rather than restore them onto shifted text — the same
"trust disk for clean" reasoning §6b used.

**Testing:** `bookmarktest` — toggle/next/prev/wrap; an insert above shifts an offset; a delete of the
bookmarked line drops it; undo restores; a round-trip through session v5; a v4 session still loads.
Sabotage each.

## Item 3 — scrollbar match marks

Draw a tick on the vertical scrollbar for every find match, so a 200 MB log shows where its matches
are without scrolling. Research §C calls this cheap and "high satisfaction", and it pairs with the
filter view Wyatt already singled out.

**The bar is byte-proportional** (§6b), so a mark's y is `match_offset / pt.length` — no line index
needed, which is why this is cheap. Two real constraints:

- **`MAX_MATCHES` saturates** and the search worker publishes incrementally (§6e), so the marks must
  render from however many matches exist *right now* and not imply completeness. If `find.truncated`
  is set, say so — the match counter already shows a trailing `+`.
- **Do not draw one quad per match.** A 200 MB log with 50,000 matches is 50,000 quads on a bar a few
  hundred pixels tall. Bucket by pixel row; one quad per occupied row.

**Testing:** `matchmarkstest` — bucketing collapses N matches in one pixel row to one mark; a match at
offset 0 and one at `length` land at the track's top and bottom; a truncated result set is flagged.

## Item 4 — filter click-to-jump

§6h item 2, and cheap: `filter_lines[i]` is *already* the byte offset of the line start. Clicking a
filtered row sets the cursor there and leaves filter mode. The only real work is the hit-test, and
`doc_filter_max_top` / the filter draw already share their layout, so there is one place to ask.

**Watch the gutter.** Filter view draws line numbers (§6h item 1) and `GUTTER_W` is added by both
`col_x` and `col_at_x` so they cannot disagree — a click in the gutter should still select the row,
not map to a negative column.

## Item 5 — filter's first paint

§6e's main outstanding gap and the one thing still owed against CLAUDE.md's *"no frame ever shows
emptiness."* Filter view renders `filter_lines`, which the worker fills from offset 0, so on a large
file **the screen is empty until the first match arrives.**

A viewport-scoped pass does not help — filter is not viewport-relative. What it needs is a bounded
**synchronous** pass from offset 0 that fills enough rows to paint one screen, with the worker
continuing behind it. That is the spec's "pass 1" that §6e deliberately deferred to keep the
concurrency change reviewable.

**The bound is the whole design question.** Too small and a sparse match set still paints empty; too
large and a keystroke stalls on a multi-GB file, re-opening the P0 that roadmap item 1 closed. Budget
it in *bytes scanned*, not matches found, and stop at the budget whether or not the screen is full —
a partially-filled first frame is the acceptable outcome, an unbounded scan is not. State the chosen
budget and the measurement behind it.

**Testing:** extend `findtest` — on a fixture whose first match is deliberately far into the buffer,
the first frame after the query must show either rows or an explicit "searching" state, never a bare
empty grid. This one needs a *falsifier*, not just an assertion: measure the worst-case synchronous
scan and record it, the way `regextest` reports per-keystroke latency.

## Out of scope

Numbered bookmarks; an in-app key-capture UI; editing while filtered (§6h item 3 — needs its own
design pass, since every edit invalidates both `filter_lines` and the match list *and* the view must
stay stable under the caret); bookmark marks on the scrollbar (item 3 is find matches only — adding a
second mark kind is a colour-role and precedence question, not free).

## Verification

Per `docs/development-loop.md`: fresh implementer per task, reviewer after each told that task's named
risks, one fix subagent per review round, whole-branch review at the end, every test sabotage-verified
with the failure output recorded.

The risks to name to reviewers, by item: **1** reserved chords and the shift-is-not-part-of-the-chord
trap; **2** offset drift under edits and undo, and the session ladder; **3** quad count at scale and
the truncated-result case; **4** the gutter in the hit-test; **5** the synchronous bound, which is a
hard-rule violation if it is wrong.

**Nothing in this batch can be verified against real GUI input.** All five items are things you click
or press. Wyatt's live pass is owed on every one.
