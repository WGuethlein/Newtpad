// Layer: platform — the proportional text shaper for the markdown preview.
//
// UI spec §9.1: "one text shaper — given a font + a max width, emit positioned
// glyphs and a height. This is the only new code." It exists because the preview
// pane is read-only output with no caret, no column and no selection anchor, so
// it does not need the editor's cell grid — and the grid is precisely what stops
// prose from looking like a document.
//
// The difference from the grid, stated exactly, because it is the whole point:
// text_char_width ROUNDS the advance to a whole pixel so that column n's left
// edge is exactly n*cell_w for the glyphs, the caret, the selection and the
// hit-test alike. The shaper must not do that. It accumulates the true
// fractional advance DirectWrite reports for each glyph and rounds nothing along
// the way; the only rounding is the whole-pixel snap the draw already applies at
// emit (text_walk_glyphs, floor(v + 0.5)), which exists because an integer-sized
// glyph quad sampled at a fractional position puts a vertical seam through every
// character. Accumulate fractional, snap once at emit. Rounding each advance as
// it is added would silently rebuild the grid with different arithmetic.
//
// Line breaking is greedy — accumulate advances, break at the last space before
// the measure — which is what browsers do for body text. No Knuth-Plass, no
// hyphenation, no complex-script shaping (that is IDWriteTextAnalyzer and it is
// tracked separately in HANDOFF §5).
//
// Per-glyph advances come from glyph_get, i.e. from the SAME map (Text.cache,
// keyed by Glyph_Key{set, face, index, px}) that backs the glyph atlas. There is
// no second cache and no second measurement path: the number the shaper lays out
// with is the number the draw's Glyph carries. §9.1's "preview glyphs go into
// the same atlas and the same instanced draw call as everything else" is a
// consequence of that, not a separate promise.
package platform

// One positioned glyph. `x` and `y` are pixels relative to the run's origin,
// with `y` on the BASELINE (the same convention text_draw takes) rather than at
// the top of the line box — text_draw_spans wants a baseline, and converting in
// two places is how the caret and the glyphs stop agreeing.
//
// `off` is the byte offset of the rune within the run that was shaped. It is
// here because the link seam needs it: a link's span is a byte range, and its
// pixel rect has to come from the shaper's own positions rather than from any
// second walk over the text.
Shaped_Glyph :: struct {
	x, y: f32,
	off:  i32, // byte offset into the shaped string
	line: i32, // 0-based visual line within this run
	r:    rune,
}

// The result of shaping one run.
//
// `height` is the single producer of the run's vertical cost: the fit decision,
// the block advance and the draw must all read this field rather than
// recomputing lines * something. The invariant it guarantees, and which
// `newtpad shapetest` asserts, is that every emitted glyph's ink box
// [y - ascent, y + descent] lies inside [0, height), and that the last line
// actually reaches the final line slot — so the number cannot be one line too
// large or too small without a test going red.
//
// `width` is the widest line's ADVANCE width, not its true ink width: it is the
// pen position after the last non-space glyph, so it excludes right side
// bearing and does not include ink that overhangs the advance (an italic `f`,
// a swash serif). It is the right measure for "does this line fit the column"
// (which is what greedy breaking needs) and for reporting a fit width back to
// a caller, but the link-rect seam — which needs a true ink bound around a
// span, not an advance bound — will have to compute that separately. Trailing
// spaces at a break hang past the measure (as they do in every browser) and
// are not counted, so a run that broke correctly reports width <= max_width.
//
// `lines` is the number of line slots the glyphs occupy — max(glyph.line) + 1,
// or 0 when nothing was emitted. An empty run therefore costs nothing; what an
// empty PARAGRAPH costs is the block model's decision, not the shaper's.
Shaped :: struct {
	glyphs:  []Shaped_Glyph,
	width:   f32,
	height:  f32,
	lines:   int,
	// The line box the run was laid out with, echoed back so consumers do not
	// re-derive it. line_h is the value actually used, which may exceed the
	// requested one (see shape_run).
	line_h:  f32,
	ascent:  f32,
	descent: f32,
}

