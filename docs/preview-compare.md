---
title: Front matter must be the first thing in the file
tags: [comparison, fixture]
draft: true
---

# 1 · Headings

## h2 · the second level

### h3 · the third level

#### h4 · the fourth level

##### h5 · the fifth level

###### h6 · the sixth level

Setext h1
=========

Setext h2
---------

# 2 · Inline

Body text long enough to wrap two or three times, so line height and the measure are both
visible at once. It carries **bold**, *italic*, ***bold italic***, `inline code`,
~~strikethrough~~, an [inline link](https://example.com), a bare autolink
<https://example.com/a/path>, an escaped \*asterisk\* and a trailing‑space hard break here  
which should start a new line without starting a new paragraph.

A second paragraph, to show the space between two paragraphs against the space after a
heading. It also has `code containing a backtick`` `` and an unusually long unbroken token
https://example.com/a/very/long/path/that/will/not/fit/inside/the/measure/at/all to show
what overflow does.

# 3 · Lists

- Bulleted item
- A longer item whose text runs past the end of the line, so the wrap and the hanging indent
  under the marker are both visible
  - Nested item, second level
    - Third level
- Back to the first level

1. Ordered item
2. Second ordered item
   1. Nested ordered
   2. Second nested
3. Third ordered

- Mixed: a bullet holding an ordered list
  1. First
  2. Second

A loose list, whose items are separated by blank lines:

- First loose item

- Second loose item

- An item with two paragraphs.

  This is the second paragraph inside that item.

- [ ] Unticked task
- [x] Ticked task
  - [ ] Nested unticked
  - [x] Nested ticked

# 4 · Blockquotes

> A blockquote that wraps once, so the bar's height against its text can be judged.
> A second line of the same quote, with no blank line between them.
>
> A second paragraph inside the same quote.

> > A nested quote
> > > And a third level

> A quote containing a list:
>
> - First
> - Second
>
> ...and a fence:
>
> ```json
> { "inside": "a quote" }
> ```

# 5 · Code

```powershell
Get-ChildItem -Path $env:TEMP | Where-Object { $_.Length -gt 1MB }
```

```json
{ "key": "value", "count": 42, "nested": { "flag": true } }
```

```odin
main :: proc() { fmt.println("hello") } // a language with a lexer
```

```notalanguage
this fence names a language nothing knows
```

```
this fence names no language at all
```

~~~
a tilde fence rather than a backtick one
~~~

    An indented code block, four spaces, no fence at all.
    Second line of it.

A fence with a line far too long to fit, to show whether it wraps or scrolls:

```sh
echo "aaaaaaaaaa bbbbbbbbbb cccccccccc dddddddddd eeeeeeeeee ffffffffff gggggggggg hhhhhhhhhh iiiiiiiiii"
```

# 6 · Tables

| Left | Centre | Right | Notes |
|:---|:---:|---:|---|
| first | 42 | 1.00 | short |
| a longer value | 7 | 22.50 | wraps if the column is tight |
| | | | an entirely empty row's cells |
| **bold** | *italic* | `code` | [a link](https://example.com) |

# 7 · Rules

Three ways to write a thematic break, each with a paragraph either side.

---

Between the first and second.

***

Between the second and third.

___

After the third.

# 8 · Not supported yet

An image, which the preview has no handling for at all:

![alt text](https://example.com/image.png "a title")

A footnote reference[^1] in a sentence.

[^1]: The footnote's text.

# 9 · Non-ASCII

Accents éàüñ, symbols → ≠ ≤ ∑ ✓, emoji 🎉 🚀 ✅, and CJK 日本語のテキスト mixed into a line of
Latin prose to show how the faces fall back and whether the line height changes.
