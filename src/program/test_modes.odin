// Layer: program — headless verification entry points. The environment can't
// inject GUI keyboard/focus, so features are exercised through these argv modes
// (`newtpad <file> <mode> ...`) and checked against printed output. Kept out of
// main.odin so the frame loop reads clean.
package main

import "core:fmt"
import "core:os"
import "core:time"
import plat "src:platform"

// Run a headless test mode if argv selects one. Returns true if a mode ran (the
// caller should then exit). `seh_install` has already run in main.
test_mode_dispatch :: proc() -> (handled: bool) {
	if len(os.args) < 2 {return false}

	// `newtpad sehtest` proves the SEH guard catches a real page fault.
	if os.args[1] == "sehtest" {
		fmt.printfln("seh guard caught + zero-filled a page fault: %v", plat.seh_selftest())
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
