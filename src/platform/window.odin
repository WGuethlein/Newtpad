// Layer: platform — all Win32/COM lives here and never leaks upward.
// This file owns the OS window and its message pump.
package platform

import win "core:sys/windows"

// A single top-level OS window. Platform types stay in this layer; upper
// layers see only this opaque handle and the procs below.
// Editor key commands queued from the message pump, drained once per frame.
Key_Cmd :: enum u8 {
	Left,
	Right,
	Up,
	Down,
	Home,
	End,
	PageUp,
	PageDown,
	Backspace,
	DeleteFwd,
	Enter,
	Undo,
	Redo,
}

Window :: struct {
	hwnd:         win.HWND,
	width:        i32,
	height:       i32,
	should_close: bool,
	resized:      bool,
	// input, drained once per frame by the program
	scroll_delta: int, // mouse-wheel lines this frame (+down / -up)
	key_cmds:     [64]Key_Cmd,
	key_count:    int,
	chars:        [64]rune, // printable characters typed this frame
	char_count:   int,
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
	return w
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
	case win.WM_SIZE:
		w.width = i32(lparam & 0xFFFF)
		w.height = i32((lparam >> 16) & 0xFFFF)
		w.resized = true
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
	case win.WM_KEYDOWN:
		ctrl := (int(win.GetKeyState(win.VK_CONTROL)) & 0x8000) != 0
		cmd: Key_Cmd
		has := true
		switch wparam {
		case win.VK_LEFT:
			cmd = .Left
		case win.VK_RIGHT:
			cmd = .Right
		case win.VK_UP:
			cmd = .Up
		case win.VK_DOWN:
			cmd = .Down
		case win.VK_HOME:
			cmd = .Home
		case win.VK_END:
			cmd = .End
		case win.VK_PRIOR:
			cmd = .PageUp
		case win.VK_NEXT:
			cmd = .PageDown
		case win.VK_BACK:
			cmd = .Backspace
		case win.VK_DELETE:
			cmd = .DeleteFwd
		case win.VK_RETURN:
			cmd = .Enter
		case win.VK_Z:
			cmd = .Undo;has = ctrl
		case win.VK_Y:
			cmd = .Redo;has = ctrl
		case:
			has = false
		}
		if has && w.key_count < len(w.key_cmds) {
			w.key_cmds[w.key_count] = cmd
			w.key_count += 1
		}
		return 0
	}
	return win.DefWindowProcW(hwnd, msg, wparam, lparam)
}
