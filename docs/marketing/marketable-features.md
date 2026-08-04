# Marketable features

The sales-facing list. The other three are engineering lists:

| File | Holds |
|---|---|
| **marketing/marketable-features.md** (this file) | **what we can truthfully sell, and what we cannot** |
| [../features.md](../features.md) | what is built and working today, in engineering terms |
| [../requested-features.md](../requested-features.md) | what is owed, asked for, or still unbuilt |
| [../reported-bugs.md](../reported-bugs.md) | open defects from daily use |

**The rule of this file: every claim carries its evidence and its limit in the same entry.**
A claim with no `src/` or measurement behind it does not go in. A claim whose limit would embarrass us
in a review thread goes in *with* the limit written down, so whoever writes the copy knows where the
edge is before a customer finds it.

This is deliberate, not cautious. The product's whole story is "someone actually did the work" — and
the fastest way to lose that story is a landing page that oversells by 10% and gets caught. File
Pilot's credibility comes from claims that survive being tested.

Started 2026-08-04. Measurements are from this repo at **v0.66.0** unless stated.

---

## The five headline claims

Ranked by how much work each does in a purchase decision.

### 1. It opens multi-gigabyte files instantly, and keeps working in them

**Claim:** open a 4 GB log and it is on screen immediately — scroll to the end, search it, filter it.
No progress bar, no "file too large", no waiting.

**Proof:** files over 16 MB are memory-mapped rather than read, so opening costs no read of the body
and almost no private memory (`../features.md` "Opening files"). The viewport walks lines on demand,
so a scroll position never costs a scan from the start. Line counting, search and syntax highlighting
are all viewport-scoped with background workers behind them.

**Limit (state it):** mapping is used only on local fixed drives — a file on a network share or a USB
stick is copied whatever its size. While a file is mapped, Windows itself refuses to truncate or
replace it, so a service cannot roll a log Newtpad has mapped; Newtpad detaches to a private copy the
moment it notices a change.

**Why it sells:** this is the wedge. It is the one thing Notepad, Notepad++ and VS Code all visibly
fail at, and the failure is dramatic and reproducible on a machine the buyer already owns.

### 2. It never locks your file

**Claim:** Newtpad open on a log does not stop your build, your service, or another program from
writing, moving or deleting it.

**Proof:** files are opened share-read/write/delete and the handle is closed immediately
(`../features.md` "Opening files"). External changes are detected by polling timestamp and size on a
background worker — never by a held handle.

**Limit:** the mapped-file caveat above is the one exception, and it is a moment rather than a state.

**Why it sells:** every sysadmin has been burned by an editor holding a lock. It is a small claim that
signals the whole product's character.

### 3. A live log tails itself, without losing your place

**Claim:** point it at a log a service is writing and new lines appear as they land. Your caret,
selection, search results and bookmarks all keep their meaning.

**Proof:** a background worker polls each open file once a second; a file that only grew is absorbed
as an append rather than a reload, with the view following the tail if the caret was already at the
end (`../features.md` "External changes").

**Limit:** UTF-8, BOM-less, unmodified buffers only. A dirty tab is never overwritten — it tells you
the file changed and leaves the choice to you. Only the first 32 open files are watched.

### 4. Filter-as-you-type

**Claim:** `Ctrl+L` collapses a million-line log to just the lines matching what you are typing, with
their real line numbers, updating on every keystroke. Click a line to jump to it in the whole file.

**Proof:** `../features.md` "Finding things". Searching runs on a worker, so the filter arms
immediately and fills in as results arrive rather than blanking the screen; buffers up to 256 KB scan
inline and larger ones get a bounded 64 KB first-paint pass plus a worker for the rest, so a keystroke
never waits on file size.

**Limit:** at most 100,000 matches are tracked at once, and a pattern spanning an internal block
boundary may not match. Regex is line-aligned.

**Why it sells:** this is the feature people do not know they want until they see it, and it is a
direct consequence of the speed work — exactly the "speed unlocks features" argument in the product
principles. It demos in four seconds.

### 5. One 1.4 MB exe, no install, no runtime, no telemetry

**Claim:** the whole product is a single file you can put on a USB stick. Nothing to install, nothing
in the background, no account, no network traffic.

**Proof:** measured 2026-08-04 from a clean `build.bat release`: **1,445,376 bytes (1.38 MB)**. The
only runtime dependencies are DLLs Windows already ships. Exactly one command in the product touches
the network — `Help ▸ Check for Updates` — and its menu title says so; there is no telemetry, no
background traffic and no timers (`../features.md` "Diagnostics, crashes and updates").

