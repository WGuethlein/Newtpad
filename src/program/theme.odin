// Layer: program — the colour model. One role per semantic slot; a Theme is a
// TOTAL array over the enum, so adding a role forces every theme to supply a
// value rather than silently inheriting a zero (which is transparent black, an
// invisible hole rather than an obvious error).
//
// Dark is a *consolidation* of the 107 colour literals previously hand-picked
// per call site across src/program, not a literal transcription of all of
// them: a faithful one-role-per-literal model came to 66 roles (see
// docs/superpowers/specs/2026-07-25-theme-model-design.md, "Consolidation")
// and was rejected as a theme nobody would author. Clustering the 61 distinct
// values by chroma and luminance found the real structure -- ten neutral tiers
// absorbing 42 near-duplicate greys/blues across 81 call sites, and fifteen
// accents that carry real meaning and stay separate. That table is the single
// source of truth for both this file and themetest; do not re-derive it.
//
// Consequence: Dark is deliberately no longer pixel-identical to the
// pre-migration UI -- roughly 50 of the 107 call sites will shift by a small
// amount once Tasks 2/3 migrate onto these roles. The mechanical guard for
// that migration isn't "nothing changed", it's "every changed pixel was one
// of the literals this role's comment lists below" -- themetest checks
// exactly that, role by role.
package main

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"

