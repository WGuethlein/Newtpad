// Layer: program — the command table: every editor action declared once. The
// enumerated `command_table` (compiler forces a row per Command_Id) holds palette
// metadata; `default_bindings` is the keymap (key chord + context -> command),
// separated from the metadata so keys are rebindable later (a user overlay);
// `command_dispatch` is the single behavior switch. This replaces the old split
// between the platform VK->Key_Cmd switch and the program Key_Cmd->action switch.
package main

import "core:fmt"
import "core:mem"
import "core:path/filepath"
import "core:strings"
import "core:unicode/utf8"
import base "src:base"
import plat "src:platform"

// Where a binding is active. Find mode is modal (doc.find.active); the same chord
// can mean different things per context (Enter = newline vs confirm-search).
Ctx :: enum u8 {
	Editor,
	Find,
	Palette,
	Menu,
	Settings,
	History,
	Font,
}

Command_Id :: enum u8 {
	None = 0,
	// editor
	Cursor_Left,
	Cursor_Right,
	Cursor_Up,
	Cursor_Down,
	Cursor_Home,
	Cursor_End,
	Doc_Start,
	Doc_End,
	Word_Left,
	Word_Right,
	Page_Up,
	Page_Down,
	Backspace,
	Delete_Fwd,
	Delete_Word_Back,
	Insert_Newline,
	Insert_Tab,
	Undo,
	Redo,
	Select_All,
	Copy,
	Cut,
	Paste,
	Save,
	Save_As,
	Find_Open,
	Replace_Open,
	Filter_Open,
	Goto_Line,
	Open_Link,
	Clear_Selection,
	Move_Line_Up,
	Move_Line_Down,
	Block_Extend_Left,
	Block_Extend_Right,
	Block_Extend_Up,
	Block_Extend_Down,
	Toggle_Wrap,
	Toggle_Table,
	Toggle_Preview,
	Bookmark_Toggle,
	// ONE cycle command, not a next/prev pair: Binding is (key, ctrl, alt, ctx)
	// and shift is not part of a chord (see Binding's own comment and the
	// Ctrl+Alt+S scar below), so F2 and Shift+F2 cannot be two rows. The
	// direction is read off ev.shift in the dispatch, exactly as
	// doc_cursor_left(doc, ev.shift) reads it.
	Bookmark_Cycle,
	// Sort/dedupe the selected lines (the whole document with no selection).
	// THREE commands, not two with a modifier: shift is not part of a chord
	// (see Binding, and Bookmark_Cycle above), so a descending variant cannot
	// be Shift+something and has to be its own row. All three are palette-only
	// -- no default chord, because adding one is a keys.txt line now.
	Sort_Lines,
	Sort_Lines_Desc,
	Remove_Duplicate_Lines,
	Format_Document,
	// The table header's context menu (menu.odin's table_header_menu_items).
	// Dispatched against app.menu.ctx_col -- the column the menu was opened on,
	// which menu_close deliberately preserves past the row's pick -- because there is
	// no persistent "current column" in the table view outside an open cell
	// edit (table_edit_col). Excluded from the palette below for exactly that
	// reason: the palette has no column to name.
	Table_Sort_Asc,
	Table_Sort_Desc,
	Table_Sort_Then_Asc,
	Table_Sort_Then_Desc,
	Table_Sort_Remove,
	Table_Sort_Clear,
	Table_First_Row_Is_Data,
	Table_Filter_Open,
	Table_Filter_Toggle,
	Table_Filter_All,
	Table_Filter_Clear,
	// tab strip context menu
	Tab_Reveal,
	Tab_Copy_Path,
	Tab_Close_This,
	Tab_Close_Others,
	// command palette
	Palette_Open,
	Palette_Close,
	Palette_Confirm,
	Palette_Next,
	Palette_Prev,
	Palette_Backspace,
	// tabs
	Tab_New,
	Tab_Open,
	Tab_Close,
	Tab_Next,
	Tab_Prev,
	Exit,
	Reload,
	// encoding / line endings
	Enc_UTF8,
	Enc_UTF16LE,
	Enc_CP1252,
	Reopen_UTF8,
	Reopen_UTF16LE,
	Reopen_CP1252,
	Eol_LF,
	Eol_CRLF,
	// menu bar navigation
	Menu_Close,
	Menu_Next,
	Menu_Prev,
	Menu_Item_Next,
	Menu_Item_Prev,
	Menu_Activate,
	Menu_Search_Back,
	// settings page
	Settings_Open,
	Settings_Close,
	Settings_Next,
	Settings_Prev,
	Settings_Toggle,
	Settings_Inc,
	Settings_Dec,
	Theme_Edit,
	Keys_Edit,
	Rules_Edit,
	Open_Logs_Folder,
	Open_Themes_Folder,
	// help
	Check_For_Updates,
	// font page (Edit > Font)
	Font_Open,
	Font_Close,
	Font_Next,
	Font_Prev,
	Font_Inc,
	Font_Dec,
	Zoom_In,
	Zoom_Out,
	Zoom_Reset,
	// undo history panel
	History_Open,
	History_Close,
	History_Next,
	History_Prev,
	History_Jump,
	// find mode
	Find_Close,
	Find_Backspace,
	// Ctrl+V into the query/replace field. It has to be its own row, in the
	// .Find context, because the alternative is what this fixes: with no .Find
	// binding the chord fell through resolve_key to the editor's .Paste and the
	// clipboard landed in the DOCUMENT while the find bar had focus -- and the
	// viewport is not editable while it does, so the text could not be taken
	// back out without closing the bar first. Wyatt, live use, 2026-07-29.
	Find_Paste,
	Find_Confirm,
	// The two step verbs, split out for exactly the reason the replace verbs
	// below were: .Find_Confirm reads DIRECTION off the shift key in the action,
	// so "search backwards" could be spelled by one gesture and named nowhere. A
	// button carries no key event, so the find bar's `↑` had nothing to dispatch.
	// Naming them also puts both in the palette and the menus, which §7 asks for
	// ("every command in it is also in a menu") and which Shift+Enter never was.
	Find_Step_Next,
	Find_Step_Prev,
	Find_Field_Toggle,
	Find_Toggle_Regex,
	Find_Toggle_Case,
	Find_Toggle_Word,
	Find_Toggle_Filter,
	Find_Toggle_Replace_Mode,
	// The two replace verbs, as commands rather than as branches inside
	// .Find_Confirm. They have to be their own rows to be REACHABLE: a palette
	// entry, a menu row and a button all dispatch a Command_Id and carry no key
	// event, so "Enter with ctrl held, in the replace field" could be spelled by
	// exactly one gesture and named nowhere. It was worse than that -- the ctrl
	// branch was dead. Binding matches (key, ctrl, alt, ctx) exactly and the
	// only Enter rows were ctrl=false, so Ctrl+Enter resolved to .None and
	// Replace All had no key, no palette entry and no button. That is precisely
	// the report this fixes.
	Find_Replace_One,
	Find_Replace_All,
	Find_Filter_Page_Up,
	Find_Filter_Page_Down,
}

// Palette metadata for a command. (Behavior is in command_dispatch; key chords
// are in default_bindings.)
Command :: struct {
	title:    string,
	category: string,
}

// One row per Command_Id — the array is total over the enum, so a new command
// can't be forgotten here. `.None` is the unbound sentinel.
command_table := [Command_Id]Command {
	.None                     = {},
	.Cursor_Left              = {"Move Left", "Cursor"},
	.Cursor_Right             = {"Move Right", "Cursor"},
	.Cursor_Up                = {"Move Up", "Cursor"},
	.Cursor_Down              = {"Move Down", "Cursor"},
	.Cursor_Home              = {"Move to Line Start", "Cursor"},
	.Cursor_End               = {"Move to Line End", "Cursor"},
	.Doc_Start                = {"Go to Start of File", "Cursor"},
	.Doc_End                  = {"Go to End of File", "Cursor"},
	.Word_Left                = {"Move Word Left", "Cursor"},
	.Word_Right               = {"Move Word Right", "Cursor"},
	.Page_Up                  = {"Page Up", "Cursor"},
	.Page_Down                = {"Page Down", "Cursor"},
	.Backspace                = {"Delete Backward", "Edit"},
	.Delete_Fwd               = {"Delete Forward", "Edit"},
	.Delete_Word_Back         = {"Delete Word Backward", "Edit"},
	.Insert_Newline           = {"Insert Newline", "Edit"},
	.Insert_Tab               = {"Insert Tab", "Edit"},
	.Undo                     = {"Undo", "Edit"},
	.Redo                     = {"Redo", "Edit"},
	.Select_All               = {"Select All", "Edit"},
	.Copy                     = {"Copy", "Edit"},
	.Cut                      = {"Cut", "Edit"},
	.Paste                    = {"Paste", "Edit"},
	.Save                     = {"Save", "File"},
	.Save_As                  = {"Save As…", "File"},
	.Find_Open                = {"Find", "Search"},
	.Replace_Open             = {"Replace", "Search"},
	.Filter_Open              = {"Filter to Matching Lines", "Search"},
	.Goto_Line                = {"Go to Line…", "Cursor"},
	.Open_Link                = {"Open Link Under Cursor", "File"},
	.Clear_Selection          = {"Clear Selection", "Cursor"},
	.Move_Line_Up             = {"Move Line Up", "Edit"},
	.Move_Line_Down           = {"Move Line Down", "Edit"},
	.Block_Extend_Left        = {"Extend Column Selection Left", "Edit"},
	.Block_Extend_Right       = {"Extend Column Selection Right", "Edit"},
	.Block_Extend_Up          = {"Extend Column Selection Up", "Edit"},
	.Block_Extend_Down        = {"Extend Column Selection Down", "Edit"},
	// No "Toggle" verb: every one of these carries a check mark, which already
	// says it is a toggle, and the word cost seven characters of menu width on
	// three of the four longest rows (UI spec 6).
	.Toggle_Wrap              = {"Word Wrap", "View"},
	.Toggle_Table             = {"Table View (CSV/TSV)", "View"},
	.Toggle_Preview           = {"Markdown Preview / Split", "View"},
	.Bookmark_Toggle          = {"Toggle Bookmark on This Line", "Cursor"},
	.Bookmark_Cycle           = {"Go to Next Bookmark (Shift: Previous)", "Cursor"},
	// The titles carry the two things a user would otherwise have to discover by
	// running the command on real data: the scope (selection, else the whole
	// file) and, for dedupe, that the match is exact -- `Foo` and `foo` are two
	// different lines, even though the SORT compares case-insensitively. The
	// palette shows the title and nothing else, so anything not in it is not said.
	// The parenthetical qualifiers these three used to carry -- "(selection, or
	// whole file)" twice and "(exact match, keeps the first)" -- were affordable
	// while the palette was their only route. They are not affordable as MENU rows:
	// dropdown_w sizes a panel from its widest label, and 53 characters of
	// "Remove Duplicate Lines (exact match, keeps the first)" made the Edit menu
	// wider than the whole menu bar. They also set the palette's width floor at
	// ~700px, which is why it is 720 against ui-spec 7's 560.
	//
	// The behaviour they described is not lost: it is in features.md, and the case
	// that actually needs saying at the moment of choosing -- the 16 MB / 1,000,000
	// line refusal -- is what command_disabled_hint puts in the accelerator column.
	.Sort_Lines               = {"Sort Lines", "Edit"},
	.Sort_Lines_Desc          = {"Sort Lines Descending", "Edit"},
	.Remove_Duplicate_Lines   = {"Remove Duplicate Lines", "Edit"},
	.Format_Document          = {"Format Document", "Edit"},
	.Table_Sort_Asc           = {"Sort Ascending", "Table"},
	.Table_Sort_Desc          = {"Sort Descending", "Table"},
	.Table_Sort_Then_Asc      = {"Then by Ascending", "Table"},
	.Table_Sort_Then_Desc     = {"Then by Descending", "Table"},
	.Table_Sort_Remove        = {"Remove from Sort", "Table"},
	.Table_Sort_Clear         = {"Clear Sort", "Table"},
	.Table_First_Row_Is_Data  = {"First Row Is Data", "Table"},
	.Table_Filter_Open        = {"Filter…", "Table"},
	.Table_Filter_Toggle      = {"Filter: Toggle Value", "Table"},
	.Table_Filter_All         = {"(Select All)", "Table"},
	.Table_Filter_Clear       = {"Clear Filter", "Table"},
	.Tab_Reveal               = {"Reveal in Explorer", "Tab"},
	.Tab_Copy_Path            = {"Copy Full Path", "Tab"},
	.Tab_Close_This           = {"Close Tab", "Tab"},
	.Tab_Close_Others         = {"Close Other Tabs", "Tab"},
	.Palette_Open             = {"Command Palette", "View"},
	.Palette_Close            = {"Palette: Close", "View"},
	.Palette_Confirm          = {"Palette: Confirm", "View"},
	.Palette_Next             = {"Palette: Next", "View"},
	.Palette_Prev             = {"Palette: Previous", "View"},
	.Palette_Backspace        = {"Palette: Delete Backward", "View"},
	.Tab_New                  = {"New Tab", "Tabs"},
	.Tab_Open                 = {"Open File…", "Tabs"},
	.Tab_Close                = {"Close Tab", "Tabs"},
	.Tab_Next                 = {"Next Tab", "Tabs"},
	.Tab_Prev                 = {"Previous Tab", "Tabs"},
	.Exit                     = {"Exit", "File"},
	.Reload                   = {"Reload from Disk", "File"},
	.Enc_UTF8                 = {"Save as UTF-8", "Encoding"},
	.Enc_UTF16LE              = {"Save as UTF-16 LE", "Encoding"},
	.Enc_CP1252               = {"Save as Windows-1252", "Encoding"},
	.Reopen_UTF8              = {"Reopen as UTF-8", "Encoding"},
	.Reopen_UTF16LE           = {"Reopen as UTF-16 LE", "Encoding"},
	.Reopen_CP1252            = {"Reopen as Windows-1252", "Encoding"},
	.Eol_LF                   = {"Line Endings: LF (Unix)", "Encoding"},
	.Eol_CRLF                 = {"Line Endings: CRLF (Windows)", "Encoding"},
	.Menu_Close               = {"Menu: Close", "View"},
	.Menu_Next                = {"Menu: Next", "View"},
	.Menu_Prev                = {"Menu: Previous", "View"},
	.Menu_Item_Next           = {"Menu: Next Item", "View"},
	.Menu_Item_Prev           = {"Menu: Previous Item", "View"},
	.Menu_Activate            = {"Menu: Activate Item", "View"},
	.Menu_Search_Back         = {"Menu: Search Delete Backward", "View"},
	.Settings_Open            = {"Settings", "View"},
	.Settings_Close           = {"Settings: Close", "View"},
	.Settings_Next            = {"Settings: Next", "View"},
	.Settings_Prev            = {"Settings: Previous", "View"},
	.Settings_Toggle          = {"Settings: Toggle", "View"},
	.Settings_Inc             = {"Settings: Increase", "View"},
	.Settings_Dec             = {"Settings: Decrease", "View"},
	.Theme_Edit               = {"Edit Current Theme…", "View"},
	.Keys_Edit                = {"Edit Keybindings…", "View"},
	.Rules_Edit               = {"Edit Colour Rules…", "View"},
	.Open_Logs_Folder         = {"Open Logs Folder", "View"},
	.Open_Themes_Folder       = {"Open Themes Folder", "View"},
	// The only command in the product that touches the network, and the title
	// says so. The user should not have to guess which row leaves the machine,
	// and the menu row and the palette entry both read from this one string.
	.Check_For_Updates        = {"Check for Updates (contacts GitHub)", "Help"},
	.Font_Open                = {"Font...", "Edit"},
	.Font_Close               = {"Font: Close", "Edit"},
	.Font_Next                = {"Font: Next", "Edit"},
	.Font_Prev                = {"Font: Previous", "Edit"},
	.Font_Inc                 = {"Font: Next Value", "Edit"},
	.Font_Dec                 = {"Font: Previous Value", "Edit"},
	.Zoom_In                  = {"Zoom In", "View"},
	.Zoom_Out                 = {"Zoom Out", "View"},
	.Zoom_Reset               = {"Reset Zoom", "View"},
	.History_Open             = {"Undo History", "Edit"},
	.History_Close            = {"History: Close", "Edit"},
	.History_Next             = {"History: Next", "Edit"},
	.History_Prev             = {"History: Previous", "Edit"},
	.History_Jump             = {"History: Jump to State", "Edit"},
	.Find_Close               = {"Close Find", "Search"},
	.Find_Backspace           = {"Find: Delete Backward", "Search"},
	.Find_Paste               = {"Find: Paste", "Search"},
	.Find_Confirm             = {"Find: Confirm", "Search"},
	.Find_Step_Next           = {"Find: Next Match", "Search"},
	.Find_Step_Prev           = {"Find: Previous Match", "Search"},
	.Find_Field_Toggle        = {"Find: Toggle Field", "Search"},
	.Find_Toggle_Regex        = {"Find: Regex", "Search"},
	.Find_Toggle_Case         = {"Find: Match Case", "Search"},
	.Find_Toggle_Word         = {"Find: Whole Word", "Search"},
	.Find_Toggle_Filter       = {"Find: Toggle Filter View", "Search"},
	.Find_Toggle_Replace_Mode = {"Find: Toggle Replace", "Search"},
	// Plain names, not "Find: ..." -- these are the two things a user came to
	// the replace row to do, and they are what gets typed into the palette.
	.Find_Replace_One         = {"Replace Match", "Search"},
	.Find_Replace_All         = {"Replace All", "Search"},
	.Find_Filter_Page_Up      = {"Find: Filter Page Up", "Search"},
	.Find_Filter_Page_Down    = {"Find: Filter Page Down", "Search"},
}

