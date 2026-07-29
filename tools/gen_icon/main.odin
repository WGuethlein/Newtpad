// Generates src/platform/newtpad.ico by hand -- no image library, because the
// dependency bar (CLAUDE.md) is "OS APIs + at most a couple of trusted
// single-file libraries, each individually justified," and a whole PNG/ICO
// encoder is not worth justifying for one asset. Run with:
//
//   odin run tools/gen_icon -collection:src=src
//
// from the repo root. It overwrites src/platform/newtpad.ico. Commit the
// regenerated file alongside any change to the geometry table below.
//
// ---------------------------------------------------------------------------
// THE ARTWORK
//
// "16a Caret on paper" from docs/ui-spec/newtpad-ui-spec-v1.md §16 (Wyatt's
// choice, docs/superpowers/specs/2026-07-29-batch-17-preview-shaper-design.md
// "Part two"). Warm paper, an accent caret, two or three text-line bars.
// The HTML mockup (search newtpad-ui-spec-v1.html for "Caret on paper") gives
// hand-tuned rectangles at 96/48/32/16px; those four are the source of truth.
// This tool ships 16/20/24/32/48/64/256 (the spec's required set), so the
// four sizes the mockup doesn't cover (20, 24, 64, 256) are derived here by
// scaling every rectangle from the nearest hand-tuned reference and rounding
// each coordinate to a whole pixel independently -- see the comment on SPECS.
//
// ---------------------------------------------------------------------------
// THE FILE FORMAT
//
// A .ico is:
//   ICONDIR         6 bytes:  reserved(u16)=0, type(u16)=1, count(u16)
//   ICONDIRENTRY[]  16 bytes each, one per image, in the same order the image
//                   data follows in the file (not required by the format, but
//                   simplest to get right):
//     width, height   u8 each (0 means 256 -- the one place this format
//                      can't express its own most common large size)
//     colorCount       u8  = 0 (not a palette image)
//     reserved         u8  = 0
//     planes           u16 = 1
//     bitCount         u16 = 32
//     bytesInRes       u32 = length of this image's data
//     imageOffset      u32 = byte offset from the start of the FILE
//   image data[]    concatenated, one blob per entry, at the offsets above.
//
// Two blob shapes are legal per entry: a BMP (BITMAPINFOHEADER + XOR color
// data + AND mask, no file header -- unlike a standalone .bmp, an icon's DIB
// has no BITMAPFILEHEADER) or a complete PNG file.
//
// PNG from 48px up, BMP for 16/20/24/32. CHANGED (2026-07-29 review, F8): this
// was PNG for 256 only, which left 36 KB of the 39 KB resource as raw BGRA --
// 44% of the whole batch's exe growth, in a file whose every entry is flat
// colour and therefore almost pure run-length. DEFLATE of each stored entry
// measured: 16 -> 94 bytes, 20 -> 102, 24 -> 114, 32 -> 139, 48 -> 205,
// 64 -> 247. The two largest are where the bytes are (48*48*4 + 64*64*4 is
// 25 KB of the 36), so those two move and the four smallest stay.
//
// The four smallest stay for compatibility, not for size: PNG-in-ICO works from
// Vista on and the app's manifest already requires PerMonitorV2, so nothing
// Newtpad supports could fail to read a PNG entry -- but the small sizes are
// the ones consumed by the widest variety of shell surfaces and third-party
// code (Alt+Tab, tray, jump lists, file-dialog lists, older shell extensions),
// and 449 bytes of BMP is not worth finding out. The 16..32 entries are 6 KB
// together, which is the whole remaining cost.
//
// BMP blob layout, BITMAPINFOHEADER (40 bytes) then pixels:
//   biHeight is doubled (XOR height + AND height) -- that doubling is how a
//   reader locates the AND mask without a separate length field.
//   XOR data: BGRA, 4 bytes/pixel (so no row padding needed), bottom-up (the
//   last row in the file is the top row of the image -- classic BMP).
//   AND mask: 1 bit/pixel, rows padded to a 4-byte boundary, also bottom-up.
//   Modern Windows composites via the alpha channel and mostly ignores the
//   AND mask, but old code paths still read it, so it is filled in for real:
//   1 where alpha==0 (transparent), 0 elsewhere.
//
// PNG blob layout: signature + IHDR + IDAT + IEND chunks, 8-bit RGBA
// (colour type 6), no interlacing. The IDAT payload is a real zlib stream:
// each scanline gets the PNG row filter (types 0-4) that minimises the
// sum-of-absolute-differences heuristic, then the filtered bytes are
// compressed with DEFLATE using fixed Huffman codes (RFC 1951 BTYPE=01) over
// a hash-chain LZ77 match search. This image is five flat-colour rectangles
// on a flat background, so the Up filter turns most scanlines into runs of
// zero and LZ77 collapses those runs hard -- no dynamic Huffman tables
// needed to get from ~262 KB raw down to a few KB. See verify_png below:
// every encoded PNG is decoded again in-process (chunk CRCs, zlib Adler-32,
// inflate, un-filter) and compared byte-for-byte against the source pixels
// before gen_icon will write the .ico, so a broken deflate stream fails the
// build instead of shipping a silently-corrupt icon.
//
// ---------------------------------------------------------------------------
// ANTI-ALIASING
//
// Every shape here is an axis-aligned rectangle except the paper's rounded
// corners, so "draw it properly" only has one hard case. render() supersamples
// each output pixel at 4x4=16 sub-pixel samples and box-filters down, rather
// than trying to anti-alias the rounded-rect edge (or the caret/paper edge)
// analytically. The 4x4 loop and the "average only the covered samples" box
// filter are written inline per pixel instead of materializing a literal
// 4x-size intermediate bitmap first -- same result, no extra allocation.
package main

