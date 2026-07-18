// Layer: program — wires the layers together and owns the frame loop.
// The main thread builds UI and handles input, nothing else (nothing to build
// yet — this milestone just proves window + D3D11 present end-to-end).
package main

import "core:fmt"
import "core:os"
import "core:strconv"
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

	doc, dok := doc_open(path)
	if !dok {
		fmt.eprintfln("Newtpad: could not open %s", path)
		return
	}
	defer doc_close(&doc)
	fmt.printfln("Newtpad: opened %s (%d bytes, %v). Scroll to read; close to exit.", path, len(doc.content), doc.enc)

	px: f32 = 16
	line_h := px * 1.5

	// Optional 2nd arg: start scrolled down N lines (demo + seed of file:line jump).
	if len(os.args) > 2 {
		if n, ok := strconv.parse_int(os.args[2]); ok {
			doc_scroll(&doc, n)
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
			doc_scroll(&doc, 1_000_000_000)
			window.scroll_to_end = false
		}
		if window.scroll_delta != 0 {
			doc_scroll(&doc, window.scroll_delta)
			window.scroll_delta = 0
		}

		plat.gfx_begin_frame(&gfx, 0.09, 0.11, 0.16)
		doc_draw(&gfx, &text, &doc, px, rows)
		plat.gfx_end_frame(&gfx)
	}
}
