// Layer: platform — glyph atlas + ClearType text pipeline (D3D11 + DirectWrite).
// Rasterizes glyphs via the hand-declared DirectWrite bindings (dwrite.odin)
// into a shared coverage atlas, caches them, and draws cached glyphs as
// instanced quads with dual-source ClearType blending. COM stays in platform.
//
// Current scope (milestone): single font face, ASCII via GetGlyphIndices (a cmap
// lookup, NOT shaping). Shaping + font fallback (IDWriteTextAnalyzer) are the
// next milestone; keep the glyph-run construction fed by an explicit index list
// so shaping can replace the cmap path without reworking the raster/atlas.
// Atlas is grow-only for now; eviction is required before ship (project rule).
package platform

import "core:fmt"
import "core:mem"
import "core:unicode/utf8"
import d3d "vendor:directx/d3d11"
import win "core:sys/windows"

ATLAS_W :: 1024
ATLAS_H :: 1024
MAX_TEXT_INSTANCES :: 4096
MAX_FACES :: 8

// Primary font first, then per-codepoint fallbacks. Missing files are skipped.
@(private)
FALLBACK_FONTS := [?]struct {
	path: string,
	kind: FONT_FACE_TYPE,
	face: u32,
}{
	{"C:\\Windows\\Fonts\\consola.ttf", .TRUETYPE, 0}, // primary: code / Latin / Cyrillic / Greek
	{"C:\\Windows\\Fonts\\seguisym.ttf", .TRUETYPE, 0}, // symbols
	{"C:\\Windows\\Fonts\\msyh.ttc", .OPENTYPE_COLLECTION, 0}, // CJK (Microsoft YaHei)
	{"C:\\Windows\\Fonts\\segoeui.ttf", .TRUETYPE, 0}, // general Latin / misc
}

Glyph_Key :: struct {
	face:  u8,
	index: u16,
	px:    u16,
}

Glyph :: struct {
	uv_min, uv_max: [2]f32,
	w, h:           i32, // bitmap size, pixels
	left, top:      i32, // bearings from the pen's baseline origin (top is negative above baseline)
	advance:        f32, // pixels to advance the pen
}

Text_Instance :: struct {
	pos:    [2]f32,
	size:   [2]f32,
	color:  [4]f32,
	uv_min: [2]f32,
	uv_max: [2]f32,
}

Text :: struct {
	// DirectWrite fonts: [0] primary, [1..] fallbacks
	factory:    ^IFactory,
	faces:      [MAX_FACES]^IFontFace,
	units:      [MAX_FACES]f32, // designUnitsPerEm per face
	nfaces:     int,
	char_em:    f32, // primary 'x' advance as a fraction of em == one cell's width
	cell_cache: map[rune]u8, // codepoint -> monospace cells (0 combining / 1 / 2 wide)

	// atlas + cache
	atlas:     ^d3d.ITexture2D,
	atlas_srv: ^d3d.IShaderResourceView,
	pack_x:    i32,
	pack_y:    i32,
	shelf_h:   i32,
	cache:     map[Glyph_Key]Glyph,
	atlas_full: bool, // a glyph was dropped for want of space (see glyph_get)

	// pipeline
	vs:        ^d3d.IVertexShader,
	ps:        ^d3d.IPixelShader,
	layout:    ^d3d.IInputLayout,
	blend:     ^d3d.IBlendState,
	sampler:   ^d3d.ISamplerState,
	instances: ^d3d.IBuffer,
	constants: ^d3d.IBuffer,
}

@(private)
TEXT_HLSL := `
cbuffer Constants : register(b0) {
	float2 screen_size;
	float2 _pad;
};
Texture2D    atlas : register(t0);
SamplerState samp  : register(s0);

struct VSIn {
	float2 ipos   : IPOS;
	float2 isize  : ISIZE;
	float4 icolor : ICOLOR;
	float2 iuvmin : IUVMIN;
	float2 iuvmax : IUVMAX;
	uint   vid    : SV_VertexID;
};
struct VSOut {
	float4 pos   : SV_POSITION;
	float4 color : COLOR;
	float2 uv    : TEXCOORD;
};
VSOut vs_main(VSIn i) {
	float2 c = float2(i.vid & 1, (i.vid >> 1) & 1);
	float2 px = i.ipos + c * i.isize;
	float2 ndc = float2(px.x / screen_size.x * 2.0 - 1.0,
	                    1.0 - px.y / screen_size.y * 2.0);
	VSOut o;
	o.pos = float4(ndc, 0.0, 1.0);
	o.color = i.icolor;
	o.uv = lerp(i.iuvmin, i.iuvmax, c);
	return o;
}

struct PSOut {
	float4 color    : SV_Target0;
	float4 coverage : SV_Target1; // per-channel ClearType coverage (dual-source)
};
PSOut ps_main(VSOut i) {
	float3 cov = atlas.Sample(samp, i.uv).rgb;
	PSOut o;
	o.color = float4(i.color.rgb, 1.0);
	o.coverage = float4(cov * i.color.a, i.color.a);
	return o;
}
`

