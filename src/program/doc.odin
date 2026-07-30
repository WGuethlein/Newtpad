// Layer: program — an editable document: a piece-table buffer over the file's
// (immutable) original bytes, a caret, undo/redo via piece snapshots, and a
// background line index over the original for the scrollbar. The viewport reads
// through the piece table on demand, so it stays instant regardless of size.
// Every screen pass shares one capped line iterator (visible_begin/next) and the
// layout helpers below, so geometry stays consistent and bounded.
package main

import "base:intrinsics"
import "core:fmt"
import "core:slice"
import "core:strings"
import "core:thread"
import "core:unicode/utf8"
import base "src:base"
import plat "src:platform"

// Max bytes scanned per visible line for its end (bounds per-frame work).
RENDER_LINE_CAP :: 8192
// Max columns any screen pass computes geometry for; caret/selection/text are
// all clipped to this so a long line can't produce off-screen quads or place the
// caret past the rendered glyphs. Real horizontal scroll is a later feature.
VISIBLE_COLS :: 2048

// --- shared screen layout (one home for the margins/spacing every pass used to
// hardcode as 12 / 10 / 1.5) ---

// Chrome text comes in exactly two sizes. Every distinct px is an independent
// set of rasterized glyphs in the atlas, and glyph area grows with the square of
// the DPI scale — six chrome sizes (15/17/14/13/12 plus the body's 16) meant six
// copies of ASCII, which at 300% is most of a 1024^2 atlas before a single CJK
// character. Two is also simply less to keep consistent.
BASE_PX_96 :: f32(16) // default document text size at 96 DPI
BASE_PX := BASE_PX_96 // current, from settings (see settings.odin)
UI_PX_96 :: f32(15) // chrome: menu/caption glyphs, palette rows, find bar
UI_SMALL_PX_96 :: f32(13) // secondary: tab labels, status bar, category labels
TEXT_MARGIN_X_96 :: f32(24) // side padding (UI spec 2.3; was 12)
TEXT_MARGIN_Y_96 :: f32(16) // top padding -- "never 0, the first line needs air" (UI spec 2.3; was 10)
TAB_STRIP_H_96 :: f32(40) // the tab rail (UI spec 2.1; was 36)

LINE_SPACING :: f32(1.5) // line height = font px * this (a ratio; DPI-independent)

// --- the same values at the current DPI ---
//
// These are variables, not constants, because every one of them is a pixel
// measurement and the window's DPI is only known at runtime — and can change
// while running, when the window is dragged to another monitor. They are written
// in exactly one place (metrics_recompute, main.odin) before any frame is drawn,
// and read everywhere else. Newtpad is a single-window app, so there is exactly
// one DPI in play at a time and no need to thread a context object through every
// draw call.
// One width for the scrollbar. It used to be three disagreeing numbers — the
// hit-test gutter, the drawn track, and the width reserved when wrapping — which
// merely looked sloppy at 96 DPI but would have rendered wrapped text underneath
// the bar once they scaled independently.
SCROLLBAR_W_96 :: f32(14) // the reserved LANE: track width + inset from the edge
// The drawn bar inside that lane. UI spec 2.3 asks for 8 wide, 6 inset from the
// right edge; 8 + 6 is the 14 above, so the bar is drawn at
// `right - SCROLLBAR_W` with this width and the inset falls out.
//
// Two names because SCROLLBAR_W had two jobs: every "right edge of the content"
// computation subtracts it (doc_view_cols, the markdown panes, four table
// widths), AND the track quad used it as its width. Those were the same number
// only because the bar used to fill its lane. Same shape as the Border_Subtle
// role split recorded in theme.odin -- one value serving a boundary and a fill.
SCROLLBAR_TRACK_W_96 :: f32(8)

// The status line along the bottom (UI spec 2.1; was an inline sx(20)).
//
// The find bar's own heights are deliberately NOT changed here even though UI
// spec 12 gives them (38, and 76 in replace mode): 12 MOVES that bar to the top
// of the editor, which is batch 15, and retuning a bar's height in the batch
// before the one that relocates it is churn. doc_bottom_bar_h still owns both
// numbers.
STATUS_BAR_H_96 :: f32(26)

// Corner radii -- the whole list from UI spec 2.4, nothing above 8. Consumed by
// the rounded-rect pipeline; no caller passes a radius until the tab rail and
// menus are rebuilt in batch 13, so these are declared here (beside every other
// metric) rather than invented per widget then.
RADIUS_MENU_BAR_ITEM_96 :: f32(4)
RADIUS_ROW_96 :: f32(5) // menu rows, palette rows, close button, tooltips
RADIUS_TAB_96 :: f32(6) // tabs, find bar, commands control
RADIUS_PANEL_96 :: f32(7) // menu and palette panels
RADIUS_CARD_96 :: f32(8) // settings cards, the window itself

UI_PX := UI_PX_96
UI_SMALL_PX := UI_SMALL_PX_96
TEXT_MARGIN_X := TEXT_MARGIN_X_96
TEXT_MARGIN_Y := TEXT_MARGIN_Y_96
TAB_STRIP_H := TAB_STRIP_H_96
SCROLLBAR_W := SCROLLBAR_W_96
SCROLLBAR_TRACK_W := SCROLLBAR_TRACK_W_96
STATUS_BAR_H := STATUS_BAR_H_96
RADIUS_MENU_BAR_ITEM := RADIUS_MENU_BAR_ITEM_96
RADIUS_ROW := RADIUS_ROW_96
RADIUS_TAB := RADIUS_TAB_96
RADIUS_PANEL := RADIUS_PANEL_96
RADIUS_CARD := RADIUS_CARD_96

// Bottom edge of the chrome: below the tab strip AND the menu bar. Anything
// positioned against the top of the content area (the scrollbar, its drag
// mapping) must use this, not TAB_STRIP_H — using the strip alone let the
// scrollbar gutter extend up into the menu row and swallow clicks meant for it.
CHROME_TOP := TAB_STRIP_H_96 + MENU_BAR_H_96

// Content-area top edge. Derived, so it is recomputed with the rest; the
// initialiser here must stay in step with metrics_recompute, since the headless
// test modes never call that.
CONTENT_TOP := TAB_STRIP_H_96 + MENU_BAR_H_96 + TEXT_MARGIN_Y_96

// window DPI / 96, written by metrics_recompute. Lets the small one-off offsets
// inside a widget scale without every draw proc taking a context parameter.
UI_SCALE: f32 = 1

// Extra top inset, below the menu, for the FILTER banner (Ctrl+L). It names the
// active filter and how to leave it. Only nonzero while filtering; set once per
// frame by doc_update_top_inset and added by the row math below, so the drawn
// rows, the hit-test and the row count all shift together. Without the shift the
// banner (taller than the 10px menu/content gap) was drawn half under the menu
// bar, cut off and unreadable.
FILTER_BANNER_H: f32 = 0

// Everything between the chrome and the first document row: the filter banner
// plus the find bar. ONE value, because it is the row grid's origin and every
// pass that positions against a row -- the draw, the caret, the selection, the
// find highlights, the hit-test and the frame loop's row count -- has to agree
// on it exactly. Two separate addends is how a hit-test ends up one bar out of
// step with the draw.
TOP_INSET: f32 = 0
FILTER_BANNER_H_96 :: f32(22)

// The banner shows exactly when the filter view is engaged (see render_frame).
doc_update_top_inset :: proc(doc: ^Document) {
	FILTER_BANNER_H = sx(FILTER_BANNER_H_96) if (doc != nil && doc.filter && doc.find.active) else 0
	TOP_INSET = FILTER_BANNER_H + doc_top_bar_h(doc)
}

// Scale a 96-DPI offset. Sign-preserving, and never rounds a non-zero value away
// to nothing (a 1px gap must stay visible).
sx :: #force_inline proc(v: f32) -> f32 {
	if v == 0 {return 0}
	r := f32(int(v * UI_SCALE + (0.5 if v > 0 else -0.5)))
	return r if r != 0 else (1 if v > 0 else -1)
}

// A one-device-pixel line at the current scale.
//
// FLOOR, never round -- and that is the whole point of it existing separately
// from sx(1). At 125% `sx(1)` rounds 1.25 up to 2, and at 150% to 2, so a
// hairline that should stay a hairline thickens; worse, at scales where the
// rounded width and the (unrounded) position disagree, the line lands straddling
// two device pixels and the rasteriser splits it into two half-alpha lines. That
// is the "the menu separator looks blurry at 125%" class of defect, and it is
// the one thing about hairlines the UI spec calls a hard rule (§3 item 4).
//
// Minimum 1: a hairline that scales away is a missing boundary, not a subtle
// one. Same reasoning as sx()'s own never-round-to-nothing clamp.
//
// Callers should also SNAP THE POSITION to a whole pixel. This returns a width;
// it cannot fix an x that arrives fractional.
hairline :: #force_inline proc() -> f32 {return max(1, f32(int(UI_SCALE)))}

// Snap a coordinate to a whole pixel.
//
// For anything TEXT is positioned from. Glyphs come out of an alpha atlas, and
// drawing one at a half-pixel x samples between texels: every stem picks up a
// ghost on one side and the run reads as smeared or doubled. It is not subtle
// and it is not obviously a coordinate problem when you see it.
//
// The palette shipped exactly this. Its origin is `(width - w) / 2`, so at the
// panel's maximum width an ODD window width put x0 on a half pixel and an even
// one did not -- which is why it looked intermittent and why dragging the window
// edge one pixel toggled it. Wyatt, live use: "if i move the left edge of the
// window 1 pixel it goes to look normal, when i expand 1 more pixel it goes
// wonky again."
//
// Rounds rather than floors: a panel one pixel narrower on odd widths is
// invisible, whereas floor would bias every centred thing left by half a pixel
// at every size.
snap :: #force_inline proc(v: f32) -> f32 {return f32(int(v + 0.5))}

// A chrome font size rounded to an even whole pixel.
//
// Even, not merely whole: line_height multiplies by LINE_SPACING and truncates,
// and vertical centring inside a row divides by two. An odd px therefore puts
// the centred baseline of a menu row or a tab label on a half pixel, which is
// the difference between crisp chrome text and slightly soft chrome text at
// 125% and 175% (UI spec §3 item 6). The document's own px is deliberately NOT
// forced even -- it is the user's chosen size and line_height already rounds it
// for the row grid.
ui_px_even :: #force_inline proc(v: f32) -> f32 {
	n := int(v + 0.5)
	if n % 2 != 0 {n -= 1}
	return f32(max(n, 2))
}

// Rounded to a whole pixel for the same reason cell width is (see
// plat.text_char_width): row r's top is r*line_height, and every pass that
// positions against rows — draw, caret, selection, find rects, hit-testing, and
// the `rows` count in the frame loop — must agree exactly. At an odd px (105%
// scale gives px=17) an unrounded px*1.5 is fractional, drifting half a pixel
// per row: a full row off by row 40.
line_height :: #force_inline proc(px: f32) -> f32 {return f32(int(px * LINE_SPACING + 0.5))}
// Text baseline y for visible row r (what text_draw wants).
row_baseline_y :: #force_inline proc(px: f32, r: int) -> f32 {return px + CONTENT_TOP + TOP_INSET + f32(r) * line_height(px)}
// Top y of a line-height-tall highlight box for row r.
row_rect_y :: #force_inline proc(px: f32, r: int) -> f32 {return CONTENT_TOP + TOP_INSET + f32(r) * line_height(px)}
// Left x of column `col` (monospace).
// Width of the line-number gutter, 0 when there isn't one. Set once per frame
// (doc_update_gutter) and added by BOTH col_x and col_at_x, so the drawn column
// and the hit-tested column cannot disagree about where text begins.
GUTTER_W: f32 = 0

// Horizontal scroll offset, in cells (non-wrap only). col_x subtracts it and
// col_at_x/cell_at_x add it, so the caret, selection, find highlights, links,
// the drawn text and every hit-test shift together through the one column-
// geometry primitive — the same single-source discipline the gutter uses. Zero
// while wrapping or filtering (no horizontal scroll there). Mirrored from
// doc.h_scroll once per frame by doc_update_hscroll.
H_SCROLL: int = 0

// Mirror the active doc's horizontal scroll into H_SCROLL for this frame, off
// unless the document is in the plain view -- non-wrap, non-filter, and not one
// of the two rendered views. Set alongside the gutter/top-inset so the whole
// frame agrees.
//
// Zero in the views that REPLACE the text pass (doc_read_only_view: the grid and
// full Markdown Preview), not just in the wrapped/filtered ones. Neither of those
// two reads H_SCROLL -- table_draw pans doc.table_col instead and Preview lays out
// to the pane -- but doc.h_scroll survives a view toggle, so a document panned in
// text view and then switched to the grid left H_SCROLL non-zero with nothing
// honouring it. The visible consequence was render_frame's left-margin cover strip
// (drawn whenever H_SCROLL > 0, to hide glyphs panned off the left edge) painting
// Bg_Base over the first TEXT_MARGIN_X of a view that had not panned anything.
// That was latent while the grid's first column started at TEXT_MARGIN_X and went
// live the moment §10's zebra bands and header reached x = 0.
doc_update_hscroll :: proc(doc: ^Document) {
	H_SCROLL = doc.h_scroll if (doc != nil && !doc_wraps(doc) && !doc.filter && !doc_read_only_view(doc)) else 0
}

// Recompute the gutter for the active document. Only the filter view has one:
// its whole purpose is showing lines out of context, which is meaningless
// without saying which lines they are.
doc_update_gutter :: proc(doc: ^Document, char_w: f32) {
	GUTTER_W = 0
	if doc == nil || !doc_filtering(doc) || len(doc.filter_line_nos) == 0 {return}
	biggest := doc.filter_line_nos[len(doc.filter_line_nos) - 1]
	digits := 1
	for v := biggest; v >= 10; v /= 10 {digits += 1}
	GUTTER_W = f32(digits + 2) * char_w
}

// Usable content width in cells -- what word wrap breaks at. One definition,
// like col_x/col_at_x above: the main loop subtracted GUTTER_W and the resize
// repaint in render_frame did not, so the two frames wrapped to different
// widths. Latent only because the gutter is filter-view-only today; it goes
// live the moment the gutter generalizes to normal editing.
// Call after doc_update_gutter -- it reads GUTTER_W.
doc_view_cols :: #force_inline proc(width, char_w: f32) -> int {
	return max(1, int((width - TEXT_MARGIN_X - GUTTER_W - SCROLLBAR_W) / char_w))
}

// Right edge of the editor's content area. The full window normally; the split
// point in Markdown Split, where the preview owns the right half. Everything that
// bounds the editor (wrap width, its scrollbar, its click region) uses this.
// split_frac comes from Settings (a global preference, not per-file) -- the
// caller passes its own copy rather than this reading an App/Settings pointer,
// since every call site already has one in scope.
doc_editor_right :: proc(doc: ^Document, winw, split_frac: f32) -> f32 {
	if doc != nil && doc.kind == .Text && doc.md_mode == .Split {return f32(int(winw * split_frac))}
	return winw
}

// The draggable divider between the editor and the preview. Produced here and
// consumed by the draw, the hover cursor and the drag hit-test -- one layout per
// widget, so what is drawn is exactly what is grabbable. Zero-size when the
// document is not in Split, so callers need no second condition. Centred on
// doc_editor_right's x -- never computed independently, or the grab band could
// drift from the pane it is supposed to divide. Stops above the find/status bar
// (doc_bottom_bar_h) -- that strip owns its own presses (main.odin), and before
// this the divider's full-window-height hit band would steal one out from under
// it whenever the divider's x column happened to cross the bar.
MD_DIVIDER_W :: 6 // logical px; the visible line is thinner than the grab band
md_divider_rect :: proc(doc: ^Document, winw, winh, split_frac: f32) -> plat.Quad {
	if doc == nil || doc.kind != .Text || doc.md_mode != .Split {return {}}
	er := doc_editor_right(doc, winw, split_frac)
	w := sx(MD_DIVIDER_W)
	bot := winh - doc_bottom_bar_h(doc)
	return {pos = {er - w * 0.5, CHROME_TOP}, size = {w, max(0, bot - CHROME_TOP)}}
}

// The editor scrollbar's clickable x-range at the current doc_editor_right.
// In Markdown Split it stops MD_DIVIDER_W/2 short of ed_right, ceding
// md_divider_rect's grab band (which straddles ed_right) instead of competing
// with it for the same pixels -- the full window edge otherwise. One proc so
// main.odin's hit-test and splittest's assertion on it agree on the same
// boundary rather than the test re-deriving a second copy.
editor_scrollbar_hit_x :: proc(doc: ^Document, ed_right: f32) -> (lo, hi: f32) {
	hi = ed_right - sx(MD_DIVIDER_W) * 0.5 if doc.md_mode == .Split else ed_right
	return ed_right - SCROLLBAR_W, hi
}

// The drag fraction for a divider-drag mouse x at window width winw -- the
// same expression main.odin's WM_MOUSEMOVE handler evaluates while
// divider_drag is live, factored out so splittest calls the real computation
// instead of a second copy of it. A test that re-evaluates its own copy of an
// expression and asserts on the copy tests the language's clamp, not this
// code (see the report on this finding). max(1, winw) matches main.odin's own
// guard against a zero-width window.
split_frac_at :: proc(mx, winw: f32) -> f32 {
	return clamp(mx / max(1, winw), SPLIT_MIN, SPLIT_MAX)
}

// A new/untitled buffer (no path yet) is allowed into any view -- you don't know
// what it will become. A saved file only gets the view its extension fits.
@(private = "file")
path_has_ext :: proc(path: string, exts: []string) -> bool {
	if path == "" {return true} // untitled: don't limit
	lp := strings.to_lower(path, context.temp_allocator)
	for e in exts {
		if strings.has_suffix(lp, e) {return true}
	}
	return false
}

// Table view fits delimited data; markdown views fit markdown. Toggling a mode
// OFF is always allowed (see the command guards) so a file can never get stuck
// in a view -- these only gate turning a mode ON.
doc_is_tabular :: proc(doc: ^Document) -> bool {
	return doc != nil && path_has_ext(doc.path, {".csv", ".tsv", ".tab", ".psv"})
}
// The extensions Ctrl+M preview will enter. EXT_LEXERS (highlight.odin) must
// register base.lex_markdown for every one of these, or a file with one of
// the six less-common extensions enters Preview with no lexer at all --
// md_fence_seed's doc_lex_state_at then always reports .Normal, silently
// undoing the fence-state seeding fix these two lists exist together to
// support. highlight_markdown_exts_ok (highlight.odin) is the guard that
// keeps the two lists from drifting apart again; lexcoveragetest asserts it.
MARKDOWN_EXTS := []string{".md", ".markdown", ".mkd", ".mdown", ".mdwn", ".mdtext", ".mdx", ".mtext"}
doc_is_markdownish :: proc(doc: ^Document) -> bool {
	return doc != nil && path_has_ext(doc.path, MARKDOWN_EXTS)
}

// May the active document enter (or leave) each view? Already being in the view
// keeps it toggleable so you can always get back out.
doc_can_table :: proc(doc: ^Document) -> bool {
	return doc != nil && doc.kind == .Text && (doc.table || doc_is_tabular(doc))
}
doc_can_markdown :: proc(doc: ^Document) -> bool {
	return doc != nil && doc.kind == .Text && (doc.md_mode != .Off || doc_is_markdownish(doc))
}

// Column geometry. `hs` is the row's effective horizontal offset in cells; the
// HS_GLOBAL sentinel means "use the frame-wide H_SCROLL". A force-wrapped row
// passes 0 (it fits the window, so the pan does not apply to it) while the
// non-wrapped rows around it still pan — the coexistence the mixed layout needs.
HS_GLOBAL :: min(int)
@(private = "file")
eff_hs :: #force_inline proc(hs: int) -> int {return H_SCROLL if hs == HS_GLOBAL else hs}
col_x :: #force_inline proc(char_w: f32, col: int, hs := HS_GLOBAL) -> f32 {return TEXT_MARGIN_X + GUTTER_W + f32(col - eff_hs(hs)) * char_w}
// Inverse mappings for hit-testing a client-space pixel.
row_at_y :: #force_inline proc(px, my: f32) -> int {return int((my - CONTENT_TOP - TOP_INSET) / line_height(px))}
col_at_x :: #force_inline proc(char_w, mx: f32, hs := HS_GLOBAL) -> int {return eff_hs(hs) + max(0, int((mx - TEXT_MARGIN_X - GUTTER_W) / char_w + 0.5))}
// Which cell a point is INSIDE, as opposed to col_at_x, which rounds to the
// nearest caret boundary because that is what click-to-place-caret wants.
// Hit-testing a drawn span needs this one: with col_at_x the boundary sits half
// a cell to the left, so a link's first cell was clickable from outside it and
// its last cell was not clickable at all. Same function, wrong space — the
// §6j bug class, caught here by asserting the drawn span against the clickable
// span at both edges.
cell_at_x :: #force_inline proc(char_w, mx: f32, hs := HS_GLOBAL) -> int {return eff_hs(hs) + max(0, int((mx - TEXT_MARGIN_X - GUTTER_W) / char_w))}

// --- word wrap: break a logical line into visual rows at doc.view_cols cells ---

// A line longer than this force-wraps even with global word wrap off, so a
// minified JSON or a long log/CSV row is readable without horizontal scrolling
// (which only reaches VISIBLE_COLS anyway). Wyatt, 2026-07-20.
//
// NOTE for anyone editing line_wrap_decision below: it must answer the SAME
// question eff_wrap_at answers, because visible_next asks eff_wrap_at for the
// first visible row and line_wrap_decision for every logical line after it. It
// used to open with `if doc.wrap` rather than `if doc_wraps(doc)`, so Markdown
// Split's forced wrap was invisible to it -- see the comment on doc_wraps.
WRAP_LONG_CELLS :: 1024

// How far back a force-wrap line-start scan will go, and how far forward the
// wrap decision scans. A line longer than this stays a capped, horizontally-
// scrollable row rather than wrapping. It equals RENDER_LINE_CAP deliberately:
// every viewport/navigation step decides wrap by scanning at most this far, so
// the hot path costs no more than the capped no-wrap stepping the huge-file fix
// established — the perf guarantee holds — and a line past the cap is already
// drawn as capped segments, so leaving it unwrapped is consistent, not a loss.
// (Lines from 1024 up to this wrap; longer single lines still use h-scroll.)
WRAP_START_CAP :: RENDER_LINE_CAP

