// Layer: program — wires the layers together and owns the frame loop. The main
// thread builds UI and handles input only: drain events, update the document,
// draw the viewport, present. Headless argv test modes live in test_modes.odin.
package main

import "base:runtime"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:time"
import base "src:base"
import plat "src:platform"

// Drain a batch of paths handed over by another instance or dropped onto the
// window: open each as a tab (app_open_path activates an existing tab if the
// file is already open, so re-opening one just focuses it), skip directories
// with a status-bar note, and focus the FIRST successfully opened tab rather
// than the last — the natural read order for a multi-file Explorer drop.
// Exported as its own proc (not inlined in the frame loop) so droptest drives
// the exact code the frame loop runs, rather than a parallel copy of it.
app_consume_open_requests :: proc(a: ^App, paths: []string) {
	first := -1
	folders := 0
	unreadable := 0
	for p in paths {
		if plat.path_is_directory(p) {
			folders += 1
			continue // a folder is not a document; project trees are out of scope
		}
		if !app_open_path(a, p) {
			fmt.eprintfln("Newtpad: could not open %q", p)
			unreadable += 1
			continue
		}
		if first < 0 {first = a.active}
	}
	if first >= 0 {app_activate(a, first)} // focus the first, not the last
	if folders > 0 || unreadable > 0 {
		// [BRACKETED CAPS] matches the status line's other loud conditions
		// ([CHANGED ON DISK ...], [GLYPH CACHE FULL ...]) -- this is the same
		// class of message and should read as one. Folders and unreadable files
		// are counted separately: they are different problems, and one message
		// covering both made the user guess which had happened.
		if folders > 0 && unreadable > 0 {
			app_note(a, fmt.tprintf("[FOLDERS NOT OPENED - %d folder%s skipped (Newtpad opens files, not folders); %d file%s could not be read]", folders, "" if folders == 1 else "s", unreadable, "" if unreadable == 1 else "s"))
		} else if folders > 0 {
			app_note(a, fmt.tprintf("[FOLDERS NOT OPENED - %d folder%s skipped. Newtpad opens files, not folders]", folders, "" if folders == 1 else "s"))
		} else {
			app_note(a, fmt.tprintf("[FILE NOT OPENED - %d file%s could not be read]", unreadable, "" if unreadable == 1 else "s"))
		}
	}
}

