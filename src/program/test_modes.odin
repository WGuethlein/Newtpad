// Layer: program — headless verification entry points. The environment can't
// inject GUI keyboard/focus, so features are exercised through these argv modes
// (`newtpad <file> <mode> ...`) and checked against printed output. Kept out of
// main.odin so the frame loop reads clean.
package main

import "core:fmt"
import "core:os"
import "core:time"
import base "src:base"
import plat "src:platform"

@(private = "file")
key_chk :: proc(got, want: Command_Id, label: string) {
	ok := "OK" if got == want else fmt.tprintf("FAIL want=%v", want)
	fmt.printfln("%-22s -> %-16v %s", label, got, ok)
}

// Run a headless test mode if argv selects one. Returns true if a mode ran (the
// caller should then exit). `seh_install` has already run in main.
test_mode_dispatch :: proc() -> (handled: bool) {
	if len(os.args) < 2 {return false}

	// `newtpad sehtest` proves the SEH guard catches a real page fault.
	if os.args[1] == "sehtest" {
		fmt.printfln("seh guard caught + zero-filled a page fault: %v", plat.seh_selftest())
		return true
	}

	// `newtpad celltest` prints the monospace cell width of sample codepoints and
	// a byte<->cell round-trip (no GPU; uses text_load_faces).
	if os.args[1] == "celltest" {
		t: plat.Text
		if !plat.text_load_faces(&t) {
			fmt.eprintln("celltest: no fonts loaded")
			return true
		}
		samples := "aé中がx́" // ascii, 2-byte latin, CJK x2, kana, ascii, combining acute
		fmt.printf("cells: ")
		for r in samples {fmt.printf("%q=%d ", r, plat.text_cell_width(&t, r))}
		bytes := transmute([]u8)samples
		fmt.printfln(" | total=%d cells over %d bytes", plat.text_cells(&t, bytes), len(bytes))
		// inverse: the byte offset at each cell column should round-trip.
		total := plat.text_cells(&t, bytes)
		fmt.printf("col->byte: ")
		for c in 0 ..= total {fmt.printf("%d:%d ", c, plat.text_bytes_for_cells(&t, bytes, c))}
		fmt.println()
		return true
	}

	// `newtpad sessiontest` round-trips session save -> restore (clobbers the real
	// session under %APPDATA%\Newtpad, so only run on a dev machine).
	if os.args[1] == "sessiontest" {
		tmpf := fmt.tprintf("%s%cnewtpad_sesstest.txt", os.get_env("TEMP", context.temp_allocator), '\\')
		plat.file_write_atomic(tmpf, transmute([]u8)string("clean file content\nsecond line"))
		a: App
		if fd, ok := doc_open(tmpf); ok { // clean tab from a real file
			d := new(Document);d^ = fd;d.cursor = 3
			app_add(&a, d)
		}
		raw := "unsaved untitled buffer"
		content := make([]u8, len(raw));copy(content, transmute([]u8)raw)
		du := new(Document);du^ = doc_from_content(content, "", .UTF8);du.cursor = 8
		app_add(&a, du)
		a.active = 1
		fmt.printfln("saved %d tabs, active=%d", app_live_count(&a), a.active)
		session_save(&a)
		app_destroy(&a)

		b: App
		ok := session_restore(&b)
		fmt.printfln("restore ok=%v tabs=%d active=%d", ok, app_live_count(&b), b.active)
		for d, i in b.docs {
			if d == nil {continue}
			s := doc_debug_string(d)
			fmt.printfln("  tab %d: path=%q modified=%v cursor=%d %q", i, d.path, d.modified, d.cursor, s[:min(len(s), 24)])
		}
		app_destroy(&b)
		// reset the session so the GUI doesn't restore this test's tabs
		empty: App
		app_new_scratch(&empty)
		session_save(&empty)
		app_destroy(&empty)
		return true
	}

	// `newtpad palettetest` exercises the command palette's fuzzy match + modes.
	if os.args[1] == "palettetest" {
		a: App
		mk :: proc(a: ^App, name: string) {
			c := make([]u8, 4);copy(c, transmute([]u8)string("data"))
			d := new(Document);d^ = doc_from_content(c, name, .UTF8)
			app_add(a, d)
		}
		mk(&a, "notes.txt")
		mk(&a, "config.json")
		mk(&a, "readme.md")

		palette_open(&a)
		for r in "conf" {palette_input_rune(&a, r)}
		top := a.palette.results[0].slot if len(a.palette.results) > 0 else -1
		fmt.printfln("tabs 'conf'   -> %d results, top=%q", len(a.palette.results), doc_display_name(a.docs[top]) if top >= 0 else "")

		palette_close(&a);palette_open(&a)
		for r in ">wrap" {palette_input_rune(&a, r)}
		tc := a.palette.results[0].cmd if len(a.palette.results) > 0 else Command_Id.None
		fmt.printfln("cmd  '>wrap'  -> %d results, top=%q (mode=%v)", len(a.palette.results), command_table[tc].title, a.palette.mode)

		palette_close(&a);palette_open(&a)
		for r in ":42" {palette_input_rune(&a, r)}
		fmt.printfln("goto ':42'    -> mode=%v", a.palette.mode)

		app_destroy(&a)
		return true
	}

	// `newtpad vnavtest` checks vertical caret nav at the document edges: Up on the
	// first row and Down on the last must still move the caret to the document edge
	// (so shift+Up/shift+Down select to it), wrapped and unwrapped.
	if os.args[1] == "vnavtest" {
		t: plat.Text
		if !plat.text_load_faces(&t) {
			fmt.eprintln("vnavtest: no fonts loaded")
			return true
		}
		chk :: proc(got, want: int, what: string) {
			fmt.printfln("%-32s cursor=%d want=%d  %s", what, got, want, "ok" if got == want else "FAIL")
		}
		one :: proc(content: string, wrap: bool, cols: int, start: int, down: bool, t: ^plat.Text) -> (int, int) {
			doc: Document
			doc.pt = base.pt_init(transmute([]u8)content)
			doc.wrap, doc.view_cols = wrap, cols
			doc.cursor, doc.anchor = start, start
			if down {doc_cursor_down(&doc, t, true)} else {doc_cursor_up(&doc, t, true)}
			c, a := doc.cursor, doc.anchor
			base.pt_destroy(&doc.pt)
			return c, a
		}
		single := "hello world foo" // one line, no trailing newline
		c, _ := one(single, false, 0, 6, true, &t)
		chk(c, len(single), "single line, shift+Down")
		c, _ = one(single, false, 0, 6, false, &t)
		chk(c, 0, "single line, shift+Up")
		multi := "first line\nsecond line\nlast line here"
		c, _ = one(multi, false, 0, 28, true, &t) // on the last line, col 5
		chk(c, len(multi), "last line, shift+Down")
		c, _ = one(multi, false, 0, 3, false, &t)
		chk(c, 0, "first line, shift+Up")
		wrapped := "the quick brown fox jumps over the lazy dog"
		c, _ = one(wrapped, true, 20, len(wrapped) - 2, true, &t) // squarely on the last visual row
		chk(c, len(wrapped), "wrapped, last row shift+Down")
		c, _ = one(wrapped, true, 20, 3, false, &t)
		chk(c, 0, "wrapped, first row shift+Up")
		return true
	}

	// `newtpad wraptest` prints word-wrap segments for a sample paragraph.
	if os.args[1] == "wraptest" {
		t: plat.Text
		if !plat.text_load_faces(&t) {
			fmt.eprintln("wraptest: no fonts loaded")
			return true
		}
		content := "the quick brown fox jumps over the lazy dog\nshort line\nsupercalifragilisticexpialidocious_longword"
		doc: Document
		doc.pt = base.pt_init(transmute([]u8)content)
		cols := 20
		fmt.printfln("wrap at %d cells:", cols)
		p := 0
		for p < doc.pt.length {
			e, le := wrap_row_end(&doc, &t, p, cols)
			fmt.printfln("  [%2d,%2d) line_end=%-5v %q", p, e, le, content[p:e])
			p = e + 1 if le else e
		}
		base.pt_destroy(&doc.pt)
		return true
	}

	if len(os.args) < 3 {return false}
	path, mode := os.args[1], os.args[2]

	switch {
	case mode == "count":
		doc, ok := doc_open(path)
		if !ok {
			fmt.eprintfln("could not open %s", path)
			return true
		}
		doc_index_start(&doc)
		t0 := time.tick_now()
		for !doc_index_done(&doc) && !doc_index_faulted(&doc) {
			time.sleep(time.Millisecond)
		}
		if doc_index_faulted(&doc) {fmt.eprintln("warning: mapped read faulted mid-index (file changed on disk)")}
		fmt.printfln("indexed %d lines in %.1f ms (%d bytes, %v)", doc_line_count(&doc), time.duration_milliseconds(time.tick_since(t0)), doc.pt.length, doc.enc)
		doc_close(&doc)

	case mode == "keytest":
		app: App
		if !app_open_path(&app, path) {app_new_scratch(&app)} // e.g. "hello world foo"
		dummy: plat.Window
		dtext: plat.Text // these commands don't measure text
		key_chk(resolve_key(.Left, false, false, .Editor), .Cursor_Left, "Left / Editor")
		key_chk(resolve_key(.Left, true, false, .Editor), .Word_Left, "Ctrl+Left / Editor")
		key_chk(resolve_key(.F, true, false, .Editor), .Find_Open, "Ctrl+F / Editor")
		key_chk(resolve_key(.Z, false, true, .Editor), .Toggle_Wrap, "Alt+Z / Editor")
		key_chk(resolve_key(.Enter, false, false, .Editor), .Insert_Newline, "Enter / Editor")
		key_chk(resolve_key(.Enter, false, false, .Find), .Find_Confirm, "Enter / Find")
		key_chk(resolve_key(.Escape, false, false, .Find), .Find_Close, "Esc / Find")
		key_chk(resolve_key(.H, true, false, .Editor), .Replace_Open, "Ctrl+H / Editor")
		key_chk(resolve_key(.H, true, false, .Find), .Find_Toggle_Replace_Mode, "Ctrl+H / Find")
		key_chk(resolve_key(.A, false, false, .Editor), .None, "a (unbound)")
		// dispatch effects (dummy window/text; these commands don't touch them)
		app_active(&app).cursor = 0
		command_dispatch(resolve_key(.Right, false, false, .Editor), {.Right, false, false, false}, &app, &dummy, &dtext, 10)
		fmt.printfln("dispatch Right    -> cursor=%d", app_active(&app).cursor)
		command_dispatch(.Toggle_Wrap, {}, &app, &dummy, &dtext, 10)
		fmt.printfln("dispatch Alt+Z    -> wrap=%v", app_active(&app).wrap)
		command_dispatch(resolve_key(.F, true, false, .Editor), {.F, true, false, false}, &app, &dummy, &dtext, 10)
		fmt.printfln("dispatch Ctrl+F   -> find.active=%v", app_active(&app).find.active)
		command_dispatch(resolve_key(.Escape, false, false, .Find), {.Escape, false, false, false}, &app, &dummy, &dtext, 10)
		fmt.printfln("dispatch Esc      -> find.active=%v", app_active(&app).find.active)
		// tab commands
		command_dispatch(.Tab_New, {}, &app, &dummy, &dtext, 10)
		fmt.printfln("Tab_New           -> live tabs=%d active=%d", app_live_count(&app), app.active)
		command_dispatch(.Tab_Close, {}, &app, &dummy, &dtext, 10)
		fmt.printfln("Tab_Close         -> live tabs=%d", app_live_count(&app))
		app_destroy(&app)

	case mode == "edittest":
		doc, _ := doc_open(path)
		pre :: proc(s: string) -> string {return s[:min(len(s), 8)]}
		doc.cursor = 0
		doc_insert_rune(&doc, 'A')
		doc_insert_rune(&doc, 'B')
		doc_insert_rune(&doc, '\n')
		fmt.printfln("insert AB\\n : %q  (%d lines)", pre(doc_debug_string(&doc)), doc.nl_delta)
		doc_backspace(&doc)
		fmt.printfln("backspace  : %q", pre(doc_debug_string(&doc)))
		doc_cursor_right(&doc, false)
		doc_delete_fwd(&doc)
		fmt.printfln("del-fwd @1 : %q", pre(doc_debug_string(&doc)))
		doc_undo(&doc)
		doc_undo(&doc)
		fmt.printfln("undo x2    : %q", pre(doc_debug_string(&doc)))
		doc_redo(&doc)
		fmt.printfln("redo x1    : %q", pre(doc_debug_string(&doc)))
		doc_close(&doc)

	case mode == "savetest" && len(os.args) > 3:
		outp := os.args[3]
		doc, _ := doc_open(path)
		doc.cursor = 0
		doc_insert_text(&doc, transmute([]u8)string("SAVED:"))
		ok2 := doc_save(&doc, outp)
		fmt.printfln("save ok=%v enc=%v had_bom=%v", ok2, doc.enc, doc.had_bom)
		doc_close(&doc)
		doc2, r2 := doc_open(outp)
		if r2 {
			s := doc_debug_string(&doc2)
			fmt.printfln("reopened %q (%d bytes, enc=%v)", s[:min(len(s), 16)], doc2.pt.length, doc2.enc)
			doc_close(&doc2)
		}

	case mode == "seltest":
		p8 :: proc(s: string) -> string {return s[:min(len(s), 14)]}
		doc, _ := doc_open(path) // e.g. "hello world foo"
		doc.anchor = 6
		doc.cursor = 11
		fmt.printfln("selection [6,11): %q", doc_selected_text(&doc, context.temp_allocator))
		doc_insert_rune(&doc, 'Z') // replace selection
		fmt.printfln("replace sel : %q", p8(doc_debug_string(&doc)))
		doc_undo(&doc)
		fmt.printfln("undo        : %q sel=%q", p8(doc_debug_string(&doc)), doc_selected_text(&doc, context.temp_allocator))
		doc_select_word_at(&doc, 2) // inside "hello"
		lo, hi := doc_sel_range(&doc)
		fmt.printfln("word@2      : [%d,%d) %q", lo, hi, doc_selected_text(&doc, context.temp_allocator))
		doc_select_all(&doc)
		fmt.printfln("select all  : anchor=%d cursor=%d", doc.anchor, doc.cursor)
		plat.clipboard_set_text(nil, "clip round-trip ✓")
		if g, gok := plat.clipboard_get_text(nil, context.temp_allocator); gok {
			fmt.printfln("clipboard   : %q", g)
		}
		doc_close(&doc)

	case mode == "repltest" && len(os.args) > 4:
		doc, _ := doc_open(path)
		find_open(&doc, true)
		for r in os.args[3] {find_input_rune(&doc, r)} // query (field 0)
		doc.find.field = 1
		for r in os.args[4] {find_input_rune(&doc, r)} // replacement
		doc.find.field = 0
		fmt.printfln("query=%q replace=%q matches=%d", os.args[3], os.args[4], len(doc.find.matches))
		find_replace_all(&doc)
		s := doc_debug_string(&doc)
		fmt.printfln("after replace all: %q", s[:min(len(s), 40)])
		doc_close(&doc)

	case mode == "filtertest" && len(os.args) > 3:
		doc, _ := doc_open(path)
		find_open(&doc, false)
		for r in os.args[3] {find_input_rune(&doc, r)}
		fmt.printfln("query=%q matches=%d filter_lines=%d", os.args[3], len(doc.find.matches), len(doc.filter_lines))
		for ls in doc.filter_lines {
			fmt.printfln("  %q", doc_line_text(&doc, ls, context.temp_allocator))
		}
		doc_close(&doc)

	case mode == "findtest" && len(os.args) > 3:
		doc, _ := doc_open(path)
		find_open(&doc, false)
		if len(os.args) > 4 && os.args[4] == "rx" {doc.find.regex = true}
		for r in os.args[3] {find_input_rune(&doc, r)}
		fmt.printf("query=%q matches=%d offsets:", string(doc.find.query[:]), len(doc.find.matches))
		for m in doc.find.matches {fmt.printf(" %d", m)}
		fmt.printfln("  current=%d", doc.find.current)
		if len(doc.find.matches) > 0 {
			find_next(&doc)
			fmt.printfln("next -> current=%d (cursor %d)", doc.find.current, doc.cursor)
			find_prev(&doc)
			find_prev(&doc)
			fmt.printfln("prev x2 -> current=%d", doc.find.current)
		}
		doc_close(&doc)

	case:
		return false // not a recognized mode; fall through to the GUI
	}
	return true
}
