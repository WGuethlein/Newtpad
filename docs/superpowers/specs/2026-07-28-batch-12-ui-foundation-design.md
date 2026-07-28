# Batch 12 — UI foundation (design)

The first batch of the UI overhaul (CLAUDE.md priority 2). Source material: a 21-section UI
specification produced with Claude Design (`Newtpad UI specification v1`, plus an HTML visual
reference with the same content rendered).

That document states its own status plainly and it governs how this batch reads it:

> This is a target state, not an audit of the codebase. It was written from screenshots,
> `Light Custom.theme`, and the colour-rules file — nothing else. **If the code and this document
> conflict on a fact, the code wins.** If they conflict on a value, this document is the intended
> value.

So the first work of this batch was the audit the spec could not do. It changed the plan twice.

Decisions taken with Wyatt, 2026-07-28. **Do not relitigate.**

1. **Batch 12 is spec steps 1, 2, 4 plus the font *split*** — theme, metrics struct, SDF pipeline,
   and separating the interface font from the document font. Wyatt: *"i want them all done today, i
   don't care the order per se."*
2. **Six new theme roles, not nine and not zero.** See item 1 for which four were dropped and why
   `scrollbar_thumb` was added back after the audit.
3. **Monaspace is embedded — but not in this batch.** Wyatt chose to embed all four faces; the audit
   then found there is no in-memory font path at all. Item 4 lands the architecture with a font that
   is already present, and the embedding gets its own batch. This is the one place the answer given
   and the work done differ, and it is recorded here rather than quietly absorbed.
4. **Chrome sizes change in the same commits as the metrics conversion**, not in a follow-up pass.
5. **Batch 13 is the shell** — tabs, focus ring, motion, narrow windows.

## What the audit found, and what it changed

**The spec assumed missing things that are already built.** Read this before treating any badge in
that document as a defect:

- **§3 DPI is ~80% done.** `src/platform/newtpad.manifest` declares `PerMonitorV2` (spec item 1),
  with a comment explaining why it is not a runtime `SetProcessDpiAwarenessContext` call.
  `window.odin:623` already performs suggested-rect → `SetWindowPos` → rebuild metrics → re-bake, and
  carries the words *"Order matters"* (spec item 2). `DWMWCP_ROUND` is set (§4.1).
- **§4.1 caption ownership is done.** `WM_NCCALCSIZE`, `WM_NCHITTEST` and `WM_NCLBUTTONDOWN` are all
  handled.
- **§14 is roughly two-thirds done.** `CreateFileMapping`/`MapViewOfFile` in `file.odin`, a search
  worker with atomic `scanned`/`cancel`/`done`, `SEARCH_SYNC_MAX` chunking, and a first-paint budget.
- **§17's `base dark` / `base light` inheritance** — which the spec calls the best decision in the
  current format — already works.

**Two findings changed this batch's content:**

- **`scrollbar_thumb` goes back in.** It was dropped from the recommended set, then restored on
  evidence: `theme.odin:63` already records the split as owed — *"this role is both a text colour
  (gutter numbers, every hint line) AND a fill (the scrollbar thumb). An author darkening it for
  gutter legibility unavoidably darkens the thumb too; Light already shows this as a heavy near-black
  bar on a pale track. Not split here … but recorded so the next batch finds both candidates
  together."* The spec reached the same conclusion independently. This is that next batch.
