// Layer: base — the one thing Newtpad needs to read out of a font FILE: its
// name.
//
// WHY THIS EXISTS RATHER THAN A DIRECTWRITE CALL. Font enumeration needs a
// family name per file. DirectWrite has one, through
// IDWriteFontCollection -> IDWriteFontFamily -> IDWriteLocalizedStrings, and
// getting from a family back to the file it lives in needs
// IDWriteFontFace -> GetFiles -> IDWriteFontFile -> GetLoader -> QueryInterface
// -> IDWriteLocalFontFileLoader -> GetFilePathFromKey. That is eight COM
// interfaces to bind by hand, in a project whose dwrite.odin binds four and
// leaves every unused vtable slot as `rawptr`.
//
// A hand-written vtable is not checked by the compiler. Miscount the slots and
// the program calls a different method with the wrong arguments — a crash if you
// are lucky, and silent nonsense if you are not. Eight interfaces of that, for a
// string that is sitting in a documented table in the file, is the wrong trade.
//
// The `name` table is stable, specified, and reads in about sixty lines. It is
// also PURE, so it is testable with `odin test` — which the COM route could
// never be.
package base

import "core:mem"
import "core:strings"

// Big-endian readers. sfnt is big-endian throughout; every multi-byte field
// below goes through these so no call site has to remember that.
@(private = "file")
be16 :: proc(b: []u8, off: int) -> (v: u16, ok: bool) {
	if off < 0 || off + 2 > len(b) {return 0, false}
	return u16(b[off]) << 8 | u16(b[off + 1]), true
}

@(private = "file")
be32 :: proc(b: []u8, off: int) -> (v: u32, ok: bool) {
	if off < 0 || off + 4 > len(b) {return 0, false}
	return u32(b[off]) << 24 | u32(b[off + 1]) << 16 | u32(b[off + 2]) << 8 | u32(b[off + 3]), true
}

// Where a font's tables start. A bare .ttf/.otf starts at 0; a .ttc is a
// collection whose header points at several, and `index` picks one.
//
// Returned rather than assumed, because the fallback chain already loads a .ttc
// (msyh.ttc) and a scan that assumed offset 0 would read its header as a table
// directory and produce garbage rather than an error.
sfnt_offset :: proc(data: []u8, index := 0) -> (off: int, ok: bool) {
	tag, got := be32(data, 0)
	if !got {return 0, false}
	if tag != 0x7474_6366 {return 0, index == 0} // not 'ttcf': a single font
	n, nok := be32(data, 8)
	if !nok || index < 0 || u32(index) >= n {return 0, false}
	o, ook := be32(data, 12 + index * 4)
	if !ook {return 0, false}
	return int(o), true
}

// How many fonts a file holds. 1 for a plain .ttf/.otf.
sfnt_face_count :: proc(data: []u8) -> int {
	tag, got := be32(data, 0)
	if !got {return 0}
	if tag != 0x7474_6366 {return 1}
	n, nok := be32(data, 8)
	if !nok {return 0}
	return int(n)
}

@(private = "file")
find_table :: proc(data: []u8, base_off: int, want: u32) -> (off, length: int, ok: bool) {
	num, nok := be16(data, base_off + 4)
	if !nok {return 0, 0, false}
	for i in 0 ..< int(num) {
		rec := base_off + 12 + i * 16
		tag, tok := be32(data, rec)
		if !tok {return 0, 0, false}
		if tag != want {continue}
		o, ook := be32(data, rec + 8)
		l, lok := be32(data, rec + 12)
		if !ook || !lok {return 0, 0, false}
		if int(o) > len(data) || int(o) + int(l) > len(data) {return 0, 0, false}
		return int(o), int(l), true
	}
	return 0, 0, false
}

Sfnt_Names :: struct {
	family:    string, // nameID 1
	subfamily: string, // nameID 2 -- "Regular", "Bold", "Bold Italic", ...
}

// The en-US family and subfamily, allocated in `allocator`.
//
// EN-US SPECIFICALLY, and only en-US (Wyatt's call, 2026-08-04): the chosen
// family is stored in settings.txt as a plain string, so the name shown and the
// name written have to be the same one on every machine. A localized name would
// make a settings file locale-bound -- change the Windows display language and
// the setting silently stops resolving, which is the failure the keys.txt "+"
// alias exists to prevent one layer up.
//
// Windows platform records (platformID 3) are UTF-16BE. Records for platformID 1
// (Macintosh, single-byte) are accepted as a fallback because a few older
// monospace faces ship Mac records only.
sfnt_names :: proc(data: []u8, index := 0, allocator := context.allocator) -> (out: Sfnt_Names, ok: bool) {
	base_off, bok := sfnt_offset(data, index)
	if !bok {return {}, false}
	tbl, tlen, found := find_table(data, base_off, 0x6E61_6D65) // 'name'
	if !found || tlen < 6 {return {}, false}

	count, cok := be16(data, tbl + 2)
	str_off, sok := be16(data, tbl + 4)
	if !cok || !sok {return {}, false}
	strings_base := tbl + int(str_off)

	// Best record per name id. A font carries the same id several times over
	// different platforms, and the Windows/en-US one is preferred where present.
	best_family, best_sub := -1, -1
	best_family_rank, best_sub_rank := -1, -1
	for i in 0 ..< int(count) {
		rec := tbl + 6 + i * 12
		plat, pok := be16(data, rec)
		enc, eok := be16(data, rec + 2)
		lang, lok := be16(data, rec + 4)
		nid, nok := be16(data, rec + 6)
		if !pok || !eok || !lok || !nok {break}
		if nid != 1 && nid != 2 {continue}

		// Rank: Windows/en-US beats Windows/any beats Mac/English.
		rank := -1
		switch {
		case plat == 3 && lang == 0x0409:
			rank = 3
		case plat == 3:
			rank = 2
		case plat == 1 && lang == 0:
			rank = 1
		}
		if rank < 0 {continue}
		if nid == 1 && rank > best_family_rank {best_family, best_family_rank = rec, rank}
		if nid == 2 && rank > best_sub_rank {best_sub, best_sub_rank = rec, rank}
		_ = enc
	}
	if best_family < 0 {return {}, false}

	decode :: proc(data: []u8, rec, strings_base: int, allocator: mem.Allocator) -> string {
		plat, _ := be16(data, rec)
		slen, lok := be16(data, rec + 8)
		soff, ook := be16(data, rec + 10)
		if !lok || !ook {return ""}
		start := strings_base + int(soff)
		end := start + int(slen)
		if start < 0 || end > len(data) || start > end {return ""}
		raw := data[start:end]
		if plat == 3 {
			// UTF-16BE. Only the BMP matters for a family name, and a lone
			// surrogate is dropped rather than emitted as a replacement run.
			b := strings.builder_make(allocator)
			for i := 0; i + 1 < len(raw); i += 2 {
				r := rune(u16(raw[i]) << 8 | u16(raw[i + 1]))
				if r >= 0xD800 && r <= 0xDFFF {continue}
				strings.write_rune(&b, r)
			}
			return strings.to_string(b)
		}
		return strings.clone(string(raw), allocator)
	}

	out.family = decode(data, best_family, strings_base, allocator)
	if best_sub >= 0 {out.subfamily = decode(data, best_sub, strings_base, allocator)}
	if out.family == "" {return {}, false}
	return out, true
}
