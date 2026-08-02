// Layer: program — session restore. On a bare launch we reopen the tabs from the
// last run (paths + caret/scroll/wrap), and for unsaved/untitled buffers we
// restore their content from crash-safe backups. Everything lives under
// %APPDATA%\Newtpad\. Save is atomic (temp + rename via file_write_atomic) and
// referenced backups always exist before session.txt points at them, so a crash
// mid-save never leaves a dangling reference (it may leave a harmless stale
// backup, cleaned on the next save / by the *.tmp sweep).
//
// The metadata format is one simple line per tab (hand-rolled, no dependency):
//   newtpad-session 1
//   active <index>
//   <cursor> <anchor> <top> <wrap> <enc> <backupIndex|-1> <path...>
// The path is the rest of the line (may contain spaces); -1 backup = clean tab.
//
// Every later format APPENDS fields ahead of the path and bumps the version;
// the reader keeps a tolerant ladder so a session written by any older build
// still restores (see session_restore's per-version field counts). Format 5's
// field is the bookmark list.
//
// The markdown preview's PIXEL scroll offset (doc.md_top, UI spec 9.1 item 4)
// is deliberately NOT a field here, and the format is NOT bumped for it.
// `top` is the editor's line and the preview is DERIVED from it on the first
// frame after restore, by the same block map 9.4's Split sync uses -- so a
// restored preview lands at the top of the block the saved line is in, which is
// where the saved line is. Persisting the pixels instead would mean restoring a
// sub-block offset into a layout whose block heights depend on the window size,
// the type scale and the theme, none of which the session records: the same
// number would mean a different place. This way there is no migration and no
// saved position to lose.
package main

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"
import base "src:base"
import plat "src:platform"

MAX_SESSION_TABS :: 64

// Bookmarks persisted per tab (format 5). A cap, not because anyone will hit it
// -- every bookmark is one deliberate Ctrl+F2 -- but because this field is the
// first unbounded-length thing in a session line, and session.txt is rewritten
// on a ~2 s autosave timer. A run of the whole file bookmarked by some future
// "bookmark all matches" command would otherwise put a megabyte on that timer.
// Beyond the cap the extras are simply not written; the tab still restores.
SESSION_BOOKMARKS_MAX :: 256

// Largest buffer we snapshot into a crash-safe backup. A backup is a full
// in-memory copy (pt_collect) plus a full write, on the main thread; for a
// multi-GB buffer that is several GB of transient allocation and a multi-GB
// write on the ~2 s autosave timer — a multi-second freeze and a real OOM-crash
// risk (the most likely cause of the reported "2 GB opened, then died quickly").
// Above this a dirty buffer is not backed up: the tab is still recorded (a saved
// file reopens from disk, the live buffer is untouched), and the status bar warns
// while it stays dirty. Streaming/off-thread serialize is the proper fix (owed).
BACKUP_MAX :: 128 * 1024 * 1024

// Whether a dirty buffer is too large to auto-back-up, so its unsaved edits are
// not crash-protected until saved. Surfaced in the status bar.
doc_backup_skipped :: proc(d: ^Document) -> bool {
	return d != nil && d.modified && d.pt.length > BACKUP_MAX
}

// --- handing one tab to another window -------------------------------------
//
// The tab tear-off (ui_tabs.odin) moves a document to a NEW PROCESS, and a
// process boundary means the buffer has to be written down. A path alone is not
// enough: the tab may be dirty, or untitled and have no path at all, and losing
// the edits in the move would make the gesture a data-loss bug rather than a
// convenience.
//
// One FILE rather than a longer command line, and that is a decision. Everything
// needed to rebuild the document -- encoding, BOM, line ending, caret, scroll,
// path, bytes -- travels together, so argv stays five numbers and a filename and
// cannot silently lose a field to quoting. It is also the same shape session.txt
// already uses (a version line, a metadata line, then the payload), which means
// one reader idiom in this file rather than two.
//
//   newtpad-handover 1
//   <enc> <bom> <eol> <cursor> <top> <modified> <path...>
//   <raw buffer bytes, EMPTY for a clean tab that has a path>
//
// The path is last on its line for the reason it is last in a session line: it
// may contain spaces, so it has to be "the rest".
//
// A CLEAN TAB CARRIES NO BYTES. It has a file on disk that says the same thing,
// and the receiving window reopens from it -- which also gets the mmap path back
// for a large file. Copying them would mean a multi-GB collect-and-write to move a
// tab whose contents are already sitting on the disk, and BACKUP_MAX only guards
// the DIRTY case (a clean buffer is never backed up because it never needs to be).
// So the size ceiling and the byte payload answer the same question from two
// directions, and neither is redundant.
HANDOVER_VERSION :: "newtpad-handover 1"

