# Platform subsystem audit — Win32 / COM / D3D11 / DirectWrite

Scope read in full: `src/platform/{gfx,quads,text,dwrite,shape,window,clipboard,crash,http,instance,draw_trace,seh}.odin`,
`guarded_copy.c`, plus the files not named in the brief that live in the same layer:
**`file.odin` (918 lines)** and **`path.odin` (313 lines)** — both covered below where they bear on
handles or the SEH shim. Non-code assets in `src/platform/`: `newtpad.ico`, `newtpad.manifest`,
`newtpad.rc` (read; the manifest does declare `PerMonitorV2`, which `build.bat` embeds via
`-resource:`).

Cross-checked against `HANDOFF.md` (7.5k lines), `docs/reported-bugs.md`, `docs/requested-features.md`.
Nothing below is already recorded except where stated. §6au's resize-arena fix and the Split-resize
crash were checked against every remaining resize path — the arena side is clean; a *different*
problem on the same path is finding 6.

`src/renderer` and `src/ui` stubs are not reported (planned extraction, per CLAUDE.md).

---

### [CRITICAL] Copying a selection that contains invalid UTF-8 dereferences NULL and kills the process
**Where:** `src/platform/clipboard.odin:13-16`
**Confidence:** CONFIRMED
**Fix risk:** SAFE
**Mechanism:** `ws := win.utf8_to_wstring(s, context.temp_allocator)` — Odin's
`utf8_to_wstring_alloc` (`core/sys/windows/util.odin:181-201`) calls `MultiByteToWideChar` with
**`MB_ERR_INVALID_CHARS`**, and returns **nil** on conversion failure rather than substituting
U+FFFD. The next three lines are:
```odin
src := ([^]u16)(ws)
n := 0
for src[n] != 0 {n += 1}
```
With `ws == nil` this reads address 0. There is no nil check anywhere in the procedure.
**Failure scenario:** `detect_encoding` (`src/base/encoding.odin:74-117`) sniffs only the first
`SNIFF = 4096` bytes. A 200 MB server log, a CSV exported by an old tool, or any file whose first
4 KB is clean ASCII but which carries one stray 0x80–0xFF byte later is classified `.UTF8`, and
`doc.original` then holds those raw bytes verbatim (`doc.odin:1874` — the UTF-8 path deliberately
does not transcode). Select a region spanning that byte (or just Ctrl+A) → Ctrl+C →
`doc_selected_text` returns the raw bytes → `clipboard_set_text` → `MultiByteToWideChar` fails →
nil → **EXCEPTION_ACCESS_VIOLATION**. The crash filter fires, so unsaved work is saved, but the
editor dies on a plain Ctrl+C over a file it advertises it can open.
**Fix:** `if ws == nil {return}` after the conversion, and convert with a lossy path
(`MultiByteToWideChar` without `MB_ERR_INVALID_CHARS`, or a hand-rolled UTF-8 decoder substituting
U+FFFD) so the user still gets their text. The nil guard alone is the one-line stop-the-crash fix.

---

### [CRITICAL] Cut deletes the selection even when the clipboard write failed — `clipboard_set_text` cannot report failure
**Where:** `src/platform/clipboard.odin:6-9` (signature + `OpenClipboard` early return);
consumed at `src/program/commands.odin:1456-1458`
**Confidence:** CONFIRMED
**Fix risk:** SAFE (platform half) / RISKY (gating the delete is behavioural)
**Mechanism:** `clipboard_set_text :: proc(owner, s) { if !win.OpenClipboard(owner) { return } ... }`
returns **nothing**. `OpenClipboard` fails whenever another process currently holds the clipboard —
this is the normal, documented, frequent condition on Windows (clipboard-history apps, Ditto,
ClipboardFusion, RDP clipboard redirection, Office/Teams). MS's own guidance is to retry; there is
no retry loop and no return value. The Cut path is:
```odin
} else if s := doc_selected_text(doc, context.temp_allocator); s != "" {
	plat.clipboard_set_text(w.hwnd, s)
	doc_backspace(doc) // deletes the selection
}
```
**Failure scenario:** User has a clipboard manager running. Selects a paragraph, Ctrl+X. `OpenClipboard`
returns FALSE, `clipboard_set_text` returns silently, `doc_backspace` deletes the paragraph. Ctrl+V
pastes whatever was on the clipboard *before* — the paragraph is gone from the clipboard entirely.
Recoverable only by noticing and hitting Ctrl+Z. Note that every *other* Cut branch in this switch
(`block_text` refusal, `md_preview_sel_text` refusal) is loudly reported — only the plain-selection
one is silent, and it is the common one.
**Fix:** `clipboard_set_text -> bool`, with an `OpenClipboard` retry loop (5 attempts, ~10 ms apart,
the standard pattern), and gate `doc_backspace` on the result with an `app_note` on failure.

