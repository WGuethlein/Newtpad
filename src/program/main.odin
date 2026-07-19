// Layer: program — wires the layers together and owns the frame loop. The main
// thread builds UI and handles input only: drain events, update the document,
// draw the viewport, present. Headless argv test modes live in test_modes.odin.
package main

import "base:runtime"
import "core:fmt"
import "core:mem"
import "core:os"
import plat "src:platform"

main :: proc() {
	plat.seh_install() // arm the mapped-read fault guard before any file opens

	if test_mode_dispatch() {return} // headless argv modes (see test_modes.odin)

	// Open the file given on the command line; with no argument, start empty.
	path := ""
	if len(os.args) > 1 {
		path = os.args[1]
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

	app: App
	if path == "" {
		app_new_scratch(&app)
	} else if !app_open_path(&app, path) {
		fmt.eprintfln("Newtpad: could not open %q; starting empty", path)
		app_new_scratch(&app)
	}
	defer app_destroy(&app)

	px: f32 = 16
	line_h := line_height(px)
	char_w := plat.text_char_width(&text, px)

	// The renderer is reusable so the WM_SIZE handler can repaint live during a
	// window resize (the OS runs a modal loop that otherwise freezes this one).
	rc := Render_Ctx{&gfx, &text, &quad_pipe, &app, window, px, char_w, line_h}
	window.on_resize = on_resize
	window.resize_user = &rc

	for !window.should_close {
		plat.window_pump_events(window)

		if window.resized {
			plat.gfx_resize(&gfx, window.width, window.height)
			window.resized = false
		}
		rows := int((f32(window.height) - CONTENT_TOP) / line_h)

		doc := app_active(&app)
		// Re-center on the caret only when it actually moves on THIS tab — never
		// after a wheel/page scroll (which leaves the caret put) or a tab switch.
		active_before := app.active
		cursor_before := doc.cursor

		// Drain input once per frame: typed characters route to the find field or
		// the document; key chords resolve to a command in the active context.
		for i in 0 ..< window.char_count {
			if doc.find.active {
				find_input_rune(doc, window.chars[i])
			} else {
				doc_insert_rune(doc, window.chars[i])
			}
		}
		window.char_count = 0
		for i in 0 ..< window.key_count {
			ev := window.key_events[i]
			// Context is per-event; the active doc may change (tab switch) mid-loop.
			ctx := Ctx.Find if app_active(&app).find.active else Ctx.Editor
			command_dispatch(resolve_key(ev.key, ev.ctrl, ctx), ev, &app, window, rows)
		}
		window.key_count = 0

		// A tab switch/close may have changed the active document.
		doc = app_active(&app)

		// The tab strip claims clicks in its region before the caret sees them.
		tabs_hit_test(&app, window)

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
		} else if window.mouse_down && window.mouse_count == 1 {
			// drag extends a single-click selection; word/line selects stay put.
			// Auto-scroll when the pointer is dragged past the top/bottom edge.
			if window.mouse_y < i32(CONTENT_TOP) {
				doc_scroll(doc, -1)
			} else if window.mouse_y > window.height - i32(line_h) {
				doc_scroll(doc, 1)
			}
			doc.cursor = doc_pos_at(doc, &text, window.mouse_x, window.mouse_y, px, char_w, rows)
		}

		if window.scroll_delta != 0 {
			if doc.filter {
				doc.filter_top = clamp(doc.filter_top + window.scroll_delta, 0, max(0, len(doc.filter_lines) - 1))
			} else {
				doc_scroll(doc, window.scroll_delta)
			}
			window.scroll_delta = 0
		}

		// Keep the caret on screen only when it moved on this tab this frame.
		doc = app_active(&app)
		if !doc.filter && app.active == active_before && doc.cursor != cursor_before {
			doc_ensure_cursor_visible(doc, rows)
		}

		render_frame(&rc)

		// A mapped read may have faulted during this frame's draw/search (file
		// truncated or decompression-broken underneath us). Detach from the map
		// into a private copy so we never fault again; next frame draws that.
		if doc_fault_pending(doc) {
			doc_recover_from_fault(doc)
			fmt.eprintln("Newtpad: file changed on disk mid-read; showing a recovered copy")
		}
		free_all(context.temp_allocator)
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
// main loop or the WM_SIZE handler.
render_frame :: proc(rc: ^Render_Ctx) {
	gfx, text, quad_pipe, window := rc.gfx, rc.text, rc.quads, rc.window
	px, char_w, line_h := rc.px, rc.char_w, rc.line_h
	doc := app_active(rc.app)
	rows := int((f32(window.height) - CONTENT_TOP) / line_h)

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
		sb_h := h - TAB_STRIP_H
		ty := TAB_STRIP_H + f32(doc.top) / f32(total) * sb_h
		th := max(24, f32(bottom - doc.top) / f32(total) * sb_h)
		bars[nb] = {pos = {w - 14, TAB_STRIP_H}, size = {12, sb_h}, color = {0.16, 0.18, 0.22, 1}};nb += 1
		bars[nb] = {pos = {w - 13, ty}, size = {10, th}, color = {0.42, 0.48, 0.60, 1}};nb += 1
	}
	if caret {
		bars[nb] = {pos = {cx, cy - px}, size = {2, line_h}, color = {0.95, 0.85, 0.35, 1}};nb += 1
	}
	if nb > 0 {
		plat.quads_draw(gfx, quad_pipe, bars[:nb])
	}

	tabs_draw(gfx, quad_pipe, text, rc.app, w)

	if doc.find.active {
		f := &doc.find
		bar_h: f32 = 48 if f.replace_mode else 26
		bar := plat.Quad{pos = {0, h - bar_h}, size = {w, bar_h}, color = {0.14, 0.16, 0.20, 1}}
		plat.quads_draw(gfx, quad_pipe, []plat.Quad{bar})
		info: string
		if len(f.query) == 0 {
			info = ""
		} else if len(f.matches) == 0 {
			info = "  (no matches)"
		} else {
			info = fmt.tprintf("  (%d/%d)", f.current + 1, len(f.matches))
		}
		mode := "regex" if f.regex else "text"
		fline := fmt.tprintf("Find [%s]%s: %s%s%s", mode, " filter" if doc.filter else "", string(f.query[:]), " _" if f.field == 0 else "", info)
		if f.replace_mode {
			plat.text_draw(gfx, text, fline, 12, h - 30, 14, {0.95, 0.88, 0.55, 1})
			rline := fmt.tprintf("Replace: %s%s", string(f.replace[:]), " _" if f.field == 1 else "")
			plat.text_draw(gfx, text, rline, 12, h - 8, 14, {0.82, 0.9, 0.98, 1})
		} else {
			plat.text_draw(gfx, text, fline, 12, h - 8, 14, {0.95, 0.88, 0.55, 1})
		}
	} else {
		recovered := "  [RECOVERED COPY - file changed on disk, not the original]" if doc.recovered else ""
		status := fmt.tprintf("%d lines%s%s%s", doc_line_count(doc), " *" if doc.modified else "", recovered, "" if doc_index_done(doc) else fmt.tprintf("  (indexing %.0f%%)", doc_index_progress(doc) * 100))
		col := [4]f32{0.95, 0.55, 0.35, 1} if doc.recovered else {0.55, 0.60, 0.70, 1}
		plat.text_draw(gfx, text, status, 12, h - 8, 13, col)
	}

	plat.gfx_end_frame(gfx)
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
	render_frame(rc)
}
