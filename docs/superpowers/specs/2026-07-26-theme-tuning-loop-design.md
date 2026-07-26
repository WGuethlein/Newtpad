# Theme tuning loop — design

**Date:** 2026-07-26
**Batch:** live-use fix batch on top of v0.13.0 (batches 3 and 4)
**Branch:** `feat/theme-tuning-loop`
**Target version:** 0.14.0

## Why

Wyatt's live pass on batch 4 found every syntax-highlighted file rendering the same
magenta in Dark — JSON, YAML, CSV and Markdown all identical. That is not a colour
choice gone wrong. Dark's nine `Syn_*` roles are literally `{1, 0, 1, 1}`
(`theme.odin:227`): batch 3 planted pure magenta as a deliberate "missing texture"
marker, batch 4 shipped the lexers that consume those roles, and **only Light was
ever filled in** (`theme.odin:334`). Every format looks the same because every
format resolves to the same nine placeholders.

Batch 4's whole-branch review missed it. The reviews were aimed at cross-cutting
invariants and at whether the lexers were correct; nobody asked whether the theme
the lexers render against had values. The countermeasure is in this batch: a test
that fails if any role in any built-in is still the placeholder.

Wyatt's second request is the reason this is a batch rather than a one-line fix.
He wants to tune the colours himself rather than round-trip through a rebuild for
every adjustment. Asked how, he chose **live-reloading a theme file** over per-role
inputs in Settings — which is also the answer that respects CLAUDE.md principle 3
(fight options): 34 colour pickers is exactly the chrome that signals leakage in
core design.

## The obstacle that shaped the design

Live-reload alone delivers nothing, for two reasons found while exploring:

1. **Built-in Dark and Light have no file.** `theme_resolve` (`theme.odin:566`)
   returns `theme_dark()`/`theme_light()` directly and only reaches disk for a name
   that is neither. The theme Wyatt actually runs cannot be reloaded because there
   is nothing to reload.
2. **No `.theme` file exists anywhere, and nothing in the product creates one.** The
   file format is documented only in a source comment. The feature shipped in batch 3
   with no discoverable way to use it.

So the batch has to supply the file before it can watch it.

## Decisions taken with Wyatt (2026-07-26)

1. **An "Edit Current Theme" command does the bootstrap** — not file-backed built-ins
   (a corrupt file could then break a built-in, and the compiled-in values stop being
   the guaranteed-good fallback), and not auto-creating a file at startup (invisible,
   and imposed on users who never asked).
2. **Re-apply on save and on external-change reload** — not a dedicated poller. The
   theme file is an open tab, so both events already exist. No new thread, no new
   polling, no idle cost.
3. **Dark's syntax colours mirror Light's hue families**, re-tuned for a dark
   background, so a role means the same thing in both themes and Light's already-
   reasoned hue choices are not thrown away.
4. **Dropped folders keep being skipped**, but the status note becomes obvious, so it
   reads as a decision rather than as nothing happening.

## Components

### A. `theme_export` and the Edit Current Theme command

Behaviour, in order:

1. Determine the target name. On `Dark` → `Dark Custom`; on `Light` → `Light Custom`.
   On a custom theme, the target is that theme itself.
2. **If the target file already exists, never write.** Switch to it and open it. The
   file is the user's work; the export path must not be able to destroy it.
3. Otherwise write `themes_dir_ensure()/<name>.theme` containing a header comment, a
   `base dark` or `base light` line, and **all 34 roles** as `role #rrggbb`, grouped
   under section comments matching the enum's own grouping (neutrals / accents /
   syntax).
4. Set `settings.theme_name` to the target, re-resolve `g_theme`, save settings.
5. Open the file as a tab and activate it.

The target name may never be `Dark` or `Light`. A file with a built-in's name is
unreachable — `theme_resolve` short-circuits on those two names before consulting
disk — which is the "lists but can never load" defect §6v recorded and carried. This
batch additionally excludes those two stems in `theme_available_names`, so a stray
`Dark.theme` cannot appear in the Settings cycle offering something that cannot work.