---

### [HIGH] Copy silently truncates at the first NUL byte; combined with Cut, the remainder is destroyed
**Where:** `src/platform/clipboard.odin:16` (`for src[n] != 0 {n += 1}`)
**Confidence:** CONFIRMED
**Fix risk:** SAFE
**Mechanism:** U+0000 is a valid UTF-8 codepoint and a valid rune, so `utf8_to_wstring` passes it
through as a wide `0`. The length count then stops there. `n` is used for both the `GlobalAlloc`
size and the copy loop, so everything after the NUL is dropped. `SetClipboardData(CF_UNICODETEXT)`
would truncate at the NUL anyway — the point is that the *caller* is never told.
**Failure scenario:** `detect_encoding` only routes to UTF-16 when >30% of one byte-parity is NUL
(`encoding.odin:101-109`), so a log or dump with a handful of stray NULs is `.UTF8` and keeps them.
Select 500 lines containing one such byte on line 3, Ctrl+X → 2 lines reach the clipboard, all 500
are deleted from the buffer. Silent, and the paste that follows looks like the copy "didn't take".
**Fix:** count the converted units from the conversion's own return length rather than by scanning
for a terminator, and refuse (returning false, see the previous finding) when the text contains an
embedded NUL rather than shipping a prefix.

---

### [HIGH] The crash filter allocates from the heap and takes a mutex *before* it saves the user's work
**Where:** `src/platform/crash.odin:176-189` (`fmt.tprintf` ×2 → temp arena; `write_minidump`'s
`win.utf8_to_wstring` at :263 → `context.allocator` → HeapAlloc; `base.log_error` at :185 →
`sync.mutex_lock(&g_log.mu)`, `src/base/log.odin:96-107`)
**Confidence:** CONFIRMED (that it allocates and locks) / PLAUSIBLE (the specific deadlock)
**Fix risk:** RISKY
**Mechanism:** The filter's documented premise is "cannot assume the heap is intact"
(`crash.odin:9-12`), and `exception_name` explicitly enumerates `0xC0000374 HEAP_CORRUPTION` and
`0xC00000FD STACK_OVERFLOW` as expected inputs. Yet the very first statements after entry build two
paths with `fmt.tprintf` (Odin temp arena — grows via the heap), and `write_minidump` heap-allocates
a wide path *before* `MiniDumpWriteDump`. Step 2 then takes `g_log.mu`, a **non-recursive**
`sync.Mutex`. `on_fatal` — the only thing that saves unsaved buffers — is step 3, behind all of it.
The file comment at :253-259 concedes the heap allocation and defers the decision; it does not
mention the mutex.
**Failure scenario A (deadlock):** the fault occurs inside `base.log()` on the main thread (an AV
while formatting a `%s` over a freed string is exactly the shape of bug this handler exists for).
The thread already holds `g_log.mu`. `base.log_error` at :185 blocks on a mutex it owns → the filter
hangs on the faulting thread → **no report, no `on_fatal`, no message box, a frozen window and every
dirty buffer lost when the user force-kills**. **Failure scenario B (heap):** the fault is
`HEAP_CORRUPTION` or an AV raised inside `HeapAlloc`/`HeapFree`, so the process heap's SRW lock is
held or its structures are poisoned. `fmt.tprintf` on line 176 then hangs or re-faults — before the
minidump is even attempted.
**Failure scenario C (stack):** `STACK_OVERFLOW` — `write_report` (:289) puts a **64 KB** buffer on
the stack of a thread that has just exhausted its guard page. Second fault; `g_crash.handling` does
not help because the OS does not re-enter the filter. Work *is* saved first here (step 3 precedes
step 4), so this one costs only the .txt report.
**Fix:** format both paths into fixed stack buffers with the same `fmt.bprintf` discipline
`crash_issue_url` already uses; call `MiniDumpWriteDump` first with a `CreateFileW` over a
stack-built wide path; move `on_fatal` to immediately after the dump; replace `base.log_error` with a
lock-free ring append (or `sync.mutex_try_lock` with a skip on failure); shrink `write_report`'s
backing to a static rather than a stack array.

