# Batch 12 — UI foundation implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Land the four things every later UI batch depends on — the repainted theme with six new
roles, one scale point for every chrome metric, an SDF rounded-rect quad pipeline, and the interface
font separated from the document font.

**Architecture:** Four independent items in dependency order. The theme is pure data. The metrics work
extends `metrics_recompute` (`main.odin:1448`), which already writes 21 named globals in exactly one
place — this finishes that conversion rather than replacing it with a struct. The pipeline extends the
existing single instanced draw call with two new per-instance fields. The font split adds a second
face selection and routes chrome through it.

**Tech Stack:** Odin `dev-2026-07a`, D3D11 + HLSL (compiled at startup from embedded source),
DirectWrite via `src/platform/dwrite.odin`.

## Global Constraints

- **Spec:** `docs/superpowers/specs/2026-07-28-batch-12-ui-foundation-design.md`. The UI
  specification it derives from is a *target state written from screenshots*: **where the code and it
  conflict on a fact, the code wins; where they conflict on a value, the spec's value is intended.**
- **Do not impose the spec's code shapes.** Its §0 says: *"Do not refactor working code to match the
  structure implied here. Struct names, file layout and function boundaries … are illustrative —
  including the `Rect_Instance` struct and the HLSL in §19 … The numbers, colours, role names and
  behaviours are the deliverable; the code shape is not."* Task 3 keeps globals; Task 4 keeps `Quad`.
- **Build:** `build.bat` (debug, console) for headless modes. Never a bare `odin build` — it omits the
  DPI manifest.
- **Tests:** `odin test src\base -collection:src=src` for pure logic; headless modes in
  `src/program/test_modes.odin` for everything else. **Set `NEWTPAD_SESSION_DIR` to a temp dir first.**
- **Sabotage every fix.** Reintroduce the bug, run the test, watch it fail, record the exact output,
  restore. A test that has never failed proves nothing.
- **Test the seam, not the unit.** Compare what is *drawn* against what is *hit-tested*, at boundary
  sizes.
- **Git:** every commit authored solely by Wyatt Guethlein. No `Co-Authored-By`, no AI attribution
  anywhere, in any commit, merge, tag or PR body.
- **Branch:** `feat/batch-12-ui-foundation` (already created; the design spec is its first commit).
- **Every commit must build.** Verify with the `git rev-list` loop in
  `docs/development-loop.md` §5.3 before merging.

---

### Task 1: Theme — six new roles, two repainted built-ins

**Files:**
- Modify: `src/program/theme.odin` — `Color_Role` enum, `theme_dark`, `theme_light`, the key table
- Test: `src/program/test_modes.odin` — `themetest`

**Interfaces:**
- Consumes: nothing.
- Produces: `Color_Role.Bg_Hover`, `.Accent_Wash`, `.Focus_Ring`, `.Scrollbar_Thumb`, `.Md_Code_Bg`,
  `.Md_Rule`. Task 4 reads `.Focus_Ring`; nothing else in this batch depends on Task 1.

- [ ] **Step 1: Add the six roles to `Color_Role`**

Insert `Bg_Hover` after `Bg_Raised`; `Accent_Wash`, `Focus_Ring`, `Scrollbar_Thumb` after `Accent`;
`Md_Code_Bg` after `Md_Code`; `Md_Rule` after `Md_Quote`. Each gets a comment saying what it is for and
why it is not a reuse — matching the existing house style on `Bookmark` and `Match_Mark`:

```odin
	// Hover fill for any tab, menu row, settings row or palette row. Implicit
	// today: every hover surface reaches for Selection_List or Border_Subtle,
	// so an author cannot make hover quieter than keyboard selection -- which
	// is the one distinction two-weight selection needs (spec §6, "two
	// selection colours").
	Bg_Hover,
```

```odin
	// Fill behind a selected settings row and the filter band. Deliberately a
	// role and not "12% Accent": alpha over the surface inverts on a light
	// custom theme, where a wash must be DARKER than the page, not lighter.
	Accent_Wash,
	// Defaults to the same value as Accent in both built-ins, but separable:
	// an author may want the accent quiet and focus loud. Consumed by the
	// focus ring (batch 13) through the pipeline Task 4 adds.
	Focus_Ring,
	// The scrollbar thumb. THE role this file already asked for: see the note
	// on Text_Muted, which records that it is both a text colour (gutter
	// numbers, every hint line) and this fill, so darkening it for gutter
	// legibility darkens the thumb too -- "Light already shows this as a heavy
	// near-black bar on a pale track." That note ends "recorded so the next
	// batch finds both candidates together." This is that batch.
	Scrollbar_Thumb,
```

