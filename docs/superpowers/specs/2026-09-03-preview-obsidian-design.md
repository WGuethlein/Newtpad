# The markdown preview, rebuilt against Obsidian (C7)

**Date:** 2026-09-03 · **Branch:** `fix/preview-inert` → to be branched for this work
**Decision authority:** C7 (`docs/ui-spec-gaps/README.md`) — *the markdown preview is measured against
Obsidian, and Obsidian wins where it and §9 conflict.* Pre-release blocker, not polish.

Wyatt, 2026-09-03, on what "like Obsidian" means:

> it should look like we ripped the viewport out of obsidian and dropped it into newtpad respecting
> the colors/etc of the theme

and on the scroll:

> the scroll is weird, it's blocky… it should be smooth. overall its like a 5 year olds rendition of
> the feature

So: **Obsidian owns the geometry — type scale, weights, leading, block rhythm, measure, indentation,
padding. Newtpad's theme owns every colour.** Nothing in this document changes a colour role.

---

## 1. Why this can be exact rather than a matter of taste

Obsidian is installed on this machine. `resources/obsidian.asar` contains `app.css` (600 KB,
20,643 lines, unminified), which is the shipping source of its reading view. Every number in §3 was
read out of that file, not inferred from a screenshot.

Extraction, for anyone repeating it — the asar header is four `u32`s, the last being the length of the
JSON directory, and file bodies start at `16 + json-len + offset`:

```python
import json, struct
f = open(r"...\Obsidian\resources\obsidian.asar", 'rb')
_, _, _, jlen = struct.unpack('<IIII', f.read(16))
hdr = json.loads(f.read(jlen).decode('utf-8'))
node = hdr['files']['app.css']
f.seek(16 + jlen + int(node['offset']))
open('obsidian-app.css', 'wb').write(f.read(node['size']))
```

**This is a reading of Obsidian's stylesheet, which is evidence of what it asks the browser for. It is
not a capture of what it draws.** Where the two could differ — letter-spacing, the exact fallback face
that resolves for `--font-default` on this machine — §7 says so, and the plan verifies at 1:1 rather
than trusting the number here.

### 1.1 The target is Wyatt's Obsidian, not stock Obsidian

The comparison Wyatt made was against **his** install, so its configuration is part of the target.
Read from the vault at `C:\Users\Wyatt\Documents\Main\.obsidian`:

| Setting | Value | Consequence |
|---|---|---|
| `appearance.json` → `theme` | `"obsidian"` | **Dark mode.** Newtpad also defaults to Dark, so the comparison is like-for-like and D1's "colours stay ours" costs nothing here. |
| `themes/`, `snippets/` | **empty** | Stock CSS. Every value in §3 is the one in force. |
| no `textFontFamily` override | — | `--font-default` resolves through `ui-sans-serif` → **Segoe UI** on Windows. That is the face D2 should match. |
| `app.json` → `readableLineLength` | **`false`** | **There is no 700 px column and no centring in the Obsidian he is looking at.** Text runs the full pane width with only the 20 px file margins. This is the single most consequential finding here and it rewrites §3.5. |

Checking this was not optional: a spec written against stock defaults would have specced a narrow
centred column as "matching Obsidian" when the thing being matched is full-bleed text.

---

## 2. Decisions taken (Wyatt, 2026-09-03) — do not relitigate

| | Decision |
|---|---|
| **D1** | Obsidian's geometry, Newtpad's colours. The preview adopts type scale, weights, leading, rhythm, measure, indentation and padding; every colour continues to come from the theme. |
| **D2** | **Body prose moves to a sans face — specifically Segoe UI.** §9.3's serif is overruled; this is C7's named exception, and it is the single largest reason the two applications look unlike each other. Segoe UI is not a guess: it is what `--font-default`'s `ui-sans-serif` resolves to on Windows, so it is literally the face Wyatt's Obsidian is drawing (§1.1). It is **already the fourth row of `BODY_FAMILIES`** with all four styles, so W2 is a reorder rather than a font-loading change. |
| **D3** | **The column is a four-state user choice: Full / Left / Centre / Right**, offered as a segmented control in the preview pane's top-right corner. **Full is the default** — see §3.5, it is what Wyatt's Obsidian actually does. The other three apply the measure and place it. |
| **D4** | **Pixels everywhere** — the wheel moves a pixel delta rather than one body line, and Split's sync interpolates within a block rather than jumping between them. **Easing is split out and deferred** to `W7b`: see §4.1, the devil's advocate found it contradicts UI spec §17's `scroll → 0ms` row and the app's one-timer architecture. Wyatt asked for eased scrolling and it is not refused — it is sequenced behind the change that may make it unnecessary. |

