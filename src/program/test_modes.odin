// Layer: program — headless verification entry points. The environment can't
// inject GUI keyboard/focus, so features are exercised through these argv modes
// (`newtpad <file> <mode> ...`) and checked against printed output. Kept out of
// main.odin so the frame loop reads clean.
package main

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"
import "core:unicode/utf8"
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

	// `newtpad regextest` times an incremental regex find over a synthetic buffer
	// large enough that the old materialize-the-whole-document path stalled, and
	// checks the matches are the ones we planted.
	if os.args[1] == "regextest" {
		mb := 64
		if len(os.args) > 2 {
			n, _ := strconv.parse_int(os.args[2])
			mb = max(1, n)
		}
		line := "2026-07-19 INFO  request served in 12ms path=/health\n" // 52 bytes
		reps := (mb * 1024 * 1024) / len(line)
		content := make([]u8, reps * len(line))
		defer delete(content)
		for i in 0 ..< reps {copy(content[i * len(line):], transmute([]u8)line)}
		// Plant a distinctive match in the final line, past every block boundary.
		// Overwrite only the head of that line so its trailing newline survives.
		plant := "2026-07-19 ERROR boom path=/NEEDLE-ZZZ"
		copy(content[len(content) - len(line):], transmute([]u8)plant)

		doc: Document
		doc.pt = base.pt_init(content)
		defer base.pt_destroy(&doc.pt)
		fmt.printfln("buffer: %.1f MB", f64(doc.pt.length) / (1024 * 1024))

		doc.find.regex = true
		find_open(&doc, false)
		// Type the pattern one rune at a time. Each keystroke restarts the
		// search; on a buffer this size that hands off to the worker, so the
		// keystroke itself must return well inside a 16 ms frame no matter how
		// big the file is. The "settled" column is the worker's full pass.
		pattern := "NEEDLE-[A-Z]+"
		worst := 0.0
		for r in pattern {
			t0 := time.tick_now()
			find_input_rune(&doc, r)
			key_ms := time.duration_milliseconds(time.tick_since(t0))
			worst = max(worst, key_ms)
			t1 := time.tick_now()
			find_wait(&doc)
			settled_ms := time.duration_milliseconds(time.tick_since(t1))
			fmt.printfln("  %-15q key %6.2f ms  settled %7.1f ms  %6d matches%s", string(doc.find.query[:]), key_ms, settled_ms, len(doc.find.matches), " (truncated)" if doc.find.truncated else "")
		}
		fmt.printfln("worst keystroke: %.2f ms (frame budget 16.7)", worst)
		if len(doc.find.matches) > 0 {
			m := doc.find.matches[0]
			fmt.printfln("planted needle found at %d (%.1f MB in), len=%d", m, f64(m) / (1024 * 1024), doc.find.match_len[0])
		} else {
			fmt.println("planted needle NOT found")
		}

		// Edit the document while a search is in flight. This is the path that
		// used to be a use-after-free: the worker is mid-read of the piece tree
		// and the add arena while the main thread mutates both. The edit must
		// cancel the worker, and the restarted search must still be correct.
		clear(&doc.find.query)
		find_recompute(&doc) // restart, then edit immediately without waiting
		append(&doc.find.query, ..transmute([]u8)string("NEEDLE-[A-Z]+"))
		find_recompute(&doc)
		edits := 0
		for i in 0 ..< 200 { // typing while the worker scans
			doc.cursor = 0
			doc.anchor = 0
			doc_insert_text(&doc, transmute([]u8)string("x"))
			edits += 1
		}
		find_wait(&doc)
		fmt.printfln("edited %d times mid-search; survived, %d matches after", edits, len(doc.find.matches))
		if len(doc.find.matches) > 0 {
			// Every inserted byte landed at offset 0, so the needle shifted right.
			m := doc.find.matches[0]
			fmt.printfln("needle re-found at %d (shifted by %d)", m, edits)
		}
		find_close(&doc)
		return true
	}

	// `newtpad findtest` covers the literal scan's block-boundary handling and
	// the line starts the worker computes for the filter view — both of which
	// are per-block bookkeeping that a single-block search would never exercise.
	if os.args[1] == "findtest" {
		line := "0123456789abcdefghijklmnopqrstuvwxyz-------------\n" // 50 bytes
		reps := (3 * SEARCH_BLOCK) / len(line)
		content := make([]u8, reps * len(line))
		defer delete(content)
		for i in 0 ..< reps {copy(content[i * len(line):], transmute([]u8)line)}

		// Straddle the first block boundary: half the needle in block 0, half in
		// block 1. Found only if the scan overlaps blocks by len(query)-1.
		straddle := "STRADDLE"
		at := SEARCH_BLOCK - 4
		copy(content[at:], transmute([]u8)straddle)
		// And one wholly inside the second block, to prove the boundary case
		// isn't the only thing that works.
		later := SEARCH_BLOCK + 12345
		copy(content[later:], transmute([]u8)straddle)

		doc: Document
		doc.pt = base.pt_init(content)
		defer base.pt_destroy(&doc.pt)
		defer find_close(&doc)

		find_open(&doc, false)
		for r in straddle {find_input_rune(&doc, r)}
		find_wait(&doc)
		fmt.printfln("buffer %d KB, block %d KB", doc.pt.length / 1024, SEARCH_BLOCK / 1024)
		fmt.printfln("straddling match: %d found, want 2", len(doc.find.matches))
		for m, i in doc.find.matches {
			want := at if i == 0 else later
			fmt.printfln("  match %d at %d want %d  %s", i, m, want, "OK" if m == want else "FAIL")
		}
		// Line numbers for the filter gutter, counted by the worker in the same
		// pass. Every match here is on its own line, so number == index+1 within
		// its block of the synthetic file.
		fmt.printfln("filter line numbers: %d recorded (want %d)", len(doc.filter_line_nos), len(doc.filter_lines))
		nums_ok := len(doc.filter_line_nos) == len(doc.filter_lines)
		for ln, i in doc.filter_line_nos {
			want := doc.filter_lines[i] / len(line) + 1 // fixed-width lines
			if ln != want {
				fmt.printfln("  line %d: got %d want %d FAIL", i, ln, want)
				nums_ok = false
			}
		}
		fmt.printfln("line numbers correct: %v  %s", nums_ok, "OK" if nums_ok else "FAIL")

		// The gutter must widen with the largest number, and col_x/col_at_x must
		// both shift by it or the caret lands in the wrong column.
		{
			t2: plat.Text
			plat.text_load_faces(&t2)
			cw := plat.text_char_width(&t2, 16)
			doc.filter = true
			doc_update_gutter(&doc, cw)
			g := GUTTER_W
			round := col_at_x(cw, col_x(cw, 7)) == 7
			fmt.printfln("gutter %0.f px, col_x/col_at_x round-trip: %v  %s", g, round, "OK" if g > 0 && round else "FAIL")
			doc.filter = false
			doc_update_gutter(&doc, cw)
			off := GUTTER_W == 0
			fmt.printfln("no gutter outside filter view: %v  %s", off, "OK" if off else "FAIL")
		}

		// Line starts drive the filter view; each match is on its own line here.
		fmt.printfln("filter lines: %d (want 2)", len(doc.filter_lines))
		for fl, i in doc.filter_lines {
			m := doc.find.matches[i]
			want := (m / len(line)) * len(line)
			fmt.printfln("  line %d start %d want %d  %s", i, fl, want, "OK" if fl == want else "FAIL")
		}
		// Case-insensitive, matching the find bar's behaviour.
		clear(&doc.find.query)
		for r in "straddle" {find_input_rune(&doc, r)}
		find_wait(&doc)
		fmt.printfln("case-insensitive: %d found, want 2", len(doc.find.matches))
		return true
	}

	// `newtpad fonttest` — which curated families are installed, and whether each
	// style keeps the same advance. The whole renderer is a cell grid built on
	// one advance width, so a style that differs would slide glyphs out from
	// under the caret.
	if os.args[1] == "fonttest" {
		bad := 0
		t: plat.Text
		if !plat.text_load_faces(&t) {
			fmt.eprintln("fonttest: no fonts loaded")
			return true
		}
		base_em := plat.text_char_em(&t)
		fmt.printfln("default Consolas char_em %.4f", base_em)
		if base_em <= 0 {bad += 1}

		fmt.println("--- curated families ---")
		found := 0
		for f in plat.FONT_FAMILIES {
			avail := plat.font_family_available(f)
			if !avail {
				fmt.printfln("  %-24s not installed", f.name)
				continue
			}
			found += 1
			// Every style must load and keep the family's advance.
			ems: [4]f32
			consistent := true
			for st, si in ([]plat.Font_Style{.Regular, .Bold, .Italic, .Bold_Italic}) {
				if !plat.text_load_family(&t, f.name, st) {
					fmt.printfln("  %-24s FAILED to load %v", f.name, st)
					bad += 1
					consistent = false
					break
				}
				ems[si] = plat.text_char_em(&t)
				if ems[si] <= 0 {consistent = false}
				if si > 0 && abs(ems[si] - ems[0]) > 0.0001 {consistent = false}
			}
			fmt.printfln("  %-24s em %.4f  styles consistent=%v %s", f.name, ems[0], consistent, "OK" if consistent else "FAIL")
			if !consistent {bad += 1}
		}
		fmt.printfln("%d of %d curated families installed", found, len(plat.FONT_FAMILIES))
		if found == 0 {bad += 1}

		// The font page must offer only families that actually loaded, and
		// cycling must stay in range.
		font_choices_refresh()
		fmt.printfln("font page offers %d families", len(font_choices))
		idx_ok := font_choice_index("Consolas") >= 0 && font_choice_index("Not Installed") == 0
		fmt.printfln("index lookup: known>=0 and unknown->0: %v  %s", idx_ok, "OK" if idx_ok else "FAIL")
		if !idx_ok {bad += 1}

		// An unknown family must fall back, not fail — a settings file copied
		// from another machine can name a font that isn't here.
		okf := plat.text_load_family(&t, "No Such Font 12345", .Regular)
		fmt.printfln("unknown family falls back: %v  %s", okf, "OK" if okf else "FAIL")
		if !okf {bad += 1}

		// The chrome and the document must be independent: choosing a font for
		// your text should never change the menus, and the two cell widths must
		// not be shared. Both chains started as Consolas, so pick a family with a
		// visibly different advance.
		fmt.println("--- chrome vs document faces ---")
		other := ""
		for f in plat.FONT_FAMILIES {
			if f.name != "Consolas" && plat.font_family_available(f) {
				other = f.name
				break
			}
		}
		if other == "" {
			fmt.println("  (only Consolas installed; cannot distinguish)")
		} else {
			ui_before := plat.text_char_em(&t, .UI)
			plat.text_load_family(&t, other, .Regular, .Doc)
			ui_after := plat.text_char_em(&t, .UI)
			doc_after := plat.text_char_em(&t, .Doc)
			unchanged := ui_before == ui_after
			differs := doc_after != ui_after
			fmt.printfln("  doc -> %s: ui em %.4f -> %.4f (unchanged=%v), doc em %.4f (differs=%v)  %s", other, ui_before, ui_after, unchanged, doc_after, differs, "OK" if unchanged && differs else "FAIL")
			if !(unchanged && differs) {bad += 1}
			plat.text_load_family(&t, "Consolas", .Regular, .Doc)
		}

		fmt.printfln("fonttest: %d failures", bad)
		return true
	}

	// `newtpad watchtest <dir>` — external-change detection and reconciliation.
	// This feature changes the document without the user asking, so the failure
	// mode is data loss rather than a wrong pixel.
	if os.args[1] == "watchtest" && len(os.args) > 2 {
		bad := 0
		dir := os.args[2]
		path := fmt.tprintf("%s\\watch.txt", dir)

		plat.file_write_atomic(path, transmute([]u8)string("line one\nline two\n"))
		doc, ok := doc_open(path)
		if !ok {
			fmt.println("watchtest: could not open")
			return true
		}
		defer doc_close(&doc)
		s0 := doc.disk_stamp
		fmt.printfln("opened: %d bytes, stamp ok=%v", doc.pt.length, s0.ok)
		if !s0.ok {bad += 1}

		// A service appends. The tail must be absorbed without re-reading the
		// whole file and without disturbing offsets before the old end.
		f, _ := os.open(path, os.O_WRONLY | os.O_APPEND)
		os.write(f, transmute([]u8)string("line three\n"))
		os.close(f)
		s1 := plat.file_stamp(path)
		changed := s1 != s0
		fmt.printfln("after append: detected=%v size %d -> %d", changed, s0.size, s1.size)
		if !changed {bad += 1}

		doc.cursor = doc.pt.length // pretend the caret was at EOF, as when tailing
		doc.anchor = doc.cursor
		absorbed := doc_absorb_append(&doc, s1.size)
		txt := doc_debug_string(&doc)
		tail_ok := absorbed && doc.pt.length == int(s1.size) && doc.cursor == doc.pt.length
		fmt.printfln("absorbed=%v len=%d (want %d) caret follows=%v  %s", absorbed, doc.pt.length, s1.size, doc.cursor == doc.pt.length, "OK" if tail_ok else "FAIL")
		if !tail_ok {bad += 1}
		fmt.printfln("  content: %q", txt)

		// Save, then let the file grow. The append offset must come from the file
		// as last seen, not from the original length — otherwise the bytes we
		// just saved get read back and inserted a second time.
		{
			doc.cursor, doc.anchor = 0, 0
			doc_insert_text(&doc, transmute([]u8)string("EDIT"), .Paste)
			doc_save(&doc, path)
			saved := doc_debug_string(&doc)
			f2, _ := os.open(path, os.O_WRONLY | os.O_APPEND)
			os.write(f2, transmute([]u8)string("tail\n"))
			os.close(f2)
			s2 := plat.file_stamp(path)
			doc_absorb_append(&doc, s2.size)
			got := doc_debug_string(&doc)
			want := fmt.tprintf("%s%s", saved, "tail\n")
			dup_ok := got == want
			fmt.printfln("append after save: %q  %s", got[:min(len(got), 32)], "OK" if dup_ok else "FAIL")
			if !dup_ok {
				fmt.printfln("  want %q", want[:min(len(want), 32)])
				bad += 1
			}
		}

		// Shrinking is not an append: it must be refused so the caller reloads.
		refused := !doc_absorb_append(&doc, 5)
		fmt.printfln("shrink refused by append path: %v  %s", refused, "OK" if refused else "FAIL")
		if !refused {bad += 1}

		// A rewrite that is not an append -> full reload, position preserved.
		plat.file_write_atomic(path, transmute([]u8)string("completely different\ncontent here\n"))
		doc.cursor = 5
		doc.anchor = 5
		rok := doc_reload(&doc)
		after := doc_debug_string(&doc)
		reload_ok := rok && doc.cursor == 5 && !doc.disk_changed
		fmt.printfln("reload=%v caret=%d stamp refreshed=%v  %s", rok, doc.cursor, doc.disk_stamp.ok, "OK" if reload_ok else "FAIL")
		if !reload_ok {bad += 1}
		fmt.printfln("  content: %q", after[:min(len(after), 24)])

		// A caret past the new end must clamp, not index out of bounds.
		plat.file_write_atomic(path, transmute([]u8)string("tiny\n"))
		doc.cursor = 999
		doc.anchor = 999
		doc_reload(&doc)
		clamped := doc.cursor <= doc.pt.length
		fmt.printfln("caret clamped after shrink: %d <= %d  %s", doc.cursor, doc.pt.length, "OK" if clamped else "FAIL")
		if !clamped {bad += 1}

		// Encodings whose bytes do not map 1:1 to document bytes must never take
		// the append fast path: a BOM shifts every offset, UTF-16 is transcoded.
		doc.enc = .UTF16LE
		u16_refused := !doc_absorb_append(&doc, i64(doc.pt.length + 10))
		doc.enc = .UTF8
		doc.had_bom = true
		bom_refused := !doc_absorb_append(&doc, i64(doc.pt.length + 10))
		doc.had_bom = false
		fmt.printfln("append refused for UTF-16=%v and BOM=%v  %s", u16_refused, bom_refused, "OK" if u16_refused && bom_refused else "FAIL")
		if !(u16_refused && bom_refused) {bad += 1}

		fmt.printfln("watchtest: %d failures", bad)
		return true
	}

	// `newtpad atlastest` — how much text actually fits in the glyph atlas at a
	// given size. The atlas has no per-glyph eviction (a shelf packer cannot free
	// one rectangle), so when it fills it grows and ultimately recycles; this
	// pins the capacity that decision rests on. A CJK document needs thousands of
	// distinct glyphs, which is what overflowed the old fixed 1024.
	if os.args[1] == "atlastest" {
		bad := 0
		// Distinct glyphs is bounded by the character repertoire in use, not by
		// cell count: a dense CJK page is ~3000 distinct characters, and Latin
		// text across 4 font styles is ~400. Viewport-first means only visible
		// glyphs are ever rasterized, so this is the working set to hold.
		//
		// The bar applies to normal sizes (<= 64px effective). Above that the
		// atlas recycles instead, which is a designed fallback, not a failure —
		// at 144px a screen holds a few hundred cells anyway.
		HEAVY :: 3000 // dense CJK page, one style
		for px in ([]i32{16, 24, 32, 48, 64, 96, 144}) {
			// Consolas ink box: roughly 0.55*px wide by 1.05*px tall + AA bleed.
			gw := i32(f32(px) * 0.55) + 4
			gh := i32(f32(px) * 1.05) + 4
			c1 := plat.text_atlas_fit_count(1024, gw, gh)
			c3 := plat.text_atlas_fit_count(plat.ATLAS_MAX, gw, gh)
			normal := px <= 64
			ok := !normal || c3 >= HEAVY
			if !ok {bad += 1}
			note := "recycles (expected at this size)"
			if c3 >= HEAVY {note = "holds a heavy page"}
			fmt.printf("px %v  box %vx%v  1024 fits %v  4096 fits %v  ", px, gw, gh, c1, c3)
			fmt.printfln("%s  %s", note, "OK" if ok else "FAIL")
		}
		// The old fixed 1024 could not hold a heavy page at any usable size —
		// which is the bug this replaced, and the reason growth exists.
		small := plat.text_atlas_fit_count(1024, 21, 37) // 32px
		fmt.printfln("old fixed 1024 at 32px fits %v of %v needed -> growth required  %s", small, HEAVY, "OK" if small < HEAVY else "FAIL")
		if small >= HEAVY {bad += 1}
		// A glyph bigger than the atlas can never be packed; that must be
		// reported rather than looping forever.
		huge := plat.text_atlas_fit_count(1024, 2000, 2000)
		fmt.printfln("glyph larger than atlas -> %d (want 0)  %s", huge, "OK" if huge == 0 else "FAIL")
		if huge != 0 {bad += 1}
		fmt.printfln("atlastest: %d failures", bad)
		return true
	}

	// `newtpad savefailtest <path>` — a save that fails must say WHY. Release
	// builds are -subsystem:windows, so the old stderr report was invisible and a
	// failed save was indistinguishable from a successful one.
	if os.args[1] == "savefailtest" && len(os.args) > 2 {
		bad := 0
		target := os.args[2]

		// A directory that does not exist: the temp file cannot be created.
		e1 := plat.file_write_atomic_err(fmt.tprintf("%s\\nope\\deep\\x.txt", target), transmute([]u8)string("hi"))
		fmt.printfln("missing dir      -> %-12v %s", e1, "OK" if e1 == .Create_Temp else "FAIL")
		if e1 != .Create_Temp {bad += 1}

		// A normal write succeeds.
		good := fmt.tprintf("%s\\ok.txt", target)
		e2 := plat.file_write_atomic_err(good, transmute([]u8)string("hello"))
		fmt.printfln("normal write     -> %-12v %s", e2, "OK" if e2 == .None else "FAIL")
		if e2 != .None {bad += 1}

		// Every failure must produce a non-empty, specific message. A blank or
		// generic one is the same bug in a different place.
		for e in ([]plat.Write_Error{.Create_Temp, .Write, .Replace}) {
			msg := plat.write_error_text(e, good)
			ok := len(msg) > 20
			fmt.printfln("  text(%-12v) %d chars %s", e, len(msg), "OK" if ok else "FAIL")
			if !ok {bad += 1}
		}
		// The locked-file case is the one that matters most; say so explicitly.
		rep := plat.write_error_text(.Replace, good)
		mentions := false
		for i in 0 ..< len(rep) - 8 {if rep[i:i + 8] == "NOT been" {mentions = true}}
		fmt.printfln("replace text warns changes are unsaved: %v %s", mentions, "OK" if mentions else "FAIL")
		if !mentions {bad += 1}

		fmt.printfln("savefailtest: %d failures", bad)
		return true
	}

	// `newtpad historytest` covers undo coalescing, the entry cap, and jumping to
	// an arbitrary state.
	if os.args[1] == "historytest" {
		bad := 0
		doc: Document
		doc.pt = base.pt_init(nil)
		defer base.pt_destroy(&doc.pt)

		// A typing run is one entry, not one per character.
		for r in "hello" {doc_insert_rune(&doc, r)}
		one := len(doc.undo)
		fmt.printfln("typed 5 chars -> %d undo entries (want 1)  %s", one, "OK" if one == 1 else "FAIL")
		if one != 1 {bad += 1}

		// A caret jump breaks the run.
		doc.cursor = 0
		doc.anchor = 0
		doc_insert_rune(&doc, 'X')
		two := len(doc.undo)
		fmt.printfln("caret jump then type -> %d entries (want 2)  %s", two, "OK" if two == 2 else "FAIL")
		if two != 2 {bad += 1}

		// A newline breaks it too, so undo stops at line boundaries.
		doc.cursor = doc.pt.length
		doc.anchor = doc.cursor
		doc_insert_rune(&doc, '\n')
		doc_insert_rune(&doc, 'a')
		fmt.printfln("newline splits run -> %d entries (want 4)  %s", len(doc.undo), "OK" if len(doc.undo) == 4 else "FAIL")
		if len(doc.undo) != 4 {bad += 1}

		// Undo walks whole runs: one Ctrl+Z should remove "hello", not "o".
		before := doc_debug_string(&doc)
		for len(doc.undo) > 0 {doc_undo(&doc)}
		empty := doc.pt.length == 0
		fmt.printfln("undo to start: %q -> len %d  %s", before[:min(len(before), 12)], doc.pt.length, "OK" if empty else "FAIL")
		if !empty {bad += 1}

		// Jump forward to the newest state, then back to the middle.
		n := doc_history_len(&doc)
		doc_history_goto(&doc, n - 1)
		newest := doc_debug_string(&doc)
		doc_history_goto(&doc, 1)
		mid := doc_history_current(&doc)
		fmt.printfln("goto newest %q then state 1 -> current %d  %s", newest[:min(len(newest), 12)], mid, "OK" if mid == 1 else "FAIL")
		if mid != 1 {bad += 1}

		// The cap must hold, and dropping the oldest must not corrupt the rest.
		doc2: Document
		doc2.pt = base.pt_init(nil)
		defer base.pt_destroy(&doc2.pt)
		for i in 0 ..< UNDO_MAX + 50 {
			doc2.cursor = 0 // force a new entry every time
			doc2.anchor = 0
			doc_insert_rune(&doc2, 'z')
		}
		capped := len(doc2.undo) <= UNDO_MAX
		fmt.printfln("%d edits -> %d entries (cap %d)  %s", UNDO_MAX + 50, len(doc2.undo), UNDO_MAX, "OK" if capped else "FAIL")
		if !capped {bad += 1}
		doc_history_goto(&doc2, 0) // walk to the oldest surviving state
		fmt.printfln("walk to oldest after eviction: len %d  OK", doc2.pt.length)

		// Labels must survive moving between the undo and redo stacks. A state
		// that lost its description on the way back read as "As opened", so
		// jumping to an entry renamed it and it never came back.
		{
			d3: Document
			d3.pt = base.pt_init(nil)
			defer base.pt_destroy(&d3.pt)
			for r in "abc" {doc_insert_rune(&d3, r)}
			d3.cursor, d3.anchor = 0, 0
			doc_insert_text(&d3, transmute([]u8)string("XY"), .Paste)
			d3.cursor = d3.pt.length
			d3.anchor = d3.cursor
			doc_insert_rune(&d3, '\n')

			n := doc_history_len(&d3)
			before := make([]string, n);defer delete(before)
			for i in 0 ..< n {before[i] = strings.clone(doc_history_label(&d3, i))}
			fmt.println("labels as recorded:")
			for s, i in before {fmt.printfln("  %d %s", i, s)}

			// Walk all the way back and forward again; every label must match.
			doc_history_goto(&d3, 0)
			doc_history_goto(&d3, n - 1)
			stable := true
			for i in 0 ..< n {
				now := doc_history_label(&d3, i)
				if now != before[i] {
					fmt.printfln("  MISMATCH at %d: %q -> %q", i, before[i], now)
					stable = false
				}
			}
			for s in before {delete(s)}
			fmt.printfln("labels stable across undo/redo round trip: %v  %s", stable, "OK" if stable else "FAIL")
			if !stable {bad += 1}

			// The oldest state is the file as opened, not an edit.
			doc_history_goto(&d3, 0)
			first := doc_history_label(&d3, 0)
			fok := first == "As opened"
			fmt.printfln("oldest entry reads %q  %s", first, "OK" if fok else "FAIL")
			if !fok {bad += 1}
		}

		// Row hit-testing must account for the scroll offset: with more entries
		// than fit, the row drawn k places down is entry top+k. Reading it as
		// entry k picks the wrong state to jump to.
		{
			a: App
			app_add(&a, &doc2)
			a.active = 0
			history_open(&a)
			W := f32(1200)
			x := W - HISTORY_W - SCROLLBAR_W + sx(10) // inside the panel
			y0 := CONTENT_TOP + sx(28)

			a.history.rows = 10
			a.history.top = 0
			r0 := history_row_at(&a, x, y0 + HISTORY_ROW * 0.5, W)
			r3 := history_row_at(&a, x, y0 + HISTORY_ROW * 3.5, W)
			a.history.top = 25 // scrolled down
			s0 := history_row_at(&a, x, y0 + HISTORY_ROW * 0.5, W)
			s3 := history_row_at(&a, x, y0 + HISTORY_ROW * 3.5, W)
			off := history_row_at(&a, x, y0 - sx(4), W) // above the first row
			out := history_row_at(&a, x, y0 + HISTORY_ROW * 50, W) // past the last drawn
			left := history_row_at(&a, sx(4), y0 + HISTORY_ROW * 0.5, W) // outside the panel

			ok := r0 == 0 && r3 == 3 && s0 == 25 && s3 == 28 && off == -1 && out == -1 && left == -1
			fmt.printfln("row hit-test: top0->%d,%d top25->%d,%d  edges %d,%d,%d  %s", r0, r3, s0, s3, off, out, left, "OK" if ok else "FAIL")
			if !ok {bad += 1}
			a.docs[0] = nil // doc2 is stack-owned here; don't let app_destroy free it
		}

		fmt.printfln("historytest: %d failures", bad)
		return true
	}

	// `newtpad settingstest` round-trips settings.txt and checks the defaults and
	// clamps. Set NEWTPAD_SESSION_DIR first — it writes to the session store.
	if os.args[1] == "settingstest" {
		bad := 0
		d := settings_default()
		fmt.printfln("defaults: restore=%v wrap=%v font=%d", d.restore_session, d.wrap_default, d.font_size)
		if !d.restore_session {
			fmt.println("  FAIL restore should default on")
			bad += 1
		}

		// Round-trip non-default values.
		w := Settings {
			restore_session = false,
			wrap_default    = true,
			font_size       = 22,
			zoom_pct        = 125,
			font_family     = "Courier New",
			font_style      = .Italic,
		}
		settings_save(w)
		r := settings_load()
		ok := r == w
		fmt.printfln("round-trip: restore=%v wrap=%v font=%d zoom=%d family=%q style=%v  %s", r.restore_session, r.wrap_default, r.font_size, r.zoom_pct, r.font_family, r.font_style, "OK" if ok else "FAIL")
		if !ok {bad += 1}

		// An empty family must normalise on the way out, not persist as blank —
		// a blank family would resolve to the first curated entry on next load
		// and look like the setting silently changed.
		settings_save(Settings{font_size = 16, zoom_pct = 100})
		blank := settings_load()
		bok := blank.font_family == "Consolas"
		fmt.printfln("blank family normalises to %q  %s", blank.font_family, "OK" if bok else "FAIL")
		if !bok {bad += 1}

		// An out-of-range font size on disk must clamp, not propagate.
		settings_save(Settings{restore_session = true, font_size = 9999})
		c := settings_load()
		cok := c.font_size <= FONT_SIZE_MAX && c.font_size >= FONT_SIZE_MIN
		fmt.printfln("clamp 9999 -> %d  %s", c.font_size, "OK" if cok else "FAIL")
		if !cok {bad += 1}

		// A missing file must give defaults rather than zeroes (font_size 0 would
		// divide into the cell grid).
		if p, pok := session_dir(); pok {os.remove(fmt.tprintf("%s%csettings.txt", p, '\\'))}
		m := settings_load()
		mok := m == settings_default() && m.font_size > 0
		fmt.printfln("missing file -> defaults (font=%d)  %s", m.font_size, "OK" if mok else "FAIL")
		if !mok {bad += 1}

		// Zoom must land on the steps, clamp at both ends, and compose with the
		// font size rather than replacing it.
		fmt.println("--- zoom ---")
		t2: plat.Text
		plat.text_load_faces(&t2)
		wz: plat.Window
		wz.dpi = 96
		az: App
		az.settings = settings_default()
		rcz := Render_Ctx{window = &wz, text = &t2, app = &az}
		for _ in 0 ..< 20 {zoom_adjust(&rcz, 1)}
		hi := az.settings.zoom_pct
		for _ in 0 ..< 40 {zoom_adjust(&rcz, -1)}
		lo := az.settings.zoom_pct
		zoom_adjust(&rcz, 0)
		rst := az.settings.zoom_pct
		zok := hi == ZOOM_STEPS[len(ZOOM_STEPS) - 1] && lo == ZOOM_STEPS[0] && rst == ZOOM_DEFAULT
		fmt.printfln("  clamp hi=%d lo=%d reset=%d  %s", hi, lo, rst, "OK" if zok else "FAIL")
		if !zok {bad += 1}
		// font_size 20 at 150% zoom must give px 30, not 20 or 150.
		az.settings.font_size = 20
		az.settings.zoom_pct = 150
		settings_apply(&rcz)
		pok := int(BASE_PX) == 30 && int(rcz.px) == 30
		fmt.printfln("  font 20 @150%% -> BASE_PX %.0f px %.0f (want 30)  %s", BASE_PX, rcz.px, "OK" if pok else "FAIL")
		if !pok {bad += 1}
		// ...and DPI still multiplies on top of that.
		wz.dpi = 192
		metrics_recompute(&rcz)
		dok := int(rcz.px) == 60
		fmt.printfln("  ...at 200%% DPI -> px %.0f (want 60)  %s", rcz.px, "OK" if dok else "FAIL")
		if !dok {bad += 1}
		BASE_PX = BASE_PX_96 // leave globals alone for later modes

		fmt.printfln("settingstest: %d failures", bad)
		return true
	}

	// `newtpad menutest` covers the menu model and keyboard navigation: that every
	// item names a real command, that mnemonics are unique and don't collide with
	// an explicit Alt binding, that navigation skips separators and disabled rows,
	// and that Esc unwinds one level at a time rather than dropping straight out.
	if os.args[1] == "menutest" {
		t: plat.Text
		plat.text_load_faces(&t)
		a: App
		menu_init(&a.menu)
		app_new_scratch(&a)
		defer app_destroy(&a)

		bad := 0
		// The zero value of Menu_State means "File dropdown open", so a missed
		// menu_init shows the app with a menu hanging down on launch.
		{
			raw: App
			closed_after_init: App
			menu_init(&closed_after_init.menu)
			zero_open := raw.menu.open >= 0
			init_closed := !menu_is_active(&closed_after_init)
			fmt.printfln("--- startup ---")
			fmt.printfln("  zero value would open menu %d (that's why init exists), after menu_init closed=%v %s", raw.menu.open, init_closed, "OK" if zero_open && init_closed else "FAIL")
			if !(zero_open && init_closed) {bad += 1}
		}
		fmt.println("--- model ---")
		seen: map[rune]bool;defer delete(seen)
		for m in menus {
			items, seps := 0, 0
			for it in m.items {
				if it.cmd == .None {seps += 1} else {items += 1}
				// A menu item pointing at .None that isn't a separator, or at a
				// command with no title, would render as an empty row.
				if it.cmd != .None && command_table[it.cmd].title == "" {
					fmt.printfln("  FAIL %v has an untitled command", m.title)
					bad += 1
				}
			}
			// The mnemonic must not be claimed by an explicit Alt binding, or the
			// menu becomes unreachable from the keyboard with no diagnostic.
			clash := resolve_key(char_key(m.mnemonic), false, true, .Editor)
			dup := seen[m.mnemonic]
			seen[m.mnemonic] = true
			if clash != .None || dup {bad += 1}
			fmt.printfln("  %-6s Alt+%c  %2d items %d separators  alt-clash=%v dup=%v %s", m.title, m.mnemonic, items, seps, clash, dup, "OK" if clash == .None && !dup else "FAIL")
		}

		fmt.println("--- navigation ---")
		menu_open_at(&a, 0)
		first := a.menu.item
		ok_first := first >= 0 && menus[0].items[first].cmd != .None
		fmt.printfln("  open File -> item %d (%v) %s", first, menus[0].items[first].cmd, "OK" if ok_first else "FAIL")
		if !ok_first {bad += 1}

		// Stepping down must never land on a separator or a disabled row.
		steps_ok := true
		for _ in 0 ..< 20 {
			a.menu.item = menu_step(&a, a.menu.open, a.menu.item + 1, 1)
			if a.menu.item < 0 || !item_enabled(&a, menus[a.menu.open].items[a.menu.item]) {steps_ok = false}
		}
		fmt.printfln("  20 steps stay on enabled items: %v %s", steps_ok, "OK" if steps_ok else "FAIL")
		if !steps_ok {bad += 1}

		// Esc unwinds one level: dropdown -> bar mode -> out.
		command_dispatch(.Menu_Close, {}, &a, nil, &t, 10)
		lvl1 := a.menu.open < 0 && a.menu.mode
		command_dispatch(.Menu_Close, {}, &a, nil, &t, 10)
		lvl2 := !menu_is_active(&a)
		fmt.printfln("  Esc: dropdown->bar %v, bar->out %v %s", lvl1, lvl2, "OK" if lvl1 && lvl2 else "FAIL")
		if !(lvl1 && lvl2) {bad += 1}

		// A global chord must still resolve while the menu is open.
		// Hover maps a y coordinate to a row. Separators must report -1 rather
		// than a selectable index, or hovering one highlights nothing while the
		// keyboard cursor sits somewhere else.
		fmt.println("--- hover row hit-test ---")
		menu_open_at(&a, 1) // Edit: has separators
		W, H := f32(1280), f32(720)
		dx, dw, _ := menu_dropdown_rect(&t, &a, W, H)
		inx := dx + dw * 0.5 // a point inside the dropdown horizontally
		rows_ok, seps_seen := true, 0
		y := TAB_STRIP_H + MENU_BAR_H + sx(1)
		for it, i in menus[1].items {
			ih := MENU_ITEM_H if it.cmd != .None else MENU_ITEM_H * 0.4
			got := menu_item_at(&t, &a, inx, y + ih * 0.5, W, H)
			if it.cmd == .None {
				seps_seen += 1
				if got != -1 {rows_ok = false}
			} else if got != i {rows_ok = false}
			y += ih
		}
		above := menu_item_at(&t, &a, inx, TAB_STRIP_H, W, H) // in the bar
		below := menu_item_at(&t, &a, inx, 99999, W, H)
		// The x axis is the one that had no check at all: a point at a valid row
		// height but far to the right used to select that row, so clicking into
		// the document to dismiss a menu ran whatever command sat at that height.
		mid_y := TAB_STRIP_H + MENU_BAR_H + sx(1) + MENU_ITEM_H * 0.5
		right := menu_item_at(&t, &a, dx + dw + sx(200), mid_y, W, H)
		left := menu_item_at(&t, &a, max(0, dx - sx(20)), mid_y, W, H)
		edge_ok := above == -1 && below == -1
		x_ok := right == -1 && left == -1
		fmt.printfln("  rows map correctly (%d separators skipped): %v %s", seps_seen, rows_ok, "OK" if rows_ok else "FAIL")
		fmt.printfln("  outside vertically -> -1: %v %s", edge_ok, "OK" if edge_ok else "FAIL")
		fmt.printfln("  outside horizontally -> %d,%d %s", right, left, "OK" if x_ok else "FAIL")
		if !rows_ok {bad += 1}
		if !edge_ok {bad += 1}
		if !x_ok {bad += 1}
		menu_close(&a)

		// Drawn rows must equal hit-testable rows. Checking the hit-test against
		// the model alone missed a real bug: when a dropdown fit exactly, the
		// draw dropped its last row (measuring the bottom from the box origin
		// instead of the items origin) while the hit-test kept it, so Edit > Font
		// was an invisible but clickable strip.
		fmt.println("--- drawn rows == hit-testable rows ---")
		dh_bad := 0
		for mi in 0 ..< len(menus) {
			items := menus[mi].items
			content := f32(0)
			for it in items {content += MENU_ITEM_H if it.cmd != .None else MENU_ITEM_H * 0.4}
			// Heights either side of an exact fit, plus a deliberately tight one.
			for extra in ([]f32{-1, 0, 1, 40}) {
				HH := TAB_STRIP_H + MENU_BAR_H + sx(1) + content + sx(4) + extra
				menu_open_at(&a, mi)
				drawn := menu_visible_rows(&t, &a, 1280, HH)
				dx2, dw2, hh := menu_dropdown_rect(&t, &a, 1280, HH)
				// Last hit-testable index, probing every row's midpoint.
				last_hit := -1
				y := TAB_STRIP_H + MENU_BAR_H + sx(1)
				for i := a.menu.top; i < len(items); i += 1 {
					ih := MENU_ITEM_H if items[i].cmd != .None else MENU_ITEM_H * 0.4
					if menu_item_at(&t, &a, dx2 + dw2 * 0.5, y + ih * 0.5, 1280, HH) >= 0 {last_hit = i}
					y += ih
				}
				// The last hit-testable row must be within the drawn set.
				ok := last_hit < a.menu.top + drawn
				if !ok {
					dh_bad += 1
					fmt.printfln("  %-5s h=%.0f drawn=%d last_hit=%d  FAIL", menus[mi].title, hh, drawn, last_hit)
				}
			}
			menu_close(&a)
		}
		fmt.printfln("  draw/hit agree at every height: %v %s", dh_bad == 0, "OK" if dh_bad == 0 else "FAIL")
		bad += dh_bad

		fmt.println("--- global chords survive menu mode ---")
		for k in ([]plat.Key{.S, .P, .N, .Z}) {
			got := resolve_key(k, true, false, .Menu)
			if got == .None {bad += 1}
			fmt.printfln("  Ctrl+%v / Menu -> %-12v %s", k, got, "OK" if got != .None else "FAIL")
		}
		// ...but unmodified keys belong to the menu.
		un := resolve_key(.Down, false, false, .Menu)
		fmt.printfln("  Down / Menu -> %v %s", un, "OK" if un == .Menu_Item_Next else "FAIL")
		if un != .Menu_Item_Next {bad += 1}

		fmt.printfln("menutest: %d failures", bad)
		return true
	}

	// `newtpad menuseam` is a falsifier, not a regression test. It answers one
	// question about a PROPOSED frame shape before that shape is committed to:
	// if a frame ran LAYOUT, then applied INPUT, then ran LAYOUT again to draw,
	// would the two layout passes resolve the same scroll offset?
	//
	// They only can when the dropdown fits. When it does not, resolving with the
	// highlighted item at k and at k+1 yields two different `top` values, so the
	// rows the hit-test accepted (pass 1) are not the rows the draw emitted
	// (pass 2) — the seam-bug class, reintroduced at frame granularity, in a
	// design whose entire purpose is to make that class impossible.
	//
	// TODAY'S CODE DOES NOT HAVE THIS BUG. menu_scroll_to_item runs exactly once,
	// inside the draw, and menu_item_at reads the app.menu.top the previous draw
	// cached (see menu.odin's comment above menu_scroll_to_item). It is one frame
	// stale on purpose, and therefore self-consistent. This mode measures a
	// property of the resolution function, to decide whether a future layout pass
	// is allowed to run twice per frame.
	if os.args[1] == "menuseam" {
		t: plat.Text
		plat.text_load_faces(&t)
		a: App
		menu_init(&a.menu)
		app_new_scratch(&a)
		defer app_destroy(&a)

		W := f32(1280)
		diverged, checked := 0, 0
		fmt.println("--- scroll resolution stability across a one-row selection move ---")
		fmt.println("  (topA = resolved with item k, topB = resolved with item k+1 after Down)")
		for H in ([]f32{200, 201, 202, 480, 481, 720}) {
			for m, mi in menus {
				items := m.items
				a.menu.open = mi
				a.menu.item = -1
				a.menu.top = 0
				_, _, h := menu_dropdown_rect(&t, &a, W, H)
				n0 := menu_visible_rows(&t, &a, W, H) // rows fitting from top=0
				fits := n0 >= len(items)
				if fits || n0 == 0 {
					fmt.printfln("  h=%4.0f %-6s rows=%d/%d fits — resolution cannot move", H, m.title, n0, len(items))
					continue
				}
				k := n0 - 1 // last row visible while top=0
				if k + 1 > len(items) - 1 {continue}
				checked += 1

				topA := menu_resolve_top(0, k, items, h)
				topB := menu_resolve_top(0, k + 1, items, h)

				// Row sets each offset would produce.
				a.menu.top = topA
				nA := menu_visible_rows(&t, &a, W, H)
				a.menu.top = topB
				nB := menu_visible_rows(&t, &a, W, H)

				if topA != topB {
					diverged += 1
					fmt.printfln(
						"  h=%4.0f %-6s rows=%d/%d  topA=%d hitbox=[%d,%d)  topB=%d drawn=[%d,%d)  DIVERGES",
						H, m.title, n0, len(items), topA, topA, topA + nA, topB, topB, topB + nB,
					)
				} else {
					fmt.printfln("  h=%4.0f %-6s rows=%d/%d  topA=topB=%d  stable", H, m.title, n0, len(items), topA)
				}
			}
		}

		fmt.println("--- control: today's single-resolution frame ---")
		// The current shape resolves once and caches. Re-resolving from the SAME
		// cached top with the SAME item is idempotent, which is why today's draw
		// and next frame's hit-test agree.
		idem := true
		for H in ([]f32{200, 480}) {
			for m, mi in menus {
				a.menu.open = mi
				a.menu.top = 0
				_, _, h := menu_dropdown_rect(&t, &a, W, H)
				for k in 0 ..< len(m.items) {
					once := menu_resolve_top(0, k, m.items, h)
					twice := menu_resolve_top(once, k, m.items, h)
					if once != twice {idem = false}
				}
			}
		}
		fmt.printfln("  resolve is idempotent for a fixed item: %v %s", idem, "OK" if idem else "FAIL")

		fmt.printfln(
			"menuseam: %d/%d scrolling cases diverge across one selection move; idempotent-for-fixed-item=%v",
			diverged, checked, idem,
		)
		fmt.println(
			"  DIVERGES means: a frame that resolves scroll in layout AND again in draw would",
		)
		fmt.println(
			"  accept clicks on one row set and paint another. One layout call per frame is required.",
		)
		return true
	}

	// `newtpad savepathtest <dir>` pins the ownership seam in the save path.
	// doc_save_err replaces doc.path with a fresh buffer and frees the old one, so
	// any caller that captured doc.path before the call is holding freed memory
	// afterwards. That is what Ctrl+S did, and the failure dialog -- the one whose
	// job is to name the file that would not save -- was the reader.
	//
	// Pointer identity is the deterministic check. Reading the freed bytes would
	// usually still return the right characters, so a content comparison would
	// pass with the bug present and prove nothing.
	if os.args[1] == "savepathtest" && len(os.args) > 2 {
		dir := os.args[2]
		path := fmt.tprintf("%s\\savepath.txt", dir)
		if werr := os.write_entire_file(path, transmute([]u8)string("hello\n")); werr != nil {
			fmt.eprintfln("savepathtest: could not seed %q: %v", path, werr)
			return true
		}

		t: plat.Text
		plat.text_load_faces(&t)
		a: App
		menu_init(&a.menu)
		if !app_open_path(&a, path) {
			fmt.eprintfln("savepathtest: could not open %q", path)
			return true
		}
		defer app_destroy(&a)
		doc := app_active(&a)
		bad := 0

		fmt.println("--- the hazard: doc_save_err replaces the buffer a caller may alias ---")
		before := raw_data(doc.path)
		aliased := doc.path // exactly what the old Ctrl+S captured
		doc_insert_text(doc, transmute([]u8)string("x"))
		err := doc_save_err(doc, aliased)
		after := raw_data(doc.path)
		replaced := before != after
		fmt.printfln("  save err=%v", err)
		fmt.printfln(
			"  doc.path buffer replaced by the save: %v %s",
			replaced,
			"OK (so an alias captured before the call is dangling)" if replaced else "FAIL",
		)
		if !replaced || err != .None {bad += 1}

		fmt.println("--- the fix: Ctrl+S must not hand report_save an alias of doc.path ---")
		// Drive the real command. If it still aliased, it would be formatting the
		// buffer the save just freed.
		doc_insert_text(doc, transmute([]u8)string("y"))
		pre := raw_data(doc.path)
		command_dispatch(.Save, {}, &a, nil, &t, 10)
		post := raw_data(doc.path)
		saved_ok := !doc.modified
		fmt.printfln("  Ctrl+S completed, modified=%v %s", doc.modified, "OK" if saved_ok else "FAIL")
		fmt.printfln("  buffer replaced again: %v (expected, the save re-clones)", pre != post)
		if !saved_ok {bad += 1}

		// Content must survive both saves: the original plus the two inserts.
		got, rerr := os.read_entire_file(path, context.temp_allocator)
		content_ok := rerr == nil && len(got) == len("hello\n") + 2
		fmt.printfln(
			"  file on disk = %q (%d bytes, want %d) %s",
			string(got) if rerr == nil else "<unreadable>",
			len(got),
			len("hello\n") + 2,
			"OK" if content_ok else "FAIL",
		)
		if !content_ok {bad += 1}

		fmt.printfln("savepathtest: %d failures", bad)
		return true
	}

	// `newtpad drawcount <file>` measures what a frame actually costs in draw
	// calls, because the claim "an always-on line-number gutter roughly doubles
	// per-frame draw calls" was arithmetic from constants, not a measurement, and
	// it is load-bearing: if true, renderer batching is a hard prerequisite for
	// the gutter rather than a parallel cleanup.
	//
	// Creates its own window and drives render_frame directly — no GUI input, so
	// it runs unattended. The window is visible for the moment it takes.
	if os.args[1] == "drawcount" && len(os.args) > 2 {
		window := plat.window_create("Newtpad drawcount", 1280, 720)
		gfx, ok := plat.gfx_init(window)
		if !ok {fmt.eprintln("drawcount: gfx init failed");return true}
		text, tok := plat.text_init(&gfx)
		if !tok {fmt.eprintln("drawcount: text init failed");return true}
		quad_pipe, qok := plat.quads_init(&gfx)
		if !qok {fmt.eprintln("drawcount: quad init failed");return true}

		app: App
		menu_init(&app.menu)
		app.settings = settings_load()
		if !app_open_path(&app, os.args[2]) {
			fmt.eprintfln("drawcount: could not open %q", os.args[2])
			return true
		}
		defer app_destroy(&app)

		rc := Render_Ctx{&gfx, &text, &quad_pipe, &app, window, 0, 0, 0}
		active_render_ctx = &rc
		BASE_PX = f32(clamp(app.settings.font_size, FONT_SIZE_MIN, FONT_SIZE_MAX))
		metrics_recompute(&rc)
		plat.window_pump_events(window)

		// Warm frame: fills the glyph atlas, so the measured frame is a steady-state
		// frame and not a first-paint one.
		render_frame(&rc, false)
		plat.window_pump_events(window)

		plat.draw_counts_reset()
		render_frame(&rc, false)
		tc, qc := plat.draw_counts()

		doc := app_active(&app)
		rows := doc_visible_rows(doc, f32(window.height), rc.line_h)

		fmt.println("--- steady-state frame, 1280x720, no menu open ---")
		fmt.printfln("  visible text rows      : %d", rows)
		fmt.printfln("  plat.text_draw  calls  : %d", tc)
		fmt.printfln("  plat.quads_draw calls  : %d", qc)
		fmt.printfln("  total draw calls       : %d", tc + qc)
		fmt.println("--- projection: one more text_draw per visible row (the gutter) ---")
		fmt.printfln("  projected text_draw    : %d  (x%.2f)", tc + rows, f32(tc + rows) / max(f32(tc), 1))
		fmt.printfln("  projected total        : %d  (x%.2f)", tc + qc + rows, f32(tc + qc + rows) / max(f32(tc + qc), 1))
		fmt.printfln(
			"  per-row share of today's text_draw: %.0f%%",
			100 * f32(rows) / max(f32(tc), 1),
		)
		fmt.println("  (text_draw also heap-allocates a [dynamic]Text_Instance per call — text.odin:559)")
		return true
	}

	// `newtpad dpitest` guards the identity the whole cell grid rests on: the
	// column grid the program lays out with (col_x, caret, selection, find rects)
	// must advance by exactly the same amount as the pen inside text_draw. If a
	// rounded cell width is ever introduced on one side only, glyphs drift out
	// from under the caret — at every scale, not just fractional ones.
	if os.args[1] == "dpitest" {
		t: plat.Text
		if !plat.text_load_faces(&t) {
			fmt.eprintln("dpitest: no fonts loaded")
			return true
		}
		// Glyph quads must land on whole pixels or the atlas is sampled at
		// fractional offsets and the text blurs — which is the whole point of the
		// DPI work. So cell_w and line_h must be integral. `track` is how far the
		// integral cell sits from the font's natural advance; that is the accepted
		// cost of a crisp grid (AtlasEngine rounds its cell dims the same way), not
		// a defect, so it is reported but not asserted on.
		fmt.println("scale   px  cell_w  natural   track%  line_h  integral")
		bad := 0
		for scale in ([]f32{1.00, 1.05, 1.25, 1.50, 1.75, 2.00, 3.00}) {
			px := f32(int(16 * scale + 0.5))
			cw := plat.text_char_width(&t, px)
			raw := plat.text_char_em(&t, .Doc) * px
			track := (cw - raw) / raw * 100
			lh := line_height(px)
			ok := cw == f32(int(cw)) && lh == f32(int(lh)) && cw >= 1 && lh >= 1
			if !ok {bad += 1}
			fmt.printfln("%5.2f  %3.0f  %6.0f  %7.3f  %6.2f  %6.0f  %s", scale, px, cw, raw, track, lh, "OK" if ok else "FAIL")
		}
		// Every scaled metric must stay >= 1px. A metric reaching 0 divides into
		// +Inf downstream (rows, columns), and Odin's f32->int on Inf is poison —
		// negative row counts indexing the visible-line iterator.
		fmt.println("--- metric floors (thinnest values, incl. out-of-range DPI) ---")
		zero_bad := 0
		for dpi in ([]u32{0, 1, 48, 96, 120, 144, 240, 384, 960, 100000}) {
			w: plat.Window
			w.dpi = plat.clamp_dpi_for_test(dpi)
			rc := Render_Ctx{window = &w, text = &t}
			// TAB_GAP is the thinnest design value in the app at 1px.
			gap := dp(&rc, TAB_GAP)
			caret := dp(&rc, 2)
			pxv := dp(&rc, BASE_PX)
			ok := gap >= 1 && caret >= 1 && pxv >= 1 && w.dpi >= 96 && w.dpi <= 960
			if !ok {zero_bad += 1}
			fmt.printfln("  dpi %6d -> clamped %4d  scale %5.2f  gap %3.0f  caret %3.0f  px %3.0f  %s", dpi, w.dpi, plat.window_scale(&w), gap, caret, pxv, "OK" if ok else "FAIL")
		}
		fmt.printfln("metric floors: %d failures", zero_bad)

		// Scaling a metric twice squares it, which is invisible at 100% (1*1==1)
		// and wrong everywhere else. metrics_recompute must leave each variable at
		// exactly its 96-DPI value times the scale.
		fmt.println("--- single-scaling (a value scaled twice would square) ---")
		sq_bad := 0
		for dpi in ([]u32{96, 120, 144, 192, 288}) {
			w: plat.Window
			w.dpi = dpi
			rc := Render_Ctx{window = &w, text = &t}
			metrics_recompute(&rc)
			s := f32(dpi) / 96
			want_strip := f32(int(TAB_STRIP_H_96 * s + 0.5))
			want_menu := f32(int(TEXT_MARGIN_X_96 * s + 0.5))
			// titlebar_h is what WM_NCHITTEST uses to split client from OS drag.
			tb := f32(w.titlebar_h)
			ok := TAB_STRIP_H == want_strip && TEXT_MARGIN_X == want_menu && tb == want_strip
			if !ok {sq_bad += 1}
			fmt.printfln("  dpi %3d (x%.2f)  strip %5.0f want %5.0f   margin %4.0f want %4.0f   titlebar_h %5.0f  %s", dpi, s, TAB_STRIP_H, want_strip, TEXT_MARGIN_X, want_menu, tb, "OK" if ok else "FAIL")
		}
		fmt.printfln("single-scaling: %d failures", sq_bad)
		// Leave the globals at 96 DPI so later modes in the same process aren't
		// affected by whatever the loop last set.
		{
			w: plat.Window
			w.dpi = 96
			rc := Render_Ctx{window = &w, text = &t}
			metrics_recompute(&rc)
		}

		// The grid must be exactly linear: column n starts at n*cell_w.
		cw := plat.text_char_width(&t, 16)
		lin_ok := true
		for n in ([]int{1, 7, 100, 2047}) {
			if abs(col_x(cw, n) - (TEXT_MARGIN_X + f32(n) * cw)) > 0.0001 {lin_ok = false}
		}
		fmt.printfln("column grid linear: %v  %s", lin_ok, "OK" if lin_ok else "FAIL")
		fmt.printfln("%d/%d scales failed", bad, 7)
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
		samples := "aé中がx́\t" // ascii, 2-byte latin, CJK x2, kana, ascii, combining acute, tab
		fmt.printfln("tab = %d cells (want %d, and must draw no glyph)", plat.text_cell_width(&t, '\t'), plat.TAB_CELLS)
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

	// `newtpad linktest` covers link detection and resolution — the parts that are
	// pure logic and therefore actually testable here. The Ctrl+click gesture and
	// the underline are not covered: this environment cannot inject mouse input.
	//
	// The interesting cases are all about where a link ENDS, and about not
	// turning ordinary prose into links.
	if os.args[1] == "linktest" {
		bad := 0
		Case :: struct {
			text:   string,
			want:   string, // expected target text, "" = expect no link
			line:   int,
			kind:   Link_Kind,
		}
		cases := []Case {
			// URLs, and the trailing-punctuation problem.
			{"see http://example.com/x", "http://example.com/x", 0, .URL},
			{"see http://example.com/x.", "http://example.com/x", 0, .URL},
			{"(see https://example.com/a)", "https://example.com/a", 0, .URL},
			{"wiki https://en.wikipedia.org/wiki/A_(b)", "https://en.wikipedia.org/wiki/A_(b)", 0, .URL},
			{"mail mailto:a@b.com, thanks", "mailto:a@b.com", 0, .URL},
			// A scheme we refuse: must not be detected as a URL at all.
			{"run ms-msdt:/id PCWDiagnostic", "", 0, .URL},
			{"run search-ms:query=x", "", 0, .URL},
			// Absolute Windows paths.
			{`open C:\dir\file.txt now`, `C:\dir\file.txt`, 0, .Path},
			{`open C:/dir/file.txt now`, `C:/dir/file.txt`, 0, .Path},
			// The drive-letter trap: C: must not parse as target "C" line 0.
			{`at C:\dir\file.txt:42`, `C:\dir\file.txt`, 42, .Line_Ref},
			// UNC.
			{`see \\server\share\a.log`, `\\server\share\a.log`, 0, .Path},
			// Compiler / linter output.
			{"src/main.odin:120:5: error here", "src/main.odin", 120, .Line_Ref},
			{"at build\\out.log:9", "build\\out.log", 9, .Line_Ref},
			// Prose must not become links.
			{"this is just a sentence", "", 0, .Path},
			{"ratio was 3:1 overall", "", 0, .Path},
			{"see the readme for details", "", 0, .Path},
			// Quoted paths end at the quote.
			{`"C:\dir\a.txt" and more`, `C:\dir\a.txt`, 0, .Path},
			// Markdown links: only the target inside the parens is the link.
			{"[docs](https://example.com/y)", "https://example.com/y", 0, .URL},
			{"see [the log](build/out.log:12) here", "build/out.log", 12, .Line_Ref},
			{"a [plain](word) is not a link", "", 0, .Path},
			// smb:// shares are detected as paths (link_resolve rewrites to UNC).
			{"open smb://server/share/a.txt please", "smb://server/share/a.txt", 0, .Path},
			{"log smb://server/share/a.txt:7 there", "smb://server/share/a.txt", 7, .Line_Ref},
		}

		fmt.println("--- detection ---")
		for c in cases {
			links := links_scan(c.text)
			got := ""
			gl := 0
			gk := Link_Kind.Path
			if len(links) > 0 {
				got = c.text[links[0].start:links[0].start + links[0].target_len]
				gl = links[0].line
				gk = links[0].kind
			}
			ok := got == c.want && gl == c.line
			if c.want != "" {ok = ok && gk == c.kind}
			if !ok {bad += 1}
			fmt.printfln(
				"  %-40q -> %-36q line=%-4d %s",
				c.text,
				got,
				gl,
				"OK" if ok else fmt.tprintf("FAIL (want %q line %d)", c.want, c.line),
			)
		}

		fmt.println("--- resolution is anchored to the document's folder ---")
		dir := os.get_env("TEMP", context.temp_allocator)
		anchor := fmt.tprintf("%s\\newtpad_link_anchor.txt", dir)
		target := fmt.tprintf("%s\\newtpad_link_target.txt", dir)
		plat.file_write_atomic(anchor, transmute([]u8)string("anchor"))
		plat.file_write_atomic(target, transmute([]u8)string("target"))
		doc, dok := doc_open(anchor)
		if dok {
			defer doc_close(&doc)
			line := "see newtpad_link_target.txt:3 for details"
			links := links_scan(line)
			if len(links) == 0 {
				fmt.println("  FAIL: relative link not detected")
				bad += 1
			} else {
				t, rok := link_resolve(&doc, line, links[0])
				want_ok := rok && t.path == target && t.line == 3
				fmt.printfln("  relative resolves next to the document: %v %s", t.path, "OK" if want_ok else "FAIL")
				if !want_ok {bad += 1}
			}

			// A file that does not exist must not resolve at all.
			missing := "see newtpad_no_such_file.txt for details"
			ml := links_scan(missing)
			if len(ml) > 0 {
				_, rok := link_resolve(&doc, missing, ml[0])
				fmt.printfln("  missing file refuses to resolve: %v %s", !rok, "OK" if !rok else "FAIL")
				if rok {bad += 1}
			}

			// A parent walk is refused rather than resolved.
			up := "see ..\\outside.txt now"
			ul := links_scan(up)
			if len(ul) > 0 {
				_, rok := link_resolve(&doc, up, ul[0])
				fmt.printfln("  parent walk refused: %v %s", !rok, "OK" if !rok else "FAIL")
				if rok {bad += 1}
			}

			// A relative directory resolves against the document folder and is
			// flagged as a directory, so link_activate reveals it in Explorer
			// rather than trying to open it as a tab.
			os.make_directory(fmt.tprintf("%s\\newtpad_link_subdir", dir))
			dirline := "open .\\newtpad_link_subdir here"
			dl := links_scan(dirline)
			if len(dl) > 0 {
				td, dok2 := link_resolve(&doc, dirline, dl[0])
				_, isdir := plat.path_exists(td.path)
				okd := dok2 && isdir
				fmt.printfln("  relative directory resolves + reveals: %v %s", td.path, "OK" if okd else "FAIL")
				if !okd {bad += 1}
			} else {
				fmt.println("  FAIL: relative directory not detected")
				bad += 1
			}
		}

		fmt.println("--- scheme whitelist ---")
		for u in ([]string{"http://x.com", "https://x.com", "mailto:a@b.com"}) {
			ok := plat.url_is_openable(u)
			fmt.printfln("  %-24q openable=%v %s", u, ok, "OK" if ok else "FAIL")
			if !ok {bad += 1}
		}
		for u in ([]string{"ms-msdt:/id X", "search-ms:query=x", "javascript:alert(1)", "file://server/x", "ms-officecmd:%7B%22id%22"}) {
			ok := plat.url_is_openable(u)
			fmt.printfln("  %-24q openable=%v %s", u, ok, "OK" if !ok else "FAIL")
			if ok {bad += 1}
		}

		fmt.println("--- drawn span == clickable span ---")
		// The underline is drawn from Link_Hit.col/cells and links_hit tests the
		// same fields, so they cannot disagree by construction. This asserts the
		// construction actually holds: a point inside the reported cells hits, and
		// one just outside does not. Boundary cells on both edges, because that is
		// where every seam bug in this codebase has lived.
		{
			tt: plat.Text
			plat.text_load_faces(&tt)
			seamf := fmt.tprintf("%s\\newtpad_link_seam.txt", dir)
			plat.file_write_atomic(seamf, transmute([]u8)string("go to https://example.com/x now\n"))
			sd, sok := doc_open(seamf)
			if sok {
				defer doc_close(&sd)
				sd.view_cols = 200
				sd.view_rows = 10
				hits := links_layout(&sd, &tt, 10)
				if len(hits) != 1 {
					fmt.printfln("  FAIL: expected 1 hit, got %d", len(hits))
					bad += 1
				} else {
					h := hits[0]
					cw := plat.text_char_width(&tt, BASE_PX, .Doc)
					px := BASE_PX
					yy := row_baseline_y(px, h.row) - line_height(px) * 0.5
					inside_l := col_x(cw, h.col) + cw * 0.5
					inside_r := col_x(cw, h.col + h.cells - 1) + cw * 0.5
					outside_l := col_x(cw, h.col - 1) + cw * 0.5
					outside_r := col_x(cw, h.col + h.cells) + cw * 0.5
					_, i1 := links_hit(hits, px, cw, inside_l, yy)
					_, i2 := links_hit(hits, px, cw, inside_r, yy)
					_, o1 := links_hit(hits, px, cw, outside_l, yy)
					_, o2 := links_hit(hits, px, cw, outside_r, yy)
					ok := i1 && i2 && !o1 && !o2
					fmt.printfln("  cells [%d,%d)  first=%v last=%v before=%v after=%v %s", h.col, h.col + h.cells, i1, i2, o1, o2, "OK" if ok else "FAIL")
					if !ok {bad += 1}
					got := h.text[h.link.start:h.link.start + h.link.target_len]
					tok := got == "https://example.com/x"
					fmt.printfln("  target %q %s", got, "OK" if tok else "FAIL")
					if !tok {bad += 1}
				}
			}
		}

		fmt.printfln("linktest: %d failures", bad)
		return true
	}

	// `newtpad devicelosttest` covers what happens after the GPU goes away.
	//
	// Present's HRESULT was discarded, so a removed device (driver update, TDR,
	// eGPU unplug, an RDP session change) left a window that never updated again
	// while the loop kept issuing calls into dead COM objects -- a frozen editor
	// still holding every unsaved buffer.
	//
	// What this does NOT cover: a real device removal. It cannot be provoked here,
	// so the HRESULT branch itself is unexercised and the flag is set through a
	// test seam. What it does cover is the property that matters once the flag is
	// set -- every frame entry point goes inert instead of calling into dead
	// objects -- and that gfx_create_rtv survives a failed GetBuffer, which used
	// to Release through a nil pointer.
	if os.args[1] == "devicelosttest" {
		window := plat.window_create("Newtpad devicelost", 640, 480)
		gfx, ok := plat.gfx_init(window)
		if !ok {fmt.eprintln("devicelosttest: gfx init failed");return true}
		text, tok := plat.text_init(&gfx)
		if !tok {fmt.eprintln("devicelosttest: text init failed");return true}
		qp, qok := plat.quads_init(&gfx)
		if !qok {fmt.eprintln("devicelosttest: quad init failed");return true}
		bad := 0

		// A healthy frame presents cleanly.
		plat.text_frame_begin(&gfx, &text)
		plat.gfx_begin_frame(&gfx, 0, 0, 0)
		plat.text_draw(&gfx, &text, "hello", 0, 20, 16, {1, 1, 1, 1})
		st := plat.gfx_end_frame(&gfx, 0)
		fmt.println("--- healthy device ---")
		fmt.printfln("  present -> %v %s", st, "OK" if st == .Ok else "FAIL")
		fmt.printfln("  lost    -> %v %s", plat.gfx_is_lost(&gfx), "OK" if !plat.gfx_is_lost(&gfx) else "FAIL")
		if st != .Ok || plat.gfx_is_lost(&gfx) {bad += 1}

		plat.gfx_force_lost(&gfx)

		// Every one of these used to run straight into dead COM objects. They must
		// now be no-ops, and reaching the end of this block at all is the assertion.
		fmt.println("--- after the device is lost ---")
		plat.text_frame_begin(&gfx, &text)
		plat.gfx_begin_frame(&gfx, 0.1, 0.1, 0.1)
		plat.text_draw(&gfx, &text, "should not draw", 0, 20, 16, {1, 1, 1, 1})
		plat.quads_draw(&gfx, &qp, []plat.Quad{{pos = {0, 0}, size = {10, 10}, color = {1, 1, 1, 1}}})
		st2 := plat.gfx_end_frame(&gfx, 0)
		plat.gfx_resize(&gfx, 800, 600) // the path that used to Release a nil backbuffer
		fmt.printfln("  a full frame + resize did not crash: OK")
		fmt.printfln("  present -> %v %s", st2, "OK" if st2 == .Lost else "FAIL")
		fmt.printfln("  lost    -> %v %s", plat.gfx_is_lost(&gfx), "OK" if plat.gfx_is_lost(&gfx) else "FAIL")
		if st2 != .Lost || !plat.gfx_is_lost(&gfx) {bad += 1}
		fmt.printfln("  reason  -> %q", plat.gfx_lost_reason(&gfx))

		fmt.printfln("devicelosttest: %d failures", bad)
		return true
	}

	// `newtpad atlasgrowtest` proves the atlas actually grows. atlastest checks
	// only text_atlas_fit_count -- arithmetic that assumes growth works -- and it
	// passed for the entire time growth was impossible, because it never asked the
	// atlas to do anything. atlas_relieve's one caller sat inside text_draw, where
	// its own `drawing` guard always refused, so the atlas stayed at ATLAS_START
	// forever and glyphs past ~1196 silently vanished while the pen advanced.
	//
	// Needs a real device, so it makes a window like drawcount does.
	if os.args[1] == "atlasgrowtest" {
		window := plat.window_create("Newtpad atlasgrow", 800, 600)
		gfx, ok := plat.gfx_init(window)
		if !ok {fmt.eprintln("atlasgrowtest: gfx init failed");return true}
		text, tok := plat.text_init(&gfx)
		if !tok {fmt.eprintln("atlasgrowtest: text init failed");return true}

		start_dim := plat.text_atlas_dim(&text)
		fmt.printfln("--- atlas growth under a heavy glyph load ---")
		fmt.printfln("  start dim         : %d (ATLAS_START)", start_dim)

		// Draw a lot of distinct CJK codepoints at a large size: glyph area grows
		// with px^2, so this overflows 1024 quickly. One text_draw per frame, with
		// a frame boundary between, which is where relief is now allowed to happen.
		FRAMES :: 40
		PER :: 64
		cp := rune(0x4E00)
		for f in 0 ..< FRAMES {
			plat.text_frame_begin(&gfx, &text)
			plat.gfx_begin_frame(&gfx, 0, 0, 0)
			buf: [PER * 4]u8
			n := 0
			for _ in 0 ..< PER {
				b, sz := utf8.encode_rune(cp)
				bb := b
				copy(buf[n:], bb[:sz])
				n += sz
				cp += 1
			}
			plat.text_draw(&gfx, &text, string(buf[:n]), 0, 40, 48, {1, 1, 1, 1})
			plat.gfx_end_frame(&gfx, 0)
		}
		// One more boundary so any relief owed by the final frame is applied.
		plat.text_frame_begin(&gfx, &text)

		end_dim := plat.text_atlas_dim(&text)
		grew := end_dim > start_dim
		fmt.printfln("  after %d frames    : %d", FRAMES, end_dim)
		fmt.printfln("  atlas grew        : %v %s", grew, "OK" if grew else "FAIL")
		fmt.printfln("  atlas_full latched: %v %s", plat.text_atlas_full(&text), "OK" if !plat.text_atlas_full(&text) else "FAIL")
		bad := 0
		if !grew {bad += 1}
		if plat.text_atlas_full(&text) {bad += 1}
		fmt.printfln("atlasgrowtest: %d failures", bad)
		return true
	}

	// `newtpad resavetest <file>` opens a file, edits it and saves, so an external
	// checker can assert what the save preserved. The atomic write used to rename
	// a brand-new temp file over the target, which substitutes a fresh file and
	// silently drops the original's attributes, ACLs and alternate data streams --
	// the properties are easiest to observe from outside, hence this mode.
	if os.args[1] == "resavetest" && len(os.args) > 2 {
		path := os.args[2]
		doc, ok := doc_open(path)
		if !ok {
			fmt.eprintfln("resavetest: could not open %q", path)
			return true
		}
		defer doc_close(&doc)
		doc.cursor = doc.pt.length
		doc.anchor = doc.cursor
		doc_insert_text(&doc, transmute([]u8)string("appended\n"))
		err := doc_save_err(&doc, path)
		fmt.printfln("resavetest: save err=%v size=%d", err, doc.pt.length)
		return true
	}

	// `newtpad colperftest <mb>` measures the status bar's caret column on a
	// single-line file -- minified JSON, an unrotated log, a CSV with no newlines.
	// doc_cursor_col called pt_line_start, an uncapped backward scan, and the
	// status bar calls it unconditionally every frame: 27.9 ms per frame on
	// 100 MB, one core pinned at ~35 fps for as long as the file stays open.
	if os.args[1] == "colperftest" && len(os.args) > 2 {
		mbn, _ := strconv.parse_int(os.args[2])
		mb := max(mbn, 1)
		n := mb * 1024 * 1024
		content := make([]u8, n)
		for i in 0 ..< n {content[i] = 'a'} // no newline anywhere: worst case
		doc := doc_from_content(content, "", .UTF8)
		defer doc_close(&doc)
		doc.cursor = n // caret at the far end, so the scan is the whole buffer
		t: plat.Text
		plat.text_load_faces(&t)

		s1 := time.tick_now()
		c1 := doc_cursor_col(&doc, &t)
		d1 := time.duration_milliseconds(time.tick_since(s1))

		s2 := time.tick_now()
		REP :: 200
		for _ in 0 ..< REP {doc_cursor_col(&doc, &t)}
		d2 := time.duration_milliseconds(time.tick_since(s2)) / f64(REP)

		// A short line must still report a real column -- the cap must not blind the
		// common case.
		short := doc_from_content(transmute([]u8)strings.clone("hello world"), "", .UTF8)
		defer doc_close(&short)
		short.cursor = 5
		sc := doc_cursor_col(&short, &t)

		// The old path, timed here rather than quoted, so the comparison is this
		// machine and this buffer: an uncapped backward scan for the line start.
		s0 := time.tick_now()
		base.pt_line_start(&doc.pt, doc.cursor)
		d0 := time.duration_milliseconds(time.tick_since(s0))

		fmt.printfln("--- caret column on a %d MB single-line buffer ---", mb)
		fmt.printfln("  uncapped scan   : %.2f ms  <- what ran every frame", d0)
		fmt.printfln("  first call      : %.2f ms (col=%d, 0 = beyond cap, reported as unknown)", d1, c1)
		fmt.printfln("  cached repeat   : %.4f ms", d2)
		fmt.printfln("  cap             : %d MB", STATUS_COL_CAP / (1024 * 1024))
		bad := 0
		if d1 > 16 {
			fmt.printfln("  FAIL: first call exceeds one frame (%.2f ms)", d1)
			bad += 1
		}
		if sc != 6 {
			fmt.printfln("  FAIL: short line reports col %d, want 6", sc)
			bad += 1
		} else {
			fmt.println("  short line still reports an exact column: OK")
		}
		fmt.printfln("colperftest: %d failures", bad)
		return true
	}

	// `newtpad scrollperftest <mb>` guards the huge-file lockup: the viewport
	// helpers (doc_scroll / doc_max_top / doc_ensure_cursor_visible) called the
	// UNCAPPED base.pt_line_start/end on the UI thread, O(line length), so a
	// multi-GB single-line file froze on every wheel tick. They now step by capped
	// rows like the renderer. This times them on a single-line buffer (worst case)
	// and asserts each stays inside one frame, then checks that scrolling a normal
	// multi-line buffer still lands on the right line starts.
	if os.args[1] == "scrollperftest" && len(os.args) > 2 {
		mbn, _ := strconv.parse_int(os.args[2])
		n := max(mbn, 1) * 1024 * 1024
		content := make([]u8, n)
		for i in 0 ..< n {content[i] = 'a'} // one line, no newline: worst case
		doc := doc_from_content(content, "", .UTF8)
		defer doc_close(&doc)
		doc.wrap = false
		doc.view_cols = 200
		doc.view_rows = 50
		t: plat.Text
		plat.text_load_faces(&t)
		rows := 50
		bad := 0

		// The old uncapped scan, timed on this machine for the comparison.
		s0 := time.tick_now()
		base.pt_line_start(&doc.pt, doc.pt.length)
		d0 := time.duration_milliseconds(time.tick_since(s0))

		doc.top = n / 2
		s1 := time.tick_now()
		doc_max_top(&doc, &t, rows)
		d1 := time.duration_milliseconds(time.tick_since(s1))

		doc.top = n / 2
		s2 := time.tick_now()
		for _ in 0 ..< 20 {doc_scroll(&doc, &t, 1, rows)}
		d2 := time.duration_milliseconds(time.tick_since(s2)) / 20

		s3 := time.tick_now()
		for _ in 0 ..< 20 {doc_scroll(&doc, &t, -1, rows)}
		d3 := time.duration_milliseconds(time.tick_since(s3)) / 20

		doc.cursor = n
		doc.top = 0
		s4 := time.tick_now()
		doc_ensure_cursor_visible(&doc, &t, rows)
		d4 := time.duration_milliseconds(time.tick_since(s4))

		fmt.printfln("--- viewport ops on a %d MB single-line buffer ---", max(mbn, 1))
		fmt.printfln("  uncapped pt_line_start : %.2f ms  <- what ran per interaction", d0)
		fmt.printfln("  doc_max_top            : %.2f ms", d1)
		fmt.printfln("  doc_scroll +1 (avg)    : %.3f ms", d2)
		fmt.printfln("  doc_scroll -1 (avg)    : %.3f ms", d3)
		fmt.printfln("  ensure_cursor_visible  : %.2f ms", d4)
		for pair in ([]struct{name: string, ms: f64}{{"doc_max_top", d1}, {"doc_scroll+", d2}, {"doc_scroll-", d3}, {"ensure_visible", d4}}) {
			if pair.ms > 16 {
				fmt.printfln("  FAIL: %s exceeds one frame (%.2f ms)", pair.name, pair.ms)
				bad += 1
			}
		}

		// A normal multi-line buffer must still scroll by real line starts.
		ml := strings.clone("l0\nl1\nl2\nl3\nl4\nl5\n")
		md := doc_from_content(transmute([]u8)ml, "", .UTF8)
		defer doc_close(&md)
		md.wrap = false
		md.view_cols = 80
		md.view_rows = 3
		md.top = 0
		doc_scroll(&md, &t, 2, 3) // l0=0 l1=3 l2=6 ... -> top should be 6
		if md.top != 6 {
			fmt.printfln("  FAIL: scroll +2 landed at %d, want 6 (line start of l2)", md.top)
			bad += 1
		}
		doc_scroll(&md, &t, -1, 3) // back to l1 at 3
		if md.top != 3 {
			fmt.printfln("  FAIL: scroll -1 landed at %d, want 3 (line start of l1)", md.top)
			bad += 1
		}
		if bad == 0 {fmt.println("  bounded, and short-line scrolling still lands on line starts: OK")}
		fmt.printfln("scrollperftest: %d failures", bad)
		return true
	}

	// `newtpad hscrolltest` guards the horizontal-scroll seam: with the viewport
	// panned right by H_SCROLL cells, the drawn column (col_x) and the hit-tested
	// column (cell_at_x / doc_pos_at) must agree — the §6j "right function, wrong
	// space" class, here the space being the horizontal offset. Checks the left
	// edge, middle and right edge of the viewport at several pan offsets.
	if os.args[1] == "hscrolltest" {
		bad := 0
		t: plat.Text
		plat.text_load_faces(&t)
		px := BASE_PX
		cw := plat.text_char_width(&t, px, .Doc)
		line := strings.repeat("x", 400) // ASCII: cell index == byte index
		content := strings.concatenate({line, "\n"})
		doc := doc_from_content(transmute([]u8)content, "", .UTF8)
		defer doc_close(&doc)
		doc.wrap = false
		doc.view_cols = 80
		doc.view_rows = 5
		rows := 5
		y := row_baseline_y(px, 0) - line_height(px) * 0.5

		for hs in ([]int{0, 50, 100, 250}) {
			doc.h_scroll = clamp(hs, 0, doc_max_hscroll(&doc, &t, rows))
			doc_update_hscroll(&doc)
			for cell in ([]int{doc.h_scroll, doc.h_scroll + doc.view_cols / 2, doc.h_scroll + doc.view_cols - 1}) {
				base_x := col_x(cw, cell)
				// cell_at_x truncates: any point inside the cell maps to it.
				gc := cell_at_x(cw, base_x + cw*0.5)
				// doc_pos_at rounds to the nearest caret boundary; bias left so it
				// lands on this cell, then (ASCII) the byte offset equals the cell.
				gb := doc_pos_at(&doc, &t, i32(base_x + cw*0.2), i32(y), px, cw, rows)
				if gc != cell || gb != cell {
					fmt.printfln("  FAIL hs=%d cell=%d -> cell_at_x=%d pos=%d", doc.h_scroll, cell, gc, gb)
					bad += 1
				}
			}
		}
		// Wrapping disables horizontal scroll (H_SCROLL forced to 0).
		doc.wrap = true
		doc.h_scroll = 100
		doc_update_hscroll(&doc)
		if H_SCROLL != 0 {
			fmt.println("  FAIL: wrap did not disable horizontal scroll")
			bad += 1
		}
		doc.wrap = false
		doc.h_scroll = 0
		doc_update_hscroll(&doc) // leave the global reset

		// The draggable bar's seam: dropping the thumb where it was drawn must
		// recover the same offset (thumb-centre round-trip through pos_at).
		maxhs := doc_max_hscroll(&doc, &t, rows)
		for hs in ([]int{0, 40, 120, maxhs}) {
			doc.h_scroll = clamp(hs, 0, maxhs)
			hb := hscrollbar_geo(&doc, 1000, 700, maxhs)
			if !hb.shown {
				fmt.println("  FAIL: scrollbar not shown though content overflows")
				bad += 1
				continue
			}
			got := hscrollbar_pos_at(hb, hb.thumb_x + hb.thumb_w*0.5, maxhs)
			if got != doc.h_scroll {
				fmt.printfln("  FAIL: thumb round-trip hs=%d -> %d", doc.h_scroll, got)
				bad += 1
			}
		}
		doc.h_scroll = 0

		if bad == 0 {fmt.println("  drawn column == hit-tested column, and the scrollbar thumb round-trips: OK")}
		fmt.printfln("hscrolltest: %d failures", bad)
		return true
	}

	// `newtpad replacetest` covers the two ways Replace All lost data.
	//
	// It pushed one undo entry per match. UNDO_MAX is 200 and evicts the oldest,
	// so replacing more than 200 occurrences discarded the pre-replace snapshot --
	// the document before the replace became unreachable by any number of Ctrl+Z.
	// The count here is deliberately above UNDO_MAX so the old behaviour cannot
	// pass. And an empty replacement went through doc_insert_text, which returns
	// early on empty input before deleting the selection, so "remove every X" was
	// a silent no-op.
	if os.args[1] == "replacetest" {
		bad := 0
		N :: 300 // > UNDO_MAX (200): the whole point
		tmpf := fmt.tprintf("%s%cnewtpad_repl.txt", os.get_env("TEMP", context.temp_allocator), '\\')

		sb := strings.builder_make(context.temp_allocator)
		for i in 0 ..< N {fmt.sbprintf(&sb, "alpha line %d\n", i)}
		original := strings.to_string(sb)
		plat.file_write_atomic(tmpf, transmute([]u8)original)

		fmt.printfln("--- Replace All over %d matches (UNDO_MAX=%d) ---", N, UNDO_MAX)
		doc, _ := doc_open(tmpf)
		find_open(&doc, true)
		for r in "alpha" {find_input_rune(&doc, r)}
		doc.find.field = 1
		for r in "beta" {find_input_rune(&doc, r)}
		doc.find.field = 0
		find_wait(&doc)
		matches := len(doc.find.matches)
		undo_before := len(doc.undo)
		find_replace_all(&doc)
		entries := len(doc.undo) - undo_before
		fmt.printfln("  matches=%d, undo entries added=%d %s", matches, entries, "OK" if entries == 1 else "FAIL")
		if entries != 1 {bad += 1}

		// One Ctrl+Z must restore the document exactly.
		doc_undo(&doc)
		back := doc_debug_string(&doc)
		restored := back == original
		fmt.printfln("  one undo restores the original: %v %s", restored, "OK" if restored else "FAIL")
		if !restored {bad += 1}
		doc_close(&doc)

		fmt.println("--- empty replacement deletes every occurrence ---")
		d2, _ := doc_open(tmpf)
		find_open(&d2, true)
		for r in "alpha " {find_input_rune(&d2, r)}
		d2.find.field = 1 // replacement left empty
		d2.find.field = 0
		find_wait(&d2)
		before := len(doc_debug_string(&d2))
		find_replace_all(&d2)
		after_s := doc_debug_string(&d2)
		shrank := len(after_s) < before
		gone := !strings.contains(after_s, "alpha")
		fmt.printfln("  %d -> %d bytes, 'alpha' gone=%v %s", before, len(after_s), gone, "OK" if shrank && gone else "FAIL")
		if !(shrank && gone) {bad += 1}
		doc_close(&d2)

		fmt.printfln("replacetest: %d failures", bad)
		return true
	}

	// `newtpad diskstamptest` pins the restore/watch seam in both directions. A
	// dirty tab restored from a backup used to carry a zero stamp, so the watcher
	// compared zero against the real file, called it changed, and told the user to
	// reload away the work hot exit had just restored -- within a second of every
	// launch. Suppressing the report would have been the wrong fix: it would also
	// suppress a file that really did change while we were closed. So the session
	// carries the stamp, and both directions are asserted here.
	if os.args[1] == "diskstamptest" {
		tmpf := fmt.tprintf("%s%cnewtpad_stamptest.txt", os.get_env("TEMP", context.temp_allocator), '\\')
		plat.file_write_atomic(tmpf, transmute([]u8)string("original content\n"))
		bad := 0

		a: App
		if fd, ok := doc_open(tmpf); ok {
			d := new(Document);d^ = fd
			app_add(&a, d)
			doc_insert_text(d, transmute([]u8)string("edited ")) // dirty: forces a backup
		}
		session_save(&a)
		app_destroy(&a)

		b: App
		session_restore(&b)
		d := app_active(&b)
		fmt.println("--- restored dirty tab ---")
		fmt.printfln("  modified=%v path=%q", d.modified, d.path)
		has := d.disk_stamp.ok
		fmt.printfln("  carries a disk stamp: %v %s", has, "OK" if has else "FAIL")
		if !has {bad += 1}

		// This is exactly the comparison watch_worker makes.
		now := plat.file_stamp(tmpf)
		quiet := now == d.disk_stamp
		fmt.printfln("  unchanged file reports a change: %v %s", !quiet, "OK" if quiet else "FAIL")
		if !quiet {bad += 1}

		// Now let the file really change underneath us.
		time.sleep(16 * time.Millisecond) // mtime granularity
		plat.file_write_atomic(tmpf, transmute([]u8)string("changed by someone else\n"))
		now2 := plat.file_stamp(tmpf)
		detects := now2 != d.disk_stamp
		fmt.printfln("  genuine external change still detected: %v %s", detects, "OK" if detects else "FAIL")
		if !detects {bad += 1}
		app_destroy(&b)

		// doc_from_content sets neither had_bom nor eol, so a dirty tab restored
		// from a backup forgot both and the next save wrote a BOM-less LF file over
		// what had been a UTF-8-BOM CRLF one -- which is what breaks Excel and
		// PowerShell, and what turns one edit into a whole-file diff.
		fmt.println("--- restore preserves BOM and line endings ---")
		bomf := fmt.tprintf("%s%cnewtpad_bom.txt", os.get_env("TEMP", context.temp_allocator), '\\')
		bom_bytes := []u8{0xEF, 0xBB, 0xBF, 'a', '\r', '\n', 'b', '\r', '\n'}
		plat.file_write_atomic(bomf, bom_bytes)
		e: App
		if fd, ok := doc_open(bomf); ok {
			bd := new(Document);bd^ = fd
			app_add(&e, bd)
			fmt.printfln("  opened  : had_bom=%v eol=%v", bd.had_bom, bd.eol)
			doc_insert_text(bd, transmute([]u8)string("x")) // dirty -> backup path
		}
		session_save(&e)
		app_destroy(&e)

		g: App
		session_restore(&g)
		gd := app_active(&g)
		bom_ok := gd.had_bom && gd.eol == .CRLF
		fmt.printfln("  restored: had_bom=%v eol=%v %s", gd.had_bom, gd.eol, "OK" if bom_ok else "FAIL")
		if !bom_ok {bad += 1}
		app_destroy(&g)

		// doc_reload goes through doc_close, which nils idx.th, and only
		// app_activate starts an index lazily -- which never fires again for a tab
		// that is already active. So the tab you are watching a log on lost its line
		// count permanently the first time it reloaded.
		fmt.println("--- reload restarts the line index ---")
		c: App
		if fd, ok := doc_open(tmpf); ok {
			rd := new(Document);rd^ = fd
			app_add(&c, rd)
			app_activate(&c, 0)
			started_before := rd.idx.th != nil
			reloaded := doc_reload(rd)
			started_after := rd.idx.th != nil
			fmt.printfln("  index running before reload: %v", started_before)
			fmt.printfln("  reload ok=%v, index running after: %v %s", reloaded, started_after, "OK" if reloaded && started_after else "FAIL")
			if !reloaded || !started_after {bad += 1}
		}
		app_destroy(&c)

		empty: App
		app_new_scratch(&empty)
		session_save(&empty)
		app_destroy(&empty)
		fmt.printfln("diskstamptest: %d failures", bad)
		return true
	}

	// `newtpad sessiontest` round-trips session save -> restore. Set
	// NEWTPAD_SESSION_DIR to a temp dir first — without it this writes to, and
	// then resets, the real session under %APPDATA%\Newtpad.
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

	// `newtpad sessionlosstest <file>` — launching on a file used to skip session
	// restore, and the exit save then deleted every backup the resulting one-tab
	// session didn't reference, destroying unsaved scratch buffers. Set
	// NEWTPAD_SESSION_DIR to a temp dir before running.
	if os.args[1] == "sessionlosstest" && len(os.args) > 2 {
		file := os.args[2]
		SCRATCH :: "precious unsaved work"

		// A prior session with one dirty, untitled scratch tab.
		a: App
		content := make([]u8, len(SCRATCH));copy(content, SCRATCH)
		d := new(Document);d^ = doc_from_content(content, "", .UTF8)
		app_add(&a, d)
		session_save(&a)
		app_destroy(&a)
		fmt.printfln("saved prior session: 1 dirty scratch tab")

		// Now "launch with a file argument", the way main does. Pass "old" to
		// reproduce the pre-fix path (skip restore entirely) and confirm this
		// test actually detects the data loss.
		old_behavior := len(os.args) > 3 && os.args[3] == "old"
		b: App
		had := session_exists()
		restored := !old_behavior && session_restore(&b)
		can_sweep := old_behavior || !had || restored
		if !app_open_path(&b, file) {fmt.println("  (could not open file arg)")}
		if app_live_count(&b) == 0 {app_new_scratch(&b)}
		fmt.printfln("launch w/ file: had_session=%v restored=%v tabs=%d sweep=%v", had, restored, app_live_count(&b), can_sweep)
		session_save(&b, can_sweep)
		app_destroy(&b)

		// Relaunch bare: the scratch buffer must still be there.
		c: App
		session_restore(&c)
		found := false
		for dd in c.docs {
			if dd == nil {continue}
			if dd.path == "" && doc_debug_string(dd) == SCRATCH {found = true}
		}
		fmt.printfln("after relaunch: tabs=%d scratch survived=%v  %s", app_live_count(&c), found, "OK" if found else "FAIL - unsaved work destroyed")
		app_destroy(&c)
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

		// Results must be clickable, and the hit-test must agree with the drawn
		// box on BOTH axes — the menu's equivalent had no x check at all, which
		// made every point at a row height a live menu row.
		clear(&a.palette.query)
		palette_recompute(&a)
		a.palette.active = true
		W, H := f32(1280), f32(720)
		l := palette_layout(&a, W, H)
		inx := l.x0 + l.w * 0.5
		rowtop := l.y0 + l.qh
		r0 := palette_row_at(&a, inx, rowtop + l.rowh * 0.5, W, H)
		rq := palette_row_at(&a, inx, l.y0 + l.qh * 0.5, W, H) // the query field
		rl := palette_row_at(&a, l.x0 - sx(20), rowtop + l.rowh * 0.5, W, H) // left of box
		rr := palette_row_at(&a, l.x0 + l.w + sx(20), rowtop + l.rowh * 0.5, W, H) // right
		rb := palette_row_at(&a, inx, rowtop + l.rowh * f32(l.nres + 3), W, H) // below
		ok := r0 == 0 && rq == -1 && rl == -1 && rr == -1 && rb == -1
		fmt.printfln("palette rows: first=%d query=%d L=%d R=%d below=%d  %s", r0, rq, rl, rr, rb, "OK" if ok else "FAIL")

		// Clicking away closes; clicking a row selects without closing.
		_, c1 := palette_click(&a, sx(4), H - sx(4), W, H)
		away_ok := c1 && !a.palette.active
		// Reopen properly: palette_close clears the results, so simply setting
		// `active` would leave no rows to hit.
		palette_open(&a)
		l = palette_layout(&a, W, H)
		rowtop = l.y0 + l.qh
		chose, c2 := palette_click(&a, l.x0 + l.w * 0.5, rowtop + l.rowh * 0.5, W, H)
		row_ok := chose && c2
		fmt.printfln("click away closes=%v, click row chooses=%v  %s", away_ok, row_ok, "OK" if away_ok && row_ok else "FAIL")
		a.palette.active = false

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
		// Reported as dead in the GUI (2026-07-19); pin what the keymap resolves.
		key_chk(resolve_key(.A, true, false, .Editor), .Select_All, "Ctrl+A / Editor")
		key_chk(resolve_key(.P, true, false, .Editor), .Palette_Open, "Ctrl+P / Editor")
		key_chk(resolve_key(.L, true, false, .Editor), .Filter_Open, "Ctrl+L / Editor")
		// Reported missing by the 2026-07-19 audit as first-hour daily-driver gaps.
		key_chk(resolve_key(.Tab, false, false, .Editor), .Insert_Tab, "Tab / Editor")
		key_chk(resolve_key(.Home, true, false, .Editor), .Doc_Start, "Ctrl+Home / Editor")
		key_chk(resolve_key(.End, true, false, .Editor), .Doc_End, "Ctrl+End / Editor")
		key_chk(resolve_key(.G, true, false, .Editor), .Goto_Line, "Ctrl+G / Editor")
		key_chk(resolve_key(.Tab, true, false, .Editor), .Tab_Next, "Ctrl+Tab still switches")
		key_chk(resolve_key(.Home, false, false, .Editor), .Cursor_Home, "Home still line-start")
		key_chk(resolve_key(.L, true, false, .Find), .Find_Toggle_Filter, "Ctrl+L / Find")
		// The real defect: Find context has no fallback to the Editor bindings, so
		// every editor chord is dead while the find bar is open.
		key_chk(resolve_key(.A, true, false, .Find), .Select_All, "Ctrl+A / Find")
		key_chk(resolve_key(.P, true, false, .Find), .Palette_Open, "Ctrl+P / Find")
		key_chk(resolve_key(.S, true, false, .Find), .Save, "Ctrl+S / Find")
		key_chk(resolve_key(.C, true, false, .Find), .Copy, "Ctrl+C / Find")
		key_chk(resolve_key(.Z, true, false, .Find), .Undo, "Ctrl+Z / Find")
		key_chk(resolve_key(.N, true, false, .Find), .Tab_New, "Ctrl+N / Find")
		// These must NOT fall through — Find deliberately overrides them.
		key_chk(resolve_key(.Enter, false, false, .Find), .Find_Confirm, "Enter / Find (override)")
		key_chk(resolve_key(.Escape, false, false, .Find), .Find_Close, "Esc / Find (override)")
		key_chk(resolve_key(.H, true, false, .Find), .Find_Toggle_Replace_Mode, "Ctrl+H / Find (override)")
		// Unmodified keys must stay owned by the mode: falling these through would
		// edit and navigate the document while the user types a query.
		key_chk(resolve_key(.Delete, false, false, .Find), .None, "Delete / Find (no fall)")
		key_chk(resolve_key(.Left, false, false, .Find), .None, "Left / Find (no fall)")
		key_chk(resolve_key(.Home, false, false, .Find), .None, "Home / Find (no fall)")
		// The palette is a text field: nothing falls through to the editor.
		key_chk(resolve_key(.A, true, false, .Palette), .None, "Ctrl+A / Palette (no fall)")
		key_chk(resolve_key(.S, true, false, .Palette), .None, "Ctrl+S / Palette (no fall)")
		// ...and what dispatch actually does with them.
		d0 := app_active(&app)
		d0.cursor, d0.anchor = 0, 0
		command_dispatch(.Select_All, {}, &app, &dummy, &dtext, 10)
		fmt.printfln("dispatch Ctrl+A   -> anchor=%d cursor=%d len=%d", d0.anchor, d0.cursor, d0.pt.length)
		command_dispatch(resolve_key(.P, true, false, .Editor), {.P, true, false, false}, &app, &dummy, &dtext, 10)
		fmt.printfln("dispatch Ctrl+P   -> palette.active=%v results=%d", app.palette.active, len(app.palette.results))
		// Arrowing past the drawn window (12 rows) — does selected stay visible?
		for i in 0 ..< 30 {palette_move(&app, 1)}
		fmt.printfln("palette Down x30  -> selected=%d of %d (drawn rows=12)", app.palette.selected, len(app.palette.results))
		palette_close(&app)
		// Every palette-visible command should teach its shortcut, and the ones
		// that only exist inside find mode must be listed at all.
		shown, with_chord := 0, 0
		for cmd in Command_Id {
			if !command_in_palette(cmd) {continue}
			shown += 1
			if command_chord(cmd) != "" {with_chord += 1}
		}
		fmt.printfln("palette lists %d commands, %d show a shortcut", shown, with_chord)
		for c in ([]Command_Id{.Find_Toggle_Filter, .Find_Toggle_Regex, .Filter_Open, .Goto_Line, .Save_As}) {
			fmt.printfln("  %-24v in palette=%-5v chord=%q", c, command_in_palette(c), command_chord(c))
		}
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
		find_wait(&doc)
		fmt.printfln("query=%q replace=%q matches=%d", os.args[3], os.args[4], len(doc.find.matches))
		find_replace_all(&doc)
		s := doc_debug_string(&doc)
		fmt.printfln("after replace all: %q", s[:min(len(s), 40)])
		doc_close(&doc)

	case mode == "filtertest" && len(os.args) > 3:
		doc, _ := doc_open(path)
		find_open(&doc, false)
		for r in os.args[3] {find_input_rune(&doc, r)}
		find_wait(&doc)
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
		find_wait(&doc)
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
