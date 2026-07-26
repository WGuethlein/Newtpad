# Theme Tuning Loop Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give Dark real syntax colours, and give Wyatt a loop where he edits a theme file inside Newtpad, saves, and sees the colours change without a rebuild.

**Architecture:** One `[Color_Role]string` total array becomes the single source of truth for role↔key naming, so the file writer and the file parser cannot drift. An "Edit Current Theme" command exports the active theme to `%APPDATA%\Newtpad\themes\<name>.theme`, switches to it, and opens it as a tab. A single `theme_reapply_if_active` helper, called after a successful save and after an external-change reload, re-resolves `g_theme` when the written path is that file.

**Tech Stack:** Odin (`dev-2026-07a`), Win32, no new dependencies. All changes in `src/program/`.

Spec: [`docs/superpowers/specs/2026-07-26-theme-tuning-loop-design.md`](../specs/2026-07-26-theme-tuning-loop-design.md).

## Global Constraints

- **Git identity:** every commit is authored solely by Wyatt Guethlein. Never add `Co-Authored-By: Claude`, "Generated with Claude Code", a robot emoji, or any other AI attribution to any commit message. `.claude/settings.json` sets `includeCoAuthoredBy: false` — do not override it.
- **Commit style:** imperative subject under ~65 chars; body only when the *why* isn't obvious from the diff. No changelog dumps.
- **Build:** `build.bat` (debug, console subsystem). A bare `odin build` is wrong — it omits the DPI manifest and the SEH shim. The exe lands at `build\newtpad.exe`, not the repo root.
- **Tests:** always `set NEWTPAD_SESSION_DIR=<temp dir>` before running any headless mode, or it writes to the real store under `%APPDATA%\Newtpad`.
- **`Select-String "FAIL"` is case-insensitive** and matches "0 failures". Use `-CaseSensitive`.
- **Never run `drawcount`** — it opens a real window, hangs, and locks the exe so the next build fails.
- **Every commit must compile.** If you change a signature and its callers, they go in the same commit.
- **Sabotage discipline (CLAUDE.md):** for every test you add, reintroduce the bug, run the test, watch it fail, capture the exact output, restore the fix. "I verified it fails" without the captured output is not evidence.
- **ASCII only in `.ps1` files.** PowerShell 5.1 decodes a BOM-less `.ps1` as ANSI, so a non-ASCII literal is mojibake before the script runs.
- Odin comments in this codebase use `--`, not em dashes, in source files.

---

## File Structure

| File | Responsibility | Change |
|---|---|---|
| `src/program/theme.odin` | Colour model, role↔key naming, theme files, export | Modify — Dark's 9 `Syn_*` values, `theme_role_keys`, `theme_role_from_key` rewrite, `theme_key_from_role`, `theme_export`, `theme_active_file_path`, `theme_reapply_if_active`, `theme_available_names` guard |
| `src/program/commands.odin` | Command table, keymap, dispatch | Modify — `Theme_Edit` command id, table entry, dispatch case, `save_checked` re-apply hook |
| `src/program/menu.odin` | Menu bar | Modify — View menu entry |
| `src/program/main.odin` | Frame loop, status bar, drop consumer | Modify — reload re-apply hook, `warn` includes a live notice, folder-note wording |
| `src/program/test_modes.odin` | Headless harness | Modify — new `themetest` cases |

---

## Task 1: Dark's nine syntax colours

**Files:**
- Modify: `src/program/theme.odin:227-235` (the nine placeholder values), `src/program/theme.odin:138-144` (the stale enum comment)
- Test: `src/program/test_modes.odin` (`themetest`)

**Interfaces:**
- Consumes: nothing from other tasks.
- Produces: nothing other tasks depend on. `theme_dark()` keeps its signature `proc() -> Theme`.

**Context.** `theme_dark()` currently returns `{1, 0, 1, 1}` — pure magenta — for all nine `Syn_*` roles. That was a deliberate "missing texture" marker planted in batch 3 for roles nothing consumed yet. Batch 4 shipped the lexers that consume them and never replaced the marker, so every highlighted file renders identically magenta in Dark. Light was filled in (`theme.odin:334`).

Values below mirror Light's hue family per role, re-tuned for Dark's `Bg_Base` (`#1A1F29`). Contrast ratios are WCAG relative-luminance ratios against `Bg_Base`, computed — this environment cannot render a frame, so computation is the only available standard, and it is the one batch 3 used for Light.

- [ ] **Step 1: Write the failing tests**

Add to `themetest` in `src/program/test_modes.odin`, immediately after the existing "Every role must be non-zero" loop (which ends at the closing brace of `for role in Color_Role { ... }`, around line 2774):

```odin
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
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
build.bat
```

Then:

```bash
set NEWTPAD_SESSION_DIR=%TEMP%\np_t1 && build\newtpad.exe themetest
```

Expected: nine `FAIL   Syn_* is still the magenta placeholder in Dark` lines, plus `FAIL   Dark Syn_Comment vs Text_Muted` (magenta vs `Text_Muted` actually differs by more than 0.10, so that one may pass — the placeholder lines are the ones that must fail). Record the exact output.

- [ ] **Step 3: Replace the nine placeholder values**

In `src/program/theme.odin`, replace lines 227-235 with:

```odin
		// Light's hue family per role, re-tuned for this theme's Bg_Base
		// (#1A1F29). Ratios are WCAG relative luminance against Bg_Base,
		// computed rather than eyeballed -- this environment cannot render a
		// frame, and computation is the standard theme_light already used.
		// Every token colour clears 4.5:1 except Syn_Comment, which is
		// deliberately de-emphasised and clears 3:1: a comment that shouts is
		// a worse outcome than a comment that is slightly dim.
		//
		// Syn_Comment is pulled away from Text_Muted (#808CA3) on purpose --
		// the gutter line numbers are Text_Muted and sit directly beside
		// comment text. Light deliberately placed those two close together;
		// Dark must not, because Dark is the theme with the gutter beside it
		// in daily use. Syn_Punct is likewise kept clear of Text_Primary.
		// themetest asserts both separations.
		.Syn_Keyword    = {0.56, 0.66, 1.00, 1}, // #8FA8FF -- periwinkle (Light: indigo #3B5BDB), 7.4:1
		.Syn_String     = {0.56, 0.85, 0.66, 1}, // #8FD9A8 -- soft green (Light: green #17824E), 10.1:1
		.Syn_Number     = {0.96, 0.72, 0.48, 1}, // #F5B87A -- peach (Light: burnt orange #B5560A), 9.5:1
		.Syn_Comment    = {0.43, 0.52, 0.47, 1}, // #6E8578 -- sage grey (Light: slate #707A88), 4.2:1
		.Syn_Type       = {0.44, 0.83, 0.88, 1}, // #70D4E0 -- cyan (Light: teal #0B7285), 9.5:1
		.Syn_Punct      = {0.60, 0.65, 0.74, 1}, // #99A6BD -- mid neutral (Light: #444B58), 6.7:1
		.Syn_Json_Key   = {0.94, 0.63, 0.54, 1}, // #F0A18A -- salmon (Light: rust #9C4221), 8.0:1
		.Syn_Xml_Tag    = {0.96, 0.55, 0.71, 1}, // #F58CB5 -- pink (Light: rose #B5165A), 7.3:1
		.Syn_Xml_Attr   = {0.77, 0.68, 0.96, 1}, // #C4ADF5 -- lavender (Light: violet #6B4FB6), 8.4:1
```

- [ ] **Step 4: Correct the now-false enum comment**

In `src/program/theme.odin`, replace the block at lines 138-144 (`// --- syntax highlighting (batch 4) ---` through `// before batch 4 lands would be visually obvious instead of invisible.`) with:

```odin
	// --- syntax highlighting ---
	// Declared in batch 3 so batch 4's lexers could emit role names from their
	// first line instead of RGB literals needing migration right after landing.
	// That worked; what did not is that theme_dark kept the loud-magenta
	// "missing texture" placeholder these were given, through the entire batch 4
	// release -- every highlighted file rendered identically magenta in Dark in
	// v0.13.0. Both built-ins now hold real values and themetest fails if either
	// ever holds {1,0,1,1} again.
```

- [ ] **Step 5: Run the tests to verify they pass**

```bash
build.bat
```

```bash
set NEWTPAD_SESSION_DIR=%TEMP%\np_t1 && build\newtpad.exe themetest
```

Expected: `ok     no built-in role holds the magenta placeholder`, and both separation lines `ok` with a diff at or above 0.10. No line matching `FAIL` (check with `-CaseSensitive`).

- [ ] **Step 6: Sabotage-verify, and record the output**

