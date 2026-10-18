//! The showcase's cube shader, written in Zig and compiled to SPIR-V at
//! build time: each face its own colour, lit from one side.

const gpu = @import("gpu");
const Vec3 = gpu.Vec3;
const Vec4 = gpu.Vec4;

pub const Uniforms = extern struct {
    mvp: [4]Vec4,
    model: [4]Vec4,
};

const u = gpu.uniforms(Uniforms);

const light = Vec3{ -0.4, 0.6, 0.7 };

const in_pos = gpu.vertexInput(Vec3, 0);
const in_color = gpu.vertexInput(Vec3, 1);
const in_normal = gpu.vertexInput(Vec3, 2);

const v_color = gpu.vertexOutput(Vec3, 0);
const v_normal = gpu.vertexOutput(Vec3, 1);

export fn vertex() callconv(.spirv_vertex) void {
    const p = in_pos.*;
    const m = u.mvp;
    gpu.position.* = m[0] * gpu.splat4(p[0]) + m[1] * gpu.splat4(p[1]) + m[2] * gpu.splat4(p[2]) + m[3];
    const r = u.model;
    const n = in_normal.*;
    const nw = r[0] * gpu.splat4(n[0]) + r[1] * gpu.splat4(n[1]) + r[2] * gpu.splat4(n[2]);
    v_color.* = in_color.*;
    v_normal.* = Vec3{ nw[0], nw[1], nw[2] };
}

const f_color = gpu.fragmentInput(Vec3, 0);
const f_normal = gpu.fragmentInput(Vec3, 1);

export fn fragment() callconv(.{ .spirv_fragment = .{} }) void {
    const shade = 0.35 + 0.65 * @max(gpu.dot(gpu.normalize(f_normal.*), gpu.normalize(light)), 0.0);
    const rgb = f_color.* * gpu.splat3(shade);
    gpu.color.* = .{ rgb[0], rgb[1], rgb[2], 1.0 };
}
