# UI spec gaps — start here

The UI rework is a **V1 gate** (Wyatt, 2026-08-04; HANDOFF §6aa fork 1, reversed). This folder is the
working state of it. Read this file first; the others are only useful in order.

---

## The one thing to know before anything else

**`docs/ui-spec/` holds TWO files, and the mockups are in the HTML.**

| File | Size | Holds |
|---|---|---|
| `newtpad-ui-spec-v1.md` | 57 KB | the prose rules |
| `newtpad-ui-spec-v1.html` | **185 KB**, 493 mockup elements | **the rendered mockups** |

On 2026-08-04 two batches were built from the markdown alone and declared "§6 is done". Wyatt put the
app beside the mockups and it did not look like them. **Satisfying the prose is a much smaller claim
than matching the spec, and only the second one is the goal.** Open the HTML.

**Tiebreak rule (Wyatt): "mockup generally wins."** Two named exceptions, both decided *against* the
mockup and recorded in `2026-08-04-visual-gaps.md` — the `Toggle` verb stays dropped, and a disabled
menu row shows its reason rather than its accelerator. Do not "fix" either toward the mockup.

## Reading order

1. **[2026-08-04-visual-gaps.md](2026-08-04-visual-gaps.md)** — the real list, app vs mockups, per
   surface. **This is the live document.**
2. **[2026-08-04-status-bar-plan.md](2026-08-04-status-bar-plan.md)** — half executed; read its header
   correction before trusting the rest.
3. [2026-08-04-menus.md](2026-08-04-menus.md) and [2026-08-04-palette.md](2026-08-04-palette.md) — the
   prose-only analyses. Accurate about §6/§7's *rules*, and both carry a correction header saying what
   that does and does not mean. Useful as reference; **not** a definition of done.

## State as of v0.73.0 (2026-08-04)

| Surface | State |
|---|---|
| **Menus** | §6's 14 prose rules met (§6ch, §6cj). Mockup diffs remain: `Show Menu Bar` row absent, `Find: Regex`/`Ctrl+R` vs built `Find: Regular Expression`/`Alt+R`. Motion (§6 M6) deliberately out with the reduce-motion setting. |
| **Palette** | Rebuilt to the §7 mockup (§6ck): `>` prompt, `4 of 62` count, dimmed legend footer, raised (not accent) selection, 560×88. **Still open:** no scroll — `PALETTE_MAX_ROWS` truncates, which is also the audit's HIGH "selection walks past the drawn rows". Plus PM2/PP1/PP2 and two decisions (Ctrl+Tab, palette-only commands) in the palette file. |
| **Font screen** | Matches §11.1 (§6cl), less the `Ligatures` row (needs DirectWrite font-feature plumbing). |
| **Status bar** | **Seam fixed** (§6cm) — the drop lives in `status_cells`, so drawn and clickable are one geometry. **The mockup's three cells are not added.** |
| **Find bar** | Untouched. The largest gap. Needs the button primitive first. |
| **Everything else** | **Not compared.** ~20 spec sections whose mockups have never been opened. |

## Next session: do the sweep before more code

**The highest-value next action is a full mockup sweep of every `ui-spec` section**, not another
surface. Everything above came from the five surfaces Wyatt happened to screenshot; the total is
unknown, and §9 (markdown) is expected to be larger than the find bar. One pass gives a real number
and will probably reorder the queue.

After that, in Wyatt's chosen order:

1. **Status-bar cells** — small now the seam is fixed. **`status_cells` takes a `[4]Status_Cell`
   buffer at every call site; three more cells overflow it.** Grow it and check every caller, or they
   vanish silently.
2. **The button primitive, then the find bar.** Spec first, then ONE `*_layout()` producer feeding
   draw + hit-test + hover, with seam tests, then the bar on top. Nothing in Newtpad has ever drawn a
   button. It is the foundation the find bar, the status cells and every future control sit on, and
   the piece that stops §6j's seam-bug class repeating.
3. **`Show Menu Bar`** — the feature, not the row: a Settings toggle plus hide/reveal, `Alt` to
   reveal, `☰` opening the same menus. `CHROME_TOP` changes when the bar is hidden and every y below
   it reads that.

## Three traps this work has already hit

- **A test can encode a bug as intent and stay green.** The status bar's own assertion read
  *"status_cells itself does not drop — the caller does, so the geometry stays one thing"*, which was
  backwards, and it passed vacuously besides. Read what an assertion *claims* before trusting that it
  passing means anything.
- **A plan written from reading is a hypothesis.** The status-bar plan called for per-frame App state;
  the extraction showed none was needed. Check a plan's premise before paying its price.
- **Sabotage every new assertion.** The whole-word fixture took four attempts and the first three
  passed while testing nothing (HANDOFF §6ci).