---

## 3. The measured target

`S` is the preview's base document size — what `md_metrics` already takes as its parameter. Obsidian's
base is `--font-text-size: 16px`, so an `em` in its stylesheet is `1.0 S` for us, and a `rem` is also
`1.0 S` (its root and its text size are the same 16 px in the reading view).

### 3.1 Type scale

| | Newtpad now | Obsidian | Obsidian's variable |
|---|---|---|---|
| h1 | **1.85 S** | **1.618 S** | `--h1-size: 1.618em` |
| h2 | **1.50 S** | **1.462 S** | `--h2-size: 1.462em` |
| h3 | **1.25 S** | **1.318 S** | `--h3-size: 1.318em` |
| h4 | **1.10 S** | **1.188 S** | `--h4-size: 1.188em` |
| h5 | **1.00 S** | **1.076 S** | `--h5-size: 1.076em` |
| h6 | 1.00 S | 1.000 S | `--h6-size: 1em` |
| body | 1.00 S | 1.00 S | `--font-text-size` |
| inline + fenced code | **0.92 S** | **0.80 S** | `--code-size: var(--font-smaller)` → `0.8em` |
| table text | **0.95 S** | **1.00 S** | `--table-text-size: var(--font-text-size)` |

The shape of the difference: **our h1 is much too large and our h3–h5 too small**, so our scale is far
more contrasty than Obsidian's near-geometric one (each step is ≈1.10× the next). Our code is nearly
body-sized where Obsidian's is markedly smaller, and our table text is smaller where Obsidian's is
full size.

### 3.2 Heading line-height and weight

| Level | Obsidian line-height | Obsidian weight |
|---|---|---|
| h1 | 1.2 | 700 |
| h2 | 1.2 | 680 |
| h3 | 1.3 | 660 |
| h4 | 1.4 | 640 |
| h5 | 1.5 (`--line-height-normal`) | 620 |
| h6 | 1.5 | 600 |

**The graduated weights are not reachable and will not be attempted.** `plat.Font_Set` loads four
discrete faces per family (regular, bold, italic, bold-italic) — there is no variable weight axis — so
every heading draws bold. That is the existing behaviour and §9.3 already specified weight 700 for
every heading. Recorded here so a future reader does not file the 680/660/640/620 ladder as missing:
it is refused, not forgotten.

**The per-level line-heights ARE reachable and are new.** Today every heading uses one leading. A
1.618 S h1 at 1.2 leading is visibly tighter than the same h1 at body leading, and tight headings over
loose body is a large part of Obsidian's texture.

### 3.3 Body leading

| | Newtpad now | Obsidian |
|---|---|---|
| body prose | **1.65 S** | **1.50 S** (`--line-height-normal`) |
| table rows | — | 1.30 S (`--table-line-height: var(--line-height-tight)`) |

Ours is 10% looser. The existing caveat on `Md_Metrics.body_lead` stands: it is a **floor**, not the
leading you get, because the shaper clamps up for a face whose ascent+descent exceeds it. Georgia's is
1.136 em; whichever sans D2 selects has its own, and the plan must re-read `Shaped.line_h` rather than
assume 1.50 S came out the other side.

### 3.4 Vertical rhythm — the biggest structural change

Obsidian's rhythm is **uniform across heading levels**. Ours is graduated per level:

| | Newtpad now | Obsidian |
|---|---|---|
| above h1…h6 | 0 / **1.60 / 1.40 / 1.20 / 1.00 / 1.00 S** | **2.50 S** for every level, when the heading follows a block |
| above a heading opening the document, or following another heading | — | **1.00 S** |
| below h1…h6 | **0.60 / 0.50 / 0.40 / 0.30 / 0.30 / 0.30 S** | **1.00 S** for every level |
| below a paragraph | **0.80 S** | **1.00 S** |
| between list items | **0.25 S** | **0.15 S** (`--list-spacing: 0.075em`, applied top *and* bottom) |
| around a blockquote | 0.80 / 0.80 S | 1.00 / 1.00 S |
| around a fence | 1.00 / 1.00 S | 1.00 / 1.00 S |

