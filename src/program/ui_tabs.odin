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

@(private = "file")
tab_bg := [3][4]f32 {
	{0.10, 0.12, 0.16, 1}, // strip background
	{0.14, 0.16, 0.21, 1}, // inactive tab
	{0.20, 0.23, 0.30, 1}, // active tab
}

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

// Tabs that don't fit. Drawn as a count rather than silently dropped — with no
// indicator there was nothing to say the other tabs existed at all.
tabs_hidden_count :: proc(app: ^App, win: ^plat.Window, width: f32) -> int {
	limit := tabs_limit(win, width)
	x := MENU_W - app.tab_scroll
	shown, live := 0, 0
	for d in app.docs {
		if d == nil {continue}
		live += 1
		if x + TAB_W <= limit {
			shown += 1
			x += TAB_W + TAB_GAP
		}
	}
	// Re-run with the indicator's width reserved, or the count itself can be
	// what pushes a tab out and the number comes out one too low.
	if shown < live {
		limit -= sx(52)
		x = MENU_W - app.tab_scroll
		shown = 0
		for d in app.docs {
			if d == nil {continue}
			if x + TAB_W <= limit {
				shown += 1
				x += TAB_W + TAB_GAP
			}
		}
	}
	return live - shown
}

@(private = "file")
tabs_right :: proc(app: ^App, win: ^plat.Window, width: f32) -> f32 {
	x := MENU_W
	for d in app.docs {
		if d != nil {x += TAB_W + TAB_GAP}
	}
	return min(x + PLUS_W, tabs_limit(win, width))
}

// Handle a click on the title bar during the input phase. Returns true (and
// consumes the click) if it landed on the menu / a tab / the + button.
tabs_hit_test :: proc(app: ^App, win: ^plat.Window) -> bool {
	if !(win.mouse_pressed || win.mouse_middle_pressed) {return false}
	if f32(win.mouse_y) >= TAB_STRIP_H {return false}
	mx := f32(win.mouse_x)

	consumed := true
	limit := tabs_limit(win, f32(win.width)) // must match what tabs_draw drew
	hidden := tabs_hidden_count(app, win, f32(win.width))
	if hidden > 0 && mx >= limit - sx(52) && mx < limit {
		// The overflow count opens the palette's tab list, which can reach any
		// tab regardless of whether the strip has room to show it.
		palette_open(app)
		win.mouse_pressed = false
		win.mouse_middle_pressed = false
		win.mouse_down = false
		return true
	}
	if hidden > 0 {limit -= sx(52)}
	if mx < MENU_W { // menu -> command palette
		palette_open(app)
		palette_input_rune(app, '>')
	} else {
		x := MENU_W - app.tab_scroll
		hit_slot := -1
		hit_close := false
		for d, slot in app.docs {
			if d == nil {continue}
			if x + TAB_W > limit {break} // not drawn, so not clickable
			if mx >= x && mx < x + TAB_W {
				hit_slot = slot
				hit_close = win.mouse_middle_pressed || mx >= x + TAB_W - TAB_CLOSE_W
			}
			x += TAB_W + TAB_GAP
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
		} else if x + PLUS_W <= limit && mx >= x && mx < x + PLUS_W { // + -> new tab
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
	// Target display index from the cursor x (same layout the strip is drawn with).
	rel := f32(win.mouse_x) - (MENU_W - app.tab_scroll)
	target := clamp(int(rel / (TAB_W + TAB_GAP)), 0, len(live) - 1)
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
		col := [4]f32{0.75, 0.16, 0.16, 1} if is_close else {0.28, 0.32, 0.40, 1}
		plat.quads_draw(gfx, qp, []plat.Quad{{pos = {x, 0}, size = {w, TAB_STRIP_H}, color = col}})
	}
	fg := [4]f32{0.96, 0.96, 0.98, 1} if (hovered && is_close) else {0.72, 0.76, 0.84, 1}
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

	plat.quads_draw(gfx, quad_pipe, []plat.Quad{{pos = {0, 0}, size = {width, TAB_STRIP_H}, color = tab_bg[0]}})

	// menu button
	if in_bar && f32(cx) < MENU_W {
		plat.quads_draw(gfx, quad_pipe, []plat.Quad{{pos = {0, 0}, size = {MENU_W, TAB_STRIP_H}, color = {0.28, 0.32, 0.40, 1}}})
	}
	plat.text_draw(gfx, text, "☰", MENU_W / 2 - sx(8), base_y, UI_PX, {0.80, 0.84, 0.90, 1})

	// tabs
	// Nothing past `limit` may be drawn: the caption buttons are non-client and
	// WM_NCHITTEST claims that region first, so a tab drawn under them looks
	// clickable but sends HT_CLOSE — one click and the app exits.
	limit := tabs_limit(win, width)
	// Reserve room for the overflow indicator when not everything fits, so the
	// count is never itself clipped.
	hidden := tabs_hidden_count(app, win, width)
	if hidden > 0 {limit -= sx(52)}
	max_cells := int((TAB_W - TAB_CLOSE_W - sx(8)) / char_w)
	x := MENU_W - app.tab_scroll
	for d, slot in app.docs {
		if d == nil {continue}
		if x + TAB_W > limit {break} // overflow; the count is drawn below
		active := slot == app.active
		plat.quads_draw(gfx, quad_pipe, []plat.Quad{{pos = {x, sx(4)}, size = {TAB_W, TAB_STRIP_H - sx(4)}, color = tab_bg[2 if active else 1]}})

		title := tab_title(d, context.temp_allocator)
		tb := transmute([]u8)title
		if plat.text_cells(text, tb) > max_cells && max_cells > 1 {
			cut := plat.text_bytes_for_cells(text, tb, max_cells - 1)
			title = strings.concatenate({title[:cut], "…"}, context.temp_allocator)
		}
		fg := [4]f32{0.92, 0.94, 0.98, 1} if active else {0.66, 0.70, 0.78, 1}
		plat.text_draw(gfx, text, title, x + sx(8), base_y, UI_SMALL_PX, fg)
		plat.text_draw(gfx, text, "×", x + TAB_W - sx(15), base_y, UI_SMALL_PX, {0.60, 0.64, 0.72, 1})
		x += TAB_W + TAB_GAP
	}

	// Overflow count, clickable to reach the hidden tabs via the palette.
	if hidden > 0 {
		hx := limit
		hot := in_bar && f32(cx) >= hx && f32(cx) < hx + sx(52)
		if hot {
			plat.quads_draw(gfx, quad_pipe, []plat.Quad{{pos = {hx, sx(4)}, size = {sx(52), TAB_STRIP_H - sx(4)}, color = {0.20, 0.23, 0.30, 1}}})
		}
		plat.text_draw(gfx, text, fmt.tprintf("+%d ▸", hidden), hx + sx(6), base_y, UI_SMALL_PX, {0.75, 0.79, 0.86, 1})
	}

	// new-tab button, only if it fits clear of the caption buttons
	if x + PLUS_W <= limit {
		if in_bar && f32(cx) >= x && f32(cx) < x + PLUS_W {
			plat.quads_draw(gfx, quad_pipe, []plat.Quad{{pos = {x, sx(4)}, size = {PLUS_W, TAB_STRIP_H - sx(4)}, color = {0.20, 0.23, 0.30, 1}}})
		}
		plat.text_draw(gfx, text, "+", x + PLUS_W / 2 - sx(4), base_y, UI_PX, {0.75, 0.79, 0.86, 1})
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
