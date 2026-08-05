// Layer: platform — glyph atlas + grayscale text pipeline (D3D11 + DirectWrite).
// Rasterizes glyphs via the hand-declared DirectWrite bindings (dwrite.odin) into
// a shared coverage atlas, caches them, and draws cached glyphs as instanced
// quads. Coverage is DirectWrite's antialiased ClearType 3x1 with the three
// subpixels averaged to grayscale (see glyph_get) — no colour fringe, which is
// what read as "blur" once a glyph was magnified. COM stays in platform.
//
// Current scope (milestone): single font face, ASCII via GetGlyphIndices (a cmap
// lookup, NOT shaping). Shaping + font fallback (IDWriteTextAnalyzer) are the
// next milestone; keep the glyph-run construction fed by an explicit index list
// so shaping can replace the cmap path without reworking the raster/atlas.
// Atlas sizing: starts at ATLAS_START, doubles on demand to ATLAS_MAX, then
// recycles wholesale at a frame boundary (atlas_relieve / text_frame_begin).
// This comment used to say "grow-only for now; eviction is required before
// ship" — it outlived the §6j fix by seven months and, being a claim of
// ABSENCE, was never re-tested, so it propagated into HANDOFF §5, CLAUDE.md's
// roadmap and the 2026-07-25 feature audit, which ranked it a ship blocker
// whose failure mode was "your text silently vanishes." Measured 2026-07-26
// (`newtpad atlastest`, `newtpad atlasgrowtest`): at 4096² the atlas holds
// 61,425 glyphs at 16px and 9,768 at 48px (300% DPI); growth 1024→4096 is
// observed against a real device and `atlas_full` does not latch. One screen
// of text is far fewer distinct glyphs than that, so exhaustion is not
// reachable by a real document. LRU/generational eviction was consequently
// dropped from batch 7 — see HANDOFF §6ab.
package platform

import "core:fmt"
import "core:math"
import "core:mem"
import "core:os"
import "core:strings"
import "core:unicode/utf8"
import d3d "vendor:directx/d3d11"
import win "core:sys/windows"

// Starting atlas size. It grows on demand up to ATLAS_MAX and, once there,
// recycles — see atlas_relieve. A fixed 1024 was not enough: glyph area grows
// with the square of the pixel size, so a CJK document (thousands of distinct
// characters) overflows it at ordinary sizes, and each additional font style
// multiplies the working set again.
ATLAS_START :: 1024
ATLAS_MAX :: 4096
MAX_TEXT_INSTANCES :: 4096
MAX_FACES :: 8

// Which typeface a piece of text belongs to. The document's font is the user's
// choice; the chrome's is fixed, so choosing a document font cannot make the
// menus unreadable.
//
// .Body is the markdown preview's proportional face (UI spec §9.3: "Serif over
// sans, deliberately -- it is what separates 'document' from 'UI'"). It is a
// third chain rather than a mode on .Doc because the preview and the editor are
// on screen at the same time in split view, and because every cached glyph is
// keyed by its set (Glyph_Key.set), so sharing a chain would mean sharing the
// cell_cache and the atlas entries of a face with completely different metrics.
//
// STYLE IS A MEMBER, NOT A PARAMETER. §9.3 gives weight 700 to every heading
// row, so the preview needs a real Georgia Bold rather than the synthetic
// hairline-offset double-draw (at 1.85 S that is a smear, not weight 700). The
// two shapes considered were (a) a `style` parameter alongside every existing
// `set` parameter, making Text.chains two-dimensional, and (b) more members.
//
// (b), for a reason that is about call sites rather than taste: `set` appears in
// ten public signatures here (text_draw, text_draw_spans, text_cells,
// text_cell_width_at, text_bytes_for_cells, text_span_cells, text_char_width,
// text_vmetrics, text_advance, shape_run) and roughly a hundred call sites in
// src/program. A parallel `style` parameter would have to be threaded through
// every one of them, and every site that forgot would silently keep drawing
// regular text. As members, a caller asks for bold by naming .Body_Bold, the
// atlas key (Glyph_Key.set) already separates the faces, and nothing else moves.
//
// It also makes the NEXT face cheap, which was the deciding argument: Monaspace
// Neon (batch 20) is four members and four rows of FONT_SETS below, with no
// signature touched anywhere. The cost is that (role x style) is enumerated by
// hand -- which is why FONT_SETS is a single table and `fonttest` asserts its
// (base, style) pairs are unique, so a copy-pasted row cannot go unnoticed.
Font_Set :: enum u8 {
	UI,
	Doc,
	Body,
	Body_Bold,
	Body_Italic,
	Body_Bold_Italic,
}

// Which regular set a member is a style of, and which style. The SINGLE table
// describing the (role, style) grid: text_load_faces loads exactly the rows it
// names, text_styled_set reads it back to answer "give me this face in bold",
// and find_family uses `base` to decide which family list a set draws from.
//
// A member whose base is itself and whose style is .Regular has no styled
// companions, which is deliberate for .UI and .Doc: those drive the cell grid,
// whose premise is one advance for every character, and a bold face's different
// advance would slide glyphs out from under the caret.
Font_Set_Def :: struct {
	base:  Font_Set, // the .Regular member of the same family
	style: Font_Style, // which style of it this member is
}

@(private)
FONT_SETS := [Font_Set]Font_Set_Def {
	.UI               = {.UI, .Regular},
	.Doc              = {.Doc, .Regular},
	.Body             = {.Body, .Regular},
	.Body_Bold        = {.Body, .Bold},
	.Body_Italic      = {.Body, .Italic},
	.Body_Bold_Italic = {.Body, .Bold_Italic},
}

// The (base, style) of `set`. Exposed so a test can assert the table above is a
// bijection -- a duplicated row would otherwise make one member unreachable
// from text_styled_set and silently draw regular text where bold was asked for.
font_set_def :: proc(set: Font_Set) -> (base: Font_Set, style: Font_Style) {
	d := FONT_SETS[set]
	return d.base, d.style
}

// A primary face plus its per-codepoint fallbacks.
Face_Chain :: struct {
	faces:   [MAX_FACES]^IFontFace,
	units:   [MAX_FACES]f32, // designUnitsPerEm per face
	n:       int,
	char_em: f32, // primary 'x' advance as a fraction of em == one cell's width
	// Primary-face vertical metrics as fractions of em. The shaper's line box is
	// built from these (see text_vmetrics / shape_run in shape.odin) so that the
	// height a run reports and the height its glyphs occupy come from one place.
	ascent_em:   f32,
	descent_em:  f32,
	line_gap_em: f32,
	// The style whose FILE actually loaded, which is not always the style that
	// was asked for: a family with no italic file falls back to its regular one
	// (see font_style_file), and a chain that did so must not claim to be
	// italic. text_styled_set reads this rather than the request, so a caller
	// that asks for bold and gets regular finds out (text_has_style) and can
	// keep its synthetic emphasis instead of drawing regular text believing it
	// is bold.
	style:       Font_Style,
}

Font_Style :: enum u8 {
	Regular,
	Bold,
	Italic,
	Bold_Italic,
}

font_style_name :: proc(s: Font_Style) -> string {
	switch s {
	case .Regular:
		return "Regular"
	case .Bold:
		return "Bold"
	case .Italic:
		return "Italic"
	case .Bold_Italic:
		return "Bold Italic"
	}
	return "?"
}

// A selectable family, with the file for each style. Empty means the family has
// no such style and the regular file is used instead.
//
// A curated list of known code fonts, resolved by filename. It is no longer the
// ONLY source — fontscan.odin enumerates the system now — but it stays, and the
// division is worth stating because it is not "curated because enumeration is
// impossible" any more.
//
// WHAT THE CURATED TABLE IS FOR NOW: exact style files. An entry here names the
// bold, italic and bold-italic files by hand, which is what lets text_load_family
// load a real face instead of letting DirectWrite synthesise one — and synthetic
// emphasis changes the advance, which the editor's cell grid cannot take. A
// scanned family only knows what its files' name tables said, so where both
// describe a family, find_family prefers this one.
//
// THIS COMMENT USED TO ARGUE AGAINST ENUMERATION, on three grounds. Recorded
// with what happened to each, because two are answered and one was simply wrong:
//
//   - "costs over a second, on the main thread, before the first frame" —
//     answered by moving it OFF the main thread and starting it lazily, when a
//     font list is first shown. No frame waits for it. (settings.odin's
//     font_scan_kick.)
//   - "needs filtering, because monospaced by the font's own metrics includes
//     Marlett, Wingdings, AutoCAD shape fonts and CJK faces" — half right.
//     fontscan's probe excludes the symbol fonts by measurement rather than by
//     charset, and they fail it twice over (varying advances AND missing glyphs).
//     But CJK faces belong in the list: text_cell_width_at already returns width
//     2 for full-width cells, so the grid handles them, and excluding them would
//     have been the bug rather than the filter. AutoCAD's TrueType technical
//     fonts (ISOCT*, Monotxt) DO pass, and are offered — they genuinely are
//     monospaced text faces, however odd a choice.
//   - "avoids six COM interfaces and the localized-family-name problem" — the
//     COM count was the real objection and it was an undercount (eight). Avoided
//     entirely by reading the name table directly; see base/sfnt.odin. The
//     localized-name problem is answered by reading en-US ONLY, because the
//     chosen family is stored in settings.txt as a plain string.
Font_Family :: struct {
	name:                              string,
	regular, bold, italic, bolditalic: string,
	// Face index within the file, per slot above. Zero for every curated entry --
	// they all name single-font .ttf files. A SCANNED family may point into a .ttc
	// collection (simsun.ttc holds SimSun and NSimSun; msgothic.ttc holds three),
	// where the path alone does not say which font is meant. Offering such a family
	// without this loaded face 0 of the collection, which returns a face and errors
	// nothing -- you simply got a different font than the one you picked.
	idx: [4]u32,
}

