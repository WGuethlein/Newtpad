// Layer: program — dispatch from a document's file extension to a base-layer
// lexer, and the map from a lexer's Token_Kind to this layer's Color_Role.
//
// Both tables are DATA — an extension list, an indexed switch that is really
// just a lookup table — never a decision tree that grows a branch per lexer.
// See CLAUDE.md's "commands declared once" rule for [Command_Id]Command; the
// same shape applies here, just without the #assert-on-length machinery
// (there is no fixed "one entry per lexer" invariant to violate the way
// there is for commands).
//
// base must never import this file, or anything above base — lex.odin's
// header comment carries the actual rule; this file is where the mapping
// that rule exists to protect actually lives.
package main

import "core:strings"
import base "src:base"
import plat "src:platform"

// Every lexer in the table speaks this shape: a line's raw bytes plus the
// Lex_State the previous line ended in, producing tokens plus the state THIS
// line ends in. Task 3 added the state parameter/result — lex_log and
// lex_json (line-local, Task 1/2) never look at state_in and always return
// .Normal, via the two adapters below, so neither file was rewritten to grow
// a state it doesn't have. lex_xml (base/lex_xml.odin) is the first real
// consumer: its signature already matches this exactly, so it needs no
// adapter of its own.
Lexer_Proc :: proc(line: []u8, state_in: base.Lex_State, out: []base.Token) -> (n: int, state_out: base.Lex_State)

@(private = "file")
lex_log_adapt :: proc(line: []u8, state_in: base.Lex_State, out: []base.Token) -> (n: int, state_out: base.Lex_State) {
	return base.lex_log(line, out), .Normal
}

@(private = "file")
lex_json_adapt :: proc(line: []u8, state_in: base.Lex_State, out: []base.Token) -> (n: int, state_out: base.Lex_State) {
	return base.lex_json(line, out), .Normal
}

// A resync candidate's validity check: given the single physical line that
// contains it and the offset just past the anchor within that line, is the
// state right after that offset trustworthy as .Normal? nil means "trust the
// anchor unconditionally" (XML's historical behaviour — sound for "-->" only
// because Lex_State has nothing else it could be there; see EXT_LEXERS's
// comment). See base.lex_c_resync_valid for why the C-family entries below
// need this and XML doesn't.
Resync_Validate_Proc :: proc(line: []u8, candidate_end: int) -> bool

// Task 4: one grammar (base.lex_c), eleven keyword sets. Each extension gets
// its own tiny pair of adapters — one binding the keyword set to lex_c's
// Lexer_Proc shape, one binding it to lex_c_resync_valid's — mirroring
// lex_log_adapt/lex_json_adapt's existing shape exactly. See lex_c.odin's
// header and its per-language keyword tables (C_KW, CPP_KW, ...) for what
// each language actually gets and where each keyword list came from.
@(private = "file")
lex_c_c_adapt :: proc(line: []u8, state_in: base.Lex_State, out: []base.Token) -> (n: int, state_out: base.Lex_State) {
	return base.lex_c(line, state_in, &base.C_KW, out)
}
@(private = "file")
lex_c_c_valid :: proc(line: []u8, candidate_end: int) -> bool {return base.lex_c_resync_valid(&base.C_KW, line, candidate_end)}

@(private = "file")
lex_c_cpp_adapt :: proc(line: []u8, state_in: base.Lex_State, out: []base.Token) -> (n: int, state_out: base.Lex_State) {
	return base.lex_c(line, state_in, &base.CPP_KW, out)
}
@(private = "file")
lex_c_cpp_valid :: proc(line: []u8, candidate_end: int) -> bool {return base.lex_c_resync_valid(&base.CPP_KW, line, candidate_end)}

@(private = "file")
lex_c_cs_adapt :: proc(line: []u8, state_in: base.Lex_State, out: []base.Token) -> (n: int, state_out: base.Lex_State) {
	return base.lex_c(line, state_in, &base.CS_KW, out)
}
@(private = "file")
lex_c_cs_valid :: proc(line: []u8, candidate_end: int) -> bool {return base.lex_c_resync_valid(&base.CS_KW, line, candidate_end)}

