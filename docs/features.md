# What Newtpad already does

The third of three lists, and the only one about the present tense:

| File | Holds |
|---|---|
| **features.md** (this file) | **what is built and working today** |
| [requested-features.md](requested-features.md) | what is owed, asked for, or still unbuilt |
| [reported-bugs.md](reported-bugs.md) | open defects from daily use |

Nothing here is aspirational. Every entry was checked against the source at **v0.33.0**; where a
feature has a real limit, the limit is stated in the same breath. Anything in the UI spec that is not
built is in `requested-features.md`, not here.

The command table (`src/program/commands.odin`) is the authority for what is invocable — CLAUDE.md
requires every command be declared exactly once — so the [keyboard reference](#keyboard-reference) at
the end is complete by construction.

---

## Opening files

- **Any text-ish file opens natively.** 34 extensions are registered with Explorer
  (`text_exts.txt`): `.txt .log .md .markdown .json .csv .tsv .xml .yaml .yml .toml .ini .cfg .conf
  .env .c .h .cpp .hpp .cs .odin .py .js .ts .go .rs .java .sql .sh .bat .ps1 .html .css .gitignore`.
  Nothing stops you opening a file with any other extension by hand.
- **Multi-GB files open instantly.** Under 16 MB the file is copied into private memory; over 16 MB it
  is memory-mapped, so opening costs no read of the body and almost no private memory. The viewport
  walks lines on demand, so scroll position never costs a scan from the start of the file.
  *Limit:* mapping is only used on local fixed drives — a file on a network share, a USB stick or a
  CD is always copied, whatever its size.
- **The file is never locked.** It is opened share-read/write/delete and the handle is closed
  immediately. *One caveat:* while a large file is memory-mapped, Windows itself refuses truncation,
  deletion and replacement of it (`ERROR_USER_MAPPED_FILE`) — so a service cannot roll a log Newtpad
  has mapped. Newtpad detaches to a private copy the moment it notices the file changing, which is
  what makes this a moment rather than a state.
- **Encoding is detected**: UTF-8, UTF-16 LE and UTF-16 BE by BOM, BOM-less UTF-16 by NUL parity over
  the first sniff window, otherwise UTF-8 if the bytes are valid UTF-8 and Windows-1252 if they are
  not.
- **Line endings are detected and preserved** — LF, CRLF, or `Mixed` when both appear.
- **Drag and drop.** Dropping files from Explorer onto the window opens them as tabs and focuses the
  *first* one — the natural read order for a multi-file drop. A file already open just gets focused
  rather than opened twice. Directories are skipped with a status-bar note (project trees are out of
  scope).
- **Double-click in Explorer, or `newtpad foo.txt` on the command line**, hands the path to the
  already-running window rather than starting a second process — the file lands as a new tab and the
  existing window is focused. `newtpad --version` prints the version and exits.
- **A bare launch** gives you an empty scratch buffer (or your restored session).
- **One portable exe, 1.21 MB** (1,271,808 bytes, measured at v0.33.0 from a clean `build.bat release`).
  No install required and nothing to ship beside it — the only runtime dependencies are DLLs Windows
  already has. Well inside the ~2–3 MB the product principles set. An optional Inno Setup installer
  exists (`installer/newtpad.iss`) — per-user, HKCU and `%LOCALAPPDATA%` only, no elevation.
  *Not verified:* the installer has never been compiled or run.

### External changes

A background worker polls each open file's timestamp and size once a second (never a held handle).
Once a frame the main thread acts on what it saw:

- **A clean tab reloads silently**, keeping its view mode, wrap state and scroll position.
- **A file that only grew is absorbed as an append** — `tail -f` behaviour for live logs, with the
  view following the tail if the caret was already at the end. Caret, selection, search results and
  bookmarks all keep their meaning. (UTF-8, BOM-less, unmodified buffers only.)
- **A dirty tab is never overwritten.** The status bar says
  `[CHANGED ON DISK - you have unsaved edits. File > Reload to discard yours]`, and the choice is
  yours (`File ▸ Reload from Disk`, which confirms first).
- **A deleted file** says `[FILE DELETED ON DISK - your text is still here; Save to write it back]`.
- **A file that changes underneath a mapping mid-read** is detached into a private copy, and the tab
  is flagged `[RECOVERED COPY - file changed on disk, not the original]`.
- Saving `theme.theme` / `keys.txt` / `rules.txt` — from inside Newtpad *or* another editor — re-reads
  them live, so all three can be tuned without restarting.

### Saving

- **`Ctrl+S`** saves; an untitled buffer gets the native Save dialog. **`Ctrl+Alt+S`** is Save As.
  (`Ctrl+Shift+S` cannot be expressed — Shift is not part of a chord anywhere in Newtpad.)
- **Writes are atomic** — temp file, then rename — and streamed in bounded chunks, so a multi-GB save
  does not need a multi-GB allocation.
- **A save that would lose characters asks first.** Saving text containing an em dash, a curly quote
  or an emoji into a Windows-1252 file counts the losses and offers *Save as UTF-8 / Save anyway /
  Cancel* rather than silently substituting `?`.
- **A failed save always says so** — silence on a failed write is a data-loss bug, and in the
  GUI-subsystem release build there is no console for it to fall back to.
- A successful save flashes `[SAVED]` in the status bar for a few seconds; the tab's `*` also clears.

---

## Tabs and the session

- `Ctrl+N` new, `Ctrl+O` open, `Ctrl+W` close, `Ctrl+Tab` / `Shift+Ctrl+Tab` to cycle,
  `Ctrl+PgDn` / `Ctrl+PgUp` for next/previous. Cycling follows strip order, not most-recently-used.
  A new tab always lands at the *end* of the strip, never in the hole left by a closed one.
  *Limits:* the session restores at most **64** tabs, and only the first **32** open files are watched
  for external changes.
- **The tab strip is the title bar.** The OS frame is removed; the strip carries `☰`, the tabs, `+`,
  and the minimise/maximise/close buttons.
  - Clicking `☰` opens the command palette in command mode.
  - Clicking `+` opens a new scratch tab.
  - **Middle-click closes a tab**; so does the `×` on it.
  - **Tabs drag to reorder.**
  - When the strip runs out of room, an overflow count appears; clicking it opens the palette's tab
    list, which can reach any tab.
  - Tabs size to their label between a floor and a ceiling, and reserve a fixed slot for the dirty
    `*` so a file going dirty never shifts its own name.
- **Closing a dirty tab prompts** to save / discard / cancel. Cancelling or a failed save aborts the
  close.
- **Hot exit.** Closing the window — or `File ▸ Exit` — does *not* prompt. Open tabs are recorded in
  `%APPDATA%\Newtpad\session.txt` and unsaved buffers are written to per-tab backups, restored on next
  launch. Restore carries caret, anchor, scroll position, wrap, encoding, view mode and bookmarks.
  Session state is also autosaved about two seconds after input settles.
  - *Limit:* a dirty buffer over 128 MB is **not** auto-backed up (the copy would freeze the app), and
    the status bar says `[LARGE FILE - unsaved edits are NOT auto-backed up; Save to keep them]` for
    as long as it stays dirty.
  - Turning restore off in Settings still keeps the backups on disk — it only stops reopening them.
- Session restore, backups and every other stored file live under `%APPDATA%\Newtpad`, or under
  `NEWTPAD_SESSION_DIR` if that is set.

---

## Moving around

| | |
|---|---|
| Arrows | character / line |
| `Ctrl+←` `Ctrl+→` | word left / right |
| `Home` `End` | line start / end |
| `Ctrl+Home` `Ctrl+End` | start / end of file |
| `PgUp` `PgDn` | page |
| `Ctrl+G` | go to line (opens the palette in `:` mode) |
| `Ctrl+F2` | toggle a bookmark on the caret's line |
| `F2` / `Shift+F2` | next / previous bookmark, wrapping |

- **Bookmarks** show as marks in the left margin, survive edits above them, and persist in the session
  (up to 256 per tab). With none set, `F2` says `[NO BOOKMARKS - press Ctrl+F2 to set one]`.
  *Limit:* they are not shown on the scrollbar, and they are hidden in the grid and full Markdown
  Preview, which lay out on a different model.
- **Scrolling**: mouse wheel, a byte-proportional vertical scrollbar you can drag or click, and
  `Shift+wheel` to pan horizontally when wrap is off. A horizontal scrollbar appears when a line runs
  past the window.
- **Auto-scroll while selecting** — drag past the top or bottom edge and the view follows.
- **A background worker counts total lines** so the status bar can report them; while it is running
  the bar shows `(indexing NN%)`. Nothing waits on it.

---

## Editing

- Piece-tree buffer with full **undo (`Ctrl+Z`) / redo (`Ctrl+Y`)**. There is no `Ctrl+Shift+Z`.
- **Selection**: `Shift`+any movement key, mouse drag, **double-click for a word**, **triple-click for
  a line**, `Ctrl+A` for all, `Esc` to clear.
- **`Ctrl+A` skips the blank tail, and a second press takes everything.** A run of blank rows *after*
  the last content is trailing whitespace and is left out; a blank line *between* two paragraphs is
  content and stays selected. Whitespace-only rows count as blank, and a document that is entirely
  blank selects in full so `Ctrl+A` never appears to do nothing. **This is a deliberate divergence** —
  VS Code, Notepad and Sublime all select the whole buffer — which is why the second press exists:
  select-all-then-delete is still one extra keystroke away. The backward scan is capped at 1 MiB and
  falls back to selecting everything past it, so a multi-GB log with a huge blank tail cannot stall the
  keystroke.
- **Clipboard**: `Ctrl+C` / `Ctrl+X` / `Ctrl+V` via `CF_UNICODETEXT`. Pasted text is converted to the
  document's own line endings (the Windows clipboard is CRLF by convention); copied text is *not*
  rewritten on the way out.
- **`Alt+↑` / `Alt+↓` move the current line** up or down.
- **`Ctrl+Backspace`** deletes the previous word. (There is no delete-word-forward.)
- **Tab inserts a tab**; the tab stop width is configurable in Settings (Tab width, 1–16, default 4),
  and it is a real tab stop — a tab advances to the next multiple, it does not insert N spaces.

### Undo history panel

`Edit ▸ Undo History` (palette: *Undo History*) opens a side panel listing every recorded state, with
`↑`/`↓` to move and `Enter` to jump straight to one — Photoshop-style, rather than only stepping with
`Ctrl+Z`. Every past state is already a cloned piece tree, so a jump is a tree swap, not a replay.

### Column / block editing

`Alt+drag` with the mouse, or `Alt+Shift+arrows` from the keyboard, makes a **rectangular selection**.

- Typing replaces the rectangle on every spanned row; at zero width it inserts at N carets, which is
  how you prefix a column.
- `Tab` indents every spanned row. `Backspace` / `Delete` delete the rectangle (or one cell per row at
  zero width). `Ctrl+C` / `Ctrl+X` copy and cut the rectangle. All of it is one undo entry.
- Rows shorter than the rectangle's left edge are padded with virtual space.
- *Limits, each of which refuses with a message rather than doing something partial:* a rectangle
  cannot span more than **300 rows**; column select is unavailable with **word wrap on** (`Alt+Z`), in
  **Markdown Split** (`Ctrl+M`), in **filter view**, and on a row too far into a very large file to
  resolve. `Enter` deliberately clears the rectangle rather than splitting every row.

### Text operations

Three commands, **palette-only** — no chord and no menu row. Each acts on the selected lines expanded
to whole lines, or on the whole document when there is no selection.

- **Sort Lines (selection, or whole file)**
- **Sort Lines Descending (selection, or whole file)**
- **Remove Duplicate Lines (exact match, keeps the first)** — all duplicates, not just adjacent ones.

*Limits:* the sort folds ASCII case only (`Ä`/`ä` do not fold; non-ASCII compares by UTF-8 byte order).
Dedupe is exact — `Foo` and `foo` are two different lines even though the sort compares them
case-insensitively. The region must be under **16 MB and 1,000,000 lines**; beyond that the command
refuses and says so. A live column rectangle refuses rather than guessing which reading you meant.
Nothing happening is reported too (`[ALREADY SORTED]`, `[NO DUPLICATE LINES]`).

---

## Finding things

`Ctrl+F` find · `Ctrl+H` replace · `Ctrl+L` **filter to matching lines**.

The find bar sits at the top of the content area. `Enter` finds the next match, `Shift+Enter` the
previous, and both wrap. `Esc` closes. `Tab` moves between the search and replace fields.

- **Incremental**: every match is highlighted as you type, and the caret-nearest one is selected.
- **Three modes**, as clickable chips on the bar with keys beside them:
  - `Alt+C` — match case (`Aa`)
  - `Alt+W` — whole word (`ab|`)
  - `Alt+R` — regular expression (`.*`), via Odin's `core:text/regex`. In regex mode the replacement
    understands `$1`, `${12}`, `$&` and `$$`.
- **Replace Match** is `Ctrl+Enter`, **Replace All** is `Ctrl+Alt+Enter`; both are also buttons on the
  replace row and entries in the palette, and Replace All reports its count. Running either from the
  document with the bar shut opens the replace bar instead of doing nothing.
- **Match ticks on the scrollbar**, drawn under the thumb so the marks you can see are the matches
  that are *off* screen.
- **Filter-as-you-type (`Ctrl+L`)** — the one that is easy to forget. It collapses the view to just the
  matching lines, with a line-number gutter, and a banner reading
  `FILTER  N matching lines  —  Ctrl+L shows the whole file`. **Clicking a filtered line jumps to it in
  the whole document.** `PgUp`/`PgDn` page the filtered list. `Ctrl+F` switches back to ordinary
  search without closing the bar. Because searching runs on a worker, the filter arms immediately and
  fills in as results arrive rather than blanking the screen; the banner distinguishes
  *type to filter* / *searching…* / *no matching lines*.
- **Large files search on a background thread.** Buffers up to 256 KB scan inline; larger ones get a
  bounded 64 KB first-paint pass on the calling thread and a worker for the rest, so a keystroke never
  waits on file size.
- *Limits:* at most **100,000** matches are tracked at once, and Replace All says so rather than
  silently replacing a prefix (`Run Replace All again to continue`). A pattern spanning an internal
  block boundary may not match. Regex is line-aligned.
- Pasting into the find field is `Ctrl+V` and lands in the *field* — it cannot fall through to the
  document.

---

## Views

Each is per-document, toggles both ways, and leaves the bytes alone.

### Word wrap — `Alt+Z`

On/off per tab, with a default for new documents in Settings. Refuses (with a reason naming the key
that gets you out) in table view and Markdown Preview, which ignore the flag; Markdown Split always
wraps.

### Markdown preview / split — `Ctrl+M`

Cycles **Off → Preview → Split → Off** on `.md .markdown .mkd .mdown .mdwn .mdtext .mdx .mtext`.

Rendered with real proportional body faces (Georgia, then Constantia / Times New Roman / Segoe UI):
headings, **bold**, *italic*, ~~strikethrough~~, inline code in a rounded box, fenced code blocks
*syntax-highlighted by their language tag* (` ```json `, ` ```bash `, ` ```csharp `… aliases included),
blockquotes including nested ones, ordered and unordered lists, task lists, horizontal rules, YAML
front matter, tables with columns aligned across rows, and `[label](target)` links which are
Ctrl+clickable.

- **Split** shows editor and preview side by side, with a **draggable divider** (position persisted
  globally, not per file, clamped to 15–85%). The two panes scroll independently — the wheel over each
  half moves that half — and are re-synced by block once a frame; **double-clicking a block in the
  preview scrolls the editor to it**.
- The preview scrolls in pixels and has its own scrollbar. It is bounded like every other viewport
  pass, so a huge markdown file previews without being parsed whole.
- *Limits:* **the preview is read-only and cannot be selected or copied.** Markdown **concealment**
  (hiding `#` and `**` on non-caret lines) is not built. Only `[a](b)` links work — no autolinks, no
  reference links — and a link inside a *table* cell is not clickable. Each source line is its own
  paragraph, so adjacent prose lines are not joined the way CommonMark joins them. A table wider than
  the pane is clipped with no way to reach the rest. Lists do not nest visually beyond their indent.

### Table view (CSV/TSV) — `Ctrl+T`

A grid over `.csv .tsv .tab .psv`, with a sticky header row, a delimiter chosen automatically on first
open, and column widths fitted from a 500-row sample (clamped 8–40 characters, leftover width shared
out proportionally). Only visible rows are parsed, so a multi-GB CSV opens and scrolls like any other
file.

- **Cells are editable in place.** Click a cell to start; `Enter` commits, `Esc` cancels, `Tab` commits
  and steps to the next cell on the row, and arrows/Home/End move inside the cell. The edit splices a
  single field back into the buffer, undoably.
- **Click a header to sort**, again to reverse, again to clear, with an accent arrow. **The sort is a
  view, and the file is never rewritten** — it is a permutation over row offsets, and editing a cell
  while sorted still writes to that cell's own line. Files over 100,000 data rows refuse the sort and
  the summary row says why; the ceiling is a freeze budget (100,000 rows sort in ~258 ms of release
  build on the main thread, and a million took two seconds, which is a hung window rather than a slow
  feature).
- **Sort by two columns**, first-selected-wins. **`Ctrl+click`** a second header adds it as the tie-break
  and cycles that key asc → desc → removed; a plain click still means "this column alone". **A header
  menu** — hover the header for a chevron, or right-click anywhere in it — carries Sort ascending /
  descending, *Then by* ascending / descending, Remove from sort and Clear sort, with the rows that
  cannot apply greyed rather than hidden. Each sorted column draws its own arrow, with a precedence
  digit once there are two. The limit is two keys, and the summary row says so when you reach it.
- **A row-number gutter**, 56px and right-aligned, with the current row brighter. A row whose absolute
  number cannot be known — one still being indexed, or the continuation of a line over 8 KB — draws no
  number rather than a guess.
- **Numeric and date columns right-align**, detected by sampling. **Drag a header edge to resize a
  column, double-click it to fit the content**; a width you set survives the recompute an edit triggers.
- **Malformed rows are marked, not hidden** — a row whose field count disagrees with the header keeps
  its place and gets a 2px warning bar on its left edge.
- **A summary row** at the bottom: row count, column count and the active sort. The row count reads as
  approximate (`~4.2M rows`) while the background line index is still running, rather than showing a
  settled number that later changes.
- **`Shift+wheel` pans columns.** **Ctrl+click follows a link inside a cell.**
- Empty cells draw an em dash so "parsed, and empty" is distinguishable from "missing".
- Fields quoted with `"` (and `""` escaping) are parsed within a line.
- *Limits:* a quoted field spanning a newline is not handled — each visible line is one row. Sorting is
  not persisted across a session. Every other buffer-mutating command is blocked while the grid is up.

### Zoom — `Ctrl+=` / `Ctrl+-` / `Ctrl+0`

Fourteen discrete steps from 50% to 400%, saved. Zoom scales the **document text only** — the menus,
tabs and status bar keep their own size, so zooming in never makes the chrome unreadable.

---

## Syntax highlighting

Viewport-scoped: only visible rows are lexed, with state resynced from an anchor rather than from the
top of the file, so it is instant at any size.

**Languages with real lexers** (from `EXT_LEXERS`):

| Family | Extensions |
|---|---|
| C-family | `.c .h .cpp .hpp .cs .java .js .ts .go .rs .odin .css .sql` |
| Markup / data | `.xml .html .json .md .markdown .mkd .mdown .mdwn .mdtext .mdx .mtext` |
| Config | `.ini .cfg .conf .env .gitignore .toml .yaml .yml` |
| Shell | `.sh .bat .ps1` |
| Delimited | `.csv .tsv` |
| Logs | `.log` (levels: `ERROR WARNING WARN INFO DEBUG TRACE`) |

**`.txt` is deliberately plain** — there is no grammar to find. **`.py` has no lexer** and is a known
gap, left plain rather than forced through a lexer that would only get comments right.

### Colour rules — `View ▸ Edit Colour Rules...`

`%APPDATA%\Newtpad\rules.txt`: one `pattern = Role_Name` per line, matched as a **literal substring**
against every visible row. Rules name a theme colour role rather than an RGB value, so the same file
reads correctly in Dark and Light and re-colours instantly when you switch theme. Up to 64 rules,
patterns up to 64 characters. Saving the file applies it on the next frame.

*Limits:* literal substrings only — `^ERROR` matches the six characters, it is not an anchor. Matching
is case-sensitive, a pattern cannot start with `#`, and precedence is **links > lexer > rules**, so a
rule for a word the lexer already colours (`ERROR` on a `.log`) changes nothing there — the seeded file
says which words those are. Rules do not reach the markdown preview or the grid.

---

## Links and paths

Build logs, stack traces and linter output are full of paths, so **Ctrl+click follows them**. Detection
is viewport-scoped — only visible lines, capped at 4096 bytes per line.

- **URLs**: `http://`, `https://`, `mailto:` open in the browser. `smb://` is rewritten to its UNC form.
- **Paths**: absolute (`C:\...`), rooted, `./`, and paths relative to the document's folder. A
  **`:123` or `:123:45` suffix** is understood and jumps to that line and column.
- **A text-ish target opens as a tab**; anything else (or a directory) is *revealed* in Explorer, never
  executed.
- **Ctrl+click works in the document, in table cells, and in the markdown preview.** The keyboard
  equivalent is the palette-only **Open Link Under Cursor**, which scans the caret's own line.
- **Show links** in Settings chooses when the decoration appears: *On Ctrl* (default), *Always,
  underlined*, or *Always, tinted*.
- A link that would not resolve is not decorated, so an underline is a promise.
- *Limits, and they are real:*
  - **Non-local targets never resolve.** `\\server\share\...`, `smb://`, a mapped network drive, an
    unmapped drive letter, or a CD-ROM: nothing is stat'd and nothing is decorated, because stating an
    unreachable UNC host blocks the calling thread for the redirector timeout (>100 s measured).
    Ctrl+click on one still *reveals* it in Explorer, which is safe because Explorer resolves it in its
    own process.
  - **Every link in a document opened from a UNC path or mapped network drive fails the same way**,
    including plain relative ones — the anchor itself is non-local.
  - A `..` parent walk is refused; the anchor is the document's folder, full stop.
  - A bare `/` or `\` between two words is not evidence of a path — `24/7`, `he/she`, `07/28/2026` are
    not links. A token needs a known text extension or a real root/anchor prefix.
  - `ms-msdt:` and similar handler schemes are never links.

---

## Appearance

- **Themes**: *Dark* (default) and *Light* are compiled in. Any `*.theme` file dropped in
  `%APPDATA%\Newtpad\themes\` appears as a choice in Settings by its filename stem.
- **`View ▸ Edit Current Theme...`** exports the active theme to a `.theme` file, opens it as a tab, and
  **re-applies it every time you save** — a live tuning loop with no rebuild. The format is one
  `role #rrggbb` per line over a fixed set of semantic roles, grouped into neutrals / accents / syntax,
  with a `base dark` or `base light` line to inherit from. Deleting a line falls back to the base
  theme's value; an unknown role or a malformed colour is skipped and logged, never fatal. An existing
  file is never clobbered.
- **Document font**: `Edit ▸ Font` — family, style and size (8–72 pt), stepped with `←`/`→`. The list is
  a curated set of **monospace** families, filtered to what is actually installed: Consolas, Cascadia
  Mono, Cascadia Code, Courier New, Lucida Console, Lucida Sans Typewriter, DejaVu Sans Mono, JetBrains
  Mono, Fira Code, Source Code Pro, IBM Plex Mono, Hack, Iosevka, Ubuntu Mono. Deliberately not the
  native font dialog, which would offer proportional faces that break the cell grid.
- **Interface font** is set separately, in Settings, from the same list — choosing a document font can
  never make the menus unreadable. Defaults to Cascadia Mono.
- **Multilingual text** renders via per-codepoint font fallback (Consolas → Microsoft YaHei for CJK →
  Segoe UI Symbol → Segoe UI): Latin, Cyrillic, Greek, CJK, accents and symbols all draw.
  *Limit:* no complex-script shaping (Arabic, Indic, ligatures), and the caret / hit-test / selection /
  find rectangles assume a monospace column, so they misalign on CJK and emoji. No colour emoji.
- **Per-monitor DPI v2.** Drag the window between a 4K and a 1080p monitor and everything rescales;
  DPI is clamped to 96–960 (100%–1000%).

---

## Settings

`View ▸ Settings` (palette: *Settings*). A full-window page, not a dialog — `Esc` closes it, `↑`/`↓`
choose, `Enter` toggles or resets, `←`/`→` step. Ten rows, deliberately:

| Row | Values |
|---|---|
| Restore session on launch | On / Off |
| Word wrap new documents | On / Off |
| Zoom | 50–400%, `Enter` resets to 100% |
| Show links | On Ctrl / Always, underlined / Always, tinted |
| Markdown default view | Off / Preview / Split — applied when a `.md` opens fresh |
| Table default view | Off / Table — applied when a `.csv`/`.tsv` opens fresh |
| Remember last view used | On makes the two rows above learn from what you last did; Off pins them |
| Theme | Dark, Light, or any `.theme` file |
| Tab width | 1–16, `Enter` resets to 4 |
| Interface font | any installed family from the curated list |

Settings live in `%APPDATA%\Newtpad\settings.txt` as plain `key value` lines. Unknown keys are ignored,
so an older build reading a newer file degrades rather than failing.

---

## The command palette and the keyboard

**`Ctrl+P`** — the universal access point. Four modes, chosen by a leading character:

| Prefix | Mode |
|---|---|
| *(none)* | fuzzy-switch open tabs |
| `>` | run any command, with its shortcut and category shown |
| `:` | go to a line number |
| `?` | list these prefixes |

Fuzzy matching with fzf-style bonuses, an exact-prefix boost, and a **recency tie-break** — two
commands that score the same are ordered by which you ran more recently, and a command run from a
*menu* teaches the palette exactly as one run from the palette does. Matched characters light up in
the accent colour. Rows are clickable and hoverable; clicking outside dismisses.

### Menu bar

`File · Edit · View · Encoding · Help`, opened by clicking, by tapping `Alt` (keyboard mode), or by
`Alt+F` / `Alt+E` / `Alt+V` / `Alt+N` / `Alt+H`. Arrows and `Enter` walk it; `Esc` unwinds one level.
Rows show their shortcut, carry a check mark for the toggles, and scroll (with ▲/▼ markers) when the
window is too short for the dropdown. A row that does not apply is greyed out and — where there is a
reason worth giving — replaces its shortcut with that reason.

### Rebindable keys — `View ▸ Edit Keybindings...`

Real, and it writes the file for you. `%APPDATA%\Newtpad\keys.txt`, one `chord = Command` per line
(`ctrl+k = Undo`), seeded with every default binding commented out plus every command that has no
default chord — it is the only place in the product that lists the command names. **Saving it re-reads
it**, so a binding can be tried without restarting, and a refused line reports
`[KEYS.TXT: n LINE(S) REFUSED - see the log]`.

Four things it will not let you do, each for a stated reason:

1. **Shift is not part of a chord.** `ctrl+shift+k` is refused rather than quietly bound to `ctrl+k`.
   Commands that care about shift read it themselves (shift+arrow extends, `Shift+Enter` searches
   backwards, `Shift+F2` goes to the previous bookmark).
2. **It binds the editor only.** Find, the palette, the menus, Settings and the Font page keep their own
   keys, so nothing you write can trap you inside one of them with unsaved work.
3. **`Esc`, `Ctrl+S` and `Ctrl+P` are reserved** — cancel, save, and the palette that can still run
   every command including *Edit Keybindings...*
4. **No unmodified letters, digits, `+` or `-`** — the character is typed independently of the keymap,
   so the command would also run every time you typed it.

Chords Windows owns (`Alt+F4`, `F10`) are refused too. An empty right-hand side unbinds a chord; the
last matching line in the file wins. Deleting the file restores every default. An `alt+<letter>` binding
does take over the menu bar's Alt shortcut for that letter — documented in the seeded header, not
refused.

---

## Encoding and line endings

Both are shown as **clickable cells in the status bar**, and both have menus.

- **`Encoding ▸ Reopen as UTF-8 / UTF-16 LE / Windows-1252`** re-reads the file under a forced encoding
  when detection got it wrong. Confirms first if there are unsaved changes; a failed read leaves the
  document exactly as it was. *Limit:* re-decoding as anything but UTF-8 reads the whole file at once,
  so it refuses above **64 MB** — and refuses rather than guessing if the file cannot be measured.
  Reopening as UTF-8 keeps the mapping and is free at any size.
- **`Encoding ▸ Save as UTF-8 / UTF-16 LE / Windows-1252`** changes what the *next save* writes.
- **`Encoding ▸ Line Endings: LF / CRLF`** rewrites the whole buffer, undoably.

---

## The status bar

Two groups with fixed homes, so the eye learns where to look.

- **Left:** `Ln N, Col N` · the line count, replaced by `N selected` (in the accent) while there is a
  selection · a `*` when modified · and every transient warning: recovered copy, changed/deleted on
  disk, indexing progress, glyph cache full, large-file-not-backed-up.
- **Right:** the encoding and line-ending cells (clickable), and the active view name
  (`Wrap`, `Table (Ctrl+T)`, `Markdown Preview (Ctrl+M)`, `Markdown Split (Ctrl+M)`).
- **Cells drop right-to-left as the window narrows** — measured against what the left group actually
  needs, so it holds at any DPI and font. `Ln/Col` and the line count never drop.
- Transient notices (`[SAVED]`, refusals, `[REPLACED n OCCURRENCE(S)]`) appear centred for a few
  seconds, green for confirmations and amber otherwise.

---

## Diagnostics, crashes and updates

- **Logging is on by default**, to `%APPDATA%\Newtpad\logs\newtpad.log` (append, rolled at 2 MB), with
  breadcrumbs recording which command ran. **`View ▸ Open Logs Folder`** opens it.
- **Crash handling.** An unhandled exception (including an Odin panic or assert) saves your unsaved
  work first, then writes a `.dmp` minidump and a human-readable `.txt` report that folds in the log
  breadcrumbs, then tells you where they are and offers to open the crashes folder or a **prefilled
  GitHub issue**. Nothing is ever sent automatically.
- **GPU loss** (driver update, TDR, eGPU unplug, RDP session change) writes the session, says what
  happened, and exits cleanly rather than freezing with your text inside it.
- **`Help ▸ Check for Updates (contacts GitHub)`** — the only command in the product that touches the
  network, and the title says so. One HTTPS GET to the GitHub Releases API, on a worker thread, with a
  numeric version compare; a tag it cannot parse reports "could not check", never "up to date". **No
  background traffic, no telemetry, no timers.**

---

## Keyboard reference

Everything with a default chord. Contexts other than the editor are noted.

### Editor

| Chord | Command |
|---|---|
| `←` `→` `↑` `↓` | Move caret (with `Shift`: extend selection) |
| `Ctrl+←` `Ctrl+→` | Move word left / right |
| `Home` `End` | Line start / end |
| `Ctrl+Home` `Ctrl+End` | Start / end of file |
| `PgUp` `PgDn` | Page up / down |
| `Backspace` `Delete` | Delete backward / forward |
| `Ctrl+Backspace` | Delete word backward |
| `Enter` | Insert newline |
| `Tab` | Insert tab (indents a live column rectangle) |
| `Ctrl+Z` / `Ctrl+Y` | Undo / Redo |
| `Ctrl+A` | Select All |
| `Ctrl+C` `Ctrl+X` `Ctrl+V` | Copy / Cut / Paste |
| `Esc` | Clear selection (and any column rectangle) |
| `Ctrl+S` | Save |
| `Ctrl+Alt+S` | Save As... |
| `Ctrl+N` `Ctrl+O` `Ctrl+W` | New Tab / Open File... / Close Tab |
| `Ctrl+Tab` (`Shift+`) | Next / previous tab |
| `Ctrl+PgDn` `Ctrl+PgUp` | Next / previous tab |
| `Ctrl+F` | Find |
| `Ctrl+H` | Replace |
| `Ctrl+L` | Filter to Matching Lines |
| `Ctrl+Enter` | Replace Match |
| `Ctrl+Alt+Enter` | Replace All |
| `Ctrl+G` | Go to Line... |
| `Ctrl+P` | Command Palette |
| `Alt+↑` `Alt+↓` | Move line up / down |
| `Alt+Shift+↑` `Alt+Shift+↓` | Extend column selection up / down |
| `Alt+Shift+←` `Alt+Shift+→` | Extend column selection left / right |
| `Alt+Z` | Word Wrap |
| `Ctrl+T` | Table View (CSV/TSV) |
| `Ctrl+M` | Markdown Preview / Split |
| `Ctrl+=` / `Ctrl+-` / `Ctrl+0` | Zoom in / out / reset (numpad `+`/`-` also work; the menus spell it `Ctrl++`) |
| `Ctrl+F2` | Toggle bookmark on this line |
| `F2` / `Shift+F2` | Next / previous bookmark |
| `Alt` (tap) | Menu bar keyboard mode |
| `Alt+F` `Alt+E` `Alt+V` `Alt+N` `Alt+H` | Open File / Edit / View / Encoding / Help |

### Find bar

| Chord | Command |
|---|---|
| `Enter` / `Shift+Enter` | Next / previous match (in the replace field: replace and advance) |
| `Tab` | Switch between the search and replace fields |
| `Esc` | Close find |
| `Ctrl+F` | Leave filter view, back to search |
| `Ctrl+H` | Toggle the replace row |
| `Ctrl+L` | Toggle filter view |
| `Ctrl+V` | Paste into the field |
| `Alt+C` `Alt+W` `Alt+R` | Match case / whole word / regular expression |
| `PgUp` `PgDn` | Page the filtered list |

### Table cell edit

`Enter` commit · `Esc` cancel · `Tab` commit and move to the next cell · `←` `→` `Home` `End` within the
cell · `Backspace` `Delete`.

### Settings / Font pages, the undo-history panel, the palette, menus

`Esc` closes · `↑`/`↓` move · `Enter` activates · `←`/`→` step a value (Settings and Font).

### Commands with no default chord

Reachable from the palette (`Ctrl+P`, then `>`), from a menu, or by binding them in `keys.txt`:

- **Palette-only, no menu row:** Sort Lines · Sort Lines Descending · Remove Duplicate Lines ·
  Open Link Under Cursor · Extend Column Selection Up / Down.
- **Menu + palette:** Reload from Disk · Exit · Settings · Font... · Undo History · Edit Current
  Theme... · Edit Keybindings... · Edit Colour Rules... · Open Logs Folder · Check for Updates ·
  Reopen as UTF-8 / UTF-16 LE / Windows-1252 · Save as UTF-8 / UTF-16 LE / Windows-1252 ·
  Line Endings: LF / CRLF.

*Known dead entries:* **Extend Column Selection Left** and **Extend Column Selection Right** appear in
the palette but do nothing when run from it — they read the `Shift` state of the key event that
invoked them, and the palette supplies none. Their `Up`/`Down` siblings work, because they have no bare-key
behaviour to preserve.
