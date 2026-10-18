//! 2D graphics for Facet's widget toolkit: anti-aliased rectangles with
//! rounded corners (and circles), polygons and polylines, filled or stroked,
//! text from a glyph `Atlas`, and images, blended source-over.
//!
//! A `Canvas` records shapes and text into batches on the CPU, independent of
//! the rendering backend. A `Renderer` draws those batches using one of the
//! built-in backends (`software`, `opengl`, `vulkan`) or a custom backend
//! implementing `Renderer.of(&my_backend)`.
//!
//!     canvas.begin(width, height);
//!     canvas.fillRoundedRect(.{ .x = 16, .y = 16, .w = 200, .h = 56 }, .all(28), .rgb(0x6750a4));
//!     canvas.strokePolyline(&points, false, 2, .rgb(0x1d1b20));
//!     _ = canvas.drawText(&atlas, .{ .font = &fira, .size = 16 }, 16, 120, "Hello", .rgb(0x1d1b20));
//!     try software.renderCanvas(&canvas, img);

pub const geometry = @import("geometry.zig");
pub const atlas = @import("atlas.zig");
pub const shaders = @import("shaders.zig");
pub const canvas = @import("canvas.zig");
pub const renderer = @import("renderer.zig");
pub const software = @import("software.zig");
pub const preview = software;
pub const opengl = @import("opengl.zig");
pub const vulkan = @import("vulkan.zig");
pub const png = @import("png.zig");

pub const Canvas = canvas.Canvas;
pub const Image = canvas.Image;
pub const Color = canvas.Color;
pub const Rect = canvas.Rect;
pub const Radii = canvas.Radii;
pub const Point = canvas.Point;
pub const Atlas = atlas.Atlas;
pub const Record = canvas.Record;

pub const Viewport = renderer.Viewport;
pub const GpuArea = renderer.GpuArea;
pub const GpuDraw = renderer.GpuDraw;
pub const Segment = renderer.Segment;
pub const Renderer = renderer.Renderer;
pub const SoftwareRenderer = software.SoftwareRenderer;
pub const OpenGlRenderer = opengl.OpenGlRenderer;
pub const OpenGlContext = opengl.OffscreenContext;
pub const VulkanRenderer = vulkan.VulkanRenderer;
pub const VulkanContext = vulkan.OffscreenContext;

test {
    _ = geometry;
    _ = atlas;
    _ = shaders;
    _ = canvas;
    _ = renderer;
    _ = software;
    _ = opengl;
    _ = vulkan;
    _ = png;
}