// A default key binding. Matching uses (key, ctrl) within a context; shift is a
// modifier the action reads (selection extend, search direction), never part of
// the chord — no command distinguishes on shift. A command may have several
// bindings (e.g. Find_Close on Esc and Ctrl+F).
Binding :: struct {
	key:  plat.Key,
	ctrl: bool,
	alt:  bool,
	ctx:  Ctx,
	cmd:  Command_Id,
}

default_bindings := []Binding {
	// --- editor context ---   {key, ctrl, alt, ctx, cmd}
	{.Left, false, false, .Editor, .Cursor_Left},
	{.Right, false, false, .Editor, .Cursor_Right},
	{.Up, false, false, .Editor, .Cursor_Up},
	{.Down, false, false, .Editor, .Cursor_Down},
	{.Home, false, false, .Editor, .Cursor_Home},
	{.End, false, false, .Editor, .Cursor_End},
	{.Left, true, false, .Editor, .Word_Left},
	{.Right, true, false, .Editor, .Word_Right},
	{.Page_Up, false, false, .Editor, .Page_Up},
	{.Page_Down, false, false, .Editor, .Page_Down},
	{.Backspace, false, false, .Editor, .Backspace},
	{.Backspace, true, false, .Editor, .Delete_Word_Back},
	{.Delete, false, false, .Editor, .Delete_Fwd},
	{.Enter, false, false, .Editor, .Insert_Newline},
	{.Tab, false, false, .Editor, .Insert_Tab},
	{.Home, true, false, .Editor, .Doc_Start}, // Ctrl+Home
	{.End, true, false, .Editor, .Doc_End}, // Ctrl+End
	{.Z, true, false, .Editor, .Undo},
	{.Y, true, false, .Editor, .Redo},
	{.A, true, false, .Editor, .Select_All},
	{.C, true, false, .Editor, .Copy},
	{.X, true, false, .Editor, .Cut},
	{.V, true, false, .Editor, .Paste},
	{.S, true, false, .Editor, .Save},
	{.F, true, false, .Editor, .Find_Open},
	{.H, true, false, .Editor, .Replace_Open},
	{.L, true, false, .Editor, .Filter_Open}, // Ctrl+L opens find with the filter armed
	{.G, true, false, .Editor, .Goto_Line}, // Ctrl+G
	{.S, true, true, .Editor, .Save_As}, // Ctrl+Alt+S (Ctrl+Shift+S can't be expressed: shift isn't part of a chord)
	// Ctrl+Alt+F. VS Code's Format Document is Shift+Alt+F and that cannot be
	// expressed here -- Binding has no `shift` field, the same reason Save As is
	// Ctrl+Alt+S rather than Ctrl+Shift+S -- so this is its nearest expressible
	// neighbour, and it keeps the F. Ctrl+F is Find and stays that way.
	{.F, true, true, .Editor, .Format_Document},
	// The two replace verbs, declared in .Editor and NOT in .Find, deliberately.
	// resolve_key falls the Find context back to the editor keymap for modified
	// chords (see its comment), so one row here binds the chord in both places --
	// and command_chord prefers an Editor row, so the palette, the menus and the
	// buttons on the replace row all teach the same string. Two rows would be two
	// chances to disagree. From the document (find shut) they open the replace
	// bar rather than doing nothing, which is the honest answer to "replace what?".
	{.Enter, true, false, .Editor, .Find_Replace_One}, // Ctrl+Enter
	{.Enter, true, true, .Editor, .Find_Replace_All}, // Ctrl+Alt+Enter
	{.Escape, false, false, .Editor, .Clear_Selection},
	{.Up, false, true, .Editor, .Move_Line_Up}, // Alt+Up (Alt+Shift+Up extends a column selection -- shift read in the action)
	{.Down, false, true, .Editor, .Move_Line_Down}, // Alt+Down (Alt+Shift+Down extends a column selection -- shift read in the action)
	// Alt+Left/Right were unbound before this feature. The chord itself
	// carries no shift bit (Binding has none -- shift is read by the
	// action), so a bare Alt+Left/Right lands on these same two rows; the
	// action must keep doing nothing without shift, exactly as the unbound
	// key did before this task.
	{.Left, false, true, .Editor, .Block_Extend_Left}, // Alt+Left / Alt+Shift+Left
	{.Right, false, true, .Editor, .Block_Extend_Right}, // Alt+Right / Alt+Shift+Right
	{.Z, false, true, .Editor, .Toggle_Wrap}, // Alt+Z
	{.T, true, false, .Editor, .Toggle_Table}, // Ctrl+T: CSV/TSV table view
	{.M, true, false, .Editor, .Toggle_Preview}, // Ctrl+M: markdown preview -> split -> off
	{.Plus, true, false, .Editor, .Zoom_In}, // Ctrl+= / Ctrl+numpad+
	{.Minus, true, false, .Editor, .Zoom_Out}, // Ctrl+- / Ctrl+numpad-
	{.Num0, true, false, .Editor, .Zoom_Reset}, // Ctrl+0
	{.P, true, false, .Editor, .Palette_Open}, // Ctrl+P
	{.F2, true, false, .Editor, .Bookmark_Toggle}, // Ctrl+F2
	{.F2, false, false, .Editor, .Bookmark_Cycle}, // F2 / Shift+F2 -- shift read in the action
	// --- palette context ---
	{.P, true, false, .Palette, .Palette_Close},
	{.Escape, false, false, .Palette, .Palette_Close},
	{.Enter, false, false, .Palette, .Palette_Confirm},
	{.Up, false, false, .Palette, .Palette_Prev},
	{.Down, false, false, .Palette, .Palette_Next},
	{.Backspace, false, false, .Palette, .Palette_Backspace},
	{.N, true, false, .Editor, .Tab_New},
	{.O, true, false, .Editor, .Tab_Open},
	{.W, true, false, .Editor, .Tab_Close},
	{.Tab, true, false, .Editor, .Tab_Next}, // Ctrl+Tab (Shift -> previous, in the action)
	{.Page_Up, true, false, .Editor, .Tab_Prev},
	{.Page_Down, true, false, .Editor, .Tab_Next},
	// --- history context ---
	{.Escape, false, false, .History, .History_Close},
	{.Down, false, false, .History, .History_Next},
	{.Up, false, false, .History, .History_Prev},
	{.Enter, false, false, .History, .History_Jump},
	// --- font page context ---
	{.Escape, false, false, .Font, .Font_Close},
	{.Down, false, false, .Font, .Font_Next},
	{.Up, false, false, .Font, .Font_Prev},
	{.Right, false, false, .Font, .Font_Inc},
	{.Left, false, false, .Font, .Font_Dec},
	{.Enter, false, false, .Font, .Font_Inc},
	// --- settings context ---
	{.Escape, false, false, .Settings, .Settings_Close},
	{.Down, false, false, .Settings, .Settings_Next},
	{.Up, false, false, .Settings, .Settings_Prev},
	{.Enter, false, false, .Settings, .Settings_Toggle},
	{.Right, false, false, .Settings, .Settings_Inc},
	{.Left, false, false, .Settings, .Settings_Dec},
	// --- menu context ---
	{.Escape, false, false, .Menu, .Menu_Close},
	{.Left, false, false, .Menu, .Menu_Prev},
	{.Right, false, false, .Menu, .Menu_Next},
	{.Down, false, false, .Menu, .Menu_Item_Next},
	{.Up, false, false, .Menu, .Menu_Item_Prev},
	{.Enter, false, false, .Menu, .Menu_Activate},
	// Backspace edits the filter dropdown's search box, and does nothing at all on
	// every other menu. It is a MENU command rather than a .Menu-context binding of
	// .Backspace because main.odin closes the menu on any non-menu chord -- binding
	// the editor's Backspace here would dismiss the dropdown and delete a character
	// from the document behind it, which is the shape of bug this whole context
	// system exists to prevent.
	{.Backspace, false, false, .Menu, .Menu_Search_Back},
	// --- find context ---
	{.Escape, false, false, .Find, .Find_Close},
	{.F, true, false, .Find, .Find_Open}, // switch to search view (leaves filter); Escape closes
	{.Backspace, false, false, .Find, .Find_Backspace},
	// Ctrl+V belongs to the FIELD, not to the document behind it. Declared here
	// rather than left to resolve_key's editor fallback, which is what sent it to
	// .Paste; find_fallback_writes_doc now refuses that fallback as well, so this
	// row and that refusal are belt and braces for the same hole.
	{.V, true, false, .Find, .Find_Paste},
	{.Enter, false, false, .Find, .Find_Confirm},
	{.Tab, false, false, .Find, .Find_Field_Toggle},
	// All three toggles are Alt, matching VS Code: Alt+C case, Alt+W whole
	// word, Alt+R regex. Not Ctrl -- Ctrl+C, Ctrl+W and Ctrl+R already mean
	// copy, close-tab and (until this line) regex-via-a-different-chord, and a
	// find bar that stole any of them would be worse than the modes are
	// worth. Ctrl+R is retired outright, not left as a second way to toggle
	// regex: one chord per command, and the seeded keys.txt header only
	// documents alt+<letter> as the mnemonic-shadowing surprise, not this one.
	{.R, false, true, .Find, .Find_Toggle_Regex},
	{.C, false, true, .Find, .Find_Toggle_Case},
	{.W, false, true, .Find, .Find_Toggle_Word},
	{.L, true, false, .Find, .Find_Toggle_Filter},
	{.H, true, false, .Find, .Find_Toggle_Replace_Mode},
	{.Page_Up, false, false, .Find, .Find_Filter_Page_Up},
	{.Page_Down, false, false, .Find, .Find_Filter_Page_Down},
}

// Human-readable chord for a command, e.g. "Ctrl+S", or "" if unbound. The first
// Editor-context binding wins, since that is the one a user would press from the
// document. Used by the palette and the menu — the keymap is the only place that
// knows the shortcuts, so anything that teaches them has to read it from here
// rather than repeat them in a second table that can drift.
// A user overlay changes the answer, so this reads the overlay too. Without
// that, rebinding Save to Ctrl+J would leave every menu and palette row still
// teaching Ctrl+S — a shortcut that no longer works. The keymap being the only
// place that knows the shortcuts is exactly why this proc exists; consulting
// only half of the keymap would reintroduce the drift it was written to stop.
//
// Three sources, in this order, and EVERY candidate — default or overlay — has
// to answer the same question first: does this chord still resolve to this
// command? A row that teaches a chord which now runs something ELSE is worse
// than a row that teaches nothing, and a keys.txt can produce that from either
// side (a later duplicate line beats an earlier one, so an overlay row is no
// more self-evidently live than a default one).
//
//  1. THE DEFAULT EDITOR CHORD, IF IT STILL RESOLVES. The distinction that
//     matters is between a keys.txt line that ADDS a chord and one that
//     REPLACES it. `ctrl+k = Undo` leaves Ctrl+Z alone; the user asked for one
//     more way in, not for the one they already know to be un-taught, so the
//     menus keep saying Ctrl+Z. Unbinding Ctrl+Z, or giving it to Redo, makes
//     this test fail — and then, and only then, the overlay's chord is what
//     gets taught. "The overlay wins" alone would collapse the two cases.
//  2. THE OVERLAY'S OWN ROW, last-wins inside the file (the order
//     keymap_lookup resolves in). This is the answer for a rebind, and the
//     only answer a command with no default chord at all can have —
//     `ctrl+alt+o = Open_Link` is the whole reason the seed lists those.
//  3. ANY OTHER CONTEXT'S DEFAULT, so mode-local commands (the find toggles)
//     still teach their key instead of showing blank. Last, because an Editor
//     chord is the one a user would press from the document.
//
// All three are no-ops with no keys.txt: an empty overlay makes resolve_key the
// plain default lookup, and no two default_bindings rows share a (key, ctrl,
// alt, ctx) — keymaptest pins that — so nothing can fail its own guard.
command_chord :: proc(cmd: Command_Id, allocator := context.temp_allocator) -> string {
	if cmd == .None {return ""}
	fmt_chord :: proc(b: Binding, allocator: mem.Allocator) -> string {
		parts: [4]string
		n := 0
		if b.ctrl {parts[n] = "Ctrl+";n += 1}
		if b.alt {parts[n] = "Alt+";n += 1}
		parts[n] = key_name(b.key)
		// DISPLAY ONLY, and it has to happen here rather than in key_names: the
		// key is unshifted on a US layout, so "Ctrl+=" is what the user actually
		// presses and what the UI spec's §6 mockup shows -- but key_names is also
		// the keys.txt grammar, and keymap_parse splits a line on its first '='.
		// Renaming the key there would make `ctrl+= = Zoom_In` unparseable and
		// would silently break every keys.txt already spelling it "+".
		if b.key == .Plus {parts[n] = "="}
		n += 1
		return strings.concatenate(parts[:n], allocator)
	}
	for b in default_bindings {
		if b.cmd != cmd || b.ctx != .Editor {continue}
		if resolve_key(b.key, b.ctrl, b.alt, b.ctx) != cmd {continue}
		return fmt_chord(b, allocator)
	}
	#reverse for e in g_keymap.entries {
		if e.cmd != cmd {continue}
		if resolve_key(e.key, e.ctrl, e.alt, e.ctx) != cmd {continue}
		return fmt_chord(e, allocator)
	}
	for b in default_bindings {
		if b.cmd != cmd || b.ctx == .Editor {continue}
		if resolve_key(b.key, b.ctrl, b.alt, b.ctx) != cmd {continue}
		return fmt_chord(b, allocator)
	}
	return ""
}

