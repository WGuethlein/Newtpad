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

### Newtpad as Explorer's text preview handler — asked for 2026-08-02, DEFERRED TO V2+

**DECIDED 2026-08-02 by Wyatt: *"drop … Explorer preview for v2+"*, the same day he asked for it**, and
with his own framing on the request: *"it's just a thought doesn't need to be now."* Kept here in full
rather than cut down, because the packaging question below is the thing to answer before anyone
schedules it, and it does not get easier by being rediscovered later.

Wyatt: *"i want to be able to use newtpad as the text previewer in explorer"* — i.e. select a `.txt`,
`.log`, `.json`, `.csv` in Explorer and have **Newtpad render the Preview Pane**, rather than the
built-in handler (which is Notepad-grade and refuses most extensions outright).

**Recorded, not scoped.** Everything below is from reading, not from having built one, and the API
details want checking against Microsoft's docs before anyone plans work off them.

**What Explorer actually requires is an `IPreviewHandler` COM server, and that is the whole problem.**
It is registered per extension under the preview-handler shell-extension CLSID
(`{8895b1c6-b41f-4c1c-a562-0d564250836f}` — verify), instantiated by Explorer, and hosted **inside
`prevhost.exe`**, a surrogate process. Consequences, in the order they bite:

- **It must be a DLL, not our exe.** Newtpad is one standalone executable, and CLAUDE.md's scope row
  makes that a product property ("size reflects absence of complexity. No install required"). A
  preview handler means a **second shipped artifact** and a **registration step**, which is the first
  thing in this product that genuinely cannot work without an installer. That is the decision to take
  first, and it is Wyatt's: is the Explorer integration worth ending "no install required"?
- **Our renderer would be running in someone else's process, in a window we do not own.** The handler
  is handed a parent `HWND` and a rect and must draw inside it, resize with it, and honour
  `IPreviewHandlerVisuals` for background and font. D3D11 + DXGI flip-model in a host-supplied child
  window inside a restricted surrogate is plausible but unproven here, and `prevhost.exe` runs at
  reduced integrity — worth checking early whether device creation even succeeds there.
- **A preview handler is not an editor.** It is read-only by contract: no caret, no typing, no menus.
  So this is not "run Newtpad in a pane" — it is a **new front end over the existing viewer** (piece
  tree, lexer, table view, markdown preview), which is the honest way to scope it and also the reason
  it is not absurd: the read-only half of Newtpad is most of what makes the preview worth having.
- **It must never lock the file.** CLAUDE.md's hard rule already says so, and it matters more here:
  Explorer previews whatever the user clicks, and a handler holding a handle blocks renames and
  deletes from the very window the user is standing in. `IInitializeWithFile` vs
  `IInitializeWithStream` is a real decision — the stream form is what Microsoft recommends and it
  interacts with our mmap path.

**What it buys, and why it is a good fit despite the above:** the built-in preview refuses most of the
extensions Newtpad exists to open, and this is the one integration that puts the product in front of
the user without them launching it. It is also the natural companion to a **thumbnail handler**
(`IThumbnailProvider`), a separate interface with the same packaging problem — decide them together or
the DLL gets built twice.

**Not blocked on anything technical; blocked on the packaging decision.** Do not start it as a
"small feature".

### Format minified JavaScript — asked for 2026-08-02, deliberately NOT built

Wyatt, after JSON/CSS/XML shipped: *"add js for later future request"*. Recorded here rather than
attempted, and the reason is not effort — it is that **the technique the other three use cannot be
made safe for JavaScript.**

JSON, CSS and XML are token re-emitters with no parser, and they are ~200 lines each **because
whitespace is never significant in JSON or CSS, and in XML the one place it is can be detected
locally**. None of that holds here:

- **Automatic Semicolon Insertion.** Where a newline may go depends on where a statement ends, and
  that cannot be known without parsing. `return\n  x` returns `undefined`. A formatter that guesses
  wrong does not produce ugly output — it produces *different code*.
