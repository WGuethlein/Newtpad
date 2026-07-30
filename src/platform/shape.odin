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

import "core:math"

// One positioned glyph. `x` and `y` are pixels relative to the run's origin,
// with `y` on the BASELINE (the same convention text_draw takes) rather than at
// the top of the line box — text_draw_spans wants a baseline, and converting in
// two places is how the caret and the glyphs stop agreeing.
//
// `off` is the byte offset of the rune within the SPAN it came from (the whole
// string, for shape_run, which has exactly one span). It is here because the
// link seam needs it: a link's span is a byte range, and its pixel rect has to
// come from the shaper's own positions rather than from any second walk over
// the text.
//
// `span` is the index into the Shape_Span slice the glyph came from, and is
// always 0 for shape_run. The pair (span, off) is the glyph's address in the
// caller's text; `span` alone is how the draw knows which colour and which face
// this glyph belongs to, and how an inline-code background finds its extent.
Shaped_Glyph :: struct {
	x, y: f32,
	off:  i32, // byte offset into the span's text
	line: i32, // 0-based visual line within this run
	span: i32, // index into the Shape_Span slice this came from
	r:    rune,
}

// One run of text in one face at one size. §9.3 puts inline code at 0.92 S on
// the mono face inside a paragraph at 1.00 S on the body face, so a paragraph
// is a SEQUENCE of these that has to break as one line — see shape_spans.
Shape_Span :: struct {
	text: string,
	px:   f32,
	set:  Font_Set,
}

// One visual line's box, in the run's own coordinate space.
//
// This exists because the box is a per-LINE property once a line can mix faces
// and sizes: a line holding 0.92 S mono and 1.00 S body needs the taller of the
// two ascents and the deeper of the two descents, or the code sits visibly off
// the prose's baseline. `y` is the single producer of that common baseline —
// every glyph on line l is placed at line_boxes[l].y, so no two glyphs on one
// line can disagree about where the baseline is.
//
// `top` and `h` tile the run exactly: line_boxes[l].top + .h == line_boxes[l+1]
// .top, and the last one's sum is Shaped.height.
Shaped_Line :: struct {
	top:     f32, // top of the line box, relative to the run's origin
	y:       f32, // the baseline every glyph on this line sits on
	h:       f32, // this line's box height
	ascent:  f32, // the tallest ascent among the spans landing on this line
	descent: f32, // the deepest descent among them
	width:   f32, // this line's advance width, excluding trailing spaces
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
	glyphs:     []Shaped_Glyph,
	width:      f32,
	height:     f32,
	lines:      int,
	// One entry per visual line, len == lines. The AUTHORITATIVE geometry once
	// a run can mix faces: baselines, box tops and per-line widths all come
	// from here. The three scalars below are summaries of it, kept because
	// every single-face consumer only wants the summary.
	line_boxes: []Shaped_Line,
	// The NOMINAL line box: the box a line containing every span would get.
	// For a single-face run (shape_run) that is every line's box, which is why
	// height == lines * line_h holds there and only there — under shape_spans a
	// line holding only the smaller face gets a shorter box, so height is the
	// SUM of line_boxes[].h and can be less. line_h is the value actually used,
	// which may exceed the requested one (see shape_run).
	line_h:     f32,
	ascent:     f32,
	descent:    f32,
}

shaped_free :: proc(s: ^Shaped, allocator := context.allocator) {
	delete(s.glyphs, allocator)
	delete(s.line_boxes, allocator)
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

// Shape `str` at `px` in `set` into a column `max_width` pixels wide.
//
// The one-span case of shape_spans, and literally that: it forwards. There is
// exactly one greedy breaker in this file, because two breakers that must agree
// is the shape this project has sixteen recorded instances of, and the cheapest
// evidence that the shared core still behaves is that `newtpad shapetest` — 75
// assertions written against this entry point before shape_spans existed —
// passes unchanged.
//
// `line_height` is the requested leading in pixels (§9.3 asks for 1.65 * S on
// body text); pass <= 0 for the face's own ascent + descent + lineGap. It is
// clamped up to ascent + descent (line_box_h). The leading is split half above
// and half below, as browsers do, so the first baseline is not jammed against
// the top of the block. Everything else — termination on an over-long word, a
// measure of 0, trailing spaces hanging past the break — is documented on
// shape_spans, which is where it happens.
//
// Because there is one span, every line's box is the same and the summaries on
// Shaped are exact: height == lines * line_h, and line_boxes[l].h == line_h for
// every l.
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
	one := [1]Shape_Span{{text = str, px = px, set = set}}
	return shape_spans(gfx, t, one[:], max_width, line_height, allocator)
}

