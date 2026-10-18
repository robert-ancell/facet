//! ProgressBar: Material 3's linear progress indicator, determinate (when
//! `value` is given, from 0 to 1) or indeterminate (when `value` is null,
//! animating a bar along the track).

const std = @import("std");
const gfx = @import("gfx");
const geometry = @import("geometry.zig");
const widget = @import("widget.zig");
const painter = @import("painter.zig");

const Color = gfx.Color;

pub const ProgressBar = struct {
    /// From 0 to 1, or null for an indeterminate animation.
    value: ?f32 = null,
    height: f32 = 6,
    color: ?Color = null,
    track_color: ?Color = null,

    pub fn layout(self: *const ProgressBar, _: *widget.Node, c: geometry.Constraints) geometry.Size {
        return c.constrain(.{
            .w = if (std.math.isFinite(c.max_w)) c.max_w else 200,
            .h = self.height,
        });
    }

    pub fn minSize(self: *const ProgressBar, _: *widget.Node, c: geometry.Constraints) geometry.Size {
        return c.constrain(.{
            .w = self.height * 4,
            .h = self.height,
        });
    }

    pub fn paint(self: *const ProgressBar, n: *widget.Node, p: *painter.Painter) void {
        const t = n.theme();
        const c = p.canvas();
        const w = n.size.w;
        const h = n.size.h;
        if (w <= 0 or h <= 0) return;
        const radius: gfx.Radii = .all(h / 2);
        const active_color = self.color orelse t.primary;
        const track = self.track_color orelse t.surface_container_highest;
        c.fillRoundedRect(.{ .x = 0, .y = 0, .w = w, .h = h }, radius, track);

        if (self.value) |v| {
            const k = std.math.clamp(if (std.math.isFinite(v)) v else 0, 0, 1);
            if (k > 0) {
                const fill_w = @min(w, @max(w * k, h));
                c.fillRoundedRect(.{ .x = 0, .y = 0, .w = fill_w, .h = h }, radius, active_color);
            }
        } else {
            n.ui.needs_frame = true;
            const period_ns = 1500 * std.time.ns_per_ms;
            const phase: f32 = @floatCast(@as(f64, @floatFromInt(n.ui.now_ns % period_ns)) / period_ns);
            const seg_w = @max(w * (0.25 + 0.25 * @sin(phase * std.math.pi)), h);
            const start = (w + seg_w) * phase - seg_w;
            const x0 = std.math.clamp(start, 0, w);
            const x1 = std.math.clamp(start + seg_w, 0, w);
            if (x1 > x0) {
                c.fillRoundedRect(.{ .x = x0, .y = 0, .w = @min(w - x0, @max(x1 - x0, h)), .h = h }, radius, active_color);
            }
        }
    }
};
