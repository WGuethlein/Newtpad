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

Color_Role :: enum u8 {
	// --- neutrals: 10 roles absorbing 42 values across 81 sites ---

	// #171C29 (2: main.odin:903,942 gutter/preview bg) + #1A1F29 (3:
	// ui_tabs.odin:27 tab strip, settings.odin:293 + fontpage.odin:45 full-page
	// bg) + #1C212B (1: palette.odin:277 body bg). Winner: #1A1F29 (3 sites).
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

	// --- syntax highlighting (batch 4) ---
	// Declared now so the lexers due in batch 4 emit role names from their
	// first line instead of new RGB literals that would need migrating right
	// after landing. Deliberately unused until then -- do not delete these as
	// dead code. theme_dark gives them an obviously-fake placeholder colour
	// (loud magenta) rather than leaving them zero, so a stray reference
	// before batch 4 lands would be visually obvious instead of invisible.
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

		.Syn_Keyword    = {1, 0, 1, 1},
		.Syn_String     = {1, 0, 1, 1},
		.Syn_Number     = {1, 0, 1, 1},
		.Syn_Comment    = {1, 0, 1, 1},
		.Syn_Type       = {1, 0, 1, 1},
		.Syn_Punct      = {1, 0, 1, 1},
		.Syn_Json_Key   = {1, 0, 1, 1},
		.Syn_Xml_Tag    = {1, 0, 1, 1},
		.Syn_Xml_Attr   = {1, 0, 1, 1},
	}
}