Set `.Syn_Comment` to exactly `{0.50, 0.55, 0.64, 1}` (Text_Muted's value). Rebuild, run `themetest`, and confirm the separation check reports `FAIL` with `max channel diff 0.000`. Paste that line into the task report. Then restore the real value, rebuild, and confirm `ok` again.

- [ ] **Step 7: Commit**

```bash
git add src/program/theme.odin src/program/test_modes.odin
git commit -m "Give Dark real syntax colours instead of the magenta placeholder"
```

---

## Task 2: One source of truth for role names

**Files:**
- Modify: `src/program/theme.odin:418-457` (`theme_role_from_key`)
- Test: `src/program/test_modes.odin` (`themetest`)

**Interfaces:**
- Consumes: nothing from other tasks.
- Produces, relied on by Tasks 3 and 5:
  - `theme_role_keys: [Color_Role]string` — package-level, the total array.
  - `theme_key_from_role :: proc(role: Color_Role) -> string`
  - `theme_role_from_key :: proc(key: string) -> (role: Color_Role, ok: bool)` — signature unchanged from today.

**Context.** `theme_role_from_key` is a 25-case switch; the nine `Syn_*` roles are absent, so they cannot be set from a file. Task 3 needs the inverse mapping to *write* a file. Two hand-maintained 34-case mappings can drift apart silently, so both directions come from one `[Color_Role]string` total array — a missing role is then a compile error, the same guarantee `Theme :: [Color_Role][4]f32` and `[Command_Id]Command` already provide.

- [ ] **Step 1: Write the failing test**

Add to `themetest`, after the separation-check block from Task 1:

```odin
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
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
build.bat
```

Expected: a **compile error**, `undefined name 'theme_key_from_role'`. That is the failing state for this step — the test cannot run until Step 3 introduces the mapping.

- [ ] **Step 3: Replace the switch with a total array**

In `src/program/theme.odin`, replace the whole of `theme_role_from_key` (lines 418-457, comment included) with:

```odin
// The file key for every role, as a TOTAL array over Color_Role: Odin rejects
// an incomplete keyed enumerated-array composite literal at compile time, so a
// role added without a key is a compile error, not a role that silently cannot
// be set from a file. That is exactly what went wrong before -- the nine Syn_*
// roles were absent from the 25-case switch this replaces, so a theme file
// could not touch them, and Dark's placeholders could not be worked around by
// the very file mechanism meant to allow it.
//
// One array serves both directions: theme_key_from_role writes files
// (theme_export), theme_role_from_key reads them (theme_load_file). Two
// hand-maintained mappings would drift, and a drift here is silent.
//
// Keys are the lowercase enum name. "base" is deliberately not a key: it
// selects which built-in theme_load_file overlays onto, it is not a role, and
// it must never be counted or logged as an unrecognized one.
theme_role_keys := [Color_Role]string {
	.Bg_Base        = "bg_base",
	.Bg_Panel       = "bg_panel",
	.Bg_Raised      = "bg_raised",
	.Border_Subtle  = "border_subtle",
	.Border_Strong  = "border_strong",
	.Text_Muted     = "text_muted",
	.Text_Dim       = "text_dim",
	.Text_Secondary = "text_secondary",
	.Text_Primary   = "text_primary",
	.Text_Bright    = "text_bright",
	.Selection_Doc  = "selection_doc",
	.Selection_List = "selection_list",
	.Caret          = "caret",
	.Accent         = "accent",
	.Find_Match_Bg  = "find_match_bg",
	.Link           = "link",
	.Warning        = "warning",
	.Danger         = "danger",
	.Success        = "success",
	.Filter_Bg      = "filter_bg",
	.Filter_Text    = "filter_text",
	.Md_Heading     = "md_heading",
	.Md_Code        = "md_code",
	.Md_Italic      = "md_italic",
	.Md_Quote       = "md_quote",
	.Syn_Keyword    = "syn_keyword",
	.Syn_String     = "syn_string",
	.Syn_Number     = "syn_number",
	.Syn_Comment    = "syn_comment",
	.Syn_Type       = "syn_type",
	.Syn_Punct      = "syn_punct",
	.Syn_Json_Key   = "syn_json_key",
	.Syn_Xml_Tag    = "syn_xml_tag",
	.Syn_Xml_Attr   = "syn_xml_attr",
}

// The file key for a role. Used by theme_export to write a file.
theme_key_from_role :: proc(role: Color_Role) -> string {
	return theme_role_keys[role]
}

// Role name -> Color_Role. An unrecognized name returns ok=false so the caller
// skips that line instead of failing the whole file -- the same "unknown key
// ignored" contract settings_load uses, which is what lets an older build read
// a newer file. A linear scan of 34 entries, run once per line at load time;
// the switch this replaces bought nothing measurable and cost the second
// mapping.
theme_role_from_key :: proc(key: string) -> (role: Color_Role, ok: bool) {
	for k, r in theme_role_keys {
		if k == key {
			return r, true
		}
	}
	return {}, false
}
```

Note: `theme_role_from_key` loses its `@(private = "file")` attribute because `themetest` (in `test_modes.odin`, same package but a different file) now calls it. `theme_parse_hex` keeps its `@(private = "file")`.

- [ ] **Step 4: Run the test to verify it passes**

```bash
build.bat
```

```bash
set NEWTPAD_SESSION_DIR=%TEMP%\np_t2 && build\newtpad.exe themetest
```

Expected: `ok     all 34 role keys are non-empty, unique and round-trip` and `ok     "base" is not a role key`. The pre-existing file round-trip, partial-file, unknown-role and malformed-colour cases must all still print `ok` — they exercise the same parser through a different door.

- [ ] **Step 5: Sabotage-verify, and record the output**

Change `.Syn_String`'s key to `"syn_keyword"` (a duplicate). Rebuild, run, and confirm `FAIL   key "syn_keyword" maps to both Syn_Keyword and Syn_String`. Paste it into the report. Restore, rebuild, confirm `ok`.

Then separately confirm the compile-time guarantee: delete the `.Syn_Xml_Attr` line from `theme_role_keys`, run `build.bat`, and confirm it is a **compile error** rather than a test failure. Record the compiler's message. Restore.

- [ ] **Step 6: Commit**

```bash
git add src/program/theme.odin src/program/test_modes.odin
git commit -m "Derive theme file keys from one total array over Color_Role"
```

---

## Task 3: Export a theme to a file

**Files:**
- Modify: `src/program/theme.odin` (add `theme_active_file_path`, `theme_export`; amend `theme_available_names`)
- Test: `src/program/test_modes.odin` (`themetest`)

**Interfaces:**
- Consumes from Task 2: `theme_key_from_role(role) -> string`, `theme_role_keys`.
- Produces, relied on by Tasks 4 and 5:
  - `theme_active_file_path :: proc(name: string) -> (path: string, ok: bool)` — temp-allocated path of the `.theme` backing `name`; `ok=false` for `"Dark"`, `"Light"`, or when `themes_dir()` is unavailable.
  - `theme_export_target :: proc(name: string) -> string` — the theme name to export the current theme *as*: `"Dark Custom"` for `"Dark"`, `"Light Custom"` for `"Light"`, otherwise `name` unchanged. Temp-allocated or a literal.
  - `theme_export :: proc(from_name: string) -> (target: string, path: string, ok: bool)` — writes the file if it does not exist, never overwrites; returns the target theme name and the file path. `ok=false` only when the directory or the write fails.

- [ ] **Step 1: Write the failing tests**

Add to `themetest`, inside the existing `else` branch that has `tdir` in scope (after the malformed-colour block, before that branch closes):

```odin
			// Export writes every role, and what it writes parses back to the
			// same theme within the 8-bit limit of #rrggbb. The theme is
			// [4]f32 and the file format is 8 bits per channel, so an exact
			// round-trip is impossible by construction -- 0.10 * 255 = 25.5.
			// Two properties make that safe instead of merely lossy: every
			// channel lands within 1/255, and a second export of the parsed
			// result is byte-identical to the first, i.e. one trip reaches a
			// fixed point rather than drifting further on each export.
			{
				target, path, ok := theme_export("Dark")
				if !ok {
					fmt.println("  FAIL   theme_export(\"Dark\") failed")
					fail = true
				} else {
					first, rerr := os.read_entire_file(path, context.temp_allocator)
					if !rerr {
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
						within := worst <= (1.0 / 255.0) + 0.0001
						if !within {fail = true}
						fmt.printfln("  %-6s export round-trip: worst channel drift %.5f (need <= 1/255)", "ok" if within else "FAIL", worst)

						// Fixed point: exporting the PARSED theme must produce
						// the identical bytes. Written under a second name so
						// the no-overwrite rule does not block it.
						os.remove(path)
						g_saved := g_theme
						g_theme = parsed
						_, path2, ok2 := theme_export("Dark")
						g_theme = g_saved
						second, rerr2 := os.read_entire_file(path2, context.temp_allocator)
						stable := ok2 && rerr2 && string(first) == string(second)
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
				_, got_path, ok := theme_export("Dark")
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
				_ = os.write_entire_file(stray, transmute([]u8)"caret #010203\n")
				names := theme_available_names(context.temp_allocator)
				count := 0
				for n in names {if n == "Dark" {count += 1}}
				ok := count == 1 && theme_export_target("Dark") != "Dark" && theme_export_target("Light") != "Light"
				if !ok {fail = true}
				fmt.printfln("  %-6s a stray Dark.theme neither duplicates nor becomes an export target", "ok" if ok else "FAIL")
				os.remove(stray)
			}
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
build.bat
```

Expected: compile error, `undefined name 'theme_export'`.

- [ ] **Step 3: Implement export**

Append to `src/program/theme.odin`, after `theme_resolve`:

```odin
// The .theme file backing a theme name, or ok=false when there is none. The
// two built-ins are compiled in and have NO file -- theme_resolve returns
// theme_dark()/theme_light() without consulting disk -- so they are the early
// out here, and the reason "reload the theme file" needs an export step before
// it can mean anything.
theme_active_file_path :: proc(name: string) -> (path: string, ok: bool) {
	if name == "Dark" || name == "Light" {
		return "", false
	}
	dir, dok := themes_dir()
	if !dok {
		return "", false
	}
	return fmt.tprintf("%s%c%s.theme", dir, '\\', name), true
}

// The name to export the current theme AS. A built-in cannot be its own
// target: a file called Dark.theme is unreachable, because theme_resolve
// short-circuits on that name before looking at disk -- it would list in the
// Settings cycle and then change nothing when picked. A custom theme exports
// as itself, which combined with theme_export's no-overwrite rule means
// "export" on an already-exported theme is just "open it".
theme_export_target :: proc(name: string) -> string {
	switch name {
	case "Dark":
		return "Dark Custom"
	case "Light":
		return "Light Custom"
	}
	return name
}

// Convert one channel to its 8-bit file form. Rounds to nearest rather than
// truncating: the theme is f32 and the file is 8 bits per channel, so a trip
// through a file cannot be exact (0.10 * 255 = 25.5). Rounding reaches a fixed
// point after one trip; truncation drifts further on the first and can ratchet
// down across repeated exports. themetest asserts the fixed point.
@(private = "file")
theme_chan_hex :: proc(c: f32) -> int {
	v := int(c * 255 + 0.5)
	if v < 0 {v = 0}
	if v > 255 {v = 255}
	return v
}

// Write the current theme to themes_dir()/<target>.theme and return the target
// name and path. Writes every role, so the file is a complete, editable
// starting point rather than something the user must know the format to build.
//
// NEVER overwrites: on an existing target this succeeds and returns the path
// having written nothing. The file is the user's tuning work and the command
// calling this is reachable at any time; silently replacing it with the
// built-in's values would destroy exactly the thing this feature exists to
// let them make.
theme_export :: proc(from_name: string) -> (target: string, path: string, ok: bool) {
	target = theme_export_target(from_name)
	dir, dok := themes_dir_ensure()
	if !dok {
		return target, "", false
	}
	path = fmt.tprintf("%s%c%s.theme", dir, '\\', target)
	if os.exists(path) {
		return target, path, true // never clobber the user's edits
	}

	base_name := "light" if from_name == "Light" else "dark"
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, "# Newtpad theme -- %s\n", target)
	fmt.sbprint(&b, "#\n")
	fmt.sbprint(&b, "# Edit a colour and save (Ctrl+S). The window updates immediately.\n")
	fmt.sbprint(&b, "# Each line is `role #rrggbb`. Lines starting with # are comments.\n")
	fmt.sbprint(&b, "# Delete a line to fall back to the base theme's value for that role.\n")
	fmt.sbprint(&b, "# An unknown role or a malformed colour is skipped, never fatal.\n")
	fmt.sbprint(&b, "#\n")
	fmt.sbprintf(&b, "base %s\n\n", base_name)

	sections := []struct {
		title: string,
		first: Color_Role,
	}{{"neutrals", .Bg_Base}, {"accents", .Selection_Doc}, {"syntax", .Syn_Keyword}}
	si := 0
	for role in Color_Role {
		if si < len(sections) && role == sections[si].first {
			fmt.sbprintf(&b, "# --- %s ---\n", sections[si].title)
			si += 1
		}
		c := g_theme[role]
		fmt.sbprintf(
			&b,
			"%s #%02X%02X%02X\n",
			theme_key_from_role(role),
			theme_chan_hex(c.r),
			theme_chan_hex(c.g),
			theme_chan_hex(c.b),
		)
	}

	if !os.write_entire_file(path, transmute([]u8)strings.to_string(b)) {
		return target, path, false
	}
	return target, path, true
}
```

- [ ] **Step 4: Exclude the built-in names from the theme list**

In `src/program/theme.odin`, in `theme_available_names`, replace the loop body:

```odin
	for info in infos {
		if info.type != .Regular {continue}
		if !strings.has_suffix(info.name, ".theme") {continue}
		stem := strings.trim_suffix(info.name, ".theme")
		// A file named Dark.theme or Light.theme can never load -- theme_resolve
		// answers those two names from the compiled-in themes before it looks at
		// disk. Listing it would offer a Settings entry that silently does
		// nothing, and a duplicate of a name already in this list.
		if stem == "Dark" || stem == "Light" {continue}
		append(&names, stem)
	}
