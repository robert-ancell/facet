//! 3D polyhedron shader for `examples/opengl.zig` and `examples/vulkan.zig`,
//! written in Zig and compiled to SPIR-V at build time.

const gpu = @import("gpu");
const Vec2 = gpu.Vec2;
const Vec3 = gpu.Vec3;
const Vec4 = gpu.Vec4;

pub const Uniforms = extern struct {
    mvp: [4]Vec4,
    model: [4]Vec4,
    options: Vec4,
};

const u = gpu.uniforms(Uniforms);

const key_light = Vec3{ -0.50, 0.65, 0.57 };
const fill_light = Vec3{ 0.55, -0.60, 0.25 };

const in_pos = gpu.vertexInput(Vec3, 0);
const in_uv = gpu.vertexInput(Vec2, 1);
const in_tint = gpu.vertexInput(Vec3, 2);
const in_normal = gpu.vertexInput(Vec3, 3);

const v_uv = gpu.vertexOutput(Vec2, 0);
const v_tint = gpu.vertexOutput(Vec3, 1);
const v_normal = gpu.vertexOutput(Vec3, 2);
const v_world_pos = gpu.vertexOutput(Vec3, 3);

export fn vertex() callconv(.spirv_vertex) void {
    const p = in_pos.*;
    const m = u.mvp;
    gpu.position.* = m[0] * gpu.splat4(p[0]) + m[1] * gpu.splat4(p[1]) + m[2] * gpu.splat4(p[2]) + m[3];

    const r = u.model;
    const wp = r[0] * gpu.splat4(p[0]) + r[1] * gpu.splat4(p[1]) + r[2] * gpu.splat4(p[2]) + r[3];
    const n0 = in_normal.*;
    const nw = r[0] * gpu.splat4(n0[0]) + r[1] * gpu.splat4(n0[1]) + r[2] * gpu.splat4(n0[2]);

    v_uv.* = in_uv.*;
    v_tint.* = in_tint.*;
    v_normal.* = gpu.normalize(Vec3{ nw[0], nw[1], nw[2] });
    v_world_pos.* = Vec3{ wp[0], wp[1], wp[2] };
}

const f_uv = gpu.fragmentInput(Vec2, 0);
const f_tint = gpu.fragmentInput(Vec3, 1);
const f_normal = gpu.fragmentInput(Vec3, 2);
const f_world_pos = gpu.fragmentInput(Vec3, 3);

export fn fragment() callconv(.{ .spirv_fragment = .{} }) void {
    const n = gpu.normalize(f_normal.*);
    const l_dir = gpu.normalize(key_light);
    const f_dir = gpu.normalize(fill_light);
    const v_dir = gpu.normalize(Vec3{ 0.0, 0.0, 3.3 } - f_world_pos.*);
    const h_dir = gpu.normalize(l_dir + v_dir);

    // High-contrast key + subtle fill lighting with deep shadows (ambient 0.07)
    const key_diff = @max(gpu.dot(n, l_dir), 0.0);
    const fill_diff = @max(gpu.dot(n, f_dir), 0.0);
    const lit_diffuse = 0.07 + 1.08 * key_diff + 0.08 * fill_diff;

    // Crisp Blinn-Phong specular highlight (ndoth^32) + Fresnel rim
    const ndoth = @max(gpu.dot(n, h_dir), 0.0);
    const s2 = ndoth * ndoth;
    const s4 = s2 * s2;
    const s8 = s4 * s4;
    const s16 = s8 * s8;
    const s32 = s16 * s16;

    const ndotv = @max(gpu.dot(n, v_dir), 0.0);
    const omv = 1.0 - ndotv;
    const rim = omv * omv * omv * 0.22 * key_diff;

    const lighting_on = u.options[0];
    const shade = 1.0 + (lit_diffuse - 1.0) * lighting_on;
    const spec = (s32 * 0.55 + rim) * lighting_on;

    // Checkerboard pattern
    const uv = f_uv.*;
    const cell = @floor(uv * gpu.splat2(6.0));
    const cell_sum = cell[0] + cell[1];
    const pat = cell_sum - 2.0 * @floor(cell_sum * 0.5);
    const tex = 1.0 + (0.62 + 0.38 * pat - 1.0) * u.options[1];

    const base_rgb = f_tint.* * gpu.splat3(shade * tex) + gpu.splat3(spec);
    const rgb = gpu.clamp(base_rgb, gpu.splat3(0.0), gpu.splat3(1.0));
    gpu.color.* = .{ rgb[0], rgb[1], rgb[2], 1.0 };
}
