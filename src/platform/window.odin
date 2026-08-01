// Layer: platform — all Win32/COM lives here and never leaks upward.
// This file owns the OS window and its message pump.
package platform

import win "core:sys/windows"

// Not present in core:sys/windows; hand-declare (used for click-count timing).
foreign import user32_extra "system:User32.lib"
foreign import kernel32_extra "system:Kernel32.lib"
foreign import dwmapi "system:Dwmapi.lib"

@(default_calling_convention = "system")
foreign kernel32_extra {
	GetTickCount :: proc() -> u32 ---
}
@(default_calling_convention = "system")
foreign user32_extra {
	GetDoubleClickTime :: proc() -> u32 ---
	MsgWaitForMultipleObjectsEx :: proc(nCount: win.DWORD, pHandles: ^win.HANDLE, dwMilliseconds: win.DWORD, dwWakeMask: win.DWORD, dwFlags: win.DWORD) -> win.DWORD ---
}
QS_ALLINPUT :: 0x04FF

// Block until a message arrives (any input, window event, or posted message) or
// `timeout_ms` elapses, then return so the caller can pump + render. This is what
// keeps the app off a CPU core when idle — instead of spinning at vsync it sleeps
// here, waking the instant an event lands. The caller spins (skips this) only
// while it genuinely needs continuous frames (a drag auto-scrolling).
window_wait_message :: proc(w: ^Window, timeout_ms: u32) {
	MsgWaitForMultipleObjectsEx(0, nil, timeout_ms, QS_ALLINPUT, 0)
}
@(default_calling_convention = "system")
foreign dwmapi {
	DwmExtendFrameIntoClientArea :: proc(hwnd: win.HWND, margins: ^MARGINS) -> win.HRESULT ---
	DwmSetWindowAttribute :: proc(hwnd: win.HWND, attr: u32, value: rawptr, size: u32) -> win.HRESULT ---
}

// --- custom (borderless) window frame: we keep the OS resize/min/max behaviour
// and the Win11 rounded corners + shadow, but replace the caption with our tab
// bar. See wnd_proc's WM_NCCALCSIZE / WM_NCHITTEST / WM_NCLBUTTONDOWN. ---
@(private = "file")
MARGINS :: struct {
	cxLeftWidth, cxRightWidth, cyTopHeight, cyBottomHeight: i32,
}
@(private = "file")
NCCALCSIZE_PARAMS :: struct {
	rgrc:  [3]win.RECT,
	lppos: ^win.WINDOWPOS,
}
DWMWA_WINDOW_CORNER_PREFERENCE :: 33
DWMWCP_ROUND: i32 : 2
RESIZE_BORDER_96 :: i32(6) // hit-test thickness of the resize edges, at 96 DPI
CAPTION_BTN_W_96 :: i32(46) // width of each min/max/close button, at 96 DPI

// Non-client metrics are pure functions of this window's DPI, so the platform
// computes them itself rather than having the program mirror them in (the way
// titlebar_h/tabs_right are). Mirroring would leave them zero on the first frame
// and stale for a frame after every DPI change — and wnd_proc needs them correct
// during window creation, before the program has drawn anything.
window_resize_border :: proc "contextless" (w: ^Window) -> i32 {
	return max(1, RESIZE_BORDER_96 * i32(w.dpi) / 96)
}
window_caption_btn_w :: proc "contextless" (w: ^Window) -> i32 {
	return max(1, CAPTION_BTN_W_96 * i32(w.dpi) / 96)
}

// Scale factor for the program's layout. Always >= 1.0: dpi is clamped at the
// capture site, because GetDpiForWindow returns 0 for an invalid HWND and a zero
// scale propagates into divisions (char_w, line_h) whose +Inf result is poison
// when converted to int — negative row counts and out-of-range indices.
window_scale :: proc "contextless" (w: ^Window) -> f32 {return f32(w.dpi) / 96}

// The smallest the window may become, in LOGICAL pixels, scaled by DPI at the
// point Windows asks.
//
// UI spec 5 gives a drop order -- status cells, then tabs to their floor, then
// the >_ and + buttons, then the menu bar to a hamburger -- and then says the
// actual fix: "Enforcing a real minimum is the actual fix; a drop order with no
// floor still eventually overlaps." There was no floor at all, so the window
// could be dragged until the tab rail ran under the caption buttons, which is
// the one overlap that matters: WM_NCHITTEST claims that region first, so a tab
// drawn there sends HT_CLOSE and one click exits the app.
//
// 318 is what the spec's own floor leaves room for: a hamburger, one tab at its
// 132 minimum, and three caption buttons.
MIN_W_96 :: i32(318)
MIN_H_96 :: i32(240)

// The clamped minimum at a given DPI. The wnd_proc computes this inline for
// WM_GETMINMAXINFO; this is the same arithmetic, exposed so a headless mode can
// assert it without a message pump. Kept beside the constants rather than in the
// handler so there is one expression, not two that agree today.
window_min_size :: proc "contextless" (dpi: u32) -> (w, h: i32) {
	s := f32(dpi) / 96
	return i32(f32(MIN_W_96) * s + 0.5), i32(f32(MIN_H_96) * s + 0.5)
}

DPI_MIN :: u32(96)
DPI_MAX :: u32(960) // 1000% — well past what Windows offers

@(private)
clamp_dpi :: proc "contextless" (dpi: u32) -> u32 {
	return DPI_MIN if dpi < DPI_MIN else (DPI_MAX if dpi > DPI_MAX else dpi)
}

// Exposed so `newtpad dpitest` can exercise the clamp without a real window.
clamp_dpi_for_test :: proc "contextless" (dpi: u32) -> u32 {return clamp_dpi(dpi)}
// hit-test codes (not all in core:sys/windows)
HT_CLIENT :: 1
HT_CAPTION :: 2
HT_MINBUTTON :: 8
HT_MAXBUTTON :: 9
HT_LEFT :: 10
HT_RIGHT :: 11
HT_TOP :: 12
HT_TOPLEFT :: 13
HT_TOPRIGHT :: 14
HT_BOTTOM :: 15
HT_BOTTOMLEFT :: 16
HT_BOTTOMRIGHT :: 17
HT_CLOSE :: 20

