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
}

settings_default :: proc() -> Settings {
	return Settings {
		restore_session = true,
		wrap_default = false,
		font_size = int(BASE_PX_96),
		zoom_pct = ZOOM_DEFAULT,
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
	body := fmt.tprintf(
		"newtpad-settings 1\nrestore_session %d\nwrap_default %d\nfont_size %d\nzoom_pct %d\n",
		1 if s.restore_session else 0,
		1 if s.wrap_default else 0,
		s.font_size,
		s.zoom_pct,
	)
	return plat.file_write_atomic(path, transmute([]u8)body)
}

// --- the page ---

Setting_Row :: struct {
	label: string,
	help:  string,
}

SETTINGS_ROWS := []Setting_Row {
	{"Restore session on launch", "Reopen the tabs you had open, including unsaved ones"},
	{"Word wrap new documents", "Long lines fold to the window width instead of running off"},
	{"Font size", "Left / Right to adjust"},
	{"Zoom", "Ctrl+= / Ctrl+- / Ctrl+0 anywhere, or Ctrl+wheel"},
}

settings_row_count :: proc() -> int {return len(SETTINGS_ROWS)}

// Apply a setting change that affects live state.
settings_apply :: proc(rc: ^Render_Ctx) {
	s := rc.app.settings
	// Zoom multiplies the preferred size; the DPI scale is applied on top of the
	// result inside metrics_recompute.
	BASE_PX = f32(clamp(s.font_size, FONT_SIZE_MIN, FONT_SIZE_MAX)) * f32(s.zoom_pct) / 100
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
		d := dir if dir != 0 else 1
		s.font_size = clamp(s.font_size + d, FONT_SIZE_MIN, FONT_SIZE_MAX)
	case 3:
		zoom_adjust(rc, dir if dir != 0 else 0) // Enter on this row resets
		return // zoom_adjust already applied and saved
	}
	settings_apply(rc)
	settings_save(s^)
}

settings_draw :: proc(gfx: ^plat.Gfx, qp: ^plat.Quad_Pipeline, t: ^plat.Text, app: ^App, width, height: f32) {
	// Full-window page: cover the content area entirely so no document shows
	// through and it reads as a distinct place, not an overlay.
	plat.quads_draw(gfx, qp, []plat.Quad{{pos = {0, CHROME_TOP}, size = {width, height - CHROME_TOP}, color = {0.10, 0.12, 0.16, 1}}})

	x := sx(32)
	y := CHROME_TOP + sx(40)
	plat.text_draw(gfx, t, "Settings", x, y, UI_PX * 1.4, {0.94, 0.96, 0.99, 1})
	plat.text_draw(gfx, t, "Esc closes    Up/Down choose    Enter toggles", x, y + sx(22), UI_SMALL_PX, {0.50, 0.55, 0.64, 1})
	y += sx(56)

	rowh := sx(46)
	for r, i in SETTINGS_ROWS {
		sel := i == app.settings_row
		if sel {
			plat.quads_draw(gfx, qp, []plat.Quad{{pos = {x - sx(12), y - sx(16)}, size = {width - sx(52), rowh - sx(6)}, color = {0.18, 0.24, 0.34, 1}}})
		}
		plat.text_draw(gfx, t, r.label, x, y, UI_PX, {0.92, 0.94, 0.98, 1})
		plat.text_draw(gfx, t, r.help, x, y + sx(16), UI_SMALL_PX, {0.50, 0.55, 0.64, 1})

		val: string
		switch i {
		case 0:
			val = "On" if app.settings.restore_session else "Off"
		case 1:
			val = "On" if app.settings.wrap_default else "Off"
		case 2:
			val = fmt.tprintf("%d", app.settings.font_size)
		case 3:
			val = fmt.tprintf("%d%%", app.settings.zoom_pct)
		}
		vc := [4]f32{0.55, 0.85, 0.60, 1} if val != "Off" else [4]f32{0.55, 0.60, 0.70, 1}
		plat.text_draw(gfx, t, val, width - sx(120), y, UI_PX, vc)
		y += rowh
	}

	// The one setting with a consequence worth stating outright.
	if !app.settings.restore_session {
		plat.text_draw(
			gfx,
			t,
			"With restore off, unsaved buffers are still kept on disk — they just aren't reopened.",
			x,
			y + sx(20),
			UI_SMALL_PX,
			{0.80, 0.76, 0.50, 1},
		)
	}
}