**Limit:** an optional Inno Setup installer exists but **has never been compiled or run**. The exe is
**not yet code-signed**, so SmartScreen will warn on first run — see "Cannot claim yet" below.

**Why it sells:** it is the proof of the other four claims rather than a claim of its own. "1.4 MB"
is how you make "fast" believable in one number.

---

## By area

### Opening and saving

| Claim | Evidence | Limit to state |
|---|---|---|
| Opens any text-ish file; 34 extensions registered with Explorer | `text_exts.txt` | Nothing stops you opening any other extension by hand |
| Encoding detected — UTF-8, UTF-16 LE/BE by BOM, BOM-less UTF-16 by NUL parity, Windows-1252 fallback | `../features.md` "Opening files" | Re-decoding as anything but UTF-8 reads the whole file, so it refuses above 64 MB |
| Line endings detected and **preserved** — LF, CRLF, or `Mixed` | same | — |
| **Writes are atomic** — temp file then rename, streamed in bounded chunks | `../features.md` "Saving" | — |
| **A save that would lose characters asks first** — counts the losses, offers Save as UTF-8 / anyway / Cancel | same | — |
| A failed save always says so | same | — |
| Hands a path to the already-running window rather than starting a second process | `../features.md` "Opening files" | — |

The atomic-write and lossy-save-confirm pair is worth more in copy than it looks: it is the difference
between "a text editor" and "a tool that will not eat your file", and Notepad itself gets the second
one wrong.

### Finding things

- **Incremental find** with every match highlighted as you type and the caret-nearest one selected.
- **Match ticks on the scrollbar**, drawn *under* the thumb so the marks you can see are the matches
  that are off screen. A small, genuinely well-considered touch.
- Match case, whole word, and **regular expressions** with `$1` / `${12}` / `$&` / `$$` in the
  replacement.
- **Replace All reports its count** and says so rather than silently replacing a prefix when it hits
  the 100,000-match ceiling.

### Views — the "it is not just a text box" argument

| View | Claim | Limit to state |
|---|---|---|
| **Markdown preview / split** (`Ctrl+M`) | Real proportional body type, headings, tables, task lists, fenced code **syntax-highlighted by language tag**, Ctrl+clickable links. Split has a draggable divider and double-click-to-sync-scroll. | Only `[a](b)` links — no autolinks or reference links. A table wider than the pane is clipped. Lists do not nest visually beyond their indent. |
| **CSV/TSV as a real grid** (`Ctrl+T`) | Sticky header, auto-detected delimiter, **editable cells**, **click-to-sort up to two columns as a view that never rewrites the file**, **Excel-style filter-by-column-value with type-to-search**, numeric/date right-align, malformed rows marked not hidden. Only visible rows are parsed, so a multi-GB CSV scrolls like any other file. | A quoted field spanning a newline is not handled. Sorting is not persisted across a session. Sort/filter refuse past 100,000 data rows, and say why. |
| **Word wrap** (`Alt+Z`) | Wrapped lines keep their indent plus two columns, so a wrapped stack trace still reads as one block. Capped at 100 columns so a maximised 1440p display does not give 200-character lines. | — |
| **Zoom** | 14 steps, 50–400%, and it scales the **document only** — chrome keeps its size, so zooming in never makes the menus unreadable. | — |

The sort-is-a-view property is the strongest single sentence available about the grid: *"sorting a
4 GB CSV rewrites nothing — it is a permutation over row offsets, and editing a cell while sorted
still writes to that cell's own line."*

### Syntax highlighting

Viewport-scoped: only visible rows are lexed, with state resynced from an anchor rather than from the
top of the file, so it is instant at any file size.

**Counted 2026-08-04, and mind the two different numbers — do not conflate them in copy:**

- **38 extensions get syntax highlighting** (counted from `highlight.odin:239-278`).
- **34 extensions are registered with Explorer** so they open in Newtpad on a double-click
  (`text_exts.txt`). Any other extension still opens fine by hand.