// Shape a SEQUENCE of runs — each with its own face and size — as one line-broken
// paragraph into a column `max_width` pixels wide.
//
// This is what §9.3 needs and shape_run cannot express: inline code at 0.92 S on
// the mono face inside prose at 1.00 S on the body face is a paragraph whose
// spans differ in both, and it must break as ONE line.
//
// IT CANNOT BE COMPOSED FROM shape_run, and the reason is the whole design.
// Greedy breaking reaches BACKWARDS: when a glyph overflows, the breaker carries
// everything from the last space onward down to the next line and rewrites the
// `x` and `line` of glyphs it has already emitted. A per-span call has no access
// to the previous span's glyph array, so a word straddling a span boundary —
// ``an `inline code` word`` — would be forced to break at the boundary, which is
// a different layout, not an approximation of the right one. Every span here
// appends into ONE glyph array, so the carry crosses boundaries for free and
// there is exactly one breaker rather than two that must agree.
//
// `line_height` is the requested leading for the whole run, as in shape_run; it
// is clamped up PER LINE to that line's own ascent + descent. A line's box is
// the maximum over the spans that actually land on it (Shaped_Line), and every
// glyph on it is placed on that line's single baseline — the one thing that
// stops inline code from sitting visibly off the prose's baseline.
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
//
// A `max_width` of 0 or less is not an error and does not mean "unbounded": it
// degenerates to one glyph per line. Nothing here loops on the measure.
shape_spans :: proc(
	gfx: ^Gfx,
	t: ^Text,
	spans: []Shape_Span,
	max_width, line_height: f32,
	allocator := context.allocator,
) -> (
	s: Shaped,
) {
	// Per-span vertical metrics, read once. text_vmetrics is the single producer
	// of a face's ascent/descent (see its comment), and reading it per glyph
	// would be the same number fetched len(str) times.
	sm := make([]Span_Metrics, len(spans), context.temp_allocator)
	total := 0
	for sp, i in spans {
		a, d, g := text_vmetrics(t, sp.px, sp.set)
		sm[i] = {a, d, g}
		total += len(sp.text)
	}
	// The NOMINAL box: the tallest span's ascent over the deepest one's descent.
	// For a single span this is exactly the box shape_run always reported, which
	// is why every one of shapetest's height assertions still reads true.
	nasc, ndesc, ngap: f32
	for m in sm {
		nasc = max(nasc, m.asc)
		ndesc = max(ndesc, m.desc)
		ngap = max(ngap, m.gap)
	}
	s.line_h = line_box_h(line_height, nasc, ndesc, ngap)
	s.ascent, s.descent = nasc, ndesc
	if total == 0 {return}

	mw := max(max_width, 0)
	ga := make([dynamic]Shaped_Glyph, 0, total, allocator)

	line: i32 = 0 // the line being filled
	line_first := 0 // index in `ga` of its first glyph
	pen: f32 = 0 // x for the next glyph on this line
	ink: f32 = 0 // pen after the last NON-SPACE glyph on this line
	brk := -1 // glyph index a break on this line would move to, or -1
	brk_ink: f32 = 0 // this line's ink width if it broke at `brk`
	in_spaces := false // currently inside a run of spaces
	pending_ink: f32 = 0 // ink width recorded when that space run started
	// One entry per line, appended when that line is FINISHED — which is the
	// same three places the run's width used to be accumulated, so the per-line
	// widths and Shaped.width can no longer disagree: the latter is the max of
	// the former. Every path that does `line += 1` appends first, so these stay
	// in line order and never need indexing.
	lw := make([dynamic]f32, 0, 8, context.temp_allocator)
	// The span in force when each line was OPENED. Only consulted for a line
	// that ends up with no glyphs at all (a blank line between two hard
	// breaks), which has no glyphs to take a box from and still owes a height.
	seed := make([dynamic]i32, 0, 8, context.temp_allocator)
	append(&seed, 0)

	for sp, si in spans {
		for r, off in sp.text {
			if r == '\n' {
				// A hard break. The block model above will normally have split these
				// out already; handling one here means a stray newline lays out as a
				// break instead of rasterizing as .notdef.
				append(&lw, ink)
				line += 1
				append(&seed, i32(si))
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
			adv := text_advance(gfx, t, r, sp.px, sp.set)

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
				//
				// `brk` and `line_first` index the ONE array every span appends to,
				// so both can point into a previous span — which is exactly how a
				// word straddling a span boundary breaks as one word.
				if pen + adv > mw && len(ga) > line_first && brk > line_first {
					bx := pen
					if brk < len(ga) {bx = ga[brk].x}
					append(&lw, brk_ink)
					for j in brk ..< len(ga) {
						ga[j].x -= bx
						ga[j].line = line + 1
					}
					line += 1
					append(&seed, i32(si))
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
					append(&lw, ink)
					line += 1
					append(&seed, i32(si))
					line_first = len(ga)
					pen, ink = 0, 0
					brk = -1
				}
			}

			append(&ga, Shaped_Glyph{x = pen, off = i32(off), line = line, span = i32(si), r = r})
			pen += adv
			if space {
				if !in_spaces {
					in_spaces, pending_ink = true, ink
				}
			} else {
				ink = pen
			}
		}
	}
	append(&lw, ink)

	// One pass to build the line boxes and place the baselines, from `line`
	// alone. Neither y nor the box is maintained during the walk: a greedy break
	// rewrites the line index of glyphs already emitted, and anything written
	// before that would have to be rewritten too — two producers for one
	// coordinate. It is also why the per-line box has to be a maximum computed
	// after the fact rather than accumulated: a carried glyph can be the tallest
	// thing on the line it lands on and the only tall thing on the line it left.
	lines := 0
	if len(ga) > 0 {
		last := i32(0)
		for g in ga {last = max(last, g.line)}
		lines = int(last) + 1
	}
	boxes := make([]Shaped_Line, lines, allocator)
	gaps := make([]f32, lines, context.temp_allocator)
	for g in ga {
		b, m := &boxes[g.line], sm[g.span]
		b.ascent = max(b.ascent, m.asc)
		b.descent = max(b.descent, m.desc)
		gaps[g.line] = max(gaps[g.line], m.gap)
	}
	top: f32 = 0
	for &b, l in boxes {
		if b.ascent == 0 && b.descent == 0 {
			// A line with no glyphs on it at all — two hard breaks in a row. It
			// still occupies a line slot, so it takes the box of whichever span
			// was being read when the break opened it.
			m := sm[seed[l]]
			b.ascent, b.descent, gaps[l] = m.asc, m.desc, m.gap
		}
		b.h = line_box_h(line_height, b.ascent, b.descent, gaps[l])
		b.top = top
		// Half the leading above, half below, as browsers do, so the first
		// baseline is not jammed against the top of the block. THE one producer
		// of a baseline: every glyph on this line reads this y, so a 0.92 S span
		// and a 1.00 S span on one line cannot end up on two baselines.
		b.y = top + (b.h - (b.ascent + b.descent)) * 0.5 + b.ascent
		if l < len(lw) {b.width = lw[l]}
		top += b.h
		s.width = max(s.width, b.width)
	}
	for &g in ga {g.y = boxes[g.line].y}

	// cap was the total byte length (one glyph per byte, the worst case); the
	// actual glyph count is smaller whenever the run has multi-byte runes or
	// dropped zero-width/CR runes. shrink to the real length before slicing, so
	// `shaped_free`'s `delete(s.glyphs, allocator)` frees exactly what was
	// allocated — `allocator` exists so the §9.1 block/span cache can own this
	// memory, and a tracking or sized allocator will reject a delete whose
	// length disagrees with what was handed out.
	shrink(&ga)
	s.glyphs = ga[:]
	s.lines = lines
	s.line_boxes = boxes
	s.height = top
	return
}

