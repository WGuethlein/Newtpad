# Batch 4 — syntax highlighting

Date: 2026-07-25. Branch `feat/syntax-highlighting`, on top of v0.12.0.

Second of the six batches in HANDOFF §6u. There is currently **no syntax highlighting at all** —
zero lexers, and every "highlight" in the tree is a find-match or selection rectangle. `doc_draw`
paints every byte of every file one colour. CLAUDE.md states lex/highlight as a hard rule and the
viewport-first machinery was built to serve it.

Decisions taken with Wyatt before design are marked **Decided:**.

## The renderer needs no changes

This is the most important fact about the batch and it should shape every task in it.

`plat.text_draw_spans(gfx, t, str, x, y, px, base_color, spans, set)` already exists
(`platform/text.odin:587`), takes `[]Text_Span{start, len, color}`, and **`links.odin` already uses
it exactly this way** — `doc_draw` collects the row's link hits into a `[dynamic]plat.Text_Span` on
the temp allocator and passes them through (`doc.odin:2202-2209`).

So syntax highlighting is **a second span producer plugged into a seam that is already load-bearing**,
not a rendering feature. No platform work, no new draw path, no change to how text reaches the GPU.
Batch 3 supplied the colours: the nine `Syn_*` roles are already declared and deliberately unused.

That also sets the shape of every lexer's output: **spans are row-relative** (`start` is a byte offset
within the row's drawn text), because that is what the existing consumer expects.

## The hard problem: lexer state at an arbitrary viewport

To colour the rows at `doc.top`, the lexer must know its state *there* — inside a block comment?
inside a multi-line string? `doc.top` can be any byte offset in a multi-GB file, and lexing from byte
0 to find out would break the never-freeze rule outright.

**Decided:** mirror the existing copy-small / mmap-large split rather than inventing a third policy.

- **Small files** (under the same threshold that decides copy-vs-mmap) get a **background lex-state
  index** — one state byte per line, built exactly the way `Line_Index` already builds the line count:
  immutable `original`, atomics for `done`/`cancel`/`fault`, the SEH guard when the content is mapped.
  Always correct, and instant once built.
- **Huge files** resync by scanning back a **bounded window** above the viewport to find a position
  whose state is unambiguous, then lex forward from there.

The huge-file path has a **documented failure mode**: a block comment or multi-line string longer than
the resync window may colour wrongly until you scroll to its start. That is the honest cost of not
scanning a multi-GB file, and it must be written next to the code rather than discovered later.

**Mirror `Line_Index`; do not invent a second background-job pattern.** The codebase has exactly one,
it is battle-tested, and HANDOFF §6 already says so about the indexer.

## Three interactions that will bite if not designed for

**1. Word wrap.** A visual row is a *segment* of a logical line, and spans are row-relative. A lexer
that produces spans per logical line must have them split and rebased per visual row, or every wrapped
line after the first will be coloured at the wrong offsets. `links.odin` already solves this shape —
its comment says *"a wrapped link only colours its part here"* — so follow it.

**2. The filter view.** In filter mode the visible rows are **non-contiguous logical lines** scattered
through the file. Sequential lexing is meaningless there: row N+1 may be 10,000 lines below row N. Each
filtered row needs its state resolved independently, which the small-file index gives for free and the
huge-file resync must handle per row rather than once per viewport.

**3. Links.** A URL inside a comment is both a link span and a comment span, on the same bytes. They
must not both be appended blindly — the result would depend on ordering inside `text_draw_spans`.
**Links win**, because a link is interactive (Ctrl-hover, Ctrl-click) and its colour is the affordance;
a comment's colour is decoration. Whatever the mechanism, the rule needs stating and testing.

## Coverage — seven lexers, 34 extensions

**Decided:** every extension in `text_exts.txt` renders highlighted; nothing you can open stays plain.

