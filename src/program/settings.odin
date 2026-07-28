// Layer: program — user settings and the page that edits them.
//
// The page replaces the document view rather than opening a dialog, which is how
// Windows 11 Notepad does it: no second HWND, no modal loop, no dialog DPI
// handling, and Esc closes it like any other mode.
//
// Scope is deliberately narrow (CLAUDE.md principle 4: personalization only at
// the edges). Every option here has to earn its place — options are a signal of
// leakage in the core design.
package main

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import plat "src:platform"

FONT_SIZE_MIN :: 8
FONT_SIZE_MAX :: 72

// Markdown Split's divider position. A fraction of window width, clamped well
// short of 0/1 so neither pane can be dragged to nothing.
SPLIT_DEFAULT :: f32(0.5)
SPLIT_MIN :: f32(0.15)
SPLIT_MAX :: f32(0.85)

// Zoom is a separate multiplier on top of the font size, so the two compose:
// font size is the preference, zoom is the transient adjustment. Discrete steps
// rather than a percentage counter, so repeated presses land on round numbers.
ZOOM_STEPS := []int{50, 67, 75, 80, 90, 100, 110, 125, 150, 175, 200, 250, 300, 400}
ZOOM_DEFAULT :: 100

zoom_step_index :: proc(pct: int) -> int {
	best, bd := 0, max(int)
	for z, i in ZOOM_STEPS {
		d := abs(z - pct)
		if d < bd {best, bd = i, d}
	}
	return best
}

Settings :: struct {
	restore_session: bool, // reopen last session's tabs on launch
	wrap_default:    bool, // new documents start word-wrapped
	font_size:       int, // document text size at 96 DPI
	zoom_pct:        int, // viewport zoom, applied on top of font_size
	// Tab-stop spacing in cells: a tab advances to the next multiple of this.
	// Bounds live in platform (plat.TAB_WIDTH_MIN/MAX) because that is where the
	// value is consumed and where a 0 would hang a measuring loop -- duplicating
	// them here is how the two ends drift apart.
	tab_width:       int,
	font_family:     string, // family NAME, not a path — paths differ per machine
	font_style:      plat.Font_Style,
	// The chrome's family, separate from the document's. plat.Font_Set has had
	// .UI and .Doc since the atlas was written -- "the document's font is the
	// user's choice; the chrome's is fixed, so choosing a document font cannot
	// make the menus unreadable" -- and text_load_faces loaded Consolas into
	// both "until settings say otherwise". This is settings saying otherwise.
	//
	// Defaults to Cascadia Mono, which ships on Windows 11 and is already in
	// FONT_FAMILIES. The UI spec asks for Monaspace Argon here; embedding a font
	// needs an in-memory DirectWrite loader that does not exist yet, so that
	// lands as one more row in that table later rather than holding this up.
	ui_font_family:  string,
	link_style:      Link_Style, // when/how clickable links are shown
	split_frac:      f32, // Markdown Split divider position; a global preference (not per-file/per-tab)
	// Remembered per-FAMILY view (not per-extension, not per-file — Wyatt's call:
	// one default for "markdown-ish" and one for "tabular", learned from the last
	// view used). Applied only on a fresh open (app_apply_view_defaults); session
	// restore carries its own per-tab state and must never be overridden by this.
	md_default:      Md_Mode,
	table_default:   bool,
	// When on, toggling a view updates the defaults above; off turns them into a
	// pin instead of a running average of what you last did.
	remember_views:  bool,
	// "Dark", "Light", or a custom *.theme file's stem (see theme_resolve).
	// Stored as-is on load, the same as font_family above -- NOT validated
	// against theme_available_names. That was tried and reverted: available
	// names come from a directory read (themes_dir()/os.read_all_directory_by_path)
	// that degrades to just the two built-ins on any failure, transient or
	// not (a OneDrive/enterprise-roaming lock on the Roaming %APPDATA% tree,
	// a momentary AV hold), so validating here meant a passing custom theme
	// name could be silently and PERMANENTLY discarded by the next
	// settings_save -- any zoom step, any split-divider drag. theme_resolve
	// already falls back to Dark for whatever it can't resolve, by design;
	// that is where an unresolvable name degrades, not here.
	theme_name:      string,
}