Handover :: struct {
	path:     string,
	content:  []u8, // empty when `modified` is false and `path` is set
	enc:      base.Encoding,
	had_bom:  bool,
	eol:      base.Line_Ending,
	cursor:   int,
	top:      int,
	modified: bool,
}

// A fresh path for one handover, under the session directory.
//
// Named by a counter rather than by a timestamp or a random number: two tabs torn
// off in the same millisecond must not collide, and this process is the only
// writer of its own store. It lives in the SESSION directory rather than %TEMP%
// so that a handover left behind by a spawn that never completed is swept by the
// same machinery that sweeps everything else here (session_sweep_tmp), instead of
// sitting in a system folder that nothing owns.
@(private = "file")
handover_seq: int

handover_path :: proc() -> string {
	dir, ok := session_dir()
	if !ok {return ""}
	handover_seq += 1
	return fmt.tprintf("%s%chandover-%d-%d", dir, filepath.SEPARATOR, plat.process_id(), handover_seq)
}

// Write `d` to `path` so another process can rebuild it. False if the buffer
// could not be collected or the write failed -- and the caller must then leave
// the tab exactly where it is.
handover_write :: proc(d: ^Document, path: string) -> bool {
	if d == nil {return false}
	// The same ceiling session_save applies to a backup, for the same measured
	// reason: this is a full in-memory copy plus a full write on the main thread,
	// and at multi-GB that is a multi-second freeze and a real OOM risk. A tab
	// that cannot be backed up cannot be handed over either, and tab_can_detach
	// refuses it before this is ever called.
	carries := d.modified || d.path == ""
	if carries && d.pt.length > BACKUP_MAX {return false}
	content: []u8
	if carries {content = base.pt_collect(&d.pt, context.temp_allocator)}
	head := fmt.tprintf(
		"%s\n%d %d %d %d %d %d %s\n",
		HANDOVER_VERSION,
		int(d.enc),
		1 if d.had_bom else 0,
		int(d.eol),
		d.cursor,
		d.top,
		1 if d.modified else 0,
		d.path,
	)
	body := make([]u8, len(head) + len(content), context.temp_allocator)
	copy(body, transmute([]u8)head)
	copy(body[len(head):], content)
	return plat.file_write_atomic(path, body)
}

// Read a handover file back. The file is DELETED whether or not it parsed: it is
// a one-shot transfer, and a malformed one left on disk would be picked up by
// nothing and cleaned by nothing.
handover_read :: proc(path: string, allocator := context.allocator) -> (h: Handover, ok: bool) {
	raw, rok := plat.file_read_all(path, context.temp_allocator)
	plat.file_delete(path)
	if !rok {return {}, false}
	// Two newlines, then the rest is bytes. Found by scanning rather than by
	// splitting the whole thing into lines: the payload is arbitrary data and may
	// contain any number of newlines, so it must never be treated as lines.
	nl1 := strings.index_byte(string(raw), '\n')
	if nl1 < 0 {return {}, false}
	if string(raw[:nl1]) != HANDOVER_VERSION {return {}, false}
	rest := raw[nl1 + 1:]
	nl2 := strings.index_byte(string(rest), '\n')
	if nl2 < 0 {return {}, false}
	meta := strings.split_n(string(rest[:nl2]), " ", 7, context.temp_allocator)
	if len(meta) < 6 {return {}, false}
	h.enc = base.Encoding(pint(meta[0]))
	h.had_bom = meta[1] == "1"
	h.eol = base.Line_Ending(pint(meta[2]))
	h.cursor = pint(meta[3])
	h.top = pint(meta[4])
	h.modified = meta[5] == "1"
	h.path = strings.clone(meta[6], allocator) if len(meta) == 7 else ""
	// Cloned out of the temp buffer: doc_from_content takes ownership of what it
	// is given and the document outlives this frame.
	payload := rest[nl2 + 1:]
	h.content = make([]u8, len(payload), allocator)
	copy(h.content, payload)
	return h, true
}

