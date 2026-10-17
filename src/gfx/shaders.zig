//! Vertex layouts, SPIR-V shader blobs (for Vulkan), and GLSL shader sources
//! (for OpenGL 3.3 / OpenGL ES 3.0) for Facet's 2D canvas batches:
//!
//! * `shape`: anti-aliased rounded rectangles, filled or stroked. Each
//!   vertex carries the rectangle: the fragment's position relative to its
//!   centre, its half size, corner radius and stroke width, and the colour.
//!   The fragment shader computes the signed distance to the rounded outline
//!   and turns it into coverage over one pixel.
//! * `solid`: triangles with a colour per vertex, for polygons and strokes
//!   whose anti-aliased edges are fringes fading to transparent.
//! * `opaque`: `solid` without blending, for triangles opaque all over
//!   (the insides of filled shapes, the cores of strokes).
//! * `text`: glyphs, their coverage from the single-channel glyph atlas
//!   texture.
//! * `image`: images, from their own RGBA textures (with the text vertices'
//!   layout: a texture position and a colour to tint them with).

const std = @import("std");

/// Floats per shape vertex: clip x, y; then local x, y, half width,
/// half height; radius, stroke width; then r, g, b, a.
pub const shape_floats = 12;
/// Floats per solid vertex: clip x, y; then r, g, b, a.
pub const solid_floats = 6;
/// Floats per text/image vertex: clip x, y; atlas u, v; then r, g, b, a.
pub const text_floats = 8;

pub const Attribute = struct {
    location: u32,
    components: u32,
    offset: u32,
};

pub const Layout = struct {
    vertex_stride: u32,
    attributes: []const Attribute,
};

pub const shape_layout: Layout = .{
    .vertex_stride = shape_floats * 4,
    .attributes = &.{
        .{ .location = 0, .components = 2, .offset = 0 },
        .{ .location = 1, .components = 4, .offset = 8 },
        .{ .location = 2, .components = 2, .offset = 24 },
        .{ .location = 3, .components = 4, .offset = 32 },
    },
};

pub const solid_layout: Layout = .{
    .vertex_stride = solid_floats * 4,
    .attributes = &.{
        .{ .location = 0, .components = 2, .offset = 0 },
        .{ .location = 1, .components = 4, .offset = 8 },
    },
};

pub const text_layout: Layout = .{
    .vertex_stride = text_floats * 4,
    .attributes = &.{
        .{ .location = 0, .components = 2, .offset = 0 },
        .{ .location = 1, .components = 2, .offset = 8 },
        .{ .location = 2, .components = 4, .offset = 16 },
    },
};

// --- SPIR-V shaders (compiled from src/gfx/shaders/*.zig) -------------------

pub const shape_spv align(4) = @embedFile("shape.spv").*;
pub const solid_spv align(4) = @embedFile("solid.spv").*;
pub const text_spv align(4) = @embedFile("text.spv").*;
pub const image_spv align(4) = @embedFile("image.spv").*;

// --- GLSL shaders (OpenGL 3.3 Core / OpenGL ES 3.0) -------------------------

pub const glsl_shape_vs: [:0]const u8 =
    \\#version 330 core
    \\layout(location = 0) in vec2 in_pos;
    \\layout(location = 1) in vec4 in_geometry;
    \\layout(location = 2) in vec2 in_shape;
    \\layout(location = 3) in vec4 in_color;
    \\out vec4 v_geometry;
    \\out vec2 v_shape;
    \\out vec4 v_color;
    \\void main() {
    \\    gl_Position = vec4(in_pos, 0.0, 1.0);
    \\    v_geometry = in_geometry;
    \\    v_shape = in_shape;
    \\    v_color = in_color;
    \\}
;

pub const glsl_shape_fs: [:0]const u8 =
    \\#version 330 core
    \\in vec4 v_geometry;
    \\in vec2 v_shape;
    \\in vec4 v_color;
    \\out vec4 out_color;
    \\float coverage(float d, vec2 sides, float inset) {
    \\    float by_distance = clamp(0.5 - (d + inset), 0.0, 1.0);
    \\    vec2 c = clamp(vec2(0.5) - (sides + vec2(inset)), vec2(0.0), vec2(1.0));
    \\    return min(by_distance, c.x * c.y);
    \\}
    \\void main() {
    \\    vec2 p = v_geometry.xy;
    \\    vec2 half_sz = v_geometry.zw;
    \\    float radius = v_shape.x;
    \\    float stroke = v_shape.y;
    \\    vec2 a = abs(p);
    \\    vec2 q = a - (half_sz - vec2(radius));
    \\    vec2 m = max(q, vec2(0.0));
    \\    float d = length(m) + min(max(q.x, q.y), 0.0) - radius;
    \\    vec2 sides = a - half_sz;
    \\    float cov = coverage(d, sides, 0.0) - coverage(d, sides, stroke);
    \\    out_color = vec4(v_color.rgb, v_color.a * cov);
    \\}
;

pub const glsl_solid_vs: [:0]const u8 =
    \\#version 330 core
    \\layout(location = 0) in vec2 in_pos;
    \\layout(location = 1) in vec4 in_color;
    \\out vec4 v_color;
    \\void main() {
    \\    gl_Position = vec4(in_pos, 0.0, 1.0);
    \\    v_color = in_color;
    \\}
;

pub const glsl_solid_fs: [:0]const u8 =
    \\#version 330 core
    \\in vec4 v_color;
    \\out vec4 out_color;
    \\void main() {
    \\    out_color = v_color;
    \\}
;

pub const glsl_text_vs: [:0]const u8 =
    \\#version 330 core
    \\layout(location = 0) in vec2 in_pos;
    \\layout(location = 1) in vec2 in_uv;
    \\layout(location = 2) in vec4 in_color;
    \\out vec2 v_uv;
    \\out vec4 v_color;
    \\void main() {
    \\    gl_Position = vec4(in_pos, 0.0, 1.0);
    \\    v_uv = in_uv;
    \\    v_color = in_color;
    \\}
;

pub const glsl_text_fs: [:0]const u8 =
    \\#version 330 core
    \\in vec2 v_uv;
    \\in vec4 v_color;
    \\uniform sampler2D u_tex;
    \\out vec4 out_color;
    \\void main() {
    \\    float cov = texture(u_tex, v_uv).r;
    \\    out_color = vec4(v_color.rgb, v_color.a * cov);
    \\}
;

pub const glsl_image_fs: [:0]const u8 =
    \\#version 330 core
    \\in vec2 v_uv;
    \\in vec4 v_color;
    \\uniform sampler2D u_tex;
    \\out vec4 out_color;
    \\void main() {
    \\    vec4 t = texture(u_tex, v_uv);
    \\    out_color = t * v_color;
    \\}
;

test "vertex layouts match float counts" {
    for ([_]Layout{ shape_layout, solid_layout, text_layout }, [_]u32{ shape_floats, solid_floats, text_floats }) |layout, floats| {
        var total: u32 = 0;
        for (layout.attributes) |a| {
            try std.testing.expectEqual(total * 4, a.offset);
            total += a.components;
        }
        try std.testing.expectEqual(floats, total);
        try std.testing.expectEqual(floats * 4, layout.vertex_stride);
    }
    try std.testing.expect(shape_spv.len > 0 and shape_spv.len % 4 == 0);
    try std.testing.expect(solid_spv.len > 0 and solid_spv.len % 4 == 0);
    try std.testing.expect(text_spv.len > 0 and text_spv.len % 4 == 0);
    try std.testing.expect(image_spv.len > 0 and image_spv.len % 4 == 0);
}
