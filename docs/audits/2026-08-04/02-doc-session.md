# Audit 02 — document lifecycle, persistence, the file seam

Scope read in full: `src/program/doc.odin` (5147), `src/program/session.odin`, `src/program/watch.odin`,
`src/platform/file.odin`, `src/platform/path.odin`, `src/platform/seh.odin`, `src/platform/guarded_copy.c`.
Supporting reads: `src/base/piecetable.odin` (read/fault path), `src/base/encoding.odin` (BOM/transcode),
`src/program/main.odin` (watcher drain, fault recovery, status bar), `src/program/commands.odin` (save path),
`src/program/app.odin` (doc lifetime), Odin `core/os/stat_windows.odin`.

Cross-checked against `HANDOFF.md`, `docs/reported-bugs.md`, `docs/requested-features.md`, `bench/RESULTS.md`
before reporting. Items already recorded there (the `doc_absorb_append` offset bug §6j, the missing
`FlushFileBuffers`/`MoveFileExW` ADS bug §6k, the `doc_cursor_col` uncapped scan, the Replace All undo
eviction, the `doc_save_err` freed-path aliasing, `BACKUP_MAX`, the mmap-locks-the-file entry) are **not**
repeated. Where I found a recorded item is worse than recorded, I say so.

**Lifetime audit result up front (no finding, stated because the brief asked):** `doc_close`
(doc.odin:1971-2039) covers every heap-owning field of `Document` I could enumerate — `idx.ckpts`,
`lex_idx.{line_starts,states,opens}`, `search` (via `search_release`, which also frees `search.view`'s
cloned tree and `search.query`), undo/redo snapshots via `snapshot_free`, `bookmarks`,
`find.{query,replace}`, `filter_lines`, `filter_line_nos`, the five `table_*` dynamics,
`table_sort_free`, `table_filter_free`, `md_layout_reset`, `pt_destroy`, `original`, `path`, `fv`.
Ordering is right (both workers joined before the memory they alias is freed; `search_release` before
`pt_destroy`). `app_close`/`app_destroy` (app.odin:315, 359) free the box. I found no leak and no double
free in this pair. The one heap allocation that escapes is #11 below, and it is inside `doc_open`, not
`doc_close`.

---

