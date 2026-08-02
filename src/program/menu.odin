// Layer: program — the menu bar: a row below the tab strip holding File / Edit /
// View and a right-aligned settings gear, matching Windows 11 Notepad's chrome
// (which also has no Format or Help menu — Word Wrap lives in View).
//
// It is a discoverability surface, not a second command system: every item names
// a Command_Id and dispatches through command_dispatch, so behaviour lives in one
// place and the shortcut shown beside each item is read from the keymap.
//
// The command palette (Ctrl+P) is unchanged and remains the fast path; every
// shipped editor with a palette also keeps a menu.
package main

import "core:fmt"
import "core:unicode/utf8"
import plat "src:platform"

MENU_BAR_H_96 :: f32(30) // UI spec 2.1 (was 26)
MENU_ITEM_H_96 :: f32(28) // dropdown row height, UI spec 2.2 (was 24)
MENU_PAD_96 :: f32(12) // horizontal padding around a top-level title
// Tallest a GENERATED dropdown gets, in rows. Twelve is about a third of a 1080p
// window: small enough that a list of two hundred column values reads as a list
// you scroll rather than as a panel that swallowed the screen.
//
// It does NOT apply to the hand-written menus. Edit is fourteen rows' worth and
// would be clipped by this, and it needs no cap anyway -- a person typed every row
// of it, so it cannot run away. Only the window-height clamp applies there, as it
// always did. See menu_dropdown_rect.
MENU_MAX_ROWS :: f32(12)
// Width of the dropdown's scrollbar, drawn only when there is something to
// scroll. Thin: it is an indicator that there is more, not a control -- the wheel
// and the arrow keys are how you move, exactly as in the document.
MENU_SCROLLBAR_W_96 :: f32(4)
GEAR_W_96 :: f32(34) // settings gear hit box (wider than the glyph, so it's clickable)
MENU_BAR_H := MENU_BAR_H_96
MENU_ITEM_H := MENU_ITEM_H_96
MENU_PAD := MENU_PAD_96

// An item is either a command row or a separator (cmd == .None).
Menu_Item :: struct {
	cmd:     Command_Id,
	// Non-nil only for toggles; draws a check mark. Takes the app because state
	// lives on the active document, which may be nil.
	// Takes the ITEM as well as the app, so a row can answer about itself. Every
	// bar toggle ignores it; the column filter's value rows are the reason it
	// exists -- each is one distinct value and the tick has to come from `payload`,
	// not from anything reachable via the app alone.
	checked: proc(app: ^App, it: Menu_Item) -> bool,
	// Non-nil when the item can be unavailable. Greyed out and unclickable —
	// several commands silently no-op (Copy with no selection, Undo with no
	// history), and a menu that offers them anyway is lying about what it does.
	enabled: proc(app: ^App) -> bool,
	// Which of a generated row set this row is. Zero and unread on every hand-
	// written menu; the column filter builds its rows at runtime, one per distinct
	// value, and this is how a row says which value it is to both the tick and the
	// command.
	payload: int,
	// A row that is TEXT AND NOTHING ELSE: cmd stays .None, so it is un-pickable and
	// un-highlightable through the machinery that already makes separators both --
	// item_enabled refuses .None, menu_item_at returns -1 for it, menu_step walks
	// past it. Only the height and the draw need to know it is a label rather than a
	// rule.
	//
	// The filter's search box is the only user, and this is why it is a synthetic
	// ITEM rather than a band above the rows: a band would need its own height
	// threaded through menu_dropdown_rect, the draw, the hit-test, rows_fitting,
	// menu_wheel and menu_scroll_to_item, and six consumers of one coordinate is the
	// exact shape of every seam bug in this file. As an item it costs nothing --
	// scrolling, clipping and hit-testing already handle it, correctly, today.
	//
	// The string must outlive the frame (menu_open_ctx's rule); the search row's
	// points into App-owned Menu_State.query.
	text:    string,
}

Menu :: struct {
	title:    string,
	mnemonic: rune, // Alt+this opens the menu
	items:    []Menu_Item,
}

@(private = "file")
has_doc :: proc(app: ^App) -> bool {return app_active(app) != nil}

// Reload needs a file on disk to reload from; an untitled buffer has none.
@(private = "file")
has_file :: proc(app: ^App) -> bool {
	d := app_active(app)
	return d != nil && d.path != ""
}

@(private = "file")
has_sel :: proc(app: ^App) -> bool {
	d := app_active(app)
	return d != nil && doc_has_sel(d)
}

@(private = "file")
can_undo :: proc(app: ^App) -> bool {
	d := app_active(app)
	return d != nil && len(d.undo) > 0
}

@(private = "file")
can_redo :: proc(app: ^App) -> bool {
	d := app_active(app)
	return d != nil && len(d.redo) > 0
}

@(private = "file")
is_wrapped :: proc(app: ^App, _: Menu_Item) -> bool {
	d := app_active(app)
	return d != nil && d.wrap
}

@(private = "file")
is_filtered :: proc(app: ^App, _: Menu_Item) -> bool {
	d := app_active(app)
	return d != nil && d.filter
}

@(private = "file")
is_table :: proc(app: ^App, _: Menu_Item) -> bool {
	d := app_active(app)
	return d != nil && d.table
}

@(private = "file")
is_md_view :: proc(app: ^App, _: Menu_Item) -> bool {
	d := app_active(app)
	return d != nil && d.md_mode != .Off
}

// Grey the toggles out on a file whose type doesn't fit the view (a new/untitled
// buffer always fits — see doc_can_*).
@(private = "file")
can_table :: proc(app: ^App) -> bool {return doc_can_table(app_active(app))}
@(private = "file")
can_md_view :: proc(app: ^App) -> bool {return doc_can_markdown(app_active(app))}
@(private = "file")
can_json :: proc(app: ^App) -> bool {return doc_can_json(app_active(app))}

@(private = "file")
is_regex :: proc(app: ^App, _: Menu_Item) -> bool {
	d := app_active(app)
	return d != nil && d.find.regex
}

// The encoding rows are the first menu items whose check mark tracks a VALUE
// rather than a bool, so each gets its own predicate rather than one proc with
// a parameter -- Menu_Item.checked takes only the app.
@(private = "file")
is_enc_utf8 :: proc(app: ^App, _: Menu_Item) -> bool {d := app_active(app);return d != nil && d.enc == .UTF8}
@(private = "file")
is_enc_utf16le :: proc(app: ^App, _: Menu_Item) -> bool {d := app_active(app);return d != nil && d.enc == .UTF16LE}
@(private = "file")
is_enc_cp1252 :: proc(app: ^App, _: Menu_Item) -> bool {d := app_active(app);return d != nil && d.enc == .CP1252}
@(private = "file")
is_eol_lf :: proc(app: ^App, _: Menu_Item) -> bool {d := app_active(app);return d != nil && d.eol == .LF}
@(private = "file")
is_eol_crlf :: proc(app: ^App, _: Menu_Item) -> bool {d := app_active(app);return d != nil && d.eol == .CRLF}

// The header context menu's predicates. All of them read the target column off
// app.menu.ctx_col rather than taking a parameter -- Menu_Item.enabled takes
// only the app -- which is why this menu's rows are checked against a context
// column and the bar's never are.
//
// Every one of them has to agree with command_dispatch's own `doc != nil &&
// doc.table` guard on the six commands, or a row paints live and no-ops: the
// divergence between what is drawn and what runs that Menu_Item.enabled exists
// to prevent. table_sorted already carries the doc.table term itself (table.odin
// documents why), so has_live_sort and can_then_by inherit the agreement;
// in_table_view is what the two plain Sort rows and is_sort_key_col need,
// because table_sort_key answers about the key vector alone and would say yes
// on a document that has left the grid with keys still set.
@(private = "file")
in_table_view :: proc(app: ^App) -> bool {d := app_active(app);return d != nil && d.table}

@(private = "file")
has_live_sort :: proc(app: ^App) -> bool {return table_sorted(app_active(app))}

@(private = "file")
is_sort_key_col :: proc(app: ^App) -> bool {
	if !in_table_view(app) {return false}
	_, ok := table_sort_key(app_active(app), app.menu.ctx_col)
	return ok
}

// "Then by" needs a sort to add a tie-breaker TO, and then either this column
// is already one of its keys (in which case table_sort_add flips its direction
// in place, per its own comment) or there is still room to append a new one.
@(private = "file")
can_then_by :: proc(app: ^App) -> bool {
	d := app_active(app)
	if !table_sorted(d) {return false}
	if _, ok := table_sort_key(d, app.menu.ctx_col); ok {return true}
	return table_sort_can_add(d, app.menu.ctx_col)
}