FONT_FAMILIES := [?]Font_Family {
	{"Consolas", "consola.ttf", "consolab.ttf", "consolai.ttf", "consolaz.ttf", {}},
	{"Cascadia Mono", "CascadiaMono.ttf", "", "", "", {}},
	{"Cascadia Code", "CascadiaCode.ttf", "", "", "", {}},
	{"Courier New", "cour.ttf", "courbd.ttf", "couri.ttf", "courbi.ttf", {}},
	{"Lucida Console", "lucon.ttf", "", "", "", {}},
	{"Lucida Sans Typewriter", "LTYPE.TTF", "LTYPEB.TTF", "LTYPEO.TTF", "", {}},
	{"DejaVu Sans Mono", "DejaVuSansMono.ttf", "DejaVuSansMono-Bold.ttf", "DejaVuSansMono-Oblique.ttf", "", {}},
	{"JetBrains Mono", "JetBrainsMono-Regular.ttf", "JetBrainsMono-Bold.ttf", "JetBrainsMono-Italic.ttf", "", {}},
	{"Fira Code", "FiraCode-Regular.ttf", "FiraCode-Bold.ttf", "", "", {}},
	{"Source Code Pro", "SourceCodePro-Regular.ttf", "SourceCodePro-Bold.ttf", "SourceCodePro-It.ttf", "", {}},
	{"IBM Plex Mono", "IBMPlexMono-Regular.ttf", "IBMPlexMono-Bold.ttf", "IBMPlexMono-Italic.ttf", "", {}},
	{"Hack", "Hack-Regular.ttf", "Hack-Bold.ttf", "Hack-Italic.ttf", "", {}},
	{"Iosevka", "iosevka-regular.ttf", "iosevka-bold.ttf", "iosevka-italic.ttf", "", {}},
	{"Ubuntu Mono", "UbuntuMono-R.ttf", "UbuntuMono-B.ttf", "UbuntuMono-RI.ttf", "", {}},
}

// Proportional body faces for the markdown preview, in preference order.
//
// DELIBERATELY a separate table from FONT_FAMILIES rather than more rows in it:
// FONT_FAMILIES is the curated list of MONOSPACE families the font page offers
// (font_choices_refresh walks exactly that array), and a proportional serif in
// it would appear as a choice for the editor grid, where its varying advances
// would wreck column arithmetic. Same struct, same loader, different menu.
//
// Georgia first because §9.3 names it: "fall back to Georgia, which is on every
// Windows install". The rest are stock Windows serifs, then Segoe UI as a
// last-ditch proportional face -- Newtpad embeds no fonts until batch 20, so
// everything here has to already be on the machine.
BODY_FAMILIES := [?]Font_Family {
	{"Georgia", "georgia.ttf", "georgiab.ttf", "georgiai.ttf", "georgiaz.ttf", {}},
	{"Constantia", "constan.ttf", "constanb.ttf", "constani.ttf", "constanz.ttf", {}},
	{"Times New Roman", "times.ttf", "timesbd.ttf", "timesi.ttf", "timesbi.ttf", {}},
	{"Segoe UI", "segoeui.ttf", "segoeuib.ttf", "segoeuii.ttf", "segoeuiz.ttf", {}},
}

// The Windows font directory. Read from the environment rather than hardcoded:
// %SystemRoot% is not C:\Windows on every machine (imaged corporate builds,
// multi-boot), and a wrong path meant no faces loaded at all and the app failed
// to start.
//
// Package-visible, not file-private: fontscan.odin walks the same directory, and
// a second copy of "where fonts live" is the thing this comment already explains
// the cost of getting wrong.
@(private)
fonts_dir :: proc(allocator := context.temp_allocator) -> string {
	root := os.get_env("SystemRoot", context.temp_allocator)
	if root == "" {root = "C:\\Windows"}
	return strings.concatenate({root, "\\Fonts\\"}, allocator)
}

// The user's own font directory. "Install for me only" is the DEFAULT in the
// Windows font installer, and it puts nothing in %SystemRoot%\Fonts -- which is
// where most developer fonts actually land, since installing them does not
// require admin. A scan that looked only at the system directory would miss
// exactly the fonts the person who wanted enumeration went and installed.
fonts_dir_user :: proc(allocator := context.temp_allocator) -> string {
	local := os.get_env("LOCALAPPDATA", context.temp_allocator)
	if local == "" {return ""}
	return strings.concatenate({local, "\\Microsoft\\Windows\\Fonts\\"}, allocator)
}

// Resolve a Font_Family's file reference to a path.
//
// The curated table names BARE FILENAMES ("consola.ttf") and always meant
// %SystemRoot%\Fonts. Enumerated families carry ABSOLUTE paths, because a
// per-user font is not in that directory at all. Both go through here, so the
// two kinds of entry coexist rather than the table having to be rewritten.
//
// "Absolute" is decided by a drive letter or a leading separator -- crude, and
// sufficient: every path on either side of this is machine-generated.
font_file_path :: proc(file: string, allocator := context.temp_allocator) -> string {
	if len(file) >= 2 && file[1] == ':' {return strings.clone(file, allocator)}
	if len(file) >= 1 && (file[0] == '\\' || file[0] == '/') {return strings.clone(file, allocator)}
	return strings.concatenate({fonts_dir(), file}, allocator)
}

font_family_available :: proc(f: Font_Family) -> bool {
	return os.exists(font_file_path(f.regular))
}

// Fallbacks appended after the chosen family, for codepoints it lacks.
@(private)
FALLBACK_FONTS := [?]struct {
	file: string,
	kind: FONT_FACE_TYPE,
	face: u32,
}{
	{"seguisym.ttf", .TRUETYPE, 0}, // symbols
	{"msyh.ttc", .OPENTYPE_COLLECTION, 0}, // CJK (Microsoft YaHei)
	{"segoeui.ttf", .TRUETYPE, 0}, // general Latin / misc
}

Glyph_Key :: struct {
	set:   u8, // which chain the face index belongs to
	face:  u8,
	index: u16,
	px:    u16,
}

Glyph :: struct {
	uv_min, uv_max: [2]f32,
	w, h:           i32, // bitmap size, pixels
	left, top:      i32, // bearings from the pen's baseline origin (top is negative above baseline)
	advance:        f32, // pixels to advance the pen
}

Text_Instance :: struct {
	pos:    [2]f32,
	size:   [2]f32,
	color:  [4]f32,
	uv_min: [2]f32,
	uv_max: [2]f32,
}

Text :: struct {
	// The preferred .Body family (the Preview font setting, §9.3). Empty means
	// "no preference": text_load_body_face then walks BODY_FAMILIES in its
	// curated order exactly as it always has. Held here rather than passed to
	// text_load_body_face because text_load_faces is the single door every Text
	// goes through -- product and headless test alike -- and threading it as a
	// parameter would mean every caller of that door choosing a value.
	//
	// A NAME, not a path, for the same reason Settings.font_family is: paths
	// differ per machine. Not owned -- it points at the settings string, which
	// outlives any load.
	body_pref:  string,
	// DirectWrite fonts: [0] primary, [1..] fallbacks
	factory:    ^IFactory,
	// Two independent face chains. The chrome must not change typeface when the
	// user picks a font for their text: menus, tabs and the status bar are the
	// application, not the document.
	chains:     [Font_Set]Face_Chain,
	// Bumped every time ANY chain is replaced. The identity of "which faces are
	// loaded right now", for a caller that caches geometry derived from glyph
	// advances -- read it through text_face_gen, never directly.
	//
	// A counter rather than a hash of the chains, and that is the opposite choice
	// from md_theme_gen deliberately. The theme global is assigned from a dozen
	// sites, so a counter there would need every one of them to remember to bump
	// it; `chains` is assigned from exactly ONE place, four lines below, which is
	// what makes a counter here a single producer rather than a promise. The
	// alternative -- hashing char_em and the primary face POINTER -- would be
	// identity by coincidence: a freed face's address is reusable, and two
	// monospace families can share an 'x' advance ratio.
	face_gen:   u64,
	cell_cache: [Font_Set]map[rune]u8, // codepoint -> cells; depends on char_em, so per chain
	// Tab-stop spacing. NOT per font set: a tab stop is a property of the text,
	// not of the typeface it happens to be drawn in, and the chrome and the
	// document disagreeing about it would put a tab in a tab title on a
	// different grid from the same tab in the document. Read it through
	// text_tab_width, never directly -- 0 means "never initialised" and hangs.
	tab_width:  int,

	// atlas + cache
	atlas:     ^d3d.ITexture2D,
	atlas_srv: ^d3d.IShaderResourceView,
	atlas_w:   i32, // current atlas dimensions (grows; see atlas_relieve)
	atlas_h:   i32,
	pack_x:    i32,
	pack_y:    i32,
	shelf_h:   i32,
	cache:     map[Glyph_Key]Glyph,
	// A glyph was dropped for want of space even after growing and recycling —
	// i.e. one screen of text genuinely does not fit. Surfaced to the user.
	atlas_full: bool,
	// Guards against recycling more than once per frame: if a single frame's
	// glyphs cannot all fit, clearing again mid-frame would evict the glyphs
	// drawn moments ago and thrash without ever making progress.
	relieved_this_frame: bool,
	// A pack failed while drawing, so relief is owed at the next frame boundary.
	// The atlas cannot be touched mid-string (see atlas_relieve), and asking for
	// it from inside the draw is how the atlas ended up never growing at all.
	want_relief:         bool,
	// True while text_draw is accumulating instances. The atlas must not move
	// under UVs that are already queued — see atlas_relieve.
	drawing:             bool,

	// pipeline
	vs:        ^d3d.IVertexShader,
	ps:        ^d3d.IPixelShader,
	layout:    ^d3d.IInputLayout,
	blend:     ^d3d.IBlendState,
	sampler:   ^d3d.ISamplerState,
	instances: ^d3d.IBuffer,
	constants: ^d3d.IBuffer,

	// Diagnostic capture of the glyph positions text_draw_spans would emit, so a
	// headless test can assert on placement without a device. Off unless armed;
	// costs one branch in the emit loop.
	probe: Text_Probe,
}