// Load the DirectWrite factory + font faces and compute the cell width. No D3D,
// so this can run headless (see the `celltest` mode). text_init calls it before
// building the GPU pipeline.
text_load_faces :: proc(t: ^Text) -> (ok: bool) {
	if hr := DWriteCreateFactory(.SHARED, &IID_IFactory, &t.factory); !win.SUCCEEDED(hr) {
		fmt.eprintfln("DWriteCreateFactory failed: 0x%X", u32(hr))
		return
	}
	for fdef in FALLBACK_FONTS {
		if t.nfaces >= MAX_FACES {
			break
		}
		wpath := win.utf8_to_wstring(fdef.path, context.temp_allocator)
		file: ^IFontFile
		if hr := t.factory->CreateFontFileReference(wpath, nil, &file); !win.SUCCEEDED(hr) {
			continue // font not present on this machine; skip
		}
		face: ^IFontFace
		if hr := t.factory->CreateFontFace(fdef.kind, 1, &file, fdef.face, .NONE, &face); !win.SUCCEEDED(hr) {
			file->Release()
			continue
		}
		file->Release() // the face keeps its own reference
		fm: FONT_METRICS
		face->GetMetrics(&fm)
		t.faces[t.nfaces] = face
		t.units[t.nfaces] = f32(fm.designUnitsPerEm)
		t.nfaces += 1
	}
	if t.nfaces == 0 {
		fmt.eprintln("text_load_faces: no fonts could be loaded")
		return
	}

	// One cell = the primary face's 'x' advance (Consolas is monospace). Stored as
	// a fraction of em so it scales with any pixel size.
	cp := u32('x')
	gi: u16
	t.faces[0]->GetGlyphIndices(&cp, 1, &gi)
	gm: GLYPH_METRICS
	idx := gi
	t.faces[0]->GetDesignGlyphMetrics(&idx, 1, &gm, win.BOOL(false))
	t.char_em = f32(gm.advanceWidth) / t.units[0]
	return true
}

