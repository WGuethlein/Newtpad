// Layer: program — a markdown renderer + preview, toggled per document (Ctrl+M
// cycles Off -> Preview -> Split). Like the table view, the underlying text is
// untouched; this lays the source out with headings, emphasis, code, lists,
// quotes, rules, links and simple tables. Bounded like every viewport pass:
// rendering walks source lines from a scroll offset and stops when the pane
// fills, so a huge markdown file previews without parsing all of it.
//
// Line-based, deliberately: a block is classified from its own prefix and its
// inline content is soft-wrapped to the pane. Consequences (v1): a paragraph's
// hard line breaks show as breaks (adjacent lines are not joined); there is no
// italic face loaded, so *italic* is shown as a tint, while **bold** is real via
// a double-draw; inline code is coloured, not boxed; tables are cell-split but
// not column-aligned across rows.
package main

import "core:fmt"
import "core:strings"
import base "src:base"
import plat "src:platform"

// Self-test for the pure parsing (block classifiers + inline runs); the rendering
// itself needs a live eye. Returns the failure count. Driven by `newtpad mdtest`.
md_selftest :: proc() -> (bad: int) {
	chk :: proc(bad: ^int, ok: bool, msg: string) {
		fmt.printfln("  %-40s %s", msg, "OK" if ok else "FAIL")
		if !ok {bad^ += 1}
	}
	// --- fenced code picks a lexer from its tag (batch 16) ---
	//
	// The mapping goes through highlight_lexer_for, so this also asserts the
	// fence and the file extension share one table rather than drifting.
	{
		chk(&bad, md_fence_lexer("```json") != nil, "```json -> a lexer")
		chk(&bad, md_fence_lexer("```cs") != nil, "```cs -> a lexer")
		chk(&bad, md_fence_lexer("~~~yaml") != nil, "~~~yaml -> a lexer")
		// Aliases that are not their own extension.
		chk(&bad, md_fence_lexer("```yml") != nil, "```yml -> a lexer (alias of yaml)")
		chk(&bad, md_fence_lexer("```csharp") != nil, "```csharp -> a lexer (alias of cs)")
		chk(&bad, md_fence_lexer("```bash") != nil, "```bash -> a lexer (alias of sh)")
		// Info strings carry more than the tag in real documents.
		chk(&bad, md_fence_lexer("```js title=\"x\"") != nil, "an info string past the tag is ignored")
		// And the negative cases, or "returns non-nil" proves nothing.
		chk(&bad, md_fence_lexer("```") == nil, "a bare fence has no lexer")
		chk(&bad, md_fence_lexer("```notalanguage") == nil, "an unknown tag has no lexer")
	}

	// --- nested blockquotes, front matter (batch 16) ---
	{
		q1, c1, d1 := md_quote_depth("> one")
		q2, c2, d2 := md_quote_depth(">> two")
		q3, c3, d3 := md_quote_depth("> > spaced")
		q4, _, d4 := md_quote_depth("plain")
		chk(&bad, q1 && d1 == 1 && c1 == "one", "> one -> depth 1")
		// The one that was broken: the second marker used to land in the TEXT.
		chk(&bad, q2 && d2 == 2 && c2 == "two", ">> two -> depth 2, marker not in the text")
		chk(&bad, q3 && d3 == 2 && c3 == "spaced", "> > spaced -> depth 2")
		chk(&bad, !q4 && d4 == 0, "plain -> not a quote")
	}

	// --- GFM strikethrough, escapes, task lists (batch 16) ---
	//
	// Each of these is a construct md_inline silently mis-parsed rather than
	// ignored, which is the worse failure: an unescaped asterisk did not render
	// as an asterisk, it toggled italics and restyled the rest of the line.
	{
		runs := md_inline("a ~~gone~~ b")
		hit := false
		for r in runs {
			if r.strike && r.text == "gone" {hit = true}
		}
		chk(&bad, hit, "~~gone~~ -> a struck run")
		// And the text either side is NOT struck, or the toggle never closed.
		clean := true
		for r in runs {
			if r.strike && r.text != "gone" {clean = false}
		}
		chk(&bad, clean, "...and nothing else on the line is struck")
	}
	{
		// The escape has to survive as a literal AND not toggle the style.
		runs := md_inline("literal \\* star")
		joined := ""
		ital := false
		for r in runs {
			joined = strings.concatenate({joined, r.text}, context.temp_allocator)
			if r.ital {ital = true}
		}
		chk(&bad, joined == "literal * star", "\\* -> a literal asterisk")
		chk(&bad, !ital, "...and it does not open italics")
	}
	{
		// A backslash before a letter is not an escape -- it is a path.
		runs := md_inline("C:\\temp\\file.txt")
		joined := ""
		for r in runs {joined = strings.concatenate({joined, r.text}, context.temp_allocator)}
		chk(&bad, joined == "C:\\temp\\file.txt", "a path keeps its backslashes")
	}
	{
		r1, d1, t1 := md_task("[ ] todo")
		r2, d2, t2 := md_task("[x] done")
		r3, _, t3 := md_task("[y] neither")
		r4, _, t4 := md_task("not a task")
		chk(&bad, t1 && !d1 && r1 == "todo", "[ ] todo -> unticked task")
		chk(&bad, t2 && d2 && r2 == "done", "[x] done -> ticked task")
		chk(&bad, !t3 && r3 == "[y] neither", "[y] is not a task box")
		chk(&bad, !t4 && r4 == "not a task", "plain text is not a task")
	}
	chk(&bad, md_heading_level("# H") == 1, "# H -> h1")
	chk(&bad, md_heading_level("### H") == 3, "### H -> h3")
	chk(&bad, md_heading_level("####### H") == 0, "7 hashes -> not a heading")
	chk(&bad, md_heading_level("#nospace") == 0, "no space -> not a heading")
	chk(&bad, md_heading_level("plain") == 0, "plain -> not a heading")
	chk(&bad, md_is_rule("---"), "--- is a rule")
	chk(&bad, md_is_rule("***"), "*** is a rule")
	chk(&bad, !md_is_rule("- item"), "- item is not a rule")
	{
		q, c := md_quote("> hi there")
		chk(&bad, q && c == "hi there", "> hi -> quote 'hi there'")
	}
	{
		b, c, d := md_list("- item")
		chk(&bad, b == "•" && c == "item" && d == 0, "- item -> bullet depth 0")
	}
	{
		b, c, d := md_list("    - nested")
		chk(&bad, b == "•" && c == "nested" && d == 2, "4-space - nested -> depth 2")
	}
	{
		b, c, _ := md_list("3. third")
		chk(&bad, b == "3." && c == "third", "3. third -> ordered")
	}
	{
		runs := md_inline("a **b** c")
		ok := len(runs) == 3 && runs[0].text == "a " && runs[1].text == "b" && runs[1].bold && runs[2].text == " c"
		chk(&bad, ok, "a **b** c -> [a ][B:b][ c]")
	}
	{
		runs := md_inline("x `code` y")
		ok := len(runs) == 3 && runs[1].text == "code" && runs[1].code
		chk(&bad, ok, "x `code` y -> code run")
	}
	{
		runs := md_inline("see [label](http://u)")
		ok := len(runs) >= 2 && runs[len(runs) - 1].link && runs[len(runs) - 1].text == "label" && runs[len(runs) - 1].url == "http://u"
		chk(&bad, ok, "[label](url) -> link run")
	}
	return
}

