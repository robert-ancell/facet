//! Special widgets: QR codes, custom painting, and animation.

const std = @import("std");
const facet = @import("facet");
const common = @import("common.zig");

pub const State = struct {
    qr: Text = .{},
    plays: u64 = 0,

    fn setQr(s: *State, v: []const u8) void {
        s.qr.set(v);
    }
    fn play(s: *State) void {
        s.plays += 1;
    }
};

const Text = struct {
    buf: [128]u8 = undefined,
    len: usize = 0,

    fn set(b: *Text, v: []const u8) void {
        var n = @min(v.len, b.buf.len);
        while (n > 0 and n < v.len and v[n] & 0xc0 == 0x80) n -= 1;
        @memcpy(b.buf[0..n], v[0..n]);
        b.len = n;
    }
};

pub fn build(cx: *facet.Context, s: *State) facet.Widget {
    const t = cx.theme();

    const qr_text = if (s.qr.len > 0) s.qr.buf[0..s.qr.len] else "https://github.com/robert-ancell/facet";

    return common.page(cx, &.{
        common.section(cx, "QR code", "Text encoded as a QR code, made as it is typed", &.{
            cx.make(facet.Row{ .spacing = 24, .cross_axis_alignment = .center, .children = &.{
                cx.make(facet.QrCode{ .text = qr_text, .size = 160 }),
                cx.make(facet.Column{ .main_axis_size = .min, .cross_axis_alignment = .start, .spacing = 8, .children = &.{
                    cx.make(facet.TextField{ .placeholder = "Text to encode", .initial = s.qr.buf[0..s.qr.len], .max_len = 127, .width = 300, .on_changed = .of(s, State.setQr) }),
                    cx.make(facet.Text{ .text = cx.fmt("{d} bytes", .{qr_text.len}), .style = .{ .size = 13, .color = t.on_surface_variant } }),
                    cx.make(facet.QrCode{ .text = "Small", .size = 64 }),
                } }),
            } }),
        }),
        common.section(cx, "Custom painting", "A widget of its own, painting shapes and lines on the canvas each frame", &.{
            // Described to screen readers as what it is.
            cx.make(facet.Accessible{ .role = .animation, .label = "A Lissajous figure", .description = "Lines and circles tracing a figure that turns", .child = cx.make(Lissajous{}) }),
        }),
        common.section(cx, "Accessibility", "What the widgets are, offered to screen readers (and other assistive technologies) over AT-SPI; widgets of the app's own are described with Accessible", &.{
            common.status(cx, if (cx.ui.a11y != null) "Offered over AT-SPI: try Orca, or Accerciser to look at the tree" else "Not offered: there is no AT-SPI bus (or NO_AT_BRIDGE is set)"),
        }),
        common.section(cx, "Animation", "A widget made afresh each frame from how far through its time it is, eased by a tweening function", animation(cx, s)),
    });
}

const Easing = struct { []const u8, facet.tween.Easing };

const easings = [_]Easing{
    .{ "linear", facet.tween.linear },
    .{ "inOutCubic", facet.tween.inOutCubic },
    .{ "outBack", facet.tween.outBack },
    .{ "outBounce", facet.tween.outBounce },
    .{ "standard", facet.tween.standard },
    .{ "emphasized", facet.tween.emphasized_decelerate },
    .{ "steps(5)", facet.tween.steps(5) },
};

fn animation(cx: *facet.Context, s: *State) []const facet.Widget {
    const t = cx.theme();
    const rows = cx.arena.alloc(facet.Widget, easings.len + 2) catch return &.{};
    rows[0] = cx.make(facet.Row{ .spacing = 12, .cross_axis_alignment = .center, .children = &.{
        cx.make(facet.FilledButton{ .label = "Play", .icon = .bolt, .on_press = .of(s, State.play) }),
        common.status(cx, "Each dot crosses in a second, eased differently"),
    } });
    for (rows[1..][0..easings.len], &easings) |*row, *e| {
        row.* = common.labelled(cx, e[0], &.{cx.make(facet.Expanded{ .child = cx.make(facet.Decorated{
            .color = t.surface_container,
            .radius = .all(14),
            .child = cx.make(facet.SizedBox{ .height = 28, .child = cx.make(facet.Padding{
                .padding = .all(4),
                .child = cx.make(facet.AnimatedWidget{
                    .duration_ns = std.time.ns_per_s,
                    .restart = s.plays,
                    .builder = .of(e, dot),
                }),
            }) }),
        }) })});
    }
    rows[easings.len + 1] = common.labelled(cx, "Back and forth", &.{cx.make(facet.Expanded{ .child = cx.make(facet.SizedBox{
        .height = 28,
        .child = cx.make(facet.AnimatedWidget{
            .duration_ns = 1500 * std.time.ns_per_ms,
            .repeat = .reverse,
            .builder = .func(pulse),
        }),
    }) })});
    return rows;
}

