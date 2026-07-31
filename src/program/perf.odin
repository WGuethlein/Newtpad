// Layer: program -- TEMPORARY startup/shutdown instrumentation.
//
// Added 2026-07-31 to investigate "startup and shutdown are no longer snappy,
// with a white flash" (docs/reported-bugs.md). It exists because the two phases
// have to be timed SEPARATELY -- one combined number hides which half is broken
// -- and because the shipped exe is GUI-subsystem, so there is no console to
// print to. Marks go to a file named by NEWTPAD_PERF; with the variable unset
// every proc here is an atomic load and a return.
//
// Deliberately allocation-free on the hot path: names are string literals, the
// mark array is fixed, and nothing is formatted until perf_dump.
package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"

PERF_MAX :: 128

@(private = "file")
Perf_Mark :: struct {
	name: string, // literal
	at:   time.Tick,
}

@(private = "file")
Perf :: struct {
	on:    bool,
	path:  string, // owned
	t0:    time.Tick,
	marks: [PERF_MAX]Perf_Mark,
	n:     int,
}

@(private = "file")
g_perf: Perf

// Call FIRST in main, before anything that could be timed.
perf_init :: proc() {
	p := os.get_env("NEWTPAD_PERF", context.allocator)
	if p == "" {
		delete(p)
		return
	}
	g_perf.on = true
	g_perf.path = p
	g_perf.t0 = time.tick_now()
}

perf_mark :: proc(name: string) {
	if !g_perf.on || g_perf.n >= PERF_MAX {return}
	g_perf.marks[g_perf.n] = {name, time.tick_now()}
	g_perf.n += 1
}

// Write the timeline. Registered as the FIRST defer in main so LIFO runs it
// LAST -- after every teardown proc it is meant to have timed.
perf_dump :: proc() {
	if !g_perf.on {return}
	// Runs last of all the defers, so this row bounds whatever teardown ran
	// after the final mark (today: diag_shutdown).
	perf_mark("exit: diag_shutdown done")
	b: strings.Builder
	strings.builder_init(&b)
	defer strings.builder_destroy(&b)
	prev := g_perf.t0
	fmt.sbprintfln(&b, "%-34s %10s %10s", "mark", "delta_ms", "since0_ms")
	for i in 0 ..< g_perf.n {
		m := g_perf.marks[i]
		fmt.sbprintfln(
			&b,
			"%-34s %10.2f %10.2f",
			m.name,
			time.duration_milliseconds(time.tick_diff(prev, m.at)),
			time.duration_milliseconds(time.tick_diff(g_perf.t0, m.at)),
		)
		prev = m.at
	}
	_ = os.write_entire_file(g_perf.path, transmute([]u8)strings.to_string(b))
	delete(g_perf.path)
	g_perf.on = false
}
