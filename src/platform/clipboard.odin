// Layer: platform — Windows clipboard (CF_UNICODETEXT), UTF-8 at the seam.
package platform

import win "core:sys/windows"

// Returns false when the text did not reach the clipboard, so a CUT can refuse to
// delete what it failed to copy. Every early return here used to be silent, and one
// of them was not a return at all -- see the nil check below.
clipboard_set_text :: proc(owner: win.HWND, s: string) -> (ok: bool) {
	// EVERYTHING THAT CAN FAIL HAPPENS BEFORE THE CLIPBOARD IS OPENED.
	//
	// This used to Open, Empty, and only then convert -- so a copy that could not
	// be converted had already destroyed whatever the user had on the clipboard
	// before it discovered it had nothing to replace it with. Found by the test
	// that covers the nil-conversion fix below: it wiped a sentinel a later case
	// in the same mode depended on, which is exactly what it would do to a user.
	ws := win.utf8_to_wstring(s, context.temp_allocator) // null-terminated UTF-16
	if ws == nil {
		// utf8_to_utf16 passes MB_ERR_INVALID_CHARS, so MultiByteToWideChar returns
		// 0 -- and this nil -- on ANY invalid UTF-8 byte. That is reachable: encoding
		// detection sniffs only the head of the file, so a document whose first window
		// is clean UTF-8 but which carries a stray high byte further down is held as
		// .UTF8 with those raw bytes intact. Dereferencing this nil crashed the whole
		// process on Ctrl+C.
		return false
	}
	src := ([^]u16)(ws)
	n := 0
	for src[n] != 0 {n += 1} // count units, excluding null

	h := win.GlobalAlloc(win.GMEM_MOVEABLE, uint(n + 1) * 2)
	if h == nil {
		return false
	}
	dst := ([^]u16)(win.GlobalLock(win.HGLOBAL(h)))
	if dst == nil {
		win.GlobalFree(win.HGLOBAL(h)) // the clipboard never took ownership
		return false
	}
	for i in 0 ..= n {dst[i] = src[i]} // include the terminating null
	win.GlobalUnlock(win.HGLOBAL(h))

	if !win.OpenClipboard(owner) {
		// Routine, not exotic: any clipboard manager, an RDP session, or another
		// app mid-copy holds it briefly.
		win.GlobalFree(win.HGLOBAL(h))
		return false
	}
	defer win.CloseClipboard()
	win.EmptyClipboard()
	if win.SetClipboardData(win.CF_UNICODETEXT, win.HANDLE(h)) == nil {
		win.GlobalFree(win.HGLOBAL(h)) // ownership only transfers on success
		return false
	}
	return true
}

clipboard_get_text :: proc(owner: win.HWND, allocator := context.allocator) -> (text: string, ok: bool) {
	if !win.OpenClipboard(owner) {
		return "", false
	}
	defer win.CloseClipboard()

	h := win.GetClipboardData(win.CF_UNICODETEXT)
	if h == nil {
		return "", false
	}
	p := win.GlobalLock(win.HGLOBAL(h))
	if p == nil {
		return "", false
	}
	defer win.GlobalUnlock(win.HGLOBAL(h))

	src := ([^]u16)(p)
	n := 0
	for src[n] != 0 {n += 1}
	s, err := win.utf16_to_utf8(src[:n], allocator)
	if err != nil {
		return "", false
	}
	return s, true
}