- **`/` is ambiguous.** `/foo/g` is a regex literal; `a / b` is division. Telling them apart needs
  parse context, not lexer context. Guess wrong and everything to the next `/` is swallowed as a
  regex.
- **Template literals** nest arbitrary expressions inside `${}`, recursively, each of which can
  contain more template literals.

So a JS formatter is a real parser plus a printer — Prettier is on the order of 100k lines — and a
partial one is **worse than none**, because this command edits the buffer and the failure mode is
silently changing what the code does rather than refusing.

**This is the plugin system's motivating example.** §6aa held first-party reformat as the V2 plugin
proof and JSON was taken out of that in v0.44.0; JS is a better proof anyway, because it is the case
where the work genuinely does not belong in a 11k-line notepad. If it is ever built first-party it
needs its own spec, a real parser, and a differential test that reformats and re-parses to prove the
AST is unchanged — nothing less is honest for a command that rewrites source.

**HTML is DONE (v0.57.0, HANDOFF §6bx)** — and the caveat this paragraph flagged turned out to be the
whole of the work. `xml_format`'s structure-only rule was *not* sufficient on its own: it already
protects mixed content, but `<div><span>a</span><span>b</span></div>` is element-only content, so it
would lay the div out and the inserted newline renders as a space. `html_format` adds one rule — lay
an element out only when every element directly inside it is block-level — and the inline table is
the "hardcoded list of text-ish element names" `xml_format`'s header rejects, which is not a reversal:
that rejection is about XML, where the significant-whitespace elements cannot be enumerated. HTML is
the one vocabulary where they can.

### Mermaid diagrams in the markdown preview

**DECIDED 2026-08-02 by Wyatt: *"drop mermaid … for v2+"*.** This closes the timing question that had
been open since 2026-07-31 — the choice was "wait for V2" versus "build it in-tree behind the future
plugin boundary now", and **he chose to wait.** So the in-tree option is off the table, mermaid is the
plugin system's motivating example, and the consequence accepted on 2026-07-31 stands and lengthens:
**the markdown preview shows raw mermaid source until V2.** The three sub-decisions below (static vs
live vs click-to-jump) are still unanswered and are still day-one decisions whenever it starts —
particularly the third, which needs source byte offsets carried through every node and is painful to
retrofit.

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

## 2. Owed to the UI spec

Everything below is a `docs/ui-spec/` obligation, **not** something Wyatt asked for — the distinction
this heading exists to restore. It was missing until 2026-08-04, so sections ran 1, 3, 4, 5, 6 and
these hundred-odd lines read as though they sat under "asked for directly".

**Wyatt, 2026-08-04: the UI "still hasn't matched the ui spec given by Claude design, especially in
menus — this needs to be reworked before a V1 release."** That settles a contradiction the two
documents had been carrying: CLAUDE.md ranked the UI overhaul and the `renderer`/`ui` extraction
priority 2, while HANDOFF §6aa had moved them to V2 as V2's first item. **CLAUDE.md's ranking is the
live one. The UI rework is a V1 gate, not a V2 opener.**

Menus specifically carry both a spec gap and defects — see the 2026-08-04 audit
([06-ui-shell.md](audits/2026-08-04/06-ui-shell.md)): context menus and the column-filter dropdown
swap themselves for the File menu on any arrow key and ignore `Enter`, and `menu_draw_dropdown` still
resolves scroll inside the draw (HANDOFF §5), a violation whose shape cost three consecutive
releases. **Fix the defects as part of the rework, not before it** — the one-layout rule is what the
rework is for, and patching the draw again would be a fourth iteration of the same mistake.

### §10 Table view — DONE
All nine rules are built: row numbers, click-to-sort with an accent arrow, numeric/date right-align,
sampled column widths with drag-to-resize and double-click-to-fit, malformed rows marked rather than
hidden, and the summary row (batch 18, HANDOFF §6ax–§6az). **The sort stayed view-only throughout — the
file is never rewritten.** v0.36.0 added a second sort key on top of it (§6bc). This list was stale from
2026-07-30 and is kept as a heading so a reader looking for §10 finds the answer rather than nothing.

