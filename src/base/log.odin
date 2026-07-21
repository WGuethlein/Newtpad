// Layer: base -- a small, always-on structured logger. Two jobs: keep the last
// N lines in a fixed in-memory ring (the breadcrumb trail a crash report dumps,
// so "random" bugs come with the sequence that led to them), and hand each line
// to an optional sink (the program installs a file/console sink -- base itself
// never touches the filesystem or Win32, mirroring how safe_copy is injected).
//
// Everything here is bounded and allocation-free on the hot path: a line formats
// into a stack buffer and is copied into the ring under a short mutex, so it is
// safe to call from the worker threads (search, watcher) as well as the main
// loop. Dropping in a log() call anywhere is meant to be effectively free.
package base

import "core:fmt"
import "core:sync"
import "core:time"

Log_Level :: enum u8 {
	Debug, // per-frame / verbose; gated off in release
	Info, // notable lifecycle events (open, save, mode change)
	Warn, // recovered-from trouble (fault recovery, disk change)
	Error, // something failed
}

LOG_RING :: 1024 // entries retained in memory for the crash dump
LOG_LINE_MAX :: 240 // bytes kept per entry (longer lines truncate)

Log_Entry :: struct {
	seq:   u64, // monotonic; 0 means "never written" (empty slot)
	t_ms:  f64, // ms since log_init, monotonic
	level: Log_Level,
	len:   int,
	text:  [LOG_LINE_MAX]u8,
}

// A sink receives every line that passes the level gate, in order. The program
// sets one to tee lines to the log file and (debug build) the console.
Log_Sink :: proc(level: Log_Level, seq: u64, t_ms: f64, msg: string)

@(private = "file")
Log_State :: struct {
	mu:        sync.Mutex,
	ring:      [LOG_RING]Log_Entry,
	head:      int, // next slot to write
	seq:       u64, // total lines ever written
	min_level: Log_Level,
	start:     time.Tick,
	started:   bool,
	sink:      Log_Sink,
}

@(private = "file")
g_log: Log_State

// Arm the logger. Safe to call before anything else; log() no-ops cleanly even
// if this was never called (start tick zero -> t_ms 0), so a forgotten init
// degrades to timestamps of 0 rather than a crash.
log_init :: proc(min_level: Log_Level = .Info) {
	sync.mutex_lock(&g_log.mu)
	g_log.min_level = min_level
	g_log.start = time.tick_now()
	g_log.started = true
	sync.mutex_unlock(&g_log.mu)
}

log_set_sink :: proc(s: Log_Sink) {
	sync.mutex_lock(&g_log.mu)
	g_log.sink = s
	sync.mutex_unlock(&g_log.mu)
}

log_set_level :: proc(l: Log_Level) {
	sync.mutex_lock(&g_log.mu)
	g_log.min_level = l
	sync.mutex_unlock(&g_log.mu)
}

log_level :: proc() -> Log_Level {
	sync.mutex_lock(&g_log.mu)
	defer sync.mutex_unlock(&g_log.mu)
	return g_log.min_level
}

// Format and record one line. Below the level gate it returns immediately,
// before formatting, so a gated-off log() costs one comparison. The sink is
// called outside the ring lock so a slow sink (a disk write) can't stall a
// worker thread that is only trying to append a breadcrumb.
log :: proc(level: Log_Level, format: string, args: ..any) {
	if level < g_log.min_level {return}
	buf: [LOG_LINE_MAX]u8
	msg := fmt.bprintf(buf[:], format, ..args)
	if len(msg) > LOG_LINE_MAX {msg = msg[:LOG_LINE_MAX]}

	t_ms := 0.0
	if g_log.started {t_ms = time.duration_milliseconds(time.tick_since(g_log.start))}

	sync.mutex_lock(&g_log.mu)
	seq := g_log.seq + 1
	g_log.seq = seq
	e := &g_log.ring[g_log.head]
	e.seq = seq
	e.t_ms = t_ms
	e.level = level
	e.len = len(msg)
	copy(e.text[:], transmute([]u8)msg)
	g_log.head = (g_log.head + 1) % LOG_RING
	sink := g_log.sink
	sync.mutex_unlock(&g_log.mu)

	if sink != nil {sink(level, seq, t_ms, msg)}
}

log_debug :: proc(format: string, args: ..any) {log(.Debug, format, ..args)}
log_info :: proc(format: string, args: ..any) {log(.Info, format, ..args)}
log_warn :: proc(format: string, args: ..any) {log(.Warn, format, ..args)}
log_error :: proc(format: string, args: ..any) {log(.Error, format, ..args)}

log_level_name :: proc(l: Log_Level) -> string {
	switch l {
	case .Debug:
		return "DBG"
	case .Info:
		return "INF"
	case .Warn:
		return "WRN"
	case .Error:
		return "ERR"
	}
	return "???"
}

// Walk the retained lines oldest-first, calling `emit` for each. Used by the
// crash reporter to fold the breadcrumb trail into the report, and by the
// diagnostics dump. Snapshots under the lock into a caller-agnostic callback so
// it can be called from a crash handler without allocating.
log_each :: proc(emit: proc(rawptr, ^Log_Entry), user: rawptr) {
	sync.mutex_lock(&g_log.mu)
	defer sync.mutex_unlock(&g_log.mu)
	// The ring holds at most LOG_RING lines; start at the oldest still present.
	start := g_log.head
	for i in 0 ..< LOG_RING {
		idx := (start + i) % LOG_RING
		e := &g_log.ring[idx]
		if e.seq == 0 {continue} // never-written slot (buffer not yet full)
		emit(user, e)
	}
}

// Retained-line count (for tests / diagnostics headers).
log_retained :: proc() -> int {
	sync.mutex_lock(&g_log.mu)
	defer sync.mutex_unlock(&g_log.mu)
	return min(int(g_log.seq), LOG_RING)
}

log_total :: proc() -> u64 {
	sync.mutex_lock(&g_log.mu)
	defer sync.mutex_unlock(&g_log.mu)
	return g_log.seq
}
