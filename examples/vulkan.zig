//! Interactive 3D Platonic solid viewer rendered with Vulkan (`zig build run-vulkan`).

const std = @import("std");
const facet = @import("facet");
const solids = @import("solids.zig");
const viewer = @import("viewer.zig");

const polyhedron_spv align(4) = @embedFile("polyhedron.spv").*;

pub const VulkanDemo = viewer.Viewer(struct {
    pub const name = "Vulkan";
    pub const Context = facet.gfx.VulkanContext;
    pub const Area = facet.VulkanArea;

    pub fn createPipeline(ctx: *Context) !Context.Pipeline {
        return ctx.createPipeline(.{
            .shader_spv = &polyhedron_spv,
            .vertex_stride = @sizeOf(solids.Vertex),
            .attributes = &viewer.vertex_attributes,
        });
    }

    pub fn finish(ctx: *Context) void {
        _ = ctx.vk.DeviceWaitIdle(ctx.device);
    }
});

pub fn main(init: std.process.Init) !void {
    try viewer.run(init, "Facet Vulkan 3D Widget", VulkanDemo{});
}
