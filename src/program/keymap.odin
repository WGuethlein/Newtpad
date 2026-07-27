// Layer: program -- the user keymap overlay (%APPDATA%\Newtpad\keys.txt).
//
// CLAUDE.md: "Rebindable keys are a runtime user-keymap overlay, not codegen."
// commands.odin has held the two halves apart since the tabs batch -- the
// `[Command_Id]Command` metadata table and the separate `default_bindings`
// keymap, split "so keys are rebindable later (a user overlay)". This file is
// that overlay, and nothing more: it parses a text file into `[]Binding` rows,
// and `lookup_binding` consults them before the defaults.
//
// The whole design goal is that NO CONTENT OF THIS FILE CAN MAKE NEWTPAD
// UNUSABLE. Four separate rules carry that, and each one is here because the
// alternative has a concrete way to trap the user:
//
//   1. The file binds the .Editor context ONLY. There is deliberately no
//      context column. Find, the palette, the menus, the settings page and the
//      font page keep their own keys, so no line in this file can take away the
//      Escape that closes a modal surface -- which is the one failure that can
//      strand someone with an unsaved buffer and no route to Save.
//      Widening a format later is easy; narrowing one is not.
//
//   2. Three chords are reserved and cannot be bound OR unbound (see
//      keymap_reserved). They are the way back out of a bad file.
//
//   3. A chord with neither Ctrl nor Alt on a printable key (letters, digits,
//      + and -) is refused. WM_CHAR is drained independently of the key events
//      (main.odin: window.chars, then window.key_events), so `a = Exit` would
//      both type an "a" and quit -- every time. That is not a binding the user
//      can be assumed to have wanted.
//
//   4. Shift is NOT part of a chord. `Binding` is (key, ctrl, alt, ctx) and no
//      command distinguishes on shift; the actions that care read ev.shift
//      themselves (selection extend, search direction). So `ctrl+shift+k` is
//      REFUSED rather than silently bound to ctrl+k -- binding a chord the user
//      did not write is worse than binding nothing.
//
// And the escape hatch for everything the four rules do not catch: delete
// keys.txt. That sentence is in the seeded header of the file itself, because
// someone whose keymap is broken cannot read documentation from inside the app.
package main

import "core:fmt"
import "core:os"
import "core:strings"
import base "src:base"
import plat "src:platform"

// The name of every key, in both directions: the seed writer formats chords
// with it and the parser matches against it.
//
// A TOTAL enumerated array over plat.Key, not a switch, for the same reason
// theme_role_keys is one: Odin rejects an incomplete keyed enumerated-array
// literal at compile time, so a key added to plat.Key without a name here is a
// build error rather than a key that silently cannot be typed into keys.txt.
// (The switch this replaced would have returned "" for it, and the chord would
// have formatted as "ctrl+".)
//
// These strings are also what the menus and the palette show, via
// command_chord, so they are display names first: "PgUp", not "page_up". The
// parser folds case, so a file may spell them however it likes.
key_names := [plat.Key]string {
	.None      = "",
	.A         = "A",
	.B         = "B",
	.C         = "C",
	.D         = "D",
	.E         = "E",
	.F         = "F",
	.G         = "G",
	.H         = "H",
	.I         = "I",
	.J         = "J",
	.K         = "K",
	.L         = "L",
	.M         = "M",
	.N         = "N",
	.O         = "O",
	.P         = "P",
	.Q         = "Q",
	.R         = "R",
	.S         = "S",
	.T         = "T",
	.U         = "U",
	.V         = "V",
	.W         = "W",
	.X         = "X",
	.Y         = "Y",
	.Z         = "Z",
	.Num0      = "0",
	.Num1      = "1",
	.Num2      = "2",
	.Num3      = "3",
	.Num4      = "4",
	.Num5      = "5",
	.Num6      = "6",
	.Num7      = "7",
	.Num8      = "8",
	.Num9      = "9",
	.Left      = "Left",
	.Right     = "Right",
	.Up        = "Up",
	.Down      = "Down",
	.Home      = "Home",
	.End       = "End",
	.Page_Up   = "PgUp",
	.Page_Down = "PgDn",
	.Backspace = "Backspace",
	.Delete    = "Del",
	.Enter     = "Enter",
	.Tab       = "Tab",
	.Escape    = "Esc",
	.Plus      = "+",
	.Minus     = "-",
}

