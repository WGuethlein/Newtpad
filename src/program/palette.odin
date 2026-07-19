// Layer: program — the command palette (Ctrl+P): the universal access point. One
// overlay widget, three modes chosen by a leading prefix:
//   (none) fuzzy-switch open tabs
//   >      fuzzy-run a command from the command table
//   :      go to a line number
// Filter-as-you-type, Up/Down to move, Enter to run, Esc to close.
package main

import "core:slice"
import "core:strconv"
import "core:unicode/utf8"
import plat "src:platform"

Palette_Mode :: enum {
	Tabs,
	Commands,
	Goto,
}

Palette_Result :: struct {
	score: int,
	cmd:   Command_Id, // Commands mode
	slot:  int, // Tabs mode
}

Palette :: struct {
	active:   bool,
	mode:     Palette_Mode,
	query:    [dynamic]u8,
	results:  [dynamic]Palette_Result,
	selected: int,
}

// Case-insensitive subsequence match with fzf-style bonuses (consecutive run,
// word-boundary start). Greedy (good enough for tabs + a small command set); a
// non-match returns ok=false. Empty pattern matches everything at score 0.
@(private = "file")
fuzzy_score :: proc(pattern, text: string) -> (score: int, ok: bool) {
	if len(pattern) == 0 {return 0, true}
	pi := 0
	prev := -2
	for ti := 0; ti < len(text) && pi < len(pattern); ti += 1 {
		if lower_ascii(pattern[pi]) == lower_ascii(text[ti]) {
			s := 16
			if ti == prev + 1 {s += 8} // consecutive
			if ti == 0 || is_sep_ascii(text[ti - 1]) {s += 12} // word boundary
			score += s
			prev = ti
			pi += 1
		}
	}
	ok = pi == len(pattern)
	if !ok {score = 0}
	return
}

@(private = "file")
lower_ascii :: proc(b: u8) -> u8 {return b + 32 if b >= 'A' && b <= 'Z' else b}

@(private = "file")
is_sep_ascii :: proc(b: u8) -> bool {
	switch b {
	case ' ', '_', '-', '/', '.', '\\', ':':
		return true
	}
	return false
}

// Commands that make sense to run from the palette (not movement/typing/internal).
@(private = "file")
command_in_palette :: proc(cmd: Command_Id) -> bool {
	#partial switch cmd {
	case .None,
	     .Cursor_Left, .Cursor_Right, .Cursor_Up, .Cursor_Down, .Cursor_Home, .Cursor_End,
	     .Word_Left, .Word_Right, .Page_Up, .Page_Down, .Backspace, .Delete_Fwd, .Delete_Word_Back,
	     .Insert_Newline, .Clear_Selection,
	     .Palette_Open, .Palette_Close, .Palette_Confirm, .Palette_Next, .Palette_Prev, .Palette_Backspace,
	     .Find_Close, .Find_Backspace, .Find_Confirm, .Find_Field_Toggle, .Find_Toggle_Regex,
	     .Find_Toggle_Filter, .Find_Toggle_Replace_Mode, .Find_Filter_Page_Up, .Find_Filter_Page_Down:
		return false
	}
	return true
}

palette_open :: proc(app: ^App) {
	app.palette.active = true
	clear(&app.palette.query)
	palette_recompute(app)
}

palette_close :: proc(app: ^App) {
	app.palette.active = false
	clear(&app.palette.query)
	clear(&app.palette.results)
}

palette_input_rune :: proc(app: ^App, r: rune) {
	bytes, n := utf8.encode_rune(r)
	append(&app.palette.query, ..bytes[:n])
	palette_recompute(app)
}

palette_backspace :: proc(app: ^App) {
	q := &app.palette.query
	if len(q) == 0 {return}
	i := len(q) - 1
	for i > 0 && (q[i] & 0xC0) == 0x80 {i -= 1} // whole rune
	resize(q, i)
	palette_recompute(app)
}

palette_move :: proc(app: ^App, delta: int) {
	n := len(app.palette.results)
	if n == 0 {return}
	app.palette.selected = clamp(app.palette.selected + delta, 0, n - 1)
}

@(private = "file")
by_score :: proc(a, b: Palette_Result) -> bool {return a.score > b.score}

