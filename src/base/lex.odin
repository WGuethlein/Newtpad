// Layer: base — pure lexers over a line's raw bytes.
//
// A lexer here is a function from bytes to Tokens, nothing else. It must not
// import, reference, or otherwise know about Color_Role (program/theme.odin)
// or plat.Text_Span (platform/text.odin) — those live above base, and the
// mapping from a Token_Kind to a colour, and from a colour to a drawn span,
// is program's job (see src/program/highlight.odin). A lexer that reaches
// upward for either has crossed the base -> platform -> program boundary
// backward.
//
// That is not bureaucracy: it is what keeps a lexer testable with
// `odin test src\base` alone, with no Document, no Text, no GPU — the only
// fast test loop this project has (see CLAUDE.md's layer-boundaries rule).
// Keep this constraint in mind before adding an import here.
package base

// The vocabulary every lexer speaks. Mirrors the nine Syn_* colour roles
// theme.odin declared for this batch, plus None for "not part of any
// construct" (never emitted as a token; see each lexer's own contract).
Token_Kind :: enum u8 {
	None,
	Keyword,
	String,
	Number,
	Comment,
	Type,
	Punct,
	Json_Key,
	Xml_Tag,
	Xml_Attr,
}

// One recognized construct within a single line's bytes. `start`/`len` are
// byte offsets relative to whatever slice the lexer was handed — never
// document- or row-absolute. The caller (program layer) is responsible for
// rebasing these onto a visual row when word wrap splits the line the lexer
// saw into more than one drawn row.
Token :: struct {
	start: int,
	len:   int,
	kind:  Token_Kind,
}