| Lexer | Extensions |
|---|---|
| C-family (one grammar, per-language keyword sets) | `.c .h .cpp .hpp .cs .java .js .ts .go .rs .odin` |
| JSON | `.json` |
| XML/HTML | `.xml .html` |
| Markdown | `.md .markdown` |
| Delimited | `.csv .tsv` |
| Config | `.ini .toml .yaml .yml .cfg .conf .env .gitignore` |
| Shell | `.sh .bat .ps1` |
| Log (pattern, not grammar — see below) | `.log` |

`.sql` and `.css` fold into the nearest fit rather than earning their own lexer; say which in the plan.
`.txt` stays plain, correctly — it has no grammar to find.

The C-family lexer is where the leverage is: eleven extensions share `//` and `/* */` comments,
double-quoted strings, numbers and identifiers. Only the keyword set differs, which is data.

## The log lexer is different in kind

**Decided:** include it. Logs are the audience the large-file research centred on, and *"keyword
colouring is disproportionately loved by log users"*.

But it has no grammar — highlighting a log means recognising **patterns**: an ISO or bracketed
timestamp, a level word (`ERROR` `WARN` `INFO` `DEBUG` `TRACE`), a quoted string, a number. That makes
it line-local with no multi-line state at all, so it sidesteps the whole state problem — worth building
early as a result.

It also deliberately overlaps the user-configurable keyword→colour rules on the batch-8 list. Building
the pattern lexer now means that later feature becomes "let the user add rules to a mechanism that
already exists", not a second system.

## Invalidation

`Document.revision` (batch 2) is already the monotonic buffer-mutation counter, and batch 3's markdown
table cache already keys on it. The lex index and any per-row span cache key on it the same way. There
is no need for a new invalidation mechanism, and inventing one would be a third pattern for the same
job.

Note the index is built over the **immutable `original`**, as `Line_Index` is — so edits in the add
arena invalidate rather than corrupt it, exactly as they do today for the line count.

## Viewport-first

Lex the visible rows plus a small margin, per frame, bounded. Never the whole file on the UI thread,
never unbounded backward scanning. The per-frame work must be proportional to the viewport, not the
document — this is the rule the whole architecture exists to serve and the one most likely to be
quietly broken by a lexer that "just needs a bit more context".

## Testing

`odin test src\base` for anything pure — the tokenisers themselves should be pure functions over a byte
slice returning spans, which makes them unit-testable without a `Document`. Push as much as possible
into that shape.

Headless modes for the rest:
- each lexer's spans on a representative fixture, asserted as `(start, len, role)` triples;
- **the wrap interaction**: a highlighted construct spanning a wrap point produces correctly rebased
  spans on both visual rows;
- **the filter interaction**: non-contiguous rows each resolve their own state;
- **link precedence**: a URL inside a comment renders as a link, not a comment;
- **the resync failure mode is bounded**: a block comment longer than the window mis-colours, and the
  test asserts *that specific documented behaviour* rather than pretending it does not happen;
- **per-frame work is viewport-proportional**: lexing a 1 GB file's viewport costs the same as a 1 KB
  file's.

The last one is the check that matters most, and it must be able to fail — the failure mode of this
whole batch is a lexer that is correct and quietly O(file).

## Out of scope

- User-configurable keyword→colour rules (batch 8, and deliberately built on this batch's log lexer).
- Code folding, bracket matching, indent guides — none were asked for.
- Semantic highlighting of any kind. These are lexers, not parsers: no symbol tables, no type
  resolution, no cross-file anything. `Syn_Type` is coloured by lexical shape only.
- Language-server anything. CLAUDE.md's scope rule: *"No LSP, no project trees, no terminal."*

## Verification owed to Wyatt

Nothing here can see a screen. Every claim in this batch is structural — spans at the right offsets
with the right roles — and none of it is a claim that the result *looks* right. Owed: open one file of
each family and confirm the highlighting reads correctly and that both themes remain legible with it,
particularly the `Syn_*` roles in Light, which were chosen in batch 4 by arithmetic and have never been
seen against real code.