```

- [ ] **Step 5: Run the tests to verify they pass**

```bash
build.bat
```

```bash
set NEWTPAD_SESSION_DIR=%TEMP%\np_t3 && build\newtpad.exe themetest
```

Expected, all `ok`: `export round-trip: worst channel drift 0.00196 (need <= 1/255)`, `export is a fixed point after one round-trip`, `export refuses to overwrite an existing theme file`, `'#' comment lines ignored`, `a stray Dark.theme neither duplicates nor becomes an export target`.

- [ ] **Step 6: Sabotage-verify, and record the output**

Three separate sabotages, each restored before the next:

1. Change `theme_chan_hex` to truncate — `v := int(c * 255)`. Rebuild, run, confirm the fixed-point check or the drift check reports `FAIL`. Record it.
2. Remove the `if os.exists(path)` early return. Rebuild, run, confirm `FAIL   export refuses to overwrite an existing theme file`. Record it.
3. Remove the `if stem == "Dark" || stem == "Light" {continue}` guard. Rebuild, run, confirm `FAIL   a stray Dark.theme neither duplicates nor becomes an export target`. Record it.

- [ ] **Step 7: Commit**

```bash
git add src/program/theme.odin src/program/test_modes.odin
git commit -m "Export the active theme to an editable .theme file"
```

---

## Task 4: The Edit Current Theme command

**Files:**
- Modify: `src/program/commands.odin` (`Command_Id` enum, `command_table`, `command_dispatch`), `src/program/menu.odin` (View menu)
- Test: `src/program/test_modes.odin` (`themetest`)

**Interfaces:**
- Consumes from Task 3: `theme_export(from_name) -> (target, path, ok)`.
- Consumes existing: `app_open_path(a: ^App, path: string) -> bool`, `app_note(a: ^App, msg: string)`, `settings_save`, `theme_resolve(name) -> Theme`, the global `g_theme`.
- Produces: `Command_Id.Theme_Edit`, and `theme_edit_current :: proc(app: ^App) -> bool`.

**Context.** `command_table` is `[Command_Id]Command` with `#assert` on its length, so adding an enum member without a table entry is a compile error. Commands are dispatched from a switch in `command_dispatch`. The command needs no key binding — it is a palette and menu entry; `default_bindings` cannot express one cleanly here anyway, and this is not a per-keystroke action.

