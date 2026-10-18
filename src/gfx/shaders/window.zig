//! A window's frame, drawn around and under its content when the content
//! is drawn on the GPU: its drop shadow (in the margin around it, and under
//! its rounded corners) and the rounding of its corners. The same as the
//! CPU draws it (see `window/wayland.zig`).
//!
//! Each vertex carries its pixel position in the window's buffer, the
//! window's rounded box (its centre and the half size of its straight
//! part), the corner radius, the scale, and what to output:
//! * 0: the pixel's coverage by the window's rounded box (to multiply what
//!   is there by: what is outside the rounding goes);
//! * 1: the shadow, premultiplied black (to go under what is there).

const gpu = @import("gpu");
const Vec2 = gpu.Vec2;
const Vec4 = gpu.Vec4;

const in_pos = gpu.vertexInput(Vec2, 0);
const in_px = gpu.vertexInput(Vec2, 1);
const in_box = gpu.vertexInput(Vec4, 2);
/// Radius, scale, mode.
const in_params = gpu.vertexInput(Vec4, 3);

const v_px = gpu.vertexOutput(Vec2, 0);
const v_box = gpu.vertexOutput(Vec4, 1);
const v_params = gpu.vertexOutput(Vec4, 2);

export fn vertex() callconv(.spirv_vertex) void {
    const p = in_pos.*;
    gpu.position.* = .{ p[0], p[1], 0, 1 };
    v_px.* = in_px.*;
    v_box.* = in_box.*;
    v_params.* = in_params.*;
}

const f_px = gpu.fragmentInput(Vec2, 0);
const f_box = gpu.fragmentInput(Vec4, 1);
const f_params = gpu.fragmentInput(Vec4, 2);

/// Signed distance from `p` to the rounded box centred at `c` (negative
/// inside).
fn roundedBox(p: Vec2, c: Vec2, half: Vec2, radius: f32) f32 {
    const q = @abs(p - c) - half;
    const m = @max(q, gpu.splat2(0));
    return @sqrt(m[0] * m[0] + m[1] * m[1]) + @min(@max(q[0], q[1]), 0) - radius;
}

export fn fragment() callconv(.{ .spirv_fragment = .{} }) void {
    const p = f_px.*;
    const box = f_box.*;
    const c = Vec2{ box[0], box[1] };
    const half = Vec2{ box[2], box[3] };
    const radius = f_params.*[0];
    const s = f_params.*[1];
    const mode = f_params.*[2];

    const d_win = roundedBox(p, c, half, radius);
    // Coverage by the window: what of the content shows.
    const cov = gpu.clamp(0.5 - d_win, 0, 1);

    // A key shadow below the window and a tight ambient one around it, and
    // a faint outline at its edge.
    const d_key = roundedBox(p, c + Vec2{ 0, 4 * s }, half, radius);
    const u_key = gpu.clamp(1 - @max(d_key, 0) / (22 * s), 0, 1);
    const t_key = u_key * u_key * u_key;
    const d_amb = roundedBox(p, c + Vec2{ 0, 1 * s }, half, radius);
    const u_amb = gpu.clamp(1 - @max(d_amb, 0) / (7 * s), 0, 1);
    const t_amb = u_amb * u_amb * (3 - 2 * u_amb);
    // Only from the edge outwards (`d_win >= -0.5`).
    const band = gpu.clamp(1 - @abs(d_win - 0.3 * s) / (0.9 * s), 0, 1) * gpu.clamp((d_win + 0.5) * 1e6, 0, 1);
    const outline = 0.18 * band;
    const shadow = gpu.clamp(0.28 * t_key + 0.14 * t_amb + outline, 0, 1);

    gpu.color.* = if (mode < 0.5) .{ 1, 1, 1, cov } else .{ 0, 0, 0, shadow };
}