The two Obsidian rules that produce this:

```css
h1, h2, h3, h4, h5, h6 { margin-block-start: var(--p-spacing);   /* 1rem */
                         margin-block-end:   var(--p-spacing); } /* 1rem */
.markdown-rendered :is(p,pre,table,ul,ol) + :is(h1,h2,h3,h4,h5,h6) {
                         margin-top: var(--heading-spacing); }   /* 2.5rem */
```

A heading therefore gets **2.5 S above only when preceded by content**, and 1.0 S otherwise. That
conditional is new to us — our `head_above` is a property of the heading alone. It falls out of the
existing margin-collapse machinery *if* the space is modelled as the previous block's `below`, but it
is genuinely a rule about the **pair**, and §5 W1 treats it as such rather than pretending otherwise.

**Margin collapse itself is already correct.** `Md_Metrics`' header documents `max(prev.below,
next.above)`, which is what CSS does and what these numbers assume.

### 3.5 Measure, padding and alignment

| | Newtpad now | Obsidian, as Wyatt runs it | Obsidian with `readableLineLength: true` |
|---|---|---|---|
| measure | **72 ch** of the body face's `'0'` | **none — full pane width** | 700 px (`--file-line-width`) |
| horizontal placement | **pinned left**, `pad_left` 40 px | fills the pane | centred (`margin-left: auto; margin-right: auto`) |
| pane padding | 40 px left only | **20 px all round** (`--file-margins: var(--size-4-5)`) | 20 px all round |

**§1.1 is what decides this: his `readableLineLength` is `false`, so full width is the target and the
default.** The 700 px column is Obsidian's *other* mode, and D3 offers it rather than imposing it.

When a measure IS applied, express it as **`43.75 * S`**, not as a raw 700 px — at Obsidian's own 16 px
base 700 px *is* 43.75 em, and the ratio is what stays correct when the user changes the preview font
size. A hardcoded 700 px would make the column narrower in characters at every size but 16.

**D3's four cases over one measure:**

```
pad    = 20px, DPI-scaled          // all four sides, replacing pad_left's 40
avail  = pane - 2 * pad
column = avail                     if state == Full          <- the default
       = min(avail, 43.75 * S)     otherwise

