# Live pass checklist — v0.36.0 (multi-column sort)

Batch 19 shipped **with no live GUI pass at all**. This environment cannot inject mouse or keyboard
input, so every claim about what happens when you hover, click, Ctrl+click or right-click a column
header is an inference from source. HANDOFF §6bc says so plainly; this file is the part only you can do.

Ordered by **how likely it is to be wrong**, not by feature. **⚠** marks the items where the code does
something load-bearing that no test can observe.

**What to open:** any `.csv`. One with a text column, a numeric column and some blank cells is ideal —
a few hundred rows for the interaction items, and something large (50k+ rows) for §5.

---

## 1. The data-loss seam — do this one first

The sort is view-only and must never rewrite the file. Editing a cell while sorted has to write to
*that cell's own line*, not to the line currently at that screen position.

- [X] Sort by a column so the rows visibly reorder
- [X] Edit a cell in a row that clearly **moved** (not one that happened to stay put)
	- The edit works, but it doesn't resort after the change, e.g. I'm sorting alphabetically, I swap G to F, it doesn't update the sort so that the row is moved up
- [X] `Ctrl+S`, then open the file in Notepad or another editor — the edit landed on the **right row**,
      and no other row's text changed
- [X] The file's **row order on disk is unchanged** — sorting did not rewrite it
- [X] Undo (`Ctrl+Z`) after that edit restores the right cell

**⚠ Then the same thing with two sort keys active**, which is what is actually new. Sort by column A,
Ctrl+click column B, edit a moved row, save, verify in another editor.

---

## 2. The three gestures

**Plain click on a header** cycles that column alone, and **clears every other key**.

- [x] Click column A → ascending. Click again → descending. Click a third time → sort cleared entirely
- [x] With A+B sorted, a plain click on C leaves **only C** sorted

**⚠ Ctrl+click** cycles one key: ascending → descending → removed from the sort.

- [ ] Sort by A (plain click). Ctrl+click B → both are keys, **A still wins** (A's groups stay together)
- [ ] Ctrl+click B again → B flips to descending, A unchanged
- [ ] Ctrl+click B a third time → B leaves the sort, A survives alone
- [ ] Ctrl+click a **third** column while A+B are keys → refused, and the summary row says why
      (the cap is 2 keys and that is deliberate — see §5)

**⚠ Precedence digits.** With two keys, a small `1` and `2` should appear on the two sorted headers.

- [X] `1` is on the first-selected column, `2` on the second
- [X] With only **one** key, no digit is drawn at all
- [ ] The digits sit on the same baseline as the arrows and do not collide with the label at any zoom
	- it does clash like my previous bug mentioned, where its cutting the name off, only to be brought back with a manual resize
---

## 3. The header menu — the part with the most inference in it

Two ways in, and **both must target the column you actually pointed at**. A bug here made every row act
on column 0; it was caught in review, but only reasoning says the fix works.

**⚠ Hover chevron.** Hovering a header cell should reveal a chevron; clicking it opens the menu.

- [X] The chevron appears on hover and disappears when you leave
- [X] The mouse cursor becomes a **hand** over the chevron
- [X] It does not overlap or push the column label
- [X] Clicking it opens the menu **for that column**

**⚠ Right-click** anywhere in a header cell opens the same menu.

- [X] Right-click column C, pick **Sort Ascending** → **column C** sorts, not column A and not column 0
- [ ] Right-click past the **last column**, in the empty header space to the right → nothing opens
      (it must not resolve to the last column)
	- the last column ends the screen, there is no edge padding
- [X] Right-click in the **row-number gutter** → nothing opens

**The six rows and their greyed states.** With nothing sorted:

- [X] `Sort Ascending` / `Sort Descending` — enabled
- [X] `Then by Ascending` / `Then by Descending` — **greyed** (nothing to be "then" after)
- [X] `Remove from Sort` — **greyed**
- [X] `Clear Sort` — **greyed**

With column A sorted, opening the menu **on column B**:

- [X] `Then by Ascending` / `Descending` — enabled
- [X] `Remove from Sort` — **greyed** (B is not a key)
- [X] `Clear Sort` — enabled

With A+B both keys, opening the menu **on B**:

- [X] `Remove from Sort` — enabled, and removing B leaves A sorted
- [X] `Then by …` — **greyed** (the 2-key cap is reached)

**⚠ Placement against a window edge.** The menu is clamped to the window; nothing verifies that live.

- [X] Open it on the **rightmost** column — the menu stays fully on screen, no rows cut off
- [ ] Shrink the window until it is short, then open it — the menu is reachable (it scrolls if it must)
	- it does not scroll, there is no scroll bar in this instance, and the menu is behind the bottom of window menu items
- [X] `Esc` closes it; clicking elsewhere closes it; neither leaves a stuck highlight

---

## 4. The summary row

- [X] It names the **whole** sort — both columns and both directions, not just the first
- [X] The sort text is **clickable** and clears the sort
- [X] After clearing, the row goes back to whatever it says with no sort

**Known, not a bug to report:** at a narrow window the summary row runs out of room. The cap note is cut
first (deliberately — the control is protected ahead of the explanation), then the clickable run at about
730px, then the line itself at 850px for two keys. The one-key line already did this at 602px before this
batch, so the threshold moved rather than being created. `Clear Sort` in the header menu works at any
width. **What to do about it is your call** — tell me if it bothers you in real use and it becomes a task.

---

## 5. Cost, on a real file

Sorting is a whole-file operation and it freezes the UI while it runs. The numbers below are **converted
from debug timings, never measured in a release build** (`build.bat release` is `-subsystem:windows` and
cannot print), so this is the item most likely to be wrong in the direction that matters.

- [X] Open a large CSV (50k–100k rows). One-key sort: expected ~250 ms of freeze at 100k rows
- [X] Two-key sort: expected ~360 ms. **Does that feel acceptable, or does it read as a hang?**
- [X] Past **100,000 rows** the sort refuses rather than running — the summary row should say so, not
      silently do nothing

---

## 6. Odds and ends

- [X] Blank cells in a secondary sort key sort **last**, in both directions
	- it should be at the top if sorting ascending
- [X] A column of numbers sorts numerically (2 before 10), and per key — a numeric key and a text key in
      the same sort each get their own treatment
- [ ] Removing the last sort key scrolls back to the top rather than leaving you at a stale offset
	- on cycling through sorts, it will take you to the bottom of the table on reset sometimes, others it'll be the middle, etc
- [X] Sorting, then switching tabs and back, keeps the sort
- [X] Malformed / short rows still appear, still marked, and do not vanish under a sort

---

## Reporting

Anything that fails: a sentence is enough, plus which column and roughly which row. Screenshots help
most for the chevron, the digits and the menu placement, since those are the three I cannot see.


## OTHER BUGS

- csv's with no header are automatically assumed to have a header... not sure how we'd differentiate this.
