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

	quad_pipe, qok := plat.quads_init(&gfx)
	if !qok {
		fmt.eprintln("Newtpad: failed to initialize quad pipeline")
		return
	}

	// SPIKE: de-risk DirectWrite-from-Odin before building the glyph atlas.
	// Rasterizes one glyph via hand-declared DWrite COM and dumps it as ASCII.
	// Remove once the atlas/text pipeline lands.
	plat.glyph_spike('A', 32)

	fmt.println("Newtpad is up. Close the window to exit.")

	// A few rectangles to prove the instanced pipeline draws in one call.
	rects := []plat.Quad {
		{pos = {60, 60}, size = {320, 200}, color = {0.90, 0.32, 0.32, 1}},
		{pos = {420, 120}, size = {260, 320}, color = {0.32, 0.72, 0.46, 1}},
		{pos = {720, 200}, size = {440, 240}, color = {0.36, 0.56, 0.95, 1}},
		{pos = {200, 430}, size = {520, 160}, color = {0.95, 0.80, 0.28, 1}},
	}

	for !window.should_close {
		plat.window_pump_events(window)

		if window.resized {
			plat.gfx_resize(&gfx, window.width, window.height)
			window.resized = false
		}

		// Calm slate background so it's obvious the pipeline is live.
		plat.gfx_begin_frame(&gfx, 0.09, 0.11, 0.16)
		plat.quads_draw(&gfx, &quad_pipe, rects)
		plat.gfx_end_frame(&gfx)
	}
}
