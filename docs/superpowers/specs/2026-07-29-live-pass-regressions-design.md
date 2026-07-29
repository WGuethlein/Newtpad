# Live-pass regressions + regex substitution — design

Six items. Five are things the v0.28.0/v0.29.0 batch itself introduced or made reachable; one is a
feature Wyatt asked for by name. Branch `fix/live-pass-regressions`, target **v0.30.0** (a new
capability lands, so it is a minor bump).

Wyatt's instruction: *"fix the bugs these generated that you mentioned… regex should be true to a
standard… after let's continue with the batch."*

Sources: [HANDOFF §6ar](../../../HANDOFF.md)'s Owed list and the whole-branch review recorded in
`.superpowers/sdd/progress.md`.

---

## 1. Regex replacement writes `$1` literally

**Wyatt: "regex should be true to a standard."**

**Today.** `$1` in a replacement inserts the two characters `$` and `1`. Pinned by a test so it cannot
change silently, but Replace All just gave it a key, a palette entry and a button, so it went from
unreachable to prominent.

**The standard: .NET / JavaScript `String.replace` substitution**, which is also what VS Code's find
widget implements. Chosen because the find bar already matches VS Code deliberately — Wyatt picked
all-Alt toggles for exactly that reason — and a user who knows one knows the other. PCRE's `\1` is the
other candidate and is rejected: backslash already means escape inside the *pattern*, and using it in
the *replacement* too invites the confusion this feature exists to remove.

| Token | Means |
|---|---|
| `$1` … `$9` | capture group *n* |
| `${12}` | capture group 12 — the braces exist so `$1` followed by a literal `2` is expressible |
| `$0`, `$&` | the whole match |
| `$$` | a literal `$` |
| `$` followed by anything else | literal, emitted as-is |

An out-of-range group substitutes **empty**, matching .NET. It is not an error: a pattern with an
optional group legitimately produces an unset capture, and refusing the whole replace over it would be
worse than the alternative.

**How captures are recovered, and why not by storing them.** `Search` keeps matches as parallel arrays
(`matches`, `match_len`, `line_start`, `line_no`) with no capture data. Storing groups would cost
`MAX_MATCHES × groups × 2` ints on every search whether or not a replacement ever uses one.

Instead: **re-match the compiled pattern against the matched bytes at replace time**, and only when the
replacement actually contains a `$` followed by a digit, `{`, `&` or `$`. Cost is one regex run over a
few bytes per replaced match, on a path the user explicitly invoked, and exactly zero when the
replacement is a plain string. A helper decides the "does this replacement reference a group" question
once, before the loop.

**Anchors are the trap.** Re-matching an isolated slice changes what `^`, `$`, `\b` and lookarounds see.
Feed the re-match the *same* buffer the scan matched in, anchored at the match's own offset — not a
freshly copied substring — or a pattern like `^foo` will behave differently at replace time than it did
at search time. If `core:text/regex` cannot express "match starting exactly here", say so in the report
rather than shipping a subtly different match.

**Test.** `a(b+)c` over `abbbc` with `[$1]` → `[bbb]`; `$&` → the whole match; `$$` → one `$`; `${12}`
against a 12-group pattern; an unset optional group → empty; `$x` → literal `$x`; a group whose text
contains a `$`. Plus: a replacement with no `$` at all must take the cheap path and produce identical
output to today. **Sabotage:** emit groups in the wrong order and confirm the test fails.

---

## 2. The `Replace All` menu row draws enabled and does nothing in table view and Preview

**Introduced by this batch**, in the same commit that added the row.

`item_enabled` (`src/program/menu.odin:443`) consults `command_allowed_on` for pseudo-tabs but not
`doc_read_only_view`, so in table view and full Preview the row paints as live, highlights on hover, and
no-ops on click — the refusal happens later, in `commands.odin`.

That is *the same defect Task 15 went out of its way to fix for the buttons*: `find_actions` returns an
empty slice on a read-only view specifically so the draw, hover, cursor and hit-test agree from one
change. The menu did not get the same treatment.

**Fix.** `item_enabled` consults `doc_read_only_view` as well. Note `.Paste` has the identical
pre-existing hole; fixing the predicate fixes both, which is the point of fixing the predicate rather
than the row.

**Test.** In table view and in full Preview, every row whose command mutates the document reports
disabled. **Sabotage:** drop the new condition, confirm it fails.

---

## 3. The front-matter card hides the `---` delimiters Wyatt could see

**Introduced by this batch.** Wyatt described the old rendering as *"i see the start and end `---`"* — a
statement of what he observes, and the card removed them. He was not asked whether he wanted them gone.

