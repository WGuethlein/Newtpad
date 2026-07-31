// Layer: program -- the per-document view mode as one value, plus the one place
// that decides whether a stored view is legal for the document it is landing on.
//
// Two callers restore a view onto a Document they did not create: session_restore
// (from session.txt) and doc_reload (across a rebuild). Both used to carry `wrap`
// open-coded and drop md_mode/table on the floor, which is why a restored .md
// always came back plain and an external-change reload silently reset the view.
// Giving them one procedure is the same move block_row_range and doc_row_lex_extent
// made: if the drawn view and the restored view can disagree, eventually they do.
package main

import base "src:base"

Doc_View :: struct {
	wrap:        bool,
	md_mode:     Md_Mode,
	table:       bool,
	table_delim: u8, // 0 = never chosen; doc_view_apply picks one
}

doc_view_capture :: proc(doc: ^Document) -> Doc_View {
	return Doc_View {
		wrap = doc.wrap,
		md_mode = doc.md_mode,
		table = doc.table,
		table_delim = doc.table_delim,
	}
}

// Put `v` onto `doc`, keeping only what this document can actually hold.
//
// Both views are cleared BEFORE either gate is asked, deliberately: doc_can_markdown
// and doc_can_table both short-circuit true when the document is already in that
// view ("already in it keeps it toggleable, so a file can never get stuck"), so
// asking them without clearing first would let any stored value validate itself.
doc_view_apply :: proc(doc: ^Document, v: Doc_View) {
	doc.wrap = v.wrap
	doc.md_mode = .Off
	doc.table = false

	if doc.kind == .Text && v.md_mode != .Off && doc_can_markdown(doc) {
		doc.md_mode = v.md_mode
	}
	// A markdown view and the grid are mutually exclusive: md_mode == .Split
	// force-wraps and the table guard in command_dispatch blocks every mutating
	// command, so a document in both is a document in an undefined state. The
	// markdown view is resolved first and the grid yields to it.
	if doc.kind == .Text && v.table && doc.md_mode == .Off && doc_can_table(doc) {
		doc.table = true
		// A grid with table_delim == 0 falls back to ',' in table_compute_widths
		// but nothing ever RECORDS a choice, so a .tsv restored this way would
		// draw one enormous column. Re-choosing costs one bounded line read and
		// is why the delimiter is not persisted in session.txt.
		doc.table_delim = v.table_delim if v.table_delim != 0 else table_choose_delim(doc)
		doc.table_col = 0
		// Left empty on purpose: table_draw recomputes when the widths are empty
		// (table.odin:183), so this needs no ^plat.Text and can run from
		// session_restore and doc_reload, neither of which has one.
		clear(&doc.table_widths)
		// ...and the manual widths with them. A restored session re-samples the
		// file from scratch, and a width the user dragged in a previous run would
		// be applied to whatever column happens to sit at that index now.
		table_user_widths_clear(doc)
	}
	// Both markdown views and the grid scroll by whole lines, so a top that
	// landed mid-line would render a partial first row. The toggles re-anchor
	// for the same reason.
	if doc.md_mode != .Off || doc.table {
		doc.top = base.pt_line_start(&doc.pt, doc.top)
	}
}
