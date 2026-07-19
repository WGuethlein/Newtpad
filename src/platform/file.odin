// Layer: platform — read-only file access honoring the locked buffer decision:
// copy small files into private memory (crash-immune), memory-map large ones
// (instant open, ~0 private memory). Always share-everything so we never lock
// the user's file (delete + rename verified to work while mapped; see bench/).
package platform

import "core:os"
import "core:strings"
import win "core:sys/windows"

// Not in core:sys/windows; hand-declared.
foreign import kernel32_fs "system:Kernel32.lib"
@(default_calling_convention = "system")
foreign kernel32_fs {
	GetDriveTypeW :: proc(lpRootPathName: win.wstring) -> u32 ---
}
DRIVE_FIXED :: 3

FILE_MMAP_THRESHOLD :: 16 * 1024 * 1024 // copy below, mmap above

// mmap only on a local fixed drive. Drive-letter paths are checked by volume
// type; UNC / relative paths are treated as non-fixed (copy, crash-safe).
@(private = "file")
drive_is_fixed :: proc(path: string) -> bool {
	if len(path) >= 3 && path[1] == ':' {
		root := win.utf8_to_wstring(path[:3], context.temp_allocator) // "C:\"
		return GetDriveTypeW(root) == DRIVE_FIXED
	}
	return false
}

File_View :: struct {
	bytes:  []u8, // the file's bytes (mapped or copied); empty for a 0-byte file
	hmap:   win.HANDLE,
	view:   rawptr,
	mapped: bool,
}

file_open_readonly :: proc(path: string) -> (fv: File_View, ok: bool) {
	info, serr := os.stat(path, context.allocator)
	if serr != nil {
		return
	}
	n := int(info.size)
	if n == 0 {
		return fv, true // empty file: bytes = nil
	}

	// Copy (crash-immune) unless the file is large AND on a local fixed drive.
	// mmap'd pages on a network/removable volume fault - and block the faulting
	// thread for the SMB timeout - if the media drops; copying avoids that.
	if n < FILE_MMAP_THRESHOLD || !drive_is_fixed(path) {
		data, rerr := os.read_entire_file(path, context.allocator)
		if rerr != nil {
			return
		}
		fv.bytes = data
		return fv, true
	}

	// Large: memory-map, share everything, then close the file handle. The
	// mapping keeps its own reference; other programs can still delete/rename.
	wpath := win.utf8_to_wstring(path)
	hfile := win.CreateFileW(
		wpath,
		win.GENERIC_READ,
		win.FILE_SHARE_READ | win.FILE_SHARE_WRITE | win.FILE_SHARE_DELETE,
		nil,
		win.OPEN_EXISTING,
		win.FILE_ATTRIBUTE_NORMAL,
		nil,
	)
	if hfile == win.INVALID_HANDLE_VALUE {
		return
	}
	fv.hmap = win.CreateFileMappingW(hfile, nil, win.PAGE_READONLY, 0, 0, nil)
	if fv.hmap == nil {
		win.CloseHandle(hfile)
		return
	}
	fv.view = win.MapViewOfFile(fv.hmap, win.FILE_MAP_READ, 0, 0, 0)
	win.CloseHandle(hfile)
	if fv.view == nil {
		win.CloseHandle(fv.hmap)
		fv.hmap = nil
		return
	}
	fv.bytes = (cast([^]u8)fv.view)[:n]
	fv.mapped = true
	return fv, true
}

// Write data to a sibling temp file then atomically rename it over `path`, so a
// crash mid-write never corrupts the original. Never holds `path` open. Works
// even when the original is memory-mapped (delete+rename succeed; see bench/).
file_write_atomic :: proc(path: string, data: []u8) -> bool {
	err := file_write_atomic_err(path, data)
	return err == .None
}

// As file_write_atomic, but says why it failed. The replace step fails with
// ERROR_ACCESS_DENIED whenever another process holds the target open — which is
// the normal state of a log being written by a service, i.e. exactly the file a
// user is most likely to be editing when this matters.
file_write_atomic_err :: proc(path: string, data: []u8) -> Write_Error {
	tmp := strings.concatenate({path, ".newtpad~"}, context.temp_allocator)
	wtmp := win.utf8_to_wstring(tmp, context.temp_allocator)

	h := win.CreateFileW(wtmp, win.GENERIC_WRITE, 0, nil, win.CREATE_ALWAYS, win.FILE_ATTRIBUTE_NORMAL, nil)
	if h == win.INVALID_HANDLE_VALUE {
		return .Create_Temp
	}
	total := 0
	for total < len(data) {
		written: win.DWORD
		if !win.WriteFile(h, raw_data(data[total:]), win.DWORD(len(data) - total), &written, nil) {
			break
		}
		if written == 0 {
			break
		}
		total += int(written)
	}
	win.CloseHandle(h)
	if total != len(data) {
		win.DeleteFileW(wtmp)
		return .Write
	}

	wdst := win.utf8_to_wstring(path, context.temp_allocator)
	if !win.MoveFileExW(wtmp, wdst, win.MOVEFILE_REPLACE_EXISTING) {
		win.DeleteFileW(wtmp)
		return .Replace
	}
	return .None
}

// Build a comdlg filter string (label\0pattern\0...\0\0) as wide chars.
@(private = "file")
build_filter :: proc(dst: ^[256]u16, parts: []string) {
	i := 0
	for s in parts {
		for c in s {
			if i < len(dst) - 2 {
				dst[i] = u16(c)
				i += 1
			}
		}
		dst[i] = 0
		i += 1
	}
	dst[i] = 0
}