Md_Mode :: enum u8 {
	Off,
	Preview, // full-window rendered view (read-only)
	Split, // editor left, live preview right
}

md_mode_name :: proc(m: Md_Mode) -> string {
	switch m {
	case .Off:
		return "Off"
	case .Preview:
		return "Preview"
	case .Split:
		return "Split"
	}
	return "?"
}

// Column widths depend on the whole table block, so measuring them from the
// visible rows only would make them a function of scroll position — columns that
// shift as you scroll. The measure is therefore hoisted out of the draw and
// cached per block, keyed on the buffer revision. Within a block the widths are
// constant by construction, which is what makes shift-free scrolling a property
// of the design rather than something to test for.
//
// A block is bounded by content (it ends at the first non-table line), so the
// normal measure is O(block), not O(file). Past MD_TABLE_BUDGET the block skips
// measurement entirely and draws on fixed columns instead — O(1), not O(block):
// deterministic per row, so still shift-free, just not content-sized.
// Content-sizing an arbitrarily large block would need a background worker; see
// the batch-1 spec for why that is deferred.
MD_TABLE_BUDGET :: 1 * 1024 * 1024
MD_TABLE_MAX_COLS :: 32
MD_TABLE_FIXED_CELLS :: 16 // fixed column width past the budget
MD_TABLE_PAD :: 2 // cells of gap between columns

// The byte budget alone does not bound the WORK of finding a block's edges: a
// renamed CSV with 20-byte rows and the 1 MB budget is ~50k short rows in each
// direction, each costing a capped line-start scan plus a capped line-end scan
// (two 4 KB pt_reads and a treap descent apiece) before the byte guard ever
// trips. This caps the row COUNT per direction the same way MD_TABLE_BUDGET
// caps the byte span per direction, so the expensive scan itself is bounded
// even on pathologically short rows.
//
// The per-row cost is a FIXED 4 KB pt_read in each capped helper regardless of
// how short the row actually is (pt_line_start_cap and pt_line_end_cap both
// read in 4 KB chunks against RENDER_LINE_CAP), so the row cap's true worst
// case at the original 4096 was roughly 4096 rows * 2 reads backward + 4096 *
// 1 read forward + up to 4096 * 1 read in the (non-oversize) measure pass over
// the same span - about 50-67 MB copied and ~12k pt_reads on the single frame
// that enters an ordinary pipe-delimited log file, repeating on every revision
// bump, i.e. every keystroke in Split mode. 1024 is still far more rows than
// any screenful or any hand-authored table (a real table is a few dozen rows
// at most), cuts that worst case ~4x, and the fallback past it is the O(1)
// fixed-column path, not a correctness loss.
MD_TABLE_MAX_ROWS :: 1024

// md_table_bounds derives `oversize` from the byte budget and MD_TABLE_MAX_ROWS
// together (see the entry-dependence comment in md_table_bounds). If the budget
// were not comfortably larger than one capped line, the forward scan's very
// first guard check (against the entry row's own length) could trip before a
// single neighbour row is examined, collapsing the cache window to one row
// regardless of the true block size.
#assert(MD_TABLE_BUDGET > RENDER_LINE_CAP)

// Runtime copy of MD_TABLE_BUDGET. Production code never changes it; mdtabletest
// lowers it to drive md_table_bounds into the oversize path on a normal-sized
// fixture instead of needing a real >1 MB buffer to build and scan.
md_table_budget := MD_TABLE_BUDGET

// Runtime copy of MD_TABLE_MAX_ROWS, mirroring md_table_budget: production code
// never changes it; mdtabletest lowers it to drive the row-count guard on a
// normal-sized fixture instead of needing thousands of rows built and scanned.
md_table_max_rows := MD_TABLE_MAX_ROWS

// Four slots, not one: rows draw top-to-bottom, so with two table blocks on
// screen a single slot ends every frame holding the lower block and misses on
// the upper one the next frame — two full block measures per frame, in steady
// state, forever. Fixed-size array, so still no allocation.
MD_TABLE_SLOTS :: 4

Md_Align :: enum u8 {
	Left,
	Center,
	Right,
}

Md_Table_Cache :: struct {
	valid:    bool,
	start:    int, // byte offset of the block's first row
	end:      int, // offset of the last row's newline (pt_line_end_cap semantics)
	revision: u64,
	oversize: bool, // block exceeded MD_TABLE_BUDGET: fixed columns
	ncols:    int,
	widths:   [MD_TABLE_MAX_COLS]int, // cells, excluding padding
	align:    [MD_TABLE_MAX_COLS]Md_Align,
}