// Should the logical line starting at `ls` force-wrap? True when it exceeds
// WRAP_LONG_CELLS cells AND its newline (or EOF) is within WRAP_START_CAP bytes.
// One bounded scan: stops at the newline (short line, cheap), at the threshold +
// a found newline (wrap), or at the cap (too long to locate for wrapping → stays
// a capped, horizontally-scrollable row, so a multi-GB single line never wraps
// and never triggers an unbounded walk). Called once per visible logical line.
@(private = "file")
line_wrap_decision :: proc(doc: ^Document, t: ^plat.Text, ls: int) -> bool {
	// doc_wraps, not doc.wrap: Markdown Split force-wraps the editor half
	// whether or not Alt+Z is on, and this proc is one of the two answers
	// visible_next uses to lay out a row. Reading the raw field here gave the
	// draw and the hit-test a DIFFERENT row grid from the one doc_scroll /
	// eff_row_start / doc_ensure_cursor_visible walk (those go through
	// eff_wrap_at, which does ask doc_wraps) whenever Split was on with wrap
	// off. Everything after the first visible row rendered unwrapped, so a
	// click low in the pane resolved to an offset the scroll machinery
	// believed was below the viewport -- it scrolled to "reveal" a line that
	// was already on screen, and the still-held button then dragged a
	// selection across the whole page from the freshly moved view. Reported by
	// Wyatt in live use, 2026-07-28. The bug is CLAUDE.md's shape B exactly:
	// one widget, two layouts.
	if doc_wraps(doc) {return true}
	buf: [4096]u8
	L := doc.pt.length
	limit := min(L, ls + WRAP_START_CAP)
	p, cells := ls, 0
	long := false
	for p < limit {
		n := base.pt_read(&doc.pt, p, buf[:min(len(buf), limit - p)])
		if n == 0 {break}
		i := 0
		for i < n {
			if buf[i] == '\n' {return long} // newline within the cap: wrap iff long
			r, sz := utf8.decode_rune(buf[i:n])
			if sz == 0 {sz = 1}
			if i + sz > n && p + n < limit {break} // rune straddles the chunk; refill
			// `cells` is this line's running cell column, counted from the
			// LOGICAL line start `ls`. wrap_row_end below counts from the
			// VISUAL row start, and the two origins are deliberately different
			// rather than one of them being an oversight: this proc answers
			// "is this whole logical line long enough to need wrapping at
			// all", a question about the line, so the line is its origin;
			// wrap_row_end answers "where does THIS visual row break", a
			// question about a row that is drawn from its own x, so the row is
			// its origin. They can only disagree about a tab on a continuation
			// row, and only about the wrap threshold, never about a drawn
			// column -- see wrap_row_end's own note.
			cells += plat.text_cell_width_at(t, r, cells, .Doc)
			if cells > WRAP_LONG_CELLS {long = true}
			i += sz
		}
		if i == 0 {break}
		p += i
	}
	return long if p >= L else false // EOF ends the line: wrap iff long; else too long
}

// Effective wrapping for the line containing `off`: global wrap, or the line
// force-wraps. Returns the (capped) line start too, for callers that then walk
// visual rows. The one predicate the mixed layout rests on; bounded, which is
// what preserves the "never freeze on a huge file" rule.
// Whether the editor wraps at all: the user's word-wrap, or Markdown Split, where
// the editor lives in the left half and must fold rather than run under the
// preview.
doc_wraps :: proc(doc: ^Document) -> bool {
	return doc != nil && (doc.wrap || (doc.kind == .Text && doc.md_mode == .Split))
}

// The views that RENDER the document instead of editing it: the CSV/TSV grid
// and the full-window Markdown Preview. Both replace the text pass entirely
// (table_draw, markdown_draw), so neither draws a caret, and both must refuse
// every buffer write -- a caret left over from text view would otherwise edit
// at an offset the user cannot see.
//
// Markdown Split is deliberately NOT here: its left half is the real editor and
// is meant to be typed in. The preview half takes no caret either, but that is
// a MOUSE question (which pane a press landed in) and belongs to
// ro_surface_swallows; the keyboard always belongs to the editor half.
//
// One predicate rather than the condition open-coded per site, because that is
// how Preview came to be editable at all: `doc.table` was spelled out at each
// guard, so adding a second read-only view meant finding every one of them, and
// nobody did. Consumed by the typed-character loop (main.odin) and the
// mutating-command guard plus the Replace All arm (commands.odin).
doc_read_only_view :: proc(doc: ^Document) -> bool {
	return doc != nil && doc.kind == .Text && (doc.table || doc.md_mode == .Preview)
}

eff_wrap_at :: proc(doc: ^Document, t: ^plat.Text, off: int) -> (wrap: bool, ls: int) {
	s, exact := base.pt_line_start_cap(&doc.pt, off, WRAP_START_CAP)
	if doc_wraps(doc) {return true, s}
	if !exact {return false, s} // line start beyond the cap: too long to wrap
	return line_wrap_decision(doc, t, s), s
}

// End of the visual row starting at `p` (which must be a visual-row start).
// Returns the break offset and whether it's the logical line end. Breaks after
// the last word boundary that fits; a single word wider than the row char-breaks.
// When wrap is off, callers use pt_line_end_cap instead.
wrap_row_end :: proc(doc: ^Document, t: ^plat.Text, p, cols: int) -> (end: int, line_end: bool) {
	c := max(cols, 1)
	L := doc.pt.length
	buf: [512]u8
	pos := p
	col := 0
	last_break := -1 // offset just after the most recent space/tab that fit
	for pos < L {
		n := base.pt_read(&doc.pt, pos, buf[:min(len(buf), L - pos)])
		if n == 0 {break}
		i := 0
		for i < n {
			if buf[i] == '\n' {return pos + i, true}
			// A CRLF's CR costs zero wrap-budget cells by construction
			// (plat.is_zero_width), so it falls straight through the ordinary path
			// below like any other zero-width character -- no special-casing needed
			// to keep it out of the column count.
			r, sz := utf8.decode_rune(buf[i:n])
			if sz == 0 {sz = 1}
			if i + sz > n && pos + n < L {break} // rune straddles the chunk; refill
			// `col` is the column within this VISUAL row, which is the origin
			// tab stops are measured from here. With wrap off -- the normal
			// case, the only case for .tsv, and the only case column editing
			// permits -- a visual row is its logical line, so it is exactly
			// right. With wrap on, a tab on a continuation row aligns to that
			// row rather than to the logical line; that is a deliberate,
			// bounded deviation (leading indentation lives on the first visual
			// row, where the origin is right), and what matters more is that
			// the draw and the hit-test share this convention, which they do
			// because both measure from the row start. Guarded by wraptest's
			// continuation-row case, which is the ONLY check in the tree that
			// can see this choice -- every other tab fixture sits on a first
			// visual row, where the two origins are the same number.
			cw := plat.text_cell_width_at(t, r, col, .Doc)
			if col + cw > c && col > 0 {
				if last_break > p {return last_break, false}
				return pos + i, false // char-break an over-long word
			}
			col += cw
			if buf[i] == ' ' || buf[i] == '\t' {last_break = pos + i + sz}
			i += sz
		}
		if i == 0 {break}
		pos += i
	}
	return L, true
}

// Start of the visual row after the one starting at `p`. `ok` is false when `p`'s
// row was the last one: an end at EOF has no successor, while a real newline
// leaves a row after it — possibly the empty final one. Same distinction
// next_row_start_capped draws, and for the same reason.
next_visual_row :: proc(doc: ^Document, t: ^plat.Text, p, cols: int) -> (start: int, ok: bool) {
	e, le := wrap_row_end(doc, t, p, cols)
	if le {
		if e >= doc.pt.length {return doc.pt.length, false}
		return e + 1, true
	}
	return e, e > p // a mid-line wrap point: the next visual row starts there
}

// Start of the visual row containing byte `off`.
visual_row_start :: proc(doc: ^Document, t: ^plat.Text, off, cols: int) -> int {
	s := base.pt_line_start(&doc.pt, off)
	for {
		e, le := wrap_row_end(doc, t, s, cols)
		if le || off < e {return s}
		s = e
	}
}

// Start of the visual row before the one starting at `p`.
prev_visual_row :: proc(doc: ^Document, t: ^plat.Text, p, cols: int) -> int {
	if p <= 0 {return 0}
	ls := base.pt_line_start(&doc.pt, p)
	if ls < p { // p is mid logical line: the segment just before it
		s := ls
		for {
			ns, _ := next_visual_row(doc, t, s, cols)
			if ns >= p {return s}
			s = ns
		}
	}
	// p is a logical line start: last segment of the previous logical line
	s := base.pt_prev_line_start(&doc.pt, p)
	for {
		e, le := wrap_row_end(doc, t, s, cols)
		if le {return s}
		s = e
	}
}

// --- mixed layout: per-line wrap (global wrap, or a long line force-wrapping)
// laid over the capped no-wrap rows. These are what the viewport and the caret
// navigation step through, so a short line stays one (horizontally-scrollable)
// row while a long line beside it wraps. All bounded (eff_wrap_at is; wrap_row_end
// is bounded by a row; a force-wrappable line is <= WRAP_START_CAP), so the
// huge-file guarantee holds. ---

// Next visual row start, wrap-aware. `ok` is false when `p`'s row was the last —
// see next_row_start_capped for why that is distinct from "starts at length".
eff_next_row :: proc(doc: ^Document, t: ^plat.Text, p, cols: int) -> (start: int, ok: bool) {
	if wrap, _ := eff_wrap_at(doc, t, p); wrap {
		return next_visual_row(doc, t, p, cols)
	}
	return next_row_start_capped(doc, p)
}

// Start of the visual row containing byte `off`.
eff_row_start :: proc(doc: ^Document, t: ^plat.Text, off, cols: int) -> int {
	wrap, ls := eff_wrap_at(doc, t, off)
	if !wrap {return row_start_capped(doc, off)}
	s := ls
	for {
		e, le := wrap_row_end(doc, t, s, cols)
		if le || off < e {return s}
		s = e
	}
}

// Start of the visual row before the one starting at `p`.
eff_prev_row :: proc(doc: ^Document, t: ^plat.Text, p, cols: int) -> int {
	if p <= 0 {return 0}
	if !(p == 0 || byte_at(doc, p - 1) == '\n') { // p is mid a line
		// Only a wrapping line has mid-line row boundaries to walk forward to; a
		// huge no-wrap line's mid-line segments step by the capped boundary (and
		// must, or this walks a quarter-megabyte per row — the perf/correctness bug).
		if wrap, ls := eff_wrap_at(doc, t, p); wrap {
			s := ls
			for {
				ns, _ := next_visual_row(doc, t, s, cols)
				if ns >= p {return s}
				s = ns
			}
		}
		return prev_row_start_capped(doc, p)
	}
	// p is a logical line start: the last visual row of the previous line.
	wrapPrev, pls := eff_wrap_at(doc, t, p - 1)
	if !wrapPrev {return prev_row_start_capped(doc, p)}
	s := pls
	for {
		e, le := wrap_row_end(doc, t, s, cols)
		if le {return s}
		s = e
	}
}

// End (exclusive) of the visual row starting at `p`, minus a CRLF's CR: this
// feeds line_offset_at_cell through up/down navigation, so it must land where
// the caret is actually allowed to sit, not one phantom cell past it.
eff_row_end :: proc(doc: ^Document, t: ^plat.Text, p, cols: int) -> int {
	if wrap, _ := eff_wrap_at(doc, t, p); wrap {
		e, le := wrap_row_end(doc, t, p, cols)
		return base.pt_row_vis_end(&doc.pt, p, e, le)
	}
	e := base.pt_line_end_cap(&doc.pt, p, RENDER_LINE_CAP)
	return base.pt_row_vis_end(&doc.pt, p, e, true)
}

// Walks the visible rows (filter view, wrapped, or consecutive) yielding each
// row's [start, end) byte range, its vis_end (end minus a CRLF's CR, when
// line_end is true — the one definition every consumer reads instead of each
// stripping the CR itself), and whether it ends a logical line. Wrap-aware, so
// every screen pass (draw, selection, find highlights) sharing it stays
// consistent; `end` is capped to RENDER_LINE_CAP when not wrapping so no pass
// scans a pathological long line.
Visible_Iter :: struct {
	doc:      ^Document,
	t:        ^plat.Text,
	rows:     int,
	r:        int,
	pos:      int,
	done:     bool,
	// Mixed layout: whether the current logical line is wrapping, and whether the
	// next row begins a fresh logical line (so the wrap decision is re-made only at
	// real line boundaries, not per capped segment of a huge line).
	cur_wrap: bool,
	fresh:    bool,
}

visible_begin :: proc(doc: ^Document, t: ^plat.Text, rows: int) -> Visible_Iter {
	return {doc = doc, t = t, rows = rows, pos = doc.top}
}

// Filter view only actually filters once there are matching lines. With the
// filter armed but nothing matched yet — an empty query, or a worker that hasn't
// published — the document renders normally instead of showing a blank screen.
// That is what lets Ctrl+L arm the filter first and narrow as the user types.
// UI spec 12 sizes: a 38px find bar, and replace adds a second 38px row.
FIND_BAR_H_96 :: f32(38)

// Height of the find bar, which sits at the TOP of the editor.
//
// It used to live in the bottom strip, sharing doc_bottom_bar_h with the status
// line -- so one procedure answered two questions and every caller had to know
// which one it was getting. UI spec 12 moves it: "the count is the number you
// stare at while typing; in the screenshots it is the lowest-contrast text in
// the window, at the bottom, 700 pixels from where you are looking."
//
// Returning a TOP inset rather than a bottom one is most of the work, because
// the row math already has a top-inset mechanism (FILTER_BANNER_H) and had no
// second one. Rows, the caret, the hit-test and the scrollbar track all measure
// from CONTENT_TOP plus the insets, so adding to that sum is enough.
doc_top_bar_h :: proc(doc: ^Document) -> f32 {
	if doc == nil || !doc.find.active {return 0}
	return sx(FIND_BAR_H_96) * (2 if doc.find.replace_mode else 1)
}

// Height of the bar along the bottom. The status line, and only the status line
// now -- the find bar moved to doc_top_bar_h. Document rows must stop above it,
// or text is drawn behind the bar and clicks in that strip land on rows the user
// cannot see.
// The status bar's right-hand cells, as rects. ONE geometry, consumed by the
// draw and by the click -- UI spec 13: "Every cell is clickable. Encoding opens
// the encoding menu, LF toggles line endings."
//
// Right-hand only. The left group is position and file facts that nothing can
// usefully do anything with (clicking "Ln 124" has no meaning), whereas every
// cell on the right names a SETTING with an obvious action.
Status_Cell :: struct {
	label: string,
	x, w:  f32,
	cmd:   Command_Id,
}

// Fills `out` and returns the used prefix. `cw` is the status font's advance.
status_cells :: proc(doc: ^Document, winw, cw: f32, out: []Status_Cell) -> []Status_Cell {
	if doc == nil || doc.kind != .Text || len(out) < 2 {return out[:0]}
	n := 0
	// Right to left, because they are right-aligned: each cell's x depends on
	// the width of everything after it.
	x := winw - sx(12)
	add :: proc(out: []Status_Cell, n: ^int, x: ^f32, cw: f32, label: string, cmd: Command_Id) {
		w := f32(len(label)) * cw
		x^ -= w
		out[n^] = {label = label, x = x^, w = w, cmd = cmd}
		n^ += 1
		x^ -= sx(24) // the gap a divider sits in the middle of
	}
	// Line endings, then encoding: the order they read left-to-right is the
	// reverse of the order they are placed.
	add(out, &n, &x, cw, base.line_ending_name(doc.eol), .Eol_CRLF if doc.eol == .LF else .Eol_LF)
	add(out, &n, &x, cw, enc_name(doc.enc), .Enc_UTF8 if doc.enc != .UTF8 else .Enc_UTF16LE)
	return out[:n]
}

// The cell a click landed on, or .None.
status_cell_at :: proc(doc: ^Document, winw, winh, cw, mx, my: f32) -> Command_Id {
	if my < winh - doc_bottom_bar_h(doc) {return .None}
	buf: [4]Status_Cell
	for c in status_cells(doc, winw, cw, buf[:]) {
		if mx >= c.x && mx < c.x + c.w {return c.cmd}
	}
	return .None
}

doc_bottom_bar_h :: proc(doc: ^Document) -> f32 {
	return STATUS_BAR_H
}

// Visible document rows, excluding both bars and the filter banner inset.
//
// FULLY visible: a row that only partly fits is not counted. That is the right
// question for every consumer reasoning about REACHABILITY -- the scroll clamp
// (doc_scroll, doc_max_top), the page keys, doc_filter_max_top -- and it must
// stay that question. doc_ensure_cursor_visible takes this too, but only to
// decide where to land the caret after an actual scroll; see its own comment
// for why the on-screen check itself has to ask doc_drawn_rows instead. See
// doc_drawn_rows for the other question.
doc_visible_rows :: proc(doc: ^Document, height, line_h: f32) -> int {
	top, bot := doc_content_box(doc, height)
	return max(0, int((bot - top) / line_h))
}

// The content box the document draws into: everything between the chrome (plus
// the find bar / filter banner inset) and the bottom status strip. One
// definition, so the draw's clip, the row budget and the tests cannot each
// grow their own.
doc_content_box :: proc(doc: ^Document, height: f32) -> (top, bot: f32) {
	return CONTENT_TOP + TOP_INSET, height - doc_bottom_bar_h(doc)
}

// The row count the VERTICAL SCROLL MODEL runs on: the grid's own budget when
// this is a grid, the editor's otherwise.
//
// One producer because three things have to hold the same number or the view
// scrolls to different places depending on how you asked. vscrollbar_geo maps
// doc.top through doc_max_top(rows) and vbar_drag_to maps the pointer back
// through doc_scroll_to_fraction(rows) -- vscrollbar_geo's comment records that
// those two being exact inverses is what makes "grab the thumb and it does not
// move" true rather than approximately true -- and the wheel calls doc_scroll
// with a third copy. While the grid shared the editor's line grid all three were
// the same by accident. §10's 26px rows under a 30px header end that, and the
// failure is not subtle: the wheel would reach a doc.top past the bar's own
// maximum, so the thumb would sit pinned at the bottom of the track while the
// file kept scrolling, and the next press on it would jump the view backwards.
doc_scroll_rows :: proc(doc: ^Document, height, line_h, px: f32) -> int {
	if doc != nil && doc.kind == .Text && doc.table {return table_visible_rows(doc, height, px)}
	return doc_visible_rows(doc, height, line_h)
}

// Rows the DRAW emits: the fully visible ones, plus a partial row when the
// remainder can show any useful part of it. The bottom strip is repainted over
// the content afterwards (render_frame), so a partial row cannot leave glyphs
// on top of the status bar.
//
// Deliberately separate from doc_visible_rows rather than replacing it.
// doc_visible_rows answers "how many rows are WHOLLY on screen", which is the
// right question for the scroll clamp and the page keys -- paging by a count
// that includes a sliver would scroll a hair further each press. The draw and
// the HIT-TEST ask this one instead: a half-visible line is clickable, because
// it is on screen. Two questions, two procedures; conflating them is the
// CLAUDE.md / HANDOFF §6j shape that has cost sixteen bugs in one session.
//
// doc_ensure_cursor_visible takes BOTH, and this comment used to cite "it would
// call a half-hidden caret visible" as a hazard. That is now exactly what it
// deliberately does, and on purpose: it asks `drawn` whether the caret counts as
// on screen, because doc_pos_at hit-tests against `drawn` too -- judging a
// clicked row "below the viewport" scrolled the file out from under the click.
// It still asks `rows` for WHERE to land after an actual scroll. Do not
// "correct" that call site back to `rows` on both sides; see its own comment.
//
// PARTIAL_ROW_MIN is the policy: below it the sliver is not worth a row, and
// drawing one would put its whole line height under the status strip for no
// visible gain. It also keeps an exactly-flush viewport from gaining a phantom
// row on floating-point noise.
PARTIAL_ROW_MIN :: f32(0.5)
doc_drawn_rows :: proc(doc: ^Document, height, line_h: f32) -> int {
	full := doc_visible_rows(doc, height, line_h)
	top, bot := doc_content_box(doc, height)
	if bot - top - f32(full) * line_h > PARTIAL_ROW_MIN {return full + 1}
	return full
}

// Highest filter_top that still fills the screen. One definition: the wheel, the
// page keys and the match auto-scroll each had their own, so Page-Down could
// scroll to a single line above a screen of empty rows while the wheel refused
// to move at all.
doc_filter_max_top :: proc(doc: ^Document, rows: int) -> int {
	return max(0, len(doc.filter_lines) - max(1, rows))
}

doc_filtering :: proc(doc: ^Document) -> bool {
	return doc.filter && len(doc.filter_lines) > 0
}

// The line the filter view drew at client-space y, as a byte offset, if any.
//
// Walks the same visible_begin/visible_next walk the filter draw walks, so the
// row a press lands on is by construction the row the user sees: filter_top, the
// row height and the end of the list each keep their single definition and this
// asks them rather than repeating any of them (CLAUDE.md, "one layout per
// widget"). In the filter view `start` is filter_lines[i] -- already the byte
// offset of a line start -- which is exactly what the jump wants, so no row
// index is derived here and none can drift by one against the draw's.
//
// ok is false for a y above the first row, at or past the last row on screen, or
// on a drawn row past the end of filter_lines. Deliberately unlike doc_pos_at,
// which CLAMPS a y off either end onto the nearest row: right for placing a
// caret, wrong here, where it would turn a press on the empty area below the
// last match into a jump to the last match.
doc_filter_line_at :: proc(doc: ^Document, t: ^plat.Text, my, px: f32, rows: int) -> (start: int, ok: bool) {
	if doc == nil || !doc_filtering(doc) {return 0, false}
	// row_rect_y(px, 0) is the top of the first row -- the same producer
	// row_at_y subtracts -- so a press on the filter banner, which sits in the
	// inset above it, is refused rather than truncating to row 0.
	if my < row_rect_y(px, 0) {return 0, false}
	target := row_at_y(px, my)
	if target >= rows {return 0, false}
	it := visible_begin(doc, t, rows)
	for {
		row, s, _, _, _, _, more := visible_next(&it)
		if !more {break}
		if row == target {return s, true}
	}
	return 0, false
}

visible_next :: proc(it: ^Visible_Iter) -> (row, start, end, vis_end: int, line_end, wrapped, ok: bool) {
	if it.done || it.r >= it.rows {return}
	d := it.doc
	if doc_filtering(d) {
		fi := d.filter_top + it.r
		if fi >= len(d.filter_lines) {return}
		start = d.filter_lines[fi]
		end = base.pt_line_end_cap(&d.pt, start, RENDER_LINE_CAP)
		line_end = true // filter view is never force-wrapped
	} else {
		if it.pos > d.pt.length {return}
		start = it.pos
		// Decide wrap for this row's logical line. The first visible row (doc.top may
		// be mid-line) is located and classified; after that the decision is re-made
		// only when a fresh logical line begins, so a huge line's many capped rows
		// don't each re-scan.
		if it.r == 0 {
			it.cur_wrap, _ = eff_wrap_at(d, it.t, start)
		} else if it.fresh {
			it.cur_wrap = line_wrap_decision(d, it.t, start)
		}
		wrapped = it.cur_wrap
		if it.cur_wrap {
			end, line_end = wrap_row_end(d, it.t, start, d.view_cols)
			if line_end {
				it.fresh = true
				if end >= d.pt.length {it.done = true} else {it.pos = end + 1}
			} else {
				it.fresh = false // next visual row continues the same logical line
				it.pos = end
			}
		} else {
			end = base.pt_line_end_cap(&d.pt, start, RENDER_LINE_CAP)
			line_end = true
			// A fresh logical line follows only if this capped row ended at a real
			// newline; a synthetic cap boundary keeps us in the same (non-wrapping,
			// too-long) line, so we don't re-classify and don't start wrapping it.
			it.fresh = end >= d.pt.length || (end < d.pt.length && byte_at(d, end) == '\n')
			nxt, more := next_row_start_capped(d, start)
			if !more {it.done = true} else {it.pos = nxt}
		}
	}
	// One definition of the row's content end for every consumer: the draw, the
	// caret, the hit-test, the selection, the link scan and the h-scroll width.
	vis_end = base.pt_row_vis_end(&d.pt, start, end, line_end)
	row = it.r
	it.r += 1
	ok = true
	return
}

