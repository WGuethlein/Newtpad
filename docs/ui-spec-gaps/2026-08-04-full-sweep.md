# The full mockup sweep — all 19 sections

Run 2026-08-04, after the partial lists. **This supersedes the per-surface state table in
[README.md](README.md) and the "Scale" section of [2026-08-04-visual-gaps.md](2026-08-04-visual-gaps.md).**
Where this file and those disagree, this one was built by opening every section's mockup and putting it
beside the running binary; they were built from five screenshots and, in two places, from prose.

## Method, so the next session can judge it

- **Mockups:** the HTML was loaded in a live browser and each section's DOM extracted with its inline
  styles — exact labels, hex colours, px metrics, font family per element. That is stricter than
  eyeballing a screenshot, not looser. The method was calibrated on §13 first: it reproduced every
  finding `visual-gaps.md` already had, *and* four it did not, before being trusted on the other 18.
- **As-built:** `src/program/*.odin` read per surface, plus `build/newtpad.exe` launched with
  `NEWTPAD_SESSION_DIR` pointed at a temp dir and captured surface by surface (editor, markdown split,
  find bar, palette, table view, View menu, theme tab).
- **Not covered:** §3's DPI checklist (8 items) and §14 (10 GB perf) are verification tasks, not
  mockup diffs, and were not run. §19 is reference. Counted separately at the bottom.

---

## Decisions taken on this sweep (Wyatt, 2026-08-04)

**C4. Monaspace Argon is rejected. Chrome stays monospace.** The spec's two-family split (§2) does not
ship. Consequences: the "Chrome family" and "font embedding" items are struck, §2's 13-row type-role
table is a rejected section rather than owed work, and **§13's "numbers in Neon, words in Argon" rule
dies with it**. The `ui_font_family` setting and the `.UI` font slot stay — they still let the chrome
use a different *monospace* face from the document. Total drops 59 → **56**.

**C5. `Open Themes Folder` stays**, though the §6 mockup has no such row. A shipped affordance is not
removed to match a picture.

**C6. Regex keeps `Alt+R`; only the label shortens to `Find: Regex`.** Verified rather than assumed:
all three find toggles are Alt chords (`commands.odin:512-514` — `Alt+R`, `Alt+C`, `Alt+W`), and that
is also what VS Code's find widget uses (Alt+R / Alt+C / Alt+W). The mockup's `Ctrl+R` is the outlier,
and moving one of three sibling toggles off Alt would break the set. Mockup wins on the label, loses on
the chord.

**Approved, and in the polish batch:** drop the gear icon at the menu bar's right end; add the
mockup's `│ Commands  Ctrl+P` item there in its place.

**Left as built:** the `>_` button stays at the left of the tab rail. See the note under §4 — it and
the menu-bar `Commands` item are two different controls, not one.

---

## Four corrections to the existing docs

These matter more than any single gap, because two of them are load-bearing for the chosen work order.

### 1. Newtpad HAS a button primitive. It has had one since 2026-07-28.

README: *"Nothing in Newtpad has ever drawn a button."* `visual-gaps.md`: *"none of which exist as
widgets anywhere in the product, because nothing in Newtpad has ever drawn a button."*

Both are wrong. `find.odin:269-369` defines `Find_Action` — a labelled box with its chord, carrying
box origin, label origin and chord origin — plus `find_actions()` as the single producer and
`find_action_at()` as the hit-test. `main.odin:2582-2599` draws it with a hover fill; the frame loop
takes the click and the pointer cursor from the same call. It lands the ⌘6j discipline exactly:

> `find_actions` is the only procedure in the program that computes a coordinate on this row, and the
> draw, the click, the hover fill and the pointer cursor all consume what it returns.

It even drops the buttons rather than clipping them when the row gets narrow, and `test_modes.odin`
has seam tests for that at 9610-9733. Commit `cf6d711`, *six days before* the gap docs said it didn't
exist.