// Display name for a key, "" for .None. Used by command_chord (commands.odin)
// and by the keys.txt seed writer, so the shortcut a menu teaches and the
// chord the file accepts are the same string by construction.
key_name :: proc(k: plat.Key) -> string {
	return key_names[k]
}

// The inverse, case-insensitive. .None is not matchable -- it has no name, and
// an empty key token is a malformed chord, not "the null key".
key_from_name :: proc(s: string) -> (plat.Key, bool) {
	if s == "" {return .None, false}
	for name, k in key_names {
		if k == .None {continue}
		if strings.equal_fold(name, s) {return k, true}
	}
	return .None, false
}

// A key that also arrives as a typed character. WM_CHAR filters to r >= 32
// (window.odin), so Enter/Tab/Backspace/Escape are NOT in this set even though
// they have ASCII codes -- they never reach window.chars, and binding them is
// the ordinary case rather than the footgun rule 3 refuses.
@(private = "file")
key_is_printable :: proc(k: plat.Key) -> bool {
	return(
		(k >= .A && k <= .Z) ||
		(k >= .Num0 && k <= .Num9) ||
		k == .Plus ||
		k == .Minus \
	)
}

// The chords keys.txt may not touch, in either direction (rebind or unbind).
// DECIDED, not discovered -- the criterion is "is this the way back from a
// broken keymap, or is losing it a data-loss path?", and only three chords
// answer yes:
//
//   Esc     the universal cancel. It is what someone tries first when the app
//           stops responding to their keys, and it is Clear_Selection here.
//   Ctrl+S  losing Save is a data-loss path, not an inconvenience: the user
//           types, presses Ctrl+S, sees nothing happen (a save prints no
//           dialog), and closes the tab.
//   Ctrl+P  the command palette -- product principle 2's "universal access
//           point". While it opens, EVERY command is still reachable,
//           including View > Edit Keybindings..., so it is the in-app repair
//           route that does not require finding the file on disk.
//
// Nothing else qualifies. Ctrl+C/V/Z are not recovery routes and rebinding
// them is a legitimate (if strange) choice; the menu bar is opened by a bare
// Alt tap in main.odin, not by a Binding, so it cannot be taken away by this
// file at all.
keymap_chord_reserved :: proc(key: plat.Key, ctrl, alt: bool) -> bool {
	if alt {return false}
	if key == .Escape && !ctrl {return true}
	if ctrl && (key == .S || key == .P) {return true}
	return false
}

// Why a line was thrown away. Counted rather than collected so the parse stays
// allocation-light and so keymaptest can assert on the exact reason -- "the
// line was ignored" is not the same claim as "the line was ignored BECAUSE it
// named shift", and the shift case is the one that must not become a silent
// ctrl-only binding.
Keymap_Reject :: enum u8 {
	Malformed, // no '=', an empty chord, or modifiers with no key ("ctrl+")
	Unknown_Key, // "ctrl+foo"
	Shift, // "ctrl+shift+k" -- see rule 4 in the file header
	Unmodified, // "k" -- see rule 3
	Reserved, // "ctrl+s" -- see keymap_reserved
	Unknown_Command, // "ctrl+k = Frobnicate"
}

// A parsed keys.txt. `entries` are all .Editor rows; cmd == .None means the
// line UNBOUND the chord, which is distinct from "no entry" -- see
// keymap_lookup's second return value.
Keymap :: struct {
	entries: [dynamic]Binding,
	rejects: [Keymap_Reject]int,
}

keymap_destroy :: proc(km: ^Keymap) {
	delete(km.entries)
	km^ = {}
}

// The active overlay. Empty until keymap_load runs, and an empty overlay makes
// every lookup fall straight through to default_bindings, so every path here
// is a no-op on a machine with no keys.txt.
g_keymap: Keymap

