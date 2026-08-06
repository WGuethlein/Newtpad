// Layer: program — the command palette (Ctrl+P): the universal access point. One
// overlay widget, three modes chosen by a leading prefix:
//   (none) fuzzy-switch open tabs
//   >      fuzzy-run a command from the command table
//   :      go to a line number
// Filter-as-you-type, Up/Down to move, Enter to run, Esc to close.
package main

import "core:fmt"
import "core:slice"
import "core:strconv"
import "core:unicode/utf8"
import plat "src:platform"

Palette_Mode :: enum {
	Tabs,
	Commands,
	Goto,
	Help,
}

// `?` lists the prefixes. One reserved character is the cheapest way for a modal
// to teach its own grammar — otherwise the only way to discover `>` and `:` is
// to already know them.
@(private = "file")
PALETTE_HELP := []string {
	"(type)   switch between open tabs",
	">        run a command  (shows its shortcut)",
	":        go to a line number",
	"?        this list",
}

Palette_Result :: struct {
	score: int,
	used:  u32, // app.cmd_used at the time of the search; the tie-break
	cmd:   Command_Id, // Commands mode
	slot:  int, // Tabs mode
}

Palette :: struct {
	active:   bool,
	mode:     Palette_Mode,
	query:    [dynamic]u8,
	results:  [dynamic]Palette_Result,
	// THE KEYBOARD CURSOR. What Enter runs, and the only thing that does. Moves on
	// a key, on a click, and on a query change -- never on mouse movement.
	selected: int,
	// First result drawn, so a selection past the twelfth row scrolls into view
	// instead of disappearing. Resolved by palette_resolve_top through the layout,
	// which is the only place that decides it -- the draw and the hit-test read
	// l.top and never compute their own.
	top:      int,
	// WHERE THE POINTER IS, and nothing else: purely visual, -1 when the pointer is
	// off the list. Split from `selected` on 2026-08-04 because palette_hover runs
	// every frame off the LIVE cursor and used to write `selected` directly, so a
	// pointer resting anywhere over the list overwrote the keyboard cursor before
	// the next frame could draw it -- arrow keys did nothing at all, and Enter ran
	// whatever the mouse was lying on. UI spec 6's "two selection colours, two
	// states, two weights" is the same split, stated as appearance.
	hover:    int,
}

