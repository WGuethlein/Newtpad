// Layer: platform — glyph atlas + ClearType text pipeline (D3D11 + DirectWrite).
// Rasterizes glyphs via the hand-declared DirectWrite bindings (dwrite.odin)
// into a shared coverage atlas, caches them, and draws cached glyphs as
// instanced quads with dual-source ClearType blending. COM stays in platform.
//
// Current scope (milestone): single font face, ASCII via GetGlyphIndices (a cmap
// lookup, NOT shaping). Shaping + font fallback (IDWriteTextAnalyzer) are the
// next milestone; keep the glyph-run construction fed by an explicit index list
// so shaping can replace the cmap path without reworking the raster/atlas.
// Atlas is grow-only for now; eviction is required before ship (PROJECT-RULES rule).
package platform

import "core:fmt"
import "core:mem"
import d3d "vendor:directx/d3d11"
import win "core:sys/windows"

ATLAS_W :: 1024
ATLAS_H :: 1024
MAX_TEXT_INSTANCES :: 4096

Glyph_Key :: struct {
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
	// DirectWrite font
	factory:      ^IFactory,
	file:         ^IFontFile,
	face:         ^IFontFace,
	units_per_em: f32,
	ascent_du:    f32, // ascent in design units (scale by px/units_per_em)
	descent_du:   f32,

	// atlas + cache
	atlas:     ^d3d.ITexture2D,
	atlas_srv: ^d3d.IShaderResourceView,
	pack_x:    i32,
	pack_y:    i32,
	shelf_h:   i32,
	cache:     map[Glyph_Key]Glyph,

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

text_init :: proc(gfx: ^Gfx) -> (t: Text, ok: bool) {
	// --- font ---
	if hr := DWriteCreateFactory(.SHARED, &IID_IFactory, &t.factory); !win.SUCCEEDED(hr) {
		fmt.eprintfln("DWriteCreateFactory failed: 0x%X", u32(hr))
		return
	}
	font_path := win.utf8_to_wstring("C:\\Windows\\Fonts\\consola.ttf")
	if hr := t.factory->CreateFontFileReference(font_path, nil, &t.file); !win.SUCCEEDED(hr) {
		fmt.eprintfln("CreateFontFileReference failed: 0x%X", u32(hr))
		return
	}
	if hr := t.factory->CreateFontFace(.TRUETYPE, 1, &t.file, 0, .NONE, &t.face); !win.SUCCEEDED(hr) {
		fmt.eprintfln("CreateFontFace failed: 0x%X", u32(hr))
		return
	}
	fm: FONT_METRICS
	t.face->GetMetrics(&fm)
	t.units_per_em = f32(fm.designUnitsPerEm)
	t.ascent_du = f32(fm.ascent)
	t.descent_du = f32(fm.descent)

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

// Draw a UTF-8 string with its baseline at (x, y), left-to-right.
text_draw :: proc(gfx: ^Gfx, t: ^Text, str: string, x, y, px: f32, color: [4]f32) {
	instances := make([dynamic]Text_Instance, 0, len(str))
	defer delete(instances)

	pen := x
	for r in str {
		cp := u32(r)
		gi: u16
		t.face->GetGlyphIndices(&cp, 1, &gi)
		g := glyph_get(gfx, t, gi, px)
		if g.w > 0 && g.h > 0 {
			append(&instances, Text_Instance {
				pos    = {pen + f32(g.left), y + f32(g.top)},
				size   = {f32(g.w), f32(g.h)},
				color  = color,
				uv_min = g.uv_min,
				uv_max = g.uv_max,
			})
		}
		pen += g.advance
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
glyph_get :: proc(gfx: ^Gfx, t: ^Text, index: u16, px: f32) -> Glyph {
	key := Glyph_Key{index, u16(px)}
	if g, found := t.cache[key]; found {
		return g
	}

	g: Glyph
	// advance from design metrics
	gm: GLYPH_METRICS
	idx := index
	t.face->GetDesignGlyphMetrics(&idx, 1, &gm, win.BOOL(false))
	g.advance = f32(gm.advanceWidth) * px / t.units_per_em

	cov, gw, gh, left, top := glyph_rasterize(t, index, px)
	g.w = gw
	g.h = gh
	g.left = left
	g.top = top
	if cov != nil && gw > 0 && gh > 0 {
		rx, ry := atlas_pack(t, gw, gh)
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
	}
	if cov != nil {
		delete(cov)
	}
	t.cache[key] = g
	return g
}

// Returns the 3-channel ClearType coverage (caller frees) and placement, with
// the run's baseline origin at (0,0) so left/top are pen-relative bearings.
@(private)
glyph_rasterize :: proc(t: ^Text, index: u16, px: f32) -> (cov: []u8, gw, gh, left, top: i32) {
	idx := index
	run := GLYPH_RUN {
		fontFace     = t.face,
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

// Shelf packer: grow-only, no eviction yet (milestone). Pads 1px between glyphs.
@(private)
atlas_pack :: proc(t: ^Text, w, h: i32) -> (x, y: i32) {
	PAD :: 1
	if t.pack_x + w + PAD > ATLAS_W {
		t.pack_x = 0
		t.pack_y += t.shelf_h + PAD
		t.shelf_h = 0
	}
	if t.pack_y + h > ATLAS_H {
		fmt.eprintln("glyph atlas full (grow-only not yet implemented)")
	}
	x = t.pack_x
	y = t.pack_y
	t.pack_x += w + PAD
	if h > t.shelf_h {
		t.shelf_h = h
	}
	return
}
