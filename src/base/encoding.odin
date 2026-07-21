// Layer: base — text encoding detection + decode to internal UTF-8.
// Pure (operates on byte slices); no platform, no COM. UTF-8 is Newtpad's
// internal representation; wide/UTF-16 is decoded at the seam.
package base

import "core:unicode/utf8"

Encoding :: enum {
	UTF8,
	UTF16LE,
	UTF16BE,
	CP1252, // Windows-1252, the Windows "ANSI" codepage
}

encoding_name :: proc(e: Encoding) -> string {
	switch e {
	case .UTF8:
		return "UTF-8"
	case .UTF16LE:
		return "UTF-16 LE"
	case .UTF16BE:
		return "UTF-16 BE"
	case .CP1252:
		return "Windows-1252"
	}
	return "?"
}

// How many bytes to sniff when there is no BOM. Enough to be confident without
// touching more than the first page of a multi-GB file.
SNIFF :: 4096

// Is `data` valid UTF-8? Used to tell UTF-8 from Windows-1252, which are
// indistinguishable by BOM (neither has one) but easy to separate structurally:
// CP1252's high bytes almost never form valid UTF-8 sequences.
@(private = "file")
looks_utf8 :: proc(data: []u8) -> bool {
	i := 0
	for i < len(data) {
		c := data[i]
		if c < 0x80 {
			i += 1
			continue
		}
		n := 0
		switch {
		case c >= 0xC2 && c <= 0xDF:
			n = 1
		case c >= 0xE0 && c <= 0xEF:
			n = 2
		case c >= 0xF0 && c <= 0xF4:
			n = 3
		case:
			return false // invalid lead byte (includes 0xC0/0xC1 overlongs)
		}
		if i + n >= len(data) {
			return true // truncated at the sniff boundary; don't judge on a partial
		}
		for k in 1 ..= n {
			if data[i + k] < 0x80 || data[i + k] > 0xBF {return false}
		}
		i += n + 1
	}
	return true
}

// Sniff the encoding. Returns it plus the BOM length to skip.
//
// Without a BOM there are three candidates and all three matter in practice:
// UTF-8 (the common case), UTF-16 (PowerShell's `>` redirection writes BOM-less
// UTF-16LE), and Windows-1252 (anything produced by older Windows tools). Getting
// this wrong is not cosmetic — a CP1252 file read as UTF-8 renders as garbage and
// is written back as garbage on save, corrupting the user's file.
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

	n := min(len(data), SNIFF)
	if n == 0 {
		return .UTF8, 0
	}
	head := data[:n]

	// BOM-less UTF-16: Latin text alternates a character byte with a NUL, so one
	// parity position is overwhelmingly NUL and the other almost never is. Plain
	// UTF-8 text has essentially no NULs at all.
	even_nul, odd_nul := 0, 0
	for b, i in head {
		if b == 0 {
			if i % 2 == 0 {even_nul += 1} else {odd_nul += 1}
		}
	}
	pairs := n / 2
	if pairs >= 8 {
		// >30% of one parity being NUL, and the other essentially clear.
		if odd_nul * 10 > pairs * 3 && even_nul * 20 < pairs {
			return .UTF16LE, 0 // "a\0b\0" — NULs in odd positions
		}
		if even_nul * 10 > pairs * 3 && odd_nul * 20 < pairs {
			return .UTF16BE, 0 // "\0a\0b" — NULs in even positions
		}
	}

	if looks_utf8(head) {
		return .UTF8, 0
	}
	// High bytes that aren't valid UTF-8: treat as the Windows codepage rather
	// than passing invalid bytes through as if they were text.
	return .CP1252, 0
}

// Line ending style. Newtpad stores text with whatever the file had; this is
// what it reports and what a conversion targets.
Line_Ending :: enum {
	LF, // Unix
	CRLF, // Windows
	Mixed, // both present — worth telling the user, since tools disagree about it
}

line_ending_name :: proc(e: Line_Ending) -> string {
	switch e {
	case .LF:
		return "LF"
	case .CRLF:
		return "CRLF"
	case .Mixed:
		return "Mixed"
	}
	return "?"
}

// Sniff line endings from the head of the buffer. Bounded, like encoding
// detection: a multi-GB file must not be scanned to report a status-bar field.
detect_line_ending :: proc(data: []u8) -> Line_Ending {
	n := min(len(data), SNIFF)
	crlf, lf := 0, 0
	for i in 0 ..< n {
		if data[i] != '\n' {continue}
		if i > 0 && data[i - 1] == '\r' {crlf += 1} else {lf += 1}
	}
	if crlf > 0 && lf > 0 {return .Mixed}
	if crlf > 0 {return .CRLF}
	return .LF // no newlines at all: LF is the harmless default
}

// Rewrite line endings. Returns a fresh buffer.
convert_line_endings :: proc(data: []u8, to: Line_Ending, allocator := context.allocator) -> []u8 {
	out := make([dynamic]u8, 0, len(data) + len(data) / 16, allocator)
	for i := 0; i < len(data); i += 1 {
		c := data[i]
		if c == '\r' {
			// Normalise CR and CRLF alike; a lone CR is treated as a line break.
			if i + 1 < len(data) && data[i + 1] == '\n' {i += 1}
			if to == .CRLF {append(&out, '\r')}
			append(&out, '\n')
			continue
		}
		if c == '\n' {
			if to == .CRLF {append(&out, '\r')}
			append(&out, '\n')
			continue
		}
		append(&out, c)
	}
	return out[:]
}

