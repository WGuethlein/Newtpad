// Layer: platform — find every monospaced font installed on this machine.
//
// Wyatt, 2026-08-04: enumerate off-thread, exclude symbol charsets, merge with
// the curated table so known families keep their exact style files.
//
// WHAT THIS DOES NOT USE: IDWriteFontCollection. See base/sfnt.odin's header for
// why — the collection route needs eight hand-bound COM interfaces to get from a
// family back to the file it lives in, and a hand-written vtable is not checked
// by the compiler. This walks the two font directories instead and asks each
// file what it is, through the four DirectWrite methods dwrite.odin already binds
// and text.odin already relies on for every glyph it draws.
//
// The monospace test is therefore a MEASUREMENT rather than a flag. DirectWrite
// exposes IsMonospacedFont on IDWriteFont1 — a ninth interface — and its answer
// is the font's own claim about itself. Measuring advances instead is both
// cheaper to reach from here and stricter: it is the property the editor's cell
// grid actually depends on, and a font that lies about being monospaced would
// wreck that grid no matter what its flag said.
package platform

import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:strings"
import base "src:base"
import win "core:sys/windows"

// Codepoints every offered family must have, at one shared advance.
//
// This is the symbol-font filter AND the monospace test in one pass, which is
// why it is a set of ordinary characters rather than a charset query. Marlett,
// Wingdings and the AutoCAD shape fonts fail it twice over: their advances vary,
// and several of these codepoints have no glyph at all.
//
// It is NOT a "must cover Latin" rule, and the difference matters. Requiring
// Latin coverage would exclude the CJK monospace faces (Sarasa Mono, Noto Sans
// Mono CJK, MS Gothic) that Wyatt wants offerable later, and text_cell_width_at
// already returns width 2 for full-width cells, so the grid can take them. What
// is required is that the face draws TEXT -- and a CJK mono face has ASCII at one
// advance, because that is what makes it a mono face.
@(private = "file")
PROBE := [?]rune{'x', 'M', 'i', '0', '.', 'W'}

// What font_scan found, once the caller has published it.
//
// PUBLISHED FROM THE MAIN THREAD, not written by the worker: the worker hands its
// slice to `program`, which calls font_scan_publish while building the font list.
// So this has exactly one writer and every reader is on the same thread as it --
// which is what lets find_family below read it with no atomic at all.
//
// It exists because find_family is the ONE place a family name becomes files, and
// a scanned family that could not be found there would fall back to
// FONT_FAMILIES[0]: pick "Berkeley Mono" from the list and silently get Consolas.
@(private)
g_scanned: []Scanned_Family

font_scan_publish :: proc(f: []Scanned_Family) {g_scanned = f}

// A family found on disk, before it is merged with the curated table.
Scanned_Family :: struct {
	name:                              string, // en-US, from the file's own name table
	regular, bold, italic, bolditalic: string, // absolute paths
	// Face index per slot. A .ttc holds several fonts at one path, so the path
	// alone does not identify one -- simsun.ttc carries both SimSun and NSimSun.
	idx:                               [4]u32,
}

@(private = "file")
subfamily_slot :: proc(sub: string) -> (bold, italic: bool) {
	s := strings.to_lower(sub, context.temp_allocator)
	// "Bold Italic", "BoldOblique", "Italic", "Oblique", "Regular", "Book", ...
	bold = strings.contains(s, "bold")
	italic = strings.contains(s, "italic") || strings.contains(s, "oblique")
	return
}

// Is this face monospaced, and does it draw text at all?
//
// Takes an already-built face so the caller controls COM lifetime; returns false
// for anything it cannot measure, because "I could not tell" and "it is not
// monospaced" have the same consequence for the cell grid.
@(private = "file")
face_is_mono :: proc(face: ^IFontFace, units: f32) -> bool {
	if units <= 0 {return false}
	cps: [len(PROBE)]u32
	for r, i in PROBE {cps[i] = u32(r)}
	gis: [len(PROBE)]u16
	if hr := face->GetGlyphIndices(&cps[0], u32(len(cps)), &gis[0]); !win.SUCCEEDED(hr) {return false}
	// Glyph 0 is .notdef. A face missing any of these is not offering text.
	for g in gis {
		if g == 0 {return false}
	}
	gms: [len(PROBE)]GLYPH_METRICS
	if hr := face->GetDesignGlyphMetrics(&gis[0], u32(len(gis)), &gms[0], win.BOOL(false)); !win.SUCCEEDED(hr) {return false}
	first := gms[0].advanceWidth
	if first == 0 {return false}
	for gm in gms[1:] {
		if gm.advanceWidth != first {return false}
	}
	return true
}

