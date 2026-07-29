// Layer: program — clickable links and file paths.
//
// The files Newtpad exists for are full of paths: build logs, stack traces,
// linter output, config files. Following one meant selecting, copying and
// opening it by hand. Ctrl+click now does it. See HANDOFF §6l for the decisions
// this was built to.
//
// Two rules shape everything here:
//
//  1. **Detection is viewport-scoped.** Only visible lines are scanned, per
//     frame, bounded by the visible cell range — never the whole document, and
//     never a whole line, because one "line" can be 100 MB.
//  2. **Never hand an arbitrary path to the shell.** Text the user is reading
//     may have been written by anyone. A text-ish file opens in a tab, anything
//     else is revealed in Explorer, and only whitelisted URL schemes reach the
//     browser.
//  3. **Never stat a non-local target.** Same threat model as (2), different
//     weapon: `GetFileAttributesW` on an unreachable UNC host blocks the caller
//     for the redirector timeout (>100 s measured), and the caller here is the
//     UI thread. link_resolve refuses UNC and non-fixed drives outright, so
//     `\\deadhost\share\out.log` in a build log costs nothing. See
//     plat.path_is_local and OWED below.
//
// OWED (HANDOFF): resolving non-local targets needs an async resolver — a worker
// that stats off-thread and feeds answers back into link_cache, the same shape
// watch.odin already uses. Until it exists, a UNC or mapped-drive link is text.
package main

import "core:fmt"
import "core:strings"
import base "src:base"
import plat "src:platform"

Link_Kind :: enum u8 {
	URL, // http://, https://, mailto:
	Path, // absolute (C:\...), UNC (\\server\...), or relative to the document
	Line_Ref, // any of the above with a :123 or :123:45 suffix
}

// How links are shown. Activation is always Ctrl+click (a plain click still
// edits), so this only governs the visual affordance, which VS Code-style
// Ctrl-only hiding makes undiscoverable until you know to hold Ctrl.
Link_Style :: enum u8 {
	Hover, // decorate only while Ctrl is held (default)
	Underline, // always underline + tint
	Tint, // always tint, no underline (underline still appears on Ctrl)
}

link_style_name :: proc(s: Link_Style) -> string {
	switch s {
	case .Hover:
		return "On Ctrl"
	case .Underline:
		return "Always, underlined"
	case .Tint:
		return "Always, tinted"
	}
	return "?"
}

// A link found inside one line of text. Offsets are bytes within that line, not
// the document — the caller knows which line it scanned.
Link :: struct {
	start: int,
	len:   int,
	kind:  Link_Kind,
	line:  int, // 1-based target line for Line_Ref, else 0
	col:   int, // 1-based target column for Line_Ref, else 0
	// Byte length of just the path/URL portion, excluding any :line:col suffix.
	// The whole thing underlines, but only this part resolves.
	target_len: int,
}

// Longest line we will scan for links. A minified JSON or an unrotated log can
// be one line of hundreds of megabytes; the viewport shows a few hundred cells
// of it. Scanning the whole logical line to decorate a fraction of it would be
// the same uncapped-scan bug the status bar had.
LINK_SCAN_CAP :: 4096

// Characters that end a bare path or URL. Space is deliberately absent for
// paths — see path_end below, where it is handled as a special case.
@(private = "file")
is_delim :: proc(b: u8) -> bool {
	switch b {
	case ' ', '\t', '\r', '\n', '"', '\'', '<', '>', '|', '*', '?':
		return true
	}
	return false
}

// Trailing bytes that are almost always sentence punctuation rather than part
// of the target. `see http://example.com/x.` must not include the period.
@(private = "file")
trim_trailing :: proc(s: string) -> string {
	out := s
	for len(out) > 0 {
		switch out[len(out) - 1] {
		case '.', ',', ';', ':', '!', '?':
			out = out[:len(out) - 1]
			continue
		case ')', ']', '}':
			// Keep a closer that is balanced within the run — wiki URLs like
			// /a_(b) are common — and drop one that is not, which is the far more
			// common "(see http://x)" case.
			open: u8 = '(' if out[len(out) - 1] == ')' else ('[' if out[len(out) - 1] == ']' else '{')
			depth := 0
			for i in 0 ..< len(out) {
				if out[i] == open {depth += 1}
				if out[i] == out[len(out) - 1] {depth -= 1}
			}
			if depth < 0 {
				out = out[:len(out) - 1]
				continue
			}
		}
		break
	}
	return out
}

@(private = "file")
is_alpha :: proc(b: u8) -> bool {return (b >= 'a' && b <= 'z') || (b >= 'A' && b <= 'Z')}

@(private = "file")
is_digit :: proc(b: u8) -> bool {return b >= '0' && b <= '9'}

