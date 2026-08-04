# Audit 06 — Application shell and immediate-mode UI

**Scope covered (read in full):** `src/program/main.odin` (2951), `app.odin` (421), `view.odin` (103),
`commands.odin` (2282), `keymap.odin` (657), `menu.odin` (1747), `palette.odin` (477), `ui_tabs.odin` (808),
`settings.odin` (780), `history.odin` (137), `fontpage.odin` (99).
**Read for cross-checking only (owned elsewhere):** `platform/window.odin` (input queues, modifier state),
`doc.odin:1000–1080` (`status_cells` / `status_cell_at`), `theme.odin:236–254` (the `#assert` precedent).
**Not covered (other auditors):** buffer, doc/session/watch, find/lex/highlight/rules, markdown/table/links/block.

Checked against `HANDOFF.md` (7471+ lines), `docs/reported-bugs.md`, `docs/requested-features.md`,
`docs/features.md`. None of the findings below is recorded there; where a *neighbouring* item is recorded
I say so and name it.

---

### [CRITICAL] A middle-click in the document body latches `mouse_middle_pressed` forever — session autosave stops, the caret stops blinking, and the next Ctrl+P dismisses or self-executes itself

**Where:** `src/program/main.odin:996` (the right-button clear that has no middle-button twin), `main.odin:433`,
`main.odin:675`, `main.odin:1616`; set at `src/platform/window.odin:1001`
**Confidence:** CONFIRMED
**Fix risk:** SAFE

**Mechanism:** `window.mouse_pressed` always terminates — the caret branch at `main.odin:1264` runs at loop
scope and clears it at `:1291`. `window.mouse_right_pressed` has an explicit unconditional clear at
`main.odin:996`, whose comment states the rule exactly: *"a right press has no such terminal consumer, so one
that landed on the canvas … would still be pending on the next frame."* **`window.mouse_middle_pressed` has
neither.** Grep of the whole tree (excluding tests) shows it is cleared only inside conditional consumers:
`ui_tabs.odin:432/465` (pointer inside the tab strip), `menu.odin:914` (a dropdown claimed a *left* press —
`menu_hit_test` returns early on `!win.mouse_pressed`), `main.odin:679` (palette active), `:750` (pseudo-tab),
`:1101` (read-only surface), `:1124`/`:1154` (pointer inside the bottom/top bar bands). A middle press on a
plain `.Text` document, in the content area, with no palette/menu open, matches none of them, and
`tabs_hit_test` returns at `ui_tabs.odin:376` (`mouse_y >= TAB_STRIP_H`) without clearing. The flag stays
`true` for the rest of the process's life. Three consequences, all per-frame:

1. `main.odin:433` re-runs `session_dirty = true; last_input = time.tick_now()` **every frame**. The
   debounced autosave at `main.odin:1616` requires `tick_since(last_input) > 2` — it can never fire again.
   **Crash-safety backups stop for the whole session.** (Exit save at `:1627` and the crash handler still
   run, so this is loss on kill/power-fail, not on a normal quit.)
2. `caret_blink_visible(elapsed≈0, true)` returns `true` unconditionally (`doc.odin:4572`), so the caret goes
   permanently solid, and `caret_blink_wait_ms` pins the idle sleep at 200 ms — the process wakes 5×/s forever.
3. `main.odin:675` gates palette click handling on `window.mouse_pressed || window.mouse_middle_pressed`, so
   the frame the palette opens it is immediately "clicked" at the stale `mouse_x/mouse_y` of that old
   middle-click.

**Failure scenario:** 1280×720, 100% DPI, a plain `.txt` tab. Middle-click (press the scroll wheel) at
(400, 300) in the text. Now press Ctrl+P. `palette_layout` gives `x0 = 280, w = 720, y0 = 44,
h = 34 + nres*26`. With 3 open tabs `h = 112`, so (400,300) is outside the box → `palette_click` calls
`palette_close` on the same frame: **Ctrl+P appears completely dead and never opens again.** With 12+ tabs
`h = 346`, so (400,300) is *inside* on row 9 → `chose = true` → `palette_execute` instantly switches to an
arbitrary tab. Separately, from that middle-click on, `session.txt` and the unsaved-buffer backups are never
rewritten again.

**Fix:** add `window.mouse_middle_pressed = false` immediately beside the right-button clear at
`main.odin:996`, with the same comment. Verify by asserting the flag is false at the bottom of a synthetic
frame after a middle press in the content area (the pattern `hscrolltest` already uses for `Drag_Latches`).

---

### [HIGH] Status-bar cells drop out of the DRAW on a narrow window but stay live in the HIT-TEST — clicking the left-hand status text rewrites every line ending in the file

**Where:** draw `src/program/main.odin:2707–2731`; hit-test `src/program/doc.odin:1050–1057`; dispatch
`src/program/main.odin:1115–1120`
**Confidence:** CONFIRMED
**Fix risk:** SAFE