---

### [HIGH] A machine with no D3D11 hardware device exits silently — no window, no message, no console
**Where:** `src/platform/gfx.odin:107-117` (`.HARDWARE` only, feature levels `11_1`/`11_0` only,
`fmt.eprintfln`) and `src/program/main.odin:182-200`
**Confidence:** CONFIRMED
**Fix risk:** SAFE
**Mechanism:** `gfx_create_device` asks for `.HARDWARE` with no `.WARP` fallback and no feature
levels below `11_0`. Every failure path in `gfx_init`, `text_init` and `quads_init` reports via
`fmt.eprintfln`/`fmt.eprintln`, and `main` responds with `fmt.eprintln(...)` + `return`. **The
shipped exe is built `-subsystem:windows`** (`build.bat`: `if "%1"=="release" set "OPT=-o:speed
-subsystem:windows ..."`), so there is no console attached and every one of those messages goes
nowhere.
**Failure scenario:** a VM without 3D acceleration (VirtualBox default, some Hyper-V/Azure VM
configs), a machine mid-driver-reinstall, or a GPU that only reaches feature level 10_1. The user
double-clicks newtpad.exe; the process starts, creates a hidden window (`window.odin:404` — created
without `WS_VISIBLE` on purpose), fails `CreateDevice`, and exits with code 0. Nothing appears.
There is no way to find out why without a debugger.
**Fix:** fall back to `.WARP` after `.HARDWARE` fails, extend `levels` to include `._10_1, ._10_0`,
and on total failure call `plat.message_error(nil, ...)` (already available, `file.odin:632`) before
returning. `message_error` with a nil parent works from a windowless process.

---

### [MEDIUM] `gfx_resize` commits the new buffer size *before* `ResizeBuffers`, and drops its HRESULT — a single failure poisons the viewport permanently
**Where:** `src/platform/gfx.odin:309-318`
**Confidence:** CONFIRMED (the code defect) / PLAUSIBLE (frequency of the trigger)
**Fix risk:** SAFE
**Mechanism:**
```odin
if width > gfx.buf_w || height > gfx.buf_h {
	gfx.buf_w = max(width, gfx.buf_w)      // committed BEFORE the call
	gfx.buf_h = max(height, gfx.buf_h)
	if gfx.rtv != nil { gfx.rtv->Release(); gfx.rtv = nil }
	gfx.swapchain->ResizeBuffers(0, u32(gfx.buf_w), u32(gfx.buf_h), .UNKNOWN, ...)  // HRESULT discarded
	gfx_create_rtv(gfx)
}
```
This is the **only** dropped HRESULT in the whole D3D/DXGI surface (I checked every COM call in
`gfx.odin`, `quads.odin` and `text.odin`; every other one is tested). It is also the growth path
HANDOFF §6g explicitly leans on: *"Virtual-screen swapchain sizing would cost ~199 MB on triple-4K,
for a bug `gfx_resize` already handles by growing. Dropped."* Secondary hazard on the same line: DXGI
requires every direct **and indirect** reference to the back buffers to be released before
`ResizeBuffers`; the documented recipe is `ClearState` + `Flush`. Flip-model `Present` does unbind the
back buffer from the OM, so this is probably survivable — but nothing here makes it true on purpose.
**Failure scenario:** launch Newtpad on a 1920×1080 laptop panel (`buf_w`/`buf_h` fixed at
`SM_CXMAXTRACK`/`SM_CYMAXTRACK` at init, `gfx.odin:255-256`), then dock to a 3840×2160 external
monitor and maximize there. `width > buf_w` → the grow branch runs. If `ResizeBuffers` returns
anything but S_OK (out of video memory for two 33 MB buffers on integrated graphics; `DXGI_ERROR_INVALID_CALL`
from a residual reference), `buf_w`/`buf_h` already claim 3840×2160, `gfx_create_rtv` builds a view
over the **old 1920×1080** buffer, and the viewport is set to 3840×2160 every frame thereafter. The
right and bottom two-thirds of the window are never written. **And it never recovers**: every later
`gfx_resize` sees `width <= buf_w` and skips the branch entirely. Restarting is the only fix, and
nothing is logged.
**Fix:** test the HRESULT; only commit `buf_w`/`buf_h` on success; set `gfx.lost` on
`DEVICE_REMOVED`/`DEVICE_RESET`; `base.log_error` otherwise. Add
`ctx->OMSetRenderTargets(0, nil, nil)` + `ctx->Flush()` before the call.