// Background job that counts total lines over the immutable original bytes (no
// race with edits, which only touch the add arena). The status bar shows this
// plus nl_delta (net newlines from edits). Published via atomics.
Line_Index :: struct {
	content:    []u8,
	line_count: int, // atomic
	indexed:    int, // atomic (bytes scanned, for progress)
	total:      int,
	done:       bool, // atomic
	cancel:     bool, // atomic
	fault:      bool, // atomic: a read faulted (mapped file changed underneath)
	guard:      bool, // scan through the SEH guard (content is mapped, not private)
	th:         ^thread.Thread,
}

// What produced an edit. Used to decide whether the next one continues it (so a
// typing run is one undo step, not one per character) and to label the entry in
// the history list.
Edit_Kind :: enum u8 {
	None,
	Type, // consecutive character inserts
	Delete,
	Paste,
	Replace, // find & replace
	Newline,
}

UNDO_MAX :: 200 // entries kept; oldest dropped. Each holds a cloned piece tree.

Snapshot :: struct {
	root:      ^base.Node, // cloned piece tree
	length:    int,
	cursor:    int,
	anchor:    int,
	nl_delta:  int,
	// The bookmark set belonging to this state, cloned. Owned by the snapshot
	// exactly like `root` is, and freed wherever `root` is freed.
	//
	// A snapshot rather than a replay: undo restores a whole tree (pt_restore),
	// so there is no edit to run the shift rules backwards against, and the
	// shift rules are lossy in one direction anyway -- a delete DROPS the
	// bookmarks it spanned, and nothing in the forward direction remembers what
	// they were. Carrying the set is what makes undo restore them.
	bookmarks: []int,
	kind:      Edit_Kind, // the edit that PRODUCED this state (.None = as opened)
	count:     int, // characters/edits involved, for the label
}

// A tab is usually a text document, but Settings and Font are tabs too. Making
// them tabs rather than a full-window takeover means they can be switched away
// from, closed, and shown in the tab strip like anything else — instead of
// trapping the window until you click the same button again.
//
// Closed by Escape, the tab strip's X or File > Close Tab. NOT by Ctrl+W, as
// this comment used to say: that chord is bound in the .Editor context and a
// pseudo-tab puts main.odin in .Settings or .Font, which falls back to .Editor
// for Find, Menu and History only (resolve_key, commands.odin).
Tab_Kind :: enum u8 {
	Text,
	Settings,
	Font,
}

Document :: struct {
	kind:       Tab_Kind,
	fv:         plat.File_View,
	original:   []u8,
	owned_orig: bool,
	enc:        base.Encoding,
	pt:         base.Piece_Table,
	path:       string, // "" for an unnamed scratch buffer
	path_owned: bool, // doc.path is heap-owned (freed on close/re-save)
	had_bom:    bool, // whether the file opened with a BOM (preserved on save)
	eol:        base.Line_Ending, // as opened; what a save writes back
	top:        int, // byte offset of the top visible (visual) row
	cursor:     int, // caret byte offset
	anchor:     int, // other end of the selection (== cursor when none)
	// --- rectangular (column) selection ---
	// Four integers, not a byte range: a rectangle is a (row, cell column)
	// region and cannot be expressed as cursor/anchor offsets.
	//
	// The vertical coordinate is the BYTE OFFSET of the row's own first byte,
	// not a line NUMBER. Newtpad has no line index, so a line number is not a
	// cheap coordinate here: turning one back into an offset means walking from
	// byte 0, which costs O(depth in the file) and has to be paid again by
	// every consumer. Storing the offset the caret already had (pt_line_start_cap
	// hands it over on the way to computing the cell column) makes every
	// consumer's cost proportional to the RECTANGLE, never to how far into the
	// file it sits. Rows are LOGICAL line starts, never visual rows -- column
	// select requires word wrap off (see the design doc's wrap fork), and
	// turning wrap on clears the block rather than silently changing what the
	// rectangle means.
	//
	// Cells, not bytes and not codepoints, on the horizontal axis: the renderer
	// is a monospace cell grid (plat.text_cell_width classifies a rune as 0, 1
	// or 2 cells), so a tab or a CJK character makes a row's byte range differ
	// from its cell range. Every conversion goes through block_row_range and
	// nowhere else.
	block:                   bool,
	block_anchor_line_start: int,
	block_anchor_cell:       int,
	block_cursor_line_start: int,
	block_cursor_cell:       int,
	wrap:       bool, // word-wrap this document at view_cols
	// Read-only table view of a CSV/TSV (see table.odin), toggled per document.
	table:       bool,
	table_delim: u8, // ',' or '\t'; chosen when the view is turned on
	table_col:    int, // horizontal scroll: first visible table column
	table_cols:   int, // column count seen this frame (set by table_draw)
	table_widths: [dynamic]int, // per-column cell widths, computed once from a
	// sample when the view opens — so columns don't shift as different rows scroll
	// into view.
	// In-cell editing (table view). While editing, keystrokes go to table_edit_buf,
	// not the document; on commit the source field range [s,e) is replaced.
	table_editing:     bool,
	table_edit_s:      int, // source byte range of the field being edited
	table_edit_e:      int,
	table_edit_row:    int, // visual row / column of the cell, for rendering
	table_edit_col:    int,
	table_edit_buf:    [dynamic]u8,
	table_edit_caret:  int, // byte offset within table_edit_buf
	// Markdown view (see markdown.odin): Off / Preview (full) / Split (editor +
	// live preview).
	md_mode:     Md_Mode,
	// The preview pane's own scroll position, in PIXELS (UI spec 9.1 item 4).
	//
	// doc.top stays the EDITOR's and is untouched by this: the editor pane keeps
	// the row grid, the byte anchor and its own scrollbar. The preview does not,
	// because it has no grid to anchor to -- a blank run is one zero-height block,
	// so a preview screen covers about three times the source an editor screen
	// does, and sharing one byte offset made the last stretch of the preview's
	// scroll travel show nothing new (2b's measurement: bottom=194 against the
	// editor's ceiling).
	//
	// Kept in step with doc.top by md_sync_top, which records the doc.top the
	// preview last mirrored: they differ => the editor moved => the preview
	// re-anchors by BLOCK (9.4). Not persisted -- see session.odin's format
	// comment: a session records doc.top, and the preview is derived from it on
	// restore, so there is no format change and no saved position to lose.
	md_top:      Md_Anchor,
	md_sync_top: int,
	// md_max_anchor's answer and the key it was computed under. See Md_Max_Key:
	// a scroll moves no term of the key, which is the case that has to be free.
	md_max:      Md_Anchor,
	md_max_key:  Md_Max_Key,
	// md_scroll_frac's DENOMINATOR -- md_scroll_scalar at md_max -- under the same
	// key. Cached with the anchor rather than recomputed from it because deriving
	// the scalar costs a walk of its own, and the fraction is asked for once per
	// frame by the scrollbar. See md_scroll_frac.
	md_max_scalar: f32,
	// One block's slot height and extent: md_slot_at's answer, warmed by whichever
	// pass last walked that block. See Md_Slot_Key and md_pass -- the point is that
	// the walk the DRAW makes is the one the scrollbar's fraction then reads,
	// instead of the fraction making a second walk over the same blocks inside
	// render_frame.
	md_slot_key:  Md_Slot_Key,
	md_slot_next: int,
	md_slot_h:    f32,
	// Per-block column measure (markdown.odin). Four slots, not one, so two table
	// blocks on screen at once don't thrash a single slot every frame; no
	// allocation, so nothing to free on doc close.
	md_table:      [MD_TABLE_SLOTS]Md_Table_Cache,
	md_table_next: int, // round-robin replacement cursor
	// Per-block laid-out glyph positions (UI spec 9.1's layout cache). Keyed on
	// the block's start byte and its own source text -- see MD_LAYOUT_SLOTS.
	//
	// A SLICE, allocated lazily on the first preview pass, not a fixed array
	// like md_table above it. Md_Layout is ~300 bytes and there are 256 slots
	// (MD_LAYOUT_SLOTS) -- doubled since batch 17's pixel anchor, see that
	// constant's comment -- so inline it would put ~75 KB into every Document.
	// The argument holds a fortiori now that the slot count is bigger; only
	// the numbers below moved. And a Document is created BY VALUE in several
	// places (doc_from_content returns one; test_mode_dispatch holds them as
	// locals in an already-enormous frame).
	// Measured: making it inline turned every headless mode into an immediate
	// STATUS_STACK_OVERFLOW (0xC00000FD), including modes that never open a
	// document, which is the third time this frame has done that. Freed
	// explicitly by md_layout_reset, which doc_close calls.
	md_layout: []Md_Layout,
	view_cols:  int, // usable content width in cells (set per frame when wrapping)
	view_rows:  int, // visible row count (set per frame; filter scrolling clamps to it)
	h_scroll:   int, // horizontal scroll offset in cells (non-wrap only; 0 otherwise)
	// High-water mark for doc_update_max_hscroll: the widest line MEASURED
	// since max_cells_rev (below) was last set, not the widest currently on
	// screen. See that proc's comment for the scan that raises it.
	//
	// The two whole-buffer-replacement paths both bump doc.revision, so the
	// revision check below covers them for free: doc_reload_forced (an actual
	// reload/reopen-as swap in different file content) replaces the WHOLE
	// Document struct (`doc^ = fresh`), so a reloaded document's mark is zero
	// regardless; doc_set_line_ending rewrites the whole buffer in place but
	// only touches line-TERMINATOR bytes -- line_cell_col never measures past a
	// line's content into its terminator -- so no line's measured width
	// actually changes even though revision moves.
	//
	// ORDINARY EDITING (fixed 2026-07-29): this used to survive every edit,
	// keyed on nothing. Delete the file's longest line through doc_replace_sel
	// (or any other edit path) and the mark stayed at the deleted line's width
	// for the rest of the session -- measured, a 400-cell line plus 50 short
	// ones gave doc_max_hscroll = 323, and it was still 323 after the long
	// line was gone, offering pan into content that no longer existed. Now
	// keyed on max_cells_rev: an edit bumps doc.revision (push_undo does, and
	// every edit path routes through it), and doc_update_max_hscroll drops the
	// mark back to 0 the next time it runs, letting it re-grow from whatever
	// is on screen. A mere SCROLL does not bump doc.revision, so the mark
	// still survives that -- the property Wyatt chose the high-water design
	// for in the first place (2026-07-28): a background full-document rescan
	// on every edit would defeat the point of not doing one on every scroll.
	max_cells_seen: int,
	// doc.revision the mark above was last measured against. See the field
	// comment; read and written only by doc_update_max_hscroll.
	max_cells_rev: u64,
	status_cursor: int, // cursor pos the cached status line was computed for
	status_line:   int, // 1-based line of the cursor (0 = beyond the cap / unknown)
	// Same for the column, which was neither cached nor capped and cost an
	// uncapped backward scan per frame. Keyed on length too, so an edit that
	// leaves the caret where it is still invalidates.
	status_col_cursor: int,
	status_col_len:    int,
	status_col:        int, // 1-based column (0 = beyond the cap / unknown)
	status_col_valid:  bool,
	modified:   bool,
	// Monotonic mutation counter, for caches that must not outlive an edit (the
	// markdown table column measure). Bumped in push_undo, which every edit path
	// routes through.
	revision:   u64,
	recovered:  bool, // a mapped read faulted; buffer is now a private copy, not the file
	// External-change detection (watch.odin). `gen` distinguishes this document
	// from a later one reusing the same tab slot, so a stat result that arrives
	// after a close is discarded instead of applied to a stranger.
	gen:          u64,
	disk_stamp:   plat.File_Stamp, // the file as we last saw it
	disk_changed: bool, // changed underneath us and we have not reconciled
	disk_gone:    bool, // it stopped existing
	appended:     int, // bytes absorbed from the file's tail since it was opened
	nl_delta:   int,
	// Bookmarked lines, as the BYTE OFFSET of each line's first byte, kept
	// sorted ascending and never holding a duplicate.
	//
	// Byte offsets, not line numbers, for the same reason the column rectangle
	// above stores them: Newtpad has no line index, so turning a line number
	// back into an offset means walking from byte 0 -- §6y measured 48 ms per
	// frame at line 28,000 of a 500 KiB log. Every consumer here (the gutter
	// mark, the cycle, the session writer) wants an offset, so a line number
	// would be converted at every one of them.
	//
	// The invariant, maintained by bookmarks_shift_insert/_delete and worth
	// stating because everything else leans on it: every entry is a real line
	// start (offset 0, or preceded by '\n'). See those two procs for how each
	// edit case preserves it.
	bookmarks:  [dynamic]int,
	undo:       [dynamic]Snapshot,
	redo:       [dynamic]Snapshot,
	// Coalescing state: what the last edit was and where it left the caret. A
	// run of typing continues only while both still match.
	last_edit:    Edit_Kind,
	last_edit_at: int,
	// Column-edit run identity. A held key over a rectangle issues one batch per
	// press; without this each press was its own undo entry, so a 300-row prefix
	// held for two seconds was dozens of Ctrl+Z -- and UNDO_MAX (200) then evicted
	// the pre-run state entirely, making the original unreachable. `block_run` is
	// bumped whenever a gesture creates or reshapes a rectangle; `last_block_run`
	// is the run the current undo entry belongs to, and 0 means "not a run".
	block_run:      int,
	last_block_run: int,
	// What produced the CURRENT state, and how much of it. Each Snapshot carries
	// the same for the state it holds, so the description travels with a state as
	// it moves between the undo and redo stacks — otherwise a state that came
	// back via undo would lose its label.
	state_kind:  Edit_Kind,
	state_count: int,
	// Inside a batch every edit still applies, but only the first takes a
	// snapshot, so a multi-edit operation is one undo entry. See doc_batch_begin.
	batch:       bool,
	idx:        Line_Index,
	lex_idx:    Lex_State_Index, // background per-line syntax-lexer state (see lex_index.odin)
	find:       Find,
	search:     Search, // background find worker (see find.odin)
	// filter-to-matching-lines view (only while find is active)
	filter:       bool,
	filter_lines: [dynamic]int, // deduped matching-line starts
	// 1-based line number for each entry above, counted by the search worker
	// during its pass. Without it a filtered view shows matching lines with no
	// indication of where in the file they came from.
	filter_line_nos: [dynamic]int,
	filter_top:   int, // index into filter_lines
}

// Incremental find/replace state (see find.odin).
Find :: struct {
	active:       bool,
	replace_mode: bool, // Ctrl+H shows the replace field
	field:        int, // 0 = query field, 1 = replace field (Tab toggles)
	regex:        bool, // regex vs literal substring
	// Search has always been case-FOLDED with no way to ask for exact case, and
	// has never had a whole-word mode at all. UI spec 12 wants all three shown as
	// labelled toggles, which only means anything once all three exist.
	case_sens:    bool, // match case exactly
	whole_word:   bool, // the match must not be flanked by word characters
	query:        [dynamic]u8, // UTF-8
	replace:      [dynamic]u8,
	// Slices into the Search arrays, re-sliced once per frame to whatever the
	// worker has published. Not owned here — see Search.
	matches:      []int, // sorted match start offsets
	match_len:    []int, // length of each match (regex matches vary)
	merged:       int, // entries already folded into filter_lines
	current:      int, // index into matches, or -1
	jumped:       bool, // already auto-selected a match for this query
	dirty:        bool, // an edit invalidated the results; restart next frame
	truncated:    bool, // hit MAX_MATCHES; results are partial
	// The most recently published result, kept so the status text does not read
	// "(no matches)" during the frames between an edit clearing the matches and
	// the worker republishing. A rapid replace otherwise flickers to zero.
	last_total:   int,
	last_current: int, // -1 when nothing has been published for this query
}

// A new empty scratch document (no file). This is what opens when Newtpad is
// launched with no argument — never fail to a closed window.
doc_new :: proc() -> (doc: Document) {
	doc.enc = .UTF8
	doc.pt = base.pt_init(nil)
	return
}

// `force_enc` overrides what detect_encoding decided -- the Reopen As commands.
// The sniff still runs, because a BOM is also how many bytes to skip.
doc_open :: proc(path: string, force_enc: Maybe(base.Encoding) = nil) -> (doc: Document, ok: bool) {
	fv, fok := plat.file_open_readonly(path)
	if !fok {
		return
	}
	doc.fv = fv
	doc.path = strings.clone(path)
	doc.path_owned = true

	// Both the sniff and any transcode read the mapping directly, on the main
	// thread, outside the SEH guard -- read_rec routes through safe_copy, these
	// did not. A mapped file that is rotated, truncated, or (NTFS-compressed)
	// fails to decompress mid-open raises EXCEPTION_IN_PAGE_ERROR, which is not a
	// catchable Odin error: it took the whole process down and every other tab's
	// unsaved work with it. So read through the guard before touching the bytes.
	enc: base.Encoding
	bom: int
	if fv.mapped {
		head: [base.SNIFF]u8
		n := min(len(fv.bytes), len(head))
		if n > 0 && !base.safe_copy(head[:n], fv.bytes[:n]) {
			doc.recovered = true // faulted pages came back zeroed; say so
		}
		enc, bom = base.detect_encoding(head[:n])
	} else {
		enc, bom = base.detect_encoding(fv.bytes)
	}
	if fe, has := force_enc.?; has {
		// The BOM belonged to the encoding it announced. Under a different
		// reading those bytes are content, so the skip goes with the detection
		// it came from -- otherwise a forced reopen quietly eats the first two
		// or three bytes of the file every time.
		if fe != enc {bom = 0}
		enc = fe
	}
	doc.enc = enc
	doc.had_bom = bom > 0

	// UTF-8 hands back the same bytes without reading them, so the mapping can
	// stay. Every other encoding transcodes, which reads every byte -- take a
	// private guarded copy first and decode from that.
	if fv.mapped && enc != .UTF8 {
		priv := make([]u8, len(fv.bytes))
		if !base.safe_copy(priv, fv.bytes) {
			doc.recovered = true
		}
		doc.original, doc.owned_orig = base.decode_to_utf8(priv, enc, bom)
		if !doc.owned_orig {
			// Defensive: every non-UTF-8 path allocates, but if that ever changes,
			// doc.original would alias priv and freeing it would be a dangling read.
			doc.owned_orig = true
		} else {
			delete(priv)
		}
	} else {
		doc.original, doc.owned_orig = base.decode_to_utf8(fv.bytes, enc, bom)
	}
	doc.pt = base.pt_init(doc.original)

	doc.idx.content = doc.original
	doc.idx.total = len(doc.original)
	// Guard the scan only when content aliases the mapping (UTF-8, no transcode);
	// a transcoded or copied original is private memory and can't fault.
	doc.idx.guard = doc.fv.mapped && !doc.owned_orig
	doc.eol = base.detect_line_ending(doc.original)
	doc.disk_stamp = plat.file_stamp(path) // baseline for change detection
	return doc, true
}

// Build an in-memory document from `content` (internal UTF-8, ownership taken)
// for session restore of a dirty/untitled buffer. `path` is the origin file
// ("" for untitled); the document is marked modified since it differs from disk.
doc_from_content :: proc(content: []u8, path: string, enc: base.Encoding) -> (doc: Document) {
	doc.original = content
	doc.owned_orig = true
	doc.enc = enc
	doc.pt = base.pt_init(content)
	if path != "" {
		doc.path = strings.clone(path)
		doc.path_owned = true
	}
	doc.modified = true
	doc.idx.content = content
	doc.idx.total = len(content)
	return
}

// Cancel and join the line indexer. Must happen before anything the worker's
// `content` slice points into is freed or unmapped.
doc_index_stop :: proc(doc: ^Document) {
	if doc.idx.th == nil {return}
	intrinsics.atomic_store(&doc.idx.cancel, true)
	thread.join(doc.idx.th)
	thread.destroy(doc.idx.th)
	doc.idx.th = nil
}

doc_index_start :: proc(doc: ^Document) {
	doc.idx.th = thread.create_and_start_with_data(&doc.idx, index_worker)
}

doc_close :: proc(doc: ^Document) {
	if doc.idx.th != nil {
		intrinsics.atomic_store(&doc.idx.cancel, true)
		thread.join(doc.idx.th)
		thread.destroy(doc.idx.th)
	}
	lex_index_stop(doc) // joins before the arrays below are freed
	delete(doc.lex_idx.line_starts)
	delete(doc.lex_idx.states)
	delete(doc.lex_idx.opens)
	// delete() frees the backing storage but leaves the [dynamic] header
	// (len/cap/data) pointing at now-freed memory -- harmless here only
	// because doc_reload immediately overwrites doc^ with a fresh zero value
	// right after calling this. Zero explicitly so a caller that ever closes
	// a document without an immediate doc_reload doesn't inherit a
	// freed-but-live array header (append/len on it would be heap corruption,
	// not just a stale read).
	doc.lex_idx.line_starts = nil
	doc.lex_idx.states = nil
	doc.lex_idx.opens = nil
	// Before pt_destroy: the worker's view aliases the add chunks it frees.
	search_release(doc)
	for s in doc.undo {snapshot_free(s)}
	for s in doc.redo {snapshot_free(s)}
	delete(doc.undo)
	delete(doc.redo)
	delete(doc.bookmarks)
	doc.bookmarks = nil // same freed-but-live header hazard as lex_idx above
	delete(doc.find.query)
	delete(doc.find.replace)
	delete(doc.filter_lines)
	delete(doc.filter_line_nos)
	delete(doc.table_widths)
	delete(doc.table_edit_buf)
	// The markdown preview's per-block layout cache owns heap storage (a source
	// copy, a span text store, the shaper's glyph and line-box arrays, and the
	// span boxes) for every filled slot. Freed here rather than left to the
	// process because a session that opens and closes many markdown files would
	// otherwise leak a screenful of shaped glyphs per file.
	md_layout_reset(doc)
	base.pt_destroy(&doc.pt)
	if doc.owned_orig {
		delete(doc.original)
	}
	if doc.path_owned {
		delete(doc.path)
	}
	plat.file_close(&doc.fv)
}

@(private = "file")
index_worker :: proc(data: rawptr) {
	idx := (^Line_Index)(data)
	c := idx.content
	CHUNK :: 64 * 1024
	buf: [CHUNK]u8
	line, i := 0, 0
	for i < len(c) {
		if intrinsics.atomic_load(&idx.cancel) {return}
		end := min(i + CHUNK, len(c))
		scan := c[i:end]
		if idx.guard {
			// c aliases a memory map: copy through the SEH guard first, so a
			// truncated/decompression-broken page stops the scan instead of
			// crashing. The main thread sees idx.fault and detaches the mapping.
			if !base.safe_copy(buf[:end - i], scan) {
				intrinsics.atomic_store(&idx.fault, true)
				return
			}
			scan = buf[:end - i]
		}
		for b in scan {if b == '\n' {line += 1}}
		i = end
		intrinsics.atomic_store(&idx.indexed, i)
		intrinsics.atomic_store(&idx.line_count, line + 1)
	}
	intrinsics.atomic_store(&idx.line_count, line + 1)
	intrinsics.atomic_store(&idx.indexed, len(c))
	intrinsics.atomic_store(&idx.done, true)
}

