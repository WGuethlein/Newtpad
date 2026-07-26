# Batch 6 — view persistence, encoding surface, and four debts

Design, 2026-07-26. Batch 6 of the plan in [HANDOFF.md](../../../HANDOFF.md) §6u, following
v0.15.1. Ships as **v0.16.0**.

§6u listed five items. Wyatt added three more from the debt register when the batch was scoped, so
this is nine tasks — but seven of them are small, and two pairs share one mechanism.

| # | Item | Source |
|---|---|---|
| 1 | One `Doc_View` definition | new; serves 2 and 3 |
| 2 | Session persists `md_mode`/`table` | §6u, §6t task-5 finding |
| 3 | `doc_reload` keeps the view | §6u, §6t whole-branch review |
| 4 | Encoding menu + reopen-with-encoding | §6u |
| 5 | Open Logs Folder | §6u |
| 6 | `on_resize`/`on_dpi` crash-reporter context | §6u, §6t task-3 finding |
| 7 | Block-edit undo coalescing | §5 debt register |
| 8 | Gate `test_modes.odin` behind a build flag | §5 debt register, §6t |
| 9 | Paste line-ending normalisation | §6t whole-branch review |

**One correction to the framing.** §6u's "encoding commands in the menus" reads as new work; it is
not. `.Enc_UTF8`, `.Enc_UTF16LE`, `.Enc_CP1252`, `.Eol_LF` and `.Eol_CRLF` already exist in the
command table under category `Encoding` (`commands.odin:199-203`) and already work from the palette.
They have simply never been in a menu. The only new command group here is *reopen*-with-encoding,
which does not exist in any form.

---

## 1. One definition of "the view"

Items 2 and 3 are the same bug twice. `doc_reload` rebuilds a `Document` via `doc_open` and carries
`wrap` forward but not `md_mode`/`table`; `session.txt` records `wrap` and not `md_mode`/`table`
either. Fixing them separately produces two places that each decide what "the view" is, and they
will disagree — that is Shape B in [development-loop.md](../../development-loop.md) §4, and this
codebase has produced sixteen instances of it in one session.

So the view becomes a value with one apply procedure:

```odin
Doc_View :: struct {
    wrap:        bool,
    md_mode:     Md_Mode,
    table:       bool,
    table_delim: u8,   // ',' or '\t'; 0 = not chosen yet
}

doc_view_capture :: proc(doc: ^Document) -> Doc_View
doc_view_apply   :: proc(doc: ^Document, v: Doc_View)
```

**`doc_view_apply` is the only place a stored view meets a document**, and it validates rather than
trusts:

- `md_mode` is applied only when `doc_can_markdown(doc)`, otherwise `.Off`.
- `table` is applied only when `doc_can_table(doc)`, otherwise `false`.
- Turning `table` on goes through the same delimiter-selection the `.Toggle_Table` case uses
  (`commands.odin:893`), not a bare `doc.table = true`. A `table` set without `table_delim` is a
  grid with no columns.
- `md_mode != .Off` and `table` are mutually exclusive; `table` wins if a malformed file somehow
  carries both, because the table guard in `command_dispatch` is the stricter one.
- `top` is re-anchored to a line start when a view that scrolls by logical line is turned on, the
  same as the toggles do.

Consumers: `session_save`/`session_restore`, `doc_reload`. Nothing else. `app_apply_view_defaults`
(§6t) stays exactly as it is and keeps applying *family defaults on fresh open only*.

**Why validation lives here and not in the callers:** the interesting cases are all "the file is not
what it was". A `.md` tab restored after the file was replaced by something unparseable, a CSV tab
whose log rotated into non-tabular text — both arrive through a different caller, and a check in
each caller is a check that will be forgotten in the third one.

### Non-goal

Persisting `filter`, `h_scroll`, `table_col`, or a live column rectangle. Those are transient view
state, not a mode; a restored filter with no query is an empty screen, and §6y established that a
rectangle must not survive anything that changes what a row means.

---

## 2. Session format 3 → 4

Two fields appended to each tab line, before the path (the path is last because it may contain
spaces and the parser splits on a field count):

```
<cursor> <anchor> <top> <wrap> <enc> <backupIdx> <mtime> <size> <had_bom> <eol> <md_mode> <table> <path...>
```

