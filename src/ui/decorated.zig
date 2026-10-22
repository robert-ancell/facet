//! Decorated: a rounded rectangle behind the child, filled, outlined or
//! both.

const gfx = @import("gfx");
const geometry = @import("geometry.zig");
const widget = @import("widget.zig");
const Painter = @import("painter.zig").Painter;

const Point = geometry.Point;
const Widget = widget.Widget;
const Node = widget.WidgetNode;

/// An outline.
pub const Border = struct {
    /// Its thickness in pixels.
    width: f32 = 1,
    /// Its colour.
    color: gfx.Color,
};

/// A rounded rectangle behind the child: filled, outlined, or both. It is
/// the child's size, or as big as allowed without one.
pub const Decorated = struct {
    /// The fill (none, if null).
    color: ?gfx.Color = null,
    /// The outline (none, if null).
    border: ?Border = null,
    /// The corners' radii.
    radius: gfx.CornerRadii = .{},
    /// The widget in it.
    child: ?Widget = null,

    pub fn paint(self: *const Decorated, n: *Node, p: *Painter) void {
        const c = p.canvas();
        const r: gfx.Rect = .{ .x = 0, .y = 0, .w = n.size.w, .h = n.size.h };
        if (self.color) |col| c.fillRoundedRect(r, self.radius, col);
        if (self.border) |b| c.strokeRoundedRect(r, self.radius, b.width, b.color);
    }

    /// Filled, it takes the pointer (what is under it cannot be clicked).
    pub fn hitTest(self: *const Decorated, _: *Node, _: Point) bool {
        return if (self.color) |col| col.a > 0 else false;
    }
};
