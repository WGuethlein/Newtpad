# Feature batch 2 — the four features from the 0.9.0 live-use report

Date: 2026-07-25. Branch `feat/live-feature-batch-2`, on top of the batch-1 bug fixes (0.10.0).

The same report that produced [batch 1](2026-07-24-bug-batch-1-design.md) asked for four features.
They were deliberately deferred so the live verification pass on the six bugs stayed small enough to
be a real signal. This is that second half.

Decisions taken by Wyatt before design (2026-07-25) are recorded inline as **Decided:** lines.

## Order

1. **Alt+Up/Down move line(s)** — self-contained, `doc.odin` only, and carries the batch's only
   data-loss risk, so it goes first per CLAUDE.md's priority order.
2. **Drag-and-drop open** — reuses an existing queue; small.
3. **Resizable split** — introduces `Settings.split_frac`, establishing the settings-extension
   pattern.
4. **View memory per file family** — the largest, and it extends `Settings` the same way.

## 0. Enter must write the document's own line ending (found during design)

Not in Wyatt's report. Found while working out feature 1's terminator handling: `commands.odin:571`
is `doc_insert_rune(doc, LF)`, a bare LF regardless of `doc.eol`. **Every Enter pressed in a CRLF
file writes an LF-only line**, so the file's endings mix silently — and `doc.eol` is detected once at
open and never recomputed, so the status bar keeps reporting CRLF and nothing surfaces it.

Same class as the `doc_delete_fwd` corruption batch 1 fixed, and it is priority-1 by CLAUDE.md's
ordering, so it goes in ahead of the features.

It is also a prerequisite rather than a digression: feature 1 must decide what terminator to
synthesise when moving a line into or out of the final position. If Enter writes LF, an `doc.eol`-aware
line move contradicts it; if line move writes LF to match, the bug spreads. Settling Enter first makes
feature 1's rule simply "use `doc.eol`", consistently.

`.Mixed` falls through to LF: the file already disagrees with itself, so there is no correct answer,
and LF is the harmless default `detect_line_ending` already returns.

**Scope note.** This widens the batch beyond the four requested features. It is one line of behaviour
plus a test, it shares feature 1's fixtures and concern exactly, and leaving it would mean shipping a
line-move that is careful about terminators next to an Enter that is not. Flagged for Wyatt rather
than assumed.

## 1. Alt+Up/Down move line(s)

**Decided:** move every logical line the selection touches, keep the selection so the keys can be
held/repeated, one undo entry per press, no-op at the first/last line rather than wrapping.

### What changes

- `Command_Id` gains `Move_Line_Up`, `Move_Line_Down`; `command_table` gains their rows (category
  `Edit`); `default_bindings` gains `{.Up, false, true, .Editor, .Move_Line_Up}` and the `.Down`
  mirror. The `#assert` on table length keeps registration compiler-enforced.
- `doc.odin` gains `doc_move_lines(doc: ^Document, delta: int)`.

**No platform work.** `WM_SYSKEYDOWN` is already handled alongside `WM_KEYDOWN` and explicitly
carries Alt combos (`window.odin:617-618`), and `alt_used` is set whenever Alt is held with another
key (`:625`), so the bare-Alt menu-mode toggle cannot fire on Alt+arrow. Verified before design.

### The mechanism

Take the logical span the selection touches — `pt_line_start` of `min(anchor, cursor)` to
`pt_line_end` of `max(anchor, cursor)` — and swap it with the adjacent logical line. Wrap the edit in
`doc_batch_begin`/`doc_batch_end` so a press is one undo entry, and shift `anchor` and `cursor` by the
byte delta so the selection follows and the keys can repeat.

Uses *logical* lines, not visual rows, so behaviour is identical with word wrap on. `revision` bumps
for free, since the edit routes through `push_undo`.

### The hazard — this is the priority-1 part

**Line terminators sit between lines, not inside them, and the last line usually has none.** A naive
"cut the span, paste it after the neighbour" either duplicates a terminator or loses one. Two ways
that becomes real damage:

- On a CRLF file, dropping or splitting a terminator leaves a bare LF — the exact silent
  line-ending corruption batch 1 had to fix in `doc_delete_fwd`.
- Moving the second-to-last line down, or the last line up, changes *which* line lacks a terminator.
  Getting it wrong either appends a newline the file never had or strips the one it did.

So the implementation reasons in terms of "line with its following terminator", and the final line is
an explicit special case rather than something the general path is assumed to cover. The document's
`doc.eol` is the terminator to write when one must be synthesised — never a hardcoded `"\n"`.

### Testing

Headless mode `movelinetest` (the logic needs a `Document`, so it is not an `odin test` case). Every
case asserts the **whole buffer's bytes**, not just the cursor, because the failure mode is a
terminator in the wrong place and a cursor check cannot see it:

- move up / move down in the middle of a file;
- no-op at the first line (up) and the last line (down), buffer byte-identical;
- the last line **with** and **without** a trailing newline, moved up, and its neighbour moved down
  into last position — on **both** LF and CRLF fixtures;
- a multi-line selection moved both directions, asserting the selection still covers the same text;
- one press is one undo: `doc_undo` restores the original bytes exactly.

## 2. Drag-and-drop open

**Decided:** each dropped file opens in its own tab, focus lands on the first. Folders are ignored
with a status-bar note. Files outside `text_exts.txt` still open, because the command line already
allows that and refusing on drop would be inconsistent.

### What changes

- `platform/window.odin`: `DragAcceptFiles(hwnd, true)` at window creation, and a `WM_DROPFILES`
  case that walks `DragQueryFileW`, converts each wide path to UTF-8, and pushes it into the
  **existing `open_paths` queue** — then `DragFinish`.
