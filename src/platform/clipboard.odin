// Layer: platform — Windows clipboard (CF_UNICODETEXT), UTF-8 at the seam.
package platform

import win "core:sys/windows"

clipboard_set_text :: proc(owner: win.HWND, s: string) {
	if !win.OpenClipboard(owner) {
		return
	}
	defer win.CloseClipboard()
	win.EmptyClipboard()

	ws := win.utf8_to_wstring(s, context.temp_allocator) // null-terminated UTF-16
	src := ([^]u16)(ws)
	n := 0
	for src[n] != 0 {n += 1} // count units, excluding null

	h := win.GlobalAlloc(win.GMEM_MOVEABLE, uint(n + 1) * 2)
	if h == nil {
		return
	}
	dst := ([^]u16)(win.GlobalLock(win.HGLOBAL(h)))
	if dst == nil {
		return
	}
	for i in 0 ..= n {dst[i] = src[i]} // include the terminating null
	win.GlobalUnlock(win.HGLOBAL(h))
	win.SetClipboardData(win.CF_UNICODETEXT, win.HANDLE(h))
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
