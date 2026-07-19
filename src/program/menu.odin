// Layer: program — the menu bar: a row below the tab strip holding File / Edit /
// View and a right-aligned settings gear, matching Windows 11 Notepad's chrome
// (which also has no Format or Help menu — Word Wrap lives in View).
//
// It is a discoverability surface, not a second command system: every item names
// a Command_Id and dispatches through command_dispatch, so behaviour lives in one
// place and the shortcut shown beside each item is read from the keymap.
//
// The command palette (Ctrl+P) is unchanged and remains the fast path; every
// shipped editor with a palette also keeps a menu.
package main

import plat "src:platform"

MENU_BAR_H_96 :: f32(26)
MENU_ITEM_H_96 :: f32(24)
MENU_PAD_96 :: f32(12) // horizontal padding around a top-level title
GEAR_W_96 :: f32(34) // settings gear hit box (wider than the glyph, so it's clickable)
MENU_BAR_H := MENU_BAR_H_96
MENU_ITEM_H := MENU_ITEM_H_96
MENU_PAD := MENU_PAD_96

// An item is either a command row or a separator (cmd == .None).
Menu_Item :: struct {
	cmd:     Command_Id,
	// Non-nil only for toggles; draws a check mark. Takes the app because state
	// lives on the active document, which may be nil.
	checked: proc(app: ^App) -> bool,
	// Non-nil when the item can be unavailable. Greyed out and unclickable —
	// several commands silently no-op (Copy with no selection, Undo with no
	// history), and a menu that offers them anyway is lying about what it does.
	enabled: proc(app: ^App) -> bool,
}

Menu :: struct {
	title:    string,
	mnemonic: rune, // Alt+this opens the menu
	items:    []Menu_Item,
}

@(private = "file")
has_doc :: proc(app: ^App) -> bool {return app_active(app) != nil}

@(private = "file")
has_sel :: proc(app: ^App) -> bool {
	d := app_active(app)
	return d != nil && doc_has_sel(d)
}

@(private = "file")
can_undo :: proc(app: ^App) -> bool {
	d := app_active(app)
	return d != nil && len(d.undo) > 0
}

@(private = "file")
can_redo :: proc(app: ^App) -> bool {
	d := app_active(app)
	return d != nil && len(d.redo) > 0
}

@(private = "file")
is_wrapped :: proc(app: ^App) -> bool {
	d := app_active(app)
	return d != nil && d.wrap
}

@(private = "file")
is_filtered :: proc(app: ^App) -> bool {
	d := app_active(app)
	return d != nil && d.filter
}

@(private = "file")
is_regex :: proc(app: ^App) -> bool {
	d := app_active(app)
	return d != nil && d.find.regex
}

@(private = "file")
sep :: Menu_Item{}

menus := []Menu {
	{
		"File",
		'f',
		[]Menu_Item {
			{cmd = .Tab_New},
			{cmd = .Tab_Open},
			sep,
			{cmd = .Save, enabled = has_doc},
			{cmd = .Save_As, enabled = has_doc},
			sep,
			{cmd = .Tab_Close, enabled = has_doc},
			{cmd = .Exit},
		},
	},
	{
		"Edit",
		'e',
		[]Menu_Item {
			{cmd = .Undo, enabled = can_undo},
			{cmd = .Redo, enabled = can_redo},
			sep,
			{cmd = .Cut, enabled = has_sel},
			{cmd = .Copy, enabled = has_sel},
			{cmd = .Paste, enabled = has_doc},
			sep,
			{cmd = .Select_All, enabled = has_doc},
			sep,
			{cmd = .Find_Open, enabled = has_doc},
			{cmd = .Replace_Open, enabled = has_doc},
			{cmd = .Goto_Line, enabled = has_doc},
		},
	},
	{
		"View",
		'v',
		[]Menu_Item {
			{cmd = .Toggle_Wrap, checked = is_wrapped, enabled = has_doc},
			sep,
			{cmd = .Filter_Open, checked = is_filtered, enabled = has_doc},
			{cmd = .Find_Toggle_Regex, checked = is_regex, enabled = has_doc},
			sep,
			{cmd = .Zoom_In},
			{cmd = .Zoom_Out},
			{cmd = .Zoom_Reset},
			sep,
			{cmd = .Palette_Open},
			{cmd = .Settings_Open},
		},
	},
}

