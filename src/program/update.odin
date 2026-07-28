// Layer: program — the manual update check: Help ▸ Check for Updates.
//
// One HTTPS GET to the GitHub Releases API, a numeric compare against
// NEWTPAD_VERSION, and either "you are up to date", an offer to open the release
// page, or "could not check". Nothing runs on a timer; there is no background
// traffic and no telemetry, because the audience this editor is for actively
// rejects both (research §D). The only bytes that leave the machine are a plain
// GET with a product-name User-Agent — no identifiers, no query parameters.
//
// **The request never runs on the UI thread.** CLAUDE.md: the main thread builds
// UI and handles input and nothing else. A synchronous WinHTTP call on it freezes
// the window for the connect timeout on a captive portal, which is exactly the
// network people are on when they wonder whether the app is broken. The worker
// follows the same shape as the line-count indexer (doc.odin's Line_Index) and the
// search worker (find.odin): copy nothing that can move, work in private memory,
// publish once, cancel via a polled flag, and join on teardown.
//
// **The version compare is the part that will be wrong if anything is.**
// "v0.19.0" vs "v0.9.0" is not a string compare — string order says 0.9.0 wins.
// It parses three integers, and a tag it cannot parse is "could not check", never
// "up to date". The safe answer when we do not know is not silence.
package main

import "base:intrinsics"
import "core:strings"
import "core:thread"
import base "src:base"
import plat "src:platform"

UPDATE_HOST :: "api.github.com"
UPDATE_PATH :: "/repos/WGuethlein/Newtpad/releases/latest"
// Where the user is sent if they want the new version. The human page, not the
// API — and a constant, never anything assembled from the response, so a
// compromised or spoofed API can direct the browser nowhere we did not choose.
UPDATE_RELEASES_URL :: "https://github.com/WGuethlein/Newtpad/releases/latest"

// The real response is ~3.5 KB. 256 KB is generous room for release notes and
// still refuses anything absurd rather than allocating it (platform/http.odin
// enforces this inside the read loop).
UPDATE_MAX_BYTES :: 256 * 1024

// Per WinHTTP phase (resolve / connect / send / receive), not for the whole
// call. It is deliberately short because `update_stop` JOINS this thread at
// teardown and a blocking WinHTTP call cannot be interrupted — so this number is
// also the worst case for how long closing the window can wait on a check that
// is in flight. Longer is friendlier to a slow link and worse at exit; four
// seconds is the compromise.
UPDATE_TIMEOUT_MS :: 4000

// Longest tag we will keep. Real tags are "v0.19.0"; anything approaching this is
// already not a version.
UPDATE_TAG_MAX :: 64

Update_Status :: enum u8 {
	Idle, // never run
	Up_To_Date,
	Newer,
	Failed, // "could not check" — `reason` says why
}

// One check. Lives on the App; there is at most one in flight (update_start
// refuses a second) because two would race to publish into the same fields for
// no benefit.
//
// Everything below `th` is written by the worker and read by the main thread,
// and the handoff is the join in `update_poll`, not the `done` flag: `done` only
// tells the main thread that joining will not block. Reading the payload after
// `thread.join` needs no atomics and no ordering argument, which is why the tag
// is a fixed array and `reason` is always a string literal — nothing crosses the
// thread boundary that either side has to free.
Update_Check :: struct {
	th:      ^thread.Thread,
	cancel:  bool, // atomic
	done:    bool, // atomic
	status:  Update_Status,
	tag:     [UPDATE_TAG_MAX]u8,
	tag_len: int,
	reason:  string, // literal; empty unless status == .Failed
}

// --- version compare (pure) -------------------------------------------------

// Longest run of digits accepted per component. A version number is not a
// bignum, and refusing an absurd one is better than silently wrapping: an
// overflowed component could compare as *smaller* than the running version and
// turn a real update into "you are up to date".
@(private = "file")
VERSION_DIGITS_MAX :: 9

// "v0.19.0" / "0.19.0" -> (0, 19, 0). ok=false on anything else: a missing or
// extra component, a non-numeric component, an empty component, trailing text,
// or a component too long to hold. Callers must treat !ok as "could not check".
version_parse :: proc(s: string) -> (major, minor, patch: int, ok: bool) {
	t := s
	// The leading `v` is optional because GitHub tags carry it and the constant
	// in version.odin does not; both must parse to the same triple or every
	// comparison is off by a prefix.
	if len(t) > 0 && (t[0] == 'v' || t[0] == 'V') {t = t[1:]}

	out: [3]int
	at := 0
	for i in 0 ..< 3 {
		if i > 0 {
			if at >= len(t) || t[at] != '.' {return 0, 0, 0, false}
			at += 1
		}
		start := at
		n := 0
		for at < len(t) && t[at] >= '0' && t[at] <= '9' {
			n = n * 10 + int(t[at] - '0')
			at += 1
		}
		digits := at - start
		if digits == 0 || digits > VERSION_DIGITS_MAX {return 0, 0, 0, false}
		out[i] = n
	}
	// Trailing anything — "0.19.0.1", "0.19.0-rc1", "0.19.0 " — is not a version
	// we know how to order, so it is not a version. Pre-release suffixes would
	// need real precedence rules; refusing is honest and says "could not check".
	if at != len(t) {return 0, 0, 0, false}
	return out[0], out[1], out[2], true
}

