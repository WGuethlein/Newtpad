// Layer: platform — D3D11 device, DXGI flip-model swapchain, and present.
// For this first milestone it only clears to a color; the quad pipeline moves
// into the renderer layer once it exists. COM stays isolated here.
package platform

import "core:fmt"
import win "core:sys/windows"
import d3d "vendor:directx/d3d11"
import dxgi "vendor:directx/dxgi"

Gfx :: struct {
	device:        ^d3d.IDevice,
	ctx:           ^d3d.IDeviceContext,
	swapchain:     ^dxgi.ISwapChain,
	rtv:           ^d3d.IRenderTargetView,
	// Set only by gfx_init_offscreen: the render target when there is no
	// swapchain to get a backbuffer from. nil on the windowed path, which is
	// also how the rest of this file tells the two apart (`swapchain == nil`).
	offscreen:     ^d3d.ITexture2D,
	width:         i32, // client/viewport size (what we render into)
	height:        i32,
	buf_w:         i32, // fixed swapchain buffer size (>= any window size)
	buf_h:         i32,
	tearing:       bool, // allow-tearing supported
	// The GPU went away: driver update, TDR (a hung shader anywhere on the
	// system), eGPU unplug, a Remote Desktop session change. Routine events, not
	// exotic ones. Every D3D object is invalid afterwards and every call on them
	// is undefined, so the frame loop must stop drawing the moment this is set.
	lost:          bool,
}

// Result of presenting a frame. Anything other than .Ok means the device is
// gone and the caller must stop rendering.
Device_Status :: enum {
	Ok,
	Lost,
}

// Why the device was lost, for the message the user gets. HRESULTs here are the
// documented DXGI removal reasons.
gfx_lost_reason :: proc(gfx: ^Gfx) -> string {
	if gfx.device == nil {return "the graphics device was released"}
	switch gfx.device->GetDeviceRemovedReason() {
	case dxgi.ERROR_DEVICE_HUNG:
		return "the graphics driver stopped responding"
	case dxgi.ERROR_DEVICE_REMOVED:
		return "the graphics device was removed or the driver was updated"
	case dxgi.ERROR_DEVICE_RESET:
		return "the graphics device was reset"
	case dxgi.ERROR_DRIVER_INTERNAL_ERROR:
		return "the graphics driver reported an internal error"
	}
	return "the graphics device became unavailable"
}

// Whether the OS/driver supports DXGI allow-tearing (Win10 1607+). Needed so a
// sync-interval-0 present is truly immediate instead of vblank-locked (a flip-
// model present can't tear without this flag, which is what made resize stutter).
@(private)
gfx_check_tearing :: proc() -> bool {
	factory: ^dxgi.IFactory5
	if !win.SUCCEEDED(dxgi.CreateDXGIFactory1(dxgi.IFactory5_UUID, (^rawptr)(&factory))) || factory == nil {
		return false
	}
	defer factory->Release()
	allow: win.BOOL
	if !win.SUCCEEDED(factory->CheckFeatureSupport(.PRESENT_ALLOW_TEARING, &allow, size_of(allow))) {
		return false
	}
	return bool(allow)
}

// The device and its immediate context, with no target attached. Shared by the
// windowed path (gfx_init) and the headless one (gfx_init_offscreen) so a
// measurement taken without a window runs against the same device
// configuration — same flags, same feature levels — the product runs against.
@(private)
gfx_create_device :: proc(gfx: ^Gfx) -> bool {
	// The D3D11 debug layer validates every API call — a large per-call overhead.
	// Opt in with -define:D3D_DEBUG=true; don't tie it to Odin's -debug.
	flags := d3d.CREATE_DEVICE_FLAGS{.BGRA_SUPPORT}
	when #config(D3D_DEBUG, false) {
		flags |= {.DEBUG}
	}
	levels := [?]d3d.FEATURE_LEVEL{._11_1, ._11_0}

	if hr := d3d.CreateDevice(nil, .HARDWARE, nil, flags, raw_data(levels[:]), u32(len(levels)), d3d.SDK_VERSION, &gfx.device, nil, &gfx.ctx); !win.SUCCEEDED(hr) {
		fmt.eprintfln("D3D11CreateDevice failed: 0x%X", u32(hr))
		return false
	}
	return true
}

