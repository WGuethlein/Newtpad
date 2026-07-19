// Layer: program — the command table: every editor action declared once. The
// enumerated `command_table` (compiler forces a row per Command_Id) holds palette
// metadata; `default_bindings` is the keymap (key chord + context -> command),
// separated from the metadata so keys are rebindable later (a user overlay);
// `command_dispatch` is the single behavior switch. This replaces the old split
// between the platform VK->Key_Cmd switch and the program Key_Cmd->action switch.
package main

import "core:fmt"
import plat "src:platform"

// Where a binding is active. Find mode is modal (doc.find.active); the same chord
// can mean different things per context (Enter = newline vs confirm-search).
Ctx :: enum u8 {
	Editor,
	Find,
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
	Word_Left,
	Word_Right,
	Page_Up,
	Page_Down,
	Backspace,
	Delete_Fwd,
	Delete_Word_Back,
	Insert_Newline,
	Undo,
	Redo,
	Select_All,
	Copy,
	Cut,
	Paste,
	Save,
	Find_Open,
	Replace_Open,
	Clear_Selection,
	// tabs
	Tab_New,
	Tab_Open,
	Tab_Close,
	Tab_Next,
	Tab_Prev,
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
	.Word_Left                = {"Move Word Left", "Cursor"},
	.Word_Right               = {"Move Word Right", "Cursor"},
	.Page_Up                  = {"Page Up", "Cursor"},
	.Page_Down                = {"Page Down", "Cursor"},
	.Backspace                = {"Delete Backward", "Edit"},
	.Delete_Fwd               = {"Delete Forward", "Edit"},
	.Delete_Word_Back         = {"Delete Word Backward", "Edit"},
	.Insert_Newline           = {"Insert Newline", "Edit"},
	.Undo                     = {"Undo", "Edit"},
	.Redo                     = {"Redo", "Edit"},
	.Select_All               = {"Select All", "Edit"},
	.Copy                     = {"Copy", "Edit"},
	.Cut                      = {"Cut", "Edit"},
	.Paste                    = {"Paste", "Edit"},
	.Save                     = {"Save", "File"},
	.Find_Open                = {"Find", "Search"},
	.Replace_Open             = {"Replace", "Search"},
	.Clear_Selection          = {"Clear Selection", "Cursor"},
	.Tab_New                  = {"New Tab", "Tabs"},
	.Tab_Open                 = {"Open File...", "Tabs"},
	.Tab_Close                = {"Close Tab", "Tabs"},
	.Tab_Next                 = {"Next Tab", "Tabs"},
	.Tab_Prev                 = {"Previous Tab", "Tabs"},
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
	ctx:  Ctx,
	cmd:  Command_Id,
}

default_bindings := []Binding {
	// --- editor context ---
	{.Left, false, .Editor, .Cursor_Left},
	{.Right, false, .Editor, .Cursor_Right},
	{.Up, false, .Editor, .Cursor_Up},
	{.Down, false, .Editor, .Cursor_Down},
	{.Home, false, .Editor, .Cursor_Home},
	{.End, false, .Editor, .Cursor_End},
	{.Left, true, .Editor, .Word_Left},
	{.Right, true, .Editor, .Word_Right},
	{.Page_Up, false, .Editor, .Page_Up},
	{.Page_Down, false, .Editor, .Page_Down},
	{.Backspace, false, .Editor, .Backspace},
	{.Backspace, true, .Editor, .Delete_Word_Back},
	{.Delete, false, .Editor, .Delete_Fwd},
	{.Enter, false, .Editor, .Insert_Newline},
	{.Z, true, .Editor, .Undo},
	{.Y, true, .Editor, .Redo},
	{.A, true, .Editor, .Select_All},
	{.C, true, .Editor, .Copy},
	{.X, true, .Editor, .Cut},
	{.V, true, .Editor, .Paste},
	{.S, true, .Editor, .Save},
	{.F, true, .Editor, .Find_Open},
	{.H, true, .Editor, .Replace_Open},
	{.Escape, false, .Editor, .Clear_Selection},
	{.N, true, .Editor, .Tab_New},
	{.O, true, .Editor, .Tab_Open},
	{.W, true, .Editor, .Tab_Close},
	{.Tab, true, .Editor, .Tab_Next}, // Ctrl+Tab (Shift -> previous, read in the action)
	{.Page_Up, true, .Editor, .Tab_Prev},
	{.Page_Down, true, .Editor, .Tab_Next},
	// --- find context ---
	{.Escape, false, .Find, .Find_Close},
	{.F, true, .Find, .Find_Close},
	{.Backspace, false, .Find, .Find_Backspace},
	{.Enter, false, .Find, .Find_Confirm},
	{.Tab, false, .Find, .Find_Field_Toggle},
	{.R, true, .Find, .Find_Toggle_Regex},
	{.L, true, .Find, .Find_Toggle_Filter},
	{.H, true, .Find, .Find_Toggle_Replace_Mode},
	{.Page_Up, false, .Find, .Find_Filter_Page_Up},
	{.Page_Down, false, .Find, .Find_Filter_Page_Down},
}

