# Menu finish + the shared selection split — design

**Batch scope agreed with Wyatt 2026-08-04.** Source of the item list:
[ui-spec-gaps/2026-08-04-menus.md](../../ui-spec-gaps/2026-08-04-menus.md) and
[ui-spec-gaps/2026-08-04-palette.md](../../ui-spec-gaps/2026-08-04-palette.md).

This is the first batch of the UI rework that HANDOFF §6aa fork 1 now gates V1 on. It is deliberately
the *finish* half — the §6 rules about how menus look, plus the one state bug they share with the
palette. **It is not the `renderer`/`ui` extraction**, and it must not make that extraction harder.

---

## What this batch is for

The menus behave correctly and read as unfinished. §6's own framing predicts that: its four numbered
problems are all appearance, and three of the four are already fixed. What is left is inset, colour,
placement and live values — small things whose absence is what Wyatt sees.

**The one-sentence goal:** make the menus look finished without touching how they work, and fix the
one place where "how they work" is genuinely wrong (selection state, shared with the palette).

---

## Decisions taken, with their reasons

### D1. Command titles lose their parentheticals

Three titles are sentences rather than labels:

| Now | Chars | Becomes |
|---|---|---|
| `Remove Duplicate Lines (exact match, keeps the first)` | 53 | `Remove Duplicate Lines` |
| `Sort Lines Descending (selection, or whole file)` | 48 | `Sort Lines Descending` |
| `Sort Lines (selection, or whole file)` | 37 | `Sort Lines` |

**Why now:** Wyatt's call that these three get menu homes (an `Edit ▸ Text` submenu) collides with
`dropdown_w`, which sizes a panel from its widest label. A 53-character row would make that submenu
wider than the whole menu bar. The parentheticals were affordable while the palette was the only
route; a menu row is where they stop being.

**Where the information goes, because it is real:** the "selection, or whole file" behaviour is
already documented in `features.md`, and §6.4's disabled-reason column carries the case that actually
needs explaining (these commands refuse over 16 MB / 1,000,000 lines and say so). Nothing the user
needs at the moment of choosing is lost.

**Consequence, and it is the point:** the longest title falls to ~29 chars
(`Extend Column Selection Right`), the widest palette row falls from ~650–700px to ~440px, and §7's
**560** becomes achievable rather than aspirational.

### D2. Palette geometry conforms to §7 — 560 wide, 88 top

Both numbers, and the top one is a bug rather than a preference. `CHROME_TOP` is
`TAB_STRIP_H (40) + MENU_BAR_H (30)` = **70**; §7's 88 clears it by 18px, while the shipped
`l.y0 = sx(44)` puts the palette's top edge **inside the menu bar** and draws over it.

Width follows D1 and is gated on it — **560 only after the titles shrink.** If D1 is cut, this
reverts to "amend the spec to 720" and must be recorded as such rather than silently left at 720.

### D3. The check gutter becomes conditional, and 26px

§6.1 exactly: 26px reserved on every row of a menu that contains *any* checkable item, none on menus
that do not. Computed once, in the same walk `dropdown_w` already makes over the items, and carried
in the layout — **not** recomputed in the draw. The File and Help menus lose an indent they never
earned.

### D4. One state field becomes two, in both the menu and the palette

Today `app.menu.item` and `app.palette.selected` each mean *both* "the mouse is over this" and "the
keyboard cursor is here", and both draw `Selection_List` either way. §6 asks for two colours in
menus: hover is `bg_hover`, the keyboard cursor is the accent fill with `bg_base` text.

**This is the only behavioural change in the batch**, and it is also the fix for the audit's finding
that `palette_hover` overwrites keyboard selection every frame, making arrow keys inert
([06-ui-shell.md](../../audits/2026-08-04/06-ui-shell.md)).

**Rule that decides every ambiguous case:** the keyboard cursor is authoritative and only moves on a
key event; hover is a separate, purely visual field that never writes the keyboard cursor. Mouse
movement therefore cannot change what `Enter` runs — which is the actual bug.

### D5. The four-row cap gets an assertion, not a comment

§6.2's *"nothing longer than four rows"* was already broken by adding `Open_Themes_Folder` directly
beneath the comment citing the rule. Prose does not defend itself. `menutest` already asserts every
dropdown is wide enough for its widest row; it gains a second assertion that no run between dividers
exceeds four rows.

**The fix for the View menu itself is Wyatt's to pick** — the five-row customisation group can either
split (a sixth group, against "five groups") or shed a row (`Open_Themes_Folder` and
`Open_Logs_Folder` are both "where files live"). **Defaulting to: move `Open_Logs_Folder` up beside
`Settings`**, since a log folder is diagnostics rather than customisation, giving 3 + 3.

### D7. No submenu — a flat group in `Edit` instead

**Checked before planning, and the assumption was wrong: Newtpad has no submenus and no mechanism for
them.** `Menu_Item` (`menu.odin`) carries `cmd`, `checked`, `enabled`, `payload` and `text` — there is
no `sub` field, and nothing in the file opens a second dropdown from a row.