main :: proc() {
	plat.seh_install() // arm the mapped-read fault guard before any file opens

	if len(os.args) > 1 && (os.args[1] == "--version" || os.args[1] == "-v" || os.args[1] == "version") {
		fmt.println("Newtpad", NEWTPAD_VERSION) // console builds only; the GUI shows it in Settings
		return
	}

	if test_mode_dispatch() {return} // headless argv modes (see test_modes.odin)

	// Logging + crash handling, armed before the window so an init-time fault is
	// still caught. The assertion proc is set on this context so it propagates to
	// the whole frame loop (Odin context flows down the call tree).
	diag_init()
	context = diag_context() // the hook propagates down the whole frame loop from here
	defer diag_shutdown()

	// Open the file given on the command line; with no argument, start empty.
	path := ""
	if len(os.args) > 1 {
		path = os.args[1]
	}

	// One instance per user: a second launch hands its file to the running window
	// and exits, so only one process owns the session file and backups. If the
	// hand-off fails (owner starting up or shutting down) we run normally rather
	// than lose the file — see the primary check on session save below.
	primary := plat.instance_claim()
	if !primary && plat.instance_send_open(path) {
		return
	}

	window := plat.window_create("Newtpad", 1280, 720)

	gfx, ok := plat.gfx_init(window)
	if !ok {
		fmt.eprintln("Newtpad: failed to initialize graphics")
		return
	}

	text, tok := plat.text_init(&gfx)
	if !tok {
		fmt.eprintln("Newtpad: failed to initialize text pipeline")
		return
	}

	quad_pipe, qok := plat.quads_init(&gfx)
	if !qok {
		fmt.eprintln("Newtpad: failed to initialize quad pipeline")
		return
	}

	session_sweep_tmp() // clear orphan atomic-write temp files from a prior crash

	// Restore the session FIRST, then open any file from the command line as an
	// extra tab. Opening a file used to skip the restore entirely, and the exit
	// save then deleted every backup the (single-tab) session didn't reference —
	// so launching Newtpad on a file destroyed unsaved scratch buffers. The
	// single-instance hand-off already appends a tab rather than replacing the
	// session, so this also makes both launch paths behave the same.
	app: App
	menu_init(&app.menu) // before any frame: the zero value means "File is open"
	app.settings = settings_load()
	// The user keymap overlay, before any frame can resolve a key. A missing or
	// unreadable keys.txt leaves the defaults in force (keymap.odin).
	keymap_load()
	defer keymap_reset()
	// The colour rules, before any frame can draw a row. A missing or unreadable
	// rules.txt leaves no rules active (rules.odin).
	rules_load()
	defer rules_reset()
	had_session := primary && session_exists()
	// Restore is opt-out. Note the sweep guard below still protects the backups
	// when it is off: they belong to tabs we chose not to adopt, so turning
	// restore off hides the old session rather than destroying it.
	restored := primary && app.settings.restore_session && session_restore(&app)
	// A session we couldn't load still owns its backups; don't sweep them.
	session_can_sweep := !had_session || restored
	// The crash handler saves the user's work; give it the App and the same
	// sweep policy the exit save uses (but it always saves with sweep off).
	diag_bind_app(&app, primary, session_can_sweep)
	if path != "" {
		if !app_open_path(&app, path) {
			fmt.eprintfln("Newtpad: could not open %q", path)
		}
	}
	if app_live_count(&app) == 0 {
		app_new_scratch(&app) // never fail to a closed window
	}
	defer app_destroy(&app)

	// Load the saved theme choice. The zero-initialized Theme is transparent
	// black, making every themed surface invisible without this assignment --
	// theme_resolve always returns a fully-populated theme, falling back to
	// theme_dark() for "Dark", an empty/corrupt settings.txt, or any name
	// settings_load already rejected as unrecognized (see its "theme_name"
	// case), so this can never leave g_theme at the zero value.
	g_theme = theme_resolve(app.settings.theme_name)

	// The renderer is reusable so the WM_SIZE handler can repaint live during a
	// window resize (the OS runs a modal loop that otherwise freezes this one).
	rc := Render_Ctx{&gfx, &text, &quad_pipe, &app, window, 0, 0, 0}
	active_render_ctx = &rc
	BASE_PX = f32(clamp(app.settings.font_size, FONT_SIZE_MIN, FONT_SIZE_MAX))
	// Before the first frame: text_load_faces left the platform default (4) in
	// place, and nothing else reads the saved value on this path -- settings_apply
	// only runs when a setting is CHANGED.
	plat.text_set_tab_width(&text, app.settings.tab_width)
	// Apply the saved font before the first frame. A family that is no longer
	// installed leaves the default in place rather than failing to start.
	if app.settings.font_family != "" && app.settings.font_family != "Consolas" {
		plat.text_load_family(&text, app.settings.font_family, app.settings.font_style)
	} else if app.settings.font_style != .Regular {
		plat.text_load_family(&text, "Consolas", app.settings.font_style)
	}
	// The chrome's family, on the .UI set. Same failure rule as the document's
	// above -- a family that is no longer installed leaves Consolas in place
	// rather than stopping the app -- and deliberately a SEPARATE call, because
	// the whole point of Font_Set is that these two never move together.
	if app.settings.ui_font_family != "" && app.settings.ui_font_family != "Consolas" {
		plat.text_load_family(&text, app.settings.ui_font_family, .Regular, .UI)
	}
	metrics_recompute(&rc)
	window.on_resize = on_resize
	window.resize_user = &rc
	// Both callbacks take rc: a DPI change has to update the layout metrics and
	// re-rasterize glyphs BEFORE the window resizes, because that resize sends a
	// nested WM_SIZE which repaints through on_resize.
	window.on_dpi = on_dpi
	window.dpi_user = &rc
	// (metrics_recompute above already set window.titlebar_h, which the NC
	// hit-test needs valid before the first render.)

	// Watch open files for external changes (see watch.odin).
	watcher: Watcher
	watcher_start(&watcher)
	defer watcher_stop(&watcher)
	disk_changes: [dynamic]Watch_Entry
	defer delete(disk_changes)

	// Debounced session autosave: save ~2s after input settles (crash safety).
	session_dirty := false
	last_input := time.tick_now()
	scrollbar_drag := false
	hscrollbar_drag := false
	md_preview_drag := false
	divider_drag := false // dragging the Markdown Split divider (md_divider_rect)
	sel_dragging := false // a text-selection drag has begun (pointer moved since press)
	press_x, press_y: i32 // client pos of the press that may become a drag
	// Column-select drag (Alt+drag). Four inline latches until the
	// whole-branch review's LOW 7 folded them into one struct next to the two
	// procedures that consume them -- see Block_Drag (block.odin) for what
	// each field latches and why. Behaviour is unchanged; this is the same
	// three assignments at the press and the same one call per drag frame.
	block_drag: Block_Drag

	for !window.should_close {
		// Sleep when idle instead of spinning at vsync (which pinned a core the whole
		// time the app was open). Keep spinning only for the one thing that needs a
		// frame with no incoming message: a held drag auto-scrolling past an edge.
		// Otherwise block on the message queue — waking instantly on any input — with
		// a short timeout while a worker is publishing (so indexing/search/autosave
		// still tick), and a long one when there is nothing to poll (so a file changed
		// on disk still surfaces within the watcher's own ~1 s cadence).
		if !(window.mouse_down || app.tab_drag) {
			d0 := app_active(&app)
			// update_running is in here so a finished check is picked up within
			// 200 ms rather than sitting until the next keypress -- the app is
			// idle by definition while the user waits for the answer.
			polling := session_dirty || !doc_index_done(d0) || search_running(d0) || scrollbar_drag || hscrollbar_drag || update_running(&app.update)
			plat.window_wait_message(window, 200 if polling else 1000)
		}
		plat.window_pump_events(window)

		// Re-read the layout metrics every frame: a DPI change rewrites them via
		// on_dpi, and the whole frame -- hit-testing included -- must use the new
		// values, not ones captured before the loop.
		px, char_w, line_h := rc.px, rc.char_w, rc.line_h
		window.dpi_changed = false

		if window.char_count > 0 || window.key_count > 0 || window.mouse_pressed || window.mouse_middle_pressed {
			session_dirty = true
			last_input = time.tick_now()
		}

		// Files handed over by other launches (Explorer double-click) or dropped
		// onto the window (WM_DROPFILES; see platform/window.odin) share this one
		// queue. app_consume_open_requests is also called directly by droptest —
		// same code path, not a parallel copy — so that mode actually exercises
		// what the frame loop runs.
		if window.open_count > 0 {
			reqs: [plat.OPEN_QUEUE]string
			app_consume_open_requests(&app, reqs[:plat.window_open_requests(window, reqs[:])])
			plat.window_clear_open_requests(window)
			session_dirty = true
		}

		if window.resized {
			plat.gfx_resize(&gfx, window.width, window.height)
			window.resized = false
		}
		doc := app_active(&app)
		// The filter banner (Ctrl+L) insets the content top; set it before any
		// row math this frame so the rows, hit-test and count agree.
		doc_update_top_inset(doc)
		// Two row budgets, and which one a consumer gets is load-bearing.
		//
		// `rows` is the FULLY visible count: everything that reasons about
		// reachability takes it -- the scroll clamp, the page keys, the wheel,
		// doc_filter_max_top, doc_max_hscroll -- so paging never advances by a
		// sliver.
		//
		// `drawn` adds the partial last row, and goes to the DRAW and the
		// HIT-TEST. A half-visible line is on screen, so it must be
		// clickable; before this there was a full row's worth of dead space at
		// the bottom of the viewport (Wyatt, live use). See doc_drawn_rows.
		//
		// doc_ensure_cursor_visible takes BOTH: `drawn` decides whether the
		// caret already counts as on screen (it must agree with doc_pos_at, or
		// a click on the partial row scrolls the view out from under itself --
		// that was a live regression, not a hypothetical); `rows` still decides
		// where the caret lands once an actual scroll is needed, so it parks on
		// the last WHOLLY visible row rather than the partial one.
		//
		// The GRID view takes NEITHER. It used to take `rows`, on the reasoning
		// that "table_draw has its own header/row geometry, and splitting a
		// layout this task does not otherwise touch is how the two halves of a
		// widget end up one row apart" -- but §10's geometry is now genuinely
		// different (a 30px sticky header band above 26px rows, neither of them
		// the editor's line_height), so `rows` over-counts the grid outright.
		// Over-counting is not benign in either direction it reaches: it feeds
		// doc_scroll's clamp, so doc_max_top would stop the wheel short of the
		// last line, and it bounds the CELL HIT-TEST, so a press in the dead
		// strip below the last drawn row would resolve to a row and start editing
		// it. `trows` is the grid's budget, from the same producer table_draw
		// positions its rows with.
		rows := doc_visible_rows(doc, f32(window.height), line_h)
		drawn := doc_drawn_rows(doc, f32(window.height), line_h)
		trows := table_visible_rows(doc, f32(window.height), px)
		// The vertical scroll model's count: `trows` in the grid, `rows`
		// everywhere else. Equal to `rows` for every non-grid document, so this
		// changes nothing outside table view -- see doc_scroll_rows for why the
		// scrollbar, its drag and the wheel cannot be allowed to differ.
		srows := doc_scroll_rows(doc, f32(window.height), line_h, px)
		// Usable content width in cells (word wrap breaks here).
		doc_update_gutter(doc, char_w) // before view_cols: the gutter narrows the text
		doc.view_cols = doc_view_cols(doc_editor_right(doc, f32(window.width), app.settings.split_frac), char_w)
		doc.view_rows = rows
		// Horizontal scroll: clamp to real content, then mirror into H_SCROLL for
		// this frame so the whole frame's column geometry agrees. This is the
		// one call per frame to the MUTATING scan (doc_update_max_hscroll) --
		// it runs here, in the update phase, before render_frame, so every
		// later read this frame (the wheel below, hscroll_model, the draw) can
		// use the pure doc_max_hscroll and see a value already current for
		// this frame without re-scanning or mutating from the draw path.
		doc.h_scroll = clamp(doc.h_scroll, 0, doc_update_max_hscroll(doc, &text, rows))
		doc_update_hscroll(doc)
		// Re-center on the caret only when it actually moves on THIS tab — never
		// after a wheel/page scroll (which leaves the caret put) or a tab switch.
		active_before := app.active
		cursor_before := doc.cursor

		// Drain input once per frame: typed characters route to the find field or
		// the document; key chords resolve to a command in the active context.
		for i in 0 ..< window.char_count {
			if doc.kind != .Text {
				// the settings page has no text fields; swallow typing
			} else if app.palette.active {
				palette_input_rune(&app, window.chars[i])
			} else if doc.find.active {
				find_input_rune(doc, window.chars[i])
			} else if doc_read_only_view(doc) {
				// A rendered view, not an editable one. Table view is read-only
				// text; typing only does something once a cell is being edited
				// (click a cell to start), and then it feeds the in-cell field, not
				// the underlying document. Markdown Preview has no field at all --
				// markdown_draw replaces the text pass, so there is not even a caret
				// on screen -- so every character is swallowed.
				//
				// Preview reached this loop unguarded until 2026-07-28: `doc.table`
				// was open-coded here, so typing in the rendered view ran
				// editor_input_rune and edited the file blind, with nothing drawn to
				// show where. Wyatt, live use. The keys that edit without producing a
				// character (Backspace, Enter, Paste, Undo) come through
				// command_dispatch and are stopped by the guard there.
				if doc.table && doc.table_editing {table_edit_rune(doc, window.chars[i])}
			} else {
				// Typing goes to the DOCUMENT, so the rail no longer holds focus.
				app.kbd_tab_focus = false
				// Not doc_insert_rune directly: with a column rectangle live
				// one keystroke is an edit on every row it spans.
				editor_input_rune(&app, doc, &text, window.chars[i])
			}
		}
		window.char_count = 0

		// Losing activation closes transient UI — otherwise Alt+Tab leaves a
		// dropdown drawn and the app in menu mode over another window.
		if window.focus_lost {
			window.focus_lost = false
			menu_close(&app)
		}
		// A bare Alt tap toggles menu-bar keyboard mode (no dropdown), matching
		// Windows. Alt+<key> sets alt_used in the platform layer, so Alt+Z never
		// reaches here.
		if window.alt_tapped {
			window.alt_tapped = false
			if menu_is_active(&app) {menu_close(&app)} else {app.menu.mode = true}
		}
		// Alt+<char> mnemonics, matched on the layout-translated character.
		// Explicit Alt bindings (Alt+Z) already consumed their press via the key
		// path, so this only sees letters no binding claimed.
		for i in 0 ..< window.sys_char_count {
			r := window.sys_chars[i]
			if resolve_key(char_key(r), false, true, .Editor) != .None {continue} // an explicit binding owns it
			for m, mi in menus {
				if lower_rune(r) == m.mnemonic {
					menu_open_at(&app, mi)
					break
				}
			}
		}
		window.sys_char_count = 0

		for i in 0 ..< window.key_count {
			ev := window.key_events[i]
			// A cell edit in the table grid owns the editing keys (a mini text
			// field), before they resolve to editor commands. Enter/Tab commit,
			// Esc cancels; Tab then steps to the next cell on the same row.
			if doc.table && doc.table_editing && !ev.ctrl && !ev.alt {
				#partial switch ev.key {
				case .Backspace:
					table_edit_backspace(doc)
					continue
				case .Delete:
					table_edit_delete(doc)
					continue
				case .Left:
					table_edit_move(doc, -1)
					continue
				case .Right:
					table_edit_move(doc, 1)
					continue
				case .Home:
					table_edit_home(doc)
					continue
				case .End:
					table_edit_end(doc)
					continue
				case .Escape:
					table_edit_cancel(doc)
					continue
				case .Enter:
					table_edit_commit(doc)
					continue
				case .Tab:
					next_row, next_col := doc.table_edit_row, doc.table_edit_col + 1
					table_edit_commit(doc)
					if ok, r, col, fs, fe, val := table_cell_at_index(doc, next_row, next_col, trows); ok {
						table_edit_start(doc, r, col, fs, fe, val)
					}
					continue
				case:
				}
			}
			// Context is per-event; palette/find/menu/tab-switch can change it
			// mid-loop. Priority: menu > palette > find > editor.
			ctx := Ctx.Editor
			if doc.kind == .Font {
				ctx = .Font
			} else if doc.kind == .Settings {
				ctx = .Settings
			} else if app.history.open {
				ctx = .History
			} else if menu_is_active(&app) {
				ctx = .Menu
			} else if app.palette.active {
				ctx = .Palette
			} else if app_active(&app).find.active {
				ctx = .Find
			}
			cmd := resolve_key(ev.key, ev.ctrl, ev.alt, ctx)
			// A global chord taken while the menu is open should close it first.
			if ctx == .Menu && cmd != .None && !is_menu_cmd(cmd) {
				menu_close(&app)
			}
			// srows, not rows: .Page_Up/.Page_Down (commands.odin) scroll by
			// `rows - 1` and clamp against doc_max_top(rows) -- the vertical
			// SCROLL MODEL's count, which is the grid's own budget in a grid and
			// the editor's everywhere else (see doc_scroll_rows). Passing the
			// editor's `rows` here reaches the grid every time a page key is
			// pressed, which is the one route batch 18's srows split did not
			// cover: the wheel and the scrollbar already went through
			// doc_scroll_rows, and this call site still had the old rows.
			command_dispatch(cmd, ev, &app, window, &text, srows)
		}
		window.key_count = 0

		// A tab switch/close may have changed the active document.
		doc = app_active(&app)

		// The palette is modal: clicking a result runs it, clicking elsewhere
		// dismisses, and either way the click is consumed so it never reaches the
		// tabs or the caret. It used to only ever dismiss, so its results looked
		// clickable and were not.
		palette_hover(&app, window, f32(window.width), f32(window.height))
		if app.palette.active && (window.mouse_pressed || window.mouse_middle_pressed) {
			chose, consumed := palette_click(&app, f32(window.mouse_x), f32(window.mouse_y), f32(window.width), f32(window.height))
			if consumed {
				window.mouse_pressed = false
				window.mouse_middle_pressed = false
				window.mouse_down = false
			}
			if chose {
				// srows: the command palette can run Page Up/Down like any other
				// command (see the keyboard dispatch above).
				palette_execute(&app, window, &text, srows)
				doc = app_active(&app)
			}
		}

		// With a dropdown open, sliding across the bar switches menus and moving
		// down the list highlights rows — before any click is considered.
		menu_hover_update(&app, &text, window)
		menu_hover_item(&app, &text, window)
		history_hover_update(&app, window, f32(window.width))

		// The menu claims clicks first: its bar sits above the scrollbar gutter's
		// top edge, and an open dropdown overlaps the content.
		if mcmd, consumed := menu_hit_test(&app, &text, window, f32(window.width), f32(window.height)); consumed {
			if mcmd != .None {
				command_dispatch(mcmd, {}, &app, window, &text, srows)
				doc = app_active(&app)
			}
		}

		// The history panel overlaps the content, so it claims clicks too.
		if app.history.open && window.mouse_pressed {
			if r := history_row_at(&app, f32(window.mouse_x), f32(window.mouse_y), f32(window.width)); r >= 0 {
				app.history.sel = r
				history_activate(&app)
				doc = app_active(&app)
			}
			if history_row_at(&app, f32(window.mouse_x), f32(window.mouse_y), f32(window.width)) >= 0 ||
			   f32(window.mouse_x) >= f32(window.width) - HISTORY_W - SCROLLBAR_W {
				window.mouse_pressed = false
				window.mouse_down = false
			}
		}

		// The tab strip claims clicks in its region before the caret sees them.
		if window.mouse_pressed {app.kbd_tab_focus = false} // a click is not keyboard focus
		tabs_hit_test(&app, window, &text)
		// An in-progress tab reorder follows the cursor and ends on release.
		if app.tab_drag {
			if window.mouse_down {
				tabs_drag_update(&app, window, &text)
			} else {
				app.tab_drag = false
			}
		}

		// Settings and Font are full-window pages with no mouse targets of their
		// own. Without this the click falls through to the document hidden behind
		// them: the caret moves, a drag selects, and the right-hand strip starts
		// a scrollbar drag — all invisibly.
		if doc.kind != .Text {
			window.mouse_pressed = false
			window.mouse_middle_pressed = false
			window.mouse_down = false
			window.scroll_delta = 0
		}
		ed_right := doc_editor_right(doc, f32(window.width), app.settings.split_frac)
		// Editor scrollbar: a press in its gutter starts a byte-proportional drag. In
		// Markdown Split it sits at the divider (ed_right), not the window edge, where
		// the preview's own scrollbar lives. (Otherwise the gutter would be live where
		// no bar exists — empty buffer, filter view — swallowing last-column clicks.)
		scrollbar_shown := doc.pt.length > 0 && !doc.filter
		// In Markdown Split, md_divider_rect's grab band straddles ed_right by
		// design (the drawn accent line sits centred on it too). Left uncapped,
		// this check -- tested first -- claimed the left half of that band,
		// leaving the divider grabbable only on its right half while the drawn
		// line still looked centred. editor_scrollbar_hit_x cedes the divider's
		// left half back to it, so the reachable band matches the drawn line.
		scrollbar_lo, scrollbar_hi := editor_scrollbar_hit_x(doc, ed_right)
		// In full Preview there IS no editor pane, so the one bar at the window
		// edge belongs to the preview and is handled by the branch below. Without
		// this the same pixels would start a byte-model drag on doc.top, and the
		// preview would then be dragged around by the sync in row steps -- the
		// model this task replaces, reachable through the bar alone.
		if scrollbar_shown && doc.md_mode != .Preview && window.mouse_pressed && f32(window.mouse_x) >= scrollbar_lo && f32(window.mouse_x) < scrollbar_hi && window.mouse_y >= i32(CHROME_TOP) {
			scrollbar_drag = true
			vscroll_grab = vbar_grab_at(g_vbar_editor, f32(window.mouse_y))
			window.mouse_pressed = false
		}
		if scrollbar_drag {
			if window.mouse_down {
				vbar_drag_to(doc, &text, g_vbar_editor, f32(window.mouse_y), vscroll_grab, srows)
			} else {
				scrollbar_drag = false
			}
		}
		// Preview scrollbar, at the window edge. In Split it is the second bar (the
		// editor's sits at the divider); in Preview it is the only one.
		if doc.md_mode != .Off && scrollbar_shown && window.mouse_pressed && f32(window.mouse_x) >= f32(window.width) - SCROLLBAR_W && window.mouse_y >= i32(CHROME_TOP) {
			md_preview_drag = true
			preview_grab = vbar_grab_at(g_vbar_preview, f32(window.mouse_y))
			window.mouse_pressed = false
		}
		if md_preview_drag {
			if window.mouse_down {
				// The PREVIEW's own model: a fraction of md_max_anchor's range,
				// inverted back to a pixel anchor. md_preview_scroll then carries
				// the editor along by block (9.4).
				if c, ok := md_scroll_ctx(&gfx, &text, doc, px, f32(window.width), f32(window.height), app.settings.split_frac); ok {
					f := vbar_frac_at(g_vbar_preview, f32(window.mouse_y), preview_grab)
					md_preview_scroll(doc, &c, &text, md_scroll_to_fraction(&c, f), rows)
				}
			} else {
				md_preview_drag = false
			}
		}

		// Markdown Split's divider. Checked before the text-selection drag below
		// (sel_dragging), or a press here would fall through and start selecting
		// the preview/editor text instead of resizing. After the scrollbar checks
		// above, though: MD_DIVIDER_W straddles ed_right, and editor_scrollbar_hit_x
		// already ceded the divider's left half back to it, so the two no longer
		// compete over the same pixels.
		{
			dvr := md_divider_rect(doc, f32(window.width), f32(window.height), app.settings.split_frac)
			if dvr.size.x > 0 && window.mouse_pressed &&
			   f32(window.mouse_x) >= dvr.pos.x && f32(window.mouse_x) < dvr.pos.x + dvr.size.x &&
			   f32(window.mouse_y) >= dvr.pos.y && f32(window.mouse_y) < dvr.pos.y + dvr.size.y {
				divider_drag = true
				window.mouse_pressed = false
			}
		}
		if divider_drag {
			if window.mouse_down {
				// Live during the drag so both panes track the pointer; settings_save
				// runs on release only below -- per-WM_MOUSEMOVE saves would be
				// hundreds of file writes for one drag.
				app.settings.split_frac = split_frac_at(f32(window.mouse_x), f32(window.width))
			} else {
				divider_drag = false
				settings_save(app.settings)
			}
		}

		// Horizontal scrollbar: a press on its track starts a drag mapping the
		// pointer's x to the scroll offset (same geometry the bar is drawn from).
		{
			hm := hscroll_model(doc, &text, ed_right, char_w)
			// Scope the bar to the editor half in Markdown Split (ed_right), so it
			// doesn't run across the preview pane; full width otherwise.
			hb := hscrollbar_geo(doc, ed_right, f32(window.height), hm)
			if hb.shown && window.mouse_pressed &&
			   f32(window.mouse_y) >= hb.y && f32(window.mouse_y) <= hb.y + hb.h &&
			   f32(window.mouse_x) >= hb.track_x && f32(window.mouse_x) <= hb.track_x + hb.track_w {
				hscrollbar_drag = true
				mx := f32(window.mouse_x)
				// On the thumb: hold it where it was taken. On the bare rail:
				// half the thumb, which reproduces the centre-on-the-cursor jump
				// this bar has always made -- once, at the press, instead of on
				// every frame of the drag.
				hscroll_grab = (mx - hb.thumb_x) if (mx >= hb.thumb_x && mx < hb.thumb_x + hb.thumb_w) else hb.thumb_w * 0.5
				window.mouse_pressed = false
			}
			if hscrollbar_drag {
				if window.mouse_down && hb.shown {
					hscroll_set(doc, hm, hscrollbar_pos_at(hb, f32(window.mouse_x) - hscroll_grab, hm))
				} else {
					hscrollbar_drag = false
				}
			}
		}

		// Ctrl+click a link inside a table cell. Cells sit at arbitrary column x's,
		// not the uniform text grid, so this uses pixel hit-testing. Runs before the
		// read-only consume below so the click reaches the link first; consumes
		// either way (the grid takes no caret).
		if doc.table && doc.kind == .Text && window.mouse_pressed && plat.key_ctrl_down() {
			if tl, found := table_link_hit(table_links(doc, &text, px, char_w, trows, f32(window.width)), f32(window.mouse_x), f32(window.mouse_y), px, table_row_h(px)); found {
				// Not resolution-gated the way the document view now is: table_links
				// decorates whatever links_scan finds in a cell, so a dead target here
				// still underlines. link_follow at least says so instead of doing
				// nothing. (Gating the table's decoration too is HANDOFF §6l work.)
				link_follow(&app, &text, window, doc, tl.text, tl.link)
				window.mouse_pressed = false
				window.mouse_down = false
			}
		}

		// Plain click on a table cell starts editing it in place (commit any cell
		// already being edited first). Before the read-only consume below, which
		// swallows the press for the grid. Ctrl is the link modifier, handled above.
		if doc.table && doc.kind == .Text && window.mouse_pressed && !plat.key_ctrl_down() &&
		   f32(window.mouse_y) >= CONTENT_TOP + TOP_INSET && f32(window.mouse_y) < f32(window.height) - doc_bottom_bar_h(doc) {
			if doc.table_editing {table_edit_commit(doc)}
			if ok, r, col, fs, fe, val := table_cell_at(doc, f32(window.mouse_x), f32(window.mouse_y), px, char_w, trows, f32(window.width)); ok {
				table_edit_start(doc, r, col, fs, fe, val)
			}
			// don't consume: let the read-only block below swallow it uniformly
		}

		// Read-only content: the table grid, a full preview, and the preview half of
		// a split take no caret. Swallow any press the scrollbars above did not claim
		// (so the wheel still scrolls, and the bars still drag). After the scrollbars,
		// so a press on either bar reaches it first.
		if doc.kind == .Text && window.mouse_y >= i32(CHROME_TOP) {
			drags := Drag_Latches{scrollbar_drag, hscrollbar_drag, md_preview_drag, divider_drag}
			ro := ro_surface_swallows(doc.table, doc.md_mode, f32(window.mouse_x) >= ed_right, drags)
			// 9.1's one surviving pixel -> content mapping, wired to the gesture it
			// exists for: "click-to-sync-scroll, which only needs the nearest
			// BLOCK". SPLIT only -- it is the mode with both panes on screen, so it
			// is the only one where a block in the preview names somewhere the
			// editor could go. In full Preview a press stays inert, as it is today.
			// The press is still swallowed below; this reads it on the way past.
			// The gate itself (bounding this to the preview pane, and to the
			// DOUBLE press) is md_split_click_gate; the scroll it applies is
			// md_split_click_sync -- see their comments for why neither is inlined.
			if window.mouse_pressed && !plat.key_ctrl_down() {
				if c, ok := md_scroll_ctx(&gfx, &text, doc, px, f32(window.width), f32(window.height), app.settings.split_frac); ok {
					md_split_click_sync(doc, &text, &c, ro, window.mouse_count, ed_right, f32(window.mouse_x), f32(window.mouse_y), rows)
				}
			}
			if ro && (window.mouse_pressed || window.mouse_down) {
				window.mouse_pressed = false
				window.mouse_middle_pressed = false
				window.mouse_down = false
			}
		}

		// The find/status bar owns the bottom strip. A fresh press there must not
		// place the caret (doc_pos_at would clamp the out-of-range row onto the
		// last one). But an in-progress drag reaching the strip must NOT be
		// cancelled: zeroing mouse_down here unconditionally killed the drag and
		// its auto-scroll the instant the pointer touched the bar, so a selection
		// could never be dragged below the last visible line. Consume only a fresh
		// press; leave an ongoing drag to the auto-scroll below.
		// A click on a status cell runs its command, before the strip swallows
		// the press. UI spec 13: "Every cell is clickable."
		if window.mouse_pressed {
			scw := plat.text_char_width(&text, UI_SMALL_PX)
			if c := status_cell_at(doc, f32(window.width), f32(window.height), scw, f32(window.mouse_x), f32(window.mouse_y)); c != .None {
				command_dispatch(c, {}, &app, window, &text, srows)
			}
		}
		if f32(window.mouse_y) >= f32(window.height) - doc_bottom_bar_h(doc) {
			if window.mouse_pressed || window.mouse_middle_pressed {
				window.mouse_pressed = false
				window.mouse_middle_pressed = false
				window.mouse_down = false
			}
		}

		// The same rule at the TOP, now that the find bar and the filter banner
		// inset the content from above. Without it a press in the find bar runs
		// through doc_pos_at, whose row_at_y goes NEGATIVE there and clamps to
		// row 0 -- so clicking the search field would silently move the caret to
		// the first visible line. The bottom strip has had this guard since the
		// find bar lived down there; moving the bar moved the hazard with it.
		//
		// A fresh press only, exactly like the bottom: an in-progress selection
		// drag that reaches the bar must keep auto-scrolling rather than dying.
		// A click on a mode chip toggles it, and a click on a replace-row button
		// runs it. Before the swallow below, which is what would otherwise eat the
		// press -- and both are drawn to look pressable, so they have to be. The
		// buttons are tested first: the two rows do not overlap, but reading the
		// precedence off the code beats inferring it from the geometry. Both come
		// from the same layout the draw used (find_actions / find_toggles).
		if window.mouse_pressed && doc.find.active {
			if c := find_action_at(doc, &text, f32(window.width), f32(window.mouse_x), f32(window.mouse_y)); c != .None {
				command_dispatch(c, {}, &app, window, &text, srows)
			} else if c := find_toggle_at(doc, f32(window.width), f32(window.mouse_x), f32(window.mouse_y)); c != .None {
				command_dispatch(c, {}, &app, window, &text, srows)
			}
		}
		if f32(window.mouse_y) >= CHROME_TOP && f32(window.mouse_y) < CONTENT_TOP + TOP_INSET {
			if window.mouse_pressed || window.mouse_middle_pressed {
				window.mouse_pressed = false
				window.mouse_middle_pressed = false
				window.mouse_down = false
			}
		}

		// Divider resize cursor, then Ctrl+hover over a link: hand cursor. Uses the
		// live cursor position, not window.mouse_y, which WM_MOUSEMOVE only updates
		// while a button is held — that exact mistake is in the §6j bug list. The
		// same md_divider_rect the drag above hit-tests against, so the cursor
		// changes exactly where a press would grab.
		{
			want := plat.Cursor_Kind.Arrow
			cx, cy := plat.window_cursor_client(window)
			dvr := md_divider_rect(doc, f32(window.width), f32(window.height), app.settings.split_frac)
			if divider_drag || (dvr.size.x > 0 && f32(cx) >= dvr.pos.x && f32(cx) < dvr.pos.x + dvr.size.x && f32(cy) >= dvr.pos.y && f32(cy) < dvr.pos.y + dvr.size.y) {
				want = .SizeWE
			} else if doc.find.active && find_action_at(doc, &text, f32(window.width), f32(cx), f32(cy)) != .None {
				// Same geometry as the draw, the hover fill and the click. A
				// button that looks pressable, fills on hover and does not change
				// the pointer is three quarters of a control.
				want = .Hand
			} else if plat.key_ctrl_down() && !doc.filter {
				if doc.table && doc.kind == .Text {
					if _, over := table_link_hit(table_links(doc, &text, px, char_w, trows, f32(window.width)), f32(cx), f32(cy), px, table_row_h(px)); over {
						want = .Hand
					}
				} else if _, over := md_preview_link_at(&gfx, &text, doc, px, f32(window.width), f32(window.height), app.settings.split_frac, f32(cx), f32(cy)); over {
					// The preview pane's own links: rectangles from the shaper,
					// not columns from the cell grid the preview does not have.
					// false in every mode but Preview/Split, and its rectangles
					// only ever cover the preview pane, so this cannot claim a
					// point in Split's editor half.
					//
					// md_preview_link_at, not md_link_at over md_preview_links:
					// the pane's y bound is inside it, so the hand cursor and the
					// Ctrl+click below cannot disagree about where the pane ends.
					want = .Hand
				} else if !md_pane_owns(doc, f32(window.width), f32(window.height), app.settings.split_frac, f32(cx)) {
					// The editor's grid path, and ONLY where the editor really
					// is. In Split the editor pass draws full-window width (the
					// preview repaints over it), so its Link_Hits run on into
					// the right half and would put a hand cursor over preview
					// prose that has nothing under it.
					if _, over := links_hit(links_layout(doc, &text, drawn), px, char_w, f32(cx), f32(cy)); over {
						want = .Hand
					}
				}
			}
			plat.window_set_cursor(window, want)
		}

		// Ctrl+click a link. Checked before the caret handling below so it does not
		// also move the caret, and gated on Ctrl so a plain click still means what
		// it always meant — you can click into the middle of a URL to edit it.
		if window.mouse_pressed && plat.key_ctrl_down() && !doc.filter {
			mmx, mmy := f32(window.mouse_x), f32(window.mouse_y)
			// Same dispatch, same producers, same order as the hover cursor
			// above: the preview pane's shaped rectangles first, the editor's
			// grid only where the editor actually is.
			if h, found := md_preview_link_at(&gfx, &text, doc, px, f32(window.width), f32(window.height), app.settings.split_frac, mmx, mmy); found {
				link_follow(&app, &text, window, doc, h.text, h.link)
				window.mouse_pressed = false
				window.mouse_down = false
			} else if !md_pane_owns(doc, f32(window.width), f32(window.height), app.settings.split_frac, mmx) {
				if h, hfound := links_hit(links_layout(doc, &text, drawn), px, char_w, mmx, mmy); hfound {
					link_follow(&app, &text, window, doc, h.text, h.link)
					window.mouse_pressed = false
					window.mouse_down = false
				}
			}
		}

		// Filter view: a press jumps to that line in the unfiltered document
		// (HANDOFF §6h item 2). Before the caret handling below, which would
		// otherwise place a caret inside the filtered row and leave the view
		// filtered.
		//
		// The press is consumed either way while the view is actually filtering,
		// including when it lands on the empty area past the last matching row:
		// that means "none of these", and falling through would place the caret
		// wherever doc_pos_at clamped the out-of-range row to. mouse_down goes
		// with it so the next frames cannot turn the same gesture into a
		// selection drag across the document the jump has just revealed.
		if window.mouse_pressed && doc_filtering(doc) {
			_ = find_filter_click(doc, &text, f32(window.mouse_x), f32(window.mouse_y), px, drawn)
			window.mouse_pressed = false
			window.mouse_down = false
		}

		// Mouse: press places/extends the caret (double=word, triple=line); drag extends.
		if window.mouse_pressed {
			mp := doc_pos_at(doc, &text, window.mouse_x, window.mouse_y, px, char_w, drawn)
			switch window.mouse_count {
			case 2:
				doc_select_word_at(doc, mp)
			case 3:
				doc_select_line_at(doc, mp)
			case:
				doc.cursor = mp
				if !window.mouse_shift {
					doc.anchor = mp
				}
				// Latch Alt now, once, for the whole gesture, clear any
				// rectangle the last gesture left, and resolve the anchor
				// corner -- all three inside block_drag_press (block.odin),
				// which owns the gesture's state. doc.cursor was just set to
				// mp above, which is the row it resolves from.
				block_drag_press(&block_drag, doc, plat.key_alt_down(), cell_at_x(char_w, f32(window.mouse_x)))
			}
			press_x, press_y = window.mouse_x, window.mouse_y
			sel_dragging = false // arm; a drag begins only once the pointer moves
			window.mouse_pressed = false
		} else if window.mouse_down && window.mouse_count == 1 && !scrollbar_drag && !hscrollbar_drag && !app.tab_drag && !divider_drag && !md_preview_drag {
			// md_preview_drag belongs in this exclusion list exactly like the other
			// three drag latches beside it: window.mouse_down stays true for its
			// whole gesture (real OS state, not something any of these consumers
			// clear), so leaving it out let a preview-scrollbar drag also fall into
			// the selection branch below on every one of its frames -- re-running
			// the Alt-drag path with whatever block_drag (the Alt latch and the
			// anchor corner it resolved) was left over from an unrelated earlier
			// gesture. Finding 2 (doc_wraps'
			// filter/Split refusals) already suppresses most of the fallout since
			// Markdown Split forces wrap, but this is the actual leak.
			// A selection drag begins only once the pointer has actually moved from
			// the press point. A stationary press-and-hold must not extend the
			// selection or auto-scroll -- that was the bug where holding still lit up
			// lines and scrolled. Once dragging, the flag stays set, so holding at an
			// edge keeps auto-scrolling without needing further movement.
			DRAG_SLOP :: 3
			slop := i32(sx(DRAG_SLOP))
			if !sel_dragging && (abs(window.mouse_x - press_x) > slop || abs(window.mouse_y - press_y) > slop) {
				sel_dragging = true
			}
			if sel_dragging {
				mp := doc_pos_at(doc, &text, window.mouse_x, window.mouse_y, px, char_w, drawn)
				// block_drag_update (block.odin) now owns whether doc.cursor commits
				// to mp this frame, not just whether a rectangle gets built: always
				// for a plain drag, only on an ACCEPTED rectangle for an Alt-drag. A
				// live pass caught the previous version of this code, which set
				// doc.cursor = mp unconditionally before the refusal was even
				// checked -- so a refused Alt-drag (wrap on, filter on, Split view)
				// still tracked the pointer every frame and degraded into an
				// ordinary linear selection nobody asked for, one that outlived the
				// gesture and even outlived toggling wrap back off. See
				// block_drag_update's own comment for the fix. The column:
				// cell_at_x, the same primitive the draw and the hit-test use for
				// every other column -- not a second conversion path from mp's byte
				// offset. The wording of each note stays here because block.odin has
				// never imported the App type.
				refusal, note := block_drag_update(&block_drag, doc, &text, mp, cell_at_x(char_w, f32(window.mouse_x)))
				if note {
					switch refusal {
					case .Wrap_On:
						app_note(&app, "[COLUMN SELECT NEEDS WRAP OFF - press Alt+Z]")
					case .Split_On:
						app_note(&app, "[COLUMN SELECT NEEDS SPLIT OFF - press Ctrl+M]")
					case .Filter_On:
						app_note(&app, "[COLUMN SELECT UNAVAILABLE - TURN OFF FILTER]")
					case .Caret_Unresolved:
						app_note(&app, "[COLUMN SELECT UNAVAILABLE HERE - the line is too far into a very large file]")
					case .None:
					}
				}
				// Auto-scroll while the pointer is dragged above the first row or at/
				// below the last one — the edges are the content area, so entering the
				// bottom bar (or leaving the window past it) keeps scrolling instead of
				// stopping dead at the last visible line. Gated on refusal == .None:
				// a refused Alt-drag already pins the cursor and refuses to extend the
				// rectangle (block_drag_update, above) -- scrolling the view under a
				// gesture that was just refused moved the file out from under the user
				// for a drag that wasn't doing anything. A plain (non-Alt) drag is
				// never refused, so this doesn't change its behavior.
				if refusal == .None {
					if f32(window.mouse_y) < CONTENT_TOP + TOP_INSET {
						doc_scroll(doc, &text, -1, rows)
					} else if f32(window.mouse_y) >= f32(window.height) - doc_bottom_bar_h(doc) {
						doc_scroll(doc, &text, 1, rows)
					}
				}
			}
		}

		// The wheel scrolls even with Ctrl held: Ctrl is the link-highlight modifier,
		// so Ctrl+wheel is how you scroll through a document while its links are lit.
		// Zoom lives on the keyboard instead (Ctrl+= / Ctrl+- / Ctrl+0) and Settings.
		if window.scroll_delta != 0 {
			// The preview pane scrolls in PIXELS (9.1 item 4). Dispatch is by PANE,
			// not by mode -- md_pane_owns, the same producer the link hit-test uses
			// -- so in Split the wheel over the left half still moves the editor's
			// rows and the wheel over the right half moves the preview's pixels,
			// each carrying the other along by block.
			if doc.kind == .Text && doc.md_mode != .Off && md_pane_owns(doc, f32(window.width), f32(window.height), app.settings.split_frac, f32(window.mouse_x)) {
				if c, ok := md_scroll_ctx(&gfx, &text, doc, px, f32(window.width), f32(window.height), app.settings.split_frac); ok {
					md_preview_scroll(doc, &c, &text, md_scroll_px(&c, doc.md_top, f32(window.scroll_delta) * md_wheel_px(&c)), rows)
				}
			} else if doc.table {
				if doc.table_editing {table_edit_commit(doc)} // rows shift underfoot
				if plat.key_shift_down() { // Shift+wheel pans table columns
					doc.table_col = clamp(doc.table_col + window.scroll_delta, 0, table_max_col(doc))
				} else {
					// Normalised through table_data_start on BOTH sides of the
					// scroll, because the header is sticky and therefore owns line
					// 0: doc.top == 0 and doc.top == <start of line 1> are the same
					// scroll position, so without the leading normalise the first
					// notch off the top of a freshly-opened CSV moves doc.top from
					// one to the other and renders an identical frame -- a wheel
					// notch that visibly does nothing. Without the trailing one the
					// last notch back up does the same in reverse. Same producer the
					// draw and the hit-test read, so no third opinion about which
					// line is the first data row.
					if s, sok := table_data_start(doc); sok {doc.top = s}
					doc_scroll(doc, &text, window.scroll_delta, trows)
					if s, sok := table_data_start(doc); sok {doc.top = s}
				}
			} else if doc.filter {
				// Stop at the point the list underfills the screen, rather than
				// letting the last line scroll to the top over empty rows.
				doc.filter_top = clamp(doc.filter_top + window.scroll_delta, 0, doc_filter_max_top(doc, rows))
			} else if plat.key_shift_down() && !doc.wrap {
				// Shift+wheel pans horizontally (no-op when wrapping — nothing runs
				// off the edge then). A few cells per notch, clamped to real content.
				doc.h_scroll = clamp(doc.h_scroll + window.scroll_delta * 4, 0, doc_max_hscroll(doc))
			} else {
				doc_scroll(doc, &text, window.scroll_delta, rows)
			}
			window.scroll_delta = 0
		}

		// External changes, merged once per frame. The worker only reports; every
		// decision about what to do with a document is made here, on the thread
		// that owns it.
		watcher_publish(&watcher, &app)
		clear(&disk_changes)
		watcher_take(&watcher, &disk_changes)
		for c in disk_changes {
			defer delete(c.path)
			if c.slot < 0 || c.slot >= len(app.docs) {continue}
			d := app.docs[c.slot]
			// The slot may have been closed and reused since the stat began.
			if d == nil || d.gen != c.gen {continue}
			if !c.stamp.ok {
				d.disk_gone = true
				continue
			}
			d.disk_gone = false
			// A pending in-cell edit holds byte offsets into the current buffer; an
			// absorb/reload below rebuilds it, so drop the edit rather than splice at
			// a stale offset when it commits.
			if d.table_editing {table_edit_cancel(d)}
			// Get off the mapping before anything else: while we hold it, the
			// other writer cannot rotate or replace the file.
			doc_detach_mapping(d)
			// Record the version we just saw in every branch. The worker re-reports
			// any file whose stamp differs from the one we publish, so a change the
			// user has not acted on used to be re-reported once a second forever --
			// and each report set session_dirty, rewriting session.txt and a full
			// backup of every dirty buffer, once a second, on an idle app.
			// disk_changed is the flag that remembers; disk_stamp only records what
			// we have already been told.
			if d.modified {
				// Never discard the user's edits silently. Mark and let them choose.
				d.disk_changed = true
				d.disk_stamp = c.stamp
			} else if doc_absorb_append(d, c.stamp.size) {
				d.disk_stamp = c.stamp
			} else if !doc_reload(d) {
				d.disk_changed = true
				d.disk_stamp = c.stamp
			}
			// If what changed on disk was the active theme's file, re-apply it.
			// Only on a branch that actually took the new bytes: when
			// d.disk_changed is set the user's edits won.
			if !d.disk_changed {
				theme_reapply_if_active(&app, d.path)
				// And the keymap, for the same reason: editing keys.txt in another
				// editor while Newtpad has it open should take effect here too.
				keymap_reload_if_active(&app, d.path)
				// And the colour rules, same reason again.
				rules_reload_if_active(&app, d.path)
			}
			session_dirty = true
		}

		// Same rule as the watcher above: the update worker only reports, and
		// every decision about what to tell the user is made here, once per
		// frame, on the thread that owns the App.
		update_poll(&app, window)

		// Take whatever the search worker published since the last frame (and
		// restart it if an edit invalidated the results).
		doc = app_active(&app)
		find_merge(doc)

		// Keep the caret on screen only when it moved on this tab this frame.
		if !doc.filter && app.active == active_before && doc.cursor != cursor_before {
			doc_ensure_cursor_visible(doc, &text, rows, drawn)
		}

		// An open cell edit that has stopped sitting on its own cell commits, at
		// ONE point, after every path above that could have moved the view and
		// before the draw reads doc.table_edit_row. See table_edit_hold: the wheel
		// committed here already (and still does, inline, because it renormalises
		// doc.top twice around its own scroll), but the scrollbar drag, the page
		// keys and a window resize did not -- the box and the caret stayed drawn
		// on a row that no longer held the bytes a commit would write.
		//
		// `trows`, the grid's own row budget, not `rows`: the resize half of the
		// check asks whether the edited row still fits under the sticky header,
		// which is exactly what table_visible_rows counts.
		//
		// Ahead of the title block below on purpose, so the dirty star appears on
		// the frame the commit happens rather than the one after it.
		if doc.table && doc.kind == .Text {table_edit_hold(doc, trows)}

		// Window title = [*]filename - Newtpad, set only when it changes.
		{
			@(static) last: [512]u8
			@(static) last_len: int
			tbuf: [512]u8
			title := fmt.bprintf(tbuf[:], "%s%s - Newtpad", "*" if doc.modified else "", doc_display_name(doc))
			if len(title) != last_len || string(last[:last_len]) != title {
				plat.window_set_title(window, title)
				copy(last[:], transmute([]u8)title)
				last_len = len(title)
			}
		}

		// 9.4's scroll sync, resolved at ONE point per frame, after every path
		// that could have moved either side and before the draw reads them.
		//
		// The editor is byte-anchored and the preview is pixel-anchored, so this
		// is a MAPPING, not the identity it used to be. doc.md_sync_top is the
		// doc.top the preview last mirrored: every path that moves the PREVIEW
		// writes it (md_preview_scroll), so a mismatch means the EDITOR moved --
		// a caret reveal, the page keys, its own wheel or scrollbar, a session
		// restore, or Ctrl+M turning the preview on -- and the preview re-anchors
		// to the block containing that line.
		//
		// It runs in Preview as well as Split, and that is what makes a restored
		// session, Ctrl+Home/End and the page keys all still move the preview
		// without any of them knowing it exists.
		if doc.kind == .Text && doc.md_mode != .Off && doc.top != doc.md_sync_top {
			if c, ok := md_scroll_ctx(&gfx, &text, doc, px, f32(window.width), f32(window.height), app.settings.split_frac); ok {
				doc.md_top = md_anchor_from_top(&c, doc.top)
				doc.md_sync_top = doc.top
			}
		}

		render_frame(&rc)

		// The GPU went away mid-frame (driver update, TDR, eGPU unplug, an RDP
		// session change). Every D3D object is invalid now, so nothing can be drawn
		// again in this process. Present's result used to be discarded, which left
		// a permanently frozen window still holding every unsaved buffer, with no
		// message and no way to get the text back.
		//
		// Get the work onto disk FIRST -- the session backups are the only copy of
		// a dirty buffer -- then say what happened, then leave. Recreating the
		// device and every dependent resource (atlas, shaders, both pipelines) is
		// the nicer answer and is deliberately not attempted here: it cannot be
		// exercised in this environment, and an untested recovery path that runs
		// only during a GPU fault is a worse failure than a clean exit.
		if plat.gfx_is_lost(&gfx) {
			reason := plat.gfx_lost_reason(&gfx)
			saved := primary && session_save(&app, session_can_sweep)
			tail :=
				"Your open tabs and unsaved changes have been saved, and will be restored when you start Newtpad again." if saved else "Newtpad could not save your session, so unsaved changes may be lost."
			plat.message_error(window.hwnd, fmt.tprintf("Newtpad has to close because %s.\n\n%s", reason, tail))
			break
		}

		// A mapped read may have faulted during this frame's draw/search (file
		// truncated or decompression-broken underneath us). Detach from the map
		// into a private copy so we never fault again; next frame draws that.
		if doc_fault_pending(doc) {
			doc_recover_from_fault(doc)
			fmt.eprintln("Newtpad: file changed on disk mid-read; showing a recovered copy")
		}

		// Autosave the session once input has settled (primary instance only).
		if primary && session_dirty && time.duration_seconds(time.tick_since(last_input)) > 2 {
			session_save(&app, session_can_sweep)
			session_dirty = false
		}
		free_all(context.temp_allocator)
	}

	if primary {
		session_save(&app, session_can_sweep) // hot-exit: persist tabs + unsaved buffers
	}
}