@(private = "file")
pjoin :: proc(elems: []string) -> string {
	s, _ := filepath.join(elems, context.temp_allocator)
	return s
}

@(private = "file")
pint :: proc(s: string) -> int {
	n, _ := strconv.parse_int(s)
	return n
}

// %APPDATA%\Newtpad, created if missing. temp-allocated.
//
// NEWTPAD_SESSION_DIR redirects the session store. Headless tests set it so they
// exercise save/restore against a temp dir instead of stomping the real session
// — these tests write backups and reset the session, which is destructive to a
// daily driver's unsaved tabs.
// Also used by settings.odin, which stores settings.txt alongside session.txt.
// A TORN-OFF WINDOW GETS ITS OWN STORE, under `windows\<pid>` of whichever
// directory would otherwise have been used. Set once, at startup, by a process
// launched with --detach.
//
// The alternative was the restriction this replaced: refuse to tear off anything
// unsaved, because a second process is not the primary instance and therefore had
// nowhere to put a backup. Wyatt asked for every tab to be draggable, so the
// second process needs a store rather than the gesture needing a rule. Its tabs
// are then backed up exactly like anyone else's; what makes them recoverable is
// session_adopt_orphans, which the next primary runs over any store whose window
// died without cleaning up.
@(private = "file")
session_dir_override: string

session_use_window_store :: proc() {
	base_dir, ok := session_root()
	if !ok {return}
	dir := pjoin({base_dir, "windows", fmt.tprintf("%d", plat.process_id())})
	plat.dir_create(pjoin({base_dir, "windows"}))
	plat.dir_create(dir)
	session_dir_override = strings.clone(dir)
	// Held open for the life of the process. It is what tells a later launch
	// whether this window is still alive: the pid in the directory name cannot,
	// because pids are reused, and a store adopted from a LIVE window would move
	// its tabs out from under it.
	plat.lock_hold(pjoin({dir, "lock"}))
}

// The directory a torn-off window uses is removed on a clean exit, so anything
// left under `windows\` is the store of a window that crashed. Called by the
// PRIMARY at startup, after its own restore, and it appends.
//
// Liveness is decided by the lock file rather than by the pid: pids are reused,
// and adopting a live window's store would take its tabs away while it is using
// them. lock_try takes the lock only if nobody holds it, which on Windows is
// exactly "the owning process is gone" -- the handle dies with the process even
// on a hard kill, which is the case this exists for.
session_adopt_orphans :: proc(a: ^App) -> int {
	root, ok := session_root()
	if !ok {return 0}
	wdir := pjoin({root, "windows"})
	names, nok := plat.dir_entries(wdir, context.temp_allocator)
	if !nok {return 0}
	adopted := 0
	for name in names {
		d := pjoin({wdir, name})
		if !plat.lock_try(pjoin({d, "lock"})) {continue} // still open in a live window
		if session_restore(a, d) {
			adopted += 1
			plat.dir_remove_all(d) // adopted once, not every launch
			continue
		}
		// THE RESTORE FAILED, AND THAT IS NOT A LICENCE TO DELETE. A store whose
		// session.txt could not be read may still hold backups -- the unsaved work
		// of the window that died -- and removing it would destroy exactly what
		// this whole mechanism exists to preserve, on a transient read error.
		//
		// A store with no session.txt at all is different: session_save writes the
		// backups BEFORE the file that references them (this file's own header), so
		// a crash between the two leaves backups nothing can name. Those are not
		// recoverable by anyone and are swept, or they accumulate forever.
		if ex, _ := plat.path_exists(pjoin({d, "session.txt"})); !ex {
			plat.dir_remove_all(d)
		}
	}
	return adopted
}

// Release this window's store at exit -- the LOCK only. The directory stays.
//
// It is tempting to delete it on a clean exit so that "a store exists" means "a
// window crashed", and that would be wrong, because closing a window here is a
// HOT EXIT and not a prompt: session_save has just written the unsaved buffers
// into it precisely so they are not lost. Deleting them would make closing a
// torn-off window the one way to destroy work in this editor.
//
// So a store outlives its window either way, and the lock -- not the presence of
// the directory -- is what says whether anyone is still using it. The next
// primary adopts it and deletes it then.
session_release_window_store :: proc() {
	if session_dir_override == "" {return}
	plat.lock_release()
}