Text_Probe :: struct {
	armed: bool,
	n:     int,
	pos:   [256][2]f32,
	// The pre-snap position for the same glyph at the same index, i.e.
	// glyph_x + g.left / y + g.top before floor(v + 0.5) is applied. Recorded
	// so a test can check pos == floor(raw + 0.5) -- the actual relationship
	// -- rather than only that pos happens to be a whole number, which both
	// floor(v+0.5) and the buggy trunc(v+0.5) satisfy for every v.
	raw:   [256][2]f32,
}

text_probe_reset :: proc(t: ^Text) {t.probe.armed = true; t.probe.n = 0}
text_probe_positions :: proc(t: ^Text) -> [][2]f32 {return t.probe.pos[:t.probe.n]}
text_probe_raw :: proc(t: ^Text) -> [][2]f32 {return t.probe.raw[:t.probe.n]}

@(private)
TEXT_HLSL := `
cbuffer Constants : register(b0) {
	float2 screen_size;
	float2 _pad;
};
Texture2D    atlas : register(t0);
SamplerState samp  : register(s0);

struct VSIn {
	float2 ipos   : IPOS;
	float2 isize  : ISIZE;
	float4 icolor : ICOLOR;
	float2 iuvmin : IUVMIN;
	float2 iuvmax : IUVMAX;
	uint   vid    : SV_VertexID;
};
struct VSOut {
	float4 pos   : SV_POSITION;
	float4 color : COLOR;
	float2 uv    : TEXCOORD;
};
VSOut vs_main(VSIn i) {
	float2 c = float2(i.vid & 1, (i.vid >> 1) & 1);
	float2 px = i.ipos + c * i.isize;
	float2 ndc = float2(px.x / screen_size.x * 2.0 - 1.0,
	                    1.0 - px.y / screen_size.y * 2.0);
	VSOut o;
	o.pos = float4(ndc, 0.0, 1.0);
	o.color = i.icolor;
	o.uv = lerp(i.iuvmin, i.iuvmax, c);
	return o;
}

// Grayscale antialiasing: a single coverage value per pixel, alpha-blended.
// This replaced ClearType's 3-channel subpixel coverage, whose colour fringes
// read as soft/blurry when a glyph is magnified (viewport zoom). Grayscale has
// no fringe and stays crisp at any size — what most editors use for scaled text.
// sRGB -> linear. The render target is sRGB-TYPED, so whatever this shader
// returns is treated as linear light and encoded on write. Colours arrive
// authored in sRGB (a theme file says #CDC3B4), so they have to be decoded here
// or every opaque fill would land a stop too bright.
//
// The round trip is the identity for an opaque pixel -- decode, then the
// hardware encodes -- so solid quads and solid glyph interiors are byte for byte
// what they were. What changes is BLENDING, which now happens in linear light,
// which is the entire point.
float3 srgb_to_linear(float3 c) {
	return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4);
}

float4 ps_main(VSOut i) : SV_Target {
	float cov = atlas.Sample(samp, i.uv).r;
	return float4(srgb_to_linear(i.color.rgb), cov * i.color.a);
}
`

// Load the DirectWrite factory + font faces and compute the cell width. No D3D,
// so this can run headless (see the `celltest` mode). text_init calls it before
// building the GPU pipeline.
text_load_faces :: proc(t: ^Text) -> (ok: bool) {
	// The one place every Text -- product and headless test alike -- passes
	// through, so it is where the tab spacing gets its default. Settings
	// overwrite it later via text_set_tab_width; text_tab_width clamps anyway,
	// so this is for the field reading truthfully, not for safety.
	t.tab_width = TAB_WIDTH_DEFAULT
	// The chrome's typeface is fixed and loaded once; the document starts on the
	// same family until settings say otherwise.
	if !text_load_family(t, "Consolas", .Regular, .UI) {return false}
	if !text_load_family(t, "Consolas", .Regular, .Doc) {return false}
	// The preview's proportional face. Not fatal if it fails: text_load_body_face
	// degrades to the mono family rather than leaving .Body faceless, and a
	// missing serif must never stop the app from starting.
	text_load_body_face(t)
	return true
}

// Load the markdown preview's proportional body face — regular AND every styled
// member FONT_SETS gives it — and report which family won. `ok` is false when no
// proportional face could be loaded and the mono fallback was used instead: the
// preview then looks like the editor, which is a cosmetic loss, not a failure to
// start.
//
// The styled chains are loaded EAGERLY, all four, rather than on first use. Lazy
// loading would mean text_load_family running mid-layout, and text_load_family
// calls text_reset_atlas, which drops every cached glyph — including ones a
// text_draw in flight has already handed UVs to. The whole family is loaded from
// files that are already in the page cache next to the regular one. Measured
// (2026-07-29, three runs of `fonttest` with the styled loads on and off):
// text_load_faces is 0.80-0.88 ms with all six chains against 0.68-0.77 ms with
// three, i.e. ~0.13 ms for twelve extra DirectWrite faces. Nothing here is worth
// a lazy path's hazards.
//
// A family that ships no italic (or no bold) is not an error: text_load_family
// falls back to the regular file and records that it did, so text_has_style says
// no and the caller keeps its synthetic emphasis.
//
// Every Text — product and headless test alike — reaches this through
// text_load_faces, so there is one body face and one place it is chosen.
text_load_body_face :: proc(t: ^Text) -> (family: string, ok: bool) {
	// The styled members of .Body, driven off FONT_SETS rather than a second
	// hand-written list: adding .Body_Small_Caps one day must not need an edit
	// here as well as there.
	styles :: proc(t: ^Text, name: string) {
		for s in Font_Set {
			d := FONT_SETS[s]
			if d.base != .Body || d.style == .Regular {continue}
			text_load_family(t, name, d.style, s)
		}
	}
	// A named preference first (the Preview font setting, §9.3). Empty means "no
	// preference", which falls through to the curated order below -- so a fresh
	// install and a settings.txt written before this existed behave identically.
	// A name that is not installed also falls through rather than failing: a
	// settings file copied from another machine is the ordinary case here, the
	// same reasoning find_family already applies.
	if t.body_pref != "" {
		if text_load_family(t, t.body_pref, .Regular, .Body) {
			styles(t, t.body_pref)
			return t.body_pref, true
		}
	}
	for f in BODY_FAMILIES {
		if text_load_family(t, f.name, .Regular, .Body) {
			styles(t, f.name)
			return f.name, true
		}
	}
	// Nothing proportional is installed (or DirectWrite refused all of them).
	// text_load_family falls back to FONT_FAMILIES[0] for an unknown name, so
	// this is the mono face the editor already uses.
	if text_load_family(t, "", .Regular, .Body) {
		styles(t, FONT_FAMILIES[0].name)
		return FONT_FAMILIES[0].name, false
	}
	return "", false
}

// The curated family named `name`, for the chain it is destined for. Unknown
// names resolve to FONT_FAMILIES[0] with found=false: a settings file copied from
// another machine can name a font that is not here, and that must fall back
// rather than fail.
//
// BODY_FAMILIES is searched ONLY for the .Body family, and that asymmetry is
// deliberate.
// .UI and .Doc drive the cell grid, whose whole premise is one advance for every
// character; letting a settings.txt that says `font_family Georgia` actually
// load Georgia there would put proportional glyphs on a monospace grid. It has
// always fallen back to Consolas and it still does. The reverse direction is
// allowed, because §9.3 asks for a "Preview font" setting offering the editor's
// face "for people who want the preview to match the source".
@(private = "file")
find_family :: proc(name: string, set: Font_Set) -> (fam: Font_Family, found: bool) {
	// FONT_SETS[set].base, not `set == .Body`: .Body_Bold and friends draw from
	// the same family list as .Body, and testing the member itself would send
	// them to FONT_FAMILIES, where "Georgia" is absent, so every styled body
	// chain would have silently loaded Consolas.
	if FONT_SETS[set].base == .Body {
		for f in BODY_FAMILIES {
			if f.name == name {return f, true}
		}
	}
	for f in FONT_FAMILIES {
		if f.name == name {return f, true}
	}
	// Then the system scan. Curated LAST-resort order is deliberate: a curated
	// entry names exact bold/italic files, and a scanned one only knows what the
	// name table said, so where both describe a family the curated one wins.
	for sf in g_scanned {
		if sf.name == name {
			return Font_Family{name = sf.name, regular = sf.regular, bold = sf.bold, italic = sf.italic, bolditalic = sf.bolditalic, idx = sf.idx}, true
		}
	}
	return FONT_FAMILIES[0], false
}

// Does this name resolve to a real family, curated or scanned?
//
// find_family returns FONT_FAMILIES[0] with found=false for an unknown name, and
// text_load_family then loads that fallback and returns TRUE -- correctly, since
// a face did load. So neither of those can tell a caller "the family you asked
// for exists". This can, and it is the only honest way to assert that a scanned
// family is reachable rather than silently becoming Consolas.
font_family_known :: proc(name: string, set := Font_Set.Doc) -> bool {
	_, found := find_family(name, set)
	return found
}

// The file `fam` ships for `style`, and the style that file ACTUALLY is.
//
// A style the family doesn't ship falls back rather than letting DirectWrite
// synthesise one: algorithmic bold/oblique changes the advance, and the editor's
// pen steps by a single cell width, so glyphs would bleed into the next column.
// Bold-italic degrades to bold before regular — a real weight with no slant is
// closer to what was asked for than neither.
//
// Pure, and exported, so `fonttest` can drive it with a Font_Family that ships
// no bold at all. That case is not otherwise reachable on a machine where every
// installed family happens to be complete, which is exactly when the "keep the
// caller's synthetic bold" path would go untested and rot.
font_style_file :: proc(fam: Font_Family, style: Font_Style) -> (file: string, got: Font_Style, index: u32) {
	file, got, index = fam.regular, .Regular, fam.idx[0]
	switch style {
	case .Bold:
		if fam.bold != "" {file, got, index = fam.bold, .Bold, fam.idx[1]}
	case .Italic:
		if fam.italic != "" {file, got, index = fam.italic, .Italic, fam.idx[2]}
	case .Bold_Italic:
		if fam.bolditalic != "" {
			file, got, index = fam.bolditalic, .Bold_Italic, fam.idx[3]
		} else if fam.bold != "" {
			file, got, index = fam.bold, .Bold, fam.idx[1]
		}
	case .Regular:
	}
	return
}

