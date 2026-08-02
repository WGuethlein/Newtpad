# Reported, not yet scheduled

Bugs Wyatt reports from daily use **between** live passes. A live-pass checklist covers one release;
this file catches everything else, so a report made mid-batch is not lost to a chat transcript.

The other two lists: [requested-features.md](requested-features.md) for what is owed or asked for, and
[features.md](features.md) for what already works.

**How to use it:** when a batch is being scoped, read this file. When an item ships, delete it from here
and record it in the HANDOFF entry instead — this file is a queue, not a history.

---

## From the v0.37.0 live pass (2026-08-01) — the preview half

The table half of that pass shipped as v0.38.0 (HANDOFF §6be); two of the three below shipped as
v0.39.0 (§6bf). **The tab glyph and the list-exit gap are fixed and deleted from this file.** The
scrollbar drag is what is left, and it is the one nothing here can observe.

### Dragging the scrollbar ghosts the Split-view sync; the wheel is clean

*"grabbing the vertical scrollbar seems to have a ghosting type of thing on scrolling that way, with
the scroll wheel it looks fine"* (§5, and the same again for the preview half).

Both halves scroll to roughly the right place, so the sync itself is fine — it is specifically the
**drag** path.

**Two hypotheses were investigated in v0.39.0 and both died**, written down so the next pass does not
re-derive them:

- **The sync does not lag a frame behind the drag.** It resolves at one point per frame
  (`main.odin`), after every path that could have moved either side and before the draw reads them,
  and the drag handlers run well above it.
- **`g_vbar_preview` is not stale in Split.** There is a second draw site for exactly that case
  (`main.odin:2095`) which maintains the latch.

