//! 3D: a scene drawn on the GPU in a widget, with the APIs the system has
//! (Vulkan and OpenGL on Linux, Metal on macOS, Direct3D 11 on Windows),
//! turned by dragging, and how it is drawn.

const std = @import("std");
const builtin = @import("builtin");
const facet = @import("facet");
const common = @import("common.zig");
const cube = @import("cube.zig");

pub const Samples = enum(u8) { one = 1, two = 2, four = 4, eight = 8 };

pub const State = struct {
    spinning: bool = true,
    speed: f32 = 1,
    angle: f32 = 0,
    tilt: f32 = 0.55,
    samples: Samples = .four,
    last_ns: ?u64 = null,

    fn setSpinning(s: *State, v: bool) void {
        s.spinning = v;
        s.last_ns = null;
    }
    fn setSpeed(s: *State, v: f32) void {
        s.speed = v;
    }
    fn setSamples(s: *State, v: Samples) void {
        s.samples = v;
    }
    fn turn(s: *State, delta: facet.Point) void {
        s.angle = @mod(s.angle + delta[0] * 0.012, std.math.tau);
        s.tilt = std.math.clamp(s.tilt + delta[1] * 0.012, -1.45, 1.45);
    }
    fn reset(s: *State) void {
        s.angle = 0;
        s.tilt = 0.55;
    }
};

pub fn build(cx: *facet.Context, s: *State) facet.Widget {
    if (s.spinning) {
        const now = cx.now();
        if (s.last_ns) |prev| {
            const dt: f32 = @floatCast(@as(f64, @floatFromInt(now -| prev)) / std.time.ns_per_s);
            s.angle = @mod(s.angle + dt * 1.2 * s.speed, std.math.tau);
        }
        s.last_ns = now;
        cx.requestFrame();
    }
    const samples = [_]facet.Select(Samples).Option{
        .{ .value = .one, .label = "None" },
        .{ .value = .two, .label = "2× MSAA" },
        .{ .value = .four, .label = "4× MSAA" },
        .{ .value = .eight, .label = "8× MSAA" },
    };
    const scenes = switch (builtin.os.tag) {
        .macos => common.section(cx, "Metal", "The scene drawn with Metal, on the renderer's GPU where it can be; drag it to turn it", &.{
            area(cx, s, facet.MetalArea, .metal, "Metal"),
        }),
        .windows => common.section(cx, "Direct3D 11", "The scene drawn with Direct3D 11, on the renderer's GPU where it can be; drag it to turn it", &.{
            area(cx, s, facet.D3D11Area, .d3d11, "Direct3D 11"),
        }),
        else => common.section(cx, "Vulkan and OpenGL", "The same scene drawn by each, on the renderer's GPU where it can be; drag either to turn it", cx.makeAll(.{
            facet.Row{ .spacing = 16, .cross_axis_alignment = .start, .children = cx.makeAll(.{
                facet.Expanded{ .child = area(cx, s, facet.VulkanArea, .vulkan, "Vulkan") },
                facet.Expanded{ .child = area(cx, s, facet.OpenGlArea, .opengl, "OpenGL") },
            }) },
        })),
    };
    return common.page(cx, &.{
        scenes,
        common.section(cx, "Drawing", "How it moves, and how its edges are smoothed", &.{
            common.labelled(cx, "Spin", cx.makeAll(.{
                facet.Switch{ .value = s.spinning, .on_changed = .of(s, State.setSpinning) },
                facet.TextButton{ .label = "Reset", .icon = .refresh, .on_press = .of(s, State.reset) },
            })),
            common.labelled(cx, cx.fmt("Speed {d:.1}×", .{s.speed}), cx.makeAll(.{
                facet.Expanded{ .child = cx.make(facet.Slider{ .value = s.speed, .min = 0.1, .max = 4, .on_changed = .of(s, State.setSpeed) }) },
            })),
            common.labelled(cx, "Anti-aliasing", cx.makeAll(.{
                facet.Select(Samples){ .options = &samples, .value = s.samples, .on_changed = .of(s, State.setSamples), .width = 180 },
            })),
        }),
    });
}

/// The cube, drawn with `api` by its widget (`Area`, as `facet.VulkanArea`).
fn area(cx: *facet.Context, s: *State, comptime Area: fn (type) type, comptime api: cube.Api, name: []const u8) facet.Widget {
    const t = cx.theme();
    return cx.make(Area(cube.Scene(api)){
        .scene = .{ .angle = s.angle, .tilt = s.tilt },
        .samples = @backingInt(s.samples),
        .border = .{ .width = 1, .color = t.outline_variant },
        .on_drag = .of(s, State.turn),
        .min_width = 200,
        .min_height = 260,
        .child = label(cx, name),
    });
}

fn label(cx: *facet.Context, text: []const u8) facet.Widget {
    const t = cx.theme();
    return cx.make(facet.Align{ .alignment = .top_left, .child = cx.make(facet.Padding{
        .padding = .all(10),
        .child = cx.make(facet.Decorated{
            .color = t.surface_container_highest.withAlpha(0.88),
            .radius = .all(6),
            .child = cx.make(facet.Padding{ .padding = .symmetric(10, 4), .child = cx.make(facet.Text{
                .text = text,
                .style = .{ .size = 13, .color = t.on_surface },
                .wrap = false,
            }) }),
        }),
    }) });
}
