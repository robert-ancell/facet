//! A spinning cube, drawn by the showcase's 3D widgets: `Scene(Api)` is the
//! scene for `kete.VulkanArea` (`Api = .vulkan`), `kete.OpenGlArea`
//! (`Api = .opengl`), `kete.MetalArea` (`Api = .metal`) or
//! `kete.D3D11Area` (`Api = .d3d11`).

const std = @import("std");
const kete = @import("kete");

const vulkan_spv align(4) = @embedFile("cube_vulkan.spv").*;
const opengl_spv align(4) = @embedFile("cube_opengl.spv").*;

const Vertex = extern struct {
    pos: [3]f32,
    color: [3]f32,
    normal: [3]f32,
};

const Uniforms = extern struct {
    mvp: Mat4,
    model: Mat4,
};

const attributes = [_]kete.gfx.shaders.Attribute{
    .{ .location = 0, .components = 3, .offset = @offsetOf(Vertex, "pos") },
    .{ .location = 1, .components = 3, .offset = @offsetOf(Vertex, "color") },
    .{ .location = 2, .components = 3, .offset = @offsetOf(Vertex, "normal") },
};

/// Each face: its normal, two directions across it, and its colour.
const faces = [_]struct { n: [3]f32, u: [3]f32, v: [3]f32, color: u24 }{
    .{ .n = .{ 1, 0, 0 }, .u = .{ 0, 0, -1 }, .v = .{ 0, 1, 0 }, .color = 0xef5350 },
    .{ .n = .{ -1, 0, 0 }, .u = .{ 0, 0, 1 }, .v = .{ 0, 1, 0 }, .color = 0x66bb6a },
    .{ .n = .{ 0, 1, 0 }, .u = .{ 1, 0, 0 }, .v = .{ 0, 0, -1 }, .color = 0x42a5f5 },
    .{ .n = .{ 0, -1, 0 }, .u = .{ 1, 0, 0 }, .v = .{ 0, 0, 1 }, .color = 0xffa726 },
    .{ .n = .{ 0, 0, 1 }, .u = .{ 1, 0, 0 }, .v = .{ 0, 1, 0 }, .color = 0xab47bc },
    .{ .n = .{ 0, 0, -1 }, .u = .{ -1, 0, 0 }, .v = .{ 0, 1, 0 }, .color = 0x26a69a },
};

const vertices: [faces.len * 4]Vertex = blk: {
    var out: [faces.len * 4]Vertex = undefined;
    for (faces, 0..) |f, i| {
        const rgb = [3]f32{
            @as(f32, @floatFromInt(f.color >> 16)) / 255,
            @as(f32, @floatFromInt((f.color >> 8) & 0xff)) / 255,
            @as(f32, @floatFromInt(f.color & 0xff)) / 255,
        };
        for ([_][2]f32{ .{ -1, -1 }, .{ 1, -1 }, .{ 1, 1 }, .{ -1, 1 } }, 0..) |c, j| {
            var p: [3]f32 = undefined;
            for (&p, 0..) |*x, k| x.* = f.n[k] + c[0] * f.u[k] + c[1] * f.v[k];
            out[i * 4 + j] = .{ .pos = p, .color = rgb, .normal = f.n };
        }
    }
    break :blk out;
};

const indices: [faces.len * 6]u16 = blk: {
    var out: [faces.len * 6]u16 = undefined;
    for (0..faces.len) |i| {
        const b: u16 = @intCast(i * 4);
        out[i * 6 ..][0..6].* = .{ b, b + 1, b + 2, b, b + 2, b + 3 };
    }
    break :blk out;
};

pub const Api = enum { vulkan, opengl, metal, d3d11 };