---

### [MEDIUM] Every frame clears a desktop-sized render target, not a window-sized one
**Where:** `src/platform/gfx.odin:344` (`ClearRenderTargetView`) with the buffer sized at
`gfx.odin:255-256`
**Confidence:** CONFIRMED
**Fix risk:** SAFE
**Mechanism:** The swapchain buffer is deliberately fixed at `max(SM_CXMAXTRACK, w.width)` ×
`max(SM_CYMAXTRACK, w.height)` so a resize never reallocates — a good decision. But
`ClearRenderTargetView` **ignores the viewport and the scissor rect**; it clears the entire
subresource. The viewport (`gfx.odin:340`) is window-sized; the clear is not.
**Failure scenario:** `SM_CXMAXTRACK` is documented as referring to *"the entire desktop"*. On a
dual 2560×1440 setup that is ~5120×1440 ≈ 7.4 Mpx. A 900×600 editor window (0.54 Mpx of actual
content) pays a **13.7× oversized clear every frame** — ~1.8 GB/s of pure write bandwidth at 60 Hz,
on the machine class most likely to have integrated graphics driving two panels. It is also the
single largest thing between an idle wake and a present. Related, and worth measuring: at two buffers
× 4 bytes, that same triple-4K case is ~199 MB of VRAM — the exact number HANDOFF §6g says was
"dropped" by *not* sizing to the virtual screen. `SM_CXMAXTRACK` may already be buying it.
**Fix:** `ID3D11DeviceContext1::ClearView` with a `[0,0,width,height]` rect, or draw a full-viewport
quad through the existing pipeline. Also worth logging `buf_w`×`buf_h` at init so the VRAM claim in
§6g is a measurement rather than an assumption.

---

### [MEDIUM] One DirectWrite COM call per glyph per frame — the rune→glyph-index lookup has no cache
**Where:** `src/platform/text.odin:996-1011` (`rune_face`), called unconditionally at
`text.odin:1097` (`text_walk_glyphs`) and `shape.odin:660` (`shaped_draw`)
**Confidence:** CONFIRMED
**Fix risk:** SAFE
**Mechanism:** `rune_face` calls `c.faces[fi]->GetGlyphIndices(&cp, 1, &g)` — a COM vtable call into
DirectWrite, one codepoint at a time — for **every rune of every string drawn, every frame**. It is
not cached anywhere: `Text.cache` is keyed by `Glyph_Key{set, face, index, px}`, i.e. *after* this
resolution, and `Text.cell_cache` caches only the cell *width*. Worse, the loop walks the whole
fallback chain (`for fi in 0 ..< c.n`) until a face reports a glyph, so any non-Latin rune costs 2–4
COM calls per frame, and a rune no face has costs `n+1`. CLAUDE.md: *"Every repeated OS fetch gets a
cache with an eviction scheme."* This is the largest uncached repeated OS fetch in the layer.
**Failure scenario:** the measured baseline (`drawcount`, HANDOFF §6k) is 26 rows at 1280×720. At
~150 visible columns that is ~3,900 `GetGlyphIndices` calls per frame from the document alone, before
chrome. Maximized on a 4K panel at 100% it is ~15,000+/frame. Held-key repeat and live-resize repaint
pay it on every frame. It is pure duplicate work: the answer for `(set, rune)` cannot change until
`face_gen` moves.
**Fix:** a `map[struct{set: Font_Set, r: rune}]struct{set: Font_Set, face: u8, gi: u16}` beside
`cell_cache`, cleared by `text_reset_atlas` (which already runs on every font/DPI change and is
already the single invalidation point). Same lifetime rules as `cell_cache`, so no new eviction
policy is needed.

---