text_init :: proc(gfx: ^Gfx) -> (t: Text, ok: bool) {
	if !text_load_faces(&t) {
		return
	}

	// --- atlas texture + SRV ---
	tex_desc := d3d.TEXTURE2D_DESC {
		Width      = ATLAS_W,
		Height     = ATLAS_H,
		MipLevels  = 1,
		ArraySize  = 1,
		Format     = .R8G8B8A8_UNORM,
		SampleDesc = {Count = 1},
		Usage      = .DEFAULT,
		BindFlags  = {.SHADER_RESOURCE},
	}
	if hr := gfx.device->CreateTexture2D(&tex_desc, nil, &t.atlas); !win.SUCCEEDED(hr) {
		fmt.eprintfln("CreateTexture2D(atlas) failed: 0x%X", u32(hr))
		return
	}
	if hr := gfx.device->CreateShaderResourceView((^d3d.IResource)(t.atlas), nil, &t.atlas_srv); !win.SUCCEEDED(hr) {
		fmt.eprintfln("CreateShaderResourceView(atlas) failed: 0x%X", u32(hr))
		return
	}

	// --- shaders + input layout ---
	vs_blob, vs_ok := compile_shader(TEXT_HLSL, "vs_main", "vs_5_0")
	if !vs_ok {
		return
	}
	defer vs_blob->Release()
	ps_blob, ps_ok := compile_shader(TEXT_HLSL, "ps_main", "ps_5_0")
	if !ps_ok {
		return
	}
	defer ps_blob->Release()

	if hr := gfx.device->CreateVertexShader(vs_blob->GetBufferPointer(), vs_blob->GetBufferSize(), nil, &t.vs); !win.SUCCEEDED(hr) {
		return
	}
	if hr := gfx.device->CreatePixelShader(ps_blob->GetBufferPointer(), ps_blob->GetBufferSize(), nil, &t.ps); !win.SUCCEEDED(hr) {
		return
	}

	layout := [?]d3d.INPUT_ELEMENT_DESC {
		{"IPOS", 0, .R32G32_FLOAT, 0, 0, .INSTANCE_DATA, 1},
		{"ISIZE", 0, .R32G32_FLOAT, 0, 8, .INSTANCE_DATA, 1},
		{"ICOLOR", 0, .R32G32B32A32_FLOAT, 0, 16, .INSTANCE_DATA, 1},
		{"IUVMIN", 0, .R32G32_FLOAT, 0, 32, .INSTANCE_DATA, 1},
		{"IUVMAX", 0, .R32G32_FLOAT, 0, 40, .INSTANCE_DATA, 1},
	}
	if hr := gfx.device->CreateInputLayout(raw_data(layout[:]), u32(len(layout)), vs_blob->GetBufferPointer(), vs_blob->GetBufferSize(), &t.layout); !win.SUCCEEDED(hr) {
		fmt.eprintfln("CreateInputLayout(text) failed: 0x%X", u32(hr))
		return
	}

	// --- dual-source ClearType blend: final = text*cov + dst*(1-cov) per channel ---
	blend_desc: d3d.BLEND_DESC
	rt := &blend_desc.RenderTarget[0]
	rt.BlendEnable = win.BOOL(true)
	rt.SrcBlend = .SRC1_COLOR
	rt.DestBlend = .INV_SRC1_COLOR
	rt.BlendOp = .ADD
	rt.SrcBlendAlpha = .SRC1_ALPHA
	rt.DestBlendAlpha = .INV_SRC1_ALPHA
	rt.BlendOpAlpha = .ADD
	rt.RenderTargetWriteMask = 0x0F
	if hr := gfx.device->CreateBlendState(&blend_desc, &t.blend); !win.SUCCEEDED(hr) {
		fmt.eprintfln("CreateBlendState failed: 0x%X", u32(hr))
		return
	}

	// --- point sampler (glyphs blit 1:1; clamp) ---
	samp_desc := d3d.SAMPLER_DESC {
		Filter   = .MIN_MAG_MIP_POINT,
		AddressU = .CLAMP,
		AddressV = .CLAMP,
		AddressW = .CLAMP,
		MaxLOD   = 3.402823466e+38,
	}
	if hr := gfx.device->CreateSamplerState(&samp_desc, &t.sampler); !win.SUCCEEDED(hr) {
		fmt.eprintfln("CreateSamplerState failed: 0x%X", u32(hr))
		return
	}

	// --- instance + constant buffers ---
	inst_desc := d3d.BUFFER_DESC {
		ByteWidth      = MAX_TEXT_INSTANCES * size_of(Text_Instance),
		Usage          = .DYNAMIC,
		BindFlags      = {.VERTEX_BUFFER},
		CPUAccessFlags = {.WRITE},
	}
	if hr := gfx.device->CreateBuffer(&inst_desc, nil, &t.instances); !win.SUCCEEDED(hr) {
		fmt.eprintfln("CreateBuffer(text instances) failed: 0x%X", u32(hr))
		return
	}
	const_desc := d3d.BUFFER_DESC {
		ByteWidth      = 16,
		Usage          = .DYNAMIC,
		BindFlags      = {.CONSTANT_BUFFER},
		CPUAccessFlags = {.WRITE},
	}
	if hr := gfx.device->CreateBuffer(&const_desc, nil, &t.constants); !win.SUCCEEDED(hr) {
		fmt.eprintfln("CreateBuffer(text constants) failed: 0x%X", u32(hr))
		return
	}

	return t, true
}

// Width of one grid cell at size px (the primary monospace 'x' advance), rounded
// to a whole pixel.
//
// Rounding here rather than in the caller is load-bearing. text_draw advances its
// pen by this same value, so column n's left edge is exactly n*cell_w for both
// the glyphs and everything the program positions against the grid — caret,
// selection rects, find highlights, hit-testing. A rounded cell width computed
// program-side while text_draw kept advancing by the raw fraction would drift the
// two apart by (cell_w - raw) per column: ~0.2px/col for Consolas at 16px, which
// is 400px of divergence by VISIBLE_COLS. Both sides must call this one proc.
// Guarded by `newtpad dpitest`.
text_char_width :: proc(t: ^Text, px: f32) -> f32 {
	return max(1, f32(int(t.char_em * px + 0.5)))
}