// smb://host/share/path is how a Unix/macOS tool or a chat client writes a
// Windows network share. Windows has no smb: protocol handler, so we detect it
// here and link_resolve rewrites it to the UNC form \\host\share\path, which
// then flows through the same path-safety checks as any other path.
@(private = "file")
is_smb_url :: proc(s: string) -> bool {
	return len(s) > 6 && strings.equal_fold(s[:6], "smb://")
}

// Known text-ish extensions. A path ending in one of these opens in a tab;
// everything else is revealed in Explorer instead.
//
// The list lives in ONE place — text_exts.txt at the repo root — embedded here at
// compile time and read by install.ps1 for the Explorer registration. Two hand-
// maintained copies used to drift (this list had .cpp/.cs/.go/…; the installer
// had .markdown); a single source is the only thing that keeps them in step.
@(private = "file")
TEXT_EXTS_RAW :: #load("../../text_exts.txt", string)

@(private = "file")
text_exts_cache: []string

@(private = "file")
text_exts_list :: proc() -> []string {
	if text_exts_cache == nil {
		out := make([dynamic]string, 0, 40) // process-lifetime; slices into static data
		raw := TEXT_EXTS_RAW // a ^string for the iterator; the bytes are static
		for ln in strings.split_lines_iterator(&raw) {
			s := strings.trim_space(ln)
			if len(s) > 0 {append(&out, s)}
		}
		text_exts_cache = out[:]
	}
	return text_exts_cache
}

link_is_text_ext :: proc(path: string) -> bool {
	for ext in text_exts_list() {
		if len(path) >= len(ext) && strings.equal_fold(path[len(path) - len(ext):], ext) {
			return true
		}
	}
	return false
}

// Is this token a URI with a scheme, rather than a path? A one-character scheme
// is a drive letter and is handled by the absolute branch; anything longer is a
// URI, and if it were openable the URL branch would already have taken it.
//
// This guard is why `ms-msdt:/id` does not become a link. It contains a slash,
// so the path heuristic below happily accepted it, and although link_resolve
// would refuse to open it (no such file), it still rendered underlined —
// advertising a target we would decline. The handler schemes that matter here
// (ms-msdt:, search-ms:, ms-officecmd:) all arrive in exactly this shape.
@(private = "file")
has_uri_scheme :: proc(s: string) -> bool {
	for i in 0 ..< len(s) {
		c := s[i]
		if c == ':' {return i > 1}
		if !(is_alpha(c) || is_digit(c) || c == '+' || c == '.' || c == '-') {return false}
	}
	return false
}

// Does this look like a path worth offering?
//
// A bare separator is NOT evidence. This used to accept any token containing a
// '/' or a '\', which made `hello/world`, `and/or`, `24/7`, `he/she`, `km/h`
// and every date written `07/28/2026` into links -- Wyatt reported exactly that.
// English writes a slash between two words all day long; a filesystem does not
// care. So require a signal only a path has: a known text extension, or a
// prefix that names a root or an anchor.
//
// Note what the tightening does NOT cost. `src/main.odin`, `build\out.log` and
// every other compiler/linter line still match on their extension, which is the
// case this feature exists for. What it drops is precisely the set that could
// never resolve anyway -- see links_layout, which now refuses to decorate
// anything link_resolve declines, so the two guards agree by construction
// rather than by coincidence.
@(private = "file")
looks_like_path :: proc(s: string) -> bool {
	if len(s) < 3 {return false}
	if has_uri_scheme(s) {return false} // ms-msdt:/id and friends: never a path
	if link_is_text_ext(s) {return true}
	if strings.has_prefix(s, "./") || strings.has_prefix(s, ".\\") {return true} // explicit "here"
	if strings.has_prefix(s, "../") || strings.has_prefix(s, "..\\") {return true} // (link_resolve still refuses the walk)
	if strings.has_prefix(s, "~/") {return true}
	if strings.has_prefix(s, "\\\\") {return true} // UNC
	if s[0] == '/' || s[0] == '\\' {return true} // rooted
	if is_alpha(s[0]) && s[1] == ':' && (s[2] == '\\' || s[2] == '/') {return true} // drive
	return false
}

// Split a trailing :line or :line:col from a candidate. Returns the target
// length and the parsed numbers.
//
// The trap: "C:\dir\x.txt" must not read as target "C" at line 0. A single
// letter followed by a colon at the very start is a drive, so parsing only ever
// looks at colons after the third byte, and only accepts all-digit runs.
@(private = "file")
split_line_ref :: proc(s: string) -> (target_len, line, col: int) {
	target_len = len(s)
	// Walk back over :digits groups, at most twice (line then column).
	rest := s
	for _ in 0 ..< 2 {
		ci := strings.last_index_byte(rest, ':')
		if ci < 2 {break} // < 2 keeps the drive-letter colon out of reach
		digits := rest[ci + 1:]
		if len(digits) == 0 {break}
		all_digits := true
		for i in 0 ..< len(digits) {
			if !is_digit(digits[i]) {all_digits = false;break}
		}
		if !all_digits {break}
		n := 0
		for i in 0 ..< len(digits) {n = n * 10 + int(digits[i] - '0')}
		// First group found from the right is the column if we find a second.
		col = line
		line = n
		rest = rest[:ci]
		target_len = ci
	}
	return
}