// Window class name, also used by instance.odin to find a running instance.
WINDOW_CLASS :: "NewtpadWindowClass"

// Per-frame capacity for cross-instance open requests (selecting a batch of
// files in Explorer sends one per file). Overflow is dropped, not truncated.
//
// Paths on this queue are deliberately NOT \\?\-prefixed. They arrive from
// another process (WM_COPYDATA) or from Explorer (WM_DROPFILES) and are carried
// as plain UTF-8; the prefix is applied at the syscall, inside platform/file.odin.
// OPEN_PATH_MAX is 1024, well past MAX_PATH, so a long dropped path survives the
// queue and is opened correctly by the file layer.
OPEN_QUEUE :: 16
OPEN_PATH_MAX :: 1024

// A single top-level OS window. Platform types stay in this layer; upper
// layers see only this opaque handle and the procs below.

// OS-neutral key codes. The message pump translates Win32 VK codes to these so
// the program layer binds keys without touching Win32 (semantics live above the
// platform seam). Letters/digits are contiguous for range translation.
Key :: enum u16 {
	None = 0,
	A, B, C, D, E, F, G, H, I, J, K, L, M, N, O, P, Q, R, S, T, U, V, W, X, Y, Z,
	Num0, Num1, Num2, Num3, Num4, Num5, Num6, Num7, Num8, Num9,
	Left, Right, Up, Down, Home, End, Page_Up, Page_Down,
	Backspace, Delete, Enter, Tab, Escape,
	Plus, Minus, // the =/+ and -/_ keys, and their numpad twins (zoom)
	// The whole F1-F12 range, contiguous, even though only F2/Ctrl+F2 are bound
	// today. Adding one at a time is how a key set acquires holes that the next
	// feature re-discovers: before this, VK_F2 fell through vk_to_key to .None
	// and every function key was silently swallowed by the message pump.
	// F10 is the one to know about: Windows treats a bare F10 as the menu-bar
	// activation key and delivers it as WM_SYSKEYDOWN, so key_belongs_to_windows
	// below hands it straight back to DefWindowProc. It is translated but never
	// queued, and keys.txt refuses to bind it for that reason.
	F1, F2, F3, F4, F5, F6, F7, F8, F9, F10, F11, F12,
}

// Chords the OS owns, which must reach DefWindowProc instead of the key queue.
// `sys` is "this arrived as WM_SYSKEYDOWN", which is how Windows delivers a
// key pressed with Alt held, and a bare F10.
//
// This exists because adding F1–F12 to `Key` above SILENTLY BROKE Alt+F4. The
// pump's rule is "translate and queue what we recognize, let DefWindowProc
// handle the rest", and Alt+F4 / F10 were previously "the rest" only because
// vk_to_key returned .None for them — an accident of the key set, not a
// decision. The moment VK_F4 translated, Alt+F4 was queued and swallowed, and
// the window stopped closing. Nothing in the type system could catch that: the
// enum grew, every exhaustive switch still compiled.
//
// Deliberately a named predicate rather than an inline condition in wnd_proc,
// so the rule can be asserted from a headless test (keytest) — the pump itself
// needs a real HWND and a message loop, which this environment cannot drive.
//
// Only the two: Alt+Space is VK_SPACE, which has no Key at all, and Alt+Tab
// and Ctrl+Alt+Del never reach an application window.
key_belongs_to_windows :: proc "contextless" (key: Key, sys: bool) -> bool {
	if !sys {return false} // a bare F4 or F10 is ordinary and stays bindable
	return key == .F4 || key == .F10 // Alt+F4 closes; F10 opens the system menu
}

// The same question asked from a CHORD rather than from a message, for callers
// that never see a WM_ at all -- the keys.txt parser, which has to refuse
// `alt+f4 = ...` and `f10 = ...` rather than accept a binding the pump will
// swallow before the lookup ever runs.
//
// The translation is one fact the parser cannot know: Alt held means
// WM_SYSKEYDOWN by definition, and Windows also delivers a BARE F10 that way
// because it is the menu-bar activation key. Kept here, next to the pump that
// relies on it, so there is still exactly one list of the keys Windows owns.
key_chord_belongs_to_windows :: proc "contextless" (key: Key, alt: bool) -> bool {
	return key_belongs_to_windows(key, alt || key == .F10)
}

// A raw key press, drained once per frame. The program maps (key, modifiers) to
// a command via its keymap — the platform assigns no meaning.
Key_Event :: struct {
	key:   Key,
	ctrl:  bool,
	shift: bool,
	alt:   bool,
}

@(private)
vk_to_key :: proc "contextless" (vk: win.WPARAM) -> Key {
	switch vk {
	case win.VK_LEFT:
		return .Left
	case win.VK_RIGHT:
		return .Right
	case win.VK_UP:
		return .Up
	case win.VK_DOWN:
		return .Down
	case win.VK_HOME:
		return .Home
	case win.VK_END:
		return .End
	case win.VK_PRIOR:
		return .Page_Up
	case win.VK_NEXT:
		return .Page_Down
	case win.VK_BACK:
		return .Backspace
	case win.VK_DELETE:
		return .Delete
	case win.VK_RETURN:
		return .Enter
	case win.VK_TAB:
		return .Tab
	case win.VK_ESCAPE:
		return .Escape
	case win.VK_OEM_PLUS, win.VK_ADD:
		return .Plus
	case win.VK_OEM_MINUS, win.VK_SUBTRACT:
		return .Minus
	}
	if vk >= win.WPARAM('A') && vk <= win.WPARAM('Z') {
		return Key(u16(Key.A) + u16(vk - win.WPARAM('A')))
	}
	if vk >= win.WPARAM('0') && vk <= win.WPARAM('9') {
		return Key(u16(Key.Num0) + u16(vk - win.WPARAM('0')))
	}
	// VK_F1..VK_F12 are contiguous (0x70..0x7B), as are Key.F1..Key.F12, so the
	// range translates the same way the letters and digits above do.
	if vk >= win.WPARAM(win.VK_F1) && vk <= win.WPARAM(win.VK_F12) {
		return Key(u16(Key.F1) + u16(vk - win.WPARAM(win.VK_F1)))
	}
	return .None
}

