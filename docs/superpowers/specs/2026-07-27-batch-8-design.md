# Batch 8 — engine debt (design)

Batch 8 of HANDOFF §6aa. **Not started.** Written at the end of batch 7's overnight run so Wyatt can
redirect it before any code exists — because the batch lost half its contents overnight and its
headline item turns out not to be verifiable in this environment.

## Scope collapsed from four items to two, and neither is what §6aa expected

§6aa listed: release build time under the ~5 s rule · precompiled `.cso` shaders · batch the text
pipeline · settle the VirtualAlloc-arena decision.

- **Build time — resolved, not by this batch.** Measured 2026-07-27 at v0.17.0, warm, consecutive:
  `build.bat release` **5.12 / 5.07 / 5.07 / 5.31 / 5.08 s**; `build.bat release tests` **6.94 /
  6.91 s**; debug 1.07 s. The harness is ~1.85 s of it, so §6z's `NEWTPAD_TESTS` gating is what
  closed the gap and the 10.2 s figure predated it. The rule is met to within noise. **Do not spend
  a task here.** (HANDOFF §5's entry now carries both series.)
- **Arena decision — settled.** Wyatt's call, §6aa fork 3: amend the rule rather than build arenas.
  Done in batch 7 task 6; `CLAUDE.md`'s memory row now describes the code.

That leaves two, and they are very different in value.

## Item 1 — precompiled `.cso` shaders (low value; the audit downgraded it itself)

HANDOFF §5 lists this as "before ship", framed as dropping the `d3dcompiler_47.dll` runtime
dependency. **The 2026-07-25 audit already checked and downgraded that framing:** `d3dcompiler_47.dll`
ships in `System32` on Windows 10+, so this is startup cost and tidiness, **not a will-it-run risk.**

What is actually true today: `compile_shader` runs twice for quads and twice for text at startup
(`quads.odin:72,78`, `text.odin:377,382`), on the main thread, before the first frame. Nobody has
measured what that costs. **Measure before building** — this batch's whole lesson is that a debt
entry with no measurement behind it is as likely to be resolved as to be real. If it is under a few
milliseconds, say so in §5 and close the item.

If it is worth doing, the shape is straightforward and fits the existing build script: `build.bat`
already locates MSVC via `vswhere` for `cl` (the SEH shim) and `rc` (the DPI manifest), caching both
in `build\`. `fxc` comes from the same SDK and would cache the same way. The embed is `#load`, which
the tree already uses (`links.odin` does `#load("../../text_exts.txt")`).

**The one real design question:** `#load`ing a build artifact makes the Odin compile depend on `fxc`
having run first. That is already true of `guarded.obj` and `newtpad.res`, so it is not a new class
of dependency — but those are linker inputs and this would be a *source* dependency, which breaks a
bare `odin build` harder than the current omissions do. Decide deliberately whether to keep a
runtime-compile fallback (option bloat, two code paths, one of them untested) or to accept that
`build.bat` is the only supported build (already effectively true — a bare `odin build` omits the
DPI manifest and the SEH shim). **Recommendation: no fallback.** One path, and `build.bat` is the
build.

## Item 2 — batch the text pipeline. **This is the item, and it cannot be verified here.**

`text_draw_spans` does one heap allocation, two buffer maps and one `DrawInstanced` **per string**,
across 74 call sites, several inside per-row loops. `drawcount` measured a frame at 26 rows / 38
`text_draw` / 4 `quads_draw`. Batching is the prerequisite for the always-on line-number gutter
(§6k), which is a real user-facing feature, so this is the one item in batch 8 that buys something
beyond tidiness.

**But its acceptance criterion is "fewer draw calls, identical pixels", and this environment can
measure neither.**

- Draw calls are counted by `drawcount`, which **opens a real window, hangs, and locks the exe so the
  next build fails.** `docs/development-loop.md` §6 says never to run it. It is the only instrument
  for the numerator and it is unusable headlessly.
- "Identical pixels" needs a screen. There is no golden-image harness, and every claim about what
  the app draws is currently inference from source.

This is exactly the shape of failure this project keeps paying for — §6j's glyph atlas "grew only in
the commit message", and batch 7 found three more tests that passed with their bug sabotaged.
Rewriting the hot path of the entire text renderer with no way to observe the result is how that
happens again, at a scale where the symptom is "nothing renders."

**So the first task of batch 8 is not the batching. It is the instrument:**

1. **Make `drawcount` headless.** It needs a D3D device, not a *window* — `atlasgrowtest` already
   drives real glyphs through a real device without hanging, so the pattern exists in the tree. A
   counter that reports `text_draw` / `quads_draw` / instance totals for a rendered frame, runnable
   from the console, is the acceptance criterion for everything after it. It also retires a
   long-standing §6 trap.
2. **Then a pixel check that can fail.** Render a known string to an offscreen target and hash it, or
   read back the instance buffer and compare the instance stream before and after batching. The
   instance stream is the better target: it is what the GPU actually consumes, it is deterministic,
   and a batching change that alters one instance's UV or position shows up immediately. Compare
   *streams*, not counts — a count is exactly the kind of assertion that passes while the content is
   wrong.
3. **Only then batch**, with the stream comparison green before and after.

**Estimate honestly: this is a whole batch on its own**, and §6aa's pairing of it with the shader
tidy-up understates it. Splitting batch 8 into "8a: the instrument + `.cso`" and "8b: the batching"
is the right shape, and it means Wyatt sees a green instrument before any hot-path code moves.

## What to ask Wyatt before starting

1. **Is the line-number gutter actually wanted?** Batching's justification is that it unblocks the
   gutter (§6k). If the gutter is not going into V1, batching is pure performance work on a path
   nobody has complained about, and it should drop below batch 9's user-visible features.
2. **Is a golden-image or instance-stream harness worth building at all**, or is his live pass the
   intended verification for renderer work from here on? That answer decides whether batch 8a exists.
