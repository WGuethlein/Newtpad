# Syntax Highlighting Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Colour every file type Newtpad claims to open, without breaking the never-freeze rule on huge files.

**Architecture:** Lexers are **pure functions in `src/base`** over a byte slice, emitting `base.Token{start, len, kind}`. `program` maps `Token_Kind` → `Color_Role` → `plat.Text_Span` and hands them to `plat.text_draw_spans`, which already exists and which `links.odin` already uses. **The renderer needs no changes.** Multi-line state comes from a background per-line index for small files and a bounded backward resync for huge ones.

**Tech Stack:** Odin; lexers in `base` (unit-testable via `odin test`), dispatch and span mapping in `program`; headless modes for everything needing a `Document`.

**Spec:** [docs/superpowers/specs/2026-07-25-syntax-highlighting-design.md](../specs/2026-07-25-syntax-highlighting-design.md)

**Branch:** `feat/syntax-highlighting` (created; spec committed).

## Global Constraints

- **Layer boundaries:** `base` → `platform` → `program`. **Lexers go in `base` and must not know about `Color_Role` or `plat.Text_Span`** — both live above them. They emit a `base`-level `Token_Kind`; `program` maps it. This is what makes them unit-testable and what keeps the layering legal.
- **Viewport-first:** per-frame work proportional to the viewport, never to the document. No unbounded backward scan, ever.
- **Never freeze on huge files.** A multi-GB single-line file and a renamed CSV are supported inputs.
- **One layout per widget.** Spans are row-relative; the row's extent comes from `visible_next`'s `vis_end`, not a second computation.
- **Zero-is-initialization** (Odin default).
- **A test that has never failed proves nothing.** Reintroduce the bug, watch it fail, restore.
- **Build:** `build.bat` (debug, console). A bare `odin build` omits the DPI manifest and is wrong. Rebuild under ~5 s — **already at 5.8 s for release, so watch it.**
- **Test modes:** set `NEWTPAD_SESSION_DIR` to a temp dir; several modes refuse without it. `edittest`/`keytest` need a path argument first; `watchtest` needs a directory. **Never run `drawcount` and never launch the app** — both open a real window, hang, and lock the exe.
- **Git:** commits authored solely by the repo owner. **Never** `Co-Authored-By: Claude`, "Generated with Claude Code", robot emoji, or any AI attribution. Imperative subject under 65 chars.

---

## File Structure

**Created:**
- `src/base/lex.odin` — `Token`, `Token_Kind`, `Lex_State`, and the shared scanning helpers.
- `src/base/lex_log.odin`, `lex_json.odin`, `lex_xml.odin`, `lex_c.odin`, `lex_md.odin`, `lex_delim.odin`, `lex_conf.odin`, `lex_shell.odin` — one per lexer, so each stays small enough to hold in context.
- `src/base/lex_test.odin` — `@(test)` cases for all of them.
- `src/program/highlight.odin` — extension→lexer dispatch, `Token_Kind`→`Color_Role` mapping, the per-row span builder, the lex-state index, and the resync.

