# Requested and owed features

One of three lists: **bugs** live in [reported-bugs.md](reported-bugs.md), **what already works** in
[features.md](features.md), and everything owed or asked for lives here.
Same rule as the bug list: **when an item ships, delete it from here and record it in the HANDOFF entry
instead** (and add it to `features.md`). This is a queue, not a history.

Compiled 2026-07-30 by sweeping HANDOFF §5/§6 and every `### Owed` section, `docs/ui-spec/`,
`docs/2026-07-25-forgotten-feature-audit.md`, `docs/live-pass-*.md`, and the project memory. Where an
item was **decided** one way or another, that is recorded — several things on this list were ruled out
once and would be a reopening, not a new idea.

---

## 1. Asked for directly, unscheduled

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

### Mermaid diagrams in the markdown preview

**Requested 2026-07-31 by Wyatt**, with the reason attached: *"I will be using spec driven design
heavily on new projects and this is a large piece of interacting with it."* He also asked the right
question himself — built-in, or a V2 plugin?

**Clarified 2026-07-31.** Wyatt: *"I want to use it as a tool to work through spec driven design,
that's why i mentioned v2 plugin/'dlc'."* So the plugin framing was not "defer this" — it was a
**packaging** proposal: mermaid as a separately-shipped add-on rather than core Newtpad.

