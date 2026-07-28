# Batch 11 — ship-readiness (design)

Batch 11 of HANDOFF §6aa: the last batch before the beta. It is the first batch that is not about the
editor — it is about handing the editor to a stranger.

Decisions taken with Wyatt, 2026-07-27. **Do not relitigate.**

1. **Installer: Inno Setup.** One `.iss`, a single signable `setup.exe`, a proper Add/Remove Programs
   entry, install-over-running, and a silent flag. The build-time dependency never ships inside the
   exe, so it costs nothing against the 2–3 MB budget or the handmade story.
2. **Updater: manual check only, against the GitHub Releases API.** No background traffic. Research
   §D lists telemetry and phoning home as things this audience actively rejects.
3. **Crash reports: open the folder, and offer a prefilled GitHub issue.** Nothing leaves the machine
   unless the user attaches it deliberately.
4. **No beta expiry.** Honour-system, per `research/newtpad-research-report.md:117` — no DRM, no
   online checks. The binary enforces nothing. This also removes the worst failure mode: a time bomb
   that bricks every tester's editor if V1 slips.

## What is blocked on Wyatt, and stays blocked

- **A code-signing certificate.** Claude must never handle one or its password. The pipeline is built
  signing-*ready*: one documented, stubbed step that becomes real the day a certificate exists.
- **A storefront and a landing page.** Account creation and publishing are his.
- **The EULA text needs his review.** It will be drafted here; I am not a lawyer and the file will
  say so.

Also worth stating plainly, because the research says it and it is easy to forget while building a
signing pipeline: **signing barely helps with SmartScreen for a small unknown publisher.**
`research/newtpad-research-report.md:116` records File Pilot's author calling it *"worst money ever
spent."* The pipeline is worth building; the expectation is not that it removes the warning.

## Two facts found before speccing

- **Inno Setup is not installed on this machine** (`winget` is available). Nothing in this batch may
  *require* it at build time: `build.bat` must stay a single Odin invocation, and the installer step
  must detect `ISCC.exe` and skip with a clear message rather than failing. Installing the toolchain
  is one command Wyatt runs when he wants a `setup.exe`.
- **There is no HTTP anywhere in the tree.** `URL_SCHEMES` in `file.odin` is link *detection*; the
  only network-adjacent call is `ShellExecuteW` opening a browser. The updater therefore needs
  **WinHTTP hand-declared in `platform`**, the same way `dwrite.odin` hand-declares DirectWrite. That
  is the largest single piece of new surface in this batch and the only one that can hang.

## Item 1 — the update check

A `Help ▸ Check for Updates` row and a palette command. One HTTPS GET to
`api.github.com/repos/WGuethlein/Newtpad/releases/latest`, compare `tag_name` against
`NEWTPAD_VERSION`, and either say "you are up to date" or offer to open the release page in a browser.

**It must never block the UI thread.** CLAUDE.md's rule is that the main thread builds UI and handles
input and nothing else; a network call on it freezes the window for the connect timeout on a captive
portal or a dead DNS. Run it on a worker with the established pattern — copy inputs, work in private
memory, merge once per frame, poll a cancel flag — the same shape as the line-count indexer and the
search worker. **A worker that outlives the window is worse than no updater**, so teardown must join.

**Bound everything:** a connect and receive timeout (WinHTTP takes both), a response size cap (the
JSON is a few KB; refuse anything absurd rather than allocating it), and one request in flight.

**Parse defensively.** The response is untrusted input from the network. A hand-rolled scan for
`"tag_name"` is enough and is what the dependency bar argues for — do not add a JSON library for one
field. Anything unexpected is "could not check", never a crash and never a wrong "up to date".

**Version compare must be real.** `v0.19.0` vs `v0.9.0` is not a string compare — that says 0.9.0 is
newer. Parse three integers. A tag that does not parse is "could not check".

**Privacy:** no identifiers, no query parameters, no telemetry. A plain GET with a User-Agent (GitHub
requires one). Say in the menu row's own text that it contacts GitHub — the user should not have to
guess which of two commands touches the network.

## Item 2 — the crash-report path

`crash.odin` already writes a minidump and a human-readable report and shows a `MessageBox` naming
the path. What is missing is any way to act on it.

