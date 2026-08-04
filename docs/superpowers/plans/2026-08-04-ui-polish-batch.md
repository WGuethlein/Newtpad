# UI polish batch — plan

Design: [2026-08-04-ui-polish-batch-design.md](../specs/2026-08-04-ui-polish-batch-design.md).
Branch `ui-polish-batch`.

Phases land as separate commits. Phase 4 is separable and may be dropped without touching 1–3.

---

## Phase 1 — labels and chords

### T1.1 `Find: Regular Expression` → `Find: Regex`

`src/program/commands.odin:359`

```odin
.Find_Toggle_Regex        = {"Find: Regex", "Search"},
```

Chord stays `Alt+R` (decision C6). `menutest` asserts menu labels — expect it to need its expected
string updated; **check what it asserts before changing it**, because a test that is edited to match
new output proves nothing.

### T1.2 Zoom In renders `Ctrl+=`, not `Ctrl++`

`src/program/keymap.odin:123`

```odin
	.Plus      = "=",
```

**This table is not display-only.** Its comment says the strings are "display names first", but
`key_from_name` (`keymap.odin:148`) folds case over *the same array* to parse `keys.txt`. Changing the
name alone means an existing user keymap containing `ctrl++` stops resolving — silently, because
`key_from_name` returns `(.None, false)` and a malformed chord is skipped.

So the rename needs an alias. In `key_from_name`, after the exact-match loop and before the failure
return:

```odin
	// "+" was .Plus's display name until the UI spec's Ctrl+= landed (§6, 2026-08-04).
	// Keys.txt files written before that spell it "+", and a rename alone would
	// silently stop resolving them -- a malformed chord is skipped, not reported.
	if strings.equal_fold(s, "+") {return .Plus, true}
```

**Sabotage:** delete the alias, write a `keys.txt` binding using `+`, confirm it no longer resolves,
restore. `keytest` is the mode (`newtpad keytest`, no path needed as of 2026-07-30).

### T1.3 `...` → `…` in six labels

`src/program/commands.odin` lines 240, 244, 303, 331, 332, 333:
`Save As…`, `Go to Line…`, `Open File…`, `Edit Current Theme…`, `Edit Keybindings…`,
`Edit Colour Rules…`.

Two hazards, both real:

1. **`dropdown_w` sizes a panel from its widest row.** `…` is one cell where `...` is three, so panels
   get *narrower*. Verify no dropdown reflows badly; `menuseam` prints its numbers and exits 0
   regardless, so **diff its printed line**, don't read its exit code.
2. **`…` is non-ASCII, and PowerShell 5.1 decodes a BOM-less file as ANSI.** These strings are in a
   `.odin` file compiled by Odin, not a `.ps1`, so the script trap does not apply — but confirm the
   bytes that landed are UTF-8 (`git diff` will show mojibake if not) rather than trusting the console.

### T1.4 Palette footer — **SKIPPED, and why**

The sweep listed the footer as a divergence: built shows `>  command · :  go to line · ?  help`
(`palette.odin:460`), the mockup shows a single `:  124   go to line · type a number` row.

**Not doing it.** The mockup's row teaches one prefix; the built legend teaches all three, and §7's own
prose asks for prefixes to be discoverable (`?` exists precisely so the grammar is self-teaching). This
is a case where matching the picture makes the product worse, so it goes to Wyatt as a question rather
than being changed silently. Recorded here so it is not re-raised as an unexplained miss.

---

## Phase 2 — gear → `Commands  Ctrl+P`

### T2.1 One producer for the menu bar's right-hand item

The gear today has a metric (`menu.odin:65`), a hit-test (`959-964`) and a draw (`1313`) that agree
because its width is a constant. A text item's width comes from a measured label, so the two sites
would each measure and could diverge — that is exactly HANDOFF §6j's bug class.

Add a single producer alongside the existing menu-bar layout:

```odin
// The menu bar's right-hand Commands item, as a box with its label and chord
// already placed. ONE geometry, consumed by the draw, the hit-test and the
// hover fill -- the same rule Find_Action follows, and for the same reason: the
// gear this replaces could get away with two sites because its width was a
// constant, and a measured label cannot.
Menu_Bar_Command :: struct {
	x, y, w, h: f32,
	tx, ty:     f32, // label origin (ty is the baseline)
	cx:         f32, // chord origin, same baseline
}
```

Consumed by draw, `menu_bar_hit`, and the hover fill. Nothing else may compute these coordinates.

### T2.2 Remove the gear

Delete `GEAR_W_96`, its hit-test branch and its draw. **`menu.odin:2`'s file comment describes the
gear as matching Windows 11 Notepad's chrome — rewrite that comment, do not leave it describing a
control that no longer exists.**

### T2.3 Seam test

Compare drawn box against clickable box at several window widths, including the narrow end where the
menu bar's items compete for space. Then **sabotage**: shift the hit-test box by 3px, watch the test
fail, record the FAIL line, restore. Add to `menuseam` if it fits there, else `menutest`.

---

## Phase 3 — colour and glyph polish

Each is small; the risk is in *where the rect comes from*, not the colour.

| Task | Change | Watch for |
|---|---|---|
| T3.1 | Inline code span gets `Md_Code_Bg` fill, 3px radius, in the preview | The preview has a per-block layout cache; a fill drawn from a stale cached rect is Shape B. Draw from the same rect the glyphs use. |
| T3.2 | Blockquote bar → `Accent`, 2px | Currently reads muted. |
| T3.3 | List bullets → `•` top level, `◦` nested | Non-ASCII; confirm the glyph exists in the fallback chain (`seguisym.ttf` is in it). |
| T3.4 | Task checkbox → 14px box, accent tick, done text `Text_Muted` | Currently a box with `✕`. |
| T3.5 | Table zebra using `Table_Zebra` | **Key off the DISPLAY row index, not the source row**, or sorting (already shipped — `tablesorttest`) stripes wrongly. |
| T3.6 | Table header band `Bg_Raised` + `Border_Strong` bottom rule | |
| T3.7 | Settings hint row: add `←→ adjust`, arrow glyphs not words (`settings.odin:663`) | Width — the hint row is a single drawn string. |
| T3.8 | Font page breadcrumb `Settings › Editor font` | |
| T3.9 | Font page `PREVIEW` in caps | |

T3.5 is the one with a real trap: `tablesorttest` exists and covers multi-column sort, so zebra keyed
on the source row would be caught only if a test actually sorts *and* checks stripe parity. Add that
check and sabotage it.

---

## Phase 4 — font enumeration (separable)

Not fully planned — it needs DirectWrite API investigation this plan has not done, and the loop's own
rule is that a plan written from reading is a hypothesis. Sketch only:

1. Worker-thread enumeration of the system font collection.
2. Filter: monospaced, **exclude symbol/dingbat charsets**. Do *not* require Latin coverage —
   `text_cell_width_at` already returns width 2 for full-width CJK and a CJK fallback is in the chain,
   so non-Latin mono faces should come through.
3. Merge with the curated `FONT_FAMILIES` so known families keep their exact style files.
4. **Rewrite `text.odin:164`'s comment.** It argues against enumeration on three grounds; two are
   answered here, and the third — localized family names — is unsolved and goes in the debt register
   named, not dropped.

**Land phases 1–3 first and review them before starting this.** It touches the platform layer, COM
lifetime and a list that can change under an open settings page; bundling it with label edits would
make the batch un-reviewable.

---

## Verification (all phases)

`modeguardtest` **first**, then HANDOFF §7's list — not this plan's shorter one. Build through
PowerShell, check `$LASTEXITCODE`, confirm `build\newtpad.exe`'s `LastWriteTime` moved. Read each
mode's OUTPUT, not just its exit code. `menuseam`, `drawcount` and `jsonperf` exit 0 regardless —
diff their printed lines.