**Consequence for the work order:** item 2 is not "build a button primitive from nothing." It is
"promote `Find_Action` out of find.odin into a shared control, and add the four controls the find bar
still lacks." That is a materially smaller and lower-risk job than the README quotes it as.

### 2. The find bar is not "untouched," and it is not the largest gap.

`visual-gaps.md` records the count as "not shown" and the chips as "present but unstyled." Both are
wrong: `find_status_info()` (find.odin:1910) returns `(3/349)` and colours it `Danger` at zero
matches, and `find_toggles()` gives the active chip an accent fill with `Bg_Base` text
(main.odin:2550-2556) — which is what the mockup shows. Verified in the running app.

What the find bar actually still lacks is listed under §12 below: six items, four of them small.

### 3. There is a THIRD decided exception to "mockup wins," and it is not recorded here.

`theme.odin` ships `scrollbar_thumb #746B61`, not the spec's `#3E3833`, with this reasoning:

> `#746B61`, 3.14:1 against Bg_Base — NOT the UI spec's `#3E3833`. That value is annotated "3.0
> against bg_base" in the spec and does not measure it: `#3E3833` computes to 1.42:1, less than half
> the claim.

That is the same shape as C1 and C2 — the spec argues rather than describes, and loses on the
argument. It belongs beside them as **C3** so nobody "fixes" it toward the spec later.

### 4. The spec contradicts itself on the palette width, and the build already picked right.

§2's metric table says `palette panel 520 wide`. §7's mockup renders it at **560**. The build is 560,
per "mockup wins." Recorded so it is not re-opened as a bug.

---

## The largest gap in the product was on nobody's list

**§2: the chrome is drawn in the document's monospace face.**

The spec asks for two families by one designer: **Monaspace Neon for the document, Monaspace Argon
(proportional) for all chrome** — and says plainly what it buys:

> Monaspace Argon for chrome, which is the single change that most removes the developer-tool feel.

Every mockup in the document honours this. Tab labels, menu items, settings rows, palette rows and the
status bar's *words* are proportional; only numbers, accelerators and tabular data stay mono. In the
running app **every one of those is Cascadia Mono**, confirmed in the captures.

The plumbing is already there — `settings.odin:64` has `ui_font_family`, `main.odin:330` loads it into
a `.UI` font slot, and there is a settings row for it. It defaults to `"Cascadia Mono"`, and
`settings.odin:61` says why:

> FONT_FAMILIES. The UI spec asks for Monaspace Argon here; embedding a font […]

So this is one deliberate deferral away from being the highest-leverage change available: it alters
**every surface in the product at once**, and no per-surface fix substitutes for it. It is why the app
"looks completely different in some parts" in a way the per-surface lists could not explain — they were
all comparing labels and colours, which mostly match, while the letterforms never did.

---

## The preview vs Obsidian — Wyatt, 2026-08-05

He put our markdown preview beside Obsidian's on the same document and said ours *"looks significantly
worse… it 1000% needs to be retouched"*. He was right, and the gap is **three concrete things, not a
vague quality difference**. Diagnosed rather than eyeballed:

### 1. A fence with no resolved lexer renders in the PROPORTIONAL SERIF body face — a bug

`md_layout_build`'s `.Fence_Body` case sets `px`, `lead` and `base_col` but **not `fallback_set`**, which
defaults to `plat.Font_Set.Body` at the top of the proc. Only `.Table` overrides it. The mono, coloured
span path (`set = .Doc` + `syn_*` per token) is gated on `fence_lex != nil`, so:

- a fence whose language HAS a lexer → mono, syntax-coloured, correct;
- a fence whose language does not → **proportional serif, one flat colour**.

Inline code is unaffected (correctly mono), which is why the two disagree in the same paragraph. Code in
a proportional face is the single biggest reason his screenshot looked unlike Obsidian's.

