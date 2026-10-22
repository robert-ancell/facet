//! Interactive 3D Platonic solid viewer rendered with Metal, on macOS (`zig build run-metal`).

const std = @import("std");
const facet = @import("facet");
const solids = @import("solids.zig");
const viewer = @import("viewer.zig");

pub const MetalDemo = viewer.Viewer(struct {
    pub const name = "Metal";
    pub const Context = facet.gfx.MetalContext;
    pub const Area = facet.MetalArea;

    pub fn createPipeline(ctx: *Context) !Context.Pipeline {
        return ctx.createPipeline(.{
            .source = @embedFile("shaders/polyhedron.metal"),
            .vertex_stride = @sizeOf(solids.Vertex),
            .attributes = &viewer.vertex_attributes,
        });
    }

    pub fn finish(ctx: *Context) void {
        ctx.waitIdle();
    }
});

pub fn main(init: std.process.Init) !void {
    try viewer.run(init, "Facet Metal 3D Widget", MetalDemo{});
}
