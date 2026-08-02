// Layer: platform — the `\\?\` ("extended-length") path form, and the wide
// conversion every file-I/O call goes through.
//
// Why this file exists: a normalized Win32 path is capped at MAX_PATH, 260
// *including* the terminating NUL, so 259 usable characters. Past that,
// CreateFileW / GetFileAttributesExW / MoveFileExW simply fail — a file inside a
// deep node_modules, a synced OneDrive tree or nested build output cannot be
// opened at all. The `\\?\` prefix lifts the cap to ~32767 wide characters and is
// the only mechanism available to us: the alternative opt-in (HKLM
// LongPathsEnabled *plus* a `longPathAware` manifest entry) is per-machine and
// CLAUDE.md forbids depending on the registry for it.
//
// **The prefix is not free, and a blanket prefix is worse than the bug.** `\\?\`
// tells the object manager to skip path normalization entirely, so:
//
//   - It is absolute-only. `\\?\sub\f.txt` is not a path at all.
//   - `/` is no longer a separator, `.` and `..` are no longer resolved — they
//     become literal directory names that do not exist.
//   - A UNC path takes a different shape: `\\server\share\x` must be written
//     `\\?\UNC\server\share\x`, not `\\?\\\server\share\x`.
//
// So canonicalization happens **before** the prefix goes on, never after, and the
// prefix goes on only where it is needed. Everything else is returned untouched,
// which also keeps ordinary paths ordinary in a debugger and in an error message.
//
// Known divergence, deliberate: Win32's normalizer strips trailing dots and
// spaces from each component, and `\\?\` does not. A 248+-character path whose
// last component ends in `.` or ` ` therefore resolves differently through this
// helper than a short one would. Replicating the stripping was considered and
// rejected — it is an extra transformation on every long path to serve a case
// that is already unreachable through Explorer, and getting `...` right is its
// own trap. If it ever bites, this comment is the place it was weighed.
package platform

import "core:fmt"
import "core:strings"
import win "core:sys/windows"

// Prefix at this length or above. 248 is `MAX_PATH - 12`, and it is the number
// core:os uses (`_fix_long_path_internal`, core/os/path_windows.odin) — for a
// reason worth stating, because it is not the 259-character file limit and it is
// not a safety margin against one.
//
// **Directories cap lower than files.** Win32 reserves twelve characters inside a
// directory for an 8.3 name it may have to generate there, so a *plain*
// `CreateDirectoryW` refuses at 248 while a plain `CreateFileW` is content to 259.
// Measured on this machine, one component under a short parent:
//
//   plain CreateDirectoryW  247 ok, 248 fails ERROR_FILENAME_EXCED_RANGE (206)
//   plain CreateFileW       259 ok, 260 fails ERROR_PATH_NOT_FOUND (3)
//   the `\\?\` form         succeeds at every length, both calls
//
// `dir_create` is therefore what pins the threshold here. **Raising it breaks
// directory creation for the eleven lengths 248-258 and nothing else complains**
// — files keep working, so the damage stays invisible until a mkdir at exactly
// the wrong depth fails. The `#assert` below and `longpathtest`'s "dir_create at
// exactly 248 chars" row are what turn that into a build error and a red test.
//
// The threshold applies to *each string handed to a syscall*, not to a logical
// file: `atomic_write_begin` appends ".newtpad~" and calls `wide_path` on the temp
// string, which is thresholded on its own length. Those nine characters play no
// part in choosing 248, and no slack here is reserved for them.
LONG_PATH_THRESHOLD :: 248

// The plain-form cap Win32 puts on a directory path, measured above. The
// threshold may sit at or below it and nowhere else, so the compiler says so
// rather than leaving the next reader to rediscover the 206 the hard way.
@(private = "file")
DIR_PATH_MAX_PLAIN :: 248
#assert(LONG_PATH_THRESHOLD <= DIR_PATH_MAX_PLAIN)

@(private = "file")
is_sep :: proc(c: u8) -> bool {
	return c == '\\' || c == '/'
}

@(private = "file")
Path_Kind :: enum {
	Relative, // "sub\f.txt", "C:f.txt" (drive-relative), "\f.txt" (rooted, no volume)
	Drive, // "C:\..."
	UNC, // "\\server\share\..."
}

@(private = "file")
path_kind :: proc(path: string) -> Path_Kind {
	if len(path) >= 3 && path[1] == ':' && is_sep(path[2]) {
		c := path[0]
		if (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') {
			return .Drive
		}
	}
	if len(path) >= 2 && is_sep(path[0]) && is_sep(path[1]) {
		return .UNC
	}
	return .Relative
}