// Menu bar / dropdown state. `mode` is menu-bar keyboard mode with nothing open
// (what a bare Alt tap gives you); `open` is the index of the open dropdown.
Menu_State :: struct {
	mode: bool,
	open: int, // -1 = no dropdown
	item: int, // highlighted item within the open dropdown
}

// Must be called before the first frame: the zero value of `open` is 0, which
// means "the File dropdown is open", so an uninitialised Menu_State starts the
// app with a menu hanging down.
menu_init :: proc(m: ^Menu_State) {
	m.open = -1
	m.item = -1
	m.mode = false
}

menu_close :: proc(app: ^App) {
	app.menu.mode = false
	app.menu.open = -1
	app.menu.item = -1
}

menu_is_active :: proc(app: ^App) -> bool {return app.menu.mode || app.menu.open >= 0}

is_menu_cmd :: proc(c: Command_Id) -> bool {
	#partial switch c {
	case .Menu_Close, .Menu_Next, .Menu_Prev, .Menu_Item_Next, .Menu_Item_Prev, .Menu_Activate:
		return true
	}
	return false
}

lower_rune :: proc(r: rune) -> rune {return r + 32 if r >= 'A' && r <= 'Z' else r}

// Map a character back to a Key so an Alt+<char> press can be checked against
// the explicit Alt bindings before it is treated as a mnemonic.
char_key :: proc(r: rune) -> plat.Key {
	c := lower_rune(r)
	if c >= 'a' && c <= 'z' {return plat.Key(int(plat.Key.A) + int(c - 'a'))}
	if c >= '0' && c <= '9' {return plat.Key(int(plat.Key.Num0) + int(c - '0'))}
	return .None
}

// Click handling for the bar and any open dropdown. Returns true if the click
// was consumed. Must run before the tab strip and scrollbar handlers.
// Returns the command a click selected (.None if it selected nothing) and
// whether the click was consumed. The caller dispatches, so the menu never has
// to know how commands run.
menu_hit_test :: proc(app: ^App, t: ^plat.Text, win: ^plat.Window, w, h: f32) -> (cmd: Command_Id, consumed: bool) {
	if !win.mouse_pressed {return .None, false}
	mx, my := f32(win.mouse_x), f32(win.mouse_y)

	if my >= TAB_STRIP_H && my < TAB_STRIP_H + MENU_BAR_H {
		gx := w - SCROLLBAR_W - sx(GEAR_W_96)
		if mx >= gx && mx < gx + sx(GEAR_W_96) {
			menu_close(app)
			consume_click(win)
			return .Settings_Open if !app.settings_open else .Settings_Close, true
		}
		if i := menu_title_at(t, mx); i >= 0 {
			if app.menu.open == i {menu_close(app)} else {menu_open_at(app, i)}
		} else {
			menu_close(app) // empty bar area: swallow, don't move the caret
		}
		consume_click(win)
		return .None, true
	}

	if app.menu.open >= 0 {
		picked := Command_Id.None
		if idx := menu_item_at(app, my); idx >= 0 {
			it := menus[app.menu.open].items[idx]
			if item_enabled(app, it) {picked = it.cmd}
		}
		// Any click while a dropdown is open is consumed, as native menus do —
		// clicking away closes it rather than also moving the caret.
		menu_close(app)
		consume_click(win)
		return picked, true
	}
	return .None, false
}

// Take the click entirely. Clearing mouse_down matters as much as mouse_pressed:
// the caret's drag-to-extend branch runs off mouse_down alone, so leaving it set
// meant clicking a menu also dragged a selection through the document behind it,
// and kept highlighting for as long as the button stayed down.
@(private = "file")
consume_click :: proc(win: ^plat.Window) {
	win.mouse_pressed = false
	win.mouse_middle_pressed = false
	win.mouse_down = false
}

item_enabled :: proc(app: ^App, it: Menu_Item) -> bool {
	if it.cmd == .None {return false} // separator
	return it.enabled == nil || it.enabled(app)
}