// Every monospaced family in the system and per-user font directories.
//
// PURE OF UI and safe to run off the main thread: it touches the filesystem and
// DirectWrite face creation, allocates only into `allocator`, and writes no
// global. It does need its OWN IFactory -- COM objects are not free to share
// across threads without marshalling, and borrowing the Text's factory is
// exactly the kind of quiet cross-thread reach that turns into a rare crash.
font_scan :: proc(allocator := context.allocator) -> []Scanned_Family {
	factory: ^IFactory
	if hr := DWriteCreateFactory(.SHARED, &IID_IFactory, &factory); !win.SUCCEEDED(hr) {return nil}
	defer factory->Release()

	found: map[string]Scanned_Family
	defer delete(found)

	scan_dir :: proc(factory: ^IFactory, dir: string, found: ^map[string]Scanned_Family, allocator: mem.Allocator) {
		if dir == "" {return}
		// The path list outlives the per-file temp reset below, so it CANNOT live in
		// temp memory itself.
		fis, err := filepath.glob(strings.concatenate({dir, "*"}, context.temp_allocator), context.allocator)
		if err != nil {return}
		defer {
			for f in fis {delete(f)}
			delete(fis)
		}
		for path in fis {
			// PER FILE, not per scan. Every font on the machine is read whole to get
			// its name, and %SystemRoot%\Fonts is 431 MB across 671 files on the
			// machine this was written on. Without this the worker's temp arena grows
			// to the total size of every font installed -- a 1.4 MB program briefly
			// holding 400+ MB, off-thread where nothing would notice.
			//
			// CLAUDE.md pairs the heap with one free_all per FRAME; a worker has no
			// frame, so the loop iteration is the unit.
			defer free_all(context.temp_allocator)
			ext := strings.to_lower(filepath.ext(path), context.temp_allocator)
			if ext != ".ttf" && ext != ".otf" && ext != ".ttc" {continue}
			data, rerr := os.read_entire_file_from_path(path, context.temp_allocator)
			if rerr != nil {continue}

			n_faces := base.sfnt_face_count(data)
			for fi in 0 ..< n_faces {
				names, nok := base.sfnt_names(data, fi, context.temp_allocator)
				if !nok || names.family == "" {continue}

				// Build the face to measure it. A .ttc needs its collection type
				// or CreateFontFace refuses it.
				kind := FONT_FACE_TYPE.OPENTYPE_COLLECTION if ext == ".ttc" else (FONT_FACE_TYPE.CFF if ext == ".otf" else FONT_FACE_TYPE.TRUETYPE)
				wpath := win.utf8_to_wstring(path, context.temp_allocator)
				file: ^IFontFile
				if hr := factory->CreateFontFileReference(wpath, nil, &file); !win.SUCCEEDED(hr) {continue}
				face: ^IFontFace
				hr2 := factory->CreateFontFace(kind, 1, &file, u32(fi), .NONE, &face)
				file->Release()
				if !win.SUCCEEDED(hr2) {continue}
				fm: FONT_METRICS
				face->GetMetrics(&fm)
				mono := face_is_mono(face, f32(fm.designUnitsPerEm))
				face->Release()
				if !mono {continue}

				bold, italic := subfamily_slot(names.subfamily)
				e, seen := found[names.family]
				if !seen {
					e.name = strings.clone(names.family, allocator)
				}
				p := strings.clone(path, allocator)
				switch {
				case bold && italic:
					if e.bolditalic == "" {e.bolditalic, e.idx[3] = p, u32(fi)}
				case bold:
					if e.bold == "" {e.bold, e.idx[1] = p, u32(fi)}
				case italic:
					if e.italic == "" {e.italic, e.idx[2] = p, u32(fi)}
				case:
					if e.regular == "" {e.regular, e.idx[0] = p, u32(fi)}
				}
				found[e.name] = e
			}
		}
	}

	scan_dir(factory, fonts_dir(), &found, allocator)
	scan_dir(factory, fonts_dir_user(), &found, allocator)

	// A family with no regular face is not offerable: font_style_file falls back
	// to `regular` for every style, and text_load_family gives up when that file
	// will not load. Dropping it here is better than offering a choice that
	// silently does nothing when picked.
	out := make([dynamic]Scanned_Family, 0, len(found), allocator)
	for _, e in found {
		if e.regular == "" {continue}
		append(&out, e)
	}
	return out[:]
}