@(private = "file")
has_live_filter :: proc(app: ^App) -> bool {return table_filtered(app_active(app))}

// --- the column filter's generated dropdown --------------------------------
//
// One row per distinct value, each a checkbox, plus (Select All) -- Excel and
// PowerBI, which is what Wyatt asked for. It reuses the CONTEXT MENU wholesale:
// the same draw, hit-test, scroll, keyboard and edge clamp the header menu and the
// tab menu already go through. That is what `Menu_Item.payload` bought -- a
// generated row set instead of a second widget with its own scrolling list, its
// own hit-test and its own bugs.
//
// The rows are built into an App-owned buffer, NOT the frame's temp allocator:
// menu_open_ctx stores the slice and a menu by definition survives into the next
// frame's draw, so a temp-built slice would dangle at the first free_all. Its own
// comment says exactly this and it is the trap this generator would have walked
// straight into.
menu_filter_items :: proc(app: ^App) -> []Menu_Item {
	d := app_active(app)
	clear(&app.filter_items)
	if d == nil {return app.filter_items[:]}
	f := &d.table_filter
	q := string(app.menu.query[:app.menu.query_len])
	// The search box first, then (Select All), then the values. *"there should also
	// be a search bar of sorts in this menu of the column choices... it's annoying
	// to scroll to find the one you need"* (Wyatt, v0.49.0). It is the first row
	// because a search box below the thing it searches reads as a footer.
	//
	// (Select All) is NOT filtered out by the query and stays above the values, so
	// "type three letters, Select All" means all of THE MATCHES -- which is the
	// operation the search exists to make possible. table_filter_apply reads the
	// ticks, not the rows, so this is a property of the row set alone.
	label := "Type to search…"
	if q != "" {label = fmt.bprintf(app.menu.query_label[:], "Search: %s_", q)}
	append(&app.filter_items, Menu_Item{text = label})
	append(&app.filter_items, Menu_Item{cmd = .Table_Filter_All, checked = filter_all_on})
	append(&app.filter_items, sep)
	for v, i in f.values {
		// THE PAYLOAD IS THE TRUE VALUE INDEX, not the row's position, so a search
		// that hides rows cannot make a click tick the wrong value. That separation
		// is the whole reason the filter survives being typed into.
		if q != "" && !menu_contains_fold(v, q) {continue}
		append(&app.filter_items, Menu_Item{cmd = .Table_Filter_Toggle, checked = filter_value_on, payload = i})
	}
	return app.filter_items[:]
}

// Is `q` in `s`, ignoring ASCII case? Hand-rolled and ASCII-only on purpose: a
// full Unicode case fold is a table this layer has no business carrying, and the
// values being searched are the column's own text, where matching `active`
// against `ACTIVE` is the whole of what anyone wants.
@(private = "file")
menu_contains_fold :: proc(s, q: string) -> bool {
	if len(q) > len(s) {return false}
	lower :: proc(b: u8) -> u8 {return b + 32 if b >= 'A' && b <= 'Z' else b}
	for i in 0 ..= len(s) - len(q) {
		ok := true
		for j in 0 ..< len(q) {
			if lower(s[i + j]) != lower(q[j]) {ok = false;break}
		}
		if ok {return true}
	}
	return false
}

// Feed one typed character to the filter dropdown's search box. Returns true when
// it was taken, so the caller stops looking for another consumer.
//
// Only while the dropdown carrying the FILTER's rows is open -- typing over a bar
// menu still means whatever it meant before, and a document keystroke must never
// be swallowed by a menu that happens to be up.
menu_filter_query_rune :: proc(app: ^App, r: rune) -> bool {
	if !menu_dropdown_active(app) || !menu_is_filter_dropdown(app) {return false}
	if r < 32 || r == 127 {return false} // control characters are not a query
	b, n := utf8.encode_rune(r)
	if app.menu.query_len + n > len(app.menu.query) {return true} // full: swallow, don't wrap
	copy(app.menu.query[app.menu.query_len:], b[:n])
	app.menu.query_len += n
	menu_filter_requery(app)
	return true
}

// Backspace in the search box. Same contract as above.
menu_filter_query_back :: proc(app: ^App) -> bool {
	if !menu_dropdown_active(app) || !menu_is_filter_dropdown(app) {return false}
	if app.menu.query_len == 0 {return false} // nothing to delete: let Backspace mean what it means
	p := app.menu.query_len - 1
	for p > 0 && (app.menu.query[p] & 0xC0) == 0x80 {p -= 1}
	app.menu.query_len = p
	menu_filter_requery(app)
	return true
}

// Rebuild the visible rows and put the highlight somewhere real. The row set just
// changed under `menu.item`, and an index into the old list points at a different
// value -- or past the end -- in the new one.
@(private = "file")
menu_filter_requery :: proc(app: ^App) {
	items := menu_filter_items(app)
	app.menu.ctx_items = items
	app.menu.top = 0
	app.menu.item = -1
	for it, i in items {
		if item_enabled(app, it) {
			app.menu.item = i
			break
		}
	}
}

// Is the open dropdown the column filter's? The query only applies to that one,
// and asking by CONTENT rather than by a flag means a dropdown cannot claim to be
// the filter's while holding somebody else's rows.
menu_is_filter_dropdown :: proc(app: ^App) -> bool {
	if !app.menu.ctx {return false}
	for it in app.menu.ctx_items {
		if it.cmd == .Table_Filter_All || it.cmd == .Table_Filter_Toggle {return true}
	}
	return false
}

// Every value ticked? The (Select All) row's own state, and what makes it a
// three-way control rather than a button: ticked means "everything is showing",
// and clicking it when it is ticked hides everything instead.
@(private = "file")
filter_all_on :: proc(app: ^App, _: Menu_Item) -> bool {
	d := app_active(app)
	if d == nil {return false}
	for on in d.table_filter.on {if !on {return false}}
	return len(d.table_filter.on) > 0
}

@(private = "file")
filter_value_on :: proc(app: ^App, it: Menu_Item) -> bool {
	d := app_active(app)
	if d == nil {return false}
	f := &d.table_filter
	return it.payload >= 0 && it.payload < len(f.on) && f.on[it.payload]
}

// A filter row's LABEL is the value it stands for, not the command's title. The
// draw asks this for every row and gets "" for an ordinary one, which is what
// keeps the generated rows inside the same draw rather than beside it.
menu_item_label :: proc(app: ^App, it: Menu_Item) -> string {
	if it.cmd != .Table_Filter_Toggle {return ""}
	d := app_active(app)
	if d == nil {return ""}
	f := &d.table_filter
	if it.payload < 0 || it.payload >= len(f.values) {return ""}
	v := f.values[it.payload]
	// An EMPTY cell needs a name, or its row is a checkbox with nothing beside it
	// and no way to tell what it would hide. The grid draws an em dash for the same
	// reason (TABLE_EMPTY_CELL).
	return "(blank)" if v == "" else v
}

@(private = "file")
sep :: Menu_Item{}

