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
session_dir :: proc() -> (dir: string, ok: bool) {
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
			"%d %d %d %d %d %d %d %d %d %d %d %d %s %s\n",
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
			d.path,
		)
		ti += 1
	}

	body := fmt.tprintf("newtpad-session 5\nactive %d\n%s", active_idx, strings.to_string(tb))
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

session_restore :: proc(a: ^App) -> bool {
	dir, ok := session_dir()
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
		case ver >= 5:
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
						path = parts[13] if len(parts) == 14 else ""
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
			doc_view_apply(d, Doc_View{wrap = wrap, md_mode = md_mode, table = table})
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