// Scan one line of text for links. Results are temp-allocated and point into
// `text` by offset. `text` is expected to be already capped by the caller.
links_scan :: proc(text: string, allocator := context.temp_allocator) -> []Link {
	out := make([dynamic]Link, 0, 4, allocator)
	i := 0
	for i < len(text) {
		b := text[i]

		// --- URLs -----------------------------------------------------------
		if is_alpha(b) {
			rest := text[i:]
			matched := false
			for scheme in ([]string{"http://", "https://", "mailto:"}) {
				if len(rest) > len(scheme) && strings.equal_fold(rest[:len(scheme)], scheme) {
					j := i + len(scheme)
					for j < len(text) && !is_delim(text[j]) {j += 1}
					run := trim_trailing(text[i:j])
					if len(run) > len(scheme) {
						append(&out, Link{start = i, len = len(run), kind = .URL, target_len = len(run)})
						i += len(run)
						matched = true
					}
					break
				}
			}
			if matched {continue}
		}

		// --- smb:// share URLs (resolved as Windows UNC paths) --------------
		// Rejected by looks_like_path (has_uri_scheme), so caught here first;
		// link_resolve rewrites the token to \\host\share\path.
		if (b == 's' || b == 'S') && is_smb_url(text[i:]) {
			j := i + 6
			for j < len(text) && !is_delim(text[j]) {j += 1}
			run := trim_trailing(text[i:j])
			if len(run) > 6 {
				tl, ln, cl := split_line_ref(run)
				append(
					&out,
					Link {
						start = i,
						len = len(run),
						kind = .Line_Ref if ln > 0 else .Path,
						line = ln,
						col = cl,
						target_len = tl,
					},
				)
				i += len(run)
				continue
			}
		}

		// --- UNC paths ------------------------------------------------------
		if b == '\\' && i + 1 < len(text) && text[i + 1] == '\\' {
			j := i + 2
			for j < len(text) && !is_delim(text[j]) {j += 1}
			run := trim_trailing(text[i:j])
			if len(run) > 4 {
				tl, ln, cl := split_line_ref(run)
				append(
					&out,
					Link {
						start = i,
						len = len(run),
						kind = .Line_Ref if ln > 0 else .Path,
						line = ln,
						col = cl,
						target_len = tl,
					},
				)
				i += len(run)
				continue
			}
		}

		// --- absolute drive paths -------------------------------------------
		if is_alpha(b) && i + 2 < len(text) && text[i + 1] == ':' && (text[i + 2] == '\\' || text[i + 2] == '/') {
			// Only at a token boundary, so "see C:\x" works but "abC:\x" does not.
			if i == 0 || is_delim(text[i - 1]) || text[i - 1] == '(' || text[i - 1] == '[' {
				j := i + 3
				for j < len(text) && !is_delim(text[j]) {j += 1}
				run := trim_trailing(text[i:j])
				tl, ln, cl := split_line_ref(run)
				append(
					&out,
					Link {
						start = i,
						len = len(run),
						kind = .Line_Ref if ln > 0 else .Path,
						line = ln,
						col = cl,
						target_len = tl,
					},
				)
				i += len(run)
				continue
			}
		}

		// --- markdown links: [label](target) -------------------------------
		// The clickable part is the target inside the parens; only it underlines
		// and resolves. Without this the whole "[label](http://x)" run is taken
		// as one path token — parens are not delimiters, so wiki URLs like
		// /a_(b) survive — and the markdown link resolved as a bogus relative
		// path and never opened.
		if b == '[' {
			if rb := strings.index_byte(text[i:], ']'); rb > 0 && i + rb + 1 < len(text) && text[i + rb + 1] == '(' {
				us := i + rb + 2 // start of the target, just past "]("
				j := us
				for j < len(text) && text[j] != ')' && !is_delim(text[j]) {j += 1}
				if j < len(text) && text[j] == ')' && j > us {
					inner := text[us:j]
					if plat.url_is_openable(inner) {
						append(&out, Link{start = us, len = j - us, kind = .URL, target_len = j - us})
						i = j + 1
						continue
					}
					tl, ln, cl := split_line_ref(inner)
					if tl > 0 && (is_smb_url(inner[:tl]) || looks_like_path(inner[:tl])) {
						append(
							&out,
							Link {
								start = us,
								len = j - us,
								kind = .Line_Ref if ln > 0 else .Path,
								line = ln,
								col = cl,
								target_len = tl,
							},
						)
						i = j + 1
						continue
					}
				}
			}
			// Not a markdown link: skip '[' so its inner content is still scanned
			// (e.g. "[C:\x]" continues to find the drive path inside).
			i += 1
			continue
		}

		// --- relative paths and bare file:line refs -------------------------
		// Only at a token boundary, and only when the run looks like a path
		// (contains a separator or ends in a known text extension). Without that
		// guard every word in prose becomes a candidate.
		if !is_delim(b) && (i == 0 || is_delim(text[i - 1]) || text[i - 1] == '(' || text[i - 1] == '[') {
			j := i
			for j < len(text) && !is_delim(text[j]) {j += 1}
			run := trim_trailing(text[i:j])
			tl, ln, cl := split_line_ref(run)
			if tl > 0 && looks_like_path(run[:tl]) {
				append(
					&out,
					Link {
						start = i,
						len = len(run),
						kind = .Line_Ref if ln > 0 else .Path,
						line = ln,
						col = cl,
						target_len = tl,
					},
				)
				i += max(len(run), 1)
				continue
			}
			i = j + 1 if j == i else j
			continue
		}

		i += 1
	}
	return out[:]
}