Color_Role :: enum u8 {
	// --- neutrals: 10 roles absorbing 42 values across 81 sites ---

	// #171C29 (3: main.odin:903,942 gutter/preview bg + main.odin:842 the frame
	// clear behind the plain-text/table/markdown-preview canvas, found only
	// after the fact -- see doc_canvas_clear's comment) + #1A1F29 (3:
	// ui_tabs.odin:27 tab strip, settings.odin:293 + fontpage.odin:45 full-page
	// bg) + #1C212B (1: palette.odin:277 body bg). Tied at 3 sites (#171C29 vs
	// #1A1F29); chose #1A1F29 since its three sites span three separate files
	// (ui_tabs, settings, fontpage) vs #171C29's three, which all live in
	// main.odin.
	Bg_Base,
	// #1F242E (2: menu.odin bar + markdown.odin MD_CODEBG) + #1F2430 (1:
	// history.odin:113) + #212633 (1: menu.odin drop) + #242933 (1:
	// main.odin:1022 find bar bg) + #242936 (1: ui_tabs.odin:28 inactive tab) +
	// #262B38 (1: palette.odin:278 query bg). Winner: #1F242E (2 sites).
	Bg_Panel,
	// #292E38 (3: main.odin:923,959,972 scrollbar track) + #293345 (1:
	// table.odin:205 header row band). Winner: #292E38 (3 sites).
	Bg_Raised,
	// #333B4C (3: ui_tabs.odin:29,231,239 active-tab/overflow/plus fill) +
	// #3D4554 (1: table.odin:204 column separator). Winner: #333B4C (3 sites).
	Border_Subtle,
	// #475266 (2: ui_tabs.odin:172,193 caption/menu hover) + #4C576B (5:
	// history.odin:112, palette.odin:276, menu.odin border, markdown.odin
	// MD_RULE, main.odin:947 split divider). Winner: #4C576B (5 sites).
	Border_Strong,
	// #6B758A (1: menu.odin dim) + #6B788F (2: settings.odin:334,
	// doc.odin:2196 gutter numbers) + #6B7A99 (3: main.odin:924,960,973
	// scrollbar thumb) + #737D91 (4: history.odin:136, palette.odin:285,
	// fontpage.odin:97, main.odin:1122) + #7A8599 (1: history.odin:128) +
	// #808A9E (1: palette.odin:310) + #808CA3 (6: settings.odin:298,308,
	// history.odin:117, fontpage.odin:50,67,75). Winner: #808CA3 (6 sites).
	//
	// Second candidate role split (found in the final review, alongside
	// Border_Subtle's -- see theme_light's comment): this role is both a text
	// colour (gutter numbers, every hint line) AND a fill (the scrollbar
	// thumb, main.odin:924,960,973). An author darkening it for gutter
	// legibility unavoidably darkens the thumb too; Light already shows this
	// as a heavy near-black bar on a pale track. Not split here -- CLAUDE.md
	// principle 3 (fight options) and the same "the author decides, not this
	// batch" call Border_Subtle got -- but recorded so the next batch finds
	// both candidates together instead of re-discovering this one alone.
	Text_Muted,
	// #8C99B2 (3: settings.odin:327 off, markdown.odin MD_MUTED,
	// main.odin:1109 default status) + #94A3C2 (1: menu.odin chord) +
	// #99A3B8 (2: ui_tabs.odin:222, palette.odin:290) + #9EADCC (1:
	// palette.odin:315) + #A8B2C7 (1: ui_tabs.odin:220 inactive tab fg).
	// Winner: #8C99B2 (3 sites).
	Text_Dim,
	// #B8C2D6 (1: ui_tabs.odin:175 default caption fg) + #B8C7E0 (1:
	// palette.odin:295) + #BFC9DB (2: ui_tabs.odin:233,241) + #BFCCE0 (1:
	// fontpage.odin:85) + #CCD6E6 (2: ui_tabs.odin:195, palette.odin:306
	// default). Tied at 2 sites (#BFC9DB vs #CCD6E6); chose #CCD6E6 since its
	// two sites span two different widgets (hamburger icon, palette result
	// text) vs #BFC9DB's two sites both within ui_tabs.odin.
	Text_Secondary,
	// #DBE6F5 (3: table.odin:203, doc.odin:2172, markdown.odin MD_TEXT) +
	// #E0E8F5 (2: history.odin:127, fontpage.odin:83) + #E6EBF7 (1: menu.odin
	// fg) + #EBF0FA (5: ui_tabs.odin:220 active, settings.odin:307,
	// history.odin:115, palette.odin:282, fontpage.odin:64) + #F0F5FC (3:
	// table.odin:230, settings.odin:297, fontpage.odin:49) + #F2F5FC (1:
	// palette.odin:306 selected). Winner: #EBF0FA (5 sites).
	Text_Primary,
	// #F5F5FA (1: ui_tabs.odin:175 hot) + #FAFCFF (1: markdown.odin MD_BOLD) +
	// #FFFFFF (2: table.odin:249,252) + #D1E6FA (1: main.odin:1052 replace
	// text). Winner: #FFFFFF (2 sites).
	Text_Bright,

	// --- accents: 15 roles, each carrying real meaning ---

	// #334C7A (1: doc.odin:1989 in-document text selection).
	Selection_Doc,
	// #33476B (2: history.odin:123, palette.odin:303 selected list row) +
	// #334C73 (1: table.odin:246 cell being edited) + #3D4C6B (1: menu.odin
	// hover) + #2E3D57 (2: settings.odin:305, fontpage.odin:62 selected
	// settings row). Tied at 2 sites (#33476B vs #2E3D57); chose #33476B for
	// tighter fit with the role's name -- history/palette are literal
	// scrollable selection lists, settings/fontpage a single focus row.
	Selection_List,
	// #F2D959 (1: main.odin:927 editor caret).
	Caret,
	// #F2E08C (3: main.odin:1050,1055,1121 find-bar accent) + #CCC280 (1:
	// settings.odin:345 warning note). Winner: #F2E08C (3 sites).
	Accent,
	// #6B6129 (1: find.odin:581 "muted amber" match highlight).
	Find_Match_Bg,
	// #73B2FA (1: doc.odin:2158 LINK_COL).
	Link,
	// #F28C59 (1: main.odin:1109 warn branch of the status bar).
	Warning,
	// #BF2929 (1: ui_tabs.odin:172 close-caption hover).
	Danger,
	// #8CD999 (4: settings.odin:327 on, history.odin:129 current,
	// fontpage.odin:65, menu.odin check).
	Success,
	// #2E4233 (1: main.odin:988 filter banner bg).
	Filter_Bg,
	// #B2E6BD (1: main.odin:994 filter banner text).
	Filter_Text,
	// #B8D9FF (1: markdown.odin MD_HEAD).
	Md_Heading,
	// #F2CCA6 (1: markdown.odin MD_CODE).
	Md_Code,
	// #CCDBC7 (1: markdown.odin MD_ITALIC).
	Md_Italic,
	// #A8B89E (1: markdown.odin MD_QUOTE).
	Md_Quote,

	// --- syntax highlighting ---
	// Declared in batch 3 so batch 4's lexers could emit role names from their
	// first line instead of RGB literals needing migration right after landing.
	// That worked; what did not is that theme_dark kept the loud-magenta
	// "missing texture" placeholder these were given, through the entire batch 4
	// release -- every highlighted file rendered identically magenta in Dark in
	// v0.13.0. Both built-ins now hold real values and themetest fails if either
	// ever holds {1,0,1,1} again.
	Syn_Keyword,
	Syn_String,
	Syn_Number,
	Syn_Comment,
	Syn_Type,
	Syn_Punct,
	Syn_Json_Key,
	Syn_Xml_Tag,
	Syn_Xml_Attr,
}

