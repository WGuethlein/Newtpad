// Layer: program -- keyword->colour rules (%APPDATA%\Newtpad\rules.txt).
//
// Research §C calls this "disproportionately loved by log users": the poor
// man's highlighting that needs no lexer. One `pattern = Role_Name` per line,
// matched as a LITERAL SUBSTRING against every visible row, every frame.
//
// Four decisions carry the whole design, and each one is here because the
// alternative has a concrete cost:
//
//   1. LITERAL SUBSTRINGS, NOT REGEX. Regex costs 16-19 ms/MB (HANDOFF §6d)
//      and this runs per visible row per frame, inside the budget the lexer
//      already spends. A literal multi-pattern scan is what the renderer can
//      afford; `^ERROR` is a pattern that matches the five characters "^ERRO"
//      followed by "R", not an anchor, and the seeded header says so.
//
//   2. ROLES ARE Color_Role NAMES, not RGB. A rule therefore cannot invent a
//      colour, and every rule is themeable for free -- the same rules.txt
//      reads correctly in Dark and in Light because it names a role. The
//      colour is resolved out of g_theme at DRAW time, not at parse time, so
//      switching theme recolours existing rules with no reload.
//
//   3. RULES ARE THE LOWEST-PRIORITY SPAN PRODUCER: links > lexer > rules
//      (decided in the batch 10 plan, "The precedence question"). They never
//      punch holes in real syntax colouring -- a rule matching `error` inside
//      a JSON string would recolour part of a token and make correct code look
//      broken -- and they win exactly where they are for, which is the .txt and
//      .log files that have no lexer at all. The ordering is enforced by
//      highlight_merge_spans_n (highlight.odin), the SAME merge the lexer and
//      the links go through, never a second pass beside it.
//
//   4. THE PER-FRAME COST IS BOUNDED BY CONSTRUCTION, not by hoping. RULES_MAX
//      caps the rule count, RULES_PATTERN_MAX caps a pattern's length, and the
//      scan is driven by a 256-entry first-byte table (`first_byte`) holding a
//      bitmask of the rules that can possibly start at that byte. A row byte
//      that begins no rule costs one table load and one compare -- so the
//      common case is O(row), not O(rules x row), and the O(rules x row x
//      pattern) worst case needs a row made entirely of near-misses for 64
//      rules sharing a first byte. See rulestest's cost measurement.
//
// Everything about the file is tolerant in the way settings.txt, the themes and
// keys.txt are tolerant: an unknown role, a malformed line, a pattern that is
// too long and a 65th rule are all counted, logged and skipped. Nothing in this
// file is ever fatal, and an absent file is the ordinary case -- it leaves
// g_rules empty and every path here becomes a length check that returns 0.
package main

import "base:intrinsics"
import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strings"
import base "src:base"
import plat "src:platform"

// How many rules may be active at once. The bound exists because the scan runs
// per visible row per frame: at the cap, a worst-case row (every byte starting
// a candidate that fails late) costs RULES_MAX x RULES_PATTERN_MAX byte
// compares per row. The measured cost at this cap is in rulestest and in
// .superpowers/sdd/b10-task-2-report.md; the instruction from the plan was to
// lower the cap rather than ship a number over ~1 ms per frame.
//
// 64 is also exactly the width of the first_byte bitmask below, which is what
// makes "which rules can start here" one u64 load. Raising this past 64 is not
// a constant change -- it changes the mask type.
RULES_MAX :: 64

// The longest pattern a line may declare. Two jobs: it is the second half of
// the worst-case cost bound above, and it stops a runaway line (a pasted log
// record, a whole paragraph) from being accepted as a "keyword" that can never
// match anything on a screen row anyway.
RULES_PATTERN_MAX :: 64

// Rule spans one row may contribute before the scan stops. Sized like the
// lexer's own HL_MAX_ROW_TOKENS and for the same reason: a row that saturates
// must DEGRADE (colouring stops partway across, the row still draws in full),
// never overflow. 256 x 32 B = 8 KB in doc_draw's frame, on top of the ~42 KB
// its existing row buffers hold -- see HL_MAX_ROW_TOKENS's own note on the
// 64 KB frame budget.
//
// A visual row is VISIBLE_COLS (2048) cells wide, so 256 spans means colouring
// survives one match every 8 columns across a full-width row. Denser than that
// is a row where the rules have coloured essentially everything.
RULES_MAX_ROW_SPANS :: 256