// Most distinct targets one viewport pass will stat. A bound, not a tuning
// knob: it exists so that a pathological screen -- a generated file that is
// nothing but thousands of paths, at a one-cell font -- cannot turn one frame
// into thousands of blocking filesystem calls. A real viewport is a couple of
// hundred rows with at most a link or two each, so this never bites in normal
// use, and a candidate skipped for budget is simply not decorated (the safe
// direction: it under-promises, never over-promises).
LINK_RESOLVE_BUDGET :: 256

// Why links_layout can afford to resolve at all.
//
// link_resolve stats the target (plat.path_exists -> GetFileAttributesW). That
// call has no timeout, and on a UNC or mapped-drive target it can block the
// calling thread for minutes -- which here is the thread that builds the UI.
// links_layout runs up to three times in one frame (the hover cursor, the
// Ctrl+click test, the draw), it runs every frame while Ctrl is merely HELD (so
// Ctrl+S is enough), and with the Show-links setting on "always" it runs every
// frame with no gesture at all. doc.top is part of the generation below, so every
// scroll step is a fresh generation that re-stats the screen.
//
// Two things make that affordable, and they are not interchangeable:
//
//   - link_resolve refuses non-local targets WITHOUT a syscall
//     (plat.path_is_local), which is what bounds the worst case in TIME. The
//     budget below bounds a count; a count is no defence when one call is
//     unbounded.
//   - this cache bounds how often the local ones are paid for.
//
// Four properties of the cache, each load-bearing:
//
//   1. It is filled ONLY from links_layout's own row walk, which is
//      visible_begin/visible_next -- the viewport and nothing else. There is no
//      other writer. An off-screen row therefore cannot cost a stat, because no
//      code path ever offers it one. (The Ctrl+click handler in main.odin calls
//      link_resolve directly, but only for the row the user clicked, which by
//      construction is on screen.)
//   2. Keyed on the raw target token, so the several row-segments of a single
//      force-wrapped link, and the repeated passes within a frame, share one
//      stat rather than one each.
//   3. Dropped whole when anything changes what the viewport is showing: a
//      different document, an edit (doc.revision), a scroll (doc.top), or a
//      re-anchor (doc.path moved, which changes what a relative link means).
//      That keeps answers fresh -- a file created after we looked becomes a link
//      on the next scroll or keystroke -- and bounds the map to one screenful of
//      distinct tokens.
//   4. Bounded per generation by LINK_RESOLVE_BUDGET above.
//
// Keys are cloned into the ordinary allocator and freed on reset: the tokens
// they are cloned from point into frame-arena text that is gone next frame.
//
// The key is the token ALONE, not (token, kind), and that is safe only because
// has_uri_scheme keeps a URL-shaped token off the .Path branch (see its comment).
// So no two Links with the same token text can ever have kinds that link_resolve
// answers differently. Loosen has_uri_scheme and this key becomes wrong: add
// `kind` to it in the same change.
@(private = "file")
Link_Cache :: struct {
	doc:      rawptr, // identity only, never dereferenced
	revision: u64,
	top:      int,
	anchor:   string, // OWNED copy of doc.path; see link_cache_sync
	budget:   int,
	entries:  map[string]bool, // owned keys: raw target token -> resolves
}

@(private = "file")
link_cache: Link_Cache

