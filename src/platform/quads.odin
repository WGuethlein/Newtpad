// Layer: platform — the instanced-quad GPU pipeline (D3D11).
// COM/D3D11 stays isolated in platform; upper layers hand down plain-data
// `Quad` lists and this draws them in one instanced call. This is the seed of
// the glyph renderer: a glyph is just a textured quad.
//
// Shaders are compiled from embedded HLSL at startup for now. Switch to
// precompiled bytecode (fxc/dxc at build time, embedded via #load) before V1
// ships, to drop the d3dcompiler_47.dll dependency.
package platform

import "core:fmt"
import "core:mem"
import d3d "vendor:directx/d3d11"
import dxc "vendor:directx/d3d_compiler"
import win "core:sys/windows"

// One instanced rectangle in pixel space. Plain data — safe to hand upward.
//
// `radius` and `softness` are ZERO-IS-DEFAULT deliberately: every existing
// caller writes only pos/size/color, and a zero radius with zero softness must
// draw exactly the hard-edged rectangle it always drew. quadsdftest asserts
// that against a real device rather than trusting it.
//
// Rounded corners, hairlines, focus rings and panel shadows are all this one
// shape with different parameters — the whole point of the signed-distance
// form. No new geometry, no per-shape code, and still one draw call.
Quad :: struct {
	pos:      [2]f32, // top-left, pixels
	size:     [2]f32, // width, height, pixels
	color:    [4]f32, // rgba, 0..1
	radius:   [4]f32, // per corner: TL, TR, BR, BL. 0 = square
	softness: f32, // 0 = a crisp antialiased edge; >0 = a shadow's blur radius
	_pad:     [3]f32, // keep the instance 16-byte aligned
}

MAX_QUADS :: 4096

Quad_Pipeline :: struct {
	vs:        ^d3d.IVertexShader,
	ps:        ^d3d.IPixelShader,
	layout:    ^d3d.IInputLayout,
	instances: ^d3d.IBuffer, // dynamic; refilled each frame
	constants: ^d3d.IBuffer, // screen size
	// Straight alpha over the destination. The pass used to bind NO blend state
	// at all ("opaque; don't inherit the text pass's blend"), which was fine
	// while every edge was hard: a rect either covered a pixel or did not. The
	// distance field resolves its edge IN alpha, so without blending every
	// antialiased boundary would write its partial coverage as an opaque colour
	// and the rounded corners would come out jagged and dark.
	blend:     ^d3d.IBlendState,
}

