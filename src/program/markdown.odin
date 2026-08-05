// Layer: program — a markdown renderer + preview, toggled per document (Ctrl+M
// cycles Off -> Preview -> Split). Like the table view, the underlying text is
// untouched; this lays the source out with headings, emphasis, code, lists,
// quotes, rules, links and simple tables. Bounded like every viewport pass:
// rendering walks source lines from a scroll offset and stops when the pane
// fills, so a huge markdown file previews without parsing all of it.
//
// Line-based CLASSIFICATION, deliberately: a block's kind comes from its own
// prefix (md_classify is pure -- one line in, one class out, no lookback) and its
// inline content is soft-wrapped to the pane. A block's EXTENT is not line-based:
// md_para_bounds joins a run of prose lines into one CommonMark paragraph and
// absorbs an unmarked line into the list item or blockquote above it. Two
// consequences this header used to list are gone with it -- adjacent lines ARE
// joined now, and a link inside a TABLE cell is clickable again since the cells
// went through the shaper. Emphasis, inline code and tables went the same way in
// batch 17: real bold and italic body faces, a rounded Md_Code_Bg box behind an
// inline code span, and md_table_ensure aligning a table's columns across rows.
package main

import "core:fmt"
import "core:strings"
import "core:unicode/utf8"
import base "src:base"
import plat "src:platform"

// Self-test for the pure parsing (block classifiers + inline runs); the rendering
// itself needs a live eye. Returns the failure count. Driven by `newtpad mdtest`.
md_selftest :: proc() -> (bad: int) {
	chk :: proc(bad: ^int, ok: bool, msg: string) {
		fmt.printfln("  %-40s %s", msg, "OK" if ok else "FAIL")
		if !ok {bad^ += 1}
	}
	// --- fenced code picks a lexer from its tag (batch 16) ---
	//
	// The mapping goes through highlight_lexer_for, so this also asserts the
	// fence and the file extension share one table rather than drifting.
	{
		chk(&bad, md_fence_lexer("```json") != nil, "```json -> a lexer")
		chk(&bad, md_fence_lexer("```cs") != nil, "```cs -> a lexer")
		chk(&bad, md_fence_lexer("~~~yaml") != nil, "~~~yaml -> a lexer")
		// Aliases that are not their own extension.
		chk(&bad, md_fence_lexer("```yml") != nil, "```yml -> a lexer (alias of yaml)")
		chk(&bad, md_fence_lexer("```csharp") != nil, "```csharp -> a lexer (alias of cs)")
		chk(&bad, md_fence_lexer("```bash") != nil, "```bash -> a lexer (alias of sh)")
		// Info strings carry more than the tag in real documents.
		chk(&bad, md_fence_lexer("```js title=\"x\"") != nil, "an info string past the tag is ignored")
		// And the negative cases, or "returns non-nil" proves nothing.
		chk(&bad, md_fence_lexer("```") == nil, "a bare fence has no lexer")
		chk(&bad, md_fence_lexer("```notalanguage") == nil, "an unknown tag has no lexer")
	}

	// --- nested blockquotes, front matter (batch 16) ---
	{
		q1, c1, d1 := md_quote_depth("> one")
		q2, c2, d2 := md_quote_depth(">> two")
		q3, c3, d3 := md_quote_depth("> > spaced")
		q4, _, d4 := md_quote_depth("plain")
		chk(&bad, q1 && d1 == 1 && c1 == "one", "> one -> depth 1")
		// The one that was broken: the second marker used to land in the TEXT.
		chk(&bad, q2 && d2 == 2 && c2 == "two", ">> two -> depth 2, marker not in the text")
		chk(&bad, q3 && d3 == 2 && c3 == "spaced", "> > spaced -> depth 2")
		chk(&bad, !q4 && d4 == 0, "plain -> not a quote")
	}

	// --- GFM strikethrough, escapes, task lists (batch 16) ---
	//
	// Each of these is a construct md_inline silently mis-parsed rather than
	// ignored, which is the worse failure: an unescaped asterisk did not render
	// as an asterisk, it toggled italics and restyled the rest of the line.
	{
		runs := md_inline("a ~~gone~~ b")
		hit := false
		for r in runs {
			if r.strike && r.text == "gone" {hit = true}
		}
		chk(&bad, hit, "~~gone~~ -> a struck run")
		// And the text either side is NOT struck, or the toggle never closed.
		clean := true
		for r in runs {
			if r.strike && r.text != "gone" {clean = false}
		}
		chk(&bad, clean, "...and nothing else on the line is struck")
	}
	{
		// The escape has to survive as a literal AND not toggle the style.
		runs := md_inline("literal \\* star")
		joined := ""
		ital := false
		for r in runs {
			joined = strings.concatenate({joined, r.text}, context.temp_allocator)
			if r.ital {ital = true}
		}
		chk(&bad, joined == "literal * star", "\\* -> a literal asterisk")
		chk(&bad, !ital, "...and it does not open italics")
	}
	{
		// A backslash before a letter is not an escape -- it is a path.
		runs := md_inline("C:\\temp\\file.txt")
		joined := ""
		for r in runs {joined = strings.concatenate({joined, r.text}, context.temp_allocator)}
		chk(&bad, joined == "C:\\temp\\file.txt", "a path keeps its backslashes")
	}

	// --- `_` cannot open/close emphasis intraword; `*` still can (found
	// 2026-07-30 in research/newtpad-research-report.md itself: the source's
	// "(stb_sprintf aside)" drew as "(stbsprintf aside)" with everything after
	// it italicised, because md_inline treated every `_` as a toggle). These
	// assert on the RENDERED RUNS (Md_Run, what markdown_draw actually draws),
	// not just that classification changed, so a fix that reclassifies but
	// still eats the byte would still fail here.
	{
		// The reported defect itself, first: the underscore must survive
		// AND nothing past it may end up italicised.
		runs := md_inline("(stb_sprintf aside)")
		joined := ""
		any_ital := false
		for r in runs {
			joined = strings.concatenate({joined, r.text}, context.temp_allocator)
			if r.ital {any_ital = true}
		}
		chk(&bad, joined == "(stb_sprintf aside)", "stb_sprintf keeps its underscore")
		chk(&bad, !any_ital, "...and nothing after it is italicised")
	}
	{
		// Multiple intraword underscores on one identifier: every one of them
		// is a toggle candidate under the old code, so this is the case that
		// showed the damage scales with underscore count.
		runs := md_inline("snake_case_with_many_underscores")
		joined := ""
		any_style := false
		for r in runs {
			joined = strings.concatenate({joined, r.text}, context.temp_allocator)
			if r.ital || r.bold {any_style = true}
		}
		chk(&bad, joined == "snake_case_with_many_underscores", "snake_case_with_many_underscores survives whole")
		chk(&bad, !any_style, "...and none of it is styled")
	}
	{
		// A standalone `_word_` is still real emphasis -- the fix must not
		// disable `_` entirely, only intraword use of it.
		runs := md_inline("_italic_")
		chk(&bad, len(runs) == 1 && runs[0].text == "italic" && runs[0].ital, "_italic_ -> one italic run, no underscores")
	}
	{
		// One-sided intraword: `_leading` is left-flanking-only (can open,
		// can't close) and `trailing_` is right-flanking-only (can close,
		// can't open). Neither has a partner in its own string, which is
		// exactly the case the single-pass toggle (no delimiter stack) does
		// not resolve correctly -- `_leading` still opens italics with
		// nothing to close it, so the run past the word is left italicised.
		// That is the documented limitation, not a second bug: a real
		// CommonMark parser would leave an unmatched delimiter literal.
		{
			runs := md_inline("_leading")
			chk(&bad, len(runs) == 1 && runs[0].text == "leading" && runs[0].ital,
				"_leading (unmatched opener) opens italics per the flanking rule -- known single-pass limitation")
		}
		{
			// `trailing_` alone: right-flanking only, and we are not already
			// in italics, so it cannot close what was never opened -- stays
			// literal. This is the case that must NOT regress to eating the
			// underscore the way stb_sprintf did.
			runs := md_inline("trailing_")
			joined := ""
			any_ital := false
			for r in runs {
				joined = strings.concatenate({joined, r.text}, context.temp_allocator)
				if r.ital {any_ital = true}
			}
			chk(&bad, joined == "trailing_", "trailing_ (unmatched closer) keeps its underscore literal")
			chk(&bad, !any_ital, "...and does not open italics")
		}
	}
	{
		// Regression guard: `*` intraword is UNCHANGED by the `_` fix.
		// **bold** and *italic* still toggle mid-word, since `*` has no
		// intraword restriction in CommonMark (only `_` does).
		runs := md_inline("wo*rd* mid**bo**ld")
		joined := ""
		saw_ital, saw_bold := false, false
		for r in runs {
			joined = strings.concatenate({joined, r.text}, context.temp_allocator)
			if r.ital {saw_ital = true}
			if r.bold {saw_bold = true}
		}
		chk(&bad, joined == "word midbold", "*/** still toggle intraword (asterisks consumed)")
		chk(&bad, saw_ital, "...*rd* still italicised")
		chk(&bad, saw_bold, "...**bo** still bold")
	}
	{
		// An escaped underscore is untouched by any of this -- md_escapable
		// wins before the flanking test is even reached.
		runs := md_inline("snake\\_case")
		joined := ""
		any_ital := false
		for r in runs {
			joined = strings.concatenate({joined, r.text}, context.temp_allocator)
			if r.ital {any_ital = true}
		}
		chk(&bad, joined == "snake_case", "\\_ -> a literal underscore")
		chk(&bad, !any_ital, "...and it does not open italics")
	}

	{
		r1, d1, t1 := md_task("[ ] todo")
		r2, d2, t2 := md_task("[x] done")
		r3, _, t3 := md_task("[y] neither")
		r4, _, t4 := md_task("not a task")
		chk(&bad, t1 && !d1 && r1 == "todo", "[ ] todo -> unticked task")
		chk(&bad, t2 && d2 && r2 == "done", "[x] done -> ticked task")
		chk(&bad, !t3 && r3 == "[y] neither", "[y] is not a task box")
		chk(&bad, !t4 && r4 == "not a task", "plain text is not a task")
	}
	// --- front matter draws as ONE card, not a bar per line (live pass 0.27) ---
	//
	// Wyatt: "I see like a quote bar on the side but it's thinner" -- the old
	// code drew a 2px Md_Rule at the left of every front-matter line, which is
	// the blockquote's own decoration. Two assertions, and the second is the
	// one the old shape fails: exactly one quad comes back (the pre-fix shape
	// is N of them, one per line), and NONE of them is Md_Rule. The panel's
	// height is checked against the block, since "one quad" alone would also
	// be satisfied by a single 2px bar.
	{
		old_theme := g_theme
		defer g_theme = old_theme
		g_theme = theme_dark()
		x0, x1, ytop, line_h := f32(40), f32(600), f32(100), f32(20)
		// The delimiters are ROWS again (item 3, 2026-07-29). Stated as a
		// number here so the card's height and md_draw_front_matter's row walk
		// cannot both drop them and still agree with each other.
		chk(&bad, md_fm_rows(0) == 2, fmt.tprintf("an empty front-matter block still draws its two `---` rows (%d)", md_fm_rows(0)))
		chk(&bad, md_fm_rows(3) == 5, fmt.tprintf("3 key/value lines -> 5 rows, the two delimiters included (%d)", md_fm_rows(3)))
		for inner in ([]int{1, 4, 12}) {
			q: [MD_FM_MAX_LINES + 2]plat.Quad
			n := md_front_matter_quads(x0, x1, ytop, line_h, inner, q[:])
			chk(&bad, n == 1, fmt.tprintf("%d-line front matter -> exactly 1 quad (%d)", inner, n))
			if n != 1 {continue}
			rules := 0
			for i in 0 ..< n {
				if q[i].color == g_theme[.Md_Rule] {rules += 1}
			}
			chk(&bad, rules == 0, fmt.tprintf("%d-line front matter -> no Md_Rule quad (%d)", inner, rules))
			chk(&bad, q[0].color == g_theme[.Md_Code_Bg], fmt.tprintf("%d-line front matter -> the card is Md_Code_Bg", inner))
			// It spans the block, not one row: the panel must cover every inner
			// line's row, the TWO DELIMITER rows (item 3, 2026-07-29 -- the
			// `---` lines are drawn as muted text on the card now, so they take
			// rows the card has to cover), plus an inset above the first and
			// below the last.
			//
			// Written out as `inner + 2` rather than through md_fm_rows on
			// purpose: this is the arithmetic the test STATES, so dropping the
			// delimiter rows from md_fm_rows fails here instead of quietly
			// moving both sides together.
			pad := md_fm_pad()
			want_h := f32(inner + 2) * line_h + pad * 2
			chk(&bad, pad > 0 && q[0].size.y == want_h, fmt.tprintf("%d-line front matter -> card covers the block + inset (%.1f == %.1f)", inner, q[0].size.y, want_h))
			// And it starts at the skipped fence's row rather than reaching up
			// past the pane's top edge.
			chk(&bad, q[0].pos.y == ytop, fmt.tprintf("%d-line front matter -> card top is the fence's own row (%.1f == %.1f)", inner, q[0].pos.y, ytop))
			// And it is a PANEL: full content width and rounded, not a bar.
			chk(&bad, q[0].size.x == x1 - x0 && q[0].radius[0] > 0, fmt.tprintf("%d-line front matter -> full-width, rounded panel", inner))
		}
		// The card's height comes from md_front_matter_end's inner count, so
		// that count is checked against real documents too -- a card sized from
		// a wrong count is the same bug one level up.
		//
		// Its own procedure so md_selftest's frame does not also carry a
		// Document; `content` is DEFAULT-allocated on purpose, since
		// doc_from_content sets owned_orig and doc_close frees it.
		md_fm_probe :: proc(src: string) -> (end, inner: int) {
			content := make([]u8, len(src))
			copy(content, src)
			doc := doc_from_content(content, "fm.md", .UTF8)
			defer doc_close(&doc)
			return md_front_matter_end(&doc)
		}
		{
			e1, i1 := md_fm_probe("---\ntitle: x\ntags: y\n---\nbody\n")
			chk(&bad, e1 == len("---\ntitle: x\ntags: y\n---\n") && i1 == 2, fmt.tprintf("two keys between the fences -> end %d, inner %d", e1, i1))
			e2, i2 := md_fm_probe("---\n...\nbody\n")
			chk(&bad, e2 == len("---\n...\n") && i2 == 0, fmt.tprintf("an empty block closed by ... -> end %d, inner %d", e2, i2))
			e3, i3 := md_fm_probe("---\ntitle: x\nnever closed\n")
			chk(&bad, e3 == 0 && i3 == 0, fmt.tprintf("an unclosed opener is not front matter (end %d, inner %d)", e3, i3))
			e4, i4 := md_fm_probe("# heading\n---\nnot front matter\n")
			chk(&bad, e4 == 0 && i4 == 0, fmt.tprintf("a `---` that is not on line 1 is a rule (end %d, inner %d)", e4, i4))
		}
	}

	// --- a done task item mutes EVERY colour, not just the prose (live pass 0.27) ---
	//
	// Two halves, and only the second one is about the defect.
	//
	// (a) MD_DONE_MUTE reproduces each theme's own muted tier -- roughly. This is
	// what makes 0.26 a derived placeholder rather than a number picked by eye,
	// but it is explicitly marked PLACEHOLDER in its own comment (see
	// MD_DONE_MUTE) precisely because it is Wyatt's to eye-tune on the next live
	// pass. A prior version of this test bound the miss to 0.05 per channel,
	// which is tight enough that the two built-ins' own disagreement (Dark wants
	// ~0.298, Light ~0.220) leaves an intersection of roughly [0.232, 0.264] --
	// 0.003 from the shipped 0.26, not the "[0.19, 0.33]" that comment claimed
	// (2026-07 review, Finding 3). A plausible eye-tune (0.30) already fails it.
	//
	// So this asserts DIRECTION AND ORDERING instead of pinning a tier -- the
	// property that has to hold whatever Wyatt retunes MD_DONE_MUTE to, not just
	// at today's 0.26: muting must move STRICTLY toward the page (rules out
	// k <= 0, "no mute happened") and must not overshoot past Bg_Base (rules out
	// k >= 1, "muted all the way to invisible"). The "lands near Text_Muted"
	// reading is kept too, widened to 0.10 -- comfortably past both themes' own
	// spread AND past a same-ballpark future retune -- so it still catches "the
	// constant regressed to something unreasonable" without being a tripwire on
	// "the constant moved". If a retune DOES trip this, the message says why.
	{
		old_theme := g_theme
		defer g_theme = old_theme
		for th, ti in ([]Theme{theme_dark(), theme_light()}) {
			g_theme = th
			name := "dark" if ti == 0 else "light"
			bg := g_theme[.Bg_Base]
			primary := g_theme[.Text_Primary]
			got := md_mute(primary, MD_DONE_MUTE)
			toward := true
			for i in 0 ..< 3 {
				if abs(got[i] - bg[i]) >= abs(primary[i] - bg[i]) {toward = false}
			}
			chk(&bad, toward, fmt.tprintf("%s: mute(Text_Primary, MD_DONE_MUTE) moves strictly toward Bg_Base", name))
			want := g_theme[.Text_Muted]
			worst := f32(0)
			for i in 0 ..< 3 {worst = max(worst, abs(got[i] - want[i]))}
			chk(
				&bad,
				worst <= 0.10,
				fmt.tprintf(
					"%s: mute(Text_Primary, MD_DONE_MUTE) is in the ballpark of Text_Muted (worst %.3f) -- MD_DONE_MUTE is a documented PLACEHOLDER; if retuning it trips this, widen THIS bound, it is not a regression",
					name, worst,
				),
			)
			// Alpha is a compositing decision, not a tone: it must survive.
			chk(&bad, got.a == g_theme[.Text_Primary].a, fmt.tprintf("%s: muting leaves alpha alone", name))
		}
		g_theme = theme_dark()
		bg := g_theme[.Bg_Base]
		// One line exercising every role md_run_color can pick: bold
		// (Text_Bright), code (Md_Code), a link (Link) and italics (Md_Italic).
		runs := md_inline("plain **bold** `code` [label](http://u) *ital*")
		styled := 0
		for run in runs {
			lit := md_run_color(run, g_theme[.Text_Muted], 0)
			dim := md_run_color(run, g_theme[.Text_Muted], MD_DONE_MUTE)
			if !(run.bold || run.code || run.link || run.ital) {continue}
			styled += 1
			// It moved at all -- this is the assertion the old code fails: it
			// returned `lit` for every themed run regardless of the mute.
			moved := lit != dim
			// ...and it moved TOWARD the page, not to some unrelated colour.
			toward := true
			for i in 0 ..< 3 {
				if abs(dim[i] - bg[i]) > abs(lit[i] - bg[i]) {toward = false}
			}
			chk(&bad, moved && toward, fmt.tprintf("styled run %q mutes toward the page", run.text))
		}
		chk(&bad, styled == 4, fmt.tprintf("...and the fixture really produced 4 themed runs (%d)", styled))
		// The DEFAULT run -- plain prose carrying no role of its own -- is what
		// Finding 1 (2026-07 review) got wrong and the block above cannot catch,
		// since it only walks STYLED runs. Driven through md_task_prose_style,
		// the exact procedure markdown_draw's task branch calls: the bug was
		// task_col = Text_Muted (an already-muted base), so a plain run muted
		// TWICE and landed well past Text_Muted toward Bg_Base, not on it.
		plain_col, plain_mute := md_task_prose_style(true)
		plain_checked := false
		for run in runs {
			if run.bold || run.code || run.link || run.ital || run.strike {continue}
			got := md_run_color(run, plain_col, plain_mute)
			want := g_theme[.Text_Muted]
			worst := f32(0)
			for i in 0 ..< 3 {worst = max(worst, abs(got[i] - want[i]))}
			chk(&bad, worst <= 0.10, fmt.tprintf("done item's plain run %q mutes to Text_Muted's own tier, not past it (worst %.3f)", run.text, worst))
			plain_checked = true
		}
		chk(&bad, plain_checked, "...and the fixture produced a plain run to check")
	}

	// --- the ticked checkbox's tick is centred on the BOX (live pass 0.27) ---
	//
	// Wyatt: "the X is at the bottom right of the box, not in the center". The
	// tick is now geometry, so its placement is measurable without a device:
	// take the union bounding box of the quads md_tick_quads emits and compare
	// its centre against the box's. Run at three UI scales, because the
	// stroke width is hairline() (scale-dependent) while the box size is not,
	// and an off-by-one-stroke centring error only shows up when they differ.
	{
		old_scale := UI_SCALE
		defer UI_SCALE = old_scale
		for scale in ([]f32{1.0, 1.5, 2.0}) {
			UI_SCALE = scale
			bx, by := f32(100), f32(200)
			bs := f32(11.2) * scale
			tq: [MD_TICK_STEPS * 2]plat.Quad
			n := md_tick_quads(bx, by, bs, {1, 1, 1, 1}, tq[:])
			chk(&bad, n >= 4, fmt.tprintf("scale %.1f: the tick draws at all (%d quads)", scale, n))
			if n == 0 {continue}
			lo, hi := tq[0].pos, tq[0].pos + tq[0].size
			for q in tq[1:n] {
				lo = {min(lo.x, q.pos.x), min(lo.y, q.pos.y)}
				hi = {max(hi.x, q.pos.x + q.size.x), max(hi.y, q.pos.y + q.size.y)}
			}
			cx, cy := (lo.x + hi.x) * 0.5, (lo.y + hi.y) * 0.5
			bcx, bcy := bx + bs * 0.5, by + bs * 0.5
			// The tolerance is 0.05px, not the "within one pixel" the task
			// asked for, and deliberately: md_tick_quads centres EXACTLY by
			// construction (each diagonal's f runs 0 ..= arm-st and a step is
			// st wide, so the union spans exactly arm), leaving only float
			// error. A 1px tolerance was measured to ADMIT the defect -- the
			// shipped `bx + bs*0.28` origin offset is 0.34px off centre at
			// scale 1, so it passed a 1px bound and the assertion proved
			// nothing. A bound that cannot reject the bug is not a test.
			chk(&bad, abs(cx - bcx) <= 0.05 && abs(cy - bcy) <= 0.05, fmt.tprintf("scale %.1f: tick centre (%.2f,%.2f) is the box centre (%.2f,%.2f)", scale, cx, cy, bcx, bcy))
			// ...and it stays inside the box, or "centred" could be satisfied by
			// a tick that overhangs symmetrically.
			chk(&bad, lo.x >= bx && lo.y >= by && hi.x <= bx + bs && hi.y <= by + bs, fmt.tprintf("scale %.1f: tick stays inside the box", scale))
		}
		// --- the degenerate case: a box smaller than 4*st (Finding 5, 2026-07
		// review) ---
		//
		// Every case above uses `bs = 11.2*scale`, which never gets close to
		// `st*2` (the OTHER side of `arm`'s max), so the clamp this exercises was
		// never reached by the fixture above -- `chk`'s own "stays inside the
		// box" assertion could not have caught the bug it was meant to catch.
		// Unclamped, `arm := max(st*2, bs*0.5)` picks `st*2` here and OVERSHOOTS
		// `bs`, pushing the tick's origin (`bx + (bs-arm)*0.5`) past `bx` itself.
		{
			UI_SCALE = 1
			bx, by := f32(300), f32(400)
			bs := f32(1.5) // < 4*st (st=1 at UI_SCALE 1)
			tq: [MD_TICK_STEPS * 2]plat.Quad
			n := md_tick_quads(bx, by, bs, {1, 1, 1, 1}, tq[:])
			chk(&bad, n >= 4, fmt.tprintf("degenerate box (bs=%.1f < 4*st): the tick draws at all (%d quads)", bs, n))
			if n > 0 {
				lo, hi := tq[0].pos, tq[0].pos + tq[0].size
				for q in tq[1:n] {
					lo = {min(lo.x, q.pos.x), min(lo.y, q.pos.y)}
					hi = {max(hi.x, q.pos.x + q.size.x), max(hi.y, q.pos.y + q.size.y)}
				}
				chk(
					&bad, lo.x >= bx && lo.y >= by && hi.x <= bx + bs && hi.y <= by + bs,
					fmt.tprintf("degenerate box (bs=%.1f): tick stays inside it (got [%.2f,%.2f]-[%.2f,%.2f], box [%.2f,%.2f]-[%.2f,%.2f])", bs, lo.x, lo.y, hi.x, hi.y, bx, by, bx + bs, by + bs),
				)
			}
		}
	}
	chk(&bad, md_heading_level("# H") == 1, "# H -> h1")
	chk(&bad, md_heading_level("### H") == 3, "### H -> h3")
	chk(&bad, md_heading_level("####### H") == 0, "7 hashes -> not a heading")
	chk(&bad, md_heading_level("#nospace") == 0, "no space -> not a heading")
	chk(&bad, md_heading_level("plain") == 0, "plain -> not a heading")
	chk(&bad, md_is_rule("---"), "--- is a rule")
	chk(&bad, md_is_rule("***"), "*** is a rule")
	chk(&bad, !md_is_rule("- item"), "- item is not a rule")
	// md_setext_level, and the rows that matter are the ones where it must DIVERGE
	// from md_is_rule -- `***` and `- - -` are thematic breaks that can never
	// underline anything, and `-` and `--` are underlines md_is_rule's three-character
	// minimum rejects.
	chk(&bad, md_setext_level("===") == 1, "=== underlines an h1")
	chk(&bad, md_setext_level("=") == 1, "a single = does too")
	chk(&bad, md_setext_level("---") == 2, "--- underlines an h2")
	chk(&bad, md_setext_level("-") == 2, "a single - does too")
	chk(&bad, md_setext_level("--") == 2, "and so does --")
	chk(&bad, md_setext_level("   ---  ") == 2, "3 spaces of indent and trailing space are allowed")
	chk(&bad, md_setext_level("    ---") == 0, "4 spaces are not")
	chk(&bad, md_setext_level("***") == 0, "*** underlines nothing")
	chk(&bad, md_setext_level("___") == 0, "___ underlines nothing")
	chk(&bad, md_setext_level("- - -") == 0, "a spaced-out rule underlines nothing")
	chk(&bad, md_setext_level("=-=") == 0, "mixed characters underline nothing")
	chk(&bad, md_setext_level("") == 0, "an empty line underlines nothing")
	chk(&bad, md_setext_level("   ") == 0, "a blank line underlines nothing")
	chk(&bad, md_setext_level("- item") == 0, "a list item underlines nothing")
	{
		q, c := md_quote("> hi there")
		chk(&bad, q && c == "hi there", "> hi -> quote 'hi there'")
	}
	{
		b, c, d := md_list("- item")
		chk(&bad, b == "•" && c == "item" && d == 0, "- item -> bullet depth 0")
	}
	{
		b, c, d := md_list("    - nested")
		chk(&bad, b == "•" && c == "nested" && d == 2, "4-space - nested -> depth 2")
	}
	{
		b, c, _ := md_list("3. third")
		chk(&bad, b == "3." && c == "third", "3. third -> ordered")
	}
	{
		runs := md_inline("a **b** c")
		ok := len(runs) == 3 && runs[0].text == "a " && runs[1].text == "b" && runs[1].bold && runs[2].text == " c"
		chk(&bad, ok, "a **b** c -> [a ][B:b][ c]")
	}
	{
		runs := md_inline("x `code` y")
		ok := len(runs) == 3 && runs[1].text == "code" && runs[1].code
		chk(&bad, ok, "x `code` y -> code run")
	}
	{
		runs := md_inline("see [label](http://u)")
		ok := len(runs) >= 2 && runs[len(runs) - 1].link && runs[len(runs) - 1].text == "label" && runs[len(runs) - 1].url == "http://u"
		chk(&bad, ok, "[label](url) -> link run")
	}
	return
}

Md_Mode :: enum u8 {
	Off,
	Preview, // full-window rendered view (read-only)
	Split, // editor left, live preview right
}

md_mode_name :: proc(m: Md_Mode) -> string {
	switch m {
	case .Off:
		return "Off"
	case .Preview:
		return "Preview"
	case .Split:
		return "Split"
	}
	return "?"
}

// Column widths depend on the whole table block, so measuring them from the
// visible rows only would make them a function of scroll position — columns that
// shift as you scroll. The measure is therefore hoisted out of the draw and
// cached per block, keyed on the buffer revision. Within a block the widths are
// constant by construction, which is what makes shift-free scrolling a property
// of the design rather than something to test for.
//
// A block is bounded by content (it ends at the first non-table line), so the
// normal measure is O(block), not O(file). Past MD_TABLE_BUDGET the block skips
// measurement entirely and draws on fixed columns instead — O(1), not O(block):
// deterministic per row, so still shift-free, just not content-sized.
// Content-sizing an arbitrarily large block would need a background worker; see
// the batch-1 spec for why that is deferred.
MD_TABLE_BUDGET :: 1 * 1024 * 1024
MD_TABLE_MAX_COLS :: 32
MD_TABLE_FIXED_CELLS :: 16 // fixed column width past the budget
MD_TABLE_PAD :: 2 // cells of gap between columns

// The clamps md_table_fit_cells fits a table's natural columns to the measure
// with. UI spec §10 gives the TABLE VIEW's rule -- "measure the first 200 rows,
// clamp each column to 8-40 characters, distribute leftover width proportionally"
// -- and the shape of it applies here even though §10 governs a different surface:
// the natural widths are already measured per block (md_table_measure), the upper
// clamp is reused verbatim, and the leftover distribution is the same
// water-filling.
//
// The LOWER clamp is where this deliberately diverges from §10's 8. A CSV grid's
// columns are all data, so eight characters is a sensible floor; a markdown table
// routinely has a one-character column (`| x |`, a tick, an index) and clamping
// that up to eight would spend a third of a 3-column measure on it and take the
// width from the prose column that needed it. The floor here is only what keeps a
// column from collapsing to nothing under pressure, and it is SOFT: md_table_fit_
// cells lowers it toward 1 rather than dropping a column, because a dropped column
// is lost data and §10's own "malformed rows are marked, not hidden" is the same
// instinct.
MD_TABLE_MIN_CELLS :: 4
MD_TABLE_MAX_CELLS :: 40 // §10's upper clamp, reused

// The byte budget alone does not bound the WORK of finding a block's edges: a
// renamed CSV with 20-byte rows and the 1 MB budget is ~50k short rows in each
// direction, each costing a capped line-start scan plus a capped line-end scan
// (two 4 KB pt_reads and a treap descent apiece) before the byte guard ever
// trips. This caps the row COUNT per direction the same way MD_TABLE_BUDGET
// caps the byte span per direction, so the expensive scan itself is bounded
// even on pathologically short rows.
//
// The per-row cost is a FIXED 4 KB pt_read in each capped helper regardless of
// how short the row actually is (pt_line_start_cap and pt_line_end_cap both
// read in 4 KB chunks against RENDER_LINE_CAP), so the row cap's true worst
// case at the original 4096 was roughly 4096 rows * 2 reads backward + 4096 *
// 1 read forward + up to 4096 * 1 read in the (non-oversize) measure pass over
// the same span - about 50-67 MB copied and ~12k pt_reads on the single frame
// that enters an ordinary pipe-delimited log file, repeating on every revision
// bump, i.e. every keystroke in Split mode. 1024 is still far more rows than
// any screenful or any hand-authored table (a real table is a few dozen rows
// at most), cuts that worst case ~4x, and the fallback past it is the O(1)
// fixed-column path, not a correctness loss.
MD_TABLE_MAX_ROWS :: 1024

// md_table_bounds derives `oversize` from the byte budget and MD_TABLE_MAX_ROWS
// together (see the entry-dependence comment in md_table_bounds). If the budget
// were not comfortably larger than one capped line, the forward scan's very
// first guard check (against the entry row's own length) could trip before a
// single neighbour row is examined, collapsing the cache window to one row
// regardless of the true block size.
#assert(MD_TABLE_BUDGET > RENDER_LINE_CAP)

// Runtime copy of MD_TABLE_BUDGET. Production code never changes it; mdtabletest
// lowers it to drive md_table_bounds into the oversize path on a normal-sized
// fixture instead of needing a real >1 MB buffer to build and scan.
md_table_budget := MD_TABLE_BUDGET

// Runtime copy of MD_TABLE_MAX_ROWS, mirroring md_table_budget: production code
// never changes it; mdtabletest lowers it to drive the row-count guard on a
// normal-sized fixture instead of needing thousands of rows built and scanned.
md_table_max_rows := MD_TABLE_MAX_ROWS

// A paragraph's join budget, in bytes, and its line-count analogue. Mirrors
// MD_TABLE_BUDGET/MD_TABLE_MAX_ROWS and exists for the same reason: joining
// stops at the first blank or non-Para line, so a file with no blank line in it
// would otherwise be walked to EOF on the UI thread by the first block.
//
// 256 KB rather than the table's 1 MB because a paragraph is prose: at ~100
// columns a 256 KB run is ~2,600 source lines, which no document has, while a
// CSV that is one enormous table is an ordinary file.
MD_PARA_BUDGET :: 256 * 1024
MD_PARA_MAX_LINES :: 4096

// Required by the forward scan's guard, exactly as MD_TABLE_BUDGET's own assert
// requires: without it the first check could trip on the entry line's length
// alone, before a single neighbour line is examined, collapsing every paragraph
// to one line and making the whole join invisible.
#assert(MD_PARA_BUDGET > RENDER_LINE_CAP)

// Runtime copies, mirroring md_table_budget/md_table_max_rows: production code
// never changes them; mdjointest lowers them to drive the truncation path on a
// small fixture instead of building a 256 KB one.
md_para_budget := MD_PARA_BUDGET
md_para_max_lines := MD_PARA_MAX_LINES

// Four slots, not one: rows draw top-to-bottom, so with two table blocks on
// screen a single slot ends every frame holding the lower block and misses on
// the upper one the next frame — two full block measures per frame, in steady
// state, forever. Fixed-size array, so still no allocation.
MD_TABLE_SLOTS :: 4

Md_Align :: enum u8 {
	Left,
	Center,
	Right,
}

Md_Table_Cache :: struct {
	valid:    bool,
	start:    int, // byte offset of the block's first row
	end:      int, // offset of the last row's newline (pt_line_end_cap semantics)
	revision: u64,
	// The bounds this entry was MEASURED under, and part of its key -- see
	// md_table_ensure. Md_Para_Cache carries the same two fields for the same
	// reason; this struct did not, and the difference was a live defect.
	budget:   int,
	max_rows: int,
	oversize: bool, // block exceeded MD_TABLE_BUDGET: fixed columns
	ncols:    int,
	widths:   [MD_TABLE_MAX_COLS]int, // cells, excluding padding
	align:    [MD_TABLE_MAX_COLS]Md_Align,
}

// A markdown table row, by the same test the renderer already used.
md_is_table_row :: proc(line: string) -> bool {
	return strings.contains(line, "|") && strings.count(line, "|") >= 2
}

// Split a row into cells, preserving empty ones. Strips at most one leading and
// one trailing pipe rather than trimming a character set from both ends — the
// old strings.trim(line, "| ") ate empty leading cells outright.
md_split_cells :: proc(line: string, allocator := context.temp_allocator) -> []string {
	s := strings.trim_right(line, " \t")
	if strings.has_prefix(s, "|") {s = s[1:]}
	if strings.has_suffix(s, "|") {s = s[:len(s) - 1]}
	parts := strings.split(s, "|", allocator)
	for &p in parts {p = strings.trim_space(p)}
	return parts
}

// Alignment markers on a separator cell: :--- / :--: / ---: / ---
@(private = "file")
md_cell_align :: proc(cell: string) -> Md_Align {
	c := strings.trim_space(cell)
	left := strings.has_prefix(c, ":")
	right := strings.has_suffix(c, ":")
	switch {
	case left && right:
		return .Center
	case right:
		return .Right
	}
	return .Left
}

// Read one line at `p` into `buf`, trailing CR removed. Returns the line, the
// offset of its end (at the newline, or the buffer end), and whether that end
// is a synthetic RENDER_LINE_CAP break rather than a real newline or EOF — a
// single row longer than the cap, which the caller must treat as a truncation
// of its own scan, not a real line boundary.
@(private = "file")
md_line_at :: proc(doc: ^Document, p: int, buf: []u8) -> (line: string, end: int, capped: bool) {
	end = base.pt_line_end_cap(&doc.pt, p, RENDER_LINE_CAP)
	capped = end < doc.pt.length && end - p >= RENDER_LINE_CAP
	n := base.pt_read(&doc.pt, p, buf[:min(end - p, len(buf))])
	if n > 0 && buf[n - 1] == '\r' {n -= 1}
	return string(buf[:n]), end, capped
}

