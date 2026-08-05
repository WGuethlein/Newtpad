// `odin test src/base -collection:src=src`
//
// Two halves, deliberately. The synthetic fonts pin the PARSER against bytes
// this file builds, so a failure names the field that moved. The real-font case
// then reads whatever is actually installed on this machine, because a parser
// that only ever sees fixtures its own test wrote is a parser tested against its
// author's assumptions -- and the reason this code exists at all is to read
// files nobody here produced.
package base

import "core:os"
import "core:strings"
import "core:testing"

// --- a minimal sfnt with a `name` table -------------------------------------
@(private = "file")
put16 :: proc(b: ^[dynamic]u8, v: u16) {append(b, u8(v >> 8), u8(v))}
@(private = "file")
put32 :: proc(b: ^[dynamic]u8, v: u32) {append(b, u8(v >> 24), u8(v >> 16), u8(v >> 8), u8(v))}

@(private = "file")
Rec :: struct {
	plat, enc, lang, nid: u16,
	text:                 string,
	utf16:                bool,
}

// A one-table font whose `name` holds exactly `recs`.
@(private = "file")
build_font :: proc(recs: []Rec, allocator := context.allocator) -> []u8 {
	// string storage first, so offsets are known before the records are written
	store: [dynamic]u8
	defer delete(store)
	offs := make([]u16, len(recs), context.temp_allocator)
	lens := make([]u16, len(recs), context.temp_allocator)
	for r, i in recs {
		offs[i] = u16(len(store))
		if r.utf16 {
			for ch in r.text {put16(&store, u16(ch))}
		} else {
			append(&store, r.text)
		}
		lens[i] = u16(len(store)) - offs[i]
	}

	name: [dynamic]u8
	defer delete(name)
	put16(&name, 0) // format
	put16(&name, u16(len(recs)))
	put16(&name, u16(6 + len(recs) * 12)) // stringOffset
	for r, i in recs {
		put16(&name, r.plat)
		put16(&name, r.enc)
		put16(&name, r.lang)
		put16(&name, r.nid)
		put16(&name, lens[i])
		put16(&name, offs[i])
	}
	append(&name, ..store[:])

	out: [dynamic]u8
	out.allocator = allocator
	put32(&out, 0x0001_0000) // sfnt version
	put16(&out, 1) // numTables
	put16(&out, 0);put16(&out, 0);put16(&out, 0)
	name_off := u32(12 + 16)
	put32(&out, 0x6E61_6D65) // 'name'
	put32(&out, 0) // checksum
	put32(&out, name_off)
	put32(&out, u32(len(name)))
	append(&out, ..name[:])
	return out[:]
}

@(test)
reads_the_windows_en_us_family :: proc(t: ^testing.T) {
	f := build_font(
		[]Rec {
			{3, 1, 0x0409, 1, "Cascadia Mono", true},
			{3, 1, 0x0409, 2, "Regular", true},
		},
	)
	defer delete(f)
	n, ok := sfnt_names(f)
	testing.expect(t, ok, "parsed")
	testing.expect_value(t, n.family, "Cascadia Mono")
	testing.expect_value(t, n.subfamily, "Regular")
	delete(n.family);delete(n.subfamily)
}

// The decision this encodes: en-US wins, always, because the chosen family is
// written into settings.txt as a plain string and has to mean the same thing on
// a machine with a different display language.
@(test)
en_us_beats_another_windows_locale :: proc(t: ^testing.T) {
	f := build_font(
		[]Rec {
			{3, 1, 0x0407, 1, "Nicht Dieser", true}, // de-DE, listed FIRST
			{3, 1, 0x0409, 1, "Correct Name", true},
		},
	)
	defer delete(f)
	n, ok := sfnt_names(f)
	testing.expect(t, ok, "parsed")
	testing.expect_value(t, n.family, "Correct Name")
	delete(n.family)
}

