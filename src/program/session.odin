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
@(private = "file")
session_dir :: proc() -> (dir: string, ok: bool) {
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
session_save :: proc(a: ^App) -> bool {
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
		fmt.sbprintf(&tb, "%d %d %d %d %d %d %s\n", d.cursor, d.anchor, d.top, 1 if d.wrap else 0, int(d.enc), backup_idx, d.path)
		ti += 1
	}

	body := fmt.tprintf("newtpad-session 1\nactive %d\n%s", active_idx, strings.to_string(tb))
	sp := pjoin({dir, "session.txt"})
	if !plat.file_write_atomic(sp, transmute([]u8)body) {
		return false
	}
	// session.txt now points only at backups we just wrote; delete the rest.
	for i in 0 ..< MAX_SESSION_TABS {
		if !used[i] {os.remove(backup_path(backups, i))}
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
	active := 0
	if strings.has_prefix(lines[1], "active ") {
		active = pint(lines[1][7:])
	}

	restored := 0
	active_slot := 0
	ti := 0
	for li in 2 ..< len(lines) {
		if len(lines[li]) == 0 {continue}
		parts := strings.split_n(lines[li], " ", 7, context.temp_allocator)
		if len(parts) < 6 {continue}
		cursor := pint(parts[0])
		anchor := pint(parts[1])
		top := pint(parts[2])
		wrap := pint(parts[3]) != 0
		enc := base.Encoding(pint(parts[4]))
		bidx := pint(parts[5])
		path := parts[6] if len(parts) == 7 else ""

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
