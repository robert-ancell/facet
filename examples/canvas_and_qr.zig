//! Animated harmonic wave viewer and live QR code generator (`zig build run-canvas`).

const std = @import("std");
const facet = @import("facet");

/// Custom widget that draws an animated harmonic wave and orbiting circles.
pub const WaveCanvas = struct {
    animate: bool = true,
    frequency: f32 = 2.0,

    pub const State = struct {
        phase: f32 = 0,
        last_ns: ?u64 = null,
    };

    pub fn layout(_: *const WaveCanvas, _: *facet.Node, c: facet.Constraints) facet.Size {
        return c.constrain(.{ .w = 340, .h = 200 });
    }

    pub fn paint(self: *const WaveCanvas, n: *facet.Node, p: *facet.Painter) void {
        const state = n.state(State);
        if (self.animate) {
            if (state.last_ns) |prev| {
                const dt_ns = n.ui.now_ns -| prev;
                const dt_s: f32 = @floatCast(@as(f64, @floatFromInt(dt_ns)) / std.time.ns_per_s);
                state.phase = @mod(state.phase + dt_s * std.math.tau * 0.4, std.math.tau);
            }
            state.last_ns = n.ui.now_ns;
            n.ui.needs_frame = true;
        } else {
            state.last_ns = null;
        }

        const t = &n.ui.theme;
        const c = p.canvas();
        const w = n.size.w;
        const h = n.size.h;
        const phase = state.phase;

        c.fillRoundedRect(.{ .x = 0, .y = 0, .w = w, .h = h }, .all(12), t.surface_container_highest);
        c.strokeRoundedRect(.{ .x = 0.5, .y = 0.5, .w = w - 1, .h = h - 1 }, .all(12), 1, t.outline_variant);

        const steps = 256;
        var points: [steps]facet.Point = undefined;
        for (&points, 0..) |*pt, i| {
            const u = @as(f32, @floatFromInt(i)) / @as(f32, steps - 1);
            const x = 16 + u * (w - 32);
            const y = h * 0.5 + @sin(u * std.math.tau * self.frequency + phase) * (h * 0.3);
            pt.* = .{ x, y };
        }
        c.strokePolyline(&points, false, 3, t.primary);

        const tip = points[steps - 1];
        c.fillCircle(tip, 6, t.primary);
        c.strokeCircle(tip, 10, 2, t.primary.withAlpha(0.4));
    }
};

pub const CanvasAndQrDemo = struct {
    pub const State = struct {
        animate: bool = true,
        frequency: f32 = 2.0,
        payload_buf: [128]u8 = undefined,
        payload_len: usize = 0,

        pub fn setAnimate(s: *State, v: bool) void {
            s.animate = v;
        }

        pub fn setFrequency(s: *State, v: f32) void {
            s.frequency = v;
        }

        pub fn setPayload(s: *State, text: []const u8) void {
            const n = @min(text.len, s.payload_buf.len);
            @memcpy(s.payload_buf[0..n], text[0..n]);
            s.payload_len = n;
        }
    };

    pub fn build(_: *const CanvasAndQrDemo, cx: *facet.Context, state: *State) facet.Widget {
        const default_url = "https://github.com/robert-ancell/facet";
        const payload = if (state.payload_len > 0) state.payload_buf[0..state.payload_len] else default_url;

        return cx.make(facet.Padding{
            .padding = .all(24),
            .child = cx.make(facet.Row{
                .cross_axis_alignment = .start,
                .spacing = 24,
                .children = &.{
                    cx.make(facet.Card{
                        .variant = .outlined,
                        .child = cx.make(facet.Column{
                            .main_axis_size = .min,
                            .cross_axis_alignment = .start,
                            .spacing = 12,
                            .children = &.{
                                cx.make(facet.Text{
                                    .text = "Custom 2D Vector Widget",
                                    .style = .{ .size = 18 },
                                }),
                                cx.make(WaveCanvas{
                                    .animate = state.animate,
                                    .frequency = state.frequency,
                                }),
                                cx.make(facet.SizedBox{
                                    .width = 340,
                                    .child = cx.make(facet.Slider{
                                        .value = state.frequency,
                                        .min = 0.5,
                                        .max = 5.0,
                                        .on_changed = .of(state, State.setFrequency),
                                    }),
                                }),
                                cx.make(facet.Switch{
                                    .value = state.animate,
                                    .on_changed = .of(state, State.setAnimate),
                                    .label = "Animate wave",
                                }),
                            },
                        }),
                    }),
                    cx.make(facet.Card{
                        .variant = .outlined,
                        .child = cx.make(facet.Column{
                            .main_axis_size = .min,
                            .cross_axis_alignment = .center,
                            .spacing = 12,
                            .children = &.{
                                cx.make(facet.Text{
                                    .text = "Live QR Code Generator",
                                    .style = .{ .size = 18 },
                                }),
                                cx.make(facet.QrCode{
                                    .text = payload,
                                    .size = 180,
                                }),
                                cx.make(facet.TextField{
                                    .width = 240,
                                    .initial = default_url,
                                    .placeholder = "Text or URL to encode",
                                    .on_changed = .of(state, State.setPayload),
                                }),
                            },
                        }),
                    }),
                },
            }),
        });
    }
};

pub fn main(init: std.process.Init) !void {
    const app = try facet.App.open(init.gpa, init.io, init.minimal.environ, .{
        .title = "Facet Canvas & QR",
        .size = .{ 740, 460 },
    });
    defer app.close();

    while (try app.step(std.math.maxInt(u64))) {
        app.takeInput();
        try app.draw(CanvasAndQrDemo{});
    }
}