import "core:fmt"
import "core:os"

// --------------------------------------------------------------- geometry

Rect :: struct {
	x, y, w, h: int,
}

RGB :: struct {
	r, g, b: u8,
}

PAPER :: RGB{0xF2, 0xEB, 0xE0} // #F2EBE0
CARET :: RGB{0xD9, 0x9B, 0x62} // #D99B62
LINE_AB :: RGB{0xB3, 0xA8, 0x97} // #B3A897 -- lines 1 and 2
LINE_C :: RGB{0xCD, 0xC3, 0xB4} // #CDC3B4 -- line 3, when present

Line :: struct {
	rect:  Rect,
	color: RGB,
}

Icon_Spec :: struct {
	size:       int,
	radius:     int,
	caret:      Rect,
	lines:      [3]Line,
	line_count: int, // 2 at 16/20px (a third line would be under ~2px), else 3
}

// 16, 32, 48px come straight from the spec's own hand-tuned mockup (see the
// header comment). 20, 24, 64, 256 are not in the mockup, so each rectangle
// is scaled from the nearest hand-tuned size and every coordinate is rounded
// to a whole pixel independently (round-half-away-from-zero), per the batch
// spec's rule: "derive proportionally from the nearest specified size and
// round to whole pixels -- every rectangle must land on integer coordinates
// or it will look soft."
//
//   20  <- 16px  * 1.25       (20 is 4 away from 16, 12 away from 32)
//   24  <- 32px  * 0.75       (24 is equidistant from 16 and 32; 32 is used
//                               so the third line survives at exactly 2px --
//                               deriving from 16 would drop it)
//   64  <- 48px  * 4/3
//   256 <- 96px  * 8/3        (96 is the mockup's own reference size, itself
//                               not a shipped size)
//
// Independent per-rectangle rounding means gaps between elements at a derived
// size are not perfectly proportional to the source (e.g. 24px's two text
// lines sit 1px apart rather than a scaled 2-3px) -- expected, and still
// clearly separated at every size; see the batch spec for why the four
// hand-tuned sizes are authoritative and these four are not.
//
// The smallest size stored as a PNG rather than as raw BGRA. See the file
// header for why the line is here and not at 256 or at 16. `newtpad icontest`
// asserts the same split from the other side, off the committed bytes.
ICO_PNG_FROM :: 48

SPECS := [7]Icon_Spec {
	{
		size = 16,
		radius = 3,
		caret = {4, 4, 2, 8},
		lines = {{{8, 5, 5, 2}, LINE_AB}, {{8, 10, 5, 2}, LINE_AB}, {}},
		line_count = 2,
	},
	{
		size = 20,
		radius = 4,
		caret = {5, 5, 3, 10},
		lines = {{{10, 6, 6, 3}, LINE_AB}, {{10, 13, 6, 3}, LINE_AB}, {}},
		line_count = 2,
	},
	{
		size = 24,
		radius = 4,
		caret = {7, 6, 2, 12},
		lines = {{{11, 8, 7, 2}, LINE_AB}, {{11, 11, 7, 2}, LINE_AB}, {{11, 15, 4, 2}, LINE_C}},
		line_count = 3,
	},
	{
		size = 32,
		radius = 5,
		caret = {9, 8, 2, 16},
		lines = {{{15, 10, 9, 2}, LINE_AB}, {{15, 15, 9, 2}, LINE_AB}, {{15, 20, 5, 2}, LINE_C}},
		line_count = 3,
	},
	{
		size = 48,
		radius = 7,
		caret = {13, 12, 3, 24},
		lines = {{{22, 15, 13, 3}, LINE_AB}, {{22, 23, 13, 3}, LINE_AB}, {{22, 31, 8, 3}, LINE_C}},
		line_count = 3,
	},
	{
		size = 64,
		radius = 9,
		caret = {17, 16, 4, 32},
		lines = {{{29, 20, 17, 4}, LINE_AB}, {{29, 31, 17, 4}, LINE_AB}, {{29, 41, 11, 4}, LINE_C}},
		line_count = 3,
	},
	{
		size = 256,
		radius = 37,
		caret = {69, 64, 16, 128},
		lines = {{{117, 80, 69, 13}, LINE_AB}, {{117, 123, 69, 13}, LINE_AB}, {{117, 165, 43, 13}, LINE_C}},
		line_count = 3,
	},
}

// --------------------------------------------------------------- rendering

inside_rect :: proc(fx, fy: f64, r: Rect) -> bool {
	return fx >= f64(r.x) && fx < f64(r.x + r.w) && fy >= f64(r.y) && fy < f64(r.y + r.h)
}

// Standard rounded-rect containment test: outside the 0..w / 0..h box is out;
// inside the "plus" formed by excluding the four radius x radius corner
// squares is always in; inside a corner square is in only within `radius` of
// that corner's centre.
inside_rounded_rect :: proc(fx, fy, w, h, radius: f64) -> bool {
	if fx < 0 || fx >= w || fy < 0 || fy >= h {
		return false
	}
	dx := max(0.0, radius - fx, fx - (w - radius))
	dy := max(0.0, radius - fy, fy - (h - radius))
	return dx * dx + dy * dy <= radius * radius
}

