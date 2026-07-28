// Layer: platform -- one bounded, blocking HTTPS GET, hand-declared over WinHTTP
// the way dwrite.odin hand-declares DirectWrite (Odin ships no WinHTTP bindings,
// and the dependency bar says hand-roll before adding a library).
//
// This is the first and only network surface in the product. It exists for the
// update check (program/update.odin) and is deliberately the smallest thing that
// works: HTTPS only, GET only, no cookies, no auth, no redirects, no request body,
// no caller-supplied headers. Anything a caller might want to add here is a new
// way for an untrusted server to steer us.
//
// **NEVER call this from the UI thread.** Every WinHTTP call below is synchronous.
// On a captive portal or a dead DNS the connect blocks for the full resolve +
// connect timeout, and on the UI thread that is a frozen window. CLAUDE.md's rule
// -- the main thread builds UI and handles input and nothing else -- is the whole
// reason update.odin runs this on a worker.
//
// Three properties are load-bearing and each has a failure mode behind it:
//
//   1. Every handle is closed on every path, errors included. A leaked session
//      handle leaks WinHTTP's per-session thread pool, and the process never gets
//      it back.
//   2. All four timeouts are set. WinHTTP's defaults are 60 s resolve / 60 s
//      connect / 30 s send / 30 s receive; a caller that joins this thread on
//      teardown would wait minutes for a portal that will never answer.
//   3. `max_bytes` is enforced *inside* the read loop, not checked after it. The
//      server decides how many bytes it sends; we decide how many we allocate.
package platform

import base "src:base"
import win "core:sys/windows"

foreign import winhttp_lib "system:winhttp.lib"

HINTERNET :: rawptr

@(default_calling_convention = "system")
foreign winhttp_lib {
	WinHttpOpen :: proc(pszAgentW: win.wstring, dwAccessType: u32, pszProxyW: win.wstring, pszProxyBypassW: win.wstring, dwFlags: u32) -> HINTERNET ---
	WinHttpSetTimeouts :: proc(hInternet: HINTERNET, nResolveTimeout, nConnectTimeout, nSendTimeout, nReceiveTimeout: i32) -> win.BOOL ---
	WinHttpSetOption :: proc(hInternet: HINTERNET, dwOption: u32, lpBuffer: rawptr, dwBufferLength: u32) -> win.BOOL ---
	WinHttpConnect :: proc(hSession: HINTERNET, pswzServerName: win.wstring, nServerPort: u16, dwReserved: u32) -> HINTERNET ---
	WinHttpOpenRequest :: proc(hConnect: HINTERNET, pwszVerb, pwszObjectName, pwszVersion, pwszReferrer: win.wstring, ppwszAcceptTypes: [^]win.wstring, dwFlags: u32) -> HINTERNET ---
	WinHttpSendRequest :: proc(hRequest: HINTERNET, lpszHeaders: win.wstring, dwHeadersLength: u32, lpOptional: rawptr, dwOptionalLength, dwTotalLength: u32, dwContext: uintptr) -> win.BOOL ---
	WinHttpReceiveResponse :: proc(hRequest: HINTERNET, lpReserved: rawptr) -> win.BOOL ---
	WinHttpQueryHeaders :: proc(hRequest: HINTERNET, dwInfoLevel: u32, pwszName: win.wstring, lpBuffer: rawptr, lpdwBufferLength: ^u32, lpdwIndex: ^u32) -> win.BOOL ---
	WinHttpReadData :: proc(hRequest: HINTERNET, lpBuffer: rawptr, dwNumberOfBytesToRead: u32, lpdwNumberOfBytesRead: ^u32) -> win.BOOL ---
	WinHttpCloseHandle :: proc(hInternet: HINTERNET) -> win.BOOL ---
}

// --- constants (winhttp.h; not in core:sys/windows) -------------------------

@(private = "file")
WINHTTP_ACCESS_TYPE_DEFAULT_PROXY :: 0
@(private = "file")
WINHTTP_ACCESS_TYPE_AUTOMATIC_PROXY :: 4 // Win 8.1+; honours WPAD/system proxy
@(private = "file")
WINHTTP_FLAG_SECURE :: 0x0080_0000
@(private = "file")
WINHTTP_DEFAULT_HTTPS_PORT :: u16(443)
@(private = "file")
WINHTTP_OPTION_DISABLE_FEATURE :: 63
@(private = "file")
WINHTTP_DISABLE_COOKIES :: 0x0000_0001
@(private = "file")
WINHTTP_DISABLE_REDIRECTS :: 0x0000_0002
@(private = "file")
WINHTTP_DISABLE_AUTHENTICATION :: 0x0000_0004
@(private = "file")
WINHTTP_QUERY_STATUS_CODE :: 19
@(private = "file")
WINHTTP_QUERY_FLAG_NUMBER :: 0x2000_0000
@(private = "file")
ERROR_WINHTTP_TIMEOUT :: 12002

