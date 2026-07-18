// Layer: platform — hand-declared DirectWrite COM surface (Odin ships no
// dwrite bindings). Minimal: just enough to rasterize a glyph run into a
// ClearType coverage bitmap. Vtable method ORDER is load-bearing and positional
// — taken from the on-disk SDK dwrite.h (10.0.28000.0), NOT MS Learn (whose
// method tables are alphabetized and would silently call the wrong slot).
// Unused vtable slots are declared as rawptr placeholders to preserve offsets.
//
// SPIKE STATUS: this is the de-risking spike. It proves (a) the hand-declared
// vtables are correct (wrong order => crash) and (b) ClearType coverage looks
// right, before we build the atlas/packer/shader on top.
package platform

import "core:fmt"
import win "core:sys/windows"

foreign import dwrite_lib "system:dwrite.lib"

@(default_calling_convention = "system")
foreign dwrite_lib {
	DWriteCreateFactory :: proc(factoryType: FACTORY_TYPE, iid: ^win.GUID, factory: ^^IFactory) -> win.HRESULT ---
}

// b859ee5a-d838-4b5b-a2e8-1adc7d93db48
IID_IFactory := win.GUID{0xb859ee5a, 0xd838, 0x4b5b, {0xa2, 0xe8, 0x1a, 0xdc, 0x7d, 0x93, 0xdb, 0x48}}

FACTORY_TYPE :: enum i32 {
	SHARED   = 0,
	ISOLATED = 1,
}

FONT_FACE_TYPE :: enum i32 {
	CFF                 = 0,
	TRUETYPE            = 1,
	OPENTYPE_COLLECTION = 2,
	TYPE1               = 3,
	VECTOR              = 4,
	BITMAP              = 5,
	UNKNOWN             = 6,
	RAW_CFF             = 7,
}

FONT_SIMULATIONS :: enum u32 {
	NONE    = 0,
	BOLD    = 1,
	OBLIQUE = 2,
}

RENDERING_MODE :: enum i32 {
	DEFAULT           = 0,
	ALIASED           = 1,
	GDI_CLASSIC       = 2,
	GDI_NATURAL       = 3,
	NATURAL           = 4,
	NATURAL_SYMMETRIC = 5,
	OUTLINE           = 6,
}

MEASURING_MODE :: enum i32 {
	NATURAL     = 0,
	GDI_CLASSIC = 1,
	GDI_NATURAL = 2,
}

TEXTURE_TYPE :: enum i32 {
	ALIASED_1x1   = 0,
	CLEARTYPE_3x1 = 1,
}

GLYPH_OFFSET :: struct {
	advanceOffset:  f32,
	ascenderOffset: f32,
}

MATRIX :: struct {
	m11, m12, m21, m22, dx, dy: f32,
}

GLYPH_RUN :: struct {
	fontFace:      ^IFontFace,
	fontEmSize:    f32,
	glyphCount:    u32,
	glyphIndices:  [^]u16,
	glyphAdvances: [^]f32,
	glyphOffsets:  [^]GLYPH_OFFSET,
	isSideways:    win.BOOL,
	bidiLevel:     u32,
}

// --- COM interfaces (call via Odin's -> operator) ---

IUnknown_VTable :: struct {
	QueryInterface: proc "system" (this: rawptr, riid: ^win.GUID, ppv: ^rawptr) -> win.HRESULT,
	AddRef:         proc "system" (this: rawptr) -> u32,
	Release:        proc "system" (this: rawptr) -> u32,
}

IFontFile :: struct {
	using vtable: ^IFontFile_VTable,
}
IFontFile_VTable :: struct {
	using iunknown: IUnknown_VTable,
	// (remaining methods unused)
}

IFontFace :: struct {
	using vtable: ^IFontFace_VTable,
}
IFontFace_VTable :: struct {
	using iunknown:        IUnknown_VTable,
	GetType:               rawptr,
	GetFiles:              rawptr,
	GetIndex:              rawptr,
	GetSimulations:        rawptr,
	IsSymbolFont:          rawptr,
	GetMetrics:            rawptr,
	GetGlyphCount:         rawptr,
	GetDesignGlyphMetrics: rawptr,
	GetGlyphIndices:       proc "system" (this: ^IFontFace, codePoints: [^]u32, codePointCount: u32, glyphIndices: [^]u16) -> win.HRESULT,
	// (remaining methods unused)
}

IGlyphRunAnalysis :: struct {
	using vtable: ^IGlyphRunAnalysis_VTable,
}
IGlyphRunAnalysis_VTable :: struct {
	using iunknown:        IUnknown_VTable,
	GetAlphaTextureBounds: proc "system" (this: ^IGlyphRunAnalysis, textureType: TEXTURE_TYPE, textureBounds: ^win.RECT) -> win.HRESULT,
	CreateAlphaTexture:    proc "system" (this: ^IGlyphRunAnalysis, textureType: TEXTURE_TYPE, textureBounds: ^win.RECT, alphaValues: [^]u8, bufferSize: u32) -> win.HRESULT,
	GetAlphaBlendParams:   rawptr,
}