// Everything render_frame needs; built once in main and handed to the resize
// callback via the window so a live resize can repaint.
Render_Ctx :: struct {
	gfx:                ^plat.Gfx,
	text:               ^plat.Text,
	quads:              ^plat.Quad_Pipeline,
	app:                ^App,
	window:             ^plat.Window,
	px, char_w, line_h: f32,
}

// Horizontal scrollbar geometry (pixels). One producer, consumed by the draw in
// render_frame and the drag hit-test in the main loop, so the drawn track and the
// clickable track cannot disagree. Shown only in the plain view when a visible
// line overflows the viewport.
Hbar :: struct {
	shown:                                  bool,
	track_x, track_w, y, h, thumb_x, thumb_w: f32,
}

// What the horizontal scrollbar actually pans. There is more than one answer,
// which is the whole bug this type exists to close: the text view scrolls by
// CELLS (doc.h_scroll), while the grid scrolls by COLUMNS (doc.table_col) and
// has done since before the bar existed -- Shift+wheel drives it. The bar used
// to compute its range from doc_max_hscroll unconditionally, i.e. from the
// widest source-text line, and to write doc.h_scroll on drag. In the grid that
// meant a bar that appeared (source lines are long), dragged, and moved
// nothing, because table_draw never reads H_SCROLL. Markdown Preview was the
// same, with no pan axis at all.
//
// Resolving it here once, and having the geometry, the drag and the draw all
// ask, is CLAUDE.md's "one layout per widget" applied to the question "which
// number am I scrolling?".
Hscroll_Kind :: enum u8 {
	None, // wrapped, filtered, or a view that lays out to fit (Preview, Split)
	Cells, // plain text view: doc.h_scroll
	Columns, // grid view: doc.table_col
}