menus := []Menu {
	{
		"File",
		'f',
		[]Menu_Item {
			{cmd = .Tab_New},
			{cmd = .Tab_Open},
			sep,
			// Both are dead on the Settings and Font pseudo-tabs, but not from
			// here: `enabled` says only "there is a document". The kind rule is
			// command_allowed_on (commands.odin), consulted by item_enabled below
			// AND by command_dispatch, because the palette reaches a command
			// without ever looking at a menu row.
			{cmd = .Save, enabled = has_doc},
			{cmd = .Save_As, enabled = has_doc},
			{cmd = .Reload, enabled = has_file},
			sep,
			// Tab_Close must stay live on a pseudo-tab, and this is why the rule
			// is per-command rather than "nothing runs on a Settings tab": closing
			// one is the only thing on this menu that means anything there.
			//
			// Ctrl+W does NOT do it, which an earlier version of this comment
			// claimed as the reason the row could safely go dead. The binding is
			// {.W, true, false, .Editor, .Tab_Close} (commands.odin) -- Editor
			// context -- and on a pseudo-tab main.odin sets ctx to .Settings or
			// .Font, from which resolve_key falls back to .Editor for nothing but
			// Find, Menu and History. What actually closes a pseudo-tab is Escape
			// (Settings_Close / Font_Close, both request_close_tab), the tab
			// strip's X, and this row.
			{cmd = .Tab_Close, enabled = has_doc},
			{cmd = .Exit},
		},
	},
	{
		"Edit",
		'e',
		[]Menu_Item {
			{cmd = .Undo, enabled = can_undo},
			{cmd = .Redo, enabled = can_redo},
			{cmd = .History_Open, enabled = has_doc},
			sep,
			{cmd = .Cut, enabled = has_sel},
			{cmd = .Copy, enabled = has_sel},
			// Dead on a pseudo-tab for the same reason File > Save is, and by the
			// same shared predicate: a paste there inserted the clipboard into a
			// document nothing draws and left it .modified, so the tab-strip X or
			// File > Close Tab then asked whether to save a page with no file.
			// Cut and Copy carry no kind predicate of their own -- command_mutates_doc
			// covers Cut, and Copy off a pseudo-document is a no-op reading an
			// empty buffer.
			{cmd = .Paste, enabled = has_doc},
			sep,
			// Live on a pseudo-tab, and the precondition for that being harmless is
			// worth writing down because nothing else states it: app_open_special
			// (app.odin) builds the Settings and Font documents from a bare
			// doc_new() with no content and nothing ever writes to them, so
			// doc_select_all leaves anchor == cursor == 0 and there is no selection
			// for Cut or Copy to act on.
			//
			// That held by luck until a palette paste could put text in the
			// pseudo-buffer -- select it, and Cut went live and mutated. Cut is now
			// refused outright there by command_allowed_on (via command_mutates_doc),
			// so the invariant no longer rests on the buffer happening to be empty;
			// this row is merely a no-op rather than a harmless-for-now one.
			{cmd = .Select_All, enabled = has_doc},
			sep,
			{cmd = .Find_Open, enabled = has_doc},
			{cmd = .Replace_Open, enabled = has_doc},
			{cmd = .Find_Replace_All, enabled = has_doc},
			{cmd = .Goto_Line, enabled = has_doc},
			sep,
			// Live on any text document, not just a .json: the request was
			// illustrated with a .log file, and an extension gate excluded it. See
			// doc_can_json. Pressing it on something that is not JSON says so and
			// puts the caret on the first byte that is not.
			{cmd = .Format_Document, enabled = can_json},
			sep,
			{cmd = .Font_Open},
		},
	},
	{
		"View",
		'v',
		[]Menu_Item {
			{cmd = .Toggle_Wrap, checked = is_wrapped, enabled = has_doc},
			{cmd = .Toggle_Table, checked = is_table, enabled = can_table},
			{cmd = .Toggle_Preview, checked = is_md_view, enabled = can_md_view},
			sep,
			{cmd = .Filter_Open, checked = is_filtered, enabled = has_doc},
			{cmd = .Find_Toggle_Regex, checked = is_regex, enabled = has_doc},
			sep,
			{cmd = .Zoom_In},
			{cmd = .Zoom_Out},
			{cmd = .Zoom_Reset},
			sep,
			// Split from the four below. UI spec 6: five groups, "nothing longer
			// than four rows" -- this was one run of six mixing two different
			// kinds of thing. Opening the palette or Settings is something you do
			// while working; editing the theme, the keymap or the colour rules is
			// customisation, and the log folder belongs with those because it is
			// where you go when one of them misbehaves.
			{cmd = .Palette_Open},
			{cmd = .Settings_Open},
			sep,
			{cmd = .Theme_Edit},
			{cmd = .Keys_Edit},
			{cmd = .Rules_Edit},
			// Beside Theme_Edit rather than at the end: someone who has just edited
			// a theme is the person who needs to know where theme files live, and
			// this row is the only thing in the app that says.
			{cmd = .Open_Themes_Folder},
			{cmd = .Open_Logs_Folder},
		},
	},
	{
		"Encoding",
		'n',
		[]Menu_Item {
			{cmd = .Reopen_UTF8, enabled = has_file},
			{cmd = .Reopen_UTF16LE, enabled = has_file},
			{cmd = .Reopen_CP1252, enabled = has_file},
			sep,
			// Same shape again: these set doc.modified (Enc_*) or rewrite the whole
			// buffer (Eol_*), and both are refused on a pseudo-tab by
			// command_allowed_on, not by anything in this table.
			{cmd = .Enc_UTF8, checked = is_enc_utf8, enabled = has_doc},
			{cmd = .Enc_UTF16LE, checked = is_enc_utf16le, enabled = has_doc},
			{cmd = .Enc_CP1252, checked = is_enc_cp1252, enabled = has_doc},
			sep,
			{cmd = .Eol_LF, checked = is_eol_lf, enabled = has_doc},
			{cmd = .Eol_CRLF, checked = is_eol_crlf, enabled = has_doc},
		},
	},
	{
		// The header above notes that Windows 11 Notepad has no Help menu. It also
		// does not ship outside the Store, so it has nothing to check for. A
		// standalone exe a stranger downloaded needs one reachable place to ask
		// whether it is current, and burying the product's only network command in
		// View would be worse than a short menu.
		//
		// No `enabled` predicate: this is the one row that means the same thing on
		// a Settings or Font pseudo-tab as it does on a document.
		"Help",
		'h',
		[]Menu_Item{{cmd = .Check_For_Updates}},
	},
}

// The table header's context menu: its contents only. Nothing here opens it --
// the gesture that does must go through menu_open_ctx, which is the only writer
// of ctx_col and therefore the only thing that can aim these rows at a column.
// menu_open_ctx is the OTHER caller of the dropdown machinery `menus` above
// feeds, and its own
// comment explains why this has to be a package-level slice rather than
// something built per-open: a menu survives into the frame after the one that
// opened it, and main.odin's free_all(context.temp_allocator) runs once every
// frame, so a temp-allocated table would dangle by the time the next draw or
// hit-test read it.
//
// Six rows, three pairs, matching table.odin's Table_Sort operations one for
// one: table_sort_set (replace with a single key) for the first two,
// table_sort_add (compose a tie-breaker, or flip an existing key's direction
// in place) for "Then by", table_sort_drop for "Remove", table_sort_clear for
// "Clear". Nothing here writes doc.table_sort itself -- every row calls one of
// those four, which is the only thing allowed to.
table_header_menu_items := []Menu_Item {
	{cmd = .Table_Sort_Asc, enabled = in_table_view},
	{cmd = .Table_Sort_Desc, enabled = in_table_view},
	sep,
	{cmd = .Table_Sort_Then_Asc, enabled = can_then_by},
	{cmd = .Table_Sort_Then_Desc, enabled = can_then_by},
	{cmd = .Table_Sort_Remove, enabled = is_sort_key_col},
	sep,
	{cmd = .Table_Sort_Clear, enabled = has_live_sort},
	sep,
	{cmd = .Table_Filter_Open, enabled = in_table_view},
	{cmd = .Table_Filter_Clear, enabled = has_live_filter},
	sep,
	// Not a sort row, which is why it is behind its own separator. It is here
	// rather than in a top-level menu because it is a property of THIS TABLE and
	// this menu is already the per-table surface; a View-menu entry would be a
	// document-wide-looking control for a per-document answer.
	//
	// Checkable rather than a pair of rows: it is one yes/no about one file, and
	// the tick says which way it is currently answered -- including when the answer
	// came from the heuristic and the user has said nothing, which is the state
	// they most need to be able to see and disagree with.
	{cmd = .Table_First_Row_Is_Data, enabled = in_table_view, checked = first_row_is_data},
}

// Is line 0 currently being treated as data? Reads the RESOLVED flag, not the
// mode, so the tick reflects what is on screen whether the answer came from the
// user, from the family default or from table_detect_headerless.
@(private = "file")
first_row_is_data :: proc(app: ^App, _: Menu_Item) -> bool {
	d := app_active(app)
	return d != nil && d.table && d.table_headerless
}

// --- the tab strip's context menu ------------------------------------------
//
// Requested by a user, relayed by Wyatt: *"if you could right click the tabs to
// open the folder it's located in."* The action already existed --
// `plat.shell_reveal` is what a non-text link resolves to -- and the surface did
// not: there was no right-click on the strip at all.
//
// FOUR ROWS, DECIDED ONCE. `requested-features.md` warned that a tab menu invites
// every other per-tab command (close others, close to the right, copy path, pin)
// and that principle 3 says fight options, so the contents were settled with
// Wyatt before it was built rather than grown a row at a time. Reveal answers the
// request; Copy Path is the other thing anyone actually wants from a tab; the two
// closes are what every editor's tab menu has. Pin and Close to the Right were
// considered and left out -- pin is real state with its own ordering rules, not
// another row.
//
// The two file rows are GREYED with a reason on a tab that has no file on disk,
// rather than hidden: a menu that changes shape per tab defeats muscle memory,
// and the disabled-reason column already exists for exactly this (it is what the
// table's sort menu uses to explain a dead row).
@(private = "file")
tab_has_path :: proc(app: ^App) -> bool {
	d := menu_ctx_tab_doc(app)
	return d != nil && d.path != ""
}

