//! Triangles with a colour per vertex (its alpha includes the coverage of
//! anti-aliasing fringes): polygons, strokes, and the straight parts of the
//! canvas's rectangles. Blended source-over.

const gpu = @import("gpu");

const in_pos = gpu.vertexInput(gpu.Vec2, 0);
const in_color = gpu.vertexInput(gpu.Vec4, 1);
const v_color = gpu.vertexOutput(gpu.Vec4, 0);

export fn vertex() callconv(.spirv_vertex) void {
    const p = in_pos.*;
    gpu.position.* = .{ p[0], p[1], 0, 1 };
    v_color.* = in_color.*;
}

const f_color = gpu.fragmentInput(gpu.Vec4, 0);

export fn fragment() callconv(.spirv_fragment) void {
    gpu.color.* = f_color.*;
}
