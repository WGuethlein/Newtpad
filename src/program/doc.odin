// Layer: program — a read-only document view: file bytes (mapped or copied),
// decoded to UTF-8, a byte-offset viewport that walks lines on demand, and a
// background line index (sparse anchors) for exact scrollbar + goto-line.
package main

import "base:intrinsics"
import "core:thread"
import base "src:base"
import plat "src:platform"

ANCHOR_STRIDE :: 1024 // record a line-start offset every N lines

// Background line index. The worker reads the immutable content bytes, counts
// lines, and records a sparse anchor every ANCHOR_STRIDE lines. All cross-thread
// fields are touched only via atomics; anchors[] is pre-sized so it never
// reallocates, and the worker only ever appends, so the main thread reads
// committed entries (index < anchor_count) without a lock.
Line_Index :: struct {
	content:      []u8,
	anchors:      []int, // anchors[i] = byte offset of line i*ANCHOR_STRIDE
	anchor_count: int, // atomic
	line_count:   int, // atomic (total lines seen so far)
	indexed:      int, // atomic (bytes scanned so far)
	total:        int, // const
	done:         bool, // atomic
	cancel:       bool, // atomic
	th:           ^thread.Thread,
}

Document :: struct {
	fv:       plat.File_View,
	content:  []u8, // UTF-8
	owned:    bool,
	enc:      base.Encoding,
	top:      int, // byte offset of the top visible line (a line start)
	top_line: int, // line number of the top visible line
	idx:      Line_Index,
}

doc_open :: proc(path: string) -> (doc: Document, ok: bool) {
	fv, fok := plat.file_open_readonly(path)
	if !fok {
		return
	}
	doc.fv = fv
	enc, bom := base.detect_encoding(fv.bytes)
	doc.enc = enc
	doc.content, doc.owned = base.decode_to_utf8(fv.bytes, enc, bom)

	// set up the index (bytes + anchor storage); the worker starts separately,
	// once the Document is at its final address (see doc_index_start).
	doc.idx.content = doc.content
	doc.idx.total = len(doc.content)
	// worst-realistic anchors: assume >= 8 bytes/line; guard overflow in the worker
	n_anchors := len(doc.content) / (8 * ANCHOR_STRIDE) + 16
	doc.idx.anchors = make([]int, n_anchors)
	doc.idx.anchor_count = 1
	return doc, true
}

// Start the background line-index worker. Call AFTER the Document is in its final
// location — the worker holds &doc.idx, which must not move.
doc_index_start :: proc(doc: ^Document) {
	doc.idx.content = doc.content // rebind in case content moved with the Document
	doc.idx.th = thread.create_and_start_with_data(&doc.idx, index_worker)
}

doc_close :: proc(doc: ^Document) {
	if doc.idx.th != nil {
		intrinsics.atomic_store(&doc.idx.cancel, true)
		thread.join(doc.idx.th)
		thread.destroy(doc.idx.th)
	}
	delete(doc.idx.anchors)
	if doc.owned {
		delete(doc.content)
	}
	plat.file_close(&doc.fv)
}

@(private = "file")
index_worker :: proc(data: rawptr) {
	idx := (^Line_Index)(data)
	c := idx.content
	line := 0
	i := 0
	for i < len(c) {
		if i & 0xFFFFF == 0 { // ~every 1 MB: publish progress + poll cancel
			if intrinsics.atomic_load(&idx.cancel) {
				return
			}
			intrinsics.atomic_store(&idx.indexed, i)
			intrinsics.atomic_store(&idx.line_count, line + 1)
		}
		if c[i] == '\n' {
			line += 1
			if line % ANCHOR_STRIDE == 0 {
				ai := line / ANCHOR_STRIDE
				if ai < len(idx.anchors) {
					idx.anchors[ai] = i + 1
					intrinsics.atomic_store(&idx.anchor_count, ai + 1)
				}
			}
		}
		i += 1
	}
	intrinsics.atomic_store(&idx.line_count, line + 1) // last line may be unterminated
	intrinsics.atomic_store(&idx.indexed, len(c))
	intrinsics.atomic_store(&idx.done, true)
}

doc_line_count :: proc(doc: ^Document) -> int {return intrinsics.atomic_load(&doc.idx.line_count)}
doc_index_done :: proc(doc: ^Document) -> bool {return intrinsics.atomic_load(&doc.idx.done)}
doc_index_progress :: proc(doc: ^Document) -> f32 {
	if doc.idx.total == 0 {
		return 1
	}
	return f32(intrinsics.atomic_load(&doc.idx.indexed)) / f32(doc.idx.total)
}

doc_scroll :: proc(doc: ^Document, delta: int) {
	if delta > 0 {
		for _ in 0 ..< delta {
			nt := base.next_line_start(doc.content, doc.top)
			if nt == doc.top {break}
			doc.top = nt
			doc.top_line += 1
		}
	} else if delta < 0 {
		for _ in 0 ..< -delta {
			if doc.top == 0 {break}
			doc.top = base.prev_line_start(doc.content, doc.top)
			doc.top_line -= 1
		}
	}
}

// Jump to line n using the sparse index: land on the nearest anchor <= n, then
// scan forward the remainder (< ANCHOR_STRIDE lines). Falls back to scanning
// from the top if that region isn't indexed yet.
doc_goto_line :: proc(doc: ^Document, n: int) {
	n := max(0, n)
	// Only clamp to the total once the index is complete; a partial count would
	// wrongly clamp toward 0. Otherwise the forward scan self-bounds at EOF.
	if doc_index_done(doc) {
		if lc := doc_line_count(doc); lc > 0 {
			n = min(n, lc - 1)
		}
	}
	ai := n / ANCHOR_STRIDE
	off, base_line := 0, 0
	if ai < intrinsics.atomic_load(&doc.idx.anchor_count) {
		off = doc.idx.anchors[ai]
		base_line = ai * ANCHOR_STRIDE
	}
	for base_line < n {
		nt := base.next_line_start(doc.content, off)
		if nt == off {break}
		off = nt
		base_line += 1
	}
	doc.top = off
	doc.top_line = base_line
}

// Draw the visible lines starting at doc.top through the ClearType pipeline.
doc_draw :: proc(gfx: ^plat.Gfx, t: ^plat.Text, doc: ^Document, px: f32, rows: int) {
	fg := [4]f32{0.86, 0.90, 0.96, 1}
	x: f32 = 12
	line_h := px * 1.5
	y := px + 10

	pos := doc.top
	for _ in 0 ..< rows {
		if pos >= len(doc.content) {
			break
		}
		end := base.line_end(doc.content, pos)
		line := doc.content[pos:end]
		if len(line) > 0 && line[len(line) - 1] == '\r' {
			line = line[:len(line) - 1]
		}
		if len(line) > 2000 {
			line = line[:2000]
		}
		if len(line) > 0 {
			plat.text_draw(gfx, t, string(line), x, y, px, fg)
		}
		y += line_h
		pos = end + 1 if end < len(doc.content) else len(doc.content)
	}
}