// Show a save failure. Silence here is a data-loss bug: the user believes the
// file was written, and in a release build (-subsystem:windows) stderr is gone.
@(private = "file")
// UI spec 13: "Errors take the whole bar in danger until dismissed -- Could not
// save: file is read-only. NOTHING IN THIS APP SHOULD EVER NEED A MODAL DIALOG."
// This proc was the modal that rule names: a failed save put up a message box
// that had to be clicked before anything else could happen.
//
// `app` may be nil -- several test modes drive the save path without one -- and
// the message box is what happens then, because a failure that reaches nobody is
// worse than a modal.
report_save :: proc(app: ^App, err: plat.Write_Error, path: string, w: ^plat.Window) -> bool {
	if err == .None {
		fmt.printfln("Newtpad: saved %s", path)
		return true
	}
	if app != nil {
		app_error(app, plat.write_error_text(err, path))
	} else {
		plat.message_error(w.hwnd if w != nil else nil, plat.write_error_text(err, path))
	}
	return false
}

// Save, after checking the document's encoding can actually hold its contents.
// Windows-1252 cannot represent an em-dash, a curly quote or an emoji, and
// encode_from_utf8 substituted '?' for each one and reported success -- so
// pasting modern text into a legacy file destroyed it silently. Returns true if
// the file was written.
//
// The lossy check collects the buffer, and so does the save, so a CP1252 file is
// collected twice. Acceptable while CP1252 means "small legacy file"; if that
// stops being true, have doc_save_err report the loss instead.
@(private = "file")
save_checked :: proc(app: ^App, doc: ^Document, path: string, w: ^plat.Window) -> bool {
	if doc.enc == .CP1252 {
		body := base.pt_collect(&doc.pt, context.temp_allocator)
		if lost := base.encode_lossy_count(body, doc.enc); lost > 0 {
			switch plat.confirm_lossy_encoding(w.hwnd if w != nil else nil, doc_display_name(doc), enc_name(doc.enc), lost) {
			case .Save_As_UTF8:
				// Keep the text, change the container. A BOM would surprise anything
				// parsing this file, so it is written BOM-less.
				doc.enc = .UTF8
				doc.had_bom = false
			case .Save_Anyway:
			// The user chose the loss with the count in front of them.
			case .Cancel:
				return false
			}
		}
	}
	saved := report_save(app, doc_save_err(doc, path), path, w)
	if saved && app != nil {
		// UI spec 13: "Saved for 1.5s in success, then gone. No toast, no dialog,
		// no sound." A save that succeeds currently says nothing at all, so the
		// only confirmation is the asterisk disappearing from a tab you may not be
		// looking at. app_note already owns the transient-message lifetime.
		app_note(app, "Saved", .Success)
		// Saving the active theme's own file re-applies it -- this is the loop
		// that makes tuning a theme possible without a rebuild. `path`, not
		// doc.path: doc_save_err frees and reallocates doc.path.
		theme_reapply_if_active(app, path)
		// Same loop for the keymap: saving keys.txt re-reads it, so a binding can
		// be tried without restarting. All three are called unconditionally and
		// each checks the path itself.
		keymap_reload_if_active(app, path)
		// And for the colour rules: saving rules.txt recolours the next frame.
		rules_reload_if_active(app, path)
	}
	return saved
}

// How large a file may be and still be re-decoded under a forced encoding.
//
// Reopening as anything but UTF-8 transcodes, and doc_open's transcode branch
// materialises the whole file on the UI thread: make([]u8, len) + safe_copy for
// a private guarded copy, then decode_to_utf8 into a second allocation. Above
// plat.FILE_MMAP_THRESHOLD (16 MB) the file is mapped precisely so that none of
// that happens at open time, and one menu click would undo it -- on a 500 MB log
// that is a multi-second freeze on the "opens multi-GB files" property, and if
// the allocation fails the document comes back EMPTY, which a following Ctrl+S
// then writes over the user's file.
//
// So it refuses above a cap, the same shape as a column edit refusing past
// BLOCK_EDIT_MAX_LINES: a refusal that changes nothing beats a partial result.
// 64 MB is four times the mmap threshold. Below 16 MB the bytes were copied into
// private memory at open time anyway, so a transcode there adds nothing new in
// kind; between 16 and 64 MB sits the band of large-but-ordinary logs and dumps
// where a mis-detected encoding is still worth correcting and the cost is a
// tenth of a second. 64 MB bounds the transient allocation at roughly 3x that.
//
// A variable, not a constant, only so enctest can lower it and prove the refusal
// without carrying a 64 MB fixture. Nothing in the product writes it.
REOPEN_TRANSCODE_MAX_BYTES :: i64(64 * 1024 * 1024)
reopen_transcode_max_bytes := REOPEN_TRANSCODE_MAX_BYTES

// Re-read the file under `enc`. Confirms first when there are unsaved changes:
// this discards the buffer, and a menu row that silently destroys work is worse
// than no row. A failed read leaves the document exactly as it was -- doc_open
// fails before doc_reload_forced touches anything.
@(private = "file")
reopen_with_encoding :: proc(app: ^App, doc: ^Document, w: ^plat.Window, enc: base.Encoding) {
	if doc == nil || doc.path == "" {return}
	// Before the confirm, not after: refusing is not a decision the user should
	// be asked to discard unsaved work for first. Only the transcoding rows are
	// capped -- doc_open takes the private copy only when the resolved encoding
	// is not UTF-8, so Reopen as UTF-8 keeps the mapping and costs nothing extra
	// however large the file is.
	//
	// Stat NOW rather than reading doc.disk_stamp.size, which is what this used
	// to do and what made the cap fail OPEN on exactly the two cases it exists
	// for: the stamp is 0 when the last stat failed (a dropped share), and it is
	// stale on a restored dirty tab, which carries the size the session recorded
	// -- so a file that grew to 500 MB while Newtpad was closed reported its old
	// size and the cap waved the transcode through. The size that matters is the
	// size doc_open is about to read, and that is only knowable now.
	//
	// A failed stat REFUSES. Being wrong in that direction costs a menu row that
	// does nothing and says why; being wrong in the other costs the multi-second
	// UI freeze the cap exists to prevent, on a file we could not even measure.
	// A guard whose unknown case is its unsafe case is not a guard.
	//
	// The stat is synchronous on the UI thread and can block for the redirector
	// timeout on a dropped share (see plat.file_stamp), so the order below is
	// load-bearing and an earlier version of this comment had it wrong: refusing
	// is NOT "strictly less blocking than proceeding" in every branch.
	//
	// The recorded stamp gets to REFUSE for free -- if what we last saw was
	// already over the cap, or could not be measured at all, the answer cannot
	// change in the safe direction and the old code refused it with zero
	// syscalls. Blocking for thirty seconds only to print the same message would
	// be a regression introduced by the fix.
	//
	// The stamp does not get to APPROVE: that is the whole bug (below). So the
	// stat runs exactly on the branch where the reopen it gates was about to open
	// and read the same path -- one timeout instead of one, never a new one on a
	// path that was going to stay untouched.
	//
	// A not-ok stamp does not wedge the rows shut either: the watcher re-stats
	// every open file from its worker thread and publishes the result
	// (main.odin), so a share that comes back clears the stamp within a poll
	// without the UI thread blocking at all.
	if enc != .UTF8 {
		ok, size := doc.disk_stamp.ok, doc.disk_stamp.size
		if ok && size <= reopen_transcode_max_bytes {
			st := plat.file_stamp(doc.path)
			ok, size = st.ok, st.size
		}
		if !ok {
			app_note(app, "[REOPEN REFUSED - the file could not be measured, so its cost is unknown]")
			return
		}
		if size > reopen_transcode_max_bytes {
			app_note(
				app,
				fmt.tprintf(
					"[REOPEN REFUSED - re-decoding reads the whole file at once, and this one is over the %d MB limit]",
					reopen_transcode_max_bytes / (1024 * 1024),
				),
			)
			return
		}
	}
	if doc.modified {
		if !plat.confirm_reopen(w.hwnd if w != nil else nil, doc_display_name(doc), enc_name(enc)) {
			return
		}
	}
	if !doc_reload_forced(doc, enc) {
		app_note(app, "[REOPEN FAILED - the file could not be read]")
		return
	}
	app_note(app, fmt.tprintf("[REOPENED AS %s]", enc_name(enc)))
}

// Close a tab, prompting to save first if it has unsaved changes. Save-dialog
// cancel or a failed save aborts the close (keeps the tab).
request_close_tab :: proc(app: ^App, slot: int, w: ^plat.Window) {
	if slot < 0 || slot >= len(app.docs) || app.docs[slot] == nil {
		return
	}
	d := app.docs[slot]
	if d.modified {
		// `w.hwnd if w != nil` -- the pattern its neighbours in this file already
		// use (the lossy-encoding confirm, the reopen confirm). This one dereferenced
		// `w` directly, which every production caller satisfies and no test mode
		// does: driving it with a nil window and a dirty tab is an access violation,
		// which is how it was found.
		switch plat.confirm_discard(w.hwnd if w != nil else nil, doc_display_name(d)) {
		case .Cancel:
			return
		case .Save:
			p := d.path
			if p == "" {
				np, ok := plat.file_save_dialog(w.hwnd)
				if !ok {return}
				p = np
			} else {
				p = strings.clone(p, context.temp_allocator) // see .Save above
			}
			// Aborting the close is right — but say why, or the user sees the tab
			// simply refuse to close with no explanation and may force-quit.
			if !save_checked(app, d, p, w) {return}
		case .Discard:
		}
	}
	app_close(app, slot)
}

// The user overlay (keys.txt, see keymap.odin) is consulted FIRST; only a chord
// it does not mention falls through to default_bindings. The second return
// value is load-bearing: an overlay entry whose command is .None means the user
// unbound the chord, and returning .None *without* consulting the defaults is
// the only way that can work.
//
// keymap_lookup answers only for .Editor, so every other context reaches the
// defaults untouched by design (keymap.odin, rule 1).
@(private = "file")
lookup_binding :: proc(key: plat.Key, ctrl, alt: bool, ctx: Ctx) -> Command_Id {
	if cmd, found := keymap_lookup(key, ctrl, alt, ctx); found {
		return cmd
	}
	for b in default_bindings {
		if b.key == key && b.ctrl == ctrl && b.alt == alt && b.ctx == ctx {
			return b.cmd
		}
	}
	return .None
}

// May a chord the FIND context did not claim reach the editor keymap? Composed
// from command_mutates_doc rather than listing the buffer writers again, so the
// six chords of the Ctrl+V report are refused as a class rather than one at a
// time.
//
// BE PRECISE ABOUT WHICH CLASS. command_mutates_doc is the TABLE-VIEW READ-ONLY
// predicate -- "commands table view and Markdown Preview must block" -- and that
// set overlaps the buffer writers without being them. A writer added to it is
// refused here for free; a writer that has no reason to be on it is not, and two
// already exist: Ctrl+T (.Toggle_Table) and Ctrl+M (.Toggle_Preview) both reach a
// doc_replace_range through table_edit_commit (the .Toggle_Table arm below, and
// leave_table_view). Neither is on the predicate, so neither is refused here.
//
// That is benign and is left alone deliberately: what those two commit is the
// user's own cell text into the cell the user typed it in, which is the intended
// semantics of leaving the view, not a write behind an invisible caret. But it
// means this proc guarantees "no command table view blocks falls through", NOT
// "no command that writes the buffer falls through". Anyone adding a writer has to
// think about this proc; the composition does not do it for them.
//
// The two replace verbs are the exception, and they are the reason this is a
// predicate rather than `!command_mutates_doc`. Ctrl+Enter / Ctrl+Alt+Enter are
// declared in .Editor and NOT in .Find deliberately (see default_bindings), so
// the fallback is the ONLY way they reach the replace row -- the surface whose
// whole purpose is running them. Refusing them here would take Replace Match and
// Replace All off the keyboard everywhere they are meant to be pressed.
//
// They are also the safe exception rather than a hole: replace_dispatch writes
// through find_replace_current / find_replace_all, which act on the query's
// matches, and the .Find_Confirm arm carries its own doc_read_only_view refusal.
// Neither writes at doc.cursor, which is the invisible caret this refusal exists
// to keep out of reach.
@(private = "file")
find_fallback_writes_doc :: proc(cmd: Command_Id) -> bool {
	#partial switch cmd {
	case .Find_Replace_One, .Find_Replace_All:
		return false
	}
	return command_mutates_doc(cmd)
}

// Map a key press to a command within the active context (shift ignored here; the
// action reads it). First matching binding wins; a user overlay would prepend.
//
// Find falls back to the editor keymap for *modified* chords only. Without the
// fallback, opening the find bar killed every global chord — Ctrl+S, Ctrl+P,
// Ctrl+A, Ctrl+C, Ctrl+Z, Ctrl+N all resolved to nothing, which is what made
// Ctrl+A and Ctrl+P look broken. The ctrl/alt restriction is the important half:
// an unmodified fallback would send plain Delete to Delete_Fwd and the arrows to
// the caret, so typing a query would quietly edit and navigate the document.
// Unmodified keys stay owned by the mode.
//
// The palette does not fall back at all: it is a text field first, and every
// printable key belongs to its query.
resolve_key :: proc(key: plat.Key, ctrl, alt: bool, ctx: Ctx) -> Command_Id {
	if cmd := lookup_binding(key, ctrl, alt, ctx); cmd != .None {
		return cmd
	}
	// The menu falls back for the same reason find does — a global chord should
	// not die because a dropdown happens to be open. The palette is the one true
	// exception, being a text field.
	//
	// The find bar is a text field too, and the fallback above gave it every
	// MODIFIED editor chord including the ones that write to the buffer. That is
	// the whole of the Ctrl+V report (Wyatt, 2026-07-29) and it was never only
	// about paste: with the query focused, Ctrl+X cut the document's selection,
	// Ctrl+Z/Ctrl+Y undid and redid the document, Ctrl+Backspace deleted a word
	// behind an invisible caret and Alt+Up/Down moved document lines -- all of
	// them under a bar whose viewport takes no keystrokes, so nothing typed there
	// could be taken back without closing the bar first. Refuse the fallback for
	// the writers; the reads (Ctrl+S, Ctrl+P, Ctrl+A, Ctrl+C, the tab chords) are
	// exactly why the fallback exists and are untouched.
	//
	// The menu is deliberately NOT covered: it is a dropdown, not a field, the
	// document behind it is still the focused surface, and is_menu_cmd's caller
	// closes the menu before the command runs.
	if ctx == .Find && (ctrl || alt) {
		cmd := lookup_binding(key, ctrl, alt, .Editor)
		if find_fallback_writes_doc(cmd) {return .None}
		return cmd
	}
	if ctx == .Menu && (ctrl || alt) {
		return lookup_binding(key, ctrl, alt, .Editor)
	}
	// The history panel is a side panel, not a mode: it owns only its navigation
	// keys and everything else still edits the document. It has no text field, so
	// there is no reason for it to swallow Backspace or the other editing keys.
	if ctx == .History {
		return lookup_binding(key, ctrl, alt, .Editor)
	}
	return .None
}