// Already an extended-length or device path (`\\?\...`, `\\.\...`)? Those are
// returned untouched: they are already normalization-free, and prefixing one
// again yields `\\?\\\?\C:\...`, which names nothing. Both separator spellings
// are recognised — we never produce `//?/`, but passing an unfamiliar string
// through unchanged is the only safe answer for one.
@(private = "file")
path_is_extended :: proc(path: string) -> bool {
	return len(path) >= 4 && is_sep(path[0]) && is_sep(path[1]) && (path[2] == '?' || path[2] == '.') && is_sep(path[3])
}

// The form of `path` to hand to a file-I/O API: `\\?\`-prefixed and canonicalized
// when the path is absolute and long enough to need it, byte-identical to the
// input otherwise.
//
// Pure: no Win32, no filesystem, so every row of its rule table is a plain string
// assertion (see `longpathtest`).
//
// Limitation worth knowing: a *relative* path is returned unchanged, because
// `\\?\` cannot be applied to one. Resolving it would need GetFullPathNameW,
// which would make this impure and put a syscall on every stat in the watch
// poll. A relative path that resolves past MAX_PATH therefore still fails —
// Newtpad's own paths are absolute everywhere except a command-line argument.
long_path_form :: proc(path: string, allocator := context.temp_allocator) -> string {
	if path_is_extended(path) {return path}

	kind := path_kind(path)
	if kind == .Relative {return path}
	// Decide on the input length, not the canonical length: canonicalization can
	// only shorten a path, so this can prefix one that did not strictly need it
	// and can never miss one that did.
	if len(path) < LONG_PATH_THRESHOLD {return path}

	// Split into components first. `..` is resolved here, while `\` is still just
	// a separator; once the prefix is on it is far too late.
	comps := make([dynamic]string, 0, 32, context.temp_allocator)
	defer delete(comps)

	start := 2 // both kinds consume two leading bytes: "C:" or "\\"
	// A UNC's server and share are part of the root, not components `..` may pop.
	floor := 2 if kind == .UNC else 0

	i := start
	for i < len(path) {
		for i < len(path) && is_sep(path[i]) {i += 1}
		j := i
		for j < len(path) && !is_sep(path[j]) {j += 1}
		if j > i {
			switch c := path[i:j]; c {
			case ".": // no-op
			case "..":
				// Never climbs out of the volume root; Win32's own normalizer
				// treats `C:\..\x` as `C:\x` rather than as an error.
				if len(comps) > floor {pop(&comps)}
			case:
				append(&comps, c)
			}
		}
		i = j
	}

	// Degenerate shapes we refuse to rewrite rather than guess at: a bare root, or
	// a UNC missing its share. Neither can occur at 248+ characters, but a helper
	// that silently emits `\\?\C:` would be a very quiet bug if one ever did.
	if len(comps) < floor + 1 {return path}

	b := strings.builder_make(allocator)
	switch kind {
	case .Drive:
		strings.write_string(&b, `\\?\`)
		strings.write_byte(&b, path[0])
		strings.write_byte(&b, ':')
	case .UNC:
		strings.write_string(&b, `\\?\UNC`)
	case .Relative:
		unreachable()
	}
	for c in comps {
		strings.write_byte(&b, '\\')
		strings.write_string(&b, c)
	}
	return strings.to_string(b)
}

// UTF-8 path -> null-terminated wide path, through long_path_form. This is the
// only conversion a file-I/O call should use; the shell, dialog and
// inter-process call sites keep win.utf8_to_wstring deliberately (see the
// comments on each in file.odin).
wide_path :: proc(path: string, allocator := context.temp_allocator) -> win.wstring {
	// The intermediate UTF-8 form is always temp-allocated even when the caller
	// wants the wide string somewhere else: it dies at the end of this expression,
	// and putting it in a caller-supplied heap allocator would leak it.
	return win.utf8_to_wstring(long_path_form(path, context.temp_allocator), allocator)
}

// --- directory primitives, long-path aware ---------------------------------
//
// core:os goes through its own _fix_long_path, which returns the path unchanged
// whenever HKLM LongPathsEnabled is set — the registry opt-in CLAUDE.md says not
// to depend on, and which does nothing without a `longPathAware` manifest entry
// we do not ship. So directory work that must survive a long path comes through
// here instead.

dir_create :: proc(path: string) -> bool {
	return bool(win.CreateDirectoryW(wide_path(path), nil))
}

dir_remove :: proc(path: string) -> bool {
	return bool(win.RemoveDirectoryW(wide_path(path)))
}

file_delete :: proc(path: string) -> bool {
	return bool(win.DeleteFileW(wide_path(path)))
}

// The names (not paths) directly inside `path`, excluding "." and "..". Used by
// the torn-off-window store sweep, which has to enumerate a directory whose
// contents nothing else knows about.
dir_entries :: proc(path: string, allocator := context.temp_allocator) -> ([]string, bool) {
	fd: win.WIN32_FIND_DATAW
	pat := wide_path(fmt.tprintf("%s\\*", path))
	h := win.FindFirstFileW(pat, &fd)
	if h == win.INVALID_HANDLE_VALUE {return nil, false}
	defer win.FindClose(h)
	out := make([dynamic]string, 0, 8, allocator)
	for {
		name, err := win.wstring_to_utf8(win.wstring(&fd.cFileName[0]), -1, allocator)
		if err == nil && name != "." && name != ".." {append(&out, name)}
		if !win.FindNextFileW(h, &fd) {break}
	}
	return out[:], true
}

// Delete `path` and everything directly inside it. ONE level deep plus the
// well-known `backups` subdirectory, which is the whole shape of a session store
// -- deliberately not a general recursive delete, because a general recursive
// delete pointed at the wrong string is the most destructive procedure a program
// can contain and nothing here needs one.
dir_remove_all :: proc(path: string) -> bool {
	if subs, ok := dir_entries(pjoin_two(path, "backups"), context.temp_allocator); ok {
		for s in subs {file_delete(pjoin_two(pjoin_two(path, "backups"), s))}
		dir_remove(pjoin_two(path, "backups"))
	}
	if names, ok := dir_entries(path, context.temp_allocator); ok {
		for n in names {file_delete(pjoin_two(path, n))}
	}
	return dir_remove(path)
}

@(private = "file")
pjoin_two :: proc(a, b: string) -> string {
	return fmt.tprintf("%s\\%s", a, b)
}

// --- a lock this process holds for as long as it runs ----------------------
//
// One per process, which is all that is needed: the only holder is a torn-off
// window keeping its own session store, and a process has exactly one of those.
//
// The handle is deliberately never closed except by lock_release. That is the
// mechanism, not an oversight: Windows closes it when the process dies BY ANY
// MEANS, including a hard kill or a crash, and "can this file be opened
// exclusively" is therefore an exact test for "is the owning process gone". A pid
// cannot answer that -- pids are reused.
@(private = "file")
lock_handle: win.HANDLE = win.INVALID_HANDLE_VALUE

// This process's id. Used to name a torn-off window's own session store, where it
// is a convenient unique name and NOT a liveness test -- pids are reused, which is
// what the lock above is for.
process_id :: proc() -> u32 {
	return u32(win.GetCurrentProcessId())
}

lock_hold :: proc(path: string) -> bool {
	if lock_handle != win.INVALID_HANDLE_VALUE {return true}
	h := win.CreateFileW(
		wide_path(path),
		win.GENERIC_WRITE,
		0, // no sharing: this is the whole point
		nil,
		win.CREATE_ALWAYS,
		win.FILE_ATTRIBUTE_NORMAL,
		nil,
	)
	if h == win.INVALID_HANDLE_VALUE {return false}
	lock_handle = h
	return true
}

lock_release :: proc() {
	if lock_handle == win.INVALID_HANDLE_VALUE {return}
	win.CloseHandle(lock_handle)
	lock_handle = win.INVALID_HANDLE_VALUE
}

// Can this lock be taken? True means nobody holds it -- the owning process is
// gone -- and the handle is closed again immediately, because the caller wants
// the ANSWER and not the lock.
//
// A missing lock file also reads as free: a store written by a build before locks
// existed, or one whose lock never got created, must still be adoptable rather
// than stranded forever.
lock_try :: proc(path: string) -> bool {
	if ex, _ := path_exists(path); !ex {return true}
	h := win.CreateFileW(wide_path(path), win.GENERIC_WRITE, 0, nil, win.OPEN_EXISTING, win.FILE_ATTRIBUTE_NORMAL, nil)
	if h == win.INVALID_HANDLE_VALUE {return false}
	win.CloseHandle(h)
	return true
}

// The last Win32 error, for a caller that wants to report *why* an operation
// failed rather than only that it did. Platform types don't leak upward, so this
// is a plain u32.
last_error :: proc() -> u32 {
	return u32(win.GetLastError())
}