// The contiguous run of table rows containing `p`. Scans backward to the block's
// true start and forward to its end, both bounded by md_table_budget so a file
// that is one enormous table cannot stall a frame.
//
// `p` need NOT be a line start. markdown_draw walks a line longer than
// RENDER_LINE_CAP in capped segments (`p = end + 1` where `end` came from
// `pt_line_end_cap`), so the second and later segments of such a line hand this
// function a mid-line offset as the entry point — `doc.top` can be one too, if
// the viewport happens to be scrolled there. A mid-line `p` cannot establish the
// block's real start (`start = p` below would be a lie), so it is deliberately
// forced oversize by the pt_line_start_cap seed just below rather than measuring
// a partial line and disagreeing with the segment drawn above it.
@(private = "file")
md_table_bounds :: proc(doc: ^Document, p: int) -> (start, end: int, oversize, ok: bool) {
	buf: [RENDER_LINE_CAP]u8
	line, lend, entry_capped := md_line_at(doc, p, buf[:])
	if !md_is_table_row(line) {return 0, 0, false, false}
	start, end = p, lend

	// Is `p` itself a real line start? Feeds trunc_back's seed value below (see
	// the doc comment above the invariant this checks).
	entry_line_start, entry_line_start_exact := base.pt_line_start_cap(&doc.pt, p, RENDER_LINE_CAP)
	entry_is_line_start := entry_line_start_exact && entry_line_start == p

	// Both bounds are measured from the ENTRY POINT `p`, never from the moving
	// `start`. Two traps here, both of which shipped once:
	//   - `start - q` is invariantly 0 (the loop assigns both from `ps`), so a guard
	//     written that way is dead code and the backward walk runs to byte 0 — on a
	//     renamed CSV that is the whole file, on the UI thread.
	//   - `r - start` in the forward loop is already past the budget the moment the
	//     backward walk moved `start`, so it trips on the first iteration and leaves
	//     `end` at the entry row. The cache window is then one row wide, every
	//     subsequent row misses, and the fallback becomes the most expensive path.
	// A window measured from `p` gives at least a budget's worth of cached rows
	// ahead of the viewport in both directions.
	//
	// A third trap, found after those two: `oversize` must NOT be "did a guard
	// fire while scanning", because which guard fires depends on `x = p - S`, the
	// entry offset within the block. For a block of size K < B <= 2K (K the
	// budget), entering near the top trips only the backward guard, entering near
	// the bottom trips only the forward one, and entering mid-block can trip
	// NEITHER — same block, three different answers depending on where the
	// viewport happened to land, which is exactly the scroll-dependent shift this
	// cache exists to prevent. So each direction only records that it was
	// truncated (`trunc_back` / `trunc_fwd`); `oversize` is derived once, after
	// both scans finish, from the window they produced — entry-independent by
	// construction (see the callers' case analysis over B in the batch-1 report).
	// trunc_back starts seeded from the mid-line-entry check above: a `p` that
	// isn't a real line start means `start = p` (set above) is not trustworthy,
	// so the block is forced oversize even if both scans below would otherwise
	// complete within budget.
	trunc_back, trunc_fwd := !entry_is_line_start, entry_capped
	q := p
	back_rows := 0
	for q > 0 {
		if p - q > md_table_budget {trunc_back = true;break}
		// pt_line_start is UNCAPPED: on a file with one enormous line containing
		// pipes it scans to byte 0 by itself. A non-exact result means the cap was
		// reached, which is a block boundary for our purposes.
		ps, exact := base.pt_line_start_cap(&doc.pt, q - 1, RENDER_LINE_CAP)
		if !exact {trunc_back = true;break}
		// md_line_at's own cap: `ps` is a real line start (exact, above), but the
		// line it starts may still run past RENDER_LINE_CAP before its own
		// newline — a single row longer than the cap, the same failure this
		// fixes on the forward side below.
		pl, _, pl_capped := md_line_at(doc, ps, buf[:])
		if !md_is_table_row(pl) {break}
		if pl_capped {trunc_back = true}
		back_rows += 1
		start = ps
		q = ps
		if back_rows > md_table_max_rows {trunc_back = true;break}
	}

	// Forward. Requires MD_TABLE_BUDGET > RENDER_LINE_CAP (asserted at the
	// constant) — otherwise this first check could trip on the entry row's own
	// length alone, before a single neighbour row is scanned, reproducing the
	// one-row cache window the comment above already names.
	r := lend
	fwd_rows := 0
	for r < doc.pt.length {
		if r - p > md_table_budget {trunc_fwd = true;break}
		ns := r + 1
		if ns > doc.pt.length {break}
		nl, ne, ne_capped := md_line_at(doc, ns, buf[:])
		if !md_is_table_row(nl) {break}
		if ne_capped {trunc_fwd = true}
		fwd_rows += 1
		end = ne
		r = ne
		if fwd_rows > md_table_max_rows {trunc_fwd = true;break}
	}

	// A row-count analogue of the same entry-dependence trap: if neither
	// direction's row cap trips, both scans ran to the block's true edges, so
	// `back_rows + fwd_rows + 1` IS the block's real total row count — entry-
	// independent — and must be checked against the cap too. Without this, a
	// block with, say, 200 short rows and a row cap of 120 would report oversize
	// when entered near either edge (one direction's own count exceeds 120) but
	// NOT when entered near the middle (each direction sees ~100, under the cap,
	// even though the block has 200 rows total) — the identical flip Important 1
	// fixes, one level down.
	total_rows := back_rows + fwd_rows + 1
	oversize = trunc_back || trunc_fwd || (end - start) > md_table_budget || total_rows > md_table_max_rows
	return start, end, oversize, true
}

// Is this line a paragraph line?
//
// NOT the predicate the run scans use -- that is md_is_run_line, which is this
// minus the setext underlines. This one answers only "would md_classify call this
// `.Para`", which is what the OWNER ENTRY needs (a marker line is not one) and
// what md_is_run_line is built on.
//
// Asks md_classify rather than testing anything itself, so there is exactly one
// definition of what a paragraph line is. Everything that already terminates a
// paragraph (blank, fence, rule, heading, quote, list, table row) keeps
// terminating it for free, because md_classify tests all of them ahead of the
// .Para fallthrough.
//
// No `in_fence` parameter, unlike md_classify itself: see md_para_bounds' doc
// comment, which states the fence contract for BOTH of its production callers
// -- one of which cannot be inside a fence and one of which can.
@(private = "file")
md_is_para_line :: proc(line: string) -> bool {
	trimmed := strings.trim_left(line, " \t")
	return md_classify(line, trimmed, false).kind == .Para
}

// The setext heading level this line UNDERLINES: 1 for a run of `=`, 2 for a run
// of `-`, 0 for everything else.
//
// PURE -- one line in, one number out -- and deliberately NOT part of
// md_classify, for the reason lazy continuation is not either. CommonMark makes
// `Title` over `===` an h1 and `Title` over `---` an h2, but a `---` line on its
// own is a thematic break, so the reading depends on the line ABOVE. md_classify
// never looks back and does not start now; the predecessor dependency lives in
// md_para_bounds, the layer that was already looking backward.
//
// Not md_is_rule with a fourth character, and the differences are all real:
//   * md_is_rule accepts `*` and `_`, which are never setext underlines;
//   * md_is_rule accepts internal spaces (`- - -` is a thematic break), which an
//     underline may not contain;
//   * md_is_rule requires three characters, while a single `-` is a valid h2
//     underline.
// The two overlap only on a bare run of three or more `-`, and there the
// promotion in md_para_bounds is what decides which reading applies.
//
// Up to three leading spaces, per CommonMark; a fourth would make the line
// indented code. Trailing spaces and tabs are insignificant.
@(private = "file")
md_setext_level :: proc(line: string) -> int {
	t := strings.trim_right(line, " \t")
	n := 0
	for n < len(t) && t[n] == ' ' {n += 1}
	if n > 3 {return 0}
	t = t[n:]
	if len(t) == 0 {return 0}
	c := t[0]
	if c != '=' && c != '-' {return 0}
	for i in 0 ..< len(t) {
		if t[i] != c {return 0}
	}
	return 1 if c == '=' else 2
}

// Is this a line an ordinary paragraph run may absorb as PROSE?
//
// md_is_para_line minus the setext underlines, and that subtraction is what makes
// an underline a run TERMINATOR rather than a line of the run's text.
//
// It matters for `=` and not for `-`, which is worth stating because the two look
// symmetric and are not. md_classify has no rule for `=` at all, so `===` falls
// through to `.Para` and a run would otherwise swallow it -- and then keep going
// into whatever prose followed it, which is the wrong block boundary, not merely
// the wrong text. A `---` is already `.Rule` and already stops both scans. This
// predicate makes the two characters behave the same way, which is what lets ONE
// promotion step in md_para_bounds handle both.
@(private = "file")
md_is_run_line :: proc(line: string) -> bool {
	return md_setext_level(line) == 0 && md_is_para_line(line)
}

// Is this a line a LAZY CONTINUATION may hang off -- a list item or a
// blockquote?
//
// CommonMark's rule: an unmarked prose line directly below a list item or a
// blockquote continues THAT block, inheriting its marker and its indent, rather
// than opening a paragraph of its own. Nothing else on md_classify's list
// continues that way -- a heading, a rule and a table row are each finished at
// their own line's end -- so this is deliberately two kinds and not "everything
// that is not .Para".
//
// Asks md_classify, for the same single-definition reason md_is_para_line does:
// what counts as a list item is md_list's business and what counts as a quote is
// md_quote_depth's, and neither is re-tested here. md_classify itself stays PURE
// -- one line in, one class out -- which is why the predecessor dependency this
// procedure serves lives in md_para_bounds, the layer that was already looking
// backward, and not in the classifier.
//
// `in_fence` is false here for the same reason it is in md_is_para_line; see
// md_para_bounds' fence contract, which covers this procedure too.
@(private = "file")
md_is_continuable :: proc(line: string) -> bool {
	trimmed := strings.trim_left(line, " \t")
	k := md_classify(line, trimmed, false).kind
	return k == .List || k == .Quote
}

// The contiguous run of paragraph lines containing `p`, PLUS the list item or
// blockquote it lazily continues and PLUS the setext underline that terminates it,
// if there is either. Scans backward to the run's true start and forward to its
// end, both bounded by md_para_budget, and reports the setext level the underline
// gives the run (0 when there is none).
//
// THE SINGLE PRODUCER of a paragraph's extent. It exists because a joined
// paragraph STARTS ABOVE ITS OWN LINE, which makes it the third construct with
// that property (a collapsed blank run and front matter are the other two) --
// and unlike those it occurs in every document. TWO production sites ask where
// the block containing byte B starts, and they must never disagree:
//
//   * md_join_run, called from md_layout_build's `.Para`, `.List`, `.Quote` and
//     promoted-`.Heading` cases, which joins the run this names into one block;
//   * md_block_start_at, which snaps an arbitrary byte back to that same start
//     before any resolver may hand it to a walk as a block key.
//
// Neither reaches this procedure directly. Both go through md_para_run, which
// memoises it and, more importantly, applies the `capped` refusal once on their
// behalf -- so the snap and the join agree by construction rather than by two
// readings of the same flag that have to be kept matching.
//
// Fence contract: md_is_run_line takes no `in_fence` parameter, unlike
// md_classify beneath it, and the two sites reach here differently.
// md_join_run is only reached from a switch on `e.cls = md_classify(e.src,
// trimmed, in_fence)`, and while `in_fence` is true md_classify returns
// `.Fence_Close` on a fence line and `.Fence_Body` on every other line -- never
// `.Para`, `.List` or `.Quote` (`.Fence_Open` is returned only when `in_fence` is
// FALSE, on the line that opens one -- it cannot occur while already inside a
// fence). So that caller is structurally unreachable inside a fence, and so is the
// setext promotion, which md_layout_build gates on `.Para`.
//
// md_block_start_at is NOT. It snaps a raw byte and holds no fence state, so it
// does run this over fence-body lines that read as prose. That is safe, not
// merely tolerated: inside a fence every line is its own block, so any line
// start it returns IS a block start, and md_is_run_line is false for both
// delimiters, so neither scan can cross out of the fence it started in (or into
// one from below). The overshoot costs run-up, never correctness.
//
// What DID move inside a fence, MEASURED against the parent commit with a
// md_block_start_at probe rather than reasoned about (2026-08-01 review) -- this
// comment's first draft named the wrong character and the wrong mechanism:
//
//	```\nTitle\n---\n```           the `---` (byte 10):  10 -> 4
//	```\nTitle\n===\nafter\n```    the `===` (byte 10):   4 -> 4
//	                              `after`  (byte 14):    4 -> 14
//
// The `---` row is NOT this scan changing its mind: md_is_para_line was already
// false for a `.Rule`, so it stops at the same line as before. That move comes
// from the new UNDERLINE ENTRY walking up out of the `---`. The character
// md_is_run_line actually changes here is `=`, and its effect shows one row
// down, on the line BELOW a fenced `===`. All three answers are real line starts
// inside the fence, so the conclusion above holds for every one of them.
//
// The OWNER lookup below inherits that contract unchanged. Inside a fence a body
// line reading `- x` classifies as `.List`, so this can name it the owner of the
// prose line beneath it and answer that line's start -- still a fence body line
// start, still a real block start inside a fence, still an overshoot bounded by
// the delimiters md_is_run_line refuses. And the JOIN side cannot reach it at
// all: md_layout_build's `.List` / `.Quote` cases are only entered when
// md_classify returned those kinds, which it never does while `in_fence`.
//
// LAZY CONTINUATION, and why it is here rather than in md_classify. A wrapped
// list item's second line carries no bullet and a wrapped blockquote's carries no
// `>`, so md_classify -- one line in, one class out, no lookback, and it stays
// that way -- calls both `.Para`. CommonMark says such a line continues the block
// above it. It is expressed as an EXTENT here instead: the run absorbs the owner's
// own line, so the block a walk builds at the resulting `start` is entered on the
// marker line and md_classify gives it the right kind, level and bullet with no
// inheritance step at all. Consequently nothing needs an `owner` return value:
// md_block_start_at wants only `start`, and md_layout_build reads the kind off the
// line it was entered at.
//
// SETEXT is the second construct whose KIND depends on a neighbour, and it is the
// one case where the extent alone is not enough -- the deciding line is BELOW the
// run, not above it, so entering at `start` cannot see it. Hence the `setext`
// return: the extent and the level come out of this one answer together, and
// md_layout_build promotes off it rather than looking again.
//
// THREE ENTRIES, ONE ANSWER. A run can be entered on its own prose, on the owner
// line above it, or on the setext underline below it, and all three must produce
// the same triple or md_para_run's window memo (which answers for line starts it
// has never been asked about) serves a different block to different scroll
// positions:
//
//   * entered on a PROSE line, both scans run; the lookup after them reads the
//     line above the settled `start` -- a pure function of `start`, not of `p` --
//     and extends `start` over it when it is continuable, and the promotion below
//     reads the line after the settled `end` on the same terms;
//   * entered on the OWNER's line, there is no backward scan (a marker line is a
//     block start in its own right); the run is seeded with the prose line
//     directly below and the forward scan continues from there;
//   * entered on the SETEXT UNDERLINE, there is no forward scan (the underline is
//     the run's last line by construction); `start` is seeded with the prose line
//     directly above and the backward scan continues from there.
//
// All three count the owner and the underline in `total_lines` and all three
// include their bytes in `end - start`, so the final, entry-independent cap checks
// see the same numbers from every entry.
//
// SETEXT, and why it is an EXTENT here rather than a kind in md_classify. `Title`
// over `===` is an h1 and over `---` an h2, and the underline BELONGS TO THE
// HEADING BLOCK -- it is markup that decided the level, not a block of its own. So
// the run must cover it, or a walk skips past the heading straight onto the
// underline and draws a thematic rule underneath it. Expressing it as an extent is
// what makes the underline byte snap back to the heading's own start
// (md_block_start_at), which is what stops the preview rendering a heading or a
// rule depending on where the pane happens to be scrolled.
//
// The promotion is refused when the run has an OWNER: a `---` under a list item or
// a blockquote is a thematic break, which is CommonMark and is also the only
// reading the two directions can agree on. From a prose entry that is simply no
// promotion; from the underline entry it means the underline is in no run at all,
// so that entry returns `ok = false` and the underline becomes its own block --
// which is exactly the block the prose entry's extent left room for.
//
// A CAPPED run is not promoted either, in the sense that matters: `capped` is
// derived after the promotion and md_para_run refuses the whole answer, so
// md_join_end reports no join and md_block_start_at falls back to the line start.
// The paragraph then renders line by line and the underline renders as whatever
// md_classify calls it in isolation -- a `.Rule` for `---`, a one-line `.Para` for
// `===`. The snap and the builder agree because they agree for every capped run,
// through the one refusal in md_para_run, and nothing about setext is special-cased
// into that.
//
// The three traps are md_table_bounds', in the same order, and each shipped once:
//   1. Both bounds measured from the ENTRY POINT `p`, never from the moving
//      `start`. `start - q` is invariantly 0 if written the other way, so the
//      guard is dead code and the backward walk runs to byte 0 on the UI thread.
//   2. The forward guard measured from `p` too, or it is already past budget the
//      moment the backward walk moved `start`, and every paragraph collapses to
//      its entry line.
//   3. `capped` derived ONCE, after both scans, from the window they produced --
//      never "did a guard fire while scanning". Which guard fires depends on
//      where within the run the entry landed, so an entry-dependent flag gives
//      one paragraph three different answers depending on scroll position.
@(private = "file")
md_para_bounds :: proc(doc: ^Document, p: int) -> (start, end: int, setext: int, capped, ok: bool) {
	buf: [RENDER_LINE_CAP]u8
	line, lend, entry_capped := md_line_at(doc, p, buf[:])
	start, end = p, lend

	// A `p` that is not a real line start cannot establish the run's start, so
	// `start = p` above is not trustworthy and the block is forced capped even if
	// both scans complete within budget. markdown_draw walks a line longer than
	// RENDER_LINE_CAP in capped segments, and doc.top can land mid-line.
	entry_line_start, entry_line_start_exact := base.pt_line_start_cap(&doc.pt, p, RENDER_LINE_CAP)
	entry_is_line_start := entry_line_start_exact && entry_line_start == p

	trunc_back, trunc_fwd := !entry_is_line_start, entry_capped
	// 0 or 1: the owner line -- the list item or blockquote this run continues.
	// Counted in `total_lines` and covered by `end - start` from BOTH entries, see
	// "TWO ENTRIES, ONE ANSWER" above.
	owner_lines := 0
	back_lines, fwd_lines := 0, 0
	q, r := p, lend
	// The underline entry sets this false: an underline is the run's LAST line, so
	// there is nothing below it to scan for.
	scan_fwd := true

	if under := md_setext_level(line); under > 0 {
		// THE UNDERLINE ENTRY, the mirror of the owner entry below. An underline is
		// only an underline when a plain paragraph line sits directly above it; with
		// anything else above (a blank, a list item, another underline, the top of the
		// file) it is a thematic break or a stray line of `=`, so this refuses and the
		// line becomes its own block.
		//
		// The line above is found from `entry_line_start`, not from `p - 1`: for a `p`
		// in the middle of the underline `p - 1` is still inside it and would find the
		// underline's own start. Such an entry is forced capped by
		// `entry_is_line_start` regardless, but the scan should walk the document, not
		// a mis-derived position.
		if !entry_line_start_exact || entry_line_start <= 0 {return 0, 0, 0, false, false}
		ps, exact := base.pt_line_start_cap(&doc.pt, entry_line_start - 1, RENDER_LINE_CAP)
		if !exact {return 0, 0, 0, false, false}
		pl, _, pl_capped := md_line_at(doc, ps, buf[:])
		if !md_is_run_line(pl) {return 0, 0, 0, false, false}
		if pl_capped {trunc_back = true}
		setext = under
		back_lines = 1
		start, q = ps, ps
		scan_fwd = false
	} else if !md_is_para_line(line) {
		// THE OWNER ENTRY. A marker line is a run only when an unmarked prose line
		// hangs off it; a list item that wraps nothing is an ordinary one-line block
		// and must stay one, so this returns `ok = false` and md_layout_build's
		// `.List` case joins nothing.
		if !md_is_continuable(line) {return 0, 0, 0, false, false}
		ns := lend + 1
		if ns > doc.pt.length {return 0, 0, 0, false, false}
		nl, ne, ne_capped := md_line_at(doc, ns, buf[:])
		if !md_is_run_line(nl) {return 0, 0, 0, false, false}
		if ne_capped {trunc_fwd = true}
		owner_lines = 1
		end, r = ne, ne
		// No backward scan from here: the marker line IS the block's start, and
		// nothing above it can be part of this block.
		q = 0
	}

	for q > 0 {
		if p - q > md_para_budget {trunc_back = true;break}
		ps, exact := base.pt_line_start_cap(&doc.pt, q - 1, RENDER_LINE_CAP)
		if !exact {trunc_back = true;break}
		pl, _, pl_capped := md_line_at(doc, ps, buf[:])
		if !md_is_run_line(pl) {break}
		if pl_capped {trunc_back = true}
		back_lines += 1
		start = ps
		q = ps
		if back_lines > md_para_max_lines {trunc_back = true;break}
	}

	for scan_fwd && r < doc.pt.length {
		if r - p > md_para_budget {trunc_fwd = true;break}
		ns := r + 1
		if ns > doc.pt.length {break}
		nl, ne, ne_capped := md_line_at(doc, ns, buf[:])
		if !md_is_run_line(nl) {break}
		if ne_capped {trunc_fwd = true}
		fwd_lines += 1
		end = ne
		r = ne
		if fwd_lines > md_para_max_lines {trunc_fwd = true;break}
	}

	// THE OWNER LOOKUP, for the continuation entry. Reads the line above the
	// SETTLED `start`, never above `p` -- the same discipline as trap 1, and the
	// reason this sits after the scans rather than inside the backward loop's
	// break: it is then a pure function of the run's start, which every entry into
	// the run agrees on, so every entry finds the same owner (or none).
	//
	// `ol_capped` is NOT redundant with the backward loop's own `pl_capped`. That
	// check sits BELOW the loop's `!md_is_para_line` break, so the one line the loop
	// never applies it to is precisely the line that stopped it -- this one. Without
	// it, an owner longer than RENDER_LINE_CAP would be absorbed here uncapped while
	// the same block entered on that owner reads back `entry_capped` and reports
	// capped: two answers for one block, which is the whole failure this procedure
	// is built to make impossible.
	if owner_lines == 0 && start > 0 {
		owner_ls, exact := base.pt_line_start_cap(&doc.pt, start - 1, RENDER_LINE_CAP)
		if !exact {
			// No line start within the scan cap, so whether an owner is up there
			// cannot be established at all. Refuse rather than guess.
			trunc_back = true
		} else {
			ol, _, ol_capped := md_line_at(doc, owner_ls, buf[:])
			if md_is_continuable(ol) {
				if ol_capped {trunc_back = true}
				owner_lines = 1
				start = owner_ls
			}
		}
	}

	// THE SETEXT PROMOTION, the only place it is decided, and after the owner lookup
	// because it depends on that lookup's answer. Same discipline as the lookup
	// itself: it reads the line after the SETTLED `end`, never after `p`, so it is a
	// pure function of the run's extent and every entry into the run finds the same
	// underline (or none).
	if owner_lines > 0 {
		// A `---` under a list item or a blockquote is a thematic break, not that
		// block's underline. Entered on the underline (setext already set), this
		// entry therefore holds no run at all.
		if setext > 0 {return 0, 0, 0, false, false}
	} else if setext == 0 && !trunc_fwd {
		// `!trunc_fwd`: with the forward scan truncated, `end` is not the run's edge
		// and the line after it is not the run's terminator, so there is nothing here
		// to read.
		//
		// NO TEST GUARDS THIS TERM, and none can: removing it leaves mdtest,
		// mdjointest, mdviewtest, splittest and mdfencetest all at 0 failures
		// (2026-08-01 review, verified by deletion). That is the comment's own
		// reasoning holding -- the answer is refused for being capped either way --
		// so this is honest defensive code rather than dead weight. Recorded so that
		// whoever "simplifies" it later knows the green suite is not evidence.
		// The answer is refused for being capped either way; this just keeps
		// the promotion from being decided off a position that means nothing.
		ns := end + 1
		if ns <= doc.pt.length {
			ul, ue, ue_capped := md_line_at(doc, ns, buf[:])
			if lvl := md_setext_level(ul); lvl > 0 {
				setext = lvl
				end = ue
				fwd_lines += 1
				if ue_capped {trunc_fwd = true}
			}
		}
	}

	// The line-count analogue of trap 3: if neither direction's cap tripped, both
	// scans reached the run's true edges, so back+fwd+owner+1 IS the run's real line
	// count and must be checked too. Without it a 6000-line run with a 4096 cap
	// reports capped when entered near either edge and NOT when entered near the
	// middle -- the identical flip, one level down.
	//
	// The underline is counted in exactly one of these terms from each entry -- in
	// `fwd_lines` from a prose entry (the promotion increments it) and as the `+1`
	// entry line from the underline entry, where `back_lines` carries the prose
	// instead. `Title\ncont\n---` is three lines from all three of them.
	total_lines := back_lines + fwd_lines + owner_lines + 1
	capped = trunc_back || trunc_fwd || (end - start) > md_para_budget || total_lines > md_para_max_lines
	return start, end, setext, capped, true
}

// Package-visible so mdjointest can drive the bounds function directly.
// md_para_bounds is `private = "file"`, so this shim is the only way outside
// this file to call it directly -- but it is not the only CALLER: md_para_run
// below memoises it for the two production call sites, so this shim and those
// two all bottom out in the same single producer.
//
// It DROPS the `setext` return rather than widening the 34 call sites that
// only ever wanted the extent. The level is asserted through
// md_para_run_for_test, which is what production reads anyway; the extent -- the
// half of the promotion this shim does carry -- covers the underline here exactly
// as it does there.
md_para_bounds_for_test :: proc(doc: ^Document, p: int) -> (start, end: int, capped, ok: bool) {
	s, e, _, c, o := md_para_bounds(doc, p)
	return s, e, c, o
}

// Four slots, mirroring MD_TABLE_SLOTS -- but note the difference, because the
// two comments should not be read as making the same kind of claim.
// MD_TABLE_SLOTS' count answers a MEASURED thrash. This one does not: rebuilt at
// MD_PARA_SLOTS :: 1, every mdperftest fixture is unchanged within noise
// (4.450 / 5.155 / 1.606 / 1.654 ms against 4.402 / 5.124 / 1.584 / 1.604) and
// mdjointest stays green, so on every document that exists today one slot is
// indistinguishable from four (2026-08-01 review).
//
// Four is kept anyway because the reasoning it was chosen for is sound and the
// cost is four structs on Document: a scroll frame asks about several blocks, and
// a single slot is evicted by the next block and missed on the one after. What is
// NOT claimed is that anything has been observed to need it.
MD_PARA_SLOTS :: 4

// One remembered md_para_bounds answer, keyed on a BYTE WINDOW rather than on the
// entry byte. See md_para_run for why the window is sound.
Md_Para_Cache :: struct {
	valid:     bool,
	revision:  u64, // the buffer this was measured against (doc.revision)
	budget:    int, // md_para_budget / md_para_max_lines as they were at measure
	max_lines: int, // time; mdjointest lowers both, so they are part of the key
	lo, hi:    int, // the window this answer covers, inclusive at both ends
	setext:    int, // 1 or 2 if the run's last line is a setext underline, else 0
	joinable:  bool, // lo/hi ARE the run's true bounds; false = capped, no bounds
}

// THE production question: is there a JOINABLE run containing `p` -- a paragraph
// run, or one lazily continuing the list item or blockquote above it -- and where
// does it begin and end? Memoised over md_para_bounds.
//
// Two things happen here, and both are the point.
//
// 1. The `capped` decision is made ONCE, here, instead of at two call sites that
//    have to keep agreeing. md_join_run and md_block_start_at
//    both refuse a capped run -- the join because a truncated run's bounds are
//    not the run's, the snap because it must land where the join will start --
//    and a review found each of them justifying the rule by the other's failure.
//    Folding it in here makes the agreement structural: there is no longer a
//    `capped` flag at either call site to get out of step. md_para_bounds still
//    returns it, for md_para_bounds_for_test and for mdjointest's trap rows.
//
// 2. The scans are skipped when a previous answer already covers `p`. Without
//    this every resolver call walks the whole run. Measured on mdperftest's
//    `hardwrap 1x2000` fixture, debug build, 2026-08-01: md_scroll_px 4.015 ms
//    with this lookup disabled, 0.005 ms with it, and the whole scroll frame
//    13.849 -> 1.633 ms. The 4000-line fixture, where the run is capped and
//    NOTHING joins, went 39.783 -> 1.615 ms -- the join's cost there was never
//    the joining, it was asking this question once per block per frame.
//
// WHY A WINDOW IS SOUND. For an entry that is a real line start, the answer is a
// property of the RUN, not of the entry -- md_para_bounds' trap 3 and the
// line-count check under it exist to make `capped` entry-independent, and
// mdjointest asserts it directly ("one answer per paragraph, whatever byte you
// enter at"). So:
//
//   * joinable: [lo, hi] are the run's true edges, every line start between them
//     is a line of that run, and md_para_bounds would return the same triple from
//     each of them. That includes a SETEXT UNDERLINE, whose bytes are inside the
//     window because the run covers it -- which is the whole point of putting the
//     promotion in the bounds layer. `setext` rides along in the slot for the same
//     reason `lo`/`hi` do: it is a property of the run, so serving it out of a
//     window measured from one entry cannot give another entry a different level.
//   * not joinable: [lo, hi] is the truncated window the scans reached. It is a
//     SUBSET of the same contiguous run, so every line start in it is in that run
//     -- and the run is capped from every entry, so the answer is `false` for all
//     of them. The truncated bounds themselves are entry-dependent and are
//     deliberately NOT handed back; nothing needs them.
//
// THE TRAP, and why the line-start test guards both the lookup and the store: a
// `p` that is not a line start is forced capped by md_para_bounds' own
// `entry_is_line_start` check EVEN WHEN the run is small and joins fine from
// every real line start in it. Caching that answer would poison the whole window
// with a verdict that was about the entry and not about the run. So a mid-line
// entry neither reads the cache nor writes it; it pays the scan and gets the
// unmemoised answer, which is what it asked for.
@(private = "file")
md_para_run :: proc(doc: ^Document, p: int) -> (start, end: int, setext: int, ok: bool) {
	ls, exact := base.pt_line_start_cap(&doc.pt, p, RENDER_LINE_CAP)
	line_start := exact && ls == p
	if line_start {
		for &e in doc.md_para {
			if !e.valid || e.revision != doc.revision {continue}
			if e.budget != md_para_budget || e.max_lines != md_para_max_lines {continue}
			if p < e.lo || p > e.hi {continue}
			if e.joinable {return e.lo, e.hi, e.setext, true}
			return 0, 0, 0, false
		}
	}
	s, en, lvl, capped, pok := md_para_bounds(doc, p)
	if !pok {return 0, 0, 0, false}
	if line_start {
		slot := &doc.md_para[doc.md_para_next]
		doc.md_para_next = (doc.md_para_next + 1) % MD_PARA_SLOTS
		slot^ = {
			valid     = true,
			revision  = doc.revision,
			budget    = md_para_budget,
			max_lines = md_para_max_lines,
			lo        = s,
			hi        = en,
			setext    = lvl,
			joinable  = !capped,
		}
	}
	if capped {return 0, 0, 0, false}
	return s, en, lvl, true
}

// Package-visible so mdjointest can assert on the MEMO -- that it answers the
// same as md_para_bounds from every line start of a run, and that an edit
// retires it -- rather than only on the producer underneath.
//
// The `setext` return is dropped here for the same reason
// md_para_bounds_for_test drops it: the eight existing call sites ask about the
// extent. md_para_setext_for_test below is the one that carries it.
md_para_run_for_test :: proc(doc: ^Document, p: int) -> (start, end: int, ok: bool) {
	s, e, _, o := md_para_run(doc, p)
	return s, e, o
}

// The memo's WHOLE answer, promotion included, so mdjointest can assert that the
// setext level is a property of the run and not of the byte it was asked about.
// Entry independence for the extent is only half the claim; a level that differed
// between the prose entry and the underline entry would render the same block as
// an h1 from above and an h2 from below.
md_para_setext_for_test :: proc(doc: ^Document, p: int) -> (start, end, setext: int, ok: bool) {
	return md_para_run(doc, p)
}

// Per-column maxima across the whole block, plus the separator row's alignments.
// Returns the populated cache; caller owns storage.
//
// Package-visible rather than file-private so the mdtabletest mode can drive the
// O(1) oversized branch directly with `oversize=true`, without needing a real
// >1 MB fixture. That direct call bypasses md_table_bounds entirely, so it does
// NOT exercise how `oversize` gets set — two Criticals hid for a round behind
// exactly that gap. The bounds drive-through (lowering md_table_budget so a
// normal-sized fixture trips the real guards) is what actually tests oversize
// detection; this export is only for the measurement branch below it.
md_table_measure :: proc(doc: ^Document, t: ^plat.Text, start, end: int, oversize: bool) -> Md_Table_Cache {
	c := Md_Table_Cache {
		valid    = true,
		start    = start,
		end      = end,
		revision = doc.revision,
		budget   = md_table_budget,
		max_rows = md_table_max_rows,
		oversize = oversize,
	}
	// Past the budget: fixed columns, and NO SCAN AT ALL. Every column is the same
	// width and every row draws at i*(width+pad), which depends on nothing outside
	// the row being drawn — so it is shift-free without measuring anything, and the
	// fallback is O(1) instead of O(block). Scanning the span here just to collect
	// ncols would reintroduce the per-row cost the budget exists to avoid, and the
	// draw already clips at x1, so a generous ncols costs nothing.
	if oversize {
		c.ncols = MD_TABLE_MAX_COLS
		for i in 0 ..< MD_TABLE_MAX_COLS {c.widths[i] = MD_TABLE_FIXED_CELLS}
		return c
	}

	buf: [RENDER_LINE_CAP]u8
	for p := start; p <= end && p < doc.pt.length; {
		line, lend, _ := md_line_at(doc, p, buf[:])
		if !md_is_table_row(line) {break}
		cells := md_split_cells(line, context.temp_allocator)
		if len(cells) > c.ncols {c.ncols = min(len(cells), MD_TABLE_MAX_COLS)}
		if md_row_is_sep(line) {
			for cell, i in cells {
				if i >= MD_TABLE_MAX_COLS {break}
				c.align[i] = md_cell_align(cell)
			}
		} else {
			// The separator row is excluded, so its dashes never inflate a column.
			for cell, i in cells {
				if i >= MD_TABLE_MAX_COLS {break}
				// Measure what will be DRAWN, not the raw cell. md_layout_build shapes
				// `md_inline(cell)`'s runs (see its .Table case above), which strips
				// markdown syntax -- "[label](url)" draws as "label". Measuring the raw
				// cell here counted the brackets and the whole URL as visible width, so
				// a link column's natural width had nothing to do with what it actually
				// rendered as, and the water-fill in md_table_fit_cells starved other
				// columns to feed a link column that only needed a few cells.
				// col0 = 0: a table cell's rendered text is measured from its own start,
				// matching where the shaper starts it.
				rb := strings.builder_make(context.temp_allocator)
				for run in md_inline(cell) {
					strings.write_string(&rb, run.text)
				}
				w := plat.text_cells(t, transmute([]u8)strings.to_string(rb), 0, .Doc)
				if w > c.widths[i] {c.widths[i] = w}
			}
		}
		if lend >= doc.pt.length {break}
		p = lend + 1
	}
	return c
}