// The User-Agent. GitHub's API rejects a request without one outright (403), so
// this is not decoration. It names the product and nothing else -- no machine id,
// no user, no OS build. The privacy rule for the update check is that a plain GET
// carries no identifying information, and the User-Agent is the one header we
// choose, so it is the one that has to be checked.
HTTP_USER_AGENT :: "Newtpad"

Http_Result :: enum u8 {
	Ok, // 2xx and the whole body fit in max_bytes
	Network, // could not resolve/connect/send/read, or a bad argument
	Timeout, // one of the four WinHTTP timeouts elapsed
	Too_Large, // the response exceeded max_bytes; nothing is returned
	Bad_Status, // the request completed but the status was not 2xx
}

// The read-loop accumulator, split out so the size cap can be tested without a
// socket. `http_get`'s loop does nothing to the body except call push() on each
// chunk WinHttpReadData hands back, so exercising push() directly exercises the
// real cap -- see `httptest`.
Http_Sink :: struct {
	buf:  [dynamic]u8,
	max:  int,
	over: bool, // the cap was exceeded; buf is abandoned
}

// Append `chunk`, refusing to grow past `max`. Returns false once the cap would
// be exceeded, and does NOT append the chunk that would have broken it -- the
// point of the cap is that the process never allocates more than the caller
// allowed, whatever the server claims its Content-Length is. Once `over` is set
// it stays set: a later, smaller chunk must not be able to un-refuse the response.
http_sink_push :: proc(s: ^Http_Sink, chunk: []u8) -> bool {
	if s.over {return false}
	if len(s.buf) + len(chunk) > s.max {
		s.over = true
		return false
	}
	append(&s.buf, ..chunk)
	return true
}

// A host we are willing to hand to WinHttpConnect. Printable ASCII only, and
// none of the characters that would let a caller smuggle a port, a path, a
// userinfo section or a second host into what is supposed to be a bare hostname.
// `http_get` is not given a URL to parse, so this is the whole of the input
// validation -- and it is what stops a hostname assembled from a response
// somewhere upstream from redirecting the request.
http_host_ok :: proc(host: string) -> bool {
	if len(host) == 0 || len(host) > 253 {return false}
	for i in 0 ..< len(host) {
		c := host[i]
		if c <= 0x20 || c >= 0x7F {return false}
		switch c {
		case '/', '\\', ':', '?', '#', '@', '[', ']', '%', '"', '\'':
			return false
		}
	}
	return true
}

// A path we are willing to put on the request line. Printable ASCII, must start
// with '/', and no space/CR/LF -- a newline here is request splitting.
http_path_ok :: proc(path: string) -> bool {
	if len(path) == 0 || path[0] != '/' || len(path) > 2048 {return false}
	for i in 0 ..< len(path) {
		c := path[i]
		if c <= 0x20 || c >= 0x7F {return false}
	}
	return true
}

// Classify a WinHTTP GetLastError. Pure, so the mapping is testable without
// provoking a real network failure.
http_result_for_error :: proc(err: u32) -> Http_Result {
	return .Timeout if err == ERROR_WINHTTP_TIMEOUT else .Network
}

// 2xx is the only success. Everything else -- a 301 we refused to follow, a 403
// for a missing User-Agent, a 404, a 500 -- is Bad_Status, and the caller's job
// is to treat that as "could not check" rather than as an answer.
http_result_for_status :: proc(status: int) -> Http_Result {
	return .Ok if status >= 200 && status < 300 else .Bad_Status
}

// UTF-8 -> a NUL-terminated wide string in a caller-supplied stack buffer.
// Deliberately not win.utf8_to_wstring: that allocates, and this runs on a
// worker thread whose temp arena is never reset between calls. ASCII-only is not
// a limitation here -- http_host_ok/http_path_ok already reject everything else,
// and an IDN host would have to arrive punycoded anyway.
@(private = "file")
ascii_wide :: proc(s: string, out: []u16) -> (win.wstring, bool) {
	if len(s) + 1 > len(out) {return nil, false}
	for i in 0 ..< len(s) {
		c := s[i]
		if c < 0x20 || c > 0x7E {return nil, false}
		out[i] = u16(c)
	}
	out[len(s)] = 0
	return cast(win.wstring)raw_data(out), true
}