Header becomes `newtpad-session 4`; `session_restore`'s existing version ladder gains a `ver >= 4`
arm with `nf = 13`. A v3 session still loads and its tabs come back with the view `.Off`/`false` —
the same tolerant-versioned parse that let format 1 and 2 sessions survive two format changes
already.

`md_mode` is range-checked on load and degrades to `.Off` when out of range, exactly as
`link_style`/`font_style` are in `settings.odin`. An enum built from an arbitrary integer read off
disk is a real hazard in Odin: an out-of-range value makes every `switch` on it fall through and
`md_mode_name` return garbage.

**The seam that must not move:** `session_restore` builds its Documents directly and must continue
*not* to call `app_apply_view_defaults`. A restored tab's own recorded view outranks the family
default — otherwise leaving one `.md` in Split teaches the default, and every restored `.md` comes
back Split regardless of how it was left. `viewmemtest` already asserts this and the assertion was
sabotage-verified in §6t; it must still hold, and now with a genuinely round-tripped value behind
it rather than a constant.

---

## 3. `doc_reload` keeps the view

`doc_reload` captures a `Doc_View` before `doc_close` and applies it after `doc^ = fresh`, in the
same place `wrap` is carried today (`doc.odin:1383`). `wrap`'s open-coded carry is deleted, not left
beside the new one.

The reload path is the one that most needs the validation: reload exists for **log tailing**, and a
rotated log is exactly the file that stops being a CSV between one read and the next.

`block_*` state deliberately keeps its current behaviour — `doc^ = fresh` zeroes it, so a rectangle
cannot survive a reload, and `doc_view_apply` must not resurrect one.

---

## 4. Encoding menu and reopen-with-encoding

### A new top-level `Encoding` menu

`menus` gains a fifth entry (`File`, `Edit`, `View`, `Encoding`, + the gear), mnemonic `n`:

```
Reopen as UTF-8                enabled = has_file
Reopen as UTF-16 LE            enabled = has_file
Reopen as Windows-1252         enabled = has_file
—
Save as UTF-8                  checked = current enc
Save as UTF-16 LE              checked = current enc
Save as Windows-1252           checked = current enc
—
Line Endings: LF (Unix)        checked = current eol
Line Endings: CRLF (Windows)   checked = current eol
```

Chosen over grouping these into File: `menu.odin` has no submenus, File is already nine rows, and
eight more would push it into the scrolling dropdown on a short window — the exact geometry that
produced the "Edit > Font was an invisible live strip" bug in §6j. A fifth menu title is cheaper
than a seventeen-row dropdown.

The `checked` procs follow the existing `is_wrapped`/`is_table` pattern; they are the first ones in
the tree that check a *value* rather than a bool, which is why they are worth writing once each
rather than inline.

### Reopen: re-decode from disk under a forced encoding

The gap this fills: `detect_encoding` can be wrong (a BOM-less UTF-16 file, a CP1252 file whose
high bytes happen to look like UTF-8), and today there is no way to say so. `doc_set_encoding` only
changes what the *next save* writes; it does not re-read anything.

`doc_open` grows an optional override:

```odin
doc_open :: proc(path: string, force_enc: Maybe(base.Encoding) = nil) -> (doc: Document, ok: bool)
```

When set, the sniff still runs (a BOM still tells us how many bytes to skip) but the returned
encoding is overridden before `decode_to_utf8`. One opener, one guarded-read path, one place that
knows about `safe_copy` — a second opener would be a second copy of the SEH discipline in §6/item 1.

Reopen then reuses `doc_reload`'s teardown with the override threaded through, so the index restart,
the revision carry-forward and the stamp reset are inherited rather than re-derived.

**On a modified tab it confirms first.** Reopening discards the buffer, and a menu row that silently
destroys unsaved work is the one thing this batch must not add. The dialog names the file, states
that unsaved changes will be lost, and defaults to Cancel — the same shape as
`plat.confirm_lossy_encoding`.

---

## 5. Open Logs Folder

Logging has been on by default since 0.9.0 (`%APPDATA%\Newtpad\logs\newtpad.log`) and is completely
undiscoverable — §6u's audit found it exists with no command and no menu entry.

New command `.Open_Logs_Folder` ("Open Logs Folder", category `View`), in the View menu directly
after `.Settings_Open` — that is where the other "app itself, not this document" rows already live
(`menu.odin:161-162`). New platform helper:

```odin
shell_open_folder :: proc(path: string) -> bool   // stats is_dir, then ShellExecuteW "explorer.exe"
```