// Candidate comparisons one row may spend before the scan gives up. This is the
// hard backstop on per-frame cost, and it exists because measuring found that
// the two obvious caps do not bound anything on their own:
//
//   * 64 log/source keywords over a 40-row viewport of real log lines costs
//     0.005 ms per frame (release). Fine by three orders of magnitude.
//   * The same rules over FULL-WIDTH rows -- doc_draw reads up to VISIBLE_COLS
//     bytes per visual row, so a minified .json or a long unwrapped line really
//     is 40 x 2048 bytes in one frame -- costs 0.085 ms.
//   * The ADVERSARIAL shape costs whatever it is allowed to. 64 patterns of the
//     maximum length agreeing on all but their 63rd byte, over a full-width row
//     of that byte, defeats both index tables and runs 64 long compares at every
//     one of 2048 positions: 131,072 comparisons per row, 14 ms per frame,
//     unbudgeted.
//
// Lowering RULES_MAX to 32 would have halved the adversarial figure -- still
// far over -- while halving what a user may legitimately write. The probe
// budget bounds the same product (rules x row x pattern) directly instead: a
// row costs at most RULES_MAX_ROW_PROBES comparisons of at most
// RULES_PATTERN_MAX bytes each, whatever the rules look like.
//
// 4096 is 10x the 409 comparisons the FULL-WIDTH realistic case actually spends,
// so no row anyone will write comes near it, and it puts the adversarial worst
// case at about 0.4 ms per frame in the shipped build.
//
// Past the budget the row stops being coloured and still DRAWS in full -- the
// same degradation the lexer's own HL_MAX_ROW_TOKENS gives. rulestest measures
// the adversarial frame and FAILS over the budget, so this number is GATED
// rather than asserted; see §6ad's SEARCH_FIRST_PAINT for the same shape, and
// see that mode for why the release gate is the real one.
RULES_MAX_ROW_PROBES :: 4096

// One rule. `pattern` is owned by the Color_Rules it lives in (cloned at parse
// time) and freed by rules_destroy; `role` is resolved to a colour at draw time
// so a theme switch is free.
Color_Rule :: struct {
	pattern: string,
	role:    Color_Role,
}

// Why a line was thrown away. Counted rather than collected, exactly as
// Keymap_Reject is, so the parse stays allocation-light and so rulestest can
// assert the exact reason -- "the line was ignored" is not the same claim as
// "the line was ignored BECAUSE the role does not exist".
Rules_Reject :: enum u8 {
	Malformed, // no '=', or nothing before it
	Unknown_Role, // "ERROR = Neon_Pink"
	Too_Long, // a pattern over RULES_PATTERN_MAX bytes
	Too_Many, // the 65th accepted rule
}

// A parsed rules.txt.
//
// `first_byte[c]` and `second_byte[c]` hold a bit per rule whose pattern has
// byte `c` in that position; `len1` holds a bit per ONE-byte pattern, which has
// no second byte to index and so has to stay a candidate unconditionally. All
// three are derived state, rebuilt by rules_index whenever `list` changes.
//
// They are NOT optional, and the second one is not a micro-optimisation. With
// only the first-byte table, 64 rules over a viewport of FULL-WIDTH rows (the
// minified-.json shape: doc_draw reads up to VISIBLE_COLS bytes per visual row)
// left 2,517 candidate comparisons per row and cost 1.72 ms per frame in the
// debug build -- past the ~1 ms the batch 10 plan budgeted. ANDing the second
// byte in costs one extra load and one AND per row byte and takes the same case
// to 409 comparisons per row and 0.69 ms (0.085 ms release). rulestest prints
// the figure it is measured from.
//
// `duplicates` is counted and logged but deliberately NOT part of
// rules_reject_total, because a duplicate is HONOURED (last wins) rather than
// refused. That total is what drives the "[RULES.TXT: n LINES REFUSED]" note
// after a save, and telling someone a line was refused when it took effect
// would send them looking for a mistake they did not make.
//
// `pattern_alloc` is the allocator every pattern was cloned from. Recorded
// rather than assumed because rules_destroy frees them one at a time and the
// default `delete` would take context.allocator -- fine for every caller today
// and a use-after-free the moment one passes something else. keymap_parse gets
// away with not tracking it only because a Binding owns no memory.
Color_Rules :: struct {
	list:          [dynamic]Color_Rule,
	first_byte:    [256]u64,
	second_byte:   [256]u64,
	len1:          u64,
	rejects:       [Rules_Reject]int,
	duplicates:    int,
	pattern_alloc: runtime.Allocator,
}