// Families present on this machine, in the curated order. Recomputed when the
// settings page opens rather than at startup: it is a handful of file-exists
// checks, but none of them are needed to draw the first frame.
font_choices: [dynamic]string

font_choices_refresh :: proc() {
	clear(&font_choices)
	for f in plat.FONT_FAMILIES {
		if plat.font_family_available(f) {append(&font_choices, f.name)}
	}
	if len(font_choices) == 0 {append(&font_choices, "Consolas")}
}

font_choice_index :: proc(name: string) -> int {
	for n, i in font_choices {
		if n == name {return i}
	}
	return 0
}

settings_default :: proc() -> Settings {
	return Settings {
		restore_session = true,
		wrap_default = false,
		font_size = int(BASE_PX_96),
		zoom_pct = ZOOM_DEFAULT,
		tab_width = plat.TAB_WIDTH_DEFAULT,
		font_family = "Consolas",
		font_style = .Regular,
		ui_font_family = "Cascadia Mono",
		link_style = .Hover,
		split_frac = SPLIT_DEFAULT,
		md_default = .Off,
		table_default = false,
		remember_views = true, // remembering is on by default; the toggle pins it
		theme_name = "Dark",
	}
}

@(private = "file")
settings_path :: proc() -> (string, bool) {
	dir, ok := session_dir() // honours NEWTPAD_SESSION_DIR, so tests stay isolated
	if !ok {
		return "", false
	}
	return fmt.tprintf("%s%csettings.txt", dir, '\\'), true
}

// The single reading of `tab_width`, called by BOTH settings_load and
// settings_save so the two ends cannot disagree about what a value means.
//
// 0 is "never set" -- a struct built before the field existed, a truncated
// settings.txt, a hand edit -- and resolves to the DEFAULT, not to
// TAB_WIDTH_MIN. Same reasoning as zoom_pct's `if == 0` one line above the save
// call, with teeth: a 0 clamped up to 1 makes every tab in every document one
// cell wide, which reads as the app silently changing a setting rather than as
// a default being applied. Anything else is a real choice and is clamped into
// range.
//
// Two sides normalising the same value differently is exactly the bug this
// replaces: save wrote 4 for a struct 0 while load turned a disk 0 into 1, so a
// file the save side would never have produced still had to be read, and was
// read the other way.
@(private = "file")
tab_width_normalise :: proc(n: int) -> int {
	if n == 0 {return plat.TAB_WIDTH_DEFAULT}
	return clamp(n, plat.TAB_WIDTH_MIN, plat.TAB_WIDTH_MAX)
}