- [ ] **Step 1: Write the failing test**

Add to `themetest`, inside the `tdir` branch:

```odin
			// The command's whole job: produce a file, point settings at it,
			// and leave g_theme resolved from that file rather than from the
			// built-in it started as. Tested through theme_edit_current rather
			// than through the dispatch switch, because opening a tab needs an
			// App and a window; what is asserted here is the state change the
			// command is responsible for.
			{
				app_t: App
				menu_init(&app_t.menu)
				defer app_destroy(&app_t)
				app_t.settings.theme_name = strings.clone("Dark")
				g_saved := g_theme
				g_theme = theme_dark()

				ok_cmd := theme_edit_current(&app_t)
				switched := app_t.settings.theme_name == "Dark Custom"
				path, pok := theme_active_file_path(app_t.settings.theme_name)
				on_disk := pok && os.exists(path)

				// Editing the file and re-resolving must be visible in g_theme:
				// this is the property the whole feature rests on.
				_ = os.write_entire_file(path, transmute([]u8)"base dark\ncaret #010203\n")
				g_theme = theme_resolve(app_t.settings.theme_name)
				applied := g_theme[.Caret] == [4]f32{f32(0x01) / 255, f32(0x02) / 255, f32(0x03) / 255, 1}

				all_ok := ok_cmd && switched && on_disk && applied
				if !all_ok {fail = true}
				fmt.printfln(
					"  %-6s edit-current-theme: exported=%v switched=%v on_disk=%v reresolved=%v",
					"ok" if all_ok else "FAIL",
					ok_cmd,
					switched,
					on_disk,
					applied,
				)
				if pok {os.remove(path)}
				g_theme = g_saved
			}
```