// More than one tab open? Close Others is dead on a single tab -- there are no
// others -- and saying so is better than a row that appears to do nothing.
@(private = "file")
tab_has_others :: proc(app: ^App) -> bool {
	return app != nil && app_live_count(app) > 1
}

// The document the tab menu targets, or nil. One producer, so the enabled
// predicates, the disabled reasons and the four commands cannot disagree about
// which tab is being acted on.
menu_ctx_tab_doc :: proc(app: ^App) -> ^Document {
	if app == nil {return nil}
	s := app.menu.ctx_tab
	if s < 0 || s >= len(app.docs) {return nil}
	return app.docs[s]
}

tab_menu_items := []Menu_Item {
	{cmd = .Tab_Reveal, enabled = tab_has_path},
	{cmd = .Tab_Copy_Path, enabled = tab_has_path},
	sep,
	{cmd = .Tab_Close_This},
	{cmd = .Tab_Close_Others, enabled = tab_has_others},
}

// Menu bar / dropdown state. `mode` is menu-bar keyboard mode with nothing open
// (what a bare Alt tap gives you); `open` is the index of the open dropdown.
Menu_State :: struct {
	mode: bool,
	open: int, // -1 = no dropdown
	item: int, // highlighted item within the open dropdown
	// First visible row when the dropdown is taller than the window. Without
	// scrolling, items past the clip were simply unreachable — on a short window
	// the last entries of the Edit menu could not be seen or selected at all.
	top:  int,
	rows: int, // rows drawn last frame; the hit-test must use the same count

	// Context-menu mode: the same draw/hit-test/scroll machinery as the bar
	// dropdown, anchored to a point instead of a bar title (a right-click on a
	// table column header — Task 5). Kept as its own bool + slice rather than
	// repurposing `open` as an index into ctx_items, because `open` also
	// selects which bar title lights up in menu_draw, and a context menu has
	// no bar title to light.
	ctx:       bool,
	ctx_items: []Menu_Item,
	ctx_x:     f32, // anchor, top-left, before menu_dropdown_rect's edge clamp
	ctx_y:     f32,
	// The table column the context menu targets. Written by exactly two procs --
	// menu_open_ctx sets it, menu_open_at clears it -- and read by the six
	// Table_Sort commands in command_dispatch, which run AFTER the menu that
	// picked them has been closed. That ordering is why menu_close must not
	// clear it; see menu_close.
	ctx_col:   int,
	// The TAB SLOT a tab context menu targets, on exactly the same terms as
	// ctx_col above and for the same reason: the four Tab_* commands run after the
	// menu that picked them has closed, so the target has to outlive the menu.
	//
	// A slot, not a display index. Display order is the order of live entries in
	// app.docs and a slot survives another tab being closed in between, which a
	// display index does not -- and the commands on this menu include two that
	// close tabs.
	ctx_tab:   int,
	// The picked row's Menu_Item.payload, left here by menu_hit_test for the same
	// reason ctx_col is: the command runs after the menu has closed, so anything it
	// needs from the row has to outlive the menu.
	ctx_payload: int,

	// The column filter dropdown's search box. A fixed buffer, not a [dynamic]u8:
	// it lives on the App for the life of the process and this is a filter over a
	// list of column values, where a query past a line's worth of text has already
	// stopped narrowing anything.
	//
	// UNLIKE ctx_col and ctx_payload, this IS cleared on close -- it is read only
	// while the dropdown is open (menu_filter_items), so a stale query would
	// silently pre-filter the next column's values.
	query:       [128]u8,
	query_len:   int,
	// Where the search row's label is BUILT. Its own buffer because Menu_Item.text
	// is a borrowed string that has to outlive the frame, and the obvious way to
	// write it -- format into the temp allocator -- dangles at the next free_all,
	// which is the trap menu_open_ctx's comment already describes for the slice.
	query_label: [160]u8,
}

// Must be called before the first frame: the zero value of `open` is 0, which
// means "the File dropdown is open", so an uninitialised Menu_State starts the
// app with a menu hanging down.
menu_init :: proc(m: ^Menu_State) {
	m.open = -1
	m.item = -1
	m.mode = false
	m.top = 0
	m.rows = 0
	// Zero value (false/nil/0) is already "no context menu"; set explicitly so
	// a reader doesn't have to re-derive that from Odin's zero-init rule.
	m.ctx = false
	m.ctx_items = nil
	m.ctx_x = 0
	m.ctx_y = 0
	m.ctx_col = 0
}

// Deliberately does NOT clear ctx_col, and this is the whole of why: both routes
// from a picked row to its command close the menu FIRST and dispatch second --
// menu_hit_test evaluates item_enabled, calls this, and returns the command for
// main.odin to dispatch; .Menu_Activate does the same in commands.odin because
// the item may open the palette. Clearing here therefore aimed every one of the
// six Table_Sort commands at column 0 while item_enabled had already greyed the
// row for column N, which is exactly the draw-disagrees-with-effect divergence
// Menu_Item.enabled exists to prevent.
//
// Leaving it set is safe because nothing can read a stale value: the predicates
// and item_disabled_reason only run while a dropdown holding those rows is open,
// menu_open_ctx overwrites it on every open, menu_open_at clears it, and the six
// commands are reachable from no other route -- no bar row carries them, the
// palette excludes them (palette.odin), and a hand-written keymap chord cannot
// reach them either: command_from_name (keymap.odin) refuses any name for which
// command_needs_menu_target (commands.odin) holds. That is true by construction,
// not by the accident of nothing having bound one yet.
menu_close :: proc(app: ^App) {
	app.menu.mode = false
	app.menu.open = -1
	app.menu.item = -1
	app.menu.ctx = false
	app.menu.ctx_items = nil
	app.menu.query_len = 0
}

// Covers `ctx` as well as the bar: without it, a click outside a context menu
// would not be recognised as "dismiss", because the only other doorway to
// dismissal (main.odin's alt_tapped toggle and the Ctx.Menu key-routing
// branch) both gate on this proc, not on `open`.
menu_is_active :: proc(app: ^App) -> bool {return app.menu.mode || app.menu.open >= 0 || app.menu.ctx}

// Whether an open dropdown exists to draw or hit-test, bar or context.
// Deliberately not the same question as menu_is_active: bare Alt-tap keyboard
// mode (mode == true, open == -1, ctx == false) is "active" for key routing
// but has no dropdown here, so reusing menu_is_active as this guard would
// fall through to menus[-1] in menu_items.
@(private = "file")
menu_dropdown_active :: proc(app: ^App) -> bool {return app.menu.open >= 0 || app.menu.ctx}

is_menu_cmd :: proc(c: Command_Id) -> bool {
	#partial switch c {
	case .Menu_Close, .Menu_Next, .Menu_Prev, .Menu_Item_Next, .Menu_Item_Prev, .Menu_Activate, .Menu_Search_Back:
		return true
	}
	return false
}

lower_rune :: proc(r: rune) -> rune {return r + 32 if r >= 'A' && r <= 'Z' else r}

// Map a character back to a Key so an Alt+<char> press can be checked against
// the explicit Alt bindings before it is treated as a mnemonic.
char_key :: proc(r: rune) -> plat.Key {
	c := lower_rune(r)
	if c >= 'a' && c <= 'z' {return plat.Key(int(plat.Key.A) + int(c - 'a'))}
	if c >= '0' && c <= '9' {return plat.Key(int(plat.Key.Num0) + int(c - '0'))}
	return .None
}

// Click handling for the bar and any open dropdown. Returns true if the click
// was consumed. Must run before the tab strip and scrollbar handlers.
// Once a dropdown is open, moving the pointer across the bar switches to the
// menu under it — how every native menu behaves. Without it the bar feels dead:
// you open File, slide to Edit, and nothing happens until you click again.
//
// Only while something is open. Hovering the bar with everything closed must not
// open anything, or the menu drops down whenever the pointer crosses the row.
menu_hover_update :: proc(app: ^App, t: ^plat.Text, win: ^plat.Window) {
	if app.menu.open < 0 {return}
	cx, cy := plat.window_cursor_client(win)
	if f32(cy) < TAB_STRIP_H || f32(cy) >= TAB_STRIP_H + MENU_BAR_H {return}
	if i := menu_title_at(t, f32(cx)); i >= 0 && i != app.menu.open {
		menu_open_at(app, i)
	}
}