// The store this process actually uses -- the per-window one when it has been
// claimed, the shared one otherwise.
session_dir :: proc() -> (dir: string, ok: bool) {
	if session_dir_override != "" {return session_dir_override, true}
	return session_root()
}

// The shared store, ignoring any per-window override. Split out because
// session_use_window_store and session_adopt_orphans both need the ROOT while
// session_dir may already be answering with a window's own subdirectory.
session_root :: proc() -> (dir: string, ok: bool) {
	if over := os.get_env("NEWTPAD_SESSION_DIR", context.temp_allocator); over != "" {
		plat.dir_create(over)
		return over, true
	}
	appdata := os.get_env("APPDATA", context.temp_allocator)
	if appdata == "" {
		return "", false
	}
	dir = pjoin({appdata, "Newtpad"})
	plat.dir_create(dir) // ignore "already exists"
	return dir, true
}

@(private = "file")
backup_path :: proc(backups: string, i: int) -> string {
	return fmt.tprintf("%s%cbackup-%d", backups, filepath.SEPARATOR, i)
}

// Remove orphan atomic-write temp files (file_write_atomic uses "<path>.newtpad~")
// left by a crash mid-write. Bounded scan; runs once at startup.
session_sweep_tmp :: proc() {
	dir, ok := session_dir()
	if !ok {
		return
	}
	backups := pjoin({dir, "backups"})
	plat.file_delete(fmt.tprintf("%s%csession.txt.newtpad~", dir, filepath.SEPARATOR))
	for i in 0 ..< MAX_SESSION_TABS {
		plat.file_delete(fmt.tprintf("%s.newtpad~", backup_path(backups, i)))
	}
}

// Persist the open tabs + view state, backing up unsaved/untitled buffers. Skips
// the empty scratch buffer. Safe to call on exit or periodically.
// True if a previous session file exists. Used to tell "first ever run" apart
// from "a session is there but we failed to load it" — in the second case the
// backups on disk belong to tabs we never adopted, and sweeping them would
// destroy unsaved work.
session_exists :: proc() -> bool {
	dir, ok := session_dir()
	if !ok {
		return false
	}
	ex, _ := plat.path_exists(pjoin({dir, "session.txt"}));return ex
}