// Draw a shaped run with its origin at (x, y), where y is the TOP of the run's
// first line box (not a baseline — the baselines are inside Shaped.line_boxes,
// which is the whole point of shaping first and drawing second).
//
// THE CONSUMER SIDE OF THE SEAM. It computes no position of its own: every
// glyph is placed at the (x, y) the shaper already assigned it, and the only
// arithmetic here is the origin translation and the whole-pixel snap
// text_walk_glyphs already applies for the same reason (an integer-sized glyph
// quad sampled at a fractional position puts a vertical seam through every
// character). A caller that wants to know where a glyph landed must ask the
// same Shaped this was handed, never re-derive it — that re-derivation is the
// bug class HANDOFF §6j counts sixteen instances of.
//
// `spans` must be the SAME slice the run was shaped from: each glyph's `span`
// indexes it for the face and size to rasterize at. `colors` is parallel to it,
// one colour per span; a short or nil `colors` falls back to `base` for the
// spans it does not cover, which is what a single-colour block wants.
//
// `lines` draws only the run's FIRST `lines` visual lines; negative means all of
// them, which is every caller that has no reason to care. It is expressed as a
// line index rather than as a y bound on purpose: this renderer has no scissor
// rect, so a caller that can only fit part of a run has to stop at a boundary the
// SHAPER knows about, and Shaped_Glyph.line is that boundary. Nothing is clipped
// and no glyph is moved -- a glyph is emitted or it is not. The markdown
// preview's per-line block admission is the caller this exists for (see
// md_block_admit); doing the same filtering outside would mean re-deriving which
// glyphs are on which line, which is the re-derivation this file's header warns
// about.
//
// Reaches the GPU through text_submit_instances, the same call text_draw_spans
// makes.
shaped_draw :: proc(
	gfx: ^Gfx,
	t: ^Text,
	s: ^Shaped,
	spans: []Shape_Span,
	x, y: f32,
	base: [4]f32,
	colors: [][4]f32 = nil,
	lines: int = -1,
) {
	if s == nil || len(s.glyphs) == 0 {return}
	if lines == 0 {return}
	g_draw.text_calls += 1 // see draw_trace.odin
	instances := make([dynamic]Text_Instance, 0, len(s.glyphs), context.temp_allocator)
	// The atlas must hold still while these UVs are being collected.
	t.drawing = true
	defer t.drawing = false
	for sg in s.glyphs {
		if lines >= 0 && int(sg.line) >= lines {continue}
		si := int(sg.span)
		if si < 0 || si >= len(spans) {continue}
		sp := spans[si]
		color := base
		if si < len(colors) {color = colors[si]}
		// A fully transparent span emits nothing at all. That is what lets a
		// caller run this twice over one Shaped to draw a SUBSET of its spans —
		// the synthetic-bold second pass in the markdown preview, which must
		// embolden the bold spans and leave the prose between them alone.
		if color.a <= 0 {continue}
		fset, face, gi := rune_face(t, sg.r, sp.set)
		g := glyph_get(gfx, t, fset, face, gi, sp.px)
		if g.w <= 0 || g.h <= 0 {continue}
		raw := [2]f32{x + sg.x + f32(g.left), y + sg.y + f32(g.top)}
		append(&instances, Text_Instance {
			pos    = {math.floor(raw.x + 0.5), math.floor(raw.y + 0.5)},
			size   = {f32(g.w), f32(g.h)},
			color  = color,
			uv_min = g.uv_min,
			uv_max = g.uv_max,
		})
	}
	text_submit_instances(gfx, t, instances[:])
}

@(private = "file")
Span_Metrics :: struct {
	asc, desc, gap: f32,
}

// The height of a line box whose tallest span has `asc`/`desc`/`gap`, given the
// caller's requested leading.
//
// `requested` <= 0 means the face's own ascent + descent + lineGap. Whatever it
// is, it is clamped up to ascent + descent, because a line box shorter than the
// face's own ink would put glyphs outside the height the run reports, which is
// the one thing that height is for. Georgia's asc + desc is 1.136 em, so §9.3's
// 1.00 S rows silently get 1.136 S of box — the reason Shaped.line_h is
// authoritative and must be read back rather than assumed.
//
// One proc because shape_spans decides this twice — once for the nominal box it
// reports and once per line — and two copies of a clamp is how the reported
// height and the emitted glyphs drift apart.
@(private = "file")
line_box_h :: proc(requested, asc, desc, gap: f32) -> f32 {
	h := requested
	if h <= 0 {h = asc + desc + gap}
	return max(h, asc + desc)
}
