# Theme Model Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give Newtpad a colour model and two themes, so batch 4's syntax highlighting can emit role names instead of RGB.

**Architecture:** A `Color_Role` enum plus `Theme :: [Color_Role][4]f32` — a total array over the enum, so a new role cannot be added without every theme being forced to supply it. One global `g_theme`, read by array index in the per-frame path. The 107 existing colour literals migrate to roles; the Dark theme reproduces today's rendering exactly, which turns the migration into a mechanical check rather than a visual one.

**Tech Stack:** Odin; `src/program` only (the two literals in `src/platform` are a window-frame colour and an atlas clear value, not themeable surfaces); headless modes in `test_modes.odin`.

**Spec:** [docs/superpowers/specs/2026-07-25-theme-model-design.md](../specs/2026-07-25-theme-model-design.md)

**Branch:** `feat/theme-model` (created; spec committed).

## Global Constraints

- **Layer boundaries:** `base` → `platform` → `program`. The theme is a `program` concern; do not put it in `base` or `platform`.
- **Fight options.** One Settings row picks a theme. **No per-role colour pickers** — that is the option-count leakage CLAUDE.md principle 3 exists to stop.
- **Hot path:** `g_theme` is read per visible row and per chrome element every frame. Array index on a global only — no allocation, no hashing, no procedure call that can fail.
- **Zero-is-initialization** (Odin default). Note the consequence here: an unfilled role is `{0,0,0,0}` — transparent black, which renders as an invisible hole rather than an obvious error. The array type guarantees the slot exists; it cannot guarantee somebody filled it.
- **A test that has never failed proves nothing.** Reintroduce the bug, watch it fail, restore.
- **Build:** `build.bat` (debug, console). A bare `odin build` omits the DPI manifest and is wrong. Rebuild under ~5 s.
- **Test modes:** set `NEWTPAD_SESSION_DIR` to a temp dir. Six modes now refuse to run without it. `edittest`/`keytest` need a path argument first; `watchtest` needs a directory. **Never run `drawcount`** — it opens a real window, hangs, and locks the exe.
- **Git:** commits authored solely by the repo owner. **Never** `Co-Authored-By: Claude`, "Generated with Claude Code", robot emoji, or any AI attribution. Imperative subject under 65 chars.

---

## File Structure

**Created:** `src/program/theme.odin` — the enum, the `Theme` type, the two built-in themes, the file loader, and `g_theme`.

**Modified:** `doc.odin`, `main.odin` (the document and chrome draw — the hot path); `ui_tabs.odin`, `palette.odin`, `menu.odin`, `settings.odin`, `fontpage.odin`, `history.odin`, `table.odin`, `markdown.odin`, `find.odin`, `links.odin` (UI surfaces); `test_modes.odin` (the new mode).

**Task order.** The type and Dark first, so the migration is a pure rename with a mechanical check. Light comes *after* the migration, so its findings are about colour choices rather than tangled up with a rename. Files and the Settings row last.

---

## Task 1: The role enum, the `Theme` type, and the Dark theme

No migration in this task. Nothing changes on screen.

**Files:** Create `src/program/theme.odin`; modify `src/program/test_modes.odin`.

**Interfaces produced:**
- `Color_Role :: enum u8 {...}`
- `Theme :: [Color_Role][4]f32`
- `g_theme: Theme`
- `theme_dark :: proc() -> Theme`

- [ ] **Step 1: Derive the role list from the existing literals**

Do not invent roles. Walk every colour literal in `src/program/` and name what it is *for*. Three sources already show the structure and should be followed rather than replaced:

- `ui_tabs.odin:27-29` — a three-entry array already commented `// strip background`, `// inactive tab`, `// active tab`.
- `markdown.odin:404-420` — ten already-named roles (`MD_TEXT`, `MD_HEAD`, `MD_BOLD`, `MD_ITALIC`, `MD_CODE`, `MD_QUOTE`, `MD_MUTED`, `MD_CODEBG`, `MD_RULE`, and `LINK_COL` in `doc.odin:2158`).
- Repeated values that reveal a shared role: `{0.16,0.18,0.22}` is the scrollbar track in three places, `{0.42,0.48,0.60}` the thumb in three, `{0.95,0.88,0.55}` the find-bar accent in three, `{0.09,0.11,0.16}` the gutter/preview background in two.

Where one literal serves two genuinely different purposes, that is **two roles with the same Dark value** — the point of the model is that Light can separate them.

Also declare, unused, the roles batch 4 will need: `Syn_Keyword`, `Syn_String`, `Syn_Number`, `Syn_Comment`, `Syn_Type`, `Syn_Punct`, `Syn_Json_Key`, `Syn_Xml_Tag`, `Syn_Xml_Attr`. **Comment them as deliberately unused until syntax highlighting lands**, or the next reader deletes them as dead.

Report the full role list in your report with the literal each came from.

- [ ] **Step 2: Write the type and the `#assert`**

```odin
// Layer: program — the colour model. One role per semantic slot; a Theme is a
// TOTAL array over the enum, so adding a role forces every theme to supply a
// value rather than silently inheriting a zero (which is transparent black, an
// invisible hole rather than an obvious error).
Color_Role :: enum u8 { ... }

Theme :: [Color_Role][4]f32

// Read per visible row and per chrome element every frame: an array index on a
// global, never a lookup that can allocate or fail.
g_theme: Theme
```

Add an `#assert` tying the theme's length to the enum, mirroring how `command_table`'s length is asserted in `commands.odin`.

- [ ] **Step 3: Populate Dark from the existing literals**

Transcribe each literal into its role. **This transcription is the whole risk of the batch** — a transposed digit is invisible in review and obvious in use. Copy carefully, one at a time.

- [ ] **Step 4: Write `themetest`**

Path-less mode beside `rowtest`. Assert:

- every role in Dark is non-zero (catches an unfilled slot — see the zero-is-initialization note);
- Dark's value for each role equals the literal it replaces. **Transcribe the expected values into the test independently from the pre-migration source, not by copying from `theme_dark`** — copying from the theme would make the test agree with a typo rather than catch it. The reviewer verifies the transcription against `git show`.

- [ ] **Step 5: Verify and commit**

```bash
build.bat && build\newtpad.exe themetest && odin test src\base -collection:src=src
```

Sabotage: change one component of one role in `theme_dark`, confirm `themetest` fails, restore.

```bash
git add src/program/theme.odin src/program/test_modes.odin
git commit -m "Add a colour role model and the current theme"
```

---

## Task 2: Migrate the document and chrome draw

The hot path. `doc.odin` and `main.odin`, ~23 literals.

- [ ] **Step 1: Replace each literal with its role**

`g_theme[.Role]` at each site. Nothing else changes — no reordering, no refactoring, no "while I'm here."

- [ ] **Step 2: Verify nothing moved**

```bash
build.bat && build\newtpad.exe themetest && build\newtpad.exe rowtest && build\newtpad.exe crlftest && build\newtpad.exe mdtabletest && build\newtpad.exe splittest
```

`themetest` is what proves the values are unchanged. The others prove the geometry still works.

**Confirm no literal was missed:** after this task `grep -cE '\{[01]?\.?[0-9]*, *[01]?\.?[0-9]*, *[01]?\.?[0-9]*, *[01](\.[0-9]+)?\}' src/program/doc.odin src/program/main.odin` should be 0 for colours. Report any remaining match and why it is not a colour.

- [ ] **Step 3: Commit**

```bash
git commit -m "Draw the document and chrome from the theme"
```

---

## Task 3: Migrate the remaining UI surfaces