// A mapped read faulted (the file was truncated or its NTFS decompression failed
// underneath us). Copy whatever pages are still readable into private memory,
// detach from the mapping, and mark the document recovered so the user knows the
// content is no longer the file on disk. Main thread only; idempotent.
doc_recover_from_fault :: proc(doc: ^Document) {
	if doc.recovered || !doc.fv.mapped {return}
	// Stop the index worker before touching/unmapping the shared mapped bytes.
	if doc.idx.th != nil {
		intrinsics.atomic_store(&doc.idx.cancel, true)
		thread.join(doc.idx.th)
		thread.destroy(doc.idx.th)
		doc.idx.th = nil
	}
	// Same for the search worker: its view aliases the mapping about to be
	// unmapped. Restart it next frame against the recovered buffer.
	find_invalidate(doc)
	// Guarded copy of the mapped original into private memory (bad pages -> zeros).
	priv := make([]u8, len(doc.original))
	base.safe_copy(priv, doc.original)
	doc.original = priv
	doc.owned_orig = true
	doc.pt.original = priv // pieces index by offset, so this repoint is transparent
	doc.revision += 1 // faulted pages came back as zeros: real content change
	plat.file_close(&doc.fv) // unmaps and zeroes fv
	doc.recovered = true
	doc.modified = true // buffer differs from disk; don't let a save look clean

	// Re-index over the now-private buffer for a correct final line count.
	doc.idx.content = priv
	doc.idx.total = len(priv)
	doc.idx.guard = false
	intrinsics.atomic_store(&doc.idx.done, false)
	intrinsics.atomic_store(&doc.idx.fault, false)
	intrinsics.atomic_store(&doc.idx.cancel, false)
	intrinsics.atomic_store(&doc.idx.indexed, 0)
	intrinsics.atomic_store(&doc.idx.line_count, 0)
	doc_index_start(doc)
}

// True if a mapped read faulted on either the main thread or the index worker.
// The buffer flag is this document's own, so a fault on a background tab no
// longer recovers whichever document happens to be active.
doc_fault_pending :: proc(doc: ^Document) -> bool {
	return base.pt_take_fault(&doc.pt) || intrinsics.atomic_load(&doc.idx.fault) || search_faulted(doc)
}

// Save the buffer to `path`, re-encoded to the file's original encoding
// (UTF-16 files round-trip; UTF-8 keeps/omits its BOM as opened). Atomic write.
doc_save :: proc(doc: ^Document, path: string) -> bool {
	return doc_save_err(doc, path) == .None
}

// Returns why the save failed so the caller can tell the user. A save that fails
// silently is a data-loss bug: the user believes the file is written.
//
// Streamed in rune-aligned chunks rather than collect-whole + encode-whole: those
// were two full-buffer allocations on the main thread (~4-6 GB transient for a
// 2 GB doc, a real OOM). Now the peak is one chunk. UTF-8 writes the buffer bytes
// directly; other encodings transcode a chunk at a time and free it immediately.
SAVE_CHUNK :: 1 << 20
doc_save_err :: proc(doc: ^Document, path: string) -> plat.Write_Error {
	aw, ok := plat.atomic_write_begin(path)
	if !ok {return .Create_Temp}

	bom: [3]u8
	if bn := base.encoding_bom(bom[:], doc.enc, doc.had_bom); bn > 0 {
		if !plat.atomic_write(&aw, bom[:bn]) {
			plat.atomic_write_abort(&aw)
			return .Write
		}
	}

	raw := make([]u8, SAVE_CHUNK)
	defer delete(raw)
	for pos := 0; pos < doc.pt.length; {
		n := base.pt_read(&doc.pt, pos, raw[:min(SAVE_CHUNK, doc.pt.length - pos)])
		if n == 0 {break}
		if pos + n < doc.pt.length { // keep a multibyte rune whole across chunks
			if a := base.utf8_complete_len(raw[:n]); a > 0 {n = a}
		}
		wrote := false
		if doc.enc == .UTF8 {
			wrote = plat.atomic_write(&aw, raw[:n]) // no transcode: write as-is
		} else {
			enc := base.encode_body_from_utf8(raw[:n], doc.enc)
			wrote = plat.atomic_write(&aw, enc)
			delete(enc)
		}
		if !wrote {
			plat.atomic_write_abort(&aw)
			return .Write
		}
		pos += n
	}

	if err := plat.atomic_write_commit(&aw); err != .None {
		return err
	}
	newpath := strings.clone(path) // clone first: path may alias doc.path (re-save)
	if doc.path_owned {
		delete(doc.path)
	}
	doc.path = newpath
	doc.path_owned = true
	doc.modified = false
	// Record the file as we just left it, or the watcher reports our own write
	// as an external change on its next pass.
	doc.disk_stamp = plat.file_stamp(path)
	doc.disk_changed = false
	doc.disk_gone = false
	doc.appended = 0
	return .None
}

// Materialize the buffer as a string (debug/test only; leaks).
doc_debug_string :: proc(doc: ^Document) -> string {return string(base.pt_collect(&doc.pt))}

// The text of the line starting at `start` (no trailing newline).
doc_line_text :: proc(doc: ^Document, start: int, allocator := context.allocator) -> string {
	end := base.pt_line_end(&doc.pt, start)
	buf := make([]u8, end - start, allocator)
	base.pt_read(&doc.pt, start, buf)
	return string(buf)
}

doc_line_count :: proc(doc: ^Document) -> int {
	lc := intrinsics.atomic_load(&doc.idx.line_count)
	// nl_delta is only meaningful once the base count over the original is done.
	return lc + doc.nl_delta if intrinsics.atomic_load(&doc.idx.done) else lc
}
doc_index_done :: proc(doc: ^Document) -> bool {return intrinsics.atomic_load(&doc.idx.done)}
doc_index_faulted :: proc(doc: ^Document) -> bool {return intrinsics.atomic_load(&doc.idx.fault)}
doc_index_progress :: proc(doc: ^Document) -> f32 {
	if doc.idx.total == 0 {return 1}
	return f32(intrinsics.atomic_load(&doc.idx.indexed)) / f32(doc.idx.total)
}

// --- small buffer helpers ---

@(private = "file")
byte_at :: proc(doc: ^Document, i: int) -> u8 {
	one: [1]u8
	base.pt_read(&doc.pt, i, one[:])
	return one[0]
}

@(private = "file")
rune_size_lead :: proc(b: u8) -> int {
	switch {
	case b < 0x80:
		return 1
	case b < 0xE0:
		return 2
	case b < 0xF0:
		return 3
	case:
		return 4
	}
}

@(private = "file")
prev_rune :: proc(doc: ^Document, pos: int) -> int {
	if pos <= 0 {return 0}
	p := pos - 1
	for p > 0 && (byte_at(doc, p) & 0xC0) == 0x80 {p -= 1} // skip UTF-8 continuation bytes
	return p
}

@(private = "file")
next_rune :: proc(doc: ^Document, pos: int) -> int {
	if pos >= doc.pt.length {return doc.pt.length}
	return min(pos + rune_size_lead(byte_at(doc, pos)), doc.pt.length)
}

@(private = "file")
count_newlines :: proc(doc: ^Document, pos, count: int) -> (c: int) {
	buf: [4096]u8
	p, remaining := pos, count
	for remaining > 0 {
		n := base.pt_read(&doc.pt, p, buf[:min(len(buf), remaining)])
		if n == 0 {break}
		for k in 0 ..< n {if buf[k] == '\n' {c += 1}}
		p += n
		remaining -= n
	}
	return
}

// --- bookmarks ---
//
// Stored on the Document as sorted byte offsets of line starts (see the field's
// comment for why offsets). Everything below exists to keep two properties true:
// the list stays sorted with no duplicates, and every entry is still a real line
// start after any edit.
//
// The edit half of that is the whole difficulty of the feature, and it is solved
// the way find_invalidate and apply_snapshot solve the same shape for the match
// list and the column rectangle: ONE seam that every edit already passes through
// (here, pt_edit_replace, which wraps every piece-table mutation in this file),
// plus a cloned set carried on the undo Snapshot. No third mechanism, and in
// particular no per-command bookkeeping -- a command that forgets is exactly how
// the column rectangle went stale before §6u.
//
// "One seam" also means one RULE. It was briefly a shift-for-insert and a
// shift-for-delete, and a replace calls both at the same offset -- where the two
// correct halves produced a wrong answer that no invariant could see. See
// bookmarks_shift_replace.

// A bookmark's index in doc.bookmarks, and whether the offset is bookmarked.
// Binary search: the list is sorted by construction.
@(private = "file")
bookmark_find :: proc(doc: ^Document, off: int) -> (idx: int, found: bool) {
	lo, hi := 0, len(doc.bookmarks)
	for lo < hi {
		mid := (lo + hi) / 2
		if doc.bookmarks[mid] < off {lo = mid + 1} else {hi = mid}
	}
	return lo, lo < len(doc.bookmarks) && doc.bookmarks[lo] == off
}

// ONE edit, ONE shift. The range [at, at+n) is about to be replaced by `text`.
// An insert is n == 0, a delete is an empty `text`, and a real replace is both
// AT THE SAME OFFSET -- which is the entire reason this is a single procedure
// and not two.
//
// It WAS two, and the composition was wrong in a way that neither half could be
// blamed for. The delete rule correctly collapses a bookmark sitting at `at + n`
// down onto `at` (the "the line above me was deleted, my line starts there now"
// case); the insert rule then correctly declines to move an offset equal to `at`
// (the "you typed at my line start, that is still my line start" case). Compose
// them at one offset and the bookmark stops on the REPLACEMENT text: Alt+Down
// over a bookmarked line below, a paste over a Shift+Down/triple-click line
// selection, Replace All on any pattern ending in '\n'. The structural invariant
// held throughout -- every entry was still a real line start -- so nothing that
// checked the invariant could see it. CLAUDE.md §6j's shape exactly: two correct
// functions, wrong result.
//
// The rules, with `m` = len(text):
//
//   b < at            untouched; nothing before it moved.
//   at <= b < at+n    DROPPED. The line start itself is inside the replaced
//                     text, so afterwards the offset would name whatever bytes
//                     moved up into it -- a bookmark silently pointing at a
//                     different line, which is the one outcome worse than losing
//                     it. This is also what makes "delete the bookmarked line"
//                     drop it: that selection runs from the line start, so
//                     b == at.
//   b == at+n (n > 0) The edge the replacement butts against. The bookmarked
//                     line's text now begins at `at + m`, and the entry survives
//                     only if THAT is a line start:
//                       m > 0  -> `text` must END in '\n'. "bravo\n" -> "XX\n"
//                                 keeps the bookmark on the line below; the same
//                                 replace with "XX" merges that line onto the
//                                 replacement's tail, and it is DROPPED.
//                       m == 0 -> `at` must have been a line start. Deleting the
//                                 whole line ABOVE keeps the bookmark (its line
//                                 genuinely begins where the deleted one did);
//                                 Backspace at a bookmarked line start deletes
//                                 just the '\n' from mid-line, joins the two
//                                 lines, and DROPS it. One byte read out of the
//                                 LIVE buffer tells them apart -- which is why
//                                 this must run before the mutation.
//   b == at (n == 0)  A pure insert AT a bookmarked line start leaves it alone.
//                     The byte before `at` is untouched, so `at` is still a line
//                     start afterwards -- whether what was typed was "x" (the
//                     bookmark keeps naming the same line, now one character
//                     longer) or "abc\n" (it names the new line beginning
//                     there). Shifting instead would leave the "x" case one byte
//                     inside its own line, which no row's line start matches, so
//                     the mark would vanish while the entry stayed in the list.
//   otherwise         b += m - n.
//
// Every rule is monotone in `b`, so the list stays sorted and duplicate-free
// without a re-sort: entries before `at` do not move, the one at `at+n` lands on
// `at+m`, and everything past it lands strictly beyond that.
@(private = "file")
bookmarks_shift_replace :: proc(doc: ^Document, at, n: int, text: []u8) {
	m := len(text)
	if (n == 0 && m == 0) || len(doc.bookmarks) == 0 {return}
	// Asked by exactly one case, and only when n > 0, so a plain insert pays for
	// no byte read at all.
	end_is_line_start := false
	if n > 0 {
		end_is_line_start =
			text[m - 1] == '\n' if m > 0 else (at == 0 || (at <= doc.pt.length && byte_at(doc, at - 1) == '\n'))
	}
	keep := 0
	for b in doc.bookmarks {
		switch {
		case b < at:
			doc.bookmarks[keep] = b
			keep += 1
		case n == 0: // pure insert: `b == at` stays put, everything after shifts
			doc.bookmarks[keep] = b if b == at else b + m
			keep += 1
		case b < at + n: // the line start was inside the replaced text -- dropped
		case b == at + n:
			if end_is_line_start {
				doc.bookmarks[keep] = at + m
				keep += 1
			}
		case:
			doc.bookmarks[keep] = b + m - n
			keep += 1
		}
	}
	resize(&doc.bookmarks, keep)
}

// Every piece-table mutation in this file goes through these, so the bookmark
// shift cannot be forgotten at a call site. That is deliberate: the alternative
// -- a bookmarks_shift_* call next to each of the ten base.pt_* calls -- is
// CLAUDE.md's shape B (a correct function fed the wrong input, or forgotten at
// the eleventh site), and this feature's whole risk is exactly that. Nothing
// outside doc.odin calls base.pt_insert/base.pt_delete; block.odin and
// find.odin's replace both route through doc_replace_range.
//
// pt_edit_replace is the primitive and the other two are named sugar over it,
// rather than the other way round: a caller that deletes and then inserts at the
// same offset through the two thin wrappers is exactly the bug
// bookmarks_shift_replace's comment describes, so there is no pair of calls that
// can express it.
@(private = "file")
pt_edit_replace :: proc(doc: ^Document, at, n: int, text: []u8) {
	bookmarks_shift_replace(doc, at, n, text) // before the mutation: it reads byte_at(at-1)
	if n > 0 {base.pt_delete(&doc.pt, at, n)}
	if len(text) > 0 {base.pt_insert(&doc.pt, at, text)}
}

@(private = "file")
pt_edit_insert :: proc(doc: ^Document, at: int, text: []u8) {
	pt_edit_replace(doc, at, 0, text)
}

@(private = "file")
pt_edit_delete :: proc(doc: ^Document, at, n: int) {
	pt_edit_replace(doc, at, n, nil)
}

// Toggle the bookmark on the line the caret is on. Returns the resulting state
// (true = now bookmarked) and false in `ok` when the caret's line start could not
// be resolved within the cap -- the same refusal block_extend makes, and for the
// same reason: guessing would silently bookmark the wrong line.
doc_bookmark_toggle :: proc(doc: ^Document) -> (on, ok: bool) {
	if doc == nil || doc.kind != .Text {return false, false}
	ls, exact := base.pt_line_start_cap(&doc.pt, doc.cursor, BOOKMARK_LINE_CAP)
	if !exact {return false, false}
	idx, found := bookmark_find(doc, ls)
	if found {
		ordered_remove(&doc.bookmarks, idx)
		return false, true
	}
	inject_at(&doc.bookmarks, idx, ls)
	return true, true
}

// Bytes scanned backwards to find the caret's line start when toggling. Same
// budget MOVE_LINE_BUDGET uses and for the same reason: this is a keypress, not
// a frame pass, so it can afford more than RENDER_LINE_CAP -- but it still must
// not become an unbounded walk of a multi-GB single-line file.
BOOKMARK_LINE_CAP :: MOVE_LINE_BUDGET

// Move the caret to the next (or previous) bookmark, wrapping. A no-op with an
// empty set. Returns false when there was nothing to go to, so the caller can
// say so rather than leaving the keypress looking dead.
//
// Strictly after / strictly before the CARET, not the current bookmark index:
// there is no "current" bookmark to hold, the caret moves for a hundred other
// reasons, and an index would be one more thing every edit path has to fix.
doc_bookmark_cycle :: proc(doc: ^Document, back: bool) -> bool {
	if doc == nil || len(doc.bookmarks) == 0 {return false}
	idx, found := bookmark_find(doc, doc.cursor)
	target: int
	if back {
		// bookmark_find gives the first entry >= cursor, so the first one
		// strictly before it is idx-1 either way (found or not).
		target = doc.bookmarks[idx - 1] if idx > 0 else doc.bookmarks[len(doc.bookmarks) - 1]
	} else {
		nxt := idx + 1 if found else idx
		target = doc.bookmarks[nxt] if nxt < len(doc.bookmarks) else doc.bookmarks[0]
	}
	doc.cursor = target
	doc.anchor = target
	// Same reasoning as doc_select_all: this writes doc.cursor directly rather
	// than through set_cursor, so a live rectangle would otherwise survive a jump
	// to a line it no longer describes.
	if block_active(doc) {block_clear(doc)}
	return true
}

// --- undo/redo ---

@(private = "file")
snapshot :: proc(doc: ^Document) -> Snapshot {
	return {
		root = base.pt_snapshot(&doc.pt),
		length = doc.pt.length,
		cursor = doc.cursor,
		anchor = doc.anchor,
		nl_delta = doc.nl_delta,
		bookmarks = slice.clone(doc.bookmarks[:]) if len(doc.bookmarks) > 0 else nil,
	}
}

// Free everything a Snapshot owns. Every site that drops one calls this rather
// than pt_free_node_tree alone -- the tree used to be the only owned thing, and
// the four drop sites (doc_close x2, push_undo's redo clear, UNDO_MAX eviction)
// are exactly the kind of list that acquires a leak when a second owned field
// appears.
@(private = "file")
snapshot_free :: proc(s: Snapshot) {
	base.pt_free_node_tree(s.root)
	delete(s.bookmarks)
}

@(private = "file")
apply_snapshot :: proc(doc: ^Document, s: Snapshot) {
	find_invalidate(doc) // undo/redo don't go through push_undo
	doc.revision += 1 // ...so neither does its bump; the buffer content still moved
	base.pt_restore(&doc.pt, s.root, s.length) // takes ownership of s.root
	doc.cursor = s.cursor
	doc.anchor = s.anchor
	doc.nl_delta = s.nl_delta
	// The bookmark set belonging to the restored state, exactly as the tree is.
	// The snapshot's array is consumed here (the Snapshot is popped and never
	// freed by its caller, mirroring how pt_restore takes s.root), so this is a
	// move, not a copy.
	clear(&doc.bookmarks)
	append(&doc.bookmarks, ..s.bookmarks)
	delete(s.bookmarks)
	// This bypasses set_cursor, so a live rectangle would otherwise survive
	// undo/redo describing line/cell offsets a just-restored tree may no
	// longer have.
	if block_active(doc) {block_clear(doc)}
	doc.last_block_run = 0 // undo/redo/history jump always ends a run
}

@(private = "file")
// Record the state BEFORE an edit of `kind`.
//
// Consecutive typing coalesces into one entry: if the previous edit was also
// typing and the caret is exactly where it left off, the existing snapshot still
// describes the state before the whole run, so no new one is needed. Without
// this, "hello" is five undo steps and the history list is unreadable.
// A caret jump, a different kind of edit, or a newline breaks the run.
push_undo :: proc(doc: ^Document, kind: Edit_Kind = .Type) {
	find_invalidate(doc) // most edit paths route through here; match offsets shift
	doc.revision += 1 // ...and so must anything caching a measure of the buffer --
	// except apply_snapshot and doc_absorb_append, which bypass this by design and
	// bump revision themselves, and doc_reload, which replaces the struct wholesale.
	doc.modified = true
	// Any edit that is not part of the current column run ends it. Set here, on
	// the path every ordinary edit takes, so a missed break is impossible rather
	// than enumerated: doc_batch_begin_run re-sets it after calling through.
	doc.last_block_run = 0
	// One entry for the whole batch; doc_batch_begin already took the snapshot of
	// the state being left. Without this, Replace All pushed one snapshot per
	// match -- and since UNDO_MAX evicts the oldest, replacing more than 200
	// occurrences discarded the pre-replace state entirely. No amount of Ctrl+Z
	// could get the document back.
	if doc.batch {return}
	for s in doc.redo {snapshot_free(s)}
	clear(&doc.redo)

	continues := kind == .Type &&
		doc.last_edit == .Type &&
		doc.cursor == doc.last_edit_at &&
		len(doc.undo) > 0 &&
		!doc_has_sel(doc)
	if continues {
		doc.state_count += 1 // the run grows the state we are about to reach
		return
	}

	// The snapshot holds the state we are leaving, labelled with whatever
	// produced it. The edit now happening labels the state we are moving to.
	s := snapshot(doc)
	s.kind = doc.state_kind
	s.count = doc.state_count
	doc.state_kind = kind
	doc.state_count = 1
	append(&doc.undo, s)
	// Bounded: this is a long-lived process and every entry holds a cloned tree.
	if len(doc.undo) > UNDO_MAX {
		snapshot_free(doc.undo[0])
		ordered_remove(&doc.undo, 0)
	}
	doc.last_edit = kind
}

// Group a multi-edit operation into a single undo entry. Every editor treats
// Replace All as one step; doing otherwise is not just noisy, it overflows the
// undo stack and loses the state the user wants back.
doc_batch_begin :: proc(doc: ^Document, kind: Edit_Kind) {
	if doc.batch {return}
	push_undo(doc, kind) // snapshots the state being left, exactly once
	doc.batch = true
}

// `count` labels the resulting state in the history list ("Replace x37").
doc_batch_end :: proc(doc: ^Document, count: int) {
	if !doc.batch {return}
	doc.batch = false
	doc.state_count = max(count, 1)
	doc.last_edit = .None // a later keystroke must not coalesce into the batch
}

// Like doc_batch_begin, but CONTINUES the previous entry when this batch belongs
// to the same column-edit run and is the same kind of edit. `run` is doc.block_run;
// 0 behaves exactly like doc_batch_begin.
doc_batch_begin_run :: proc(doc: ^Document, kind: Edit_Kind, run: int) {
	if doc.batch {return}
	if run != 0 && run == doc.last_block_run && kind == doc.last_edit {
		// No snapshot -- the entry the first press pushed already describes the
		// state before the whole run. Everything ELSE push_undo does still must
		// happen: the buffer really is changing.
		find_invalidate(doc)
		doc.revision += 1
		doc.modified = true
		doc.batch = true
		return
	}
	push_undo(doc, kind)
	doc.batch = true
	doc.last_block_run = run // after push_undo, which clears it
}

// `count` labels the resulting state with the rows THIS press edited. It cannot
// accumulate across the run: push_undo unconditionally zeroes last_block_run
// before this runs (see push_undo's comment -- that ordering is what makes the
// break condition complete), so by the time we get here the token this batch
// began with never survives to be compared against. A coalesced run is
// therefore labelled by its last press -- "x3" for a held key over a 3-row
// rectangle, not an accumulated "x60" -- which is also the more truthful
// number: the entry restores three columns, not sixty rows.
doc_batch_end_run :: proc(doc: ^Document, count, run: int) {
	if !doc.batch {return}
	doc.batch = false
	doc.state_count = max(count, 1)
	// doc_batch_end sets last_edit = .None so a later keystroke cannot coalesce
	// into a batch. A column run is the one case where the next press must, so
	// the kind is left alone and the run token is what gates it.
	doc.last_block_run = run
}