// Native Save-As dialog with file-type filters and a default .txt extension
// (so a name typed without an extension becomes name.txt). Returns the chosen
// path (heap-allocated) or ok=false if cancelled.
file_save_dialog :: proc(owner: win.HWND) -> (path: string, ok: bool) {
	buf: [520]u16
	fbuf: [256]u16
	build_filter(
		&fbuf,
		{
			"Text Documents (*.txt)",
			"*.txt",
			"JSON (*.json)",
			"*.json",
			"Markdown (*.md)",
			"*.md",
			"Log Files (*.log)",
			"*.log",
			"All Files (*.*)",
			"*.*",
		},
	)
	defext := [?]u16{'t', 'x', 't', 0}
	ofn := win.OPENFILENAMEW {
		lStructSize  = size_of(win.OPENFILENAMEW),
		hwndOwner    = owner,
		lpstrFile    = win.wstring(&buf[0]),
		nMaxFile     = u32(len(buf)),
		lpstrFilter  = win.wstring(&fbuf[0]),
		nFilterIndex = 1,
		lpstrDefExt  = win.wstring(&defext[0]),
		Flags        = u32(win.OFN_OVERWRITEPROMPT | win.OFN_EXPLORER | win.OFN_NOCHANGEDIR),
	}
	if !win.GetSaveFileNameW(&ofn) {
		return "", false
	}
	n := 0
	for n < len(buf) && buf[n] != 0 {n += 1}
	// temp-allocated: the caller (doc_save) clones it into the doc; freed at frame end.
	s, err := win.utf16_to_utf8(buf[:n], context.temp_allocator)
	if err != nil {
		return "", false
	}
	return s, true
}

// Native Open dialog. Returns the chosen path (temp-allocated; the caller clones
// it) or ok=false if cancelled. The file must exist (OFN_FILEMUSTEXIST).
file_open_dialog :: proc(owner: win.HWND) -> (path: string, ok: bool) {
	buf: [520]u16
	fbuf: [256]u16
	build_filter(&fbuf, {"All Files (*.*)", "*.*", "Text (*.txt;*.md;*.log)", "*.txt;*.md;*.log", "Data (*.json;*.xml;*.yaml;*.toml;*.csv)", "*.json;*.xml;*.yaml;*.toml;*.csv"})
	ofn := win.OPENFILENAMEW {
		lStructSize  = size_of(win.OPENFILENAMEW),
		hwndOwner    = owner,
		lpstrFile    = win.wstring(&buf[0]),
		nMaxFile     = u32(len(buf)),
		lpstrFilter  = win.wstring(&fbuf[0]),
		nFilterIndex = 1,
		Flags        = u32(win.OFN_FILEMUSTEXIST | win.OFN_EXPLORER | win.OFN_NOCHANGEDIR),
	}
	if !win.GetOpenFileNameW(&ofn) {
		return "", false
	}
	n := 0
	for n < len(buf) && buf[n] != 0 {n += 1}
	s, err := win.utf16_to_utf8(buf[:n], context.temp_allocator)
	if err != nil {
		return "", false
	}
	return s, true
}

// Not all in core:sys/windows; hand-declared constants for MessageBoxW.
@(private = "file")
MB_YESNOCANCEL :: 0x00000003
@(private = "file")
MB_ICONWARNING :: 0x00000030
@(private = "file")
ID_YES :: 6
@(private = "file")
ID_NO :: 7

Save_Choice :: enum {
	Save,
	Discard,
	Cancel,
}

// Ask whether to save changes to `name` before closing. Yes/No/Cancel.
// Report a failure the user must know about. Release builds are -subsystem:windows,
// so anything printed to stderr is discarded — a failed save reported that way is
// indistinguishable from a successful one.
message_error :: proc(owner: win.HWND, text: string) {
	wmsg := win.utf8_to_wstring(text, context.temp_allocator)
	wcap := win.utf8_to_wstring("Newtpad", context.temp_allocator)
	win.MessageBoxW(owner, wmsg, wcap, MB_ICONWARNING)
}

// Why a write failed, so the caller can say something better than "failed".
Write_Error :: enum {
	None,
	Create_Temp, // couldn't create the temp file (permissions, missing directory)
	Write, // the write itself failed (disk full)
	Replace, // couldn't replace the target — usually another process holds it open
}

write_error_text :: proc(e: Write_Error, path: string) -> string {
	switch e {
	case .Create_Temp:
		return strings.concatenate({"Could not create a temporary file next to\n", path, "\n\nCheck permissions on that folder."}, context.temp_allocator)
	case .Write:
		return strings.concatenate({"Could not write all data to\n", path, "\n\nThe disk may be full."}, context.temp_allocator)
	case .Replace:
		return strings.concatenate({"Could not replace\n", path, "\n\nAnother program may have the file open. Your changes have NOT been saved."}, context.temp_allocator)
	case .None:
		return ""
	}
	return ""
}

confirm_discard :: proc(owner: win.HWND, name: string) -> Save_Choice {
	msg := strings.concatenate({"Save changes to ", name, "?"}, context.temp_allocator)
	wmsg := win.utf8_to_wstring(msg, context.temp_allocator)
	wcap := win.utf8_to_wstring("Newtpad", context.temp_allocator)
	switch win.MessageBoxW(owner, wmsg, wcap, MB_YESNOCANCEL | MB_ICONWARNING) {
	case ID_YES:
		return .Save
	case ID_NO:
		return .Discard
	}
	return .Cancel
}

file_close :: proc(fv: ^File_View) {
	if fv.mapped {
		if fv.view != nil {win.UnmapViewOfFile(fv.view)}
		if fv.hmap != nil {win.CloseHandle(fv.hmap)}
	} else if fv.bytes != nil {
		delete(fv.bytes)
	}
	fv^ = {}
}
