//! Images: their pixels from their texture, times the vertices' colour (a
//! tint, and how opaque the image is drawn). Blended source-over.

const gpu = @import("gpu");

const in_pos = gpu.vertexInput(gpu.Vec2, 0);
const in_uv = gpu.vertexInput(gpu.Vec2, 1);
const in_color = gpu.vertexInput(gpu.Vec4, 2);
const v_uv = gpu.vertexOutput(gpu.Vec2, 0);
const v_color = gpu.vertexOutput(gpu.Vec4, 1);

export fn vertex() callconv(.spirv_vertex) void {
    const p = in_pos.*;
    gpu.position.* = .{ p[0], p[1], 0, 1 };
    v_uv.* = in_uv.*;
    v_color.* = in_color.*;
}

const f_uv = gpu.fragmentInput(gpu.Vec2, 0);
const f_color = gpu.fragmentInput(gpu.Vec4, 1);

export fn fragment() callconv(.{ .spirv_fragment = .{} }) void {
    const t = gpu.texture(f_uv.*);
    const c = f_color.*;
    gpu.color.* = .{ t[0] * c[0], t[1] * c[1], t[2] * c[2], t[3] * c[3] };
}