// Hand-parsed `key value` lines, the same shape session.txt already uses.
// Unknown keys are ignored rather than fatal, so an older build reading a newer
// file degrades instead of failing.
settings_load :: proc() -> Settings {
	s := settings_default()
	path, ok := settings_path()
	if !ok {
		return s
	}
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil {
		return s
	}
	for line in strings.split_lines(string(data), context.temp_allocator) {
		parts := strings.split_n(strings.trim_space(line), " ", 2, context.temp_allocator)
		if len(parts) < 2 {continue}
		switch parts[0] {
		case "restore_session":
			s.restore_session = parts[1] == "1"
		case "wrap_default":
			s.wrap_default = parts[1] == "1"
		case "font_size":
			if n, pok := strconv.parse_int(parts[1]); pok {
				s.font_size = clamp(n, FONT_SIZE_MIN, FONT_SIZE_MAX)
			}
		case "zoom_pct":
			if n, pok := strconv.parse_int(parts[1]); pok {
				s.zoom_pct = clamp(n, ZOOM_STEPS[0], ZOOM_STEPS[len(ZOOM_STEPS) - 1])
			}
		case "tab_width":
			// Through the same normaliser the save side uses, deliberately: a 0
			// has to mean the same thing coming in as it does going out.
			if n, pok := strconv.parse_int(parts[1]); pok {
				s.tab_width = tab_width_normalise(n)
			}
		case "font_family":
			s.font_family = strings.clone(parts[1])
		case "ui_font_family":
			s.ui_font_family = strings.clone(parts[1])
		case "font_style":
			if n, pok := strconv.parse_int(parts[1]); pok && n >= 0 && n <= int(max(plat.Font_Style)) {
				s.font_style = plat.Font_Style(n)
			}
		case "link_style":
			if n, pok := strconv.parse_int(parts[1]); pok && n >= 0 && n <= int(max(Link_Style)) {
				s.link_style = Link_Style(n)
			}
		case "md_default":
			// Range-checked like font_style/link_style above: an out-of-range integer
			// (hand-edited, or a future build with more modes) degrades to the
			// default rather than becoming an invalid enum value every switch on
			// Md_Mode would then have to defend against.
			if n, pok := strconv.parse_int(parts[1]); pok && n >= 0 && n <= int(max(Md_Mode)) {
				s.md_default = Md_Mode(n)
			}
		case "table_default":
			s.table_default = parts[1] == "1"
		case "remember_views":
			s.remember_views = parts[1] == "1"
		case "split_frac":
			// Clamp here too, not just on save: a hand-edited or corrupted file could
			// carry a value that never went through the drag's own clamp.
			if n, pok := strconv.parse_f32(parts[1]); pok {
				s.split_frac = clamp(n, SPLIT_MIN, SPLIT_MAX)
			}
		case "theme_name":
			// Cloned unconditionally, same as font_family above -- see the
			// Settings.theme_name field comment for why an availability check
			// here is actively harmful rather than merely redundant.
			s.theme_name = strings.clone(parts[1])
		}
	}
	return s
}

settings_save :: proc(s: Settings) -> bool {
	path, ok := settings_path()
	if !ok {
		return false
	}
	// Normalise on the way out as well as in. A zero-valued field reaching disk
	// would come back clamped to the minimum, which is a silent setting change
	// rather than the default it was meant to be.
	s := s
	s.font_size = clamp(s.font_size, FONT_SIZE_MIN, FONT_SIZE_MAX)
	if s.zoom_pct == 0 {s.zoom_pct = ZOOM_DEFAULT}
	s.zoom_pct = clamp(s.zoom_pct, ZOOM_STEPS[0], ZOOM_STEPS[len(ZOOM_STEPS) - 1])
	s.tab_width = tab_width_normalise(s.tab_width)
	// Zero means "never set" (a literal built without this field, or a struct
	// that predates it) rather than a deliberate 0.0 fraction, which SPLIT_MIN
	// would silently misrepresent as a real user choice.
	if s.split_frac == 0 {s.split_frac = SPLIT_DEFAULT}
	s.split_frac = clamp(s.split_frac, SPLIT_MIN, SPLIT_MAX)
	body := fmt.tprintf(
		"newtpad-settings 1\nrestore_session %d\nwrap_default %d\nfont_size %d\nzoom_pct %d\ntab_width %d\nfont_family %s\nfont_style %d\nui_font_family %s\nlink_style %d\nsplit_frac %.4f\nmd_default %d\ntable_default %d\nremember_views %d\ntheme_name %s\n",
		1 if s.restore_session else 0,
		1 if s.wrap_default else 0,
		s.font_size,
		s.zoom_pct,
		s.tab_width,
		s.font_family if s.font_family != "" else "Consolas",
		int(s.font_style),
		s.ui_font_family if s.ui_font_family != "" else "Cascadia Mono",
		int(s.link_style),
		s.split_frac,
		int(s.md_default),
		1 if s.table_default else 0,
		1 if s.remember_views else 0,
		s.theme_name if s.theme_name != "" else "Dark",
	)
	return plat.file_write_atomic(path, transmute([]u8)body)
}

// --- the page ---

Setting_Row :: struct {
	label: string,
	help:  string,
}