```odin
	// Code span and fenced-block fill. markdown.odin has a foreground (Md_Code)
	// and no background, so a code span is coloured text on the page rather
	// than a block.
	Md_Code_Bg,
	// Thematic breaks, table borders, and the h1/h2 underline. markdown.odin
	// draws all three with Border_Strong today (markdown.odin:559,694) -- a
	// CHROME role -- so an author tuning menu borders moves markdown rules
	// with them.
	Md_Rule,
```

- [ ] **Step 2: Run the build to watch it fail**

Run: `build.bat`
Expected: FAIL — Odin rejects an incomplete keyed enumerated-array composite literal, once per
built-in, naming the missing roles. This is the guarantee `theme.odin`'s `#assert` comment describes;
seeing it is the proof it works.

- [ ] **Step 3: Repaint `theme_dark` to spec §1.1**

Replace every value. The neutrals go warm (chroma under 0.02) and the accent becomes amber. Hex from
the spec, with the ratio comments kept because they are the evidence for Step 6:

```odin
		.Bg_Base         = {0.133, 0.122, 0.110, 1}, // #221F1C
		.Bg_Panel        = {0.110, 0.098, 0.090, 1}, // #1C1917
		.Bg_Raised       = {0.169, 0.153, 0.141, 1}, // #2B2724
		.Bg_Hover        = {0.188, 0.169, 0.153, 1}, // #302B27
		.Border_Subtle   = {0.196, 0.176, 0.157, 1}, // #322D28
		.Border_Strong   = {0.290, 0.263, 0.224, 1}, // #4A4339
		.Text_Muted      = {0.616, 0.573, 0.518, 1}, // #9D9284  4.9
		.Text_Dim        = {0.435, 0.400, 0.361, 1}, // #6F665C  2.6 disabled only
		.Text_Secondary  = {0.702, 0.659, 0.592, 1}, // #B3A897  6.6
		.Text_Primary    = {0.804, 0.765, 0.706, 1}, // #CDC3B4  9.2
		.Text_Bright     = {0.949, 0.922, 0.878, 1}, // #F2EBE0  13.4
		.Selection_Doc   = {0.200, 0.259, 0.290, 1}, // #33424A
		.Selection_List  = {0.227, 0.208, 0.184, 1}, // #3A352F
		.Caret           = {0.851, 0.608, 0.384, 1}, // #D99B62  7.3
		.Accent          = {0.851, 0.608, 0.384, 1}, // #D99B62  7.3
		.Accent_Wash     = {0.188, 0.157, 0.137, 1}, // #302823
		.Focus_Ring      = {0.851, 0.608, 0.384, 1}, // #D99B62
		.Scrollbar_Thumb = {0.243, 0.220, 0.200, 1}, // #3E3833  3.0
		.Find_Match_Bg   = {0.290, 0.220, 0.149, 1}, // #4A3826
		.Match_Mark      = {0.851, 0.608, 0.384, 1}, // #D99B62
		.Link            = {0.592, 0.765, 0.847, 1}, // #97C3D8  8.2
		.Warning         = {0.878, 0.643, 0.345, 1}, // #E0A458  7.6
		.Danger          = {0.753, 0.271, 0.231, 1}, // #C0453B
		.Success         = {0.616, 0.788, 0.627, 1}, // #9DC9A0  8.6
		.Filter_Bg       = {0.180, 0.157, 0.137, 1}, // #2E2823
		.Filter_Text     = {0.898, 0.710, 0.498, 1}, // #E5B57F  8.4
		.Bookmark        = {0.592, 0.765, 0.847, 1}, // #97C3D8
		.Md_Heading      = {0.898, 0.710, 0.498, 1}, // #E5B57F  8.4
		.Md_Code         = {0.592, 0.765, 0.847, 1}, // #97C3D8  8.2
		.Md_Code_Bg      = {0.165, 0.153, 0.137, 1}, // #2A2723
		.Md_Italic       = {0.769, 0.718, 0.624, 1}, // #C4B79F  8.0
		.Md_Quote        = {0.651, 0.608, 0.545, 1}, // #A69B8B  5.6
		.Md_Rule         = {0.227, 0.204, 0.180, 1}, // #3A342E
		.Syn_Keyword     = {0.827, 0.663, 0.804, 1}, // #D3A9CD  7.4
		.Syn_String      = {0.616, 0.788, 0.627, 1}, // #9DC9A0  8.6
		.Syn_Number      = {0.898, 0.710, 0.498, 1}, // #E5B57F  8.4
		.Syn_Comment     = {0.616, 0.573, 0.518, 1}, // #9D9284  4.9
		.Syn_Type        = {0.592, 0.765, 0.847, 1}, // #97C3D8  8.2
		.Syn_Punct       = {0.651, 0.608, 0.545, 1}, // #A69B8B  5.6
		.Syn_Json_Key    = {0.937, 0.906, 0.859, 1}, // #EFE7DB  12.7
		.Syn_Xml_Tag     = {0.827, 0.663, 0.804, 1}, // #D3A9CD
		.Syn_Xml_Attr    = {0.898, 0.710, 0.498, 1}, // #E5B57F
```

