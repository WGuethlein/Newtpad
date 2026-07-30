# Requested and owed features

The counterpart to [reported-bugs.md](reported-bugs.md). **Bugs live there; features live here.**
Same rule: **when an item ships, delete it from here and record it in the HANDOFF entry instead.** This
is a queue, not a history.

Compiled 2026-07-30 by sweeping HANDOFF §5/§6 and every `### Owed` section, `docs/ui-spec/`,
`docs/2026-07-25-forgotten-feature-audit.md`, `docs/live-pass-*.md`, and the project memory. Where an
item was **decided** one way or another, that is recorded — several things on this list were ruled out
once and would be a reopening, not a new idea.

---

## 1. Asked for directly by Wyatt, unscheduled

### JSON formatting — reformat minified JSON into readable JSON

**Requested 2026-07-30**, illustrated with a `.log` file that is one enormous unreadable line, and a
`tasks.json` showing the wanted result. Wyatt, clarifying: *"if a json comes in not following the typical
formatting schema, I want to give an option to format it so that it no longer looks like the log file, but
the tasks.json… vscode has a similar feature."* So: **VS Code's Format Document, for JSON.** The log was
the illustration of unreadable input, not a separate feature.

**This reopens a locked decision.** HANDOFF §6aa records first-party JSON/CSV/XML reformat as decided
**out** of V1 and held to the V2 plugin proofs, and CLAUDE.md scopes the plugin C-ABI to *"formatters +
viewers"* precisely so a formatter proves that boundary works. Wyatt has now asked for it, so the open
question is **whether it moves into V1 as a built-in or stays the V2 plugin proof** — building it
first-party spends the plugin system's motivating example.

Decisions that change the build:
- **Edit the buffer, or a view?** Every other editor means *edit*. But Newtpad has three view modes
  already (table, preview, split), all `doc_read_only_view`, and a view leaves the bytes alone. **A view
  is also the only answer that survives the size constraint** — Newtpad opens multi-GB files,
  viewport-first forbids a whole-document main-thread pass, and a 2 GB minified JSON is a realistic input.
- **Whole file, selection, or line?** Whole file is the ask; a selection or line variant also covers
  JSON embedded in a log line.
- **Key order must be preserved**, which rules out parse-to-map-and-re-emit.
- **Invalid JSON must be marked, not silently refused** — the same reasoning §10 applies to malformed CSV
  rows.
- Indent width, and whether it follows the existing tab-width setting.

**Build on `src/base/lex_json.odin`** — a hand-rolled, viewport-bounded JSON lexer already driving the
highlighting. A formatter over its token stream inherits the bounding and cannot disagree with the
highlighter about what a token is. **Do not write a second JSON parser.**

---

## 2. The UI spec still owes these

`docs/ui-spec/` is the corpus for UI work. Section by section, what is asked for and not built:

### §10 Table view — 5 of 9 rules unbuilt (batch 18 is partial)
- **Row numbers** — 56px right-aligned gutter, `text_secondary` on the current row.
- **Click-to-sort with an accent arrow**, view-only, never rewriting the file. *The table view is already
  an editing surface, so this is a data-safety seam* — see §5's guard notes.
- **Numeric and date columns right-align**, detected from the first 200 rows.
- **Column widths from a sample** — 200 rows, clamp 8–40 chars, distribute proportionally; drag a header
  edge to resize, double-click to fit.
- **Malformed rows marked with a 2px `warning` bar**, not hidden.
- **Summary row** — row count, column count, active sort.

### §8 Editor surface
- **Caret blink** — 500ms, stopping while typing and for 500ms after. *No blink implementation exists.*
- **Gutter** — 44px right-aligned + 12px gap, off by default, current line `text_primary`.
- **Current-line tint** — off by default, 3% when on.
- **Wrap indent** — a wrapped line continues at the original indent + 2 columns.
- **Wrap column cap** — cap the text column at 100 characters in wrap mode. §8: *"On a maximised 1440p
  window an uncapped wrap gives 200-character lines."*

### §9 Markdown
- **Concealment** — hide `#`/`**` on non-caret lines, Obsidian-style. **Wyatt chose this** and it is not
  built: it makes the drawn column stop matching the byte column, which is the seam §6j records sixteen
  bugs against. Needs its own batch.
- **Autolinks and reference links** — only `[a](b)` works.
- **h6 caps and tracking** (§9.3) — h6 is currently identical to h5.
- **A *Preview font* setting** (§9.3), defaulting to the shipped serif with the editor font as an option.
- **The caption/meta row** (§9.3, 0.88 S) — computed and unread.
- **Zebra rows in the preview table** (§9.2 item 6) — the preview doubled down on per-column rules.
- **Preview selection and copy** (§9.4) — a silent omission, never a recorded deferral.
- **The heading tick-mark rail** (§9.4) — an 8px mini-map of `md_heading` ticks.
- **Divider `border_subtle` + 320px minimum pane** (§9.4) — currently `Border_Strong` and 0.15/0.85.
- **Lists do not nest visually** beyond their indent — no per-level bullet cycling.
- **A screen *above* the viewport** is laid out only on the scroll-up gesture, not per pass (§9.1).

### §14 Huge files
- **Progress hairline and the sparse index** — two-thirds built.

### §15 The empty tab
- The caret already there and blinking; **three hints bottom-left** (`Ctrl+O`, `Ctrl+P`, `drop`) that
  vanish on the first keystroke; **a 2px accent inset drop ring** on the editor area only.

### §16 Icon
- **A document icon per associated extension** (same shape, extension label in the corner).
- **A monochrome variant** for the notification area.

### §17 Themes
- **Theme warnings** and **Follow Windows**; high contrast is blocked on the colour-token layer.