### 2. ` ```powershell ` resolves no lexer, though the lexer exists

`md_fence_lexer` maps aliases → extension: `js`→`c`, `bash`→`sh`, `yml`→`yaml`, `csharp`→`cs`, `c++`→`cpp`.
There is **no `powershell`/`pwsh` → `ps1`**, and `EXT_LEXERS` carries a real PowerShell lexer at `.ps1`
(`lex_shell_ps1_adapt`, stateful, `#>` resync). So every ` ```powershell ` block — which is most of what
his deploy docs contain — falls into case 1 above and gets neither the mono face nor the colours that
are already implemented and already tested.

### 3. No language label on the fence

§9.2 item 4's preview column asks for *"6px radius block, 12px padding, lang label"*. The block and the
radius ship; the label does not.

### Cost, which is the part worth knowing

**1 and 2 are roughly two lines between them** — a `fallback_set = .Doc` in the `.Fence_Body` case, and
one `case "powershell", "pwsh": tag = "ps1"` arm. Together they turn his screenshot's flat serif blocks
into mono, syntax-coloured ones using machinery that already exists.

Wyatt deferred this behind the queued batches on the assumption it was a retouch. **It is mostly a
two-line fix plus a genuine polish tail** (the lang label, padding, and whatever spacing comparison
survives after the face is right). Flagged so the scheduling call can be made against the real cost.

## Per section

Tags: **[V]** visual divergence in something that exists · **[F]** feature absent · **[✓]** matches ·
**[D]** already decided, do not change.

### §1 Theme files — 6 items
The shipped `Dark Custom.theme` matches §1.1 **value for value** (read off the running app's own theme
tab): `bg_base #221F1C`, `bg_panel #1C1917`, `bg_raised #2B2724`, `bg_hover #302B27`,
`border_subtle #322D28`, `border_strong #4A4339`, the full text ramp, `accent/caret/focus_ring
#D99B62`, `accent_wash #302823`. The warm palette landed. *(The role-enum comments in `theme.odin`
still narrate the old cool-grey values — they are harvest history, not current state. Do not read them
as the palette.)*

- [D] `scrollbar_thumb` deviates deliberately — see correction 3.
- [F] `md_bold` and `md_list_mark` roles absent; folded into existing roles by an explicit decision at
  `theme.odin:300-305`. Spec wants them separable. Low.
- [F] No third (high-contrast) theme. §17: *"Ship three, not one."*
- [F] No `SPI_GETHIGHCONTRAST` override.
- [F] No "Follow Windows" theme choice (settings offers Dark / Light / custom only).
- [F] No 20px colour swatch in the gutter of an open `.theme` tab — confirmed absent in the capture.

### §2 Metrics & type — 3 items
- ~~[F] **Chrome family: Argon.**~~ **STRUCK by C4.**  See above. *The single highest-value item in this document.*
- ~~[F] Font embedding (~1.1 MB, four faces) with Consolas fallback.~~ **STRUCK by C4.** 
- ~~[V] Per-role type scale — the spec names 13 distinct role/size pairs.~~ **STRUCK by DECISION
  (Wyatt, 2026-08-05): keep the two sizes** (`UI_PX` 15, `UI_SMALL_PX` 13). The 13 pairs were largely
  how §2 distinguished chrome roles inside one PROPORTIONAL family; with C4 rejecting Argon most of
  that distinction is gone, and 13 sizes in one monospace face reads as noise.
- [✓] Chrome metrics that already match: 40px rail, 30px tab, 132/220 tab clamp, reserved 8px dirty
  slot, 30px menu bar, 26px status bar, 28px menu row, 30px palette row, radii set.

### §4 Window shell — 4 items
> **The mockup has TWO command affordances, not one.** A `>_` button (26×26, radius 5, Neon) in the
> 40px tab rail, *and* a separate `│ Commands  Ctrl+P` item at the right end of the 30px menu bar —
> the menu bar's full text is `File Edit View Encoding Help │ Commands Ctrl+P`. Newtpad ships the
> `>_` (at the left of the rail) and a gear icon where the mockup puts `Commands`.