@(private = "file")
lex_c_java_adapt :: proc(line: []u8, state_in: base.Lex_State, out: []base.Token) -> (n: int, state_out: base.Lex_State) {
	return base.lex_c(line, state_in, &base.JAVA_KW, out)
}
@(private = "file")
lex_c_java_valid :: proc(line: []u8, candidate_end: int) -> bool {return base.lex_c_resync_valid(&base.JAVA_KW, line, candidate_end)}

@(private = "file")
lex_c_js_adapt :: proc(line: []u8, state_in: base.Lex_State, out: []base.Token) -> (n: int, state_out: base.Lex_State) {
	return base.lex_c(line, state_in, &base.JS_KW, out)
}
@(private = "file")
lex_c_js_valid :: proc(line: []u8, candidate_end: int) -> bool {return base.lex_c_resync_valid(&base.JS_KW, line, candidate_end)}

@(private = "file")
lex_c_ts_adapt :: proc(line: []u8, state_in: base.Lex_State, out: []base.Token) -> (n: int, state_out: base.Lex_State) {
	return base.lex_c(line, state_in, &base.TS_KW, out)
}
@(private = "file")
lex_c_ts_valid :: proc(line: []u8, candidate_end: int) -> bool {return base.lex_c_resync_valid(&base.TS_KW, line, candidate_end)}

@(private = "file")
lex_c_go_adapt :: proc(line: []u8, state_in: base.Lex_State, out: []base.Token) -> (n: int, state_out: base.Lex_State) {
	return base.lex_c(line, state_in, &base.GO_KW, out)
}
@(private = "file")
lex_c_go_valid :: proc(line: []u8, candidate_end: int) -> bool {return base.lex_c_resync_valid(&base.GO_KW, line, candidate_end)}

@(private = "file")
lex_c_rust_adapt :: proc(line: []u8, state_in: base.Lex_State, out: []base.Token) -> (n: int, state_out: base.Lex_State) {
	return base.lex_c(line, state_in, &base.RUST_KW, out)
}
@(private = "file")
lex_c_rust_valid :: proc(line: []u8, candidate_end: int) -> bool {return base.lex_c_resync_valid(&base.RUST_KW, line, candidate_end)}

@(private = "file")
lex_c_odin_adapt :: proc(line: []u8, state_in: base.Lex_State, out: []base.Token) -> (n: int, state_out: base.Lex_State) {
	return base.lex_c(line, state_in, &base.ODIN_KW, out)
}
@(private = "file")
lex_c_odin_valid :: proc(line: []u8, candidate_end: int) -> bool {return base.lex_c_resync_valid(&base.ODIN_KW, line, candidate_end)}

// Task 5: .css and .sql fold into the SAME C-family grammar as the eleven
// languages above -- one more Keyword_Set each (base.CSS_KW/base.SQL_KW),
// not a new lexer. See those tables' own comments (lex_c.odin) for exactly
// what each fold gets right and the disclosed imprecisions each accepts.
@(private = "file")
lex_c_css_adapt :: proc(line: []u8, state_in: base.Lex_State, out: []base.Token) -> (n: int, state_out: base.Lex_State) {
	return base.lex_c(line, state_in, &base.CSS_KW, out)
}
@(private = "file")
lex_c_css_valid :: proc(line: []u8, candidate_end: int) -> bool {return base.lex_c_resync_valid(&base.CSS_KW, line, candidate_end)}

@(private = "file")
lex_c_sql_adapt :: proc(line: []u8, state_in: base.Lex_State, out: []base.Token) -> (n: int, state_out: base.Lex_State) {
	return base.lex_c(line, state_in, &base.SQL_KW, out)
}
@(private = "file")
lex_c_sql_valid :: proc(line: []u8, candidate_end: int) -> bool {return base.lex_c_resync_valid(&base.SQL_KW, line, candidate_end)}

