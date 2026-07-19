// Layer: program — the undo history panel: every recorded state, with the
// ability to jump to one, the way Photoshop's History palette works rather than
// only stepping with Ctrl+Z.
//
// The buffer already made this cheap: doc.undo holds cloned piece trees, so
// every past state is already materialised and a jump is a walk of tree swaps,
// not a re-application of edits. See doc_history_goto.
package main

import "core:fmt"
import plat "src:platform"

HISTORY_ROW_96 :: f32(22)
HISTORY_W_96 :: f32(300)
HISTORY_ROW := HISTORY_ROW_96
HISTORY_W := HISTORY_W_96

History_State :: struct {
	open: bool,
	sel:  int, // highlighted row
	// First visible row. A stored scroll offset, not derived from `sel`:
	// centring on the selection would make the list chase the pointer, since
	// hovering sets the selection. It moves only when the selection would
	// otherwise leave the view.
	top:  int,
	rows: int, // rows drawn last frame; hit-testing needs the same number
}

history_open :: proc(app: ^App) {
	d := app_active(app)
	app.history.open = true
	app.history.sel = doc_history_current(d) if d != nil else 0
	app.history.top = 0 // draw clamps this to bring the selection into view
	app.history.rows = 0
}

history_close :: proc(app: ^App) {app.history.open = false}

history_move :: proc(app: ^App, delta: int) {
	d := app_active(app)
	if d == nil {return}
	app.history.sel = clamp(app.history.sel + delta, 0, doc_history_len(d) - 1)
}

// Jump the document to the highlighted state. The panel stays open so you can
// keep scrubbing, which is the point of having a list rather than a stack.
history_activate :: proc(app: ^App) {
	d := app_active(app)
	if d == nil {return}
	doc_history_goto(d, app.history.sel)
}

// Move the highlight to the row under the pointer. Uses the live cursor, not
// win.mouse_y: WM_MOUSEMOVE only records a position while a button is held, so
// the stored one is wherever the last click landed.
history_hover_update :: proc(app: ^App, win: ^plat.Window, width: f32) {
	if !app.history.open {return}
	cx, cy := plat.window_cursor_client(win)
	if r := history_row_at(app, f32(cx), f32(cy), width); r >= 0 {
		app.history.sel = r
	}
}

// History index at client (x, y), or -1. Accounts for the scroll offset: the
// row drawn k places down is entry top+k, not entry k.
history_row_at :: proc(app: ^App, mx, my, width: f32) -> int {
	d := app_active(app)
	if d == nil || !app.history.open {return -1}
	x0 := width - HISTORY_W - SCROLLBAR_W
	if mx < x0 || mx >= width - SCROLLBAR_W {return -1}
	y := CONTENT_TOP + sx(28)
	// Reject above the first row explicitly: integer division truncates toward
	// zero, so a small negative offset yields row 0 rather than -1.
	if my < y {return -1}
	k := int((my - y) / HISTORY_ROW)
	if k < 0 || k >= app.history.rows {return -1}
	i := app.history.top + k
	if i < 0 || i >= doc_history_len(d) {return -1}
	return i
}

history_draw :: proc(gfx: ^plat.Gfx, qp: ^plat.Quad_Pipeline, t: ^plat.Text, app: ^App, width, height: f32) {
	d := app_active(app)
	if d == nil {return}
	n := doc_history_len(d)
	cur := doc_history_current(d)

	x0 := width - HISTORY_W - SCROLLBAR_W
	y0 := CONTENT_TOP
	// Clamp to the window: the panel is a client-space quad, not a popup, so a
	// long history must scroll rather than run off the bottom.
	max_rows := max(1, int((height - y0 - sx(36)) / HISTORY_ROW))
	// Scroll the minimum needed to keep the selection visible. Recentring on it
	// every frame would drag the list under the pointer while hovering.
	if app.history.sel < app.history.top {app.history.top = app.history.sel}
	if app.history.sel >= app.history.top + max_rows {app.history.top = app.history.sel - max_rows + 1}
	app.history.top = clamp(app.history.top, 0, max(0, n - max_rows))
	first := app.history.top
	shown := min(max_rows, n - first)
	app.history.rows = shown // hit-testing must use the count actually drawn
	h := sx(28) + f32(shown) * HISTORY_ROW + sx(8)

	plat.quads_draw(gfx, qp, []plat.Quad {
			{pos = {x0 - sx(1), y0}, size = {HISTORY_W + sx(2), h + sx(2)}, color = {0.30, 0.34, 0.42, 1}},
			{pos = {x0, y0 + sx(1)}, size = {HISTORY_W, h}, color = {0.12, 0.14, 0.19, 1}},
		})
	plat.text_draw(gfx, t, "History", x0 + sx(12), y0 + sx(19), UI_PX, {0.92, 0.94, 0.98, 1})
	if n > max_rows {
		plat.text_draw(gfx, t, fmt.tprintf("%d of %d", app.history.sel + 1, n), x0 + HISTORY_W - sx(80), y0 + sx(19), UI_SMALL_PX, {0.50, 0.55, 0.64, 1})
	}

	y := y0 + sx(28)
	for i in first ..< first + shown {
		if i == app.history.sel {
			plat.quads_draw(gfx, qp, []plat.Quad{{pos = {x0, y}, size = {HISTORY_W, HISTORY_ROW}, color = {0.20, 0.28, 0.42, 1}}})
		}
		// States after the current one are the redo stack: reachable, but not
		// where the document is. Dim them so the present is obvious.
		col := [4]f32{0.88, 0.91, 0.96, 1}
		if i > cur {col = {0.48, 0.52, 0.60, 1}}
		if i == cur {col = {0.55, 0.85, 0.60, 1}}
		mark := "▸ " if i == cur else "  "
		plat.text_draw(gfx, t, fmt.tprintf("%s%s", mark, doc_history_label(d, i)), x0 + sx(10), y + HISTORY_ROW - sx(6), UI_SMALL_PX, col)
		y += HISTORY_ROW
	}
	plat.text_draw(gfx, t, "Up/Down + Enter to jump    Esc closes", x0 + sx(10), y + sx(12), UI_SMALL_PX, {0.45, 0.49, 0.57, 1})
}