// Replace the overlay, freeing the old one. Takes ownership of `km.entries`.
keymap_install :: proc(km: Keymap) {
	keymap_destroy(&g_keymap)
	g_keymap = km
}

keymap_reset :: proc() {
	keymap_destroy(&g_keymap)
}

// The overlay's answer for a chord, and whether it had one.
//
// The bool is the whole point: an entry whose cmd is .None means the user
// UNBOUND this chord, and that must stop the fall-through to default_bindings.
// Returning just .None would have made an unbind indistinguishable from "not
// mentioned", i.e. would have made unbinding impossible.
//
// Scanned in REVERSE so the last matching line in the file wins. Stated in the
// seeded header and chosen deliberately -- with a forward scan the winner would
// be an artifact of iteration order, and the user's mental model of a config
// file is that a later line corrects an earlier one.
//
// Non-.Editor contexts are never touched (rule 1).
keymap_lookup :: proc(key: plat.Key, ctrl, alt: bool, ctx: Ctx) -> (Command_Id, bool) {
	if ctx != .Editor || len(g_keymap.entries) == 0 {
		return .None, false
	}
	#reverse for e in g_keymap.entries {
		if e.key == key && e.ctrl == ctrl && e.alt == alt {
			return e.cmd, true
		}
	}
	return .None, false
}

// Command_Id from its enum name, case-insensitively. .None is excluded on
// purpose: "unbind" is spelled by leaving the right-hand side EMPTY, and
// accepting a second spelling for it would mean two ways to say one thing
// (principle 3) and a name in the file that matches no row in the seeded list.
command_from_name :: proc(s: string) -> (Command_Id, bool) {
	if s == "" {return .None, false}
	for cmd in Command_Id {
		if cmd == .None {continue}
		if strings.equal_fold(fmt.tprintf("%v", cmd), s) {return cmd, true}
	}
	return .None, false
}

// Drop the whitespace that only pads a '+'. "ctrl + shift + k" is the same
// chord a user means by "ctrl+shift+k", and it should get the same answer --
// "shift is not part of a chord" -- rather than being blamed on an unknown key
// named "ctrl + shift + k". Both are refusals; only one of them tells the user
// what to change.
//
// Only whitespace ADJACENT to a '+' is dropped, not all of it. Key names come
// from key_names, the one table the seed writer also formats with, and a name
// there could legitimately contain a space one day ("Num Lock"); squeezing
// everything would make such a name unmatchable while the writer kept emitting
// it. Returns the input untouched when there is no whitespace to remove, which
// is every well-formed line.
@(private = "file")
chord_squeeze :: proc(s: string, allocator := context.temp_allocator) -> string {
	if strings.index_byte(s, ' ') < 0 && strings.index_byte(s, '\t') < 0 {return s}
	b := strings.builder_make(allocator)
	space :: proc(c: byte) -> bool {return c == ' ' || c == '\t'}
	for i in 0 ..< len(s) {
		if space(s[i]) {
			p := i - 1
			for p >= 0 && space(s[p]) {p -= 1}
			n := i + 1
			for n < len(s) && space(s[n]) {n += 1}
			if (p >= 0 && s[p] == '+') || (n < len(s) && s[n] == '+') {continue}
		}
		strings.write_byte(&b, s[i])
	}
	return strings.to_string(b)
}

