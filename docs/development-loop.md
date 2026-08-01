# The development loop

How work gets done on Newtpad. Written 2026-07-26, after four batches (§6s–§6w in
[HANDOFF.md](../HANDOFF.md)) settled into a loop that reliably catches things a single pass does
not. It exists because Wyatt asked that a new chat behave exactly like the one that built batches
1–4, and a loop that lives only in a conversation dies with it.

This is not process for its own sake. Every rule below is here because skipping it shipped a bug.
Where that's true the incident is named, because a rule with its incident attached survives and a
rule without one gets optimised away by the next session that's in a hurry.

---

## 0. Before anything: ask

CLAUDE.md states it and it is the most-violated rule, so it goes first.

**Ask 2–4 questions whose answers would change what you build.** Not clarifications, not
confirmations — decisions. Then wait. This applies to a bug batch, a feature, a refactor, and
"quick, just add X."

The test for a good question: if both answers lead to the same code, don't ask it. If one answer
means a per-document cache and the other means a global one, ask it.

Real examples that changed the outcome:

- *"Word wrap is on — is the shift you're seeing in the first ten rows the source text, or the
  renderer?"* → it was the renderer, and the answer redirected the whole markdown-table task.
- *"Should Ctrl+D be part of column editing?"* → no, and that removed a task.
- *"Surely those 44 roles can drop to 3–5"* → Wyatt's own push-back, which turned 66 proposed
  colour roles into 25 and made the theme model something a human would actually author.

Never rubber-stamp. If the request has an obvious problem, say so in a sentence or two and then
build the thing anyway under a stated assumption — scaling the work down is Wyatt's call, not
yours.

---

## 1. Spec, then plan, then execute

In that order, as separate artifacts, even when the work looks small. Wyatt has interrupted a
session mid-turn with *"well, start the work flow, don't just jump into it"* — diving into code is
the failure mode, and it happens when the work feels obvious.

| Stage | Skill | Artifact |
|---|---|---|
| Brainstorm → design | `superpowers:brainstorming` | `docs/superpowers/specs/YYYY-MM-DD-<topic>-design.md` |
| Design → tasks | `superpowers:writing-plans` | `docs/superpowers/plans/YYYY-MM-DD-<topic>.md` |
| Tasks → code | `superpowers:subagent-driven-development` | commits + a HANDOFF entry |

The spec is where decisions and their *reasons* live; the plan is where exact code, exact commands
and exact expected output live. A plan step that says "add appropriate error handling" is a plan
failure — write the code.

**The plan is not above review.** Reviewers found defects *in the plan* repeatedly, and the plan was
authored by the same process that executed it. When a reviewer says the plan is wrong, fix the plan
before the code. A sample of what got through plan self-review and was caught downstream:

- a symmetry test that compared index-for-index and was structurally incapable of passing
- a fixture sized below `SEARCH_SYNC_MAX`, so search ran inline and the test could never fail
- a cited procedure, `find_busy`, that does not exist (it's `search_running`)
- a bounds guard where the expression was invariantly zero — a dead check over an unbounded scan
- a "fixed-width caret slot" that preserved the exact double-space Wyatt had screenshotted

---

## 2. Execution: one subagent per task, review after every task

Follow `superpowers:subagent-driven-development`. The parts that matter most here:

**A fresh implementer per task.** It gets a task brief file, a report file path, and the interfaces
from neighbouring tasks — not the session's history. Pasted history is the single biggest waste;
one observed dispatch hit 42k characters of which 99% was prior-task summaries.

**A reviewer after every task, without exception.** Two verdicts required: spec compliance *and*
code quality. The reviewer prompt must say, in substance:

> Do not trust the implementer's report. Re-derive its claims independently from the code.
> Here are the specific risks this task carries: […]. Categorise findings by actual severity and
> acknowledge what was done well before listing issues.

Naming the risks is what makes the difference. A reviewer told "review this diff" finds style; a
reviewer told "this task threads state across a bounded scan — check what happens when the scan
hits its bound" finds the bug.

**One fix subagent per review round, with the complete findings list.** Not one fixer per finding —
each rebuilds context and re-runs suites, and a per-finding fix wave has cost more than all of a
batch's tasks combined.

**A whole-branch review at the end, on the most capable model.** Point it at what the per-task
reviews *structurally could not see*: cross-cutting invariants, whether the app is correct at every
commit, whether counters and assertions actually observe the thing they're named after, whether the
batch made the planned `renderer`/`ui` extraction harder. Hand it every finding the batch carried
deliberately and make it triage each one: carry, or block?

Batch 3's whole-branch review is the argument for this stage. `main.odin` passed the document
canvas clear colour to `gfx_begin_frame` as three loose `f32` arguments rather than a `[4]f32`.
Every migration grep in the batch matched `{r, g, b, a}`, so it was invisible to all five task
reviews. Under the new Light theme that was near-black text on a near-black canvas across the
entire document body, with correct chrome around it.

**Keep a durable ledger.** `.superpowers/sdd/progress.md`, one line per completed task with its
commit range. Conversation memory does not survive compaction; controllers that lost their place
have re-dispatched entire completed task sequences.

---

## 3. Sabotage discipline

CLAUDE.md: **"A test that has never failed proves nothing."** Operationally:

1. Write the fix and the test.
2. **Reintroduce the bug.** Run the test. Watch it fail. Record the exact output.
3. Restore the fix. Run it again.
4. Put the failure output in the report. "I verified it fails" without the output is not evidence.

This is the single highest-yield rule in the file. Things it has caught:

- A "fixed" glyph atlas that grew only in the commit message.
- A no-shift test that reused one `Document`, so the cache short-circuited it and it passed
  regardless.
- `lexstatetest`'s "resync cost is window-bounded, not file-bounded" check, which asserted
  `small == big` and passed — while the counter it measured could not see the 64 KiB window read
  that the check is named after. Vacuous for as long as it existed.
- `highlighttest`'s "wrapped row past `WRAP_START_CAP`" case, where sabotaging the guard the comment
  spends two paragraphs on leaves every assertion green. The reason turned out to be sound
  (`WRAP_START_CAP == RENDER_LINE_CAP`, so a second guard catches the same rows) but it was a
  coincidence of two constants, not a property — so it is now `#assert`-ed.

Prefer a check that *cannot* pass with the bug present: pointer identity over content comparison
when the bug is a use-after-free; a real device over arithmetic when the claim is about the GPU.

---

## 4. The shape that keeps recurring

Newtpad's bugs are not randomly distributed. Two shapes account for most of them, and looking for
them by name is more productive than reading a diff top to bottom.

**Shape A — a bounded scan reports a confident wrong answer.** A procedure reads a capped or
truncated slice, cannot tell that it was truncated, and returns as though it saw everything. Seven
instances so far, six of them in one batch:

- `lex_xml` stopped scanning when its *token buffer* filled, so a `<!--` after token 64 was
  invisible and corrupted every later line's state.
- `lex_c_resync_valid` did the same at its own 256-token buffer.
- Then again at a truncated line.
- `doc_row_lex_spans` discarded `pt_line_start_cap`'s `exact` flag and used a scan floor that
  *slides with the row* as though it were a line start.
- `links_layout` had the identical bug with a 4096-byte cap — with word wrap on, a URL past ~4 KB
  into a logical line was neither underlined nor clickable.

When you find one, **go looking for the next one**. Both the fourth and fifth instances were found
only because a reviewer was explicitly told "three of these have been fixed; is the shape gone
everywhere, or is there a fourth?"

**Shape B — a correct, tested function fed the wrong input, or its result read in the wrong space.**
Sixteen bugs in one session were all this. The countermeasure is CLAUDE.md's **one layout per
widget**: a widget's geometry comes from exactly one `*_layout()` procedure, consumed by the draw
*and* the hit-test *and* the hover *and* the cursor. **Test the seam, not the unit** — compare what
is *drawn* against what is *clickable*, at boundary sizes.

The syntax-highlighting fix applied this to a non-widget and it worked: `doc_row_lex_extent` makes
the extent decision once, and both the span builder and `doc_draw`'s state bootstrap ask it, rather
than each deriving it and diverging.

---

## 5. Landing the work

1. **HANDOFF entry** — a new `§6<letter>` section. Not a changelog: what was built, *why* it was
   built that way, what it got wrong, and what is owed. The "two things this batch got wrong"
   sections have been more useful to later sessions than any of the success descriptions.
2. **Version bump** — `src/program/version.odin`, in the same commit as the HANDOFF entry.
   SemVer-ish while pre-1.0: a feature batch is a minor bump. `release.ps1` greps this file, so the
   tag and the binary cannot disagree.
3. **Verify every commit builds.** If the branch changed a signature in one commit and its callers
   in another, it is not bisectable. Batch 4 shipped two such commits and they were squashed before
   merge. To check without mutating anything:

   ```bash
   for c in $(git rev-list --reverse main..HEAD); do d=$(mktemp -d); git archive "$c" | tar -x -C "$d"; ( cd "$d" && odin check src/program -collection:src=src >/dev/null 2>&1 ) && echo "ok   $c" || echo "FAIL $c"; done
   ```

   Archive the **whole tree**, not just `src/` — `links.odin` does `#load("../../text_exts.txt")`
   and a partial archive fails for that reason alone, which looks exactly like a real failure.
4. **Merge to `main`.**
5. **Run `install.ps1`** — a standing instruction after every merge. Check `Get-Process newtpad`
   first, and **never use `-Force` while it is running**: a hard kill skips the hot-exit session
   write and loses unsaved tabs.
6. **Push and cut the release, every time, without asking.** Wyatt, 2026-07-29: *"just always
   put out a push and release."* Run `release.ps1` **bare** — never piped through `2>&1`, see the
   trap in §6. This replaces the old rule ("push only when Wyatt asks, every time"), which cost a
   round trip that never changed the answer: he runs Newtpad as his daily driver on more than one
   machine, and a fix sitting unpushed is a fix he does not have.

   **`install.ps1` is still conditional.** Check `Get-Process newtpad` first; if it is running, say
   so and leave it to him. `-Force` skips the hot-exit session write and loses unsaved tabs.

---

## 6. Operational traps

Each of these cost real time at least once.

**Builds and the exe**

- `build.bat` = debug, console subsystem, so headless modes can print. `build.bat release` =
  `-o:speed -subsystem:windows`, the shipped exe. A bare `odin build` omits the DPI manifest and is
  wrong for anything visual.
- **The exe is at `build\newtpad.exe`**, not the repo root.
- `--version` exists but prints nothing in a release build — GUI subsystem, detached from the
  console.

**Tests**

- `odin test src\base -collection:src=src` for pure logic. Everything else is a headless mode in
  `src/program/test_modes.odin`.
- **Set `NEWTPAD_SESSION_DIR` to a temp directory first.** Six modes used to write to the real store
  under `%APPDATA%\Newtpad`; they now refuse without it, but set it anyway.
- Argument order is per-mode and unforgiving: `edittest`/`seltest` take the path **first**.
  **`keytest` no longer needs one** (2026-07-30) — `newtpad keytest`
  works, `newtpad <path> keytest` still works, and it belongs in every regression sweep from now on.
  **`watchtest`'s directory is optional as of 2026-07-31** (it defaults under `%TEMP%`), and
  `lineidxtest` is one-argument with an optional path; both belong in every sweep. **`tablegridtest`
  is one-argument and was missing from HANDOFF §7's list entirely until 2026-07-31** — it existed,
  it asserted a hundred things about a data-loss seam, and no required list named it. It is in §7
  now. **`resavetest` is one-argument as of 2026-07-31 too** — `newtpad resavetest` builds its own
  fixture under `%TEMP%`, asserts the bytes, the creation time and an alternate data stream, and
  exits non-zero; `newtpad resavetest <file>` still saves over a file you name and leaves it there.
  It belongs in every sweep. Bare, it used to fall through to the GUI and hang, so it was in no
  required list, nothing ran it, and a stale assertion that the D1 keymap fix had invalidated sat in
  the tree printing `FAIL` to nobody. **A mode nothing runs is worse than no mode.** When you add one,
  make it one-argument and put it in a list. **`selalltest` is the first one added under that rule
  (2026-07-31)** — `newtpad selalltest`, no path, covers Ctrl+A's trailing-blank-row trim end to end
  (the row rule, the second-press extend and what resets it, the 1 MiB scan cap, and the eight
  consumers of the selection), exits non-zero, and counts a missing `NEWTPAD_SESSION_DIR` as a
  failure rather than skipping the part that needs it. It belongs in every sweep.
  **`tablesorttest` is the second (2026-08-01)** — `newtpad tablesorttest`, no path, ~16 cases over
  multi-column sort: the key vector, precedence, per-key numeric detection, empty-last on a secondary
  key, both click cycles, the header seam, the menu's disabled states, the summary row's clickable span
  and the cost at the row ceiling. Same rules — one argument, exits non-zero, a missing
  `NEWTPAD_SESSION_DIR` is a failure. It belongs in every sweep.
- **Two more modes were printing `FAIL` and exiting 0 until 2026-08-01: `menutest` and
  `settingstest`.** Both are fixed. This is the same defect the bullet above was written about, found
  again in two more places, so treat "does this mode actually exit non-zero?" as a thing to *check*
  rather than assume — and note that **`menuseam` legitimately exits 0 whatever it finds**, because it
  is a falsifier rather than a pass/fail test. Its answer moved 14/14 → 12/12 under a sabotage with the
  exit code unchanged throughout, so sweep it by diffing its printed line, never by exit code.
- **`drawcount` is safe to run as of batch 8** — `newtpad drawcount <file>` renders offscreen (no
  window, no message pump), prints its numbers and exits, and a bare `newtpad drawcount` prints
  usage. **The old rule here was right to forbid it but wrong about why**, and the difference is the
  useful part: measured under a watchdog before the change, the windowed `drawcount <file>` **exited
  in 0.3 s** — it opened a visible window whose DPI and mouse position moved the reading, which is
  reason enough not to trust it, but it did not hang. What hung past 20 s was **bare `drawcount`
  with no path**, falling through to the real GUI. So the hazard was never this mode; it was the
  missing-argument fall-through, which is the trap the rest of this bullet describes. **That trap is
  still live everywhere else, so keep reading.** `keytest` used to take `<path> <mode>`, two
  arguments, and with only one it fell through to opening the real GUI window and hung; it takes either
  form now (see the bullet above). **`edittest` and `seltest` still do it when their two arguments are
  in the wrong order** — the path comes FIRST — and that cost a ten-minute timeout once. Any
  file-argument mode can do this; check the argument order in `test_modes.odin` before running one.
- **A test mode can grow a stack overflow.** The trigger is total per-procedure frame size, not a
  sibling count — it is not "three or more inline blocks." `test_mode_dispatch` is one enormous
  procedure with an already-large frame; a callee that holds two `App` structs live at once
  (inline, or via a local proc that itself calls another local proc without returning first) adds
  its own full frame on top of that, and `blocktest` has hit a real `STATUS_STACK_OVERFLOW` twice
  this way — the same two `App`s, called one at a time from separate local procs, did not overflow.
  Pull each new case into its own local proc, and keep each proc to one `App`/`Document` at a time;
  the existing `block_test_*` procs are that pattern. `build.bat` now also raises the thread stack
  to 8 MB via `-extra-linker-flags:"/STACK:8388608"`, so this is a higher ceiling, not just a
  comment convention — but it is still a ceiling, not an excuse to stop watching frame size.
- **`Select-String "FAIL"` is case-insensitive** and happily matches "0 failures" in a passing
  summary. Use `-CaseSensitive`.

**Shell**

- Bash heredocs mangle backslashes here. For file content, write with the `Write` tool or splice via
  a scratchpad file — don't build Windows paths inside a heredoc.
- PowerShell 5.1's `Get-Content -Raw` decodes UTF-8 as ANSI. It has already corrupted every em dash
  in HANDOFF.md once. Pass the encoding explicitly, or use the `Read` tool.
- **PowerShell 5.1 decodes a BOM-less `.ps1` as ANSI too** — so a non-ASCII character written into a
  script by the `Write`/`Edit` tools is already mojibake by the time the script runs, before any
  command sees it. An em dash in `release.ps1`'s notes string shipped as `â€"` into the published
  v0.13.0 release notes. Keep script string literals ASCII, or save the script with a BOM. **Reading
  the command's output back in the console does not catch this** — the console mangles it the same
  way, so it looks correct. Dump the bytes of what actually landed.
- PowerShell 5.1 has no `&&`, no `||`, no ternary, no `?.`. Use `; if ($?) { }`.
- **PowerShell 5.1 re-parses quotes when passing arguments to a native command**, so a `"` inside a
  here-string reaches `git commit -m` as an argument break — the tail of the message then arrives as
  a pathspec and the commit fails. Write the message to a file and use `git commit -F`.
- **Never pipe `.\release.ps1` (or any script that runs `git push`) through `2>&1`.** PowerShell 5.1
  wraps each stderr line from a native command in an ErrorRecord, and `git push` writes its progress
  there — so with the script's `$ErrorActionPreference = 'Stop'` the push "fails" and the script
  aborts *after* tagging and pushing the branch but *before* pushing the tag and creating the
  Release. Recovering means pushing the tag and running `gh release create` by hand, and
  `release.ps1` cannot simply be re-run because it refuses an existing tag. Run it bare.
- **The `Write`/`Edit` tools can silently rewrite a whole file from CRLF to LF.** It happened twice
  on one branch. `.gitattributes` normalises storage so nothing corrupts, but the working tree ends up
  inconsistent and the diff balloons. Check `git diff --stat` before committing and confirm the line
  count matches what you actually changed.
- Bash working directory persists between calls; shell variables do not.

**Git**

- **Commits, merges, tags and PR bodies are authored solely by Wyatt Guethlein.** Never
  `Co-Authored-By: Claude`, never "Generated with Claude Code", never a robot emoji, never any other
  AI attribution. `.claude/settings.json` sets `includeCoAuthoredBy: false` — do not override it.
  This applies to every subagent you dispatch; put it in their prompt.
- Interactive rebase works here only through `GIT_SEQUENCE_EDITOR` / `GIT_EDITOR`; the `-i` flag has
  no terminal to open.
- Commit in logical, incremental units. The history should read like a person building the project.

**Signing**

- **Never handle a code-signing certificate password.** Signing is blocked on Wyatt purchasing a
  certificate; build the pipeline signing-*ready* and stop there.

---

## 7. Where to look first in a new session

1. [HANDOFF.md](../HANDOFF.md) §6u — the batch plan and the decisions taken with Wyatt.
2. HANDOFF.md's last `§6<letter>` — what shipped most recently and what it owes.
3. HANDOFF.md §5 — the live debt register.
4. [CLAUDE.md](../CLAUDE.md) — locked decisions and hard engineering rules. Note the "as-built
   caveat" markers: several rows describe intent, not code, and say so.
5. This file.
