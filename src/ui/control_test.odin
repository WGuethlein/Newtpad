// `odin test src/ui -collection:src=src`
//
// The point of this file is not that the arithmetic is hard. It is that this
// package is pure, so its rules can be pinned WITHOUT a device, a window or a
// font — which is the whole argument for putting geometry here rather than in
// `program`. Everything below would need a GPU and a message pump to assert one
// layer up.
package ui

import "core:testing"

@(private = "file")
M :: Metrics {
	h        = 24,
	pad      = 8,
	gap      = 6,
	label_cw = 7,
	chord_cw = 6,
	baseline = 16,
}

@(test)
button_box_and_hit_agree :: proc(t: ^testing.T) {
	b := button_layout(100, 50, "Filter", "Ctrl+L", M)
	// 8 + 6*7 + 8 + 6 + 6*6 = 100
	testing.expect_value(t, b.w, f32(100))
	testing.expect_value(t, b.h, f32(24))

	// THE SEAM: every edge of the box the draw fills is the box the click reads.
	testing.expect(t, button_hit(b, b.x, b.y), "top-left corner is inside")
	testing.expect(t, button_hit(b, b.x + b.w - 0.5, b.y + b.h - 0.5), "bottom-right is inside")
	testing.expect(t, !button_hit(b, b.x - 0.5, b.y), "one pixel left is outside")
	testing.expect(t, !button_hit(b, b.x + b.w, b.y), "the right edge is exclusive")
	testing.expect(t, !button_hit(b, b.x, b.y - 0.5), "one pixel above is outside")
	testing.expect(t, !button_hit(b, b.x, b.y + b.h), "the bottom edge is exclusive")
}

@(test)
adjacent_buttons_cannot_both_claim_an_edge :: proc(t: ^testing.T) {
	a := button_layout(0, 0, "Aa", "", M)
	b := button_layout(a.x + a.w, 0, "ab|", "", M)
	shared := b.x
	testing.expect(t, !button_hit(a, shared, 0), "the left control does not own the shared edge")
	testing.expect(t, button_hit(b, shared, 0), "the right control does")
}

@(test)
label_and_chord_sit_inside_the_box :: proc(t: ^testing.T) {
	b := button_layout(10, 0, "Filter", "Ctrl+L", M)
	testing.expect(t, b.tx >= b.x, "label starts inside")
	end := b.cx + f32(len(b.chord)) * M.chord_cw
	testing.expect(t, end <= b.x + b.w, "chord ends inside")
	testing.expect(t, b.cx > b.tx, "chord follows the label")
	// EXACTLY one gap after the label, not merely somewhere inside the box.
	//
	// The three checks above have slack: a button sized from its own content has
	// room to spare at the chord end, and shifting cx by 6px passed all of them.
	// Found by sabotaging this producer after folding find_actions and
	// menu_bar_command onto it -- two call sites whose chord placement nothing
	// else pins, since their seam tests compare the BOX against the hit-test and
	// never ask where the text inside it went.
	testing.expect_value(t, b.cx, b.tx + f32(len("Filter")) * M.label_cw + M.gap)
}

// Odin's len() on a string is BYTES. Every glyph these controls actually use is
// multi-byte UTF-8 -- the find bar's ↑ ↓ ✕, the menu's ‹ ›. Measuring in bytes
// centres a 3-byte arrow as though it were three cells, which lands it a cell
// and a half off and reads as a wonky icon rather than as bad arithmetic.
@(test)
multibyte_glyphs_measure_as_one_cell :: proc(t: ^testing.T) {
	arrow := button_square(0, 0, 24, "↑", M)
	ascii := button_square(0, 0, 24, "x", M)
	testing.expect_value(t, arrow.tx, ascii.tx)

	// And in a labelled button, where the width is what drifts.
	testing.expect_value(t, button_width("✕", "", M), button_width("x", "", M))
	testing.expect_value(t, button_width("Filter", "Ctrl+L", M), f32(100))
}

// find_actions and menu_bar_command both hand-rolled their geometry and both
// snapped every coordinate to a whole pixel, "so the glyphs land on whole pixels
// rather than sampling between texels in the alpha atlas". Folding them onto
// button_layout would have dropped that silently -- the boxes would still agree
// with their hit-tests, and the text would just go slightly soft.
@(test)
snap_rounds_every_coordinate :: proc(t: ^testing.T) {
	ms := M
	ms.snap = true
	// Fractional origin AND a fractional advance, so nothing lands whole by luck.
	ms.label_cw = 7.4
	b := button_layout(10.3, 20.7, "Filter", "Ctrl+L", ms)
	whole :: proc(v: f32) -> bool {return v == f32(int(v))}
	testing.expect(t, whole(b.x) && whole(b.y), "box origin is whole")
	testing.expect(t, whole(b.w) && whole(b.h), "box size is whole")
	testing.expect(t, whole(b.tx) && whole(b.ty), "label origin is whole")
	testing.expect(t, whole(b.cx), "chord origin is whole")
	// The seam still holds after rounding: both drawn edges hit, neither
	// neighbour pixel does.
	testing.expect(t, button_hit(b, b.x, b.y), "and the snapped box still hit-tests")
	testing.expect(t, !button_hit(b, b.x - 1, b.y), "...with its left edge exclusive below")

	// Off by default, or the centring test above would be asserting rounded values.
	u := button_layout(10.3, 20.7, "Filter", "Ctrl+L", M)
	testing.expect(t, u.x == 10.3, "snap is opt-in: unset leaves the origin alone")
}

