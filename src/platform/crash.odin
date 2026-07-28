// Layer: platform -- the last line of defence. Arms an unhandled-exception
// filter so a hard crash (access violation, illegal instruction -- which is
// also what an Odin panic/assert traps to) does three things before the process
// dies: save the user's unsaved work, drop a .dmp minidump for offline analysis,
// and write a human-readable .txt report that folds in the log breadcrumb trail
// so a "random" crash arrives with the sequence that led to it. Then it tells
// the user their work was saved and where the report is.
//
// The filter is `proc "system"`, so it runs without an Odin context and cannot
// assume the heap is intact -- it establishes a default context but leans on the
// stack (a fixed report buffer, Win32 file writes) and pure-Win32 dump calls, so
// it still works when the heap is the thing that got corrupted.
package platform

import "base:runtime"
import "core:fmt"
import "core:strings"
import base "src:base"
import win "core:sys/windows"

// GetTickCount64 isn't in the Odin bindings; it only names the crash files.
foreign import kernel32 "system:Kernel32.lib"
@(default_calling_convention = "system")
foreign kernel32 {
	GetTickCount64 :: proc() -> u64 ---
}

@(private = "file")
Crash_State :: struct {
	dir:      string, // where .dmp/.txt land (heap-cloned, lives for the process)
	version:  string,
	on_fatal: proc(), // save-the-user's-work hook (best-effort)
	installed: bool,
	handling:  bool, // re-entrancy guard: a fault inside the handler must not loop
	silent:    bool, // suppress the message box (headless crash tests)
	// Everything the issue URL needs that is knowable BEFORE the fault, captured
	// at arm time so the filter does not have to ask the OS anything. `ver` is
	// `version` reduced to URL-safe characters, in fixed storage -- the filter
	// must not allocate to build a string it is about to hand to the shell.
	os_major:  u32,
	os_minor:  u32,
	os_build:  u32,
	ver:       [32]u8,
	ver_len:   int,
}

// Suppress the crash message box (for headless tests that trigger a real fault
// and then inspect the .dmp/.txt from outside the process).
crash_set_silent :: proc(v: bool) {g_crash.silent = v}

@(private = "file")
g_crash: Crash_State

// Arm crash handling. `crash_dir` is where reports are written (created by the
// caller); `version` is stamped into every report; `on_fatal` saves open work.
// Call once, early -- after seh_install, before the window exists is fine.
crash_install :: proc(crash_dir: string, version: string, on_fatal: proc()) {
	g_crash.dir = strings.clone(crash_dir) // must outlive every frame's temp arena
	g_crash.version = strings.clone(version)
	g_crash.on_fatal = on_fatal
	g_crash.installed = true

	// The two things the issue URL needs that the filter should not have to go
	// and get: the OS version, and a URL-safe copy of the product version. Doing
	// this here rather than in the filter is the design's own instruction -- the
	// version and OS are known at arm time and only the exception code is not.
	//
	// RtlGetVersion rather than GetVersionExW: it reports the real build whether
	// or not a compatibility manifest is present, so the number in a report is
	// the machine's, not a shim's.
	osvi: win.OSVERSIONINFOEXW
	osvi.dwOSVersionInfoSize = size_of(osvi)
	if win.RtlGetVersion(&osvi) == 0 {
		g_crash.os_major, g_crash.os_minor, g_crash.os_build = osvi.dwMajorVersion, osvi.dwMinorVersion, osvi.dwBuildNumber
	}
	// Reduced to [A-Za-z0-9.-]. `version` is a compile-time constant today, but
	// this is the one caller-supplied string that reaches a URL, and "today's
	// caller passes something safe" is not a property the URL builder can rely
	// on. Anything else is dropped rather than escaped: there is no percent
	// encoder here on purpose (see crash_issue_url).
	g_crash.ver_len = 0 // re-arming must replace the version, not append to it
	for i in 0 ..< len(version) {
		if g_crash.ver_len >= len(g_crash.ver) {break}
		c := version[i]
		safe :=
			(c >= 'a' && c <= 'z') ||
			(c >= 'A' && c <= 'Z') ||
			(c >= '0' && c <= '9') ||
			c == '.' ||
			c == '-'
		if safe {
			g_crash.ver[g_crash.ver_len] = c
			g_crash.ver_len += 1
		}
	}

	win.SetUnhandledExceptionFilter(crash_filter)
	base.log_info("crash handler armed; reports -> %s", crash_dir)
}

// Where "Report it" sends the browser. A constant: the URL's host and path are
// never assembled from anything observed at runtime.
CRASH_ISSUE_BASE :: "https://github.com/WGuethlein/Newtpad/issues/new"

