# Newtpad UI specification v1

Companion to `Newtpad Spec.dc.html` (visual reference, same content plus rendered
examples). This file is the handoff copy.

---

## 0. How to use this document

**This is a target state, not an audit of the codebase.** It was written from
screenshots, `Light Custom.theme`, and the colour-rules file — nothing else. It does
not know what is already implemented.

- Every item is a **value to verify against the code**, changed only where the code
  disagrees.
- Read **NEW** as *"if not already present."* The badge marks something not visible in
  the screenshots. If it exists, the badge is wrong; the surrounding spec still applies.
- Where the text says *"in the screenshots"*, that is the entire evidence. Confirm
  before treating it as a defect.
- **Do not refactor working code to match the structure implied here.** Struct names,
  file layout and function boundaries in §9/§14/§19 are illustrative — including the
  `Rect_Instance` struct and the HLSL in §19, which is the section most likely to be
  copied verbatim. The numbers, colours, role names and behaviours are the deliverable;
  the code shape is not.
- Effort estimates in §20 assume building from nothing. Subtract what exists. The
  *ordering* still holds — it is dependency-driven: theme → metrics struct → DPI → rest.
- **If the code and this document conflict on a fact, the code wins.** If they conflict
  on a value — a size, colour, or ratio — this document is the intended value, and the
  reason is stated next to it.

**Shell:** direction 2a — 40px tab rail with pill tabs, visible 30px menu bar that can
be hidden, 26px status bar.

**Decisions locked from the client's answers:**

| | |
|---|---|
| It will be sold | Conventions beat cleverness; nothing invented where a standard exists |
| Menu bar ships visible | Client lives in menus; buyers may live in the palette. Both first-class |
| App owns the title bar | §4.1 lists what that obliges |
| 1440p + 1080p, unknown future | DPI rounding is a hard rule — §3 |
| Markdown is the priority | Redesigned inside the fixed cell grid — §9 |
| Filter must stay smooth to 10 GB | Streaming pass, no modal — §14 |
| Themes may use any colour | Warn once, never clamp — §17 |
| Icon needed | Three directions in §16 |
| Motion budget | 50ms |
| Accessibility target | WCAG AA for all body text; respect reduced motion |

---

## 1. Theme files

Nine roles are added to the existing format. Everything in this document resolves
through a role name — no hard-coded colour anywhere — so a themer can restyle the whole
app and colour rules keep working across themes.

### 1.0 New roles

| Role | Purpose |
|---|---|
| `bg_hover` | Hover fill for any tab, menu item, settings row, palette row. If currently implicit, it needs a key: a themer cannot change what has no name. |
| `accent_wash` | Fill behind a selected settings row / the filter band. Deriving it from `accent` by alpha breaks on a light custom theme. |
| `focus_ring` | Defaults to `accent`; separable because a themer may want accent quiet and focus loud. |
| `scrollbar_thumb` | If the thumb colour is not already a role, make it one. Sits on `bg_base`, needs 3:1. |
| `table_zebra` | Alternating row fill in table view, replacing column rules (§10). |
| `md_bold` | The role list has `md_italic` but no bold. If that is still true, bold has nowhere to go. |
| `md_code_bg` | Code spans and fenced blocks need a fill, not just a foreground (§9). |
| `md_rule` | Thematic breaks, table borders, h1/h2 underline in preview. |
| `md_list_mark` | Bullets and ordinals. Quieter than `md_heading`, louder than body. |

### 1.1 Dark.theme (paste-ready)

```
# Newtpad theme -- Dark
# Ratios in comments are against bg_base unless marked. All clear WCAG AA
# for body text except text_dim, which is disabled-only (see §18).

base dark

# --- neutrals ---
bg_base         #221F1C   # document surface, menu bar, settings page
bg_panel        #1C1917   # tab rail, status bar -- the frame
bg_raised       #2B2724   # active tab, menus, palette, table header
bg_hover        #302B27   # NEW  any hoverable row or pill
border_subtle   #322D28   # the only separator in the app, 1px
border_strong   #4A4339   # table header rule, input underline
text_muted      #9D9284   # 4.9  accelerators, help lines, hints
text_dim        #6F665C   # 2.6  DISABLED ONLY -- never live text
text_secondary  #B3A897   # 6.6  inactive tabs, status bar, chrome
text_primary    #CDC3B4   # 9.2  document body -- the default
text_bright     #F2EBE0   # 13.4 active tab label, titles

# --- accents ---
selection_doc   #33424A   # text_primary on it: 8.9 -- test this, not bg_base
selection_list  #3A352F   # keyboard cursor in settings/palette/table
caret           #D99B62   # 7.3, drawn 2px wide
accent          #D99B62   # 7.3  one accent, state only, never decoration
accent_wash     #302823   # NEW  selected settings row, filter band
focus_ring      #D99B62   # NEW  2px, 1px offset, every focusable thing
scrollbar_thumb #3E3833   # NEW  3.0 against bg_base
table_zebra     #262320   # NEW  every other table row
find_match_bg   #4A3826   # non-current hits; current hit uses accent fill
match_mark      #D99B62   # scrollbar tick marks
link            #97C3D8   # 8.2, plus a 1px 35%-alpha underline
warning         #E0A458   # 7.6
danger          #C0453B   # white on it: 4.7 -- close hover, unsaved-close
success         #9DC9A0   # 8.6
filter_bg       #2E2823   # filter mode band -- a mode must be obvious
filter_text     #E5B57F   # 8.4 on filter_bg
bookmark        #97C3D8

# --- markdown ---
md_heading      #E5B57F   # 8.4  all levels; size carries the level, not hue
md_bold         #EFE7DB   # NEW  12.7 -- weight does the work, colour assists
md_italic       #C4B79F   # 8.0  slanted face, very slightly cooler
md_code         #97C3D8   # 8.2  same hue as link: both point elsewhere
md_code_bg      #2A2723   # NEW  code span and fence fill
md_quote        #A69B8B   # 5.6  quieter than body, plus a 2px accent bar
md_rule         #3A342E   # NEW  --- breaks, table borders, h1/h2 underline
md_list_mark    #D99B62   # NEW  bullets and ordinals only

# --- syntax: five hues, one job each ---
syn_keyword     #D3A9CD   # 7.4  mauve -- language words
syn_string      #9DC9A0   # 8.6  green -- literal content
syn_number      #E5B57F   # 8.4  amber -- numbers, true/false/null
syn_comment     #9D9284   # 4.9  grey -- AA, so comments stay readable
syn_type        #97C3D8   # 8.2  blue -- types, tags, references
syn_punct       #A69B8B   # 5.6  braces, pipes, commas
syn_json_key    #EFE7DB   # 12.7 keys are the index you scan: brightest
syn_xml_tag     #D3A9CD   # tags are keywords
syn_xml_attr    #E5B57F
```