shaped_free :: proc(s: ^Shaped, allocator := context.allocator) {
	delete(s.glyphs, allocator)
	s^ = {}
}

// The pixel advance of `r` at `px` in `set`, taken from the same cached Glyph the
// atlas holds. This is the ONLY place the shaper learns how wide anything is.
//
// `gfx` may be nil (headless): glyph_get then returns real DirectWrite metrics
// without touching the atlas, at the cost of not caching — see its comment.
//
// A tab advances by the tab-stop spacing in spaces rather than to the next stop.
// Real tab stops are a grid concept (they are defined in columns) and the
// preview has no columns; markdown blocks reaching the shaper have had their
// leading indentation turned into a block indent already. This cannot hang the
// way a zero cell width could — shape_run's loop is a for-range over the string,
// so it advances one rune per iteration whatever the advance is.
text_advance :: proc(gfx: ^Gfx, t: ^Text, r: rune, px: f32, set := Font_Set.Body) -> f32 {
	if r == '\t' {
		return f32(text_tab_width(t)) * text_advance(gfx, t, ' ', px, set)
	}
	if is_zero_width(r) {return 0}
	fset, face, gi := rune_face(t, r, set)
	return glyph_get(gfx, t, fset, face, gi, px).advance
}

// Shape `str` at `px` into a column `max_width` pixels wide.
//
// `line_height` is the requested leading in pixels (§9.3 asks for 1.65 * S on
// body text); pass <= 0 for the face's own ascent + descent + lineGap. It is
// clamped up to ascent + descent, because a line box shorter than the face's own
// ink would put glyphs outside the height this proc reports, which is the one
// thing the height is for. The leading is split half above and half below, as
// browsers do, so the first baseline is not jammed against the top of the block.
//
// A `max_width` of 0 or less is not an error and does not mean "unbounded": it
// degenerates to one glyph per line. Nothing here loops on the measure.
//
// TERMINATION, and the over-long word. The classic greedy breaker hangs on a
// word wider than the measure, because it breaks at the last space, finds none,
// and retries the same line forever. This one cannot: the overflow test only
// fires when the current line already holds at least one glyph, so every break
// moves the line start strictly forward, and the outer loop is a single pass
// over the runes. What a too-long word DOES is break between characters at the
// last glyph that fits ("overflow-wrap: anywhere"), rather than overflowing the
// measure. That is a decision, not a default: the preview pane is a fixed
// column with content beyond it clipped, so an overflowing 200-character URL
// would be silently unreadable, while a character-broken one is merely ugly. A
// single glyph wider than the whole measure still overflows — there is nowhere
// else for it to go — and gets a line to itself.
shape_run :: proc(
	gfx: ^Gfx,
	t: ^Text,
	str: string,
	px, max_width, line_height: f32,
	set := Font_Set.Body,
	allocator := context.allocator,
) -> (
	s: Shaped,
) {
	asc, desc, gap := text_vmetrics(t, px, set)
	lh := line_height
	if lh <= 0 {lh = asc + desc + gap}
	lh = max(lh, asc + desc)
	s.line_h, s.ascent, s.descent = lh, asc, desc
	if len(str) == 0 {return}

	mw := max(max_width, 0)
	ga := make([dynamic]Shaped_Glyph, 0, len(str), allocator)

	line: i32 = 0 // the line being filled
	line_first := 0 // index in `ga` of its first glyph
	pen: f32 = 0 // x for the next glyph on this line
	ink: f32 = 0 // pen after the last NON-SPACE glyph on this line
	brk := -1 // glyph index a break on this line would move to, or -1
	brk_ink: f32 = 0 // this line's ink width if it broke at `brk`
	in_spaces := false // currently inside a run of spaces
	pending_ink: f32 = 0 // ink width recorded when that space run started
	max_w: f32 = 0

	for r, off in str {
		if r == '\n' {
			// A hard break. The block model above will normally have split these
			// out already; handling one here means a stray newline lays out as a
			// break instead of rasterizing as .notdef.
			max_w = max(max_w, ink)
			line += 1
			line_first = len(ga)
			pen, ink, brk_ink, pending_ink = 0, 0, 0, 0
			brk, in_spaces = -1, false
			continue
		}
		space := r == ' ' || r == '\t'
		// Combining marks and zero-width format characters: the grid gives them 0
		// cells (text_cell_width_at) and so does the shaper. They are dropped
		// rather than stacked, which is the same approximation the editor makes
		// and which real shaping (IDWriteTextAnalyzer) will replace.
		if !space && is_zero_width(r) {continue}
		adv := text_advance(gfx, t, r, px, set)

		if !space {
			// The first non-space after a run of spaces is where this line may be
			// broken. Recorded BEFORE the overflow test, so a glyph that itself
			// overflows breaks at its own position rather than at the previous
			// word's.
			if in_spaces {
				brk, brk_ink, in_spaces = len(ga), pending_ink, false
			}
			// Greedy break at the last space: carry everything from `brk` onward
			// down to the next line and re-origin it. `brk` points at the first
			// non-space after the spaces, so the new line never starts with one,
			// and the spaces stay on the finished line where they hang past the
			// measure without counting toward it.
			//
			// brk == len(ga) is the COMMON case, not an edge one: it is what "the
			// glyph that overflows is the first of its word" looks like, i.e. every
			// break landing on a word boundary. That glyph has not been appended
			// yet, so its x is the live pen and the carry loop below is empty.
			if pen + adv > mw && len(ga) > line_first && brk > line_first {
				bx := pen
				if brk < len(ga) {bx = ga[brk].x}
				max_w = max(max_w, brk_ink)
				for j in brk ..< len(ga) {
					ga[j].x -= bx
					ga[j].line = line + 1
				}
				line += 1
				line_first = brk
				pen -= bx
				// Everything carried is non-space (a space run in progress would
				// have moved `brk` to this glyph above), so the pen is the ink.
				ink = pen
				brk = -1
			}
			// Deliberately a SECOND test, not an else. It covers two situations:
			//   * there was no break opportunity on this line at all, so the word
			//     is wider than the measure;
			//   * a greedy break just happened and the carried tail plus this glyph
			//     STILL do not fit, which is the same over-long word arriving one
			//     step later. Without this, that glyph hung past the measure by up
			//     to its own width — invisible whenever the leading word happened
			//     to be wider than one glyph, which is why it needs an invariant
			//     test over many measures rather than one hand-picked case.
			// Either way: break between characters, before this glyph. The line
			// held at least one glyph (tested here), so this always makes progress
			// and the shaper cannot spin.
			if pen + adv > mw && len(ga) > line_first {
				max_w = max(max_w, ink)
				line += 1
				line_first = len(ga)
				pen, ink = 0, 0
				brk = -1
			}
		}

		append(&ga, Shaped_Glyph{x = pen, off = i32(off), line = line, r = r})
		pen += adv
		if space {
			if !in_spaces {
				in_spaces, pending_ink = true, ink
			}
		} else {
			ink = pen
		}
	}
	max_w = max(max_w, ink)

	// One pass to place the baselines, from `line` alone. y is deliberately not
	// maintained during the walk: a greedy break rewrites the line index of
	// glyphs already emitted, and a y written before that would have to be
	// rewritten too — two producers for one coordinate.
	lines := 0
	if len(ga) > 0 {
		last := i32(0)
		for g in ga {last = max(last, g.line)}
		lines = int(last) + 1
	}
	base0 := (lh - (asc + desc)) * 0.5 + asc
	for &g in ga {g.y = base0 + f32(g.line) * lh}

	// cap was len(str) (one glyph per byte, the worst case); the actual glyph
	// count is smaller whenever the run has multi-byte runes or dropped
	// zero-width/CR runes. shrink to the real length before slicing, so
	// `shaped_free`'s `delete(s.glyphs, allocator)` frees exactly what was
	// allocated — `allocator` exists so the §9.1 block/span cache can own this
	// memory, and a tracking or sized allocator will reject a delete whose
	// length disagrees with what was handed out.
	shrink(&ga)
	s.glyphs = ga[:]
	s.lines = lines
	s.height = f32(lines) * lh
	s.width = max_w
	return
}
