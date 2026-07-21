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
package main

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

// Does this look like a path worth offering? Requires either a directory
// separator or a known text extension, so ordinary prose words do not become
// links. This is the main false-positive guard for relative paths.
@(private = "file")
looks_like_path :: proc(s: string) -> bool {
	if len(s) < 3 {return false}
	if has_uri_scheme(s) {return false}
	has_sep := strings.contains(s, "\\") || strings.contains(s, "/")
	return has_sep || link_is_text_ext(s)
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

// One link, placed on screen. This is the single producer of link geometry:
// the draw, the hover and the click all consume it, so the span that underlines
// and the span that is clickable cannot disagree. Producing geometry twice is
// the seam-bug class this codebase keeps generating — see HANDOFF §6j.
Link_Hit :: struct {
	row:   int, // visual row within the viewport
	col:   int, // starting cell
	cells: int,
	text:  string, // temp copy of the row's drawn text; link offsets index this
	link:  Link,
}

// Links on the visible rows. Temp-allocated, rebuilt per frame.
//
// Only called while Ctrl is held, which is both the gesture and the reason this
// costs nothing the rest of the time. Bounded by the same VISIBLE_COLS the draw
// uses, so a 100 MB single-line file scans a screen's worth, not a file's.
links_layout :: proc(doc: ^Document, t: ^plat.Text, rows: int, allocator := context.temp_allocator) -> []Link_Hit {
	out := make([dynamic]Link_Hit, 0, 8, allocator)
	if doc == nil {return out[:]}
	line_buf: [VISIBLE_COLS]u8
	it := visible_begin(doc, t, rows)
	for {
		row, start, end, _, _, ok := visible_next(&it)
		if !ok {break}
		draw_len := min(end - start, len(line_buf), LINK_SCAN_CAP)
		if draw_len <= 0 {continue}
		n := base.pt_read(&doc.pt, start, line_buf[:draw_len])
		vis := n
		if vis > 0 && line_buf[vis - 1] == '\r' {vis -= 1}
		if vis <= 0 {continue}
		// The row text has to outlive this loop iteration: line_buf is reused.
		text := strings.clone(string(line_buf[:vis]), allocator)
		for l in links_scan(text, allocator) {
			col, cells := plat.text_span_cells(t, text, l.start, l.len, .Doc)
			append(&out, Link_Hit{row = row, col = col, cells = cells, text = text, link = l})
		}
	}
	return out[:]
}

// The link under a client-space point, or nil. Uses the same cell grid the
// underline is drawn on, through the same col_at_x/row_at_y everything else
// hit-tests with.
links_hit :: proc(hits: []Link_Hit, px, char_w, mx, my: f32) -> (Link_Hit, bool) {
	r := row_at_y(px, my)
	c := cell_at_x(char_w, mx) // inside-the-cell, not nearest-caret-boundary
	for h in hits {
		if h.row == r && c >= h.col && c < h.col + h.cells {
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

// Resolve a link against the document that contains it.
//
// Relative paths are anchored to the open document's folder and nothing else:
// never the process CWD (which is wherever Explorer launched us), never PATH,
// never a walk up through parents. An untitled buffer has no anchor, so
// relative links simply do not resolve there.
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
		if exists, _ := plat.path_exists(abs); !exists {return {}, false}
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

	exists, _ := plat.path_exists(abs)
	if !exists {return {}, false} // a broken link reaches no handler
	return Link_Target{path = abs, line = l.line, col = l.col}, true
}

// Act on a resolved link. Text-ish files become tabs; a directory (or any other
// non-text target) is revealed in Explorer, so nothing we did executed it.
link_activate :: proc(app: ^App, txt: ^plat.Text, t: Link_Target) -> bool {
	if t.is_url {
		return plat.shell_open_url(t.url)
	}
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
				off := plat.text_bytes_for_cells(txt, buf[:got], t.col - 1, .Doc)
				d.cursor = min(ls + off, end)
				d.anchor = d.cursor
			}
		}
	}
	return true
}