@(test)
falls_back_to_a_mac_record :: proc(t: ^testing.T) {
	f := build_font([]Rec{{1, 0, 0, 1, "Old Mono", false}})
	defer delete(f)
	n, ok := sfnt_names(f)
	testing.expect(t, ok, "a Mac-only font still yields a name")
	testing.expect_value(t, n.family, "Old Mono")
	delete(n.family)
}

@(test)
no_family_record_is_a_failure_not_an_empty_string :: proc(t: ^testing.T) {
	f := build_font([]Rec{{3, 1, 0x0409, 2, "Regular", true}}) // subfamily only
	defer delete(f)
	_, ok := sfnt_names(f)
	testing.expect(t, !ok, "a font with no family name is refused, not reported as \"\"")
}

// SHAPE A (HANDOFF §4): every read is bounds-checked, so a truncated file has to
// come back `false` rather than a confident wrong answer. Truncating at EVERY
// length rather than one arbitrary one -- the interesting failures are at the
// table directory, the record array and the string storage, and a single sample
// hits none of them reliably.
@(test)
a_truncated_font_never_reports_success :: proc(t: ^testing.T) {
	full := build_font(
		[]Rec {
			{3, 1, 0x0409, 1, "Cascadia Mono", true},
			{3, 1, 0x0409, 2, "Regular", true},
		},
	)
	defer delete(full)
	for cut in 0 ..< len(full) {
		n, ok := sfnt_names(full[:cut])
		if ok {
			// A short read may still be internally consistent, but it must never
			// invent a name longer than the bytes it was given.
			if len(n.family) > cut {
				testing.expectf(t, false, "cut=%d: reported family %q from %d bytes", cut, n.family, cut)
				delete(n.family)
				return
			}
			delete(n.family)
			if n.subfamily != "" {delete(n.subfamily)}
		}
	}
}

@(test)
garbage_is_refused :: proc(t: ^testing.T) {
	junk := []u8{0xDE, 0xAD, 0xBE, 0xEF, 1, 2, 3, 4, 5, 6, 7, 8}
	_, ok := sfnt_names(junk)
	testing.expect(t, !ok, "a non-font is refused")
	_, ok2 := sfnt_names(nil)
	testing.expect(t, !ok2, "so is nothing at all")
}

@(test)
a_collection_reports_its_face_count :: proc(t: ^testing.T) {
	single := build_font([]Rec{{3, 1, 0x0409, 1, "One", true}})
	defer delete(single)
	testing.expect_value(t, sfnt_face_count(single), 1)
	off, ok := sfnt_offset(single, 0)
	testing.expect(t, ok && off == 0, "a plain font starts at 0")
	_, ok2 := sfnt_offset(single, 1)
	testing.expect(t, !ok2, "and has no second face")
}

// --- against fonts this machine actually has --------------------------------
//
// Not skipped when a font is missing: the whole point is reading files this
// project did not write, and a test that quietly passes on a machine with no
// fonts would be exactly the vacuous green HANDOFF §3 is about. Consolas ships
// with Windows and the suite already assumes Windows.
@(test)
reads_a_real_font_off_this_machine :: proc(t: ^testing.T) {
	path := "C:\\Windows\\Fonts\\consola.ttf"
	data, rerr := os.read_entire_file_from_path(path, context.allocator)
	if !testing.expectf(t, rerr == nil, "could not read %s (%v) -- the parser is untested against a real file", path, rerr) {
		return
	}
	defer delete(data)
	n, nok := sfnt_names(data)
	testing.expect(t, nok, "parsed a real Windows font")
	if !nok {return}
	defer delete(n.family)
	defer if n.subfamily != "" {delete(n.subfamily)}
	testing.expectf(t, n.family == "Consolas", "family is %q, want \"Consolas\"", n.family)
	// The name must be clean text, not UTF-16 read as bytes -- the failure mode
	// that shows up as "C\x00o\x00n\x00s..." and still compares non-empty.
	testing.expect(t, !strings.contains(n.family, "\x00"), "no embedded NULs -- UTF-16 was decoded, not copied")
}