@(private)
QUAD_HLSL := `
cbuffer Constants : register(b0) {
	float2 screen_size;
	float2 _pad;
};

struct VSIn {
	float2 ipos    : IPOS;
	float2 isize   : ISIZE;
	float4 icolor  : ICOLOR;
	float4 iradius : IRADIUS;
	float  isoft   : ISOFT;
	uint   vid     : SV_VertexID;
};

struct VSOut {
	float4 pos    : SV_POSITION;
	float4 color  : COLOR;
	float2 local  : LOCAL;   // position relative to the rect's centre, in pixels
	float2 half_s : HALFSIZE;
	float4 radius : RADIUS;
	float  soft   : SOFT;
};

VSOut vs_main(VSIn i) {
	// vid 0..3 -> corners (0,0)(1,0)(0,1)(1,1) drawn as a triangle strip.
	float2 corner = float2(i.vid & 1, (i.vid >> 1) & 1);
	// Grow the geometry by the blur radius. A shadow's falloff lies OUTSIDE the
	// rectangle, and the pixel shader only runs where there is geometry -- so
	// without this the distance field is evaluated correctly and then simply
	// never sampled beyond the edge, and a shadow renders as nothing at all.
	// Zero for every ordinary quad, which is why the expanded form costs the
	// common case nothing.
	float2 grow = float2(i.isoft, i.isoft);
	float2 px = (i.ipos - grow) + corner * (i.isize + 2.0 * grow);
	// Pixel space -> normalized device coords (y down to y up).
	float2 ndc = float2(px.x / screen_size.x * 2.0 - 1.0,
	                    1.0 - px.y / screen_size.y * 2.0);
	VSOut o;
	o.pos = float4(ndc, 0.0, 1.0);
	o.color = i.icolor;
	// The distance field is evaluated about the rect's centre, so the pixel
	// shader needs the offset from it and the half extent. Both in pixels, so
	// fwidth below is one screen pixel at any DPI without a scale uniform.
	o.half_s = i.isize * 0.5;
	o.local  = px - (i.ipos + o.half_s);
	o.radius = i.iradius;
	o.soft   = i.isoft;
	return o;
}

// Signed distance to a rounded box: negative inside, zero on the edge.
// The per-corner radius is selected by which quadrant the point falls in, so a
// single instance can carry four different corners -- a tab pill rounded on top
// and square along the bottom is one quad, not three.
float sd_round_box(float2 p, float2 b, float4 r) {
	float2 rr = (p.x > 0.0) ? r.yz : r.xw;   // right pair (TR,BR) : left pair (TL,BL)
	float  cr = (p.y > 0.0) ? rr.y : rr.x;
	cr = min(cr, min(b.x, b.y));             // a radius cannot exceed the half extent
	float2 q = abs(p) - b + cr;
	return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - cr;
}

float4 ps_main(VSOut i) : SV_TARGET {
	// The plain rectangle takes no distance field at all.
	//
	// This is not an optimisation, it is the compatibility contract. fwidth-based
	// AA ramps coverage over the last pixel or two INSIDE any edge, so running
	// every quad through it would have softened the border of every existing
	// piece of chrome -- measured at r=244 instead of 255 on the pixel just
	// inside a hard edge. Nothing asked for that, and "radius 0, softness 0
	// renders exactly what it always rendered" is the property that lets this
	// change land under the whole UI at once. Uniform across an instance, so the
	// branch costs a wavefront nothing.
	if (i.soft <= 0.0 && dot(i.radius, float4(1, 1, 1, 1)) <= 0.0) {
		return i.color;
	}
	float d = sd_round_box(i.local, i.half_s, i.radius);
	float a;
	if (i.soft > 0.0) {
		// A shadow: widen the falloff instead of resolving an edge. One quad,
		// no blur pass, no render target, no downsample.
		a = 1.0 - smoothstep(-i.soft, i.soft, d);
	} else {
		// fwidth is the hardware derivative of the distance in screen space, so
		// this is one pixel of gradient at 100% and at 200% alike -- the AA does
		// not need to know the DPI. Guarded against zero, which happens where
		// the field is flat (a fully interior pixel) and would make smoothstep
		// undefined.
		float aa = max(fwidth(d), 1e-5);
		a = 1.0 - smoothstep(-aa, aa, d);
	}
	return float4(i.color.rgb, i.color.a * a);
}
`

quads_init :: proc(gfx: ^Gfx) -> (qp: Quad_Pipeline, ok: bool) {
	vs_blob, vs_ok := compile_shader(QUAD_HLSL, "vs_main", "vs_5_0")
	if !vs_ok {
		return qp, false
	}
	defer vs_blob->Release()

	ps_blob, ps_ok := compile_shader(QUAD_HLSL, "ps_main", "ps_5_0")
	if !ps_ok {
		return qp, false
	}
	defer ps_blob->Release()

	if hr := gfx.device->CreateVertexShader(vs_blob->GetBufferPointer(), vs_blob->GetBufferSize(), nil, &qp.vs); !win.SUCCEEDED(hr) {
		fmt.eprintln("CreateVertexShader failed")
		return qp, false
	}
	if hr := gfx.device->CreatePixelShader(ps_blob->GetBufferPointer(), ps_blob->GetBufferSize(), nil, &qp.ps); !win.SUCCEEDED(hr) {
		fmt.eprintln("CreatePixelShader failed")
		return qp, false
	}

	// All attributes are per-instance, packed to match the Quad struct.
	layout := [?]d3d.INPUT_ELEMENT_DESC{
		{"IPOS", 0, .R32G32_FLOAT, 0, 0, .INSTANCE_DATA, 1},
		{"ISIZE", 0, .R32G32_FLOAT, 0, 8, .INSTANCE_DATA, 1},
		{"ICOLOR", 0, .R32G32B32A32_FLOAT, 0, 16, .INSTANCE_DATA, 1},
		{"IRADIUS", 0, .R32G32B32A32_FLOAT, 0, 32, .INSTANCE_DATA, 1},
		{"ISOFT", 0, .R32_FLOAT, 0, 48, .INSTANCE_DATA, 1},
	}
	if hr := gfx.device->CreateInputLayout(raw_data(layout[:]), u32(len(layout)), vs_blob->GetBufferPointer(), vs_blob->GetBufferSize(), &qp.layout); !win.SUCCEEDED(hr) {
		fmt.eprintln("CreateInputLayout failed")
		return qp, false
	}

	inst_desc := d3d.BUFFER_DESC {
		ByteWidth      = MAX_QUADS * size_of(Quad),
		Usage          = .DYNAMIC,
		BindFlags      = {.VERTEX_BUFFER},
		CPUAccessFlags = {.WRITE},
	}
	if hr := gfx.device->CreateBuffer(&inst_desc, nil, &qp.instances); !win.SUCCEEDED(hr) {
		fmt.eprintln("CreateBuffer(instances) failed")
		return qp, false
	}

	bdesc: d3d.BLEND_DESC
	bdesc.RenderTarget[0] = {
		BlendEnable           = true,
		SrcBlend              = .SRC_ALPHA,
		DestBlend             = .INV_SRC_ALPHA,
		BlendOp               = .ADD,
		SrcBlendAlpha         = .ONE,
		DestBlendAlpha        = .INV_SRC_ALPHA,
		BlendOpAlpha          = .ADD,
		RenderTargetWriteMask = u8(d3d.COLOR_WRITE_ENABLE_ALL),
	}
	if hr := gfx.device->CreateBlendState(&bdesc, &qp.blend); !win.SUCCEEDED(hr) {
		fmt.eprintln("CreateBlendState failed")
		return qp, false
	}

	const_desc := d3d.BUFFER_DESC {
		ByteWidth      = 16, // float2 screen_size + float2 pad
		Usage          = .DYNAMIC,
		BindFlags      = {.CONSTANT_BUFFER},
		CPUAccessFlags = {.WRITE},
	}
	if hr := gfx.device->CreateBuffer(&const_desc, nil, &qp.constants); !win.SUCCEEDED(hr) {
		fmt.eprintln("CreateBuffer(constants) failed")
		return qp, false
	}

	return qp, true
}