// A real device drawing into an offscreen texture instead of a swapchain: no
// HWND, no message pump, nothing on screen, and the process exits when the
// caller is done with it.
//
// This exists because a D3D device does not need a *window* — only a swapchain
// does — but the only way to get one here used to be gfx_init, so every headless
// mode that needed the GPU (`drawcount`, `atlasgrowtest`) created a visible
// window it never pumped. That is what development-loop.md §6 warns about, and
// it also made `drawcount`'s output depend on the machine: the monitor's DPI
// scaled every metric, and the physical mouse position over that window changed
// how many hover quads the frame drew. An instrument whose reading moves with
// where the pointer happens to be cannot support a before/after comparison.
//
// The format matches the swapchain's backbuffer so the pipeline state, blend
// and shaders are exercised exactly as they are on screen.
gfx_init_offscreen :: proc(width, height: i32) -> (gfx: Gfx, ok: bool) {
	gfx.width, gfx.height = width, height
	gfx.buf_w, gfx.buf_h = width, height
	if !gfx_create_device(&gfx) {
		return gfx, false
	}
	desc := d3d.TEXTURE2D_DESC {
		Width      = u32(width),
		Height     = u32(height),
		MipLevels  = 1,
		ArraySize  = 1,
		Format     = .B8G8R8A8_UNORM, // as CreateSwapChainForHwnd's below
		SampleDesc = {Count = 1},
		Usage      = .DEFAULT,
		BindFlags  = {.RENDER_TARGET},
	}
	if hr := gfx.device->CreateTexture2D(&desc, nil, &gfx.offscreen); !win.SUCCEEDED(hr) {
		fmt.eprintfln("CreateTexture2D(offscreen %dx%d) failed: 0x%X", width, height, u32(hr))
		return gfx, false
	}
	if hr := gfx.device->CreateRenderTargetView((^d3d.IResource)(gfx.offscreen), nil, &gfx.rtv); !win.SUCCEEDED(hr) {
		fmt.eprintfln("CreateRenderTargetView(offscreen) failed: 0x%X", u32(hr))
		return gfx, false
	}
	return gfx, true
}

// Read the offscreen render target back to the CPU, as BGRA8 rows.
//
// Offscreen ONLY -- there is deliberately no windowed path. This exists so a
// headless mode can assert what the GPU actually produced instead of asserting
// the arithmetic a shader was supposed to perform, which CLAUDE.md asks for
// whenever the claim is about the GPU ("a real device over arithmetic"). The
// rounded-rect pipeline is exactly that kind of claim: its antialiasing comes
// from `fwidth`, a hardware derivative that no CPU-side reimplementation of the
// distance function would exercise.
//
// Returns a freshly allocated [width*height*4] buffer the caller owns. A
// STAGING copy is made per call rather than cached: this runs a handful of
// times in a test mode, never in a frame.
gfx_readback_bgra :: proc(gfx: ^Gfx, allocator := context.allocator) -> (pixels: []u8, ok: bool) {
	if gfx.offscreen == nil {return nil, false}
	desc := d3d.TEXTURE2D_DESC {
		Width          = u32(gfx.width),
		Height         = u32(gfx.height),
		MipLevels      = 1,
		ArraySize      = 1,
		Format         = .B8G8R8A8_UNORM,
		SampleDesc     = {Count = 1},
		Usage          = .STAGING,
		CPUAccessFlags = {.READ},
	}
	staging: ^d3d.ITexture2D
	if hr := gfx.device->CreateTexture2D(&desc, nil, &staging); !win.SUCCEEDED(hr) {
		fmt.eprintfln("CreateTexture2D(staging) failed: 0x%X", u32(hr))
		return nil, false
	}
	defer staging->Release()
	gfx.ctx->CopyResource((^d3d.IResource)(staging), (^d3d.IResource)(gfx.offscreen))

	mapped: d3d.MAPPED_SUBRESOURCE
	if hr := gfx.ctx->Map((^d3d.IResource)(staging), 0, .READ, {}, &mapped); !win.SUCCEEDED(hr) {
		fmt.eprintfln("Map(staging) failed: 0x%X", u32(hr))
		return nil, false
	}
	defer gfx.ctx->Unmap((^d3d.IResource)(staging), 0)

	// RowPitch is the GPU's stride and is NOT width*4 in general -- it is padded
	// to the driver's alignment. Copying the whole mapped block would shear the
	// image; copy row by row.
	out := make([]u8, int(gfx.width) * int(gfx.height) * 4, allocator)
	src := ([^]u8)(mapped.pData)
	row := int(gfx.width) * 4
	for y in 0 ..< int(gfx.height) {
		copy(out[y * row:][:row], src[y * int(mapped.RowPitch):][:row])
	}
	return out, true
}