// Returns top-down RGBA8, size*size*4 bytes, straight (non-premultiplied)
// alpha with colour taken only from covered sub-samples (so a fully
// transparent pixel's RGB is deterministic paper colour, not garbage, even
// though nothing should ever composite it visibly).
render :: proc(spec: Icon_Spec) -> []u8 {
	size := spec.size
	out := make([]u8, size * size * 4)
	SS :: 4
	N :: SS * SS
	for y in 0 ..< size {
		for x in 0 ..< size {
			sum_r, sum_g, sum_b, cover := 0, 0, 0, 0
			for sy in 0 ..< SS {
				for sx in 0 ..< SS {
					fx := f64(x) + (f64(sx) + 0.5) / f64(SS)
					fy := f64(y) + (f64(sy) + 0.5) / f64(SS)
					if !inside_rounded_rect(fx, fy, f64(size), f64(size), f64(spec.radius)) {
						continue
					}
					cover += 1
					col := PAPER
					if inside_rect(fx, fy, spec.caret) {
						col = CARET
					} else {
						for i in 0 ..< spec.line_count {
							if inside_rect(fx, fy, spec.lines[i].rect) {
								col = spec.lines[i].color
								break
							}
						}
					}
					sum_r += int(col.r)
					sum_g += int(col.g)
					sum_b += int(col.b)
				}
			}
			idx := (y * size + x) * 4
			if cover > 0 {
				out[idx + 0] = u8(sum_r / cover)
				out[idx + 1] = u8(sum_g / cover)
				out[idx + 2] = u8(sum_b / cover)
				out[idx + 3] = u8((cover * 255 + N / 2) / N)
			} else {
				out[idx + 0] = PAPER.r
				out[idx + 1] = PAPER.g
				out[idx + 2] = PAPER.b
				out[idx + 3] = 0
			}
		}
	}
	return out
}

// --------------------------------------------------------------- byte packing

put_u16le :: proc(buf: []u8, off: ^int, v: u16) {
	buf[off^ + 0] = u8(v & 0xFF)
	buf[off^ + 1] = u8((v >> 8) & 0xFF)
	off^ += 2
}

put_u32le :: proc(buf: []u8, off: ^int, v: u32) {
	buf[off^ + 0] = u8(v & 0xFF)
	buf[off^ + 1] = u8((v >> 8) & 0xFF)
	buf[off^ + 2] = u8((v >> 16) & 0xFF)
	buf[off^ + 3] = u8((v >> 24) & 0xFF)
	off^ += 4
}

put_i32le :: proc(buf: []u8, off: ^int, v: i32) {
	put_u32le(buf, off, u32(v))
}

put_u32be :: proc(buf: []u8, off: ^int, v: u32) {
	buf[off^ + 0] = u8((v >> 24) & 0xFF)
	buf[off^ + 1] = u8((v >> 16) & 0xFF)
	buf[off^ + 2] = u8((v >> 8) & 0xFF)
	buf[off^ + 3] = u8(v & 0xFF)
	off^ += 4
}

dput_u16le :: proc(out: ^[dynamic]u8, v: u16) {
	append(out, u8(v & 0xFF), u8((v >> 8) & 0xFF))
}

dput_u32le :: proc(out: ^[dynamic]u8, v: u32) {
	append(out, u8(v & 0xFF), u8((v >> 8) & 0xFF), u8((v >> 16) & 0xFF), u8((v >> 24) & 0xFF))
}

dput_u32be :: proc(out: ^[dynamic]u8, v: u32) {
	append(out, u8((v >> 24) & 0xFF), u8((v >> 16) & 0xFF), u8((v >> 8) & 0xFF), u8(v & 0xFF))
}

// ------------------------------------------------------------- BMP-style icon

// BITMAPINFOHEADER + BGRA XOR data + 1bpp AND mask. No BITMAPFILEHEADER --
// an icon directory entry's image data starts directly at the DIB header.
encode_bmp_entry :: proc(rgba: []u8, size: int) -> []u8 {
	mask_row_bytes := ((size + 31) / 32) * 4
	xor_size := size * size * 4
	and_size := mask_row_bytes * size
	buf := make([]u8, 40 + xor_size + and_size)
	off := 0
	put_u32le(buf, &off, 40) // biSize
	put_i32le(buf, &off, i32(size)) // biWidth
	put_i32le(buf, &off, i32(size * 2)) // biHeight: XOR + AND
	put_u16le(buf, &off, 1) // biPlanes
	put_u16le(buf, &off, 32) // biBitCount
	put_u32le(buf, &off, 0) // biCompression = BI_RGB
	put_u32le(buf, &off, u32(xor_size + and_size)) // biSizeImage
	put_i32le(buf, &off, 0) // biXPelsPerMeter
	put_i32le(buf, &off, 0) // biYPelsPerMeter
	put_u32le(buf, &off, 0) // biClrUsed
	put_u32le(buf, &off, 0) // biClrImportant

	// XOR (colour) data, bottom-up, BGRA -- 4 bytes/pixel needs no row padding.
	for row := size - 1; row >= 0; row -= 1 {
		for col := 0; col < size; col += 1 {
			idx := (row * size + col) * 4
			buf[off + 0] = rgba[idx + 2] // B
			buf[off + 1] = rgba[idx + 1] // G
			buf[off + 2] = rgba[idx + 0] // R
			buf[off + 3] = rgba[idx + 3] // A
			off += 4
		}
	}

	// AND mask, bottom-up, 1 bit/pixel, rows padded to a 4-byte boundary.
	// Bit set (1) marks a transparent pixel; modern Windows composites via
	// the alpha channel and mostly ignores this, but it must still be
	// present and correct for the format to be valid.
	for row := size - 1; row >= 0; row -= 1 {
		row_start := off
		for i in 0 ..< mask_row_bytes {
			buf[row_start + i] = 0
		}
		for col := 0; col < size; col += 1 {
			idx := (row * size + col) * 4
			if rgba[idx + 3] == 0 {
				byte_i := col / 8
				bit_i := u8(7 - (col % 8))
				buf[row_start + byte_i] |= (1 << bit_i)
			}
		}
		off += mask_row_bytes
	}

	return buf
}

