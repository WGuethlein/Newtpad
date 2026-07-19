// Layer: program — the command table: every editor action declared once. The
// enumerated `command_table` (compiler forces a row per Command_Id) holds palette
// metadata; `default_bindings` is the keymap (key chord + context -> command),
// separated from the metadata so keys are rebindable later (a user overlay);
// `command_dispatch` is the single behavior switch. This replaces the old split
// between the platform VK->Key_Cmd switch and the program Key_Cmd->action switch.
package main

import "core:fmt"
import base "src:base"
import plat "src:platform"

// Where a binding is active. Find mode is modal (doc.find.active); the same chord
// can mean different things per context (Enter = newline vs confirm-search).
Ctx :: enum u8 {
	Editor,
	Find,
	Palette,
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
	{.Z, true, false, .Editor, .Undo},
	{.Y, true, false, .Editor, .Redo},
	{.A, true, false, .Editor, .Select_All},
	{.C, true, false, .Editor, .Copy},
	{.X, true, false, .Editor, .Cut},
	{.V, true, false, .Editor, .Paste},
	{.S, true, false, .Editor, .Save},
	{.F, true, false, .Editor, .Find_Open},
	{.H, true, false, .Editor, .Replace_Open},
	{.Escape, false, false, .Editor, .Clear_Selection},
	{.Z, false, true, .Editor, .Toggle_Wrap}, // Alt+Z
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
			if !doc_save(d, p) {return}
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
	if ctx == .Find && (ctrl || alt) {
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