### §8 Editor surface
**Caret blink and the current-line tint are DONE (v0.42.0, HANDOFF §6bi)** — the blink is the app's
only timer, gated off for a caret-less view and an inactive window, on by default with a setting; the
tint is Text_Primary at 3%, the caret's visual row, off by default.
**The gutter and the wrap column cap are DONE (v0.57.0, HANDOFF §6bx).**
- ~~**Wrap indent**~~ **DONE (v0.63.0, HANDOFF §6cc)** — a wrapped line continues at its original
  indent + 2 columns. The §8 section is now complete.
- ~~**`caret_blink` and `current_line` have no UI at all**~~ **DONE (v0.61.0, HANDOFF §6ca)** — both
  now have settings rows, so the gap opened in v0.42.0 is closed.

### §9 Markdown

**Paragraph joining is DONE (v0.37.0, HANDOFF §6bd)** — consecutive prose lines join and re-flow, hard
breaks survive, lazy continuation works for list items and blockquotes, and setext headings render. It
is noted here because §9.2 asks for it and a reader checking this list should find the answer rather
than nothing. Two things it left behind, both new:

- **A blockquote written with `>` on every line renders as N stacked blocks with a segmented bar** —
  13px gaps between 26px segments, measured. Pre-existing, but v0.37.0 made it *inconsistent*: the
  lazily-continued form (`> a` then unmarked lines) now renders as one clean bar, so the way nearly
  everyone writes a blockquote looks worse than the unusual way. The fix is joining a run of *marked*
  quote lines. **It is NOT the small predicate change this entry used to claim** — investigated
  2026-08-01 and corrected (HANDOFF §6bi). Both scans in `md_para_bounds` continue a run on
  `md_is_run_line`, which is `.Para` only, so accepting a `>` line makes the predicate depend on the
  run's KIND — while that procedure's whole contract is that its answer is **entry-independent**, which
  `md_block_start_at`'s snap and the layout memo both rest on. It must also compose with lazy
  continuation, since `> a` / `b` / `> c` is one quote in CommonMark. **Needs its own spec and a
  fixture set that asserts entry-independence from several bytes of one run.**