// A markdown table row, by the same test the renderer already used.
md_is_table_row :: proc(line: string) -> bool {
	return strings.contains(line, "|") && strings.count(line, "|") >= 2
}

// Split a row into cells, preserving empty ones. Strips at most one leading and
// one trailing pipe rather than trimming a character set from both ends — the
// old strings.trim(line, "| ") ate empty leading cells outright.
md_split_cells :: proc(line: string, allocator := context.temp_allocator) -> []string {
	s := strings.trim_right(line, " \t")
	if strings.has_prefix(s, "|") {s = s[1:]}
	if strings.has_suffix(s, "|") {s = s[:len(s) - 1]}
	parts := strings.split(s, "|", allocator)
	for &p in parts {p = strings.trim_space(p)}
	return parts
}

// Alignment markers on a separator cell: :--- / :--: / ---: / ---
@(private = "file")
md_cell_align :: proc(cell: string) -> Md_Align {
	c := strings.trim_space(cell)
	left := strings.has_prefix(c, ":")
	right := strings.has_suffix(c, ":")
	switch {
	case left && right:
		return .Center
	case right:
		return .Right
	}
	return .Left
}

// Read one line at `p` into `buf`, trailing CR removed. Returns the line, the
// offset of its end (at the newline, or the buffer end), and whether that end
// is a synthetic RENDER_LINE_CAP break rather than a real newline or EOF — a
// single row longer than the cap, which the caller must treat as a truncation
// of its own scan, not a real line boundary.
@(private = "file")
md_line_at :: proc(doc: ^Document, p: int, buf: []u8) -> (line: string, end: int, capped: bool) {
	end = base.pt_line_end_cap(&doc.pt, p, RENDER_LINE_CAP)
	capped = end < doc.pt.length && end - p >= RENDER_LINE_CAP
	n := base.pt_read(&doc.pt, p, buf[:min(end - p, len(buf))])
	if n > 0 && buf[n - 1] == '\r' {n -= 1}
	return string(buf[:n]), end, capped
}

// The contiguous run of table rows containing `p`. Scans backward to the block's
// true start and forward to its end, both bounded by md_table_budget so a file
// that is one enormous table cannot stall a frame.
//
// `p` need NOT be a line start. markdown_draw walks a line longer than
// RENDER_LINE_CAP in capped segments (`p = end + 1` where `end` came from
// `pt_line_end_cap`), so the second and later segments of such a line hand this
// function a mid-line offset as the entry point — `doc.top` can be one too, if
// the viewport happens to be scrolled there. A mid-line `p` cannot establish the
// block's real start (`start = p` below would be a lie), so it is deliberately
// forced oversize by the pt_line_start_cap seed just below rather than measuring
// a partial line and disagreeing with the segment drawn above it.
@(private = "file")
md_table_bounds :: proc(doc: ^Document, p: int) -> (start, end: int, oversize, ok: bool) {
	buf: [RENDER_LINE_CAP]u8
	line, lend, entry_capped := md_line_at(doc, p, buf[:])
	if !md_is_table_row(line) {return 0, 0, false, false}
	start, end = p, lend

	// Is `p` itself a real line start? Feeds trunc_back's seed value below (see
	// the doc comment above the invariant this checks).
	entry_line_start, entry_line_start_exact := base.pt_line_start_cap(&doc.pt, p, RENDER_LINE_CAP)
	entry_is_line_start := entry_line_start_exact && entry_line_start == p

	// Both bounds are measured from the ENTRY POINT `p`, never from the moving
	// `start`. Two traps here, both of which shipped once:
	//   - `start - q` is invariantly 0 (the loop assigns both from `ps`), so a guard
	//     written that way is dead code and the backward walk runs to byte 0 — on a
	//     renamed CSV that is the whole file, on the UI thread.
	//   - `r - start` in the forward loop is already past the budget the moment the
	//     backward walk moved `start`, so it trips on the first iteration and leaves
	//     `end` at the entry row. The cache window is then one row wide, every
	//     subsequent row misses, and the fallback becomes the most expensive path.
	// A window measured from `p` gives at least a budget's worth of cached rows
	// ahead of the viewport in both directions.
	//
	// A third trap, found after those two: `oversize` must NOT be "did a guard
	// fire while scanning", because which guard fires depends on `x = p - S`, the
	// entry offset within the block. For a block of size K < B <= 2K (K the
	// budget), entering near the top trips only the backward guard, entering near
	// the bottom trips only the forward one, and entering mid-block can trip
	// NEITHER — same block, three different answers depending on where the
	// viewport happened to land, which is exactly the scroll-dependent shift this
	// cache exists to prevent. So each direction only records that it was
	// truncated (`trunc_back` / `trunc_fwd`); `oversize` is derived once, after
	// both scans finish, from the window they produced — entry-independent by
	// construction (see the callers' case analysis over B in the batch-1 report).
	// trunc_back starts seeded from the mid-line-entry check above: a `p` that
	// isn't a real line start means `start = p` (set above) is not trustworthy,
	// so the block is forced oversize even if both scans below would otherwise
	// complete within budget.
	trunc_back, trunc_fwd := !entry_is_line_start, entry_capped
	q := p
	back_rows := 0
	for q > 0 {
		if p - q > md_table_budget {trunc_back = true;break}
		// pt_line_start is UNCAPPED: on a file with one enormous line containing
		// pipes it scans to byte 0 by itself. A non-exact result means the cap was
		// reached, which is a block boundary for our purposes.
		ps, exact := base.pt_line_start_cap(&doc.pt, q - 1, RENDER_LINE_CAP)
		if !exact {trunc_back = true;break}
		// md_line_at's own cap: `ps` is a real line start (exact, above), but the
		// line it starts may still run past RENDER_LINE_CAP before its own
		// newline — a single row longer than the cap, the same failure this
		// fixes on the forward side below.
		pl, _, pl_capped := md_line_at(doc, ps, buf[:])
		if !md_is_table_row(pl) {break}
		if pl_capped {trunc_back = true}
		back_rows += 1
		start = ps
		q = ps
		if back_rows > md_table_max_rows {trunc_back = true;break}
	}

	// Forward. Requires MD_TABLE_BUDGET > RENDER_LINE_CAP (asserted at the
	// constant) — otherwise this first check could trip on the entry row's own
	// length alone, before a single neighbour row is scanned, reproducing the
	// one-row cache window the comment above already names.
	r := lend
	fwd_rows := 0
	for r < doc.pt.length {
		if r - p > md_table_budget {trunc_fwd = true;break}
		ns := r + 1
		if ns > doc.pt.length {break}
		nl, ne, ne_capped := md_line_at(doc, ns, buf[:])
		if !md_is_table_row(nl) {break}
		if ne_capped {trunc_fwd = true}
		fwd_rows += 1
		end = ne
		r = ne
		if fwd_rows > md_table_max_rows {trunc_fwd = true;break}
	}

	// A row-count analogue of the same entry-dependence trap: if neither
	// direction's row cap trips, both scans ran to the block's true edges, so
	// `back_rows + fwd_rows + 1` IS the block's real total row count — entry-
	// independent — and must be checked against the cap too. Without this, a
	// block with, say, 200 short rows and a row cap of 120 would report oversize
	// when entered near either edge (one direction's own count exceeds 120) but
	// NOT when entered near the middle (each direction sees ~100, under the cap,
	// even though the block has 200 rows total) — the identical flip Important 1
	// fixes, one level down.
	total_rows := back_rows + fwd_rows + 1
	oversize = trunc_back || trunc_fwd || (end - start) > md_table_budget || total_rows > md_table_max_rows
	return start, end, oversize, true
}