**Comments in the format.** `#`-leading lines already survive `theme_load_file`: they
parse as an unrecognised key and are skipped by the existing "unknown keys ignored"
contract. This batch makes that explicit rather than incidental, and tests it, because
the exported file leans on it heavily.

### B. `theme_reapply_if_active`

One helper, two call sites — after a successful save, and after the external-change
watcher reloads a document. It resolves the active theme's file path (empty for a
built-in, so built-ins are a cheap early-out), compares it to the supplied path, and
re-resolves `g_theme` on a match.

**This is a Shape B risk and is treated as one.** The comparison is the whole
component, and a correct comparison fed the wrong input is the bug class this codebase
keeps producing. `doc.path` can differ from `themes_dir()`'s path in case and in
separator — most easily by dragging the theme file in from Explorer rather than using
the command. The compare is therefore case-insensitive with separators normalised, and
the test feeds it a deliberately differently-cased path rather than the path the
command itself produced.

### C. All 34 roles file-settable

The nine `Syn_*` cases join `theme_role_from_key`, keyed by the lowercase enum name
(`syn_keyword`, `syn_json_key`, …), consistent with the existing 25.

The nine cases are the small part. **The guarantee is a test that walks every
`Color_Role` value and asserts the parser accepts its key** — the same total-over-the-
enum property `Theme` itself has, applied to the parser. The absence of that property
is precisely what let nine roles ship unsettable and, in Dark, unset.

Replacing the switch with reflection over enum names was considered and rejected: it
rewrites reviewed parsing logic to buy a guarantee the test already provides, and adds
a runtime dependency to a product with a 2–3 MB size target.

The enum's own comment ("deliberately unused until batch 4 … do not delete these as
dead code") is now false and gets corrected in the same change.

### D. Dark's nine syntax colours

Method, not taste. Each role keeps Light's hue family and is re-tuned for `Bg_Base`
(`#1A1F29`), with contrast ratios computed rather than eyeballed — the standard batch 3
set for Light, and the only standard available in an environment that cannot render a
frame.

| Role | Light | Dark direction |
|---|---|---|
| `Syn_Keyword` | indigo `#3B5BDB` | periwinkle |
| `Syn_String` | green `#17824E` | soft green |
| `Syn_Number` | burnt orange `#B5560A` | peach |
| `Syn_Comment` | muted slate `#707A88` | slate, **separated from `Text_Muted`** |
| `Syn_Type` | teal `#0B7285` | cyan |
| `Syn_Punct` | dark neutral `#444B58` | mid neutral, **separated from `Text_Primary`** |
| `Syn_Json_Key` | rust `#9C4221` | salmon |
| `Syn_Xml_Tag` | rose `#B5165A` | pink |
| `Syn_Xml_Attr` | violet `#6B4FB6` | lavender |

Two constraints are lifted directly from §6w's "what only Wyatt can check" list and
become assertions:

- **`Syn_Comment` must be visibly distinct from `Text_Muted`.** The gutter line numbers
  are `Text_Muted` and sit immediately beside comment text. Light deliberately placed
  them close; Dark must not, because Dark is the theme with the gutter beside it in
  Wyatt's daily use.
- **`Syn_Punct` must be visibly distinct from `Text_Primary`.** If punctuation reads as
  body text, every `.Punct` token batch 4 emits is wasted work.

"Visibly distinct" is quantified as **maximum absolute per-channel difference ≥ 0.10**
(≈26/255) so it is testable rather than a matter of opinion. That threshold is a floor
against the two roles being set equal or near-equal, not a claim that 0.10 is
perceptually sufficient — only Wyatt's eye settles that, which is what the tuning loop
is for.

Every token colour targets at least 4.5:1 against `Bg_Base`, except `Syn_Comment` and
`Syn_Punct`, which are deliberately de-emphasised and target at least 3:1 — a comment
that shouts is a worse outcome than a comment that is slightly dim.

### E. The dropped-folder note

`app_consume_open_requests` keeps skipping directories — project trees are out of scope
per CLAUDE.md, and that has not changed.

