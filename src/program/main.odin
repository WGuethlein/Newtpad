// Layer: program — wires the layers together and owns the frame loop.
// The main thread builds UI and handles input, nothing else (nothing to build
// yet — this milestone just proves window + D3D11 present end-to-end).
package main

import "core:fmt"
import "core:os"
import "core:time"
import plat "src:platform"

main :: proc() {
	// Open the file given on the command line; with no argument, start empty.
	path := ""
	if len(os.args) > 1 {
		path = os.args[1]
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
		doc_cursor_right(&doc, false)
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

	// Headless save check: `newtpad <in> savetest <out>` edits, saves, reopens.
	if len(os.args) > 3 && os.args[2] == "savetest" {
		outp := os.args[3]
		doc, _ := doc_open(path)
		doc.cursor = 0
		doc_insert_text(&doc, transmute([]u8)string("SAVED:"))
		ok2 := doc_save(&doc, outp)
		fmt.printfln("save ok=%v enc=%v had_bom=%v", ok2, doc.enc, doc.had_bom)
		doc_close(&doc)
		doc2, r2 := doc_open(outp)
		if r2 {
			s := doc_debug_string(&doc2)
			fmt.printfln("reopened %q (%d bytes, enc=%v)", s[:min(len(s), 16)], doc2.pt.length, doc2.enc)
			doc_close(&doc2)
		}
		return
	}

	// Headless selection/clipboard check: `newtpad <path> seltest`.
	if len(os.args) > 2 && os.args[2] == "seltest" {
		p8 :: proc(s: string) -> string {return s[:min(len(s), 14)]}
		doc, _ := doc_open(path) // e.g. "hello world foo"
		doc.anchor = 6
		doc.cursor = 11
		fmt.printfln("selection [6,11): %q", doc_selected_text(&doc, context.temp_allocator))
		doc_insert_rune(&doc, 'Z') // replace selection
		fmt.printfln("replace sel : %q", p8(doc_debug_string(&doc)))
		doc_undo(&doc)
		fmt.printfln("undo        : %q sel=%q", p8(doc_debug_string(&doc)), doc_selected_text(&doc, context.temp_allocator))
		doc_select_word_at(&doc, 2) // inside "hello"
		lo, hi := doc_sel_range(&doc)
		fmt.printfln("word@2      : [%d,%d) %q", lo, hi, doc_selected_text(&doc, context.temp_allocator))
		doc_select_all(&doc)
		fmt.printfln("select all  : anchor=%d cursor=%d", doc.anchor, doc.cursor)
		plat.clipboard_set_text(nil, "clip round-trip ✓")
		if g, gok := plat.clipboard_get_text(nil, context.temp_allocator); gok {
			fmt.printfln("clipboard   : %q", g)
		}
		doc_close(&doc)
		return
	}

	// Headless find check: `newtpad <path> findtest <query>`.
	if len(os.args) > 3 && os.args[2] == "findtest" {
		doc, _ := doc_open(path)
		find_open(&doc)
		for r in os.args[3] {find_input_rune(&doc, r)}
		fmt.printf("query=%q matches=%d offsets:", string(doc.find.query[:]), len(doc.find.matches))
		for m in doc.find.matches {fmt.printf(" %d", m)}
		fmt.printfln("  current=%d", doc.find.current)
		if len(doc.find.matches) > 0 {
			find_next(&doc)
			fmt.printfln("next -> current=%d (cursor %d)", doc.find.current, doc.cursor)
			find_prev(&doc)
			find_prev(&doc)
			fmt.printfln("prev x2 -> current=%d", doc.find.current)
		}
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

	doc: Document
	if path == "" {
		doc = doc_new()
		fmt.println("Newtpad: new scratch buffer. Type; close to exit.")
	} else {
		ok2: bool
		doc, ok2 = doc_open(path)
		if !ok2 {
			fmt.eprintfln("Newtpad: could not open %q; starting empty", path)
			doc = doc_new()
		} else {
			fmt.printfln("Newtpad: opened %s (%d bytes, %v). Edit; close to exit.", path, doc.pt.length, doc.enc)
		}
	}
	defer doc_close(&doc)
	doc_index_start(&doc) // &doc is stable here; safe for the worker to hold

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
			if doc.find.active {
				find_input_rune(&doc, window.chars[i])
			} else {
				doc_insert_rune(&doc, window.chars[i])
			}
		}
		window.char_count = 0
		for i in 0 ..< window.key_count {
			ev := window.key_events[i]
			if doc.find.active {
				#partial switch ev.cmd {
				case .Backspace:
					find_backspace(&doc)
				case .Enter:
					if ev.shift {find_prev(&doc)} else {find_next(&doc)}
				case .Escape, .Find:
					find_close(&doc)
				}
				continue
			}
			#partial switch ev.cmd {
			case .Left:
				doc_cursor_left(&doc, ev.shift)
			case .Right:
				doc_cursor_right(&doc, ev.shift)
			case .Up:
				doc_cursor_up(&doc, ev.shift)
			case .Down:
				doc_cursor_down(&doc, ev.shift)
			case .Home:
				doc_cursor_home(&doc, ev.shift)
			case .End:
				doc_cursor_end(&doc, ev.shift)
			case .WordLeft:
				doc_word_left(&doc, ev.shift)
			case .WordRight:
				doc_word_right(&doc, ev.shift)
			case .PageUp:
				doc_scroll(&doc, -(rows - 1))
			case .PageDown:
				doc_scroll(&doc, rows - 1)
			case .Backspace:
				doc_backspace(&doc)
			case .DeleteFwd:
				doc_delete_fwd(&doc)
			case .DeleteWordBack:
				doc_delete_word_back(&doc)
			case .Enter:
				doc_insert_rune(&doc, '\n')
			case .Undo:
				doc_undo(&doc)
			case .Redo:
				doc_redo(&doc)
			case .SelectAll:
				doc_select_all(&doc)
			case .Copy:
				if s := doc_selected_text(&doc, context.temp_allocator); s != "" {
					plat.clipboard_set_text(window.hwnd, s)
				}
			case .Cut:
				if s := doc_selected_text(&doc, context.temp_allocator); s != "" {
					plat.clipboard_set_text(window.hwnd, s)
					doc_backspace(&doc) // deletes the selection
				}
			case .Paste:
				if s, cok := plat.clipboard_get_text(window.hwnd, context.temp_allocator); cok {
					doc_insert_text(&doc, transmute([]u8)s)
				}
			case .Save:
				p := doc.path
				if p == "" {
					if np, sok := plat.file_save_dialog(window.hwnd); sok {
						p = np
					}
				}
				if p != "" {
					if doc_save(&doc, p) {
						fmt.printfln("Newtpad: saved %s", p)
					} else {
						fmt.eprintfln("Newtpad: failed to save %s", p)
					}
				}
			case .Find:
				find_open(&doc)
			case .Escape:
				doc.anchor = doc.cursor // clear selection
			}
		}
		window.key_count = 0

		// Mouse: press places/extends the caret (double=word, triple=line); drag extends.
		if window.mouse_pressed {
			mp := doc_pos_at(&doc, window.mouse_x, window.mouse_y, px, char_w, rows)
			switch window.mouse_count {
			case 2:
				doc_select_word_at(&doc, mp)
			case 3:
				doc_select_line_at(&doc, mp)
			case:
				doc.cursor = mp
				if !window.mouse_shift {
					doc.anchor = mp
				}
			}
			window.mouse_pressed = false
		} else if window.mouse_down && window.mouse_count == 1 {
			// drag extends a single-click selection; word/line selects stay put
			doc.cursor = doc_pos_at(&doc, window.mouse_x, window.mouse_y, px, char_w, rows)
		}

		if window.scroll_delta != 0 {
			doc_scroll(&doc, window.scroll_delta)
			window.scroll_delta = 0
		}

		doc_ensure_cursor_visible(&doc, rows)

		plat.gfx_begin_frame(&gfx, 0.09, 0.11, 0.16)

		// Behind the text: find-match highlights (dim), then the selection (bright).
		findq: [80]plat.Quad
		if nfq := find_match_rects(&doc, px, char_w, rows, findq[:]); nfq > 0 {
			plat.quads_draw(&gfx, &quad_pipe, findq[:nfq])
		}
		selq: [80]plat.Quad
		ns := doc_selection_rects(&doc, px, char_w, rows, selq[:])
		if ns > 0 {
			plat.quads_draw(&gfx, &quad_pipe, selq[:ns])
		}

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

		if doc.find.active {
			bar := plat.Quad{pos = {0, h - 26}, size = {f32(window.width), 26}, color = {0.14, 0.16, 0.20, 1}}
			plat.quads_draw(&gfx, &quad_pipe, []plat.Quad{bar})
			info: string
			if len(doc.find.query) == 0 {
				info = ""
			} else if len(doc.find.matches) == 0 {
				info = "  (no matches)"
			} else {
				info = fmt.tprintf("  (%d/%d)", doc.find.current + 1, len(doc.find.matches))
			}
			fb := fmt.tprintf("Find: %s%s", string(doc.find.query[:]), info)
			plat.text_draw(&gfx, &text, fb, 12, h - 8, 14, {0.95, 0.88, 0.55, 1})
		} else {
			status := fmt.tprintf("%d lines%s%s", doc_line_count(&doc), " *" if doc.modified else "", "" if doc_index_done(&doc) else fmt.tprintf("  (indexing %.0f%%)", doc_index_progress(&doc) * 100))
			plat.text_draw(&gfx, &text, status, 12, h - 8, 13, {0.55, 0.60, 0.70, 1})
		}

		plat.gfx_end_frame(&gfx)
		free_all(context.temp_allocator)
	}
}