// Highlight the dropdown row under the pointer, so the mouse and the keyboard
// agree about what is selected before a click lands.
//
// Queries the cursor rather than reading win.mouse_y: WM_MOUSEMOVE only records
// a position while a button is held (it exists for drag-select), so mouse_y is
// wherever the last click landed and never moves during a plain hover.
menu_hover_item :: proc(app: ^App, t: ^plat.Text, win: ^plat.Window) {
	if !menu_dropdown_active(app) {return}
	cx, cy := plat.window_cursor_client(win)
	if r := menu_item_at(t, app, f32(cx), f32(cy), f32(win.width), f32(win.height)); r >= 0 {
		if item_enabled(app, menu_items(app)[r]) {app.menu.item = r}
	}
}

// Returns the command a click selected (.None if it selected nothing) and
// whether the click was consumed. The caller dispatches, so the menu never has
// to know how commands run.
menu_hit_test :: proc(app: ^App, t: ^plat.Text, win: ^plat.Window, w, h: f32) -> (cmd: Command_Id, consumed: bool) {
	if !win.mouse_pressed {return .None, false}
	mx, my := f32(win.mouse_x), f32(win.mouse_y)

	if my >= TAB_STRIP_H && my < TAB_STRIP_H + MENU_BAR_H {
		gx := w - SCROLLBAR_W - sx(GEAR_W_96)
		if mx >= gx && mx < gx + sx(GEAR_W_96) {
			menu_close(app)
			consume_click(win)
			// Always "open": it activates the existing Settings tab if there is
			// one, so the gear is a destination, not a toggle.
			return .Settings_Open, true
		}
		if i := menu_title_at(t, mx); i >= 0 {
			if app.menu.open == i {menu_close(app)} else {menu_open_at(app, i)}
		} else {
			menu_close(app) // empty bar area: swallow, don't move the caret
		}
		consume_click(win)
		return .None, true
	}

	if menu_dropdown_active(app) {
		picked := Command_Id.None
		if idx := menu_item_at(t, app, mx, my, w, h); idx >= 0 {
			it := menu_items(app)[idx]
			if item_enabled(app, it) {picked = it.cmd;app.menu.ctx_payload = it.payload}
		}
		// Any click while a dropdown is open is consumed, as native menus do —
		// clicking away closes it rather than also moving the caret.
		//
		// EXCEPT a row that ticks a checkbox. A menu closing on every click is
		// right for a command and wrong for a multi-select: ticking one value,
		// having the list vanish, and reopening it to tick a second is not a
		// gesture anyone would design, and it is what shipped in v0.49.0.
		// command_keeps_menu_open names the rows that stay.
		if !command_keeps_menu_open(picked) {menu_close(app)}
		consume_click(win)
		return picked, true
	}
	return .None, false
}

// Take the click entirely. Clearing mouse_down matters as much as mouse_pressed:
// the caret's drag-to-extend branch runs off mouse_down alone, so leaving it set
// meant clicking a menu also dragged a selection through the document behind it,
// and kept highlighting for as long as the button stayed down.
@(private = "file")
consume_click :: proc(win: ^plat.Window) {
	win.mouse_pressed = false
	win.mouse_middle_pressed = false
	win.mouse_down = false
}

// A row is live when the command may run against the active document AND the
// row's own predicate agrees. Two halves, deliberately: the first is
// command_allowed_on (commands.odin), the shared rule about what KIND of
// document is under the cursor, which command_dispatch enforces too so a row
// cannot be grey here and still run from the palette; the second is this row's
// local availability -- a selection to cut, a file to reload, history to undo --
// which only the menu has any reason to know.
// Why a row is greyed out, in the accelerator's column.
//
// UI spec 6: "Table View greys out on a .md file with no explanation. Show the
// reason in text_muted where the accelerator would be." A disabled row with no
// reason is indistinguishable from a broken one, and the two commands this
// mostly affects are gated on the FILE TYPE -- which the user can see, once
// someone says that is what matters.
//
// Returns "" when there is nothing useful to say, in which case the accelerator
// is drawn as usual. Deliberately not a general mechanism: only the gates whose
// reason is both stable and actionable get wording, because "unavailable" in
// the accelerator column is worse than an empty one.
// The wording, as a pure function of the command. Separate from the decision
// below so dropdown_w can budget for it: the panel is sized from the widest
// TRAILING text, and a reason is longer than the accelerator it replaces --
// "Markdown files only" against "Ctrl+M". Without this the reason would be
// clipped by exactly the width the shortcut used to need.
command_disabled_hint :: proc(cmd: Command_Id) -> string {
	#partial switch cmd {
	case .Toggle_Table:
		return "CSV and TSV only"
	case .Toggle_Preview:
		return "Markdown files only"
	case .Reopen_UTF8, .Reopen_UTF16LE, .Reopen_CP1252:
		return "unsaved file"
	case .Table_Sort_Then_Asc, .Table_Sort_Then_Desc:
		return fmt.tprintf("%d-column sort limit", TABLE_SORT_KEYS_MAX)
	case .Tab_Reveal, .Tab_Copy_Path:
		// Both are dead for the same reason and it is one the user can act on:
		// save the tab and they light up.
		return "unsaved file"
	case .Tab_Close_Others:
		return "only tab"
	}
	return ""
}

item_disabled_reason :: proc(app: ^App, it: Menu_Item) -> string {
	d := app_active(app)
	#partial switch it.cmd {
	case .Toggle_Table:
		if d != nil && d.kind == .Text && !doc_can_table(d) {return command_disabled_hint(it.cmd)}
	case .Toggle_Preview:
		if d != nil && d.kind == .Text && !doc_can_markdown(d) {return command_disabled_hint(it.cmd)}
	case .Reopen_UTF8, .Reopen_UTF16LE, .Reopen_CP1252:
		if d != nil && d.path == "" {return command_disabled_hint(it.cmd)}
	case .Tab_Reveal, .Tab_Copy_Path:
		// The TARGET tab, not the active one: the menu may be open on a tab that
		// is not in front, and explaining the active tab's state there would be a
		// reason for the wrong file.
		if t := menu_ctx_tab_doc(app); t != nil && t.path == "" {return command_disabled_hint(it.cmd)}
	case .Tab_Close_Others:
		if app_live_count(app) <= 1 {return command_disabled_hint(it.cmd)}
	case .Table_Sort_Then_Asc, .Table_Sort_Then_Desc:
		// Only the AT-THE-CAP reason: a sort that isn't live yet needs no
		// explanation for "there is nothing to add a tie-breaker to" -- the row
		// being dead is its own explanation there. This is the one state that
		// isn't, per the brief: two keys already live, neither of them this
		// column, so the row reads as broken without saying why.
		if table_sorted(d) {
			if _, ok := table_sort_key(d, app.menu.ctx_col); !ok && !table_sort_can_add(d, app.menu.ctx_col) {
				return command_disabled_hint(it.cmd)
			}
		}
	}
	return ""
}

item_enabled :: proc(app: ^App, it: Menu_Item) -> bool {
	if it.cmd == .None {return false} // separator
	if !command_allowed_on(it.cmd, app_active(app)) {return false}
	// command_allowed_on only knows about pseudo-tabs (doc.kind != .Text); it
	// says nothing about table view or Preview, which ARE .Text documents that
	// merely refuse writes. Without this, Replace All (and .Paste, which had
	// the identical pre-existing hole) painted live, hovered live, and no-oped
	// on click there -- the refusal happened later, in command_dispatch. This
	// is the same fix find_actions already got for the find-bar buttons: one
	// predicate change so the draw, hover and hit-test all agree.
	if command_mutates_doc(it.cmd) && doc_read_only_view(app_active(app)) {return false}
	return it.enabled == nil || it.enabled(app)
}

// First selectable item at or after `from`, walking `dir`. Skips separators and
// disabled rows so keyboard navigation never parks on something inert.
menu_step :: proc(app: ^App, mi, from, dir: int) -> int {
	items := menus[mi].items
	i := from
	for _ in 0 ..< len(items) {
		if i < 0 {i = len(items) - 1}
		if i >= len(items) {i = 0}
		if item_enabled(app, items[i]) {return i}
		i += dir
	}
	return -1
}

menu_open_at :: proc(app: ^App, mi: int) {
	// A bar dropdown and the context menu must never both be "open" at once:
	// menu_items and menu_origin test `ctx` before `open`, so leaving ctx set
	// here left open==0 && ctx==true reachable -- commands.odin's Ctx.Menu
	// keyboard routing calls this with `open < 0` as its only test, which is
	// true for a context menu too (ctx never touches `open`), so a stray key
	// while a context menu was up silently swapped it for File's dropdown
	// while still reading ctx_items for the draw and hit-test. Clearing
	// ctx_items and ctx_col alongside ctx matches menu_close, so no stale
	// slice or column survives into the bar menu.
	app.menu.ctx = false
	app.menu.ctx_items = nil
	app.menu.ctx_col = 0
	app.menu.query_len = 0
	app.menu.mode = true
	app.menu.open = clamp(mi, 0, len(menus) - 1)
	app.menu.item = menu_step(app, app.menu.open, 0, 1)
	app.menu.top = 0 // the draw scrolls this to keep the highlight visible
	app.menu.rows = 0
}