### [CRITICAL] A save can write NUL bytes over the user's file when the mapped original faults
**Where:** src/program/doc.odin:2158-2159 (`doc_save_err`'s read loop); fault set at src/base/piecetable.odin:251-252
**Confidence:** CONFIRMED (code path traced end to end; the fault trigger itself is external and not reproduced here)
**Fix risk:** SAFE
**Mechanism:** `doc_save_err` streams the buffer with `base.pt_read(&doc.pt, pos, raw[...])`. When a piece
resolves into the memory-mapped `original` and the page cannot be read, `read_rec` calls `safe_copy`, which
**zero-fills the unreadable page, returns false, and sets `pt.fault`** — but still counts those bytes as
copied, so `pt_read` returns the full length. `doc_save_err` never calls `base.pt_faulted`. The zeros go
into the temp file and `atomic_write_commit` then atomically replaces the good file with them.
`doc_sort_lines` guards exactly this hazard and says why (doc.odin:3791-3805: *"Every other reader of a
faulted region only DISPLAYS it; this one would write it back as a real edit"*). The save is the one
reader where writing it back is permanent, and it has no guard.
**Failure scenario:** Open a 40 MB `.log` on C: (>`FILE_MMAP_THRESHOLD`, so mapped, UTF-8, `owned_orig`
false). A service rotates/truncates it while you have an unsaved edit. Press Ctrl+S before the next
watcher poll (up to 1 s away) or in the same frame as the truncation. Pages past the new EOF fault →
zero-filled → the atomic write commits → **your file is now your edit plus a multi-megabyte run of
`00` bytes**, and `doc.modified` is cleared so nothing says otherwise. Undo does not help: the undo tree
reads out of the same broken mapping.
**Fix:** In `doc_save_err`, after each `pt_read` (or once before the commit), check `base.pt_faulted(&doc.pt)`
— peeked, not taken, exactly as `doc_sort_lines` does — and on true call `plat.atomic_write_abort(&aw)` and
return a new `Write_Error` variant (`.Source_Faulted`) whose message says the file changed underneath and
the save was refused. The frame's `doc_fault_pending` recovery then detaches, and the retry saves the
recovered copy.

---

### [CRITICAL] Ctrl+S silently overwrites a file that changed on disk since it was loaded
**Where:** src/program/commands.odin:1469-1485 (`.Save`) → commands.odin:597 (`save_checked`) → src/program/doc.odin:2144
**Confidence:** CONFIRMED
**Fix risk:** RISKY (adds a modal prompt to the most-used command)
**Mechanism:** The watcher detects the external change and, because the buffer is dirty, sets
`d.disk_changed = true` and records the new stamp (main.odin:1458-1461) — deliberately refusing to discard
the user's edits. The *only* consequence is a status-bar string (main.odin:2638,
`[CHANGED ON DISK - you have unsaved edits. File > Reload to discard yours]`) in the low-contrast bottom
strip. Neither `.Save`, `save_checked`, nor `doc_save_err` reads `disk_changed`, `disk_gone` or
re-compares `doc.disk_stamp` against the file. The write proceeds and afterwards
`doc.disk_changed = false; doc.disk_stamp = plat.file_stamp(path)` (doc.odin:2191-2194) erases the evidence.
There is a second, worse window: a change made **between** the last watcher poll and the save is never
seen at all, because nothing stats the target before writing.
**Failure scenario:** You open `config.yaml`, type one line, and step away. A colleague (or a `git pull`,
or a deploy script, or your own second Newtpad window) rewrites the same file with 200 lines of changes.
You come back, glance at the tab, press Ctrl+S. `ReplaceFileW` replaces their 200 lines with your
one-line-older buffer. No dialog, no undo, no copy of what was there. The status bar warning that was
supposed to prevent this scrolls past unread and is cleared by the very save that destroyed the data.
**Fix:** In `save_checked`, before calling `doc_save_err`: if `doc.disk_changed` **or**
`plat.file_stamp(path) != doc.disk_stamp` (when `doc.disk_stamp.ok` and this is a re-save, not a Save As),
show a three-way confirm — *Overwrite / Reload and lose my edits / Cancel*. Reuse `plat.confirm_discard`'s
shape. The stat is one more UI-thread `file_stamp` immediately before a write to the same path, which is
exactly the accounting `file.odin:249-261` already accepts for the other five sites.

---

### [CRITICAL] Detaching a mapping copies the whole file on the UI thread, and an allocation failure leaves the document pointing at nothing
**Where:** src/program/doc.odin:3054-3058 (`doc_detach_mapping`), doc.odin:2106-2110 (`doc_recover_from_fault`); called unconditionally at src/program/main.odin:1450
**Confidence:** CONFIRMED (the unbounded copy); PLAUSIBLE (the crash — depends on `make` returning an empty slice rather than aborting, which is Odin's behaviour when the allocator error is discarded)
**Fix risk:** RISKY
**Mechanism:** `main.odin:1450` calls `doc_detach_mapping(d)` for **every** watcher report, before deciding
what the change was. For a mapped document that means `priv := make([]u8, len(doc.original))` followed by
`base.safe_copy(priv, doc.original)` — a full private copy of the entire file, synchronously, on the input
thread, with no size cap of any kind (contrast `BACKUP_MAX` 128 MB, `FORMAT_MAX` 256 MB, `SORT_MAX_BYTES`
16 MB, `MOVE_LINE_BUDGET` 2 MB — every other bulk operation in this codebase has one). Worse, `safe_copy`
is `guarded_copy` (seh.odin:24-37), which issues **one foreign SEH-guarded call per 4096 bytes**: a 4 GB
original is 1,048,576 foreign calls plus 4 GB of commit. If the `make` fails, the discarded allocator error
leaves `priv` an empty slice; `doc.original = priv` and `doc.pt.original = priv` then make
`piece_src` (piecetable.odin:232) evaluate `pt.original[p.start : p.start+p.len]` on a zero-length slice —
an out-of-range slice, i.e. a bounds panic, on a code path whose whole purpose is preserving data.
**Failure scenario:** Tail a 6 GB application log (opens instantly, ~0 private memory — the headline
property). The writing service touches the file. One second later the watcher fires; `doc_detach_mapping`
tries to commit 6 GB and copy it through a million guarded calls. On a 16 GB machine that is a
multi-second-to-minutes freeze with the disk thrashing; on a machine already under pressure the allocation
returns nothing and the next frame's draw crashes the process with every other tab's unsaved work in it.
**Fix:** Two parts. (a) Cap the detach: above some `DETACH_MAX` (a number measured, not argued — start
from the mmap threshold × N), do not copy; close the tab's mapping and mark the document
`recovered`/read-only-until-reload with a status-bar reason, or re-open lazily. (b) Check the allocation:
`priv, err := make([]u8, n); if err != nil || len(priv) != n { … }` and refuse rather than repoint
`pt.original` at a shorter slice. `doc_recover_from_fault` needs the identical treatment — same two lines,
same hazard.

---

### [HIGH] `doc_absorb_append` reads an unbounded tail into memory on the input thread
**Where:** src/program/doc.odin:3088
**Confidence:** CONFIRMED
**Fix risk:** SAFE
**Mechanism:** `chunk, ok := plat.file_read_range(doc.path, old, int(new_size - old))` — the size is
whatever the watcher's stat reported, with no ceiling. `file_read_range` does `make([]u8, count)` then a
blocking `ReadFile` loop (file.odin:305-313). Both happen on the frame thread inside the watcher drain
loop. The chunk is then `pt_edit_insert`ed, which copies it again into the add arena, and scanned once for
newlines (doc.odin:3101). So peak transient is 2× the growth.
**Failure scenario:** You have a 3 KB `build.log` open. The build starts and dumps 1.8 GB of verbose output
in the second between two watcher polls. The next frame allocates 1.8 GB, blocks on `ReadFile` for it, then
copies it into the add arena — the window is unresponsive for many seconds and may OOM. This is precisely
the log-tailing workflow the feature exists for.
**Fix:** Cap the absorb (e.g. `ABSORB_MAX :: 16 * 1024 * 1024`); above it fall through to the
`doc_reload` branch that already follows it at main.odin:1464, or absorb in bounded chunks across frames.
One constant plus one comparison at doc.odin:3086.

---

### [HIGH] A failed backup write silently downgrades a dirty tab to "reopen from disk", losing the edits on restore
**Where:** src/program/session.odin:378-384
**Confidence:** CONFIRMED
**Fix risk:** SAFE
**Mechanism:**
```
if (d.modified || …) && d.pt.length <= BACKUP_MAX {
    content := base.pt_collect(…)
    if plat.file_write_atomic(backup_path(backups, ti), content) {
        backup_idx = ti
        used[ti] = true
    }
}
```
When `file_write_atomic` returns false, `backup_idx` stays `-1`. The session line is written anyway,
`session_save` returns `true`, and on the next launch `session_restore` sees `bidx < 0`, takes the
`path != ""` branch (session.odin:667) and reopens **from disk** — the version without the user's edits.
Nothing anywhere reports the failure: `doc_backup_skipped` (session.odin:62) only covers the `BACKUP_MAX`
size case, not a write that failed.
**Failure scenario:** `%APPDATA%` is on a volume that fills, or an AV/backup agent holds
`backups\backup-0` open, or the roaming profile is on a briefly-unreachable share. Every 2 s autosave
silently records `-1`. You close the window (hot exit, no prompt because hot exit is the design). Next
launch, the tab comes back as it was on disk. Your edits are gone and were never warned about.
**Fix:** Make the write failure visible in the same channel the size cap already uses: set a
`d.backup_failed` flag when `file_write_atomic` returns false, fold it into `doc_backup_skipped`'s status
warning, and (separately) consider refusing hot exit for a tab whose backup could not be written.

---

### [HIGH] A BOM-less UTF-16 file gains a BOM on every save
**Where:** src/base/encoding.odin:327-332 (`encoding_bom`), called from src/program/doc.odin:2149
**Confidence:** CONFIRMED
**Fix risk:** SAFE
**Mechanism:** `doc_save_err` correctly threads `doc.had_bom` in: `base.encoding_bom(bom[:], doc.enc, doc.had_bom)`.
`encoding_bom` honours `add_bom` for `.UTF8` and **ignores it entirely for `.UTF16LE` / `.UTF16BE`**, writing
`FF FE` / `FE FF` unconditionally. Newtpad ships BOM-less UTF-16 *detection* (HANDOFF.md:966), so this case
is reachable by design, and `doc_open` sets `doc.had_bom = bom > 0` = false for it. The doc comment on
`doc_save_err` claims "UTF-16 files round-trip" (doc.odin:2130-2131); they do not, byte-for-byte.
**Failure scenario:** Open a BOM-less UTF-16LE file (a registry export variant, a UTF-16 log written by a
.NET tool with `UnicodeEncoding(false, false)`, a fixture in a test suite). Change nothing, or change one
character. Save. The file is now two bytes longer and starts with `FF FE`. A consumer that byte-compares,
hashes, or parses with a fixed header offset breaks; a `git diff` shows the whole file changed.
**Fix:** `case .UTF16LE: if add_bom { … return 2 }; return 0` and the same for `.UTF16BE`. Then fix
`doc_set_encoding` (doc.odin:2994) — which already sets `had_bom = true` when the user explicitly *chooses*
UTF-16 — so a deliberate conversion still emits one. Note the trade honestly in the comment: BOM-less UTF-16
is ambiguous on re-open, so preserving its absence is preserving the user's bytes, not making the file
better.

---

### [HIGH] An orphan window store is deleted with its backups when `session.txt` reads fine but no tab could be restored
**Where:** src/program/session.odin:255-275 (`session_adopt_orphans`)
**Confidence:** CONFIRMED
**Fix risk:** SAFE
**Mechanism:** The code is
```
if session_restore(a, d) { adopted += 1 }
if readable, _ := plat.file_read_all(…"session.txt"); readable != nil { plat.dir_remove_all(d) }
```
`dir_remove_all` (path.odin:235) deletes the `backups` subdirectory and everything in it. The comment
(session.odin:257-266) reasons the distinction is *"could we read it, NOT did it give us anything"*, and
justifies deleting a store that "reads fine and simply holds no tabs". But the condition does not
distinguish "holds no tabs" from "holds tabs, none of which could be built". `session_restore` returns
false when `restored == 0`, which happens whenever every `plat.file_read_all(backup_path(...))` failed —
and for an **untitled** dirty tab there is no `path != ""` fallback, so the tab is dropped and its backup
is then deleted.
**Failure scenario:** A torn-off window with two untitled scratch buffers crashes. On the next primary
launch, an AV scanner or an indexer holds `backup-0` and `backup-1` open for a moment.
`session_restore` reads `session.txt` fine, fails both backup reads, returns false. The very next line
reads `session.txt` again (succeeds) and `dir_remove_all`s the store — **permanently deleting the two
backups that would have restored on the following launch**. The mechanism destroys exactly what it exists
to preserve, in the case its own comment says it must not.
**Fix:** Only remove the store when the session file parsed **and** listed zero tabs, or when every listed
tab was accounted for. Have `session_restore` return the tab-line count alongside `restored` and gate
`dir_remove_all` on `lines_seen == 0 || restored == lines_seen`.

---

### [HIGH] `FlushFileBuffers` and `CloseHandle` return values are discarded in the atomic commit
**Where:** src/platform/file.odin:415-416
**Confidence:** CONFIRMED
**Fix risk:** SAFE
**Mechanism:**
```
win.FlushFileBuffers(aw.h)
win.CloseHandle(aw.h)
… file_replace / MoveFileExW
```
Neither result is checked. `WriteFile` can succeed against the cache and the actual failure (disk full,
quota exceeded, a network share dropping, a delayed-write failure) can surface only at flush or close.
HANDOFF §6k records adding the flush *for durability*; it does not record checking it. That makes this
worse than what is recorded: the flush was added precisely so a crash could not commit a rename over
un-flushed data, and an unchecked flush provides that guarantee only when it succeeds.
**Failure scenario:** Save a 200 MB document to a nearly-full disk or a mapped network drive. The chunked
`WriteFile` loop succeeds (cached). `FlushFileBuffers` fails with `ERROR_DISK_FULL` / `ERROR_NETNAME_DELETED`.
The return is ignored, `ReplaceFileW` commits, `doc_save_err` returns `.None`, `doc.modified` clears, the
status bar shows `[SAVED]` — and the file on disk is truncated or partially written, with the original
already replaced.
**Fix:** `if !win.FlushFileBuffers(aw.h) { win.CloseHandle(aw.h); win.DeleteFileW(wtmp); atomic_write_free(aw); return .Write }`,
and treat a failing `CloseHandle` the same way. Three lines, no behavioural change on the healthy path.

---

### [HIGH] `doc_set_line_ending` collects and rewrites the entire buffer with no size cap, from a one-click status-bar cell
**Where:** src/program/doc.odin:3000-3034; reachable from src/program/doc.odin:1044 (`status_cells` makes the `LF`/`CRLF` cell clickable) and src/program/commands.odin:2000-2003
**Confidence:** CONFIRMED
**Fix risk:** SAFE
**Mechanism:**
```
body      := base.pt_collect(&doc.pt, context.temp_allocator)   // whole buffer
converted := base.convert_line_endings(body, eol, context.temp_allocator) // whole buffer again
…
pt_edit_replace(doc, 0, doc.pt.length, converted)               // and a third copy into the add arena
```
Plus `push_undo` clones the whole piece tree, and `doc_index_start` restarts the index. There is no
ceiling analogous to `FORMAT_MAX`, `SORT_MAX_BYTES`, `BACKUP_MAX` or `MOVE_LINE_BUDGET`, and the two
temp-allocator allocations live until the frame's `free_all`. `commands.odin:1073-1083` correctly
identifies this as "nothing looks like an edit less and few things are a bigger one" — but only to route
it through the rectangle/table guards, not to bound it.
**Failure scenario:** Open a 2 GB CRLF log (mapped, instant). Click the `CRLF` cell in the status bar
— one click, no confirmation, no menu depth. Newtpad allocates ~2 GB + ~2 GB on the frame arena, copies
~2 GB into the add arena, and clones a piece tree; on most machines this is an OOM or a minutes-long
freeze with the whole session in it.
**Fix:** Refuse above a measured cap with an `app_note`, exactly as `format_too_large` /
`doc_sort_lines`' `.Too_Big` already do — the house style is already written for this. Add the guard in
`command_dispatch` beside the other refusals so the menu row can also be greyed.

---

### [MEDIUM] Session backups are keyed by display position, so a crash mid-save can point a tab's line at another tab's bytes
**Where:** src/program/session.odin:380 (`backup_path(backups, ti)`) with `ti` the running display index
**Confidence:** CONFIRMED (as a code property; the window is narrow — see below)
**Fix risk:** RISKY
**Mechanism:** The file header (session.odin:4-7) argues *"referenced backups always exist before
session.txt points at them, so a crash mid-save never leaves a dangling reference"*. That is true for
**dangling** references, and it does not cover the other direction: `ti` is the tab's position in the
current save, not a stable identity, so the same `backup-N` file names different content from one save to
the next. Between the loop that overwrites the backups and the atomic commit of `session.txt`, the *old*
`session.txt` is still on disk pointing at indices that now hold *other tabs'* bytes.
**Failure scenario:** Tabs `[A dirty, B dirty]`; last saved session says line0→`backup-0` (A), line1→`backup-1` (B).
You close A. The autosave writes `backup-0` = **B's content**, then dies (hard kill, power loss, or a fault
inside `session_save` itself, which `diag_on_fatal` cannot re-enter) before `session.txt` commits. Next
launch reads the old `session.txt`: line0 says path=A, backup=0. Tab "A" restores **with B's text in it**,
marked modified. One Ctrl+S and A's file on disk becomes B's content. Silent, and indistinguishable from a
real edit.
*Honest bound:* `diag_on_fatal` (diag.odin:105-111) does a full `session_save` from the crash handler, and
the session file is written `WRITE_THROUGH`, so the window is milliseconds and only reachable via hard
kill / power loss / a fault inside the save itself.
**Fix:** Name the backup by a per-document identity, not by position — `d.gen` (already unique per
document, app.odin:175) or a monotonic counter persisted in the line. The sweep then deletes any
`backup-*` not named in the new session file, exactly as it does today.

---

### [MEDIUM] `os.stat`'s `File_Info` is leaked on every document open
**Where:** src/platform/file.odin:172
**Confidence:** CONFIRMED
**Fix risk:** SAFE
**Mechanism:** `info, serr := os.stat(long, context.allocator)`. Odin's `internal_stat`
(`core/os/stat_windows.odin:75` → `_file_info_from_win32_file_attribute_data`:263) sets
`fi.fullpath, e = full_path_from_name(name, allocator)` — a heap allocation in the caller's allocator, and
`fi.name` slices it. `core:os` provides `file_info_delete` for exactly this. `file_open_readonly` never
calls it, and only reads `info.size`.
**Failure scenario:** Not a crash — a slow bleed keyed to the reload path. `doc_reload_forced` calls
`doc_open` on every non-append external change (main.odin:1464). Tail a file that a writer *rewrites*
rather than appends to (a status file, a `--watch` build artifact, an atomically-replaced log) and Newtpad
opens it once per second for the life of the session, leaking one full path string each time. Also once per
tab per launch and once per Reopen-As.
**Fix:** `defer os.file_info_delete(info, context.allocator)` after the `serr` check. Better: replace the
call with `file_stamp(path)` — this function already exists in the same file, needs no allocator, and
`info.size` is the only field read.

---

### [MEDIUM] The watcher re-clones every watched path from the main thread on every frame
**Where:** src/program/watch.odin:96-131, called unconditionally from src/program/main.odin:1430
**Confidence:** CONFIRMED
**Fix risk:** SAFE
**Mechanism:** `watcher_publish` takes the worker's mutex, `delete`s every entry's path, `clear`s the list,
then `strings.clone`s each of up to `WATCH_MAX` (64) paths again — every frame. The worker then clones them
all a *second* time each poll cycle (watch.odin:157). Nothing in the loop checks whether anything changed;
the list is rebuilt from scratch whether or not a tab opened, closed, or was renamed.
**Failure scenario:** Not correctness — cost. With a full 64-tab session, that is 128 heap operations per
frame under a lock shared with a thread that can be blocked in `GetFileAttributesExW` on a dropped share
for tens of seconds. `file_stamp`'s own comment establishes the worker can hold that lock; while it does,
`watcher_publish` blocks the **main thread** at exactly the point in the frame it was written to avoid. (The
worker does release the mutex around the stats — watch.odin:154-158 — so the exposure is the short
copy window, not the stat itself. It is still a per-frame lock acquisition for work that changes at
human timescales.)
**Fix:** Publish only when the watch set actually changed — bump an `App` counter in `app_add`/`app_close`/
`doc_save_err` (path realloc) and compare it, or move the publish behind the same "once input has settled"
gate the session autosave uses (main.odin:1616).

---

### [LOW] `doc_reload_forced` zeroes `doc.gen`, discarding the watcher's document identity
**Where:** src/program/doc.odin:3144 (`doc^ = fresh`); `gen` is assigned once at src/program/app.odin:174-175
**Confidence:** CONFIRMED
**Fix risk:** SAFE
**Mechanism:** `doc_reload_forced` carefully carries `path`, `revision`, `cursor`, `anchor`, `top` and the
view across `doc^ = fresh`, and restarts both index workers — but not `gen`. Zero-is-initialization makes
the reloaded document `gen == 0`, a value `a.next_gen` (which pre-increments from 0) never legitimately
assigns. The field's own comment (doc.odin:1718-1721) says it "distinguishes this document from a later one
reusing the same tab slot".
**Failure scenario:** Today this fails *safe*: in-flight watcher results carry the old non-zero gen and are
discarded, which is the right answer for a document that has just been re-read. But the stated invariant
("gen identifies this document") is no longer true, and two reloaded documents in different slots now share
gen 0 — so any future consumer that keys on gen alone rather than (slot, gen) is silently wrong. Recorded
as a latent invariant break, not a live bug.
**Fix:** `gen := doc.gen` alongside `rev := doc.revision` at doc.odin:3141, and `doc.gen = gen` after the
assignment. One line, and it makes the comment true again.

---

### [LOW] A read-only or permission-denied save reports "Another program may have the file open"
**Where:** src/platform/file.odin:600-619 (`Write_Error` / `write_error_text`), reached via file.odin:425-428
**Confidence:** CONFIRMED
**Fix risk:** SAFE
**Mechanism:** `Write_Error` has three failure variants and no permission case. A target with the read-only
attribute set, or one the user lacks write access to, fails both `ReplaceFileW` and `MoveFileExW` with
`ERROR_ACCESS_DENIED`, which maps to `.Replace`, whose text is *"Another program may have the file open."*
`plat.last_error()` exists (path.odin:311) and is not consulted here.
**Failure scenario:** You edit a file checked out read-only from a VCS, or one under `Program Files`. Ctrl+S
fails with a dialog blaming a nonexistent other process. You close every other program, retry, fail again,
and conclude the editor is broken — while the actual fix (clear the read-only bit / elevate / save
elsewhere) is never suggested. The save *did* correctly refuse, so this is a diagnosis bug, not data loss.
**Fix:** Capture `last_error()` in `atomic_write_commit` and add `.Denied` for `ERROR_ACCESS_DENIED` /
`ERROR_WRITE_PROTECT`, with text naming permissions and the read-only attribute.

---

### [LOW] `file.odin`'s header and its mmap CAUTION comment contradict each other, and the CAUTION is the one that was refuted
**Where:** src/platform/file.odin:3-4 vs src/platform/file.odin:199-204; the measurement is bench/RESULTS.md:105-110
**Confidence:** CONFIRMED
**Fix risk:** SAFE
**Mechanism:** The file header says *"Always share-everything so we never lock the user's file (delete +
rename verified to work while mapped; see bench/)"*. Ninety lines later the CAUTION block says *"While a
user-mapped section is open, Windows fails truncation, deletion and replacement of that file with
ERROR_USER_MAPPED_FILE (1224) regardless of the sharing mode requested here."* `bench/RESULTS.md:105-110`
settles it: *"[REFUTED by direct test] … `DeleteFileW` while mapped succeeds … Rename also succeeds.
Never-lock is honored for delete AND rename"* on Win11 26200 (POSIX-unlink semantics, Win10 1709+), with a
stated caveat that FAT32/USB/SMB were not verified. HANDOFF.md:1011 still carries the old claim too.
**Failure scenario:** Not a runtime failure — a decision hazard. The CAUTION is the stated justification for
`doc_detach_mapping` running unconditionally on every watcher report (main.odin:1450), which is finding #3's
unbounded copy. Someone reasoning from it will keep an expensive workaround for a problem that measurement
says does not exist on the target OS; someone reasoning from the header will remove a workaround that *is*
still needed on FAT32/SMB. Two comments in one file, one of them refuted, both load-bearing.
**Fix:** Replace the CAUTION block with the measured result and its caveat (cite `bench/lock_test`), keep
the detach for the *other* reason it is actually needed and which is independently true — the
moving-target problem an in-place external write creates (doc.odin:3046-3048). Update HANDOFF.md:1011 the
same way.