// Drop everything and re-stamp the generation. Called once per links_layout,
// and a no-op on the common case where the viewport has not moved.
//
// The anchor is held as an owned COPY and compared by value, not by pointer,
// and that is the whole reason this is safe against address reuse. Documents are
// heap-boxed and freed on close, so a fresh document can land on a just-closed
// one's address with the same revision (0) and the same top (0) -- every other
// field in the generation matches and the stale entries survive. Comparing the
// anchor by value removes the hazard rather than arguing about it: the only
// document-dependent input to link_resolve is the folder a relative link is
// anchored to, so two documents with the same anchor genuinely have the same
// answers, and two with different anchors reset. A pointer comparison would
// instead be reading a field of a document that no longer exists.
@(private = "file")
link_cache_sync :: proc(doc: ^Document) {
	if link_cache.doc == rawptr(doc) &&
	   link_cache.revision == doc.revision &&
	   link_cache.top == doc.top &&
	   link_cache.anchor == doc.path {
		return
	}
	for k in link_cache.entries {delete(k)}
	clear(&link_cache.entries)
	delete(link_cache.anchor)
	link_cache.doc = rawptr(doc)
	link_cache.revision = doc.revision
	link_cache.top = doc.top
	link_cache.anchor = strings.clone(doc.path)
	link_cache.budget = LINK_RESOLVE_BUDGET
}

// Would this candidate actually open? The gate links_layout gives every hit
// before it is allowed on screen.
//
// There is no `target_len <= 0` guard here: split_line_ref returns len(s) or a
// colon index >= 2 on every path, so every Link links_scan emits has target_len
// >= 2. A check that cannot fire is a check nobody maintains.
@(private = "file")
link_gate :: proc(doc: ^Document, text: string, l: Link) -> bool {
	raw := text[l.start:l.start + l.target_len]
	if v, hit := link_cache.entries[raw]; hit {return v}
	if link_cache.budget <= 0 {return false}
	link_cache.budget -= 1
	_, ok := link_resolve(doc, text, l)
	link_cache.entries[strings.clone(raw)] = ok
	return ok
}

// One link, placed on screen. This is the single producer of link geometry:
// the draw, the hover and the click all consume it, so the span that underlines
// and the span that is clickable cannot disagree. Producing geometry twice is
// the seam-bug class this codebase keeps generating — see HANDOFF §6j.
Link_Hit :: struct {
	row:   int, // visual row within the viewport
	col:   int, // starting cell on the row (underline + hit-test)
	cells: int, // cell span on the row
	// The visible portion of the link on THIS row, as a byte span within the row's
	// drawn text — what doc_draw colours. For a link that wraps across rows this is
	// only the segment on this row; the whole link still resolves via text+link.
	span_start: int,
	span_len:   int,
	wrapped:    bool, // on a force-wrapped row, which ignores the horizontal pan
	// The line the link was found on and the whole link within it, so a click on
	// any per-row segment resolves the entire target. For a wrapped link this is
	// the logical line (all its rows share it); for an unwrapped row it is the row.
	text: string,
	link: Link,
}