Window :: struct {
	hwnd:         win.HWND,
	width:        i32,
	height:       i32,
	should_close: bool,
	// Whether the last input was the KEYBOARD. UI spec 18: the focus ring
	// "appears on keyboard focus only… never on mouse click" -- a ring that
	// follows the mouse is noise on every click, and a ring that never appears
	// makes the app unusable without one. Latched at the platform seam because
	// this is the only place that sees both event kinds arrive.
	kbd_nav:      bool,
	resized:      bool,
	maximized:    bool,
	// custom title bar geometry (set by the program each frame, read by the NC
	// hit-test): bar height and the x where the tab/menu region ends (left of it
	// is client, right of it up to the window buttons is a drag region).
	titlebar_h:   i32,
	tabs_right:   i32,
	// This window's DPI (clamped, never 0). 96 == 100%.
	dpi:          u32,
	// Set when the DPI changed this frame; the program recomputes its layout
	// metrics and re-rasterizes glyphs, then clears it.
	dpi_changed:  bool,
	// Invoked from WM_DPICHANGED *before* the window is resized, so the nested
	// WM_SIZE repaint already uses the new scale. A poll-only flag would repaint
	// a whole cross-monitor drag at the old scale, since the OS runs a modal loop.
	on_dpi:       proc "contextless" (user: rawptr),
	dpi_user:     rawptr,
	// optional repaint callback, invoked from WM_SIZE so the app can render live
	// during the OS modal resize loop (which blocks the main loop).
	on_resize:    proc "contextless" (user: rawptr),
	resize_user:  rawptr,
	// input, drained once per frame by the program
	scroll_delta:  int, // mouse-wheel lines this frame (+down / -up)
	key_events:    [64]Key_Event,
	key_count:     int,
	chars:         [64]rune, // printable characters typed this frame
	char_count:    int,
	// Cursor the program wants over the client area this frame. The window class
	// set one IDC_ARROW for the process lifetime and handled no WM_SETCURSOR, so
	// the pointer never changed shape over anything.
	cursor:        Cursor_Kind,
	cursors:       [Cursor_Kind]win.HCURSOR,
	// High surrogate awaiting its low half across two WM_CHAR messages. Persists
	// between messages, not between frames — the pair arrives back to back.
	pending_high:  u16,
	// Alt+&lt;char&gt; this frame, layout-translated (menu mnemonics; see WM_SYSCHAR)
	sys_chars:      [16]rune,
	sys_char_count: int,
	// Alt gesture tracking. alt_tapped is set on release of a bare Alt press —
	// the "enter menu mode" gesture — and cleared by the program once consumed.
	alt_down:       bool,
	alt_used:       bool, // another key was pressed while Alt was held
	alt_tapped:     bool,
	focus_lost:     bool, // activation lost this frame; close transient UI
	// mouse (client coords)
	mouse_x:       i32,
	mouse_y:       i32,
	mouse_pressed: bool, // a press happened this frame
	mouse_count:   int, // 1 single, 2 double, 3 triple
	mouse_shift:   bool,
	mouse_down:    bool, // button held (dragging)
	mouse_middle_pressed: bool, // a middle-click happened this frame
	// A right-click happened this frame. No mouse_down partner and no capture:
	// nothing in the program drags with the right button, so this is a press
	// event and not a gesture. The program clears it once per frame (main.odin)
	// rather than relying on a consumer to claim it, which is what mouse_pressed
	// does -- a right press that lands where nothing reads it has no terminal
	// consumer to fall through to.
	mouse_right_pressed:  bool,
	// paths handed over by other instances this frame (see instance.odin);
	// copied out of the WM_COPYDATA payload, which is only valid during the call
	open_paths:    [OPEN_QUEUE][OPEN_PATH_MAX]u8,
	open_lens:     [OPEN_QUEUE]int,
	open_count:    int,
	// internal click-count tracking
	last_click_ms: u32,
	last_click_x:  i32,
	last_click_y:  i32,
	click_count:   int,
}