// -------------------------------------------------------------- PNG filters

// Standard PNG Paeth predictor (PNG spec §9.4): picks whichever of a, b, c
// is closest to a+b-c, with ties broken a, then b, then c.
paeth_predictor :: proc(a, b, c: int) -> int {
	p := a + b - c
	pa := abs(p - a)
	pb := abs(p - b)
	pc := abs(p - c)
	if pa <= pb && pa <= pc {
		return a
	}
	if pb <= pc {
		return b
	}
	return c
}

// Applies each of PNG's five per-scanline filters (spec §9.2) to an RGBA8
// image, bpp=4, and keeps whichever filter minimises the sum of the
// filtered bytes read as signed values -- the standard "minimum sum of
// absolute differences" heuristic (libpng's default). The image is only
// 256 rows even at its largest, so this is a full per-row search across all
// five filter types rather than a partial heuristic.
// Returns size*(1+size*4) bytes: one filter-type byte followed by the
// filtered scanline, per row -- exactly the layout DEFLATE will compress.
filter_scanlines :: proc(rgba: []u8, size: int) -> []u8 {
	bpp :: 4
	stride := size * bpp
	out := make([]u8, size * (1 + stride))
	prev := make([]u8, stride) // row "above" row 0 is defined as all zero
	defer delete(prev)
	trial := make([]u8, stride)
	defer delete(trial)
	best := make([]u8, stride)
	defer delete(best)

	for row in 0 ..< size {
		line := rgba[row * stride:(row + 1) * stride]

		best_type := 0
		best_sum := max(int)
		for ftype in 0 ..= 4 {
			sum := 0
			for x in 0 ..< stride {
				raw := int(line[x])
				a := int(line[x - bpp]) if x >= bpp else 0
				b := int(prev[x])
				c := int(prev[x - bpp]) if x >= bpp else 0
				v: int
				switch ftype {
				case 0:
					v = raw
				case 1:
					v = raw - a
				case 2:
					v = raw - b
				case 3:
					v = raw - (a + b) / 2
				case 4:
					v = raw - paeth_predictor(a, b, c)
				}
				fb := u8(v)
				trial[x] = fb
				sum += abs(int(transmute(i8)fb)) // signed-byte abs, per the heuristic
			}
			if sum < best_sum {
				best_sum = sum
				best_type = ftype
				copy(best[:], trial[:])
			}
		}

		out_row := out[row * (1 + stride):(row + 1) * (1 + stride)]
		out_row[0] = u8(best_type)
		copy(out_row[1:], best[:])
		copy(prev[:], line)
	}

	return out
}

// Inverse of filter_scanlines: reconstructs raw RGBA8 scanlines from
// filtered ones. Used only by verify_png below (this tool's own round-trip
// check), never by the encoder.
unfilter_scanlines :: proc(raw: []u8, size: int) -> (rgba: []u8, ok: bool) {
	bpp :: 4
	stride := size * bpp
	if len(raw) != size * (1 + stride) {
		return nil, false
	}
	rgba = make([]u8, size * stride)
	prev := make([]u8, stride)
	defer delete(prev)
	cur := make([]u8, stride)
	defer delete(cur)

	for row in 0 ..< size {
		row_start := row * (1 + stride)
		ftype := raw[row_start]
		data := raw[row_start + 1:row_start + 1 + stride]
		for x in 0 ..< stride {
			a := int(cur[x - bpp]) if x >= bpp else 0
			b := int(prev[x])
			c := int(prev[x - bpp]) if x >= bpp else 0
			recon: int
			switch ftype {
			case 0:
				recon = int(data[x])
			case 1:
				recon = int(data[x]) + a
			case 2:
				recon = int(data[x]) + b
			case 3:
				recon = int(data[x]) + (a + b) / 2
			case 4:
				recon = int(data[x]) + paeth_predictor(a, b, c)
			case:
				return nil, false
			}
			cur[x] = u8(recon)
		}
		copy(rgba[row * stride:(row + 1) * stride], cur[:])
		copy(prev[:], cur[:])
	}
	return rgba, true
}

// ------------------------------------------------------------- DEFLATE (RFC 1951)
//
// Fixed-Huffman-only encoder and decoder. No dynamic Huffman tables (BTYPE
// 10) -- fixed codes (BTYPE 01) need no tree construction and, combined with
// LZ77 back-references over the mostly-zero filtered rows this image
// produces, are already sufficient (see the file header). The decoder here
// also accepts stored blocks (BTYPE 00) since that costs nothing extra and
// keeps the decoder generally useful, but the encoder never emits them.

Code_Info :: struct {
	base, extra: int,
}

