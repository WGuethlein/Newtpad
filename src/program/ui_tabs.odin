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
TAB_W_96 :: f32(160) // fixed tab width
TAB_GAP_96 :: f32(1)
TAB_CLOSE_W_96 :: f32(20) // right-edge hit zone that closes instead of switches
MENU_W_96 :: f32(44) // hamburger menu button
PLUS_W_96 :: f32(32) // new-tab button

TAB_W := TAB_W_96
TAB_GAP := TAB_GAP_96
TAB_CLOSE_W := TAB_CLOSE_W_96
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
tabs_layout :: proc(app: ^App, win: ^plat.Window, width: f32, allocator := context.temp_allocator) -> (L: Tabs_Layout) {
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
	place :: proc(app: ^App, rects: []Tab_Rect, limit, scroll: f32) -> (drawn: int) {
		x := MENU_W - scroll
		i := 0
		for d, slot in app.docs {
			if d == nil {continue}
			w := TAB_W
			fits := x + w <= limit
			rects[i] = {slot = slot, x = x, w = w, close_x = x + w - TAB_CLOSE_W, drawn = fits}
			if fits {
				drawn += 1
				x += w + TAB_GAP
			}
			i += 1
		}
		return
	}
	drawn := place(app, rects, L.limit, app.tab_scroll)
	if drawn < n {
		L.over_w = sx(52)
		L.over_x = L.limit - L.over_w
		L.over_on = true
		drawn = place(app, rects, L.limit - L.over_w, app.tab_scroll)
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
tabs_hidden_count :: proc(app: ^App, win: ^plat.Window, width: f32) -> int {
	return tabs_layout(app, win, width).hidden
}

@(private = "file")
tabs_right :: proc(app: ^App, win: ^plat.Window, width: f32) -> f32 {
	// The sixth walker, and the least obvious: it feeds win.tabs_right, which
	// WM_NCHITTEST uses to decide where dragging the WINDOW is allowed. It also
	// ignored tab_scroll, so it was already approximate; with variable widths it
	// would be wrong outright, and being wrong here means either a dead strip of
	// rail or a tab you cannot click because the OS took the press as a drag.
	L := tabs_layout(app, win, width)
	right := MENU_W
	for r in L.tabs {
		if r.drawn {right = r.x + r.w + TAB_GAP}
	}
	if L.plus_on {right = L.plus_x + PLUS_W}
	return min(right, L.limit)
}

// Handle a click on the title bar during the input phase. Returns true (and
// consumes the click) if it landed on the menu / a tab / the + button.
tabs_hit_test :: proc(app: ^App, win: ^plat.Window) -> bool {
	if !(win.mouse_pressed || win.mouse_middle_pressed) {return false}
	if f32(win.mouse_y) >= TAB_STRIP_H {return false}
	mx := f32(win.mouse_x)

	consumed := true
	// The SAME layout tabs_draw consumes -- that is the point of it existing.
	L := tabs_layout(app, win, f32(win.width))
	if L.over_on && mx >= L.over_x && mx < L.over_x + L.over_w {
		// The overflow count opens the palette's tab list, which can reach any
		// tab regardless of whether the strip has room to show it.
		palette_open(app)
		win.mouse_pressed = false
		win.mouse_middle_pressed = false
		win.mouse_down = false
		return true
	}
	if mx < MENU_W { // menu -> command palette
		palette_open(app)
		palette_input_rune(app, '>')
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
			app_new_scratch(app, true) // always after the last tab
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
tabs_drag_update :: proc(app: ^App, win: ^plat.Window) {
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
	L := tabs_layout(app, win, f32(win.width))
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

@(private = "file")
caption_btn :: proc(gfx: ^plat.Gfx, qp: ^plat.Quad_Pipeline, text: ^plat.Text, x, w: f32, glyph: string, hovered, is_close: bool) {
	if hovered {
		col := g_theme[.Danger] if is_close else g_theme[.Border_Strong]
		plat.quads_draw(gfx, qp, []plat.Quad{{pos = {x, 0}, size = {w, TAB_STRIP_H}, color = col}})
	}
	fg := g_theme[.Text_Bright] if (hovered && is_close) else g_theme[.Text_Secondary]
	cw := plat.text_char_width(text, UI_PX)
	plat.text_draw(gfx, text, glyph, x + (w - cw) / 2, TAB_STRIP_H * 0.5 + sx(5), UI_PX, fg)
}

tabs_draw :: proc(gfx: ^plat.Gfx, quad_pipe: ^plat.Quad_Pipeline, text: ^plat.Text, app: ^App, win: ^plat.Window, width: f32) {
	win.titlebar_h = i32(TAB_STRIP_H)
	char_w := plat.text_char_width(text, UI_SMALL_PX)
	win.tabs_right = i32(tabs_right(app, win, width))

	cx, cy := plat.window_cursor_client(win)
	in_bar := f32(cy) >= 0 && f32(cy) < TAB_STRIP_H
	base_y := TAB_STRIP_H - sx(12)

	plat.quads_draw(gfx, quad_pipe, []plat.Quad{{pos = {0, 0}, size = {width, TAB_STRIP_H}, color = g_theme[.Bg_Base]}})

	// menu button
	if in_bar && f32(cx) < MENU_W {
		plat.quads_draw(gfx, quad_pipe, []plat.Quad{{pos = {0, 0}, size = {MENU_W, TAB_STRIP_H}, color = g_theme[.Border_Strong]}})
	}
	plat.text_draw(gfx, text, "☰", MENU_W / 2 - sx(8), base_y, UI_PX, g_theme[.Text_Secondary])

	// tabs
	// Nothing past `limit` may be drawn: the caption buttons are non-client and
	// WM_NCHITTEST claims that region first, so a tab drawn under them looks
	// clickable but sends HT_CLOSE — one click and the app exits.
	L := tabs_layout(app, win, width)
	for r in L.tabs {
		if !r.drawn {continue} // overflow; the count is drawn below
		d := app.docs[r.slot]
		x, slot := r.x, r.slot
		max_cells := int((r.w - TAB_CLOSE_W - sx(8)) / char_w)
		active := slot == app.active
		plat.quads_draw(gfx, quad_pipe, []plat.Quad{{pos = {x, sx(4)}, size = {r.w, TAB_STRIP_H - sx(4)}, color = g_theme[.Border_Subtle] if active else g_theme[.Bg_Panel]}})

		title := tab_title(d, context.temp_allocator)
		tb := transmute([]u8)title
		// Both col0 = 0: a tab title is a whole label drawn from its own x, and
		// these two are the measure/inverse pair for that one label.
		if plat.text_cells(text, tb, 0) > max_cells && max_cells > 1 {
			cut := plat.text_bytes_for_cells(text, tb, max_cells - 1, 0)
			title = strings.concatenate({title[:cut], "…"}, context.temp_allocator)
		}
		// Text_Secondary for the inactive label, NOT Text_Dim. Text_Dim is the
		// disabled-only tier -- 2.9:1 in Dark, 2.8:1 in Light, below the AA floor
		// by design, and theme.odin labels it "DISABLED ONLY -- never live text".
		// An inactive tab is not disabled: it is a document you can click, and it
		// carries the filename you are looking for. Reported by Wyatt as chrome
		// text being hard to read in both themes; it measured as exactly that.
		fg := g_theme[.Text_Primary] if active else g_theme[.Text_Secondary]
		plat.text_draw(gfx, text, title, x + sx(8), base_y, UI_SMALL_PX, fg)
		plat.text_draw(gfx, text, "×", x + r.w - sx(15), base_y, UI_SMALL_PX, g_theme[.Text_Secondary])
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
	caption_btn(gfx, quad_pipe, text, width - 3 * bw, bw, "–", hov && cxf < width - 2 * bw, false)
	caption_btn(gfx, quad_pipe, text, width - 2 * bw, bw, "❐" if win.maximized else "▢", hov && cxf >= width - 2 * bw && cxf < width - bw, false)
	caption_btn(gfx, quad_pipe, text, width - bw, bw, "✕", hov && cxf >= width - bw, true)
	_ = cyf
}
