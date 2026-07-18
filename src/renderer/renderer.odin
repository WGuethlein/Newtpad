// Layer: renderer — turns UI intent into GPU work (quads only).
// Consumes a cached alpha glyph atlas and emits instanced quads via the
// platform's D3D11 device. Knows nothing about Win32 windows or UI widgets.
//
// Empty for now; the platform layer currently owns the raw D3D11 device and a
// clear/present path. This package takes over once we add the quad pipeline.
package renderer