// Per-column maxima across the whole block, plus the separator row's alignments.
// Returns the populated cache; caller owns storage.
//
// Package-visible rather than file-private so the mdtabletest mode can drive the
// O(1) oversized branch directly with `oversize=true`, without needing a real
// >1 MB fixture. That direct call bypasses md_table_bounds entirely, so it does
// NOT exercise how `oversize` gets set — two Criticals hid for a round behind
// exactly that gap. The bounds drive-through (lowering md_table_budget so a
// normal-sized fixture trips the real guards) is what actually tests oversize
// detection; this export is only for the measurement branch below it.
md_table_measure :: proc(doc: ^Document, t: ^plat.Text, start, end: int, oversize: bool) -> Md_Table_Cache {
	c := Md_Table_Cache {
		valid    = true,
		start    = start,
		end      = end,
		revision = doc.revision,
		oversize = oversize,
	}
	// Past the budget: fixed columns, and NO SCAN AT ALL. Every column is the same
	// width and every row draws at i*(width+pad), which depends on nothing outside
	// the row being drawn — so it is shift-free without measuring anything, and the
	// fallback is O(1) instead of O(block). Scanning the span here just to collect
	// ncols would reintroduce the per-row cost the budget exists to avoid, and the
	// draw already clips at x1, so a generous ncols costs nothing.
	if oversize {
		c.ncols = MD_TABLE_MAX_COLS
		for i in 0 ..< MD_TABLE_MAX_COLS {c.widths[i] = MD_TABLE_FIXED_CELLS}
		return c
	}

	buf: [RENDER_LINE_CAP]u8
	for p := start; p <= end && p < doc.pt.length; {
		line, lend, _ := md_line_at(doc, p, buf[:])
		if !md_is_table_row(line) {break}
		cells := md_split_cells(line, context.temp_allocator)
		if len(cells) > c.ncols {c.ncols = min(len(cells), MD_TABLE_MAX_COLS)}
		if md_row_is_sep(line) {
			for cell, i in cells {
				if i >= MD_TABLE_MAX_COLS {break}
				c.align[i] = md_cell_align(cell)
			}
		} else {
			// The separator row is excluded, so its dashes never inflate a column.
			for cell, i in cells {
				if i >= MD_TABLE_MAX_COLS {break}
				// col0 = 0: a table cell is measured from its own start,
				// matching where md_draw_table_row draws it (see that proc).
				w := plat.text_cells(t, transmute([]u8)cell, 0, .Doc)
				if w > c.widths[i] {c.widths[i] = w}
			}
		}
		if lend >= doc.pt.length {break}
		p = lend + 1
	}
	return c
}

// Cached measure for the block containing `p`, or nil if `p` is not a table row.
// The per-frame cost is the containment test over MD_TABLE_SLOTS entries; a scan
// happens only when the viewport enters a block none of the slots cover, or the
// buffer changed.
md_table_ensure :: proc(doc: ^Document, t: ^plat.Text, p: int) -> ^Md_Table_Cache {
	for &c in doc.md_table {
		if c.valid && c.revision == doc.revision && p >= c.start && p < c.end {
			return &c
		}
	}
	start, end, oversize, ok := md_table_bounds(doc, p)
	if !ok {return nil}
	slot := &doc.md_table[doc.md_table_next]
	doc.md_table_next = (doc.md_table_next + 1) % MD_TABLE_SLOTS
	slot^ = md_table_measure(doc, t, start, end, oversize)
	return slot
}

// x offset of column `i`, in pixels from x0.
@(private = "file")
md_col_x :: proc(c: ^Md_Table_Cache, i: int, char_w: f32) -> f32 {
	cells := 0
	for k in 0 ..< min(i, c.ncols) {cells += c.widths[k] + MD_TABLE_PAD}
	return f32(cells) * char_w
}

// One styled run of a line's inline content.
@(private = "file")
Md_Run :: struct {
	text:                    string,
	bold, ital, code, link:  bool,
	strike:                  bool, // ~~text~~ (GFM)
	url:                     string,
}