// Release everything gfx_init / gfx_init_offscreen created, in reverse order.
// The product leaks these deliberately (process exit reclaims them and the
// teardown would only slow the exit), but a headless mode that creates and
// destroys a device inside one run needs them back.
gfx_destroy :: proc(gfx: ^Gfx) {
	if gfx.rtv != nil {gfx.rtv->Release();gfx.rtv = nil}
	if gfx.offscreen != nil {gfx.offscreen->Release();gfx.offscreen = nil}
	if gfx.swapchain != nil {gfx.swapchain->Release();gfx.swapchain = nil}
	if gfx.ctx != nil {gfx.ctx->Release();gfx.ctx = nil}
	if gfx.device != nil {gfx.device->Release();gfx.device = nil}
}

gfx_init :: proc(w: ^Window) -> (gfx: Gfx, ok: bool) {
	gfx.width = w.width
	gfx.height = w.height
	gfx.tearing = gfx_check_tearing()

	if !gfx_create_device(&gfx) {
		return gfx, false
	}

	factory: ^dxgi.IFactory2
	if hr := dxgi.CreateDXGIFactory2({}, dxgi.IFactory2_UUID, (^rawptr)(&factory)); !win.SUCCEEDED(hr) {
		fmt.eprintfln("CreateDXGIFactory2 failed: 0x%X", u32(hr))
		return gfx, false
	}
	defer factory->Release()

	// The swapchain buffer is fixed at the largest a window can be, so resizing
	// the window only moves the viewport — it never reallocates the swapchain
	// (ResizeBuffers stalls the GPU and is what made resize stutter). SCALING_NONE
	// presents the top-left window-sized region of the buffer 1:1.
	gfx.buf_w = max(i32(win.GetSystemMetrics(win.SM_CXMAXTRACK)), w.width)
	gfx.buf_h = max(i32(win.GetSystemMetrics(win.SM_CYMAXTRACK)), w.height)

	desc := dxgi.SWAP_CHAIN_DESC1 {
		Width       = u32(gfx.buf_w),
		Height      = u32(gfx.buf_h),
		Format      = .B8G8R8A8_UNORM,
		SampleDesc  = {Count = 1},
		BufferUsage = {.RENDER_TARGET_OUTPUT},
		BufferCount = 2,
		Scaling     = .NONE,
		SwapEffect  = .FLIP_DISCARD,
		AlphaMode   = .UNSPECIFIED,
		Flags       = {.ALLOW_TEARING} if gfx.tearing else {},
	}

	swapchain1: ^dxgi.ISwapChain1
	if hr := factory->CreateSwapChainForHwnd((^dxgi.IUnknown)(rawptr(gfx.device)), w.hwnd, &desc, nil, nil, &swapchain1); !win.SUCCEEDED(hr) {
		fmt.eprintfln("CreateSwapChainForHwnd failed: 0x%X", u32(hr))
		return gfx, false
	}
	gfx.swapchain = (^dxgi.ISwapChain)(rawptr(swapchain1))

	gfx_create_rtv(&gfx)
	return gfx, true
}