Full:    x = pad
Left:    x = pad
Centre:  x = pad + (avail - column) / 2
Right:   x = pad + (avail - column)
```

Note **Full and Left produce the same `x` and differ only in `column`** — Full stretches the measure to
the pane, Left caps it. They are not the same state and must not be folded into one: the wrap width is
what differs, and it is what the reader sees.

When `column == avail` — Full always, and the others whenever the pane is narrower than the measure,
which is the usual case in Split — all four collapse to the same geometry and the control has no
visible effect. That is correct, and must not be special-cased into "hide the control when it does
nothing": a control that vanishes when the window is resized is worse than one that is briefly inert.

**`pad_left`'s 40 px becomes a symmetric 20 px pad**, which changes the left edge as well as adding a
right, top and bottom. `m.pad_left` has exactly one reader — **`md_content_span`** (`markdown.odin:4013`),
which is already the single producer of `(origin, pane)` for the whole preview — so this is a contained
change and `md_content_span` is where the four-state placement of D3 belongs. Its two callers hand it
`x0` with `TEXT_MARGIN_X` already added, which is why it can apply the pad without either of them
knowing about it.

#### 3.5.1 The layout cache goes stale unless `column` is resolved OUTSIDE the layout

This is the sharpest finding of the devil's advocate pass, and it would have shipped.

`Md_Slot_Key` is `{block, rev, measure, px, ui_scale, faces}`, and **its `measure` is the PANE, not the
wrap width.** The wrap width is derived *inside* `md_layout_build` as `min(pane, m.measure)`. That is
sound today only because `m.measure` is itself a pure function of `px` and `faces` — both already key
terms — so it cannot move without the key moving.

**W3 breaks exactly that.** Switch Full → Centre at an unchanged window and `pane`, `rev`, `px`,
`ui_scale` and `faces` are all identical, while the wrap width changes. The cache would hand back **the
Full layout for the Centre state**: stale wrap points, stale block heights, and a hit-test resolving
against geometry nothing drew. It is the failure `Md_Metrics.faces`' own comment describes — *"a layout
bakes something that a global can move underneath it"* — one field over.

**The obvious fix is wrong, and the codebase already says why.** The tempting move is to resolve
`column` *before* the layout and pass it as the pane, so the existing `measure` key term carries the
align state for free. `md_content_span`'s own comment (`markdown.odin:4010`) forbids it:

> This also has to be the LAYOUT CACHE KEY, which is the other reason the cap cannot live here: keyed
> on the capped value, a table's layout would not invalidate when the pane grew from 100ch to 140ch,
> because the key never moved.

Passing a capped `column` as the pane reintroduces precisely that: with Centre selected, a pane growing
from 100ch to 140ch leaves `column` pinned at `43.75 S`, the key never moves, and a **table** — which is
exempt from the cap and lays out against the full pane — never re-wraps. That bug was found and fixed
once already; the cap lives inside `md_layout_build`, where the block's *kind* is known, for that
reason.

**So the align state becomes a cache-key term, which is the pattern this struct already has.**
`Md_Metrics`' last section exists for exactly this — its own header says *"the state OUTSIDE this
struct that a block's layout also depends on, sampled ONCE per pass here… All three are cache-key
terms"* — and `ui_scale`, `theme` and `faces` sit there for the identical reason. The align state joins
them, and joins `Md_Slot_Key` and `Md_Max_Key` beside `measure`.

The origin `x` stays **out** of every key: moving a column sideways cannot change how its text wraps,
so it is a draw-and-hit-test term only. `md_block_origin` (three call sites: `markdown.odin:4836`,
`:5601`, `:5635`) remains its single producer.

**W3's test asserts this by pointer identity of the cache entry, not by comparing content** — the bug
is stale reuse, and CLAUDE.md's rule is that pointer identity is what cannot pass with it present.
**Second assertion, against the failure the wrong fix would have caused:** a table at Centre must
re-layout when the pane grows, since it ignores the cap. That one goes red against the mitigation this
section rejected, which is why it is written down rather than assumed.

### 3.6 Blocks

| | Newtpad now | Obsidian |
|---|---|---|
| list indent | 24 px per level | **first level `3ch`; deeper levels `2.25 em`** (`--indent-unit: 0.5625em` × `--indent-size: 4`) |
| bullet hang | — | `-0.8em` (`.list-bullet { margin-inline-start: -0.8em }`) |
| blockquote inset | 16 px per level | **24 px** (`--size-4-6`), bar **2 px** (`--blockquote-border-thickness`) |
| fence padding | 12 px | **12 px vertical, 16 px horizontal** (`--size-4-3 --size-4-4`) |
| fence radius | 6 px | **4 px** (`--radius-s`) |
| fence min-height | — | 38 px |
| inline code radius | 3 px | **4 px** (`--radius-s`) |
| inline code padding | — | **0.15 em × 0.3 em** |
| rule thickness | — | **2 px** (`--hr-thickness`) |
| table cell padding | — | **4 px × 8 px** (`--size-2-2 --size-4-2`) |
| table border | — | 1 px, every cell |

Two of these read as "cheap" at a glance and are worth calling out: **our fence corners are 6 px where
Obsidian's are 4**, and **our inline code has no horizontal padding**, so a code span touches the words
either side of it.

---

## 4. The three bugs, which are separate from the typography

C7 is a look problem. These are not, and two of them are why Wyatt cannot use the preview at all.

### B1 — the preview is inert to the mouse

> i can't drag, right-click, etc, copy, anything on the preview — *Wyatt, 2026-08-06*

**Right-click is confirmed dead by construction, from the source.** `main.odin:987` calls
`plat.window_clear_oneshot_presses(window)`, which zeroes `mouse_right_pressed`; the only reader of
that flag is the table-header branch immediately above it. The preview's press block is 50 lines below.
**There is no preview context menu at all** — this is unimplemented, not broken, and no diagnostic run
is needed to establish it.

**Drag and copy are NOT diagnosed.** The routing at `main.odin:1087` reads correct: `ro` is true in
Preview (`ro_surface_swallows` returns on `md_mode == .Preview` alone), the x-gate is `>= 0` outside
Split, nothing between `CHROME_TOP` and there zeroes `mouse_pressed` for a non-table document, and
`md_preview_pos_at` passes 7-of-7 probes in `mdhittest` against a real offscreen device.

**This is the fourth time a preview bug has hidden in the frame loop, which is the one path this
environment cannot execute.** `NEWTPAD_PREVIEW_DIAG` was built last session for exactly this and has
never been run.

**But W6 is NOT blocked, and filing it as blocked was this spec's own mistake.** The devil's advocate
pass found the precedent already in the repo: v0.86.0 hit this identical wall for the **keyboard** and
solved it structurally rather than by instrumentation. HANDOFF §6cz — the whole per-event decision (the
cell-edit intercept, context priority, `resolve_key`, both `menu_close` rules) became **`key_route` in
`commands.odin`**, which `keytest` and `metricstest` now drive headlessly. Deleting a guard that the
old code needed fails four assertions across two modes.

**The press routing gets the same treatment: a pure `press_route` predicate over the gates, called by
both `main.odin` and a new test mode.** That converts an unreachable bug into a permanently reachable
one — which is the actual fix, since instrumenting the fourth bug does nothing about the fifth. It may
also name this defect without Wyatt running anything.

The diagnostic stays valuable as live confirmation (§7), but it gates nothing.

### B2 — the scroll is blocky

Confirmed from the source, and it is the design rather than a glitch:

- `md_wheel_px` returns `c.m.body_lead` — **one body line per wheel notch**, landing in a single frame.
- In Split, `md_preview_scroll` carries the editor **by block** (§9.4), so the editor pane jumps in
  quanta the size of a whole paragraph or fence.

`Md_Anchor` already carries a sub-block `px` field, so the model can express a pixel position — nothing
is *incapable* of smoothness, it simply never asks for it.

#### 4.1 Why easing is sequenced behind the quanta, and not refused

The devil's advocate pass found two hard constraints that the first draft of D4 walked straight into.

**UI spec §17's motion table names scroll and gives it zero:**

> `everything else — 0ms — caret, `**`scroll`**`, typing, selection, resize, filter results, theme switch, zoom`

**And `main.odin:415` defends the architecture by name:** *"The caret blink is the ONE timer in this
app (UI spec §10)."* The app sleeps 200–1000 ms inside `MsgWaitForMultipleObjectsEx` when idle. Easing
needs a ~16 ms wake for the duration of every gesture — a second timer, running at 60 Hz.

**But "blocky" is a complaint about quantisation, not about the absence of animation.** The blockiness
is one body-line per notch plus whole-block sync quanta, and removing those produces smoothness *at
0 ms latency*, which is what §17 wants and what UI spec line 530 already asks for outright:

> `4. a scroll offset in PIXELS, not lines`

So the pixel half is **owed work, not an invention**, and it is uncontested. Easing is a genuine
addition that costs a spec amendment, so:

- **`W7a` — pixels.** Wheel and sync. No timer, 0 ms, spec-mandated. Ship it.
- **`W7b` — easing.** Deferred, and gated on two things existing first: an explicit amendment of §17's
  `scroll → 0ms` row, and §11's **Reduce motion** setting (`SPI_GETCLIENTAREAANIMATION`, spec line 934,
  re-read on `WM_SETTINGCHANGE`), which is unbuilt and is precisely the control that governs easing.

**`W7a` ships first and Wyatt is asked whether it is still blocky before `W7b` is costed at all.** If
pixel-exact scrolling reads as smooth, `W7b` buys a spec violation for nothing.

#### 4.2 The Split sync overrules a §9.4 rule that has a reason, so it keeps the reason

§9.4: *"**Scroll sync by block, not by line.** Line-based sync drifts the moment a heading or code
fence changes height — the usual reason split views feel broken."*

That reason is still true, so `W7a` does **not** simply switch to pixels. It keeps the mapping
**block-to-block** — which is what makes it drift-proof — and interpolates the **fraction through the
block** in pixels, which is what removes the jump. Both properties, and it is a better rule than
either. Recorded here because overruling a named spec rule silently is how a spec stops being one.

### B3 — the original three fence defects, still owed

From the 2026-08-04 sweep, all still true and all inside this work's blast radius:

1. `md_layout_build`'s `.Fence_Body` case never sets `fallback_set`, so it defaults to
   `plat.Font_Set.Body` — **a fence whose language has no lexer renders in the proportional body
   face.** With D2 that becomes proportional *sans* instead of proportional serif, which is no better.
2. `md_fence_lexer` has no `powershell`/`pwsh` → `ps1` alias, though `EXT_LEXERS` carries a real
   PowerShell lexer. Every ` ```powershell ` block falls into defect 1.