// `sweep_backups` deletes backup files the new session doesn't reference. Only
// safe when this process actually owns the previous session's tabs; pass false
// when a session existed but could not be restored.
session_save :: proc(a: ^App, sweep_backups := true) -> bool {
	dir, ok := session_dir()
	if !ok {
		return false
	}
	backups := pjoin({dir, "backups"})
	plat.dir_create(backups)

	tb := strings.builder_make(context.temp_allocator)
	active_idx := 0
	ti := 0
	used: [MAX_SESSION_TABS]bool
	for d, slot in a.docs {
		if d == nil || ti >= MAX_SESSION_TABS {continue}
		// skip the empty untitled scratch — nothing to restore
		if d.path == "" && !d.modified && d.pt.length == 0 {continue}

		backup_idx := -1
		// Cap the backup (see BACKUP_MAX): snapshotting a multi-GB buffer here
		// froze the autosave and risked an OOM crash. Skipping it never crashes and
		// never touches the live buffer; it only forgoes crash-protection for that
		// one huge dirty buffer, which the status bar flags.
		if (d.modified || (d.path == "" && d.pt.length > 0)) && d.pt.length <= BACKUP_MAX {
			content := base.pt_collect(&d.pt, context.temp_allocator) // internal UTF-8
			if plat.file_write_atomic(backup_path(backups, ti), content) {
				backup_idx = ti
				used[ti] = true
			}
		}
		if slot == a.active {active_idx = ti}
		// mtime/size go in the line (format 2) so a restored dirty buffer knows what
		// the file looked like when we left it. Without them a restored buffer had a
		// zero stamp, the watcher compared it against the real file and reported a
		// change within a second of every launch -- on the hot-exit feature itself,
		// telling the user to reload away the work it had just restored.
		// had_bom and eol ride along too (format 3). doc_from_content sets neither,
		// so a restored dirty buffer forgot both: a UTF-8-BOM config file came back
		// BOM-less and a CRLF file came back LF, and the next save wrote it that way
		// -- which breaks Excel and PowerShell on the first, and produces a
		// whole-file diff on the second.
		// md_mode and table ride along too (format 4). Without them a restored
		// tab always came back .Off/false: leave a .md in Split, restart, and it
		// is plain text again -- and with a family default set (batch 2's
		// remember_views) the restore actively disagreed with what a fresh open
		// of the same file would have done. table_delim is NOT persisted: it is
		// re-derived from the path and first line by doc_view_apply, which is
		// cheaper than a field that can go stale against the file.
		// Bookmarks ride along too (format 5). Comma-separated with NO SPACES,
		// which is the load-bearing part: the path is still "the rest of the
		// line", so every field ahead of it has to be a single token or every
		// later split index moves.
		//
		// "-" for an empty set is NOT load-bearing and is not claimed to be --
		// strings.split_n emits an empty part for a doubled separator, so the
		// positions would survive an empty token (sabotage-verified: removing
		// the placeholder breaks nothing). It is here so a human reading
		// session.txt sees a field rather than a gap, and so a field appended
		// after it later is unambiguous by eye.
		bm := strings.builder_make(context.temp_allocator)
		for b, i in d.bookmarks {
			if i >= SESSION_BOOKMARKS_MAX {break}
			if i > 0 {strings.write_byte(&bm, ',')}
			strings.write_int(&bm, b)
		}
		bm_field := strings.to_string(bm)
		if bm_field == "" {bm_field = "-"}

		fmt.sbprintf(
			&tb,
			"%d %d %d %d %d %d %d %d %d %d %d %d %s %d %s\n",
			d.cursor,
			d.anchor,
			d.top,
			1 if d.wrap else 0,
			int(d.enc),
			backup_idx,
			d.disk_stamp.mtime,
			d.disk_stamp.size,
			1 if d.had_bom else 0,
			int(d.eol),
			int(d.md_mode),
			1 if d.table else 0,
			bm_field,
			// The user's ANSWER, not the resolved bool. Persisting the resolution
			// would freeze a guess into a decision: a file whose heuristic answer
			// was "headerless" would come back as though a person had said so, and
			// would then teach the family default and never be re-judged when its
			// contents changed. Auto restores as Auto and is decided again.
			int(d.table_header_mode),
			d.path,
		)
		ti += 1
	}

	body := fmt.tprintf("newtpad-session 6\nactive %d\n%s", active_idx, strings.to_string(tb))
	sp := pjoin({dir, "session.txt"})
	if !plat.file_write_atomic(sp, transmute([]u8)body) {
		return false
	}
	// session.txt now points only at backups we just wrote; delete the rest.
	if sweep_backups {
		for i in 0 ..< MAX_SESSION_TABS {
			if !used[i] {plat.file_delete(backup_path(backups, i))}
		}
	}
	return true
}

