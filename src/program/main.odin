// Layer: program — wires the layers together and owns the frame loop.
// The main thread builds UI and handles input, nothing else (nothing to build
// yet — this milestone just proves window + D3D11 present end-to-end).
package main

import "core:fmt"
import "core:os"
import "core:time"
import plat "src:platform"

main :: proc() {
	// Open the file given on the command line; default to the 1GB bench file to
	// demo instant multi-GB open, falling back to a source file if it's absent.
	path := "bench/data/test_1024MB.txt"
	if len(os.args) > 1 {
		path = os.args[1]
	} else if !os.exists(path) {
		path = "src/platform/text.odin"
	}

	// Headless verification: `newtpad <path> count` indexes and prints stats.
	if len(os.args) > 2 && os.args[2] == "count" {
		doc, ok := doc_open(path)
		if !ok {
			fmt.eprintfln("could not open %s", path)
			return
		}
		doc_index_start(&doc)
		t0 := time.tick_now()
		for !doc_index_done(&doc) {
			time.sleep(time.Millisecond)
		}
		fmt.printfln("indexed %d lines in %.1f ms (%d bytes, %v)", doc_line_count(&doc), time.duration_milliseconds(time.tick_since(t0)), doc.pt.length, doc.enc)
		doc_close(&doc)
		return
	}

	// Headless edit check: `newtpad <path> edittest` exercises the doc edit path.
	if len(os.args) > 2 && os.args[2] == "edittest" {
		doc, _ := doc_open(path)
		pre :: proc(s: string) -> string {return s[:min(len(s), 8)]}
		doc.cursor = 0
		doc_insert_rune(&doc, 'A')
		doc_insert_rune(&doc, 'B')
		doc_insert_rune(&doc, '\n')
		fmt.printfln("insert AB\\n : %q  (%d lines)", pre(doc_debug_string(&doc)), doc.nl_delta)
		doc_backspace(&doc)
		fmt.printfln("backspace  : %q", pre(doc_debug_string(&doc)))
		doc_cursor_right(&doc)
		doc_delete_fwd(&doc)
		fmt.printfln("del-fwd @1 : %q", pre(doc_debug_string(&doc)))
		doc_undo(&doc)
		doc_undo(&doc)
		fmt.printfln("undo x2    : %q", pre(doc_debug_string(&doc)))
		doc_redo(&doc)
		fmt.printfln("redo x1    : %q", pre(doc_debug_string(&doc)))
		doc_close(&doc)
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

	doc, dok := doc_open(path)
	if !dok {
		fmt.eprintfln("Newtpad: could not open %s", path)
		return
	}
	defer doc_close(&doc)
	doc_index_start(&doc) // &doc is stable here; safe for the worker to hold
	fmt.printfln("Newtpad: opened %s (%d bytes, %v). Edit; close to exit.", path, doc.pt.length, doc.enc)

	px: f32 = 16
	line_h := px * 1.5
	char_w := plat.text_char_width(&text, px)

	for !window.should_close {
		plat.window_pump_events(window)

		if window.resized {
			plat.gfx_resize(&gfx, window.width, window.height)
			window.resized = false
		}
		rows := int(f32(window.height) / line_h)

		// Drain input once per frame: typed characters, then editor key commands.
		for i in 0 ..< window.char_count {
			doc_insert_rune(&doc, window.chars[i])
		}
		window.char_count = 0
		for i in 0 ..< window.key_count {
			#partial switch window.key_cmds[i] {
			case .Left:
				doc_cursor_left(&doc)
			case .Right:
				doc_cursor_right(&doc)
			case .Up:
				doc_cursor_up(&doc)
			case .Down:
				doc_cursor_down(&doc)
			case .Home:
				doc_cursor_home(&doc)
			case .End:
				doc_cursor_end(&doc)
			case .PageUp:
				doc_scroll(&doc, -(rows - 1))
			case .PageDown:
				doc_scroll(&doc, rows - 1)
			case .Backspace:
				doc_backspace(&doc)
			case .DeleteFwd:
				doc_delete_fwd(&doc)
			case .Enter:
				doc_insert_rune(&doc, '\n')
			case .Undo:
				doc_undo(&doc)
			case .Redo:
				doc_redo(&doc)
			}
		}
		window.key_count = 0
		if window.scroll_delta != 0 {
			doc_scroll(&doc, window.scroll_delta)
			window.scroll_delta = 0
		}

		doc_ensure_cursor_visible(&doc, rows)

		plat.gfx_begin_frame(&gfx, 0.09, 0.11, 0.16)
		cx, cy, caret, bottom := doc_draw(&gfx, &text, &doc, px, char_w, rows)

		// Scrollbar (byte-proportional) + caret, both solid quads.
		bars: [4]plat.Quad
		nb := 0
		w := f32(window.width)
		h := f32(window.height)
		total := doc.pt.length
		if total > 0 {
			ty := f32(doc.top) / f32(total) * h
			th := max(24, f32(bottom - doc.top) / f32(total) * h)
			bars[nb] = {pos = {w - 14, 0}, size = {12, h}, color = {0.16, 0.18, 0.22, 1}};nb += 1
			bars[nb] = {pos = {w - 13, ty}, size = {10, th}, color = {0.42, 0.48, 0.60, 1}};nb += 1
		}
		if caret {
			bars[nb] = {pos = {cx, cy - px}, size = {2, line_h}, color = {0.95, 0.85, 0.35, 1}};nb += 1
		}
		if nb > 0 {
			plat.quads_draw(&gfx, &quad_pipe, bars[:nb])
		}

		status := fmt.tprintf("%d lines%s%s", doc_line_count(&doc), " *" if doc.modified else "", "" if doc_index_done(&doc) else fmt.tprintf("  (indexing %.0f%%)", doc_index_progress(&doc) * 100))
		plat.text_draw(&gfx, &text, status, 12, f32(window.height) - 8, 13, {0.55, 0.60, 0.70, 1})

		plat.gfx_end_frame(&gfx)
		free_all(context.temp_allocator)
	}
}