3. No language label on the fence. Obsidian shows one; §9 asks for one.

---

## 5. Work items

Ordered so nothing later invalidates something earlier, and so the branch is shippable if it stops
after any item.

| | Item | Touches | Independent of the diagnostic? |
|---|---|---|---|
| **W1** | Type scale, per-level heading leading, and the vertical rhythm of §3.1–3.4 | `md_metrics`, `md_layout_build`'s heading branch | yes |
| **W2** | Body prose to Segoe UI (D2) — reorder `BODY_FAMILIES`, and re-read the leading floor of §3.3 against the new face's ascent+descent | `platform/text.odin`, `settings.odin`'s curated order | yes |
| **W3** | Symmetric 20 px pad, the `43.75 S` measure, and the four-case column of §3.5 — **Full is the default** | `md_metrics`, `md_block_origin`, the draw and every hit-test that reads it | yes |
| **W4** | The Full/Left/Centre/Right segmented control (D3), **revealed on hover** (§5.1), plus the setting it persists to | new `*_layout()` in `src/ui`, drawn by `program`, `settings.odin`, `session.odin` | yes |
| **W5** | Block geometry of §3.6 — list indent and hang, quote inset, fence and inline-code padding and radius, rule thickness, table cell padding | `md_metrics` and the per-kind draws | yes |
| **W6** | B1 — **extract `press_route`** the way `key_route` was extracted, drive it from a new mode, then fix what it names; plus a preview context menu | `main.odin` press routing, `menu.odin`, `test_modes.odin` | yes — §4 B1 |
| **W7a** | B2 — pixel wheel, and Split sync interpolated within a block-to-block mapping (§4.2) | `md_wheel_px`, `md_preview_scroll`, `md_scroll_px`, the anchor arithmetic | yes |
| **W7b** | Eased scrolling — **deferred**, gated on §17's amendment and on Reduce motion existing (§4.1) | a frame clock, `settings.odin`, `platform/window.odin` | deferred |
| **W8** | B3 — the three fence defects | `md_layout_build`, `md_fence_lexer` | yes |