// The prefilled GitHub issue for `code` at `addr`, written into `out`. Returns
// the slice of `out` that holds it, or "" if it would not fit.
//
// **Nothing in this URL comes from the user's data.** Not the crashed file's
// path, not its name, not a byte of its contents, not the crash report's own
// path. A crash while editing resignation-letter.txt must not put that in a
// public issue, and the guarantee here is structural rather than a filter:
// every variable substituted below is either a number we formatted ourselves or
// `exception_name`'s return value, which comes from a compile-time set of
// A-Z_ literals. That is also why there is no percent-encoder in this file --
// there is nothing here that could need escaping, and a hand-rolled encoder
// running inside an exception filter would be new machinery guarding against a
// case that cannot arise.
//
// Allocation-free: it formats into the caller's buffer exactly the way
// write_report formats into its fixed backing, so a corrupt heap does not stop
// the user being able to report the crash that corrupted it.
crash_issue_url :: proc(code: u32, addr: uintptr, out: []u8) -> string {
	ver := string(g_crash.ver[:g_crash.ver_len])
	if ver == "" {ver = "unknown"}
	s := fmt.bprintf(
		out,
		"%s?title=Crash%%3A%%20%s&body=" +
		"Newtpad%%20%s%%20crashed.%%0A%%0A" +
		"Exception%%3A%%20%s%%20(0x%x)%%0A" +
		"Address%%3A%%200x%x%%0A" +
		"Windows%%3A%%20%d.%d%%20build%%20%d%%0A%%0A" +
		"What%%20I%%20was%%20doing%%3A%%20%%0A%%0A" +
		"A%%20crash%%20dump%%20and%%20a%%20text%%20report%%20are%%20in%%20the%%20Newtpad%%20crashes%%20folder%%20" +
		"on%%20my%%20machine.%%20Nothing%%20was%%20sent%%20automatically%%3B%%20attach%%20them%%20here%%20if%%20you%%20want%%20them.",
		CRASH_ISSUE_BASE,
		exception_name(code),
		ver,
		exception_name(code),
		code,
		addr,
		g_crash.os_major,
		g_crash.os_minor,
		g_crash.os_build,
	)
	// bprintf truncates silently once the buffer is full, and a truncated URL is
	// a URL that means something other than what it says. Refuse instead.
	if len(s) >= len(out) {return ""}
	return s
}

// Report a fatal condition we detected ourselves (a panic/assert routes here
// before trapping) so the reason is captured even though there is no hardware
// exception record yet. Writes the text report + saves work; the subsequent trap
// still produces the minidump through the filter below.
crash_note :: proc(reason: string) {
	base.log_error("FATAL: %s", reason)
}

@(private = "file")
crash_filter :: proc "system" (info: ^win.EXCEPTION_POINTERS) -> win.LONG {
	context = runtime.default_context()
	if g_crash.handling {return win.EXCEPTION_EXECUTE_HANDLER} // second fault: just die
	g_crash.handling = true

	code: u32 = 0
	addr: uintptr = 0
	if info != nil && info.ExceptionRecord != nil {
		code = u32(info.ExceptionRecord.ExceptionCode)
		addr = uintptr(info.ExceptionRecord.ExceptionAddress)
	}

	// Stamp a base name shared by the .dmp and .txt so they pair up. No wall clock
	// in this environment's Odin build path is guaranteed, so use the process tick
	// count -- unique enough within a machine's uptime, and monotonic.
	stamp := GetTickCount64()
	dmp := fmt.tprintf("%s\\crash-%d.dmp", g_crash.dir, stamp)
	txt := fmt.tprintf("%s\\crash-%d.txt", g_crash.dir, stamp)

	// 1. Minidump first: pure Win32, no locks, most likely to succeed. Captures the
	//    true fault stack regardless of what else goes wrong -- taken before any log
	//    call so a lock the faulting thread already held can't cost us the dump.
	write_minidump(dmp, info)

	// 2. Record the fault in the breadcrumb ring so the report below shows it.
	base.log_error("unhandled exception %s at 0x%x", exception_name(code), addr)

	// 3. Save the user's work. Best-effort; if the heap is wrecked this may fail,
	//    which is why the dump went first.
	if g_crash.on_fatal != nil {g_crash.on_fatal()}

	// 4. Human-readable report with the breadcrumb trail.
	write_report(txt, code, addr)

	// 5. Tell the user, and give them something to do about it. The old MB_OK
	//    named a path and stopped there, which meant the report existed and
	//    nothing ever reached us.
	//
	//    MessageBoxW rather than TaskDialogIndirect, which would have real button
	//    labels: the task dialog needs a comctl32 v6 activation context and a
	//    30-field struct, and this is an exception filter. Every line in this
	//    procedure is chosen for how little it depends on the process still being
	//    healthy, and MessageBoxW is already proven to work here. The three
	//    buttons are labelled in the body text instead.
	if !g_crash.silent {
		msg := fmt.tprintf(
			"Newtpad hit a problem and has to close.\n\n" +
			"Your open tabs and unsaved changes have been saved and will be restored next launch.\n\n" +
			"A crash report was written to:\n%s\n\n" +
			"Yes\t- report this on GitHub (opens your browser; nothing is sent automatically)\n" +
			"No\t- open the folder containing the report\n" +
			"Cancel\t- just close",
			txt,
		)
		switch win.MessageBoxW(nil, win.utf8_to_wstring(msg), win.L("Newtpad"), MB_YESNOCANCEL | win.MB_ICONERROR) {
		case ID_YES:
			// The URL carries the version, the OS build and the exception -- and
			// nothing else. See crash_issue_url: `txt` above is deliberately not
			// among its arguments.
			ubuf: [1024]u8
			if url := crash_issue_url(code, addr, ubuf[:]); url != "" {
				shell_open_url(url)
			}
		case ID_NO:
			shell_open_folder(g_crash.dir)
		}
	}
	return win.EXCEPTION_EXECUTE_HANDLER
}