It stats with the existing `path_exists` before calling the shell. `file.odin`'s standing rule is
that no arbitrary string reaches `ShellExecuteW`; this path is constructed from `session_dir()`
rather than read out of a document, so it is not untrusted input, but the `is_dir` check keeps the
helper safe for any future caller and makes "the folder does not exist yet" a `false` rather than a
shell error dialog.

The command creates the directory if missing (`diag_init` already does this on every launch, so in
practice it exists), and posts a note if the shell refuses.

---

## 6. `on_resize` / `on_dpi` crash-reporter context

Flagged in §6t task 3 and never fixed. Both callbacks do `context = runtime.default_context()`,
which silently resets `context.assertion_failure_proc` away from `diag_assert_fail` — the hook
`main()` installs so panics route through the crash reporter. A bounds check or panic inside a
resize or a DPI change therefore bypasses crash reporting entirely, on two callbacks that run
during window manipulation, which is when a layout bug would fire.

One helper in `diag.odin`:

```odin
diag_context :: proc "contextless" () -> runtime.Context {
    c := runtime.default_context()
    c.assertion_failure_proc = diag_assert_fail
    return c
}
```

Both callbacks use it. `main()` uses it too, so `assertion_failure_proc = diag_assert_fail` appears
exactly once in the tree. `window.odin` stays contextless as it is — package `platform` cannot reach
`diag_assert_fail` without inverting the layering, and its comment at `window.odin:486` already
explains why staying context-free is the right answer there.

---

## 7. Block-edit undo coalescing

From §5: 20 held presses over a rectangle is currently 20 undo entries, and with `UNDO_MAX :: 200` a
long hold evicts the pre-run state off the end of the stack — a small but real data-loss path, and
the same shape as the Replace All bug that made batching mandatory in §6i.

`doc_batch_begin` currently calls `push_undo` unconditionally. Block edits gain a coalescing arm:
a batch continues the previous entry when the previous edit was a block edit of the same kind **and
the rectangle is the same live rectangle**. The run breaks on:

- the rectangle being cleared or re-made (any `block_clear`, any new Alt+drag),
- any non-block edit,
- undo, redo, or a history-panel jump,
- a document reload or snapshot apply.

Identity is a monotonic `block_run` counter bumped in `block_clear`/rectangle creation, not a
comparison of the four `block_*` offsets — the rectangle legitimately *moves* during a run (each
press collapses it to a zero-width rectangle one cell along), so comparing coordinates would break
the run on exactly the case it exists for.

**Accepted consequence, confirmed with Wyatt:** one Ctrl+Z undoes the entire held-key run. That is
the point — the alternative is 300 presses of Ctrl+Z and a pre-run state that has already been
evicted.

History label: "Column edit ×N", counted the same way `Typed %d characters` is.

**No cap raise rides along.** `BLOCK_EDIT_MAX_LINES` stays at 300. §5 is explicit that the cap is
about per-press read cost through a fragmenting tree, that it was misdiagnosed twice, and that the
fix is a single batched region splice — none of which is this task.

---

## 8. Gating `test_modes.odin`

`test_modes.odin` is `package main`, so the whole headless harness ships inside the customer's
binary; §6t called it the highest-value size item by a wide margin.

```odin
NEWTPAD_TESTS :: #config(NEWTPAD_TESTS, ODIN_DEBUG)
when NEWTPAD_TESTS { ...entire file... }
when !NEWTPAD_TESTS { test_mode_dispatch :: proc() -> bool { return false } }
```

`build.bat`:

| Invocation | Opt | Harness |
|---|---|---|
| `build.bat` | `-debug` | in |
| `build.bat release` | `-o:speed -subsystem:windows` | **out** |
| `build.bat release tests` | `-o:speed -subsystem:windows -define:NEWTPAD_TESTS=true` | in |

The third row is not optional. §6y's live-pass item 4 — held Backspace over a ~300-row rectangle —
is explicitly a *release-build* measurement that the debug harness cannot answer, and gating without
a way back in would make that class of measurement impossible for good. Console subsystem is kept
for that row too, or the modes have nowhere to print.

Release size before and after gets **measured and recorded in the HANDOFF entry**, not asserted.
§6j's glyph atlas is the standing warning here: a size win that exists only in the commit message.

Known consequence: in a gated release build, `newtpad blocktest` is a request to open a file named
`blocktest`. That is correct behaviour for a shipped text editor and needs no special case.