- ~~[V] The `>_` sits at the **far left** of the rail~~ **LEFT AS BUILT (not approved).** ; the mockup puts it right of `+`, immediately
  before the caption buttons. **[C] Left as built for now** — reposition not approved.
- ~~[F] No `Commands  Ctrl+P` item (with its 1px separator) at the right end of the menu bar.~~ **SHIPPED v0.74.0.** 
  **Approved.**
- ~~[V] The gear icon at the menu bar's right edge appears in no mockup.~~ **SHIPPED v0.74.0.**  **Approved for removal**, with
  `Commands` taking its place.
- [✓] Pill tabs, radii, per-tab `✕`, `+`, reserved dirty slot, caption buttons all match.

### §5 Narrow windows — 2 items
- ~~[V] Overflow is a `+N` indicator that opens the palette's tab list.~~ **DECIDED (Wyatt, 2026-08-05):
  the `+N` stays**, the mockup's `‹` `›` scrolling rail is not built. One click reaches any tab by name
  and by typing, which beats chevron-scrolling to hunt for one visually, and it reuses a surface that
  already scrolls and filters.
  **And it did not work — fixed in v0.87.0.** *"+N but currently it doesn't work"* (Wyatt, live use), and
  it never had: `WM_NCHITTEST` returns `HT_CLIENT` only for `x < win.tabs_right`, `tabs_right` walked the
  drawn tabs and the `+` button, and when tabs overflow BOTH of those are placed inside `limit - over_w`
  — entirely to the LEFT of the indicator. The count is drawn only when tabs overflow, which is exactly
  when it sat in the OS drag region: at 320px with three tabs the client region ended at 76 while the
  indicator spanned 130..182. **A decision the register recorded as open was also a live bug, and the
  register could not have seen it — it compares pictures.**
- ~~[F] The `>_` drop at 460px and the menu-bar → `☰` collapse at 360px.~~ **SHIPPED v0.77.0 (360px; the 460px `>_` drop is still open).**  The `☰` metric exists
  (`ui_tabs.odin:50`); the behaviour rides on Show Menu Bar.
- [✓] 318px floor honoured. Status cells drop at ~700px, and they drop by **measuring** the left
  group rather than against a hardcoded breakpoint — better than the spec asks for.

### §6 Menus — 4 items
14 prose rules met; panel, rows, dividers, check column, accent keyboard selection all match.
- ~~[F] `Show Menu Bar` row + `Alt` accelerator (B15).~~ **SHIPPED v0.76.0.** 
- ~~[V] `Find: Regular Expression` / `Alt+R` built vs `Find: Regex`~~ **SHIPPED v0.74.0 (label; chord kept by C6).**  / `Ctrl+R` in the mockup — label
  *and* chord.
- ~~[V] `Zoom In  Ctrl++` vs the mockup's `Ctrl+=`.~~ **SHIPPED v0.74.0.** 
- ~~[V] `Open Themes Folder` exists; the mockup has only `Open Logs Folder`.~~ **KEPT by C5.** 
- [D] C1 (`Toggle` verb dropped) and C2 (disabled row shows its reason) — confirmed correct in the
  running app, leave them.

### §7 Command palette — 3 items
Rebuilt to the mockup: `>` prompt, subtle raised selection (the accent-fill regression **is** reverted
— verified), dimmed legend footer, 560 wide.
- ~~[F] **No scroll.** `PALETTE_MAX_ROWS` truncates~~ **SHIPPED v0.81.0.** , and the audit's HIGH — selection walking past the
  drawn rows — is the same bug. Open.
- [V] Footer reads `> command · : go to line · ? help`; the mockup shows a live
  `: 124   go to line · type a number`.