window_create :: proc(title: string, width, height: i32) -> ^Window {
	w := new(Window)
	w.width = width
	w.height = height

	hinstance := win.HINSTANCE(win.GetModuleHandleW(nil))

	// RegisterClassExW copies the class name, so a temp wstring is fine here.
	class_name := win.utf8_to_wstring(WINDOW_CLASS)

	// Resource id 1 in the ICON namespace, embedded by newtpad.rc (see that
	// file's comment) from src/platform/newtpad.ico. Setting both hIcon and
	// hIconSm here is what gives the *window* its icon — title bar, taskbar,
	// Alt+Tab — as opposed to the .exe's own file icon, which Explorer takes
	// straight from the resource without any code running at all. A LoadIconW
	// failure (e.g. a corrupt or missing resource) yields a nil HICON, which
	// Windows quietly falls back to a default system icon for, so this is not
	// worth failing the whole window creation over.
	app_icon := win.LoadIconW(hinstance, transmute(win.LPCWSTR)win.MAKEINTRESOURCEW(1))

	wc := win.WNDCLASSEXW {
		cbSize        = size_of(win.WNDCLASSEXW),
		style         = win.CS_HREDRAW | win.CS_VREDRAW | win.CS_OWNDC,
		lpfnWndProc   = wnd_proc,
		hInstance     = hinstance,
		// IDC_ARROW is an integer resource id typed as cstring; reinterpret it
		// as the wide-string form LoadCursorW expects.
		hCursor       = win.LoadCursorW(nil, transmute(win.wstring)win.IDC_ARROW),
		hIcon         = app_icon,
		hIconSm       = app_icon,
		lpszClassName = class_name,
	}
	win.RegisterClassExW(&wc)

	// Loaded once. IDC_* are integer resource ids typed as cstring; reinterpret
	// them as the wide-string form LoadCursorW expects.
	w.cursors[.Arrow] = win.LoadCursorW(nil, transmute(win.wstring)win.IDC_ARROW)
	w.cursors[.Hand] = win.LoadCursorW(nil, transmute(win.wstring)win.IDC_HAND)
	w.cursors[.IBeam] = win.LoadCursorW(nil, transmute(win.wstring)win.IDC_IBEAM)
	w.cursors[.SizeWE] = win.LoadCursorW(nil, transmute(win.wstring)win.IDC_SIZEWE)

	// No AdjustWindowRectEx: WM_NCCALCSIZE gives this window a client area equal
	// to its whole window rect, so there is no frame to add. (It was also the
	// non-DPI variant, returning primary-monitor frame metrics.)
	//
	// The size here is provisional. CW_USEDEFAULT means the target monitor — and
	// therefore the DPI — isn't knowable until the window exists, so we create at
	// the 96-DPI size and rescale immediately below.
	w.dpi = DPI_MIN

	// NOT WS_VISIBLE. The window is created hidden and shown by window_show
	// once the first frame has been presented.
	//
	// Measured 2026-07-31 on real desktop pixels (docs/reported-bugs.md, "white
	// box for a split second"): with WS_VISIBLE here the window appeared 20 ms
	// into startup, DWM faded it to solid white by ~85 ms, and it stayed white
	// until the first present at ~220 ms -- a 196 ms white box, on every build
	// back to v0.32.0. hbrBackground is deliberately still unset (an erase brush
	// would only choose the colour of the flash, not remove it); creating hidden
	// removes the gap itself. The cost being covered is gfx_init, which measured
	// 132-145 ms of that 196 -- D3D11 device + swapchain creation, which cannot
	// usefully be made faster and must simply not be watched.
	title_w := win.utf8_to_wstring(title)
	w.hwnd = win.CreateWindowExW(
		0,
		class_name,
		title_w,
		win.WS_OVERLAPPEDWINDOW,
		win.CW_USEDEFAULT,
		win.CW_USEDEFAULT,
		width,
		height,
		nil,
		nil,
		hinstance,
		w, // handed to WM_NCCREATE so wnd_proc can find this Window
	)

	// Now the window exists, so its monitor's DPI is knowable. Capturing here
	// rather than in WM_NCCREATE avoids the CW_USEDEFAULT position quirk and the
	// fact that w.hwnd is still nil that early; nothing before this point needs
	// the DPI (WM_NCCALCSIZE only reads system metrics when maximized, which a
	// freshly created WS_OVERLAPPEDWINDOW is not).
	w.dpi = clamp_dpi(win.GetDpiForWindow(w.hwnd))
	if w.dpi != DPI_MIN {
		sw := width * i32(w.dpi) / 96
		sh := height * i32(w.dpi) / 96
		// Don't hand back a window bigger than the monitor: at 300% a 1280x720
		// default becomes 3840x2160, which is the whole screen on a 4K laptop.
		if mi, ok := monitor_work_area(w.hwnd); ok {
			sw = min(sw, mi.right - mi.left)
			sh = min(sh, mi.bottom - mi.top)
		}
		win.SetWindowPos(w.hwnd, nil, 0, 0, sw, sh, win.SWP_NOMOVE | win.SWP_NOZORDER | win.SWP_NOACTIVATE)
	}

	// Custom frame: keep a 1px DWM frame extension for the drop shadow, and force
	// Win11 rounded corners. The caption itself is removed in WM_NCCALCSIZE.
	m := MARGINS{0, 0, 1, 0}
	DwmExtendFrameIntoClientArea(w.hwnd, &m)
	corner := DWMWCP_ROUND
	DwmSetWindowAttribute(w.hwnd, DWMWA_WINDOW_CORNER_PREFERENCE, &corner, size_of(corner))
	// Force the frame to recompute now that our WM_NCCALCSIZE is in effect.
	win.SetWindowPos(w.hwnd, nil, 0, 0, 0, 0, win.SWP_FRAMECHANGED | win.SWP_NOMOVE | win.SWP_NOSIZE | win.SWP_NOZORDER)

	// Explorer drag-and-drop. Dropped paths join the same queue the
	// single-instance handoff uses (WM_COPYDATA below), so there is one producer
	// contract and one consumer rather than two to keep in sync.
	win.DragAcceptFiles(w.hwnd, true)
	return w
}

// Make the window visible. Called ONCE, immediately after the first frame has
// been presented -- see the WS_VISIBLE note in window_create for the measurement
// that put it there.
//
// SetForegroundWindow as well as ShowWindow because WS_VISIBLE at creation used
// to get the activation for free from the shell's launch rules; a window shown
// later is not covered by them, and starting behind the window the user launched
// from would be a worse bug than the flash. This process still holds the
// foreground right at this point (it was launched by the user seconds earlier),
// so the call is not the "steal focus" case the API refuses.
//
// Idempotent by construction: the caller latches it to the first frame, and
// ShowWindow/SetForegroundWindow on an already-visible foreground window are
// both no-ops anyway.
window_show :: proc(w: ^Window) {
	if w.hwnd == nil {return}
	win.ShowWindow(w.hwnd, win.SW_SHOW)
	win.SetForegroundWindow(w.hwnd)
}

// Take the window off screen at the START of shutdown, so the teardown that
// follows it is not something the user sits and watches.
//
// The mirror of window_show, and it exists for the measurement in the same bug
// report: WM_CLOSE to process exit measured 94-157 ms, of which only ~46-80 ms
// is inside main() -- the rest is CRT/DLL detach, chiefly the D3D11 and DXGI
// unload, which is not ours to speed up. All of it used to happen with the
// window still on screen and its message pump dead.
//
// Deliberately NOT a DestroyWindow: the crash handler can still be reached from
// the exit-path save below, message_error takes this hwnd as its parent, and a
// destroyed handle would make that message box parentless mid-crash. Hidden is
// enough -- the pixels are what the user is waiting on.
window_hide :: proc(w: ^Window) {
	if w.hwnd == nil {return}
	win.ShowWindow(w.hwnd, win.SW_HIDE)
}

