//! Interactive 3D Platonic solid viewer rendered with OpenGL (`zig build run-opengl`).

const std = @import("std");
const facet = @import("facet");
const solids = @import("solids.zig");

const Shape = solids.Shape;
const Look = solids.Look;
const Vertex = solids.Vertex;

const polyhedron_spv align(4) = @embedFile("polyhedron.spv").*;
const polyhedron_vert = @embedFile("shaders/polyhedron.vert");
const polyhedron_frag = @embedFile("shaders/polyhedron.frag");

pub const Uniforms = extern struct {
    mvp: [4][4]f32,
    model: [4][4]f32,
    options: [4]f32,
};

pub const SolidGlScene = struct {
    shape: Shape = .dodecahedron,
    yaw: f32 = 0.5,
    pitch: f32 = 0.35,
    roll: f32 = 0.0,
    look: Look = .{},

    pub const State = struct {
        pipeline: facet.OpenGlContext.Pipeline = .{},
        vbos: [solids.shapes.len]facet.OpenGlContext.Buffer = @splat(.{}),
        ibos: [solids.shapes.len]facet.OpenGlContext.Buffer = @splat(.{}),
        index_counts: [solids.shapes.len]u32 = @splat(0),

        pub fn init(ctx: *facet.OpenGlContext, gpa: std.mem.Allocator) !State {
            var s: State = .{};
            errdefer s.deinit(ctx);

            s.pipeline = try ctx.createPipeline(.{
                .shader_spv = if (ctx.supportsSpirv()) &polyhedron_spv else null,
                .vs_source = polyhedron_vert,
                .fs_source = polyhedron_frag,
                .vertex_stride = @sizeOf(Vertex),
                .attributes = &.{
                    .{ .location = 0, .components = 3, .offset = @offsetOf(Vertex, "pos") },
                    .{ .location = 1, .components = 2, .offset = @offsetOf(Vertex, "uv") },
                    .{ .location = 2, .components = 3, .offset = @offsetOf(Vertex, "tint") },
                    .{ .location = 3, .components = 3, .offset = @offsetOf(Vertex, "normal") },
                },
            });

            for (solids.shapes, 0..) |sh, idx| {
                const m = try solids.buildMesh(gpa, sh);
                defer m.deinit(gpa);
                s.vbos[idx] = try ctx.createVertexBuffer(Vertex, m.vertices);
                s.ibos[idx] = try ctx.createIndexBuffer(m.indices);
                s.index_counts[idx] = @intCast(m.indices.len);
            }
            return s;
        }

        pub fn deinit(s: *State, ctx: *facet.OpenGlContext) void {
            for (s.vbos) |b| ctx.destroyBuffer(b);
            for (s.ibos) |b| ctx.destroyBuffer(b);
            ctx.destroyPipeline(s.pipeline);
        }
    };

    pub fn render(self: *const SolidGlScene, s: *State, ctx: *facet.OpenGlContext) !void {
        const model = solids.modelMatrix(self.yaw, self.pitch, self.roll);
        const mvp = solids.mvpMatrix(ctx.aspect(), model);
        const uniforms: Uniforms = .{
            .mvp = @bitCast(mvp),
            .model = @bitCast(model),
            .options = .{
                if (self.look.lighting) 1.0 else 0.0,
                if (self.look.texturing) 1.0 else 0.0,
                0.0,
                0.0,
            },
        };

        const idx = @intFromEnum(self.shape);
        ctx.bindPipeline(s.pipeline);
        ctx.setUniforms(Uniforms, &uniforms);
        ctx.bindVertexBuffer(s.vbos[idx]);
        ctx.bindIndexBuffer16(s.ibos[idx]);
        ctx.drawIndexed(s.index_counts[idx]);
    }
};