// Nonspacing combining marks and zero-width format characters. These need a
// codepoint check, not measured advance: monospace fonts (Consolas) give
// combining marks a FULL advance so they're visible standalone, so measuring
// can't detect them. Covers the common unambiguous blocks (decomposed accents,
// Hebrew niqqud, Arabic harakat, variation selectors, zero-width format); Indic
// spacing/nonspacing ambiguity is left to the deferred shaping work.
@(private = "file")
is_zero_width :: proc(r: rune) -> bool {
	switch r {
	case 0x00AD: // soft hyphen
		return true
	case 0x0300 ..= 0x036F, 0x0483 ..= 0x0489: // combining diacritical, Cyrillic
		return true
	case 0x0591 ..= 0x05BD, 0x05BF, 0x05C1, 0x05C2, 0x05C4, 0x05C5, 0x05C7: // Hebrew
		return true
	case 0x0610 ..= 0x061A, 0x064B ..= 0x065F, 0x0670: // Arabic harakat
		return true
	case 0x06D6 ..= 0x06DC, 0x06DF ..= 0x06E4, 0x06E7, 0x06E8, 0x06EA ..= 0x06ED: // Arabic
		return true
	case 0x0711, 0x0730 ..= 0x074A, 0x07A6 ..= 0x07B0: // Syriac, Thaana
		return true
	case 0x1AB0 ..= 0x1AFF, 0x1DC0 ..= 0x1DFF, 0x20D0 ..= 0x20FF: // combining supplements
		return true
	case 0x200B ..= 0x200F, 0x202A ..= 0x202E, 0x2060 ..= 0x206F: // zero-width / bidi format
		return true
	case 0xFE00 ..= 0xFE0F, 0xFE20 ..= 0xFE2F, 0xFEFF: // variation selectors, half marks, ZWNBSP
		return true
	}
	return false
}

// Monospace cells a codepoint occupies: 0 (combining / zero-width), 1 (normal),
// or 2 (wide / full-width CJK). Width 2 is decided by the glyph's real advance
// relative to one cell, so it matches whatever font renders it (no width tables);
// width 0 is decided by is_zero_width. Cached; the ratio is px-independent. Tabs
// are one cell for now (tab stops are a later feature).
// Cells a tab occupies. Fixed width, not true tab stops (which would advance to
// the next multiple and so need the column, which this per-rune call doesn't
// have). Predictable, and it beats the previous behaviour: one cell, rendered as
// a missing-glyph box because no font has a glyph for U+0009.
TAB_CELLS :: 4

text_cell_width :: proc(t: ^Text, r: rune) -> int {
	if r == '\t' {return TAB_CELLS}
	if c, found := t.cell_cache[r]; found {return int(c)}
	cells: u8 = 1
	if is_zero_width(r) {
		cells = 0
	} else {
		face, gi := rune_face(t, r)
		if gi != 0 {
			gm: GLYPH_METRICS
			idx := gi
			t.faces[face]->GetDesignGlyphMetrics(&idx, 1, &gm, win.BOOL(false))
			adv_em := f32(gm.advanceWidth) / t.units[face]
			if adv_em < 0.01 * t.char_em {
				cells = 0 // font reports zero advance
			} else if adv_em > 1.5 * t.char_em {
				cells = 2 // wide / full-width
			}
		}
	}
	t.cell_cache[r] = cells
	return int(cells)
}

// Total cells spanned by a UTF-8 slice (sum of per-rune cell widths).
text_cells :: proc(t: ^Text, s: []u8) -> int {
	col := 0
	for r in string(s) {col += text_cell_width(t, r)}
	return col
}

// Bytes of `s` that fill up to `target` cells, rounded to a rune boundary. Maps a
// click's cell column back to a byte offset (inverse of text_cells).
text_bytes_for_cells :: proc(t: ^Text, s: []u8, target: int) -> int {
	str := string(s)
	col, i := 0, 0
	for i < len(str) {
		r, w := utf8.decode_rune(str[i:])
		cw := text_cell_width(t, r)
		if col + cw > target {break} // target lands within this rune's cell span
		col += cw
		i += w
	}
	return i
}

