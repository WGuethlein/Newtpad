# Audit 03 — search & syntax (find.odin, highlight.odin, rules.odin, lex_index.odin, src/base/lex_*.odin)

Read-only pass, 2026-08-04. Scope files read in full except `lex_c.odin` (read: header, all
scanners, `lex_c`, `lex_c_resync_valid`, keyword-set inventory). Cross-checked against
`HANDOFF.md`, `docs/reported-bugs.md`, `docs/requested-features.md`,
`docs/odin-regex-capture-bug.md`.

**Already recorded, not re-reported:** `docs/reported-bugs.md:78` — a find match starting exactly
at a wrap point highlights on the earlier row. Finding 3 below is a *different, larger* defect in
the same procedure that the recorded fix (`< end` instead of `<= end`) does not touch; it is called
out as such.

---

### [HIGH] Any edit permanently kills the lex-state index, and for Markdown/YAML/Rust/Odin the fallback resync is guaranteed to return `.Normal`
**Where:** `src/program/lex_index.odin:162-171` (`lex_index_valid`), `src/program/lex_index.odin:133-143` (`lex_index_start`), `src/program/lex_index.odin:542-545` (cap-hit), `src/base/lex_markdown.odin:462` and `src/base/lex_yaml.odin:345` (validators that always return `false`), `src/base/lex_c.odin:870` (same for `nest_comments`)
**Confidence:** CONFIRMED
**Fix risk:** RISKY

**Mechanism:** three independent facts compose into a wrong colour.

1. `lex_index_valid` returns false the moment `doc.revision != idx.built_for_revision` — i.e. after
   the first keystroke in the document.
2. The index is never rebuilt: `lex_index_start` returns early on `doc.lex_idx.th != nil`
   (line 134), and only `doc_close`/`doc_reload` ever nil `th`. So the invalidation is permanent
   for the session.
3. `doc_lex_state_at` then falls through to `lex_resync_state`. For `.md`/`.markdown`/`.mkd`/…
   (8 extensions), `.yaml`/`.yml`, `.rs` and `.odin`, the registered `resync_validate` returns
   `false` unconditionally, so the candidate loop never accepts, `from` stays `-1`, and
   `if win_start != 0 {return .Normal, true}` fires. `win_start != 0` whenever
   `target > LEX_RESYNC_WINDOW` (64 KiB).

The header comment at `lex_index.odin:43-47` claims the fallback is "correct at any revision …
just slower than an O(log n) lookup". That claim is false for these four grammars: past 64 KiB it
is not slower, it is *wrong*. The always-reject validators are documented as a huge/mapped-file
limitation (`lex_markdown.odin:458-461`, `lex_yaml.odin:40-52`); nothing documents that one
keystroke drops every small file into the same regime.

**Failure scenario:** open a 200 KB `notes.md` containing a fenced block

```
    ## Setup                     <- byte ~150,000
    ```json
    { "url": "https://x", "n": 1_000 }
    ```
```

Scroll to it — fence colouring is correct (background index is valid). Now type one character
anywhere in the file, then scroll back. `doc.revision` has moved, `lex_index_valid` is false, and
`doc_lex_state_at(doc, 150000, 64<<10)` cap-hits to `.Normal`. `lex_markdown` is now entered at
`.Normal` inside the fence body, so `## Setup` inside the code block colours as a heading, `_x_`
colours as italic, and the `[text](url)` bracket scan fires on JSON. Same shape on a >64 KB YAML
after an edit: the body of a `|` block scalar is re-parsed as mappings, so every `key:` inside a
literal scalar colours as `Json_Key`.

**Fix:** restart the index instead of abandoning it — on a revision change, `lex_index_stop`,
`clear` the three arrays, re-`lex_index_start` with the new revision, debounced (an idle timer, or
"first frame with no edit for N ms") so a held key doesn't spawn a thread per keystroke. That also
needs the index to read the *live piece table* rather than `doc.original`, which today it does not
(`lex_index.odin:138`) — which is why this is RISKY and wants a design pass, not a patch. A cheap
interim: when `lex_index_valid` is false **and** the extension's validator is one of the
always-reject ones, do not claim `.Normal` — the honest degradation is to lex forward from the
nearest byte-0-reachable point or to leave the previous frame's state, not to assert a state the
code knows it cannot compute.

