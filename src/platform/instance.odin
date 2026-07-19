// Layer: platform — single-instance ownership and the cross-process "open this
// file" hand-off.
//
// A second launch (Explorer double-click, `newtpad foo.txt`) must not become a
// second process: two instances would race on the one session file and the
// shared backups directory and lose unsaved buffers. Instead the second launch
// finds the running window, hands it the path over WM_COPYDATA, focuses it, and
// exits — the file lands as a new tab in the window the user already has.
package platform

import win "core:sys/windows"

foreign import kernel32_inst "system:Kernel32.lib"
foreign import user32_inst "system:User32.lib"

// Not present in core:sys/windows; hand-declare.
@(default_calling_convention = "system")
foreign kernel32_inst {
	CreateMutexW :: proc(attrs: rawptr, initial_owner: win.BOOL, name: win.wstring) -> win.HANDLE ---
}
@(default_calling_convention = "system")
foreign user32_inst {
	// Lets the process we're about to hand a file to steal focus from us.
	AllowSetForegroundWindow :: proc(pid: win.DWORD) -> win.BOOL ---
}

// Payload tag on the WM_COPYDATA hand-off, so we ignore anything else that
// happens to reach our window. Arbitrary but fixed ('NEWT').
OPEN_REQUEST :: win.ULONG_PTR(0x4E455754)

// Session-local (per user, per login session), not global: two different users
// on one machine each get their own Newtpad.
@(private = "file")
MUTEX_NAME :: "Local\\NewtpadSingleInstance"

@(private = "file")
instance_mutex: win.HANDLE

// Claim this user's single Newtpad instance. True = we are the primary and own
// the session file; false = another instance is already live. Windows releases
// the mutex on process exit, so a crash doesn't wedge the next launch.
instance_claim :: proc() -> bool {
	instance_mutex = CreateMutexW(nil, win.BOOL(false), win.utf8_to_wstring(MUTEX_NAME))
	if instance_mutex == nil {return true} // can't tell; behave as primary
	return win.GetLastError() != win.ERROR_ALREADY_EXISTS
}

// Hand `path` (empty = just focus) to the running instance. False if no window
// was found — the owner is still starting up or already shutting down, and the
// caller should run normally rather than drop the file on the floor.
instance_send_open :: proc(path: string) -> bool {
	hwnd := win.FindWindowW(win.utf8_to_wstring(WINDOW_CLASS), nil)
	if hwnd == nil {return false}

	// The receiving instance has its own working directory, so a relative path
	// from a shell would resolve differently there. Send an absolute one.
	abs := transmute([]u8)path_absolute(path)
	if len(abs) > 0 {
		cds := win.COPYDATASTRUCT {
			dwData = OPEN_REQUEST,
			cbData = win.DWORD(len(abs)),
			lpData = raw_data(abs),
		}
		pid: win.DWORD
		win.GetWindowThreadProcessId(hwnd, &pid)
		AllowSetForegroundWindow(pid)
		// Synchronous: the target copies the bytes out before this returns.
		win.SendMessageW(hwnd, win.WM_COPYDATA, 0, win.LPARAM(uintptr(&cds)))
	}

	if bool(win.IsIconic(hwnd)) {win.ShowWindow(hwnd, win.SW_RESTORE)}
	win.SetForegroundWindow(hwnd)
	return true
}

// Absolute form of `path`, temp-allocated. Falls back to the input unchanged if
// the OS can't resolve it (the caller's open attempt reports the real error).
@(private = "file")
path_absolute :: proc(path: string) -> string {
	if path == "" {return ""}
	buf: [4096]u16
	n := win.GetFullPathNameW(win.utf8_to_wstring(path), u32(len(buf)), win.LPCWSTR(&buf[0]), nil)
	if n == 0 || int(n) >= len(buf) {return path}
	s, err := win.wstring_to_utf8(win.wstring(&buf[0]), int(n), context.temp_allocator)
	return path if err != nil else s
}