Theme :: [Color_Role][4]f32

// This is NOT what forces theme_dark() to supply every role when one is
// added -- that guarantee is the language's: Odin rejects an incomplete
// keyed enumerated-array composite literal at compile time, so a role
// missing from the Theme{...} literal below is a compile error, not a
// silent zero (and #partial has no effect here -- it only applies to
// switch, never to composite literals). What this #assert actually guards
// is narrower: that Theme stays defined as [Color_Role][4]f32 two lines up
// rather than being hand-rolled to some fixed-size array that happens to
// match today's role count but silently decouples from the enum in a
// future refactor. Cheap to keep, but read it as guarding that decoupling,
// not as the reason adding a role can't be forgotten -- the same role
// command_table's [Command_Id]Command array plays for the command list.
#assert(len(Theme) == len(Color_Role))

// Read per visible row and per chrome element every frame: an array index on a
// global, never a lookup that can allocate or fail.
g_theme: Theme

// The document-canvas clear colour. The plain-text, table, and markdown-preview
// paths draw no full-content background quad of their own (only the H_SCROLL
// margin strip, the split-mode right half, and the Settings/Font pages do) --
// so whatever render_frame clears the backbuffer to before drawing IS the
// canvas underneath the document text. This proc is the one place that answer
// comes from: render_frame calls it instead of holding its own copy, and
// themetest reads it too, so the two cannot independently drift the way
// main.odin:842's `gfx_begin_frame(gfx, 0.09, 0.11, 0.16)` once did -- a loose
// three-scalar literal that matched none of this batch's `{r, g, b, a}` greps
// and quietly left the canvas on Dark's old value after Light shipped, making
// Light's Text_Primary (#1E2430, near-black) draw on a near-black canvas.
doc_canvas_clear :: proc() -> [4]f32 {
	return g_theme[.Bg_Base]
}

