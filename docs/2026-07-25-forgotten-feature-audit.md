# Feature audit — 2026-07-25

Two passes. The **first** swept for work that was started and left unfinished (TODOs, deferred
comments, stale debt entries). Wyatt correctly pointed out that this structurally cannot find
features that were **decided in the docs and never begun** — which is most of what is actually
missing. The **second pass** reads the markdown corpus as a source of commitments and checks each
against the code.

Verified against `0d9dac3` (v0.11.0). The second pass is the important one.

---

# PASS 2 — decided in the docs, never built

## The big one: there is no syntax highlighting. At all.

`grep -rni 'lex_|tokenize|syntax_' src/` returns **zero**. Every occurrence of "highlight" in the
tree means a find-match rectangle or a selection rectangle. `doc_draw` sets one foreground colour
(`fg := {0.86, 0.90, 0.96, 1}`) and draws every byte of every file in it.

This is not a small omission:

- **CLAUDE.md states it as a hard engineering rule:** *"Viewport-first: lex/highlight/measure visible
  lines + margin; background threads fill the rest."* The viewport-first machinery exists and is
  excellent. The thing it was built to serve does not.
- **`research/demand-side-feature-research.md` assumes it throughout** — §B5 contrasts "we plan
  syntax *lexers* (highlight json/csv/xml)" against users wanting *reformat*, and resolves the
  argument in favour of keeping lexers in V1 and holding reformat for V2 plugins. The V1 half was
  never built either.
