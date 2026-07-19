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

main :: proc() {
	plat.seh_install() // arm the mapped-read fault guard before any file opens

	if test_mode_dispatch() {return} // headless argv modes (see test_modes.odin)

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
	had_session := primary && session_exists()
	// Restore is opt-out. Note the sweep guard below still protects the backups
	// when it is off: they belong to tabs we chose not to adopt, so turning
	// restore off hides the old session rather than destroying it.
	restored := primary && app.settings.restore_session && session_restore(&app)
	// A session we couldn't load still owns its backups; don't sweep them.
	session_can_sweep := !had_session || restored
	if path != "" {
		if !app_open_path(&app, path) {
			fmt.eprintfln("Newtpad: could not open %q", path)
		}
	}
	if app_live_count(&app) == 0 {
		app_new_scratch(&app) // never fail to a closed window
	}
	defer app_destroy(&app)

	// The renderer is reusable so the WM_SIZE handler can repaint live during a
	// window resize (the OS runs a modal loop that otherwise freezes this one).
	rc := Render_Ctx{&gfx, &text, &quad_pipe, &app, window, 0, 0, 0}
	active_render_ctx = &rc
	BASE_PX = f32(clamp(app.settings.font_size, FONT_SIZE_MIN, FONT_SIZE_MAX))
	// Apply the saved font before the first frame. A family that is no longer
	// installed leaves the default in place rather than failing to start.
	if app.settings.font_family != "" && app.settings.font_family != "Consolas" {
		plat.text_load_family(&text, app.settings.font_family, app.settings.font_style)
	} else if app.settings.font_style != .Regular {
		plat.text_load_family(&text, "Consolas", app.settings.font_style)
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

	for !window.should_close {
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

		// Files handed over by other launches (Explorer double-click while we're
		// running): open each as a tab. app_open_path activates an existing tab if
		// the file is already open, so re-opening a file just focuses it.
		if window.open_count > 0 {
			reqs: [plat.OPEN_QUEUE]string
			for p in reqs[:plat.window_open_requests(window, reqs[:])] {
				if !app_open_path(&app, p) {
					fmt.eprintfln("Newtpad: could not open %q", p)
				}
			}
			plat.window_clear_open_requests(window)
			session_dirty = true
		}

		if window.resized {
			plat.gfx_resize(&gfx, window.width, window.height)
			window.resized = false
		}
		rows := int((f32(window.height) - CONTENT_TOP) / line_h)

		doc := app_active(&app)
		// Usable content width in cells (word wrap breaks here).
		doc.view_cols = max(1, int((f32(window.width) - TEXT_MARGIN_X - SCROLLBAR_W) / char_w))
		doc.view_rows = rows
		// Re-center on the caret only when it actually moves on THIS tab — never
		// after a wheel/page scroll (which leaves the caret put) or a tab switch.
		active_before := app.active
		cursor_before := doc.cursor

		// Drain input once per frame: typed characters route to the find field or
		// the document; key chords resolve to a command in the active context.
		for i in 0 ..< window.char_count {
			if app.settings_open {
				// the settings page has no text fields; swallow typing
			} else if app.palette.active {
				palette_input_rune(&app, window.chars[i])
			} else if doc.find.active {
				find_input_rune(doc, window.chars[i])
			} else {
				doc_insert_rune(doc, window.chars[i])
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
			// Context is per-event; palette/find/menu/tab-switch can change it
			// mid-loop. Priority: menu > palette > find > editor.
			ctx := Ctx.Editor
			if app.settings_open {
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
			command_dispatch(cmd, ev, &app, window, &text, rows)
		}
		window.key_count = 0

		// A tab switch/close may have changed the active document.
		doc = app_active(&app)

		// While the palette is open it's modal: a click anywhere dismisses it and
		// is consumed, so it never falls through to the tabs/caret handlers.
		if app.palette.active && (window.mouse_pressed || window.mouse_middle_pressed) {
			palette_close(&app)
			window.mouse_pressed = false
			window.mouse_middle_pressed = false
			window.mouse_down = false
		}

		// The menu claims clicks first: its bar sits above the scrollbar gutter's
		// top edge, and an open dropdown overlaps the content.
		if mcmd, consumed := menu_hit_test(&app, &text, window, f32(window.width), f32(window.height)); consumed {
			if mcmd != .None {
				command_dispatch(mcmd, {}, &app, window, &text, rows)
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
		tabs_hit_test(&app, window)

		// Scrollbar: a press in the right-edge gutter starts a drag that maps the
		// pointer's y to a byte-proportional scroll position (consumes the click).
		if window.mouse_pressed && f32(window.mouse_x) >= f32(window.width) - SCROLLBAR_W && window.mouse_y >= i32(CHROME_TOP) {
			scrollbar_drag = true
			window.mouse_pressed = false
		}
		if scrollbar_drag {
			if window.mouse_down {
				frac := (f32(window.mouse_y) - CHROME_TOP) / max(1, f32(window.height) - CHROME_TOP)
				doc_scroll_to_fraction(doc, &text, frac, rows)
			} else {
				scrollbar_drag = false
			}
		}

		// Mouse: press places/extends the caret (double=word, triple=line); drag extends.
		if window.mouse_pressed {
			mp := doc_pos_at(doc, &text, window.mouse_x, window.mouse_y, px, char_w, rows)
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
			}
			window.mouse_pressed = false
		} else if window.mouse_down && window.mouse_count == 1 && !scrollbar_drag {
			// drag extends a single-click selection; word/line selects stay put.
			// Auto-scroll when the pointer is dragged past the top/bottom edge.
			if window.mouse_y < i32(CONTENT_TOP) {
				doc_scroll(doc, &text, -1, rows)
			} else if window.mouse_y > window.height - i32(line_h) {
				doc_scroll(doc, &text, 1, rows)
			}
			doc.cursor = doc_pos_at(doc, &text, window.mouse_x, window.mouse_y, px, char_w, rows)
		}

		// Ctrl+wheel zooms rather than scrolls, as everywhere else.
		if window.scroll_delta != 0 && plat.key_ctrl_down() {
			zoom_adjust(&rc, -1 if window.scroll_delta > 0 else 1)
			window.scroll_delta = 0
		}
		if window.scroll_delta != 0 {
			if doc.filter {
				// Stop at the point the list underfills the screen, rather than
				// letting the last line scroll to the top over empty rows.
				doc.filter_top = clamp(doc.filter_top + window.scroll_delta, 0, max(0, len(doc.filter_lines) - rows))
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
			// Get off the mapping before anything else: while we hold it, the
			// other writer cannot rotate or replace the file.
			doc_detach_mapping(d)
			if d.modified {
				// Never discard the user's edits silently. Mark and let them choose.
				d.disk_changed = true
			} else if doc_absorb_append(d, c.stamp.size) {
				d.disk_stamp = c.stamp
			} else if !doc_reload(d) {
				d.disk_changed = true
			}
			session_dirty = true
		}

		// Take whatever the search worker published since the last frame (and
		// restart it if an edit invalidated the results).
		doc = app_active(&app)
		find_merge(doc)

		// Keep the caret on screen only when it moved on this tab this frame.
		if !doc.filter && app.active == active_before && doc.cursor != cursor_before {
			doc_ensure_cursor_visible(doc, &text, rows)
		}

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

		render_frame(&rc)

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

// Draw one frame from current state. No input handling — safe to call from the
// main loop or the WM_SIZE handler. vsync=false (resize) presents immediately so
// clustered WM_SIZE repaints don't each stall on vsync.
render_frame :: proc(rc: ^Render_Ctx, vsync := true) {
	gfx, text, quad_pipe, window := rc.gfx, rc.text, rc.quads, rc.window
	px, char_w, line_h := rc.px, rc.char_w, rc.line_h
	doc := app_active(rc.app)
	rows := int((f32(window.height) - CONTENT_TOP) / line_h)
	// Recompute the wrap width here (not just in the main loop) so word wrap
	// re-flows live during a resize, which repaints through this path.
	doc.view_cols = max(1, int((f32(window.width) - TEXT_MARGIN_X - SCROLLBAR_W) / char_w))

	plat.text_frame_begin(text) // resets the atlas recycle guard
	plat.gfx_begin_frame(gfx, 0.09, 0.11, 0.16)

	// Behind the text: find-match highlights (dim), then the selection (bright).
	if !doc.filter {
		findq: [80]plat.Quad
		if nfq := find_match_rects(doc, text, px, char_w, rows, findq[:]); nfq > 0 {
			plat.quads_draw(gfx, quad_pipe, findq[:nfq])
		}
		selq: [80]plat.Quad
		if ns := doc_selection_rects(doc, text, px, char_w, rows, selq[:]); ns > 0 {
			plat.quads_draw(gfx, quad_pipe, selq[:ns])
		}
	}

	cx, cy, caret, bottom := doc_draw(gfx, text, doc, px, char_w, rows)

	// Scrollbar (byte-proportional, below the tab strip) + caret.
	bars: [4]plat.Quad
	nb := 0
	w := f32(window.width)
	h := f32(window.height)
	total := doc.pt.length
	if total > 0 && !doc.filter {
		sb_h := h - CHROME_TOP
		ty := CHROME_TOP + f32(doc.top) / f32(total) * sb_h
		th := max(sx(24), f32(bottom - doc.top) / f32(total) * sb_h)
		bars[nb] = {pos = {w - SCROLLBAR_W, CHROME_TOP}, size = {SCROLLBAR_W, sb_h}, color = {0.16, 0.18, 0.22, 1}};nb += 1
		bars[nb] = {pos = {w - SCROLLBAR_W + dp(rc, 1), ty}, size = {SCROLLBAR_W - dp(rc, 2), th}, color = {0.42, 0.48, 0.60, 1}};nb += 1
	}
	if caret {
		bars[nb] = {pos = {cx, cy - px}, size = {sx(2), line_h}, color = {0.95, 0.85, 0.35, 1}};nb += 1
	}
	if nb > 0 {
		plat.quads_draw(gfx, quad_pipe, bars[:nb])
	}

	tabs_draw(gfx, quad_pipe, text, rc.app, window, w)
	if rc.app.settings_open {
		settings_draw(gfx, quad_pipe, text, rc.app, w, h)
	} else if rc.app.history.open {
		history_draw(gfx, quad_pipe, text, rc.app, w, h)
	}
	menu_draw(gfx, quad_pipe, text, rc.app, window, w, h)

	if rc.app.palette.active {
		palette_draw(gfx, quad_pipe, text, rc.app, w, h)
	}

	// Filter view replaces the document with just the matching lines, which is
	// disorienting if you don't know why. Say so, unmistakably, and say how to
	// leave — the previous signal was the word "filter" inside the find line.
	if doc.filter && doc.find.active {
		bh := sx(20)
		plat.quads_draw(gfx, quad_pipe, []plat.Quad{{pos = {0, CONTENT_TOP - bh}, size = {w, bh}, color = {0.18, 0.26, 0.20, 1}}})
		msg := fmt.tprintf(
			"FILTER  %d matching lines%s   —   Ctrl+L shows the whole file",
			len(doc.filter_lines),
			"" if doc_filtering(doc) else " (searching...)",
		)
		plat.text_draw(gfx, text, msg, sx(12), CONTENT_TOP - sx(6), UI_SMALL_PX, {0.70, 0.90, 0.74, 1})
	}

	if doc.find.active {
		f := &doc.find
		bar_h := sx(48) if f.replace_mode else sx(26)
		bar := plat.Quad{pos = {0, h - bar_h}, size = {w, bar_h}, color = {0.14, 0.16, 0.20, 1}}
		plat.quads_draw(gfx, quad_pipe, []plat.Quad{bar})
		info: string
		if len(f.query) == 0 {
			info = ""
		} else if len(f.matches) == 0 {
			info = "  (no matches)"
		} else {
			// "+" marks a partial result: we stopped at the match limit or the
			// regex scan cap, so there may be more further down the file.
			info = fmt.tprintf("  (%d/%d%s)", f.current + 1, len(f.matches), "+" if f.truncated else "")
		}
		mode := "regex" if f.regex else "text"
		fline := fmt.tprintf("Find [%s]%s: %s%s%s", mode, " filter" if doc.filter else "", string(f.query[:]), " _" if f.field == 0 else "", info)
		if f.replace_mode {
			plat.text_draw(gfx, text, fline, sx(12), h - sx(30), UI_PX, {0.95, 0.88, 0.55, 1})
			rline := fmt.tprintf("Replace: %s%s", string(f.replace[:]), " _" if f.field == 1 else "")
			plat.text_draw(gfx, text, rline, sx(12), h - sx(8), UI_PX, {0.82, 0.9, 0.98, 1})
			hint_find(gfx, text, f, doc, w, h - sx(30))
		} else {
			plat.text_draw(gfx, text, fline, sx(12), h - sx(8), UI_PX, {0.95, 0.88, 0.55, 1})
			hint_find(gfx, text, f, doc, w, h - sx(8))
		}
	} else {
		ln := doc_cursor_line(doc)
		lncol := fmt.tprintf("Ln %d, Col %d", ln, doc_cursor_col(doc, text)) if ln > 0 else fmt.tprintf("Col %d", doc_cursor_col(doc, text))
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
		status := fmt.tprintf("%s    %s    %s    %d lines%s%s%s%s%s%s", lncol, enc_name(doc.enc), base.line_ending_name(doc.eol), doc_line_count(doc), " *" if doc.modified else "", "    Wrap" if doc.wrap else "", recovered, disk, indexing, atlas)
		warn := doc.recovered || doc.disk_changed || doc.disk_gone || plat.text_atlas_full(text)
		col := [4]f32{0.95, 0.55, 0.35, 1} if warn else {0.55, 0.60, 0.70, 1}
		plat.text_draw(gfx, text, status, sx(12), h - sx(8), UI_SMALL_PX, col)
	}

	plat.gfx_end_frame(gfx, 1 if vsync else 0)
}

// The find bar's own toggles, right-aligned, active ones lit. These commands
// exist only inside find mode, so without this the only way to learn Ctrl+R and
// Ctrl+L was to be told they were there.
@(private = "file")
hint_find :: proc(gfx: ^plat.Gfx, text: ^plat.Text, f: ^Find, doc: ^Document, w, y: f32) {
	on := [4]f32{0.95, 0.88, 0.55, 1}
	off := [4]f32{0.45, 0.49, 0.57, 1}
	cw := plat.text_char_width(text, UI_SMALL_PX)
	hints := [3]struct {
		label: string,
		lit:   bool,
	} {
		{"Ctrl+R regex", f.regex},
		{"Ctrl+L filter", doc.filter},
		{"Tab field", f.replace_mode},
	}
	total := 0
	for h in hints {total += len(h.label) + 3}
	x := w - sx(12) - f32(total) * cw
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
	rc.char_w = plat.text_char_width(rc.text, rc.px)

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
	TAB_GAP = dp(rc, TAB_GAP_96)
	TAB_CLOSE_W = dp(rc, TAB_CLOSE_W_96)
	MENU_W = dp(rc, MENU_W_96)
	PLUS_W = dp(rc, PLUS_W_96)
	SCROLLBAR_W = dp(rc, SCROLLBAR_W_96)
	HISTORY_ROW = dp(rc, HISTORY_ROW_96)
	HISTORY_W = dp(rc, HISTORY_W_96)

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
	context = runtime.default_context()
	rc := (^Render_Ctx)(user)
	metrics_recompute(rc) // also refreshes window.titlebar_h
	plat.text_reset_atlas(rc.text)
}

// WM_SIZE calls this so the content re-renders live during a resize. It runs from
// the "system" window proc (no Odin context) and uses a private scratch arena so
// it never disturbs the main loop's temp allocator.
on_resize :: proc "contextless" (user: rawptr) {
	context = runtime.default_context()
	rc := (^Render_Ctx)(user)
	if rc.window.width <= 0 || rc.window.height <= 0 {return}
	@(static) scratch: [64 * 1024]u8
	arena: mem.Arena
	mem.arena_init(&arena, scratch[:])
	context.temp_allocator = mem.arena_allocator(&arena)
	plat.gfx_resize(rc.gfx, rc.window.width, rc.window.height)
	render_frame(rc, false) // immediate (allow-tearing) present: smooth live resize
}