// Links on the visible rows. Temp-allocated, rebuilt per frame.
//
// Only called while Ctrl is held (or when the Show-links setting is on), which is
// the gesture and the reason it costs nothing otherwise. Bounded by VISIBLE_COLS
// and LINK_SCAN_CAP, so a 100 MB single-line file scans a screen's worth.
//
// A force-wrapped line's link must be detected on the whole LOGICAL line (a scan
// per visual row would see a link cut at the wrap point and mis-resolve the
// halves) and then split into per-row segments. Unwrapped rows keep the simple
// per-row scan.
//
// Every hit is gated on link_resolve before it is emitted, so the invariant the
// draw, the hover cursor and the click all rely on is **underlined implies
// openable**. It used to be possible to underline a target detection had
// invented -- `hello/world`, `ms-msdt:/id` -- which the click handler then
// silently declined to open, and that is what "the click doesn't work" was.
// Resolution is a stat, so it goes through link_cache above; read its comment
// before touching this.
links_layout :: proc(doc: ^Document, t: ^plat.Text, rows: int, allocator := context.temp_allocator) -> []Link_Hit {
	out := make([dynamic]Link_Hit, 0, 8, allocator)
	if doc == nil {return out[:]}
	link_cache_sync(doc)
	line_buf: [VISIBLE_COLS]u8
	// Cache of the current wrapped logical line, so its rows don't each rescan it.
	cur_lls := -1
	cur_line: string
	cur_links: []Link
	it := visible_begin(doc, t, rows)
	for {
		row, start, end, vis_end, _, wrapped, ok := visible_next(&it)
		if !ok {break}

		// A wrapped row is normally scanned as part of its whole logical line
		// (below), but only when that line is actually reachable: both scans
		// bounding it are capped, and a capped scan that came up short must not
		// be treated as though it saw the line.
		//
		//   - pt_line_start_cap reports exact=false past WRAP_START_CAP bytes
		//     into a line: what comes back is a scan floor that slides with the
		//     row, not a line start.
		//   - the read below stops at LINK_SCAN_CAP, so on a longer line it
		//     cannot cover a row past that point.
		//
		// Either way the rebase window ([row_off, row_end_off)) comes out empty
		// and the row is skipped — no underline, nothing clickable — on a
		// silently wrong premise, and the sliding floor makes the cache miss
		// once per row on top of it. Reachable only with word wrap ON, since a
		// line whose newline is past WRAP_START_CAP never force-wraps
		// (line_wrap_decision, doc.odin). This is the same bug, and the same
		// treatment, as doc_row_lex_extent's in the syntax highlighter: fall
		// back to scanning the ROW's own bytes. A link straddling the wrap
		// point then resolves to only its part of the row rather than whole,
		// which is a real (documented) loss — but it applies only to rows that
		// currently produce nothing at all. Note what that loss actually is:
		// links_scan runs on a FRAGMENT, so it can emit a hit for text that is
		// not a link in the document (a URL cut across the boundary leaves a
		// tail that scans as a .Path). It cannot become a different SITE — a
		// URL needs a whitelisted scheme (links_scan below) — and a spurious
		// path only resolves if such a file exists beside the document, so the
		// worst case is an underline that does nothing when clicked.
		lls, lend := 0, 0
		row_local := !wrapped
		if wrapped {
			exact: bool
			lls, exact = base.pt_line_start_cap(&doc.pt, start, WRAP_START_CAP)
			if exact {
				lend = base.pt_line_end_cap(&doc.pt, lls, LINK_SCAN_CAP)
				row_local = end > lend
			} else {
				row_local = true
			}
		}

		if row_local {
			// [start, vis_end), not end: a link at EOL must not absorb a CRLF's CR.
			draw_len := min(vis_end - start, len(line_buf), LINK_SCAN_CAP)
			if draw_len <= 0 {continue}
			n := base.pt_read(&doc.pt, start, line_buf[:draw_len])
			if n <= 0 {continue}
			text := strings.clone(string(line_buf[:n]), allocator) // outlive the loop
			for l in links_scan(text, allocator) {
				if !link_gate(doc, text, l) {continue} // underlined implies openable
				// col0 = 0: `text` was read from `start`, the VISUAL ROW's own
				// start, which is the origin doc_draw draws the row from and
				// therefore the origin tab stops are measured from (see
				// wrap_row_end). `col` comes back row-relative, which is what
				// links_hit compares against cell_at_x.
				col, cells := plat.text_span_cells(t, text, l.start, l.len, 0, .Doc)
				// `wrapped` still comes from the iterator, not from which branch
				// took the row: it is what tells links_hit whether the
				// horizontal pan applies (a wrapped row ignores it).
				append(&out, Link_Hit{row = row, col = col, cells = cells, span_start = l.start, span_len = l.len, wrapped = wrapped, text = text, link = l})
			}
			continue
		}

		// Wrapped row whose whole logical line IS reachable: scan it once, then
		// emit the portion of each link that lands here.
		if lls != cur_lls {
			cur_lls = lls
			cur_line, cur_links = "", nil
			if lend > lls {
				buf := make([]u8, lend - lls, allocator)
				got := base.pt_read(&doc.pt, lls, buf)
				cur_line = strings.clone(string(buf[:got]), allocator)
				cur_links = links_scan(cur_line, allocator)
			}
		}
		if len(cur_links) == 0 {continue}
		row_off := start - lls
		row_end_off := min(end - lls, len(cur_line))
		if row_off >= row_end_off {continue}
		row_text := cur_line[row_off:row_end_off]
		for l in cur_links {
			lo := max(l.start, row_off)
			hi := min(l.start + l.len, row_end_off)
			if lo >= hi {continue} // link doesn't touch this row
			// Gated AFTER that check, deliberately: cur_links covers the whole
			// (capped) logical line, whose other rows may be off-screen, and the
			// cache must never be asked about a row the viewport is not showing.
			if !link_gate(doc, cur_line, l) {continue} // underlined implies openable
			ss := lo - row_off // row-relative draw span
			// col0 = 0 even though `row_text` is a SLICE of the logical line:
			// it is sliced at row_off, i.e. it starts exactly at this visual
			// row's start, and tab stops are measured from the visual row start
			// (the documented wrap deviation -- doc.odin's wrap_row_end). The
			// logical line's column would be the wrong origin here, not the
			// more precise one.
			col, cells := plat.text_span_cells(t, row_text, ss, hi - lo, 0, .Doc)
			append(&out, Link_Hit{row = row, col = col, cells = cells, span_start = ss, span_len = hi - lo, wrapped = true, text = cur_line, link = l})
		}
	}
	return out[:]
}