// Reopen the last session into `a` (which must be empty). Returns false if there
// is no session or nothing could be restored.
//
// This procedure deliberately NEVER calls app_apply_view_defaults, and that is a
// rule, not an omission. Every tab here is built directly (doc_open /
// doc_from_content) and then given the view the session recorded for that
// specific file; the family default is what a FRESH open falls back to when
// there is nothing better. Applying it on top would silently overwrite a view
// the user deliberately left set -- a .md tab left in Preview coming back as
// Split because the family default says so. Restore wins over the default,
// always. (The reasoning also lives at app_apply_view_defaults in app.odin, at
// the other end of the same rule.)
//
// The test that holds the line is viewmemtest's "session restore wins over the
// family default" case (HANDOFF §6z), sabotage-verified by wiring
// app_apply_view_defaults in here and watching it fail. Worth knowing before
// trusting it: that assertion was VACUOUS for eight tasks of batch 6 -- it
// expected md_mode == .Off against a session format that carried only `wrap`,
// so the value was constant whether this code was right or wrong. Format 4
// persists md_mode and it now asserts .Preview against a .Split family default,
// which is the version that can actually fail. If a future format change makes
// another of its values constant again, the case needs the same treatment.
// Put a session line's bookmark field back onto a restored tab, or refuse to.
//
// A bookmark is a byte offset into a specific sequence of bytes, so it is only
// meaningful against the file the session recorded. Three gates, in order:
//
//   - `from_backup` is the crash-safe copy of the buffer as we left it, so its
//     offsets are exactly the ones that were written. Always trusted.
//   - a clean tab is reopened from disk, so the offsets are only good if the
//     file is byte-for-byte what it was. The recorded stamp against the stamp
//     doc_open just took answers that, and a mismatch DROPS the whole set --
//     the same "trust disk for clean" reasoning §6b used for the buffer itself.
//     Restoring them anyway would put marks on lines nobody bookmarked, which
//     is worse than losing them, because it is silent.
//   - anything that is not a line start in the buffer that actually loaded is
//     dropped individually. That is defence against a stamp that did not move
//     (mtime granularity, a same-size in-place rewrite), and it is also what
//     keeps doc.bookmarks' invariant true for a set that came off disk rather
//     than out of the shift rules.
//
// Out-of-order or duplicate entries in the file are dropped by the same pass,
// so a hand-edited session.txt cannot break the sorted-list assumption that
// bookmark_find relies on.
@(private = "file")
session_restore_bookmarks :: proc(d: ^Document, field: string, stamp: plat.File_Stamp, from_backup: bool) {
	if field == "" || field == "-" {return}
	if !from_backup {
		if !stamp.ok || !d.disk_stamp.ok {return}
		if stamp.mtime != d.disk_stamp.mtime || stamp.size != d.disk_stamp.size {return}
	}
	prev := -1
	rest := field
	for tok in strings.split_iterator(&rest, ",") {
		v, vok := strconv.parse_int(tok)
		if !vok || v <= prev || v < 0 || v > d.pt.length {continue}
		if v > 0 {
			one: [1]u8
			base.pt_read(&d.pt, v - 1, one[:])
			if one[0] != '\n' {continue}
		}
		append(&d.bookmarks, v)
		prev = v
		if len(d.bookmarks) >= SESSION_BOOKMARKS_MAX {break}
	}
}

