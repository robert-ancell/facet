//! Overlay: layers over each other.

const geometry = @import("geometry.zig");
const widget = @import("widget.zig");

const Size = geometry.Size;
const Constraints = geometry.Constraints;
const Widget = widget.Widget;
const Node = widget.WidgetNode;

/// Layers over each other, filling it (later ones on top, and first to
/// get the pointer). Each layer positions its content itself (with
/// `Align`, `Padding` and so on).
pub const Overlay = struct {
    children: []const Widget = &.{},

    pub fn layout(_: *const Overlay, n: *Node, c: Constraints) Size {
        var size = c.biggest();
        // Unbounded: as big as the biggest layer wants.
        if (!c.boundedWidth() or !c.boundedHeight()) {
            var want: Size = .{};
            for (n.children.items) |ch| {
                const s = ch.layout(c.loosen());
                want = .{ .w = @max(want.w, s.w), .h = @max(want.h, s.h) };
            }
            size = c.constrain(.{ .w = if (c.boundedWidth()) c.max_w else want.w, .h = if (c.boundedHeight()) c.max_h else want.h });
        }
        for (n.children.items) |ch| _ = ch.layout(.tight(size));
        return size;
    }

    pub fn minSize(_: *const Overlay, n: *Node, c: Constraints) Size {
        var want: Size = .{};
        for (n.children.items) |ch| {
            const s = ch.minSize(c.loosen());
            want = .{ .w = @max(want.w, s.w), .h = @max(want.h, s.h) };
        }
        return c.constrain(want);
    }
};