// Is the window on screen? Exists so `windowshowtest` can assert the create-
// hidden / show-after-present ordering against the OS rather than against the
// source, and so nothing above the platform layer has to name IsWindowVisible.
window_is_visible :: proc(w: ^Window) -> bool {
	if w.hwnd == nil {return false}
	return bool(win.IsWindowVisible(w.hwnd))
}

// Live Ctrl state, for gestures that aren't key presses (Ctrl+wheel).
Cursor_Kind :: enum u8 {
	Arrow,
	Hand,
	IBeam,
	SizeWE, // horizontal resize, e.g. hovering/dragging the Markdown Split divider
}

// What the pointer should look like over the client area. Set per frame by the
// program; WM_SETCURSOR applies it. Setting it every frame is deliberate — the
// program decides from live state (is Ctrl held, is the pointer over a link)
// rather than trying to track enter/leave events.
window_set_cursor :: proc(w: ^Window, k: Cursor_Kind) {w.cursor = k}

// Headless seam. These three read the *physical* keyboard, not a queued event,
// so a frame built by a windowless measurement mode would still branch on
// whatever the person at the keyboard happens to be holding — Ctrl alone adds a
// link-underline quad per visible link to `drawcount`'s reading. A measurement
// whose value depends on that is not a measurement. Off in the product, where
// reading the real keyboard is exactly the point.
@(private)
keys_ignored: bool

keys_ignore_physical :: proc(on: bool) {keys_ignored = on}

key_ctrl_down :: proc() -> bool {
	if keys_ignored {return false}
	return (int(win.GetKeyState(win.VK_CONTROL)) & 0x8000) != 0
}

key_shift_down :: proc() -> bool {
	if keys_ignored {return false}
	return (int(win.GetKeyState(win.VK_SHIFT)) & 0x8000) != 0
}

key_alt_down :: proc() -> bool {
	if keys_ignored {return false}
	return (int(win.GetKeyState(win.VK_MENU)) & 0x8000) != 0
}

// Ask the window to close, exactly as the ✕ button does.
window_request_close :: proc(w: ^Window) {
	win.PostMessageW(w.hwnd, win.WM_CLOSE, 0, 0)
}

// Work area (screen minus taskbar) of the monitor this window is on.
@(private)
monitor_work_area :: proc(hwnd: win.HWND) -> (win.RECT, bool) {
	mon := win.MonitorFromWindow(hwnd, .MONITOR_DEFAULTTONEAREST)
	if mon == nil {
		return {}, false
	}
	mi: win.MONITORINFO
	mi.cbSize = size_of(mi)
	if !win.GetMonitorInfoW(mon, &mi) {
		return {}, false
	}
	return mi.rcWork, true
}

// Cursor position in this window's client coordinates (for title-bar button
// hover, since the buttons are non-client and don't get WM_MOUSEMOVE).
window_cursor_client :: proc(w: ^Window) -> (x, y: i32) {
	// A windowless Window (the headless render path: no hwnd, just a size) has
	// no client space to map into. ScreenToClient(nil) FAILS SILENTLY and leaves
	// the point in SCREEN coordinates, so every hover hit-test downstream —
	// tabs, the menu bar, the palette, the history panel — would read the
	// physical mouse position as though it were inside the window and light up
	// whatever it landed on. Report a point outside every widget instead, so a
	// headless frame draws no hover state at all.
	if w.hwnd == nil {return -1, -1}
	pt: win.POINT
	win.GetCursorPos(&pt)
	win.ScreenToClient(w.hwnd, &pt)
	return pt.x, pt.y
}

window_set_title :: proc(w: ^Window, title: string) {
	win.SetWindowTextW(w.hwnd, win.utf8_to_wstring(title, context.temp_allocator))
}

// Files handed to us by other instances since the last clear. The returned
// strings alias the window's buffers — use or copy them before clearing.
window_open_requests :: proc(w: ^Window, out: []string) -> int {
	n := min(w.open_count, len(out))
	for i in 0 ..< n {
		out[i] = string(w.open_paths[i][:w.open_lens[i]])
	}
	return n
}

window_clear_open_requests :: proc(w: ^Window) {w.open_count = 0}

// Would DragQueryFileW's true required length (queried with a nil buffer,
// which per MS docs reports the size *including* the null terminator) fit the
// fixed wide buffer WM_DROPFILES reads into? "contextless" so it can be called
// straight from wnd_proc, a raw WNDPROC with no Odin context of its own. Split
// out of the handler so the exact skip-vs-truncate boundary -- fits, exactly
// at the cap, one over it -- is something a test can drive directly, without
// a live HDROP.
drop_wide_fits :: proc "contextless" (need: int) -> bool {
	return need > 0 && need <= OPEN_PATH_MAX
}

// Convert a wide path DragQueryFileW has already copied into `out`, a
// caller-owned UTF-8 buffer. Calls WideCharToMultiByte directly rather than
// core:sys/windows's wstring_to_utf8: that helper is an ordinary
// "odin"-convention proc, so even though its buffer-based overload doesn't
// itself allocate, calling it still requires an Odin context at the call
// site -- which would force wnd_proc to fabricate one via
// runtime.default_context(), silently resetting context.assertion_failure_proc
// away from diag_assert_fail (main() sets that once so it propagates down the
// whole frame loop -- see main.odin). Going straight to the Win32 call keeps
// this "contextless" and sidesteps the question entirely.
//
// Fails (empty path, ok=false) if the conversion itself fails, or if the
// UTF-8 expansion of a wide string that fit `drop_wide_fits` still overflows
// `out` (three-byte-per-character scripts can do this well under the
// wide-character cap) -- split out so that case has a test too.
drop_path_convert :: proc "contextless" (wide: []u16, out: []u8) -> (path: string, ok: bool) {
	if len(wide) == 0 {return}
	need := win.WideCharToMultiByte(win.CP_UTF8, win.WC_ERR_INVALID_CHARS, win.wstring(raw_data(wide)), win.c_int(len(wide)), nil, 0, nil, nil)
	if need == 0 || int(need) > len(out) {return}
	got := win.WideCharToMultiByte(win.CP_UTF8, win.WC_ERR_INVALID_CHARS, win.wstring(raw_data(wide)), win.c_int(len(wide)), raw_data(out), need, nil, nil)
	if got == 0 {return}
	return string(out[:got]), true
}

