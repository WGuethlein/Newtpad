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

**Tiebreak rule (Wyatt): "mockup generally wins."** **Three** named exceptions, all decided *against*
the mockup — the `Toggle` verb stays dropped (C1), a disabled menu row shows its reason rather than its
accelerator (C2), and `scrollbar_thumb` keeps `#746B61` because the spec's `#3E3833` fails the contrast
it claims (C3, found in the sweep; reasoning lives in `theme.odin`). Do not "fix" any of them toward
the mockup. C1/C2 are written up in `2026-08-04-visual-gaps.md`, C3 in the sweep.

## Reading order

1. **[2026-08-04-full-sweep.md](2026-08-04-full-sweep.md)** — all 19 sections, mockups opened, app
   captured beside them. **This is the live document.** It carries the total (59 items), four
   corrections to the files below, and the one gap that was on no list — §2's chrome font.
2. [2026-08-04-visual-gaps.md](2026-08-04-visual-gaps.md) — the five-surface list that preceded it.
   Still the best writeup of the C1/C2 decisions. **Its "Scale" section and its find-bar row are
   superseded** — see the sweep's corrections 1 and 2.
3. **[2026-08-04-status-bar-plan.md](2026-08-04-status-bar-plan.md)** — half executed; read its header
   correction before trusting the rest.
4. [2026-08-04-menus.md](2026-08-04-menus.md) and [2026-08-04-palette.md](2026-08-04-palette.md) — the
   prose-only analyses. Accurate about §6/§7's *rules*, and both carry a correction header saying what
   that does and does not mean. Useful as reference; **not** a definition of done.

## State as of v0.73.0 (2026-08-04)

| Surface | State |
|---|---|
| **Menus** | §6's 14 prose rules met (§6ch, §6cj). Mockup diffs remain: `Show Menu Bar` row absent, `Find: Regex`/`Ctrl+R` vs built `Find: Regular Expression`/`Alt+R`. Motion (§6 M6) deliberately out with the reduce-motion setting. |
| **Palette** | Rebuilt to the §7 mockup (§6ck): `>` prompt, `4 of 62` count, dimmed legend footer, raised (not accent) selection, 560×88. **Still open:** no scroll — `PALETTE_MAX_ROWS` truncates, which is also the audit's HIGH "selection walks past the drawn rows". Plus PM2/PP1/PP2 and two decisions (Ctrl+Tab, palette-only commands) in the palette file. |
| **Font screen** | Matches §11.1 (§6cl), less the `Ligatures` row (needs DirectWrite font-feature plumbing). |
| **Status bar** | **Seam fixed** (§6cm) — the drop lives in `status_cells`, so drawn and clickable are one geometry. **The mockup's three cells are not added.** |
| **Find bar** | ~~Untouched. The largest gap.~~ **Wrong — see the sweep.** The chips, the live count and two real replace buttons already ship. Six items remain, four small. |
| **Everything else** | **Swept 2026-08-04.** See [the full sweep](2026-08-04-full-sweep.md). |

## The sweep is done: 59 items

All 19 sections compared. Headline findings:

- **§2's chrome font is the biggest gap in the product and was on no list.** The spec wants Monaspace
  Argon (proportional) for all chrome; every surface draws Cascadia Mono. The plumbing exists
  (`ui_font_family`, a `.UI` font slot); only the face is missing. It changes all 19 sections at once.
- **A button primitive already exists** — `Find_Action` in `find.odin`, one producer feeding draw,
  hit-test, hover and cursor, with seam tests. Since 2026-07-28.
- **§9 markdown is nearly done, not a hole** — serif preview, heading rules, real bold/italic, nested
  lists all ship. But **its tables render broken**, which is the worst-looking defect found anywhere.
- **§15 needs no work at all.**

Wyatt's chosen order, as amended by the sweep:

1. **Status-bar cells** — unchanged, small. **`status_cells` takes a `[4]Status_Cell` buffer at every
   call site; three more cells overflow it.** Grow it and check every caller, or they vanish silently.
2. **The find bar** — *promote* `Find_Action` into a shared control rather than building one, then add
   the bordered input, the `↑` `↓` buttons, the `Filter Ctrl+L` pill and the `✕`. Extending the focus
   ring (§18) off the same control is the natural companion.
3. **`Show Menu Bar`** — the feature, not the row: a Settings toggle plus hide/reveal, `Alt` to
   reveal, `☰` opening the same menus. `CHROME_TOP` changes when the bar is hidden and every y below
   it reads that. Also unlocks §5's 360px collapse.

## Three traps this work has already hit

- **A test can encode a bug as intent and stay green.** The status bar's own assertion read
  *"status_cells itself does not drop — the caller does, so the geometry stays one thing"*, which was
  backwards, and it passed vacuously besides. Read what an assertion *claims* before trusting that it
  passing means anything.
- **A plan written from reading is a hypothesis.** The status-bar plan called for per-frame App state;
  the extraction showed none was needed. Check a plan's premise before paying its price.
- **Sabotage every new assertion.** The whole-word fixture took four attempts and the first three
  passed while testing nothing (HANDOFF §6ci).