// Candidate comparisons the row scan has made, accumulated across calls.
// Exists only so rulestest can assert the probe budget BINDS rather than
// inferring it from a stopwatch -- the same weight and the same justification
// hl_bytes_examined (highlight.odin) carries for the lexer: incrementing an int
// costs less than the comparison it accounts for.
rules_probes_examined: int

// The active rule set. Empty until rules_load runs, and an empty set makes
// rules_row_spans return 0 on its first line -- so every path here is a no-op
// on a machine with no rules.txt.
g_rules: Color_Rules

// Are there any rules at all? The one check doc_draw makes per row before it
// spends a byte on this feature.
rules_active :: proc() -> bool {
	return len(g_rules.list) > 0
}

rules_destroy :: proc(r: ^Color_Rules) {
	alloc := r.pattern_alloc if r.pattern_alloc.procedure != nil else context.allocator
	for rule in r.list {delete(rule.pattern, alloc)}
	delete(r.list)
	r^ = {}
}

// Replace the active set, freeing the old one. Takes ownership of `r.list` and
// every pattern in it.
rules_install :: proc(r: Color_Rules) {
	rules_destroy(&g_rules)
	g_rules = r
}

rules_reset :: proc() {
	rules_destroy(&g_rules)
}

// Rebuild the three lookup tables from list. Called by rules_parse; also the
// one thing a caller that hand-builds a Color_Rules (rulestest) must not
// forget, which is why it is exported rather than file-private.
rules_index :: proc(r: ^Color_Rules) {
	r.first_byte = {}
	r.second_byte = {}
	r.len1 = 0
	for rule, i in r.list {
		if len(rule.pattern) == 0 || i >= RULES_MAX {continue}
		bit := u64(1) << uint(i)
		r.first_byte[rule.pattern[0]] |= bit
		if len(rule.pattern) == 1 {
			r.len1 |= bit
		} else {
			r.second_byte[rule.pattern[1]] |= bit
		}
	}
}

// Role name -> Color_Role, case-insensitively, accepting BOTH spellings that
// exist in the product: the enum name a user reads in this file's own seeded
// list (`Syn_Keyword`) and the lowercase file key the .theme files use
// (`syn_keyword`). They differ only in case, so one equal_fold over
// theme_role_keys covers both -- and that is deliberate rather than lucky: the
// single [Color_Role]string total array stays the only place a role name is
// written, so a role added without a key is still a compile error (§6x).
rules_role_from_name :: proc(s: string) -> (Color_Role, bool) {
	if s == "" {return {}, false}
	for key, role in theme_role_keys {
		if strings.equal_fold(key, s) {return role, true}
	}
	return {}, false
}