// Windows-1252 differs from Latin-1 only in 0x80..0x9F, where Latin-1 has unused
// control codes. Everything else maps to the same codepoint as its byte value.
@(private = "file")
CP1252_HIGH := [32]rune {
	0x20AC, 0x0081, 0x201A, 0x0192, 0x201E, 0x2026, 0x2020, 0x2021,
	0x02C6, 0x2030, 0x0160, 0x2039, 0x0152, 0x008D, 0x017D, 0x008F,
	0x0090, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014,
	0x02DC, 0x2122, 0x0161, 0x203A, 0x0153, 0x009D, 0x017E, 0x0178,
}

cp1252_to_rune :: proc(b: u8) -> rune {
	if b < 0x80 {return rune(b)}
	if b < 0xA0 {return CP1252_HIGH[b - 0x80]}
	return rune(b) // 0xA0..0xFF match Latin-1 / Unicode
}

// Reverse of cp1252_to_rune. ok=false when the character has no representation
// in the codepage, so the caller can warn instead of silently writing '?'.
rune_to_cp1252 :: proc(r: rune) -> (u8, bool) {
	if r < 0x80 {return u8(r), true}
	if r >= 0xA0 && r <= 0xFF {return u8(r), true}
	for h, i in CP1252_HIGH {
		if h == r {return u8(0x80 + i), true}
	}
	return '?', false
}

// How many runes in `data` (UTF-8) the target encoding cannot represent. Only
// the single-byte codepages can lose anything; UTF-8 and UTF-16 encode all of
// Unicode. rune_to_cp1252 has always reported this per character -- encoding a
// buffer just threw the answer away and wrote '?', so typing an em-dash or an
// emoji into a Windows-1252 file destroyed it on save and reported success.
encode_lossy_count :: proc(data: []u8, enc: Encoding) -> int {
	if enc != .CP1252 {return 0}
	n, i := 0, 0
	for i < len(data) {
		r, sz := utf8.decode_rune(data[i:])
		i += max(sz, 1)
		if _, ok := rune_to_cp1252(r); !ok {n += 1}
	}
	return n
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

	if enc == .CP1252 {
		// Every byte is one character, and the high half expands to 2-3 UTF-8
		// bytes, so reserve generously rather than growing repeatedly.
		buf := make([dynamic]u8, 0, len(body) + len(body) / 2, allocator)
		for b in body {
			bytes, n := utf8.encode_rune(cp1252_to_rune(b))
			append(&buf, ..bytes[:n])
		}
		return buf[:], true
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
// UTF-8 byte length of `buf` up to the last COMPLETE rune, so a streaming caller
// never splits a multi-byte character across chunks. Returns len(buf) when the
// final byte ends a whole rune (e.g. at EOF). Never 0 for a non-empty buffer that
// starts on a rune boundary.
utf8_complete_len :: proc(buf: []u8) -> int {
	n := len(buf)
	if n == 0 {return 0}
	i := n - 1
	for i > 0 && (buf[i] & 0xC0) == 0x80 {i -= 1} // back over continuation bytes
	size := 1
	switch {
	case buf[i] < 0x80:
		size = 1
	case buf[i] < 0xE0:
		size = 2
	case buf[i] < 0xF0:
		size = 3
	case:
		size = 4
	}
	return n if i + size <= n else i
}

// The BOM for `enc` (UTF-8 only when add_bom), written into `dst`; returns the
// byte count. Used to emit the BOM once before a streamed body.
encoding_bom :: proc(dst: []u8, enc: Encoding, add_bom: bool) -> int {
	switch enc {
	case .UTF8:
		if add_bom {dst[0], dst[1], dst[2] = 0xEF, 0xBB, 0xBF;return 3}
	case .UTF16LE:
		dst[0], dst[1] = 0xFF, 0xFE
		return 2
	case .UTF16BE:
		dst[0], dst[1] = 0xFE, 0xFF
		return 2
	case .CP1252:
	}
	return 0
}

// Encode UTF-8 `data` to `enc` with NO BOM — for streaming a large file chunk by
// chunk, the BOM written once up front by encoding_bom. `data` must end on a rune
// boundary (see utf8_complete_len). Freshly allocated; caller owns it.
encode_body_from_utf8 :: proc(data: []u8, enc: Encoding, allocator := context.allocator) -> []u8 {
	switch enc {
	case .UTF8:
		out := make([]u8, len(data), allocator)
		copy(out, data)
		return out
	case .CP1252:
		out := make([dynamic]u8, 0, len(data), allocator)
		i := 0
		for i < len(data) {
			r, sz := utf8.decode_rune(data[i:])
			i += max(sz, 1)
			b, _ := rune_to_cp1252(r)
			append(&out, b)
		}
		return out[:]
	case .UTF16LE, .UTF16BE:
		le := enc == .UTF16LE
		b := make([dynamic]u8, 0, len(data) * 2, allocator)
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
	return make([]u8, 0, allocator)
}

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

	if enc == .CP1252 {
		out := make([dynamic]u8, 0, len(data), allocator)
		i := 0
		for i < len(data) {
			r, sz := utf8.decode_rune(data[i:])
			i += max(sz, 1)
			b, _ := rune_to_cp1252(r) // unrepresentable characters become '?'
			append(&out, b)
		}
		return out[:]
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