doc_undo :: proc(doc: ^Document) {
	if len(doc.undo) == 0 {return}
	cur := snapshot(doc) // the state we leave keeps its own description
	cur.kind, cur.count = doc.state_kind, doc.state_count
	append(&doc.redo, cur)
	s := pop(&doc.undo)
	doc.state_kind, doc.state_count = s.kind, s.count
	apply_snapshot(doc, s) // s.root becomes the live tree
	doc.last_edit = .None
}

doc_redo :: proc(doc: ^Document) {
	if len(doc.redo) == 0 {return}
	cur := snapshot(doc)
	cur.kind, cur.count = doc.state_kind, doc.state_count
	append(&doc.undo, cur)
	s := pop(&doc.redo)
	doc.state_kind, doc.state_count = s.kind, s.count
	apply_snapshot(doc, s)
	doc.last_edit = .None
}

// Change the encoding the document will be SAVED as. The buffer is already
// internal UTF-8, so nothing is re-decoded — only the target changes.
doc_set_encoding :: proc(doc: ^Document, enc: base.Encoding) {
	if doc.enc == enc {return}
	doc.enc = enc
	if enc != .UTF8 {doc.had_bom = enc == .UTF16LE || enc == .UTF16BE}
	doc.modified = true // it now differs from what is on disk
}

// Rewrite the buffer's line endings. A real edit, so it goes through the undo
// path and can be reverted.
doc_set_line_ending :: proc(doc: ^Document, eol: base.Line_Ending) {
	if eol == .Mixed || doc.eol == eol {return}
	body := base.pt_collect(&doc.pt, context.temp_allocator)
	converted := base.convert_line_endings(body, eol, context.temp_allocator)
	if len(converted) == len(body) {
		doc.eol = eol // nothing actually changed (no line breaks)
		return
	}
	push_undo(doc, .Replace)
	// One replace over the whole buffer, so the bookmark rules see it as one
	// operation. Every bookmark inside [0, length) -- which is all of them,
	// INCLUDING one at offset 0 -- is dropped, and that is the right answer
	// rather than an accident: a CRLF<->LF rewrite moves every line start after
	// the first by one byte per preceding line, so nothing here could be shifted
	// correctly without re-walking the whole buffer. Undo restores the set (the
	// snapshot above holds it).
	//
	// The one survivor is a bookmark on the trailing empty line, at offset ==
	// length, which is not inside the replaced range: it moves to the new end,
	// which is still the trailing empty line. That is exact, not a guess. As two
	// calls it instead landed on 0 and stayed there, putting a mark on line 1
	// that the user never set -- the silent-relocation outcome this feature is
	// written to avoid, and the reason the delete and the insert are one call.
	pt_edit_replace(doc, 0, doc.pt.length, converted)
	doc.eol = eol
	doc.cursor = clamp(doc.cursor, 0, doc.pt.length)
	doc.anchor = doc.cursor
	doc.nl_delta = 0
	doc_index_stop(doc)
	doc.idx.content = doc.original
	doc.idx.total = len(doc.original)
	doc_index_start(doc)
}

// --- external changes ---

// Copy the mapped bytes into private memory and drop the mapping.
//
// This is the "never lock the user's file" rule made real. A user-mapped section
// makes Windows refuse truncation, deletion and replacement of the file
// (ERROR_USER_MAPPED_FILE), so a service cannot roll a log while we hold it
// mapped. As soon as the file starts changing we get out of the way.
//
// Also removes the moving-target problem: an external in-place write changes the
// bytes under a mapping with no size change and no fault, so every offset the
// buffer derived from them would silently describe different content.
doc_detach_mapping :: proc(doc: ^Document) {
	if !doc.fv.mapped {return}
	find_invalidate(doc) // the search worker holds a view aliasing the mapping
	doc_index_stop(doc)

	priv := make([]u8, len(doc.original))
	base.safe_copy(priv, doc.original)
	doc.original = priv
	doc.owned_orig = true
	doc.pt.original = priv // pieces index by offset, so the repoint is transparent
	plat.file_close(&doc.fv)

	doc.idx.content = priv
	doc.idx.total = len(priv)
	doc.idx.guard = false
	intrinsics.atomic_store(&doc.idx.done, false)
	intrinsics.atomic_store(&doc.idx.fault, false)
	intrinsics.atomic_store(&doc.idx.cancel, false)
	intrinsics.atomic_store(&doc.idx.indexed, 0)
	intrinsics.atomic_store(&doc.idx.line_count, 0)
	doc_index_start(doc)
}

// Bytes appended to the file since we last looked, pulled in without remapping.
// Returns false if the change was not a pure append (the file shrank, or the
// read came up short because it is mid-write — retried on the next poll).
//
// Appending through the add arena rather than remapping is what makes this safe
// against the search worker: arena chunks never move, so a pt_view stays valid
// by construction. No cancel, no join, no unmap window.
doc_absorb_append :: proc(doc: ^Document, new_size: i64) -> bool {
	// Only for documents whose bytes correspond 1:1 with file bytes. A BOM
	// shifts every offset by 3 and UTF-16 is transcoded, so "file grew by N"
	// says nothing about how many document bytes to add.
	if doc.enc != .UTF8 || doc.had_bom {return false}
	// The real precondition is that the buffer IS the file's first `old` bytes.
	// Deriving `old` from len(original)+appended broke after a save: saving
	// writes pt.length bytes and clears `appended`, but leaves `original` at its
	// opening length, so the next append re-read the user's own saved edits and
	// inserted them a second time — silently duplicating text in their file.
	if i64(doc.pt.length) != doc.disk_stamp.size {return false}
	old := doc.disk_stamp.size
	if new_size <= old {return false}

	chunk, ok := plat.file_read_range(doc.path, old, int(new_size - old))
	defer delete(chunk)
	if !ok || len(chunk) == 0 {return false}

	// Appending at the end never disturbs earlier offsets, so the caret,
	// selection, search results and bookmarks all stay meaningful. A bookmark on
	// the TRAILING EMPTY LINE is at offset == length, i.e. exactly at the
	// insertion point, and bookmarks_shift_replace's pure-insert rule leaves it
	// there -- correctly: that offset is still preceded by '\n', so it is still a
	// line start, and it now names the first line that arrived from disk, which
	// is the same line the mark was on, grown some content.
	at_end := doc.cursor >= doc.pt.length
	pt_edit_insert(doc, doc.pt.length, chunk)
	for b in chunk {if b == '\n' {doc.nl_delta += 1}}
	doc.appended += len(chunk)
	doc.revision += 1 // content changed; this path deliberately skips push_undo
	if at_end { // follow the tail, like tail -f
		doc.cursor = doc.pt.length
		doc.anchor = doc.cursor
	}
	find_invalidate(doc) // match offsets past the old end are now stale
	// This bypasses push_undo, so a live column run's token would otherwise
	// survive an append. The next press would then coalesce onto a snapshot
	// taken before the appended tail, and one Ctrl+Z would discard bytes that
	// came from disk, not from the user's edit.
	doc.last_block_run = 0
	return true
}

// Re-open from disk, discarding the buffer. Used when the change was not a
// simple append. Undo states describe a document that no longer exists, so they
// go; keeping them would let Ctrl+Z resurrect a file that was never on disk.
doc_reload :: proc(doc: ^Document) -> bool {
	return doc_reload_forced(doc, nil)
}

// Re-open from disk, discarding the buffer. `force_enc` re-decodes under an
// encoding the user picked instead of the detected one (the Reopen As commands);
// nil is an ordinary reload. Undo states describe a document that no longer
// exists, so they go; keeping them would let Ctrl+Z resurrect a file that was
// never on disk.
doc_reload_forced :: proc(doc: ^Document, force_enc: Maybe(base.Encoding)) -> bool {
	if doc.path == "" {return false}
	fresh, ok := doc_open(doc.path, force_enc)
	if !ok {return false}

	cursor, anchor, top := doc.cursor, doc.anchor, doc.top
	view := doc_view_capture(doc)
	path := strings.clone(doc.path)
	// fresh is a brand-new Document and so starts at revision 0; carried forward
	// and bumped rather than left at 0, or revision would go backwards on a tab
	// that had already advanced past 0 -- breaking the "monotonic" contract a
	// cache relies on to tell reload apart from "nothing happened since I looked".
	rev := doc.revision

	doc_close(doc) // stops both workers, frees the trees and the old original
	doc^ = fresh
	if doc.path_owned {delete(doc.path)}
	doc.path = path
	doc.path_owned = true
	doc.revision = rev + 1
	// Preserve position by byte offset, clamped — the file may have shrunk.
	L := doc.pt.length
	doc.cursor = clamp(cursor, 0, L)
	doc.anchor = clamp(anchor, 0, L)
	doc.top = clamp(top, 0, L)
	// Applied after the position clamps, not before: doc_view_apply re-anchors
	// doc.top to a line start when a line-scrolled view is on, and the clamp above
	// would overwrite that. (An earlier draft of this comment claimed the ordering
	// was about doc.path being empty until line 1381 -- it never is: doc_open
	// clones the path into `fresh`, so doc.path is valid the instant doc^ = fresh
	// runs. Sabotaging the order fails through `top`, not through the gates.)
	doc_view_apply(doc, view)
	doc.disk_stamp = plat.file_stamp(doc.path)
	doc.disk_changed = false
	doc.disk_gone = false
	doc.recovered = false // freshly read; no longer a salvaged copy
	// doc_close stopped the index and nil'd idx.th, and only app_activate starts
	// one lazily -- which never fires again for a tab that is already active. So
	// a reload left the status bar reading "0 lines, indexing 0%" for good, on the
	// log-tailing path this feature exists for.
	doc_index_start(doc)
	lex_index_start(doc) // same reasoning: doc_close nil'd lex_idx.th too
	// No block_clear needed: doc^ = fresh above already zeroed every
	// block_* field (zero-is-initialization), so a live rectangle cannot
	// survive a reload -- unlike apply_snapshot/doc_select_all/etc, which
	// mutate doc.cursor/anchor in place and so need an explicit clear.
	return true
}

// --- history list ---

// Total states the history can show: every undo entry, the current state, and
// everything on the redo stack (which is stored newest-last, so it reads
// backwards relative to the timeline).
doc_history_len :: proc(doc: ^Document) -> int {
	return len(doc.undo) + 1 + len(doc.redo)
}

// Index of the state the document is currently at.
doc_history_current :: proc(doc: ^Document) -> int {return len(doc.undo)}

// Label for history entry `i`: what produced that state. Every entry carries its
// own description, so a state keeps its label as it moves between the undo and
// redo stacks — deriving it from a neighbour made states rename themselves to
// "Opened" the moment you jumped to one.
doc_history_label :: proc(doc: ^Document, i: int) -> string {
	kind: Edit_Kind
	count := 0
	switch {
	case i < len(doc.undo):
		kind, count = doc.undo[i].kind, doc.undo[i].count
	case i == len(doc.undo):
		kind, count = doc.state_kind, doc.state_count
	case:
		// redo is stored newest-last, so it reads backwards against the timeline
		j := len(doc.redo) - 1 - (i - len(doc.undo) - 1)
		if j < 0 || j >= len(doc.redo) {return "?"}
		kind, count = doc.redo[j].kind, doc.redo[j].count
	}
	switch kind {
	case .Type:
		return fmt.tprintf("Typed %d character%s", count, "" if count == 1 else "s")
	case .Newline:
		return "New line"
	case .Delete:
		return fmt.tprintf("Deleted %d time%s", count, "" if count == 1 else "s")
	case .Paste:
		return "Inserted text"
	case .Replace:
		return "Replaced"
	case .None:
		return "As opened"
	}
	return "Edit"
}

// Move the document to history state `target` by walking undo/redo. Walking
// rather than jumping directly keeps both stacks consistent, and each step is a
// tree swap, not a copy of the text.
doc_history_goto :: proc(doc: ^Document, target: int) {
	t := clamp(target, 0, doc_history_len(doc) - 1)
	for doc_history_current(doc) > t && len(doc.undo) > 0 {doc_undo(doc)}
	for doc_history_current(doc) < t && len(doc.redo) > 0 {doc_redo(doc)}
	doc.last_edit = .None // a jump always breaks a typing run
}

// --- selection ---
// Selection is [min(anchor,cursor), max(anchor,cursor)); active when anchor != cursor.

doc_sel_range :: proc(doc: ^Document) -> (lo, hi: int) {
	if doc.anchor <= doc.cursor {
		return doc.anchor, doc.cursor
	}
	return doc.cursor, doc.anchor
}

doc_has_sel :: proc(doc: ^Document) -> bool {return doc.anchor != doc.cursor}

@(private = "file")
set_cursor :: proc(doc: ^Document, pos: int, select: bool) {
	doc.cursor = pos
	if !select {
		doc.anchor = pos
		// A plain (non-extending) caret move collapses a normal selection --
		// and it must drop a live column rectangle the same way, or an
		// unrelated arrow key (Home, a click, Ctrl+Right...) would leave a
		// stale block behind describing a rectangle the caret has already
		// left. block_extend never reaches this branch itself (it only ever
		// touches the block_* fields directly, not doc.cursor/anchor), so
		// this cannot clear a block out from under the gesture that is
		// actively building it.
		if block_active(doc) {
			block_clear(doc)
		}
	}
}

// Replace the selection (possibly empty) with `text` (possibly empty) as ONE
// piece-table operation, leaving the caret just past what was written.
//
// One operation, not a delete followed by an insert at the same offset: see
// bookmarks_shift_replace. Pasting over a whole-line selection is the everyday
// way to hit that, so this is the seam it has to be fixed at rather than in
// doc_insert_text alone.
@(private = "file")
replace_sel_raw :: proc(doc: ^Document, text: []u8) {
	lo, hi := doc_sel_range(doc)
	doc.nl_delta -= count_newlines(doc, lo, hi - lo)
	pt_edit_replace(doc, lo, hi - lo, text)
	for b in text {if b == '\n' {doc.nl_delta += 1}}
	doc.cursor = lo + len(text)
	doc.anchor = doc.cursor
}

@(private = "file")
del_sel_raw :: proc(doc: ^Document) {
	replace_sel_raw(doc, nil)
}

// Selected text as a freshly-allocated UTF-8 string (empty if no selection).
doc_selected_text :: proc(doc: ^Document, allocator := context.allocator) -> string {
	lo, hi := doc_sel_range(doc)
	if lo == hi {
		return ""
	}
	buf := make([]u8, hi - lo, allocator)
	base.pt_read(&doc.pt, lo, buf)
	return string(buf)
}

// --- edits (an active selection is replaced/deleted first, as one undo step) ---

// `kind` labels the entry in the history and decides coalescing: a single typed
// character continues a run, a paste or a newline always starts a new entry.
doc_insert_text :: proc(doc: ^Document, text: []u8, kind: Edit_Kind = .Paste) {
	if len(text) == 0 {return}
	push_undo(doc, kind)
	// With no selection doc_sel_range is (cursor, cursor), so this is a plain
	// insert at the caret; with one it is a single replace rather than a delete
	// and an insert at the same offset (bookmarks_shift_replace explains why the
	// difference is not cosmetic).
	replace_sel_raw(doc, text)
	doc.last_edit_at = doc.cursor
}

// Replace the selection with `text`, which is allowed to be empty. Find and
// replace routed this through doc_insert_text, which returns early on empty
// input -- before it deletes the selection -- so "replace X with nothing", a
// first-class use of the feature, silently did nothing and said nothing.
doc_replace_sel :: proc(doc: ^Document, text: []u8, kind: Edit_Kind = .Replace) {
	if len(text) > 0 {
		doc_insert_text(doc, text, kind)
		return
	}
	if !doc_has_sel(doc) {return}
	push_undo(doc, .Delete)
	del_sel_raw(doc)
	doc.last_edit_at = doc.cursor
}

// Replace the raw byte range [at, at+count) with `text`, as one undo step,
// leaving the cursor just past the inserted text. Used by table cell editing,
// which addresses the source directly rather than via the selection.
doc_replace_range :: proc(doc: ^Document, at, count: int, text: []u8, kind: Edit_Kind = .Replace) {
	// Clamp to the buffer: a caller's range may have been captured before some
	// other edit shrank the document (a table cell edit holds byte offsets), and
	// an out-of-range pt_delete would fault. Defence in depth -- table view also
	// blocks the commands that could shrink it mid-edit.
	at := clamp(at, 0, doc.pt.length)
	count := clamp(count, 0, doc.pt.length - at)
	if count == 0 && len(text) == 0 {return}
	push_undo(doc, kind)
	if count > 0 {doc.nl_delta -= count_newlines(doc, at, count)}
	// One pt_edit_replace, not a delete plus an insert at the same offset. This
	// is the path Alt+Up/Alt+Down, Replace All and a column edit all take, and
	// splitting it silently moved a bookmark onto the replacement text --
	// see bookmarks_shift_replace.
	pt_edit_replace(doc, at, count, text)
	for b in text {if b == '\n' {doc.nl_delta += 1}}
	doc.cursor = at + len(text)
	doc.anchor = doc.cursor
	doc.last_edit_at = doc.cursor
	doc.last_edit = .None // don't coalesce a later keystroke into this
}

// A single typed character: the one case that coalesces into a run. A newline
// breaks the run so undo stops at line boundaries, which is what people expect.
doc_insert_rune :: proc(doc: ^Document, r: rune) {
	bytes, n := utf8.encode_rune(r)
	doc_insert_text(doc, bytes[:n], .Newline if r == '\n' else .Type)
}

// Enter. Writes the document's own terminator rather than a bare LF: on a CRLF
// file a lone '\n' mixes line endings for good, and doc.eol is detected once at
// open, so nothing downstream notices or reports it.
doc_insert_newline :: proc(doc: ^Document) {
	if doc.eol == .CRLF {
		// kind: .Newline (not the doc_insert_text default of .Paste) so undo
		// history still reads "New line" and a following keystroke still
		// breaks the typing run, exactly as the LF path below does.
		doc_insert_text(doc, transmute([]u8)string("\r\n"), .Newline)
		return
	}
	// .LF and .Mixed both land here: .Mixed means the file already disagrees
	// with itself, so there is no right terminator to pick, and LF is the same
	// harmless default detect_line_ending falls back to.
	doc_insert_rune(doc, '\n')
}

doc_backspace :: proc(doc: ^Document) {
	if doc_has_sel(doc) {
		push_undo(doc, .Delete)
		del_sel_raw(doc)
		doc.last_edit_at = doc.cursor
		return
	}
	if doc.cursor <= 0 {return}
	push_undo(doc, .Delete)
	// Mirror of doc_delete_fwd: Backspace at a line start must take the whole
	// CRLF break with it, not just the LF, or a bare CR is left behind.
	p := doc.cursor - 2 if doc.cursor >= 2 && base.pt_crlf_at(&doc.pt, doc.cursor - 2) else prev_rune(doc, doc.cursor)
	doc.nl_delta -= count_newlines(doc, p, doc.cursor - p)
	pt_edit_delete(doc, p, doc.cursor - p)
	set_cursor(doc, p, false)
	doc.last_edit_at = doc.cursor
}

doc_delete_fwd :: proc(doc: ^Document) {
	if doc_has_sel(doc) {
		push_undo(doc, .Delete)
		del_sel_raw(doc)
		doc.last_edit_at = doc.cursor
		return
	}
	if doc.cursor >= doc.pt.length {return}
	push_undo(doc, .Delete)
	// A CRLF break is one unit: deleting forward from the content end (the CR;
	// see doc_cursor_end) must take the LF with it, or the buffer still renders
	// two lines -- the keystroke looks dead -- and the stray LF corrupts an
	// otherwise-CRLF file on save.
	n := 2 if base.pt_crlf_at(&doc.pt, doc.cursor) else next_rune(doc, doc.cursor) - doc.cursor
	doc.nl_delta -= count_newlines(doc, doc.cursor, n)
	pt_edit_delete(doc, doc.cursor, n)
	doc.anchor = doc.cursor
}

// Bytes scanned/allocated/copied per line-move press. This path is not
// navigation -- it scans, then allocates, then copies, then inserts -- so it
// needs its own budget well above RENDER_LINE_CAP's per-frame render bound.
// 2 MiB comfortably covers any real line (minified JSON lines run to a few
// hundred KB in practice) while keeping the worst case a bounded, synchronous
// blip on the input thread rather than an open-ended scan of a multi-GB file.
MOVE_LINE_BUDGET :: 2 * 1024 * 1024

// The end of a line's content (excluding its terminator) and the terminator's
// length in bytes: 0 if `line_start` begins the buffer's final, unterminated
// line, 1 for a bare LF, 2 for CRLF. pt_line_end stops at the '\n', which for
// a CRLF line leaves the '\r' looking like content -- doc_cursor_end peels the
// same byte off for the same reason. doc_move_lines needs this split to
// reason about "line plus its following terminator" as one unit, so a swap
// never cuts a CRLF pair in half.
//
// Capped: `ok` is false when no terminator (or buffer end) was found within
// `cap` bytes of `line_start`, meaning the line is longer than the move
// budget. The caller must bail rather than trust content_end/term_len, or a
// pathologically long line gets split instead of refused.
@(private = "file")
line_span_cap :: proc(pt: ^base.Piece_Table, line_start, cap: int) -> (content_end, term_len: int, ok: bool) {
	limit := min(pt.length, line_start + cap)
	nl := base.pt_line_end_cap(pt, line_start, cap)
	if nl >= limit && limit < pt.length {
		return 0, 0, false // hit the budget before finding the line's own terminator
	}
	if nl >= pt.length {
		return pt.length, 0, true
	}
	if nl > 0 && base.pt_crlf_at(pt, nl - 1) {
		return nl - 1, 2, true
	}
	return nl, 1, true
}

// A defensive copy of pt[pos:pos+n) on the frame arena, for assembling
// doc_move_lines' replacement text out of relocated pieces. nil for n <= 0 so
// appending it is a no-op rather than an out-of-range read.
@(private = "file")
read_range :: proc(pt: ^base.Piece_Table, pos, n: int) -> []u8 {
	if n <= 0 {return nil}
	buf := make([]u8, n, context.temp_allocator)
	base.pt_read(pt, pos, buf)
	return buf
}

