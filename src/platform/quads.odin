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
Quad :: struct {
	pos:   [2]f32, // top-left, pixels
	size:  [2]f32, // width, height, pixels
	color: [4]f32, // rgba, 0..1
}

MAX_QUADS :: 4096

Quad_Pipeline :: struct {
	vs:        ^d3d.IVertexShader,
	ps:        ^d3d.IPixelShader,
	layout:    ^d3d.IInputLayout,
	instances: ^d3d.IBuffer, // dynamic; refilled each frame
	constants: ^d3d.IBuffer, // screen size
}

@(private)
QUAD_HLSL := `
cbuffer Constants : register(b0) {
	float2 screen_size;
	float2 _pad;
};

struct VSIn {
	float2 ipos   : IPOS;
	float2 isize  : ISIZE;
	float4 icolor : ICOLOR;
	uint   vid    : SV_VertexID;
};

struct VSOut {
	float4 pos   : SV_POSITION;
	float4 color : COLOR;
};

VSOut vs_main(VSIn i) {
	// vid 0..3 -> corners (0,0)(1,0)(0,1)(1,1) drawn as a triangle strip.
	float2 corner = float2(i.vid & 1, (i.vid >> 1) & 1);
	float2 px = i.ipos + corner * i.isize;
	// Pixel space -> normalized device coords (y down to y up).
	float2 ndc = float2(px.x / screen_size.x * 2.0 - 1.0,
	                    1.0 - px.y / screen_size.y * 2.0);
	VSOut o;
	o.pos = float4(ndc, 0.0, 1.0);
	o.color = i.icolor;
	return o;
}

float4 ps_main(VSOut i) : SV_TARGET {
	return i.color;
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

// Draw-call accounting. Two increments on paths that already do a Map plus a
// DrawInstanced, so the cost is noise — but it is the only way to answer "how
// much does one more per-row draw actually cost" with a number instead of an
// estimate. Read by `newtpad drawcount`.
draw_calls_text: int
draw_calls_quad: int

draw_counts :: proc() -> (text_calls, quad_calls: int) {return draw_calls_text, draw_calls_quad}
draw_counts_reset :: proc() {draw_calls_text, draw_calls_quad = 0, 0}

// Upload the quad list and draw it all in a single instanced call.
quads_draw :: proc(gfx: ^Gfx, qp: ^Quad_Pipeline, quads: []Quad) {
	if len(quads) == 0 {
		return
	}
	draw_calls_quad += 1
	n := min(len(quads), MAX_QUADS)
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
	ctx->OMSetBlendState(nil, nil, 0xFFFFFFFF) // opaque; don't inherit the text pass's blend
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
