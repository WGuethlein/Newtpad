// Layer: ui — control GEOMETRY. Where things are; not what they look like.
//
// This is the package's first real occupant (Wyatt, 2026-08-04), and the split
// that finally made it possible is worth stating because it is not the split the
// stub anticipated.
//
// The stub said "produces draw intent for the renderer". A ui package that draws
// needs plat.Gfx, plat.Text and the theme — and the theme lives in `program`. So
// every previous attempt at this extraction had to move the theme down first,
// which is how a button turns into a rewrite. That is why this package sat empty
// for sixteen batches.
//
// CLAUDE.md's actual rule is narrower than "ui draws":
//
//     A widget's geometry is produced by exactly one *_layout() procedure,
//     consumed by the draw AND the hit-test AND the hover AND the cursor.
//
// It never says the producer must draw. Splitting there gives a package that is
// pure arithmetic over f32 and strings: no COM, no device, no theme, no
// Document. It satisfies "never calls Win32/COM directly" by construction rather
// than by discipline, and it is the first layer besides `base` that
// `odin test` can reach.
//
// THE BOUNDARY, for whoever extends this: **ui decides where things are;
// program decides what they look like.** Colours, fonts and quads stay up there.
// Text advances come DOWN as numbers, in Metrics — a number crossing the seam,
// not a type.
package ui

import "core:unicode/utf8"

// Cells a label occupies on the chrome grid. RUNES, not bytes: Odin's len() on
// a string counts bytes, and every glyph these controls actually use -- the find
// bar's arrows and close, the menu's chevrons -- is multi-byte UTF-8. Centring a
// 3-byte arrow as though it were three cells puts it a cell and a half left of
// where it belongs, which reads as "the icon is off" and not as "the arithmetic
// is wrong".
cells :: proc(s: string) -> f32 {return f32(utf8.rune_count_in_string(s))}

// Per-size text advances and the box metrics a control is built from. The caller
// fills the advances from the platform's font measurement; ui cannot ask.
//
// Monospace advances, deliberately: every surface this serves is chrome, and
// chrome is one font. A proportional control would need per-string measurement,
// which means a callback, which means ui depends on platform again. When that is
// genuinely needed, pass the measured width in on the Item instead of the string.
Metrics :: struct {
	h:        f32, // box height
	pad:      f32, // horizontal padding inside the box, each side
	gap:      f32, // between a label and its chord
	label_cw: f32, // advance per character at the label size
	chord_cw: f32, // advance per character at the chord size
	baseline: f32, // from the box's top edge down to the text baseline
	// Round every coordinate to a whole pixel.
	//
	// A rendering concern reaching into a geometry package, and it belongs here
	// anyway: the alternative is the DRAW rounding while the hit-test does not, and
	// half a pixel of divergence between them is the same seam bug as thirty, just
	// harder to see. One producer means one rounding.
	//
	// Opt-in because it is not free: rounding a CENTRED glyph moves it up to half a
	// pixel off centre, which is the right trade for chrome text (a blurry label is
	// worse than a half-pixel lean) and the wrong one for a test asserting exact
	// symmetry. find_actions and menu_bar_command set it; the unit tests do not.
	snap:     bool,
}

// A labelled control: a box with its label and optional chord already placed.
//
// `tag` is an int and not a Command_Id on purpose. That type belongs to
// `program`, and a ui that named it would be a ui that depends upward — the
// exact inversion this package exists to avoid. The caller maps tags to whatever
// it dispatches.
Button :: struct {
	x, y, w, h:   f32, // the box: the hover fill and the hit-test read exactly this
	tx, ty:       f32, // label origin; ty is the baseline
	cx:           f32, // chord origin, on the same baseline
	label, chord: string,
	tag:          int,
}

// The natural width of a button with this label and chord, before it is placed.
// Split out so a caller can measure a control for `pack` without building it.
button_width :: proc(label, chord: string, m: Metrics) -> f32 {
	w := m.pad + cells(label) * m.label_cw + m.pad
	if chord != "" {w += m.gap + cells(chord) * m.chord_cw}
	return w
}