// The set that draws `set`'s family in `style` — the one thing a caller wanting
// bold body text asks. Returns the REGULAR set when no real face for that style
// is loaded, so a caller can compare the answer to what it asked for (or call
// text_has_style) and fall back to synthetic emphasis rather than quietly
// drawing regular text at weight 700's size.
//
// Requesting a style of a set that has no styled members (.UI, .Doc — the cell
// grid) always yields the set itself, which is what keeps the editor's synthetic
// bold working unchanged.
text_styled_set :: proc(t: ^Text, set: Font_Set, style: Font_Style) -> Font_Set {
	base := FONT_SETS[set].base
	if style == .Regular {return base}
	// Degradation order, most-wanted first. Regular is the caller's problem, not
	// a member to search for: it is `base`.
	want: [3]Font_Style
	n := 1
	want[0] = style
	if style == .Bold_Italic {
		want[1], want[2] = .Bold, .Italic
		n = 3
	}
	for k in 0 ..< n {
		for s in Font_Set {
			d := FONT_SETS[s]
			// d.style is the style this MEMBER is for; t.chains[s].style is the
			// style whose file actually loaded into it. Both must match, or a
			// family missing an italic file would hand back .Body_Italic holding
			// Georgia Regular.
			if d.base == base && d.style == want[k] && t.chains[s].n > 0 && t.chains[s].style == want[k] {
				return s
			}
		}
	}
	return base
}

// Whether a REAL face for `style` is loaded for `set`'s family, i.e. whether
// text_styled_set will give the caller something other than the regular face.
// The question markdown.odin has to answer before choosing between a real bold
// and its hairline double-draw.
text_has_style :: proc(t: ^Text, set: Font_Set, style: Font_Style) -> bool {
	base := FONT_SETS[set].base
	if style == .Regular {return t.chains[base].n > 0}
	return text_styled_set(t, set, style) != base
}

// The 'x' advance of a face as a fraction of em — one cell's width.
@(private = "file")
face_char_em :: proc(face: ^IFontFace, units: f32) -> f32 {
	cp := u32('x')
	gi: u16
	face->GetGlyphIndices(&cp, 1, &gi)
	gm: GLYPH_METRICS
	idx := gi
	face->GetDesignGlyphMetrics(&idx, 1, &gm, win.BOOL(false))
	return f32(gm.advanceWidth) / units
}

@(private = "file")
add_face :: proc(t: ^Text, c: ^Face_Chain, file_name: string, kind: FONT_FACE_TYPE, index: u32) -> bool {
	if c.n >= MAX_FACES {return false}
	path := font_file_path(file_name)
	// The container kind comes from the EXTENSION, not the caller. Every caller
	// passed .TRUETYPE, which is right for a .ttf and wrong for a .ttc --
	// CreateFontFace refuses a collection asked for as a single font, so a scanned
	// family living in one could not load at all.
	container := kind
	if len(path) > 4 {
		switch path[len(path) - 4:] {
			case ".ttc", ".TTC":
				container = .OPENTYPE_COLLECTION
			case ".otf", ".OTF":
				container = .CFF
		}
	}
	// NOT wide_path: a font file lives under %SystemRoot%\Fonts and is always far
	// short of MAX_PATH, and DirectWrite's CreateFontFileReference is not one of
	// the APIs \\?\ is documented to work with.
	wpath := win.utf8_to_wstring(path, context.temp_allocator)
	file: ^IFontFile
	if hr := t.factory->CreateFontFileReference(wpath, nil, &file); !win.SUCCEEDED(hr) {
		return false // not present on this machine
	}
	face: ^IFontFace
	if hr := t.factory->CreateFontFace(container, 1, &file, index, .NONE, &face); !win.SUCCEEDED(hr) {
		file->Release()
		return false
	}
	file->Release() // the face keeps its own reference
	fm: FONT_METRICS
	face->GetMetrics(&fm)
	c.faces[c.n] = face
	c.units[c.n] = f32(fm.designUnitsPerEm)
	c.n += 1
	return true
}

// Load `family` in `style` as the primary face, then the fallback chain.
// Returns false and leaves the previous faces in place if the family cannot be
// loaded, so a missing font never leaves the app with nothing to draw with.
text_load_family :: proc(t: ^Text, family: string, style: Font_Style, set := Font_Set.Doc) -> bool {
	if t.factory == nil {
		if hr := DWriteCreateFactory(.SHARED, &IID_IFactory, &t.factory); !win.SUCCEEDED(hr) {
			fmt.eprintfln("DWriteCreateFactory failed: 0x%X", u32(hr))
			return false
		}
	}

	chosen, _ := find_family(family, set)
	file, got, fidx := font_style_file(chosen, style)

	// Build into a scratch chain so a failure can't strand us faceless.
	fresh: Face_Chain
	if !add_face(t, &fresh, file, .TRUETYPE, fidx) {
		if file == chosen.regular || !add_face(t, &fresh, chosen.regular, .TRUETYPE, chosen.idx[0]) {
			for i in 0 ..< fresh.n {fresh.faces[i]->Release()}
			return false
		}
		// The styled file named by the family is not actually on this machine.
		// The chain is regular now, and must say so.
		got = .Regular
	}
	fresh.style = got
	for fdef in FALLBACK_FONTS {
		add_face(t, &fresh, fdef.file, fdef.kind, fdef.face)
	}
	fresh.char_em = face_char_em(fresh.faces[0], fresh.units[0])
	// Vertical metrics of the primary face, in em. Read here rather than at every
	// shape_run so the line box cannot be built from one face's ascent while the
	// glyphs come from another's.
	fm: FONT_METRICS
	fresh.faces[0]->GetMetrics(&fm)
	fresh.ascent_em = f32(fm.ascent) / fresh.units[0]
	fresh.descent_em = f32(fm.descent) / fresh.units[0]
	fresh.line_gap_em = f32(fm.lineGap) / fresh.units[0]

	// Release the faces we are replacing, then adopt the new ones.
	old := &t.chains[set]
	for i in 0 ..< old.n {
		if old.faces[i] != nil {old.faces[i]->Release()}
	}
	t.chains[set] = fresh
	// The ONE place a chain is replaced, so the ONE place face_gen is bumped.
	t.face_gen += 1
	// Every cached glyph and cell width belongs to the old face.
	text_reset_atlas(t)
	return true
}

// Which faces are loaded, as one number. Changes whenever any chain is replaced.
//
// For callers that cache LAID-OUT geometry rather than glyphs. text_reset_atlas
// drops the rasterized bitmaps, which is enough for anything that re-measures
// every frame -- but a cache of shaped positions, wrap points and block heights
// keeps the previous family's advances while the atlas fills with the new
// family's ink. That is a Settings > Font change in the markdown preview, where
// inline code and fenced blocks draw on the .Doc chain: see md_metrics.
text_face_gen :: proc(t: ^Text) -> u64 {return t.face_gen if t != nil else 0}

text_init :: proc(gfx: ^Gfx) -> (t: Text, ok: bool) {
	if !text_load_faces(&t) {
		return
	}

	// --- atlas texture + SRV ---
	if !atlas_create(gfx, &t, ATLAS_START) {
		return
	}

	// --- shaders + input layout ---
	vs_blob, vs_ok := compile_shader(TEXT_HLSL, "vs_main", "vs_5_0")
	if !vs_ok {
		return
	}
	defer vs_blob->Release()
	ps_blob, ps_ok := compile_shader(TEXT_HLSL, "ps_main", "ps_5_0")
	if !ps_ok {
		return
	}
	defer ps_blob->Release()

	if hr := gfx.device->CreateVertexShader(vs_blob->GetBufferPointer(), vs_blob->GetBufferSize(), nil, &t.vs); !win.SUCCEEDED(hr) {
		return
	}
	if hr := gfx.device->CreatePixelShader(ps_blob->GetBufferPointer(), ps_blob->GetBufferSize(), nil, &t.ps); !win.SUCCEEDED(hr) {
		return
	}

	layout := [?]d3d.INPUT_ELEMENT_DESC {
		{"IPOS", 0, .R32G32_FLOAT, 0, 0, .INSTANCE_DATA, 1},
		{"ISIZE", 0, .R32G32_FLOAT, 0, 8, .INSTANCE_DATA, 1},
		{"ICOLOR", 0, .R32G32B32A32_FLOAT, 0, 16, .INSTANCE_DATA, 1},
		{"IUVMIN", 0, .R32G32_FLOAT, 0, 32, .INSTANCE_DATA, 1},
		{"IUVMAX", 0, .R32G32_FLOAT, 0, 40, .INSTANCE_DATA, 1},
	}
	if hr := gfx.device->CreateInputLayout(raw_data(layout[:]), u32(len(layout)), vs_blob->GetBufferPointer(), vs_blob->GetBufferSize(), &t.layout); !win.SUCCEEDED(hr) {
		fmt.eprintfln("CreateInputLayout(text) failed: 0x%X", u32(hr))
		return
	}

	// --- straight alpha blend for grayscale glyphs: final = text*cov + dst*(1-cov) ---
	blend_desc: d3d.BLEND_DESC
	rt := &blend_desc.RenderTarget[0]
	rt.BlendEnable = win.BOOL(true)
	rt.SrcBlend = .SRC_ALPHA
	rt.DestBlend = .INV_SRC_ALPHA
	rt.BlendOp = .ADD
	rt.SrcBlendAlpha = .ONE
	rt.DestBlendAlpha = .INV_SRC_ALPHA
	rt.BlendOpAlpha = .ADD
	rt.RenderTargetWriteMask = 0x0F
	if hr := gfx.device->CreateBlendState(&blend_desc, &t.blend); !win.SUCCEEDED(hr) {
		fmt.eprintfln("CreateBlendState failed: 0x%X", u32(hr))
		return
	}

	// --- point sampler (glyphs blit 1:1; clamp) ---
	samp_desc := d3d.SAMPLER_DESC {
		Filter   = .MIN_MAG_MIP_POINT,
		AddressU = .CLAMP,
		AddressV = .CLAMP,
		AddressW = .CLAMP,
		MaxLOD   = 3.402823466e+38,
	}
	if hr := gfx.device->CreateSamplerState(&samp_desc, &t.sampler); !win.SUCCEEDED(hr) {
		fmt.eprintfln("CreateSamplerState failed: 0x%X", u32(hr))
		return
	}

	// --- instance + constant buffers ---
	inst_desc := d3d.BUFFER_DESC {
		ByteWidth      = MAX_TEXT_INSTANCES * size_of(Text_Instance),
		Usage          = .DYNAMIC,
		BindFlags      = {.VERTEX_BUFFER},
		CPUAccessFlags = {.WRITE},
	}
	if hr := gfx.device->CreateBuffer(&inst_desc, nil, &t.instances); !win.SUCCEEDED(hr) {
		fmt.eprintfln("CreateBuffer(text instances) failed: 0x%X", u32(hr))
		return
	}
	const_desc := d3d.BUFFER_DESC {
		ByteWidth      = 16,
		Usage          = .DYNAMIC,
		BindFlags      = {.CONSTANT_BUFFER},
		CPUAccessFlags = {.WRITE},
	}
	if hr := gfx.device->CreateBuffer(&const_desc, nil, &t.constants); !win.SUCCEEDED(hr) {
		fmt.eprintfln("CreateBuffer(text constants) failed: 0x%X", u32(hr))
		return
	}

	return t, true
}