// Task 5: the delimited-values lexer (base.lex_delimited) parameterized on
// the delimiter byte -- one tiny adapter per extension, same shape as the
// C-family adapters above. Line-local (see base/lex_delimited.odin's
// header), so no *_valid wrapper is needed -- these are registered
// stateful=false below, same as lex_log/lex_json.
@(private = "file")
lex_delimited_csv_adapt :: proc(line: []u8, state_in: base.Lex_State, out: []base.Token) -> (n: int, state_out: base.Lex_State) {
	return base.lex_delimited(line, ',', out), .Normal
}
@(private = "file")
lex_delimited_tsv_adapt :: proc(line: []u8, state_in: base.Lex_State, out: []base.Token) -> (n: int, state_out: base.Lex_State) {
	return base.lex_delimited(line, '\t', out), .Normal
}

// Task 5: base.lex_config is already line-local with the (line, out) -> n
// shape lex_log/lex_json use -- one shared adapter for all five extensions
// it covers (.ini .cfg .conf .env .gitignore). base.lex_yaml, by contrast,
// already matches Lexer_Proc's shape exactly (state_in/state_out, same as
// base.lex_xml) and needs no adapter at all -- see EXT_LEXERS below.
@(private = "file")
lex_config_adapt :: proc(line: []u8, state_in: base.Lex_State, out: []base.Token) -> (n: int, state_out: base.Lex_State) {
	return base.lex_config(line, out), .Normal
}

// Task 5: the shell lexer (base.lex_shell) parameterized on a per-dialect
// base.Shell_Set -- one adapter per extension, mirroring the C-family shape
// exactly. Only PowerShell (.ps1) carries real state (its <# #> block
// comment); bash and batch's Shell_Set never produces anything but .Normal
// (Shell_Set.block_comment is false for both), so they are registered
// stateful=false below even though they share this same adapter shape.
@(private = "file")
lex_shell_sh_adapt :: proc(line: []u8, state_in: base.Lex_State, out: []base.Token) -> (n: int, state_out: base.Lex_State) {
	return base.lex_shell(line, state_in, &base.BASH_SH, out)
}
@(private = "file")
lex_shell_bat_adapt :: proc(line: []u8, state_in: base.Lex_State, out: []base.Token) -> (n: int, state_out: base.Lex_State) {
	return base.lex_shell(line, state_in, &base.BATCH, out)
}
@(private = "file")
lex_shell_ps1_adapt :: proc(line: []u8, state_in: base.Lex_State, out: []base.Token) -> (n: int, state_out: base.Lex_State) {
	return base.lex_shell(line, state_in, &base.POWERSHELL, out)
}
@(private = "file")
lex_shell_ps1_valid :: proc(line: []u8, candidate_end: int) -> bool {
	return base.lex_shell_resync_valid(&base.POWERSHELL, line, candidate_end)
}

