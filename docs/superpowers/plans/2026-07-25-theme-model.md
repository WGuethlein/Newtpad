# Theme Model Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give Newtpad a colour model and two themes, so batch 4's syntax highlighting can emit role names instead of RGB.

**Architecture:** A `Color_Role` enum plus `Theme :: [Color_Role][4]f32` — a total array over the enum, so a new role cannot be added without every theme being forced to supply it. One global `g_theme`, read by array index in the per-frame path. The 107 existing colour literals collapse onto 25 roles per the spec's merge table; the check is that every role holds a colour that genuinely appeared in the pre-migration UI, so only the enumerated merges can move a pixel.

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

**Task order.** The type and Dark first, so the migration is a mechanical collapse onto a fixed table rather than a redesign. Light comes *after* the migration, so its findings are about colour choices rather than tangled up with the collapse. Files and the Settings row last.

---

## Task 1: The role enum, the `Theme` type, and the Dark theme

No migration in this task. Nothing changes on screen.

**Files:** Create `src/program/theme.odin`; modify `src/program/test_modes.odin`.

**Interfaces produced:**
- `Color_Role :: enum u8 {...}`
- `Theme :: [Color_Role][4]f32`
- `g_theme: Theme`
- `theme_dark :: proc() -> Theme`

- [ ] **Step 1: Use the merge table from the spec**

**The role list is already decided — do not re-derive it.** The spec's "role table" section fixes 25 roles and names exactly which literals each absorbs. It came from clustering all 61 distinct values by chroma and luminance, and a faithful one-role-per-literal alternative (66 roles) was measured and rejected as unauthorable.

Your job in this step is to turn that table into the enum and record, per role, **which member of the merged set becomes its value** — generally the one with the most call sites, so the fewest pixels move. Record that choice per role in your report; it is the one judgement left in this step.

Where the spec's table and the code disagree — a literal in the tree that appears in no row — stop and report it rather than inventing a home for it.

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

- [ ] **Step 3: Populate Dark from the merge table**

Each role takes the value you chose in Step 1. **This transcription is the whole risk of the batch** — a transposed digit is invisible in review and obvious in use. Copy one at a time.

- [ ] **Step 4: Write `themetest`**

Path-less mode beside `rowtest`. Assert:

- every role in Dark is non-zero (catches an unfilled slot — see the zero-is-initialization note);
- **every role's Dark value is one of the literals the spec's table says that role absorbs.** Encode the absorbed sets as data in the test and check membership. This is the replacement for the old pixel-identical guard: a role can only ever hold a colour that genuinely appeared in the pre-migration UI, so a typo'd digit produces a value on no list and fails, while an intended merge passes. Transcribe the absorbed sets from the **spec table**, not from `theme_dark` — copying from the theme would make the test agree with a typo instead of catching it.

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

- [ ] **Step 0: Initialise `g_theme` at startup, before migrating anything**

`g_theme = theme_dark()` during `main`'s init, beside the other one-time setup. **This must land in the same commit as the first migrated call site**, or every migrated surface renders as transparent black — a zero-value `Theme` is `{0,0,0,0}` — until theme loading arrives in Task 5.

The property worth protecting: **the app runs correctly at every commit on this branch.** A migration that leaves the build black between tasks is not a safe place to stop, and this batch will be stopped in the middle at some point.

- [ ] **Step 1: Replace each literal with its role**

`g_theme[.Role]` at each site. Nothing else changes — no reordering, no refactoring, no "while I'm here."

- [ ] **Step 2: Verify nothing moved**

```bash
build.bat && build\newtpad.exe themetest && build\newtpad.exe rowtest && build\newtpad.exe crlftest && build\newtpad.exe mdtabletest && build\newtpad.exe splittest
```

`themetest` proves every role still holds a colour that genuinely appeared in the pre-migration UI. The others prove the geometry still works.

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

Note `g_theme` is already initialised to Dark at startup (Task 2 Step 0); this step replaces that assignment with a load, it does not introduce the first one.

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
- [ ] **Wyatt's live pass:** Dark is *deliberately* not pixel-identical — ~50 sites shift slightly as part of the 66-to-25 consolidation. So the check is not "did anything change" but "does anything look **wrong**": a label that lost contrast, a border that vanished, two things that used to be distinguishable now reading the same. Then Light, looking for text that vanishes, borders that disappear, or a caret he cannot find.