**W3 is the one with a hit-test seam**, and CLAUDE.md's one-layout rule is the whole risk: the measure
and the column origin are read by the draw, the hit-test, the hover, the cursor and the link rects.
Changing where the column starts without changing all five is exactly the sixteen-bugs-one-shape
failure §6j names. `md_block_origin` is the current single producer of the origin and must stay the
only one.

**W4 belongs in `src/ui`** for the reason `ui` exists: it is pure arithmetic over `f32` and strings, so
`odin test` can reach it without a device. Geometry in `ui`, appearance in `program`.

### 5.1 The control is chrome over content, so it hides until asked for

Principle 2 gives the screen to the content; principle 3 says every added option signals leakage. A
four-state control floating permanently over the text is both, and the devil's advocate was right to
call it.

**It is revealed on hover over the preview pane and is otherwise not drawn** — which is exactly what
Obsidian does with its own in-content controls: `.markdown-rendered pre:not(:hover) > button.copy-code-button
{ display: none }`. Precedent taken from the application being copied.

The *hit region* is unconditional even while the control is invisible — a control that is only
clickable once a hover has been registered loses the first click of every interaction. Drawn on hover;
hit-tested always. This is one `*_layout()` producing both, per the one-layout rule.

---

## 6. How this gets verified

The standing rule applies: **a test that has never failed proves nothing**, so every assertion below is
checked by reintroducing the defect and watching it go red.

- **W1, W3, W5 — `metricstest`.** It already asserts the whole scale is `round(k · S)` in one place,
  which is the right shape; the constants change and the structural assertion does not. Assert the
  *values*, never a tolerance — four assertions with slack admitted defects last session.