// Drain the message queue once. Called at the top of each frame.
window_pump_events :: proc(w: ^Window) {
	msg: win.MSG
	for win.PeekMessageW(&msg, nil, 0, 0, win.PM_REMOVE) {
		if msg.message == win.WM_QUIT {
			w.should_close = true
		}
		win.TranslateMessage(&msg)
		win.DispatchMessageW(&msg)
	}
}

@(private)
wnd_proc :: proc "system" (hwnd: win.HWND, msg: win.UINT, wparam: win.WPARAM, lparam: win.LPARAM) -> win.LRESULT {
	// Stash the Window pointer in GWLP_USERDATA on creation, then recover it.
	if msg == win.WM_NCCREATE {
		cs := (^win.CREATESTRUCTW)(uintptr(lparam))
		win.SetWindowLongPtrW(hwnd, win.GWLP_USERDATA, win.LONG_PTR(uintptr(cs.lpCreateParams)))
		return win.DefWindowProcW(hwnd, msg, wparam, lparam)
	}

	w := (^Window)(uintptr(win.GetWindowLongPtrW(hwnd, win.GWLP_USERDATA)))
	if w == nil {
		return win.DefWindowProcW(hwnd, msg, wparam, lparam)
	}

	switch msg {
	case win.WM_CLOSE, win.WM_DESTROY:
		w.should_close = true
		return 0
	case win.WM_COPYDATA:
		// Another instance handing us a file to open. The payload is only valid
		// for the duration of this call, so copy it out now.
		cds := (^win.COPYDATASTRUCT)(uintptr(lparam))
		if cds == nil || cds.dwData != OPEN_REQUEST || cds.lpData == nil {break}
		n := int(cds.cbData)
		if n > 0 && n <= OPEN_PATH_MAX && w.open_count < OPEN_QUEUE {
			copy(w.open_paths[w.open_count][:], (cast([^]u8)cds.lpData)[:n])
			w.open_lens[w.open_count] = n
			w.open_count += 1
		}
		return 1
	case win.WM_DROPFILES:
		// Explorer drop. Same queue, same cap, same overflow rule as WM_COPYDATA
		// above — one producer contract, one consumer.
		//
		// No Odin context needed: DragQueryFileW is a raw Win32 call, and
		// drop_path_convert writes straight into a stack buffer, so nothing
		// here allocates or reads `context`. That matters because wnd_proc is
		// invoked directly by the OS as a raw WNDPROC and has no context
		// flowing in the way an ordinary call gets one -- establishing one
		// with `context = runtime.default_context()` (the fix that made this
		// compile originally) is not free: it would silently reset
		// context.assertion_failure_proc away from diag_assert_fail, which
		// main() sets once specifically so it propagates down the whole frame
		// loop's context (see main.odin). A panic or bounds check hit from in
		// here would then skip the crash/log path the rest of the app gets.
		// Staying context-free sidesteps the question rather than getting it
		// wrong; on_resize/on_dpi in main.odin call default_context() too, but
		// they live in package main and can reassign assertion_failure_proc
		// there directly -- this file (package platform) cannot reach
		// diag_assert_fail without inverting the platform/program layering.
		hdrop := win.HDROP(uintptr(wparam))
		n := int(win.DragQueryFileW(hdrop, 0xFFFFFFFF, nil, 0))
		for i in 0 ..< n {
			if w.open_count >= OPEN_QUEUE {break} // overflow is dropped, as documented

			// wbuf is sized in wide characters; OPEN_PATH_MAX bounds UTF-8
			// bytes for the queue slot below, a different unit entirely.
			// Query the true required length before ever calling with a real
			// buffer -- DragQueryFileW truncates silently into a too-small
			// one and returns only the count it managed to copy, with no way
			// to tell a genuine 1023-wide-char path from one clipped down to
			// it. Skip rather than truncate.
			need := int(win.DragQueryFileW(hdrop, u32(i), nil, 0))
			if !drop_wide_fits(need) {continue}

			wbuf: [OPEN_PATH_MAX]u16
			got := win.DragQueryFileW(hdrop, u32(i), &wbuf[0], u32(len(wbuf)))
			if got == 0 {continue}

			u8buf: [OPEN_PATH_MAX]u8
			s, ok := drop_path_convert(wbuf[:got], u8buf[:])
			if !ok {continue} // conversion failed, or UTF-8 expansion overflowed u8buf
			copy(w.open_paths[w.open_count][:], s)
			w.open_lens[w.open_count] = len(s)
			w.open_count += 1
		}
		win.DragFinish(hdrop)
		return 0
	case win.WM_NCCALCSIZE:
		if wparam == 0 {
			break // wParam==FALSE: let DefWindowProc handle it
		}
		// Remove the caption: leave the client rect = full window rect. When
		// maximized, inset by the frame so we don't overflow the monitor/taskbar.
		if bool(win.IsZoomed(hwnd)) {
			p := (^NCCALCSIZE_PARAMS)(uintptr(lparam))
			// ...ForDpi: the plain GetSystemMetrics returns primary-monitor values
			// once the process is per-monitor aware, so a window maximized on a
			// different-DPI monitor would inset by the wrong amount and either
			// overflow the taskbar or fall short of it.
			fx := win.GetSystemMetricsForDpi(win.SM_CXFRAME, w.dpi) + win.GetSystemMetricsForDpi(win.SM_CXPADDEDBORDER, w.dpi)
			fy := win.GetSystemMetricsForDpi(win.SM_CYFRAME, w.dpi) + win.GetSystemMetricsForDpi(win.SM_CXPADDEDBORDER, w.dpi)
			p.rgrc[0].left += fx
			p.rgrc[0].right -= fx
			p.rgrc[0].top += fy
			p.rgrc[0].bottom -= fy
		}
		return 0
	case win.WM_GETMINMAXINFO:
		// Scaled at the moment it is asked, not cached: this arrives before the
		// first WM_DPICHANGED on a non-96 monitor, and it arrives again after
		// each one, so reading the window's current DPI here is both simpler and
		// more correct than keeping a mirrored value in step.
		mmi := (^win.MINMAXINFO)(uintptr(lparam))
		mmi.ptMinTrackSize.x, mmi.ptMinTrackSize.y = window_min_size(w.dpi)
		return 0
	case win.WM_DPICHANGED:
		// Order matters. The SetWindowPos below sends WM_NCCALCSIZE and WM_SIZE
		// nested, and WM_SIZE runs the program's repaint callback — so the DPI and
		// the program's layout metrics must both already be current, or that
		// nested frame draws at the old scale against the new physical size and
		// WM_NCCALCSIZE insets using the old DPI.
		w.dpi = clamp_dpi(u32(wparam & 0xFFFF)) // LOWORD; X and Y are equal on Windows
		w.dpi_changed = true
		if w.on_dpi != nil {
			w.on_dpi(w.dpi_user)
		}
		// Honouring the suggested rect is not optional: ignoring it breaks
		// cursor-relative position when dragging across monitors and can put the
		// window into a recursive DPI-change cycle.
		if sug := (^win.RECT)(uintptr(lparam)); sug != nil {
			win.SetWindowPos(
				hwnd,
				nil,
				sug.left,
				sug.top,
				sug.right - sug.left,
				sug.bottom - sug.top,
				win.SWP_NOZORDER | win.SWP_NOACTIVATE,
			)
		}
		return 0
	case win.WM_NCHITTEST:
		pt := win.POINT{i32(i16(lparam & 0xFFFF)), i32(i16((lparam >> 16) & 0xFFFF))}
		win.ScreenToClient(hwnd, &pt)
		x, y, W, H := pt.x, pt.y, w.width, w.height
		if !bool(win.IsZoomed(hwnd)) {
			rb := window_resize_border(w)
			top, bot, lft, rgt := y < rb, y >= H - rb, x < rb, x >= W - rb
			switch {
			case top && lft:
				return HT_TOPLEFT
			case top && rgt:
				return HT_TOPRIGHT
			case bot && lft:
				return HT_BOTTOMLEFT
			case bot && rgt:
				return HT_BOTTOMRIGHT
			case top:
				return HT_TOP
			case bot:
				return HT_BOTTOM
			case lft:
				return HT_LEFT
			case rgt:
				return HT_RIGHT
			}
		}
		if y < w.titlebar_h {
			switch {
			case x >= W - window_caption_btn_w(w):
				return HT_CLOSE
			case x >= W - 2 * window_caption_btn_w(w):
				return HT_MAXBUTTON
			case x >= W - 3 * window_caption_btn_w(w):
				return HT_MINBUTTON
			case x < w.tabs_right:
				return HT_CLIENT // tabs / menu / + : the program handles the click
			}
			return HT_CAPTION // empty title-bar area: OS drag / double-click-maximize
		}
		return HT_CLIENT
	case win.WM_NCLBUTTONDOWN:
		switch wparam {
		case HT_MINBUTTON:
			win.ShowWindow(hwnd, win.SW_MINIMIZE)
			return 0
		case HT_MAXBUTTON:
			win.ShowWindow(hwnd, win.SW_RESTORE if bool(win.IsZoomed(hwnd)) else win.SW_MAXIMIZE)
			return 0
		case HT_CLOSE:
			win.PostMessageW(hwnd, win.WM_CLOSE, 0, 0)
			return 0
		}
	case win.WM_SIZE:
		w.width = i32(lparam & 0xFFFF)
		w.height = i32((lparam >> 16) & 0xFFFF)
		w.maximized = bool(win.IsZoomed(hwnd))
		if w.on_resize != nil {
			w.on_resize(w.resize_user) // repaint live during the modal resize loop
		} else {
			w.resized = true // pre-callback (startup): main handles the resize
		}
		return 0
	case win.WM_SETCURSOR:
		// Only the client area; the caption and borders keep the system's own
		// cursors (resize arrows at the edges) by falling through.
		if (u32(lparam) & 0xFFFF) == win.HTCLIENT {
			win.SetCursor(w.cursors[w.cursor])
			return 1
		}
	case win.WM_MOUSEWHEEL:
		// signed wheel delta lives in the high word of wParam
		raw := int(wparam >> 16) & 0xFFFF
		if raw >= 0x8000 {raw -= 0x10000}
		w.scroll_delta -= (raw / 120) * 3 // wheel-up scrolls up
		return 0
	case win.WM_CHAR:
		r := rune(wparam)
		// wparam is a UTF-16 code unit, not a rune. Anything outside the BMP -- an
		// emoji from Win+., most IME output above U+FFFF -- arrives as TWO WM_CHARs,
		// a high surrogate then a low one. Treating each as a rune inserted two lone
		// surrogates, which cannot be encoded as valid UTF-8: the document came out
		// mojibake and other editors read the saved file as corrupt.
		switch {
		case r >= 0xD800 && r <= 0xDBFF:
			w.pending_high = u16(r) // wait for the low half
			return 0
		case r >= 0xDC00 && r <= 0xDFFF:
			if w.pending_high == 0 {
				return 0 // orphan low surrogate: drop rather than insert garbage
			}
			r = 0x10000 + (rune(w.pending_high) - 0xD800) << 10 + (r - 0xDC00)
			w.pending_high = 0
		case:
			w.pending_high = 0 // a normal character cancels a dangling high half
		}
		if r >= 32 && r != 0x7F && w.char_count < len(w.chars) {
			w.chars[w.char_count] = r
			w.char_count += 1
		}
		return 0
	case win.WM_SYSCHAR:
		// Still swallowed so DefWindowProc doesn't beep or run its own mnemonic
		// lookup — but the character is captured first. Mnemonics must match on
		// the CHARACTER, not the virtual key: VK codes are layout-dependent (the
		// key printed "A" sends VK_Q on AZERTY), so a VK-based mnemonic would
		// silently address the wrong menu on non-US keyboards.
		if r := rune(wparam); r >= 32 && w.sys_char_count < len(w.sys_chars) {
			w.sys_chars[w.sys_char_count] = r
			w.sys_char_count += 1
		}
		return 0
	case win.WM_SYSKEYUP:
		// A bare Alt press-and-release is the "enter menu mode" gesture. It only
		// counts if no other key was pressed while Alt was held, which is what
		// separates it from Alt+Z. Returning 0 (rather than falling through)
		// stops DefWindowProc synthesizing WM_SYSCOMMAND/SC_KEYMENU — otherwise
		// the OS enters its own system-menu keyboard mode at the same time as
		// ours and eats the next letter (e.g. "n" = Minimize).
		if wparam == win.WPARAM(win.VK_MENU) {
			if !w.alt_used {w.alt_tapped = true}
			w.alt_down = false
			return 0
		}
	case win.WM_CAPTURECHANGED:
		// Capture lost to a dialog, the file picker, or another window. The
		// matching WM_LBUTTONUP goes there, not here, so without this mouse_down
		// stays true forever and the caret is dragged to the last known position
		// every frame — recoverable only by clicking again.
		w.mouse_down = false
		return 0
	case win.WM_ACTIVATE:
		// Losing activation must close any open menu. Without this, Alt+Tabbing
		// away leaves the dropdown drawn and the app in menu mode, tracking a
		// cursor that is now driving a different window.
		if (wparam & 0xFFFF) == 0 {
			w.focus_lost = true
			w.alt_down, w.alt_used, w.alt_tapped = false, false, false
			w.mouse_down = false // a drag cannot continue into another window
		}
		return 0
	case win.WM_KEYDOWN, win.WM_SYSKEYDOWN:
		// WM_SYSKEYDOWN carries Alt combos (e.g. Alt+Z). Translate and queue keys
		// we recognize; let DefWindowProc handle the rest (Alt+F4, Alt+Space, F10).
		if wparam == win.WPARAM(win.VK_MENU) {
			if !w.alt_down {w.alt_used = false} // fresh press
			w.alt_down = true
			return 0 // see WM_SYSKEYUP
		}
		if w.alt_down {w.alt_used = true} // Alt is a modifier here, not a tap
		key := vk_to_key(wparam)
		if key == .None || key_belongs_to_windows(key, msg == win.WM_SYSKEYDOWN) {
			break
		}
		ctrl := (int(win.GetKeyState(win.VK_CONTROL)) & 0x8000) != 0
		shift := (int(win.GetKeyState(win.VK_SHIFT)) & 0x8000) != 0
		alt := (int(win.GetKeyState(win.VK_MENU)) & 0x8000) != 0
		if w.key_count < len(w.key_events) {
			w.kbd_nav = true
			w.key_events[w.key_count] = {key, ctrl, shift, alt}
			w.key_count += 1
		}
		return 0
	case win.WM_LBUTTONDOWN:
		lp := u32(uintptr(lparam))
		xi := int(lp & 0xFFFF);if xi >= 0x8000 {xi -= 0x10000}
		yi := int(lp >> 16);if yi >= 0x8000 {yi -= 0x10000}
		x, y := i32(xi), i32(yi)
		now := GetTickCount()
		if now - w.last_click_ms < GetDoubleClickTime() && abs(x - w.last_click_x) < 4 && abs(y - w.last_click_y) < 4 {
			w.click_count += 1
			if w.click_count > 3 {w.click_count = 1}
		} else {
			w.click_count = 1
		}
		w.last_click_ms = now;w.last_click_x = x;w.last_click_y = y
		w.mouse_x = x;w.mouse_y = y
		w.kbd_nav = false
		w.mouse_pressed = true
		w.mouse_count = w.click_count
		w.mouse_shift = (int(win.GetKeyState(win.VK_SHIFT)) & 0x8000) != 0
		w.mouse_down = true
		if w.alt_down {w.alt_used = true} // Alt is a modifier here, not a tap
		win.SetCapture(hwnd)
		return 0
	case win.WM_MOUSEMOVE:
		if w.mouse_down {
			lp := u32(uintptr(lparam))
			xi := int(lp & 0xFFFF);if xi >= 0x8000 {xi -= 0x10000}
			yi := int(lp >> 16);if yi >= 0x8000 {yi -= 0x10000}
			w.mouse_x = i32(xi);w.mouse_y = i32(yi)
		}
		return 0
	case win.WM_LBUTTONUP:
		w.mouse_down = false
		win.ReleaseCapture()
		return 0
	case win.WM_MBUTTONDOWN:
		lp := u32(uintptr(lparam))
		xi := int(lp & 0xFFFF);if xi >= 0x8000 {xi -= 0x10000}
		yi := int(lp >> 16);if yi >= 0x8000 {yi -= 0x10000}
		w.mouse_x = i32(xi);w.mouse_y = i32(yi)
		w.mouse_middle_pressed = true
		return 0
	case win.WM_RBUTTONDOWN:
		// Same shape as the middle button above: record where it happened and set
		// the flag. `return 0` here only accounts for WM_RBUTTONDOWN itself -- it
		// does not stop WM_CONTEXTMENU, which Windows raises from the UP message
		// (WM_RBUTTONUP, or WM_NCRBUTTONUP for a non-client click), not the down
		// one. This file has no case for either UP message, so it falls through to
		// DefWindowProcW unchanged and WM_CONTEXTMENU still fires. That is
		// harmless to verify from here: this window is never given a menu (no
		// SetMenu or CreateMenu call anywhere in this file), so DefWindowProc's
		// default WM_CONTEXTMENU handling -- open the window's menu at the click
		// point -- has no menu to open.
		lp := u32(uintptr(lparam))
		xi := int(lp & 0xFFFF);if xi >= 0x8000 {xi -= 0x10000}
		yi := int(lp >> 16);if yi >= 0x8000 {yi -= 0x10000}
		w.mouse_x = i32(xi);w.mouse_y = i32(yi)
		// kbd_nav, same as WM_LBUTTONDOWN above: a right press is mouse input same
		// as a left one, and the focus ring UI spec 18 gates on this is not
		// supposed to survive ANY click.
		w.kbd_nav = false
		w.mouse_right_pressed = true
		return 0
	}
	return win.DefWindowProcW(hwnd, msg, wparam, lparam)
}
