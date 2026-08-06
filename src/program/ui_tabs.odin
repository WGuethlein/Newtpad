// Layer: program — the custom title bar: [☰ menu] [tabs] [+]  ...drag...  [_ ▢ ✕].
// The OS frame is removed (see window.odin); this strip IS the title bar. Menu,
// tabs and + are client hit-tested here; the window buttons are non-client (the
// platform handles their clicks) — we only draw them. Hover uses the live cursor
// position since the window buttons don't get client mouse messages.
package main

import "core:fmt"
import "core:strings"
import plat "src:platform"

// 96-DPI design values; the live ones below are scaled per window DPI.
TAB_W_96 :: f32(160) // the width a tab wants before its label is measured
// UI spec 2.1. A tab sizes to its label between these, so short names stop
// wasting rail and long ones stay readable. The floor is a real floor: 5 says
// not to shrink below it because "a tab with two visible characters is worse
// than a scroll".
TAB_MIN_W_96 :: f32(132)
TAB_MAX_W_96 :: f32(220)
// Reserved on EVERY tab, occupied only when the document is modified. The point
// is that it is reserved: a file becoming dirty must not move the label or its
// truncation point.
//
// 12, not 8: at 8 the '*' filled the slot edge to edge and butted against the
// name -- `*version.odin` in Wyatt's screenshot. Widening the SLOT rather than
// moving the marker keeps the stability property the slot exists for, and
// tab_natural_w picks the new width up for free since it already sums this.
TAB_DIRTY_W_96 :: f32(12)
TAB_PAD_L_96 :: f32(4) // before the dirty slot; was 4 + 8 = the spec's 12 to the text, now 4 + 12 = 16 since the slot widened
TAB_PAD_R_96 :: f32(9)
// The pill itself, inside the 40px rail. UI spec 2.1: "tab height / radius
// 30 / 6", and the rail is 40 -- so the pill is INSET, not flush with the rail's
// bottom edge, and the 5px above and below is what makes it read as a pill
// rather than as a browser tab.
//
// It was TAB_STRIP_H - sx(4): 36 tall, hard against the bottom. Rounding only
// its top two corners was correct for that shape and is wrong for this one --
// something that floats is rounded on all four. Wyatt, live use: "the tabs not
// actually being pills". The radius was drawing the whole time; the SHAPE was
// the browser tab it had always been.
TAB_H_96 :: f32(30)
TAB_GAP_96 :: f32(3) // UI spec 2.1; was 1, which read as one continuous bar
TAB_CLOSE_W_96 :: f32(20) // right-edge hit zone that closes instead of switches
// Reserved between the end of the (possibly elided) label and the close zone.
// The budget used to be `r.w - TAB_CLOSE_W - sx(8)` with nothing held back for
// this at all, so a long name ran straight into the ×. Wyatt, live use: "with a
// really long name there's no pixel gap between the X and the end of the file
// name, they blend together."
TAB_LABEL_GAP_96 :: f32(4)
MENU_W_96 :: f32(44) // hamburger menu button
PLUS_W_96 :: f32(32) // new-tab button

TAB_W := TAB_W_96
TAB_H := TAB_H_96
TAB_MIN_W := TAB_MIN_W_96
TAB_MAX_W := TAB_MAX_W_96
TAB_DIRTY_W := TAB_DIRTY_W_96
TAB_PAD_L := TAB_PAD_L_96
TAB_PAD_R := TAB_PAD_R_96
TAB_GAP := TAB_GAP_96
TAB_CLOSE_W := TAB_CLOSE_W_96
TAB_LABEL_GAP := TAB_LABEL_GAP_96
MENU_W := MENU_W_96
PLUS_W := PLUS_W_96

// x where the tabs + "+" end (everything left of here in the bar is client; the
// gap between here and the window buttons is the OS drag region).
// x where the caption buttons begin. Tabs must never be drawn or hit-tested
// past this: WM_NCHITTEST checks the caption buttons FIRST, so a tab drawn
// underneath them is unreachable — and clicking where it appears to be sends
// HT_CLOSE, which exits the app.
@(private = "file")
tabs_limit :: proc(win: ^plat.Window, width: f32) -> f32 {
	return max(MENU_W, width - 3 * f32(plat.window_caption_btn_w(win)))
}

