# Audit 04 — rich views: markdown preview, table view, links, block select, formatters

Scope read in full: `src/program/markdown.odin` (5815), `src/program/table.odin` (4913),
`src/program/links.odin` (1046), `src/program/block.odin` (1371), `src/base/json_format.odin`,
`xml_format.odin`, `css_format.odin`, `html_format.odin` and their tests
(`css_format_test.odin`, `test_modes.odin` `mdseltest` / html-format / css-through-the-command
sections). UI spec §9 (Markdown) and §10 (Table view) read before judging any layout decision.
HANDOFF.md, `docs/requested-features.md` and `docs/reported-bugs.md` grepped for every finding
below; where an item is already recorded I say so and say whether it is worse than recorded.

**Nothing was edited. No build was run.** Everything marked CONFIRMED is traced end to end in
the source; none of it was executed, because the environment cannot run the GUI and I was asked
not to build.

12 findings: 2 CRITICAL, 4 HIGH, 3 MEDIUM, 3 LOW.

---

### [CRITICAL] `css_format` silently rewrites a stylesheet that contains an unquoted `url(...)`, and the damage cascades past the URL
**Where:** `src/base/css_format.odin:212` (`':'` case), `:206` (`';'` case), `:145` (`//` branch), header claim at `:13`
**Confidence:** CONFIRMED
**Fix risk:** RISKY (a new lexical state; changes what the formatter emits)
**Mechanism:** The header says *"WHAT IT NEVER TOUCHES: the bytes inside a string, a comment, or a
`url(...)`"*. There is **no `url(` handling anywhere in the file** — an unquoted URL is walked
byte by byte through the ordinary token cases:
- `':'` (`:212`) appends `": "` whenever `paren > 0`, so `url(http:` becomes `url(http: `.
- `';'` (`:206`) has **no `paren` guard at all** — it emits `;` + a newline even inside parens.
- `'/'` (`:145`) takes the SCSS line-comment branch on `//`, swallowing the rest of the physical
  line — including the closing `)` — as comment text. `paren` is therefore never decremented and
  stays `> 0` for the **remainder of the file**, which turns every later `:` into a declaration
  colon.

**Failure scenario:** `styles.css`
```css
.btn {
  background: url(http://cdn.example.com/a.png);
}
.btn:hover { color: red }
```
Format Document (`commands.odin:1644`) produces, silently, with `[FORMATTED]`:
```css
.btn {
  background: url(http: //cdn.example.com/a.png);
}

.btn: hover {
  color: red
}
```
The URL is broken **and** `.btn:hover` has become `.btn: hover`, a selector that matches nothing.
Second scenario, no `//` needed: `a{background:url(data:image/png;base64,iVBORw0K...)}` comes back
as `url(data: image/png;` + newline + `base64, iVBORw0K...)` — the data URI is destroyed by the
space, the injected newline and the injected comma-space. A third shape refuses outright rather
than corrupting (`.btn { background: url(http://x/a.png); }` all on one line ends `.Truncated`,
because the `}` is eaten as comment text) — which is the *lucky* case.
Not recorded. HANDOFF §6 records the **lexer's** `//`-in-`url()` colouring gap (HANDOFF:2095, 2212)
and the `url(https://x/a/*/b)` block-comment gap (HANDOFF:2830) — both about *colour*, both
explicitly "bounded to that one line, self-correcting". This is the same character sequence in the
**formatter**, where the output replaces the user's file and the damage is not bounded to the line.
`css_format_test.odin:49` is the only `url()` test and it uses `url(a b.png)` — no `:`, no `;`, no
`//` — so nothing in the suite reaches this.
**Fix:** add a `url(` case beside the `'"'` case: on seeing `url(` (case-insensitive) at token
position, copy verbatim to the matching `)` (respecting a quoted argument), `pad` once before it,
and do not touch `paren`. Add `test_css_format_preserves_content` rows for `url(http://x)`,
`url(data:a/b;base64,Zg==)` and a multi-line file that proves `a:hover` survives after one.

---