---

## MARKETABLE

Each claim below was verified in the code, with the limit stated.

**1. It never holds your file open.**
Every read opens with `FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE`
(file.odin:209, file.odin:286), and the mmap path closes the file handle the moment the view exists
(file.odin:224 — `CloseHandle(hfile)` before the view is even checked). Change detection is timestamp
polling on a worker thread with no handle retained (`file_stamp`, file.odin:262-273; watch.odin). Other
programs can rotate, rename or delete a file you are reading — measured, not assumed
(bench/RESULTS.md:105-110).
*Real limit:* while a file over 16 MB is memory-mapped, a section object is open on it. On this Windows
that still permits delete and rename, but it is not literally "no handle"; on FAT32/USB/SMB the bench
explicitly did not verify it. And getting off the mapping when a change is detected costs a full private
copy of the file (finding #3).

**2. Multi-GB files open instantly and stay responsive.**
Files above `FILE_MMAP_THRESHOLD` (16 MB, file.odin:29) are memory-mapped rather than read
(file.odin:196-232), so open time is independent of size and private memory is ~0. Every scan on the frame
path is capped by construction: `RENDER_LINE_CAP` 8 KB per visible line (doc.odin:20), `WRAP_START_CAP`
(doc.odin:620), `pt_line_start_cap` everywhere a backward scan could run away (doc.odin:4397, 4421),
`STATUS_LINE_CAP` 4 MB and `STATUS_COL_CAP` 1 MB with caching (doc.odin:3959, 3978), and a background
checkpointed line index with a bounded lookup (`doc_line_no_at`, doc.odin:2288, `CKPT_SCAN_CAP`).
*Real limit:* mmap only on a **local fixed drive** (`drive_is_fixed_live`, file.odin:90-95) — the same file
on a network share or a USB stick is fully copied into RAM at open. And three operations are still
uncapped: changing line endings (finding #9), `doc_goto_line` (doc.odin:4027, an O(file) walk from byte 0,
documented as such), and absorbing an appended tail (finding #4).

**3. Your bytes come back the way they went in.**
A UTF-8 save writes the buffer's bytes straight through with no transcode (doc.odin:2166). Line endings
are carried **positionally** rather than re-emitted from a global setting — `sort_split_lines` records each
terminator's length by position and rebuilds it (doc.odin:3711-3727, 3866-3871), and `doc_move_lines`
relocates terminator bytes without ever synthesising one (doc.odin:3473-3484), so a region whose endings
disagree with the rest of the file survives a sort. Enter writes the document's own terminator, CRLF
included (`doc_insert_newline`, doc.odin:3364). A CRLF pair is one caret step and one delete
(doc.odin:3389, 3409), so editing can't leave a stray CR. Pasting from the Windows clipboard is normalised
to the document's ending rather than silently mixing (commands.odin:1466). Saving as Windows-1252 counts
what would be lost first and offers UTF-8 instead of substituting `?` (commands.odin:598-612).
*Real limit:* a BOM-less UTF-16 file gains a BOM on save (finding #6). `detect_line_ending` sniffs only the
head of the file (noted at doc.odin:3706-3710), so `doc.eol` can be wrong for a file that changes
convention halfway. A UTF-16 file with an odd trailing byte loses it on load (encoding.odin:254, the loop
condition is `i + 1 < len(body)`).

**4. Saving is atomic and keeps the file's identity.**
Every save writes a sibling `.newtpad~` temp in bounded 1 MB chunks and commits with `ReplaceFileW`
(`REPLACEFILE_WRITE_THROUGH`, file.odin:408-412), which preserves the original's ACLs, attributes,
creation time and alternate data streams — including `Zone.Identifier`, so mark-of-the-web on a downloaded
file is not stripped. A crash mid-write leaves the original untouched and a stale temp that the next launch
sweeps (session.odin:327-337). A save that fails says why, in a dialog, because release builds are
`-subsystem:windows` and stderr would be discarded (commands.odin:577-585, file.odin:590-597).
*Real limit:* when `ReplaceFileW` fails, the commit falls back to `MoveFileExW` (file.odin:425) — which
substitutes a *new* file and loses exactly the ACLs and alternate data streams the primary path was chosen
to keep, silently (the fallback is acknowledged in file.odin's own comment at 405-407). The flush before
the commit is unchecked (finding #8), and a save does not check whether the file changed underneath
(finding #2).

**5. Close the window and everything is exactly where you left it.**
Hot exit: `session_save` (session.odin:356) writes each tab's path, caret, anchor, scroll, wrap, encoding,
BOM, line ending, markdown/table view, bookmarks and the file's mtime+size, plus a full crash-safe backup
of every dirty or untitled buffer — and the backups are written *before* the file that names them, so a
crash cannot leave a dangling reference. The format has a tolerant version ladder, so a session written by
any older build still restores (session.odin:563-649). Torn-off windows get their own store with a
process-lifetime lock file, and a window that dies has its unsaved tabs adopted by the next primary
(session.odin:246-278) — liveness decided by the lock, not by a reusable pid. A crash handler saves the
session before the process dies (diag.odin:104-111).
*Real limit:* dirty buffers over 128 MB are **not** backed up (`BACKUP_MAX`, session.odin:58); the status
bar says so while they stay dirty. A backup write that fails is silent (finding #5), backup files are keyed
by display position rather than identity (finding #10), and an orphan store can be deleted with its
backups in one specific failure mode (finding #7).

**6. Deep paths just work — no registry switch, no manifest opt-in.**
`long_path_form` (path.odin:120-179) canonicalises `.`/`..` *before* applying the `\\?\` prefix, handles
UNC as `\\?\UNC\…`, and leaves short and relative paths byte-identical, so ordinary paths stay ordinary.
Every file-I/O call in the platform layer goes through `wide_path` (path.odin:185), including the directory
primitives `core:os` would have gated behind `HKLM LongPathsEnabled`. The 248 threshold is measured against
the *directory* cap, not the file cap, and pinned by a `#assert` (path.odin:63-70).
*Real limit:* a relative path cannot be prefixed and is returned unchanged (stated at path.odin:116-119),
so a relative argument that resolves past MAX_PATH still fails. The shell call sites — Explorer reveal,
Open/Save dialogs, URL launch — deliberately do **not** prefix, because `explorer.exe` and `comdlg32`
reject `\\?\`, so a long path cannot be revealed in Explorer or navigated to in the file dialogs
(file.odin:454-462, 791-793).