// The keyboard focus ring: 2px in Focus_Ring, 1px outside the element, matching
// its radius. UI spec 18 asks for "one implementation, everywhere… drawn as one
// SDF instance with an annular parameter" -- this is four instances rather than
// one, because the pipeline batch 12 built resolves a filled rounded box and has
// no annular term, and adding one would change every quad's shader for a shape
// used by a handful of widgets. Four edge quads is the cheaper honest version;
// swap it for an annulus if the ring ever needs a radius that reads.
//
// Drawn OUTSIDE the element (spec's 1px offset), so it never eats into the
// element's own content box and cannot shift what is inside it.
// `bound_lo`/`bound_hi` clamp the ring vertically to the surface it sits in.
//
// It is drawn OUTSIDE the element, so an element flush against its container's
// edge pushes the ring past it -- which is exactly what shipped in v0.22.0: the
// tab was 36 tall starting 4px down a 40px rail, so the ring's bottom edge
// landed at y=43 and drew a bar across the menu bar below. Wyatt saw it and
// took it for a highlighting bug, which is a fair reading of an accent line
// appearing where nothing was focused.
focus_ring_draw :: proc(gfx: ^plat.Gfx, qp: ^plat.Quad_Pipeline, x, y, w, h, radius: f32, bound_lo: f32 = 0, bound_hi: f32 = 1e9) {
	t := max(1, sx(2)) // 2px, and never scaled away
	o := hairline() // the 1px offset
	col := g_theme[.Focus_Ring]
	rx, ry := x - o - t, y - o - t
	rw, rh := w + 2 * (o + t), h + 2 * (o + t)
	if ry < bound_lo {
		rh -= bound_lo - ry
		ry = bound_lo
	}
	if ry + rh > bound_hi {rh = bound_hi - ry}
	if rh <= 2 * t {return} // nothing left to ring
	plat.quads_draw(
		gfx,
		qp,
		[]plat.Quad {
			{pos = {rx, ry}, size = {rw, t}, color = col, radius = {radius, radius, 0, 0}},
			{pos = {rx, ry + rh - t}, size = {rw, t}, color = col, radius = {0, 0, radius, radius}},
			{pos = {rx, ry + t}, size = {t, rh - 2 * t}, color = col},
			{pos = {rx + rw - t, ry + t}, size = {t, rh - 2 * t}, color = col},
		},
	)
}

// --- one layout for the tab rail ---
//
// CLAUDE.md: "A widget's geometry is produced by exactly one *_layout()
// procedure, consumed by the draw AND the hit-test AND the hover AND the
// cursor." The rail had FIVE walkers instead -- tabs_hidden_count, its own
// second pass, tabs_hit_test, tabs_drag_update and tabs_draw -- each starting
// from `MENU_W - app.tab_scroll` and stepping by TAB_W.
//
// They agreed, because the width is a constant. tabs_drag_update shows what
// that was worth: it recovers a tab index with `int(rel / (TAB_W + TAB_GAP))`,
// which is only meaningful while every tab is the same size. Variable width
// (batch 13's next task) breaks that division and the four other walkers at
// once, which is why this lands first and changes nothing.
//
// Produced fresh per call rather than cached: it is a handful of arithmetic per
// tab, the frame already rebuilds far more than this, and a cache would need
// invalidating on open, close, reorder, rename, resize, DPI change and scroll --
// six chances to be stale in exchange for nothing measurable.
Tab_Rect :: struct {
	slot:     int, // index into app.docs
	x, w:     f32,
	close_x:  f32, // left edge of the close hit zone, TAB_CLOSE_W wide
	drawn:    bool, // fits inside the strip; a tab that is not drawn is not clickable
}

Tabs_Layout :: struct {
	tabs:     []Tab_Rect, // live documents only, in display order
	hidden:   int, // live tabs the strip had no room for
	limit:    f32, // right edge tabs may occupy (caption buttons excluded)
	plus_x:   f32,
	plus_on:  bool,
	over_x:   f32, // the "+N" overflow indicator
	over_w:   f32,
	over_on:  bool,
}

// The rail's geometry. `width` is the client width.
// A tab's natural width: everything it must show, clamped to the spec's range.
// Reserved-not-conditional on the dirty slot and the close zone -- both occupy
// room whether or not they are currently drawn, so neither appearing nor
// disappearing moves the label.
tab_natural_w :: proc(app: ^App, d: ^Document, t: ^plat.Text) -> f32 {
	label := tab_label(app, d)
	text_w := f32(plat.text_cells(t, transmute([]u8)label, 0)) * plat.text_char_width(t, UI_SMALL_PX)
	want := TAB_PAD_L + TAB_DIRTY_W + text_w + TAB_CLOSE_W + TAB_PAD_R
	return clamp(want, TAB_MIN_W, TAB_MAX_W)
}

// The label's cell budget: the pill's width less everything reserved around it.
//
// Derived from the SAME constants the draw places the label with. It used to be
// `r.w - TAB_CLOSE_W - sx(8)`, hand-copied and wrong twice over: the label
// starts at TAB_PAD_L + TAB_DIRTY_W (12 at 96 DPI), not 8, and nothing was
// reserved between the label and the close zone at all -- so a long name ran
// straight into the ×. Wyatt: "with a really long name there's no pixel gap
// between the X and the end of the file name, they blend together."
tab_label_cells :: proc(tab_w, char_w: f32) -> int {
	return max(1, int((tab_w - TAB_PAD_L - TAB_DIRTY_W - TAB_CLOSE_W - TAB_LABEL_GAP) / char_w))
}