**Modified:** `src/program/doc.odin` (the draw's span collection, alongside the existing link spans), `src/program/test_modes.odin`.

**Task order.** Task 1 builds the whole pipeline with the one lexer that has no multi-line state, so the seam is proven before the hard part. Task 3 adds the state machinery with the simplest multi-line lexer to exercise it. Task 4's C-family lexer — the one covering eleven extensions — lands on machinery that is already proven.

---

## Task 1: The span pipeline, the log lexer, and the three interactions

The foundation. **Every later lexer inherits whatever this task gets right or wrong about wrap, filter and links**, so those are here rather than bolted on later.

The log lexer is first because it is line-local — no multi-line state at all — so it proves the pipeline without needing the index that Task 3 builds.

**Files:** create `src/base/lex.odin`, `src/base/lex_log.odin`, `src/base/lex_test.odin`, `src/program/highlight.odin`; modify `doc.odin`, `test_modes.odin`.

**Interfaces produced:**
- `base.Token_Kind :: enum u8 {None, Keyword, String, Number, Comment, Type, Punct, Json_Key, Xml_Tag, Xml_Attr}`
- `base.Token :: struct {start, len: int, kind: Token_Kind}`
- `base.lex_log :: proc(line: []u8, out: []Token) -> int`
- `highlight_kind_role :: proc(k: base.Token_Kind) -> Color_Role`
- `highlight_row_spans :: proc(doc: ^Document, row_bytes: []u8, out: []plat.Text_Span) -> int`

- [ ] **Step 1: The token types, in `base`**

`Token_Kind` mirrors the nine `Syn_*` roles plus `None`. **`base` must not reference `Color_Role` or `plat.Text_Span`** — the mapping lives in `program`. Write that constraint into the file's header comment, because it is the thing a later contributor will most naturally break.

- [ ] **Step 2: `lex_log` as a pure function, with unit tests first**

Signature takes one line's bytes and fills a caller-supplied `[]Token`, returning the count — no allocation, since this runs per visible row per frame.

Patterns: an ISO-8601 or bracketed timestamp at line start; a level word (`ERROR` `WARN` `WARNING` `INFO` `DEBUG` `TRACE`) as a whole word; a double- or single-quoted string; a bare number. Map: timestamp → `Number`, level → `Keyword`, string → `String`, number → `Number`.

Write `lex_test.odin` cases **before** the implementation and watch them fail: a line with all four, a line with none, a level word appearing inside a larger word (must not match), an unterminated quote (must not run past the line end), an empty line, and a line longer than `out` (must stop at capacity, not overflow).

- [ ] **Step 3: The dispatch and the mapping, in `program`**

`highlight.odin`: extension → lexer, and `Token_Kind` → `Color_Role`. Both are data, not branching logic. `.txt` maps to no lexer, correctly — it has no grammar.

- [ ] **Step 4: Wire into `doc_draw` beside the links, and handle all three interactions**

The link-span collection at `doc.odin:2202-2209` is the model and the neighbour. Three things must be right:

**Wrap.** Spans are row-relative. The row's drawn extent is `vis_end` from `visible_next` — use it, do not recompute. A construct crossing a wrap point must produce correctly rebased spans on both visual rows. `links.odin`'s comment (*"a wrapped link only colours its part here"*) marks where this is already solved; follow it rather than inventing a second approach.

**Filter.** In filter mode the visible rows are non-contiguous logical lines. For a line-local lexer this is free — say so in a comment, because it stops being free in Task 3 and the next reader needs to know why.

**Links win.** A URL inside a log line is both a link span and a lexer span on the same bytes. Emit the lexer's spans first and the link spans after, so links overwrite — but **verify that is actually how `text_draw_spans` resolves overlap** before relying on ordering. If it does not resolve overlaps deterministically, drop the syntax spans that intersect a link instead, and say which you did and why.

- [ ] **Step 5: Prove the per-frame work is viewport-proportional**

The failure mode of this whole batch is a lexer that is correct and quietly O(file). Add a headless mode asserting that highlighting a viewport costs the same on a 1 KB file and a very large one — compare a counter of bytes examined, not wall-clock, so the assertion is stable.

Verify it can fail: make the row-span builder scan from the buffer start, watch the assertion fail, restore.

- [ ] **Step 6: Verify and commit**

`odin test src\base`, the new mode, plus `rowtest crlftest mdtabletest splittest movelinetest themetest`.

```bash
git commit -m "Highlight log files, and the pipeline to do it"
```

---

## Task 2: The JSON lexer

A second line-local lexer, to prove one drops into the pipeline cheaply and to exercise a format-specific role.

JSON strings cannot span lines, so this still needs no state machinery. `Json_Key` distinguishes a string before a `:` from a string used as a value — the one thing that makes JSON highlighting worth having over generic string colouring.

- [ ] **Step 1: Unit tests first**, then `base.lex_json`: keys, string values, numbers (including negative, exponent, and `.5`-style malformed input that must not crash), `true`/`false`/`null` as `Keyword`, structural `{}[],:` as `Punct`.
- [ ] **Step 2: Register the extension.** If nothing beyond registration is needed, that is the pipeline working — say so, it is evidence about Task 1's design.
- [ ] **Step 3: A malformed-JSON fixture must not crash or hang** — the lexer colours, it does not validate. An unterminated string ends at the line end; an unbalanced brace is just a `Punct`.
- [ ] **Step 4: Verify and commit.**

---

## Task 3: Lex state — the background index and the bounded resync

The architectural piece. No new file type is *required* here, but the XML/HTML lexer comes with it because its `<!-- -->` comments are the simplest real multi-line construct to exercise the machinery — building the state mechanism against a lexer with no state would prove nothing.

**Mirror `Line_Index` (`doc.odin:586`).** Same fields, same lifecycle: immutable `original`, atomics for `line_count`/`indexed`/`done`/`cancel`/`fault`, the `guard` flag for mapped content, cancel-store then join on teardown. **Do not invent a second background-job pattern** — HANDOFF says so and the codebase has exactly one.

- [ ] **Step 1: `Lex_State`** — a small enum, one byte per line (`Normal`, `In_Block_Comment`, `In_String`, …). It must stay one byte: on a 10M-line file the index is 10 MB, and a wider state multiplies that directly.
- [ ] **Step 2: The background index for small files.** Threshold: the same one that decides copy-vs-mmap. Built over `original`, keyed on `Document.revision` for invalidation — **do not add a new invalidation mechanism**, batch 2's counter already exists and batch 3's table cache already uses it.
- [ ] **Step 3: The bounded resync for huge files.** Scan back a bounded window from the viewport for a position of unambiguous state, then lex forward. **A cap hit is a bail to `Normal`, not a truncation** — the documented failure mode, not a corrupted one.
- [ ] **Step 4: `base.lex_xml`,** exercising `<!-- -->` across lines, plus tags, attributes and entity refs.
- [ ] **Step 5: The filter interaction stops being free.** Non-contiguous rows each need their own state. With the index that is a lookup; with resync it is a resync *per row*, which could be O(rows × window). **Bound it** — and if the bound makes filtered highlighting wrong on huge files, that is a documented limitation, not something to hide.
- [ ] **Step 6: Test the failure mode explicitly.** A block comment longer than the resync window mis-colours until scrolled to. Assert *that specific behaviour*. A test that pretends the limitation does not exist is worse than no test.
- [ ] **Step 7: Verify, sabotage the resync bound, commit.**

---

## Task 4: The C-family lexer

Eleven extensions, one grammar, on machinery Task 3 proved. Where the leverage is.

- [ ] **Step 1: Unit tests first** — line comments, block comments (including nested-looking `/* /* */`, which in C is *not* nested), strings with escapes, char literals, raw/backtick strings where the language has them, numbers in every base, and preprocessor lines.
- [ ] **Step 2: `base.lex_c`,** taking a keyword set as a parameter so the grammar is written once.
- [ ] **Step 3: Keyword sets as data**, one per language. Report the source used for each — an invented keyword list is worse than none.
- [ ] **Step 4: `Syn_Type` is lexical only.** No symbol table, no resolution. Colour by shape (e.g. an identifier after `struct`/`class`, or a known primitive). If a language makes this genuinely ambiguous, emit `None` rather than guessing — a wrong colour is worse than no colour.
- [ ] **Step 5: Verify and commit.**

---

## Task 5: The remaining lexers

`markdown`, `delimited` (`.csv .tsv`), `config` (`.ini .toml .yaml .yml .cfg .conf .env .gitignore`), `shell` (`.sh .bat .ps1`). Plus `.sql` and `.css` folded into their nearest fit — **state which and why**.

- [ ] **Step 1: Unit tests per lexer, then each implementation.** They are independent; do them one at a time with the tests first.
- [ ] **Step 2: Markdown must not fight the existing preview.** `markdown.odin` already renders a *styled preview*; this lexer colours the *source* view. They are different features on the same file type and must not be confused for one another.
- [ ] **Step 3: YAML's significant indentation and multi-line block scalars** (`|`, `>`) need Task 3's state. If that turns out not to fit, report rather than approximating — a YAML lexer that mis-colours block scalars is worse than one that leaves them plain.
- [ ] **Step 4: Verify every extension in `text_exts.txt` now resolves to a lexer or is deliberately plain.** Assert that as a test over the actual file, so adding an extension later without a lexer is caught.
- [ ] **Step 5: Commit.**

---

## Final verification

- [ ] `odin test src\base -collection:src=src`
- [ ] Every headless mode with `NEWTPAD_SESSION_DIR` set
- [ ] `build.bat release` — **watch the ~5 s rule; it was 5.8 s before this batch and eight new files will not help.** If it goes further over, say so rather than letting it slide.
- [ ] Bump `src/program/version.odin`
- [ ] HANDOFF entry: the pipeline, the state strategy and its documented failure mode, what each lexer covers, and anything deferred
- [ ] **Run `install.ps1`** — standing instruction. Check `Get-Process newtpad` first; do **not** use `-Force` if it is running, since a hard kill can skip the hot-exit session write.
- [ ] **Wyatt's live pass:** one file of each family, in both themes. The `Syn_*` roles were chosen by arithmetic in batch 3 and have never been seen against real code — Light especially.