**Note the three dropped roles are folded in, not lost:** `md_bold` → `Text_Bright` (`#F2EBE0` vs the
spec's `#EFE7DB` — within a rounding of each other, and the spec's own rule is "weight does the work");
`md_list_mark` → `Accent`; `table_zebra` → derived in Task 3's consumer, not a value here.

- [ ] **Step 4: Repaint `theme_light` to spec §1.2**

Same role order, values from the spec. `Bg_Base = {0.980,0.973,0.953,1}` (`#FAF8F3` — warm paper, not
white), `Bg_Raised = {1,1,1,1}` (raised is *lighter* than base in a light theme),
`Accent = {0.627,0.353,0.118,1}` (`#A05A1E`, 4.8), `Scrollbar_Thumb = {0.788,0.761,0.710,1}`
(`#C9C2B5`, 3.0), `Accent_Wash = {0.949,0.902,0.847,1}` (`#F2E6D8`),
`Focus_Ring = {0.627,0.353,0.118,1}`, `Bg_Hover = {0.910,0.890,0.851,1}` (`#E8E3D9`),
`Md_Code_Bg = {0.941,0.929,0.894,1}` (`#F0EDE4`), `Md_Rule = {0.871,0.847,0.800,1}` (`#DED8CC`).

- [ ] **Step 5: Add the six keys to `theme_role_keys`**

`theme_role_keys` is a `[Color_Role]string` keyed enumerated array serving both directions
(`theme_key_from_role` writes files, `theme_role_from_key` reads them). Because it is keyed over the
same enum, **Step 2's build failure names this table too** — a missing key is a compile error, not a
theme file that silently drops a role. Add: `bg_hover`, `accent_wash`, `focus_ring`, `scrollbar_thumb`,
`md_code_bg`, `md_rule` — the lowercase enum name, per the file's own rule.

- [ ] **Step 6: Add §17's six contrast pairs to `themetest`**

The spec's §17 names exactly six pairs, because they cover every place text sits on a themeable fill.
Compute the ratio from the theme values — do not hardcode the spec's numbers, or the test asserts the
spec instead of the code:

```odin
// WCAG 2.x relative luminance, then the contrast ratio. Both built-ins must
// clear 4.5:1 on every pair the spec names. Text_Dim is deliberately absent:
// it is disabled-only at 2.6 and WCAG exempts disabled controls.
lum :: proc(c: [4]f32) -> f64 {
	ch :: proc(v: f32) -> f64 {
		x := f64(v)
		return x / 12.92 if x <= 0.04045 else math.pow((x + 0.055) / 1.055, 2.4)
	}
	return 0.2126 * ch(c[0]) + 0.7152 * ch(c[1]) + 0.0722 * ch(c[2])
}
ratio :: proc(fg, bg: [4]f32) -> f64 {
	a, b := lum(fg), lum(bg)
	if a < b {a, b = b, a}
	return (a + 0.05) / (b + 0.05)
}
```

Six pairs per theme: `Text_Primary`/`Bg_Base`, `Text_Secondary`/`Bg_Panel`, `Text_Muted`/`Bg_Base`,
`Text_Primary`/`Selection_Doc`, `Text_Primary`/`Find_Match_Bg`, `Filter_Text`/`Filter_Bg`. Print each
computed ratio next to its threshold so a failure says which pair and by how much.

- [ ] **Step 7: Run the tests**

Run: `build.bat` then `newtpad.exe themetest`
Expected: `themetest: all ok`, with twelve printed ratios (six per theme), each ≥ 4.5.

- [ ] **Step 8: Sabotage the contrast check**

Set `theme_dark`'s `.Text_Primary` to `{0.35, 0.33, 0.31, 1}` (a plausible-looking mid grey).
Run: `newtpad.exe themetest`
Expected: FAIL on `Text_Primary on Bg_Base`, printing a ratio near 2.2 against 4.5. **Record the exact
line in the task report.** Then restore.