tabs_layout :: proc(app: ^App, win: ^plat.Window, t: ^plat.Text, width: f32, allocator := context.temp_allocator) -> (L: Tabs_Layout) {
	L.limit = tabs_limit(win, width)
	n := 0
	for d in app.docs {
		if d != nil {n += 1}
	}
	rects := make([]Tab_Rect, n, allocator)

	// Two passes, exactly as tabs_hidden_count did and for the reason its own
	// comment gives: reserving the indicator's width can itself push a tab out,
	// so the count has to be recomputed with that reservation in place or it
	// comes out one too low. The first pass only answers "does anything
	// overflow at all".
	// Natural widths first, then one fitting pass. UI spec 5: tabs shrink toward
	// the 132 floor BEFORE the rail scrolls, so a few extra tabs cost width
	// rather than reachability -- but never below the floor, because a tab with
	// two visible characters is worse than a scroll.
	nat := make([]f32, n, allocator)
	{
		i, total := 0, f32(0)
		for d in app.docs {
			if d == nil {continue}
			nat[i] = tab_natural_w(app, d, t)
			total += nat[i] + TAB_GAP
			i += 1
		}
		avail := L.limit - MENU_W - PLUS_W
		if n > 0 && total > avail && avail > 0 {
			// Take the overshoot off the widest tabs first: shrinking a 220 down
			// to 160 costs nothing a reader notices, while shrinking a name that
			// already fits in 132 costs the whole name.
			for pass in 0 ..< 8 {
				total = 0
				for w in nat {total += w + TAB_GAP}
				if total <= avail {break}
				over := total - avail
				widest := f32(0)
				count := 0
				for w in nat {
					if w > TAB_MIN_W + 0.5 {
						count += 1
						if w > widest {widest = w}
					}
				}
				if count == 0 {break} // everything is already at the floor
				step := max(1, over / f32(count))
				for &w in nat {
					if w > TAB_MIN_W {w = max(TAB_MIN_W, w - step)}
				}
			}
		}
	}

	// Every tab gets its true position; whether it is DRAWN is a separate
	// question. It used to stop advancing x at the first tab that did not fit,
	// so every overflowing tab shared one position -- which made the strip's
	// total width unknowable and any scroll offset computed from it nonsense.
	// That is invisible while the rail never scrolls, which it never did.
	place :: proc(app: ^App, rects: []Tab_Rect, nat: []f32, limit, scroll: f32) -> (drawn: int) {
		x := MENU_W - scroll
		i := 0
		for d, slot in app.docs {
			if d == nil {continue}
			w := nat[i]
			// Fully inside the strip. Partially-visible tabs are not drawn: a tab
			// clipped by the caption buttons is one whose click sends HT_CLOSE,
			// and one clipped at the left shows a truncated name with no marker.
			fits := x >= MENU_W - 0.5 && x + w <= limit
			rects[i] = {slot = slot, x = x, w = w, close_x = x + w - TAB_CLOSE_W, drawn = fits}
			if fits {drawn += 1}
			x += w + TAB_GAP
			i += 1
		}
		return
	}
	drawn := place(app, rects, nat, L.limit, app.tab_scroll)
	if drawn < n {
		L.over_w = sx(52)
		L.over_x = L.limit - L.over_w
		L.over_on = true
		drawn = place(app, rects, nat, L.limit - L.over_w, app.tab_scroll)
	}
	L.tabs = rects
	L.hidden = n - drawn

	// The + button sits after the last DRAWN tab, and only when it fits inside
	// the same limit the tabs respect.
	px := MENU_W - app.tab_scroll
	for r in rects {
		if r.drawn {px = r.x + r.w + TAB_GAP}
	}
	lim := L.limit - (L.over_w if L.over_on else 0)
	L.plus_x, L.plus_on = px, px + PLUS_W <= lim
	return
}

// Elide a label to `cells`, keeping BOTH ends.
//
// The tail is what identifies a file -- the extension, and whatever suffix
// distinguishes it from its neighbours -- so an end-elided run of tabs can show
// nothing but a shared prefix. Splits the budget with the larger half at the
// front, since the front carries the name and the back carries the type.
tab_elide :: proc(t: ^plat.Text, label: string, cells: int, allocator := context.temp_allocator) -> string {
	b := transmute([]u8)label
	if cells <= 1 || plat.text_cells(t, b, 0) <= cells {return label}
	keep := cells - 1 // one cell for the ellipsis
	if keep < 2 {return "…"}
	head := (keep + 1) / 2
	tail := keep - head
	hb := plat.text_bytes_for_cells(t, b, head, 0)
	// Walk back from the end for the tail: bytes_for_cells measures forward from
	// a start, so the tail's start is found by asking for everything but it.
	tb := plat.text_bytes_for_cells(t, b, plat.text_cells(t, b, 0) - tail, 0)
	if tb < hb {return label}
	return strings.concatenate({label[:hb], "…", label[tb:]}, allocator)
}

// Scroll the rail so the active tab is on screen.
//
// app.tab_scroll was declared, read in four places, and NEVER WRITTEN -- so it
// was always zero and the rail never scrolled. With more tabs than fit, Ctrl+Tab
// could land on a tab that is simply not drawn: the overflow count said "+3" and
// the only way to reach one of them was the palette. Switching to a tab you
// cannot see is the worst version of that, because nothing on screen changes
// except the document.
//
// Measured from the UNSCROLLED layout, so the answer does not depend on where
// the rail happens to be sitting -- otherwise each call nudges the previous
// call's result and the strip creeps.
tabs_reveal_active :: proc(app: ^App, win: ^plat.Window, t: ^plat.Text, width: f32) {
	if app.active < 0 {return}
	saved := app.tab_scroll
	app.tab_scroll = 0
	L := tabs_layout(app, win, t, width)
	app.tab_scroll = saved

	ax, aw := f32(0), f32(0)
	total := MENU_W
	found := false
	for r in L.tabs {
		if r.slot == app.active {
			ax, aw, found = r.x, r.w, true
		}
		total = r.x + r.w
	}
	if !found {return}

	span := L.limit - (L.over_w if L.over_on else 0)
	// Nothing to scroll when everything fits; leaving a stale offset would push
	// the strip off its own left edge.
	if total <= span {
		app.tab_scroll = 0
		return
	}
	sc := app.tab_scroll
	if ax - sc < MENU_W {sc = ax - MENU_W} // off the left
	if ax + aw - sc > span {sc = ax + aw - span} // off the right
	app.tab_scroll = clamp(sc, 0, max(0, total - span))
}