// Heading pixel scale by level (1..6).
@(private = "file")
md_head_px :: proc(px: f32, level: int) -> f32 {
	switch level {
	case 1:
		return px * 1.7
	case 2:
		return px * 1.45
	case 3:
		return px * 1.25
	case 4:
		return px * 1.12
	case:
		return px * 1.03
	}
}

@(private = "file")
is_space :: proc(b: u8) -> bool {return b == ' ' || b == '\t'}

// Parse a line's inline content into styled runs. Small state machine: ** / __
// bold, * / _ italic, ` code, [text](url) links. Non-nested (a link's label is
// plain), which is enough for a preview.
@(private = "file")
md_inline :: proc(s: string, allocator := context.temp_allocator) -> []Md_Run {
	out := make([dynamic]Md_Run, 0, 8, allocator)
	bold, ital, code, strike := false, false, false, false
	sb := strings.builder_make(allocator)
	flush := proc(out: ^[dynamic]Md_Run, sb: ^strings.Builder, bold, ital, code, strike: bool) {
		if strings.builder_len(sb^) == 0 {return}
		append(out, Md_Run{text = strings.clone(strings.to_string(sb^), context.temp_allocator), bold = bold, ital = ital, code = code, strike = strike})
		strings.builder_reset(sb)
	}
	i, n := 0, len(s)
	for i < n {
		c := s[i]
		if code { // inside inline code: only ` ends it
			if c == '`' {
				flush(&out, &sb, false, false, true, strike)
				code = false
				i += 1
			} else {
				strings.write_byte(&sb, c)
				i += 1
			}
			continue
		}
		switch {
		// A backslash escape takes the NEXT byte literally. Without this, a
		// path like C:\*.txt or a literal asterisk toggled italics and the rest
		// of the line changed style -- CommonMark's escapes are not optional
		// once a document contains any punctuation at all.
		case c == '\\' && i + 1 < n && md_escapable(s[i + 1]):
			strings.write_byte(&sb, s[i + 1])
			i += 2
		case c == '`':
			flush(&out, &sb, bold, ital, false, strike)
			code = true
			i += 1
		case c == '~' && i + 1 < n && s[i + 1] == '~':
			flush(&out, &sb, bold, ital, false, strike)
			strike = !strike
			i += 2
		case c == '*' && i + 1 < n && s[i + 1] == '*', c == '_' && i + 1 < n && s[i + 1] == '_':
			flush(&out, &sb, bold, ital, false, strike)
			bold = !bold
			i += 2
		case c == '*' || c == '_':
			flush(&out, &sb, bold, ital, false, strike)
			ital = !ital
			i += 1
		case c == '[':
			// [label](url)
			rb := strings.index_byte(s[i:], ']')
			if rb > 0 && i + rb + 1 < n && s[i + rb + 1] == '(' {
				us := i + rb + 2
				j := us
				for j < n && s[j] != ')' {j += 1}
				if j < n {
					flush(&out, &sb, bold, ital, false, strike)
					append(&out, Md_Run{text = s[i + 1:i + rb], bold = bold, ital = ital, strike = strike, link = true, url = s[us:j]})
					i = j + 1
					continue
				}
			}
			strings.write_byte(&sb, c)
			i += 1
		case:
			strings.write_byte(&sb, c)
			i += 1
		}
	}
	flush(&out, &sb, bold, ital, code, strike)
	return out[:]
}

// The punctuation CommonMark lets a backslash escape. Restricted to that set on
// purpose: escaping a letter is not an escape, it is a backslash followed by a
// letter, and treating it as one would eat backslashes out of Windows paths.
@(private = "file")
md_escapable :: proc(c: u8) -> bool {
	switch c {
	case '\\', '`', '*', '_', '{', '}', '[', ']', '(', ')', '#', '+', '-', '.', '!', '|', '~', '<', '>', '"', '$', '\'', ',', ':', ';', '=', '?', '@', '^':
		return true
	}
	return false
}

// The lexer for a fence's info string, or nil when the tag names nothing known.
//
// Resolved through highlight_lexer_for by building a pseudo-path, so the fence
// and the file extension share ONE table: adding a lexer for `.rs` makes
// ```rust work for free, and the two can never disagree.
md_fence_lexer :: proc(fence_line: string) -> Lexer_Proc {
	tag := strings.trim_space(strings.trim_left(strings.trim_left(fence_line, "`"), "~"))
	if tag == "" {return nil}
	// Only the first word: ```js title="x" is a real thing people write.
	if sp := strings.index_byte(tag, ' '); sp > 0 {tag = tag[:sp]}
	// A handful of names that are not their own extension. Everything else is
	// tried as one directly, which covers c, cs, cpp, json, xml, yaml, toml, ini,
	// sh, bat, md and any lexer added later.
	switch strings.to_lower(tag, context.temp_allocator) {
	case "javascript", "js", "typescript", "ts":
		tag = "c" // close enough for braces, strings and // comments
	case "shell", "console", "bash", "zsh":
		tag = "sh"
	case "yml":
		tag = "yaml"
	case "csharp", "c#":
		tag = "cs"
	case "c++":
		tag = "cpp"
	}
	lexer, _, _, _ := highlight_lexer_for(strings.concatenate({"x.", tag}, context.temp_allocator))
	return lexer
}

// A task list item: `- [ ] thing` or `- [x] thing`. Returns the text after the
// box, and whether it is ticked. GFM, and the one list variant whose absence is
// noticed immediately because a checklist renders as literal brackets.
md_task :: proc(content: string) -> (rest: string, done, is_task: bool) {
	if len(content) < 3 || content[0] != '[' || content[2] != ']' {return content, false, false}
	switch content[1] {
	case ' ':
		done = false
	case 'x', 'X':
		done = true
	case:
		return content, false, false
	}
	rest = content[3:]
	if len(rest) > 0 && rest[0] == ' ' {rest = rest[1:]}
	return rest, done, true
}