// Cached measure for the block containing `p`, or nil if `p` is not a table row.
// The per-frame cost is the containment test over MD_TABLE_SLOTS entries; a scan
// happens only when the viewport enters a block none of the slots cover, or the
// buffer changed.
// `md_table_budget` and `md_table_max_rows` are part of the key, not just inputs
// to the scan. They are runtime variables so a test can drive md_table_bounds
// into the oversize path on a small fixture, and without them here a lowered
// budget reads back an entry measured at the production one: same revision, same
// containing range, wrong bounds. Measured -- dropping this check returns
// `oversize=false, window=9313` where the lowered budget's answer is a bounded
// ~4.9 KB window, so an oversize assertion passes on a block that was never
// measured as oversize.
//
// mdtabletest used to defend against this by hand, clearing `doc.md_table`
// before every budget change. That worked and could not scale: the guarantee
// lived in seven copies at the call sites instead of in the cache, so a future
// case that forgot one would silently assert against stale numbers. Md_Para_Cache
// keyed on its own budget from the start (md_para_run); this is that fix, one
// cache later.
md_table_ensure :: proc(doc: ^Document, t: ^plat.Text, p: int) -> ^Md_Table_Cache {
	for &c in doc.md_table {
		if !c.valid || c.revision != doc.revision {continue}
		if c.budget != md_table_budget || c.max_rows != md_table_max_rows {continue}
		if p >= c.start && p < c.end {
			return &c
		}
	}
	start, end, oversize, ok := md_table_bounds(doc, p)
	if !ok {return nil}
	slot := &doc.md_table[doc.md_table_next]
	doc.md_table_next = (doc.md_table_next + 1) % MD_TABLE_SLOTS
	slot^ = md_table_measure(doc, t, start, end, oversize)
	return slot
}

// One fitted column of a table block: where it starts and how wide it is, in
// pixels from the block's own origin.
//
// THE column geometry, produced once per table block by md_table_cols and stored
// on the block's layout. The shaper wraps each cell inside `w` and places it at
// `x`; the draw's column rules and the separator row's rule read the same two
// numbers back. There is no second expression of a column's position anywhere --
// md_col_x, which computed one from cell counts at the draw site while
// md_table_measure computed the widths those counts came from, is gone.
Md_Table_Col :: struct {
	x, w: f32,
}

// Fit a table's NATURAL column widths (in character cells, as md_table_measure
// derived them) into `avail` cells of measure. Returns how many columns survived
// and writes their fitted cell widths into `out`.
//
// Pure integer arithmetic on purpose: it is the whole of the measure-fit decision,
// it needs no device and no font, and a test can drive every branch of it directly.
// Cells rather than pixels because the mono face is what makes a table's columns
// line up (§9.3, "always mono: columns align") -- a column boundary on a whole
// character cell keeps that true, where a proportional fraction of the measure
// would not.
//
// The rule, which is §10's with the divergence documented at MD_TABLE_MIN_CELLS:
//
//  1. Clamp each natural width to [1, MD_TABLE_MAX_CELLS]. §10's upper clamp,
//     reused: one 300-character cell must not claim the entire measure.
//  2. If the clamped widths plus the gutters already fit, use them. A table
//     narrower than the measure is therefore laid out exactly as it was before
//     this existed -- which is why the fit cannot regress the common case.
//  3. Otherwise water-fill: a column wanting no more than its equal share of what
//     is left KEEPS its natural width, and the width it did not want goes back
//     into the pool for the columns that did. Repeat until no column is under the
//     share, then give every remaining column the soft floor and split what's
//     left of the budget PROPORTIONALLY to how much each still wants beyond that
//     floor -- §10's rule, reused: two greedy columns wanting 50 and 300 cells do
//     not end up the same width. The integer remainder is handed out one cell at
//     a time so the fitted widths sum to the budget EXACTLY and no rounding
//     drift leaks past the measure.
//
// Under real pressure (many columns in a narrow pane) the floor is lowered toward
// 1 cell before any column is dropped, and a column is dropped only when even one
// cell each plus the gutters cannot fit -- 32 columns in a pane a dozen characters
// wide. Dropping is the last resort rather than the first because there is no
// scissor rect in this renderer: a column past the measure does not clip, it paints
// over the scrollbar and the other split half.
md_table_fit_cells :: proc(natural: []int, avail: int, out: []int) -> (ncols: int) {
	n := min(len(natural), len(out))
	if n <= 0 {return 0}
	// The soft floor, then the column count. Both loops shrink monotonically and
	// stop at 1, so neither can spin.
	minc := MD_TABLE_MIN_CELLS
	for minc > 1 && n * minc + (n - 1) * MD_TABLE_PAD > avail {minc -= 1}
	for n > 1 && n * minc + (n - 1) * MD_TABLE_PAD > avail {n -= 1}
	budget := max(n * minc, avail - (n - 1) * MD_TABLE_PAD)

	want: [MD_TABLE_MAX_COLS]int
	sum := 0
	for i in 0 ..< n {
		want[i] = clamp(natural[i], 1, MD_TABLE_MAX_CELLS)
		sum += want[i]
	}
	if sum <= budget {
		for i in 0 ..< n {out[i] = want[i]}
		return n
	}

	fixed: [MD_TABLE_MAX_COLS]bool
	remaining, free := budget, n
	for free > 0 {
		share := remaining / free
		changed := false
		for i in 0 ..< n {
			if fixed[i] || want[i] > share {continue}
			fixed[i], out[i] = true, want[i]
			remaining -= want[i]
			free -= 1
			changed = true
		}
		if !changed {break}
	}
	if free > 0 {
		// Every remaining column gets the floor first, then the rest of the
		// budget splits PROPORTIONALLY to how much each still wants beyond that
		// floor -- §10's rule ("distribute leftover width proportionally"),
		// reused rather than diverged from. Basing the weight on want[i]-minc
		// rather than want[i] itself is what keeps out[i] >= minc by
		// construction: a column whose want IS the floor gets none of the
		// leftover and stays exactly at minc, instead of an even split pushing
		// it above its own natural want.
		leftover := max(0, remaining - free * minc)
		extra_sum := 0
		for i in 0 ..< n {
			if fixed[i] {continue}
			extra_sum += max(0, want[i] - minc)
		}
		assigned := 0
		for i in 0 ..< n {
			if fixed[i] {continue}
			add := 0
			if extra_sum > 0 {add = leftover * max(0, want[i] - minc) / extra_sum}
			out[i] = minc + add
			assigned += add
		}
		// The proportional split's integer division rounds down, so up to
		// (free - 1) cells of leftover go unassigned above; hand them out one
		// at a time, same as the even split used to, so the fitted widths
		// still sum to the budget EXACTLY.
		extra := leftover - assigned
		for i in 0 ..< n {
			if fixed[i] {continue}
			if extra <= 0 {break}
			out[i] += 1
			extra -= 1
		}
	}
	return n
}

// THE advance a table's column arithmetic is denominated in.
//
// One producer, because there are two candidates and they are not the same pixel.
// The cell COUNTS come from plat.text_cells; the cell TEXT is laid out by the
// proportional shaper, which advances by the font's real advance. So the number
// that turns a count into a pixel width has to be the shaper's, or a column
// fitted to its content's own natural width is not wide enough to hold it.
//
// NOT plat.text_char_width, which is what this used to be: that ROUNDS to a whole
// pixel, and has to -- the editor's grid needs an integral cell because text_draw
// advances its pen by the same number, so the glyphs and every rect positioned
// against column n*cell_w cannot drift. The preview's table is not on that grid.
//
// The cost of the mix-up, live: at the default 16px document size m.table is 15px,
// where the rounded cell is 8.0000 and the real advance 8.2471. A table narrower
// than the measure is fitted at its NATURAL widths, so a 6-cell column came out
// 48.0px while its 6-character cell shapes to 49.48px -- the shaper's greedy break
// then fired on the cell's last glyph and every such cell dropped its last word
// (or, with no space in it, its last character) onto a second line. That is Wyatt's
// "it looks like it's not respecting the spaces all the time" on a table
// (2026-07-29): the break lands on the space, so the space is what appears to go
// missing. The sign flips with the size -- at 24px the rounded 13.0000 exceeds the
// real 12.6455, columns come out too wide instead and nothing wraps early, which
// is why mdtest's px_=24 table sections were all green while the shipped default
// size was broken. md_table_fit_selftest sweeps sizes for exactly that reason.
md_table_char_w :: proc(gfx: ^plat.Gfx, t: ^plat.Text, m: ^Md_Metrics) -> f32 {
	return plat.text_advance(gfx, t, '0', m.table, .Doc)
}

// The fitted pixel geometry of one table block's columns, for a pane whose content
// column is `measure` pixels wide at a mono advance of `char_w` (md_table_char_w --
// the shaper's advance, not the editor grid's rounded cell).
//
// The one production call site is md_layout_build, which stores the result on the
// block's layout and lets the draw read it back. Package-visible rather than
// file-private for the same reason md_table_measure is: mdtest asks it the
// identical question the layout asked, so a pixel assertion about a column can be
// written against the geometry the layout actually used instead of a copy of it.
md_table_cols :: proc(c: ^Md_Table_Cache, measure, char_w: f32, allocator := context.allocator) -> []Md_Table_Col {
	if c == nil || c.ncols <= 0 || char_w <= 0 {return nil}
	cells: [MD_TABLE_MAX_COLS]int
	avail := int(measure / char_w)
	n := 0
	if c.oversize {
		// Past the budget the columns are FIXED and nothing was scanned, so
		// md_table_measure's ncols is MD_TABLE_MAX_COLS -- a deliberate over-estimate
		// (see its comment: a generous count costs nothing because the draw clips).
		// Water-filling that fiction would spend the measure squeezing 32 imaginary
		// columns into one character each, which is unreadable AND drops the real
		// data that was in the first few. So the fixed width is kept -- that is the
		// whole point of the fallback, and it is what makes it O(1) and
		// entry-independent -- and only the COUNT is bounded by the measure.
		for n < c.ncols && (n + 1) * MD_TABLE_FIXED_CELLS + n * MD_TABLE_PAD <= avail {n += 1}
		n = max(1, n)
		for i in 0 ..< n {cells[i] = MD_TABLE_FIXED_CELLS}
	} else {
		n = md_table_fit_cells(c.widths[:min(c.ncols, MD_TABLE_MAX_COLS)], avail, cells[:])
	}
	if n <= 0 {return nil}
	out := make([]Md_Table_Col, n, allocator)
	at := 0
	for i in 0 ..< n {
		out[i] = {x = f32(at) * char_w, w = f32(cells[i]) * char_w}
		at += cells[i] + MD_TABLE_PAD
	}
	return out
}

// The pixel extent of a fitted row: its last column's right edge. Derived from the
// stored geometry, so the separator row's rule cannot be a different width from
// the columns it sits under.
@(private = "file")
md_table_extent :: proc(cols: []Md_Table_Col) -> f32 {
	if len(cols) == 0 {return 0}
	last := cols[len(cols) - 1]
	return last.x + last.w
}

// One styled run of a line's inline content.
@(private = "file")
Md_Run :: struct {
	text:                    string,
	bold, ital, code, link:  bool,
	strike:                  bool, // ~~text~~ (GFM)
	url:                     string,
}

// --- UI spec 9.3, the preview type scale ------------------------------------
//
// Every size is a multiple of the base document size S, so Ctrl+= scales the
// whole preview for free, and every one of them is `round(k * S)` computed ONCE
// into this struct.
//
// The rounding is load-bearing, not cosmetic, and it is the one rule in this
// file that is enforced by a hazard rather than by taste. Glyph_Key.px is a u16
// and glyph_get truncates into it (`u16(px)`, platform/text.odin), so two
// fractional sizes that truncate to the same integer SHARE one cache entry —
// and that entry carries whichever advance and rasterized bitmap arrived first.
// Let 0.92 * S = 14.72 reach the atlas and it silently collides with a 14 px
// entry: the shaper then lays out with 14 px advances while asking for 14.72 px
// ink, or the other way round, depending on which size was seen first. Task 2a
// flagged this rather than changing the key (it belongs to its own change with
// its own test); honouring the rounding here is the other side of that contract.
//
// So: nothing in the preview may multiply S by a ratio at a draw site. It reads
// a field of this struct, which was rounded when the struct was built.
Md_Metrics :: struct {
	s:            f32, // the base document size S, as handed in
	// Sizes, round(k * S). head[0] is unused so head[level] indexes directly.
	head:         [7]f32,
	body:         f32, // 1.00 S
	code:         f32, // 0.92 S -- inline and fenced
	table:        f32, // 0.95 S
	// 0.88 S. RESERVED, and deliberately still computed: 9.3 gives the preview a
	// caption row, but every construct that would use one -- image captions,
	// table captions, footnote text -- is in 9.2's unimplemented list, so nothing
	// reads this today. Kept because the row is part of the type scale and the
	// metrics test asserts the whole scale is round(k * S) in one place; dropping
	// it would mean re-deriving 0.88 S at whichever draw site first needs it,
	// which is the ratio-at-a-draw-site this struct's header forbids. Marked
	// rather than deleted so "nothing reads it" reads as a decision (L6).
	caption:      f32,
	// Requested leading for body prose (1.65 S). NOT the leading you get: a face
	// whose ascent + descent exceeds it is clamped up per line by the shaper, and
	// Georgia's is 1.136 em, so this is a floor. Read Shaped.line_h /
	// Shaped.line_boxes[l].h back for what actually happened.
	body_lead:    f32,
	// Vertical rhythm, all round(k * S). Adjacent margins COLLAPSE (the gap
	// between two blocks is max(prev.below, next.above)), which is what browsers
	// do and what the spec's own numbers assume -- a paragraph's 0.8 S below and
	// an h2's 1.6 S above are not meant to sum to 2.4 S.
	head_above:   [7]f32,
	head_below:   [7]f32,
	para_below:   f32, // 0.8 S
	list_gap:     f32, // 0.25 S between items
	quote_above:  f32, // 0.8 S
	quote_below:  f32, // 0.8 S
	fence_above:  f32, // 1.0 S
	fence_below:  f32, // 1.0 S
	// Fixed pixel quantities from 9.2/9.3, DPI-scaled rather than S-scaled: they
	// are decorations, not type.
	rule_gap:     f32, // 24px above and below a thematic break (9.2 item 10)
	fence_pad:    f32, // 12px inside a fenced block
	code_radius:  f32, // 3px behind an inline code span
	fence_radius: f32, // 6px on the fenced block
	quote_inset:  f32, // 16px per blockquote level (9.2 item 7)
	list_indent:  f32, // 24px per list level (9.2 item 5)
	task_box:     f32, // 14px checkbox (9.2 item 9)
	pad_left:     f32, // 40px left padding (9.3 measure line)
	// 72ch, where a `ch` is the body face's advance for '0' at body size -- CSS's
	// own definition, and the only one that makes "72ch" mean a column of 72
	// characters in a proportional face.
	measure:      f32,
	// Not type at all: the state OUTSIDE this struct that a block's layout also
	// depends on, sampled ONCE per pass here because this struct is already the
	// thing md_pass builds once and hands to every block. All three are cache-key
	// terms (see MD_LAYOUT_SLOTS); nothing draws with them.
	ui_scale:     f32,
	theme:        u64,
	// Which faces are loaded (plat.text_face_gen). Sits in exactly the position
	// `theme` does and for the same mechanism -- a layout bakes something that a
	// global can move underneath it -- but what it protects is GEOMETRY, not
	// colour: every glyph position, every soft-wrap point and every block height
	// in a cached entry came out of the shaper at the advances of whichever
	// families were loaded when it was built. Settings > Font reloads the .Doc
	// chain (settings_apply_font), which is what inline code and fenced blocks
	// draw on, and text_reset_atlas alone does not touch a laid-out entry: the
	// atlas rasterizes the new family while the cache keeps the old family's
	// spacing, wrap points, inline-code backgrounds and link rects. Note that
	// `measure` cannot stand in for this -- it is 72 advances of the BODY face,
	// invariant under a .Doc change.
	faces:        u64,
}

// The theme's identity as one number, for the layout cache key.
//
// A HASH of g_theme rather than a generation counter bumped at each assignment
// site. The global is assigned from main.odin's startup, the Settings theme
// cycle, theme_edit_current, theme_reapply_if_active and a dozen test modes, and
// "every future assignment remembers to bump the counter" is exactly the promise
// CLAUDE.md's one-producer rule exists to stop making -- a missed site is a
// silent stale-colour bug, not a compile error.
//
// It also makes the test honest. A probe switches themes by assigning g_theme,
// which is what the reviewer's probe did and what every existing themetest does;
// under a counter the probe would have to bump the counter itself, and would
// then be asserting that the cache reads a number the test just set rather than
// that a theme switch invalidates.
//
// 40 roles x 4 channels, once per md_pass (at most three passes a frame): 160
// multiply-xors against a pass that shapes text.
@(private = "file")
md_theme_gen :: proc() -> u64 {
	h := u64(0xcbf29ce484222325) // FNV-1a
	for role in g_theme {
		for c in role {
			h = (h ~ u64(transmute(u32)c)) * 0x100000001b3
		}
	}
	return h
}

// round(k * S), floored at 1 so a degenerate S cannot produce a 0 px face.
@(private = "file")
md_scale :: #force_inline proc(s, k: f32) -> f32 {return max(1, f32(int(s * k + 0.5)))}

// The whole type scale for base size `s`. Built once per pass, never per block
// and never per draw call.
//
// `t` is needed only for the `ch` measure, which is a property of the body face.
md_metrics :: proc(t: ^plat.Text, s: f32) -> (m: Md_Metrics) {
	m.s = s
	m.head = {0, md_scale(s, 1.85), md_scale(s, 1.50), md_scale(s, 1.25), md_scale(s, 1.10), md_scale(s, 1.00), md_scale(s, 1.00)}
	m.body = md_scale(s, 1.00)
	m.code = md_scale(s, 0.92)
	m.table = md_scale(s, 0.95)
	m.caption = md_scale(s, 0.88)
	m.body_lead = md_scale(s, 1.65)
	m.head_above = {0, 0, md_scale(s, 1.60), md_scale(s, 1.40), md_scale(s, 1.20), md_scale(s, 1.00), md_scale(s, 1.00)}
	m.head_below = {0, md_scale(s, 0.60), md_scale(s, 0.50), md_scale(s, 0.40), md_scale(s, 0.30), md_scale(s, 0.30), md_scale(s, 0.30)}
	m.para_below = md_scale(s, 0.80)
	m.list_gap = md_scale(s, 0.25)
	m.quote_above, m.quote_below = md_scale(s, 0.80), md_scale(s, 0.80)
	m.fence_above, m.fence_below = md_scale(s, 1.00), md_scale(s, 1.00)
	m.rule_gap = sx(24)
	m.fence_pad = sx(12)
	m.code_radius = sx(3)
	m.fence_radius = sx(6)
	m.quote_inset = sx(16)
	m.list_indent = sx(24)
	m.task_box = sx(14)
	m.pad_left = sx(40)
	m.measure = 72 * plat.text_advance(nil, t, '0', m.body, .Body)
	m.ui_scale, m.theme, m.faces = UI_SCALE, md_theme_gen(), plat.text_face_gen(t)
	return
}

// h1 and h2 carry a rule under them (9.2 item 1, 9.3's "+ md_rule").
@(private = "file")
md_head_rules :: #force_inline proc(level: int) -> bool {return level == 1 || level == 2}

@(private = "file")
is_space :: proc(b: u8) -> bool {return b == ' ' || b == '\t'}

// CommonMark's ASCII punctuation set, used only by the `_` flanking test
// below. `*` doesn't need it -- `*` is allowed to open/close emphasis
// mid-word, only `_` has the intraword restriction.
@(private = "file")
md_is_ascii_punct :: proc(b: u8) -> bool {
	switch b {
	case '!', '"', '#', '$', '%', '&', '\'', '(', ')', '*', '+', ',', '-', '.', '/',
	     ':', ';', '<', '=', '>', '?', '@', '[', '\\', ']', '^', '_', '`', '{', '|', '}', '~':
		return true
	}
	return false
}

// Whether the delimiter run s[start:end] (a run of `_` or `__`) can open
// and/or can close emphasis, per CommonMark's left-/right-flanking rules
// (spec 6.2). String boundaries count as whitespace. This is a single test,
// not the full delimiter-stack algorithm -- see md_inline's `_` cases for
// what that means in practice.
@(private = "file")
md_delim_flanks :: proc(s: string, start, end: int) -> (can_open, can_close: bool) {
	before_ws := start == 0 || is_space(s[start - 1])
	after_ws := end >= len(s) || is_space(s[end])
	before_punct := !before_ws && start > 0 && md_is_ascii_punct(s[start - 1])
	after_punct := !after_ws && end < len(s) && md_is_ascii_punct(s[end])
	left_flank := !after_ws && (!after_punct || before_ws || before_punct)
	right_flank := !before_ws && (!before_punct || after_ws || after_punct)
	// _ can open only if left-flanking and (not right-flanking, or preceded
	// by punctuation). _ can close only if right-flanking and (not
	// left-flanking, or followed by punctuation). That asymmetric guard is
	// exactly what keeps `_` out of the middle of a word like stb_sprintf
	// while still letting `_italic_` and `snake_case_` (one-sided) work.
	can_open = left_flank && (!right_flank || before_punct)
	can_close = right_flank && (!left_flank || after_punct)
	return
}

// Parse a line's inline content into styled runs. Small state machine: ** / __
// bold, * / _ italic, ` code, [text](url) links. Non-nested (a link's label is
// plain), which is enough for a preview.
@(private = "file")
md_inline :: proc(s: string, allocator := context.temp_allocator) -> []Md_Run {
	out := make([dynamic]Md_Run, 0, 8, allocator)
	bold, ital, code, strike := false, false, false, false
	sb := strings.builder_make(allocator)
	flush := proc(out: ^[dynamic]Md_Run, sb: ^strings.Builder, bold, ital, code, strike: bool) {
		if strings.builder_len(sb^) == 0 {return}
		append(out, Md_Run{text = strings.clone(strings.to_string(sb^), context.temp_allocator), bold = bold, ital = ital, code = code, strike = strike})
		strings.builder_reset(sb)
	}
	i, n := 0, len(s)
	for i < n {
		c := s[i]
		if code { // inside inline code: only ` ends it
			if c == '`' {
				flush(&out, &sb, false, false, true, strike)
				code = false
				i += 1
			} else {
				strings.write_byte(&sb, c)
				i += 1
			}
			continue
		}
		switch {
		// A backslash escape takes the NEXT byte literally. Without this, a
		// path like C:\*.txt or a literal asterisk toggled italics and the rest
		// of the line changed style -- CommonMark's escapes are not optional
		// once a document contains any punctuation at all.
		case c == '\\' && i + 1 < n && md_escapable(s[i + 1]):
			strings.write_byte(&sb, s[i + 1])
			i += 2
		case c == '`':
			flush(&out, &sb, bold, ital, false, strike)
			code = true
			i += 1
		case c == '~' && i + 1 < n && s[i + 1] == '~':
			flush(&out, &sb, bold, ital, false, strike)
			strike = !strike
			i += 2
		case c == '*' && i + 1 < n && s[i + 1] == '*':
			flush(&out, &sb, bold, ital, false, strike)
			bold = !bold
			i += 2
		case c == '_' && i + 1 < n && s[i + 1] == '_':
			// `*` may toggle emphasis mid-word; `_` may not (CommonMark's
			// intraword exception applies only to `_`). Without this test,
			// any `_` in a snake_case identifier eats a character and flips
			// every later `_` on the line into an emphasis toggle.
			can_open, can_close := md_delim_flanks(s, i, i + 2)
			if (bold && can_close) || (!bold && can_open) {
				flush(&out, &sb, bold, ital, false, strike)
				bold = !bold
				i += 2
			} else {
				strings.write_byte(&sb, c)
				strings.write_byte(&sb, s[i + 1])
				i += 2
			}
		case c == '*':
			flush(&out, &sb, bold, ital, false, strike)
			ital = !ital
			i += 1
		case c == '_':
			can_open, can_close := md_delim_flanks(s, i, i + 1)
			if (ital && can_close) || (!ital && can_open) {
				flush(&out, &sb, bold, ital, false, strike)
				ital = !ital
				i += 1
			} else {
				strings.write_byte(&sb, c)
				i += 1
			}
		case c == '[':
			// [label](url)
			rb := strings.index_byte(s[i:], ']')
			if rb > 0 && i + rb + 1 < n && s[i + rb + 1] == '(' {
				us := i + rb + 2
				j := us
				for j < n && s[j] != ')' {j += 1}
				if j < n {
					flush(&out, &sb, bold, ital, false, strike)
					append(&out, Md_Run{text = s[i + 1:i + rb], bold = bold, ital = ital, strike = strike, link = true, url = s[us:j]})
					i = j + 1
					continue
				}
			}
			strings.write_byte(&sb, c)
			i += 1
		case:
			strings.write_byte(&sb, c)
			i += 1
		}
	}
	flush(&out, &sb, bold, ital, code, strike)
	return out[:]
}

// The punctuation CommonMark lets a backslash escape. Restricted to that set on
// purpose: escaping a letter is not an escape, it is a backslash followed by a
// letter, and treating it as one would eat backslashes out of Windows paths.
@(private = "file")
md_escapable :: proc(c: u8) -> bool {
	switch c {
	case '\\', '`', '*', '_', '{', '}', '[', ']', '(', ')', '#', '+', '-', '.', '!', '|', '~', '<', '>', '"', '$', '\'', ',', ':', ';', '=', '?', '@', '^':
		return true
	}
	return false
}

// The lexer for a fence's info string, or nil when the tag names nothing known.
//
// Resolved through highlight_lexer_for by building a pseudo-path, so the fence
// and the file extension share ONE table: adding a lexer for `.rs` makes
// ```rust work for free, and the two can never disagree.
md_fence_lexer :: proc(fence_line: string) -> Lexer_Proc {
	tag := strings.trim_space(strings.trim_left(strings.trim_left(fence_line, "`"), "~"))
	if tag == "" {return nil}
	// Only the first word: ```js title="x" is a real thing people write.
	if sp := strings.index_byte(tag, ' '); sp > 0 {tag = tag[:sp]}
	// A handful of names that are not their own extension. Everything else is
	// tried as one directly, which covers c, cs, cpp, json, xml, yaml, toml, ini,
	// sh, bat, md and any lexer added later.
	switch strings.to_lower(tag, context.temp_allocator) {
	case "javascript", "js", "typescript", "ts":
		tag = "c" // close enough for braces, strings and // comments
	case "shell", "console", "bash", "zsh":
		tag = "sh"
	case "yml":
		tag = "yaml"
	case "csharp", "c#":
		tag = "cs"
	case "c++":
		tag = "cpp"
	}
	lexer, _, _, _ := highlight_lexer_for(strings.concatenate({"x.", tag}, context.temp_allocator))
	return lexer
}

// A task list item: `- [ ] thing` or `- [x] thing`. Returns the text after the
// box, and whether it is ticked. GFM, and the one list variant whose absence is
// noticed immediately because a checklist renders as literal brackets.
md_task :: proc(content: string) -> (rest: string, done, is_task: bool) {
	if len(content) < 3 || content[0] != '[' || content[2] != ']' {return content, false, false}
	switch content[1] {
	case ' ':
		done = false
	case 'x', 'X':
		done = true
	case:
		return content, false, false
	}
	rest = content[3:]
	if len(rest) > 0 && rest[0] == ' ' {rest = rest[1:]}
	return rest, done, true
}

// The most steps md_tick_quads will emit per diagonal; the buffer a caller
// needs is twice this, since the X has two of them.
MD_TICK_STEPS :: 32

// The tick inside a ticked task checkbox, as geometry, CENTRED on the box.
//
// Two things were wrong with drawing it as `text_draw(.., "x", bx + bs*0.28,
// y, ..)`. The one Wyatt saw -- "the X is at the bottom right of the box, not
// in the center" -- is that a glyph's ink box is not its layout box: that x is
// a pen origin and that y is a BASELINE, so an "x" placed from the box's
// ORIGIN lands wherever the face's advance and x-height happen to put its ink,
// which for Cascadia Mono at a box of 1.4 cells is low and to the right. The
// second is the reason caption_btn's `.Close` case (ui_tabs.odin) already
// draws its X as a stepped stack of quads: batch 12 moved the chrome onto
// Cascadia Mono, so a glyph is one font substitution away from being a box.
//
// Centring is on the box's CENTRE, not its origin: the returned quads' union
// bounding box is exactly [cx-arm/2, cx+arm/2] x [cy-arm/2, cy+arm/2] by
// construction (each diagonal's f runs 0 ..= arm-st, and a step is st wide),
// which is what the mdtest assertion checks.
//
// Returns the quads rather than drawing them so that assertion needs no device
// -- the md_row_fits precedent.
md_tick_quads :: proc(bx, by, bs: f32, col: [4]f32, out: []plat.Quad) -> (n: int) {
	st := max(1, hairline())
	// Half the box, so the tick clears the border on every side instead of
	// touching it. Clamped to bs itself (Finding 5, 2026-07 review): at a small
	// enough box (bs < 4*st) the unclamped `bs*0.5` still loses to `st*2`, so arm
	// could exceed bs and the origin went negative -- the tick escaped the box it
	// is supposed to sit inside.
	arm := min(bs, max(st * 2, bs * 0.5))

	// A CHECK, not an X. UI spec 9.2 item 9 and §9.4's mockup both show an
	// accent-FILLED box with a dark tick; this drew an accent-outlined box with an
	// X in it, which reads as "rejected" rather than "done".
	//
	// Still quads rather than a glyph, for the reason the X was: batch 12 moved the
	// chrome onto one font, so a glyph is one substitution away from being a box.
	//
	// The bounding box is EXACTLY w x h by construction -- the first stroke starts
	// at the left edge, the second ends at the right, the vertex touches the bottom
	// and the second stroke's end touches the top -- and that box is centred in the
	// checkbox. That is what keeps mdtest's 0.05px centring assertion meaningful: a
	// check leans, so its ink is not symmetric, but the SPAN it occupies still is,
	// and centring the span is the claim that assertion was making about the X.
	w := arm
	h := max(st, arm * 0.72)
	x0 := bx + (bs - w) * 0.5
	y0 := by + (bs - h) * 0.5
	// The USABLE span is (w - st, h - st), not (w, h): every quad is st square
	// and drawn from its origin, so an endpoint at w would put ink at w + st and
	// the tick would escape the box. Caught by mdtest's degenerate case (bs <
	// 4*st), where h - st is small enough that a fraction of h overshoots it --
	// the same class as Finding 5, which is why that case is in the suite.
	uw := max(0, w - st)
	uh := max(0, h - st)
	vx := x0 + uw * 0.38 // where the short stroke meets the long one

	seg :: proc(ax, ay, bx2, by2, st: f32, col: [4]f32, out: []plat.Quad, n: ^int) {
		dx, dy := bx2 - ax, by2 - ay
		span := max(abs(dx), abs(dy))
		// `+2` for the same reason the diagonals used it: strictly more steps than
		// span/st requires, so consecutive st-sized squares overlap or touch and
		// never leave a gap along the stroke. Endpoints stay exact at any count.
		steps := clamp(int(span / st) + 2, 2, MD_TICK_STEPS)
		for i in 0 ..< steps {
			if n^ >= len(out) {return}
			f := f32(i) / f32(steps - 1)
			out[n^] = {pos = {ax + dx * f, ay + dy * f}, size = {st, st}, color = col}
			n^ += 1
		}
	}
	seg(x0, y0 + uh * 0.42, vx, y0 + uh, st, col, out, &n)
	seg(vx, y0 + uh, x0 + uw, y0, st, col, out, &n)
	return
}

// YAML front matter: a `---` fence on line 1, closed by `---` or `...`. Returns
// the byte offset just past the closing fence, and how many lines sit BETWEEN
// the two fences; `end` is 0 when the document does not open with one. Bounded
// by a line budget so a file whose first line happens to be `---` cannot make
// this scan to EOF looking for a close that is not there.
//
// `inner` is what sizes the card md_front_matter_quads draws, via md_fm_rows:
// the block draws its two fence lines TOO (see md_fm_rows), so the card covers
// inner + 2 rows.
MD_FM_MAX_LINES :: 64

md_front_matter_end :: proc(doc: ^Document) -> (end: int, inner: int) {
	if doc == nil || doc.pt.length < 4 {return 0, 0}
	// RENDER_LINE_CAP, not a smaller local cap (Finding 7, 2026-07 review): this
	// scan and markdown_draw's own closing-fence check (`buf: [RENDER_LINE_CAP]u8`
	// there) must agree on what a line's TEXT is, or a line that trims to `---`
	// within a shorter buffer but not in full is a fence to one and a plain row
	// to the other -- the card and the draw's row-advance would then size
	// themselves from different inputs and disagree. md_line_at already bounds
	// the line's END at RENDER_LINE_CAP regardless of `buf`'s size; only the
	// returned TEXT was truncated shorter here, which is what this fixes.
	buf: [RENDER_LINE_CAP]u8
	line, e0, _ := md_line_at(doc, 0, buf[:])
	if strings.trim_space(line) != "---" {return 0, 0}
	p := e0 + 1
	for _ in 0 ..< MD_FM_MAX_LINES {
		if p >= doc.pt.length {return 0, 0} // never closed: not front matter
		l2, e2, _ := md_line_at(doc, p, buf[:])
		t := strings.trim_space(l2)
		if t == "---" || t == "..." {return min(e2 + 1, doc.pt.length), inner}
		inner += 1
		p = e2 + 1
	}
	return 0, 0
}

// Inset between the front-matter card's top/bottom edge and its text, at 96 dpi.
MD_FM_PAD_96 :: f32(5)

md_fm_pad :: #force_inline proc() -> f32 {return max(2, sx(MD_FM_PAD_96))}

// How many TEXT ROWS a front-matter block of `inner_lines` key/value lines
// draws: the key/value lines plus the opening and the closing delimiter.
//
// The `+ 2` is item 3 of the 2026-07-29 live-pass regressions. The card
// originally swallowed the `---` lines entirely -- "the card IS the delimiter"
// -- but Wyatt's description of what he wants to see is "i see the start and
// end ---", so the delimiters are back, drawn as muted TEXT on the card surface
// rather than as the Md_Rule horizontal rules that made the block read as two
// separate lines in the first place. Still a PLACEHOLDER for his eye: this
// restores information he had, it does not settle the design.
//
// One producer, and this is the reason it exists as a named procedure rather
// than a `+ 2` spelled inline: md_fm_height sizes the card, md_draw_front_matter
// draws exactly this many rows onto it, and markdown_draw advances past the
// block by md_fm_height. A row count that disagreed with the card's height would
// put text outside the card, which mdtest samples for.
md_fm_rows :: #force_inline proc(inner_lines: int) -> int {return max(0, inner_lines) + 2}

// The card's height for a block of `inner_lines` key/value lines: every row it
// draws (md_fm_rows) plus the inset above the first and below the last.
md_fm_height :: #force_inline proc(line_h: f32, inner_lines: int) -> f32 {
	return f32(md_fm_rows(inner_lines)) * line_h + md_fm_pad() * 2
}

// The card behind YAML front matter. ONE panel spanning the whole block, at
// the surface fenced code already uses (Md_Code_Bg) and the radius tabs and
// the find bar use, with the text inset from its edges.
//
// PLACEHOLDER, and stated as one: this is a first draft for Wyatt to react to
// on the next live pass, per "I don't know about the colour shades... just put
// in a placeholder that would be close to the final anyways". It reuses a
// surface he has already accepted rather than inventing a value, so it sits
// consistently with the rest of the preview, but the final treatment is his
// call. What it REPLACES is not a placeholder question, though: the old code
// drew a 2px Md_Rule down the left of every front-matter line, which is the
// blockquote's own decoration -- "I see like a quote bar on the side but it's
// thinner" -- so front matter and a quote read as the same construct. UI spec
// 9.2 item 12 asks for a muted card.
//
// Returns the quads instead of drawing them so mdtest can assert the shape
// (one panel, no per-line rules) without a device -- the md_row_fits
// precedent.
// `ytop` is the TOP of the block's first row -- the opening `---`, which since
// item 3 of the 2026-07-29 regressions is drawn as muted text ON this card
// rather than skipped. The card starts exactly at that row top and its `pad`
// inset is taken out of the row, so the card never reaches up past the pane's
// own top edge.
md_front_matter_quads :: proc(x0, x1, ytop, line_h: f32, inner_lines: int, out: []plat.Quad) -> (n: int) {
	if len(out) == 0 || inner_lines < 0 {return 0}
	r := RADIUS_TAB
	out[0] = {
		pos = {x0, ytop},
		size = {max(0, x1 - x0), md_fm_height(line_h, inner_lines)},
		color = g_theme[.Md_Code_Bg],
		radius = {r, r, r, r},
	}
	return 1
}