- `platform/file.odin`: `path_is_directory(path: string) -> bool`.
- `program/main.odin`: the existing `window_take_open_paths` consumer gains folder-skipping with a
  status note and focuses the first newly opened tab.

`core/sys/windows/shell32.odin` already declares `DragAcceptFiles` and `DragQueryFileW`, so no
hand-declaration and no new dependency. Verified before design.

### Why reuse `open_paths`

That queue exists for the single-instance handoff (`WM_COPYDATA`, `window.odin:419-430`) and its own
comment already anticipates multiple files: *"files in Explorer sends one per file"*. Producer
contract, `OPEN_QUEUE` cap, `OPEN_PATH_MAX` truncation and the `window_take_open_paths` consumer are
all in place. A second parallel path would be two things to keep in sync for no gain.

Overflow past `OPEN_QUEUE` is dropped, not truncated — matching the existing documented behaviour.

### Where the folder check lives

`platform` reports the fact (`path_is_directory`); `program` decides what to do and owns the
user-visible message. That keeps the layer rule intact: platform exposes plain data, policy lives
above it.

### Testing

A drop cannot be injected, but **the handler can**: the program-side path consumer is ordinary code.
Headless mode `droptest` pushes a mix — two real files, a directory, a nonexistent path — through the
same consumer and asserts which tabs exist afterwards, that focus is on the first opened file, that
the directory produced a note and no tab, and that a duplicate path activates the existing tab rather
than opening a second one (whatever the existing single-instance behaviour already is — the test
pins it rather than changing it).

## 3. Resizable split

**Decided:** one global fraction in `Settings`. The divider position is a personal preference, not a
per-file property.

### What changes

- `MD_SPLIT_FRAC` (a compile-time `f32(0.5)`) becomes `Settings.split_frac`, clamped to
  `[0.15, 0.85]` on load, on save, and on drag.
- `doc_editor_right` reads the setting. It is already the single source that the wrap width, the
  editor's scrollbar and the editor's click region derive from, so this stays one change rather than
  four.
- `md_divider_rect(doc, winw, winh) -> plat.Quad` — **one** procedure produced once and consumed by
  the draw, the hover cursor, and the drag hit-test, per the one-layout rule.
- Drag handling in `main.odin`'s existing mouse path; the hover sets a horizontal-resize cursor
  through the existing `window_set_cursor` mechanism.

### Persistence timing

The fraction updates live during the drag so the panes track the pointer, but `settings_save` runs
**on mouse-up only**. Writing on every `WM_MOUSEMOVE` would be hundreds of file writes per drag.

### Testing

Headless mode `splittest`:

- `md_divider_rect` and `doc_editor_right` agree at boundary window widths (1 px, very wide) — the
  drawn-vs-clickable comparison, not a check against a constant;
- a simulated drag clamps at both ends and cannot invert the panes;
- wrap columns and the editor scrollbar x follow the new fraction, so nothing still reads a hardcoded
  half;
- an out-of-range value in `settings.txt` is clamped on load rather than trusted.

## 4. View memory per file family

**Decided:** one default per family (markdown → Off/Preview/Split, tabular → Off/Table), learned
implicitly from the last view used, with a Settings row per family and a "remember last used" toggle
that pins it.

### What changes

- `Settings` gains `md_default: Md_Mode`, `table_default: bool`, `remember_views: bool`.
- `settings_load` / `settings_save` gain the three keys.
- The view-toggle command handlers write the new default when `remember_views` is on.
- A **fresh** document open applies the family default.
- The settings page gains two dropdowns and the toggle.

### Compatibility

The settings file is `key value` lines and `settings_load` already ignores unknown keys
(`settings.odin:88-89`, deliberate: *"an older build reading a newer file degrades instead of
failing"*). So no migration, and old and new builds interoperate in both directions.

### Two rules that keep it from being annoying

- **Session restore wins.** `session.odin` already persists per-tab view state. Applying a family
  default over a restored tab would silently change a view you had deliberately left set. The default
  applies on a fresh open only.
- **Existing gating still applies.** `doc_is_markdownish` / `doc_is_tabular` already decide whether a
  document may enter a view. A stored default cannot force a view onto a file that cannot hold it, so
  a stray `md_default` can never wedge a `.txt`.

### Testing

Headless mode `viewmemtest`:

- a fresh `.md` open picks up the stored default; a `.csv` picks up the tabular default;
- toggling a view writes the setting when `remember_views` is on and leaves it alone when off;
- a session-restored tab keeps its own stored view even when the family default differs;
- a `.txt` is unaffected by the markdown default;
- a nonsense value in `settings.txt` (a `md_default` out of enum range) degrades to Off rather than
  producing an invalid mode.

**Set `NEWTPAD_SESSION_DIR` and a temp settings location before running these** — they write real
state otherwise.

## Out of scope

- Rebindable keys (the runtime user-keymap overlay is separate, already-planned work).
- A duplicate-line command on Alt+Shift+arrow — offered and declined; the plumbing overlaps but it is
  scope Wyatt did not ask for.
- Per-family split fractions, and per-tab divider positions — one global fraction was chosen.
- Dropping a folder to open its text files (contradicts the no-project-trees scope rule).
- Any part of the project-wide forgotten-feature audit, which follows this batch as a written report.

## Verification owed to Wyatt

This environment cannot inject GUI input, so four things are his to confirm: Alt+arrow with a real
keyboard including auto-repeat; an actual Explorer drag of several files and of a folder; dragging
the divider and confirming the position survives a restart; and opening a `.md` after having left the
previous one in Split.
