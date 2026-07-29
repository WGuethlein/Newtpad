---
this is a test
---
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
- [X] Dark theme: background is a warm near-black, not grey
- [X] Light theme: page is warm off-white (`#FAF8F3`), not pure white
- [X] Text does not look bloated or haloed — glyph edges got deliberately heavier
- [X] Selection, find highlights and the filter band read as tints, not as solid blocks

**⚠ Syntax colours, as the colourblind-safe palette.** Chosen by search against a deuteranopia and
protanopia simulation, not by eye. The measurement says the worst adjacent pair went 6.4 → 15.7 (Dark)
and → 10.9 (Light); whether that is *enough* is the thing only you can answer.
- [X] Open a `.cs` or `.json`. Can you tell **strings** (teal) from **numbers** (amber)?
- [X] Can you tell **comments** (green, dim) from **body text**?
- [X] Can you tell **keywords** (violet) from **types** (blue)?
- [X] Does anything look garish? The chroma was capped specifically to avoid that

**⚠ Find bar moved to the top.** Twelve call sites read the old bottom-inset value.
- [X] Ctrl+F: bar appears at the **top**, and the status line stays visible below
- [X] The first line of text is not hidden behind the bar
- [X] Click in the search field — the caret must **not** jump into the document
- [X] Ctrl+H: two rows, and the document still starts below both
      - Pressing Ctrl+H after it's open drops it down into Ctrl+F mode, not backing out to the viewport
      - Ctrl+F once it's opened doesn't close the menu or the search feature
- [X] Esc closes it and the text returns to the top of the window

---

## 2. Things with no test coverage at all

**Tab rail.** The layout is tested; the appearance is not.
- [X] Tabs are **pills** — inset in the rail, rounded on all four corners, 3px apart
- [X] Open ~10 tabs, then Ctrl+Tab through them: **the rail scrolls to follow**. This never worked
      before v0.25.0
- [X] A modified file shows `*` in a reserved slot, and the label does **not** shift when it appears
      - this is true but it it's missing the space between the name and the asterisk like was in the design docs, do you need those again?
- [X] Two files with the same name show their parent folder
- [X] A long name elides in the **middle**, keeping the extension
- [ ] Close button appears on the active tab and on hover only
      - it appears only on the active tab, but it doesn't disappear when it's not being hovered over... also with a really long name there's no pixel gap between the X and the end of the file name, they blend together
- [X] Ctrl+Tab shows a focus ring on the tab; **clicking** a tab shows none

**Caption buttons** — now drawn geometry, not font glyphs.
- [X] Minimise / maximise / close look right, and maximise changes shape when maximised
- [X] At 150% display scaling the strokes thicken rather than staying hairlines

**Window floor.**
- [ ] Drag the window as narrow as it goes. It should stop at ~318px with chrome intact — before
      v0.22.0 the tab rail slid under the caption buttons, where **one click closed the app**
      - This needs work, but it's not a priority

---

## 3. Batch 16 — markdown (this release)

Open a `.md`, press Ctrl+M until you reach Preview or Split.
- [X] `~~struck~~` renders struck through, at mid-height
- [X] `- [ ] todo` and `- [x] done` render as **checkboxes**, not literal brackets
	- This works, though the X is at the bottom right of the box, not in the center in the view
- [ ] A done item is muted and keeps its tick
	- the base color text gets muted but the theme colors don't, maybe we just add a filter over all colors dropping them the same percent as the white/base color?
- [ ] `>> nested` shows **two** quote bars, indented — not one
	- This is correct, though in the edit view the first > is green, where the rest are white... slight change, not a huge priority
- [ ] A ` ```json ` or ` ```cs ` block is **syntax coloured** inside the fence
	- the trailing backticks don't get recognized, they're even a different color... it just makes the rest of the file a codeblock. Also, when the code block start goes off screen, the viewport stops rendering the whole codeblock
- [ ] YAML front matter at the top of a file reads as a muted card, not as two rules
	- i'm not exactly sure what this is supposed to look like... it shows as muted, i see the start and end ---, and i see like a quote bar on the side but it's thinner
- [X] In the plain editor view, `C:\temp\file.txt` does **not** italicise the rest of the line


---

## 4. Menus, palette, settings, status bar

- [X] View menu: rows read "Word Wrap", not "Toggle Word Wrap"
- [X] On a `.md`, **Table View** is greyed with `CSV and TSV only` where the shortcut goes
- [ ] Each dropdown is only as wide as **its own** longest row
	- encoding is long
- [X] Ctrl+P: category and accelerator columns **line up** and do not collide (this was your screenshot)
- [X] Type `>sav` — matched characters carry the accent, and a result count sits by the caret
- [X] Run a command, reopen the palette: it ranks **higher** than before
- [X] Status bar: position on the left, encoding/EOL on the right, a divider between the right cells
- [X] **Click** the encoding cell and the `LF`/`CRLF` cell — both should act
- [X] Ctrl+S shows `[SAVED]` for ~1.5s
- [X] Select text: the line count is replaced by a selection count, in accent
- [X] Narrow the window slowly — right-hand cells drop one at a time rather than colliding

---

## 5. Regressions to rule out

- [X] **Scrollbar**: grab the thumb by its very edge and hold still — the view must not move
- [X] Click the bare rail — the thumb jumps to the cursor, which is intended
	- Issue Here, the vertical scrollbar doesn't go to the bottom of the screen anymore, only about 80% of the way
- [X] Horizontal scrollbar behaves the same way
	- Issue Here, the horizontal scrollbar only allows for expanding left/right if the large row is on the screen, if it's not on the screen the horizontal scroll bar won't appear
- [X] Alt+Z in Markdown Preview: says *"doesn't apply"* rather than doing nothing
- [X] Ctrl+F, then Alt+C / Alt+W / Ctrl+R: three chips light up; **clicking** them also works
	- Alt+C/W work, i'm not sure about having some be Alt and some be Ctrl. need to have some sort of standard to follow for the default set atleast
- [X] Whole word on: `cat` does **not** match inside `cat_x` or `concat`
- [X] Regex on with an invalid pattern like `cat(`: reads `(invalid pattern)`, not "no matches"
- [X] Open a very large file — nothing above should have changed its behaviour

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


## OTHER BUGS FOUND
- the half-glyph issue still occurs on the tabs, havent seen it on the other 
- sometime tabs get added in the middle of the tab list... it should always appear at the end if it was newly created, dragged in, or opened
- when shrinking the view horizontally, occasionally there's a row of text that overlaps the bottom cells
- Ctrl+H has no replace all button/keybind, also no explanation of what you're to do on this menu... doesn't tell you how to replace
- the Ctrl link/filepath highlighting still don't work as intended