// The whole front-matter block: the card, then every one of its lines drawn on
// top of it -- INCLUDING the two `---` delimiters.
//
// Drawn as ONE unit rather than a row at a time inside markdown_draw's loop,
// which is what makes md_fm_height the single producer of the block's height.
// The old shape composed that height TWICE: md_fm_height sized the card, while
// the loop re-derived the same total as a sum of per-fence `md_fm_pad()` and
// per-row `line_h` increments. Nothing forced the two to stay equal, and item 3
// (which adds two rows) would have had to be applied to both. Here the caller
// advances past the block by md_fm_height and nothing else, so a row count that
// disagreed with the card would be visible as text spilling off the card --
// which is exactly what mdtest samples for.
//
// PLACEHOLDER: the delimiters draw at Text_Muted, the same tier as the values,
// which is the least invented thing available and reads as "muted text on a
// muted card". Wyatt's to retune on the next live pass along with the card
// itself.
@(private = "file")
md_draw_front_matter :: proc(
	gfx: ^plat.Gfx,
	qp: ^plat.Quad_Pipeline,
	text: ^plat.Text,
	doc: ^Document,
	x0, x1, card_top, px, char_w, line_h: f32,
	fm_end, fm_inner: int,
) {
	fq: [1]plat.Quad
	nq := md_front_matter_quads(x0, x1, card_top, line_h, fm_inner, fq[:])
	plat.quads_draw(gfx, qp, fq[:nq])
	// No markdown parsing at all: it is YAML, and running a `*` or `_` in a
	// value through the inline parser would style it as emphasis. The
	// delimiters go through the same plain path for the same reason -- and
	// because `---` through the block classifier is an Md_Rule, the horizontal
	// rule this card exists to replace.
	buf: [RENDER_LINE_CAP]u8
	ry := card_top + md_fm_pad() + px // first baseline inside the card
	for p := 0; p < fm_end; {
		line, end, _ := md_line_at(doc, p, buf[:])
		plat.text_draw(gfx, text, line, x0 + char_w, ry, px, g_theme[.Text_Muted], .Doc)
		ry += line_h
		if end >= doc.pt.length {break}
		p = end + 1
	}
}

// Lerp a colour toward the page background, for muting a completed task item.
//
// A TRANSFORM applied per run, not a base colour substituted for the whole
// line. The bug it replaces: task_col was set to Text_Muted and handed to
// md_draw_inline as `base_col`, but every run that carries its own role --
// code, links, emphasis, bold -- resolves that role and ignores the base
// entirely. So the prose muted and nothing else did, which is exactly what
// Wyatt reported: "the base color text gets muted but the theme colors don't,
// maybe we just add a filter over all colors dropping them the same percent".
// This is that filter.
//
// Alpha is carried through untouched: muting is a tone change, and folding it
// into alpha would make a done item composite differently over the find-match
// wash than a live one.
md_mute :: proc(c: [4]f32, k: f32) -> [4]f32 {
	bg := g_theme[.Bg_Base]
	return {c.r + k * (bg.r - c.r), c.g + k * (bg.g - c.g), c.b + k * (bg.b - c.b), c.a}
}

// PLACEHOLDER -- Wyatt, on this batch: "I don't know about the colour shades...
// just put in a placeholder that would be close to the final anyways." Tune it
// on the next live pass.
//
// Not a guess, though. Muting is a lerp toward Bg_Base, so solving
// mute(Text_Primary) == Text_Muted per channel asks "what k reproduces the
// muted tier this theme already ships?" Against theme.odin's actual values
// that is 0.280/0.299/0.315 in Dark (mean 0.298) and 0.244/0.217/0.199 in
// Light (mean 0.220) -- the two themes disagree, so one constant cannot hit
// both, and 0.26 sits between them. Worst per-channel miss is 0.033 in Dark
// and 0.047 in Light (Light's blue, whose two tiers are furthest apart), which
// is why mdtest's bound below is 0.05 rather than the 0.02 the task brief
// assumed. The point of the derivation is that 0.26 lands on a tier Wyatt
// already accepts rather than being picked by eye.
MD_DONE_MUTE :: f32(0.26)

// The prose base colour and mute fraction for a task item's inline content,
// given whether it is done. Pulled out of markdown_draw's task branch (which
// used to set both as two inline assignments) so mdtest can ask "what colour
// does a done item's prose actually get" by calling the EXACT procedure the
// draw calls, with the exact argument the draw passes -- not a copy of the
// logic and not a hand-picked MD_DONE_MUTE disconnected from the call site.
// A 2026-07 review found the old shape blind to precisely this: sabotaging the
// call site alone (`task_mute = 0`) left every mdtest assertion green, because
// the test only ever drove md_run_color directly.
//
// The base is ALWAYS Text_Primary, done or not: md_run_color's own mute step
// (not a pre-muted base) is what drops a done item's prose to the muted tier.
// Passing Text_Muted here would drop it TWICE -- once by starting from an
// already-muted base, once more by lerping that base toward the page (Finding
// 1, 2026-07 review): mute(Text_Muted, 0.26) measures 3.58:1 against Bg_Base in
// Dark and 3.28:1 in Light, both under the 4.5:1 every text role in theme.odin
// is annotated against, versus mute(Text_Primary, 0.26) at ~5.4:1 / ~6.0:1 --
// which is Text_Muted's OWN contrast, restored rather than halved again.
@(private = "file")
md_task_prose_style :: proc(done: bool) -> (col: [4]f32, mute: f32) {
	if !done {return g_theme[.Text_Primary], 0}
	return g_theme[.Text_Primary], MD_DONE_MUTE
}

// One inline run's colour: its role, then the done-item mute.
//
// Split out of md_draw_inline so mdtest can assert the thing that actually
// broke -- that a THEMED run mutes, not just the base-coloured prose -- without
// a device. Asserting md_mute alone would prove nothing: "the lerp moves a
// colour toward the background" is a property of any lerp, and the pre-fix code
// would satisfy it too.
@(private = "file")
md_run_color :: proc(run: Md_Run, base_col: [4]f32, mute: f32) -> [4]f32 {
	col := base_col
	if run.code {col = g_theme[.Md_Code]}
	if run.ital {col = g_theme[.Md_Italic]}
	if run.link {col = g_theme[.Link]}
	if run.bold && !run.code && !run.link {col = g_theme[.Text_Bright]}
	// Struck text drops to muted as well as getting its line. UI spec 18's
	// "never colour alone" runs both ways: the LINE is the primary cue, so a
	// reader who cannot see the tone still gets it, and the tone stops struck
	// text competing with live text for attention.
	if run.strike {col = g_theme[.Text_Muted]}
	if mute > 0 {col = md_mute(col, mute)}
	return col
}

// Does something whose TOP edge is `ytop` and whose extent is `h` fit entirely
// above `ybot`?
//
// One expression, and its own procedure so a test can drive it without a
// device. It replaces md_row_fits, which asked the same question about a
// BASELINE (`y - px + row_h <= ybot`); the preview no longer walks baselines,
// so the -px correction that turned a baseline into a row top has nothing left
// to correct. The property it exists to protect is unchanged and is the reason
// it is a named procedure at all: there is no scissor rect in this renderer
// (clipping is the cover strip main.odin paints afterwards), so the only way
// GLYPHS are not cut through the middle is for them not to be ADMITTED.
//
// 2026-07-29, Wyatt's report: this used to be asked once per BLOCK, with `h` the
// block's own height, and the admit site refused the whole block. That is right
// for a heading -- one line, fits or does not -- and wrong for a paragraph,
// which since batch 17 is an arbitrary number of shaped lines: a pane with room
// for four of a paragraph's five lines showed a heading and then 200px of blank.
// So the question is now asked once per LINE, `h` is md_line_bottom's answer,
// and md_block_admit is the only place that asks it. A single-line block, and
// every kind the shaper did not place, reduces to exactly the old call (see
// md_block_lines), which is why no other kind's behaviour moved.
md_block_fits :: #force_inline proc(ytop, h, ybot: f32) -> bool {
	return ytop + h <= ybot
}

// Is this kind's height a stack of independently admissible SHAPED lines?
//
// False for everything the shaper did not place: a rule and a fence's open/close
// padding strip are one indivisible band, and the front-matter card is drawn whole
// (md_draw_front_matter paints its frame and all its rows in one call, so there is
// no line to stop at). A Blank block has no height at all. Those kinds keep
// whole-block admission, and md_block_lines returning 1 for them is what makes
// that literally the same test they had before.
//
// .Table MOVED HERE 2026-07-29, and this is the pairing the guard in md_block_draw
// exists for: a table row's cells are now shaped (plat.shape_columns), so a row is
// a stack of visual lines exactly as a paragraph is and it reaches shaped_draw the
// same way. Leaving it on the indivisible side would have made md_block_lines
// return 1 for a three-line row and shaped_draw would have emitted only the first
// line -- a wrapped table silently rendering one line per row, with mdtabletest
// (cell arithmetic only) still green. The guard turns that into a panic.
@(private = "file")
md_kind_lines :: #force_inline proc(k: Md_Kind) -> bool {
	switch k {
	case .Para, .Heading, .Quote, .List, .Fence_Body, .Table:
		return true
	case .Blank, .Rule, .Fence_Open, .Fence_Close, .Front_Matter:
		return false
	}
	return false
}

// How many independently admissible lines a block has. Never zero: a kind the
// shaper did not place is ONE line whose bottom is the block's own height, so
// md_block_admit degenerates to a single md_block_fits call for it.
@(private = "file")
md_block_lines :: #force_inline proc(lay: ^Md_Layout) -> int {
	if lay == nil || !md_kind_lines(lay.cls.kind) {return 1}
	return max(1, len(lay.sh.line_boxes))
}

// The bottom edge of visual line `l`, as an offset from the block's own top.
//
// THE last line's bottom is the block's `h`, not its line box's -- a block's
// trailing decoration lives in the gap between the two (an h1/h2 rule is inside
// Md_Layout.h, added after the shaper's height). Reading the line box there
// would admit a last line whose rule then paints one row below what the admit
// test budgeted for, which on the pane's last block is a hairline on the status
// bar: the exact shape of item 6 of the 2026-07-29 regressions. It also keeps
// `whole` and `md_block_fits(y, lay.h, ybot)` the same predicate, so a
// single-line heading is admitted on precisely the terms it was before.
@(private = "file")
md_line_bottom :: #force_inline proc(lay: ^Md_Layout, l: int) -> f32 {
	if lay == nil {return 0}
	if l >= md_block_lines(lay) - 1 {return lay.h}
	return lay.sh.line_boxes[l].top + lay.sh.line_boxes[l].h
}

// How much of one block a pane admits.
//
// `lines` is how many of its visual lines were admitted (0 == none: the block is
// refused), `h` the height those lines occupy from the block's top, and `whole`
// says the block has nothing left to reveal -- which is what lets the pass
// advance past it and continue to the next.
//
// File-private on purpose: the only producer is md_block_admit and the only route
// to it is md_place_next, so a value of this type outside this file would mean a
// second answer to "what is on screen" existed.
@(private = "file")
Md_Admit :: struct {
	lines: int,
	h:     f32,
	whole: bool,
}

// THE per-line admit rule, and its only expression.
//
// One producer, because a per-line draw with a per-block hit-test is CLAUDE.md's
// "a correct function fed the wrong input" by construction -- HANDOFF 6j counts
// sixteen instances of that shape. md_place_next is the only caller, and
// md_pass's draw and md_block_at_y's click map both consume md_place_next, so
// the ink and the click cannot be answering two different questions.
//
// `forced` is the first block's waiver, narrowed by this change from the whole
// block to its first LINE: a pane too short for even one line still shows one
// ("no frame ever shows emptiness" outranks the cover strip's trim), but a pane
// too short for a five-line paragraph no longer draws all five and lets the
// strip eat four.
@(private = "file")
md_block_admit :: proc(lay: ^Md_Layout, y, ybot: f32, forced: bool) -> (a: Md_Admit) {
	n := md_block_lines(lay)
	for l in 0 ..< n {
		if !md_block_fits(y, md_line_bottom(lay, l), ybot) {break}
		a.lines = l + 1
	}
	if a.lines == 0 && forced {a.lines = 1}
	if a.lines == 0 {return}
	a.whole = a.lines >= n
	a.h = lay.h if a.whole else md_line_bottom(lay, a.lines - 1)
	return
}

// --- UI spec 9.1, the block/span model --------------------------------------
//
//	Block :: struct { kind, level, spans: []Span, indent }
//	Span  :: struct { text, style_flags, colour_role }
//
// A block is derived from a RUN of source lines. It used to be one line, with a
// blank run, front matter and a table's column measure as the bounded exceptions;
// paragraph joining made the run the general case.
//
// PARAGRAPH JOINING -- treating a paragraph's hard line breaks as soft, per 9.2 --
// IS DONE (2026-08-01). This comment said it was "still not done" through the
// three commits that did it, which is why it is being rewritten rather than
// deleted: it was right about what the change would cost, and that is worth
// keeping.
//
// It predicted a PARSER change rather than a scroll change -- altering which
// source lines form a block, which moves every block start byte, which is the
// layout cache's key, the anchor's identity, 9.4's sync map and the fence seed's
// input. All five moved, and each one cost something:
//
//   * the layout cache's key -- a block cached while single-line survived the
//     append that should have joined it (see md_join_end)
//   * the anchor's identity -- the run-up landed inside a joined paragraph and the
//     preview drew from line 0 while the editor sat at line 100 (md_block_start_at)
//   * 9.4's sync map -- sync is now per BLOCK over hard-wrapped prose, which is
//     what 9.4 asks for, but coarser than what the one-line-per-block model gave
//     by accident
//
// The prediction that it should not be batched with the scroll model was wrong in
// one direction: the scroll model had to change WITH it (md_block_start_at), not
// after it, because a construct that starts above its own line cannot be found by
// a fixed line run-up.

Md_Style :: enum u8 {
	Bold,
	Italic,
	Code,
	Link,
	Strike,
}
Md_Styles :: bit_set[Md_Style;u8]

// What KIND of block one source line is. The switch in md_block_draw has
// exactly these branches and Odin's exhaustiveness check keeps the two lists
// the same list.
Md_Kind :: enum u8 {
	Para, // the fallthrough case, so a zeroed block is the harmless one
	Blank, // a RUN of blank lines, collapsed (see MD_BLANK_RUN_MAX)
	Fence_Open,
	Fence_Body,
	Fence_Close,
	Rule,
	Heading,
	Quote,
	List,
	Table,
	Front_Matter,
}

// One styled span of a block's inline content, parallel to the plat.Shape_Span
// the shaper was handed: index i of one describes index i of the other.
//
// Split in two rather than carried as one struct because the shaper's input is
// deliberately (text, px, set) and nothing else -- it needs a face and a size to
// lay out, and colour is not its business. `span` on every Shaped_Glyph is the
// join key between the two.
Md_Span :: struct {
	style: Md_Styles,
	color: [4]f32,
	url:   string, // .Link spans only; slices into the block's own text store
}

// What one source line classifies as, before anything is measured or laid out.
// Pure, and the same order of tests the old row loop applied, so no line
// changes kind.
Md_Class :: struct {
	kind:      Md_Kind,
	level:     int, // heading level, quote depth, or list nesting depth
	content:   string, // the inline content (a slice of the line handed in)
	bullet:    string, // the list marker to draw (a slice, or the "•" literal)
	task:      bool,
	task_done: bool,
	is_sep:    bool, // a table separator row draws as a rule, not as cells
	// Is this row the FIRST or LAST of its table? §9.4 draws a table as one
	// bordered card, but a table reaches the draw as one block PER ROW, each
	// admitted independently by the viewport -- so the card's top edge, bottom
	// edge and rounded corners have to be attributed to a row, and only the
	// layout knows which row it is looking at.
	//
	// Decided here rather than in the draw because md_table_ensure is already
	// called here and carries the table's byte range; asking again from the draw
	// would be a second producer of "where does this table begin", and a frame
	// where the two disagreed would draw a card with two tops or none.
	tbl_first: bool,
	tbl_last:  bool,
}

md_classify :: proc(line, trimmed: string, in_fence: bool) -> (c: Md_Class) {
	switch {
	case md_is_fence_line(line):
		c.kind = .Fence_Close if in_fence else .Fence_Open
	case in_fence:
		c.kind, c.content = .Fence_Body, line
	case len(strings.trim_space(line)) == 0:
		c.kind = .Blank
	case md_is_rule(trimmed):
		c.kind = .Rule
	case:
		if lvl := md_heading_level(trimmed); lvl > 0 {
			c.kind, c.level = .Heading, lvl
			c.content = strings.trim_left(trimmed[lvl:], " ")
			return
		}
		if q, qcontent, qdepth := md_quote_depth(trimmed); q {
			c.kind, c.content, c.level = .Quote, qcontent, qdepth
			return
		}
		// md_list reads the RAW line: its leading indent is the nesting depth.
		if bullet, content, depth := md_list(line); bullet != "" {
			c.kind, c.bullet, c.content, c.level = .List, bullet, content, depth
			if rest, done, is_task := md_task(content); is_task {
				c.task, c.task_done, c.content = true, done, rest
			}
			return
		}
		if md_is_table_row(line) {
			c.kind, c.is_sep = .Table, md_row_is_sep(line)
			return
		}
		c.kind, c.content = .Para, line
	}
	return
}

// One span's box on ONE visual line of a shaped block, in the block's own
// coordinate space (x from the block's content origin, y from its top).
//
// THIS IS THE SEAM. It is the single producer of every pixel rectangle derived
// from a span: the inline-code background, the strikethrough rule, the link
// underline, the link hit-test and the hand cursor all read a box from here and
// none of them computes one. A span that wraps across a soft break produces one
// box per visual line it touches, which is what makes a wrapped link clickable
// on both of its rows rather than on a rectangle spanning the gap between them.
//
// `w` is an ADVANCE bound, not an ink bound: the right edge is the last glyph's
// pen position plus that glyph's advance, so it excludes right side bearing and
// any ink overhanging the advance (an italic `f`). That is a deliberate choice
// for a HIT-TEST -- the advance box is the region a reader perceives as
// belonging to the character, an ink box would leave dead gaps between adjacent
// glyphs of a link, and the underline drawn from the same number then matches
// the clickable region EXACTLY, which is the property that actually matters
// here. The cost is that up to a fraction of a pixel of an italic tail can sit
// outside the box.
Md_Span_Box :: struct {
	span:     int,
	line:     int,
	x, y:     f32, // left edge, and the TOP of the line box
	w, h:     f32,
	baseline: f32, // the line's baseline, for the strike rule
}

// Every span's boxes, one per (span, visual line) it has glyphs on.
//
// Reads nothing but the Shaped the shaper produced plus the same advance oracle
// the shaper laid out with (plat.text_advance -> glyph_get -> the atlas map), so
// the right edge cannot be a different number from the one the break decision
// used. Glyphs arrive in span-then-offset order within a line, so a single pass
// with a "same (span, line) as the last box" test collects them.
md_span_boxes :: proc(gfx: ^plat.Gfx, t: ^plat.Text, sh: ^plat.Shaped, shape: []plat.Shape_Span, allocator := context.temp_allocator) -> []Md_Span_Box {
	out := make([dynamic]Md_Span_Box, 0, 8, allocator)
	for g in sh.glyphs {
		si, li := int(g.span), int(g.line)
		if si < 0 || si >= len(shape) || li < 0 || li >= len(sh.line_boxes) {continue}
		adv := plat.text_advance(gfx, t, g.r, shape[si].px, shape[si].set)
		if n := len(out); n > 0 && out[n - 1].span == si && out[n - 1].line == li {
			// Right edge first, then the left, then the width from the two.
			// Widening in place (`w = max(w, g.x + adv - x)`) is only correct
			// while `x` never moves, which is true of the order glyphs arrive in
			// today and is exactly the assumption that stops being true the
			// moment anything reorders them.
			b := &out[n - 1]
			right := max(b.x + b.w, g.x + adv)
			b.x = min(b.x, g.x)
			b.w = right - b.x
			continue
		}
		lb := sh.line_boxes[li]
		append(&out, Md_Span_Box{span = si, line = li, x = g.x, y = lb.top, w = adv, h = lb.h, baseline = lb.y})
	}
	return out[:]
}

// A link placed on screen by the preview: an ABSOLUTE-coordinate rectangle plus
// what it points at.
//
// The preview's answer to Link_Hit, and deliberately not the same struct: a
// Link_Hit is (row, col, cells) on the editor's cell grid, which the preview
// does not have. Everything downstream of this -- the underline main.odin
// draws, md_link_at's hit-test and the hand cursor -- consumes the `rect` this
// carries and never re-derives it from a column.
Md_Link_Hit :: struct {
	rect:   plat.Quad, // pos/size only; colour is the consumer's business
	base_y: f32, // the baseline the link's glyphs sit on, for the underline
	url:    string, // the raw target text, as written in the document
	text:   string, // the text `link`'s offsets index into
	link:   Link, // for link_resolve / link_follow
}

// Underline every placed link. The affordance, drawn from the SAME rectangles
// md_link_at accepts and offset to the baseline exactly as the editor pane's is
// (row_baseline_y + 2). Nothing here recomputes a position.
md_draw_links :: proc(gfx: ^plat.Gfx, qp: ^plat.Quad_Pipeline, hits: []Md_Link_Hit) {
	for h in hits {
		plat.quads_draw(gfx, qp, []plat.Quad{{pos = {h.rect.pos.x, h.base_y + sx(2)}, size = {h.rect.size.x, hairline()}, color = g_theme[.Link]}})
	}
}

// The link under a client-space point, or nil. Point-in-rect against the SAME
// rectangles the underline is drawn from, produced by md_span_boxes and by
// nothing else. There is no row_at_y and no cell_at_x here on purpose: the
// preview's glyphs do not sit on the cell grid those two describe, and asking
// them would be the "correct function fed the wrong input" bug this project has
// sixteen recorded instances of.
//
// Deliberately NO y bound of its own. This is point-in-rect and nothing else;
// the pane's bound lives in md_preview_link_at, its only caller, applied ONCE to
// the point. A second bound here would make each of the two invisible to the
// suite -- the failure a reviewer found the last time this codebase bounded the
// same thing in two places -- and would also have to re-derive the pane box that
// md_preview_link_at already has.
md_link_at :: proc(hits: []Md_Link_Hit, mx, my: f32) -> (Md_Link_Hit, bool) {
	for h in hits {
		r := h.rect
		if mx >= r.pos.x && mx < r.pos.x + r.size.x && my >= r.pos.y && my < r.pos.y + r.size.y {
			return h, true
		}
	}
	return {}, false
}

// Does this line (RAW, not pre-trimmed -- see below) open or close a fenced
// code block?
//
// One predicate, used by markdown_draw's toggle AND by mdfencetest's walk, so
// the test cannot pass while agreeing with a rule the draw doesn't apply.
//
// CORRECTED (2026-07 review, Finding 2): this used to take an already
// `strings.trim_left(line, " \t")`-ed string and check only the prefix, which
// made it LOOSER than base.lex_markdown's mk_leading_spaces/mk_match_fence in
// a way that mattered once the drawer's toggle started SEEDING from the
// lexer's state (md_fence_seed): a line indented 4+ spaces, or led by a tab,
// toggled here but was invisible to the lexer. The old comment claimed that
// divergence "only ever means md_fence_seed declines to seed... never that it
// seeds a fence the draw would not have entered" -- false. The fence bit is
// PARITY (an even/odd count of toggle lines since the top), not membership in
// a set, so an ODD number of such lines above top_byte flips md_fence_seed's
// answer the WRONG way relative to what a walk from byte 0 actually draws
// (mdfencetest's indented-fence case pins this). Fixed by mirroring
// mk_leading_spaces + mk_match_fence exactly instead of trimming: an indent of
// 4+ columns is CommonMark's indented-code-block rule, not a fence-opener, and
// a tab does not count as indent at all here (matching mk_leading_spaces,
// which only ever advances past `' '`) -- so a tab-led line's lead is 0 and
// its first byte is the tab itself, never a backtick or tilde. This is now
// the SAME rule the lexer applies, not merely a looser one that fails safe.
md_is_fence_line :: proc(line: string) -> bool {
	lead := 0
	for lead < len(line) && lead < 4 && line[lead] == ' ' {lead += 1}
	if lead > 3 || lead >= len(line) {return false}
	ch := line[lead]
	if ch != '`' && ch != '~' {return false}
	run := 0
	for lead + run < len(line) && line[lead + run] == ch {run += 1}
	return run >= 3
}

// The fence state markdown_draw must START in when it begins drawing at
// `top_byte`, and the lexer for that fence's language.
//
// The bug this exists to kill: markdown_draw seeded `in_fence := false` and
// began scanning at top_byte, so scrolling past an opening fence lost the bit.
// The block's contents then drew as ordinary markdown AND the CLOSING fence
// toggled in_fence ON -- turning the whole rest of the file into a code block.
// Wyatt reported both halves separately ("when the code block start goes off
// screen, the viewport stops rendering the whole codeblock" and "it just makes
// the rest of the file a codeblock"); they are the same lost bit, seen before
// and after the closing fence.
//
// Nothing new is invented here. The plain editor already answers "what is the
// lexer's state at this byte" for exactly this reason -- doc_lex_state_at, via
// the background per-line index with a bounded resync fallback -- and
// base.lex_markdown's Lex_State already encodes "inside an unterminated fence"
// as .In_Comment (see that file's header). markdown_draw simply never asked.
//
// The one thing the state cannot carry is the fence's language tag, since
// Lex_State is a scalar. lex_index_fence_open finds the fence-open LINE through
// the index in O(log n) and the tag is read off it. When that lookup declines
// (huge mapped file, or an index stale against the current revision) the block
// draws UNCOLOURED: still correctly a fence, just without syntax colours.
//
// Two documented ways this seeds `false` where a draw from byte 0 would have
// been inside a fence, both of them the pre-fix behaviour and neither of them a
// new wrong answer:
//   - doc.path's extension isn't in EXT_LEXERS with base.lex_markdown (an
//     unsaved buffer switched into preview, or -- before this task's Finding 1
//     fix -- one of .mkd/.mdown/.mdwn/.mdtext/.mdx/.mtext, which
//     doc_is_markdownish (doc.odin's MARKDOWN_EXTS) let into Preview but
//     EXT_LEXERS never gave a lexer), so highlight_lexer_for picks no lexer
//     and the state is .Normal.
//   - the opening fence is indented 4+ spaces or led by a tab, which
//     base.lex_markdown deliberately does not treat as a fence-opener
//     (CommonMark: 4+ columns is an indented code block instead) and
//     md_is_fence_line now agrees (see its own comment, Finding 2) -- so the
//     seed correctly stays out, matching what a walk from byte 0 would do.
md_fence_seed :: proc(doc: ^Document, top_byte: int) -> (in_fence: bool, fence_lex: Lexer_Proc) {
	if doc == nil || top_byte <= 0 {return false, nil}
	// Finding 4 (2026-07 review): in .Preview mode markdown_draw REPLACES the
	// text pass (main.odin's .Preview branch), so doc_draw's bootstrap resync
	// never runs and this doc_lex_state_at call is net-new per-frame work.
	// base.lex_markdown_resync_valid ALWAYS rejects (see its own comment --
	// "```" toggles rather than having distinct open/close forms, so a bounded
	// window can't know the state without full parity since byte 0), and a
	// mapped document never gets the background per-line index
	// (lex_index_start refuses to run over mapped content -- see
	// Lex_State_Index's struct comment), so doc_lex_state_at always falls
	// through to lex_resync_state for one. lex_resync_state's own
	// window-exhausted branch (`if win_start != 0 {return .Normal, true}`)
	// means: whenever top_byte sits further than LEX_RESYNC_WINDOW past byte
	// 0, the backward anchor scan can never reach byte 0, every candidate gets
	// rejected by the always-false validator, and the answer is PROVABLY
	// .Normal -- bought at a 64 KiB pt_read plus the candidate-validation loop
	// (up to LEX_RESYNC_MAX_VALIDATE_BYTES), every frame, for a constant.
	// Skipping straight to that constant in exactly this case is a pure cost
	// cut, not a behaviour change.
	//
	// Deliberately NOT "if doc.fv.mapped {return false, nil}" unconditionally:
	// when top_byte <= LEX_RESYNC_WINDOW the backward scan DOES reach byte 0
	// (unambiguously .Normal on its own -- see lex_resync_state), so
	// lex_resync_state does a real forward lex from byte 0 to top_byte and can
	// return a genuine non-.Normal answer. That is exactly the case this
	// task's fix exists for on a large (mapped, >= plat.FILE_MMAP_THRESHOLD)
	// file scrolled only partway in -- an unconditional mapped-skip would
	// silently reintroduce Wyatt's original bug for it, so the guard checks
	// top_byte against the window too, not "mapped" alone.
	if doc.fv.mapped && top_byte > LEX_RESYNC_WINDOW {return false, nil}
	if doc_lex_state_at(doc, top_byte, LEX_RESYNC_WINDOW) == .Normal {return false, nil}
	in_fence = true
	if open, ok := lex_index_fence_open(doc, top_byte); ok {
		buf: [RENDER_LINE_CAP]u8
		line, _, _ := md_line_at(doc, open, buf[:])
		fence_lex = md_fence_lexer(strings.trim_left(line, " \t"))
	}
	return
}

// --- the layout cache (UI spec 9.1) -----------------------------------------
//
// "Cache each block's laid-out glyph positions, keyed by (block index, pane
// width). Invalidate a block on edit; invalidate all on resize or zoom."
//
// CORRECTION, and it is the one place this deviates from the spec's wording: the
// key is the block's START BYTE, not its index. The block list is built lazily
// from the scroll anchor forward (viewport-first is a hard rule, so there is no
// document-wide list to index into), which means "block 3" is a different block
// after every scroll step, and an index key would return another block's glyphs.
// The start byte is the block's identity and does not move when the viewport
// does.
//
// The start byte alone is NOT a sufficient identity, and this is the non-obvious
// part. Two blocks cannot share a start byte -- but the same start byte can name
// a block whose EXTENT changed while its stripped source text did not. md_pass
// strips the trailing `\r` before handing `line` to the key, so a CRLF -> LF
// conversion leaves every `src` byte-identical while every `end`/`next` shifts.
// A hit then resumes the pass one byte late per converted line, and the next
// block renders with its first character eaten. Hence `end` in the key: the
// caller already has it from pt_line_end_cap, so it costs one compare.
//
// The rest of the key is everything a block's layout is a function of:
//
//	start        the block's first byte -- its identity
//	end          its LAST byte, so a line whose raw length changed but whose
//	             stripped text did not (CRLF <-> LF) misses. See above.
//	src          its own source text, held as an OWNED copy. This is what makes
//	             invalidation PER-BLOCK on edit: nothing here consults
//	             doc.revision, so editing one line leaves every other block's
//	             entry usable. (An insert shifts the start byte of everything
//	             after it, so those rebuild; that is inherent to a byte identity,
//	             not a property of this comparison.)
//	measure      the column it was broken to -- "pane width"
//	px           the base size S -- "zoom"
//	ui_scale     the DPI scale. `indent` bakes sx()-scaled insets (a fence's 12px
//	             pad, a list's 24px per level, a quote's 16px), and when the pane
//	             is wide enough for the 72ch cap to bind, `measure` is a function
//	             of S alone -- so a monitor change with no window-size change
//	             moves every inset while nothing else in the key moves.
//	theme        the palette the spans' colours were BAKED from. Md_Span.color is
//	             resolved at build time now (the old code called md_run_color per
//	             draw), so without this a theme switch leaves warm-white body text
//	             and amber headings on a light background until the entries are
//	             evicted. See md_theme_gen for why it is a hash and not a counter.
//	faces        which font families were loaded when the entry was SHAPED. The
//	             same mechanism as `theme` one row up, for geometry instead of
//	             colour: glyph positions, soft-wrap points and the block's height
//	             all come out of the shaper at the loaded faces' advances.
//	             Settings > Font reloads the .Doc chain, which inline code and
//	             fenced blocks draw on, and text_reset_atlas drops the rasterized
//	             glyphs without touching a laid-out entry -- so the atlas fills
//	             with the new family while the cache keeps the old family's
//	             spacing, wrap points, code backgrounds and link rects. Every
//	             other term is invariant under it, `measure` included: that is 72
//	             advances of the BODY face, which a .Doc change does not move.
//	fence in/out the lexer state it was coloured under; the SAME line is prose or
//	             code depending on it, so it is part of the key and not a result
//	revision     for kinds whose layout depends on bytes OUTSIDE their own src:
//	             a table row (its columns are measured across the whole block), a
//	             blank RUN (its extent is the following lines) and front matter
//	             (drawn from the document). Those three cannot be validated by
//	             their own text, so they take the coarse key; everything that
//	             carries real shaping work takes the fine one.
//
// A resize changes `measure`, a zoom changes `px`, a monitor change `ui_scale`,
// a theme switch `theme` and a font change `faces`, so each invalidates every
// entry wholesale without a sweep -- every lookup simply misses.
// 256, not 128, since batch 17's pixel anchor: one walk now covers the pane
// PLUS a pane below it (9.1's layout budget), and a walk that resolves an
// anchor pays MD_RUNUP_LINES of run-up on top of that. Measured directly
// (test_modes.odin's "budget-mid" case, a resolved mid-document anchor on a
// one-block-per-line fixture): 44 live entries for one such walk. The draw,
// the link pass and the scrollbar fraction each walk independently and can
// each be first to touch a given anchor in a frame, so the real budget is
// per-PASS live entries times the up-to-three passes a frame can make:
// 44 * 3 = 132, which is already past 128 -- at 128 slots the three passes
// would evict each other's blocks within a single frame instead of sharing
// them, turning the cache into a cost every frame rather than just the first
// one after a scroll. 256 covers 132 with room to spare.
MD_LAYOUT_SLOTS :: 256

// The longest run of blank lines collapsed into one Blank block. Blank runs
// collapse so that a file of nothing but empty lines is a handful of blocks
// rather than one per line -- but the scan that finds the run's end is a
// forward line walk, so it needs a bound of its own or that same file would be
// walked to EOF on the UI thread by the first block.
MD_BLANK_RUN_MAX :: 64

// Zero-height blocks admitted in one pass.
//
// The fit test cannot stop a block that costs nothing, and blank runs only
// alternate with content while every run FITS in one block. A file that is
// nothing but empty lines produces a CHAIN of Blank blocks, each capped at
// MD_BLANK_RUN_MAX and each costing a bounded forward line walk -- so without
// this the worst case is MD_WALK_BLOCKS * MD_BLANK_RUN_MAX = 16k capped line
// reads on the UI thread, up to three times a frame while Ctrl is held. 64 * 64
// = 4096 is the same order as MD_TABLE_MAX_ROWS and covers any real document:
// content is what fills a pane, and content is not free.
//
// Stopping early only under-reports `bottom`, which makes the scrollbar thumb
// conservative over a region that has nothing to show. It cannot lose content:
// reaching this cap means the pane below the last drawn block is empty.
MD_MAX_EMPTY_BLOCKS :: 64

// Layouts BUILT since the process started. Test-visible on purpose: "a second
// layout at the same width does no work" is not observable from the result --
// a correct cache and no cache at all return the same glyphs -- so the only
// honest way to assert it is to count the builds.
md_layout_builds: int

// Bumped once per md_pass. An entry stamped with the CURRENT id was already
// used by this pass, so evicting it would make the pass rebuild a block it has
// already laid out -- and that rebuild takes another slot, which can evict
// another live entry, and so on. Round-robin alone has that hole: measured, a
// one-byte edit rebuilt TWO blocks, the edited one plus whichever live entry
// its replacement happened to land on. See md_layout_slot.
md_layout_pass: u64