// The display index a pointer x falls on, for the reorder. Asks the layout
// rather than dividing by a uniform width -- which is the whole reason the
// layout exists.
tabs_index_at :: proc(L: Tabs_Layout, mx: f32) -> int {
	if len(L.tabs) == 0 {return 0}
	for r, i in L.tabs {
		if mx < r.x + r.w {return i}
	}
	return len(L.tabs) - 1
}

// Tabs that don't fit. Drawn as a count rather than silently dropped — with no
// indicator there was nothing to say the other tabs existed at all.
tabs_hidden_count :: proc(app: ^App, win: ^plat.Window, t: ^plat.Text, width: f32) -> int {
	return tabs_layout(app, win, t, width).hidden
}

// NOT file-private: tabseamtest asserts what this returns against the layout the
// rail draws, because the two disagreeing is invisible from inside either one.
tabs_right :: proc(app: ^App, win: ^plat.Window, t: ^plat.Text, width: f32) -> f32 {
	// The sixth walker, and the least obvious: it feeds win.tabs_right, which
	// WM_NCHITTEST uses to decide where dragging the WINDOW is allowed. It also
	// ignored tab_scroll, so it was already approximate; with variable widths it
	// would be wrong outright, and being wrong here means either a dead strip of
	// rail or a tab you cannot click because the OS took the press as a drag.
	L := tabs_layout(app, win, t, width)
	right := MENU_W
	for r in L.tabs {
		if r.drawn {right = r.x + r.w + TAB_GAP}
	}
	if L.plus_on {right = L.plus_x + PLUS_W}
	// The "+N" overflow count, which this walk missed entirely until 2026-08-05.
	//
	// It is the RIGHTMOST control on the rail and it is the one this proc must
	// stretch to reach, because when it exists the tabs and the + button are both
	// placed inside `limit - over_w` -- so every other term above lands strictly
	// to its LEFT and the client region stopped short of it. Past that edge
	// WM_NCHITTEST returns HT_CAPTION, so the press became an OS window drag and
	// tabs_hit_test's overflow branch never ran. The count is drawn only when tabs
	// overflow, which is exactly when it was unclickable: at 320px with 3 tabs the
	// region ended at 76 while the indicator spanned 130..182.
	//
	// max, not assignment: the + button can be absent while tabs still overflow,
	// and this must never pull the boundary back to the left of something the walk
	// above already claimed. Wyatt, live use: "+N but currently it doesn't work".
	if L.over_on {right = max(right, L.over_x + L.over_w)}
	return min(right, L.limit)
}

// Handle a click on the title bar during the input phase. Returns true (and
// consumes the click) if it landed on the menu / a tab / the + button.
tabs_hit_test :: proc(app: ^App, win: ^plat.Window, t: ^plat.Text) -> bool {
	if !(win.mouse_pressed || win.mouse_middle_pressed || win.mouse_right_pressed) {return false}
	if f32(win.mouse_y) >= TAB_STRIP_H {return false}
	mx := f32(win.mouse_x)

	// RIGHT-CLICK: the tab's own context menu, handled before everything below so
	// a right press can never fall through to activate, close or start a drag.
	//
	// IT ACTIVATES THE TAB IT OPENS ON. That reverses the original decision, at
	// Wyatt's request after using it: *"if you right click a different, non-active
	// tab i think it should swap to that tab as a visual queue"*. He is right --
	// a menu whose rows say "Close Tab" and "Reveal in Explorer" while a DIFFERENT
	// tab is highlighted gives the reader nothing to bind those words to, and the
	// most likely reading is the wrong one.
	//
	// The ctx_tab targeting stays exactly as it was and is NOT now redundant: it is
	// what makes the rows correct even in the frame before the activation lands,
	// and it keeps the four commands honest about which tab they act on rather than
	// making them depend on a side effect of opening the menu.
	if win.mouse_right_pressed {
		win.mouse_right_pressed = false
		if f32(win.mouse_y) < TAB_STRIP_H && mx >= MENU_W {
			L := tabs_layout(app, win, t, f32(win.width))
			for r in L.tabs {
				if !r.drawn {continue}
				if mx >= r.x && mx < r.x + r.w {
					// BELOW THE MENU BAR, not just below the tab strip, and that is a
					// correctness requirement rather than taste. menu_hit_test claims
					// every click in the band [TAB_STRIP_H, TAB_STRIP_H + MENU_BAR_H)
					// for the menu BAR before it looks at any open dropdown -- so a
					// menu anchored at TAB_STRIP_H puts its first row inside that band,
					// and clicking that row reads as "empty bar area", closes the menu
					// and runs nothing. That is exactly what shipped: "the right click
					// on tab does not open explorer to the path" (Wyatt, v0.43.0), and
					// it was always the FIRST row that was dead.
					//
					// A right-click also ACTIVATES the tab (below), so the menu is
					// visually anchored to the tab by its x and by the tab now being
					// the highlighted one.
					app_activate(app, r.slot)
					menu_open_tab_ctx(app, r.x, r.slot)
					return true
				}
			}
		}
		// Empty strip, the menu button, or past the last tab: nothing to target.
		// Consumed anyway, so a right press up here never reaches the document.
		return true
	}

	consumed := true
	// The SAME layout tabs_draw consumes -- that is the point of it existing.
	L := tabs_layout(app, win, t, f32(win.width))
	if L.over_on && mx >= L.over_x && mx < L.over_x + L.over_w {
		// The overflow count opens the palette's tab list, which can reach any
		// tab regardless of whether the strip has room to show it.
		palette_open(app)
		win.mouse_pressed = false
		win.mouse_middle_pressed = false
		win.mouse_down = false
		return true
	}
	if mx < MENU_W {
		if MENU_BAR_SHOWN {
			palette_open(app)
			palette_input_rune(app, '>')
		} else {
			// The hamburger opens the SAME menus, not a copy of them: menu_open_at
			// is the one entry point, and the dropdown draws over the document
			// without the bar coming back (menu_draw handles that case).
			if menu_is_active(app) {menu_close(app)} else {menu_open_at(app, 0)}
		}
	} else {
		hit_slot := -1
		hit_close := false
		for r in L.tabs {
			if !r.drawn {continue} // not drawn, so not clickable
			if mx >= r.x && mx < r.x + r.w {
				hit_slot = r.slot
				hit_close = win.mouse_middle_pressed || mx >= r.close_x
			}
		}
		if hit_slot >= 0 {
			if hit_close {
				request_close_tab(app, hit_slot, win)
			} else {
				app_activate(app, hit_slot)
				// Begin a reorder: keep the button "held" so a drag can follow. A
				// plain click just activates and ends the drag on release (no swap).
				app.tab_drag = true
				app.tab_drag_slot = hit_slot
			}
		} else if L.plus_on && mx >= L.plus_x && mx < L.plus_x + PLUS_W { // + -> new tab
			app_new_scratch(app) // app_add always appends after the last live tab
		}
	}

	win.mouse_pressed = false
	win.mouse_middle_pressed = false
	if !app.tab_drag {win.mouse_down = false} // a tab drag needs the held state
	return consumed
}