// Extension (with leading dot, case-insensitive) -> lexer, whether that
// lexer's state can differ line to line, the byte marker whose end position
// is unambiguously .Normal (used to seed the bounded resync,
// program/lex_index.odin, before it starts lexing forward), and — when a
// bare textual match on that marker is NOT enough on its own — the validator
// that confirms a candidate occurrence before trusting it.
//
// "-->" is safe for XML/HTML with resync_validate left nil (trust the last
// occurrence unconditionally) because comments don't nest AND Lex_State has
// no In_Tag/In_Attr_String: `<a href="x-->y">` really is .Normal wherever
// "-->" lands, so there is nothing for a validator to catch.
//
// `*/` is NOT unambiguously .Normal for the C-family entries below —
// `char *s = "*/";` and `// */` both put it at a position that is inside a
// string or a line comment — so every one of them registers
// base.lex_c_resync_valid (via its own tiny per-language wrapper above) as
// resync_validate. lex_resync_state (lex_index.odin) walks candidate
// occurrences from the last backward and uses the first one the validator
// accepts, rather than blindly trusting the last textual match the way the
// nil-validator path does. See base.lex_c_resync_valid's own comment for why
// that check is sound given this grammar's Lex_State shape.
//
// `.log` is Task 1's entry; `.json` is Task 2's; `.xml`/`.html` are Task 3's;
// the eleven C-family extensions are Task 4's. Task 5 (this one) adds
// markdown, delimited, config, YAML, shell, and folds .css/.sql into the
// C-family grammar above — see task-5-report.md for the full account,
// including two entries below whose resync_validate ALWAYS rejects rather
// than approximating an anchor that doesn't exist for their grammar:
//
//   - Markdown's "```" fence marker TOGGLES state (the SAME bytes open and
//     close it), unlike XML's "-->" or C's validated "*/" — see
//     base.lex_markdown_resync_valid's comment.
//   - YAML's block scalar ends based on the FOLLOWING line's indentation
//     relative to an arbitrarily-distant key, which Resync_Validate_Proc's
//     one-line signature cannot express at all — see
//     base.lex_yaml_resync_valid's comment.
//
// Both are still registered stateful=true (so the small-file background
// index, which never consults resync_anchor, stays exactly correct); only
// a huge/mapped file of either kind always cap-hits to .Normal on resync,
// rather than merely when a construct outgrows the window the way every
// other stateful entry's documented failure mode works. `.txt`, `.py`, and
// every other extension not listed below correctly map to no lexer at all
// — `.py` is a genuine gap this task's own coverage test (highlighttest's
// sibling, see the extension-coverage check) caught: the design doc's
// "34 extensions" count already included it, but no lexer was ever
// assigned to it. Left deliberately plain rather than force-fit into an
// existing grammar that doesn't actually match Python — see
// task-5-report.md.
@(private = "file")
EXT_LEXERS := [?]struct {
	ext:             string,
	lexer:           Lexer_Proc,
	stateful:        bool, // false: state_in is never consulted, don't bother indexing
	resync_anchor:   string, // "" when stateful is false (never consulted)
	resync_validate: Resync_Validate_Proc, // nil: trust resync_anchor's last occurrence unconditionally (sound only for XML's "-->" — see comment above)
}{
	{".log", lex_log_adapt, false, "", nil},
	{".json", lex_json_adapt, false, "", nil},
	{".xml", base.lex_xml, true, "-->", nil},
	{".html", base.lex_xml, true, "-->", nil},
	{".c", lex_c_c_adapt, true, "*/", lex_c_c_valid},
	{".h", lex_c_c_adapt, true, "*/", lex_c_c_valid},
	{".cpp", lex_c_cpp_adapt, true, "*/", lex_c_cpp_valid},
	{".hpp", lex_c_cpp_adapt, true, "*/", lex_c_cpp_valid},
	{".cs", lex_c_cs_adapt, true, "*/", lex_c_cs_valid},
	{".java", lex_c_java_adapt, true, "*/", lex_c_java_valid},
	{".js", lex_c_js_adapt, true, "*/", lex_c_js_valid},
	{".ts", lex_c_ts_adapt, true, "*/", lex_c_ts_valid},
	{".go", lex_c_go_adapt, true, "*/", lex_c_go_valid},
	{".rs", lex_c_rust_adapt, true, "*/", lex_c_rust_valid},
	{".odin", lex_c_odin_adapt, true, "*/", lex_c_odin_valid},
	{".css", lex_c_css_adapt, true, "*/", lex_c_css_valid},
	{".sql", lex_c_sql_adapt, true, "*/", lex_c_sql_valid},
	{".md", base.lex_markdown, true, "```", base.lex_markdown_resync_valid},
	{".markdown", base.lex_markdown, true, "```", base.lex_markdown_resync_valid},
	{".csv", lex_delimited_csv_adapt, false, "", nil},
	{".tsv", lex_delimited_tsv_adapt, false, "", nil},
	{".ini", lex_config_adapt, false, "", nil},
	{".cfg", lex_config_adapt, false, "", nil},
	{".conf", lex_config_adapt, false, "", nil},
	{".env", lex_config_adapt, false, "", nil},
	{".gitignore", lex_config_adapt, false, "", nil},
	{".toml", lex_config_adapt, false, "", nil},
	{".yaml", base.lex_yaml, true, "\n", base.lex_yaml_resync_valid},
	{".yml", base.lex_yaml, true, "\n", base.lex_yaml_resync_valid},
	{".sh", lex_shell_sh_adapt, false, "", nil},
	{".bat", lex_shell_bat_adapt, false, "", nil},
	{".ps1", lex_shell_ps1_adapt, true, "#>", lex_shell_ps1_valid},
}