Hscroll :: struct {
	kind:     Hscroll_Kind,
	pos, max: int, // current and maximum offset, in this kind's unit
	span:     int, // how much is visible in the same unit; sizes the thumb
}

// L8 (2026-07-29 review): `rows` was in this signature for symmetry with the
// vertical model, but neither branch below reads it -- the .Columns branch
// sizes its span from the pixel width (table_cols_fitting), and the .Cells
// branch reads doc_max_hscroll, which doc_update_max_hscroll (the caller's
// job, once per frame) already measured against the actual row count. Removed
// rather than documented, since there was nothing to document.
hscroll_model :: proc(doc: ^Document, t: ^plat.Text, winw, char_w: f32) -> (m: Hscroll) {
	if doc == nil || doc.filter {return}
	// The grid replaces the text pass entirely, so its axis is columns and the
	// widest source line is irrelevant to it.
	if doc.table && doc.kind == .Text {
		if len(doc.table_widths) == 0 {table_compute_widths(doc, t)} // idempotent; one-time sample
		if doc.table_cols == 0 {doc.table_cols = len(doc.table_widths)} // table_draw sets this, but not before frame 1
		m.max = table_max_col(doc)
		if m.max <= 0 {return}
		m.pos = clamp(doc.table_col, 0, m.max)
		m.span = table_cols_fitting(doc, char_w, winw, m.pos)
		m.kind = .Columns
		return
	}
	// Preview lays markdown out to the pane width, so there is nothing to pan
	// horizontally; Split's editor half wraps for the same reason. (A markdown
	// TABLE wider than the pane is still clipped -- that is a separate problem
	// needing the table to scroll, not the pane. Tracked in HANDOFF 5.)
	if doc.kind == .Text && doc.md_mode != .Off {return}
	if doc_wraps(doc) {return}
	m.max = doc_max_hscroll(doc)
	if m.max <= 0 {return}
	m.pos = clamp(doc.h_scroll, 0, m.max)
	m.span = max(1, doc.view_cols)
	m.kind = .Cells
	return
}

// Write a new offset back to whichever field this view pans. The only writer
// the bar's drag uses -- so the drag cannot set a field the draw does not read.
hscroll_set :: proc(doc: ^Document, m: Hscroll, pos: int) {
	p := clamp(pos, 0, m.max)
	switch m.kind {
	case .Cells:
		doc.h_scroll = p
	case .Columns:
		doc.table_col = p
	case .None: // nothing to write; the bar is not shown
	}
}

hscrollbar_geo :: proc(doc: ^Document, winw, winh: f32, m: Hscroll) -> (b: Hbar) {
	if doc == nil || m.kind == .None || m.max <= 0 {return}
	b.track_x = TEXT_MARGIN_X
	b.track_w = winw - SCROLLBAR_W - TEXT_MARGIN_X
	if b.track_w <= sx(30) {return}
	b.h = sx(8)
	b.y = winh - doc_bottom_bar_h(doc) - b.h
	total := f32(m.max + max(1, m.span)) // full extent in this kind's unit
	b.thumb_w = max(sx(24), b.track_w * f32(m.span) / total)
	b.thumb_x = b.track_x + (b.track_w - b.thumb_w) * (f32(m.pos) / f32(m.max))
	b.shown = true
	return
}