// Alt+Up / Alt+Down: move every logical line the selection touches up or down
// past its neighbour, keeping the selection so the key can be held and the
// move repeated. One undo entry per press; no wraparound -- the first line
// has nothing above it and the last has nothing below, so those are a no-op
// rather than a rotation. (Declined: duplicating the line instead of moving
// it -- a different command, not this one.)
//
// The hazard is terminators: they live BETWEEN lines, and the buffer's last
// line usually has none. Terminators keep their positions -- only the two
// lines swap between them. The separator between A and `other` is always the
// one that already separated them before the swap (physically A's own, when A
// sat first and moved down past `other`; physically `other`'s own, when
// `other` sat first and A moved up past it) -- and it always exists, by the
// same reasoning that makes the no-neighbour cases below a bail rather than
// an edit. The separator after the pair is whichever one already followed the
// physically-second piece, carried over unchanged -- so it is empty exactly
// when that piece was the buffer's true unterminated last line, with no
// separate case needed for it. No synthesis, ever: a line move relocates
// bytes, it never invents or discards a terminator, so a `.Mixed` document's
// line endings are untouched anywhere the user didn't touch them. Everything
// else -- both lines' own text -- is untouched bytes, just relocated. One
// doc_replace_range over the whole region, so no intermediate state ever
// exists and no offset can drift mid-edit.
doc_move_lines :: proc(doc: ^Document, delta: int) {
	orig_anchor, orig_cursor := doc.anchor, doc.cursor

	// Both line-start scans run before any bail below, so an uncapped scan here
	// would make the no-op case (e.g. the cursor sitting on a single giant line)
	// the expensive one. A cap hit means the real line start is more than the
	// budget away -- bail rather than guess.
	lo, lo_exact := base.pt_line_start_cap(&doc.pt, min(orig_anchor, orig_cursor), MOVE_LINE_BUDGET)
	if !lo_exact {return}
	last_start, last_exact := base.pt_line_start_cap(&doc.pt, max(orig_anchor, orig_cursor), MOVE_LINE_BUDGET)
	if !last_exact {return}
	end_a, term_a, a_ok := line_span_cap(&doc.pt, last_start, MOVE_LINE_BUDGET)
	if !a_ok {return}

	if delta < 0 && lo == 0 {return} // first line: no line above to swap with
	// `end_a + term_a` (not the brief's raw pt_line_end) is A's true span end,
	// terminator included: a last line WITH a trailing newline has term_a > 0
	// but still has no next line to swap with, since the terminator is the
	// last byte in the buffer. Using the raw, un-peeled pt_line_end here
	// under-counts a CRLF terminator by one byte and would fail to bail on
	// exactly that case (see the report's arithmetic on "last line down").
	if delta > 0 && end_a + term_a >= doc.pt.length {return} // last line: no line below

	// `other` is the neighbour A swaps with -- the next line moving down, the
	// previous line moving up -- and `a_first` says which of A/other lands
	// first in the new byte order.
	other_start, other_end, other_term: int
	region_lo, region_hi: int
	a_first: bool
	if delta > 0 {
		other_start = end_a + term_a
		ok: bool
		other_end, other_term, ok = line_span_cap(&doc.pt, other_start, MOVE_LINE_BUDGET)
		if !ok {return}
		region_lo, region_hi = lo, other_end + other_term
		a_first = false
	} else {
		exact: bool
		other_start, exact = base.pt_line_start_cap(&doc.pt, lo - 1, MOVE_LINE_BUDGET)
		if !exact {return}
		ok: bool
		other_end, other_term, ok = line_span_cap(&doc.pt, other_start, MOVE_LINE_BUDGET)
		if !ok {return}
		region_lo, region_hi = other_start, end_a + term_a
		a_first = true
	}

	// MOVE_LINE_BUDGET only bounded the individual scans above -- it said
	// nothing about region_hi - region_lo, the span that's about to be read,
	// copied and pushed through doc_replace_range (delete + insert + an undo
	// tree clone). A short last line with a multi-GB selection above it (click
	// line 2, Ctrl+Shift+End, Alt+Up) sailed through every _cap check while
	// read_range below allocated and copied the whole remainder of the file on
	// the input thread. Bail here, once both region ends are known, so the
	// neighbour's size counts against the budget too, not just the selection's.
	if region_hi - region_lo > MOVE_LINE_BUDGET {return}

	a_bytes := read_range(&doc.pt, lo, end_a - lo)
	other_bytes := read_range(&doc.pt, other_start, other_end - other_start)
	a_term_bytes := read_range(&doc.pt, end_a, term_a)
	other_term_bytes := read_range(&doc.pt, other_end, other_term)

	// sep_mid is whichever piece sat PHYSICALLY first before the swap: A when
	// moving down (A preceded other), other when moving up (other preceded A).
	// sep_end is the other one's own terminator, carried over unchanged as the
	// separator after the pair -- see the doc comment above for why this needs
	// no synthesis and no unterminated-tail special case.
	sep_mid := a_term_bytes if delta > 0 else other_term_bytes
	sep_end := other_term_bytes if delta > 0 else a_term_bytes

	first_bytes := a_bytes if a_first else other_bytes
	second_bytes := other_bytes if a_first else a_bytes

	out := make(
		[dynamic]u8,
		0,
		len(first_bytes) + len(sep_mid) + len(second_bytes) + len(sep_end),
		context.temp_allocator,
	)
	append(&out, ..first_bytes)
	append(&out, ..sep_mid)
	append(&out, ..second_bytes)
	append(&out, ..sep_end)

	doc_batch_begin(doc, .Replace)
	doc_replace_range(doc, region_lo, region_hi - region_lo, out[:])
	doc_batch_end(doc, 1)

	// doc_replace_range collapses to a single caret past the inserted text;
	// restore the selection so Alt+Up/Down can be held and the move repeated.
	// A's internal bytes kept their relative layout, so shifting both ends by
	// A's net displacement reproduces the original selection exactly.
	new_a_start := region_lo if a_first else region_lo + len(first_bytes) + len(sep_mid)
	shift := new_a_start - lo
	doc.anchor = orig_anchor + shift
	doc.cursor = orig_cursor + shift
	doc.last_edit_at = doc.cursor
}

// --- sort lines / remove duplicate lines ---
//
// Three commands over one procedure, because the only thing that differs is what
// happens to the line list in the middle: the scope resolution, the cap, the
// terminator handling, the single write and the bookmark consequence are shared
// and each of them is a place a second copy would drift.
//
// The shape is doc_move_lines': resolve a whole-line region, read it ONCE, build
// the replacement in a private buffer, and write it back with ONE
// doc_replace_range inside a doc_batch_begin/end pair. Not a per-line edit loop
// -- §5's measurement is 2,000 per-row splices at 64 ms with the tree left
// fragmented so every later read pays, where one region replace costs what a
// single edit costs.

// The region a sort will read, allocate and copy in one go, on the input thread.
// 16 MiB is eight times MOVE_LINE_BUDGET: a sort is a deliberate, once-in-a-while
// action rather than a held key, so it can afford more than a line move, but it
// still must not turn "Ctrl+A, sort" on a multi-GB log into an unbounded copy.
SORT_MAX_BYTES :: 16 * 1024 * 1024
// ...and the line count, which the byte cap does not bound on its own: 16 MiB of
// "a\n" is eight million lines, and the sort's own bookkeeping (a Sort_Line per
// line, plus a map entry per line for dedupe) is what costs there, not the bytes.
// Whichever binds first refuses.
SORT_MAX_LINES :: 1_000_000

// What a sort did, so the caller can post the note. doc.odin has no ^App (the
// same layering block_extend keeps), so the refusal text lives in commands.odin
// beside every other refusal note.
Sort_Result :: enum u8 {
	Ok, // the region was rewritten
	Unchanged, // already sorted / no duplicates -- nothing written, NO undo entry
	Too_Big, // over SORT_MAX_BYTES or SORT_MAX_LINES: refused, nothing changed
	Unresolved, // a line start or line end further than the cap away: refused
	Faulted, // the region's read faulted on the mapping: refused, nothing changed
}

Sort_Mode :: enum u8 {
	Ascending,
	Descending,
	Dedupe,
}

// One line of the region: a slice INTO the read-once buffer (which does not move
// while the sort runs) plus where the line started out.
//
// `idx` is not decoration -- it is the final tie-break in both comparators, and
// it is what makes the sort STABLE. slice.sort_by is smoothsort and explicitly
// "not guaranteed to be stable", so without a tie-break the order of `Foo` and
// `foo` -- equal under a case-insensitive compare -- would be whatever the heap
// happened to do. With it the comparator is a total order and the result is the
// stable one by construction, independent of the algorithm underneath.
@(private = "file")
Sort_Line :: struct {
	text: []u8,
	idx:  int,
}

// Ascending and descending as two procs rather than one plus a flag: slice.sort_by
// takes a plain proc with no closure, and a package-level "which direction is this
// sort" variable is exactly the kind of hidden state that makes two call sites
// disagree. Note both tie-break on `idx` ASCENDING: descending reverses the ORDER,
// not the ties, so equal lines keep their original relative order either way --
// which is also why this cannot be reverse_sort over the ascending comparator.
@(private = "file")
sort_less_asc :: proc(a, b: Sort_Line) -> bool {
	c := sort_cmp_ci(a.text, b.text)
	return c < 0 if c != 0 else a.idx < b.idx
}

@(private = "file")
sort_less_desc :: proc(a, b: Sort_Line) -> bool {
	c := sort_cmp_ci(a.text, b.text)
	return c > 0 if c != 0 else a.idx < b.idx
}

@(private = "file")
sort_lower :: proc(b: u8) -> u8 {return b + 32 if b >= 'A' && b <= 'Z' else b}

// Case-insensitive (ASCII) byte order, ties broken by length. Not a locale
// collation and not Unicode case folding: this is the "no options" sort of
// principle 3, and the audience is log lines and identifiers.
//
// The limitation, stated rather than left to be discovered: sort_lower folds
// A-Z and nothing else, so a-umlaut and A-umlaut do NOT fold and a mixed-case
// German list is not alphabetised the way a German speaker would write it.
// Carried deliberately -- a Unicode case-folding table is a dependency and a
// size cost a notepad's sort does not earn. It has one property worth knowing
// though: comparing UTF-8 BYTEWISE is codepoint order, so non-ASCII lines still
// sort deterministically and sensibly WITHIN a script. What is missing is case
// pairing, not ordering.
@(private = "file")
sort_cmp_ci :: proc(a, b: []u8) -> int {
	n := min(len(a), len(b))
	for i in 0 ..< n {
		ca, cb := sort_lower(a[i]), sort_lower(b[i])
		if ca != cb {return -1 if ca < cb else 1}
	}
	if len(a) != len(b) {return -1 if len(a) < len(b) else 1}
	return 0
}

// Split [0,len(buf)) into lines and their terminators, producing exactly
// (newlines + 1) lines and (newlines) terminators — because the final line is
// appended unconditionally, whether or not it is empty.
//
// A previous version of this comment justified that by claiming `buf` never
// ends with a terminator. **That is false**, and the batch-10 whole-branch
// review caught it: when the region's last line is empty, `line_span_cap`
// returns `content_end == line_start`, so `hi` lands just past the preceding
// '\n' and `buf` does end with one. Worked example — `"b\na\n\n"` with no
// selection gives `lo=0, hi=4, buf="b\na\n"`. The count identity survives
// anyway (that trailing '\n' contributes a newline AND an empty final line),
// which is why nothing was broken; but the reason had to be right, because
// doc_sort_lines' line cap is written against it.
//
// `terms[i]` is the LENGTH of the terminator that followed input line i -- 2 for
// CRLF, 1 for LF. A 2 is always exactly "\r\n" by construction, which is what
// lets the join re-emit it from the length alone.
//
// Terminators are indexed by POSITION, not carried with their line, and that is
// the whole line-ending story here. doc_move_lines takes the same view ("only
// the two lines swap between them"), and it is stronger than re-emitting
// doc.eol: a CRLF file comes back CRLF and an LF file LF, but so does a region
// that disagrees with doc.eol -- which is reachable, because detect_line_ending
// only sniffs the head of the file (§6ab) while the region can be anywhere in
// it. Nothing is normalised, invented or discarded; the same terminator bytes
// come back in the same places.
@(private = "file")
sort_split_lines :: proc(buf: []u8, lines: ^[dynamic]Sort_Line, terms: ^[dynamic]u8) {
	start := 0
	for i := 0; i < len(buf); i += 1 {
		if buf[i] != '\n' {continue}
		end := i
		tl := 1
		if end > start && buf[end - 1] == '\r' {
			end -= 1
			tl = 2
		}
		append(lines, Sort_Line{text = buf[start:end], idx = len(lines)})
		append(terms, u8(tl))
		start = i + 1
	}
	append(lines, Sort_Line{text = buf[start:], idx = len(lines)})
}

// Sort, or dedupe, the selected lines expanded to whole lines at both ends --
// the whole document when there is no selection.
//
// Expanding is not optional: a selection almost never lands exactly on line
// boundaries, and sorting a partial first or last line corrupts it.
//
// Bookmarks: every bookmark INSIDE the region is dropped, every one outside is
// kept, and neither is coded here. The single write goes through
// doc_replace_range -> pt_edit_replace, whose one rule already says exactly
// that (bookmarks_shift_replace: `at <= b < at+n` is dropped; `b < at` is
// untouched; `b >= at+n` shifts). That is deliberate and it is the point of
// §6ad's one-seam collapse -- a sort reorders lines, so no shift can express
// where a bookmark went, and leaving one pointing at whatever line landed on
// its offset is the Alt+Down bug that shipped. `Reload from Disk` and
// doc_set_line_ending drop for the same reason.
//
// A bookmark exactly AT the region's far edge (b == hi) is DROPPED, and that is
// correct -- but not for the reason this comment used to give. It claimed the
// replacement ends in '\n' whenever hi is not the buffer end, which is backwards:
// the region stops at a line's CONTENT end, so the replacement ends with the
// last output line's CONTENT and ends in '\n' only when that line is empty.
// bookmarks_shift_replace's `b == at+n` rule therefore almost never keeps such a
// bookmark. Both directions verified: "a\n\n\n" with a bookmark at 3, ascending,
// drops it; "\nb\n\n" descending keeps it.
//
// It stays dropped because b == hi is only REACHABLE when the region's last line
// is empty -- anywhere else hi sits at a content end, and the byte after it is a
// terminator, so no bookmark (which is always a line start) can be there at all.
// So a bookmark at hi always names an empty line: there is no content for it to
// be silently re-pointed at, and losing it errs in the same direction as every
// other bookmark inside the region. Undo restores the whole set.
doc_sort_lines :: proc(doc: ^Document, mode: Sort_Mode) -> Sort_Result {
	if doc == nil || doc.kind != .Text || doc.pt.length == 0 {return .Unchanged}

	sel_lo, sel_hi := doc_sel_range(doc)
	if !doc_has_sel(doc) {sel_lo, sel_hi = 0, doc.pt.length}

	lo, lo_exact := base.pt_line_start_cap(&doc.pt, sel_lo, SORT_MAX_BYTES)
	if !lo_exact {return .Unresolved}

	// A range that ends exactly ON a line start does not include that line --
	// the convention every editor with this command uses, and here it is also
	// what stops "no selection" (sel_hi == pt.length) from feeding the trailing
	// empty line of a newline-terminated file into the sort, where it would
	// float to the top and turn "a\nb\n" into "\na\nb".
	end_pos := sel_hi
	if end_pos > lo && end_pos > 0 && byte_at(doc, end_pos - 1) == '\n' {end_pos -= 1}

	last_start, last_exact := base.pt_line_start_cap(&doc.pt, end_pos, SORT_MAX_BYTES)
	if !last_exact {return .Unresolved}
	// The region stops at the last line's CONTENT end, terminator excluded, so
	// the document's trailing terminator (or its absence) is never part of what
	// is rewritten. That is what makes "does this file end with a newline"
	// survive by construction rather than by an end-of-join special case -- the
	// bytes are simply never read and never written.
	hi, _, span_ok := line_span_cap(&doc.pt, last_start, SORT_MAX_BYTES)
	if !span_ok {return .Unresolved}
	if hi <= lo {return .Unchanged}
	if hi - lo > SORT_MAX_BYTES {return .Too_Big}

	buf := make([]u8, hi - lo)
	defer delete(buf)
	// A read out of a MAPPED original can fail: another process truncates the
	// file underneath us, the SEH shim catches the access violation, read_rec
	// (piecetable.odin) sets pt.fault and leaves the uncopied tail ZEROED. Every
	// other reader of a faulted region only DISPLAYS it for one frame; this one
	// would write it back as a real edit, splicing a run of NULs into the
	// document and marking it modified. main.odin's doc_fault_pending recovery
	// runs after the command and only detaches the mapping -- it cannot un-write
	// them, and the undo entry it would leave behind restores a tree read out of
	// the same broken mapping.
	//
	// Peeked, not taken: doc_fault_pending must still see the flag this frame and
	// recover. A short return from pt_read is checked too, because a truncation
	// that lands exactly on a piece boundary can end the copy without any
	// individual copy faulting.
	if base.pt_read(&doc.pt, lo, buf) != len(buf) || base.pt_faulted(&doc.pt) {return .Faulted}

	// The line cap, checked BEFORE the split rather than after it. The byte cap
	// is correctly ahead of its own allocation (the make above); this one was
	// not, and the constant's comment names the very cost it failed to bound --
	// "a Sort_Line per line ... is what costs there". 16 MiB of bare '\n' is 16
	// million Sort_Lines at 24 bytes each, plus the two dynamic arrays doubling
	// their way up to it: several hundred megabytes allocated, on the input
	// thread, only to be thrown away by a refusal one line later.
	//
	// sort_split_lines appends one line per '\n' plus one final line — appended
	// unconditionally, whether or not it is empty — so newlines+1 IS len(lines),
	// the same test rather than an approximation of it. (An earlier version of
	// this comment reached the same identity via "buf never ends with a
	// terminator", which is not true when the region's last line is empty; see
	// sort_split_lines. Right answer, wrong reason.) One pass over a buffer that
	// is already in cache is the whole price of knowing first.
	//
	// After the READ, though, and that part is unchanged: the byte cap already
	// bounds the read, and the line count is not knowable without it. Nothing has
	// been written either way, which is what makes both caps refusals rather than
	// partial edits.
	nl := 0
	for b in buf {if b == '\n' {nl += 1}}
	if nl + 1 > SORT_MAX_LINES {return .Too_Big}

	lines := make([dynamic]Sort_Line, 0, 64)
	defer delete(lines)
	terms := make([dynamic]u8, 0, 64)
	defer delete(terms)
	sort_split_lines(buf, &lines, &terms)
	if len(lines) < 2 {return .Unchanged}

	out_lines := lines[:]
	switch mode {
	case .Ascending:
		slice.sort_by(out_lines, sort_less_asc)
	case .Descending:
		slice.sort_by(out_lines, sort_less_desc)
	case .Dedupe:
		// Exact bytes, not the sort's case-insensitive key: `Foo` and `foo` are
		// different lines. Keep the FIRST occurrence and drop every later one
		// regardless of distance -- not uniq's adjacent-only collapse, which
		// silently leaves duplicates on unsorted input and reads as broken.
		seen := make(map[string]bool, 1 << 8)
		defer delete(seen)
		keep := 0
		for l in lines {
			s := string(l.text)
			if s in seen {continue}
			seen[s] = true
			lines[keep] = l
			keep += 1
		}
		out_lines = lines[:keep]
	}

	out := make([dynamic]u8, 0, len(buf))
	defer delete(out)
	for l, i in out_lines {
		append(&out, ..l.text)
		// Positional terminators (see sort_split_lines). len(out_lines) <=
		// len(lines) always, so terms[i] exists for every i < len(out_lines)-1.
		if i < len(out_lines) - 1 {
			if terms[i] == 2 {append(&out, '\r')}
			append(&out, '\n')
		}
	}

	// Nothing to write. Crucially this is checked BEFORE doc_batch_begin, whose
	// push_undo would otherwise mark the document modified and push an entry
	// that restores the state it is already in -- an undo step that does
	// nothing is worse than no undo step, and it evicts a real one from
	// UNDO_MAX. block_delete's own no-op guard exists for the same reason.
	if slice.equal(out[:], buf) {return .Unchanged}

	had_sel := doc_has_sel(doc)
	// The batch pair is CURRENTLY INERT, and kept anyway. Verified by deletion:
	// with a SINGLE doc_replace_range the entry count is 1 either way --
	// doc_batch_begin's push_undo takes the one snapshot and doc_replace_range's
	// own then returns early on doc.batch, so removing the pair just moves which
	// call takes it. doc_batch_end's state_count = max(1,1) equals push_undo's 1,
	// and both paths end at last_edit = .None. Deleting these two lines leaves
	// sortlinestest, bookmarktest, historytest, replacetest and blocktest all at
	// zero failures, and no test can be written that it would fail.
	//
	// What actually delivers the one-undo-entry property is the single write, and
	// that is what sl_undo asserts against (12 lines -> 1 entry; a per-line loop
	// reads 24). This pair is the guard the moment a second write appears beside
	// it, it costs nothing, and it is the documented idiom -- but it is not the
	// mechanism, and the plan was wrong to treat it as one.
	doc_batch_begin(doc, .Replace)
	doc_replace_range(doc, lo, hi - lo, out[:])
	doc_batch_end(doc, 1)

	// Keep the affected region selected when the user had a selection, so a
	// second command (sort, then dedupe) can follow without re-selecting;
	// collapse to the region start when they did not, because doc_replace_range
	// leaves the caret past the inserted text and the end of a just-sorted whole
	// document is nowhere the user asked to be. Either way the ORIGINAL offsets
	// are gone on purpose: the lines moved, so preserving the caret's byte offset
	// would put it in the middle of an unrelated line.
	if had_sel {
		doc.anchor, doc.cursor = lo, lo + len(out)
	} else {
		// `lo`, not 0 -- though with no selection lo IS always 0 (sel_lo is 0 and
		// the line start of 0 is 0), so no test can tell the two apart and saying
		// so here is worth more than a check that cannot fail. It is written as lo
		// because the statement is "collapse to the start of what was sorted"; if
		// the no-selection scope ever stops being the whole document, this line is
		// already right.
		doc.anchor, doc.cursor = lo, lo
	}
	doc.last_edit_at = doc.cursor
	return .Ok
}

// --- cursor movement (select=true extends the selection) ---

doc_cursor_left :: proc(doc: ^Document, select: bool) {
	if !select && doc_has_sel(doc) {
		lo, _ := doc_sel_range(doc)
		set_cursor(doc, lo, false) // collapse to selection start
		return
	}
	// A CRLF break is one caret step. Without this the caret lands between CR and
	// LF — the phantom cell at end of line, from the other side.
	p := doc.cursor
	if p >= 2 && base.pt_crlf_at(&doc.pt, p - 2) {
		set_cursor(doc, p - 2, select)
		return
	}
	set_cursor(doc, prev_rune(doc, p), select)
}

doc_cursor_right :: proc(doc: ^Document, select: bool) {
	if !select && doc_has_sel(doc) {
		_, hi := doc_sel_range(doc)
		set_cursor(doc, hi, false) // collapse to selection end
		return
	}
	p := doc.cursor
	if base.pt_crlf_at(&doc.pt, p) {
		set_cursor(doc, p + 2, select)
		return
	}
	set_cursor(doc, next_rune(doc, p), select)
}

enc_name :: proc(e: base.Encoding) -> string {return base.encoding_name(e)}

// 1-based line number of the caret, or 0 if it's beyond the scan cap (so the
// status bar never spends an unbounded scan on a huge file). Cached per cursor
// position, so it costs nothing when the caret isn't moving.
STATUS_LINE_CAP :: 4 * 1024 * 1024
doc_cursor_line :: proc(doc: ^Document) -> int {
	// Recompute on a cursor move, or on the first call (both fields start at 0).
	if doc.cursor != doc.status_cursor || (doc.status_line == 0 && doc.cursor <= STATUS_LINE_CAP) {
		doc.status_cursor = doc.cursor
		doc.status_line = 1 + count_newlines(doc, 0, doc.cursor) if doc.cursor <= STATUS_LINE_CAP else 0
	}
	return doc.status_line
}