palette_recompute :: proc(app: ^App) {
	p := &app.palette
	clear(&p.results)
	p.selected = 0
	q := string(p.query[:])
	pat := q
	p.mode = .Tabs
	if len(q) > 0 && q[0] == '>' {
		p.mode = .Commands
		pat = q[1:]
	} else if len(q) > 0 && q[0] == ':' {
		p.mode = .Goto
		pat = q[1:]
	}

	switch p.mode {
	case .Commands:
		for cmd in Command_Id {
			if !command_in_palette(cmd) {continue}
			if s, ok := fuzzy_score(pat, command_table[cmd].title); ok {
				append(&p.results, Palette_Result{score = s, cmd = cmd})
			}
		}
		slice.sort_by(p.results[:], by_score)
	case .Tabs:
		for d, slot in app.docs {
			if d == nil {continue}
			if s, ok := fuzzy_score(pat, doc_display_name(d)); ok {
				append(&p.results, Palette_Result{score = s, slot = slot})
			}
		}
		slice.sort_by(p.results[:], by_score)
	case .Goto:
	// no list; Enter parses the number
	}
}

palette_draw :: proc(gfx: ^plat.Gfx, quad_pipe: ^plat.Quad_Pipeline, text: ^plat.Text, app: ^App, width, height: f32) {
	p := &app.palette
	PW := min(sx(720), width - sx(80))
	x0 := (width - PW) / 2
	y0 := sx(44)
	qh := sx(34)
	rowh := sx(26)
	nres := min(len(p.results), 12)
	boxh := qh + (rowh if p.mode == .Goto else f32(nres) * rowh)

	plat.quads_draw(gfx, quad_pipe, []plat.Quad {
			{pos = {x0 - sx(1), y0 - sx(1)}, size = {PW + sx(2), boxh + sx(2)}, color = {0.30, 0.34, 0.42, 1}}, // border
			{pos = {x0, y0}, size = {PW, boxh}, color = {0.11, 0.13, 0.17, 1}}, // body
			{pos = {x0, y0}, size = {PW, qh}, color = {0.15, 0.17, 0.22, 1}}, // query field
		})

	qs := string(p.query[:])
	qcol := [4]f32{0.92, 0.94, 0.98, 1}
	if len(qs) == 0 {
		qs = "Search tabs    ( >  command    :  go to line )"
		qcol = {0.45, 0.49, 0.57, 1}
	}
	plat.text_draw(gfx, text, qs, x0 + sx(12), y0 + sx(22), UI_PX, qcol)

	if p.mode == .Goto {
		plat.text_draw(gfx, text, "type a line number, then Enter", x0 + sx(16), y0 + qh + sx(17), UI_PX, {0.6, 0.64, 0.72, 1})
		return
	}

	for i in 0 ..< nres {
		ry := y0 + qh + f32(i) * rowh
		if i == p.selected {
			plat.quads_draw(gfx, quad_pipe, []plat.Quad{{pos = {x0, ry}, size = {PW, rowh}, color = {0.20, 0.28, 0.42, 1}}})
		}
		r := p.results[i]
		fg := [4]f32{0.95, 0.96, 0.99, 1} if i == p.selected else {0.80, 0.84, 0.90, 1}
		if p.mode == .Commands {
			plat.text_draw(gfx, text, command_table[r.cmd].title, x0 + sx(16), ry + sx(17), UI_PX, fg)
			cat := command_table[r.cmd].category
			plat.text_draw(gfx, text, cat, x0 + PW - sx(130), ry + sx(17), UI_SMALL_PX, {0.5, 0.54, 0.62, 1})
		} else if r.slot >= 0 && r.slot < len(app.docs) && app.docs[r.slot] != nil {
			plat.text_draw(gfx, text, doc_display_name(app.docs[r.slot]), x0 + sx(16), ry + sx(17), UI_PX, fg)
		}
	}
}

// Run the selected result (or the goto target), then close.
palette_execute :: proc(app: ^App, w: ^plat.Window, t: ^plat.Text, rows: int) {
	p := &app.palette
	switch p.mode {
	case .Commands:
		if p.selected < len(p.results) {
			cmd := p.results[p.selected].cmd
			palette_close(app)
			command_dispatch(cmd, {}, app, w, t, rows)
			return
		}
	case .Tabs:
		if p.selected < len(p.results) {
			slot := p.results[p.selected].slot
			palette_close(app)
			app_activate(app, slot)
			return
		}
	case .Goto:
		if n, ok := strconv.parse_int(string(p.query[1:])); ok && n > 0 {
			if d := app_active(app); d != nil {doc_goto_line(d, n)}
		}
	}
	palette_close(app)
}