### [MEDIUM] The full pipeline state and the screen-size constant buffer are re-uploaded on every draw call
**Where:** `src/platform/text.odin:1192-1215` and `src/platform/quads.odin:251-272`
**Confidence:** CONFIRMED
**Fix risk:** SAFE
**Mechanism:** `text_submit_instances` sets blend state, input layout, topology, vertex buffers,
VS, VS constant buffer, PS, PS shader resource and PS sampler on **every call** — and issues a
`Map(WRITE_DISCARD)` on `t.constants` to write `{width, height}`, a value that cannot change within a
frame. `quads_draw` does the same for its own six state calls plus its own constant-buffer map.
Neither tracks what is already bound.
**Failure scenario:** at the measured 38 `text_draw` + 4 `quads_draw` per frame (HANDOFF §6k) that is
~380 redundant `ID3D11DeviceContext` calls and 42 redundant buffer maps per frame. The counts scale
with row count, and per-row work is already 68% of `text_draw` per that same measurement — so a
maximized 4K window with a gutter is in the low thousands. `draw_trace.odin`'s header already names
per-call `Map`/`DrawInstanced` as the batching target; the *state* half is the cheaper win and is not
mentioned there.
**Fix:** hoist the constant-buffer write into `gfx_begin_frame` (screen size is a frame property),
and set the two pipelines' immutable state once per pass rather than once per string. The digest
instrument in `draw_trace.odin` is exactly the right falsifier: call count down, `frame_digest`
identical.

---

### [MEDIUM] `GlobalAlloc` is leaked on two error paths, and `SetClipboardData`'s result is never checked
**Where:** `src/platform/clipboard.odin:18-28`
**Confidence:** CONFIRMED
**Fix risk:** SAFE
**Mechanism:** Three problems in eleven lines. (a) If `GlobalLock` returns nil the procedure returns
without `GlobalFree(h)` — the block leaks for the process lifetime. (b) `SetClipboardData`'s return
is discarded; ownership of the `HGLOBAL` transfers to the system **only on success**, so a failure
leaks it too. (c) `GlobalUnlock`'s result is discarded (benign, but it is the only one of the three
that genuinely is).
**Failure scenario:** (b) is the reachable one. `SetClipboardData` fails if the clipboard was closed
or re-opened by another process between `EmptyClipboard` and here — the same race that makes finding 2
real. Every failed Copy on a large selection leaks (selection bytes × 2) of `GMEM_MOVEABLE` memory,
permanently, with no way to reclaim it. A user repeatedly Ctrl+C-ing a 10 MB selection against a busy
clipboard manager leaks 20 MB per attempt.
**Fix:** `defer` a `GlobalFree(h)` that is cancelled only after `SetClipboardData` returns non-nil.

---