// PURE over the file's bytes: no window, no globals, no disk -- the same split
// keymap_parse has, and for the same reason (rulestest drives every case
// headlessly).
//
// The line is split at the LAST '=' rather than the first, so a pattern may
// contain one: `key=value = Syn_String` is a rule for the nine bytes
// `key=value`, which is what half the log lines in the world are made of.
// Splitting at the first '=' would make that pattern unwritable.
//
// Duplicates: LAST WINS, stated in the seeded header. Implemented by
// overwriting the earlier rule's role in place rather than appending a second
// entry, so the scan can never see two rules with the same pattern and does not
// need a tie-break for that case. The earlier rule keeps its POSITION, which
// only matters for the equal-length tie-break in rules_row_spans, and there it
// is the conservative choice: a redefinition should not also reorder.
rules_parse :: proc(src: string, allocator := context.allocator) -> Color_Rules {
	r: Color_Rules
	r.list = make([dynamic]Color_Rule, allocator)
	r.pattern_alloc = allocator

	for raw_line, line_no in strings.split_lines(src, context.temp_allocator) {
		line := strings.trim_space(raw_line)
		// A '#' in column 0 is a comment, ALWAYS -- so a pattern cannot begin
		// with '#'. Said in the seeded header (match "TODO", not "#TODO")
		// rather than solved with an escape character, because an escape is a
		// second syntax for one problem and this file has no other need of one.
		if line == "" || line[0] == '#' {continue}

		eq := strings.last_index_byte(line, '=')
		if eq < 0 {
			r.rejects[.Malformed] += 1
			base.log_warn("rules.txt:%d: no '=' in %q -- expected `pattern = Role_Name`", line_no + 1, line)
			continue
		}
		pat := strings.trim_space(line[:eq])
		name := strings.trim_space(line[eq + 1:])
		if pat == "" {
			r.rejects[.Malformed] += 1
			base.log_warn("rules.txt:%d: no pattern before '=' in %q", line_no + 1, line)
			continue
		}
		if name == "" {
			r.rejects[.Malformed] += 1
			base.log_warn("rules.txt:%d: no colour role after '=' in %q -- delete the line to remove a rule", line_no + 1, line)
			continue
		}
		if len(pat) > RULES_PATTERN_MAX {
			r.rejects[.Too_Long] += 1
			base.log_warn("rules.txt:%d: pattern %q refused -- %d bytes, the limit is %d", line_no + 1, pat[:RULES_PATTERN_MAX], len(pat), RULES_PATTERN_MAX)
			continue
		}
		role, rok := rules_role_from_name(name)
		if !rok {
			r.rejects[.Unknown_Role] += 1
			base.log_warn("rules.txt:%d: unknown colour role %q -- see the list at the bottom of the file", line_no + 1, name)
			continue
		}
		dup := -1
		for existing, i in r.list {
			if existing.pattern == pat {
				dup = i
				break
			}
		}
		if dup >= 0 {
			r.duplicates += 1
			base.log_warn("rules.txt:%d: %q is declared more than once -- this line wins, the earlier one is discarded", line_no + 1, pat)
			r.list[dup].role = role // last line wins
			continue
		}
		if len(r.list) >= RULES_MAX {
			r.rejects[.Too_Many] += 1
			base.log_warn("rules.txt:%d: %q ignored -- there are already %d rules, which is the limit", line_no + 1, pat, RULES_MAX)
			continue
		}
		append(&r.list, Color_Rule{strings.clone(pat, allocator), role})
	}
	rules_index(&r)
	return r
}

rules_reject_total :: proc(r: Color_Rules) -> (n: int) {
	for c in r.rejects {n += c}
	return
}

// Row-relative rule spans for one row's bytes, sorted ascending by start with
// no overlaps -- the precondition highlight_merge_spans_n requires of every
// producer, and the one text_draw_spans has no defined behaviour without.
//
// Both properties fall out of the scan rather than being restored afterwards:
// positions are visited left to right, and a match advances the cursor PAST its
// own end, so two rule spans can never touch.
//
// Where two rules match at the SAME position, the LONGER match wins: with `ERR`
// and `ERROR` both declared, colouring only the first three letters of ERROR
// reads as a truncation defect, not as a precedence. Where they match at
// DIFFERENT positions and would overlap, the LEFTMOST wins and the cursor jumps
// past it, so the second never gets a turn.
//
// The `>=` in the length comparison below breaks an equal-length tie towards
// the later rule in the file, matching "a later line corrects an earlier one".
// That tie is UNREACHABLE and the code is defensive: two patterns matching at
// the same position with the same length are the same bytes, hence the same
// pattern, and rules_parse collapses duplicate patterns into one entry.
//
// Matching is CASE-SENSITIVE. `ERROR` and `error` are different rules; write
// both lines to colour both. Stated in the seeded header. The cost argument is
// real (a fold is a branch per byte on the hottest loop in the feature) but the
// deciding one is that log levels are conventionally cased and being able to
// separate `ERROR` from `error` is worth more than being spared a second line.
rules_row_spans :: proc(row: []u8, out: []plat.Text_Span) -> int {
	return rules_row_spans_of(&g_rules, row, out)
}