- [ ] **Step 9: Commit**

```bash
git add src/program/theme.odin src/program/test_modes.odin
git commit -m "Repaint both themes warm and add the six roles that had no home"
```

---

### Task 2: The two rounding rules

**Files:**
- Modify: `src/program/doc.odin` — beside `sx()` (`doc.odin:96`) and `line_height()`
- Test: `src/program/test_modes.odin` — new `metricstest`

**Interfaces:**
- Consumes: nothing.
- Produces: `hairline() -> f32` and `ui_px_even(f32) -> f32`. Task 3 uses both.

Spec §3 items 4 and 6 name two rounding rules the current code gets wrong. They are separable from the
call-site conversion and land first so Task 3 can use them.

- [ ] **Step 1: Write the failing test — a new `metricstest` mode**

Place it beside `splittest` in `test_mode_dispatch`. Keep each case in its own local proc (the
`test_mode_dispatch` frame is already large; see `docs/development-loop.md` §6 on
`STATUS_STACK_OVERFLOW`).

```odin
if os.args[1] == "metricstest" {
	bad := 0
	mt_chk :: proc(bad: ^int, ok: bool, label: string) {
		if !ok {bad^ += 1}
		fmt.printfln("  %-6s %s", "ok" if ok else "FAIL", label)
	}
	// The five scales the spec's §3.8 test matrix names, plus 175% because it
	// is the one where 1.75 rounds up and floors down -- the case that tells
	// the two rules apart.
	scales := []f32{1.0, 1.25, 1.5, 1.75, 2.0}
	saved := UI_SCALE
	defer UI_SCALE = saved
	for s in scales {
		UI_SCALE = s
		// Rule 4: a hairline is floor, never round. At 125% a ROUNDED
		// hairline is 1px at an offset straddling two device pixels and
		// renders as two half-alpha lines.
		h := hairline()
		mt_chk(bad, h == f32(int(s)) || (s < 2 && h == 1), fmt.tprintf("scale %.2f: hairline=%.1f (floor(s), min 1)", s, h))
		mt_chk(bad, h == f32(int(h)), fmt.tprintf("scale %.2f: hairline is a whole pixel", s))
		// Rule 6: font px rounds to EVEN, so line_height and the vertical
		// centring inside a row cannot land on a half pixel.
		p := ui_px_even(UI_PX_96 * s)
		mt_chk(bad, int(p) % 2 == 0, fmt.tprintf("scale %.2f: ui px %.0f is even", s, p))
		mt_chk(bad, line_height(p) == f32(int(line_height(p))), fmt.tprintf("scale %.2f: line height %.1f is whole", s, line_height(p)))
	}
	fmt.printfln("metricstest: %d failures", bad)
	return true
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `build.bat`
Expected: FAIL to compile — `hairline` and `ui_px_even` are undefined. That is the failing test.

- [ ] **Step 3: Implement both**

```odin
// A 1-device-pixel line at the current scale. floor, never round -- spec §3
// item 4: at 125% a rounded hairline is 1px positioned at a half-pixel offset
// and the rasteriser splits it into two half-alpha lines, which is the "menu
// bar separator looks blurry" class of defect. Minimum 1: a hairline that
// scales away is a missing boundary.
hairline :: #force_inline proc() -> f32 {return max(1, f32(int(UI_SCALE)))}

// A chrome font size rounded to an even whole pixel. Cell width and line
// height both derive from it (line_height multiplies by LINE_SPACING and
// truncates), and an ODD line height makes vertical centring inside a row of
// even height land on a half pixel -- spec §3 item 6.
ui_px_even :: #force_inline proc(v: f32) -> f32 {
	n := int(v + 0.5)
	if n % 2 != 0 {n -= 1}
	return f32(max(n, 2))
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `build.bat` then `newtpad.exe metricstest`
Expected: `metricstest: 0 failures`, 20 ok lines.

- [ ] **Step 5: Sabotage — restore `round` for the hairline**

Change `hairline` to `max(1, f32(int(UI_SCALE + 0.5)))`.
Run: `newtpad.exe metricstest`
Expected: FAIL at scale 1.50 and 1.75 — `hairline=2.0` where floor gives 1. **Record the output.**
Then restore.

- [ ] **Step 6: Commit**

```bash
git add src/program/doc.odin src/program/test_modes.odin
git commit -m "Add the hairline and even-font-size rounding rules"
```

---

### Task 3: Finish the metrics conversion, and change the chrome sizes