// The link under a client-space point, or nil. Uses the same cell grid the
// underline is drawn on, through the same col_at_x/row_at_y everything else
// hit-tests with.
links_hit :: proc(hits: []Link_Hit, px, char_w, mx, my: f32) -> (Link_Hit, bool) {
	r := row_at_y(px, my)
	for h in hits {
		if h.row != r {continue}
		// inside-the-cell, not nearest-caret-boundary; a wrapped row ignores the pan.
		c := cell_at_x(char_w, mx, 0 if h.wrapped else H_SCROLL)
		if c >= h.col && c < h.col + h.cells {
			return h, true
		}
	}
	return {}, false
}

// The link containing byte offset `off` within the scanned line, or nil.
links_at :: proc(links: []Link, off: int) -> (Link, bool) {
	for l in links {
		if off >= l.start && off < l.start + l.len {
			return l, true
		}
	}
	return {}, false
}

// The link the caret is sitting in, if any, plus the line text it indexes.
// Scans only the caret's line, capped like every other line walk here.
link_at_cursor :: proc(doc: ^Document, allocator := context.temp_allocator) -> (line: string, l: Link, ok: bool) {
	if doc == nil {return "", {}, false}
	start := base.pt_line_start(&doc.pt, doc.cursor)
	end := base.pt_line_end_cap(&doc.pt, start, LINK_SCAN_CAP)
	n := end - start
	if n <= 0 {return "", {}, false}
	buf := make([]u8, n, allocator)
	got := base.pt_read(&doc.pt, start, buf)
	text := string(buf[:got])
	if len(text) > 0 && text[len(text) - 1] == '\r' {text = text[:len(text) - 1]}
	hit, found := links_at(links_scan(text, allocator), doc.cursor - start)
	return text, hit, found
}

// What a link resolves to. `path` is empty for a URL.
Link_Target :: struct {
	url:    string, // temp-allocated
	path:   string, // temp-allocated, absolute
	line:   int,
	col:    int,
	is_url: bool,
}

// Every stat link resolution has performed, for the tests. The claim "a non-local
// target is never stat'd" cannot be checked by looking at the answer -- a dead
// UNC and a refused UNC both come back `false` -- so the call itself is counted.
// Incremented immediately before each plat.path_exists below and nowhere else.
link_stat_count: int

// Stat a resolved absolute path, or refuse it because reaching the filesystem
// for it could block this thread for minutes. The single door: every stat on the
// resolution path goes through here, so the guard cannot be forgotten by one
// branch. See plat.path_is_local and rule 3 in this file's header.
@(private = "file")
link_stat :: proc(abs: string) -> (exists, is_dir: bool) {
	if !plat.path_is_local(abs) {return false, false}
	link_stat_count += 1
	return plat.path_exists(abs)
}

// Resolve a link against the document that contains it.
//
// Relative paths are anchored to the open document's folder and nothing else:
// never the process CWD (which is wherever Explorer launched us), never PATH,
// never a walk up through parents. An untitled buffer has no anchor, so
// relative links simply do not resolve there.
//
// A target that is not on a local fixed volume does not resolve, full stop --
// which also means links_layout never decorates one. Of the two ways to keep the
// UI thread off a network stat, refusing to decorate is the one that stays
// refused: decorating optimistically would just move the multi-minute block from
// the frame that draws the underline to the click that follows it. The cost is
// real and is recorded as owed at the top of this file: `\\server\share\x.log`
// and `smb://server/share/x` are plain text until the async resolver exists.
link_resolve :: proc(doc: ^Document, text: string, l: Link) -> (t: Link_Target, ok: bool) {
	raw := text[l.start:l.start + l.target_len]
	if l.kind == .URL {
		if !plat.url_is_openable(raw) {return {}, false}
		return Link_Target{url = strings.clone(raw, context.temp_allocator), is_url = true}, true
	}

	// smb://host/share/path -> \\host\share\path. Windows has no smb: handler, so
	// this becomes an ordinary UNC path and takes the path branch: stat'd first,
	// text-ish opens in a tab, anything else is revealed in Explorer.
	if is_smb_url(raw) {
		body, _ := strings.replace_all(raw[6:], "/", "\\", context.temp_allocator)
		abs := strings.concatenate({"\\\\", body}, context.temp_allocator)
		// Always UNC by construction, so link_stat always refuses it today.
		if exists, _ := link_stat(abs); !exists {return {}, false}
		return Link_Target{path = abs, line = l.line, col = l.col}, true
	}

	abs := ""
	is_abs :=
		(len(raw) >= 2 && raw[0] == '\\' && raw[1] == '\\') ||
		(len(raw) >= 3 && is_alpha(raw[0]) && raw[1] == ':' && (raw[2] == '\\' || raw[2] == '/'))
	if is_abs {
		abs = strings.clone(raw, context.temp_allocator)
	} else {
		if doc == nil || doc.path == "" {return {}, false} // no anchor
		dir := doc.path
		if ci := strings.last_index_any(dir, "\\/"); ci >= 0 {
			dir = dir[:ci]
		} else {
			return {}, false
		}
		rel := raw
		// "./x" and ".\x" are the same anchor, just drop the prefix.
		if len(rel) > 2 && rel[0] == '.' && (rel[1] == '\\' || rel[1] == '/') {rel = rel[2:]}
		// A parent walk is refused rather than resolved: the anchor is the
		// document's folder, full stop.
		if strings.contains(rel, "..") {return {}, false}
		abs = strings.concatenate({dir, "\\", rel}, context.temp_allocator)
	}

	exists, _ := link_stat(abs)
	// A broken link reaches no handler -- and so does a non-local one, which
	// link_stat declined to look at rather than blocking the UI thread on.
	if !exists {return {}, false}
	return Link_Target{path = abs, line = l.line, col = l.col}, true
}