// Open a context menu at (x, y), the point the caller measured before
// clamping — menu_dropdown_rect applies the window clamp when it draws, not
// here. Two input paths reach it, both in main.odin's table block and both
// carrying table_header_menu_items: a left click on the header's chevron
// (table_header_at) and a right click anywhere in a header cell
// (table_header_cell_at) -- NOT table_header_col_at, an older procedure that
// answers a similar-sounding question but does not clip to the grid's right
// edge, so a press past it resolves to the last column instead of to
// nothing. The right-click path was written against table_header_cell_at
// specifically to avoid that; see its own comment in table.odin.
//
// `items` is not copied, so the caller must pass a slice that outlives the
// menu. main.odin's frame loop calls free_all(context.temp_allocator) once
// per frame, and a menu by definition survives into the NEXT frame's draw
// and hit-test -- so a slice built from context.temp_allocator and stored
// here dangles the moment that free_all runs. The caller must pass a
// package-level []Menu_Item (like `menus`) or one owned by App, never a
// temp_allocator build. Menu_Item holds only a Command_Id and two procedure
// pointers (no strings), so only the slice's backing store is at risk here,
// not anything it points to.
menu_open_ctx :: proc(app: ^App, items: []Menu_Item, x, y: f32, col: int) {
	app.menu.mode = false
	app.menu.open = -1
	app.menu.query_len = 0 // a search box starts empty on every open, per column
	app.menu.ctx = true
	app.menu.ctx_items = items
	app.menu.ctx_x = x
	app.menu.ctx_y = y
	app.menu.ctx_col = col
	app.menu.ctx_tab = -1 // a header menu targets a column, never a tab
	// menu_step walks menus[mi].items by menu INDEX, which a context menu has
	// none of — first-enabled found directly instead, same rule (skip
	// separators and disabled rows) menu_step applies for the bar.
	app.menu.item = -1
	for it, i in items {
		if item_enabled(app, it) {
			app.menu.item = i
			break
		}
	}
	app.menu.top = 0
	app.menu.rows = 0
}

// Open the TAB context menu on `slot`, at the point the caller measured.
//
// Its own entry point rather than a `kind` parameter on menu_open_ctx, because
// the two menus target different things and the targets must not be settable at
// once: a stale ctx_col read by a Tab_ command, or a stale ctx_tab read by a
// Table_Sort one, is the "captured index consumed in the wrong space" shape this
// codebase keeps producing. Each opener sets its own target and clears the other.
// THE Y IS THIS PROCEDURE'S, not the caller's, and that is where the bug was.
//
// menu_hit_test claims every click in the band [TAB_STRIP_H, TAB_STRIP_H +
// MENU_BAR_H) for the menu BAR before it looks at any open dropdown. A tab menu
// anchored at TAB_STRIP_H therefore puts its FIRST ROW inside that band, and
// clicking that row reads as "empty bar area": the menu closes and nothing runs.
// That shipped in v0.43.0 as "the right click on tab does not open explorer to
// the path" -- and it was always the first row, whichever row that was.
//
// The caller passed the y before. Now it cannot, so the rule cannot be got wrong
// at a second call site, and menutest can assert it.
menu_open_tab_ctx :: proc(app: ^App, x: f32, slot: int) {
	menu_open_ctx(app, tab_menu_items, x, TAB_STRIP_H + MENU_BAR_H, 0)
	app.menu.ctx_col = 0
	app.menu.ctx_tab = slot
	// The first-enabled highlight was chosen against ctx_tab == -1 above, when
	// every path-dependent row read as disabled. Re-run it now the target is set,
	// or a right-click on a saved tab would open with Close highlighted.
	app.menu.item = -1
	for it, i in tab_menu_items {
		if item_enabled(app, it) {
			app.menu.item = i
			break
		}
	}
}

// --- layout ---

@(private = "file")
title_w :: proc(t: ^plat.Text, s: string) -> f32 {
	// col0 = 0: a menu title is a whole label, drawn from its own x.
	return f32(plat.text_cells(t, transmute([]u8)s, 0)) * plat.text_char_width(t, UI_PX) + 2 * MENU_PAD
}

// x range of top-level menu `i` in the bar.
menu_title_rect :: proc(t: ^plat.Text, i: int) -> (x0, x1: f32) {
	x := f32(0)
	for m, k in menus {
		w := title_w(t, m.title)
		if k == i {return x, x + w}
		x += w
	}
	return 0, 0
}

// Which top-level title is at client x (in the bar row), or -1.
menu_title_at :: proc(t: ^plat.Text, mx: f32) -> int {
	for _, i in menus {
		x0, x1 := menu_title_rect(t, i)
		if mx >= x0 && mx < x1 {return i}
	}
	return -1
}

// The open dropdown's rows: a bar dropdown's own Menu.items, or ctx_items for
// a context menu. Every draw/hit-test/scroll proc below reads through here
// instead of indexing `menus` by the open index directly, so a context menu is
// a second ANCHOR onto the same machinery rather than a second copy of it.
// Callers must already know a dropdown is open (menu_dropdown_active) —
// app.menu.open == -1 with ctx == false is not a valid index into `menus`.
menu_items :: proc(app: ^App) -> []Menu_Item {
	if app.menu.ctx {return app.menu.ctx_items}
	return menus[app.menu.open].items
}

// Unclamped anchor of the open dropdown. A bar dropdown's x comes from its
// title's rect (menu_title_rect, hence `t` — title width is glyph metrics,
// not something this proc can know on its own); its y is always the row
// below the bar. A context menu's anchor is whatever menu_open_ctx was given.
// menu_dropdown_rect is what applies the window-edge clamp; this proc must
// return the pre-clamp point, or a menu anchored near the edge would be
// clamped once here and again there against a different reference width.
menu_origin :: proc(t: ^plat.Text, app: ^App) -> (x0, y0: f32) {
	if app.menu.ctx {return app.menu.ctx_x, app.menu.ctx_y}
	x0, _ = menu_title_rect(t, app.menu.open)
	return x0, TAB_STRIP_H + MENU_BAR_H
}

// --- drawing ---

menu_draw :: proc(gfx: ^plat.Gfx, qp: ^plat.Quad_Pipeline, t: ^plat.Text, app: ^App, win: ^plat.Window, width, height: f32) {
	cw := plat.text_char_width(t, UI_PX)
	base_y := TAB_STRIP_H + MENU_BAR_H - sx(8)
	plat.quads_draw(gfx, qp, []plat.Quad{{pos = {0, TAB_STRIP_H}, size = {width, MENU_BAR_H}, color = g_theme[.Bg_Panel]}})

	cx, cy := plat.window_cursor_client(win)
	in_bar := f32(cy) >= TAB_STRIP_H && f32(cy) < TAB_STRIP_H + MENU_BAR_H
	hover := menu_title_at(t, f32(cx)) if in_bar else -1

	for m, i in menus {
		x0, x1 := menu_title_rect(t, i)
		lit := i == app.menu.open || (app.menu.open < 0 && i == hover)
		if lit {
			plat.quads_draw(gfx, qp, []plat.Quad{{pos = {x0, TAB_STRIP_H}, size = {x1 - x0, MENU_BAR_H}, color = g_theme[.Bg_Hover]}})
		}
		plat.text_draw(gfx, t, m.title, x0 + MENU_PAD, base_y, UI_PX, g_theme[.Text_Primary])
		// Underline the mnemonic while in keyboard menu mode, the way Windows
		// reveals access keys only once Alt has been pressed.
		if app.menu.mode {
			plat.quads_draw(gfx, qp, []plat.Quad{{pos = {x0 + MENU_PAD, base_y + sx(2)}, size = {cw, sx(1)}, color = g_theme[.Text_Primary]}})
		}
	}

	// Settings gear, right-aligned and clear of the scrollbar gutter. Drawn
	// larger than the menu text: at UI_PX the glyph reads as a speck rather than
	// a button, and it is the only icon-only control in the bar.
	gw := sx(GEAR_W_96)
	gx := width - SCROLLBAR_W - gw
	if in_bar && f32(cx) >= gx && f32(cx) < gx + gw {
		plat.quads_draw(gfx, qp, []plat.Quad{{pos = {gx, TAB_STRIP_H}, size = {gw, MENU_BAR_H}, color = g_theme[.Bg_Hover]}})
	}
	gpx := UI_PX * 1.35
	gcw := plat.text_char_width(t, gpx)
	on_settings := false
	if d := app_active(app); d != nil {on_settings = d.kind == .Settings}
	plat.text_draw(gfx, t, "⚙", gx + (gw - gcw) * 0.5, base_y + sx(2), gpx, g_theme[.Success] if on_settings else g_theme[.Text_Primary])

	if !menu_dropdown_active(app) {return}
	menu_draw_dropdown(gfx, qp, t, app, width, height)
}