// The theme in use today. Each role's value is the winner (most call sites)
// of the merged set documented on the enum above -- see the spec's role
// table for the full absorbed-value lists. No call site has been migrated
// onto g_theme yet (that is Tasks 2 and 3), so populating this changes
// nothing on screen today; the ~50 sites whose literal isn't the winner will
// shift slightly once they're migrated, which is the intended, measured cost
// of consolidating 66 roles down to 25.
theme_dark :: proc() -> Theme {
	return Theme {
		.Bg_Base        = {0.10, 0.12, 0.16, 1}, // #1A1F29
		.Bg_Panel       = {0.12, 0.14, 0.18, 1}, // #1F242E
		.Bg_Raised      = {0.16, 0.18, 0.22, 1}, // #292E38
		.Border_Subtle  = {0.20, 0.23, 0.30, 1}, // #333B4C
		.Border_Strong  = {0.30, 0.34, 0.42, 1}, // #4C576B
		.Text_Muted     = {0.50, 0.55, 0.64, 1}, // #808CA3
		.Text_Dim       = {0.55, 0.60, 0.70, 1}, // #8C99B2
		.Text_Secondary = {0.80, 0.84, 0.90, 1}, // #CCD6E6
		.Text_Primary   = {0.92, 0.94, 0.98, 1}, // #EBF0FA
		.Text_Bright    = {1, 1, 1, 1}, // #FFFFFF

		.Selection_Doc  = {0.20, 0.30, 0.48, 1}, // #334C7A
		.Selection_List = {0.20, 0.28, 0.42, 1}, // #33476B
		.Caret          = {0.95, 0.85, 0.35, 1}, // #F2D959
		.Accent         = {0.95, 0.88, 0.55, 1}, // #F2E08C
		.Find_Match_Bg  = {0.42, 0.38, 0.16, 1}, // #6B6129
		.Link           = {0.45, 0.70, 0.98, 1}, // #73B2FA
		.Warning        = {0.95, 0.55, 0.35, 1}, // #F28C59
		.Danger         = {0.75, 0.16, 0.16, 1}, // #BF2929
		.Success        = {0.55, 0.85, 0.60, 1}, // #8CD999
		.Filter_Bg      = {0.18, 0.26, 0.20, 1}, // #2E4233
		.Filter_Text    = {0.70, 0.90, 0.74, 1}, // #B2E6BD
		.Md_Heading     = {0.72, 0.85, 1.0, 1}, // #B8D9FF
		.Md_Code        = {0.95, 0.80, 0.65, 1}, // #F2CCA6
		.Md_Italic      = {0.80, 0.86, 0.78, 1}, // #CCDBC7
		.Md_Quote       = {0.66, 0.72, 0.62, 1}, // #A8B89E

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
	}
}