- [F] `Unwrap Selected Lines` and `Reflow Paragraph at Wrap Column` appear as ordinary palette rows in
  the mockup and exist nowhere in the product.

### §8 Editor surface — 1 item
Closest section to done. 16px top padding, 2px caret, find-match vs current-match fills, gutter off by
default, 8px scrollbar with accent tick marks — all present in source.
- ~~[V] Confirm gutter is 44px + 12px gap when enabled (spec §2)~~ **STRUCK -- derives from the line count, better than a fixed 44.**  — not visually verified this pass.

### §9 Markdown — 6 items (**smaller than expected, but with one real defect**)
The expectation that §9 would outweigh the find bar was half right: it is the biggest *section*, but it
is also the most built. The split view renders a **proportional serif preview** with h1/h2 at scale
plus their rules, real bold and italic faces, nested lists, a blockquote bar, task checkboxes, thematic
breaks, links and `Ctrl+M` cycling three states. §9.3's serif is honoured.

> **Correction, 2026-08-04 — four of these six were wrong, the same way §10's were.** Called from a
> downscaled capture; re-checked at 1:1 with a 5× zoom and against the producers. The spec's own
> values are *deliberately subtle* — `md_code_bg #2A2723` on `bg_base #221F1C` is an 8/8/7 difference —
> so "I can't see it in a screenshot" is not evidence of absence. **Verify at full resolution, or read
> the draw.**
>
> | Claimed | Actually |
> |---|---|
> | Inline code has no fill | `markdown.odin:5670` draws a rounded `Md_Code_Bg` box behind it, and it is plainly visible at 1:1. Fences use it too (`5571-5612`). |
> | Bullets are not `•`/`◦` | `markdown.odin:2511` — the `•` literal, drawn in accent. Correct at 1:1. |
> | Blockquote bar reads muted | The bar is there and coloured; §9.4's mockup is accent, the build reads quieter. Real but cosmetic, kept below. |
> | Done text not dimmed | It is — `read` renders in `Text_Muted` beside the blue `v1.json` link. |

Remaining, all verified at 1:1:
- ~~[V] **The ticked checkbox is an accent-*outlined* box containing `✕`.**~~ **SHIPPED v0.77.0.**  §9.2 item 9 and §9.4's mockup
  both want an accent-**filled** 14px box with a dark `✓` (`bg=#d99b62 fg=#221f1c r=3px`). The 14px
  box (`m.task_box = sx(14)`) and the dimmed done-text are already right; only the fill and the glyph
  are wrong. Small.
- ~~[V] **The preview's table is text-with-rules, not the mockup's card.**~~ **SHIPPED v0.82.0.**  It *does* render — header,
  a `md_rule` under it, column separators, code chips inside cells — so "renders broken" was an
  overstatement. What it lacks is §9.4's bordered card: `1px #3a342e` at `radius 6` around the whole
  table, a `bg_raised` 26px header row, and no full-height vertical rules. Also a wide gap between the
  header rule and the first body row. This is the **markdown-table job**, not polish.
- [V] Blockquote bar → accent (§9.4 shows 2px `#d99b62`).
- [F] Deferred tier untouched: YAML front-matter card, footnotes, image placeholders, setext headings.

### §10 Table view — 2 items (**corrected 2026-08-04 — three of the five were wrong**)