So `Edit ▸ Text` is not a small addition. It would be **Newtpad's first nested widget**: a child rect
with its own placement, its own flip-left when it would leave the work area, its own hit-test, its own
scroll if it overflows, hover-to-open timing, and right-arrow-to-enter / left-arrow-to-leave keyboard
handling — every one of which is a second producer of a coordinate in the file whose own comments say
*"six consumers of one coordinate is the exact shape of every seam bug in this file."*

**Building that inside a batch whose entire purpose is finish work is how a finish batch becomes a
seam batch.** The requirement Wyatt actually chose was §7's *"every command in it is also in a
menu"* — and a flat, divider-separated group in `Edit` satisfies that completely, for one line of
data and no new machinery:

```
Edit ▸ … existing rows …
       ─────
       Sort Lines
       Sort Lines Descending
       Remove Duplicate Lines
       Open Link Under Cursor
```

Four rows, inside §6.2's four-row cap, and it needs D1's shortened titles to sit at a sane width —
which is the same dependency the submenu would have had.

**Submenus are not ruled out**, they are just not this batch. If they are ever wanted, they want their
own spec and their own seam tests, and the honest trigger is a *second* group needing one — one group
is not evidence for a nesting mechanism.

### D6. Motion is out

§6's 50ms opacity fade is excluded, and so is the reduce-motion setting it depends on. An animation
with no way to disable it is a regression against a position that is already "ships with no
screen-reader support". They land together in a later batch or not at all.

---

## Task list

Ordered so each task builds and passes on its own — the branch must be bisectable.

| # | Task | Files | Risk |
|---|---|---|---|
| 1 | **Shorten the three command titles** (D1) | `commands.odin` | Low. `menutest`/`palettetest` reference titles — check both. |
| 2 | **A flat text-operations group in `Edit`** — Sort Lines / Sort Descending / Remove Duplicates / Open Link Under Cursor. **Not a submenu — see D7.** | `menu.odin` | Low |
| 3 | **Conditional 26px check gutter** (D3) | `menu.odin` | Low |
| 4 | **Real pixel width budget** — replace the `+8` character-cell approximation with §6's `label + 26 + 24 + accel + 20` | `menu.odin` | Low, and it makes task 3's 26 real |
| 5 | **Highlight inset — 5px panel padding** (§6 M1) | `menu.odin` | Low, highest visible payoff |
| 6 | **Two selection colours + the state split** (D4), menu *and* palette | `menu.odin`, `palette.odin`, `app.odin` | **Highest risk in the batch.** Behavioural. |
| 7 | **2px gap below the bar; horizontal clamp to the work area** | `menu.odin` | Low. The clamp matters for context menus, not bar menus. |
| 8 | **Live values in labels** — `Reset Zoom (125%)`, `Tab Width (4)` | `menu.odin` | Low. `menu_item_label` is the existing hook. |
| 9 | **Palette geometry 560/88** (D2) + **the four-row assertion** (D5) | `palette.odin`, `menu.odin`, `test_modes.odin` | Low |

---

## What must not regress

Named explicitly because each is a seam this file's own history says is easy to break:

- **`menu_dropdown_rect` returns `y0` as well as `x0/w/h`**, so the draw and the hit-test cannot
  derive a flip separately. Tasks 5 and 7 touch that geometry. **Both consumers keep reading it from
  there.**
- **`dropdown_w` and the draw agree on a row's length through one lookup** (`menu_item_label`, then
  the command title). Tasks 1, 3, 4 and 8 all touch that agreement. A width computed from one string
  and a draw using another is the bug this batch is most likely to introduce.
- **`menutest` asserts every dropdown fits its widest row.** It must still pass after task 4 changes
  how width is computed — and if it passes *unchanged* after a real change, suspect it.
- **Scroll resolution stays where it is.** `menu_draw_dropdown` still calls `menu_scroll_to_item`
  (HANDOFF §5). **This batch does not fix that** — it is the `renderer`/`ui` extraction's job, and a
  fourth patch to the same shape is what the one-layout rule exists to prevent. Do not let task 5 or
  7 "tidy" it on the way past.

## Verification

Per CLAUDE.md, every task with an observable failure mode gets a test that fails without the fix:

- **Tasks 3, 4, 5, 7** are geometry — `menutest` and `menuseam`, asserting the drawn rect against the
  hit-tested rect at boundary sizes (a menu with no checkables, a context menu at the right edge, a
  dropdown taller than the screen).
- **Task 6** is state — a headless case that moves the keyboard cursor, then moves the mouse, then
  presses Enter, and asserts the *keyboard* target ran. That case fails today.
- **Task 9** — `palettetest` on the 560/88 numbers and the four-row rule.
- **Sabotage every one of them**: reintroduce the defect, watch the named assertion print `FAIL`,
  record the output, restore. Exit codes alone are not evidence (§6bv).

## Owed before this batch, carried deliberately

The five fixes shipped this morning (clipboard crash, Cut data loss, middle-click latch, two find
defects) **still have no failing tests.** Wyatt chose this batch ahead of that debt. It is recorded
here so the next session does not discover it as a surprise, and it should not slip a second time.
