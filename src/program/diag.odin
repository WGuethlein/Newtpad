// Layer: program -- wires the base logger and the platform crash handler to the
// rest of the app. Owns the on-disk log file (append, size-capped), the crash
// directory, the save-on-fatal hook, and the routing of Odin panics/asserts into
// the same crash path. Breadcrumb helpers (diag_cmd, etc.) drop compact lines
// into the log ring so a crash report shows what the user was doing.
//
// Everything degrades quietly: if the session dir can't be found, logging is
// in-memory only and the crash handler still writes what it can.
package main

import "base:intrinsics"
import "base:runtime"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:sync"
import base "src:base"
import plat "src:platform"

@(private = "file")
djoin :: proc(a, b: string) -> string {
	s, _ := filepath.join({a, b}, context.temp_allocator)
	return s
}

LOG_FILE_MAX :: 2 * 1024 * 1024 // roll the log when it passes this (bytes)

@(private = "file")
g_diag: struct {
	logf:    ^os.File,
	logf_ok: bool,
	mu:      sync.Mutex, // the sink runs on worker threads too
	app:     ^App, // for the save-on-crash hook
	primary: bool,
	sweep:   bool,
}

// Set up logging + crash handling. Call once at startup, after session_dir is
// usable. `context.assertion_failure_proc` is set by the caller (in main), not
// here, because the Odin context propagates down the call tree, not up.
diag_init :: proc() {
	level := base.Log_Level.Info
	when ODIN_DEBUG {level = .Debug}
	base.log_init(level)

	dir, ok := session_dir()
	if ok {
		logs := djoin(dir, "logs")
		os.make_directory(logs)
		crashes := djoin(dir, "crashes")
		os.make_directory(crashes)
		diag_open_log(djoin(logs, "newtpad.log"))
		plat.crash_install(crashes, NEWTPAD_VERSION, diag_on_fatal)
	}

	base.log_set_sink(diag_sink)
	base.log_info("Newtpad %s starting (debug=%v)", NEWTPAD_VERSION, ODIN_DEBUG)
}

// Give the crash handler what it needs to save the user's work. Called from main
// once the App exists.
diag_bind_app :: proc(app: ^App, primary, sweep: bool) {
	g_diag.app = app
	g_diag.primary = primary
	g_diag.sweep = sweep
}

@(private = "file")
diag_open_log :: proc(path: string) {
	// Roll when the file gets large: keep one .old, start fresh. Bounded, no
	// unbounded growth on a long-lived daily driver.
	if fi, err := os.stat(path, context.temp_allocator); err == nil && fi.size > LOG_FILE_MAX {
		old := fmt.tprintf("%s.old", path)
		os.remove(old)
		os.rename(path, old)
	}
	h, err := os.open(path, os.File_Flags{.Write, .Create, .Append})
	if err != nil {return}
	g_diag.logf = h
	g_diag.logf_ok = true
}

// The log sink: append every line to the file, and echo warnings+ to the console
// on debug builds. Thread-safe. Formats into a stack buffer -- no heap on the
// path a worker thread hits constantly.
@(private = "file")
diag_sink :: proc(level: base.Log_Level, seq: u64, t_ms: f64, msg: string) {
	buf: [base.LOG_LINE_MAX + 48]u8
	line := fmt.bprintf(buf[:], "[%9.1f] %s %s\n", t_ms, base.log_level_name(level), msg)
	sync.mutex_lock(&g_diag.mu)
	if g_diag.logf_ok {os.write(g_diag.logf, transmute([]u8)line)}
	sync.mutex_unlock(&g_diag.mu)
	when ODIN_DEBUG {
		if level >= .Warn {fmt.eprint(line)}
	}
}

// Save-the-user's-work hook, run from the crash handler before the process dies.
// Never sweeps backups (a half-corrupt App must not delete files), and flushes
// the log so the last breadcrumbs reach disk.
@(private = "file")
diag_on_fatal :: proc() {
	if g_diag.primary && g_diag.app != nil {
		session_save(g_diag.app, false) // sweep=false: never delete backups on a crash
	}
	sync.mutex_lock(&g_diag.mu)
	if g_diag.logf_ok {
		os.flush(g_diag.logf)
		os.close(g_diag.logf)
		g_diag.logf_ok = false
	}
	sync.mutex_unlock(&g_diag.mu)
}

// Route Odin panics/asserts (`assert`, `panic`, bounds checks) through the crash
// path: record the reason in the log ring, then trap. The trap raises an illegal
// instruction, which the platform unhandled-exception filter catches and turns
// into a full dump + report + save + message -- the same path as a hardware
// fault, so panics and access violations get identical treatment.
diag_assert_fail :: proc(prefix, message: string, loc: runtime.Source_Code_Location) -> ! {
	base.log_error("%s: %s (%s:%d:%d)", prefix, message, loc.file_path, loc.line, loc.column)
	plat.crash_note(fmt.tprintf("%s: %s", prefix, message))
	intrinsics.trap()
}

// --- breadcrumbs ------------------------------------------------------------
// Compact, cheap lines that make a crash report readable. Kept out of the hot
// per-frame path; these mark user-visible events.

diag_cmd :: proc(cmd: Command_Id) {
	base.log_debug("cmd %v", cmd)
}

diag_open :: proc(path: string, size: int, ok: bool) {
	if ok {
		base.log_info("open %q (%d bytes)", path, size)
	} else {
		base.log_warn("open failed %q", path)
	}
}

// Flush the log on a clean exit too, so a normal shutdown's tail is on disk.
diag_shutdown :: proc() {
	base.log_info("Newtpad exiting")
	sync.mutex_lock(&g_diag.mu)
	if g_diag.logf_ok {
		os.flush(g_diag.logf)
		os.close(g_diag.logf)
		g_diag.logf_ok = false
	}
	sync.mutex_unlock(&g_diag.mu)
}