// Width of one grid cell at size px (the primary monospace 'x' advance), rounded
// to a whole pixel.
//
// Rounding here rather than in the caller is load-bearing. text_draw advances its
// pen by this same value, so column n's left edge is exactly n*cell_w for both
// the glyphs and everything the program positions against the grid — caret,
// selection rects, find highlights, hit-testing. A rounded cell width computed
// program-side while text_draw kept advancing by the raw fraction would drift the
// two apart by (cell_w - raw) per column: ~0.2px/col for Consolas at 16px, which
// is 400px of divergence by VISIBLE_COLS. Both sides must call this one proc.
// Guarded by `newtpad dpitest`.
text_char_width :: proc(t: ^Text, px: f32, set := Font_Set.UI) -> f32 {
	return max(1, f32(int(t.chains[loaded_set(t, set)].char_em * px + 0.5)))
}

// Nonspacing combining marks and zero-width format characters. These need a
// codepoint check, not measured advance: monospace fonts (Consolas) give
// combining marks a FULL advance so they're visible standalone, so measuring
// can't detect them. Covers the common unambiguous blocks (decomposed accents,
// Hebrew niqqud, Arabic harakat, variation selectors, zero-width format); Indic
// spacing/nonspacing ambiguity is left to the deferred shaping work.
// Package-private, not file-private: the proportional shaper (shape.odin) has to
// make the same zero-advance decision the grid does, and a second copy of this
// table is exactly how the two would drift.
@(private)
is_zero_width :: proc(r: rune) -> bool {
	switch r {
	case 0x0000 ..= 0x001F: // C0 controls, including CR/LF: no glyph, no advance.
		// True by construction rather than a font accident -- text_cell_width's
		// glyph-metrics fallback below happened to also measure CR as ~0 on the
		// loaded font, which let wrap_row_end's CR handling go untested (see
		// task-7 Important 2). \t is intercepted earlier in text_cell_width and
		// never reaches here, so it's unaffected by being in this range.
		return true
	case 0x00AD: // soft hyphen
		return true
	case 0x0300 ..= 0x036F, 0x0483 ..= 0x0489: // combining diacritical, Cyrillic
		return true
	case 0x0591 ..= 0x05BD, 0x05BF, 0x05C1, 0x05C2, 0x05C4, 0x05C5, 0x05C7: // Hebrew
		return true
	case 0x0610 ..= 0x061A, 0x064B ..= 0x065F, 0x0670: // Arabic harakat
		return true
	case 0x06D6 ..= 0x06DC, 0x06DF ..= 0x06E4, 0x06E7, 0x06E8, 0x06EA ..= 0x06ED: // Arabic
		return true
	case 0x0711, 0x0730 ..= 0x074A, 0x07A6 ..= 0x07B0: // Syriac, Thaana
		return true
	case 0x1AB0 ..= 0x1AFF, 0x1DC0 ..= 0x1DFF, 0x20D0 ..= 0x20FF: // combining supplements
		return true
	case 0x200B ..= 0x200F, 0x202A ..= 0x202E, 0x2060 ..= 0x206F: // zero-width / bidi format
		return true
	case 0xFE00 ..= 0xFE0F, 0xFE20 ..= 0xFE2F, 0xFEFF: // variation selectors, half marks, ZWNBSP
		return true
	}
	return false
}

// Tab-stop spacing: a tab advances to the next multiple of Text.tab_width, so
// the number is the stop SPACING, not a fixed advance.
//
// The floor is 1, not 0, and that bound is load-bearing rather than cosmetic. A
// spacing of 0 makes the advance 0, and every loop that measures text here
// (text_cells, text_bytes_for_cells, text_draw_spans) and in the program layer
// (line_wrap_decision, wrap_row_end, block_row_range) advances by exactly that
// value -- so a 0 is not a wrong number on screen, it is a non-terminating loop
// on the main thread, i.e. a hang on the one property Newtpad advertises.
TAB_WIDTH_DEFAULT :: 4
TAB_WIDTH_MIN :: 1
TAB_WIDTH_MAX :: 16

// The effective tab-stop spacing, always within [TAB_WIDTH_MIN, TAB_WIDTH_MAX].
// Zero-is-initialization means a `Text` that never went through text_load_faces
// -- a bare `t: plat.Text` in a test, a future deserialized one -- reads 0 here,
// and 0 is the one value that hangs (see above), so the read is clamped rather
// than trusted. Callers that want to display the setting should read this, not
// the field.
text_tab_width :: proc(t: ^Text) -> int {
	if t.tab_width < TAB_WIDTH_MIN {return TAB_WIDTH_DEFAULT}
	return min(t.tab_width, TAB_WIDTH_MAX)
}

// Set the tab-stop spacing, clamped. Every cached cell measurement downstream of
// a tab is now wrong, so the caller must invalidate whatever a font change
// invalidates (settings_apply does).
text_set_tab_width :: proc(t: ^Text, n: int) {
	t.tab_width = clamp(n, TAB_WIDTH_MIN, TAB_WIDTH_MAX)
}

// Cells a rune occupies when it begins at cell column `col` of its row.
// `col` matters only for '\t': a tab advances to the next tab stop, so its
// width depends on where it starts. Every other rune ignores it.
//
// `col` is required rather than defaulted on purpose. A defaulted `col := 0`
// compiles at every existing call site unchanged, which is precisely how a
// substring measurement would keep a silently wrong origin; making it required
// turns the sweep into a compiler error at every site that decides a tab's
// width.
//
// Monospace cells a non-tab codepoint occupies: 0 (combining / zero-width), 1
// (normal), or 2 (wide / full-width CJK). Width 2 is decided by the glyph's real
// advance relative to one cell, so it matches whatever font renders it (no width
// tables); width 0 is decided by is_zero_width. Cached; the ratio is
// px-independent.
text_cell_width_at :: proc(t: ^Text, r: rune, col: int, set := Font_Set.UI) -> int {
	if r == '\t' {
		// This early return MUST stay above the cell_cache lookup below. The
		// cache is keyed by rune alone, which is sound for every other
		// codepoint because their width is a property of the glyph -- but a
		// tab's width is a property of WHERE IT IS. Caching it would freeze
		// whatever the first tab measured (4 at column 0, say) and hand that
		// same 4 to a tab at column 2, silently reintroducing fixed-width tabs
		// through the cache with the arithmetic below looking correct.
		//
		// No font has a glyph for U+0009 either, so a tab must never reach the
		// glyph-metrics path: it would measure as .notdef, not as whitespace.
		n := text_tab_width(t)
		return n - (col % n) // in [1, n]; never 0, so measuring loops advance
	}
	if c, found := t.cell_cache[set][r]; found {return int(c)}
	cells: u8 = 1
	if is_zero_width(r) {
		cells = 0
	} else {
		fset, face, gi := rune_face(t, r, set)
		c := &t.chains[fset]
		if gi != 0 {
			gm: GLYPH_METRICS
			idx := gi
			c.faces[face]->GetDesignGlyphMetrics(&idx, 1, &gm, win.BOOL(false))
			adv_em := f32(gm.advanceWidth) / c.units[face]
			if adv_em < 0.01 * c.char_em {
				cells = 0 // font reports zero advance
			} else if adv_em > 1.5 * c.char_em {
				cells = 2 // wide / full-width
			}
		}
	}
	t.cell_cache[set][r] = cells
	return int(cells)
}

// Total cells spanned by a UTF-8 slice (sum of per-rune cell widths), when the
// slice begins at cell column `col0` of its row.
//
// `col0` is REQUIRED, for the same reason text_cell_width_at's `col` is: this
// proc is the wrapper most of the program measures through, and a defaulted 0
// would compile every existing call site unchanged while silently measuring a
// mid-row fragment's tabs from the wrong origin. Two of those call sites are
// reachable from a keystroke (block_replace, block_delete), so the default would
// have shipped the bug this parameter exists to prevent.
//
// The RESULT stays relative -- the slice's own cell width, not the column it
// ends at -- so `col0` changes only what the tabs inside measure to, never the
// meaning of the return value.
text_cells :: proc(t: ^Text, s: []u8, col0: int, set := Font_Set.UI) -> int {
	col := col0
	for r in string(s) {col += text_cell_width_at(t, r, col, set)}
	return col - col0
}