What is left is a **cost** hypothesis with real evidence behind it but no proof of the symptom:
`md_preview_frac` is measured at **3.322 ms** per call (markdown.odin's own note), and a drag pays
that on every frame where a wheel notch pays it once. That would read as stutter under a continuous
gesture and be invisible under a discrete one, which matches the report — and so would several other
things.

**One observation splits it, and only a person can make it:** does the *content* trail the thumb, or
does the *thumb itself* stutter under the cursor? The first points at the sync, the second at frame
cost, and they are different fixes. **Do not guess at this one** — the scroll model is where this
project has been burned most.

### FIXED in v0.39.0 — a blank line does end a list item; only the gap was wrong

Kept as a note rather than deleted, because the *report* and the *defect* were different things and
that is worth remembering. Wyatt filed it under "a blank line still ends a list item" failing. The
list ending was fine — the prose after a list really is its own block and was never swallowed. What
was wrong was that §9.3's "0.25 S **between items**" was being spent below the *last* item too, so
leaving a list was 4px where entering one was 13px. A probe over `md_walk` is what told the two apart;
reading the report at face value would have sent the fix into the paragraph join. See HANDOFF §6bf.

### Also from that pass, deliberately not queued

Two items Wyatt flagged are **CommonMark working as v0.37.0 intended**, not defects: a soft line
break inside a paragraph renders as a space unless the line ends in two spaces or a backslash (so
address blocks and blockquote continuations need them), and `---` directly under a line of prose is a
setext underline that makes it a heading. If the first one keeps costing him in real notes, the
answer is a setting — "treat single newlines as breaks", GitHub-comment style — not a parser change.

## Reported 2026-08-01 — documented for a later pass, not investigated

Wyatt's list, recorded verbatim at his direction: *"just document them for a further pass later."* Each
entry separates **what he said** from **what the code says**, and the code notes below are from a few
minutes of reading, not from a real investigation. Nothing here has been reproduced.

### Dragging a tab off the tab row does not spawn a new instance with that tab

*"dragging tabs off the tab row doesn't spawn a new instance with that tab"*

**This looks like a missing feature rather than a broken one.** `tabs_drag_update` (`ui_tabs.odin:428`)
reorders the dragged tab *along the strip* by adjacent swaps and nothing else — there is no tear-off,
no detach, and no second-window path anywhere in the file. So the expected behaviour has never been
built, and it should probably move to `requested-features.md` when someone confirms that.

Worth deciding before building: Newtpad tear-off means a **new process** (a second window is not a
thing today), which drags in what the torn tab does about unsaved state and about the session store —
both windows would be writing the same `%APPDATA%\Newtpad` session. That is the actual design question,
not the drag gesture.

### Web links do not open from the CSV table view (they work in text and JSON)

*"web links highlight on click but dont open the default broswer tab on click"* — then, corrected:
*"i slightly lied on the links, i'd always tested it on the csv table view... it works in a regular
text/json but not in table view."*

**So this is specific to the grid, and the document path is fine.** That is a much sharper report and it
kills most of the obvious candidates. Four things were checked in the code and are NOT the cause — written
down so the next pass does not re-derive them:

- **The path exists and is ordered correctly.** `main.odin:685` handles Ctrl+click on a link in a table
  cell, and it runs *before* the column-resize, header-sort and read-only-consume branches, so none of
  those swallows the press first.
- **The sort permutation is handled.** `table_links` steps rows with `table_row_next` (`table.odin:3012`),
  the same step the draw and `table_row_start` take, specifically so an underline positioned by data-row
  index lands on the line that index resolves to under a sort. The comment at `table.odin:594` records
  this being got wrong once already.
- **The draw/hit-test geometry seam has already been fought.** `table_link_hit`'s own comment
  (`table.odin:3019`) records a fixed bug of exactly that shape — `line_h` instead of `row_h` made the top
  of the band right and the bottom short.
- **`doc.kind == .Text` holds for a CSV**, or the header sort at `main.odin:705` would be dead too, and
  sorting works.

**The leading candidate is now resolution, and it is a real asymmetry between the two views.** The table
path is **explicitly not resolution-gated** (`main.odin:687-690`): `table_links` decorates whatever
`links_scan` finds in a cell, so a dead target in the grid *still underlines*, while the document view
only decorates links that resolve — "an underline is a promise" (`features.md:365`) is true of the
document and **not** of the grid. A cell link that fails to resolve therefore reaches `link_follow`,
which is loud on every failure path (`links.odin:975`) and should raise a `Could not resolve` box.

**So the one question that splits this cleanly, and it needs a person:** *does a dialog appear when you
Ctrl+click a link in the grid?*

- **A dialog** → the click is arriving and the failure is in `link_resolve` or in `plat.shell_open_url`'s
  scheme whitelist (`file.odin:725`, HANDOFF §6l). Read the dialog text; it names which.
- **Silently nothing** → the click never reached `link_follow`, which means `table_link_hit` returned
  false at the pixel he clicked, and the suspect is the band `[l.y - px, l.y - px + row_h]` at
  `table.odin:3025` against the underline the draw puts at `tl.y + sx(2)` (`main.odin:1906`) — the two
  read the same `Table_Link.y` (a *baseline*) but derive different vertical extents from it.

Worth a headless test either way: nothing currently compares what the grid *draws* as a link against what
the grid treats as *clickable*, which is precisely the seam CLAUDE.md's one-layout rule is about.

### Menu and Ctrl+F interactions feel awkward

*"there are a lot of interactions in and out of menus like Ctrl+F that are awkward but it's hard to
expalin these now."*

**Deliberately left vague — he could not pin it down and said so.** Recorded so it is not lost, and
because a vague report from daily use has been right before.

Do not guess at a fix from this. What it needs is a session where he drives and narrates, or a
focused live pass on focus transitions specifically: what has keyboard focus after opening and closing
the find bar, after Esc, after a menu opens over the find bar, and what happens to the caret and to the
selection at each of those. The find bar moved to the top in batch 12 and twelve call sites read its
inset (HANDOFF §6aq), and CLAUDE.md's own event rule is only *partially* honoured — "input is drained
from the platform queue but acted on at several points in the frame, and some widgets still resolve
state during the draw" — so there is a plausible structural cause here, which is a reason to look
properly rather than to patch a symptom.