// First selectable item at or after `from`, walking `dir`. Skips separators and
// disabled rows so keyboard navigation never parks on something inert.
menu_step :: proc(app: ^App, mi, from, dir: int) -> int {
	items := menus[mi].items
	i := from
	for _ in 0 ..< len(items) {
		if i < 0 {i = len(items) - 1}
		if i >= len(items) {i = 0}
		if item_enabled(app, items[i]) {return i}
		i += dir
	}
	return -1
}

menu_open_at :: proc(app: ^App, mi: int) {
	app.menu.mode = true
	app.menu.open = clamp(mi, 0, len(menus) - 1)
	app.menu.item = menu_step(app, app.menu.open, 0, 1)
}

// --- layout ---

@(private = "file")
title_w :: proc(t: ^plat.Text, s: string) -> f32 {
	return f32(plat.text_cells(t, transmute([]u8)s)) * plat.text_char_width(t, UI_PX) + 2 * MENU_PAD
}

// x range of top-level menu `i` in the bar.
menu_title_rect :: proc(t: ^plat.Text, i: int) -> (x0, x1: f32) {
	x := f32(0)
	for m, k in menus {
		w := title_w(t, m.title)
		if k == i {return x, x + w}
		x += w
	}
	return 0, 0
}

// Which top-level title is at client x (in the bar row), or -1.
menu_title_at :: proc(t: ^plat.Text, mx: f32) -> int {
	for _, i in menus {
		x0, x1 := menu_title_rect(t, i)
		if mx >= x0 && mx < x1 {return i}
	}
	return -1
}

// --- drawing ---

@(private = "file")
MENU_COL := struct {
	bar, hover, drop, border, fg, dim, chord, check: [4]f32,
} {
	bar    = {0.12, 0.14, 0.18, 1},
	hover  = {0.24, 0.30, 0.42, 1},
	drop   = {0.13, 0.15, 0.20, 1},
	border = {0.30, 0.34, 0.42, 1},
	fg     = {0.90, 0.92, 0.97, 1},
	dim    = {0.42, 0.46, 0.54, 1},
	chord  = {0.58, 0.64, 0.76, 1},
	check  = {0.55, 0.85, 0.60, 1},
}

menu_draw :: proc(gfx: ^plat.Gfx, qp: ^plat.Quad_Pipeline, t: ^plat.Text, app: ^App, win: ^plat.Window, width, height: f32) {
	cw := plat.text_char_width(t, UI_PX)
	base_y := TAB_STRIP_H + MENU_BAR_H - sx(8)
	plat.quads_draw(gfx, qp, []plat.Quad{{pos = {0, TAB_STRIP_H}, size = {width, MENU_BAR_H}, color = MENU_COL.bar}})

	cx, cy := plat.window_cursor_client(win)
	in_bar := f32(cy) >= TAB_STRIP_H && f32(cy) < TAB_STRIP_H + MENU_BAR_H
	hover := menu_title_at(t, f32(cx)) if in_bar else -1

	for m, i in menus {
		x0, x1 := menu_title_rect(t, i)
		lit := i == app.menu.open || (app.menu.open < 0 && i == hover)
		if lit {
			plat.quads_draw(gfx, qp, []plat.Quad{{pos = {x0, TAB_STRIP_H}, size = {x1 - x0, MENU_BAR_H}, color = MENU_COL.hover}})
		}
		plat.text_draw(gfx, t, m.title, x0 + MENU_PAD, base_y, UI_PX, MENU_COL.fg)
		// Underline the mnemonic while in keyboard menu mode, the way Windows
		// reveals access keys only once Alt has been pressed.
		if app.menu.mode {
			plat.quads_draw(gfx, qp, []plat.Quad{{pos = {x0 + MENU_PAD, base_y + sx(2)}, size = {cw, sx(1)}, color = MENU_COL.fg}})
		}
	}

	// Settings gear, right-aligned and clear of the scrollbar gutter. Drawn
	// larger than the menu text: at UI_PX the glyph reads as a speck rather than
	// a button, and it is the only icon-only control in the bar.
	gw := sx(GEAR_W_96)
	gx := width - SCROLLBAR_W - gw
	if in_bar && f32(cx) >= gx && f32(cx) < gx + gw {
		plat.quads_draw(gfx, qp, []plat.Quad{{pos = {gx, TAB_STRIP_H}, size = {gw, MENU_BAR_H}, color = MENU_COL.hover}})
	}
	gpx := UI_PX * 1.35
	gcw := plat.text_char_width(t, gpx)
	plat.text_draw(gfx, t, "⚙", gx + (gw - gcw) * 0.5, base_y + sx(2), gpx, MENU_COL.fg if !app.settings_open else MENU_COL.check)

	if app.menu.open < 0 {return}
	menu_draw_dropdown(gfx, qp, t, app, width, height)
}

