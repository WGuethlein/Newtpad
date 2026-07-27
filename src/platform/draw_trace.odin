// Layer: platform — accounting for what a frame actually costs, and for what it
// actually contains. Read by `newtpad drawcount`.
//
// Two instruments, and the split between them is the point.
//
//   * The COUNTERS answer "how many draw calls?". They are what says whether
//     batching the text pipeline did anything: today text_draw_spans does one
//     heap allocation, two buffer maps and one DrawInstanced per string, at 74
//     call sites, several inside per-row loops.
//
//   * The DIGEST answers "did the pixels move?". A draw-call count is exactly
//     the kind of assertion that passes while the content is wrong — halving the
//     count by dropping half the glyphs scores as a win. So the ordered stream of
//     instances the GPU consumes (position, size, colour, UVs, per instance) is
//     hashed as well. Two runs that produce the same digest submitted the same
//     geometry in the same order, whatever number of DrawInstanced calls it took
//     to get there.
//
// The digest is deliberately blind to call boundaries: no per-call marker is
// mixed in, so merging two draws into one leaves it unchanged. That is the
// property the batching work needs — call count down, digest identical — and it
// is why the two instruments have to be read together. `drawcount` prints both.
//
// Three digests, not one. text and quad instances go to their own streams and
// also to a combined one in submission order, so a change that preserves each
// pass's content but reorders the passes against each other (drawing all text
// after all quads, say) shows up in `frame` while `text` and `quad` stay put.
// That distinction matters because the passes alpha-blend over each other:
// reordering them is a real pixel change, not a bookkeeping one.
package platform

// The instance layouts are hashed as raw bytes, so any padding the compiler
// inserted would be hashed too — uninitialised, and therefore different between
// two runs that drew identical frames. Both structs are all-f32 today and pack
// exactly; these assert that nobody adds a field that breaks it.
#assert(size_of(Text_Instance) == 12 * size_of(f32))
#assert(size_of(Quad) == 8 * size_of(f32))

Draw_Stats :: struct {
	// Calls into text_draw_spans, including those whose string produced no
	// glyphs at all (a blank status field, a zero-length span). Those still pay
	// the allocation and the per-rune walk, so they are part of what batching
	// has to remove, and hiding them would understate the work.
	text_calls:     int,
	// Of those, the ones that reached DrawInstanced.
	text_draws:     int,
	// Calls into quads_draw that had a non-empty list (an empty one returns
	// before doing anything).
	quad_calls:     int,
	text_instances: int,
	quad_instances: int,
	text_digest:    u64,
	quad_digest:    u64,
	frame_digest:   u64,
}

@(private)
g_draw: Draw_Stats

// Hashing is off unless something asks for it: the product's frame loop should
// not pay ~100 KB of FNV per frame to compute a number nobody reads. The
// counters are a single increment each and stay always-on.
@(private)
g_draw_digest_on: bool

// FNV-1a, 64-bit. Chosen for being three lines with no table and no dependency;
// this is a change-detector, not a security primitive.
@(private)
FNV64_OFFSET :: 0xcbf29ce484222325
@(private)
FNV64_PRIME :: 0x00000100000001b3

@(private)
digest_bytes :: proc "contextless" (h: u64, b: []u8) -> u64 {
	x := h
	for c in b {
		x ~= u64(c)
		x *= FNV64_PRIME
	}
	return x
}

// Turn instance-stream hashing on or off. Resetting the counters also reseeds
// the digests, so enable this before the frame you intend to measure.
draw_digest_enable :: proc(on: bool) {g_draw_digest_on = on}

draw_stats :: proc() -> Draw_Stats {return g_draw}

// The original two-number reading, kept because it is what `drawcount` has
// always printed and what HANDOFF §6k's gutter measurement is stated in.
draw_counts :: proc() -> (text_calls, quad_calls: int) {
	return g_draw.text_calls, g_draw.quad_calls
}

draw_counts_reset :: proc() {
	g_draw = {}
	g_draw.text_digest = FNV64_OFFSET
	g_draw.quad_digest = FNV64_OFFSET
	g_draw.frame_digest = FNV64_OFFSET
}

// Called by text_draw_spans / quads_draw at the moment the instances are handed
// to the GPU — after the MAX_* clamp, so what is hashed is what is drawn and not
// what was asked for. A clamped-away instance is a real pixel difference and
// must not be hashed as though it had been submitted.
@(private)
draw_note_text :: proc "contextless" (inst: []Text_Instance) {
	g_draw.text_draws += 1
	g_draw.text_instances += len(inst)
	if !g_draw_digest_on || len(inst) == 0 {return}
	bytes := (cast([^]u8)raw_data(inst))[:len(inst) * size_of(Text_Instance)]
	g_draw.text_digest = digest_bytes(g_draw.text_digest, bytes)
	g_draw.frame_digest = digest_bytes(g_draw.frame_digest, bytes)
}

@(private)
draw_note_quads :: proc "contextless" (quads: []Quad) {
	g_draw.quad_instances += len(quads)
	if !g_draw_digest_on || len(quads) == 0 {return}
	bytes := (cast([^]u8)raw_data(quads))[:len(quads) * size_of(Quad)]
	g_draw.quad_digest = digest_bytes(g_draw.quad_digest, bytes)
	g_draw.frame_digest = digest_bytes(g_draw.frame_digest, bytes)
}
