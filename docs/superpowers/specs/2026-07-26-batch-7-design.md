# Batch 7 — hard rules and stale beliefs (design)

Batch 7 of the sequence in HANDOFF §6aa. Wyatt asked for the road to V1 and answered four forks
(§6aa "The four forks, as answered"); this batch is the first one down that road, and it is
executed overnight with Wyatt asleep, under the merge policy he chose: **branches merge to `main`,
`install.ps1` is NOT run.** His daily driver stays v0.16.0 until he has done a live pass.

## The batch changed shape before it was written, and that is the headline

§6aa listed five items. **Two of them were not real**, and finding that out cost twenty minutes of
measurement against the alternative of a night spent building the wrong thing.

### Glyph-atlas eviction is not a ship blocker — dropped from the batch

The audit (`docs/2026-07-25-forgotten-feature-audit.md`) ranks this Tier 2 with the sharpest failure
description on its whole list: *"the only item whose failure mode is 'your text silently vanishes.'"*
HANDOFF §5 and CLAUDE.md's roadmap item 6 carry it too. All three trace to one stale comment at
`platform/text.odin:12`: *"Atlas is grow-only for now; eviction is required before ship (project
rule)."*

That comment predates §6j's fix. Measured on this machine, 2026-07-26:

```
px 16  box 12x20  1024 fits 3744  4096 fits 61425  holds a heavy page  OK
px 48  box 30x54  1024 fits 594   4096 fits 9768   holds a heavy page  OK
px 96  box 56x104 1024 fits 153   4096 fits 2769   recycles (expected at this size)  OK
--- atlas growth under a heavy glyph load ---
  start dim: 1024 -> after 40 frames: 4096   atlas grew: true   atlas_full latched: false
```

Grow-to-4096 plus wholesale recycle at the cap already exists and works. At 16 px the atlas holds
**61,425** distinct glyphs; at 48 px (300 % DPI) **9,768**. One screen of text is a few thousand
characters and far fewer *distinct* glyphs, so `atlas_full` is not reachable by any real document —
`atlasgrowtest` confirms it never latches. Above 96 px the atlas recycles instead, which is a
re-rasterization cost, not a loss.

**Decision: do not build LRU/generational eviction.** There is no measured failure to fix, the shelf
packer cannot free an individual rectangle without being replaced wholesale, and the viewport-first
rule already bounds what must come back. What ships instead is a documentation correction (task 5)
carrying the numbers above, so the belief does not regenerate a third time.

*This is the third instance of a stale comment outliving the fix it described (§6j's atlas commit
message, §6i's "not yet built" for two shipped features, §5's `WaitMessage` entry). The pattern is
not carelessness about comments — it is that **a claim of absence is never re-tested**, while a
claim of presence gets exercised every build.*

### Tabs are already four cells wide, not one

The audit says tabs *"render as one cell — indented code and `.tsv` display wrong."* False since
whenever `TAB_CELLS :: 4` landed (`platform/text.odin:497`); the file carries **both** comments,
the stale one directly above the live one.

The real gap is narrower and still worth fixing: tabs are a **fixed four cells**, not true tab
stops. `\tab` at column 2 lands at column 6, where every editor and every terminal puts it at
column 4. So a `.tsv` whose fields differ in length still misaligns, which is precisely the case
tab stops exist for. Wyatt chose **advance to the next multiple of N, configurable, default 4**.

## Task 1+2 — true tab stops

**The whole difficulty is that a tab's width depends on where it starts.** `text_cell_width` is a
per-rune call with no column parameter, which is exactly why `TAB_CELLS` is a constant — the
existing comment says so. Making tabs real means every measurement API becomes column-aware, and
that is a Shape-B change (CLAUDE.md: *a correct, tested function fed the wrong input, or its result
read in the wrong space*) across ~20 call sites.

**Design: an explicit starting column, defaulted to 0.** `text_cells`, `text_bytes_for_cells`,
`text_span_cells` and the draw take a `col0` — the absolute cell column the slice begins at. A
caller measuring from a line start passes 0 and behaves exactly as today. A caller measuring a
*substring* must pass its real origin, and the ones that must are enumerated in the plan, not left
to judgment:

