# Odin bug report — `core:text/regex` renumbers capture groups

Written 2026-07-29, found while building regex replacement (HANDOFF §6as). Kept in the repo because it
is the reason `src/program/find.odin` drives `core:text/regex/virtual_machine` directly instead of using
the public `regex.match*` API — anyone who later tries to "simplify" that back to the public API needs
to read this first.

**Ready to file upstream as-is.** Reproduction at [`odin-regex-capture-bug/main.odin`](odin-regex-capture-bug/main.odin);
run `odin run .` from that directory.

---

## Summary

**Version:** `dev-2026-07-nightly:819fdc7`
**Package:** `core:text/regex`
**Severity:** silent wrong data — no error, no panic, plausible-looking output

When a capture group does not participate in a match — an optional group that did not fire, or the
losing side of an alternation — `core:text/regex` **removes it from the results and shifts every later
group down**. Group *n*'s text is reported at index *n − k*, where *k* is the number of
non-participating groups before it.

PCRE, .NET, JavaScript, Python and Go all preserve numbering and report the unset group as empty or
null.

## Reproduction

```odin
package main

import "core:fmt"
import "core:text/regex"

main :: proc() {
	re, _ := regex.create(`x(y)?(z)`)
	defer regex.destroy(re)
	cap, ok := regex.match(re, "xz")
	defer regex.destroy(cap)
	fmt.printfln("matched=%v len=%d", ok, len(cap.groups))
	for g, i in cap.groups {
		fmt.printfln("  groups[%d] = %q", i, g)
	}
}
```

**Expected** (PCRE / .NET / JS / Python / Go): three entries — `groups[0] == "xz"`, `groups[1]` unset
because group 1 did not participate, `groups[2] == "z"`.

**Actual:**

```
matched=true len=2
  groups[0] = "xz"
  groups[1] = "z"        <-- this is group 2, reported at index 1
```

### The clearest case: alternation becomes undecidable

```
pattern "(foo)|(bar)"  input "bar"   ->  groups[1] = "bar"
pattern "(foo)|(bar)"  input "foo"   ->  groups[1] = "foo"
```

Identical output shape for both inputs. A caller asking *"did group 1 or group 2 match?"* cannot answer
it — the information is gone.

### The shift compounds

```
pattern "(a)?(b)?(c)"  input "c"     ->  groups[1] = "c"     (group 3, at index 1)
```

## Root cause

All three capture-building paths in `core/text/regex/regex.odin` skip unset pairs while advancing the
output index only for participating ones:

| Procedure | Approx. lines |
|---|---|
| `match_and_allocate_capture` | 337–359 |
| `match_with_preallocated_capture` | 416–428 |
| `match_iterator` | 507–519 |

Each contains this shape:

```odin
n := 0
for i := 0; i < len(saved); i += 2 {
	a, b := saved[i], saved[i + 1]
	if a == -1 || b == -1 {
		continue          // unset group dropped entirely
	}
	capture.groups[n] = str[a:b]
	capture.pos[n] = {a, b}
	n += 1                // only advances for participating groups
}
```

**The VM's data is already correct.** `compiler.odin` emits `Save 2*id` / `Save 2*id+1` per capturing
group, so `saved[2n]` / `saved[2n+1]` *is* group *n*, with `-1` marking non-participation. The
information is present and right; it is discarded at the API boundary.

## Why this reads as a bug, not a design choice

- The `Capture` doc comment documents only the `pos`/`groups` correspondence
  (`str[pos[0][0]:pos[0][1]] == groups[0]`). Nothing states that indices are compacted.
- `doc.odin` explicitly advertises optional groups as supported ("such as an optional group") — exactly
  the construct that triggers this.
- **There is no way to recover true numbering through the public API.** The count of dropped groups is
  not exposed, so a caller cannot compensate.
- It is invisible in the common case: any test where every group participates passes.

## Suggested fix

Emit one entry per declared group, preserving index, with `{-1, -1}` and an empty string for
non-participants — `{-1, -1}` is already the VM's own sentinel:

```odin
ngroups := len(saved) / 2
capture.groups = make([]string, ngroups)
capture.pos = make([][2]int, ngroups)
for i in 0 ..< ngroups {
	a, b := saved[2*i], saved[2*i + 1]
	if a == -1 || b == -1 {
		capture.pos[i] = {-1, -1}
		continue
	}
	capture.groups[i] = str[a:b]
	capture.pos[i] = {a, b}
}
```

This is a breaking change for anyone relying on the compacted layout, so it likely warrants a release
note.

## Impact on Newtpad

`$1` in a regex replacement substituted the **wrong group** whenever a pattern had an optional group
before it. The workaround was to bypass the public API and drive `core:text/regex/virtual_machine`
directly, reading `saved`.

That works and is tested, but it couples `find.odin` to non-public stdlib internals: a signature change
breaks the build (fine), but a *semantic* change to the `saved` layout would be silent. The `${9}` and
`\B` cases in `linktest`/`findtest` are what guard it. **If this bug is fixed upstream, that workaround
can be deleted** — which is the main reason this file exists.

## Related, not filed

Two other limitations found in the same investigation. Neither is a bug; both shaped the design:

- **`MAX_CAPTURE_GROUPS` is 10 *including* group 0**, so 9 is the highest group any pattern can have
  (`common/common.odin`, `parser/parser.odin` rejects the tenth `(`). Raising it is a `#config` change
  that also affects search cost.
- **The engine cannot anchor a match at an offset.** The compiler injects a forward scan, and
  `Assert_Start` is literally `sp == 0` of the VM's string, so "match starting exactly here" is
  inexpressible. Newtpad works around it with a windowed re-match plus span verification; the residual
  is documented in `find_subst_one`'s header.
