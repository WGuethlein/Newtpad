# The status-bar seam — diagnosis and the fix that follows

> ## ⚠ HALF DONE, AND THIS PLAN'S PREMISE WAS WRONG
>
> **The seam is FIXED (v0.73.0, HANDOFF §6cm).** The drop lives in `status_cells`, so what is drawn
> and what is hit-tested are one geometry. The data-loss path is closed.
>
> **The "Why the obvious fix does not work" section below is wrong**, and it is left standing because
> the mistake is the useful part. It argued the drop could not move into `status_cells` because the
> left group's width came from state the hit-test lacks, and concluded the fix needed a per-frame
> measurement threaded through `App`. Extracting `status_left_text` showed it needs only `doc` and
> `text` — **both of which the hit-test's caller already holds.** No frame-loop state, no new App
> field, about a third of the work this plan budgeted.
>
> **A plan written from reading is a hypothesis. Check its premise before paying its price.**
>
> What is still owed from this file: **"Only then, the mockup's cells"** at the bottom — that part
> stands, including the `[4]Status_Cell` buffer warning. The test section is done and its assertions
> shipped; note the recorded limit that neither can see the *draw*, so re-adding a post-filter in
> `main.odin` would pass both.

Written 2026-08-04. Wyatt chose "fix the mismatch first, then add the mockup's cells"; this was the
first half, worked out far enough to execute without re-deriving it.

## The bug, exactly

`status_cell_at` (`doc.odin`) walks **every** cell `status_cells` returns:

```odin
for c in status_cells(doc, winw, cw, buf[:]) {
    if mx >= c.x && mx < c.x + c.w {return c.cmd}
}
```

The **draw** (`main.odin`, the `UI spec 5's drop order` block) calls the same `status_cells` and then
drops cells that would collide with the left group:

```odin
for len(cells) > 0 && cells[len(cells) - 1].x < need {
    cells = cells[:len(cells) - 1]
}
```

So on a narrow window a cell is **not drawn and still clickable**. Clicking where the dropped `LF`
cell used to be dispatches `.Eol_CRLF` — a whole-buffer rewrite. Two owners of one geometry, which is
CLAUDE.md's one-layout rule and the §6j bug class verbatim.

## Why the obvious fix does not work

Move the drop into `status_cells` so both callers get it — except the drop measures against
`need`, derived from the **left group's width**, and that string is built in the draw from state the
hit-test does not have:

```odin
left := fmt.tprintf("%s    %s%s%s%s%s%s%s", lncol, count, " *" if doc.modified else "",
                    recovered, disk, indexing, atlas, nobackup)
```

`indexing` is background-worker progress, `atlas` is `plat.text_atlas_full(text)`, and the transient
notice rides the same line on a timer. Rebuilding that inside `status_cell_at` makes the hit-test a
**second producer of the left width** — the same disease one layer down.

## The fix

**Measure the left group once per frame, in the input phase, and feed both consumers.**

1. Extract the left string into `status_left_text(doc, app, text) -> string` (`doc.odin`), so it has
   exactly one definition. It needs the notice, the atlas flag and the indexing state, so it takes
   `app` and `text`.
2. Early in the frame — **input phase, before the hit-test, not in the draw** — compute
   `app.status_left_w = f32(len(status_left_text(...))) * cw`. It is a *measurement* of input state,
   not resolved scroll, so this does not repeat the `menu_scroll_to_item` violation. Keep it out of
   `render_frame` regardless.
3. Give `status_cells` a `left_w: f32` parameter and move the drop loop into it. It then returns only
   the cells that are actually drawn.
4. `status_cell_at` passes `app.status_left_w` through. Draw and hit-test now read one list.
5. The view-name (`right`) drop can stay in the draw — it is not clickable, so it cannot fire a
   command. Note that in a comment or someone will "fix" it later.

## The test that must fail first

`menuseam`-shaped, in `settingstest` or its own mode:

- Build a document whose left group is long (a selection, plus a warning so the string grows).
- At a **wide** width: assert every cell `status_cells` returns is hit-testable at its own `x`.
- At a **narrow** width, chosen so at least one cell drops: assert `status_cells` returns fewer
  cells, **and** that `status_cell_at` at the dropped cell's former x returns `.None` — not
  `.Eol_CRLF`.
- Assert the drop **order** is right-to-left per ui-spec §5: Tab width → LF → UTF-8 → language.
- **Sabotage:** restore the old two-owner arrangement (drop in the draw only) and watch the narrow
  case return `.Eol_CRLF`. That is the data-loss path, stated as a test.

## Only then, the mockup's cells

§13 wants `Ln 124, Col 94` · `778 lines` · **`42.1 KB`** on the left, and **`Markdown`** · `UTF-8` ·
`LF` · **`Tab 4`** on the right. Three cells that do not exist:

- **File size** — left group, after the line count.
- **Language** — the lexer's name. Note the right group currently shows the **view** name
  (`Markdown Split (Ctrl+M)`) where the mockup shows the **language**; these are different things and
  both may want a home.
- **Tab width** — `Tab 4`. A click should reach the Font screen, which now displays tab width.

`status_cells` takes a `[4]Status_Cell` buffer at every call site. **Three more cells overflow it** —
grow it and check every caller, or the new cells silently vanish.