pub const OpenGlDemo = struct {
    pub const State = struct {
        shape: Shape = .dodecahedron,
        look: Look = .{},
        samples: u8 = 4,
        yaw: f32 = 0.5,
        pitch: f32 = 0.35,
        roll: f32 = 0.0,
        speed: f32 = 1.0,
        paused: bool = false,
        last_ns: ?u64 = null,

        pub fn chooseShape(s: *State, sh: Shape) void {
            s.shape = sh;
        }

        pub fn setLighting(s: *State, v: bool) void {
            s.look.lighting = v;
        }

        pub fn setTexturing(s: *State, v: bool) void {
            s.look.texturing = v;
        }

        pub fn setSamples1(s: *State) void {
            s.samples = 1;
        }

        pub fn setSamples2(s: *State) void {
            s.samples = 2;
        }

        pub fn setSamples4(s: *State) void {
            s.samples = 4;
        }

        pub fn setSamples8(s: *State) void {
            s.samples = 8;
        }

        pub fn setSpeed(s: *State, v: f32) void {
            s.speed = v;
        }

        pub fn togglePause(s: *State) void {
            s.paused = !s.paused;
            s.last_ns = null;
        }

        pub fn resetView(s: *State) void {
            s.yaw = 0.5;
            s.pitch = 0.35;
            s.roll = 0.0;
        }

        pub fn orbit(s: *State, delta: facet.Point) void {
            s.yaw = @mod(s.yaw + delta[0] * 0.012, std.math.tau);
            s.pitch = std.math.clamp(s.pitch + delta[1] * 0.012, -1.45, 1.45);
        }
    };

    pub fn build(_: *const OpenGlDemo, cx: *facet.Context, state: *State) facet.Widget {
        const now = cx.now();
        if (!state.paused) {
            if (state.last_ns) |prev| {
                const dt_s: f32 = @floatCast(@as(f64, @floatFromInt(now -| prev)) / std.time.ns_per_s);
                state.yaw = @mod(state.yaw + dt_s * 0.9 * state.speed, std.math.tau);
                state.roll = @mod(state.roll + dt_s * 0.45 * state.speed, std.math.tau);
            }
            state.last_ns = now;
            cx.requestFrame();
        } else {
            state.last_ns = null;
        }

        const t = cx.theme();
        var radios: [solids.shapes.len]facet.Widget = undefined;
        for (&radios, solids.shapes) |*w, sh| {
            w.* = cx.make(facet.Radio(Shape){
                .value = sh,
                .group_value = state.shape,
                .on_changed = .of(state, State.chooseShape),
                .label = sh.name(),
            });
        }

        const msaa_label = switch (state.samples) {
            1 => "1× (Off)",
            2 => "2× MSAA",
            8 => "8× MSAA",
            else => "4× MSAA",
        };
        const badge = cx.make(facet.Align{
            .alignment = .top_left,
            .child = cx.make(facet.Padding{
                .padding = .all(12),
                .child = cx.make(facet.Decorated{
                    .color = t.surface_container_highest.withAlpha(0.88),
                    .radius = .all(8),
                    .border = .{ .width = 1, .color = t.outline_variant },
                    .child = cx.make(facet.Padding{
                        .padding = .symmetric(12, 6),
                        .child = cx.make(facet.Text{
                            .text = cx.fmt("OpenGL  ·  {s}  ·  {s} ({d} triangles)  ·  Drag to orbit", .{
                                msaa_label,
                                state.shape.name(),
                                state.shape.triangles(),
                            }),
                            .style = .{ .size = 13, .color = t.on_surface },
                        }),
                    }),
                }),
            }),
        });

        return cx.make(facet.Column{
            .cross_axis_alignment = .stretch,
            .children = &.{
                cx.make(facet.TitleBar{ .title = "OpenGL 3D Widget" }),
                cx.make(facet.Expanded{
                    .child = cx.make(facet.Padding{
                        .padding = .all(20),
                        .child = cx.make(facet.Row{
                            .cross_axis_alignment = .stretch,
                            .spacing = 20,
                            .children = &.{
                                cx.make(facet.Expanded{
                                    .child = cx.make(facet.OpenGlArea(SolidGlScene){
                                        .scene = .{
                                            .shape = state.shape,
                                            .yaw = state.yaw,
                                            .pitch = state.pitch,
                                            .roll = state.roll,
                                            .look = state.look,
                                        },
                                        .samples = state.samples,
                                        .border = .{ .width = 1, .color = t.outline_variant },
                                        .on_drag = .of(state, State.orbit),
                                        .child = badge,
                                    }),
                                }),
                                cx.make(facet.Card{
                                    .variant = .outlined,
                                    .padding = .all(14),
                                    .child = cx.make(facet.SizedBox{
                                        .width = 264,
                                        .child = cx.make(facet.Column{
                                            .main_axis_size = .min,
                                            .cross_axis_alignment = .start,
                                            .spacing = 4,
                                            .children = &.{
                                                cx.make(facet.Text{
                                                    .text = "Platonic Solid",
                                                    .style = .{ .size = 16 },
                                                }),
                                                radios[0],
                                                radios[1],
                                                radios[2],
                                                radios[3],
                                                radios[4],
                                                cx.make(facet.Divider{}),
                                                cx.make(facet.Text{
                                                    .text = "Shader Options",
                                                    .style = .{ .size = 16 },
                                                }),
                                                cx.make(facet.Switch{
                                                    .value = state.look.lighting,
                                                    .on_changed = .of(state, State.setLighting),
                                                    .label = "Directional Lighting",
                                                }),
                                                cx.make(facet.Switch{
                                                    .value = state.look.texturing,
                                                    .on_changed = .of(state, State.setTexturing),
                                                    .label = "Checkerboard Texture",
                                                }),
                                                cx.make(facet.Divider{}),
                                                cx.make(facet.Text{
                                                    .text = "Anti-Aliasing (MSAA)",
                                                    .style = .{ .size = 14, .color = t.on_surface_variant },
                                                }),
                                                cx.make(facet.PillBar{
                                                    .children = &.{
                                                        cx.make(facet.PillButton{
                                                            .label = "Off",
                                                            .selected = state.samples == 1,
                                                            .first = true,
                                                            .on_press = .of(state, State.setSamples1),
                                                        }),
                                                        cx.make(facet.PillButton{
                                                            .label = "2×",
                                                            .selected = state.samples == 2,
                                                            .on_press = .of(state, State.setSamples2),
                                                        }),
                                                        cx.make(facet.PillButton{
                                                            .label = "4×",
                                                            .selected = state.samples == 4,
                                                            .on_press = .of(state, State.setSamples4),
                                                        }),
                                                        cx.make(facet.PillButton{
                                                            .label = "8×",
                                                            .selected = state.samples == 8,
                                                            .last = true,
                                                            .on_press = .of(state, State.setSamples8),
                                                        }),
                                                    },
                                                }),
                                                cx.make(facet.Divider{}),
                                                cx.make(facet.Text{
                                                    .text = cx.fmt("Rotation Speed ({d:.1}×)", .{state.speed}),
                                                    .style = .{ .size = 14, .color = t.on_surface_variant },
                                                }),
                                                cx.make(facet.SizedBox{
                                                    .width = 264,
                                                    .child = cx.make(facet.Slider{
                                                        .value = state.speed,
                                                        .min = 0.2,
                                                        .max = 4.0,
                                                        .on_changed = .of(state, State.setSpeed),
                                                    }),
                                                }),
                                                cx.make(facet.Row{
                                                    .main_axis_size = .min,
                                                    .spacing = 8,
                                                    .children = &.{
                                                        cx.make(facet.ConstrainedBox{
                                                            .constraints = .{ .min_w = 136 },
                                                            .child = cx.make(facet.TonalButton{
                                                                .label = if (state.paused) "Resume" else "Pause",
                                                                .icon = if (state.paused) .play_arrow else .pause,
                                                                .on_press = .of(state, State.togglePause),
                                                            }),
                                                        }),
                                                        cx.make(facet.OutlinedButton{
                                                            .label = "Reset",
                                                            .icon = .refresh,
                                                            .on_press = .of(state, State.resetView),
                                                        }),
                                                    },
                                                }),
                                            },
                                        }),
                                    }),
                                }),
                            },
                        }),
                    }),
                }),
            },
        });
    }
};

pub fn main(init: std.process.Init) !void {
    const app = try facet.App.open(init.gpa, init.minimal.environ, .{
        .title = "Facet OpenGL 3D Widget",
        .size = .{ 920, 660 },
    });
    defer app.close();

    while (try app.step(std.math.maxInt(u64))) {
        app.takeInput();
        try app.draw(facet.window.nowNs(), OpenGlDemo{});
    }
}