- `links.odin:491,522` — span cells within a row
- `block.odin:1290,1350` — the column-edit rectangle, where a wrong origin edits bytes the user
  never highlighted (§6z shipped exactly that bug via a different route)
- `table.odin:38,143,226,250` and `markdown.odin:366,515,699` — fields and cells inside a laid-out
  grid, where the tab-stop origin is arguably the field, not the line. **Open question the plan must
  answer, not the implementer at the keyboard.**
- `doc.odin:297,349,2102,2111,2681` — the row measure/hit-test pair, which must agree or the caret
  drifts

**Word wrap is the sharp edge.** A wrapped visual row starts mid-line, so its tabs must align to the
*logical* line's stops — tab stops are a property of the text, not of the window width. The wrapped
row therefore needs the cell count of everything before it on its logical line. If the wrap code
does not already carry that, this task grows; the plan must check before the implementer starts.
Wrap measurement itself also has to become tab-aware or lines wrap in the wrong place.

**Split into two commits so the tree is correct at each:**

- **Task 1** adds `col0` everywhere, defaulted to 0, with `TAB_CELLS` still fixed. Pure
  refactor — behaviour is bit-identical and the existing suites must pass unchanged. That is the
  point: it isolates the mechanical sweep from the behaviour change, so a bisect lands on the
  real one.
- **Task 2** flips tabs to `next multiple of tab_width`, adds the Settings row (default 4), and
  fixes every origin the plan enumerated.

**Sabotage requirement:** a test that fails when a tab's origin is wrong. Measuring `a\tb` from
column 0 and from column 1 must give *different* answers; a test that only ever measures from a
line start cannot fail and is the vacuous shape §6z shipped twice.

## Task 3 — `\\?\` long paths

CLAUDE.md states it as a hard rule; there is not one occurrence in the tree, so any path over
~260 characters fails to open. Deep `node_modules`, a synced OneDrive tree, nested build output.

**Not a blanket prefix.** `\\?\` disables path normalization, which makes the naive version worse
than the bug:

- It is **absolute-only**. A relative path with the prefix is invalid, so the helper must resolve
  first (`GetFullPathNameW`) and refuse otherwise.
- It does **not** normalize `/`, `.` or `..`. Forward slashes must be converted; a path containing
  `..` must be canonicalized *before* the prefix goes on, never after.
- UNC takes a different form: `\\server\share` becomes `\\?\UNC\server\share`, not
  `\\?\\\server\share`.
- **Several APIs reject it.** `ShellExecuteW` (links, Open Logs Folder, the Explorer helpers at
  `file.odin:510-557`), the comdlg32 dialogs, and anything handing a path to another process must
  keep the plain form. Prefixing those is a regression, not a fix.

So: one `wide_path()` helper in `platform`, applied at the file-I/O call sites
(`CreateFileW`, `GetFileAttributesExW`, `GetFileAttributesW`, `DeleteFileW`, `MoveFileExW`) and
deliberately **not** at the shell/dialog ones. The plan lists which call sites get it and which are
excluded *with the reason on each line*, because "we missed one" and "we deliberately left one" are
indistinguishable in a diff six months later.

**Testable without a 300-character path:** the prefixing decision is a pure string function. Test
that directly — relative refused, `/` converted, UNC special-cased, already-prefixed left alone,
plain-form preserved for the shell sites. Then one real round-trip through a genuinely long path
under the temp dir as the end-to-end check.

## Task 4 — the CSS and SQL comment markers

§6w disclosed both deliberately: `.css` and `.sql` fold into the C-family grammar, which knows only
`//` and `/* */`. So a stylesheet's `url(https://...)` colours the rest of the line as a comment,
and a SQL `-- SELECT the right index` colours `SELECT` as a keyword *inside* a comment. §6w called
the SQL one sharper and it is right: SQL comments routinely contain SQL words.