// Map a thumb LEFT EDGE on the track to a horizontal scroll offset. The exact
// inverse of hscrollbar_geo's thumb_x, and kept beside it so the two stay
// consistent.
//
// It used to take the pointer x and subtract half the thumb width -- "thumb
// centred on the cursor" -- which silently made every drag frame a fresh
// centre-on-the-pointer jump, so grabbing the thumb by its edge snapped it under
// the cursor and then refused to be dragged from where it was grabbed. The
// caller now subtracts the grab offset it latched at the press, so a rail click
// still centres (grab = half the thumb) and a thumb grab holds (grab = where you
// actually took hold of it).
// Every gesture that owns the pointer across frames. The read-only swallow must
// exclude all of them, and this struct exists so the list is one thing that can
// be tested rather than four `&&` clauses nobody re-reads.
Drag_Latches :: struct {
	vscroll, hscroll, preview, divider: bool,
}

// Should a read-only surface swallow this mouse event?
//
// The grid, a full Preview and the preview half of a Split take no caret, so a
// press that no scrollbar claimed is consumed. **But consuming means zeroing
// `window.mouse_down`, and that is persistent platform state** — set on
// WM_LBUTTONDOWN, cleared on WM_LBUTTONUP (`window.odin`). Zero it mid-gesture
// and the drag is dead until the next press, twice over: the latch above sees
// `!mouse_down` and clears itself, and WM_MOUSEMOVE only updates `mouse_x`
// while `mouse_down` is set, so the pointer stops moving too.
//
// That is exactly what shipped: `hscroll` was missing from this list while the
// other three were present, so dragging the grid's horizontal bar moved it on
// the press frame and froze — "it only moves when you click, not when you hold
// and drag" (Wyatt, live use, v0.17.1). It went unnoticed because the bar was
// dead in the grid until the fix immediately before it, and because in the
// plain text view `ro` is false so nothing is swallowed at all.
ro_surface_swallows :: proc(table: bool, md_mode: Md_Mode, in_preview_half: bool, d: Drag_Latches) -> bool {
	if d.vscroll || d.hscroll || d.preview || d.divider {return false}
	return table || md_mode == .Preview || (md_mode == .Split && in_preview_half)
}

// Whether a press at (mx, my) is Split's click-to-sync-scroll gesture, and the
// block it names if so. `ro` alone is not enough of a gate: it is true for the
// status bar and the find bar too (both run through the caller's block before
// their OWN guards, later in the same frame), and it is true for the EDITOR
// half whenever the document is also a table (ro_surface_swallows answers
// from `table` alone, not from which pane the press is in). x >= ed_right
// restricts this to the preview pane's columns.
//
// THE GESTURE IS A DOUBLE PRESS, and that is the fix for Wyatt's report -- "when
// you click in the markdown preview on split mode it shifts the edit side
// up/down" (live use, 2026-07-29). The capability is spec'd (9.1 names
// click-to-sync-scroll, 9.4 lists scroll sync as a Split rule) and stays; only
// the binding changes. A single click is what people use to focus a pane or
// dismiss something, and the other half of the window jumping in response to
// one is hostile.
//
// `clicks` is window.mouse_count, which is the press INDEX within a
// double-click-time/4px cluster: WM_LBUTTONDOWN increments it and wraps 3 -> 1
// (platform/window.odin), so it is 1 on a lone press, 2 on the second press of
// a double click, 3 on a triple's third. `>= 2` therefore means "not the first
// press of a cluster": the second press syncs, and a triple's third press
// re-syncs to the block the second one already named, which is where the view
// is. Nothing else in the preview half claims a double press -- ro_surface_swallows
// eats it before doc_select_word_at ever sees it -- so this takes no gesture away.
//
// The ROWS are md_block_at_y's own business, and that is a correction: this
// procedure used to carry `my < c.ytop || my >= c.ytop + c.pane` as well, and
// commented it as what kept the status bar and the find bar out. md_block_at_y
// is the only thing this calls, and it applies that identical predicate to the
// identical `c` two lines later -- so the copy could never refuse a press the
// callee would have accepted. Removing it: 0 failures across the suite.
// Removing BOTH: exactly one of the three "gate:" rows that name a y bound
// fails (the find bar, which is the only one genuinely above ytop); the status
// bar and the empty-strip cases are refused by the placement md_block_at_y reads
// instead (md_place_next), whatever their assertion names say. Same shape the branch already
// diagnosed and removed at md_layout_slot -- a guard crediting itself with a
// fix (2026-07-29 review, F5).
//
// A separate, named proc rather than inlined in main()'s loop: main() is the
// live WM_* loop and cannot run in a headless test, so a gate that lived only
// there could not be exercised at its own boundaries -- exactly the shape
// that let the original `ro`-only gate ship unbounded. mdtest's "gate:"
// checks call this directly.
md_split_click_gate :: proc(doc: ^Document, c: ^Md_Scroll_Ctx, ro: bool, clicks: int, ed_right, mx, my: f32) -> (blk: int, hit: bool) {
	if !ro || doc.md_mode != .Split || mx < ed_right || clicks < 2 {return}
	return md_block_at_y(c, doc.md_top, my)
}

// The gesture's EFFECT, extracted from main()'s loop for the same reason the gate
// was: main() is the live WM_* loop and cannot run headless, so the only thing a
// test could reach was the gate's return value -- and a gate returning `false` is
// not the same claim as "the editor did not move". The bug Wyatt reported is
// about `doc.top` moving, so `doc.top` is what a test has to be able to watch.
//
// Returns whether it scrolled. `doc.md_sync_top` follows `doc.top` because the
// preview keeps its own pixel offset, and the sync is what re-anchors it.
md_split_click_sync :: proc(
	doc: ^Document,
	t: ^plat.Text,
	c: ^Md_Scroll_Ctx,
	ro: bool,
	clicks: int,
	ed_right, mx, my: f32,
	rows: int,
) -> bool {
	blk, hit := md_split_click_gate(doc, c, ro, clicks, ed_right, mx, my)
	if !hit {return false}
	doc.top = min(base.pt_line_start(&doc.pt, blk), doc_max_top(doc, t, rows))
	doc.md_sync_top = doc.top
	return true
}

// The vertical scrollbar's track, in client pixels. ONE definition, consumed by
// the thumb draw, the find-match marks, the Markdown Split preview bar and both
// drag hit-tests — CLAUDE.md's "one layout per widget" applied to a widget that
// had quietly grown five copies of `h - CHROME_TOP`.
//
// Subtracting the bottom bar is the fix, not a refinement: the status line (and
// the taller find/replace bar) is drawn AFTER the scrollbar, opaque and full
// width, so a track running to the window bottom has its last rows painted over.
// That cost the thumb its last ~20px near the document end, and — since batch 9
// — every match tick in the last 2.5% of the file (4.7% in replace mode), which
// are exactly the off-screen matches the ticks exist to point at.
scrollbar_track :: proc(doc: ^Document, winh: f32) -> (top, height: f32) {
	return CHROME_TOP, max(1, winh - CHROME_TOP - doc_bottom_bar_h(doc))
}

// The vertical scrollbar's track AND thumb, in client pixels. The hscrollbar_geo
// of the vertical axis, and it exists for the same reason: the thumb's y and
// height were computed inside render_frame -- twice, once for the editor bar and
// once for the Split preview's -- so the DRAG could not see the thumb at all.
// Not being able to see it is precisely why the drag re-derived the scroll
// position from the raw pointer y on every frame, which is the bug Wyatt hit:
// press-and-hold anywhere on the thumb re-ran the rail-click jump every frame
// and the view lurched out from under the grab.
//
// `bottom` is the last visible byte offset, which the draw discovers -- so the
// two callers pass their own (doc_draw's for the editor, markdown_draw's for the
// preview) and this stays one geometry with two inputs rather than two
// geometries.
Vbar :: struct {
	shown:                                bool,
	x, track_y, track_h, thumb_y, thumb_h: f32,
}

vscrollbar_geo :: proc(doc: ^Document, x, winh: f32, bottom: int, t: ^plat.Text, rows: int) -> (b: Vbar) {
	if doc == nil || doc.pt.length <= 0 {return}
	total := f32(doc.pt.length)
	b.x = x
	b.track_y, b.track_h = scrollbar_track(doc, winh)
	b.thumb_h = clamp(f32(bottom - doc.top) / total * b.track_h, sx(24), b.track_h)
	// The thumb travels the track MINUS its own height, not the whole track --
	// at the document end its BOTTOM meets the track's bottom, not its top. The
	// clamp is kept as a belt for the ends, but it is no longer what does the
	// work, and that distinction is the fix: with the full track as the
	// multiplier this map and vbar_drag_to's inverse disagreed by
	// track_h / (track_h - thumb_h), so pressing the thumb and holding perfectly
	// still moved the document by ~3% of its length. The two are exact inverses
	// now, which is what makes "grab it and it does not move" true rather than
	// approximately true.
	//
	// Mapped against the SCROLLABLE range, not the document length. doc.top is
	// the top visible line's offset, which at the end of the document is
	// doc_max_top -- never pt.length. Dividing by pt.length made the ratio peak
	// at (length - one screenful)/length, so the thumb stopped short by exactly
	// the visible fraction of the file: on a document where a screen is a fifth
	// of the content it halted at 80%, which is what Wyatt measured by eye.
	// doc_scroll_to_fraction (the inverse vbar_drag_to calls through) maps by
	// the same doc_max_top, so the two stay exact inverses of each other.
	max_top := f32(max(1, doc_max_top(doc, t, rows)))
	travel := max(1, b.track_h - b.thumb_h)
	b.thumb_y = clamp(b.track_y + f32(doc.top) / max_top * travel, b.track_y, b.track_y + b.track_h - b.thumb_h)
	b.shown = true
	return
}

// The two vertical bars as they were last DRAWN, written by render_frame and
// read by the press hit-test in the frame loop.
//
// One frame stale, and that is the correct staleness rather than a compromise:
// the question a press asks is "was the pointer on the thumb the user can see",
// and the thumb the user can see is the one the last frame drew. Recomputing it
// at press time would test against a thumb that has never been on screen.
g_vbar_editor: Vbar
g_vbar_preview: Vbar

// Where the pointer sat inside the thumb when the drag began, so the thumb stays
// under the cursor instead of jumping to it. Zero after a press on the bare rail,
// which is what makes that press put the thumb's top at the cursor -- the jump
// Wyatt confirmed is the wanted behaviour -- and then track smoothly from there.
vscroll_grab: f32
preview_grab: f32
hscroll_grab: f32

// Where in the thumb a press landed. On the thumb, that offset; on the bare
// rail, zero -- which makes the first drag frame put the thumb's TOP at the
// cursor, the jump this bar has always made and the one Wyatt confirmed is
// right. The difference from before is that it now happens once, at the press,
// rather than being recomputed from the raw pointer on every frame of the hold.
vbar_grab_at :: proc(b: Vbar, my: f32) -> f32 {
	if b.shown && my >= b.thumb_y && my < b.thumb_y + b.thumb_h {return my - b.thumb_y}
	return 0
}

// The fraction of the scrollable range a vertical drag is pointing at.
//
// Positions the THUMB (pointer minus the grab) and converts THAT, rather than
// mapping the pointer straight onto the track -- the difference between dragging
// a thumb and teleporting it. One expression, shared by the editor's bar and the
// preview's, because the two bars now map onto different models and the only
// thing keeping them honest is that the pointer-to-fraction half is identical.
vbar_frac_at :: proc(b: Vbar, my, grab: f32) -> f32 {
	return clamp(((my - grab) - b.track_y) / max(1, b.track_h - b.thumb_h), 0, 1)
}

// One frame of a vertical scrollbar drag, on the editor's byte model.
vbar_drag_to :: proc(doc: ^Document, t: ^plat.Text, b: Vbar, my, grab: f32, rows: int) {
	if !b.shown {return}
	doc_scroll_to_fraction(doc, t, vbar_frac_at(b, my, grab), rows)
}

// The preview's vertical scrollbar geometry -- vscrollbar_geo's counterpart for
// a pane that scrolls in pixels.
//
// It has to keep that procedure's hard-won property, and by the same argument:
// the thumb's BOTTOM meets the track's bottom at the end of the scrollable
// range, not its top, so the multiplier is the track minus the thumb and the
// fraction is measured against the range's end. The range is the PREVIEW's own
// (md_max_anchor) rather than the editor's doc_max_top, which is the defect this
// replaces -- the preview covers roughly three times the source per screen that
// the editor does, so mapping it against the editor's ceiling left the thumb
// short and the last stretch of travel showing nothing new.
//
// The thumb's SIZE stays byte-proportional -- the visible byte span over the
// document's length, exactly as the editor's is. A pixel-proportional size would
// need the document's total HEIGHT, and measuring that means laying the document
// out, which is the one thing viewport-first forbids.
//
// `shown_end` is markdown_draw's `shown` out-param, NOT its `bottom` return
// (2026-07-29 review, F1). `bottom` only advances past a block the pane
// FINISHED, so when the topmost visible block is taller than the pane --
// one long paragraph, Split at half width or a larger font -- `bottom` sits at
// `doc.md_top.block` for the entire scroll through it: `shown_end - doc.md_top.block`
// is always 0, `clamp(0, sx(24), track)` pins the thumb at its 24px floor, and it
// snaps to full height the instant the block clears the top edge. `shown_end`
// instead credits a partial block with the fraction of its span actually put on
// screen, so the thumb shrinks and grows with what is visible rather than
// collapsing to a stub and popping.
md_vscrollbar_geo :: proc(doc: ^Document, x, winh: f32, shown_end: int, frac: f32) -> (b: Vbar) {
	if doc == nil || doc.pt.length <= 0 {return}
	b.x = x
	b.track_y, b.track_h = scrollbar_track(doc, winh)
	b.thumb_h = clamp(f32(shown_end - doc.md_top.block) / f32(doc.pt.length) * b.track_h, sx(24), b.track_h)
	b.thumb_y = clamp(b.track_y + frac * max(1, b.track_h - b.thumb_h), b.track_y, b.track_y + b.track_h - b.thumb_h)
	b.shown = true
	return
}

// One movement of the preview, and 9.4's write-back to the editor.
//
// THE producer of doc.md_top outside the sync itself: the wheel, the preview's
// scrollbar drag and anything added later all come through here, so the
// md_sync_top latch cannot be left behind by a path that forgot it -- which
// would make the next frame's sync snap the preview back to the editor's line
// and undo the gesture.
//
// 9.4, "scroll sync by block, not by line": the editor's top goes to the START
// of the block the preview is showing. By block and not by line deliberately --
// a line-based map drifts the moment a heading or a fence changes height, which
// is the usual reason split views feel broken.
md_preview_scroll :: proc(doc: ^Document, c: ^Md_Scroll_Ctx, t: ^plat.Text, a: Md_Anchor, rows: int) {
	doc.md_top = a
	doc.top = min(md_anchor_top_byte(c, a), doc_max_top(doc, t, rows))
	doc.md_sync_top = doc.top
}

