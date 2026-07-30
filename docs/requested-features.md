# Requested, not yet scheduled

Features Wyatt asks for from daily use, between batches. The counterpart to
[reported-bugs.md](reported-bugs.md) — same rule: **when an item ships, delete it from here and record
it in the HANDOFF entry instead.** This is a queue, not a history.

**Read this when scoping a batch.** An item here has not been designed; it has been *asked for*, with
whatever the request needs decided still open.

---

## JSON formatting — pretty-print minified JSON

**Requested 2026-07-30** with two screenshots: a `.log` file whose content is one enormous single-line
JSON blob running far past the window edge, and a `tasks.json` already indented. Wyatt: *"json
formatting… so it turns something like this into its regular format."*

### This reopens a locked decision — flag it before building

HANDOFF §6aa records the prior call: *"first-party JSON/CSV/XML reformat — was decided **out** of V1 and
held to the V2 plugin proofs,"* and §6aa's "Explicitly out of V1" list repeats it. CLAUDE.md's plugin row
scopes the C-ABI to *"formatters + viewers"* precisely so a formatter is the thing that proves the plugin
boundary works.

So the question is not "should Newtpad format JSON" — Wyatt has answered that. It is **whether this
moves into V1 as a built-in, or stays the V2 plugin proof.** Building it first-party now is defensible
(it is small, and a beta with an unreadable log file is a bad first impression) but it spends the plugin
system's motivating example. **Ask before choosing.**

### The two screenshots are two different features

Worth separating, because they need different mechanisms and only one of them is "format a JSON file":

1. **A `.json` file that happens to be minified.** The whole buffer is one JSON document; formatting it
   is a whole-file transform. This is the obvious reading.
2. **A `.log` file whose *lines* contain embedded JSON.** The first screenshot is this — a log line with
   `{"@timestamp":…,"message":"[SEARCH TIMEOUT] {…}"}` and nested escaped JSON inside a string. The file
   is **not** a JSON document; each line is. Formatting the buffer as JSON would fail on line 1.

The second is arguably the more valuable of the two — it is the case where the text is genuinely
unreadable — and it is the one a naive "format the file" implementation does not touch.

### Decisions that change what gets built

- **Does it edit the buffer, or is it a view?** An edit is undoable, saveable, and changes the file the
  user may not own. A view (like the table and markdown views, both `doc_read_only_view`) leaves the
  bytes alone. Newtpad already has three view modes, so a *JSON view* is the more idiomatic answer and
  the safer one — but "format" in every other editor means an edit.
- **Whole file, selection, or current line?** The log case needs line or selection. The `.json` case
  wants whole file.
- **Must key order be preserved?** Yes for a diff to stay meaningful, and it rules out any
  parse-to-map-and-re-emit approach.
- **What about a file that is not valid JSON?** A log file's non-JSON prefix, a trailing comma, a
  truncated line. **Refusing silently is the worst option** — the same reasoning §10 applies to malformed
  CSV rows: mark it, do not hide it.
- **Indent width, and does it follow a setting?** Two spaces is the common default; the codebase already
  has a tab-width setting.
- **How big can it be?** Newtpad opens multi-GB files, and CLAUDE.md's viewport-first rule forbids a
  whole-document pass on the main thread. A 2 GB minified JSON is a real input for this feature, and
  formatting it is exactly the unbounded work the rule exists to prevent. **This is the constraint most
  likely to decide the design** — a view that formats only the visible region sidesteps it; an edit does
  not.

### What already exists to build on

`src/base/lex_json.odin` is a hand-rolled JSON lexer, already viewport-bounded and already used for
syntax highlighting. A formatter that consumes its token stream inherits the bounding for free and
cannot disagree with the highlighter about what a token is — which is the single-producer rule this
project keeps relearning. **Do not write a second JSON parser.**