@(private = "file")
menu_draw_dropdown :: proc(gfx: ^plat.Gfx, qp: ^plat.Quad_Pipeline, t: ^plat.Text, app: ^App, width, height: f32) {
	items := menu_items(app)
	cw := plat.text_char_width(t, UI_PX)
	// Same geometry the hit-test uses, y included — see menu_dropdown_rect. This
	// used to take y from menu_origin and only x/w/h from the rect, which is what
	// made a flip-up impossible to add safely.
	x0, y0, dw, h := menu_dropdown_rect(t, app, width, height)

	plat.quads_draw(gfx, qp, []plat.Quad {
			{pos = {x0 - sx(1), y0}, size = {dw + sx(2), h + sx(2)}, color = g_theme[.Border_Strong]},
			{pos = {x0, y0 + sx(1)}, size = {dw, h}, color = g_theme[.Bg_Panel]},
		})

	// Keep the highlighted item visible, then draw from the scroll offset.
	menu_scroll_to_item(app, items, h)
	app.menu.rows = rows_fitting(items, app.menu.top, h)
	more_above := app.menu.top > 0
	more_below := app.menu.top + app.menu.rows < len(items)

	// Items begin one pixel down, inside the border. The bottom bound must be
	// measured from THAT origin, not from y0: measuring from y0 gave the items
	// h-1 of room while the hit-test gave them h, so a dropdown that fit exactly
	// lost its last row on screen while still being clickable — which is how
	// Edit > Font became an invisible-but-live strip at the bottom of the menu.
	// Draw exactly the rows rows_fitting says fit — the same count the hit-test
	// uses. Deciding independently here (a bound measured from the box origin
	// rather than the items origin) dropped the last row on screen while it
	// stayed clickable, which is how Edit > Font became an invisible live strip.
	items_y0 := y0 + sx(1)
	y := items_y0
	last := app.menu.top + app.menu.rows
	for i := app.menu.top; i < min(last, len(items)); i += 1 {
		it := items[i]
		if it.cmd == .None && it.text != "" { // a label row: the filter's search box
			plat.quads_draw(gfx, qp, []plat.Quad{{pos = {x0 + sx(4), y + sx(3)}, size = {dw - sx(8), MENU_ITEM_H - sx(6)}, color = g_theme[.Bg_Raised]}})
			// Muted when it is showing the prompt, primary when it is showing what
			// was typed -- the same distinction the find bar draws, so an empty box
			// cannot be read as a query that matches nothing.
			typed := app.menu.query_len > 0
			plat.text_draw(gfx, t, it.text, x0 + sx(12), y + MENU_ITEM_H - sx(9), UI_PX, g_theme[.Text_Primary] if typed else g_theme[.Text_Muted])
			y += MENU_ITEM_H
			continue
		}
		if it.cmd == .None { // separator
			sh := MENU_ITEM_H * 0.4
			plat.quads_draw(gfx, qp, []plat.Quad{{pos = {x0 + sx(8), y + sh * 0.5}, size = {dw - sx(16), sx(1)}, color = g_theme[.Border_Strong]}})
			y += sh
			continue
		}
		on := item_enabled(app, it)
		if i == app.menu.item && on {
			plat.quads_draw(gfx, qp, []plat.Quad{{pos = {x0, y}, size = {dw, MENU_ITEM_H}, color = g_theme[.Selection_List]}})
		}
		ty := y + MENU_ITEM_H - sx(7)
		if it.checked != nil && it.checked(app, it) {
			plat.text_draw(gfx, t, "✓", x0 + sx(8), ty, UI_PX, g_theme[.Success])
		}
		// A generated row shows its VALUE; every other row shows its command's
		// title. One lookup, so the width budget below and the draw cannot disagree
		// about how long a row is.
		label := menu_item_label(app, it)
		if label == "" {label = command_table[it.cmd].title}
		plat.text_draw(gfx, t, label, x0 + sx(28), ty, UI_PX, g_theme[.Text_Primary] if on else g_theme[.Text_Muted])
		// The accelerator, or -- when the row is greyed out for a reason worth
		// giving -- that reason in its place.
		trailing := command_chord(it.cmd)
		if !on {
			if why := item_disabled_reason(app, it); why != "" {trailing = why}
		}
		if trailing != "" {
			plat.text_draw(gfx, t, trailing, x0 + dw - sx(12) - f32(len(trailing)) * cw, ty, UI_PX, g_theme[.Text_Muted])
		}
		y += MENU_ITEM_H
	}

	// Say that there is more. Silently truncating is what hid Edit > Font on a
	// short window.
	if more_above {
		plat.text_draw(gfx, t, "▲", x0 + dw - sx(16), y0 + sx(12), UI_SMALL_PX, g_theme[.Text_Muted])
	}
	if more_below {
		plat.text_draw(gfx, t, "▼", x0 + dw - sx(16), y0 + h - sx(4), UI_SMALL_PX, g_theme[.Text_Muted])
	}
	// A SCROLLBAR, when there is more than fits. The two arrows above say "there is
	// more" and say nothing about how much or where you are -- which is fine for a
	// menu clipped by one row and useless for a generated list of two hundred
	// values. Proportional thumb, same shape as the document's.
	//
	// Drawn, not draggable. The wheel and the arrow keys move the list; a drag
	// would need its own hit-test inside a surface whose every other pixel already
	// means "pick this row", and the wheel is what a person reaches for anyway.
	if total := len(items); total > app.menu.rows && app.menu.rows > 0 {
		bw := max(sx(MENU_SCROLLBAR_W_96), 2)
		bx := x0 + dw - bw
		frac := f32(app.menu.rows) / f32(total)
		th := max(h * frac, MENU_ITEM_H * 0.5)
		// Positioned off the FIRST VISIBLE ROW over the rows that can be first, so
		// the thumb reaches the bottom exactly when the last row is on screen.
		span := max(1, total - app.menu.rows)
		ty := y0 + (h - th) * f32(min(app.menu.top, span)) / f32(span)
		plat.quads_draw(
			gfx,
			qp,
			[]plat.Quad {
				{pos = {bx, y0}, size = {bw, h}, color = g_theme[.Bg_Raised]},
				{pos = {bx, ty}, size = {bw, th}, color = g_theme[.Scrollbar_Thumb]},
			},
		)
	}
}