- **Split scroll sync over a long hard-wrapped paragraph is per BLOCK**, so the preview pins to the
  paragraph's top rather than tracking the editor's line. This is `ui-spec` §9.4 (*"scroll sync by
  block, not by line"*) being honoured for the first time — the finer old behaviour was an artefact of
  every source line accidentally being its own block — so it is **not a regression against spec**.
  Sub-block sync is achievable and two of three pieces exist: `Md_Anchor` already carries a
  within-block pixel offset, and `lay.sh.line_boxes` already gives per-visual-line geometry. Missing is
  a map from a source byte to an offset in `e.joined`. **The hard half is the inverse** —
  `md_anchor_top_byte` must invert it exactly, and `md_scroll_scalar`'s own comment calls that property
  hard-won. Scope any task here around the inverse, not the forward map.

- **Marks dimmed in the editor pane — DONE (v0.60.0, HANDOFF §6bz).** `#`, `**`/`__` and `*`/`_` now
  emit their own `.Punct` tokens, so they draw in `Syn_Punct` while the text they mark keeps its
  colour. This is what §9.2 rows 1–2 ask the EDITOR for. Inline-code backticks and `~~strikethrough~~`
  are deliberately not included — §9.2 names marks only for those two rows.
- **Concealment** — hide `#`/`**` on non-caret lines, Obsidian-style. **NOT in the UI spec**, which was
  discovered while scoping it (§6bz): §9.2's "marks hidden" is the **preview** column, and the editor
  column says "marks *dimmed*", which is the item above. So this is an **extra-spec feature**, not owed
  work — recorded because Wyatt asked for it, not because §9 does.
  It remains expensive for the original reason: it makes the drawn column stop matching the byte
  column, so caret placement, selection rects, find highlights, link underlines, click hit-testing,
  h-scroll extent, wrap width and Home/End all have to learn about hidden runs — and a line's geometry
  becomes caret-dependent, which nothing in the editor currently is. **Needs its own spec enumerating
  those seam decisions before any code**, and is worth re-deciding now that the dimming has shipped.
- **Autolinks and reference links** — only `[a](b)` works.
- **h6 tracking** (§9.3) — caps shipped in v0.42.0; the shaper has no letter-spacing parameter, so
  tracking is still owed and needs one threaded through `shape_spans`.
- ~~**A *Preview font* setting** (§9.3)~~ **DONE (v0.61.0, HANDOFF §6ca)** — cycles every installed
  BODY_FAMILIES face, then the editor's own family last, per §9.3's "for people who want the preview
  to match the source".
- **The caption/meta row** (§9.3, 0.88 S) — computed and unread.
- ~~**Zebra rows in the preview table**~~ **DONE (v0.64.0, HANDOFF §6cd)** — alternate data rows carry
  a `Table_Zebra` band, header and separator never. Parity is counted from the table's own start, so
  the stripe does not flip as the table scrolls.
- ~~**Preview selection and copy** (§9.4)~~ **DONE (v0.62.0, HANDOFF §6cb)** — drag to select, Ctrl+A,
  Ctrl+C. Copy yields the rendered text in Obsidian's plain-text shape: bullets kept, table cells
  tab-separated, links as their label.
  **Owed follow-ups, both named rather than discovered later:** Obsidian also puts a RICH-TEXT flavour
  on the clipboard (`CF_HTML`), which is why pasting into Word keeps bold and headings — that is a
  second clipboard format and a second serializer, not built. And **double-click-to-select-a-word is
  not offered**, because the second press of a cluster is already Split's click-to-sync-scroll gesture
  (§6ao); one input cannot mean two things, and the gesture shipped first.
- **The heading tick-mark rail** (§9.4) — an 8px mini-map of `md_heading` ticks.
- **Lists do not nest visually** beyond their indent — no per-level bullet cycling.
- **A screen *above* the viewport** is laid out only on the scroll-up gesture, not per pass (§9.1).

### §14 Huge files
- **Progress hairline and the sparse index** — two-thirds built.

### §15 The empty tab
**The three hints are DONE (v0.57.0, HANDOFF §6bx)**, in Text_Muted rather than §15's `text_dim` —
`themetest` forbids Text_Dim outside a disabled control, and these are instructions meant to be read.
Worth Wyatt's ruling if he wants them dimmer.
- **The 2px accent inset drop ring is NOT built, and it is not a small job.** Newtpad uses
  `DragAcceptFiles` + `WM_DROPFILES`, which delivers the drop and gives **no drag-over notification at
  all**, so there is no event to draw a ring from. It needs OLE `IDropTarget` — `OleInitialize`,
  `RegisterDragDrop`, and a hand-rolled COM vtable in the platform layer — and it changes how dropped
  files arrive. Its own batch, deliberately deferred 2026-08-02.

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
- **Mermaid, as the first plugin** — Wyatt's decision 2026-08-02; see §1 for the cost argument, the
  three sub-decisions still open, and what the ABI has to carry that "formatters + viewers" does not.
- **An Explorer preview handler (`IPreviewHandler`), and a thumbnail handler with it** — Wyatt's
  decision 2026-08-02; see §1. Blocked on a product question, not a technical one: it needs a DLL and
  a registration step, which is the first thing here that cannot work without an installer.
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
| **Macros / record-replay** | overlaps regex find/replace | Medium |
| **Print / print preview** | requested; arguably outside "fast viewer" | Medium |

**Code folding, file compare/diff and spellcheck were cut from this table 2026-08-04** — see §6.
The three that remain are the ones the "second window" wedge argues *for* rather than against.

### The open plugin question — what a plugin IS (2026-08-04)

**Plugins are staying. What they are is not settled**, and the two readings differ enough that they
are separate products.

Wyatt, 2026-08-04: *"i still want plugins, i think being able to customize everything should be a
feature, i don't want to limit people, i also think this leads to a healthier community... maybe this
is the wrong way forward since we aren't going to make the source code public."*

**The closed-source worry is unfounded and should not drive this.** Closed source and a healthy plugin
ecosystem are orthogonal: **Obsidian** is the near-exact analogue — closed source, commercial, a
notes/text tool, one of the largest plugin communities in software. **Sublime Text** (closed, Package
Control) and **IDA Pro** are the same story. A community needs a stable documented extension point and
a way to share, not the ability to read the renderer.

**The real conflict is with the locked decision, not with licensing.** CLAUDE.md locks plugins as a
*"narrow C-ABI (formatters + viewers), worker threads, timeouts, **never generic scripting**"*.
"Customize everything" and "don't limit people" describe a scripting runtime, which is the clause that
row rules out. **Choosing the broad reading is an amendment to a locked decision and should be
recorded as one**, not arrived at by drift.

What the audit established, and what still stands whichever way this goes: **the ABI has lost both its
motivating examples.** Formatters shipped first-party (JSON/CSS/XML/HTML, v0.44.0–v0.57.0), and of the
two named viewer cases, the archive tree is now cut (§6) and mermaid is deferred on cost — and E2's own
note says the ABI *"is scoped on the unexamined assumption that a viewer returns text or a bitmap;
mermaid needs far more."* So the one surviving example does not fit the interface designed for it.
**Whatever is built needs a use case chosen before the interface**, or it will be an interface with
nothing behind it.

Three costs that are specific to this product rather than to plugins generally:

1. **Native DLLs end the single-exe story** — the same objection that ruled out the Explorer preview
   handler in §6. A plugin folder is an install.
2. **AV reputation.** v0.33.0 already drew a `Trojan:Win32/Wacatac.B!ml` false positive (VirusTotal
   1/40, sole ML dissenter). An unsigned binary that loads arbitrary native code from a user directory
   is materially worse for heuristics — while 2–8 weeks of SmartScreen reputation is being built.
3. **Crash attribution.** Every plugin fault arrives as a Newtpad minidump with Newtpad breadcrumbs and
   a prefilled Newtpad issue, and gets triaged as one.

**The cheap middle, stated so it is a real option rather than a strawman:** Newtpad already ships an
unusually deep declarative surface — `theme.theme`, `keys.txt` and `rules.txt` are live-reloading text
files that apply on save with no restart. Extending *that* (user-defined lexers, user-defined commands)
buys much of "customize everything" with no code-execution boundary, no DLL and no AV surface.
**It does genuinely limit people**, which is the thing Wyatt said he did not want, so it is a trade and
not a free win.

*Research §E explicitly marks go-to-line syntax and drag-drop as **not** demanded.*

Also never decided, from HANDOFF §6:
- **Complex-script shaping** (Arabic/Indic/bidi via `IDWriteTextAnalyzer`). **Wyatt asked for this
  2026-08-02 — "it should be able to handle any language" — and then deferred it the same day: "spec
  this tomorrow, skip it for now."** So it is SPEC-FIRST, not scheduled work, and the spec has to
  answer an architectural question before a line is written.

  **What already works, verified 2026-08-02 (`emojitest`), because the old text here was wrong:**
  Latin/Greek/Cyrillic, **CJK** (`text_cell_width_at` gives full-width glyphs 2 cells and combining
  marks 0 — the terminal model), and **basic monochrome emoji**, which resolve through
  `seguisym.ttf`, rasterize with ink, occupy 2 cells, and round-trip cell↔byte so the caret lands past
  the surrogate pair. This entry used to claim "the caret/hit-test/selection/find rects assume a
  monospace column, so they misalign on CJK and emoji". **They do not.** The draw advances by
  `cells * cell_w` (`text_walk_glyphs`) using the same `text_cell_width_at` the caret, the selection
  and the hit-test read — one origin, no second arithmetic to disagree with.

  **What genuinely cannot work, and why it is architectural:** Arabic/Persian/Urdu need contextual
  forms and lam-alef ligatures; Hebrew and Arabic need **RTL**; Devanagari and friends **reorder**
  matras before their consonant. None of that is expressible on a fixed cell grid, and the grid is a
  LOCKED decision (CLAUDE.md: it exists so caret arithmetic, column selection and hit-testing are
  O(1); `ui-spec` §9.1: *"the editor pane keeps the grid untouched"*). Bidi also makes a logically
  contiguous selection **visually discontiguous**, needs bidi-aware arrow keys, and makes column/block
  editing meaningless inside an RTL run.

  **The preview is the cheap half and is not blocked:** it already has a real proportional shaper with
  fractional advances and no grid, and `shape.odin`'s own header names `IDWriteTextAnalyzer` as the
  missing piece. Shaping there touches no locked decision.

  **Colour emoji stay ruled out** — Wyatt, 2026-08-02: "don't put color emoji only the basic ones
  supported". Monochrome outlines only; no COLR/CPAL layer compositing.
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

### Cut 2026-08-04 by Wyatt, after the market research

Five items, cut in one pass once the research put a buyer behind the scope rule. The wedge it argues
for is the **"second window"** — the sysadmin or support engineer who already has an IDE open and
needs somewhere else for logs, CSVs and configs. That gives a sharper test than "is this an IDE
feature": *would they use Newtpad for this, or Alt-Tab to the IDE that is already open?*

- **Container / archive tree viewer (JAR/ZIP/tar/.docx → tree of entries).** Was E8, parked in
  HANDOFF §6. Two reasons: it introduces Newtpad's **first side panel**, against Principle #2
  ("content owns the screen"), and browsing archives is **File Pilot's job** — the product Newtpad is
  modelled on. Duplicating the file manager sitting next to it is not scope, it is competition with
  your own other tool.
- **Embedding Monaspace Neon + Argon.** Was ui-spec §2.5/§20 step 3. It needs hand-written
  `IDWriteFontFileLoader`/`IDWriteFontFileStream` vtables **and a rewrite of
  `THIRD-PARTY-NOTICES.txt`'s "bundles and redistributes no third-party components" claim** — and the
  research finds that self-contained/handmade story is *the entire distribution ticket* (gHacks led
  with "a mere 1.8 MB" on File Pilot). L-sized work that weakens the best press hook. The curated
  installed-font list already satisfies Principle #4.
- **Code folding, file compare/diff, spellcheck.** The IDE half of §4's "never decided either way",
  now decided. Diff is a separate paid product category (Beyond Compare, WinMerge); folding is an IDE
  affordance; spellcheck serves a prose writer, not this buyer. **Macros/record-replay and
  global-hotkey quick capture stay in §4** — repetitive text-munging over logs is squarely the wedge,
  and the "second window" *is* a scratchpad.
- **Theme contrast warnings** (six pairs, status bar, dismissible, once per save). Was ui-spec §17.
  A theme-*authoring* tool for a product whose theme authors number roughly one. Options fighting,
  per Principle #3. `Follow Windows` and high contrast are **not** cut with it — those are user
  choices, not authoring aids.
- **Explorer preview handler (`IPreviewHandler`) + thumbnail handler.** Was E4, deferred to V2+ on
  2026-08-02. **Promoted from deferred to ruled out**, because the blocker is a principle rather than
  a schedule: it needs a DLL and a registration step, which is the first thing in the queue that
  cannot work without an installer — ending "no install required" (Principle #5), a line that is in
  the marketing copy. Reopening it means accepting that Newtpad becomes a thing you install.

**Plugins were NOT cut** — see §4's new plugin entry. The audit's argument for cutting them was that
formatters shipped first-party and the two named viewer use cases (mermaid, the archive tree) were
both going away, leaving the ABI with no motivating example. Wyatt's answer, 2026-08-04:
*"i still want plugins, i think being able to customize everything should be a feature, i don't want
to limit people, i also think this leads to a healthier community."*

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