**Files:**
- Modify: `src/program/doc.odin` — the `_96` constant block and the mirrored variables
- Modify: `src/program/main.odin:1448` — `metrics_recompute`
- Modify, one commit each: `main.odin`, `menu.odin`, `palette.odin`, `settings.odin`, `ui_tabs.odin`,
  `history.odin`, `fontpage.odin`, `doc.odin`, `markdown.odin`, `block.odin`, `table.odin`, `find.odin`
- Test: `src/program/test_modes.odin` — extend `metricstest`

**Interfaces:**
- Consumes: `hairline()`, `ui_px_even()` from Task 2.
- Produces: named globals for every value in spec §2.1–2.4, all written only by `metrics_recompute`.

**This extends a pattern that already exists and works.** `metrics_recompute` writes 21 named globals
in one place, and the reason is recorded there: a value scaled at its call site *"was being scaled a
second time by one of them, squaring it and pushing the OS drag region into the content."* That is spec
§3 rule 3, already learned the hard way. There are 167 `sx()` calls left.

**Do not turn all 167 into globals.** `UI_SCALE`'s own comment says it exists to let *"the small
one-off offsets inside a widget scale without every draw proc taking a context parameter"* — and 167
globals is worse than 167 call sites. The rule for this task:

- A value in spec §2.1–2.4, **or** one that two different procedures must agree on, **or** one a
  hit-test and a draw both read → **named global, set in `metrics_recompute`.**
- A genuinely local offset with exactly one reader → **leave it on `sx()`.**
- Any 1px line → **`hairline()`**, never `sx(1)`.

- [ ] **Step 1: Add the §2 constants and their mirrors**

In `doc.odin`'s constant block, with the new values from spec §2.1–2.3. Keep the `_96` / mirror pairing
the file already uses:

```odin
TAB_STRIP_H_96 :: f32(40) // was 36 -- spec §2.1 tab rail
TAB_H_96 :: f32(30) // the pill inside the rail
TAB_MIN_W_96 :: f32(132)
TAB_MAX_W_96 :: f32(220)
TAB_DIRTY_SLOT_96 :: f32(8) // reserved on EVERY tab so nothing shifts
STATUS_BAR_H_96 :: f32(26) // was sx(20) at its call site
TEXT_MARGIN_Y_96 :: f32(16) // was 10 -- spec §2.3 "never 0, the first line needs air"
TEXT_MARGIN_X_96 :: f32(24) // was 12 -- spec §2.3 side padding
SCROLLBAR_W_96 :: f32(8) // was 16 -- spec §2.3
SCROLLBAR_INSET_96 :: f32(6)
CARET_W_96 :: f32(2)
```

Radii, from spec §2.4 — the complete list, nothing above 8:

```odin
RADIUS_MENU_BAR_ITEM_96 :: f32(4)
RADIUS_ROW_96 :: f32(5) // menu rows, palette rows, close button, tooltips
RADIUS_TAB_96 :: f32(6) // tabs, find bar, commands control
RADIUS_PANEL_96 :: f32(7) // menu and palette panels
RADIUS_CARD_96 :: f32(8) // settings cards, the window
```

- [ ] **Step 2: Set them all in `metrics_recompute`**

Add one `X = dp(rc, X_96)` line per new metric, in the same block as the existing 21. `UI_PX` and
`UI_SMALL_PX` change to go through Task 2's rule:

```odin
	UI_PX = ui_px_even(dp(rc, UI_PX_96))
	UI_SMALL_PX = ui_px_even(dp(rc, UI_SMALL_PX_96))
```

- [ ] **Step 3: Extend `metricstest` to assert the whole set**

For each of the five scales, assert every new global is a whole number, that `TAB_H < TAB_STRIP_H`
(the pill fits its rail), that `TAB_MIN_W < TAB_MAX_W`, and the four alignment pairs spec §3.8 names:
the menu-bar hairline is exactly `hairline()`, the caption stroke scales with the box, the status-cell
divider is `hairline()`, and **the active tab's left edge equals the editor's left padding**
(`TEXT_MARGIN_X`) — that last one is the seam the spec says catches nearly everything.

- [ ] **Step 4: Run — expect failures naming each unconverted site**

Run: `build.bat` then `newtpad.exe metricstest`
Expected: FAIL on the alignment pairs, because the call sites still compute their own values.

- [ ] **Step 5: Convert, one commit per file, largest first**

