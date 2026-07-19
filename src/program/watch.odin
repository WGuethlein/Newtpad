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
WATCH_MAX :: MAX_TABS

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
	for d, slot in app.docs {
		if d == nil || d.path == "" || len(w.want) >= WATCH_MAX {continue}
		append(&w.want, Watch_Entry{slot = slot, gen = d.gen, path = strings.clone(d.path), stamp = d.disk_stamp})
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
