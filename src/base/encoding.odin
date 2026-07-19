// Layer: base — text encoding detection + decode to internal UTF-8.
// Pure (operates on byte slices); no platform, no COM. UTF-8 is Newtpad's
// internal representation; wide/UTF-16 is decoded at the seam.
package base

import "core:unicode/utf8"

Encoding :: enum {
	UTF8,    // also the fallback for BOM-less / ANSI (treated as UTF-8/Latin-ish bytes)
	UTF16LE,
	UTF16BE,
}

// Sniff a byte-order mark. Returns the encoding and the BOM length to skip.
detect_encoding :: proc(data: []u8) -> (enc: Encoding, bom_len: int) {
	if len(data) >= 3 && data[0] == 0xEF && data[1] == 0xBB && data[2] == 0xBF {
		return .UTF8, 3
	}
	if len(data) >= 2 && data[0] == 0xFF && data[1] == 0xFE {
		return .UTF16LE, 2
	}
	if len(data) >= 2 && data[0] == 0xFE && data[1] == 0xFF {
		return .UTF16BE, 2
	}
	return .UTF8, 0
}

// Decode to UTF-8. UTF-8 input returns the same bytes (BOM stripped), no copy
// (allocated=false). UTF-16 input is transcoded into a new UTF-8 buffer
// (allocated=true) — the caller owns it. Large multi-GB files are expected to be
// UTF-8/ASCII (the no-copy fast path); huge UTF-16 is rare and materialized.
decode_to_utf8 :: proc(data: []u8, enc: Encoding, bom_len: int, allocator := context.allocator) -> (out: []u8, allocated: bool) {
	body := data[bom_len:]
	if enc == .UTF8 {
		return body, false
	}

	buf := make([dynamic]u8, 0, len(body), allocator)
	i := 0
	for i + 1 < len(body) {
		unit: u16
		if enc == .UTF16LE {
			unit = u16(body[i]) | (u16(body[i + 1]) << 8)
		} else {
			unit = (u16(body[i]) << 8) | u16(body[i + 1])
		}
		i += 2

		r: rune
		if unit >= 0xD800 && unit <= 0xDBFF && i + 1 < len(body) {
			// high surrogate; combine with the following low surrogate
			low: u16
			if enc == .UTF16LE {
				low = u16(body[i]) | (u16(body[i + 1]) << 8)
			} else {
				low = (u16(body[i]) << 8) | u16(body[i + 1])
			}
			if low >= 0xDC00 && low <= 0xDFFF {
				r = rune(0x10000 + (u32(unit - 0xD800) << 10) + u32(low - 0xDC00))
				i += 2
			} else {
				r = rune(unit)
			}
		} else {
			r = rune(unit)
		}

		bytes, n := utf8.encode_rune(r)
		append(&buf, ..bytes[:n])
	}
	return buf[:], true
}

@(private = "file")
put_u16 :: proc(b: ^[dynamic]u8, u: u16, le: bool) {
	if le {
		append(b, u8(u), u8(u >> 8))
	} else {
		append(b, u8(u >> 8), u8(u))
	}
}

// Encode internal UTF-8 back to the given encoding for saving. UTF-8 returns the
// bytes (with a BOM prepended if add_bom); UTF-16 transcodes and always writes a
// BOM. Always returns a freshly-allocated buffer the caller owns.
encode_from_utf8 :: proc(data: []u8, enc: Encoding, add_bom: bool, allocator := context.allocator) -> []u8 {
	if enc == .UTF8 {
		if add_bom {
			out := make([]u8, len(data) + 3, allocator)
			out[0], out[1], out[2] = 0xEF, 0xBB, 0xBF
			copy(out[3:], data)
			return out
		}
		out := make([]u8, len(data), allocator)
		copy(out, data)
		return out
	}

	le := enc == .UTF16LE
	b := make([dynamic]u8, 0, len(data) * 2 + 2, allocator)
	put_u16(&b, 0xFEFF, le) // BOM
	i := 0
	for i < len(data) {
		r, sz := utf8.decode_rune(data[i:])
		i += max(sz, 1)
		if r <= 0xFFFF {
			put_u16(&b, u16(r), le)
		} else {
			v := u32(r) - 0x10000
			put_u16(&b, u16(0xD800 + (v >> 10)), le)
			put_u16(&b, u16(0xDC00 + (v & 0x3FF)), le)
		}
	}
	return b[:]
}