// A stateful entry with no resync_anchor is an undetectable bail: doc_draw's
// bootstrap and the filter view both call lex_resync_state with whatever
// anchor highlight_lexer_for hands back, and lex_resync_state's own
// `len(anchor) == 0` guard returns `.Normal, false` silently -- not a crash,
// just every row of that extension mis-colouring the moment state matters,
// with nothing to point at why. EXT_LEXERS is a fixed table maintained by
// hand, not generated, so nothing else catches a new stateful entry added
// without its anchor -- this is that catch.
//
// The predicate is separate from the reporting so lexcoveragetest can assert
// it as an ordinary check line (nothing in the table is expressible as a
// compile-time #assert: EXT_LEXERS is a runtime array of composite literals,
// and Odin has no compile-time loop to fold it with).
highlight_ext_tables_ok :: proc() -> (ok: bool, offender: string) {
	for e in EXT_LEXERS {
		if e.stateful && e.resync_anchor == "" {return false, e.ext}
	}
	return true, ""
}

// Run the check and make its failure VISIBLE. It used to be an @(init) that
// called panic_contextless: correct, but in the shipped GUI-subsystem build
// there is no console for a panic message to land in, and an @(init) runs
// before diag_init has armed the logger, so nothing reached the log file
// either. Called from diag_init instead, once the sink is live, so the line
// lands in %APPDATA%\Newtpad\logs\newtpad.log. The panic stays: a mis-built
// table is a programming error, the debug build should still stop loudly on
// it, and the crash handler now folds the logged line into the report.
highlight_check_ext_tables :: proc() {
	if ok, offender := highlight_ext_tables_ok(); !ok {
		base.log_error("EXT_LEXERS: stateful entry %q has no resync_anchor -- its rows will silently mis-colour", offender)
		panic("EXT_LEXERS: a stateful lexer must register a resync_anchor")
	}
}

// The complete, EXPLICIT list of extensions in text_exts.txt that
// deliberately have no lexer at all — Task 5's Step 4, made a hand-maintained
// list rather than "whatever EXT_LEXERS doesn't happen to mention":
//
//   - .txt has no grammar to find (design doc: "`.txt` stays plain,
//     correctly"). Never expected to gain a lexer.
//   - .py is a REAL GAP this task's own coverage test (lexcoveragetest,
//     test_modes.odin) caught rather than shipped silently: the design doc's
//     "34 extensions" count already included .py, but no lexer was ever
//     assigned to it in any of this batch's four tasks. None of this
//     batch's seven lexers are an honest fit for Python's actual grammar
//     (significant indentation, `#` comments, triple-quoted multi-line
//     strings) — forcing it through, say, the shell lexer's `#`-comment
//     handling would get comments right and nothing else, which is exactly
//     the "half-works" outcome CLAUDE.md and this batch's own briefs warn
//     against. Left plain rather than guessed at; a real Python lexer is a
//     follow-up task's to build deliberately, not this one's to improvise.
//
// lexcoveragetest asserts every extension in the ACTUAL text_exts.txt
// resolves to either a real lexer (highlight_lexer_for returns non-nil) or
// an entry in this exact list — so adding a ninth extension to
// text_exts.txt without either giving it a lexer or adding it here fails a
// test instead of being noticed on screen.
DELIBERATELY_PLAIN_EXTS := []string{".txt", ".py"}

// The lexer for a document's path (nil when the extension has none yet, or
// never will, like .txt), whether it carries state across lines, and — when
// it does — the resync anchor marker and (maybe) its validator. See
// EXT_LEXERS's comment for what all four mean.
highlight_lexer_for :: proc(path: string) -> (lexer: Lexer_Proc, stateful: bool, resync_anchor: string, resync_validate: Resync_Validate_Proc) {
	if path == "" {return}
	dot := strings.last_index_byte(path, '.')
	if dot < 0 {return}
	ext := path[dot:]
	for e in EXT_LEXERS {
		if strings.equal_fold(ext, e.ext) {return e.lexer, e.stateful, e.resync_anchor, e.resync_validate}
	}
	return
}