// The same scan against an explicit rule set. rules_row_spans is the shipping
// entry point (doc_draw draws with it); this one exists so a test can drive a
// hand-built set without installing it globally, and so the two can never
// diverge -- there is one loop, not two.
rules_row_spans_of :: proc(r: ^Color_Rules, row: []u8, out: []plat.Text_Span) -> int {
	if r == nil || len(r.list) == 0 || len(row) == 0 || len(out) == 0 {return 0}
	n := 0
	i := 0
	probes := 0
	for i < len(row) {
		// Which rules can possibly start here: the first-byte set, narrowed by
		// the second-byte set, plus every one-byte pattern (which has no second
		// byte and is fully decided by the first). At the last byte of the row
		// only the one-byte patterns can still fit.
		m := r.first_byte[row[i]]
		if m != 0 {
			m &= r.len1 | (r.second_byte[row[i + 1]] if i + 1 < len(row) else 0)
		}
		if m == 0 {
			i += 1
			continue
		}
		best := -1
		best_len := 0
		for m != 0 {
			k := int(intrinsics.count_trailing_zeros(m))
			m &= m - 1 // clear the lowest set bit
			p := r.list[k].pattern
			if len(p) > len(row) - i {continue}
			// Counted BEFORE the compare, because the compare is the cost.
			probes += 1
			rules_probes_examined += 1
			if probes > RULES_MAX_ROW_PROBES {
				// Budget spent. Keep what has been found so far and stop --
				// the row draws in full either way.
				return n
			}
			if string(row[i:i + len(p)]) != p {continue}
			// >=, not >: bits come out lowest-index first, so on equal length
			// the LATER rule in the file replaces the earlier one.
			if len(p) >= best_len {
				best = k
				best_len = len(p)
			}
		}
		if best < 0 {
			i += 1
			continue
		}
		if n >= len(out) {break} // saturated: stop colouring, never overflow
		out[n] = plat.Text_Span {
			start = i,
			len   = best_len,
			color = g_theme[r.list[best].role],
		}
		n += 1
		i += best_len
	}
	return n
}

// %APPDATA%\Newtpad\rules.txt -- sibling of settings.txt, keys.txt and
// session.txt under the same session_dir(), so NEWTPAD_SESSION_DIR redirects
// this too and the headless modes never touch the real store.
rules_path :: proc() -> (string, bool) {
	dir, ok := session_dir()
	if !ok {
		return "", false
	}
	return fmt.tprintf("%s%crules.txt", dir, '\\'), true
}

// Read rules.txt (if there is one) and make it the active set. A missing file,
// an unreadable one, or one made entirely of garbage all leave no rules active
// -- rules_parse returns an empty list and rules_row_spans returns 0.
//
// Returns the counts so the caller can say something: at startup nothing but the
// log is wanted, but on the reload-after-save path the user is standing there
// having just written a rule. Same split keymap_load has.
rules_load :: proc() -> (active: int, refused: int) {
	path, ok := rules_path()
	if !ok {return}
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil {
		rules_reset()
		return
	}
	r := rules_parse(string(data))
	active, refused = len(r.list), rules_reject_total(r)
	if active > 0 || refused > 0 {
		base.log_info("rules.txt: %d rule(s), %d line(s) refused", active, refused)
	}
	rules_install(r)
	return
}