// PURE over the file's bytes: no window, no globals, no disk. That is what
// lets keymaptest drive every case headlessly, and it is the reason the load
// path is split into parse + install rather than one read_and_apply.
//
// Nothing here is fatal. A line that cannot be understood is counted, logged
// and skipped, exactly as settings.txt and the theme files treat an
// unrecognized key -- that tolerance is why an old build can read a file a new
// one wrote.
keymap_parse :: proc(src: string, allocator := context.allocator) -> Keymap {
	km: Keymap
	km.entries = make([dynamic]Binding, allocator)

	for raw_line, line_no in strings.split_lines(src, context.temp_allocator) {
		line := strings.trim_space(raw_line)
		if line == "" || line[0] == '#' {continue}

		eq := strings.index_byte(line, '=')
		if eq < 0 {
			km.rejects[.Malformed] += 1
			base.log_warn("keys.txt:%d: no '=' in %q -- expected `chord = Command`", line_no + 1, line)
			continue
		}
		lhs := strings.trim_space(line[:eq])
		rhs := strings.trim_space(line[eq + 1:])
		if lhs == "" {
			km.rejects[.Malformed] += 1
			base.log_warn("keys.txt:%d: no chord before '=' in %q", line_no + 1, line)
			continue
		}

		// Modifier prefixes are stripped one at a time rather than splitting on
		// '+', because the key itself can BE '+' or '-': splitting "ctrl++"
		// yields ["ctrl", "", ""] and loses the key.
		//
		// The prefixes are consumed even when nothing follows (>=, not >), so
		// "ctrl+" arrives at the empty-key check below as a chord with no key
		// rather than as the unknown key "ctrl+". Both are refused either way;
		// the point is that the warning names the problem the user has.
		rest := chord_squeeze(lhs)
		ctrl, alt, shift := false, false, false
		for {
			if len(rest) >= 5 && strings.equal_fold(rest[:5], "ctrl+") {
				ctrl = true
				rest = rest[5:]
				continue
			}
			if len(rest) >= 4 && strings.equal_fold(rest[:4], "alt+") {
				alt = true
				rest = rest[4:]
				continue
			}
			if len(rest) >= 6 && strings.equal_fold(rest[:6], "shift+") {
				shift = true
				rest = rest[6:]
				continue
			}
			break
		}

		// Modifiers and nothing else. Malformed rather than Shift even when
		// shift was one of them: the line has no key at all, which is the more
		// basic thing to say, and it is the same fault as the empty chord above.
		if rest == "" {
			km.rejects[.Malformed] += 1
			base.log_warn("keys.txt:%d: %q refused -- there is no key after the modifiers", line_no + 1, lhs)
			continue
		}

		// Checked before the key name, so `ctrl+shift+k` reports the real
		// problem (shift is not bindable) instead of blaming the key.
		if shift {
			km.rejects[.Shift] += 1
			base.log_warn(
				"keys.txt:%d: %q refused -- shift is not part of a chord in Newtpad; commands that care about shift read it themselves",
				line_no + 1,
				lhs,
			)
			continue
		}

		key, kok := key_from_name(rest)
		if !kok {
			km.rejects[.Unknown_Key] += 1
			base.log_warn("keys.txt:%d: unknown key %q in %q", line_no + 1, rest, lhs)
			continue
		}
		if !ctrl && !alt && key_is_printable(key) {
			km.rejects[.Unmodified] += 1
			base.log_warn(
				"keys.txt:%d: %q refused -- an unmodified %q also types that character, so the command would run every time you typed it",
				line_no + 1,
				lhs,
				key_name(key),
			)
			continue
		}
		if keymap_chord_reserved(key, ctrl, alt) {
			km.rejects[.Reserved] += 1
			base.log_warn("keys.txt:%d: %q refused -- Esc, Ctrl+S and Ctrl+P are reserved as the way back from a broken keymap", line_no + 1, lhs)
			continue
		}

		// Empty right-hand side unbinds. Recorded as an entry with .None so the
		// lookup can tell it apart from a chord the file never mentions.
		if rhs == "" {
			append(&km.entries, Binding{key, ctrl, alt, .Editor, .None})
			continue
		}
		cmd, cok := command_from_name(rhs)
		if !cok {
			km.rejects[.Unknown_Command] += 1
			base.log_warn("keys.txt:%d: unknown command %q", line_no + 1, rhs)
			continue
		}
		append(&km.entries, Binding{key, ctrl, alt, .Editor, cmd})
	}
	return km
}

keymap_reject_total :: proc(km: Keymap) -> (n: int) {
	for c in km.rejects {n += c}
	return
}

