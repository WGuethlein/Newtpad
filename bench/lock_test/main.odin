// Characterize precisely: does an open file MAPPING block DELETE of the file?
// The adversarial pass claimed yes (never-lock violation). First quick test
// suggested delete SUCCEEDS with FILE_SHARE_DELETE. This resolves it cleanly:
//   Case A: mapping created from a FILE_SHARE_DELETE handle (our design)
//   Case B: mapping created from a handle WITHOUT share-delete (the claim's case)
// and whether the mapped view still reads AFTER the file is deleted (no crash).
// Build: odin build bench/lock_test -out:build\locktest.exe && build\locktest.exe
package main

import "core:fmt"
import "core:os"
import win "core:sys/windows"

exists :: proc(wpath: win.wstring) -> bool {
	h := win.CreateFileW(wpath, win.GENERIC_READ, win.FILE_SHARE_READ | win.FILE_SHARE_WRITE | win.FILE_SHARE_DELETE, nil, win.OPEN_EXISTING, win.FILE_ATTRIBUTE_NORMAL, nil)
	if h == win.INVALID_HANDLE_VALUE {return false}
	win.CloseHandle(h)
	return true
}

map_file :: proc(wpath: win.wstring, share: win.DWORD) -> (view: rawptr, hmap: win.HANDLE) {
	hfile := win.CreateFileW(wpath, win.GENERIC_READ, share, nil, win.OPEN_EXISTING, win.FILE_ATTRIBUTE_NORMAL, nil)
	hmap = win.CreateFileMappingW(hfile, nil, win.PAGE_READONLY, 0, 0, nil)
	view = win.MapViewOfFile(hmap, win.FILE_MAP_READ, 0, 0, 0)
	win.CloseHandle(hfile) // hold only the mapping, like piece_open
	return
}

main :: proc() {
	os.make_directory("bench/data")

	// ---- Case A: our design (source handle has FILE_SHARE_DELETE) ----
	fmt.println("Case A: mapping from a FILE_SHARE_READ|WRITE|DELETE handle (Newtpad's design)")
	pathA := "bench/data/lockA.tmp"
	_ = os.write_entire_file(pathA, transmute([]u8)string("AAAA mmap delete test\n"))
	wA := win.utf8_to_wstring(pathA)
	viewA, hmapA := map_file(wA, win.FILE_SHARE_READ | win.FILE_SHARE_WRITE | win.FILE_SHARE_DELETE)
	before := (cast([^]u8)viewA)[0]
	fmt.printfln("  mapped, first byte = %c", before)

	h2 := win.CreateFileW(wA, win.DELETE, win.FILE_SHARE_READ | win.FILE_SHARE_WRITE | win.FILE_SHARE_DELETE, nil, win.OPEN_EXISTING, win.FILE_ATTRIBUTE_NORMAL, nil)
	fmt.printfln("  another app opens for DELETE : %s", "OK" if h2 != win.INVALID_HANDLE_VALUE else fmt.tprintf("BLOCKED err %d", win.GetLastError()))
	if h2 != win.INVALID_HANDLE_VALUE {win.CloseHandle(h2)}

	del := win.DeleteFileW(wA)
	fmt.printfln("  DeleteFileW while mapped     : %s", "SUCCESS" if del else fmt.tprintf("BLOCKED err %d", win.GetLastError()))
	fmt.printfln("  file gone to other programs? : %v", !exists(wA))
	after := (cast([^]u8)viewA)[0] // read the still-mapped (now-deleted) data
	fmt.printfln("  view still reads after delete: %v (first byte %c)", after == before, after)
	win.UnmapViewOfFile(viewA)
	win.CloseHandle(hmapA)
	_ = win.DeleteFileW(wA) // cleanup if still present

	// ---- Case B: mapping WITHOUT share-delete (the mechanism the agent cited) ----
	fmt.println("Case B: mapping from a handle WITHOUT FILE_SHARE_DELETE")
	pathB := "bench/data/lockB.tmp"
	_ = os.write_entire_file(pathB, transmute([]u8)string("BBBB mmap delete test\n"))
	wB := win.utf8_to_wstring(pathB)
	viewB, hmapB := map_file(wB, win.FILE_SHARE_READ)
	delB := win.DeleteFileW(wB)
	fmt.printfln("  DeleteFileW while mapped     : %s", "SUCCESS" if delB else fmt.tprintf("BLOCKED err %d", win.GetLastError()))
	win.UnmapViewOfFile(viewB)
	win.CloseHandle(hmapB)
	_ = win.DeleteFileW(wB)

	fmt.println("\nConclusion: does our (Case A) mapping honor the never-lock rule for DELETE?")
}