@(test)
square_centres_its_glyph :: proc(t: ^testing.T) {
	b := button_square(0, 0, 24, "x", M)
	testing.expect_value(t, b.w, f32(24))
	// Ink is one 7-wide cell in a 24 box: (24-7)/2 = 8.5 either side.
	testing.expect_value(t, b.tx, f32(8.5))
	testing.expect_value(t, b.x + b.w - (b.tx + M.label_cw), f32(8.5))
}

// --- pack ----------------------------------------------------------------

@(private = "file")
three :: proc() -> [3]Item {
	return [3]Item{{w = 30, drop = 1, tag = 0}, {w = 40, drop = 3, tag = 1}, {w = 50, drop = 2, tag = 2}}
}

@(test)
pack_keeps_everything_when_it_fits :: proc(t: ^testing.T) {
	it := three()
	keep: [3]bool
	// 30+40+50 + two 10 gaps = 140
	used := pack(it[:], 140, 10, keep[:])
	testing.expect_value(t, used, f32(140))
	testing.expect(t, keep[0] && keep[1] && keep[2], "exactly-fits keeps all three")
}

@(test)
pack_drops_by_priority_not_by_position :: proc(t: ^testing.T) {
	it := three()
	keep: [3]bool
	// One pixel short of fitting: the HIGHEST drop (item 1, drop=3) goes, even
	// though it is neither the widest nor the last. A positional rule would take
	// item 2.
	pack(it[:], 139, 10, keep[:])
	testing.expect(t, keep[0] && !keep[1] && keep[2], "the highest drop priority goes first")
}

@(test)
pack_drops_in_priority_order_all_the_way_down :: proc(t: ^testing.T) {
	it := three()
	keep: [3]bool
	pack(it[:], 60, 10, keep[:]) // 30+50+gap = 90 still too wide; next out is drop=2
	testing.expect(t, keep[0] && !keep[1] && !keep[2], "then the next-highest")
	pack(it[:], 10, 10, keep[:])
	testing.expect(t, !keep[0] && !keep[1] && !keep[2], "and finally everything")
}

@(test)
pack_ties_break_toward_the_later_item :: proc(t: ^testing.T) {
	it := [3]Item{{w = 30, drop = 1}, {w = 30, drop = 1}, {w = 30, drop = 1}}
	keep: [3]bool
	// All equal: a caller listing controls left-to-right gets right-to-left
	// removal, which is what the status bar wants and what it had to hand-roll.
	pack(it[:], 65, 5, keep[:])
	testing.expect(t, keep[0] && keep[1] && !keep[2], "rightmost goes first on a tie")
}

// SHAPE A (HANDOFF §4): a bounded scan must not report a confident wrong answer.
// `used` has to describe the set `keep` marks, not the set pack started with.
//
// SWEEPS EVERY WIDTH, and the first version of this test did not — it checked
// one `avail` and PASSED under the subtract-as-you-go sabotage it was written to
// catch. The reason is worth keeping: removing k of n items removes exactly k
// gaps, so subtracting `w + gap` per victim agrees with a recount at every step
// EXCEPT the last, when the final survivor leaves and there was no gap left to
// take. One sample missed it; the invariant checked across the whole range does
// not. A test aimed at a shape has to be aimed at where the shape bites.
@(test)
pack_reports_the_width_of_what_survived :: proc(t: ^testing.T) {
	it := three()
	for avail := f32(0); avail <= 160; avail += 1 {
		keep: [3]bool
		used := pack(it[:], avail, 10, keep[:])
		want := f32(0)
		seen := 0
		for k, i in keep {
			if !k {continue}
			want += it[i].w
			if seen > 0 {want += 10}
			seen += 1
		}
		if used != want {
			testing.expectf(t, false, "avail=%.0f: reported %.0f, survivors need %.0f", avail, used, want)
			return
		}
		if used > avail {
			testing.expectf(t, false, "avail=%.0f: kept %.0f, which does not fit", avail, used)
			return
		}
	}
}

@(test)
pack_survives_an_impossible_width :: proc(t: ^testing.T) {
	it := three()
	keep: [3]bool
	used := pack(it[:], 0, 10, keep[:])
	testing.expect_value(t, used, f32(0))
	for k in keep {testing.expect(t, !k, "nothing survives zero width")}
}

@(test)
pack_tolerates_a_short_keep_buffer :: proc(t: ^testing.T) {
	it := three()
	keep: [2]bool // deliberately smaller than items
	used := pack(it[:], 1000, 10, keep[:])
	// It must describe only what it could answer for, rather than indexing past
	// the caller's buffer or reporting the third item as surviving.
	testing.expect_value(t, used, f32(80)) // 30 + 40 + one gap
	testing.expect(t, keep[0] && keep[1], "both answerable items survive")
}
