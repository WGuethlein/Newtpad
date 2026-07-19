// Layer: program — headless verification entry points. The environment can't
// inject GUI keyboard/focus, so features are exercised through these argv modes
// (`newtpad <file> <mode> ...`) and checked against printed output. Kept out of
// main.odin so the frame loop reads clean.
package main

import "core:fmt"
import "core:os"
import "core:strconv"
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
		w := Settings{restore_session = false, wrap_default = true, font_size = 22, zoom_pct = 125}
		settings_save(w)
		r := settings_load()
		ok := r == w
		fmt.printfln("round-trip: restore=%v wrap=%v font=%d  %s", r.restore_session, r.wrap_default, r.font_size, "OK" if ok else "FAIL")
		if !ok {bad += 1}

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
			raw := t.char_em * px
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