> **Correction.** The first draft of this section claimed zebra striping, sorting and the header band
> were missing. All three ship. They were called absent from a screenshot of a 3-row fixture, which is
> exactly the mistake this whole document exists to stop — *"a spec with mockups is not read by
> reading its prose"* has a twin, and it is that an app is not read by squinting at one capture.
> Verified instead by sampling pixels and reading the producer:
>
> | Claimed | Actually |
> |---|---|
> | No zebra | `table.odin:3971,4140`. Sampled the capture: row 4 is `#262320` (`Table_Zebra`), rows 1 and 3 are `#221F1C`. It keys off `table_row_band` — the **absolute** row number, so the stripe survives sorting — and the row fill and the gutter fill both read it, so they cannot disagree. The reason it looked absent is that `#262320` on `#221F1C` is a 4/4/3 difference: **the spec's own value**, and nearly invisible. |
> | No sorting | `table.odin:961+`. A view-only permutation over row offsets with `table_row_start` as its single producer, an accent header arrow (`4259`), and `tablesorttest` covering ~16 cases. |
> | Weak header band | `table.odin:4182,4314` draw `Bg_Raised`, and `4321` draws the 1px `Border_Strong` rule §10 asks for, deliberately last so it survives descenders. |

Remaining:
- ~~[V] Columns do not fill the pane~~ **STRUCK by DECISION (Wyatt, 2026-08-05): leave the slack.** A
  4-column CSV stretched across 1280px puts huge gaps between related values and reads worse; the 8-40
  character clamp already does the useful part. The original entry, for the record: §10's rule, as
  quoted in `markdown.odin:548`, is *"measure the first 200 rows, clamp each column to 8-40
  characters, distribute leftover width proportionally"*, and the mockup's columns are `fr` units that
  fill. **Unverified whether the code intends the slack**, and it is arguably right not to stretch a
  4-column CSV across 1280px. Needs a decision, not a fix.
- ~~[F] Malformed rows are not marked with a `warning` bar.~~ **STRUCK -- table_row_malformed draws it.**  *(A warning fill does exist at
  `table.odin:4142` — confirm what triggers it before counting this as owed.)*

### §11 Settings + §11.1 Font — 9 items
- ~~[F] Group headers `SESSION` / `APPEARANCE` / `VIEWS` (B14).~~ **SHIPPED v0.78.0.** 
- ~~[F] `Show menu bar` row; [F] `Animations` / reduce-motion row.~~ **SHIPPED v0.76.0 (Show menu bar; Animations still open).** 
- [F] `NEW` badges, and the dimmed accent bar the mockup gives a NEW row.
- ~~[V] Header hint row omits `←→ adjust` and spells the arrows as words.~~ **SHIPPED v0.77.0 (the fourth key; arrows still spelled).** 
- [V] Confirm the selected row uses `accent_wash` + a 2px accent bar (role exists; not visually
  verified — Settings did not open in the capture pass).
- §11.1 — **corrected 2026-08-04, three of five were already built** (`fontpage.odin:55-68,105`): the
  breadcrumb `Settings › Editor font` ships, `PREVIEW` is already caps, and the values are already
  right-aligned and bracketed by their chevrons. Each has a comment citing the 11.1 mockup, so they
  were built *from* it. Remaining: [F] `Ligatures` row (needs DirectWrite font-feature plumbing) and
  [V] a syntax-highlighted code sample in the preview.

### §12 Find / Replace / Filter — 6 items
Already built: three chips with the active one accent-filled, a live count with `Danger` at zero, and
two real replace-row buttons with hover and a narrow-window drop. See correction 2.
- ~~[V] The query is flat text (`Find: the_`).~~ **SHIPPED v0.75.0.**  Mockup: a **bordered input**, `bg_base`, radius 6, 26px,
  with a 2px inset accent ring.
- ~~[V] Count reads `(1/5)` inline; mockup is `3 / 349`~~ **SHIPPED v0.75.0.**  right-aligned in a 62px column.
- ~~[V] Chips sit at the far right~~ **SHIPPED v0.75.0.**  (`winw - 12 - 3*(w+gap)`); mockup places them straight after the
  count, then a separator.
