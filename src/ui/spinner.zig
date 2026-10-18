//! Spinner: Material 3's indeterminate circular progress indicator.

const std = @import("std");
const gfx = @import("gfx");
const widget = @import("widget.zig");
const geometry = @import("geometry.zig");
const painter = @import("painter.zig");

const Color = gfx.Color;

/// Material's indeterminate circular progress indicator: an arc that turns
/// as it grows and shrinks, for work that takes a while. It asks for frames
/// while it is shown.
pub const Spinner = struct {
    /// Its diameter.
    size: f32 = 48,
    /// The theme's primary colour if not given.
    color: ?Color = null,

    pub fn layout(self: *const Spinner, _: *widget.Node, c: geometry.Constraints) geometry.Size {
        return c.constrain(.{ .w = self.size, .h = self.size });
    }

    pub fn paint(self: *const Spinner, n: *widget.Node, p: *painter.Painter) void {
        n.ui.needs_frame = true;
        const t: f32 = @floatCast(@as(f64, @floatFromInt(n.ui.now_ns % (12 * std.time.ns_per_s))) / std.time.ns_per_s);
        const r = @min(n.size.w, n.size.h) / 2;
        const width = @max(r / 6, 2);
        const radius = r - width / 2;
        const tau = std.math.tau;
        // Turning once every 1.5 seconds; growing from a tenth of a turn to
        // three quarters and back every 1.3.
        const phase = @sin(t / 1.3 * tau) * 0.5 + 0.5;
        const sweep = (0.1 + 0.65 * phase) * tau;
        const start = t / 1.5 * tau + phase * 0.5 * tau;
        var points: [33]gfx.Point = undefined;
        for (&points, 0..) |*pt, i| {
            const a = start + sweep * @as(f32, @floatFromInt(i)) / 32;
            pt.* = .{ n.size.w / 2 + radius * @cos(a), n.size.h / 2 + radius * @sin(a) };
        }
        p.canvas().strokePolyline(&points, false, width, self.color orelse n.theme().primary);
    }
};