// A genuinely designed light theme, not theme_dark inverted. Every one of the
// 107 pre-migration literals was chosen by eye against a dark background, so
// carrying a role's dark value (or its naive per-channel inversion) onto a
// light background is not a shortcut here -- it is the specific failure this
// theme exists to avoid. See task-4-report.md for the full contrast-ratio
// workings (WCAG relative-luminance ratios, computed, not eyeballed -- this
// environment cannot render a frame) and the roles that did not survive a
// straight lightening pass:
//
//   - Caret: dark's #F2D959 (pale gold) is a 1.42:1 smudge on white -- a caret
//     that cannot be found, exactly the failure mode the task brief named.
//     Light instead deepens the same gold hue to a saturated amber (#946200,
//     ~5.3:1) so the identity survives, not just the label.
//   - Border_Subtle does double duty as a hairline (table column separator)
//     and as the active-tab/overflow/plus-hover fill. On dark the fill value
//     is *lighter* than its surroundings, which pops on a dark strip; on
//     white nothing can be lighter than the base, so both jobs are forced to
//     want "darker" and one value cannot serve them. That geometric argument
//     is the reason to split, not the ratios: light measures 1.90:1 for the
//     hairline and 1.69:1 for the active-tab pop, which are actually *better*
//     than dark's own 1.47:1 and 1.39:1 for the same pairings. Reported, not
//     fixed, because fixing it means splitting the role.
//   - Text_Bright/Danger: the tab-close hover icon pairs whatever Text_Bright
//     is with a fixed red fill. Dark pairs white-on-red (5.89:1); light's
//     darkest text (needed elsewhere for body-text emphasis) pairs
//     near-black-on-red (3.18:1) -- still clears the 3:1 non-text UI
//     threshold, but by less margin than dark had.
//
// Danger is the one role deliberately unchanged from Dark: it is a solid,
// fully-opaque hover fill never blended with either theme's chrome, used only
// for the close-tab affordance, and Windows itself renders that hover in the
// same red regardless of system theme. Every other role's value had to move
// because the surface it sits against moved; Danger's surface (its own
// opaque quad) didn't.
theme_light :: proc() -> Theme {
	return Theme {
		.Bg_Base        = {1.00, 1.00, 1.00, 1}, // #FFFFFF -- document canvas + tab-strip rest state
		.Bg_Panel       = {0.93, 0.95, 0.96, 1}, // #EEF1F6 -- menu bar, history, query field, inactive tab
		.Bg_Raised      = {0.89, 0.91, 0.93, 1}, // #E2E7EE -- scrollbar track, table header band
		.Border_Subtle  = {0.70, 0.74, 0.80, 1}, // #B3BDCC -- table separator + active-tab fill (see note above: weak pop)
		.Border_Strong  = {0.45, 0.51, 0.60, 1}, // #748199 -- dividers, dropdown borders, caption-hover fill
		.Text_Muted     = {0.36, 0.40, 0.46, 1}, // #5D6776 -- gutter numbers, hints, scrollbar thumb (5.8:1 on white)
		.Text_Dim       = {0.30, 0.34, 0.40, 1}, // #4C5666 -- chords, bullets, inactive-tab fg (7.4:1 on white)
		.Text_Secondary = {0.23, 0.26, 0.31, 1}, // #3A4250 -- default row/caption text (10.1:1 on white)
		.Text_Primary   = {0.12, 0.14, 0.19, 1}, // #1E2430 -- document text, headings, active tab (15.6:1 on white)
		.Text_Bright    = {0.06, 0.07, 0.10, 1}, // #10131A -- bold emphasis, table header/edit text (18.7:1 on white)

		// #BFD6F2 measured 1.48:1 against Bg_Base -- the in-document text
		// selection, drawn as an opaque quad behind unchanged Text_Primary
		// glyphs (doc.odin:1989-2004) with NO other cue that anything is
		// selected (no border, no text recolour), the same "the fill is the
		// only cue" shape Selection_List had, and the single most-used
		// highlight in the app. Darkened past the same 1.6:1 bar: this value
		// measures 1.83:1 against Bg_Base, with Text_Primary still at 8.5:1
		// on top of it (was 10.5:1 -- comfortably above the 4.5:1 AA text
		// floor either way).
		.Selection_Doc  = {0.68, 0.76, 0.85, 1}, // #ADC2D9
		// #E1E6EE measured 1.12:1 against Bg_Panel -- menu-bar title hover, the
		// gear hover, the dropdown item highlight, and the history selected row
		// all use this fill with NO other cue (keyboard menu navigation has
		// nothing else marking the selected item), so that was a near-invisible
		// selection. Darkened to clear Dark's own separation (1.68:1 against its
		// Bg_Panel): this value measures 1.64:1 against Light's Bg_Panel and
		// 1.85:1 against Bg_Base, with Text_Primary still at 8.4:1 on top of it.
		.Selection_List = {0.70, 0.75, 0.84, 1}, // #B3BFD6
		.Caret          = {0.58, 0.38, 0.00, 1}, // #946200 -- deepened gold, not lightened (see note above)
		.Accent         = {0.54, 0.43, 0.12, 1}, // #8A6D1F -- same gold family as Caret, lower chroma for running text
		// #F0E4B8 measured 1.28:1 against Bg_Base -- find.odin's
		// find_match_rects draws this as a dim wash behind unchanged fg text
		// for every match but the one under the caret/selection, so most
		// matches on screen have no cue but this fill: the same
		// "fill-is-the-only-cue" shape as Selection_Doc/Selection_List, just
		// not named in the original brief. Darkened past the same 1.6:1 bar:
		// this value measures 1.64:1 against Bg_Base, staying deliberately
		// closer to that floor than Selection_Doc's 1.83:1 so the match
		// highlight stays visibly *dimmer* than the selection it can sit
		// under (main.odin: "find-match highlights (dim), then the selection
		// (bright)"). Text_Primary on top: 9.5:1 (was 12.1:1).
		.Find_Match_Bg  = {0.84, 0.79, 0.64, 1}, // #D6C9A3 -- amber wash; text drawn on top is unchanged dark fg
		.Link           = {0.11, 0.37, 0.66, 1}, // #1B5FA8 -- dark's #73B2FA is 2.2:1 on white; deepened to 6.5:1
		.Warning        = {0.71, 0.28, 0.06, 1}, // #B5480F -- burnt orange, legible as status text on Bg_Panel (4.8:1)
		.Danger         = {0.75, 0.16, 0.16, 1}, // #BF2929 -- SAME as Dark, deliberately (see note above)
		.Success        = {0.12, 0.48, 0.24, 1}, // #1E7A3C -- deep green, legible on Bg_Base and Bg_Panel (5.3/4.8:1)
		.Filter_Bg      = {0.86, 0.93, 0.87, 1}, // #DCEEDF -- pale green wash for the filter banner
		.Filter_Text    = {0.12, 0.36, 0.20, 1}, // #1F5C34 -- deep green text on Filter_Bg (6.6:1)
		.Md_Heading     = {0.09, 0.30, 0.53, 1}, // #164C86 -- deep blue heading text (8.6:1 on white)
		.Md_Code        = {0.54, 0.29, 0.13, 1}, // #8A4A22 -- terracotta; legible on Bg_Base and the code-block Bg_Panel fill
		.Md_Italic      = {0.25, 0.36, 0.23, 1}, // #3F5C3A -- deep moss green (7.5:1 on white)
		.Md_Quote       = {0.33, 0.38, 0.30, 1}, // #55614C -- deep olive, used for both the quote bar and its text (6.6:1)

		// Deliberate light-appropriate placeholders, not magenta: batch 4 has
		// no consumer for these yet, but a light theme with magenta holes
		// would be a trap for whoever wires syntax highlighting up next.
		// Provisional -- chosen for legibility and mutual distinctness on
		// Bg_Base, not validated against real code on screen.
		.Syn_Keyword    = {0.23, 0.36, 0.86, 1}, // #3B5BDB -- indigo
		.Syn_String     = {0.09, 0.51, 0.31, 1}, // #17824E -- green
		.Syn_Number     = {0.71, 0.34, 0.04, 1}, // #B5560A -- burnt orange
		.Syn_Comment    = {0.44, 0.48, 0.53, 1}, // #707A88 -- muted slate (deliberately near Text_Muted's tone)
		.Syn_Type       = {0.04, 0.45, 0.52, 1}, // #0B7285 -- teal
		.Syn_Punct      = {0.27, 0.29, 0.35, 1}, // #444B58 -- dark neutral, low-emphasis
		.Syn_Json_Key   = {0.61, 0.26, 0.13, 1}, // #9C4221 -- rust
		.Syn_Xml_Tag    = {0.71, 0.09, 0.35, 1}, // #B5165A -- rose/maroon
		.Syn_Xml_Attr   = {0.42, 0.31, 0.71, 1}, // #6B4FB6 -- violet
	}
}

