// Layer: program — the Font page (Edit > Font), where the typeface is chosen.
//
// Font lives under Edit rather than in Settings because it is something you
// reach for while working on a document, not a preference you set once. Windows
// Notepad puts it under Edit for the same reason. Settings keeps the things you
// genuinely set and forget.
//
// A full-window page, like Settings: no modal dialog, no second HWND, Esc closes
// it. Deliberately NOT the native ChooseFont dialog — that lists every installed
// font including proportional ones, and a proportional face breaks the cell grid
// the whole renderer is built on.
package main

import "core:fmt"
import plat "src:platform"

FONT_ROWS :: 3 // family, style, size

font_page_move :: proc(app: ^App, d: int) {
	app.font_row = clamp(app.font_row + d, 0, FONT_ROWS - 1)
}

// dir -1/+1 steps the value; 0 means "activate" (steps forward).
font_page_adjust :: proc(rc: ^Render_Ctx, row, dir: int) {
	s := &rc.app.settings
	d := dir if dir != 0 else 1
	switch row {
	case 0:
		if len(font_choices) == 0 {font_choices_refresh()}
		i := font_choice_index(s.font_family)
		s.font_family = font_choices[(i + d + len(font_choices)) % len(font_choices)]
		settings_apply_font(rc)
	case 1:
		n := int(max(plat.Font_Style)) + 1
		s.font_style = plat.Font_Style((int(s.font_style) + d + n) % n)
		settings_apply_font(rc)
	case 2:
		s.font_size = clamp(s.font_size + d, FONT_SIZE_MIN, FONT_SIZE_MAX)
		settings_apply(rc)
	}
	settings_save(s^)
}

font_page_draw :: proc(gfx: ^plat.Gfx, qp: ^plat.Quad_Pipeline, t: ^plat.Text, app: ^App, width, height: f32) {
	plat.quads_draw(gfx, qp, []plat.Quad{{pos = {0, CHROME_TOP}, size = {width, height - CHROME_TOP}, color = {0.10, 0.12, 0.16, 1}}})

	x := sx(32)
	y := CHROME_TOP + sx(40)
	plat.text_draw(gfx, t, "Font", x, y, UI_PX * 1.4, {0.94, 0.96, 0.99, 1})
	plat.text_draw(gfx, t, "Esc closes    Up/Down choose    Left/Right change", x, y + sx(22), UI_SMALL_PX, {0.50, 0.55, 0.64, 1})
	y += sx(60)

	labels := [FONT_ROWS]string{"Family", "Style", "Size"}
	vals: [FONT_ROWS]string
	vals[0] = app.settings.font_family
	vals[1] = plat.font_style_name(app.settings.font_style)
	vals[2] = fmt.tprintf("%d", app.settings.font_size)

	rowh := sx(38)
	for i in 0 ..< FONT_ROWS {
		if i == app.font_row {
			plat.quads_draw(gfx, qp, []plat.Quad{{pos = {x - sx(12), y - sx(16)}, size = {width - sx(64), rowh - sx(4)}, color = {0.18, 0.24, 0.34, 1}}})
		}
		plat.text_draw(gfx, t, labels[i], x, y, UI_PX, {0.92, 0.94, 0.98, 1})
		plat.text_draw(gfx, t, vals[i], x + sx(160), y, UI_PX, {0.55, 0.85, 0.60, 1})
		if i == app.font_row {
			plat.text_draw(gfx, t, "<   >", x + sx(420), y, UI_PX, {0.50, 0.55, 0.64, 1})
		}
		y += rowh
	}

	// Live preview at the real size, in the real face — the point of a font page
	// is seeing the thing before committing to it.
	y += sx(24)
	plat.text_draw(gfx, t, "Preview", x, y, UI_SMALL_PX, {0.50, 0.55, 0.64, 1})
	y += sx(28)
	// The real size the document renders at, DPI and zoom included — a preview
	// drawn at the raw 96-DPI number would show 16px text on a 200% display
	// while the document showed 32px.
	px := active_render_ctx.px if active_render_ctx != nil else sx(f32(app.settings.font_size))
	plat.text_draw(gfx, t, "The quick brown fox jumps over the lazy dog", x, y, px, {0.88, 0.91, 0.96, 1})
	y += px * 1.6
	plat.text_draw(gfx, t, "0123456789  {}[]()<>  il1| oO0  ->  ==  !=", x, y, px, {0.75, 0.80, 0.88, 1})

	// Families are filtered to monospaced ones on purpose; say so, or the short
	// list looks like a bug.
	y += px * 1.8
	plat.text_draw(
		gfx,
		t,
		fmt.tprintf("%d monospaced families found. Proportional fonts are not offered: the editor lays text out on a fixed cell grid.", len(font_choices)),
		x,
		y,
		UI_SMALL_PX,
		{0.45, 0.49, 0.57, 1},
	)
}