---

### [HIGH] Whole-word literal search accepts a false match at every scan-block boundary
**Where:** `src/program/find.odin:771` (buffer size), `find.odin:792` (read length), `find.odin:820-825` (the `after` test)
**Confidence:** CONFIRMED
**Fix risk:** SAFE

**Mechanism:** the block read overlaps forward by exactly `len(q)-1` bytes — enough for a match to
be *found* across the boundary, one byte short of what whole-word needs to *judge* it. The buffer
is `make([]u8, SEARCH_BLOCK + len(q) - 1)` and the read is `min(bs + len(q) - 1, L - pos)`, so for
a non-final block `got == bs + len(q) - 1`. The last candidate position is `k == bs-1`, whose match
ends at `buf[got-1]`; the byte after it sits at index `got`, which was never read. The guard
`if k + len(q) < got {after = buf[k + len(q)]}` is then false, `after` stays `0`,
`is_word_byte(0)` is false, and the match is accepted as a whole word.

The final block is fine (`after == 0` genuinely means end-of-file there), which is why every
existing test passes: `test_modes.odin:30178-30212` runs the whole-word fixture on a 39-byte
in-memory document, where the first block is also the last.

**Failure scenario:** a 1 MB `.log`. Query `cat`, whole-word chip ON, case chip off. The bytes
`cats` begin at offset 65535 (the first-paint budget edge, `SEARCH_FIRST_PAINT = 65536`) or at
`65536 + 262144·k - 1` (each worker block edge). `cat` is reported as a whole-word match and
highlighted, and Enter jumps to it — inside the word `cats`. `find_status_info` counts it. Every
other `cats` in the file is correctly excluded, so the result set is internally inconsistent.

**Fix:** size the buffer `SEARCH_BLOCK + len(q)` and read
`min(bs + len(q), L - pos)`. `limit` is unaffected (`min(bs, got-len(q)+1)` becomes `min(bs, bs+1)`
= `bs`), and `prev = buf[bs-1]` is unaffected. Then reintroduce the one-byte shortfall and watch a
new findtest case (plant `cats` at `SEARCH_FIRST_PAINT - 1` on a >64 KB fixture, assert 0 matches)
go red — findtest already plants a straddler at `SEARCH_FIRST_PAINT - 4` for the literal-overlap
case, so the fixture shape exists.

---

### [HIGH] A find match that spans two visual rows is highlighted on the first row only
**Where:** `src/program/find.odin:1661-1674` (`find_match_rects`), contrast `src/program/doc.odin:4285-4295` (`doc_selection_rects`)
**Confidence:** CONFIRMED
**Fix risk:** SAFE

**Mechanism:** the inner loop takes a match into a row when `f.matches[mi] <= end`, emits **one**
rect clipped to `min(m + f.match_len[mi], vis_end)`, then does `mi += 1`. A match whose end is past
`vis_end` therefore never gets a second rect on the next row — the cursor has already moved past
it. `doc_selection_rects`, walking the identical iterator two files over, uses the range test
`lo <= end && hi > start` and so re-emits on every row a range touches.

This is *not* the recorded bug (`docs/reported-bugs.md:78`). That entry is about which row a match
starting exactly at the break offset attributes to, and its proposed fix (`< end` for a non-line-end
wrapped row) is correct and orthogonal. This one survives that fix.

It also fires without word wrap: `visible_next` splits any logical line longer than
`RENDER_LINE_CAP` (8192) into capped rows (`doc.odin:1214`), so a match straddling an 8 KiB cap
boundary in a minified `.json` is truncated the same way.