Order: `main.odin` (27), `menu.odin` (25), `palette.odin` (23), `settings.odin` (21), `ui_tabs.odin`
(20), `history.odin` (18), `fontpage.odin` (14), `doc.odin` (8), `markdown.odin` (4), `block.odin` (3),
`table.odin` (2), `find.odin` (2). For each file: replace qualifying `sx(N)` with the named global,
replace every `max(sx(1), 1)` with `hairline()`, run `build.bat` and `newtpad.exe metricstest`, commit.

`markdown.odin:559` and `:694` are `max(sx(1), 1)` rules — they become `hairline()` **and** switch
from `.Border_Strong` to `.Md_Rule` (Task 1's role), which is the one place Task 1 and Task 3 touch the
same line.

- [ ] **Step 6: Run the full suite**

Run each of `wraptest`, `wraplongtest`, `rowtest`, `hscrolltest`, `splittest`, `mdviewtest`, `mdtest`,
`menutest`, `menuseam`, `palettetest`, `settingstest`, `fonttest`, `historytest`, `tablecellstest`,
`dpitest`, `themetest`, `metricstest`, and `odin test src\base -collection:src=src`.
Expected: all pass. `menuseam` and `mdviewtest` matter most — both are seam tests over drawn-vs-clickable
geometry, which is exactly what this task can break.

- [ ] **Step 7: Sabotage the alignment seam**

In `ui_tabs.odin`, change the tab's left edge back to `sx(12)` (the old `TEXT_MARGIN_X_96`) while the
editor uses the new `TEXT_MARGIN_X` (24).
Run: `newtpad.exe metricstest`
Expected: FAIL — `active tab left edge 12 != editor left padding 24`. **Record it.** Restore.

---

### Task 4: The SDF rounded-rect pipeline

**Files:**
- Modify: `src/platform/quads.odin` — `Quad`, `QUAD_HLSL`, the input layout
- Test: `src/program/test_modes.odin` — new `quadsdftest`

**Interfaces:**
- Consumes: `Color_Role.Focus_Ring` from Task 1 (read by batch 13, not here).
- Produces: `plat.Quad` gains `radius: [4]f32` (per-corner, 0 = square) and `softness: f32`
  (0 = crisp AA edge, > 0 = shadow blur). **Zero value stays "square, crisp"**, so every existing
  `Quad{pos=…, size=…, color=…}` literal in the tree keeps compiling and keeps its current output.

This is the `renderer` extraction CLAUDE.md's priority 2 names. Keep the name `Quad` — the spec's
`Rect_Instance` is illustrative and renaming it would touch every draw call in the program for nothing.

- [ ] **Step 1: Write the failing test — pixel identity**

The whole value of this task is that nothing changes until a caller asks for a radius. Render the same
scene through the pipeline and compare the readback byte for byte against a reference captured before
the change. Use the offscreen-device pattern `atlastest` and `devicelosttest` already establish — a real
D3D11 device with an offscreen target, no window — because the claim is about the GPU and CLAUDE.md
requires a real device over arithmetic.

```odin
// Three overlapping opaque quads and one alpha-blended quad, at
// deliberately fractional positions (the case where an AA change shows up),
// rendered to an offscreen target and read back.
scene :: proc() -> []plat.Quad {
	return []plat.Quad {
		{pos = {0, 0}, size = {64, 64}, color = {1, 0, 0, 1}},
		{pos = {10.5, 10.5}, size = {31.25, 31.25}, color = {0, 1, 0, 1}},
		{pos = {40, 8}, size = {17, 40}, color = {0, 0, 1, 1}},
		{pos = {4.25, 48.75}, size = {50, 12.5}, color = {1, 1, 1, 0.5}},
	}
}
```

Assert: every one of the 64×64 BGRA pixels is identical to the golden buffer. Commit the golden buffer
as a small `#load`ed binary or generate it from the pre-change shader in the same run — generating it in
the same run is better, because a committed golden goes stale silently.

- [ ] **Step 2: Run to verify it fails**

Run: `build.bat`
Expected: FAIL to compile — `quadsdftest` is undefined until Step 1's mode is added, then FAIL at
runtime because there is no second shader to compare against yet.

- [ ] **Step 3: Extend the instance and the input layout**

```odin
// One instanced rectangle in pixel space. Plain data -- safe to hand upward.
//
// radius and softness are ZERO-IS-DEFAULT on purpose: every existing caller
// writes only pos/size/color, and a zero radius with zero softness must render
// exactly the square, crisp rect it always did. quadsdftest asserts that
// against a real device rather than trusting it.
Quad :: struct {
	pos:      [2]f32, // top-left, pixels
	size:     [2]f32, // width, height, pixels
	color:    [4]f32, // rgba, 0..1
	radius:   [4]f32, // per-corner TL, TR, BR, BL; 0 = square
	softness: f32, // 0 = analytic AA only; >0 = shadow blur radius in px
	_pad:     [3]f32, // keep the instance 16-byte aligned
}
```

Add `IRADIUS` (`DXGI_FORMAT_R32G32B32A32_FLOAT`) and `ISOFT` (`R32_FLOAT`) to the input-element
description, both `INPUT_PER_INSTANCE_DATA`, with offsets matching the struct.

- [ ] **Step 4: Replace the pixel shader**

Pass the local position and half size through from the vertex shader, then:

```hlsl
// Signed distance to a rounded box. Per-corner radius selected by which
// quadrant the point is in, so one instance can have four different corners
// (a tab pill is rounded on top and square on the bottom).
float sd_round_box(float2 p, float2 b, float4 r) {
	float2 rr = p.x > 0.0 ? r.yz : r.xw;   // TR/BR : TL/BL
	float  cr = p.y > 0.0 ? rr.y : rr.x;
	float2 q = abs(p) - b + cr;
	return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - cr;
}

float4 ps_main(VSOut i) : SV_TARGET {
	float d = sd_round_box(i.local, i.half_size, i.radius);
	// fwidth gives one screen pixel of gradient at any DPI, so the edge is
	// one pixel wide at 100% and at 200% without a scale parameter.
	float aa = max(fwidth(d), 1e-5);
	float a  = 1.0 - smoothstep(-aa, aa, d);
	// softness > 0 widens the falloff into a shadow instead of an edge.
	if (i.softness > 0.0) { a = 1.0 - smoothstep(-i.softness, i.softness, d); }
	return float4(i.color.rgb, i.color.a * a);
}
```

- [ ] **Step 5: Run to verify pixel identity**

Run: `build.bat` then `newtpad.exe quadsdftest`
Expected: `quadsdftest: 0 failures` — all 4096 pixels identical.

- [ ] **Step 6: Add the cases that prove the new parameters do something**

A quad with `radius = {8,8,8,8}` must have a **transparent** corner pixel at (0,0) and an opaque centre;
a quad with `softness = 16` must have a non-zero alpha *outside* its rect bounds. Without these, Step 5
passes for a shader that ignores both new fields entirely.

- [ ] **Step 7: Sabotage — drop the radius from the shader**

Change `sd_round_box`'s `cr` to a constant `0.0`.
Run: `newtpad.exe quadsdftest`
Expected: the identity case still passes (correctly — radius 0 is unaffected) and the
`radius={8,8,8,8}` corner case FAILs with an opaque corner pixel. **Record it.** Restore.

- [ ] **Step 8: Commit**

```bash
git add src/platform/quads.odin src/program/test_modes.odin
git commit -m "Draw quads through a rounded-box SDF"
```

---

### Task 5: Make the interface font configurable

**Files:**
- Modify: `src/program/settings.odin` — add `ui_font_family`; bump the settings format version
- Modify: `src/platform/text.odin:266` — `text_load_faces`
- Modify: `src/program/fontpage.odin` — parameterise the font screen by target
- Test: `src/program/test_modes.odin` — extend `fonttest`, `settingstest`

**Interfaces:**
- Consumes: nothing from Tasks 1–4.
- Produces: `Settings.ui_font_family: string`.

**The separation already exists — this task only makes it configurable.** `Font_Set` (`text.odin:48`)
has had `.UI` and `.Doc` since the atlas was written, with the comment *"The document's font is the
user's choice; the chrome's is fixed, so choosing a document font cannot make the menus unreadable."*
Every `text_draw` / `text_cells` / `text_char_width` **defaults to `.UI`**, and document sites pass
`.Doc` explicitly — so chrome draws need no routing work at all. What is missing is one line:
`text_load_faces` loads Consolas into both sets, above the comment *"same family until settings say
otherwise."* This is settings saying otherwise.

Scope accordingly: this is a setting, a load line and a Settings row — **not** the "half a day" the
spec's step 3 estimated, and not the face routing the design spec assumed before the audit.

- [ ] **Step 1: Write the failing test**

Extend `fonttest`: load a different family into `.UI` than `.Doc` and assert
`plat.text_char_width(t, UI_PX, .UI) != plat.text_char_width(t, UI_PX, .Doc)`. Then assert the property
that actually matters — **changing the document family leaves the chrome advance unchanged.** Verify
the chosen pair really do have different advances first, or the check is vacuous.

- [ ] **Step 2: Run to verify it fails**

Run: `build.bat` then `newtpad.exe fonttest`
Expected: FAIL — both sets are Consolas, so the two advances are equal.

- [ ] **Step 3: Add the setting and load it**

Add `ui_font_family` to `Settings` (default `"Cascadia Mono"` — `FONT_FAMILIES` already registers it
and it ships on Windows 11), bump the settings format version, and change `text_load_faces` to load it
into `.UI`. Fall back to the document family when `font_family_available` says no, so a missing font is
never fatal — the rule the document font already follows.

- [ ] **Step 4: Add the Settings row**

*Interface font* under APPEARANCE, between *Editor font* and *Zoom*, per spec §11. Reuse the existing
font screen parameterised by target (spec §11.1, "one screen, three uses") rather than copying it.

- [ ] **Step 6: Run the tests**

Run: `build.bat`, then `fonttest`, `settingstest`, `menutest`, `palettetest`, `themetest`, `metricstest`.
Expected: all pass.

- [ ] **Step 7: Sabotage — load the document family into `.UI` again**

Revert `text_load_faces` to loading the document family into both sets.
Run: `newtpad.exe fonttest`
Expected: FAIL on "changing the document family leaves the chrome advance unchanged" — the chrome
advance moves with the document font, which is the whole defect. **Record it.** Restore.

- [ ] **Step 8: Commit**

```bash
git add -A
git commit -m "Give the chrome its own font, separate from the document's"
```

---

### Task 6: Land the batch

- [ ] **Step 1: HANDOFF entry** — a new `§6ah`, covering what was built, why the metrics work extended
      `metrics_recompute` instead of introducing the spec's struct, the two spec claims the audit
      falsified (§3 and §4.1 already done), and what is owed (Monaspace embedding; batches 13–20).
- [ ] **Step 2: Version bump** — `src/program/version.odin` to `0.21.0` (a feature batch is a minor
      bump), in the same commit as the HANDOFF entry.
- [ ] **Step 3: Verify every commit builds**

```bash
for c in $(git rev-list --reverse main..HEAD); do d=$(mktemp -d); git archive "$c" | tar -x -C "$d"; ( cd "$d" && odin check src/program -collection:src=src >/dev/null 2>&1 ) && echo "ok   $c" || echo "FAIL $c"; rm -rf "$d"; done
```

- [ ] **Step 4: Merge to `main`**, then run `install.ps1`. Check `Get-Process newtpad` first and never
      use `-Force` while it is running — a hard kill skips the hot-exit session write and loses
      unsaved tabs.
- [ ] **Step 5: Do not push.** Wyatt asks for pushes explicitly, every time.

---

## Self-review

**Spec coverage.** §1 → Task 1. §2.1–2.4 → Task 3. §2.5 → Task 5. §3 items 4 and 6 → Task 2; item 3 →
Task 3; item 8's four alignment checks → Task 3 Step 3. §19 instance + shader + one draw call → Task 4.
§17's six contrast pairs → Task 1 Step 6.

**Deliberately out of scope, and recorded in the design spec:** §19's gamma-correct linear blending
(it changes every measured ratio in §1 and deserves its own before/after comparison, not a line in a
four-item batch); §3 item 7's atlas retention across a monitor drag; §19's precompiled shader bytecode.
Each belongs to batch 13 or later. Named here so the next session finds them rather than assuming §19
is finished.

**Type consistency.** `hairline()` and `ui_px_even()` are defined in Task 2 and used under those names
in Task 3. `Quad.radius` / `Quad.softness` are named identically in Task 4's struct, HLSL and tests.
Task 5 uses the **existing** `Font_Set.UI` / `.Doc` — an earlier draft of this plan invented
`Font_Set.Ui` and a routing step, both of which the audit removed. `Color_Role.Md_Rule` is introduced
in Task 1 and consumed in Task 3 Step 5.

**Three plan facts corrected by audit before this plan was committed**, recorded because
`docs/development-loop.md` §1 lists cited-but-nonexistent procedures as the characteristic plan
failure: `Font_Set` already exists with both members (Task 5 shrank to a setting); `theme_role_keys` is
keyed over `Color_Role` so it is compile-enforced (Task 1 Step 5 is not a "confirm"); and
`metrics_recompute` already writes 21 named globals (Task 3 extends it rather than introducing the
spec's struct).

**Placeholder scan.** No TBD/TODO. Every code step carries the code. Task 3 Step 5's twelve file
conversions are mechanical repetitions of one stated rule rather than twelve unwritten steps, and the
rule is given explicitly above them.
