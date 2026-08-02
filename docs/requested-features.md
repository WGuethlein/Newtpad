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

### A sorted cell re-sorts on commit — DECIDED 2026-08-01, not built

From the v0.36.0 live pass §1: *"The edit works, but it doesn't resort after the change, e.g. I'm
sorting alphabetically, I swap G to F, it doesn't update the sort so that the row is moved up."*
Wyatt's decision, asked and answered in the same session: **the row moves when the edit is committed**
(Enter, or leaving the cell), not live per keystroke, and the view does *not* chase it.

Deliberately held out of v0.38.0, which fixed the rest of that pass. It touches `table_edit_commit`,
the seam §1 of the live pass exists to cover, and the failure mode is a value landing on the wrong
row rather than a cosmetic one — so it gets its own spec, its own subagent and its own review rather
than riding along with four geometry fixes.

What has to be decided before building it: the commit already runs *before* every reorder
(`table_sort_set` and friends each commit first, HANDOFF §6bc), so this is the reverse dependency —
a reorder triggered *by* a commit — and the anchor `table_edit_line_intact` validates against is the
thing being invalidated. Whether the caret survives the move, and to which cell, is the second
question.

### A CSV with no header row is still treated as having one

From the same pass: *"csv's with no header are automatically assumed to have a header... not sure how
we'd differentiate this."* His own note names the hard part correctly — there is no reliable signal,
which is why every spreadsheet ships a toggle for it.

Likely shape: a cheap heuristic on open (does row 1 differ in *type* from the rows under it — all
text over mostly-numeric columns), plus a way to override it, which is the header menu's natural
home. Principle 3 says fight options; this is one of the few that earns its place, because being
wrong silently costs the user a whole row of data hidden in the header band.

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

### Excel-style column filtering — batch 20 (the sort half shipped in v0.36.0)

**Requested 2026-07-31 by Wyatt**, alongside the four table bugs: *"multiple sort of columns, first
column selected to sort takes precedence. would also be nice to filter columns, and have a dropdown
list of all items in the column to filter like powerbi/excel has."* He raised the scope question
himself: *"maybe this is a csv/xslx expansion since it doesn't really match the stated goals so far."*

**The multi-column sort half is DONE (v0.36.0, HANDOFF §6bc)** — two keys, first-selected-wins, via a
header menu, Ctrl+click and the existing plain click. **What is left here is the filtering.** Two
decisions were already taken with Wyatt when the work was split:

- **Past `TABLE_SORT_MAX` (100,000 rows) the distinct-value list refuses**, the same answer the sort
  gives, because it is the only one that cannot become a bounded scan reporting a confident wrong
  answer. A labelled partial list still reads as complete once you are scrolling it.
- **The column filter and `Ctrl+L` are exclusive** — opening one clears the other. `Ctrl+L` already has
  its own render path, scroll model and banner; making a column predicate ride inside it means one row
  set with two owners.

**What the sort half leaves you to build on:** the header menu exists and a `Filter` row is an addition
to it rather than a redesign; `menu_open_ctx` opens the shared dropdown at an arbitrary anchor; and
`table_header_layout` is the one producer of the header's geometry, so a new hit region goes there and
nowhere else.

**That instinct deserves a real answer rather than a reflex, because the mermaid decision just showed
how easy it is to reach for the wrong test.** The question is not "is this spreadsheet-like" — it is
*whether a CSV viewer that cannot answer "which rows say ACTIVE" is finished*. Newtpad already has a
table view with a sort, and §10 committed to it. Filtering is the second question anyone has of a CSV,
and the app already has a **filter-as-you-type over lines** (`Ctrl+L`) — so the capability exists, just
not per-column. That makes this much closer to "finish the table view" than to "become Excel".

Where the caution IS warranted: **a per-column dropdown with a distinct-value list is the first UI in
Newtpad that cannot be viewport-bounded.** Listing every distinct value in a column requires reading
every row — the same wall the sort hit, and the sort's answer (refuse past `TABLE_SORT_MAX`, say so)
is available here too. Decide that before building, not after.

**It also subsumed a shipped defect, and that half is done.** "There is no discoverable way to reset the
sort" is answered by the header menu's labelled `Clear sort` row, built in v0.36.0. The interim
hover-state and summary-row wording were kept anyway — two labelled routes to one command, not two
mechanisms.

Design decisions that would change the build:

- ~~**Multi-sort precedence**~~ — **settled: first-selected-wins**, matching PowerBI and Windows
  Explorer and the opposite of Excel. Shipped that way; array order is precedence, so it is a property
  of the data structure rather than a rule. Do not "fix" it toward Excel.
- ~~**The sort must stay view-only**~~ — **held.** `offs`/`perm`/`rank` never changed meaning and the
  file is still never rewritten.
- ~~**Filter versus the existing line filter**~~ — **settled: exclusive**, see above.
- **`.xlsx` is a separate product decision and is NOT implied by any of this.** It is a ZIP of XML with
  a shared string table, not a text format, and CLAUDE.md scopes Newtpad to text-ish files. If it is
  ever wanted it is its own entry, and reading it does not follow from having a good CSV grid.

### Mermaid diagrams in the markdown preview

