// Layer: platform — read-only file access honoring the locked buffer decision:
// copy small files into private memory (crash-immune), memory-map large ones
// (instant open, ~0 private memory). Always share-everything so we never lock
// the user's file (delete + rename verified to work while mapped; see bench/).
package platform

import "core:os"
import win "core:sys/windows"

FILE_MMAP_THRESHOLD :: 16 * 1024 * 1024 // copy below, mmap above

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

	if n < FILE_MMAP_THRESHOLD {
		// Small: read into private memory and let the handle go (no lock held).
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
	fv.view = win.MapViewOfFile(fv.hmap, win.FILE_MAP_READ, 0, 0, 0)
	win.CloseHandle(hfile)
	if fv.view == nil {
		return
	}
	fv.bytes = (cast([^]u8)fv.view)[:n]
	fv.mapped = true
	return fv, true
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