// Geometry of the open dropdown. The single source both the draw and the
// hit-test consume, so they cannot disagree — every seam bug found so far has
// been a pair of expressions in two different procs.
// RETURNS y0 AS WELL AS x0, and that is the whole of the flip-up fix rather than
// a convenience. The draw and the hit-test used to each call menu_origin for
// their own y and only ask this proc for x/w/h, so a flip computed in one of them
// would be a menu drawn in one place and clickable in another — CLAUDE.md's one
// layout per widget, in the exact shape (draw and hit-test deriving the same
// coordinate separately) that this file's own comments say every seam bug here
// has taken. Both consumers read y0 from here now.
menu_dropdown_rect :: proc(t: ^plat.Text, app: ^App, width, height: f32) -> (x0, y0, w, h: f32) {
	if !menu_dropdown_active(app) {return 0, 0, 0, 0}
	items := menu_items(app)
	ox, oy := menu_origin(t, app)
	w = dropdown_w(app, t, items)
	full := f32(0)
	for it in items {full += MENU_ITEM_H if it.cmd != .None else MENU_ITEM_H * 0.4}

	// Clamped to the window, and the two axes still are not the same kind of
	// clamp. x0 REPOSITIONS: an anchor too close to the right edge slides the
	// whole dropdown left so it still fits. y0 FLIPS: when the room below the
	// anchor cannot hold the menu and there is more room above it, the menu's
	// BOTTOM edge goes at the anchor instead of its top.
	//
	// This used to cap downward only, and the comment here said a flip-up was
	// owed "if a context-menu anchor is ever near the bottom", then argued the
	// case was unreachable because column headers sit at the top of the grid.
	// The header does sit at the top of the grid; on a short enough window the
	// top of the grid IS near the bottom of the window, which is exactly how it
	// was reached — "it does not scroll, there is no scroll bar in this instance,
	// and the menu is behind the bottom of window menu items" (Wyatt, live use,
	// v0.36.0). What was reachable was never about the anchor being unusual.
	//
	// `above > below` is what keeps a BAR dropdown from flipping over the menu
	// bar that opened it: its anchor is TAB_STRIP_H + MENU_BAR_H from the top, so
	// there is almost never more room above than below, and no special case on
	// `ctx` is needed to say so. A window short enough to fail that test has no
	// good answer available in either direction.
	//
	// The downward cap still floors at MENU_ITEM_H, and the rows past the cap are
	// still not clickable (menu_item_at requires my < height), so the residual
	// case is a visibility one and not a safety one — as before.
	// A CEILING IN ROWS, not just in window height. A hand-written menu is a dozen
	// rows and never reaches it; the column filter GENERATES its rows -- up to
	// TABLE_FILTER_VALUES_MAX of them -- and without this the dropdown is as tall
	// as the window, which is not a menu, it is a wall. *"there's no scroll bar, it
	// shouldn't be the full vertical height of the window... something reasonable"*
	// (Wyatt, v0.49.0).
	//
	// The scroll machinery to go under it already existed (menu.top, rows_fitting,
	// the more_above/more_below arrows); what it never had was a reason to trigger
	// or a way to drive it with the mouse. Both arrived with this.
	// ...AND ONLY ON A GENERATED ROW SET. This first shipped unconditional, and the
	// Edit menu is 12 command rows and 5 separators -- fourteen rows' worth, past a
	// cap of twelve -- so Font became unreachable again, which is the exact bug the
	// more_above/more_below arrows were added for in the first place. menutest
	// caught it; the constant's own comment ("enough that no hand-written menu is
	// ever clipped") was simply wrong, and a menu nobody generated has never needed
	// this because a person typed every row of it.
	if menu_is_filter_dropdown(app) {full = min(full, MENU_MAX_ROWS * MENU_ITEM_H)}
	below := max(0, height - oy - sx(4))
	above := max(0, oy - sx(4))
	if full > below && above > below {
		h = min(full, max(MENU_ITEM_H, above))
		y0 = max(0, oy - h)
	} else {
		h = min(full, max(MENU_ITEM_H, below))
		y0 = oy
	}
	x0 = min(ox, max(0, width - w))
	return
}

// Item height, separators included. A .None row carrying text is a label, not a
// rule, and gets a full row -- one expression, so the draw and the hit-test cannot
// disagree about how tall the search box is.
@(private = "file")
item_h :: proc(it: Menu_Item) -> f32 {
	if it.cmd != .None || it.text != "" {return MENU_ITEM_H}
	return MENU_ITEM_H * 0.4
}

// Rows that fit in `h` starting at item `from`, and whether everything from
// `from` onward fits. One walk, used by both the draw and the hit-test.
// How many items the draw will emit. Exposed so a test can compare what is
// drawn against what is hit-testable — the pair disagreeing is the bug class
// this codebase keeps producing.
menu_visible_rows :: proc(t: ^plat.Text, app: ^App, width, height: f32) -> int {
	if !menu_dropdown_active(app) {return 0}
	_, _, _, h := menu_dropdown_rect(t, app, width, height)
	return rows_fitting(menu_items(app), app.menu.top, h)
}

@(private = "file")
rows_fitting :: proc(items: []Menu_Item, from: int, h: f32) -> (count: int) {
	used := f32(0)
	for i := from; i < len(items); i += 1 {
		ih := item_h(items[i])
		if used + ih > h {return}
		used += ih
		count += 1
	}
	return
}

// The scroll resolution, as a pure function: which `top` does a dropdown of
// height `h` settle on when `item` must be visible? Takes `top` by value and
// returns the resolved offset instead of mutating, so the answer can be asked
// without performing a draw — which is what `menuseam` needs to compare the row
// set the draw would emit against the row set the hit-test would accept.
menu_resolve_top :: proc(top, item: int, items: []Menu_Item, h: f32) -> int {
	if item < 0 {return top}
	t := top
	if item < t {t = item}
	// Grow `top` until the highlighted item is within the visible run.
	for {
		n := rows_fitting(items, t, h)
		if n == 0 {break}
		if item < t + n {break}
		t += 1
	}
	return clamp(t, 0, max(0, len(items) - 1))
}

// The wheel over an open dropdown. Returns true when it consumed the notch, so
// the document behind it does not scroll too.
//
// The dropdown had scroll STATE (menu.top) and a scroll RESOLVER
// (menu_resolve_top) since the day a menu first outgrew a short window, and no way
// at all to drive either with the mouse -- the keyboard highlight was the only
// thing that ever moved it. That was survivable while every menu was a dozen
// hand-written rows and stopped being survivable the moment the column filter
// generated two hundred.
menu_wheel :: proc(app: ^App, t: ^plat.Text, delta: int, w, h: f32) -> bool {
	if !menu_dropdown_active(app) || delta == 0 {return false}
	items := menu_items(app)
	_, _, _, dh := menu_dropdown_rect(t, app, w, h)
	vis := rows_fitting(items, app.menu.top, dh)
	if vis >= len(items) && app.menu.top == 0 {return true} // nothing to scroll, still ours
	// Clamped so the last row can reach the bottom and no further: scrolling into
	// empty space below a list is the thing that makes a list feel broken.
	last := 0
	for last < len(items) {
		if rows_fitting(items, last, dh) >= len(items) - last {break}
		last += 1
	}
	app.menu.top = clamp(app.menu.top - delta, 0, last)
	return true
}

// Scroll the dropdown the minimum needed to bring `app.menu.item` into view.
// Called from the draw, so the hit-test one frame later agrees with what is on
// screen.
@(private = "file")
menu_scroll_to_item :: proc(app: ^App, items: []Menu_Item, h: f32) {
	m := &app.menu
	m.top = menu_resolve_top(m.top, m.item, items, h)
}

// Row index at client (x, y) within the open dropdown, or -1.
//
// Takes x: without it every point at the right height was a live menu row, so
// clicking into the document to dismiss a menu instead ran whatever command sat
// at that height — Save, Reload or Exit among them.
menu_item_at :: proc(t: ^plat.Text, app: ^App, mx, my, width, height: f32) -> int {
	if !menu_dropdown_active(app) {return -1}
	x0, oy, w, h := menu_dropdown_rect(t, app, width, height)
	if mx < x0 || mx >= x0 + w {return -1}
	// The rect's own y, not menu_origin's: under a flip-up the two differ by the
	// whole height of the menu, and this is the half that would still have been
	// hit-testing the un-flipped box.
	y0 := oy + sx(1)
	if my < y0 || my >= y0 + h {return -1} // below a clipped dropdown is not a row
	items := menu_items(app)
	y := y0
	// Starts at the scroll offset and stops at the same count the draw used, so
	// a row is clickable exactly when it is visible.
	last := app.menu.top + rows_fitting(items, app.menu.top, h)
	for i := app.menu.top; i < min(last, len(items)); i += 1 {
		ih := item_h(items[i])
		if my >= y && my < y + ih {
			return i if items[i].cmd != .None else -1
		}
		y += ih
	}
	return -1
}

// Not file-private: menutest asserts that every dropdown is wide enough for its
// own widest row, which is the seam this sizing exists to hold.
// Width of ONE dropdown's rows. UI spec 6: "widest label + check gutter + gap +
// widest accelerator + padding. Measure once on open; never a fixed width."
//
// Per dropdown, not across all of them. It used to take the widest row anywhere,
// so every dropdown was as wide as the longest item in the whole menu bar --
// File inherited its width from View's longest row and looked padded for no
// reason. Takes the item slice rather than a menu index so a context menu's
// ctx_items sizes the same way a bar menu's items do, through the one budget
// rule below rather than a second one keyed off ctx.
//
// The trailing budget is the larger of the accelerator and the disabled reason,
// because either can occupy that column.
dropdown_w :: proc(app: ^App, t: ^plat.Text, items: []Menu_Item) -> f32 {
	cw := plat.text_char_width(t, UI_PX)
	widest := 0
	for it in items {
		// A label row has no command and no accelerator, and still has to fit: the
		// search box showing "abcdefgh" in a dropdown sized for "(Select All)" would
		// print past its own border.
		if it.cmd == .None && it.text != "" {
			if n := len(it.text) + 8; n > widest {widest = n}
			continue
		}
		if it.cmd == .None {continue}
		trailing := max(len(command_chord(it.cmd)), len(command_disabled_hint(it.cmd)))
		title := menu_item_label(app, it)
		if title == "" {title = command_table[it.cmd].title}
		if n := len(title) + trailing + 8; n > widest {widest = n}
	}
	return f32(widest) * cw
}