**DECIDED, same day, by Wyatt: this is not core Newtpad.** His words: *"it also is more of an ide
feature rather than notepad."* That is the scope row's own test — CLAUDE.md rules out LSP, project
trees and terminals on the grounds that Newtpad is a notepad and not an IDE, and **a graph layout
engine is the same category of thing.** It is also the largest feature ever proposed here: more code
than the product currently is. So it ships as an add-on or it does not ship, and principle 5 (*"small
standalone exe — size reflects absence of complexity"*) is protected structurally rather than by
willpower.

**Do not re-propose this as a core feature.** If a later audit finds mermaid in this file and reads it
as unscheduled work, the answer is that it was ruled out of core on 2026-07-31 and the reason has not
changed.

**What remains open is only WHEN and against what boundary.** The two words in the original request
are separate decisions with different deadlines:

- **"DLC" is a packaging decision and can be made late.** Selling it separately needs a build flag, a
  licence tier, or a second binary — none of which require the C-ABI to exist. Do not let a pricing
  question dictate the architecture.
- **"Plugin" is an architecture decision**, and with mermaid ruled out of core it is the natural home:
  a separate binary, separately licensed, loaded on demand, is exactly what an out-of-scope-for-core
  feature that someone still wants should be. **This becomes the plugin system's motivating example**,
  which is a better one than the JSON formatter because it is genuinely too big for core rather than
  merely convenient to externalise.

**The remaining tension is timing, and it is worth naming rather than discovering later.** Plugins are
V2, and the stated need — spec work on new projects — is now. Two honest options, and this is Wyatt's
call whenever he wants it:

- **Wait for V2.** Cleanest. Mermaid becomes the first plugin, the ABI is designed for it, nothing
  provisional ever ships. Costs him the tool for the whole interim.
- **Build it in-tree behind the future plugin boundary, gated out of the shipped exe.** Same interface
  the C-ABI will expose — in: the fenced block's text, theme, DPI; out: a quad list, glyph runs, hit
  regions — so it never reaches into Newtpad's internals and becomes a recompile rather than a rewrite
  when plugins land. Gets him the tool sooner at the cost of carrying an unshipped module.

Either way, **design the boundary before the engine.** The plugin row scopes the ABI to *"formatters +
viewers"* on the unexamined assumption that a viewer returns text or a bitmap; a diagram that scrolls
with the preview, scales with DPI, themes with the palette and supports selection needs far more than
that. That assumption should be corrected by a real client, not discovered during V2.

**The question to settle before this is specced, because it is a day-one decision:** *"work through"*
implies more than rendering. Three separable products, in increasing cost:

1. **Static render in the preview.** The baseline.
2. **Live preview as you type** — cheap once layout exists, given the existing per-block cache, but it
   sets a latency budget that constrains the layout engine's design.
3. **Click a node to jump to the section that describes it.** Genuinely excellent for spec-driven work
   and the thing that would make this a *tool* rather than a viewer — but it requires the parser and
   layout engine to **carry source byte offsets through to every node**. That is trivial if designed in
   and painful to retrofit, so it must be decided before the first line, not after.

**Why not "full mermaid".** Mermaid is not one format, it is ~15 (flowchart, sequence, class, state,
ER, gantt, pie, journey, gitgraph, mindmap, timeline, quadrant, C4, sankey, requirement), each with
its own grammar *and its own layout algorithm*. `mermaid.js` is larger than all of Newtpad. Newtpad is
~11k lines of Odin total; committing to the whole spec is committing to more code than the product.
**Name the subset and ship it, rather than shipping 40% of everything.**

**The subset that matches the stated use.** Spec-driven design is overwhelmingly two diagram types:

- **`flowchart` / `graph`** — boxes, edges, labels, subgraphs.
- **`sequenceDiagram`** — participants, messages, activations, notes.

Those two also happen to be the two with well-understood published layout algorithms. `stateDiagram`
falls out of the flowchart engine nearly free (same layered layout, different node shapes). `classDiagram`
and `erDiagram` are a later, separate decision.

**The hard part is layout, not drawing.** This is the thing to be clear-eyed about before scheduling
it: drawing is quads and glyphs, which this codebase already has from batch 17's preview shaper. The
work is a **layered (Sugiyama/dagre-style) graph layout** — rank assignment, crossing minimisation,
coordinate assignment, then edge routing — and that is on the order of 1,500–2,500 lines by itself,
independent of any parsing. A naive layout produces diagrams so ugly they are worse than the fenced
source, so this cannot be half-done and still be worth having. **Budget it as several batches, not
one.**

**What already exists to build on:** batch 17's preview shaper (proportional text, real fonts), the
glyph atlas, `quads.odin`, and the markdown block model that already isolates fenced blocks. A
mermaid block is *bounded* — one fence — so a whole-block layout does not violate the viewport-first
rule the way a whole-document pass would. A file with fifty diagrams does need **lazy per-visible-block
layout with a cache**, which is the same shape the preview already uses.

**Two things it needs that do not exist yet:**

- **A real scissor rect** (already listed in §5 as owed). Clipping is currently a cover strip painted
  after the content, and a diagram pane that scrolls needs genuine clipping.
- **Line/curve primitives.** Everything today is axis-aligned quads. Edges need diagonal strokes and
  either bezier flattening or orthogonal routing. Decide which before starting — orthogonal routing is
  much less code and arguably reads better for spec diagrams.

**Open question worth settling early:** does a diagram render *in the preview only*, or also inline in
the editor (Obsidian-style)? The preview-only answer is far cheaper and consistent with how every
other markdown view here works; the inline answer collides with §9's concealment work, which is
already flagged as needing its own batch because it makes the drawn column stop matching the byte
column.

### Right-click a tab to open the folder the file is in

**Requested 2026-07-31 by a user, relayed by Wyatt:** *"if you could right click the tabs to open the
folder it's located in."* Documented, not scheduled.

**The action already exists; the surface does not.** `plat.explorer_select_arg` is built and in use —
`link_follow` reveals a non-text path in Explorer through it (`links.odin`), including the escaping
care that path needs. So this is not "implement reveal-in-Explorer", it is "give the tab strip a
right-click".

**There is no tab context menu at all.** `grep` over `ui_tabs.odin`, `menu.odin` and `app.odin` finds
no right-click handling on the strip, so this is a new surface rather than a new row in an existing
menu — and that is the part worth scoping deliberately, because a tab context menu invites every
other per-tab command (close others, close to the right, copy path, pin) and CLAUDE.md principle 3
says fight options. Decide the menu's full contents once, when it is built, rather than growing it a
row at a time.

Related and already listed in §4: *directories opening as a tab* listing contents rather than
revealing in Explorer. If that is ever built, this request's answer changes — "open the folder" would
mean a Newtpad tab, not an Explorer window. Worth settling the direction before building either.

### Tell the user where the themes folder is

**Requested 2026-07-31 by a user, relayed by Wyatt:** *"i want to create a new .theme file but not
sure where the themes folder is on my machine."*

**The likely cause is more specific than "it is undiscoverable": for that user the folder probably
does not exist.** `themes_dir()` (`theme.odin:525`) returns `%APPDATA%\Newtpad\themes`, but
`theme.odin:511-524` records a deliberate decision not to create it at startup — a bare read of
`settings.txt` was `mkdir`-ing a `themes/` folder for every user who had never touched a theme, so
creation moved to `themes_dir_ensure` at the point of actual use. Correct decision, with the
side effect that a user looking for the folder finds nothing there and cannot tell whether they have
the wrong path or the right one.

So the fix is not documentation. Candidates, cheapest first:

- **An `Open Themes Folder` command** in the palette that calls `themes_dir_ensure` and reveals it.
  Creates the folder as a side effect of asking for it, which is exactly when it should exist.
- **A line in Settings** next to the theme picker showing the resolved path, clickable. Settings is
  where someone changing themes already is.
- Both. They are the same two lines of work behind one shared `themes_dir_ensure` call.

Note this generalises: `keys.txt` and `rules.txt` live under the same `%APPDATA%\Newtpad` root and
have the same discovery problem. Whatever answer is chosen should cover all three rather than
being built once for themes.

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
- **A Defender false-positive submission to Microsoft** — Wyatt's to file, it needs his account:
  <https://www.microsoft.com/en-us/wdsi/filesubmission>, as "Software developer".

  **Evidence, 2026-07-31.** A GitHub download of v0.33.0 failed in the browser with
  *"Failed - Virus detected"*, and VirusTotal on that exact binary returned **1 detection out of
  ~40**: Microsoft `Trojan:Win32/Wacatac.B!ml`. The `!ml` suffix is Microsoft's own marker for a
  machine-learning verdict rather than a signature match, and every other ML engine on the panel —
  **SentinelOne (Static ML), CrowdStrike Falcon**, Palo Alto, Symantec, Fortinet, McAfee,
  Malwarebytes — returned Undetected. Real malware is what the other ML engines agree on first;
  being the sole ML dissenter is the signature of a false positive, and `Wacatac.B!ml` is the
  specific bucket Defender uses for unsigned, low-prevalence, freshly-built executables.

  Verified locally at the same time: nothing is vendored (every binary in `build/` is produced by
  `build.bat` from our own sources), and `update.odin` does one HTTPS GET for a version string with
  no `CreateProcess`, no `ShellExecute` of a downloaded file and no `MoveFileEx` self-replacement —
  so Newtpad cannot download and run anything, which is the behaviour a dropper heuristic looks for.

  **One of the two reputation signals is already gone:** the exe had *no version resource at all*
  until 2026-07-31 (empty `FileVersion`, `CompanyName`, `ProductName`, `FileDescription`), now fixed.
  Signing removes the other. The submission is what clears it for existing Defender installs in the
  meantime, and it clears it for everyone, not just the reporter.

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
- **Mermaid diagrams in core Newtpad** — ruled out of the core product 2026-07-31 by Wyatt (*"it also
  is more of an ide feature rather than notepad"*), on the same test CLAUDE.md's scope row applies to
  LSP, project trees and terminals. **Not ruled out as an add-on** — it is the plugin system's best
  motivating example. The full entry, including the subset worth building and the source-offset
  decision that must be made on day one, is in §1 above.