// One block's laid-out geometry. Owned storage: `src`, `store`, `shape`,
// `spans`, `sh` and `boxes` are all heap-allocated and freed by md_layout_free,
// which doc_close calls for every slot.
Md_Layout :: struct {
	valid:       bool,
	// --- the key (see MD_LAYOUT_SLOTS) ---
	start:       int,
	src:         string, // OWNED copy of the block's source line
	in_fence:    bool,
	fence_lex:   Lexer_Proc,
	fence_state: base.Lex_State,
	measure:     f32,
	px:          f32,
	ui_scale:    f32, // sx()'s scale: `indent` is baked from it
	theme:       u64, // md_theme_gen: the palette every span colour was baked from
	faces:       u64, // plat.text_face_gen: the faces every advance was baked from
	revision:    u64, // consulted only for the kinds md_layout_extern_dep names
	// --- the value, except `end` which is BOTH (see MD_LAYOUT_SLOTS) ---
	end:         int, // what the pass reports as `bottom` after this block
	next:        int, // where the pass continues from
	cls:         Md_Class, // .content / .bullet slice into `src`
	// OWNED: the joined text of a multi-line block, which `cls.content` then
	// slices. Set by the four kinds md_join_run serves -- .Para, .List, .Quote and
	// a .Heading PROMOTED FROM a paragraph by a setext underline -- and by nothing
	// else. An ATX heading never reaches it. A single-line block leaves this nil and
	// `cls.content` slices `src` as it always did.
	joined:      string,
	// Did this block read bytes past its own first line? One MECHANISM sets it --
	// md_join_run -- for a joined paragraph run, for a list item or blockquote
	// continued lazily across an unmarked line, and for a setext heading, whose
	// prose run it joins and whose underline it covers without printing.
	//
	// THIS, not the kind, is what makes a block externally dependent: the block's
	// own first line cannot witness an edit to the lines it absorbed, so caching
	// it against that line alone goes stale. The kind cannot answer the question at
	// all now that setext headings exist -- a promoted `.Heading` depends on the
	// line below it and is indistinguishable by kind from an ATX one, which does
	// not.
	multiline:   bool,
	store:       string, // OWNED; every span's text and url slices into this
	shape:       []plat.Shape_Span,
	spans:       []Md_Span,
	sh:          plat.Shaped,
	boxes:       []Md_Span_Box,
	// .Table only: the block's fitted column geometry (md_table_cols). OWNED.
	// Produced once when the block is laid out and read back by the draw for the
	// column rules and the separator row's width -- the same single-producer rule
	// `h` and `indent` follow, and the reason md_col_x no longer exists.
	tcols:       []Md_Table_Col,
	// THE height. Produced here, once, and consumed by BOTH the admit decision
	// and the advance -- md_row_geom's lesson, carried into the block model. The
	// two must never be computed separately: a block admitted against one number
	// and advanced by another is how a heading got cut through the middle of its
	// glyphs (item 6, 2026-07-29).
	h:           f32,
	above:       f32, // 9.3's space above; adjacent margins COLLAPSE (see md_pass)
	below:       f32, // 9.3's space below
	indent:      f32, // the block's left inset from the content origin
	// Where the block's MARKER goes, as an inset from the content origin: a list
	// bullet or checkbox sits left of the prose, so it is not `indent`. Produced
	// here for the same reason `indent` is -- md_block_draw used to re-derive it
	// as `cx + level * m.list_indent`, a second expression that had to agree with
	// the one this file computes two lines above.
	marker:      f32,
	out_fence:   bool,
	out_lex:     Lexer_Proc,
	out_state:   base.Lex_State,
	fm_inner:    int, // Front_Matter only: key/value lines between the fences
	used:        u64, // the md_layout_pass that last read or built this entry
}

// Does this block's layout depend on bytes outside its own `src`? Those take
// doc.revision as part of their key, since their own text cannot witness the
// change. See MD_LAYOUT_SLOTS.
//
// Takes the LAYOUT, not the kind, and lazy continuation is why that is no longer
// only an anticipation: `multiline` is set by any block that absorbed lines below
// its first, which means a joined paragraph run, a list item or blockquote
// continued across an unmarked line, or a setext heading. Each of those is a kind
// that is extern-dep when it absorbed something and is not when it did not -- a
// `.Heading` most sharply of all, since a promoted one read the line below it and
// an ATX one did not -- so the KIND cannot answer for any of them. This is the
// case the signature was originally shaped for. See Md_Layout.multiline.
@(private = "file")
md_layout_extern_dep :: #force_inline proc(e: ^Md_Layout) -> bool {
	return(
		e.cls.kind == .Table ||
		e.cls.kind == .Blank ||
		e.cls.kind == .Front_Matter ||
		e.multiline \
	)
}

// The kinds whose EXTENT can depend on bytes below their own first line, whether
// or not this particular block currently joins anything.
//
// `e.multiline` alone is not enough, and the difference is a live-editing bug
// (2026-08-01 review). A block cached as single-line has multiline = false, so
// keying on that flag leaves it keyed on `e.src != line || e.end != line_end` --
// and NEITHER of those changes when a line is appended BELOW it. Typing a
// continuation under a bullet in Split view therefore hit the stale slot: the
// item redrew unjoined, and the new line came back as a stray .Para at indent 0,
// which is the exact defect lazy continuation exists to fix. Reproduced through
// md_layout_ensure for all three kinds before this guard existed.
//
// md_layout_reset runs only from doc_close and MD_LAYOUT_SLOTS is 256 under LRU,
// so a stale entry survived until scrolling happened to evict it.
//
// `multiline` is still consulted above, and a SETEXT heading is exactly why: it is
// a `.Heading`, a kind this predicate refuses, whose layout read the underline
// below it. Without the `multiline` arm of md_layout_extern_dep such a block would
// be checked against `line_end` here and survive an edit to its own underline.
//
// These kinds are deliberately NOT made extern-dep by this predicate. Doing that
// was the first fix for the stale-cache bug and it cost too much: an edit anywhere
// invalidated every paragraph on screen, taking mdtest's "a one-byte edit rebuilds
// exactly ONE block, not the document" from 1 to 4. The cache asks md_join_end for
// the block's real extent instead.
@(private = "file")
md_kind_joins :: #force_inline proc(k: Md_Kind) -> bool {
	return k == .Para || k == .List || k == .Quote
}

md_layout_free :: proc(e: ^Md_Layout) {
	if !e.valid {return}
	delete(e.src)
	delete(e.joined)
	delete(e.store)
	delete(e.shape)
	delete(e.spans)
	delete(e.boxes)
	delete(e.tcols)
	plat.shaped_free(&e.sh)
	e^ = {}
}

// Every slot dropped. doc_close's audited free, and the reset a test uses to
// make "did this rebuild?" a question with a defined starting point.
md_layout_reset :: proc(doc: ^Document) {
	if doc == nil {return}
	for &e in doc.md_layout {md_layout_free(&e)}
	delete(doc.md_layout)
	doc.md_layout = nil
}

// One span under construction. Offsets into a temp builder rather than strings,
// because the block's text is copied into ONE owned allocation at the end and
// slices taken from that -- a builder reallocs, so a slice taken during the
// build would dangle.
@(private = "file")
Md_Draft_Span :: struct {
	off, len: int,
	url_off:  int,
	url_len:  int,
	style:    Md_Styles,
	color:    [4]f32,
	px:       f32,
	set:      plat.Font_Set,
}

// The face for an inline run: real bold/italic faces when the body chain has
// them (9.3 asks for weight 700 on every heading row and "real bold + italic
// faces" for emphasis), the base face when it does not. Code is always the mono
// chain -- 9.2 item 3, "always Neon even in serif body"; Neon is not embedded
// until batch 20, so the mono chain here is .Doc, the editor's own face.
@(private = "file")
md_run_set :: proc(t: ^plat.Text, style: Md_Styles) -> plat.Font_Set {
	if .Code in style {return .Doc}
	switch {
	case .Bold in style && .Italic in style:
		return plat.text_styled_set(t, .Body, .Bold_Italic)
	case .Bold in style:
		return plat.text_styled_set(t, .Body, .Bold)
	case .Italic in style:
		return plat.text_styled_set(t, .Body, .Italic)
	}
	return .Body
}

@(private = "file")
md_run_styles :: proc(r: Md_Run) -> (s: Md_Styles) {
	if r.bold {s += {.Bold}}
	if r.ital {s += {.Italic}}
	if r.code {s += {.Code}}
	if r.link {s += {.Link}}
	if r.strike {s += {.Strike}}
	return
}

// Split a drafted span at the bare URLs and paths inside it, so a link written
// without markdown syntax stays clickable in the preview.
//
// links_scan is the SAME detector the editor pane uses -- not a second rule
// about what a path looks like. It runs on the span's own text, which is what
// the reader sees, so a `*` that md_inline consumed as an emphasis marker
// cannot end up inside a detected token.
@(private = "file")
md_split_bare_links :: proc(out: ^[dynamic]Md_Draft_Span, d: Md_Draft_Span, text: string) {
	if .Code in d.style || .Link in d.style || d.len <= 0 {
		append(out, d)
		return
	}
	found := links_scan(text, context.temp_allocator)
	if len(found) == 0 {
		append(out, d)
		return
	}
	cut := 0
	for l in found {
		if l.start > cut {
			pre := d
			pre.off, pre.len = d.off + cut, l.start - cut
			append(out, pre)
		}
		lk := d
		lk.off, lk.len = d.off + l.start, l.len
		lk.url_off, lk.url_len = d.off + l.start, l.target_len
		lk.style += {.Link}
		lk.color = g_theme[.Link]
		append(out, lk)
		cut = l.start + l.len
	}
	if cut < d.len {
		post := d
		post.off, post.len = d.off + cut, d.len - cut
		append(out, post)
	}
}

// Absorb the run beginning at this block's own line into `e`, if there is one.
//
// THE SINGLE JOIN. Three cases call it -- `.Para`, `.List` and `.Quote` -- and
// none of them has a loop of its own, because "which lines are one block" and
// "what text do they make" are the two halves of one answer and were never going
// to survive being written three times. What differs between the three is only
// what md_classify already put in `e.cls`: a paragraph's own line contributes the
// whole line, a list item's contributes the text after its bullet, a quote's the
// text after its `>`. `first` is that text, and it is the caller's `e.cls.content`
// -- which for `.Para` IS the whole line, so this changed nothing about the
// paragraph join when the two other kinds were added to it.
//
// Bounds come from md_para_run -- md_para_bounds behind a memo -- and from
// nowhere else; see md_para_bounds' comment for why a second producer here would
// be entry-dependent.
//
// A CAPPED run is refused, and that refusal lives inside md_para_run (`ok` is
// false for one) rather than as a `!capped` test here. It is there so that this
// and md_block_start_at cannot get out of step about which runs join: the snap has
// to land on the byte this treats as the block's start, and two separate readings
// of the same flag are two things to keep matching. The cost of refusing is that a
// run past 4096 lines or 256 KB renders unjoined, one block per line, exactly as
// it did before the join existed -- and such a paragraph is already pathological.
//
// It is NOT refused to prevent a re-draw. That was this comment's claim until a
// 2026-08-01 review measured it with the `!capped` test removed and `ps == p`
// kept: block 1 spans 0..203 with next=204, block 2 spans 204..237 -- zero
// duplication, because `ps != p` refuses block 2 before its bounds are ever used.
// The two guards are individually sufficient against a re-draw, and each was being
// credited here with the other's work.
//
// `ps == p` is therefore load-bearing in its own right, not only "defence in
// depth": it is what stops a block from claiming to start at `p` while holding
// text from `ps` -- the regression md_block_start_at exists to remove, in which
// the preview drew from line 0 while the editor sat at line 100. With the snap in
// place it never fires in production (mdtest is green with it removed);
// mdjointest's mid-run rows drive it directly.
// The byte a block starting at `p` ends at, given the run below it -- `line_end`
// when nothing joins, the run's end when something does.
//
// THE single answer to "does this block join, and how far", and it has two askers
// for a reason. md_join_run asks it when it BUILDS the block; md_layout_ensure
// asks it when it decides whether a cached block is still current. Those two must
// agree, and before this existed they could not: the cache compared `e.end`
// against `line_end`, which is the extent of the block's own line and says nothing
// about the lines below it. A block cached while single-line therefore survived
// the append that should have joined it -- typing a continuation under a bullet in
// Split view redrew the item unjoined and dropped the new line out as a stray
// .Para at indent 0 (2026-08-01 review).
//
// The first fix tried was making every joining kind revision-keyed. That is
// correct and too coarse: mdtest's "a one-byte edit rebuilds exactly ONE block,
// not the document" went from 1 to 4, because an edit anywhere invalidated every
// paragraph on screen. Asking for the block's actual extent keeps that property --
// only a block whose own run moved rebuilds -- and costs one md_para_run call,
// which is memoised.
//
// It also carries the SETEXT level, and that is what makes the promotion a single
// decision rather than two agreeing ones: md_layout_build asks this before its kind
// switch to decide the block IS a heading, and md_join_run asks it to decide the
// underline is markup rather than text. Both readings come from the one
// md_para_run answer that md_block_start_at snapped the entry byte with, so the
// kind, the extent and the block start cannot disagree. `setext` is 0 whenever
// `end` is `line_end`: a refused or unpromoted run has no level to report.
@(private = "file")
md_join_end :: proc(doc: ^Document, p, line_end: int) -> (end, setext: int) {
	ps, pe, lvl, pok := md_para_run(doc, p)
	if !pok || ps != p || pe <= line_end {return line_end, 0}
	return pe, lvl
}

@(private = "file")
md_join_run :: proc(doc: ^Document, e: ^Md_Layout, p, line_end: int, buf: []u8) {
	pe, setext := md_join_end(doc, p, line_end)
	if pe == line_end {return}
	ps := p
	sb := strings.builder_make(context.temp_allocator)
	q := ps
	head := true
	// prev_hard: whether the line just written into sb ended with a hard-break
	// marker. CommonMark: a line ending in two or more spaces, or in a backslash,
	// ends with a hard break. The break belongs to the line that carries the
	// marker, so it is written before the NEXT line's text -- never after the
	// current line -- or the run's last line would gain a stray trailing break it
	// never asked for.
	prev_hard := false
	for q <= pe {
		l, le, _ := md_line_at(doc, q, buf)
		// THE SETEXT UNDERLINE is the run's last line, and it is MARKUP: it decided the
		// heading's level and contributes no text. `le >= pe` names it without a second
		// scan and without re-deciding anything -- md_para_bounds put `pe` at exactly
		// this line's end, and `setext` came from the same answer. The run's BYTES
		// still reach past it (`e.end` below), which is what stops the walk continuing
		// onto the underline and drawing a rule under the heading.
		if setext > 0 && le >= pe {break}
		// A hard break becomes a real newline instead of a space. The shaper already
		// breaks on '\n' (platform/shape.odin:287) and handles two in a row
		// (shape.odin:404-409), so this is the whole implementation. The marker is
		// read off the RAW line even on the first iteration, where the TEXT comes
		// from `first` instead: a list item's content has already had its bullet
		// stripped, but the trailing spaces that make the break are still on the line
		// as read.
		//
		// `has_suffix(l, "  ")` is TWO spaces, not one, and that is CommonMark, not a
		// rounding of it: one trailing space is ordinary insignificant whitespace and
		// must join as a space like any other line break. A tab does not count either
		// -- the spec says spaces.
		raw := strings.trim_right(l, " \t")
		hard := strings.has_suffix(l, "  ") || strings.has_suffix(raw, "\\")
		text := raw
		if head {
			text = strings.trim_right(e.cls.content, " \t")
		} else {
			// A continuation line's own leading indent is markup, not content: a
			// wrapped list item is conventionally written indented under its bullet,
			// and CommonMark strips that indent when the line is folded into the
			// block above. Without this, "- item\n  more" joins as "item   more".
			text = strings.trim_left(text, " \t")
		}
		if strings.has_suffix(text, "\\") {text = text[:len(text) - 1]}
		if strings.builder_len(sb) > 0 {
			strings.write_byte(&sb, '\n' if prev_hard else ' ')
		}
		strings.write_string(&sb, text)
		prev_hard = hard
		head = false
		q = le + 1
	}
	e.joined = strings.clone(strings.to_string(sb))
	e.cls.content = e.joined
	e.end, e.next = pe, pe + 1
	e.multiline = true
}

// Lay one block out: classify it, turn it into spans, shape them and produce
// its height and its span boxes. Allocates into the ordinary allocator; the
// cache owns the result.
//
// `line` is the block's FIRST source line, already read and CR-stripped by the
// caller. Kinds that span more than one line (a blank run, front matter) read
// the rest through `doc` themselves and set `end`/`next` accordingly.
@(private = "file")
md_layout_build :: proc(
	gfx: ^plat.Gfx,
	t: ^plat.Text,
	doc: ^Document,
	m: ^Md_Metrics,
	p, line_end: int,
	line: string,
	in_fence: bool,
	fence_lex: Lexer_Proc,
	fence_state: base.Lex_State,
	measure: f32,
) -> (
	e: Md_Layout,
) {
	md_layout_builds += 1
	e.valid = true
	e.start, e.end, e.next = p, line_end, line_end + 1
	e.src = strings.clone(line)
	e.in_fence, e.fence_lex, e.fence_state = in_fence, fence_lex, fence_state
	e.measure, e.px, e.revision = measure, m.s, doc.revision
	e.ui_scale, e.theme, e.faces = m.ui_scale, m.theme, m.faces
	e.out_fence, e.out_lex, e.out_state = in_fence, fence_lex, fence_state

	trimmed := strings.trim_left(e.src, " \t")
	e.cls = md_classify(e.src, trimmed, in_fence)

	// Front matter is a BLOCK, not a pre-loop special case. Its height comes
	// from md_fm_height and from nowhere else, which is what removed its
	// two-producer risk; here it is simply this block's `h`.
	if p == 0 && !in_fence {
		if fm_end, fm_inner := md_front_matter_end(doc); fm_end > 0 {
			e.cls = Md_Class{kind = .Front_Matter}
			e.fm_inner = fm_inner
			e.end, e.next = fm_end, fm_end
			e.h = md_fm_height(line_height(m.code), fm_inner)
			e.below = m.para_below
			return
		}
	}

	// THE SETEXT PROMOTION, and it sits HERE -- above the kind switch, not inside
	// the `.Para` case -- for one reason: the `.Heading` branch below owns the
	// heading's type size, its space above and below, its colour and its h1/h2 rule,
	// and promoting into it means this block gets all five from the same code an ATX
	// heading does. Copying that branch into a `.Para` case would be a second
	// producer of every one of those numbers.
	//
	// The DECISION is md_join_end's, which is md_para_run's, which is what
	// md_block_start_at snapped the entry byte with. Nothing here re-derives "is this
	// setext". The local `setext` is not handed anywhere: it only records the answer
	// so the `.Heading` case knows to call the join at all. md_join_run asks
	// md_join_end for itself and gets the same level from the same memo, which is why
	// the underline can be dropped from the TEXT there while staying in the EXTENT
	// without a second decision travelling between the two.
	//
	// Only a `.Para` line is ever promoted, and that is an invariant of the bounds
	// layer rather than a narrowing applied here: md_para_bounds promotes only a run
	// with no list-item or blockquote owner, and such a run's first line is a plain
	// paragraph line. `# Title` over `===` is therefore an ATX heading followed by a
	// paragraph reading `===`, which is what CommonMark says it is.
	setext := 0
	if e.cls.kind == .Para {
		if _, lvl := md_join_end(doc, p, line_end); lvl > 0 {
			setext = lvl
			e.cls.kind, e.cls.level = .Heading, lvl
		}
	}

	base_col := g_theme[.Text_Primary]
	mute := f32(0)
	px := m.body
	lead := m.body_lead
	// .Table only: the block's measured cache, kept because the span builder below
	// needs its per-column alignments. Read once, here, so nothing downstream of the
	// switch calls md_table_ensure a second time.
	tcache: ^Md_Table_Cache
	// The face the EMPTY-BLOCK height fallback at the end of this proc measures on.
	// .Body for prose; the mono chain for the kinds that draw on it, so a table
	// separator row -- which drafts no spans at all -- is one row of the TABLE face
	// tall rather than one row of Georgia.
	fallback_set := plat.Font_Set.Body
	// ONE line scratch for every case that reads lines below its own -- .Blank's run
	// collapse, and the .Para / .List / .Quote join, which is handed this slice
	// rather than declaring a buffer in its own frame. They used to declare their
	// own [RENDER_LINE_CAP]u8 inside the switch -- 16 KB of frame on a procedure the
	// walk calls once per block. Nothing here outlives the case that fills it:
	// .Blank only measures, and md_join_run copies each line into the builder before
	// reading the next, so there is no slice of this left alive to alias. (`line`
	// and `e.src` are the caller's buffer and an owned clone of it; neither points
	// here -- which is also why md_join_run may read `e.cls.content` while writing
	// through this buffer.)
	buf: [RENDER_LINE_CAP]u8

	switch e.cls.kind {
	case .Blank:
		// Collapse the run. Bounded by MD_BLANK_RUN_MAX so a file of empty lines
		// costs a bounded scan rather than a walk to EOF. Zero height: 9.3's
		// space-above/below columns are what put air between blocks now, so a
		// blank line is a separator in the source and nothing on screen.
		q := line_end
		for _ in 0 ..< MD_BLANK_RUN_MAX {
			if q >= doc.pt.length {break}
			nl, ne, _ := md_line_at(doc, q + 1, buf[:])
			if len(strings.trim_space(nl)) != 0 || md_is_fence_line(nl) {break}
			e.end, e.next, q = ne, ne + 1, ne
		}
		return
	case .Rule:
		e.h = hairline()
		e.above, e.below = m.rule_gap, m.rule_gap
		return
	case .Fence_Open:
		e.out_fence = true
		e.out_lex, e.out_state = md_fence_lexer(trimmed), .Normal
		e.h = m.fence_pad
		e.above = m.fence_above
		return
	case .Fence_Close:
		e.out_fence, e.out_lex = false, nil
		e.h = m.fence_pad
		e.below = m.fence_below
		return
	case .Table:
		// 9.3 keeps a table on the mono face at 0.95 S -- "always mono: columns
		// align" -- and its column widths stay a property of the whole BLOCK, which
		// is what md_table_ensure measures. Two things changed 2026-07-29, both from
		// Wyatt's screenshot of a wide table with its last column cut off by the pane
		// edge:
		//
		//   * the natural widths are FITTED to the measure (md_table_cols), so the
		//     table cannot run off the right edge -- there is no scissor rect here,
		//     so a column past the measure paints over the scrollbar rather than
		//     clipping;
		//   * each cell's text WRAPS inside its own column (plat.shape_columns), and
		//     a row is as tall as its tallest cell. That is what GitHub, Obsidian and
		//     VS Code do, and it is Wyatt's choice. Mono is about the FACE, not about
		//     refusing to wrap.
		//
		// This case no longer returns, and that is load-bearing: the cells go through
		// the shaper, so `spans`, `boxes` and `sh` are populated and a table row
		// reaches shaped_draw exactly as a paragraph does. Which is why .Table is on
		// md_kind_lines' DIVISIBLE side now -- see the pairing guard in md_block_draw.
		//
		// It also closes batch 17's disclosed regression: LINKS INSIDE TABLE CELLS
		// ARE CLICKABLE AGAIN. That regression was disclosed on the grounds that
		// emitting link rects would need a second producer of cell geometry; once the
		// shaper places the cells, the second producer is gone -- md_span_boxes reads
		// the same Shaped the glyphs were drawn from, so a table cell's link rect
		// comes from the identical seam every other block's does.
		px, lead = m.table, line_height(m.table)
		fallback_set = .Doc
		tcache = md_table_ensure(doc, t, p)
		e.tcols = md_table_cols(tcache, measure, md_table_char_w(gfx, t, m))
		if tcache != nil {
			e.cls.tbl_first = p <= tcache.start
			// `end` is the last row's newline (pt_line_end_cap semantics), so a row
			// whose own line end reaches it is the last one.
			e.cls.tbl_last = line_end >= tcache.end
		}
		// md_table_bounds refuses an entry point that is not a real line start (a
		// physical row longer than RENDER_LINE_CAP, drawn in segments), and a refusal
		// is nil here. The row still has to draw: one column, the whole measure.
		if len(e.tcols) == 0 {
			e.tcols = make([]Md_Table_Col, 1)
			e.tcols[0] = {x = 0, w = max(1, measure)}
		}
	case .Fence_Body:
		px, lead = m.code, line_height(m.code)
		base_col = g_theme[.Md_Code]
		// 9.3's 12px fenced-code padding, as the block's INDENT rather than as a
		// number the draw adds on its own. The glyph origin has exactly one
		// producer (md_block_origin) and the link rects are built from it, so an
		// inset applied at the draw and not at the layout would put the underline
		// and the hit-test 12px apart -- which is the whole failure this task
		// exists to make impossible.
		e.indent = m.fence_pad
	case .Heading:
		px = m.head[clamp(e.cls.level, 1, 6)]
		lead = line_height(px)
		base_col = g_theme[.Md_Heading]
		e.above = m.head_above[clamp(e.cls.level, 1, 6)]
		e.below = m.head_below[clamp(e.cls.level, 1, 6)]
		// A SETEXT heading, promoted above. Its prose is an ordinary paragraph run and
		// may be several lines, so it joins on exactly the terms `.Para` does -- and
		// the run md_para_bounds handed back reaches past the underline, so `e.end`
		// and `e.next` clear it and no rule is drawn beneath the heading. An ATX
		// heading has `setext == 0` and never calls this.
		if setext > 0 {md_join_run(doc, &e, p, line_end, buf[:])}
	case .Quote:
		base_col = g_theme[.Md_Quote]
		e.indent = f32(e.cls.level) * m.quote_inset
		e.above, e.below = m.quote_above, m.quote_below
		// A lazily continued quote: the unmarked prose lines below this one carry
		// no `>` and md_classify calls each of them `.Para`, but CommonMark says
		// they are this quote. The kind, the level and so the INDENT and the bar
		// count are this line's own, taken from md_classify above and untouched by
		// the join -- which is the point of expressing the continuation as an
		// EXTENT rather than as a kind a continuation line inherits. Nothing here
		// re-derives them.
		md_join_run(doc, &e, p, line_end, buf[:])
	case .List:
		e.indent = f32(e.cls.level) * m.list_indent
		// The bullet / checkbox sits at the item's nesting depth; the PROSE is
		// indented one step further. Both come out of here, so md_block_draw has
		// no expression of its own to keep in step (2026-07-29 review, L2).
		e.marker = e.indent
		e.below = m.list_gap
		if e.cls.task {
			e.indent += m.task_box + m.list_indent * 0.25
		} else {
			e.indent += m.list_indent
		}
		if e.cls.task_done {base_col, mute = md_task_prose_style(true)}
		// A lazily continued list item, on exactly the same terms as .Quote above:
		// `indent`, `marker`, `bullet` and the task box are all this line's own and
		// the join only lengthens the text they sit beside. This is what puts a
		// wrapped item's second line under the first instead of at indent 0 as a
		// stray paragraph.
		//
		// The task checkbox is unaffected by where this call sits: `cls.task` and
		// `cls.task_done` were decided by md_classify, above the switch, off the
		// marker line's own content. md_join_run rewrites `cls.content` and nothing
		// else, so a `[x]` in a continuation line cannot become a checkbox.
		md_join_run(doc, &e, p, line_end, buf[:])
	case .Para:
		e.below = m.para_below
		// Join the run. CommonMark's paragraph model: consecutive prose lines are
		// ONE paragraph, re-flowed to the pane, with a space at each break -- which
		// is also the fix for "the preview does not always respect spaces", since
		// the space at the join is the one that was missing (there was no join).
		md_join_run(doc, &e, p, line_end, buf[:])
	case .Front_Matter:
	}

	// --- spans ---------------------------------------------------------------
	sb := strings.builder_make(context.temp_allocator)
	draft := make([dynamic]Md_Draft_Span, 0, 8, context.temp_allocator)
	// .Table only: one entry per fitted column, the index in `draft` where that
	// column's spans END. Recorded while drafting because the flat
	// plat.Shape_Span array the columns must subslice does not exist yet.
	tcol_end := make([dynamic]int, 0, MD_TABLE_MAX_COLS, context.temp_allocator)
	if e.cls.kind == .Table {
		// A separator row draws as a rule and no text at all (the old
		// md_draw_table_row did the same), so it drafts nothing and takes its height
		// from the empty-block fallback at the end of this proc -- one mono row at
		// m.table, which is what fallback_set is for.
		if !e.cls.is_sep {
			cells := md_split_cells(e.src, context.temp_allocator)
			for ci in 0 ..< len(e.tcols) {
				// A row with fewer cells than the block has columns contributes an
				// EMPTY column, not a missing one: the columns are the block's, so
				// every row must offer the same number of them or the spans and the
				// geometry would index differently.
				cell := cells[ci] if ci < len(cells) else ""
				for run in md_inline(cell) {
					if len(run.text) == 0 {continue}
					st := md_run_styles(run)
					off := strings.builder_len(sb)
					strings.write_string(&sb, run.text)
					d := Md_Draft_Span {
						off   = off,
						len   = len(run.text),
						style = st,
						color = md_run_color(run, base_col, mute),
						// EVERY table span at m.table on the mono chain, inline code
						// included -- which is the one place this deviates from what
						// the same run would get in a paragraph. 9.3's "always mono:
						// columns align" is a statement about the column grid, and a
						// 0.92 S code run inside a 0.95 S row would advance on a
						// different width from the cells around it, which is exactly
						// the alignment the mono face is there to buy.
						px    = m.table,
						set   = .Doc,
					}
					if .Link in st {
						d.url_off = strings.builder_len(sb)
						d.url_len = len(run.url)
						strings.write_string(&sb, run.url)
					}
					md_split_bare_links(&draft, d, run.text)
				}
				append(&tcol_end, len(draft))
			}
		}
	} else if e.cls.kind == .Fence_Body && fence_lex != nil {
		// Syntax colours inside a fenced block: one span per token, all on the
		// mono face at the code size. The lexer's outgoing state is carried to
		// the next block, and is part of that block's cache key.
		toks: [128]base.Token
		nt, st := fence_lex(transmute([]u8)e.src, fence_state, toks[:])
		e.out_state = st
		cut := 0
		emit :: proc(sb: ^strings.Builder, draft: ^[dynamic]Md_Draft_Span, s: string, col: [4]f32, px: f32) {
			if len(s) == 0 {return}
			off := strings.builder_len(sb^)
			strings.write_string(sb, s)
			append(draft, Md_Draft_Span{off = off, len = len(s), color = col, px = px, set = .Doc})
		}
		for i in 0 ..< nt {
			tk := toks[i]
			if tk.start > cut {emit(&sb, &draft, e.src[cut:tk.start], base_col, px)}
			hi := min(tk.start + tk.len, len(e.src))
			if hi > tk.start {emit(&sb, &draft, e.src[tk.start:hi], g_theme[highlight_kind_role(tk.kind)], px)}
			cut = hi
		}
		if cut < len(e.src) {emit(&sb, &draft, e.src[cut:], base_col, px)}
	} else {
		content := e.cls.content
		// UI spec §9.3: h6 is CAPS. It is the one level with no size of its own --
		// §9.3 gives h5 and h6 the same 1.00 S and the same weight -- so without
		// this an h6 is indistinguishable from an h5, which is what shipped.
		//
		// Uppercased HERE, on the block's text, rather than at the draw: the
		// shaper measures what it is given, and a draw-time transform would size
		// every line against lower-case metrics and then paint wider glyphs into
		// the box. That is the drawn-column-versus-byte-column seam §6j records
		// sixteen bugs against, in its narrowest form.
		//
		// §9.3 also asks for tracking on h6 and this does NOT add it: the shaper
		// has no letter-spacing parameter, and threading one through shape_spans
		// for a single heading level is its own task. Recorded rather than quietly
		// dropped.
		if e.cls.kind == .Heading && e.cls.level == 6 {
			content = strings.to_upper(content, context.temp_allocator)
		}
		for run in md_inline(content) {
			if len(run.text) == 0 {continue}
			st := md_run_styles(run)
			if e.cls.kind == .Heading {st += {.Bold}} // 9.3: weight 700, every level
			col := md_run_color(run, base_col, mute)
			// A heading keeps its OWN colour through emphasis (2026-07-29 review,
			// L7). md_run_color repaints a bold run Text_Bright and an italic run
			// Md_Italic, which is the exact base-colour override batch 17 removed
			// from headings -- it survived in this sub-case because the run is
			// handed to md_run_color unmodified, so `run.bold` still wins over the
			// Md_Heading base. Deliberate, not incidental: a heading is already at
			// weight 700 at every level, so `**bold**` inside one has no face
			// change left to make and the colour was carrying emphasis on its own,
			// which is the "colour alone" the UI spec's item 18 rejects. Browsers
			// do the same -- <strong> inside <h1> inherits the heading's colour and
			// its weight. Code, links and strikethrough still override, because
			// each of those is saying something a heading is not: a code face, an
			// affordance, a deletion.
			if e.cls.kind == .Heading && !run.code && !run.link && !run.strike {col = base_col}
			off := strings.builder_len(sb)
			strings.write_string(&sb, run.text)
			d := Md_Draft_Span {
				off   = off,
				len   = len(run.text),
				style = st,
				color = col,
				px    = m.code if .Code in st else px,
				set   = md_run_set(t, st),
			}
			if .Link in st {
				d.url_off = strings.builder_len(sb)
				d.url_len = len(run.url)
				strings.write_string(&sb, run.url)
			}
			md_split_bare_links(&draft, d, run.text)
		}
	}

	// One owned allocation for every span's text and url; the slices below index
	// into it, so nothing here points at the temp arena.
	e.store = strings.clone(strings.to_string(sb))
	e.shape = make([]plat.Shape_Span, len(draft))
	e.spans = make([]Md_Span, len(draft))
	for d, i in draft {
		e.shape[i] = {text = e.store[d.off:d.off + d.len], px = d.px, set = d.set}
		e.spans[i] = {style = d.style, color = d.color}
		if d.url_len > 0 {e.spans[i].url = e.store[d.url_off:d.url_off + d.url_len]}
	}

	if e.cls.kind == .Table {
		// Each column shaped in ITS OWN width, at the block's fitted geometry, and
		// merged into one Shaped whose line slots are the per-line max over the
		// columns. So the row's height is the tallest cell's, produced once by the
		// shaper, and consumed by md_block_admit and by md_walk's advance through
		// `e.h` below like every other kind's.
		cols := make([]plat.Shape_Column, len(e.tcols), context.temp_allocator)
		lo := 0
		for i in 0 ..< len(e.tcols) {
			hi := tcol_end[i] if i < len(tcol_end) else lo
			al := plat.Shape_Align.Left
			if tcache != nil && i < tcache.ncols {
				switch tcache.align[i] {
				case .Left:
					al = .Left
				case .Center:
					al = .Center
				case .Right:
					al = .Right
				}
			}
			cols[i] = {spans = e.shape[lo:hi], x = e.tcols[i].x, w = e.tcols[i].w, align = al}
			lo = hi
		}
		e.sh = plat.shape_columns(gfx, t, cols, lead)
	} else {
		e.sh = plat.shape_spans(gfx, t, e.shape, max(1, measure - e.indent), lead)
	}
	e.boxes = md_span_boxes(gfx, t, &e.sh, e.shape, context.allocator)
	// THE height, read back rather than assumed: Shaped.height is the SUM of the
	// per-line boxes, and a line box is clamped UP to its own face's ascent +
	// descent (Georgia's is 1.136 em), so the leading asked for above is a floor
	// and not an answer. An empty block still owes one line.
	e.h = e.sh.height
	// FOOTGUN, not a bug today: shape_run's last argument is its PERSISTENT
	// allocator (shape.odin:184), and this call passes context.temp_allocator for
	// it -- so the returned Shaped's glyphs and line_boxes land on whatever temp
	// arena is active, which during a resize repaint is resize_temp_begin's
	// per-invocation arena. Benign here because only .line_h is read and the rest
	// of the Shaped value is discarded; plat.shaped_free on a value built this way
	// would `delete` temp-arena memory through the heap allocator instead. This is
	// also the real mechanism behind the third trap site in the RESIZE_TEMP_BLOCK
	// writeup above: shape.odin:397 indexes `boxes`, which is allocated on the
	// CALLER-SUPPLIED allocator (shape_spans' `allocator` param), not on a stray
	// temp `make` inside shape.odin itself -- so a caller that hands shape_spans a
	// resize-scoped temp allocator and then persists the result has the exact same
	// footgun as this line, just with the roles reversed.
	//
	// A second, load-bearing consequence of the growing-arena fix: resize_temp_end
	// calls arena_destroy, which returns the block to the HEAP -- unlike the old
	// shared @(static) buffer, which stayed mapped for the process's life. Any
	// pointer that escapes a resize repaint's temp arena and gets dereferenced
	// later is therefore now a REAL use-after-free (freed, unmapped memory) rather
	// than a stale-but-still-readable value. Nothing here escapes: Md_Layout's
	// persisted fields (e.store, e.shape, e.spans, e.boxes above) are all built on
	// context.allocator and md_layout_free deletes them through the same, so this
	// is clean today -- but it is an invariant nothing enforces, only audits.
	// A TABLE SEPARATOR ROW COLLAPSES TO A HAIRLINE.
	//
	// It drafts no text, so it fell to the empty-block fallback and took a whole
	// mono line -- an empty band between the header and the body wide enough to
	// read as a missing row. §9.4's card has no separator row at all: the body
	// starts directly under the header band, and the band's own colour change is
	// the boundary.
	//
	// A hairline rather than 0: this height feeds the scroll/admit arithmetic, and
	// a zero-height block is a shape nothing else in the pass produces. One pixel
	// is invisible and keeps every "how far did this block advance" answer > 0.
	if e.cls.kind == .Table && e.cls.is_sep {
		e.h = hairline()
	}
		if e.h <= 0 {e.h = plat.shape_run(gfx, t, " ", px, measure, lead, fallback_set, context.temp_allocator).line_h}
	// h1 and h2 carry a rule (9.2 item 1). It is part of the block's OWN height,
	// not decoration painted after it: a rule drawn at the block's bottom edge
	// while the height stopped above it is a row of pixels the admit decision
	// never budgeted for, which on the last block of a pane is a line painted
	// on the status bar. Same single-producer rule as everything else here --
	// md_block_draw derives the rule's y from this h, it does not add its own.
	if e.cls.kind == .Heading && md_head_rules(e.cls.level) {e.h += hairline()}
	return
}

