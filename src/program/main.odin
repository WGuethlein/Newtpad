// Layer: program — wires the layers together and owns the frame loop.
// The main thread builds UI and handles input, nothing else (nothing to build
// yet — this milestone just proves window + D3D11 present end-to-end).
package main

import "core:fmt"
import plat "src:platform"

main :: proc() {
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

	fmt.println("Newtpad is up. Close the window to exit.")

	fg := [4]f32{0.92, 0.94, 0.98, 1} // near-white ink on slate

	for !window.should_close {
		plat.window_pump_events(window)

		if window.resized {
			plat.gfx_resize(&gfx, window.width, window.height)
			window.resized = false
		}

		// Calm slate background so it's obvious the pipeline is live.
		plat.gfx_begin_frame(&gfx, 0.09, 0.11, 0.16)
		plat.text_draw(&gfx, &text, "Hello, World", 60, 110, 48, fg)
		plat.text_draw(&gfx, &text, "Newtpad renders text via DirectWrite + ClearType.", 60, 170, 22, fg)
		plat.text_draw(&gfx, &text, "The quick brown fox jumps over the lazy dog.", 60, 210, 22, fg)
		plat.text_draw(&gfx, &text, "0123456789  {}[]()<>  +-*/=  @#$%&", 60, 250, 22, fg)
		plat.gfx_end_frame(&gfx)
	}
}