// Blocking HTTPS GET of `https://<host><path>`. Caller owns `body` and frees it
// with `delete(body, allocator)`; it is nil on every non-.Ok result.
//
// `timeout_ms` is applied to each of WinHTTP's four phases separately (resolve,
// connect, send, receive), so it bounds each stage rather than the whole call.
// A caller that joins this thread should size it accordingly.
//
// NEVER call from the UI thread. See the file header.
http_get :: proc(
	host, path: string,
	max_bytes: int,
	timeout_ms: int,
	allocator := context.allocator,
) -> (
	body: []u8,
	status: int,
	res: Http_Result,
) {
	// Bad arguments are .Network rather than a distinct result: every caller's
	// only sensible response to any non-.Ok is "could not check", and adding a
	// fifth enumerator would invite someone to treat one of them as recoverable.
	if !http_host_ok(host) || !http_path_ok(path) || max_bytes <= 0 || timeout_ms <= 0 {
		base.log_warn("http: refusing malformed request host=%q path_len=%d", host, len(path))
		return nil, 0, .Network
	}

	whost: [256]u16
	wpath: [2049]u16
	wagent: [64]u16
	hw, hok := ascii_wide(host, whost[:])
	pw, pok := ascii_wide(path, wpath[:])
	aw, aok := ascii_wide(HTTP_USER_AGENT, wagent[:])
	if !hok || !pok || !aok {return nil, 0, .Network}

	// Handles are closed in reverse order of acquisition on EVERY exit below,
	// including the error returns -- `defer` is what makes that true without a
	// goto ladder, and a missed close here leaks WinHTTP's thread pool for the
	// life of the process.
	session := WinHttpOpen(aw, WINHTTP_ACCESS_TYPE_AUTOMATIC_PROXY, nil, nil, 0)
	if session == nil {
		// AUTOMATIC_PROXY needs Win 8.1. Fall back rather than tell the user their
		// network is broken when it is only an old OS.
		session = WinHttpOpen(aw, WINHTTP_ACCESS_TYPE_DEFAULT_PROXY, nil, nil, 0)
	}
	if session == nil {
		return nil, 0, http_result_for_error(u32(win.GetLastError()))
	}
	defer WinHttpCloseHandle(session)

	// Both timeouts, and the other two. Set on the session so every handle
	// derived from it inherits them; this is the single call that stops a dead
	// DNS from parking the worker for a minute per phase.
	t := i32(timeout_ms)
	WinHttpSetTimeouts(session, t, t, t, t)

	// No cookies, no credentials, no redirects. Refusing redirects outright is
	// stricter than "no cross-host redirects" and fails closed: a redirect
	// surfaces as a 3xx -> .Bad_Status -> "could not check", which is the right
	// answer when the endpoint has moved somewhere we did not agree to go.
	feat := u32(WINHTTP_DISABLE_COOKIES | WINHTTP_DISABLE_REDIRECTS | WINHTTP_DISABLE_AUTHENTICATION)
	WinHttpSetOption(session, WINHTTP_OPTION_DISABLE_FEATURE, &feat, size_of(feat))

	conn := WinHttpConnect(session, hw, WINHTTP_DEFAULT_HTTPS_PORT, 0)
	if conn == nil {
		return nil, 0, http_result_for_error(u32(win.GetLastError()))
	}
	defer WinHttpCloseHandle(conn)

	// WINHTTP_FLAG_SECURE is what makes this HTTPS; without it the same port
	// would be spoken to in plaintext. There is no code path here that omits it.
	req := WinHttpOpenRequest(conn, win.L("GET"), pw, nil, nil, nil, WINHTTP_FLAG_SECURE)
	if req == nil {
		return nil, 0, http_result_for_error(u32(win.GetLastError()))
	}
	defer WinHttpCloseHandle(req)

	// The same disable set on the request handle. The session-level option covers
	// handles created after it, but stating it here too costs one call and makes
	// the guarantee local to the request being sent.
	WinHttpSetOption(req, WINHTTP_OPTION_DISABLE_FEATURE, &feat, size_of(feat))

	// No additional headers, no body. The User-Agent rides on the session agent
	// string, which is where WinHTTP puts it.
	if WinHttpSendRequest(req, nil, 0, nil, 0, 0, 0) == win.FALSE {
		return nil, 0, http_result_for_error(u32(win.GetLastError()))
	}
	if WinHttpReceiveResponse(req, nil) == win.FALSE {
		return nil, 0, http_result_for_error(u32(win.GetLastError()))
	}

	code: u32
	code_len := u32(size_of(code))
	if WinHttpQueryHeaders(req, WINHTTP_QUERY_STATUS_CODE | WINHTTP_QUERY_FLAG_NUMBER, nil, &code, &code_len, nil) == win.FALSE {
		return nil, 0, http_result_for_error(u32(win.GetLastError()))
	}
	status = int(code)
	if r := http_result_for_status(status); r != .Ok {
		base.log_warn("http: %s%s -> HTTP %d", host, path, status)
		return nil, status, r
	}

	sink := Http_Sink {
		buf = make([dynamic]u8, 0, min(max_bytes, 16 * 1024), allocator),
		max = max_bytes,
	}
	chunk: [8 * 1024]u8
	for {
		n: u32
		if WinHttpReadData(req, raw_data(chunk[:]), u32(len(chunk)), &n) == win.FALSE {
			delete(sink.buf)
			return nil, status, http_result_for_error(u32(win.GetLastError()))
		}
		if n == 0 {break} // end of response
		// The cap is applied HERE, before the bytes are kept -- not to the
		// finished buffer. A server that streams gigabytes gets refused after one
		// chunk past the limit instead of after we have allocated all of it.
		if !http_sink_push(&sink, chunk[:n]) {
			delete(sink.buf)
			base.log_warn("http: %s%s exceeded %d bytes; refused", host, path, max_bytes)
			return nil, status, .Too_Large
		}
	}

	base.log_info("http: %s%s -> HTTP %d, %d bytes", host, path, status, len(sink.buf))
	return sink.buf[:], status, .Ok
}