// --- theme files ---
//
// %APPDATA%\Newtpad\themes\*.theme, one `role #rrggbb` per line, plus one
// optional `base dark`/`base light` line anywhere in the file (see
// theme_load_file). Deliberately the same key/value shape as settings.txt
// (see settings_load's comment): unknown keys/roles are ignored so an older
// build reading a newer file degrades instead of failing, and a malformed
// value leaves that field at whatever it already was -- here, the base
// built-in's value for that role, rather than the zero value, which is
// transparent black and would render as an invisible hole instead of an
// obvious error.
//
// Built-in themes ("Dark", "Light") are never loaded from a file -- they are
// theme_dark()/theme_light() directly. A name that isn't one of those two is
// looked up as themes_dir()/<name>.theme, overlaid onto whichever built-in
// the file's own `base` key names (see theme_resolve). Per-role colour
// pickers are deliberately out of scope (CLAUDE.md principle 3, and the
// spec's "Out of scope" section) -- editing a .theme file by hand is the
// power-user path; the Settings row only ever picks a name.

// %APPDATA%\Newtpad\themes -- the path, with no side effects. Sibling of
// settings.txt and session.txt under the same session_dir(), so
// NEWTPAD_SESSION_DIR redirects this too and headless tests stay isolated
// from the real store.
//
// Deliberately does NOT create the directory: this is reachable from
// settings_load (theme_resolve -> themes_dir) at every startup, so a bare
// read of settings.txt was mkdir'ing a themes/ folder for every user who has
// never placed a custom theme -- harmless, but a read path with a write
// side effect nobody asked for. Both callers here are reads
// (os.read_all_directory_by_path in theme_available_names,
// os.read_entire_file via theme_load_file in theme_resolve) and both already
// degrade correctly when the directory doesn't exist. See themes_dir_ensure
// for the one place that genuinely needs the directory to be there.
themes_dir :: proc() -> (string, bool) {
	dir, ok := session_dir()
	if !ok {
		return "", false
	}
	return fmt.tprintf("%s%cthemes", dir, '\\'), true
}