### [MEDIUM] The glyph atlas stores 4 bytes per pixel for a value the shader reads one channel of
**Where:** `src/platform/text.odin:1372` (`Format = .R8G8B8A8_UNORM`), the expansion at
`text.odin:1289-1297`, and the sample at `text.odin:407` (`atlas.Sample(samp, i.uv).r`)
**Confidence:** CONFIRMED
**Fix risk:** SAFE
**Mechanism:** `glyph_get` averages DirectWrite's three ClearType subpixels into one grayscale
coverage byte `c`, then writes `c` into all four RGBA channels of a freshly-allocated
`make([]u8, gw*gh*4)` staging buffer, uploads that via `UpdateSubresource`, and the pixel shader
reads `.r` and throws the other three away.
**Failure scenario:** 4× the VRAM and 4× the `UpdateSubresource` bandwidth for every glyph. At
`ATLAS_START` (1024²) that is 4 MB instead of 1 MB; at `ATLAS_MAX` (4096²) it is **67 MB instead of
16.7 MB** — and §6ab's own measurement says 300% DPI at 48px reaches the 4096² atlas with 9,768
glyphs, so the max is not hypothetical on a high-DPI CJK document. It also makes `atlas_relieve`'s
grow step (`atlas_create`, which allocates the new texture before releasing the old) transiently need
4× as much: 67 + 16.7 MB in flight instead of 16.7 + 4.2.
**Fix:** `Format = .R8_UNORM`, drop the RGBA expansion loop (upload `cov`'s averaged bytes directly),
`row pitch = gw` instead of `gw*4`. The shader already samples `.r`, so it needs no change. Verify
with `atlasgrowtest` against a real device, per CLAUDE.md's "a real device over arithmetic".

---

### [LOW] `GetDesignGlyphMetrics` and `GetGlyphIndices` HRESULTs are discarded; a failure silently collapses the cell grid to 1 px
**Where:** `src/platform/text.odin:604-608` (`face_char_em`), `:921` (`text_cell_width_at`),
`:1003`/`:1009` (`rune_face`), `:1230` (`glyph_get`)
**Confidence:** CONFIRMED (dropped) / PLAUSIBLE (the consequence)
**Fix risk:** SAFE
**Mechanism:** Both are `-> win.HRESULT` in `dwrite.odin:139-140` and neither result is tested at any
of the five call sites. Odin zero-initialises `gm: GLYPH_METRICS` and `gi: u16`, so a failure yields
`advanceWidth = 0` / glyph index 0 rather than garbage — but silently.
**Failure scenario:** `face_char_em` is the one that matters. It computes
`f32(gm.advanceWidth) / units` for `'x'`. If `GetDesignGlyphMetrics` fails (a bitmap-only or
CFF-variant face that `CreateFontFace` accepted, a corrupt installed font file), `char_em` becomes
0.0, so `text_char_width` returns `max(1, int(0 * px + 0.5)) = 1`. Every column in the document is
then one pixel wide: the caret, selection rects, find highlights and hit-testing all land on a 1-px
grid while glyphs draw at their real size. The app does not crash and reports nothing — it just
becomes unusable, and the cause is invisible.
**Fix:** test both HRESULTs. In `face_char_em`, fall back to `0.6` (a sane monospace ratio) and
`base.log_warn` the face name; in `text_load_family`, treat a zero `char_em` as a failed load so the
scratch-chain rollback that already exists takes over.

---

### [LOW] A failed buffer `Map` still issues the draw, against whatever the buffer held last frame
**Where:** `src/platform/quads.odin:251-272`, `src/platform/text.odin:1192-1215`
**Confidence:** CONFIRMED
**Fix risk:** SAFE
**Mechanism:** Both draw procedures wrap the upload in `if win.SUCCEEDED(ctx->Map(...)) { ...copy...
Unmap }` and then unconditionally fall through to `IASetVertexBuffers` + `DrawInstanced(4, n, 0, 0)`.
When `Map` fails, `n` is still the *new* instance count and the buffer still holds the *previous*
call's contents.
**Failure scenario:** `Map(WRITE_DISCARD)` on a `DYNAMIC` buffer fails on device removal
(`DXGI_ERROR_DEVICE_REMOVED`) and on driver-level OOM. The frame then draws the previous string's
glyphs at the previous string's positions — the visible symptom being duplicated or displaced text,
one frame before `Present` catches the removal and the app exits. Also note `draw_trace`'s digest
hashes what was *submitted to the CPU-side call*, not what actually reached the buffer, so the
falsifier cannot see this.
**Fix:** `return` from the draw when either `Map` fails, and set `gfx.lost` when the HRESULT is
`DEVICE_REMOVED`/`DEVICE_RESET` so the loop exits through the save path rather than waiting for the
next `Present`.

---

### [LOW] One mapped-file read still bypasses the SEH shim
**Where:** `src/program/doc.odin:1886` (`base.detect_line_ending(doc.original)`)
**Confidence:** CONFIRMED
**Fix risk:** SAFE
**Mechanism:** I traced every read of a mapping. The shim itself is correct and well-covered:
`guarded_copy.c` uses `__try/__except(1)` around a byte loop, `seh.odin`'s page-at-a-time wrapper
zero-fills faulted pages and reports false, `seh_selftest` proves the handler fires through the
Odin→C foreign call against a `MEM_RESERVE|PAGE_NOACCESS` page, `read_rec`
(`base/piecetable.odin:251`) routes every non-`from_add` piece through `safe_copy`, `doc_open`
guards both the sniff and the transcode (:1839, :1862), `doc.idx.guard` (:1885) covers the line-index
scan, and `lex_index_start` refuses mapped files outright (`lex_index.odin:137`). The one exception
is the line immediately *after* the guard flag is set: `detect_line_ending(doc.original)` reads
`doc.original[0 : SNIFF]` directly, and `doc.original` aliases the mapping on the UTF-8 path.
**Failure scenario:** the same class of bug the comment at `doc.odin:1828-1833` was written to close,
one line lower. The window is small — those pages were just read successfully through `safe_copy` a
few microseconds earlier — but with `bom > 0` the read also extends up to 3 bytes past the verified
region, and a log rotated or an NTFS-compressed file failing to decompress in that gap raises
`EXCEPTION_IN_PAGE_ERROR` and takes down every other tab's unsaved work.
**Fix:** `detect_line_ending(head[:n])` on the mapped branch — the bytes are already in the guarded
stack buffer at :1837, and `detect_line_ending` reads at most `SNIFF` bytes anyway, so this is a
free substitution.

---

### [LOW] `Glyph_Key.px` truncates `f32` → `u16`; fractional sizes already reach it, and the invariant is maintained only by arithmetic luck
**Where:** `src/platform/text.odin:1220` (`key := Glyph_Key{u8(set), u8(face), index, u16(px)}`);
violated at `src/program/fontpage.odin:49`, `src/program/settings.odin:662` (`UI_PX * 1.4`) and
`src/program/menu.odin:1208` (`UI_PX * 1.35`)
**Confidence:** CONFIRMED (truncation + fractional callers) / PLAUSIBLE (a colliding pair)
**Fix risk:** SAFE
**Mechanism:** The key truncates rather than rounds, so any two `px` values in the same integer
bucket share one cache entry — and that entry carries whichever advance and bitmap arrived first.
`markdown.odin:1680-1688` documents this hazard at length and defends against it by pre-rounding
every preview size into `Md_Metrics`. But the defence is local to markdown: three chrome sites
multiply `UI_PX` by a ratio at the draw site and hand the fractional result straight to `glyph_get`
(at 125% DPI, `UI_PX = 19` → `UI_PX * 1.35 = 25.65` → key 25).
**Failure scenario:** I enumerated the four `.UI` sizes in play (`UI_PX`, `UI_SMALL_PX`, `UI_PX*1.35`,
`UI_PX*1.4`) across DPI 96–960 and found no pair that truncates to the same integer today — the
collision is not currently reachable, and I am not going to claim otherwise. What is reachable is the
next one: one more chrome multiplier, or one settings-driven size, and a menu glyph silently
rasterizes at 25.65 px while laying out with 25 px advances (or vice versa), depending on draw order
within the frame. The markdown comment calls this out and explicitly defers the key change.
**Fix:** either round in `glyph_get` (`u16(px + 0.5)`) and accept that two sizes 0.5 apart share an
entry deliberately, or widen the key to hold the f32 bit pattern. The cheap interim: an
`assert(px == math.floor(px))` in `glyph_get` under `-debug`, which would have caught the three
chrome sites.

---

## MARKETABLE

Six sellable properties, each with file:line evidence and its real limit.

**1. Real GPU text rendering, not a bitmap blit.** Every glyph is rasterized once by DirectWrite into
a shared coverage atlas (`text.odin:1508-1541`) and drawn as an instanced quad
(`text.odin:1215`, `DrawInstanced`). A full 26-row screen at 1280×720 costs **38 text draw calls and
4 quad draw calls** — measured, not estimated (HANDOFF §6k, `newtpad drawcount`). All UI chrome —
rounded tabs, focus rings, hairlines, panel shadows — is the *same single quad shape* with different
signed-distance parameters (`quads.odin:118-160`), so the whole interface is one pipeline with no
per-shape code. **Limit:** those 42 calls are not yet batched into one; each still re-sets pipeline
state (see finding 9).

**2. A 1.4 MB single executable, no runtime, no installer.**
**Measured release exe: 1,445,376 bytes (1.38 MiB)** — `%LOCALAPPDATA%\Newtpad\newtpad.exe`, v0.66.0,
placed there by `install.ps1:73,84` which runs `build.bat release` and copies `build\newtpad.exe`.
(The 6,614,016-byte file currently in `build/` is a `-debug` build and is **not** the shipped
artifact; `build.bat` only sets `-o:speed -subsystem:windows` on `release`.) Zero third-party
libraries: DirectWrite's COM surface is hand-declared (`dwrite.odin`), WinHTTP is hand-declared
(`http.odin:36-48`), and the SEH shim is 26 lines of C with no CRT dependency (`guarded_copy.c:6-9`).
**Limit:** shaders compile from embedded HLSL at startup, so `d3dcompiler_47.dll` (a system DLL) is
still a load-time dependency — `quads.odin:6-8` flags precompiling it before V1.

**3. No launch flash — the window is not shown until real pixels exist.** The window is created
without `WS_VISIBLE` and shown only after the first frame has been presented
(`window.odin:404-415`, `window_show:480-484`). This was measured on real desktop pixels: the
previous behaviour produced a **196 ms white box** on every build back to v0.32.0, of which 132–145 ms
was D3D11 device and swapchain creation. **Limit:** the startup cost itself is unchanged — it is
hidden, not removed.

**4. Genuine per-monitor v2 DPI, including the parts most apps get wrong.** Declared by manifest
(`newtpad.manifest` → `.rc` → `-resource:`), not by API, so it applies before the loader.
`WM_DPICHANGED` updates the scale and re-runs the program's layout **before** honouring the OS's
suggested rect, so the nested `WM_SIZE` repaint already draws at the new scale
(`window.odin:773-798`). Non-client insets use `GetSystemMetricsForDpi`, not the plain call
(`window.odin:757-758`) — the plain one returns primary-monitor values once a process is per-monitor
aware, which is why competitors mis-inset a window maximized on a second monitor. Verified on
hardware across 100–300% (HANDOFF §6g). **Limit:** Windows keeps one DPI per window, so while a
window straddles two monitors it renders at the DPI of the one it last "belonged" to until the
majority crosses.

**5. It never holds your file hostage, and it survives files that change underneath it.** Files open
with `FILE_SHARE_READ|WRITE|DELETE` and the file handle is closed immediately after the mapping is
created (`file.odin:206-232`); change detection is timestamp polling with no handle retained
(`file_stamp:262-273`). Every read out of a memory-mapped original goes through an SEH-guarded copy
(`seh.odin:24-37` → `guarded_copy.c`), so a log rotated or truncated mid-read yields a *recovered
copy* instead of taking the process down — and the guard is proved against a real hardware fault at
startup, not assumed (`seh_selftest:48-58`). **Limit, stated plainly:** while a mapping is open,
Windows itself refuses truncation and deletion of that file by other processes with
`ERROR_USER_MAPPED_FILE` regardless of the share mode requested — Newtpad detaches to a private copy
as soon as it detects a change, which is what keeps the promise true in practice
(`file.odin:198-204`). Files below the mmap threshold are copied outright and have no such window at
all.

**6. One network call in the entire product, and your crash reports contain none of your data.** The
whole network surface is a single bounded HTTPS GET for the update check: HTTPS only
(`WINHTTP_FLAG_SECURE`, `http.odin:245`, with default certificate validation left intact — nothing
disables it), GET only, **no cookies, no auth, no redirects** (`http.odin:234-258`, set at request
level where it actually takes effect), all four WinHTTP timeouts set (`:228`), the response size cap
enforced *inside* the read loop before bytes are kept (`:295`), host and path validated against
injection (`http_host_ok:121-132`, `http_path_ok:136-143` — a newline in a path is request
splitting), and a User-Agent that is the literal string `"Newtpad"` with no machine id
(`:80`). The crash-report URL is structurally incapable of carrying your data: every substituted
value is a number Newtpad formatted itself or a compile-time literal, and the crashed file's path is
deliberately not among the arguments (`crash.odin:106-121`). Nothing is ever sent automatically.
**Limit:** the update check must not run on the UI thread (`http.odin:11-15`) — it is synchronous and
would freeze the window on a captive portal.

---

## Notes on things checked and found sound

Recorded so they are not re-audited: UTF-16 surrogate pairing across two `WM_CHAR` messages, with
orphan-low-surrogate rejection (`window.odin:874-898`); `WM_DROPFILES` querying the true required
length before copying and skipping rather than truncating, with `WC_ERR_INVALID_CHARS` on the
conversion (`window.odin:717-743`, `drop_path_convert:646-653`); `wnd_proc` staying `"contextless"`
so it cannot silently reset `assertion_failure_proc`; the `Alt+F4`/`F10` ownership predicate
(`key_belongs_to_windows:178-181`) and the enum-growth bug it documents; the `\\?\` long-path
handling in `path.odin`/`file.odin` (CLAUDE.md still says this is unimplemented — **it is
implemented**, `wide_path:189`, and that line of CLAUDE.md is stale); `FindClose`, `CloseHandle` and
`DragFinish` on every path in `file.odin`/`path.odin`; device-lost handling, which correctly saves
the session and exits with a real message rather than attempting an untested recovery
(`main.odin:1585-1605`) — a recorded decision, not a gap.