// Token_Kind -> Color_Role. Data, not branching logic: every kind a lexer can
// produce maps to exactly one of the nine Syn_* roles theme.odin declared for
// this batch. A total enumerated array, not a #partial switch: Odin rejects
// an incomplete keyed enumerated-array composite literal at compile time
// (see theme.odin's Theme/#assert comment, and command_table's identical
// reasoning), so a Token_Kind a later task adds and forgets to map here is a
// build error, not a silent fallthrough. `.None` still needs an entry
// because the array is total over the whole enum, but it never actually
// reaches g_theme[...] — highlight_row_spans filters `.None` out before this
// map is consulted — so its value here is unreachable, not meaningful.
@(private = "file")
TOKEN_KIND_ROLE := [base.Token_Kind]Color_Role {
	.None     = .Syn_Punct, // unreachable -- see comment above
	.Keyword  = .Syn_Keyword,
	.String   = .Syn_String,
	.Number   = .Syn_Number,
	.Comment  = .Syn_Comment,
	.Type     = .Syn_Type,
	.Punct    = .Syn_Punct,
	.Json_Key = .Syn_Json_Key,
	.Xml_Tag  = .Syn_Xml_Tag,
	.Xml_Attr = .Syn_Xml_Attr,
}

highlight_kind_role :: proc(k: base.Token_Kind) -> Color_Role {
	return TOKEN_KIND_ROLE[k]
}

// Tokens per row a pattern lexer can produce before highlight_row_spans stops
// converting them — and the size of every fixed token/span array on the row
// path: highlight_row_spans's `toks`, doc_draw's `hl_buf`,
// Highlight_Row_Cache.cur_buf, highlight_merge_spans's `survivors`, and
// lex_resync_state's / the index worker's `tok_buf`.
//
// The bound is in TOKENS, and a token is not a character: lex_c emits one per
// punctuation BYTE (its `.Punct` branch, lex_c.odin), so density swings by
// nearly 4x with the content. Measured by running the real lexers over real
// input (2026-07 review):
//
//   hand-written source, this repo through lex_c/ODIN_KW:  4.9–5.9 chars/token
//                                     worst single line:  46 tokens / 223 chars
//   dense C / minified JS / minified JSON:                 2.2 / 1.8 / 1.5 chars/token
//
// 512 therefore covers ~2,500 characters of ordinary source — past
// VISIBLE_COLS, the 2,048 cells a row can actually show — but only ~770 of
// minified JSON, the densest real content measured. The value this replaced,
// 64, covered ~100 characters of that and ~370 of ordinary code, justified as
// "a screen row is bounded by VISIBLE_COLS cells; generous headroom": wrong
// by more than 10x, and on a minified .js/.css/.json it meant colouring
// stopped a tenth of the way across the row.
//
// Covering VISIBLE_COLS unconditionally would take 2,048 (a row of pure
// punctuation really is one token per byte) — 64 KB per span array, ~160 KB
// in doc_draw's frame alone. 512 is where the trade sits: 16 KB per
// Text_Span array (32 B each), 12 KB per Token array (24 B each), ~43 KB in
// doc_draw's frame including the row cache, and no frame over 64 KB.
//
// Past the cap, colouring stops but the row still DRAWS in full
// (text_draw_spans simply runs out of spans), and the lexer's state_out is
// still correct — every lexer keeps SCANNING once `out` is full rather than
// returning early with whatever state it had reached. That invariant is
// checked, not assumed: all five stateful lexers (lex_xml, lex_c,
// lex_markdown, lex_yaml, lex_shell) guard each emit with `n < len(out)` and
// never break their scan loop on it, and the four line-local ones (lex_log,
// lex_json, lex_delimited, lex_config) do stop scanning when `out` fills,
// which is sound only because their state_out is unconditionally .Normal.
// See the "Keep lex_xml scanning for state past its token cap" fix earlier in
// this branch for the bug this exists because of.
HL_MAX_ROW_TOKENS :: 512

// Total bytes handed to a lexer, accumulated across calls. Exists only for
// highlighttest (test_modes.odin) to prove the per-frame cost is
// viewport-proportional rather than O(file) — see that mode's comment for
// why a plain package-level int, not a debug-only counter, is the right
// weight here: incrementing it costs less than the lex call it accounts for,
// the same shape draw_calls_text already carries unconditionally in the
// shipping text_draw_spans (platform/text.odin).
hl_bytes_examined: int