- **W3 — a new seam assertion**, and it is the one that matters: for each of Full/Left/Centre/Right, at
  a pane wider than the measure and a pane narrower than it, compare the x the draw uses against the x
  the hit-test resolves from, **and the wrap width each used**. Both terms, because Full and Left share
  an `x` and differ only in `column` — an assertion on `x` alone passes with the two states confused.
  Sabotage by offsetting one side by the alignment delta, and separately by making Full cap at the
  measure.
- **W4 — `odin test src\ui`.** The segmented control's geometry, with no device.
- **W3 — and the cache-staleness assertion of §3.5.1, which is a separate check from the seam one:**
  build at pane `P` in Full, then at the same `P` in Centre, and assert the second did not reuse the
  first's cache entry — **by pointer identity, not by comparing content.** The bug is stale reuse, and
  content comparison can pass with it present.
- **W7a — extend `mdhittest`, or add a scroll mode**: assert that a wheel delta of *n* pixels moves the
  anchor by exactly *n* pixels, and that a Split sync lands the editor at a pixel offset that is **not
  a multiple of any block height**. The second is the assertion that cannot pass with block
  quantisation present, which is the property to aim for over a content comparison.
- **W6 — `press_route` is the test.** Extracted first, driven by a new mode the way `keytest` drives
  `key_route`, with a case per gate. Sabotage by restoring whichever gate the fix moves and watching
  the mode go red. The live diagnostic (§7) confirms; it does not substitute.
- **The whole branch — `modeguardtest` first**, then the modes this change can reach: `mdtest`,
  `mdviewtest`, `mdjointest`, `mdfencetest`, `mdtabletest`, `mdperftest`, `mdhittest`, `splittest`,
  `metricstest`, `linktest`, `blocktest`, `wraptest`, `settingstest`, `menutest`. Sweep what the change
  can reach, not the list this document wrote down — `gutterseamtest` and `rulestest` both went red for
  releases by that mistake. Set `NEWTPAD_SESSION_DIR` to a temp dir first, and check exit codes, not
  just `FAIL`.
- **`mdperftest` carries a measured gate in its exit code.** W1's rhythm change alters block heights and
  W7 changes how often the layout is walked; if that gate moves, it moves for a reason that gets
  written down.
- **Then a 1:1 pass by Wyatt against `docs/preview-compare.md`**, the same document open in both
  applications. Nothing in §3 is believed until that happens: this whole document is a reading of a
  stylesheet, and the register's own warning is that *"a plan written from reading is a hypothesis."*

---

## 7. What is owed from Wyatt, and what is not blocked on it

**Nothing here blocks the work.** The first draft of this spec filed W6 as blocked on a live
diagnostic run; §4 B1 corrects that — `press_route` is extractable and testable now.

Two things still want Wyatt, both as *confirmation* rather than as gates:

1. **The press-routing diagnostic**, which is worth running because it is live evidence against a
   headless inference, and because it costs two minutes:

   ```
   build.bat
   $env:NEWTPAD_PREVIEW_DIAG=1
   .\build\newtpad.exe docs\preview-compare.md
   ```

   Open Preview and Split, click and drag, and paste the `press mode=…` lines. The first `false` in a
   line is the bug. Right-click needs no run — §4 B1 already settles it.

2. **The W7a smoothness question**, once pixels ship and before `W7b` is costed: *is it still blocky?*
   §4.1 exists so that easing is bought only if that answer is yes.

### 7.1 Register items this work creates

Two named spec rules are being overruled by live use, which is the same mechanism C7 itself used. They
belong in `docs/ui-spec-gaps/README.md`'s decisions table, not buried here:

- **C8** — §17's motion table gives `scroll` **0 ms**. `W7b` would change that, and is deferred rather
  than taken silently (§4.1).
- **C9** — §9.4's *"scroll sync by block, not by line"* is overruled in its *effect* but kept in its
  *reason*: block-to-block mapping, pixel interpolation within the block (§4.2).

---

## 8. Deliberately not in scope

- **Colours.** D1. No theme role changes, no Obsidian palette.
- **The graduated heading weights** (700/680/660/640/620/600). Refused in §3.2 — four discrete faces.
- **Images and footnotes**, both in §9.2's unimplemented list and both in `preview-compare.md` §8 as
  known gaps. They stay gaps; this work is typography, spacing and the mouse.
- **Re-theming the application** to match Obsidian. Wyatt declined it explicitly.
