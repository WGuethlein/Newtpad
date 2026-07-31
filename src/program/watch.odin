// Layer: program — external-change detection.
//
// CLAUDE.md requires this ("external-change detection via timestamp polling,
// never held handles") and it was unimplemented: a file changed by another
// program was neither noticed nor reloaded, and saving silently clobbered it.
//
// Polling runs on a worker because a stat on a dropped network share blocks for
// the redirector timeout — the same reason file_open_readonly refuses to mmap
// non-fixed drives. The main thread must never block on the filesystem.
//
// The worker copies its inputs (CLAUDE.md: "Jobs copy their inputs, work in
// private memory, merge results once per frame"). It holds no Document pointer
// and no borrowed path: documents are freed on close and doc.path is reallocated
// on every save, so either would be a use-after-free.
package main

import "base:intrinsics"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"
import plat "src:platform"

WATCH_INTERVAL_MS :: 1000

// Upper bound on watched files, and it is the WATCHER's budget only -- tabs
// themselves are unlimited (app_add caps nothing) and a session restores at most
// MAX_SESSION_TABS. This used to be spelled `MAX_TABS` over in app.odin, whose
// own comment had to say it was "independent of the session's tab limit"
// precisely because the name claimed otherwise; it was referenced from this one
// line and nowhere else, and it still got read as a tab limit. The name was the
// bug, so the constant now lives where it is used and says what it bounds.
//
// 64 rather than 32 so a fully restored session is covered end to end -- a file
// that was open last time is a file the user expects to be watched.
//
// The cap is NOT about CPU: a stat on a local file is microseconds, and the
// worker sleeps a second between cycles. It is about the worst case in
// watch_worker below -- a stat "can block for many seconds on an unreachable
// share" -- so an unbounded list of dead UNC paths would stretch a cycle without
// limit. Raising the number therefore trades a wider covered set against a worse
// tail, which is why this is 64 and not "no cap".
WATCH_MAX :: 64

// One watched file. `gen` guards against a slot being reused by a different
// document while the worker is mid-stat: the result is discarded unless the
// generation still matches.
Watch_Entry :: struct {
	slot:  int,
	gen:   u64,
	path:  string, // owned by the watcher, cloned from doc.path
	stamp: plat.File_Stamp,
}

Watcher :: struct {
	th:      ^thread.Thread,
	cancel:  bool, // atomic
	mu:      sync.Mutex, // guards `want` and `found`
	want:    [dynamic]Watch_Entry, // what the main thread asked to watch
	found:   [dynamic]Watch_Entry, // stamps the worker observed as changed
	pending: bool, // atomic: `found` is non-empty
}

watcher_start :: proc(w: ^Watcher) {
	w.th = thread.create_and_start_with_data(w, watch_worker)
}

watcher_stop :: proc(w: ^Watcher) {
	if w.th == nil {return}
	intrinsics.atomic_store(&w.cancel, true)
	thread.join(w.th)
	thread.destroy(w.th)
	w.th = nil
	sync.mutex_lock(&w.mu)
	for e in w.want {delete(e.path)}
	for e in w.found {delete(e.path)}
	delete(w.want)
	delete(w.found)
	sync.mutex_unlock(&w.mu)
}

// Publish the current watch list. Called once per frame from the main thread;
// paths are cloned so the worker never aliases doc.path (freed on save/close).
watcher_publish :: proc(w: ^Watcher, app: ^App) {
	if w.th == nil {return}
	sync.mutex_lock(&w.mu)
	defer sync.mutex_unlock(&w.mu)
	for e in w.want {delete(e.path)}
	clear(&w.want)

	// One publisher for a slot, so the cap check and the clone cannot diverge
	// between the two passes below.
	add :: proc(w: ^Watcher, app: ^App, slot: int) {
		if slot < 0 || slot >= len(app.docs) {return}
		d := app.docs[slot]
		if d == nil || d.path == "" || len(w.want) >= WATCH_MAX {return}
		append(&w.want, Watch_Entry{slot = slot, gen = d.gen, path = strings.clone(d.path), stamp = d.disk_stamp})
	}

	// THE ACTIVE DOCUMENT FIRST, before the cap can be spent on anything else.
	//
	// This used to walk slots in order and take the first WATCH_MAX with a path,
	// which meant the cap fell on whichever tabs happened to sit in high slots --
	// silently, with no indicator and no reload prompt. "Never lock the user's
	// file" (CLAUDE.md) is what makes timestamp polling the whole safety
	// mechanism here, so a file dropping out of it is not cosmetic.
	//
	// A cap has to fall somewhere, but it must not fall on the file being looked
	// at: an external change to the ACTIVE document is the case where missing it
	// costs the most, because that is the buffer the user is about to save over.
	// Publishing it first makes that impossible regardless of its slot. The rest
	// still fill in slot order -- recency would be better still, but App keeps no
	// MRU list today and inventing one for this would be a bigger change than the
	// problem warrants.
	add(w, app, app.active)
	for _, slot in app.docs {
		if slot == app.active {continue} // published above; a second entry would double-stat it
		add(w, app, slot)
	}
}

// Drain what the worker saw. Returns entries whose stamp differs from the one
// the main thread published; the caller re-resolves the slot before acting.
watcher_take :: proc(w: ^Watcher, out: ^[dynamic]Watch_Entry) {
	if w.th == nil || !intrinsics.atomic_load(&w.pending) {return}
	sync.mutex_lock(&w.mu)
	defer sync.mutex_unlock(&w.mu)
	for e in w.found {append(out, e)} // path ownership transfers to the caller
	clear(&w.found)
	intrinsics.atomic_store(&w.pending, false)
}

@(private = "file")
watch_worker :: proc(data: rawptr) {
	w := (^Watcher)(data)
	local: [dynamic]Watch_Entry
	defer delete(local)
	for !intrinsics.atomic_load(&w.cancel) {
		// Copy the request list, then stat with the lock released — a stat can
		// block for many seconds on an unreachable share and must not hold the
		// main thread out of the mutex while it does.
		sync.mutex_lock(&w.mu)
		for e in local {delete(e.path)}
		clear(&local)
		for e in w.want {append(&local, Watch_Entry{e.slot, e.gen, strings.clone(e.path), e.stamp})}
		sync.mutex_unlock(&w.mu)

		for &e in local {
			if intrinsics.atomic_load(&w.cancel) {break}
			now := plat.file_stamp(e.path)
			if now == e.stamp {continue}
			sync.mutex_lock(&w.mu)
			append(&w.found, Watch_Entry{e.slot, e.gen, strings.clone(e.path), now})
			sync.mutex_unlock(&w.mu)
			intrinsics.atomic_store(&w.pending, true)
			e.stamp = now // don't re-report the same change every cycle
		}

		// Sleep in slices so cancel lands promptly on shutdown.
		for i := 0; i < WATCH_INTERVAL_MS / 50; i += 1 {
			if intrinsics.atomic_load(&w.cancel) {break}
			time.sleep(50 * time.Millisecond)
		}
	}
	for e in local {delete(e.path)}
}