// Upload the quad list and draw it all in a single instanced call.
// Draw-call and instance-stream accounting lives in draw_trace.odin.
quads_draw :: proc(gfx: ^Gfx, qp: ^Quad_Pipeline, quads: []Quad) {
	if len(quads) == 0 {
		return
	}
	g_draw.quad_calls += 1
	n := min(len(quads), MAX_QUADS)
	g_draw.quad_clamped += len(quads) - n
	draw_note_quads(quads[:n])
	ctx := gfx.ctx

	mapped: d3d.MAPPED_SUBRESOURCE
	if win.SUCCEEDED(ctx->Map((^d3d.IResource)(qp.instances), 0, .WRITE_DISCARD, {}, &mapped)) {
		mem.copy(mapped.pData, raw_data(quads), n * size_of(Quad))
		ctx->Unmap((^d3d.IResource)(qp.instances), 0)
	}

	if win.SUCCEEDED(ctx->Map((^d3d.IResource)(qp.constants), 0, .WRITE_DISCARD, {}, &mapped)) {
		screen := [2]f32{f32(gfx.width), f32(gfx.height)}
		mem.copy(mapped.pData, &screen, size_of(screen))
		ctx->Unmap((^d3d.IResource)(qp.constants), 0)
	}

	stride := u32(size_of(Quad))
	offset := u32(0)
	ctx->OMSetBlendState(qp.blend, nil, 0xFFFFFFFF) // straight alpha: the SDF resolves its edge in alpha
	ctx->IASetInputLayout(qp.layout)
	ctx->IASetPrimitiveTopology(.TRIANGLESTRIP)
	ctx->IASetVertexBuffers(0, 1, &qp.instances, &stride, &offset)
	ctx->VSSetShader(qp.vs, nil, 0)
	ctx->VSSetConstantBuffers(0, 1, &qp.constants)
	ctx->PSSetShader(qp.ps, nil, 0)
	ctx->DrawInstanced(4, u32(n), 0, 0)
}

@(private)
compile_shader :: proc(source: string, entry: cstring, target: cstring) -> (blob: ^d3d.IBlob, ok: bool) {
	errors: ^d3d.IBlob
	hr := dxc.Compile(
		raw_data(source),
		d3d.SIZE_T(len(source)),
		nil,
		nil,
		nil,
		entry,
		target,
		0,
		0,
		&blob,
		&errors,
	)
	if !win.SUCCEEDED(hr) {
		if errors != nil {
			fmt.eprintfln("shader compile failed (%s): %s", target, cstring(errors->GetBufferPointer()))
			errors->Release()
		} else {
			fmt.eprintfln("shader compile failed (%s): 0x%X", target, u32(hr))
		}
		return nil, false
	}
	if errors != nil {
		errors->Release()
	}
	return blob, true
}