### [CRITICAL] A live **filter with no sort** leaves `table_sort_shift` disabled, so one cell edit desynchronises every row offset below it
**Where:** `src/program/table.odin:2430-2432` (`if s.nkeys == 0 || len(s.offs) == 0 {return}`), fed from `src/program/doc.odin:2668`
**Confidence:** CONFIRMED
**Fix risk:** SAFE (widen one predicate)
**Mechanism:** `table_filter_open` (`table.odin:1554-1568`) rebuilds `doc.table_sort.offs` for the
whole file *whether or not a sort exists* — its own comment says so ("a filter needs the row index
whether or not a sort exists"). It never touches `nkeys`. `table_sort_shift`, the hook on the one
buffer-write primitive, gates on `s.nkeys == 0` and returns immediately. So with `active = true`
and `nkeys = 0`, `offs` is **never repaired across an edit**, while `table_indexed()`
(`table.odin:1481`) still routes `table_row_start` through it.
**Failure scenario:** open `people.csv` (unsorted), `Ctrl+T`, right-click a header → Filter, untick
a value. Now click a cell in an early visible row and change `OK` to `OKAY` (+2 bytes) and press
Enter. `table_edit_commit` → `doc_replace_range` → `table_sort_shift` → early return. Every
`offs[j]` for a row below the edit now points **2 bytes before** its true line start, i.e. inside
the previous line's tail. `table_row_start` → `table_sort_row_at` → `offs[j]`, and
`pt_line_end_cap` from there stops at the *previous* line's newline: the grid draws near-empty
1–2 byte rows for the rest of the screen. Click one of those rows and commit an edit and
`table_field_at` computes `fs/fe` from the stale offset, so the splice lands two bytes off the
true field — writing over a delimiter and the tail of the neighbouring field.
`table_edit_line_intact` cannot catch it: the snapshot is taken at the *same* stale offset, so it
compares equal.
Not recorded. HANDOFF:6316 records a *different* filter/`offs` lifetime bug ("the filter outlived
its own index" — invalidation sites), and HANDOFF:1038 lists "edit text while filtered" as a
harder open problem for the **find filter**, not the grid.
**Fix:** change the guard to `if (s.nkeys == 0 && !table_filtered(doc)) || len(s.offs) == 0 {return}`.
The newline-drop branch (`:2434`, `:2436`) then also protects a filter-only view, which it
currently does not. Add a `tablegridtest` case: filter without sorting, edit a cell to a
longer value, assert `table_row_start(doc, r)` for a row below the edit is still a real line start
(`byte_at(p-1) == '\n'`).

---

### [HIGH] Preview selection hit-test ignores the block's indent — clicking a list item, a blockquote or a fenced code line selects the wrong characters
**Where:** `src/program/markdown.odin:4826` (`gx := cx + g.x`) inside `md_block_pos_at:4800`; the draw uses `md_block_origin(lay, cx)` at `:5509` and `:4710`
**Confidence:** CONFIRMED
**Fix risk:** SAFE (one-line, and it is exactly the producer the file already has)
**Mechanism:** This is the one-layout rule broken in its textbook form. Three consumers read the
block's glyph origin through `md_block_origin(lay, cx) == cx + lay.indent`: the draw
(`md_block_draw:5509`), the selection band (`md_draw_selection:4710`) and the link rects
(`md_block_links:5475`). `md_block_pos_at` — the pixel→`Md_Pos` hit-test, the fourth consumer —
computes `gx := cx + g.x`, **dropping `lay.indent`**. `indent` is non-zero for exactly the kinds
that build it: `.List` (`:3459/3466/3468`, ≥ `sx(24)` even at depth 0), `.Quote` (`:3448`,
`level * sx(16)`) and `.Fence_Body` (`:3433`, `sx(12)`). `.Para`, `.Heading` and `.Table` have
`indent == 0`, which is why prose feels correct and hid this.
**Failure scenario:** preview `notes.md` containing `- alpha bravo charlie`. At 100% DPI a
top-level bullet's prose is drawn at `cx + 24px`. Press the mouse exactly on the `a` of `alpha`
(client x = `cx + 24`). `md_block_pos_at` walks glyphs testing `mx >= cx + g.x`, so it accepts every
glyph up to `g.x <= 24` — roughly the third character in Georgia at 16px. Drag right to the end of
`alpha` and the highlight (drawn at the *correct* origin) covers `pha b`, and Ctrl+C copies
`pha b` rather than `alpha`. The error is a constant 24px (one level of list indent), 16px per
blockquote level, 12px in a fenced block, and it scales with DPI because `indent` is `sx()`-baked.
`mdseltest` (`test_modes.odin:37404`) never catches it: every positional assertion in it constructs
`Md_Pos` values by hand and never drives `md_preview_pos_at` / `md_block_pos_at` from a pixel.
Not in HANDOFF, `reported-bugs.md` or `requested-features.md` (the §9.4 selection entry at
`requested-features.md:295` is marked DONE with two named follow-ups, neither of which is this).
**Fix:** `gx := md_block_origin(lay, cx) + g.x`, and hoist `x := md_block_origin(lay, cx)` to the
top of the proc so nothing in it can re-derive an origin. Then add the missing seam test: for a
document with a list, a quote and a fenced block, sweep `md_preview_pos_at` across the *drawn* x of
each block's first glyph (taken from `lay.sh.glyphs[0].x + md_block_origin(...)`) and assert the
returned `Md_Pos.off == 0`. Verify it by reintroducing `cx + g.x` and watching it fail.

---

### [HIGH] `html_format` refuses essentially every real HTML document — void elements are parsed as unclosed
**Where:** `src/base/html_format.odin:119` → `src/base/xml_format.odin:154` (`xml_elem_extent`), `xml_format.odin:98` (`self` detection)
**Confidence:** CONFIRMED
**Fix risk:** RISKY (needs a second element table and a matching rule in the extent scan)
**Mechanism:** `html_format` is `xml_format_impl(..., html = true)`. The tokeniser only calls a tag
self-closing when the byte before `>` is `/` (`xml_format.odin:98`). HTML's **void elements** —
`meta`, `link`, `br`, `hr`, `img`, `input`, `source`, `col`, `area`, `base`, `embed`, `param`,
`track`, `wbr` — are legally written without the slash, so each is tokenised as `.Open`.
`xml_elem_extent` then hunts for a matching `</meta>` that does not exist, finds the enclosing
`</head>` instead, and returns `.Unbalanced`. There is **no void-element table anywhere in the
tree** (`grep` for `void` in `src/base` returns nothing).
**Failure scenario:** any ordinary page:
```html
<!DOCTYPE html><html><head><meta charset="utf-8"><title>x</title></head><body><p>hi</p></body></html>
```
Format Document on `page.html` prints `[NOT VALID HTML -- mismatched closing tag]` and puts the
caret on the `<meta`. The same file with `<meta charset="utf-8"/>` formats fine. Every fixture in
the `html_format` suite (`test_modes.odin:4326-4388`) is XML-well-formed — `<img src="a"/>`,
`<div>`, `<UL><LI>x</LI></UL>` — so the suite is green while the feature does not work on the
files it was built for.
HANDOFF §6bx (HANDOFF:6986) and `requested-features.md:97` record the *inline-whitespace* caveat as
"the whole job"; the void-element problem is not mentioned anywhere. **This is worse than
recorded — the feature is documented as DONE (v0.57.0).**
**Fix:** add `HTML_VOID` beside `HTML_INLINE` in `html_format.odin`; in `xml_token`, when the
`html` flag is on and the name is void, return `.Self`. That needs the `html` flag threaded into
`xml_token` (it currently only reaches `xml_elem_extent`). Test with a real minified page
containing `<meta>`, `<br>` and `<img src=x>` and assert the result reparses to the same tag
sequence.

---

### [HIGH] Copying a preview table emits a TAB per SPAN, not per COLUMN — any formatting or empty cell shifts the paste into the wrong spreadsheet columns
**Where:** `src/program/markdown.odin:4680` (`if lay.cls.kind == .Table && ... {write '\t'}`) in `md_sel_block_text:4651`; spans built at `:3499-3540`
**Confidence:** CONFIRMED
**Fix risk:** SAFE-to-moderate (needs the per-column span boundaries persisted on `Md_Layout`)
**Mechanism:** `md_layout_build`'s `.Table` case drafts **one span per inline run per cell** — a
cell containing `a **b** c` produces three spans — and records the per-column boundaries only in a
temp `tcol_end` (`:3498`, `:3539`) that is thrown away. `md_sel_block_text` then walks
`lay.shape` and writes `\t` after every span but the last, so span boundaries become column
boundaries. Separately, an **empty cell** drafts *no* span at all (`:3513` skips zero-length runs,
and `md_inline("")` returns nothing), so it contributes neither text nor a tab.
**Failure scenario:** preview this table and Ctrl+A, Ctrl+C:
```markdown
| Name | Note | Qty |
| --- | --- | --- |
| Bolt | **M4** hex |  |
| Nut  |            | 12 |
```
Row 1 copies as `Bolt\tM4\t hex` — three tab fields from a two-cell row, and the empty `Qty` cell
is gone. Row 2 copies as `Nut\t12` — the empty `Note` cell vanishes and `12` lands under *Note* in
the spreadsheet. Pasting into Excel produces a table whose columns do not line up with its header,
which is precisely the outcome the tab was added to buy (`markdown.odin:4677-4682`,
`requested-features.md:295`).
`mdseltest` (`test_modes.odin:37458`) asserts only `strings.contains(got, "\t")` on a fixture whose
cells are single plain words (`| a | b |`, `| 1 | 2 |`), so it cannot see either half.
**Fix:** persist `tcol_end` on `Md_Layout` (a `tcol_span_end: []int` beside `tcols`, freed in
`md_layout_free`), and have `md_sel_block_text` emit a `\t` when `i + 1` crosses a recorded column
boundary — and emit an empty field for a column whose boundary equals the previous one. Test with
the fixture above and assert the field count per row equals `len(lay.tcols)`.

---

### [HIGH] Markdown tables split on escaped pipes — `\|` inside a cell creates a phantom column
**Where:** `src/program/markdown.odin:664` (`md_split_cells`, `strings.split(s, "|")`), consumed by `md_table_measure:1397` and `md_layout_build:3505`
**Confidence:** CONFIRMED
**Fix risk:** SAFE (a hand-rolled split that honours `\|`)
**Mechanism:** GFM's one table-specific escape is `\|`, which means a literal pipe inside a cell.
`md_split_cells` splits on every `|` unconditionally and only then hands each part to `md_inline`,
which un-escapes what is left. So the escape is honoured *after* the cell boundaries have already
been decided from it.
**Failure scenario:**
```markdown
| Expression | Meaning |
| --- | --- |
| a \| b | logical or |
```
The header and separator rows produce 2 cells; the data row produces **3** (`a \`, `b`,
`logical or`). The block's `ncols` becomes 3 (`md_table_measure:1398` takes the max), so a phantom
third column is fitted and every subsequent row's `Meaning` value is drawn under the wrong heading,
with `a \` rendered as literal text in column 1. Not recorded anywhere; §9.2 item 6 lists
"tables + alignment" as supported and `requested-features.md` does not name this.
**Fix:** replace the `strings.split` with a walk that treats `\|` as a literal and does not cut
there, leaving the backslash in place for `md_inline` to consume. Same walk in one place serves the
measure and the layout, since both already go through `md_split_cells`.

---

### [MEDIUM] Any prose line containing two `|` characters is rendered as a table row, and it splits the surrounding paragraph
**Where:** `src/program/markdown.odin:657` (`md_is_table_row`), reached from `md_classify:2545`
**Confidence:** CONFIRMED
**Fix risk:** RISKY (changing the predicate changes `md_table_bounds`, `md_para_bounds` and the
layout cache's block boundaries at once)
**Mechanism:** `md_is_table_row` is `contains("|") && count("|") >= 2` — no delimiter/separator row
is required, and no leading-pipe requirement. GFM requires a header row *followed by* a delimiter
row. Because `md_is_para_line` is defined as "`md_classify` says `.Para`"
(`markdown.odin:826`), a `.Table` line also **terminates a paragraph run** in `md_para_bounds`.
**Failure scenario:** a README paragraph:
```markdown
The build script accepts a target. Pass one of
debug | release | check to build.bat and it does the rest.
```
Line 2 has two pipes → `.Table`. In the preview it is laid out as a three-column table row
(mono face, column rules, its own fitted geometry) sandwiched between two one-line paragraphs,
because the join stops at it from both sides. The prose reflow the paragraph model exists to give
is lost for the whole paragraph. Same for any line mentioning `a || b`, an ASCII box drawing, or a
shell pipeline written outside a code span.
Not recorded; HANDOFF §6be/§9 discuss table *rendering* but not the recogniser.
**Fix:** require that the line, or the line directly above/below it, participates in a header +
`md_row_is_sep` pair before classifying `.Table`. That is a two-line lookaround and therefore
belongs in `md_para_bounds`'s layer (which already looks back and forward) rather than in the pure
`md_classify` — the same argument the file makes for setext and lazy continuation. Worth raising
with Wyatt before building: it moves block boundaries, which is the layout cache's key.

---

### [MEDIUM] `xml_format` silently deletes text that sits outside the root element
**Where:** `src/base/xml_format.odin:217-223` (`case .Text: i = e; continue`)
**Confidence:** CONFIRMED
**Fix risk:** SAFE (refuse instead of dropping)
**Mechanism:** The `.Text` case drops the token with the justification that "text between elements
at a laid-out level is whitespace by construction — an element with real text was copied whole by
the `.Open` branch and never reaches here". That reasoning holds *inside* an element (the
`has_text` extent check protects it) but **not at depth 0**, where there is no enclosing element to
have been copied verbatim.
**Failure scenario:** a hand-maintained fragment file `snippet.xml`:
```xml
<row a="1"/>
NOTE: regenerate after every schema change
<row a="2"/>
```
Format Document rewrites it to `<row a="1"/>\n<row a="2"/>\n` — the NOTE line is gone, with a
`[FORMATTED]` note and no warning. Undoable, but silent, and `unchanged` (`commands.odin:1662`) is
false so the buffer really is replaced. The same shape swallows any trailing text after the root.
**Fix:** in the `.Text` case, refuse with a new `Xml_Error` (or `.Unbalanced`) when
`depth == 0 && !is_ws_only(...)`, and put the caret on the offending byte the way every other
refusal here does. `is_ws_only` already exists at `:120`.

---

### [MEDIUM] Every visible markdown table row re-shapes and the whole table block re-measures on **every keystroke** in Split view
**Where:** `src/program/markdown.odin:2977` (`md_layout_extern_dep` includes `.Table`), `:1452` (`md_table_ensure` keys on `doc.revision`), `:1394-1427` (`md_table_measure`)
**Confidence:** CONFIRMED (code path); the millisecond cost is NOT measured
**Fix risk:** RISKY (a content-keyed table cache is a design change)
**Mechanism:** A `.Table` block is revision-keyed, so `md_layout_ensure` (`:3769`) misses for every
visible table row on any edit, and each miss re-runs `md_inline` per cell plus a
`plat.shape_columns` for the row. `md_table_ensure` is likewise revision-keyed (`:1453`), so the
block measure is redone too: `md_table_measure` walks the whole block up to `md_table_max_rows`
(1024 rows) / `md_table_budget` (1 MB) and, per non-separator cell, allocates a
`strings.Builder`, re-runs `md_inline`, and calls `plat.text_cells`. This violates the
viewport-first rule for the measure specifically — the measure is deliberately block-scoped (the
file argues for it at `:528-540`), but it is redone per revision rather than per content change.
**Failure scenario:** a 300-row × 6-column markdown table in `Ctrl+M` Split view. Every character
typed anywhere in the document — including in a paragraph 400 lines above the table — invalidates
all four `md_table` slots and every visible `.Table` layout, so each keystroke pays one full
1800-cell measure plus ~40 `shape_columns` calls before the frame draws. A one-character edit in a
document with no table rebuilds exactly one block (`mdtest` asserts this); with a table on screen
it rebuilds every visible row and re-measures the block.
Related but not the same as HANDOFF §5's *fixed* `md_table_ensure` cache-key entry (HANDOFF:250),
which was about the budget/max_rows terms being **missing** from the key, not about `revision`
being too coarse.
**Fix:** measure before changing anything — `mdperftest` with a large-table fixture. If it is real,
key `Md_Table_Cache` on the block's own bytes (a hash of `[start, end)`) rather than on
`doc.revision`, exactly as the layout cache keys on `src` for the non-extern-dep kinds; and make
`.Table` extern-dep on the *table cache's* generation rather than on `doc.revision`.

---

### [LOW] `css_format` collapses runs of spaces inside an unquoted `url(...)`, contradicting its own header and its own test's claim
**Where:** `src/base/css_format.odin:106-113` (whitespace case), header at `:13`, test at `src/base/css_format_test.odin:49`
**Confidence:** CONFIRMED
**Fix risk:** SAFE (subsumed by the `url(` case in finding 1)
**Mechanism:** The whitespace case collapses any run to one space. The test
`css_ok(t, "a{background:url(a b.png)}", ..., "a url keeps its spaces")` passes only because the
fixture has exactly one space.
**Failure scenario:** `a{background:url(my  file.png)}` (two spaces, a real filename) formats to
`url(my file.png)`, pointing at a file that does not exist. Same for a tab inside the URL.
**Fix:** the verbatim `url(` copy from finding 1 closes this; widen the existing test fixture to
two spaces so it can fail.

---

### [LOW] A markdown link whose target contains a closing paren is truncated
**Where:** `src/program/markdown.odin:1942-1955` (`case c == '['`)
**Confidence:** CONFIRMED
**Fix risk:** SAFE (balance-count the parens, as `links.odin:118-132` already does for bare URLs)
**Mechanism:** The target scan is `for j < n && s[j] != ')' {j += 1}` — it stops at the *first*
`)`. `links.odin`'s `trim_trailing` already implements paren balancing for bare URLs, so the two
detectors disagree about the same URL shape.
**Failure scenario:** `See [the article](https://en.wikipedia.org/wiki/Sort_(C++)) for details.` —
the preview draws the label `the article` with `url = "https://en.wikipedia.org/wiki/Sort_(C++"`,
underlines it (if it resolves), Ctrl+click opens the truncated URL, and a stray `)` is left in the
prose. Wikipedia and MSDN URLs are the common carriers of this shape.
`requested-features.md:285` records autolinks and reference links as unsupported; it does not
record inline links being truncated.
**Fix:** track paren depth in the target scan, closing on the paren that returns depth to zero,
matching `links.odin`'s balancing rule.

---

### [LOW] `md_table_measure` re-parses every cell's inline runs, duplicating work `md_layout_build` does again immediately after
**Where:** `src/program/markdown.odin:1417-1421` vs `:3512-3537`
**Confidence:** CONFIRMED
**Fix risk:** SAFE
**Mechanism:** The measure builds a `strings.Builder` per cell and runs `md_inline(cell)` purely to
strip markdown syntax before `plat.text_cells`. `md_layout_build`'s `.Table` case then runs
`md_inline(cell)` again on the same bytes to draft spans. Two parses of the same text, in the same
frame, for the same block. It is the *right* measure (the comment at `:1408-1416` explains why the
raw cell was wrong) — it just happens twice.
**Failure scenario:** no wrong output; a 300×6 table pays ~1800 redundant `md_inline` calls plus
1800 temp builders on every measure (which, per finding 9, is every keystroke).
**Fix:** have `md_table_measure` record the per-cell rendered *cell count* it computed and let
`md_layout_build` read it, or (cleaner) split a `md_inline_plain(cell) -> string` helper both call.
Low priority; fold into finding 9's measurement.

---

## MARKETABLE

Six things in this subsystem that are genuinely sellable, each with the honest limit stated.

1. **Live markdown preview that scrolls in pixels, not lines, and stays anchored to your editor.**
   `Ctrl+M` cycles source → split → preview (`markdown.odin:510`). The preview is pixel-anchored
   (`Md_Anchor`, `:3917`) with block-level scroll sync in both directions
   (`md_anchor_from_top:5377`, `md_anchor_top_byte:5386`), so a heading or a code fence changing
   height does not drift the two halves apart — the failure mode that makes most split previews
   feel broken. **Limit:** the layout budget is one pane below the viewport; the screen *above* is
   only laid out on the scroll-up gesture (`md_probe_back:5065`), so a very fast upward fling can
   land on a position the walk had to clamp.

2. **It previews a multi-GB markdown file without parsing it.** Every walk is bounded from the
   scroll anchor outward — `md_walk` (`:4092`) has a hard height limit and a hard block budget, the
   paragraph join is capped at 256 KB / 4096 lines (`MD_PARA_BUDGET:613`), the table measure at
   1 MB / 1024 rows (`:541`, `:585`), and blank runs collapse (`MD_BLANK_RUN_MAX:2861`). There is no
   code path that lays out the whole document. **Limit:** past those caps a construct degrades
   rather than failing — an over-long paragraph renders line-by-line, an over-long table falls back
   to fixed 16-cell columns (`md_table_measure:1387`).

3. **Real typography, not a monospace fake.** UI spec §9.3's type scale is computed once per pass
   and rounded to whole pixels (`md_metrics:1796`, `md_scale:1790`): a proportional body face with
   real bold and italic faces (`md_run_set:3059`), Monaspace/`.Doc` mono for code and tables, a
   72-character measure (`:1818`), collapsing margins (`md_walk:4135`), h1/h2 rules, task-list
   checkboxes drawn as geometry rather than glyphs (`md_tick_quads:2049`), a front-matter card and
   zebra-banded tables whose stripe parity is counted from the table's own start so it does not
   flip as you scroll (`md_table_row_index:4746`). **Limit:** reference links, autolinks, footnotes,
   images and mermaid are not rendered (`requested-features.md:285`, HANDOFF §6 "drop mermaid for
   v2+"); h6 tracking is owed.

4. **The preview is selectable and copyable, and it copies what you see.** Drag-select, `Ctrl+A`,
   `Ctrl+C` (`md_sel_text:4577`) yield the *rendered* text — `# Title` copies as `Title`, a link
   copies as its label, list bullets survive, table cells are tab-separated so a pasted table lands
   in a spreadsheet's columns. The hit-test reads the same `Shaped` glyph list the draw painted
   (`md_block_pos_at:4800`). **Limit (measured, not marketing):** finding 3 above means the click
   point is off by the block indent inside lists, quotes and code blocks, and finding 5 means a
   table with formatted or empty cells pastes into the wrong columns. Both are fixable and both are
   real today. There is no rich-text (CF_HTML) clipboard flavour, and `Ctrl+A` refuses past 4 MB
   (`MD_COPY_MAX:4563`).

5. **CSV and TSV rendered as a real, editable grid over a multi-GB file.** `Ctrl+T`
   (`table.odin`): sticky header, 56px row-number gutter, zebra bands, numeric/date columns
   auto-right-aligned from a bounded 500-row sample (`table_compute_widths:3482`,
   `table_is_number:3563`, `table_is_date:3602`), drag-to-resize and double-click-to-fit columns,
   `Ctrl+click` on links inside cells (`table_links:3784`), in-cell editing that writes exactly one
   field's byte span through the document's undo (`csv_field_ranges:4451`, `csv_serialize:4484`,
   `table_edit_commit:4761`), a summary row that says row count / column count / active sort in
   words, and a 2px warning bar on rows with the wrong field count rather than dropping them
   (`table_draw:4141`). **Limit:** a quoted field spanning a newline is not supported (stated in the
   file header, `table.odin:8`) — each physical line is one row.

6. **View-only multi-column sort and a per-column value filter that never rewrite the file.**
   Click a header to sort, `Ctrl+click` a second for a tie-breaker (`TABLE_SORT_KEYS_MAX:1133`),
   and a checkbox dropdown of a column's distinct values to filter (`table_filter_open:1537`). The
   sort is a permutation over row offsets — the bytes never move and the document is not marked
   modified — and cell editing keeps working through it, guarded by a byte-identity check on the
   edited line so a reorder can never redirect a commit onto a different row
   (`table_edit_line_intact:4670`). **Limits, all honest and all in the code:** it refuses past
   100,000 rows and *says so in the summary row* rather than sorting a sample (`TABLE_SORT_MAX:1081`,
   measured at ~258 ms release at the ceiling); `Ctrl+End` under a sort lands wherever the file's
   last row went (`table_sort_snap:2477`); and finding 2 above is a real data-integrity hole in the
   filter-without-sort combination that must be fixed before this is marketed.
