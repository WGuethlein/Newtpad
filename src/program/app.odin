// Layer: program — the open-document set and tab state. Documents are heap-boxed
// (new(Document)) so their addresses are STABLE: the index worker holds a pointer
// into its Document, and tab/active state references slot indices, so nothing may
// move a Document. `docs` is a slot array — a closed tab's slot goes nil and STAYS
// nil; it is never shifted, and app_add reclaims only a TRAILING nil (see its
// comment), so a hole with a live tab to its right persists until that tab
// closes too. Indices stay valid either way. (Per the tabs decision: stable
// addresses, plain slot indices, no generational handles until a job re-resolves
// a handle across a frame; see HANDOFF Decisions.)
package main

import "core:path/filepath"
import "core:strings"
import "core:time"

App :: struct {
	docs:       [dynamic]^Document, // slot array; nil = empty slot (never shifts)
	active:     int, // slot index of the active document
	mru:        [dynamic]int, // live slots, most-recently-active first
	tab_scroll: f32, // horizontal scroll of the tab strip (overflow)
	menu:       Menu_State,
	settings:      Settings,
	// Settings and Font are tabs (Document.kind), not overlays; only their
	// cursor position lives here.
	settings_row:  int,
	// First visible settings row, scrolled the same way history.top and
	// menu.top are — see settings_resolve_top. Added when the 8-row list
	// stopped always fitting the window (IMPORTANT 3 in the final review).
	settings_top:  int,
	font_row:      int,
	history:       History_State,
	palette:    Palette, // command palette overlay (Ctrl+P)
	// Monotonic id stamped on each Document. The file watcher is the job the
	// header note anticipated — it re-resolves a slot across frames, so a slot
	// index alone is no longer enough to prove a result belongs to the document
	// that asked for it.
	next_gen:   u64,
	// Tab reorder: a tab is being dragged along the strip. tab_drag_slot follows
	// the dragged document as it swaps places (the slot changes each swap).
	// The tab rail was reached BY KEYBOARD and should draw its focus ring.
	//
	// Not the platform's kbd_nav, which latches on any key: typing a character
	// in the document is a keypress, so gating on it put a focus ring on the
	// active tab on every keystroke. Focus is about WHERE input is going, and a
	// character goes to the document. Set only by Ctrl+Tab / Ctrl+PgUp/PgDn,
	// cleared by anything that moves attention elsewhere.
	//
	// A stand-in for a real chrome focus model, which batch 14 needs anyway for
	// menus and the palette. When that exists this becomes one case of it.
	// How recently each command was run, as a monotonic counter rather than a
	// clock: UI spec 7 breaks ranking ties by "recency of use -- a palette that
	// learns beats a clever scorer", and the only question it has to answer is
	// which of two commands was used later. Not persisted; a session is the
	// right horizon for "what am I doing today".
	cmd_used:      [Command_Id]u32,
	cmd_clock:     u32,
	kbd_tab_focus: bool,
	tab_drag:      bool,
	tab_drag_slot: int,
	// Transient status-bar message (dropped folder, etc). Live from
	// notice_started until NOTICE_SECONDS later; see app_notice_active.
	notice:         string,
	notice_started: time.Tick,
	// The manual update check (update.odin). At most one in flight; joined by
	// app_destroy below, because a network worker that outlives the window
	// writes into freed memory.
	update:         Update_Check,
}

// A short-lived status-bar message's display window. Wall-clock, not a frame
// count: the frame loop blocks in window_wait_message for up to a second at a
// time while idle (main.odin), so "240 frames" stretched a few seconds into
// minutes whenever the app wasn't actively redrawing -- see the report on
// this finding. The zero Tick is always in the past (it predates process
// start), so a never-set notice_started reads as already-expired for free.
NOTICE_SECONDS :: 4.0

// Set the transient status-bar message, replacing any previous one. notice is
// always self-owned (only ever set here), so freeing it unconditionally before
// the clone is safe — the zero value is "", and deleting an empty string is a
// no-op, not a crash.
app_note :: proc(a: ^App, msg: string) {
	delete(a.notice)
	a.notice = strings.clone(msg) // caller's msg is often temp-allocated
	a.notice_started = time.tick_now()
}

// Whether the transient notice is still within its display window. One proc
// so the draw call (main.odin) and anything asserting on it (test_modes.odin)
// share the same definition of "still showing" instead of the draw call
// re-deriving it inline, the way the frame-count version used to.
app_notice_active :: proc(a: ^App) -> bool {
	return a.notice != "" && time.duration_seconds(time.tick_since(a.notice_started)) < NOTICE_SECONDS
}

