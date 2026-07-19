// Layer: platform — installs the SEH-guarded copy into base's read hook, so any
// read out of a memory-mapped original survives a page fault instead of crashing
// (see guarded_copy.c for why SEH lives in C). base stays SEH-agnostic; it just
// calls a proc variable this file overrides at startup.
package platform

import base "src:base"
import win "core:sys/windows"

// build\guarded.obj, produced by build.bat (cl /c guarded_copy.c). Path is
// relative to this source file.
foreign import gc "../../build/guarded.obj"

@(default_calling_convention = "c")
foreign gc {
	newtpad_guarded_copy :: proc(dst: rawptr, src: rawptr, n: u64) -> i32 ---
}

// Copy `src` into `dst` a page at a time under SEH; a page that faults is left
// zero-filled and makes the whole copy report false, so the document can detach
// from the mapping. Straddling an OS page boundary just means a bad page can
// take a few good bytes with it - recovery is best-effort by design.
@(private = "file")
guarded_copy :: proc(dst, src: []u8) -> bool {
	PAGE :: 4096
	ok := true
	i := 0
	for i < len(dst) {
		n := min(PAGE, len(dst) - i)
		if newtpad_guarded_copy(raw_data(dst[i:]), raw_data(src[i:]), u64(n)) == 0 {
			for k in i ..< i + n {dst[k] = 0}
			ok = false
		}
		i += n
	}
	return ok
}

// Call once at startup (before any document opens) to arm the guard.
seh_install :: proc() {
	base.safe_copy = guarded_copy
}

// Proof the guard actually catches a hardware fault through the Odin->C foreign
// call (SEH tables present, exception frame preserved, zero-fill runs): read a
// reserved-but-uncommitted page, which faults. Returns true iff the fault was
// caught (process survives) and the destination came back zero-filled.
seh_selftest :: proc() -> bool {
	bad := win.VirtualAlloc(nil, 4096, win.MEM_RESERVE, win.PAGE_NOACCESS)
	if bad == nil {return false}
	defer win.VirtualFree(bad, 0, win.MEM_RELEASE)
	dst := [16]u8{0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF}
	src := (cast([^]u8)bad)[:16]
	caught := !guarded_copy(dst[:], src) // must report the page unreadable
	zeroed := true
	for b in dst {if b != 0 {zeroed = false}}
	return caught && zeroed
}
