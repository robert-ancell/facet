//! 2D: a widget of the app's own, painting shapes and lines on the canvas.

const std = @import("std");
const kete = @import("kete");
const common = @import("common.zig");

pub const State = struct {};

pub fn build(cx: *kete.BuildContext, _: *State) kete.Widget {
    const painting = common.section(cx, "Custom painting", "A widget of its own, painting shapes and lines on the canvas each frame", &.{
        // Described to screen readers as what it is.
        cx.make(kete.Accessible{ .role = .img, .label = "A Lissajous figure", .roledescription = "animation", .description = "Lines and circles tracing a figure that turns", .child = cx.make(Lissajous{}) }),
    });
    return common.page(cx, &.{painting});
}

/// A custom widget: a Lissajous figure drawn with lines and circles,
/// turning slowly.
const Lissajous = struct {
    pub const State = struct {
        phase: f32 = 0,
        last_ns: ?u64 = null,
    };

    pub fn layout(_: *const Lissajous, _: *kete.WidgetNode, c: kete.Constraints) kete.Size {
        return c.constrain(.{ .w = if (c.boundedWidth()) c.max_w else 480, .h = 220 });
    }

    pub fn paint(_: *const Lissajous, n: *kete.WidgetNode, p: *kete.Painter) void {
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
        var points: [steps]kete.Point = undefined;
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
            const pt: kete.Point = .{ cx_ + rx * @sin(3 * a + st.phase), cy + ry * @sin(2 * a) };
            c.fillCircle(pt, 6, t.@"error");
            c.strokeCircle(pt, 10, 2, t.@"error".withAlpha(0.4));
        }
        c.strokeRoundedRect(.{ .x = 0.5, .y = 0.5, .w = w - 1, .h = h - 1 }, .all(12), 1, t.outline_variant);
    }
};