### 1.2 Light.theme (paste-ready)

Not a second design — the same file with different values. Two deliberate departures
from the current light theme: the page is `#FAF8F3` rather than pure white so it does
not glare beside a dark desktop, and the neutrals are warm rather than blue-grey, which
is most of what makes the current light theme feel like a dev tool.

```
# Newtpad theme -- Light

base light

# --- neutrals ---
bg_base         #FAF8F3   # warm paper, not white
bg_panel        #EEEAE2
bg_raised       #FFFFFF   # raised is lighter than base in light themes
bg_hover        #E8E3D9
border_subtle   #DED8CC
border_strong   #B9B0A2
text_muted      #6B6156   # 5.4
text_dim        #9A9186   # 2.6  disabled only
text_secondary  #5F574D   # 7.1
text_primary    #3D372F   # 10.4
text_bright     #2C2620   # 13.9

# --- accents ---
selection_doc   #CFDBE2   # text_primary on it: 9.6
selection_list  #DCD6CA
caret           #A05A1E   # 4.8
accent          #A05A1E   # 4.8
accent_wash     #F2E6D8
focus_ring      #A05A1E
scrollbar_thumb #C9C2B5   # 3.0 against bg_base
table_zebra     #F4F1EA
find_match_bg   #F0DFBE
match_mark      #A05A1E
link            #1F5F78   # 6.4
warning         #9A5A12   # 5.1
danger          #B23A30   # white on it: 5.4
success         #2F6B47   # 5.9
filter_bg       #F3E8D9
filter_text     #7A4A12   # 6.2 on filter_bg
bookmark        #1F5F78

# --- markdown ---
md_heading      #8A5416   # 6.1
md_bold         #2C2620   # 13.9
md_italic       #5C5240   # 7.4
md_code         #1F5F78   # 6.4
md_code_bg      #F0EDE4
md_quote        #6B6156   # 5.4
md_rule         #DED8CC
md_list_mark    #A05A1E

# --- syntax ---
syn_keyword     #7A3F77   # 6.8
syn_string      #2F6B47   # 5.9
syn_number      #8A5416   # 6.1
syn_comment     #6B6156   # 5.4
syn_type        #1F5F78   # 6.4
syn_punct       #5F574D   # 7.1
syn_json_key    #2C2620   # 13.9
syn_xml_tag     #7A3F77
syn_xml_attr    #8A5416
```

### 1.3 Rules the palette obeys

- **One accent, state only.** If a colour is not saying *selected / dirty / focused /
  found / dangerous*, it is a neutral. This single rule is what separates the design
  from the accent-on-everything look.
- **Warm neutrals, chroma under 0.02.** Every grey carries a trace of the accent's hue.
  Cold greys read as tooling; warm greys read as paper. This is most of the "cosy".
- **Five syntax hues, no more.** A sixth always looks arbitrary. Distinguish further
  token types by lightness within a hue — that is why `syn_json_key` is bright neutral
  rather than a new colour.
- **Type does hierarchy, colour does state.** Heading level is size and weight, never
  hue; that is why all six markdown heading levels share `md_heading`.
- **Measure text on what it sits on.** Selection, find matches and the filter band all
  change the background under text; each pair is listed with its own ratio.
- **Store alphas, not resolved hex.** Where a value is "12% accent", keep it as an alpha
  over the surface so it stays correct when a user replaces `accent`. The files above
  resolve them only for readability.

---

## 2. Metrics & type

Logical pixels at 100%. 4px base unit; every row height is a multiple of 2. Scale by DPI
then round per §3 — never emit a fractional rect.

### 2.1 Chrome

```
tab rail height          40      bg_panel
tab height / radius      30 / 6  bg_raised when active, bg_hover on hover, else none
tab min / max width      132 / 220
tab padding              0 9 0 12    (0 9 0 4 when the dirty slot is present)
dirty slot               8       reserved on EVERY tab so nothing shifts
tab gap                  3
close button             16 box inside a 24 hit area
new-tab button           30 x 30, radius 6
caption button           46 x 40, 1px geometry inside a 10 x 10 box
menu bar height          30      bg_base
menu item                22 tall, radius 4, padding 0 10
status bar height        26      bg_panel, 1px border_subtle on top
status cell padding      0 12, 1px border_subtle between cells
```

### 2.2 Surfaces

```
menu panel               5 padding, radius 7, 1px border_subtle ring
menu row                 28 tall, radius 5, padding 0 10
menu divider             1px, 5 margin, 10 inset each side
palette panel            560 wide, radius 8
palette input row        42 tall
palette result row       30 tall, radius 5
tooltip                  24 tall, radius 5, padding 0 8, 11.5px
```

### 2.3 Editor

```
top padding              16      never 0 -- the first line needs air
side padding             24
line height              1.6 x font size, rounded to an even integer
caret width              2
gutter width             44 right-aligned + 12 gap, optional, off by default
scrollbar                8 wide, 4 radius, 6 inset from the right edge
tick marks               3 wide, 2 tall, in the scrollbar track
```

### 2.4 Radii — the whole list

```
0    editor, menu bar, status bar, table rows
4    menu bar items
5    menu rows, palette rows, close button, tooltips
6    tabs, find bar, commands control
7    menu and palette panels
8    settings cards, the window itself
```

Nothing larger than 8. No gradients. No blur. No glow. Shadows on menus and the palette
only — those are the only things that float.

### 2.5 Type

Two families by one designer, so they never clash. **Monaspace Neon** for the document
(the existing setting; the Font screen already explains why proportional families are
not offered). **Monaspace Argon** for chrome — the single change that most removes the
developer-tool feel. Ship both as static regular + bold (~1.1 MB for four faces) and
keep Consolas as the fallback so a missing font is never fatal.

```
document        Neon    user-set, default 11pt / 1.6 line     text_primary
tab label       Argon   12.5px / 400                          text_secondary
menu item       Argon   12.5px / 400                          text_primary
status bar      Argon   11.5px / 400  -- the floor, nothing smaller
settings title  Argon   13.5px / 400                          text_primary
settings desc   Argon   12px / 400                            text_muted
settings value  Argon   13px / 400                            text_secondary
screen title    Argon   19px / 500                            text_bright
group header    Argon   11.5px / 500, 0.1em tracking, caps     text_muted
palette query   Neon    13.5px                                text_bright
palette row     Argon   12.5px                                text_primary
accelerator     Neon    11.5px  -- mono so Ctrl+ columns align text_muted
tabular data    Neon    12.5px, tnum always on
```

Chrome sets `calt` off (no ligatures); the document leaves it user-controlled. Nothing
below 11.5px anywhere, at any zoom, in any screen.

---

## 3. DPI

A checklist to verify against the existing code, **not** an assumption that any of it is
missing. A 1440p and a 1080p monitor side by side is the worst case: dragging the window
between them changes DPI mid-session and Windows hands back a suggested rect at the new
scale.