// Index i corresponds to length/literal symbol 257+i.
LENGTH_INFO := [29]Code_Info {
	{3, 0}, {4, 0}, {5, 0}, {6, 0}, {7, 0}, {8, 0}, {9, 0}, {10, 0},
	{11, 1}, {13, 1}, {15, 1}, {17, 1},
	{19, 2}, {23, 2}, {27, 2}, {31, 2},
	{35, 3}, {43, 3}, {51, 3}, {59, 3},
	{67, 4}, {83, 4}, {99, 4}, {115, 4},
	{131, 5}, {163, 5}, {195, 5}, {227, 5},
	{258, 0},
}

// Index i is distance code i (fixed Huffman: distance codes are their own
// 5-bit value, no separate symbol table).
DISTANCE_INFO := [30]Code_Info {
	{1, 0}, {2, 0}, {3, 0}, {4, 0},
	{5, 1}, {7, 1},
	{9, 2}, {13, 2},
	{17, 3}, {25, 3},
	{33, 4}, {49, 4},
	{65, 5}, {97, 5},
	{129, 6}, {193, 6},
	{257, 7}, {385, 7},
	{513, 8}, {769, 8},
	{1025, 9}, {1537, 9},
	{2049, 10}, {3073, 10},
	{4097, 11}, {6145, 11},
	{8193, 12}, {12289, 12},
	{16385, 13}, {24577, 13},
}

length_to_code :: proc(length: int) -> (code, extra_bits, extra_val: int) {
	for i := len(LENGTH_INFO) - 1; i >= 0; i -= 1 {
		if length >= LENGTH_INFO[i].base {
			return 257 + i, LENGTH_INFO[i].extra, length - LENGTH_INFO[i].base
		}
	}
	return 257, 0, 0
}

distance_to_code :: proc(dist: int) -> (code, extra_bits, extra_val: int) {
	for i := len(DISTANCE_INFO) - 1; i >= 0; i -= 1 {
		if dist >= DISTANCE_INFO[i].base {
			return i, DISTANCE_INFO[i].extra, dist - DISTANCE_INFO[i].base
		}
	}
	return 0, 0, 0
}

// Fixed Huffman literal/length code table, RFC 1951 §3.2.6.
fixed_lit_code :: proc(sym: int) -> (code: u32, nbits: int) {
	switch {
	case sym <= 143:
		return u32(0x30 + sym), 8
	case sym <= 255:
		return u32(0x190 + (sym - 144)), 9
	case sym <= 279:
		return u32(sym - 256), 7
	case:
		return u32(0xC0 + (sym - 280)), 8
	}
}

Bit_Writer :: struct {
	out:   [dynamic]u8,
	buf:   u32,
	nbits: int,
}

// LSB-first packing -- used for the block header (BFINAL/BTYPE) and every
// "extra bits" field. Huffman codes use bw_put_huffman instead (see below).
bw_put_bits :: proc(bw: ^Bit_Writer, value: u32, n: int) {
	bw.buf |= value << u32(bw.nbits)
	bw.nbits += n
	for bw.nbits >= 8 {
		append(&bw.out, u8(bw.buf & 0xFF))
		bw.buf >>= 8
		bw.nbits -= 8
	}
}

// Huffman codes are packed starting with the code's most-significant bit
// (RFC 1951 §3.1.1) -- the opposite order from every other field in the
// stream -- so reverse it into the normal LSB-first bit packer one bit at a
// time. n is at most 9 here, so this never gets to matter for speed.
bw_put_huffman :: proc(bw: ^Bit_Writer, code: u32, n: int) {
	for i := n - 1; i >= 0; i -= 1 {
		bw_put_bits(bw, (code >> u32(i)) & 1, 1)
	}
}

bw_flush :: proc(bw: ^Bit_Writer) {
	if bw.nbits > 0 {
		append(&bw.out, u8(bw.buf & 0xFF))
		bw.buf = 0
		bw.nbits = 0
	}
}

MIN_MATCH :: 3
MAX_MATCH :: 258
LZ_WINDOW :: 32768
LZ_HASH_BITS :: 15
LZ_HASH_SIZE :: 1 << LZ_HASH_BITS
LZ_MAX_CHAIN :: 128 // bounded search; this image's redundancy makes long chains rare

lz_hash :: proc(data: []u8, i: int) -> u32 {
	h := u32(data[i]) << 10 ~ u32(data[i + 1]) << 5 ~ u32(data[i + 2])
	return h & (LZ_HASH_SIZE - 1)
}