Why the current note is invisible, confirmed in the code rather than guessed: the notice
is **appended to the end of the status line** and drawn in one colour with the rest of it
(`main.odin:1121`), and that colour is `Text_Dim` unless `warn` is set — which a notice
does not set (`main.odin:1122`). So a dropped folder produces dim grey text at the far
right of a line that already carries line/column, encoding, line-ending and line count.

Two changes, both matching what the status line already does:

1. `warn` includes "a notice is live", so the line goes amber for the notice's four
   seconds. Drawing the notice separately in its own colour was rejected: it requires
   measuring the status prefix to place the notice's x, which is a new seam of exactly
   the Shape B kind (a coordinate computed in one place and consumed in another) bought
   for a four-second highlight.
2. The wording adopts the `[BRACKETED CAPS]` idiom the line's other loud conditions
   already use (`[CHANGED ON DISK …]`, `[GLYPH CACHE FULL …]`), so it reads as the same
   class of message: `[FOLDERS NOT OPENED — Newtpad opens files, not folders]`, with
   unreadable files still counted separately.

No modal, no dialog.

## Error handling

Every failure degrades rather than propagating:

- Themes directory not creatable, or the file not writable → the command reports via the
  same status note and changes no state. It must not half-switch: `settings.theme_name`
  is only updated after the file exists on disk.
- Malformed line, unknown role, bad hex in the file → skipped, that role keeps the base
  theme's value. Unchanged from batch 3's contract, and the reason a typo while tuning
  cannot produce a transparent-black hole.
- Re-apply on a path that is not the theme file → no-op.

## Round-tripping f32 through 8-bit hex

The theme is `[4]f32`; the file format is `#rrggbb`. Exporting Dark and reloading it
therefore does not reproduce Dark exactly — `0.10 × 255 = 25.5`, and 8 bits cannot hold
the difference. Two requirements follow:

1. **Round to nearest, not truncate.** Truncation drifts further on the first trip and
   can ratchet across repeated exports; rounding reaches a fixed point after one.
2. **Test the fixed point.** Export → parse → export must be byte-identical on the
   second pass, and every channel must land within 1/255 of the original.

This is a real, documented behavioural difference — "Dark" and "Dark Custom" are not
bit-identical — and it is acceptable. Recording it here so a future session does not
read it as a bug.

## Testing

All in `themetest`, all sabotage-verified per CLAUDE.md ("a test that has never failed
proves nothing") — for each, reintroduce the defect, capture the failing output, restore:

1. **No role in either built-in equals the placeholder `{1, 0, 1, 1}`.** The test that
   would have caught the shipped bug. Sabotage: restore magenta to one Dark role.
2. **Every `Color_Role` has a parser key.** Sabotage: delete one case from
   `theme_role_from_key`.
3. **Export → parse → export is a fixed point**, and channels round-trip within 1/255.
   Sabotage: truncate instead of rounding.
4. **Export refuses to overwrite an existing file.** Sabotage: remove the existence
   check and confirm the pre-seeded file's contents change.
5. **`theme_reapply_if_active` matches a differently-cased, differently-separated path
   and ignores unrelated ones.** Sabotage: make the compare case-sensitive.
6. **`Syn_Comment` ≠ `Text_Muted` and `Syn_Punct` ≠ `Text_Primary` in Dark**, by a stated
   minimum per-channel distance. Sabotage: set one equal to the other.
7. **A `#` comment line in a theme file is ignored**, including one whose text contains a
   role name.

`NEWTPAD_SESSION_DIR` must be set to a temp directory for every one of these — they write
theme files, and without it they write to the real store under `%APPDATA%\Newtpad`.

## Out of scope

- **Per-role colour inputs in Settings.** Wyatt asked about these and then chose the file
  loop instead. CLAUDE.md principle 3.
- **Polling a theme file that is not open as a tab.** Only matters while tuning in a
  second editor; costs a stat per second forever.
- **The two role splits §6v deferred** — `Border_Subtle` (table hairline *and* active-tab
  fill) and `Text_Muted` (gutter text *and* scrollbar thumb). Tuning is likely to run into
  both. Each becomes its own task, not a smuggled-in change here.
- **Light's `Syn_*` values.** Still marked provisional. The tuning loop is what lets Wyatt
  settle them; changing them blind in this batch would be guessing twice.