// Bytes of `s` that fill up to `target` cells, rounded to a rune boundary. Maps a
// click's cell column back to a byte offset (inverse of text_cells). `target` is
// relative to the start of `s`; `col0` is where `s` starts on its row, and must
// be the same value the matching text_cells call was given or the two stop being
// inverses on any line containing a tab.
text_bytes_for_cells :: proc(t: ^Text, s: []u8, target: int, col0: int, set := Font_Set.UI) -> int {
	str := string(s)
	col, i := col0, 0
	for i < len(str) {
		r, w := utf8.decode_rune(str[i:])
		cw := text_cell_width_at(t, r, col, set)
		if col + cw > col0 + target {break} // target lands within this rune's cell span
		col += cw
		i += w
	}
	return i
}

// The set whose chain is actually read for `set`: itself when it has faces, its
// base otherwise.
//
// A styled member whose family ships no file for it, on a machine where even the
// regular fallback would not load, leaves an EMPTY chain — and every read below
// then dereferences a nil faces[0]. Found by sabotage: disabling the styled
// loads in text_load_body_face turned `fonttest` from a set of red assertions
// into an access violation, which proves nothing about the code under test.
// Loading normally fills all six chains, so this is the guard for the machine
// where it did not, and it must be applied at every entry that indexes chains.
@(private)
loaded_set :: proc(t: ^Text, set: Font_Set) -> Font_Set {
	if t.chains[set].n > 0 {return set}
	return FONT_SETS[set].base
}

// Pick the first loaded face that has a glyph for r; fall back to the primary
// (which renders .notdef) if none does. Per-codepoint fallback, no shaping.
//
// Returns the SET it resolved as well as the face index within it. `face`
// indexes one specific chain, and every caller goes on to index a chain with it
// (glyph_get's cache key, glyph_rasterize's faces[face]) — so handing back the
// index without the chain it belongs to is the two-producer shape: caller and
// callee would each decide, separately, which set an empty chain falls back to.
@(private)
rune_face :: proc(t: ^Text, r: rune, set_in := Font_Set.UI) -> (set: Font_Set, face: int, gi: u16) {
	set = loaded_set(t, set_in)
	c := &t.chains[set]
	if c.n == 0 {return set, 0, 0} // faceless Text: no glyph, and no fault
	cp := u32(r)
	for fi in 0 ..< c.n {
		g: u16
		c.faces[fi]->GetGlyphIndices(&cp, 1, &g)
		if g != 0 {
			return set, fi, g
		}
	}
	g: u16
	c.faces[0]->GetGlyphIndices(&cp, 1, &g)
	return set, 0, g
}

// Draw a UTF-8 string with its baseline at (x, y), left-to-right.
// `set` selects the typeface: chrome text uses the fixed UI face, the document
// uses whichever family the user chose. Defaulting to UI means only the document
// draw has to say so.
text_draw :: proc(gfx: ^Gfx, t: ^Text, str: string, x, y, px: f32, color: [4]f32, set := Font_Set.UI) {
	text_draw_spans(gfx, t, str, x, y, px, color, nil, set)
}

// A byte range within the string that draws in its own colour. Spans must be
// sorted by `start` and must not overlap; bytes outside every span use the base
// colour. This is the primitive syntax highlighting and clickable links both
// need — text_draw took one flat colour per call, so there was no way to
// recolour part of a line.
//
// Underlines are deliberately NOT drawn here. This proc knows glyphs; the
// caller owns the quad pipeline and the cell grid, and already draws selection
// and find highlights as quads. text_span_cells gives it the cell range.
Text_Span :: struct {
	start: int,
	len:   int,
	color: [4]f32,
}

// The measure-and-place walk shared by text_draw_spans (the real GPU draw,
// which passes `instances` to append to) and text_probe_capture (a headless
// test hook, which passes instances=nil and only wants the positions, via
// t.probe). Both call this SAME walk rather than each having their own copy,
// because a probe that measures something the draw does not is a test that
// cannot fail for the right reason.
//
// `gfx` may be nil: it is only touched inside glyph_get to upload a freshly
// rasterized glyph into the GPU atlas, which the probe has no device for and
// does not need -- it only reads back g.left/g.top/g.w/g.h, all computed from
// DirectWrite metrics before gfx is ever touched.
@(private = "file")
text_walk_glyphs :: proc(
	gfx: ^Gfx,
	t: ^Text,
	str: string,
	x, y, px: f32,
	base: [4]f32,
	spans: []Text_Span,
	set: Font_Set,
	instances: ^[dynamic]Text_Instance,
) {
	cell_w := text_char_width(t, px, set) // same rounded advance the program's grid uses
	pen := x
	// The cell column, tracked alongside the pen. `pen` is pixels and cannot
	// stand in for it: (pen - x) / cell_w only equals the column while every
	// rune is a whole number of fixed-width cells, which stops being true the
	// moment a tab's width depends on where it starts.
	//
	// 0 is the origin, and that is the convention rather than an accident: a
	// fragment is measured from its own start and drawn from its own start.
	// The document draw passes line_buf from the visual row start at
	// col_x(.., 0, ..); chrome callers pass whole labels; the markdown and
	// table draws pass one field/word/cell each, positioned by their own x.
	// Every measuring call site (text_cells, text_span_cells) passes the same
	// origin for the same fragment, so what is drawn and what is hit-tested
	// cannot disagree. There is deliberately no col0 parameter here: no caller
	// would pass anything but 0, and an always-0 parameter on the hottest proc
	// in the file is worse than none.
	col := 0
	si := 0 // spans are sorted, so this only ever moves forward
	for r, off in str {
		// Advance past spans this rune is already beyond, then take the colour of
		// the span containing it. One pass over both sequences, no search per rune.
		for si < len(spans) && off >= spans[si].start + spans[si].len {si += 1}
		color := base
		if si < len(spans) && off >= spans[si].start {
			color = spans[si].color
		}
		// `set`, not the default .UI: the pen advances by cells * cell_w, and cell_w
		// above is already this set's rounded advance. Classifying against the UI
		// chain instead made every wide/zero-width decision -- and the cell_cache
		// key -- belong to a different font than the one being drawn, so with any
		// document font other than Consolas the caret and selection drifted from
		// the glyphs, accumulating along the line.
		cells := text_cell_width_at(t, r, col, set)
		if r == '\t' {
			pen += f32(cells) * cell_w // whitespace: advance, draw nothing
			col += cells
			continue
		}
		fset, face, gi := rune_face(t, r, set)
		g := glyph_get(gfx, t, fset, face, gi, px)
		if g.w > 0 && g.h > 0 {
			// Combining marks (0 cells) sit over the previous cell, not after it.
			glyph_x := pen - cell_w if cells == 0 else pen
			// Snap to whole pixels. An integer-sized glyph quad at a fractional
			// position is resampled across texel boundaries, which puts a vertical
			// seam through every glyph -- Wyatt, live use: "all characters/glyphs
			// in the tabs and menus are split vertically".
			//
			// Fixed HERE and not in the callers, of which there are dozens.
			// Must be floor(v + 0.5), not trunc(v + 0.5): trunc rounds toward
			// zero, so for a negative integral v it lands on v + 1, a 1px
			// shift. Document text does land on integers today (text_char_width
			// rounds the advance so column n's left edge is exactly n*cell_w),
			// but under horizontal scroll col_x subtracts h_scroll*char_w and
			// goes deeply negative (src/program/doc.odin, col_x with rhs), so
			// trunc was not actually a no-op there -- it was only invisible
			// because the h_scroll>0 cover strip repaints [0, TEXT_MARGIN_X)
			// over it. round(v + 0.5) is not a fix either: it is the same
			// half-away-from-zero asymmetry under a different name. floor is
			// the one call that is a true round for every v, negative or not.
			raw := [2]f32{glyph_x + f32(g.left), y + f32(g.top)}
			pos := [2]f32{math.floor(raw.x + 0.5), math.floor(raw.y + 0.5)}
			if t.probe.armed && t.probe.n < len(t.probe.pos) {
				t.probe.pos[t.probe.n] = pos
				t.probe.raw[t.probe.n] = raw
				t.probe.n += 1
			}
			if instances != nil {
				append(instances, Text_Instance {
					pos    = pos,
					size   = {f32(g.w), f32(g.h)},
					color  = color,
					uv_min = g.uv_min,
					uv_max = g.uv_max,
				})
			}
		}
		pen += f32(cells) * cell_w // grid advance, not the glyph's natural advance
		col += cells
	}
}

// Runs text_walk_glyphs with `s` drawn at (x, y) in `set`, recording each
// glyph's placed position into t.probe (see text_probe_reset) without
// touching the device. Lets a headless test assert on where text_draw_spans
// would actually put pixels.
text_probe_capture :: proc(t: ^Text, s: string, x, y, px: f32, set: Font_Set = .UI) {
	text_walk_glyphs(nil, t, s, x, y, px, {1, 1, 1, 1}, nil, set, nil)
}

text_draw_spans :: proc(
	gfx: ^Gfx,
	t: ^Text,
	str: string,
	x, y, px: f32,
	base: [4]f32,
	spans: []Text_Span,
	set := Font_Set.UI,
) {
	g_draw.text_calls += 1 // see draw_trace.odin
	instances := make([dynamic]Text_Instance, 0, len(str))
	defer delete(instances)
	// The atlas must hold still while these UVs are being collected.
	t.drawing = true
	defer t.drawing = false

	text_walk_glyphs(gfx, t, str, x, y, px, base, spans, set, &instances)
	text_submit_instances(gfx, t, instances[:])
}