// LZ77 (hash-chain match search, greedy -- no lazy matching) + fixed Huffman
// deflate, RFC 1951 §3.2.5/3.2.6. Emits a single final block (BFINAL=1,
// BTYPE=01); deflate blocks have no size limit the way stored blocks do, so
// one block for the whole image is fine.
deflate_fixed :: proc(data: []u8) -> []u8 {
	bw: Bit_Writer
	bw.out = make([dynamic]u8, 0, len(data) / 4 + 16)

	bw_put_bits(&bw, 1, 1) // BFINAL = 1
	bw_put_bits(&bw, 1, 2) // BTYPE = 01 (fixed Huffman)

	n := len(data)
	head := make([]int, LZ_HASH_SIZE)
	defer delete(head)
	for i in 0 ..< LZ_HASH_SIZE {
		head[i] = -1
	}
	prev := make([]int, max(n, 1))
	defer delete(prev)

	insert_hash :: proc(data: []u8, pos: int, head: []int, prev: []int) {
		h := lz_hash(data, pos)
		prev[pos] = head[h]
		head[h] = pos
	}

	i := 0
	for i < n {
		best_len := 0
		best_dist := 0
		if i + MIN_MATCH <= n {
			h := lz_hash(data, i)
			cand := head[h]
			chain := 0
			max_len := min(MAX_MATCH, n - i)
			for cand >= 0 && chain < LZ_MAX_CHAIN {
				dist := i - cand
				if dist > LZ_WINDOW {
					break
				}
				l := 0
				for l < max_len && data[cand + l] == data[i + l] {
					l += 1
				}
				if l > best_len {
					best_len = l
					best_dist = dist
					if l >= MAX_MATCH {
						break
					}
				}
				cand = prev[cand]
				chain += 1
			}
		}

		if best_len >= MIN_MATCH {
			code, ebits, eval := length_to_code(best_len)
			lcode, lnbits := fixed_lit_code(code)
			bw_put_huffman(&bw, lcode, lnbits)
			if ebits > 0 {
				bw_put_bits(&bw, u32(eval), ebits)
			}

			dcode, debits, deval := distance_to_code(best_dist)
			bw_put_huffman(&bw, u32(dcode), 5)
			if debits > 0 {
				bw_put_bits(&bw, u32(deval), debits)
			}

			end := i + best_len
			for i < end {
				if i + MIN_MATCH <= n {
					insert_hash(data, i, head, prev)
				}
				i += 1
			}
		} else {
			lit := int(data[i])
			lcode, lnbits := fixed_lit_code(lit)
			bw_put_huffman(&bw, lcode, lnbits)
			if i + MIN_MATCH <= n {
				insert_hash(data, i, head, prev)
			}
			i += 1
		}
	}

	ecode, enbits := fixed_lit_code(256) // end-of-block symbol
	bw_put_huffman(&bw, ecode, enbits)

	bw_flush(&bw)
	return bw.out[:]
}

Bit_Reader :: struct {
	data:   []u8,
	pos:    int,
	bitpos: int,
}

br_read_bit :: proc(br: ^Bit_Reader) -> (bit: u32, ok: bool) {
	if br.pos >= len(br.data) {
		return 0, false
	}
	b := br.data[br.pos]
	bit = u32((b >> u32(br.bitpos)) & 1)
	br.bitpos += 1
	if br.bitpos == 8 {
		br.bitpos = 0
		br.pos += 1
	}
	return bit, true
}

br_read_bits :: proc(br: ^Bit_Reader, n: int) -> (val: u32, ok: bool) {
	for i in 0 ..< n {
		bit, o := br_read_bit(br)
		if !o {
			return 0, false
		}
		val |= bit << u32(i)
	}
	return val, true
}

br_align_byte :: proc(br: ^Bit_Reader) {
	if br.bitpos != 0 {
		br.bitpos = 0
		br.pos += 1
	}
}

// Reverse of fixed_lit_code: Huffman codes arrive MSB-first, so accumulate
// bit by bit and check the canonical ranges from RFC 1951 §3.2.6 after each
// bit -- 7-bit codes (256-279) are a strict prefix range of the 8/9-bit ones.
decode_fixed_litlen :: proc(br: ^Bit_Reader) -> (sym: int, ok: bool) {
	code := 0
	for nbits in 1 ..= 9 {
		bit, o := br_read_bit(br)
		if !o {
			return 0, false
		}
		code = (code << 1) | int(bit)
		if nbits == 7 && code <= 23 {
			return 256 + code, true
		}
		if nbits == 8 {
			if code >= 48 && code <= 191 {
				return code - 48, true
			}
			if code >= 192 && code <= 199 {
				return 280 + (code - 192), true
			}
		}
		if nbits == 9 && code >= 400 && code <= 511 {
			return 144 + (code - 400), true
		}
	}
	return 0, false
}

decode_fixed_dist :: proc(br: ^Bit_Reader) -> (code: int, ok: bool) {
	v := 0
	for i in 0 ..< 5 {
		bit, o := br_read_bit(br)
		if !o {
			return 0, false
		}
		v = (v << 1) | int(bit)
	}
	if v > 29 {
		return 0, false
	}
	return v, true
}