// Combine one row's raw lexer spans with its link spans into a single
// sorted, non-overlapping list — the shape text_draw_spans requires. Links
// always win: a lexer span that intersects a link anywhere is dropped
// WHOLE, never truncated, because text_draw_spans's own contract ("sorted…
// must not overlap") has no defined behaviour for overlapping input (see
// the comment at doc_draw's call site for the concrete example). Both
// inputs must already be sorted ascending by start with no internal
// overlaps of their own (lex_spans: tokens are found left to right;
// link_spans: links_layout scans the same way), so survivor selection plus
// a linear two-pointer merge is enough — no general sort — and the two
// inputs never contain an overlapping pair once the drop below has run,
// which is exactly the precondition being upheld.
//
// Factored out of doc_draw, which previously had this inlined, so
// highlighttest can call the literal proc doc_draw draws with rather than a
// second copy that could quietly diverge — "test the seam, not the unit"
// (CLAUDE.md). A 2026-07 review flagged this mechanism as untested; the
// "link precedence" checks in highlighttest exist to close that gap.
highlight_merge_spans :: proc(lex_spans, link_spans: []plat.Text_Span, out: []plat.Text_Span) -> int {
	survivors: [HL_MAX_ROW_TOKENS]plat.Text_Span
	sn := 0
	outer: for sp in lex_spans {
		for l in link_spans {
			if sp.start < l.start + l.len && l.start < sp.start + sp.len {
				continue outer // overlaps a link: drop it whole, link wins
			}
		}
		if sn >= len(survivors) {break}
		survivors[sn] = sp
		sn += 1
	}
	n := 0
	li, ri := 0, 0
	for (li < sn || ri < len(link_spans)) && n < len(out) {
		if ri >= len(link_spans) || (li < sn && survivors[li].start <= link_spans[ri].start) {
			out[n] = survivors[li]
			li += 1
		} else {
			out[n] = link_spans[ri]
			ri += 1
		}
		n += 1
	}
	return n
}

// Row-relative syntax spans for one row's bytes, through whichever lexer
// `doc`'s path selects (nil for an extension with none, e.g. .txt — in which
// case this returns 0 and draws nothing extra). No allocation: tokens land
// in a fixed-size local array, spans are written into the caller's `out`
// slice. Runs per visible row per frame, so this is the hot path
// highlighttest holds to viewport-proportional cost.
//
// `row_bytes` is whatever the caller decides represents "this row" — this
// proc has no opinion on word wrap. doc_draw (doc.odin) passes the row's own
// drawn bytes directly for an unwrapped or filtered row (which already IS
// the whole logical line, capped) and routes a wrapped row through
// doc_row_lex_spans, which lexes the cached whole logical line once and
// rebases the result onto each visual row — see that proc's comment.
//
// `state_in` is the Lex_State the lexer should begin this row's bytes in
// (.Normal for a line-local lexer or for the very first line of a stateful
// one); `state_out` is what it ends in, for the caller to pass to whatever
// comes next. A nil lexer returns state_in unchanged, so a caller that always
// threads state_out forward doesn't need to special-case "no lexer."
highlight_row_spans :: proc(doc: ^Document, row_bytes: []u8, state_in: base.Lex_State, out: []plat.Text_Span) -> (n: int, state_out: base.Lex_State) {
	state_out = state_in
	if doc == nil || len(row_bytes) == 0 || len(out) == 0 {return}
	lexer, _, _, _ := highlight_lexer_for(doc.path)
	if lexer == nil {return}
	toks: [HL_MAX_ROW_TOKENS]base.Token
	tn: int
	tn, state_out = lexer(row_bytes, state_in, toks[:])
	hl_bytes_examined += len(row_bytes)
	w := 0
	for i in 0 ..< tn {
		if w >= len(out) {break}
		tok := toks[i]
		if tok.kind == .None {continue}
		out[w] = plat.Text_Span {
			start = tok.start,
			len   = tok.len,
			color = g_theme[highlight_kind_role(tok.kind)],
		}
		w += 1
	}
	n = w
	return
}