// Upload a batch of placed glyph quads and issue the instanced draw.
//
// Split out of text_draw_spans so the SHAPER's draw (shaped_draw, shape.odin)
// reaches the GPU through the same path rather than a second copy of this
// plumbing. The grid walk and the proportional walk place glyphs differently —
// that is the whole point of the shaper — but there is exactly one place that
// maps, binds and draws them, so a pipeline-state change cannot land in one and
// miss the other.
//
// The caller owns `instances` and is responsible for the t.drawing guard around
// the walk that produced them: the UVs inside are only valid while the atlas
// holds still.
@(private)
text_submit_instances :: proc(gfx: ^Gfx, t: ^Text, instances: []Text_Instance) {
	if len(instances) == 0 {
		return
	}

	n := min(len(instances), MAX_TEXT_INSTANCES)
	g_draw.text_clamped += len(instances) - n // see draw_trace.odin
	draw_note_text(instances[:n])
	ctx := gfx.ctx

	mapped: d3d.MAPPED_SUBRESOURCE
	if win.SUCCEEDED(ctx->Map((^d3d.IResource)(t.instances), 0, .WRITE_DISCARD, {}, &mapped)) {
		mem.copy(mapped.pData, raw_data(instances), n * size_of(Text_Instance))
		ctx->Unmap((^d3d.IResource)(t.instances), 0)
	}
	if win.SUCCEEDED(ctx->Map((^d3d.IResource)(t.constants), 0, .WRITE_DISCARD, {}, &mapped)) {
		screen := [2]f32{f32(gfx.width), f32(gfx.height)}
		mem.copy(mapped.pData, &screen, size_of(screen))
		ctx->Unmap((^d3d.IResource)(t.constants), 0)
	}

	stride := u32(size_of(Text_Instance))
	offset := u32(0)
	blend_factor := [4]f32{1, 1, 1, 1}
	ctx->OMSetBlendState(t.blend, &blend_factor, 0xFFFFFFFF)
	ctx->IASetInputLayout(t.layout)
	ctx->IASetPrimitiveTopology(.TRIANGLESTRIP)
	ctx->IASetVertexBuffers(0, 1, &t.instances, &stride, &offset)
	ctx->VSSetShader(t.vs, nil, 0)
	ctx->VSSetConstantBuffers(0, 1, &t.constants)
	ctx->PSSetShader(t.ps, nil, 0)
	ctx->PSSetShaderResources(0, 1, &t.atlas_srv)
	ctx->PSSetSamplers(0, 1, &t.sampler)
	ctx->DrawInstanced(4, u32(n), 0, 0)
}

@(private)
glyph_get :: proc(gfx: ^Gfx, t: ^Text, set: Font_Set, face: int, index: u16, px: f32) -> Glyph {
	key := Glyph_Key{u8(set), u8(face), index, u16(px)}
	if g, found := t.cache[key]; found {
		return g
	}

	g: Glyph
	// advance from design metrics
	gm: GLYPH_METRICS
	idx := index
	c := &t.chains[set]
	c.faces[face]->GetDesignGlyphMetrics(&idx, 1, &gm, win.BOOL(false))
	g.advance = f32(gm.advanceWidth) * px / c.units[face]

	cov, gw, gh, left, top := glyph_rasterize(t, set, face, index, px)
	g.w = gw
	g.h = gh
	g.left = left
	g.top = top
	// gfx is nil when called from text_probe_capture (no device, e.g.
	// glyphsnaptest): there is no atlas to pack into, since atlas_w/atlas_h are
	// only ever set by atlas_create, which text_init (not text_load_faces) runs.
	// Packing anyway would read atlas_w/atlas_h as 0, atlas_pack would report
	// every glyph too big to fit, and g.w/g.h would get zeroed below as if the
	// atlas were full -- silently breaking position math for a probe that never
	// asked for pixels, only placement. g.w/h/left/top above are already the
	// real DirectWrite metrics, which is everything position math needs, so
	// return before the atlas is ever touched. Not cached: this Glyph has no
	// valid uv, and a later real draw of the same key must still pack for real.
	if gfx == nil {
		if cov != nil {delete(cov)}
		return g
	}
	if cov != nil && gw > 0 && gh > 0 {
		rx, ry, packed := atlas_pack(t, gw, gh)
		if !packed {
			// Out of room. Do not relieve the atlas here. When this was written,
			// this branch really was reached only from inside text_draw, which
			// holds queued UVs normalised against the current atlas, and
			// atlas_relieve refuses while `drawing` for exactly that reason. That
			// premise no longer holds: shape_run (src/platform/shape.odin) can
			// call glyph_get with a real gfx directly, via text_advance, from
			// OUTSIDE any text_draw call -- so `t.drawing` can be false here too.
			// It is still correct not to relieve from inside glyph_get: this proc
			// has no way to know whether some other in-flight UV collection
			// elsewhere is relying on the atlas staying put, so it always defers
			// to the one place that does know, text_frame_begin, at the boundary
			// where the queue is empty, regardless of who the caller was. No
			// layout correctness breaks in the meantime: the Glyph returned here
			// still carries the real metrics computed above (advance, left, top,
			// w, h); only the atlas fields are left at zero, and the miss is not
			// cached (see below), so a shape_run that hits a full atlas still
			// lays out correctly -- the glyph just has no pixels until relief
			// runs.
			//
			// Asking anyway is what broke it -- this line was atlas_relieve's
			// only caller, so its guard was always true, so the atlas never grew
			// past ATLAS_START and never recycled. ATLAS_MAX was dead code and
			// atlas_full latched for the life of the process, which is glyphs
			// silently missing from the user's file.
			//
			// Record that relief is owed, skip this glyph for this frame, and let
			// text_frame_begin do it at the boundary where the queue is empty. The
			// glyph then appears next frame instead of never.
			t.want_relief = true
		}
		if packed {
			// Average the three ClearType subpixels into one grayscale coverage and
			// replicate across RGBA; the pixel shader samples .r and alpha-blends.
			// Averaging is what removes the colour fringe that reads as blur at zoom.
			rgba := make([]u8, int(gw * gh) * 4)
			defer delete(rgba)
			for i in 0 ..< int(gw * gh) {
				c := u8((u32(cov[i * 3 + 0]) + u32(cov[i * 3 + 1]) + u32(cov[i * 3 + 2])) / 3)
				rgba[i * 4 + 0] = c
				rgba[i * 4 + 1] = c
				rgba[i * 4 + 2] = c
				rgba[i * 4 + 3] = c
			}
			box := d3d.BOX {
				left   = u32(rx),
				top    = u32(ry),
				front  = 0,
				right  = u32(rx + gw),
				bottom = u32(ry + gh),
				back   = 1,
			}
			gfx.ctx->UpdateSubresource((^d3d.IResource)(t.atlas), 0, &box, raw_data(rgba), u32(gw * 4), 0)
			g.uv_min = {f32(rx) / f32(t.atlas_w), f32(ry) / f32(t.atlas_h)}
			g.uv_max = {f32(rx + gw) / f32(t.atlas_w), f32(ry + gh) / f32(t.atlas_h)}
		} else {
			// Atlas full. Nothing to draw for this glyph, but do NOT cache that:
			// a cached miss makes the glyph invisible for the rest of the process
			// even after text_reset_atlas frees space. Flag it so the program can
			// say so — the pen still advances, so the silent failure looks like
			// holes punched in the user's file, with no way to tell why.
			t.atlas_full = true
			g.w, g.h = 0, 0
			if cov != nil {
				delete(cov)
			}
			return g
		}
	}
	if cov != nil {
		delete(cov)
	}
	t.cache[key] = g
	return g
}

// Cell offset and cell width of a byte range within `str`, when `str` itself
// begins at cell column `col0` of its row. Decorations that sit under text — a
// link underline, later a squiggle — must be placed on the same grid the glyphs
// advance along, or they drift on CJK and tabs.
//
// `col0` is required (see text_cells). Both returns stay RELATIVE to `str`: the
// caller draws the decoration from `str`'s own x, so an absolute column would be
// the wrong space to hand back.
text_span_cells :: proc(t: ^Text, str: string, start, length: int, col0: int, set := Font_Set.UI) -> (col, cells: int) {
	for r, off in str {
		// `col0 + col + cells`, not any one alone: this walk splits one running
		// column across two accumulators -- `col` holds the cells before
		// `start`, and `cells` holds the cells since -- on top of the origin
		// `col0` the whole fragment sits at. Neither accumulator is the rune's
		// column on its own; only the sum is, before `start` (when cells == 0)
		// and after it (when col has stopped moving) alike.
		w := text_cell_width_at(t, r, col0 + col + cells, set)
		if off < start {
			col += w
			continue
		}
		if off >= start + length {
			break
		}
		cells += w
	}
	return
}

// True once a glyph has been dropped for want of atlas space.
text_atlas_full :: proc(t: ^Text) -> bool {return t.atlas_full}

// (Re)create the atlas texture at `dim` and reset the packer. Any existing
// texture is released; the glyph cache holds UVs into it and must be cleared by
// the caller.
@(private = "file")
atlas_create :: proc(gfx: ^Gfx, t: ^Text, dim: i32) -> bool {
	tex_desc := d3d.TEXTURE2D_DESC {
		Width      = u32(dim),
		Height     = u32(dim),
		MipLevels  = 1,
		ArraySize  = 1,
		Format     = .R8G8B8A8_UNORM,
		SampleDesc = {Count = 1},
		Usage      = .DEFAULT,
		BindFlags  = {.SHADER_RESOURCE},
	}
	tex: ^d3d.ITexture2D
	if hr := gfx.device->CreateTexture2D(&tex_desc, nil, &tex); !win.SUCCEEDED(hr) {
		fmt.eprintfln("CreateTexture2D(atlas %d) failed: 0x%X", dim, u32(hr))
		return false
	}
	srv: ^d3d.IShaderResourceView
	if hr := gfx.device->CreateShaderResourceView((^d3d.IResource)(tex), nil, &srv); !win.SUCCEEDED(hr) {
		fmt.eprintfln("CreateShaderResourceView(atlas) failed: 0x%X", u32(hr))
		tex->Release()
		return false
	}
	if t.atlas_srv != nil {t.atlas_srv->Release()}
	if t.atlas != nil {t.atlas->Release()}
	t.atlas, t.atlas_srv = tex, srv
	t.atlas_w, t.atlas_h = dim, dim
	t.pack_x, t.pack_y, t.shelf_h = 0, 0, 0
	return true
}