- **Newtpad explicitly courts json/env/md/csv/log/xml/yaml/toml users** (CLAUDE.md's opening line).
  Those are precisely the file types where flat monochrome text is most obviously wrong.
- Independent check: syntax highlighting is the first feature named in essentially every
  "Notepad replacement" roundup — see Sources.

I missed this in pass 1 because nothing in the code says "TODO: syntax highlighting." Nobody leaves
a TODO for a feature they never started.

## V1 decision #1 was never built: column/block editing

`research/demand-side-feature-research.md` §B1 calls multi-cursor/column editing **"the consensus #1
gap," flagged by 4 of 6 independent research lenses** — narrative, Reddit, competitor and
incumbent-wishlist all independently. §G records the decision made with you on 2026-07-18:

> **Column/block editing in V1; full multi-cursor in V2.** Ship the rectangular-edit workflow (strip
> log timestamps, prefix many lines) now.

`grep -c 'Column\|Block' src/program/commands.odin` → **1**, and that one is `VISIBLE_COLS`. Not
started. HANDOFF §6 still lists it under "beyond V1 core," which contradicts §G of the research.

The cited workflows — strip a timestamp column out of a log, prefix many lines at once — are exactly
the large-file/log audience Newtpad is aimed at.

## Themes — a stated product principle, 103 hardcoded colours

CLAUDE.md principle 4: *"Personalization only at the edges — **fonts, theme, hotkeys, animations**.
Core design is ours."* Fonts shipped (there is a whole font page). The other three did not.

`grep -rni theme src/` → **zero**. There are **103** literal `{r, g, b, a}` colour constants scattered
across `src/program/`. Every one is a place a theme would have to reach, and the number grows every
batch — this session added several.

Worth saying plainly: this gets more expensive every week it waits, and it is the one item on this
list whose cost is actively compounding.

## Rebindable hotkeys — designed for, not delivered

CLAUDE.md: *"Rebindable keys are a runtime user-keymap overlay, not codegen."* `commands.odin:4`:
*"separated from the metadata so keys are rebindable later (a user overlay)."*

The separation was done — `Binding` and `Command` are distinct types and the table is data. The
overlay that would consume it does not exist. This is the cheapest item here, because the hard part
(the data-declared command table) is already built and there is an `#assert` keeping it honest.

Research §C also lists **chord/multi-key hotkeys** as low-cost and a natural fit for that same table.

## An actual installer, and signing

CLAUDE.md principle 5: *"Small standalone exe — ... No install required; **optional embedded
installer**."* What exists is `install.ps1` — a developer script that builds, copies to
`%LOCALAPPDATA%`, and writes HKCU registry keys. It is not something you hand to a buyer: it requires
a PowerShell execution policy that permits it, and it cannot be signed as an installer.

HANDOFF's own priority list puts **signing, updater, crash reporting** as priority 3 ("ship
readiness"). Crash reporting shipped in 0.9.0. Signing and the updater did not, and neither did the
embedded installer. For a product positioned as a **paid, one-time-purchase commercial download**
(research §F), an unsigned exe delivered by a `.ps1` is the gap between "works" and "sellable" —
SmartScreen will flag every download.

## Plugins — correctly deferred, but note the V1 dependency

Plugins are post-V1 by locked decision (narrow C-ABI, formatters + viewers, worker threads,
timeouts). Nothing to fix. One thing to notice: research §G item 4 held **JSON/XML pretty-print and
CSV column view** as "the first-party proof of the plugin boundary" — so the plugin API's first
justification is a feature set that also doesn't exist yet. The table view (Ctrl+T) shipped and is
part of that story; the reformatters are not.

---

## Never decided either way — research §C's secondary list

These were surfaced by the 2026-07-18 research, never ruled in or out. Roughly by value-per-cost for
this product's stated audience:

| Feature | Why it matters here | Cost |
|---|---|---|
| **Sort lines / remove duplicates** | log + data crowd, high frequency | Cheap |
| **Keyword→colour rules** | *"disproportionately loved by log users"*; a poor man's highlighting that needs no lexer | Cheap given the renderer |
| **Scrollbar match/occurrence marks** | pairs with the filter-as-you-type that already shipped | Cheap |
| **Bookmarks (incl. numbered)** | navigation in big files | Cheap |
| **Global hotkey / always-on-top quick capture** | *"a whole product category"*, fits the scratchpad positioning | Medium |
| **Code folding** | expected in the "power notepad" tier | Medium |
| **Macros / record-replay** | overlaps regex F/R | Medium |
| **File compare / diff** | 4 of 5 competitors have it; #1 Notepad++ plugin | Stretches scope |
| **Print / print preview** | requested; arguably outside "fast viewer" | Medium |
| **Spellcheck** | table-stakes creep for prose; conflicts with "fight options" | Medium |

Research §E explicitly marks **go-to-line syntax and drag-drop as *not* demanded** — worth knowing,
since drag-drop is what we just spent a task on. It was your ask, so it was the right call, but the
research says don't over-invest there.

---

## Two corrections to what I told you earlier

**Logging is real, and I was wrong to leave the impression it wasn't.** `diag_init` (`diag.odin:41`)
installs a file sink and writes to:

```
%APPDATA%\Newtpad\logs\newtpad.log
```

Level Info in release, Debug in debug builds, plus a `crashes\` directory beside it with minidumps.
It is on by default and always has been since 0.9.0. What is missing is **discoverability** — there
is no menu item, no command, and no mention in the UI, so there is no way to know it exists. A
"Open Logs Folder" command in the palette would cost minutes.

**`--version` exists** (`main.odin:45`), contrary to what I said earlier. It prints nothing from the
installed binary because release builds with `-subsystem:windows` and detach from the console. The
flag is real; the output has nowhere to go.

---

# PASS 1 — started and left unfinished

## Ship-blockers written down as ship-blockers

**Glyph atlas has no eviction.** `platform/text.odin:12`: *"Atlas is grow-only for now; eviction is
required before ship (project rule)."* The status bar already carries a `[GLYPH CACHE FULL - some
text may not draw]` warning, because when it fills, glyphs draw as nothing while the pen still
advances — text silently vanishes. Grow-at-frame-boundary relief exists; eviction and a second page
do not.

**`\\?\` long paths — zero occurrences in the tree.** CLAUDE.md states it as a hard rule. Any path
over ~260 characters fails to open: a deep `node_modules`, a synced OneDrive tree, a nested build
output.

**`test_modes.odin` ships in the release binary** — 4,218 of 13,708 lines, 31% of the tree, and
`package main`. Release is 1.10 MB against a 2–3 MB target so it isn't urgent, but it is the cheapest
large win and it grows every session.

**Shaders compile at startup from embedded HLSL** (`quads.odin:6`). Worth downgrading from how
HANDOFF frames it: I checked, and `d3dcompiler_47.dll` is present in `System32` on Windows 10+, so
this is startup cost and tidiness, not a will-it-run risk.

## HANDOFF §5's debt register is partly stale — three items are done

A register listing finished work makes the live items harder to see.

- *"no `WaitMessage` anywhere"* — false; `window_wait_message` exists (`window.odin:28`,
  `MsgWaitForMultipleObjectsEx`) and `main.odin:166` blocks on it.
- *"Dead line-index anchors"* — gone from `doc.odin`.
- *"7 headless test-modes clutter `main.odin`"* — they live in `test_modes.odin` now.

Still accurate: VirtualAlloc arenas (zero implementation — `base/base.odin:5` is a comment; the only
`VirtualAlloc` in the tree is a deliberate guard page in `seh.odin:49`), and the un-batched text
pipeline.

## Follow-ups promised in comments

| Where | Promise | User-visible? |
|---|---|---|
| `platform/text.odin:492` | *"tabs are one cell for now (tab stops are a later feature)"* | **Yes** — indented code and `.tsv` display wrong |
| `program/find.odin:6` | regex group substitution (`$1`) is a follow-up | Yes, for regex replace |
| `program/session.odin:33` | serialize blocks the main thread while dirty | Only on very large dirty buffers |
| `platform/text.odin:455` | complex-script shaping (Arabic/Indic/ligatures) | Yes for those scripts; locked deferral |
| `program/doc.odin:21` | *"Real horizontal scroll is a later feature"* | **Stale** — h-scroll works; what's true is `VISIBLE_COLS :: 2048` caps its reach |

## Found during this session's two batches

- **`session.txt` does not persist `md_mode`/`table`** — only `wrap`. A tab left in Split comes back
  plain. This is the other half of the "views don't save state" complaint.
- **`doc_reload` loses the view too** — preserves `wrap`, not `md_mode`/`table`.
- **Paste writes clipboard bytes verbatim** — the Windows clipboard is CRLF, so pasting into an LF
  file reproduces the exact mixing that justified fixing Enter this batch.
- **`on_resize`/`on_dpi` disable crash reporting** — both call `runtime.default_context()` and never
  restore `assertion_failure_proc`. Two-line fix; they run on every resize.
- **Six test modes wrote real user state** — fixed this batch (they refuse without
  `NEWTPAD_SESSION_DIR`), noted because it went unnoticed for a long time.

## Small gaps

- **Encoding conversion is palette-only.** `Save as UTF-8 / UTF-16 LE / Windows-1252` are declared and
  dispatched (`commands.odin:757-761`) but appear in no menu. Same for the line-ending commands.
- **Six mutually-exclusive drag flags in `main.odin`**, each excluded from the others by hand-written
  `&& !x` clauses; this batch added two more. The concrete way `ui` extraction is getting harder.

---

# If you want an order

**Tier 1 — the product is incomplete without these**

1. **Syntax highlighting.** The single largest gap, a stated hard rule, and the thing the
   viewport-first architecture was built to serve. Start with the formats already courted:
   json, xml, md, csv, ini/toml/yaml, log.
2. **Column/block editing.** V1 decision #1, validated by 4 of 6 research lenses, aimed squarely at
   the log audience.
3. **Session persists the view** (`md_mode`/`table`). Finishes a complaint you already made; small
   format addition with an existing version-tolerant reader.

**Tier 2 — ship-readiness**

4. **Signing + a real installer.** For a paid download, an unsigned `.ps1` is the gap between works
   and sellable. SmartScreen flags every unsigned download.
5. **Glyph atlas eviction.** The only item whose failure mode is "your text silently vanishes."
6. **Gate `test_modes.odin` behind a build flag.** Mechanical; stops the growth.

**Tier 3 — cheap wins with outsized effect**

7. **Themes**, before the colour-literal count grows further.
8. **Rebindable keys** — the hard half is already built.
9. **Tab stops**, **sort/dedupe lines**, **keyword→colour rules**, **bookmarks**, **scrollbar match
   marks** — all individually small, all named by the research.
10. **"Open Logs Folder" command** — logging exists and nobody can find it.
11. **`on_resize`/`on_dpi` crash-reporter fix** — two lines, silently undermines the 0.9.0 crash suite.

**Bookkeeping:** delete the three stale entries from HANDOFF §5, and reconcile §6's "beyond V1 core"
list with research §G, which pulled column/block editing *into* V1.

---

## Sources

Local, and better than anything on the open web for this product:
`research/demand-side-feature-research.md` (six parallel research lenses, cross-lens convergence
weighting, 2026-07-18), `research/newtpad-research-report.md`, `CLAUDE.md`, `HANDOFF.md`.

Independent confirmation that syntax highlighting and column-edit mode lead the feature expectations
for this category:

- [The 10 Best Notepad Replacements for Windows](https://www.online-tech-tips.com/notepad-replacement/)
- [12 Best Notepad++ Alternatives Picked for 2026](https://thectoclub.com/tools/best-notepad-alternative/)
- [10 Best Notepad Alternatives With Better Features (2026)](https://www.techbloat.com/10-best-notepad-alternatives-with-better-features-2026.html)