**Fix.** Keep the card, restore the delimiters *inside* it, drawn in `Text_Muted` on the card surface
rather than as `Md_Rule` horizontal rules (rules were the thing that made it read as two lines rather
than a block). The card stays the "muted card" UI spec 9.2 item 12 asks for, and the document still
looks like the document.

Still a placeholder for his eye; this restores information he had rather than settling the design.

**Test.** The opening and closing `---` rows are drawn as text inside the card's bounds, and no
`Md_Rule` quad is emitted. **Sabotage:** suppress the delimiter rows, confirm it fails.

---

## 4. The horizontal scroll range never shrinks, so deleting the longest line leaves phantom pan

**Introduced by this batch.** Measured: one 400-cell line plus fifty short ones gives
`doc_max_hscroll` = 323; delete the long line and it stays 323 for the rest of the session, offering
pan into content that no longer exists.

The high-water mark was Wyatt's explicit choice over a background scan and stays. What was missed is
that **an edit can shrink the content**, and the comment concluding "no reset needed" enumerated only
document-*replacement* paths.

**Fix.** Clear `max_cells_seen` when the document is edited, letting it re-grow from the viewport. An
edit already bumps `doc.revision`; key the high-water on the revision it was measured at and drop it
when the revision moves. That keeps the property Wyatt wanted — the range does not collapse when you
merely *scroll* — while not surviving a change to the content itself.

**Secondary defect to fix with it:** `doc_max_hscroll` is a getter that mutates the `Document`, called
from `render_frame`, so the draw is not idempotent. Move the store to the frame's update phase, or make
the mutation explicit in the name. The draw must not be where this happens.

**Test.** Long line visible → range *R*; scroll it off → still *R* (the property that must not
regress); delete it → range shrinks. **Sabotage each direction separately** — they are independent, and
a single test that only checks the shrink would let the original bug back in.

---

## 5. A non-local link neither decorates nor opens

**Introduced by this batch**, deliberately, to stop a >100-second UI freeze. The async resolver is the
real answer and is out of scope here. But there is a middle ground the review identified and it costs
nothing:

**On Ctrl+click of a non-local target, skip resolution and go straight to `shell_reveal`.**
`explorer.exe /select,"path"` resolves the path in *its own process*, off our UI thread. Reveal-not-
execute is already the policy for every non-text target, so this weakens nothing about what we are
willing to launch.

**The security question, stated rather than glossed:** this hands an unstat'd path to the shell, where
today every path is stat'd first. `/select` does not execute the target — it opens a folder window with
the item selected — so the exposure is "Explorer navigates somewhere" rather than "something runs".
Combined with the existing scheme whitelist (a URI-scheme-carrying token is refused on the path branch
before any of this), the residual risk is a folder window opening on a path the user Ctrl+clicked in
their own document. **Decoration stays off** — we still cannot promise it will open.

**Test.** A UNC target routes to reveal without a stat; a local target is unaffected; a URI-scheme token
is still refused. **Sabotage:** route it through `link_resolve` instead and confirm the no-stat
assertion fails.

---

## 6. Markdown headings overhang the content box and are clipped mid-glyph

**Introduced by this batch.** `markdown.odin:807-817` advances `y` by `hh + (hpx - px) - px*0.3` for a
heading, while `md_row_fits` admits on body `line_h`. A heading near the bottom is admitted, drawn
taller than the budget it was admitted against, and the cover strip clips it through the middle of the
glyphs.

Strictly better than the pre-batch behaviour (it used to paint over the status bar), which is why it was
carried — but a half-glyph is its own defect.

**Fix.** `md_row_fits` must be asked with the row's *own* height. That means classifying the block
before deciding whether it fits, rather than after — restructuring the loop so height is known at the
admit decision. This is the largest of the six and should be sequenced last.

**Test.** At window heights where a heading is the last admissible row, assert the heading's full drawn
height is within the content box, for each heading level. **Sabotage:** restore the body-`line_h`
admit, confirm a level-1 heading overflows.

---

## Out of scope, and why

- **The async link resolver.** A `watch.odin`-shaped worker; a design change, not a regression fix.
- **A path link to a missing file is now invisible.** That is the "underlined implies openable"
  invariant working as designed. It goes in the release notes so it is not re-reported as a bug.
- **Fences indented 4+ columns are now ignored.** CommonMark-correct, and the drawer and lexer now
  agree — which is what made the parity bug fixable at all.
- **`render_frame` queries the live OS cursor inside the draw.** Real, and against "events queue to the
  frame arena", but it is one instance of a pattern the `renderer`/`ui` extraction exists to fix.
  Recorded, not fixed here.
- **The grid/CSV view still wastes its last row**, and **there is still no scissor facility.** Both are
  their own tasks.