// What one key event resolves to, before command_dispatch runs it.
Key_Route :: struct {
	cmd:      Command_Id, // .None when nothing is bound, or when the cell editor took it
	// UNDEFINED WHEN `consumed`. The cell-edit arms return before a context is
	// chosen, and Ctx's zero value is .Editor -- so a consumed key reads as an
	// editor route and is indistinguishable from a real one. Nothing reads it in
	// that case today; a test asserting `.ctx == .Editor` on an intercepted key
	// would be a guaranteed green that means nothing.
	ctx:      Ctx,
	consumed: bool, // the cell editor handled it; the caller must not dispatch
}

// Everything the frame loop does with a key event except run it. Lifted out of
// main.odin's loop body on 2026-08-05; the loop is now `key_route` + `continue`
// on consumed + `command_dispatch`.
//
// THE REASON IS A TEST, not tidiness. §6ct fixed an Alt reveal that stuck for the
// whole session on the Settings and Font pages -- those contexts outrank .Menu
// below, so after an Alt tap no later key was ever routed to .Menu and nothing
// reached menu_close. Its test could only drive menu_close directly, which pins
// what the exit DOES and not that the loop REACHES it, and reaching it was the
// bug. The exit lives in the menu subsystem; the thing deciding whether the menu
// subsystem sees a key at all lived inline in a frame loop no mode can call.
//
// So this performs the menu_close calls rather than returning "the caller should
// close the menu": a decision here and its effect back in main.odin would rebuild
// the exact seam §6ct came from. A test asserting app.menu.revealed after this
// returns proves the chain; a test asserting a returned bool proves the decision
// and nothing about the wiring.
//
// It takes no ^plat.Window and no ^plat.Text, which is what makes it reachable
// from a headless mode with only an App and a Document -- every callee on these
// paths is app/doc-only. command_dispatch is what needs the window, and it stays
// in the loop.
//
// `doc` is a parameter rather than app_active(app) because the frame loop
// captures it once per frame and re-reads it only AFTER the key loop, while the
// .Find arm below reads app_active(app).find.active fresh. That asymmetry is
// preserved exactly: this was an extraction, not a fix. It means two key events
// in one frame across a Ctrl+Tab resolve the second one's context from the
// PREVIOUS document's kind. Pre-existing, rare, and now in one place if it is
// ever worth changing.
key_route :: proc(app: ^App, doc: ^Document, ev: plat.Key_Event, trows: int) -> Key_Route {
	// A cell edit in the table grid owns the editing keys (a mini text field),
	// before they resolve to editor commands. Enter/Tab commit, Esc cancels; Tab
	// then steps to the next cell on the same row.
	if doc.table && doc.table_editing && !ev.ctrl && !ev.alt {
		#partial switch ev.key {
		case .Backspace:
			table_edit_backspace(doc)
			return {consumed = true}
		case .Delete:
			table_edit_delete(doc)
			return {consumed = true}
		case .Left:
			table_edit_move(doc, -1)
			return {consumed = true}
		case .Right:
			table_edit_move(doc, 1)
			return {consumed = true}
		case .Home:
			table_edit_home(doc)
			return {consumed = true}
		case .End:
			table_edit_end(doc)
			return {consumed = true}
		case .Escape:
			table_edit_cancel(doc)
			return {consumed = true}
		case .Enter:
			table_edit_commit(doc)
			return {consumed = true}
		case .Tab:
			// COMMITS WITHOUT REORDERING, and `next_row` is why as much as
			// the feel is: it is a VISIBLE row index, captured here and
			// consumed after the commit, so a commit that re-sorted would
			// leave it naming a different row entirely -- an index read in
			// an order it was not taken in, which is the shape
			// development-loop §4 calls Shape B. Tab means "the next cell in
			// this row"; the row moves when it is left for good, by Enter or
			// by a click elsewhere.
			next_row, next_col := doc.table_edit_row, doc.table_edit_col + 1
			table_edit_commit(doc, resort = false)
			if ok, r, col, fs, fe, val := table_cell_at_index(doc, next_row, next_col, trows); ok {
				table_edit_start(doc, r, col, fs, fe, val)
			}
			return {consumed = true}
		case:
		}
	}
	// Context is per-event; palette/find/menu/tab-switch can change it
	// mid-loop. Priority: menu > palette > find > editor.
	ctx := Ctx.Editor
	if doc.kind == .Font {
		ctx = .Font
	} else if doc.kind == .Settings {
		ctx = .Settings
	} else if app.history.open {
		ctx = .History
	} else if menu_is_active(app) {
		ctx = .Menu
	} else if app.palette.active {
		ctx = .Palette
	} else if app_active(app).find.active {
		ctx = .Find
	}
	cmd := resolve_key(ev.key, ev.ctrl, ev.alt, ctx)
	// A global chord taken while the menu is open should close it first.
	if ctx == .Menu && cmd != .None && !is_menu_cmd(cmd) {
		menu_close(app)
	}
	// ...and a key that routed SOMEWHERE ELSE ENTIRELY ends an Alt reveal.
	//
	// The reveal is cleared by menu_close, and every dismissal used to reach it
	// -- but .Font and .Settings outrank .Menu in the priority above, so on
	// those pages an Alt tap revealed the bar and then NO later key was ever
	// routed to .Menu to close it. The bar stayed down for the rest of the
	// session, holding the content 30px lower, on a page where Alt has nothing
	// to reach. Focus loss was the only way out.
	//
	// Written as "any key not going to the menus" rather than "not on the
	// settings page": the bug was one instance of a class, and naming the two
	// contexts that outrank .Menu today would go stale the moment a third
	// full-page surface is added.
	if ctx != .Menu && app.menu.revealed {
		menu_close(app)
	}
	return {cmd = cmd, ctx = ctx}
}

// block_extend (block.odin) takes no ^App -- that file has never imported
// the App type, keeping its layering the same as before this feature -- so
// the one caller that has `app` in scope turns a refusal into the status
// note here instead. Shared by every Block_Extend_* dispatch case and the
// two Move_Line_Up/Down branches below, so the message can't drift between
// call sites.
@(private = "file")
block_extend_dispatch :: proc(app: ^App, doc: ^Document, t: ^plat.Text, dline, dcell: int) {
	switch block_extend(doc, t, dline, dcell) {
	case .Wrap_On:
		app_note(app, "[COLUMN SELECT NEEDS WRAP OFF - press Alt+Z]")
	case .Split_On:
		app_note(app, "[COLUMN SELECT NEEDS SPLIT OFF - press Ctrl+M]")
	case .Filter_On:
		app_note(app, "[COLUMN SELECT UNAVAILABLE - TURN OFF FILTER]")
	case .Caret_Unresolved:
		app_note(app, "[COLUMN SELECT UNAVAILABLE HERE - the line is too far into a very large file]")
	case .None:
	}
}

// The single path for both replace verbs, from every surface that can run them:
// the two buttons on the replace row, the palette, and Ctrl+Enter /
// Ctrl+Alt+Enter (which reach here from the document as well as from the bar,
// because resolve_key falls Find back to the editor keymap for modified chords).
//
// The opening guard is the one that matters. Run from the palette with find
// SHUT, there is no query and f.matches is nil, and doc.search.done has never
// been set -- so find_replace_all would return (0, complete=false) and the
// caller below would put up a modal warning that a file it never looked at may
// have more matches. Opening the replace bar instead answers the only question
// the user can actually be asked at that point, which is "replace what, with
// what". Same for an empty query: the bar is the answer, not a dialog.
@(private = "file")
replace_dispatch :: proc(app: ^App, doc: ^Document, w: ^plat.Window, all: bool) {
	if doc == nil {return}
	if !doc.find.active || !doc.find.replace_mode || len(doc.find.query) == 0 {
		find_open(doc, true)
		return
	}
	if !all {
		find_replace_current(doc)
		return
	}
	replaced, complete := find_replace_all(doc)
	// Say so when the pass could not have seen the whole document. The
	// alternative -- replacing a prefix in silence -- looks exactly like
	// replacing everything, so a half-finished rename reads as a finished one
	// until something downstream breaks.
	if !complete {
		plat.message_error(
			w.hwnd if w != nil else nil,
			fmt.tprintf(
				"Replaced %d occurrence(s).\n\nThe search had not finished scanning the file, or there were more matches than Newtpad tracks at once, so there may be more.\n\nRun Replace All again to continue.",
				replaced,
			),
		)
		return
	}
	// A completed Replace All that matched nothing changes no pixel, so without
	// this the button reads as broken -- the same argument sort_lines_dispatch's
	// .Unchanged note makes. The success count is worth saying too: the whole
	// complaint behind this feature was a row that never told you anything.
	if app != nil {
		app_note(app, "[NO MATCHES TO REPLACE]" if replaced == 0 else fmt.tprintf("[REPLACED %d OCCURRENCE(S)]", replaced))
	}
}

// The one note every rectangle-wide EDIT refusal posts. block_replace and
// block_delete refuse for exactly the two reasons the copy and the cut already
// refuse for -- an unresolvable row, or a rectangle deeper than
// BLOCK_EDIT_MAX_LINES -- and the row count is read off the constant rather
// than written out, because it has already moved once (10,000 -> 2,000) and a
// literal would have drifted silently.
//
// The refusal is the whole edit or none of it: block_apply leaves the buffer
// byte-identical, so this note is the only thing that happened.
@(private = "file")
block_edit_note :: proc(app: ^App) {
	app_note(app, fmt.tprintf("[COLUMN EDIT REFUSED - a row could not be read, or the rectangle spans more than %d rows]", BLOCK_EDIT_MAX_LINES))
}

// The note for all three of Sort Lines / Sort Lines Descending / Remove
// Duplicate Lines, in one place for the reason block_edit_note is: three copies
// of a refusal message drift, and the cap is read off the constant rather than
// written out because BLOCK_EDIT_MAX_LINES has already moved once and a literal
// would have gone stale silently.
//
// The .Unchanged note is not decoration. The user has just picked these by name
// -- from the palette, or from Edit's text-operations group -- so with nothing to
// do and nothing said, the command reads as broken; the same argument
// .Bookmark_Cycle's "[NO BOOKMARKS]" makes. And .Unchanged specifically means NO
// undo entry was pushed (doc_sort_lines returns before doc_batch_begin), so
// there is not even a history row to notice.
//
// (This note used to say "all three commands are palette-only". They stopped
// being palette-only when they got menu rows, per ui-spec 7's "every command in
// it is also in a menu" -- the argument survives the change, the premise did not.)
@(private = "file")
sort_lines_dispatch :: proc(app: ^App, doc: ^Document, mode: Sort_Mode) {
	// Name the command the user actually ran. A single shared "[SORT ...]" told
	// someone who had just run Remove Duplicate Lines that a SORT was refused --
	// an operation they never asked for, in a product where the note bar is the
	// only feedback a palette-only command has.
	what := "DEDUPE" if mode == .Dedupe else "SORT"
	// A rectangle is a COLUMN; these three commands only speak rows. Refuse
	// rather than guess -- "sort the rectangle's rows by their whole-line
	// content" and "sort them by the cells the rectangle actually covers" are
	// both honest readings of the same gesture, and principle 3's answer to an
	// operation with two meanings is to offer neither. BLOCK_EDIT_MAX_LINES'
	// refusal has the same shape, and adding a chord or a row-span variant later
	// is a change to this one branch.
	//
	// Without this the escalation was the largest on the command_mutates_doc
	// list: the block-clear branch in command_dispatch runs block_collapse_linear
	// (`doc.anchor = doc.cursor`) for every mutating command not on its exception
	// list, so doc_sort_lines saw !doc_has_sel and sorted the WHOLE FILE. Five
	// column-selected rows of a 200k-line log reordered the lot and dropped every
	// bookmark in it. The three commands are on that exception list now, which is
	// what lets this refusal be reached at all.
	//
	// Leave the rectangle live, exactly like every other block refusal
	// (block_extend's own comment in block.odin makes this an invariant): a
	// refusal that also destroys the gesture's state costs the user the selection
	// they spent the drag making, for nothing.
	if doc != nil && block_active(doc) {
		app_note(app, fmt.tprintf("[%s UNAVAILABLE - column selection is live; press Escape first]", what))
		return
	}
	switch doc_sort_lines(doc, mode) {
	case .Ok:
	// The document visibly changed; a note would be noise.
	case .Unchanged:
		if doc != nil && doc.kind == .Text {
			app_note(app, "[NO DUPLICATE LINES]" if mode == .Dedupe else "[ALREADY SORTED]")
		}
	case .Too_Big:
		// Short enough to read at a glance. The old wording explained the
		// implementation ("read and rewritten in one go") in 110 characters; what
		// the user can act on is the two numbers.
		app_note(app, fmt.tprintf("[%s REFUSED - over the %d MB / %d line limit]", what, SORT_MAX_BYTES / (1024 * 1024), SORT_MAX_LINES))
	case .Unresolved:
		app_note(app, fmt.tprintf("[%s UNAVAILABLE HERE - a line runs longer than it can scan]", what))
	case .Faulted:
		// The file changed on disk mid-read. main.odin's recovery detaches from
		// the mapping at the end of this frame and prints its own line; say here
		// that the command did not run, because from the user's side it simply
		// did nothing.
		app_note(app, fmt.tprintf("[%s REFUSED - the file changed on disk while it was being read]", what))
	}
}