1. **Per-monitor v2 awareness declared in the manifest** (`dpiAwareness = PerMonitorV2`),
   not via a runtime `SetProcessDpiAwareness` call. Manifest-declared awareness applies
   before the first window exists, so the first frame is correct. v2 also gets correctly
   scaled non-client area and dialogs.
2. **Confirm the `WM_DPICHANGED` order:** take the suggested rect from `lParam`,
   `SetWindowPos` to it exactly → rebuild the metrics struct → re-bake the glyph atlas
   at the new pixel size → invalidate. In that order; rebuilding the atlas before
   resizing wastes a bake.
3. **Round every metric once, at the point of scaling, into a struct.** Compute
   `m.tab_h = round(30 * s)` once per DPI change and read `m.tab_h` everywhere. Never
   scale at the call site — that is how two things that should align end up one pixel
   apart at 125%.
4. **Hairlines: `max(1, floor(s))`, never `round`.** At 125% a rounded hairline becomes
   1px at an offset straddling two device pixels and renders as two half-alpha lines.
   Floor it and snap its position to an integer.
5. **Caption geometry is drawn, so scale the stroke too.** The 10×10 box becomes
   `round(10*s)`; the 1px stroke becomes `max(1, round(s))`. At 150% that is a 15px box
   with a 2px stroke, which is right — a 1px stroke in a 15px box looks broken.
6. **Round the font pixel size to even, then derive.** Cell width and line height derive
   from it, and an odd line height makes vertical centring inside a 30px row land on a
   half pixel.
7. **One atlas per (family, size, weight, DPI).** Keep the previous DPI's atlas alive for
   a few seconds when dragging between monitors — users drag back and forth, and
   re-baking twice a second is the one place this design could stutter.
8. **Test matrix, whatever the current state:** 100 / 125 / 150 / 175 / 200%, plus the
   drag between the two real monitors. At each, check the menu-bar hairline, the caption
   stroke, the status-bar cell dividers, and the active tab's left edge against the
   editor's left padding. Those four catch nearly everything.

---

## 4. Window shell

### 4.1 Owning the caption area — checklist

```
WM_NCHITTEST     HTCAPTION for empty rail space          -> drag the window
                 HTCLIENT over tabs, buttons, the >_     -> they stay clickable
                 HTMINBUTTON/HTMAXBUTTON/HTCLOSE for the three caption buttons
                 HTMAXBUTTON is what makes Win11 snap layouts appear on hover.
                 Without it, hovering maximise shows nothing and users think it
                 is broken.
WM_NCCALCSIZE    extend the client area over the caption; keep the 8px resize
                 border or the window cannot be resized from the top edge
double-click     on empty rail space = maximise / restore
right-click      on empty rail space = the system menu (Move, Size, Close)
                 Cheap to forget, and its absence feels non-native immediately.
Win+arrow, snap  work for free once NCCALCSIZE and NCHITTEST are right
DWM corners      Win11 rounds the window; do not draw your own 8px radius on
                 top of it -- set DWMWCP_ROUND and let the compositor do it
inactive window  dim text_secondary -> text_muted on deactivate. One value,
                 and it is how a user tells which window has focus
maximised state  drop the window radius to 0 and remove the outer ring
```

### 4.2 Tabs

- **Dirty marker:** accent asterisk in a reserved 8px slot on every tab, so the label's
  truncation point never moves when a file becomes dirty. Not prepended to the filename
  string.
- **Truncation:** shrink from 220 toward the 132 floor first; then ellipsise the middle,
  not the end — `2026-07-27…-sync.md` keeps the extension, which identifies the file.
- **Ambiguous names:** when two open tabs share a filename, append the parent folder to
  both in `text_muted`. Full path in a tooltip after 500ms, always.
- **Close:** 16px geometry in a 24px hit area; visible only on the active tab and on
  hover, so a row of idle tabs is quiet. Middle-click closes any tab.
- **Reorder:** drag with a 4px threshold; the dragged pill lifts to `bg_raised` with the
  panel shadow and others slide 50ms. Drop outside the rail does nothing (no tear-off).
- **Closing a dirty tab:** not a modal — the tab turns `danger`-tinted and shows
  *Save · Discard · Cancel* inline in the rail for 4 seconds. Enter saves, Esc cancels.

---

## 5. Narrow windows — drop order

Things leave in reverse order of need; the survivors are the ones the OS requires.
Widths are client width at 100%. Breakpoints compare against the metrics struct, so they
scale with DPI for free.

| Width | Behaviour |
|---|---|
| ≥ 900 | Everything |
| 700 | **Status cells drop** right-to-left: Tab width → LF → UTF-8 → language. Ln/Col and line count always stay |
| 560 | **Tabs hit the 132px floor and the rail scrolls.** Chevron at each end when there is more; Ctrl+Tab lists all tabs in the palette. Do not shrink below 132 — a tab with two visible characters is worse than a scroll |
| 460 | **`>_` and the new-tab button drop.** Both keep keyboard routes (Ctrl+P, Ctrl+N) and the menu bar still has *Commands*, so nothing becomes unreachable |
| 360 | **Menu bar collapses to ☰** regardless of the setting; one tab remains |
| 318 | **Enforced minimum:** ☰ + one tab + three caption buttons. Set `WM_GETMINMAXINFO` to 318 × 240 logical, scaled |

Enforcing a real minimum is the actual fix — a drop order with no floor still eventually
overlaps.

---

## 6. Menus

Four problems are visible in the View menu screenshot. Verify each still applies before
changing anything:

1. **The check mark shifts the label.** ✓ is drawn in the text run, so *Toggle Markdown
   Preview* sits further right than its neighbours. Fix: a fixed **26px** check gutter
   reserved on every row of a menu that contains any checkable item, and none on menus
   that do not.
2. **Eighteen items, three dividers, one rhythm.** The five settings-ish items at the
   bottom are a different kind of thing from the view toggles. Group as: view toggles /
   search modes / zoom / palette + settings / customisation. Five groups, four dividers,
   nothing longer than four rows.
3. **"Toggle" ×3 is noise.** Word Wrap, Table View, Markdown Preview are all toggles and
   all carry a check mark, which already says so. Drop the verb. Saves 7 characters of
   width per row and reads faster.
4. **Disabled items give no reason.** *Table View* greys out on a `.md` file with no
   explanation. Show the reason in `text_muted` where the accelerator would be, or in a
   tooltip: *CSV and TSV files only*.

Additional rules:

- **Alt accelerators:** the underline appears only after Alt is pressed (Windows
  convention). 1px `text_primary`, snapped to an integer y.
- **Accelerator column:** right-aligned, `text_muted`, in Monaspace Neon — mono means
  every `Ctrl+` lines up without measuring.
- **Panel width:** widest label + 26 check gutter + 24 gap + widest accelerator + 20
  padding. Measure once on open; never a fixed width.