### §18 Accessibility
- **A UIA provider / screen-reader support.** §6aa decided this rides with the V2 UI refresh — *"the
  beta and the paid V1 both ship with no screen-reader support"*, a deliberate dated choice.

### §20 Monaspace
- **Embed Monaspace Neon** — needs an in-memory font path. Retires the Georgia fallback and the
  mono-face assumption in the preview.

---

## 3. Roadmap: beta → V1 → V2

From HANDOFF §6aa, which is the plan of record.

**Before the free public beta**
- Landing page, download, and **publish the price early and hold it** (File Pilot precedent).
- **Code signing** — pipeline is built signing-*ready*; blocked on Wyatt purchasing a certificate.
  Never handle a certificate or its password.

**V1 (paid), after the beta**
- **Trial**, **offline license key**, **storefront** — informed by beta feedback.
- **Rebindable keys** are in V1 (CLAUDE.md principle 4). The data-declared command table exists; only the
  user overlay is missing.

**V2**
- **The UI overhaul and the `renderer`/`ui` extraction.** §6aa moved these to V2 as its *first* item, on
  File Pilot's own advice: budget exactly one UI rewrite and do it after real use. `src/renderer` and
  `src/ui` are still empty stubs, and recent batches made the extraction measurably harder in ~10 named
  places.
- **Plugins** — narrow C-ABI, formatters + viewers, worker threads, timeouts. Never generic scripting.
- **First-party JSON/CSV/XML reformat** — see item 1; Wyatt may have just moved this.
- **Accessibility**, per §18 above.

---

## 4. Never decided either way

Surfaced by the 2026-07-18 research (§C's secondary list), never ruled in or out. Ordered by
value-per-cost for this audience:

| Feature | Why it matters here | Cost |
|---|---|---|
| **Global hotkey / always-on-top quick capture** | *"a whole product category"*, fits the scratchpad positioning | Medium |
| **Code folding** | expected in the "power notepad" tier | Medium |
| **Macros / record-replay** | overlaps regex find/replace | Medium |
| **File compare / diff** | 4 of 5 competitors have it; the #1 Notepad++ plugin | Stretches scope |
| **Print / print preview** | requested; arguably outside "fast viewer" | Medium |
| **Spellcheck** | table-stakes creep for prose; conflicts with "fight options" | Medium |

*Research §E explicitly marks go-to-line syntax and drag-drop as **not** demanded.*

Also never decided, from HANDOFF §6:
- **Complex-script shaping** (Arabic/Indic/ligatures via `IDWriteTextAnalyzer`) — the chosen follow-up to
  per-codepoint fallback. Related: the caret/hit-test/selection/find rects assume a monospace column, so
  they misalign on CJK and emoji; the real fix needs per-glyph x positions, which comes with shaping.
- **Colour emoji** — needs a colour-glyph path.
- **A container/archive tree viewer** — parked, edges toward scope creep.
- **Directories opening as a tab** listing contents rather than revealing in Explorer.

---

## 5. Feature-shaped engine work

Not user-facing features, but not bugs either — each changes what the product can do.

- **An async link resolver** (`watch.odin`-shaped worker). Today **non-local link targets never resolve
  at all** — `\\server\share\x`, `smb://`, and *every* link inside a document opened from a UNC path or
  mapped drive. Refusing to stat is what fixed a >100-second UI freeze; restoring the coverage needs the
  worker. **This is the largest user-visible capability currently missing.**
- **A real scissor-rect facility.** The renderer has never had one; clipping is a cover strip painted
  after the content passes, now with three consumers. Would retire the hack and unblock cleaner preview
  clipping.
- **`WaitMessage` when idle** — the app redraws at vsync with nothing happening, burning a core on a
  static window.
- **Batch the text pipeline** — one heap allocation, two buffer maps and one draw call per `text_draw`.
- **Precompiled `.cso` shaders** — drops the `d3dcompiler_47.dll` runtime dependency. Wanted before ship.
- **Coalesce consecutive block edits into one undo entry** — currently correctness-adjacent, not cosmetic.
- **`pt_insert` never coalesces adjacent appends**, so a multi-row edit fragments the tree.
- **reindex-on-edit** — line count and scrollbar drift after big edits.
- **Command/hotkey/option codegen from a data file** — hardcoded today; cheap retrofit, and the shared
  registry pairs with the palette.
- **Soft wrap is not in the markdown admit budget**, so a wrapped block at the pane bottom can overhang.
- **The grid/CSV view still wastes its last row** — it stayed on the fully-visible row count.
- **~274 unchecked `make` calls on `context.temp_allocator`.** A genuine process OOM becomes a bounds
  trap almost anywhere. One instance of this shipped the v0.31.0 Split-resize crash.

---

## 6. Explicitly ruled out — do not resurface

Recorded so an audit does not raise them again. From HANDOFF §6aa unless noted.

- **Code folding, macros, file compare, print/preview, spellcheck, global-hotkey quick capture** — all
  from research §C, *none ever ruled in*. (They appear in §4 above because they were never ruled **out**
  either; §6aa lists them as out of **V1** specifically.)
- **Full multi-cursor** — V2.
- **LSP, project trees, terminal** — CLAUDE.md scope row: Notepad-first, not an IDE.
- **Glyph-atlas eviction** — **refuted by measurement**, not deferred. At 4096² the atlas holds 61,425
  glyphs at 16px. Do not re-add without a measurement contradicting that.
- **Arenas on VirtualAlloc with grouped lifetimes** — the CLAUDE.md row was amended twice; build an arena
  only when a measurement asks, and amend the row again when you do.
- **Beta expiry / DRM / online checks** — honour-system, per research.