hscrollbar_pos_at :: proc(b: Hbar, thumb_x: f32, m: Hscroll) -> int {
	frac := (thumb_x - b.track_x) / max(1, b.track_w - b.thumb_w)
	return clamp(int(frac * f32(m.max) + 0.5), 0, m.max)
}

// Draw one frame from current state. No input handling — safe to call from the
// main loop or the WM_SIZE handler. vsync=false (resize) presents immediately so
// clustered WM_SIZE repaints don't each stall on vsync.
render_frame :: proc(rc: ^Render_Ctx, vsync := true) {
	gfx, text, quad_pipe, window := rc.gfx, rc.text, rc.quads, rc.window
	px, char_w, line_h := rc.px, rc.char_w, rc.line_h
	doc := app_active(rc.app)
	doc_update_top_inset(doc) // filter banner inset; must match the main loop's value
	// The same split the frame loop makes (see its comment): `rows` is what
	// fits wholly and feeds the scroll/scrollbar geometry, `drawn` adds the
	// partial last row and feeds every pass that puts pixels on a text row.
	// The frame loop's hit-test reads `drawn` too, so what is clickable is what
	// was drawn.
	rows := doc_visible_rows(doc, f32(window.height), line_h)
	drawn := doc_drawn_rows(doc, f32(window.height), line_h)
	// The grid's budget, same producer and same reasoning as the frame loop's
	// (see its comment). Recomputed here rather than passed in because a resize
	// repaints through this path without going round the loop, and a grid drawn
	// to a stale row count is a grid whose last row is not where the loop's
	// hit-test thinks it is.
	trows := table_visible_rows(doc, f32(window.height), px)
	srows := doc_scroll_rows(doc, f32(window.height), line_h, px) // the bar's count; see doc_scroll_rows
	doc_update_gutter(doc, char_w) // resize repaints come through here too
	// Recompute the wrap width here (not just in the main loop) so word wrap
	// re-flows live during a resize, which repaints through this path.
	doc.view_cols = doc_view_cols(doc_editor_right(doc, f32(window.width), rc.app.settings.split_frac), char_w)
	doc_update_hscroll(doc) // mirror the (already-clamped) horizontal offset

	plat.text_frame_begin(gfx, text) // resets the recycle guard and grows the atlas if owed
	// The clear IS the document canvas (see doc_canvas_clear's comment) -- it must
	// read Bg_Base, not carry its own copy of it. This used to be a bare literal,
	// {0.09, 0.11, 0.16} = Dark's old #171C29, which kept the canvas dark under
	// Light: a shape (three loose f32 args, not a `{r, g, b, a}` composite) that
	// survived five reviews of this batch because none of their greps matched it.
	clear_col := doc_canvas_clear()
	plat.gfx_begin_frame(gfx, clear_col[0], clear_col[1], clear_col[2])

	cx, cy: f32
	caret := false
	bottom := doc.top
	shown := doc.md_top.block // markdown_draw's out-param; feeds md_vscrollbar_geo's thumb, not bottom (F1)
	if doc.kind == .Text && doc.md_mode == .Preview {
		// Full-window rendered markdown (read-only) replaces the text pass.
		// The pane box comes from md_pane_box, the SAME producer the link pass
		// reads -- so what is clickable and what is drawn cannot be laid out in
		// two different rectangles.
		if mx0, mx1, mytop, mybot, mok := md_pane_box(doc, f32(window.width), f32(window.height), rc.app.settings.split_frac); mok {
			bottom = markdown_draw(gfx, quad_pipe, text, doc, px, mx0, mx1, mytop, mybot, doc.md_top, &shown)
			if plat.key_ctrl_down() || rc.app.settings.link_style != .Hover {
				md_draw_links(gfx, quad_pipe, md_preview_links(gfx, text, doc, px, f32(window.width), f32(window.height), rc.app.settings.split_frac))
			}
			// The anchor block is routinely PARTLY above the pane -- that is what a
			// pixel offset is -- and there is no scissor rect here. See
			// md_preview_clip.
			md_preview_clip(gfx, quad_pipe, doc, f32(window.width), f32(window.height), rc.app.settings.split_frac)
		}
	} else if doc.table && doc.kind == .Text {
		// Read-only grid view (CSV/TSV) replaces the text pass entirely.
		bottom = table_draw(gfx, quad_pipe, text, doc, px, char_w, trows, f32(window.width))
		// Underline links in the cells while Ctrl is held (or Show-links is on).
		if plat.key_ctrl_down() || rc.app.settings.link_style != .Hover {
			for tl in table_links(doc, text, px, char_w, trows, f32(window.width)) {
				plat.quads_draw(gfx, quad_pipe, []plat.Quad{{pos = {tl.x, tl.y + sx(2)}, size = {tl.w, hairline()}, color = g_theme[.Link]}})
			}
		}
	} else {
		// Behind the text: find-match highlights (dim), then the selection (bright).
		if !doc.filter {
			findq: [80]plat.Quad
			if nfq := find_match_rects(doc, text, px, char_w, drawn, findq[:]); nfq > 0 {
				plat.quads_draw(gfx, quad_pipe, findq[:nfq])
			}
			selq: [80]plat.Quad
			// A column rectangle is still a selection (same fill role,
			// Selection_Doc) -- it just gets its geometry from block_row_range
			// instead of the linear anchor/cursor pair, so the draw call
			// swaps procedures rather than branching inside one of them.
			ns := block_selection_rects(doc, text, px, char_w, drawn, selq[:]) if block_active(doc) else doc_selection_rects(doc, text, px, char_w, drawn, selq[:])
			if ns > 0 {
				plat.quads_draw(gfx, quad_pipe, selq[:ns])
			}
		}

		// Links. When shown (always, or only on Ctrl per the Show-links setting) the
		// list is produced once and consumed by the underline here, the glyph
		// colouring inside doc_draw, and the hover/click in the main loop. The
		// underline is drawn while Ctrl is held (the activation affordance) or when
		// the setting forces it; the "tint" style shows colour without an underline.
		links: []Link_Hit
		ctrl := plat.key_ctrl_down()
		style := rc.app.settings.link_style
		if !doc.filter && (ctrl || style != .Hover) {
			links = links_layout(doc, text, drawn)
			if ctrl || style == .Underline {
				for h in links {
					plat.quads_draw(
						gfx,
						quad_pipe,
						[]plat.Quad {
							{
								pos = {col_x(char_w, h.col, 0 if h.wrapped else H_SCROLL), row_baseline_y(px, h.row) + sx(2)},
								size = {f32(h.cells) * char_w, hairline()},
								color = g_theme[.Link],
							},
						},
					)
				}
			}
		}

		cx, cy, caret, bottom = doc_draw(gfx, text, doc, px, char_w, drawn, links)
	}

	// Horizontal scroll draws each line shifted left, so glyphs left of the first
	// visible cell bleed into the left margin. Cover that thin strip with the
	// background (the caret sits at/after the margin, so it is never covered; the
	// right-side overrun is already hidden by the scrollbar drawn below).
	if H_SCROLL > 0 {
		ctop, cbot := doc_content_box(doc, f32(window.height))
		plat.quads_draw(gfx, quad_pipe, []plat.Quad{{pos = {0, ctop}, size = {TEXT_MARGIN_X, cbot - ctop}, color = g_theme[.Bg_Base]}})
	}

	// Bookmark marks, in the left margin. AFTER the H_SCROLL cover strip above,
	// not with the selection/find quads behind the text: that strip repaints
	// [0, TEXT_MARGIN_X) with the canvas colour whenever the view is panned
	// horizontally, which is exactly the band these are drawn in -- so drawing
	// them earlier would make every mark vanish the moment the user scrolls
	// right. Skipped in the grid view, which has no text rows to mark.
	// Skipped in every view that replaces the text pass, because the marks are
	// positioned by the SOURCE line rows and those views lay out on a different
	// model: the grid (table_draw) and full Markdown Preview (markdown_draw).
	// Split is fine — the editor pass really runs in its left half. Preview was
	// missed when this was written, and the stray ticks it produced sat in the
	// left margin pointing at nothing.
	if doc != nil && doc.kind == .Text && !doc.table && doc.md_mode != .Preview {
		bmq: [80]plat.Quad
		if nbq := doc_bookmark_rects(doc, text, px, drawn, bmq[:]); nbq > 0 {
			plat.quads_draw(gfx, quad_pipe, bmq[:nbq])
		}
	}

	// Scrollbar (byte-proportional, below the tab strip) + caret. In Markdown Split
	// the editor's scrollbar sits at the split, not the window edge (the preview's
	// is drawn separately below).
	bars: [4]plat.Quad
	nb := 0
	w := f32(window.width)
	h := f32(window.height)
	er := doc_editor_right(doc, w, rc.app.settings.split_frac)
	total := doc.pt.length
	if total > 0 && !doc.filter {
		vb: Vbar
		if doc.kind == .Text && doc.md_mode == .Preview {
			// Full Preview replaces the editor pane, so the one bar at the window
			// edge is the PREVIEW's and maps the preview's own pixel range. It goes
			// to g_vbar_preview, which is the latch the press hit-test reads for
			// this mode (the editor branch there is disabled in Preview).
			vb = md_vscrollbar_geo(doc, er - SCROLLBAR_W, h, shown, md_preview_frac(gfx, text, doc, px, w, h, rc.app.settings.split_frac))
			g_vbar_preview = vb
		} else {
			vb = vscrollbar_geo(doc, er - SCROLLBAR_W, h, bottom, text, srows)
			g_vbar_editor = vb // what the press hit-tests against next frame
		}
		sb_h, th, ty := vb.track_h, vb.thumb_h, vb.thumb_y
		track := plat.Quad{pos = {vb.x, vb.track_y}, size = {SCROLLBAR_TRACK_W, sb_h}, color = g_theme[.Bg_Raised]}
		// Find-match ticks, drawn BETWEEN the track and the thumb.
		//
		// Under the thumb rather than over it, deliberately. No single colour
		// reads strongly on both surfaces in Dark -- the track is near-black and
		// the thumb is a pale grey -- and the marks the user actually needs are
		// the ones OFF screen: every match the thumb covers is already on screen
		// with its own highlight behind the text. The cost is that a file small
		// enough to fit in the window hides its marks behind a full-height thumb,
		// which is exactly the file that does not need them.
		//
		// Costs two extra quads_draw calls -- the marks' own, plus the track's,
		// which can no longer share a batch with the thumb now that something is
		// drawn between them -- and only while the find bar is open with matches.
		// find_mark_cap returns 0 otherwise and this whole block is skipped,
		// allocation included; measured on HANDOFF.md, 7 -> 9 calls with the bar
		// open and 4 with it shut, which is what it was before this existed.
		if mc := find_mark_cap(doc, sb_h); mc > 0 {
			marks := make([]plat.Quad, mc, context.temp_allocator)
			nmk, _ := find_mark_rects(doc, er - SCROLLBAR_W, SCROLLBAR_TRACK_W, CHROME_TOP, sb_h, marks)
			if nmk > 0 {
				plat.quads_draw(gfx, quad_pipe, []plat.Quad{track})
				plat.quads_draw(gfx, quad_pipe, marks[:nmk])
			} else {
				bars[nb] = track;nb += 1
			}
		} else {
			bars[nb] = track;nb += 1
		}
		bars[nb] = {pos = {er - SCROLLBAR_W, ty}, size = {SCROLLBAR_TRACK_W, th}, color = g_theme[.Scrollbar_Thumb]};nb += 1
	}
	if caret {
		bars[nb] = {pos = {cx, cy - px}, size = {sx(2), line_h}, color = g_theme[.Caret]};nb += 1
	}
	if nb > 0 {
		plat.quads_draw(gfx, quad_pipe, bars[:nb])
	}

	// Markdown Split: a divider, the live preview in the right half, and a second
	// scrollbar on the preview's OWN pixel range (md_vscrollbar_geo) -- the two
	// panes no longer share one scroll position, they are mapped onto each other
	// by block once a frame. See the sync in the frame loop.
	if doc.kind == .Text && doc.md_mode == .Split {
		pvtop, pvbot := doc_content_box(doc, h)
		// The editor pass above draws full-window width, so its lines bleed into the
		// right half where the preview lives. There is no scissor rect (the H_SCROLL
		// margin above uses the same trick), so paint the right half back to the
		// background before the preview, giving two clean side-by-side panes.
		plat.quads_draw(gfx, quad_pipe, []plat.Quad{{pos = {er, pvtop}, size = {w - er, pvbot - pvtop}, color = g_theme[.Bg_Base]}})
		// The visible accent line is thinner than the draggable band; both come from
		// md_divider_rect so the drawn line always sits exactly where a drag grabs it.
		dr := md_divider_rect(doc, w, h, rc.app.settings.split_frac)
		line_w := hairline()
		plat.quads_draw(gfx, quad_pipe, []plat.Quad{{pos = {dr.pos.x + dr.size.x * 0.5 - line_w * 0.5, dr.pos.y}, size = {line_w, dr.size.y}, color = g_theme[.Border_Strong]}})
		// The preview draws from its OWN pixel anchor (doc.md_top), which the
		// frame's sync has already mapped onto doc.top by block. Pane box from
		// md_pane_box, the producer the link pass reads too.
		// `mok` is CHECKED here, as the .Preview branch above already checks it
		// (L4, 2026-07-29): md_pane_box returns ok=false for a pane with no width
		// -- a split fraction dragged to the right edge, or a window narrower than
		// the divider plus the scrollbar -- and drawing into x1 <= x0 would hand
		// md_content_span a negative span, which max(1, ..) turns into a 1px
		// measure and a column of one glyph per line.
		if mx0, mx1, mytop, mybot, mok := md_pane_box(doc, w, h, rc.app.settings.split_frac); mok {
			pv_shown: int
			markdown_draw(gfx, quad_pipe, text, doc, px, mx0, mx1, mytop, mybot, doc.md_top, &pv_shown)
			if plat.key_ctrl_down() || rc.app.settings.link_style != .Hover {
				md_draw_links(gfx, quad_pipe, md_preview_links(gfx, text, doc, px, w, h, rc.app.settings.split_frac))
			}
			md_preview_clip(gfx, quad_pipe, doc, w, h, rc.app.settings.split_frac)
			if total > 0 {
				pvb := md_vscrollbar_geo(doc, w - SCROLLBAR_W, h, pv_shown, md_preview_frac(gfx, text, doc, px, w, h, rc.app.settings.split_frac))
				g_vbar_preview = pvb
				plat.quads_draw(
					gfx,
					quad_pipe,
					[]plat.Quad {
						{pos = {pvb.x, pvb.track_y}, size = {SCROLLBAR_TRACK_W, pvb.track_h}, color = g_theme[.Bg_Raised]},
						{pos = {pvb.x, pvb.thumb_y}, size = {SCROLLBAR_TRACK_W, pvb.thumb_h}, color = g_theme[.Scrollbar_Thumb]},
					},
				)
			}
		}
	}

	// Clip the document to the content box, by repainting the bottom strip.
	//
	// There is no scissor rect in this renderer (see the H_SCROLL cover strip
	// above and the Split preview's repaint, which are the same trick), and the
	// status line is NOT drawn on an opaque band -- it is text on the bare
	// canvas. So anything a content pass puts below doc_content_box's `bot`
	// stays on screen sitting on top of the status bar. Two passes can still do
	// that on purpose: doc_draw's partial last row, and markdown_draw's ONE
	// remaining deliberate overhang -- the `forced` first LINE, spent once, so a
	// pane too short for even one line shows something instead of nothing (see
	// md_block_admit in markdown.odin).
	//
	// The soft-wrap overhang that used to be listed here is gone: batch 17 lays
	// the preview out in BLOCKS, and a block's height comes back from the shaper
	// with its wrapped lines already in it (Md_Layout.h), so the admit test and
	// the advance read the same number.
	//
	// 2026-07-29: admission is now per LINE within a block, not per block, because
	// refusing a whole paragraph left up to a paragraph's height of blank pane
	// under the last heading (Wyatt, live use) -- "no frame ever shows emptiness".
	// That does NOT widen what overhangs this strip: a line is admitted only when
	// its own bottom edge clears ybot, and the block's trailing decoration (an
	// h1/h2 rule) belongs to its last line's bottom (md_line_bottom), so a heading
	// whose rule will not fit still draws without the rule rather than painting it
	// down here. The `forced` waiver above is the only thing that overhangs, and it
	// is now one line rather than one whole block.
	//
	// Placed after every DOCUMENT pass (editor, grid, preview, both scrollbars,
	// the caret) and before every CHROME pass -- the horizontal scrollbar sits
	// at bot - its height, and the tab rail, menus, palette and status text all
	// draw later -- so it clips content without erasing anything that is allowed
	// to overlap the strip.
	{
		_, cbot := doc_content_box(doc, h)
		plat.quads_draw(gfx, quad_pipe, []plat.Quad{{pos = {0, cbot}, size = {w, h - cbot}, color = doc_canvas_clear()}})
	}

	// Horizontal scrollbar: cells in the text view, columns in the grid, hidden
	// where the content lays out to fit. hscroll_model is the one authority.
	if hb := hscrollbar_geo(doc, er, h, hscroll_model(doc, text, er, char_w)); hb.shown {
		plat.quads_draw(
			gfx,
			quad_pipe,
			[]plat.Quad {
				{pos = {hb.track_x, hb.y}, size = {hb.track_w, hb.h}, color = g_theme[.Bg_Raised]},
				{pos = {hb.thumb_x, hb.y}, size = {hb.thumb_w, hb.h}, color = g_theme[.Text_Muted]},
			},
		)
	}

	// Filter view replaces the document with just the matching lines, which is
	// disorienting if you don't know why. Say so, and say how to leave.
	//
	// Drawn BEFORE the chrome: it sits at the top of the content area, which is
	// exactly where menus and the palette drop down, and drawing it afterwards
	// painted it over them.
	if doc.filter && doc.find.active {
		// Sits in the reserved inset below the menu bar (see FILTER_BANNER_H), so
		// it no longer draws half under the menu or over the first matching line.
		by := CHROME_TOP
		// Accent_Wash, the same fill a selected settings row uses. UI spec 12: "a
		// mode must be obvious; it does not have to be the loudest thing on
		// screen. Same fill as a selected settings row, so 'something is active'
		// reads consistently across the app." The 2px accent bar is what keeps it
		// from being colour alone.
		plat.quads_draw(
			gfx,
			quad_pipe,
			[]plat.Quad {
				{pos = {0, by}, size = {w, FILTER_BANNER_H}, color = g_theme[.Accent_Wash]},
				{pos = {0, by}, size = {max(2, sx(2)), FILTER_BANNER_H}, color = g_theme[.Accent]},
			},
		)
		// filter_banner_text (find.odin) owns the wording, so "searching" and
		// "no matching lines" cannot collapse into one string again.
		plat.text_draw(gfx, text, filter_banner_text(doc), sx(12), by + FILTER_BANNER_H - sx(7), UI_SMALL_PX, g_theme[.Text_Primary])
	}

	// Keep the active tab on screen before the rail is drawn -- and before the
	// hit-test next frame reads the same layout.
	tabs_reveal_active(rc.app, window, text, w)
	tabs_draw(gfx, quad_pipe, text, rc.app, window, w)
	if doc.kind == .Font {
		font_page_draw(gfx, quad_pipe, text, rc.app, w, h)
	} else if doc.kind == .Settings {
		settings_draw(gfx, quad_pipe, text, rc.app, w, h)
	} else if rc.app.history.open {
		history_draw(gfx, quad_pipe, text, rc.app, w, h)
	}
	menu_draw(gfx, quad_pipe, text, rc.app, window, w, h)

	if rc.app.palette.active {
		palette_draw(gfx, quad_pipe, text, rc.app, w, h)
	}

	// Whether the transient notice (e.g. "2 items skipped" from a drop) is
	// still live -- checked once per frame regardless of which branch below
	// runs. This used to be a countdown that only decremented inside the
	// no-find-bar branch, so opening find paused it indefinitely; app_notice_
	// active is now a wall-clock check against app.odin's NOTICE_SECONDS, so
	// it expires on schedule whether or not find happens to be open.
	notice_live := app_notice_active(rc.app)

	// The find bar, at the TOP of the editor (UI spec 12). It used to occupy the
	// bottom strip INSTEAD of the status line -- the two shared one if/else, so
	// opening find hid the file's encoding, line endings and position. They are
	// independent now: the bar insets the content from above, the status line
	// keeps its own strip below, and both are visible at once.
	if doc.find.active {
		f := &doc.find
		bar_h := doc_top_bar_h(doc)
		by := CHROME_TOP
		plat.quads_draw(
			gfx,
			quad_pipe,
			[]plat.Quad {
				{pos = {0, by}, size = {w, bar_h}, color = g_theme[.Bg_Panel]},
				{pos = {0, by + bar_h - hairline()}, size = {w, hairline()}, color = g_theme[.Border_Subtle]},
			},
		)
		row_h := sx(FIND_BAR_H_96)
		fbase := by + row_h * 0.5 + UI_PX * 0.35
		cw := plat.text_char_width(text, UI_PX)

		// Three toggles, always visible and always labelled. UI spec 12: "while
		// regex is a hidden Ctrl+R state, there is no way to tell why a search is
		// behaving oddly." Active ones take the accent fill, so the state is
		// readable without hovering anything.
		tbuf: [3]Find_Toggle
		for t in find_toggles(doc, w, tbuf[:]) {
			if t.on {
				plat.quads_draw(gfx, quad_pipe, []plat.Quad{{pos = {t.x, by + sx(7)}, size = {t.w, row_h - sx(14)}, color = g_theme[.Accent], radius = {RADIUS_ROW, RADIUS_ROW, RADIUS_ROW, RADIUS_ROW}}})
			}
			lc := g_theme[.Bg_Base] if t.on else g_theme[.Text_Muted]
			plat.text_draw(gfx, text, t.label, t.x + (t.w - f32(len(t.label)) * cw) * 0.5, fbase, UI_PX, lc)
		}

		// The query, and the count beside it -- not in the status bar, "700
		// pixels from where you are looking".
		fcaret := "_" if f.field == 0 else ""
		fline := fmt.tprintf("%s%s%s", "Filter: " if doc.filter else "Find: ", string(f.query[:]), fcaret)
		plat.text_draw(gfx, text, fline, sx(12), fbase, UI_PX, g_theme[.Text_Primary])
		info := find_status_info(doc)
		if info != "" {
			ix := sx(12) + f32(len(fline)) * cw + sx(16)
			// Zero results colours the count rather than beeping or shaking.
			ic := g_theme[.Danger] if len(f.matches) == 0 && len(f.query) > 0 else g_theme[.Text_Muted]
			plat.text_draw(gfx, text, info, ix, fbase, UI_PX, ic)
		}
		if f.replace_mode {
			rcaret := "_" if f.field == 1 else ""
			rline := fmt.tprintf("Replace: %s%s", string(f.replace[:]), rcaret)
			plat.text_draw(gfx, text, rline, sx(12), fbase + row_h, UI_PX, g_theme[.Text_Bright])

			// The two action buttons. Every coordinate here comes out of
			// find_actions -- the box, the label origin, the chord origin -- and
			// the same procedure answers the click (the frame loop), the hover
			// fill below and the pointer cursor. Nothing on this row computes a
			// coordinate twice; see Find_Action's comment for why that is the
			// rule and not a preference.
			abuf: [2]Find_Action
			acts := find_actions(doc, text, w, abuf[:])
			hovered := Command_Id.None
			if len(acts) > 0 {
				cx, cy := plat.window_cursor_client(window)
				hovered = find_action_at(doc, text, w, f32(cx), f32(cy))
			}
			for a in acts {
				plat.quads_draw(
					gfx,
					quad_pipe,
					[]plat.Quad {
						{
							pos = {a.x, a.y},
							size = {a.w, a.h},
							color = g_theme[.Bg_Hover] if a.cmd == hovered else g_theme[.Bg_Raised],
							radius = {RADIUS_ROW, RADIUS_ROW, RADIUS_ROW, RADIUS_ROW},
						},
					},
				)
				plat.text_draw(gfx, text, a.label, a.tx, a.ty, UI_SMALL_PX, g_theme[.Text_Primary])
				// The chord in the muted tier beside the verb, which is exactly how
				// the menus draw their shortcut column (menu.odin) -- one visual
				// convention for "this is the key that does this", so the row
				// teaches without needing a sentence.
				if a.chord != "" {
					plat.text_draw(gfx, text, a.chord, a.cx, a.ty, UI_SMALL_PX, g_theme[.Text_Muted])
				}
			}
			// The mode hints keep the rest of the row, up to the buttons' left
			// edge. They are drawn last and skipped when the space between the
			// replace field and the buttons cannot hold them, so a narrow window
			// loses the hints rather than overlapping three runs of text.
			hint_right := w - sx(12)
			if len(acts) > 0 {hint_right = acts[0].x - sx(12)}
			hint_find(gfx, text, f, doc, hint_right, sx(12) + f32(len(rline) + 2) * cw, fbase + row_h)
		}
	}
	{
		// Either figure can be unknown on a huge file: both are capped so the status
		// bar never spends an unbounded scan. Say what is known rather than printing
		// a placeholder number that reads as fact.
		ln := doc_cursor_line(doc)
		cl := doc_cursor_col(doc, text)
		lncol: string
		switch {
		case ln > 0 && cl > 0:
			lncol = fmt.tprintf("Ln %d, Col %d", ln, cl)
		case cl > 0:
			lncol = fmt.tprintf("Col %d", cl)
		case ln > 0:
			lncol = fmt.tprintf("Ln %d", ln)
		case:
			lncol = "Ln -, Col -"
		}
		recovered := "  [RECOVERED COPY - file changed on disk, not the original]" if doc.recovered else ""
		// Only ever shown for a modified document: a clean one is reloaded
		// silently, so a marker here always means there is a real choice to make.
		disk := ""
		if doc.disk_gone {
			disk = "  [FILE DELETED ON DISK - your text is still here; Save to write it back]"
		} else if doc.disk_changed {
			disk = "  [CHANGED ON DISK - you have unsaved edits. File > Reload to discard yours]"
		}
		indexing := "" if doc_index_done(doc) else fmt.tprintf("  (indexing %.0f%%)", doc_index_progress(doc) * 100)
		// The atlas has no eviction: once full, further glyphs draw as nothing
		// while the pen still advances, so text goes missing with no other
		// symptom. Say so rather than let it look like a corrupt file.
		atlas := "  [GLYPH CACHE FULL - some text may not draw; reduce zoom or font size]" if plat.text_atlas_full(text) else ""
		// A dirty buffer too large to auto-back-up: unsaved edits are not
		// crash-protected until saved (backing it up would freeze/OOM the app).
		nobackup := "  [LARGE FILE - unsaved edits are NOT auto-backed up; Save to keep them]" if doc_backup_skipped(doc) else ""
		mode := "    Wrap" if doc.wrap else ""
		if doc.table {mode = "    Table (Ctrl+T)"}
		switch doc.md_mode {
		case .Off:
		case .Preview:
			mode = "    Markdown Preview (Ctrl+M)"
		case .Split:
			mode = "    Markdown Split (Ctrl+M)"
		}
		// The transient notice rides along on the same line while notice_live
		// (see above).
		notice := ""
		if notice_live {
			notice = fmt.tprintf("    %s", rc.app.notice)
		}
		// Two groups, not one sentence. UI spec 13: facts about POSITION on the
		// left, facts about the FILE on the right, "a fixed home for each, so the
		// eye learns where to look". Everything transient -- warnings, the disk
		// state, the indexing progress, the notice -- rides with the left group,
		// because that is the half that is already changing as you work.
		//
		// A selection replaces the line count while it exists, in the accent, per
		// the same section: when you have selected something, how much you have
		// selected is the number you want in that slot.
		count := fmt.tprintf("%d lines", doc_line_count(doc))
		selected := false
		if lo, hi := doc_sel_range(doc); hi > lo {
			count = fmt.tprintf("%d selected", hi - lo)
			selected = true
		}
		left := fmt.tprintf("%s    %s%s%s%s%s%s%s", lncol, count, " *" if doc.modified else "", recovered, disk, indexing, atlas, nobackup)
		// `mode` is not a cell: it names the VIEW, which the menus own, and there
		// is no single obvious action for a click on it.
		right := mode // reassigned by the drop order below

		warn := doc.recovered || doc.disk_changed || doc.disk_gone || plat.text_atlas_full(text) || doc_backup_skipped(doc)
		// Text_Muted, not Text_Dim. Text_Dim is the disabled-only tier at 2.9:1 --
		// below the AA floor by design and labelled "never live text" in
		// theme.odin -- and the status bar is live text on every frame. Same
		// defect the tab labels carried.
		col := g_theme[.Warning] if warn else g_theme[.Text_Muted]
		base_y := h - sx(8)
		cw := plat.text_char_width(text, UI_SMALL_PX)
		plat.text_draw(gfx, text, left, sx(12), base_y, UI_SMALL_PX, g_theme[.Accent] if selected else col)
		// The cells, from the one geometry the click also reads, with a hairline
		// divider in each gap. UI spec 13: "Cells, not a sentence... a fixed home
		// for each, so the eye learns where to look."
		// UI spec 5's drop order, enforced rather than implied.
		//
		// The window has a floor now (WM_GETMINMAXINFO), but between that floor
		// and a comfortable width nothing DROPPED in order -- the right-hand
		// cells simply kept being drawn until they ran into the left group and
		// the two overlapped into an unreadable middle. The spec's order is
		// explicit: "Status cells drop right-to-left: Tab width -> LF -> UTF-8 ->
		// language. Ln/Col and the line count always stay."
		//
		// Measured against what the LEFT group actually needs, not against a
		// hardcoded breakpoint, so it holds at any DPI and any font.
		cbuf: [4]Status_Cell
		cells := status_cells(doc, w, cw, cbuf[:])
		{
			need := sx(12) + f32(len(left)) * cw + sx(24)
			// Drop from the left end of the right-hand group, which is the
			// rightmost cell in reading order -- status_cells places them right
			// to left, so the LAST entry is the leftmost on screen.
			for len(cells) > 0 && cells[len(cells) - 1].x < need {
				cells = cells[:len(cells) - 1]
			}
			// The view name goes before any cell does: it is the least useful of
			// the three and the widest.
			if len(cells) < 2 || (len(cells) > 0 && cells[len(cells) - 1].x - sx(24) - f32(len(right)) * cw < need) {
				right = ""
			}
		}
		for c, i in cells {
			plat.text_draw(gfx, text, c.label, c.x, base_y, UI_SMALL_PX, col)
			// A divider between cells, never after the last one -- the cells are
			// placed right to left, so the LAST in this list is the leftmost.
			if i + 1 < len(cells) {
				dx := cells[i + 1].x + cells[i + 1].w + sx(12)
				plat.quads_draw(gfx, quad_pipe, []plat.Quad{{pos = {snap(dx), h - doc_bottom_bar_h(doc) + sx(6)}, size = {hairline(), doc_bottom_bar_h(doc) - sx(12)}, color = g_theme[.Border_Subtle]}})
			}
		}
		// Whatever is left of the cells (the view name) keeps its own slot.
		if right != "" {
			rx := cells[len(cells) - 1].x - sx(24) - f32(len(right)) * cw if len(cells) > 0 else w - sx(12) - f32(len(right)) * cw
			plat.text_draw(gfx, text, right, rx, base_y, UI_SMALL_PX, col)
		}
		// The transient notice sits between them, in Success when it is a
		// confirmation and Warning otherwise -- "[SAVED]" is the one message that
		// reports something going right.
		if notice_live {
			nt := rc.app.notice
			ncol := g_theme[.Success] if (len(nt) >= 6 && nt[:6] == "[SAVED") else g_theme[.Warning]
			plat.text_draw(gfx, text, nt, snap((w - f32(len(nt)) * cw) * 0.5), base_y, UI_SMALL_PX, ncol)
		}
		_ = notice
	}

	plat.gfx_end_frame(gfx, 1 if vsync else 0)
}