// Re-read rules.txt if `path` names it. The mirror of theme_reapply_if_active
// and keymap_reload_if_active, called from the same two places (after a
// successful save, and after the external-change watcher reloads a document),
// so editing the rules inside Newtpad recolours the next frame without a
// restart. Without it, trying a rule means restarting the app.
//
// The compare normalises both sides for the reason theme's and keymap's do:
// doc.path can arrive from the Save dialog, from argv or from an Explorer drop,
// and can name the same file with different case and separators than the one
// built from session_dir().
//
// A refused line is REPORTED here and only here, in the same channel and with
// the same shape keys.txt uses: everywhere else a bad line is a log entry, which
// is the right weight for a file read at startup, but this is the try-it loop
// and the user is about to look at a row that did not change colour.
rules_reload_if_active :: proc(app: ^App, path: string) -> bool {
	rp, ok := rules_path()
	if !ok || path == "" {
		return false
	}
	norm :: proc(s: string) -> string {
		fwd, _ := strings.replace_all(s, "\\", "/", context.temp_allocator)
		return strings.to_lower(fwd, context.temp_allocator)
	}
	if norm(path) != norm(rp) {
		return false
	}
	_, refused := rules_load()
	if refused > 0 && app != nil {
		app_note(app, fmt.tprintf("[RULES.TXT: %d LINE%s REFUSED - see the log (View > Open Logs Folder)]", refused, "" if refused == 1 else "S"))
	}
	return true
}