- **Placement:** left edge aligns with its menu-bar item's left edge; 2px gap below the
  bar. Flip left if it would leave the work area.
- **Highlight inset:** 5px panel padding means the highlight never touches the panel
  edge — the single biggest reason the menus read as unfinished in the screenshots.
- **Motion:** opacity only, 50ms. No slide, no scale. Highlight movement is instant for
  both mouse and keyboard.
- **Live values in labels:** *Reset Zoom (125%)*, *Tab Width (4)* — state without
  opening Settings.
- **Two selection colours:** mouse hover uses `bg_hover`; keyboard cursor uses the accent
  fill with `bg_base` text. Two states, two weights.

---

## 7. Command palette

Geometry: 560 wide, top edge 88px below the window top, horizontally centred, max 12
rows then scroll. Never full-height — a palette that fills the window looks like a mode,
and it is not one.

- **Matched characters carry the accent** — that is the whole ranking display. No second
  colour, no bold, no score bar.
- **Category is `text_muted`, right-aligned** next to the accelerator, both on the row's
  single baseline. In the palette screenshot the two columns are different sizes and
  neither aligns with the label.
- **Ranking:** fuzzy subsequence, case-insensitive, biased to word starts. Exact prefix >
  word-start subsequence > anywhere. Ties break by recency of use — a palette that learns
  beats a clever scorer.
- **Result count in the input row**, not the status bar. It is feedback on what was just
  typed and belongs next to the caret.
- **Prefixes:** `:124` goes to a line, `>` forces commands only, bare text searches
  commands *and* open tabs. Show available prefixes as a dimmed hint row when empty.
- **Open tabs are results.** With seven tabs open and a 132px floor, the palette is the
  real tab switcher. Ctrl+Tab opens it pre-filtered to tabs, most-recent-first.
- **Every command in it is also in a menu.** The palette is a faster route, never the
  only route — that keeps it optional for the client and complete for everyone else.

### 7.1 Palette entry point

The magnifier-plus-rounded-fill shape reads as "search your files", which is wrong. Two
recommended entry points, ideally both:

- **`>_` glyph in the rail** — 26×26, no fill until hover, same prompt the palette
  itself shows, so the button and the thing it opens look alike. Tooltip *Commands
  (Ctrl+P)*. Collapses first at 460px.
- **Menu-bar item** — *Commands  Ctrl+P* after a divider, at the end of the menu bar.
  Costs the rail nothing and is discoverable where people already look.

---

## 8. Editor surface

- **16px of top padding.** Text starting flush against the menu bar is the clearest
  "unfinished" signal in the screenshots. This one change does more for the feel than any
  colour.
- **Caret 2px, `caret` role, 500ms blink.** 1px carets disappear at 150% on a bright
  line. Stop blinking while typing and for 500ms after.
- **Gutter:** 44px right-aligned + 12px gap, off by default. Current line number in
  `text_primary`, others `text_muted` — that alone shows position without a line
  highlight.
- **Current-line tint off by default;** 3% when on. More turns a wrapped paragraph into
  stripes.
- **Selection is a run of rects, not per-glyph.** One instance per visual line, so only
  visible lines cost anything.
- **Scrollbar 8px wide, 6px inset, thumb min 24px.** No arrows, no track fill. Overlay
  style, always visible — auto-hiding scrollbars hide the tick marks, which are
  load-bearing during a find.
- **Tick marks in the track:** 3×2px `match_mark` per find hit, plus `bookmark` ticks.
- **Links:** `link` colour plus a 1px 35%-alpha underline — colour alone fails WCAG
  1.4.1. Underline thickens to 100% on Ctrl-hover, which is also the affordance that it
  is now clickable.
- **Wrap indent:** a wrapped line continues at the original indent + 2 columns, so
  wrapped prose stays visually distinct from a new line.
- **Wrap column cap:** in wrap mode cap the text column at 100 characters and left-align.
  On a maximised 1440p window an uncapped wrap gives 200-character lines.

---

## 9. Markdown — the priority

### 9.1 The grid is not the obstacle

**The preview pane does not need the grid at all.** The grid exists to make caret
arithmetic, column selection and hit-testing O(1). The preview has no caret, no selection
anchor, no column and no editing — it is read-only output. So it can use free
proportional layout while the editor pane keeps the grid untouched.

```
What the preview actually needs
1. a block list           Block :: struct { kind, level, spans: []Span, indent }
2. a span list per block  Span  :: struct { text, style_flags, colour_role }
3. one text shaper        given a font + a max width, emit positioned glyphs
                          and a height  -- this is the only new code
4. a scroll offset in PIXELS, not lines

Because it is read-only, you never map a pixel back to a character except for
one case: click-to-sync-scroll, which only needs the nearest BLOCK, not the
nearest glyph. Store each block's y range and binary-search it.

The shaper, in full
Proportional text needs per-glyph advances: one DirectWrite call
(IDWriteFontFace->GetDesignGlyphMetrics) or one stbtt_GetCodepointHMetrics per
glyph, cached in the same atlas map. Line breaking is greedy: accumulate
advances, break at the last space before max width. Greedy is what browsers do
for body text. No Knuth-Plass, no hyphenation.

Cost
Layout only the visible blocks plus a screen above and below. Cache each
block's laid-out glyph positions, keyed by (block index, pane width).
Invalidate a block on edit; invalidate all on resize or zoom. A 778-line
document lays out ~40 visible blocks -- microseconds, once, per width.
```

Preview glyphs go into the same atlas and the same instanced draw call as everything
else. No new pipeline.

### 9.2 Support list

Client put current support at roughly 50%, so this is a target list to diff against the
parser rather than a list of what is missing. CommonMark plus the four GFM extensions
people actually type, ordered by how often the absence is noticed.

| # | Feature | Editor pane (in grid) | Preview pane |
|---|---|---|---|
| 1 | ATX headings 1–6 | `md_heading`, bold, marks dimmed | size scale §9.3, h1/h2 get a rule |
| 2 | bold / italic / both | `md_bold` weight, `md_italic` slant | real bold + italic faces, marks hidden |
| 3 | inline code | `md_code` on `md_code_bg`, 3px radius | same, always Neon even in serif body |
| 4 | fenced code + lexer | `md_code_bg` block, `syn_*` inside | 6px radius block, 12px padding, lang label |
| 5 | lists, nested, ordered | `md_list_mark`, indent guides off | hanging indent, real bullets, 24px per level |
| 6 | tables + alignment | `syn_punct` pipes, aligned columns | real table, `md_rule` borders, zebra |
| 7 | blockquote, nested | `md_quote` text, 2px accent bar | 2px bar + 16px inset per level |
| 8 | links, autolinks, refs | `link` + underline, target dimmed | text only, Ctrl+click opens, title tooltip |
| 9 | task list items | accent `[x]`, `text_muted` `[ ]` | 14px box, accent tick, done text dimmed |
| 10 | thematic break `---` | `md_rule`, as typed | 1px `md_rule`, 24px above and below |
| 11 | strikethrough | `text_muted` + 1px line | 1px line at x-height centre |
| 12 | YAML front matter | `syn_comment`, collapsible | a small key/value card at the top |
| 13 | escapes, hard breaks | backslash in `syn_punct` | honoured |
| — | images | path as a link | placeholder box with the alt text; loading images means a decoder |
| — | footnotes | `link` colour | superscript + a list at the end |
| — | raw HTML | `syn_xml_tag` | show the source verbatim, never render it |
| — | setext headings | `md_heading` | treat as h1/h2 — cheap, rarely typed |

