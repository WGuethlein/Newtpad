// Layer: program — the command table: every editor action declared once. The
// enumerated `command_table` (compiler forces a row per Command_Id) holds palette
// metadata; `default_bindings` is the keymap (key chord + context -> command),
// separated from the metadata so keys are rebindable later (a user overlay);
// `command_dispatch` is the single behavior switch. This replaces the old split
// between the platform VK->Key_Cmd switch and the program Key_Cmd->action switch.
package main

import "core:fmt"
import "core:strings"
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
	Clear_Selection,
	Toggle_Wrap,
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
	.Clear_Selection          = {"Clear Selection", "Cursor"},
	.Toggle_Wrap              = {"Toggle Word Wrap", "View"},
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
	.Find_Toggle_Regex        = {"Find: Toggle Regex", "Search"},
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
	{.Z, false, true, .Editor, .Toggle_Wrap}, // Alt+Z
	{.Plus, true, false, .Editor, .Zoom_In}, // Ctrl+= / Ctrl+numpad+
	{.Minus, true, false, .Editor, .Zoom_Out}, // Ctrl+- / Ctrl+numpad-
	{.Num0, true, false, .Editor, .Zoom_Reset}, // Ctrl+0
	{.P, true, false, .Editor, .Palette_Open}, // Ctrl+P
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
	{.F, true, false, .Find, .Find_Close},
	{.Backspace, false, false, .Find, .Find_Backspace},
	{.Enter, false, false, .Find, .Find_Confirm},
	{.Tab, false, false, .Find, .Find_Field_Toggle},
	{.R, true, false, .Find, .Find_Toggle_Regex},
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
command_chord :: proc(cmd: Command_Id, allocator := context.temp_allocator) -> string {
	// Editor bindings first — that's the chord a user would press from the
	// document. Falling back to any context so mode-local commands (the find
	// toggles) still teach their key instead of showing blank.
	for pass in 0 ..< 2 {
		for b in default_bindings {
			if b.cmd != cmd {continue}
			if pass == 0 && b.ctx != .Editor {continue}
			parts: [4]string
			n := 0
			if b.ctrl {parts[n] = "Ctrl+";n += 1}
			if b.alt {parts[n] = "Alt+";n += 1}
			parts[n] = key_name(b.key)
			n += 1
			return strings.concatenate(parts[:n], allocator)
		}
	}
	return ""
}

@(private = "file")
key_name :: proc(k: plat.Key) -> string {
	#partial switch k {
	case .Left:
		return "Left"
	case .Right:
		return "Right"
	case .Up:
		return "Up"
	case .Down:
		return "Down"
	case .Home:
		return "Home"
	case .End:
		return "End"
	case .Page_Up:
		return "PgUp"
	case .Page_Down:
		return "PgDn"
	case .Backspace:
		return "Backspace"
	case .Delete:
		return "Del"
	case .Enter:
		return "Enter"
	case .Tab:
		return "Tab"
	case .Escape:
		return "Esc"
	case .Plus:
		return "+"
	case .Minus:
		return "-"
	}
	// Letters and digits are contiguous in the enum, in order.
	if k >= .A && k <= .Z {
		return LETTERS[int(k) - int(plat.Key.A)][:]
	}
	if k >= .Num0 && k <= .Num9 {
		return DIGITS[int(k) - int(plat.Key.Num0)][:]
	}
	return ""
}

@(private = "file")
LETTERS := [26]string{"A", "B", "C", "D", "E", "F", "G", "H", "I", "J", "K", "L", "M", "N", "O", "P", "Q", "R", "S", "T", "U", "V", "W", "X", "Y", "Z"}
@(private = "file")
DIGITS := [10]string{"0", "1", "2", "3", "4", "5", "6", "7", "8", "9"}

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
			}
			// Aborting the close is right — but say why, or the user sees the tab
			// simply refuse to close with no explanation and may force-quit.
			if !report_save(doc_save_err(d, p), p, w) {return}
		case .Discard:
		}
	}
	app_close(app, slot)
}

@(private = "file")
lookup_binding :: proc(key: plat.Key, ctrl, alt: bool, ctx: Ctx) -> Command_Id {
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

// Run a command. `rows` is the visible row count (page moves); `w` supplies the
// HWND for clipboard / Save-dialog. The active-context split means each command
// is unambiguous here.
command_dispatch :: proc(cmd: Command_Id, ev: plat.Key_Event, app: ^App, w: ^plat.Window, t: ^plat.Text, rows: int) {
	doc := app_active(app)
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
		doc_backspace(doc)
	case .Delete_Fwd:
		doc_delete_fwd(doc)
	case .Delete_Word_Back:
		doc_delete_word_back(doc)
	case .Insert_Newline:
		doc_insert_rune(doc, '\n')
	case .Insert_Tab:
		// Tab arrives as WM_CHAR 0x09 too, but the char path filters control
		// characters, so the binding is what actually inserts it.
		doc_insert_rune(doc, '\t')
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
		if s := doc_selected_text(doc, context.temp_allocator); s != "" {
			plat.clipboard_set_text(w.hwnd, s)
		}
	case .Cut:
		if s := doc_selected_text(doc, context.temp_allocator); s != "" {
			plat.clipboard_set_text(w.hwnd, s)
			doc_backspace(doc) // deletes the selection
		}
	case .Paste:
		if s, ok := plat.clipboard_get_text(w.hwnd, context.temp_allocator); ok {
			doc_insert_text(doc, transmute([]u8)s)
		}
	case .Save:
		p := doc.path
		if p == "" {
			if np, ok := plat.file_save_dialog(w.hwnd); ok {
				p = np
			}
		}
		if p != "" {
			report_save(doc_save_err(doc, p), p, w)
		}
	case .Save_As:
		if p, ok := plat.file_save_dialog(w.hwnd); ok {
			report_save(doc_save_err(doc, p), p, w)
		}
	case .Find_Open:
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
	case .Goto_Line:
		// Go-to-line lives in the palette as its ':' mode. Routing it through a
		// real command makes it findable by name and bindable; the palette closes
		// and reopens itself in that mode.
		palette_open(app)
		palette_input_rune(app, ':')
	case .Clear_Selection:
		doc.anchor = doc.cursor
	case .Toggle_Wrap:
		doc.wrap = !doc.wrap
		doc.top = base.pt_line_start(&doc.pt, doc.top) // re-anchor top to a logical line start

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
		app_switch_relative(app, -1 if ev.shift else 1) // Shift+Ctrl+Tab -> previous
	case .Tab_Prev:
		app_switch_relative(app, -1)
	case .Enc_UTF8:
		doc_set_encoding(doc, .UTF8)
	case .Enc_UTF16LE:
		doc_set_encoding(doc, .UTF16LE)
	case .Enc_CP1252:
		doc_set_encoding(doc, .CP1252)
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
		app_open_special(app, .Settings)
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
			if ev.ctrl {find_replace_all(doc)} else {find_replace_current(doc)}
		} else {
			if ev.shift {find_prev(doc)} else {find_next(doc)}
		}
	case .Find_Field_Toggle:
		if doc.find.replace_mode {find_toggle_field(doc)}
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
		doc.filter = !doc.filter
		doc.filter_top = 0
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