**Failure scenario:** word wrap on, `view_cols` 80. Line: 200 characters of prose. Search for the
28-character phrase beginning at column 62. Row 0 shows a dim highlight from column 62 to column
80; row 1 shows the remaining 10 characters of the phrase with **no** highlight at all. Pressing
Enter to select it draws the selection correctly on both rows (different producer), so the two
highlights for the same bytes disagree on screen.

**Fix:** mirror `doc_selection_rects` — iterate matches with a range test and do not advance `mi`
until `m + match_len[mi] <= end`; emit a clipped rect per row the match touches. `out` is
already bounds-checked (`n < len(out)`), and the caller sizes it per frame.

---

### [MEDIUM] Find-next wraps to the top at the *published* prefix while a large search is still scanning
**Where:** `src/program/find.odin:1436-1448` (`find_next`/`find_prev`)
**Confidence:** CONFIRMED
**Fix risk:** RISKY

**Mechanism:** `f.current = (f.current + 1) % len(f.matches)`, and `f.matches` is
`s.matches[:count]` — the prefix the worker has published *so far* (`find_merge`, `find.odin:606`).
The worker publishes once per 256 KB block, so on a multi-GB file `len(f.matches)` grows over
seconds. Nothing distinguishes "this is the last match" from "this is the last match found yet".
The same modulo also wraps permanently at `MAX_MATCHES` (100,000) once `truncated` is set — that
half is surfaced by the `+` in `find_status_info` (`find.odin:1907`), but the mid-scan half is not
surfaced anywhere.

**Failure scenario:** open a 2 GB `.log`, Ctrl+F `timeout`, press Enter repeatedly. After ~8
presses the caret jumps back to the first match near the top of the file, while the scrollbar
match marks keep growing further down. Matches between the wrap point and end-of-file are skipped
on that pass; a second pass a few seconds later reaches them, so the behaviour is non-deterministic
from the user's side.

**Fix:** refuse the wrap while `search_running(doc)` — stay on the last match (or say "searching…"
in the status text) rather than looping. `search_running` already exists and is already what the
main loop polls on. Behavioural, so it wants a decision on what the last-match keypress should do.

---

### [MEDIUM] Every find keystroke allocates a 256 KB block buffer (320 KB + an arena in regex mode) regardless of file size
**Where:** `src/program/find.odin:771` (`make([]u8, SEARCH_BLOCK + len(q) - 1)`), `find.odin:863` (`make([]u8, SEARCH_BLOCK + REGEX_LINE_SLACK + 1)`), `find.odin:872-874` (`mem.dynamic_arena_init`)
**Confidence:** CONFIRMED
**Fix risk:** SAFE

**Mechanism:** `find_query_changed` → `find_recompute` → `scan_all` runs the inline pass on the
**main thread** on every keystroke. `scan_literal` unconditionally allocates a full `SEARCH_BLOCK`
(256 KiB) buffer even when the budget is `SEARCH_FIRST_PAINT` (64 KiB) or the whole document is
100 bytes. `scan_regex` allocates 320 KiB plus initialises and destroys a `mem.Dynamic_Arena`.
Then the worker path allocates the same again on its own thread. The block buffer's *size* is
never a function of `upto` or `pt.length`, only of the constant.

**Failure scenario:** hold a key in the find bar on a 2 KB `.env` file. Each of the ~30
repeats/second does a 256 KiB heap alloc + free on the main thread — 7.5 MB/s of allocator traffic,
and (`find.odin:865-871` says this explicitly for the regex path) contention on the process heap
lock with whatever else the frame is allocating. Nothing about it is visible; it is pure waste.

**Fix:** `bufsz := min(SEARCH_BLOCK, max(upto, 0), pt.length) + len(q) - 1` (clamped ≥ `len(q)`),
same shape for `scan_regex`. Mechanical and local; the loop's `bs` computation already clamps to
`upto - pos` independently.

---