- ~~[F] `↑` `↓` step buttons (24×24).~~ **SHIPPED v0.75.0.** 
- ~~[F] `Filter  Ctrl+L` pill.~~ **SHIPPED v0.75.0.** 
- ~~[F] `✕` close button.~~ **SHIPPED v0.75.0.** 
- [V] Also: 46px `Find` / `Replace` label column; bar is `Bg_Panel` where the mockup is `bg_raised`.
  *(Corrected 2026-08-04: an earlier draft of this file said the bar was ~30px against the mockup's
  38px, estimated from a screenshot. `FIND_BAR_H_96 :: f32(38)` at `doc.odin:992` — **the height
  already matches**. Measure the constant, not the pixels.)*

### §13 Status bar — 7 items
Seam fixed (the drop lives in `status_cells`), and the selection count already replaces the line count
exactly as §13 asks — verified live (`Ln 3, Col 22   3 selected`).
- ~~[F] `42.1 KB` file-size cell. [F] Language cell~~ **SHIPPED v0.74.0 (all three cells).**  — the right group shows the **view name**
  (`Markdown Split (Ctrl+M)`) where the mockup shows `Markdown`. [F] `Tab 4` cell.
- ~~[F] `Saved` as a **cell** in `success`; today it is a centred transient notice.~~ **SHIPPED v0.87.0.**
- ~~[V] The left group is one text run; the mockup is three cells, each `padding 0 12px` with a 1px
  `border_subtle` on its left edge~~ **SHIPPED v0.87.0.** *(The parenthetical it used to carry — "the first cell in each group has none" — was WRONG. The mockup DOM gives the right group's
  leading cell a `border-left` too; the rule is "every cell but the bar's very first".)*
- ~~[V] **Numbers in Neon, words in Argon**~~ **STRUCK by C4 (Argon rejected).**  — a two-font rule *inside* the bar. Blocked on §2.
- ~~[F] Errors take the whole bar in `danger`.~~ **SHIPPED v0.87.0** — and it replaced the modal message
  box a failed save used to put up, which is the dialog §13's "nothing in this app should ever need a
  modal dialog" is aimed at.
- ~~⚠ `status_cells` guards on `len(out) < 2` and callers pass `[4]Status_Cell`.~~ **STRUCK — stale
  since v0.77.0 (§6cq).** It takes a fixed-array POINTER, so an undersized buffer is a COMPILE error at
  every call site. The warning survived four re-counts of this document unchecked.

### §15 The empty tab — 0 items
`main.odin:2252` carries exactly the spec's three hints (`Ctrl+O open a file`, `Ctrl+P commands`,
`drop a file anywhere in this window`), with the caret and no logo/welcome/recent grid. **Done.**

### §16 Icon — 1 item
No icon work exists. §16 names **16a "Caret on paper"** as recommended and gives full geometry at
96/48/32/16px with its palette (paper `#F2EBE0`, accent caret `#D99B62`, two `#B3A897` lines, one
`#CDC3B4`). Plus the `.ico` size set a shipped product needs.

### §17 Themes & colour rules — 3 items
- [F] Contrast warning on save — check six named pairs, warn once, never clamp.
- [F] Surface "N colour rules inactive on this file" when the lexer wins (Rule 3).
- [F] Validate `Bg_*` roles on save and hide them from the rules docs.

### §18 Motion, focus, accessibility — 4 items
- [V] **The focus ring exists and is correct** — `ui_tabs.odin:77-98`, 2px in `Focus_Ring`, 1px
  outside, radius-matched. But it is drawn **only for tabs**. §18 wants it on menu-bar items, menu
  rows, palette rows, settings rows, find fields and toggles, table headers, the `>_` button, caption
  buttons and the split divider. Extending it is the natural companion to promoting `Find_Action`.
- [F] The 50ms motion table (5 places) — deliberately out, paired with the reduce-motion setting.
- [F] Reduce-motion setting + `SPI_GETCLIENTAREAANIMATION`.
- [F] Gamma-correct text blending — unverified; if absent, every measured ratio in §1 is optimistic.

---

## The total

