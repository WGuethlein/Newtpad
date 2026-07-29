// Minimal reproduction: core:text/regex renumbers capture groups when an
// earlier group does not participate in the match.
package main

import "core:fmt"
import "core:text/regex"

show :: proc(label, pattern, input: string) {
	re, err := regex.create(pattern)
	if err != nil {
		fmt.printfln("%s: create failed: %v", label, err)
		return
	}
	defer regex.destroy(re)

	cap, ok := regex.match(re, input)
	defer regex.destroy(cap)

	fmt.printfln("--- %s", label)
	fmt.printfln("  pattern %q  input %q  matched=%v", pattern, input, ok)
	if !ok {return}
	fmt.printfln("  len(groups) = %d", len(cap.groups))
	for g, i in cap.groups {
		fmt.printfln("    groups[%d] = %q   pos = %v", i, g, cap.pos[i])
	}
}

main :: proc() {
	// Group 1 is optional and does NOT participate. Group 2 does.
	// Expected (PCRE / .NET / JS / Python / Go): groups[1] is the unset group 1
	// (empty / nil), groups[2] == "z".
	// Actual: groups[1] == "z" -- group 2's text is reported at index 1.
	show("unset FIRST group", `x(y)?(z)`, "xz")

	// Control: when both groups participate, numbering is correct. This is why
	// the bug is easy to miss -- every test with fully-participating groups passes.
	show("both groups participate", `x(y)?(z)`, "xyz")

	// Two unset groups shift the third by two.
	show("two unset groups", `(a)?(b)?(c)`, "c")

	// Alternation: only one side ever participates, so the surviving group is
	// always reported at index 1 regardless of which one it actually is.
	show("alternation, right side", `(foo)|(bar)`, "bar")
	show("alternation, left side", `(foo)|(bar)`, "foo")
}