@(private)
gfx_create_rtv :: proc(gfx: ^Gfx) {
	backbuffer: ^d3d.ITexture2D
	// GetBuffer's HRESULT was discarded and backbuffer released unconditionally.
	// On a lost device GetBuffer fails and leaves the pointer nil, so the Release
	// was a call through a nil vtable -- an access violation on the resize path,
	// at exactly the moment things were already going wrong.
	if hr := gfx.swapchain->GetBuffer(0, d3d.ITexture2D_UUID, (^rawptr)(&backbuffer)); !win.SUCCEEDED(hr) || backbuffer == nil {
		if hr == dxgi.ERROR_DEVICE_REMOVED || hr == dxgi.ERROR_DEVICE_RESET {gfx.lost = true}
		gfx.rtv = nil
		return
	}
	defer backbuffer->Release()
	if hr := gfx.device->CreateRenderTargetView((^d3d.IResource)(backbuffer), nil, &gfx.rtv); !win.SUCCEEDED(hr) {
		gfx.rtv = nil
	}
}

gfx_resize :: proc(gfx: ^Gfx, width, height: i32) {
	if gfx.swapchain == nil || width <= 0 || height <= 0 {
		return
	}
	gfx.width = width
	gfx.height = height
	// The fixed buffer covers any normal resize, so this is just a viewport change
	// (no realloc → no stutter). Only grow the buffer if the window somehow exceeds
	// it (e.g. dragged onto a larger monitor).
	if width > gfx.buf_w || height > gfx.buf_h {
		gfx.buf_w = max(width, gfx.buf_w)
		gfx.buf_h = max(height, gfx.buf_h)
		if gfx.rtv != nil {
			gfx.rtv->Release()
			gfx.rtv = nil
		}
		gfx.swapchain->ResizeBuffers(0, u32(gfx.buf_w), u32(gfx.buf_h), .UNKNOWN, {.ALLOW_TEARING} if gfx.tearing else {})
		gfx_create_rtv(gfx)
	}
}

// Bind the backbuffer, set the viewport, and clear. Draw calls go after this.
gfx_begin_frame :: proc(gfx: ^Gfx, r, g, b: f32) {
	// Nothing may be issued against a dead device, and rtv is nil when the target
	// could not be created — binding it would render into nothing at best.
	if gfx.lost || gfx.rtv == nil {return}
	color := [4]f32{r, g, b, 1}
	viewport := d3d.VIEWPORT{0, 0, f32(gfx.width), f32(gfx.height), 0, 1}

	gfx.ctx->OMSetRenderTargets(1, &gfx.rtv, nil)
	gfx.ctx->RSSetViewports(1, &viewport)
	gfx.ctx->ClearRenderTargetView(gfx.rtv, &color)
	// Reset to default opaque blend so per-pass blend state never leaks frames.
	gfx.ctx->OMSetBlendState(nil, nil, 0xFFFFFFFF)
}

// Present the frame. sync=1 = vsync (default, calm GPU); sync=0 = immediate,
// used during a live resize so per-WM_SIZE presents don't each block on vblank.
// Sync-0 needs the ALLOW_TEARING present flag to actually be immediate (otherwise
// a flip-model present stays vblank-locked).
gfx_end_frame :: proc(gfx: ^Gfx, sync: u32 = 1) -> Device_Status {
	if gfx.lost {return .Lost}
	// Offscreen (gfx_init_offscreen): nothing to present. Flush anyway, so the
	// frame's commands are actually submitted to the GPU rather than left
	// queued in the context — otherwise a headless "frame" would be a list of
	// API calls that never ran, and a driver validation failure in one of them
	// would go unreported.
	if gfx.swapchain == nil {
		gfx.ctx->Flush()
		return .Ok
	}
	flags: dxgi.PRESENT
	if sync == 0 && gfx.tearing {
		flags = {.ALLOW_TEARING}
	}
	// Present's HRESULT was discarded, so a removed device produced a window that
	// never updated again while the loop kept issuing calls into dead COM objects
	// -- a frozen editor holding every unsaved buffer, with no message and no way
	// to get the text back.
	hr := gfx.swapchain->Present(sync, flags)
	if hr == dxgi.ERROR_DEVICE_REMOVED || hr == dxgi.ERROR_DEVICE_RESET {
		gfx.lost = true
		return .Lost
	}
	return .Ok
}

gfx_is_lost :: proc(gfx: ^Gfx) -> bool {return gfx.lost}

// Test seam. A real device removal needs a TDR or a driver update, neither of
// which can be provoked here, so this is the only way to exercise the paths that
// must go inert afterwards. It sets the same flag Present would.
gfx_force_lost :: proc(gfx: ^Gfx) {gfx.lost = true}