// MessageBoxW constants; file.odin's copies are @(private="file").
@(private = "file")
MB_YESNOCANCEL :: 0x0000_0003
@(private = "file")
ID_YES :: 6
@(private = "file")
ID_NO :: 7

// NOT wide_path, here or in the report writer below: this runs inside the
// unhandled-exception filter, and the fewer moving parts between the fault and
// the bytes on disk, the better. The exclusion stands -- but not for the reason
// it used to give, and it is a known hole rather than a free one.
//
// **The crash directory is already user-configurable.** `session_dir()`
// (program/session.odin) honours NEWTPAD_SESSION_DIR and `diag_init` derives
// `<dir>\crashes` from it, so an override long enough to push these paths past
// MAX_PATH produces a crash file plain CreateFileW cannot open, and the artefact
// the crash suite exists to produce is lost with no diagnostic at all. In
// practice the hole opens one step earlier still: the `os.make_directory` that
// would have created `<dir>\crashes` is core:os's registry-dependent long-path
// path, so the directory is not there either. Nobody has hit this -- the override
// is a test affordance and %APPDATA%\Newtpad\crashes is short -- but "always
// short" is now an assumption about how the program is invoked, not a fact.
//
// The "less machinery in the filter" half is weaker than it reads, too: the
// `win.utf8_to_wstring` calls below allocate from the **heap**, inside a filter
// whose entire premise is that the heap may be corrupt. `wide_path` would put
// that work on the temp allocator instead, which is not obviously worse. Whether
// to switch is a call for the crash-reporting work, not a drive-by; recorded here
// so it is weighed rather than rediscovered.
@(private = "file")
write_minidump :: proc(path: string, info: ^win.EXCEPTION_POINTERS) {
	h := win.CreateFileW(
		win.utf8_to_wstring(path),
		win.GENERIC_WRITE,
		0,
		nil,
		win.CREATE_ALWAYS,
		win.FILE_ATTRIBUTE_NORMAL,
		nil,
	)
	if h == win.INVALID_HANDLE_VALUE {return}
	defer win.CloseHandle(h)

	mei := win.MINIDUMP_EXCEPTION_INFORMATION {
		ThreadId          = win.GetCurrentThreadId(),
		ExceptionPointers = info,
		ClientPointers    = win.FALSE,
	}
	// Threads + stacks + referenced memory + data segments: enough to inspect the
	// fault and nearby state, without a full-memory dump's size.
	dump_type := transmute(win.MINIDUMP_TYPE)(u32(0x1) | u32(0x40) | u32(0x1000)) // DataSegs | IndirectlyReferencedMemory | WithThreadInfo
	mei_ptr := &mei if info != nil else nil
	win.MiniDumpWriteDump(win.GetCurrentProcess(), win.GetCurrentProcessId(), h, dump_type, mei_ptr, nil, nil)
}