### [MEDIUM] The post-edit resync runs its full three-term worst case every frame, and YAML's `"\n"` anchor makes every newline a candidate
**Where:** `src/program/lex_index.odin:437-540` (`lex_resync_state`), `lex_index.odin:273-274` (YAML registered with anchor `"\n"` + always-reject validator), `src/program/doc.odin:5056` and `doc.odin:5084` (the two call sites)
**Confidence:** CONFIRMED
**Fix risk:** SAFE (bound the anchor), RISKY (fix the underlying invalidation — see finding 1)

**Mechanism:** consequence of finding 1's cause, but a distinct cost. Once the index is stale,
`doc_draw` calls `lex_resync_state` once per frame (contiguous viewport) or **once per visible row**
(filter view, `doc.odin:5052-5056`). Its own header names the honest worst case as
`window + LEX_RESYNC_MAX_VALIDATE_BYTES + window`. For a grammar whose validator always rejects,
that worst case is the *only* case — the loop always runs to `LEX_RESYNC_MAX_CANDIDATES` (256) or
`LEX_RESYNC_MAX_VALIDATE_BYTES` (64 KiB), never to an accept.

YAML is the extreme: its anchor is `"\n"`, so *every newline in the window is a candidate*. A 64
KiB window of 40-byte YAML lines holds ~1,600 candidates; the loop tries 256 of them, each doing a
`pt_line_start_cap` + `pt_line_end_cap` + `pt_read`, and only stops on the try-count cap. This is
CLAUDE.md's viewport-first rule being paid for by a constant rather than by the viewport.

**Failure scenario:** a 3 MB `docker-compose.yaml`. Type one character. From then on, every frame
does a 64 KiB piece-table read + 256 line reads + a 64 KiB forward lex — ~150 KiB of scanning per
frame, ~9 MB/s at 60 Hz, all of it thrown away because the validator can never accept. In filter
view (Ctrl+L) the same work runs per visible row against the 4 KiB window: 50 rows × (4 KiB + up to
64 KiB validation) per frame.

**Fix:** when `resync_validate` is one of the unconditional-reject ones, skip the candidate loop
entirely and go straight to the `win_start == 0 ? byte-0 : cap-hit` decision — the loop's outcome is
already known. That is one branch and it removes the whole validation term. The real fix is
finding 1.

---

### [MEDIUM] Five duplicated number scanners have drifted; YAML and CSV silently refuse scientific notation
**Where:** `src/base/lex_yaml.odin:123-137` (`ym_scan_number`), `src/base/lex_delimited.odin:72-88` (`ld_field_is_number`), vs `src/base/lex_json.odin:70-102`, `src/base/lex_config.odin:105-127`, `src/base/lex_c.odin:432-510`
**Confidence:** CONFIRMED
**Fix risk:** SAFE

**Mechanism:** each lexer carries its own copy of "scan a plausible number", per the batch's
stated per-file convention. They have diverged on three axes with no comment acknowledging it:

| scanner | leading `-` | `.5` | exponent |
|---|---|---|---|
| `lj_scan_number` (json) | yes | yes | yes |
| `cf_scan_number` (ini/toml/env/conf) | yes | no | yes |
| `ym_scan_number` (yaml) | yes | no | **no** |
| `ld_field_is_number` (csv/tsv) | yes | no | **no** |
| `lc_scan_number` (11 C-family) | **no** | yes | yes |
| `sh_scan_number` (sh/bat/ps1) | **no** | no | **no** |

**Failure scenario:** `timeout: 1e-9` in a `.yaml`. `ym_scan_number` consumes only `1`, emitting a
one-byte Number token; `e` then falls into the alpha branch (`lex_yaml.odin:309-319`), forms the
word `e`, fails the keyword list, and emits nothing. On screen: the `1` is coloured as a number and
`e-9` is plain text on the same literal. Same value in a `.toml` colours whole. In `.csv`,
`ld_field_is_number` returns false for the whole field `1.5e3`, so a scientific-notation column
gets no Number colour at all while the integer column beside it does.

**Fix:** give `ym_scan_number` and `ld_field_is_number` the exponent clause `cf_scan_number`
already has (six lines each), or promote one lenient scanner to a shared `base` helper and
parameterise the three flags. Either is mechanical; the table above is the test matrix.