// Follow a link the user asked to follow: resolve it, act on it, and SAY SO if
// either step fails. The one procedure behind all three routes -- Ctrl+click in
// the document, Ctrl+click in the table view, and the Open Link command -- which
// each used to carry their own copy and each ended it the same way:
//
//	if t, rok := link_resolve(...); rok { ...open... }
//	                                     <- and nothing at all otherwise
//
// Doing nothing is indistinguishable from a feature that does not work, and that
// is exactly how it was reported ("the click to goto link/explorer doesn't
// work"). links_layout now refuses to decorate anything that does not resolve,
// so the document view reaches the failure branch only when the target went away
// between the frame that drew the underline and the click -- but the table view
// and the keyboard command have no such gate in front of them at all, so for
// them this is the only thing standing between a dead target and silence.
//
// A non-local target (UNC, mapped drive) now lands in that same failure branch,
// deliberately: link_resolve refuses it without a syscall, so what the user gets
// is "Could not resolve" immediately instead of a frozen editor for the length of
// the SMB timeout. It is still reachable here — the table view and the Open Link
// command are not gated on decoration — which is exactly why the refusal lives in
// link_resolve rather than in links_layout's gate.
link_follow :: proc(app: ^App, t: ^plat.Text, w: ^plat.Window, doc: ^Document, text: string, l: Link) {
	if tgt, rok := link_resolve(doc, text, l); rok {
		if !link_activate(app, t, tgt) {
			plat.message_error(
				w.hwnd if w != nil else nil,
				fmt.tprintf("Could not open:\n\n%s", tgt.url if tgt.is_url else tgt.path),
			)
		}
		return
	}
	plat.message_error(
		w.hwnd if w != nil else nil,
		fmt.tprintf("Could not resolve:\n\n%s", text[l.start:l.start + l.target_len]),
	)
}

// Act on a resolved link. Text-ish files become tabs; a directory (or any other
// non-text target) is revealed in Explorer, so nothing we did executed it.
link_activate :: proc(app: ^App, txt: ^plat.Text, t: Link_Target) -> bool {
	if t.is_url {
		return plat.shell_open_url(t.url)
	}
	// Safe to stat directly: t.path only ever comes from a successful
	// link_resolve, which means it already passed link_stat's local-volume guard.
	_, is_dir := plat.path_exists(t.path)
	if is_dir || !link_is_text_ext(t.path) {
		return plat.shell_reveal(t.path)
	}
	if !app_open_path(app, t.path) {
		return false
	}
	if t.line > 0 {
		d := app_active(app)
		if d != nil {
			doc_goto_line(d, t.line)
			if t.col > 1 {
				// The column is 1-based cells (what the status bar reports), not
				// bytes: on a CJK/tab line those differ, so a byte offset landed the
				// caret in the wrong place. Map cells -> byte offset through the
				// line's own glyph widths, capped and clamped to the line end.
				ls := d.cursor // doc_goto_line left us at the line start
				end := base.pt_line_end_cap(&d.pt, ls, RENDER_LINE_CAP)
				buf := make([]u8, end - ls, context.temp_allocator)
				got := base.pt_read(&d.pt, ls, buf)
				// col0 = 0: `buf` was read from `ls`, the line start.
				off := plat.text_bytes_for_cells(txt, buf[:got], t.col - 1, 0, .Doc)
				d.cursor = min(ls + off, end)
				d.anchor = d.cursor
			}
		}
	}
	return true
}