**Mechanism:** `status_cells` (`doc.odin:1029`) places the two right-hand cells right-to-left from
`winw - sx(12)`, unconditionally. The **draw** then applies UI spec §5's drop order in a loop the producer
knows nothing about:

```odin
need := sx(12) + f32(len(left)) * cw + sx(24)
for len(cells) > 0 && cells[len(cells) - 1].x < need {
    cells = cells[:len(cells) - 1]
}
```

`status_cell_at` re-calls `status_cells` and walks **all** of them with no `need` term. So a dropped cell is
invisible and still clickable, at pixels now occupied by the left group's own text. This is exactly the
"one layout, consumed by the draw *and* the hit-test" rule; the drop is a second geometry decision made
inside `render_frame`. `docs/features.md:612` documents the drop as a shipped behaviour; nothing records
that the click side does not participate.

**Failure scenario:** Window narrowed toward the `WM_GETMINMAXINFO` floor (HANDOFF §6bz records the floor as
318 px), 100% DPI, a modified UTF-8/LF file that is still indexing — so `left` reads
`Ln 1, Col 1    412000 lines *  (indexing 38%)`, long enough that `need` exceeds both cells' `x`. Both cells
vanish from the bar. Click on the visible words `(indexing 38%)` where the `LF` cell would have sat →
`status_cell_at` returns `.Eol_CRLF` → `command_dispatch` runs `doc_set_line_ending`, which
`command_mutates_doc` itself describes (`commands.odin:1073–1082`) as `pt_delete(0, length)` +
`pt_insert` — **the entire buffer is rewritten and every line start moves.** Undoable, but the user clicked
on a progress percentage.

**Fix:** move the drop loop into `status_cells` (it needs `left`'s cell count as a parameter, or a
`left_w: f32`), so one producer answers both consumers. Verify by reintroducing the divergence: assert at
several window widths that every `x` returned by the hit-test is also drawn.

---

### [HIGH] Eight commands that require a menu target are reachable from the command palette; palette "Close Tab" closes slot 0, and "Close Other Tabs" closes everything except slot 0

**Where:** `src/program/palette.odin:98–141` (`command_in_palette` excludes only the six `.Table_Sort_*`),
`src/program/commands.odin:1139–1154` (`command_needs_menu_target` names fourteen),
`commands.odin:2128–2148`, `commands.odin:1824–1880`, `src/program/menu.odin:732–746` (`menu_init` never
sets `ctx_tab`, so it is 0)
**Confidence:** CONFIRMED
**Fix risk:** SAFE (add eight members to the palette exclusion list)

**Mechanism:** `command_needs_menu_target` is the declared rule for "this command's argument is
`app.menu.ctx_tab` / `ctx_col` / `ctx_payload`, which only a menu sets, and which deliberately survives
`menu_close`". `keymap.odin:283` refuses to bind any of them from `keys.txt` for exactly that reason. But
`command_in_palette`'s `#partial switch` lists **only** `.Table_Sort_Asc/Desc/Then_Asc/Then_Desc/Remove/Clear`.
A script over the enum confirms the other eight — `.Tab_Reveal`, `.Tab_Copy_Path`, `.Tab_Close_This`,
`.Tab_Close_Others`, `.Table_Filter_Open`, `.Table_Filter_Toggle`, `.Table_Filter_All`,
`.Table_Filter_Clear` — are all `in_palette = true`. `menu_init` sets `ctx_col = 0` but never `ctx_tab`, so
`ctx_tab` is Odin's zero, i.e. **slot 0**, before any right-click. HANDOFF §6bx records the design intent
("the target is the whole design … a menu that read the active document would … act on the wrong file") and
records the `keys.txt` closure; the palette route was not closed.

Aggravating: `command_table` gives `.Tab_Close_This` the title `"Close Tab"` (`commands.odin:283`) and
`.Tab_Close` the title `"Close Tab"` (`commands.odin:293`). Typing `>close tab` in the palette shows **two
identically-labelled rows**, distinguished only by the category column (`Tab` vs `Tabs`).

**Failure scenario:** Fresh launch, 8 files opened, active tab is slot 5. Ctrl+P, type `>close`, pick the
`Tab`-category "Close Tab", Enter. `command_dispatch` runs
`if app.menu.ctx_tab >= 0 { request_close_tab(app, app.menu.ctx_tab, w) }` with `ctx_tab == 0` → **the first
tab closes, not the one you are looking at.** Pick "Close Other Tabs" instead → the loop at
`commands.odin:2142` keeps `app.docs[0]` and closes the other seven, including the active one. (Unsaved tabs
prompt, so this is a wrong destructive result rather than silent loss.) Same shape for
`.Tab_Reveal`/`.Tab_Copy_Path` — Explorer opens on, and the clipboard gets, slot 0's path. `.Table_Filter_Open`
from the palette calls `menu_open_ctx(app, …, app.menu.ctx_x, app.menu.ctx_y, …)` with stale/zero
coordinates, dropping a filter list at the window's top-left corner for column 0.