- **Embedding Monaspace is not a half-day step.** Fonts resolve **by filename out of
  `%SystemRoot%\Fonts\`** (`text.odin:98`, `font_family_available`). There is no load-from-memory
  route. Embedding therefore means hand-declaring `IDWriteFontFileLoader` and
  `IDWriteFontFileStream` — *callback* interfaces whose vtables this project would implement, which
  is materially harder than the DirectWrite calls `dwrite.odin` already declares — plus rewriting the
  central claim in `THIRD-PARTY-NOTICES.txt`: *"It bundles and redistributes no third-party
  components … nothing vendored into the tree."* Monaspace is also not installed on this machine.

## Item 1 — theme: six roles, two repainted built-ins

Add to `Color_Role`: `Bg_Hover`, `Accent_Wash`, `Focus_Ring`, `Scrollbar_Thumb`, `Md_Code_Bg`,
`Md_Rule`. Repaint `theme_dark` and `theme_light` to the spec's §1.1/§1.2 values — warm neutrals,
chroma under 0.02, one accent used only for state.

Three of the spec's nine are dropped as reusable, and the reasoning is the same one that took the
palette from 66 roles to 25 in §6v — a role a themer never needs to set independently is a tax on
every theme file:

| Dropped | Resolves to | Why it needs no key |
|---|---|---|
| `table_zebra` | derived from `Bg_Base` | An alternating row fill is a fixed delta from the surface it alternates on. A themer who changes `Bg_Base` wants the zebra to follow, not to re-pick it. |
| `md_bold` | `Text_Bright` | The spec's own rule is *"weight does the work, colour assists."* Both its files give `md_bold` a value already used by `text_bright`. |
| `md_list_mark` | `Accent` | Both spec files set it to exactly the accent value. A role whose only value is another role's value is an alias. |

`Md_Rule` is **kept** despite looking similar, because `markdown.odin` currently draws rules with
`Border_Strong` — a chrome role — so a themer tuning menu borders moves markdown rules with them.

Odin rejects an incomplete keyed enumerated-array composite literal, so adding a role is a compile
error in both built-ins until both supply it. That guarantee is the language's, not a test's.

**Verification.** `themetest` gains §17's six contrast pairs as real assertions computed from the
theme values — body-on-base, secondary-on-panel, muted-on-base, body-on-`selection_doc`,
body-on-`find_match_bg`, `filter_text`-on-`filter_bg`. Each must clear 4.5:1. The existing
magenta-placeholder guard stays.

## Item 2 — metrics: one scale point

Today `sx()` is called at **167 sites** across `src/program`. The spec's §3 rule 3 names exactly this
as the defect: *"Never scale at the call site — that is how two things that should align end up one
pixel apart at 125%."*

Build a `Metrics` struct holding every scaled value, computed once per DPI change and read everywhere.
Convert the call sites file by file, one commit per file. Carry the §2.1–2.4 values in the same
commits, per decision 4: tab rail 36 → 40, status bar 20 → 26, scrollbar 16 → 8, editor top padding
10 → 16.

Two rounding rules the current code gets wrong, both from §3:

- **Hairlines are `max(1, floor(s))`, never `round`.** At 125% a rounded hairline lands at an offset
  straddling two device pixels and renders as two half-alpha lines. `sx()` rounds.
- **Font pixel size rounds to even, then everything derives from it.** An odd line height makes
  vertical centring inside a 30px row land on a half pixel.

**Verification.** A new `metricstest` asserts the struct at 100/125/150/175/200%: every field a whole
number, hairlines exactly 1 at 100–125%, font px even at every scale, and the four alignment pairs
§3.8 names — menu-bar hairline, caption stroke, status-cell dividers, and the active tab's left edge
against the editor's left padding. The sabotage is restoring `round` for hairlines and watching the
125% case fail.

## Item 3 — the SDF rounded-rect pipeline

`plat.Quad` is `{pos, size, color}`. Every corner in the app is square, and there are no shadows and
no focus rings, because there is nothing to draw them with. This item is also the `renderer`
extraction CLAUDE.md's priority 2 names — §19 and that extraction are one job, not two.

Extend the instance to carry `radius: [4]f32` and `softness: f32`; replace the pixel shader with a
signed-distance rounded box and `fwidth`-based analytic AA. Rounded corners, hairlines, focus rings
and panel shadows all become the same instance with different parameters. Still one draw call.

**Verification, and it is the whole point of this item:** with `radius = 0` and `softness = 0` the
output must be **pixel-identical to today**. Verified against a real D3D11 device by rendering the
same scene through both shaders and comparing the readback buffer byte for byte — not by arithmetic,
per CLAUDE.md's *"a real device over arithmetic when the claim is about the GPU."* `devicelosttest`
and `atlastest` already establish the offscreen-device pattern this reuses.

## Item 4 — interface font, separated from the document font

Split the single font setting into **document font** and **interface font**, and route every chrome
draw through the interface face. §2.5's argument is that one designer's two families is the single
change that most removes the developer-tool feel; the prerequisite is that chrome stops borrowing the
document font at all.

**Default the interface font to Cascadia Mono**, which `FONT_FAMILIES` already registers and which
ships on Windows 11. That lands the architecture and the Settings row today. When the embedding batch
runs, Monaspace Argon becomes one more entry in that table and one line in the default — no
structural change.

## What this batch does not do

- **Monaspace embedding** (its own batch — the DirectWrite in-memory loader plus the licensing
  change).
- Everything in the roadmap below. This batch is the keystone: radii, shadows and focus rings need
  item 3, and every layout in batches 13–15 needs item 2 or it gets laid out twice.

## Where the rest of the specification lands

Audited status, so the spec's 13 build steps are ~8 batches rather than 13:

| § | Section | Status | Batch |
|---|---|---|---|
| 1, 2, 19, 2.5 | Theme, metrics, pipeline, font split | this batch | **12** |
| 4.2 | Tabs: pills, dirty slot, truncation, reorder | tabs exist, none of the treatment | 13 |
| 18 | Focus ring, motion, reduced motion | nothing | 13 |
| 5 | Narrow-window drop order | nothing — no `WM_GETMINMAXINFO` | 13 |
| 7.1 | `>_` palette entry point | magnifier button today | 13 |
| 6, 7, 11, 13 | Menus, palette, settings/font, status bar | all exist; layout and defects owed | 14 |
| 12 | Find/replace/filter | regex exists but is a hidden Ctrl+R state, exactly as §12 complains; filter keeps original line numbers (§12 calls this the best thing in the screenshots); bar is at the bottom and moves to the top | 15 |
| 9.2, 9.4 | Markdown parser + split rules | parser ~50%, split view works | 16 |
| 9.1, 9.3 | Preview shaper + type scale | preview works but is grid-based | 17 |
| 10, 8, 15, 16 | Table, editor details, empty tab, icon | table exists without sort/zebra/row numbers; no `.ico` exists at all | 18 |
| 14, 17 | Huge files, theme warnings/high contrast | §14 two-thirds built; §17 owes warnings and Follow Windows | 19 |
| — | Monaspace embedding | no in-memory font path | 20 |

§3 (DPI) and §4.1 (caption ownership) are done and appear in no batch.