// Font lives under Edit > Font, not here: it is something you reach for while
// working, not a preference you set once. These are the set-and-forget ones.
SETTINGS_ROWS := []Setting_Row {
	{"Restore session on launch", "Reopen the tabs you had open, including unsaved ones"},
	{"Word wrap new documents", "Long lines fold to the window width instead of running off"},
	{"Zoom", "Ctrl+= / Ctrl+- / Ctrl+0 anywhere"},
	{"Show links", "When URLs and paths are highlighted (Ctrl+click always opens)"},
	// Appended, not inserted -- settings_draw's value switch below is index-based
	// against this array, so inserting here would shift every later row's value
	// to the wrong label.
	{"Markdown default view", "Applied when a .md/.markdown file opens fresh (Ctrl+M cycles)"},
	{"Table default view", "Applied when a .csv/.tsv file opens fresh (Ctrl+T toggles)"},
	{"Remember last view used", "Toggling a view updates the two defaults above; off pins them"},
	{"Theme", "Dark, Light, or a custom .theme file placed in the themes folder"},
	{"Tab width", "Columns a Tab advances to; Left/Right adjust, Enter resets to 4"},
	{"Interface font", "Tabs, menus, settings and the status bar; the document keeps its own font"},
}

settings_row_count :: proc() -> int {return len(SETTINGS_ROWS)}

// Rows that fit in height `h` starting at row `from`, given the fixed row
// height `rowh` -- the settings-page analogue of menu.odin's rows_fitting.
// Reused rather than reinvented (IMPORTANT 3 in the final review named this
// explicitly): all settings rows are the same height, so this collapses to a
// bound division, but keeping the same accumulate-until-it-doesn't-fit shape
// as the dropdown's version means a future row of different height costs
// nothing extra here, and settings_draw and this proc can never disagree
// about what fits because there is only the one computation.
settings_rows_fitting :: proc(from: int, h, rowh: f32) -> (count: int) {
	used := f32(0)
	for i := from; i < settings_row_count(); i += 1 {
		if used + rowh > h {return}
		used += rowh
		count += 1
	}
	return
}

// Scroll `top` the minimum needed to keep `row` visible. Mirrors
// menu_resolve_top exactly -- grow `top` one row at a time until the
// selected row falls inside the run settings_rows_fitting says is visible.
settings_resolve_top :: proc(top, row: int, h, rowh: f32) -> int {
	t := top
	if row < t {t = row}
	for {
		n := settings_rows_fitting(t, h, rowh)
		if n == 0 {break}
		if row < t + n {break}
		t += 1
	}
	return clamp(t, 0, max(0, settings_row_count() - 1))
}

// Geometry of the row list: where it starts (below the page header), and how
// much vertical room it has before the version string. The one place both
// numbers come from, so settings_draw and a test asking "does everything fit"
// read the same values instead of each hardcoding its own copy of the header
// height and footer reservation -- which is exactly how the 8th row's help
// text ended up overprinting the version string: the row loop grew but
// nothing that used height - sx(24) as a bottom bound ever heard about it.
settings_list_bounds :: proc(height: f32) -> (y0, avail_h: f32) {
	y0 = CHROME_TOP + sx(40) + sx(56) // header title + subtitle, then the gap before row 0
	// The version string's baseline sits at height - sx(24); reserve its own
	// line height plus a gap above that, so the last visible row's help text
	// (drawn sx(16) below its label, still inside its rowh slot) can never
	// reach far enough down to touch it.
	avail_h = max(0, (height - sx(24) - sx(20)) - y0)
	return
}