// The find bar's own toggles, right-aligned, active ones lit. These commands
// exist only inside find mode, so without this the only way to learn Alt+R and
// Ctrl+L was to be told they were there.
// `right` is the edge to end at (the action buttons' left edge, once they are on
// the row) and `min_x` the first pixel they may not cross -- the end of the
// "Replace: ..." field. Purely decorative text, so the answer to not fitting is
// to draw nothing: three overlapping runs are less readable than two.
@(private = "file")
hint_find :: proc(gfx: ^plat.Gfx, text: ^plat.Text, f: ^Find, doc: ^Document, right, min_x, y: f32) {
	on := g_theme[.Accent]
	off := g_theme[.Text_Muted]
	cw := plat.text_char_width(text, UI_SMALL_PX)
	hints := [3]struct {
		label: string,
		lit:   bool,
	} {
		{"Alt+R regex", f.regex},
		{"Ctrl+L filter", doc.filter},
		{"Tab field", f.replace_mode},
	}
	total := 0
	for h in hints {total += len(h.label) + 3}
	x := right - f32(total) * cw
	if x < min_x {return}
	for h in hints {
		plat.text_draw(gfx, text, h.label, x, y, UI_SMALL_PX, on if h.lit else off)
		x += f32(len(h.label) + 3) * cw
	}
}