// Package-visible so mdjointest can assert on a built layout without a window.
// Gives the test a `p` and a real `line_end`/`line` without duplicating
// md_line_at's cap handling.
//
// It does NOT snap `p`, deliberately: md_block_start_at is what every production
// resolver runs a byte through before a walk may enter there, so a test that
// wants "the block containing byte B" must snap first, exactly as md_anchor_walk
// and md_block_at_byte do. Handed a mid-paragraph byte, this builds the block
// md_layout_build builds for that entry -- which, by the `ps == p` refusal in the
// `.Para` case, is the unjoined single line.
// One entry per block the walk emits, flattened for a test: the gap ABOVE it and
// its own height, which together are the only two numbers the vertical rhythm is
// made of. Exposed because Md_Walk_Block and md_walk are file-private and should
// stay that way -- this hands back a plain shape rather than opening the walk's
// own type up to the program layer.
//
// The distance between two blocks on screen is a SUM over this slice (a blank
// line contributes a gap and no height), so a test that wants to assert about
// spacing has to walk it rather than read a metric back out of Md_Metrics.
Md_Block_Gap :: struct {
	kind:    Md_Kind,
	gap:     f32, // collapsed space above this block
	h:       f32,
	content: string, // joined text, for naming a block without counting indices
}

md_block_gaps_for_test :: proc(gfx: ^plat.Gfx, t: ^plat.Text, doc: ^Document, m: ^Md_Metrics, allocator := context.temp_allocator) -> []Md_Block_Gap {
	blocks := make([]Md_Walk_Block, 64, context.temp_allocator)
	n, _, _ := md_walk(gfx, t, doc, m, m.measure, 0, max(int), 0, max(f32), blocks)
	out := make([]Md_Block_Gap, n, allocator)
	for i in 0 ..< n {
		b := blocks[i]
		out[i] = {kind = b.lay.cls.kind, gap = b.gap, h = b.h, content = b.lay.cls.content}
	}
	return out
}

md_layout_build_for_test :: proc(gfx: ^plat.Gfx, t: ^plat.Text, doc: ^Document, m: ^Md_Metrics, p: int, measure: f32) -> Md_Layout {
	buf: [RENDER_LINE_CAP]u8
	line, lend, _ := md_line_at(doc, p, buf[:])
	return md_layout_build(gfx, t, doc, m, p, lend, line, false, nil, {}, measure)
}

// The cached layout for the block at `p`, building it if no slot holds one.
// Round-robin replacement, like md_table_ensure's four slots and for the same
// reason: a viewport walk touches its blocks top to bottom, so anything that
// evicts the block it is about to need again next frame turns the cache into a
// cost.
@(private = "file")
md_layout_ensure :: proc(
	gfx: ^plat.Gfx,
	t: ^plat.Text,
	doc: ^Document,
	m: ^Md_Metrics,
	p, line_end: int,
	line: string,
	in_fence: bool,
	fence_lex: Lexer_Proc,
	fence_state: base.Lex_State,
	measure: f32,
) -> ^Md_Layout {
	// Allocated on the first preview pass and never before: a document that is
	// never previewed pays nothing, which is most of them.
	if doc.md_layout == nil {doc.md_layout = make([]Md_Layout, MD_LAYOUT_SLOTS)}
	for &e in doc.md_layout {
		if !e.valid || e.start != p {continue}
		if e.measure != measure || e.px != m.s || e.ui_scale != m.ui_scale || e.theme != m.theme || e.faces != m.faces {continue}
		if e.in_fence != in_fence || e.fence_lex != fence_lex || e.fence_state != fence_state {continue}
		if md_layout_extern_dep(&e) {
			if e.revision != doc.revision {continue}
		} else {
			// The extent this block would have RIGHT NOW. For the joining kinds
			// that is a function of the lines BELOW it, which `line` cannot
			// witness -- so asking md_join_end is what stops a block cached while
			// single-line from surviving the append that should have joined it.
			// Same producer md_join_run builds from; see its comment.
			// A promoted setext heading never reaches here: md_join_run marks it
			// multiline, so md_layout_extern_dep sent it down the revision-keyed
			// branch above. Which is required, not incidental -- its kind is
			// `.Heading`, which md_kind_joins refuses, so this line would hold it
			// at `line_end` and cache it across an edit to its own underline.
			want_end := line_end
			if md_kind_joins(e.cls.kind) {want_end, _ = md_join_end(doc, p, line_end)}
			// `e.end != want_end` is NOT redundant with `e.src != line`: md_pass
			// strips the trailing \r, so a CRLF -> LF conversion leaves `src`
			// identical and every extent one byte shorter. See MD_LAYOUT_SLOTS.
			if e.src != line || e.end != want_end {continue}
		}
		e.used = md_layout_pass
		return &e
	}
	slot := md_layout_slot(doc)
	md_layout_free(slot)
	slot^ = md_layout_build(gfx, t, doc, m, p, line_end, line, in_fence, fence_lex, fence_state, measure)
	slot.used = md_layout_pass
	return slot
}

// Package-visible so mdjointest can assert on md_layout_ensure's CACHE, not
// just on what md_layout_build produces once. Same shape as
// md_layout_build_for_test: derive `line`/`line_end` from `p` so the caller
// only has to supply a byte offset.
md_layout_ensure_for_test :: proc(gfx: ^plat.Gfx, t: ^plat.Text, doc: ^Document, m: ^Md_Metrics, p: int, measure: f32) -> ^Md_Layout {
	buf: [RENDER_LINE_CAP]u8
	line, lend, _ := md_line_at(doc, p, buf[:])
	return md_layout_ensure(gfx, t, doc, m, p, lend, line, false, nil, {}, measure)
}

// The slot a new layout goes in: an empty one, else the LEAST RECENTLY USED
// entry.
//
// Round-robin -- what md_table_ensure's four slots use, and what this started
// as -- has a hole that only shows once the table is full of entries from
// earlier configurations. A pass that must rebuild one block takes the next
// slot round; if that slot holds a live entry for a block FURTHER DOWN THE SAME
// PASS, that block then misses too, rebuilds, and takes the slot after it.
// Measured on a six-block fixture with 128 slots: a one-byte edit to one line
// rebuilt TWO blocks, the edited one and whichever neighbour its replacement
// landed on. LRU picks a stale entry from an old width or zoom instead, which
// is exactly what should go.
//
// LRU is the WHOLE fix, and that is worth stating because this procedure used to
// carry a second one -- an explicit `e.used == md_layout_pass {continue}` guard,
// commented as what kept a live entry from being evicted. Under LRU it can never
// select one: `used` is stamped with the current pass id on every hit and every
// build, so a live entry holds the MAXIMUM `used` in the table and is chosen only
// when every entry is live -- in which case the guard skips them all and the
// `max(best, 0)` fallback returns slot 0, which is exactly where the unguarded
// scan lands too. It was dead code crediting itself with the fix (2026-07-29
// review, L1).
//
// If every slot was used by this pass -- a viewport with more than
// MD_LAYOUT_SLOTS blocks in it -- there is nothing evictable that is not also
// needed, and slot 0 goes. That thrashes, bounded and correctly; the fix if it
// ever matters is more slots, not a cleverer policy.
@(private = "file")
md_layout_slot :: proc(doc: ^Document) -> ^Md_Layout {
	best := -1
	for &e, i in doc.md_layout {
		if !e.valid {return &e}
		if best < 0 || e.used < doc.md_layout[best].used {best = i}
	}
	return &doc.md_layout[max(best, 0)]
}

// The preview pane's content box, for the mode the document is actually in.
//
// ONE producer, read by markdown_draw, by markdown_links and by main.odin's own
// call sites. The draw and the hit-test must agree about where the pane is down
// to the pixel or the link seam is broken before either of them starts, and
// "both call sites evaluate the same expression" is not the same promise as
// "there is one expression".
md_pane_box :: proc(doc: ^Document, winw, winh, split_frac: f32) -> (x0, x1, ytop, ybot: f32, ok: bool) {
	if doc == nil || doc.kind != .Text {return}
	switch doc.md_mode {
	case .Off:
		return
	case .Preview:
		x0 = TEXT_MARGIN_X
	case .Split:
		x0 = doc_editor_right(doc, winw, split_frac) + TEXT_MARGIN_X
	}
	x1 = winw - SCROLLBAR_W
	ytop, ybot = doc_content_box(doc, winh)
	return x0, x1, ytop, ybot, x1 > x0
}

// Does the preview pane own the column at `mx`? True for every x in .Preview
// mode and for the right half in .Split.
//
// The dispatch is BY PANE, not by mode, and that is the point: in Split both
// models are on screen at once, the editor pass draws full-window width (the
// preview repaints over it), so an editor link hit is only meaningful left of
// the divider. Reads md_pane_box, so it cannot disagree with where the preview
// was actually drawn.
md_pane_owns :: proc(doc: ^Document, winw, winh, split_frac, mx: f32) -> bool {
	x0, x1, _, _, ok := md_pane_box(doc, winw, winh, split_frac)
	if !ok {return false}
	return mx >= x0 - TEXT_MARGIN_X && mx < x1 + SCROLLBAR_W
}

// The content origin and the measure inside a pane spanning [x0, x1].
//
// 9.3: "measure 72ch max, left-aligned, 40px left padding". The padding is
// measured from the PANE's own left edge, which is x0 - TEXT_MARGIN_X (both
// call sites hand this the margin already added), so the preview gets its 40px
// without either of them having to know that.
md_content_span :: proc(m: ^Md_Metrics, x0, x1: f32) -> (cx, measure: f32) {
	cx = max(x0, x0 - TEXT_MARGIN_X + m.pad_left)
	return cx, max(1, min(x1 - cx, m.measure))
}

// UI spec 9.1 item 4: "a scroll offset in PIXELS, not lines".
//
// The preview's position is a BLOCK plus a pixel offset into it -- the start
// byte of the block at the top of the pane, and how many pixels of that block's
// SLOT are scrolled above the pane's top edge.
//
// It is not a single pixel count measured from the document's first byte, and
// that is the whole design decision. A pure offset cannot be resolved to a
// position without laying out every block above it, which is exactly the
// failure viewport-first exists to prevent (and exactly the temptation the 2c
// brief names). The block byte is an identity that survives scrolling and costs
// nothing to resolve; the `px` is the sub-block resolution the row grid used to
// deny the preview.
//
// A block's SLOT is the collapsed gap that PRECEDES it plus the block itself,
// so `px` lives in [0, gap + h). The gap is attributed to the block below it,
// not above, because a scroll position inside a gap has to name one block and
// the block below is the one whose glyphs are about to appear.
//
// Consequence, decided deliberately (2c brief, "md_pass applies the first
// visible block's above"): the anchor block's space-ABOVE is drawn, and it is
// now SCROLLABLE rather than a constant inset at the top of the pane. At
// {0, 0} -- the top of the document -- the first block's `above` shows exactly
// as it did under the byte anchor, so 9.3's spacing table is unchanged and so
// is every assertion about it.
Md_Anchor :: struct {
	block: int, // start byte of the block at the top of the pane
	px:    f32, // pixels of that block's slot scrolled above the pane top
}

// Everything md_max_anchor's answer is a function of. Compared whole, so a term
// added to the layout later cannot be forgotten here without the compiler
// noticing the struct changed shape -- and a SCROLL moves none of these, which
// is what makes the cache free in the case that matters.
Md_Max_Key :: struct {
	rev:      u64,
	measure:  f32,
	px:       f32,
	ui_scale: f32,
	pane:     f32,
	// Which faces are loaded. The ceiling is "the anchor at which the document's
	// last block ends at the pane's bottom edge", so it is a function of block
	// HEIGHTS -- and a family change moves every one of them. The layout cache's
	// `theme` term has no counterpart here for the opposite reason: a palette
	// changes colour and no height at all.
	faces:    u64,
	valid:    bool,
}

// Everything ONE block's slot height and extent is a function of. Md_Max_Key's
// terms minus `pane` -- a block's own height does not depend on how much of the
// window is showing it -- plus the block itself.
//
// This exists so that the walk which DREW a block is the walk the scrollbar's
// fraction reads, rather than the fraction walking the same blocks again from
// inside render_frame. Measured before it existed (-o:speed, 1085-line file,
// 1340x800, mean of 200 frames): md_preview_frac 3.322 ms against
// markdown_draw's 1.660 -- the thumb's position costing twice the content it
// describes, because md_scroll_frac calls md_scroll_scalar twice and each one
// ran an md_slot_at -> md_anchor_walk with a 24-line run-up and a 256-entry
// Md_Walk_Block array. CLAUDE.md: "scroll resolution must not happen inside the
// draw".
Md_Slot_Key :: struct {
	block:    int,
	rev:      u64,
	measure:  f32,
	px:       f32,
	ui_scale: f32,
	faces:    u64,
	valid:    bool,
}

// One block as a walk measured it. `slot_top` is the top of the block's slot --
// the gap that precedes it -- relative to the walk's own start, so the block's
// glyphs begin at slot_top + gap and the slot ends at slot_top + gap + h.
//
// The layout POINTER is carried, not a copy, and that is safe only because
// MD_WALK_BLOCKS == MD_LAYOUT_SLOTS: a walk performs at most one
// md_layout_ensure per slot, every entry it touches is stamped with the current
// md_layout_pass, and md_layout_slot picks the least recently used -- so it
// cannot select an entry this walk is still holding, PROVIDED the walk holds
// fewer than MD_WALK_BLOCKS entries. At exactly MD_WALK_BLOCKS every slot
// shares this pass's stamp and md_layout_slot's `best` search falls through to
// slot 0 -- which the walk holds -- but that walk is already at its own array
// bound (`n < len(out)` in md_walk) and can take no further slot, so the stale
// pointer it hands back is never written through. Bounded and, short of
// raising one constant without the other, unreachable in practice.
// One end of a preview selection (UI spec §9.4: "Preview is selectable and
// copyable. Read-only does not mean inert").
//
// `block` is the block's START BYTE in the source, which is what every other
// preview coordinate is keyed on (Md_Anchor, the layout cache, md_table_ensure)
// -- so an edit that moves a block moves its selection with it exactly as it
// moves the scroll anchor, rather than needing its own repair.
//
// `span` indexes the block's SHAPE spans (`lay.shape`), and `off` is a byte
// offset inside that span's text -- which is precisely what plat.Shaped_Glyph
// already records for every glyph it places. The hit-test therefore reads the
// glyph the draw emitted rather than re-deriving a position from advances, which
// is the one-producer rule applied to this seam.
//
// NOT a source byte offset: the rendered text is not the source (`# Heading`
// renders as `Heading`), so a source offset could not name a position in what the
// reader is looking at, which is the thing being selected.
Md_Pos :: struct {
	block: int,
	span:  int,
	off:   int,
}

// Document order. Blocks sort by start byte, then spans within a block, then
// bytes within a span -- the same order md_pass walks and md_sel_text emits, so
// "is this glyph inside the selection" is one comparison and not a special case
// per block.
md_pos_less :: proc(a, b: Md_Pos) -> bool {
	if a.block != b.block {return a.block < b.block}
	if a.span != b.span {return a.span < b.span}
	return a.off < b.off
}

md_pos_eq :: proc(a, b: Md_Pos) -> bool {
	return a.block == b.block && a.span == b.span && a.off == b.off
}

// The selection's two ends in document order. The ANCHOR is where the drag
// started and the CURSOR is where it is now, so either may be the earlier one --
// every consumer wants them ordered and none of them wants to know which was
// which.
md_sel_range :: proc(doc: ^Document) -> (lo, hi: Md_Pos, ok: bool) {
	if doc == nil || !doc.md_sel_on {return {}, {}, false}
	a, b := doc.md_sel_a, doc.md_sel_b
	if md_pos_eq(a, b) {return {}, {}, false} // a bare click selects nothing
	if md_pos_less(b, a) {a, b = b, a}
	return a, b, true
}

md_sel_clear :: proc(doc: ^Document) {
	if doc == nil {return}
	doc.md_sel_on = false
	doc.md_sel_drag = false
	doc.md_sel_a, doc.md_sel_b = {}, {}
}

@(private = "file")
Md_Walk_Block :: struct {
	start:    int,
	end:      int,
	next:     int,
	slot_top: f32,
	gap:      f32,
	h:        f32,
	lay:      ^Md_Layout,
}

// Blocks one walk may hold at once. See Md_Walk_Block: this is not a tuning
// knob, it is the layout cache's slot count, and the two must move together.
MD_WALK_BLOCKS :: MD_LAYOUT_SLOTS

// Lines of run-up a walk takes before the block it is resolving.
//
// The collapsed gap ABOVE a block is a function of the block BEFORE it
// (max(prev.below, this.above)), so a walk that starts at the anchor gets the
// anchor's own gap wrong -- it sees no predecessor and falls back to the
// block's own `above`. Measured on a paragraph following a paragraph that is 19
// px at S=24, and it is not a cosmetic error: it makes the anchor's slot a
// different height in different procedures, so scrolling one pixel across a
// block boundary and back landed 19 px from where it started, and the drag's
// inverse stopped agreeing with the map. Every walk that RESOLVES an anchor
// takes this run-up, so the gap is the same number everywhere.
//
// 24 lines is headroom, not a derived bound: the fix above only needs the ONE
// block before the anchor, which is rarely more than a couple of source lines
// away, so 24 is generous margin for that case and nothing more precise than
// "comfortably more than one block usually costs".
//
// It no longer has to CLEAR anything, and clearing things was its other,
// unstated job. Whatever line the run-up lands on, md_runup_start snaps it back
// to a real block start before a walk may begin there, so a paragraph of any
// length and a front-matter card of any size are entered at their own first
// byte rather than wherever 24 lines happened to reach. The paragraph case is
// what forced that (a joined run is unbounded, so no constant could have worked);
// the front-matter case is the one this comment used to record as "an absence of
// a demonstrated defect, not a proof the case is handled" -- md_wheel_selftest's
// 30- and 50-line cards each diverged on exactly one up-step, and with the snap
// they diverge on none. A collapsed blank run longer than 24 lines is the one
// construct still riding on this constant; see md_block_start_at.
MD_RUNUP_LINES :: 24

// Lay blocks out forward from `from`, stopping at `limit_h` pixels of height, at
// `stop_at` bytes, or at a bound -- whichever comes first.
//
// THE viewport-first primitive. Every walk over blocks in this file goes through
// here, and every caller passes a height limit derived from the PANE. There is
// no path that walks to the end of a document: `limit_h` and `len(out)` are both
// hard, and the zero-height bound (MD_MAX_EMPTY_BLOCKS) covers the case a height
// limit cannot see.
//
// `limit_from` is where the height limit starts counting -- the run-up above an
// anchor is not part of the pane's budget and must not eat it.
@(private = "file")
md_walk :: proc(
	gfx: ^plat.Gfx,
	text: ^plat.Text,
	doc: ^Document,
	m: ^Md_Metrics,
	measure: f32,
	from: int,
	stop_at: int,
	limit_from: int,
	limit_h: f32,
	out: []Md_Walk_Block,
) -> (
	n: int,
	total: f32,
	reached: bool,
) {
	if doc == nil {return}
	base_h := f32(0)
	counting := from >= limit_from
	buf: [RENDER_LINE_CAP]u8
	p := clamp(from, 0, doc.pt.length)
	// Seeded from the document's own lexer state at `from`, NOT from `false`: the
	// opening fence can be anywhere above. See md_fence_seed.
	in_fence, fence_lex := md_fence_seed(doc, p)
	fence_state: base.Lex_State
	// Adjacent margins collapse: the gap between two blocks is the larger of the
	// upper one's space-below and the lower one's space-above, which is what
	// browsers do and what 9.3's own numbers assume (a paragraph's 0.8 S and an
	// h2's 1.6 S are not meant to sum). `prev_below` carries the upper half.
	prev_below := f32(0)
	// The walk has just passed a list item and has not yet seen what ends the run.
	// See the gap override below; this is the only piece of BETWEEN-block state the
	// walk keeps besides prev_below, and both exist for the same reason -- a gap is
	// a property of a pair, not of a block.
	after_list := false
	empties := 0
	reached = p > doc.pt.length || p >= stop_at
	for p <= doc.pt.length && p < stop_at && n < len(out) && empties < MD_MAX_EMPTY_BLOCKS {
		if !counting && p >= limit_from {counting, base_h = true, total}
		end := base.pt_line_end_cap(&doc.pt, p, RENDER_LINE_CAP)
		nb := base.pt_read(&doc.pt, p, buf[:min(end - p, len(buf))])
		if nb > 0 && buf[nb - 1] == '\r' {nb -= 1}
		lay := md_layout_ensure(gfx, text, doc, m, p, end, string(buf[:nb]), in_fence, fence_lex, fence_state, measure)
		gap := max(prev_below, lay.above)
		// THE GAP AFTER A LIST RUN IS A PARAGRAPH'S, NOT AN ITEM'S. §9.3 gives a
		// list item "0.25 S between items" -- between ITEMS -- and the layout
		// applied it as the `below` of every item including the last, so the prose
		// after a list sat as close to it as one bullet sits to the next. Entering
		// a list already gets the full 0.8 S (the preceding paragraph's own below),
		// so the asymmetry was visible in one screenful: "it does not look like
		// this is the case, there isn't a slightly larger gap like the top of the
		// list" (Wyatt, live use, v0.37.0 §3).
		//
		// A LOOK BACK, not a look ahead, which is why it lives here and not in
		// md_layout_ensure: a block cannot know whether the list it belongs to has
		// ended, but the walk knows what it has just passed. `last_kind` skips
		// .Blank so a LOOSE list -- items separated by blank lines -- still reads
		// as one list at 0.25 S rather than being pulled apart by its own blanks.
		//
		// max(), so this only ever RAISES the gap to at least a paragraph's worth.
		// Every block with a bigger space-above of its own keeps it: an h2's 1.6 S,
		// a fence's 1.0 S, a rule's 24px are all untouched by this.
		//
		// It fires on the FIRST non-list block, blank or not, and clears there --
		// which is what makes the total come out at exactly one paragraph gap
		// rather than the item's 0.25 S plus a paragraph's 0.8 S stacked. A blank
		// line has no height of its own, so the space between the last bullet and
		// the prose under it is this one number.
		//
		// CONSEQUENCE, stated because it is a real change and not a side effect
		// worth hiding: a LOOSE list -- items separated by blank lines -- now has a
		// paragraph gap between its items rather than 0.25 S, because that blank is
		// the first non-list block after an item. That is what CommonMark means by
		// loose and what every browser renders (a loose item's content is wrapped
		// in <p> and takes paragraph margins), and the source asked for it by
		// leaving the line blank. A TIGHT list is untouched: the next item follows
		// immediately, so nothing fires.
		//
		// PROSE AND BLANKS ONLY, not every block that can follow a list. Every
		// other kind carries its own space-above from §9.3 -- an h2's 1.6 S, a
		// fence's 1.0 S, a quote's 0.8 S -- and those are already at least a
		// paragraph's worth, so raising them would change nothing. The one
		// exception is an h1, whose §9.3 space-above is 0 ON PURPOSE (it is the
		// document's opening element), and overriding that would be this fix
		// second-guessing the spec on a case nobody reported. A paragraph's
		// space-above is 0 for the same stated reason and is exactly the case that
		// WAS reported, which is why the gap has to come from the list's side.
		if after_list && lay.cls.kind != .List {
			if lay.cls.kind == .Para || lay.cls.kind == .Blank {
				gap = max(gap, m.para_below)
			}
			after_list = false
		}
		if lay.cls.kind == .List {after_list = true}
		out[n] = {start = p, end = lay.end, next = lay.next, slot_top = total, gap = gap, h = lay.h, lay = lay}
		n += 1
		total += gap + lay.h
		// See MD_MAX_EMPTY_BLOCKS: a zero-height block is invisible to a height
		// limit, so it needs a bound of its own.
		empties = empties + 1 if lay.h <= 0 else empties
		prev_below = lay.below
		in_fence, fence_lex, fence_state = lay.out_fence, lay.out_lex, lay.out_state
		if lay.next > doc.pt.length {
			reached = true
			break
		}
		p = lay.next
		reached = p >= stop_at
		if counting && total - base_h >= limit_h {break}
	}
	return
}

// The walk that RESOLVES an anchor: MD_RUNUP_LINES of run-up before it, so the
// anchor block's collapsed gap is the document's and not an artefact of where
// the walk began (see MD_RUNUP_LINES), plus the index of the block the anchor
// falls in.
//
// Every consumer of an anchor goes through here -- the draw, the slot height,
// the downward scroll -- which is what makes "the anchor's slot" one number.
// `limit_h` is measured from the anchor, not from the run-up.
@(private = "file")
md_anchor_walk :: proc(c: ^Md_Scroll_Ctx, block: int, limit_h: f32, out: []Md_Walk_Block) -> (n, idx: int) {
	from := md_runup_start(c.doc, block, MD_RUNUP_LINES)
	n, _, _ = md_walk(c.gfx, c.text, c.doc, &c.m, c.measure, from, max(int), block, limit_h, out)
	// The last block starting at or before the anchor byte IS the block the
	// anchor names -- blocks tile the document -- so a stale anchor left
	// mid-block by an edit resolves to its container instead of misreading.
	for i in 0 ..< n {
		if out[i].start <= block {idx = i}
	}
	return
}

// One block as a pane PUT IT ON SCREEN: the walk entry, the client y its top
// landed at, and how much of it the pane admitted.
@(private = "file")
Md_Placed :: struct {
	blk:   Md_Walk_Block,
	y:     f32,
	admit: Md_Admit,
	// Wholly above ytop -- a zero-height anchor (a blank run), or an anchor whose
	// px invariant an edit broke underneath it. Reported as PASSED rather than
	// painted into the chrome, and it does not spend the first block's waiver:
	// that belongs to the first block with something to show.
	above: bool,
}

// The state of one pane's placement walk. See md_place_next.
@(private = "file")
Md_Placer :: struct {
	blocks:         []Md_Walk_Block,
	i, n:           int,
	y0, ytop, ybot: f32,
	forced:         bool,
	done:           bool,
}

@(private = "file")
md_placer :: proc(blocks: []Md_Walk_Block, idx, n: int, y0, ytop, ybot: f32) -> Md_Placer {
	// `forced` starts true: the very first block with something to show is
	// admitted whatever the pane's height. See md_block_admit.
	return {blocks = blocks, i = idx, n = n, y0 = y0, ytop = ytop, ybot = ybot, forced = true}
}

// THE producer of "what this pane has on screen", stepped one block at a time.
//
// md_pass PAINTS exactly what this returns and md_block_at_y MAPS exactly what
// this returns -- neither has an admit test of its own, and neither may grow one.
// Before 2026-07-29 they each ran their own copy of the loop against
// md_block_fits, and md_block_at_y's comment said in as many words that it
// existed to "mirror md_pass's own fit test". That mirror was survivable only
// while admission was per-BLOCK and both copies read one number; with per-line
// admission a drifted copy means a click naming a block whose lines the pane
// never painted, which is CLAUDE.md's one-layout-per-widget rule ("no procedure
// may both compute a coordinate and consume it") stated for the preview's
// blocks. So the loop itself is the shared thing, not just the predicate.
//
// Iterator rather than an out-slice because a second MD_WALK_BLOCKS array per
// call is real temp-arena traffic three times a frame, and because a caller that
// receives blocks one at a time cannot accidentally look past the one the pane
// stopped at.
@(private = "file")
md_place_next :: proc(p: ^Md_Placer) -> (out: Md_Placed, ok: bool) {
	if p == nil || p.done || p.i >= p.n {return}
	b := p.blocks[p.i]
	y := p.y0 + b.slot_top + b.gap
	if y + b.h <= p.ytop {
		p.i += 1
		return Md_Placed{blk = b, y = y, above = true, admit = {lines = md_block_lines(b.lay), h = b.h, whole = true}}, true
	}
	// The ONE consumer pair of the height the layout produced: this test and the
	// walk's own advance. Nothing else may size this block.
	a := md_block_admit(b.lay, y, p.ybot, p.forced)
	if a.lines == 0 {
		p.done = true
		return
	}
	p.forced = false
	// A partially admitted block is the LAST thing on screen: there is no room
	// below its unadmitted lines for anything else, and the pass must not report
	// having finished it. Stop here.
	if !a.whole {p.done = true}
	p.i += 1
	return Md_Placed{blk = b, y = y, admit = a}, true
}

// One walk over the visible blocks, consumed by the draw and by the link pass.
//
// There is exactly ONE of these because the two consumers must not be able to
// disagree: what is clickable is what is drawn, and the only way to guarantee
// that is for both to come out of the same walk over the same layout cache with
// the same inputs. `qp` is nil for the link pass, which is what turns the
// painting off -- nothing else differs, not even the order.
//
// Viewport-first, and 9.1's layout budget: blocks are built from the anchor
// forward and the walk stops one PANE past the bottom edge -- "the visible
// blocks plus a screen below". The screen ABOVE is laid out by md_probe_back,
// on the scroll-up path, where it is the thing being asked for rather than work
// repeated three times a frame; see that procedure. Nothing is ever laid out
// for the document.
@(private = "file")
md_pass :: proc(
	gfx: ^plat.Gfx,
	qp: ^plat.Quad_Pipeline,
	text: ^plat.Text,
	doc: ^Document,
	px: f32,
	x0, x1, ytop, ybot: f32,
	at: Md_Anchor,
	links: ^[dynamic]Md_Link_Hit,
	// Optional hit-test: when non-nil, the point to resolve into an Md_Pos and
	// where to put the answer. Rides this walk rather than getting its own for the
	// reason md_preview_link_at's header gives about links -- a second walk is a
	// second chance to place a block somewhere the draw did not.
	sel_at: ^Md_Sel_Probe = nil,
) -> (
	bottom: int,
	shown:  int,
) {
	bottom = at.block
	shown = at.block
	if doc == nil {return}
	md_layout_pass += 1 // see md_layout_slot: this pass's entries are not evictable
	m := md_metrics(text, px)
	cx, measure := md_content_span(&m, x0, x1)
	pane := max(1, ybot - ytop)
	c := Md_Scroll_Ctx{gfx, text, doc, m, measure, ytop, pane}
	blocks := make([]Md_Walk_Block, MD_WALK_BLOCKS, context.temp_allocator)
	// The anchor's own scrolled-off part, the pane, and one pane below it -- 9.1's
	// budget. The run-up md_anchor_walk takes is NOT part of that budget and is
	// never drawn; it is what makes the anchor's gap the document's own.
	n, idx := md_anchor_walk(&c, at.block, at.px + pane * 2, blocks)
	// The anchor block's slot, handed to md_slot_at rather than left for it to
	// re-derive. This walk already has the number: `md_slot_at` runs the SAME
	// md_anchor_walk from the same byte with the same run-up, differing only in a
	// height limit that cannot affect any block at or before `idx`. Publishing it
	// here is what stops the scrollbar's fraction from resolving the scroll
	// position a second time inside render_frame, three lines after this pass
	// produced it (CLAUDE.md's one-producer rule, and its "scroll resolution must
	// not happen inside the draw").
	if n > 0 {md_slot_store(&c, at.block, blocks[idx])}
	if links != nil {link_cache_begin(doc)}
	// The anchor block's SLOT top, in client pixels. Everything else in the pass
	// is this plus the walk's own relative offsets -- one origin, so a block's
	// draw y and its link rect's y cannot be two different numbers.
	y0 := ytop - at.px - (blocks[idx].slot_top if n > 0 else 0)
	// From the anchor, not from the walk's start: the blocks before `idx` are the
	// run-up, and they exist only so the anchor's gap is right. What is admitted
	// is md_place_next's answer and nothing else -- see its header.
	pl := md_placer(blocks, idx, n, y0, ytop, ybot)
	// See the zebra note in the loop: the table block currently being counted
	// within, and the row index inside it.
	zebra_tbl := -1
	zebra_row := 0
	for {
		p, ok := md_place_next(&pl)
		if !ok {break}
		if p.above {
			bottom = p.blk.end
			shown = p.blk.end
			continue
		}
		// Zebra parity for a table row (§9.2 item 6). Tracked by the WALK, not
		// baked into the block's cached layout: the preview caches one row per
		// Md_Layout entry keyed on that row's own line, so an insert at the top of
		// a table flips every following row's parity while those entries stay
		// valid. Parity is a property of position within the table, which only the
		// walk knows.
		//
		// The first visible row's parity is counted from the TABLE'S OWN START,
		// which is usually off screen -- md_placer begins at the anchor, so the
		// rows above it are never walked. Counting only from the first visible row
		// would make the stripes flip as the table scrolled. That count is one
		// bounded scan per table per frame (the cache window), and every row after
		// it just increments.
		trow := -1
		if p.blk.lay != nil && p.blk.lay.cls.kind == .Table {
			if tc := md_table_ensure(doc, text, p.blk.start); tc != nil {
				if tc.start != zebra_tbl {
					zebra_tbl = tc.start
					zebra_row = md_table_row_index(doc, tc.start, p.blk.start)
				} else {
					zebra_row += 1
				}
				trow = zebra_row
			}
		} else {
			zebra_tbl = -1 // a non-table block ends the run
		}
		if qp != nil {md_block_draw(gfx, qp, text, doc, &m, p.blk.lay, cx, x1, p.y, p.admit, p.blk.start, trow)}
		if links != nil {md_block_links(doc, p.blk.lay, cx, p.y, p.admit, links)}
		if sel_at != nil && !sel_at.ok {
			// First block whose admitted band contains the point wins. `>= p.y` and
			// the admitted height, not the layout height, so a point over the part of
			// a block the pane refused resolves in the NEXT block instead of one the
			// reader cannot see -- the same bound md_block_links applies.
			if sel_at.y >= p.y && sel_at.y < p.y + p.admit.h {
				sel_at.pos, sel_at.ok = md_block_pos_at(p.blk, cx, p.y, p.admit, sel_at.x, sel_at.y)
			}
			// Remember the last block the walk admitted, so a point BELOW every block
			// (the empty pane under a short document) can still clamp to the end of
			// the text rather than selecting nothing.
			if p.admit.h > 0 {sel_at.last, sel_at.last_y, sel_at.last_ad, sel_at.cx = p.blk, p.y, p.admit, cx}
		}
		// `bottom` advances only past a block that is FINISHED. A partially drawn
		// block reports its own start (i.e. leaves `bottom` where the previous block
		// left it), because lines of it the reader has never seen are not behind
		// them. The preview scrolls in PIXELS (Md_Anchor{block, px}), so the pixel
		// anchor is what advances into a partial block. `bottom` has no consumer
		// left in the product (2026-07-29 review, F1) -- it is kept because it is
		// still the honest "last FINISHED block" answer and something may want that
		// again -- but it is no longer what sizes the thumb.
		//
		// `shown` is that different input. It credits a partial block with the
		// FRACTION of its own byte span its admitted lines cover, using
		// `p.admit.h / p.blk.h` -- the identical fraction md_block_draw already used
		// to decide how tall the Fence_Body / Quote band gets (see its comments),
		// so the thumb's extra credit can never disagree with what was actually
		// painted. Byte-proportional, not line-proportional, because md_vscrollbar_geo
		// is byte-proportional throughout (its own header: measuring the document's
		// HEIGHT would mean laying it out, which viewport-first forbids). A block
		// that is refused outright (p.admit.h == 0, e.g. `forced` pinned it to one
		// line that still does not fit) contributes 0 of its span, same as before.
		if !p.admit.whole {
			frac := p.admit.h / max(1, p.blk.h)
			shown = p.blk.start + int(f32(p.blk.end - p.blk.start) * clamp(frac, 0, 1))
			break
		}
		bottom = p.blk.end
		shown = p.blk.end
	}
	return
}