// Caches holding measurements denominated in CELLS, on every open document.
//
// metrics_recompute and text_reset_atlas between them cover everything measured
// in PIXELS -- that is what a font or zoom change moves, and it is why those two
// were enough until tab width became configurable. A tab-width change moves the
// cell counts themselves, and neither of these two caches is keyed on anything
// that notices:
//
//   - doc.md_table is keyed on doc.revision, which only an edit bumps.
//   - doc.table_widths is cleared only by edits and by entering/leaving the grid.
//
// So without this, changing Tab width from 4 to 8 with a markdown preview or a
// CSV grid open leaves the columns sized against the old tab stops until the
// next edit: text overhangs its column, and the alignment padding is computed
// against a width the column was never sized for.
@(private = "file")
cell_caches_invalidate :: proc(app: ^App) {
	for d in app.docs { 	// slot array: nil is a closed tab
		if d == nil {continue}
		clear(&d.table_widths) // table_draw refits when it is empty
		for &c in d.md_table {c.valid = false}
		// The third cell-denominated cache, and the one two earlier passes
		// missed: doc_cursor_col keys only on (cursor, pt.length), so with the
		// caret sitting after a mid-line tab the status bar keeps reporting the
		// old Col N until the caret moves. Cosmetic and self-correcting, but it
		// is the same class as the two above and belongs in the same place.
		d.status_col_valid = false
	}
}

// Apply a setting change that affects live state.
settings_apply :: proc(rc: ^Render_Ctx) {
	s := rc.app.settings
	// Zoom multiplies the preferred size; the DPI scale is applied on top of the
	// result inside metrics_recompute.
	BASE_PX = f32(clamp(s.font_size, FONT_SIZE_MIN, FONT_SIZE_MAX)) * f32(s.zoom_pct) / 100
	// Before the invalidation below, not after: every cached cell measurement on
	// a line with a tab is wrong once the spacing moves, so the reset has to be
	// the last thing that happens. text_set_tab_width clamps, so a 0 arriving
	// from a struct that predates the field cannot reach the measuring loops.
	//
	// Read the effective width on both sides of the write rather than comparing
	// s.tab_width to itself: text_set_tab_width clamps, so 0, -5 and 99 are all
	// no-ops against an already-clamped value and must not cost a walk of every
	// open document on every zoom step.
	tab_before := plat.text_tab_width(rc.text)
	plat.text_set_tab_width(rc.text, s.tab_width)
	if plat.text_tab_width(rc.text) != tab_before {cell_caches_invalidate(rc.app)}
	metrics_recompute(rc)
	plat.text_reset_atlas(rc.text) // px changed: cached glyphs are the wrong size
}

// Step the zoom. dir 0 resets to 100%.
zoom_adjust :: proc(rc: ^Render_Ctx, dir: int) {
	s := &rc.app.settings
	if dir == 0 {
		s.zoom_pct = ZOOM_DEFAULT
	} else {
		i := clamp(zoom_step_index(s.zoom_pct) + dir, 0, len(ZOOM_STEPS) - 1)
		s.zoom_pct = ZOOM_STEPS[i]
	}
	settings_apply(rc)
	settings_save(s^)
}

settings_toggle_row :: proc(rc: ^Render_Ctx, row, dir: int) {
	s := &rc.app.settings
	switch row {
	case 0:
		if dir == 0 {s.restore_session = !s.restore_session}
	case 1:
		if dir == 0 {s.wrap_default = !s.wrap_default}
	case 2:
		zoom_adjust(rc, dir if dir != 0 else 0) // Enter on this row resets
		return // zoom_adjust already applied and saved
	case 3:
		n := int(max(Link_Style)) + 1
		step := dir if dir != 0 else 1 // Enter cycles forward; Left/Right step
		s.link_style = Link_Style((int(s.link_style) + step + n) % n)
	case 4:
		n := int(max(Md_Mode)) + 1
		step := dir if dir != 0 else 1 // Enter cycles forward; Left/Right step
		s.md_default = Md_Mode((int(s.md_default) + step + n) % n)
	case 5:
		if dir == 0 {s.table_default = !s.table_default}
	case 6:
		if dir == 0 {s.remember_views = !s.remember_views}
	case 7:
		names := theme_available_names(context.temp_allocator)
		cur := 0
		for n, i in names {
			if n == s.theme_name {
				cur = i
				break
			}
		}
		step := dir if dir != 0 else 1 // Enter cycles forward; Left/Right step
		nn := len(names)
		s.theme_name = strings.clone(names[((cur + step) % nn + nn) % nn])
		g_theme = theme_resolve(s.theme_name)
	case 9:
		// Cycled through the same curated, installed-only list the Font screen
		// offers, so the chrome can never land on a family that is not there.
		// The document's font stays on Edit > Font: it is reached while working,
		// where this is set once.
		if len(font_choices) > 0 {
			cur := 0
			for n, i in font_choices {
				if n == s.ui_font_family {
					cur = i
					break
				}
			}
			step := dir if dir != 0 else 1
			s.ui_font_family = font_choices[(cur + step + len(font_choices)) % len(font_choices)]
		}
	case 8:
		// Stepped, not cycled: 16 values is too many to reach by pressing Enter,
		// and the useful ones (2, 4, 8) are all within a few Rights of each
		// other. Enter resets to the default instead -- the same affordance the
		// Zoom row already uses.
		if dir == 0 {
			s.tab_width = plat.TAB_WIDTH_DEFAULT
		} else {
			s.tab_width = clamp(s.tab_width + dir, plat.TAB_WIDTH_MIN, plat.TAB_WIDTH_MAX)
		}
	}
	settings_apply(rc)
	settings_save(s^)
}

