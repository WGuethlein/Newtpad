# Live pass checklist — v0.49.0 → v0.60.0

**Twelve releases, none of them walked systematically.** This environment cannot inject GUI input, so
everything below is an inference from source: 89 headless modes are green and that proves the code does
what the code says, not that the result is any good to use.

**The argument for doing this at all is v0.58.0.** The "Line numbers" row shipped, read correctly in
review, passed every test — and was dead to the arrow keys, along with four other boolean rows that had
been dead since the settings page was written. You found it in about a minute of real use. Nothing here
could have caught it.

Ordered **most likely to be wrong first**. **⚠** marks items where something load-bearing changed and no
test can see the result. Answer in the checkboxes; a one-line note on anything that feels off is worth
more than a tick.

**What to open:** a long `.md` (HANDOFF.md is ideal), a multi-thousand-line `.log` or `.txt`, and a
`.csv` with a few hundred rows and a URL column.

---

## 1. ⚠ Line numbers — the newest and the riskiest (v0.57.0)

Off by default. **Settings → Line numbers → Enter, or Left/Right.** The gutter reads `GUTTER_W`, which
both the draw and the click hit-test add, so this is the seam sixteen bugs have come from.

- [ ] The setting **turns on and off** with Enter, and with Left and Right
- [ ] Numbers appear down the left, current line **brighter** than the rest
- [ ] **Click on a character mid-line — does the caret land exactly where you clicked?** This is the one
      that matters. If everything is off by a few characters, the gutter width is reaching one of the
      two paths and not the other
- [ ] Drag-select across a line: does the selection cover the characters you dragged over?
- [ ] Numbers stay **aligned with their rows** as you scroll (not drifting a half-row)
- [ ] With **word wrap on**, a wrapped line is numbered **once**, on its first row — continuation rows
      have blank gutter
- [ ] Open a **very large file**. While it is still indexing, the gutter is **blank rather than wrong**,
      then fills in — and the text does **not** shift sideways when the numbers appear
- [ ] On a file with 10,000+ lines the numbers are not clipped
- [ ] Turn it off again: text returns to the left margin, clicking still lands correctly

## 2. ⚠ Wrapped text now stops at 100 columns (v0.57.0)

`Alt+Z`, on a **maximised** window. Not a setting.

- [ ] Wrapped lines stop at ~100 characters instead of running the full window width
- [ ] Text stays **left-aligned** — it should get shorter, not centred
- [ ] **Does it look right, or does it look broken?** A big empty right half on a wide monitor is the
      risk here, and it is a judgement call I cannot make from source
- [ ] Unwrapped (`Alt+Z` off) horizontal scrolling still uses the **full** window width
- [ ] Wrap + line numbers together: the cap and the gutter do not fight

## 3. ⚠ Markdown marks are dimmer (v0.60.0)

Open a `.md` in the **normal editor view** (not Ctrl+M preview).

- [ ] `#`/`##` on headings draw **muted**, the heading text keeps its colour
- [ ] `**bold**` and `_italic_` — the marks are muted, the text is not
- [ ] **Is it too dim?** They are `Syn_Punct`, the same colour as braces and commas. If they vanish
      into the background that is a number worth changing
- [ ] Nothing else changed colour by accident — lists, quotes, code spans, links
- [ ] Backticks around `` `code` `` are **not** dimmed. Deliberate (the spec names only headings and
      emphasis) — **does that look inconsistent to you?** Easy to extend

## 4. The empty tab (v0.57.0)

- [ ] A new tab shows three hints bottom-left: `Ctrl+O`, `Ctrl+P`, `drop`
- [ ] They **vanish on the first keystroke**
- [ ] Delete everything again — do they come back? (Intended)
- [ ] They are readable but quiet. **They use Text_Muted, not the spec's `text_dim`** — the theme test
      forbids `text_dim` outside disabled controls. Too loud?
- [ ] They do not overlap the status bar or the first line you type

## 5. Settings page, now that the arrows work (v0.58.0)

Every row should answer **both** Enter and Left/Right.

- [ ] Walk **every** row top to bottom, pressing Left and Right on each. Any that do nothing?
- [ ] **Interface font** — it was completely dead until v0.58.0 if you had not opened the Font page
      first. Open Settings **fresh** (restart Newtpad, go straight to Settings) and try it
- [ ] Values that cycle land on sensible things; nothing shows a blank value
- [ ] Changes **survive a restart**

## 6. ⚠ The filter dropdown — five releases, never walked (v0.49.0 → v0.54.0)

Open a `.csv` in table view, then the column filter. This took **five** releases and every fix was
found by you reporting it, not by a test.

- [ ] Open the dropdown from the header chevron **and** by right-click
- [ ] Every distinct value has a checkbox, sorted ascending
- [ ] The **search box** filters the value list as you type
- [ ] **Scroll wheel** over the list scrolls the list, not the grid behind it
- [ ] ⚠ **Drag the scrollbar thumb** — does it follow the cursor for the whole drag, or stop after a
      frame? This broke three times (§6br → §6bt → §6bu)
- [ ] Click a value's row: the right row ticks — including rows **next to the scrollbar**
- [ ] A click on dead space inside the dropdown does **not** close it
- [ ] Applying a filter filters the grid; clearing it restores every row
- [ ] Filter + sort together behave sanely
- [ ] It refuses past the row cap with a message rather than freezing

## 7. Format Document — HTML is new (v0.57.0)

`Ctrl+Alt+F`.

- [ ] A minified `.html` becomes readable
- [ ] ⚠ **Text that was on one line stays on one line where it matters.**
      `<div><span>a</span><span>b</span></div>` must come back **unchanged** — a line break between
      those spans renders as a space and would change what the page says
- [ ] `<pre>` blocks survive byte for byte
- [ ] A `.json`, `.css` and `.xml` still format as before

## 8. Regression sweep — the things most likely to have been broken in passing

Everything below worked before this run of releases. Two minutes.

- [ ] Open, edit, save, reopen — content intact
- [ ] Ctrl+F, Ctrl+H, Ctrl+L (filter) all still work and Esc gets you out
- [ ] Tabs: open several, reorder, tear one off, close
- [ ] Markdown `Ctrl+M` cycles Off → Preview → Split
- [ ] Table view `Ctrl+T`, sort by clicking a header
- [ ] Undo/redo across a few edits
- [ ] Session restore: close with unsaved tabs, reopen

---

## The one question still outstanding from before this batch

**Ctrl+click a web link in the CSV table view.** Everything from the pixel to `shell_open_url` is now
verified correct by `gridlinktest`, so this single observation decides where to look next:

- [ ] **A dialog appears** → read its text and paste it here. The failure is in `link_resolve` or the
      scheme whitelist, and the dialog names which
- [ ] **Nothing at all happens** → the click is not reaching the handler, and since the hit-test and
      every input-ordering suspect are eliminated, that points somewhere nobody has looked yet

---

## Anything else

Free text. A vague report from daily use has been right before — the menu/Ctrl+F awkwardness note is
still open precisely because it was worth recording without being pinnable.