// themes_dir(), guaranteed to exist on disk. Call this only at the point
// that actually needs to WRITE a theme file there -- never from a read path
// (see themes_dir's comment for why that distinction matters).
themes_dir_ensure :: proc() -> (string, bool) {
	dir, ok := themes_dir()
	if !ok {
		return "", false
	}
	os.make_directory(dir) // ignore "already exists"
	return dir, true
}

// Parses "#rrggbb" into a fully-opaque colour. Anything else -- wrong
// length, a missing '#', non-hex digits -- is malformed; the caller keeps
// whatever value the role already had rather than accepting this result, so
// a typo'd digit can never produce transparent black.
@(private = "file")
theme_parse_hex :: proc(s: string) -> (col: [4]f32, ok: bool) {
	if len(s) != 7 || s[0] != '#' {
		return {}, false
	}
	r, rok := strconv.parse_int(s[1:3], 16)
	g, gok := strconv.parse_int(s[3:5], 16)
	b, bok := strconv.parse_int(s[5:7], 16)
	if !rok || !gok || !bok {
		return {}, false
	}
	return {f32(r) / 255, f32(g) / 255, f32(b) / 255, 1}, true
}

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

// Hand-parsed `key value` lines, the same shape settings_load uses. Starts
// from a built-in -- Dark by default, or whichever one the file's own `base`
// line names -- and overlays only what the file supplies, so a file naming
// three roles is a valid theme: the other roles simply keep the base's
// value. Never returns a lower-quality result than that base -- an
// unreadable file, an unknown role, or a malformed colour each just skip
// that one line rather than touching the rest.
//
// `base` exists because a fixed "always overlay Dark" base made a
// light-based custom theme inexpressible: a user on Light who picked a
// custom theme naming even one role got every *other* role reset to Dark's
// values -- backgrounds, text, all of it flipping dark, a much bigger
// surprise than "a partial file is valid" implies. Overlaying whichever
// built-in was active before the switch was considered and rejected too --
// that would make a custom theme's appearance depend on Dark/Light history
// instead of the file itself, which is worse (non-deterministic from the
// file's point of view). Letting the file declare its own base fixes both:
// the file alone determines the theme's appearance, independent of what was
// selected before, and a light-based custom theme finally becomes
// expressible.
//
// `base` is recognized anywhere in the file, not just the first line -- this
// format has no ordering rules (settings.txt doesn't either), so resolving
// it is a first pass over every line before any role overlay is applied,
// rather than a single-pass fold that would only see a `base` line if it
// happened to come first. An absent or unrecognized value (`base solarized`,
// a typo, no `base` line at all) falls back to Dark, the same "malformed
// input degrades, never fails" contract theme_parse_hex/theme_role_from_key
// already use.
theme_load_file :: proc(path: string, base: Theme) -> Theme {
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil {
		return base
	}
	lines := strings.split_lines(string(data), context.temp_allocator)

	// Pass 1: resolve the base built-in from a `base` line, wherever it
	// falls. Starts at Dark so an absent or unrecognized value already
	// lands on the required fallback without a separate branch.
	t := theme_dark()
	for line in lines {
		parts := strings.split_n(strings.trim_space(line), " ", 2, context.temp_allocator)
		if len(parts) < 2 {continue}
		if strings.trim_space(parts[0]) != "base" {continue}
		switch strings.trim_space(parts[1]) {
		case "dark": t = theme_dark()
		case "light": t = theme_light()
		// anything else is malformed: leave t at whatever a prior valid
		// `base` line set it to, or Dark if none has appeared yet -- never
		// black, same fallback contract every other malformed value here has.
		}
	}

	// Pass 2: overlay named roles onto the base resolved above. `base`
	// itself is skipped explicitly rather than falling through to
	// theme_role_from_key's unknown-role branch -- it is not a role, and
	// must never be mistaken for one (theme_role_from_key has no "base"
	// case, so this is also independently enforced there).
	for line in lines {
		parts := strings.split_n(strings.trim_space(line), " ", 2, context.temp_allocator)
		if len(parts) < 2 {continue}
		key := strings.trim_space(parts[0])
		if key == "base" {continue}
		role, rok := theme_role_from_key(key)
		if !rok {continue}
		col, cok := theme_parse_hex(strings.trim_space(parts[1]))
		if !cok {continue} // malformed colour: role keeps base's value, never black
		t[role] = col
	}
	return t
}

