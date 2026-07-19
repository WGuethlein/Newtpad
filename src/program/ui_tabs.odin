// Layer: program — the tab strip. Immediate-mode: hit-test during input, draw
// during render, both walking the same fixed-width layout. Overflow currently
// clips off the right edge (horizontal scroll is a follow-up).
package main

import "core:strings"
import plat "src:platform"

TAB_W :: f32(160) // fixed tab width
TAB_GAP :: f32(1)
TAB_PX :: f32(13) // tab label font size
TAB_CLOSE_W :: f32(20) // right-edge hit zone that closes instead of switches

@(private = "file")
tab_bg := [3][4]f32 {
	{0.10, 0.12, 0.16, 1}, // strip background
	{0.14, 0.16, 0.21, 1}, // inactive tab
	{0.20, 0.23, 0.30, 1}, // active tab
}

// Handle a click on the strip during the input phase. Returns true (and consumes
// the click on the window) if the press landed in the strip, so the caret handler
// skips it. Left-click switches (or closes on the right-edge zone); middle-click
// closes.
tabs_hit_test :: proc(app: ^App, win: ^plat.Window) -> bool {
	if !(win.mouse_pressed || win.mouse_middle_pressed) {return false}
	if f32(win.mouse_y) >= TAB_STRIP_H {return false}
	mx := f32(win.mouse_x)
	x := -app.tab_scroll
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
	}
	// consume: clicking the strip (even empty area) must not move the caret
	win.mouse_pressed = false
	win.mouse_middle_pressed = false
	win.mouse_down = false
	return true
}

tabs_draw :: proc(gfx: ^plat.Gfx, quad_pipe: ^plat.Quad_Pipeline, text: ^plat.Text, app: ^App, width: f32) {
	// strip background
	plat.quads_draw(gfx, quad_pipe, []plat.Quad{{pos = {0, 0}, size = {width, TAB_STRIP_H}, color = tab_bg[0]}})

	char_w := plat.text_char_width(text, TAB_PX)
	max_cells := int((TAB_W - TAB_CLOSE_W - 8) / char_w) // label budget before the close glyph
	x := -app.tab_scroll
	for d, slot in app.docs {
		if d == nil {continue}
		active := slot == app.active
		plat.quads_draw(gfx, quad_pipe, []plat.Quad{{pos = {x, 2}, size = {TAB_W, TAB_STRIP_H - 2}, color = tab_bg[2 if active else 1]}})

		title := tab_title(d, context.temp_allocator)
		tb := transmute([]u8)title
		if plat.text_cells(text, tb) > max_cells && max_cells > 1 {
			// elide: keep max_cells-1 cells, add an ellipsis
			cut := plat.text_bytes_for_cells(text, tb, max_cells - 1)
			title = strings.concatenate({title[:cut], "…"}, context.temp_allocator)
		}
		fg := [4]f32{0.92, 0.94, 0.98, 1} if active else {0.66, 0.70, 0.78, 1}
		plat.text_draw(gfx, text, title, x + 8, TAB_STRIP_H - 9, TAB_PX, fg)
		// close glyph at the right edge
		plat.text_draw(gfx, text, "×", x + TAB_W - 15, TAB_STRIP_H - 9, TAB_PX, {0.60, 0.64, 0.72, 1})

		x += TAB_W + TAB_GAP
	}
}