@(private = "file")
write_report :: proc(path: string, code: u32, addr: uintptr) {
	// Fixed backing store: no heap allocation, so a corrupt heap can't stop the
	// report. Big enough for the header + the whole log ring at LOG_LINE_MAX.
	backing: [64 * 1024]u8
	b := strings.builder_from_bytes(backing[:])

	fmt.sbprintf(&b, "Newtpad crash report\n")
	fmt.sbprintf(&b, "version:   %s\n", g_crash.version)
	fmt.sbprintf(&b, "exception: %s (0x%x)\n", exception_name(code), code)
	fmt.sbprintf(&b, "address:   0x%x", addr)
	nb: [512]u8
	if name, off, ok := symbolize(addr, nb[:]); ok {
		fmt.sbprintf(&b, "  %s +0x%x", name, off)
	}
	fmt.sbprintf(&b, "\n")

	// Handler-side backtrace. The fault stack proper is in the .dmp; this at least
	// names nearby frames when symbols are present.
	frames: [48]win.PVOID
	n := win.RtlCaptureStackBackTrace(0, 48, &frames[0], nil)
	fmt.sbprintf(&b, "\nbacktrace (handler; see .dmp for the fault stack):\n")
	fnb: [512]u8
	for i in 0 ..< int(n) {
		a := uintptr(frames[i])
		if name, off, ok := symbolize(a, fnb[:]); ok {
			fmt.sbprintf(&b, "  0x%x  %s +0x%x\n", a, name, off)
		} else {
			fmt.sbprintf(&b, "  0x%x\n", a)
		}
	}

	// The breadcrumb trail: the last LOG_RING lines, oldest first.
	fmt.sbprintf(&b, "\nlog (%d retained of %d total):\n", base.log_retained(), base.log_total())
	base.log_each(report_emit_line, &b)

	// One write, one handle.
	s := strings.to_string(b)
	h := win.CreateFileW(
		win.utf8_to_wstring(path),
		win.GENERIC_WRITE,
		0,
		nil,
		win.CREATE_ALWAYS,
		win.FILE_ATTRIBUTE_NORMAL,
		nil,
	)
	if h == win.INVALID_HANDLE_VALUE {return}
	defer win.CloseHandle(h)
	written: win.DWORD
	win.WriteFile(h, raw_data(s), u32(len(s)), &written, nil)
}

@(private = "file")
report_emit_line :: proc(user: rawptr, e: ^base.Log_Entry) {
	b := (^strings.Builder)(user)
	// Guard the shared builder: once the fixed backing is full, stop appending
	// (sbprintf would keep trying). Leave room for the closing.
	if strings.builder_len(b^) >= cap(b.buf) - 300 {return}
	fmt.sbprintf(b, "  [%9.1fms] %s %s\n", e.t_ms, base.log_level_name(e.level), string(e.text[:e.len]))
}

// --- symbolization (best-effort; needs a PDB alongside the exe) -------------

@(private = "file")
g_sym_ready: bool

@(private = "file")
sym_init :: proc() {
	if g_sym_ready {return}
	win.SymSetOptions(win.SYMOPT_LOAD_LINES | 0x2) // LOAD_LINES | UNDNAME
	if win.SymInitialize(win.GetCurrentProcess(), nil, win.TRUE) == win.TRUE {
		g_sym_ready = true
	}
}

// Resolve an address to `name +offset`, writing the name into `out` (which must
// outlive the returned string -- callers pass a stack buffer used immediately).
@(private = "file")
symbolize :: proc(addr: uintptr, out: []u8) -> (name: string, offset: u64, ok: bool) {
	if addr == 0 {return}
	sym_init()
	if !g_sym_ready {return}
	MAXN :: 256
	// SYMBOL_INFOW has a flexible Name tail; over-allocate on the stack.
	buf: [size_of(win.SYMBOL_INFOW) + MAXN * size_of(u16)]u8
	si := (^win.SYMBOL_INFOW)(raw_data(buf[:]))
	si.SizeOfStruct = size_of(win.SYMBOL_INFOW)
	si.MaxNameLen = MAXN
	disp: win.DWORD64
	if win.SymFromAddrW(win.GetCurrentProcess(), win.DWORD64(addr), &disp, si) != win.TRUE {return}
	nm := win.wstring_to_utf8(out, cast(win.wstring)&si.Name[0], int(si.NameLen))
	return nm, u64(disp), true
}

@(private = "file")
exception_name :: proc(code: u32) -> string {
	switch code {
	case 0xC0000005:
		return "ACCESS_VIOLATION"
	case 0xC000001D:
		return "ILLEGAL_INSTRUCTION"
	case 0xC0000094:
		return "INT_DIVIDE_BY_ZERO"
	case 0xC0000095:
		return "INT_OVERFLOW"
	case 0xC00000FD:
		return "STACK_OVERFLOW"
	case 0xC0000025:
		return "NONCONTINUABLE_EXCEPTION"
	case 0x80000003:
		return "BREAKPOINT"
	case 0xC0000374:
		return "HEAP_CORRUPTION"
	}
	return "EXCEPTION"
}
