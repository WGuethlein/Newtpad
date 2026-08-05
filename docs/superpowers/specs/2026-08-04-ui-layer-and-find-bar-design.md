# The `ui` layer, and the find bar on top of it — design

From [the full sweep](../../ui-spec-gaps/2026-08-04-full-sweep.md) §12. Wyatt's three decisions,
2026-08-04:

1. **Start `src/ui` properly** — the promoted primitive is its first real occupant, not a
   `program/control.odin`.
2. **Chips move inline**, per the mockup: `Find │ [input] │ 3 / 349 │ Aa ab| .* │ sep │ ↑ ↓ │ Filter Ctrl+L │ ✕`.
3. **Narrow drop order: Filter pill → ↑↓ → ✕**, with the count and chips surviving longest.

## The shape that makes `src/ui` possible today

CLAUDE.md's layer rule is `base → platform → renderer → ui → program`, and its as-built caveat admits
`renderer` and `ui` are 8- and 6-line stubs. The reason they stayed stubs is real: a `ui` package that
*draws* needs `plat.Gfx`, `plat.Text` and `g_theme`, and `g_theme` lives in `program`. Moving the theme
down to make one button work is how a layer extraction turns into a rewrite.

**So `ui` is not the drawing layer. It is the geometry layer.**

> A widget's geometry is produced by exactly one `*_layout()` procedure, consumed by the draw *and*
> the hit-test *and* the hover *and* the cursor. — CLAUDE.md

That rule never says the producer must draw. Splitting on it gives a `ui` package that is **pure
arithmetic over f32 and strings**: no COM, no device, no theme, no `Document`. Which means:

- It satisfies "never calls Win32/COM directly" by construction rather than by discipline.
- It is testable with `odin test src/ui` — the first layer besides `base` that can be.
- `program` keeps the draw, and passes colours it already owns.

The layer boundary this establishes is worth stating plainly, because the next batch will want to know
where the line is: **`ui` decides where things are; `program` decides what they look like.**

## What goes in it

```odin
// A labelled control: a box with its label and optional chord already placed.
Button :: struct {
	x, y, w, h:   f32, // the box -- hover fill and hit-test read exactly this
	tx, ty:       f32, // label origin; ty is the baseline
	cx:           f32, // chord origin, same baseline
	label, chord: string,
	tag:          int, // the caller's own id; ui never interprets it
}
```

`tag` is deliberately an `int`, not a `Command_Id` — that type is `program`'s and a `ui` that named it
would be a `ui` that depends upward. The caller maps tags to commands.

Three procedures:

- `button_layout(x, y: f32, label, chord: string, m: Metrics) -> Button` — the one producer.
- `button_hit(b: Button, mx, my: f32) -> bool` — consumed by click, hover and cursor.
- `pack(items: []Item, avail, gap: f32, keep: []bool) -> f32` — the drop rule.

`pack` is the piece the find bar actually needs and the status bar reinvented last batch. Each `Item`
carries a natural width and a **drop priority**; `pack` decides which survive in `avail`, dropping
highest-priority-first, and returns the used width. It does not place anything — placement is a second
pass, exactly as `status_cells` learned to do, because dropping before placing is what keeps a
right-aligned group flush right instead of leaving a hole where a control used to be.

**Widths come in measured.** `ui` cannot call `plat.text_char_width`, so `Metrics` carries the advance
per character for each text size and the caller fills it from the platform. That is the one awkward
seam, and it is the right one to have: it is a number, not a type.

## The find bar, rebuilt on it

Per §12's mockup, at the metrics the DOM extraction gives:

| Part | Spec |
|---|---|
| Bar | 38px, `bg_raised`, 1px `border_subtle` bottom, `padding 0 12`, `gap 14` |
| Label | `Find` / `Replace`, `text_muted`, 12px, **fixed 46px column** |
| Input | `bg_base`, radius 6, h 26, `padding 0 10`, **`inset 0 0 0 2px` accent ring**, 2×15 caret |
| Count | `3 / 349`, 12px, **62px column, right-aligned**; `danger` at zero |
| Chips | 24 tall, radius 5, `padding 0 8`, gap 3; **active = accent fill, `bg_base` text** |
| Separator | 1×18, `border_subtle` |
| Steppers | `↑` `↓`, 24×24, radius 5 |
| Filter | `Filter` + `Ctrl+L`, h 24, radius 5, `padding 0 8` |
| Close | `✕`, 24×24, radius 5 |
| Replace row | second 38px row; `Replace` and `All 349` as buttons, `#34302c`, radius 6, h 26 |

**Already correct, do not touch:** the bar is already 38px (`FIND_BAR_H_96`), the chips already take an
accent fill when active, the count already exists and already colours `danger` at zero, and the replace
row already has two real buttons with hover, a hand cursor and a narrow-window drop. §12's gap was
never as wide as the first draft of the sweep claimed.

**Changing:** the flat `Find: query_` becomes a bordered input; the count moves into a fixed
right-aligned column and loses its parentheses; the chips move from hard-right to inline after the
count; and the four missing controls arrive.

### The drop order, and why it is not the status bar's

Wyatt's rule: **Filter pill → ↑↓ → ✕**, count and chips last. The reasoning to record is that
*everything dropped keeps a keyboard route* — `Ctrl+L` still filters, `Enter`/`Shift+Enter` still step,
`Esc` still closes — whereas the count and the chips are the only things that **report state**. A
dropped button costs a click; a dropped count costs knowledge.

That is a different rule from the status bar's plain right-to-left, and deliberately so. Both are
`pack` calls with different priorities, which is the point of putting the drop rule in `ui` rather than
writing it a third time.

## Risks

- **The bar has one producer today and must still have one after.** `find_toggles` and `find_actions`
  are already single-producer; the new controls join them rather than growing a second opinion.
  Seam-tested at boundary widths, sabotaged before it is believed.
- **`pack` is a bounded scan reporting a confident answer** — HANDOFF §4's Shape A. It must not report
  "everything fits" when it stopped early. Test it at exactly-fits and one-pixel-short.
- **Moving the chips changes daily muscle memory.** Wyatt chose it knowing that; noted so it is not
  quietly reverted later.

## Out of scope

The replace row's existing buttons keep their current geometry this batch. Filter-mode's banner
(`FILTER context 249 of 778 lines` + the right-hand hint) is §12's third mockup and its own task.
