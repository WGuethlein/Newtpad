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

// Lexer state carried from the end of one line to the start of the next, for
// grammars with a construct that can cross a line boundary (a block comment,
// a triple-quoted string...). lex_log and lex_json never produce or consume
// anything but .Normal -- they are entirely line-local (see each one's header
// comment) -- so this only matters to a lexer like lex_xml.
//
// Must stay exactly one byte: the background per-line state index (Task 3,
// program/lex_index.odin) is one Lex_State per line, so on a 10M-line file
// the index is 10 MB; a wider backing type multiplies that directly. If a
// future lexer's grammar cannot be captured in 256 states, that is a decision
// to bring back rather than one to make by quietly widening this enum.
//
// The two named values below are all lex_xml, lex_log and lex_json ever
// produce or consume. A lexer whose grammar needs more than a flat
// Normal/In_Comment split (Task 4's lex_c, for a NESTING block comment --
// see Keyword_Set.nest_comments, lex_c.odin) may reinterpret a non-Normal
// value's raw byte as an integer depth (1..255) rather than a boolean flag,
// entirely within this same one-byte budget: 0 stays Normal for every
// lexer, unconditionally, and every OTHER lexer only ever writes/reads 0 or
// 1, so a lexer that never nests is completely unaffected by one that does.
// That is a decision about how lex_c spends its own byte, not a change to
// this enum's size or its meaning for anyone else.
Lex_State :: enum u8 {
	Normal,
	In_Comment, // inside a <!-- ... --> whose closing "-->" hasn't been seen yet
}
#assert(size_of(Lex_State) == 1)

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