// Pick the first loaded face that has a glyph for r; fall back to the primary
// (which renders .notdef) if none does. Per-codepoint fallback, no shaping.
@(private)
rune_face :: proc(t: ^Text, r: rune) -> (face: int, gi: u16) {
	cp := u32(r)
	for fi in 0 ..< t.nfaces {
		g: u16
		t.faces[fi]->GetGlyphIndices(&cp, 1, &g)
		if g != 0 {
			return fi, g
		}
	}
	g: u16
	t.faces[0]->GetGlyphIndices(&cp, 1, &g)
	return 0, g
}

// Draw a UTF-8 string with its baseline at (x, y), left-to-right.
text_draw :: proc(gfx: ^Gfx, t: ^Text, str: string, x, y, px: f32, color: [4]f32) {
	instances := make([dynamic]Text_Instance, 0, len(str))
	defer delete(instances)

	cell_w := text_char_width(t, px) // same rounded advance the program's grid uses
	pen := x
	for r in str {
		cells := text_cell_width(t, r)
		if r == '\t' {
			pen += f32(cells) * cell_w // whitespace: advance, draw nothing
			continue
		}
		face, gi := rune_face(t, r)
		g := glyph_get(gfx, t, face, gi, px)
		if g.w > 0 && g.h > 0 {
			// Combining marks (0 cells) sit over the previous cell, not after it.
			glyph_x := pen - cell_w if cells == 0 else pen
			append(&instances, Text_Instance {
				pos    = {glyph_x + f32(g.left), y + f32(g.top)},
				size   = {f32(g.w), f32(g.h)},
				color  = color,
				uv_min = g.uv_min,
				uv_max = g.uv_max,
			})
		}
		pen += f32(cells) * cell_w // grid advance, not the glyph's natural advance
	}
	if len(instances) == 0 {
		return
	}

	n := min(len(instances), MAX_TEXT_INSTANCES)
	ctx := gfx.ctx

	mapped: d3d.MAPPED_SUBRESOURCE
	if win.SUCCEEDED(ctx->Map((^d3d.IResource)(t.instances), 0, .WRITE_DISCARD, {}, &mapped)) {
		mem.copy(mapped.pData, raw_data(instances), n * size_of(Text_Instance))
		ctx->Unmap((^d3d.IResource)(t.instances), 0)
	}
	if win.SUCCEEDED(ctx->Map((^d3d.IResource)(t.constants), 0, .WRITE_DISCARD, {}, &mapped)) {
		screen := [2]f32{f32(gfx.width), f32(gfx.height)}
		mem.copy(mapped.pData, &screen, size_of(screen))
		ctx->Unmap((^d3d.IResource)(t.constants), 0)
	}

	stride := u32(size_of(Text_Instance))
	offset := u32(0)
	blend_factor := [4]f32{1, 1, 1, 1}
	ctx->OMSetBlendState(t.blend, &blend_factor, 0xFFFFFFFF)
	ctx->IASetInputLayout(t.layout)
	ctx->IASetPrimitiveTopology(.TRIANGLESTRIP)
	ctx->IASetVertexBuffers(0, 1, &t.instances, &stride, &offset)
	ctx->VSSetShader(t.vs, nil, 0)
	ctx->VSSetConstantBuffers(0, 1, &t.constants)
	ctx->PSSetShader(t.ps, nil, 0)
	ctx->PSSetShaderResources(0, 1, &t.atlas_srv)
	ctx->PSSetSamplers(0, 1, &t.sampler)
	ctx->DrawInstanced(4, u32(n), 0, 0)
}

