# Batch 13 — the shell (design)

The second batch of the UI overhaul. Batch 12 built the foundation (theme, metrics, the rounded-rect
pipeline, the interface font); this is the first batch that *uses* it, and the tab rail is what the
user looks at most.

Covers UI specification §4.2 (tabs), §18 (focus, accessibility), §5 (narrow windows), §7.1 (the
palette entry point) and §2.1's caption-button geometry.

Decisions taken with Wyatt, 2026-07-29. **Do not relitigate.**

1. **Variable tab width, 132–220**, per §2.1 — not the current fixed 160.
2. **No motion.** Every transition stays 0ms. §18's five 50ms fades are dropped.
3. **Caption buttons become drawn geometry**, not text glyphs.

## Why no motion, written down so it is not re-added by someone reading §18

§18 asks for 50ms ease-out on hover fills, the active-tab pill, and menu/palette appearance.
Implementing that means waking the message loop for ~3 frames per hover, which trades away the
property CLAUDE.md and §19 both state outright — *"Idle cost zero. Render on demand… block on
`WM_PAINT` / input rather than spinning."* The frame loop currently sleeps 200–1000ms when nothing is
happening.

For a notepad whose entire pitch is that it is instant, 50ms of fade is the least valuable thing in the
specification and the only one that costs an architectural property. Skipped deliberately, not
forgotten. §18's *other* content — the focus ring, reduced-motion, hit-target sizes, never-colour-alone
— is all in scope.

The one piece of motion that carries information rather than polish, §13's 1.5s "Saved" flash, already
has its mechanism: `app_note` plus `app_notice_active`, which the frame loop already polls.

## The finding that shapes the batch

**Five separate places walk the tab strip**, each computing `x := MENU_W - app.tab_scroll` and stepping
by `TAB_W`: `tabs_hidden_count`, the scroll clamp, `tabs_hit_test`, the reorder's `rel`, and
`tabs_draw`. They agree today **only because the width is a constant.**

Variable width makes them diverge the instant it lands — and CLAUDE.md's rule exists for exactly this:
*"A widget's geometry is produced by exactly one `*_layout()` procedure, consumed by the draw and the
hit-test and the hover and the cursor."* HANDOFF §6j records sixteen bugs of this shape in one session.

So the layout extraction is Task 1 and variable width is Task 2. Doing them in the other order would
be shipping the bug and then fixing it.

## What is actually missing, as opposed to what the spec assumes

Audited, because §4.2 reads as a list of refinements and two of its items are absent rather than rough:

- **Tabs show no modified state at all.** Nothing in `ui_tabs.odin` reads `doc.modified`; only the
  window title gets the `*`. With several tabs open there is no way to see which have unsaved edits.
  The spec's "reserve an 8px slot so the truncation point never moves" is about layout stability — but
  the marker it stabilises does not exist yet.
- **No ambiguous-name disambiguation.** Two tabs called `notes.md` are indistinguishable.
- **Truncation is end-ellipsis**, so `2026-07-27-batch-11-sync.md` loses the extension — the part that
  identifies the file. §4.2 wants the middle elided.
- **Reorder exists** (`app.tab_drag`), and works. It needs the pill treatment, not a rewrite.
- **`WM_GETMINMAXINFO` is not handled anywhere**, so the window can be dragged narrow enough for the
  caption buttons and the tab rail to overlap. §5's drop order has no floor under it today.
- **Caption buttons are text glyphs** (`–`, `❐`, `▢`). Batch 12 moved chrome onto Cascadia Mono, so
  they now depend on that face carrying them or falling through to Segoe UI Symbol. §3 item 5 also
  notes a 1px stroke inside a 15px box at 150% looks broken, so the stroke has to scale regardless.

## The tasks

1. **`tabs_layout()`** — one procedure producing every tab's rect, consumed by the draw, the hit-test,
   the reorder, the overflow count and the scroll clamp. No behaviour change; fixed width retained, so
   any visual difference is a bug. This is the task whose test is a seam test: what is drawn against
   what is clickable, at the boundary sizes.
2. **Variable width 132–220**, plus middle truncation, the dirty marker in a reserved slot, ambiguous
   names, and close-on-hover. Safe only on top of Task 1.
3. **Pills** — radius on the tab quads, the first consumer of batch 12's SDF pipeline.
4. **Focus ring** — `Focus_Ring` at 2px with 1px offset, drawn as one annular instance, on keyboard
   focus only. Needs a "last input was keyboard" flag.
5. **Caption buttons as geometry**, with a DPI-scaled stroke.
6. **`WM_GETMINMAXINFO` + §5's drop order**, breakpoints read from the metrics globals so they scale.
7. **`>_` palette entry point** replacing the magnifier.

## Verification

The seam test is the batch's centre: **compare the drawn tab rect against the hit-tested one**, for
every tab, at boundary widths — one tab, tabs exactly filling the rail, tabs overflowing, and the
narrow-window floor. Then sabotage by reintroducing a second x computation and watch it fail.

`WM_GETMINMAXINFO` is testable headlessly by calling the handler with a `MINMAXINFO` and asserting the
clamped values scale with DPI. The focus ring and the pills are pixel claims and go through
`quadsdftest`'s readback path.