@(private = "file")
menu_draw_dropdown :: proc(gfx: ^plat.Gfx, qp: ^plat.Quad_Pipeline, t: ^plat.Text, app: ^App, width, height: f32) {
	mi := app.menu.open
	items := menus[mi].items
	cw := plat.text_char_width(t, UI_PX)
	x0, _ := menu_title_rect(t, mi)
	dw := dropdown_w(t)
	y0 := TAB_STRIP_H + MENU_BAR_H

	h := f32(0)
	for it in items {h += MENU_ITEM_H if it.cmd != .None else MENU_ITEM_H * 0.4}
	// The dropdown is a client-space quad, not an OS popup, so it cannot leave
	// the window: clamp it or the bottom items are drawn off-screen and become
	// unclickable.
	h = min(h, max(MENU_ITEM_H, height - y0 - sx(4)))
	x0 = min(x0, max(0, width - dw))

	plat.quads_draw(gfx, qp, []plat.Quad {
			{pos = {x0 - sx(1), y0}, size = {dw + sx(2), h + sx(2)}, color = MENU_COL.border},
			{pos = {x0, y0 + sx(1)}, size = {dw, h}, color = MENU_COL.drop},
		})

	y := y0 + sx(1)
	for it, i in items {
		if it.cmd == .None { // separator
			sh := MENU_ITEM_H * 0.4
			if y + sh > y0 + h {break}
			plat.quads_draw(gfx, qp, []plat.Quad{{pos = {x0 + sx(8), y + sh * 0.5}, size = {dw - sx(16), sx(1)}, color = MENU_COL.border}})
			y += sh
			continue
		}
		if y + MENU_ITEM_H > y0 + h {break}
		on := item_enabled(app, it)
		if i == app.menu.item && on {
			plat.quads_draw(gfx, qp, []plat.Quad{{pos = {x0, y}, size = {dw, MENU_ITEM_H}, color = MENU_COL.hover}})
		}
		ty := y + MENU_ITEM_H - sx(7)
		if it.checked != nil && it.checked(app) {
			plat.text_draw(gfx, t, "✓", x0 + sx(8), ty, UI_PX, MENU_COL.check)
		}
		plat.text_draw(gfx, t, command_table[it.cmd].title, x0 + sx(28), ty, UI_PX, MENU_COL.fg if on else MENU_COL.dim)
		if chord := command_chord(it.cmd); chord != "" {
			plat.text_draw(gfx, t, chord, x0 + dw - sx(12) - f32(len(chord)) * cw, ty, UI_PX, MENU_COL.chord if on else MENU_COL.dim)
		}
		y += MENU_ITEM_H
	}
}

// Row index at client y within the open dropdown, or -1.
menu_item_at :: proc(app: ^App, my: f32) -> int {
	if app.menu.open < 0 {return -1}
	y := TAB_STRIP_H + MENU_BAR_H + sx(1)
	for it, i in menus[app.menu.open].items {
		ih := MENU_ITEM_H if it.cmd != .None else MENU_ITEM_H * 0.4
		if my >= y && my < y + ih {
			return i if it.cmd != .None else -1
		}
		y += ih
	}
	return -1
}

@(private = "file")
dropdown_w :: proc(t: ^plat.Text) -> f32 {
	cw := plat.text_char_width(t, UI_PX)
	widest := 0
	for m in menus {
		for it in m.items {
			if it.cmd == .None {continue}
			n := len(command_table[it.cmd].title) + len(command_chord(it.cmd)) + 8
			if n > widest {widest = n}
		}
	}
	return f32(widest) * cw
}
