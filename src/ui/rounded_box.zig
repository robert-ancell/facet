//! RoundedBox: a rounded rectangle behind the child, filled, outlined or
//! both.

const gfx = @import("gfx");
const geometry = @import("geometry.zig");
const widget = @import("widget.zig");
const Painter = @import("painter.zig").Painter;

const Point = geometry.Point;
const Widget = widget.Widget;
const Node = widget.WidgetNode;

/// A rounded rectangle behind the child: filled, outlined, or both. It is
/// the child's size, or as big as allowed without one.
pub const RoundedBox = struct {
    /// The fill (none, if null).
    color: ?gfx.Color = null,
    /// The colour of the outline (none, if null).
    border_color: ?gfx.Color = null,
    /// The thickness of the outline, in pixels.
    border_width: f32 = 1,
    /// The corners' radii.
    radius: gfx.CornerRadii = .{},
    /// The widget in it.
    child: ?Widget = null,

    pub fn paint(self: *const RoundedBox, n: *Node, p: *Painter) void {
        const c = p.canvas();
        const r: gfx.Rect = .{ .x = 0, .y = 0, .w = n.size.w, .h = n.size.h };
        if (self.color) |col| c.fillRoundedRect(r, self.radius, col);
        if (self.border_color) |col| c.strokeRoundedRect(r, self.radius, self.border_width, col);
    }

    /// Filled, it takes the pointer (what is under it cannot be clicked).
    pub fn hitTest(self: *const RoundedBox, _: *Node, _: Point) bool {
        return if (self.color) |col| col.a > 0 else false;
    }
};