// Reorder the dragged tab as the pointer moves along the strip. Called each frame
// while the drag is held. The tab bubbles past its neighbours (adjacent swaps),
// so the active/highlighted tab follows the cursor — no floating render needed.
tabs_drag_update :: proc(app: ^App, win: ^plat.Window, t: ^plat.Text) {
	if f32(win.mouse_y) < 0 {return}
	live := make([dynamic]int, 0, len(app.docs), context.temp_allocator)
	for d, s in app.docs {
		if d != nil {append(&live, s)}
	}
	di := -1
	for s, i in live {
		if s == app.tab_drag_slot {di = i;break}
	}
	if di < 0 || len(live) < 2 {return}
	// Target display index from the cursor x, ASKED of the layout the strip is
	// drawn with. It used to divide by (TAB_W + TAB_GAP), which recovers an
	// index only while every tab is the same width.
	L := tabs_layout(app, win, t, f32(win.width))
	target := clamp(tabs_index_at(L, f32(win.mouse_x)), 0, len(live) - 1)
	for di < target { // move right: swap with the next display neighbour
		app_swap_tabs(app, live[di], live[di + 1])
		app.tab_drag_slot = live[di + 1] // the dragged doc now lives in that slot
		di += 1
	}
	for di > target { // move left
		app_swap_tabs(app, live[di], live[di - 1])
		app.tab_drag_slot = live[di - 1]
		di -= 1
	}
}

// --- tearing a tab off into its own window ---------------------------------
//
// Does releasing here tear the tab off? Two ways, and the second was added after
// live use.
//
// v0.41.0 shipped with ONLY "the pointer left the window", which was the option
// chosen at scoping over "drag below the strip by a clear margin". In use it is
// the wrong one: *"if you drag the tab into the viewport it doesn't open a new
// tab"* (Wyatt, v0.43.0). Dragging a tab down into the document is what every
// browser treats as a tear-off, and on a maximised window there is barely anywhere
// to go that IS outside. Both rules are live now -- the window one still catches a
// drag onto another monitor.
//
// On release rather than live, and that is a real difference from Chrome: a
// window cannot be created and dragged mid-gesture here, so the tab stays in the
// strip until the button comes up. Dropping it back on the strip is therefore an
// ordinary reorder, which is the whole of the "changed my mind" story.
//
// The client-coordinate test survives mouse CAPTURE, which is what makes it work
// at all: SetCapture on mouse-down (platform/window.odin) keeps WM_MOUSEMOVE
// arriving after the pointer leaves, and a point outside reads as negative or as
// past the edge. Both are caught here.
tabs_drag_outside :: proc(win: ^plat.Window) -> bool {
	if win == nil || win.hwnd == nil {return false} // headless: no window to leave
	return tabs_pointer_detaches(win.mouse_x, win.mouse_y, win.width, win.height)
}

// How far below the strip the pointer must go before a drag means "tear off"
// rather than "reorder". One tab's height: far enough that an ordinary sloppy
// reorder cannot reach it -- the strip is 40px and a drag wanders a few pixels --
// and near enough that dragging into the document obviously qualifies.
TAB_TEAR_DROP_96 :: TAB_H_96

