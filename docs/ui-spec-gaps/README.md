# UI spec gaps — start here

The UI rework is a **V1 gate** (Wyatt, 2026-08-04; HANDOFF §6aa fork 1, reversed). This folder is its
working state. **Current as of v0.85.0, 2026-08-05.**

---

## The one thing to know before anything else

**`docs/ui-spec/` holds TWO files, and the mockups are in the HTML.**

| File | Size | Holds |
|---|---|---|
| `newtpad-ui-spec-v1.md` | 57 KB | the prose rules |
| `newtpad-ui-spec-v1.html` | **185 KB**, 493 mockup elements | **the rendered mockups** |

Two batches were once built from the markdown alone and declared "§6 is done". Wyatt put the app beside
the mockups and it did not look like them. **Satisfying the prose is a much smaller claim than matching
the spec, and only the second one is the goal.** Open the HTML — it renders in a browser and its DOM can
be extracted with inline styles, which is stricter than eyeballing a screenshot.

## The second thing: verify before you believe this folder

Of the 59 items the full sweep first filed, **13 turned out to be already built** and were struck on
inspection. The cause each time: the item was filed from *reading* — a downscaled screenshot, or a prose
rule — rather than from checking the code or the app at 1:1.

The spec's own values are deliberately quiet. `md_code_bg` is **eight units** off `bg_base`;
`table_zebra` is **four**. At half scale they vanish, and "I cannot see it" reads as "it is missing."

> **Verify at 1:1, or read the producer. A capture is evidence of presence, never of absence.**

## Reading order

1. **[2026-08-04-full-sweep.md](2026-08-04-full-sweep.md)** — all 19 sections, every bullet struck and
   stamped with the version that closed it. **The live document.** Carries the current total, the
   corrections, and the diagnosed preview-vs-Obsidian gap.
2. [2026-08-04-visual-gaps.md](2026-08-04-visual-gaps.md) — the five-surface list that preceded it. Best
   writeup of the C1/C2 decisions; its "Scale" section and find-bar row are **superseded**.
3. [2026-08-04-status-bar-plan.md](2026-08-04-status-bar-plan.md) — half executed; read its header
   correction first.
4. [2026-08-04-menus.md](2026-08-04-menus.md), [2026-08-04-palette.md](2026-08-04-palette.md) — prose-only
   analyses. Accurate about the *rules*; **not** a definition of done.

## Decisions — do not relitigate

**Tiebreak: "mockup generally wins" (Wyatt).** Six named exceptions, each decided individually:

| | Decision |
|---|---|
| **C1** | The `Toggle` verb stays dropped — `Word Wrap`, not `Toggle Word Wrap`. |
| **C2** | A disabled menu row shows its **reason**, not its accelerator. |
| **C3** | `scrollbar_thumb` keeps `#746B61`; the spec's `#3E3833` measures 1.42:1 against a claimed 3.0:1. |
| **C4** | **Monaspace Argon is rejected.** Chrome stays monospace. §2's type table is a rejected section, and §13's "numbers in Neon, words in Argon" dies with it. |
| **C5** | `Open Themes Folder` stays, though the mockup omits it. |
| **C6** | Regex keeps `Alt+R` (all three find toggles are Alt, matching VS Code); only the label shortened. |

Two more overrules of the spec, from live use on 2026-08-05:

- **The editor's 100-column wrap cap (§8) is gone.** Wrap follows the window.
- **§9.3's 72ch measure is PROSE-only.** Tables and fenced code get the whole pane — capping a table
  makes its columns narrower and its cells wrap *more*, which is the opposite of what a measure is for.

## State as of v0.85.0

**21 items shipped across v0.74.0–v0.85.0**, ~24 remain. Highlights:

- **`src/ui` is real** — control geometry (`Button`, `pack`, opt-in pixel snapping), 13 tests, no device
  needed. Every control in the product now shares it: the find bar's row, its replace buttons, and the
  menu bar's `Commands` item. **`ui` decides where things are; `program` decides what they look like.**
- **Find bar** rebuilt to §12: bordered input, count column, chips inline, `↑ ↓`, `Filter Ctrl+L`, `✕`.
- **Status bar** has its four cells and a size in the left group.
- **Show Menu Bar** ships: setting, Alt reveal, `☰` in the rail, plus §5's 360px collapse.
- **Settings** is grouped (SESSION / APPEARANCE / EDITOR / VIEWS), which required moving 30 index-based
  switch cases onto a stable `Setting_Id`.
- **Font enumeration** — 22 monospaced families against the curated 14, per-user fonts included.
- **Markdown** — §9.4's bordered table card, filled checkbox, cell padding.
- **Palette scrolls** — closing the audit's open HIGH.

## What next

1. **Extract the frame loop's context selection into a proc.** The Alt-reveal fix (§6ct) is verified only
   by a live pass; its test drives `menu_close` directly and cannot prove the frame loop *reaches* it,
   because the context choice is inline in `main.odin`. This is the smallest real improvement available.
2. **The preview vs Obsidian** — **deferred by Wyatt on 2026-08-05** ("push it off, there are other
   issues"), and diagnosed in the sweep: a fence with no resolved lexer renders in the **proportional
   serif** face; ` ```powershell ` resolves no lexer though `.ps1` has one; no lang label. **Two of the
   three are ~2 lines.**
3. The decision-needed three (§5 overflow, §10 column fill, §2 type scale) — cheaper to ask than to build.

## Traps this work has hit, each more than once

- **A test can encode a bug as intent and stay green.** The status bar's own assertion once read
  *"status_cells itself does not drop — the caller does"*, which was backwards, and passed vacuously.
- **An assertion with slack is one something drifts into.** Four times this session: a 1px centring
  tolerance that admitted the defect; a gap check that reduced to `trow <= trow * 1.5`; a header-band
  probe that measured glyph ink; and "label and chord sit inside the box", which absorbed a 6px drift.
  **Where a value is derivable, assert the value, not a bound.**
- **Sweep the modes the CHANGE can reach, not the list your batch wrote down.** Twice this session:
  `gutterseamtest` and `rulestest` both went red for releases. The second had been failing for **nine**.
- **A silent mode is not a passing mode.** A release build is GUI-subsystem and prints nothing; a stray
  `newtpad` holding the exe means a "rebuild" tests the old binary.
- **A plan written from reading is a hypothesis.** Check its premise before paying its price.