`ui_tabs.odin`, `palette.odin`, `menu.odin`, `settings.odin`, `fontpage.odin`, `history.odin`, `table.odin`, `markdown.odin`, `find.odin`, `links.odin` — roughly 80 literals.

`markdown.odin`'s `MD_*` constants and `doc.odin`'s `LINK_COL` become roles; delete the constants once nothing references them.

- [ ] **Step 1: Migrate, file by file**

One file at a time, rebuilding between, so a mistake is attributable.

- [ ] **Step 2: Verify**

Every headless mode plus `themetest`. Then confirm the colour-literal count in `src/program/` is zero apart from `test_modes.odin` (test fixtures may legitimately hold literals — say which and why).

- [ ] **Step 3: Commit**

```bash
git commit -m "Draw the remaining UI surfaces from the theme"
```

---

## Task 4: The Light theme

**This is the task that can actually fail.** Everything before it is a rename with a mechanical check; a dark-only theme model is indistinguishable from one.

- [ ] **Step 1: Write `theme_light`**

A genuine light scheme — light background, dark text — not an inversion. Every role gets a deliberate value.

- [ ] **Step 2: Extend `themetest`**

- every role in Light is non-zero;
- Light differs from Dark in every role that is not *deliberately* shared. Where a role is intentionally identical in both, list it explicitly in the test with a reason — an accidental inheritance is exactly what this catches.

- [ ] **Step 3: Report what Light exposed**

Every colour in this tree was chosen against a dark background. Expect to find roles that cannot simply be lightened: muted greys that vanish on white, an overlay tuned for a dark base, a caret that disappears, a selection that swallows its text.

**Report these; do not quietly adjust them.** They are the finding this batch exists to produce, and some may indicate a role that should be split in two. If you split one, say so.

- [ ] **Step 4: Commit**

```bash
git commit -m "Add a light theme"
```

---

## Task 5: Theme files and the Settings row

- [ ] **Step 1: The loader**

`%APPDATA%\Newtpad\themes\*.theme`, one `role #rrggbb` per line. Follow `settings_load`'s shape exactly — same key/value parse, and **unknown keys ignored** so an older build reading a newer file degrades instead of failing.

Start from the built-in theme and overlay what the file supplies, so a partial file is valid. A malformed colour (`#zzz`, `#12`, no `#`) leaves that role at its built-in value — **never black**, which would be an invisible hole.

- [ ] **Step 2: The Settings row**

One row, cycling through the available themes by name. `SETTINGS_ROWS` is an index-based `switch i` in two places — **append**, never insert, or every later row's value shifts to the wrong label. Persist the choice in `settings.txt` as a name; an unknown name on load falls back to Dark.

- [ ] **Step 3: Extend `themetest`**

- a file round-trips;
- an unknown role name is ignored, not fatal;
- each malformed-colour form falls back to the built-in rather than to black;
- a partial file leaves unmentioned roles at their built-in values;
- an unknown theme name in `settings.txt` falls back to Dark.

- [ ] **Step 4: Sabotage, verify, commit**

Make the malformed-colour path fall back to `{0,0,0,1}` instead of the built-in; confirm the test fails; restore.

```bash
git commit -m "Load themes from disk and pick one in Settings"
```

---

## Final verification

- [ ] `odin test src\base -collection:src=src`
- [ ] Every headless mode with `NEWTPAD_SESSION_DIR` set
- [ ] `build.bat release` — clean, under ~5 s
- [ ] Bump `src/program/version.odin`
- [ ] HANDOFF entry: the role model, what Light exposed, and any role that had to be split
- [ ] **Run `install.ps1`** — standing instruction. Check `Get-Process newtpad` first; do **not** use `-Force` if it is running, since a hard kill can skip the hot-exit session write.
- [ ] **Wyatt's live pass:** Dark must be pixel-identical to what he uses today — if anything looks different, the migration is wrong, and that is the single most useful thing he can check. Then Light, looking for text that vanishes, borders that disappear, or a caret he cannot find.
