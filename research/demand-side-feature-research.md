# Newtpad — Demand-Side Feature Research

Run 2026-07-18 (research session). Six parallel research agents, each a distinct lens:
narrative "why I switched" posts, Reddit/forum recommendation threads, competitor
feature/pricing pages, incumbent (Notepad++/Win11 Notepad) wishlists, the large-file/log
audience, and the everyday scratchpad user.

This is the demand-side round HANDOFF §4/§7 flagged as missing — the round that "did not
survive verification" and left the V1 list as *judgment, not evidence*. Findings below are
weighted by **cross-agent convergence**: a gap flagged by one agent is a lead; a gap flagged
by four independent lenses is a signal.

**Evidence honesty carried from the agents:** Reddit/SuperUser could not be fetched directly
(crawler blocked) — those items are search-summarized, directionally reliable but not
single-thread-quoted. Notepad++ issue-tracker reaction counts are modest (top asks ~15–43 👍),
because a 20-year-old tool has already shipped the obvious features; the louder volume signal
is on the Win11-Notepad side. Competitor feature lists skew toward marketing. HN threads were
weighted highest as genuine user voice.

---

## A. Strongest validation: our core bets hit the live nerve

The single loudest theme across every lens: **users are actively fleeing the incumbent
(Win11 Notepad) because Microsoft added AI, formatting, telemetry, account-gating, and
startup lag.** An entire cottage industry of "restore classic Notepad" / "disable
Copilot+formatting+spellcheck" guides now exists. Microsoft has since *walked back* Copilot
in Notepad after backlash.

This means Newtpad's locked identity is not just defensible — it's a **tailwind and a
marketable asset**:
- **No AI, no account, no telemetry** — the most unanimous single demand. "No AI, not even
  opt-in-in-the-menu, is a positioning asset."
- **Instant open + tiny native exe** — the emotional core; the exact nerve people cite when
  rejecting modern Notepad ("used to be instantaneous, now sluggish / 25 s to open").
- **Plain-text-first, minimal UI** — purist wing wants "absolutely zero features"; bloat that
  "removes the scratchpad workflow" is punished.
- **Tabs + session restore** — the one modern addition users broadly *welcomed* — BUT a vocal
  cohort wants it **off**; must ship a clean disable toggle or we reproduce the complaint.
- **Encoding detect/convert** — a quiet, perennial pain (ANSI mis-detection, garbled
  smart-quotes); well-targeted.

---

## B. Convergent gaps — flagged by multiple independent lenses (ranked)