### 9.3 Preview type scale

The single biggest "this is a real application" lever. A proportional body face for prose
and Monaspace Neon for code is exactly the split Obsidian and VS Code use. Sizes are
multiples of the base document size `S`, so the whole preview scales with Ctrl+= for free.

```
                size        weight  face      colour       space above / below
h1              1.85 S      700     body      md_heading   0 / 0.6 S  + md_rule
h2              1.50 S      700     body      md_heading   1.6 S / 0.5 S + md_rule
h3              1.25 S      700     body      md_heading   1.4 S / 0.4 S
h4              1.10 S      700     body      md_heading   1.2 S / 0.3 S
h5 / h6         1.00 S      700     body      md_heading   1.0 S / 0.3 S  (h6 caps)
paragraph       1.00 S      400     body      text_primary 0 / 0.8 S, line 1.65
list item       1.00 S      400     body      text_primary 0.25 S between items
blockquote      1.00 S      400     body      md_quote     0.8 S / 0.8 S
code, inline    0.92 S      400     Neon      md_code      md_code_bg, 3px radius
code, fenced    0.92 S      400     Neon      syn_*        1.0 S / 1.0 S, 6px, 12 pad
table           0.95 S      400     Neon      text_primary always mono: columns align
caption / meta  0.88 S      400     body      text_muted

measure         72ch max, left-aligned, 40px left padding
Rounding: compute every size as round(k * S) into the metrics struct once.
h6 is the same size as body, distinguished by caps + tracking, not size.
```

**Which body face:** ship one proportional serif (Source Serif 4 subset to Latin is
~120 KB, OFL) or fall back to Georgia, which is on every Windows install. Serif over
sans, deliberately — it is what separates "document" from "UI". Make it a setting,
*Preview font*, defaulting to the shipped serif, with the editor font as one of the
options for people who want the preview to match the source.

### 9.4 Split view rules

- **Dim the syntax, don't hide it.** In the editor pane the `#`, `**` and `` ` ``
  characters stay — this is a text editor, and hiding characters that exist in the file
  breaks column arithmetic and trust. Dimming them to `syn_punct` gets 90% of the benefit
  for none of the risk.
- **Scroll sync by block, not by line.** Map the caret's block index to the preview's
  block y and vice versa. Line-based sync drifts the moment a heading or code fence
  changes height — the usual reason split views feel broken.
- **Re-parse incrementally.** Keep block boundaries; on edit, re-parse from the start of
  the containing block to the next blank line. Only a fence or table can extend past
  that, so widen to the fence end when one is open.
- **Ctrl+M cycles three states:** source → split → preview only. Remember per file type,
  per §11's *Remember last view used*.
- **Preview is selectable and copyable.** Read-only does not mean inert. Selection uses
  `selection_doc`; copy yields the rendered text, not the markdown. Needs pixel→glyph
  hit-testing within one block only, which the layout cache already has.
- **Keep the tick-mark rail.** The preview already has a coloured mini-map of headings
  down its right edge and it is genuinely good — keep it at 8px wide with `md_heading`
  ticks, and give the editor pane the same treatment for find hits.
- **Divider:** 1px `border_subtle`, 4px hit area, drags, min 320px each side, defaults
  50/50.

---

## 10. Table view

- **Column rules are gone.** `table_zebra` carries the eye instead. If the view draws a
  vertical line per column, that is 8 extra quads per screen and it makes the grid louder
  than the data.
- **Row numbers:** 56px right-aligned gutter in `text_dim`, `text_secondary` on the
  current row. Where there is no row-number gutter, counting rows by hand is the gap.
- **Empty cells show an em dash** in `text_dim`. In the screenshot the blank first column
  reads as broken parsing; a dash says "empty, and we know it".
- **Header is a real header:** `bg_raised` + a 1px `border_strong` rule beneath, sticky on
  scroll, click to sort with an accent arrow. Sorting is view-only and never rewrites the
  file.
- **Numeric and date columns right-align.** Detect by sampling the first 200 rows.
  Right-aligned numbers with `tnum` is the difference between a table and a text dump.
- **Column widths from a sample:** measure the first 200 rows, clamp each column to 8–40
  characters, distribute leftover width proportionally. Drag a header edge to resize;
  double-click to fit content.
- **Summary row at the bottom:** row count, column count, active sort — the questions you
  actually have about a CSV, in the place you already look for file facts.
- **Malformed rows are marked, not hidden.** A row with the wrong field count gets a 2px
  `warning` bar on its left edge and stays in place. Silently dropping data in a data
  viewer is the worst possible failure.

Metrics: header 30px, rows 26px, cell padding 0 10.

---

## 11. Settings and other tab-screens

Screens that open as tabs share one layout: 28px page margin, a title block, group
headers, and label / description / value rows.

- **Rows pad, they do not fix.** 11px top and bottom around a two-line block.
  Fixed-height rows clip the moment a description gets longer or the interface font gets
  larger.
- **28px margin on both sides.** The value column right-aligns to the same 28px as the
  title's left edge. In the screenshots the page indents at ~32 while the chrome pads at
  8–14; if that still holds, it is why the two halves look unrelated.
- **Selected row: `accent_wash` + a 2px accent bar**, and the value brightens to
  `md_heading`. The full-width blue band in the screenshot is the loudest thing on it; a
  wash plus a bar is unmistakable and quiet.
- **Show the affordance on the row.** A cycling value shows `‹ ›` (dimmed at the ends of
  the range), a sub-screen shows `›`, a toggle shows just its state. Three row types,
  visibly different, no icons.
- **Group headers earn their keep at ten rows.** This spec lists thirteen. Session /
  Appearance / Views, with new settings folded in where they belong rather than appended.
- **Mouse works everywhere.** Click a row to select, click the value to cycle, click
  `‹ ›` to step. The help line lists keys because keys are faster, not because the mouse
  is unsupported.

### Settings list