// 1-based cell column of the caret within its line, or 0 when the line start is
// further back than the cap -- same contract as doc_cursor_line above, and the
// status bar omits whichever it cannot state.
//
// This ran unconditionally every frame and pt_line_start is an uncapped
// backward scan, so on a single-line file with the caret near the end it walked
// the whole document per frame: measured at 27.9 ms on 100 MB, i.e. a core
// pinned at ~35 fps for as long as the file is open. Cached on the caret
// position and the buffer length, so a still caret costs nothing.
STATUS_COL_CAP :: 1 * 1024 * 1024
doc_cursor_col :: proc(doc: ^Document, t: ^plat.Text) -> int {
	// The valid flag matters: a fresh Document is all zeroes, and so is a caret at
	// offset 0 in an empty buffer, which would otherwise return a cached 0.
	if doc.status_col_valid && doc.cursor == doc.status_col_cursor && doc.pt.length == doc.status_col_len {
		return doc.status_col
	}
	doc.status_col_valid = true
	doc.status_col_cursor = doc.cursor
	doc.status_col_len = doc.pt.length
	ls, exact := base.pt_line_start_cap(&doc.pt, doc.cursor, STATUS_COL_CAP)
	doc.status_col = line_cell_col(doc, t, ls, doc.cursor) + 1 if exact else 0
	return doc.status_col
}

// Scroll so the top of the view is the line start at fraction `frac` of the
// SCROLLABLE RANGE (0 = doc.top's minimum, 1 = doc_max_top) -- used by the
// draggable scrollbar, whose thumb travels the same range (vscrollbar_geo).
//
// This used to be a fraction of the raw buffer length, which was the exact
// mirror of the bug vscrollbar_geo had: it made the two consistent with each
// other (so a press-and-hold round trip landed back where it started) but
// both wrong against the track, since the true 1.0 point -- doc_max_top -- is
// short of pt.length by one screenful. Fixing only one side would have kept
// the round trip passing while making the drag land somewhere other than
// where the thumb visibly was.
//
// `+ 0.5` before truncating, matching hscrollbar_pos_at's rounding: a floor
// here is not a harmless rounding choice, it is a coin flip on which LINE you
// land on. vscrollbar_geo's forward map and this inverse recover the same
// frac up to f32 noise, and when that noise lands target a fraction of a byte
// under the real row start, `eff_row_start` reads it as the trailing '\n' of
// the PREVIOUS row and snaps a whole line short -- caught by scrollgrabtest's
// existing mid-document hold case once max_top (a smaller, differently-valued
// denominator than the old pt.length) shifted which side of the byte the
// truncation fell on.
doc_scroll_to_fraction :: proc(doc: ^Document, t: ^plat.Text, frac: f32, rows: int) {
	max_top := doc_max_top(doc, t, rows)
	target := int(clamp(frac, 0, 1) * f32(max_top) + 0.5)
	doc.top = min(eff_row_start(doc, t, target, doc.view_cols), max_top)
}

// Move the caret to the start of 1-based line `n` (O(n) line walk from the top).
doc_goto_line :: proc(doc: ^Document, n: int) {
	p := 0
	for _ in 1 ..< max(n, 1) {
		np := base.pt_next_line_start(&doc.pt, p)
		if np == p {break}
		p = np
	}
	doc.cursor = p
	doc.anchor = p
}

doc_cursor_home :: proc(doc: ^Document, select: bool) {set_cursor(doc, base.pt_line_start(&doc.pt, doc.cursor), select)}
// End lands on the row's content end, not on the CR of a CRLF break: the caret
// can never sit between CR and LF.
doc_cursor_end :: proc(doc: ^Document, select: bool) {
	e := base.pt_line_end(&doc.pt, doc.cursor)
	// max(0, e - 1), not the line start: pt_row_vis_end only inspects the two bytes
	// around `e`, and pt_line_start is an UNCAPPED backward scan. Passing the real
	// line start walked the whole document on every End press on a single-line
	// multi-GB file — the pattern pt_line_start_cap exists to prevent.
	set_cursor(doc, base.pt_row_vis_end(&doc.pt, max(0, e - 1), e, true), select)
}
// Ctrl+Home / Ctrl+End. Without these there is no keyboard way to reach the end
// of a large file at all.
doc_start :: proc(doc: ^Document, select: bool) {set_cursor(doc, 0, select)}
doc_end :: proc(doc: ^Document, select: bool) {set_cursor(doc, doc.pt.length, select)}

// Up/down move by VISUAL rows through the mixed layout, so they step wrapped
// sub-rows of a long line and whole short lines alike, keeping the caret's cell
// column. Bounded via the eff_* steppers.
doc_cursor_up :: proc(doc: ^Document, t: ^plat.Text, select: bool) {
	vs := eff_row_start(doc, t, doc.cursor, doc.view_cols)
	if vs == 0 {
		set_cursor(doc, 0, select) // already the first row: clamp to the start
		return
	}
	col := line_cell_col(doc, t, vs, doc.cursor)
	pv := eff_prev_row(doc, t, vs, doc.view_cols)
	pe := eff_row_end(doc, t, pv, doc.view_cols)
	set_cursor(doc, line_offset_at_cell(doc, t, pv, pe, col), select)
}

doc_cursor_down :: proc(doc: ^Document, t: ^plat.Text, select: bool) {
	vs := eff_row_start(doc, t, doc.cursor, doc.view_cols)
	e := eff_row_end(doc, t, vs, doc.view_cols)
	if e >= doc.pt.length { // already the last visual row
		set_cursor(doc, doc.pt.length, select) // clamp to the doc end, mirroring Up
		return
	}
	col := line_cell_col(doc, t, vs, doc.cursor)
	nv, more := eff_next_row(doc, t, vs, doc.view_cols)
	if !more {
		set_cursor(doc, doc.pt.length, select)
		return
	}
	ne := eff_row_end(doc, t, nv, doc.view_cols)
	set_cursor(doc, line_offset_at_cell(doc, t, nv, ne, col), select)
}

// --- word boundaries, word nav, click selection, hit-test ---

// Word boundaries live in base (three-class, direction-symmetric) so they are
// unit-testable; these are the document-level adapters.
@(private = "file")
word_left_of :: proc(doc: ^Document, pos: int) -> int {
	return base.pt_word_left(&doc.pt, pos)
}

@(private = "file")
word_right_of :: proc(doc: ^Document, pos: int) -> int {
	return base.pt_word_right(&doc.pt, pos)
}

doc_word_left :: proc(doc: ^Document, select: bool) {set_cursor(doc, word_left_of(doc, doc.cursor), select)}
doc_word_right :: proc(doc: ^Document, select: bool) {set_cursor(doc, word_right_of(doc, doc.cursor), select)}

doc_delete_word_back :: proc(doc: ^Document) {
	if doc_has_sel(doc) {
		doc_backspace(doc)
		return
	}
	p := word_left_of(doc, doc.cursor)
	if p == doc.cursor {return}
	push_undo(doc, .Delete)
	doc.nl_delta -= count_newlines(doc, p, doc.cursor - p)
	pt_edit_delete(doc, p, doc.cursor - p)
	set_cursor(doc, p, false)
	doc.last_edit_at = doc.cursor
}

doc_select_all :: proc(doc: ^Document) {
	doc.anchor = 0
	doc.cursor = doc.pt.length
	// Bypasses set_cursor, so a live rectangle must be dropped explicitly --
	// otherwise Ctrl+A leaves a stale block describing a rectangle that no
	// longer relates to the (now whole-document) selection.
	if block_active(doc) {block_clear(doc)}
}

doc_select_word_at :: proc(doc: ^Document, pos: int) {
	L := doc.pt.length
	if pos < L && base.char_class(byte_at(doc, pos)) == .Word {
		s, e := pos, pos
		for s > 0 && base.char_class(byte_at(doc, s - 1)) == .Word {s -= 1}
		for e < L && base.char_class(byte_at(doc, e)) == .Word {e += 1}
		doc.anchor, doc.cursor = s, e
	} else if base.pt_crlf_at(&doc.pt, pos) {
		// pos is the CR that begins a CRLF break -- doc_pos_at clamps a click past
		// EOL here, so this is the ordinary "double-click past end of line" case,
		// not a deliberate click on the break. The pair isn't selectable content:
		// selecting the CR (the else branch below) leaves cursor == vis_end + 1,
		// which no row's [start, vis_end] claims, so the caret vanishes until the
		// next keypress and typing then replaces the CR, corrupting the line
		// ending. Land the caret at the content end instead, with no selection.
		doc.anchor = pos
		doc.cursor = pos
	} else {
		doc.anchor = pos
		doc.cursor = next_rune(doc, pos)
	}
	// Bypasses set_cursor -- a double-click word-select must drop a stale
	// rectangle the same way a plain caret move does.
	if block_active(doc) {block_clear(doc)}
}

doc_select_line_at :: proc(doc: ^Document, pos: int) {
	doc.anchor = base.pt_line_start(&doc.pt, pos)
	doc.cursor = base.pt_next_line_start(&doc.pt, pos) // include the newline
	// Bypasses set_cursor -- a triple-click line-select must drop a stale
	// rectangle the same way a plain caret move does.
	if block_active(doc) {block_clear(doc)}
}

// Cell column of byte offset `off` measured from line start `ls` (off >= ls),
// via the text layer's per-codepoint cell widths. Bounded to the drawn extent.
line_cell_col :: proc(doc: ^Document, t: ^plat.Text, ls, off: int) -> int {
	if off <= ls {return 0}
	buf: [VISIBLE_COLS * 4]u8 // <=4 bytes per cell, <=VISIBLE_COLS cells
	n := min(off - ls, len(buf))
	got := base.pt_read(&doc.pt, ls, buf[:n])
	// col0 = 0 by this proc's own contract: the answer is defined as the column
	// measured FROM `ls`, so `ls` is the origin. Choosing what `ls` means -- a
	// logical line start or a visual row start -- is the caller's job, and the
	// callers inside the draw loop pass the visual row start so that this and
	// wrap_row_end agree.
	return plat.text_cells(t, buf[:got], 0, .Doc)
}

// Inverse: byte offset within line [ls, le] at cell column `col` (rune-rounded).
// Not file-private: this and line_cell_col are a seam — the drawn column and the
// hit-tested column — and CLAUDE.md's rule is to test the seam, not the unit, so
// hscrolltest round-trips the pair on a tabbed line. With tabs the two are no
// longer inverses by construction the way they were when a cell was a byte.
line_offset_at_cell :: proc(doc: ^Document, t: ^plat.Text, ls, le, col: int) -> int {
	buf: [VISIBLE_COLS * 4]u8
	n := min(le - ls, len(buf))
	got := base.pt_read(&doc.pt, ls, buf[:n])
	// col0 = 0, matching line_cell_col above exactly -- these two are inverses
	// and a different origin in either would break the round-trip on any line
	// containing a tab.
	return min(ls + plat.text_bytes_for_cells(t, buf[:got], col, 0, .Doc), le)
}

// Byte offset under a client-space pixel (cell-grid column mapping). The column
// is resolved with the target row's own offset — a wrapped row ignores the pan,
// so a click on it maps by its own cells, not the panned ones.
doc_pos_at :: proc(doc: ^Document, t: ^plat.Text, mx, my: i32, px, char_w: f32, rows: int) -> int {
	target := clamp(row_at_y(px, f32(my)), 0, rows - 1)
	it := visible_begin(doc, t, rows)
	last_start, last_vis_end, last_wrap := doc.top, doc.top, false
	for {
		row, start, _, vis_end, _, wrapped, ok := visible_next(&it)
		if !ok {break}
		last_start, last_vis_end, last_wrap = start, vis_end, wrapped
		if row == target {
			col := col_at_x(char_w, f32(mx), 0 if wrapped else H_SCROLL)
			return line_offset_at_cell(doc, t, start, vis_end, col)
		}
	}
	col := col_at_x(char_w, f32(mx), 0 if last_wrap else H_SCROLL)
	return line_offset_at_cell(doc, t, last_start, last_vis_end, col) // click below last row
}

// Selection highlight rectangles for the visible lines (opaque; drawn behind
// text). Fills `out`, returns the count.
doc_selection_rects :: proc(doc: ^Document, t: ^plat.Text, px, char_w: f32, rows: int, out: []plat.Quad) -> int {
	lo, hi := doc_sel_range(doc)
	if lo == hi {return 0}
	col := g_theme[.Selection_Doc]
	lh := line_height(px)
	it := visible_begin(doc, t, rows)
	n := 0
	for n < len(out) {
		row, start, end, vis_end, _, wrapped, ok := visible_next(&it)
		if !ok {break}
		if lo <= end && hi > start { // selection overlaps [start, end]
			rhs := 0 if wrapped else H_SCROLL
			startcol := min(line_cell_col(doc, t, start, max(start, lo)), VISIBLE_COLS)
			endcol := min(line_cell_col(doc, t, start, min(vis_end, hi)), VISIBLE_COLS)
			sx := col_x(char_w, startcol, rhs)
			ex := col_x(char_w, endcol, rhs)
			if hi > vis_end {ex += char_w * 0.4} // continues past EOL: hint the newline
			out[n] = {pos = {sx, row_rect_y(px, row)}, size = {max(ex - sx, 2), lh}, color = col}
			n += 1
		}
	}
	return n
}

// Bookmark mark geometry, in the LEFT MARGIN. Two numbers, used only here.
//
// The margin and not the gutter, deliberately: GUTTER_W is nonzero only in the
// filter view (doc_update_gutter), so there is no gutter to draw in while
// editing, and turning one on for every document is Wyatt's toggle and belongs
// to the batching work -- not a side effect of adding bookmarks. Nothing here
// adds a second width: TEXT_MARGIN_X and GUTTER_W both keep their single
// definitions, and the mark sits entirely to the LEFT of col_x(char_w, 0), so
// it cannot overlap the filter view's line numbers when a gutter IS present.
BOOKMARK_MARK_X_96 :: f32(3)
BOOKMARK_MARK_W_96 :: f32(4)

// One quad per visible row whose LINE START is bookmarked, produced from the
// same visible_begin/visible_next walk the draw and the selection use -- so a
// mark can only appear on a row the document actually drew, and a wrapped
// line's continuation rows (whose `start` is not the logical line start) are
// excluded by construction rather than by a second rule.
//
// Works in the filter view too: there `start` is filter_lines[i], which is
// already a line start, so a bookmarked line that survives the filter is marked
// with no extra case.
doc_bookmark_rects :: proc(doc: ^Document, t: ^plat.Text, px: f32, rows: int, out: []plat.Quad) -> int {
	if doc == nil || len(doc.bookmarks) == 0 {return 0}
	col := g_theme[.Bookmark]
	lh := line_height(px)
	x, w := sx(BOOKMARK_MARK_X_96), sx(BOOKMARK_MARK_W_96)
	it := visible_begin(doc, t, rows)
	n := 0
	for n < len(out) {
		row, start, _, _, _, _, ok := visible_next(&it)
		if !ok {break}
		if _, found := bookmark_find(doc, start); !found {continue}
		out[n] = {pos = {x, row_rect_y(px, row)}, size = {w, lh}, color = col}
		n += 1
	}
	return n
}

// --- viewport ---

// Non-wrap row stepping, capped to RENDER_LINE_CAP exactly like the renderer
// (visible_next / doc_draw). A line longer than the cap is treated as successive
// capped rows — which is already how doc_draw shows it — so scrolling and drawing
// agree on where the rows fall. For any normal line (< cap) these are identical
// to base.pt_line_start / pt_next_line_start / pt_prev_line_start.
//
// This is the fix for the multi-GB single-line freeze: doc_scroll, doc_max_top,
// doc_ensure_cursor_visible and doc_scroll_to_fraction called the UNCAPPED
// base.pt_* scans (O(line length), ~350 ms/GB) on the UI thread on every wheel
// tick / page / scrollbar drag, so a long-line file locked the whole app on any
// interaction. These bound each step to one cap's worth of bytes.
@(private = "file")
row_start_capped :: proc(doc: ^Document, pos: int) -> int {
	s, _ := base.pt_line_start_cap(&doc.pt, pos, RENDER_LINE_CAP)
	return s
}

// Start of the row after the one beginning at `pos`. `ok` is false when that row
// was the last one.
//
// The two facts this used to conflate: "the next row starts at length" is true
// when the buffer ends with a newline, where that final empty row exists and
// must render; "there is no next row" is true when the last line runs to EOF
// with no newline to step past. Returning length for both emitted a phantom row
// at [length, length] on every buffer without a trailing newline — which is
// every scratch buffer — and the caret, matching it, was drawn on it.
@(private = "file")
next_row_start_capped :: proc(doc: ^Document, pos: int) -> (start: int, ok: bool) {
	e := base.pt_line_end_cap(&doc.pt, pos, RENDER_LINE_CAP)
	if e >= doc.pt.length {return doc.pt.length, false}
	// A real newline is stepped past; a synthetic cap boundary starts at e.
	if byte_at(doc, e) == '\n' {return e + 1, true}
	return e, true
}

@(private = "file")
prev_row_start_capped :: proc(doc: ^Document, pos: int) -> int {
	if pos <= 0 {return 0}
	s, _ := base.pt_line_start_cap(&doc.pt, pos - 1, RENDER_LINE_CAP)
	return s
}

// The largest doc.top that still fills the viewport (keeps the last line at the
// bottom row); 0 if the whole document fits. Bounds scrolling to real content.
doc_max_top :: proc(doc: ^Document, t: ^plat.Text, rows: int) -> int {
	p := eff_row_start(doc, t, doc.pt.length, doc.view_cols)
	for _ in 0 ..< max(rows - 1, 0) {
		if p == 0 {break}
		p = eff_prev_row(doc, t, p, doc.view_cols)
	}
	return p
}

// A few cells of slack past the longest line's end, so the last character isn't
// jammed against the right edge — but only a few, not a screen of blank.
HSCROLL_PAD :: 3

// Largest horizontal scroll (cells) that still shows content: the widest
// currently-visible line, plus a little slack, minus the viewport width. Scoped
// to the visible rows, never the whole file, so it costs about what a frame's
// draw does. 0 while wrapping/filtering (no horizontal scroll there).
//
// Takes `rows` (doc_visible_rows), not the partial-row-inclusive `drawn`
// (doc_drawn_rows): if the partial last row happens to hold the widest line
// on screen, its tail is one h-scroll step out of reach. That is a real, small
// inconsistency, not a hazard, and it is not needed for agreement with the
// bar's other two readers (hscroll_model at main.odin:561 and :1446) -- both
// just read whatever this returns, so they would still agree with each other
// if this scanned `drawn` instead. The reason to leave it on `rows` is only
// that the sliver is not worth the extra row's scan.
//
// Capped at VISIBLE_COLS because that is all doc_draw renders of a line — without
// the cap the bar ran far past the drawn text into blank space on a long line
// (a minified JSON, a long log/CSV row), since the width was measured up to the
// scan cap while only VISIBLE_COLS cells are ever drawn. (Panning the tail of a
// line longer than VISIBLE_COLS needs the draw to window on h_scroll — a separate
// follow-up; this just makes the bar stop where the text does.)
//
// The widest line SEEN SO FAR since the mark was last dropped (see
// max_cells_rev), not the widest currently on screen. This used to walk only
// the visible rows and derive `reach` from that scan alone, so scrolling the
// wide line off the top collapsed the range and the bar vanished -- Wyatt,
// live use: the horizontal scrollbar only allows expanding if the large row
// is on screen. Viewport-first still holds: nothing here scans off-screen
// content, the measurement just stops throwing itself away once something
// wider has actually been looked at.
//
// Chosen over a background full-document scan (Wyatt, 2026-07-28) because it
// needs no job, no invalidation and no rule bent. The accepted cost: on first
// open the range is only as wide as what has been looked at, so it grows as the
// user scrolls rather than being right from frame one.
//
// MUTATING: raises max_cells_seen, and first drops it if an edit has moved
// doc.revision since it was last measured (2026-07-29 fix -- see the field
// comment). Call exactly once per frame, from the frame's UPDATE phase in
// main.odin -- never from render_frame. Not safe to call from a job, and not
// idempotent with respect to the struct. doc_max_hscroll (below) is the pure
// read that render_frame and everything else should use instead; splitting
// the two is what makes the draw idempotent again.
doc_update_max_hscroll :: proc(doc: ^Document, t: ^plat.Text, rows: int) -> int {
	if doc == nil || doc_wraps(doc) || doc.filter {return 0}
	if doc.max_cells_rev != doc.revision {
		// An edit happened since this was last measured. It may have SHRUNK
		// the content (deleted the line that set the mark), so the mark
		// cannot simply be trusted forward -- drop it and let the scan below
		// re-grow it from whatever is on screen right now. A mere scroll
		// never reaches this branch, because a scroll never bumps revision.
		doc.max_cells_seen = 0
		doc.max_cells_rev = doc.revision
	}
	widest := 0
	it := visible_begin(doc, t, rows)
	for {
		_, start, _, vis_end, _, wrapped, ok := visible_next(&it)
		if !ok {break}
		if wrapped {continue} // wrapped rows fit the window; they don't pan
		if w := line_cell_col(doc, t, start, vis_end); w > widest {widest = w}
	}
	if widest > doc.max_cells_seen {doc.max_cells_seen = widest}
	return doc_max_hscroll(doc)
}

// Pure read of the range doc_update_max_hscroll last computed: no scan, no
// mutation. Safe to call from render_frame (hscroll_model) or anywhere else
// that only wants the number for this frame, since the update above already
// ran once before the draw.
doc_max_hscroll :: proc(doc: ^Document) -> int {
	if doc == nil || doc_wraps(doc) || doc.filter {return 0}
	reach := min(doc.max_cells_seen + HSCROLL_PAD, VISIBLE_COLS)
	return max(0, reach - max(1, doc.view_cols))
}

// Scroll the viewport by `delta` visual rows (up when negative), clamped so the
// last line can't scroll above the bottom row.
doc_scroll :: proc(doc: ^Document, t: ^plat.Text, delta, rows: int) {
	if delta > 0 {
		for _ in 0 ..< delta {
			nt, more := eff_next_row(doc, t, doc.top, doc.view_cols)
			if !more || nt == doc.top {break}
			doc.top = nt
		}
	} else if delta < 0 {
		for _ in 0 ..< -delta {
			if doc.top == 0 {break}
			doc.top = eff_prev_row(doc, t, doc.top, doc.view_cols)
		}
	}
	doc.top = min(doc.top, doc_max_top(doc, t, rows))
}

