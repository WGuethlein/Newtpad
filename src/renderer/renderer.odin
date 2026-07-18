// Layer: renderer — the CPU-side builder that turns UI/text intent into a flat
// list of quads, then hands them to the platform quad pipeline to draw.
// It owns glyph-atlas *packing* and layout math, not the GPU device: per the
// layer rule, all D3D11/COM lives in platform (see platform/quads.odin). This
// package deals in plain-data quads only and never touches COM.
//
// Empty for now; arrives with the glyph atlas and text layout.
package renderer
