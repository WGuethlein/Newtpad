# UI spec gaps — start here

The UI rework is a **V1 gate** (Wyatt, 2026-08-04; HANDOFF §6aa fork 1, reversed). This folder is its
working state. **Current as of v0.91.0, 2026-09-03.**

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

Of the 59 items the full sweep first filed, **14 have turned out to be already built** and were struck on
inspection. The cause each time: the item was filed from *reading* — a downscaled screenshot, or a prose
rule — rather than from checking the code or the app at 1:1.

**The fourteenth (2026-08-06) is the sharpest example, because the evidence was already running.** §16
said *"No icon work exists."* The icon shipped in v0.31.0, `newtpad.rc` embeds it as the exe's own icon,
and **`icontest` has been in HANDOFF §7's required sweep the whole time** — printing 39 `OK` lines that
assert the seven sizes, the no-scaling rule, the `#F2EBE0` paper and the two/three-line rule this entry
called missing. Every sweep since ran it. **Before filing anything as absent, grep the mode list for it.**

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

**Tiebreak: "mockup generally wins" (Wyatt).** Nine named exceptions, each decided individually:

| | Decision |
|---|---|
| **C1** | The `Toggle` verb stays dropped — `Word Wrap`, not `Toggle Word Wrap`. |
| **C2** | A disabled menu row shows its **reason**, not its accelerator. |
| **C3** | `scrollbar_thumb` keeps `#746B61`; the spec's `#3E3833` measures 1.42:1 against a claimed 3.0:1. |
| **C4** | **Monaspace Argon is rejected.** Chrome stays monospace. §2's type table is a rejected section, and §13's "numbers in Neon, words in Argon" dies with it. |
| **C5** | `Open Themes Folder` stays, though the mockup omits it. |
| **C6** | Regex keeps `Alt+R` (all three find toggles are Alt, matching VS Code); only the label shortened. |
| **C7** | **The markdown preview is measured against OBSIDIAN, and Obsidian wins where it and §9 conflict.** Wyatt, 2026-08-06, after comparing them: *"it deviates a lot compared to Obsidian's markdown previewer. it look horrendous compared to it. It definitely needs to be redone before the release."* This is the first exception that overrules a whole section's design rather than one row of it, and **§9.3's serif body is explicitly in scope** — the register records that serif as something we got right, and it is now something to re-judge rather than defend. **Executed v0.91.0** (HANDOFF §6de) — the serif went, and what replaced it is Segoe UI, which is the face Obsidian resolves to on Windows. |
| **C8** | **UI spec §17's motion table gives `scroll` a budget of 0ms, and that stands.** Wyatt asked for eased scrolling (2026-09-03); the devil's advocate found it contradicts that row *and* `main.odin:415`'s "the caret blink is the ONE timer in this app". The complaint was quantisation, not the absence of animation, and pixels fix that at 0ms — so easing is **deferred, not refused**, and buying it means amending §17 in writing and building §11's Reduce motion setting first. Revisit only if the pixel sync still reads as blocky. |
| **C9** | **§9.4's "scroll sync by block, not by line" is overruled in its EFFECT and kept in its REASON.** The rule's stated reason — *"line-based sync drifts the moment a heading or a code fence changes height"* — is still true, so the anchor is still a block and nothing counts lines from the top of the document; the pixels are interpolated only *within* that block, where the two views describe the same bytes. Shipped v0.91.0. |

**C7 also reclassifies the work.** It was deferred on 2026-08-05 as a retouch, and I costed it at "two
lines plus a polish tail" as recently as 2026-08-06 — from the three defects visible in the SOURCE.
That was the wrong question. *"Three things I can point at in the code"* is not *"does it look good
beside the thing it will be compared to"*, and only one of us can answer the second. **It is a
pre-release blocker, not polish**, and the scope is a typography and spacing pass over the whole
preview: heading scale and weights, body size and line height, the space above and below every block
kind, measure, list indentation, code-block and inline-code treatment, blockquote, table density.

`docs/preview-compare.md` is the fixture: every structure the preview renders, on one screen, so the
same document can be captured in both applications and compared block for block.

Two more overrules of the spec, from live use on 2026-08-05:

- **The editor's 100-column wrap cap (§8) is gone.** Wrap follows the window.
- ~~**§9.3's 72ch measure is PROSE-only.**~~ **SUPERSEDED by C7, v0.91.0.** The measure is a four-state
  reader choice now (Full / Left / Centre / Right), defaulting to **Full** — no cap at all, which is
  what Wyatt's own Obsidian does. The prose-only carve-out existed because a 72ch cap applied to a
  table made its cells wrap *more*; under Full nothing is capped, and under a chosen column everything
  inside it belongs inside it, so the exemption has nothing left to protect. See `md_content_span`.

## State as of v0.87.0

**21 items shipped across v0.74.0–v0.85.0**, ~24 remain. Highlights:

- **`src/ui` is real** — control geometry (`Button`, `pack`, `Segmented`, opt-in pixel snapping), 19
  tests, no device needed. Every control in the product now shares it: the find bar's row, its replace
  buttons, the menu bar's `Commands` item, and (v0.91.0) the preview's column control, which is the
  first one that sits over the CONTENT rather than in the chrome.
  **`ui` decides where things are; `program` decides what they look like.**
- **Find bar** rebuilt to §12: bordered input, count column, chips inline, `↑ ↓`, `Filter Ctrl+L`, `✕`.
- **Status bar** has its four cells and a size in the left group.
- **Show Menu Bar** ships: setting, Alt reveal, `☰` in the rail, plus §5's 360px collapse.
- **Settings** is grouped (SESSION / APPEARANCE / EDITOR / VIEWS), which required moving 30 index-based
  switch cases onto a stable `Setting_Id`.
- **Font enumeration** — 22 monospaced families against the curated 14, per-user fonts included.
- **Markdown** — §9.4's bordered table card, filled checkbox, cell padding.
- **Palette scrolls** — closing the audit's open HIGH.

## What next

1. ~~**Extract the frame loop's context selection into a proc.**~~ **DONE v0.86.0 (HANDOFF §6cz).** The
   whole per-event decision — cell-edit intercept, context priority, `resolve_key`, both `menu_close`
   rules — is `key_route` in `commands.odin`, and `keytest`/`metricstest` now drive it. Deleting the
   guard §6ct says leaves the suite green fails four assertions across two modes.
2. **§13 is done** (v0.87.0) — the left group is three cells, `Saved` is a `success` cell, errors take
   the whole bar and replaced a modal. And the `+N` overflow count **had never been clickable**: it sat
   past `win.tabs_right`, in the OS drag region, on exactly the widths where it is drawn.
3. ~~**The preview vs Obsidian**~~ — **BUILT v0.91.0 (HANDOFF §6de).** Type scale, per-level heading
   leading, flat rhythm with the heading pair rule, Segoe UI body, block geometry, the four-state
   column, the heading rules dropped, the fences fixed and the Split sync interpolated. The sweep's own
   three-defect diagnosis is closed with one correction on the record: it named `fallback_set`, which is
   read at exactly one place (the empty-block height fallback), so setting it fixes nothing — the face
   comes from `md_run_set`. **The language label is struck rather than built**: Obsidian's reading view
   has none (`code-block-flair` lives only under `.markdown-source-view`), and C7 makes it the
   authority. **What is still owed is the 1:1 pass** — every number came from Obsidian's stylesheet,
   and nobody has yet put the two side by side.
4. ~~The decision-needed three~~ — **all three decided 2026-08-05**: `+N` stays, table columns keep
   their slack, the type scale stays at two sizes. See the sweep.

## Traps this work has hit, each more than once

- **A test can encode a bug as intent and stay green.** The status bar's own assertion once read
  *"status_cells itself does not drop — the caller does"*, which was backwards, and passed vacuously.
- **An assertion with slack is one something drifts into.** Four times in one session: a 1px centring
  tolerance that admitted the defect; a gap check that reduced to `trow <= trow * 1.5`; a header-band
  probe that measured glyph ink; and "label and chord sit inside the box", which absorbed a 6px drift.
  **Three more in v0.91.0, each the exact size of the defect**: the gap table compares with ±1px while
  the thematic break's change is 2px against 1; the same table added `+ hairline()` to its h1/h2
  heights, so removing the heading rule moved them by precisely the tolerance; and it named
  `hairline()` as the break's own expected height, which is *the test agreeing with the bug*.
  **Where a value is derivable, assert the value, not a bound.**
- **A fixture goes QUIET before it goes red, and quiet is worse.** Five in v0.91.0: a descent that
  clamped at the ceiling and saw two blocks instead of three; probes at fixed offsets that fell into
  gaps a shorter heading opened; a two-family cache-key fixture that stopped diverging *twice*; and a
  `ui_scale` case still watching a quantity that had stopped varying with DPI. None of them failed —
  they passed while testing nothing. **Fix the fixture, never the bound**, and where a case depends on
  an observable varying, assert that it still varies.
- **A test can pass for the wrong reason and look identical to one that passes.** Two harnesses in
  v0.91.0: `md_layout_build_for_test` hands `in_fence = false` unconditionally, so a test asking for a
  fence body got a paragraph and asserted happily about it; and `mdfencetest` never set `g_theme`, so
  every syntax role resolved to the zero value and eight tokens counted as "one colour". The tell in
  both cases was a CONTROL case failing — the thing already known to work.
- **Sweep the modes the CHANGE can reach, not the list your batch wrote down.** Twice this session:
  `gutterseamtest` and `rulestest` both went red for releases. The second had been failing for **nine**.
- **A silent mode is not a passing mode.** A release build is GUI-subsystem and prints nothing; a stray
  `newtpad` holding the exe means a "rebuild" tests the old binary.
- **A plan written from reading is a hypothesis.** Check its premise before paying its price.