@(private = "file")
rnd :: proc(v: f32, on: bool) -> f32 {
	return f32(int(v + 0.5)) if on else v
}

// THE ONE PRODUCER. `x, y` is the box's top-left.
button_layout :: proc(x, y: f32, label, chord: string, m: Metrics, tag := 0) -> Button {
	b := Button {
		x     = x,
		y     = y,
		w     = button_width(label, chord, m),
		h     = m.h,
		label = label,
		chord = chord,
		tag   = tag,
	}
	b.tx = x + m.pad
	b.ty = y + m.baseline
	b.cx = b.tx + cells(label) * m.label_cw + m.gap
	if m.snap {
		b.x, b.y, b.w, b.h = rnd(b.x, true), rnd(b.y, true), rnd(b.w, true), rnd(b.h, true)
		b.tx, b.ty, b.cx = rnd(b.tx, true), rnd(b.ty, true), rnd(b.cx, true)
	}
	return b
}

// A square control — a stepper, a close glyph — whose label is centred rather
// than left-padded. Same struct, so the draw and the hit-test do not branch.
button_square :: proc(x, y, size: f32, label: string, m: Metrics, tag := 0) -> Button {
	b := Button {
		x     = x,
		y     = y,
		w     = size,
		h     = size,
		label = label,
		tag   = tag,
	}
	b.tx = x + (size - cells(label) * m.label_cw) * 0.5
	b.ty = y + m.baseline
	b.cx = b.tx
	if m.snap {
		b.x, b.y, b.w, b.h = rnd(b.x, true), rnd(b.y, true), rnd(b.w, true), rnd(b.h, true)
		b.tx, b.ty, b.cx = rnd(b.tx, true), rnd(b.ty, true), rnd(b.cx, true)
	}
	return b
}

// Consumed by the click, the hover and the pointer cursor. Half-open on both
// axes, so two controls sharing an edge cannot both claim it.
button_hit :: proc(b: Button, mx, my: f32) -> bool {
	return mx >= b.x && mx < b.x + b.w && my >= b.y && my < b.y + b.h
}

// --- the drop rule -------------------------------------------------------
//
// One control in a strip, as a width and a priority, for `pack`.
Item :: struct {
	w:    f32, // natural width
	drop: int, // HIGHER goes first. Ties break toward the later item.
	tag:  int,
}

// Decide which items survive in `avail`, dropping by priority, and return the
// width the survivors need (gaps included).
//
// TWO PASSES, DELIBERATELY: this decides survival and does NOT place anything.
// The status bar learned that the hard way — it placed right-to-left and then
// dropped, which meant a dropped cell left a hole at the flush edge and the drop
// order was forced to be positional rather than intentional. Deciding first lets
// a right-aligned group stay flush and lets the caller declare an order that has
// nothing to do with position (the find bar drops its Filter pill before its
// close button, because Ctrl+L and Esc both still work and neither reports
// state).
//
// SHAPE A (HANDOFF §4): a bounded scan must not report a confident wrong answer.
// This one cannot claim "everything fits" after stopping early — it recomputes
// the total from the survivor set on each removal rather than subtracting as it
// goes, so the returned width always describes exactly the set `keep` marks.
pack :: proc(items: []Item, avail, gap: f32, keep: []bool) -> (used: f32) {
	n := min(len(items), len(keep))
	for i in 0 ..< n {keep[i] = true}

	total :: proc(items: []Item, keep: []bool, n: int, gap: f32) -> f32 {
		w := f32(0)
		seen := 0
		for i in 0 ..< n {
			if !keep[i] {continue}
			w += items[i].w
			if seen > 0 {w += gap}
			seen += 1
		}
		return w
	}

	used = total(items, keep, n, gap)
	for used > avail {
		// The surviving item with the highest drop priority; the LATER one wins a
		// tie, so a caller listing controls left to right gets right-to-left
		// removal for free when every priority is equal.
		victim := -1
		for i in 0 ..< n {
			if !keep[i] {continue}
			if victim < 0 || items[i].drop >= items[victim].drop {victim = i}
		}
		if victim < 0 {break} // nothing left to give up
		keep[victim] = false
		used = total(items, keep, n, gap)
	}
	return used
}
