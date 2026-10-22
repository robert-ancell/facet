//! Interactive 3D Platonic solid viewer rendered with OpenGL (`zig build run-opengl`).

const std = @import("std");
const facet = @import("facet");
const solids = @import("solids.zig");
const viewer = @import("viewer.zig");

const polyhedron_spv align(4) = @embedFile("polyhedron.spv").*;

pub const OpenGlDemo = viewer.Viewer(struct {
    pub const name = "OpenGL";
    pub const Context = facet.gfx.OpenGlContext;
    pub const Area = facet.OpenGlArea;

    pub fn createPipeline(ctx: *Context) !Context.Pipeline {
        return ctx.createPipeline(.{
            .shader_spv = if (ctx.supportsSpirv()) &polyhedron_spv else null,
            .vs_source = @embedFile("shaders/polyhedron.vert"),
            .fs_source = @embedFile("shaders/polyhedron.frag"),
            .vertex_stride = @sizeOf(solids.Vertex),
            .attributes = &viewer.vertex_attributes,
        });
    }
});

pub fn main(init: std.process.Init) !void {
    try viewer.run(init, "Facet OpenGL 3D Widget", OpenGlDemo{});
}