// Strictly newer, component by component. Equal is NOT newer — a released build
// checking against its own tag must say "up to date", not offer itself.
version_newer :: proc(a, b: [3]int) -> bool {
	for i in 0 ..< 3 {
		if a[i] != b[i] {return a[i] > b[i]}
	}
	return false
}

// --- response parsing (untrusted bytes) -------------------------------------

// Pull `tag_name`'s value out of a GitHub release JSON document, into `out`.
// The returned string aliases `out`, so it lives exactly as long as the caller's
// buffer.
//
// A hand-rolled scan rather than a JSON dependency: one field does not justify a
// parser, and the dependency bar says hand-roll when in doubt. The input is
// bytes from the network, so nothing here trusts the shape of the document —
// every step can fail and every failure is "could not check".
//
// `"tag_name"` can legitimately appear inside another string (release notes
// quoting the field name), so a candidate that is not followed by `: "..."` is
// skipped rather than treated as a malformed document.
update_extract_tag :: proc(body: []u8, out: []u8) -> (tag: string, ok: bool) {
	KEY :: "\"tag_name\""
	s := string(body)
	at := 0
	for {
		i := strings.index(s[at:], KEY)
		if i < 0 {return "", false}
		p := at + i + len(KEY)
		at = p // next candidate starts after this key, whatever happens below

		for p < len(s) && (s[p] == ' ' || s[p] == '\t' || s[p] == '\r' || s[p] == '\n') {p += 1}
		if p >= len(s) || s[p] != ':' {continue}
		p += 1
		for p < len(s) && (s[p] == ' ' || s[p] == '\t' || s[p] == '\r' || s[p] == '\n') {p += 1}
		// A null tag_name is valid JSON and means "no tag", not "parse error" —
		// but it is still nothing we can compare, so it fails like everything else.
		if p >= len(s) || s[p] != '"' {continue}
		p += 1

		start := p
		for p < len(s) && s[p] != '"' {
			// An escape means the value is not a plain tag. Real tags are
			// [A-Za-z0-9.\-_]; decoding \u sequences here would be a JSON string
			// parser, which is the dependency this scan exists to avoid. Refuse.
			if s[p] == '\\' {return "", false}
			p += 1
		}
		// Ran off the end without a closing quote: the body was truncated.
		if p >= len(s) {return "", false}
		val := s[start:p]
		if len(val) == 0 || len(val) > len(out) {return "", false}
		copy(out, transmute([]u8)val)
		return string(out[:len(val)]), true
	}
}

// Why a check failed, as a literal so nothing has to own it across the thread
// boundary. Every branch is "could not check" — none of them may ever be
// presented as "up to date".
update_http_reason :: proc(res: plat.Http_Result, status: int) -> string {
	switch res {
	case .Ok:
		return "" // not a failure
	case .Timeout:
		return "the connection to GitHub timed out"
	case .Network:
		return "could not reach GitHub"
	case .Too_Large:
		return "GitHub's reply was larger than expected"
	case .Bad_Status:
		return "GitHub refused the request" // includes a refused redirect
	}
	return "the check did not complete"
}

// The whole decision, as a pure function of what the network produced. Split out
// of the worker deliberately: "a tag that does not parse is could-not-check,
// never up-to-date" is a claim about this table, and a claim that can only be
// exercised by making a real request is a claim nothing checks. `updatetest`
// drives every row of it — every Http_Result, and every way a body can be
// hostile — with no socket involved.
//
// `tag` aliases `tag_out` and is empty on failure. A non-.Failed result ALWAYS
// means both versions parsed; there is no path to .Up_To_Date that skipped a
// comparison.
update_decide :: proc(
	res: plat.Http_Result,
	http_status: int,
	body: []u8,
	current: string,
	tag_out: []u8,
) -> (
	st: Update_Status,
	tag: string,
	reason: string,
) {
	if res != .Ok {
		return .Failed, "", update_http_reason(res, http_status)
	}
	got, tok := update_extract_tag(body, tag_out)
	if !tok {
		return .Failed, "", "GitHub's reply did not contain a version tag"
	}
	tmaj, tmin, tpat, tpok := version_parse(got)
	if !tpok {
		return .Failed, "", "the published version tag could not be read"
	}
	// The running build's own constant is parsed too, and a failure here is also
	// "could not check". Assuming it parses would make a typo in version.odin
	// silently answer every check with "up to date".
	cmaj, cmin, cpat, cpok := version_parse(current)
	if !cpok {
		return .Failed, "", "this build's own version could not be read"
	}
	if version_newer({tmaj, tmin, tpat}, {cmaj, cmin, cpat}) {
		return .Newer, got, ""
	}
	return .Up_To_Date, got, ""
}

// --- the worker -------------------------------------------------------------

