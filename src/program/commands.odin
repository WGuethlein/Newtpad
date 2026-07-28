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
	Find_Confirm,
	Find_Field_Toggle,
	Find_Toggle_Regex,
	Find_Toggle_Case,
	Find_Toggle_Word,
	Find_Toggle_Filter,
	Find_Toggle_Replace_Mode,
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
	.Save_As                  = {"Save As...", "File"},
	.Find_Open                = {"Find", "Search"},
	.Replace_Open             = {"Replace", "Search"},
	.Filter_Open              = {"Filter to Matching Lines", "Search"},
	.Goto_Line                = {"Go to Line...", "Cursor"},
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
	.Sort_Lines               = {"Sort Lines (selection, or whole file)", "Edit"},
	.Sort_Lines_Desc          = {"Sort Lines Descending (selection, or whole file)", "Edit"},
	.Remove_Duplicate_Lines   = {"Remove Duplicate Lines (exact match, keeps the first)", "Edit"},
	.Palette_Open             = {"Command Palette", "View"},
	.Palette_Close            = {"Palette: Close", "View"},
	.Palette_Confirm          = {"Palette: Confirm", "View"},
	.Palette_Next             = {"Palette: Next", "View"},
	.Palette_Prev             = {"Palette: Previous", "View"},
	.Palette_Backspace        = {"Palette: Delete Backward", "View"},
	.Tab_New                  = {"New Tab", "Tabs"},
	.Tab_Open                 = {"Open File...", "Tabs"},
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
	.Settings_Open            = {"Settings", "View"},
	.Settings_Close           = {"Settings: Close", "View"},
	.Settings_Next            = {"Settings: Next", "View"},
	.Settings_Prev            = {"Settings: Previous", "View"},
	.Settings_Toggle          = {"Settings: Toggle", "View"},
	.Settings_Inc             = {"Settings: Increase", "View"},
	.Settings_Dec             = {"Settings: Decrease", "View"},
	.Theme_Edit               = {"Edit Current Theme...", "View"},
	.Keys_Edit                = {"Edit Keybindings...", "View"},
	.Rules_Edit               = {"Edit Colour Rules...", "View"},
	.Open_Logs_Folder         = {"Open Logs Folder", "View"},
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
	.Find_Confirm             = {"Find: Confirm", "Search"},
	.Find_Field_Toggle        = {"Find: Toggle Field", "Search"},
	.Find_Toggle_Regex        = {"Find: Regular Expression", "Search"},
	.Find_Toggle_Case         = {"Find: Match Case", "Search"},
	.Find_Toggle_Word         = {"Find: Whole Word", "Search"},
	.Find_Toggle_Filter       = {"Find: Toggle Filter View", "Search"},
	.Find_Toggle_Replace_Mode = {"Find: Toggle Replace", "Search"},
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
	// --- find context ---
	{.Escape, false, false, .Find, .Find_Close},
	{.F, true, false, .Find, .Find_Open}, // switch to search view (leaves filter); Escape closes
	{.Backspace, false, false, .Find, .Find_Backspace},
	{.Enter, false, false, .Find, .Find_Confirm},
	{.Tab, false, false, .Find, .Find_Field_Toggle},
	{.R, true, false, .Find, .Find_Toggle_Regex},
	// Alt, not Ctrl: Ctrl+C and Ctrl+W already mean copy and close-tab, and a
	// find bar that stole either would be worse than the modes are worth.
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
report_save :: proc(err: plat.Write_Error, path: string, w: ^plat.Window) -> bool {
	if err == .None {
		fmt.printfln("Newtpad: saved %s", path)
		return true
	}
	plat.message_error(w.hwnd if w != nil else nil, plat.write_error_text(err, path))
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
	saved := report_save(doc_save_err(doc, path), path, w)
	if saved && app != nil {
		// UI spec 13: "Saved for 1.5s in success, then gone. No toast, no dialog,
		// no sound." A save that succeeds currently says nothing at all, so the
		// only confirmation is the asterisk disappearing from a tab you may not be
		// looking at. app_note already owns the transient-message lifetime.
		app_note(app, "[SAVED]")
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
		switch plat.confirm_discard(w.hwnd, doc_display_name(d)) {
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
	if (ctx == .Find || ctx == .Menu) && (ctrl || alt) {
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
// The .Unchanged note is not decoration. All three commands are palette-only, so
// the user has just typed a name and pressed Enter; with nothing to do and
// nothing said, the command reads as broken -- the same argument
// .Bookmark_Cycle's "[NO BOOKMARKS]" makes. And .Unchanged specifically means NO
// undo entry was pushed (doc_sort_lines returns before doc_batch_begin), so
// there is not even a history row to notice.
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
	if doc.table_editing {table_edit_commit(doc)}
	doc.table = false
	clear(&doc.table_widths)
}

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
		doc_select_all(doc)
	case .Copy:
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
			plat.clipboard_set_text(w.hwnd, s)
			doc_backspace(doc) // deletes the selection
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
		if line, l, found := link_at_cursor(doc); found {
			if tgt, rok := link_resolve(doc, line, l); rok {
				if !link_activate(app, t, tgt) {
					plat.message_error(
						w.hwnd if w != nil else nil,
						fmt.tprintf("Could not open:\n\n%s", tgt.url if tgt.is_url else tgt.path),
					)
				}
			}
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
		if ev.shift {block_extend_dispatch(app, doc, t, 0, -1)}
	case .Block_Extend_Right:
		if ev.shift {block_extend_dispatch(app, doc, t, 0, 1)}
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
			if doc.table_editing {table_edit_commit(doc)} // don't leave an edit dangling
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
				doc.table_col = 0
				table_compute_widths(doc, t) // fix the columns now, so they don't shift on scroll
			} else {
				clear(&doc.table_widths) // recompute on next open (content may have changed)
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
	case .Toggle_Preview:
		// Cycle Off -> Preview -> Split -> Off. Both preview modes scroll from
		// doc.top; Split anchors the editor and preview to the same source line.
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
			it := menus[app.menu.open].items[app.menu.item]
			menu_close(app) // close first: the item may open the palette
			command_dispatch(it.cmd, ev, app, w, t, rows)
		}

	// --- find mode ---
	case .Find_Close:
		find_close(doc)
	case .Find_Backspace:
		find_backspace(doc)
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
			if ev.ctrl {
				// Say so when the pass could not have seen the whole document. The
				// alternative -- replacing a prefix in silence -- looks exactly like
				// replacing everything, so a half-finished rename reads as a finished
				// one until something downstream breaks.
				if replaced, complete := find_replace_all(doc); !complete {
					plat.message_error(
						w.hwnd if w != nil else nil,
						fmt.tprintf(
							"Replaced %d occurrence(s).\n\nThe search had not finished scanning the file, or there were more matches than Newtpad tracks at once, so there may be more.\n\nRun Replace All again to continue.",
							replaced,
						),
					)
				}
			} else {find_replace_current(doc)}
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