That three-line `App` setup is the idiom `droptest` already uses (`test_modes.odin:4315-4317`): `App` is zero-is-initialization, so there is no `app_init` — only `menu_init` and a `defer app_destroy`. Copy it exactly; do not invent a constructor.

- [ ] **Step 2: Run the test to verify it fails**

```bash
build.bat
```

Expected: compile error, `undefined name 'theme_edit_current'`.

- [ ] **Step 3: Add the command id and its table entry**

In `src/program/commands.odin`, add to `Command_Id` immediately after `Settings_Dec`:

```odin
	Theme_Edit,
```

and to `command_table`, immediately after the `.Settings_Dec` line:

```odin
	.Theme_Edit               = {"Edit Current Theme...", "View"},
```

- [ ] **Step 4: Implement the command body**

Append to `src/program/theme.odin`:

```odin
// Edit Current Theme: the one command that turns "themes are files" from a
// documented format nobody has a file for into a loop. Exports the active
// theme if it has no file yet, switches to it, and opens it as a tab -- so the
// editor becomes the editor of its own theme, and saving re-applies (see
// theme_reapply_if_active).
//
// Order matters on the failure path: settings.theme_name is updated only after
// the file exists, so a failed write leaves the app on the theme it was
// already using rather than pointing at a theme file that isn't there.
theme_edit_current :: proc(app: ^App) -> bool {
	target, path, ok := theme_export(app.settings.theme_name)
	if !ok {
		app_note(app, "[THEME NOT SAVED - could not write to the themes folder]")
		return false
	}
	if app.settings.theme_name != target {
		delete(app.settings.theme_name)
		app.settings.theme_name = strings.clone(target)
		g_theme = theme_resolve(target)
		settings_save(&app.settings)
	}
	app_open_path(app, path)
	return true
}
```

`settings_save :: proc(s: Settings) -> bool` takes `Settings` **by value** (`settings.odin:187`) — pass `app.settings`, not `&app.settings`. The `delete` / `strings.clone` pair around `theme_name` mirrors what the Settings theme cycle already does at `settings.odin:352-354`; `theme_name` is heap-owned, and double-freeing or leaking it is the failure mode here. The `if app.settings.theme_name != target` guard matters for the custom-theme case, where target *is* the current name and the delete-then-clone would free the string it is about to read.

- [ ] **Step 5: Dispatch it**

In `src/program/commands.odin`, in `command_dispatch`'s switch, next to `case .Settings_Open:`:

```odin
	case .Theme_Edit:
		theme_edit_current(app)
```

Match the surrounding cases' access to `app` — if that switch has an `app` parameter under a different name, use it.

- [ ] **Step 6: Add the menu entry**

In `src/program/menu.odin`, the View menu's item list ends with `{cmd = .Palette_Open},` then `{cmd = .Settings_Open},` (lines 162-163). Add one line after `.Settings_Open`:

```odin
			{cmd = .Theme_Edit},
```

No `enabled` or `checked` field: the command works with no document open, exactly like `.Settings_Open` beside it.

- [ ] **Step 7: Run the tests to verify they pass**

```bash
build.bat
```

```bash
set NEWTPAD_SESSION_DIR=%TEMP%\np_t4 && build\newtpad.exe themetest && build\newtpad.exe menutest && build\newtpad.exe palettetest
```

Expected: the edit-current-theme line `ok`; `menutest` and `palettetest` still fully passing (the new command joins both surfaces).

- [ ] **Step 8: Sabotage-verify, and record the output**

Move the `settings.theme_name` update *above* the `if !ok` early return so a failed export still switches. Force the failure by pointing `NEWTPAD_SESSION_DIR` at a path that cannot be created. Confirm the test reports `FAIL` with `exported=false switched=true`. Record it, then restore.

- [ ] **Step 9: Commit**

```bash
git add src/program/theme.odin src/program/commands.odin src/program/menu.odin src/program/test_modes.odin
git commit -m "Add an Edit Current Theme command"
```

---

## Task 5: Re-apply the theme when its file changes

**Files:**
- Modify: `src/program/theme.odin` (add `theme_reapply_if_active`), `src/program/commands.odin:433-451` (`save_checked`), `src/program/main.odin:679-715` (the disk-change loop)
- Test: `src/program/test_modes.odin` (`themetest`)

**Interfaces:**
- Consumes from Task 3: `theme_active_file_path(name) -> (path, ok)`.
- Produces: `theme_reapply_if_active :: proc(app: ^App, path: string) -> bool` — true when the path was the active theme's file and `g_theme` was re-resolved.

**Context and the specific risk this task carries.** This is a **Shape B** task (HANDOFF §6j, `docs/development-loop.md` §4): a correct comparison fed the wrong input. The whole component is one path comparison, and the two paths reach it from different places — `doc.path` (which may come from the Save dialog, from `argv`, or from an Explorer drop) versus `themes_dir()`'s constructed path. They can differ in case and in separator while naming the same file. Windows paths are case-insensitive. **The test must feed a differently-cased, differently-separated path, not the path the export produced** — a test that round-trips the export's own path proves nothing, because those two are identical by construction.

`save_checked` (`commands.odin:433`) is the single funnel for all three save paths — the close-prompt save at line 475, `.Save` at 621, and `.Save_As` at 625 — so one hook there covers every save. Note `doc_save_err` frees and reallocates `doc.path`, so compare the `path` parameter, never `doc.path`, after the save.

