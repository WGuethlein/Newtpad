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
RESIZE_BORDER :: i32(6) // hit-test thickness of the resize edges
CAPTION_BTN_W :: i32(46) // width of each min/max/close button
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
	}
	if vk >= win.WPARAM('A') && vk <= win.WPARAM('Z') {
		return Key(u16(Key.A) + u16(vk - win.WPARAM('A')))
	}
	if vk >= win.WPARAM('0') && vk <= win.WPARAM('9') {
		return Key(u16(Key.Num0) + u16(vk - win.WPARAM('0')))
	}
	return .None
}

Window :: struct {
	hwnd:         win.HWND,
	width:        i32,
	height:       i32,
	should_close: bool,
	resized:      bool,
	maximized:    bool,
	// custom title bar geometry (set by the program each frame, read by the NC
	// hit-test): bar height and the x where the tab/menu region ends (left of it
	// is client, right of it up to the window buttons is a drag region).
	titlebar_h:   i32,
	tabs_right:   i32,
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
	// mouse (client coords)
	mouse_x:       i32,
	mouse_y:       i32,
	mouse_pressed: bool, // a press happened this frame
	mouse_count:   int, // 1 single, 2 double, 3 triple
	mouse_shift:   bool,
	mouse_down:    bool, // button held (dragging)
	mouse_middle_pressed: bool, // a middle-click happened this frame
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
	class_name := win.utf8_to_wstring("NewtpadWindowClass")

	wc := win.WNDCLASSEXW {
		cbSize        = size_of(win.WNDCLASSEXW),
		style         = win.CS_HREDRAW | win.CS_VREDRAW | win.CS_OWNDC,
		lpfnWndProc   = wnd_proc,
		hInstance     = hinstance,
		// IDC_ARROW is an integer resource id typed as cstring; reinterpret it
		// as the wide-string form LoadCursorW expects.
		hCursor       = win.LoadCursorW(nil, transmute(win.wstring)win.IDC_ARROW),
		lpszClassName = class_name,
	}
	win.RegisterClassExW(&wc)

	// Size the window so the *client* area is width x height.
	rect := win.RECT{0, 0, width, height}
	win.AdjustWindowRectEx(&rect, win.WS_OVERLAPPEDWINDOW, win.BOOL(false), 0)

	title_w := win.utf8_to_wstring(title)
	w.hwnd = win.CreateWindowExW(
		0,
		class_name,
		title_w,
		win.WS_OVERLAPPEDWINDOW | win.WS_VISIBLE,
		win.CW_USEDEFAULT,
		win.CW_USEDEFAULT,
		rect.right - rect.left,
		rect.bottom - rect.top,
		nil,
		nil,
		hinstance,
		w, // handed to WM_NCCREATE so wnd_proc can find this Window
	)

	// Custom frame: keep a 1px DWM frame extension for the drop shadow, and force
	// Win11 rounded corners. The caption itself is removed in WM_NCCALCSIZE.
	m := MARGINS{0, 0, 1, 0}
	DwmExtendFrameIntoClientArea(w.hwnd, &m)
	corner := DWMWCP_ROUND
	DwmSetWindowAttribute(w.hwnd, DWMWA_WINDOW_CORNER_PREFERENCE, &corner, size_of(corner))
	// Force the frame to recompute now that our WM_NCCALCSIZE is in effect.
	win.SetWindowPos(w.hwnd, nil, 0, 0, 0, 0, win.SWP_FRAMECHANGED | win.SWP_NOMOVE | win.SWP_NOSIZE | win.SWP_NOZORDER)
	return w
}

// Cursor position in this window's client coordinates (for title-bar button
// hover, since the buttons are non-client and don't get WM_MOUSEMOVE).
window_cursor_client :: proc(w: ^Window) -> (x, y: i32) {
	pt: win.POINT
	win.GetCursorPos(&pt)
	win.ScreenToClient(w.hwnd, &pt)
	return pt.x, pt.y
}

window_set_title :: proc(w: ^Window, title: string) {
	win.SetWindowTextW(w.hwnd, win.utf8_to_wstring(title, context.temp_allocator))
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
	case win.WM_NCCALCSIZE:
		if wparam == 0 {
			break // wParam==FALSE: let DefWindowProc handle it
		}
		// Remove the caption: leave the client rect = full window rect. When
		// maximized, inset by the frame so we don't overflow the monitor/taskbar.
		if bool(win.IsZoomed(hwnd)) {
			p := (^NCCALCSIZE_PARAMS)(uintptr(lparam))
			fx := win.GetSystemMetrics(win.SM_CXFRAME) + win.GetSystemMetrics(win.SM_CXPADDEDBORDER)
			fy := win.GetSystemMetrics(win.SM_CYFRAME) + win.GetSystemMetrics(win.SM_CXPADDEDBORDER)
			p.rgrc[0].left += fx
			p.rgrc[0].right -= fx
			p.rgrc[0].top += fy
			p.rgrc[0].bottom -= fy
		}
		return 0
	case win.WM_NCHITTEST:
		pt := win.POINT{i32(i16(lparam & 0xFFFF)), i32(i16((lparam >> 16) & 0xFFFF))}
		win.ScreenToClient(hwnd, &pt)
		x, y, W, H := pt.x, pt.y, w.width, w.height
		if !bool(win.IsZoomed(hwnd)) {
			rb := RESIZE_BORDER
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
			case x >= W - CAPTION_BTN_W:
				return HT_CLOSE
			case x >= W - 2 * CAPTION_BTN_W:
				return HT_MAXBUTTON
			case x >= W - 3 * CAPTION_BTN_W:
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
	case win.WM_MOUSEWHEEL:
		// signed wheel delta lives in the high word of wParam
		raw := int(wparam >> 16) & 0xFFFF
		if raw >= 0x8000 {raw -= 0x10000}
		w.scroll_delta -= (raw / 120) * 3 // wheel-up scrolls up
		return 0
	case win.WM_CHAR:
		r := rune(wparam)
		if r >= 32 && r != 0x7F && w.char_count < len(w.chars) {
			w.chars[w.char_count] = r
			w.char_count += 1
		}
		return 0
	case win.WM_SYSCHAR:
		// Swallow Alt+key chars so DefWindowProc doesn't do a menu-mnemonic lookup
		// and beep (we have no menu bar). Alt combos are handled via WM_SYSKEYDOWN.
		return 0
	case win.WM_KEYDOWN, win.WM_SYSKEYDOWN:
		// WM_SYSKEYDOWN carries Alt combos (e.g. Alt+Z). Translate and queue keys
		// we recognize; let DefWindowProc handle the rest (Alt+F4, Alt+Space, F10).
		key := vk_to_key(wparam)
		if key == .None {
			break
		}
		ctrl := (int(win.GetKeyState(win.VK_CONTROL)) & 0x8000) != 0
		shift := (int(win.GetKeyState(win.VK_SHIFT)) & 0x8000) != 0
		alt := (int(win.GetKeyState(win.VK_MENU)) & 0x8000) != 0
		if w.key_count < len(w.key_events) {
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
		w.mouse_pressed = true
		w.mouse_count = w.click_count
		w.mouse_shift = (int(win.GetKeyState(win.VK_SHIFT)) & 0x8000) != 0
		w.mouse_down = true
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
	}
	return win.DefWindowProcW(hwnd, msg, wparam, lparam)
}