// `from` overrides the store to read, and exists for exactly one caller:
// session_adopt_orphans, which restores the tabs of a torn-off window whose
// process died. Everything else passes nothing and gets this process's own store.
// Appends, so adopting orphans on top of an already-restored session keeps both.
session_restore :: proc(a: ^App, from := "") -> bool {
	dir, ok := from, true
	if from == "" {dir, ok = session_dir()}
	if !ok {
		return false
	}
	backups := pjoin({dir, "backups"})
	sp := pjoin({dir, "session.txt"})
	data, rerr := plat.file_read_all(sp, context.temp_allocator)
	if !rerr {
		return false
	}
	lines := strings.split_lines(string(data), context.temp_allocator)
	if len(lines) < 2 || !strings.has_prefix(lines[0], "newtpad-session") {
		return false
	}
	// Format 1 lines have no stamp fields. Read them rather than discarding a
	// session written by the previous build.
	ver := pint(strings.trim_space(lines[0][len("newtpad-session"):]))
	if ver < 1 {ver = 1}
	active := 0
	if strings.has_prefix(lines[1], "active ") {
		active = pint(lines[1][7:])
	}

	restored := 0
	active_slot := 0
	ti := 0
	for li in 2 ..< len(lines) {
		if len(lines[li]) == 0 {continue}
		// path is last and may contain spaces, so the split count is the field count
		nf := 7
		switch {
		case ver >= 6:
			nf = 15
		case ver == 5:
			nf = 14
		case ver == 4:
			nf = 13
		case ver == 3:
			nf = 11
		case ver == 2:
			nf = 9
		}
		parts := strings.split_n(lines[li], " ", nf, context.temp_allocator)
		if len(parts) < 6 {continue}
		cursor := pint(parts[0])
		anchor := pint(parts[1])
		top := pint(parts[2])
		wrap := pint(parts[3]) != 0
		enc := base.Encoding(pint(parts[4]))
		bidx := pint(parts[5])
		stamp: plat.File_Stamp
		had_bom := false
		eol := base.Line_Ending.LF
		have_eol := false
		md_mode := Md_Mode.Off
		table := false
		header_mode := Table_Header_Mode.Auto
		bm_field := ""
		path := ""
		if ver >= 2 {
			if len(parts) >= 8 {
				mt := u64(pint(parts[6]))
				stamp = plat.File_Stamp{mtime = mt, size = i64(pint(parts[7])), ok = mt != 0}
			}
			if ver >= 3 {
				if len(parts) >= 10 {
					had_bom = pint(parts[8]) != 0
					eol = base.Line_Ending(pint(parts[9]))
					have_eol = true
				}
				if ver >= 4 {
					if len(parts) >= 12 {
						// Range-checked, not cast blind: an out-of-range integer
						// read off disk makes an invalid enum, and every switch on
						// it then falls through -- the same degrade-don't-corrupt
						// rule link_style and font_style follow in settings.odin.
						m := pint(parts[10])
						if m >= int(Md_Mode.Off) && m <= int(Md_Mode.Split) {
							md_mode = Md_Mode(m)
						}
						table = pint(parts[11]) != 0
					}
					if ver >= 5 {
						if len(parts) >= 13 {bm_field = parts[12]}
						if ver >= 6 {
							// Format 6: the user's answer about line 0, appended
							// after the bookmarks and ahead of the path, which is
							// where every added field goes. Range-checked like
							// md_mode above -- an out-of-range integer off disk
							// would make an invalid enum and every switch on it
							// would fall through.
							if len(parts) >= 14 {
								m := pint(parts[13])
								if m >= int(Table_Header_Mode.Auto) && m <= int(max(Table_Header_Mode)) {
									header_mode = Table_Header_Mode(m)
								}
							}
							path = parts[14] if len(parts) == 15 else ""
						} else {
							path = parts[13] if len(parts) == 14 else ""
						}
					} else {
						path = parts[12] if len(parts) == 13 else ""
					}
				} else {
					path = parts[10] if len(parts) == 11 else ""
				}
			} else {
				path = parts[8] if len(parts) == 9 else ""
			}
		} else {
			path = parts[6] if len(parts) == 7 else ""
		}

		d := new(Document)
		created := false
		// "the session RECORDED a backup" (bidx >= 0) is not "the backup LOADED".
		// A missing, swept or unreadable backup falls through to doc_open below,
		// which is a reopen FROM DISK -- so everything that is only true of a
		// restored buffer (the recorded BOM/EOL, and above all the bookmark
		// offsets, which describe the bytes we wrote, not the bytes on disk) must
		// key off this and not off bidx.
		from_backup := false
		if bidx >= 0 { // dirty/untitled: restore content from the backup
			if content, cerr := plat.file_read_all(backup_path(backups, bidx), context.allocator); cerr {
				d^ = doc_from_content(content, path, enc)
				created = true
				from_backup = true
			}
		}
		if !created && path != "" { // clean tab: reopen from disk
			ok2: bool
			d^, ok2 = doc_open(path)
			created = ok2
		}
		if created {
			L := d.pt.length
			d.cursor = clamp(cursor, 0, L)
			d.anchor = clamp(anchor, 0, L)
			d.top = clamp(top, 0, L)
			// After the position clamps, not before: doc_view_apply re-anchors
			// doc.top to a line start when a line-scrolled view is on.
			doc_view_apply(d, Doc_View{wrap = wrap, md_mode = md_mode, table = table, table_header_mode = header_mode})
			// A buffer rebuilt from a backup has never been stat'd (doc_from_content
			// sets no stamp), while doc_open already stamped the clean-tab case. Adopt
			// what the session recorded so an unchanged file stays quiet -- and a file
			// that genuinely changed while we were closed still reports.
			if !d.disk_stamp.ok && d.path != "" {
				d.disk_stamp = stamp if stamp.ok else plat.file_stamp(d.path)
			}
			// Same for the BOM and line endings, which doc_from_content does not set
			// either. Only for the backup path: doc_open detected both from the real
			// bytes and is authoritative for a clean tab.
			if from_backup && have_eol {
				d.had_bom = had_bom
				d.eol = eol
			}
			session_restore_bookmarks(d, bm_field, stamp, from_backup)
			// In FILE order, which IS display order: session_save walks a.docs in
			// slot order and writes one line per live tab, and `active` is that same
			// display index (ti), not a slot. app_add appends, so replaying the lines
			// top to bottom rebuilds the rail exactly as it was left -- restore is a
			// second, independent route to a scrambled rail and is pinned by
			// `newtpad taborder` as well.
			slot := app_add(a, d)
			if ti == active {active_slot = slot}
			restored += 1
		} else {
			free(d) // missing file / backup — skip this tab
		}
		ti += 1
	}

	if restored == 0 {
		return false
	}
	app_activate(a, active_slot)
	return true
}