pub fn Scene(comptime api: Api) type {
    const Context = switch (api) {
        .vulkan => kete.gfx.VulkanContext,
        .opengl => kete.gfx.OpenGlContext,
        .metal => kete.gfx.MetalContext,
        .d3d11 => kete.gfx.D3D11Context,
    };
    return struct {
        /// How far round the cube has turned, and tilted towards the
        /// viewer, in radians.
        angle: f32 = 0,
        tilt: f32 = 0.55,

        pub const State = struct {
            pipeline: Context.Pipeline = .{},
            vbo: Context.Buffer = .{},
            ibo: Context.Buffer = .{},

            pub fn init(ctx: *Context) !State {
                var s: State = .{};
                errdefer s.deinit(ctx);
                s.pipeline = try switch (api) {
                    .vulkan => ctx.createPipeline(.{
                        .shader_spv = &vulkan_spv,
                        .vertex_stride = @sizeOf(Vertex),
                        .attributes = &attributes,
                        .cull_mode = 0,
                    }),
                    .opengl => ctx.createPipeline(.{
                        .shader_spv = if (ctx.supportsSpirv()) &opengl_spv else null,
                        .vs_source = @embedFile("shaders/cube.vert"),
                        .fs_source = @embedFile("shaders/cube.frag"),
                        .vertex_stride = @sizeOf(Vertex),
                        .attributes = &attributes,
                        .cull_back = false,
                    }),
                    .metal => ctx.createPipeline(.{
                        .source = @embedFile("shaders/cube.metal"),
                        .vertex_stride = @sizeOf(Vertex),
                        .attributes = &attributes,
                        .cull_back = false,
                    }),
                    .d3d11 => ctx.createPipeline(.{
                        .vertex = @embedFile("cube_vs.dxbc"),
                        .pixel = @embedFile("cube_ps.dxbc"),
                        .vertex_stride = @sizeOf(Vertex),
                        .attributes = &attributes,
                        .cull_back = false,
                    }),
                };
                s.vbo = try ctx.createVertexBuffer(Vertex, &vertices);
                s.ibo = try ctx.createIndexBuffer(&indices);
                return s;
            }

            pub fn deinit(s: *State, ctx: *Context) void {
                switch (api) {
                    .vulkan => _ = ctx.vk.DeviceWaitIdle(ctx.device),
                    .metal, .d3d11 => ctx.waitIdle(),
                    .opengl => {},
                }
                ctx.destroyBuffer(s.vbo);
                ctx.destroyBuffer(s.ibo);
                ctx.destroyPipeline(s.pipeline);
            }
        };

        pub fn render(self: *const @This(), s: *State, ctx: *Context) !void {
            const model = mul(rotX(self.tilt), rotY(self.angle));
            const proj = perspective(std.math.degreesToRadians(40), ctx.aspect(), 1, 12);
            const uniforms: Uniforms = .{ .mvp = mul(proj, mul(translate(0, 0, -7), model)), .model = model };
            ctx.bindPipeline(s.pipeline);
            ctx.setUniforms(Uniforms, &uniforms);
            ctx.bindVertexBuffer(s.vbo);
            ctx.bindIndexBuffer16(s.ibo);
            ctx.drawIndexed(indices.len);
        }
    };
}

/// Column-major, as the shaders read it.
const Mat4 = [16]f32;

fn mul(a: Mat4, b: Mat4) Mat4 {
    var out: Mat4 = undefined;
    for (0..4) |col| for (0..4) |row| {
        var sum: f32 = 0;
        for (0..4) |k| sum += a[k * 4 + row] * b[col * 4 + k];
        out[col * 4 + row] = sum;
    };
    return out;
}

fn translate(x: f32, y: f32, z: f32) Mat4 {
    return .{ 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, x, y, z, 1 };
}

fn rotX(a: f32) Mat4 {
    const c = @cos(a);
    const s = @sin(a);
    return .{ 1, 0, 0, 0, 0, c, s, 0, 0, -s, c, 0, 0, 0, 0, 1 };
}

fn rotY(a: f32) Mat4 {
    const c = @cos(a);
    const s = @sin(a);
    return .{ c, 0, -s, 0, 0, 1, 0, 0, s, 0, c, 0, 0, 0, 0, 1 };
}

/// Maps depth `[near, far]` to `[0, 1]`, which suits Vulkan, OpenGL and
/// Metal.
fn perspective(fovy: f32, aspect: f32, near: f32, far: f32) Mat4 {
    const f = 1 / @tan(fovy / 2);
    const nf = 1 / (near - far);
    return .{ f / aspect, 0, 0, 0, 0, f, 0, 0, 0, 0, far * nf, -1, 0, 0, far * near * nf, 0 };
}
