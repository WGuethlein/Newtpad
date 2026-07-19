// Layer: program — the custom title bar: [☰ menu] [tabs] [+]  ...drag...  [_ ▢ ✕].
// The OS frame is removed (see window.odin); this strip IS the title bar. Menu,
// tabs and + are client hit-tested here; the window buttons are non-client (the
// platform handles their clicks) — we only draw them. Hover uses the live cursor
// position since the window buttons don't get client mouse messages.
package main

import "core:strings"
import plat "src:platform"

TAB_W :: f32(160) // fixed tab width
TAB_GAP :: f32(1)
TAB_PX :: f32(13) // tab label font size
TAB_CLOSE_W :: f32(20) // right-edge hit zone that closes instead of switches
MENU_W :: f32(44) // hamburger menu button
PLUS_W :: f32(32) // new-tab button

@(private = "file")
tab_bg := [3][4]f32 {
	{0.10, 0.12, 0.16, 1}, // strip background
	{0.14, 0.16, 0.21, 1}, // inactive tab
	{0.20, 0.23, 0.30, 1}, // active tab
}

// x where the tabs + "+" end (everything left of here in the bar is client; the
// gap between here and the window buttons is the OS drag region).
@(private = "file")
tabs_right :: proc(app: ^App, char_w: f32) -> f32 {
	x := MENU_W
	for d in app.docs {
		if d != nil {x += TAB_W + TAB_GAP}
	}
	return x + PLUS_W
}

// Handle a click on the title bar during the input phase. Returns true (and
// consumes the click) if it landed on the menu / a tab / the + button.
tabs_hit_test :: proc(app: ^App, win: ^plat.Window) -> bool {
	if !(win.mouse_pressed || win.mouse_middle_pressed) {return false}
	if f32(win.mouse_y) >= TAB_STRIP_H {return false}
	mx := f32(win.mouse_x)

	consumed := true
	if mx < MENU_W { // menu -> command palette
		palette_open(app)
		palette_input_rune(app, '>')
	} else {
		x := MENU_W - app.tab_scroll
		hit_slot := -1
		hit_close := false
		for d, slot in app.docs {
			if d == nil {continue}
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
			}
		} else if mx >= x && mx < x + PLUS_W { // + -> new tab
			app_new_scratch(app)
		}
	}

	win.mouse_pressed = false
	win.mouse_middle_pressed = false
	win.mouse_down = false
	return consumed
}

@(private = "file")
caption_btn :: proc(gfx: ^plat.Gfx, qp: ^plat.Quad_Pipeline, text: ^plat.Text, x, w: f32, glyph: string, hovered, is_close: bool) {
	if hovered {
		col := [4]f32{0.75, 0.16, 0.16, 1} if is_close else {0.28, 0.32, 0.40, 1}
		plat.quads_draw(gfx, qp, []plat.Quad{{pos = {x, 0}, size = {w, TAB_STRIP_H}, color = col}})
	}
	fg := [4]f32{0.96, 0.96, 0.98, 1} if (hovered && is_close) else {0.72, 0.76, 0.84, 1}
	cw := plat.text_char_width(text, 15)
	plat.text_draw(gfx, text, glyph, x + (w - cw) / 2, TAB_STRIP_H * 0.5 + 5, 15, fg)
}

tabs_draw :: proc(gfx: ^plat.Gfx, quad_pipe: ^plat.Quad_Pipeline, text: ^plat.Text, app: ^App, win: ^plat.Window, width: f32) {
	win.titlebar_h = i32(TAB_STRIP_H)
	char_w := plat.text_char_width(text, TAB_PX)
	win.tabs_right = i32(tabs_right(app, char_w))

	cx, cy := plat.window_cursor_client(win)
	in_bar := f32(cy) >= 0 && f32(cy) < TAB_STRIP_H
	base_y := TAB_STRIP_H - 12

	plat.quads_draw(gfx, quad_pipe, []plat.Quad{{pos = {0, 0}, size = {width, TAB_STRIP_H}, color = tab_bg[0]}})

	// menu button
	if in_bar && f32(cx) < MENU_W {
		plat.quads_draw(gfx, quad_pipe, []plat.Quad{{pos = {0, 0}, size = {MENU_W, TAB_STRIP_H}, color = {0.28, 0.32, 0.40, 1}}})
	}
	plat.text_draw(gfx, text, "☰", MENU_W / 2 - 8, base_y, 15, {0.80, 0.84, 0.90, 1})

	// tabs
	max_cells := int((TAB_W - TAB_CLOSE_W - 8) / char_w)
	x := MENU_W - app.tab_scroll
	for d, slot in app.docs {
		if d == nil {continue}
		active := slot == app.active
		plat.quads_draw(gfx, quad_pipe, []plat.Quad{{pos = {x, 4}, size = {TAB_W, TAB_STRIP_H - 4}, color = tab_bg[2 if active else 1]}})

		title := tab_title(d, context.temp_allocator)
		tb := transmute([]u8)title
		if plat.text_cells(text, tb) > max_cells && max_cells > 1 {
			cut := plat.text_bytes_for_cells(text, tb, max_cells - 1)
			title = strings.concatenate({title[:cut], "…"}, context.temp_allocator)
		}
		fg := [4]f32{0.92, 0.94, 0.98, 1} if active else {0.66, 0.70, 0.78, 1}
		plat.text_draw(gfx, text, title, x + 8, base_y, TAB_PX, fg)
		plat.text_draw(gfx, text, "×", x + TAB_W - 15, base_y, TAB_PX, {0.60, 0.64, 0.72, 1})
		x += TAB_W + TAB_GAP
	}

	// new-tab button
	if in_bar && f32(cx) >= x && f32(cx) < x + PLUS_W {
		plat.quads_draw(gfx, quad_pipe, []plat.Quad{{pos = {x, 4}, size = {PLUS_W, TAB_STRIP_H - 4}, color = {0.20, 0.23, 0.30, 1}}})
	}
	plat.text_draw(gfx, text, "+", x + PLUS_W / 2 - 4, base_y, 17, {0.75, 0.79, 0.86, 1})

	// window buttons (non-client; drawn here, clicks handled by the platform)
	bw := f32(plat.CAPTION_BTN_W)
	cxf, cyf := f32(cx), f32(cy)
	hov := in_bar && cxf >= width - 3 * bw
	caption_btn(gfx, quad_pipe, text, width - 3 * bw, bw, "–", hov && cxf < width - 2 * bw, false)
	caption_btn(gfx, quad_pipe, text, width - 2 * bw, bw, "❐" if win.maximized else "▢", hov && cxf >= width - 2 * bw && cxf < width - bw, false)
	caption_btn(gfx, quad_pipe, text, width - bw, bw, "✕", hov && cxf >= width - bw, true)
	_ = cyf
}