// YAML front matter: a `---` fence on line 1, closed by `---` or `...`. Returns
// the byte offset just past the closing fence, or 0 when the document does not
// open with one. Bounded by a line budget so a file whose first line happens to
// be `---` cannot make this scan to EOF looking for a close that is not there.
md_front_matter_end :: proc(doc: ^Document) -> int {
	if doc == nil || doc.pt.length < 4 {return 0}
	buf: [512]u8
	line, end, _ := md_line_at(doc, 0, buf[:])
	if strings.trim_space(line) != "---" {return 0}
	p := end + 1
	for _ in 0 ..< 64 {
		if p >= doc.pt.length {return 0} // never closed: not front matter
		l2, e2, _ := md_line_at(doc, p, buf[:])
		t := strings.trim_space(l2)
		if t == "---" || t == "..." {return min(e2 + 1, doc.pt.length)}
		p = e2 + 1
	}
	return 0
}

// Draw inline runs word-wrapped from (x,y) within [xind, x1]; new rows indent to
// xind. Advances y per wrapped row. Synthetic bold via a second draw one px over.
@(private = "file")
md_draw_inline :: proc(gfx: ^plat.Gfx, qp: ^plat.Quad_Pipeline, text: ^plat.Text, runs: []Md_Run, xind, x1: f32, x, y: ^f32, px, char_w, line_h: f32, base_col: [4]f32) {
	boff := hairline()
	for run in runs {
		col := base_col
		if run.code {col = g_theme[.Md_Code]}
		if run.ital {col = g_theme[.Md_Italic]}
		if run.link {col = g_theme[.Link]}
		if run.bold && !run.code && !run.link {col = g_theme[.Text_Bright]}
		// Struck text drops to muted as well as getting its line. UI spec 18's
		// "never colour alone" runs both ways: the LINE is the primary cue, so a
		// reader who cannot see the tone still gets it, and the tone stops struck
		// text competing with live text for attention.
		if run.strike {col = g_theme[.Text_Muted]}
		// Split into words, keeping each word's trailing space so wrapping is by word.
		w := run.text
		for len(w) > 0 {
			// take one word (up to and including trailing spaces)
			e := 0
			for e < len(w) && !is_space(w[e]) {e += 1}
			for e < len(w) && is_space(w[e]) {e += 1}
			word := w[:e]
			w = w[e:]
			// col0 = 0: one word, drawn from x^ by the text_draw immediately
			// below and advancing x^ by exactly this width. Measuring it from
			// the row's column instead would make the measurement disagree with
			// the draw, which measures every string it is given from 0.
			ww := f32(plat.text_cells(text, transmute([]u8)word, 0, .Doc)) * char_w
			if x^ + ww > x1 && x^ > xind { // wrap
				x^ = xind
				y^ += line_h
			}
			plat.text_draw(gfx, text, word, x^, y^, px, col, .Doc)
			if run.bold {plat.text_draw(gfx, text, word, x^ + boff, y^, px, col, .Doc)}
			if run.strike {
				// At the x-height centre, per UI spec 9.2 -- through the middle
				// of the lowercase, not through the baseline, or it reads as an
				// underline that has slipped.
				plat.quads_draw(gfx, qp, []plat.Quad{{pos = {x^, y^ - px * 0.28}, size = {ww, hairline()}, color = col}})
			}
			x^ += ww
		}
	}
}

// Does a markdown row whose BASELINE is `y` fit entirely above `ybot`?
//
// The row occupies [y - px, y - px + line_h): the baseline sits px down from
// the row's top, not at it. The loop below used to ask `y < ybot`, which admits
// a row whose baseline is one pixel above the content bottom and then draws a
// whole line height of it -- up to line_h - px pixels of glyphs painted on top
// of the status bar. That is the overlap Wyatt reported in Markdown Preview and
// in Split, and BOTH call sites already pass ybot = winh - doc_bottom_bar_h(doc)
// (main.odin), so the bug was the bound, not the bound's input.
//
// Its own procedure so the test can drive it without a GPU device: reverting it
// to `y < ybot` makes rowbudgettest's markdown walk fail rather than only
// showing up on Wyatt's screen.
md_row_fits :: #force_inline proc(y, px, line_h, ybot: f32) -> bool {
	return y - px + line_h <= ybot
}

