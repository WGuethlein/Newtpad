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
