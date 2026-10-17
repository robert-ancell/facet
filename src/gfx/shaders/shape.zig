//! Anti-aliased rounded rectangles, filled or stroked: the corner cells of
//! the canvas's rectangles (and whole circles). Blended source-over.
//!
//! Each vertex carries the rectangle: the position relative to its centre,
//! its half size, corner radius and stroke width, and the colour. The
//! fragment shader turns the signed distance to the rounded outline into
//! coverage over one pixel.

const gpu = @import("gpu");
const Vec2 = gpu.Vec2;
const Vec4 = gpu.Vec4;

const in_pos = gpu.vertexInput(Vec2, 0);
/// Position relative to the centre, and half the size.
const in_geometry = gpu.vertexInput(Vec4, 1);
/// Corner radius and stroke width (a huge one when filled).
const in_shape = gpu.vertexInput(Vec2, 2);
const in_color = gpu.vertexInput(Vec4, 3);

const v_geometry = gpu.vertexOutput(Vec4, 0);
const v_shape = gpu.vertexOutput(Vec2, 1);
const v_color = gpu.vertexOutput(Vec4, 2);

export fn vertex() callconv(.spirv_vertex) void {
    const p = in_pos.*;
    gpu.position.* = .{ p[0], p[1], 0, 1 };
    v_geometry.* = in_geometry.*;
    v_shape.* = in_shape.*;
    v_color.* = in_color.*;
}

const f_geometry = gpu.fragmentInput(Vec4, 0);
const f_shape = gpu.fragmentInput(Vec2, 1);
const f_color = gpu.fragmentInput(Vec4, 2);

/// The pixel's coverage by the shape shrunk by `inset`: its distance spread
/// over one pixel, but no more than the product of the coverages by the
/// box's sides, which is exact at square corners (where the distance alone
/// gives a half rather than a quarter).
fn coverage(d: f32, sides: Vec2, inset: f32) f32 {
    const by_distance = gpu.clamp(0.5 - (d + inset), 0, 1);
    const c = gpu.clamp(gpu.splat2(0.5) - (sides + gpu.splat2(inset)), gpu.splat2(0), gpu.splat2(1));
    return @min(by_distance, c[0] * c[1]);
}

export fn fragment() callconv(.{ .spirv_fragment = .{} }) void {
    const g = f_geometry.*;
    const p = Vec2{ g[0], g[1] };
    const half = Vec2{ g[2], g[3] };
    const radius = f_shape.*[0];
    const stroke = f_shape.*[1];

    // Signed distance to a rounded box (negative inside).
    const a = @abs(p);
    const q = a - (half - gpu.splat2(radius));
    const m = @max(q, gpu.splat2(0));
    const d = @sqrt(m[0] * m[0] + m[1] * m[1]) + @min(@max(q[0], q[1]), 0) - radius;
    // Distances to the box's sides, without rounding.
    const sides = a - half;

    // The band from the outline to `stroke` pixels inside it.
    const cov = coverage(d, sides, 0) - coverage(d, sides, stroke);
    const c = f_color.*;
    gpu.color.* = .{ c[0], c[1], c[2], c[3] * cov };
}