// Render markdown source from `at`, laid out in [x0,x1] x [ytop,ybot].
//
// Returns the byte offset just past the last FINISHED block -- NOT "for scroll
// clamping" (the preview's clamp is md_scroll_clamp -> md_max_anchor, which
// reads neither this nor any admit decision) and not "the last line drawn"
// (a partially admitted block's lines ARE drawn and this does not advance past
// them). Corrected 2026-07-29 review, F5: both halves of the old sentence were
// false, and the false "for scroll clamping" half is what produced F1's wrong
// premise that this value was safe to feed the thumb.
//
// `shown`, an optional out-param, is the DIFFERENT input the thumb actually
// needs: the byte extent the pane put on screen, crediting a partially
// admitted block with the fraction of its own span its admitted lines cover
// instead of stopping dead at its start. See md_pass for why `bottom` itself
// is kept rather than repurposed.
//
// A partially-scrolled anchor block draws ABOVE ytop -- that is what a pixel
// offset is -- and there is no scissor rect in this renderer, so the caller owes
// this pane a cover strip over [0, ytop) exactly as it already owes one below
// ybot. md_preview_clip is that strip.
markdown_draw :: proc(gfx: ^plat.Gfx, qp: ^plat.Quad_Pipeline, text: ^plat.Text, doc: ^Document, px: f32, x0, x1, ytop, ybot: f32, at: Md_Anchor, shown: ^int = nil) -> (bottom: int) {
	s: int
	bottom, s = md_pass(gfx, qp, text, doc, px, x0, x1, ytop, ybot, at, nil)
	if shown != nil {shown^ = s}
	return
}

// The links the preview would draw, in absolute client coordinates. The same
// walk markdown_draw makes, with the painting off -- so a link's rectangle here
// IS the rectangle its glyphs were drawn inside, not a second derivation of it.
//
// Called from the input phase (the hand cursor and the Ctrl+click test) where
// the frame's draw has not run yet; the layout cache makes it a lookup per
// block rather than a second shaping pass.
// DELIBERATELY UNBOUNDED IN Y, and that is load-bearing rather than an
// oversight: this reports what the pass actually PUT ON SCREEN, overflow
// included, and mdtest's partial-admission sweep reads exactly that -- "no drawn
// line's bottom exceeds ybot" is an assertion about the admit rule that can only
// be made if this producer is willing to report a rect that broke it. Clipping
// here would make that assertion pass by construction. The pane's y bound for
// CLICKING lives in md_preview_link_at, on the hit-test path, where it cannot
// silence anything.
markdown_links :: proc(gfx: ^plat.Gfx, text: ^plat.Text, doc: ^Document, px: f32, x0, x1, ytop, ybot: f32, at: Md_Anchor, allocator := context.temp_allocator) -> []Md_Link_Hit {
	out := make([dynamic]Md_Link_Hit, 0, 8, allocator)
	md_pass(gfx, nil, text, doc, px, x0, x1, ytop, ybot, at, &out)
	return out[:]
}

// The preview pane's links for this frame, or nil when the document has no
// preview pane on screen.
//
// The hand cursor, the Ctrl+click and the underline all call THIS, and it takes
// its pane box from md_pane_box, which is also what the draw takes. Three
// consumers, one producer, one pane box -- so none of them can end up hit-
// testing a rectangle the draw placed somewhere else.
md_preview_links :: proc(gfx: ^plat.Gfx, text: ^plat.Text, doc: ^Document, px, winw, winh, split_frac: f32, allocator := context.temp_allocator) -> []Md_Link_Hit {
	x0, x1, ytop, ybot, ok := md_pane_box(doc, winw, winh, split_frac)
	if !ok {return nil}
	return markdown_links(gfx, text, doc, px, x0, x1, ytop, ybot, doc.md_top, allocator)
}

// The preview link under a client-space point -- THE hit-test, and the only
// place the pane's y bound is applied.
//
// One proc for both consumers (main.odin's hand cursor and its Ctrl+click),
// because it is the same question asked twice and they used to ask it as two
// open-coded md_link_at(md_preview_links(...)) expressions with no bound in
// either. md_link_at tests point-in-rect and nothing else; md_block_admit
// force-admits the pane's first LINE even when it does not fit ("no frame ever
// shows emptiness" outranks the cover strip's trim), and its link rects go with
// it (md_block_links gates on b.line >= ad.lines, not on y). The glyphs are then
// covered by md_preview_clip's strip -- so the rect was invisible and still
// live, and Ctrl+clicking the status bar opened a link the user could not see.
//
// The bound is on the POINT, not on the rectangles, and that is what keeps it to
// ONE bound. Clipping the rects would need the pane box in md_preview_links too,
// and would silence the only assertion the suite has about the admit rule
// overflowing (see markdown_links). Refusing a point the pane does not own is
// exact for both cases at once: a rect wholly below ybot becomes unreachable,
// and a rect that straddles ybot keeps exactly its visible half clickable --
// which matters, because the alternative (dropping it) would make a link that IS
// drawn and IS underlined stop responding.
//
// ytop as well as ybot: the pane owes a cover strip at BOTH ends (markdown_draw)
// because a partially-scrolled anchor block draws above ytop, and rects go up
// there for the same reason they go down past ybot.
// A pixel→position query riding md_pass. `last*` carry the final admitted block
// so a point below every block clamps to the end of the document's text instead
// of resolving to nothing -- dragging past the last paragraph is how people
// select to the end.
@(private = "file")
Md_Sel_Probe :: struct {
	x, y:    f32,
	pos:     Md_Pos,
	ok:      bool,
	last:    Md_Walk_Block,
	last_y:  f32,
	last_ad: Md_Admit,
	// The content origin this pass laid the blocks against. Recorded by the walk
	// rather than re-derived by the caller: md_block_pos_at reads glyph x's
	// relative to it, and a second derivation is a second chance to disagree with
	// where the draw actually put them.
	cx:      f32,
}

// How much of the document a preview copy will lay out, in bytes of SOURCE.
//
// Copying needs each block's rendered spans, which means laying each block out --
// shaping included. That is cheap per block and unbounded over a document, and
// Ctrl+A on a large markdown file is exactly the case that would discover it. So
// it refuses past this and says so, the same shape as JSON_FORMAT_MAX and
// TABLE_SORT_MAX rather than a new idea.
//
// 4 MB is far past any hand-written document and well inside what one frame can
// absorb; the number is a starting point rather than a measurement, which is
// stated because §6bl records a ceiling that was argued rather than measured.
MD_COPY_MAX :: 4 * 1024 * 1024

// The rendered text of the current preview selection, in document order.
//
// "Copy yields the rendered text, not the markdown" (UI spec §9.4), and Wyatt's
// call for the details was "like Obsidian" -- whose reading view is HTML, so a
// PLAIN-TEXT copy out of it keeps list bullets, tab-separates table cells (which
// is what makes a pasted table land in a spreadsheet's columns) and copies a link
// as its label. That is what this produces.
//
// What it deliberately does NOT do, and Obsidian does: put a RICH-TEXT flavour on
// the clipboard as well, so pasting into Word keeps the bold and the headings.
// That is a second clipboard format (CF_HTML) and a second serializer; recorded
// in requested-features.md rather than half-done here.
md_sel_text :: proc(gfx: ^plat.Gfx, text: ^plat.Text, doc: ^Document, px, measure: f32, allocator := context.temp_allocator) -> (out: string, ok: bool) {
	lo, hi, on := md_sel_range(doc)
	if !on {return "", false}
	if hi.block - lo.block > MD_COPY_MAX {return "", false}
	m := md_metrics(text, px)
	// The SAME walk the draw uses (md_walk), not a second block enumeration. It
	// is what carries fence state forward -- a selection that starts inside a
	// fenced code block has to see the blocks after it as fence bodies, and a
	// hand-rolled "classify each line from lo.block" would not, so the copy would
	// disagree with what is on screen about what those lines even are.
	//
	// The run-up is md_runup_start's, exactly as md_anchor_walk takes it, because
	// that is what makes the first block's own state right.
	blocks := make([]Md_Walk_Block, MD_WALK_BLOCKS, context.temp_allocator)
	from := md_runup_start(doc, lo.block, MD_RUNUP_LINES)
	sb := strings.builder_make(allocator)
	first := true
	for from <= doc.pt.length {
		n, _, _ := md_walk(gfx, text, doc, &m, measure, from, max(int), lo.block, 1e30, blocks)
		if n == 0 {break}
		done := false
		for bi in 0 ..< n {
			blk := blocks[bi]
			if blk.start < lo.block {continue} // still in the run-up
			if blk.start > hi.block {done = true;break}
			md_sel_block_text(&sb, blk.lay, blk.start, lo, hi, &first)
		}
		if done {break}
		nxt := blocks[n - 1].next
		if nxt <= from {break} // a walk that does not advance would spin
		from = nxt
	}
	return strings.to_string(sb), true
}

// The preview selection's text for the CURRENT pane, or ok=false when there is
// no selection or no pane. The clipboard's one call.
//
// Takes the pane box from md_pane_box, like every other preview consumer, so the
// measure a copy re-lays-out against is the measure the reader is looking at --
// a different measure would wrap differently and, for a table, fit a different
// number of columns.
md_preview_sel_text :: proc(gfx: ^plat.Gfx, text: ^plat.Text, doc: ^Document, px, winw, winh, split_frac: f32, allocator := context.temp_allocator) -> (string, bool) {
	if doc == nil || !doc.md_sel_on {return "", false}
	x0, x1, _, _, ok := md_pane_box(doc, winw, winh, split_frac)
	if !ok {return "", false}
	m := md_metrics(text, px)
	_, measure := md_content_span(&m, x0, x1)
	return md_sel_text(gfx, text, doc, px, measure, allocator)
}

// Package-visible so mdseltest can drive the copy without a window: the pane box
// is the only thing md_preview_sel_text needs one for, and a test that supplied a
// fake window would be asserting against a measure the product never uses. Takes
// the measure directly instead, which is what md_pane_box would have produced.
md_preview_sel_text_for_test :: proc(doc: ^Document, text: ^plat.Text, px, measure: f32, allocator := context.temp_allocator) -> (string, bool) {
	return md_sel_text(nil, text, doc, px, measure, allocator)
}

// Select the whole rendered document (Ctrl+A in the preview). The end position
// is deliberately "past the last block", which md_sel_text clamps per block --
// naming a real final span would mean laying the last block out here, and the
// walk is going to do that anyway.
md_preview_select_all :: proc(doc: ^Document) {
	if doc == nil {return}
	doc.md_sel_a = Md_Pos{block = 0, span = 0, off = 0}
	doc.md_sel_b = Md_Pos{block = max(0, doc.pt.length), span = max(int), off = max(int)}
	doc.md_sel_on = true
	doc.md_sel_drag = false
}

// One block's contribution to a copy. Split out so the walk above reads as a
// walk and the Obsidian-shaped formatting decisions live in one place.
@(private = "file")
md_sel_block_text :: proc(sb: ^strings.Builder, lay: ^Md_Layout, p: int, lo, hi: Md_Pos, first: ^bool) {
	if lay == nil {return}
	// A blank line renders nothing and contributes no text, but it DOES end a
	// paragraph -- the newline BETWEEN blocks is what carries that, which is why it
	// is written before the block rather than after (no trailing newline on a copy).
	if !first^ {strings.write_byte(sb, '\n')}
	first^ = false
	// The list marker is drawn from cls.bullet at an offset rather than being one
	// of the shaped spans, so a copy that only walked spans would lose it. Obsidian
	// keeps it, and a bulleted list pasted without its bullets reads as a paragraph
	// of fragments.
	if lay.cls.kind == .List && len(lay.cls.bullet) > 0 {
		strings.write_string(sb, lay.cls.bullet)
		strings.write_byte(sb, ' ')
	}
	for sp, i in lay.shape {
		// Trim the two END blocks to the selection; every block between them
		// contributes whole.
		s := sp.text
		if p == lo.block && i < lo.span {continue}
		if p == hi.block && i > hi.span {break}
		a := lo.off if (p == lo.block && i == lo.span) else 0
		b := hi.off if (p == hi.block && i == hi.span) else len(s)
		a = clamp(a, 0, len(s))
		b = clamp(b, a, len(s))
		strings.write_string(sb, s[a:b])
		// A table row's cells are separate spans, and a TAB between them is what
		// makes the paste land in a spreadsheet's columns -- which is exactly what
		// copying a table out of Obsidian's reading view does.
		if lay.cls.kind == .Table && !lay.cls.is_sep && i + 1 < len(lay.shape) {
			strings.write_byte(sb, '\t')
		}
	}
}


// Is this glyph inside the selection? `pos` is the glyph's own position and the
// range is half-open [lo, hi) -- the same convention the editor's selection uses,
// so the character under the drag's end is not included until the drag passes it.
@(private = "file")
md_glyph_selected :: proc(blk_start: int, g: plat.Shaped_Glyph, lo, hi: Md_Pos) -> bool {
	p := Md_Pos{block = blk_start, span = int(g.span), off = int(g.off)}
	return !md_pos_less(p, lo) && md_pos_less(p, hi)
}

// Selection bands for one block: one quad per visual line, spanning from the
// first selected glyph on that line to the right edge of the last.
//
// Reads the SAME glyph list the draw is about to paint, so a highlighted
// character and a drawn character cannot be different characters -- this is the
// draw/selection seam and it has exactly one producer.
@(private = "file")
md_draw_selection :: proc(gfx: ^plat.Gfx, qp: ^plat.Quad_Pipeline, doc: ^Document, lay: ^Md_Layout, cx, ytop: f32, ad: Md_Admit, blk_start: int) {
	lo, hi, ok := md_sel_range(doc)
	if !ok || lay == nil || len(lay.sh.glyphs) == 0 {return}
	// Whole blocks outside the range contribute nothing, and this is the cheap
	// test that keeps a long selection from costing per-glyph work on every block
	// on screen.
	if blk_start < lo.block || blk_start > hi.block {return}
	x := md_block_origin(lay, cx)
	nlines := len(lay.sh.line_boxes)
	if ad.lines > 0 {nlines = min(nlines, ad.lines)}
	for line in 0 ..< nlines {
		l0, l1 := f32(1e9), f32(-1e9)
		for g, i in lay.sh.glyphs {
			if int(g.line) != line {continue}
			if !md_glyph_selected(blk_start, g, lo, hi) {continue}
			gx := x + g.x
			adv := f32(0)
			if i + 1 < len(lay.sh.glyphs) && int(lay.sh.glyphs[i + 1].line) == line {
				adv = lay.sh.glyphs[i + 1].x - g.x
			} else {
				adv = max(0, lay.sh.line_boxes[line].width - g.x)
			}
			l0 = min(l0, gx)
			l1 = max(l1, gx + adv)
		}
		if l1 <= l0 {continue}
		lb := lay.sh.line_boxes[line]
		plat.quads_draw(
			gfx,
			qp,
			[]plat.Quad{{pos = {l0, ytop + lb.top}, size = {l1 - l0, lb.h}, color = g_theme[.Selection_Doc]}},
		)
	}
}

// Which row of its table the block starting at `row` is: 0 for the header, 1 for
// the separator, 2 upward for data rows.
//
// A newline count over [table_start, row), which is bounded by the table cache's
// own window (md_table_budget) because `table_start` came from that cache -- so
// this cannot walk a document, only a block. Called ONCE per table per frame; the
// walk increments from there.
@(private = "file")
md_table_row_index :: proc(doc: ^Document, table_start, row: int) -> int {
	if doc == nil || row <= table_start {return 0}
	buf: [512]u8
	n := 0
	p := table_start
	for p < row {
		got := base.pt_read(&doc.pt, p, buf[:min(len(buf), row - p)])
		if got == 0 {break}
		for i in 0 ..< got {
			if buf[i] == '\n' {n += 1}
		}
		p += got
	}
	return n
}

// Does this table row get a zebra band? Header and separator never do, and data
// rows alternate starting with the SECOND one -- so the first row of data reads
// against the page and the band is what separates it from the next, rather than
// the whole table sitting on a tint.
//
// §10 made the same call for the grid ("column rules are gone, table_zebra
// carries the eye instead") and this is that rule in the preview, which is what
// §9.2 item 6 asks for.
@(private = "file")
md_zebra_row :: proc(trow: int) -> bool {
	if trow < 2 {return false} // 0 header, 1 separator
	return (trow - 2) % 2 == 1
}

// Package-visible for mdzebratest. These two are what make the stripe
// scroll-invariant -- the index is counted from the table's own start rather than
// from the first visible row -- so they are worth asserting directly, not only
// through pixels.
md_table_row_index_for_test :: proc(doc: ^Document, table_start, row: int) -> int {
	return md_table_row_index(doc, table_start, row)
}
md_zebra_row_for_test :: proc(trow: int) -> bool {return md_zebra_row(trow)}

// The rendered position under a point inside one laid-out block.
//
// Reads `lay.sh.glyphs` -- the glyphs the draw placed -- so the character the
// caller selects is the character the reader sees at that pixel. Nothing here
// re-measures anything.
//
// Two deliberate roundings, both of which are what a text selection is expected
// to do rather than what a strict point-in-rect would do:
//   - past the last glyph on a line, the position is the END of that line's last
//     glyph, so dragging into the ragged right margin selects to end-of-line
//     rather than stopping at the final character;
//   - within a glyph, the nearer EDGE wins, so clicking the left half of a
//     character puts the boundary before it. A caret-less view still has a
//     boundary; it is just drawn as the edge of a highlight.
@(private = "file")
md_block_pos_at :: proc(blk: Md_Walk_Block, cx, ytop: f32, ad: Md_Admit, mx, my: f32) -> (Md_Pos, bool) {
	lay := blk.lay
	if lay == nil || len(lay.sh.glyphs) == 0 {return {}, false}
	// Which visual line the point is on, bounded to the lines this block was
	// ADMITTED -- a line the pane refused was never drawn, so a point cannot be
	// on it even though the layout has geometry for it.
	line := -1
	for lb, i in lay.sh.line_boxes {
		if ad.lines > 0 && i >= ad.lines {break}
		top := ytop + lb.top
		if my >= top && my < top + lb.h {line = i;break}
	}
	if line < 0 {
		// Above the first admitted line or below the last: clamp to the block's
		// nearer end so a drag that runs off the block still resolves inside it.
		last := max(0, min(len(lay.sh.line_boxes), ad.lines if ad.lines > 0 else len(lay.sh.line_boxes)) - 1)
		line = 0 if my < ytop else last
	}
	best := -1
	best_after := false
	for g, i in lay.sh.glyphs {
		if int(g.line) != line {continue}
		gx := cx + g.x
		if best < 0 {best = i}
		if mx >= gx {
			best = i
			// Past this glyph's midpoint means the boundary is after it. The
			// advance is the next glyph's x on the same line, or the line's own
			// width for the last one.
			adv := f32(0)
			if i + 1 < len(lay.sh.glyphs) && int(lay.sh.glyphs[i + 1].line) == line {
				adv = lay.sh.glyphs[i + 1].x - g.x
			} else {
				adv = max(0, lay.sh.line_boxes[line].width - g.x)
			}
			best_after = mx >= gx + adv * 0.5
		}
	}
	if best < 0 {return {}, false}
	g := lay.sh.glyphs[best]
	off := int(g.off)
	if best_after {
		// One rune past this glyph, inside its own span. utf8 because `off` is a
		// BYTE offset into the span's text and a multi-byte rune must not be split
		// -- a boundary inside a rune would slice the string at copy time.
		if int(g.span) < len(lay.shape) {
			s := lay.shape[g.span].text
			_, sz := utf8.decode_rune_in_string(s[min(off, len(s)):])
			off = min(off + max(1, sz), len(s))
		}
	}
	return Md_Pos{block = blk.start, span = int(g.span), off = off}, true
}

// The rendered position under a client-space point in the preview pane, or
// ok=false when the point is not in the pane at all.
//
// THE hit-test for selection, and the only place the pane's bounds are applied
// to one -- same contract, same reason, as md_preview_link_at directly below.
md_preview_pos_at :: proc(gfx: ^plat.Gfx, text: ^plat.Text, doc: ^Document, px, winw, winh, split_frac, mx, my: f32) -> (Md_Pos, bool) {
	x0, x1, ytop, ybot, ok := md_pane_box(doc, winw, winh, split_frac)
	if !ok {return {}, false}
	if my < ytop || my >= ybot || mx < x0 || mx >= x1 {return {}, false}
	pr := Md_Sel_Probe {
		x = mx,
		y = my,
	}
	md_pass(gfx, nil, text, doc, px, x0, x1, ytop, ybot, doc.md_top, nil, &pr)
	if pr.ok {return pr.pos, true}
	// Below every admitted block: clamp to the end of the last one. A drag into
	// the empty space under a short document should select to the end, which is
	// what every other text view does.
	if pr.last.lay != nil {
		return md_block_pos_at(pr.last, pr.cx, pr.last_y, pr.last_ad, 1e9, pr.last_y + pr.last_ad.h - 1)
	}
	return {}, false
}

md_preview_link_at :: proc(gfx: ^plat.Gfx, text: ^plat.Text, doc: ^Document, px, winw, winh, split_frac, mx, my: f32) -> (Md_Link_Hit, bool) {
	x0, x1, ytop, ybot, ok := md_pane_box(doc, winw, winh, split_frac)
	if !ok {return {}, false}
	if my < ytop || my >= ybot {return {}, false}
	return md_link_at(markdown_links(gfx, text, doc, px, x0, x1, ytop, ybot, doc.md_top, context.temp_allocator), mx, my)
}

// The preview's scroll fraction for this frame, or 0 when it has no pane. The
// scrollbar's one call: it takes the pane box from md_pane_box, the same
// producer the draw takes, so the thumb cannot be positioned against a pane the
// content was not laid out in.
md_preview_frac :: proc(gfx: ^plat.Gfx, text: ^plat.Text, doc: ^Document, px, winw, winh, split_frac: f32) -> f32 {
	c, ok := md_scroll_ctx(gfx, text, doc, px, winw, winh, split_frac)
	if !ok {return 0}
	return md_scroll_frac(&c, doc.md_top)
}

// The cover strip a pixel-anchored preview owes its own pane, painted over
// [0, ytop) of the pane's columns.
//
// There is no scissor rect in this renderer -- clipping is a strip painted after
// the content (see main.odin's bottom strip and Split's right-half repaint) --
// and a pixel offset means the anchor block is routinely drawn PARTIALLY above
// the pane. Under the byte anchor nothing could sit above ytop, so this is
// net-new and it is not optional: without it the top of the anchor block draws
// across the tab rail's band. Called immediately after the preview's content
// pass and before any chrome, exactly like the bottom strip.
md_preview_clip :: proc(gfx: ^plat.Gfx, qp: ^plat.Quad_Pipeline, doc: ^Document, winw, winh, split_frac: f32) {
	x0, x1, ytop, _, ok := md_pane_box(doc, winw, winh, split_frac)
	if !ok || ytop <= 0 {return}
	l := max(0, x0 - TEXT_MARGIN_X)
	plat.quads_draw(gfx, qp, []plat.Quad{{pos = {l, 0}, size = {x1 + SCROLLBAR_W - l, ytop}, color = doc_canvas_clear()}})
}

// --- the pixel scroll model (UI spec 9.1 item 4, 9.4) ------------------------
//
// Everything below moves an Md_Anchor. It is deliberately ALL in this file and
// all built on md_walk: main.odin owns the gestures (wheel, drag, keys) and this
// file owns what a pixel of preview means, so there is no second place that
// knows how tall a block is.
//
// The one rule every procedure here obeys: no walk is unbounded, and no walk is
// seeded from the document's start "to find out where we are". A position is
// resolved from the anchor outwards, over a pane's worth of blocks.

// The inputs every scroll query needs, taken ONCE from md_pane_box -- the same
// producer markdown_draw and markdown_links take their box from. A scroll query
// that measured a different pane than the draw would put the thumb somewhere the
// content is not.
Md_Scroll_Ctx :: struct {
	gfx:     ^plat.Gfx,
	text:    ^plat.Text,
	doc:     ^Document,
	m:       Md_Metrics,
	measure: f32,
	ytop:    f32,
	pane:    f32,
}

md_scroll_ctx :: proc(gfx: ^plat.Gfx, text: ^plat.Text, doc: ^Document, px, winw, winh, split_frac: f32) -> (c: Md_Scroll_Ctx, ok: bool) {
	x0, x1, ytop, ybot, box_ok := md_pane_box(doc, winw, winh, split_frac)
	if !box_ok {return}
	c = {gfx = gfx, text = text, doc = doc, m = md_metrics(text, px), ytop = ytop, pane = max(1, ybot - ytop)}
	_, c.measure = md_content_span(&c.m, x0, x1)
	return c, true
}

// `k` line starts back from `p`, bounded by the line-start scan cap. Safe only
// because its caller bounds `k`.
//
// It used to be the preview's ONLY backward motion; md_para_bounds' backward scan
// is the other one now, and md_runup_start (this proc's single caller) composes
// the two. Both are bounded -- `k` here, md_para_budget / md_para_max_lines there.
@(private = "file")
md_line_start_back :: proc(doc: ^Document, p, k: int) -> int {
	q := clamp(p, 0, doc.pt.length)
	for _ in 0 ..< k {
		if q <= 0 {break}
		s, _ := base.pt_line_start_cap(&doc.pt, q - 1, RENDER_LINE_CAP)
		if s >= q {break}
		q = s
	}
	return q
}

// A byte at or before `p` that IS a block start, and from which a forward walk
// reaches `p`.
//
// That is the invariant, and it is deliberately weaker than "the first byte of
// the block containing `p`", which this used to claim and does not deliver in two
// cases its own body describes below: inside a fence it can answer an earlier
// fence-body line, and inside a collapsed blank run it answers a line that is not
// the chunked block's start. Both are OVERSHOOTS -- a real block start, above
// `p`, costing the walk a little extra distance -- which is all a walk needs and
// all any caller here asks for.
//
// The reason it exists: any byte handed to md_walk -- and so to md_layout_ensure,
// whose cache key is `e.start != p` -- as a block start must actually BE a block
// start. Every resolver that turns a raw byte into a walk entry goes through here
// (md_runup_start below), so a walk always enters a block at its real beginning
// and a block never claims to start where it does not.
//
// This is the fix for the regression the paragraph join shipped. md_layout_build
// is reached not only from a forward block walk, where the entry byte is always a
// real block start, but from md_block_at_byte and md_anchor_walk, whose entry is
// MD_RUNUP_LINES of run-up back from an arbitrary byte. A fixed line run-up
// cannot find the start of a construct of unbounded length: on a hard-wrapped
// document the run-up lands INSIDE the paragraph, md_para_bounds hands back a
// start above it, and the block then claimed `start = p` while holding text from
// the run's true beginning. MEASURED, on md_scroll_selftest's 200-line prose
// fixture: with the editor top at byte 1200, md_anchor_from_top answered block
// 912 -- 1200 minus MD_RUNUP_LINES lines of 12 bytes, exactly -- and the preview
// pane drew from line 0 while the editor half sat at line 100.
//
// Three constructs start above their own first line. This handles two:
//
//   * a PARAGRAPH run, INCLUDING the list item or blockquote it lazily continues.
//     md_para_run produces it and nothing else does, and only when that run is
//     JOINABLE -- a capped run comes back `ok = false` and this falls through to
//     the line start. The refusal is not repeated here: it lives inside
//     md_para_run precisely so this and md_join_run cannot get out of step about
//     which runs are one block. The continuation case is why the count in the line
//     above is unchanged at three rather than four: a wrapped list item is the
//     SAME construct as a wrapped paragraph, one produced by one procedure, and
//     the only thing that changed is where its run is allowed to begin.
//   * FRONT MATTER, which is always [0, md_front_matter_end) and so contains no
//     other block start at all. MD_RUNUP_LINES is 24 and MD_FM_MAX_LINES is 64,
//     so the run-up alone could never clear a card of 25-64 lines -- a divergence
//     md_wheel_selftest measures directly (its 30- and 50-line front-matter
//     fixtures each had exactly one non-reversible up-step) and this closes.
//   * a COLLAPSED BLANK RUN is NOT handled, and that is a decision rather than an
//     oversight. Its block is chunked at MD_BLANK_RUN_MAX, so "the run's first
//     blank line" is not in general the containing block's start, and answering
//     properly means modelling the chunking. The MD_RUNUP_LINES run-up still
//     covers runs up to 24 lines, which is every run in mdtest's fixtures;
//     nothing has yet measured a longer one misbehaving. Recorded as known.
//
// THE ONE STATED EXCEPTION to "returns a block start": a `p` inside a line longer
// than RENDER_LINE_CAP. The line-start scan is capped, so there is no line start
// to return, and the early exit hands `p` itself back -- a byte that is a segment
// boundary of markdown_draw's capped walk, not a block start. It is deliberate
// and bounded, and nothing joins across it (md_para_bounds forces `capped` on
// such an entry, so md_para_run answers `ok = false`), which is what keeps the
// answer usable. mdjointest's pj_case_overlong_line drives it directly.
//
// Cheap on the common path: md_front_matter_end reads exactly one line and
// returns when the document does not open with `---`, and md_para_run's memo
// usually answers without a scan at all.
md_block_start_at :: proc(doc: ^Document, p: int) -> int {
	if doc == nil {return 0}
	q := clamp(p, 0, doc.pt.length)
	if fm_end, _ := md_front_matter_end(doc); fm_end > 0 && q < fm_end {return 0}
	ls, exact := base.pt_line_start_cap(&doc.pt, q, RENDER_LINE_CAP)
	// No line start inside the scan cap: `q` is within a line longer than
	// RENDER_LINE_CAP, which markdown_draw walks in capped segments. Hand back what
	// the caller had rather than a position that is not a line start either -- see
	// the stated exception above.
	if !exact || ls > q {return q}
	if ps, _, _, ok := md_para_run(doc, ls); ok {return ps}
	return ls
}

// The byte a walk RESOLVING `p` must start at: `k` lines of run-up for the
// collapsed gap (see MD_RUNUP_LINES), snapped back to a real block start.
//
// One producer, so the three walks that resolve a byte -- md_anchor_walk,
// md_block_at_byte and md_probe_back -- cannot enter a block at three different
// places. That was the shape of the defect: each of them derived its own entry
// and two of them derived one that was not a block start at all.
@(private = "file")
md_runup_start :: proc(doc: ^Document, p, k: int) -> int {
	return md_block_start_at(doc, md_line_start_back(doc, p, k))
}

// The starting point a forward walk needs so that laying out [s, stop_at) yields
// at least `want_h` pixels -- 9.1's "a screen above", and the only way to move a
// pixel anchor UPWARDS without a document-wide layout.
//
// It works by guessing a line count, walking forward, and doubling out if the
// guess was short. The guess grows geometrically and is capped, so a blank-heavy
// region (where a screen of height can cost thousands of source lines) simply
// stops producing more height rather than walking to the top of the file -- the
// anchor then clamps at the furthest point actually measured, and the next
// scroll step continues from there. The walk that produced the height is
// RETURNED, not thrown away, so the caller pays for one walk and the blocks land
// in the layout cache warm for the frames that follow.
@(private = "file")
md_probe_back :: proc(c: ^Md_Scroll_Ctx, at, stop_at: int, want_h: f32, out: []Md_Walk_Block) -> (n, s: int, total: f32) {
	s = clamp(at, 0, c.doc.pt.length)
	lines := MD_RUNUP_LINES
	// The snap can pin two different line counts to the SAME block start -- a
	// 100-line paragraph swallows both 24 and 96 lines of run-up -- and re-walking
	// an identical span three more times measures nothing new. Breaking keeps
	// (n, s, total) and `out` describing the walk that DID run, which is the same
	// contract the `!reached` branch below protects.
	prev_try := -1
	for _ in 0 ..< 4 {
		try := md_runup_start(c.doc, at, lines)
		if try == prev_try {break}
		prev_try = try
		tn, tt, reached := md_walk(c.gfx, c.text, c.doc, &c.m, c.measure, try, stop_at, try, max(f32), out)
		// The walk could not span [try, stop_at) inside one walk's block budget,
		// so `try` is further back than this model can represent. Keep the last
		// span that did span, which is what the caller's arithmetic assumes --
		// but THIS walk already overwrote `out` with the failed span's blocks,
		// so `out` and (n, s, total) would otherwise describe two different
		// walks. Re-walk the last good `s` to put `out` back in agreement with
		// the numbers being returned.
		if !reached {
			if n > 0 {md_walk(c.gfx, c.text, c.doc, &c.m, c.measure, s, stop_at, s, max(f32), out)}
			break
		}
		n, s, total = tn, try, tt
		if total >= want_h || try <= 0 {break}
		lines *= 4
	}
	return
}

// One wheel step, in preview pixels: the preview's OWN body line height, so a
// notch moves a line of what is on screen rather than a line of the source the
// preview no longer lays out in rows. The notch count the platform reports is
// unchanged, which keeps the feel identical at the default type scale.
md_wheel_px :: proc(c: ^Md_Scroll_Ctx) -> f32 {
	return c.m.body_lead
}

// The block containing byte `b`, and the height of its slot.
//
// Blocks tile the document ([start, next) with no gaps), so "the last block that
// starts at or before b" IS the block containing b -- which a forward walk with
// a stop_at of b+1 produces without a search.
md_block_at_byte :: proc(c: ^Md_Scroll_Ctx, b: int) -> (start, next: int, slot: f32) {
	if c.doc == nil {return}
	target := clamp(b, 0, c.doc.pt.length)
	out := make([]Md_Walk_Block, MD_WALK_BLOCKS, context.temp_allocator)
	// The run-up is what makes the slot returned here the same number md_pass
	// will use; without it the gap above the block would be its own `above`
	// rather than the document's collapsed one. md_runup_start then snaps that
	// run-up onto a real block start, which is what makes the `last.start` this
	// returns a block start too -- a walk entered mid-paragraph produces a first
	// block that begins where nothing begins, and this procedure would hand that
	// straight back as an anchor. See md_block_start_at.
	from := md_runup_start(c.doc, target, MD_RUNUP_LINES)
	n, _, _ := md_walk(c.gfx, c.text, c.doc, &c.m, c.measure, from, target + 1, from, max(f32), out)
	if n == 0 {return target, target + 1, 0}
	last := out[n - 1]
	return last.start, last.next, last.gap + last.h
}

// The cache key for one block's slot, from a context. One producer, so the key
// md_pass writes and the key md_slot_at looks up cannot drift apart.
@(private = "file")
md_slot_key_of :: proc(c: ^Md_Scroll_Ctx, block: int) -> Md_Slot_Key {
	return {
		block    = block,
		rev      = c.doc.revision,
		measure  = c.measure,
		px       = c.m.s,
		ui_scale = c.m.ui_scale,
		faces    = c.m.faces,
		valid    = true,
	}
}

// Record one block's slot on the document, for md_slot_at to find. Called by the
// pass that has just walked it -- see md_pass.
@(private = "file")
md_slot_store :: proc(c: ^Md_Scroll_Ctx, block: int, b: Md_Walk_Block) {
	c.doc.md_slot_key = md_slot_key_of(c, block)
	c.doc.md_slot_next, c.doc.md_slot_h = b.next, b.gap + b.h
}