- [ ] **Step 1: Write the failing test**

Add to `themetest`, inside the `tdir` branch:

```odin
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
				defer app_destroy(&app_t) // frees theme_name; App is zero-is-initialization
				app_t.settings.theme_name = strings.clone("Dark Custom")
				path, pok := theme_active_file_path("Dark Custom")
				g_saved := g_theme
				g_theme = theme_dark()
				_ = os.write_entire_file(path, transmute([]u8)"base dark\ncaret #010203\n")
				want := [4]f32{f32(0x01) / 255, f32(0x02) / 255, f32(0x03) / 255, 1}

				exact := pok && theme_reapply_if_active(&app_t, path) && g_theme[.Caret] == want

				g_theme = theme_dark()
				upper := theme_reapply_if_active(&app_t, strings.to_upper(path, context.temp_allocator)) && g_theme[.Caret] == want

				g_theme = theme_dark()
				fwd := theme_reapply_if_active(&app_t, strings.replace_all(path, "\\", "/", context.temp_allocator)) && g_theme[.Caret] == want

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
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
build.bat
```

Expected: compile error, `undefined name 'theme_reapply_if_active'`.

- [ ] **Step 3: Implement the helper**

Append to `src/program/theme.odin`:

```odin
// Re-resolve g_theme if `path` is the active theme's file. Called after a
// successful save and after the external-change watcher reloads a document, so
// editing the theme file inside Newtpad (or in another editor while it is open
// here) updates the window without a restart.
//
// The comparison is the whole procedure, and its two inputs come from different
// places: doc.path can arrive from the Save dialog, from argv, or from an
// Explorer drop, while the theme path is constructed from themes_dir(). Those
// can name the same file in different case and with different separators, so
// the compare normalises both. A built-in theme has no file at all, which
// theme_active_file_path reports as ok=false -- without that early out, every
// save on Dark would fall through to a string compare against nothing.
theme_reapply_if_active :: proc(app: ^App, path: string) -> bool {
	theme_path, ok := theme_active_file_path(app.settings.theme_name)
	if !ok || path == "" {
		return false
	}
	norm :: proc(s: string) -> string {
		return strings.to_lower(strings.replace_all(s, "\\", "/", context.temp_allocator), context.temp_allocator)
	}
	if norm(path) != norm(theme_path) {
		return false
	}
	g_theme = theme_resolve(app.settings.theme_name)
	return true
}
```

- [ ] **Step 4: Hook it into the save path**

In `src/program/commands.odin`, change `save_checked`'s final line (currently `return report_save(doc_save_err(doc, path), path, w)`) to:

```odin
	saved := report_save(doc_save_err(doc, path), path, w)
	if saved && app != nil {
		// Saving the active theme's own file re-applies it -- this is the loop
		// that makes tuning a theme possible without a rebuild. `path`, not
		// doc.path: doc_save_err frees and reallocates doc.path.
		theme_reapply_if_active(app, path)
	}
	return saved
```

`save_checked` has no `app` parameter today. Add `app: ^App` as its first parameter and update all three call sites (`commands.odin:475`, `:621`, `:625`) **in the same commit** — a signature change split from its callers is exactly the non-bisectable commit the loop doc calls out. Confirm each call site has an `app` in scope; `command_dispatch` does.

- [ ] **Step 5: Hook it into the external-change path**

In `src/program/main.odin`, inside the `for c in disk_changes` loop, after the `if d.modified { ... } else if doc_absorb_append ... else if !doc_reload ...` chain and before `session_dirty = true`, add:

```odin
			// If what changed on disk was the active theme's file, re-apply it.
			// Only on a branch that actually took the new bytes: when
			// d.disk_changed is set the user's edits won.
			if !d.disk_changed {
				theme_reapply_if_active(&app, d.path)
			}
```

- [ ] **Step 6: Run the tests to verify they pass**

```bash
build.bat
```

```bash
set NEWTPAD_SESSION_DIR=%TEMP%\np_t5 && build\newtpad.exe themetest && build\newtpad.exe watchtest %TEMP%\np_t5 && build\newtpad.exe savepathtest %TEMP%\np_t5
```

Expected: `ok     reapply: exact=true upper=true fwdslash=true other-file-ignored=true builtin-ignored=true`, and `watchtest`/`savepathtest` unchanged.

- [ ] **Step 7: Sabotage-verify, and record the output**

Make the compare case-sensitive — drop `strings.to_lower` from `norm`. Rebuild, run `themetest`, confirm `FAIL   reapply: exact=true upper=false ...`. Record the line. Restore, rebuild, confirm `ok`.

- [ ] **Step 8: Commit**

```bash
git add src/program/theme.odin src/program/commands.odin src/program/main.odin src/program/test_modes.odin
git commit -m "Re-apply the theme when its own file is saved or changes"
```

---

## Task 6: Make the skipped-folder note visible

**Files:**
- Modify: `src/program/main.odin:37-39` (the note text), `src/program/main.odin:1122` (`warn`)
- Test: `src/program/test_modes.odin` (`droptest`)

**Interfaces:**
- Consumes: `app_notice_active(app) -> bool` (existing, `app.odin:64`).
- Produces: nothing other tasks depend on.

