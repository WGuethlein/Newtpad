// Layer: platform — read-only file access honoring the locked buffer decision:
// copy small files into private memory (crash-immune), memory-map large ones
// (instant open, ~0 private memory). Always share-everything so we never lock
// the user's file (delete + rename verified to work while mapped; see bench/).
package platform

import "core:fmt"
import "core:os"
import "core:strings"
import win "core:sys/windows"

// Not in core:sys/windows; hand-declared.
foreign import kernel32_fs "system:Kernel32.lib"
@(default_calling_convention = "system")
foreign kernel32_fs {
	GetDriveTypeW :: proc(lpRootPathName: win.wstring) -> u32 ---
	ReplaceFileW :: proc(lpReplacedFileName, lpReplacementFileName, lpBackupFileName: win.wstring, dwReplaceFlags: win.DWORD, lpExclude, lpReserved: rawptr) -> win.BOOL ---
}
DRIVE_FIXED :: 3
REPLACEFILE_WRITE_THROUGH :: win.DWORD(0x1)
REPLACEFILE_IGNORE_MERGE_ERRORS :: win.DWORD(0x2)

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

	// Large: memory-map, share everything, then close the file handle.
	//
	// CAUTION: a mapping is NOT free of consequences for other programs. While a
	// user-mapped section is open, Windows fails truncation, deletion and
	// replacement of that file with ERROR_USER_MAPPED_FILE (1224) regardless of
	// the sharing mode requested here. A service rotating a log therefore cannot
	// roll it while we hold the mapping. The document layer detaches to a private
	// copy as soon as it detects the file changing (see doc_detach_mapping), which
	// is what keeps "never lock the user's file" true in practice.
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
// An opaque identity for "the file as we last saw it". Compared with ==; the
// program layer never sees a FILETIME (platform types don't leak upward).
File_Stamp :: struct {
	mtime: u64,
	size:  i64,
	ok:    bool, // false when the file could not be stat'd (missing, unreachable)
}

// Cheap stat with no handle held open. Safe to call from a worker: on a dropped
// network share this blocks for the redirector timeout, which is exactly why it
// must not run on the UI thread.
file_stamp :: proc(path: string) -> File_Stamp {
	wpath := win.utf8_to_wstring(path, context.temp_allocator)
	d: win.WIN32_FILE_ATTRIBUTE_DATA
	if !win.GetFileAttributesExW(wpath, win.GetFileExInfoStandard, &d) {
		return File_Stamp{}
	}
	return File_Stamp {
		mtime = (u64(d.ftLastWriteTime.dwHighDateTime) << 32) | u64(d.ftLastWriteTime.dwLowDateTime),
		size = (i64(d.nFileSizeHigh) << 32) | i64(d.nFileSizeLow),
		ok = true,
	}
}

