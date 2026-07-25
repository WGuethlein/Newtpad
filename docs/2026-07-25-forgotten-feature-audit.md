# Forgotten-feature audit — 2026-07-25

A sweep of the whole tree plus `HANDOFF.md` and `CLAUDE.md` for work that was promised, started, or
committed to and then left. Wyatt's call on what gets built; this is evidence, not a plan.

Method: `TODO`/`FIXME` markers (there are **zero** — this project records debt in prose, not
markers), deferred-work language in comments, every locked rule in CLAUDE.md checked against the
code, HANDOFF §5's debt register re-verified line by line, and the command table checked for
declared-but-unreachable entries.

Verified against the tree at `0b878ef` (v0.11.0, both batches merged).

---

## A. Ship-blockers that are written down as ship-blockers

**A1. Glyph atlas has no eviction — and the failure is already user-visible.**
`platform/text.odin:12`: *"Atlas is grow-only for now; eviction is required before ship (project
rule)."* The status bar already carries a `[GLYPH CACHE FULL - some text may not draw]` warning
(`main.odin`), which exists because when the atlas fills, glyphs silently draw as nothing while the
pen still advances — text disappears with no other symptom. There is machinery for *relief* (a
grow-at-frame-boundary path, `text.odin:176,705,850`) but no eviction and no second page
(`text.odin:970`). A long session in a multilingual file reaches this. **This is the single most
user-visible unfinished item in the tree.**

**A2. `\\?\` long paths — still literally zero occurrences.**
CLAUDE.md states it as a hard rule: *"Long paths: `\\?\` prefixed wide paths internally; never depend
on the registry opt-in."* `grep -F '\\?\' src/` returns **0 hits**. So any path over ~260 characters
fails to open — reachable in a deep `node_modules`, a synced OneDrive tree, or a nested build output.
HANDOFF §5 records it accurately as owed; it has simply never been done.

**A3. `test_modes.odin` ships in the release binary, and it is now the largest file in the tree.**
4,218 of 13,708 lines — 31% of the codebase — and `package main`, so it is linked into the shipped
exe. §6s flagged it as the largest contributor to binary size; batch 2 added ~600 more lines. Release
is now 1.10 MB against the project's stated 2–3 MB target, so it is not yet urgent, but this is the
cheapest large win available and it grows every session.

**A4. Shaders compile at startup from embedded HLSL.**
`platform/quads.odin:6-8` plans precompiled `.cso` "before it ships, to drop the
`d3dcompiler_47.dll` dependency." Worth downgrading from how HANDOFF frames it: **I checked, and
`d3dcompiler_47.dll` is present in `System32` on Windows 10+**, so this is a startup-cost and
tidiness item, not a will-it-run-on-a-clean-machine risk.

---

## B. HANDOFF §5's debt register is partly stale — three items are already done

Worth fixing, because a register that lists finished work makes the live items harder to see.

**B1. "The app redraws at vsync when idle — no `WaitMessage` anywhere."** False now.
`platform/window.odin:28` has `window_wait_message` built on `MsgWaitForMultipleObjectsEx`, and
`main.odin:166` blocks on it. Done.

**B2. "Dead line-index anchors (`anchors`/`anchor_count` written but never read)."** Gone from
`doc.odin` entirely.

**B3. "7 headless test-modes clutter `main.odin` (~125 lines)."** They live in `test_modes.odin`
now; `main.odin` has two incidental references.

Still accurate and still owed: VirtualAlloc arenas (zero implementation — `base/base.odin:5` is a
comment, and the only `VirtualAlloc` call in the tree is a deliberate guard page in `seh.odin:49`),
and the un-batched text pipeline.

---

## C. Follow-ups promised in code comments