**Context.** Dropping a folder already skips it deliberately (`main.odin:25`, "a folder is not a document; project trees are out of scope") and posts a note. Wyatt reported it as "folders do nothing". The reason, confirmed in the code: the notice is appended to the *end* of the status line and drawn in one colour with the rest of it (`main.odin:1121`), and that colour is `Text_Dim` unless `warn` is set — which a notice does not set (`main.odin:1122`). So it is dim grey text at the far right of a line already carrying line/column, encoding, line-ending and line count.

Drawing the notice separately in its own colour was considered and rejected in the spec: it needs the status prefix measured to place the notice's x, which is a new seam of exactly the Shape B kind, bought for a four-second highlight.

- [ ] **Step 1: Rewrite the existing assertion**

**`droptest` already asserts the old wording** at `test_modes.odin:4337` — `ok3 := app_notice_active(&a) && strings.contains(a.notice, "2 items skipped")`. This task changes that string, so that assertion is not a test to add alongside; it is the test to rewrite. Leaving it would turn a deliberate change into a red suite.

`droptest`'s scenario drops `subdir`, `fileA`, `fileB`, `missing` — one folder and one unreadable file — so it exercises the both-kinds branch. Replace the `ok3` block with:

```odin
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
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
build.bat
```

```bash
set NEWTPAD_SESSION_DIR=%TEMP%\np_t6 && build\newtpad.exe droptest
```

Expected: `FAIL   dropped-folder note is bracketed and live: "1 item skipped (folders and unreadable files are not opened)"`. Record it.

- [ ] **Step 3: Reword the note**

In `src/program/main.odin`, replace the `app_note` call in `app_consume_open_requests` (lines 37-39). Folders and unreadable files are now counted separately, because they are different problems and the old message made the user guess which had happened:

```odin
	if folders > 0 || unreadable > 0 {
		// [BRACKETED CAPS] matches the status line's other loud conditions
		// ([CHANGED ON DISK ...], [GLYPH CACHE FULL ...]) -- this is the same
		// class of message and should read as one. Folders and unreadable files
		// are counted separately: they are different problems, and one message
		// covering both made the user guess which had happened.
		if folders > 0 && unreadable > 0 {
			app_note(app_arg, fmt.tprintf("[FOLDERS NOT OPENED - %d folder%s skipped (Newtpad opens files, not folders); %d file%s could not be read]", folders, "" if folders == 1 else "s", unreadable, "" if unreadable == 1 else "s"))
		} else if folders > 0 {
			app_note(app_arg, fmt.tprintf("[FOLDERS NOT OPENED - %d folder%s skipped. Newtpad opens files, not folders]", folders, "" if folders == 1 else "s"))
		} else {
			app_note(app_arg, fmt.tprintf("[FILE NOT OPENED - %d file%s could not be read]", unreadable, "" if unreadable == 1 else "s"))
		}
	}
```

Replace the single `skipped` counter with two, `folders` and `unreadable`, incremented in the two `continue` branches respectively (`main.odin:25-33`). Use the procedure's own `App` parameter name in place of `app_arg`.

- [ ] **Step 4: Make a live notice set `warn`**

In `src/program/main.odin:1122`, change:

```odin
		warn := doc.recovered || doc.disk_changed || doc.disk_gone || plat.text_atlas_full(text) || doc_backup_skipped(doc) || notice_live
```

`notice_live` is already computed at `main.odin:1031` and in scope here.

- [ ] **Step 5: Run the tests to verify they pass**

```bash
build.bat
```

```bash
set NEWTPAD_SESSION_DIR=%TEMP%\np_t6 && build\newtpad.exe droptest
```

Expected: `ok     dropped-folder note is bracketed and live: "[FOLDERS NOT OPENED - 1 folder skipped. Newtpad opens files, not folders]"`.

- [ ] **Step 6: Sabotage-verify, and record the output**

Revert the wording to the old `"%d item%s skipped (folders and unreadable files are not opened)"`, rebuild, run `droptest`, confirm `FAIL` with the old string printed. Record it, then restore.

- [ ] **Step 7: Commit**

```bash
git add src/program/main.odin src/program/test_modes.odin
git commit -m "Say plainly that a dropped folder was not opened"
```

---

## Final verification (controller, after all six tasks)

- [ ] Full suite: `odin test src\base -collection:src=src`, then every headless mode touched — `themetest`, `droptest`, `menutest`, `palettetest`, `settingstest`, `watchtest`, `savepathtest`, `sessiontest`, `highlighttest`, `lexstatetest` — with `NEWTPAD_SESSION_DIR` set. Grep with `Select-String -CaseSensitive "FAIL"`.
- [ ] Every commit compiles:

```bash
for c in $(git rev-list --reverse main..HEAD); do d=$(mktemp -d); git archive "$c" | tar -x -C "$d"; ( cd "$d" && odin check src/program -collection:src=src >/dev/null 2>&1 ) && echo "ok   $c" || echo "FAIL $c"; done
```

Archive the whole tree, not just `src/` — `links.odin` does `#load("../../text_exts.txt")` and a partial archive fails for that reason alone.

- [ ] `build.bat release` succeeds and the exe size is recorded (v0.13.0 shipped 1.26 MB).
- [ ] Whole-branch review on the most capable model, pointed at what per-task reviews structurally cannot see: `theme_name` ownership across export/cycle/load (heap-owned, freed and re-cloned in two places now), whether `g_theme` can be left resolved from a file that failed to write, and whether this batch makes the planned `renderer`/`ui` extraction harder (`theme.odin` is already flagged in §6v as needing to *split* when `ui` becomes a package).
