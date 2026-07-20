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
package main

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"
import base "src:base"
import plat "src:platform"

MAX_SESSION_TABS :: 64

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
		os.make_directory(over)
		return over, true
	}
	appdata := os.get_env("APPDATA", context.temp_allocator)
	if appdata == "" {
		return "", false
	}
	dir = pjoin({appdata, "Newtpad"})
	os.make_directory(dir) // ignore "already exists"
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
	os.remove(fmt.tprintf("%s%csession.txt.newtpad~", dir, filepath.SEPARATOR))
	for i in 0 ..< MAX_SESSION_TABS {
		os.remove(fmt.tprintf("%s.newtpad~", backup_path(backups, i)))
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
	return os.exists(pjoin({dir, "session.txt"}))
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
	os.make_directory(backups)

	tb := strings.builder_make(context.temp_allocator)
	active_idx := 0
	ti := 0
	used: [MAX_SESSION_TABS]bool
	for d, slot in a.docs {
		if d == nil || ti >= MAX_SESSION_TABS {continue}
		// skip the empty untitled scratch — nothing to restore
		if d.path == "" && !d.modified && d.pt.length == 0 {continue}

		backup_idx := -1
		if d.modified || (d.path == "" && d.pt.length > 0) {
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
		fmt.sbprintf(
			&tb,
			"%d %d %d %d %d %d %d %d %d %d %s\n",
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
			d.path,
		)
		ti += 1
	}

	body := fmt.tprintf("newtpad-session 3\nactive %d\n%s", active_idx, strings.to_string(tb))
	sp := pjoin({dir, "session.txt"})
	if !plat.file_write_atomic(sp, transmute([]u8)body) {
		return false
	}
	// session.txt now points only at backups we just wrote; delete the rest.
	if sweep_backups {
		for i in 0 ..< MAX_SESSION_TABS {
			if !used[i] {os.remove(backup_path(backups, i))}
		}
	}
	return true
}

// Reopen the last session into `a` (which must be empty). Returns false if there
// is no session or nothing could be restored.
session_restore :: proc(a: ^App) -> bool {
	dir, ok := session_dir()
	if !ok {
		return false
	}
	backups := pjoin({dir, "backups"})
	sp := pjoin({dir, "session.txt"})
	data, rerr := os.read_entire_file(sp, context.temp_allocator)
	if rerr != nil {
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
		case ver >= 3:
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
				path = parts[10] if len(parts) == 11 else ""
			} else {
				path = parts[8] if len(parts) == 9 else ""
			}
		} else {
			path = parts[6] if len(parts) == 7 else ""
		}

		d := new(Document)
		created := false
		if bidx >= 0 { // dirty/untitled: restore content from the backup
			if content, cerr := os.read_entire_file(backup_path(backups, bidx), context.allocator); cerr == nil {
				d^ = doc_from_content(content, path, enc)
				created = true
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
			d.wrap = wrap
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
			if bidx >= 0 && have_eol {
				d.had_bom = had_bom
				d.eol = eol
			}
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
