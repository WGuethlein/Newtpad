# The app vs the spec's MOCKUPS

Written 2026-08-04 after Wyatt put screenshots of the running app beside the spec's mockups and said
*"it still doesn't look anything like the spec... it looks completely different in some parts."*
He was right.

## What the earlier gap lists missed

`docs/ui-spec/` holds **two** files:

| File | Size | Holds |
|---|---|---|
| `newtpad-ui-spec-v1.md` | 57 KB | the prose rules |
| `newtpad-ui-spec-v1.html` | **185 KB**, 493 mockup elements | **the rendered mockups** |

[2026-08-04-menus.md](2026-08-04-menus.md) and [-palette.md](2026-08-04-palette.md) were built from
the markdown alone. They correctly enumerate §6's and §7's *prose* rules and correctly report those
as met — and that is a much smaller claim than "matches the spec", which is what "§6 is done" was
read as. **A spec with mockups is not read by reading its prose.**

Proof, by content that exists in the HTML and nowhere in the markdown: `Toggle Word Wrap`,
`Show Menu Bar`, `go to line · type a number`, `All 349`, `249 of 778`, `4 of 62`, `sqlReaderQuery`,
`Reflow Paragraph at Wrap Column`.

**Two of those are commands that do not exist in the product at all** — `Unwrap Selected Lines` and
`Reflow Paragraph at Wrap Column` appear in the palette mockup as ordinary rows.

---

## THE TIEBREAK RULE (Wyatt, 2026-08-04)

> **"mockup generally wins"**

So: **where the mockup and the prose disagree, build the mockup** — it is the picture the product is
being compared against. The two exceptions below are named exceptions, decided individually, not
precedent for reopening the rule.

Both exceptions have the same shape, which is worth seeing: the prose states a *reason* and the
mockup only shows a *result*. Where the prose is arguing rather than describing, it can still win —
but that is a judgement per case, not a second rule.

## Two places the mockup and the prose contradict each other — BOTH DECIDED

**Both were implemented per the prose, the mockup shows the opposite, and Wyatt chose the prose in
both. No code change; they are recorded so nobody "fixes" them toward the mockup later.**

### C1. The `Toggle` verb — DECIDED: prose. Keep the verb dropped.

Wyatt, 2026-08-04: *"keep toggle off"*. `Word Wrap`, not `Toggle Word Wrap`. Built state is correct.


- **Prose §6.3:** *"'Toggle' ×3 is noise… Drop the verb."*
- **Mockup:** rows read `Toggle Word Wrap`, `Toggle Table View (CSV/TSV)`, `Toggle Markdown Preview`.
- **Built:** verb dropped, per the prose.

The mockup is not simply the "before" picture — it also contains `Reset Zoom (125%)` and a
`Show Menu Bar NEW` row, both target-state.

### C2. The disabled row's reason — DECIDED: prose. Keep showing the reason.

Wyatt, 2026-08-04, choosing it against the mockup and against a both-columns variant: a greyed row
shows **why**, not its shortcut — `Table View (CSV/TSV)    CSV and TSV only`. Built state is
correct, and `menutest` already covers it. The "both" option was rejected on width: `dropdown_w`
sizes a panel from its widest row, so carrying reason *and* accelerator widens every dropdown that
has a disabled row.


- **Prose §6.4:** *"Disabled items give no reason… Show the reason in `text_muted` where the
  accelerator would be."*
- **Mockup:** the greyed `Toggle Table View (CSV/TSV)` row **keeps its `Ctrl+T` accelerator** and
  shows no reason.
- **Built:** reason replaces the accelerator (`CSV and TSV only`), per the prose.

---

## Per surface

### Command palette — the largest divergence

| | Mockup | Built |
|---|---|---|
| Header | `>` prompt + the query, count **`4 of 62` right-aligned in the input row** | a mode caption: `Search tabs   ( > command  : go to line  ? help )` |
| Footer | a **persistent dimmed hint row**: `: 124 go to line · type a number` | none; `?` is a separate mode you must know to type |
| Selected row | a **subtle raised fill** | **a bright accent fill** — see below |
| Rows | category **and** accelerator right-aligned (`View  Alt+Z`) | same ✓ |
| Match accent | on matched characters ✓ | same ✓ |