// Render markdown source from `top_byte`, laid out in [x0,x1] x [ytop,ybot].
// Returns the byte offset just past the last line drawn (for scroll clamping).
markdown_draw :: proc(gfx: ^plat.Gfx, qp: ^plat.Quad_Pipeline, text: ^plat.Text, doc: ^Document, px, char_w: f32, x0, x1, ytop, ybot: f32, top_byte: int) -> (bottom: int) {
	bottom = top_byte
	line_h := line_height(px)
	buf: [RENDER_LINE_CAP]u8
	y := ytop + px // first baseline
	p := top_byte
	in_fence := false
	// The fence's language tag, resolved to a lexer. UI spec 9.2 item 4 asks for
	// "fenced code + lexer -- syn_* inside", and a fenced block was drawn as flat
	// Md_Code however it was tagged.
	//
	// The tag is turned into a pseudo-path and handed to highlight_lexer_for,
	// rather than growing a second tag->lexer table beside the extension one.
	// One mapping means a lexer added for a file type is immediately available
	// inside a fence, and the two can never disagree about what "cs" means.
	fence_lex: Lexer_Proc
	fence_state: base.Lex_State
	// YAML front matter reads as a small card rather than as body text with two
	// horizontal rules around it, which is what `---` on its own line otherwise
	// renders as (UI spec 9.2 item 12). Only when the view starts at the top of
	// the file: scrolled past it, there is nothing to card.
	fm_end := md_front_matter_end(doc) if top_byte == 0 else 0
	for md_row_fits(y, px, line_h, ybot) && p <= doc.pt.length {
		end := base.pt_line_end_cap(&doc.pt, p, RENDER_LINE_CAP)
		if p < fm_end {
			// Inside the front matter: one muted key/value line, no markdown
			// parsing at all. It is YAML, and running `*` or `_` in a value
			// through the inline parser would style it as emphasis.
			fn := base.pt_read(&doc.pt, p, buf[:min(end - p, len(buf))])
			if fn > 0 && buf[fn - 1] == '' {fn -= 1}
			plat.quads_draw(gfx, qp, []plat.Quad{{pos = {x0 - char_w, y - px}, size = {max(2, sx(2)), line_h}, color = g_theme[.Md_Rule]}})
			plat.text_draw(gfx, text, string(buf[:fn]), x0 + char_w, y, px, g_theme[.Text_Muted], .Doc)
			y += line_h
			bottom = end
			p = end + 1
			continue
		}
		n := base.pt_read(&doc.pt, p, buf[:min(end - p, len(buf))])
		if n > 0 && buf[n - 1] == '\r' {n -= 1}
		line := string(buf[:n])
		trimmed := strings.trim_left(line, " \t")

		if strings.has_prefix(trimmed, "```") || strings.has_prefix(trimmed, "~~~") {
			in_fence = !in_fence
			if in_fence {
				fence_lex, fence_state = md_fence_lexer(trimmed), .Normal
			} else {
				fence_lex = nil
			}
			y += line_h
		} else if in_fence {
			plat.quads_draw(gfx, qp, []plat.Quad{{pos = {x0, y - px}, size = {x1 - x0, line_h}, color = g_theme[.Md_Code_Bg]}})
			if fence_lex != nil {
				toks: [128]base.Token
				nt, st := fence_lex(transmute([]u8)line, fence_state, toks[:])
				fence_state = st
				spans: [128]plat.Text_Span
				ns := 0
				for i in 0 ..< nt {
					if ns >= len(spans) {break}
					spans[ns] = {start = toks[i].start, len = toks[i].len, color = g_theme[highlight_kind_role(toks[i].kind)]}
					ns += 1
				}
				plat.text_draw_spans(gfx, text, line, x0 + char_w, y, px, g_theme[.Md_Code], spans[:ns], .Doc)
			} else {
				plat.text_draw(gfx, text, line, x0 + char_w, y, px, g_theme[.Md_Code], .Doc)
			}
			y += line_h
		} else if len(strings.trim_space(line)) == 0 {
			y += line_h * 0.5 // blank line: a little gap
		} else if md_is_rule(trimmed) {
			plat.quads_draw(gfx, qp, []plat.Quad{{pos = {x0, y - px * 0.5}, size = {x1 - x0, hairline()}, color = g_theme[.Md_Rule]}})
			y += line_h
		} else if lvl := md_heading_level(trimmed); lvl > 0 {
			hpx := md_head_px(px, lvl)
			hh := line_height(hpx)
			by := y + (hpx - px) // sink the larger baseline so it sits on the row
			x := x0
			yy := by
			runs := md_inline(strings.trim_left(trimmed[lvl:], " "))
			// force bold heading colour
			for &r in runs {r.bold = true}
			md_draw_inline(gfx, qp, text, runs, x0, x1, &x, &yy, hpx, plat.text_char_width(text, hpx, .Doc), hh, g_theme[.Md_Heading])
			y = yy + hh - px * 0.3
		} else if q, qcontent, qdepth := md_quote_depth(trimmed); q {
			// One bar per nesting level, indented per level (UI spec 9.2's "2px
			// bar + 16px inset per level"), so a reply inside a reply is visibly
			// deeper instead of identical to a single quote.
			for d in 0 ..< qdepth {
				plat.quads_draw(gfx, qp, []plat.Quad{{pos = {x0 + f32(d) * char_w * 2, y - px}, size = {max(sx(3), 2), line_h}, color = g_theme[.Md_Quote]}})
			}
			qind := x0 + f32(qdepth) * char_w * 2
			x := qind
			yy := y
			md_draw_inline(gfx, qp, text, md_inline(qcontent), qind, x1, &x, &yy, px, char_w, line_h, g_theme[.Md_Quote])
			y = yy + line_h
		} else if bullet, content, depth := md_list(line); bullet != "" {
			ind := x0 + f32(depth) * char_w * 2
			body := content
			// A task item draws a real box instead of literal brackets, which is
			// how `- [ ] thing` reads without this. Done items go muted, so a
			// finished checklist recedes -- and the TICK carries the state as
			// well as the tone, never colour alone (UI spec 18).
			task_col := g_theme[.Text_Primary]
			if rest, done, is_task := md_task(content); is_task {
				body = rest
				bx := ind
				bs := char_w * 1.4
				by := y - px * 0.75
				edge := hairline()
				bc := g_theme[.Accent] if done else g_theme[.Text_Muted]
				plat.quads_draw(
					gfx,
					qp,
					[]plat.Quad {
						{pos = {bx, by}, size = {bs, edge}, color = bc},
						{pos = {bx, by + bs - edge}, size = {bs, edge}, color = bc},
						{pos = {bx, by}, size = {edge, bs}, color = bc},
						{pos = {bx + bs - edge, by}, size = {edge, bs}, color = bc},
					},
				)
				if done {
					plat.text_draw(gfx, text, "x", bx + bs * 0.28, y, px, g_theme[.Accent], .Doc)
					task_col = g_theme[.Text_Muted]
				}
				x := ind + bs + char_w
				yy := y
				md_draw_inline(gfx, qp, text, md_inline(body), ind + bs + char_w, x1, &x, &yy, px, char_w, line_h, task_col)
				y = yy + line_h
				p = end + 1
				continue
			}
			plat.text_draw(gfx, text, bullet, ind, y, px, g_theme[.Accent], .Doc)
			x := ind + char_w * f32(len(bullet) + 1)
			yy := y
			md_draw_inline(gfx, qp, text, md_inline(body), ind + char_w * 2, x1, &x, &yy, px, char_w, line_h, g_theme[.Text_Primary])
			y = yy + line_h
		} else if md_is_table_row(line) {
			if c := md_table_ensure(doc, text, p); c != nil {
				md_draw_table_row(gfx, qp, text, c, line, x0, x1, y, px, char_w, md_row_is_sep(line))
			}
			y += line_h
		} else {
			x := x0
			yy := y
			md_draw_inline(gfx, qp, text, md_inline(line), x0, x1, &x, &yy, px, char_w, line_h, g_theme[.Text_Primary])
			y = yy + line_h
		}

		bottom = end
		if end >= doc.pt.length {break}
		p = end + 1
	}
	return
}

