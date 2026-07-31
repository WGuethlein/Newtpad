# Reported, not yet scheduled

Bugs Wyatt reports from daily use **between** live passes. A live-pass checklist covers one release;
this file catches everything else, so a report made mid-batch is not lost to a chat transcript.

The other two lists: [requested-features.md](requested-features.md) for what is owed or asked for, and
[features.md](features.md) for what already works.

**How to use it:** when a batch is being scoped, read this file. When an item ships, delete it from here
and record it in the HANDOFF entry instead — this file is a queue, not a history.

---

## MEASURED AND FIXED 2026-07-31 — the white flash was real; the regression was not

**Reported 2026-07-31 by Wyatt**, on v0.34.1/0.34.2: *"when opening and closing the app it's no longer
snappy... it'll show a white box for a split second, then close/open."*

**The white box measured 196 ms and is gone.** `CreateWindowExW` passed `WS_VISIBLE`, so an empty
window went up 20 ms into startup and DWM composited it long before D3D presented anything: on real
desktop pixels, solid `FFFFFF` by ~85 ms and still white at ~200 ms, with the first Newtpad frame at
~220 ms. What filled that gap was `gfx_init` — **133 ms** of D3D11 device and swapchain creation,
which has nothing wasteful in it and simply must not be watched. The window is now created hidden,
shown after the first present, and hidden again the instant the loop exits.

**"No longer" is not supported by the measurement.** v0.32.0, v0.33.0, v0.34.0, v0.34.1 and v0.34.2
were each built from their tags and timed with the same harness on Wyatt's real session: white flash
196 ms and WM_CLOSE-to-exit 89–157 ms in *all five*, flat within noise. Whatever changed that day, it
was not the code — which makes the flash (present all along) the likely thing noticed for the first
time.

**All four suspects in the original entry were eliminated with numbers**, and the real shutdown cost
was none of them:

- **`WATCH_MAX` 32 → 64 is innocent.** At 40 open tabs — where the values actually differ —
  `watcher_stop` measured **18.2 ms** at 64 and **26.9 ms** at 32. The cost was `watch_worker`
  sleeping its poll interval in twenty 50 ms naps, so exit paid whatever was left of one: 24 ms
  median, 58 ms worst. It is now a posted `sync.Sema` and measures **0.13 ms**. `WATCH_MAX` stays 64.
- **The line index join is 0.00 ms**, including the 1.05 GB tab and including closing 300 ms after
  launch with the scan still running — `index_worker` polls `cancel` every 64 KB.
- **Snapshot checkpoint frees are 0.00 ms.** A restored session has an empty undo stack.
- **`session_save` is 33 ms** and is the largest thing left on the exit path. Left alone: it is
  writing the backups that are the only copy of an unsaved buffer.

Shutdown went 129 ms → **77 ms**, and the window now starts vanishing ~7 ms after the click instead of
after 40–105 ms of teardown. Full evidence, both instruments, the sabotage output and the before/after
tables: `.superpowers/sdd/reports/startup-shutdown.md`.

### Still open, and why this entry has not been deleted

1. **Does the window still take focus on launch?** `WS_VISIBLE` at creation got activation from the
   shell's launch rules for free; a window shown 220 ms later does not, so `window_show` calls
   `SetForegroundWindow`. Measured identical to the old build in this environment, but the harness
   cannot reproduce a real shell launch. **Launch from the shortcut and from an Explorer
   double-click.**
2. **One trade to sign off:** nothing is on screen for ~220 ms and then a finished window appears,
   where before an empty white one appeared at 28 ms. Time to a *usable* window is unchanged. One
   line to reverse if the wrong call.
3. **High DPI is unverified** — everything measured at 96 DPI.
4. **220 ms to first frame is 133 ms of `D3D11CreateDevice`.** Getting on screen sooner means painting
   a themed placeholder before the GPU is ready, which is a design decision, not a bug fix.

## "The preview does not always respect spaces" — one defect fixed, needs Wyatt's confirmation

**Reported 2026-07-29** with a side-by-side screenshot of the editor and the preview: *"it looks like it's
not respecting the spaces all the time."* **A defect matching that description was found and fixed**
(table columns were fitted at `text_char_width`'s whole-pixel grid cell while the cells were shaped at
the font's real advance, so at the default 16px size every table cell at its natural width broke at its
last space and dropped the last word onto a second line — `md_table_char_w`, `md_table_fit_selftest`).

**Left here because it is not certain that is what he saw.** What was ruled out, with evidence, in case
the report survives the fix:

- **Runs of consecutive spaces do NOT collapse** — the preview draws every space with its own advance
  (verified on rendered pixels: `AAAA    BBBB` keeps its four-space gap). It is *more* literal than
  CommonMark here, not less.
- **Leading indentation is preserved** — an indented paragraph line keeps its spaces, and nested list
  items get their depth from the indent. It is drawn in proportional spaces, so it is visibly *narrower*
  than the same indent in the monospace editor half, which may be what looked wrong.
- **The shaper is not losing spaces** — every space in a block's classified content survives into the
  spans and into the glyph stream (0 drops over the 144 blocks of `research/newtpad-research-report.md`
  plus a 31-block fixture), and `shaped_draw` positions each glyph at the shaper's own `x`, so the draw
  cannot collapse a run either.

**If he still sees it, the remaining candidate is the line-per-block model:** every source line is its own
`.Para` with a full `para_below` gap, so two adjacent prose lines look like two paragraphs and a blank
line between them adds nothing (blank runs are zero height, margins collapse). CommonMark joins those
lines into one paragraph with a space at the break. That is a design question, not a bug — ask before
changing it.