Behind the 38 are **9 hand-written lexers**, including **11 separate C-family keyword vocabularies**
(C, C++, C#, Java, JavaScript, TypeScript, Go, Rust, Odin, CSS, SQL — `lex_c.odin:912-1842`) and
**3 shell dialects** (bash, Windows batch, PowerShell — `lex_shell.odin:436-503`), plus JSON,
XML/HTML, Markdown, YAML, CSV/TSV, six config formats and a level-aware lexer for `.log`.

"Nine hand-written lexers, no plugins, no config, no language servers" is the honest and the better
line — the extension count is the supporting number, not the headline.

**Limit, and do not hide it: `.py` has no lexer.** It is left plain rather than forced through a lexer
that would only get comments right. For a product sold to developers this is the most likely single
objection in a launch thread — better to name it as a deliberate choice with a date attached than to
be caught.

**Colour rules** (`rules.txt`) are a genuinely differentiated feature: `pattern = Role_Name` per line,
naming a *theme role* rather than an RGB value, so the same file reads correctly in Dark and Light and
re-colours instantly on a theme switch. Saving the file applies it on the next frame.

### Links and paths — the underrated one

Build logs, stack traces and linter output are full of paths, and **Ctrl+click follows them**:
absolute, rooted, `./`, and paths relative to the document's folder, with a **`:123` or `:123:45`
suffix understood** so it jumps to the line and column. A text-ish target opens as a tab; anything
else is *revealed* in Explorer, **never executed**. Works in the document, in table cells, and in the
markdown preview.

**A link that would not resolve is not decorated, so an underline is a promise.** That sentence is
good copy and it is also literally what the code does.

**Limits, and they are real:** non-local targets (`\\server\share`, mapped network drives, `smb://`)
are never resolved or decorated, because stat'ing an unreachable UNC host blocks the calling thread for
the redirector timeout — over 100 seconds, measured. Every link in a document opened *from* a UNC path
fails the same way, including relative ones.

### Text handling

- **Multilingual text renders** via per-codepoint font fallback: Latin, Cyrillic, Greek, CJK, accents
  and symbols. **CJK and basic monochrome emoji have correct caret, selection and hit-testing** —
  verified by `emojitest` at v0.66.0, which measures `A<emoji>B` as 4 cells and puts the caret on the
  far side of the surrogate pair rather than inside it.
- **Limit:** no complex-script shaping — Arabic contextual forms, RTL and Indic reordering cannot work
  on a fixed cell grid, which is a locked architectural decision, not a to-do. No colour emoji (that
  one was a deliberate choice, not a gap).

### The keyboard and the interface

- **Command palette** (`Ctrl+P`) with four modes by prefix: fuzzy tab switch, `>` commands, `:` go to
  line, `?` help. Fuzzy matching with fzf-style bonuses and a **recency tie-break that learns from
  menu use as well as palette use**.
- **Rebindable keys that write the file for you** — `keys.txt` is seeded with every default binding
  commented out plus every command that has no default chord, and **saving it re-reads it** so a
  binding can be tried without restarting. Four things it refuses, each with a stated reason, and the
  reasons are good ones (it cannot trap you inside a modal surface with unsaved work; `Esc`, `Ctrl+S`
  and `Ctrl+P` are reserved).
- **Live theme tuning** — `View ▸ Edit Current Theme...` exports the active theme, opens it as a tab,
  and re-applies it every time you save. No rebuild, no restart.
- **Undo history panel** — Photoshop-style, jump straight to any past state. Every past state is
  already a cloned piece tree, so a jump is a tree swap rather than a replay.
- **Column / block editing** — `Alt+drag` or `Alt+Shift+arrows`, with typing, `Tab`, delete, copy and
  cut all as one undo entry.
- **Per-monitor DPI v2** — drag between a 4K and a 1080p monitor and everything rescales.
- **Hot exit** — closing the window never prompts. Tabs and unsaved buffers are restored next launch,
  carrying caret, scroll, wrap, encoding, view mode and bookmarks.

### Engineering proof points

These are for the "how" section of a landing page, the HN comment thread, and any technical
interview. Each is measured or traced in the tree, not asserted. Sources are the
[2026-08-04 audit reports](../audits/2026-08-04/).

| Claim | The number, and where it came from |
|---|---|
| **Editing cost does not depend on file size** | Piece tree (treap): every insert and delete is O(log n) whether the file is 2 KB or 4 GB (`piecetable.odin:17-22,126-225`). An independent audit traced split/merge/rotate case by case and found **no defect in the structure** |
| **Opening a UTF-8 file copies nothing** | The mapped bytes are the buffer (`encoding.odin:237-239`) |
| **Undo is proportional to edits, not bytes** | Every past state is a cloned piece tree, so jumping to one is a tree swap, not a replay (`piecetable.odin:280-289`) |
| **Search runs concurrently on a buffer that is being edited** | The add arena is chunked and chunks never move, so a `pt_view` stays valid across edits — the worker needs no lock and no copy (`piecetable.odin:24-35,291-313`) |
| **A keystroke in the find box never waits on the file** | 64 KiB searched inline so the frame you typed into already shows results; the worker resumes exactly where that stopped and no byte is scanned twice (asserted in-tree as `Search.swept`). Measured `-o:speed` on an 8 MB buffer: **0.10 ms literal, 0.29 ms regex** |
| **A whole frame is ~42 draw calls** | 38 `text_draw` + 4 `quads_draw`, measured by the in-tree `drawcount` mode. Text is GPU-instanced from a cached glyph atlas; all chrome is one SDF quad shape |
| **No launch flash** | The window stays hidden until the first present, replacing a **measured 196 ms white box** |
| **A yanked USB stick is a warning, not a crash** | Reads from a mapped file go through a real SEH shim, and the guard **tests itself against a deliberate page fault at startup** (`seh.odin:24-58`) |
| **Bounded scans admit when they gave up** | The capped scanners return an `exact` flag rather than a confident wrong answer (`piecetable.odin:371,433,492`) — this project's most-repeated bug class, named and guarded |
| **An atomic save keeps what the file was** | `ReplaceFileW`, so ACLs, alternate data streams and the `Zone.Identifier` mark survive a save — a plain write-and-rename loses all three |
| **Long paths work without the registry opt-in** | `platform/path.odin`, `\\?\` form applied at the file-I/O seam. **Note:** CLAUDE.md still says this is unimplemented; the code disagrees and the code is right |

**One number to be careful with:** "130 commands" (the command table has 131 rows including `.None`)
is true but oversells — 72 are palette-exposed and 59 appear in menus. Prefer "everything is one
`Ctrl+P` away" to a count that invites someone to go counting.

### Trust and diagnostics

This section is worth writing into the marketing copy explicitly, because it is unusual for a small
paid tool and it is cheap to verify:

- **No telemetry. No background network traffic. No timers. No account.** Exactly one command touches
  the network and its own menu title says so.
- **Crash handling that saves your work first**, then writes a minidump and a human-readable report
  folding in log breadcrumbs, then offers a *prefilled GitHub issue*. **Nothing is ever sent
  automatically.**
- **GPU loss** (driver update, TDR, eGPU unplug, RDP change) writes the session, says what happened,
  and exits cleanly rather than freezing with your text inside it.
- Everything it stores lives in one folder (`%APPDATA%\Newtpad`), redirectable with an environment
  variable.

---

## Cannot claim yet

Keep this section current. Anything here that gets written into copy is a lie with a date on it.

| Not claimable | Why | Where it is tracked |
|---|---|---|
| "Signed, installs cleanly" | The exe is **not code-signed**. SmartScreen will warn on first run. | Ship-readiness; signing is blocked on purchasing a certificate |
| "Installer" | `installer/newtpad.iss` exists but **has never been compiled or run** | `../features.md` "Opening files" |
| "Python highlighting" | `.py` has no lexer | `../features.md` "Syntax highlighting" |
| "Handles any language" | No complex-script shaping; RTL/Indic are architecturally out | `../requested-features.md` §4 |
| "Colour emoji" | Deliberately monochrome | as above |
| "Works over the network" | Non-local paths are never resolved, and mapping is local-drive-only | `../features.md` "Links and paths" |
| "Idles at zero CPU" | The app redraws at vsync when idle — no `WaitMessage` | HANDOFF §5 debt register |

---

## Positioning notes

*To be completed from the market research pass. Placeholder so the file has one home for it.*

The contrast that appears to do the most work, pending research:

- **vs. Notepad** — everything, but specifically: it will not eat your file, and it opens the log.
- **vs. Notepad++** — speed on large files, a modern UI, and the grid/preview views. Notepad++ is free
  and entrenched; the case has to be made on the large-file wedge, not on features-in-general.
- **vs. VS Code** — 1.4 MB against ~350 MB, instant start, and no project/workspace ceremony to read
  one file. Not competing on capability; competing on *not being an IDE*.
- **vs. paid large-file viewers** — Newtpad is an *editor* you would also use for everything else,
  not a single-purpose viewer.
