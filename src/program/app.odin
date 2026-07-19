// Layer: program — the open-document set and tab state. Documents are heap-boxed
// (new(Document)) so their addresses are STABLE: the index worker holds a pointer
// into its Document, and tab/active state references slot indices, so nothing may
// move a Document. `docs` is a slot array — a closed tab's slot goes nil and is
// reused, never shifted, so indices stay valid. (Per the tabs decision: stable
// addresses, plain slot indices, no generational handles until a job re-resolves
// a handle across a frame; see HANDOFF Decisions.)
package main

import "core:path/filepath"
import "core:strings"

App :: struct {
	docs:       [dynamic]^Document, // slot array; nil = empty slot (never shifts)
	active:     int, // slot index of the active document
	mru:        [dynamic]int, // live slots, most-recently-active first
	tab_scroll: f32, // horizontal scroll of the tab strip (overflow)
	menu:       Menu_State,
	settings:      Settings,
	settings_open: bool,
	settings_row:  int,
	palette:    Palette, // command palette overlay (Ctrl+P)
}

app_active :: proc(a: ^App) -> ^Document {
	if a.active >= 0 && a.active < len(a.docs) {
		return a.docs[a.active]
	}
	return nil
}

app_live_count :: proc(a: ^App) -> (n: int) {
	for d in a.docs {
		if d != nil {n += 1}
	}
	return
}

// Place a document in a free slot (reusing a nil one) and return its slot.
app_add :: proc(a: ^App, d: ^Document) -> int {
	for slot, i in a.docs {
		if slot == nil {
			a.docs[i] = d
			return i
		}
	}
	append(&a.docs, d)
	return len(a.docs) - 1
}

// Make `slot` active: reorder MRU and lazily start its line index on first view
// (so restoring N tabs doesn't spawn N index threads at once).
app_activate :: proc(a: ^App, slot: int) {
	if slot < 0 || slot >= len(a.docs) || a.docs[slot] == nil {
		return
	}
	a.active = slot
	// move slot to MRU front
	for s, i in a.mru {
		if s == slot {
			ordered_remove(&a.mru, i)
			break
		}
	}
	inject_at(&a.mru, 0, slot)
	// lazy index start (idx.th stays nil until first activation)
	d := a.docs[slot]
	if d.idx.th == nil {
		doc_index_start(d)
	}
}

app_new_scratch :: proc(a: ^App) {
	d := new(Document)
	d^ = doc_new()
	d.wrap = a.settings.wrap_default
	app_activate(a, app_add(a, d))
}

// Open `path` into a new tab and activate it. Returns false if the file couldn't
// be opened (no tab is added in that case).
app_open_path :: proc(a: ^App, path: string) -> bool {
	// already open? just activate it.
	for d, i in a.docs {
		if d != nil && d.path == path {
			app_activate(a, i)
			return true
		}
	}
	d := new(Document)
	ok: bool
	d^, ok = doc_open(path)
	if !ok {
		free(d)
		return false
	}
	app_activate(a, app_add(a, d))
	return true
}

// Close the tab in `slot`. Frees its Document. If it was active, activates the
// next MRU tab; if it was the last tab, opens a fresh scratch (the window never
// falls to an empty state — only the OS window-close exits).
app_close :: proc(a: ^App, slot: int) {
	if slot < 0 || slot >= len(a.docs) || a.docs[slot] == nil {
		return
	}
	doc_close(a.docs[slot])
	free(a.docs[slot])
	a.docs[slot] = nil
	for s, i in a.mru {
		if s == slot {
			ordered_remove(&a.mru, i)
			break
		}
	}
	if a.active == slot {
		if len(a.mru) > 0 {
			a.active = a.mru[0]
		} else {
			app_new_scratch(a) // last tab closed -> fresh scratch
		}
	}
}

// Switch to the next (dir=+1) or previous (dir=-1) tab in slot order, wrapping.
app_switch_relative :: proc(a: ^App, dir: int) {
	live := make([dynamic]int, 0, len(a.docs), context.temp_allocator)
	for d, i in a.docs {
		if d != nil {append(&live, i)}
	}
	if len(live) <= 1 {
		return
	}
	cur := 0
	for s, i in live {
		if s == a.active {
			cur = i
			break
		}
	}
	app_activate(a, live[(cur + dir + len(live)) % len(live)])
}

app_destroy :: proc(a: ^App) {
	for d in a.docs {
		if d != nil {
			doc_close(d)
			free(d)
		}
	}
	delete(a.docs)
	delete(a.mru)
	delete(a.palette.query)
	delete(a.palette.results)
}

// The document's display name: file base name, or "untitled" for a scratch.
doc_display_name :: proc(d: ^Document) -> string {
	if d.path != "" {
		return filepath.base(d.path)
	}
	return "untitled"
}

// Tab label: display name with a leading "*" when modified.
tab_title :: proc(d: ^Document, allocator := context.temp_allocator) -> string {
	name := doc_display_name(d)
	if d.modified {
		return strings.concatenate({"*", name}, allocator)
	}
	return strings.clone(name, allocator)
}