IFactory :: struct {
	using vtable: ^IFactory_VTable,
}
IFactory_VTable :: struct {
	using iunknown:                 IUnknown_VTable,
	GetSystemFontCollection:        rawptr,
	CreateCustomFontCollection:     rawptr,
	RegisterFontCollectionLoader:   rawptr,
	UnregisterFontCollectionLoader: rawptr,
	CreateFontFileReference:        proc "system" (this: ^IFactory, filePath: win.wstring, lastWriteTime: ^win.FILETIME, fontFile: ^^IFontFile) -> win.HRESULT,
	CreateCustomFontFileReference:  rawptr,
	CreateFontFace:                 proc "system" (this: ^IFactory, fontFaceType: FONT_FACE_TYPE, numberOfFiles: u32, fontFiles: ^^IFontFile, faceIndex: u32, fontFaceSimulationFlags: FONT_SIMULATIONS, fontFace: ^^IFontFace) -> win.HRESULT,
	CreateRenderingParams:          rawptr,
	CreateMonitorRenderingParams:   rawptr,
	CreateCustomRenderingParams:    rawptr,
	RegisterFontFileLoader:         rawptr,
	UnregisterFontFileLoader:       rawptr,
	CreateTextFormat:               rawptr,
	CreateTypography:               rawptr,
	GetGdiInterop:                  rawptr,
	CreateTextLayout:               rawptr,
	CreateGdiCompatibleTextLayout:  rawptr,
	CreateEllipsisTrimmingSign:     rawptr,
	CreateTextAnalyzer:             rawptr,
	CreateNumberSubstitution:       rawptr,
	CreateGlyphRunAnalysis:         proc "system" (this: ^IFactory, glyphRun: ^GLYPH_RUN, pixelsPerDip: f32, transform: ^MATRIX, renderingMode: RENDERING_MODE, measuringMode: MEASURING_MODE, baselineOriginX: f32, baselineOriginY: f32, glyphRunAnalysis: ^^IGlyphRunAnalysis) -> win.HRESULT,
}

// SPIKE: rasterize one glyph via DirectWrite and dump its ClearType coverage as
// ASCII art. Verifies the whole hand-declared COM chain end to end.
glyph_spike :: proc(codepoint: rune = 'A', em_size: f32 = 32) {
	factory: ^IFactory
	if hr := DWriteCreateFactory(.SHARED, &IID_IFactory, &factory); !win.SUCCEEDED(hr) {
		fmt.eprintfln("DWriteCreateFactory failed: 0x%X", u32(hr))
		return
	}
	defer factory->Release()

	font_path := win.utf8_to_wstring("C:\\Windows\\Fonts\\consola.ttf")
	font_file: ^IFontFile
	if hr := factory->CreateFontFileReference(font_path, nil, &font_file); !win.SUCCEEDED(hr) {
		fmt.eprintfln("CreateFontFileReference failed: 0x%X", u32(hr))
		return
	}
	defer font_file->Release()

	font_face: ^IFontFace
	if hr := factory->CreateFontFace(.TRUETYPE, 1, &font_file, 0, .NONE, &font_face); !win.SUCCEEDED(hr) {
		fmt.eprintfln("CreateFontFace failed: 0x%X", u32(hr))
		return
	}
	defer font_face->Release()

	cp := u32(codepoint)
	glyph_index: u16
	if hr := font_face->GetGlyphIndices(&cp, 1, &glyph_index); !win.SUCCEEDED(hr) {
		fmt.eprintfln("GetGlyphIndices failed: 0x%X", u32(hr))
		return
	}
	fmt.printfln("glyph index for %q = %d", codepoint, glyph_index)

	run := GLYPH_RUN {
		fontFace     = font_face,
		fontEmSize   = em_size,
		glyphCount   = 1,
		glyphIndices = &glyph_index,
		isSideways   = win.BOOL(false),
	}

	analysis: ^IGlyphRunAnalysis
	if hr := factory->CreateGlyphRunAnalysis(&run, 1.0, nil, .NATURAL, .NATURAL, 0, em_size, &analysis); !win.SUCCEEDED(hr) {
		fmt.eprintfln("CreateGlyphRunAnalysis failed: 0x%X", u32(hr))
		return
	}
	defer analysis->Release()

	bounds: win.RECT
	if hr := analysis->GetAlphaTextureBounds(.CLEARTYPE_3x1, &bounds); !win.SUCCEEDED(hr) {
		fmt.eprintfln("GetAlphaTextureBounds failed: 0x%X", u32(hr))
		return
	}
	w := int(bounds.right - bounds.left)
	h := int(bounds.bottom - bounds.top)
	fmt.printfln("bounds %dx%d  (L%d T%d R%d B%d)", w, h, bounds.left, bounds.top, bounds.right, bounds.bottom)
	if w <= 0 || h <= 0 {
		fmt.eprintln("empty glyph bounds")
		return
	}

	buf := make([]u8, w * h * 3) // CLEARTYPE_3x1 = 3 bytes/pixel
	defer delete(buf)
	if hr := analysis->CreateAlphaTexture(.CLEARTYPE_3x1, &bounds, raw_data(buf), u32(len(buf))); !win.SUCCEEDED(hr) {
		fmt.eprintfln("CreateAlphaTexture failed: 0x%X", u32(hr))
		return
	}

	ramp := " .:-=+*#%@"
	row := make([]u8, w)
	defer delete(row)
	fmt.println("--- coverage (avg of 3 ClearType channels) ---")
	for y in 0 ..< h {
		for x in 0 ..< w {
			i := (y * w + x) * 3
			cov := (int(buf[i]) + int(buf[i + 1]) + int(buf[i + 2])) / 3
			row[x] = ramp[cov * (len(ramp) - 1) / 255]
		}
		fmt.println(string(row))
	}
	fmt.println("--- end ---")
}
