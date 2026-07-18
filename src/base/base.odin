// Layer: base — fundamental types, arena allocators, strings.
// The bottom of the dependency stack: base -> platform -> renderer -> ui -> program.
// base depends on nothing above it and never touches Win32/COM.
//
// Empty for now; populated when we introduce arenas (VirtualAlloc-backed,
// grouped lifetimes) and the UTF-8 string helpers.
package base
