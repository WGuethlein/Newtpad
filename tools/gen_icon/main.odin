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
// Two blob shapes are legal per entry (rule 3 of the batch-17 spec picks one
// per size): a BMP (BITMAPINFOHEADER + XOR color data + AND mask, no file
// header -- unlike a standalone .bmp, an icon's DIB has no BITMAPFILEHEADER)
// or a complete PNG file. We use BMP for 16..64 (uncompressed, matches "the
// smaller sizes as uncompressed BGRA") and PNG for 256 (the standard choice
// for icon sizes >= 256, and the one size where a raw 256*256*4-byte BMP
// blob would be wasteful).
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
// (colour type 6), no interlacing. The IDAT payload is a zlib stream built
// from "stored" (uncompressed) deflate blocks -- valid per RFC 1950/1951,
// just not compressed. That is a deliberate simplification: a real Huffman
// deflate is a lot of code for one 256x256 image (~262 KB raw, well under
// any icon-cache size limit Windows enforces), and PNG readers do not care
// how well the stream compressed, only that it decodes correctly.
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

// zlib stream (2-byte header + deflate stream + 4-byte Adler32) built from
// uncompressed ("stored") deflate blocks, RFC 1951 §3.2.4. Valid deflate,
// just not compressed -- see the file header comment for why that is fine
// here.
zlib_stored :: proc(data: []u8) -> []u8 {
	out: [dynamic]u8
	append(&out, 0x78, 0x01) // CMF, FLG -- chosen so (CMF*256+FLG) % 31 == 0

	i := 0
	for {
		remain := len(data) - i
		chunk := min(remain, 65535)
		final: u8 = 1 if i + chunk >= len(data) else 0
		// The 3-bit block header (BFINAL, BTYPE=00) fits in the low bits of
		// one byte; a stored block is then required to be byte-aligned, so
		// the rest of this byte is padding zero and nothing else is needed.
		append(&out, final)
		dput_u16le(&out, u16(chunk))
		dput_u16le(&out, ~u16(chunk))
		if chunk > 0 {
			append(&out, ..data[i:i + chunk])
		}
		i += chunk
		if i >= len(data) {
			break
		}
	}

	adler := adler32(data)
	dput_u32be(&out, adler)
	return out[:]
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

// Whole PNG file: signature + IHDR + one IDAT + IEND. 8-bit RGBA, filter
// type 0 (None) on every scanline -- simplest correct choice; filtering for
// better compression would matter for a photo, not a few flat rectangles.
png_encode :: proc(rgba: []u8, size: int) -> []u8 {
	raw := make([]u8, size * (1 + size * 4))
	pos := 0
	for row in 0 ..< size {
		raw[pos] = 0 // filter type: None
		pos += 1
		copy(raw[pos:pos + size * 4], rgba[row * size * 4:row * size * 4 + size * 4])
		pos += size * 4
	}
	zdata := zlib_stored(raw)

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

// ------------------------------------------------------------------- main

main :: proc() {
	image_data: [len(SPECS)][]u8
	for i in 0 ..< len(SPECS) {
		spec := SPECS[i]
		rgba := render(spec)
		if spec.size >= 256 {
			image_data[i] = png_encode(rgba, spec.size)
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