/// A dot across its track, eased `t` of the way along (inset a little,
/// for easings that overshoot).
fn dot(e: *const Easing, cx: *facet.Context, t: f32) facet.Widget {
    return cx.make(facet.Align{
        .alignment = .{ .x = facet.tween.lerp(@as(f32, -0.8), 0.8, e[1](t)), .y = 0 },
        .child = cx.make(facet.SizedBox{ .width = 20, .height = 20, .child = cx.make(facet.Decorated{
            .color = cx.theme().primary,
            .radius = .all(10),
        }) }),
    });
}

/// A bar growing and changing colour, and back.
fn pulse(cx: *facet.Context, t: f32) facet.Widget {
    const th = cx.theme();
    const e = facet.tween.inOutSine(t);
    return cx.make(facet.Align{
        .alignment = .center_left,
        .child = cx.make(facet.SizedBox{ .width = facet.tween.lerp(@as(f32, 40), 240, e), .height = 28, .child = cx.make(facet.Decorated{
            .color = facet.tween.lerp(th.primary, th.@"error", e),
            .radius = .all(14),
        }) }),
    });
}

/// A custom widget: a Lissajous figure drawn with lines and circles,
/// turning slowly.
const Lissajous = struct {
    pub const State = struct {
        phase: f32 = 0,
        last_ns: ?u64 = null,
    };

    pub fn layout(_: *const Lissajous, _: *facet.Node, c: facet.Constraints) facet.Size {
        return c.constrain(.{ .w = if (c.boundedWidth()) c.max_w else 480, .h = 220 });
    }

    pub fn paint(_: *const Lissajous, n: *facet.Node, p: *facet.Painter) void {
        const st = n.state(@This().State);
        if (st.last_ns) |prev| {
            const dt: f32 = @floatCast(@as(f64, @floatFromInt(n.ui.now_ns -| prev)) / std.time.ns_per_s);
            st.phase = @mod(st.phase + dt * 0.5, std.math.tau);
        }
        st.last_ns = n.ui.now_ns;
        n.ui.needs_frame = true;

        const t = &n.ui.theme;
        const c = p.canvas();
        const w = n.size.w;
        const h = n.size.h;
        c.fillRoundedRect(.{ .x = 0, .y = 0, .w = w, .h = h }, .all(12), t.surface_container);

        // A grid behind.
        var x: f32 = 24;
        while (x < w) : (x += 24) c.fillRect(.{ .x = x, .y = 0, .w = 1, .h = h }, t.outline_variant.withAlpha(0.5));
        var y: f32 = 24;
        while (y < h) : (y += 24) c.fillRect(.{ .x = 0, .y = y, .w = w, .h = 1 }, t.outline_variant.withAlpha(0.5));

        const steps = 400;
        var points: [steps]facet.Point = undefined;
        const cx_ = w / 2;
        const cy = h / 2;
        const rx = @min(w, h * 2) * 0.4;
        const ry = h * 0.4;
        for (&points, 0..) |*pt, i| {
            const a = @as(f32, @floatFromInt(i)) / steps * std.math.tau;
            pt.* = .{ cx_ + rx * @sin(3 * a + st.phase), cy + ry * @sin(2 * a) };
        }
        c.strokePolyline(&points, true, 2.5, t.primary);

        // Dots travelling along it.
        for (0..6) |i| {
            const a = st.phase * 2 + @as(f32, @floatFromInt(i)) * std.math.tau / 6;
            const pt: facet.Point = .{ cx_ + rx * @sin(3 * a + st.phase), cy + ry * @sin(2 * a) };
            c.fillCircle(pt, 6, t.@"error");
            c.strokeCircle(pt, 10, 2, t.@"error".withAlpha(0.4));
        }
        c.strokeRoundedRect(.{ .x = 0.5, .y = 0.5, .w = w - 1, .h = h - 1 }, .all(12), 1, t.outline_variant);
    }
};