// The live render context. command_dispatch needs it for commands that change
// layout-affecting state (font size), and it takes no rc parameter — the same
// single-window assumption the layout metrics already rest on.
active_render_ctx: ^Render_Ctx

// Scale a 96-DPI design value to this window's DPI. Never returns 0 for a
// positive input: a metric collapsing to zero divides into +Inf downstream
// (rows, columns), and Odin's f32->int on Inf is poison.
dp :: proc(rc: ^Render_Ctx, v: f32) -> f32 {
	s := plat.window_scale(rc.window)
	r := f32(int(v * s + 0.5))
	return max(1, r) if v > 0 else r
}

// Recompute everything derived from the window's DPI. px is rounded so it stays
// an exact key into the glyph cache (Glyph_Key.px is u16) and so char_w/line_h,
// which round off it, land on whole pixels.
metrics_recompute :: proc(rc: ^Render_Ctx) {
	rc.px = dp(rc, BASE_PX)
	rc.line_h = line_height(rc.px)
	rc.char_w = plat.text_char_width(rc.text, rc.px, .Doc) // the document's grid

	// The chrome. Sole writer of these — see the note on their declarations.
	UI_SCALE = plat.window_scale(rc.window)
	UI_PX = dp(rc, UI_PX_96)
	UI_SMALL_PX = dp(rc, UI_SMALL_PX_96)
	TEXT_MARGIN_X = dp(rc, TEXT_MARGIN_X_96)
	TEXT_MARGIN_Y = dp(rc, TEXT_MARGIN_Y_96)
	TAB_STRIP_H = dp(rc, TAB_STRIP_H_96)
	MENU_BAR_H = dp(rc, MENU_BAR_H_96)
	MENU_ITEM_H = dp(rc, MENU_ITEM_H_96)
	MENU_PAD = dp(rc, MENU_PAD_96)
	CHROME_TOP = TAB_STRIP_H + MENU_BAR_H
	CONTENT_TOP = CHROME_TOP + TEXT_MARGIN_Y
	TAB_W = dp(rc, TAB_W_96)
	TAB_H = dp(rc, TAB_H_96)
	TAB_MIN_W = dp(rc, TAB_MIN_W_96)
	TAB_MAX_W = dp(rc, TAB_MAX_W_96)
	TAB_DIRTY_W = dp(rc, TAB_DIRTY_W_96)
	TAB_PAD_L = dp(rc, TAB_PAD_L_96)
	TAB_PAD_R = dp(rc, TAB_PAD_R_96)
	TAB_GAP = dp(rc, TAB_GAP_96)
	TAB_CLOSE_W = dp(rc, TAB_CLOSE_W_96)
	TAB_LABEL_GAP = dp(rc, TAB_LABEL_GAP_96)
	MENU_W = dp(rc, MENU_W_96)
	PLUS_W = dp(rc, PLUS_W_96)
	SCROLLBAR_W = dp(rc, SCROLLBAR_W_96)
	SCROLLBAR_TRACK_W = dp(rc, SCROLLBAR_TRACK_W_96)
	STATUS_BAR_H = dp(rc, STATUS_BAR_H_96)
	RADIUS_MENU_BAR_ITEM = dp(rc, RADIUS_MENU_BAR_ITEM_96)
	RADIUS_ROW = dp(rc, RADIUS_ROW_96)
	RADIUS_TAB = dp(rc, RADIUS_TAB_96)
	RADIUS_PANEL = dp(rc, RADIUS_PANEL_96)
	RADIUS_CARD = dp(rc, RADIUS_CARD_96)
	HISTORY_ROW = dp(rc, HISTORY_ROW_96)
	HISTORY_W = dp(rc, HISTORY_W_96)
	TABLE_HEADER_H = dp(rc, TABLE_HEADER_H_96)
	TABLE_ROW_H = dp(rc, TABLE_ROW_H_96)
	TABLE_CELL_PAD_X = dp(rc, TABLE_CELL_PAD_X_96)

	// The non-client hit-test boundary is derived from the tab strip, so it is
	// set here rather than at each call site — it was being scaled a second time
	// by one of them, squaring it and pushing the OS drag region into the content.
	rc.window.titlebar_h = i32(TAB_STRIP_H)
}

// WM_DPICHANGED calls this, before the window is resized. Glyphs cached at the
// old pixel size are wrong at the new one and would also hold atlas space the
// new size needs, so the atlas is dropped wholesale; the viewport-first rule
// bounds what gets re-rasterized to roughly the visible glyph set.
on_dpi :: proc "contextless" (user: rawptr) {
	context = diag_context()
	rc := (^Render_Ctx)(user)
	metrics_recompute(rc) // also refreshes window.titlebar_h
	plat.text_reset_atlas(rc.text)
}

// The FIRST block of a resize repaint's temp arena, and only the first: a
// runtime.Arena takes another block from the heap when a request does not fit, so
// this is a "how many mallocs" knob and never a correctness one. 256 KB is sized
// against the preview pane's OWN demand, not the whole frame's: measured at a
// realistic pane height (resizetemptest prints this), the preview alone asks for
// 174.7 KB at 2100px and 210.7 KB at 3200px -- both under 256 KB individually, but
// the rest of the frame (editor pane, tab strip, status bar, both scrollbars) draws
// out of the SAME arena before the preview does, so the common case takes a SECOND
// block, not one -- 1-2 mallocs per resize frame, not one. The corrected number
// matters less than it looks: arena_init(256 KB) + arena_destroy measures 3.31
// us/frame steady state (6.41 us when a second block is taken) against a 16,666 us
// budget at 60 Hz -- 0.02-0.04% either way, so the size is not a performance knob
// worth tuning further. The 900px-pane-height, UI_SCALE-1 harness this number comes
// from cannot see either fact on its own; both were measured directly, not read off
// resizetemptest's default sweep.
RESIZE_TEMP_BLOCK :: 256 * 1024

// The temp allocator a resize repaint runs on, and the ONE producer of it, so
// resizetemptest exercises the allocator WM_SIZE actually installs rather than a
// second copy of the same intent that has to agree with it.
//
// GROWING, and that is the whole fix. v0.31.0 used a fixed 64 KB mem.Arena over a
// static buffer, which shipped the crash Wyatt hit: drag the right window edge in
// markdown Split view and Newtpad died with STATUS_ARRAY_BOUNDS_EXCEEDED inside
// plat.shape_spans. A repaint's temp appetite is not bounded by any constant and
// never was -- changing the WIDTH changes `measure`, which is part of the
// Md_Layout cache key, so every visible block misses the cache and rebuilds, and
// every rebuild puts its draft spans, its string builder and shape_spans' own
// Span_Metrics array on the temp allocator. Past the end of a fixed arena
// mem.Arena returns .Out_Of_Memory; `make`'s #optional_allocator_error drops the
// error, the caller gets a ZERO-LENGTH slice, and shape.odin:246 indexes it.
// Nothing about that is specific to shape_spans -- it was simply the first
// unchecked `make` past the 64 KB mark -- which is why the fix is here and not a
// length guard there.
//
// Per-invocation, which also closes a LATENT second defect in the old code, though
// this one was never demonstrated reachable and the comment used to overclaim that
// it was. The old code re-ran `mem.arena_init` over one shared `@(static)` buffer on
// every entry, so IF on_resize could ever re-enter itself -- e.g. a nested WM_SIZE
// with an outer on_resize still on the stack -- the inner call would reset the
// shared arena's offset to zero and hand out memory the outer call was still
// holding. That is a real aliasing bug in the shared-buffer design, and removing
// the static buffer removes it regardless of whether it was reachable. But
// reachability was NOT shown: on_dpi (above) does not resize the window itself --
// it only calls metrics_recompute and text_reset_atlas, and the SetWindowPos that
// follows a DPI change lives in window.odin's WM_DPICHANGED handler, which runs
// AFTER on_dpi returns, so that path is WM_DPICHANGED -> on_dpi (returns) -> WM_SIZE
// -> one on_resize, not a nested one. The only PeekMessageW/DispatchMessageW pump is
// window_pump_events, called only from the main loop, never from inside
// render_frame. A fault-stack review found exactly one on_resize frame, not two. A
// fresh arena per repaint is correct either way -- it just is not evidence of a
// demonstrated crash, only of a closed latent one -- and costs one heap block per
// resize frame: nothing against the render it is paying for.
resize_temp_begin :: proc(arena: ^runtime.Arena) -> (a: mem.Allocator, ok: bool) {
	if runtime.arena_init(arena, RESIZE_TEMP_BLOCK, context.allocator) != nil {return}
	return runtime.arena_allocator(arena), true
}

resize_temp_end :: proc(arena: ^runtime.Arena) {
	runtime.arena_destroy(arena)
}

// WM_SIZE calls this so the content re-renders live during a resize. It runs from
// the "system" window proc (no Odin context) and uses a private growing arena so
// it never disturbs the main loop's temp allocator (see resize_temp_begin).
on_resize :: proc "contextless" (user: rawptr) {
	context = diag_context()
	rc := (^Render_Ctx)(user)
	if rc.window.width <= 0 || rc.window.height <= 0 {return}
	// Resize the swapchain and RTV FIRST, unconditionally, before anything that can
	// fail. gfx_resize / gfx_create_rtv (gfx.odin) allocate no Odin memory, so this
	// is free and cannot be the thing that fails below. It must not be gated on the
	// arena: v0.31.0 called gfx_resize unconditionally because arena_init could not
	// fail; now that it can, gating gfx_resize on `ok` would mean an arena failure on
	// the LAST WM_SIZE of a drag leaves gfx.width/height stuck at the stale size
	// permanently -- window.resized is only set pre-callback (startup, see
	// window.odin's WM_SIZE handler), so no later WM_SIZE re-syncs it once this
	// callback is installed, and every frame after draws a viewport that disagrees
	// with the window: content outside the viewport, hit-tests that disagree with
	// the draw (CLAUDE.md Shape B), until the next resize that happens to succeed.
	plat.gfx_resize(rc.gfx, rc.window.width, rc.window.height)
	arena: runtime.Arena
	scratch, ok := resize_temp_begin(&arena)
	// Out of memory before the repaint even starts: skip the CONTENT repaint this
	// frame rather than run it on the main loop's arena, which an outer frame may be
	// mid-way through. The swapchain is already correctly sized above, so the only
	// cost of skipping here is one frame that does not repaint, not a desynced
	// viewport. The OS sends another WM_SIZE for the next mouse position.
	if !ok {return}
	defer resize_temp_end(&arena)
	context.temp_allocator = scratch
	render_frame(rc, false) // immediate (allow-tearing) present: smooth live resize
}