@(private)
glyph_get :: proc(gfx: ^Gfx, t: ^Text, face: int, index: u16, px: f32) -> Glyph {
	key := Glyph_Key{u8(face), index, u16(px)}
	if g, found := t.cache[key]; found {
		return g
	}

	g: Glyph
	// advance from design metrics
	gm: GLYPH_METRICS
	idx := index
	t.faces[face]->GetDesignGlyphMetrics(&idx, 1, &gm, win.BOOL(false))
	g.advance = f32(gm.advanceWidth) * px / t.units[face]

	cov, gw, gh, left, top := glyph_rasterize(t, face, index, px)
	g.w = gw
	g.h = gh
	g.left = left
	g.top = top
	if cov != nil && gw > 0 && gh > 0 {
		rx, ry, packed := atlas_pack(t, gw, gh)
		if packed {
			// expand 3-channel ClearType coverage to RGBA for the atlas.
			rgba := make([]u8, int(gw * gh) * 4)
			defer delete(rgba)
			for i in 0 ..< int(gw * gh) {
				rgba[i * 4 + 0] = cov[i * 3 + 0]
				rgba[i * 4 + 1] = cov[i * 3 + 1]
				rgba[i * 4 + 2] = cov[i * 3 + 2]
				rgba[i * 4 + 3] = 255
			}
			box := d3d.BOX {
				left   = u32(rx),
				top    = u32(ry),
				front  = 0,
				right  = u32(rx + gw),
				bottom = u32(ry + gh),
				back   = 1,
			}
			gfx.ctx->UpdateSubresource((^d3d.IResource)(t.atlas), 0, &box, raw_data(rgba), u32(gw * 4), 0)
			g.uv_min = {f32(rx) / ATLAS_W, f32(ry) / ATLAS_H}
			g.uv_max = {f32(rx + gw) / ATLAS_W, f32(ry + gh) / ATLAS_H}
		} else {
			// Atlas full. Nothing to draw for this glyph, but do NOT cache that:
			// a cached miss makes the glyph invisible for the rest of the process
			// even after text_reset_atlas frees space. Flag it so the program can
			// say so — the pen still advances, so the silent failure looks like
			// holes punched in the user's file, with no way to tell why.
			t.atlas_full = true
			g.w, g.h = 0, 0
			if cov != nil {
				delete(cov)
			}
			return g
		}
	}
	if cov != nil {
		delete(cov)
	}
	t.cache[key] = g
	return g
}

// True once a glyph has been dropped for want of atlas space.
text_atlas_full :: proc(t: ^Text) -> bool {return t.atlas_full}

// Empty the atlas. Every cached glyph holds UVs into it, so the cache goes too.
// Used when the rasterization size changes wholesale (a DPI change): keeping
// entries rasterized for the old size would both mis-render and permanently
// consume the space the new size needs.
text_reset_atlas :: proc(t: ^Text) {
	clear(&t.cache)
	t.pack_x, t.pack_y, t.shelf_h = 0, 0, 0
	t.atlas_full = false
}

// Returns the 3-channel ClearType coverage (caller frees) and placement, with
// the run's baseline origin at (0,0) so left/top are pen-relative bearings.
@(private)
glyph_rasterize :: proc(t: ^Text, face: int, index: u16, px: f32) -> (cov: []u8, gw, gh, left, top: i32) {
	idx := index
	run := GLYPH_RUN {
		fontFace     = t.faces[face],
		fontEmSize   = px,
		glyphCount   = 1,
		glyphIndices = &idx,
		isSideways   = win.BOOL(false),
	}
	analysis: ^IGlyphRunAnalysis
	if hr := t.factory->CreateGlyphRunAnalysis(&run, 1.0, nil, .NATURAL, .NATURAL, 0, 0, &analysis); !win.SUCCEEDED(hr) {
		return
	}
	defer analysis->Release()

	b: win.RECT
	if hr := analysis->GetAlphaTextureBounds(.CLEARTYPE_3x1, &b); !win.SUCCEEDED(hr) {
		return
	}
	gw = b.right - b.left
	gh = b.bottom - b.top
	left = b.left
	top = b.top
	if gw <= 0 || gh <= 0 {
		return nil, 0, 0, left, top // whitespace: advance only
	}

	cov = make([]u8, int(gw * gh) * 3)
	if hr := analysis->CreateAlphaTexture(.CLEARTYPE_3x1, &b, raw_data(cov), u32(len(cov))); !win.SUCCEEDED(hr) {
		delete(cov)
		return nil, 0, 0, left, top
	}
	return
}

// Shelf packer: grow-only, no eviction yet. Returns ok=false when the atlas is
// full (caller then skips the glyph rather than writing out of bounds).
// Eviction / a second atlas page is a follow-up.
@(private)
atlas_pack :: proc(t: ^Text, w, h: i32) -> (x, y: i32, ok: bool) {
	PAD :: 1
	if t.pack_x + w + PAD > ATLAS_W {
		t.pack_x = 0
		t.pack_y += t.shelf_h + PAD
		t.shelf_h = 0
	}
	if t.pack_y + h > ATLAS_H {
		return 0, 0, false // atlas full
	}
	x = t.pack_x
	y = t.pack_y
	t.pack_x += w + PAD
	if h > t.shelf_h {
		t.shelf_h = h
	}
	return x, y, true
}