// Read [offset, offset+count) with no handle retained. Used to pick up bytes
// appended to a file we already have open — cheaper and safer than remapping,
// and it holds no lock.
file_read_range :: proc(path: string, offset: i64, count: int, allocator := context.allocator) -> ([]u8, bool) {
	if count <= 0 {
		return nil, true
	}
	wpath := win.utf8_to_wstring(path, context.temp_allocator)
	h := win.CreateFileW(
		wpath,
		win.GENERIC_READ,
		win.FILE_SHARE_READ | win.FILE_SHARE_WRITE | win.FILE_SHARE_DELETE,
		nil,
		win.OPEN_EXISTING,
		win.FILE_ATTRIBUTE_NORMAL,
		nil,
	)
	if h == win.INVALID_HANDLE_VALUE {
		return nil, false
	}
	defer win.CloseHandle(h)
	// SetFilePointerEx, not SetFilePointer: the latter returns the new low dword,
	// and INVALID_SET_FILE_POINTER (0xFFFFFFFF) is a legal one -- any offset whose
	// low 32 bits are all ones, i.e. every 4 GB boundary minus one. Distinguishing
	// it from a real error needs a SetLastError/GetLastError pair that was not
	// there, so a seek to 4 GB-1 read as failure and the tail of a multi-GB log
	// silently never appeared. That is precisely the file this function exists for.
	if !win.SetFilePointerEx(h, win.LARGE_INTEGER(offset), nil, win.FILE_BEGIN) {
		return nil, false
	}
	buf := make([]u8, count, allocator)
	total := 0
	for total < count {
		got: win.DWORD
		if !win.ReadFile(h, raw_data(buf[total:]), win.DWORD(count - total), &got, nil) || got == 0 {
			break
		}
		total += int(got)
	}
	if total != count {
		// Short read: the file shrank or is mid-write. Return what we got so the
		// caller can decide, rather than pretending we have the whole range.
		return buf[:total], false
	}
	return buf, true
}

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
	// Durability before the rename. Without it the rename can commit while the
	// bytes are still only in the cache, so a power loss leaves a zero-length file
	// where the document was -- and the original is already gone. That is strictly
	// worse than the plain overwrite this atomic scheme replaced, which is the
	// whole reason the scheme exists.
	win.FlushFileBuffers(h)
	win.CloseHandle(h)
	if total != len(data) {
		win.DeleteFileW(wtmp)
		return .Write
	}

	wdst := win.utf8_to_wstring(path, context.temp_allocator)
	// Replacing an existing file goes through ReplaceFileW, which keeps the
	// original's ACLs, attributes, creation time and alternate data streams.
	// MoveFileExW substitutes a brand-new file, so every save silently reset the
	// permissions on anything with non-default ACLs -- a config under a hardened
	// directory, a file in a shared folder -- and dropped Zone.Identifier with it.
	// ReplaceFileW requires the target to exist, so a first save (Save As to a new
	// name) still takes the rename path below.
	if win.GetFileAttributesW(wdst) != win.INVALID_FILE_ATTRIBUTES {
		if ReplaceFileW(wdst, wtmp, nil, REPLACEFILE_WRITE_THROUGH | REPLACEFILE_IGNORE_MERGE_ERRORS, nil, nil) {
			return .None
		}
		// Fall through rather than fail: ReplaceFileW does not work on every
		// filesystem or across volumes, and a save that succeeds without preserving
		// metadata beats a save that refuses to happen.
	}
	if !win.MoveFileExW(wtmp, wdst, win.MOVEFILE_REPLACE_EXISTING | win.MOVEFILE_WRITE_THROUGH) {
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

Encoding_Choice :: enum {
	Save_As_UTF8,
	Save_Anyway,
	Cancel,
}

// The file's encoding cannot represent something the user typed. Offer the
// lossless option first: saving as UTF-8 keeps the text, and the alternative
// destroys it. Notepad prompts here too rather than silently substituting.
confirm_lossy_encoding :: proc(owner: win.HWND, name, enc: string, lost: int) -> Encoding_Choice {
	count := fmt.tprintf("%d", lost)
	msg := strings.concatenate(
		{
			name,
			" is ",
			enc,
			", which cannot represent ",
			count,
			" character(s) in it.\n\nSave as UTF-8 instead to keep them?\n\n",
			"Yes  - save as UTF-8 (nothing is lost)\n",
			"No   - save as ",
			enc,
			" anyway (those characters become '?')\n",
			"Cancel - do not save",
		},
		context.temp_allocator,
	)
	wmsg := win.utf8_to_wstring(msg, context.temp_allocator)
	wcap := win.utf8_to_wstring("Newtpad", context.temp_allocator)
	switch win.MessageBoxW(owner, wmsg, wcap, MB_YESNOCANCEL | MB_ICONWARNING) {
	case ID_YES:
		return .Save_As_UTF8
	case ID_NO:
		return .Save_Anyway
	}
	return .Cancel
}

// --- opening things the user clicked ---------------------------------------
//
// The rule: never hand an arbitrary string to ShellExecute. Text the user is
// reading may have been written by anyone -- a build log, a downloaded file, a
// pasted stack trace -- so a link in it is untrusted input.

// URL schemes allowed to reach the shell. A whitelist, because a blacklist
// fails open: search-ms:, ms-msdt: (Follina), ms-officecmd: and friends are
// delivered exactly this way, and the list of dangerous handlers grows.
@(private = "file")
URL_SCHEMES := [?]string{"http://", "https://", "mailto:"}

// True if `s` is a URL we are willing to open. file:// is deliberately absent:
// it is a path, and paths go through the classify-and-reveal path below.
url_is_openable :: proc(s: string) -> bool {
	for scheme in URL_SCHEMES {
		if len(s) > len(scheme) && strings.equal_fold(s[:len(scheme)], scheme) {
			return true
		}
	}
	return false
}

// Hand a URL to the default browser. Refuses anything not whitelisted, so a
// caller that forgets to check cannot open a handler URL by accident.
shell_open_url :: proc(url: string) -> bool {
	if !url_is_openable(url) {
		return false
	}
	wurl := win.utf8_to_wstring(url, context.temp_allocator)
	wop := win.utf8_to_wstring("open", context.temp_allocator)
	r := win.ShellExecuteW(nil, wop, wurl, nil, nil, win.SW_SHOWNORMAL)
	return uintptr(rawptr(r)) > 32 // ShellExecute's documented success threshold
}

// Select `path` in Explorer rather than opening it. This is what a non-text
// file gets: the user sees where it is and decides what to do, and nothing we
// did executed it.
shell_reveal :: proc(path: string) -> bool {
	// /select, needs the path quoted or a comma or space in the name truncates it.
	arg := strings.concatenate({"/select,\"", path, "\""}, context.temp_allocator)
	warg := win.utf8_to_wstring(arg, context.temp_allocator)
	wexe := win.utf8_to_wstring("explorer.exe", context.temp_allocator)
	wop := win.utf8_to_wstring("open", context.temp_allocator)
	r := win.ShellExecuteW(nil, wop, wexe, warg, nil, win.SW_SHOWNORMAL)
	return uintptr(rawptr(r)) > 32
}

// Does this path exist, and is it a directory? Callers stat before opening: a
// link to something that is not there should reach no handler at all.
path_exists :: proc(path: string) -> (exists, is_dir: bool) {
	wpath := win.utf8_to_wstring(path, context.temp_allocator)
	attrs := win.GetFileAttributesW(wpath)
	if attrs == win.INVALID_FILE_ATTRIBUTES {
		return false, false
	}
	return true, (attrs & win.FILE_ATTRIBUTE_DIRECTORY) != 0
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