// The typed-character path when a rectangle is live: one character replaces the
// rectangle's cell range on every row it spans (or, at zero width, is inserted
// on every row -- prefixing a column). main.odin's char loop calls this instead
// of doc_insert_rune so the choice lives beside the Backspace/Delete cases that
// make the same one, and so a headless test can drive the real decision rather
// than a copy of it.
//
// Control characters never reach here (the platform char path filters them), so
// there is no newline case to worry about: Enter is .Insert_Newline, which
// drops the rectangle with every other block-unaware mutating command below.
editor_input_rune :: proc(app: ^App, doc: ^Document, t: ^plat.Text, r: rune) {
	if block_active(doc) {
		buf, n := utf8.encode_rune(r)
		if !block_replace(doc, t, buf[:n]) {block_edit_note(app)}
		return
	}
	doc_insert_rune(doc, r)
}

// Run a command. `rows` is the visible row count (page moves); `w` supplies the
// HWND for clipboard / Save-dialog. The active-context split means each command
// is unambiguous here.
// Commands that write to the document buffer. Table view blocks every one of
// them (see the guard in command_dispatch): the grid is read-only text and the
// only writes are the controlled cell-edit splice (table_edit_commit).
command_mutates_doc :: proc(cmd: Command_Id) -> bool {
	#partial switch cmd {
	case .Backspace, .Delete_Fwd, .Delete_Word_Back, .Insert_Newline, .Insert_Tab, .Undo, .Redo, .Cut, .Paste,
	     .Move_Line_Up, .Move_Line_Down,
	     // One replace over a whole-line region -- the same kind of edit
	     // Alt+Up/Down already is, and for the same reasons it has to be listed
	     // here: table view must block it (the grid is read-only and a caret left
	     // over from text view would rewrite the file underneath it), and a live
	     // column rectangle has to be seen at all -- these three are the one entry
	     // on this list that REFUSES under a rectangle rather than dropping it,
	     // and they only get the chance because membership here is what routes
	     // them through the block branch in command_dispatch.
	     .Sort_Lines, .Sort_Lines_Desc, .Remove_Duplicate_Lines:
		return true
	// Changing the line ending rewrites the ENTIRE buffer -- doc_set_line_ending
	// does pt_delete(0, length) followed by pt_insert -- so every line start after
	// the first moves by one byte per preceding line. Nothing looks like an edit
	// less and few things are a bigger one. Left out, both guards below missed it:
	// a live rectangle kept byte offsets naming rows that had shifted (Alt+drag,
	// Encoding > CRLF, Ctrl+X cut bytes the user never saw highlighted), and an
	// in-progress table cell edit kept a captured byte span that table_edit_commit
	// would then splice at the wrong place. Same shape as the find_replace_all and
	// Toggle_Table holes fixed in earlier batches.
	case .Eol_LF, .Eol_CRLF:
		return true
	// Same class one level up: jumping to a history state is apply_snapshot ->
	// pt_restore, a whole-tree replacement, exactly what .Undo and .Redo above are.
	// It was missed for the same reason -- it does not look like an edit. The
	// rectangle is not what this protects (apply_snapshot clears one itself); the
	// TABLE guard is. Edit > Undo History is enabled on any document, a click in
	// the menu bar lands above CONTENT_TOP so an in-progress cell edit is never
	// committed on the way, and without this the panel then rewrites the buffer
	// under a captured cell span that table_edit_commit will splice into.
	case .History_Jump:
		return true
	// Both write to the buffer, and unlike .Find_Confirm -- which is find_next in
	// the search field and a replace in the replace field, so it can be neither
	// on this list nor off it -- these two mean one thing wherever they are run
	// from. Membership is what gets them the read-only-view refusal and the
	// stale-rectangle drop at the top of command_dispatch; the find procs clear a
	// live rectangle themselves as well (find.odin explains why that belt is
	// worth its braces), so the guard here is additive, not a substitute.
	case .Find_Replace_One, .Find_Replace_All:
		return true
	}
	return false
}

// The header menu's six sort rows (menu.odin's table_header_menu_items): do
// they take their target from the menu that opened them rather than from any
// state of their own? All six read app.menu.ctx_col, the column the menu was
// opened on, and there is no persistent "current column" in the table view to
// fall back on -- table_edit_col exists, but only while a cell is being
// edited, and none of the six consult it. A binding that fires outside that
// menu therefore has no column to name.
//
// command_from_name (keymap.odin) consults this to refuse a hand-written
// keymap line naming one of these six -- see its comment. A seventh command
// with the same shape gets the same refusal by being added to this switch,
// not by a second list somewhere else.
// Rows whose click does NOT dismiss the dropdown they were clicked in.
//
// A menu closing on every click is right for a command and wrong for a
// multi-select: the column filter's rows are checkboxes, and ticking one, having
// the list vanish and reopening it to tick a second is not a gesture anyone would
// design. Escape and a click outside still close it, which is how every
// multi-select popup behaves.
//
// Deliberately a short, named list rather than a flag on Menu_Item: staying open
// is a property of what the command DOES, and a row that stayed open by accident
// -- a flag someone copied onto a new item -- would be a menu that will not go
// away.
command_keeps_menu_open :: proc(cmd: Command_Id) -> bool {
	#partial switch cmd {
	case .Table_Filter_Toggle, .Table_Filter_All:
		return true
	}
	return false
}

command_needs_menu_target :: proc(cmd: Command_Id) -> bool {
	#partial switch cmd {
	case .Table_Sort_Asc, .Table_Sort_Desc, .Table_Sort_Then_Asc, .Table_Sort_Then_Desc,
	     .Table_Sort_Remove, .Table_Sort_Clear:
		return true
	// The tab menu's four act on app.menu.ctx_tab, which only a menu sets, so a
	// keymap line naming one of them has no target and must be refused the same way.
	case .Tab_Reveal, .Tab_Copy_Path, .Tab_Close_This, .Tab_Close_Others:
		return true
	// The filter's rows act on app.menu.ctx_col and on a row payload, neither of
	// which a keymap chord can supply.
	case .Table_Filter_Open, .Table_Filter_Toggle, .Table_Filter_All, .Table_Filter_Clear:
		return true
	}
	return false
}

// May `cmd` run against `doc`? The single answer to that question, and both
// routes to a command consult it: the menu greys the row out (item_enabled,
// menu.odin) and command_dispatch refuses outright.
//
// One predicate rather than one per route, because the routes are not equal.
// Settings and Font are TABS, not overlays, so app_active returns a Document for
// them -- a pseudo-document with no file, no encoding and no line endings. This
// rule used to live entirely in the `menus` table, as a per-row `enabled`
// predicate, and the command palette walked straight past it: palette_execute
// calls command_dispatch directly and consults no row, the palette draws OVER
// the Settings page, and palette_click runs before the pseudo-tab mouse-swallow
// in main.odin. So Settings -> View > Command Palette > Paste did the exact
// thing the menu gate was added to stop: the clipboard landed in a buffer
// nothing draws, the pseudo-tab went .modified, and closing it raised a
// save-changes dialog for a page with no file. A rule enforced at one of two
// entry points is not enforced.
//
// Composed from command_mutates_doc rather than listing the buffer writers a
// second time, so a mutating command added there is gated here for free. The
// three extras are not buffer writes: Save/Save_As put the empty pseudo-buffer
// through a Save dialog, and Enc_* sets doc.modified without touching the text.
//
// A nil document answers "allowed": whether a command needs a document at all is
// the row's own business (has_doc and friends in menu.odin), and the dispatch
// arms that can meet a nil doc already handle one. This proc answers only the
// question the two routes disagreed about -- what KIND of document it is.
command_allowed_on :: proc(cmd: Command_Id, doc: ^Document) -> bool {
	if doc == nil || doc.kind == .Text {return true}
	if command_mutates_doc(cmd) {return false}
	#partial switch cmd {
	case .Save, .Save_As, .Enc_UTF8, .Enc_UTF16LE, .Enc_CP1252:
		return false
	}
	return true
}

// Leave the grid, doing everything .Toggle_Table's own off-branch does rather
// than assigning the field. A dangling cell edit holds a byte span captured
// before whatever happens next, and table_edit_commit is the only thing that
// closes it (it splices, drops the rectangle and refits); the widths go so the
// next turn-on measures the content as it then is. Used by .Toggle_Preview,
// which must turn the grid off because the two views are mutually exclusive.
@(private = "file")
leave_table_view :: proc(doc: ^Document) {
	if !doc.table {return}
	// No reorder: the sort is cleared a few lines below, and reordering a grid the
	// user is in the act of leaving would be work nobody ever sees.
	if doc.table_editing {table_edit_commit(doc, resort = false)}
	doc.table = false
	clear(&doc.table_widths)
	// The sort is a property of the VIEW, not of the document: leaving the grid
	// leaves the file's own order, and doc.top is already a real line offset (the
	// invariant Table_Sort's block comment exists to hold), so the text view opens
	// on whatever row was at the top of the sorted screen. Cleared AFTER the commit
	// above, which needs the permutation to resolve its own row.
	table_sort_clear(doc);table_filter_clear(doc)
}

// Was this command invoked BY NAME -- a palette row, a menu row, a status-bar
// cell, a find-bar button -- rather than by pressing its chord?
//
// The discriminator is Key.None, which is zero (platform/window.odin) and which
// the keyboard can never deliver: the message pump translates the VK code first
// and drops the event outright when vk_to_key returns .None, so nothing with a
// .None key is ever queued. So main.odin's key drain and .Menu_Activate (which
// forwards the Enter that activated the row) always carry a real key, while
// every by-name route dispatches a zero Key_Event -- palette_execute
// (palette.odin), and main.odin's menu hit-test, status-bar cell and find-bar
// button/mode chip. That already made ev.key the thing telling the two routes
// apart; this only gives it a name, so an arm can say which one it means.
//
// What it is FOR: an arm gated on a modifier in order to preserve what the BARE
// chord does must not apply that gate to a named invocation. A bare Alt+Left has
// to keep doing nothing, exactly as an unbound key does -- but a user who found
// "Extend Column Selection Left" in the palette and pressed Enter on it has
// already said what they want, and there is no bare chord to protect. Without
// this the command was listed, matched, highlighted, run, and did nothing.
//
// NOT a general "was a modifier held" question. An arm that reads ev.shift as a
// DIRECTION (.Bookmark_Cycle, .Tab_Next, .Find_Confirm, the cursor moves) is
// already right without it -- unshifted means forward, and forward is what a
// named invocation should do. Only an arm whose non-modifier path is EMPTY has
// the shape this fixes; as of this writing that is .Block_Extend_Left and
// .Block_Extend_Right and nothing else.
command_named :: proc(ev: plat.Key_Event) -> bool {return ev.key == .None}