**Requested 2026-07-31 by Wyatt**, with the reason attached: *"I will be using spec driven design
heavily on new projects and this is a large piece of interacting with it."* He also asked the right
question himself — built-in, or a V2 plugin?

**Clarified 2026-07-31.** Wyatt: *"I want to use it as a tool to work through spec driven design,
that's why i mentioned v2 plugin/'dlc'."* So the plugin framing was not "defer this" — it was a
**packaging** proposal: mermaid as a separately-shipped add-on rather than core Newtpad.

**DECIDED 2026-07-31: not in the core exe — deferred on COST, not on scope.** The distinction is the
whole point of this paragraph, so it is written out.

Wyatt's first framing was *"it also is more of an ide feature rather than notepad"*, and that was
initially agreed to. **On review that test does not hold, and recording it would have been worse than
recording nothing.** Newtpad already renders markdown — headings, tables, links, proportional text, a
real shaper — and `docs/ui-spec` §9 is titled *"Markdown — the priority"*. Rendering a fenced block the
way every other markdown renderer does is the same category of work as rendering a table, which is
built. LSP and code folding are IDE features because they are about **authoring code**; mermaid in a
preview is about **reading a document correctly**. The "IDE feature" test, applied consistently, would
also have cut the markdown preview, the syntax highlighting and the table view — so it is the wrong
test, and leaving it in the log would have aimed it at the wrong things a year from now.

**The reason that does survive is cost.** A Sugiyama-style layered layout is 1,500–2,500 lines before
any parsing, in a product that is ~11k lines and a 1.24 MB exe. That is a real argument for an add-on,
and it is a *price* argument, which means it can be revisited on price: if the add-on proves the engine
and it lands nearer 800 lines than 2,500, reopening this is a cost conversation and not a
re-litigation of what Newtpad is.

**The consequence, accepted knowingly:** the markdown preview shows raw mermaid source indefinitely.
Given §9 is the stated priority and spec-driven work is the use case, that is a visible hole in the
product's own priority — small, but present every time.

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

### §10 Table view — DONE
All nine rules are built: row numbers, click-to-sort with an accent arrow, numeric/date right-align,
sampled column widths with drag-to-resize and double-click-to-fit, malformed rows marked rather than
hidden, and the summary row (batch 18, HANDOFF §6ax–§6az). **The sort stayed view-only throughout — the
file is never rewritten.** v0.36.0 added a second sort key on top of it (§6bc). This list was stale from
2026-07-30 and is kept as a heading so a reader looking for §10 finds the answer rather than nothing.

### §8 Editor surface
- **Caret blink** — 500ms, stopping while typing and for 500ms after. *No blink implementation exists.*
- **Gutter** — 44px right-aligned + 12px gap, off by default, current line `text_primary`.
- **Current-line tint** — off by default, 3% when on.
- **Wrap indent** — a wrapped line continues at the original indent + 2 columns.
- **Wrap column cap** — cap the text column at 100 characters in wrap mode. §8: *"On a maximised 1440p
  window an uncapped wrap gives 200-character lines."*

### §9 Markdown

**Paragraph joining is DONE (v0.37.0, HANDOFF §6bd)** — consecutive prose lines join and re-flow, hard
breaks survive, lazy continuation works for list items and blockquotes, and setext headings render. It
is noted here because §9.2 asks for it and a reader checking this list should find the answer rather
than nothing. Two things it left behind, both new:

- **A blockquote written with `>` on every line renders as N stacked blocks with a segmented bar** —
  13px gaps between 26px segments, measured. Pre-existing, but v0.37.0 made it *inconsistent*: the
  lazily-continued form (`> a` then unmarked lines) now renders as one clean bar, so the way nearly
  everyone writes a blockquote looks worse than the unusual way. The fix is joining a run of *marked*
  quote lines — the same `md_join_run` machinery, a different predicate. **Small and self-contained.**
- **Split scroll sync over a long hard-wrapped paragraph is per BLOCK**, so the preview pins to the
  paragraph's top rather than tracking the editor's line. This is `ui-spec` §9.4 (*"scroll sync by
  block, not by line"*) being honoured for the first time — the finer old behaviour was an artefact of
  every source line accidentally being its own block — so it is **not a regression against spec**.
  Sub-block sync is achievable and two of three pieces exist: `Md_Anchor` already carries a
  within-block pixel offset, and `lay.sh.line_boxes` already gives per-visual-line geometry. Missing is
  a map from a source byte to an offset in `e.joined`. **The hard half is the inverse** —
  `md_anchor_top_byte` must invert it exactly, and `md_scroll_scalar`'s own comment calls that property
  hard-won. Scope any task here around the inverse, not the forward map.

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
- **Mermaid in the core exe** — **deferred on cost, and deliberately NOT filed as ruled out.** The
  first framing was "it is an IDE feature"; that test was withdrawn on review because it would equally
  have cut the markdown preview and the table view (see §1). What stands is the price: a layout engine
  is 1,500–2,500 lines in an 11k-line product. It is listed here only so an audit does not read it as
  unscheduled core work — **it is live as an add-on**, and it is the plugin system's best motivating
  example.