```
SESSION
  Restore session on launch      On        Reopen the tabs you had open, including unsaved ones
  Word wrap new documents        Off       Long lines fold to the window width instead of running off

APPEARANCE
  Theme                          Dark      Dark, Light, Follow Windows, or a custom .theme file
  Editor font                    Neon 11   Family, style, and size for the document surface
  Interface font        NEW      Argon 10  Tabs, menus, settings, and status bar
  Preview font          NEW      Serif 11  Body face for the markdown preview; code stays monospaced
  Zoom                           125%      Ctrl+= / Ctrl+- / Ctrl+0 anywhere
  Show menu bar         NEW      On        When off, Alt reveals it and the hamburger opens the same menus
  Reduce motion         NEW      Follow    Follows the Windows animation setting by default

VIEWS
  Markdown default view          Split     Applied when a .md file opens fresh (Ctrl+M cycles)
  Table default view             Table     Applied when a .csv/.tsv file opens fresh (Ctrl+T toggles)
  Remember last view used        On        Toggling a view updates the two defaults above
  Tab width                      4         Columns a Tab advances to
```

### 11.1 Font screen

- **Breadcrumb title:** *Settings › Editor font*, so a screen opened from another screen
  says where Esc goes back to. In the screenshot the Font tab gives no clue it came from
  Settings.
- **The preview should show real work.** Pangram, then the disambiguation set
  (`il1| oO0 -> == !=`), then **an actual coloured code sample** — you choose a coding
  font by looking at code in it, not at a sentence about a fox.