// %APPDATA%\Newtpad\keys.txt -- sibling of settings.txt and session.txt under
// the same session_dir(), so NEWTPAD_SESSION_DIR redirects this too and the
// headless modes never touch the real store.
keymap_path :: proc() -> (string, bool) {
	dir, ok := session_dir()
	if !ok {
		return "", false
	}
	return fmt.tprintf("%s%ckeys.txt", dir, '\\'), true
}

// Read keys.txt (if there is one) and make it the active overlay. A missing
// file, an unreadable one, or one made entirely of garbage all leave the
// defaults in force -- keymap_parse returns an empty entry list and every
// lookup falls through.
keymap_load :: proc() {
	path, ok := keymap_path()
	if !ok {return}
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil {
		keymap_reset()
		return
	}
	km := keymap_parse(string(data))
	n := keymap_reject_total(km)
	if len(km.entries) > 0 || n > 0 {
		base.log_info("keys.txt: %d binding(s), %d line(s) refused", len(km.entries), n)
	}
	keymap_install(km)
}

// Re-read keys.txt if `path` names it. The mirror of theme_reapply_if_active:
// called after a successful save and after the external-change watcher reloads
// a document, so editing the keymap inside Newtpad takes effect on the next
// keystroke without a restart. That loop is the whole point of the menu row --
// without it, testing a binding means restarting the app.
//
// The compare normalises both sides for the same reason theme's does: doc.path
// can arrive from the Save dialog, from argv or from an Explorer drop, and can
// name the same file with different case and separators than the one built
// from session_dir().
keymap_reload_if_active :: proc(path: string) -> bool {
	kp, ok := keymap_path()
	if !ok || path == "" {
		return false
	}
	norm :: proc(s: string) -> string {
		fwd, _ := strings.replace_all(s, "\\", "/", context.temp_allocator)
		return strings.to_lower(fwd, context.temp_allocator)
	}
	if norm(path) != norm(kp) {
		return false
	}
	keymap_load()
	return true
}

// The chord half of a keys.txt line, lowercased: "ctrl+alt+s", "alt+up", "-".
@(private = "file")
keymap_chord_text :: proc(b: Binding, allocator := context.temp_allocator) -> string {
	parts: [3]string
	n := 0
	if b.ctrl {parts[n] = "ctrl+";n += 1}
	if b.alt {parts[n] = "alt+";n += 1}
	parts[n] = strings.to_lower(key_name(b.key), context.temp_allocator)
	n += 1
	return strings.concatenate(parts[:n], allocator)
}

