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
	// Hover fill for any tab, menu row, settings row or palette row.
	//
	// Implicit today: every hover surface reaches for Selection_List or
	// Border_Subtle, so an author cannot make hover quieter than the keyboard
	// cursor -- which is the one distinction two-weight selection needs (spec
	// §6, "mouse hover uses bg_hover; keyboard cursor uses the accent fill").
	// A themer cannot change what has no name.
	Bg_Hover,
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
	// Fill behind a selected settings row and the filter band.
	//
	// A role and not "12% Accent over the surface", deliberately: an alpha wash
	// inverts on a light theme, where it must be DARKER than the page rather
	// than lighter. Storing the resolved surface colour is the only form that
	// survives an author replacing Accent in either direction.
	Accent_Wash,
	// The keyboard focus ring. Both built-ins give it the same value as Accent,
	// and it is still its own role: an author may want the accent quiet and
	// focus loud, and focus is the one cue that must never be tuned away for
	// aesthetics (spec §18, "if a thing can be reached with Tab, it draws the
	// ring"). Consumed by batch 13 through the pipeline this batch adds.
	Focus_Ring,
	// The scrollbar thumb. THE role this file has already asked for -- see the
	// second-candidate note on Text_Muted above, which records that Text_Muted
	// is both a text colour (gutter numbers, every hint line) AND this fill, so
	// "an author darkening it for gutter legibility unavoidably darkens the
	// thumb too; Light already shows this as a heavy near-black bar on a pale
	// track." That note ends "recorded so the next batch finds both candidates
	// together instead of re-discovering this one alone." This is that batch,
	// and the UI spec arrived at the same split independently.
	//
	// Border_Subtle, the other candidate recorded there, is NOT split here: its
	// two jobs (table hairline, active-tab fill) are both chrome on chrome,
	// while this one is a fill on the document canvas judged at 3:1 for
	// non-text contrast. Still open.
	Scrollbar_Thumb,
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
	// Fill behind a code span and a fenced block. Md_Code is a foreground and
	// there is no matching background, so a code span renders as coloured text
	// on the page rather than as a block -- the one markdown construct whose
	// whole visual job is to be a container.
	Md_Code_Bg,
	// #CCDBC7 (1: markdown.odin MD_ITALIC).
	Md_Italic,
	// #A8B89E (1: markdown.odin MD_QUOTE).
	Md_Quote,
	// Thematic breaks, table borders, and the h1/h2 underline in the preview.
	// All three draw with Border_Strong today (markdown.odin:559,694) -- a
	// CHROME role, shared with dropdown borders and the split divider -- so an
	// author tuning menu borders moves every markdown rule with them.
	Md_Rule,
	// The bookmark mark in the left margin (doc_bookmark_rects). A new role
	// rather than a reuse: the nearest existing candidates are Accent (the find
	// bar) and Caret, and a mark that changes colour when an author retunes the
	// find bar is the kind of coupling these roles exist to prevent. It is also
	// the one mark on the canvas that must read against the document
	// background, which is a different constraint from any chrome accent.
	Bookmark,
	// The find-match ticks on the vertical scrollbar (find_mark_rects). A new
	// role for the same reason Bookmark is one, plus a constraint no existing
	// role carries: this is the only accent drawn as a solid fill on the
	// scrollbar TRACK (Bg_Raised), so it is judged against that surface and not
	// against Bg_Base. Find_Match_Bg is the obvious candidate and is the wrong
	// one -- it is a wash tuned to sit *behind unchanged text* on the canvas
	// (deliberately dim, 1.64:1 in Light), and a 2px tick with that contrast is
	// not there at all. Same amber family as Find_Match_Bg on purpose, since
	// the tick and the in-document highlight are one feature; the value differs
	// because the job does.
	Match_Mark,

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
		// Warm neutrals, chroma under 0.02: every grey carries a trace of the
		// accent's hue. Cold greys read as tooling, warm greys read as paper,
		// and that is most of what the UI spec means by "cosy" (spec §1.3).
		// Ratios in the comments are WCAG relative luminance against Bg_Base,
		// computed rather than eyeballed -- this environment cannot render a
		// frame, and computation is the standard both built-ins already used.
		.Bg_Base         = {0.133, 0.122, 0.110, 1}, // #221F1C
		.Bg_Panel        = {0.110, 0.098, 0.090, 1}, // #1C1917
		.Bg_Raised       = {0.169, 0.153, 0.141, 1}, // #2B2724
		.Bg_Hover        = {0.188, 0.169, 0.153, 1}, // #302B27
		.Border_Subtle   = {0.196, 0.176, 0.157, 1}, // #322D28
		.Border_Strong   = {0.290, 0.263, 0.224, 1}, // #4A4339
		.Text_Muted      = {0.616, 0.573, 0.518, 1}, // #9D9284  5.4
		.Text_Dim        = {0.435, 0.400, 0.361, 1}, // #6F665C  2.9 DISABLED ONLY
		.Text_Secondary  = {0.702, 0.659, 0.592, 1}, // #B3A897  7.1
		.Text_Primary    = {0.804, 0.765, 0.706, 1}, // #CDC3B4  9.4
		.Text_Bright     = {0.949, 0.922, 0.878, 1}, // #F2EBE0  13.6

		.Selection_Doc   = {0.200, 0.259, 0.290, 1}, // #33424A -- Text_Primary on it: 8.9
		.Selection_List  = {0.227, 0.208, 0.184, 1}, // #3A352F
		.Caret           = {0.851, 0.608, 0.384, 1}, // #D99B62  7.3, drawn 2px wide
		// One accent, state only. If a colour is not saying selected / dirty /
		// focused / found / dangerous, it is a neutral (spec §1.3) -- that
		// single rule is what separates this palette from the accent-on-
		// everything look, and it is why Caret, Focus_Ring, Match_Mark and
		// Md_List_Mark's job all resolve to this one value.
		.Accent          = {0.851, 0.608, 0.384, 1}, // #D99B62  7.3
		.Accent_Wash     = {0.188, 0.157, 0.137, 1}, // #302823
		.Focus_Ring      = {0.851, 0.608, 0.384, 1}, // #D99B62
		// #746B61, 3.14:1 against Bg_Base -- NOT the UI spec's #3E3833.
		//
		// That value is annotated "3.0 against bg_base" in the spec and does
		// not measure it: #3E3833 computes to 1.42:1, less than half the
		// stated figure. It matters because spec §18 lists "scrollbar thumb
		// 3.0:1" as a WCAG 1.4.11 non-text-contrast compliance point, so
		// shipping the literal value would have made an accessibility claim
		// the palette does not meet. This is the lightest warm neutral that
		// actually clears 3:1; themetest asserts it so the next retune cannot
		// quietly drop back under.
		.Scrollbar_Thumb = {0.455, 0.420, 0.380, 1}, // #746B61  3.14
		.Find_Match_Bg   = {0.290, 0.220, 0.149, 1}, // #4A3826 -- Text_Primary on it: 7.3
		.Link            = {0.592, 0.765, 0.847, 1}, // #97C3D8  8.2
		.Warning         = {0.878, 0.643, 0.345, 1}, // #E0A458  7.6
		.Danger          = {0.753, 0.271, 0.231, 1}, // #C0453B -- white on it: 4.7
		.Success         = {0.616, 0.788, 0.627, 1}, // #9DC9A0  8.6
		.Filter_Bg       = {0.180, 0.157, 0.137, 1}, // #2E2823
		.Filter_Text     = {0.898, 0.710, 0.498, 1}, // #E5B57F  8.4 on Filter_Bg
		.Md_Heading      = {0.898, 0.710, 0.498, 1}, // #E5B57F  8.4 -- all six levels
		.Md_Code         = {0.592, 0.765, 0.847, 1}, // #97C3D8  8.2 -- same hue as Link: both point elsewhere
		.Md_Code_Bg      = {0.165, 0.153, 0.137, 1}, // #2A2723
		.Md_Italic       = {0.769, 0.718, 0.624, 1}, // #C4B79F  8.0
		.Md_Quote        = {0.651, 0.608, 0.545, 1}, // #A69B8B  5.6
		.Md_Rule         = {0.227, 0.204, 0.180, 1}, // #3A342E
		.Bookmark        = {0.592, 0.765, 0.847, 1}, // #97C3D8
		// 6.2:1 against Bg_Raised (#2B2724), the scrollbar track it is drawn
		// on -- judged there, not against Bg_Base, because that is the surface
		// under it. Find_Match_Bg measures 1.3:1 there and would be an
		// invisible tick, which is why these two stay separate roles even
		// though they are one feature.
		.Match_Mark      = {0.851, 0.608, 0.384, 1}, // #D99B62  6.2 on Bg_Raised

		// Five hues, one job each (spec §1.3). A sixth always looks arbitrary;
		// further token types are distinguished by LIGHTNESS within a hue,
		// which is why Syn_Json_Key is a bright neutral rather than a new
		// colour.
		//
		// Syn_Comment is pulled away from Text_Muted deliberately -- the
		// gutter line numbers are Text_Muted and sit immediately beside
		// comment text, and themetest asserts the separation. The UI spec sets
		// both to #9D9284, the SAME value, which would have failed that
		// assertion: it was written from screenshots and could not know the
		// gutter shares the role. Green instead -- comments are green nearly
		// everywhere and the convention is worth more than palette tidiness --
		// but muted rather than vivid (Wyatt: "maybe not such a vibrant bright
		// green in the dark mode"), at 4.7:1, still above the AA floor so
		// comments stay readable rather than merely present.
		// Syn_Punct is likewise kept clear of Text_Primary.
		.Syn_Keyword     = {0.820, 0.576, 0.820, 1}, // #D193D1  6.9  violet -- language words
		.Syn_String      = {0.404, 0.635, 0.635, 1}, // #67A2A2  5.7  teal -- literal content
		.Syn_Number      = {0.894, 0.714, 0.490, 1}, // #E4B67D  8.8  amber -- numbers, true/false/null
		.Syn_Comment     = {0.369, 0.561, 0.337, 1}, // #5E8F56  4.3  green, dim -- see the note above
		.Syn_Type        = {0.408, 0.529, 0.910, 1}, // #6887E8  4.9  blue -- types, tags, references
		.Syn_Punct       = {0.533, 0.506, 0.463, 1}, // #888176  4.2  braces, pipes, commas
		.Syn_Json_Key    = {0.937, 0.906, 0.859, 1}, // #EFE7DB  12.7 keys are the index you scan: brightest
		.Syn_Xml_Tag     = {0.820, 0.576, 0.820, 1}, // #D193D1  tags are keywords
		.Syn_Xml_Attr    = {0.894, 0.714, 0.490, 1}, // #E4B67D
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
		// Two deliberate departures from the previous light theme, both from
		// spec §1.2: the page is #FAF8F3 rather than pure white so it does not
		// glare beside a dark desktop, and the neutrals are warm rather than
		// blue-grey -- which is most of what made the old light theme feel
		// like a dev tool. Bg_Raised is LIGHTER than Bg_Base here; "raised"
		// means nearer the light in a light theme, which is the one rule that
		// does not survive inverting a dark palette.
		.Bg_Base         = {0.980, 0.973, 0.953, 1}, // #FAF8F3 -- warm paper, not white
		.Bg_Panel        = {0.933, 0.918, 0.886, 1}, // #EEEAE2
		.Bg_Raised       = {1.000, 1.000, 1.000, 1}, // #FFFFFF
		.Bg_Hover        = {0.910, 0.890, 0.851, 1}, // #E8E3D9
		.Border_Subtle   = {0.871, 0.847, 0.800, 1}, // #DED8CC
		.Border_Strong   = {0.725, 0.690, 0.635, 1}, // #B9B0A2
		.Text_Muted      = {0.420, 0.380, 0.337, 1}, // #6B6156  6.0
		.Text_Dim        = {0.604, 0.569, 0.525, 1}, // #9A9186  2.8 DISABLED ONLY
		.Text_Secondary  = {0.373, 0.341, 0.302, 1}, // #5F574D  7.2
		.Text_Primary    = {0.239, 0.216, 0.184, 1}, // #3D372F  10.6
		.Text_Bright     = {0.173, 0.149, 0.125, 1}, // #2C2620  13.6

		.Selection_Doc   = {0.812, 0.859, 0.886, 1}, // #CFDBE2 -- Text_Primary on it: 9.6
		.Selection_List  = {0.863, 0.839, 0.792, 1}, // #DCD6CA
		.Caret           = {0.627, 0.353, 0.118, 1}, // #A05A1E  4.8, drawn 2px wide
		.Accent          = {0.627, 0.353, 0.118, 1}, // #A05A1E  4.8
		.Accent_Wash     = {0.949, 0.902, 0.847, 1}, // #F2E6D8
		.Focus_Ring      = {0.627, 0.353, 0.118, 1}, // #A05A1E
		// #948D80, 3.10:1 against Bg_Base -- NOT the UI spec's #C9C2B5, which
		// is annotated "3.0 against bg_base" and measures 1.67:1. The same
		// error appears in the Dark file (#3E3833, annotated 3.0, measures
		// 1.42) -- two themes, one mistake, so it is systematic rather than a
		// typo. See the Dark note for why it matters: spec §18 cites this
		// 3.0 as a WCAG 1.4.11 compliance point.
		.Scrollbar_Thumb = {0.580, 0.553, 0.502, 1}, // #948D80  3.10
		.Find_Match_Bg   = {0.941, 0.875, 0.745, 1}, // #F0DFBE -- Text_Primary on it: 9.3
		.Link            = {0.122, 0.373, 0.471, 1}, // #1F5F78  6.4
		.Warning         = {0.604, 0.353, 0.071, 1}, // #9A5A12  5.1
		.Danger          = {0.698, 0.227, 0.188, 1}, // #B23A30 -- white on it: 5.4
		.Success         = {0.184, 0.420, 0.278, 1}, // #2F6B47  5.9
		.Filter_Bg       = {0.953, 0.910, 0.851, 1}, // #F3E8D9
		.Filter_Text     = {0.478, 0.290, 0.071, 1}, // #7A4A12  6.2 on Filter_Bg
		.Md_Heading      = {0.541, 0.329, 0.086, 1}, // #8A5416  6.1
		.Md_Code         = {0.122, 0.373, 0.471, 1}, // #1F5F78  6.4
		.Md_Code_Bg      = {0.941, 0.929, 0.894, 1}, // #F0EDE4
		.Md_Italic       = {0.361, 0.322, 0.251, 1}, // #5C5240  7.4
		.Md_Quote        = {0.420, 0.380, 0.337, 1}, // #6B6156  6.0
		.Md_Rule         = {0.871, 0.847, 0.800, 1}, // #DED8CC
		.Bookmark        = {0.122, 0.373, 0.471, 1}, // #1F5F78
		// Judged against Bg_Raised (#FFFFFF here), not Bg_Base: this is the
		// one accent drawn on the scrollbar track. 4.9:1 there -- above the
		// 3:1 non-text floor with margin, because a 2px tick has less area to
		// carry its contrast than a glyph does.
		.Match_Mark      = {0.627, 0.353, 0.118, 1}, // #A05A1E  4.9 on Bg_Raised

		// Five hues, matched to Dark's assignments so a file looks like the
		// same file in either theme: mauve keywords, green strings, amber
		// numbers, blue types, bright-neutral JSON keys. These are no longer
		// the "provisional placeholders" the previous note described -- they
		// are the spec's §1.2 values, chosen against this Bg_Base.
		//
		// Syn_Comment stays clear of Text_Muted for the reason recorded in
		// Dark: the gutter numbers are Text_Muted and sit beside comment text,
		// and themetest asserts the separation. The old note here said Light
		// "deliberately placed those two close together"; that is no longer
		// true, and the assertion now applies to both themes equally.
		.Syn_Keyword     = {0.494, 0.306, 0.494, 1}, // #7E4E7E  6.0  violet
		.Syn_String      = {0.231, 0.408, 0.408, 1}, // #3B6868  5.9  teal
		.Syn_Number      = {0.565, 0.416, 0.231, 1}, // #906A3B  4.6  amber
		.Syn_Comment     = {0.227, 0.325, 0.212, 1}, // #3A5336  8.0  green, dim
		.Syn_Type        = {0.275, 0.353, 0.600, 1}, // #465A99  6.2  blue
		.Syn_Punct       = {0.416, 0.388, 0.349, 1}, // #6A6359  5.6
		.Syn_Json_Key    = {0.173, 0.149, 0.125, 1}, // #2C2620  13.6 keys are the index you scan: darkest
		.Syn_Xml_Tag     = {0.494, 0.306, 0.494, 1}, // #7E4E7E
		.Syn_Xml_Attr    = {0.565, 0.416, 0.231, 1}, // #906A3B
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
	.Bg_Hover       = "bg_hover",
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
	.Accent_Wash    = "accent_wash",
	.Focus_Ring     = "focus_ring",
	.Scrollbar_Thumb = "scrollbar_thumb",
	.Find_Match_Bg  = "find_match_bg",
	.Link           = "link",
	.Warning        = "warning",
	.Danger         = "danger",
	.Success        = "success",
	.Filter_Bg      = "filter_bg",
	.Filter_Text    = "filter_text",
	.Md_Heading     = "md_heading",
	.Md_Code        = "md_code",
	.Md_Code_Bg     = "md_code_bg",
	.Md_Italic      = "md_italic",
	.Md_Quote       = "md_quote",
	.Md_Rule        = "md_rule",
	.Bookmark       = "bookmark",
	.Match_Mark     = "match_mark",
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
//
// No delete() before the clone below: settings_default leaves theme_name as
// the static literal "Dark" until settings.txt actually supplies a
// theme_name line (settings_load only clones then), so on a fresh install,
// or a settings.txt written before that key existed, this field can be a
// pointer into .rdata rather than heap memory -- freeing it would be
// HeapFree on read-only static memory. This leaks one short name string per
// theme switch -- the same leak the Settings theme cycle at
// settings.odin:353 already has, so the two sites are consistent rather
// than newly divergent.
theme_edit_current :: proc(app: ^App) -> bool {
	target, path, ok := theme_export(app.settings.theme_name, g_theme)
	if !ok {
		app_note(app, "[THEME NOT SAVED - could not write to the themes folder]")
		return false
	}
	if app.settings.theme_name != target {
		app.settings.theme_name = strings.clone(target)
		g_theme = theme_resolve(target)
		settings_save(app.settings)
	}
	app_open_path(app, path)
	return true
}

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
		fwd, _ := strings.replace_all(s, "\\", "/", context.temp_allocator)
		return strings.to_lower(fwd, context.temp_allocator)
	}
	if norm(path) != norm(theme_path) {
		return false
	}
	g_theme = theme_resolve(app.settings.theme_name)
	return true
}