// The geometry, split out so a test can reach it: tabs_drag_outside needs a real
// hwnd (a headless Window has no client area to leave and must never report that
// the pointer left it), and the arithmetic is the part worth pinning.
//
// Half-open on the window edges, matching every other hit-test in the tree: the
// pixel at `width` is the first one outside.
tabs_pointer_detaches :: proc(mx, my, w, h: i32) -> bool {
	if mx < 0 || my < 0 || mx >= w || my >= h {return true} // left the window
	return f32(my) > TAB_STRIP_H + sx(TAB_TEAR_DROP_96) // dropped into the document
}

// May this tab be torn off? ANY TAB, dirty or untitled, with one exception.
//
// It was saved-and-unmodified-only when the tear-off shipped in v0.40.0, on the
// reasoning that a torn-off window is a second process and therefore not the
// primary instance, so handing it unsaved work would move that work somewhere with
// no crash protection. Wyatt, from live use: *"i can only drag tabs that don't have
// edits, you should be able to drag all tabs."* He is right, and the restriction
// was solving the problem the wrong way round -- the answer is to give the new
// window a backup store of its own (session_dir), not to refuse the gesture.
// Unsaved bytes now travel with the tab (handover_write).
//
// THE ONE EXCEPTION is a dirty buffer past BACKUP_MAX. The handover is a full
// in-memory copy plus a full write on the main thread, which is the same operation
// session_save already refuses at that size for a measured reason: at multi-GB it
// is a multi-second freeze and a real OOM risk. Such a buffer is already excluded
// from crash backups and the status bar already says so; this is the same limit
// reached by the same argument, not a new one.
tab_can_detach :: proc(doc: ^Document) -> bool {
	if doc == nil {return false}
	// An empty untitled scratch is not a document anybody means to move, and
	// session_save skips it for the same reason.
	if doc.path == "" && !doc.modified && doc.pt.length == 0 {return false}
	if doc.modified && doc.pt.length > BACKUP_MAX {return false}
	return true
}

// Open the dragged tab in a window of its own and close it here.
//
// ORDER IS LOAD-BEARING: the process is spawned FIRST and the tab is closed only
// if that succeeded. A close-then-spawn would lose the tab outright whenever
// CreateProcessW failed -- a locked exe, a policy block, an exhausted desktop heap
// -- and the tab is the only record of where the user was in that file.
//
// Returns false when nothing happened, so the caller can leave the drag alone.
tab_detach :: proc(app: ^App, win: ^plat.Window) -> bool {
	if app == nil || win == nil {return false}
	slot := app.tab_drag_slot
	if slot < 0 || slot >= len(app.docs) {return false}
	doc := app.docs[slot]
	if !tab_can_detach(doc) {return false}
	// THE ONLY TAB GOES NOWHERE. Tearing it off spawns a second window holding
	// this document and then closes the only tab here -- which, because a window
	// never fails to a closed state, leaves a fresh empty scratch behind. Two
	// windows where there was one, and the original now blank: *"when you also only
	// have one tab open and you drag it it spawns a new instance... this shouldn't
	// be the case"* (Wyatt, v0.41.0). Every browser treats dragging a window's only
	// tab as moving the window, which is to say as nothing.
	//
	// Asked here rather than in tab_can_detach because it is a question about the
	// STRIP, not about the document -- and it has to be asked BEFORE the spawn,
	// alongside the other refusals, so the "spawn before you close" ordering is
	// undisturbed.
	if app_live_count(app) <= 1 {return false}

	// At the pointer, sized like the window it came from -- so the new window
	// appears where the tab was dropped rather than wherever the shell would have
	// put it. Screen pixels, from the cursor directly: by now the point is outside
	// this window, where its own client-space answer is a negative number.
	sx, sy := plat.cursor_screen()
	exe := plat.exe_path()
	if exe == "" {return false}

	// THE WHOLE DOCUMENT TRAVELS, not just its path: the tab may be dirty, or
	// untitled and have no path at all. Written before the spawn so a failure here
	// leaves the tab untouched -- same ordering argument as the spawn itself.
	hpath := handover_path()
	if hpath == "" || !handover_write(doc, hpath) {return false}

	args := []string {
		"--detach",
		fmt.tprintf("%d", sx),
		fmt.tprintf("%d", sy),
		fmt.tprintf("%d", win.width),
		fmt.tprintf("%d", win.height),
		hpath,
	}
	if !plat.process_spawn(exe, args) {
		// The child never started, so nothing will ever read the handover. Delete
		// it rather than leaving a full copy of the buffer lying in the session
		// directory for a reader that does not exist.
		plat.file_delete(hpath)
		return false
	}
	// Closed directly rather than through request_close_tab: that path exists to
	// ASK about unsaved work, and tab_can_detach has already established there is
	// none. Going through it would put a dialog in the middle of a drag.
	app_close(app, slot)
	return true
}

@(private = "file")
Caption_Kind :: enum {
	Minimise,
	Maximise,
	Close,
}