// Keep the caret on screen: scroll so its visual row is within [top, top+drawn).
//
// `drawn` (doc_drawn_rows), not `rows` (doc_visible_rows), decides whether the
// caret already counts as on screen: doc_pos_at hit-tests against `drawn`
// too, since a half-visible last row is clickable. Judging the same row
// "below the viewport" here scrolled the file out from under a click or drag
// landing on that row -- one line per click, one line per drag frame. `rows`
// still decides WHERE to land after an actual scroll (below): the caret is
// parked on the last WHOLLY visible row, not the partial one, so the very
// next move down doesn't have to scroll again immediately.
doc_ensure_cursor_visible :: proc(doc: ^Document, t: ^plat.Text, rows, drawn: int) {
	// Horizontal follow first (plain view only; wrap/filter have no h-scroll):
	// keep the caret's column inside [h_scroll, h_scroll+view_cols) so typing or
	// arrowing off the right edge pans instead of hiding the caret.
	//
	// Only when the caret's real line start is found within the cap. On a line
	// longer than RENDER_LINE_CAP the capped scan stops at a synthetic offset one
	// cap back, so the column measured from it was ~8000 -- and a mere click flung
	// h_scroll to the far right. A line that long is rendered as capped segments
	// anyway (its column relative to the logical start is not what the draw uses),
	// so leaving h_scroll put is the right behaviour, not a compromise.
	// Skip it when the caret sits on a wrapped line (its rows fit the window, so
	// h_scroll never hides it) or a too-long line (start past the cap) — leaving
	// h_scroll put for whatever non-wrapped lines are being panned.
	if !doc_wraps(doc) && !doc.filter {
		if lstart, exact := base.pt_line_start_cap(&doc.pt, doc.cursor, RENDER_LINE_CAP); exact && !line_wrap_decision(doc, t, lstart) {
			ccol := line_cell_col(doc, t, lstart, doc.cursor)
			vc := max(1, doc.view_cols)
			if ccol < doc.h_scroll {
				doc.h_scroll = ccol
			} else if ccol >= doc.h_scroll + vc {
				doc.h_scroll = ccol - vc + 1
			}
		}
	}
	cls := eff_row_start(doc, t, doc.cursor, doc.view_cols)
	if cls < doc.top {
		doc.top = cls
		return
	}
	// walk `drawn` visual rows from top; if we pass the caret's row, it's on
	// screen (see doc_pos_at, which hit-tests the same budget)
	p := doc.top
	for _ in 0 ..< drawn {
		if p >= cls {return}
		np, more := eff_next_row(doc, t, p, doc.view_cols)
		if !more {break}
		p = np
	}
	// caret is below the viewport: put its row at the bottom of the WHOLLY
	// visible rows (rows, not drawn) -- landing it on the partial row would
	// leave the very next down-move needing to scroll again right away
	doc.top = cls
	doc_scroll(doc, t, -(rows - 1), rows)
}

// Per-viewport-pass state for the wrapped side of syntax highlighting.
// Mirrors links_layout's cur_lls/cur_line/cur_links cache exactly — a wrapped
// row is only a segment of its logical line, but the log lexer's line-start
// timestamp pattern is anchored to the true line start, and any token can
// straddle the wrap point, so the whole (capped) logical line is lexed once
// and its spans rebased onto each visual row in turn, rather than re-lexing
// a partial, possibly-truncated segment per row. The zero value IS a usable
// empty cache — cur_whole false means "holds nothing," so the first row of a
// pass always misses. (It used to need cur_lls seeded to -1, a value no real
// line start can equal; cur_whole subsumes that sentinel.)
//
// cur_state_out is the Lex_State the WHOLE cached logical line ends in —
// computed once, the same call that fills cur_buf — and handed back
// unchanged on every visual row of that line, wrapped or not. Only the row
// that actually starts a new logical line needs a fresh, caller-supplied
// state_in; every other visual row of an already-wrapped line reuses the
// cached tokens and the cached state_out, both fixed once the line is lexed.
//
// cur_whole is what makes that claim conditional rather than assumed: the
// cache can only speak for a whole logical line when doc_row_lex_extent said
// so (its comment has the two ways that fails). When it is false the cache
// holds nothing and every row of that line lexes its own extent instead —
// see doc_row_lex_spans.
//
// cur_line_buf is the cached line's bytes, a fixed array rather than a
// per-row make(): the whole point of the cache is that a wrapped row costs
// nothing extra, and RENDER_LINE_CAP bounds the read by construction (a line
// that doesn't fit in it is exactly the cur_whole=false case). Its live
// length is cur_len, kept as an int rather than a string field so the struct
// never holds a pointer into itself.
Highlight_Row_Cache :: struct {
	cur_lls:       int,
	cur_line_buf:  [RENDER_LINE_CAP]u8,
	cur_len:       int,
	cur_buf:       [HL_MAX_ROW_TOKENS]plat.Text_Span,
	cur_n:         int,
	cur_whole:     bool,
	cur_state_out: base.Lex_State,
}

// The byte range a row's syntax spans are lexed from, and whether that range
// is the row's WHOLE logical line (so the result is cacheable and shared by
// every visual row of it) or just this row's own extent.
//
// ONE decision, two consumers — doc_row_lex_spans and doc_draw's first-row
// state bootstrap — because they must agree about where `state_in` belongs.
// The bootstrap resolves the state at `from`; doc_row_lex_spans begins lexing
// at `from`. Split across two sites they diverged: the bootstrap resolved at
// a line start the row loop then didn't lex from.
//
// A wrapped row uses its whole logical line UNLESS either bound fails, and
// both failures have the same shape — a bounded scan that cannot see far
// enough must not pretend it did:
//
// (There is a THIRD bound on this path that this proc does not decide and
// does not guard: cur_buf holds HL_MAX_ROW_TOKENS spans, a budget sized for
// a ROW, while the whole-line path fills it from a LINE of up to
// RENDER_LINE_CAP bytes. A line dense enough to saturate it colours its
// first rows and leaves the rest bare. state_out stays correct — every lexer
// keeps scanning for state after its token slice fills — so this is a visual
// limit, not a state bug, and it is recorded in HANDOFF §5 rather than fixed
// here: the naive `saturated -> whole_line = false` is WRONG, because the
// fall-through would then lex [start,end) with a state_in that was resolved
// at lls.)
//
//   - pt_line_start_cap reports exact=false: no newline within WRAP_START_CAP
//     behind `start`, so what came back is a scan FLOOR that slides with
//     `start`, not a line start. Applying `state_in` (the state at the
//     PREVIOUS logical line's end) there is a confident wrong answer, and
//     since the floor moves with every visual row it also defeats the cache
//     it feeds — every row past 8 KiB into the line would re-read and re-lex.
//   - pt_line_end_cap hit its cap: the line is longer than RENDER_LINE_CAP,
//     so a read from `lls` cannot reach its end and the state it produces is
//     the state at a truncated read's end, not at the line's end — which is
//     what the cache hands out as "what this WHOLE line ends in."
//
// Falling back to the row's own extent is correct for the caller's state
// threading because successive visual rows of one logical line are a
// contiguous byte stream: visible_next sets the next row's `pos` to exactly
// this row's `end` at a wrap point (doc.odin's wrap branch; "a wrap point
// belongs to the next visual row's start"), so row-to-row threading of the
// state at `end` is the same thing the !wrapped path already relies on.
//
// The `exact` guard below cannot be sabotage-tested on its own, and that is a
// consequence of the two caps being equal rather than of the guard being
// pointless: when exact is false the floor is exactly start - WRAP_START_CAP,
// so pt_line_end_cap can only reach `start` and the truncation guard fires
// instead. Drop WRAP_START_CAP below RENDER_LINE_CAP and that stops holding —
// the end scan would run PAST `start`, could find a real newline, and would
// return whole_line=true on a floor that is not a line start, with no test to
// catch it. Hence the assert: it is what keeps the untested guard redundant.
#assert(WRAP_START_CAP >= RENDER_LINE_CAP)
doc_row_lex_extent :: proc(doc: ^Document, start, end: int, wrapped: bool) -> (from, to: int, whole_line: bool) {
	if wrapped {
		lls, exact := base.pt_line_start_cap(&doc.pt, start, WRAP_START_CAP)
		if exact {
			lend := base.pt_line_end_cap(&doc.pt, lls, RENDER_LINE_CAP)
			// pt_line_end_cap returns min(length, lls+cap) when it finds no
			// newline, so "stopped short of the cap, or ran out of document"
			// is exactly "this is a real line end." A line of precisely
			// RENDER_LINE_CAP bytes is indistinguishable from a truncated one
			// here and is treated as truncated: conservative, and it only
			// costs that one line the shared cache.
			if lend < lls + RENDER_LINE_CAP || lend >= doc.pt.length {
				return lls, lend, true
			}
		}
	}
	return start, min(end, start + RENDER_LINE_CAP), false
}

// Row-relative syntax spans for one visible row, handling the wrap rebase
// when needed. Factored out of doc_draw so highlighttest (test_modes.odin)
// can exercise the exact wrap-rebase path doc_draw draws with, rather than a
// second implementation that could quietly diverge from it — "test the
// seam, not the unit" (CLAUDE.md).
//
// Filter rows are never `wrapped` (visible_next only ever sets it in the
// non-filter branch), so a filtered row's bytes ARE its whole logical line
// already — this line-local lexer handles the filter view for free FOR A
// LINE-LOCAL LEXER. A stateful lexer's filter row still needs its OWN
// state_in resolved independently (the row above it in the filter view can
// be an unrelated logical line 10,000 lines away) — that resolution is the
// caller's job (doc_lex_state_at, program/lex_index.odin), not this proc's;
// this proc only threads whatever state_in it is given through to the lexer
// and reports what it ends in.
//
// `state_in` is the Lex_State in effect at doc_row_lex_extent's `from` for
// this row — its logical line's start on the whole-line path, this row's own
// `start` otherwise. doc_draw's bootstrap resolves it through that same proc,
// so the two cannot disagree about which one it is.
//
// `state_out` follows the same split. On the whole-line path it is what the
// WHOLE logical line ends in — identical across every visual row of that
// line, so the caller can hold it and only advance once `line_end` is
// reached (doc_draw does exactly this). On the row-extent path it is what
// THIS ROW's bytes end in, which is what the next visual row starts in:
// successive rows of one logical line are contiguous (see
// doc_row_lex_extent), so threading it forward row to row is correct, and is
// what the !wrapped path has always done.
doc_row_lex_spans :: proc(
	doc: ^Document,
	cache: ^Highlight_Row_Cache,
	start, end: int,
	wrapped: bool,
	row_bytes: []u8,
	state_in: base.Lex_State,
	out: []plat.Text_Span,
) -> (n: int, state_out: base.Lex_State) {
	if wrapped {
		// The cache serves any row whose bytes lie inside the logical line it
		// already holds — checked directly against that line's extent rather
		// than by re-deriving `lls` per row, so the common case (every visual
		// row after the first of a wrapped line) costs nothing but this
		// comparison.
		if !(cache.cur_whole && start >= cache.cur_lls && end <= cache.cur_lls + cache.cur_len) {
			from, to, whole := doc_row_lex_extent(doc, start, end, true)
			cache.cur_lls = from
			cache.cur_len = 0
			cache.cur_n = 0
			cache.cur_whole = whole
			cache.cur_state_out = state_in // nothing to lex: state passes through
			if whole && to > from {
				// `to - from` is bounded by RENDER_LINE_CAP by construction
				// (doc_row_lex_extent only returns whole_line when the line
				// end came back inside that cap); the min mirrors the
				// !wrapped path's own read below rather than trusting that
				// invariant from a distance.
				cache.cur_len = base.pt_read(&doc.pt, from, cache.cur_line_buf[:min(to - from, len(cache.cur_line_buf))])
				cache.cur_n, cache.cur_state_out = highlight_row_spans(
					doc,
					cache.cur_line_buf[:cache.cur_len],
					state_in,
					cache.cur_buf[:],
				)
			}
		}
		if cache.cur_whole {
			row_off := start - cache.cur_lls
			row_end_off := min(end - cache.cur_lls, cache.cur_len)
			n = 0
			for k in 0 ..< cache.cur_n {
				sp := cache.cur_buf[k]
				lo := max(sp.start, row_off)
				hi := min(sp.start + sp.len, row_end_off)
				if lo >= hi {continue} // this token doesn't touch this row
				if n >= len(out) {break}
				// Rebased onto this row: "a wrapped link only colours its part here"
				// (links.odin) applies identically to a syntax span.
				out[n] = plat.Text_Span{start = lo - row_off, len = hi - lo, color = sp.color}
				n += 1
			}
			state_out = cache.cur_state_out
			return
		}
		// Not a whole line we can speak for (doc_row_lex_extent said so): this
		// row lexes its OWN extent, exactly like the !wrapped path below, and
		// reports the state at the end of THAT extent. Falls through.
	}
	{
		// `row_bytes` is whatever the caller already read for DRAWING —
		// doc_draw's line_buf is VISIBLE_COLS (2048) wide, but this row's real
		// extent (`end`) can be up to RENDER_LINE_CAP (8192, 4x more): a long
		// unwrapped line only shows its first 2048 bytes on screen but is still
		// one row for lexing purposes. Trusting the caller's buffer here used to
		// mean a `<!--` past byte 2048 was invisible to the lexer, so state_out
		// silently reported the wrong thing — and every following row inherits
		// it, since state threads row to row. So: re-read the row's OWN full
		// extent directly (bounded to RENDER_LINE_CAP, same cap `end` already
		// respects), lex THAT for spans/state, and let text_draw_spans's own
		// tolerance for spans past the drawn string (platform/text.odin: the
		// rune loop simply never reaches them) discard whatever falls outside
		// what's actually shown. `full` is a fixed stack array, not a heap
		// allocation — the per-row path stays allocation-free; this only adds
		// a second bounded pt_read, not a second per-row alloc.
		if end <= start {return highlight_row_spans(doc, row_bytes, state_in, out)}
		full: [RENDER_LINE_CAP]u8
		got := base.pt_read(&doc.pt, start, full[:min(end - start, len(full))])
		return highlight_row_spans(doc, full[:got], state_in, out)
	}
}

// Draw visible lines; return the caret's screen rect (if visible) and the byte
// offset just past the last visible line (for the scrollbar).
doc_draw :: proc(
	gfx: ^plat.Gfx,
	t: ^plat.Text,
	doc: ^Document,
	px, char_w: f32,
	rows: int,
	links: []Link_Hit = nil,
) -> (
	cx, cy: f32,
	caret: bool,
	bottom: int,
) {
	fg := g_theme[.Text_Primary]
	// A line longer than the cap renders as successive capped rows and columns
	// past VISIBLE_COLS aren't drawn (crude long-line handling; proper horizontal
	// scroll is a follow-up).
	line_buf: [VISIBLE_COLS]u8
	// Span buffers for the row being drawn: syntax spans (highlight.odin) and
	// colour-rule spans (rules.odin). Declared HERE rather than inside the row
	// loop: Odin zero-initialises a declared array, so a per-row declaration is
	// a 16 KB memset for hl_buf plus an 8 KB one for rules_buf EVERY row -- 960
	// KB a frame on a 40-row viewport, spent to clear buffers that are written
	// before they are read. Each row consumes only the [:hl_n] / [:rules_n]
	// prefix its own producer just wrote that row (doc_row_lex_spans and
	// rules_row_spans both report what they wrote, and neither reads what was
	// there before), so one buffer for the whole pass is equivalent and free.
	// The counts stay per row; only the storage is shared.
	hl_buf: [HL_MAX_ROW_TOKENS]plat.Text_Span
	rules_buf: [RULES_MAX_ROW_SPANS]plat.Text_Span
	bottom = doc.top
	// Syntax highlighting: nil lexer for an extension with no grammar (.txt,
	// or anything not yet wired in highlight.odin) skips the whole pass below
	// at zero cost. hl_cache's zero value is an empty cache (see its comment),
	// so the first wrapped row this pass sees always misses and lexes its
	// logical line fresh.
	hl_lexer, _, _, _ := highlight_lexer_for(doc.path)
	hl_cache: Highlight_Row_Cache
	// The Lex_State carried into the row about to be drawn. In the filter
	// view every row is a non-contiguous logical line (row N+1 can be 10,000
	// lines below row N), so each one resolves its own state independently
	// below. Outside the filter view the viewport is one contiguous stream:
	// bytes flow from one row straight into the next regardless of whether a
	// row boundary happens to be a wrap point, a RENDER_LINE_CAP split, or a
	// genuine new logical line, so a single running state threaded forward
	// row to row is correct throughout — only the FIRST row needs an actual
	// lookup (hl_state_ready gates that), because it may be lexing a
	// document byte range whose preceding state is otherwise unknown.
	hl_state: base.Lex_State
	hl_state_ready := false
	it := visible_begin(doc, t, rows)
	for {
		row, start, end, vis_end, line_end, wrapped, ok := visible_next(&it)
		if !ok {break}
		bottom = end
		row_y := row_baseline_y(px, row)
		rhs := 0 if wrapped else H_SCROLL // a wrapped row ignores the horizontal pan

		draw_len := min(vis_end - start, len(line_buf))
		n := base.pt_read(&doc.pt, start, line_buf[:draw_len])
		// An EMPTY row skips this whole block, syntax highlighting included, so
		// hl_state does not advance across a blank line — while the background
		// index (lex_index_worker, lex_index.odin) lexes every line including
		// the empty ones. The two only agree because a blank line is
		// state-preserving in all five stateful grammars: lex_xml and lex_c
		// carry an open comment through it untouched, and lex_markdown and
		// lex_yaml each handle "blank line inside my construct" explicitly
		// (a fenced block, a block scalar), as does lex_shell's <# #>. One
		// exception, unreachable today: lex_yaml drops .In_Comment on a bare
		// "\r", which only matters if a YAML block scalar could open on a CRLF
		// line, and ym_match_block_scalar rejects `|\r` so it cannot. That is a
		// pre-existing CRLF gap in the grammar, not in this guard. A sixth
		// stateful lexer whose state a blank line can CHANGE — an
		// indentation-sensitive grammar where a blank line closes a block,
		// say — breaks that agreement here rather than in itself, and would
		// need this guard restructured so the lexer still sees the row.
		if n > 0 {
			// Line number, when the filter view is showing lines out of context.
			if GUTTER_W > 0 {
				fi := doc.filter_top + row
				if fi < len(doc.filter_line_nos) {
					num := fmt.tprintf("%d", doc.filter_line_nos[fi])
					// Right-aligned against the gutter's text edge.
					nx := TEXT_MARGIN_X + GUTTER_W - f32(len(num) + 1) * char_w
					plat.text_draw(gfx, t, num, nx, row_y, px, g_theme[.Text_Muted])
				}
			}
			// Links on this row, if Ctrl is held. Colour comes from the same
			// Link_Hit list the hover and the click consume, so what is highlighted
			// is exactly what is clickable. The underlines are drawn by
			// render_frame, which owns the quad pipeline — from this same list.
			link_spans: [dynamic]plat.Text_Span
			for h in links {
				if h.row != row {continue}
				link_spans = link_spans if link_spans != nil else make([dynamic]plat.Text_Span, 0, 4, context.temp_allocator)
				// The row-relative segment (a wrapped link only colours its part here).
				append(&link_spans, plat.Text_Span{start = h.span_start, len = h.span_len, color = g_theme[.Link]})
			}

			// Syntax spans on this row (nil hl_lexer -> zero cost). A URL inside a
			// log line can be both a link and a lexer span on the same bytes, and
			// text_draw_spans has no defined behaviour for overlapping input (see
			// its own doc comment in platform/text.odin) — so the drop-then-merge
			// precedence that resolves this lives in highlight_merge_spans
			// (highlight.odin), not inlined here, so highlighttest can exercise
			// the exact proc this draws with rather than a duplicate that could
			// quietly diverge from it.
			hl_n := 0 // hl_buf is hoisted above the loop -- see its comment there
			if hl_lexer != nil {
				if doc_filtering(doc) {
					// Non-contiguous row: can't inherit state from the row
					// above (see hl_state's comment), so resolve it here,
					// bounded by the smaller filter-view window.
					hl_state = doc_lex_state_at(doc, start, LEX_FILTER_RESYNC_WINDOW)
				} else if !hl_state_ready {
					// Contiguous viewport: only the very first row needs a
					// real lookup, and it must be resolved at exactly the
					// offset doc_row_lex_spans is about to start lexing from —
					// which is doc_row_lex_extent's `from`, the SAME proc
					// doc_row_lex_spans asks. Two sites deciding this
					// separately is how they came apart before:
					//
					// - Wrapped whole-line rows: the top row may be a wrap
					//   CONTINUATION, not its logical line's true start, and
					//   doc_row_lex_spans re-lexes the whole cached line from
					//   that true start, so state_in must be resolved there
					//   too or the whole-line lex begins from the wrong state.
					// - Row-extent rows (never wrapped, or wrapped but past
					//   one of doc_row_lex_extent's two bounds): the row lexes
					//   its OWN [start,end) extent, so state must be resolved
					//   at `start`. Resolving at pt_line_start_cap's
					//   WRAP_START_CAP-bounded guess instead — which for a
					//   line longer than that cap lands neither at the true
					//   line start nor at `start`, but partway between — meant
					//   the bytes in between were never lexed at all.
					//
					// Resolving directly AT a mid-logical-line offset is fine:
					// lex_resync_state's forward walk is chunk-relative to
					// wherever it finds the anchor, not dependent on `target`
					// being a real line start (see its comment).
					from, _, _ := doc_row_lex_extent(doc, start, end, wrapped)
					hl_state = doc_lex_state_at(doc, from, LEX_RESYNC_WINDOW)
					hl_state_ready = true
				}
				hl_n, hl_state = doc_row_lex_spans(doc, &hl_cache, start, end, wrapped, line_buf[:n], hl_state, hl_buf[:])
			}

			// Colour rules (rules.odin) are the THIRD span producer and the
			// lowest-priority one: links > lexer > rules, fixed here and
			// nowhere else. They are independent of hl_lexer on purpose —
			// their whole audience is the .txt and .log files that have no
			// lexer at all — so this sits outside the `hl_lexer != nil` block
			// above. rules_active() is a length check, so a machine with no
			// rules.txt pays one compare per row for the feature.
			rules_n := 0
			if rules_active() {
				rules_n = rules_row_spans(line_buf[:n], rules_buf[:])
			}

			spans: []plat.Text_Span
			if hl_n > 0 || rules_n > 0 || link_spans != nil {
				merged := make([]plat.Text_Span, hl_n + len(link_spans) + rules_n, context.temp_allocator)
				spans = merged[:highlight_merge_row(link_spans[:], hl_buf[:hl_n], rules_buf[:rules_n], merged)]
			}
			if spans != nil {
				plat.text_draw_spans(gfx, t, string(line_buf[:n]), col_x(char_w, 0, rhs), row_y, px, fg, spans, .Doc)
			} else {
				plat.text_draw(gfx, t, string(line_buf[:n]), col_x(char_w, 0, rhs), row_y, px, fg, .Doc)
			}
		}

		// Caret on this row: [start, vis_end], but a wrap point (non-line-end
		// vis_end) belongs to the next visual row's start, so exclude it here.
		if doc.cursor >= start && doc.cursor <= vis_end && (line_end || doc.cursor < vis_end) {
			cprefix := min(doc.cursor - start, n) // cells before caret, clipped to drawn text
			// col0 = 0: line_buf was read from `start`, the visual row start,
			// and the glyphs above were drawn from col_x(char_w, 0, rhs) with
			// the same buffer -- so the caret is measured in exactly the space
			// the text was drawn in. This is the draw/caret seam; the two must
			// keep the same origin or the caret drifts along a tabbed line.
			cx = col_x(char_w, plat.text_cells(t, line_buf[:cprefix], 0, .Doc), rhs)
			cy = row_y
			caret = true
		}
	}
	return
}