// Walks md_slot_at had to make because nothing had already measured the block.
// Test-visible on purpose: "the scrollbar's fraction rides the draw's own walk"
// is not observable from the fraction -- a cached and an uncached answer are the
// same number -- so the only honest way to assert it is to count the walks.
md_slot_walks: int

// One block's slot height and extent. Goes through md_anchor_walk for the run-up
// (see MD_RUNUP_LINES): this number is the denominator of the scrollbar's
// fraction and the divisor of its inverse, so it has to be the one the draw uses.
//
// Reads the cache md_pass fills, which is what makes "the one the draw uses"
// literal rather than "computed the same way the draw computes it". On a hit
// this costs a struct compare; on a miss it is the walk it always was.
@(private = "file")
md_slot_at :: proc(c: ^Md_Scroll_Ctx, start: int) -> (next: int, slot: f32) {
	if c.doc == nil {return start + 1, 0}
	if key := md_slot_key_of(c, start); c.doc.md_slot_key == key {
		return c.doc.md_slot_next, c.doc.md_slot_h
	}
	md_slot_walks += 1
	out := make([]Md_Walk_Block, MD_WALK_BLOCKS, context.temp_allocator)
	n, idx := md_anchor_walk(c, start, 1, out)
	if n == 0 {return start + 1, 0}
	md_slot_store(c, start, out[idx])
	return out[idx].next, out[idx].gap + out[idx].h
}

// The scroll position as ONE monotone scalar: bytes, with the fraction of the
// anchor block that is scrolled past.
//
// This is what the scrollbar maps and what its drag inverts, and the two are
// EXACT inverses by construction -- md_scroll_to_fraction rebuilds an anchor
// whose scalar is the number it was given, so grabbing the thumb and holding
// still moves nothing. (That property is vscrollbar_geo's, hard won; see its
// comment. The fraction is here rather than plain bytes for the same reason
// vscrollbar_geo divides by doc_max_top and not pt.length: without it the thumb
// reads 1.0 while a block of travel is still left.)
md_scroll_scalar :: proc(c: ^Md_Scroll_Ctx, a: Md_Anchor) -> f32 {
	next, slot := md_slot_at(c, a.block)
	f := clamp(a.px / max(1, slot), 0, 1)
	return f32(a.block) + f * f32(max(1, next - a.block))
}

// The last anchor with content still to show: the position at which the document
// ends exactly at the pane's bottom edge. The preview's own doc_max_top.
//
// This is the fix for the measured defect 2b recorded: the preview covers about
// three times as much SOURCE per screen as the editor does (a blank run is one
// zero-height block), so the editor's doc_max_top let the preview scroll a long
// way past its own last block and show nothing new. Its ceiling is its own now.
//
// Computed from the document's END, backwards -- one pane of layout, never the
// document -- and cached on the key every term of it depends on, so scrolling
// (which moves none of them) costs nothing after the first frame.
md_max_anchor :: proc(c: ^Md_Scroll_Ctx) -> Md_Anchor {
	doc := c.doc
	if doc == nil || doc.pt.length <= 0 {return {}}
	key := Md_Max_Key {
		rev      = doc.revision,
		measure  = c.measure,
		px       = c.m.s,
		ui_scale = c.m.ui_scale,
		pane     = c.pane,
		faces    = c.m.faces,
		valid    = true,
	}
	if doc.md_max_key == key {return doc.md_max}
	out := make([]Md_Walk_Block, MD_WALK_BLOCKS, context.temp_allocator)
	n, s, total := md_probe_back(c, doc.pt.length, max(int), c.pane, out)
	a := Md_Anchor{s, 0}
	if rel := total - c.pane; rel > 0 && n > 0 {
		// Same rule as md_scroll_px's upward branch: the walk's first block has no
		// predecessor here, so it is only a legitimate anchor when it is the
		// document's own first block.
		lo := 0 if s <= 0 else min(1, n - 1)
		a = md_at_offset(out[:n], lo, max(rel, out[lo].slot_top))
	}
	// The fraction's denominator, computed here because this is where the key is
	// written and because it is a function of exactly the same terms. Costs one
	// md_slot_at on a miss -- a resize, a zoom, a monitor change or an edit -- and
	// nothing on the scroll frames in between, which is the case that matters.
	doc.md_max, doc.md_max_key = a, key
	doc.md_max_scalar = md_scroll_scalar(c, a)
	return a
}

// Is `a` at or past `b` in scroll order? Byte first, pixels inside a block --
// the same order md_scroll_scalar is monotone in, without its walk.
@(private = "file")
md_anchor_ge :: #force_inline proc(a, b: Md_Anchor) -> bool {
	return a.block > b.block || (a.block == b.block && a.px >= b.px)
}

// Clamp an anchor into [{0,0}, md_max_anchor]. Every producer of an anchor ends
// here, so "you cannot scroll past the end" is one expression and not five.
md_scroll_clamp :: proc(c: ^Md_Scroll_Ctx, a: Md_Anchor) -> Md_Anchor {
	mx := md_max_anchor(c)
	if md_anchor_ge(a, mx) {return mx}
	if a.block <= 0 && a.px <= 0 {return {}}
	return a
}

// Move the preview by `dy` PIXELS. Positive is down. 9.1 item 4, as a gesture.
md_scroll_px :: proc(c: ^Md_Scroll_Ctx, a: Md_Anchor, dy: f32) -> Md_Anchor {
	if c.doc == nil || dy == 0 {return a}
	out := make([]Md_Walk_Block, MD_WALK_BLOCKS, context.temp_allocator)
	res := a
	if dy > 0 {
		// One pane past the target, so the blocks the next frame draws are laid
		// out here and the frame after it is a cache hit -- 9.1's "a screen
		// below", on the gesture that needs it.
		n, idx := md_anchor_walk(c, a.block, a.px + dy + c.pane, out)
		if n == 0 {return a}
		target := out[idx].slot_top + a.px + dy
		// A step larger than the walk could span lands at the furthest position
		// the walk actually MEASURED, and the next step continues from there --
		// md_probe_back's header states the same rule for the other direction. The
		// height limit above normally makes this a no-op (the walk is asked for the
		// step plus a pane, so the target is inside it); what it bounds is the walk
		// truncating on its block budget or on MD_MAX_EMPTY_BLOCKS instead, where
		// the offset past the last slot names a distance over blocks nothing has
		// laid out. Without it md_at_offset's past-the-walk case below would carry
		// that unmeasured distance into `px`.
		last := out[n - 1]
		res = md_at_offset(out[:n], idx, min(target, last.slot_top + last.gap + last.h))
	} else {
		// 9.1's "a screen above": ask the probe for the step PLUS a pane, so the
		// blocks above the new position are warm rather than rebuilt next frame.
		n, s, total := md_probe_back(c, a.block, a.block, -dy + c.pane, out)
		target := total + a.px + dy
		if n == 0 {
			// The probe could not move: md_line_start_back(doc, p, k) returns `p`
			// only for p == 0, so n == 0 IS "the anchor is in the document's first
			// block", and `target` is then simply a.px + dy measured from byte 0.
			// This used to return {s, 0} and DISCARD the target, which teleported
			// every up-step taken inside block 0 to the top of the document --
			// reachable on any file whose first block is taller than one wheel
			// notch, which is any heading, any fence, any front-matter card and any
			// wrapping paragraph. The clamp at 0 is the top of the document; the
			// clamp at the other end is md_scroll_clamp's, as everywhere else.
			res = {s, max(0, target)}
		} else {
			// Never resolve onto the walk's FIRST block unless it is the document's
			// -- that one has no predecessor here, so its gap is its own `above`
			// and not the document's collapsed one (MD_RUNUP_LINES). Clamping to
			// the second block instead costs one block of travel on a jump larger
			// than the probe could reach; the next step continues from there.
			lo := 0 if s <= 0 else min(1, n - 1)
			res = md_at_offset(out[:n], lo, max(target, out[lo].slot_top))
		}
	}
	return md_scroll_clamp(c, res)
}

// The anchor naming the position `target` in a walk's own space, searched from
// `lo` forward. One place resolves an offset to an anchor, so the invariant
// px in [0, gap + h) holds however the offset was arrived at.
//
// A target past everything the walk measured names a position in the block
// AFTER the last one -- which is what `next` is, and which on the UPWARD path is
// the anchor block itself, since md_probe_back's walk deliberately stops at it
// (stop_at == a.block). So a step smaller than the anchor's own offset has no
// entry in the walk to land in, and that is the common case, not an edge: it is
// every up-step of less than px.
//
// This used to clamp the offset into the last entry's slot instead, which
// emitted px == gap + h: the next block's {start, 0} written in the previous
// block's coordinates. That is the same PLACE on screen, so it looked harmless,
// and it is not -- it breaks the [0, gap + h) invariant this procedure's header
// claims to be the one guarantor of, it loses the sub-block remainder (a notch
// up from px = 32 returned the previous block's last pixel rather than px = 2),
// and md_scroll_scalar's `px / slot` then reads 1.0, putting the scrollbar thumb
// a whole block ahead of the content.
@(private = "file")
md_at_offset :: proc(w: []Md_Walk_Block, lo: int, target: f32) -> Md_Anchor {
	for i in lo ..< len(w) {
		b := w[i]
		if target < b.slot_top + b.gap + b.h {
			return {b.start, max(0, target - b.slot_top)}
		}
		if i == len(w) - 1 {
			return {b.next, max(0, target - (b.slot_top + b.gap + b.h))}
		}
	}
	if lo < len(w) {return {w[lo].start, 0}}
	return {}
}

// The scroll position as a fraction of the scrollable range, for the scrollbar.
// 0 at the top, exactly 1 at md_max_anchor -- so the thumb's BOTTOM meets the
// track's bottom when the document's last block does the pane's, which is the
// property vscrollbar_geo's comment exists to protect.
// The denominator comes from md_max_anchor's cache and not from a second
// md_scroll_scalar. This used to call md_scroll_scalar TWICE, each one an
// md_slot_at -> md_anchor_walk with a 24-line run-up and a 256-entry
// Md_Walk_Block array, from inside render_frame, over blocks markdown_draw had
// laid out three lines earlier -- 3.322 ms a frame against the draw's 1.660.
// Both halves are now lookups: the denominator on Md_Max_Key (a scroll moves no
// term of it) and the numerator on the slot md_pass published.
md_scroll_frac :: proc(c: ^Md_Scroll_Ctx, a: Md_Anchor) -> f32 {
	if c.doc == nil {return 0}
	md_max_anchor(c) // ensures md_max_scalar holds this key's denominator
	den := c.doc.md_max_scalar
	if den <= 0 {return 0}
	return clamp(md_scroll_scalar(c, a) / den, 0, 1)
}

// The inverse of md_scroll_frac, for a scrollbar drag. Exact: the anchor this
// returns has the scalar it was asked for (see md_scroll_scalar).
md_scroll_to_fraction :: proc(c: ^Md_Scroll_Ctx, frac: f32) -> Md_Anchor {
	if c.doc == nil {return {}}
	// md_max_anchor's cached scalar, the same field md_scroll_frac divides by --
	// so the map and its inverse multiply and divide by literally one number
	// rather than by two walks that have to agree. (It also takes the drag off
	// the walk: a held thumb asks for this every frame.)
	md_max_anchor(c)
	t := clamp(frac, 0, 1) * c.doc.md_max_scalar
	start, next, slot := md_block_at_byte(c, int(t))
	px := (t - f32(start)) / f32(max(1, next - start)) * slot
	return md_scroll_clamp(c, {start, clamp(px, 0, slot)})
}

// 9.4, "scroll sync by block, not by line": the preview position that
// corresponds to the editor's top line. The editor stays byte-anchored and the
// preview is pixel-anchored, so the sync is a MAPPING -- this is the map, and
// md_anchor_top_byte below is its inverse.
md_anchor_from_top :: proc(c: ^Md_Scroll_Ctx, top: int) -> Md_Anchor {
	start, _, _ := md_block_at_byte(c, top)
	return md_scroll_clamp(c, {start, 0})
}

// The other direction of 9.4's sync: the source line the editor should put at
// its top when the preview is at `a`. A block start is a line start, so this is
// the block's own byte -- the mapping is by BLOCK, which is the point: mapping
// by line drifts the moment a heading or a fence changes height.
md_anchor_top_byte :: proc(c: ^Md_Scroll_Ctx, a: Md_Anchor) -> int {
	if c.doc == nil {return 0}
	return base.pt_line_start(&c.doc.pt, clamp(a.block, 0, c.doc.pt.length))
}

// 9.1's one surviving pixel -> content mapping: "click-to-sync-scroll, which
// only needs the nearest BLOCK, not the nearest glyph. Store each block's y
// range and binary-search it."
//
// The y ranges are the walk's, so they are the ranges the draw used; the search
// is a binary one over them because they are sorted by construction. Returns the
// start byte of the block under `y`, and false when the pane holds nothing.
md_block_at_y :: proc(c: ^Md_Scroll_Ctx, a: Md_Anchor, y: f32) -> (start: int, ok: bool) {
	if c.doc == nil {return}
	// Outside the pane: refused here rather than left to the clamp below, which
	// otherwise answers for a y meant for the status bar or the find bar just as
	// readily as it does for an actual block.
	//
	// This is the ONLY copy of that predicate now. md_split_click_gate carried a
	// second one and no longer does (see its comment): it called nothing but this
	// procedure, so its copy could never refuse a press this one would accept.
	// MEASURED, so the division of labour is on the record rather than assumed:
	// of the three "gate:" cases that read as pane-bound checks, only the FIND BAR
	// is actually refused by this line. The status bar and the empty strip below
	// the last drawn block are both inside or below the pane's rows and are
	// refused by the PLACEMENT further down instead (2026-07-29 review, F5:
	// there is no "fit test" left to refuse them -- md_place_next's admit
	// decision does, via the `rel >= last.blk...admit.h` bound just past the
	// binary search below; its twin in main.odin, md_split_click_gate, already
	// says it this way). Deleting this line therefore costs exactly one case --
	// which is one more than zero, which is why it stays here while the
	// duplicate went.
	if y < c.ytop || y >= c.ytop + c.pane {return}
	out := make([]Md_Walk_Block, MD_WALK_BLOCKS, context.temp_allocator)
	n, idx := md_anchor_walk(c, a.block, a.px + c.pane, out)
	if n == 0 {return}
	// The blocks the pane PUT ON SCREEN come from md_place_next, the same
	// procedure md_pass paints from -- not from a fit test written out again here.
	// md_anchor_walk's budget is a HEIGHT limit, not "did this block fit inside
	// ybot", so a block that straddles the pane's bottom edge is walked (and
	// cached) but only partly painted; without consulting the placement, a click
	// in the strip below the last PAINTED line clamps onto lines that were never
	// drawn -- the same "clamps to whatever the binary search's last entry is"
	// shape the pane bound above exists to close off, just for a y still inside
	// the pane.
	//
	// This used to be a hand-written mirror of md_pass's loop, and its own comment
	// said so. Under per-line admission a mirror is not survivable: the two copies
	// would have to agree about how many LINES of the last block were painted, not
	// just about one height. See md_place_next.
	y0 := c.ytop - a.px - out[idx].slot_top
	pl := md_placer(out, idx, n, y0, c.ytop, c.ytop + c.pane)
	last: Md_Placed
	cnt := 0
	// The last placed block's index in `out`, for the binary search below: the
	// placer walks `out` in order from `idx`, so this is idx + cnt - 1.
	for {
		p, ok := md_place_next(&pl)
		if !ok {break}
		last = p
		cnt += 1
	}
	if cnt == 0 {return}
	rel := (y - c.ytop) + a.px + out[idx].slot_top // into the walk's own space
	// `admit.h`, not `blk.h`: the last block on screen may be a partial one, and
	// the rows below its admitted lines hold nothing to click.
	if rel >= last.blk.slot_top + last.blk.gap + last.admit.h {return}
	lo, hi := idx, idx + cnt - 1
	for lo < hi {
		mid := (lo + hi + 1) / 2
		if out[mid].slot_top <= rel {lo = mid} else {hi = mid - 1}
	}
	return out[lo].start, true
}

// Collect one block's link rectangles, gated exactly as the editor pane's are:
// underlined implies openable. The colour a link's TEXT draws in is not gated
// -- a markdown link is a link in the document whether or not the target
// resolves -- but the affordance and the click are, which is the invariant
// links.odin's header states.
// Where a block's GLYPHS start, horizontally. The single producer: the draw
// places the shaped run at this x and the link rects are offset from this x, so
// the underline, the hit-test and the ink are the same geometry by
// construction rather than by two call sites agreeing.
@(private = "file")
md_block_origin :: #force_inline proc(lay: ^Md_Layout, cx: f32) -> f32 {return cx + lay.indent}

@(private = "file")
md_block_links :: proc(doc: ^Document, lay: ^Md_Layout, cx, ytop: f32, ad: Md_Admit, out: ^[dynamic]Md_Link_Hit) {
	x := md_block_origin(lay, cx)
	for b in lay.boxes {
		// A line the pane did not admit has no glyphs on screen, so it has no link
		// either. Same `ad.lines` the draw filters its glyphs by, out of the same
		// Md_Admit -- so an unpainted line cannot be clickable.
		if b.line >= ad.lines {continue}
		if b.span < 0 || b.span >= len(lay.spans) {continue}
		sp := lay.spans[b.span]
		if .Link not_in sp.style || len(sp.url) == 0 {continue}
		l, lok := link_whole(sp.url)
		if !lok || !link_gate_visible(doc, sp.url, l) {continue}
		append(out, Md_Link_Hit {
			rect   = {pos = {x + b.x, ytop + b.y}, size = {b.w, b.h}},
			base_y = ytop + b.baseline,
			url    = sp.url,
			text   = sp.url,
			link   = l,
		})
	}
}

// Paint one laid-out block at (cx, ytop), as much of it as `ad` admitted.
// Consumes the layout and produces no geometry of its own beyond the decorations
// that are not text: every glyph position comes from lay.sh, every span
// rectangle from lay.boxes.
//
// `ad` is md_block_admit's answer, handed down rather than recomputed here. Its
// two consequences: `ad.h` is the height every FULL-WIDTH band this block paints
// (a fence body's background, a quote's bars) must use, since the band may not
// run past the last admitted line; and `ad.lines` is the line cutoff for the
// glyphs and for every rectangle in lay.boxes. A band drawn to lay.h under a
// partial admit is exactly the overhang the admit test exists to prevent.
@(private = "file")
md_block_draw :: proc(gfx: ^plat.Gfx, qp: ^plat.Quad_Pipeline, text: ^plat.Text, doc: ^Document, m: ^Md_Metrics, lay: ^Md_Layout, cx, x1, ytop: f32, ad: Md_Admit, blk_start := -1, trow := -1) {
	x := md_block_origin(lay, cx)
	// The selection, UNDER everything this block draws (UI spec §9.4: "Selection
	// uses selection_doc"). First so the glyphs, the rules and the quote bars all
	// read on top of it, the same ordering the current-line tint uses in the
	// editor and for the same reason.
	//
	// ONE QUAD PER VISUAL LINE, not per glyph -- §8's "Selection is a run of
	// rects, not per-glyph. One instance per visual line, so only visible lines
	// cost anything." The run is [first selected glyph's left, last selected
	// glyph's right] on each line, which for a full line is the whole line.
	// The zebra band goes UNDER the selection, which goes under everything else:
	// a selected cell has to read as selected, and at 1.05:1 against Bg_Base the
	// band would otherwise wash out the highlight sitting on it. Same layering
	// argument the editor's current-line tint makes for going first.
	//
	// ad.h, not lay.h -- a row whose second wrapped line the pane refused must not
	// have its band painted below the glyphs that were admitted, the same bound
	// the fence body's background and the quote bar take.
	if qp != nil && md_zebra_row(trow) && ad.h > 0 {
		w := min(md_table_extent(lay.tcols), x1 - x)
		if w > 0 {
			plat.quads_draw(gfx, qp, []plat.Quad{{pos = {x, ytop}, size = {w, ad.h}, color = g_theme[.Table_Zebra]}})
		}
	}
	if qp != nil && blk_start >= 0 {
		md_draw_selection(gfx, qp, doc, lay, cx, ytop, ad, blk_start)
	}
	// PAIRING GUARD (2026-07-29 review, F4). The kinds that `return` inside the
	// switch below must be EXACTLY the kinds md_kind_lines calls indivisible, and
	// the kinds that fall through to shaped_draw (below the switch) must be
	// exactly the ones it calls divisible -- two hand-written expressions of the
	// same fact, and until now nothing checked they agreed. `reached_shaped` is
	// set true at the one place shaped_draw is actually called; the deferred
	// check fires for EVERY block this proc ever draws, so a kind added to one
	// side without the other panics the first time that kind is painted, rather
	// than silently reducing `shaped_draw`'s `lines` to 1 and dropping every
	// visual line but the first (see F4: the very next task shapes table cells,
	// which turns `.Table` from an early return into a fall-through, and this is
	// what stops `.Table` landing on only one side of the pairing).
	reached_shaped := false
	defer if reached_shaped != md_kind_lines(lay.cls.kind) {
		fmt.panicf(
			"md_block_draw: kind %v reaches shaped_draw=%v but md_kind_lines says divisible=%v -- add/remove it on BOTH sides (see F4)",
			lay.cls.kind, reached_shaped, md_kind_lines(lay.cls.kind),
		)
	}
	// The kinds that return inside this switch are the ones md_kind_lines calls
	// indivisible, so md_block_lines is 1 for them, so an admitted one is always
	// `whole` and ad.h == lay.h. They keep reading lay.h: it says "the block's own
	// height", which for them is the truth, and swapping in ad.h would only
	// obscure that they cannot be partial.
	switch lay.cls.kind {
	case .Blank:
		return
	case .Front_Matter:
		md_draw_front_matter(gfx, qp, text, doc, cx, x1, ytop, m.code, plat.text_char_width(text, m.code, .Doc), line_height(m.code), lay.end, lay.fm_inner)
		return
	case .Rule:
		plat.quads_draw(gfx, qp, []plat.Quad{{pos = {cx, ytop}, size = {x1 - cx, lay.h}, color = g_theme[.Md_Rule]}})
		return
	case .Fence_Open:
		r := m.fence_radius
		plat.quads_draw(gfx, qp, []plat.Quad{{pos = {cx, ytop}, size = {x1 - cx, lay.h}, color = g_theme[.Md_Code_Bg], radius = {r, r, 0, 0}}})
		return
	case .Fence_Close:
		r := m.fence_radius
		plat.quads_draw(gfx, qp, []plat.Quad{{pos = {cx, ytop}, size = {x1 - cx, lay.h}, color = g_theme[.Md_Code_Bg], radius = {0, 0, r, r}}})
		return
	case .Table:
		// Decoration only. The CELLS fall through to shaped_draw below, from
		// lay.sh -- there is no table-specific text path left, which is what made
		// links in cells work again and what removed the second producer of cell
		// geometry that md_col_x / md_draw_table_row were.
		//
		// Both quads below read lay.tcols, the geometry the layout fitted and the
		// shaper placed the glyphs against, and ad.h, the height the pane actually
		// admitted -- a rule or a column rule painted to lay.h under a partial
		// admit is the overhang the admit test exists to prevent (same reason as
		// Fence_Body's band).
		// §9.4's CARD: a 1px Md_Rule border at radius 6 around the whole table,
		// with the header row on Bg_Raised. Built per row, because a table arrives
		// as one block per row -- left and right edges on every row, the top edge
		// and its corners only on the first, the bottom only on the last.
		//
		// ad.h, never lay.h, for every quad here. A partially admitted last row
		// must not paint a bottom edge below the glyphs the pane accepted, which is
		// the same overhang rule Fence_Body's band follows -- and on a card it is
		// worse than an overhang, because a bottom edge drawn mid-table says "the
		// table ends here" about a table that does not.
		{
			tw := min(md_table_extent(lay.tcols), x1 - x)
			if tw > 0 {
				edge := hairline()
				r := m.fence_radius
				rule := g_theme[.Md_Rule]
				// The header is the row ABOVE the separator, which is the first row
				// of any well-formed table -- and `tbl_first` is how the card knows
				// its top anyway, so the fill needs no separate notion of "header".
				if lay.cls.tbl_first {
					plat.quads_draw(gfx, qp, []plat.Quad{{pos = {x, ytop}, size = {tw, ad.h}, color = g_theme[.Bg_Raised], radius = {r, r, 0, 0}}})
				}
				// Side edges, every row.
				plat.quads_draw(
					gfx,
					qp,
					[]plat.Quad {
						{pos = {x, ytop}, size = {edge, ad.h}, color = rule},
						{pos = {x + tw - edge, ytop}, size = {edge, ad.h}, color = rule},
					},
				)
				if lay.cls.tbl_first {
					plat.quads_draw(gfx, qp, []plat.Quad{{pos = {x, ytop}, size = {tw, edge}, color = rule, radius = {r, r, 0, 0}}})
				}
				if lay.cls.tbl_last {
					plat.quads_draw(gfx, qp, []plat.Quad{{pos = {x, ytop + ad.h - edge}, size = {tw, edge}, color = rule, radius = {0, 0, r, r}}})
				}
			}
		}
		if lay.cls.is_sep {
			// NOTHING. The separator used to draw its own md_rule, centred in a
			// full-height row -- which was right when the table had no card around
			// it. §9.4 draws the header on bg_raised with the body plain beneath and
			// NO line between them: the band's colour change is the boundary, and a
			// rule on top of it is a second answer to the same question.
			//
			// The row is a hairline tall now (see md_layout_build), so there is also
			// nowhere left to centre anything in.
		} else {
			// One rule per column boundary, down the middle of the gutter between
			// two fitted columns, spanning the row's admitted height. A quad and not
			// the "│" glyph the old row draw used: a glyph covers one line, and a row
			// is now as many lines as its tallest wrapped cell.
			for i in 1 ..< len(lay.tcols) {
				prev, cur := lay.tcols[i - 1], lay.tcols[i]
				mid := x + (prev.x + prev.w + cur.x) * 0.5
				if mid >= x1 {break}
				plat.quads_draw(gfx, qp, []plat.Quad{{pos = {mid, ytop}, size = {hairline(), ad.h}, color = g_theme[.Md_Rule]}})
			}
		}
	case .Fence_Body:
		// ad.h, not lay.h: a wrapped code line whose second half the pane refused
		// must not have its background band painted below the glyphs that were.
		plat.quads_draw(gfx, qp, []plat.Quad{{pos = {cx, ytop}, size = {x1 - cx, ad.h}, color = g_theme[.Md_Code_Bg]}})
	case .Quote:
		// One bar per nesting level (9.2 item 7: "2px bar + 16px inset per
		// level"), so a reply inside a reply is visibly deeper. The step comes
		// out of the block's own indent rather than from m.quote_inset again --
		// the layout set indent = level * quote_inset, so dividing it back is the
		// same number by construction and cannot drift from it (L2).
		step := lay.indent / f32(max(1, lay.cls.level))
		for d in 0 ..< lay.cls.level {
			// ad.h for the same reason the fence body's band uses it: the bar runs
			// beside the quote's admitted lines, not past them.
			plat.quads_draw(gfx, qp, []plat.Quad{{pos = {cx + f32(d) * step, ytop}, size = {max(sx(2), 2), ad.h}, color = g_theme[.Md_Quote]}})
		}
	case .List:
		lx := cx + lay.marker // md_layout_build's own number, not a second copy
		if lay.cls.task {
			// A real box, not literal brackets, and the TICK carries the state as
			// well as the tone -- never colour alone (UI spec 18).
			bs := m.task_box
			asc, _, _ := plat.text_vmetrics(text, m.body, .Body)
			by := ytop + max(0, asc - bs)
			edge := hairline()
			bq: [4 + MD_TICK_STEPS * 2]plat.Quad
			nq := 0
			if lay.cls.task_done {
				// FILLED, with the tick knocked out in the page colour -- §9.4's mockup
				// is `bg=#d99b62 fg=#221f1c r=3px`. A done item should read as done from
				// across the pane; an outline reads as a control nobody has touched.
				r := edge * 3
				bq[0] = {pos = {lx, by}, size = {bs, bs}, color = g_theme[.Accent], radius = {r, r, r, r}}
				nq = 1 + md_tick_quads(lx, by, bs, g_theme[.Bg_Base], bq[1:])
			} else {
				bc := g_theme[.Text_Muted]
				bq[0] = {pos = {lx, by}, size = {bs, edge}, color = bc}
				bq[1] = {pos = {lx, by + bs - edge}, size = {bs, edge}, color = bc}
				bq[2] = {pos = {lx, by}, size = {edge, bs}, color = bc}
				bq[3] = {pos = {lx + bs - edge, by}, size = {edge, bs}, color = bc}
				nq = 4
			}
			plat.quads_draw(gfx, qp, bq[:nq])
		} else if len(lay.cls.bullet) > 0 {
			asc, _, _ := plat.text_vmetrics(text, m.body, .Body)
			plat.text_draw(gfx, text, lay.cls.bullet, lx, ytop + asc, m.body, g_theme[.Accent], .Body)
		}
	case .Heading:
	case .Para:
	}

	// --- span decorations, then the glyphs -----------------------------------
	//
	// Every rectangle below comes from lay.boxes, which md_span_boxes produced
	// from the shaper's own glyph positions. The inline-code background, the
	// strike rule and the link underline are therefore the SAME geometry the
	// link hit-test accepts; there is no second derivation anywhere.
	//
	// `b.line >= ad.lines` is the line cutoff. It is applied to every box loop
	// here, to the glyphs through shaped_draw's own `lines` argument, and to the
	// link rects in md_block_links -- all off the one `ad.lines`, so a refused line
	// has neither ink nor decoration nor a hit rectangle.
	for b in lay.boxes {
		if b.line >= ad.lines {continue}
		if b.span < 0 || b.span >= len(lay.spans) {continue}
		sp := lay.spans[b.span]
		bx, by := x + b.x, ytop + b.y
		if .Code in sp.style && .Link not_in sp.style {
			r := m.code_radius
			pad := max(1, m.code_radius * 0.5)
			plat.quads_draw(gfx, qp, []plat.Quad{{pos = {bx - pad, by}, size = {b.w + pad * 2, b.h}, color = g_theme[.Md_Code_Bg], radius = {r, r, r, r}}})
		}
	}
	colors := make([][4]f32, len(lay.spans), context.temp_allocator)
	for s, i in lay.spans {colors[i] = s.color}
	reached_shaped = true // the pairing guard's flag -- see the defer above
	plat.shaped_draw(gfx, text, &lay.sh, lay.shape, x, ytop, g_theme[.Text_Primary], colors, ad.lines)
	// Synthetic emphasis, only where a real face is missing. With Georgia loaded
	// this never runs; on a machine whose body family ships no bold it is what
	// keeps a heading from rendering at weight 400. The second pass draws ONLY
	// the emphasised spans -- shaped_draw skips a glyph whose colour is fully
	// transparent -- so it cannot embolden the prose around them.
	if !plat.text_has_style(text, .Body, .Bold) {
		any := false
		for s, i in lay.spans {
			if .Bold in s.style && .Code not_in s.style {
				colors[i] = s.color
				any = true
			} else {
				colors[i] = {0, 0, 0, 0}
			}
		}
		if any {plat.shaped_draw(gfx, text, &lay.sh, lay.shape, x + hairline(), ytop, g_theme[.Text_Primary], colors, ad.lines)}
	}
	for b in lay.boxes {
		if b.line >= ad.lines {continue}
		if b.span < 0 || b.span >= len(lay.spans) {continue}
		sp := lay.spans[b.span]
		if .Strike not_in sp.style {continue}
		// At the x-height centre per UI spec 9.2 -- through the middle of the
		// lowercase, not through the baseline, or it reads as a slipped
		// underline.
		plat.quads_draw(gfx, qp, []plat.Quad{{pos = {x + b.x, ytop + b.baseline - lay.shape[b.span].px * 0.28}, size = {b.w, hairline()}, color = sp.color}})
	}
	// h1 and h2 carry a rule (9.2 item 1), on the LAST row of the block's own
	// height -- md_layout_build already made room for it, so this consumes that
	// height rather than reaching past it.
	//
	// `ad.whole` gates it, and md_line_bottom is why that is the right gate: the
	// last line's admitted bottom IS lay.h, so a heading whose rule the pane cannot
	// hold is not `whole` and the rule is not painted. A wrapped h2 with three of
	// four lines on screen would otherwise get its rule under line three.
	if ad.whole && lay.cls.kind == .Heading && md_head_rules(lay.cls.level) {
		plat.quads_draw(gfx, qp, []plat.Quad{{pos = {cx, ytop + lay.h - hairline()}, size = {x1 - cx, hairline()}, color = g_theme[.Md_Rule]}})
	}
}


@(private = "file")
md_heading_level :: proc(s: string) -> int {
	n := 0
	for n < len(s) && s[n] == '#' {n += 1}
	if n >= 1 && n <= 6 && n < len(s) && s[n] == ' ' {return n}
	return 0
}

@(private = "file")
md_is_rule :: proc(s: string) -> bool {
	t := strings.trim_space(s)
	if len(t) < 3 {return false}
	c := t[0]
	if c != '-' && c != '*' && c != '_' {return false}
	for i in 0 ..< len(t) {
		if t[i] != c && t[i] != ' ' {return false}
	}
	return true
}

@(private = "file")
md_quote :: proc(s: string) -> (bool, string) {
	q, c, _ := md_quote_depth(s)
	return q, c
}

// A blockquote, with its NESTING DEPTH. `>> a` is a quote inside a quote and
// used to render exactly like `> a` -- md_quote stripped one marker and returned
// the rest verbatim, so the second ">" became part of the text. UI spec 9.2
// lists "blockquote, nested" as one item for that reason.
md_quote_depth :: proc(s: string) -> (is_quote: bool, content: string, depth: int) {
	rest := s
	for {
		t := strings.trim_left(rest, " ")
		if !strings.has_prefix(t, ">") {break}
		rest = t[1:]
		depth += 1
	}
	if depth == 0 {return false, "", 0}
	return true, strings.trim_left(rest, " "), depth
}

// A list item: returns the bullet to draw ("•" or "1."), the content, and the
// nesting depth from the leading indent.
@(private = "file")
md_list :: proc(line: string) -> (bullet, content: string, depth: int) {
	i := 0
	for i < len(line) && (line[i] == ' ' || line[i] == '\t') {
		depth += 2 if line[i] == '\t' else 1
		i += 1
	}
	depth /= 2
	rest := line[i:]
	if len(rest) >= 2 && (rest[0] == '-' || rest[0] == '*' || rest[0] == '+') && rest[1] == ' ' {
		return "•", strings.trim_left(rest[2:], " "), depth
	}
	// ordered: digits then '.' or ')'
	j := 0
	for j < len(rest) && rest[j] >= '0' && rest[j] <= '9' {j += 1}
	// A SLICE of `line`, not a clone: the block layout cache holds an owned copy
	// of the source line and every field of Md_Class points into it, so a marker
	// cloned into the frame arena here would dangle the moment the cache outlived
	// the frame that built it.
	if j > 0 && j + 1 < len(rest) && (rest[j] == '.' || rest[j] == ')') && rest[j + 1] == ' ' {
		return rest[:j + 1], strings.trim_left(rest[j + 2:], " "), depth
	}
	return "", "", 0
}

@(private = "file")
md_is_table_sep :: proc(s: string) -> bool {
	for i in 0 ..< len(s) {
		switch s[i] {
		case '|', '-', ':', ' ', '\t':
		case:
			return false
		}
	}
	return strings.contains(s, "-")
}

// Single source for "is this row a separator": the measure and the draw used to
// each trim their own copy of the line before checking, which agreed only
// incidentally. Both now call this on the same untrimmed line.
@(private = "file")
md_row_is_sep :: proc(line: string) -> bool {
	return md_is_table_sep(strings.trim_left(line, " \t"))
}

// md_draw_table_row and md_col_x are GONE (2026-07-29). They were the second
// producer of table cell geometry -- a row's glyphs placed from character cells at
// the draw site, while the widths those cells came from were computed in
// md_table_measure -- and that is precisely why a link inside a table cell could
// not be given a rectangle. A table row's cells now go through the shaper
// (plat.shape_columns, from md_layout_build's .Table case), so the glyph positions,
// the wrap points, the column rules and the link rects all come out of one place.
// The only thing this removal loses is the "│" glyph, replaced by a quad that can
// span a wrapped row's full height.