// Inflate supporting stored (BTYPE 00) and fixed Huffman (BTYPE 01) blocks
// -- dynamic Huffman (BTYPE 10) is unimplemented since deflate_fixed never
// emits it. Used only by verify_png, to decode this tool's own output.
inflate :: proc(data: []u8) -> (out: []u8, ok: bool) {
	br := Bit_Reader{data = data}
	result: [dynamic]u8

	for {
		final, o1 := br_read_bits(&br, 1)
		if !o1 {
			return nil, false
		}
		btype, o2 := br_read_bits(&br, 2)
		if !o2 {
			return nil, false
		}

		switch btype {
		case 0:
			br_align_byte(&br)
			if br.pos + 4 > len(data) {
				return nil, false
			}
			length := int(data[br.pos]) | int(data[br.pos + 1]) << 8
			nlen := int(data[br.pos + 2]) | int(data[br.pos + 3]) << 8
			if length != (~nlen & 0xFFFF) {
				return nil, false
			}
			br.pos += 4
			if br.pos + length > len(data) {
				return nil, false
			}
			append(&result, ..data[br.pos:br.pos + length])
			br.pos += length
		case 1:
			block_ok := false
			for {
				sym, sok := decode_fixed_litlen(&br)
				if !sok {
					return nil, false
				}
				if sym < 256 {
					append(&result, u8(sym))
				} else if sym == 256 {
					block_ok = true
					break
				} else {
					idx := sym - 257
					if idx < 0 || idx >= len(LENGTH_INFO) {
						return nil, false
					}
					extra, eok := br_read_bits(&br, LENGTH_INFO[idx].extra)
					if !eok {
						return nil, false
					}
					length := LENGTH_INFO[idx].base + int(extra)

					dcode, dok := decode_fixed_dist(&br)
					if !dok {
						return nil, false
					}
					dextra, deok := br_read_bits(&br, DISTANCE_INFO[dcode].extra)
					if !deok {
						return nil, false
					}
					dist := DISTANCE_INFO[dcode].base + int(dextra)

					if dist <= 0 || dist > len(result) {
						return nil, false
					}
					start := len(result) - dist
					for k in 0 ..< length {
						append(&result, result[start + k])
					}
				}
			}
			if !block_ok {
				return nil, false
			}
		case:
			return nil, false // dynamic Huffman: unimplemented, unused
		}

		if final == 1 {
			break
		}
	}

	return result[:], true
}

// ------------------------------------------------------------------- PNG

PNG_SIGNATURE :: [8]u8{0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A}

crc32_table: [256]u32
crc32_table_ready: bool

crc32 :: proc(data: []u8) -> u32 {
	if !crc32_table_ready {
		for n in 0 ..< 256 {
			c := u32(n)
			for k in 0 ..< 8 {
				if c & 1 != 0 {
					c = 0xEDB88320 ~ (c >> 1)
				} else {
					c = c >> 1
				}
			}
			crc32_table[n] = c
		}
		crc32_table_ready = true
	}
	crc: u32 = 0xFFFFFFFF
	for b in data {
		crc = crc32_table[(crc ~ u32(b)) & 0xFF] ~ (crc >> 8)
	}
	return crc ~ 0xFFFFFFFF
}

adler32 :: proc(data: []u8) -> u32 {
	a: u32 = 1
	b: u32 = 0
	MOD :: 65521
	for byte in data {
		a = (a + u32(byte)) % MOD
		b = (b + a) % MOD
	}
	return (b << 16) | a
}

// zlib stream (2-byte header + deflate stream + 4-byte Adler32), RFC 1950,
// with the deflate payload compressed via deflate_fixed (LZ77 + fixed
// Huffman) rather than stored uncompressed.
zlib_deflate :: proc(data: []u8) -> []u8 {
	out: [dynamic]u8
	append(&out, 0x78, 0x01) // CMF, FLG -- chosen so (CMF*256+FLG) % 31 == 0
	compressed := deflate_fixed(data)
	append(&out, ..compressed)
	delete(compressed)
	adler := adler32(data)
	dput_u32be(&out, adler)
	return out[:]
}

// Inverse of zlib_deflate: validates the 2-byte header's mod-31 checksum,
// inflates, and checks the trailing Adler-32 against the decompressed data.
zlib_inflate :: proc(zdata: []u8) -> (out: []u8, ok: bool) {
	if len(zdata) < 6 {
		return nil, false
	}
	cmf := zdata[0]
	flg := zdata[1]
	if (int(cmf) * 256 + int(flg)) % 31 != 0 {
		return nil, false
	}
	deflate_data := zdata[2:len(zdata) - 4]
	result, dok := inflate(deflate_data)
	if !dok {
		return nil, false
	}
	tail := zdata[len(zdata) - 4:]
	want_adler := u32(tail[0]) << 24 | u32(tail[1]) << 16 | u32(tail[2]) << 8 | u32(tail[3])
	if adler32(result) != want_adler {
		return nil, false
	}
	return result, true
}

append_chunk :: proc(out: ^[dynamic]u8, typ: string, data: []u8) {
	dput_u32be(out, u32(len(data)))
	start := len(out)
	for c in typ {
		append(out, u8(c))
	}
	if len(data) > 0 {
		append(out, ..data)
	}
	crc := crc32(out[start:])
	dput_u32be(out, crc)
}

// Whole PNG file: signature + IHDR + one IDAT + IEND. 8-bit RGBA. Each
// scanline gets its best-fit filter (filter_scanlines), then the filtered
// bytes are compressed for real (zlib_deflate) instead of stored raw.
png_encode :: proc(rgba: []u8, size: int) -> []u8 {
	raw := filter_scanlines(rgba, size)
	defer delete(raw)
	zdata := zlib_deflate(raw)

	out: [dynamic]u8
	sig := PNG_SIGNATURE
	append(&out, ..sig[:])

	ihdr: [13]u8
	ioff := 0
	put_u32be(ihdr[:], &ioff, u32(size)) // width
	put_u32be(ihdr[:], &ioff, u32(size)) // height
	ihdr[8] = 8 // bit depth
	ihdr[9] = 6 // colour type: RGBA
	ihdr[10] = 0 // compression method
	ihdr[11] = 0 // filter method
	ihdr[12] = 0 // interlace method
	append_chunk(&out, "IHDR", ihdr[:])
	append_chunk(&out, "IDAT", zdata)
	append_chunk(&out, "IEND", {})

	return out[:]
}