**Regression I introduced today (v0.68.0):** the palette's selected row is now the accent fill with
`bg_base` text. That is §6's rule **for menus**, which I extended to the palette; §7 never asks for
it and the mockup shows a subtle selection. The menu mockup *does* show the accent fill (`Settings`
row), so the rule is right where it came from and wrong where I took it. **Revert the palette to a
raised fill.**

### Menus

- **`Show Menu Bar` row is missing** (already tracked as B15).
- `Find: Regex` + **`Ctrl+R`** in the mockup vs `Find: Regular Expression` + **`Alt+R`** built —
  label *and* chord differ.
- Mockup has no `Open Themes Folder` row; built has one.
- Zoom In reads `Ctrl+=` in the mockup, `Ctrl++` built.

### Find / Replace / Filter — structurally different, and the biggest visual gap after the palette

| | Mockup | Built |
|---|---|---|
| Query | a **bordered input box** with an accent border | flat text: `Find: _` |
| Count | **`3 / 349`** beside the field | not shown |
| Chips | `Aa` `ab|` `.*`, **active one filled** | present but unstyled, far right |
| Controls | **`↑` `↓` buttons, `Filter Ctrl+L`, `✕` close** | none |
| Replace | **`Replace` and `All 349` as buttons** | keyboard hints as text |
| Filter banner | `FILTER context 249 of 778 lines` + right-hand hint `Ctrl+L shows the whole file · ↑↓ moves · Enter jumps there`, then numbered rows with the match highlighted | banner exists; needs checking against this form |

### Status bar — BLOCKED on an open HIGH, do not start with this

Adding the mockup's missing cells (`42.1 KB`, the language cell, `Tab 4`) means adding rows to a
group whose **draw and hit-test already disagree**: the 2026-08-04 audit found that the bar drops
right-hand cells from the *draw* on a narrow window while `status_cell_at` still walks all of them,
so a click lands on a cell that is not there and fires `.Eol_CRLF` — a whole-buffer rewrite
([06-ui-shell.md](../audits/2026-08-04/06-ui-shell.md)).

**Every cell added widens the blast radius of that bug.** Fix the drop/hit-test mismatch first, then
add cells. Sequencing recorded here so this is not discovered halfway through.


| | Mockup | Built |
|---|---|---|
| Left | `Ln 124, Col 94` · `778 lines` · **`42.1 KB`** | `Ln 41, Col 544` · `155 lines` |
| Right | **`Markdown`** · `UTF-8` · `LF` · **`Tab 4`** | `Markdown Split (Ctrl+M)` · `UTF-8` · `CRLF` |
| Saved | a **cell** reading `Saved` | a centred transient notice |

Two new findings beyond B19: **the file-size cell does not exist**, and the right group shows the
**view name** where the mockup shows the **language**.

### Font screen (§11.1)

| | Mockup | Built |
|---|---|---|
| Title | breadcrumb **`Settings › Editor font`** | `Font` |
| Values | right-aligned and bracketed: **`‹ Monaspace Neon ›`** | left-ish, `Cascadia Mono   ‹ ›` |
| Rows | Family / Style / Size / **`Ligatures NEW`** | Family / Style / Size |
| Preview | pangram + glyph line + **a syntax-highlighted code sample** (`"sqlReaderQuery": "SELECT TOP (1000)"`) | pangram + glyph line only |
| Label | `PREVIEW` | `Preview` |

### Settings (§11)

Group headers (`SESSION` / `APPEARANCE` / `VIEWS`) still absent — already tracked as B14. Row
layout, descriptions and right-aligned values otherwise read close to the mockup.

---

## Scale, stated honestly

This is not a finishing pass. The find bar alone wants a bordered input, a live count, two arrow
buttons, a close button and two real buttons on the replace row — **none of which exist as widgets
anywhere in the product**, because nothing in Newtpad has ever drawn a button. That is a new
primitive, and CLAUDE.md's one-layout rule means it needs a single `*_layout()` producer feeding the
draw, the hit-test and the hover before any of it is drawn.

**The honest read: the UI rework Wyatt gated V1 on is this, and the two batches so far were its
prose-shaped prologue.**