// The file Newtpad writes when there isn't one: a header that has to teach the
// three things nobody can guess (literal not regex, role names not colours,
// where rules sit in the precedence order), a few rules commented out as a
// starting point, and the complete list of role names -- there is no other place
// in the product that lists them.
//
// Temp-allocated by default, exactly as keymap_seed_text is: the result is
// written to disk or parsed and dropped by both callers.
rules_seed_text :: proc(allocator := context.temp_allocator) -> string {
	b := strings.builder_make(allocator)
	w :: proc(b: ^strings.Builder, s: string) {strings.write_string(b, s)}
	w(&b, "# Newtpad colour rules. Restart is not needed -- saving this file re-reads it.\n")
	w(&b, "#\n")
	w(&b, "# One rule per line:\n")
	w(&b, "#\n")
	w(&b, "#     pattern = Role_Name\n")
	w(&b, "#\n")
	w(&b, "# Every line of every file you open is scanned for `pattern`, and each\n")
	w(&b, "# match is drawn in the colour the current theme gives `Role_Name`.\n")
	w(&b, "#\n")
	w(&b, "# --- the four things worth knowing before you write one --------------------\n")
	w(&b, "#\n")
	w(&b, "# 1. PATTERNS ARE LITERAL TEXT, NOT REGULAR EXPRESSIONS.  `^ERROR` matches\n")
	w(&b, "#    a caret followed by ERROR, and `.*` matches a dot followed by a star.\n")
	w(&b, "#    There is no anchoring, no wildcard and no character class. This is not\n")
	w(&b, "#    an omission: these rules run over every visible line on every frame,\n")
	w(&b, "#    and a regex engine there would cost more than the whole rest of the\n")
	w(&b, "#    frame does.\n")
	w(&b, "#\n")
	w(&b, "# 2. MATCHING IS CASE-SENSITIVE.  `ERROR` and `error` are two different\n")
	w(&b, "#    rules -- write both lines if you want both.\n")
	w(&b, "#\n")
	w(&b, "# 3. SYNTAX HIGHLIGHTING WINS.  Where a file has a real lexer (.json, .c,\n")
	w(&b, "#    .md and about thirty more) its colours stay, and a rule that would\n")
	w(&b, "#    overlap one of them is skipped for that match. Clickable links win over\n")
	w(&b, "#    both.\n")
	w(&b, "#\n")
	w(&b, "#    THAT INCLUDES .log FILES, which is the surprising part and worth\n")
	w(&b, "#    knowing before you write your first rule. Newtpad's log lexer already\n")
	w(&b, "#    colours these six words by itself:\n")
	w(&b, "#\n")
	w(&b, "#        ERROR   WARNING   WARN   INFO   DEBUG   TRACE\n")
	w(&b, "#\n")
	w(&b, "#    so a rule for any of them changes nothing on a .log -- the lexer got\n")
	w(&b, "#    there first, and it is already doing the job. Rules are for the words\n")
	w(&b, "#    it does NOT know: your service names, request ids, hostnames, FATAL,\n")
	w(&b, "#    TODO, or whatever your own logs happen to shout. On a .txt, where\n")
	w(&b, "#    there is no lexer at all, every rule shows.\n")
	w(&b, "#\n")
	w(&b, "# 4. THE COLOUR IS A ROLE, NOT AN RGB.  That is why the same file reads\n")
	w(&b, "#    correctly in the Dark and the Light theme, and why editing a theme\n")
	w(&b, "#    recolours your rules with it. The full list of role names is at the\n")
	w(&b, "#    bottom of this file.\n")
	w(&b, "#\n")
	w(&b, "# --- the small print -------------------------------------------------------\n")
	w(&b, "#\n")
	w(&b, "# A line starting with # is a comment, so a pattern cannot begin with one:\n")
	w(&b, "# match TODO rather than #TODO.\n")
	w(&b, "# If the same pattern appears twice, THE LAST LINE WINS.\n")
	w(&b, "# Where two different patterns match at the same spot, the LONGER one wins.\n")
	strings.write_string(&b, fmt.tprintf("# At most %d rules are used, and a pattern may be at most %d bytes long.\n", RULES_MAX, RULES_PATTERN_MAX))
	w(&b, "# A line that cannot be understood is ignored and noted in the log\n")
	w(&b, "# (View > Open Logs Folder). Nothing in this file is ever fatal, and\n")
	w(&b, "# deleting the file removes every rule.\n")
	w(&b, "#\n")
	w(&b, "# --- a starting point, all commented out -----------------------------------\n")
	w(&b, "#\n")
	w(&b, "# These show on a .log, because the log lexer does not know them:\n")
	w(&b, "#\n")
	w(&b, "# FATAL    = Danger\n")
	w(&b, "# TODO     = Accent\n")
	w(&b, "# FIXME    = Warning\n")
	w(&b, "#\n")
	w(&b, "# These do NOT show on a .log -- see rule 3 above, the lexer already\n")
	w(&b, "# colours them -- but they do show on a .txt:\n")
	w(&b, "#\n")
	w(&b, "# ERROR    = Danger\n")
	w(&b, "# WARN     = Warning\n")
	w(&b, "# WARNING  = Warning\n")
	w(&b, "# INFO     = Success\n")
	w(&b, "# DEBUG    = Text_Muted\n")
	w(&b, "# TRACE    = Text_Muted\n")
	w(&b, "#\n")
	w(&b, "# --- every colour role ------------------------------------------------------\n")
	w(&b, "#\n")
	w(&b, "# Case does not matter, and Syn_Keyword and syn_keyword are the same name.\n")
	w(&b, "# The Bg_* roles are BACKGROUND colours -- a rule using one draws text you\n")
	w(&b, "# cannot read against the page. They are listed for completeness.\n")
	w(&b, "#\n")
	for role in Color_Role {
		strings.write_string(&b, fmt.tprintf("#     %v\n", role))
	}
	return strings.to_string(b)
}

// Edit Colour Rules: writes the seeded file if there isn't one, then opens it as
// a tab -- the loop Edit Current Theme... (§6x) and Edit Keybindings... (§6ad)
// already give the theme and the keymap, for the same reason. A documented file
// format nobody has a file for is not a feature.
//
// An existing file is never overwritten: the user's rules are the thing this
// command exists to let them edit. Saving it re-reads it (rules_reload_if_active
// via save_checked), so a rule can be tried without restarting.
rules_edit_current :: proc(app: ^App) -> bool {
	path, ok := rules_path()
	if !ok {
		app_note(app, "[RULES.TXT NOT AVAILABLE - the settings folder could not be found]")
		return false
	}
	if !os.exists(path) {
		seed := rules_seed_text(context.temp_allocator)
		if os.write_entire_file(path, transmute([]u8)seed) != nil {
			app_error(app, "Could not write rules.txt: the settings folder is not writable")
			return false
		}
	}
	app_open_path(app, path)
	return true
}