**Re-counted 2026-08-05 after v0.74.0–v0.85.0.** Every shipped or struck bullet in the sections above is
now struck through and stamped with the version that closed it, because the first re-count updated only
the totals and left the per-section lists reading like pre-v0.74 state — a document that would have had
the next session redo shipped work, which is the exact failure this whole register exists to stop.

The figure has moved **twice, both times downward**, and the reason was the same each time: items filed
from *reading* rather than *checking*. **Quote the current number, not a remembered one, and re-verify
before starting anything on this list.**

| | Count |
|---|---|
| Shipped v0.74.0–v0.85.0 | **21** |
| Struck as already built (verified) | **13** |
| Struck by decision (C3–C6) | **6** |
| **Remaining** | **~24** |

Remaining, by weight rather than by count:

- **§1 theme** ×4 — third (high-contrast) theme, `SPI_GETHIGHCONTRAST`, "Follow Windows", the `.theme`
  tab's colour swatches.
- **§17 colour rules** ×3 — contrast warning on save, "N rules inactive on this file", `Bg_*` validation.
- **§18** ×3 — extend the focus ring past tabs, the 50ms motion table, the reduce-motion setting.
- **§11** ×4 — `Animations` row, `NEW` badges, `Ligatures`, a syntax-highlighted code sample on the font
  page. Plus one **unverified**: does the selected row use `accent_wash` + a 2px bar?
- **§9** ×2 + **3 deferred** — blockquote bar to accent, the deferred markdown tier (front matter,
  footnotes, images, setext); and the fence face / `powershell` alias / lang label Wyatt deferred.
- **§7** ×2 — the footer's live form, and two palette rows the mockup shows that do not exist
  (`Unwrap Selected Lines`, `Reflow Paragraph at Wrap Column`).
- **§13** ×3 — `Saved` as a cell, the left group as three bordered cells, errors taking the whole bar.
- **§16** ×1 — the icon (16a "Caret on paper", geometry and palette both specified).
- **Three needing a DECISION, not work:** §5's `+N` overflow vs the mockup's `‹ ›` scrolling rail;
  §10's columns not filling the pane; §2's per-role type scale, now that Argon is struck.

**And two bugs the sweep could never have seen**, both found by checking rather than reading: the font
scan's 431 MB temp arena and the palette drawing labels a byte at a time. Neither was a mockup
divergence. **A visual register is not a bug list.**

## What this changes about the queue

Wyatt's chosen order was status-bar cells → button primitive + find bar → Show Menu Bar. The sweep does
not overturn it, but it changes two of the three and adds a candidate above them:

1. **§2's chrome font is the highest-leverage change in the document** and was on no list. It is a
   settings default plus font embedding, not a rewrite. Every surface improves at once. Worth deciding
   before the per-surface work, because a lot of the polish items get re-measured after it lands.
2. **Status-bar cells** — unchanged, still small, still gated on growing the `[4]Status_Cell` buffer.
   Its two-font rule (numbers Neon, words Argon) is blocked on item 1.
3. **The find bar is smaller than believed and the primitive already exists.** The job is promoting
   `Find_Action` to a shared control + four missing controls, not greenfield work.
4. **Show Menu Bar** — unchanged, and it also unlocks §5's `☰` collapse.
5. **New candidate: markdown tables.** §9's table rendering is the worst-looking single defect in the
   product right now, and §9 was expected to be a large hole when it is in fact nearly done apart from
   this. Small fix, disproportionate visual payoff.

## One thing left unresolved

Screen captures showed a thin band at the very top and bottom edges of the window that did not match
the surrounding chrome. `DwmGetWindowAttribute(DWMWA_EXTENDED_FRAME_BOUNDS)` returns the same rect as
`GetWindowRect` (no invisible border to explain it), but the band appears **above the tab rail** too,
which Newtpad cannot be drawing. Most likely an overlapping always-on-top window during capture.
**Not counted as a defect — unproven either way.** If it shows up in normal use, it is real; a
screenshot from Wyatt's own session would settle it in one look.
