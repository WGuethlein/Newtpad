# Extracting the frame loop's key routing into `key_route`

2026-08-05. Branch `refactor/key-route-proc`. Closes the item HANDOFF §6ct left open and
§6cm-z listed first: *"Extract the frame loop's context selection into a proc, so §6ct's
Alt-reveal wiring becomes testable."*

## The problem, stated as the bug that produced it

§6ct fixed an Alt reveal that stuck for the whole session on the Settings and Font pages:
`.Font` and `.Settings` outrank `.Menu` in the frame loop's context priority, so after an
Alt tap on those pages no later key was ever routed to `.Menu`, and nothing reached
`menu_close`. The bar stayed down, holding content 30px lower, until focus loss.

The fix landed as a second rule beside the existing one:

```odin
if ctx == .Menu && cmd != .None && !is_menu_cmd(cmd) { menu_close(&app) }
if ctx != .Menu && app.menu.revealed             { menu_close(&app) }
```

**Its test drives `menu_close` directly.** That pins what the exit does — both flags cleared,
`MENU_BAR_SHOWN` following — and cannot pin that the frame loop *reaches* it, which was the
whole bug. Deleting the second guard leaves every mode green. §6ct recorded that limit in the
test itself rather than pretending otherwise.

The structural reason: **the reveal's exit lives in the menu subsystem, while the thing that
decides whether the menu subsystem sees a key at all lives inline in `main.odin`** and cannot
be called from a headless mode.

## What moves

All of `main.odin:597-689`'s per-event work except `command_dispatch` — Wyatt's call
(2026-08-05), taking the widest of the three scopes offered:

1. The cell-edit intercept (`doc.table && doc.table_editing && !ev.ctrl && !ev.alt`), eight
   arms, each of which `continue`s the loop.
2. The context if-chain: `.Font`/`.Settings` > `.History` > `.Menu` > `.Palette` > `.Find` >
   `.Editor`.
3. `resolve_key`.
4. Both `menu_close` rules.

Leaving one statement in the loop body:

```odin
for i in 0 ..< window.key_count {
    ev := window.key_events[i]
    r := key_route(&app, doc, ev, trows)
    if r.consumed { continue }
    command_dispatch(r.cmd, ev, &app, window, &text, srows)
}
```

## The shape, and why it is effectful

```odin
Key_Route :: struct {
    cmd:      Command_Id,  // .None when nothing is bound, or when the cell editor took it
    ctx:      Ctx,         // the context the chord was resolved in
    consumed: bool,        // the cell editor handled it; do not dispatch
}

key_route :: proc(app: ^App, doc: ^Document, ev: plat.Key_Event, trows: int) -> Key_Route
```

**It performs the `menu_close` calls itself rather than returning "the caller should close the
menu."** A proc that returns a flag `main.odin` must remember to act on rebuilds the exact seam
that produced §6ct — a decision in one place and its effect in another. A test that calls
`key_route` and then asserts `app.menu.revealed == false` proves the chain end to end; a test
that asserts a returned bool proves only that the decision was taken.

**No `plat.Window`, no `plat.Text`.** Every callee on these paths is `app`/`doc`-only
(`table_edit_*`, `table_cell_at_index`, `menu_close`, `resolve_key`), so the proc is reachable
from a headless mode with nothing but an `App` and a `Document`. `command_dispatch` is what
needs the window, and it stays in the loop.

**`doc` stays a parameter, not `app_active(app)`.** The frame loop captures `doc` once per
frame and re-reads it only *after* the key loop, while the `.Find` arm reads
`app_active(&app).find.active` fresh. That asymmetry is preserved exactly — this is an
extraction, not a fix. Recorded below as an observation, not acted on.

**Home: `commands.odin`, immediately after `resolve_key`.** It is the routing decision that
wraps it, and `Ctx` is declared there.

## Test — extended `keytest`, not a new mode

`keytest` already builds a real `App`, already covers `resolve_key` across every context, and
is already in HANDOFF §7's required sweep. A new mode is one more thing for a sweep to forget,
which is the failure `development-loop.md` §6 names.

Cases:

| # | Sets up | Asserts |
|---|---|---|
| 1 | each surface active in turn | the full priority order, `.Font`/`.Settings` above `.Menu` included |
| 2 | `doc.kind == .Settings`, `menu.revealed = true`, any key | `revealed == false` — **the §6ct bug** |
| 3 | same, then `menu_bar_apply` | `MENU_BAR_SHOWN == false` |
| 4 | menu open, a menu key (`Down`) | menu still open, still revealed |
| 5 | menu open, a global chord (`Ctrl+S`) | menu closed, `cmd == .Save` |
| 6 | `table_editing`, plain `Escape`/`Enter`/`Tab` | `consumed`, and the edit state moved |
| 7 | `table_editing`, `Ctrl+`-modified | **not** consumed — the guard is `!ev.ctrl && !ev.alt` |

## Sabotage, which is the point of the exercise

Delete the `ctx != .Menu && app.menu.revealed` guard. **Case 2 must fail**, and its output goes
in the report. That is the exact deletion §6ct says leaves the current suite green.

## Observed, not fixed

Within one frame `doc` is stale after a mid-loop tab switch while `.find.active` is fresh, so
two keys in one frame across a `Ctrl+Tab` resolve the second one's context from the *previous*
document's `kind`. Rare (needs two key events in a single frame) and pre-existing. The
extraction gives it a name and one call site; flagged for Wyatt rather than changed under a
refactor.

## Risk

The cell-edit arms are a data path (commit / cancel / next-cell). The `continue`s become
`consumed = true` returns and must not change which arms fall through. `edittest`, `tabletest`,
`tablesorttest`, `tablegridtest` and `blocktest` all reach it and are in the sweep.