// Parses a PNG byte stream back apart: validates the signature, walks every
// chunk verifying its CRC32 against the bytes actually present, collects
// IDAT payloads (a real encoder may split IDAT across chunks; concatenation
// before zlib decoding is required by the PNG spec), and reads width/height
// from IHDR. Independent of png_encode's internals -- it only assumes the
// general PNG chunk format, not this tool's specific chunk ordering.
png_parse :: proc(png_bytes: []u8) -> (w, h: int, idat: []u8, ok: bool) {
	sig := PNG_SIGNATURE
	if len(png_bytes) < 8 {
		return 0, 0, nil, false
	}
	for i in 0 ..< 8 {
		if png_bytes[i] != sig[i] {
			return 0, 0, nil, false
		}
	}
	pos := 8
	idat_buf: [dynamic]u8
	for pos + 8 <= len(png_bytes) {
		length := int(
			u32(png_bytes[pos]) << 24 |
			u32(png_bytes[pos + 1]) << 16 |
			u32(png_bytes[pos + 2]) << 8 |
			u32(png_bytes[pos + 3]),
		)
		ctype := string(png_bytes[pos + 4:pos + 8])
		if pos + 8 + length + 4 > len(png_bytes) {
			return 0, 0, nil, false
		}
		chunk_data := png_bytes[pos + 8:pos + 8 + length]
		crc_stored :=
			u32(png_bytes[pos + 8 + length]) << 24 |
			u32(png_bytes[pos + 9 + length]) << 16 |
			u32(png_bytes[pos + 10 + length]) << 8 |
			u32(png_bytes[pos + 11 + length])
		crc_calc := crc32(png_bytes[pos + 4:pos + 8 + length]) // type + data
		if crc_calc != crc_stored {
			return 0, 0, nil, false
		}
		switch ctype {
		case "IHDR":
			if length < 8 {
				return 0, 0, nil, false
			}
			w = int(u32(chunk_data[0]) << 24 | u32(chunk_data[1]) << 16 | u32(chunk_data[2]) << 8 | u32(chunk_data[3]))
			h = int(u32(chunk_data[4]) << 24 | u32(chunk_data[5]) << 16 | u32(chunk_data[6]) << 8 | u32(chunk_data[7]))
		case "IDAT":
			append(&idat_buf, ..chunk_data)
		}
		pos += 8 + length + 4
		if ctype == "IEND" {
			break
		}
	}
	return w, h, idat_buf[:], true
}

// Round-trips a just-encoded PNG through this tool's own decoder (chunk
// CRCs, zlib Adler-32 and inflate, PNG un-filtering) and compares the
// result byte-for-byte against the source pixels. A malformed PNG loads
// silently-wrong in some viewers and not at all in others, so this is the
// check that keeps a broken deflate stream from ever reaching the .ico --
// see main() below, which treats a false return here as a build failure.
verify_png :: proc(png_bytes: []u8, size: int, orig_rgba: []u8) -> bool {
	w, h, idat, pok := png_parse(png_bytes)
	if !pok || w != size || h != size {
		return false
	}
	raw, zok := zlib_inflate(idat)
	if !zok {
		return false
	}
	rgba, uok := unfilter_scanlines(raw, size)
	if !uok {
		return false
	}
	if len(rgba) != len(orig_rgba) {
		return false
	}
	for i in 0 ..< len(rgba) {
		if rgba[i] != orig_rgba[i] {
			return false
		}
	}
	return true
}

// ------------------------------------------------------------------- main

main :: proc() {
	image_data: [len(SPECS)][]u8
	for i in 0 ..< len(SPECS) {
		spec := SPECS[i]
		rgba := render(spec)
		// See the header comment: PNG from 48px up. Every PNG written goes through
		// verify_png first, so a broken deflate stream fails the build rather than
		// shipping an icon Windows renders as nothing -- which matters more now
		// that six of the seven entries take that path instead of one.
		if spec.size >= ICO_PNG_FROM {
			png := png_encode(rgba, spec.size)
			if !verify_png(png, spec.size, rgba) {
				fmt.println("gen_icon: FAILED round-trip verification of the", spec.size, "px PNG -- refusing to write a possibly-corrupt icon")
				os.exit(1)
			}
			image_data[i] = png
		} else {
			image_data[i] = encode_bmp_entry(rgba, spec.size)
		}
	}

	out: [dynamic]u8
	dput_u16le(&out, 0) // reserved
	dput_u16le(&out, 1) // type: icon
	dput_u16le(&out, u16(len(SPECS)))

	header_and_entries := 6 + 16 * len(SPECS)
	offsets: [len(SPECS)]int
	off := header_and_entries
	for i in 0 ..< len(SPECS) {
		offsets[i] = off
		off += len(image_data[i])
	}

	for i in 0 ..< len(SPECS) {
		spec := SPECS[i]
		wh: u8 = 0 if spec.size >= 256 else u8(spec.size)
		append(&out, wh, wh, u8(0), u8(0))
		dput_u16le(&out, 1) // planes
		dput_u16le(&out, 32) // bit count
		dput_u32le(&out, u32(len(image_data[i])))
		dput_u32le(&out, u32(offsets[i]))
	}

	for i in 0 ..< len(SPECS) {
		append(&out, ..image_data[i])
	}

	path :: "src/platform/newtpad.ico"
	if os.write_entire_file(path, out[:]) != nil {
		fmt.println("gen_icon: FAILED to write", path)
		os.exit(1)
	}
	fmt.printfln("gen_icon: wrote %s (%d bytes, %d images)", path, len(out), len(SPECS))
}