caption_btn :: proc(gfx: ^plat.Gfx, qp: ^plat.Quad_Pipeline, text: ^plat.Text, x, w: f32, kind: Caption_Kind, hovered, is_close: bool, restored := false) {
	if hovered {
		col := g_theme[.Danger] if is_close else g_theme[.Border_Strong]
		plat.quads_draw(gfx, qp, []plat.Quad{{pos = {x, 0}, size = {w, TAB_STRIP_H}, color = col}})
	}
	fg := g_theme[.Text_Bright] if (hovered && is_close) else g_theme[.Text_Secondary]
	// Drawn as geometry, not as a glyph.
	//
	// These were text -- "–", "❐", "▢" -- which made them depend on the chrome
	// font carrying them. Batch 12 moved chrome onto Cascadia Mono, so they had
	// become one font substitution away from wrong, and a glyph cannot follow the
	// caption sizing UI spec 2.1 gives. Strokes scale with DPI for the reason
	// spec 3 item 5 states: a 1px stroke inside a 15px box at 150% looks broken.
	box := sx(10)
	st := max(1, sx(1) * max(1, f32(int(UI_SCALE)))) // 1px at 100%, 2px at 150%+
	cx0 := x + (w - box) * 0.5
	cy0 := TAB_STRIP_H * 0.5 - box * 0.5
	switch kind {
	case .Minimise:
		plat.quads_draw(gfx, qp, []plat.Quad{{pos = {cx0, cy0 + box * 0.5 - st * 0.5}, size = {box, st}, color = fg}})
	case .Maximise:
		// Four edges, so the middle stays the window behind it rather than a
		// filled block. Restore draws the same square offset, with a second
		// square behind it -- the standard pair, and the only place the two
		// states differ.
		e := []plat.Quad {
			{pos = {cx0, cy0}, size = {box, st}, color = fg},
			{pos = {cx0, cy0 + box - st}, size = {box, st}, color = fg},
			{pos = {cx0, cy0}, size = {st, box}, color = fg},
			{pos = {cx0 + box - st, cy0}, size = {st, box}, color = fg},
		}
		plat.quads_draw(gfx, qp, e)
		if restored {
			o := box * 0.28
			plat.quads_draw(
				gfx,
				qp,
				[]plat.Quad {
					{pos = {cx0 + o, cy0 - o}, size = {box - o, st}, color = fg},
					{pos = {cx0 + box, cy0 - o}, size = {st, box - o}, color = fg},
				},
			)
		}
	case .Close:
		// Two diagonals cannot be axis-aligned quads, so the X is drawn as a
		// short stack of stepped segments -- at 10px the step is under a pixel
		// and reads as a line. Cheaper than adding a rotated-quad path to the
		// pipeline for one glyph.
		steps := int(box)
		for i in 0 ..< steps {
			f := f32(i)
			plat.quads_draw(
				gfx,
				qp,
				[]plat.Quad {
					{pos = {cx0 + f, cy0 + f}, size = {st, st}, color = fg},
					{pos = {cx0 + box - st - f, cy0 + f}, size = {st, st}, color = fg},
				},
			)
		}
	}
}

