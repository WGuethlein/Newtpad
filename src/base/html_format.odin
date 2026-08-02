// Layer: base — reformatting minified HTML, as a narrower variant of xml_format.
//
// It reuses xml_format's machinery entirely and adds exactly one rule, because
// HTML has a hazard XML does not: **whitespace between INLINE elements renders.**
//
// xml_format's existing rule already covers mixed content -- an element with any
// non-whitespace text of its own goes out byte for byte, so `<p>Hello <b>x</b>!</p>`
// is safe there and here. What it does not cover is element-ONLY content made of
// inline elements:
//
//     <div><span>a</span><span>b</span></div>
//
// The `<div>` has no text of its own, so xml_format lays it out and puts each
// `<span>` on its own line. In XML that is a pure formatting change. In HTML the
// newline between `</span>` and `<span>` collapses to a rendered SPACE, so "ab"
// becomes "a b" -- the document now says something different, silently, which is
// the failure mode that got a JavaScript formatter refused outright
// (requested-features.md §1). A formatter that edits the buffer must never do it.
//
// So: an element is laid out only when every element directly inside it is
// block-level. One inline child and the whole subtree is copied verbatim, the
// same treatment text already gets.
//
// **This is the "hardcoded list of text-ish element names" xml_format's header
// rejects, and it is not a reversal.** That rejection is about XML, where the
// elements whose whitespace matters have names nobody can enumerate, so a list
// guesses wrong on every vocabulary but one. HTML *is* that one vocabulary: the
// set is fixed, published, and small. The list is wrong for XML for precisely the
// reason it is right here.
//
// The cost, stated plainly: a page of prose comes back close to unchanged, and a
// page of structure -- the minified `<div>` soup people actually stare at --
// becomes readable. That is the same honest trade xml_format makes.
package base

// Elements whose surrounding whitespace is rendered, plus the two whose INNER
// whitespace is significant (`pre`, `textarea`). Both kinds mean the same thing
// to this formatter -- do not reflow anything containing one -- so they share a
// table rather than being tracked apart for a distinction that changes nothing.
//
// From the HTML Living Standard's rendering section. `img`, `input`, `button`,
// `select` and `textarea` are here because they are replaced/inline-level and a
// line break beside them renders exactly as it does beside a `<span>`.
@(private = "file")
HTML_INLINE := [?]string {
	"a",
	"abbr",
	"b",
	"bdi",
	"bdo",
	"br",
	"button",
	"cite",
	"code",
	"data",
	"datalist",
	"dfn",
	"em",
	"i",
	"img",
	"input",
	"kbd",
	"label",
	"map",
	"mark",
	"meter",
	"noscript",
	"object",
	"output",
	"picture",
	"pre",
	"progress",
	"q",
	"rp",
	"rt",
	"ruby",
	"s",
	"samp",
	"select",
	"slot",
	"small",
	"span",
	"strong",
	"sub",
	"sup",
	"svg",
	"template",
	"textarea",
	"time",
	"u",
	"var",
	"video",
	"wbr",
}

// Case-insensitive over ASCII: `<SPAN>` and `<span>` are the same element, and a
// hand-written or legacy page may use either. Compared without allocating -- this
// runs once per token on a file that can be megabytes.
html_is_inline :: proc(name: string) -> bool {
	if len(name) == 0 || len(name) > 16 {return false} // no inline name is longer
	for cand in HTML_INLINE {
		if len(cand) != len(name) {continue}
		same := true
		for i in 0 ..< len(name) {
			c := name[i]
			if c >= 'A' && c <= 'Z' {c += 32}
			if c != cand[i] {
				same = false
				break
			}
		}
		if same {return true}
	}
	return false
}

// Reformat minified HTML. Same contract as xml_format -- same errors, same
// `at` offset, caller owns `out` -- differing only by the inline rule above.
html_format :: proc(src: []u8, indent: int, allocator := context.allocator) -> (out: []u8, err: Xml_Error, at: int) {
	return xml_format_impl(src, indent, true, allocator)
}