@(private = "file")
md_heading_level :: proc(s: string) -> int {
	n := 0
	for n < len(s) && s[n] == '#' {n += 1}
	if n >= 1 && n <= 6 && n < len(s) && s[n] == ' ' {return n}
	return 0
}

@(private = "file")
md_is_rule :: proc(s: string) -> bool {
	t := strings.trim_space(s)
	if len(t) < 3 {return false}
	c := t[0]
	if c != '-' && c != '*' && c != '_' {return false}
	for i in 0 ..< len(t) {
		if t[i] != c && t[i] != ' ' {return false}
	}
	return true
}

@(private = "file")
md_quote :: proc(s: string) -> (bool, string) {
	q, c, _ := md_quote_depth(s)
	return q, c
}

// A blockquote, with its NESTING DEPTH. `>> a` is a quote inside a quote and
// used to render exactly like `> a` -- md_quote stripped one marker and returned
// the rest verbatim, so the second ">" became part of the text. UI spec 9.2
// lists "blockquote, nested" as one item for that reason.
md_quote_depth :: proc(s: string) -> (is_quote: bool, content: string, depth: int) {
	rest := s
	for {
		t := strings.trim_left(rest, " ")
		if !strings.has_prefix(t, ">") {break}
		rest = t[1:]
		depth += 1
	}
	if depth == 0 {return false, "", 0}
	return true, strings.trim_left(rest, " "), depth
}

// A list item: returns the bullet to draw ("•" or "1."), the content, and the
// nesting depth from the leading indent.
@(private = "file")
md_list :: proc(line: string) -> (bullet, content: string, depth: int) {
	i := 0
	for i < len(line) && (line[i] == ' ' || line[i] == '\t') {
		depth += 2 if line[i] == '\t' else 1
		i += 1
	}
	depth /= 2
	rest := line[i:]
	if len(rest) >= 2 && (rest[0] == '-' || rest[0] == '*' || rest[0] == '+') && rest[1] == ' ' {
		return "•", strings.trim_left(rest[2:], " "), depth
	}
	// ordered: digits then '.' or ')'
	j := 0
	for j < len(rest) && rest[j] >= '0' && rest[j] <= '9' {j += 1}
	if j > 0 && j + 1 < len(rest) && (rest[j] == '.' || rest[j] == ')') && rest[j + 1] == ' ' {
		return strings.clone(rest[:j + 1], context.temp_allocator), strings.trim_left(rest[j + 2:], " "), depth
	}
	return "", "", 0
}

@(private = "file")
md_is_table_sep :: proc(s: string) -> bool {
	for i in 0 ..< len(s) {
		switch s[i] {
		case '|', '-', ':', ' ', '\t':
		case:
			return false
		}
	}
	return strings.contains(s, "-")
}

// Single source for "is this row a separator": the measure and the draw used to
// each trim their own copy of the line before checking, which agreed only
// incidentally. Both now call this on the same untrimmed line.
@(private = "file")
md_row_is_sep :: proc(line: string) -> bool {
	return md_is_table_sep(strings.trim_left(line, " \t"))
}

// One row of a table, drawn at the block's cached column positions so every row
// lines up. `qp` is needed for the header rule under the separator row, which
// the old renderer skipped entirely.
@(private = "file")
md_draw_table_row :: proc(
	gfx: ^plat.Gfx,
	qp: ^plat.Quad_Pipeline,
	text: ^plat.Text,
	c: ^Md_Table_Cache,
	line: string,
	x0, x1, y, px, char_w: f32,
	is_sep: bool,
) {
	if is_sep {
		// The separator row becomes a rule, not text. md_col_x(c.ncols) sums a
		// width+pad for every column including the last, so it includes one pad's
		// worth of gap that has nothing after it — trim it or the rule overhangs
		// the last column by MD_TABLE_PAD cells.
		w := min(max(0, md_col_x(c, c.ncols, char_w) - f32(MD_TABLE_PAD) * char_w), x1 - x0)
		plat.quads_draw(gfx, qp, []plat.Quad{{pos = {x0, y - px * 0.5}, size = {w, hairline()}, color = g_theme[.Md_Rule]}})
		return
	}
	cells := md_split_cells(line, context.temp_allocator)
	for cell, i in cells {
		if i >= c.ncols {break}
		cx := x0 + md_col_x(c, i, char_w)
		if cx >= x1 {break}
		if i > 0 {
			// The TABLE column separator -- Md_Rule, which UI spec 1 assigns to
			// "thematic breaks, table borders, h1/h2 underline". It was Text_Dim,
			// the disabled-only tier, until the Text_Dim sweep.
			plat.text_draw(gfx, text, "│", cx - char_w, y, px, g_theme[.Md_Rule], .Doc)
		}
		// col0 = 0, and it must match md_table_measure's origin for the same
		// cell or the alignment padding below is computed against a width the
		// column was never sized for.
		cw := plat.text_cells(text, transmute([]u8)cell, 0, .Doc)
		pad := 0
		switch c.align[i] {
		case .Left:
		case .Center:
			pad = max(0, (c.widths[i] - cw) / 2)
		case .Right:
			pad = max(0, c.widths[i] - cw)
		}
		plat.text_draw(gfx, text, cell, cx + f32(pad) * char_w, y, px, g_theme[.Text_Primary], .Doc)
	}
}