tabs_draw :: proc(gfx: ^plat.Gfx, quad_pipe: ^plat.Quad_Pipeline, text: ^plat.Text, app: ^App, win: ^plat.Window, width: f32) {
	win.titlebar_h = i32(TAB_STRIP_H)
	char_w := plat.text_char_width(text, UI_SMALL_PX)
	win.tabs_right = i32(tabs_right(app, win, text, width))

	cx, cy := plat.window_cursor_client(win)
	in_bar := f32(cy) >= 0 && f32(cy) < TAB_STRIP_H
	base_y := TAB_STRIP_H - sx(12)

	plat.quads_draw(gfx, quad_pipe, []plat.Quad{{pos = {0, 0}, size = {width, TAB_STRIP_H}, color = g_theme[.Bg_Base]}})

	// menu button
	if in_bar && f32(cx) < MENU_W {
		plat.quads_draw(gfx, quad_pipe, []plat.Quad{{pos = {0, 0}, size = {MENU_W, TAB_STRIP_H}, color = g_theme[.Border_Strong]}})
	}
	// ">_", not a magnifier. UI spec 7.1: the magnifier-in-a-rounded-fill shape
	// reads as "search your files", which is the wrong promise -- this opens the
	// COMMAND palette. Showing the same prompt the palette itself shows makes the
	// button and the thing it opens look like each other.
	//
	// It becomes a hamburger while the menu bar is hidden (UI spec 11: "☰ opens
	// the same menus"). ONE slot, not two: Wyatt's call, on the grounds that a
	// second permanent button spends tab width to duplicate a route Ctrl+P still
	// has. The glyph names whichever route is currently NOT otherwise reachable.
	glyph := ">_" if MENU_BAR_SHOWN else "☰"
	gw := plat.text_char_width(text, UI_PX) * f32(1 if !MENU_BAR_SHOWN else 2)
	plat.text_draw(gfx, text, glyph, MENU_W / 2 - gw * 0.5, base_y, UI_PX, g_theme[.Text_Secondary])

	// tabs
	// Nothing past `limit` may be drawn: the caption buttons are non-client and
	// WM_NCHITTEST claims that region first, so a tab drawn under them looks
	// clickable but sends HT_CLOSE — one click and the app exits.
	L := tabs_layout(app, win, text, width)
	for r in L.tabs {
		if !r.drawn {continue} // overflow; the count is drawn below
		d := app.docs[r.slot]
		x, slot := r.x, r.slot
		max_cells := tab_label_cells(r.w, char_w)
		active := slot == app.active
		// A pill: rounded on top, square along the bottom where it meets the
		// content. One quad with two corner radii -- the shape batch 12's SDF
		// pipeline was built for, and its first consumer.
		fill := g_theme[.Bg_Raised] if active else (g_theme[.Bg_Hover] if (in_bar && f32(cx) >= r.x && f32(cx) < r.x + r.w) else g_theme[.Bg_Panel])
		// The pill's own vertical centre, and the label's baseline derived from
		// it. base_y is measured from the RAIL's bottom edge, which was the same
		// thing while the tab was flush with it and is not now -- using it here
		// would sit the label low in the pill by exactly the inset.
		ty := (TAB_STRIP_H - TAB_H) * 0.5
		tab_base_y := ty + TAB_H * 0.5 + UI_SMALL_PX * 0.35
		plat.quads_draw(gfx, quad_pipe, []plat.Quad{{pos = {x, ty}, size = {r.w, TAB_H}, color = fill, radius = {RADIUS_TAB, RADIUS_TAB, RADIUS_TAB, RADIUS_TAB}}})
		if active && app.kbd_tab_focus {
			focus_ring_draw(gfx, quad_pipe, x, ty, r.w, TAB_H, RADIUS_TAB, 0, TAB_STRIP_H)
		}

		title := tab_label(app, d, context.temp_allocator)
		// Elide the MIDDLE, not the end. `2026-07-27-batch-11-sync.md` truncated
		// at the end becomes `2026-07-27-batch-…`, which loses the extension --
		// the part that says what the file IS -- and leaves a run of tabs whose
		// visible halves are identical. Keeping the tail keeps the extension and
		// whatever distinguishes the name (UI spec 4.2).
		title = tab_elide(text, title, max_cells, context.temp_allocator)
		// Text_Secondary for the inactive label, NOT Text_Dim. Text_Dim is the
		// disabled-only tier -- 2.9:1 in Dark, 2.8:1 in Light, below the AA floor
		// by design, and theme.odin labels it "DISABLED ONLY -- never live text".
		// An inactive tab is not disabled: it is a document you can click, and it
		// carries the filename you are looking for. Reported by Wyatt as chrome
		// text being hard to read in both themes; it measured as exactly that.
		fg := g_theme[.Text_Primary] if active else g_theme[.Text_Secondary]
		// The dirty marker, in the slot the layout reserved on every tab. Accent
		// AND a glyph, not colour alone -- UI spec 18, 1.4.1.
		if d.modified {
			plat.text_draw(gfx, text, "*", x + TAB_PAD_L, tab_base_y, UI_SMALL_PX, g_theme[.Accent])
		}
		plat.text_draw(gfx, text, title, x + TAB_PAD_L + TAB_DIRTY_W, tab_base_y, UI_SMALL_PX, fg)
		// The close button shows on the ACTIVE tab and on hover only, so a row of
		// idle tabs is quiet (UI spec 4.2). Middle-click still closes any tab --
		// that path is in the hit-test and does not depend on the glyph.
		hot_tab := in_bar && f32(cx) >= r.x && f32(cx) < r.x + r.w
		if active || hot_tab {
			plat.text_draw(gfx, text, "×", r.close_x + (TAB_CLOSE_W - plat.text_char_width(text, UI_SMALL_PX)) * 0.5, tab_base_y, UI_SMALL_PX, g_theme[.Text_Secondary])
		}
	}

	// Overflow count, clickable to reach the hidden tabs via the palette.
	if L.over_on {
		hx := L.over_x
		hot := in_bar && f32(cx) >= hx && f32(cx) < hx + L.over_w
		if hot {
			plat.quads_draw(gfx, quad_pipe, []plat.Quad{{pos = {hx, sx(4)}, size = {L.over_w, TAB_STRIP_H - sx(4)}, color = g_theme[.Border_Subtle]}})
		}
		plat.text_draw(gfx, text, fmt.tprintf("+%d ▸", L.hidden), hx + sx(6), base_y, UI_SMALL_PX, g_theme[.Text_Secondary])
	}

	// new-tab button, only if it fits clear of the caption buttons
	if L.plus_on {
		px := L.plus_x
		if in_bar && f32(cx) >= px && f32(cx) < px + PLUS_W {
			plat.quads_draw(gfx, quad_pipe, []plat.Quad{{pos = {px, sx(4)}, size = {PLUS_W, TAB_STRIP_H - sx(4)}, color = g_theme[.Border_Subtle]}})
		}
		plat.text_draw(gfx, text, "+", px + PLUS_W / 2 - sx(4), base_y, UI_PX, g_theme[.Text_Secondary])
	}

	// window buttons (non-client; drawn here, clicks handled by the platform)
	bw := f32(plat.window_caption_btn_w(win))
	cxf, cyf := f32(cx), f32(cy)
	hov := in_bar && cxf >= width - 3 * bw
	caption_btn(gfx, quad_pipe, text, width - 3 * bw, bw, .Minimise, hov && cxf < width - 2 * bw, false)
	caption_btn(gfx, quad_pipe, text, width - 2 * bw, bw, .Maximise, hov && cxf >= width - 2 * bw && cxf < width - bw, false, win.maximized)
	caption_btn(gfx, quad_pipe, text, width - bw, bw, .Close, hov && cxf >= width - bw, true)
	_ = cyf
}