**Fix:** in `command_in_palette`, exclude every command for which `command_needs_menu_target(cmd)` holds —
one composition instead of a second hand-maintained list, exactly as `find_fallback_writes_doc` composes
from `command_mutates_doc`. Also set `m.ctx_tab = -1` in `menu_init`.

---

### [HIGH] Palette keyboard selection walks past the 12 drawn rows — nothing is highlighted and Enter runs a result that was never on screen

**Where:** `src/program/palette.odin:170–174` (`palette_move` clamps to `len(results)`),
`palette.odin:234–269` (`PALETTE_MAX_ROWS :: 12`, `l.nres = min(len(p.results), 12)`),
`palette.odin:408–447` (draw loops `0 ..< nres`), `palette.odin:452–468` (`palette_execute` indexes
`p.results[p.selected]`)
**Confidence:** CONFIRMED
**Fix risk:** SAFE (clamp) / RISKY (add real scrolling)

**Mechanism:** `Palette` has no `top` field — the list does not scroll. The draw emits `nres = min(len, 12)`
rows and highlights `i == p.selected`. `palette_move` clamps `selected` against `len(p.results)`, not
against `nres`, and `palette_row_at` (the hit-test) correctly refuses `i >= l.nres`. So the keyboard can
put `selected` in `[12, len)`, where **no row is highlighted at all** and `palette_execute` still runs
`results[selected]`. This is the draw and the "hit-test" (here, the keyboard selector) disagreeing about
which rows exist.

**Failure scenario:** 1280×720, 100% DPI. Ctrl+P, type `>` (empty pattern matches everything at score 0 —
72 commands are palette-eligible). Press Down 12 times. The highlight leaves row 11 and **the panel now
shows no selected row**. Press Enter: the 13th result runs. With `>` and no further typing, the sort is by
`(score, used)` with all-zero keys, so which command that is depends on `slice.sort_by`'s ordering — it can
be `Format_Document`, `Sort_Lines`, or anything else in the table. Same in Tabs mode with 13+ tabs open,
which is the exact case the `+N` overflow indicator (`ui_tabs.odin:427–435`) sends users to the palette for.

**Fix:** minimum — `palette_move` clamps to `min(len(p.results), PALETTE_MAX_ROWS) - 1`. Better — add
`Palette.top`, resolve it in `palette_move` (**not** in the draw), and have `palette_layout` return it so
the draw, `palette_row_at` and `palette_hover` all index through it.

---

### [HIGH] `palette_hover` overwrites the keyboard selection every frame from the live cursor, so Up/Down do nothing while the pointer rests over the result list

**Where:** `src/program/main.odin:674` (called unconditionally each frame, **after** the key-dispatch loop at
`:585–664`), `src/program/palette.odin:287–293`
**Confidence:** CONFIRMED
**Fix risk:** SAFE

**Mechanism:** `palette_hover` reads `plat.window_cursor_client(win)` — the *live* pointer, correctly, since
`win.mouse_y` only tracks while a button is held — and assigns `app.palette.selected = r` with no gate on
the pointer having moved. It runs after the key loop in the same frame, so `.Palette_Next` /
`.Palette_Prev` (`commands.odin:1964–1967`) are applied and then immediately overwritten.

**Failure scenario:** 1280×720. The palette box is `x ∈ [280, 1000)`, `y ∈ [44, 44 + 34 + 26·nres)` — with 8
results that is `y ∈ [44, 286)`, a large slab across the top-centre of the window. Leave the mouse anywhere
in it (very likely: Ctrl+P is a keyboard gesture and the pointer is wherever it was left). Type `>sav`,
press Down to move from "Save" to "Save As…". The selection snaps back to whatever row is under the
stationary pointer on the very same frame. **The arrow keys are inert** and Enter runs the hovered row.

**Fix:** latch the last cursor position on `Palette` (or reuse `win.kbd_nav`, which `window.odin:957/976/1021`
already maintains) and only let hover retarget when the pointer has actually moved since the last frame —
the same edge-vs-level distinction `menu_scroll_to_item` (`menu.odin:1619–1648`) already had to make.

---

### [HIGH] Arrow keys and Enter are broken on every context menu — Down/Up/Left/Right replace the open context menu with the File dropdown, Enter does nothing

**Where:** `src/program/commands.odin:2032–2049` (`.Menu_Next/.Menu_Prev/.Menu_Item_Next/.Menu_Item_Prev`
test `app.menu.open < 0`), `commands.odin:2192–2200` (`.Menu_Activate` requires `app.menu.open >= 0`),
`src/program/menu.odin:1063–1086` (`menu_open_ctx` sets `open = -1`, `ctx = true`)
**Confidence:** CONFIRMED
**Fix risk:** RISKY (behavioural — needs a decision about what Left/Right mean on a context menu)