// The file Newtpad writes when there isn't one: a header that has to work for
// someone whose keymap is already broken (hence the DELETE THIS FILE line),
// followed by every default editor binding commented out, so the file is also
// the reference for what the names are. There is no other place in the product
// that lists them.
keymap_seed_text :: proc(allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	w :: proc(b: ^strings.Builder, s: string) {strings.write_string(b, s)}
	w(&b, "# Newtpad keybindings. Restart is not needed -- saving this file re-reads it.\n")
	w(&b, "#\n")
	w(&b, "# One binding per line:\n")
	w(&b, "#\n")
	w(&b, "#     chord = Command\n")
	w(&b, "#\n")
	w(&b, "#   chord    [ctrl+][alt+]key   e.g.  ctrl+k   alt+up   ctrl+alt+s   pgdn\n")
	w(&b, "#   Command  one of the names listed below. Leave it EMPTY to unbind the\n")
	w(&b, "#            chord entirely:   alt+up =\n")
	w(&b, "#\n")
	w(&b, "# Case does not matter. Lines starting with # are comments.\n")
	w(&b, "# If the same chord appears twice, THE LAST LINE WINS.\n")
	w(&b, "# A line that cannot be understood is ignored and noted in the log\n")
	w(&b, "# (View > Open Logs Folder). Nothing in this file is ever fatal.\n")
	w(&b, "#\n")
	w(&b, "# --- four things this file deliberately will not let you do ---------------\n")
	w(&b, "#\n")
	w(&b, "# 1. SHIFT IS NOT PART OF A CHORD.  `ctrl+shift+k = ...` is refused, not\n")
	w(&b, "#    quietly turned into ctrl+k. Commands that care about shift read it\n")
	w(&b, "#    themselves -- shift+arrow extends a selection, shift+Enter searches\n")
	w(&b, "#    backwards -- so there is nothing to bind.\n")
	w(&b, "#\n")
	w(&b, "# 2. THIS FILE BINDS THE EDITOR ONLY.  The find bar, the command palette,\n")
	w(&b, "#    the menus, the settings page and the font page keep their own keys, so\n")
	w(&b, "#    nothing you write here can trap you inside one of them with unsaved\n")
	w(&b, "#    work and no way to reach Save.\n")
	w(&b, "#\n")
	w(&b, "# 3. RESERVED CHORDS.  Esc, Ctrl+S and Ctrl+P cannot be rebound or unbound.\n")
	w(&b, "#    They are the way back from a keymap you did not mean: cancel, save your\n")
	w(&b, "#    work, and open the command palette -- which can still run every command\n")
	w(&b, "#    including View > Edit Keybindings...\n")
	w(&b, "#\n")
	w(&b, "# 4. NO UNMODIFIED LETTERS, DIGITS, + OR -.  `k = Undo` is refused: the\n")
	w(&b, "#    character is typed independently of the keymap, so the command would\n")
	w(&b, "#    also run every time you typed a k. Add ctrl+ or alt+.\n")
	w(&b, "#\n")
	w(&b, "# --- LOST? -----------------------------------------------------------------\n")
	w(&b, "#\n")
	w(&b, "# DELETE THIS FILE (keys.txt, next to settings.txt) AND RESTART NEWTPAD.\n")
	w(&b, "# That restores every built-in key. Nothing else in Newtpad depends on it.\n")
	w(&b, "#\n")
	w(&b, "# --- the built-in editor keys, all commented out ---------------------------\n")
	w(&b, "#\n")
	w(&b, "# Uncomment a line and change it to rebind. The three reserved chords above\n")
	w(&b, "# are not listed, because they cannot be changed.\n")
	w(&b, "#\n")
	for bind in default_bindings {
		if bind.ctx != .Editor {continue}
		if keymap_chord_reserved(bind.key, bind.ctrl, bind.alt) {continue}
		strings.write_string(&b, fmt.tprintf("# %-14s = %v\n", keymap_chord_text(bind), bind.cmd))
	}
	w(&b, "#\n")
	w(&b, "# --- commands with no default editor key -----------------------------------\n")
	w(&b, "#\n")
	w(&b, "# Names only -- give any of them a chord of your own, e.g.\n")
	w(&b, "#\n")
	w(&b, "#     ctrl+alt+o = Open_Link\n")
	w(&b, "#\n")
	for cmd in Command_Id {
		if cmd == .None || !command_in_palette(cmd) {continue}
		bound := false
		for bind in default_bindings {
			if bind.ctx == .Editor && bind.cmd == cmd {
				bound = true
				break
			}
		}
		if bound {continue}
		strings.write_string(&b, fmt.tprintf("#     %v\n", cmd))
	}
	return strings.to_string(b)
}

// Edit Keybindings: writes the seeded file if there isn't one, then opens it as
// a tab -- the same loop Edit Current Theme... gives the theme, and for the same
// reason. A documented file format nobody has a file for is not a feature; a
// file the app writes for you, with every default in it, is.
//
// An existing file is never overwritten: the user's bindings are the thing this
// command exists to let them edit. Saving it re-reads it (keymap_reload_if_active
// via save_checked), so a binding can be tried without restarting.
keymap_edit_current :: proc(app: ^App) -> bool {
	path, ok := keymap_path()
	if !ok {
		app_note(app, "[KEYS.TXT NOT AVAILABLE - the settings folder could not be found]")
		return false
	}
	if !os.exists(path) {
		seed := keymap_seed_text(context.temp_allocator)
		if os.write_entire_file(path, transmute([]u8)seed) != nil {
			app_note(app, "[KEYS.TXT NOT WRITTEN - could not write to the settings folder]")
			return false
		}
	}
	app_open_path(app, path)
	return true
}
