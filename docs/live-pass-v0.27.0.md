# Live pass checklist — v0.27.0

Everything shipped in batches 12–16 (v0.21.0 → v0.27.0), which is **fifteen releases of UI work
verified only by headless measurement**. This environment cannot inject GUI input, so every item below
is an inference from source that only you can confirm.

Ordered by *how likely it is to be wrong*, not by feature. Items marked **⚠** are ones where I changed
something load-bearing and the test I wrote cannot see the result.

Use `install.ps1` output (already installed) or the release exe. Two files worth having open: a long
`.md` (HANDOFF.md itself is ideal) and a `.cs` or `.json`.

---

## 1. The things most likely to be broken

**⚠ Colours after the gamma change.** v0.26.0 shipped washed out and v0.26.1 fixed the canvas clear.
The clear is now verified byte-exact, but *blended* pixels are not.
- [ ] Dark theme: background is a warm near-black, not grey
- [ ] Light theme: page is warm off-white (`#FAF8F3`), not pure white
- [ ] Text does not look bloated or haloed — glyph edges got deliberately heavier
- [ ] Selection, find highlights and the filter band read as tints, not as solid blocks

**⚠ Syntax colours, as the colourblind-safe palette.** Chosen by search against a deuteranopia and
protanopia simulation, not by eye. The measurement says the worst adjacent pair went 6.4 → 15.7 (Dark)
and → 10.9 (Light); whether that is *enough* is the thing only you can answer.
- [ ] Open a `.cs` or `.json`. Can you tell **strings** (teal) from **numbers** (amber)?
- [ ] Can you tell **comments** (green, dim) from **body text**?
- [ ] Can you tell **keywords** (violet) from **types** (blue)?
- [ ] Does anything look garish? The chroma was capped specifically to avoid that

**⚠ Find bar moved to the top.** Twelve call sites read the old bottom-inset value.
- [ ] Ctrl+F: bar appears at the **top**, and the status line stays visible below
- [ ] The first line of text is not hidden behind the bar
- [ ] Click in the search field — the caret must **not** jump into the document
- [ ] Ctrl+H: two rows, and the document still starts below both
- [ ] Esc closes it and the text returns to the top of the window

---

## 2. Things with no test coverage at all

**Tab rail.** The layout is tested; the appearance is not.
- [ ] Tabs are **pills** — inset in the rail, rounded on all four corners, 3px apart
- [ ] Open ~10 tabs, then Ctrl+Tab through them: **the rail scrolls to follow**. This never worked
      before v0.25.0
- [ ] A modified file shows `*` in a reserved slot, and the label does **not** shift when it appears
- [ ] Two files with the same name show their parent folder
- [ ] A long name elides in the **middle**, keeping the extension
- [ ] Close button appears on the active tab and on hover only
- [ ] Ctrl+Tab shows a focus ring on the tab; **clicking** a tab shows none

**Caption buttons** — now drawn geometry, not font glyphs.
- [ ] Minimise / maximise / close look right, and maximise changes shape when maximised
- [ ] At 150% display scaling the strokes thicken rather than staying hairlines

**Window floor.**
- [ ] Drag the window as narrow as it goes. It should stop at ~318px with chrome intact — before
      v0.22.0 the tab rail slid under the caption buttons, where **one click closed the app**

---

## 3. Batch 16 — markdown (this release)

Open a `.md`, press Ctrl+M until you reach Preview or Split.
- [ ] `~~struck~~` renders struck through, at mid-height
- [ ] `- [ ] todo` and `- [x] done` render as **checkboxes**, not literal brackets
- [ ] A done item is muted and keeps its tick
- [ ] `>> nested` shows **two** quote bars, indented — not one
- [ ] A ` ```json ` or ` ```cs ` block is **syntax coloured** inside the fence
- [ ] YAML front matter at the top of a file reads as a muted card, not as two rules
- [ ] In the plain editor view, `C:\temp\file.txt` does **not** italicise the rest of the line

---

## 4. Menus, palette, settings, status bar

- [ ] View menu: rows read "Word Wrap", not "Toggle Word Wrap"
- [ ] On a `.md`, **Table View** is greyed with `CSV and TSV only` where the shortcut goes
- [ ] Each dropdown is only as wide as **its own** longest row
- [ ] Ctrl+P: category and accelerator columns **line up** and do not collide (this was your screenshot)
- [ ] Type `>sav` — matched characters carry the accent, and a result count sits by the caret
- [ ] Run a command, reopen the palette: it ranks **higher** than before
- [ ] Status bar: position on the left, encoding/EOL on the right, a divider between the right cells
- [ ] **Click** the encoding cell and the `LF`/`CRLF` cell — both should act
- [ ] Ctrl+S shows `[SAVED]` for ~1.5s
- [ ] Select text: the line count is replaced by a selection count, in accent
- [ ] Narrow the window slowly — right-hand cells drop one at a time rather than colliding

---

## 5. Regressions to rule out

- [ ] **Scrollbar**: grab the thumb by its very edge and hold still — the view must not move
- [ ] Click the bare rail — the thumb jumps to the cursor, which is intended
- [ ] Horizontal scrollbar behaves the same way
- [ ] Alt+Z in Markdown Preview: says *"doesn't apply"* rather than doing nothing
- [ ] Ctrl+F, then Alt+C / Alt+W / Ctrl+R: three chips light up; **clicking** them also works
- [ ] Whole word on: `cat` does **not** match inside `cat_x` or `concat`
- [ ] Regex on with an invalid pattern like `cat(`: reads `(invalid pattern)`, not "no matches"
- [ ] Open a very large file — nothing above should have changed its behaviour

---

## Known-not-done, so don't report these

- **Markdown concealment.** You chose "hide `#`/`**` on non-caret lines". **Not built** — it makes the
  drawn column stop matching the byte column, and that pair is the seam HANDOFF §6j records sixteen
  bugs against. It needs its own batch.
- **Preview still lays out on the character grid** — §9.3's proportional face and type scale are batch 17.
- **No app icon** — batch 18.
- **Autolinks and reference links** — only `[a](b)` works.
- **Table view** has no sort, zebra or row numbers — batch 18.
- **Huge-file progress hairline and sparse index** — batch 19.
- **Monaspace not embedded** — chrome is Cascadia Mono; batch 20.

---

## If something is wrong

The most useful report is the one you have been giving: what you did, what you saw, and a screenshot.
Two of the three defects you caught this session (the palette smearing, the focus-ring bar) were
diagnosable *only* because the screenshot showed the thing rather than described it.
