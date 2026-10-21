//! Interactive 3D Platonic solid viewer rendered with Direct3D 11, on Windows (`zig build run-d3d11`).

const std = @import("std");
const facet = @import("facet");
const solids = @import("solids.zig");
const viewer = @import("viewer.zig");

pub const D3D11Demo = viewer.Viewer(struct {
    pub const name = "Direct3D 11";
    pub const Context = facet.D3D11Context;
    pub const Area = facet.D3D11Area;

    pub fn createPipeline(ctx: *Context) !Context.Pipeline {
        return ctx.createPipeline(.{
            .vertex = @embedFile("polyhedron_vs.dxbc"),
            .pixel = @embedFile("polyhedron_ps.dxbc"),
            .vertex_stride = @sizeOf(solids.Vertex),
            .attributes = &viewer.vertex_attributes,
        });
    }

    pub fn finish(ctx: *Context) void {
        ctx.waitIdle();
    }
});

pub fn main(init: std.process.Init) !void {
    try viewer.run(init, "Facet Direct3D 11 3D Widget", D3D11Demo{});
}
