# Live pass — batches 7 through 11

Everything merged since v0.16.0: five batches, roughly 120 commits, **none of it ever verified
against real GUI input.** This environment cannot inject a keystroke or a click, so every claim about
what happens when you press something is inference from source plus a headless assertion. This is the
list that turns that into evidence.

**Order matters.** §1 is ranked by *what breaks worst if it is broken*. If you only have twenty
minutes, do §1 and stop. §2-§6 are per-batch and can be done piecemeal.

**Build under test:** v0.20.0. Installed build is v0.19.0 unless you have run `install.ps1` since.
Check with `Help ▸ Check for Updates` — it reports the running version.

**When something is wrong**, the useful report is: what you did, what happened, what you expected.
A file that triggers it is worth more than a description of it.

---

## 1. The six that would be worst to ship broken

Each of these is a fix that *nearly shipped inverted*, or a path where the failure is silent.

- [x] **1.1 `Alt+F4` closes the window.** — **CONFIRMED by Wyatt, 2026-07-27, on v0.19.0.**
  Adding F1-F12 to the key table silently broke this — the pump only let Alt+F4 reach Windows because
  those keys previously resolved to nothing. Every switch still compiled and every test stayed green,
  so this was the highest-risk item on the list and it is now the first one with real evidence behind
  it rather than inference.
  Still unchecked: **F10 alone** does not do something strange (Windows treats it as a menu key).

- [ ] **1.2 A held key over a column rectangle, then ONE `Ctrl+Z`.**
  Alt+drag a rectangle ~20 rows tall, hold a character down for a second, release. **One** undo must
  restore all of it. If it takes twenty, a long hold can push the pre-edit state off the 200-entry
  undo stack and the original becomes unreachable.

- [ ] **1.3 Bookmarks survive an edit above them.**
  `Ctrl+F2` on a line, put the caret two lines above it, press `Alt+Down` (move line down). The
  bookmark must still be on **its own line**. This shipped wrong once — it silently jumped two lines
  up, and the structural check could not see it. Then: type above it, delete a line above it, and
  `Ctrl+Z` each time.

- [ ] **1.4 Sort a selection, then `Ctrl+Z`.**
  Select ~10 lines mid-file, `>Sort Lines` from the palette. Check the lines *outside* the selection
  did not move and the file's last line is unchanged. One `Ctrl+Z` restores exactly. Then do it on a
  CRLF file and confirm the line endings did not silently convert.

- [ ] **1.5 A live column rectangle refuses to sort.**
  Alt+drag a rectangle, then `>Sort Lines`. It must **refuse with a note** — not sort the whole file.
  It escalated to a whole-file sort during development.

- [ ] **1.6 Click a filtered line, then type.**
  `Ctrl+L` filter on a large file, click a result row, type one character. It must insert, **not
  overwrite the matched word**. This was a real defect: the click set a caret and a later step in the
  same frame turned it into a selection.

---

## 2. Batch 7 — tab stops, long paths, lexers *(v0.17.x)*

- [ ] **2.1 Indented code.** Open a source file indented with tabs. Columns should line up on
  multiples of 4, not jump by a fixed 4 each time. A tab at column 2 should reach column 4, not 6.
- [ ] **2.2 A ragged `.tsv`.** Rows with fields of different lengths should align into columns.
- [ ] **2.3 Click in the middle of a tabbed line.** The caret must land where you clicked. Then use
  arrow keys across the tab — the caret should step *through* the tab, and selection should highlight
  exactly the cells the glyphs occupy. This is the seam most likely to be subtly off.
- [ ] **2.4 Tab width.** `Settings ▸ Tab width` 4 → 8. Text re-lays out immediately. Do it with a
  **CSV grid** (`Ctrl+T`) and a **markdown preview** (`Ctrl+M`) open — the column widths must resize,
  not keep the old measurements.
- [ ] **2.5 A path over 260 characters.** Make a deep folder nest, put a file in it. Open it from
  Explorer, edit, save, `Save As` into the same place, and drag-drop it onto the window. Then check
  the file on disk actually changed.
- [ ] **2.6 A `.sql` file** with `-- a comment mentioning SELECT`. The whole line should be comment
  coloured, and `SELECT` inside it must **not** be keyword coloured.
- [ ] **2.7 A `.css` file** containing `url(https://example.com/x.png)`. Nothing after the `//`
  should turn into a comment.
- [ ] **2.8 Settings ▸ `Ctrl+P` ▸ `>Paste` ▸ Enter, then close the tab.** It must close **silently** —
  no "save changes?" prompt. The palette used to bypass the guard that stops you editing a settings
  page.

---

## 3. Batch 9 — keys, bookmarks, marks, filter *(v0.18.0)*

- [ ] **3.1 `View ▸ Edit Keybindings...`** opens `keys.txt` as a tab, pre-filled with every default
  commented out. Uncomment one, change it, `Ctrl+S`. The new binding works immediately.
- [ ] **3.2 A refused line is reported.** Add `ctrl+shift+k = Undo` and save. You should get
  `[KEYS.TXT: n LINE(S) REFUSED ...]`. Shift cannot be part of a chord, and it must **refuse** rather
  than silently binding `Ctrl+K`.