`Keyword_Set` is already data-not-branching (`lex_c.odin:82`), so this is one more field —
`line_comment: string`, `"//"` for the C family, `"--"` for SQL, `""` for CSS, which has no line
comment at all. The matcher consults the field instead of hardcoding `'/'`+`'/'`.

**The risk this task carries is Shape A** — §6w paid for this lesson twice, in `lex_xml` and in
`lex_c_resync_valid`: *a stateful lexer must keep scanning for state past its token-buffer cap even
once it stops emitting.* A new line-comment marker is a new way to stop emitting early. The test
must include a small-`out` case, and the reviewer must be told this specifically.

Keyword tables get the other §6w lesson too: assert a *specific* real word (the Go table shipped
without `func` because every fixture reached its words through `type_intro`).

## Task 5 — the findings batch 6 carried, and the documentation correction

From HANDOFF §5's "carried from batch 6" list, plus this batch's own findings.

1. **The reopen size cap fails open.** It reads `doc.disk_stamp.size`, which is absent on a failed
   stat (reads as 0) and stale on a restored dirty tab. A file that grew to 500 MB while Newtpad was
   closed reports its old size and transcodes synchronously on the UI thread. Fix: stat at the
   moment of the reopen. The cap's whole purpose is refusing a multi-second freeze, and a guard that
   fails open on exactly the unusual cases is not one.
2. **`File ▸ Save` and `Edit ▸ Paste` are live on the Settings and Font pseudo-tabs.** Pre-existing,
   row-by-row rather than one predicate because `Tab_Close` shares `has_doc` and must stay live.
3. **Paste rewrites a lone CR as a line break** (inherited from `convert_line_endings`). Real in a
   CSV field or terminal output pasted into an LF document.
4. **No test exercises any menu `checked` predicate's semantics** — not the encoding ones, not
   `is_wrapped`/`is_table`. `menutest` covers structure and mnemonics only.
5. **`session_restore` carries no comment** saying why it deliberately never calls
   `app_apply_view_defaults`; the reasoning lives only in `app.odin`.
6. **Documentation correction**, carrying the evidence above: the atlas measurements into HANDOFF §5
   and the audit; the two stale comments in `text.odin` (lines 12 and 491-492) deleted; the audit's
   Tier-1/Tier-2 marked shipped where it is.
7. **Amend CLAUDE.md's memory row** — Wyatt's decision, §6aa fork 3. The row describes VirtualAlloc
   arenas with grouped lifetimes; zero exist and none are planned. Rewrite it to describe the heap +
   `free_all(context.temp_allocator)` reality, keeping the rationale (no measured allocation
   problem; the per-document arena was refuted on its own merits in §6b). **CLAUDE.md is Wyatt's
   constitution — this is the one file where an edit needs his decision behind it, and it has one.**

## Out of scope, deliberately

- **LRU / generational atlas eviction** — no measured failure; see above.
- **Elastic tab stops** — Wyatt chose fixed stops. Elastic would make a tab's width depend on other
  lines, breaking the fixed-cell-grid assumption the renderer, caret and column-edit rectangle all
  rest on.
- **Per-language block-comment markers** — only the *line* comment differs for CSS and SQL. Teaching
  the shared matcher a second block form is a change to reviewed matching logic with no reported
  symptom behind it.
- **Batch 8's contents** (build time, `.cso` shaders, text batching) — a separate branch, if the
  night allows.

## How this batch is verified

Per `docs/development-loop.md`: a fresh implementer per task, a reviewer after every task told the
specific risks that task carries, one fix subagent per review round, a whole-branch review at the
end, and every test sabotage-verified with the failure output recorded in the report.

The risks to name to reviewers, by task: **1-2** wrong-origin Shape B and the wrap interaction;
**3** the excluded-API list and `..` canonicalization order; **4** Shape A past the token cap;
**5** whether each fix's test can actually fail.

**Nothing in this batch can be verified against real GUI input** — this environment cannot inject
any. Every claim about clicking is inference from source plus a headless assertion, and the tab-stop
change is the most visual thing in the batch. Wyatt's live pass is owed and will be listed in the
HANDOFF entry.