| Where | Promise | User-visible? |
|---|---|---|
| `platform/text.odin:492` | *"tabs are one cell for now (tab stops are a later feature)"* | **Yes** — a tab renders as one column, so indented code and `.tsv` files display wrong. Probably the highest-value item in this table. |
| `program/find.odin:6` | *"Group substitution (`$1`) is a follow-up"* | Yes, for regex replace — you can match groups but not reference them. |
| `program/session.odin:33` | serialize blocks the main thread while dirty; *"streaming/off-thread is the proper fix (owed)"* | Only on very large dirty buffers. |
| `platform/text.odin:455` | complex-script shaping (Arabic/Indic/ligatures) deferred | Yes for those scripts; a known locked-decision deferral. |
| `platform/text.odin:970` | atlas second page / eviction | See A1. |
| `program/doc.odin:21` | *"Real horizontal scroll is a later feature"* | **Stale.** H-scroll exists (`H_SCROLL` in 9 places, `hscrolltest` passes). What is actually true is that `VISIBLE_COLS :: 2048` caps how far it reaches. The comment should say that. |

---

## D. Found during this session's two batches

These are in HANDOFF §6s/§6t but collected here because they are the ones most likely to bite you.

**D1. `session.txt` does not persist `md_mode`/`table` — only `wrap`.**
Format is `cursor anchor top wrap enc backup mtime size had_bom eol path`. So a restored tab always
comes back with its view **off**. This is arguably part of the very thing you reported as "views
don't save state": batch 2 gave you per-family defaults for *newly opened* files, which is what you
asked for and chose, but a file you left in Split and reopened via session restore still comes back
plain. **My read: this is the highest-value item on the whole list**, because it is the remaining half
of a complaint you already raised.

**D2. `doc_reload` loses the view too.** It rebuilds via `doc_open` preserving `wrap` but not
`md_mode`/`table`, so an external-change reload silently resets a tab. Batch 2 made this more
visible: with a family default set, a reload now disagrees with what a fresh open of the same file
would do.

**D3. Paste writes clipboard bytes verbatim.** The Windows clipboard is CRLF by convention, so
pasting multi-line text into an LF file produces exactly the silent line-ending mixing that justified
fixing Enter this batch — via the most common way multi-line text enters a buffer. It was judged
"leave it, a paste should preserve what was copied," which is defensible, but it is the opposite
conclusion from Enter on the same harm.

**D4. `on_resize`/`on_dpi` disable crash reporting.** Both call `runtime.default_context()` and never
restore `assertion_failure_proc`, so a panic in either bypasses the crash reporter `main()` installs.
Two-line fix, and they run on every resize. Found while fixing the same bug in the drop handler.

**D5. Six test modes wrote real user state** — fixed this batch (they now refuse without
`NEWTPAD_SESSION_DIR`), noted because it went unnoticed for a long time and the same shape could
recur with the next mode.

---

## E. Small user-facing gaps

**E1. `--version` prints nothing from the installed binary.** The flag exists (`main.odin:45`) but
the release is GUI-subsystem, so it detaches from the console and the output goes nowhere. There is
no way to confirm which build is installed from a shell — I had to compare file size and timestamp.
Either attach to the parent console, or write it to a file, or accept it and document that Settings
is the only place to read the version.

**E2. Encoding conversion is palette-only.** `Save as UTF-8` / `UTF-16 LE` / `Windows-1252` are
declared and correctly dispatched (`commands.odin:757-761`) but appear in no menu, so they are
discoverable only via Ctrl+P. The line-ending commands beside them have the same gap.

**E3. Six mutually-exclusive drag flags in `main.odin`.** `scrollbar_drag`, `hscrollbar_drag`,
`md_preview_drag`, `divider_drag`, `sel_dragging`, `app.tab_drag` — each excluded from the others by
hand-written `&& !x` clauses, and batch 2 added two more such clauses. Every new drag costs O(n) new
exclusions in a 700-line frame loop. Not a bug today; it is the concrete way the tree is getting
harder to extract `ui` from.

---

## Suggested order, if you want one

1. **D1** — session persists the view. Finishes a complaint you already made, and it is a small
   format addition with an existing version-tolerant reader.
2. **A1** — atlas eviction. The only item here whose failure mode is "your text silently vanishes."
3. **C/tabs** — tab stops. Cheap relative to how wrong indented files look now.
4. **D4** — the crash-reporter gap. Two lines, and it silently undermines the crash suite shipped in
   0.9.0.
5. **A3** — gate `test_modes.odin` behind a build flag. Mechanical, and it stops the growth.
6. **A2** — long paths. Real, but you may simply never hit it.

Everything in **B** is bookkeeping: delete the three stale entries so the register means something.