---

### [LOW] `mk_leading_spaces` never advances over a tab, contradicting its own comment
**Where:** `src/base/lex_markdown.odin:72-77`
**Confidence:** CONFIRMED
**Fix risk:** SAFE

**Mechanism:** the comment says "Tabs count as one space here, an approximation". The loop is
`for n < len(line) && n < 4 && line[n] == ' '` — a tab terminates it, so `lead` is 0 and
`line[lead]` is `'\t'`. `mk_match_fence` (`lex_markdown.odin:101-108`) then reads `ch := line[lead]`,
sees `'\t'`, and returns 0.

**Failure scenario:** a tab-indented Markdown file (a fenced block inside a tab-indented list item):

```
-\t```json
-\t{ "a": 1 }
-\t```
```

Neither fence toggles `Lex_State`, so the JSON body is lexed as ordinary Markdown, and — because
the *closing* fence is also missed — nothing downstream goes wrong either. The bug is silent: the
construct is simply invisible to the lexer, and the comment says it should not be. `mk_match_hr`,
`mk_match_heading` and `mk_is_space` all *do* treat `\t` as space, so the file is internally
inconsistent about it too.

**Fix:** decide one way and make the comment match. Either count `\t` in `mk_leading_spaces`
(matching the comment and the rest of the file) or delete the claim and state that a tab-indented
block marker is not recognised.

---

### [LOW] Backslash escaping is applied to single-quoted strings in formats that have no escapes
**Where:** `src/base/lex_config.odin:85-97` (`cf_scan_quoted`), `src/base/lex_yaml.odin:105-117` (`ym_scan_quoted`)
**Confidence:** CONFIRMED
**Fix risk:** SAFE

**Mechanism:** both scanners take `q := line[i]` and then run one escape rule — `\` + any byte —
for both quote characters. TOML *literal* strings (`'…'`) define no escape at all; YAML
single-quoted scalars escape a quote by doubling it (`''`), not with a backslash. `lex_shell.odin`
gets this right and parameterises it (`Shell_Set.sq_doubled_escape`, `dq_backslash_escape`); these
two do not.

**Failure scenario:** `.env` / `.toml` line `TOOLS = 'C:\build\tools\'`. `cf_scan_quoted` sees
`\b`, `\t`, and then `\'` — consuming the closing quote — runs off the end, returns 0, and the
caller colours `len(line) - i` bytes to end-of-line (`lex_config.odin:227`). Everything after the
value on that line, including a trailing `# comment`, colours as string. Bounded to the one line
(these lexers are line-local), which is why it is LOW.

**Fix:** give `cf_scan_quoted`/`ym_scan_quoted` the same two-flag shape `sh_scan_dquote`/
`sh_scan_squote` already have: no escape for `'` in TOML, doubled-quote escape for `'` in YAML.

---

### [LOW] Case-insensitive find is ASCII-only, and nothing on screen says so
**Where:** `src/program/find.odin:200` (`lower`), `find.odin:768` (the fold), `find.odin:944` (regex mode delegates to `regex.Flags{.Case_Insensitive}`)
**Confidence:** CONFIRMED
**Fix risk:** RISKY

**Mechanism:** `lower` maps `A`–`Z` only. UTF-8 lead and continuation bytes are all ≥ 0x80 and pass
through untouched, so there is no corruption — but there is also no folding. The file header
states "case-insensitive, ASCII-fold" and `is_word_byte` (`find.odin:158-166`) carries a careful
note about the same limit for whole-word; the *user-facing* `Aa` chip carries none.

Note the asymmetry: literal mode folds ASCII only, regex mode hands
`regex.Flags{.Case_Insensitive}` to `core:text/regex`, which may fold more. The same query in the
two modes can therefore return different match counts on non-ASCII text.

**Failure scenario:** a `.md` with both `Café` and `CAFÉ`. `Aa` off (fold on), query `café` →
1 match, not 2. Turn the `.*` chip on with the same query → potentially 2, depending on what the
stdlib folds. Nothing distinguishes "no such word" from "we do not fold that alphabet".