// Load the chosen family/style. The cell width comes from the new face, so the
// layout metrics and the glyph cache both have to follow.
settings_apply_font :: proc(rc: ^Render_Ctx) {
	s := rc.app.settings
	// .Doc only — the chrome keeps its own typeface, so choosing a font for your
	// text can never make the menus unreadable.
	if !plat.text_load_family(rc.text, s.font_family, s.font_style, .Doc) {
		// Keep the previous face rather than leaving nothing to draw with.
		return
	}
	metrics_recompute(rc)
}

settings_draw :: proc(gfx: ^plat.Gfx, qp: ^plat.Quad_Pipeline, t: ^plat.Text, app: ^App, width, height: f32) {
	// Full-window page: cover the content area entirely so no document shows
	// through and it reads as a distinct place, not an overlay.
	plat.quads_draw(gfx, qp, []plat.Quad{{pos = {0, CHROME_TOP}, size = {width, height - CHROME_TOP}, color = g_theme[.Bg_Base]}})

	// 28, matching the value column's right inset -- UI spec 11 asks for the same
	// margin on both sides, and the page indenting at 32 while the chrome pads at
	// 8-14 is what made the two halves look unrelated.
	x := sx(28)
	y := CHROME_TOP + sx(40)
	plat.text_draw(gfx, t, "Settings", x, y, UI_PX * 1.4, g_theme[.Text_Primary])
	plat.text_draw(gfx, t, "Esc closes    Up/Down choose    Enter toggles", x, y + sx(22), UI_SMALL_PX, g_theme[.Text_Muted])

	rowh := sx(46)
	y0, avail_h := settings_list_bounds(height)
	// Scroll the minimum needed to keep the selected row visible -- the same
	// pattern menu_draw_dropdown already uses via menu_scroll_to_item, reused
	// rather than reinvented (IMPORTANT 3 in the final review named this
	// explicitly as the preferred fix).
	app.settings_top = settings_resolve_top(app.settings_top, app.settings_row, avail_h, rowh)
	shown := settings_rows_fitting(app.settings_top, avail_h, rowh)
	last := app.settings_top + shown

	y = y0
	for i := app.settings_top; i < last; i += 1 {
		r := SETTINGS_ROWS[i]
		sel := i == app.settings_row
		if sel {
			// A wash PLUS a 2px accent bar, not a full-width band. UI spec 11:
			// "the full-width blue band in the screenshot is the loudest thing on
			// it; a wash plus a bar is unmistakable and quiet". The bar is also
			// what keeps the selection legible for anyone the wash alone is too
			// subtle for -- never colour alone (spec 18, 1.4.1).
			rx, ry := x - sx(12), y - sx(16)
			rw, rh := width - sx(52), rowh - sx(6)
			plat.quads_draw(
				gfx,
				qp,
				[]plat.Quad {
					{pos = {rx, ry}, size = {rw, rh}, color = g_theme[.Accent_Wash], radius = {RADIUS_ROW, RADIUS_ROW, RADIUS_ROW, RADIUS_ROW}},
					{pos = {rx, ry}, size = {max(2, sx(2)), rh}, color = g_theme[.Accent]},
				},
			)
		}
		plat.text_draw(gfx, t, r.label, x, y, UI_PX, g_theme[.Text_Primary])
		plat.text_draw(gfx, t, r.help, x, y + sx(16), UI_SMALL_PX, g_theme[.Text_Muted])

		val: string
		switch i {
		case 0:
			val = "On" if app.settings.restore_session else "Off"
		case 1:
			val = "On" if app.settings.wrap_default else "Off"
		case 2:
			val = fmt.tprintf("%d%%", app.settings.zoom_pct)
		case 3:
			val = link_style_name(app.settings.link_style)
		case 4:
			val = md_mode_name(app.settings.md_default)
		case 5:
			val = "Table" if app.settings.table_default else "Off"
		case 6:
			val = "On" if app.settings.remember_views else "Off"
		case 7:
			val = app.settings.theme_name
		case 8:
			val = fmt.tprintf("%d", app.settings.tab_width)
		case 9:
			val = app.settings.ui_font_family
		}
		vc := g_theme[.Success] if val != "Off" else g_theme[.Text_Muted]
		// The selected row's value brightens, per UI spec 11 -- the row you are
		// about to change should say which value you are about to change.
		if sel && val != "Off" {vc = g_theme[.Md_Heading]}
		vx := width - sx(220)
		plat.text_draw(gfx, t, val, vx, y, UI_PX, vc)
		// Show the affordance ON the row: a cycling value gets guillemets, so a
		// row you can step through looks different from one you cannot. Dimmed
		// on the rows that only toggle, which have nowhere to step to.
		if sel {
			cw := plat.text_char_width(t, UI_SMALL_PX)
			cyc := i == 2 || i == 4 || i == 5 || i == 7 || i == 8 || i == 9
			ac := g_theme[.Text_Muted] if cyc else g_theme[.Text_Dim]
			plat.text_draw(gfx, t, "<", vx - sx(18), y, UI_SMALL_PX, ac)
			plat.text_draw(gfx, t, ">", width - sx(40) - cw, y, UI_SMALL_PX, ac)
		}
		y += rowh
	}

	// Say there's more, the same affordance menu_draw_dropdown uses for a
	// clipped dropdown -- silently truncating a scrolled list is what hid
	// Edit > Font there, and a short window with the Theme row selected is
	// exactly the case that would otherwise recur here.
	if app.settings_top > 0 {
		plat.text_draw(gfx, t, "▲ more above", x, y0 - sx(14), UI_SMALL_PX, g_theme[.Text_Muted])
	}
	if last < settings_row_count() {
		plat.text_draw(gfx, t, "▼ more below", x, y0 + avail_h + sx(2), UI_SMALL_PX, g_theme[.Text_Muted])
	}

	// Version, bottom-left — the one always-visible surface for it in the GUI
	// build (there is no console for --version once -subsystem:windows).
	plat.text_draw(gfx, t, fmt.tprintf("Newtpad v%s", NEWTPAD_VERSION), x, height - sx(24), UI_SMALL_PX, g_theme[.Text_Muted])

	// The one setting with a consequence worth stating outright. Anchored off
	// the version string, not off `y` (the last VISIBLE row's bottom) --
	// Restore-session is row 0, so once the list scrolls it can read "off"
	// while off-screen, and this note is about that setting, not about
	// whichever row happens to be on screen right now.
	if !app.settings.restore_session {
		plat.text_draw(
			gfx,
			t,
			"With restore off, unsaved buffers are still kept on disk — they just aren't reopened.",
			x,
			height - sx(44),
			UI_SMALL_PX,
			g_theme[.Accent],
		)
	}
}