Replace the `MB_OK` with a choice: **open the folder**, **report it**, or **close**. `MessageBoxW`
cannot label three custom buttons, so this is either `MB_YESNOCANCEL` with the text explaining what
each does, or `TaskDialogIndirect` with real button labels. The task dialog reads better; it is one
more hand-declared COM-adjacent call in `platform`. Weigh it.

**"Report it" opens a prefilled GitHub issue URL** in the browser via the existing `shell_open_url`
— title, and a body pre-filled with version, OS build, and the crash's exception code and address.
**It must not paste file paths or document contents into the URL.** The dump stays on disk and the
user attaches it if they choose; the safety rule about not putting personal data in URLs applies
exactly here, and a crash in a file called `resignation-letter.txt` must not put that in a public
issue.

**This runs inside the unhandled-exception filter**, where the heap may be corrupt. `crash.odin`
already carries that discipline and its comments explain each exclusion. Everything added here must
respect it: no allocation that can be avoided, and the URL built into a fixed buffer. **If a
prefilled URL cannot be built safely inside the filter, build it at arm time and store it** — the
version and OS are known then and only the exception code is not.

## Item 3 — LICENSE and the notices

- **`LICENSE.txt` at the repo root** — proprietary, all rights reserved; the beta licensed free for
  evaluation; no redistribution; no warranty; the license converts or terminates when V1 ships. It
  must carry a plain line saying it was drafted by an AI and needs a lawyer's eye before money
  changes hands. **Wyatt reviews it; nobody should treat it as advice.**
- The installer shows it as the license page (Inno Setup has one) — which is the whole reason a real
  installer matters for a paid product later.
- A short **third-party notices** section: the tree depends on OS APIs plus Odin's `core`/`vendor`.
  That is a short list today and it is far easier to write now than to reconstruct at V1.

## Item 4 — the installer and the signing-ready pipeline

**`installer/newtpad.iss`:** installs to `%LOCALAPPDATA%\Newtpad` (per-user, no elevation — which is
also what keeps `HKCU` registration working as it does today), an Add/Remove Programs entry, a Start
Menu shortcut, the `OpenWithList` registrations `install.ps1` already writes for ~24 extensions, PATH
entry, uninstaller, `/SILENT`, and **close-or-upgrade handling for a running instance**.

That last one is the requirement `install.ps1` cannot meet and is why this exists: today the answer
is "close Newtpad first, and never `-Force`, because a hard kill skips the hot-exit session write and
loses unsaved tabs." An installer must do better — ask the running instance to close *gracefully* so
hot exit runs, and only then replace the exe.

**`install.ps1` stays** as the developer loop. It is faster and it is what the dev cycle uses. The
`.iss` is what a stranger gets.

**The signing step is stubbed and documented**, one place in `release.ps1`, with the exact
`signtool.exe` invocation commented and a clear no-op when no certificate is configured. **It must
never prompt for or store a password, and no certificate path may be committed.** Both the exe and
the setup.exe are signed when it becomes real.

**Portable stays first-class.** Principle 5: *"Small standalone exe — no install required; optional
embedded installer."* The release keeps attaching the bare `newtpad.exe`; the setup.exe is an
additional asset, not a replacement.

## Out of scope

Actually obtaining or using a certificate; a storefront; a landing page; auto-download/self-update
(decided: manual check only, and it wants signing first anyway); trial/license-key machinery (batch
12, after the beta); crash upload; any beta expiry.

## Verification

Per `docs/development-loop.md`. The risks to name to reviewers, by item: **1** the worker must not
block or outlive the window, the version compare must not be a string compare, and the parser eats
untrusted bytes; **2** it runs in the exception filter and must not leak paths or contents into a
URL; **3** nothing to test, everything to have read; **4** the running-instance path must not lose
unsaved work, and no certificate material may be committed.

**Most of this batch cannot be verified headlessly** — an installer's real test is running it, and
`ISCC` is not even present. Say so rather than implying coverage: the `.iss` will be authored and
syntax-checked at best, and Wyatt installs it on a real machine. The update check *can* be tested
against a fake response, and the version compare is pure and must be tested hard.