**Fix:** either fold via `core:unicode` on the decoded rune (costs a decode per byte on the hot
scan — needs measuring against the numbers in `SEARCH_FIRST_PAINT`'s comment), or state the limit
in the `Aa` chip's tooltip/help. Not a silent change either way.

---

## Checked and found sound (recorded so the next pass does not redo it)

- **Replace-all offset drift.** `find_replace_all` applies last→first (`find.odin:1625`), computes
  every `$`-expansion before the first splice against the untouched buffer (`find.odin:1609-1617`),
  and drops overlapping matches through `find_keep_set` with a `max(len,1)` barrier for
  zero-length regex matches (`find.odin:1515-1525`). No drift, no double-insert, one undo entry.
- **The documented Odin regex capture bug.** `find_subst_one` bypasses `regex.match*` and reads
  `saved` from `rx_vm.run` directly (`find.odin:1397-1403`), sizes `pos` from the *program*'s
  `Save` operands rather than from the compacted `Capture` (`find_subst_groups`,
  `find.odin:1233-1241`), and verifies the re-matched span before trusting any group
  (`find.odin:1398`). The workaround matches what `docs/odin-regex-capture-bug.md` prescribes.
- **Token byte ranges.** Every emit in all nine lexers was checked against `len(line)`:
  `lc_scan_raw_string` (Cpp arm), `lc_scan_regex`, `lx_scan_tag_rest`'s quoted value,
  `mk_scan_bold`/`mk_scan_italic`, the markdown link arm, `lj_scan_string`, `cf_scan_section`.
  None can produce `start + len > len(line)`.
- **State past the token cap.** All five stateful lexers guard emits with `n < len(out)` and keep
  scanning (`lex_xml.odin:189-199`, `lex_c.odin:519-525`, `lex_shell.odin:220-223`,
  `lex_yaml.odin:206-210`, `lex_markdown.odin:213-218`). The four line-local ones stop scanning at
  capacity, which is sound because their `state_out` is unconditionally `.Normal`.
- **Publication protocol.** Fixed-capacity result arrays, worker-writes-then-stores-`count`,
  reader-loads-`count`-then-reads-below-it, and the deliberate `scanned`/`done` before `count`
  ordering in `find_merge` (`find.odin:585-596`) are all correct as written.
- **One-layout rule.** `find_match_rects` consumes `visible_begin`/`visible_next`, `line_cell_col`,
  `row_indent_cells` and `col_x` — the same four producers the draw, the caret and
  `doc_selection_rects` use. `find_toggles`/`find_toggle_at` and `find_actions`/`find_action_at`
  are genuine single-producer pairs. The only divergence found is finding 3, which is a *rule*
  difference (per-match vs per-range), not a second geometry.
- **Test coverage.** All nine lexers have `@(test)` coverage in `src/base` (`lex_test.odin` covers
  `lex_log` and `lex_json`; the other seven have their own files). Findings 2 and 3 are the two
  real gaps: whole-word is only tested on a 39-byte fixture, and `find_match_rects` is only tested
  through `findtest`'s wrap fixture, which the recorded bug entry shows was itself misread.

---

## MARKETABLE

Six things that are real, verified in the tree, with their honest limit stated.

1. **Filter-as-you-type: type a word, keep only the lines that contain it.**
   Ctrl+L turns the whole file into just the matching lines, live, with real line numbers in the
   gutter, and clicking a row jumps back to that line in the full document.
   *Evidence:* `find.odin:1781-1882` (`filter_searching`, `filter_banner_text`, `find_set_filter`,
   `find_filter_click`), filter rows built during the scan at `find.odin:610-621`.
   *Limit:* the list fills in as the scan progresses on a large file — the banner says
   "searching…" rather than pretending an empty list means no matches — and it stops at 100,000
   matches (`MAX_MATCHES`, `find.odin:22`), which the counter marks with `+`.

2. **A keystroke in the find box never waits on the file.**
   The first 64 KiB is searched on the spot so the frame you typed into already shows results; the
   rest goes to a background thread that publishes incrementally and resumes exactly where the
   first pass stopped — no byte is scanned twice, and the tree asserts it (`Search.swept`).
   *Evidence:* `find.odin:34-111` (the budget and its measurement), `find.odin:548-562` (the
   handoff), `find.odin:696-700` (`find_swept`). Measured in-tree at that budget, `-o:speed`:
   0.10 ms literal, 0.29 ms ordinary regex on an 8 MB buffer.
   *Limit:* regex uses a backtracking engine, so a deliberately pathological pattern costs ~11 ms
   for that same first paint (`find.odin:88-93`) — stated in the code, not hidden.

3. **Syntax colouring for 38 file extensions out of the box, no plugins, no config.**
   Nine hand-written lexers cover them: 11 separate C-family keyword vocabularies (C, C++, C#,
   Java, JavaScript, TypeScript, Go, Rust, Odin, CSS, SQL), 3 shell dialects (bash, Windows batch,
   PowerShell), plus JSON, XML/HTML, Markdown, YAML, CSV/TSV, six config formats
   (ini/toml/cfg/conf/env/gitignore) and a pattern lexer for `.log`.
   *Evidence:* `highlight.odin:239-278` — 38 entries, counted; 11 `Keyword_Set` tables in
   `lex_c.odin:912-1842`; 3 `Shell_Set` tables in `lex_shell.odin:436-503`.
   *Limit:* `.txt` and `.py` deliberately have no lexer and the tree says so out loud
   (`highlight.odin:338-361`) — Python is named as an owed gap rather than force-fitted into a
   grammar that does not match it. And see finding 1: multi-line constructs in Markdown/YAML/
   Rust/Odin lose state past 64 KiB once the file has been edited.

4. **Find and replace with real regular expressions, including capture groups in the replacement.**
   `$1`, `${12}`, `$&`, `$$` work the way VS Code / .NET / JavaScript do, including the awkward
   corners: `$5` against a two-group pattern stays literal, an optional group that did not fire
   substitutes empty.
   *Evidence:* `find.odin:1025-1192` (the token grammar and the two standards it cites),
   `find.odin:1338-1406` (the windowed re-match, with `\b` and `$` made to see real document
   context).
   *Limit:* the underlying engine caps a pattern at 9 capture groups and has no lookaround
   (`docs/odin-regex-capture-bug.md:150-158`); `^` is block-relative rather than line-relative
   (`find.odin:1321-1327`).

5. **Every match marked on the scrollbar, on a 200 MB file, for a few hundred quads.**
   The track shows where the hits are, so a file's shape is visible before you step through it —
   and the marks are bucketed per pixel row, so 100,000 matches cost one quad per occupied pixel,
   not 100,000 quads per frame.
   *Evidence:* `find.odin:1719-1779` (`find_mark_cap`, `mark_bucket_h`, `find_mark_rects`); the
   mapping is deliberately the same arithmetic the scrollbar thumb uses (`find.odin:1686-1705`).
   *Limit:* the mark set is whatever the scan has published; a truncated set is reported once, in
   the `+` on the counter, and not a second time on the track.

6. **Colour your own keywords in any file, themed, without restarting.**
   `rules.txt` — one `pattern = Role_Name` per line — colours your service names, request ids or
   `FATAL` in files that have no lexer at all. Save the file and the next frame is recoloured;
   switch theme and the rules follow, because a rule names a colour *role*, not an RGB.
   *Evidence:* `rules.odin:354-417` (the scan), `rules.odin:469-486` (save-to-reload),
   `rules.odin:16-21` (role, not RGB).
   *Limit:* patterns are literal text, not regex, and matching is case-sensitive — both stated in
   the file Newtpad seeds for you (`rules.odin:510-518`). At most 64 rules of ≤64 bytes, and a
   real lexer's colours win over a rule where the two overlap (`highlight.odin:481-487`).
