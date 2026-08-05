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

import "src:base"

// The preview's code sample, at package scope so fonttest asserts on the bytes the
// page actually draws. It lived inside font_page_draw and the test carried its own
// copy of the same literal -- two copies of one string, free to drift, and the test
// would have gone on passing while the page drew something else.
FONT_PREVIEW_SAMPLE := []string{`"sqlReaderQuery": "SELECT TOP (1000)",`, `"retry": 0, // comment`}

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
		// Start the system scan the first time a font list is shown, and rebuild
		// once when it lands. `scan_merged` is what stops that being every frame.
		font_scan_kick()
		if len(font_choices) == 0 || (font_scan_landed() && !font_choices_scanned) {font_choices_refresh()}
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
	plat.quads_draw(gfx, qp, []plat.Quad{{pos = {0, CHROME_TOP}, size = {width, height - CHROME_TOP}, color = g_theme[.Bg_Base]}})

	x := sx(32)
	y := CHROME_TOP + sx(40)
	// BREADCRUMB, not a bare title. The 11.1 mockup reads "Settings > Editor font",
	// and the spec's own note beside it is that a screen opened FROM somewhere
	// should say where from -- this page is reached through Settings and Esc goes
	// back there, so a lone "Font" left the trail unstated.
	cw := plat.text_char_width(t, UI_PX * 1.4)
	plat.text_draw(gfx, t, "Settings", x, y, UI_PX * 1.4, g_theme[.Text_Muted])
	plat.text_draw(gfx, t, "›", x + 9 * cw, y, UI_PX * 1.4, g_theme[.Text_Muted])
	plat.text_draw(gfx, t, "Editor font", x + 11 * cw, y, UI_PX * 1.4, g_theme[.Text_Primary])
	// "Esc goes back", not "Esc closes" -- it returns to Settings, and the
	// breadcrumb above now promises exactly that.
	plat.text_draw(gfx, t, "Esc goes back    Up/Down choose    Left/Right change", x, y + sx(22), UI_SMALL_PX, g_theme[.Text_Muted])
	y += sx(60)

	labels := [FONT_ROWS]string{"Family", "Style", "Size"}
	vals: [FONT_ROWS]string
	vals[0] = app.settings.font_family
	vals[1] = plat.font_style_name(app.settings.font_style)
	vals[2] = fmt.tprintf("%d", app.settings.font_size)

	// Values RIGHT-ALIGNED and bracketed by the chevrons, per the mockup's
	// "< Monaspace Neon >". They used to sit at a fixed x+160 with the chevrons
	// stranded out at x+420, so the value floated in the middle of the row with a
	// gap on both sides and the arrows pointed at nothing in particular. The
	// bracket is what makes them read as "this value steps".
	rowh := sx(38)
	vw := plat.text_char_width(t, UI_PX)
	right := width - sx(64)
	for i in 0 ..< FONT_ROWS {
		sel := i == app.font_row
		if sel {
			plat.quads_draw(gfx, qp, []plat.Quad{{pos = {x - sx(12), y - sx(16)}, size = {width - sx(64), rowh - sx(4)}, color = g_theme[.Accent_Wash]}})
		}
		plat.text_draw(gfx, t, labels[i], x, y, UI_PX, g_theme[.Text_Primary])
		vwidth := f32(len(vals[i])) * vw
		vx := right - vwidth
		plat.text_draw(gfx, t, vals[i], vx, y, UI_PX, g_theme[.Success])
		// The chevrons only on the selected row -- they say "this is the one the
		// arrow keys will change", which is not true of the others.
		if sel {
			plat.text_draw(gfx, t, "‹", vx - sx(20), y, UI_PX, g_theme[.Text_Muted])
			plat.text_draw(gfx, t, "›", right + sx(8), y, UI_PX, g_theme[.Text_Muted])
		}
		y += rowh
	}

	// Live preview at the real size, in the real face — the point of a font page
	// is seeing the thing before committing to it.
	y += sx(24)
	plat.text_draw(gfx, t, "PREVIEW", x, y, UI_SMALL_PX, g_theme[.Text_Muted])
	y += sx(28)
	// The real size the document renders at, DPI and zoom included — a preview
	// drawn at the raw 96-DPI number would show 16px text on a 200% display
	// while the document showed 32px.
	px := active_render_ctx.px if active_render_ctx != nil else sx(f32(app.settings.font_size))
	// .Doc: the preview must show the face the document will actually use, not
	// the chrome face this page is otherwise drawn in.
	plat.text_draw(gfx, t, "The quick brown fox jumps over the lazy dog", x, y, px, g_theme[.Text_Primary], .Doc)
	y += px * 1.6
	plat.text_draw(gfx, t, "0123456789  {}[]()<>  il1| oO0  ->  ==  !=", x, y, px, g_theme[.Text_Secondary], .Doc)

	// A REAL CODE SAMPLE, syntax-coloured, in a panel -- the mockup's
	// `"sqlReaderQuery": "SELECT TOP (1000)"`. A pangram tells you what the letters
	// look like; it tells you nothing about the thing you will actually stare at,
	// which is punctuation density, how a quote sits against a colon, and whether
	// the comment colour survives at this size.
	//
	// Coloured by the REAL json lexer rather than by hand-picked spans, so the
	// sample cannot drift from what the editor would draw for the same bytes.
	y += px * 1.9
	{
		SAMPLE := FONT_PREVIEW_SAMPLE
		panh := px * 1.5 * f32(len(SAMPLE)) + px
		plat.quads_draw(gfx, qp, []plat.Quad{{pos = {x - sx(12), y - px}, size = {min(width - sx(64) + sx(12), sx(560)), panh}, color = g_theme[.Bg_Raised]}})
		cwd := plat.text_char_width(t, px, .Doc)
		for line in SAMPLE {
			toks: [64]base.Token
			nt := base.lex_json(transmute([]u8)line, toks[:])
			// The whole line first, in the ordinary text colour: anything the lexer
			// does not claim (the colon, the spaces) still has to appear, or the
			// sample would be a few coloured islands in a blank strip. The tokens
			// then overdraw their own spans.
			plat.text_draw(gfx, t, line, x, y, px, g_theme[.Text_Secondary], .Doc)
			for k in 0 ..< nt {
				tk := toks[k]
				if tk.start + tk.len > len(line) {continue}
				plat.text_draw(gfx, t, line[tk.start:tk.start + tk.len], x + f32(tk.start) * cwd, y, px, g_theme[token_kind_role(tk.kind)], .Doc)
			}
			y += px * 1.5
		}
		y += px * 0.4
	}

	// Families are filtered to monospaced ones on purpose; say so, or the short
	// list looks like a bug.
	y += px * 0.6
	plat.text_draw(
		gfx,
		t,
		fmt.tprintf("%d monospaced families found. Proportional fonts are not offered: the editor lays text out on a fixed cell grid.", len(font_choices)),
		x,
		y,
		UI_SMALL_PX,
		g_theme[.Text_Muted],
	)
}