- **Keep the explanatory line** ("Proportional fonts are not offered: the editor lays
  text out on a fixed cell grid"). It is the best copy in the app — it answers "where are
  my other fonts" before the user asks. Under the preview, `text_muted`, 12px.
- **Dim the arrow at the range end.** `‹` goes to `text_dim` at the first family. Free
  feedback that the list has ends.
- **Live application, no Apply button.** Changing a value re-bakes the atlas and repaints
  immediately, as the theme file already does. Esc is the only exit and it keeps the
  change.
- **One screen, three uses.** Editor font, interface font and preview font are the same
  screen parameterised by target; only the preview block differs.
- Add a **Ligatures** row (NEW).

---

## 12. Find, Replace, Filter

Find lives in a bar at the top of the editor, not in the status line. The count is the
number you stare at while typing; in the screenshots it is the lowest-contrast text in
the window, at the bottom, 700 pixels from where you are looking.

Metrics: find bar 38px, field 26px tall / radius 6, toggles 24px tall, replace adds a
second 38px row.

- **Count next to the field, at 9.2:1.** `3 / 349` in mono so digits do not shift as you
  type. Zero results turns the field's focus ring `danger` and the count reads `0 / 0` —
  no beep, no shake.
- **Current hit vs the rest.** Current is accent fill with `bg_base` text; others are
  `find_match_bg` keeping `text_primary`. Both pairs clear AA — measure the text on the
  highlight, not on the page.
- **Three toggles, always visible, always labelled:** `Aa` case, `ab|` whole word, `.*`
  regex. Active = accent fill. While regex is a hidden Ctrl+R state, there is no way to
  tell why a search is behaving oddly.
- **Invalid regex is inline.** The field's ring goes `danger` and the reason replaces the
  count: *unterminated group*. Never a dialog, never silent.
- **Filter keeps original line numbers.** That is the whole value of the feature — the
  screenshots show it already working, and it is the best thing in them. Numbers in
  `text_muted`, not `text_dim`.
- **Filter band is 12% accent, not a green fill.** A mode must be obvious; it does not
  have to be the loudest thing on screen. Same fill as a selected settings row, so
  "something is active" reads consistently across the app.
- **Selection seeds the search.** Ctrl+F with a selection puts it in the field, selected,
  so typing replaces it. Ctrl+F with no selection keeps the previous term.
- **Esc closes and keeps the caret** at the current hit, clearing the highlight. Enter
  next, Shift+Enter previous, F3 works with the bar closed.

---

## 13. Status bar

26px, `bg_panel`, 1px `border_subtle` on top. Cells with 12px padding each side and a 1px
`border_subtle` between.

```
left   Ln 124, Col 94 | 778 lines | 42.1 KB
right  Markdown | UTF-8 | LF | Tab 4
```

- **Cells, not a sentence.** Facts about position on the left, facts about the file on the
  right — a fixed home for each, so the eye learns where to look.
- **Numbers in Neon, words in Argon.** Mono digits stop `Ln 9 → Ln 10` from shifting the
  row.
- **Selection count replaces the line count** when a selection exists, in accent:
  `42 selected, 3 lines`.
- **Save confirmation lives here.** `Saved` for 1.5s in `success`, then gone. No toast, no
  dialog, no sound.
- **Every cell is clickable.** Encoding opens the encoding menu, LF toggles line endings,
  Tab 4 opens tab width, the language opens the lexer list.
- **Errors take the whole bar** in `danger` until dismissed — *Could not save: file is
  read-only*. Nothing in this app should ever need a modal dialog.

---

## 14. 10 GB and still smooth

"Seamless" has a precise UI meaning here: the caret never stops responding, no progress
dialog ever appears, and partial results are visible while the rest is still being found.

```
THE ONE RULE
The UI thread never touches the file. It reads two things: a results buffer
that a worker appends to, and an atomic progress counter. Both are read-only
from the UI side, so there is no lock and no stall.

MECHANISM
memory-map the file   CreateFileMapping + MapViewOfFile in 256 MB views
                      The OS pages in what you touch. A 10 GB file costs no
                      RAM until read.
line index, lazily    a []i64 of line-start offsets, built by the worker
                      10 GB / ~80 bytes per line = ~134M lines = ~1 GB of
                      index. Too much. Index every 1024th line instead:
                      ~1 MB, and scan forward at most 1023 lines to find any
                      line. Instant.
filter on a worker    chunk on 4 MB boundaries snapped to newlines, one job
                      per hardware thread (core:thread pool). Each job appends
                      matches to its OWN buffer; the UI reads them in chunk
                      order, so results stay sorted with no contention.
results appear live   the filter list grows as chunks land, top-down
progress              atomic bytes_scanned / total, read once per frame

UI RULES
1. no modal, ever         the file opens instantly; the first screen of text is
                          available before the index exists
2. progress is a hairline 2px accent bar along the BOTTOM of the filter band,
                          width = fraction scanned. Disappears at 100%. This is
                          the only "loading" affordance in the application.
3. count is provisional   "1,284 lines so far..." while scanning, then
                          "1,284 of 134,217,728 lines". Never a spinner.
4. Esc cancels            sets an atomic flag; workers check it per chunk.
                          Instant, and keeps the partial results.
5. scrollbar is honest    thumb size reflects total bytes, not lines found
6. typing stays live      the filter query debounces 120ms, then restarts the
                          scan. Cancel, do not queue.
7. degrade one thing only at >2 GB, disable word wrap by default (wrap needs
                          the full line index) and say so in the status bar:
                          "Word wrap off -- large file". One honest sentence
                          beats a silently different behaviour.
```

---

## 15. The empty tab

- **The caret is already there,** top-left, blinking. The page is empty because it is an
  empty document, not because the app has not loaded.
- **Three hints, bottom-left, `text_dim`:** `Ctrl+O` open a file / `Ctrl+P` commands /
  `drop` a file anywhere in this window. Bottom-left keeps them clear of the first thing
  typed; they vanish on the first keystroke — never fade, never animate.
- **No logo, no welcome, no recent-files grid.** This is a notepad; it opens in under a
  second and you type. A splash screen would undo the one thing the app is best at.
- **Drop target:** dragging a file over the window draws a 2px accent inset ring on the
  editor area only — no overlay, no text, no dimming.

---

## 16. Icon

Three directions, all buildable from rectangles and one letterform, all legible at 16px —
the only size that really matters (taskbar, alt-tab, file association). Ship 16, 20, 24,
32, 48, 64, 256 in one `.ico`; do not scale one bitmap.

- **16a Caret on paper — recommended.** Warm paper (`#F2EBE0`), the accent caret, two
  lines of text. Says "type here" with no letterform, so it needs no localisation and
  reads at 16px where a letter would mush. Uses the app's own warm white and accent,
  which is what makes an icon feel like it belongs to its window.
- **16b Letterform.** `N` in Monaspace Neon Bold, accent on `bg_raised`. Cheapest to
  produce and makes the typeface part of the brand. Risk: a single letter on a dark
  rounded square is the most common indie-app icon there is.
- **16c Tabs.** Two tab stubs above a paper body — names the one feature that
  differentiates it from Notepad. Strongest at 48px+, weakest at 16 where the stubs merge;
  simplify to a single accent tab at 16px.

Also needed for a product: a document icon per associated extension (same shape,
extension label in the corner), a monochrome variant for the notification area, and an app
icon that does **not** change with the theme — Windows caches it, and an icon that flickers
between light and dark looks broken.

---

## 17. Themes and colour rules

**Never clamp, warn once, make the warning useful.** Clamping a user's colour is a bug
from their point of view, but a product shipping an accessibility claim should say when it
has been broken.

Warning UI: status bar, dismissible, once per save —
`Contrast  text_primary on bg_base is 2.9:1 — below the 4.5:1 needed for body text.
Applied anyway.    Ctrl+click to see all 6   ✕`

- **Check six pairs, not everything:** body-on-base, secondary-on-panel, muted-on-base,
  body-on-`selection_doc`, body-on-`find_match_bg`, `filter_text`-on-`filter_bg`. Those
  cover every place text sits on a themeable fill.
- **Keep `base dark` / `base light` inheritance.** It is the best decision in the current
  format: a nine-line theme file works, and adding a role later does not break every
  existing theme.
- **`Follow Windows` as a theme choice, if it is not already one.** Read the system
  light/dark preference, switch on `WM_SETTINGCHANGE`. Expected in a paid app; one
  registry read.
- **Theme editing stays a normal tab.** The file opens as a tab and Ctrl+S applies it
  live — better than a colour-picker dialog. Do add a 20px swatch in the gutter beside
  each colour line.
- **High contrast mode overrides everything.** On `SPI_GETHIGHCONTRAST`, build the theme
  from `GetSysColor` and set every alpha fill to solid. Cheap, because the theme is one
  struct.
- **Ship three, not one.** Dark, Light, and one high-contrast, plus the §1 files as
  defaults. A theme system with one theme looks unfinished.

### 17.1 Colour rules — UI notes

The rules file is the best-written document in the project and the reasoning about literal
patterns versus regex is right. Two UI notes:

- **Rule 3 needs to be visible, not just documented.** "Syntax highlighting wins,
  including `.log`" is genuinely surprising, and the file admits it. Surface it where it
  bites: when a rule is skipped because the lexer got there first, the status bar can say
  *3 colour rules inactive on this file — the log lexer already colours them*, clickable to
  the log. Otherwise a first-time user writes `ERROR = Danger`, sees nothing change, and
  concludes the feature is broken.
- **Hide the `Bg_*` roles from the rules docs.** The file lists them "for completeness"
  and then warns they make text unreadable — a role list containing six always-wrong
  choices is a trap. Move them to a footnote or drop them. Also validate on save: a rule
  using a `Bg_*` role warns in the status bar the same way a low-contrast theme does.

---

## 18. Motion, focus, accessibility

```
MOTION -- 50ms, five places, nothing else
tab / menu / row hover fill   50ms  ease-out cubic  colour only
active tab pill move          50ms  ease-out cubic  x + width, on reorder only
menu & palette appear         50ms  ease-out cubic  opacity only -- no scale, no slide
split divider drag            0ms   follows the pointer exactly
"Saved" in the status bar     0ms in, 1.5s hold, 0ms out

everything else                 0ms  caret, scroll, typing, selection, resize,
                                     filter results, theme switch, zoom

Reduced motion: SystemParametersInfo(SPI_GETCLIENTAREAANIMATION) at startup,
re-read on WM_SETTINGCHANGE. When false, every duration above becomes 0 and the
caret stops blinking. The Reduce motion setting defaults to following it and can
be forced on or off.

FOCUS RING -- one implementation, everywhere
2px focus_ring, 1px offset, matching the element's radius, drawn as one SDF
instance with an annular parameter. Appears on keyboard focus only (track a
"last input was keyboard" flag), never on mouse click. Applies to: tabs, the >_
button, caption buttons, menu-bar items, menu rows, palette rows, settings rows,
find fields and toggles, table headers, the split divider. If a thing can be
reached with Tab, it draws the ring.
```

- **1.4.3 AA on all body text.** Every pair in §1 is measured. The single exception is
  `text_dim` for disabled controls, which WCAG explicitly exempts and which is redundant
  with the control not responding.
- **1.4.11 non-text 3:1.** Caret 2px in `caret` (7.3:1), focus ring 2px, scrollbar thumb
  3.0:1, checkbox borders 3:1. Hairlines are decorative and exempt — they never carry the
  only cue for a boundary.
- **1.4.1 never colour alone.** Links get an underline; the dirty tab gets an asterisk as
  well as accent; the current find hit differs by fill *and* by the count; malformed table
  rows get a bar, not a tint.
- **Hit targets:** nothing interactive smaller than 24×24. Close glyph is 16px in a 24px
  box, toggles 24 tall, caption buttons 46×40.
- **Keyboard completeness:** every command is in a menu with an accelerator; the palette
  lists all of them. Tab order follows visual order: rail → menu bar → editor → find bar.
  Esc always backs out one level and never loses work.
- **Screen readers — be honest.** A custom-drawn editor is invisible to Narrator unless UI
  Automation is implemented. That is a real project. For v1, say so in the docs rather
  than shipping a half-working provider; if a buyer needs it, the text control pattern is
  where to start.
- **Zoom is the text-resize story.** Ctrl+= scales the document; chrome scales with the
  interface font setting. Together those cover 1.4.4 without a separate mechanism.
- **Gamma-correct text blending.** Not an accessibility checkbox, but it is why the
  measured ratios are true. Blend light-on-dark text in linear space or every value in §1
  is optimistic by roughly a weight.

---

## 19. Rendering pipeline

The whole redesign is one instanced quad pipeline. Rounded corners, hairlines, focus rings
and panel shadows are the same signed-distance rounded rectangle with different
parameters — no new geometry, no per-shape code, strictly less overdraw than drawing
borders as separate quads.

```odin
Rect_Instance :: struct {            // one 48-byte instance per visual
    rect:     [4]f32,                // x, y, w, h in pixels
    color:    [4]f32,                // premultiplied, linear
    radius:   [4]f32,                // per-corner, 0 = square
    softness: f32,                   // 0 = AA only, >0 = shadow blur
    _pad:     [3]f32,
}
```

```hlsl
// pixel shader, rounded-box SDF + analytic AA
float sd_round_box(float2 p, float2 b, float r) {
    float2 q = abs(p) - b + r;
    return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;
}
float d  = sd_round_box(local, half_size, radius);
float aa = fwidth(d);                          // 1px in screen space, any DPI
float a  = 1.0 - smoothstep(-aa, aa, d);       // softness=0 -> crisp edge
return input.color * a;                        // premultiplied, straight blend
```

- **Two draw calls per frame, total.** One for every rectangle in the window (chrome,
  tabs, menus, selection, zebra rows, shadows), one for all glyph quads with the atlas
  bound. The instance buffer is already in paint order.
- **Shadows are the same shader.** A menu shadow is one instance with `softness = 16`,
  offset +12y, black at 75% — one quad, not a blur pass, no render target, no downsample.
- **Hairlines too:** a 1px 7%-alpha instance with radius 0. Snap to integer pixels or it
  renders as two 3.5% lines.
- **Gamma matters more than antialiasing here.** Light text on a dark ground gets thin if
  blended in sRGB. Blend text in linear (sRGB-typed render target, or convert in the PS
  and back).
- **Idle cost zero.** Render on demand: rebuild the instance buffer when the model is
  dirty, present with flip-model (`FLIP_DISCARD`), block on `WM_PAINT` / input rather than
  spinning. The caret blink is the one timer — its own 500ms tick, redraw only on phase
  change.
- **Zero per-frame allocation.** One arena for the instance list, reset each frame;
  map / atlas / layout caches live for the tab's lifetime.

### Text rasterisation — two dependency-free routes

Odin ships D3D11, DXGI and the D3D compiler in `vendor:directx`, and a TrueType rasteriser
in `vendor:stb/truetype`. Both are part of the toolchain, not external packages.

- **Recommended — DirectWrite through Win32.** `DWriteCreateFactory → IDWriteFontFace →
  CreateGlyphRunAnalysis → CreateAlphaTexture(TEXTURE_ALIASED_1x1 | TEXTURE_CLEARTYPE_3x1)`.
  Microsoft's hinting and stem darkening are why system text looks crisper than most GPU
  editors. OS-provided, zero binary size, and it gives the metrics
  (`GetDesignGlyphMetrics`, `IDWriteTextAnalyzer`) otherwise written by hand. Requires
  hand-writing COM vtable structs for the DWrite interfaces used — a few hundred lines,
  once.
- **Alternative — `vendor:stb/truetype`.** Deterministic across machines, portable, and it
  allows an SDF atlas so zoom is free. Slightly softer at 11pt because there is no
  hinting. Use it if identical rendering everywhere matters more than maximum sharpness.

Either way: one `R8_UNORM` 1024×1024 atlas per (family, size, weight, DPI), packed with a
shelf allocator, grown by adding pages rather than reallocating. Because the document font
is monospaced, cache the advance once and position glyphs by integer column — no shaping,
no kerning table, no per-glyph measurement in the hot loop.

---

## 20. Build order

Ordered by visible improvement per hour. Estimates assume building from nothing —
subtract what exists. The ordering is dependency-driven and still holds.

| # | Step | Size | Why here |
|---|---|---|---|
| 1 | Paste the two theme files (§1) | an hour | Warm neutrals, one accent, AA everywhere. Biggest change, least code |
| 2 | Metrics struct + §2 values + 16px editor padding | half a day | Fixes the alignment and sizing called out. Prerequisite for §3 |
| 3 | Interface font setting + Monaspace Argon in chrome | half a day | Strongest anti-dev-tool move. Needs a second atlas, nothing more |
| 4 | SDF rounded-rect instance pipeline (§19) | a day | Radii, hairlines, shadows and focus rings become one shader. Everything after gets cheaper |
| 5 | Tab rail: pills, dirty asterisk, close hit area, focus ring | a day | The part of the window users look at most |
| 6 | Caption buttons as geometry + §4.1 checklist | a day | Snap layouts and the system menu are the "missing features" users report first |
| 7 | DPI: manifest, `WM_DPICHANGED`, rounding rules (§3) | a day | Belongs before the polish, not after — every metric depends on it |
| 8 | Menus, palette, settings and font screens (§6/7/11) | 2 days | Mostly re-laying-out what exists, once the metrics struct is in place |
| 9 | Find/replace bar out of the status line (§12) | a day | Fixes the worst contrast problem and adds visible search modes |
| 10 | Markdown: block/span parser to §9.2 level 13 | a week | The priority, but it wants the pipeline and metrics struct first |
| 11 | Preview pane: shaper, proportional face, type scale (§9.1/9.3) | a week | Where "looks like Obsidian" actually happens. Independent of the editor grid |
| 12 | Table view, narrow-window drop order, icon (§10/5/16) | 3 days | Independent of everything above; slot wherever convenient |
| 13 | Huge-file worker + progress hairline (§14) | a week | Last, because it is the only item where the UI work is the small half |

Steps 1–3 are worth doing on their own even if nothing else here happens.

---

## 21. Anti-slop constraints

"Modern" has a house style right now that would ruin a notepad, and it is easy to arrive
at by accident: a violet-to-blue gradient somewhere, frosted translucent panels, 16px
radii on everything, oversized rounded cards with a coloured left border, a glow on the
focused element, emoji in the settings list, one 700-weight sans doing all the work. All of
it is decoration competing with the text being read, and all of it costs frame time.

What this spec does instead:

- One accent, used only for state.
- Warm neutrals so the surface reads as paper rather than tooling.
- Radii capped at 8px.
- No gradient anywhere. No blur, no translucency over content, no glow.
- Shadows only on the two surfaces that genuinely float above the document.
- Type does the hierarchy; colour only marks state.
- The cosiness comes from the warmth of the greys and the space around the text — not
  from anything added on top of it.