---

## 9. Paste line-ending normalisation

Recorded in §6t's whole-branch review and deliberately not fixed then: `.Paste` writes clipboard
bytes verbatim (`commands.odin:781`). The Windows clipboard is CRLF by convention, so pasting
multi-line text into an LF file mixes line endings silently — through the most common way multi-line
text enters a buffer, and it is the exact harm the line-ending work was justified by.

Paste normalises the clipboard text to `doc.eol` at that one call site. Mixed input normalises
wholly. **Copy and Cut are not touched**: what leaves the document is what the document contains,
and rewriting on the way out would corrupt a deliberate paste into a different editor.

Placed in the `.Paste` case rather than in `doc_insert_text`, because `doc_insert_text` also carries
typed characters and table cell commits, where there is nothing to normalise and a scan would be
pure cost.

---

## Testing

Every task extends an existing headless mode where one fits; three need new coverage. Per
[development-loop.md](../../development-loop.md) §3, **each test is sabotage-verified — reintroduce
the bug, capture the failure output, restore** — and the captured output goes in the task report.

| Item | Test | The check that cannot pass with the bug present |
|---|---|---|
| 1, 2 | `sessiontest` | Save a tab in Split and a CSV in Table, restore, assert both come back; assert a v3 session still loads; assert an out-of-range `md_mode` degrades to `.Off` rather than producing an invalid enum |
| 1, 3 | `watchtest` | Reload a `.md` left in Split and assert `md_mode` survives; reload a Table CSV rewritten as non-tabular and assert it degrades to `.Off` rather than drawing a grid |
| 4 | new `enctest` | `doc_open` with a forced encoding decodes a BOM-less UTF-16 file that `detect_encoding` calls UTF-8; menu rows resolve to the right commands; `checked` tracks the live doc |
| 5 | `linktest` (extend) | `shell_open_folder` refuses a path that is not a directory. The `ShellExecuteW` itself is not exercised headlessly |
| 6 | new `ctxtest` | `diag_context()` returns a context whose `assertion_failure_proc` is `diag_assert_fail`, plus a grep-assert that no bare `default_context()` remains in `package main` |
| 7 | `blocktest` | N consecutive block edits produce **one** undo entry and one Ctrl+Z restores the pre-run text; a rectangle re-made mid-run produces two |
| 8 | build A/B | `build.bat release` then `build.bat release tests`; record both sizes and confirm the gated exe does not dispatch a mode name |
| 9 | new `pastetest` | Paste `"a\r\nb"` into an LF document and assert the buffer holds `"a\nb"`; and the CRLF direction |

The `blocktest` case must be added as its own local proc holding one `App` at a time — §6y hit
`STATUS_STACK_OVERFLOW` twice on that mode, and the trigger is total per-procedure frame size, not
the number of sibling blocks.

`sessiontest` and `watchtest` write to the session store: **`NEWTPAD_SESSION_DIR` must be set to a
temp directory** before any run.

## Risks worth naming to reviewers

- **Task 1/2/3** — a stored view applied to a file that no longer supports it. The failure is a
  grid over non-tabular text or a preview of something unparseable, and it arrives through whichever
  caller the test does not cover.
- **Task 2** — the format ladder. A wrong field count silently shifts the path field, and a tab
  whose path is `"0"` is a tab that opens the wrong file.
- **Task 4** — `doc_open`'s override interacting with the mapped-read guard. The non-UTF-8 branch
  takes a private guarded copy; a forced encoding must not route a mapped file down the unguarded
  branch.
- **Task 4** — the confirm on a dirty tab. A dialog that defaults to the destructive answer is worse
  than no command.
- **Task 7** — a run that never breaks. If a break condition is missed, an unrelated later edit
  folds into the block entry and one Ctrl+Z takes back more than the user did.
- **Task 8** — the gated release must still *build*, and the debug build must still run every mode.
  A `when` block that silently drops a proc the product calls is a link error at best.
- **Task 9** — a normalisation that also rewrites bytes inside the pasted text that were not line
  endings (a lone `\r` in the middle of a line is a real thing in log files).

## Order

1 → 2 → 3 → 4 → 5 → 6 → 7 → 8 → 9. Items 1-3 are one dependency chain; 4-9 are independent of each
other and of the chain, so a blocked task never blocks the batch. Task 8 goes late deliberately: it
changes how every other task's tests are built.