// Case-insensitive subsequence match with fzf-style bonuses (consecutive run,
// word-boundary start). Greedy (good enough for tabs + a small command set); a
// non-match returns ok=false. Empty pattern matches everything at score 0.
@(private = "file")
fuzzy_score :: proc(pattern, text: string) -> (score: int, ok: bool) {
	if len(pattern) == 0 {return 0, true}
	// An exact prefix outranks anything a subsequence can accumulate. UI spec 7:
	// "Exact prefix > word-start subsequence > anywhere." Typing "sav" should put
	// Save first rather than whichever longer command collects more
	// consecutive-run bonuses, which is what a pure fzf score does.
	if len(pattern) <= len(text) {
		pre := true
		for i in 0 ..< len(pattern) {
			if lower_ascii(pattern[i]) != lower_ascii(text[i]) {
				pre = false
				break
			}
		}
		if pre {score += 1000}
	}
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
command_in_palette :: proc(cmd: Command_Id) -> bool {
	// Movement, typing and pure plumbing are noise in a command list. The find
	// *toggles* are deliberately NOT excluded any more: hiding them meant regex
	// and filter-view appeared in no menu, no palette and no hint anywhere, so
	// the only way to learn Ctrl+L existed was to be told.
	#partial switch cmd {
	case .None,
	     .Cursor_Left, .Cursor_Right, .Cursor_Up, .Cursor_Down, .Cursor_Home, .Cursor_End,
	     .Word_Left, .Word_Right, .Page_Up, .Page_Down, .Backspace, .Delete_Fwd, .Delete_Word_Back,
	     .Insert_Newline, .Insert_Tab, .Clear_Selection,
	     .Palette_Open, .Palette_Close, .Palette_Confirm, .Palette_Next, .Palette_Prev, .Palette_Backspace,
	     .Find_Close, .Find_Backspace, .Find_Paste, .Find_Confirm, .Find_Field_Toggle,
	     .Find_Filter_Page_Up, .Find_Filter_Page_Down,
	     // Menu navigation verbs are plumbing, not commands a user runs.
	     .Menu_Close, .Menu_Next, .Menu_Prev, .Menu_Item_Next, .Menu_Item_Prev, .Menu_Activate, .Menu_Search_Back,
	     // Settings navigation likewise. Settings_Open stays — a real destination.
	     .Settings_Close, .Settings_Next, .Settings_Prev, .Settings_Toggle, .Settings_Inc, .Settings_Dec,
	     // Font page navigation; Font_Open stays listed.
	     .Font_Close, .Font_Next, .Font_Prev, .Font_Inc, .Font_Dec,
	     // History navigation likewise; History_Open stays.
	     .History_Close, .History_Next, .History_Prev, .History_Jump,
	     // Filter_Open supersedes it here: same key, but it opens find first
	     // instead of silently toggling a mode with no visible UI.
	     .Find_Toggle_Filter,
	     // The header menu's six sort rows act on app.menu.ctx_col, the column
	     // the menu was opened on -- the palette has no column to name, so
	     // none of these can mean anything run from here. A real cost, taken
	     // knowingly: multi-sort is not reachable from Ctrl+P.
	     //
	     // The same exclusion drops them from keys.txt's "commands with no
	     // default editor key" listing, which loops over command_in_palette
	     // (keymap.odin). That is the outcome we want, not a side effect worth
	     // undoing: a user-bound chord would have no menu behind it, so it
	     // would dispatch against whatever column the last context menu
	     // happened to leave in ctx_col -- which is why command_from_name
	     // (keymap.odin) separately refuses to bind one of these six at all,
	     // via command_needs_menu_target (commands.odin). Excluding them here
	     // only keeps them off the listing; closing the route is that check's job.
	     .Table_Sort_Asc, .Table_Sort_Desc, .Table_Sort_Then_Asc, .Table_Sort_Then_Desc,
	     .Table_Sort_Remove, .Table_Sort_Clear:
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
	p := &app.palette
	n := len(p.results)
	if n == 0 {return}
	p.selected = clamp(p.selected + delta, 0, n - 1)
	// Scroll follows the selection HERE, in the input phase, so the draw only ever
	// reads a settled offset. This is the fix for the audit's open HIGH: selected
	// clamped to n-1 while the draw emitted at most PALETTE_MAX_ROWS rows, so with
	// 62 commands the twelfth Down put the highlight on a row nobody could see --
	// and Enter still ran it.
	p.top = palette_resolve_top(p.top, p.selected, n, PALETTE_MAX_ROWS)
}

@(private = "file")
// Score first, then RECENCY. Two commands matching a short query equally well
// is the common case, not the exotic one -- "Save" and "Save As..." both score
// identically on "sav" -- and which of them you want is a question about you,
// not about the strings. UI spec 7: "a palette that learns beats a clever
// scorer."
by_score :: proc(a, b: Palette_Result) -> bool {
	if a.score != b.score {return a.score > b.score}
	return a.used > b.used
}

palette_recompute :: proc(app: ^App) {
	p := &app.palette
	clear(&p.results)
	p.selected = 0
	// Back to the top with it. A `top` left from a longer result set would strand
	// the narrowed list scrolled past its own end.
	p.top = 0
	// The row set is about to change under it, so an index into the OLD list points
	// at a different row now. palette_hover re-establishes it next frame if the
	// pointer is still over the list; leaving it stale draws a hover on a row the
	// pointer is not on. (menu_set_items has the same rule for menu.item.)
	p.hover = -1
	q := string(p.query[:])
	pat := q
	p.mode = .Tabs
	if len(q) > 0 && q[0] == '>' {
		p.mode = .Commands
		pat = q[1:]
	} else if len(q) > 0 && q[0] == ':' {
		p.mode = .Goto
		pat = q[1:]
	} else if len(q) > 0 && q[0] == '?' {
		p.mode = .Help
		pat = q[1:]
	}

	switch p.mode {
	case .Commands:
		for cmd in Command_Id {
			if !command_in_palette(cmd) {continue}
			// Don't offer a view the active file can't enter (an untitled buffer can
			// enter any; toggling OFF stays offered so you can always get back out).
			d := app_active(app)
			if cmd == .Toggle_Table && !doc_can_table(d) {continue}
			if cmd == .Toggle_Preview && !doc_can_markdown(d) {continue}
			if s, ok := fuzzy_score(pat, command_table[cmd].title); ok {
				append(&p.results, Palette_Result{score = s, used = app.cmd_used[cmd], cmd = cmd})
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
	case .Help:
	// static text; nothing to match
	}
}

PALETTE_MAX_ROWS :: 12

// The footer's resting state: what you can type here. Replaced by a live form
// (palette_draw) the moment a prefix is typed. Named so the draw and any test
// read the same string.
PALETTE_LEGEND :: ">  command   ·   :  go to line   ·   ?  help"

// The palette's geometry, computed once and consumed by the draw, the hit-test
// and the hover. Two expressions in two procs is how every seam bug in this
// codebase has started.
Palette_Layout :: struct {
	x0, y0, w, h: f32,
	qh, rowh:     f32, // query field height, row height
	hint:         f32, // the dimmed prefix-legend footer
	nres:         int, // result rows actually drawn
	// First result drawn. The list SCROLLS: nres caps how many rows fit, and
	// without a first-row offset the selection could move past the last drawn row
	// and vanish -- palette_move clamps to len(results)-1, the draw emitted
	// min(len(results), PALETTE_MAX_ROWS), and with 62 commands pressing Down
	// twelve times put the highlight on a row nobody could see while Enter still
	// ran it. Running an unseen command is the failure; the missing highlight was
	// only the symptom.
	top:          int,
}

// Scroll the minimum needed to keep `sel` inside a window of `max_rows`.
//
// PURE, and separate from the layout, so palettetest can drive it without a
// device -- the same split settings_resolve_top and menu_resolve_top already use.
// Clamped both ways: a `top` left over from a longer result set must not strand
// the list past its own end when the query narrows.
palette_resolve_top :: proc(top, sel, n, max_rows: int) -> int {
	if n <= max_rows {return 0}
	t := clamp(top, 0, n - max_rows)
	if sel < t {t = sel}
	if sel >= t + max_rows {t = sel - max_rows + 1}
	return clamp(t, 0, n - max_rows)
}

palette_layout :: proc(app: ^App, width, height: f32) -> Palette_Layout {
	p := &app.palette
	l: Palette_Layout
	// UI spec 7: "560 wide". Reached 2026-08-04, and only reachable at all because
	// the three sentence-length command titles came down the same day -- at 53
	// characters "Remove Duplicate Lines (exact match, keeps the first)" put the
	// floor near 700, which is where the old 720 came from.
	//
	// MEASURED, not assumed: palettetest computes the widest Commands row from the
	// command table and asserts the box fits it. 514 needed against 560 at the time
	// of writing, so there is 46px of headroom -- and if a future title eats it the
	// assertion fails rather than the row clipping silently.
	l.w = min(sx(560), width - sx(80))
	// snap: a centred origin is a division by two, and half of an odd number is
	// a half pixel -- which every glyph in the panel is then drawn from. See
	// snap()'s own comment for what that looks like on screen.
	l.x0 = snap((width - l.w) / 2)
	// UI spec 7: "top edge 88px below the window top". Not arbitrary and not a
	// taste call -- CHROME_TOP is TAB_STRIP_H (40) + MENU_BAR_H (30) = 70, so 88
	// clears the chrome by 18. At the old 44 the palette's top edge was INSIDE the
	// menu bar and drew over it.
	//
	// The WIDTH is deliberately left at 720 against the same line's 560. The 560 was
	// unreachable while three command titles ran to 37-53 characters; those came
	// down on 2026-08-04, but a palette row carries a label PLUS a category column
	// PLUS an accelerator column, and nobody has measured the new worst case. Do
	// that before narrowing it -- a clipped palette is worse than a wide one.
	l.y0 = sx(88)
	l.qh = sx(34)
	l.rowh = sx(26)
	l.nres = min(len(p.results), PALETTE_MAX_ROWS)
	// READ, not resolved: p.top is settled in the input phase (palette_move,
	// palette_recompute). Resolving it here would be scroll resolution inside
	// the draw, which CLAUDE.md forbids outright -- and menu_scroll_to_item is
	// already carrying that violation with a HANDOFF note owed against it.
	l.top = clamp(p.top, 0, max(0, len(p.results) - PALETTE_MAX_ROWS))
	// Every mode contributes its own height. Help draws a fixed list and produces
	// no results, so sizing purely off nres left its text outside the box.
	body_rows := f32(l.nres)
	switch p.mode {
	case .Goto:
		body_rows = 1
	case .Help:
		body_rows = f32(len(PALETTE_HELP))
	case .Tabs, .Commands:
	}
	// The prefix legend is a dimmed FOOTER row, per the 7 mockup, not a caption
	// inside the input. The mockup shows it while a query is being typed, so it is
	// permanent rather than an empty-state placeholder -- which is also what makes
	// it discoverable, since the caption it replaces vanished the moment you typed.
	l.hint = l.rowh
	l.h = l.qh + body_rows * l.rowh + l.hint
	return l
}

// Result row at client (x, y), or -1. Only the result list is clickable; the
// query field and the Goto/Help bodies are not rows.
palette_row_at :: proc(app: ^App, mx, my, width, height: f32) -> int {
	p := &app.palette
	if !p.active || (p.mode != .Tabs && p.mode != .Commands) {return -1}
	l := palette_layout(app, width, height)
	if mx < l.x0 || mx >= l.x0 + l.w {return -1}
	top := l.y0 + l.qh
	if my < top {return -1} // the query field, not a row
	i := int((my - top) / l.rowh)
	if i < 0 || i >= l.nres {return -1}
	// SCREEN row + scroll offset = RESULT index. Returning `i` alone meant a
	// click on the first visible row always picked result 0, whatever was
	// scrolled to -- the same divergence in the other direction.
	return l.top + i
}

// Highlight the row under the pointer. Live cursor, not win.mouse_y, which only
// updates while a button is held.
palette_hover :: proc(app: ^App, win: ^plat.Window, width, height: f32) {
	if !app.palette.active {return}
	cx, cy := plat.window_cursor_client(win)
	// Writes `hover` ONLY. It used to write `selected`, which is why arrow keys
	// were inert: this runs every frame from the live cursor.
	app.palette.hover = palette_row_at(app, f32(cx), f32(cy), width, height)
}

// Click inside the palette. Returns whether the click was consumed and whether
// it chose a result (the caller runs it, so the palette needn't know how).
palette_click :: proc(app: ^App, mx, my, width, height: f32) -> (chose: bool, consumed: bool) {
	if !app.palette.active {return false, false}
	l := palette_layout(app, width, height)
	inside := mx >= l.x0 && mx < l.x0 + l.w && my >= l.y0 && my < l.y0 + l.h
	if !inside {
		palette_close(app) // click-away dismisses, as it always did
		return false, true
	}
	if r := palette_row_at(app, mx, my, width, height); r >= 0 {
		app.palette.selected = r
		return true, true
	}
	return false, true // inside the box but not on a row: swallow, stay open
}

// The widest category and accelerator in the whole command table, in cells.
//
// Measured across the table rather than per row so the two right-hand columns
// are FIXED: they must not shift as the result list changes under the caret,
// and the accelerators have to line up vertically or the mono face they are
// drawn in is buying nothing. Computed once and cached -- the table is a
// compile-time constant, so this can never go stale.
@(private = "file")
g_cat_cells, g_chord_cells: int

// The denominator of the mockup's "4 of 62": how many candidates the CURRENT mode
// could offer before the query narrowed them. Commands counts what the palette is
// willing to show (command_in_palette, not the whole table -- offering a number
// that includes rows you can never reach would be a lie); Tabs counts live tabs.
palette_total :: proc(app: ^App) -> int {
	n := 0
	switch app.palette.mode {
	case .Commands:
		for c in Command_Id {
			if command_in_palette(c) {n += 1}
		}
	case .Tabs:
		n = app_live_count(app)
	case .Goto, .Help:
	}
	return n
}

palette_widest_category :: proc() -> int {
	if g_cat_cells == 0 {
		for c in Command_Id {
			if n := len(command_table[c].category); n > g_cat_cells {g_cat_cells = n}
		}
	}
	return g_cat_cells
}

palette_widest_chord :: proc() -> int {
	if g_chord_cells == 0 {
		for c in Command_Id {
			if n := len(command_chord(c)); n > g_chord_cells {g_chord_cells = n}
		}
	}
	return g_chord_cells
}

// Draw `label`, accenting the characters the query matched.
//
// The match is recomputed here rather than carried on the result, because the
// ranking already walks the same subsequence and storing per-character flags
// would make Palette_Result variable-sized for a purely visual concern. Same
// left-to-right subsequence walk the filter uses, so what lights up is exactly
// what matched.
palette_draw_match :: proc(gfx: ^plat.Gfx, text: ^plat.Text, label, query: string, x, y: f32, fg: [4]f32) {
	if query == "" {
		plat.text_draw(gfx, text, label, x, y, UI_PX, fg)
		return
	}
	// RUNES, not bytes. This walked `0 ..< len(label)` and drew `label[i:i+1]`,
	// which is one BYTE -- so a multi-byte rune became several invalid one-byte
	// draws and rendered as that many replacement boxes. It went unnoticed while
	// every command title was ASCII, and appeared the moment six of them took a
	// real ellipsis in v0.74.0: "Save As…" drew as "Save As???" in the palette
	// while the menus, which draw the label in one call, were fine.
	//
	// The MATCH stays byte-wise over ASCII, which is correct rather than a
	// shortcut: `query` is ascii_lower'd, so only an ASCII rune can ever match,
	// and a multi-byte rune simply never lights up.
	cw := plat.text_char_width(text, UI_PX)
	qi := 0
	col := 0
	for r, bi in label {
		hit := false
		if r < 0x80 && qi < len(query) && ascii_lower(u8(r)) == ascii_lower(query[qi]) {
			hit = true
			qi += 1
		}
		n := utf8.rune_size(r)
		plat.text_draw(gfx, text, label[bi:bi + n], x + f32(col) * cw, y, UI_PX, g_theme[.Accent] if hit else fg)
		// Cells, not runes: a full-width codepoint occupies two. Chrome labels are
		// Latin today, but the advance has to come from the same place the editor's
		// does or a CJK command name would overlap its own next glyph.
		col += plat.text_cell_width_at(text, r, col, .UI)
	}
}

@(private = "file")
ascii_lower :: proc(c: u8) -> u8 {return c + 32 if c >= 'A' && c <= 'Z' else c}

palette_draw :: proc(gfx: ^plat.Gfx, quad_pipe: ^plat.Quad_Pipeline, text: ^plat.Text, app: ^App, width, height: f32) {
	p := &app.palette
	l := palette_layout(app, width, height)
	PW, x0, y0, qh, rowh, nres := l.w, l.x0, l.y0, l.qh, l.rowh, l.nres
	boxh := l.h

	plat.quads_draw(gfx, quad_pipe, []plat.Quad {
			{pos = {x0 - sx(1), y0 - sx(1)}, size = {PW + sx(2), boxh + sx(2)}, color = g_theme[.Border_Strong]}, // border
			{pos = {x0, y0}, size = {PW, boxh}, color = g_theme[.Bg_Base]}, // body
			{pos = {x0, y0}, size = {PW, qh}, color = g_theme[.Bg_Panel]}, // query field
		})

	// THE PROMPT, then the query. The 7 mockup's input row is `> wrap |` -- a
	// prompt glyph in the accent and the query beside it. It used to hold a caption
	// ("Search tabs ( > command : go to line ? help )") which is not what an input
	// field is for and which vanished the moment you typed; the legend is a footer
	// row now, so it is there when you need it rather than only before you start.
	cwq := plat.text_char_width(text, UI_PX)
	plat.text_draw(gfx, text, ">", x0 + sx(12), y0 + sx(22), UI_PX, g_theme[.Accent])
	plat.text_draw(gfx, text, string(p.query[:]), x0 + sx(12) + 2 * cwq, y0 + sx(22), UI_PX, g_theme[.Text_Primary])
	// The result count, in the input row. UI spec 7: "it is feedback on what was
	// just typed and belongs next to the caret", not 700 pixels away in the
	// status bar.
	//
	// "N of M", not a bare N -- the mockup reads `4 of 62`, and the denominator is
	// what makes the numerator mean anything: 4 of 62 says the filter is working,
	// 4 alone could be the whole product.
	if len(p.query) > 0 && (p.mode == .Commands || p.mode == .Tabs) {
		n := fmt.tprintf("%d of %d", len(p.results), palette_total(app))
		cw := plat.text_char_width(text, UI_SMALL_PX)
		col := g_theme[.Text_Muted] if len(p.results) > 0 else g_theme[.Danger]
		plat.text_draw(gfx, text, n, x0 + PW - sx(16) - f32(len(n)) * cw, y0 + sx(22), UI_SMALL_PX, col)
	}
	// The footer. A LIVE FORM once a prefix is typed, not a static legend.
	//
	// §7's mockup renders it as three runs -- the prefix, what you have typed after
	// it, then the hint -- e.g. `: 124  go to line · type a number`. The legend
	// answers "what can I type here"; once you have answered that yourself it
	// should tell you what THIS is going to do, and echo the argument so a
	// mistyped number is visible without looking back up at the input.
	{
		fx := x0 + sx(12)
		fy := y0 + boxh - sx(9)
		cwf := plat.text_char_width(text, UI_SMALL_PX)
		q := string(p.query[:])
		if p.mode != .Tabs && len(q) > 0 {
			// The prefix in the accent, the argument in primary text, the hint
			// dimmed -- the mockup's three colours, in its order.
			pre := q[:1]
			arg := q[1:]
			hint := ""
			switch p.mode {
			case .Goto:
				hint = "go to line · type a number"
			case .Commands:
				hint = "command · type to filter"
			case .Help:
				hint = "help"
			case .Tabs:
			}
			plat.text_draw(gfx, text, pre, fx, fy, UI_SMALL_PX, g_theme[.Accent])
			fx += f32(len(pre) + 1) * cwf
			if arg != "" {
				plat.text_draw(gfx, text, arg, fx, fy, UI_SMALL_PX, g_theme[.Text_Primary])
				fx += f32(len(arg) + 2) * cwf
			}
			plat.text_draw(gfx, text, hint, fx, fy, UI_SMALL_PX, g_theme[.Text_Muted])
		} else {
			plat.text_draw(gfx, text, PALETTE_LEGEND, fx, fy, UI_SMALL_PX, g_theme[.Text_Muted])
		}
	}

	if p.mode == .Goto {
		plat.text_draw(gfx, text, "type a line number, then Enter", x0 + sx(16), y0 + qh + sx(17), UI_PX, g_theme[.Text_Muted])
		return
	}
	if p.mode == .Help {
		for h, i in PALETTE_HELP {
			plat.text_draw(gfx, text, h, x0 + sx(16), y0 + qh + f32(i) * rowh + sx(17), UI_PX, g_theme[.Text_Secondary])
		}
		return
	}

	for vis in 0 ..< nres {
		// `vis` is the row on screen; `i` is which result it is.
		i := l.top + vis
		if i >= len(p.results) {break}
		ry := y0 + qh + f32(vis) * rowh
		// Two states, two weights -- but NOT the menu's two weights.
		//
		// v0.68.0 gave this row the accent fill with bg_base text, which is UI spec
		// 6's rule for MENUS applied to a surface 7 never asks it of. The 7 mockup
		// shows the selected row as a subtle RAISED fill; the 6 mockup does show the
		// accent (its `Settings` row), so the rule is right where it came from and
		// was wrong where it was taken. Reverted 2026-08-04.
		//
		// The palette is a list you are reading while typing, and a full-strength
		// accent bar sweeping down it on every keystroke is a different thing from a
		// menu's one deliberate highlight.
		if i == p.selected {
			plat.quads_draw(gfx, quad_pipe, []plat.Quad{{pos = {x0, ry}, size = {PW, rowh}, color = g_theme[.Bg_Raised]}})
		} else if i == p.hover {
			plat.quads_draw(gfx, quad_pipe, []plat.Quad{{pos = {x0, ry}, size = {PW, rowh}, color = g_theme[.Bg_Hover]}})
		}
		r := p.results[i]
		fg := g_theme[.Text_Primary] if i == p.selected else g_theme[.Text_Secondary]
		if p.mode == .Commands {
			// The label, with the matched characters in the accent. UI spec 7:
			// "Matched characters carry the accent -- that is the whole ranking
			// display. No second colour, no bold, no score bar."
			title := command_table[r.cmd].title
			palette_draw_match(gfx, text, title, string(p.query[:]), x0 + sx(16), ry + sx(17), fg)

			// Category and accelerator, both RIGHT-aligned into fixed columns.
			//
			// The category used to be drawn left-aligned at a fixed 130px from the
			// right edge while the accelerator was right-aligned, so the gap
			// between them was whatever the category's length left over -- a long
			// one ran up against the shortcut and a short one floated. UI spec 7
			// names it: "the two columns are different sizes and neither aligns
			// with the label". Wyatt's screenshot has "CursorCtrl+Home".
			//
			// Both columns are sized from the WIDEST value in the table, not from
			// this row's, so neither column moves as you type and the accelerators
			// line up down the list -- which is the reason they are drawn in the
			// mono face at all.
			cw := plat.text_char_width(text, UI_SMALL_PX)
			chord_col := f32(palette_widest_chord()) * cw
			cat_col := f32(palette_widest_category()) * cw
			chord_x := x0 + PW - sx(16) - chord_col
			cat_x := chord_x - sx(16) - cat_col
			cat := command_table[r.cmd].category
			plat.text_draw(gfx, text, cat, cat_x + (cat_col - f32(len(cat)) * cw), ry + sx(17), UI_SMALL_PX, g_theme[.Text_Muted])
			if chord := command_chord(r.cmd); chord != "" {
				plat.text_draw(gfx, text, chord, chord_x + (chord_col - f32(len(chord)) * cw), ry + sx(17), UI_SMALL_PX, g_theme[.Text_Muted])
			}
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
	case .Help:
	// Enter just dismisses the help list.
	}
	palette_close(app)
}
