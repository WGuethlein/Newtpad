// Layer: program — headless verification entry points. The environment can't
// inject GUI keyboard/focus, so features are exercised through these argv modes
// (`newtpad <file> <mode> ...`) and checked against printed output. Kept out of
// main.odin so the frame loop reads clean.
package main

import "base:intrinsics"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"
import "core:time"
import "core:unicode/utf8"
import "core:unicode/utf16"
import base "src:base"
import plat "src:platform"

// The headless harness is `package main`, so without a gate every test mode
// ships inside the customer's exe -- the single largest contributor to release
// size (6t). Debug keeps it, release drops it, and `build.bat release tests`
// puts it back for the measurements that must run against an -o:speed build
// (6y's held-key column-edit cost is one).
NEWTPAD_TESTS :: #config(NEWTPAD_TESTS, ODIN_DEBUG)

when NEWTPAD_TESTS {

	@(private = "file")
	key_chk :: proc(got, want: Command_Id, label: string) {
		ok := "OK" if got == want else fmt.tprintf("FAIL want=%v", want)
		fmt.printfln("%-22s -> %-16v %s", label, got, ok)
	}

	// Guard for any headless mode that writes settings.txt, session.txt, or crash
	// backups. Without NEWTPAD_SESSION_DIR set, session_dir() falls back to the
	// real %APPDATA%\Newtpad (see session_dir's own doc comment), so a bare
	// `newtpad.exe <mode>` run by hand silently overwrites the author's real
	// font/zoom/view settings or wipes the restore-session store -- including
	// unsaved-tab backups. Every mode that touches either store calls this first.
	// A documented "set NEWTPAD_SESSION_DIR first" in a comment is not a
	// constraint if nothing checks it; this is the check.
	@(private = "file")
	require_scratch_session :: proc(mode: string) -> bool {
		if os.get_env("NEWTPAD_SESSION_DIR", context.temp_allocator) == "" {
			fmt.printfln("%s: refusing to run without NEWTPAD_SESSION_DIR", mode)
			return false
		}
		return true
	}

	// A real D3D11 device with no OS window. An offscreen render target stands in
	// for the swapchain, so a mode can drive the product's actual draw path,
	// print numbers, and exit.
	//
	// `drawcount` and `atlasgrowtest` both used to call window_create purely to
	// get a device, because gfx_init was the only way to make one — a visible
	// window that nothing ever pumped. That is the trap development-loop.md §6
	// records against `drawcount`, and it also made the reading environmental:
	// the window landed on whatever monitor, so its DPI scaled every metric, and
	// the physical mouse sitting over it changed how many hover quads the frame
	// drew.
	//
	// `window` here is a plain Window value with no hwnd. The draw path reads its
	// size and DPI and nothing else; window_cursor_client returns (-1,-1) for a
	// hwnd-less window (see its comment) so no hover state can leak in, and the
	// DPI is pinned at 96 rather than sampled from a monitor, so the same input
	// gives the same numbers on any machine.
	//
	// ~17 KB of Window buffers, so own it from a proc of your own rather than
	// from test_mode_dispatch's already-large frame (§6, stack overflow).
	@(private = "file")
	Headless_Gpu :: struct {
		gfx:    plat.Gfx,
		text:   plat.Text,
		quads:  plat.Quad_Pipeline,
		window: plat.Window,
	}

	@(private = "file")
	headless_gpu_init :: proc(h: ^Headless_Gpu, width, height: i32, label: string) -> bool {
		h.window.width, h.window.height = width, height
		h.window.dpi = 96
		ok: bool
		if h.gfx, ok = plat.gfx_init_offscreen(width, height); !ok {
			fmt.eprintfln("%s: offscreen device init failed", label)
			return false
		}
		if h.text, ok = plat.text_init(&h.gfx); !ok {
			fmt.eprintfln("%s: text init failed", label)
			return false
		}
		if h.quads, ok = plat.quads_init(&h.gfx); !ok {
			fmt.eprintfln("%s: quad init failed", label)
			return false
		}
		// The frame must not branch on what someone is holding down while the
		// measurement runs — Ctrl alone underlines every visible link.
		plat.keys_ignore_physical(true)
		return true
	}

	@(private = "file")
	headless_gpu_destroy :: proc(h: ^Headless_Gpu) {
		plat.keys_ignore_physical(false)
		plat.gfx_destroy(&h.gfx)
	}

	// No background job of this document's is still going to change what a frame
	// draws. Each worker is "quiet" when it was never started, finished, or
	// stopped on a fault — a faulted index never sets `done`, so waiting on
	// `done` alone would wait forever on exactly the mapped-file case the SEH
	// guard exists for.
	@(private = "file")
	doc_workers_quiet :: proc(d: ^Document) -> bool {
		if d == nil {return true}
		if d.idx.th != nil && !doc_index_done(d) && !intrinsics.atomic_load(&d.idx.fault) {
			return false
		}
		if d.lex_idx.th != nil && !lex_index_done(d) && !intrinsics.atomic_load(&d.lex_idx.fault) {
			return false
		}
		return !search_running(d)
	}

	// `newtpad drawcount <file>` — what one frame costs, and what one frame
	// contains. Two readings, and needing both is the lesson rather than a
	// flourish:
	//
	//   * The CALL COUNTS say whether batching the text pipeline achieved
	//     anything. text_draw_spans does one heap allocation, two buffer maps and
	//     one DrawInstanced per string across 74 call sites, several of them
	//     inside per-row loops, and HANDOFF §6k's "does an always-on gutter double
	//     per-frame draw calls?" is stated in these numbers.
	//   * The STREAM DIGESTS say whether the pixels moved. A call count is exactly
	//     the kind of assertion that passes while the content is wrong — halving
	//     the count by dropping half the glyphs reads as a win. The digest covers
	//     the ordered instances the GPU consumed and is blind to call boundaries,
	//     so a pure batching change leaves it identical while the counts fall.
	//     See draw_trace.odin.
	//
	// Runs offscreen and exits; no window, nothing on screen, no lock on the exe.
	//
	// KNOWN LIMITS — read these before trusting it to sign off the batching work,
	// because two of them will bite exactly there:
	//
	//   1. It measures ONE frame of ONE document in ONE view, reaching about six
	//      of the ~60 text_draw_spans call sites in program/ (they do carry all
	//      the instances, but still). Nothing here exercises the menus, palette,
	//      history panel, Settings/Font tabs, find/replace bar, filter banner,
	//      markdown preview or split, or the grid. A batching change can break any
	//      of those and this reports green. The fix is a view argument
	//      (`drawcount <file> [--menu|--palette|--find|--md-split|--grid]`), not a
	//      better digest — do not confuse the two.
	//   2. The digest hashes UVs, and UVs encode glyph FIRST-USE order in the
	//      atlas. A batching pass that regroups draws reorders glyph_get, which
	//      reshuffles the packer and moves the digest with zero pixel change — a
	//      FALSE POSITIVE arriving during precisely the work this was built for.
	//      Add a UV-independent digest (pos/size/colour only) before batching.
	//   3. The digest sees instances, not render state. Blend state, SRV, sampler,
	//      stride and the per-call constants buffer are all set per draw today and
	//      batching necessarily moves them; a bit-identical stream with the wrong
	//      blend state bound hashes green. Closing this needs a real pixel readback
	//      (CopyResource to a STAGING texture), which also dissolves limit 2.
	//   4. No cost measurement at all — no allocation count, no frame time — so a
	//      change could cut draw calls and raise cost unnoticed.
	//
	// doc_workers_quiet's last term is !search_running, and search.th is nil'd only
	// by search_stop, which the main loop drives and render_frame never does. Inert
	// while nothing here opens find; the moment limit 1 is closed with a --find
	// view, the settle loop will burn all 400 iterations and blame nondeterminism
	// for a missing reap.
	@(private = "file")
	draw_count_mode :: proc(path: string) {
		h: Headless_Gpu
		if !headless_gpu_init(&h, 1280, 720, "drawcount") {return}
		defer headless_gpu_destroy(&h)

		app: App
		menu_init(&app.menu)
		app.settings = settings_load() // scratch session dir => the defaults, deterministically
		// Without this g_theme stays at its zero value, which is transparent
		// black -- and that makes the digest's whole colour dimension a constant.
		// Every instance's 16 colour bytes would be {0,0,0,0}, the canvas clear
		// would be opaque black, and the text pixel shader emits cov * color.a,
		// so the offscreen target would be a uniform black rectangle. "The merged
		// batch used one call's colour for all of it" is the single likeliest bug
		// batching produces, and it is exactly what that hole hides -- as would
		// any pixel hash later built on this target. Mirrors main.odin's own
		// theme_resolve, which is the reason this is a real frame and not a
		// plausible one.
		g_theme = theme_resolve(app.settings.theme_name)
		defer app_destroy(&app)
		if !app_open_path(&app, path) {
			fmt.eprintfln("drawcount: could not open %q", path)
			return
		}

		rc := Render_Ctx{&h.gfx, &h.text, &h.quads, &app, &h.window, 0, 0, 0}
		active_render_ctx = &rc
		defer active_render_ctx = nil
		BASE_PX = f32(clamp(app.settings.font_size, FONT_SIZE_MIN, FONT_SIZE_MAX))
		plat.text_set_tab_width(&h.text, app.settings.tab_width)
		// Same two branches as main.odin's startup. Faithful without it only
		// because a scratch session dir forces the defaults -- so it would start
		// lying the moment anyone measured against a real settings.txt, and the
		// glyph mix is most of what the digest hashes.
		if app.settings.font_family != "" && app.settings.font_family != "Consolas" {
			plat.text_load_family(&h.text, app.settings.font_family, app.settings.font_style)
		} else if app.settings.font_style != .Regular {
			plat.text_load_family(&h.text, "Consolas", app.settings.font_style)
		}
		metrics_recompute(&rc)
		plat.draw_digest_enable(true)

		// Render whole frames until the frame stops changing, then report it. A
		// single frame is not reproducible, for two separate reasons:
		//
		//   * the first frame fills the glyph atlas, so it is a first-paint frame,
		//     not the steady-state one the product spends its life drawing;
		//   * the line index and the stateful-lexer index run on worker threads,
		//     and their results reach the screen. The status bar carries
		//     "(indexing 47%)" while the line index runs — same glyph count as
		//     "(indexing 48%)", different glyphs — which is precisely a change the
		//     call counts cannot see and the digest can. Measured on a 149 MB log
		//     before this wait existed: identical counts, identical instance
		//     totals, and a text digest that differed on every run.
		//
		// So: wait for the workers to go quiet, and only then require two
		// consecutive identical frames. Both halves are load-bearing — quiet alone
		// still catches the first-paint frame, and two-in-a-row alone is
		// satisfiable mid-index whenever the rounded percentage happens to repeat.
		doc := app_active(&app)
		SETTLE_MAX :: 400
		prev, cur: plat.Draw_Stats
		frames := 0
		settled, have_prev := false, false
		for i in 1 ..= SETTLE_MAX {
			free_all(context.temp_allocator) // as the real frame loop does
			plat.draw_counts_reset()
			render_frame(&rc, false)
			cur = plat.draw_stats()
			frames = i
			quiet := doc_workers_quiet(doc)
			if quiet && have_prev && cur == prev {
				settled = true
				break
			}
			prev = cur
			have_prev = quiet // never compare against a frame drawn mid-index
			time.sleep(2 * time.Millisecond)
		}

		// Repack the atlas from scratch, then measure. A glyph's UVs ARE its
		// position in the atlas, and the shelf packer assigns those in first-use
		// order — so the UVs in a warm frame's instance stream encode which glyphs
		// the settle frames happened to touch on the way here. That is history,
		// not content: with the indexing percentage counting up during warm-up,
		// the same 149 MB file settled with a different text digest on every run
		// while the call counts and the instance totals stayed identical. After a
		// reset the measured frame packs the atlas in its own deterministic draw
		// order, so the stream describes the frame and nothing else.
		plat.text_reset_atlas(&h.text)
		warm: plat.Draw_Stats
		for i in 0 ..< 2 {
			free_all(context.temp_allocator)
			plat.draw_counts_reset()
			render_frame(&rc, false)
			if i == 0 {warm = plat.draw_stats()} else {cur = plat.draw_stats()}
		}
		// The repacking frame and the one after it must agree. They differ only if
		// the atlas ran out of room and relieved mid-measurement, which would make
		// the reported stream one that no steady-state frame ever draws.
		reproducible := warm == cur

		rows := doc_visible_rows(doc, f32(h.window.height), rc.line_h)
		tc, qc := cur.text_calls, cur.quad_calls

		fmt.println("--- drawcount: headless offscreen frame, 1280x720 @96dpi, no menu open ---")
		fmt.printfln("  file                   : %s", path)
		fmt.printfln("  font / size / tab      : %s %v / %.0f px / %d", app.settings.font_family, app.settings.font_style, rc.px, app.settings.tab_width)
		fmt.printfln(
			"  frame settled after    : %d frames %s",
			frames,
			"(workers quiet, two identical in a row)" if settled else "FAIL - never settled, the numbers below are one sample of a moving target",
		)
		fmt.printfln(
			"  measured frame         : atlas %dx%d, repacked  %s",
			plat.text_atlas_dim(&h.text),
			plat.text_atlas_dim(&h.text),
			"(reproduced identically on the next frame)" if reproducible else "FAIL - the next frame differed; the atlas moved mid-measurement",
		)
		fmt.printfln("  visible text rows      : %d", rows)
		fmt.println("--- draw calls ---")
		fmt.printfln("  plat.text_draw  calls  : %d  (%d issued a DrawInstanced, %d drew no glyphs)", tc, cur.text_draws, tc - cur.text_draws)
		fmt.printfln("  plat.quads_draw calls  : %d", qc)
		fmt.printfln("  total draw calls       : %d", tc + qc)
		fmt.println("--- instance stream (what the GPU consumed) ---")
		fmt.printfln("  text instances         : %d", cur.text_instances)
		fmt.printfln("  quad instances         : %d", cur.quad_instances)
		fmt.printfln(
			"  instances clamped away : %d text, %d quad  %s",
			cur.text_clamped,
			cur.quad_clamped,
			"" if cur.text_clamped == 0 && cur.quad_clamped == 0 else "FAIL - MAX_TEXT_INSTANCES/MAX_QUADS dropped geometry; the frame on screen is incomplete",
		)
		fmt.printfln("  text  stream digest    : 0x%016x", cur.text_digest)
		fmt.printfln("  quad  stream digest    : 0x%016x", cur.quad_digest)
		fmt.printfln("  frame stream digest    : 0x%016x", cur.frame_digest)
		fmt.println("--- projection: one more text_draw per visible row (the gutter) ---")
		fmt.printfln("  projected text_draw    : %d  (x%.2f)", tc + rows, f32(tc + rows) / max(f32(tc), 1))
		fmt.printfln("  projected total        : %d  (x%.2f)", tc + qc + rows, f32(tc + qc + rows) / max(f32(tc + qc), 1))
		fmt.printfln("  per-row share of today's text_draw: %.0f%%", 100 * f32(rows) / max(f32(tc), 1))
		fmt.println("  (text_draw also heap-allocates a [dynamic]Text_Instance per call — text.odin)")
	}

	// `newtpad atlasgrowtest` proves the atlas actually grows. atlastest checks
	// only text_atlas_fit_count -- arithmetic that assumes growth works -- and it
	// passed for the entire time growth was impossible, because it never asked the
	// atlas to do anything. atlas_relieve's one caller sat inside text_draw, where
	// its own `drawing` guard always refused, so the atlas stayed at ATLAS_START
	// forever and glyphs past ~1196 silently vanished while the pen advanced.
	//
	// Needs a real device, which is all it needs: no window (it used to make one).
	@(private = "file")
	atlas_grow_mode :: proc() -> int {
		h: Headless_Gpu
		if !headless_gpu_init(&h, 800, 600, "atlasgrowtest") {return 1}
		defer headless_gpu_destroy(&h)

		start_dim := plat.text_atlas_dim(&h.text)
		fmt.printfln("--- atlas growth under a heavy glyph load ---")
		fmt.printfln("  start dim         : %d (ATLAS_START)", start_dim)

		// Draw a lot of distinct CJK codepoints at a large size: glyph area grows
		// with px^2, so this overflows 1024 quickly. One text_draw per frame, with
		// a frame boundary between, which is where relief is now allowed to happen.
		FRAMES :: 40
		PER :: 64
		cp := rune(0x4E00)
		for _ in 0 ..< FRAMES {
			plat.text_frame_begin(&h.gfx, &h.text)
			plat.gfx_begin_frame(&h.gfx, 0, 0, 0)
			buf: [PER * 4]u8
			n := 0
			for _ in 0 ..< PER {
				b, sz := utf8.encode_rune(cp)
				bb := b
				copy(buf[n:], bb[:sz])
				n += sz
				cp += 1
			}
			plat.text_draw(&h.gfx, &h.text, string(buf[:n]), 0, 40, 48, {1, 1, 1, 1})
			plat.gfx_end_frame(&h.gfx, 0)
		}
		// One more boundary so any relief owed by the final frame is applied.
		plat.text_frame_begin(&h.gfx, &h.text)

		end_dim := plat.text_atlas_dim(&h.text)
		grew := end_dim > start_dim
		fmt.printfln("  after %d frames    : %d", FRAMES, end_dim)
		fmt.printfln("  atlas grew        : %v %s", grew, "OK" if grew else "FAIL")
		fmt.printfln("  atlas_full latched: %v %s", plat.text_atlas_full(&h.text), "OK" if !plat.text_atlas_full(&h.text) else "FAIL")
		bad := 0
		if !grew {bad += 1}
		if plat.text_atlas_full(&h.text) {bad += 1}
		return bad
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
			rev0 := doc.revision
			absorbed := doc_absorb_append(&doc, s1.size)
			txt := doc_debug_string(&doc)
			tail_ok := absorbed && doc.pt.length == int(s1.size) && doc.cursor == doc.pt.length
			fmt.printfln("absorbed=%v len=%d (want %d) caret follows=%v  %s", absorbed, doc.pt.length, s1.size, doc.cursor == doc.pt.length, "OK" if tail_ok else "FAIL")
			if !tail_ok {bad += 1}
			fmt.printfln("  content: %q", txt)
			// doc_absorb_append bypasses push_undo by design, so it must bump
			// revision itself; a future refactor that drops the bump leaves the
			// markdown table cache reading stale columns with no other symptom.
			rev0_ok := doc.revision > rev0
			fmt.printfln("  revision bumped: %d -> %d  %s", rev0, doc.revision, "OK" if rev0_ok else "FAIL")
			if !rev0_ok {bad += 1}

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
				rev1 := doc.revision
				doc_absorb_append(&doc, s2.size)
				got := doc_debug_string(&doc)
				want := fmt.tprintf("%s%s", saved, "tail\n")
				dup_ok := got == want
				fmt.printfln("append after save: %q  %s", got[:min(len(got), 32)], "OK" if dup_ok else "FAIL")
				if !dup_ok {
					fmt.printfln("  want %q", want[:min(len(want), 32)])
					bad += 1
				}
				rev1_ok := doc.revision > rev1
				fmt.printfln("  revision bumped: %d -> %d  %s", rev1, doc.revision, "OK" if rev1_ok else "FAIL")
				if !rev1_ok {bad += 1}
			}

			// Shrinking is not an append: it must be refused so the caller reloads.
			refused := !doc_absorb_append(&doc, 5)
			fmt.printfln("shrink refused by append path: %v  %s", refused, "OK" if refused else "FAIL")
			if !refused {bad += 1}

			// A rewrite that is not an append -> full reload, position preserved.
			plat.file_write_atomic(path, transmute([]u8)string("completely different\ncontent here\n"))
			doc.cursor = 5
			doc.anchor = 5
			rev2 := doc.revision
			rok := doc_reload(&doc)
			after := doc_debug_string(&doc)
			reload_ok := rok && doc.cursor == 5 && !doc.disk_changed
			fmt.printfln("reload=%v caret=%d stamp refreshed=%v  %s", rok, doc.cursor, doc.disk_stamp.ok, "OK" if reload_ok else "FAIL")
			if !reload_ok {bad += 1}
			fmt.printfln("  content: %q", after[:min(len(after), 24)])
			// doc_reload replaces the whole Document; the old revision must carry
			// forward and bump, not reset to the fresh struct's zero value.
			rev2_ok := doc.revision > rev2
			fmt.printfln("  revision bumped: %d -> %d  %s", rev2, doc.revision, "OK" if rev2_ok else "FAIL")
			if !rev2_ok {bad += 1}

			// A caret past the new end must clamp, not index out of bounds.
			plat.file_write_atomic(path, transmute([]u8)string("tiny\n"))
			doc.cursor = 999
			doc.anchor = 999
			rev3 := doc.revision
			doc_reload(&doc)
			clamped := doc.cursor <= doc.pt.length
			fmt.printfln("caret clamped after shrink: %d <= %d  %s", doc.cursor, doc.pt.length, "OK" if clamped else "FAIL")
			if !clamped {bad += 1}
			rev3_ok := doc.revision > rev3
			fmt.printfln("  revision bumped: %d -> %d  %s", rev3, doc.revision, "OK" if rev3_ok else "FAIL")
			if !rev3_ok {bad += 1}

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
			if !require_scratch_session("settingstest") {return true}
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
				tab_width       = 3, // non-default and in range, so the whole-struct compare below can see it
				font_family     = "Courier New",
				font_style      = .Italic,
				split_frac      = 0.25, // non-zero, non-default, exact in binary float (survives %.4f round-trip)
				theme_name      = "Light", // non-blank, non-default -- see the blank-normalises check below for ""
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

			// tab_width has the same "0 is not a real choice" hazard as zoom_pct,
			// and a sharper consequence: a 0 reaching plat.text_cell_width_at
			// makes the advance 0 and every measuring loop non-terminating. So
			// the save side must write the DEFAULT for a 0, not the clamped
			// minimum -- writing 1 would silently turn every tab into one cell on
			// the next launch.
			settings_save(Settings{restore_session = true, font_size = 16, zoom_pct = 100})
			tz := settings_load()
			tzok := tz.tab_width == plat.TAB_WIDTH_DEFAULT
			fmt.printfln("tab_width 0 saves as the default %d (not the min) -> %d  %s", plat.TAB_WIDTH_DEFAULT, tz.tab_width, "OK" if tzok else "FAIL")
			if !tzok {bad += 1}

			// Out of range in both directions, written straight to disk so this is
			// settings_load's own normalise and not a re-test of the save side.
			//
			// The 0 case is the seam, not a second clamp check: a `tab_width 0` on
			// disk (hand-edited, or a truncated write) must resolve to whatever a
			// struct 0 resolves to on the way OUT, because the two sides are the
			// same value read twice. They disagreed once -- save wrote the default
			// 4 while load clamped to the minimum 1, so a hand-edited file gave
			// one-cell tabs in every document -- and the assertion below is written
			// against `tz` (what the save side produced for a struct 0, measured
			// eight lines up) rather than against a literal, so reintroducing the
			// disagreement in EITHER direction fails it.
			if p, pok := session_dir(); pok {
				base_kv := "newtpad-settings 1\nrestore_session 1\nwrap_default 0\nfont_size 16\nzoom_pct 100\n"
				plat.file_write_atomic(fmt.tprintf("%s%csettings.txt", p, '\\'), transmute([]u8)strings.concatenate({base_kv, "tab_width 99\n"}, context.temp_allocator))
				hiw := settings_load()
				plat.file_write_atomic(fmt.tprintf("%s%csettings.txt", p, '\\'), transmute([]u8)strings.concatenate({base_kv, "tab_width 0\n"}, context.temp_allocator))
				low := settings_load()
				twok := hiw.tab_width == plat.TAB_WIDTH_MAX && low.tab_width == tz.tab_width && low.tab_width == plat.TAB_WIDTH_DEFAULT
				fmt.printfln(
					"tab_width on disk 99 -> %d (want %d), 0 -> %d (want %d, the same thing a struct 0 saves as)  %s",
					hiw.tab_width, plat.TAB_WIDTH_MAX, low.tab_width, tz.tab_width, "OK" if twok else "FAIL",
				)
				if !twok {bad += 1}
			}

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

			// --- tab width reaches the text layer -----------------------------
			// The row can be right and the wiring still missing: settings_apply
			// is the only thing that pushes the setting into plat.Text, and
			// nothing else in the program reads Settings.tab_width. Assert the
			// row index first -- SETTINGS_ROWS is index-matched against the value
			// switch and the toggle switch, so an inserted row silently moves
			// this to a different setting.
			fmt.println("--- tab width ---")
			trok := len(SETTINGS_ROWS) > 8 && SETTINGS_ROWS[8].label == "Tab width"
			fmt.printfln("  row 8 is %q  %s", SETTINGS_ROWS[8].label if len(SETTINGS_ROWS) > 8 else "", "OK" if trok else "FAIL")
			if !trok {bad += 1}
			az.settings.tab_width = 4
			settings_toggle_row(&rcz, 8, 1)
			settings_toggle_row(&rcz, 8, 1)
			up := az.settings.tab_width == 6 && plat.text_tab_width(&t2) == 6
			fmt.printfln("  two Rights -> setting %d, text layer %d (want 6, 6)  %s", az.settings.tab_width, plat.text_tab_width(&t2), "OK" if up else "FAIL")
			if !up {bad += 1}
			for _ in 0 ..< 40 {settings_toggle_row(&rcz, 8, -1)}
			downc := az.settings.tab_width == plat.TAB_WIDTH_MIN && plat.text_tab_width(&t2) == plat.TAB_WIDTH_MIN
			fmt.printfln("  40 Lefts clamp at %d (text layer %d)  %s", az.settings.tab_width, plat.text_tab_width(&t2), "OK" if downc else "FAIL")
			if !downc {bad += 1}
			settings_toggle_row(&rcz, 8, 0) // Enter resets
			rstw := az.settings.tab_width == plat.TAB_WIDTH_DEFAULT && plat.text_tab_width(&t2) == plat.TAB_WIDTH_DEFAULT
			fmt.printfln("  Enter resets to %d (text layer %d)  %s", az.settings.tab_width, plat.text_tab_width(&t2), "OK" if rstw else "FAIL")
			if !rstw {bad += 1}

			// --- a tab-width change invalidates the CELL caches ---------------
			// metrics_recompute and text_reset_atlas between them cover every
			// cached measurement denominated in PIXELS, which is why they were
			// enough for font and zoom. Two caches hold CELL counts and are keyed
			// on nothing a settings change moves: doc.md_table on doc.revision
			// (only an edit bumps it) and doc.table_widths on edits and view
			// toggles. Without settings_apply invalidating them, changing Tab
			// width with a grid or a preview open leaves both columns sized
			// against the old tab stops until the next edit.
			//
			// Both checks read the value THE DRAW WOULD USE (table_draw's own
			// "refit when empty", md_table_ensure's own lookup), not the validity
			// flags, so they cannot pass on an invalidation that clears a flag
			// nothing consults.
			fmt.println("--- tab width invalidates the cell caches ---")
			{
				// A literal tab in the MIDDLE of a field, so the measurement moves
				// with the tab width: "a\tb" is 'a' + a tab from column 1 + 'b',
				// which is 5 cells at width 4 and 9 at width 8. A LEADING tab
				// would be one full width in both and could not tell them apart.
				cd := new(Document)
				cd^ = doc_from_content(transmute([]u8)strings.clone("a\tb,c\nd,e\n"), "t.csv", .UTF8)
				cd.table, cd.table_delim = true, ','
				mdd := new(Document)
				mdd^ = doc_from_content(transmute([]u8)strings.clone("| a\tb | c |\n|---|---|\n| d | e |\n"), "t.md", .UTF8)
				app_add(&az, cd)
				app_add(&az, mdd)

				settings_toggle_row(&rcz, 8, 0) // Enter: start from the default 4
				table_compute_widths(cd, &t2)
				w4 := cd.table_widths[0] if len(cd.table_widths) > 0 else -1
				m4 := -1
				if c := md_table_ensure(mdd, &t2, 0); c != nil {m4 = c.widths[0]}
				base4 := w4 == 5 && m4 == 5
				fmt.printfln("  %-6s at width 4: grid col 0 = %d cells, md col 0 = %d (want 5, 5)", "ok" if base4 else "FAIL", w4, m4)
				if !base4 {bad += 1}

				for _ in 0 ..< 4 {settings_toggle_row(&rcz, 8, 1)} // 4 -> 8

				// table_draw's own line: refit only when the widths were cleared.
				if len(cd.table_widths) == 0 {table_compute_widths(cd, &t2)}
				w8 := cd.table_widths[0] if len(cd.table_widths) > 0 else -1
				m8 := -1
				if c := md_table_ensure(mdd, &t2, 0); c != nil {m8 = c.widths[0]}
				movd := w8 == 9 && m8 == 9
				fmt.printfln(
					"  %-6s at width 8: grid col 0 = %d cells, md col 0 = %d (want 9, 9; a stale cache reports 5)",
					"ok" if movd else "FAIL", w8, m8,
				)
				if !movd {bad += 1}

				app_destroy(&az)
				az = App{} // the dynamic arrays above are freed; do not walk them again
				az.settings = settings_default()
			}

			BASE_PX = BASE_PX_96 // leave globals alone for later modes

			// The settings-page row list (IMPORTANT 3, final review): the 8th row
			// (Theme) stopped always fitting the window once it was added -- at
			// 150% DPI on a 1366x768 laptop, the unclamped layout drew its label
			// and help text straddling the version string's baseline. Checked at
			// the reported scale/height plus two others so the guard isn't tuned
			// to one number, using the same settings_list_bounds/
			// settings_rows_fitting settings_draw itself now calls -- not a
			// parallel copy of the arithmetic, so the two cannot disagree.
			fmt.println("--- settings row-list overflow ---")
			check_fit :: proc(rc: ^Render_Ctx, dpi: u32, height: f32) -> (ok: bool, shown: int, last_bottom, version_y: f32) {
				rc.window.dpi = dpi
				metrics_recompute(rc)
				rowh := sx(46)
				y0, avail_h := settings_list_bounds(height)
				shown = settings_rows_fitting(0, avail_h, rowh)
				last_bottom = y0 + f32(shown) * rowh
				version_y = height - sx(24)
				ok = last_bottom <= version_y
				return
			}
			cases := [][2]f32{{96, 900}, {144, 768}, {192, 1080}}
			for c in cases {
				dpi, height := u32(c[0]), c[1]
				ok, shown, last_bottom, version_y := check_fit(&rcz, dpi, height)
				fmt.printfln(
					"  %-6s dpi=%d height=%.0f: %d/%d rows shown, last row bottom=%.0f (version line=%.0f)",
					"ok" if ok else "FAIL",
					dpi,
					height,
					shown,
					settings_row_count(),
					last_bottom,
					version_y,
				)
				if !ok {bad += 1}
			}
			// Proof this check can actually fail (CLAUDE.md: "a test that has never
			// failed proves nothing") -- the unclamped layout the bug shipped with
			// (draw every row regardless of height) DOES overflow at 150%/768. If
			// this stops reproducing, the scenario needs revisiting, not just the
			// fitted-count assertion above.
			{
				rcz.window.dpi = 144
				metrics_recompute(&rcz)
				rowh := sx(46)
				y0, _ := settings_list_bounds(768)
				naive_bottom := y0 + f32(settings_row_count()) * rowh
				naive_version_y := f32(768) - sx(24)
				overflowed := naive_bottom > naive_version_y
				fmt.printfln(
					"  %-6s unclamped layout overflows at 150%%/768 (naive_bottom=%.0f, version_y=%.0f)",
					"ok" if overflowed else "FAIL",
					naive_bottom,
					naive_version_y,
				)
				if !overflowed {bad += 1}
			}
			rcz.window.dpi = 96
			metrics_recompute(&rcz) // leave globals alone for later modes

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

			// The Encoding menu. A fourth top-level menu is the first change to the
			// bar's width since it was written, so the seam assertions above matter
			// more here than the contents do.
			enc_menu := -1
			for m, i in menus {
				if m.title == "Encoding" {enc_menu = i}
			}
			enc_rows_ok := enc_menu >= 0 && len(menus[enc_menu].items) == 10
			fmt.printfln("  %-6s Encoding menu present with 8 commands + 2 separators: idx=%d", "ok" if enc_rows_ok else "FAIL", enc_menu)
			if !enc_rows_ok {bad += 1}

			mn_ok := true
			enc_seen: map[rune]bool
			defer delete(enc_seen)
			for m in menus {
				if enc_seen[m.mnemonic] {mn_ok = false}
				enc_seen[m.mnemonic] = true
			}
			fmt.printfln("  %-6s every menu mnemonic is unique", "ok" if mn_ok else "FAIL")
			if !mn_ok {bad += 1}

			// Settings and Font are TABS, so app_active returns a Document for them
			// and has_doc is true. The Encoding menu's Save-as and Line-Endings rows
			// used that predicate and were therefore live on a pseudo-tab: "Save as
			// UTF-16 LE" set doc.modified on a page with no file, and closing the
			// tab then asked whether to save it -- closing it via the tab strip's X,
			// the File row or Escape, NOT via Ctrl+W, which is bound in the .Editor
			// context only and does not resolve on a pseudo-tab at all. Every row of the
			// menu must be dead there -- the Reopen_* rows already were, via has_file.
			{
				ea: App
				app_open_special(&ea, .Settings)
				live: [dynamic]Command_Id
				defer delete(live)
				// found matters as much as live: without it, `len(live) == 0` reads the
				// same whether every row is dead or the menu was never located, so
				// renaming the menu would leave this passing while testing nothing.
				found := false
				for m in menus {
					if m.title != "Encoding" {continue}
					found = true
					for it in m.items {
						if it.cmd == .None {continue}
						// item_enabled, not it.enabled: the row predicate is only
						// half the rule now (command_allowed_on is the other half),
						// and the half the product reads is the one worth asserting.
						if item_enabled(&ea, it) {append(&live, it.cmd)}
					}
				}
				enc_dead := found && len(live) == 0
				fmt.printfln("  %-6s no Encoding row is live on the Settings tab: found=%v still live=%v", "ok" if enc_dead else "FAIL", found, live[:])
				if !enc_dead {bad += 1}
				app_destroy(&ea)
			}

			// The same pseudo-tab problem outside the Encoding menu, which the
			// Encoding fix did not reach: File > Save / Save As and Edit > Paste
			// were has_doc, so all three were live on Settings and Font. Save
			// raised a Save dialog for a page with no file; Paste inserted the
			// clipboard into a document nothing draws and left it .modified, so
			// closing the tab -- by the tab strip's X, by this File row, or by Escape;
			// Ctrl+W does not resolve on a pseudo-tab -- then asked whether to save it.
			//
			// Tab_Close is asserted LIVE in the same breath, deliberately: closing
			// one is the only thing on this menu that means anything on a pseudo-tab,
			// so a gate written as "nothing runs there" -- or done as one predicate
			// swap over the rows above -- would kill the row that has to survive.
			// Without this half the test would pass just as well against that wrong
			// fix.
			menu_row_live :: proc(app: ^App, cmd: Command_Id) -> (live: bool, found: bool) {
				for m in menus {
					for it in m.items {
						if it.cmd != cmd {continue}
						found = true
						// Through item_enabled: the kind rule now lives in
						// command_allowed_on, so `it.enabled` alone no longer decides
						// whether a row is live, and asserting on half the rule would
						// report Save as live on a pseudo-tab.
						if item_enabled(app, it) {live = true}
					}
				}
				return
			}
			pseudo_tab_rows_case :: proc(kind: Tab_Kind) -> (bad: int) {
				a: App
				app_open_special(&a, kind)
				defer app_destroy(&a)
				for cmd in ([]Command_Id{.Save, .Save_As, .Paste}) {
					live, found := menu_row_live(&a, cmd)
					ok := found && !live
					fmt.printfln("  %-6s %-8v %-8v is dead on the pseudo-tab (found=%v)", "ok" if ok else "FAIL", kind, cmd, found)
					if !ok {bad += 1}
				}
				live, found := menu_row_live(&a, .Tab_Close)
				ok := found && live
				fmt.printfln("  %-6s %-8v Tab_Close stays LIVE (found=%v)", "ok" if ok else "FAIL", kind, found)
				if !ok {bad += 1}
				return
			}
			fmt.println("--- mutating rows are dead on the Settings and Font pseudo-tabs ---")
			bad += pseudo_tab_rows_case(.Settings)
			bad += pseudo_tab_rows_case(.Font)
			// ...and all four are live on a real text tab, or the three above would
			// pass with the rows simply disabled everywhere.
			{
				a: App
				app_new_scratch(&a)
				defer app_destroy(&a)
				all_live := true
				for cmd in ([]Command_Id{.Save, .Save_As, .Paste, .Tab_Close}) {
					live, found := menu_row_live(&a, cmd)
					if !found || !live {all_live = false}
				}
				fmt.printfln("  %-6s all four are live on an ordinary text tab", "ok" if all_live else "FAIL")
				if !all_live {bad += 1}
			}

			// Nothing anywhere exercised what a `checked` predicate MEANS. This mode
			// asserted that the model is well-formed and that the mnemonics do not
			// collide; whether a check mark tracks the state it names was untested
			// for is_wrapped and is_table since they were written, and for the
			// encoding predicates since batch 6 added them.
			//
			// Read through the menus table rather than by calling the predicates,
			// which are @(private = "file") in menu.odin anyway: that makes the
			// assertion cover the WIRING too. A row pointed at the wrong predicate
			// -- Toggle_Table checked by is_wrapped, say -- is the likelier mistake
			// than a predicate that reads the wrong field, and calling the procs
			// directly would miss it entirely.
			//
			// Driven with command_dispatch, not by writing doc.wrap: the check mark
			// and the command must agree, and that is a seam.
			menu_checked_of :: proc(app: ^App, cmd: Command_Id) -> (checked, found: bool) {
				for m in menus {
					for it in m.items {
						if it.cmd != cmd || it.checked == nil {continue}
						found = true
						if it.checked(app) {checked = true}
					}
				}
				return
			}
			// A toggle's check mark must be off, then on, then off again -- all
			// three, because "reads true once" also passes for a predicate stuck
			// true, and "flips" passes for one that is simply inverted.
			checked_toggle_case :: proc(t: ^plat.Text, cmd: Command_Id, label: string) -> (bad: int) {
				a: App
				dummy: plat.Window
				a.settings = settings_default()
				app_new_scratch(&a) // untitled: doc_can_table/doc_can_markdown allow any view
				defer app_destroy(&a)
				before, found := menu_checked_of(&a, cmd)
				command_dispatch(cmd, {}, &a, &dummy, t, 10)
				on, _ := menu_checked_of(&a, cmd)
				command_dispatch(cmd, {}, &a, &dummy, t, 10)
				off, _ := menu_checked_of(&a, cmd)
				ok := found && !before && on && !off
				fmt.printfln(
					"  %-6s %-14v check mark: start=%v after one toggle=%v after two=%v (found=%v)",
					"ok" if ok else "FAIL", label, before, on, off, found,
				)
				if !ok {bad += 1}
				return
			}
			// The encoding rows track a VALUE, so the property is exclusivity: after
			// picking one, that row is checked and the sibling rows are not. A
			// predicate comparing against the wrong enum member passes an "is it
			// checked" test on whichever encoding it happens to name.
			checked_encoding_case :: proc() -> (bad: int) {
				a: App
				dummy: plat.Window
				t: plat.Text
				app_new_scratch(&a)
				defer app_destroy(&a)
				u8_before, found := menu_checked_of(&a, .Enc_UTF8)
				command_dispatch(.Enc_UTF16LE, {}, &a, &dummy, &t, 10)
				u16_on, _ := menu_checked_of(&a, .Enc_UTF16LE)
				u8_off, _ := menu_checked_of(&a, .Enc_UTF8)
				cp_off, _ := menu_checked_of(&a, .Enc_CP1252)
				ok := found && u8_before && u16_on && !u8_off && !cp_off
				fmt.printfln(
					"  %-6s Enc rows are exclusive: UTF8 was %v, after Enc_UTF16LE -> UTF16LE=%v UTF8=%v CP1252=%v",
					"ok" if ok else "FAIL", u8_before, u16_on, u8_off, cp_off,
				)
				if !ok {bad += 1}
				return
			}
			fmt.println("--- check marks track the state they name ---")
			bad += checked_toggle_case(&t, .Toggle_Wrap, "Toggle_Wrap")
			bad += checked_toggle_case(&t, .Toggle_Table, "Toggle_Table")
			bad += checked_encoding_case()

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

		// `newtpad mdtest` covers the markdown block classifiers and inline parser
		// (the rendering itself needs a live eye).
		if os.args[1] == "mdtest" {
			bad := md_selftest()
			fmt.printfln("mdtest: %d failures", bad)
			return true
		}

		// `newtpad csvtest` covers the table-view field parser: delimiters, empties,
		// quoted fields with embedded delimiters, and "" escapes.
		if os.args[1] == "csvtest" {
			bad := 0
			Case :: struct {
				line:  string,
				delim: u8,
				want:  []string,
			}
			cases := []Case {
				{"a,b,c", ',', {"a", "b", "c"}},
				{"a,,c", ',', {"a", "", "c"}},
				{`"a,b",c`, ',', {"a,b", "c"}},
				{`"a""b",c`, ',', {`a"b`, "c"}},
				{"", ',', {""}},
				{"a,", ',', {"a", ""}},
				{",b", ',', {"", "b"}},
				{"x\ty\tz", '\t', {"x", "y", "z"}},
			}
			for c in cases {
				got := csv_fields(c.line, c.delim)
				ok := len(got) == len(c.want)
				if ok {
					for f, i in got {
						if f != c.want[i] {ok = false;break}
					}
				}
				fmt.printfln("  %-12q -> %v %s", c.line, got, "OK" if ok else fmt.tprintf("FAIL want %v", c.want))
				if !ok {bad += 1}
			}
			fmt.printfln("csvtest: %d failures", bad)
			return true
		}

		// `newtpad tablecellstest` covers in-cell editing: the field byte-range
		// parser, the CSV serializer's quoting rules, and the full replace-a-field
		// splice that table_edit_commit performs.
		if os.args[1] == "tablecellstest" {
			bad := table_selftest()
			fmt.printfln("tablecellstest: %d failures", bad)
			return true
		}

		// `newtpad tablereadonlytest` guards the data-loss hole a red-team found: table
		// view is a read-only grid, so command_dispatch must block every
		// document-mutating command (a stale caret from text view would otherwise
		// corrupt the file invisibly), and doc_replace_range must clamp an out-of-range
		// span rather than fault (a cell edit holds byte offsets that another edit could
		// have shrunk).
		if os.args[1] == "tablereadonlytest" {
			bad := 0
			// 1. The exact guard condition in command_dispatch: doc.table && mutates.
			mutating := []Command_Id {
				.Backspace, .Delete_Fwd, .Delete_Word_Back, .Insert_Newline, .Insert_Tab, .Undo, .Redo, .Cut, .Paste,
			}
			for c in mutating {
				if !command_mutates_doc(c) {
					fmt.printfln("  FAIL %v not classified as mutating (would leak into table view)", c)
					bad += 1
				}
			}
			// Read-only / navigation commands must NOT be blocked.
			safe := []Command_Id{.Copy, .Cursor_Left, .Cursor_Down, .Select_All, .Save, .Page_Down}
			for c in safe {
				if command_mutates_doc(c) {
					fmt.printfln("  FAIL %v wrongly classified as mutating (would be blocked in table view)", c)
					bad += 1
				}
			}
			// 2. doc_replace_range clamps a stale, now-out-of-range span instead of
			//    faulting. Shrink the buffer, then splice at the old (too-large) offset.
			d := new(Document)
			d^ = doc_from_content(transmute([]u8)strings.clone("abcdef"), "t.csv", .UTF8)
			fs, fe := 4, 6 // a field span captured when the buffer was 6 bytes
			doc_replace_range(d, 0, 4, nil) // delete "abcd" -> "ef" (length 2 now)
			doc_replace_range(d, fs, fe - fs, []u8{'Z'}) // stale [4,6): must clamp, not fault
			got := make([]u8, d.pt.length, context.temp_allocator)
			base.pt_read(&d.pt, 0, got)
			if string(got) != "efZ" {
				fmt.printfln("  FAIL clamp: got %q want %q", string(got), "efZ")
				bad += 1
			}
			doc_close(d)
			free(d)
			fmt.printfln("tablereadonlytest: %d failures", bad)
			return true
		}

		// `newtpad logtest` covers the base ring-buffer logger: level gating, the
		// oldest-first dump order, wrap-around retention, and truncation.
		if os.args[1] == "logtest" {
			bad := 0
			base.log_init(.Info)
			// Level gate: a Debug line is dropped when the floor is Info.
			base.log_debug("dropped")
			if base.log_total() != 0 {
				fmt.println("  FAIL debug line not gated out")
				bad += 1
			}
			base.log_info("first")
			base.log_warn("second")
			if base.log_total() != 2 || base.log_retained() != 2 {
				fmt.printfln("  FAIL counts total=%d retained=%d want 2/2", base.log_total(), base.log_retained())
				bad += 1
			}
			// Dump order is oldest-first.
			@(static) order: [dynamic]string
			clear(&order)
			base.log_each(proc(u: rawptr, e: ^base.Log_Entry) {
				append(cast(^[dynamic]string)u, strings.clone(string(e.text[:e.len]), context.temp_allocator))
			}, &order)
			if len(order) != 2 || order[0] != "first" || order[1] != "second" {
				fmt.printfln("  FAIL dump order %v", order)
				bad += 1
			}
			// Wrap: write more than the ring holds; retained caps at LOG_RING and the
			// oldest are the most recent LOG_RING lines.
			for i in 0 ..< base.LOG_RING + 50 {base.log_info("line-%d", i)}
			if base.log_retained() != base.LOG_RING {
				fmt.printfln("  FAIL retained=%d want %d after wrap", base.log_retained(), base.LOG_RING)
				bad += 1
			}
			clear(&order)
			base.log_each(proc(u: rawptr, e: ^base.Log_Entry) {
				append(cast(^[dynamic]string)u, strings.clone(string(e.text[:e.len]), context.temp_allocator))
			}, &order)
			want_first := fmt.tprintf("line-%d", base.LOG_RING + 50 - base.LOG_RING) // 50
			if len(order) == 0 || order[0] != want_first {
				fmt.printfln("  FAIL after wrap oldest=%q want %q", len(order) > 0 ? order[0] : "", want_first)
				bad += 1
			}
			// The hook must survive establishing a context from a contextless
			// callback. Checked by identity, not by triggering a real assert: a
			// genuine panic ends the process, and the thing that was broken is the
			// pointer, so the pointer is what to assert on.
			ctx := diag_context()
			hook_ok := ctx.assertion_failure_proc == diag_assert_fail
			fmt.printfln("  %-6s diag_context keeps the crash-reporter assertion hook", "ok" if hook_ok else "FAIL")
			if !hook_ok {bad += 1}
			fmt.printfln("logtest: %d failures", bad)
			return true
		}

		// `newtpad crashtest <null|panic|assert|oob>` deliberately triggers a fault to
		// exercise the whole crash path end to end: the handler must write a .dmp and a
		// .txt to the crashes dir and save the session, WITHOUT a blocking dialog. The
		// process then dies with the fault -- the harness checks the files exist and the
		// exit code is non-zero. Set NEWTPAD_SESSION_DIR to a temp dir first.
		if os.args[1] == "crashtest" {
			kind := os.args[2] if len(os.args) > 2 else "panic"
			plat.crash_set_silent(true) // no message box in a headless run
			diag_init()
			context = diag_context()
			base.log_info("crashtest about to trigger %q", kind)
			base.log_info("breadcrumb: pretend the user opened a file and typed")
			switch kind {
			case "null":
				p := cast(^int)(uintptr(0))
				p^ = 42 // access violation -> SEH filter
			case "oob":
				s := make([]int, 2)
				i := len(os.args) + 5 // opaque index so it isn't folded out
				s[i] = 1 // bounds check -> assertion proc -> trap -> SEH filter
			case "assert":
				assert(1 + len(os.args) < 0, "crashtest forced assert")
			case:
				panic("crashtest forced panic")
			}
			fmt.println("crashtest: did not crash (BUG)") // should be unreachable
			return true
		}

		// `newtpad tabreordertest` covers the reorder bookkeeping: after dragging a tab
		// across the strip the document order changes but the same document stays
		// active and the MRU still points at it (active/mru are slot indices, so a swap
		// that forgot to remap them would silently activate the wrong tab).
		if os.args[1] == "tabreordertest" {
			bad := 0
			app: App
			ds: [4]^Document
			for i in 0 ..< 4 {
				d := new(Document)
				d^ = doc_new()
				ds[i] = d
				app_add(&app, d)
			}
			app_activate(&app, 1) // ds[1] active
			active_doc := app.docs[app.active]

			// Drag ds[0] to the far right via the same swaps tabs_drag_update makes.
			app_swap_tabs(&app, 0, 1)
			app_swap_tabs(&app, 1, 2)
			app_swap_tabs(&app, 2, 3)
			order_ok := app.docs[0] == ds[1] && app.docs[1] == ds[2] && app.docs[2] == ds[3] && app.docs[3] == ds[0]
			active_ok := app.docs[app.active] == active_doc
			mru_ok := len(app.mru) > 0 && app.mru[0] == app.active
			fmt.printfln("  drag first tab to end: order=%v active-follows=%v mru=%v %s", order_ok, active_ok, mru_ok, "OK" if (order_ok && active_ok && mru_ok) else "FAIL")
			if !(order_ok && active_ok && mru_ok) {bad += 1}

			// Now drive the mouse-x -> target mapping through tabs_drag_update itself.
			app.tab_drag_slot = 3 // ds[0], currently last
			w: plat.Window
			w.mouse_y = 5
			w.mouse_x = 0 // far left -> target display index 0
			tabs_drag_update(&app, &w)
			front_ok := app.docs[0] == ds[0] // ds[0] bubbled back to the front
			fmt.printfln("  drag last tab to front: %v %s", front_ok, "OK" if front_ok else "FAIL")
			if !front_ok {bad += 1}

			app_destroy(&app)
			fmt.printfln("tabreordertest: %d failures", bad)
			return true
		}

		// `newtpad savestreamtest` proves the streamed save (rune-aligned chunks) is
		// byte-identical to the reference whole-buffer encoder across the 1 MB chunk
		// boundary, for every encoding — the risk being a multibyte rune split at a
		// chunk edge or a per-chunk BOM.
		if os.args[1] == "savestreamtest" {
			bad := 0
			dir := os.get_env("TEMP", context.temp_allocator)
			// > SAVE_CHUNK (1 MB) of mixed ASCII + 3-byte runes, so runes straddle the
			// chunk boundary at ~1 MB.
			body := make([dynamic]u8, 0, (1 << 20) + 60000)
			for len(body) < (1 << 20) + 40000 {append(&body, ..transmute([]u8)string("abc中def漢"))}
			content := body[:]
			Case :: struct {
				e:    base.Encoding,
				bom:  bool,
				name: string,
			}
			for c in ([]Case{{.UTF8, false, "utf8"}, {.UTF8, true, "utf8bom"}, {.UTF16LE, true, "utf16le"}, {.UTF16BE, true, "utf16be"}, {.CP1252, false, "cp1252"}}) {
				dup := make([]u8, len(content)) // doc_from_content takes ownership
				copy(dup, content)
				doc := doc_from_content(dup, "", c.e)
				doc.had_bom = c.bom
				path := fmt.tprintf("%s\\npstream_%s.bin", dir, c.name)
				err := doc_save_err(&doc, path)
				ref := base.encode_from_utf8(content, c.e, c.bom, context.temp_allocator)
				on_disk, _ := os.read_entire_file(path, context.temp_allocator)
				ok := err == .None && string(on_disk) == string(ref)
				fmt.printfln("  %-8s streamed=%d ref=%d match=%v %s", c.name, len(on_disk), len(ref), string(on_disk) == string(ref), "OK" if ok else "FAIL")
				if !ok {bad += 1}
				doc_close(&doc)
				os.remove(path)
			}
			fmt.printfln("savestreamtest: %d failures", bad)
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

		// `newtpad longpathtest` — the \\?\ extended-length prefix, in two halves.
		//
		// Half one is `plat.long_path_form`'s rule table as pure string assertions.
		// It is a pure function precisely so this half needs no filesystem, and the
		// rules are not arbitrary: \\?\ turns path normalization OFF, so a blanket
		// prefix is worse than the 260-character bug it fixes. Every row here is a
		// way the naive version breaks something that works today.
		//
		// Half two is one real round-trip through a directory nest under %TEMP%
		// longer than MAX_PATH: mkdir, save through the atomic-write path, stat,
		// reopen, re-save (the ReplaceFileW branch), delete. That half is what
		// proves the feature rather than the arithmetic — sabotaging
		// long_path_form to `return path` makes it fail with real Win32 errors.
		if os.args[1] == "longpathtest" {
			// Every non-vacuous case needs a path *longer* than the threshold, or
			// "unchanged" proves nothing: a short absolute path is left alone too.
			// `prefix` plus enough directory segments to clear `n` characters, then
			// a file name — so the result never ends in a separator and the
			// expected canonical form is a plain concatenation.
			pad :: proc(prefix: string, n: int) -> string {
				b := strings.builder_make(context.temp_allocator)
				strings.write_string(&b, prefix)
				for strings.builder_len(b) < n {strings.write_string(&b, `abcdefgh\`)}
				strings.write_string(&b, "f.txt")
				return strings.to_string(b)
			}
			chk :: proc(bad: ^int, label, got, want: string) {
				ok := got == want
				if !ok {bad^ += 1}
				fmt.printfln("  %-34s %s", label, "OK" if ok else "FAIL")
				if !ok {
					fmt.printfln("      got  %q", got)
					fmt.printfln("      want %q", want)
				}
			}

			long_path_rules :: proc(chk: proc(bad: ^int, label, got, want: string), pad: proc(prefix: string, n: int) -> string) -> int {
				bad := 0
				L :: plat.LONG_PATH_THRESHOLD
				fmt.println("--- long_path_form: the rule table ---")

				// Relative: \\?\ is invalid on one, so it is returned untouched.
				// The long case is the one that matters — a short relative path
				// would be left alone for the length reason alone.
				chk(&bad, "short relative", plat.long_path_form(`sub\f.txt`), `sub\f.txt`)
				rel := pad(`sub\`, 300)
				chk(&bad, "long relative", plat.long_path_form(rel), rel)
				// Drive-relative ("C:f.txt") and rooted-without-volume ("\f.txt")
				// are both relative for this purpose: neither names a volume, so
				// neither can carry the prefix.
				dr := pad("C:", 300)
				chk(&bad, "long drive-relative C:x", plat.long_path_form(dr), dr)
				rooted := pad(`\`, 300)
				chk(&bad, "long rooted, no volume", plat.long_path_form(rooted), rooted)

				// Short absolute: no need, and keeping it plain keeps ordinary
				// paths readable in a debugger and in an error dialog.
				chk(&bad, "short absolute", plat.long_path_form(`C:\a\b.txt`), `C:\a\b.txt`)

				// The threshold boundary, both sides. One under is left alone, one
				// at it is prefixed; without both, an off-by-one is invisible.
				under := fmt.tprintf(`C:\%s`, strings.repeat("a", L - 4, context.temp_allocator))
				at := fmt.tprintf(`C:\%s`, strings.repeat("a", L - 3, context.temp_allocator))
				chk(&bad, "one under the threshold", plat.long_path_form(under), under)
				chk(&bad, "exactly at the threshold", plat.long_path_form(at), fmt.tprintf(`\\?\%s`, at))

				// The point of the task.
				lng := pad(`C:\`, 300)
				chk(&bad, "long absolute", plat.long_path_form(lng), fmt.tprintf(`\\?\%s`, lng))

				// \\?\ does not treat '/' as a separator, so slashes must be
				// converted before the prefix goes on. Same path as the row above,
				// spelled with '/' — so the expected output is identical.
				fwd, _ := strings.replace_all(lng, `\`, "/", context.temp_allocator)
				chk(&bad, "forward slashes converted", plat.long_path_form(fwd), fmt.tprintf(`\\?\%s`, lng))

				// ...and it does not resolve '.' or '..' either. Canonicalizing
				// AFTER prefixing would be too late; this is the ordering trap the
				// whole helper is arranged around.
				dots := fmt.tprintf(`C:\a\b\..\.\c\%s`, strings.repeat(`x\`, 130, context.temp_allocator))
				want_dots := fmt.tprintf(`\\?\C:\a\c\%s`, strings.repeat(`x\`, 130, context.temp_allocator))
				want_dots = want_dots[:len(want_dots) - 1] // trailing separator collapses away
				chk(&bad, "dot and dotdot resolved first", plat.long_path_form(dots), want_dots)

				// '..' may not climb out of the volume root; Win32's own
				// normalizer treats C:\..\x as C:\x rather than as an error.
				esc := fmt.tprintf(`C:\..\..\a\%s`, strings.repeat(`y\`, 140, context.temp_allocator))
				want_esc := fmt.tprintf(`\\?\C:\a\%s`, strings.repeat(`y\`, 140, context.temp_allocator))
				want_esc = want_esc[:len(want_esc) - 1]
				chk(&bad, "dotdot cannot escape the root", plat.long_path_form(esc), want_esc)

				// UNC takes a different shape entirely: \\?\UNC\server\share, not
				// \\?\\\server\share.
				unc := pad(`\\server\share\`, 300)
				chk(&bad, "UNC becomes \\\\?\\UNC", plat.long_path_form(unc), fmt.tprintf(`\\?\UNC%s`, unc[1:]))
				// `is_sep` accepts '/' in the lead-in too, so `//server/share/...`
				// is a UNC path as far as this helper is concerned — and it must
				// land on the same output as the backslash spelling, not on
				// `\\?\/server/share`. Nothing in Newtpad produces this shape, but
				// a path pasted from a URL or a shell script does.
				unc_fwd, _ := strings.replace_all(unc, `\`, "/", context.temp_allocator)
				chk(&bad, "UNC with forward slashes", plat.long_path_form(unc_fwd), fmt.tprintf(`\\?\UNC%s`, unc[1:]))
				// ...and its server and share are root, not components a '..' pops.
				unc_esc := fmt.tprintf(`\\srv\share\..\..\a\%s`, strings.repeat(`z\`, 140, context.temp_allocator))
				want_unc := fmt.tprintf(`\\?\UNC\srv\share\a\%s`, strings.repeat(`z\`, 140, context.temp_allocator))
				want_unc = want_unc[:len(want_unc) - 1]
				chk(&bad, "dotdot cannot eat the share", plat.long_path_form(unc_esc), want_unc)

				// Idempotent. Checked by pointer identity, not by content: the
				// requirement is that an already-prefixed path is *returned*, not
				// rebuilt into something that merely compares equal. The
				// round-trip's cleanup below depends on this holding even when the
				// rest of the function is sabotaged.
				pre := fmt.tprintf(`\\?\%s`, pad(`C:\`, 300))
				again := plat.long_path_form(pre)
				same := raw_data(again) == raw_data(pre)
				fmt.printfln("  %-34s %s", "already prefixed, returned as-is", "OK" if same else "FAIL")
				if !same {bad += 1}

				return bad
			}

			long_path_roundtrip :: proc() -> int {
				bad := 0
				fmt.println("--- the round trip: a real file past MAX_PATH ---")
				tmp := os.get_env("TEMP", context.temp_allocator)
				if tmp == "" {
					fmt.println("  no %TEMP% in the environment FAIL")
					return 1
				}

				// A nest whose full path clears 260 by a comfortable margin, built
				// from 40-character segments so the count is small and each mkdir
				// is individually legal.
				seg := "nplp_0123456789012345678901234567890123"
				dirs := make([dynamic]string, 0, 16, context.temp_allocator)
				cur := fmt.tprintf(`%s\nplp_root`, tmp)
				append(&dirs, cur)
				for len(cur) < 280 {
					cur = fmt.tprintf(`%s\%s`, cur, seg)
					append(&dirs, cur)
				}
				deep := cur
				file := fmt.tprintf(`%s\long.txt`, deep)
				fmt.printfln("  nest depth %d, deepest directory %d chars, file %d chars", len(dirs), len(deep), len(file))
				if len(file) <= 260 {
					fmt.println("  the fixture does not actually exceed MAX_PATH FAIL")
					return 1
				}

				// Cleanup prefixes by hand instead of going through
				// long_path_form. The sabotage run for this test disables that
				// function, and a cleanup sharing the mechanism under test would
				// leave a 300-character directory tree behind on exactly the run
				// that failed — which is the one nobody wants to unpick by hand.
				// plat.file_delete / dir_remove still route through wide_path, but
				// the idempotency rule (asserted above) passes an already-prefixed
				// path straight through, sabotage or not.
				ext :: proc(p: string) -> string {return fmt.tprintf(`\\?\%s`, p)}
				defer {
					plat.file_delete(ext(file))
					plat.file_delete(ext(fmt.tprintf("%s.newtpad~", file)))
					plat.file_delete(ext(fmt.tprintf(`%s\replace_a.txt`, deep)))
					plat.file_delete(ext(fmt.tprintf(`%s\replace_b.txt`, deep)))
					#reverse for d in dirs {plat.dir_remove(ext(d))}
					left, _ := plat.path_exists(ext(dirs[0]))
					fmt.printfln("  cleaned up, anything left behind: %v %s", left, "FAIL" if left else "OK")
				}

				ERROR_ALREADY_EXISTS :: 183
				made := 0
				for d in dirs {
					if plat.dir_create(d) || plat.last_error() == ERROR_ALREADY_EXISTS {
						made += 1
						continue
					}
					fmt.printfln("  mkdir failed at depth %d (%d chars), win32 error %d FAIL", made, len(d), plat.last_error())
					bad += 1
					break
				}
				if made == len(dirs) {
					fmt.printfln("  created %d directories, deepest %d chars OK", made, len(deep))
				}

				// The save goes through doc_save_err -> atomic_write_begin/commit,
				// i.e. temp file + rename, never a held handle on the target. That
				// is how "never lock the user's file" is honoured and this path
				// must not stop honouring it because the name got long.
				body := "long path, first write\n"
				dup := make([]u8, len(body)) // doc_from_content takes ownership
				copy(dup, transmute([]u8)body)
				doc := doc_from_content(dup, "", .UTF8)
				werr := doc_save_err(&doc, file)
				doc_close(&doc)
				fmt.printfln("  atomic save err=%v %s", werr, "OK" if werr == .None else "FAIL")
				if werr != .None {bad += 1}

				st := plat.file_stamp(file)
				stat_ok := st.ok && st.size == i64(len(body))
				fmt.printfln("  stat ok=%v size=%d (want %d) %s", st.ok, st.size, len(body), "OK" if stat_ok else "FAIL")
				if !stat_ok {bad += 1}

				reopened, ropen := doc_open(file)
				read_ok := ropen && reopened.pt.length == len(body)
				fmt.printfln("  reopen ok=%v bytes=%d (want %d) %s", ropen, reopened.pt.length if ropen else -1, len(body), "OK" if read_ok else "FAIL")
				if !read_ok {bad += 1}
				if ropen {doc_close(&reopened)}

				// A second save over an existing target takes the ReplaceFileW
				// branch, which preserves the original's ACLs and alternate data
				// streams. It falls back to MoveFileExW on failure, so a green
				// save here would not prove ReplaceFileW accepted the prefix —
				// hence the direct probe below.
				body2 := "long path, second write, longer\n"
				dup2 := make([]u8, len(body2))
				copy(dup2, transmute([]u8)body2)
				doc2 := doc_from_content(dup2, "", .UTF8)
				werr2 := doc_save_err(&doc2, file)
				doc_close(&doc2)
				st2 := plat.file_stamp(file)
				resave_ok := werr2 == .None && st2.ok && st2.size == i64(len(body2))
				fmt.printfln("  re-save err=%v size=%d (want %d) %s", werr2, st2.size, len(body2), "OK" if resave_ok else "FAIL")
				if !resave_ok {bad += 1}

				// The canonicalization rules, against the filesystem rather than
				// against an expected string: the same file named with forward
				// slashes and a "..\seg" detour. \\?\ resolves neither, so a
				// helper that prefixed before canonicalizing would hand Win32 a
				// literal directory named ".." and this stat would fail.
				detour := fmt.tprintf(`%s/../%s/long.txt`, deep, seg)
				dst := plat.file_stamp(detour)
				detour_ok := dst.ok && dst.size == i64(len(body2))
				fmt.printfln("  stat via '/' and '..' ok=%v size=%d (want %d) %s", dst.ok, dst.size, len(body2), "OK" if detour_ok else "FAIL")
				if !detour_ok {bad += 1}

				// Direct: does ReplaceFileW itself accept an extended-length path?
				// If this ever prints false, every long-path save silently loses
				// the target's ACLs and Zone.Identifier to the MoveFileExW
				// fallback, which is worth knowing before a user finds out.
				ra := fmt.tprintf(`%s\replace_a.txt`, deep)
				rb := fmt.tprintf(`%s\replace_b.txt`, deep)
				pa := plat.file_write_atomic(ra, transmute([]u8)string("a"))
				pb := plat.file_write_atomic(rb, transmute([]u8)string("bb"))
				replaced := pa && pb && plat.file_replace(ra, rb)
				fmt.printfln("  ReplaceFileW accepts \\\\?\\: %v %s", replaced, "OK" if replaced else "FAIL (saves fall back to MoveFileEx)")
				if !replaced {bad += 1}

				del := plat.file_delete(file)
				still_there, _ := plat.path_exists(file)
				del_ok := del && !still_there
				fmt.printfln("  delete ok=%v, still present=%v %s", del, still_there, "OK" if del_ok else "FAIL")
				if !del_ok {bad += 1}

				return bad
			}

			// Half three: the two boundaries that are *not* 260. Both are invisible
			// to the round trip above, which sits at 283/292 characters where
			// everything in sight is prefixed and every limit is long behind it.
			//
			//  - **248, the directory cap.** Win32 reserves twelve characters inside
			//    a directory for an 8.3 name it may have to generate there, so a
			//    plain CreateDirectoryW refuses at 248 while a plain CreateFileW is
			//    content to 259. That asymmetry, not any margin against MAX_PATH, is
			//    why LONG_PATH_THRESHOLD is 248; raising it breaks mkdir for the
			//    lengths 248-258 while every file operation keeps working.
			//
			//  - **239-247, where a save's two paths disagree.** The target is under
			//    the threshold and its ".newtpad~" temp is over it, so
			//    atomic_write_commit hands ReplaceFileW a *plain* destination and a
			//    `\\?\` source. Win32 resolves the two arguments independently and
			//    it works — but nothing said so until this fixture, and if it were
			//    ever untrue, every save of a file whose name lands in that
			//    nine-character window would fall through to MoveFileExW and quietly
			//    drop the target's ACLs and Zone.Identifier. That is the precise loss
			//    the direct ReplaceFileW probe was added to rule out, so ruling it
			//    out at 292 characters only is ruling it out where it cannot happen.
			long_path_boundary :: proc() -> int {
				bad := 0
				fmt.println("--- the 248 and 239-247 boundaries ---")
				tmp := os.get_env("TEMP", context.temp_allocator)
				if tmp == "" {
					fmt.println("  no %TEMP% in the environment FAIL")
					return 1
				}
				// Cleanup prefixes by hand, for the same reason the round trip does:
				// the sabotage runs disable long_path_form, and a cleanup sharing the
				// mechanism under test leaves the mess behind on exactly the run that
				// failed.
				ext :: proc(p: string) -> string {return fmt.tprintf(`\\?\%s`, p)}
				// One component of exactly the length needed, so the parent is always
				// short and the only variable in the call is the length of the string
				// handed to CreateDirectoryW.
				fill :: proc(parent: string, total: int, c: string) -> string {
					n := total - len(parent) - 1
					if n < 1 || n > 255 {return ""}
					return fmt.tprintf(`%s\%s`, parent, strings.repeat(c, n, context.temp_allocator))
				}

				// 248 written out, deliberately **not** plat.LONG_PATH_THRESHOLD:
				// this is a fact about Win32, not about our constant. Deriving the
				// fixture from the constant would move the fixture with it and the
				// row would stay green through exactly the change it exists to
				// catch — verified, that is what the first version of it did.
				DIR_MAX_PLAIN :: 248
				// Mid-window, so a character of drift either way keeps the target
				// plain and its 252-character temp prefixed. Both ends are asserted
				// below anyway.
				MIXED_TARGET :: 243
				root := fmt.tprintf(`%s\nplp_bound`, tmp)
				d248 := fill(root, DIR_MAX_PLAIN, "d")
				save := fill(root, MIXED_TARGET, "s") // the real save target
				save_tmp := fmt.tprintf("%s.newtpad~", save)
				pa := fill(root, MIXED_TARGET, "a") // the direct-probe pair
				pb := fmt.tprintf("%s.newtpad~", pa)
				if len(d248) != DIR_MAX_PLAIN || len(save) != MIXED_TARGET {
					fmt.printfln("  fixture arithmetic failed: root is %d chars FAIL", len(root))
					return 1
				}

				defer {
					plat.file_delete(ext(save))
					plat.file_delete(ext(save_tmp))
					plat.file_delete(ext(pa))
					plat.file_delete(ext(pb))
					plat.dir_remove(ext(d248))
					plat.dir_remove(ext(root))
					left, _ := plat.path_exists(ext(root))
					fmt.printfln("  cleaned up, anything left behind: %v %s", left, "FAIL" if left else "OK")
				}

				ERROR_ALREADY_EXISTS :: 183
				if !plat.dir_create(root) && plat.last_error() != ERROR_ALREADY_EXISTS {
					fmt.printfln("  could not create the %d-char root, win32 error %d FAIL", len(root), plat.last_error())
					return 1
				}

				// The row. Plain, this call fails with ERROR_FILENAME_EXCED_RANGE
				// (206), so it passes only because the prefix went on — and it goes
				// red the moment the threshold is raised above 248.
				dok := plat.dir_create(d248)
				derr := plat.last_error()
				if !dok && derr == ERROR_ALREADY_EXISTS {dok = true}
				if dok {
					fmt.printfln("  dir_create at exactly %d chars OK", len(d248))
				} else {
					fmt.printfln("  dir_create at exactly %d chars failed, win32 error %d FAIL", len(d248), derr)
					bad += 1
				}

				// The pair really is mixed. Asserted, not assumed: a threshold change
				// or a longer %TEMP% would otherwise leave everything below green
				// while testing two prefixed paths, which the round trip already
				// covers.
				dst_plain := plat.long_path_form(save) == save
				tmp_pref := plat.long_path_form(save_tmp) != save_tmp
				mixed := dst_plain && tmp_pref
				fmt.printfln(
					"  target %d chars plain=%v, temp %d chars prefixed=%v %s",
					len(save),
					dst_plain,
					len(save_tmp),
					tmp_pref,
					"OK" if mixed else "FAIL (the fixture is no longer a mixed pair)",
				)
				if !mixed {bad += 1}

				// A real save through doc_save_err, twice: the first creates the
				// target (no destination yet, so the rename), the second replaces it.
				body := "boundary save, first write\n"
				dup := make([]u8, len(body))
				copy(dup, transmute([]u8)body)
				doc := doc_from_content(dup, "", .UTF8)
				werr := doc_save_err(&doc, save)
				doc_close(&doc)
				st1 := plat.file_stamp(save)
				create_ok := werr == .None && st1.ok && st1.size == i64(len(body))
				fmt.printfln("  create-save err=%v size=%d (want %d) %s", werr, st1.size, len(body), "OK" if create_ok else "FAIL")
				if !create_ok {bad += 1}

				body2 := "boundary save, second write, over an existing target\n"
				dup2 := make([]u8, len(body2))
				copy(dup2, transmute([]u8)body2)
				doc2 := doc_from_content(dup2, "", .UTF8)
				werr2 := doc_save_err(&doc2, save)
				doc_close(&doc2)
				st2 := plat.file_stamp(save)
				resave_ok := werr2 == .None && st2.ok && st2.size == i64(len(body2))
				fmt.printfln("  replace-save err=%v size=%d (want %d) %s", werr2, st2.size, len(body2), "OK" if resave_ok else "FAIL")
				if !resave_ok {bad += 1}

				// ...and *which branch* that second save took, because a green save
				// proves nothing on its own: the MoveFileExW fallback also returns
				// .None, and does it while discarding the ACLs. atomic_write_commit
				// takes ReplaceFileW exactly when GetFileAttributesW sees the plain
				// destination and file_replace then succeeds, so both halves are
				// checked here against real Win32, at the real lengths, with a pair
				// built the same way the save builds its own.
				wa := plat.file_write_atomic(pa, transmute([]u8)string("a"))
				wb := plat.file_write_atomic(pb, transmute([]u8)string("bb"))
				replaced := wa && wb && plat.file_replace(pa, pb)
				branch := st2.ok && replaced
				fmt.printfln(
					"  replace-save took ReplaceFileW: dst visible=%v, ReplaceFileW(plain, \\\\?\\)=%v %s",
					st2.ok,
					replaced,
					"OK" if branch else "FAIL (every save in the 239-247 window falls back to MoveFileEx)",
				)
				if !branch {bad += 1}

				return bad
			}

			bad := long_path_rules(chk, pad)
			bad += long_path_roundtrip()
			bad += long_path_boundary()
			fmt.printfln("longpathtest: %d failures", bad)
			return true
		}

		// See draw_count_mode. Matched on the mode name ALONE, not on
		// `&& len(os.args) > 2`: with that guard a bare `newtpad drawcount` fell
		// through to argv's "open this path" handling and opened the real GUI
		// window on a file called "drawcount", which is half of the trap
		// development-loop.md §6 records. Every file-argument mode has this shape;
		// this one now refuses instead.
		if os.args[1] == "drawcount" {
			if len(os.args) < 3 {
				fmt.eprintln("usage: newtpad drawcount <file>")
				return true
			}
			if !require_scratch_session("drawcount") {return true}
			draw_count_mode(os.args[2])
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
		// `newtpad blurtest` verifies the grayscale glyph path rasterizes real
		// coverage at small and large (zoom) sizes. It can't judge how the pixels
		// look -- that needs a live eye -- but it catches a broken coverage path.
		if os.args[1] == "blurtest" {
			t: plat.Text
			plat.text_load_faces(&t)
			bad := 0
			if plat.text_shaders_compile_ok() {
				fmt.println("  text shaders compile: OK")
			} else {
				fmt.println("  FAIL: text shaders do not compile")
				bad += 1
			}
			for c in ([]struct{r: rune, px: f32}{{'A', 16}, {'g', 16}, {'5', 16}, {'中', 24}, {'W', 200}}) {
				w, h, inked := plat.text_glyph_coverage_probe(&t, c.r, c.px)
				ok := w > 0 && h > 0 && inked
				fmt.printfln("  %q @ %.0fpx -> %dx%d inked=%v %s", c.r, c.px, w, h, inked, "OK" if ok else "FAIL")
				if !ok {bad += 1}
			}
			fmt.printfln("blurtest: %d failures", bad)
			return true
		}

		if os.args[1] == "celltest" {
			t: plat.Text
			if !plat.text_load_faces(&t) {
				fmt.eprintln("celltest: no fonts loaded")
				return true
			}
			samples := "aé中がx́\t" // ascii, 2-byte latin, CJK x2, kana, ascii, combining acute, tab
			// A DUMP, not an assertion -- celltest has no failure count and never
			// had one. The old form printed the advance at column 0 against
			// text_tab_width and read like a check, but those two are equal at
			// column 0 under fixed-width tabs and under true tab stops alike, so
			// it could not fail. The advance across a full period is at least
			// legible to an eye; the assertions live in tabstoptest.
			fmt.printf("tab advance by column (width %d, and it must draw no glyph): ", plat.text_tab_width(&t))
			for c in 0 ..< 2 * plat.text_tab_width(&t) {fmt.printf("%d:%d ", c, plat.text_cell_width_at(&t, '\t', c))}
			fmt.println()
			fmt.printf("cells: ")
			// A running column, not 0 per rune: this walks `samples` from its
			// start, so each rune's real column is available, and the per-rune
			// widths printed here must sum to the text_cells total printed on
			// the next line.
			scol := 0
			for r in samples {
				w := plat.text_cell_width_at(&t, r, scol)
				fmt.printf("%q=%d ", r, w)
				scol += w
			}
			bytes := transmute([]u8)samples
			// col0 = 0 throughout: `samples` is a standalone string measured from
			// its own start, which is also the origin the per-rune walk above used.
			fmt.printfln(" | total=%d cells over %d bytes", plat.text_cells(&t, bytes, 0), len(bytes))
			// inverse: the byte offset at each cell column should round-trip.
			total := plat.text_cells(&t, bytes, 0)
			fmt.printf("col->byte: ")
			for c in 0 ..= total {fmt.printf("%d:%d ", c, plat.text_bytes_for_cells(&t, bytes, c, 0))}
			fmt.println()
			return true
		}

		// `newtpad tabstoptest` proves a tab is an ADVANCE TO THE NEXT STOP, not
		// a fixed width. The one property worth asserting is that THE SAME RUNE
		// MEASURES DIFFERENTLY AT DIFFERENT COLUMNS -- a check that only ever
		// measures a tab at column 0 returns 4 under fixed-width tabs and under
		// true tab stops alike, so it cannot fail and proves nothing. That is
		// not a hypothetical: every tab in every fixture of the other ten
		// headless suites is a LEADING tab, which is why sabotaging the tab
		// branch to real tab stops moved only two lines of `celltest` and left
		// the other nine suites byte-identical (measured twice, independently,
		// during batch 7 task 1).
		//
		// So the cases below come in pairs wherever possible: a column where the
		// two behaviours agree (0, 4, 8) to pin the wrap-around, and a column
		// where they cannot (1, 2, 3, 5) to make the check fail if the advance
		// ever goes back to being constant.
		if os.args[1] == "tabstoptest" {
			bad := 0
			fmt.println("tabstoptest:")

			chk :: proc(label: string, got, want: int, bad: ^int) {
				ok := got == want
				fmt.printfln("  %-6s %-72s got=%d want=%d", "ok" if ok else "FAIL", label, got, want)
				if !ok {bad^ += 1}
			}

			// --- the advance itself -------------------------------------------
			tab_test_advance :: proc(chk: proc(string, int, int, ^int), bad: ^int) {
				t: plat.Text
				if !plat.text_load_faces(&t) {
					fmt.eprintln("  FAIL tabstoptest: no fonts loaded")
					bad^ += 1
					return
				}
				fmt.println("--- the advance, tab_width=4 ---")
				chk("text_tab_width after text_load_faces", plat.text_tab_width(&t), 4, bad)
				// 0 and 4 are 4 under BOTH behaviours; 1/2/3/5/6/7 cannot be.
				chk("'\\t' at col 0", plat.text_cell_width_at(&t, '\t', 0, .Doc), 4, bad)
				chk("'\\t' at col 1", plat.text_cell_width_at(&t, '\t', 1, .Doc), 3, bad)
				chk("'\\t' at col 2", plat.text_cell_width_at(&t, '\t', 2, .Doc), 2, bad)
				chk("'\\t' at col 3", plat.text_cell_width_at(&t, '\t', 3, .Doc), 1, bad)
				chk("'\\t' at col 4 (wraps back to a full stop)", plat.text_cell_width_at(&t, '\t', 4, .Doc), 4, bad)
				chk("'\\t' at col 5", plat.text_cell_width_at(&t, '\t', 5, .Doc), 3, bad)
				chk("'\\t' at col 7", plat.text_cell_width_at(&t, '\t', 7, .Doc), 1, bad)
				chk("'\\t' at col 8", plat.text_cell_width_at(&t, '\t', 8, .Doc), 4, bad)
				// The advance is never 0 at any column -- a 0 is not a wrong
				// number on screen, it is a non-terminating measuring loop.
				min_adv := max(int)
				for c in 0 ..< 64 {min_adv = min(min_adv, plat.text_cell_width_at(&t, '\t', c, .Doc))}
				chk("smallest advance over columns 0..63 (0 would hang the walks)", min_adv, 1, bad)
				// The tab must never be served from cell_cache, which is keyed by
				// rune alone: measure at 0 FIRST, then at 2. If the early return
				// ever moves below the cache lookup, the second call returns the
				// cached 4 and this fails.
				_ = plat.text_cell_width_at(&t, '\t', 0, .Doc)
				chk("'\\t' at col 2 after one at col 0 (cell_cache must not serve tabs)", plat.text_cell_width_at(&t, '\t', 2, .Doc), 2, bad)
			}
			tab_test_advance(chk, &bad)

			// --- the three wrappers actually thread col0 ----------------------
			// This is the item that task 1's sweep stopped one level short of:
			// text_cells / text_bytes_for_cells / text_span_cells each hardcoded
			// an origin of 0 internally, so a mid-row fragment measured its tabs
			// from the wrong place even though every DIRECT caller of
			// text_cell_width_at was correct.
			tab_test_wrappers :: proc(chk: proc(string, int, int, ^int), bad: ^int) {
				t: plat.Text
				if !plat.text_load_faces(&t) {
					fmt.eprintln("  FAIL tabstoptest: no fonts loaded")
					bad^ += 1
					return
				}
				s := "ab\tcd"
				fmt.println("--- text_cells ---")
				// "a\tb" is 1 + 3 + 1 = 5 under tab stops and 1 + 4 + 1 = 6 under
				// a fixed four, so it discriminates -- the batch-7 plan says this
				// case "cannot fail", and that is arithmetic the plan got wrong.
				chk(`text_cells "a\tb" @0`, plat.text_cells(&t, transmute([]u8)string("a\tb"), 0, .Doc), 5, bad)
				chk(`text_cells "ab\tc" @0`, plat.text_cells(&t, transmute([]u8)string("ab\tc"), 0, .Doc), 5, bad)
				chk(`text_cells "abc\td" @0`, plat.text_cells(&t, transmute([]u8)string("abc\td"), 0, .Doc), 5, bad)
				chk(`text_cells "abcd\te" @0 (agrees with fixed-4; pins the wrap)`, plat.text_cells(&t, transmute([]u8)string("abcd\te"), 0, .Doc), 9, bad)
				chk(`text_cells "\t\t" @0`, plat.text_cells(&t, transmute([]u8)string("\t\t"), 0, .Doc), 8, bad)
				// The same slice, four origins, four answers. A wrapper that
				// ignores col0 returns 4 for all of them.
				chk(`text_cells "\t" @0`, plat.text_cells(&t, transmute([]u8)string("\t"), 0, .Doc), 4, bad)
				chk(`text_cells "\t" @1`, plat.text_cells(&t, transmute([]u8)string("\t"), 1, .Doc), 3, bad)
				chk(`text_cells "\t" @2`, plat.text_cells(&t, transmute([]u8)string("\t"), 2, .Doc), 2, bad)
				chk(`text_cells "\t" @3`, plat.text_cells(&t, transmute([]u8)string("\t"), 3, .Doc), 1, bad)
				chk(`text_cells "ab\tcd" @0`, plat.text_cells(&t, transmute([]u8)s, 0, .Doc), 6, bad)
				chk(`text_cells "ab\tcd" @1 (same bytes, different origin)`, plat.text_cells(&t, transmute([]u8)s, 1, .Doc), 5, bad)

				fmt.println("--- text_span_cells ---")
				// "cd" inside "ab\tcd": the tab occupies columns 2-3, so the span
				// starts at column 4. Under a fixed four it would start at 6.
				c0, n0 := plat.text_span_cells(&t, s, 3, 2, 0, .Doc)
				chk(`text_span_cells "ab\tcd" [3,5) @0 -> col`, c0, 4, bad)
				chk(`text_span_cells "ab\tcd" [3,5) @0 -> cells`, n0, 2, bad)
				c1, n1 := plat.text_span_cells(&t, s, 3, 2, 1, .Doc)
				chk(`text_span_cells "ab\tcd" [3,5) @1 -> col (origin threaded)`, c1, 3, bad)
				chk(`text_span_cells "ab\tcd" [3,5) @1 -> cells`, n1, 2, bad)

				fmt.println("--- seam: the three wrappers agree with each other ---")
				// text_span_cells' `col` IS text_cells over the prefix, and
				// text_bytes_for_cells is text_cells' inverse. All three walk the
				// same runes, so all three must see the same column sequence --
				// this is the check that catches a consumer (or a wrapper) that
				// forgot to thread the origin, which a unit test of the advance
				// alone cannot.
				// Counted separately from `bad` so this line reports on ITSELF and
				// not on whatever failed above it -- a summary that reads the
				// shared counter turns green only when the whole mode is green,
				// which makes it useless as a signal about the seam.
				seam_bad := 0
				for col0 in 0 ..< 5 {
					for p in 0 ..= len(s) {
						if p > 0 && p < len(s) && (s[p] & 0xC0) == 0x80 {continue} // rune boundaries only
						pref := plat.text_cells(&t, transmute([]u8)s[:p], col0, .Doc)
						back := plat.text_bytes_for_cells(&t, transmute([]u8)s, pref, col0, .Doc)
						if back != p {
							fmt.printfln("  FAIL   round-trip @col0=%d prefix=%d -> %d cells -> byte %d", col0, p, pref, back)
							seam_bad += 1
						}
						if p < len(s) {
							sc, _ := plat.text_span_cells(&t, s, p, len(s) - p, col0, .Doc)
							if sc != pref {
								fmt.printfln("  FAIL   text_span_cells col=%d disagrees with text_cells prefix=%d @col0=%d", sc, pref, col0)
								seam_bad += 1
							}
						}
					}
				}
				bad^ += seam_bad
				// Known limit, stated so nobody reads more into a green line than
				// is there: this catches a consumer that threads the origin
				// INCONSISTENTLY across the three wrappers. It does NOT catch all
				// three dropping col0 together -- they stay mutually consistent,
				// just wrong -- which is what the "@1 / @2 / @3" value checks
				// above are for.
				fmt.printfln("  %-6s cells<->bytes<->span agree for every prefix of %q at origins 0..4", "ok" if seam_bad == 0 else "FAIL", s)
			}
			tab_test_wrappers(chk, &bad)

			// --- the setting, and its clamp -----------------------------------
			tab_test_width_setting :: proc(chk: proc(string, int, int, ^int), bad: ^int) {
				t: plat.Text
				if !plat.text_load_faces(&t) {
					fmt.eprintln("  FAIL tabstoptest: no fonts loaded")
					bad^ += 1
					return
				}
				fmt.println("--- tab_width is configurable ---")
				plat.text_set_tab_width(&t, 8)
				chk("text_tab_width after set(8)", plat.text_tab_width(&t), 8, bad)
				chk("'\\t' at col 0, width 8", plat.text_cell_width_at(&t, '\t', 0, .Doc), 8, bad)
				chk("'\\t' at col 1, width 8", plat.text_cell_width_at(&t, '\t', 1, .Doc), 7, bad)
				chk(`text_cells "a\tb" @0, width 8`, plat.text_cells(&t, transmute([]u8)string("a\tb"), 0, .Doc), 9, bad)
				plat.text_set_tab_width(&t, 2)
				chk(`text_cells "abc\td" @0, width 2`, plat.text_cells(&t, transmute([]u8)string("abc\td"), 0, .Doc), 5, bad)

				fmt.println("--- the clamp, which is a hang guard and not cosmetic ---")
				// A spacing of 0 makes the advance 0, and every measuring loop in
				// platform and program advances by exactly that -- so an
				// unclamped 0 is a frozen UI, not a layout glitch.
				plat.text_set_tab_width(&t, 0)
				chk("set(0) clamps up to TAB_WIDTH_MIN", plat.text_tab_width(&t), plat.TAB_WIDTH_MIN, bad)
				zero_adv := max(int)
				for c in 0 ..< 16 {zero_adv = min(zero_adv, plat.text_cell_width_at(&t, '\t', c, .Doc))}
				chk("after set(0), the smallest advance is still >= 1", zero_adv, 1, bad)
				// And the loops really do terminate at the clamped width.
				chk(`text_cells "\t\t\t" after set(0)`, plat.text_cells(&t, transmute([]u8)string("\t\t\t"), 0, .Doc), 3, bad)
				plat.text_set_tab_width(&t, -5)
				chk("set(-5) clamps up to TAB_WIDTH_MIN", plat.text_tab_width(&t), plat.TAB_WIDTH_MIN, bad)
				plat.text_set_tab_width(&t, 999)
				chk("set(999) clamps down to TAB_WIDTH_MAX", plat.text_tab_width(&t), plat.TAB_WIDTH_MAX, bad)

				// Zero-is-initialization: a Text that never reached
				// text_load_faces reads tab_width 0 straight out of the struct,
				// and 0 is the one value that hangs. text_tab_width must hand
				// back the default instead of the raw field.
				raw: plat.Text
				chk("a zero-valued Text reports the default width", plat.text_tab_width(&raw), plat.TAB_WIDTH_DEFAULT, bad)
				chk("a zero-valued Text still advances a tab at col 2", plat.text_cell_width_at(&raw, '\t', 2, .Doc), 2, bad)
			}
			tab_test_width_setting(chk, &bad)

			fmt.printfln("tabstoptest: %d failures", bad)
			return true
		}

		// `newtpad blocktest` proves block_row_range is the only place a block
		// rectangle's cells become bytes, and that it never reports a truncated
		// scan as though it were complete. Fixture rows are chosen so byte
		// offsets and cell columns disagree in three different ways: a plain
		// ASCII row, a row whose leading tab makes one byte span four cells, and
		// a row of CJK where one rune is 2 cells and 3 bytes. A rectangle over
		// cells [2, 6) must land on a different byte range on each of them --
		// that divergence IS the feature, and a version of block_row_range that
		// confused cells with bytes would still pass a pure-ASCII fixture.
		if os.args[1] == "blocktest" {
			if !require_scratch_session("blocktest") {return true}
			fail := false
			fmt.println("blocktest:")

			// Guard the REAL Windows clipboard for the WHOLE mode, not per-case.
			// Several cases below (Cut in block_test_t/block_test_u, the Paste
			// round trip in block_test_ai, the sentinel round trip in
			// block_test_an) also save/restore around their own writes, but a
			// previous round proved that per-case discipline alone is not
			// enough: block_test_an wrote the clipboard with no save/restore of
			// its own, and it shipped anyway because nothing checked the MODE as
			// a whole. Saving once here and restoring via `defer` on every exit
			// path -- including the "no fonts loaded" early return just below --
			// means a future case that forgets its own save/restore still can't
			// reach the user; only a bug in this one save/restore can. An empty
			// clipboard, a clipboard holding non-text data (e.g. an image --
			// clipboard_get_text reports ok=false for anything that isn't
			// CF_UNICODETEXT), or a clipboard that can't be opened all come back
			// with had_clip=false: there is nothing understood to restore in
			// that case, so the defer below leaves the clipboard alone rather
			// than blanking it.
			mode_saved_clip, mode_had_clip := plat.clipboard_get_text(nil, context.allocator)
			defer if mode_had_clip {
				plat.clipboard_set_text(nil, mode_saved_clip)
				delete(mode_saved_clip)
			}

			// Stand in for "the user's real clipboard content" with a sentinel of
			// our own, so the seam-proof check at the very end of this mode (see
			// "SEAM PROOF" near the bottom) can tell a clipboard that every case
			// put back from one that some case clobbered and forgot.
			mode_seam_sentinel := "BLOCKTEST MODE SEAM SENTINEL -- must survive every case"
			plat.clipboard_set_text(nil, mode_seam_sentinel)

			t: plat.Text
			if !plat.text_load_faces(&t) {
				fmt.println("  FAIL   no fonts loaded; cannot exercise cell widths")
				fmt.println("blocktest: FAILURES")
				return true
			}

			// TEST SCAFFOLDING ONLY: the byte offset of 0-based line n, by walking
			// this fixture from the start. The PRODUCT has no line-number-to-offset
			// procedure any more -- removing it is the point of this change, because
			// a line number is not a cheap coordinate in this codebase. Fixtures
			// still need a way to say "line 2" when they are four lines long, and
			// paying O(depth) in a test that builds the document itself is fine.
			nth_line_start :: proc(d: ^Document, n: int) -> int {
				p := 0
				for _ in 0 ..< n {
					e := base.pt_line_end_cap(&d.pt, p, d.pt.length + 1)
					if e >= d.pt.length {return d.pt.length}
					p = e + 1
				}
				return p
			}

			src := "abcdefgh\n\tindented\n你好世界 ok\nshort\n"
			doc := doc_from_content(transmute([]u8)strings.clone(src), "", .UTF8)
			defer doc_close(&doc)

			// Row 0 is pure ASCII: cells [2,6) is bytes [2,6).
			ls0 := nth_line_start(&doc, 0)
			b0lo, b0hi, pad0, ok0 := block_row_range(&doc, &t, ls0, 2, 6)
			c0 := ok0 && b0lo == 2 && b0hi == 6 && pad0 == 0
			if !c0 {fail = true}
			fmt.printfln("  %-6s ascii row: bytes [%d,%d) pad=%d ok=%v", "ok" if c0 else "FAIL", b0lo, b0hi, pad0, ok0)

			// Row 1's leading tab is one byte spanning 4 cells (it starts at
			// column 0, so it advances a full tab_width), so cell 2
			// falls INSIDE it. The tab is included whole (a partial glyph has no
			// byte form), pulling byte_lo back to the tab's own start (byte 0) --
			// the rectangle ends up covering cells [0,6) worth of content in only
			// 3 bytes, not the 4 a naive bytes==cells reading would expect.
			ls1 := nth_line_start(&doc, 1)
			b1lo, b1hi, pad1, ok1 := block_row_range(&doc, &t, ls1, 2, 6)
			c1 := ok1 && b1lo == ls1 && b1hi == ls1 + 3 && pad1 == 0
			if !c1 {fail = true}
			fmt.printfln("  %-6s tab row: bytes rel [%d,%d) pad=%d ok=%v", "ok" if c1 else "FAIL", b1lo - ls1, b1hi - ls1, pad1, ok1)

			// The right-edge STRADDLE branch (a rune whose span reaches past
			// cell_hi without starting exactly there) is otherwise never hit by
			// this suite: row 1's own cell_hi=6 lands exactly on 'd', the exact-
			// match branch. Here cell_hi=2 lands INSIDE the leading tab's [0,4)
			// span, so the tab must be pulled in whole from the right edge too --
			// same rule as the left edge, straddle wins over "past the edge".
			b1slo, b1shi, pad1s, ok1s := block_row_range(&doc, &t, ls1, 0, 2)
			c1s := ok1s && b1slo == ls1 && b1shi == ls1 + 1 && pad1s == 0
			if !c1s {fail = true}
			fmt.printfln("  %-6s tab row right-edge straddle: bytes rel [%d,%d) pad=%d ok=%v", "ok" if c1s else "FAIL", b1slo - ls1, b1shi - ls1, pad1s, ok1s)

			// The CJK row: cells [2,6) must NOT be bytes [2,6) -- and must be
			// EXACTLY the right answer, not merely "some other answer". 你(3B)
			// starts cell_lo=2 mid-span (cell+w=2>2 is false, so lo actually
			// lands on 好 at rel byte 3); 界 starts exactly at cell_hi=6, so hi
			// excludes it at rel byte 9. A wrong-but-different byte range would
			// pass the old `!=` assertion; only the exact one catches that.
			ls2 := nth_line_start(&doc, 2)
			b2lo, b2hi, _, ok2 := block_row_range(&doc, &t, ls2, 2, 6)
			c2 := ok2 && b2lo == ls2 + 3 && b2hi == ls2 + 9
			if !c2 {fail = true}
			fmt.printfln("  %-6s cjk row: bytes rel [%d,%d) (want [3,9))", "ok" if c2 else "FAIL", b2lo - ls2, b2hi - ls2)

			// "short" is 5 cells; a rectangle starting at cell 8 selects nothing on
			// it and reports the padding an edit would need. pad is reported, NOT
			// applied -- selection never mutates.
			ls3 := nth_line_start(&doc, 3)
			b3lo, b3hi, pad3, ok3 := block_row_range(&doc, &t, ls3, 8, 10)
			c3 := ok3 && b3lo == b3hi && pad3 == 3
			if !c3 {fail = true}
			fmt.printfln("  %-6s short row selects nothing, pad=%d (want 3)", "ok" if c3 else "FAIL", pad3)

			// A row longer than BLOCK_ROW_CAP can still resolve a rectangle that
			// sits entirely near its start: the walk finds cell_hi long before it
			// would ever need to see past the cap, so this must SUCCEED. Refusing
			// here (the old behaviour) meant every rectangle over a minified-JSON
			// or log line resolved to nothing.
			long := make([]u8, BLOCK_ROW_CAP + 500)
			for i in 0 ..< len(long) {long[i] = 'x'}
			ldoc := doc_from_content(long, "", .UTF8)
			defer doc_close(&ldoc)
			bLlo, bLhi, padL, okL := block_row_range(&ldoc, &t, 0, 2, 6)
			cL := okL && bLlo == 2 && bLhi == 6 && padL == 0
			if !cL {fail = true}
			fmt.printfln("  %-6s low cells on a row past BLOCK_ROW_CAP still resolve: bytes [%d,%d) ok=%v", "ok" if cL else "FAIL", bLlo, bLhi, okL)

			// But a rectangle whose cell_hi genuinely lies past the cap CANNOT be
			// resolved -- the walk runs off the end of the capped scan window
			// without ever finding cell_hi, and row_end might only be a synthetic
			// cap break rather than the row's real end. ok=false is the only
			// honest answer here.
			_, _, _, okL2 := block_row_range(&ldoc, &t, 0, BLOCK_ROW_CAP - 2, BLOCK_ROW_CAP + 50)
			cL2 := !okL2
			if !cL2 {fail = true}
			fmt.printfln("  %-6s cell_hi past BLOCK_ROW_CAP refuses rather than guesses (ok=%v, want false)", "ok" if cL2 else "FAIL", okL2)

			// Regression for the chunk-boundary rune split: block_row_range reads
			// a row through a local 4096-byte buffer, and a multi-byte rune whose
			// bytes straddle that exact boundary must be refilled and decoded
			// whole, never counted as one cell per orphaned byte. 4091 ASCII
			// bytes put 好's continuation bytes across index 4096; asking for
			// cells [4091,4095) must land on 世's start (byte 4097), not wherever
			// the two split halves of 好 happened to add up to.
			splitsrc := strings.concatenate({strings.repeat("x", 4091, context.temp_allocator), "你好世界"}, context.temp_allocator)
			sdoc := doc_from_content(transmute([]u8)strings.clone(splitsrc), "", .UTF8)
			defer doc_close(&sdoc)
			bSlo, bShi, padS, okS := block_row_range(&sdoc, &t, 0, 4091, 4095)
			cS := okS && bSlo == 4091 && bShi == 4097 && padS == 0
			if !cS {fail = true}
			fmt.printfln("  %-6s rune split at the 4096-byte chunk boundary: bytes [%d,%d) ok=%v (want [4091,4097))", "ok" if cS else "FAIL", bSlo, bShi, okS)

			// Regression for byte_lo leaking a foreign row's offset: line 0 is
			// "x\n" (2 bytes), so line 1 starts at byte 2 and opens with a
			// zero-width combining acute (no base rune of its own). Asking for
			// cell 0 (an empty, single-column rectangle) makes hi_found fire on
			// that first, zero-width rune (cell==cell_hi==0) while lo_found never
			// fires (cell+w=0 is never > cell_lo=0) -- exactly the state the
			// zero-width block cursor of a later task reaches. byte_lo must come
			// out as this row's own start, not byte 0 belonging to line 0.
			combining, combining_sz := utf8.encode_rune(rune(0x0301))
			zsrc := strings.concatenate({"x\n", string(combining[:combining_sz]), " abc\n"}, context.temp_allocator)
			zdoc := doc_from_content(transmute([]u8)strings.clone(zsrc), "", .UTF8)
			defer doc_close(&zdoc)
			zls := nth_line_start(&zdoc, 1)
			zlo, zhi, padZ, okZ := block_row_range(&zdoc, &t, zls, 0, 0)
			cZ := okZ && zlo == zls && zhi == zls && padZ == 0
			if !cZ {fail = true}
			fmt.printfln("  %-6s zero-width rune at the column: bytes [%d,%d) rel to line_start=%d (want [0,0))", "ok" if cZ else "FAIL", zlo - zls, zhi - zls, zls)

			// IMPORTANT regression: a row that genuinely ends with an incomplete
			// multi-byte sequence -- a real file with a malformed tail, not a
			// chunk-boundary split -- must still resolve via the rule-5 clamp,
			// not refuse the whole row. "abcd\xE4\xB8" is 6 bytes; \xE4 wants a
			// 3-byte encoding but only one continuation byte follows before the
			// document itself ends. Both bytes must decode as RUNE_ERROR width 1
			// and count as ordinary content -- the same as line_wrap_decision and
			// wrap_row_end already treat them, and the same as the renderer draws
			// them -- so the walk clamps to what it found: [0,6), ok=true. The
			// old code refused the entire row here (ok=false) instead.
			trunc := make([]u8, 6)
			trunc[0], trunc[1], trunc[2], trunc[3] = 'a', 'b', 'c', 'd'
			trunc[4], trunc[5] = 0xE4, 0xB8
			tdoc := doc_from_content(trunc, "", .UTF8)
			defer doc_close(&tdoc)
			tlo, thi, padT, okT := block_row_range(&tdoc, &t, 0, 0, 10)
			cT := okT && tlo == 0 && thi == 6 && padT == 0
			if !cT {fail = true}
			fmt.printfln("  %-6s truncated multi-byte tail at row's real end clamps: bytes [%d,%d) ok=%v (want [0,6) ok=true)", "ok" if cT else "FAIL", tlo, thi, okT)

			// IMPORTANT regression: seeding a rectangle must refuse a caret whose
			// own line start lies past BLOCK_LINE_STEP_CAP WITHOUT first scanning
			// the whole line to find that out. 64 MB, one line, no newline
			// anywhere, caret at the very end: the bounded BACKWARD scan looks at
			// one cap's worth of bytes and gives up. base.pt_line_start scans back
			// with no bound at all and would read all 64 MB before reporting the
			// same failure -- the shape doc.odin:1853 documents, and the reason
			// every seed in this file goes through block_line_start_at.
			huge := make([]u8, 64 * 1024 * 1024)
			mem.set(raw_data(huge), 'x', len(huge))
			hdoc := doc_from_content(huge, "", .UTF8)
			defer doc_close(&hdoc)
			hdoc.wrap = false
			hdoc.cursor = hdoc.pt.length
			hstart := time.now()
			refH := block_extend(&hdoc, &t, 0, 1)
			hms := time.duration_milliseconds(time.since(hstart))
			cH := refH == .Caret_Unresolved && !block_active(&hdoc) && hms < 50
			if !cH {fail = true}
			fmt.printfln(
				"  %-6s caret past BLOCK_LINE_STEP_CAP refuses without scanning the whole line: refusal=%v elapsed=%.2fms (want Caret_Unresolved, <50ms)",
				"ok" if cH else "FAIL",
				refH,
				hms,
			)

			// IMPORTANT regression: a VERTICAL STEP that runs into a row longer
			// than one step's budget must refuse too, not answer from the
			// synthetic cap break pt_line_end_cap hands back. Line 0 is "a" and
			// line 1 is longer than BLOCK_LINE_STEP_CAP with no newline after it,
			// so the caret's own line start resolves fine (it is 2 bytes back) but
			// stepping DOWN off it cannot find where the next row begins. Refusing
			// is the only honest answer; treating the cap break as a row start
			// would anchor the rectangle in the middle of a line.
			stepsrc := make([]u8, 2 + BLOCK_LINE_STEP_CAP + 4096)
			mem.set(raw_data(stepsrc), 'x', len(stepsrc))
			stepsrc[0], stepsrc[1] = 'a', '\n'
			stdoc := doc_from_content(stepsrc, "", .UTF8)
			defer doc_close(&stdoc)
			stdoc.wrap = false
			stdoc.cursor = 2 // start of the over-long second line
			refStep := block_extend(&stdoc, &t, 1, 0)
			cStep :=
				refStep == .Caret_Unresolved &&
				!block_active(&stdoc) &&
				stdoc.block_anchor_line_start == 0 &&
				stdoc.block_cursor_line_start == 0
			if !cStep {fail = true}
			fmt.printfln(
				"  %-6s a step into a row past BLOCK_LINE_STEP_CAP refuses, no state changed: refusal=%v block_active=%v",
				"ok" if cStep else "FAIL",
				refStep,
				block_active(&stdoc),
			)

			// block_bounds normalises regardless of drag direction: up-and-left
			// must describe the same rectangle as down-and-right from the other
			// corner. The vertical axis is a BYTE OFFSET now (500 and 200 are
			// line starts, not line 500 and line 200), so the min/max is a
			// comparison of offsets -- but the property under test is unchanged:
			// both axes normalise independently.
			bd: Document
			bd.block_anchor_line_start, bd.block_anchor_cell = 500, 10
			bd.block_cursor_line_start, bd.block_cursor_cell = 200, 3
			loff_lo, loff_hi, lcell_lo, lcell_hi := block_bounds(&bd)
			bd.block_anchor_line_start, bd.block_anchor_cell = 200, 3
			bd.block_cursor_line_start, bd.block_cursor_cell = 500, 10
			roff_lo, roff_hi, rcell_lo, rcell_hi := block_bounds(&bd)
			cb := loff_lo == 200 && loff_hi == 500 && lcell_lo == 3 && lcell_hi == 10 &&
				loff_lo == roff_lo && loff_hi == roff_hi && lcell_lo == rcell_lo && lcell_hi == rcell_hi
			if !cb {fail = true}
			fmt.printfln("  %-6s block_bounds normalises drag direction: offs [%d,%d] cells [%d,%d]", "ok" if cb else "FAIL", loff_lo, loff_hi, lcell_lo, lcell_hi)

			// block_clear turns block_active off (and, zero-is-initialization,
			// resets the geometry so a caller that forgets the guard reads an
			// empty rectangle rather than a stale one).
			bd.block = true
			block_clear(&bd)
			cc := !block_active(&bd) && bd.block_anchor_line_start == 0 && bd.block_anchor_cell == 0 && bd.block_cursor_line_start == 0 && bd.block_cursor_cell == 0
			if !cc {fail = true}
			fmt.printfln("  %-6s block_clear deactivates and zeroes geometry", "ok" if cc else "FAIL")

			// block_press_clear (finding 5, task-3 review): a fresh press must
			// drop a stale rectangle from an earlier gesture EVEN WHEN Alt is
			// held at this press -- an Alt+click that never turns into a drag
			// must behave like a plain click, not silently preserve whatever was
			// there before. Regression: the old main.odin code only cleared on
			// the non-Alt branch, so a press with Alt held and a seeded block
			// used to leave it live. The proc no longer TAKES an `alt` argument
			// (whole-branch review LOW 6: it never read the one it had), so what
			// this now asserts is the same behaviour with the modifier removed
			// from the interface entirely -- there is no longer a value that
			// could gate it.
			bd.block = true
			bd.block_anchor_line_start, bd.block_anchor_cell = 1, 2
			bd.block_cursor_line_start, bd.block_cursor_cell = 3, 4
			block_press_clear(&bd)
			cPress := !block_active(&bd) && bd.block_anchor_line_start == 0 && bd.block_anchor_cell == 0 && bd.block_cursor_line_start == 0 && bd.block_cursor_cell == 0
			if !cPress {fail = true}
			fmt.printfln("  %-6s block_press_clear drops a stale block even with Alt held: block_active=%v", "ok" if cPress else "FAIL", block_active(&bd))

			// block_extend (task 2): the first call with no block active seeds
			// BOTH corners at the caret's own (line start offset, cell) -- both
			// out of the SAME pt_line_start_cap call doc_cursor_col already makes,
			// never a hand-rolled walk and never a line count -- and only then
			// applies its own delta to the cursor corner. `doc`'s line 0
			// ("abcdefgh") is pure ASCII and starts at byte 0, so the caret at
			// byte 2 is line start 0, cell 2.
			doc.wrap = false
			doc.cursor = 2
			okE1 := block_extend(&doc, &t, 0, 1) == .None
			cE1 :=
				okE1 &&
				block_active(&doc) &&
				doc.block_anchor_line_start == 0 &&
				doc.block_anchor_cell == 2 &&
				doc.block_cursor_line_start == 0 &&
				doc.block_cursor_cell == 3
			if !cE1 {fail = true}
			fmt.printfln(
				"  %-6s block_extend seeds anchor at caret and moves cursor: anchor=(off %d,cell %d) cursor=(off %d,cell %d) ok=%v",
				"ok" if cE1 else "FAIL",
				doc.block_anchor_line_start,
				doc.block_anchor_cell,
				doc.block_cursor_line_start,
				doc.block_cursor_cell,
				okE1,
			)

			// Extending left past cell 0 clamps rather than going negative --
			// four steps left from cursor_cell=3 must stop at 0, not -1, while
			// the anchor (still at cell 2, set above) never moves.
			okE2 := block_extend(&doc, &t, 0, -1) == .None // 3 -> 2
			okE3 := block_extend(&doc, &t, 0, -1) == .None // 2 -> 1
			okE4 := block_extend(&doc, &t, 0, -1) == .None // 1 -> 0
			okE5 := block_extend(&doc, &t, 0, -1) == .None // would be -1: clamp to 0
			cClamp := okE2 && okE3 && okE4 && okE5 && doc.block_cursor_cell == 0 && doc.block_anchor_cell == 2
			if !cClamp {fail = true}
			fmt.printfln("  %-6s block_extend clamps left of cell 0: cursor_cell=%d anchor_cell=%d (want 0, 2)", "ok" if cClamp else "FAIL", doc.block_cursor_cell, doc.block_anchor_cell)
			block_clear(&doc)

			// A vertical step lands on the NEXT ROW'S OWN line start, not on
			// "line index + 1" -- the whole point of the model. Two steps down
			// from the caret on line 0 of `doc` must reach line 2's byte offset
			// (ls2), which is 9 for "abcdefgh\n" + "\tindented\n". Stepping is
			// where a line-number model and an offset model visibly differ: an
			// index would still read 2 here whether or not it could be resolved.
			doc.cursor = 0
			okV1 := block_extend(&doc, &t, 1, 0) == .None
			okV2 := block_extend(&doc, &t, 1, 0) == .None
			cV := okV1 && okV2 && doc.block_anchor_line_start == ls0 && doc.block_cursor_line_start == ls2
			if !cV {fail = true}
			fmt.printfln(
				"  %-6s two steps down land on the next rows' own line starts: anchor_off=%d cursor_off=%d (want %d, %d)",
				"ok" if cV else "FAIL",
				doc.block_anchor_line_start,
				doc.block_cursor_line_start,
				ls0,
				ls2,
			)

			// Stepping up past the first row stops at byte 0 and reports success
			// -- running out of DOCUMENT is not truncation, exactly as an arrow
			// key at the top of the buffer does nothing rather than failing.
			okU1 := block_extend(&doc, &t, -1, 0) == .None
			okU2 := block_extend(&doc, &t, -1, 0) == .None
			okU3 := block_extend(&doc, &t, -1, 0) == .None
			cU := okU1 && okU2 && okU3 && doc.block_cursor_line_start == 0
			if !cU {fail = true}
			fmt.printfln("  %-6s stepping up past the first row stops at offset 0: cursor_off=%d (want 0)", "ok" if cU else "FAIL", doc.block_cursor_line_start)
			block_clear(&doc)

			// wrap=true refuses unconditionally and changes no state -- neither
			// activating a block nor touching the geometry fields, even on the
			// very first (seeding) call.
			doc.wrap = true
			refW := block_extend(&doc, &t, 0, 1)
			cW := refW == .Wrap_On && !block_active(&doc) && doc.block_anchor_line_start == 0 && doc.block_anchor_cell == 0 && doc.block_cursor_line_start == 0 && doc.block_cursor_cell == 0
			if !cW {fail = true}
			fmt.printfln("  %-6s block_extend refuses while wrapped, no state changed: refusal=%v block_active=%v", "ok" if cW else "FAIL", refW, block_active(&doc))
			doc.wrap = false

			// The real predicate is doc_wraps, not doc.wrap directly: Markdown
			// Split force-wraps the editor half (it lives in the left pane and
			// must fold rather than run under the preview) even with doc.wrap
			// itself off, so a (line, cell) rectangle is exactly as unstable
			// there as with word-wrap on. Before this fix, block_extend checked
			// doc.wrap alone and let a rectangle through in Split.
			//
			// Split reports its OWN refusal (.Split_On, not .Wrap_On) -- a
			// live-pass finding: the old single Wrap_On note told the user to
			// press Alt+Z, which does nothing at all in Split (Ctrl+M is the
			// control that turns it off). See Block_Refusal's own comment.
			doc.md_mode = .Split
			refS := block_extend(&doc, &t, 0, 1)
			cSp := refS == .Split_On && !block_active(&doc) && doc.block_anchor_line_start == 0 && doc.block_anchor_cell == 0 && doc.block_cursor_line_start == 0 && doc.block_cursor_cell == 0
			if !cSp {fail = true}
			fmt.printfln("  %-6s block_extend refuses in Markdown Split via its own Split_On, no state changed: refusal=%v block_active=%v", "ok" if cSp else "FAIL", refS, block_active(&doc))
			doc.md_mode = .Off

			// Filter view gets its own refusal (.Filter_On, not .Wrap_On): its
			// visible rows are a non-contiguous subset of the document's lines,
			// a different ambiguity than wrap, and telling the user to press
			// Alt+Z would send them chasing the wrong control.
			doc.filter = true
			refF := block_extend(&doc, &t, 0, 1)
			cF := refF == .Filter_On && !block_active(&doc) && doc.block_anchor_line_start == 0 && doc.block_anchor_cell == 0 && doc.block_cursor_line_start == 0 && doc.block_cursor_cell == 0
			if !cF {fail = true}
			fmt.printfln("  %-6s block_extend refuses while filter view is on: refusal=%v block_active=%v", "ok" if cF else "FAIL", refF, block_active(&doc))
			doc.filter = false

			// CRITICAL regression: caret_line_start_cell (and so block_extend)
			// must REFUSE rather than seed a rectangle at offset 0 / cell 0 when
			// the caret cannot be resolved within its scan cap. Falling back to 0
			// while reporting success anchors the rectangle at the top of the file
			// instead of wherever the caret actually is, on a document large
			// enough to matter -- and the copy and the edit run through it.
			// Sabotage: make caret_line_start_cell ignore its own `ok` (or have
			// block_extend ignore caret_line_start_cell's ok) and the axis-2 case
			// below must FAIL.
			//
			// The two axes this used to have are now ASYMMETRIC, and that is the
			// model change showing through: what a bounded scan can know about a
			// caret's LINE NUMBER (axis 1) and about its LINE START (axis 2) are
			// different facts. Axis 1 is now a success case; axis 2 still refuses.

			// Axis 1 INVERTED by this change: a caret more than STATUS_LINE_CAP
			// (4 MiB) into the file. The line-NUMBER model had to refuse here --
			// doc_cursor_line returns 0 (unknown) past that cap -- so column
			// select was simply unavailable anywhere past 4 MiB of a file, and
			// the test asserted that refusal. A line START is a LOCAL fact, a
			// backward scan to the nearest newline, so the same caret now
			// resolves EXACTLY and cheaply. This case is here to pin that the
			// model change bought correctness, not just speed: it must SUCCEED,
			// and anchor where the caret actually is.
			line_cap_target := STATUS_LINE_CAP + 8 * 4096 // comfortably past the old cap
			line_count := line_cap_target / 8
			big_lines := make([]u8, line_count * 8)
			for i in 0 ..< line_count {copy(big_lines[i * 8:i * 8 + 8], "aaaaaaa\n")}
			bldoc := doc_from_content(big_lines, "", .UTF8)
			defer doc_close(&bldoc)
			bldoc.wrap = false
			bldoc.cursor = len(big_lines) - 1 // on the last line, at its '\n'
			want_bl := (line_count - 1) * 8 // that line's own first byte
			bstart := time.now()
			refB := block_extend(&bldoc, &t, 1, 0)
			bms := time.duration_milliseconds(time.since(bstart))
			cB :=
				refB == .None &&
				block_active(&bldoc) &&
				bldoc.block_anchor_line_start == want_bl &&
				bldoc.block_cursor_line_start == len(big_lines) &&
				bms < 5
			if !cB {fail = true}
			fmt.printfln(
				"  %-6s caret 4+ MiB deep resolves exactly instead of refusing: refusal=%v anchor_off=%d (want %d) elapsed=%.2fms (<5ms)",
				"ok" if cB else "FAIL",
				refB,
				bldoc.block_anchor_line_start,
				want_bl,
				bms,
			)

			// Axis 2 SURVIVES the model change: one line longer than
			// BLOCK_LINE_STEP_CAP with the caret at its end. The backward scan
			// hits its cap without finding a newline, so what it returns is a
			// scan FLOOR and not a line start -- neither the row nor the column
			// is a fact, and the gesture must still refuse rather than anchor at
			// the floor. A single line with no newline at all.
			giant_line := make([]u8, STATUS_COL_CAP + 4096)
			mem.set(raw_data(giant_line), 'y', len(giant_line))
			gldoc := doc_from_content(giant_line, "", .UTF8)
			defer doc_close(&gldoc)
			gldoc.wrap = false
			gldoc.cursor = len(giant_line) - 1
			refG := block_extend(&gldoc, &t, 0, 1)
			cG :=
				refG == .Caret_Unresolved &&
				!block_active(&gldoc) &&
				gldoc.block_anchor_line_start == 0 &&
				gldoc.block_anchor_cell == 0
			if !cG {fail = true}
			fmt.printfln(
				"  %-6s block_extend refuses beyond STATUS_COL_CAP rather than seeding at cell 0: refusal=%v block_active=%v",
				"ok" if cG else "FAIL",
				refG,
				block_active(&gldoc),
			)

			// Clearing (task 2): Escape, Toggle_Wrap and a plain caret move must
			// each drop a live block. These three go through command_dispatch /
			// set_cursor rather than block.odin directly, so they need a real
			// App (command_dispatch reads app.settings, app.docs, ...) rather
			// than the bare `doc` used above.
			{
				a: App
				dummy: plat.Window
				app_new_scratch(&a)
				ad := app_active(&a)
				ad.wrap = false
				seed_block :: proc(d: ^Document) {
					d.block = true
					d.block_anchor_line_start, d.block_anchor_cell = 1, 2
					d.block_cursor_line_start, d.block_cursor_cell = 3, 4
				}

				seed_block(ad)
				command_dispatch(.Toggle_Wrap, {}, &a, &dummy, &t, 10)
				cTW := !block_active(ad) && ad.wrap == true
				if !cTW {fail = true}
				fmt.printfln("  %-6s Toggle_Wrap clears an active block: block_active=%v wrap=%v", "ok" if cTW else "FAIL", block_active(ad), ad.wrap)
				ad.wrap = false // back off, for the tests below

				seed_block(ad)
				command_dispatch(.Clear_Selection, {}, &a, &dummy, &t, 10)
				cCS := !block_active(ad)
				if !cCS {fail = true}
				fmt.printfln("  %-6s Escape (Clear_Selection) clears an active block: block_active=%v", "ok" if cCS else "FAIL", block_active(ad))

				seed_block(ad)
				command_dispatch(resolve_key(.Right, false, false, .Editor), {.Right, false, false, false}, &a, &dummy, &t, 10)
				cArrow := !block_active(ad)
				if !cArrow {fail = true}
				fmt.printfln("  %-6s a plain (unshifted) arrow move clears a stale block: block_active=%v", "ok" if cArrow else "FAIL", block_active(ad))

				// Full dispatch wiring: Alt+Shift+Right seeds+extends through the
				// real keymap (resolve_key -> command_dispatch), not block_extend
				// called directly. Bare Alt+Left (shift not held) must still do
				// nothing -- the whole reason the action re-reads ev.shift.
				//
				// Sets up its own state explicitly (block_clear, cursor/anchor)
				// rather than relying on cArrow above having left the block
				// cleared -- a case that depends on a PRECEDING case's side
				// effect fails spuriously whenever something unrelated changes.
				block_clear(ad)
				ad.cursor, ad.anchor = 0, 0
				rcmd := resolve_key(.Right, false, true, .Editor)
				command_dispatch(rcmd, {.Right, false, true, true}, &a, &dummy, &t, 10) // Alt+Shift+Right
				cDispR :=
					block_active(ad) &&
					ad.block_anchor_line_start == 0 &&
					ad.block_anchor_cell == 0 &&
					ad.block_cursor_line_start == 0 &&
					ad.block_cursor_cell == 1
				if !cDispR {fail = true}
				fmt.printfln(
					"  %-6s Alt+Shift+Right dispatch creates+extends a block: active=%v anchor=(%d,%d) cursor=(%d,%d)",
					"ok" if cDispR else "FAIL",
					block_active(ad),
					ad.block_anchor_line_start,
					ad.block_anchor_cell,
					ad.block_cursor_line_start,
					ad.block_cursor_cell,
				)
				block_clear(ad)
				lcmd := resolve_key(.Left, false, true, .Editor)
				command_dispatch(lcmd, {.Left, false, false, true}, &a, &dummy, &t, 10) // bare Alt+Left, no shift (Key_Event is {key,ctrl,shift,alt})
				cBareLeft := !block_active(ad)
				if !cBareLeft {fail = true}
				fmt.printfln("  %-6s bare Alt+Left (no shift) still does nothing: block_active=%v", "ok" if cBareLeft else "FAIL", block_active(ad))

				// IMPORTANT regression: block_extend_dispatch (commands.odin)
				// used to post the "[COLUMN SELECT NEEDS WRAP OFF...]" note on
				// ANY refusal. Now that Caret_Unresolved is its own reason, a
				// beyond-cap refusal must get its own distinct note rather than
				// sending the user chasing Alt+Z for a problem that has nothing
				// to do with wrap. Swap ad's content for a single line longer
				// than STATUS_COL_CAP (same shape as the bare-block_extend axis
				// 2 case above), then dispatch through the real keymap command
				// rather than calling block_extend directly.
				giant_disp := make([]u8, STATUS_COL_CAP + 4096)
				mem.set(raw_data(giant_disp), 'z', len(giant_disp))
				doc_close(ad)
				ad^ = doc_from_content(giant_disp, "", .UTF8)
				ad.wrap = false
				ad.cursor = len(giant_disp) - 1
				ad.anchor = ad.cursor
				command_dispatch(.Block_Extend_Down, {}, &a, &dummy, &t, 10)
				noteG := a.notice
				cNote := !block_active(ad) && strings.contains(noteG, "UNAVAILABLE HERE") && !strings.contains(noteG, "NEEDS WRAP OFF")
				if !cNote {fail = true}
				fmt.printfln("  %-6s beyond-cap refusal gets its own note, not the wrap-off one: notice=%q", "ok" if cNote else "FAIL", noteG)

				app_destroy(&a)
			}

			// Rectangle-clearing regression (IMPORTANT): apply_snapshot (undo),
			// doc_select_all, doc_select_word_at, doc_select_line_at and
			// find_select_current all mutate doc.cursor/anchor directly,
			// bypassing set_cursor -- so a live block survived undo, Select All,
			// double-click word-select, triple-click line-select and jumping to
			// a find match. Each case below sets up its own state explicitly
			// (fresh Document, block seeded fresh) rather than depending on a
			// neighbouring case, per the same rule as the Alt+Shift+Right fix
			// above.
			{
				// apply_snapshot, via doc_undo (doc.odin): a block active when
				// an undo lands must not survive it -- the restored tree may no
				// longer have the rows the rectangle's line/cell pair named.
				und := doc_from_content(transmute([]u8)strings.clone("hello\nworld\n"), "", .UTF8)
				defer doc_close(&und)
				und.wrap = false
				doc_insert_rune(&und, 'X') // pushes an undo snapshot of the pre-edit state
				und.block = true
				und.block_anchor_line_start, und.block_anchor_cell = 0, 0
				und.block_cursor_line_start, und.block_cursor_cell = 1, 2
				doc_undo(&und)
				cUndo := !block_active(&und)
				if !cUndo {fail = true}
				fmt.printfln("  %-6s undo (apply_snapshot) clears a stale block: block_active=%v", "ok" if cUndo else "FAIL", block_active(&und))

				// doc_select_all (Ctrl+A).
				sad := doc_from_content(transmute([]u8)strings.clone("hello world\n"), "", .UTF8)
				defer doc_close(&sad)
				sad.block = true
				sad.block_anchor_line_start, sad.block_anchor_cell = 0, 1
				sad.block_cursor_line_start, sad.block_cursor_cell = 0, 3
				doc_select_all(&sad)
				cSelAll := !block_active(&sad)
				if !cSelAll {fail = true}
				fmt.printfln("  %-6s Select All clears a stale block: block_active=%v", "ok" if cSelAll else "FAIL", block_active(&sad))

				// doc_select_word_at (double-click).
				swd := doc_from_content(transmute([]u8)strings.clone("hello world\n"), "", .UTF8)
				defer doc_close(&swd)
				swd.block = true
				swd.block_anchor_line_start, swd.block_anchor_cell = 0, 1
				swd.block_cursor_line_start, swd.block_cursor_cell = 0, 3
				doc_select_word_at(&swd, 2) // inside "hello"
				cSelWord := !block_active(&swd)
				if !cSelWord {fail = true}
				fmt.printfln("  %-6s double-click word-select clears a stale block: block_active=%v", "ok" if cSelWord else "FAIL", block_active(&swd))

				// doc_select_line_at (triple-click).
				sld := doc_from_content(transmute([]u8)strings.clone("hello world\nsecond line\n"), "", .UTF8)
				defer doc_close(&sld)
				sld.block = true
				sld.block_anchor_line_start, sld.block_anchor_cell = 0, 1
				sld.block_cursor_line_start, sld.block_cursor_cell = 0, 3
				doc_select_line_at(&sld, 2) // inside the first line
				cSelLine := !block_active(&sld)
				if !cSelLine {fail = true}
				fmt.printfln("  %-6s triple-click line-select clears a stale block: block_active=%v", "ok" if cSelLine else "FAIL", block_active(&sld))

				// find_select_current (find.odin) is file-private; drive it
				// through the public find_next, which advances f.current and
				// calls it -- the same path Ctrl+G / F3 takes.
				fnd := doc_from_content(transmute([]u8)strings.clone("alpha beta gamma\n"), "", .UTF8)
				defer doc_close(&fnd)
				fnd.find.matches = []int{6, 11} // "beta" at 6, "gamma" at 11
				fnd.find.match_len = []int{4, 5}
				fnd.find.current = -1
				fnd.block = true
				fnd.block_anchor_line_start, fnd.block_anchor_cell = 0, 0
				fnd.block_cursor_line_start, fnd.block_cursor_cell = 0, 3
				find_next(&fnd)
				cFindSel := !block_active(&fnd)
				if !cFindSel {fail = true}
				fmt.printfln("  %-6s jumping to a find match clears a stale block: block_active=%v", "ok" if cFindSel else "FAIL", block_active(&fnd))
			}

			// Task 3: block_set_from_points -- the mouse gesture's geometry
			// setter. The gesture itself (Alt+drag in main.odin) is NOT covered
			// here: this environment cannot inject mouse or keyboard input, so
			// there is no way to drive the real press/drag/release sequence.
			// What follows exercises exactly what is callable: the proc's own
			// writes and its two refusals.
			{
				// Both ends set directly in one call (unlike block_extend, there
				// is no seed-then-step split -- the mouse already knows both
				// corners, and main.odin resolves each one's line start through
				// block_line_start_at before calling). A drag from (offset 500,
				// cell 10) to (offset 200, cell 3), up-and-left, is stored exactly
				// as given; block_bounds (already proven above to normalise
				// regardless of drag direction) is what turns it into
				// offs [200,500] x cells [3,10].
				psp: Document
				psp.wrap = false
				refP := block_set_from_points(&psp, &t, 500, 10, 200, 3)
				poff_lo, poff_hi, pcell_lo, pcell_hi := block_bounds(&psp)
				cP :=
					refP == .None &&
					block_active(&psp) &&
					psp.block_anchor_line_start == 500 &&
					psp.block_anchor_cell == 10 &&
					psp.block_cursor_line_start == 200 &&
					psp.block_cursor_cell == 3 &&
					poff_lo == 200 &&
					poff_hi == 500 &&
					pcell_lo == 3 &&
					pcell_hi == 10
				if !cP {fail = true}
				fmt.printfln(
					"  %-6s block_set_from_points stores both ends directly, bounds normalise: anchor=(off %d,cell %d) cursor=(off %d,cell %d) bounds=offs[%d,%d] cells[%d,%d]",
					"ok" if cP else "FAIL",
					psp.block_anchor_line_start,
					psp.block_anchor_cell,
					psp.block_cursor_line_start,
					psp.block_cursor_cell,
					poff_lo,
					poff_hi,
					pcell_lo,
					pcell_hi,
				)

				// Wrap_On: the same refusal block_extend gives, for the same
				// reason -- word wrap turns a (line, cell) rectangle into
				// something that stops describing anything stable the instant
				// it's toggled. No state changes on refusal.
				pwp: Document
				pwp.wrap = true
				refPW := block_set_from_points(&pwp, &t, 0, 0, 1, 1)
				cPW :=
					refPW == .Wrap_On &&
					!block_active(&pwp) &&
					pwp.block_anchor_line_start == 0 &&
					pwp.block_anchor_cell == 0 &&
					pwp.block_cursor_line_start == 0 &&
					pwp.block_cursor_cell == 0
				if !cPW {fail = true}
				fmt.printfln("  %-6s block_set_from_points refuses while wrapped, no state changed: refusal=%v block_active=%v", "ok" if cPW else "FAIL", refPW, block_active(&pwp))

				// Markdown Split refuses too, via the same doc_wraps predicate as
				// block_extend -- not doc.wrap directly. Split force-wraps the
				// editor half even with doc.wrap off, so the mouse gesture must
				// refuse there exactly as the keyboard gesture does -- and, since
				// the live pass, with its own Split_On rather than Wrap_On, so the
				// note names Ctrl+M instead of the useless-here Alt+Z.
				psS: Document
				psS.wrap = false
				psS.md_mode = .Split
				refPS := block_set_from_points(&psS, &t, 0, 0, 1, 1)
				cPS := refPS == .Split_On && !block_active(&psS)
				if !cPS {fail = true}
				fmt.printfln("  %-6s block_set_from_points refuses in Markdown Split via its own Split_On: refusal=%v block_active=%v", "ok" if cPS else "FAIL", refPS, block_active(&psS))

				// Filter view refuses distinctly (.Filter_On): its visible rows
				// are a non-contiguous subset of the document's lines, a
				// different ambiguity than wrap, so it needs its own note rather
				// than telling the user to press Alt+Z.
				psF: Document
				psF.wrap = false
				psF.filter = true
				refPF := block_set_from_points(&psF, &t, 0, 0, 1, 1)
				cPF := refPF == .Filter_On && !block_active(&psF)
				if !cPF {fail = true}
				fmt.printfln("  %-6s block_set_from_points refuses while filter view is on: refusal=%v block_active=%v", "ok" if cPF else "FAIL", refPF, block_active(&psF))

				// Caret_Unresolved: main.odin passes -1 for an end whose line
				// start block_line_start_at could not resolve (exact=false -- what
				// it returned is a scan floor, not a row). Either end being
				// unresolved must refuse the WHOLE call rather than seed a
				// rectangle at offset 0 -- the exact "confident wrong answer on a
				// large file" shape block_extend's own Caret_Unresolved exists to
				// prevent. Checked on both the anchor end and the cursor end:
				// nothing here says one end is more trustworthy than the other.
				pup: Document
				pup.wrap = false
				refPU1 := block_set_from_points(&pup, &t, -1, 0, 3, 4)
				refPU2 := block_set_from_points(&pup, &t, 0, 0, -1, 4)
				cPU :=
					refPU1 == .Caret_Unresolved &&
					refPU2 == .Caret_Unresolved &&
					!block_active(&pup) &&
					pup.block_anchor_line_start == 0 &&
					pup.block_anchor_cell == 0 &&
					pup.block_cursor_line_start == 0 &&
					pup.block_cursor_cell == 0
				if !cPU {fail = true}
				fmt.printfln(
					"  %-6s block_set_from_points refuses an unresolved end (anchor or cursor), no seed at offset 0: refAnchor=%v refCursor=%v block_active=%v",
					"ok" if cPU else "FAIL",
					refPU1,
					refPU2,
					block_active(&pup),
				)
			}

			// Task 4: block_selection_rects -- the draw. Reuses the same `doc`
			// fixture as block_row_range's own tests above (bytes and cells
			// disagree there via a tab and via CJK), so a draw that quietly
			// counted bytes instead of asking block_row_range would be caught
			// here too, not only in block_row_range's own assertions.
			{
				doc.wrap = false
				doc.filter = false
				doc.md_mode = .Off
				doc.top = 0
				px := f32(16)
				cw := plat.text_char_width(&t, px, .Doc)
				rectq: [8]plat.Quad

				// A: emitted quad count equals the number of visible spanned
				// rows when every row reaches cell_lo. Rows 0 (ascii), 1 (tab)
				// and 2 (CJK) all reach cell 2 -- the tab row's leading tab
				// straddles it, same as block_row_range's own "tab row" case
				// above.
				doc.block = true
				doc.block_anchor_line_start, doc.block_anchor_cell = ls0, 2
				doc.block_cursor_line_start, doc.block_cursor_cell = ls2, 6
				nA := block_selection_rects(&doc, &t, px, cw, 5, rectq[:])
				cA := nA == 3
				if !cA {fail = true}
				fmt.printfln("  %-6s quad count == spanned rows reaching cell_lo: n=%d (want 3)", "ok" if cA else "FAIL", nA)

				// Fill colour is the same role the linear selection uses -- a
				// rectangle is still a selection, not a new colour.
				cCol := nA > 0 && rectq[0].color == g_theme[.Selection_Doc]
				if !cCol {fail = true}
				fmt.printfln("  %-6s fill colour is g_theme[.Selection_Doc]: got=%v want=%v", "ok" if cCol else "FAIL", rectq[0].color, g_theme[.Selection_Doc])

				// B: requirement 2 -- a row too short to reach cell_lo emits no
				// quad. Line 2 (CJK, 11 cells) reaches cells [8,10); line 3
				// ("short", 5 cells) does not, and must contribute nothing --
				// not a padded/clamped quad, nothing at all.
				doc.block_anchor_line_start, doc.block_anchor_cell = ls2, 8
				doc.block_cursor_line_start, doc.block_cursor_cell = ls3, 10
				nB := block_selection_rects(&doc, &t, px, cw, 5, rectq[:])
				cB := nB == 1
				if !cB {fail = true}
				fmt.printfln("  %-6s row too short for cell_lo emits no quad: n=%d (want 1, CJK row only)", "ok" if cB else "FAIL", nB)

				// C: requirement 1 -- a zero-width rectangle (cell_lo == cell_hi)
				// draws a thin bar on every spanned row, not nothing. Cell 0
				// sits exactly on a rune boundary on all three rows (ascii, tab
				// and CJK each start a rune there), so byte_lo == byte_hi on
				// every one and the floor below is what makes it visible.
				doc.block_anchor_line_start, doc.block_anchor_cell = ls0, 0
				doc.block_cursor_line_start, doc.block_cursor_cell = ls2, 0
				nC := block_selection_rects(&doc, &t, px, cw, 5, rectq[:])
				cC := nC == 3
				for i in 0 ..< nC {
					if rectq[i].size.x != sx(2) {cC = false}
				}
				if !cC {fail = true}
				fmt.printfln("  %-6s zero-width rectangle draws a thin bar per row: n=%d widths=%v (want 3, all sx(2))", "ok" if cC else "FAIL", nC, rectq[:nC])

				// ...and that bar SCALES WITH DPI. It is the primary affordance
				// for the feature's most-used case (N carets in one column), so it
				// must match the real caret, which main.odin draws at sx(2). A raw
				// 2 renders half the caret's width at 200% scale -- the user sees
				// hairlines where the caret is a bar. doc_selection_rects (doc.odin)
				// does use a raw 2 for its own floor, which is why the number got
				// copied here; there the floor is a degenerate case nobody looks at.
				saved_scale := UI_SCALE
				UI_SCALE = 2
				nDpi := block_selection_rects(&doc, &t, px, cw, 5, rectq[:])
				cDpi := nDpi == 3
				for i in 0 ..< nDpi {
					if rectq[i].size.x != 4 {cDpi = false}
				}
				UI_SCALE = saved_scale
				if !cDpi {fail = true}
				fmt.printfln("  %-6s the zero-width bar scales with DPI: n=%d width=%.1f at 200%% (want 3, 4px)", "ok" if cDpi else "FAIL", nDpi, rectq[0].size.x if nDpi > 0 else 0)

				block_clear(&doc)
			}

			// D: a row block_row_range itself refuses (ok=false, cell_hi
			// genuinely past BLOCK_ROW_CAP) must not draw a quad either --
			// drawing it as empty, or as far as the walk got, would show a
			// boundary that isn't where the rectangle actually ends.
			{
				long2 := make([]u8, BLOCK_ROW_CAP + 500)
				for i in 0 ..< len(long2) {long2[i] = 'x'}
				ldoc2 := doc_from_content(long2, "", .UTF8)
				defer doc_close(&ldoc2)
				ldoc2.wrap = false
				ldoc2.block = true
				ldoc2.block_anchor_line_start, ldoc2.block_anchor_cell = 0, BLOCK_ROW_CAP - 2
				ldoc2.block_cursor_line_start, ldoc2.block_cursor_cell = 0, BLOCK_ROW_CAP + 50
				px := f32(16)
				cw := plat.text_char_width(&t, px, .Doc)
				rectq: [4]plat.Quad
				nD := block_selection_rects(&ldoc2, &t, px, cw, 2, rectq[:])
				cD := nD == 0
				if !cD {fail = true}
				fmt.printfln("  %-6s row block_row_range refuses (cell_hi past BLOCK_ROW_CAP) emits no quad: n=%d (want 0)", "ok" if cD else "FAIL", nD)
			}

			// E/F/G: viewport clipping, byte-range inclusion (not row-index
			// arithmetic), and out-buffer truncation, all against a fresh
			// 4-line fixture.
			{
				cdoc := doc_from_content(transmute([]u8)strings.clone("l0\nl1\nl2\nl3\n"), "", .UTF8)
				defer doc_close(&cdoc)
				cdoc.wrap = false
				px := f32(16)
				cw := plat.text_char_width(&t, px, .Doc)
				rectq: [8]plat.Quad

				// E: rows clip to the viewport (the same capped Visible_Iter the
				// other three screen passes use), not walked past `rows`. A
				// rectangle spanning all 4 lines must still only emit 2 quads
				// when only 2 rows are visible.
				cdoc.block = true
				cdoc.block_anchor_line_start, cdoc.block_anchor_cell = nth_line_start(&cdoc, 0), 0
				cdoc.block_cursor_line_start, cdoc.block_cursor_cell = nth_line_start(&cdoc, 3), 1
				nE := block_selection_rects(&cdoc, &t, px, cw, 2, rectq[:])
				cE := nE == 2
				if !cE {fail = true}
				fmt.printfln("  %-6s rows clip to the viewport: n=%d (want 2 of 4 spanned rows, rows=2)", "ok" if cE else "FAIL", nE)

				// F: inclusion is by BYTE RANGE, not "visible row r is logical
				// line line_lo + r" -- doc.top is set to line 1's own start, so
				// the FIRST visible row is logical line 1, not line 0. A
				// rectangle over lines [1,2] must match viewport rows 0 and 1
				// and exclude row 2 (logical line 3, outside the rectangle).
				cdoc.top = nth_line_start(&cdoc, 1)
				cdoc.block_anchor_line_start, cdoc.block_anchor_cell = nth_line_start(&cdoc, 1), 0
				cdoc.block_cursor_line_start, cdoc.block_cursor_cell = nth_line_start(&cdoc, 2), 1
				nF := block_selection_rects(&cdoc, &t, px, cw, 3, rectq[:])
				cF := nF == 2
				if !cF {fail = true}
				fmt.printfln("  %-6s inclusion is by byte range, not row-index arithmetic (doc.top mid-document): n=%d (want 2)", "ok" if cF else "FAIL", nF)

				// G: `out` is a fixed caller buffer -- respected, not written
				// past. A 4-row rectangle with a 1-slot buffer must truncate to
				// 1, the same convention doc_selection_rects follows.
				cdoc.top = 0
				cdoc.block_anchor_line_start, cdoc.block_anchor_cell = nth_line_start(&cdoc, 0), 0
				cdoc.block_cursor_line_start, cdoc.block_cursor_cell = nth_line_start(&cdoc, 3), 1
				small: [1]plat.Quad
				nG := block_selection_rects(&cdoc, &t, px, cw, 4, small[:])
				cG := nG == 1
				if !cG {fail = true}
				fmt.printfln("  %-6s out buffer truncates rather than overruns: n=%d (want 1, cap=1)", "ok" if cG else "FAIL", nG)
			}

			// H: THE REVIEWER'S CASE. A rectangle deep in a large file must both
			// CREATE and DRAW. Under the line-NUMBER model these two caps
			// disagreed: a corner could be seeded anywhere within STATUS_LINE_CAP
			// (4 MiB) but the draw's line walk gave up after DOC_LINE_INDEX_CAP
			// (512 KiB), so driving the real block_extend path with the caret at
			// 665 KiB of a 716 KB file produced refusal=.None, block_active=true
			// and then ZERO quads -- a selection the user could not see, and one
			// the copy and the edit would still run through. Both halves are
			// asserted here, in that order, because either alone would have passed
			// on the broken build.
			{
				line := "the quick brown fox jumps over the lazy dog 0123456789\n" // 55 bytes
				deep_lines := 13000 // ~715 KB, the reviewer's file size
				b := strings.builder_make(context.temp_allocator)
				for _ in 0 ..< deep_lines {strings.write_string(&b, line)}
				deep := transmute([]u8)strings.clone(strings.to_string(b))
				ddoc := doc_from_content(deep, "", .UTF8)
				defer doc_close(&ddoc)
				ddoc.wrap = false
				// Caret at 665 KiB in, on a real line start well past the old
				// 512 KiB draw cap.
				deep_row := (665 * 1024) / len(line)
				deep_off := deep_row * len(line)
				ddoc.cursor = deep_off + 5
				refD1 := block_extend(&ddoc, &t, 0, 4) // seed a 4-cell-wide rectangle
				refD2 := block_extend(&ddoc, &t, 1, 0)
				refD3 := block_extend(&ddoc, &t, 1, 0) // 3 rows tall
				ddoc.top = deep_off
				px := f32(16)
				cw := plat.text_char_width(&t, px, .Doc)
				rectq: [16]plat.Quad
				nDeep := block_selection_rects(&ddoc, &t, px, cw, 10, rectq[:])
				cDeep :=
					refD1 == .None &&
					refD2 == .None &&
					refD3 == .None &&
					block_active(&ddoc) &&
					ddoc.block_anchor_line_start == deep_off &&
					nDeep == 3
				if !cDeep {fail = true}
				fmt.printfln(
					"  %-6s a rectangle 665 KiB deep both creates AND draws: refusals=%v/%v/%v anchor_off=%d (want %d) quads=%d (want 3)",
					"ok" if cDeep else "FAIL",
					refD1,
					refD2,
					refD3,
					ddoc.block_anchor_line_start,
					deep_off,
					nDeep,
				)

			}

			// I: the draw's COST must scale with the RECTANGLE, not with how far
			// into the file it sits. This is the reviewer's measured freeze,
			// rebuilt to their exact fixture: a ten-row rectangle at line 28,000
			// of a ~500 KiB log cost 48 MS PER FRAME, steady state, at -o:speed --
			// and main.odin's frame loop does not wait for messages while
			// mouse_down, so an Alt+drag paid it on every frame (~20 fps on an
			// ordinary log file). Note this rectangle sits INSIDE the old 512 KiB
			// walk budget on purpose: the defect it pins is the cost, not the
			// refusal that case H covers, so the old model would have drawn all
			// ten quads here -- just far too slowly.
			//
			// The threshold is 5 ms. Chosen against that 48 ms measurement: ~10x
			// below the defect, so the old resolve cannot sneak under it, and
			// still ~80x above what this model actually costs, so it will not
			// flake on a loaded machine. (The version of this test before this
			// change allowed 50 ms against a ~0.1 ms reality -- a 450x margin,
			// which is why it could never have failed.) Averaged over 30 calls:
			// one call is now short enough that timer granularity would dominate
			// a single sample.
			{
				logline := "2026-07-26 INFO x\n" // 18 bytes
				log_rows := 29000 // ~522 KB, the reviewer's file size
				lb := strings.builder_make(context.temp_allocator)
				for _ in 0 ..< log_rows {strings.write_string(&lb, logline)}
				cdoc2 := doc_from_content(transmute([]u8)strings.clone(strings.to_string(lb)), "", .UTF8)
				defer doc_close(&cdoc2)
				cdoc2.wrap = false
				cost_off := 28000 * len(logline) // line 28,000
				cdoc2.cursor = cost_off + 5
				cdoc2.top = cost_off
				block_extend(&cdoc2, &t, 0, 4)
				for _ in 0 ..< 9 {block_extend(&cdoc2, &t, 1, 0)} // the reviewer's 10 rows
				px := f32(16)
				cw := plat.text_char_width(&t, px, .Doc)
				rectq: [16]plat.Quad
				cstart := time.now()
				nCost := 0
				REPS :: 30
				for _ in 0 ..< REPS {nCost = block_selection_rects(&cdoc2, &t, px, cw, 10, rectq[:])}
				cms := time.duration_milliseconds(time.since(cstart)) / REPS
				cCost := nCost == 10 && cms < 5
				if !cCost {fail = true}
				fmt.printfln(
					"  %-6s draw cost scales with the rectangle, not its depth (10 rows at line 28,000 of 522 KB): n=%d %.3fms/call (want 10, <5ms)",
					"ok" if cCost else "FAIL",
					nCost,
					cms,
				)
			}

			// J: a logical line longer than RENDER_LINE_CAP is shown as several
			// screen rows, each restarting its cell numbering at 0 (visible_next,
			// doc.odin). Only the FIRST of those rows is a row of the rectangle --
			// the continuation rows are the same logical line, so painting cells
			// [cell_lo, cell_hi) on them would highlight bytes 8 KiB further along
			// that line than the rectangle covers. block_is_line_start is what
			// rejects them, and this is the case that fails without it: the
			// fixture's middle line is 10,000 bytes, so it occupies two screen
			// rows, and a rectangle spanning all three lines must emit THREE
			// quads, not four.
			{
				jb := strings.builder_make(context.temp_allocator)
				strings.write_string(&jb, "a\n")
				for _ in 0 ..< 10000 {strings.write_byte(&jb, 'x')}
				strings.write_string(&jb, "\nb\n")
				jdoc := doc_from_content(transmute([]u8)strings.clone(strings.to_string(jb)), "", .UTF8)
				defer doc_close(&jdoc)
				jdoc.wrap = false
				jdoc.block = true
				jdoc.block_anchor_line_start, jdoc.block_anchor_cell = 0, 0
				jdoc.block_cursor_line_start, jdoc.block_cursor_cell = 10003, 1 // "b"'s own line start
				px := f32(16)
				cw := plat.text_char_width(&t, px, .Doc)
				rectq: [8]plat.Quad
				nJ := block_selection_rects(&jdoc, &t, px, cw, 8, rectq[:])
				cJ := nJ == 3
				if !cJ {fail = true}
				fmt.printfln("  %-6s a long line's continuation rows are not rows of the rectangle: n=%d (want 3, not 4)", "ok" if cJ else "FAIL", nJ)
			}

			// Task 5: block_text (copy) and block_cut_delete (cut).

			// K: rows join with the document's OWN line ending -- CRLF here. Three
			// 3-cell ASCII rows, rectangle over the whole width of all three, so
			// the ONLY thing under test is the separator between them. Sabotage:
			// hardcode '\n' in block_text and this must FAIL (it would read
			// "abc\ndef\nghi" instead).
			crdoc := doc_from_content(transmute([]u8)strings.clone("abc\r\ndef\r\nghi\r\n"), "", .UTF8)
			defer doc_close(&crdoc)
			crdoc.wrap = false
			crdoc.eol = .CRLF
			crdoc.block = true
			crdoc.block_anchor_line_start, crdoc.block_anchor_cell = 0, 0
			crdoc.block_cursor_line_start, crdoc.block_cursor_cell = 10, 3 // line 2 ("ghi") starts at byte 10
			crtxt, crok := block_text(&crdoc, &t)
			cCR := crok && crtxt == "abc\r\ndef\r\nghi"
			if !cCR {fail = true}
			fmt.printfln("  %-6s block_text joins rows with doc.eol=CRLF: %q ok=%v (want %q)", "ok" if cCR else "FAIL", crtxt, crok, "abc\\r\\ndef\\r\\nghi")
			block_clear(&crdoc)

			// L: the LF counterpart of K, same shape, doc.eol=.LF (the default).
			// Tested separately per the brief: a version that always emitted "\r\n"
			// would pass K and fail only here.
			lfdoc := doc_from_content(transmute([]u8)strings.clone("abc\ndef\nghi\n"), "", .UTF8)
			defer doc_close(&lfdoc)
			lfdoc.wrap = false
			lfdoc.block = true
			lfdoc.block_anchor_line_start, lfdoc.block_anchor_cell = 0, 0
			lfdoc.block_cursor_line_start, lfdoc.block_cursor_cell = 8, 3 // line 2 ("ghi") starts at byte 8
			lftxt, lfok := block_text(&lfdoc, &t)
			cLF := lfok && lftxt == "abc\ndef\nghi"
			if !cLF {fail = true}
			fmt.printfln("  %-6s block_text joins rows with doc.eol=LF: %q ok=%v (want %q)", "ok" if cLF else "FAIL", lftxt, lfok, "abc\\ndef\\nghi")
			block_clear(&lfdoc)

			// M: requirement 2 -- a row too short to reach cell_lo contributes an
			// EMPTY line, not a skipped one, so the rectangle's row count survives
			// the round trip. Reuses `doc`'s CJK line (ls2, reaches cells [8,10) as
			// " o") and "short" line (ls3, 5 cells, does not reach cell 8 at all).
			// Sabotage: `continue` past a row with pad_cells>0 instead of still
			// writing it (empty) -- this must FAIL (result would be " o" with no
			// trailing separator, one line short of what a 2-row rectangle owes).
			doc.block = true
			doc.block_anchor_line_start, doc.block_anchor_cell = ls2, 8
			doc.block_cursor_line_start, doc.block_cursor_cell = ls3, 10
			mtxt, mok := block_text(&doc, &t)
			cM := mok && mtxt == " o\n"
			if !cM {fail = true}
			fmt.printfln("  %-6s a too-short row contributes an EMPTY line, not a skipped one: %q ok=%v (want %q)", "ok" if cM else "FAIL", mtxt, mok, " o\\n")
			block_clear(&doc)

			// N: block_text refuses (ok=false, "" text) when a spanned row's own
			// block_row_range refuses -- the same long-row/cell_hi-past-cap fixture
			// as block_row_range's own refusal test above. A partial rectangle must
			// never reach the clipboard.
			nbuf := make([]u8, BLOCK_ROW_CAP + 500)
			for i in 0 ..< len(nbuf) {nbuf[i] = 'x'}
			ndoc := doc_from_content(nbuf, "", .UTF8)
			defer doc_close(&ndoc)
			ndoc.wrap = false
			ndoc.block = true
			ndoc.block_anchor_line_start, ndoc.block_anchor_cell = 0, BLOCK_ROW_CAP - 2
			ndoc.block_cursor_line_start, ndoc.block_cursor_cell = 0, BLOCK_ROW_CAP + 50
			ntxt, nok := block_text(&ndoc, &t)
			cN := !nok && ntxt == ""
			if !cN {fail = true}
			fmt.printfln("  %-6s block_text refuses when a row's own block_row_range refuses: ok=%v text=%q (want ok=false, \"\")", "ok" if cN else "FAIL", nok, ntxt)
			block_clear(&ndoc)

			// O: block_text refuses a rectangle spanning more than
			// BLOCK_EDIT_MAX_LINES rows, rather than build the whole string and
			// throw it away -- this is the cap that keeps a Ctrl+C on a
			// rectangle spanning an entire huge file off the main thread. Rows are
			// trivial ("a\n", 2 bytes) so any refusal here is the ROW-COUNT cap,
			// not a per-row block_row_range refusal -- isolates the one from the
			// other.
			big_rows := BLOCK_EDIT_MAX_LINES + 5
			obuf := make([]u8, big_rows * 2)
			for i in 0 ..< big_rows {obuf[i * 2] = 'a'; obuf[i * 2 + 1] = '\n'}
			odoc := doc_from_content(obuf, "", .UTF8)
			defer doc_close(&odoc)
			odoc.wrap = false
			odoc.block = true
			odoc.block_anchor_line_start, odoc.block_anchor_cell = 0, 0
			odoc.block_cursor_line_start, odoc.block_cursor_cell = (big_rows - 1) * 2, 1
			ostart := time.now()
			otxt, ook := block_text(&odoc, &t)
			oms := time.duration_milliseconds(time.since(ostart))
			cO := !ook && otxt == "" && oms < 50
			if !cO {fail = true}
			fmt.printfln("  %-6s block_text refuses past BLOCK_EDIT_MAX_LINES rows without building the whole string: ok=%v text=%q elapsed=%.2fms (want ok=false, \"\", <50ms)", "ok" if cO else "FAIL", ook, otxt, oms)
			block_clear(&odoc)

			// P: block_cut_delete -- the other half of `.Cut`. Three 4-cell ASCII
			// rows, rectangle over cells [1,3) (the middle two of each), so cutting
			// leaves "aa"/"bb"/"cc" on every row. Checked, in order:
			//   - block_text (the clipboard text) matches what actually gets cut.
			//   - the buffer afterward has exactly that rectangle removed from
			//     every row -- not zero rows, not a subset.
			//   - the whole cut is ONE undo entry (batched), not one per row --
			//     doc_undo restores the original in a single call.
			//   - the block is cleared afterward, and the caret lands at the
			//     vanished rectangle's own top-left corner (byte 1, row 0's own
			//     cell 1).
			pdoc := doc_from_content(transmute([]u8)strings.clone("aaaa\nbbbb\ncccc\n"), "", .UTF8)
			defer doc_close(&pdoc)
			pdoc.wrap = false
			pls0, _, pls2 := 0, 5, 10 // row starts: "aaaa\n"=5B, "bbbb\n"=5B, so rows at 0, 5, 10
			pdoc.block = true
			pdoc.block_anchor_line_start, pdoc.block_anchor_cell = pls0, 1
			pdoc.block_cursor_line_start, pdoc.block_cursor_cell = pls2, 3
			ptxt, ptok := block_text(&pdoc, &t)
			cPtxt := ptok && ptxt == "aa\nbb\ncc"
			if !cPtxt {fail = true}
			fmt.printfln("  %-6s block_cut_delete fixture: block_text matches what will be cut: %q ok=%v (want %q)", "ok" if cPtxt else "FAIL", ptxt, ptok, "aa\\nbb\\ncc")

			undo_before := len(pdoc.undo)
			pcut := block_cut_delete(&pdoc, &t)
			after := doc_debug_string(&pdoc)
			cCut := pcut && after == "aa\nbb\ncc\n" && len(pdoc.undo) == undo_before + 1 && !block_active(&pdoc) && pdoc.cursor == 1 && pdoc.anchor == 1
			if !cCut {fail = true}
			fmt.printfln(
				"  %-6s block_cut_delete removes the rectangle from every row in ONE undo step, clears the block, carets top-left: ok=%v content=%q undo=%d (want +1) block_active=%v cursor=%d anchor=%d (want 1,1)",
				"ok" if cCut else "FAIL",
				pcut,
				after,
				len(pdoc.undo),
				block_active(&pdoc),
				pdoc.cursor,
				pdoc.anchor,
			)

			doc_undo(&pdoc)
			restored := doc_debug_string(&pdoc)
			cUndoOne := restored == "aaaa\nbbbb\ncccc\n"
			if !cUndoOne {fail = true}
			fmt.printfln("  %-6s a single Ctrl+Z restores all three rows at once: %q (want %q)", "ok" if cUndoOne else "FAIL", restored, "aaaa\\nbbbb\\ncccc\\n")

			// Q through V (below) are each their own local proc rather than an
			// inline block: this whole `blocktest` branch is one very long
			// function, and several App/Document-sized locals piled up as
			// sibling blocks in the SAME stack frame were enough to overflow the
			// default thread stack (STATUS_STACK_OVERFLOW) even though none of
			// them, and no two of them, do so alone. A separate proc gets its
			// own frame that is released on return, the same reason
			// nth_line_start and seed_block above are already pulled out rather
			// than inlined.

			// Q: MEDIUM 1 regression. Two 4-cell rows, rectangle at cells [50,60)
			// -- past the end of both. block_text still returns non-empty text
			// for this (an eol-joined run of empty lines, "\n" for two rows), so
			// `.Cut`'s `s != ""` clipboard guard passes and block_cut_delete gets
			// called -- but nothing on either row actually falls in the
			// rectangle. Before this fix, doc_batch_begin's push_undo ran anyway:
			// it marks the file modified and (since doc.batch was still false at
			// that moment) unconditionally clears the redo stack, so an
			// accidental Cut on an all-short rectangle dirtied a clean file and
			// destroyed the user's redo history with nothing to show for it.
			//
			// A real edit followed by doc_undo seeds qdoc.redo with one genuine
			// entry (doc_undo pushes the state being LEFT onto redo -- the same
			// path a user's own Ctrl+Z takes) and restores the original two-row
			// content, then qdoc.modified is forced back to false to simulate
			// the clean, just-opened file the bug report describes.
			//
			// Sabotage (per task): skip the `any_bytes` guard below and this
			// case must FAIL -- modified flips to true, the redo entry is freed
			// and the slice goes to length 0.
			block_test_q :: proc(t: ^plat.Text) -> bool {
				qdoc := doc_from_content(transmute([]u8)strings.clone("aaaa\nbbbb\n"), "", .UTF8)
				defer doc_close(&qdoc)
				qdoc.wrap = false
				qdoc.cursor, qdoc.anchor = 0, 0
				doc_insert_rune(&qdoc, 'z') // creates one undo entry
				doc_undo(&qdoc)             // restores the original text, pushes redo[0]
				qdoc.modified = false       // simulate a clean, just-opened file
				q_undo_before := len(qdoc.undo)
				q_redo_before := len(qdoc.redo)
				qdoc.block = true
				qdoc.block_anchor_line_start, qdoc.block_anchor_cell = 0, 50
				qdoc.block_cursor_line_start, qdoc.block_cursor_cell = 5, 60 // "bbbb\n"'s own line start
				qtxt, qtok := block_text(&qdoc, t)
				qcut := block_cut_delete(&qdoc, t)
				cQ :=
					qtok &&
					qtxt == "\n" &&
					qcut &&
					!qdoc.modified &&
					len(qdoc.undo) == q_undo_before &&
					len(qdoc.redo) == q_redo_before &&
					!block_active(&qdoc) &&
					doc_debug_string(&qdoc) == "aaaa\nbbbb\n"
				fmt.printfln(
					"  %-6s MEDIUM 1: Cut on an all-short rectangle leaves a clean file clean and the redo stack intact: text=%q modified=%v undo=%d (want %d) redo=%d (want %d) block_active=%v content=%q",
					"ok" if cQ else "FAIL",
					qtxt,
					qdoc.modified,
					len(qdoc.undo),
					q_undo_before,
					len(qdoc.redo),
					q_redo_before,
					block_active(&qdoc),
					doc_debug_string(&qdoc),
				)
				return cQ
			}
			if !block_test_q(&t) {fail = true}

			// R: MEDIUM 2 -- the cut's cost bound at the cap. Fixture mirrors the
			// reviewer's own: 18-byte log lines ("2026-07-26 INFO x\n"), a rectangle
			// spanning exactly BLOCK_EDIT_MAX_LINES rows starting deep in a file
			// with ~100,000 such lines (~1.8 MB, the reviewer's file size), over
			// cells [11,15) -- "INFO" -- so every row genuinely has bytes to
			// delete (this measures the real delete cost, not the all-short skip
			// path Q covers).
			//
			// THRESHOLD, retightened (whole-branch review LOW 5). This bound was
			// 60ms, sized when the cap was 10,000 rows and then left alone through
			// two cap reductions -- so at the current 300-row cap it had stopped
			// being able to fail. A cost test that cannot fail is exactly what
			// this project's own rule is about.
			//
			// Re-measured on this machine rather than estimated, DEBUG build (the
			// build these headless modes run as day to day, and the slower of the
			// two -- so a bound that holds here holds for release):
			//
			//   cap 300 (shipping):   1.33, 1.35, 1.37, 1.85, 1.94, 1.99 ms
			//   cap 2,000 (the regression this must catch): 10.91 ms
			//
			// 6ms sits ~3x above the worst of six runs at the shipping cap and
			// ~1.8x below what a regression to 2,000 rows costs. Note that the
			// "roughly 15ms" the review suggested would NOT have worked: 2,000
			// rows measures under 11ms on press #0, so 15ms would have passed the
			// very regression it was retightened to catch. The number had to come
			// off the meter, not off an estimate.
			//
			// Sabotage (per task): revert the delete loop to call block_row_range
			// a second time per row (restoring the old double-resolve) and/or
			// raise BLOCK_EDIT_MAX_LINES back to 2_000, and this must FAIL.
			block_test_r :: proc(t: ^plat.Text) -> bool {
				rline := "2026-07-26 INFO x\n" // 18 bytes; "INFO" is cells [11,15)
				rrows := 100_000 // ~1.8 MB, the reviewer's file size
				rb := strings.builder_make(context.temp_allocator)
				for _ in 0 ..< rrows {strings.write_string(&rb, rline)}
				rdoc := doc_from_content(transmute([]u8)strings.clone(strings.to_string(rb)), "", .UTF8)
				defer doc_close(&rdoc)
				rdoc.wrap = false
				r_start_row := 45_000 // deep in the file, well clear of both ends
				r_off := r_start_row * len(rline)
				rdoc.block = true
				rdoc.block_anchor_line_start, rdoc.block_anchor_cell = r_off, 11
				rdoc.block_cursor_line_start, rdoc.block_cursor_cell = r_off + (BLOCK_EDIT_MAX_LINES - 1) * len(rline), 15
				rstart := time.now()
				rcut := block_cut_delete(&rdoc, t)
				rms := time.duration_milliseconds(time.since(rstart))
				cR := rcut && !block_active(&rdoc) && rms < 6
				fmt.printfln(
					"  %-6s MEDIUM 2: cutting a %d-row rectangle at the cap costs a bounded amount: ok=%v elapsed=%.2fms (want <6ms)",
					"ok" if cR else "FAIL",
					BLOCK_EDIT_MAX_LINES,
					rcut,
					rms,
				)
				return cR
			}
			if !block_test_r(&t) {fail = true}

			// S: LOW 3 -- the caret must land at the rectangle's own top-left
			// corner even when the TOP row is too short to have anything deleted
			// on it. Rows "x" / "aaaaaaaa" / "bbbbbbbb", rectangle over cells
			// [3,6): row 0 ("x") never reaches cell 3, so its own delete is
			// skipped, and the old code left the caret at row 1's byte_lo
			// (offset 5) -- the last row the bottom-up loop actually touched --
			// instead of row 0's own resolved position (offset 1, "x"'s own end,
			// since row 0 can't reach cell 3 at all). Sabotage: remove the
			// explicit `doc.anchor = doc.cursor = los[0]` after the delete loop
			// and this must FAIL (cursor/anchor would read 5, not 1).
			block_test_s :: proc(t: ^plat.Text) -> bool {
				topdoc := doc_from_content(transmute([]u8)strings.clone("x\naaaaaaaa\nbbbbbbbb\n"), "", .UTF8)
				defer doc_close(&topdoc)
				topdoc.wrap = false
				topdoc.block = true
				topdoc.block_anchor_line_start, topdoc.block_anchor_cell = 0, 3
				topdoc.block_cursor_line_start, topdoc.block_cursor_cell = 11, 6 // "bbbbbbbb"'s own line start
				topcut := block_cut_delete(&topdoc, t)
				cTop := topcut && topdoc.cursor == 1 && topdoc.anchor == 1 && !block_active(&topdoc)
				fmt.printfln(
					"  %-6s LOW 3: caret lands at the rectangle's top-left even when the top row is too short to edit: ok=%v cursor=%d anchor=%d (want 1,1)",
					"ok" if cTop else "FAIL",
					topcut,
					topdoc.cursor,
					topdoc.anchor,
				)
				return cTop
			}
			if !block_test_s(&t) {fail = true}

			// T: LOW 3 -- block clearing must be consistent across every Cut
			// path, including a single-row all-short rectangle where block_text
			// returns "". Before this fix, commands.odin's `.Cut` handler only
			// called block_cut_delete inside its `s != ""` branch, so this exact
			// case never called block_cut_delete at all and left the rectangle
			// live -- the one Cut path that didn't collapse to a caret. Dispatched
			// through the real command table (resolve_key -> command_dispatch),
			// not block_cut_delete directly, so this exercises the actual
			// gating this finding was about.
			block_test_t :: proc(t: ^plat.Text) -> bool {
				ta: App
				tdummy: plat.Window
				app_new_scratch(&ta)
				tad := app_active(&ta)
				doc_close(tad)
				tad^ = doc_from_content(transmute([]u8)strings.clone("x\n"), "", .UTF8)
				tad.wrap = false
				tad.block = true
				tad.block_anchor_line_start, tad.block_anchor_cell = 0, 10 // "x" never reaches cell 10
				tad.block_cursor_line_start, tad.block_cursor_cell = 0, 12

				// Ctrl+X below reaches the REAL Windows clipboard through
				// commands.odin's .Cut handler. Save/restore around it so this
				// case doesn't leave the clipboard holding this fixture's cut
				// byte ("x") -- belt-and-suspenders with the mode-level
				// save/restore in the blocktest dispatcher above, which is what
				// actually protects the user, but this keeps the mode's own
				// seam-proof sentinel intact across this case specifically.
				tsaved_clip, thad_clip := plat.clipboard_get_text(tdummy.hwnd, context.allocator)
				defer if thad_clip {
					plat.clipboard_set_text(tdummy.hwnd, tsaved_clip)
					delete(tsaved_clip)
				}

				command_dispatch(resolve_key(.X, true, false, .Editor), {.X, true, false, false}, &ta, &tdummy, t, 10) // Ctrl+X
				cT := !block_active(tad)
				fmt.printfln("  %-6s LOW 3: Cut on a single all-short row still clears the block: block_active=%v", "ok" if cT else "FAIL", block_active(tad))
				app_destroy(&ta)
				return cT
			}
			if !block_test_t(&t) {fail = true}

			// U: LOW 4 -- the refusal note derives its row count from
			// BLOCK_EDIT_MAX_LINES rather than a hardcoded "10000" that would
			// drift the instant the constant changes (which this very task just
			// did). Dispatched through the real command table so this exercises
			// the actual note commands.odin builds, not a copy of its format
			// string.
			block_test_u :: proc(t: ^plat.Text) -> bool {
				ua: App
				udummy: plat.Window
				app_new_scratch(&ua)
				uad := app_active(&ua)
				u_rows := BLOCK_EDIT_MAX_LINES + 5
				ubuf := make([]u8, u_rows * 2)
				for i in 0 ..< u_rows {ubuf[i * 2] = 'a'; ubuf[i * 2 + 1] = '\n'}
				doc_close(uad)
				uad^ = doc_from_content(ubuf, "", .UTF8)
				uad.wrap = false
				uad.block = true
				uad.block_anchor_line_start, uad.block_anchor_cell = 0, 0
				uad.block_cursor_line_start, uad.block_cursor_cell = (u_rows - 1) * 2, 1

				// Same real-clipboard concern as block_test_t above: Ctrl+X
				// below writes the actual Windows clipboard via .Cut. Save and
				// restore around it rather than leaving this fixture's rows in
				// the clipboard for whatever runs next.
				usaved_clip, uhad_clip := plat.clipboard_get_text(udummy.hwnd, context.allocator)
				defer if uhad_clip {
					plat.clipboard_set_text(udummy.hwnd, usaved_clip)
					delete(usaved_clip)
				}

				command_dispatch(resolve_key(.X, true, false, .Editor), {.X, true, false, false}, &ua, &udummy, t, 10) // Ctrl+X
				wantU := fmt.tprintf("%d rows", BLOCK_EDIT_MAX_LINES)
				cU := strings.contains(ua.notice, wantU)
				fmt.printfln("  %-6s LOW 4: the refusal note derives its row count from BLOCK_EDIT_MAX_LINES: notice=%q (want it to contain %q)", "ok" if cU else "FAIL", ua.notice, wantU)
				app_destroy(&ua)
				return cU
			}
			if !block_test_u(&t) {fail = true}

			// V: LOW 4 -- the undo entry's label counts rows ACTUALLY EDITED, not
			// rows spanned. Three rows, cells [1,3): "aaaa" and "cccc" each have
			// two bytes there, but "b" (row 1) is only 1 cell wide and never
			// reaches cell 1, so it contributes nothing. The rectangle spans 3
			// rows but only 2 are actually edited -- doc.state_count (set by
			// doc_batch_end, and what the history list reads) must read 2, not 3.
			block_test_v :: proc(t: ^plat.Text) -> bool {
				raggeddoc := doc_from_content(transmute([]u8)strings.clone("aaaa\nb\ncccc\n"), "", .UTF8)
				defer doc_close(&raggeddoc)
				raggeddoc.wrap = false
				raggeddoc.block = true
				raggeddoc.block_anchor_line_start, raggeddoc.block_anchor_cell = 0, 1
				raggeddoc.block_cursor_line_start, raggeddoc.block_cursor_cell = 7, 3 // "cccc"'s own line start
				raggedcut := block_cut_delete(&raggeddoc, t)
				cRagged := raggedcut && raggeddoc.state_count == 2
				fmt.printfln("  %-6s LOW 4: undo label counts rows actually edited, not rows spanned: ok=%v state_count=%d (want 2)", "ok" if cRagged else "FAIL", raggedcut, raggeddoc.state_count)
				return cRagged
			}
			if !block_test_v(&t) {fail = true}

			// --- Task 6: editing across the rectangle ---
			//
			// Every case below compares BYTES, never line counts: the whole risk of
			// this feature is a rectangular edit that lands on the right number of
			// rows at the wrong offsets, which a line count cannot see. Each is its
			// own local proc for the stack-frame reason spelled out above Q.

			// W: the prefix case -- a ZERO-WIDTH rectangle at cell 0 is N carets,
			// and typing into it prefixes every row, including a one-character row
			// and an EMPTY one (which is where a "skip rows that are too short"
			// implementation quietly loses lines). Then a SECOND character is typed
			// with no rectangle re-made in between: the rectangle survives its own
			// edit as a zero-width rectangle at the new column, so consecutive
			// keystrokes compose the way typing does everywhere else. Finally each
			// keystroke is shown to be exactly one undo entry, and undo/redo to
			// round-trip the bytes.
			//
			// Sabotage (per task): drop the doc_batch_begin/doc_batch_end pair in
			// block_apply and the undo-count assertions here must FAIL (four rows
			// produce four entries per keystroke, not one).
			block_test_w :: proc(t: ^plat.Text) -> bool {
				src := "alpha\nb\n\ngamma\n" // 4 rows: normal, short, EMPTY, normal
				wdoc := doc_from_content(transmute([]u8)strings.clone(src), "", .UTF8)
				defer doc_close(&wdoc)
				wdoc.wrap = false
				wdoc.block = true
				wdoc.block_anchor_line_start, wdoc.block_anchor_cell = 0, 0
				wdoc.block_cursor_line_start, wdoc.block_cursor_cell = 9, 0 // "gamma"'s own line start
				u0 := len(wdoc.undo)

				ok1 := block_replace(&wdoc, t, transmute([]u8)string("// "))
				got1 := doc_debug_string(&wdoc)
				want1 := "// alpha\n// b\n// \n// gamma\n"
				c1 := ok1 && got1 == want1 && len(wdoc.undo) == u0 + 1 && block_active(&wdoc)

				// Second keystroke, no rectangle re-made: it must land at cell 3 on
				// every row -- including the row that is now exactly 3 cells long.
				ok2 := block_replace(&wdoc, t, transmute([]u8)string("X"))
				got2 := doc_debug_string(&wdoc)
				want2 := "// Xalpha\n// Xb\n// X\n// Xgamma\n"
				c2 := ok2 && got2 == want2 && len(wdoc.undo) == u0 + 2

				doc_undo(&wdoc)
				back1 := doc_debug_string(&wdoc)
				doc_undo(&wdoc)
				back0 := doc_debug_string(&wdoc)
				c3 := back1 == want1 && back0 == src
				doc_redo(&wdoc)
				doc_redo(&wdoc)
				c4 := doc_debug_string(&wdoc) == want2

				cW := c1 && c2 && c3 && c4
				fmt.printfln(
					"  %-6s prefix: one keystroke prefixes every row (empty one included) as ONE undo step, and the next lands at the new column: got=%q then %q undo=%d (want %d) undo-back=%q redo-fwd=%v",
					"ok" if cW else "FAIL",
					got1,
					got2,
					len(wdoc.undo),
					u0 + 2,
					back0,
					c4,
				)
				return cW
			}
			if !block_test_w(&t) {fail = true}

			// X: the replace case -- a rectangle with WIDTH over three ragged rows.
			// Row 0 reaches past the rectangle (3 bytes deleted), row 1 stops inside
			// it (1 byte deleted, the range clamped to what the row has), row 2 never
			// reaches its left edge at all (0 deleted, and pad_cells=1 space written
			// so the X still lands in column 2). Three different per-row shapes, one
			// exact expected buffer.
			block_test_x :: proc(t: ^plat.Text) -> bool {
				src := "abcdefgh\nabc\na\n"
				xdoc := doc_from_content(transmute([]u8)strings.clone(src), "", .UTF8)
				defer doc_close(&xdoc)
				xdoc.wrap = false
				xdoc.block = true
				xdoc.block_anchor_line_start, xdoc.block_anchor_cell = 0, 2
				xdoc.block_cursor_line_start, xdoc.block_cursor_cell = 13, 5 // "a"'s own line start
				u0 := len(xdoc.undo)
				okx := block_replace(&xdoc, t, transmute([]u8)string("X"))
				got := doc_debug_string(&xdoc)
				want := "abXfgh\nabX\na X\n"
				// The caret follows the TOP row to just past what was inserted
				// there (byte 3 of "abXfgh"), and the rectangle is left live and
				// zero-width at cell 3 -- cell_lo plus the X's own cell width, not
				// its byte length. Read before the undo below, which clears both.
				cur, anc := xdoc.cursor, xdoc.anchor
				caret := cur == 3 && anc == 3
				rect := block_active(&xdoc) && xdoc.block_anchor_cell == 3 && xdoc.block_cursor_cell == 3
				// A line break has no rectangular meaning and is refused outright,
				// changing nothing -- see block_replace's own guard.
				nl := !block_replace(&xdoc, t, transmute([]u8)string("a\nb")) && doc_debug_string(&xdoc) == want
				// One undo step, and it restores the bytes exactly; redo re-applies.
				one := len(xdoc.undo) == u0 + 1
				doc_undo(&xdoc)
				back := doc_debug_string(&xdoc)
				doc_redo(&xdoc)
				fwd := doc_debug_string(&xdoc)
				cX := okx && got == want && one && back == src && fwd == want && caret && rect && nl
				fmt.printfln(
					"  %-6s replace: rectangle [2,5) over three ragged rows, one X: got=%q (want %q) undo=%d (want %d) after-undo=%q after-redo=%q caret=%d,%d (want 3,3) rect-at-cell-3=%v newline-refused=%v",
					"ok" if cX else "FAIL",
					got,
					want,
					len(xdoc.undo),
					u0 + 1,
					back,
					fwd,
					cur,
					anc,
					rect,
					nl,
				)
				return cX
			}
			if !block_test_x(&t) {fail = true}

			// Y: BOTTOM-UP. The three rows change length by three DIFFERENT amounts
			// (+2, +5, +3 -- the padding is what makes them differ), so any pass that
			// applies its pre-computed ranges top-down writes rows 1 and 2 at offsets
			// that stopped being facts the moment row 0 was spliced. The reference is
			// built by applying the identical per-row splices INDIVIDUALLY, in
			// reverse order, on a second document -- so this compares the feature
			// against the rule rather than against a string somebody typed out, and
			// the literal expectation is asserted too so both cannot drift together.
			//
			// Sabotage (per task): reverse block_apply's write loop to run 0..n and
			// this must FAIL.
			block_test_y :: proc(t: ^plat.Text) -> bool {
				src := "aaaaaaaa\nbb\ncccc\n"
				ydoc := doc_from_content(transmute([]u8)strings.clone(src), "", .UTF8)
				defer doc_close(&ydoc)
				ydoc.wrap = false
				ydoc.block = true
				ydoc.block_anchor_line_start, ydoc.block_anchor_cell = 0, 5
				ydoc.block_cursor_line_start, ydoc.block_cursor_cell = 12, 5 // "cccc"'s own line start
				oky := block_replace(&ydoc, t, transmute([]u8)string("XY"))
				got := doc_debug_string(&ydoc)

				// Same three edits, applied one at a time, highest offset first.
				ref := doc_from_content(transmute([]u8)strings.clone(src), "", .UTF8)
				defer doc_close(&ref)
				doc_replace_range(&ref, 16, 0, transmute([]u8)string(" XY")) // "cccc" + 1 pad
				doc_replace_range(&ref, 11, 0, transmute([]u8)string("   XY")) // "bb" + 3 pad
				doc_replace_range(&ref, 5, 0, transmute([]u8)string("XY")) // "aaaaaaaa", no pad
				want := doc_debug_string(&ref)

				// The rectangle's BOTTOM corner must have been corrected by the net
				// bytes the rows above it added: 12 + 2 + 5 = 19, the new start of
				// "cccc XY". A stale corner here is the same class of silent damage
				// as a top-down write, one keystroke later.
				corner := ydoc.block_cursor_line_start == 19 && ydoc.block_anchor_line_start == 0
				cY := oky && got == want && got == "aaaaaXYaaa\nbb   XY\ncccc XY\n" && corner
				fmt.printfln(
					"  %-6s bottom-up: rows changing length by +2/+5/+3 match the same splices applied individually in reverse: got=%q ref=%q bottom-corner=%d (want 19)",
					"ok" if cY else "FAIL",
					got,
					want,
					ydoc.block_cursor_line_start,
				)
				return cY
			}
			if !block_test_y(&t) {fail = true}

			// Z: the cap refuses the WHOLE edit. BLOCK_EDIT_MAX_LINES + 1 rows, so
			// the row-start walk trips the cap before a single cell is resolved. The
			// buffer must be byte-identical afterwards, with no undo entry and the
			// modified flag still clear -- a partially-applied rectangular edit
			// across thousands of rows is damage the user cannot see the shape of,
			// let alone undo confidently. Both entry points are checked: typing and
			// Backspace refuse the same way.
			//
			// Sabotage (per task): move the cap check so it truncates the row list
			// instead of returning false (a partial edit) and the byte comparison
			// here must FAIL.
			block_test_z :: proc(t: ^plat.Text) -> bool {
				rows := BLOCK_EDIT_MAX_LINES + 1
				zb := make([]u8, rows * 3)
				for i in 0 ..< rows {zb[i * 3] = 'a'; zb[i * 3 + 1] = 'b'; zb[i * 3 + 2] = '\n'}
				zdoc := doc_from_content(zb, "", .UTF8)
				defer doc_close(&zdoc)
				zdoc.wrap = false
				zdoc.modified = false
				before := doc_debug_string(&zdoc)
				u0 := len(zdoc.undo)
				zdoc.block = true
				zdoc.block_anchor_line_start, zdoc.block_anchor_cell = 0, 0
				zdoc.block_cursor_line_start, zdoc.block_cursor_cell = (rows - 1) * 3, 0
				okr := block_replace(&zdoc, t, transmute([]u8)string("X"))
				after_r := doc_debug_string(&zdoc)
				okd := block_delete(&zdoc, t, true)
				after_d := doc_debug_string(&zdoc)
				cZ :=
					!okr &&
					!okd &&
					after_r == before &&
					after_d == before &&
					len(zdoc.undo) == u0 &&
					!zdoc.modified
				fmt.printfln(
					"  %-6s cap: a %d-row rectangle (limit %d) refuses the whole edit -- bytes identical=%v/%v replace=%v delete=%v undo=%d (want %d) modified=%v",
					"ok" if cZ else "FAIL",
					rows,
					BLOCK_EDIT_MAX_LINES,
					after_r == before,
					after_d == before,
					okr,
					okd,
					len(zdoc.undo),
					u0,
					zdoc.modified,
				)
				return cZ
			}
			if !block_test_z(&t) {fail = true}

			// AA: block_delete's four shapes, dispatched through the REAL command
			// table (resolve_key -> command_dispatch) so this exercises the wiring,
			// not just the procedure. Backspace on a zero-width rectangle deletes
			// the cell to the left of every caret; a row too short to have one
			// contributes nothing rather than being padded (padding is an INSERT
			// affordance and must not appear here). Backspace at column 0 is a
			// no-op -- never N line joins -- and leaves no undo entry at all.
			// Delete forward at the last cell of a row must not eat the newline.
			block_test_aa :: proc(t: ^plat.Text) -> bool {
				aa: App
				adummy: plat.Window
				app_new_scratch(&aa)
				d := app_active(&aa)
				doc_close(d)
				d^ = doc_from_content(transmute([]u8)strings.clone("abcdef\nabc\na\n"), "", .UTF8)
				d.wrap = false
				d.block = true
				d.block_anchor_line_start, d.block_anchor_cell = 0, 3
				d.block_cursor_line_start, d.block_cursor_cell = 11, 3 // "a"'s own line start
				u0 := len(d.undo)
				command_dispatch(resolve_key(.Backspace, false, false, .Editor), {.Backspace, false, false, false}, &aa, &adummy, t, 10)
				bs := doc_debug_string(d)
				// "a" (row 2) has nothing at cell 2, so it is untouched -- and the
				// rectangle is left at cell 2 for the next press.
				cBS := bs == "abdef\nab\na\n" && len(d.undo) == u0 + 1 && block_active(d) && d.block_cursor_cell == 2

				// Backspace twice more walks the column left to 0, then a third press
				// must do nothing at all -- no join, no undo entry.
				command_dispatch(resolve_key(.Backspace, false, false, .Editor), {.Backspace, false, false, false}, &aa, &adummy, t, 10)
				command_dispatch(resolve_key(.Backspace, false, false, .Editor), {.Backspace, false, false, false}, &aa, &adummy, t, 10)
				at0 := doc_debug_string(d)
				u1 := len(d.undo)
				command_dispatch(resolve_key(.Backspace, false, false, .Editor), {.Backspace, false, false, false}, &aa, &adummy, t, 10)
				cZero := doc_debug_string(d) == at0 && len(d.undo) == u1 && d.block_cursor_cell == 0
				app_destroy(&aa)

				// Delete forward, on its own document: cell 0 of every row, and the
				// second row is a single character -- deleting it must leave an empty
				// line, never pull the following line up.
				fdoc := doc_from_content(transmute([]u8)strings.clone("abc\nx\n"), "", .UTF8)
				defer doc_close(&fdoc)
				fdoc.wrap = false
				fdoc.block = true
				fdoc.block_anchor_line_start, fdoc.block_anchor_cell = 0, 0
				fdoc.block_cursor_line_start, fdoc.block_cursor_cell = 4, 0
				okf := block_delete(&fdoc, t, true)
				fwd := doc_debug_string(&fdoc)
				cFwd := okf && fwd == "bc\n\n" && fdoc.block_cursor_cell == 0

				// A rectangle WITH width: Delete removes it and leaves the rectangle
				// live and zero-width at its left edge, so typing continues there.
				wdoc := doc_from_content(transmute([]u8)strings.clone("abcd\nefgh\n"), "", .UTF8)
				defer doc_close(&wdoc)
				wdoc.wrap = false
				wdoc.block = true
				wdoc.block_anchor_line_start, wdoc.block_anchor_cell = 0, 1
				wdoc.block_cursor_line_start, wdoc.block_cursor_cell = 5, 3
				okw := block_delete(&wdoc, t, false)
				wide := doc_debug_string(&wdoc)
				cWide := okw && wide == "ad\neh\n" && block_active(&wdoc) && wdoc.block_anchor_cell == 1 && wdoc.block_cursor_cell == 1

				cAA := cBS && cZero && cFwd && cWide
				fmt.printfln(
					"  %-6s delete: backspace across the column=%q (want %q) col-0 press is a no-op=%v forward=%q (want %q) width-rectangle=%q (want %q)",
					"ok" if cAA else "FAIL",
					bs,
					"abdef\\nab\\na\\n",
					cZero,
					fwd,
					"bc\\n\\n",
					wide,
					"ad\\neh\\n",
				)
				return cAA
			}
			if !block_test_aa(&t) {fail = true}

			// AB: CRLF. block_row_end now peels the trailing CR with pt_row_vis_end
			// -- the tree's single definition of where a row's content stops -- so a
			// rectangle running past the end of a CRLF row covers the row's real
			// content and nothing else. Before that, row_end was the '\n' itself, so
			// the CR sat inside the rectangle as a phantom cell and a column delete
			// took half the line break with it: a bare LF in an otherwise-CRLF file,
			// which is exactly the corruption doc_insert_newline and pt_crlf_at
			// already exist to prevent one layer down. Sabotage: restore
			// block_row_end to `pt_line_end_cap` alone and this must FAIL.
			block_test_ab :: proc(t: ^plat.Text) -> bool {
				bdoc := doc_from_content(transmute([]u8)strings.clone("ab\r\ncd\r\n"), "", .UTF8)
				defer doc_close(&bdoc)
				bdoc.wrap = false
				bdoc.block = true
				bdoc.block_anchor_line_start, bdoc.block_anchor_cell = 0, 1
				bdoc.block_cursor_line_start, bdoc.block_cursor_cell = 4, 5 // past both rows' ends
				okb := block_delete(&bdoc, t, false)
				got := doc_debug_string(&bdoc)
				cAB := okb && got == "a\r\nc\r\n"
				fmt.printfln("  %-6s crlf: a column delete past the end of a CRLF row keeps the CR: got=%q (want %q)", "ok" if cAB else "FAIL", got, "a\\r\\nc\\r\\n")
				return cAB
			}
			if !block_test_ab(&t) {fail = true}

			// AC: the EDIT's own cost at the cap. Same fixture as R (the cut's
			// measurement) so the two numbers are comparable: 18-byte log lines,
			// ~1.8 MB, a rectangle of exactly BLOCK_EDIT_MAX_LINES rows starting at
			// row 45,000, over cells [11,15) -- "INFO" -- replaced by "WARN!" so
			// every row both deletes and inserts, and the rows change length (the
			// edit's real worst case, and strictly more work than R's delete).
			// BLOCK_EDIT_MAX_LINES was chosen against the DELETE's numbers, so this
			// is the case that has to justify it for the edit.
			//
			// THRESHOLD, retightened (whole-branch review LOW 5) for the same
			// reason R's was: 80ms was sized against a 10,000-row cap and left
			// stranded by two cap reductions, so a regression back to 2,000 rows
			// slipped straight through it. Re-measured, DEBUG build:
			//
			//   cap 300 (shipping):   1.37, 1.37, 1.38, 1.39, 1.41, 1.42, 1.44 ms
			//   cap 2,000 (the regression this must catch): 10.33 ms
			//
			// Same 6ms bound as R's, not a larger one. The edit is in principle
			// more work than the cut (it deletes AND inserts, and the rows change
			// length), but at this cap the two measure the same to within noise --
			// both are dominated by the per-row splice -- so giving this case a
			// looser bound would only weaken it for a distinction the meter does
			// not actually show.
			block_test_ac :: proc(t: ^plat.Text) -> bool {
				line := "2026-07-26 INFO x\n" // 18 bytes; "INFO" is cells [11,15)
				nrows := 100_000
				cb := strings.builder_make(context.temp_allocator)
				for _ in 0 ..< nrows {strings.write_string(&cb, line)}
				cdoc := doc_from_content(transmute([]u8)strings.clone(strings.to_string(cb)), "", .UTF8)
				defer doc_close(&cdoc)
				cdoc.wrap = false
				off := 45_000 * len(line)
				cdoc.block = true
				cdoc.block_anchor_line_start, cdoc.block_anchor_cell = off, 11
				cdoc.block_cursor_line_start, cdoc.block_cursor_cell = off + (BLOCK_EDIT_MAX_LINES - 1) * len(line), 15
				start := time.now()
				okc := block_replace(&cdoc, t, transmute([]u8)string("WARN!"))
				ms := time.duration_milliseconds(time.since(start))
				cAC := okc && ms < 6
				fmt.printfln(
					"  %-6s cost: replacing a %d-row rectangle at the cap costs a bounded amount: ok=%v elapsed=%.2fms (want <6ms)",
					"ok" if cAC else "FAIL",
					BLOCK_EDIT_MAX_LINES,
					okc,
					ms,
				)
				return cAC
			}
			if !block_test_ac(&t) {fail = true}

			// AD: MEDIUM re-derivation -- a HELD KEY, not a single press, is the
			// real cost this cap has to bound. Every press of block_replace over a
			// live rectangle splices the SAME rows again, fragmenting the piece
			// tree further, so the cap's own cost test measuring only press #0 (R
			// and AC above) could never see a held key degrade: the reviewer's own
			// numbers at the old 2,000-row cap climbed from 7.9ms at press 1 past
			// 70ms by press 20, still rising. This measures press 20 specifically
			// -- a sustained-but-not-extreme held key -- against the same fixture
			// R and AC use.
			//
			// The 50ms threshold is NOT the ~25ms release-build frame budget
			// BLOCK_EDIT_MAX_LINES's own comment derives 300 from -- this headless
			// mode normally runs as a DEBUG build day to day, and debug measured
			// noticeably slower per splice (31.8ms debug vs 8.2ms release at this
			// cap on the machine that derived these numbers). 50ms clears debug's
			// real number with margin while still sitting well below what press 20
			// costs at the OLD 2,000-row cap in EITHER build (76.3ms release /
			// 318.8ms debug) -- see BLOCK_EDIT_MAX_LINES's own comment for the
			// full cross-build table this was chosen against.
			//
			// Sabotage (per task): raise BLOCK_EDIT_MAX_LINES back to 2,000 (or
			// any cap the comment's own curve shows crossing budget by press 20)
			// and this must FAIL.
			block_test_ad :: proc(t: ^plat.Text) -> bool {
				line := "2026-07-26 INFO x\n" // 18 bytes; same fixture as R/AC
				nrows := 100_000
				mb := strings.builder_make(context.temp_allocator)
				for _ in 0 ..< nrows {strings.write_string(&mb, line)}
				mdoc := doc_from_content(transmute([]u8)strings.clone(strings.to_string(mb)), "", .UTF8)
				defer doc_close(&mdoc)
				mdoc.wrap = false
				off := 45_000 * len(line)
				mdoc.block = true
				mdoc.block_anchor_line_start, mdoc.block_anchor_cell = off, 0
				mdoc.block_cursor_line_start, mdoc.block_cursor_cell = off + (BLOCK_EDIT_MAX_LINES - 1) * len(line), 0

				steady_press := 20
				ms20 := 0.0
				okall := true
				for press in 1 ..= steady_press {
					start := time.now()
					ok := block_replace(&mdoc, t, transmute([]u8)string("x"))
					elapsed := time.duration_milliseconds(time.since(start))
					okall &= ok
					if press == steady_press {ms20 = elapsed}
				}
				cAD := okall && ms20 < 50
				fmt.printfln(
					"  %-6s MEDIUM (re-derived): a HELD KEY's press #%d over a %d-row rectangle stays inside the frame budget: elapsed=%.2fms (want <50ms)",
					"ok" if cAD else "FAIL",
					steady_press,
					BLOCK_EDIT_MAX_LINES,
					ms20,
				)
				return cAD
			}
			if !block_test_ad(&t) {fail = true}

			// AE: HIGH -- a stale rectangle must not survive a Replace All that
			// leaves NO matches, because find.odin's own incidental clear
			// (find_merge -> find_select_current, on jumping to the next match)
			// only fires while matches remain. Reviewer's exact probe: rows 1-2 of
			// a 4-row buffer, rectangle over cells [0,4), Replace All "Q" ->
			// "ZZZZZZ" -- the one match sits on row 0, outside the rectangle
			// entirely, and disappears once replaced. Both block_active AND
			// block_text are asserted: block_active alone would pass even if the
			// geometry fields were merely stale rather than truly cleared, and
			// block_text is what Ctrl+C/Ctrl+X actually read, which is the
			// concrete damage this finding described.
			//
			// Sabotage (per task): remove the `if block_active(doc)
			// {block_clear(doc)}` line from find_replace_all (find.odin) and this
			// must FAIL -- block_active reads true and block_text still returns
			// the 3 stale rows.
			block_test_ae :: proc(t: ^plat.Text) -> bool {
				edoc := doc_from_content(transmute([]u8)strings.clone("aaaaQaaaa\nbbbbbbbbbb\ncccccccccc\ndddddddddd\n"), "", .UTF8)
				defer doc_close(&edoc)
				edoc.wrap = false
				find_open(&edoc, true)
				for r in "Q" {find_input_rune(&edoc, r)}
				edoc.find.field = 1
				for r in "ZZZZZZ" {find_input_rune(&edoc, r)}
				edoc.find.field = 0
				find_wait(&edoc)
				matches_before := len(edoc.find.matches)

				edoc.block = true
				edoc.block_anchor_line_start, edoc.block_anchor_cell = 10, 0 // "bbbbbbbbbb\n"'s own line start
				edoc.block_cursor_line_start, edoc.block_cursor_cell = 21, 4 // "cccccccccc\n"'s own line start
				find_replace_all(&edoc)
				find_wait(&edoc)

				after := doc_debug_string(&edoc)
				etxt, etok := block_text(&edoc, t)
				cAE :=
					matches_before == 1 &&
					after == "aaaaZZZZZZaaaa\nbbbbbbbbbb\ncccccccccc\ndddddddddd\n" &&
					!block_active(&edoc) &&
					!etok &&
					etxt == ""
				fmt.printfln(
					"  %-6s HIGH: Replace All that leaves zero matches drops the rectangle -- block_active=%v block_text_ok=%v block_text=%q content=%q",
					"ok" if cAE else "FAIL",
					block_active(&edoc),
					etok,
					etxt,
					after,
				)
				return cAE
			}
			if !block_test_ae(&t) {fail = true}

			// AF: LOW 1 -- Backspace over a multi-cell rune (a leading tab) must
			// land the rectangle at the column the deletion actually reached, not
			// cell_lo-1. Reviewer's exact probe: "\tabc\n\tdef\n", rectangle at
			// cell 4 (zero-width, both rows identical) -- the tab starts at
			// column 0 so it is 4 cells wide, and deleting it drops the
			// rectangle back to column 0, not column 3. A stale column 3 would pad three stray spaces onto every
			// row on the very next keystroke.
			//
			// Sabotage (per task): restore `new_cell` to a flat `cell_lo - 1` in
			// block_delete (block.odin) and this must FAIL -- block_cursor_cell
			// reads 3, not 0.
			block_test_af :: proc(t: ^plat.Text) -> bool {
				fdoc := doc_from_content(transmute([]u8)strings.clone("\tabc\n\tdef\n"), "", .UTF8)
				defer doc_close(&fdoc)
				fdoc.wrap = false
				fdoc.block = true
				fdoc.block_anchor_line_start, fdoc.block_anchor_cell = 0, 4
				fdoc.block_cursor_line_start, fdoc.block_cursor_cell = 5, 4 // "\tdef\n"'s own line start
				okf := block_delete(&fdoc, t, false)
				got := doc_debug_string(&fdoc)
				cAF :=
					okf &&
					got == "abc\ndef\n" &&
					fdoc.block_anchor_cell == 0 &&
					fdoc.block_cursor_cell == 0
				fmt.printfln(
					"  %-6s LOW 1: backspace over a leading tab lands the rectangle at column 0, not cell_lo-1=3: content=%q (want %q) anchor_cell=%d cursor_cell=%d (want 0,0)",
					"ok" if cAF else "FAIL",
					got,
					"abc\\ndef\\n",
					fdoc.block_anchor_cell,
					fdoc.block_cursor_cell,
				)
				return cAF
			}
			if !block_test_af(&t) {fail = true}

			// AG: LOW 1 -- same off-by-(w-1) for a CJK rune (2 cells). "你abc\n",
			// rectangle at cell 2 (right after 你, zero-width) -- Backspace must
			// delete the whole 3-byte rune and drop the rectangle to column 0,
			// not column 1 (cell_lo-1).
			//
			// Sabotage: same as AF -- restore the flat `cell_lo - 1` and this must
			// FAIL (cursor_cell reads 1, not 0).
			block_test_ag :: proc(t: ^plat.Text) -> bool {
				gdoc := doc_from_content(transmute([]u8)strings.clone("你abc\n"), "", .UTF8)
				defer doc_close(&gdoc)
				gdoc.wrap = false
				gdoc.block = true
				gdoc.block_anchor_line_start, gdoc.block_anchor_cell = 0, 2
				gdoc.block_cursor_line_start, gdoc.block_cursor_cell = 0, 2
				okg := block_delete(&gdoc, t, false)
				got := doc_debug_string(&gdoc)
				cAG :=
					okg &&
					got == "abc\n" &&
					gdoc.block_anchor_cell == 0 &&
					gdoc.block_cursor_cell == 0
				fmt.printfln(
					"  %-6s LOW 1: backspace over a CJK rune lands the rectangle at column 0, not cell_lo-1=1: content=%q (want %q) anchor_cell=%d cursor_cell=%d (want 0,0)",
					"ok" if cAG else "FAIL",
					got,
					"abc\\n",
					gdoc.block_anchor_cell,
					gdoc.block_cursor_cell,
				)
				return cAG
			}
			if !block_test_ag(&t) {fail = true}

			// AH: WHOLE-BRANCH HIGH 1 -- a rectangle and a linear selection must
			// never both be live, because only ONE of them is drawn. main.odin
			// picks block_selection_rects when block_active(doc) and
			// doc_selection_rects otherwise, so a linear span coexisting with a
			// rectangle is INVISIBLE -- and every mutating command that drops the
			// rectangle (.Insert_Newline, .Paste, .Delete_Word_Back,
			// .Move_Line_*) then runs against doc.anchor..doc.cursor, where
			// doc_insert_text deletes the selection first. (.Insert_Tab no longer
			// drops the rectangle at all -- it edits it, like a typed character.)
			//
			// Both gestures are exercised because both used to leave one behind
			// and the fix is at both ends (block_collapse_linear, block.odin):
			//
			//   MOUSE  -- main.odin sets doc.cursor to the pointer on every drag
			//             frame while doc.anchor stays at the press point, then
			//             calls block_set_from_points. Reviewer's reproduction:
			//             Alt+drag a rectangle down 50 lines, press Ctrl+V, and
			//             all 50 lines are replaced by the clipboard.
			//   KEYBOARD -- Shift-select text (a real, visible linear span), then
			//             Alt+Shift+Right, then Enter.
			//
			// The damage half is dispatched through the real command table so it
			// crosses commands.odin's block-clear branch exactly as a keystroke
			// does, rather than asserting on the anchor alone -- an anchor is only
			// interesting because of what the next command does with it.
			//
			// Sabotage (per task): remove the block_collapse_linear call from
			// block_set_from_points and this must FAIL -- Enter deletes bytes
			// 0..17 instead of inserting one line break at the caret.
			block_test_ah :: proc(t: ^plat.Text) -> bool {
				ha: App
				hdummy: plat.Window
				app_new_scratch(&ha)
				hd := app_active(&ha)
				doc_close(hd)
				hd^ = doc_from_content(transmute([]u8)strings.clone("aaaa\nbbbb\ncccc\ndddd\n"), "", .UTF8)
				hd.wrap = false

				// MOUSE: press at byte 0, drag to byte 17 (row 3, cell 2). The
				// press set doc.anchor and every drag frame sets doc.cursor.
				hd.anchor, hd.cursor = 0, 17
				mouse_refusal := block_set_from_points(hd, t, 0, 0, 15, 4) // rows 0..15, cells 0..4
				mouse_collapsed := hd.anchor == hd.cursor && hd.cursor == 17

				// The damage: Enter, through the real dispatcher.
				command_dispatch(resolve_key(.Enter, false, false, .Editor), {.Enter, false, false, false}, &ha, &hdummy, t, 10)
				after_enter := doc_debug_string(hd)

				// KEYBOARD: a genuine Shift-selection (bytes 2..7, visible and
				// intended) followed by one Alt+Shift+Right.
				kd := doc_from_content(transmute([]u8)strings.clone("aaaa\nbbbb\ncccc\n"), "", .UTF8)
				defer doc_close(&kd)
				kd.wrap = false
				kd.anchor, kd.cursor = 2, 7
				key_refusal := block_extend(&kd, t, 0, 1)
				key_collapsed := kd.anchor == kd.cursor && kd.cursor == 7

				cAH :=
					mouse_refusal == .None &&
					block_active(hd) == false && // Enter dropped it, as it always did
					mouse_collapsed &&
					after_enter == "aaaa\nbbbb\ncccc\ndd\ndd\n" &&
					key_refusal == .None &&
					block_active(&kd) &&
					key_collapsed
				fmt.printfln(
					"  %-6s HIGH 1: a block gesture leaves no linear selection, so Enter inserts instead of replacing: mouse_refusal=%v anchor==cursor=%v content=%q (want %q) key_refusal=%v key_anchor=%d key_cursor=%d (want 7,7)",
					"ok" if cAH else "FAIL",
					mouse_refusal,
					mouse_collapsed,
					after_enter,
					"aaaa\\nbbbb\\ncccc\\ndd\\ndd\\n",
					key_refusal,
					kd.anchor,
					kd.cursor,
				)
				app_destroy(&ha)
				return cAH
			}
			if !block_test_ah(&t) {fail = true}

			// AI: WHOLE-BRANCH HIGH 1, the other half -- Paste specifically, the
			// command the reviewer's own reproduction used. Separate from AH
			// because it needs the real Windows clipboard (a set/get round trip in
			// this same process): blocktest already writes the clipboard in the
			// LOW 3 Cut case above, so this adds no new side effect, but keeping it
			// out of AH means a clipboard failure cannot mask the keyboard half.
			//
			// Sabotage: same as AH -- drop block_collapse_linear from
			// block_set_from_points and Ctrl+V eats bytes 0..17.
			block_test_ai :: proc(t: ^plat.Text) -> bool {
				pa: App
				pdummy: plat.Window
				app_new_scratch(&pa)
				pd := app_active(&pa)
				doc_close(pd)
				pd^ = doc_from_content(transmute([]u8)strings.clone("aaaa\nbbbb\ncccc\ndddd\n"), "", .UTF8)
				pd.wrap = false
				pd.anchor, pd.cursor = 0, 17
				refusal := block_set_from_points(pd, t, 0, 0, 15, 4)

				// This case needs a genuine clipboard set/get round trip in-process --
				// Ctrl+V has to read back real CF_UNICODETEXT -- but
				// plat.clipboard_set_text writes the REAL Windows clipboard; there is
				// no test-double seam for it. Left unguarded, every blocktest run
				// silently replaced whatever the user had copied with "PP" (a
				// live-pass finding: Wyatt hit Ctrl+V afterward and got this
				// fixture's text back instead of his own). Save it now and restore
				// on every exit path, including a failing assertion below -- the
				// defer runs regardless of how this proc returns. If the clipboard
				// held something other than CF_UNICODETEXT, or was empty,
				// clipboard_get_text reports ok=false and there is nothing to
				// restore: leaving the clipboard as this test left it is acceptable
				// in that case, corrupting it with a blank string is not, so the
				// defer below does nothing rather than writing "" over content it
				// never understood.
				saved_clip, had_clip := plat.clipboard_get_text(pdummy.hwnd, context.allocator)
				defer if had_clip {
					plat.clipboard_set_text(pdummy.hwnd, saved_clip)
					delete(saved_clip)
				}

				plat.clipboard_set_text(pdummy.hwnd, "PP")
				command_dispatch(resolve_key(.V, true, false, .Editor), {.V, true, false, false}, &pa, &pdummy, t, 10)
				after := doc_debug_string(pd)

				cAI := refusal == .None && after == "aaaa\nbbbb\ncccc\nddPPdd\n"
				fmt.printfln(
					"  %-6s HIGH 1: Ctrl+V with a rectangle active does not delete a linear span: refusal=%v content=%q (want %q)",
					"ok" if cAI else "FAIL",
					refusal,
					after,
					"aaaa\\nbbbb\\ncccc\\nddPPdd\\n",
				)
				app_destroy(&pa)
				return cAI
			}
			if !block_test_ai(&t) {fail = true}

			// AJ: WHOLE-BRANCH HIGH 2 -- table view bypassed every stale-rectangle
			// guard. command_dispatch returns EARLY for mutating commands while
			// doc.table is set, before it reaches the block-clear branch, and cell
			// editing is intercepted before dispatch entirely (main.odin) yet
			// splices the buffer through doc_replace_range (table_edit_commit).
			// Reviewer's reproduction: Alt+drag on a CSV, Ctrl+T, edit a cell,
			// Ctrl+T back, Ctrl+X -- and the cut took bytes never highlighted.
			// Identical shape to the find_replace_all hole fixed earlier on this
			// branch.
			//
			// Both new clears are asserted, because either alone leaves a route
			// in: .Toggle_Table's (the seam) and table_edit_commit's (the actual
			// write). The second is checked by re-seeding a rectangle while
			// already inside table view -- exactly the state the toggle's own
			// clear cannot reach.
			//
			// Sabotage (per task): remove either clear and this must FAIL.
			block_test_aj :: proc(t: ^plat.Text) -> bool {
				ja: App
				jdummy: plat.Window
				app_new_scratch(&ja)
				jd := app_active(&ja)
				doc_close(jd)
				jd^ = doc_from_content(transmute([]u8)strings.clone("a,bb,c\nd,ee,f\n"), "", .UTF8)
				jd.wrap = false
				jd.block = true
				jd.block_anchor_line_start, jd.block_anchor_cell = 0, 0
				jd.block_cursor_line_start, jd.block_cursor_cell = 7, 4 // "d,ee,f\n"'s own line start

				command_dispatch(resolve_key(.T, true, false, .Editor), {.T, true, false, false}, &ja, &jdummy, t, 10) // Ctrl+T
				in_table := jd.table
				toggle_cleared := !block_active(jd)

				// Now the choke point: a rectangle live INSIDE table view, which
				// the toggle's own clear can no longer reach, and a cell edit
				// that splices the buffer under it.
				jd.block = true
				jd.block_anchor_line_start, jd.block_anchor_cell = 0, 0
				jd.block_cursor_line_start, jd.block_cursor_cell = 7, 4
				table_edit_start(jd, 0, 1, 2, 4, "ZZZZ") // field "bb" of row 0 is bytes [2,4)
				table_edit_commit(jd)
				commit_cleared := !block_active(jd)
				spliced := doc_debug_string(jd)

				cAJ := in_table && toggle_cleared && commit_cleared && spliced == "a,ZZZZ,c\nd,ee,f\n"
				fmt.printfln(
					"  %-6s HIGH 2: table view drops the rectangle at BOTH the toggle and the cell-commit splice: in_table=%v toggle_cleared=%v commit_cleared=%v content=%q (want %q)",
					"ok" if cAJ else "FAIL",
					in_table,
					toggle_cleared,
					commit_cleared,
					spliced,
					"a,ZZZZ,c\\nd,ee,f\\n",
				)
				app_destroy(&ja)
				return cAJ
			}
			if !block_test_aj(&t) {fail = true}

			// AK: WHOLE-BRANCH MEDIUM 3 -- Markdown Split turns wrap on
			// (doc_wraps), which changes what a rectangle's (line start, cell)
			// pair means exactly the way Alt+Z does. .Toggle_Wrap has always
			// cleared the block for that reason; .Toggle_Preview did not, and the
			// four block operations guarded only on doc.filter, never on wrap. A
			// rectangle carried into Split is DRAWN against visual rows and EDITED
			// against logical lines, which diverge past the first wrap point.
			//
			// Two halves, matching the two-sided fix: the toggle clears (the
			// Preview -> Split transition specifically, the one that turns wrap
			// on), and all four operations refuse under doc_wraps even when
			// something else leaves a rectangle live there.
			//
			// Sabotage (per task): remove the clear from .Toggle_Preview, or drop
			// doc_wraps from block_stale_view (block.odin), and this must FAIL.
			block_test_ak :: proc(t: ^plat.Text) -> bool {
				ma: App
				mdummy: plat.Window
				app_new_scratch(&ma)
				md := app_active(&ma)
				doc_close(md)
				md^ = doc_from_content(transmute([]u8)strings.clone("aaaa\nbbbb\ncccc\n"), "", .UTF8)
				md.wrap = false
				md.md_mode = .Preview // one Ctrl+M from Split, the wrap-on transition
				md.block = true
				md.block_anchor_line_start, md.block_anchor_cell = 0, 0
				md.block_cursor_line_start, md.block_cursor_cell = 10, 4

				command_dispatch(resolve_key(.M, true, false, .Editor), {.M, true, false, false}, &ma, &mdummy, t, 10) // Ctrl+M
				in_split := md.md_mode == .Split
				toggle_cleared := !block_active(md)

				// The guards: re-seed a rectangle with Split (and therefore
				// doc_wraps) already on, and every operation must refuse.
				md.block = true
				md.block_anchor_line_start, md.block_anchor_cell = 0, 0
				md.block_cursor_line_start, md.block_cursor_cell = 10, 4
				wraps := doc_wraps(md)
				_, copy_ok := block_text(md, t)
				cut_ok := block_cut_delete(md, t)
				edit_ok := block_replace(md, t, transmute([]u8)string("X"))
				q: [8]plat.Quad
				nq := block_selection_rects(md, t, 16, plat.text_char_width(t, 16, .Doc), 3, q[:])
				intact := doc_debug_string(md)

				cAK :=
					in_split &&
					toggle_cleared &&
					wraps &&
					!copy_ok &&
					!cut_ok &&
					!edit_ok &&
					nq == 0 &&
					intact == "aaaa\nbbbb\ncccc\n"
				fmt.printfln(
					"  %-6s MEDIUM 3: Split clears the rectangle and all four block ops refuse under wrap: in_split=%v cleared=%v wraps=%v copy_ok=%v cut_ok=%v edit_ok=%v quads=%d (want 0) content=%q",
					"ok" if cAK else "FAIL",
					in_split,
					toggle_cleared,
					wraps,
					copy_ok,
					cut_ok,
					edit_ok,
					nq,
					intact,
				)
				app_destroy(&ma)
				return cAK
			}
			if !block_test_ak(&t) {fail = true}

			// AL: WHOLE-BRANCH LOW 4 -- the filter clear and the four doc.filter
			// guards had no test at all. Ctrl+L's clear is load-bearing (filter
			// view's rows are a non-contiguous subset of the document's lines,
			// while every block operation walks the buffer's own logical lines),
			// and the guards inside block.odin are its second line of defence.
			// Same shape as AK, one view toggle over.
			//
			// Sabotage: remove `if block_active(doc) {block_clear(doc)}` from
			// .Find_Toggle_Filter, or drop doc.filter from block_stale_view, and
			// this must FAIL.
			block_test_al :: proc(t: ^plat.Text) -> bool {
				la: App
				ldummy: plat.Window
				app_new_scratch(&la)
				ld := app_active(&la)
				doc_close(ld)
				ld^ = doc_from_content(transmute([]u8)strings.clone("aaaa\nbbbb\ncccc\n"), "", .UTF8)
				ld.wrap = false
				find_open(ld, false) // Ctrl+L is bound in the .Find context
				ld.block = true
				ld.block_anchor_line_start, ld.block_anchor_cell = 0, 0
				ld.block_cursor_line_start, ld.block_cursor_cell = 10, 4

				command_dispatch(resolve_key(.L, true, false, .Find), {.L, true, false, false}, &la, &ldummy, t, 10) // Ctrl+L
				filtering := ld.filter
				toggle_cleared := !block_active(ld)

				ld.block = true
				ld.block_anchor_line_start, ld.block_anchor_cell = 0, 0
				ld.block_cursor_line_start, ld.block_cursor_cell = 10, 4
				_, copy_ok := block_text(ld, t)
				cut_ok := block_cut_delete(ld, t)
				edit_ok := block_replace(ld, t, transmute([]u8)string("X"))
				q: [8]plat.Quad
				nq := block_selection_rects(ld, t, 16, plat.text_char_width(t, 16, .Doc), 3, q[:])
				intact := doc_debug_string(ld)

				cAL :=
					filtering &&
					toggle_cleared &&
					!copy_ok &&
					!cut_ok &&
					!edit_ok &&
					nq == 0 &&
					intact == "aaaa\nbbbb\ncccc\n"
				fmt.printfln(
					"  %-6s LOW 4: Ctrl+L clears the rectangle and all four block ops refuse under filter: filtering=%v cleared=%v copy_ok=%v cut_ok=%v edit_ok=%v quads=%d (want 0) content=%q",
					"ok" if cAL else "FAIL",
					filtering,
					toggle_cleared,
					copy_ok,
					cut_ok,
					edit_ok,
					nq,
					intact,
				)
				app_destroy(&la)
				return cAL
			}
			if !block_test_al(&t) {fail = true}

			// AM: WHOLE-BRANCH LOW 7 -- the Alt+drag gesture's latches moved out of
			// main.odin's frame loop into Block_Drag / block_drag_press /
			// block_drag_update (block.odin). The fold was required to be
			// behaviour-preserving, and this is what says so: as four inline
			// locals in the frame loop none of this could be driven headlessly at
			// all (there is no seam to simulate a real WM_LBUTTONDOWN), so the
			// once-per-gesture note latch in particular was previously untestable.
			// Getting a seam out of the move is the point of having made it.
			//
			// Four properties, all of them things the inline code did:
			//   - a press clears the previous gesture's rectangle whether or not
			//     Alt is held (block_press_clear's own rule, one layer up);
			//   - a NON-Alt drag frame costs nothing and creates nothing;
			//   - a refused gesture reports note=true exactly once however many
			//     drag frames follow -- app_note does a delete plus a
			//     strings.clone per call, which is why the latch exists;
			//   - a successful drag builds the rectangle AND leaves no linear
			//     selection behind it (HIGH 1, through the real gesture entry
			//     point rather than block_set_from_points directly).
			block_test_am :: proc(t: ^plat.Text) -> bool {
				gd := doc_from_content(transmute([]u8)strings.clone("aaaa\nbbbb\ncccc\n"), "", .UTF8)
				defer doc_close(&gd)
				gd.wrap = false

				// A press with Alt NOT held still drops the last rectangle.
				gd.block = true
				gd.block_anchor_line_start, gd.block_anchor_cell = 0, 1
				gd.block_cursor_line_start, gd.block_cursor_cell = 5, 3
				drag: Block_Drag
				gd.cursor, gd.anchor = 0, 0
				block_drag_press(&drag, &gd, false, 0)
				plain_cleared := !block_active(&gd) && !drag.alt

				// A non-Alt drag frame commits the cursor to the pointer -- same as a
				// plain drag has always tracked it -- but does nothing else: no row
				// resolve, no rectangle write.
				r_plain, n_plain := block_drag_update(&drag, &gd, t, 12, 2)
				plain_inert := r_plain == .None && !n_plain && !block_active(&gd) && gd.cursor == 12

				// An Alt press latches the anchor corner at the caret's own row.
				gd.cursor, gd.anchor = 2, 2
				block_drag_press(&drag, &gd, true, 2)
				latched := drag.alt && drag.anchor_off == 0 && drag.anchor_cell == 2

				// A refused gesture (wrap on) notes once, not per frame, AND --
				// live-pass HIGH -- must not degrade into a linear selection.
				// block_drag_update now owns the cursor commit itself (block.odin):
				// before this fix, main.odin set doc.cursor to the pointer BEFORE
				// checking the refusal, so a refused Alt-drag still tracked the
				// pointer every frame. Passing cursor_at=12 (the pointer, three
				// frames running) must leave gd.cursor pinned at 2 -- exactly where
				// the press left it -- not slide to 12.
				gd.wrap = true
				r1, n1 := block_drag_update(&drag, &gd, t, 12, 4)
				r2, n2 := block_drag_update(&drag, &gd, t, 12, 4)
				r3, n3 := block_drag_update(&drag, &gd, t, 12, 4)
				noted_once := r1 == .Wrap_On && n1 && r2 == .Wrap_On && !n2 && r3 == .Wrap_On && !n3
				pinned_cursor, pinned_anchor := gd.cursor, gd.anchor // snapshot -- gd moves again below
				cursor_pinned := pinned_cursor == 2 && pinned_anchor == 2

				// A successful drag: rectangle built, no linear selection under it.
				gd.wrap = false
				gd.cursor, gd.anchor = 2, 2
				block_drag_press(&drag, &gd, true, 2)
				r_ok, n_ok := block_drag_update(&drag, &gd, t, 12, 4) // pointer now on row 2; anchor stays where it was pressed
				built :=
					r_ok == .None &&
					!n_ok &&
					block_active(&gd) &&
					gd.block_anchor_line_start == 0 &&
					gd.block_anchor_cell == 2 &&
					gd.block_cursor_line_start == 10 &&
					gd.block_cursor_cell == 4 &&
					gd.anchor == gd.cursor

				cAM := plain_cleared && plain_inert && latched && noted_once && cursor_pinned && built
				fmt.printfln(
					"  %-6s LOW 7 + HIGH (live pass): the folded Alt+drag latches behave as the inline ones did, and a refused drag leaves no linear selection: plain_press_cleared=%v plain_drag_inert=%v anchor_latched=%v(off=%d cell=%d) noted_once=%v(%v,%v,%v) cursor_pinned=%v(anchor=%d cursor=%d) built=%v(anchor=%d cursor=%d)",
					"ok" if cAM else "FAIL",
					plain_cleared,
					plain_inert,
					latched,
					drag.anchor_off,
					drag.anchor_cell,
					noted_once,
					n1,
					n2,
					n3,
					cursor_pinned,
					pinned_anchor,
					pinned_cursor,
					built,
					gd.anchor,
					gd.cursor,
				)
				return cAM
			}
			if !block_test_am(&t) {fail = true}

			// AN: LIVE PASS -- block_test_ai (HIGH 1's other half, above) needs a
			// genuine set/get round trip against the REAL Windows clipboard to
			// prove Paste no longer eats a linear span. Before this fix it wrote
			// "PP" over the clipboard and never put back what was there, so every
			// blocktest run silently replaced whatever the user had copied. Seed a
			// sentinel standing in for "the user's real clipboard content", run
			// block_test_ai (which now saves/restores around its own "PP" write),
			// and confirm the sentinel -- not "PP" -- is what's left afterward.
			// No App/Document needed here -- block_test_ai owns its own -- which
			// keeps this proc's own stack frame small; see block_test_ao's own
			// comment for why that matters at this depth.
			//
			// Sabotage (per task): remove the `defer if had_clip {...}` restore
			// from block_test_ai and this must FAIL, reporting "PP".
			//
			// This proc used to write `sentinel` over the clipboard with no
			// save/restore of its own -- that was the HIGH finding a later
			// review caught: the mode-level save/restore now protects the real
			// user clipboard regardless, but this proc still cleans up after
			// itself (saving whatever was there -- the mode's own seam
			// sentinel, if nothing upstream leaked -- before overwriting it,
			// and restoring that on the way out) so it doesn't leave `sentinel`
			// sitting in the clipboard for the mode's seam-proof check at the
			// very end to trip over.
			block_test_an :: proc(t: ^plat.Text) -> bool {
				ndummy: plat.Window
				sentinel := "USER'S REAL CLIPBOARD CONTENT - DO NOT LOSE"
				nsaved_clip, nhad_clip := plat.clipboard_get_text(ndummy.hwnd, context.allocator)
				defer if nhad_clip {
					plat.clipboard_set_text(ndummy.hwnd, nsaved_clip)
					delete(nsaved_clip)
				}
				plat.clipboard_set_text(ndummy.hwnd, sentinel)
				_ = block_test_ai(t) // exercises the real clipboard round trip
				after, ok := plat.clipboard_get_text(ndummy.hwnd, context.temp_allocator)
				cAN := ok && after == sentinel
				fmt.printfln(
					"  %-6s LIVE PASS: blocktest's clipboard round trip restores what was there before, not \"PP\": got=%q (want %q)",
					"ok" if cAN else "FAIL",
					after,
					sentinel,
				)
				return cAN
			}
			if !block_test_an(&t) {fail = true}

			// AO/AP: LIVE PASS, split across TWO procs rather than one -- the wrap
			// refusal used to post the same "[COLUMN SELECT NEEDS WRAP OFF -
			// press Alt+Z]" note for BOTH causes doc_wraps covers, but Alt+Z does
			// nothing at all in Markdown Split -- Ctrl+M is the control that turns
			// it off. Each proc drives ONE cause through the real dispatcher
			// (resolve_key -> command_dispatch -> block_extend_dispatch,
			// commands.odin) with exactly one App/Document, matching the size of
			// every other proc in this file. Putting both causes' Apps in one
			// proc (tried first) hit a real STATUS_STACK_OVERFLOW at this call
			// depth -- this file is one enormous procedure, and two Apps live at
			// once in a single frame was enough to run it out, even though the
			// exact same two Apps, one per call, are not. Compare the two notes
			// via app.notice so the test survives across the two separate calls.
			//
			// Sabotage (per task): fold Split_On back into Wrap_On (either in
			// block_wrap_refusal, block.odin, or in block_extend_dispatch's
			// switch, commands.odin) and this pair must FAIL, reporting the Alt+Z
			// note for Split too.
			block_test_ao :: proc(t: ^plat.Text) -> (note: string, ok: bool) {
				wa: App
				wdummy: plat.Window
				app_new_scratch(&wa)
				wd := app_active(&wa)
				doc_close(wd)
				wd^ = doc_from_content(transmute([]u8)strings.clone("aaaa\nbbbb\ncccc\n"), "", .UTF8)
				wd.wrap = true // plain word wrap, not Split
				wd.cursor, wd.anchor = 0, 0
				rcmd := resolve_key(.Right, false, true, .Editor) // Alt+Shift+Right
				command_dispatch(rcmd, {.Right, false, true, true}, &wa, &wdummy, t, 10)
				note = strings.clone(wa.notice)
				ok = strings.contains(note, "WRAP OFF") && strings.contains(note, "Alt+Z") && !strings.contains(note, "SPLIT")
				app_destroy(&wa)
				return
			}
			block_test_ap :: proc(t: ^plat.Text) -> (note: string, ok: bool) {
				sa: App
				sdummy: plat.Window
				app_new_scratch(&sa)
				sd := app_active(&sa)
				doc_close(sd)
				sd^ = doc_from_content(transmute([]u8)strings.clone("aaaa\nbbbb\ncccc\n"), "", .UTF8)
				sd.wrap = false
				sd.md_mode = .Split
				sd.cursor, sd.anchor = 0, 0
				rcmd := resolve_key(.Right, false, true, .Editor) // Alt+Shift+Right
				command_dispatch(rcmd, {.Right, false, true, true}, &sa, &sdummy, t, 10)
				note = strings.clone(sa.notice)
				ok = strings.contains(note, "SPLIT OFF") && strings.contains(note, "Ctrl+M") && !strings.contains(note, "Alt+Z")
				app_destroy(&sa)
				return
			}
			wrap_note, cWrapNote := block_test_ao(&t)
			split_note, cSplitNote := block_test_ap(&t)
			cAOAP := cWrapNote && cSplitNote
			fmt.printfln(
				"  %-6s LIVE PASS: word-wrap and Markdown Split get distinct refusal notes naming the right key: wrap=%q split=%q",
				"ok" if cAOAP else "FAIL",
				wrap_note,
				split_note,
			)
			if !cAOAP {fail = true}
			delete(wrap_note)
			delete(split_note)

			// AQ: FEATURE (Wyatt's call) -- Tab now acts across a live rectangle
			// exactly like a typed character does (routes through block_replace),
			// rather than clearing it first the way Enter still deliberately does.
			// A ragged rectangle (rows of different lengths, some shorter than the
			// rectangle's left cell) exercises block_apply's virtual-space padding
			// the same way block_replace's other callers already do. One undo must
			// restore the exact original bytes in one step.
			//
			// Sabotage (per task): drop .Insert_Tab from the exception list in
			// command_dispatch's block-clear branch (commands.odin) and this must
			// FAIL -- Tab would clear the rectangle and insert one tab at the
			// caret instead of one per row.
			block_test_aq :: proc(t: ^plat.Text) -> bool {
				ta: App
				tdummy: plat.Window
				app_new_scratch(&ta)
				td := app_active(&ta)
				doc_close(td)
				// Ragged: row 1 ("b\n") is only 1 cell long, shorter than the
				// rectangle's cell_lo=2, so block_apply must pad it with one
				// virtual space before the tab so all three rows land in the same
				// column. Row starts: row0=0 ("aaaa\n", 5 bytes), row1=5 ("b\n", 2
				// bytes), row2=7 ("cccc\n").
				orig := "aaaa\nb\ncccc\n"
				td^ = doc_from_content(transmute([]u8)strings.clone(orig), "", .UTF8)
				td.wrap = false
				td.anchor, td.cursor = 0, 0
				// Rectangle at cell 2, rows 0..2 (all three lines), zero-width --
				// N carets, so Tab prefixes each row at column 2 rather than
				// replacing a range. a_off/c_off must be real line starts (0, 7).
				refusal := block_set_from_points(td, t, 0, 2, 7, 2)

				tab_cmd := resolve_key(.Tab, false, false, .Editor)
				command_dispatch(tab_cmd, {.Tab, false, false, false}, &ta, &tdummy, t, 10)
				after := doc_debug_string(td)
				want := "aa\taa\nb \t\ncc\tcc\n"

				block_still_active := block_active(td)

				doc_undo(td)
				undone := doc_debug_string(td)

				cAQ := refusal == .None && after == want && block_still_active && undone == orig
				fmt.printfln(
					"  %-6s FEATURE: Tab indents every row of a ragged rectangle in one undo step: refusal=%v after=%q (want %q) block_active_after=%v undo=%q (want %q)",
					"ok" if cAQ else "FAIL",
					refusal,
					after,
					want,
					block_still_active,
					undone,
					orig,
				)
				app_destroy(&ta)
				return cAQ
			}
			if !block_test_aq(&t) {fail = true}

			// A held key over a rectangle used to push one undo entry per press: 20
			// presses was 20 Ctrl+Z, and with UNDO_MAX at 200 a long hold evicted the
			// pre-run state off the end of the stack entirely -- unreachable by any
			// number of undos. Same shape as the Replace All bug in 6i.
			block_test_undo_run :: proc(t: ^plat.Text) -> (bad: int) {
				raw := "alpha\nbravo\ncharlie\n"
				content := make([]u8, len(raw));copy(content, transmute([]u8)raw)
				doc := doc_from_content(content, "", .UTF8)
				defer doc_close(&doc)
				doc.wrap = false
				before := doc_debug_string(&doc)

				doc.block = true
				doc.block_run += 1
				doc.block_anchor_line_start = 0
				doc.block_anchor_cell = 0
				doc.block_cursor_line_start = 12 // "charlie" line start
				doc.block_cursor_cell = 0

				for _ in 0 ..< 5 {block_replace(&doc, t, transmute([]u8)string("x"))}
				one := len(doc.undo) == 1
				fmt.printfln("  %-6s 5 presses over a rectangle = 1 undo entry (got %d)", "ok" if one else "FAIL", len(doc.undo))
				if !one {bad += 1}

				doc_undo(&doc)
				back := doc_debug_string(&doc) == before
				fmt.printfln("  %-6s one undo restores the whole run", "ok" if back else "FAIL")
				if !back {bad += 1}
				return
			}
			if block_test_undo_run(&t) > 0 {fail = true}

			// A re-made rectangle is a new run; an ordinary edit in between breaks it.
			block_test_undo_run_breaks :: proc(t: ^plat.Text) -> (bad: int) {
				raw := "alpha\nbravo\ncharlie\n"
				content := make([]u8, len(raw));copy(content, transmute([]u8)raw)
				doc := doc_from_content(content, "", .UTF8)
				defer doc_close(&doc)
				doc.wrap = false

				make_rect :: proc(doc: ^Document) {
					doc.block = true
					doc.block_run += 1
					doc.block_anchor_line_start = 0
					doc.block_anchor_cell = 0
					doc.block_cursor_line_start = 12
					doc.block_cursor_cell = 0
				}
				make_rect(&doc)
				block_replace(&doc, t, transmute([]u8)string("x"))
				block_clear(&doc)
				make_rect(&doc)
				block_replace(&doc, t, transmute([]u8)string("y"))
				two := len(doc.undo) == 2
				fmt.printfln("  %-6s a re-made rectangle starts a new undo entry (got %d)", "ok" if two else "FAIL", len(doc.undo))
				if !two {bad += 1}
				return
			}
			if block_test_undo_run_breaks(&t) > 0 {fail = true}

			// The OTHER break condition, and the one block_clear does not cover: an
			// ordinary edit between two block edits OF THE SAME KIND, with the same
			// rectangle still live and its run token unchanged. Only
			// `doc.last_block_run = 0` in push_undo separates them -- remove that one
			// line and the run token still matches, the kind still matches, and the
			// second block edit folds the unrelated insert into its entry, so one
			// Ctrl+Z takes back more than the user did. The insert is placed at the
			// very end of the buffer so it shifts none of the rectangle's row starts;
			// what is under test is the undo bookkeeping, not the geometry. It uses
			// doc_insert_text's default kind (.Paste), the same kind block_replace
			// passes -- with a different kind the kind gate would break the run on its
			// own and this case would prove nothing about push_undo.
			block_test_undo_run_break_edit :: proc(t: ^plat.Text) -> (bad: int) {
				raw := "alpha\nbravo\ncharlie\n"
				content := make([]u8, len(raw));copy(content, transmute([]u8)raw)
				doc := doc_from_content(content, "", .UTF8)
				defer doc_close(&doc)
				doc.wrap = false

				doc.block = true
				doc.block_run += 1
				doc.block_anchor_line_start = 0
				doc.block_anchor_cell = 0
				doc.block_cursor_line_start = 12
				doc.block_cursor_cell = 0

				block_replace(&doc, t, transmute([]u8)string("x"))
				doc.cursor = doc.pt.length
				doc.anchor = doc.cursor
				doc_insert_text(&doc, transmute([]u8)string("Z"))
				block_replace(&doc, t, transmute([]u8)string("y"))
				three := len(doc.undo) == 3
				fmt.printfln("  %-6s an ordinary edit between two block edits breaks the run (got %d, want 3)", "ok" if three else "FAIL", len(doc.undo))
				if !three {bad += 1}
				return
			}
			if block_test_undo_run_break_edit(&t) > 0 {fail = true}

			// doc_absorb_append bypasses push_undo by design (it bumps revision
			// itself) and used to leave last_block_run set with the rectangle still
			// live. Reachable while column-editing a file that is being appended to
			// on disk -- a tailing log -- whenever the buffer length still matches
			// the disk stamp, which a length-preserving column replace (one byte
			// over one byte per row, no padding) satisfies. Without the fix, the
			// next press coalesces onto a snapshot taken before the appended tail,
			// so one Ctrl+Z would discard bytes that came from disk.
			block_test_undo_run_absorb_append :: proc(t: ^plat.Text) -> (bad: int) {
				tmpf := fmt.tprintf("%s%cnewtpad_block_absorb.txt", os.get_env("TEMP", context.temp_allocator), '\\')
				plat.file_write_atomic(tmpf, transmute([]u8)string("alpha\nbravo\ncharlie\n"))
				doc, ok := doc_open(tmpf)
				if !ok {
					fmt.println("  FAIL   block_test_undo_run_absorb_append: could not open temp file")
					return 1
				}
				defer doc_close(&doc)
				doc.wrap = false

				doc.block = true
				doc.block_run += 1
				doc.block_anchor_line_start = 0
				doc.block_anchor_cell = 0
				doc.block_cursor_line_start = 12 // "charlie" line start
				doc.block_cursor_cell = 1

				// A width-1 rectangle [0,1) replaced with a single-byte "x" swaps
				// one existing byte for one byte per row -- length-preserving, so
				// pt.length still matches doc.disk_stamp.size afterward, the
				// precondition doc_absorb_append checks. (A zero-width rectangle,
				// as the other undo-run cases use, INSERTS instead and would grow
				// the buffer past the disk stamp.)
				block_replace(&doc, t, transmute([]u8)string("x"))

				f, fok := os.open(tmpf, os.O_WRONLY | os.O_APPEND)
				if fok == os.ERROR_NONE {
					os.write(f, transmute([]u8)string("delta\n"))
					os.close(f)
				}
				s := plat.file_stamp(tmpf)
				absorbed := doc_absorb_append(&doc, s.size)

				block_replace(&doc, t, transmute([]u8)string("y"))
				two := len(doc.undo) == 2
				ok_all := absorbed && two
				fmt.printfln("  %-6s doc_absorb_append between two block edits does not coalesce them: absorbed=%v undo entries=%d (want 2)", "ok" if ok_all else "FAIL", absorbed, len(doc.undo))
				if !ok_all {bad += 1}
				return
			}
			if block_test_undo_run_absorb_append(&t) > 0 {fail = true}

			// A rectangle must not survive a line-ending conversion.
			// doc_set_line_ending rewrites the WHOLE buffer -- pt_delete(0, length)
			// then pt_insert -- so every row start after the first shifts by one byte
			// per preceding line, while the rectangle's stored block_*_line_start
			// offsets still name the old ones. The next Ctrl+X would then cut bytes
			// the user never saw highlighted. The only thing standing between the two
			// is command_mutates_doc: with .Eol_LF/.Eol_CRLF missing from it neither
			// the table guard nor the block_clear branch in command_dispatch fires.
			// Dispatched as a command, not by calling doc_set_line_ending directly --
			// the guard lives in command_dispatch, so a direct call would prove
			// nothing.
			block_test_eol_clears_rect :: proc(t: ^plat.Text) -> (bad: int) {
				ta: App
				tdummy: plat.Window
				app_new_scratch(&ta)
				td := app_active(&ta)
				doc_close(td)
				td^ = doc_from_content(transmute([]u8)strings.clone("alpha\nbravo\ncharlie\n"), "", .UTF8)
				td.wrap = false
				td.eol = .LF
				// Row starts are 0, 6, 12; a width-2 rectangle down all three rows.
				refusal := block_set_from_points(td, t, 0, 0, 12, 2)
				live_before := refusal == .None && block_active(td)

				command_dispatch(.Eol_CRLF, {}, &ta, &tdummy, t, 10)

				after := doc_debug_string(td)
				gone := !block_active(td)
				converted := td.eol == .CRLF && after == "alpha\r\nbravo\r\ncharlie\r\n"
				ok_all := live_before && gone && converted
				fmt.printfln(
					"  %-6s a line-ending change drops the live rectangle: live_before=%v block_active_after=%v eol=%v text=%q",
					"ok" if ok_all else "FAIL",
					live_before,
					block_active(td),
					td.eol,
					after,
				)
				if !ok_all {bad += 1}
				app_destroy(&ta)
				return
			}
			if block_test_eol_clears_rect(&t) > 0 {fail = true}

			// Same class one level up, found by the whole-branch review right after
			// the line-ending one was fixed: .History_Jump is apply_snapshot ->
			// pt_restore, a whole-tree replacement, exactly what .Undo and .Redo are,
			// and it was missing from command_mutates_doc for the same reason -- it
			// does not look like an edit.
			//
			// The RECTANGLE is not the property to assert on here: apply_snapshot
			// clears one itself, so a rectangle-based check passes with or without the
			// fix (it was written that way first, and sabotage caught it). What
			// command_mutates_doc actually protects is the TABLE guard -- table view is
			// a read-only grid whose only legal write is table_edit_commit's single
			// splice, and a buffer rewritten under an in-progress cell edit leaves that
			// splice landing at a captured span that no longer means anything.
			block_test_history_jump_blocked_in_table :: proc(t: ^plat.Text) -> (bad: int) {
				ha: App
				hdummy: plat.Window
				app_new_scratch(&ha)
				hd := app_active(&ha)
				doc_close(hd)
				hd^ = doc_from_content(transmute([]u8)strings.clone("a,b\n1,2\n"), "", .UTF8)
				hd.wrap = false
				doc_insert_text(hd, transmute([]u8)string("Z")) // an earlier state to jump back to
				after_edit := doc_debug_string(hd)
				hd.table = true // the read-only grid
				hd.table_delim = ','

				ha.history.open = true
				ha.history.sel = 0 // "As opened" -- the state before the insert
				command_dispatch(.History_Jump, {}, &ha, &hdummy, t, 10)

				unchanged := doc_debug_string(hd) == after_edit
				fmt.printfln(
					"  %-6s table view blocks a history jump: text=%q (want it unchanged at %q)",
					"ok" if unchanged else "FAIL", doc_debug_string(hd), after_edit,
				)
				if !unchanged {bad += 1}
				app_destroy(&ha)
				return
			}
			if block_test_history_jump_blocked_in_table(&t) > 0 {fail = true}

			// --- batch 7: a tab that is NOT at column 0 -------------------------
			// Every tab in every fixture above this line is a LEADING tab, and a
			// tab at column 0 is 4 cells under fixed-width tabs and under true
			// tab stops alike -- so none of them can see the difference. These
			// three use "ab\tcd", where the tab starts at column 2 and is
			// therefore 2 cells wide, not 4.
			//
			// AR: block_row_range, the one procedure that turns cells into bytes.
			// Sabotage: make the tab branch of text_cell_width_at return a
			// constant 4 again and this FAILS -- cell 4 then lands inside the
			// tab (which would span columns 2..5), so byte_lo is pulled back to
			// the tab's own start at byte 2 instead of naming 'c' at byte 3.
			block_test_ar :: proc(t: ^plat.Text) -> bool {
				rdoc := doc_from_content(transmute([]u8)strings.clone("ab\tcd\n"), "", .UTF8)
				defer doc_close(&rdoc)
				rdoc.wrap = false
				// Columns: a=0 b=1 tab=2..3 c=4 d=5.
				lo1, hi1, pad1, ok1 := block_row_range(&rdoc, t, 0, 4, 6) // "cd"
				lo2, hi2, _, ok2 := block_row_range(&rdoc, t, 0, 2, 4) // the tab itself
				cAR := ok1 && lo1 == 3 && hi1 == 5 && pad1 == 0 && ok2 && lo2 == 2 && hi2 == 3
				fmt.printfln(
					"  %-6s TAB STOPS: \"ab\\tcd\" cells [4,6)->bytes [%d,%d) (want [3,5)) and cells [2,4)->bytes [%d,%d) (want [2,3))",
					"ok" if cAR else "FAIL", lo1, hi1, lo2, hi2,
				)
				return cAR
			}
			if !block_test_ar(&t) {fail = true}

			// AS: block_delete's caret column, the second of the two
			// keystroke-reachable wrapper bugs the task-1 review found. The
			// rectangle is zero-width at cell 4, Backspace deletes the whole tab
			// (columns 2..3), and the rectangle must land at column 2.
			//
			// Sabotage: restore `new_cell = cell_lo - plat.text_cells(t, buf, 0)`
			// -- the pre-batch-7 form, whose origin of 0 measures the tab as 4 --
			// and this FAILS with both cells reading 0: the caret jumps to the
			// start of every row.
			block_test_as :: proc(t: ^plat.Text) -> bool {
				sdoc := doc_from_content(transmute([]u8)strings.clone("ab\tcd\nab\tcd\n"), "", .UTF8)
				defer doc_close(&sdoc)
				sdoc.wrap = false
				sdoc.block = true
				sdoc.block_anchor_line_start, sdoc.block_anchor_cell = 0, 4
				sdoc.block_cursor_line_start, sdoc.block_cursor_cell = 6, 4 // second row's line start
				oks := block_delete(&sdoc, t, false)
				got := doc_debug_string(&sdoc)
				cAS := oks && got == "abcd\nabcd\n" && sdoc.block_anchor_cell == 2 && sdoc.block_cursor_cell == 2
				fmt.printfln(
					"  %-6s TAB STOPS: backspace over a mid-line tab lands at column 2 (the tab's own start), not 0: content=%q (want %q) cells=%d,%d (want 2,2)",
					"ok" if cAS else "FAIL", got, "abcd\\nabcd\\n", sdoc.block_anchor_cell, sdoc.block_cursor_cell,
				)
				return cAS
			}
			if !block_test_as(&t) {fail = true}

			// AT: block_replace's caret column, the first of the two. Pressing
			// Tab inside a zero-width rectangle at cell 2 inserts a tab that
			// advances to column 4, not to 2+4=6. Driven through the real
			// command table so it crosses commands.odin's .Insert_Tab branch the
			// way a keystroke does.
			//
			// Sabotage: pass 0 instead of cell_lo as text_cells' origin in
			// block_replace and this FAILS with both cells reading 6 -- and the
			// next keystroke would then pad two stray spaces onto every row.
			block_test_at :: proc(t: ^plat.Text) -> bool {
				ta: App
				tdummy: plat.Window
				app_new_scratch(&ta)
				td := app_active(&ta)
				doc_close(td)
				td^ = doc_from_content(transmute([]u8)strings.clone("abcd\nabcd\n"), "", .UTF8)
				td.wrap = false
				td.anchor, td.cursor = 0, 0
				refusal := block_set_from_points(td, t, 0, 2, 5, 2)
				tab_cmd := resolve_key(.Tab, false, false, .Editor)
				command_dispatch(tab_cmd, {.Tab, false, false, false}, &ta, &tdummy, t, 10)
				after := doc_debug_string(td)
				cAT :=
					refusal == .None &&
					after == "ab\tcd\nab\tcd\n" &&
					td.block_anchor_cell == 4 &&
					td.block_cursor_cell == 4
				fmt.printfln(
					"  %-6s TAB STOPS: Tab inside a rectangle at cell 2 leaves it at column 4, not 6: after=%q (want %q) cells=%d,%d (want 4,4)",
					"ok" if cAT else "FAIL", after, "ab\\tcd\\nab\\tcd\\n", td.block_anchor_cell, td.block_cursor_cell,
				)
				app_destroy(&ta)
				return cAT
			}
			if !block_test_at(&t) {fail = true}

			// SEAM PROOF: the assertion the previous round's clipboard fix
			// lacked. block_test_an (above) only proves block_test_ai's OWN
			// save/restore works; it says nothing about block_test_t,
			// block_test_u, or a case added after this comment. This instead
			// checks the WHOLE mode end-to-end: the sentinel set once, before
			// any case ran (mode_seam_sentinel, at the top of this dispatch),
			// must still be what's in the clipboard now that every case has
			// run. Reintroduce any unrestored clipboard write anywhere above --
			// not just the one the reviewer happened to name -- and this fails.
			seam_after, seam_ok := plat.clipboard_get_text(nil, context.temp_allocator)
			cSeam := seam_ok && seam_after == mode_seam_sentinel
			fmt.printfln(
				"  %-6s LIVE PASS (seam): every clipboard-touching case in blocktest restores what it found, start to finish: got=%q (want %q)",
				"ok" if cSeam else "FAIL",
				seam_after,
				mode_seam_sentinel,
			)
			if !cSeam {fail = true}

			fmt.println("blocktest: FAILURES" if fail else "blocktest: all ok")
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

			// shell_open_folder refuses anything that is not a directory. The
			// ShellExecuteW itself is not exercised headlessly -- it would open a
			// real Explorer window -- so what is tested is the guard, which is the
			// part that can be wrong.
			nf := fmt.tprintf("%s%cnewtpad_notadir.txt", os.get_env("TEMP", context.temp_allocator), '\\')
			plat.file_write_atomic(nf, transmute([]u8)string("x"))
			g1 := !plat.shell_open_folder(nf)
			fmt.printfln("  %-6s shell_open_folder refuses a file", "ok" if g1 else "FAIL")
			if !g1 {bad += 1}
			g2 := !plat.shell_open_folder(fmt.tprintf("%s%cnewtpad_no_such_dir_zz", os.get_env("TEMP", context.temp_allocator), '\\'))
			fmt.printfln("  %-6s shell_open_folder refuses a missing path", "ok" if g2 else "FAIL")
			if !g2 {bad += 1}

			// The lpParameters string handed to explorer.exe must be quoted, or a
			// space in the path (an %APPDATA% under a Windows user name with a
			// space, for instance) truncates it or splits it into extra arguments.
			// This never calls ShellExecuteW -- it only checks the pure argument
			// builder's output.
			g3 := plat.explorer_folder_arg("C:\\Users\\John Doe\\AppData\\Roaming\\Newtpad\\logs") == "\"C:\\Users\\John Doe\\AppData\\Roaming\\Newtpad\\logs\""
			fmt.printfln("  %-6s explorer_folder_arg quotes a path with a space", "ok" if g3 else "FAIL")
			if !g3 {bad += 1}
			g4 := plat.explorer_select_arg("C:\\Users\\John Doe\\x.txt") == "/select,\"C:\\Users\\John Doe\\x.txt\""
			fmt.printfln("  %-6s explorer_select_arg quotes a path with a space", "ok" if g4 else "FAIL")
			if !g4 {bad += 1}

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

			fmt.println("--- a link that starts after a MID-LINE tab ---")
			// The seam check above puts the link after a plain space, so its
			// column is the same under fixed-width tabs and true tab stops --
			// like every other tab in every other suite, it cannot see the
			// difference. Here "see" fills columns 0-2, the tab at column 3
			// advances ONE cell to reach the stop at 4, and the link starts
			// there. Under a fixed four the tab would be 4 wide and the link
			// would start at column 7.
			//
			// This is text_span_cells' only non-leading-tab fixture, and it is a
			// seam check as well as a value check: the same col/cells drive the
			// drawn underline and links_hit, so the boundary probes below fail
			// if either one drifts. Sabotage the tab branch of
			// text_cell_width_at back to a constant and col prints 7.
			{
				tt: plat.Text
				plat.text_load_faces(&tt)
				url := "https://example.com/x"
				td := doc_from_content(transmute([]u8)strings.clone("see\thttps://example.com/x now\n"), "", .UTF8)
				defer doc_close(&td)
				td.wrap = false
				td.view_cols = 200
				td.view_rows = 10
				hits := links_layout(&td, &tt, 10)
				if len(hits) != 1 {
					fmt.printfln("  FAIL: expected 1 hit, got %d", len(hits))
					bad += 1
				} else {
					h := hits[0]
					cw := plat.text_char_width(&tt, BASE_PX, .Doc)
					px := BASE_PX
					yy := row_baseline_y(px, h.row) - line_height(px) * 0.5
					_, i1 := links_hit(hits, px, cw, col_x(cw, h.col) + cw * 0.5, yy)
					_, i2 := links_hit(hits, px, cw, col_x(cw, h.col + h.cells - 1) + cw * 0.5, yy)
					_, o1 := links_hit(hits, px, cw, col_x(cw, h.col - 1) + cw * 0.5, yy)
					_, o2 := links_hit(hits, px, cw, col_x(cw, h.col + h.cells) + cw * 0.5, yy)
					ok := h.col == 4 && h.cells == len(url) && i1 && i2 && !o1 && !o2
					fmt.printfln(
						"  col=%d (want 4; a fixed-4 tab gives 7) cells=%d/%d  first=%v last=%v before=%v after=%v %s",
						h.col, h.cells, len(url), i1, i2, o1, o2, "OK" if ok else "FAIL",
					)
					if !ok {bad += 1}
				}
			}

			fmt.println("--- a link that spans force-wrapped rows ---")
			// A line over the wrap threshold (>1024) with a long URL that char-breaks
			// across several visual rows. The link must be found on the LOGICAL line and
			// split into per-row segments that together cover it and all resolve whole.
			{
				tt: plat.Text
				plat.text_load_faces(&tt)
				url := strings.concatenate({"http://example.com/", strings.repeat("a", 200)})
				line := strings.concatenate({strings.repeat("x", 1100), " ", url, "\n"})
				wd := doc_from_content(transmute([]u8)line, "", .UTF8)
				defer doc_close(&wd)
				wd.wrap = false // force-wrap kicks in because the line is > 1024 cells
				wd.view_cols = 80
				wd.view_rows = 60
				hits := links_layout(&wd, &tt, 60)
				segs := 0
				total_cells := 0
				resolved := false
				all_whole := true
				for h in hits {
					if h.link.kind != .URL {continue}
					segs += 1
					total_cells += h.span_len
					if !h.wrapped {all_whole = false} // every segment is on a wrapped row
					if h.text[h.link.start:h.link.start + h.link.target_len] != url {all_whole = false}
					if !resolved {
						if tgt, ok := link_resolve(&wd, h.text, h.link); ok && tgt.is_url && tgt.url == url {
							resolved = true
						}
					}
				}
				okw := segs >= 2 && total_cells == len(url) && resolved && all_whole
				fmt.printfln("  %d row-segments, %d/%d cells covered, resolves whole=%v %s", segs, total_cells, len(url), resolved, "OK" if okw else "FAIL")
				if !okw {bad += 1}
			}

			fmt.println("--- a link past the wrapped-row scan caps ---")
			// Same shape as the syntax highlighter's wrapped-row bug (see
			// doc_row_lex_extent, doc.odin): the wrapped branch below discards
			// pt_line_start_cap's `exact` flag and caps its whole-line read at
			// LINK_SCAN_CAP, so on a logical line longer than either cap it hands
			// the rebase a window that cannot contain the row -- and every row past
			// it is skipped, silently, with no links at all.
			//
			// Reachable only with the user's word wrap ON: a line whose newline sits
			// beyond WRAP_START_CAP never force-wraps (line_wrap_decision). The URL
			// here sits at byte ~9000, past both LINK_SCAN_CAP (4096) and
			// WRAP_START_CAP (8192).
			{
				tt: plat.Text
				plat.text_load_faces(&tt)
				url := "https://example.com/deep"
				line := strings.concatenate({strings.repeat("x", 9000), " ", url, "\n"})
				wd := doc_from_content(transmute([]u8)line, "", .UTF8)
				defer doc_close(&wd)
				wd.wrap = true // only the wrap setting produces wrapped rows this far in
				wd.view_cols = 80
				wd.view_rows = 200
				hits := links_layout(&wd, &tt, 200)
				cells, resolved := 0, false
				for h in hits {
					if h.link.kind != .URL {continue}
					cells += h.span_len
					if tgt, ok := link_resolve(&wd, h.text, h.link); ok && tgt.is_url && tgt.url == url {resolved = true}
				}
				okd := cells == len(url) && resolved
				fmt.printfln("  %d/%d cells covered, resolves=%v %s", cells, len(url), resolved, "OK" if okd else "FAIL")
				if !okd {bad += 1}
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

		// See atlas_grow_mode -- it needs a real device, which it now gets without
		// a window.
		if os.args[1] == "atlasgrowtest" {
			fmt.printfln("atlasgrowtest: %d failures", atlas_grow_mode())
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
			// The same seam on a line containing TABS, which is the case the
			// ASCII fixture above structurally cannot see: there cell index ==
			// byte index, so line_cell_col and line_offset_at_cell agree even if
			// neither understands a tab stop. Batch 7's design named this pair --
			// "the row measure/hit-test pair, which must agree or the caret
			// drifts" -- and every other tab fixture in the tree measures the
			// platform layer, not this one. Round-trip every byte offset in the
			// row: offset -> cell -> offset must be a fixed point at each one.
			{
				tline := "ab\tcd\te\t\tfghi\tj" // tabs at 2, 5, 7, 8, 13
				tcontent := strings.concatenate({tline, "\n"})
				tdoc := doc_from_content(transmute([]u8)tcontent, "", .UTF8)
				defer doc_close(&tdoc)
				tdoc.wrap = false
				tdoc.view_cols = 80
				tdoc.view_rows = 5
				le := len(tline)
				for off in 0 ..= le {
					cell := line_cell_col(&tdoc, &t, 0, off)
					back := line_offset_at_cell(&tdoc, &t, 0, le, cell)
					if back != off {
						fmt.printfln("  FAIL tab seam: off=%d -> cell=%d -> off=%d", off, cell, back)
						bad += 1
					}
				}
				// And the drawn column must be strictly increasing across the row:
				// a tab that returned 0 cells would stall the caret on two offsets.
				prev := -1
				for off in 0 ..= le {
					c := line_cell_col(&tdoc, &t, 0, off)
					if c <= prev {
						fmt.printfln("  FAIL tab seam: column not increasing at off=%d (%d <= %d)", off, c, prev)
						bad += 1
					}
					prev = c
				}
				// The round-trip above is NOT enough on its own, and finding that
				// out is why these value assertions exist: line_cell_col and
				// line_offset_at_cell are inverses whatever a tab measures, so
				// reverting to fixed-width tabs leaves the round-trip green (tried
				// it -- 0 failures). Only absolute columns discriminate. At width 4
				// these are the tab stops; under fixed-width-4 the same offsets read
				// 6, 12, 17, 21, 21, so every row below moves.
				for pair in ([][2]int {
					{2, 2}, // the first tab starts at column 2
					{3, 4}, // ...and advances to the stop, not by a full 4
					{5, 6},
					{6, 8}, // second tab: 6 -> 8
					{7, 9},
					{8, 12}, // a tab at 9 advances 3 to reach 12
					{9, 16}, // a tab sitting exactly on a stop advances a full 4
					{14, 24},
				}) {
					off, want := pair[0], pair[1]
					got := line_cell_col(&tdoc, &t, 0, off)
					if got != want {
						fmt.printfln("  FAIL tab seam: col at off=%d is %d, want %d", off, got, want)
						bad += 1
					}
				}
			}

			// The grid and the markdown views replace the text pass entirely, and
			// each pans a DIFFERENT number -- or none at all. Before hscroll_model
			// the bar took its range from doc_max_hscroll unconditionally and wrote
			// doc.h_scroll on drag, so in both views it appeared (source lines are
			// long), dragged, and moved nothing: table_draw and markdown_draw never
			// read H_SCROLL. Wyatt reported it from live use, 2026-07-27.
			grid_bad := 0
			{
				// A grid wide enough that not every column fits. Built with the
				// DEFAULT allocator, not temp: doc_from_content sets owned_orig, so
				// doc_close frees this slice. A temp-allocated fixture here is a
				// heap corruption (0xC0000374), not a leak -- cost one crash.
				sb := strings.builder_make()
				for r in 0 ..< 4 {
					for c in 0 ..< 40 {
						if c > 0 {strings.write_byte(&sb, ',')}
						fmt.sbprintf(&sb, "r%dc%d", r, c)
					}
					strings.write_byte(&sb, '\n')
				}
				gdoc := doc_from_content(sb.buf[:], "wide.csv", .UTF8)
				defer doc_close(&gdoc)
				gdoc.table = true
				gdoc.view_cols = 80
				gdoc.view_rows = 5

				gm := hscroll_model(&gdoc, &t, rows, 1000, cw)
				if gm.kind != .Columns {
					fmt.printfln("  FAIL grid: hscroll kind is %v, want Columns", gm.kind)
					bad += 1;grid_bad += 1
				}
				if gm.max <= 0 {
					fmt.printfln("  FAIL grid: nothing to pan (max=%d) though 40 columns do not fit", gm.max)
					bad += 1;grid_bad += 1
				}
				if gm.span >= 40 {
					fmt.printfln("  FAIL grid: thumb span %d claims all 40 columns fit", gm.span)
					bad += 1;grid_bad += 1
				}
				// The drag must move the number the GRID reads, and must not touch
				// the text view's. This is the assertion the old code fails.
				ghb := hscrollbar_geo(&gdoc, 1000, 700, gm)
				if !ghb.shown {
					fmt.println("  FAIL grid: scrollbar hidden though columns overflow")
					bad += 1;grid_bad += 1
				} else {
					hscroll_set(&gdoc, gm, hscrollbar_pos_at(ghb, ghb.track_x + ghb.track_w, gm))
					if gdoc.table_col != gm.max {
						fmt.printfln("  FAIL grid: dragging to the end set table_col=%d, want %d", gdoc.table_col, gm.max)
						bad += 1;grid_bad += 1
					}
					if gdoc.h_scroll != 0 {
						fmt.printfln("  FAIL grid: drag wrote h_scroll=%d, which the grid never reads", gdoc.h_scroll)
						bad += 1;grid_bad += 1
					}
					// Thumb round-trip in column space.
					for tc in ([]int{0, 1, gm.max / 2, gm.max}) {
						gdoc.table_col = clamp(tc, 0, gm.max)
						m2 := hscroll_model(&gdoc, &t, rows, 1000, cw)
						b2 := hscrollbar_geo(&gdoc, 1000, 700, m2)
						got := hscrollbar_pos_at(b2, b2.thumb_x + b2.thumb_w*0.5, m2)
						if got != gdoc.table_col {
							fmt.printfln("  FAIL grid: thumb round-trip col=%d -> %d", gdoc.table_col, got)
							bad += 1;grid_bad += 1
						}
					}
				}
			}
			{
				// Markdown Preview and Split lay out to the pane, so there is no
				// horizontal axis and the bar must be hidden -- not shown and dead.
				mdline := strings.repeat("y", 400)
				defer delete(mdline)
				mdoc := doc_from_content(transmute([]u8)strings.concatenate({mdline, "\n"}), "notes.md", .UTF8)
				defer doc_close(&mdoc)
				mdoc.view_cols = 80
				mdoc.view_rows = 5
				for mode in ([]Md_Mode{.Preview, .Split}) {
					mdoc.md_mode = mode
					mm := hscroll_model(&mdoc, &t, rows, 1000, cw)
					if mm.kind != .None {
						fmt.printfln("  FAIL markdown %v: hscroll kind is %v, want None", mode, mm.kind)
						bad += 1;grid_bad += 1
					}
					if hscrollbar_geo(&mdoc, 1000, 700, mm).shown {
						fmt.printfln("  FAIL markdown %v: scrollbar shown though the pane lays out to fit", mode)
						bad += 1;grid_bad += 1
					}
				}
				mdoc.md_mode = .Off
				om := hscroll_model(&mdoc, &t, rows, 1000, cw)
				if om.kind != .Cells {
					fmt.printfln("  FAIL markdown Off: hscroll kind is %v, want Cells", om.kind)
					bad += 1;grid_bad += 1
				}
			}
			fmt.printfln("  grid pans columns, markdown preview shows no bar: %s", "OK" if grid_bad == 0 else fmt.tprintf("%d FAILED", grid_bad))

			// A read-only surface swallows a press by zeroing window.mouse_down,
			// which is PERSISTENT platform state -- so every cross-frame drag latch
			// must be excluded or the gesture dies on its first frame. `hscroll` was
			// missing while the other three were present, which is why the grid's
			// horizontal bar moved on click and froze on drag (v0.17.1, live use).
			ro_bad := 0
			{
				all := []Drag_Latches {
					{vscroll = true},
					{hscroll = true},
					{preview = true},
					{divider = true},
				}
				names := []string{"vscroll", "hscroll", "preview", "divider"}
				for d, i in all {
					// Grid: every latch must veto the swallow.
					if ro_surface_swallows(true, .Off, false, d) {
						fmt.printfln("  FAIL ro-swallow: grid swallows while %s drag is live", names[i])
						ro_bad += 1
					}
					// Full Preview, and the preview half of a Split, likewise.
					if ro_surface_swallows(false, .Preview, false, d) {
						fmt.printfln("  FAIL ro-swallow: preview swallows while %s drag is live", names[i])
						ro_bad += 1
					}
					if ro_surface_swallows(false, .Split, true, d) {
						fmt.printfln("  FAIL ro-swallow: split preview half swallows while %s drag is live", names[i])
						ro_bad += 1
					}
				}
				// With no drag live the swallow must still happen, or a press in the
				// grid would place a caret in a read-only view. A predicate that
				// always returns false would pass every case above.
				none: Drag_Latches
				if !ro_surface_swallows(true, .Off, false, none) {
					fmt.println("  FAIL ro-swallow: grid does not swallow an ordinary press")
					ro_bad += 1
				}
				if !ro_surface_swallows(false, .Preview, false, none) {
					fmt.println("  FAIL ro-swallow: preview does not swallow an ordinary press")
					ro_bad += 1
				}
				// The editor half of a Split, and a plain text doc, are NOT read-only.
				if ro_surface_swallows(false, .Split, false, none) {
					fmt.println("  FAIL ro-swallow: split EDITOR half swallowed a press")
					ro_bad += 1
				}
				if ro_surface_swallows(false, .Off, false, none) {
					fmt.println("  FAIL ro-swallow: plain text swallowed a press")
					ro_bad += 1
				}
			}
			fmt.printfln("  a live drag survives the read-only swallow: %s", "OK" if ro_bad == 0 else fmt.tprintf("%d FAILED", ro_bad))
			bad += ro_bad

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
				hm := hscroll_model(&doc, &t, rows, 1000, cw)
				hb := hscrollbar_geo(&doc, 1000, 700, hm)
				if !hb.shown {
					fmt.println("  FAIL: scrollbar not shown though content overflows")
					bad += 1
					continue
				}
				got := hscrollbar_pos_at(hb, hb.thumb_x + hb.thumb_w*0.5, hm)
				if got != doc.h_scroll {
					fmt.printfln("  FAIL: thumb round-trip hs=%d -> %d", doc.h_scroll, got)
					bad += 1
				}
			}
			doc.h_scroll = 0

			// Clicking must not fling the viewport. On a line longer than the render
			// cap, the caret-follow measured the column from a synthetic line start one
			// cap back, so a click on a later segment jumped h_scroll to ~8000. Simulate
			// a click on the second capped segment of a very long line and require
			// h_scroll to stay put.
			{
				longline := strings.concatenate({strings.repeat("y", 20000), "\n"})
				ld := doc_from_content(transmute([]u8)longline, "", .UTF8)
				defer doc_close(&ld)
				ld.wrap = false
				ld.view_cols = 80
				ld.view_rows = 5
				ld.h_scroll = 0
				ld.top = base.pt_line_end_cap(&ld.pt, 0, RENDER_LINE_CAP) // second capped segment
				doc_update_hscroll(&ld) // H_SCROLL = 0
				mx := col_x(cw, 40) + cw*0.2 // screen col 40 of the visible segment
				my := row_baseline_y(px, 0) - line_height(px)*0.5
				ld.cursor = doc_pos_at(&ld, &t, i32(mx), i32(my), px, cw, rows)
				before := ld.h_scroll
				doc_ensure_cursor_visible(&ld, &t, ld.view_rows)
				if ld.h_scroll > before + ld.view_cols {
					fmt.printfln("  FAIL: click on a long line flung h_scroll %d -> %d", before, ld.h_scroll)
					bad += 1
				} else {
					fmt.println("  clicking a long line does not fling the viewport: OK")
				}
				// The scroll range must stop at what doc_draw actually renders
				// (VISIBLE_COLS), not run thousands of cells into blank space.
				if mh := doc_max_hscroll(&ld, &t, ld.view_rows); mh > VISIBLE_COLS {
					fmt.printfln("  FAIL: max h-scroll %d exceeds the drawn width %d (blank space)", mh, VISIBLE_COLS)
					bad += 1
				}
				ld.h_scroll = 0
				doc_update_hscroll(&ld)
			}

			if bad == 0 {fmt.println("  drawn column == hit-tested column, and the scrollbar thumb round-trips: OK")}
			fmt.printfln("hscrolltest: %d failures", bad)
			return true
		}

		// `newtpad wraplongtest` covers the mixed layout: with global wrap OFF, a line
		// past WRAP_LONG_CELLS force-wraps to the window while shorter lines stay single
		// (horizontally-scrollable) rows, the h-scroll range ignores the wrapped lines,
		// and a line too long to locate stays a capped no-wrap row (so it can't freeze).
		if os.args[1] == "wraplongtest" {
			bad := 0
			t: plat.Text
			plat.text_load_faces(&t)
			// short(5) \n long(3000) \n medium(200) \n end(3) \n
			content := strings.concatenate(
				{"short\n", strings.repeat("x", 3000), "\n", strings.repeat("y", 200), "\n", "end\n"},
			)
			doc := doc_from_content(transmute([]u8)content, "", .UTF8)
			defer doc_close(&doc)
			doc.wrap = false
			doc.view_cols = 80
			doc.view_rows = 200
			rows := 200

			wrapped_rows := 0
			medium_wrapped := false
			short_wrapped := false
			it := visible_begin(&doc, &t, rows)
			for {
				_, start, _, _, _, wrapped, ok := visible_next(&it)
				if !ok {break}
				if wrapped {wrapped_rows += 1}
				if wrapped && start < 6 {short_wrapped = true} // the "short" line region
				if wrapped && start >= 3007 && start < 3207 {medium_wrapped = true} // the 200-cell line
			}
			if wrapped_rows < 30 {
				fmt.printfln("  FAIL: the 3000-cell line did not force-wrap (%d wrapped rows)", wrapped_rows)
				bad += 1
			}
			if short_wrapped {
				fmt.println("  FAIL: a 5-cell line was wrapped")
				bad += 1
			}
			if medium_wrapped {
				fmt.println("  FAIL: a 200-cell line was wrapped (under the 1024 threshold)")
				bad += 1
			}
			// The h-scroll range must come from the 200-cell non-wrapped line, not the
			// 3000-cell wrapped one.
			if mh := doc_max_hscroll(&doc, &t, rows); mh != 200 + HSCROLL_PAD - 80 {
				fmt.printfln("  FAIL: h-scroll range %d, want %d (from the 200-cell line)", mh, 200 + HSCROLL_PAD - 80)
				bad += 1
			}

			// A line too long to locate its start (> WRAP_START_CAP) must NOT wrap: it
			// stays a capped, no-wrap row, so the huge-file guarantee holds.
			huge := strings.concatenate({strings.repeat("z", WRAP_START_CAP + 5000), "\n"})
			hd := doc_from_content(transmute([]u8)huge, "", .UTF8)
			defer doc_close(&hd)
			hd.wrap = false
			hd.view_cols = 80
			hd.view_rows = 5
			hd.top = base.pt_line_end_cap(&hd.pt, 0, RENDER_LINE_CAP) // a mid-line segment
			it2 := visible_begin(&hd, &t, 5)
			if _, _, _, _, _, w0, ok2 := visible_next(&it2); ok2 && w0 {
				fmt.println("  FAIL: a >256KB line wrapped (should stay a capped no-wrap row)")
				bad += 1
			}

			if bad == 0 {fmt.println("  long lines wrap, short/medium/huge lines do not, range excludes wrapped: OK")}
			fmt.printfln("wraplongtest: %d failures", bad)
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
			if !require_scratch_session("diskstamptest") {return true}
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

			// A reload used to rebuild through doc_open and carry only `wrap`, so an
			// external change silently reset the view -- on the log-tailing path the
			// reload feature exists for, and disagreeing with what a fresh open of
			// the same file would now do.
			fmt.println("--- reload keeps the view ---")
			mdp := fmt.tprintf("%s%cnewtpad_reload.md", os.get_env("TEMP", context.temp_allocator), '\\')
			plat.file_write_atomic(mdp, transmute([]u8)string("# one\n\nbody\n"))
			v: App
			if fd, ok := doc_open(mdp); ok {
				rd := new(Document);rd^ = fd
				rd.md_mode = .Split
				rd.wrap = true
				app_add(&v, rd)
				app_activate(&v, 0)
				// 3 bytes into "body" (which starts at offset 7) -- deliberately
				// mid-line, so a re-anchor to the line start is a real assertion and
				// not one that top=0 would pass by accident.
				mid_top := 10
				rd.top = mid_top
				plat.file_write_atomic(mdp, transmute([]u8)string("# one\n\nbody\nmore\n"))
				rok := doc_reload(rd)
				keep := rok && rd.md_mode == .Split && rd.wrap
				fmt.printfln(
					"  %-6s reload keeps md_mode and wrap: ok=%v md_mode=%v wrap=%v (want Split/true)",
					"ok" if keep else "FAIL", rok, rd.md_mode, rd.wrap,
				)
				if !keep {bad += 1}

				want_top := base.pt_line_start(&rd.pt, mid_top)
				top_ok := rd.top == want_top
				fmt.printfln(
					"  %-6s reload re-anchors top to a line start: top=%v (want %v)",
					"ok" if top_ok else "FAIL", rd.top, want_top,
				)
				if !top_ok {bad += 1}
			}
			app_destroy(&v)

			empty: App
			app_new_scratch(&empty)
			session_save(&empty)
			app_destroy(&empty)
			fmt.printfln("diskstamptest: %d failures", bad)
			return true
		}

		// `newtpad enctest` -- forcing an encoding at open time. detect_encoding is
		// right almost always, and there was no way to say otherwise: doc_set_encoding
		// only changes what the next SAVE writes, it re-decodes nothing.
		if os.args[1] == "enctest" {
			bad := 0
			fmt.println("enctest:")
			tmp := os.get_env("TEMP", context.temp_allocator)

			// "caf\xC3\xA9" is valid UTF-8 for "café" and detect says UTF8. The same
			// bytes read as Windows-1252 are "cafÃ©" -- the real-world mislabelling,
			// and an assertion that cannot pass if the override is ignored.
			u8f := fmt.tprintf("%s%cnewtpad_enc_u8.txt", tmp, '\\')
			plat.file_write_atomic(u8f, transmute([]u8)string("caf\xC3\xA9"))

			enc_default :: proc(path: string) -> (enc: base.Encoding, text: string) {
				d, ok := doc_open(path)
				if !ok {return .UTF8, ""}
				defer doc_close(&d)
				return d.enc, doc_debug_string(&d)
			}
			de, dt := enc_default(u8f)
			ok1 := de == .UTF8 && dt == "café"
			fmt.printfln("  %-6s default open detects UTF-8: enc=%v text=%q", "ok" if ok1 else "FAIL", de, dt)
			if !ok1 {bad += 1}

			enc_forced :: proc(path: string, force: base.Encoding) -> (enc: base.Encoding, text: string) {
				d, ok := doc_open(path, force)
				if !ok {return .UTF8, ""}
				defer doc_close(&d)
				return d.enc, doc_debug_string(&d)
			}
			fe, ft := enc_forced(u8f, .CP1252)
			ok2 := fe == .CP1252 && ft == "cafÃ©"
			fmt.printfln("  %-6s forced CP1252 re-decodes the same bytes: enc=%v text=%q", "ok" if ok2 else "FAIL", fe, ft)
			if !ok2 {bad += 1}

			// A BOM belongs to the encoding that wrote it. Forcing a different one
			// makes those bytes content, so the skip must be dropped -- otherwise a
			// forced reopen silently eats two or three bytes of the user's file.
			bomf := fmt.tprintf("%s%cnewtpad_enc_bom.txt", tmp, '\\')
			plat.file_write_atomic(bomf, transmute([]u8)string("\xEF\xBB\xBFhi"))
			be, bt := enc_forced(bomf, .CP1252)
			ok3 := be == .CP1252 && strings.has_suffix(bt, "hi") && len(bt) > 2
			fmt.printfln("  %-6s forced encoding drops a BOM skip that no longer applies: text=%q", "ok" if ok3 else "FAIL", bt)
			if !ok3 {bad += 1}

			// The reopen path itself: same document, re-read under a new encoding,
			// with the view preserved (it goes through doc_reload).
			reopen_case :: proc(path: string) -> (bad: int) {
				d, ok := doc_open(path)
				if !ok {return 1}
				defer doc_close(&d)
				d.wrap = true
				rok := doc_reload_forced(&d, .CP1252)
				good := rok && d.enc == .CP1252 && d.wrap && doc_debug_string(&d) == "cafÃ©"
				fmt.printfln(
					"  %-6s doc_reload_forced re-decodes and keeps the view: ok=%v enc=%v wrap=%v",
					"ok" if good else "FAIL", rok, d.enc, d.wrap,
				)
				if !good {bad += 1}
				return
			}
			bad += reopen_case(u8f)

			// The size cap. Re-decoding under a forced encoding materialises the
			// whole file twice on the UI thread, so above REOPEN_TRANSCODE_MAX_BYTES
			// the command must change NOTHING -- not a truncated document, not an
			// empty one a following Ctrl+S would write over the file. The cap is
			// lowered here rather than carrying a 64 MB fixture; that is the whole
			// reason it is a variable. Both halves matter: the transcoding row
			// refuses, and Reopen as UTF-8 -- which never takes the private copy --
			// still goes through at the same size.
			reopen_cap_case :: proc(path: string) -> (bad: int) {
				a: App
				dummy: plat.Window
				t: plat.Text
				if !app_open_path(&a, path) {
					fmt.println("  FAIL   reopen cap: could not open the fixture")
					return 1
				}
				defer app_destroy(&a)
				d := app_active(&a)
				before_text := strings.clone(doc_debug_string(d), context.temp_allocator)
				before_enc := d.enc
				before_mod := d.modified

				saved := reopen_transcode_max_bytes
				defer reopen_transcode_max_bytes = saved
				reopen_transcode_max_bytes = 1 // the fixture is larger than this

				command_dispatch(.Reopen_CP1252, {}, &a, &dummy, &t, 10)
				refused :=
					doc_debug_string(d) == before_text &&
					d.enc == before_enc &&
					d.modified == before_mod &&
					strings.has_prefix(a.notice, "[REOPEN REFUSED")
				fmt.printfln(
					"  %-6s an over-cap reopen refuses and changes nothing: text=%q enc=%v modified=%v note=%q",
					"ok" if refused else "FAIL",
					doc_debug_string(d),
					d.enc,
					d.modified,
					a.notice,
				)
				if !refused {bad += 1}

				// UTF-8 is not a transcode, so the cap does not apply to it.
				command_dispatch(.Reopen_UTF8, {}, &a, &dummy, &t, 10)
				allowed := d.enc == .UTF8 && doc_debug_string(d) == before_text && strings.has_prefix(a.notice, "[REOPENED AS")
				fmt.printfln(
					"  %-6s the cap does not apply to Reopen as UTF-8: enc=%v text=%q note=%q",
					"ok" if allowed else "FAIL",
					d.enc,
					doc_debug_string(d),
					a.notice,
				)
				if !allowed {bad += 1}
				return
			}
			bad += reopen_cap_case(u8f)

			// The cap must read the file's size NOW, not doc.disk_stamp.size. The
			// stamp is 0 when the last stat failed and stale on a restored dirty
			// tab, and both cases read as "small" -- which is the direction that
			// hurts, because the cap exists to refuse a multi-second synchronous
			// transcode. A stamp claiming 0 against a file that is really over the
			// cap must still refuse.
			//
			// The stamp is falsified rather than reproduced: a dropped share and a
			// session restored across a file that grew are both unreachable from a
			// headless test, and the stamp is the single value both of them feed.
			reopen_stale_stamp_case :: proc(path: string) -> (bad: int) {
				a: App
				dummy: plat.Window
				t: plat.Text
				if !app_open_path(&a, path) {
					fmt.println("  FAIL   stale stamp: could not open the fixture")
					return 1
				}
				defer app_destroy(&a)
				d := app_active(&a)
				before_text := strings.clone(doc_debug_string(d), context.temp_allocator)
				before_enc := d.enc

				saved := reopen_transcode_max_bytes
				defer reopen_transcode_max_bytes = saved
				reopen_transcode_max_bytes = 1 // the fixture on disk is larger than this

				d.disk_stamp.size = 0 // what a failed stat, or a session-restored tab, leaves behind
				command_dispatch(.Reopen_CP1252, {}, &a, &dummy, &t, 10)
				refused :=
					doc_debug_string(d) == before_text &&
					d.enc == before_enc &&
					strings.has_prefix(a.notice, "[REOPEN REFUSED")
				fmt.printfln(
					"  %-6s a stamp reporting 0 does not get a really-large file past the cap: enc=%v note=%q",
					"ok" if refused else "FAIL", d.enc, a.notice,
				)
				if !refused {bad += 1}
				return
			}
			bad += reopen_stale_stamp_case(u8f)

			// A file that cannot be stat'd at all is treated as OVER the cap, not
			// under it. Distinguished from a plain failure by the notice: without
			// the guard the command reaches doc_open, which fails on the missing
			// file and says "[REOPEN FAILED" -- same end state here, but only
			// because a deleted file is the cheap version of an unreachable one. On
			// a dropped share doc_open blocks first and empties the document if the
			// allocation then fails, which is the outcome being bought off.
			reopen_unstattable_case :: proc() -> (bad: int) {
				tmp := os.get_env("TEMP", context.temp_allocator)
				gone := fmt.tprintf("%s%cnewtpad_enc_gone.txt", tmp, '\\')
				plat.file_write_atomic(gone, transmute([]u8)string("caf\xC3\xA9"))
				a: App
				dummy: plat.Window
				t: plat.Text
				if !app_open_path(&a, gone) {
					fmt.println("  FAIL   unstattable: could not open the fixture")
					os.remove(gone)
					return 1
				}
				defer app_destroy(&a)
				d := app_active(&a)
				os.remove(gone) // now unstattable, with the cap left at its real 64 MB
				command_dispatch(.Reopen_CP1252, {}, &a, &dummy, &t, 10)
				refused := d.enc == .UTF8 && strings.has_prefix(a.notice, "[REOPEN REFUSED")
				fmt.printfln(
					"  %-6s an unstattable file is over the cap, not under it: enc=%v note=%q",
					"ok" if refused else "FAIL", d.enc, a.notice,
				)
				if !refused {bad += 1}
				return
			}
			bad += reopen_unstattable_case()

			// ...and the converse: a stamp that ALREADY refuses is not re-measured.
			// The stat is synchronous on the UI thread and blocks for the redirector
			// timeout on a dropped share, so a file the stamp already puts over the
			// cap must be refused without one -- which is what the code did before
			// the cap was fixed, and what statting unconditionally took away.
			//
			// "No syscall" is not directly observable here, so the two orders are
			// told apart by their notice: with the file deleted, statting first can
			// only produce "could not be measured", while consulting the stamp first
			// produces the over-the-limit message. Same refusal, different reason,
			// and only the second one is free.
			reopen_over_cap_stamp_skips_the_stat :: proc() -> (bad: int) {
				tmp := os.get_env("TEMP", context.temp_allocator)
				f := fmt.tprintf("%s%cnewtpad_enc_overcap.txt", tmp, '\\')
				plat.file_write_atomic(f, transmute([]u8)string("caf\xC3\xA9"))
				a: App
				dummy: plat.Window
				t: plat.Text
				if !app_open_path(&a, f) {
					fmt.println("  FAIL   over-cap stamp: could not open the fixture")
					os.remove(f)
					return 1
				}
				defer app_destroy(&a)
				d := app_active(&a)
				saved := reopen_transcode_max_bytes
				defer reopen_transcode_max_bytes = saved
				reopen_transcode_max_bytes = 1 // the stamp doc_open took is larger than this
				os.remove(f) // unreachable: a live stat can now only fail
				command_dispatch(.Reopen_CP1252, {}, &a, &dummy, &t, 10)
				ok := d.enc == .UTF8 && strings.contains(a.notice, "over the")
				fmt.printfln(
					"  %-6s an already-over-cap stamp refuses without statting: enc=%v note=%q",
					"ok" if ok else "FAIL", d.enc, a.notice,
				)
				if !ok {bad += 1}
				return
			}
			bad += reopen_over_cap_stamp_skips_the_stat()

			// Encoding > Line Endings, the OTHER consumer of convert_line_endings and
			// the one nothing covered: pastetest drives the paste path, and crlftest
			// is a caret/hit-test/wrap suite that never calls this at all.
			//
			// The lone CR must survive here for the same reason it survives a paste --
			// detect_line_ending counts only '\n' and Line_Ending has no .CR member, so
			// a bare CR has never been a line ending anywhere in Newtpad, and the old
			// code rewrote bytes the detector does not classify as endings.
			//
			// The MIXED case is the one that changed. A buffer of nothing but lone CRs
			// was never rewritten even before the fix: convert_line_endings returns the
			// same length, and doc_set_line_ending's length-equality early return then
			// takes the no-op path. Only a buffer holding both reaches the rewrite.
			eol_row_case :: proc(text, want_crlf, want_lf: string) -> (bad: int) {
				a: App
				defer app_destroy(&a)
				c := make([]u8, len(text));copy(c, transmute([]u8)text)
				d := new(Document)
				d^ = doc_from_content(c, "", .UTF8)
				d.eol = .LF
				app_add(&a, d)
				app_activate(&a, 0)
				doc_set_line_ending(d, .CRLF)
				to_crlf := strings.clone(doc_debug_string(d), context.temp_allocator)
				crlf_eol := d.eol
				doc_set_line_ending(d, .LF)
				to_lf := doc_debug_string(d)
				ok := to_crlf == want_crlf && to_lf == want_lf && crlf_eol == .CRLF && d.eol == .LF
				fmt.printfln(
					"  %-6s Line Endings rows leave a lone CR alone: %q -> CRLF %q (want %q) -> LF %q (want %q)",
					"ok" if ok else "FAIL", text, to_crlf, want_crlf, to_lf, want_lf,
				)
				if !ok {bad += 1}
				return
			}
			// Both endings present: the LF converts, the CR does not, and going back
			// leaves the CR where it was rather than eating it as half a pair.
			bad += eol_row_case("a\rb\nc", "a\rb\r\nc", "a\rb\nc")
			// A CR at the very end is the branch a lookahead-bounds slip gets wrong.
			bad += eol_row_case("a\nb\r", "a\r\nb\r", "a\nb\r")
			// Nothing but lone CRs: the early return fires, so the text is untouched
			// AND no undo step is pushed -- assert the second half too, or this case
			// passes for an implementation that rewrites the buffer to itself.
			{
				a: App
				defer app_destroy(&a)
				c := make([]u8, 3);copy(c, transmute([]u8)string("a\rb"))
				d := new(Document)
				d^ = doc_from_content(c, "", .UTF8)
				d.eol = .LF
				app_add(&a, d)
				app_activate(&a, 0)
				doc_set_line_ending(d, .CRLF)
				ok := doc_debug_string(d) == "a\rb" && d.eol == .CRLF && len(d.undo) == 0
				fmt.printfln(
					"  %-6s an all-lone-CR buffer takes the no-op path: text=%q eol=%v undo=%d",
					"ok" if ok else "FAIL", doc_debug_string(d), d.eol, len(d.undo),
				)
				if !ok {bad += 1}
			}

			fmt.printfln("enctest: %d failures", bad)
			return true
		}

		// `newtpad sessiontest` round-trips session save -> restore. Set
		// NEWTPAD_SESSION_DIR to a temp dir first — without it this writes to, and
		// then resets, the real session under %APPDATA%\Newtpad.
		if os.args[1] == "sessiontest" {
			if !require_scratch_session("sessiontest") {return true}
			bad := 0
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

			// A stored table view against a .txt must not come back on. Written by
			// hand because save() can only produce views that were legal when they
			// were saved; a session from another build, or an edited one, cannot.
			{
				dir, _ := session_dir()
				txtf := fmt.tprintf("%s%cnewtpad_sess_v4.txt", os.get_env("TEMP", context.temp_allocator), '\\')
				plat.file_write_atomic(txtf, transmute([]u8)string("plain,text,file\n"))
				line := fmt.tprintf("0 0 0 0 0 -1 0 0 0 0 2 1 %s\n", txtf)
				body := fmt.tprintf("newtpad-session 4\nactive 0\n%s", line)
				sp, _ := filepath.join({dir, "session.txt"}, context.temp_allocator)
				plat.file_write_atomic(sp, transmute([]u8)body)

				v: App
				vok := session_restore(&v)
				vd := app_active(&v)
				good := vok && vd != nil && !vd.table && vd.md_mode == .Off
				fmt.printfln(
					"  %-6s a .txt restored with md_mode=2 table=1 comes back plain: ok=%v table=%v md_mode=%v",
					"ok" if good else "FAIL", vok, vd != nil && vd.table, Md_Mode.Off if vd == nil else vd.md_mode,
				)
				if !good {bad += 1}
				app_destroy(&v)
			}

			// Round-trip: a .md left in Split and a .csv left in Table come back
			// that way. The property task 5 of batch 2 could only assert as a
			// constant (session.txt did not carry a view at all) is now real.
			{
				mdf := fmt.tprintf("%s%cnewtpad_sess.md", os.get_env("TEMP", context.temp_allocator), '\\')
				csvf := fmt.tprintf("%s%cnewtpad_sess.csv", os.get_env("TEMP", context.temp_allocator), '\\')
				plat.file_write_atomic(mdf, transmute([]u8)string("# heading\n\ntext\n"))
				plat.file_write_atomic(csvf, transmute([]u8)string("a,b\n1,2\n"))

				w: App
				if fd, ok := doc_open(mdf); ok {
					d := new(Document);d^ = fd;d.md_mode = .Split
					app_add(&w, d)
				}
				if fd, ok := doc_open(csvf); ok {
					d := new(Document);d^ = fd;d.table = true;d.table_delim = ','
					app_add(&w, d)
				}
				session_save(&w)
				app_destroy(&w)

				x: App
				session_restore(&x)
				got_md, got_tbl := Md_Mode.Off, false
				for d in x.docs {
					if d == nil {continue}
					if strings.has_suffix(d.path, ".md") {got_md = d.md_mode}
					if strings.has_suffix(d.path, ".csv") {got_tbl = d.table}
				}
				rt := got_md == .Split && got_tbl
				fmt.printfln(
					"  %-6s view round-trips: md_mode=%v table=%v (want Split/true)",
					"ok" if rt else "FAIL", got_md, got_tbl,
				)
				if !rt {bad += 1}
				app_destroy(&x)
			}

			// A v3 session (eleven fields, no md_mode/table) must still load: the
			// old two fields simply aren't there, and the path is still the last field.
			{
				dir, _ := session_dir()
				v3f := fmt.tprintf("%s%cnewtpad_sess_v3.txt", os.get_env("TEMP", context.temp_allocator), '\\')
				plat.file_write_atomic(v3f, transmute([]u8)string("old format file\n"))
				line := fmt.tprintf("0 0 0 0 0 -1 0 0 0 0 %s\n", v3f)
				body := fmt.tprintf("newtpad-session 3\nactive 0\n%s", line)
				sp, _ := filepath.join({dir, "session.txt"}, context.temp_allocator)
				plat.file_write_atomic(sp, transmute([]u8)body)

				y: App
				yok := session_restore(&y)
				yd := app_active(&y)
				v3ok := yok && yd != nil && !yd.table && yd.md_mode == .Off && yd.path == v3f
				fmt.printfln(
					"  %-6s v3 session still loads: ok=%v table=%v md_mode=%v path_ok=%v",
					"ok" if v3ok else "FAIL", yok, yd != nil && yd.table, Md_Mode.Off if yd == nil else yd.md_mode, yd != nil && yd.path == v3f,
				)
				if !v3ok {bad += 1}
				app_destroy(&y)
			}

			// reset the session so the GUI doesn't restore this test's tabs
			empty: App
			app_new_scratch(&empty)
			session_save(&empty)
			app_destroy(&empty)
			fmt.printfln("sessiontest: %d failures", bad)
			return true
		}

		// `newtpad sessionlosstest <file>` — launching on a file used to skip session
		// restore, and the exit save then deleted every backup the resulting one-tab
		// session didn't reference, destroying unsaved scratch buffers. Set
		// NEWTPAD_SESSION_DIR to a temp dir before running.
		if os.args[1] == "sessionlosstest" && len(os.args) > 2 {
			if !require_scratch_session("sessionlosstest") {return true}
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

			// The pseudo-tab gate is NOT the menu's to keep. palette_execute calls
			// command_dispatch directly and consults no menu row, the palette draws
			// over the Settings page, and palette_click runs before main.odin's
			// pseudo-tab mouse-swallow -- so every rule the menus table used to hold
			// alone was reachable from here with a mouse. (Not with the keyboard: no
			// Ctrl chord resolves in the .Settings context.) These cases drive the
			// real palette path -- open, type the command's own title, pick its row,
			// execute -- against a Settings tab, and assert the pseudo-document is
			// untouched. Refused at the dispatch layer, so they hold for the menu
			// route in the same breath.
			palette_pseudo_case :: proc(cmd: Command_Id, clip: string) -> (bad: int) {
				a: App
				wv: plat.Window // hwnd nil: the clipboard takes a nil owner (pastetest)
				a.settings = settings_default()
				app_open_special(&a, .Settings)
				defer app_destroy(&a)
				d := app_active(&a)
				if clip != "" {plat.clipboard_set_text(nil, clip)}
				palette_open(&a)
				palette_input_rune(&a, '>')
				for r in command_table[cmd].title {palette_input_rune(&a, r)}
				// Find the row rather than trusting the fuzzy ranking to put an exact
				// title first: the point is what happens when the user picks it.
				row := -1
				for res, i in a.palette.results {
					if res.cmd == cmd {row = i}
				}
				if row < 0 {
					// Not a pass. If the command stops being offered the case stops
					// testing anything, and silence there is how a test rots.
					fmt.printfln("  FAIL   %v is not in the palette at all, so this case proves nothing", cmd)
					return 1
				}
				a.palette.selected = row
				palette_execute(&a, &wv, nil, 10)
				// d.eol carries the Eol_* case on its own: the pseudo-buffer is empty,
				// so doc_set_line_ending takes its length-equality early return and
				// sets doc.eol WITHOUT marking the document modified. Assert only the
				// buffer and the modified flag and that case can never go red.
				ok := d.pt.length == 0 && !d.modified && d.enc == .UTF8 && d.eol == .LF
				fmt.printfln(
					"  %-6s palette %-20v refused on a Settings tab: bytes=%d modified=%v enc=%v eol=%v",
					"ok" if ok else "FAIL", cmd, d.pt.length, d.modified, d.enc, d.eol,
				)
				if !ok {bad += 1}
				return
			}
			{
				// The user's clipboard, restored on every exit path.
				saved_clip, had_clip := plat.clipboard_get_text(nil, context.allocator)
				defer if had_clip {
					plat.clipboard_set_text(nil, saved_clip)
					delete(saved_clip)
				}
				pbad := 0
				// Paste is the finding's own reproduction: the clipboard landed in the
				// pseudo-document and left it .modified, so closing the tab raised a
				// save-changes dialog for a page with no file.
				pbad += palette_pseudo_case(.Paste, "clipboard text")
				// Enc_UTF16LE is the same hole one menu over -- it sets doc.modified
				// without touching the buffer, so a buffer-only assertion would miss it.
				pbad += palette_pseudo_case(.Enc_UTF16LE, "")
				// Eol_CRLF rewrites the WHOLE buffer (doc_set_line_ending), which is why
				// it counts as a mutation even though the pseudo-buffer is empty.
				pbad += palette_pseudo_case(.Eol_CRLF, "")
				fmt.printfln("palette pseudo-tab gate: %d failures", pbad)
			}
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

			// --- batch 7: a MID-LINE tab, the case the dump above cannot reach --
			// Neither fixture above contains a tab, and every tab in every other
			// suite is a leading one -- which is 4 cells under fixed-width tabs
			// and under true tab stops alike. These two are the only wrap checks
			// that can tell the two apart.
			bad := 0

			// wrap_row_end. "ab\tcd efghijkl" at 8 cells: the tab starts at
			// column 2, so it is 2 cells wide and 'e' is the last rune that fits
			// -- the break falls back to the space at byte 5, giving [0,6).
			// Under a fixed four the tab would end at column 6, 'd' would fill
			// column 8, and the break would fall back to the TAB at byte 3
			// instead, giving [0,3). Sabotage the tab branch back to a constant
			// and this prints 3.
			tab_wrap :: proc(t: ^plat.Text) -> (bad: int) {
				content := "ab\tcd efghijkl"
				doc: Document
				doc.pt = base.pt_init(transmute([]u8)content)
				defer base.pt_destroy(&doc.pt)
				e, le := wrap_row_end(&doc, t, 0, 8)
				ok := e == 6 && !le
				fmt.printfln(
					"  %-6s mid-line tab: wrap_row_end(%q, 8 cells) = [0,%d) line_end=%v (want [0,6), false; a fixed-4 tab gives [0,3))",
					"ok" if ok else "FAIL", content, e, le,
				)
				if !ok {bad += 1}
				return
			}
			bad += tab_wrap(&t)

			// The batch's HEADLINE decision, which nothing above can observe:
			// TAB STOPS ARE MEASURED FROM THE VISUAL ROW START, NOT THE LOGICAL
			// LINE START. tab_wrap measures the FIRST visual row, where the two
			// origins are the same number, so it cannot tell them apart. This
			// puts the tab on a CONTINUATION row, where they differ, and it is
			// the only check in the tree that would notice a future refactor
			// threading a logical-line column through wrap_row_end.
			//
			// "abcde f\thijk" at 6 cells. Row 1 breaks at the space: [0,6). Row 2
			// starts at byte 6 mid-line (pt_line_start(6) == 0 -- there is no
			// newline in the fixture, so this really is a continuation row).
			//
			//   from the ROW start (correct): 'f' at column 0 -> 1, the tab at
			//   column 1 advances 3 to column 4, 'h' 5, 'i' 6, and 'j' does not
			//   fit -- the break falls back to just after the tab, [6,8).
			//
			//   from the LOGICAL LINE start: row 2 begins at logical column 6, so
			//   the tab sits at column 7 and advances 1, not 3. Everything then
			//   fits and the row runs to the end of the buffer, [6,12) line_end.
			tab_wrap_continuation :: proc(t: ^plat.Text) -> (bad: int) {
				content := "abcde f\thijk"
				doc: Document
				doc.pt = base.pt_init(transmute([]u8)content)
				defer base.pt_destroy(&doc.pt)

				e1, le1 := wrap_row_end(&doc, t, 0, 6)
				r1 := e1 == 6 && !le1 && base.pt_line_start(&doc.pt, 6) == 0
				fmt.printfln(
					"  %-6s continuation setup: row 1 = [0,%d) line_end=%v, and byte 6 is mid-LINE (line start %d) -- want [0,6), false, 0",
					"ok" if r1 else "FAIL", e1, le1, base.pt_line_start(&doc.pt, 6),
				)
				if !r1 {bad += 1}

				e2, le2 := wrap_row_end(&doc, t, 6, 6)
				r2 := e2 == 8 && !le2
				fmt.printfln(
					"  %-6s tab on a CONTINUATION row measures from the ROW start: wrap_row_end(%q, from 6, 6 cells) = [6,%d) line_end=%v (want [6,8), false; measuring from the LOGICAL line start gives [6,12), true)",
					"ok" if r2 else "FAIL", content, e2, le2,
				)
				if !r2 {bad += 1}
				return
			}
			bad += tab_wrap_continuation(&t)

			// line_wrap_decision, through eff_wrap_at (its only non-file-private
			// caller). "a\t" repeated: each pair lands the tab at column 1, so it
			// advances 3 and the pair costs exactly 4 cells. 256 pairs is 1024
			// cells -- NOT over WRAP_LONG_CELLS, so the line must not force-wrap.
			// Under a fixed four each pair costs 5, 256 pairs is 1280, and the
			// line force-wraps. The 300-pair case is the control: 1200 cells is
			// over the threshold under either behaviour, so a check stuck at
			// `false` fails it.
			tab_wrap_decision :: proc(t: ^plat.Text) -> (bad: int) {
				one :: proc(t: ^plat.Text, pairs: int, want: bool) -> bool {
					content := strings.concatenate({strings.repeat("a\t", pairs), "\n"}, context.temp_allocator)
					doc: Document
					doc.pt = base.pt_init(transmute([]u8)content)
					defer base.pt_destroy(&doc.pt)
					doc.wrap = false
					got, _ := eff_wrap_at(&doc, t, 0)
					ok := got == want
					fmt.printfln(
						"  %-6s %d x \"a\\t\" = %d cells: force-wraps=%v (want %v; a fixed-4 tab makes it %d cells)",
						"ok" if ok else "FAIL", pairs, pairs * 4, got, want, pairs * 5,
					)
					return ok
				}
				if !one(t, 256, false) {bad += 1} // 1024 cells: exactly at, not over, the threshold
				if !one(t, 300, true) {bad += 1} // 1200 cells: over it under either behaviour
				return
			}
			bad += tab_wrap_decision(&t)

			fmt.printfln("wraptest: %d failures", bad)
			return true
		}

		// `newtpad rowtest` dumps the visible rows for buffers with and without a
		// trailing newline, and where the caret lands in each. A buffer whose last
		// line runs to EOF has no successor row; emitting one puts the caret on it.
		if os.args[1] == "rowtest" {
			t: plat.Text
			if !plat.text_load_faces(&t) {
				fmt.eprintln("rowtest: no fonts loaded")
				return true
			}
			fail := false
			one :: proc(content: string, caret: int, want_rows: int, want_caret_row: int, t: ^plat.Text, fail: ^bool) {
				doc: Document
				doc.pt = base.pt_init(transmute([]u8)content)
				defer base.pt_destroy(&doc.pt)
				doc.cursor, doc.anchor = caret, caret
				doc.view_cols = 40
				rows := 0
				caret_row := -1
				it := visible_begin(&doc, t, 10)
				for {
					row, start, _, vis_end, line_end, _, ok := visible_next(&it)
					if !ok {break}
					rows += 1
					if doc.cursor >= start && doc.cursor <= vis_end && (line_end || doc.cursor < vis_end) {
						caret_row = row // last match wins, exactly as doc_draw does
					}
				}
				ok := rows == want_rows && caret_row == want_caret_row
				if !ok {fail^ = true}
				fmt.printfln(
					"  %-6s %q caret=%d -> rows=%d (want %d) caret_row=%d (want %d)",
					"ok" if ok else "FAIL",
					content,
					caret,
					rows,
					want_rows,
					caret_row,
					want_caret_row,
				)
			}
			fmt.println("rowtest:")
			one("", 0, 1, 0, &t, &fail) // empty scratch: one row, caret on it
			one("a", 1, 1, 0, &t, &fail) // THE BUG: caret must stay on row 0
			one("ab", 2, 1, 0, &t, &fail)
			one("a\n", 2, 2, 1, &t, &fail) // trailing newline: the empty last row is real
			one("a\nb", 3, 2, 1, &t, &fail)
			one("a\nb\n", 4, 3, 2, &t, &fail)

			// The wrap-aware sibling of next_row_start_capped is next_visual_row (via
			// eff_next_row), and it had the identical ambiguity: wrap_row_end returns
			// (L, true) both for a real trailing newline and for running to EOF with
			// none, and eff_next_row's old `ok := nv > p` reported a successor row that
			// doesn't exist in the EOF case. visible_next's own wrap-stop logic (below,
			// at the `it.cur_wrap` branch) already gets this right and never calls
			// eff_next_row, so it can't exercise the bug -- unlike doc_cursor_down,
			// doc_scroll and doc_ensure_cursor_visible, which do. Check eff_next_row
			// directly. doc.wrap is forced on because force-wrap alone needs
			// WRAP_LONG_CELLS (1024) cells, far more than this line has.
			{
				long := "the quick brown fox jumps over the lazy dog and keeps going well past one row"
				ldoc: Document
				ldoc.pt = base.pt_init(transmute([]u8)long)
				defer base.pt_destroy(&ldoc.pt)
				ldoc.wrap = true
				ldoc.view_cols = 40
				// Row 0 is "the quick brown fox jumps over the lazy " (40 cells, break
				// after the last space that fits): a genuine mid-line wrap point, so a
				// real successor row follows at 40.
				s1, ok1 := eff_next_row(&ldoc, &t, 0, ldoc.view_cols)
				c1 := ok1 && s1 == 40
				if !c1 {fail = true}
				fmt.printfln(
					"  %-6s eff_next_row wrap mid-line -> start=%d ok=%v (want start=40 ok=true)",
					"ok" if c1 else "FAIL",
					s1,
					ok1,
				)
				// Row 1, "dog and keeps going well past one row" (37 cells), runs to EOF
				// with no newline: THE BUG. eff_next_row must report no successor.
				s2, ok2 := eff_next_row(&ldoc, &t, 40, ldoc.view_cols)
				c2 := !ok2
				if !c2 {fail = true}
				fmt.printfln(
					"  %-6s eff_next_row wrap at EOF -> start=%d ok=%v (want ok=false)",
					"ok" if c2 else "FAIL",
					s2,
					ok2,
				)
				// The symmetric wrong fix: folding "ends at EOF" and "ends at a real
				// newline" together (testing e.g. `e >= doc.pt.length` unconditionally)
				// would discard the legitimate empty final row on a wrapped line that
				// DOES end with a newline. Same line, with "\n" appended.
				longnl := strings.concatenate({long, "\n"}, context.temp_allocator)
				nldoc: Document
				nldoc.pt = base.pt_init(transmute([]u8)longnl)
				defer base.pt_destroy(&nldoc.pt)
				nldoc.wrap = true
				nldoc.view_cols = 40
				s3, ok3 := eff_next_row(&nldoc, &t, 40, nldoc.view_cols)
				c3 := ok3 && s3 == len(longnl)
				if !c3 {fail = true}
				fmt.printfln(
					"  %-6s eff_next_row wrap at real newline -> start=%d ok=%v (want start=%d ok=true)",
					"ok" if c3 else "FAIL",
					s3,
					ok3,
					len(longnl),
				)
			}
			fmt.println("rowtest: FAILURES" if fail else "rowtest: all ok")
			return true
		}

		// `newtpad themetest` proves theme_dark() only ever holds colours that
		// genuinely appeared in the pre-migration UI. Dark is a *consolidation*
		// (66 faithful roles collapsed to 25 by merging near-duplicate greys), so
		// it is no longer pixel-identical to the old literals -- the old "every
		// value equals the one literal it replaces" guard doesn't apply anymore.
		// What replaces it: each role may hold any one of the several literals
		// the spec's merge table says that role absorbs (see
		// docs/superpowers/specs/2026-07-25-theme-model-design.md, "The role
		// table"). The absorbed-set lists below are retyped from that spec table,
		// not copied out of theme_dark -- copying from the theme would make this
		// test agree with a transposed digit instead of catching one.
		if os.args[1] == "themetest" {
			if !require_scratch_session("themetest") {return true}
			d := theme_dark()
			fail := false

			// Every role must be non-zero: zero is transparent black, Odin's
			// default for a Theme entry nobody wrote a value for -- an invisible
			// hole rather than an obvious error (see theme.odin's header comment).
			for role in Color_Role {
				if d[role] == ([4]f32{0, 0, 0, 0}) {
					fmt.printfln("  FAIL   %v is zero (unfilled Dark slot)", role)
					fail = true
				}
			}

			// No role in EITHER built-in may still hold the magenta placeholder
			// {1,0,1,1}. Batch 3 planted that in theme_dark for the nine Syn_*
			// roles as a deliberate "missing texture" marker; batch 4 shipped the
			// lexers that consume them and never replaced it, so every highlighted
			// file rendered identically magenta in Dark for a whole release. This
			// is the check that would have caught it. Both built-ins are checked
			// because the same omission is available to either one.
			//
			// Note this deliberately tests theme_dark()/theme_light() only, never a
			// theme loaded from a file: `caret #ff00ff` is a legitimate colour for
			// a user to write, and the file round-trip test below uses exactly that
			// value.
			{
				placeholder := [4]f32{1, 0, 1, 1}
				l := theme_light()
				for role in Color_Role {
					if d[role] == placeholder {
						fmt.printfln("  FAIL   %v is still the magenta placeholder in Dark", role)
						fail = true
					}
					if l[role] == placeholder {
						fmt.printfln("  FAIL   %v is still the magenta placeholder in Light", role)
						fail = true
					}
				}
				fmt.println("  ok     no built-in role holds the magenta placeholder")
			}

			// Two role pairs sit next to each other on screen and must not read as
			// the same colour. Both are lifted from HANDOFF 6w's "what only Wyatt
			// can check" list, so they stop depending on someone noticing:
			//
			//   Syn_Comment vs Text_Muted -- the gutter line numbers are Text_Muted
			//   and sit immediately beside comment text.
			//   Syn_Punct vs Text_Primary -- if punctuation reads as body text,
			//   every .Punct token batch 4 emits is wasted work.
			//
			// The bar is max absolute per-channel difference >= 0.10 (~26/255). That
			// is a floor against the two being set equal or near-equal, NOT a claim
			// that 0.10 is perceptually sufficient -- only Wyatt's eye settles that.
			{
				max_chan_diff :: proc(a, b: [4]f32) -> f32 {
					m: f32 = 0
					for i in 0 ..< 3 {
						dch := a[i] - b[i]
						if dch < 0 {dch = -dch}
						if dch > m {m = dch}
					}
					return m
				}
				pairs := []struct {
					a, b: Color_Role,
				}{{.Syn_Comment, .Text_Muted}, {.Syn_Punct, .Text_Primary}}
				for p in pairs {
					diff := max_chan_diff(d[p.a], d[p.b])
					ok := diff >= 0.10
					if !ok {fail = true}
					fmt.printfln("  %-6s Dark %v vs %v: max channel diff %.3f (need >= 0.10)", "ok" if ok else "FAIL", p.a, p.b, diff)
				}
			}

			// The role<->key mapping is a total array over Color_Role, so a role
			// with NO key is a compile error rather than a test failure -- that is
			// the point of the array, and it is the property whose absence let the
			// nine Syn_* roles ship unsettable from a file. What the array cannot
			// catch is a typo'd or duplicated key, so that is what this checks:
			// every key non-empty, every key unique, and both directions agreeing.
			{
				seen := make(map[string]Color_Role, len(Color_Role), context.temp_allocator)
				for role in Color_Role {
					key := theme_key_from_role(role)
					if key == "" {
						fmt.printfln("  FAIL   %v has an empty file key", role)
						fail = true
						continue
					}
					if prev, dup := seen[key]; dup {
						fmt.printfln("  FAIL   key %q maps to both %v and %v", key, prev, role)
						fail = true
						continue
					}
					seen[key] = role
					back, ok := theme_role_from_key(key)
					if !ok || back != role {
						fmt.printfln("  FAIL   %v -> %q -> %v (ok=%v): key does not round-trip", role, key, back, ok)
						fail = true
					}
				}
				fmt.printfln("  ok     all %d role keys are non-empty, unique and round-trip", len(Color_Role))
			}

			// "base" is not a role and must never resolve to one -- it selects
			// which built-in theme_load_file overlays onto. A role named "base"
			// would silently capture that line and change which theme you get.
			{
				_, is_role := theme_role_from_key("base")
				ok := !is_role
				if !ok {fail = true}
				fmt.printfln("  %-6s \"base\" is not a role key", "ok" if ok else "FAIL")
			}

			in_set :: proc(got: [4]f32, set: [][4]f32) -> bool {
				for v in set {if got == v {return true}}
				return false
			}
			chk :: proc(d: Theme, role: Color_Role, absorbs: [][4]f32, fail: ^bool) {
				got := d[role]
				ok := in_set(got, absorbs)
				if !ok {fail^ = true}
				fmt.printfln("  %-6s %-16v got=%v absorbs=%v", "ok" if ok else "FAIL", role, got, absorbs)
			}

			fmt.println("themetest:")
			// Neutrals: 10 roles absorbing 42 values across 81 sites.
			chk(d, .Bg_Base, {{0.09, 0.11, 0.16, 1}, {0.10, 0.12, 0.16, 1}, {0.11, 0.13, 0.17, 1}}, &fail) // #171C29 #1A1F29 #1C212B
			chk(
				d,
				.Bg_Panel,
				{{0.12, 0.14, 0.18, 1}, {0.12, 0.14, 0.19, 1}, {0.13, 0.15, 0.20, 1}, {0.14, 0.16, 0.20, 1}, {0.14, 0.16, 0.21, 1}, {0.15, 0.17, 0.22, 1}},
				&fail,
			) // #1F242E #1F2430 #212633 #242933 #242936 #262B38
			chk(d, .Bg_Raised, {{0.16, 0.18, 0.22, 1}, {0.16, 0.20, 0.27, 1}}, &fail) // #292E38 #293345
			chk(d, .Border_Subtle, {{0.20, 0.23, 0.30, 1}, {0.24, 0.27, 0.33, 1}}, &fail) // #333B4C #3D4554
			chk(d, .Border_Strong, {{0.28, 0.32, 0.40, 1}, {0.30, 0.34, 0.42, 1}}, &fail) // #475266 #4C576B
			chk(
				d,
				.Text_Muted,
				{
					{0.42, 0.46, 0.54, 1},
					{0.42, 0.47, 0.56, 1},
					{0.42, 0.48, 0.60, 1},
					{0.45, 0.49, 0.57, 1},
					{0.48, 0.52, 0.60, 1},
					{0.50, 0.54, 0.62, 1},
					{0.50, 0.55, 0.64, 1},
				},
				&fail,
			) // #6B758A #6B788F #6B7A99 #737D91 #7A8599 #808A9E #808CA3
			chk(
				d,
				.Text_Dim,
				{{0.55, 0.60, 0.70, 1}, {0.58, 0.64, 0.76, 1}, {0.60, 0.64, 0.72, 1}, {0.62, 0.68, 0.80, 1}, {0.66, 0.70, 0.78, 1}},
				&fail,
			) // #8C99B2 #94A3C2 #99A3B8 #9EADCC #A8B2C7
			chk(
				d,
				.Text_Secondary,
				{{0.72, 0.76, 0.84, 1}, {0.72, 0.78, 0.88, 1}, {0.75, 0.79, 0.86, 1}, {0.75, 0.80, 0.88, 1}, {0.80, 0.84, 0.90, 1}},
				&fail,
			) // #B8C2D6 #B8C7E0 #BFC9DB #BFCCE0 #CCD6E6
			chk(
				d,
				.Text_Primary,
				{{0.86, 0.90, 0.96, 1}, {0.88, 0.91, 0.96, 1}, {0.90, 0.92, 0.97, 1}, {0.92, 0.94, 0.98, 1}, {0.94, 0.96, 0.99, 1}, {0.95, 0.96, 0.99, 1}},
				&fail,
			) // #DBE6F5 #E0E8F5 #E6EBF7 #EBF0FA #F0F5FC #F2F5FC
			chk(d, .Text_Bright, {{0.96, 0.96, 0.98, 1}, {0.98, 0.99, 1.0, 1}, {1, 1, 1, 1}, {0.82, 0.90, 0.98, 1}}, &fail) // #F5F5FA #FAFCFF #FFFFFF #D1E6FA

			// Accents: 15 roles, each carrying real meaning.
			chk(d, .Selection_Doc, {{0.20, 0.30, 0.48, 1}}, &fail) // #334C7A
			chk(d, .Selection_List, {{0.20, 0.28, 0.42, 1}, {0.20, 0.30, 0.45, 1}, {0.24, 0.30, 0.42, 1}, {0.18, 0.24, 0.34, 1}}, &fail) // #33476B #334C73 #3D4C6B #2E3D57
			chk(d, .Caret, {{0.95, 0.85, 0.35, 1}}, &fail) // #F2D959
			chk(d, .Accent, {{0.95, 0.88, 0.55, 1}, {0.80, 0.76, 0.50, 1}}, &fail) // #F2E08C #CCC280
			chk(d, .Find_Match_Bg, {{0.42, 0.38, 0.16, 1}}, &fail) // #6B6129
			chk(d, .Link, {{0.45, 0.70, 0.98, 1}}, &fail) // #73B2FA
			chk(d, .Warning, {{0.95, 0.55, 0.35, 1}}, &fail) // #F28C59
			chk(d, .Danger, {{0.75, 0.16, 0.16, 1}}, &fail) // #BF2929
			chk(d, .Success, {{0.55, 0.85, 0.60, 1}}, &fail) // #8CD999
			chk(d, .Filter_Bg, {{0.18, 0.26, 0.20, 1}}, &fail) // #2E4233
			chk(d, .Filter_Text, {{0.70, 0.90, 0.74, 1}}, &fail) // #B2E6BD
			chk(d, .Md_Heading, {{0.72, 0.85, 1.0, 1}}, &fail) // #B8D9FF
			chk(d, .Md_Code, {{0.95, 0.80, 0.65, 1}}, &fail) // #F2CCA6
			chk(d, .Md_Italic, {{0.80, 0.86, 0.78, 1}}, &fail) // #CCDBC7
			chk(d, .Md_Quote, {{0.66, 0.72, 0.62, 1}}, &fail) // #A8B89E

			// Light is the theme that can actually fail (see theme.odin's
			// theme_light comment and task-4-report.md): every one of Dark's
			// values was chosen against a dark background, so nothing here
			// checks Light against an absorbed-literal list the way Dark is
			// checked above -- there is no pre-migration light UI to derive one
			// from. What Light must prove instead:
			//
			//   1. every role is non-zero, same reasoning as Dark: a zero slot
			//      renders as invisible transparent black, not an obvious error.
			//   2. Light differs from Dark in every role that isn't deliberately
			//      shared -- a light theme authored by copying theme_dark() and
			//      editing a few fields would pass check 1 while silently
			//      leaving most roles dark-only, and check 1 alone would not
			//      catch it. The one deliberately shared role, and why, is
			//      documented right above Danger's line in theme_light().
			l := theme_light()

			// The only role deliberately identical between the two themes, and
			// why -- see also the note above Danger's line in theme_light().
			is_shared_role :: proc(role: Color_Role) -> (shared: bool, reason: string) {
				#partial switch role {
				case .Danger:
					return true, "solid opaque hover fill, never blended with either theme's chrome; Windows renders the close-tab hover in the same red regardless of system theme"
				}
				return false, ""
			}

			for role in Color_Role {
				if l[role] == ([4]f32{0, 0, 0, 0}) {
					fmt.printfln("  FAIL   %v is zero (unfilled Light slot)", role)
					fail = true
				}
			}

			for role in Color_Role {
				is_shared, reason := is_shared_role(role)
				same := l[role] == d[role]
				ok := same == is_shared // shared roles MUST match; every other role MUST differ
				if !ok {
					if is_shared {
						fmt.printfln("  FAIL   %v is declared shared with Dark but Light's value differs", role)
					} else {
						fmt.printfln("  FAIL   %v Light == Dark (%v) but this role is not on the shared list -- accidental dark-value inheritance", role, l[role])
					}
					fail = true
				} else if is_shared {
					fmt.printfln("  ok     %v shared with Dark: %s", role, reason)
				}
			}

			// --- theme files: loading from disk (Task 5) ---
			//
			// Mirrors settings_load's shape exactly: same `key value` per-line
			// parse, same "unknown key ignored" contract (theme_role_from_key),
			// same "start from a valid default and overlay" so a partial file is
			// valid (theme_load_file). Everything below writes only under
			// NEWTPAD_SESSION_DIR/themes -- require_scratch_session at the top of
			// this mode already refused to run without that set, so none of this
			// touches the real %APPDATA%\Newtpad.
			// _ensure: this block writes .theme files below, the one legitimate
			// reason to create the directory (see themes_dir_ensure's comment).
			tdir, tdir_ok := themes_dir_ensure()
			if !tdir_ok {
				fmt.println("  FAIL   themetest: themes_dir unavailable")
				fail = true
			} else {
				write_theme_file :: proc(dir, name, body: string) -> string {
					path := fmt.tprintf("%s%c%s.theme", dir, '\\', name)
					_ = os.write_entire_file(path, body)
					return path
				}

				// A file naming several roles round-trips: every named role comes
				// back exactly as written. Expected colours are computed the same
				// way theme_parse_hex does (f32(digit-pair) / 255), not by
				// reusing theme_parse_hex itself, so a bug in that arithmetic
				// can't hide behind agreeing with its own test.
				{
					path := write_theme_file(tdir, "roundtrip", "bg_base #112233\ntext_primary #aabbcc\ncaret #ff00ff\n")
					got := theme_load_file(path, d)
					want_bg := [4]f32{f32(0x11) / 255, f32(0x22) / 255, f32(0x33) / 255, 1}
					want_tp := [4]f32{f32(0xaa) / 255, f32(0xbb) / 255, f32(0xcc) / 255, 1}
					want_caret := [4]f32{1, 0, 1, 1}
					ok := got[.Bg_Base] == want_bg && got[.Text_Primary] == want_tp && got[.Caret] == want_caret
					if !ok {fail = true}
					fmt.printfln(
						"  %-6s file round-trip: bg_base=%v text_primary=%v caret=%v",
						"ok" if ok else "FAIL",
						got[.Bg_Base],
						got[.Text_Primary],
						got[.Caret],
					)
					os.remove(path)
				}

				// A partial file -- naming only one role -- leaves every role it
				// doesn't mention at the base's built-in value.
				{
					path := write_theme_file(tdir, "partial", "accent #ffaa00\n")
					got := theme_load_file(path, d)
					changed := got[.Accent] == [4]f32{1, f32(0xaa) / 255, 0, 1}
					untouched := got[.Md_Quote] == d[.Md_Quote] && got[.Bg_Base] == d[.Bg_Base] && got[.Text_Primary] == d[.Text_Primary]
					ok := changed && untouched
					if !ok {fail = true}
					fmt.printfln(
						"  %-6s partial file: named role changed=%v, unmentioned roles untouched=%v",
						"ok" if ok else "FAIL",
						changed,
						untouched,
					)
					os.remove(path)
				}

				// An unknown role name is skipped, not fatal -- the rest of the
				// file still loads.
				{
					path := write_theme_file(tdir, "unknownrole", "not_a_real_role #ffffff\nlink #112233\n")
					got := theme_load_file(path, d)
					ok := got[.Link] == [4]f32{f32(0x11) / 255, f32(0x22) / 255, f32(0x33) / 255, 1}
					if !ok {fail = true}
					fmt.printfln("  %-6s unknown role name ignored, rest of file still applied: link=%v", "ok" if ok else "FAIL", got[.Link])
					os.remove(path)
				}

				// Each malformed-colour form leaves that role at the built-in
				// value -- never the zero value, which is transparent black and
				// would render as an invisible hole rather than an obvious error.
				{
					path := write_theme_file(
						tdir,
						"malformed",
						"border_strong #zzz\ntext_dim #12\nwarning 1122334\ndanger #1122334\n",
					)
					got := theme_load_file(path, d)
					roles := []Color_Role{.Border_Strong, .Text_Dim, .Warning, .Danger}
					labels := []string{"#zzz (non-hex digits)", "#12 (too short)", "1122334 (missing #)", "#1122334 (wrong length)"}
					for role, i in roles {
						v := got[role]
						// Checked and reported separately, not folded into one `ok :=
						// fell_back && never_black`: fell_back == (v == d[role]) and
						// d[role] is already known non-black (the "every role must be
						// non-zero" loop above already proved that for Dark), so
						// never_black was mathematically implied by fell_back and could
						// never independently fail or independently surface in the
						// printed line -- exactly the "conjunct that cannot fail" shape
						// CLAUDE.md calls out. Splitting them means a future built-in
						// that DID hold a black role would still be caught here instead
						// of being silently absorbed into fell_back's pass.
						never_black := v != ([4]f32{0, 0, 0, 0}) && v != ([4]f32{0, 0, 0, 1})
						if !never_black {
							fmt.printfln("  FAIL   malformed %-28s -> %v is black (should have fallen back)", labels[i], v)
							fail = true
						}
						fell_back := v == d[role]
						if !fell_back {
							fmt.printfln("  FAIL   malformed %-28s -> %v did not fall back to built-in %v", labels[i], v, d[role])
							fail = true
						}
						if never_black && fell_back {
							fmt.printfln("  ok     malformed %-28s -> %v (built-in=%v)", labels[i], v, d[role])
						}
					}
					os.remove(path)
				}

				// Export writes every role, and what it writes parses back to the
				// same theme within the 8-bit limit of #rrggbb. The theme is
				// [4]f32 and the file format is 8 bits per channel, so an exact
				// round-trip is impossible by construction -- 0.10 * 255 = 25.5.
				// Two properties matter here, and they guard different things.
				// theme_chan_hex rounds to nearest, so a channel's drift is bounded
				// by half a step (0.5/255): this is the check that actually
				// distinguishes rounding from truncation -- truncation can drift up
				// to just under 1/255, which would slip under a 1/255 bound but not
				// under 0.5/255. The second property, a fixed point after one
				// round-trip, does NOT distinguish them: truncation is idempotent
				// too, so it is also a fixed point after one trip. That check
				// guards a different, real property -- see the comment below.
				{
					target, path, ok := theme_export("Dark", d)
					if !ok {
						fmt.println("  FAIL   theme_export(\"Dark\") failed")
						fail = true
					} else {
						first, rerr := os.read_entire_file(path, context.temp_allocator)
						if rerr != nil {
							fmt.println("  FAIL   exported theme file unreadable")
							fail = true
						} else {
							parsed := theme_load_file(path, theme_light()) // base must come from the file, not this arg
							worst: f32 = 0
							for role in Color_Role {
								for i in 0 ..< 4 {
									dch := parsed[role][i] - d[role][i]
									if dch < 0 {dch = -dch}
									if dch > worst {worst = dch}
								}
							}
							// theme_chan_hex rounds to nearest, so a correct implementation
							// bounds every channel's drift at half a step (0.5/255). This is
							// the bound that separates rounding from truncation: truncation
							// drifts up to just under 1/255, which is caught here even though
							// it slips past a looser 1/255 bound. If theme_chan_hex reverts to
							// truncation, this assertion -- not the fixed-point check below --
							// is the one that fails.
							within := worst <= (1.0 / 510.0) + 0.0001
							if !within {fail = true}
							fmt.printfln("  %-6s export round-trip: worst channel drift %.5f (need <= 0.5/255)", "ok" if within else "FAIL", worst)

							// Fixed point: exporting the PARSED theme must produce the
							// identical bytes -- exporting does not drift further on each
							// pass. This does NOT catch a reversion to truncation: truncation
							// is also idempotent after one trip through 8-bit quantization,
							// so it is a fixed point too. That regression is caught by the
							// drift bound above, not this check. The first file is removed so
							// the no-overwrite rule does not block the second write.
							os.remove(path)
							_, path2, ok2 := theme_export("Dark", parsed)
							second, rerr2 := os.read_entire_file(path2, context.temp_allocator)
							stable := ok2 && rerr2 == nil && string(first) == string(second)
							if !stable {fail = true}
							fmt.printfln("  %-6s export is a fixed point after one round-trip", "ok" if stable else "FAIL")
							os.remove(path2)
						}
					}
					_ = target
				}

				// The export must never destroy an existing file: it is the user's
				// tuning work, and the command that calls this is reachable at any
				// time. On an existing target the call succeeds and reports the
				// path, but writes nothing.
				{
					target := theme_export_target("Dark")
					path := fmt.tprintf("%s%c%s.theme", tdir, '\\', target)
					sentinel := "base dark\ncaret #010203\n"
					_ = os.write_entire_file(path, transmute([]u8)sentinel)
					_, got_path, ok := theme_export("Dark", d)
					after, _ := os.read_entire_file(path, context.temp_allocator)
					preserved := ok && got_path == path && string(after) == sentinel
					if !preserved {fail = true}
					fmt.printfln("  %-6s export refuses to overwrite an existing theme file", "ok" if preserved else "FAIL")
					os.remove(path)
				}

				// A '#' comment line is ignored, including one whose text contains
				// a role name -- the exported file is full of both.
				{
					path := write_theme_file(tdir, "comments", "# caret #ffffff is the caret colour\n#link #ffffff\nlink #112233\n")
					got := theme_load_file(path, d)
					ok := got[.Link] == [4]f32{f32(0x11) / 255, f32(0x22) / 255, f32(0x33) / 255, 1} && got[.Caret] == d[.Caret]
					if !ok {fail = true}
					fmt.printfln("  %-6s '#' comment lines ignored, including ones naming a role", "ok" if ok else "FAIL")
					os.remove(path)
				}

				// A built-in's name can never back a file: theme_resolve
				// short-circuits on "Dark"/"Light" before consulting disk, so such
				// a file would list in Settings and then do nothing when selected.
				{
					stray := fmt.tprintf("%s%cDark.theme", tdir, '\\')
					stray_body := "caret #010203\n"
					_ = os.write_entire_file(stray, transmute([]u8)stray_body)
					names := theme_available_names(context.temp_allocator)
					count := 0
					for n in names {if n == "Dark" {count += 1}}
					ok := count == 1 && theme_export_target("Dark") != "Dark" && theme_export_target("Light") != "Light"
					if !ok {fail = true}
					fmt.printfln("  %-6s a stray Dark.theme neither duplicates nor becomes an export target", "ok" if ok else "FAIL")
					os.remove(stray)
				}

				// A `base light` line overlays Light instead of the default
				// Dark -- an unnamed role (Md_Quote here) must hold Light's
				// value, not Dark's. This is the case the fix exists for: before
				// `base`, a custom theme had no way to express "start from
				// Light" at all, so a user on Light who picked any custom theme
				// got every unmentioned role silently reset to Dark's values.
				{
					path := write_theme_file(tdir, "baselight", "base light\naccent #ffaa00\n")
					got := theme_load_file(path, d)
					ok := got[.Md_Quote] == l[.Md_Quote] && got[.Md_Quote] != d[.Md_Quote]
					if !ok {fail = true}
					fmt.printfln(
						"  %-6s base light: unnamed role holds Light's value=%v (Dark's would be %v)",
						"ok" if ok else "FAIL",
						got[.Md_Quote],
						d[.Md_Quote],
					)
					os.remove(path)
				}

				// A `base dark` line and no `base` line at all both overlay
				// Dark -- `base` is opt-in, not required, so an existing file
				// written before this feature existed must keep behaving
				// exactly as it did.
				{
					path := write_theme_file(tdir, "basedark", "base dark\naccent #ffaa00\n")
					got := theme_load_file(path, d)
					ok := got[.Md_Quote] == d[.Md_Quote]
					if !ok {fail = true}
					fmt.printfln("  %-6s base dark: unnamed role holds Dark's value=%v", "ok" if ok else "FAIL", got[.Md_Quote])
					os.remove(path)

					path2 := write_theme_file(tdir, "nobase", "accent #ffaa00\n")
					got2 := theme_load_file(path2, d)
					ok2 := got2[.Md_Quote] == d[.Md_Quote]
					if !ok2 {fail = true}
					fmt.printfln("  %-6s no base line: unnamed role holds Dark's value=%v", "ok" if ok2 else "FAIL", got2[.Md_Quote])
					os.remove(path2)
				}

				// An unrecognized base value falls back to Dark, the same
				// "malformed input degrades" contract every other bad value in
				// this loader already has.
				{
					path := write_theme_file(tdir, "basebogus", "base solarized\naccent #ffaa00\n")
					got := theme_load_file(path, d)
					ok := got[.Md_Quote] == d[.Md_Quote]
					if !ok {fail = true}
					fmt.printfln("  %-6s unrecognized base falls back to Dark: %v", "ok" if ok else "FAIL", got[.Md_Quote])
					os.remove(path)
				}

				// `base` is recognized anywhere in the file, not only on the
				// first line -- this format has no ordering rules, so a `base`
				// line appearing after role lines must still apply to all of
				// them (a single-pass fold would only pick this up if `base`
				// happened to come first).
				{
					path := write_theme_file(tdir, "baselate", "accent #ffaa00\nmd_quote #112233\nbase light\n")
					got := theme_load_file(path, d)
					want_named := [4]f32{f32(0x11) / 255, f32(0x22) / 255, f32(0x33) / 255, 1}
					named_applied := got[.Md_Quote] == want_named
					unnamed_uses_light := got[.Text_Primary] == l[.Text_Primary] && got[.Text_Primary] != d[.Text_Primary]
					ok := named_applied && unnamed_uses_light
					if !ok {fail = true}
					fmt.printfln(
						"  %-6s base after role lines still applies: named role=%v, unnamed role uses Light=%v",
						"ok" if ok else "FAIL",
						got[.Md_Quote],
						unnamed_uses_light,
					)
					os.remove(path)
				}

				// Fresh install: settings_default leaves theme_name as the static
				// literal "Dark" (never cloned) until settings.txt actually
				// supplies a theme_name line, and no settings.txt exists yet
				// under this NEWTPAD_SESSION_DIR. This is the reachable crash a
				// stray delete() on theme_name used to hit -- HeapFree on a
				// pointer into .rdata -- so this case exercises the literal path
				// directly rather than the cloned one every other case here
				// starts from.
				{
					app_t: App
					menu_init(&app_t.menu)
					defer app_destroy(&app_t)
					app_t.settings = settings_default()
					g_saved := g_theme
					g_theme = theme_dark()

					ok_cmd := theme_edit_current(&app_t)
					switched := app_t.settings.theme_name == "Dark Custom"

					all_ok := ok_cmd && switched
					if !all_ok {fail = true}
					fmt.printfln(
						"  %-6s edit-current-theme survives a literal (un-cloned) theme_name: exported=%v switched=%v",
						"ok" if all_ok else "FAIL",
						ok_cmd,
						switched,
					)
					path, pok := theme_active_file_path(app_t.settings.theme_name)
					if pok {os.remove(path)}
					g_theme = g_saved
				}

				// The command's second-invocation shape: the theme file already
				// exists on disk (as it would after an earlier export or edit), so
				// theme_export writes nothing here and the state change under test
				// is purely the settings switch plus the re-resolve --
				// `g_theme = theme_resolve(target)` inside theme_edit_current.
				// This pre-writes a distinctive Dark Custom.theme file BEFORE
				// calling theme_edit_current and reads g_theme directly afterward,
				// with NO intervening theme_resolve call in this test: calling
				// theme_resolve a second time here would make this pass even with
				// that line deleted from the real procedure (verified by deleting
				// it and rerunning this mode -- see task-4-report.md).
				//
				// app_open_path is headless-safe -- it maps and activates a tab
				// like any other open, no window required -- so the opened tab is
				// asserted too, not skipped as needing one.
				{
					app_t: App
					menu_init(&app_t.menu)
					defer app_destroy(&app_t)
					app_t.settings.theme_name = strings.clone("Dark")
					g_saved := g_theme
					g_theme = theme_dark()

					path, pok := theme_active_file_path("Dark Custom")
					want := [4]f32{f32(0x01) / 255, f32(0x02) / 255, f32(0x03) / 255, 1}
					if pok {
						_ = os.write_entire_file(path, transmute([]u8)string("base dark\ncaret #010203\n"))
					}
					g_before := g_theme
					before_already_matches := g_before[.Caret] == want

					ok_cmd := theme_edit_current(&app_t)
					switched := app_t.settings.theme_name == "Dark Custom"
					on_disk := pok && os.exists(path)
					applied := g_theme[.Caret] == want
					opened_doc := app_active(&app_t)
					opened := pok && opened_doc != nil && opened_doc.path == path

					all_ok := ok_cmd && switched && on_disk && applied && opened && !before_already_matches
					if !all_ok {fail = true}
					fmt.printfln(
						"  %-6s edit-current-theme (file preexisting): exported=%v switched=%v on_disk=%v reresolved=%v opened=%v",
						"ok" if all_ok else "FAIL",
						ok_cmd,
						switched,
						on_disk,
						applied,
						opened,
					)
					if pok {os.remove(path)}
					g_theme = g_saved
				}

				// The comparison is the entire component, and its two inputs arrive
				// from different places -- doc.path (Save dialog, argv, or an
				// Explorer drop) versus themes_dir()'s constructed path -- so they
				// can name the same file in different case and with different
				// separators. Feeding it the export's own path back would prove
				// nothing: those two are identical by construction. Each case below
				// mangles the path deliberately.
				{
					app_t: App
					menu_init(&app_t.menu)
					defer app_destroy(&app_t) // App is zero-is-initialization
					app_t.settings.theme_name = strings.clone("Dark Custom")
					path, pok := theme_active_file_path("Dark Custom")
					g_saved := g_theme
					g_theme = theme_dark()
					_ = os.write_entire_file(path, transmute([]u8)string("base dark\ncaret #010203\n"))
					want := [4]f32{f32(0x01) / 255, f32(0x02) / 255, f32(0x03) / 255, 1}

					exact := pok && theme_reapply_if_active(&app_t, path) && g_theme[.Caret] == want

					g_theme = theme_dark()
					upper := theme_reapply_if_active(&app_t, strings.to_upper(path, context.temp_allocator)) && g_theme[.Caret] == want

					g_theme = theme_dark()
					fwd_path, _ := strings.replace_all(path, "\\", "/", context.temp_allocator)
					fwd := theme_reapply_if_active(&app_t, fwd_path) && g_theme[.Caret] == want

					g_theme = theme_dark()
					other := !theme_reapply_if_active(&app_t, fmt.tprintf("%s%cnot-the-theme.txt", tdir, '\\')) && g_theme[.Caret] == theme_dark()[.Caret]

					// A built-in has no file, so nothing can match it -- otherwise
					// saving any file at all while on Dark would re-resolve.
					delete(app_t.settings.theme_name)
					app_t.settings.theme_name = strings.clone("Dark")
					builtin := !theme_reapply_if_active(&app_t, path)

					all_ok := exact && upper && fwd && other && builtin
					if !all_ok {fail = true}
					fmt.printfln(
						"  %-6s reapply: exact=%v upper=%v fwdslash=%v other-file-ignored=%v builtin-ignored=%v",
						"ok" if all_ok else "FAIL",
						exact,
						upper,
						fwd,
						other,
						builtin,
					)
					if pok {os.remove(path)}
					g_theme = g_saved
				}
			}

			// settings_load no longer rejects an unresolvable theme_name -- it is
			// cloned unconditionally, the same as font_family, because the
			// rejection used to be destructive: theme_available_names' directory
			// read degrades to just the two built-ins on ANY failure (transient
			// or not), so validating on load meant a good custom theme name could
			// be silently and permanently overwritten with "Dark" by the very
			// next settings_save. Where the fallback behaviour now lives instead
			// is theme_resolve, so that -- not settings_load -- is what this
			// checks.
			{
				bogus := settings_default()
				bogus.theme_name = "TotallyBogusThemeName"
				settings_save(bogus)
				loaded := settings_load()
				preserved := loaded.theme_name == "TotallyBogusThemeName"
				fmt.printfln(
					"  %-6s settings_load preserves an unresolvable theme_name verbatim -> %q",
					"ok" if preserved else "FAIL",
					loaded.theme_name,
				)
				if !preserved {fail = true}

				resolved := theme_resolve(loaded.theme_name)
				falls_back := resolved == theme_dark()
				fmt.printfln("  %-6s theme_resolve on that name falls back to Dark", "ok" if falls_back else "FAIL")
				if !falls_back {fail = true}

				// Leave settings.txt in a known-good state for any later mode run
				// against the same NEWTPAD_SESSION_DIR in this process.
				settings_save(settings_default())
			}

			// The document-canvas clear colour (main.odin:842) reads doc_canvas_clear(),
			// not its own copy of Bg_Base -- see that proc's comment for the bug this
			// guards against (a loose three-scalar literal that quietly kept the old
			// Dark canvas colour after Light shipped, invisible to every `{r, g, b, a}`
			// grep this batch ran). Reading gfx_begin_frame's actual argument isn't
			// practical from here, so this proves the one thing that IS practical: the
			// helper is a live read of g_theme, not a cached/baked copy -- swap
			// g_theme[.Bg_Base] to a sentinel no real theme uses and confirm the helper
			// tracks it. A helper hard-coded to return its own literal (reintroducing
			// this exact bug one layer up) fails this immediately.
			{
				saved := g_theme[.Bg_Base]
				sentinel := [4]f32{0.42, 0.11, 0.77, 1}
				g_theme[.Bg_Base] = sentinel
				tracks_live := doc_canvas_clear() == sentinel
				g_theme[.Bg_Base] = saved
				fmt.printfln("  %-6s doc_canvas_clear tracks g_theme[.Bg_Base] live", "ok" if tracks_live else "FAIL")
				if !tracks_live {fail = true}
			}

			fmt.println("themetest: FAILURES" if fail else "themetest: all ok")
			return true
		}

		// `newtpad movelinetest` — Alt+Up/Down. Terminators live BETWEEN lines and the
		// last line often has none, so a naive cut-and-paste either duplicates one or
		// drops it; on a CRLF file that leaves a bare LF, the corruption batch 1 fixed
		// in doc_delete_fwd. Hence whole-buffer assertions, and the last line as an
		// explicit case rather than one the general path is assumed to cover.
		if os.args[1] == "movelinetest" {
			fail := false
			chk :: proc(label, got, want: string, fail: ^bool) {
				ok := got == want
				if !ok {fail^ = true}
				fmt.printfln("  %-6s %-34s got=%q want=%q", "ok" if ok else "FAIL", label, got, want)
			}
			one :: proc(content: string, eol: base.Line_Ending, at, delta: int) -> string {
				doc: Document
				doc.pt = base.pt_init(transmute([]u8)content)
				defer doc_close(&doc) // undo/redo hold cloned trees too; pt_destroy alone leaked them
				doc.eol = eol
				doc.cursor, doc.anchor = at, at
				doc_move_lines(&doc, delta)
				return strings.clone(doc_debug_string(&doc), context.temp_allocator)
			}
			// Every case above collapses cursor and anchor to the same point, so a
			// multi-line SELECTION -- a_bytes covering more than one line, the
			// anchor/cursor restore's shift arithmetic -- was never exercised by any
			// of them. That is exactly the path the unbounded-read finding lived in,
			// and not a coincidence: an untested path is where an unchecked read
			// range survives. Returns the resulting anchor/cursor too, not just the
			// buffer, since a move that gets the bytes right but drops the
			// selection in the wrong place still breaks "hold the key to repeat".
			one_sel :: proc(content: string, eol: base.Line_Ending, anchor, cursor, delta: int) -> (buf: string, out_anchor, out_cursor: int) {
				doc: Document
				doc.pt = base.pt_init(transmute([]u8)content)
				defer doc_close(&doc)
				doc.eol = eol
				doc.anchor, doc.cursor = anchor, cursor
				doc_move_lines(&doc, delta)
				return strings.clone(doc_debug_string(&doc), context.temp_allocator), doc.anchor, doc.cursor
			}
			fmt.println("movelinetest:")
			// LF, middle of the file
			chk("LF: move line 2 up", one("a\nb\nc\n", .LF, 2, -1), "b\na\nc\n", &fail)
			chk("LF: move line 1 down", one("a\nb\nc\n", .LF, 0, 1), "b\na\nc\n", &fail)
			// no-ops at the bounds: the buffer must come back byte-identical
			chk("LF: first line up is a no-op", one("a\nb\n", .LF, 0, -1), "a\nb\n", &fail)
			chk("LF: last line down is a no-op", one("a\nb\n", .LF, 2, 1), "a\nb\n", &fail)
			// the bail arithmetic could plausibly strip the trailing newline instead of
			// preserving it -- pin the case where a properly-terminated true last line
			// receives a new neighbour rather than being swapped with a phantom row.
			chk("LF: down into true last line", one("a\nb\nc\n", .LF, 2, 1), "a\nc\nb\n", &fail)
			// the last line WITHOUT a trailing newline -- which line lacks one changes
			chk("LF: unterminated last up", one("a\nb", .LF, 2, -1), "b\na", &fail)
			chk("LF: into unterminated last", one("a\nb", .LF, 0, 1), "b\na", &fail)
			// CRLF must never yield a bare LF anywhere
			chk("CRLF: move line 2 up", one("a\r\nb\r\nc\r\n", .CRLF, 3, -1), "b\r\na\r\nc\r\n", &fail)
			chk("CRLF: unterminated last up", one("a\r\nb", .CRLF, 3, -1), "b\r\na", &fail)
			chk("CRLF: into unterminated last", one("a\r\nb", .CRLF, 0, 1), "b\r\na", &fail)
			// .Mixed must never rewrite a line ending the move didn't touch. The old
			// "each line carries its own terminator" model synthesised doc.eol's bytes
			// whenever the piece landing first was the unterminated last line -- here
			// that piece's real neighbour separator is a CRLF the move never touched.
			// Both directions of the same swap, since both synthesised under the old model.
			chk("Mixed: unterminated last up preserves CRLF", one("a\nb\r\nc", .Mixed, 5, -1), "a\nc\r\nb", &fail)
			chk("Mixed: into unterminated last preserves CRLF", one("a\nb\r\nc", .Mixed, 2, 1), "a\nc\r\nb", &fail)
			// Multi-line selection covering "bb" and "ccc" (bytes 2..7 of
			// "a\nbb\nccc\nd\n"): a_bytes = pt[2:8) = "bb\nccc", with "a" above and
			// "d" below. Moving down swaps the pair past "d"; moving up swaps it
			// past "a". Both directions of the same selection, mirroring the
			// single-line up/down pairs above.
			sel_fixture := "a\nbb\nccc\nd\n"
			{
				buf, a, c := one_sel(sel_fixture, .LF, 2, 7, 1)
				chk("multi-line sel: down past neighbour", buf, "a\nd\nbb\nccc\n", &fail)
				ok := a == 4 && c == 9
				if !ok {fail = true}
				fmt.printfln("  %-6s multi-line sel down: anchor=%d cursor=%d (want 4, 9)", "ok" if ok else "FAIL", a, c)
			}
			{
				buf, a, c := one_sel(sel_fixture, .LF, 2, 7, -1)
				chk("multi-line sel: up past neighbour", buf, "bb\nccc\na\nd\n", &fail)
				ok := a == 0 && c == 5
				if !ok {fail = true}
				fmt.printfln("  %-6s multi-line sel up: anchor=%d cursor=%d (want 0, 5)", "ok" if ok else "FAIL", a, c)
			}
			// A line longer than MOVE_LINE_BUDGET must be refused, not scanned: the fix
			// for the unbounded-scan finding is a bail, and a bail that silently didn't
			// fire would corrupt the buffer instead of leaving it alone -- so assert the
			// whole buffer is untouched, not just that the call returned.
			big := strings.repeat("x", MOVE_LINE_BUDGET + 16, context.temp_allocator)
			over_budget := strings.concatenate({big, "\nb"}, context.temp_allocator)
			// Compared in full but reported by length and a match flag: chk prints both
			// operands with %q, and these are a megabyte each, which buried the rest of
			// the mode's output under four megabytes of x's.
			{
				got := one(over_budget, .LF, len(big) + 1, -1)
				ok := got == over_budget
				if !ok {fail = true}
				fmt.printfln(
					"  %-6s %-34s %d bytes, unchanged=%v",
					"ok" if ok else "FAIL",
					"over-budget line is a no-op",
					len(over_budget),
					ok,
				)
			}
			// The line-length bail above doesn't cover this: every line here is two
			// bytes, so lo_exact/last_exact/line_span_cap all succeed quickly and
			// only the SELECTION's total span (region_hi - region_lo) crosses
			// MOVE_LINE_BUDGET -- the exact shape of the Critical 1 finding (click
			// line 2, Ctrl+Shift+End, Alt+Up on a huge file: every individual scan
			// is short, only the read_range about to run is not). Verified this
			// fails without the region_hi-region_lo bail in doc_move_lines: with it
			// removed, the buffer comes back changed instead of byte-identical.
			{
				line := "x\n"
				body := strings.repeat(line, MOVE_LINE_BUDGET / 2 + 50, context.temp_allocator)
				multi_over := strings.concatenate({"z\n", body}, context.temp_allocator)
				got, _, _ := one_sel(multi_over, .LF, 2, len(multi_over) - 1, -1)
				ok := got == multi_over
				if !ok {fail = true}
				fmt.printfln(
					"  %-6s %-34s %d bytes, unchanged=%v",
					"ok" if ok else "FAIL",
					"over-budget SELECTION is a no-op",
					len(multi_over),
					ok,
				)
			}
			// One press must add exactly one undo entry (Replace All's overflow bug
			// was one snapshot per match; a batch is the fix, so pin that it still
			// collapses to one here too), and doc_undo must restore the exact
			// original bytes -- not just "no error", the pre-move buffer verbatim.
			{
				ud: Document
				ud.pt = base.pt_init(transmute([]u8)string("a\r\nb\r\nc\r\n"))
				defer doc_close(&ud)
				ud.eol = .CRLF
				ud.cursor, ud.anchor = 3, 3
				before := len(ud.undo)
				doc_move_lines(&ud, -1)
				added := len(ud.undo) - before
				if added != 1 {
					fail = true
					fmt.printfln("  FAIL   undo entries added: %d (want 1)", added)
				} else {
					fmt.printfln("  ok     undo entries added: %d (want 1)", added)
				}
				doc_undo(&ud)
				restored := doc_debug_string(&ud)
				chk("undo restores original bytes", restored, "a\r\nb\r\nc\r\n", &fail)
			}
			fmt.println("movelinetest: FAILURES" if fail else "movelinetest: all ok")
			return true
		}

		// `newtpad mdtabletest` checks the two properties the old renderer lacked:
		// every row's cells land on the same x positions, and those positions do not
		// depend on where the viewport entered the block.
		if os.args[1] == "mdtabletest" {
			t: plat.Text
			if !plat.text_load_faces(&t) {
				fmt.eprintln("mdtabletest: no fonts loaded")
				return true
			}
			fail := false
			sb: strings.Builder
			strings.builder_init(&sb, context.temp_allocator)
			strings.write_string(&sb, "| id | name | notes |\n|:---|:----:|------:|\n")
			for i in 0 ..< 200 {
				fmt.sbprintf(&sb, "| %d | row %d | a much longer note cell %d |\n", i, i, i)
			}
			content := strings.to_string(sb)
			doc: Document
			doc.pt = base.pt_init(transmute([]u8)content)
			defer base.pt_destroy(&doc.pt)
			doc.md_mode = .Preview
			fmt.println("mdtabletest:")
			// Longest single row in the fixture. #assert(MD_TABLE_BUDGET >
			// RENDER_LINE_CAP) only guards the PRODUCTION constant; every block below
			// that temporarily lowers the runtime md_table_budget asserts against this
			// instead, since that's the precondition the forward guard's comment
			// actually needs (see md_table_bounds) and the constant-level #assert says
			// nothing about a value the test itself chose.
			max_row_len := 0
			for line in strings.split(content, "\n", context.temp_allocator) {
				if len(line) > max_row_len {max_row_len = len(line)}
			}

			// Enter the block from three different offsets; the measure must agree.
			offs := [3]int{0, 0, 0}
			offs[1] = base.pt_line_start(&doc.pt, doc.pt.length / 2)
			offs[2] = base.pt_line_start(&doc.pt, doc.pt.length - 40)
			first: Md_Table_Cache
			for off, k in offs {
				// Force a cold measurement at each offset -- otherwise the first entry
				// (offset 0, which is trivially its own true block start) would cache the
				// whole block, and later offsets would just hit that cache without ever
				// re-deriving the bounds, silently passing even with a broken backward
				// scan. Entering "from a different offset" has to mean a fresh measure.
				doc.md_table = {}
				c := md_table_ensure(&doc, &t, off)
				if c == nil {
					fail = true
					fmt.printfln("  FAIL  no table measured at offset %d", off)
					continue
				}
				if k == 0 {
					first = c^
					fmt.printfln("  ok    measured %d cols, block [%d,%d)", c.ncols, c.start, c.end)
					// Cache-hit check: same offset, cache NOT cleared this time, so a
					// second lookup must return the SAME slot rather than scanning again
					// into a fresh round-robin slot. Pointer identity is the only
					// observable a stale-but-correct rescan can't accidentally satisfy --
					// the values would match either way, but the address would not.
					hitc := md_table_ensure(&doc, &t, off)
					hitok := hitc == c
					if !hitok {fail = true}
					fmt.printfln("  %-6s repeat lookup at same offset hits the cache", "ok" if hitok else "FAIL")
					continue
				}
				same := c.ncols == first.ncols && c.start == first.start && c.end == first.end
				if same {
					for i in 0 ..< c.ncols {
						if c.widths[i] != first.widths[i] || c.align[i] != first.align[i] {same = false}
					}
				}
				if !same {fail = true}
				fmt.printfln("  %-6s entering at %d matches the measure from 0", "ok" if same else "FAIL", off)
			}
			// Alignment comes from the separator row: left, centre, right.
			if first.ncols == 3 {
				a := first.align[0] == .Left && first.align[1] == .Center && first.align[2] == .Right
				if !a {fail = true}
				fmt.printfln("  %-6s separator alignments parsed", "ok" if a else "FAIL")
			}
			// The measure's primary output: the derived column widths, not just that
			// three entry offsets agree with each other (which passes even with an
			// all-zero widths array -- deleting the width-measuring loop kept the
			// cross-offset check green until this assertion was added).
			//   col 0: "id"=2 vs "0".."199"                  -> 3
			//   col 1: "name"=4 vs "row 0".."row 199"         -> 7
			//   col 2: "notes"=5 vs "a much longer note cell 199" (27 chars) -> 27
			// The separator row is excluded from width measurement, so its dashes must
			// not appear in these numbers.
			want_widths := [3]int{3, 7, 27}
			wok := first.ncols == 3
			if wok {
				for i in 0 ..< 3 {
					if first.widths[i] != want_widths[i] {wok = false}
				}
			}
			if !wok {fail = true}
			fmt.printfln("  %-6s derived widths %v (want %v)", "ok" if wok else "FAIL", first.widths[:first.ncols], want_widths)

			// The oversized fallback: fixed columns, which depend on nothing outside
			// the row being drawn, so they are shift-free too. This calls
			// md_table_measure directly with oversize=true, which bypasses
			// md_table_bounds entirely -- exactly why the inverted budget guards were
			// invisible to this suite. The block below drives the real path.
			//
			// ncols is MD_TABLE_MAX_COLS, not the block's actual 3 -- the oversized
			// path does NO SCAN AT ALL (that's the fix: Critical 2 made the fallback
			// O(1) by never reading the block to count columns), and the draw clips
			// at x1, so a generous column count costs nothing.
			ov := md_table_measure(&doc, &t, 0, doc.pt.length, true)
			ovok := ov.ncols == MD_TABLE_MAX_COLS
			for i in 0 ..< ov.ncols {
				if ov.widths[i] != MD_TABLE_FIXED_CELLS {ovok = false}
			}
			if !ovok {fail = true}
			fmt.printfln("  %-6s oversized block uses fixed columns (%d)", "ok" if ovok else "FAIL", ov.widths[0])

			// Drive md_table_bounds itself into the oversize path, entering mid-block
			// so both the backward and forward scans run. A real >1MB fixture would
			// prove the same thing but costs tens of thousands of rows to build and
			// print; md_table_budget is a runtime variable for exactly this reason --
			// lowering it exercises the identical guard code on a fixture two orders
			// of magnitude smaller.
			{
				saved := md_table_budget
				md_table_budget = 200 // well under this ~8KB fixture, well over one row
				assert(md_table_budget > max_row_len, "md_table_budget must clear the fixture's longest row or the forward guard's own-length precondition doesn't hold")
				doc.md_table = {}
				mid := base.pt_line_start(&doc.pt, doc.pt.length / 2)
				entry_end := base.pt_line_end_cap(&doc.pt, mid, RENDER_LINE_CAP)
				c := md_table_ensure(&doc, &t, mid)
				md_table_budget = saved
				if c == nil {
					fail = true
					fmt.println("  FAIL  no table measured entering mid-block for the oversize drive")
				} else {
					// Critical 1: the backward scan must actually stop short of byte 0.
					// The dead `start - q` guard let it walk all the way back (this file
					// is one contiguous table, so the true start IS 0), so start > 0 here
					// is the fixed backward guard actually firing.
					back_ok := c.start > 0
					// Critical 2: the forward scan must extend past the entry row's own
					// end. The `r - start` guard tripped on its first check once the
					// backward walk had moved `start`, leaving end pinned at entry_end.
					fwd_ok := c.end > entry_end
					window_ok := c.end - c.start < len(content) / 2
					ok := c.oversize && back_ok && fwd_ok && window_ok
					if !ok {fail = true}
					fmt.printfln(
						"  %-6s bounds() trips oversize with a bounded window: oversize=%v start=%d(>0) end=%d(>%d) window=%d",
						"ok" if ok else "FAIL",
						c.oversize,
						c.start,
						c.end,
						entry_end,
						c.end - c.start,
					)
				}
			}

			// Task 7 / Important 1 regression: `oversize` (and the widths that ride on
			// it, since the oversize branch fixes every column at MD_TABLE_FIXED_CELLS)
			// must not depend on which offset entered the block. Lower the budget so
			// this ~9.3 KB fixture lands in (K, 2K] -- too big to ever be "small enough"
			// but too small to always trip both directions regardless of entry. That
			// band is exactly where the old per-guard `oversize` flipped with the entry
			// point: near-top entries tripped only the backward guard, near-bottom only
			// the forward one, mid-block entries could trip neither.
			{
				saved := md_table_budget
				md_table_budget = 6000 // K; fixture is ~9.3 KB, so K < B <= 2K
				assert(md_table_budget > max_row_len, "md_table_budget must clear the fixture's longest row or the forward guard's own-length precondition doesn't hold")
				doc.md_table = {}
				c0 := md_table_ensure(&doc, &t, offs[0])
				// c0 points INTO doc.md_table -- copy it out (nil-checked) before the
				// next reset zeroes the slot it points to, or c0v below would read
				// back the zeroed slot instead of offset 0's actual measurement.
				c0_nil := c0 == nil
				c0v: Md_Table_Cache
				if !c0_nil {c0v = c0^}
				doc.md_table = {}
				c1 := md_table_ensure(&doc, &t, offs[1])
				md_table_budget = saved
				// Every other block in this mode nil-checks its md_table_ensure result
				// before dereferencing; this one didn't. Can't fire on this fixture (both
				// offsets are always table rows), but a future fixture edit would turn a
				// FAIL into a crash instead of a FAIL, so check like every neighbour does.
				if c0_nil || c1 == nil {
					fail = true
					fmt.println("  FAIL  entry-independent oversize: no table measured")
				} else {
					c1v := c1^
					// K < B <= 2K (asserted above) must yield oversize=true by the
					// three-case algebra in the batch-1 report -- so require it explicitly,
					// not just that the two entries AGREE. Without `&& c0v.oversize`, an
					// implementation that never sets oversize at all (a "never oversize"
					// bug) would pass this check vacuously: both sides false, `==` true,
					// ncols/widths equal because both took the non-oversize measure path.
					same := c0v.oversize == c1v.oversize && c0v.oversize && c0v.ncols == c1v.ncols
					if same {
						for i in 0 ..< c0v.ncols {
							if c0v.widths[i] != c1v.widths[i] {same = false}
						}
					}
					if !same {fail = true}
					fmt.printfln(
						"  %-6s entry-independent oversize: off=0 oversize=%v ncols=%d widths=%v | off=%d oversize=%v ncols=%d widths=%v",
						"ok" if same else "FAIL",
						c0v.oversize,
						c0v.ncols,
						c0v.widths[:c0v.ncols],
						offs[1],
						c1v.oversize,
						c1v.ncols,
						c1v.widths[:c1v.ncols],
					)
				}
			}

			// Task 7 / Important 2 regression: the byte budget alone does not bound the
			// SCAN work on short rows. Lower the row cap far below this fixture's 200
			// data rows (the byte budget stays at its 1 MB default, well clear of the
			// ~9.3 KB fixture) and enter at the very first row, so the backward
			// direction is free (0 rows to walk) and the forward direction is the one
			// that must give up after md_table_max_rows rows rather than reading all of
			// them.
			{
				saved := md_table_max_rows
				md_table_max_rows = 50
				doc.md_table = {}
				c := md_table_ensure(&doc, &t, offs[0])
				md_table_max_rows = saved
				ok := c != nil && c.oversize && (c.end - c.start) < len(content) / 2
				if !ok {fail = true}
				if c != nil {
					fmt.printfln(
						"  %-6s row cap trips: oversize=%v window=%d bytes (fixture=%d, cap=50 rows)",
						"ok" if ok else "FAIL",
						c.oversize,
						c.end - c.start,
						len(content),
					)
				} else {
					fail = true
					fmt.println("  FAIL  row cap trip: no table measured")
				}
			}

			// The row cap has the identical entry-dependence trap as Important 1, one
			// level down: capping each direction's row COUNT independently reproduces
			// the same flip unless the total is also checked once both scans complete
			// without tripping (see the `total_rows` comment in md_table_bounds). This
			// fixture has 202 physical block rows (header + separator + 200 data
			// rows); with the row cap between R/2 and R, entering at the very first row
			// trips the forward direction's own count on its own, but entering
			// mid-block lets BOTH directions finish under the cap individually --
			// exactly the case the `total_rows` check exists for.
			{
				saved := md_table_max_rows
				md_table_max_rows = 120
				doc.md_table = {}
				edge := md_table_ensure(&doc, &t, offs[0])
				edge_ov := edge != nil && edge.oversize
				doc.md_table = {}
				mid := md_table_ensure(&doc, &t, offs[1])
				mid_ov := mid != nil && mid.oversize
				md_table_max_rows = saved
				ok := edge_ov && mid_ov
				if !ok {fail = true}
				fmt.printfln(
					"  %-6s row-count entry-independence: off=0 oversize=%v | off=%d oversize=%v (cap=120 rows, block=202 rows)",
					"ok" if ok else "FAIL",
					edge_ov,
					offs[1],
					mid_ov,
				)
			}

			// Review follow-up: md_table_bounds assumed `p` is a line start, but
			// markdown_draw's own capped-segment walk (`p = end + 1`, where `end` came
			// from pt_line_end_cap) hands it a mid-line offset for any physical line
			// longer than RENDER_LINE_CAP -- the second and later drawn segments of
			// such a line, and doc.top itself if the viewport happens to be scrolled
			// there. Fixture: one physical line just over one RENDER_LINE_CAP (8192)
			// long -- 8192 bytes of filler containing NO pipe, then a short
			// pipe-delimited tail. The filler-only first segment does not look like a
			// table row on its own, so p=0 is never a table entry here at all; the
			// ONLY offset that ever reaches md_table_bounds for this fixture is the
			// tail's own segment offset (RENDER_LINE_CAP+1 = 8193), exactly what
			// markdown_draw produces after drawing the filler segment above it -- and
			// it is not a real line start.
			//
			// A literal "entered at byte 0, compare to entered mid-line" check isn't
			// constructible for THIS bug: a pipe-free first segment is required so the
			// OLD backward loop's `if !md_is_table_row(pl) {break}` skips its own
			// `pl_capped` check before it can fire (that's precisely what let this hide
			// -- see the task-7 report's hand-derivation), but that same pipe-free
			// segment also means p=0 never passes md_is_table_row and so is never a
			// comparable md_table_bounds entry in the first place. So this checks the
			// mid-line entry against the one thing every other entry into a
			// >RENDER_LINE_CAP row in this suite already agrees on: the fixed oversize
			// signature (ncols=MD_TABLE_MAX_COLS, every width=MD_TABLE_FIXED_CELLS).
			{
				filler, _ := strings.repeat("x", RENDER_LINE_CAP, context.temp_allocator)
				sb2: strings.Builder
				strings.builder_init(&sb2, context.temp_allocator)
				strings.write_string(&sb2, filler)
				strings.write_string(&sb2, "| a | b | c |")
				strings.write_byte(&sb2, '\n')
				ml_content := strings.to_string(sb2)
				ml_doc: Document
				ml_doc.pt = base.pt_init(transmute([]u8)ml_content)
				defer base.pt_destroy(&ml_doc.pt)
				ml_doc.md_mode = .Preview

				mid_p := RENDER_LINE_CAP + 1 // 8193 -- exactly markdown_draw's p = end + 1
				c := md_table_ensure(&ml_doc, &t, mid_p)
				mok := c != nil && c.oversize && c.ncols == MD_TABLE_MAX_COLS
				if mok {
					for i in 0 ..< c.ncols {
						if c.widths[i] != MD_TABLE_FIXED_CELLS {mok = false}
					}
				}
				if !mok {fail = true}
				if c != nil {
					fmt.printfln(
						"  %-6s mid-line entry (p=%d) into a >RENDER_LINE_CAP row forces oversize: oversize=%v start=%d",
						"ok" if mok else "FAIL",
						mid_p,
						c.oversize,
						c.start,
					)
				} else {
					fmt.println("  FAIL  mid-line entry: no table measured")
				}
			}

			// Empty leading cells survive the split: "||b|" strips one leading and one
			// trailing pipe to "|b", which splits to ["", "b"] -- the old
			// strings.trim(line, "| ") would have trimmed the whole prefix and lost the
			// empty cell, collapsing this to just ["b"].
			cells := md_split_cells("||b|", context.temp_allocator)
			eok := len(cells) == 2 && cells[0] == "" && cells[1] == "b"
			if !eok {fail = true}
			fmt.printfln("  %-6s empty leading cells kept (%d cells)", "ok" if eok else "FAIL", len(cells))
			fmt.println("mdtabletest: FAILURES" if fail else "mdtabletest: all ok")
			return true
		}

		// `newtpad viewmemtest` proves the per-family view memory (Wyatt's complaint:
		// switching a .md to Split, then opening another .md, used to come up plain
		// again). Checks, in order:
		//   - a fresh open of a markdown/tabular file adopts the remembered family
		//     default, through the same doc_can_* gating a manual toggle uses;
		//   - a .txt is unaffected by md_default -- the gating holds, so a stray
		//     default can never wedge a file into a view it cannot hold;
		//   - toggling a view learns the new default only when remember_views is on;
		//   - toggling a view on an untitled buffer never learns a default -- the
		//     empty-path short-circuit that lets an untitled buffer enter any view
		//     also makes doc_is_tabular/doc_is_markdownish true for it, so the learn
		//     gate needs its own doc.path != "" check, not just the family check;
		//   - a session-restored tab is untouched by the family default -- this is
		//     the assertion that protects the rule most likely to be broken: session
		//     restore must win over a family default, always;
		//   - an out-of-range md_default on disk degrades to .Off, not an invalid enum.
		// Set NEWTPAD_SESSION_DIR to a temp dir first -- this reads/writes
		// settings.txt and drives session_save/session_restore.
		if os.args[1] == "viewmemtest" {
			if !require_scratch_session("viewmemtest") {return true}
			t: plat.Text
			if !plat.text_load_faces(&t) {
				fmt.eprintln("viewmemtest: no fonts loaded")
				return true
			}
			bad := 0
			tmp := os.get_env("TEMP", context.temp_allocator)
			mdf := fmt.tprintf("%s%cnewtpad_viewmem.md", tmp, '\\')
			csvf := fmt.tprintf("%s%cnewtpad_viewmem.csv", tmp, '\\')
			txtf := fmt.tprintf("%s%cnewtpad_viewmem.txt", tmp, '\\')
			plat.file_write_atomic(mdf, transmute([]u8)string("# heading\n\nbody text\n"))
			plat.file_write_atomic(csvf, transmute([]u8)string("a,b,c\n1,2,3\n"))
			plat.file_write_atomic(txtf, transmute([]u8)string("just plain text\n"))
			// real files on disk in %TEMP% -- must not be left behind (see droptest)
			defer os.remove(mdf)
			defer os.remove(csvf)
			defer os.remove(txtf)

			fmt.println("--- fresh open adopts the family default ---")
			{
				a: App
				a.settings = settings_default()
				a.settings.md_default = .Split
				a.settings.table_default = true
				app_open_path(&a, mdf)
				md := app_active(&a)
				mdok := md != nil && md.md_mode == .Split
				fmt.printfln("  .md  opens in %-8v %s", md.md_mode, "OK" if mdok else "FAIL")
				if !mdok {bad += 1}

				app_open_path(&a, csvf)
				cv := app_active(&a)
				// table_delim too, not just the flag: app_apply_view_defaults used to
				// set doc.table directly and leave the delimiter at 0, which
				// table_compute_widths silently falls back to ',' for -- so a .tsv
				// opened by the family default drew one enormous column. Routing
				// through doc_view_apply is what chooses it, and this is the
				// assertion that cannot pass with the second code path back.
				cvok := cv != nil && cv.table && cv.table_delim == ','
				fmt.printfln("  .csv opens with table=%-5v delim=%q %s", cv.table, rune(cv.table_delim), "OK" if cvok else "FAIL")
				if !cvok {bad += 1}

				// The gating holds: a .txt cannot enter markdown mode (doc_can_markdown
				// is false for it), so md_default cannot force it into Split anyway.
				app_open_path(&a, txtf)
				tx := app_active(&a)
				txok := tx != nil && tx.md_mode == .Off
				fmt.printfln("  .txt stays %-8v despite md_default=Split %s", tx.md_mode, "OK" if txok else "FAIL")
				if !txok {bad += 1}
				app_destroy(&a)
			}

			fmt.println("--- toggling a view learns the default, gated on remember_views ---")
			{
				a: App
				dummy: plat.Window
				a.settings = settings_default() // md_default .Off, so the fresh open below is Off
				a.settings.remember_views = true
				app_open_path(&a, mdf)
				command_dispatch(.Toggle_Preview, {}, &a, &dummy, &t, 10) // Off -> Preview
				learned := a.settings.md_default == .Preview
				fmt.printfln("  remember on:  toggle -> md_default=%-8v %s", a.settings.md_default, "OK" if learned else "FAIL")
				if !learned {bad += 1}
				onDisk := settings_load() // learn-on-toggle must have written settings.txt, not just memory
				savedOK := onDisk.md_default == .Preview
				fmt.printfln("  ...settings.txt agrees: md_default=%-8v %s", onDisk.md_default, "OK" if savedOK else "FAIL")
				if !savedOK {bad += 1}
				app_destroy(&a)
			}
			{
				a: App
				dummy: plat.Window
				a.settings = settings_default()
				a.settings.remember_views = false
				app_open_path(&a, csvf)
				command_dispatch(.Toggle_Table, {}, &a, &dummy, &t, 10) // Off -> On
				notLearned := a.settings.table_default == false
				fmt.printfln("  remember off: toggle -> table_default=%-5v (unchanged) %s", a.settings.table_default, "OK" if notLearned else "FAIL")
				if !notLearned {bad += 1}
				app_destroy(&a)
			}

			fmt.println("--- toggling a view on an untitled buffer must not teach a family default ---")
			{
				// doc_can_markdown/doc_can_table are true for an untitled buffer (the
				// empty-path short-circuit in path_has_ext: "don't limit an untitled
				// buffer"), so the toggle itself succeeds here same as on a real
				// markdown/csv file. The learn gate must additionally require a path,
				// or a stray Ctrl+M on a blank scratch tab teaches the family default.
				a: App
				dummy: plat.Window
				a.settings = settings_default()
				a.settings.remember_views = true
				app_new_scratch(&a) // untitled: doc.path == ""
				command_dispatch(.Toggle_Preview, {}, &a, &dummy, &t, 10) // Off -> Preview
				mdUntouched := a.settings.md_default == .Off
				fmt.printfln("  Ctrl+M on untitled: md_default=%-8v (should stay Off) %s", a.settings.md_default, "OK" if mdUntouched else "FAIL")
				if !mdUntouched {bad += 1}
				app_destroy(&a)
			}
			{
				a: App
				dummy: plat.Window
				a.settings = settings_default()
				a.settings.remember_views = true
				app_new_scratch(&a) // untitled: doc.path == ""
				command_dispatch(.Toggle_Table, {}, &a, &dummy, &t, 10) // Off -> On
				tableUntouched := a.settings.table_default == false
				fmt.printfln("  Ctrl+T on untitled: table_default=%-5v (should stay false) %s", a.settings.table_default, "OK" if tableUntouched else "FAIL")
				if !tableUntouched {bad += 1}
				app_destroy(&a)
			}

			// The live half of doc_view_apply's mutual-exclusion rule. Both
			// doc_can_* gates short-circuit true on an untitled buffer, so Ctrl+T
			// then Ctrl+M was reachable with two keystrokes on a fresh tab and
			// produced table && md_mode == .Split -- the state view.odin calls
			// undefined. Session format 4 persists both fields, so a restart
			// resolved it through doc_view_apply while the live document stayed in
			// it. Each toggle must turn the other off itself. Both directions,
			// because they are two separate pieces of code.
			fmt.println("--- the two views are mutually exclusive live, not only on restore ---")
			{
				a: App
				dummy: plat.Window
				a.settings = settings_default()
				app_new_scratch(&a)
				command_dispatch(.Toggle_Table, {}, &a, &dummy, &t, 10)
				command_dispatch(.Toggle_Preview, {}, &a, &dummy, &t, 10)
				d := app_active(&a)
				ok1 := d != nil && !d.table && d.md_mode != .Off
				fmt.printfln("  Ctrl+T then Ctrl+M: table=%-5v md_mode=%-8v (want false/not-Off) %s", d.table, d.md_mode, "OK" if ok1 else "FAIL")
				if !ok1 {bad += 1}
				app_destroy(&a)
			}
			{
				a: App
				dummy: plat.Window
				a.settings = settings_default()
				app_new_scratch(&a)
				command_dispatch(.Toggle_Preview, {}, &a, &dummy, &t, 10)
				command_dispatch(.Toggle_Table, {}, &a, &dummy, &t, 10)
				d := app_active(&a)
				ok2 := d != nil && d.table && d.md_mode == .Off
				fmt.printfln("  Ctrl+M then Ctrl+T: table=%-5v md_mode=%-8v (want true/Off) %s", d.table, d.md_mode, "OK" if ok2 else "FAIL")
				if !ok2 {bad += 1}
				app_destroy(&a)
			}

			fmt.println("--- session restore wins over the family default ---")
			{
				// A tab left in Preview, saved and restored, must not come back forced
				// onto a family default that says something else: app_apply_view_defaults
				// is never reached from the restore path, so it cannot overwrite a
				// per-tab view.
				//
				// This assertion expected .Off until batch 6, and said so at length,
				// because session.txt carried only `wrap` -- so it proved the property
				// against a value that was constant either way. Session format 4
				// persists md_mode, which is exactly the "a persisted value a future
				// session format might carry" case the old comment anticipated: the tab
				// now round-trips as .Preview while the family default says .Split, so
				// the restore genuinely WINS over the default instead of coinciding
				// with it. The test only started failing when format 4 landed, which is
				// the assertion doing its job -- it was stale, not wrong.
				a: App
				app_open_path(&a, mdf)
				d := app_active(&a)
				d.md_mode = .Preview // the view the user deliberately left this tab in
				session_save(&a)
				app_destroy(&a)

				b: App
				b.settings = settings_default()
				b.settings.md_default = .Split // family default now disagrees
				restored := session_restore(&b)
				rd := app_active(&b)
				ok := restored && rd != nil && rd.md_mode == .Preview
				fmt.printfln("  restored tab md_mode=%-8v (md_default=Split, untouched; want Preview) %s", rd.md_mode if rd != nil else Md_Mode.Off, "OK" if ok else "FAIL")
				if !ok {bad += 1}
				app_destroy(&b)
				// reset the session so the GUI doesn't inherit this test's tabs
				empty: App
				app_new_scratch(&empty)
				session_save(&empty)
				app_destroy(&empty)
			}

			fmt.println("--- out-of-range md_default degrades, not corrupts ---")
			{
				raw := "newtpad-settings 1\nrestore_session 1\nwrap_default 0\nfont_size 16\nzoom_pct 100\nfont_family Consolas\nfont_style 0\nlink_style 0\nsplit_frac 0.50\nmd_default 99\ntable_default 0\nremember_views 1\n"
				if p, pok := session_dir(); pok {
					plat.file_write_atomic(fmt.tprintf("%s%csettings.txt", p, '\\'), transmute([]u8)raw)
				}
				s := settings_load()
				degraded := s.md_default == .Off
				fmt.printfln("  md_default 99 -> %-8v %s", s.md_default, "OK" if degraded else "FAIL")
				if !degraded {bad += 1}
			}

			// --- doc_view_apply validates against the document it lands on ---
			// These are the cases a stored view can actually be wrong in: the
			// extension gates never change under reload or restore, so the guard
			// only fires for a view that came from somewhere else -- a session
			// written by another build, a hand-edited one, a future caller.
			view_apply_cases :: proc() -> (bad: int) {
				// A table view stored against a .txt must not turn the grid on.
				// doc_from_content takes ownership of the slice; an empty one is
				// enough here, since only the path drives the gates.
				td := doc_from_content(make([]u8, 0), "C:\\tmp\\notes.txt", .UTF8)
				defer doc_close(&td)
				doc_view_apply(&td, Doc_View{wrap = true, md_mode = .Split, table = true})
				ok1 := !td.table && td.md_mode == .Off && td.wrap
				fmt.printfln(
					"  %-6s .txt refuses both views, keeps wrap: table=%v md_mode=%v wrap=%v (want false/Off/true)",
					"ok" if ok1 else "FAIL", td.table, td.md_mode, td.wrap,
				)
				if !ok1 {bad += 1}
				return
			}
			bad += view_apply_cases()

			view_apply_accepts :: proc() -> (bad: int) {
				// The same view against files that DO fit is applied, and turning
				// the grid on picks a delimiter -- a table with table_delim == 0
				// draws no columns at all.
				md := doc_from_content(make([]u8, 0), "C:\\tmp\\readme.md", .UTF8)
				defer doc_close(&md)
				doc_view_apply(&md, Doc_View{md_mode = .Split})
				ok2 := md.md_mode == .Split
				fmt.printfln("  %-6s .md accepts Split: md_mode=%v (want Split)", "ok" if ok2 else "FAIL", md.md_mode)
				if !ok2 {bad += 1}
				return
			}
			bad += view_apply_accepts()

			view_apply_table :: proc() -> (bad: int) {
				raw := "a,b,c\n1,2,3\n"
				content := make([]u8, len(raw));copy(content, transmute([]u8)raw)
				cd := doc_from_content(content, "C:\\tmp\\data.csv", .UTF8)
				defer doc_close(&cd)
				doc_view_apply(&cd, Doc_View{table = true})
				ok3 := cd.table && cd.table_delim == ','
				fmt.printfln(
					"  %-6s .csv accepts Table and gets a delimiter: table=%v delim=%q (want true/',')",
					"ok" if ok3 else "FAIL", cd.table, rune(cd.table_delim),
				)
				if !ok3 {bad += 1}
				return
			}
			bad += view_apply_table()

			fmt.printfln("viewmemtest: %d failures", bad)
			return true
		}

		// `newtpad splittest` proves the Markdown Split divider has exactly one x:
		// md_divider_rect and doc_editor_right must agree at any window size and any
		// fraction, not just at the old hardcoded 0.5 -- comparing the two against
		// EACH OTHER catches a second, independently-computed split x that a constant
		// comparison would miss. Also covers the drag clamp and that the fraction
		// actually reaches the things that are supposed to derive from it.
		if os.args[1] == "splittest" {
			if !require_scratch_session("splittest") {return true}
			fail := false
			chk :: proc(label: string, ok: bool, fail: ^bool) {
				if !ok {fail^ = true}
				fmt.printfln("  %-6s %s", "ok" if ok else "FAIL", label)
			}

			doc: Document
			doc.pt = base.pt_init(transmute([]u8)string("hello world\n"))
			defer base.pt_destroy(&doc.pt)
			doc.kind = .Text
			doc.md_mode = .Split

			fmt.println("splittest:")
			fmt.println("--- agreement: md_divider_rect vs doc_editor_right ---")
			// A 1px window and a very wide one are the boundary sizes where an
			// off-by-a-few-pixels bug or an int-truncation mismatch would show up;
			// a normal window is the everyday case. All three fractions, at all
			// three widths.
			widths := []f32{1, 100000, 1280}
			fracs := []f32{0.2, 0.5, 0.73}
			for winw in widths {
				for frac in fracs {
					er := doc_editor_right(&doc, winw, frac)
					dr := md_divider_rect(&doc, winw, 720, frac)
					center := dr.pos.x + dr.size.x * 0.5
					ok := dr.size.x > 0 && abs(center - er) < 0.6 // sub-pixel rounding only
					chk(fmt.tprintf("winw=%.0f frac=%.2f  editor_right=%.1f divider_center=%.1f", winw, frac, er, center), ok, &fail)
				}
			}
			// Not in Split: the brief's "no second condition" contract -- zero size,
			// not just "don't crash".
			doc.md_mode = .Off
			zdr := md_divider_rect(&doc, 1280, 720, 0.5)
			chk(fmt.tprintf("not in Split -> zero-size rect (got %.0fx%.0f)", zdr.size.x, zdr.size.y), zdr.size.x == 0 && zdr.size.y == 0, &fail)
			doc.md_mode = .Split

			fmt.println("--- divider stops above the find/status bar ---")
			// The find/status bar owns the bottom strip (main.odin ~535); before this,
			// md_divider_rect's height ran the full window, so a press in that strip
			// at the divider's x column started a spurious drag. Bound the rect to
			// winh - doc_bottom_bar_h(doc), mirroring pvbot (main.odin ~930), and
			// check it both with find closed (status line, the smaller bar) and open
			// (the taller find bar) -- the bound must track doc_bottom_bar_h, not
			// assume the smaller one.
			bar_winw, bar_winh := f32(1280), f32(720)
			find_states := []bool{false, true}
			for find_active in find_states {
				doc.find.active = find_active
				doc.find.replace_mode = false
				bar_h := doc_bottom_bar_h(&doc)
				bdr := md_divider_rect(&doc, bar_winw, bar_winh, 0.5)
				bottom := bdr.pos.y + bdr.size.y
				want_bottom := bar_winh - bar_h
				ok := abs(bottom - want_bottom) < 0.6
				chk(fmt.tprintf("find.active=%v: rect bottom=%.1f stops at winh-bar_h=%.1f", find_active, bottom, want_bottom), ok, &fail)
				// The point of the bound is the hit-test, not the drawing: a point
				// inside the bar strip at the divider's x column must land outside
				// the rect's y range, or a press there still starts a drag.
				strip_y := bar_winh - bar_h*0.5 // mid-strip, well clear of rounding
				cx := bdr.pos.x + bdr.size.x*0.5
				inside := cx >= bdr.pos.x && cx < bdr.pos.x+bdr.size.x && strip_y >= bdr.pos.y && strip_y < bdr.pos.y+bdr.size.y
				chk(fmt.tprintf("find.active=%v: point in bar strip at divider x is NOT in rect", find_active), !inside, &fail)
			}
			doc.find.active = false

			fmt.println("--- divider grab band vs. scrollbar hit region ---")
			// The point checked is the grab band's LEFT edge, not its drawn-line
			// center: the old scrollbar hit-test was `mouse_x < ed_right` (strictly
			// less), so the center point (== ed_right exactly) was never inside it
			// even with the bug present -- only the left half of the band, where a
			// press aiming at the line but landing a pixel or two short used to
			// land, was ever actually swallowed. Checking the center would pass
			// whether or not the fix is in place, which is the same rect-vs-rect
			// blindness that let this ship: md_divider_rect never changed, only the
			// scrollbar's competing claim did, so this has to test an actual point
			// against both regions, the way a click does, and it has to be a point
			// the bug really mis-served.
			for winw in widths {
				for frac in fracs {
					er := doc_editor_right(&doc, winw, frac)
					dr := md_divider_rect(&doc, winw, 720, frac)
					band_left := dr.pos.x // left edge of the grab band
					in_divider := band_left >= dr.pos.x && band_left < dr.pos.x+dr.size.x
					sb_lo, sb_hi := editor_scrollbar_hit_x(&doc, er)
					in_scrollbar := band_left >= sb_lo && band_left < sb_hi
					chk(
						fmt.tprintf("winw=%.0f frac=%.2f  grab-band left edge x=%.1f in divider rect and outside scrollbar hit region", winw, frac, band_left),
						in_divider && !in_scrollbar,
						&fail,
					)
				}
			}

			fmt.println("--- drag clamp ---")
			// split_frac_at is the exact proc main.odin's drag handler calls -- not
			// a second copy of clamp(mx/winw, SPLIT_MIN, SPLIT_MAX), which would
			// test Odin's clamp builtin rather than this code (report finding 6).
			winw := f32(1000)
			lo := split_frac_at(10, winw) // drag to x=10 (0.01), below SPLIT_MIN
			hi := split_frac_at(990, winw) // drag to x=990 (0.99), above SPLIT_MAX
			chk(fmt.tprintf("drag to 0.01 clamps to SPLIT_MIN (%.2f -> %.3f)", SPLIT_MIN, lo), lo == SPLIT_MIN, &fail)
			chk(fmt.tprintf("drag to 0.99 clamps to SPLIT_MAX (%.2f -> %.3f)", SPLIT_MAX, hi), hi == SPLIT_MAX, &fail)
			// Panes never invert. Deliberately NOT lo/hi above: both clamp to the
			// SPLIT_MIN/SPLIT_MAX constants, so comparing doc_editor_right at those
			// two only proves SPLIT_MIN < SPLIT_MAX -- true regardless of whether
			// the drag math is right. Two distinct, UNclamped fractions instead
			// exercise the real mx/winw division: a swapped or inverted expression
			// would produce equal or backwards results here.
			mid_lo := split_frac_at(200, winw) // 0.2, inside [SPLIT_MIN, SPLIT_MAX]
			mid_hi := split_frac_at(800, winw) // 0.8, inside [SPLIT_MIN, SPLIT_MAX]
			chk(fmt.tprintf("unclamped fractions differ (x=200 -> %.2f, x=800 -> %.2f)", mid_lo, mid_hi), mid_lo < mid_hi, &fail)
			er_lo := doc_editor_right(&doc, winw, mid_lo)
			er_hi := doc_editor_right(&doc, winw, mid_hi)
			chk(fmt.tprintf("panes don't invert (er@0.2=%.0f < er@0.8=%.0f)", er_lo, er_hi), er_lo < er_hi, &fail)

			fmt.println("--- everything downstream of the fraction moves ---")
			// If either of these stopped changing, something upstream reverted to
			// reading a hardcoded half instead of the live fraction.
			er_a := doc_editor_right(&doc, winw, 0.3)
			er_b := doc_editor_right(&doc, winw, 0.7)
			cols_a := doc_view_cols(er_a, 8)
			cols_b := doc_view_cols(er_b, 8)
			chk(fmt.tprintf("wrap columns differ (frac 0.3 -> %d cols, 0.7 -> %d cols)", cols_a, cols_b), cols_a != cols_b, &fail)
			chk(fmt.tprintf("editor scrollbar x differs (frac 0.3 -> %.0f, 0.7 -> %.0f)", er_a, er_b), er_a != er_b, &fail)

			fmt.println("--- settings_load clamps an out-of-range file value ---")
			// Written directly to disk, bypassing settings_save's own clamp -- this is
			// the "hand-edited or corrupt file" case settings_load has to catch on its
			// own, not a re-test of the save-side clamp.
			if p, pok := session_dir(); pok {
				raw := "newtpad-settings 1\nrestore_session 1\nwrap_default 0\nfont_size 16\nzoom_pct 100\nfont_family Consolas\nfont_style 0\nlink_style 0\nsplit_frac 1.50\n"
				plat.file_write_atomic(fmt.tprintf("%s%csettings.txt", p, '\\'), transmute([]u8)raw)
				over := settings_load()
				chk(fmt.tprintf("1.50 on disk loads clamped to %.2f (want %.2f)", over.split_frac, SPLIT_MAX), over.split_frac == SPLIT_MAX, &fail)

				raw2 := "newtpad-settings 1\nrestore_session 1\nwrap_default 0\nfont_size 16\nzoom_pct 100\nfont_family Consolas\nfont_style 0\nlink_style 0\nsplit_frac -3.00\n"
				plat.file_write_atomic(fmt.tprintf("%s%csettings.txt", p, '\\'), transmute([]u8)raw2)
				under := settings_load()
				chk(fmt.tprintf("-3.00 on disk loads clamped to %.2f (want %.2f)", under.split_frac, SPLIT_MIN), under.split_frac == SPLIT_MIN, &fail)
			} else {
				fmt.println("  FAIL  no session dir (set NEWTPAD_SESSION_DIR)")
				fail = true
			}

			fmt.println("splittest: FAILURES" if fail else "splittest: all ok")
			return true
		}

		// `newtpad revtest` drives every mutator and requires Document.revision to
		// advance for each. A path that bypassed it would leave caches (markdown
		// table column widths) stale on screen with no other symptom.
		if os.args[1] == "revtest" {
			fail := false
			doc: Document
			doc.pt = base.pt_init(transmute([]u8)string("alpha beta\ngamma delta\n"))
			defer base.pt_destroy(&doc.pt)
			doc.enc = .UTF8
			last := doc.revision
			step :: proc(doc: ^Document, last: ^u64, label: string, fail: ^bool) {
				ok := doc.revision > last^
				if !ok {fail^ = true}
				fmt.printfln("  %-6s %-22s revision %d -> %d", "ok" if ok else "FAIL", label, last^, doc.revision)
				last^ = doc.revision
			}
			fmt.println("revtest:")
			doc.cursor, doc.anchor = 0, 0
			doc_insert_rune(&doc, 'X');step(&doc, &last, "insert rune", &fail)
			doc_backspace(&doc);step(&doc, &last, "backspace", &fail)
			doc.cursor = 5
			doc_delete_word_back(&doc);step(&doc, &last, "delete word back", &fail)
			doc.anchor, doc.cursor = 0, 3
			doc_replace_sel(&doc, transmute([]u8)string("Q"));step(&doc, &last, "replace selection", &fail)
			doc_set_line_ending(&doc, .CRLF);step(&doc, &last, "set line ending", &fail)
			doc_undo(&doc);step(&doc, &last, "undo", &fail)
			doc_redo(&doc);step(&doc, &last, "redo", &fail)
			// The batch path, which Replace All uses: push_undo returns early while
			// doc.batch is set, so the bump must come before that return. Otherwise a
			// 200-match replace advances revision once and a cache misses 199 edits.
			doc_batch_begin(&doc, .Replace)
			before := doc.revision
			doc.anchor, doc.cursor = 0, 1
			doc_replace_sel(&doc, transmute([]u8)string("z"))
			doc.anchor, doc.cursor = 2, 3
			doc_replace_sel(&doc, transmute([]u8)string("z"))
			doc_batch_end(&doc, 2)
			bok := doc.revision >= before + 2
			if !bok {fail = true}
			fmt.printfln("  %-6s %-22s revision %d -> %d", "ok" if bok else "FAIL", "two edits in a batch", before, doc.revision)
			fmt.println("revtest: FAILURES" if fail else "revtest: all ok")
			return true
		}

		// `newtpad crlftest` checks every consumer of a row agrees where it ends.
		// Comparing against a constant would pass with the bug present, because the
		// text draw already stripped the CR; the point is that the caret, the
		// hit-test, the selection and the wrap budget did not.
		if os.args[1] == "crlftest" {
			t: plat.Text
			if !plat.text_load_faces(&t) {
				fmt.eprintln("crlftest: no fonts loaded")
				return true
			}
			fail := false
			chk :: proc(label: string, got, want: int, fail: ^bool) {
				ok := got == want
				if !ok {fail^ = true}
				fmt.printfln("  %-6s %-34s got=%d want=%d", "ok" if ok else "FAIL", label, got, want)
			}
			chks :: proc(label: string, got, want: string, fail: ^bool) {
				ok := got == want
				if !ok {fail^ = true}
				fmt.printfln("  %-6s %-34s got=%q want=%q", "ok" if ok else "FAIL", label, got, want)
			}
			// Mirrors doc_draw's row-claim predicate exactly (doc.odin, the `caret =
			// true` line in doc_draw) without needing a real GPU device to draw
			// through -- same shape as rowtest's caret_row check just below it. False
			// is what doc_draw returns when no visible row claims the caret, which is
			// how it silently vanishes from the screen.
			caret_claimed :: proc(doc: ^Document, t: ^plat.Text, rows: int) -> bool {
				it := visible_begin(doc, t, rows)
				for {
					_, start, _, vis_end, line_end, _, ok := visible_next(&it)
					if !ok {break}
					if doc.cursor >= start && doc.cursor <= vis_end && (line_end || doc.cursor < vis_end) {
						return true
					}
				}
				return false
			}
			content := "hello\r\nworld\r\n"
			doc: Document
			doc.pt = base.pt_init(transmute([]u8)content)
			defer base.pt_destroy(&doc.pt)
			doc.eol = .CRLF
			doc.view_cols = 40
			px := f32(16) // document text size; render_frame computes this from zoom/DPI
			cw := plat.text_char_width(&t, px, .Doc)
			fmt.println("crlftest:")

			// Row 0 is "hello": vis_end must be the offset of the CR, not of the LF.
			it := visible_begin(&doc, &t, 5)
			_, start, end, vis_end, _, _, _ := visible_next(&it)
			chk("row 0 start", start, 0, &fail)
			chk("row 0 end (structural, at LF)", end, 6, &fail)
			chk("row 0 vis_end (before CR)", vis_end, 5, &fail)

			// End key must land on the content end, not between CR and LF.
			doc.cursor, doc.anchor = 0, 0
			doc_cursor_end(&doc, false)
			chk("End key lands at", doc.cursor, 5, &fail)
			chk("caret drawn after End", 1 if caret_claimed(&doc, &t, 5) else 0, 1, &fail)

			// Each check below resets the cursor explicitly rather than relying on the
			// previous check's result. crlftest is otherwise state-sequential — a
			// failure earlier in the chain would shift the input to everything after
			// it, turning one direct failure into several attributed to the wrong
			// mechanism.
			doc.cursor, doc.anchor = 5, 5
			// Status column at end of line: "hello" is 5 cells, so Col is 6, not 7.
			chk("Col at end of line", doc_cursor_col(&doc, &t), 6, &fail)

			doc.cursor, doc.anchor = 5, 5
			// Right-arrow from the content end crosses the whole CRLF in one step.
			doc_cursor_right(&doc, false)
			chk("Right from EOL skips CRLF", doc.cursor, 7, &fail)
			chk("caret drawn after Right across CRLF", 1 if caret_claimed(&doc, &t, 5) else 0, 1, &fail)

			doc.cursor, doc.anchor = 7, 7
			// Left-arrow back over the break returns to the content end, not the CR.
			doc_cursor_left(&doc, false)
			chk("Left over CRLF returns to", doc.cursor, 5, &fail)
			chk("caret drawn after Left across CRLF", 1 if caret_claimed(&doc, &t, 5) else 0, 1, &fail)

			// A click far to the right of the text clamps to the content end.
			chk("click past EOL clamps to", doc_pos_at(&doc, &t, i32(cw * 30), 0, px, cw, 5), 5, &fail)

			// Double-click past EOL selects the word at the clamped position -- the
			// CR. It must not select the CR itself (invisible, and typing over it
			// would silently turn the line's CRLF into a bare LF); it must leave the
			// caret exactly at the content end, where row 0 can claim it (Important 1).
			doc.cursor, doc.anchor = 0, 0
			doc_select_word_at(&doc, 5)
			chk("dblclick past EOL anchor", doc.anchor, 5, &fail)
			chk("dblclick past EOL cursor", doc.cursor, 5, &fail)
			chk("caret drawn after dblclick past EOL", 1 if caret_claimed(&doc, &t, 5) else 0, 1, &fail)

			// Selecting the whole first line stops at the content end.
			doc.anchor, doc.cursor = 0, 5
			nq := doc_selection_rects(&doc, &t, px, cw, 5, make([]plat.Quad, 8, context.temp_allocator))
			chk("selection rects for line 0", nq, 1, &fail)

			// The wrap budget must not spend a cell on the CR: it costs zero cells by
			// construction (plat.is_zero_width) now, not by font-metric accident --
			// wrap_row_end no longer special-cases CR at all (Important 2). The old
			// "wrap_row_end at 5 cells"/"line_end" pair here could pass with the
			// dedicated CR-skip block deleted and no zero-width guarantee in its
			// place, because the font happened to also measure CR as ~0 -- this is
			// the assertion that actually pins the guarantee down.
			// Column 0: CR is not a tab, so the column cannot affect its width --
			// that is the whole content of this assertion.
			chk("CR cell width (zero by construction)", plat.text_cell_width_at(&t, '\r', 0, .Doc), 0, &fail)

			// CRLF x wrap: nothing above exercises eff_row_end's wrapped branch or
			// visible_next's wrapped vis_end, since none of wraptest/wraplongtest use
			// CRLF content. A CR landing exactly at the wrap column must not be pulled
			// into row 0 as content, and the row that actually reaches the CRLF break
			// must still report it as a break, not as two ordinary bytes.
			{
				wdoc: Document
				wdoc.pt = base.pt_init(transmute([]u8)string("hello\r\n"))
				defer base.pt_destroy(&wdoc.pt)
				wdoc.eol = .CRLF
				wdoc.wrap = true
				wdoc.view_cols = 4
				wit := visible_begin(&wdoc, &t, 2)
				_, _, e0, ve0, le0, _, _ := visible_next(&wit)
				chk("wrap row 0 end (mid-line wrap)", e0, 4, &fail)
				chk("wrap row 0 vis_end (no CR here)", ve0, 4, &fail)
				chk("wrap row 0 line_end", 1 if le0 else 0, 0, &fail)
				_, s1, e1, ve1, le1, _, _ := visible_next(&wit)
				chk("wrap row 1 start", s1, 4, &fail)
				chk("wrap row 1 end at real newline", e1, 6, &fail)
				chk("wrap row 1 line_end", 1 if le1 else 0, 1, &fail)
				chk("wrap row 1 vis_end (before CR)", ve1, 5, &fail)
			}

			// An empty CRLF line ("\r\n\r\n"): two adjacent breaks with genuinely empty
			// content between them. A CR check that doesn't require the following LF
			// would treat the second break's CR as one byte of content, off by one on
			// both the caret and a click.
			{
				edoc: Document
				edoc.pt = base.pt_init(transmute([]u8)string("\r\n\r\n"))
				defer base.pt_destroy(&edoc.pt)
				edoc.eol = .CRLF
				edoc.view_cols = 40
				edoc.cursor, edoc.anchor = 0, 0
				doc_cursor_end(&edoc, false)
				chk("End on empty CRLF line lands at", edoc.cursor, 0, &fail)
				chk("click on empty CRLF line clamps to", doc_pos_at(&edoc, &t, i32(cw * 10), 0, px, cw, 5), 0, &fail)
			}

			// One Delete at the content end must consume the whole CRLF break, not
			// the CR alone -- otherwise the buffer still renders two lines (the
			// keystroke looks dead) and the stray LF corrupts an otherwise-CRLF file
			// on save (Critical 1). Assert the buffer bytes, not just the cursor.
			{
				ddoc: Document
				ddoc.pt = base.pt_init(transmute([]u8)string("hello\r\nworld"))
				defer base.pt_destroy(&ddoc.pt)
				ddoc.eol = .CRLF
				ddoc.cursor, ddoc.anchor = 5, 5 // the CR, i.e. vis_end
				doc_delete_fwd(&ddoc)
				chks("Delete at break ->", string(base.pt_collect(&ddoc.pt, context.temp_allocator)), "helloworld", &fail)
				chk("Delete at break cursor stays", ddoc.cursor, 5, &fail)
			}

			// The mirror: one Backspace at a line start must remove the whole break,
			// not the LF alone leaving a bare CR. Pre-existing bug, but it now sits
			// inconsistently beside the CRLF-atomic Left arrow.
			{
				bdoc: Document
				bdoc.pt = base.pt_init(transmute([]u8)string("hello\r\nworld"))
				defer base.pt_destroy(&bdoc.pt)
				bdoc.eol = .CRLF
				bdoc.cursor, bdoc.anchor = 7, 7 // start of "world"
				doc_backspace(&bdoc)
				chks("Backspace at break ->", string(base.pt_collect(&bdoc.pt, context.temp_allocator)), "helloworld", &fail)
				chk("Backspace at break cursor lands at", bdoc.cursor, 5, &fail)
			}

			fmt.println("crlftest: FAILURES" if fail else "crlftest: all ok")
			return true
		}

		// `newtpad pastetest` -- the Windows clipboard is CRLF by convention, so
		// pasting into an LF file mixed line endings silently, through the most
		// common way multi-line text enters a buffer.
		if os.args[1] == "pastetest" {
			if !require_scratch_session("pastetest") {return true}
			bad := 0
			fmt.println("pastetest:")

			// The user's clipboard, guarded for the whole mode on every exit path.
			saved_clip, had_clip := plat.clipboard_get_text(nil, context.allocator)
			defer if had_clip {
				plat.clipboard_set_text(nil, saved_clip)
				delete(saved_clip)
			}

			paste_case :: proc(eol: base.Line_Ending, clip, want: string) -> (bad: int) {
				a: App
				defer app_destroy(&a) // owns and closes the Document added below
				d := new(Document)
				d^ = doc_from_content(make([]u8, 0), "", .UTF8)
				d.eol = eol
				app_add(&a, d)
				app_activate(&a, 0)
				// hwnd nil: clipboard_get_text/clipboard_set_text take a nil owner
				// (blocktest already does exactly this), and the .Paste arm of
				// command_dispatch reads nothing else off the window. `t` is nil
				// because no rectangle is live, so no cell measuring happens.
				wv: plat.Window
				plat.clipboard_set_text(nil, clip)
				command_dispatch(.Paste, plat.Key_Event{}, &a, &wv, nil, 0)
				got := doc_debug_string(d)
				ok := got == want
				fmt.printfln("  %-6s eol=%v paste %q -> %q (want %q)", "ok" if ok else "FAIL", eol, clip, got, want)
				if !ok {bad += 1}
				return
			}
			bad += paste_case(.LF, "a\r\nb", "a\nb")
			bad += paste_case(.CRLF, "a\nb", "a\r\nb")
			// A LONE CR is data and must arrive unchanged. It used to become a line
			// break, which invents a row: Newtpad counts lines by '\n' only, so
			// "a\rb" is one line before the paste and must be one line after it.
			// Real in a CSV field and in terminal output that redraws a progress
			// line with a carriage return. Both targets, because the CRLF direction
			// is where a slip attaches an '\n' to the CR instead of leaving it.
			bad += paste_case(.LF, "a\rb", "a\rb")
			bad += paste_case(.CRLF, "a\rb", "a\rb")
			// The CR-then-real-break sequence, so the fix cannot be "ignore every
			// CR": the CRLF after it must still normalise.
			bad += paste_case(.LF, "a\rb\r\nc", "a\rb\nc")

			fmt.printfln("pastetest: %d failures", bad)
			return true
		}

		// `newtpad stickytest` checks the find bar's sticky match figures during an
		// async replace. Below SEARCH_SYNC_MAX the search runs inline and every result
		// publishes before find_recompute even returns, so a fixture that size proves
		// nothing -- the flicker this guards against only exists on the worker-thread
		// path. The fixture is built here in memory (mirrors wraptest) rather than
		// read from a file, so this is reachable by anyone who checks out the branch,
		// not just whoever had a scratch file lying around when the bug was found.
		if os.args[1] == "stickytest" {
			fail := false

			// Every NEEDLE sits in the first 72 bytes, comfortably inside the worker's
			// first SEARCH_BLOCK (256 KiB) read. That guarantees the whole result set
			// publishes in one find_merge call -- the same shape the synchronous path
			// always has -- so a corrupted sticky value can never be quietly
			// self-corrected by a second partial merge landing after the jump has
			// already run once. The filler after it never contains "NEEDLE", so the
			// match count stays exactly NEEDLES while the buffer is pushed well past
			// SEARCH_SYNC_MAX, which is what puts the search on the worker thread at
			// all.
			NEEDLES :: 8
			sb := strings.builder_make(context.temp_allocator)
			for i in 0 ..< NEEDLES {fmt.sbprintf(&sb, "NEEDLE %d\n", i)}
			FILLER_LINES :: 7000 // ~7000 * 45 bytes =~ 315 KB, well past the 256 KiB threshold
			for i in 0 ..< FILLER_LINES {strings.write_string(&sb, "the quick brown fox jumps over the lazy dog\n")}
			content := strings.to_string(sb)

			doc: Document
			doc.pt = base.pt_init(transmute([]u8)content)
			defer doc_close(&doc) // frees search results + find.query/replace, then doc.pt

			over := doc.pt.length > SEARCH_SYNC_MAX
			if !over {fail = true}
			fmt.printfln(
				"  %-6s fixture size=%d bytes (SEARCH_SYNC_MAX=%d), needles=%d",
				"ok" if over else "FAIL",
				doc.pt.length,
				SEARCH_SYNC_MAX,
				NEEDLES,
			)

			find_open(&doc, true)
			for r in "NEEDLE" {find_input_rune(&doc, r)}
			doc.find.field = 1
			for r in "found" {find_input_rune(&doc, r)}
			doc.find.field = 0
			find_wait(&doc)
			matched := len(doc.find.matches) == NEEDLES
			if !matched {fail = true}
			fmt.printfln("  %-6s initial matches=%d (want %d)", "ok" if matched else "FAIL", len(doc.find.matches), NEEDLES)

			// Replace one match at a time. Immediately after each replace -- before
			// find_wait lets the restarted search finish -- read the state exactly as
			// render_frame does: while matches is empty and the search is still
			// running, last_total/last_current must still be the previous search's
			// real figures, never zero and never -1.
			zeroed, stuck := false, false
			total0 := len(doc.find.matches)
			for i in 0 ..< total0 {
				find_replace_current(&doc)
				if len(doc.find.matches) == 0 && search_running(&doc) {
					if doc.find.last_total == 0 {zeroed = true}
					if doc.find.last_current < 0 {stuck = true}
				}
				find_wait(&doc)
			}
			if zeroed {fail = true}
			if stuck {fail = true}
			fmt.printfln("  %-6s count never zeroed across %d replaces", "ok" if !zeroed else "FAIL", total0)
			fmt.printfln("  %-6s last_current never stuck at -1 across %d replaces", "ok" if !stuck else "FAIL", total0)

			fmt.println("stickytest: FAILURES" if fail else "stickytest: all ok")
			return true
		}

		// `newtpad droptest` exercises the drag-and-drop consumer without a real OS
		// drop. WM_DROPFILES itself can't be synthesized headlessly, but everything
		// downstream of "the queue has paths in it" is ordinary code shared with the
		// WM_COPYDATA single-instance handoff, so this drives app_consume_open_requests
		// directly -- the exact proc the frame loop calls, not a parallel copy of it.
		if os.args[1] == "droptest" {
			fail := false

			tmp := os.get_env("TEMP", context.temp_allocator)
			dir := fmt.tprintf("%s\\newtpad_droptest", tmp)
			os.remove_all(dir) // in case a previous run crashed before cleaning up
			if err := os.make_directory(dir); err != nil {
				fmt.eprintfln("droptest: could not create %q: %v", dir, err)
				return true
			}
			defer os.remove_all(dir) // real files on disk; must not be left behind

			fileA := fmt.tprintf("%s\\a.txt", dir)
			fileB := fmt.tprintf("%s\\b.txt", dir)
			subdir := fmt.tprintf("%s\\sub", dir)
			missing := fmt.tprintf("%s\\does_not_exist.txt", dir)

			if werr := os.write_entire_file(fileA, transmute([]u8)string("alpha\n")); werr != nil {
				fmt.eprintfln("droptest: could not seed %q: %v", fileA, werr)
				return true
			}
			if werr := os.write_entire_file(fileB, transmute([]u8)string("beta\n")); werr != nil {
				fmt.eprintfln("droptest: could not seed %q: %v", fileB, werr)
				return true
			}
			if err := os.make_directory(subdir); err != nil {
				fmt.eprintfln("droptest: could not create %q: %v", subdir, err)
				return true
			}

			a: App
			menu_init(&a.menu)
			defer app_destroy(&a)

			// Order: the folder first, then the two files, then a path that does not
			// exist -- so "focus lands on the first successfully opened tab" is
			// actually exercised (the first queue entry is not the one that should
			// end up focused).
			app_consume_open_requests(&a, []string{subdir, fileA, fileB, missing})

			live := app_live_count(&a)
			want_live := 2 // fileA, fileB -- subdir and missing produced no tab
			ok1 := live == want_live
			fmt.printfln("  %-6s tabs opened = %d (want %d)", "ok" if ok1 else "FAIL", live, want_live)
			if !ok1 {fail = true}

			focused := app_active(&a)
			ok2 := focused != nil && focused.path == fileA
			fmt.printfln("  %-6s focus on first opened: %q", "ok" if ok2 else "FAIL", focused.path if focused != nil else "<nil>")
			if !ok2 {fail = true}

			// The note has to be findable, which is a wording property as much as a
			// colour one: it rides at the end of a status line that already carries
			// line/column, encoding, line ending and line count. The loud
			// conditions on that line use a [BRACKETED CAPS] idiom ([CHANGED ON
			// DISK ...], [GLYPH CACHE FULL ...]); this asserts the folder note
			// joins them, and that the two kinds are counted separately rather than
			// summed into the old "2 items skipped", which made the user guess
			// which had happened.
			ok3 :=
				app_notice_active(&a) &&
				strings.contains(a.notice, "[FOLDERS NOT OPENED") &&
				strings.contains(a.notice, "1 folder") &&
				strings.contains(a.notice, "1 file")
			fmt.printfln("  %-6s notice names folders and unreadable files separately: %q", "ok" if ok3 else "FAIL", a.notice)
			if !ok3 {fail = true}

			// Re-dropping a path that is already open must activate the existing tab
			// rather than open a second one -- pinning app_open_path's existing
			// dedupe behaviour rather than changing it.
			before := live
			app_consume_open_requests(&a, []string{fileB})
			after := app_live_count(&a)
			ok4 := after == before && app_active(&a) != nil && app_active(&a).path == fileB
			fmt.printfln("  %-6s re-drop activates the existing tab (%d -> %d tabs)", "ok" if ok4 else "FAIL", before, after)
			if !ok4 {fail = true}

			fmt.println("droptest: FAILURES" if fail else "droptest: all ok")
			return true
		}

		// `newtpad dropfittest` exercises the skip-vs-truncate decision inside
		// WM_DROPFILES (plat.drop_wide_fits / plat.drop_path_convert) directly.
		// droptest above can't reach this: it drives app_consume_open_requests,
		// well downstream of the handler, and WM_DROPFILES itself needs a live
		// HDROP this environment can't synthesize. These two procs were pulled
		// out of the handler specifically so the skip boundary is testable
		// without one -- see the review fix in window.odin's WM_DROPFILES case.
		if os.args[1] == "dropfittest" {
			fail := false
			chk :: proc(fail: ^bool, label: string, got: bool) {
				fmt.printfln("  %-6s %s", "ok" if got else "FAIL", label)
				if !got {fail^ = true}
			}

			// 1. Comfortably fits: an ordinary short ASCII path.
			{
				s := "C:\\Users\\test\\hello.txt"
				wide: [plat.OPEN_PATH_MAX]u16
				n := utf16.encode_string(wide[:], s)
				need := n + 1 // DragQueryFileW's nil-buffer query includes the null terminator
				chk(&fail, "fits: drop_wide_fits accepts", plat.drop_wide_fits(need))
				out: [plat.OPEN_PATH_MAX]u8
				path, ok := plat.drop_path_convert(wide[:n], out[:])
				chk(&fail, "fits: drop_path_convert converts", ok && path == s)
			}

			// 2. Exactly at the wide-character cap: OPEN_PATH_MAX-1 chars, so
			// need == OPEN_PATH_MAX -- the boundary drop_wide_fits must still
			// accept (its check is need <= OPEN_PATH_MAX, not <).
			{
				s, _ := strings.repeat("a", plat.OPEN_PATH_MAX - 1, context.temp_allocator)
				wide: [plat.OPEN_PATH_MAX]u16
				n := utf16.encode_string(wide[:], s)
				need := n + 1
				chk(&fail, "at cap: drop_wide_fits accepts need == OPEN_PATH_MAX", need == plat.OPEN_PATH_MAX && plat.drop_wide_fits(need))
				out: [plat.OPEN_PATH_MAX]u8
				path, ok := plat.drop_path_convert(wide[:n], out[:])
				chk(&fail, "at cap: drop_path_convert converts", ok && len(path) == n)
			}

			// 3. One wide character over the cap: DragQueryFileW would have to
			// truncate to fit wbuf. Must be skipped, never truncated -- this is
			// the finding the fix addresses, so it's the most load-bearing
			// assertion in this mode. Checked against need one past the exact
			// cap (not a generic "big number"), so a boundary-off-by-one
			// (e.g. accepting need <= OPEN_PATH_MAX + 1) fails this test instead
			// of slipping through on a value nobody would hit in practice.
			{
				s, _ := strings.repeat("a", plat.OPEN_PATH_MAX, context.temp_allocator)
				wide: [plat.OPEN_PATH_MAX + 1]u16
				n := utf16.encode_string(wide[:], s)
				need := n + 1
				chk(&fail, "over cap: drop_wide_fits rejects (skip, not truncate)", need == plat.OPEN_PATH_MAX + 1 && !plat.drop_wide_fits(need))
			}

			// 4. Wide length fits, but the UTF-8 expansion doesn't: 400 CJK
			// characters are 400 UTF-16 code units (well under the cap) but
			// 1200 UTF-8 bytes (over it). Confirms the byte-cap check still
			// catches what the wide-cap check structurally cannot.
			{
				cjk_count :: 400
				runes: [cjk_count]rune
				for i in 0 ..< cjk_count {runes[i] = '中'}
				wide: [plat.OPEN_PATH_MAX]u16
				n := utf16.encode(wide[:], runes[:])
				chk(&fail, "utf8 overflow: wide length fits", plat.drop_wide_fits(n + 1))
				out: [plat.OPEN_PATH_MAX]u8
				_, ok := plat.drop_path_convert(wide[:n], out[:])
				chk(&fail, "utf8 overflow: drop_path_convert rejects (byte cap)", !ok)
			}

			fmt.println("dropfittest: FAILURES" if fail else "dropfittest: all ok")
			return true
		}

		// `newtpad highlighttest` is Task 1's Step 5: the failure mode of the whole
		// syntax-highlighting batch is a lexer that is correct and quietly O(file).
		// It proves highlight_row_spans/doc_row_lex_spans (highlight.odin, doc.odin)
		// cost the same per viewport regardless of document size, using a counter
		// of bytes handed to the lexer (hl_bytes_examined) rather than wall-clock,
		// so the assertion is stable. It also proves the assertion CAN fail: a
		// "buggy" variant, injected only in this test's own harness (never in the
		// shipping row loop), feeds the lexer everything from byte 0 instead of
		// just the current row, and the byte count must then diverge between a
		// small and a huge file. Finally it checks the wrap-rebase path
		// (doc_row_lex_spans's wrapped branch) directly: a bare number straddling a
		// forced wrap point must still be fully covered, split correctly across
		// both visual rows, each rebased to start within that row's own bytes.
		if os.args[1] == "highlighttest" {
			fmt.println("highlighttest:")
			fail := false

			// The link-precedence checks below distinguish spans by their theme
			// colour (Syn_Number vs Syn_Keyword vs Syn_String vs Link). Without a
			// theme loaded, g_theme is its zero value, making every Color_Role
			// compare equal by accident. theme_dark() itself doesn't help either:
			// its Syn_* roles are still an unfilled magenta placeholder (batch 4
			// hasn't wired Dark's syntax colours yet, see theme.odin), so every
			// Syn_* role there is the SAME magenta too. theme_light() already has
			// real, mutually distinct provisional values for all nine Syn_* roles
			// (theme.odin's own comment: "chosen for legibility and mutual
			// distinctness"), so it's what this test needs -- the other checks in
			// this mode don't care which theme is loaded (they only ever compare
			// one role's colour to itself).
			g_theme = theme_light()

			t: plat.Text
			if !plat.text_load_faces(&t) {
				fmt.eprintln("highlighttest: no fonts loaded")
				return true
			}

			// One repeating log line carrying all four patterns lex_log recognizes,
			// so every row does real (not trivially-empty) lexing work.
			line := "2026-07-25T10:23:45Z ERROR failed to open \"C:\\log.txt\" after 42 retries\n"

			make_doc :: proc(line: string, repeats: int) -> Document {
				sb := strings.builder_make(context.temp_allocator)
				for _ in 0 ..< repeats {strings.write_string(&sb, line)}
				d: Document
				d.pt = base.pt_init(transmute([]u8)strings.to_string(sb))
				d.path = "test.log"
				d.view_cols = 200
				return d
			}

			// Bytes handed to the lexer while drawing `rows` visible rows from
			// doc.top, via the SAME per-row loop shape doc_draw uses (visible_begin/
			// next, then either highlight_row_spans directly for an unwrapped row or
			// doc_row_lex_spans's cache for a wrapped one). `buggy`, when true, feeds
			// the lexer everything from byte 0 through the current row's end instead
			// of just the row's own bytes -- a stand-in for "the row-span builder
			// scans from the buffer start" -- to prove the assertion below can
			// actually fail, not just that it happens to pass.
			measure :: proc(doc: ^Document, t: ^plat.Text, rows: int, buggy: bool) -> int {
				hl_bytes_examined = 0
				line_buf: [VISIBLE_COLS]u8
				hl_cache: Highlight_Row_Cache
				it := visible_begin(doc, t, rows)
				for {
					_, start, end, vis_end, _, wrapped, ok := visible_next(&it)
					if !ok {break}
					draw_len := min(vis_end - start, len(line_buf))
					n := base.pt_read(&doc.pt, start, line_buf[:draw_len])
					if n <= 0 {continue}
					hl_buf: [HL_MAX_ROW_TOKENS]plat.Text_Span
					if buggy {
						whole := make([]u8, end, context.temp_allocator)
						got := base.pt_read(&doc.pt, 0, whole)
						highlight_row_spans(doc, whole[:got], .Normal, hl_buf[:])
					} else {
						doc_row_lex_spans(doc, &hl_cache, start, end, wrapped, line_buf[:n], .Normal, hl_buf[:])
					}
				}
				return hl_bytes_examined
			}

			rows := 30
			// `small` must have enough lines left after `top` to fill every one of
			// `rows` rows -- otherwise visible_next runs out of document and the
			// loop stops early, examining fewer rows (and so fewer bytes) than
			// `big` for a reason that has nothing to do with the code under test.
			// That is exactly the shape of bug this fixture must not itself have:
			// it first shipped with small=20/top=5 lines, leaving only 15 lines for
			// 30 rows, and "big examines 2x small's bytes" looked like a real
			// failure until this comment's fix.
			small := make_doc(line, rows + 10) // ~3 KB: a few rows' margin past `top`
			big := make_doc(line, 200000) // ~15 MB
			defer base.pt_destroy(&small.pt)
			defer base.pt_destroy(&big.pt)
			// Not byte 0: a few lines in, so a builder that secretly scans from the
			// start would show up as size-dependent even though doc.top itself is a
			// small, fixed-looking offset on both documents.
			small.top = len(line) * 5
			big.top = len(line) * 100000
			small_bytes := measure(&small, &t, rows, false)
			big_bytes := measure(&big, &t, rows, false)
			ok := small_bytes > 0 && small_bytes == big_bytes
			if !ok {fail = true}
			fmt.printfln(
				"  %-6s viewport-proportional: small=%d big=%d (want equal, both > 0)",
				"ok" if ok else "FAIL",
				small_bytes,
				big_bytes,
			)

			small_buggy := measure(&small, &t, rows, true)
			big_buggy := measure(&big, &t, rows, true)
			// The bug must show up as a large, unmistakable gap, not noise -- big's
			// doc.top is ~100000 lines in, so scanning from byte 0 on every one of
			// its 30 rows examines roughly 100000x more bytes than small's does.
			caught := big_buggy > small_buggy * 10
			if !caught {fail = true}
			fmt.printfln(
				"  %-6s assertion can fail: buggy variant diverges (small=%d big=%d)",
				"ok" if caught else "FAIL",
				small_buggy,
				big_buggy,
			)

			// Wrap rebase: a single bare number wider than the row forces a mid-token
			// wrap (word-wrap breaks at the last fitting space; a token with none
			// char-breaks -- see wrap_row_end's comment). The Number token must still
			// be found in full across the wrapped rows, each piece rebased to start
			// within [0, that row's own byte count) -- never negative, never past
			// what's actually drawn on that row.
			{
				digits := "12345678901234567890" // 20 digits, no internal separators
				content := strings.concatenate({digits, " done\n"}, context.temp_allocator)
				wd: Document
				wd.pt = base.pt_init(transmute([]u8)content)
				defer base.pt_destroy(&wd.pt)
				wd.path = "test.log"
				wd.wrap = true
				wd.view_cols = 10

				wcache: Highlight_Row_Cache
				line_buf: [VISIBLE_COLS]u8
				total_len, first_start := 0, -1
				bounds_ok := true
				wit := visible_begin(&wd, &t, 6)
				for {
					_, start, end, vis_end, _, wrapped, ok := visible_next(&wit)
					if !ok {break}
					draw_len := min(vis_end - start, len(line_buf))
					n := base.pt_read(&wd.pt, start, line_buf[:draw_len])
					if n <= 0 {continue}
					hl_buf: [HL_MAX_ROW_TOKENS]plat.Text_Span
					hn, _ := doc_row_lex_spans(&wd, &wcache, start, end, wrapped, line_buf[:n], .Normal, hl_buf[:])
					for k in 0 ..< hn {
						sp := hl_buf[k]
						if sp.color != g_theme[.Syn_Number] {continue}
						if first_start < 0 {first_start = sp.start}
						total_len += sp.len
						if sp.start < 0 || sp.start + sp.len > n {bounds_ok = false}
					}
				}
				wrap_ok := bounds_ok && first_start == 0 && total_len == len(digits)
				if !wrap_ok {fail = true}
				fmt.printfln(
					"  %-6s wrap rebase: number split across rows, total_len=%d (want %d) first_start=%d (want 0) bounds_ok=%v",
					"ok" if wrap_ok else "FAIL",
					total_len,
					len(digits),
					first_start,
					bounds_ok,
				)
			}

			// Wrapped rows PAST WRAP_START_CAP -- the case the rebase check above
			// cannot reach, because its line is 26 bytes long. One logical line of
			// ~28 KB with word wrap ON: a line whose own newline sits beyond
			// WRAP_START_CAP never FORCE-wraps (line_wrap_decision, doc.odin), so
			// only the user's wrap setting produces wrapped rows this far into a
			// line -- and once a row starts more than WRAP_START_CAP (8192) bytes
			// past the line start, pt_line_start_cap can no longer find that start
			// and returns a scan FLOOR that slides forward with every visual row,
			// flagged exact=false.
			//
			// doc_row_lex_spans used to discard that flag (`lls, _ :=`) and treat
			// the floor as a line start, which broke both of its outputs at once:
			// state_in (the state at the PREVIOUS logical line's end) got applied
			// at an arbitrary mid-line byte and the result reported as what the
			// WHOLE line ends in, and the rebase window collapsed ([row_off,
			// row_end_off) is empty once the floor sits exactly RENDER_LINE_CAP
			// behind the row) so the row drew with no spans at all. Both are
			// asserted here: the state threaded through the draw path must match
			// what doc_lex_state_at independently reports for the same byte offset,
			// and the row after the comment opens must actually be coloured as one.
			//
			// The SECOND half of the same bug lives nearer the front of the line
			// and needs its own marker: for a row whose line start IS findable
			// (exact=true, anywhere in the first WRAP_START_CAP bytes), the cached
			// whole-line read is still capped at RENDER_LINE_CAP, so on a line
			// longer than that it can neither colour nor account for anything past
			// byte 8192 -- while still reporting its result as the whole line's.
			// CLOSED_AT puts a complete `/* */` just past that cap, inside the row
			// that straddles it, so a cache built from a truncated read shows up as
			// an uncoloured comment rather than only as a wrong state.
			//
			// WHICH HALF THIS ACTUALLY PINS, stated plainly because the name above
			// overclaims: every assertion here fails when the truncated-read guard
			// goes, and NONE of them fail when only the exact=false guard goes.
			// That is not slack in the fixture -- it is doc_row_lex_extent's
			// #assert(WRAP_START_CAP >= RENDER_LINE_CAP) holding: with the caps
			// equal, an inexact floor is start-8192 and the end scan can only reach
			// `start`, so the truncation guard catches the same rows. Break that
			// assert and this test goes quiet; the assert, not this fixture, is what
			// guards the exact flag.
			{
				CLOSED_AT :: 9000 // just past RENDER_LINE_CAP: inside the row straddling it
				CLOSED_LEN :: 102 // "/*" + 98 filler + "*/"
				OPEN_AT :: 20500 // > 2x WRAP_START_CAP into the line: the floor is nowhere near the truth
				ROW_COLS :: 2000 // no spaces anywhere below, so rows char-break on exactly this stride
				content := strings.concatenate(
					{
						strings.repeat("a", CLOSED_AT, context.temp_allocator),
						"/*", // a COMPLETE comment, past the cached read's cap
						strings.repeat("z", CLOSED_LEN - 4, context.temp_allocator),
						"*/",
						strings.repeat("a", OPEN_AT - CLOSED_AT - CLOSED_LEN, context.temp_allocator),
						"/*", // opens a block comment that never closes: every byte past here is In_Comment
						strings.repeat("b", 8000, context.temp_allocator),
						"\n",
					},
					context.temp_allocator,
				)
				cd: Document
				cd.pt = base.pt_init(transmute([]u8)content)
				defer base.pt_destroy(&cd.pt)
				cd.path = "test.c"
				cd.wrap = true
				cd.view_cols = ROW_COLS

				cache: Highlight_Row_Cache
				line_buf: [VISIBLE_COLS]u8
				all_wrapped := true
				open_row_start, open_row_end := -1, -1
				open_row_state := base.Lex_State.Normal
				next_row_len, next_row_comment := -1, 0
				straddle_comment := 0 // Comment-coloured bytes on the row spanning RENDER_LINE_CAP
				hl_state := base.Lex_State.Normal // byte 0 of the document: unambiguously .Normal
				it := visible_begin(&cd, &t, 20)
				for {
					_, start, end, vis_end, _, wrapped, ok := visible_next(&it)
					if !ok {break}
					if !wrapped {all_wrapped = false}
					draw_len := min(vis_end - start, len(line_buf))
					n := base.pt_read(&cd.pt, start, line_buf[:draw_len])
					if n <= 0 {continue}
					hl_buf: [HL_MAX_ROW_TOKENS]plat.Text_Span
					hn: int
					hn, hl_state = doc_row_lex_spans(&cd, &cache, start, end, wrapped, line_buf[:n], hl_state, hl_buf[:])
					if start <= CLOSED_AT && CLOSED_AT < end {
						for k in 0 ..< hn {
							if hl_buf[k].color == g_theme[.Syn_Comment] {straddle_comment += hl_buf[k].len}
						}
					}
					// The row the comment opens ON, then the row after it -- that
					// one is entirely inside the comment, so entirely one span.
					if start <= OPEN_AT && OPEN_AT < end {
						open_row_start, open_row_end = start, end
						open_row_state = hl_state
					} else if open_row_end == start && next_row_len < 0 {
						next_row_len = end - start
						for k in 0 ..< hn {
							if hl_buf[k].color == g_theme[.Syn_Comment] {next_row_comment += hl_buf[k].len}
						}
					}
				}
				// Ground truth for the same byte offset through the independent
				// mechanism (lex_index.odin's bounded resync -- this Document was
				// never handed to lex_index_start, so doc_lex_state_at can't
				// shortcut to the background index).
				truth := doc_lex_state_at(&cd, open_row_end, LEX_RESYNC_WINDOW)
				past_cap := open_row_start > WRAP_START_CAP
				long_ok :=
					past_cap &&
					all_wrapped &&
					open_row_state == .In_Comment &&
					truth == open_row_state &&
					next_row_len > 0 &&
					next_row_comment == next_row_len &&
					straddle_comment == CLOSED_LEN
				if !long_ok {fail = true}
				fmt.printfln(
					"  %-6s wrapped row past WRAP_START_CAP: row=[%d,%d) wrapped=%v state=%v truth=%v, next row comment-coloured %d/%d bytes, straddle row %d/%d",
					"ok" if long_ok else "FAIL",
					open_row_start,
					open_row_end,
					all_wrapped,
					open_row_state,
					truth,
					next_row_comment,
					next_row_len,
					straddle_comment,
					CLOSED_LEN,
				)
			}

			// Link precedence: the drop-then-merge in doc_draw (factored out as
			// highlight_merge_spans, highlight.odin) is the one place this batch's
			// three interactions (lexer spans, links, wrap) actually collide, and a
			// 2026-07 review found it had no test beyond "hand-verified by reading
			// the code." These checks call highlight_merge_spans directly -- the
			// literal proc doc_draw calls, not a copy -- first against a real .log
			// row with a URL a lexer token also covers, then against synthetic spans
			// that pin down all four ways a link and a token can intersect, plus the
			// adjacent-but-not-overlapping case that must NOT drop (the boundary
			// where < vs <= matters).
			{
				LEX := [4]f32{1, 0, 0, 1}
				LINK := [4]f32{0, 1, 0, 1}

				// Valid input to text_draw_spans only if ascending by start with no
				// overlap between consecutive spans -- exactly the precondition
				// highlight_merge_spans exists to uphold.
				sorted_no_overlap :: proc(spans: []plat.Text_Span) -> bool {
					for i in 1 ..< len(spans) {
						if spans[i].start < spans[i - 1].start + spans[i - 1].len {return false}
					}
					return true
				}
				spans_eq :: proc(a, b: []plat.Text_Span) -> bool {
					if len(a) != len(b) {return false}
					for i in 0 ..< len(a) {
						if a[i].start != b[i].start || a[i].len != b[i].len || a[i].color != b[i].color {return false}
					}
					return true
				}
				has_color :: proc(spans: []plat.Text_Span, color: [4]f32) -> bool {
					for s in spans {
						if s.color == color {return true}
					}
					return false
				}

				// The motivating real-world case: a quoted string that wraps a URL.
				// The String token (the whole "..." run) and the URL Link genuinely
				// overlap on real bytes, unlike the synthetic cases below -- this is
				// "link inside token" with a real lexer and a real link scan behind
				// it, not just asserted geometry.
				{
					row := `2026-07-25T10:23:45Z ERROR fetch "https://example.com/x" failed`
					rdoc: Document
					rdoc.path = "test.log"
					hl_buf: [HL_MAX_ROW_TOKENS]plat.Text_Span
					hl_n, _ := highlight_row_spans(&rdoc, transmute([]u8)row, .Normal, hl_buf[:])
					lks := links_scan(row)
					link_buf := make([]plat.Text_Span, len(lks), context.temp_allocator)
					for l, i in lks {link_buf[i] = plat.Text_Span{start = l.start, len = l.len, color = LINK}}
					merged := make([]plat.Text_Span, hl_n + len(link_buf), context.temp_allocator)
					mn := highlight_merge_spans(hl_buf[:hl_n], link_buf, merged)
					out := merged[:mn]

					url_start := strings.index(row, "https://")
					url_len := len("https://example.com/x")
					ts_len := len("2026-07-25T10:23:45Z")
					kw_start := strings.index(row, "ERROR")
					found_link, found_ts, found_kw := false, false, false
					for s in out {
						if s.start == url_start && s.len == url_len && s.color == LINK {found_link = true}
						if s.start == 0 && s.len == ts_len && s.color == g_theme[.Syn_Number] {found_ts = true}
						if s.start == kw_start && s.len == len("ERROR") && s.color == g_theme[.Syn_Keyword] {found_kw = true}
					}
					// The quoted-string token must be dropped WHOLE: no span anywhere
					// in the output may carry the String colour, because the only
					// String token on this row is the one the link overlaps.
					real_ok :=
						sorted_no_overlap(out) &&
						found_link &&
						found_ts &&
						found_kw &&
						!has_color(out, g_theme[.Syn_String])
					if !real_ok {fail = true}
					fmt.printfln(
						"  %-6s link precedence, real row: quoted URL wins over String token, timestamp/ERROR untouched (n=%d)",
						"ok" if real_ok else "FAIL",
						mn,
					)
				}

				// Synthetic geometry: exact control over where a link's boundary
				// falls relative to a token's, covering all four intersection shapes
				// the review enumerated plus the adjacent-but-not-overlapping case
				// (both directions) that must survive untouched. Each case also
				// carries an unrelated, non-intersecting span that must pass through
				// unharmed -- proving the drop is selective, not "any link present
				// nukes the row."
				Case :: struct {
					label:              string,
					lex, link_in, want: []plat.Text_Span,
				}
				cases := []Case{
					{
						label = "partial overlap: link starts before token, ends inside it",
						lex = []plat.Text_Span{{10, 10, LEX}, {40, 5, LEX}},
						link_in = []plat.Text_Span{{5, 8, LINK}}, // [5,13) overlaps [10,20)'s left edge
						want = []plat.Text_Span{{5, 8, LINK}, {40, 5, LEX}},
					},
					{
						label = "partial overlap: token starts before link, ends inside it",
						lex = []plat.Text_Span{{10, 10, LEX}, {40, 5, LEX}},
						link_in = []plat.Text_Span{{15, 10, LINK}}, // [15,25) overlaps [10,20)'s right edge
						want = []plat.Text_Span{{15, 10, LINK}, {40, 5, LEX}},
					},
					{
						label = "link entirely inside token",
						lex = []plat.Text_Span{{10, 20, LEX}, {40, 5, LEX}}, // [10,30)
						link_in = []plat.Text_Span{{15, 5, LINK}}, // [15,20) inside [10,30)
						want = []plat.Text_Span{{15, 5, LINK}, {40, 5, LEX}},
					},
					{
						label = "token entirely inside link",
						lex = []plat.Text_Span{{15, 5, LEX}, {40, 5, LEX}}, // [15,20)
						link_in = []plat.Text_Span{{10, 20, LINK}}, // [10,30) contains [15,20)
						want = []plat.Text_Span{{10, 20, LINK}, {40, 5, LEX}},
					},
					{
						label = "adjacent, link right after token: must NOT drop",
						lex = []plat.Text_Span{{10, 10, LEX}}, // [10,20)
						link_in = []plat.Text_Span{{20, 5, LINK}}, // [20,25) touches, doesn't overlap
						want = []plat.Text_Span{{10, 10, LEX}, {20, 5, LINK}},
					},
					{
						label = "adjacent, link right before token: must NOT drop",
						lex = []plat.Text_Span{{20, 10, LEX}}, // [20,30)
						link_in = []plat.Text_Span{{10, 10, LINK}}, // [10,20) touches, doesn't overlap
						want = []plat.Text_Span{{10, 10, LINK}, {20, 10, LEX}},
					},
					{
						label = "no overlap, interleaved: merge must interleave by start, not concatenate",
						lex = []plat.Text_Span{{5, 3, LEX}, {30, 5, LEX}},
						link_in = []plat.Text_Span{{15, 5, LINK}},
						want = []plat.Text_Span{{5, 3, LEX}, {15, 5, LINK}, {30, 5, LEX}},
					},
				}
				for c in cases {
					merged := make([]plat.Text_Span, len(c.lex) + len(c.link_in), context.temp_allocator)
					mn := highlight_merge_spans(c.lex, c.link_in, merged)
					out := merged[:mn]
					ok := sorted_no_overlap(out) && spans_eq(out, c.want)
					if !ok {fail = true}
					fmt.printfln("  %-6s link precedence: %s", "ok" if ok else "FAIL", c.label)
				}
			}

			fmt.println("highlighttest: FAILURES" if fail else "highlighttest: all ok")
			return true
		}

		// `newtpad lexstatetest` is Task 3's own verification surface: the
		// background per-line index, the bounded backward resync, and the two
		// interactions the design doc calls out for a STATEFUL lexer specifically
		// (lex_xml) rather than the line-local ones highlighttest already covers.
		if os.args[1] == "lexstatetest" {
			fmt.println("lexstatetest:")
			fail := false
			g_theme = theme_light() // see highlighttest's identical comment on why

			t: plat.Text
			if !plat.text_load_faces(&t) {
				fmt.eprintln("lexstatetest: no fonts loaded")
				return true
			}

			// --- 1: state threads correctly across rows in the ordinary,
			// contiguous (non-filter) viewport -- the exact doc_draw shape, hand-
			// rolled the same way highlighttest's wrap-rebase check is, so this
			// exercises doc_row_lex_spans/doc_lex_state_at rather than a second
			// copy of what doc_draw does. `<!-- start` opens on row 1, `middle`
			// (row 2) is entirely inside it with NO markers of its own, and
			// `end --> <b/>` (row 3) closes it mid-row and then lexes a real tag
			// -- the one row that proves state, not just "always Comment" or
			// "always Normal", is actually being carried forward.
			{
				content := "<a>\n<!-- start\nmiddle\nend --> <b/>\n"
				wd: Document
				wd.pt = base.pt_init(transmute([]u8)content)
				defer base.pt_destroy(&wd.pt)
				wd.path = "test.xml"
				wd.view_cols = 200

				cache: Highlight_Row_Cache
				hl_state := doc_lex_state_at(&wd, 0, LEX_RESYNC_WINDOW)
				line_buf: [VISIBLE_COLS]u8
				row_comment := [4]bool{false, false, false, false} // does this row carry ANY Comment span?
				row_tag := [4]int{0, 0, 0, 0} // Xml_Tag span count per row
				row := 0
				it := visible_begin(&wd, &t, 4)
				for {
					_, start, end, vis_end, _, wrapped, ok := visible_next(&it)
					if !ok {break}
					draw_len := min(vis_end - start, len(line_buf))
					n := base.pt_read(&wd.pt, start, line_buf[:draw_len])
					if n <= 0 {continue}
					hl_buf: [HL_MAX_ROW_TOKENS]plat.Text_Span
					hn: int
					hn, hl_state = doc_row_lex_spans(&wd, &cache, start, end, wrapped, line_buf[:n], hl_state, hl_buf[:])
					for k in 0 ..< hn {
						if row < 4 {
							if hl_buf[k].color == g_theme[.Syn_Comment] {row_comment[row] = true}
							if hl_buf[k].color == g_theme[.Syn_Xml_Tag] {row_tag[row] += 1}
						}
					}
					row += 1
				}
				ok :=
					row == 4 &&
					!row_comment[0] && row_tag[0] == 2 && // "<a>"
					row_comment[1] && // "<!-- start" -- opens, unterminated
					row_comment[2] && // "middle" -- no markers, still inside
					row_comment[3] && row_tag[3] == 2 && // "end --> <b/>" -- closes, then a tag
					hl_state == .Normal // closed by the last row; nothing left open
				if !ok {fail = true}
				fmt.printfln(
					"  %-6s state threads across rows: comment=%v tags=%v final=%v",
					"ok" if ok else "FAIL",
					row_comment,
					row_tag,
					hl_state,
				)
			}

			// --- 2: the filter view. Three rows, deliberately listed OUT OF
			// ORDER (offset order would let a bug that quietly reuses the
			// contiguous running-state logic pass by accident) -- one before any
			// comment, one inside one, one after it closes. Each must resolve
			// its OWN state independently of the others; there is no "previous
			// row" to inherit from in filter mode (see doc_draw's comment on
			// hl_state).
			{
				content := strings.concatenate(
					{
						"before comment\n",
						"<!-- open\n",
						"still inside comment\n",
						"closes here -->\n",
						"after comment\n",
					},
					context.temp_allocator,
				)
				fdoc: Document
				fdoc.pt = base.pt_init(transmute([]u8)content)
				defer base.pt_destroy(&fdoc.pt)
				fdoc.path = "test.xml"

				before_at := 0
				inside_at := strings.index(content, "still inside comment")
				after_at := strings.index(content, "after comment")

				// Reordered: after, before, inside -- not ascending, not the
				// order they appear in the file.
				s_after := doc_lex_state_at(&fdoc, after_at, LEX_FILTER_RESYNC_WINDOW)
				s_before := doc_lex_state_at(&fdoc, before_at, LEX_FILTER_RESYNC_WINDOW)
				s_inside := doc_lex_state_at(&fdoc, inside_at, LEX_FILTER_RESYNC_WINDOW)

				ok := s_before == .Normal && s_inside == .In_Comment && s_after == .Normal
				if !ok {fail = true}
				fmt.printfln(
					"  %-6s filter view resolves rows independently: before=%v inside=%v after=%v",
					"ok" if ok else "FAIL",
					s_before,
					s_inside,
					s_after,
				)
			}

			// --- 3: the documented failure mode, AND its own sabotage. A
			// comment opened at byte 0 and never closed; `target` sits well past
			// LEX_RESYNC_WINDOW bytes of plain filler with no "-->" anywhere, so
			// a real-sized window must cap-hit and bail to .Normal -- the wrong
			// answer, but the DOCUMENTED one (see lex_resync_state's comment),
			// not a crash or a truncation. Widening the window past the target
			// (the sabotage: proving the bound, not the mechanism, is what
			// produces the wrong answer) must then find byte 0 and compute the
			// TRUE state, .In_Comment -- showing this assertion can fail, and
			// exactly what makes it fail.
			{
				sb := strings.builder_make(context.temp_allocator)
				strings.write_string(&sb, "<!-- unterminated comment\n")
				filler := strings.repeat("x", 78, context.temp_allocator)
				// Enough filler lines to push `target` past LEX_RESYNC_WINDOW
				// (64 KiB) with real margin, so this isn't a fixture that
				// happens to sit right at the boundary.
				for _ in 0 ..< 900 {
					strings.write_string(&sb, filler)
					strings.write_byte(&sb, '\n')
				}
				target := strings.builder_len(sb)
				strings.write_string(&sb, "TARGET\n")
				content := strings.to_string(sb)

				ld: Document
				ld.pt = base.pt_init(transmute([]u8)content)
				defer base.pt_destroy(&ld.pt)

				cap_ok := target > LEX_RESYNC_WINDOW
				state_bad, cap_hit_bad := lex_resync_state(&ld, target, LEX_RESYNC_WINDOW, base.lex_xml, "-->")
				// Sabotage the bound, not the mechanism: a window wide enough to
				// reach byte 0 (which is always unambiguously .Normal on its
				// own) recovers the true answer through the exact same code.
				state_good, cap_hit_good := lex_resync_state(&ld, target, target + 10, base.lex_xml, "-->")

				ok :=
					cap_ok &&
					cap_hit_bad &&
					state_bad == .Normal && // wrong, but the documented failure mode
					!cap_hit_good &&
					state_good == .In_Comment // true state, recovered once the bound doesn't starve it
				if !ok {fail = true}
				fmt.printfln(
					"  %-6s documented failure mode: target=%d window=%d bad=(cap=%v,%v) widened=(cap=%v,%v)",
					"ok" if ok else "FAIL",
					target,
					LEX_RESYNC_WINDOW,
					cap_hit_bad,
					state_bad,
					cap_hit_good,
					state_good,
				)
			}

			// --- 4: the real background index, end to end -- a real file on
			// disk, doc_open, lex_index_start, waited for completion -- cross-
			// checked against the resync mechanism (a generous window, standing
			// in for ground truth) at several offsets including one inside a
			// same-line-opened-and-closed comment's aftermath and one genuinely
			// spanning two lines. The two mechanisms must agree everywhere.
			{
				xml_content := strings.concatenate(
					{
						"<root>\n",
						"<!-- header comment\n",
						"spanning two lines -->\n",
						"<child attr=\"v\">text</child>\n",
						"<!-- trailing -->\n",
						"</root>\n",
					},
					context.temp_allocator,
				)
				tmpf := fmt.tprintf("%s%cnewtpad_lexidx_test.xml", os.get_env("TEMP", context.temp_allocator), '\\')
				if werr := os.write_entire_file(tmpf, transmute([]u8)xml_content); werr != nil {
					fmt.printfln("  FAIL   could not write fixture: %v", werr)
					fail = true
				} else {
					xd, xok := doc_open(tmpf)
					if !xok {
						fmt.println("  FAIL   could not open fixture")
						fail = true
					} else {
						lex_index_start(&xd)
						t0 := time.tick_now()
						for !lex_index_done(&xd) && time.duration_seconds(time.tick_since(t0)) < 5 {
							time.sleep(time.Millisecond)
						}
						indexed := lex_index_done(&xd)

						offsets := [5]int {
							0,
							strings.index(xml_content, "spanning two lines"),
							strings.index(xml_content, "<child"),
							strings.index(xml_content, "<!-- trailing -->"),
							strings.index(xml_content, "</root>"),
						}
						want := [5]base.Lex_State{.Normal, .In_Comment, .Normal, .Normal, .Normal}

						agree := indexed
						for off, i in offsets {
							via_index := doc_lex_state_at(&xd, off, LEX_RESYNC_WINDOW)
							via_resync, _ := lex_resync_state(&xd, off, off + 10, base.lex_xml, "-->")
							if via_index != want[i] || via_resync != want[i] || via_index != via_resync {
								agree = false
							}
						}
						if !agree {fail = true}
						fmt.printfln(
							"  %-6s background index matches resync ground truth (indexed=%v)",
							"ok" if agree else "FAIL",
							indexed,
						)
					}
					doc_close(&xd)
					os.remove(tmpf)
				}
			}

			// --- 5: three-way cross-check on a line LONGER THAN RENDER_LINE_CAP
			// (8192 bytes). Check 4 above cross-checks index against resync, but
			// its fixture's lines are ~30 bytes -- nowhere near long enough to
			// see the bug this review found: doc_draw's per-row DRAW buffer
			// (line_buf, VISIBLE_COLS = 2048 wide) used to ALSO be what fed the
			// lexer for an unwrapped row, so a `<!--` sitting past byte 2048 was
			// invisible to the state machine even though the background index
			// and the resync both correctly lex the whole (capped to
			// RENDER_LINE_CAP = 8192) row. All three must agree at the same
			// offset on a fixture that actually exercises the gap.
			//
			// The line must exceed RENDER_LINE_CAP, not just VISIBLE_COLS: any
			// line over WRAP_LONG_CELLS (1024 cells) force-wraps even with word
			// wrap off, UNLESS its own newline sits beyond WRAP_START_CAP
			// (== RENDER_LINE_CAP) bytes from its start -- see line_wrap_decision
			// (doc.odin). A 2500-byte line still force-wraps and never reaches
			// doc_row_lex_spans's !wrapped branch at all, which is exactly why
			// an earlier draft of this check passed even with the bug reinstated
			// (sabotage-verified: see the task's own report). Only a line over
			// 8192 bytes is genuinely capped/non-wrapped and split into
			// successive RENDER_LINE_CAP rows the way this bug needs.
			{
				marker_pos :: 5000 // > VISIBLE_COLS (2048), still inside row 0's own 8192-byte extent
				line1 := strings.concatenate(
					{
						strings.repeat("x", marker_pos, context.temp_allocator),
						"<!-- opens, never closes in line1 -- ",
						strings.repeat("y", 4000, context.temp_allocator), // pushes line1 past RENDER_LINE_CAP
					},
					context.temp_allocator,
				)
				xml_content := strings.concatenate(
					{line1, "\n", "still inside, no markers of its own\n", "closes here --> <b/>\n"},
					context.temp_allocator,
				)
				line2_start := len(line1) + 1

				tmpf := fmt.tprintf("%s%cnewtpad_lexidx_long_test.xml", os.get_env("TEMP", context.temp_allocator), '\\')
				if werr := os.write_entire_file(tmpf, transmute([]u8)xml_content); werr != nil {
					fmt.printfln("  FAIL   could not write long-line fixture: %v", werr)
					fail = true
				} else {
					xd, xok := doc_open(tmpf)
					if !xok {
						fmt.println("  FAIL   could not open long-line fixture")
						fail = true
					} else {
						line_len_ok := len(line1) > RENDER_LINE_CAP

						lex_index_start(&xd)
						t0 := time.tick_now()
						for !lex_index_done(&xd) && time.duration_seconds(time.tick_since(t0)) < 5 {
							time.sleep(time.Millisecond)
						}

						via_index := doc_lex_state_at(&xd, line2_start, LEX_RESYNC_WINDOW)
						via_resync, _ := lex_resync_state(&xd, line2_start, LEX_RESYNC_WINDOW, base.lex_xml, "-->")

						// The doc_draw shape itself, hand-rolled the same way
						// check 1 above is: bootstrap once at row 0, then thread
						// hl_state row to row through doc_row_lex_spans exactly
						// like doc_draw's own loop. line1 alone spans TWO capped
						// rows here (row 0 = [0,8192), row 1 = [8192,len(line1))
						// -- both non-wrapped continuations of the same logical
						// line). via_draw is the state after row 0 -- the value
						// that used to come back .Normal (wrong) because the
						// lexer never saw past byte 2048 of that row, so it never
						// even noticed the comment opened.
						via_draw := base.Lex_State.Normal
						t: plat.Text
						if !plat.text_load_faces(&t) {
							fmt.eprintln("  FAIL   no fonts loaded for draw-path check")
							fail = true
						} else {
							cache: Highlight_Row_Cache
							line_buf: [VISIBLE_COLS]u8
							hl_state := doc_lex_state_at(&xd, 0, LEX_RESYNC_WINDOW)
							it := visible_begin(&xd, &t, 5)
							row := 0
							for {
								_, start, end, vis_end, _, wrapped, ok := visible_next(&it)
								if !ok {break}
								draw_len := min(vis_end - start, len(line_buf))
								n := base.pt_read(&xd.pt, start, line_buf[:draw_len])
								if n > 0 {
									hl_buf: [HL_MAX_ROW_TOKENS]plat.Text_Span
									_, hl_state = doc_row_lex_spans(&xd, &cache, start, end, wrapped, line_buf[:n], hl_state, hl_buf[:])
								}
								if row == 0 {via_draw = hl_state}
								row += 1
							}
						}

						agree :=
							line_len_ok &&
							via_index == .In_Comment &&
							via_resync == .In_Comment &&
							via_draw == .In_Comment
						if !agree {fail = true}
						fmt.printfln(
							"  %-6s three-way agreement past RENDER_LINE_CAP: index=%v resync=%v drawpath=%v (line1=%d bytes)",
							"ok" if agree else "FAIL",
							via_index,
							via_resync,
							via_draw,
							len(line1),
						)

						doc_close(&xd)
					}
					os.remove(tmpf)
				}

				// --- 5b: the bootstrap fix itself (doc_draw's hl_state, see its
				// comment), isolated from the rest of the pipeline. A fresh
				// in-memory Document over the SAME content -- deliberately never
				// given to lex_index_start, so doc_lex_state_at always takes the
				// resync path (an indexed small file can't be used for this one:
				// the background index only records state before each raw
				// newline-delimited line, so a synthetic mid-line offset like
				// 8192 below isn't one of its recorded points -- a real, narrower
				// limitation of the index noted in lex_index.odin, not what this
				// check is after).
				//
				// Simulates a viewport scrolled so its TOP row is offset 8192 --
				// exactly one RENDER_LINE_CAP into line1, a synthetic
				// continuation of the same still-open comment, not a real
				// logical line start. This row is non-wrapped (same reasoning as
				// row 0/1 above).
				//
				// OLD bootstrap: find lls = pt_line_start_cap(pt, 8192,
				// WRAP_START_CAP=8192), then resolve state THERE. That happens to
				// compute lls=0 exactly (8192-8192=0) -- the TRUE start of line1
				// -- so old_state is the state at byte 0 (.Normal, trivially,
				// nothing precedes it) treated as if it were the state at byte
				// 8192, silently skipping the 8192 bytes in between that contain
				// the comment-open marker at byte 5000. NEW bootstrap: resolve
				// state directly AT 8192, which lex_resync_state's target-
				// relative forward walk (see its comment) answers correctly.
				{
					bd: Document
					bd.pt = base.pt_init(transmute([]u8)xml_content)
					defer base.pt_destroy(&bd.pt)
					bd.path = "test.xml"

					old_lls, _ := base.pt_line_start_cap(&bd.pt, 8192, WRAP_START_CAP)
					old_state := doc_lex_state_at(&bd, old_lls, LEX_RESYNC_WINDOW)
					new_state := doc_lex_state_at(&bd, 8192, LEX_RESYNC_WINDOW)
					bootstrap_ok := old_lls == 0 && old_state == .Normal && new_state == .In_Comment
					if !bootstrap_ok {fail = true}
					fmt.printfln(
						"  %-6s bootstrap resolves state AT the row, not at an earlier guess: old(lls=%d)=%v new=%v",
						"ok" if bootstrap_ok else "FAIL",
						old_lls,
						old_state,
						new_state,
					)
				}
			}

			// --- 6: hl_resync_bytes_examined (lex_index.odin) proves
			// lex_resync_state's OWN cost is bounded by `window`, not by document
			// size. hl_bytes_examined (highlight.odin) can't answer this: it is
			// only ever incremented inside highlight_row_spans, and
			// lex_resync_state calls the lexer directly, never through
			// highlight_row_spans -- doc_draw's bootstrap and the filter view
			// both call it straight. Without a counter ON that path, extending
			// highlighttest's viewport-proportional assertion to a stateful
			// lexer would have passed even if the resync scanned the entire
			// file, because the assertion would be watching a path this code
			// never runs through.
			{
				build_resync_doc :: proc(prefix_lines: int) -> (doc: Document, target: int) {
					sb := strings.builder_make(context.temp_allocator)
					for _ in 0 ..< prefix_lines {
						strings.write_string(&sb, "plain filler line, no markers at all here\n")
					}
					strings.write_string(&sb, "<!-- closed comment --> \n")
					strings.write_string(&sb, strings.repeat("z", 500, context.temp_allocator))
					strings.write_byte(&sb, '\n')
					target = strings.builder_len(sb)
					strings.write_string(&sb, "TARGET LINE\n")
					doc.pt = base.pt_init(transmute([]u8)strings.to_string(sb))
					return
				}

				// Identical tail (the comment-close anchor, the 500-byte filler
				// line, `target`) on all three fixtures -- only the amount of
				// filler BEFORE that tail differs, and the resync never looks at
				// bytes before `target - window`.
				//
				// This check used to assert small_bytes == big_bytes, and it
				// passed -- while `big` really did read a saturated 64 KiB window
				// out of the piece table and `small` a few hundred bytes. The
				// counter simply could not see the backward anchor scan (see
				// hl_resync_bytes_examined, lex_index.odin): the test named after
				// window-bounded cost was measuring only the forward walk, whose
				// input is the identical tail on both fixtures, so equality was
				// guaranteed by the fixture rather than earned by the code.
				//
				// With the scan counted, the honest claim is what lex_resync_state
				// actually promises: every call is bounded by its three terms
				// (2*window + the validation budget) regardless of document size,
				// and past the point where the window saturates, cost stops
				// growing entirely -- which is what `bigger`, twice `big`'s size
				// for the same answer and the same byte count, pins down. `small`
				// must now come in BELOW `big`, not equal to it: it has less
				// document behind `target` than the window would allow.
				small_doc, small_target := build_resync_doc(5)
				big_doc, big_target := build_resync_doc(200000)
				bigger_doc, bigger_target := build_resync_doc(400000)
				defer base.pt_destroy(&small_doc.pt)
				defer base.pt_destroy(&big_doc.pt)
				defer base.pt_destroy(&bigger_doc.pt)

				hl_resync_bytes_examined = 0
				small_state, small_cap := lex_resync_state(&small_doc, small_target, LEX_RESYNC_WINDOW, base.lex_xml, "-->")
				small_bytes := hl_resync_bytes_examined

				hl_resync_bytes_examined = 0
				big_state, big_cap := lex_resync_state(&big_doc, big_target, LEX_RESYNC_WINDOW, base.lex_xml, "-->")
				big_bytes := hl_resync_bytes_examined

				hl_resync_bytes_examined = 0
				bigger_state, bigger_cap := lex_resync_state(&bigger_doc, bigger_target, LEX_RESYNC_WINDOW, base.lex_xml, "-->")
				bigger_bytes := hl_resync_bytes_examined

				// The worst case lex_resync_state's own header comment states:
				// window (anchor scan) + validation budget + window (forward lex).
				bound := 2 * LEX_RESYNC_WINDOW + LEX_RESYNC_MAX_VALIDATE_BYTES
				ok :=
					!small_cap &&
					!big_cap &&
					!bigger_cap &&
					small_state == .Normal &&
					big_state == .Normal &&
					bigger_state == .Normal &&
					small_bytes > 0 &&
					small_bytes <= bound &&
					big_bytes <= bound &&
					small_bytes < big_bytes && // the scan the counter used to miss
					big_bytes == bigger_bytes // saturated: 2x the file, same cost
				if !ok {fail = true}
				fmt.printfln(
					"  %-6s resync cost is window-bounded, not file-bounded: small=%d big=%d bigger=%d (want big==bigger, small<big, all <=%d)",
					"ok" if ok else "FAIL",
					small_bytes,
					big_bytes,
					bigger_bytes,
					bound,
				)
			}

			// --- 7: Task 4's own anchor-soundness proof, end to end through the
			// REAL ".c" registration (highlight_lexer_for), not just the base-
			// layer unit tests in lex_c_test.odin. Exactly the task brief's own
			// example, `char *s = "*/";`, in genuinely ordinary code -- followed,
			// on the SAME line, by a real `/*` that never closes. The decoy's
			// "*/" is the only occurrence of those two bytes anywhere in the
			// content, so it is also the textual LAST occurrence in the window.
			//
			// WITHOUT a validator (validate omitted -> nil, simulating this
			// task's starting point): lex_resync_state trusts that lone "*/"
			// unconditionally and resumes forward lexing from ONE BYTE INSIDE the
			// string (before its closing quote), assuming .Normal there. That
			// makes the resumed scan see a bogus, unterminated string starting at
			// the real closing quote -- which swallows the rest of the line,
			// INCLUDING the real "/*" opener, as inert string content. The real
			// comment is never even noticed: silently, confidently .Normal,
			// cap_hit FALSE.
			//
			// WITH the real validator (lex_c_c_valid, wired through EXT_LEXERS):
			// the decoy candidate is rejected (it sits inside a String token when
			// the line is re-lexed from a fresh .Normal), no other "*/" exists in
			// the window, and the walk falls through to byte 0 (unambiguously
			// .Normal on its own) and forward-lexes the WHOLE line properly from
			// there -- closing the decoy string correctly, THEN finding the real,
			// genuinely unclosed "/*" right after it. .In_Comment, correctly.
			{
				content := strings.concatenate(
					{`char *s = "*/"; /* real comment opens here and never closes` + "\n", "TARGET\n"},
					context.temp_allocator,
				)
				cd: Document
				cd.pt = base.pt_init(transmute([]u8)content)
				defer base.pt_destroy(&cd.pt)
				cd.path = "test.c"

				target := strings.index(content, "TARGET")
				lexer, stateful, anchor, validate := highlight_lexer_for(cd.path)

				naive_state, naive_cap := lex_resync_state(&cd, target, LEX_RESYNC_WINDOW, lexer, anchor)
				fixed_state, fixed_cap := lex_resync_state(&cd, target, LEX_RESYNC_WINDOW, lexer, anchor, validate)

				ok :=
					stateful &&
					anchor == "*/" &&
					validate != nil &&
					!naive_cap &&
					naive_state == .Normal && // confidently wrong: the decoy fooled it
					!fixed_cap &&
					fixed_state == .In_Comment // correct: the validator rejected the decoy
				if !ok {fail = true}
				fmt.printfln(
					"  %-6s C-family resync anchor soundness: naive=(cap=%v,%v) validated=(cap=%v,%v)",
					"ok" if ok else "FAIL",
					naive_cap,
					naive_state,
					fixed_cap,
					fixed_state,
				)
			}

			// --- 8: IMPORTANT 4 -- a resync candidate whose own physical line
			// start lies more than RENDER_LINE_CAP bytes behind it must be
			// SKIPPED, not validated against whatever pt_line_start_cap/
			// pt_line_end_cap happen to read when the true line start is
			// unreachable. lex_resync_state used to discard pt_line_start_cap's
			// own `exact` flag (`ls, _ :=`), so a front-truncated read got
			// handed to the validator as if it were the real line -- and once
			// the candidate sits far enough into the line, the read buffer
			// doesn't even reach the candidate at all, which made
			// lex_c_resync_valid return true UNCONDITIONALLY (see that proc's
			// own comment). Fixture: RENDER_LINE_CAP+500 bytes of filler with NO
			// newline at all, then the exact same decoy check 7 uses (a string
			// literal containing "*/") immediately followed by a real,
			// never-closed block comment opener -- all still on the SAME
			// physical line (it doesn't end until after "never closes"). The
			// decoy sits far enough into that line that
			// pt_line_start_cap(candidate, RENDER_LINE_CAP) cannot reach the
			// true start (offset 0) and reports exact=false.
			{
				filler := strings.repeat("z", RENDER_LINE_CAP + 500, context.temp_allocator)
				content := strings.concatenate(
					{filler, `char *s = "*/"; /* real comment opens here and never closes` + "\n", "TARGET\n"},
					context.temp_allocator,
				)
				td: Document
				td.pt = base.pt_init(transmute([]u8)content)
				defer base.pt_destroy(&td.pt)
				td.path = "test.c"

				target := strings.index(content, "TARGET")
				lexer, _, anchor, validate := highlight_lexer_for(td.path)

				// Window wide enough to reach byte 0 -- the point here isn't the
				// window bound (checks 3/6 already cover that), it's whether the
				// front-truncated candidate gets skipped in favour of falling
				// all the way back to byte 0, which correctly forward-lexes the
				// WHOLE line and finds the real, never-closed "/*" this time.
				state, cap_hit := lex_resync_state(&td, target, target, lexer, anchor, validate)

				ok := !cap_hit && state == .In_Comment
				if !ok {fail = true}
				fmt.printfln(
					"  %-6s front-truncated candidate (exact=false) is skipped, not validated: cap=%v state=%v",
					"ok" if ok else "FAIL",
					cap_hit,
					state,
				)
			}

			// --- 9: IMPORTANT 5 -- the candidate-validation loop's OWN cost is
			// now counted into hl_resync_bytes_examined and independently
			// byte-capped (LEX_RESYNC_MAX_VALIDATE_BYTES), not just
			// candidate-COUNT-capped (LEX_RESYNC_MAX_CANDIDATES). Before this
			// fix, NOTHING incremented hl_resync_bytes_examined for this loop at
			// all -- check 6 above proves the FORWARD walk is window-bounded,
			// but it calls lex_xml with validate == nil, which never touches the
			// candidate loop at all, so it could never have caught this. This
			// fixture is the C-family validated path with far more decoy
			// candidates in the window (300) than the byte budget can afford to
			// read (~131 at ~500 bytes each), so the loop must bail out early --
			// and, since none of the 300 decoys are genuine (each "*/" sits
			// inside a string), the walk correctly falls through to byte 0 and
			// recovers the TRUE answer (a real comment opened on line 1 never
			// closes) despite never having validated most of the candidates.
			{
				build_decoy_doc :: proc(num_decoys: int) -> (doc: Document, target: int, decoy_line_len: int) {
					decoy_line := strings.concatenate(
						{strings.repeat("z", 480, context.temp_allocator), ` = "decoy */ x";` + "\n"},
						context.temp_allocator,
					)
					decoy_line_len = len(decoy_line)
					sb := strings.builder_make(context.temp_allocator)
					strings.write_string(&sb, "/* a real comment that never closes\n")
					for _ in 0 ..< num_decoys {
						strings.write_string(&sb, decoy_line)
					}
					target = strings.builder_len(sb)
					strings.write_string(&sb, "TARGET\n")
					doc.pt = base.pt_init(transmute([]u8)strings.to_string(sb))
					return
				}

				num_decoys :: 300
				dd, target, decoy_line_len := build_decoy_doc(num_decoys)
				defer base.pt_destroy(&dd.pt)
				dd.path = "test.c"
				lexer, _, anchor, validate := highlight_lexer_for(dd.path)

				hl_resync_bytes_examined = 0
				// window = target-1: win_start ends up at 1 (> 0), so if the
				// candidate loop never validates anything, lex_resync_state
				// returns the cap-hit fallback IMMEDIATELY, before ever
				// reaching the forward-lex loop below it -- isolating
				// hl_resync_bytes_examined to JUST the candidate-validation
				// loop's own cost, not conflated with a second contributor. Not
				// quite the whole document, so nearly all 300 decoys are
				// textually visible as candidates -- far more than the ~131 the
				// byte budget can afford to read at ~500 bytes each.
				window := target - 1
				state, cap_hit := lex_resync_state(&dd, target, window, lexer, anchor, validate)
				// hl_resync_bytes_examined now counts the backward anchor scan's
				// own read as well, and this fixture's window is deliberately
				// nearly the whole document, so that term dominates: win_start
				// lands at 1 and the scan runs from there to `target`, exactly
				// `window` bytes. Subtract it to isolate the candidate loop, which
				// is what this check is about -- the two terms are added by
				// different code and only one of them is what
				// LEX_RESYNC_MAX_VALIDATE_BYTES bounds.
				validated_bytes := hl_resync_bytes_examined - window
				total_decoy_bytes := num_decoys * decoy_line_len

				ok :=
					cap_hit &&
					state == .Normal && // the documented cap-hit fallback -- every decoy correctly rejected, none validated
					validated_bytes > 0 && // was ALWAYS 0 before this fix -- the counter never saw this loop
					validated_bytes <= LEX_RESYNC_MAX_VALIDATE_BYTES + RENDER_LINE_CAP && // budget + one line's overshoot slack
					validated_bytes < total_decoy_bytes / 2 // proves the loop bailed EARLY, not after reading close to all 300 decoys
				if !ok {fail = true}
				fmt.printfln(
					"  %-6s candidate-validation cost is counted and byte-capped: validated=%d/%d cap=%v state=%v (budget=%d, scan=%d)",
					"ok" if ok else "FAIL",
					validated_bytes,
					total_decoy_bytes,
					cap_hit,
					state,
					LEX_RESYNC_MAX_VALIDATE_BYTES,
					window,
				)
			}

			fmt.println("lexstatetest: FAILURES" if fail else "lexstatetest: all ok")
			return true
		}

		// `newtpad lexcoveragetest` is Task 5's Step 4: assert over the ACTUAL
		// text_exts.txt (via text_exts_list(), links.odin — the same embedded
		// copy the app itself uses, not a hand-typed duplicate that could drift)
		// that every extension resolves to either a real lexer or an entry in
		// DELIBERATELY_PLAIN_EXTS (highlight.odin). This is the check that
		// outlives this task: adding a 35th extension to text_exts.txt without
		// giving it a lexer OR adding it to the plain list fails HERE, on the
		// next run of this mode, rather than being noticed by Wyatt on screen
		// months later. It is also what caught .py — already present in
		// text_exts.txt, matching the design doc's own "34 extensions" count,
		// but never assigned a lexer by any of this batch's four tasks — before
		// this task shipped, not after.
		if os.args[1] == "lexcoveragetest" {
			fmt.println("lexcoveragetest:")
			fail := false
			seen := 0
			// Reads the SAME text_exts.txt links.odin embeds (one source of
			// truth, per that file's own comment) rather than importing
			// text_exts_list itself, which is file-private to links.odin —
			// this is a second reader of the same underlying data, not a second
			// hand-maintained copy of it.
			raw := #load("../../text_exts.txt", string)
			for ln in strings.split_lines_iterator(&raw) {
				ext := strings.trim_space(ln)
				if len(ext) == 0 {continue}
				seen += 1
				lexer, _, _, _ := highlight_lexer_for(ext) // ext already starts with '.', a valid "path" for the extension-matching logic
				has_lexer := lexer != nil
				is_plain := false
				for p in DELIBERATELY_PLAIN_EXTS {
					if strings.equal_fold(p, ext) {
						is_plain = true
						break
					}
				}
				ok := has_lexer != is_plain // exactly one of the two must hold
				if !ok {fail = true}
				status := "lexer" if has_lexer else ("plain" if is_plain else "NEITHER")
				fmt.printfln("  %-6s %-12s -> %s", "ok" if ok else "FAIL", ext, status)
			}
			// The other EXT_LEXERS invariant: a stateful entry with no
			// resync_anchor bails to .Normal silently on every huge/mapped file of
			// that extension. The app checks this at startup (diag_init ->
			// highlight_check_ext_tables) where the only outcome available is a
			// logged line and a panic; here it is an ordinary assertion, which is
			// where a table edit should be caught.
			anchors_ok, offender := highlight_ext_tables_ok()
			if !anchors_ok {fail = true}
			fmt.printfln(
				"  %-6s every stateful EXT_LEXERS entry registers a resync_anchor%s",
				"ok" if anchors_ok else "FAIL",
				"" if anchors_ok else fmt.tprintf(" (%s does not)", offender),
			)
			fmt.printfln("  examined %d extensions from text_exts.txt", seen)
			fmt.println("lexcoveragetest: FAILURES" if fail else "lexcoveragetest: all ok")
			return true
		}

		// `newtpad keymaptest` — the keys.txt user overlay (keymap.odin).
		//
		// Every case asserts through resolve_key, not through the returned Keymap.
		// A test that only counted parse results would prove that the parser
		// parsed, which is not the claim: the claim is that a chord in the file
		// changes what a key press DOES, and that nothing in the file can take
		// away the way out. The reject counters are checked as well, but always
		// alongside the resolve_key answer — "the line was ignored" and "the line
		// was ignored for the right reason" are different assertions, and the
		// shift case only means anything if both hold.
		//
		// Writes keys.txt in the session dir for the load-from-disk case, hence
		// the scratch guard.
		if os.args[1] == "keymaptest" {
			if !require_scratch_session("keymaptest") {return true}
			// Its own proc: test_mode_dispatch's frame is already large (§6,
			// STATUS_STACK_OVERFLOW twice).
			keymaptest :: proc() -> int {
				bad := 0
				chk :: proc(bad: ^int, cond: bool, msg: string) {
					fmt.printfln("  %-4s %s", "OK" if cond else "FAIL", msg)
					if !cond {bad^ += 1}
				}
				// Parse + install, so the following resolve_key calls run against
				// the live overlay exactly as the app's would.
				load :: proc(src: string) -> Keymap {
					km := keymap_parse(src)
					keymap_install(km) // takes ownership of km.entries
					return km
				}
				defer keymap_reset()

				// --- a good file -------------------------------------------------
				// Two chords the defaults leave alone, so a pass here cannot be a
				// default answering by accident.
				fmt.println("--- a good file ---")
				k := load("# a comment\n\nctrl+k = Move_Line_Up\nalt+down = Undo\n")
				chk(&bad, len(k.entries) == 2 && keymap_reject_total(k) == 0, fmt.tprintf("2 bindings, 0 refusals (got %d / %d)", len(k.entries), keymap_reject_total(k)))
				chk(&bad, resolve_key(.K, true, false, .Editor) == .Move_Line_Up, fmt.tprintf("ctrl+k -> %v (want Move_Line_Up)", resolve_key(.K, true, false, .Editor)))
				chk(&bad, resolve_key(.Down, false, true, .Editor) == .Undo, fmt.tprintf("alt+down -> %v (want Undo, default was Move_Line_Down)", resolve_key(.Down, false, true, .Editor)))
				// Case and whitespace are not part of the format.
				load("   CTRL+K   =   move_line_up   \n")
				chk(&bad, resolve_key(.K, true, false, .Editor) == .Move_Line_Up, "case and padding are ignored")

				// --- an unknown command name is ignored ---------------------------
				fmt.println("--- unknown command name ---")
				k = load("ctrl+k = Frobnicate\n")
				chk(&bad, k.rejects[.Unknown_Command] == 1 && len(k.entries) == 0, fmt.tprintf("refused as Unknown_Command (%d), no binding made (%d)", k.rejects[.Unknown_Command], len(k.entries)))
				chk(&bad, resolve_key(.K, true, false, .Editor) == .None, fmt.tprintf("ctrl+k -> %v (want None)", resolve_key(.K, true, false, .Editor)))

				// --- malformed chords / garbage lines ------------------------------
				fmt.println("--- malformed lines ---")
				k = load("ctrl+nope = Undo\nthis line has no equals sign\n = Undo\nctrl+ = Undo\n")
				chk(&bad, k.rejects[.Unknown_Key] == 1, fmt.tprintf("1 unknown-key refusal (got %d)  [`ctrl+nope`]", k.rejects[.Unknown_Key]))
				chk(&bad, k.rejects[.Malformed] == 3, fmt.tprintf("3 malformed refusals (got %d)  [no '=', an empty chord, and `ctrl+` -- modifiers with no key]", k.rejects[.Malformed]))
				chk(&bad, len(k.entries) == 0, fmt.tprintf("nothing bound (%d entries)", len(k.entries)))
				// A chord that is nothing but modifiers is diagnosed as having no
				// key, whichever modifiers they are -- including shift, where the
				// missing key is the more basic fault. All three were Unknown_Key
				// before, which named the wrong problem: the reject reasons exist so
				// the warning can tell the user what to change.
				k = load("ctrl+ = Undo\nalt+ = Undo\nshift+ = Undo\n")
				chk(&bad, k.rejects[.Malformed] == 3 && k.rejects[.Unknown_Key] == 0 && k.rejects[.Shift] == 0, fmt.tprintf("modifiers with no key: malformed=%d unknown-key=%d shift=%d (want 3/0/0)", k.rejects[.Malformed], k.rejects[.Unknown_Key], k.rejects[.Shift]))
				chk(&bad, len(k.entries) == 0, fmt.tprintf("nothing bound (%d entries)", len(k.entries)))
				// Spaces around the '+' are tolerated, so a spaced-out chord gets
				// the diagnosis its compact spelling would get.
				k = load("ctrl + shift + k = Undo\n")
				chk(&bad, k.rejects[.Shift] == 1 && k.rejects[.Unknown_Key] == 0, fmt.tprintf("`ctrl + shift + k` is refused for naming shift, not for the key (shift=%d key=%d)", k.rejects[.Shift], k.rejects[.Unknown_Key]))
				k = load("ctrl + t = Undo\nctrl + + = Redo\n")
				chk(&bad, len(k.entries) == 2 && keymap_reject_total(k) == 0, fmt.tprintf("a spaced chord binds like the compact one (%d entries, %d refusals)", len(k.entries), keymap_reject_total(k)))
				chk(&bad, resolve_key(.T, true, false, .Editor) == .Undo, fmt.tprintf("`ctrl + t` -> %v (want Undo)", resolve_key(.T, true, false, .Editor)))
				chk(&bad, resolve_key(.Plus, true, false, .Editor) == .Redo, fmt.tprintf("...including when the key IS '+': `ctrl + +` -> %v (want Redo; the default is Zoom_In)", resolve_key(.Plus, true, false, .Editor)))

				// --- shift is not part of a chord -----------------------------------
				// The load-bearing one. commands.odin:252-254 and :294 both say a
				// Binding is (key, ctrl, alt, ctx); dropping the shift and binding
				// ctrl+k would give the user a chord they never asked for on a key
				// they are still using for something else.
				fmt.println("--- a shift+ chord is refused, not silently downgraded ---")
				k = load("ctrl+shift+k = Undo\nshift+f5 = Undo\n")
				chk(&bad, k.rejects[.Shift] == 2, fmt.tprintf("2 shift refusals (got %d)", k.rejects[.Shift]))
				chk(&bad, len(k.entries) == 0, fmt.tprintf("no binding made (%d entries)", len(k.entries)))
				chk(&bad, resolve_key(.K, true, false, .Editor) == .None, fmt.tprintf("ctrl+k is NOT bound behind the user's back -> %v (want None)", resolve_key(.K, true, false, .Editor)))
				// And shift wins the diagnosis even when the key is also bad, so the
				// warning names the real problem.
				k = load("ctrl+shift+nope = Undo\n")
				chk(&bad, k.rejects[.Shift] == 1 && k.rejects[.Unknown_Key] == 0, fmt.tprintf("shift is diagnosed before the key name (shift=%d key=%d)", k.rejects[.Shift], k.rejects[.Unknown_Key]))

				// --- an empty command unbinds a default -----------------------------
				fmt.println("--- an empty command unbinds ---")
				k = load("ctrl+z =\n")
				chk(&bad, len(k.entries) == 1 && k.entries[0].cmd == .None, fmt.tprintf("recorded as an entry, not a refusal (%d entries, cmd=%v)", len(k.entries), k.entries[0].cmd if len(k.entries) == 1 else Command_Id.None))
				chk(&bad, resolve_key(.Z, true, false, .Editor) == .None, fmt.tprintf("ctrl+z -> %v (want None; the default is Undo)", resolve_key(.Z, true, false, .Editor)))
				chk(&bad, resolve_key(.Y, true, false, .Editor) == .Redo, "unbinding one chord leaves the rest of the defaults alone (ctrl+y still Redo)")

				// --- duplicates: last wins ------------------------------------------
				fmt.println("--- a duplicate chord: last wins ---")
				k = load("ctrl+k = Undo\nctrl+k = Redo\nctrl+k = Save_As\n")
				chk(&bad, len(k.entries) == 3, fmt.tprintf("all three lines kept (%d)", len(k.entries)))
				chk(&bad, resolve_key(.K, true, false, .Editor) == .Save_As, fmt.tprintf("ctrl+k -> %v (want Save_As, the LAST line)", resolve_key(.K, true, false, .Editor)))
				// A later unbind must beat an earlier bind, too.
				load("ctrl+k = Undo\nctrl+k =\n")
				chk(&bad, resolve_key(.K, true, false, .Editor) == .None, fmt.tprintf("a later unbind beats an earlier bind -> %v (want None)", resolve_key(.K, true, false, .Editor)))

				// --- an overlay entry beats a default --------------------------------
				fmt.println("--- the overlay beats the defaults ---")
				load("ctrl+t = Undo\n")
				chk(&bad, resolve_key(.T, true, false, .Editor) == .Undo, fmt.tprintf("ctrl+t -> %v (want Undo; the default is Toggle_Table)", resolve_key(.T, true, false, .Editor)))
				// What the menus TEACH turns on add-vs-replace, not on which half
				// of the keymap the row came from. This line ADDS a chord: Ctrl+Z
				// still runs Undo, so un-teaching it would take away a shortcut the
				// user knows and never asked to lose.
				chk(&bad, command_chord(.Undo) == "Ctrl+Z", fmt.tprintf("an ADDED chord does not un-teach the working default: command_chord(Undo)=%q (want \"Ctrl+Z\")", command_chord(.Undo)))
				chk(&bad, command_chord(.Toggle_Table) == "", fmt.tprintf("...and the command whose chord was TAKEN teaches nothing: command_chord(Toggle_Table)=%q (want \"\")", command_chord(.Toggle_Table)))
				// Replace, both ways of spelling it, and the menus follow the user.
				load("ctrl+z =\nctrl+t = Undo\n")
				chk(&bad, command_chord(.Undo) == "Ctrl+T", fmt.tprintf("unbinding the default makes the menus teach the new chord: %q (want \"Ctrl+T\")", command_chord(.Undo)))
				load("ctrl+z = Redo\nctrl+t = Undo\n")
				chk(&bad, command_chord(.Undo) == "Ctrl+T", fmt.tprintf("giving the default away does too: %q (want \"Ctrl+T\")", command_chord(.Undo)))
				// A command with no default chord at all -- the overlay is its only
				// possible answer, which is why the seed lists these by name.
				load("ctrl+alt+o = Open_Link\n")
				chk(&bad, command_chord(.Open_Link) == "Ctrl+Alt+O", fmt.tprintf("a command with no default teaches its overlay chord: %q (want \"Ctrl+Alt+O\")", command_chord(.Open_Link)))
				// An overlay row a LATER line overrode must not be taught either:
				// Ctrl+K runs Redo here, so teaching it for Undo would be exactly
				// the drift this proc exists to stop. Ctrl+Z is unbound first so
				// that the default cannot answer and the overlay's own guard is
				// what is under test.
				k = load("ctrl+z =\nctrl+k = Undo\nctrl+k = Redo\n")
				chk(&bad, resolve_key(.K, true, false, .Editor) == .Redo, fmt.tprintf("ctrl+k -> %v (want Redo, the last line)", resolve_key(.K, true, false, .Editor)))
				chk(&bad, command_chord(.Undo) == "", fmt.tprintf("a superseded overlay row is not taught: command_chord(Undo)=%q (want \"\"; Ctrl+K runs Redo)", command_chord(.Undo)))
				// The invariant that makes every guard above a provable no-op on a
				// machine with no keys.txt: with an empty overlay resolve_key is the
				// plain default lookup, so a default row can only fail its own guard
				// if some OTHER default row shadows the same chord.
				dup_pairs := 0
				for a, i in default_bindings {
					for b, j in default_bindings {
						if j <= i {continue}
						if a.key == b.key && a.ctrl == b.ctrl && a.alt == b.alt && a.ctx == b.ctx {dup_pairs += 1}
					}
				}
				chk(&bad, dup_pairs == 0, fmt.tprintf("no two default_bindings rows share a chord (%d duplicate pair(s) in %d rows)", dup_pairs, len(default_bindings)))

				// --- reserved chords are refused --------------------------------------
				// The escape hatch, so a bad file cannot be a one-way door: cancel,
				// save, and the palette (which can run every command, including
				// View > Edit Keybindings...).
				fmt.println("--- reserved chords ---")
				k = load("esc = Undo\nctrl+s = Undo\nctrl+p = Undo\nctrl+s =\n")
				chk(&bad, k.rejects[.Reserved] == 4, fmt.tprintf("4 reserved refusals -- rebinds AND the unbind (got %d)", k.rejects[.Reserved]))
				chk(&bad, len(k.entries) == 0, fmt.tprintf("nothing bound (%d entries)", len(k.entries)))
				chk(&bad, resolve_key(.Escape, false, false, .Editor) == .Clear_Selection, fmt.tprintf("Esc still cancels -> %v", resolve_key(.Escape, false, false, .Editor)))
				chk(&bad, resolve_key(.S, true, false, .Editor) == .Save, fmt.tprintf("Ctrl+S still saves -> %v", resolve_key(.S, true, false, .Editor)))
				chk(&bad, resolve_key(.P, true, false, .Editor) == .Palette_Open, fmt.tprintf("Ctrl+P still opens the palette -> %v", resolve_key(.P, true, false, .Editor)))
				// Ctrl+Alt+S is Save_As and is NOT reserved -- the reservation is on
				// the exact chord, not on the key.
				k = load("ctrl+alt+s = Undo\n")
				chk(&bad, k.rejects[.Reserved] == 0 && resolve_key(.S, true, true, .Editor) == .Undo, fmt.tprintf("ctrl+alt+s is a different chord and is bindable -> %v", resolve_key(.S, true, true, .Editor)))
				chk(&bad, resolve_key(.S, true, false, .Editor) == .Save, "...and Ctrl+S is untouched by it")

				// --- an unmodified printable key is refused -----------------------------
				// WM_CHAR is drained separately from the key events (main.odin), so
				// `k = Exit` would type a k AND quit, every time.
				fmt.println("--- unmodified printable keys ---")
				k = load("k = Undo\n5 = Undo\n- = Undo\n")
				chk(&bad, k.rejects[.Unmodified] == 3, fmt.tprintf("3 refusals -- letter, digit, minus (got %d)", k.rejects[.Unmodified]))
				chk(&bad, resolve_key(.K, false, false, .Editor) == .None, fmt.tprintf("bare k -> %v (want None)", resolve_key(.K, false, false, .Editor)))
				// Keys that never reach WM_CHAR (r >= 32 filter) stay bindable bare.
				k = load("pgdn = Undo\ndel = Redo\n")
				chk(&bad, k.rejects[.Unmodified] == 0 && resolve_key(.Page_Down, false, false, .Editor) == .Undo, fmt.tprintf("bare PgDn is still bindable -> %v", resolve_key(.Page_Down, false, false, .Editor)))

				// --- the overlay is scoped to .Editor -------------------------------------
				fmt.println("--- context scoping ---")
				load("ctrl+k = Undo\nenter = Undo\n")
				chk(&bad, resolve_key(.K, true, false, .Palette) == .None, fmt.tprintf("the palette is untouched: ctrl+k/Palette -> %v (want None)", resolve_key(.K, true, false, .Palette)))
				chk(&bad, resolve_key(.Enter, false, false, .Palette) == .Palette_Confirm, fmt.tprintf("Enter still confirms in the palette -> %v", resolve_key(.Enter, false, false, .Palette)))
				chk(&bad, resolve_key(.Enter, false, false, .Find) == .Find_Confirm, fmt.tprintf("Enter still confirms in find -> %v", resolve_key(.Enter, false, false, .Find)))
				chk(&bad, resolve_key(.Escape, false, false, .Find) == .Find_Close, fmt.tprintf("Esc still closes find -> %v", resolve_key(.Escape, false, false, .Find)))
				chk(&bad, resolve_key(.Escape, false, false, .Menu) == .Menu_Close, fmt.tprintf("Esc still closes the menu -> %v", resolve_key(.Escape, false, false, .Menu)))
				chk(&bad, resolve_key(.Escape, false, false, .Settings) == .Settings_Close, fmt.tprintf("Esc still closes settings -> %v", resolve_key(.Escape, false, false, .Settings)))
				chk(&bad, resolve_key(.Escape, false, false, .History) == .History_Close, fmt.tprintf("Esc still closes the history panel -> %v", resolve_key(.Escape, false, false, .History)))
				chk(&bad, resolve_key(.Escape, false, false, .Font) == .Font_Close, fmt.tprintf("Esc still closes the font page -> %v", resolve_key(.Escape, false, false, .Font)))
				// The §6f fallbacks still work, and now carry the overlay's answer:
				// a modified chord in find/menu/history resolves through .Editor.
				chk(&bad, resolve_key(.K, true, false, .Find) == .Undo, fmt.tprintf("find falls back to the overlaid editor chord -> %v (want Undo)", resolve_key(.K, true, false, .Find)))
				chk(&bad, resolve_key(.K, true, false, .Menu) == .Undo, fmt.tprintf("the menu falls back too -> %v", resolve_key(.K, true, false, .Menu)))
				chk(&bad, resolve_key(.Left, false, false, .Find) == .None, "unmodified keys still stay owned by find (Left)")

				// --- an entirely garbage file leaves the defaults intact --------------------
				fmt.println("--- a file that is nothing but garbage ---")
				k = load("\x00\x01 binary junk\n!!!!\nctrl+shift+q = Nope\n= = =\n\xff\xfe\nhello world\n")
				chk(&bad, len(k.entries) == 0, fmt.tprintf("nothing bound (%d entries)", len(k.entries)))
				chk(&bad, keymap_reject_total(k) > 0, fmt.tprintf("and it complained (%d refusals)", keymap_reject_total(k)))
				intact := true
				for b in default_bindings {
					if resolve_key(b.key, b.ctrl, b.alt, b.ctx) == .None {intact = false}
				}
				chk(&bad, intact, "every default binding still resolves")
				// Spot-checks in the actual currency the user cares about.
				chk(&bad, resolve_key(.S, true, false, .Editor) == .Save && resolve_key(.Z, true, false, .Editor) == .Undo && resolve_key(.F, true, false, .Editor) == .Find_Open, "Ctrl+S / Ctrl+Z / Ctrl+F unchanged")
				keymap_reset()
				chk(&bad, resolve_key(.T, true, false, .Editor) == .Toggle_Table, "and clearing the overlay restores the defaults")

				// --- the seeded file is honest documentation ---------------------------------
				// Newtpad writes this file; Newtpad has to be able to read it back.
				// Everything in it is commented, so a fresh seed must parse to
				// nothing at all -- no line of the header may accidentally go live.
				fmt.println("--- the seeded keys.txt ---")
				seed := keymap_seed_text(context.temp_allocator)
				k = load(seed)
				chk(&bad, len(k.entries) == 0 && keymap_reject_total(k) == 0, fmt.tprintf("a fresh seed parses to nothing: %d entries, %d refusals", len(k.entries), keymap_reject_total(k)))
				chk(&bad, strings.contains(seed, "DELETE THIS FILE"), "the escape hatch is in the header")
				chk(&bad, strings.contains(seed, "THE LAST LINE WINS"), "last-wins is stated in the header")
				chk(&bad, strings.contains(seed, "SHIFT IS NOT PART OF A CHORD"), "the shift rule is stated in the header")
				chk(&bad, strings.contains(seed, "EDITOR ONLY"), "the editor-only scope is stated in the header")
				// The one surprise the file does not refuse: an alt+<letter> binding
				// shadows the menu bar's mnemonic for that letter. A header that
				// enumerates what the file will not let you do has to say this too,
				// or it reads as a complete list and is not one.
				chk(&bad, strings.contains(seed, "takes over from the menu bar's Alt shortcut") && strings.contains(seed, "still opens the menu bar"), "the alt+<letter> mnemonic shadow is stated in the header")
				// The three reserved commands must not appear in the list at all --
				// a row a user can uncomment only to be refused is worse than no
				// row. Matched on the command name plus the newline rather than on
				// the padded chord, so column widths are free to change.
				chk(&bad, !strings.contains(seed, "= Save\n") && !strings.contains(seed, "= Clear_Selection\n") && !strings.contains(seed, "= Palette_Open\n"), "the reserved chords are not listed as if they were editable")
				// Uncomment every row of the built-in list and they must all come
				// back as real bindings with no refusals -- the property that makes
				// the file usable as a reference. A chord the parser cannot read
				// back (a separator drift between the writer and the reader, a key
				// display name that gained a space) fails here.
				//
				// Sliced to the list's own section rather than scanning the whole
				// file: the header contains worked examples that are themselves
				// valid binding lines, and counting those would make the total
				// depend on how the prose is written.
				live := strings.builder_make(context.temp_allocator)
				want := 0
				for b in default_bindings {
					if b.ctx == .Editor && !keymap_chord_reserved(b.key, b.ctrl, b.alt) {want += 1}
				}
				in_block := false
				for ln in strings.split_lines(seed, context.temp_allocator) {
					if strings.has_prefix(ln, "# ---") {
						in_block = strings.contains(ln, "the built-in editor keys")
						continue
					}
					if !in_block || !strings.has_prefix(ln, "# ") {continue}
					body := strings.trim_space(ln[2:])
					cut := strings.index(body, " = ")
					if cut <= 0 {continue}
					if _, cok := command_from_name(strings.trim_space(body[cut + 3:])); !cok {continue}
					strings.write_string(&live, body)
					strings.write_byte(&live, '\n')
				}
				k = load(strings.to_string(live))
				chk(&bad, len(k.entries) == want && keymap_reject_total(k) == 0, fmt.tprintf("uncommenting the seeded list gives %d bindings and %d refusals (want %d / 0)", len(k.entries), keymap_reject_total(k), want))
				keymap_reset()

				// --- from disk, through session_dir ------------------------------------------
				fmt.println("--- loading from disk ---")
				path, pok := keymap_path()
				chk(&bad, pok && strings.has_suffix(path, "keys.txt") && strings.has_prefix(strings.to_lower(path, context.temp_allocator), strings.to_lower(os.get_env("NEWTPAD_SESSION_DIR", context.temp_allocator), context.temp_allocator)), fmt.tprintf("keys.txt resolves inside NEWTPAD_SESSION_DIR: %q", path))
				os.remove(path)
				keymap_load()
				chk(&bad, len(g_keymap.entries) == 0 && resolve_key(.T, true, false, .Editor) == .Toggle_Table, "no keys.txt -> the defaults, and no complaint")
				_ = os.write_entire_file(path, transmute([]u8)string("ctrl+t = Undo\n"))
				keymap_load()
				chk(&bad, resolve_key(.T, true, false, .Editor) == .Undo, fmt.tprintf("a keys.txt on disk takes effect -> %v", resolve_key(.T, true, false, .Editor)))
				// Saving the file re-reads it: the loop that makes a binding
				// testable without restarting.
				_ = os.write_entire_file(path, transmute([]u8)string("ctrl+t = Redo\n"))
				chk(&bad, keymap_reload_if_active(nil, path) && resolve_key(.T, true, false, .Editor) == .Redo, fmt.tprintf("saving keys.txt re-reads it -> %v (want Redo)", resolve_key(.T, true, false, .Editor)))
				other := fmt.tprintf("%s%csettings.txt", os.get_env("NEWTPAD_SESSION_DIR", context.temp_allocator), '\\')
				chk(&bad, !keymap_reload_if_active(nil, other), "saving some other file does not")
				// A refused line has to be visible from inside the app. Without
				// this the reload loop is only half a loop: the user writes a
				// chord, saves, presses it, nothing happens, and the one place
				// that says why is a log file they have no reason to open.
				{
					app_t: App
					menu_init(&app_t.menu)
					defer app_destroy(&app_t)
					app_t.settings = settings_default()
					_ = os.write_entire_file(path, transmute([]u8)string("ctrl+t = Redo\nctrl+shift+k = Undo\nnonsense\n"))
					reloaded := keymap_reload_if_active(&app_t, path)
					chk(&bad, reloaded && resolve_key(.T, true, false, .Editor) == .Redo, fmt.tprintf("the good lines still take effect alongside the bad -> %v (want Redo)", resolve_key(.T, true, false, .Editor)))
					chk(&bad, app_notice_active(&app_t) && strings.contains(app_t.notice, "2 LINES REFUSED"), fmt.tprintf("the refusals are reported in the app, not just the log: %q", app_t.notice))
					_ = os.write_entire_file(path, transmute([]u8)string("ctrl+q = Frobnicate\n"))
					keymap_reload_if_active(&app_t, path)
					chk(&bad, strings.contains(app_t.notice, "1 LINE REFUSED"), fmt.tprintf("one line is singular: %q", app_t.notice))
					// And a file with nothing wrong with it says nothing at all --
					// a note on every save of keys.txt would be noise.
					app_t.notice_started = {}
					_ = os.write_entire_file(path, transmute([]u8)string("ctrl+t = Undo\n"))
					keymap_reload_if_active(&app_t, path)
					chk(&bad, !app_notice_active(&app_t), fmt.tprintf("a clean file posts no note: %q", app_t.notice))
				}
				os.remove(path)
				keymap_reset()

				// --- View > Edit Keybindings... -----------------------------------------------
				// app_open_path is headless-safe (it maps and activates a tab like
				// any other open), so the opened tab is asserted rather than
				// skipped as needing a window -- the same shape the Edit Current
				// Theme... case uses.
				fmt.println("--- Edit Keybindings... ---")
				{
					app_t: App
					menu_init(&app_t.menu)
					defer app_destroy(&app_t)
					app_t.settings = settings_default()
					made := keymap_edit_current(&app_t)
					chk(&bad, made && os.exists(path), fmt.tprintf("writes keys.txt when there isn't one (ok=%v exists=%v)", made, os.exists(path)))
					opened := app_active(&app_t)
					chk(&bad, opened != nil && strings.to_lower(opened.path, context.temp_allocator) == strings.to_lower(path, context.temp_allocator), fmt.tprintf("and opens it as a tab: %q", opened.path if opened != nil else ""))
					// What it wrote must be what keymap_load reads back with no
					// complaint -- the seed is only documentation if it is also
					// a valid file.
					keymap_load()
					chk(&bad, len(g_keymap.entries) == 0 && resolve_key(.T, true, false, .Editor) == .Toggle_Table, "the freshly written file loads clean and changes nothing")
					// Second invocation must not clobber the user's bindings --
					// this command exists to let them edit the file, not to reset it.
					mine := "ctrl+t = Undo\n"
					_ = os.write_entire_file(path, transmute([]u8)mine)
					again := keymap_edit_current(&app_t)
					back, _ := os.read_entire_file(path, context.temp_allocator)
					chk(&bad, again && string(back) == mine, fmt.tprintf("an existing keys.txt is never overwritten (%d bytes back, want %d)", len(back), len(mine)))
				}
				os.remove(path)
				keymap_reset()
				return bad
			}
			n := keymaptest()
			fmt.printfln("keymaptest: %d failures", n)
			return true
		}

		// `newtpad bookmarktest` — line bookmarks (doc.odin's bookmark section,
		// the Ctrl+F2/F2 commands, and the session v5 field).
		//
		// The claim this mode has to be able to falsify is NOT "toggling appends
		// an int". It is that a bookmark still names the line it was set on after
		// the buffer has moved underneath it. So every edit case asserts three
		// independent things about the same state:
		//
		//   1. the OFFSET, against a number computed by hand from the fixture;
		//   2. the TEXT at that offset, so an offset that is arithmetically right
		//      but names the wrong line still fails;
		//   3. the "every entry is a real line start" INVARIANT, which is the
		//      property the shift rules exist to preserve and the one that a
		//      wrong rule breaks even when the arithmetic looks plausible.
		//
		// Several cases also assert through doc_bookmark_rects -- what is DRAWN --
		// rather than through doc.bookmarks alone, because the list is not the
		// user-visible artifact and a mark on the wrong row is the failure that
		// would actually be reported.
		if os.args[1] == "bookmarktest" {
			if !require_scratch_session("bookmarktest") {return true}

			// "alpha\nbravo\ncharlie\ndelta\n" -- 26 bytes, four lines.
			// Line starts: 0, 6, 12, 20. Deliberately unequal line lengths so an
			// off-by-one in a shift cannot land on another line's start by luck.
			BM_FIX :: "alpha\nbravo\ncharlie\ndelta\n"

			bm_chk :: proc(bad: ^int, cond: bool, msg: string) {
				fmt.printfln("  %-4s %s", "OK" if cond else "FAIL", msg)
				if !cond {bad^ += 1}
			}

			// `n` bytes of the buffer starting at BOOKMARK `i` -- read through the
			// bookmark itself, never at a literal offset.
			//
			// This is the difference between a check that can fail and one that
			// cannot, and it was got wrong first time round: reading at the
			// expected offset (`bm_at(&d, 14, 7) == "charlie"`) asserts something
			// about the FIXTURE, not about the bookmark, and sabotaging the shift
			// left every such line green while the offsets beside them went red.
			// Reading at d.bookmarks[i] is what makes "the entry still names its
			// own line" an assertion about the entry.
			bm_at :: proc(d: ^Document, i, n: int) -> string {
				if i < 0 || i >= len(d.bookmarks) {return "<no such bookmark>"}
				at := d.bookmarks[i]
				if at < 0 || at >= d.pt.length {return "<oob>"}
				buf := make([]u8, min(n, d.pt.length - at), context.temp_allocator)
				base.pt_read(&d.pt, at, buf)
				return string(buf)
			}

			// The invariant every shift rule is written to preserve: the list is
			// strictly ascending, in range, and every entry is a real line start.
			// Checked after every edit case; it is the assertion that does not
			// depend on the fixture's arithmetic.
			bm_invariant :: proc(d: ^Document) -> bool {
				prev := -1
				for b in d.bookmarks {
					if b <= prev || b < 0 || b > d.pt.length {return false}
					prev = b
					if b == 0 {continue}
					one: [1]u8
					base.pt_read(&d.pt, b - 1, one[:])
					if one[0] != '\n' {return false}
				}
				return true
			}

			bm_list :: proc(d: ^Document) -> string {return fmt.tprintf("%v", d.bookmarks[:])}

			// Bookmark each offset by putting the caret there and toggling, i.e.
			// through the product's own entry point rather than by appending to
			// the array -- a fixture built by hand would not prove the toggle
			// keeps the list sorted.
			bm_set :: proc(d: ^Document, offs: []int) {
				for o in offs {
					d.cursor, d.anchor = o, o
					doc_bookmark_toggle(d)
				}
			}

			bad := 0

			// --- toggle -------------------------------------------------------------
			bm_toggle :: proc(bad: ^int, fix: string) {
				fmt.println("--- toggle ---")
				d := doc_from_content(transmute([]u8)strings.clone(fix), "", .UTF8)
				defer doc_close(&d)

				// From the MIDDLE of a line: the bookmark is the line's start, not
				// the caret. This is the whole point of "bookmark the line".
				d.cursor, d.anchor = 14, 14 // inside "charlie"
				on, ok := doc_bookmark_toggle(&d)
				bm_chk(bad, on && ok && len(d.bookmarks) == 1 && d.bookmarks[0] == 12, fmt.tprintf("caret mid-line bookmarks the LINE START: %v (want [12])", d.bookmarks[:]))

				// A second line, set from a lower offset, still lands sorted.
				d.cursor, d.anchor = 2, 2
				doc_bookmark_toggle(&d)
				bm_chk(bad, len(d.bookmarks) == 2 && d.bookmarks[0] == 0 && d.bookmarks[1] == 12, fmt.tprintf("the list stays sorted: %v (want [0 12])", d.bookmarks[:]))

				// Toggling the same line OFF, from a different offset on it than
				// the one it was set from.
				d.cursor, d.anchor = 18, 18 // still inside "charlie"
				on2, _ := doc_bookmark_toggle(&d)
				bm_chk(bad, !on2 && len(d.bookmarks) == 1 && d.bookmarks[0] == 0, fmt.tprintf("toggling off from elsewhere on the line: on=%v %v (want [0])", on2, d.bookmarks[:]))

				// And exactly at a line start, both ways -- offset 0 is the edge
				// case for every "is this a line start" test in the shift rules.
				d.cursor, d.anchor = 0, 0
				doc_bookmark_toggle(&d)
				bm_chk(bad, len(d.bookmarks) == 0, fmt.tprintf("toggling off at offset 0: %v (want [])", d.bookmarks[:]))

				// A pseudo-tab (Settings/Font) has no lines to bookmark.
				d.kind = .Settings
				_, okp := doc_bookmark_toggle(&d)
				bm_chk(bad, !okp && len(d.bookmarks) == 0, "a pseudo-tab refuses rather than bookmarking its empty buffer")
			}
			bm_toggle(&bad, BM_FIX)

			// --- cycle, with wrap ----------------------------------------------------
			bm_cycle :: proc(bad: ^int, fix: string, set: proc(d: ^Document, offs: []int)) {
				fmt.println("--- cycle ---")
				d := doc_from_content(transmute([]u8)strings.clone(fix), "", .UTF8)
				defer doc_close(&d)

				// An empty set: a no-op that says so, not a crash and not a caret
				// teleported to 0.
				d.cursor, d.anchor = 14, 14
				movedF := doc_bookmark_cycle(&d, false)
				movedB := doc_bookmark_cycle(&d, true)
				bm_chk(bad, !movedF && !movedB && d.cursor == 14, fmt.tprintf("cycling an empty set is a no-op: fwd=%v back=%v cursor=%d", movedF, movedB, d.cursor))

				set(&d, {0, 12, 20})
				d.cursor, d.anchor = 0, 0
				doc_bookmark_cycle(&d, false)
				c1 := d.cursor
				doc_bookmark_cycle(&d, false)
				c2 := d.cursor
				doc_bookmark_cycle(&d, false)
				c3 := d.cursor // wraps to the first
				bm_chk(bad, c1 == 12 && c2 == 20 && c3 == 0, fmt.tprintf("forward wraps: 0 -> %d -> %d -> %d (want 12, 20, 0)", c1, c2, c3))

				b1 := doc_bookmark_cycle(&d, true) ? d.cursor : -1 // wraps to the last
				doc_bookmark_cycle(&d, true)
				b2 := d.cursor
				doc_bookmark_cycle(&d, true)
				b3 := d.cursor
				bm_chk(bad, b1 == 20 && b2 == 12 && b3 == 0, fmt.tprintf("backward wraps: 0 -> %d -> %d -> %d (want 20, 12, 0)", b1, b2, b3))

				// From a caret that is not itself on a bookmark: forward goes to
				// the next one AFTER the caret, not to the next INDEX.
				d.cursor, d.anchor = 14, 14 // inside "charlie", whose start (12) is bookmarked
				doc_bookmark_cycle(&d, false)
				fwd := d.cursor
				d.cursor, d.anchor = 14, 14
				doc_bookmark_cycle(&d, true)
				back := d.cursor
				bm_chk(bad, fwd == 20 && back == 12, fmt.tprintf("from mid-line: forward=%d back=%d (want 20, 12 -- back lands on this line's own start)", fwd, back))

				// The jump collapses a selection, like every other caret move.
				d.cursor, d.anchor = 0, 26
				doc_bookmark_cycle(&d, false)
				bm_chk(bad, d.anchor == d.cursor, fmt.tprintf("the jump collapses the selection: cursor=%d anchor=%d", d.cursor, d.anchor))
			}
			bm_cycle(&bad, BM_FIX, bm_set)

			// --- an insert ABOVE shifts the offset ------------------------------------
			//
			// THE case this feature is most likely to get wrong, so it is asserted
			// four ways: the offsets, the text each one names, the line-start
			// invariant, and the marks that actually get drawn. Removing the shift
			// leaves offsets 12 and 20 pointing at 'o' inside "bravo" and 'e'
			// inside "charlie" -- neither is a line start, so all four fail.
			bm_insert :: proc(bad: ^int, fix: string, set: proc(d: ^Document, offs: []int), at: proc(d: ^Document, at, n: int) -> string, inv: proc(d: ^Document) -> bool) {
				fmt.println("--- an insert above shifts ---")
				d := doc_from_content(transmute([]u8)strings.clone(fix), "", .UTF8)
				defer doc_close(&d)
				set(&d, {12, 20})

				d.cursor, d.anchor = 0, 0
				doc_insert_text(&d, transmute([]u8)string("XY"), .Paste)
				bm_chk(bad, len(d.bookmarks) == 2 && d.bookmarks[0] == 14 && d.bookmarks[1] == 22, fmt.tprintf("2 bytes at offset 0: %v (want [14 22])", d.bookmarks[:]))
				bm_chk(bad, at(&d, 0, 7) == "charlie" && at(&d, 1, 5) == "delta", fmt.tprintf("...and they still name their own lines: %q / %q (want \"charlie\" / \"delta\")", at(&d, 0, 7), at(&d, 1, 5)))
				bm_chk(bad, inv(&d), "...and every entry is still a line start")

				// An insert BETWEEN two bookmarks moves only the later one.
				d.cursor, d.anchor = 21, 21 // the end of "charlie", after the first bookmark
				doc_insert_text(&d, transmute([]u8)string("ZZZ"), .Paste)
				bm_chk(bad, d.bookmarks[0] == 14 && d.bookmarks[1] == 25, fmt.tprintf("an insert between them moves only the later: %v (want [14 25])", d.bookmarks[:]))
				bm_chk(bad, at(&d, 0, 10) == "charlieZZZ" && at(&d, 1, 5) == "delta", fmt.tprintf("...still their own lines: %q / %q", at(&d, 0, 10), at(&d, 1, 5)))
				bm_chk(bad, inv(&d), "...invariant holds")

				// An insert EXACTLY AT a bookmark leaves it alone: the byte before
				// it did not move, so the offset is still that line's start, and
				// the inserted text belongs to the bookmarked line. Shifting here
				// would push the entry one byte into its own line, where no row's
				// line start matches it -- the mark would silently stop drawing.
				d.cursor, d.anchor = 14, 14
				doc_insert_text(&d, transmute([]u8)string("Q"), .Paste)
				bm_chk(bad, d.bookmarks[0] == 14 && at(&d, 0, 8) == "Qcharlie", fmt.tprintf("an insert AT the line start does not shift it: %v, line is %q (want [14 ...] \"Qcharlie\")", d.bookmarks[:], at(&d, 0, 8)))
				bm_chk(bad, inv(&d), "...invariant holds")

				// ...including when what is inserted ENDS in a newline, which is
				// the case where the two answers differ visibly: offset 14 now
				// begins the new "NEW" line.
				d.cursor, d.anchor = 14, 14
				doc_insert_text(&d, transmute([]u8)string("NEW\n"), .Paste)
				bm_chk(bad, d.bookmarks[0] == 14 && at(&d, 0, 3) == "NEW", fmt.tprintf("a newline-terminated insert at the line start keeps the offset: %v, line is %q", d.bookmarks[:], at(&d, 0, 3)))
				bm_chk(bad, inv(&d), "...invariant holds")
			}
			bm_insert(&bad, BM_FIX, bm_set, bm_at, bm_invariant)

			// --- deletes -------------------------------------------------------------
			bm_delete :: proc(bad: ^int, fix: string, set: proc(d: ^Document, offs: []int), at: proc(d: ^Document, at, n: int) -> string, inv: proc(d: ^Document) -> bool) {
				fmt.println("--- deletes ---")
				d := doc_from_content(transmute([]u8)strings.clone(fix), "", .UTF8)
				defer doc_close(&d)

				// Deleting the bookmarked line takes the bookmark with it, and the
				// bookmark BELOW it shifts up onto the offset the deleted line had.
				set(&d, {12, 20})
				d.anchor, d.cursor = 12, 20 // all of "charlie\n"
				doc_replace_sel(&d, nil, .Delete)
				bm_chk(bad, len(d.bookmarks) == 1 && d.bookmarks[0] == 12, fmt.tprintf("deleting the bookmarked line drops it: %v (want [12], the old 20)", d.bookmarks[:]))
				bm_chk(bad, at(&d, 0, 5) == "delta", fmt.tprintf("...and the survivor still names its own line: %q", at(&d, 0, 5)))
				bm_chk(bad, inv(&d), "...invariant holds")

				// Deleting the line ABOVE a bookmark must KEEP it -- the bookmarked
				// line now begins where the deleted one did. This is the case that
				// stops "drop anything the delete touched" from being the rule.
				d2 := doc_from_content(transmute([]u8)strings.clone(fix), "", .UTF8)
				defer doc_close(&d2)
				set(&d2, {12})
				d2.anchor, d2.cursor = 6, 12 // all of "bravo\n"
				doc_replace_sel(&d2, nil, .Delete)
				bm_chk(bad, len(d2.bookmarks) == 1 && d2.bookmarks[0] == 6 && at(&d2, 0, 7) == "charlie", fmt.tprintf("deleting the line ABOVE shifts, does not drop: %v %q (want [6] \"charlie\")", d2.bookmarks[:], at(&d2, 0, 7)))
				bm_chk(bad, inv(&d2), "...invariant holds")

				// Backspace at a bookmarked line start JOINS it onto the previous
				// line. The offset would land mid-line, so the bookmark dies --
				// the one delete case that is neither "inside the range" nor a
				// plain shift, and the reason the rule reads the byte in front of
				// the deleted range.
				d3 := doc_from_content(transmute([]u8)strings.clone(fix), "", .UTF8)
				defer doc_close(&d3)
				set(&d3, {12})
				d3.cursor, d3.anchor = 12, 12
				doc_backspace(&d3)
				bm_chk(bad, len(d3.bookmarks) == 0, fmt.tprintf("Backspace at the line start joins the line and drops the bookmark: %v (want [])", d3.bookmarks[:]))
				bm_chk(bad, inv(&d3), "...invariant holds")

				// A delete that starts at the bookmarked line start but stays
				// inside the line drops it too. Deliberate conservatism, pinned
				// here so it is a decision and not a surprise: the rule is "the
				// line start was inside the deleted text", and distinguishing this
				// from a whole-line delete would need the line's extent, a scan
				// this path does not otherwise pay for.
				d4 := doc_from_content(transmute([]u8)strings.clone(fix), "", .UTF8)
				defer doc_close(&d4)
				set(&d4, {12})
				d4.cursor, d4.anchor = 12, 12
				doc_delete_fwd(&d4)
				bm_chk(bad, len(d4.bookmarks) == 0, fmt.tprintf("Delete at the line start drops it (documented conservatism): %v (want [])", d4.bookmarks[:]))

				// A delete entirely BELOW every bookmark moves nothing.
				d5 := doc_from_content(transmute([]u8)strings.clone(fix), "", .UTF8)
				defer doc_close(&d5)
				set(&d5, {0, 6})
				d5.anchor, d5.cursor = 20, 26
				doc_replace_sel(&d5, nil, .Delete)
				bm_chk(bad, len(d5.bookmarks) == 2 && d5.bookmarks[0] == 0 && d5.bookmarks[1] == 6, fmt.tprintf("a delete below them changes nothing: %v (want [0 6])", d5.bookmarks[:]))
				bm_chk(bad, inv(&d5), "...invariant holds")
			}
			bm_delete(&bad, BM_FIX, bm_set, bm_at, bm_invariant)

			// --- a replace is ONE operation ------------------------------------------
			//
			// The shift used to be two procedures, and their COMPOSITION at a
			// single offset was wrong even though each half was right on its own:
			// the delete half collapses a bookmark sitting at the region's END
			// down onto its START, and the insert half then declines to move an
			// offset equal to the start, so the bookmark silently ended up naming
			// the REPLACEMENT text.
			//
			// bm_invariant CANNOT see this -- every entry is still a real line
			// start, just the wrong one. That is why every case here asserts the
			// TEXT the bookmark names, read through the bookmark itself. A case
			// that only checked offsets and the invariant would have stayed green
			// through the whole bug, which is exactly what happened.
			bm_replace :: proc(bad: ^int, fix: string, set: proc(d: ^Document, offs: []int), at: proc(d: ^Document, at, n: int) -> string, inv: proc(d: ^Document) -> bool) {
				fmt.println("--- a replace is one operation ---")

				// Alt+Down two lines above a bookmark. doc_move_lines is a single
				// doc_replace_range over [6,20) that writes the same 14 bytes back
				// in the other order, so "delta" must not move AT ALL. The broken
				// version pulled it back to 6, where it named "charl".
				{
					d := doc_from_content(transmute([]u8)strings.clone(fix), "", .UTF8)
					defer doc_close(&d)
					set(&d, {20})
					d.cursor, d.anchor = 6, 6 // on "bravo", two lines above the mark
					doc_move_lines(&d, 1)
					ok := len(d.bookmarks) == 1 && d.bookmarks[0] == 20 && at(&d, 0, 5) == "delta"
					bm_chk(bad, ok, fmt.tprintf("Alt+Down above a bookmark leaves it on its own line: %v %q (want [20] \"delta\")", d.bookmarks[:], at(&d, 0, 5)))
					bm_chk(bad, inv(&d), "...invariant holds -- and it held with the bug too, which is the point")
				}

				// Alt+Up, the mirror: the caret on "charlie" swaps it with "bravo"
				// over the same region, and "delta" still must not move.
				{
					d := doc_from_content(transmute([]u8)strings.clone(fix), "", .UTF8)
					defer doc_close(&d)
					set(&d, {20})
					d.cursor, d.anchor = 12, 12 // on "charlie"
					doc_move_lines(&d, -1)
					ok := len(d.bookmarks) == 1 && d.bookmarks[0] == 20 && at(&d, 0, 5) == "delta"
					bm_chk(bad, ok, fmt.tprintf("Alt+Up above a bookmark leaves it on its own line: %v %q (want [20] \"delta\")", d.bookmarks[:], at(&d, 0, 5)))
					bm_chk(bad, inv(&d), "...invariant holds")
				}

				// Paste over a whole-line selection (Shift+Down or a triple-click,
				// then Ctrl+V): "bravo\n" -> "XX\n" shortens the line by three
				// bytes, so the bookmark on "charlie" lands on 9, not on 6 where
				// "XX" now lives.
				{
					d := doc_from_content(transmute([]u8)strings.clone(fix), "", .UTF8)
					defer doc_close(&d)
					set(&d, {12})
					d.anchor, d.cursor = 6, 12 // exactly "bravo\n"
					doc_replace_sel(&d, transmute([]u8)string("XX\n"), .Paste)
					ok := len(d.bookmarks) == 1 && d.bookmarks[0] == 9 && at(&d, 0, 7) == "charlie"
					bm_chk(bad, ok, fmt.tprintf("a paste over the line ABOVE moves the bookmark past the replacement: %v %q (want [9] \"charlie\")", d.bookmarks[:], at(&d, 0, 7)))
					bm_chk(bad, inv(&d), "...invariant holds")
				}

				// The same edit through doc_replace_range, which is the path
				// Replace All and a column edit take -- the selection is not
				// involved, so this is a second reachable route to the same shape.
				{
					d := doc_from_content(transmute([]u8)strings.clone(fix), "", .UTF8)
					defer doc_close(&d)
					set(&d, {12, 20})
					doc_replace_range(&d, 6, 6, transmute([]u8)string("XX\n"), .Replace)
					ok := len(d.bookmarks) == 2 && d.bookmarks[0] == 9 && d.bookmarks[1] == 17
					bm_chk(bad, ok && at(&d, 0, 7) == "charlie" && at(&d, 1, 5) == "delta", fmt.tprintf("replace-all over a newline-terminated match: %v %q/%q (want [9 17] \"charlie\"/\"delta\")", d.bookmarks[:], at(&d, 0, 7), at(&d, 1, 5)))
					bm_chk(bad, inv(&d), "...invariant holds")
				}

				// A replacement that does NOT end in a newline merges the
				// bookmarked line onto the replacement's tail, so there is no line
				// for the mark to sit on and it is dropped. Same conservatism as
				// the Backspace-join case, and pinned here so it is a decision.
				{
					d := doc_from_content(transmute([]u8)strings.clone(fix), "", .UTF8)
					defer doc_close(&d)
					set(&d, {12})
					doc_replace_range(&d, 6, 6, transmute([]u8)string("XX"), .Replace)
					bm_chk(bad, len(d.bookmarks) == 0, fmt.tprintf("a replacement with no trailing newline joins the line and drops it: %v (want [])", d.bookmarks[:]))
					bm_chk(bad, inv(&d), "...invariant holds")
				}

				// A bookmark strictly BELOW the replaced region shifts by the size
				// difference, not by the delete's -n or the insert's +m alone.
				{
					d := doc_from_content(transmute([]u8)strings.clone(fix), "", .UTF8)
					defer doc_close(&d)
					set(&d, {20})
					doc_replace_range(&d, 6, 6, transmute([]u8)string("XX\n"), .Replace)
					ok := len(d.bookmarks) == 1 && d.bookmarks[0] == 17 && at(&d, 0, 5) == "delta"
					bm_chk(bad, ok, fmt.tprintf("a bookmark below shifts by m-n: %v %q (want [17] \"delta\")", d.bookmarks[:], at(&d, 0, 5)))
					bm_chk(bad, inv(&d), "...invariant holds")
				}

				// And undo puts the set back, since a replace is one undo step.
				{
					d := doc_from_content(transmute([]u8)strings.clone(fix), "", .UTF8)
					defer doc_close(&d)
					set(&d, {12})
					doc_replace_range(&d, 6, 6, transmute([]u8)string("XX"), .Replace)
					doc_undo(&d)
					ok := len(d.bookmarks) == 1 && d.bookmarks[0] == 12 && at(&d, 0, 7) == "charlie"
					bm_chk(bad, ok, fmt.tprintf("undo of a replace restores the set: %v %q (want [12] \"charlie\")", d.bookmarks[:], at(&d, 0, 7)))
				}
			}
			bm_replace(&bad, BM_FIX, bm_set, bm_at, bm_invariant)

			// --- Encoding > LF/CRLF --------------------------------------------------
			//
			// doc_set_line_ending rewrites the whole buffer, so every bookmark
			// inside it goes -- there is no correct shift without re-walking, and
			// undo brings them back. What must NOT happen is the one this used to
			// do: a bookmark on the TRAILING EMPTY LINE is at offset == length,
			// outside the replaced range, and as a separate delete-then-insert it
			// collapsed to 0 and stayed there. The user set no bookmark on line 1
			// and got one.
			bm_eol :: proc(bad: ^int, fix: string, set: proc(d: ^Document, offs: []int), inv: proc(d: ^Document) -> bool) {
				fmt.println("--- LF -> CRLF ---")
				d := doc_from_content(transmute([]u8)strings.clone(fix), "", .UTF8)
				defer doc_close(&d)
				set(&d, {12, 26}) // "charlie", and the trailing empty line at length

				doc_set_line_ending(&d, .CRLF)
				// 26 LF bytes -> 30 CRLF bytes; the trailing empty line is the new end.
				ok := len(d.bookmarks) == 1 && d.bookmarks[0] == d.pt.length && d.pt.length == 30
				bm_chk(bad, ok, fmt.tprintf("the trailing-line bookmark follows the end, and NOTHING lands on line 1: %v (want [%d])", d.bookmarks[:], d.pt.length))
				bm_chk(bad, inv(&d), "...invariant holds")

				doc_undo(&d)
				back := len(d.bookmarks) == 2 && d.bookmarks[0] == 12 && d.bookmarks[1] == 26
				bm_chk(bad, back, fmt.tprintf("undo restores the whole set: %v (want [12 26])", d.bookmarks[:]))
			}
			bm_eol(&bad, BM_FIX, bm_set, bm_invariant)

			// --- undo / redo ---------------------------------------------------------
			bm_undo :: proc(bad: ^int, fix: string, set: proc(d: ^Document, offs: []int), inv: proc(d: ^Document) -> bool) {
				fmt.println("--- undo/redo ---")
				d := doc_from_content(transmute([]u8)strings.clone(fix), "", .UTF8)
				defer doc_close(&d)
				set(&d, {12, 20})

				d.anchor, d.cursor = 12, 20
				doc_replace_sel(&d, nil, .Delete)
				after := fmt.tprintf("%v", d.bookmarks[:])
				doc_undo(&d)
				bm_chk(bad, len(d.bookmarks) == 2 && d.bookmarks[0] == 12 && d.bookmarks[1] == 20, fmt.tprintf("undo restores the dropped bookmark: %v (want [12 20], was %s)", d.bookmarks[:], after))
				bm_chk(bad, inv(&d), "...invariant holds")
				doc_redo(&d)
				bm_chk(bad, len(d.bookmarks) == 1 && d.bookmarks[0] == 12, fmt.tprintf("redo re-applies the drop: %v (want [12])", d.bookmarks[:]))

				// A bookmark set AFTER an edit belongs to the state it was set in:
				// undoing that edit must bring back the set as it was BEFORE it,
				// not carry the newer one backwards.
				d2 := doc_from_content(transmute([]u8)strings.clone(fix), "", .UTF8)
				defer doc_close(&d2)
				set(&d2, {12})
				d2.cursor, d2.anchor = 0, 0
				doc_insert_text(&d2, transmute([]u8)string("XY"), .Paste) // 12 -> 14
				set(&d2, {0}) // a second bookmark, in the post-edit state
				doc_undo(&d2)
				bm_chk(bad, len(d2.bookmarks) == 1 && d2.bookmarks[0] == 12, fmt.tprintf("undo restores the set that belonged to the state: %v (want [12])", d2.bookmarks[:]))
				doc_redo(&d2)
				bm_chk(bad, len(d2.bookmarks) == 2 && d2.bookmarks[0] == 0 && d2.bookmarks[1] == 14, fmt.tprintf("redo restores the newer set: %v (want [0 14])", d2.bookmarks[:]))
			}
			bm_undo(&bad, BM_FIX, bm_set, bm_invariant)

			// --- what is DRAWN -------------------------------------------------------
			//
			// The seam, not the unit: doc_bookmark_rects walks the same
			// visible_begin/visible_next the draw does, so these assertions are
			// about rows the document actually renders. A wrapped line is the case
			// worth having -- its continuation rows have a `start` that is not the
			// logical line start, and a mark on one of them would be a mark on a
			// row the user reads as the middle of a sentence.
			bm_marks :: proc(bad: ^int, fix: string, t: ^plat.Text, set: proc(d: ^Document, offs: []int)) {
				fmt.println("--- the drawn marks ---")
				px := BASE_PX
				q: [32]plat.Quad

				d := doc_from_content(transmute([]u8)strings.clone(fix), "", .UTF8)
				defer doc_close(&d)
				d.view_cols = 80
				set(&d, {6, 20})

				n := doc_bookmark_rects(&d, t, px, 4, q[:])
				okn := n == 2 && q[0].pos.y == row_rect_y(px, 1) && q[1].pos.y == row_rect_y(px, 3)
				bm_chk(bad, okn, fmt.tprintf("one mark per bookmarked visible row: n=%d ys=%v/%v (want 2 at rows 1 and 3)", n, q[0].pos.y, q[1].pos.y))
				bm_chk(bad, n == 2 && q[0].size.y == line_height(px), fmt.tprintf("a mark is one row tall: %v (want %v)", q[0].size.y, line_height(px)))

				// Entirely left of where text begins, at any gutter width. This is
				// the "do not add a second width" check: the mark is positioned
				// against TEXT_MARGIN_X only, and col_x is the one definition of
				// where column 0 starts, so asking col_x is how the two are kept
				// from overlapping rather than comparing two literals.
				cw := plat.text_char_width(t, px)
				clear_of_text := n == 2 && q[0].pos.x >= 0 && q[0].pos.x + q[0].size.x <= col_x(cw, 0)
				bm_chk(bad, clear_of_text, fmt.tprintf("the mark sits left of column 0: [%v,%v) vs col_x(0)=%v", q[0].pos.x, q[0].pos.x + q[0].size.x, col_x(cw, 0)))
				// ...and with a filter-view gutter present it is still clear of it,
				// since GUTTER_W only pushes column 0 further right.
				saved := GUTTER_W
				GUTTER_W = 40
				n2 := doc_bookmark_rects(&d, t, px, 4, q[:])
				bm_chk(bad, n2 == 2 && q[0].pos.x + q[0].size.x <= col_x(cw, 0), fmt.tprintf("...and still clear with a gutter: [%v,%v) vs col_x(0)=%v", q[0].pos.x, q[0].pos.x + q[0].size.x, col_x(cw, 0)))
				GUTTER_W = saved

				// Scrolled: only the bookmarks in view are drawn, at their row
				// within the view rather than their row in the file.
				d.top = 12
				n3 := doc_bookmark_rects(&d, t, px, 2, q[:])
				bm_chk(bad, n3 == 1 && q[0].pos.y == row_rect_y(px, 1), fmt.tprintf("scrolled: n=%d y=%v (want 1 at row 1)", n3, q[0].pos.y))

				// A wrapped line gets exactly ONE mark, on its first visual row --
				// and the line AFTER it is marked on the row it is actually drawn
				// on, which is the assertion that pins the row walk to
				// visible_next. A mark placed by counting newlines from doc.top
				// (the obvious second implementation) puts "tail" on row 2 instead
				// of row 9, because it cannot see that one logical line occupied
				// eight visual rows.
				//
				// "head\n" is 0..4, the 300-'w' line starts at 5, its terminator is
				// at 305, "tail" starts at 306. At 40 cells the long line is 8
				// visual rows (1..8), so "tail" is row 9.
				long := strings.repeat("w", 300, context.temp_allocator)
				wsrc := fmt.tprintf("head\n%s\ntail\n", long)
				w := doc_from_content(transmute([]u8)strings.clone(wsrc), "", .UTF8)
				defer doc_close(&w)
				w.wrap = true
				w.view_cols = 40
				set(&w, {5, 306})
				nw := doc_bookmark_rects(&w, t, px, 12, q[:])
				okw := nw == 2 && q[0].pos.y == row_rect_y(px, 1) && q[1].pos.y == row_rect_y(px, 9)
				bm_chk(bad, okw, fmt.tprintf("a wrapped line is marked once and the next line lands on its real row: n=%d ys=%v/%v (want 2 at rows 1 and 9)", nw, q[0].pos.y, q[1].pos.y))
			}

			// --- the bindings and the dispatch ---------------------------------------
			//
			// Through resolve_key and command_dispatch, not by calling the doc
			// procs: the claim is that Ctrl+F2 and F2/Shift+F2 DO these things.
			// Shift+F2 is the case the whole command shape exists for -- it is not
			// a second binding and cannot be, so if the dispatch ever stops reading
			// ev.shift the two directions collapse into one and only this fails.
			bm_dispatch :: proc(bad: ^int, fix: string, t: ^plat.Text) {
				fmt.println("--- Ctrl+F2 / F2 / Shift+F2 ---")
				bm_chk(bad, resolve_key(.F2, true, false, .Editor) == .Bookmark_Toggle, fmt.tprintf("Ctrl+F2 -> %v", resolve_key(.F2, true, false, .Editor)))
				bm_chk(bad, resolve_key(.F2, false, false, .Editor) == .Bookmark_Cycle, fmt.tprintf("F2 -> %v", resolve_key(.F2, false, false, .Editor)))

				// Adding F1-F12 to plat.Key took Alt+F4 away from Windows: before
				// it, VK_F4 translated to .None and the pump fell through to
				// DefWindowProc, which is what closes the window. Nothing in the
				// type system could catch that -- the enum grew and every
				// exhaustive switch still compiled. The rule lives in one
				// predicate that the pump asks and this asserts, since driving the
				// real wnd_proc needs an HWND and a message loop.
				bm_chk(bad, plat.key_belongs_to_windows(.F4, true) && plat.key_belongs_to_windows(.F10, true), "Alt+F4 and F10 are handed back to Windows")
				bm_chk(bad, !plat.key_belongs_to_windows(.F4, false) && !plat.key_belongs_to_windows(.F10, false), "...but a bare F4 / F10 is ordinary and stays bindable")
				bm_chk(bad, !plat.key_belongs_to_windows(.F2, true) && !plat.key_belongs_to_windows(.Z, true), "...and Alt+F2 / Alt+Z are ours")

				a: App
				dummy: plat.Window
				app_new_scratch(&a)
				defer app_destroy(&a)
				a.settings = settings_default()
				ad := app_active(&a)
				doc_insert_text(ad, transmute([]u8)fix, .Paste)
				ad.cursor, ad.anchor = 0, 0

				// Ctrl+F2 on three lines, reached the way the user reaches them.
				for off in ([]int{0, 12, 20}) {
					ad.cursor, ad.anchor = off, off
					command_dispatch(resolve_key(.F2, true, false, .Editor), {.F2, true, false, false}, &a, &dummy, t, 10)
				}
				bm_chk(bad, len(ad.bookmarks) == 3, fmt.tprintf("Ctrl+F2 x3 sets three: %v", ad.bookmarks[:]))

				ad.cursor, ad.anchor = 0, 0
				cyc := resolve_key(.F2, false, false, .Editor)
				command_dispatch(cyc, {.F2, false, false, false}, &a, &dummy, t, 10)
				fwd := ad.cursor
				command_dispatch(cyc, {.F2, false, true, false}, &a, &dummy, t, 10) // Shift+F2
				back := ad.cursor
				bm_chk(bad, fwd == 12 && back == 0, fmt.tprintf("F2 then Shift+F2: %d then %d (want 12 then 0 -- shift is read from the event, not the chord)", fwd, back))

				// Ctrl+F2 again on a bookmarked line removes it.
				ad.cursor, ad.anchor = 14, 14
				command_dispatch(resolve_key(.F2, true, false, .Editor), {.F2, true, false, false}, &a, &dummy, t, 10)
				bm_chk(bad, len(ad.bookmarks) == 2, fmt.tprintf("Ctrl+F2 again clears that line: %v", ad.bookmarks[:]))

				// An empty set says so rather than leaving the key looking dead.
				b: App
				dummy2: plat.Window
				app_new_scratch(&b)
				defer app_destroy(&b)
				b.settings = settings_default()
				command_dispatch(cyc, {.F2, false, false, false}, &b, &dummy2, t, 10)
				bm_chk(bad, app_notice_active(&b) && strings.contains(b.notice, "NO BOOKMARKS"), fmt.tprintf("F2 with no bookmarks posts a note: %q", b.notice))
			}

			// The two cases above need real font metrics (visible_next decides wrap
			// through plat.Text). Loaded once here rather than per case.
			{
				t: plat.Text
				if plat.text_load_faces(&t) {
					bm_marks(&bad, BM_FIX, &t, bm_set)
					bm_dispatch(&bad, BM_FIX, &t)
				} else {
					fmt.println("  FAIL no fonts loaded; cannot exercise the drawn marks or the dispatch")
					bad += 1
				}
			}

			// --- session format 5 ----------------------------------------------------
			//
			// Writes session.txt and backups in NEWTPAD_SESSION_DIR (hence the
			// scratch guard at the top of the mode).
			bm_session :: proc(bad: ^int, fix: string, set: proc(d: ^Document, offs: []int)) {
				fmt.println("--- session ---")
				tmp := os.get_env("TEMP", context.temp_allocator)
				dir, _ := session_dir()
				sp, _ := filepath.join({dir, "session.txt"}, context.temp_allocator)

				// A CLEAN tab (reopened from disk) whose file has not changed.
				clean := fmt.tprintf("%s%cnewtpad_bm_clean.txt", tmp, '\\')
				plat.file_write_atomic(clean, transmute([]u8)fix)
				{
					a: App
					defer app_destroy(&a)
					if fd, ok := doc_open(clean); ok {
						d := new(Document)
						d^ = fd
						set(d, {6, 20})
						app_add(&a, d)
					}
					session_save(&a)
				}
				body, _ := os.read_entire_file(sp, context.temp_allocator)
				bm_chk(bad, strings.contains(string(body), "newtpad-session 5") && strings.contains(string(body), " 6,20 "), fmt.tprintf("the line carries the set as one token: %q", strings.trim_space(string(body))))
				{
					b: App
					defer app_destroy(&b)
					session_restore(&b)
					d := app_active(&b)
					got := d != nil ? fmt.tprintf("%v", d.bookmarks[:]) : "<no tab>"
					bm_chk(bad, d != nil && len(d.bookmarks) == 2 && d.bookmarks[0] == 6 && d.bookmarks[1] == 20, fmt.tprintf("a clean tab restores its bookmarks: %s (want [6 20])", got))
				}

				// ...and the same tab whose file CHANGED while we were closed drops
				// them rather than restoring offsets onto shifted text.
				//
				// The replacement is chosen so that ONLY the stamp check can save
				// it: 6 and 20 are still real line starts in the new file, so the
				// per-entry line-start filter accepts them and the bookmarks come
				// back pointing at two lines nobody marked. A first version of this
				// case used a file with completely different line lengths, and it
				// passed with the stamp check deleted -- the filter was doing the
				// work and the assertion was proving the wrong thing. The size also
				// differs (37 vs 26), which is the half of the stamp that does not
				// depend on filesystem clock granularity.
				plat.file_write_atomic(clean, transmute([]u8)string("AAAAA\nBBBBB\nCCCCCCC\nDDDDD\nEXTRA LINE\n"))
				{
					c: App
					defer app_destroy(&c)
					session_restore(&c)
					d := app_active(&c)
					got := d != nil ? fmt.tprintf("%v", d.bookmarks[:]) : "<no tab>"
					bm_chk(bad, d != nil && len(d.bookmarks) == 0, fmt.tprintf("a changed disk stamp drops them: %s (want [])", got))
				}

				// A DIRTY tab restores from its backup, which is the buffer exactly
				// as it was, so the offsets are good regardless of what the file on
				// disk did.
				{
					a: App
					defer app_destroy(&a)
					d := new(Document)
					d^ = doc_from_content(transmute([]u8)strings.clone(fix), "", .UTF8)
					set(d, {6, 12})
					app_add(&a, d)
					session_save(&a)
				}
				{
					b: App
					defer app_destroy(&b)
					session_restore(&b)
					d := app_active(&b)
					got := d != nil ? fmt.tprintf("%v", d.bookmarks[:]) : "<no tab>"
					bm_chk(bad, d != nil && len(d.bookmarks) == 2 && d.bookmarks[0] == 6 && d.bookmarks[1] == 12, fmt.tprintf("an untitled dirty tab restores from its backup: %s (want [6 12])", got))
				}

				// A hand-written format 4 line still loads -- the tolerant ladder.
				// Written by hand because session_save can only produce the CURRENT
				// format, so nothing else in this mode can prove an older one still
				// reads (the shape §6z's viewmemtest fix used).
				//
				// The path deliberately CONTAINS A SPACE, and that is what makes
				// this case able to fail. The field count is the argument to
				// split_n, which caps the split rather than requiring it, so
				// reading a v4 line with v5's count of 14 still works for a
				// space-free path -- a first version of this case used one and
				// passed with the ladder collapsed to `case ver >= 4: nf = 14`.
				// With a space in the path that same collapse splits the path in
				// two, the line comes back with 14 parts, and the tab is dropped.
				v4 := fmt.tprintf("%s%cnewtpad bm v4.txt", tmp, '\\')
				plat.file_write_atomic(v4, transmute([]u8)fix)
				{
					line := fmt.tprintf("12 12 0 0 0 -1 0 0 0 0 0 0 %s\n", v4)
					plat.file_write_atomic(sp, transmute([]u8)fmt.tprintf("newtpad-session 4\nactive 0\n%s", line))
					e: App
					defer app_destroy(&e)
					ok := session_restore(&e)
					d := app_active(&e)
					good := ok && d != nil && d.path == v4 && d.cursor == 12 && len(d.bookmarks) == 0
					bm_chk(bad, good, fmt.tprintf("a v4 session still loads, with no bookmarks: ok=%v path=%q cursor=%d bookmarks=%v", ok, d != nil ? d.path : "", d != nil ? d.cursor : -1, d != nil ? d.bookmarks[:] : nil))
				}

				// A v5 line whose bookmark field is nonsense, out of order, or names
				// something that is not a line start: each entry is dropped on its
				// own and the tab still restores. 6 and 20 are line starts in the
				// fixture; 7 is mid-line, 4 is out of order after 6, "zz" is not a
				// number, and 9999 is past the end.
				{
					line := fmt.tprintf("0 0 0 0 0 -1 %d %d 0 0 0 0 7,6,4,zz,9999,20 %s\n", plat.file_stamp(v4).mtime, plat.file_stamp(v4).size, v4)
					plat.file_write_atomic(sp, transmute([]u8)fmt.tprintf("newtpad-session 5\nactive 0\n%s", line))
					f: App
					defer app_destroy(&f)
					ok := session_restore(&f)
					d := app_active(&f)
					good := ok && d != nil && len(d.bookmarks) == 2 && d.bookmarks[0] == 6 && d.bookmarks[1] == 20
					bm_chk(bad, good, fmt.tprintf("a hand-edited bookmark field keeps only the valid, ascending line starts: %v (want [6 20])", d != nil ? d.bookmarks[:] : nil))
				}

				// A session that RECORDED a backup whose file is gone. The tab falls
				// through to a reopen from disk, so the offsets are once again
				// offsets against a file we did not write -- the stamp check has to
				// run. Keying the gate off `bidx >= 0` ("a backup was recorded")
				// rather than off "the backup loaded" skipped it, and a dirty tab
				// whose backup was swept came back with marks measured against a
				// buffer that no longer exists.
				//
				// bidx 99 has no backup file; the stamp fields are deliberately
				// wrong, and 6 and 20 ARE line starts in the file, so only the stamp
				// check can drop them.
				{
					line := fmt.tprintf("0 0 0 0 0 99 12345 999 0 0 0 0 6,20 %s\n", v4)
					plat.file_write_atomic(sp, transmute([]u8)fmt.tprintf("newtpad-session 5\nactive 0\n%s", line))
					h: App
					defer app_destroy(&h)
					ok := session_restore(&h)
					d := app_active(&h)
					good := ok && d != nil && d.path == v4 && len(d.bookmarks) == 0
					bm_chk(bad, good, fmt.tprintf("a recorded-but-missing backup still gets the stamp check: ok=%v path=%q bookmarks=%v (want [])", ok, d != nil ? d.path : "", d != nil ? d.bookmarks[:] : nil))
				}

				// A path with spaces still splits correctly with the extra field in
				// front of it -- the reason the bookmark token may never contain one.
				spaced := fmt.tprintf("%s%cnewtpad bm spaced.txt", tmp, '\\')
				plat.file_write_atomic(spaced, transmute([]u8)fix)
				{
					a: App
					defer app_destroy(&a)
					if fd, ok := doc_open(spaced); ok {
						d := new(Document)
						d^ = fd
						set(d, {12})
						app_add(&a, d)
					}
					session_save(&a)
					g: App
					defer app_destroy(&g)
					session_restore(&g)
					d := app_active(&g)
					good := d != nil && d.path == spaced && len(d.bookmarks) == 1 && d.bookmarks[0] == 12
					bm_chk(bad, good, fmt.tprintf("a path with spaces survives the new field: path=%q bookmarks=%v", d != nil ? d.path : "", d != nil ? d.bookmarks[:] : nil))
				}

				os.remove(clean)
				os.remove(v4)
				os.remove(spaced)
				os.remove(sp)
			}
			bm_session(&bad, BM_FIX, bm_set)

			fmt.printfln("bookmarktest: %d failures", bad)
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
			key_chk(resolve_key(.Up, false, true, .Editor), .Move_Line_Up, "Alt+Up / Editor")
			key_chk(resolve_key(.Down, false, true, .Editor), .Move_Line_Down, "Alt+Down / Editor")
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

			// Enter must write the document's own terminator. A bare '\n' in a CRLF
			// file silently mixes line endings, and doc.eol is only detected at open,
			// so the status bar keeps saying CRLF and nothing tells the user.
			nl: Document
			nl.pt = base.pt_init(transmute([]u8)string("hello\r\nworld\r\n"))
			defer base.pt_destroy(&nl.pt)
			nl.eol = .CRLF
			nl.cursor, nl.anchor = 5, 5
			doc_insert_newline(&nl)
			got := doc_debug_string(&nl)
			want := "hello\r\n\r\nworld\r\n"
			ok := got == want
			fmt.printfln("  %-6s Enter on CRLF -> %q (want %q)", "ok" if ok else "FAIL", got, want)

			// Mirror on LF: the fix must not be a hardcoded CRLF.
			nl2: Document
			nl2.pt = base.pt_init(transmute([]u8)string("hello\nworld\n"))
			defer base.pt_destroy(&nl2.pt)
			nl2.eol = .LF
			nl2.cursor, nl2.anchor = 5, 5
			doc_insert_newline(&nl2)
			got2 := doc_debug_string(&nl2)
			want2 := "hello\n\nworld\n"
			ok2 := got2 == want2
			fmt.printfln("  %-6s Enter on LF   -> %q (want %q)", "ok" if ok2 else "FAIL", got2, want2)

			// .Mixed (a file that already disagrees with itself) falls through to
			// the same LF path as .LF -- this was verified by inspection only until
			// now; same buffer as the LF case above, so a bare LF is the only
			// possible right answer either way.
			nl2m: Document
			nl2m.pt = base.pt_init(transmute([]u8)string("hello\nworld\n"))
			defer base.pt_destroy(&nl2m.pt)
			nl2m.eol = .Mixed
			nl2m.cursor, nl2m.anchor = 5, 5
			doc_insert_newline(&nl2m)
			got2m := doc_debug_string(&nl2m)
			want2m := "hello\n\nworld\n"
			ok2m := got2m == want2m
			fmt.printfln("  %-6s Enter on Mixed -> %q (want %q)", "ok" if ok2m else "FAIL", got2m, want2m)

			// Enter must replace an active selection exactly as doc_insert_rune does,
			// not just splice in beside it -- otherwise Enter with a selection active
			// behaves differently from typing any other character.
			nl3: Document
			nl3.pt = base.pt_init(transmute([]u8)string("hello\r\nworld\r\n"))
			defer base.pt_destroy(&nl3.pt)
			nl3.eol = .CRLF
			nl3.anchor, nl3.cursor = 7, 12 // selects "world"
			doc_insert_newline(&nl3)
			got3 := doc_debug_string(&nl3)
			want3 := "hello\r\n\r\n\r\n"
			ok3 := got3 == want3
			fmt.printfln("  %-6s Enter replaces selection -> %q (want %q)", "ok" if ok3 else "FAIL", got3, want3)

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
			// Same real-clipboard concern as blocktest's Paste case (block_test_ai,
			// above the seltest section): this is a genuine set/get round trip
			// against the real Windows clipboard, so save whatever was there and
			// restore it afterward rather than leaving the user's copied text
			// overwritten with this fixture's sentinel. Nothing to restore (empty
			// clipboard, or non-text content) is left alone, not blanked.
			saved_clip, had_clip := plat.clipboard_get_text(nil, context.allocator)
			plat.clipboard_set_text(nil, "clip round-trip ✓")
			if g, gok := plat.clipboard_get_text(nil, context.temp_allocator); gok {
				fmt.printfln("clipboard   : %q", g)
			}
			if had_clip {
				plat.clipboard_set_text(nil, saved_clip)
				delete(saved_clip)
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
			// Replace one match at a time and confirm the reported count never
			// collapses to zero while the search is still restarting.
			total0 := len(doc.find.matches)
			zeroed := false
			for i in 0 ..< min(total0, 5) {
				find_replace_current(&doc)
				// Read the status figure the way render_frame does, without waiting.
				if len(doc.find.matches) == 0 && search_running(&doc) && doc.find.last_total == 0 {
					zeroed = true
				}
				find_wait(&doc)
				_ = i
			}
			fmt.printfln("count stable across replaces: %v (started at %d)", !zeroed, total0)
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
} else {
	// main.odin calls this unconditionally; with the harness gated out it must
	// still exist and must always decline, so argv falls through to the normal
	// "open this path" handling.
	test_mode_dispatch :: proc() -> (handled: bool) {
		return false
	}
}