// Map a key press to a command within the active context (shift ignored here; the
// action reads it). First matching binding wins; a user overlay would prepend.
resolve_key :: proc(key: plat.Key, ctrl: bool, ctx: Ctx) -> Command_Id {
	for b in default_bindings {
		if b.key == key && b.ctrl == ctrl && b.ctx == ctx {
			return b.cmd
		}
	}
	return .None
}

// Run a command. `rows` is the visible row count (page moves); `w` supplies the
// HWND for clipboard / Save-dialog. The active-context split means each command
// is unambiguous here.
command_dispatch :: proc(cmd: Command_Id, ev: plat.Key_Event, app: ^App, w: ^plat.Window, rows: int) {
	doc := app_active(app)
	switch cmd {
	// --- editor ---
	case .Cursor_Left:
		doc_cursor_left(doc, ev.shift)
	case .Cursor_Right:
		doc_cursor_right(doc, ev.shift)
	case .Cursor_Up:
		doc_cursor_up(doc, ev.shift)
	case .Cursor_Down:
		doc_cursor_down(doc, ev.shift)
	case .Cursor_Home:
		doc_cursor_home(doc, ev.shift)
	case .Cursor_End:
		doc_cursor_end(doc, ev.shift)
	case .Word_Left:
		doc_word_left(doc, ev.shift)
	case .Word_Right:
		doc_word_right(doc, ev.shift)
	case .Page_Up:
		doc_scroll(doc, -(rows - 1))
	case .Page_Down:
		doc_scroll(doc, rows - 1)
	case .Backspace:
		doc_backspace(doc)
	case .Delete_Fwd:
		doc_delete_fwd(doc)
	case .Delete_Word_Back:
		doc_delete_word_back(doc)
	case .Insert_Newline:
		doc_insert_rune(doc, '\n')
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
			if doc_save(doc, p) {
				fmt.printfln("Newtpad: saved %s", p)
			} else {
				fmt.eprintfln("Newtpad: failed to save %s", p)
			}
		}
	case .Find_Open:
		find_open(doc, false)
	case .Replace_Open:
		find_open(doc, true)
	case .Clear_Selection:
		doc.anchor = doc.cursor

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
		app_close(app, app.active)
	case .Tab_Next:
		app_switch_relative(app, -1 if ev.shift else 1) // Shift+Ctrl+Tab -> previous
	case .Tab_Prev:
		app_switch_relative(app, -1)

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
		find_toggle_regex(doc)
	case .Find_Toggle_Filter:
		if len(doc.find.matches) > 0 {
			doc.filter = !doc.filter
			doc.filter_top = 0
		}
	case .Find_Toggle_Replace_Mode:
		doc.find.replace_mode = !doc.find.replace_mode
	case .Find_Filter_Page_Up:
		if doc.filter {doc.filter_top = max(0, doc.filter_top - (rows - 1))}
	case .Find_Filter_Page_Down:
		if doc.filter {doc.filter_top = min(max(0, len(doc.filter_lines) - 1), doc.filter_top + (rows - 1))}

	case .None:
	// unbound: ignore
	}
}
