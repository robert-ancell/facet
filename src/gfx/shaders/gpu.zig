//! What Facet's shaders, written in Zig and compiled to SPIR-V, import
//! as "gpu": vector types, inputs and outputs by location, the uniform
//! block, the position, and texture sampling.

const std = @import("std");

pub const Vec2 = @Vector(2, f32);
pub const Vec3 = @Vector(3, f32);
pub const Vec4 = @Vector(4, f32);

/// The vertex's position in clip space (vertex shaders write it).
pub const position = std.spirv.position_out;

/// The fragment's colour, straight (not premultiplied) RGBA.
pub const color = @extern(*addrspace(.output) Vec4, .{ .name = "facet_color", .decoration = .{ .location = 0 } });

const max_locations = 8;
const vin_names = [max_locations][]const u8{ "facet_vin0", "facet_vin1", "facet_vin2", "facet_vin3", "facet_vin4", "facet_vin5", "facet_vin6", "facet_vin7" };
const vout_names = [max_locations][]const u8{ "facet_vout0", "facet_vout1", "facet_vout2", "facet_vout3", "facet_vout4", "facet_vout5", "facet_vout6", "facet_vout7" };
const fin_names = [max_locations][]const u8{ "facet_fin0", "facet_fin1", "facet_fin2", "facet_fin3", "facet_fin4", "facet_fin5", "facet_fin6", "facet_fin7" };

/// A vertex attribute.
pub fn vertexInput(comptime T: type, comptime location: u32) *addrspace(.input) T {
    return @extern(*addrspace(.input) T, .{ .name = vin_names[location], .decoration = .{ .location = location } });
}

/// A value passed to the fragment shader, interpolated across the triangle.
pub fn vertexOutput(comptime T: type, comptime location: u32) *addrspace(.output) T {
    return @extern(*addrspace(.output) T, .{ .name = vout_names[location], .decoration = .{ .location = location } });
}

/// What the vertex shader wrote with `vertexOutput` at this location.
pub fn fragmentInput(comptime T: type, comptime location: u32) *addrspace(.input) T {
    return @extern(*addrspace(.input) T, .{ .name = fin_names[location], .decoration = .{ .location = location } });
}

/// The program's uniforms: an extern struct the app sets for each draw.
pub fn uniforms(comptime T: type) *addrspace(.uniform) T {
    return @extern(*addrspace(.uniform) T, .{ .name = "facet_uniforms", .decoration = .{ .descriptor = .{ .binding = 0, .set = 0 } } });
}

const Image2D = @SpirvType(.{ .image = .{
    .usage = .{ .sampled = f32 },
    .format = .unknown,
    .dim = .@"2d",
    .depth = .not_depth,
    .access = .unknown,
    .arrayed = false,
    .multisampled = false,
} });
const SampledImage2D = @SpirvType(.{ .sampled_image = Image2D });
const tex = @extern(*addrspace(.constant) SampledImage2D, .{
    .name = "facet_texture",
    .decoration = .{ .descriptor = .{ .set = 0, .binding = 1 } },
});

/// Samples the draw's texture at `coord` (0 to 1 across it), as RGBA.
pub fn texture(coord: Vec2) Vec4 {
    return std.spirv.imageSampleImplicitLod(tex, coord);
}

pub fn splat2(x: f32) Vec2 {
    return @splat(x);
}

pub fn splat3(x: f32) Vec3 {
    return @splat(x);
}

pub fn splat4(x: f32) Vec4 {
    return @splat(x);
}

pub fn clamp(x: anytype, lo: anytype, hi: anytype) @TypeOf(x) {
    return @min(@max(x, lo), hi);
}

pub fn dot(a: anytype, b: @TypeOf(a)) f32 {
    return @reduce(.Add, a * b);
}

pub fn length(a: anytype) f32 {
    return @sqrt(dot(a, a));
}

pub fn normalize(a: anytype) @TypeOf(a) {
    return a * @as(@TypeOf(a), @splat(1 / length(a)));
}