// Names of every theme the Settings row can cycle to: the two built-ins
// first, then one entry per *.theme file under themes_dir() (its stem, the
// filename minus ".theme"). Directory-read order isn't guaranteed, so the
// tail may reorder between calls if files are added/removed -- only the two
// built-ins are stable. temp-allocated by default; pass a longer-lived
// allocator if the result must outlive the current frame/call.
theme_available_names :: proc(allocator := context.temp_allocator) -> []string {
	names := make([dynamic]string, allocator)
	append(&names, "Dark")
	append(&names, "Light")
	dir, ok := themes_dir()
	if !ok {
		return names[:]
	}
	infos, err := os.read_all_directory_by_path(dir, allocator)
	if err != nil {
		return names[:]
	}
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
	return names[:]
}

// Resolves a theme by name for both startup and the Settings row. "Dark"
// and "Light" are theme_dark()/theme_light() directly; anything else is
// looked up as themes_dir()/<name>.theme, overlaid onto whichever built-in
// the file's own `base` line names (theme_load_file), defaulting to Dark
// when the file has none. A name that resolves to nothing -- no themes dir,
// no such file, a stale settings.txt entry left over after the file was
// renamed or deleted -- falls back to Dark: theme_load_file already returns
// its `base` argument unchanged when the file can't be read, so this never
// needs a separate existence check.
theme_resolve :: proc(name: string) -> Theme {
	switch name {
	case "Dark":
		return theme_dark()
	case "Light":
		return theme_light()
	}
	dir, ok := themes_dir()
	if !ok {
		return theme_dark()
	}
	path := fmt.tprintf("%s%c%s.theme", dir, '\\', name)
	return theme_load_file(path, theme_dark())
}

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
theme_export :: proc(from_name: string, t: Theme) -> (target: string, path: string, ok: bool) {
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
		c := t[role]
		fmt.sbprintf(
			&b,
			"%s #%02X%02X%02X\n",
			theme_key_from_role(role),
			theme_chan_hex(c.r),
			theme_chan_hex(c.g),
			theme_chan_hex(c.b),
		)
	}

	if os.write_entire_file(path, transmute([]u8)strings.to_string(b)) != nil {
		return target, path, false
	}
	return target, path, true
}

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
	target, path, ok := theme_export(app.settings.theme_name, g_theme)
	if !ok {
		app_note(app, "[THEME NOT SAVED - could not write to the themes folder]")
		return false
	}
	if app.settings.theme_name != target {
		delete(app.settings.theme_name)
		app.settings.theme_name = strings.clone(target)
		g_theme = theme_resolve(target)
		settings_save(app.settings)
	}
	app_open_path(app, path)
	return true
}