### 1. Multi-cursor + column/block editing  — flagged by 4 of 6 agents
The consensus #1 gap. Narrative ("biggest gap"), Reddit ("strongest candidate to reconsider"),
competitor ("sharpest single gap — literally *every* paid and free competitor has it, stock
Notepad lacks it"), incumbent-wishlist ("biggest 'still behind VSCode' ask"). Concrete cited
workflows: strip timestamps from log columns, prefix many lines, Ctrl+D select-next-occurrence.
Tension: skews power-user, not the median notepad user. **Not on any part of our list.**
(Note: HANDOFF already specs multi-cursor for V2 as "File Pilot batch-rename model with
per-cursor copy/paste buffers" — the question is V1 vs V2.)

### 2. Filter-to-matching-lines (collapse a huge file to just the matches)  — large-file agent's headline
The large-file agent's strongest claim: **deferring this to V2 is "the real mistake, bigger
than the tail question."** It's the feature the log/sysadmin crowd praises *most* — above raw
open speed — because it's what makes a 10 GB log usable. Regex *find* (jump to next) is not a
substitute; they want the file collapsed to matches (ideally a separate pane with ±N context).
Crucially: **it reuses the same regex engine as find — incremental cost is UI, not core.**
Without it, "V1 for a log user is just a fast editor that opens big files — which is what
Notepad++-with-plugin already is, and they've rejected that class." **On our list only as V2.**

### 3. Fast search *inside* huge files (distinct from "it opens")  — narrative + Reddit + large-file
Users sharply separate "opens the 30 GB file" from "searches near EOF without an 11–16 s
freeze / crash." This is the failure mode that actually drove people off Notepad++ (mid-file
stutter and slow search, despite its reputation). **Partially on our list** (regex F/R exists)
but it needs to be a *load-bearing, benchmarked, never-freeze* promise, not a footnote — and it
interacts directly with the pending piece-table-vs-gap-buffer benchmark (extracted data said
gap buffers beat ropes ~7× on whole-buffer search).

### 4. The persistent, continuously-autosaved, never-nag scratch buffer  — scratchpad agent's headline
The deepest scratchpad want, after speed. Our list has "session restore incl. unsaved scratch
tabs" (persistence across restart) — but the audience wants more: a scratch buffer that is
**never a file you have to save at all**, already-there-on-open with cursor where you left it
(Emacs `*scratch*` / "note to self" model). Critical nuance: do it *without* Microsoft's
silent-data-loss mistake. Winning design = named files prompt/save normally; **untitled scratch
buffers autosave continuously to a recoverable, discoverable local store, never guilt-trip.**
Get the distinction right and it's a headline feature. **On our list only as "restore scratch
tabs" — the primitive is under-specified.**

### 5. Structured-data reformatting: JSON/XML pretty-print + CSV column view  — Reddit + competitor + narrative + large-file
The sharpest mismatch between what we ship and what's asked. We plan syntax *lexers*
(highlight json/csv/xml). Users specifically want *reformat*: JSON/XML pretty-print, and CSV
displayed as **aligned columns** (sort/filter/dedupe). EmEditor's *entire commercial pitch* is
CSV tooling; JSON Viewer + CSV are top Notepad++ plugins. Since Newtpad explicitly courts
json/csv/xml users, "highlight it" vs "format/tabulate it" is the gap most worth an explicit
decision. **Currently our V2 plugin proofs (JSON pretty-print, CSV column view) — the question
is whether first-party reformat belongs in V1.**

### 6. Crisp per-monitor DPI / multi-monitor scaling  — incumbent-wishlist agent's #1 by engagement
Highest raw engagement in the entire Notepad++ tracker (#6284, 43 👍 / 56 comments). A quality
bar, not a feature — and a natural **D3D11/DXGI win by design**. Cheap to get right if built in
from the start, expensive to retrofit. **Not stated as a V1 goal; should be.**

---

## C. Secondary gaps — real but lower-frequency or scope-stretching

| Gap | Who flagged | Cost / note |
|---|---|---|
| File compare / diff | Reddit, competitor (4 of 5 have it) | Stretches "notepad-first" scope; #1 N++ plugin (ComparePlus) |
| Sort lines / remove duplicate lines | Reddit, large-file | Cheap; high-frequency for log/data crowd |
| Highlighting / color rules (keyword→color) | large-file | Cheap given renderer; disproportionately loved by log users |
| Scrollbar match/occurrence marks | wishlist | Cheap; pairs with filter-as-you-type; "high satisfaction" |
| Macros / record-replay | narrative, Reddit, competitor | Power-user; overlaps regex F/R |
| Code folding | narrative, Reddit (Notepad3 has it) | Expected in "power notepad" tier |
| Markdown live preview | narrative, wishlist | We do md lexer, not preview |
| Bookmarks (incl. numbered) | narrative, Reddit, large-file | Cheap navigation, valued in big files |
| Global hotkey / always-on-top quick-capture | scratchpad | Whole product category; fits quick-note positioning |
| In-buffer block separators (Heynote-style) | scratchpad | Scratchpad-native alternative to tabs; beloved |
| Chord/multi-key hotkeys | wishlist | Low cost; fits our data-declared command system |
| Long-line handling (minified JSON, 500 MB single line) | large-file | Must not choke; NPP's INT_MAX line limit is why it fails |
| Print / print preview | wishlist | Requested but arguably out of "fast viewer" scope |
| Spellcheck | competitor (now in Win11 + EmEditor/UltraEdit) | Table-stakes creep for prose; conflicts with "fight options" |

---

## D. Anti-features — what this audience actively rejects (confirmed across lenses)

- **AI in a text editor** — loudest, most unanimous rejection. A positioning asset to omit.
- **Slow startup / heavy runtime** (WinUI3/UWP model, 1 GB idle) — our native D3D11 + arena
  story is the direct antidote; lead with it.
- **Telemetry / account requirement / cloud entanglement** — no-login is a hard expectation.
- **Feature bloat that removes the scratchpad feel** — tabs OK only if fast/empty feel is
  preserved by default.
- **Silent data loss & hidden plaintext artifacts** — Win11's no-warning close and its
  TabState `.bin` files (plaintext copies of encrypted files) both burned trust. Our autosave
  store must be intentional, discoverable, not a surprise.
- **Forced rich-text/markdown rendering on plaintext users.**

---

## E. Notably NOT demanded (safe to keep minimal)

- `file.txt:123` go-to-line syntax and drag-drop — table-stakes niceties, nobody lists them as
  switch drivers. Keep, but don't over-invest.
- Vim keybindings, split panes — single-to-few anecdotes; edge personalization at most.

---

## F. Competitive/pricing context (for positioning, not features)

- **Paid players are all moving to subscriptions.** EmEditor killed lifetime licenses (Aug 2024),
  now $39.99 yr1 / $19.99 renewal. UltraEdit $79.95/yr. Sublime $99 perpetual but updates
  expire after 3 yrs.
- **The free tier is crowded and capable** (Notepad++, Notepad3, Notepadqq — all $0).
- **Newtpad's opening:** one-time purchase, no bloat, genuinely fast — undercutting both the
  subscription treadmill and the AI-bloat direction, while beating the free tools on speed +
  polish. (Matches HANDOFF §5 pricing plan: perpetual, trial, no subscription, offline.)

---

## G. Decisions (made with Wyatt 2026-07-18 — now reflected in HANDOFF §4)

1. **Multi-cursor / column edit** → **Column/block editing in V1; full multi-cursor in V2.**
   Ship the rectangular-edit workflow (strip log timestamps, prefix many lines) now; defer the
   File-Pilot batch-rename-style per-cursor-buffer multi-cursor.
2. **Filter-to-matches** → **Pulled into V1.** The large-file credibility feature; cheap atop
   the find regex engine.
3. **Scratch buffer as a first-class primitive** → **Yes — a V1 headline primitive.** Always-there,
   continuous autosave to a recoverable store, cursor restore, no save-nag — spec'd to dodge the
   silent-data-loss / hidden-plaintext trap.
4. **First-party structured-data reformat (JSON/CSV/XML)** → **Held to the V2 plugin proofs.**
   V1 highlights these formats; reformat ships as the first-party proof of the plugin boundary.
5. **Crisp per-monitor DPI** → **Explicit V1 quality goal.** Near-free by design now.
6. **Session/scratch restore toggle** → **Confirmed — must be cleanly disable-able.**