// Whether the palette, the history panel or an open menu is painted OVER the
// content this frame -- the same three flags main.odin's own click handling
// already gates on, each in its own place: menu_hit_test claims the bar and
// any dropdown, the palette block (:509) claims a click while app.palette.active,
// the history block (:540) claims one while app.history.open. Anything else
// that hit-tests content pixels -- the header's right-click gate is the first
// -- needs the same refusal for the same reason: an overlay drawn over the
// content means a coordinate in the content's space is being read from
// underneath something else, not the content itself. One proc so a second
// gate reads the definition rather than re-deriving it, and so a test can
// assert against the exact predicate production uses instead of a copy that
// can drift from it.
app_content_overlay_active :: proc(a: ^App) -> bool {
	return menu_is_active(a) || a.palette.active || a.history.open
}

// Swap the documents in two slots (tab reorder). Slot indices are referenced by
// `active`, `mru` and the watcher (via each doc's gen), so those move with the
// docs: active/mru are remapped here, and the watcher's gen check discards any
// in-flight result for a slot whose document changed.
app_swap_tabs :: proc(a: ^App, sa, sb: int) {
	if sa == sb || sa < 0 || sb < 0 || sa >= len(a.docs) || sb >= len(a.docs) {return}
	a.docs[sa], a.docs[sb] = a.docs[sb], a.docs[sa]
	switch a.active {
	case sa:
		a.active = sb
	case sb:
		a.active = sa
	}
	for &m in a.mru {
		switch m {
		case sa:
			m = sb
		case sb:
			m = sa
		}
	}
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

// Place a document after every live tab and return its slot.
//
// Tab order is an invariant, not a placement heuristic: the rail's display order
// is the order tabs were added, and the only thing that ever reorders it is an
// explicit user drag (app_swap_tabs). This used to reuse the first nil slot, so
// closing a middle tab and then opening a file put the new tab in the hole --
// Wyatt: "sometimes tabs get added in the middle of the tab list... it should
// always appear at the end if it was newly created, dragged in, or opened", and
// on seeing the diagnosis, "I don't want random order tabs, unacceptable."
//
// The `at_end` parameter that opted into the right behaviour is GONE rather than
// defaulted: three of its four callers omitted it and got the wrong placement,
// and a parameter with one legal value is the next caller's chance to get it
// wrong again. Same for app_new_scratch's.
//
// Slots still never shift (see the header comment): a closed middle tab leaves a
// nil hole that stays a hole, so every live slot index -- a.active, a.mru,
// Watch_Entry.slot, Palette_Result.slot -- keeps meaning what it meant.
app_add :: proc(a: ^App, d: ^Document) -> int {
	a.next_gen += 1
	d.gen = a.next_gen // identifies this document across slot reuse
	// Trailing empty slots would still put it before live tabs; drop them first
	// so "end" really is the end. This is also what keeps `docs` from growing
	// without bound over a long session: closing and reopening the last tab
	// reclaims its slot, and only a hole with live tabs to its right persists.
	for len(a.docs) > 0 && a.docs[len(a.docs) - 1] == nil {
		pop(&a.docs)
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
	if d.lex_idx.th == nil {
		lex_index_start(d) // no-op when the doc's lexer isn't stateful or the file is mapped
	}
	// The history panel is one global surface showing whichever document is
	// active, but its selected row indexes THAT document's undo stack. Switching
	// tabs with the panel open left the old document's row number pointing into
	// the new document's history, so pressing Enter jumped it to an unrelated
	// state -- silently redoing edits that had been deliberately undone. Re-seat
	// the selection on the document now being shown.
	if a.history.open {
		a.history.sel = doc_history_current(d)
		a.history.top = 0 // the draw clamps this to bring the selection into view
	}
}

app_new_scratch :: proc(a: ^App) {
	d := new(Document)
	d^ = doc_new()
	d.wrap = a.settings.wrap_default
	app_activate(a, app_add(a, d))
}

// Open a Settings or Font tab, or switch to it if one is already open — these
// are singletons; a second Settings tab would be nonsense.
app_open_special :: proc(a: ^App, kind: Tab_Kind) {
	for d, slot in a.docs {
		if d != nil && d.kind == kind {
			app_activate(a, slot)
			return
		}
	}
	// A bare doc_new(): no content, no path, and nothing ever writes to it. Menu
	// rows lean on that -- Edit > Select All stays live on a pseudo-tab and is
	// harmless only because selecting an empty buffer produces no selection (see
	// menu.odin). Anything that gives this Document content breaks that, which is
	// why command_allowed_on refuses the writers outright rather than trusting it.
	d := new(Document)
	d^ = doc_new()
	d.kind = kind
	app_activate(a, app_add(a, d))
}

// Apply the remembered per-family view to a newly opened document. Fresh opens
// only: session restore carries its own per-tab view state (session_restore
// builds its Documents directly via doc_open/doc_from_content and never calls
// this), and overriding that would silently change a view the user had
// deliberately left set on that specific file. The existing doc_can_* gating
// still applies, so a stored default can never force a view onto a file that
// cannot hold it -- a stray md_default cannot wedge a .txt into Split.
//
// Through doc_view_apply, not by writing doc.md_mode/doc.table here: this is the
// third caller that puts a view onto a Document, and open-coding the doc_can_*
// gates a second time is precisely the shape batch 6 exists to remove. It also
// silently omitted two of doc_view_apply's rules -- the markdown/grid mutual
// exclusion, and the top re-anchor -- which were inert only because the family
// defaults key on disjoint extensions and a fresh open has top == 0.
//
// `wrap` is NOT a family default; it comes from settings.wrap_default at open
// time (app_open_path/app_new_scratch) or from a restored session, so the
// document's current value is passed straight back through. table_delim is left
// 0 on purpose: doc_view_apply then chooses one, which the open-coded version
// never did -- a defaulted grid used to fall back to ',' with nothing recorded.
app_apply_view_defaults :: proc(a: ^App, doc: ^Document) {
	if doc == nil || doc.kind != .Text {return}
	doc_view_apply(doc, Doc_View{wrap = doc.wrap, md_mode = a.settings.md_default, table = a.settings.table_default})
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
	app_apply_view_defaults(a, d) // fresh open -- see the proc's own comment
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
	// First: the update worker writes into `a.update` and must not still be
	// running when this App's storage goes. Blocks for at most one WinHTTP
	// timeout — see update_stop.
	update_stop(&a.update)
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
	delete(a.notice)
}

// The document's display name: file base name, or "untitled" for a scratch.
doc_display_name :: proc(d: ^Document) -> string {
	if d.path != "" {
		return filepath.base(d.path)
	}
	return "untitled"
}

// The tab label proper. The dirty marker used to be a "*" prepended HERE,
// which is exactly what UI spec 4.2 says not to do: it moves the point at which
// a long name truncates the moment a file becomes modified. It is now a mark the
// layout reserves room for on every tab (ui_tabs.odin).
tab_title :: proc(d: ^Document, allocator := context.temp_allocator) -> string {
	#partial switch d.kind {
	case .Settings:
		return strings.clone("Settings", allocator)
	case .Font:
		return strings.clone("Font", allocator)
	}
	return strings.clone(doc_display_name(d), allocator)
}

// Two open tabs called `notes.md` are indistinguishable, and the filename is the
// only thing a tab shows. When a name repeats, both get their parent folder --
// BOTH, not just the later one, because disambiguating only the duplicate leaves
// the first tab looking like the canonical one.
//
// Compared on the display name rather than the path: two files with the same
// name in the same folder cannot happen, and two untitled buffers are both
// "Untitled" with no folder to tell them apart, so they are left alone rather
// than given a misleading suffix.
tab_name_ambiguous :: proc(a: ^App, d: ^Document) -> bool {
	if d == nil || d.kind != .Text || d.path == "" {return false}
	mine := doc_display_name(d)
	for o in a.docs {
		if o == nil || o == d || o.kind != .Text || o.path == "" {continue}
		if doc_display_name(o) == mine {return true}
	}
	return false
}

// The tab's label: the filename, plus its parent folder when that filename is
// open twice. The dirty marker is NOT here -- it lives in a reserved slot the
// layout keeps on every tab, so a file becoming modified never moves the point
// at which the label truncates (UI spec 4.2).
tab_label :: proc(a: ^App, d: ^Document, allocator := context.temp_allocator) -> string {
	name := tab_title(d, allocator)
	if !tab_name_ambiguous(a, d) {return name}
	parent := filepath.base(filepath.dir(d.path))
	if parent == "" || parent == "." {return name}
	return strings.concatenate({parent, "/", name}, allocator)
}