**Mechanism:** A context menu is `ctx == true, open == -1`. `menu_is_active` (`menu.odin:783`) is true, so
`main.odin:643` routes keys to `Ctx.Menu` and the four navigation commands resolve. Each of them branches on
`app.menu.open`, which for a context menu is `-1`, so they take the "nothing is open" arm and call
`menu_open_at(app, 0)` — which clears `ctx`/`ctx_items` and opens **File**. `.Menu_Activate` takes the
opposite arm and simply does nothing. Meanwhile `menu_open_ctx:1076–1082` and `menu_filter_requery`
(`menu.odin:328–341`) both set `app.menu.item` to the first enabled row, and `menu_draw_dropdown:1267`
paints a `Selection_List` highlight on it — so the menu **draws a keyboard highlight it cannot move or
activate.** `menu_open_at`'s own comment records half of this hazard (the stale-`ctx_items` half, fixed);
the navigation swap itself was left.

**Failure scenario:** Open a `.csv` in table view, right-click a column header, then **Filter…**. The
column-filter dropdown appears with a search box you are explicitly invited to type into (`menu.odin:230–277`,
Wyatt's v0.49.0 request). Type `act` to narrow 4,000 values to 3. Press Down to reach the first match →
**the File menu opens and the filter dropdown is gone**, query and all. Press Enter instead → nothing
happens. The dropdown is mouse-only, and the two keys a user reaches for destroy it.

**Fix:** make the four navigation arms branch on `menu_dropdown_active(app)` and operate on `menu_items(app)`
(a `menu_step` variant that takes an item slice instead of a menu index — `menu_open_ctx` already open-codes
that walk at `:1077–1082`). `.Menu_Activate` needs the same. Left/Right on a context menu should be a no-op,
not a jump to the bar.

---

### [MEDIUM] The Settings page and the Font page have no mouse hit-test at all — every click and wheel notch is swallowed, while the rows draw `<` / `>` affordances that look pressable

**Where:** `src/program/main.odin:748–753`; `src/program/settings.odin:652–780` (no `*_row_at`);
`settings.odin:739–745` (the `<` / `>` glyphs); `src/program/fontpage.odin:44–99` (same, `:66–68`)
**Confidence:** CONFIRMED
**Fix risk:** RISKY (new interaction surface; needs the layout split out first)

**Mechanism:**

```odin
// main.odin:748
if doc.kind != .Text {
    window.mouse_pressed = false
    window.mouse_middle_pressed = false
    window.mouse_down = false
    window.scroll_delta = 0
}
```

The comment justifies this as stopping fall-through to the hidden document, which it does — but no handler
runs *before* it. Grep confirms `app.settings_row` is written only by `.Settings_Open/Next/Prev`
(`commands.odin:2088–2183`) and `app.settings_top` only by `.Settings_Open` and by `settings_draw:671`.
There is no `settings_row_at`, no `font_row_at`. Meanwhile `settings_draw:739–745` prints `<` and `>`
beside the selected row's value — pure decoration.

**Failure scenario:** 1280×720. Click the gear in the menu bar → Settings. Click directly on the word
"Theme" (row 7): nothing. Click the `>` beside `Dark`: nothing. Scroll the wheel to reach "Preview font"
(row 13, below the fold on a 720-high window — `settings_list_bounds` gives ~470 px of list at 46 px/row,
so ten rows fit): nothing; the `▼ more below` hint at `:756` is the only indication, and the list can only
be reached with Down. Every other surface in Newtpad — tabs, menus, palette, history, find bar, status
cells, table headers — is clickable; these two are not, with no visual signal.

**Fix:** a `settings_row_layout()` producing `[]Setting_Rect` consumed by the draw, a new hit-test, and a
hover. Wire the wheel to `settings_top` before the swallow at `:748`. Font page likewise (3 rows).

---

### [MEDIUM] Every frame with a column-filter dropdown open walks *all* generated rows through `command_chord`, ~190 binding-table iterations per row, three to five times per frame

**Where:** `src/program/menu.odin:1729–1747` (`dropdown_w` walks the whole item slice),
`src/program/commands.odin:546–573` (`command_chord` scans `default_bindings` twice plus the overlay, and
calls `resolve_key` per candidate), `menu.odin:1338` (`menu_dropdown_rect` calls `dropdown_w`), callers at
`menu.odin:1225, 1419, 1494, 1541, 1658, 1710`
**Confidence:** CONFIRMED (mechanism and call counts traced) / PLAUSIBLE (the wall-clock figure is arithmetic,
not measured — this environment cannot drive the GUI)
**Fix risk:** SAFE

**Mechanism:** `menu_filter_items` (`menu.odin:230`) generates one `Menu_Item` per distinct column value.
The cap was removed on 2026-08-02 (`menu.odin:264–270` says so: *"a column can now put tens of thousands of
checkboxes behind a scrollbar"*), bounded only by `TABLE_SORT_MAX :: 100_000` (`table.odin:1081`).
`dropdown_w` iterates **every** item — visible or not — and for each calls `command_chord(it.cmd)` plus
`command_disabled_hint`. `command_chord` is 94 `default_bindings` rows scanned twice, with a `resolve_key`
(itself another `lookup_binding` scan) on each match candidate. Per frame, `menu_dropdown_rect` is reached
from `menu_hover_item → menu_item_at`, `menu_draw_dropdown`, and `menu_scroll_mouse → menu_vbar_at`
(twice while dragging) — three to five calls. `menu_scroll_last` (`menu.odin:1435`) adds another O(n·rows)
walk per `menu_vbar` call. All of this for a panel that draws at most 12 rows (`MENU_MAX_ROWS`).

**Failure scenario:** Open a 400,000-line CSV with a timestamp or ID column in table view, right-click that
column's header, Filter…. The distinct list is ~100,000 rows. Each frame does roughly
100,000 × 190 × 4 ≈ 7.6×10⁷ inner iterations before a single quad is drawn — the dropdown freezes, and it
freezes *harder* the more you type into its search box (`menu_filter_requery` rebuilds the slice on every
keystroke, then the next frame re-walks it).

**Fix:** `dropdown_w` should short-circuit for a generated row set — a `Table_Filter_Toggle` row has no
chord and no hint by construction, so widen only from `menu_item_label` and skip `command_chord` entirely
when `it.cmd == .Table_Filter_Toggle`. Better: cache the width on `Menu_State` at open/requery time, since
the row set only changes there.

---

### [MEDIUM] Typed characters and command keys are drained as two separate ordered queues, so within one frame every character is applied before every key — text comes out in the wrong order

**Where:** `src/program/main.odin:517–554` (char loop), `:573–583` (sys-char/mnemonic loop), `:585–664` (key
loop); producers `src/platform/window.odin:894` (`w.chars`) and `:956` (`w.key_events`); the pump at
`window_pump_events` drains **all** pending messages per frame
**Confidence:** CONFIRMED (ordering inversion is unconditional in the code) / PLAUSIBLE (reachability needs
two input events inside one frame)
**Fix risk:** RISKY (this is the "events queue to the frame arena" refactor CLAUDE.md already flags as
partially honoured)

**Mechanism:** `Window` keeps `chars: []rune` and `key_events: []Key_Event` as two independent arrays with
independent counts. `window_pump_events` drains the whole OS queue, so both fill with interleaved input;
the frame then processes *all* chars, then all sys-chars, then all keys. Relative order between a
character and a command key is lost. Note the same inversion inside the filter dropdown's search box:
`menu_filter_query_rune` runs in the char loop (`main.odin:523`) and `.Menu_Search_Back` in the key loop
(`commands.odin:2039`).

**Failure scenario:** A 600 MB log open (indexing running, markdown/lex work per frame, so a frame is
tens of ms rather than 16). Type `ab`, press Backspace, type `c` — all four events land in one pump batch.
Expected buffer: `ac`. Actual: the char loop inserts `a`, `b`, `c` → `abc`, then the key loop backspaces →
`ab`. Same shape for `x`, Left, `y` (expected `yx`, actual `xy` with the caret then moved). Reported as
PLAUSIBLE because I cannot measure frame times here; the code path is not conditional.

**Fix:** one ordered event queue in `platform/window.odin` (`{kind: Char|Key, …}`), drained at one point in
`main.odin`. This is a real refactor, not a patch, and it is the concrete instance of the rule
`docs/reported-bugs.md:214–230` ("Menu and Ctrl+F interactions feel awkward") suspects a structural cause
behind.

---

### [MEDIUM] The tab rail's layout is rebuilt three times per frame and is O(tabs²) with per-frame temp allocation, regardless of how many tabs are visible

**Where:** `src/program/ui_tabs.odin:179–273` (`tabs_layout` allocates two slices), `:160–165`
(`tab_natural_w → tab_label`), `src/program/app.odin:401–421` (`tab_name_ambiguous` scans every doc;
`tab_label`/`tab_title` `strings.clone`); call sites `main.odin:2497` (`tabs_reveal_active`),
`ui_tabs.odin:363` (`tabs_right`, called from the draw at `:708`), `ui_tabs.odin:730` (the draw itself),
plus `:396` and `:487` on press/drag
**Confidence:** CONFIRMED
**Fix risk:** SAFE (cache per frame on the `Render_Ctx`)

**Mechanism:** `tabs_layout` is called three times in every rendered frame — `tabs_reveal_active`,
`tabs_right`, `tabs_draw` — each allocating `[]Tab_Rect` and `[]f32` on the temp allocator and calling
`tab_natural_w` once per **live** tab (not per drawn tab). `tab_natural_w → tab_label → tab_name_ambiguous`
loops all docs, so each layout is O(n²) `filepath.base` comparisons, plus n `strings.clone`s and n
`plat.text_cells` measurements. `tabs_draw:752` then calls `tab_label` a fourth time per drawn tab. The
fitting loop at `:210–228` adds up to 8 more O(n) passes when the rail overflows. The layout's own comment
argues against caching ("a handful of arithmetic per tab") — that was true before variable widths and
ambiguity resolution were added to it.

**Failure scenario:** 25 open tabs, several sharing a basename so the ambiguity path is live. Per frame:
~4 × 625 = 2,500 `doc_display_name`/`filepath.base` calls, ~100 temp `strings.clone`s, ~75 DirectWrite-backed
`text_cells` measurements — and the caret blink now guarantees a frame at least every 500 ms even when
idle, so this is steady-state cost, not just cost while typing. Not a hitch on its own; it is work
proportional to *total* tabs done four times over, which is the pattern the audit brief names.

**Fix:** compute `Tabs_Layout` once per frame into `Render_Ctx` (or a `@(private)` frame cache keyed on
frame counter) and hand it to `tabs_reveal_active`, `tabs_right`, `tabs_draw` and `tabs_hit_test`. Hoist
`tab_name_ambiguous` into one pass over the doc set instead of one per tab.

---

### [LOW] The palette's accelerator column width is cached forever, but the chords it measures come from the runtime keymap overlay, which reloads mid-session

**Where:** `src/program/palette.odin:319–338` (`g_chord_cells` computed once, "the table is a compile-time
constant, so this can never go stale"), against `src/program/commands.odin:546–573` (`command_chord` reads
`g_keymap`) and `src/program/keymap.odin:513–530` (`keymap_reload_if_active` swaps the overlay on save)
**Confidence:** CONFIRMED
**Fix risk:** SAFE

**Mechanism:** The comment's premise is false: `command_chord` is not a pure function of `command_table`.
`Keys_Edit` opens `keys.txt` as a tab, and saving it re-reads the overlay without a restart — that loop is
the whole point of the row. The cached `g_chord_cells` is whatever the widest chord was the first time the
palette was drawn.

**Failure scenario:** Launch with no `keys.txt`; widest default chord is `Ctrl+Alt+Enter` (15 cells), cached.
View > Edit Keybindings…, add `ctrl+alt+backspace = Delete_Word_Back` (19 cells), Ctrl+S. Reopen the
palette: `chord_x = x0 + PW - sx(16) - 15·cw`, so the 19-cell chord is drawn starting 4 cells left of its
column and overlaps the category column beside it — the `CursorCtrl+Home` collision HANDOFF §6bg records as
fixed, reintroduced through the overlay.

**Fix:** invalidate both caches (`g_cat_cells`, `g_chord_cells`) in `keymap_install` (`keymap.odin:231`),
which is the single point every overlay change passes through.

---

### [LOW] Scroll resolution happens inside the draw in two places; CLAUDE.md forbids it outright, and only one of the two is recorded as owed

**Where:** `src/program/settings.odin:671` (`app.settings_top = settings_resolve_top(...)` inside
`settings_draw`), `src/program/menu.odin:1644–1649` (`menu_scroll_to_item`, called from
`menu_draw_dropdown:1233`)
**Confidence:** CONFIRMED
**Fix risk:** SAFE

**Mechanism:** CLAUDE.md: *"scroll resolution must not happen inside the draw."* `menu_scroll_to_item`'s own
comment admits the violation and points at HANDOFF §6bt's Owed; it is edge-triggered on `item_scrolled`, so
it is currently harmless. `settings_draw:671` is **level-triggered and unconditional** and is not recorded
anywhere. It is benign today only because nothing else writes `settings_top` (grep confirms: only
`.Settings_Open` zeroes it) — i.e. the moment anyone adds a wheel handler or a scrollbar to the settings
page (see the MEDIUM finding above), it will silently revert every scroll on the next frame. That is
precisely the v0.52.0 menu-scrollbar bug `menu.odin:1628–1633` describes, pre-staged in a second file.

**Failure scenario:** Not user-visible today. It becomes the v0.52.0 bug verbatim the first time settings
scrolling gains a second writer — which is the natural fix for finding 7.

**Fix:** move the resolve into `.Settings_Next` / `.Settings_Prev` in `commands.odin:2180–2183` (they know
the row that moved; they need `avail_h`/`rowh`, which `settings_list_bounds` already produces from
`window.height`). Leave a comment at `settings_draw` saying `top` is resolved by the input phase.

---

### [LOW] `app.filter_items` is never freed, and `Menu_State.rows` is written but never read

**Where:** `src/program/app.odin:27` (`filter_items: [dynamic]Menu_Item`), `app.odin:352–368`
(`app_destroy` frees `docs`, `mru`, `palette.query`, `palette.results`, `notice` — not `filter_items`);
`src/program/menu.odin:651` (`rows` field), written at `menu.odin:1234`, `:1040`, `:1085`, `:737` and read
nowhere
**Confidence:** CONFIRMED
**Fix risk:** SAFE

**Mechanism:** `menu_filter_items` `clear`s and `append`s into `app.filter_items` for the life of the
process; the backing store is heap-allocated and never released. `app_destroy`'s neighbours are all freed
explicitly, so this is an omission rather than a policy. `Menu_State.rows` was superseded when
`menu_item_at:1677` started recomputing `rows_fitting` itself (correctly — that is what makes the draw and
the hit-test agree); the field survived as a write-only assignment that reads like live state.

**Failure scenario:** Not user-visible — the OS reclaims at exit. It matters as a leak-detector false
negative: a future `mem.tracking_allocator` pass over `app_destroy` will report it and cost time, and a
reader of `Menu_State` will assume `rows` is load-bearing.

**Fix:** `delete(a.filter_items)` in `app_destroy`; delete the `rows` field and its four assignments.

---

### [LOW] CLAUDE.md claims the command table is guarded by `#assert` on length; there is no `#assert` — the real (and adequate) guarantee is the language's

**Where:** `CLAUDE.md` hard-engineering rules ("registration compiler-enforced (`#assert` on length)")
against `src/program/commands.odin:214` (`command_table := [Command_Id]Command { … }`) and
`src/program/theme.odin:238–250`
**Confidence:** CONFIRMED
**Fix risk:** SAFE (a documentation fix, not a code fix)

**Mechanism:** Grep for `#assert` across `src/` returns 25 hits; none is about `Command_Id` or
`command_table`. `theme.odin:238–249` already states the correct model and names this case explicitly:
Odin rejects an incomplete keyed enumerated-array composite literal at compile time, so the totality of
`command_table` **is** compiler-enforced — and `command_dispatch`'s plain (non-`#partial`) `switch cmd`
at `commands.odin:1319` forces an arm per command too. I verified both hold: 131 enum members (130 real
commands plus `.None`), 131 `command_table` rows, zero missing. The `theme.odin` `#assert` is analogous but
guards a *different* thing (that `Theme` stays defined over `Color_Role`); `Command` has no such alias to
protect, so there is nothing for an `#assert` to say here.

**Failure scenario:** No runtime failure. The cost is an audit trail: a reader looking for the guarantee
greps for `#assert`, finds nothing near the command table, and either adds a redundant one or concludes the
rule is unenforced. Two prior audits made exactly this class of mistake against the memory row (CLAUDE.md
records it).

**Fix:** amend the CLAUDE.md row to say "compiler-enforced by the total `[Command_Id]Command` literal and by
the exhaustive `switch` in `command_dispatch`", citing `theme.odin:238` for the reasoning.

---

## Things checked and found CORRECT (recorded so the next pass does not re-derive them)

- **No default keybinding collisions.** All 94 `default_bindings` rows are unique on `(key, ctrl, alt, ctx)`:
  Editor 52, Find 13, Menu 7, Palette 6, Font 6, Settings 6, History 4.
- **No unreachable commands.** Every one of the 130 real commands is reachable from at least one of a default
  chord (90), a menu row (59 distinct), or the palette (72). No menu row dispatches `.None` except the
  deliberate separators/label rows, which `item_enabled:994` refuses and `menu_item_at:1681` returns `-1` for.
- **Modifier state survives focus loss.** `key_ctrl_down`/`shift`/`alt` (`window.odin:537–550`) query
  `GetKeyState` live rather than tracking edges, and `WM_ACTIVATE` (`window.odin:929–939`) additionally
  clears `alt_down`/`alt_used`/`alt_tapped` and `mouse_down`. **Ctrl cannot stick after Alt-Tab.**
  `WM_CAPTURECHANGED` (`:922`) covers the file-dialog case.
- **Surrogate pairs are handled** (`window.odin:874–898`) — astral-plane IME/emoji output is recombined
  before reaching `window.chars`. Dead keys fall through to `DefWindowProcW` and compose normally, since
  `TranslateMessage` runs before dispatch in `window_pump_events`. No `WM_IME_*` handling exists, which is
  correct for a `WM_CHAR`-based consumer.
- **Menu dropdown draw/hit-test agree at every boundary I could reach:** flip-up (`menu_dropdown_rect:1392`),
  the `MENU_MAX_ROWS` cap applying only to generated row sets (`:1389`), the scrollbar lane excluded from
  the row hit-test through the same `menu_vbar` producer the draw uses (`menu_item_at:1667`), and
  `menu_dropdown_hit` as a separate question from `menu_item_at` (`:1708`).
- **Tab rail:** `tabs_reveal_active` runs inside `render_frame` *before* `tabs_draw`, and the next frame's
  `tabs_hit_test` reads the same `tab_scroll` — so what is drawn is what is clickable. `drawn = false` tabs
  are skipped by both the draw (`:732`) and the hit-test (`:443`). Zero tabs, one tab and overflow all
  behave (`place` still advances `x` past non-fitting tabs, `over_on` reserves before the second pass).
- **`app_close` / `app_add` slot invariants** hold: closed slots go nil and stay nil, `app_add` reclaims only
  trailing nils, `app_swap_tabs` remaps `active` and `mru`.

---

## MARKETABLE

Counts are exact, from the source, not estimated.

1. **A command palette that reaches every single thing the app can do — 130 commands, one keystroke.**
   `commands.odin:29–203` declares exactly **131 `Command_Id` members (130 real commands plus the `.None`
   sentinel)**; `commands.odin:214–359` gives every one of them a title and category in a table the Odin
   compiler refuses to let you leave a hole in. **72 of the 130 are exposed in the palette**
   (`palette.odin:98–141` hides only movement, typing and internal plumbing). Ctrl+P fuzzy-matches with
   exact-prefix priority and learns from you — ties break by how recently you ran the command
   (`palette.odin:52–83`, `:176–185`), and matched characters light up in the accent so you can see *why* a
   row ranked where it did. Three modes off one field: nothing = switch tabs, `>` = run a command,
   `:` = go to line, `?` = the help list (`palette.odin:187–232`). **Limits:** the result list shows 12 rows
   and does not scroll; keyboard selection can currently run past them (finding 4), and hover currently
   fights the arrow keys (finding 5).

2. **Tabs that survive a crash, a reboot, or a power cut — including files you never saved.**
   `session_restore` runs before the command line is even considered (`main.odin:206–232`), so launching
   Newtpad on a file *adds a tab* rather than replacing your session. Unsaved scratch buffers are backed up
   to disk, adopted back from windows that died (`main.odin:238–243`), and written again by the crash
   handler (`main.odin:253`) and on GPU loss (`main.odin:1598–1605`, which saves your work and tells you
   why it has to close). Tabs drag to reorder and **drag out into their own window carrying unsaved bytes
   with them** (`ui_tabs.odin:545–633`). **Limits:** the debounced autosave is 2 s after input settles, and
   finding 1 stops it entirely after a middle-click until that is fixed; buffers over `BACKUP_MAX` are
   excluded and the status bar says so (`main.odin:2648`).

3. **Rebindable keys in a plain text file that cannot lock you out.** `keymap.odin` is a 657-line overlay
   over the 94 built-in bindings. Edit Keybindings… writes a fully-commented `keys.txt` containing **every
   default editor chord plus every command that has no chord yet** (`keymap.odin:553–632`) — the only place
   in the product that lists them. Saving it re-reads it, so a binding is tried without restarting
   (`keymap.odin:513–530`). Four refusals make a bad file survivable: Esc/Ctrl+S/Ctrl+P are reserved as the
   way back (`:190–195`), unmodified printable keys are refused because they would also type, Shift is
   refused rather than silently downgraded, and chords Windows owns (Alt+F4, F10) are refused because they
   would never fire. Every menu and palette row reads its shortcut *from the live keymap*
   (`commands.odin:546–573`), so a rebind re-teaches itself everywhere. **Limits:** editor context only, by
   design; Shift genuinely cannot be part of a chord.

4. **Themes you can edit while the app is running.** `theme.odin` (934 lines) defines a closed set of colour
   roles; the built-in Dark and Light are joined by any `*.theme` file dropped in the themes folder, which
   the Settings row cycles by name (`settings.odin:562–573`). Edit Current Theme… opens the active theme as
   a tab and **saving it repaints the next frame** (`commands.odin:624`, `main.odin:1472`) — the same live
   loop applies to `keys.txt` and `rules.txt`, and the file watcher runs it too, so editing any of the three
   in another editor takes effect here. **Limits:** an unresolvable theme name degrades to Dark silently
   (deliberate — see `settings.odin:110–120` for why validating on load was tried and reverted).

5. **A settings page with 14 options and an argument for each one.** `SETTINGS_ROWS`
   (`settings.odin:387–410`) is exactly **14 rows**: restore session, wrap new documents, zoom, show links,
   markdown default view, table default view, remember last view, theme, tab width, interface font, line
   numbers, blink the caret, highlight the current line, preview font. That is the whole surface — not a
   tree, not a dialog, no search box, because it does not need one. It writes a 20-line human-readable
   `settings.txt` atomically, tolerates unknown keys so an old build can read a new file
   (`settings.odin:248–333`), and Newtpad *learns* your view preferences per file family rather than asking
   (`commands.odin:1795`, `:1951`). **Limits:** keyboard-only today (finding 7).

6. **Chrome that is genuinely handmade, at any DPI, on one thread.** Tabs, the menu bar, dropdowns, the
   palette, the history panel, the find bar and the status bar are all immediate-mode quads and cached
   glyphs — no HWND children, no dialogs, no theming API. Every 96-DPI constant is re-derived on
   `WM_DPICHANGED` in one procedure (`main.odin:2798–2846`, 40 metrics), and the window repaints *live*
   during a resize drag straight out of the window proc (`main.odin:2924–2951`). Tabs size to their labels
   between a 132 and 220 px range, elide in the middle so the extension survives, disambiguate duplicate
   filenames with their parent folder, and reserve the dirty marker's slot so a file going modified never
   moves the truncation point (`ui_tabs.odin:13–49`, `app.odin:401–421`). **Limits:** `renderer` and `ui`
   are still empty stubs — this all lives in `program/`, and CLAUDE.md already says so.
