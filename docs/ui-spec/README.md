# The UI specification

**This is the corpus for every UI change.** Read the relevant section before designing one.

- [`newtpad-ui-spec-v1.md`](newtpad-ui-spec-v1.md) — the handoff copy. Use this one; it is what
  agents can read and grep.
- [`newtpad-ui-spec-v1.html`](newtpad-ui-spec-v1.html) — the same content plus rendered visual
  examples, including the three app-icon directions in §16. Open in a browser.

## Why it lives here now (2026-07-29)

It didn't, until this commit. It sat in a chat upload folder, so **every batch from 12 through 16
cited it secondhand** — through whatever a prior batch's design doc had quoted — and no session ever
read the source. That is how §9.3's "serif, deliberately" got carried forward as an unqualified
"proportional face", and how "§16 icon" stayed an unspecified TODO when the spec names a recommended
direction and its exact palette.

Wyatt, 2026-07-29: *"you should be using it as the corpus for ui changes already."* Correct. Now it
is in the tree.

## What it is, and what it is not

§0 states it plainly: **a target state, not an audit of the codebase.** It was written from
screenshots, `Light Custom.theme` and the colour-rules file. It does not know what is already
implemented, so a section describing something as missing may since have shipped — check
[HANDOFF.md](../../HANDOFF.md) for as-built status before treating a gap as real work.

Where the spec and the code disagree about *what should exist*, the spec wins unless Wyatt says
otherwise. Where they disagree about *what does exist*, the code wins.

## Build order

§20 carries the spec's own build order, and [batch 12's design](../superpowers/specs/2026-07-28-batch-12-ui-foundation-design.md)
maps every section to a batch with an as-built status column. That table is the fastest way in.