@(private = "file")
update_worker :: proc(data: rawptr) {
	u := (^Update_Check)(data)
	// Set last, always, on every path: `update_poll` will not join until it is
	// set, so a worker that returns without setting it is a thread the main loop
	// waits on forever.
	defer intrinsics.atomic_store(&u.done, true)

	fail :: proc(u: ^Update_Check, why: string) {
		u.status = .Failed
		u.reason = why
	}

	// Polled at each point where there is real work still to come. It cannot
	// interrupt the blocking WinHTTP call in the middle — that is what
	// UPDATE_TIMEOUT_MS bounds — but it stops us doing anything further for a
	// window that is already closing.
	if intrinsics.atomic_load(&u.cancel) {
		fail(u, "the check was cancelled")
		return
	}

	body, status, res := plat.http_get(UPDATE_HOST, UPDATE_PATH, UPDATE_MAX_BYTES, UPDATE_TIMEOUT_MS)
	defer delete(body)

	if intrinsics.atomic_load(&u.cancel) {
		fail(u, "the check was cancelled")
		return
	}

	// Everything past this point is the pure decision table. The worker holds no
	// judgement of its own, which is what lets updatetest exercise all of it.
	st, tag, reason := update_decide(res, status, body, NEWTPAD_VERSION, u.tag[:])
	u.status = st
	u.tag_len = len(tag)
	u.reason = reason
	if st == .Failed {
		base.log_warn("update: could not check (%v, HTTP %d, %d bytes): %s", res, status, len(body), reason)
	} else {
		base.log_info("update: latest=%s running=%s -> %v", tag, NEWTPAD_VERSION, st)
	}
}

// --- lifecycle (main thread only) -------------------------------------------

update_running :: proc(u: ^Update_Check) -> bool {
	return u.th != nil && !intrinsics.atomic_load(&u.done)
}

// Reap a finished worker. Idempotent; returns true if a result was just
// collected (so update_poll knows to surface it exactly once).
@(private = "file")
update_reap :: proc(u: ^Update_Check) -> bool {
	if u.th == nil || !intrinsics.atomic_load(&u.done) {return false}
	thread.join(u.th) // already done; this cannot block
	thread.destroy(u.th)
	u.th = nil
	return true
}

// Start a check. One request in flight: a second invocation while one is running
// says so rather than spawning another.
update_start :: proc(app: ^App) {
	u := &app.update
	if update_running(u) {
		app_note(app, "Already checking for updates...")
		return
	}
	update_reap(u) // a previous result whose worker was never joined
	u.status = .Idle
	u.reason = ""
	u.tag_len = 0
	intrinsics.atomic_store(&u.done, false)
	intrinsics.atomic_store(&u.cancel, false)
	u.th = thread.create_and_start_with_data(u, update_worker)
	if u.th == nil {
		intrinsics.atomic_store(&u.done, true)
		app_note(app, "[COULD NOT CHECK FOR UPDATES]")
		base.log_error("update: could not start the worker thread")
		return
	}
	app_note(app, "Checking github.com for updates...")
}

// Cancel and join. Called from app_destroy, before anything the worker's fields
// live in goes away. A worker that outlives the window is worse than no updater:
// it writes into a freed App and, if the process is mid-teardown, into a freed
// heap. The join can block for up to UPDATE_TIMEOUT_MS because a synchronous
// WinHTTP call cannot be interrupted — that bounded wait is the price, and it is
// the reason the timeout is four seconds rather than thirty.
update_stop :: proc(u: ^Update_Check) {
	if u.th == nil {return}
	intrinsics.atomic_store(&u.cancel, true)
	thread.join(u.th)
	thread.destroy(u.th)
	u.th = nil
}

// Once per frame. Collects a finished check and tells the user. Nothing here
// runs while the worker does — the whole point is that the frame loop keeps
// drawing until this picks a result up.
update_poll :: proc(app: ^App, w: ^plat.Window) {
	u := &app.update
	if !update_reap(u) {return}

	switch u.status {
	case .Up_To_Date:
		app_note(app, strings.concatenate({"Newtpad ", NEWTPAD_VERSION, " is the latest version."}, context.temp_allocator))
	case .Newer:
		latest := string(u.tag[:u.tag_len])
		msg := strings.concatenate(
			{
				"Newtpad ",
				latest,
				" is available.\n\nYou are running ",
				NEWTPAD_VERSION,
				".\n\nOpen the releases page in your browser?",
			},
			context.temp_allocator,
		)
		if plat.confirm_question(w.hwnd if w != nil else nil, msg) {
			if !plat.shell_open_url(UPDATE_RELEASES_URL) {
				app_note(app, "[COULD NOT OPEN THE RELEASES PAGE]")
			}
		}
	case .Failed:
		// The reason goes in the log, not the status bar: the bar is one short
		// line and the distinction between "timed out" and "GitHub refused the
		// request" is a diagnostic, not something to act on.
		base.log_warn("update: could not check — %s", u.reason)
		app_note(app, "[COULD NOT CHECK FOR UPDATES]")
	case .Idle:
	// A reaped worker always set one of the three above; nothing to say.
	}
	u.status = .Idle
}
