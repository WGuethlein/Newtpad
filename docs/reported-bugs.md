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

### RESOLVED, cause unknown — dragging the scrollbar ghosted the Split-view sync

**Wyatt, 2026-08-01, on v0.41.0: *"scroll bar drag ghosting is gone now, looks normal."*** Kept rather
than deleted, because **nothing shipped between the report and the fix was aimed at it** and that is
worth knowing if it comes back.

The most likely explanation is not a fix at all: when he reported it he was running **v0.37.0**. The
v0.38.0 install was skipped that round because Newtpad was open, so the first build he actually ran
after reporting was two releases later. Which of the changes in between mattered — or whether the
original observation was of a build with something else wrong with it — is not established.

**If it returns, the investigation below is still the right one and its two dead ends still hold.**



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

## Reported 2026-08-02 — closing the last tab of one window among several

*"if an A instance only has one tab and another B instance is open... it should close A instance
instead of creating the unititled file"*

**Not yet investigated; recorded during the filtering batch.** `app_close` ends with *"last tab closed
-> fresh scratch"* (`app.odin`), which is right for the only window — a window that fails to a closed
state is worse than an empty one — and wrong once a second window exists, where the empty scratch is
just a window nobody wanted.

Two things to settle before building it, because they are not the same question:

- **Which windows count.** A second Newtpad is a separate process (§6bg), so "is another window open"
  means asking the OS, not the App. `plat.instance_claim`'s mutex says whether *any* other instance
  exists; enumerating them by window class is the other option and is what a "close me if I am not the
  last" rule actually needs.
- **What closing the window does to unsaved work.** Closing a window here is a **hot exit**, not a
  prompt (§6bh) — so "close A" must still write A's store, or the rule turns closing the last tab into
  the way to lose a buffer. A torn-off window's store is adopted by the next primary; a *primary* that
  closes itself is a different case and needs checking.

Related and already fixed, so do not re-derive it: dragging the only tab of a window is refused
outright (§6bo). If this rule lands, that refusal may want revisiting for the two-window case — they
are the same question asked from opposite ends.

## Reported 2026-08-01 — documented for a later pass, not investigated

Wyatt's list, recorded verbatim at his direction: *"just document them for a further pass later."* Each
entry separates **what he said** from **what the code says**, and the code notes below are from a few
minutes of reading, not from a real investigation. Nothing here has been reproduced.

### BUILT in v0.40.0 — tab tear-off, and what this entry got wrong

Kept as a note because the entry's own reasoning was the expensive part. It said the design question
was that *"both windows would be writing the same `%APPDATA%\Newtpad` session."* **That was already
solved** and the entry had not checked: `main.odin`'s `primary` flag gates restore, autosave,
hot-exit save and crash binding, so a second process already ran a full editor that never touched the
session store. The real missing pieces were three small ones, and the largest was that a spawned
`newtpad.exe <path>` handed its path straight back to the primary — which is why `--detach` exists.

**The lesson for this file:** an entry written from a few minutes of reading names a plausible risk,
not a verified one. Check whether the code already handles it before scoping the work off the note.
See HANDOFF §6bg.

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

**UPDATE 2026-08-02 — the owed test now exists (`gridlinktest`) and it is GREEN, which eliminates the
geometry hypothesis entirely.** This was the "worth a headless test either way" item below; it is
built, and it compares what the grid *draws* as a link against what the grid treats as *clickable*.
Every one of these passes on a 3-link fixture:

- **5 points along every drawn underline hit-test**, and **3 points through every link's glyph box** —
  so `table_link_hit` does *not* return false at the pixels a person clicks. The suspected band
  mismatch (`[l.y - px, l.y - px + row_h]` against the underline at `tl.y + sx(2)`) is real in the
  sense that the band is offset down by the row's centring pad, but it still **covers** both the rule
  and the glyphs.
- **No link is clickable from another row's middle**, so the offset does not bleed into a neighbour.
- **`tl.text` is still a valid http(s) URL after `table_links` returns** — it is `strings.clone`d into
  the frame allocator, so the dangling-stack-slice theory is dead too.
- **All three links `link_resolve` successfully, to `is_url` http targets**, and **none is mistaken by
  `link_bare_reveal_target` for a bare path to reveal in Explorer.**

Also checked by reading and NOT the cause: `trows` is assigned at `main.odin:481`, before the click
site at 855, so the click and the draw size the grid identically; nothing between the frame's first
press handler and 855 consumes `mouse_pressed` outside the palette, history panel, scrollbars and
divider; `ro_surface_swallows` runs at 1047, *after* the link branch; and the document view's own link
click requires `key_ctrl_down()` too, so there is no Ctrl-vs-Show-links asymmetry between the two
views.

**Everything from the pixel to `plat.shell_open_url` is therefore verified correct.** What cannot be
exercised here is the real click arriving and `shell_open_url` itself — and the document view already
uses that same function successfully on the same schemes.

**So the question below is now the ONLY thing left, and it is sharper than when it was written:**
`link_follow` is loud on *every* failure path — three separate `message_error` calls — so if the click
reaches it at all, a dialog is guaranteed. *Does a dialog appear when you Ctrl+click a link in the
grid?*

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