- [ ] **3.3 `alt+f4 = Save_File`** is also refused — Windows takes that chord before Newtpad sees it.
- [ ] **3.4 You cannot lock yourself out.** Try to rebind `Escape`, `Ctrl+S`, `Ctrl+P` — all reserved.
  Then confirm `Ctrl+P` still opens the palette so you can always reach *Edit Keybindings*.
- [ ] **3.5 Bookmarks.** `Ctrl+F2` toggles, `F2` / `Shift+F2` cycle and wrap, gutter marks appear.
  Close and reopen the file — bookmarks come back. Scroll horizontally on a long line — **the marks
  must not vanish** (they sit in a strip that gets repainted).
- [ ] **3.6 Scrollbar match marks.** `Ctrl+F` something common in a large file. Ticks appear down the
  scrollbar. **Check the bottom of the track** — a match in the last few percent must still show a
  tick, not be hidden behind the find bar. Do the same in Replace mode, where the bar is taller.
  Then judge: on a dense match set, is it informative or just a solid stripe?
- [ ] **3.7 Filter first paint.** `Ctrl+L` on a large file (100 MB+). The first frame must show
  either rows or an explicit "searching" state — never a bare empty grid that looks like "no matches".
  Then judge whether ~48 KB of regex / 64 KB of literal first-paint is enough on your real logs.
- [ ] **3.8 Find does not yank the viewport.** Scroll deep into a large file, `Ctrl+F`, type. It
  should select the next match **below your caret**, not jump to the top of the file.

---

## 4. Batch 10 — sort, dedupe, color rules *(v0.19.0)*

- [ ] **4.1 `>Remove Duplicate Lines`** keeps the *first* occurrence of each line, drops later ones
  however far apart. `Foo` and `foo` are different lines. Running it on an already-unique file should
  say so and push **no** undo entry.
- [ ] **4.2 `>Sort Lines (descending)`** and equal lines keeping their relative order.
- [ ] **4.3 `View ▸ Edit Color Rules...`** — this one has a documented surprise, and the point is to
  confirm the *explanation* reads right, not just the behavior:
  - On a **`.log`**, write `FATAL = Danger`. It should color.
  - Then write `ERROR = Danger`. It should **not** — the log lexer already colors ERROR, and rules
    are deliberately the lowest-priority producer. The file's header explains this. **Read that
    header and tell me whether it lands**, because a user who does not read it will file a bug.
  - On a **`.txt`**, both should color.
- [ ] **4.4 Rules are themeable.** With rules active, switch Dark ↔ Light. Colors should follow the
  theme, because a rule names a role and not an RGB.

---

## 5. Batch 11 — updates, crashes, installer *(v0.20.0)*

- [ ] **5.1 `Help ▸ Check for Updates`.** With v0.20.0 running and v0.19.0 the latest release, it
  should offer an update... **which is the wrong answer.** Once v0.20.0 is released it should say
  up to date. Either way it must never hang the window — the menu row says it contacts GitHub.
- [ ] **5.2 Offline.** Turn off networking and check again. It must say it could not check, and the
  window must stay responsive. **Then close the app while a check is in flight** — exit may stall for
  several seconds and the window may grey out. That is a known defect with a written fix; tell me how
  bad it feels in practice.
- [ ] **5.3 Crash dialog.** `newtpad crashtest panic` from a terminal (set `NEWTPAD_SESSION_DIR`
  first if you do not want it writing to the real store). The dialog should offer to open the crashes
  folder or file a pre-filled GitHub issue. **Check the issue body contains no file path and no
  document content** — it should carry version, OS build, and the exception code only.
- [ ] **5.4 The installer — the biggest untested thing in the whole list.**
  `build\newtpad-0.20.0-setup.exe` now exists and compiles, but has never been *run*.
  - [ ] Install it. Check the license page renders correctly (no mojibake).
  - [ ] Start Menu shortcut works; Add/Remove Programs shows Newtpad.
  - [ ] `newtpad` works from a fresh terminal (PATH).
  - [ ] Right-click a `.md` → Open with → Newtpad is listed.
  - [ ] **Upgrade over a running instance, with an unsaved tab open.** This is the one that matters.
        The installer should ask Newtpad to close *gracefully*, your unsaved tab should be restored
        when it relaunches, and nothing should be force-killed. If it refuses to install because
        Newtpad would not close, that is the **correct** behavior.
  - [ ] Uninstall. Registry keys, PATH entry and the install folder all gone.

---

## 6. The two passes owed from before

- [ ] **6.1 Dark theme syntax colors.** They were chosen by arithmetic and have been looked at once.
  This is the first thing a beta tester sees. Sample files at `C:\Users\Wyatt\Newtpad-testfiles`;
  `View ▸ Edit Current Theme...` writes the active theme to a file you can edit with `Ctrl+S` to see
  changes live.
- [ ] **6.2 Light theme.** Same pass. Light is where colors that silently assumed a dark background
  show up.

---

## Known-imperfect, so do not report these as bugs

- Exit can stall for seconds if an update check is in flight (§5.2) — known, fix written down.
- A markdown table wider than the preview pane is clipped with no way to scroll it.
- Wrapped continuation rows measure tab stops from the visual row, not the logical line.
- CSS has no `//` line comment, so `url(...//...)` is handled, but a `/*` inside an unquoted URL path
  can open a real comment block.
- The sort folds ASCII case only — `Ä` and `ä` do not fold together.
- Rules do not apply in markdown preview or the CSV grid.
- No application icon yet, so the installer and Explorer show a default.
