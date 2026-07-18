// Layer: program — wires the layers together and owns the frame loop.
// The main thread builds UI and handles input, nothing else (nothing to build
// yet — this milestone just proves window + D3D11 present end-to-end).
package main

import "core:fmt"
import "core:os"
import "core:strconv"
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
		fmt.printfln("indexed %d lines in %.1f ms (%d bytes, %v)", doc_line_count(&doc), time.duration_milliseconds(time.tick_since(t0)), len(doc.content), doc.enc)
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
	fmt.printfln("Newtpad: opened %s (%d bytes, %v). Scroll to read; close to exit.", path, len(doc.content), doc.enc)

	px: f32 = 16
	line_h := px * 1.5

	// Optional 2nd arg: jump to line N (uses the background index once available).
	if len(os.args) > 2 {
		if n, ok := strconv.parse_int(os.args[2]); ok {
			doc_goto_line(&doc, n)
		}
	}

	for !window.should_close {
		plat.window_pump_events(window)

		if window.resized {
			plat.gfx_resize(&gfx, window.width, window.height)
			window.resized = false
		}

		// Process queued input once per frame.
		rows := int(f32(window.height) / line_h)
		if window.scroll_to_top {
			doc.top = 0
			window.scroll_to_top = false
		}
		if window.scroll_to_end {
			lc := doc_line_count(&doc)
			doc_goto_line(&doc, lc - 1) // exact last line via the index
			doc_scroll(&doc, -(rows - 1)) // back off so the last page is visible
			window.scroll_to_end = false
		}
		if window.scroll_delta != 0 {
			doc_scroll(&doc, window.scroll_delta)
			window.scroll_delta = 0
		}

		plat.gfx_begin_frame(&gfx, 0.09, 0.11, 0.16)
		doc_draw(&gfx, &text, &doc, px, rows)

		// Scrollbar (solid quads) + status line, driven by the background index.
		lc := doc_line_count(&doc)
		if lc > 1 {
			w := f32(window.width)
			h := f32(window.height)
			thumb_y := f32(doc.top_line) / f32(lc) * h
			thumb_h := max(24, f32(rows) / f32(lc) * h)
			bar := []plat.Quad {
				{pos = {w - 14, 0}, size = {12, h}, color = {0.16, 0.18, 0.22, 1}},
				{pos = {w - 13, thumb_y}, size = {10, thumb_h}, color = {0.42, 0.48, 0.60, 1}},
			}
			plat.quads_draw(&gfx, &quad_pipe, bar)
		}
		status := fmt.tprintf("line %d / %d%s", doc.top_line + 1, lc, "" if doc_index_done(&doc) else fmt.tprintf("  (indexing %.0f%%)", doc_index_progress(&doc) * 100))
		plat.text_draw(&gfx, &text, status, 12, f32(window.height) - 8, 13, {0.55, 0.60, 0.70, 1})

		plat.gfx_end_frame(&gfx)
		free_all(context.temp_allocator)
	}
}