command_dispatch :: proc(cmd: Command_Id, ev: plat.Key_Event, app: ^App, w: ^plat.Window, t: ^plat.Text, rows: int) {
	if cmd != .None {diag_cmd(cmd)} // breadcrumb: what the user was doing
	// Recency for the palette's tie-break. Recorded at the one point every route
	// to a command converges, so a command run from a MENU teaches the palette
	// exactly as one run from the palette does.
	if cmd != .None && app != nil {
		app.cmd_clock += 1
		app.cmd_used[cmd] = app.cmd_clock
	}
	doc := app_active(app)
	// The document-kind gate, ahead of every other guard: it is the one rule the
	// menu and the palette have to agree on, and this is the point both of them
	// reach. Silent, exactly like the greyed-out menu row it mirrors -- there is
	// no note to show, because on a pseudo-tab there is no document the user
	// meant this for.
	if !command_allowed_on(cmd, doc) {return}
	// A rendered view is read-only. Block every document-mutating command so a
	// caret left over from text view can't silently corrupt the file at an
	// unrelated offset, and so an in-cell edit's captured byte span can't be
	// invalidated under it by an undo/paste before it commits. Cell editing has
	// its own key path (intercepted before dispatch); the only buffer write in
	// table view is table_edit_commit's single-field splice.
	//
	// doc_read_only_view (doc.odin), not `doc.table`: this guard used to name the
	// grid directly and so never covered the full Markdown Preview, which is
	// documented read-only (markdown.odin) and draws no caret -- Backspace,
	// Enter, Tab, Paste, Cut, Undo and the whole-buffer line-ending rewrite all
	// ran against an invisible caret in the rendered view. Wyatt, live use,
	// 2026-07-28.
	if doc_read_only_view(doc) && command_mutates_doc(cmd) {return}
	// A live rectangle is only meaningful to the handful of commands that know
	// about it. Every OTHER document-mutating command edits at doc.cursor
	// through a path that writes doc.cursor directly rather than via set_cursor
	// (doc_insert_text, doc_move_lines), so the block_clear set_cursor performs
	// on an ordinary caret move never runs -- and the rectangle is left holding
	// byte offsets describing rows the edit has since moved. A following Ctrl+X
	// would then cut bytes the user never saw highlighted, which is the one
	// outcome this whole feature is built to make impossible. Drop the
	// rectangle first; the edit itself is unchanged.
	//
	// The exceptions handle it themselves: Backspace/Delete_Fwd edit the
	// rectangle, Cut clears it in block_cut_delete, Undo/Redo clear it in
	// apply_snapshot (doc.odin) because a restored tree may not have the rows
	// at all, and Insert_Tab -- Wyatt's call -- edits the rectangle exactly
	// like a typed character does (see the .Insert_Tab case below) rather
	// than clearing it and falling through to a single tab at the caret.
	// Insert_Newline stays OUT of this exception list deliberately: splitting
	// every spanned row from one Enter is rarely what's wanted, so Enter
	// keeps clearing the rectangle and acting at the caret.
	//
	// Sort_Lines / Sort_Lines_Desc / Remove_Duplicate_Lines are on the list for
	// the opposite reason to the rest of it: not because they edit the rectangle,
	// but because the collapse this branch performs is what made them dangerous.
	// Every other command here acts at the caret or on one line, so flattening the
	// selection first costs a line at worst; these three read the selection as
	// their SCOPE, so a collapsed selection silently promoted them to the whole
	// document. They refuse in sort_lines_dispatch instead, and reaching that
	// refusal with the rectangle intact is the whole point of the exception.
	if doc != nil && block_active(doc) && command_mutates_doc(cmd) {
		#partial switch cmd {
		case .Backspace, .Delete_Fwd, .Cut, .Undo, .Redo, .Insert_Tab,
		     .Sort_Lines, .Sort_Lines_Desc, .Remove_Duplicate_Lines:
		case:
			block_clear(doc)
			// Belt and braces for the invariant block_collapse_linear
			// (block.odin) establishes at the other end: nothing may leave a
			// linear selection live underneath a rectangle, because the
			// rectangle is what was DRAWN and this branch is exactly where
			// the command that follows (.Insert_Newline, .Paste,
			// .Delete_Word_Back, .Move_Line_*) would run against
			// doc.anchor..doc.cursor and delete it. With the gestures now
			// collapsing on success this is unreachable, which is the point:
			// if a future selection path forgets, the damage stops here
			// rather than reaching doc_insert_text.
			block_collapse_linear(doc)
		}
	}
	switch cmd {
	// --- editor ---
	case .Cursor_Left:
		doc_cursor_left(doc, ev.shift)
	case .Cursor_Right:
		doc_cursor_right(doc, ev.shift)
	case .Cursor_Up:
		doc_cursor_up(doc, t, ev.shift)
	case .Cursor_Down:
		doc_cursor_down(doc, t, ev.shift)
	case .Cursor_Home:
		doc_cursor_home(doc, ev.shift)
	case .Cursor_End:
		doc_cursor_end(doc, ev.shift)
	case .Word_Left:
		doc_word_left(doc, ev.shift)
	case .Word_Right:
		doc_word_right(doc, ev.shift)
	case .Page_Up:
		doc_scroll(doc, t, -(rows - 1), rows)
	case .Page_Down:
		doc_scroll(doc, t, rows - 1, rows)
	case .Backspace:
		// A live rectangle takes priority, exactly as it does for Copy and Cut
		// below. At zero width it is N carets and this deletes one cell to the
		// left of every one of them; with width it deletes the rectangle.
		if block_active(doc) {
			if !block_delete(doc, t, false) {block_edit_note(app)}
		} else {
			doc_backspace(doc)
		}
	case .Delete_Fwd:
		if block_active(doc) {
			if !block_delete(doc, t, true) {block_edit_note(app)}
		} else {
			doc_delete_fwd(doc)
		}
	case .Delete_Word_Back:
		doc_delete_word_back(doc)
	case .Insert_Newline:
		// Deliberate choice, not an oversight: a live rectangle is cleared
		// above (command_mutates_doc's block-clear branch) rather than
		// routed through block_replace the way .Insert_Tab now is --
		// splitting every spanned row into two from one Enter is rarely what
		// the user wants, unlike indenting them.
		doc_insert_newline(doc)
	case .Insert_Tab:
		// Tab arrives as WM_CHAR 0x09 too, but the char path filters control
		// characters, so the binding is what actually inserts it. A live
		// rectangle routes through block_replace exactly like a typed
		// character does in editor_input_rune -- one tab on every spanned row
		// (or, at zero width, one tab at each of N carets) -- so Tab inherits
		// everything already proven about block_replace/block_apply: bottom-
		// up ordering, one undo step for the whole rectangle, the
		// BLOCK_EDIT_MAX_LINES row cap, and virtual-space padding on rows
		// shorter than the rectangle's left edge. Wyatt's call (asked and
		// answered): this is what VS Code and Sublime do, and it is the
		// natural companion to the existing prefix-typing behaviour.
		if block_active(doc) {
			if !block_replace(doc, t, []u8{'\t'}) {block_edit_note(app)}
		} else {
			doc_insert_rune(doc, '\t')
		}
	case .Doc_Start:
		doc_start(doc, ev.shift)
	case .Doc_End:
		doc_end(doc, ev.shift)
	case .Undo:
		doc_undo(doc)
	case .Redo:
		doc_redo(doc)
	case .Select_All:
		// The preview owns Ctrl+A whenever it is the pane being read. Only one
		// selection is ever live (doc.md_sel_on), so this is a check rather than a
		// contest between two highlights.
		if doc != nil && doc.kind == .Text && doc.md_mode == .Preview {
			md_preview_select_all(doc)
			doc.anchor = doc.cursor // drop the editor's, per the one-selection rule
		} else {
			doc_select_all(doc)
		}
	case .Copy:
		// A live PREVIEW selection takes priority, and can only be live when the
		// editor's is not -- taking either one clears the other, so there is never
		// a question of which highlight Ctrl+C meant (Wyatt, 2026-08-02).
		if doc != nil && doc.md_sel_on {
			if rc := active_render_ctx; rc != nil && rc.window != nil {
				if s, sok := md_preview_sel_text(rc.gfx, t, doc, rc.px, f32(rc.window.width), f32(rc.window.height), app.settings.split_frac); sok && s != "" {
					plat.clipboard_set_text(w.hwnd, s)
				} else {
					// Loud rather than a silent no-op: the only way this fails is
					// the MD_COPY_MAX refusal, and a Ctrl+C that quietly does
					// nothing reads as a broken clipboard.
					app_note(app, "[SELECTION TOO LARGE TO COPY]")
				}
			}
			return
		}
		// A live rectangle takes priority over the linear selection: the two
		// are mutually exclusive in practice, but block_active is the flag
		// that means "the user is column-selecting", the same predicate
		// block_selection_rects uses to pick between the two draws.
		if block_active(doc) {
			if s, ok := block_text(doc, t); ok {
				if s != "" {plat.clipboard_set_text(w.hwnd, s)}
			} else {
				// Refuse rather than put a partial rectangle on the
				// clipboard while reporting success -- either a row could
				// not be resolved, or the rectangle spans more than
				// BLOCK_EDIT_MAX_LINES rows (block_text, block.odin).
				app_note(app, fmt.tprintf("[COLUMN COPY REFUSED - a row could not be read, or the rectangle spans more than %d rows]", BLOCK_EDIT_MAX_LINES))
			}
		} else if s := doc_selected_text(doc, context.temp_allocator); s != "" {
			plat.clipboard_set_text(w.hwnd, s)
		}
	case .Cut:
		if block_active(doc) {
			if s, ok := block_text(doc, t); ok {
				// block_cut_delete runs even when s == "" (a single
				// all-short row has nothing to copy) -- it always clears
				// the block on a non-refusal, empty rectangle or not, so a
				// Cut collapses the rectangle to a caret the same way every
				// other path does. Gating the delete on s != "" left an
				// all-short single-row rectangle live after Cut (block.odin,
				// block_cut_delete's own comment).
				if s != "" {plat.clipboard_set_text(w.hwnd, s)}
				if !block_cut_delete(doc, t) {
					// Refuses only if something changed between block_text's
					// own check above and this call -- report it rather than
					// silently leaving the clipboard write (if any) as the
					// only visible effect of a Cut that deleted nothing.
					app_note(app, fmt.tprintf("[COLUMN CUT REFUSED - a row could not be read, or the rectangle spans more than %d rows]", BLOCK_EDIT_MAX_LINES))
				}
			} else {
				app_note(app, fmt.tprintf("[COLUMN CUT REFUSED - a row could not be read, or the rectangle spans more than %d rows]", BLOCK_EDIT_MAX_LINES))
			}
		} else if s := doc_selected_text(doc, context.temp_allocator); s != "" {
			// Delete ONLY if the copy actually landed. A Cut whose clipboard write
			// failed used to delete the selection anyway, so the text existed in
			// neither place -- data loss on a path as ordinary as another app
			// holding the clipboard for a moment, or a stray high byte making the
			// UTF-16 conversion refuse.
			if plat.clipboard_set_text(w.hwnd, s) {
				doc_backspace(doc) // deletes the selection
			} else {
				app_note(app, "[CUT FAILED - the clipboard could not be written; nothing was deleted]")
			}
		}
	case .Paste:
		if s, ok := plat.clipboard_get_text(w.hwnd, context.temp_allocator); ok {
			// The Windows clipboard is CRLF by convention, so pasting into an LF
			// file mixed the endings silently -- through the most common way
			// multi-line text enters a buffer. Copy and Cut are deliberately NOT
			// converted: what leaves the document is what the document holds, and
			// rewriting on the way out would corrupt a paste into another editor.
			norm := base.convert_line_endings(transmute([]u8)s, doc.eol, context.temp_allocator)
			doc_insert_text(doc, norm)
		}
	case .Save:
		p := doc.path
		if p == "" {
			if np, ok := plat.file_save_dialog(w.hwnd); ok {
				p = np
			}
		} else {
			// doc_save_err frees doc.path (doc.odin), and p aliases that buffer on a
			// re-save -- so report_save formatted freed memory, on the most-used
			// command, and worst on the failure path: the dialog whose whole job is
			// naming the file that would not save is the one reading it. Give p the
			// same lifetime the dialog branch already has.
			p = strings.clone(p, context.temp_allocator)
		}
		if p != "" {
			save_checked(app, doc, p, w)
		}
	case .Save_As:
		if p, ok := plat.file_save_dialog(w.hwnd); ok {
			save_checked(app, doc, p, w)
		}
	case .Find_Open:
		// Ctrl+F means "search", including as the way out of filter view (Ctrl+L):
		// pressing it while filtering used to hit Find_Close and drop to the
		// viewport instead of switching to the normal search. Always leave filter
		// mode and focus the query; Escape is the way to close find.
		doc.filter = false
		find_open(doc, false)
	case .Replace_Open:
		find_open(doc, true)
	case .Filter_Open:
		// Arm the filter and open find. With no query yet there is nothing to
		// filter, so the view stays whole until matches arrive — which is what
		// makes this filter-as-you-type rather than a blank screen.
		find_open(doc, false)
		doc.filter = true
		doc.filter_top = 0
		// Suppress the jump-to-nearest-match. Opening the filter deliberately
		// means "show me all of them", so the list starts at the top rather than
		// scrolled to wherever the caret happened to be.
		doc.find.jumped = true
	case .Goto_Line:
		// Go-to-line lives in the palette as its ':' mode. Routing it through a
		// real command makes it findable by name and bindable; the palette closes
		// and reopens itself in that mode.
		palette_open(app)
		palette_input_rune(app, ':')
	case .Open_Link:
		// The keyboard route to what Ctrl+click does, so links are not a mouse-only
		// feature and the action shows up in the palette by name. Scans only the
		// caret's own line rather than the viewport.
		//
		// It also had the same silent return the Ctrl+click path did, with no
		// decoration in front of it to have filtered the target first:
		// link_at_cursor reports whatever links_scan finds on the caret's line.
		// link_follow says so rather than swallowing it.
		if line, l, found := link_at_cursor(doc); found {
			link_follow(app, t, w, doc, line, l)
		}
	case .Clear_Selection:
		doc.anchor = doc.cursor
		// Escape clears a normal selection; it must drop a live column
		// rectangle the same way, or it survives invisibly after the caret
		// looks like it has none.
		if block_active(doc) {block_clear(doc)}
	case .Move_Line_Up:
		// Shift isn't part of the chord (Binding has no shift field -- see
		// the comment above default_bindings), so Alt+Up and Alt+Shift+Up
		// both dispatch here; the action tells them apart. Shift held means
		// extend the column rectangle up a row instead of moving the line --
		// bare Alt+Up is unchanged from before this feature existed.
		if ev.shift {
			block_extend_dispatch(app, doc, t, -1, 0)
		} else {
			doc_move_lines(doc, -1)
		}
	case .Move_Line_Down:
		if ev.shift {
			block_extend_dispatch(app, doc, t, 1, 0)
		} else {
			doc_move_lines(doc, 1)
		}
	case .Block_Extend_Left:
		// Alt+Left carries no shift bit in the chord either (same reason as
		// Move_Line_Up above), and this binding used to not exist at all --
		// so a bare Alt+Left must keep doing nothing, exactly as an unbound
		// key does. Only Alt+Shift+Left may act.
		//
		// command_named is the escape hatch for the route that has no chord to
		// protect: both of these are in the palette, and palette_execute
		// dispatches a zero Key_Event, so on the shift test alone they were rows
		// that ran and did nothing. Their Up/Down siblings below never needed the
		// gate and so never grew the hole.
		if ev.shift || command_named(ev) {block_extend_dispatch(app, doc, t, 0, -1)}
	case .Block_Extend_Right:
		if ev.shift || command_named(ev) {block_extend_dispatch(app, doc, t, 0, 1)}
	case .Block_Extend_Up:
		// Unreachable from the default keymap (Alt+Up already means
		// Move_Line_Up, handled above) -- reachable only from the palette or
		// a future user rebind. There is no bare-key behaviour to preserve
		// here, unlike Left/Right, so no shift check is needed.
		block_extend_dispatch(app, doc, t, -1, 0)
	case .Block_Extend_Down:
		block_extend_dispatch(app, doc, t, 1, 0)
	case .Bookmark_Toggle:
		// No note on success: the mark appears in the margin on the caret's own
		// row, which is on screen by definition, so a status line saying the
		// same thing is noise. The refusal DOES get one -- it is the caret's
		// line start being further than BOOKMARK_LINE_CAP away (one enormous
		// line), the same bound and the same "say so rather than guess" as
		// block_extend's .Caret_Unresolved, and a silent no-op reads as a dead
		// key.
		if _, ok := doc_bookmark_toggle(doc); !ok && doc != nil && doc.kind == .Text {
			app_note(app, "[BOOKMARK UNAVAILABLE HERE - the line is too far into a very large file]")
		}
	case .Bookmark_Cycle:
		// ev.shift is the direction. It is not in the chord and cannot be (see
		// Bookmark_Cycle's comment on Command_Id), so this is the only place the
		// two directions are distinguished.
		if !doc_bookmark_cycle(doc, ev.shift) && doc != nil && doc.kind == .Text {
			app_note(app, "[NO BOOKMARKS - press Ctrl+F2 to set one]")
		}
	case .Sort_Lines:
		sort_lines_dispatch(app, doc, .Ascending)
	case .Sort_Lines_Desc:
		sort_lines_dispatch(app, doc, .Descending)
	case .Remove_Duplicate_Lines:
		sort_lines_dispatch(app, doc, .Dedupe)
	case .Format_Document:
		// VS Code's Format Document. Wyatt asked for it 2026-07-30 with a .log file
		// that is one unreadable line and a tasks.json showing the wanted result,
		// then for CSS/SCSS and XML on 2026-08-02. It EDITS the buffer -- undoable,
		// like any other edit -- rather than rendering a view, which is what "format
		// this file" means everywhere else and what he chose.
		//
		// ONE command for three languages, dispatching on format_kind_for: one
		// chord, one menu row, and the note says which formatter ran so it is never
		// a mystery. JavaScript is deliberately not among them -- see
		// requested-features.md; it needs a parser, not a token re-emitter.
		if doc == nil {break}
		// A CEILING, and it is the price of editing rather than viewing -- measured,
		// see FORMAT_MAX. Refusing loudly is the house style: the sort refuses past
		// 100,000 rows and says so, and a formatter that instead froze for a minute
		// on a 2 GB minified log would be the worse failure.
		if format_too_large(doc.pt.length) {
			app_note(app, fmt.tprintf("[TOO LARGE TO FORMAT -- %d MB LIMIT]", FORMAT_MAX / (1024 * 1024)))
			break
		}
		// THE HEAP, with explicit frees -- not the frame's temp allocator. Both of
		// these are file-sized (the output is the larger of the two, since indent is
		// what this adds), and the temp arena is freed but never SHRUNK: one format
		// of a 60 MB file would leave a ~190 MB high-water mark for the rest of the
		// process's life. table_sort_build makes exactly this argument for exactly
		// this reason, and it is also what a sabotage pass found here -- with the
		// ceiling removed, the failure was not the size guard but the temp arena
		// refusing the allocation, which then surfaced as "not valid JSON".
		kind := format_kind_for(doc)
		if kind == .None {
			app_note(app, "[NOTHING TO FORMAT -- EXPECTED JSON, CSS OR XML]")
			break
		}
		src := base.pt_collect(&doc.pt, context.allocator)
		// The tab width, in spaces. Wyatt's call: the output matches how the editor
		// is already set up rather than hard-coding two. All three formatters take
		// it, so the file type does not change how the result is indented.
		tabw := plat.text_tab_width(t)
		out: []u8
		at, what, why := 0, "", ""
		switch kind {
		case .Json:
			e: base.Json_Error
			out, e, at = base.json_format(src, tabw, context.allocator)
			what, why = "JSON", base.json_error_text(e)
		case .Css:
			e: base.Css_Error
			out, e, at = base.css_format(src, tabw, context.allocator)
			what, why = "CSS", base.css_error_text(e)
		case .Xml:
			e: base.Xml_Error
			out, e, at = base.xml_format(src, tabw, context.allocator)
			what, why = "XML", base.xml_error_text(e)
		case .Html:
			// Same errors and the same `at`, so it shares xml_error_text -- it is
			// xml_format with one more rule, not a second formatter.
			e: base.Xml_Error
			out, e, at = base.html_format(src, tabw, context.allocator)
			what, why = "HTML", base.xml_error_text(e)
		case .None:
		}
		// COMPUTED BEFORE `src` IS FREED. This compared against `src` after the
		// delete below for one commit -- a use-after-free that the "already
		// formatted" test could not see, because freed memory usually still holds
		// the bytes that were in it.
		unchanged := out != nil && len(out) == len(src) && string(out) == string(src)
		// FREED IMMEDIATELY, not deferred. `out` is about twice `src` on real
		// minified JSON (measured: 128 MB in, 264 MB out), and doc_replace_range
		// below makes the piece tree's own copy of it -- so holding the source
		// across that call puts src + 2*out live at once. Dropping it here takes the
		// peak from 657 MB to 529 MB on that same file, for one moved line.
		delete(src)
		defer delete(out)
		if out == nil {
			// MARKED, NOT SILENTLY REFUSED -- the rule §10 applies to malformed CSV
			// rows. The caret goes to the offending byte so the reader is looking at
			// the problem rather than hunting for it, and the note names both what it
			// was read AS and what is wrong there -- the first matters now that three
			// formatters share one command.
			doc.cursor = clamp(at, 0, doc.pt.length)
			doc.anchor = doc.cursor
			// doc.top is left to the frame's own caret-follow
			// (doc_ensure_cursor_visible), which runs with the row counts this layer
			// does not have. Moving the caret is the whole request; scrolling to it
			// is what that pass already does for every other caret move.
			app_note(app, fmt.tprintf("[NOT VALID %s -- %s]", what, why))
			break
		}
		// Nothing to do, and saying so beats an undo entry that changes no bytes.
		if unchanged {
			app_note(app, "[ALREADY FORMATTED]")
			break
		}
		if block_active(doc) {block_clear(doc)} // a rectangle cannot survive a whole-buffer rewrite
		doc_replace_range(doc, 0, doc.pt.length, out)
		doc.cursor, doc.anchor, doc.top = 0, 0, 0
		app_note(app, "[FORMATTED]")
	case .Toggle_Wrap:
		// Refuse, with a reason, in the views that lay the document out
		// themselves and therefore ignore this flag entirely.
		//
		// It used to flip doc.wrap unconditionally. In the grid, in Markdown
		// Preview and in Markdown Split nothing reads the flag -- the grid draws
		// cells, markdown_draw replaces the text pass, and Split force-wraps via
		// doc_wraps regardless -- so Alt+Z was a key that did nothing, silently,
		// with no way to tell that from a broken build. Wyatt hit exactly that
		// and reported word wrap "wasn't toggling in the viewport".
		//
		// Refusing rather than flipping quietly is the point: a flip you cannot
		// see leaves the setting somewhere you did not choose, and you find out
		// when you leave the view. Same shape as block.odin's Wrap_On/Split_On
		// refusals, and each note names the key that gets you out, because "does
		// not apply here" is only useful with "here is how to leave here".
		if doc != nil && doc.kind == .Text {
			if doc.table {
				app_note(app, "[WORD WRAP DOESN'T APPLY IN TABLE VIEW - press Ctrl+T]")
				return
			}
			#partial switch doc.md_mode {
			case .Preview:
				app_note(app, "[WORD WRAP DOESN'T APPLY IN MARKDOWN PREVIEW - press Ctrl+M]")
				return
			case .Split:
				app_note(app, "[MARKDOWN SPLIT ALWAYS WRAPS - press Ctrl+M to leave it]")
				return
			}
		}
		doc.wrap = !doc.wrap
		doc.top = base.pt_line_start(&doc.pt, doc.top) // re-anchor top to a logical line start
		// Wrap changes what a rectangle's (line, cell) pair even means -- a
		// visual row stops being one logical line -- so a live block cannot
		// survive the toggle, the same reason the gesture itself refuses
		// while already wrapped (block_extend).
		if block_active(doc) {block_clear(doc)}
	case .Toggle_Table:
		// Read-only grid view of a CSV/TSV. Re-anchor the top to a line start so a
		// row lands where the caret was, and pick the delimiter on first turn-on.
		if doc.kind == .Text && doc_can_table(doc) {
			// Don't leave an edit dangling -- and don't reorder for it either: the
			// off-branch below clears the sort, and the on-branch has none yet.
			if doc.table_editing {table_edit_commit(doc, resort = false)}
			// A rectangle cannot survive the toggle in either direction, the
			// same reason .Toggle_Wrap clears one. Table view is a grid of
			// cells with their own widths -- a (line start, cell) pair means
			// nothing there -- and, worse, the mutating-command guard above
			// RETURNS EARLY for every mutating command while doc.table is
			// set, so it never reaches the block-clear branch that would
			// otherwise drop a rectangle the buffer has moved out from under.
			// The whole-branch review's reproduction: Alt+drag on a CSV,
			// Ctrl+T, edit a cell (table_edit_commit splices through
			// doc_replace_range), Ctrl+T back, Ctrl+X -- and the cut took
			// bytes the user never saw highlighted. Identical shape to the
			// find_replace_all hole fixed earlier on this branch.
			if block_active(doc) {block_clear(doc)}
			doc.table = !doc.table
			if doc.table {
				// The grid and a markdown view are mutually exclusive -- Split
				// force-wraps and the table guard above blocks every mutating
				// command, so a document in both is the state view.odin calls
				// undefined and doc_view_apply refuses to restore. Both gates
				// short-circuit true for an untitled buffer, so Ctrl+T then
				// Ctrl+M on a scratch tab reached it live; session format 4
				// persists both fields, so a restart quietly resolved it while
				// the live case stayed broken. Turning markdown off needs no
				// care beyond the field: its only companion state is the
				// rectangle, cleared just above for both directions.
				doc.md_mode = .Off
				doc.table_delim = table_choose_delim(doc)
				doc.top = base.pt_line_start(&doc.pt, doc.top)
				doc.table_hscroll_px = 0 // the grid always opens at its left edge
				// BEFORE the widths, not after: table_compute_widths excludes line 0
				// from its type decision only when line 0 is a header, so it has to
				// know which this file is before it samples.
				table_headerless_resolve(doc, app.settings.table_header_mode)
				table_compute_widths(doc, t) // fix the columns now, so they don't shift on scroll
			} else {
				clear(&doc.table_widths) // recompute on next open (content may have changed)
				// Manual column widths last as long as the grid is open, no
				// longer: the next open re-samples, and the column at index 3
				// after an edit may not be the column the user narrowed.
				table_user_widths_clear(doc)
				// ...and so does the sort, by leave_table_view's written policy: it
				// is a property of the VIEW, so leaving the grid leaves the file's
				// own order. This is the PRIMARY way to leave and it was the one
				// path that did not clear -- so the sort silently came back on the
				// next Ctrl+T, accent arrow and summary text and all, with nothing
				// having said it survived. It also left table_sort_shift running an
				// O(rows) pass per keystroke in the plain text editor for any
				// document that had been in the grid once.
				table_sort_clear(doc);table_filter_clear(doc)
			}
			// Learn the family default so the next tabular file opens the same way.
			// Gated on remember_views: with it off the Settings value is a pin, not a
			// running average of what you last did. Also gated on doc.path != "":
			// doc_is_tabular short-circuits true for an untitled buffer (same as
			// doc_can_table -- see path_has_ext's "don't limit" comment), so without
			// this an untitled Ctrl+T would teach the family a default from a buffer
			// that was never actually tabular.
			if app.settings.remember_views && doc.path != "" && doc_is_tabular(doc) {
				app.settings.table_default = doc.table
				settings_save(app.settings)
			}
		}
	// The header menu's six rows (menu.odin's table_header_menu_items), all
	// aimed at app.menu.ctx_col -- the column the menu was opened on. Guarded
	// on doc.table, not just doc != nil: none of the four operations below
	// check it themselves (table.odin), and building a sort on a document that
	// is not in the grid would leave it live for table_sort_shift to carry on
	// every future edit -- the same O(rows)-per-keystroke cost .Toggle_Table's
	// own off-branch clears the sort to avoid, a few cases above.
	case .Table_Sort_Asc:
		if doc != nil && doc.table {table_sort_set(doc, app.menu.ctx_col, false)}
	case .Table_Sort_Desc:
		if doc != nil && doc.table {table_sort_set(doc, app.menu.ctx_col, true)}
	case .Table_Sort_Then_Asc:
		if doc != nil && doc.table {table_sort_add(doc, app.menu.ctx_col, false)}
	case .Table_Sort_Then_Desc:
		if doc != nil && doc.table {table_sort_add(doc, app.menu.ctx_col, true)}
	case .Table_Sort_Remove:
		if doc != nil && doc.table {table_sort_drop(doc, app.menu.ctx_col)}
	case .Table_Sort_Clear:
		// Clears and lands on the file's first row, like the third header click and
		// like the summary row's own clear (main.odin). Unlike the three paths that
		// clear because the grid is being LEFT, which keep their place for the text
		// view -- see table_sort_scroll_top.
		if doc != nil && doc.table {table_sort_clear(doc);table_sort_scroll_top(doc)}
	// --- the column filter ---
	case .Table_Filter_Open:
		if doc == nil || !doc.table {break}
		// Ctrl+L and the column filter are EXCLUSIVE, settled when this batch was
		// split off: Ctrl+L has its own render path, scroll model and banner, so a
		// column predicate riding inside it would mean one row set with two owners.
		if doc.filter {doc.filter = false}
		// BEFORE menu_filter_items, not after. menu_open_ctx clears the search box on
		// every open, and the row set below is built as an argument to it -- so
		// leaving the clear to menu_open_ctx would build the rows through the old
		// query and then hide the box that explains why half of them are missing.
		app.menu.query_len = 0
		// REOPENING THE SAME COLUMN KEEPS THE SELECTION. table_filter_open rescans
		// and re-ticks everything, so without this every reopen silently undid the
		// filtering that was just done -- and since the dropdown closes on a click,
		// reopening is exactly what you do to untick a second value. That is what
		// "it doesn't look like it actually filters anything" was (Wyatt, v0.49.0):
		// the filter worked and was thrown away a moment later.
		if table_filtered(doc) && doc.table_filter.col == app.menu.ctx_col {
			menu_open_ctx(app, menu_filter_items(app), app.menu.ctx_x, app.menu.ctx_y, app.menu.ctx_col)
			break
		}
		if !table_filter_open(doc, app.menu.ctx_col) {
			if doc.table_filter.refused {
				app_note(app, fmt.tprintf("[TOO LARGE TO FILTER -- OVER %d ROWS]", TABLE_SORT_MAX))
			}
			break
		}
		// Reopened as a dropdown of values, anchored where the header menu was, so
		// the two read as one gesture rather than as a menu that vanished.
		menu_open_ctx(app, menu_filter_items(app), app.menu.ctx_x, app.menu.ctx_y, app.menu.ctx_col)
	case .Table_Filter_Toggle:
		if doc == nil || !doc.table {break}
		f := &doc.table_filter
		// The row's payload, left on the menu by the pick -- the same shape ctx_col
		// and ctx_tab use, and for the same reason: the command runs after the menu
		// that chose it has closed.
		i := app.menu.ctx_payload
		if i >= 0 && i < len(f.on) {
			f.on[i] = !f.on[i]
			table_filter_apply(doc)
			table_sort_scroll_top(doc)
		}
	case .Table_Filter_All:
		if doc == nil || !doc.table {break}
		f := &doc.table_filter
		// A three-way control, not a button: ticked means everything is showing, so
		// clicking it then hides everything. Untick-all is what you press before
		// picking two values out of two hundred, and without it that is 198 clicks.
		all := true
		for on in f.on {if !on {all = false}}
		for i in 0 ..< len(f.on) {f.on[i] = !all}
		table_filter_apply(doc)
		table_sort_scroll_top(doc)
	case .Table_Filter_Clear:
		if doc == nil || !doc.table {break}
		table_filter_clear(doc)
		table_sort_scroll_top(doc)
	case .Table_First_Row_Is_Data:
		// Unlike the six rows above it this names no column, so it is NOT in
		// command_needs_menu_target and can be run from the palette as well as from
		// the header menu.
		if doc != nil && doc.table {
			// The person has now answered, so the mode stops being Auto and the
			// heuristic stops being consulted for this document.
			doc.table_header_mode = .Header if doc.table_headerless else .Data
			table_headerless_resolve(doc, app.settings.table_header_mode)
			// THE ROW SET JUST CHANGED, so the sort has to go. Every offset in the
			// permutation was built when the row set had one more (or one fewer) row
			// at the front, and a visible row would resolve to the line beside the
			// one drawn -- which the cell editor then writes through. Same reason
			// table_sort_shift drops a sort when a newline moves, reached by a
			// different route.
			table_sort_clear(doc)
			table_sort_scroll_top(doc)
			// ...and the columns re-fit: line 0 has moved between the band and the
			// data, so it now counts toward a different one of the two.
			clear(&doc.table_widths)
			table_compute_widths(doc, t)
			// Learn the family default on exactly the terms .Toggle_Table learns
			// its own: only while remembering is on, and only from a file with a
			// path (doc_is_tabular short-circuits true for an untitled buffer, so
			// without that an untitled scratch tab would teach a default from a
			// buffer that was never a real table).
			if app.settings.remember_views && doc.path != "" {
				app.settings.table_header_mode = doc.table_header_mode
				settings_save(app.settings)
			}
		}
	case .Toggle_Preview:
		// Cycle Off -> Preview -> Split -> Off. The preview scrolls in pixels from
		// its own anchor (doc.md_top); re-anchoring doc.top to a line start here is
		// what the frame's sync then maps onto it, so turning the preview on lands
		// it on the block the caret's line is in.
		if doc.kind == .Text && doc_can_markdown(doc) {
			switch doc.md_mode {
			case .Off:
				doc.md_mode = .Preview
				// The other half of the mutual exclusion .Toggle_Table enforces.
				// Through leave_table_view, not doc.table = false: an in-cell
				// edit left dangling here would keep a byte span nothing will
				// ever splice, and the fitted widths would be reused against
				// content that has moved on.
				leave_table_view(doc)
				doc.top = base.pt_line_start(&doc.pt, doc.top)
			case .Preview:
				doc.md_mode = .Split
			case .Split:
				doc.md_mode = .Off
			}
			// Split makes doc_wraps true, so it changes what a rectangle's
			// (line start, cell) pair means exactly the way Alt+Z does -- and
			// .Toggle_Wrap has always cleared the block for that reason while
			// this case did not. Cleared for every mode transition, not just
			// the one into Split: leaving Split re-narrows the meaning the
			// other way, and a rectangle that was live across the whole cycle
			// has been drawn against visual rows the entire time. block.odin's
			// four operations refuse under doc_wraps too (block_stale_view),
			// but this is the one place that removes the stale rectangle the
			// user would otherwise still see highlighted.
			if block_active(doc) {block_clear(doc)}
			// Learn the family default so the next file of this type opens the same
			// way. Gated on remember_views: with it off the Settings value is a pin,
			// not a running average of what you last did. Also gated on doc.path != "":
			// doc_is_markdownish short-circuits true for an untitled buffer (same as
			// doc_can_markdown -- see path_has_ext's "don't limit" comment), so without
			// this an untitled Ctrl+M would teach the family a default from a buffer
			// that was never actually markdown.
			if app.settings.remember_views && doc.path != "" && doc_is_markdownish(doc) {
				app.settings.md_default = doc.md_mode
				settings_save(app.settings)
			}
		}

	// --- command palette ---
	case .Palette_Open:
		palette_open(app)
	case .Palette_Close:
		palette_close(app)
	case .Palette_Confirm:
		palette_execute(app, w, t, rows)
	case .Palette_Next:
		palette_move(app, 1)
	case .Palette_Prev:
		palette_move(app, -1)
	case .Palette_Backspace:
		palette_backspace(app)

	// --- tabs ---
	case .Tab_New:
		app_new_scratch(app)
	case .Tab_Open:
		if p, ok := plat.file_open_dialog(w.hwnd); ok {
			if !app_open_path(app, p) {
				fmt.eprintfln("Newtpad: could not open %s", p)
			}
		}
	case .Tab_Close:
		request_close_tab(app, app.active, w)
	case .Tab_Next:
		app.kbd_tab_focus = true // reached the rail by keyboard: draw the ring
		app_switch_relative(app, -1 if ev.shift else 1) // Shift+Ctrl+Tab -> previous
	case .Tab_Prev:
		app.kbd_tab_focus = true
		app_switch_relative(app, -1)
	case .Enc_UTF8:
		doc_set_encoding(doc, .UTF8)
	case .Enc_UTF16LE:
		doc_set_encoding(doc, .UTF16LE)
	case .Enc_CP1252:
		doc_set_encoding(doc, .CP1252)
	case .Reopen_UTF8:
		reopen_with_encoding(app, doc, w, .UTF8)
	case .Reopen_UTF16LE:
		reopen_with_encoding(app, doc, w, .UTF16LE)
	case .Reopen_CP1252:
		reopen_with_encoding(app, doc, w, .CP1252)
	case .Eol_LF:
		doc_set_line_ending(doc, .LF)
	case .Eol_CRLF:
		doc_set_line_ending(doc, .CRLF)

	case .Reload:
		// Discards unsaved edits, so confirm when there are any. The buffer is
		// still in the session backup at this point, which is what makes the
		// choice recoverable rather than terminal.
		if doc.path == "" {break}
		if doc.modified {
			if plat.confirm_discard(w.hwnd, doc_display_name(doc)) != .Discard {break}
		}
		if !doc_reload(doc) {
			plat.message_error(w.hwnd, "Could not re-read the file from disk.")
		}

	case .Exit:
		// No prompt, matching the close button: unsaved buffers are persisted as
		// session backups on the way out (hot exit). A File>Exit that prompted
		// would be stricter than the close button, which is worse than either.
		plat.window_request_close(w)

	// --- menu bar ---
	case .Menu_Close:
		// Unwind one level: an open dropdown closes to bar mode, bar mode exits.
		if app.menu.open >= 0 {
			app.menu.open = -1
			app.menu.item = -1
		} else {
			menu_close(app)
		}
	case .Menu_Next, .Menu_Prev:
		d := 1 if cmd == .Menu_Next else -1
		if app.menu.open >= 0 {
			menu_open_at(app, (app.menu.open + d + len(menus)) % len(menus))
		} else {
			menu_open_at(app, 0 if d > 0 else len(menus) - 1)
		}
	case .Menu_Search_Back:
		// Returns false on every menu that has no search box, and on an empty one.
		// Nothing else happens either way: a Backspace over a menu is not an edit.
		menu_filter_query_back(app)
	case .Menu_Item_Next, .Menu_Item_Prev:
		d := 1 if cmd == .Menu_Item_Next else -1
		if app.menu.open < 0 {
			menu_open_at(app, 0) // Down on the bar opens the first menu
		} else {
			app.menu.item = menu_step(app, app.menu.open, app.menu.item + d, d)
		}
	// --- undo history ---
	case .History_Open:
		menu_close(app)
		history_open(app)
	case .History_Close:
		history_close(app)
	case .History_Next:
		history_move(app, 1)
	case .History_Prev:
		history_move(app, -1)
	case .History_Jump:
		history_activate(app)

	case .Zoom_In, .Zoom_Out, .Zoom_Reset:
		if rc := active_render_ctx; rc != nil {
			zoom_adjust(rc, 1 if cmd == .Zoom_In else (-1 if cmd == .Zoom_Out else 0))
		}

	// --- font page ---
	case .Font_Open:
		menu_close(app)
		font_choices_refresh()
		app.font_row = 0
		app_open_special(app, .Font)
	case .Font_Close:
		request_close_tab(app, app.active, w)
	case .Font_Next:
		font_page_move(app, 1)
	case .Font_Prev:
		font_page_move(app, -1)
	case .Font_Inc, .Font_Dec:
		if rc := active_render_ctx; rc != nil {
			font_page_adjust(rc, app.font_row, 1 if cmd == .Font_Inc else -1)
		}

	// --- settings page ---
	case .Settings_Open:
		menu_close(app)
		app.settings_row = 0
		app.settings_top = 0
		app_open_special(app, .Settings)
	case .Theme_Edit:
		theme_edit_current(app)
	case .Keys_Edit:
		keymap_edit_current(app)
	case .Rules_Edit:
		rules_edit_current(app)
	case .Open_Logs_Folder:
		// Logging has been on by default since 0.9.0 and had no command, no menu
		// entry and no mention anywhere in the UI -- the audit found a working
		// feature nobody could reach. diag_init creates this directory on every
		// launch, so the miss below is a real failure, not a first-run case.
		if dir, ok := session_dir(); ok {
			logs, _ := filepath.join({dir, "logs"}, context.temp_allocator)
			if !plat.shell_open_folder(logs) {
				app_note(app, "[COULD NOT OPEN THE LOGS FOLDER]")
			}
		} else {
			app_note(app, "[COULD NOT OPEN THE LOGS FOLDER]")
		}
	// --- the tab strip's context menu ---
	//
	// All four resolve the tab through menu_ctx_tab_doc, the same producer the
	// menu's own enabled predicates read, so a row cannot paint live and then act
	// on a different tab -- or on none.
	case .Tab_Reveal:
		if d := menu_ctx_tab_doc(app); d != nil && d.path != "" {
			// Reveal, not open: the user asked to see where the file is, and
			// nothing we did executed it. Same call a non-text link resolves to.
			if !plat.shell_reveal(d.path) {
				app_note(app, "[COULD NOT REVEAL THE FILE]")
			}
		}
	case .Tab_Copy_Path:
		if d := menu_ctx_tab_doc(app); d != nil && d.path != "" {
			plat.clipboard_set_text(w.hwnd if w != nil else nil, d.path)
			app_note(app, "[PATH COPIED]")
		}
	case .Tab_Close_This:
		// Distinct from .Tab_Close, which is Ctrl+W and closes the ACTIVE tab. This
		// one closes the tab the menu was opened on, which is frequently not the
		// active one -- a right-click does not activate here.
		//
		// Through request_close_tab, so an unsaved tab still asks. The menu is a
		// second route to closing, not a second policy about unsaved work.
		if app.menu.ctx_tab >= 0 {request_close_tab(app, app.menu.ctx_tab, w)}
	case .Tab_Close_Others:
		// Backwards over the slots, and that is load-bearing: request_close_tab may
		// remove a slot, and walking forward while the array shrinks under the index
		// skips whatever moved into the gap. It may also be CANCELLED -- an unsaved
		// tab whose dialog the user dismisses stays open -- so this cannot assume it
		// ends with exactly one tab left.
		if app.menu.ctx_tab >= 0 && app.menu.ctx_tab < len(app.docs) {
			keep := app.docs[app.menu.ctx_tab]
			for i := len(app.docs) - 1; i >= 0; i -= 1 {
				if app.docs[i] == nil || app.docs[i] == keep {continue}
				request_close_tab(app, i, w)
			}
		}
	case .Open_Themes_Folder:
		// A user could not find where to put a .theme file, and the cause was more
		// specific than "it is undiscoverable": for them the folder did not EXIST.
		// theme.odin deliberately does not create it at startup -- a bare read of
		// settings.txt was mkdir-ing a themes/ folder for every user who had never
		// touched a theme -- so someone following the Settings row's advice found
		// nothing there and could not tell a wrong path from an empty right one.
		//
		// themes_dir_ENSURE, not themes_dir: asking for the folder is exactly the
		// moment it should come into existence, which is the distinction those two
		// procedures were split over. This is the first caller that is a user
		// action rather than a write.
		if dir, ok := themes_dir_ensure(); ok {
			if !plat.shell_open_folder(dir) {
				app_note(app, "[COULD NOT OPEN THE THEMES FOLDER]")
			}
		} else {
			app_note(app, "[COULD NOT OPEN THE THEMES FOLDER]")
		}

	// --- help ---
	case .Check_For_Updates:
		// Starts a worker and returns immediately. The request itself must never
		// run here: this is the UI thread, and a synchronous connect on a captive
		// portal would freeze the window for the whole timeout. update_poll (the
		// frame loop) surfaces the answer. See update.odin.
		menu_close(app)
		update_start(app)

	case .Settings_Close:
		request_close_tab(app, app.active, w)
	case .Settings_Next:
		app.settings_row = min(app.settings_row + 1, settings_row_count() - 1)
	case .Settings_Prev:
		app.settings_row = max(app.settings_row - 1, 0)
	case .Settings_Toggle, .Settings_Inc, .Settings_Dec:
		if rc := active_render_ctx; rc != nil {
			d := 0
			if cmd == .Settings_Inc {d = 1}
			if cmd == .Settings_Dec {d = -1}
			settings_toggle_row(rc, app.settings_row, d)
		}

	case .Menu_Activate:
		if app.menu.open >= 0 && app.menu.item >= 0 {
			// Through menu_items(app), not menus[app.menu.open].items directly --
			// one item source for the whole menu package, so a future context-menu
			// row can never be read through the bar-menu index or vice versa.
			it := menu_items(app)[app.menu.item]
			menu_close(app) // close first: the item may open the palette
			command_dispatch(it.cmd, ev, app, w, t, rows)
		}

	// --- find mode ---
	case .Find_Close:
		find_close(doc)
	case .Find_Backspace:
		find_backspace(doc)
	case .Find_Paste:
		// Guarded on find being open, not on the chord. NOT because the palette
		// can reach it -- it cannot: the same change that added this command put
		// it on command_in_palette's exclusion list and no menu row dispatches
		// it, so Ctrl+V with the bar open is the only route in today. The guard
		// is here because "the only caller checks" is not an invariant, and the
		// thing on the other side of it is a clipboard read: with the bar shut
		// there is no field for the text to land in, and find_paste would refuse
		// it anyway, so opening the Windows clipboard first would be work done
		// for a refusal. Guard the effect where the effect is.
		if doc != nil && doc.find.active {
			if s, ok := plat.clipboard_get_text(w.hwnd, context.temp_allocator); ok {
				find_paste(doc, s)
			}
		}
	case .Find_Step_Next:
		// Read-only-safe by construction: stepping moves the caret and the view,
		// and writes nothing. That is why these are NOT on command_mutates_doc
		// while .Find_Confirm cannot be -- in the replace field that same command
		// splices the buffer, and these two never can.
		if doc.find.active {find_next(doc)}
	case .Find_Step_Prev:
		if doc.find.active {find_prev(doc)}
	case .Find_Confirm:
		if doc.find.field == 1 {
			// Replace is a buffer write, and this is the one that got away: it
			// cannot go on command_mutates_doc (in the SEARCH field the very same
			// command is find_next/find_prev, which a read-only view must still
			// allow), so the guard at the top of this proc never saw it. That made
			// the table guard's own claim -- "the only buffer write in table view is
			// table_edit_commit's single-field splice" -- false for as long as it has
			// been written, and it would have left the same hole open in Markdown
			// Preview. Refuse here, in the one arm that actually writes.
			//
			// Silent, matching every other refusal these two views make; the Enter
			// simply does nothing, exactly as it does for Backspace or Paste.
			if doc_read_only_view(doc) {return}
			// Enter in the replace field replaces the current match and advances
			// (find_recompute re-selects the caret-nearest match, which after the
			// splice is the next one). Replace All used to hang off `ev.ctrl` here
			// and was unreachable: Ctrl+Enter matched no Binding row, so the branch
			// never ran. It is .Find_Replace_All now -- a command with a chord, a
			// palette entry and a button.
			find_replace_current(doc)
		} else {
			if ev.shift {find_prev(doc)} else {find_next(doc)}
		}
	case .Find_Field_Toggle:
		if doc.find.replace_mode {find_toggle_field(doc)}
	case .Find_Toggle_Case:
		find_toggle_case(doc)
	case .Find_Toggle_Word:
		find_toggle_word(doc)
	case .Find_Toggle_Regex:
		// Reachable from the palette with find closed, where it would otherwise
		// flip an invisible mode and start a search worker for a UI that isn't on
		// screen. Open find so the state it changes is visible.
		if !doc.find.active {find_open(doc, false)}
		find_toggle_regex(doc)
	case .Find_Toggle_Filter:
		// Deliberately not gated on having matches. The search runs on a worker,
		// so on a large file there are none for the first frames — gating here
		// made Ctrl+L do nothing at exactly the moment it was most wanted. The
		// view falls back to unfiltered until matches exist (doc_filtering).
		// find_set_filter (find.odin) is the single path in and out of the
		// filter view -- it also drops a live column rectangle, and its comment
		// is where the reason lives. Clicking a filtered row leaves through the
		// same proc.
		find_set_filter(doc, !doc.filter)
	case .Find_Replace_One:
		replace_dispatch(app, doc, w, false)
	case .Find_Replace_All:
		replace_dispatch(app, doc, w, true)
	case .Find_Toggle_Replace_Mode:
		doc.find.replace_mode = !doc.find.replace_mode
	case .Find_Filter_Page_Up:
		if doc.filter {doc.filter_top = max(0, doc.filter_top - (rows - 1))}
	case .Find_Filter_Page_Down:
		if doc.filter {doc.filter_top = min(doc_filter_max_top(doc, rows), doc.filter_top + (rows - 1))}

	case .None:
	// unbound: ignore
	}
}