// The atlas is out of room. Grow it if there is headroom, otherwise recycle it.
//
// The packer is a shelf allocator, which cannot free an individual rectangle —
// so "eviction" here is wholesale. That is affordable because the viewport-first
// rule bounds what has to come back to roughly one screen of glyphs, which
// re-rasterizes in milliseconds. Growing first means the common case (a big
// document, a large font) stops recurring rather than thrashing.
//
// Returns false only when even a fresh, maximum-size atlas cannot help, which
// means one screen of text genuinely does not fit.
@(private = "file")
atlas_relieve :: proc(gfx: ^Gfx, t: ^Text) -> bool {
	// Never mid-string. Instances already queued by this text_draw hold UVs
	// normalised against the current atlas size and pointing at rects that a
	// grow would discard or a recycle would overwrite — they would all be drawn
	// against the new texture. Callers defer to text_frame_begin instead; this
	// stays as a guard, but it must no longer be the only thing anyone hits.
	if t.drawing {
		return false
	}
	if t.atlas_w < ATLAS_MAX {
		if atlas_create(gfx, t, min(t.atlas_w * 2, ATLAS_MAX)) {
			clear(&t.cache)
			return true
		}
		return false
	}
	// Already at the cap. Recycle, but only once per frame — clearing twice in
	// one frame would evict glyphs this same frame just drew.
	if t.relieved_this_frame {
		return false
	}
	t.relieved_this_frame = true
	clear(&t.cache)
	t.pack_x, t.pack_y, t.shelf_h = 0, 0, 0
	return true
}

// Called once per frame, from outside any text_draw — which makes it the only
// place the atlas may be grown or recycled, since no instance queue is live
// here. Relief owed by a pack failure during the previous frame happens now.
text_frame_begin :: proc(gfx: ^Gfx, t: ^Text) {
	t.relieved_this_frame = false
	if !t.want_relief {return}
	t.want_relief = false
	// Clear the flag on success so the status bar stops reporting a condition
	// that has been resolved. If even a fresh maximum-size atlas cannot help, it
	// stays set and the warning is accurate.
	if atlas_relieve(gfx, t) {t.atlas_full = false}
}

text_atlas_dim :: proc(t: ^Text) -> i32 {return t.atlas_w}

// The primary face's cell width as a fraction of em. Exposed so a test can check
// that a family's styles agree — the cell grid assumes one advance for all text.
text_char_em :: proc(t: ^Text, set := Font_Set.Doc) -> f32 {return t.chains[loaded_set(t, set)].char_em}

// The primary face's vertical metrics at `px`, in pixels. `ascent` is above the
// baseline and `descent` below, both positive; `line_gap` is the face's own
// recommended extra leading.
//
// The shaper is the only consumer today and it is the single producer of a run's
// height, so these must not be recomputed anywhere else — a block that positions
// itself from one ascent while the glyphs are placed from another is the
// two-producer shape this project has recorded sixteen instances of.
text_vmetrics :: proc(t: ^Text, px: f32, set := Font_Set.Body) -> (ascent, descent, line_gap: f32) {
	c := &t.chains[loaded_set(t, set)]
	return c.ascent_em * px, c.descent_em * px, c.line_gap_em * px
}

// How many `gw`x`gh` boxes the shelf packer fits in a `dim` square. Pure
// arithmetic mirroring atlas_pack, so capacity can be checked without a GPU.
text_atlas_fit_count :: proc(dim, gw, gh: i32) -> int {
	if gw > dim || gh > dim {return 0}
	PAD :: 1
	x, y, shelf, n := i32(0), i32(0), i32(0), 0
	for {
		if x + gw + PAD > dim {
			x = 0
			y += shelf + PAD
			shelf = 0
		}
		if y + gh > dim {return n}
		x += gw + PAD
		if gh > shelf {shelf = gh}
		n += 1
	}
}

// Empty the atlas. Every cached glyph holds UVs into it, so the cache goes too.
// Used when the rasterization size changes wholesale (a DPI change): keeping
// entries rasterized for the old size would both mis-render and permanently
// consume the space the new size needs.
text_reset_atlas :: proc(t: ^Text) {
	clear(&t.cache)
	// Cell widths depend on char_em and on which face serves a rune, so a font
	// change invalidates them too — a stale entry desyncs the column grid from
	// what text_draw actually advances.
	for set in Font_Set {clear(&t.cell_cache[set])}
	t.pack_x, t.pack_y, t.shelf_h = 0, 0, 0
	t.atlas_full = false
}

// Returns 3-channel coverage (one RGB triple per pixel; caller frees) and
// placement, baseline origin at (0,0) so left/top are pen-relative bearings.
// The texture stays CLEARTYPE_3x1 because the antialiased (NATURAL_SYMMETRIC)
// rendering mode only fills that type — asking for ALIASED_1x1 under it returns
// an empty glyph. glyph_get averages the three subpixels into one grayscale
// value, which is what kills ClearType's colour fringe (the source of the
// zoomed-in "blur") while keeping the crisp antialiased edge. NATURAL_SYMMETRIC
// antialiases in both axes, steadier than NATURAL as the viewport zooms.
@(private)
glyph_rasterize :: proc(t: ^Text, set: Font_Set, face: int, index: u16, px: f32) -> (cov: []u8, gw, gh, left, top: i32) {
	idx := index
	run := GLYPH_RUN {
		fontFace     = t.chains[set].faces[face],
		fontEmSize   = px,
		glyphCount   = 1,
		glyphIndices = &idx,
		isSideways   = win.BOOL(false),
	}
	analysis: ^IGlyphRunAnalysis
	if hr := t.factory->CreateGlyphRunAnalysis(&run, 1.0, nil, .NATURAL_SYMMETRIC, .NATURAL, 0, 0, &analysis); !win.SUCCEEDED(hr) {
		return
	}
	defer analysis->Release()

	b: win.RECT
	if hr := analysis->GetAlphaTextureBounds(.CLEARTYPE_3x1, &b); !win.SUCCEEDED(hr) {
		return
	}
	gw = b.right - b.left
	gh = b.bottom - b.top
	left = b.left
	top = b.top
	if gw <= 0 || gh <= 0 {
		return nil, 0, 0, left, top // whitespace: advance only
	}

	cov = make([]u8, int(gw * gh) * 3)
	if hr := analysis->CreateAlphaTexture(.CLEARTYPE_3x1, &b, raw_data(cov), u32(len(cov))); !win.SUCCEEDED(hr) {
		delete(cov)
		return nil, 0, 0, left, top
	}
	return
}

// Test helper (no D3D device): compile the text shaders, so a headless run
// catches an HLSL error that would otherwise only surface as a failed text_init
// (a black window that never draws) at startup.
text_shaders_compile_ok :: proc() -> bool {
	vs, vok := compile_shader(TEXT_HLSL, "vs_main", "vs_5_0")
	if vs != nil {vs->Release()}
	ps, pok := compile_shader(TEXT_HLSL, "ps_main", "ps_5_0")
	if ps != nil {ps->Release()}
	return vok && pok
}

// Test probe (no D3D device needed): rasterize `r` at `px` and report the
// coverage size, whether any pixel is inked, and a checksum of the coverage
// itself. Verifies the glyph path produces real coverage — the pixels
// themselves still need a live eye.
//
// `sum` exists because the box alone is not a fingerprint of the FACE: Georgia
// Italic's 'W' at 24px rasterizes to the same 26x17 box as Georgia Regular's,
// so a test asserting "a different style has a different box" failed against a
// correctly-loaded italic. The position-weighted sum below differs whenever any
// pixel of coverage differs, which two different font files essentially always
// do — and unlike a plain byte sum it also separates two bitmaps that merely
// permute their coverage.
text_glyph_coverage_probe :: proc(t: ^Text, r: rune, px: f32, set := Font_Set.Doc) -> (w, h: int, inked: bool, sum: u64) {
	fset, face, gi := rune_face(t, r, set)
	cov, gw, gh, _, _ := glyph_rasterize(t, fset, face, gi, px)
	defer if cov != nil {delete(cov)}
	for b, i in cov {
		if b > 0 {inked = true}
		sum += u64(b) * u64(i + 1)
	}
	return int(gw), int(gh), inked, sum
}

// Shelf packer. Returns ok=false when the atlas is full; the caller then skips
// the glyph (rather than writing out of bounds) and asks for relief at the next
// frame boundary, which grows or recycles. A shelf allocator cannot free an
// individual rectangle, so relief is necessarily wholesale — affordable because
// the viewport-first rule bounds what has to come back to about one screen of
// glyphs. Per-glyph eviction would mean replacing the packer, and the measured
// capacity (see this file's header) says nothing is asking for that.
@(private)
atlas_pack :: proc(t: ^Text, w, h: i32) -> (x, y: i32, ok: bool) {
	PAD :: 1
	if w > t.atlas_w || h > t.atlas_h {
		return 0, 0, false // single glyph larger than the whole atlas
	}
	if t.pack_x + w + PAD > t.atlas_w {
		t.pack_x = 0
		t.pack_y += t.shelf_h + PAD
		t.shelf_h = 0
	}
	if t.pack_y + h > t.atlas_h {
		return 0, 0, false // atlas full
	}
	x = t.pack_x
	y = t.pack_y
	t.pack_x += w + PAD
	if h > t.shelf_h {
		t.shelf_h = h
	}
	return x, y, true
}
