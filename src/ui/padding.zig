//! Padding: space around the child.

const geometry = @import("geometry.zig");
const widget = @import("widget.zig");

const Size = geometry.Size;
const Constraints = geometry.Constraints;
const Insets = geometry.Insets;
const Widget = widget.Widget;
const Node = widget.WidgetNode;

/// Space around the child.
pub const Padding = struct {
    padding: Insets,
    child: ?Widget = null,

    pub fn layout(self: *const Padding, n: *Node, c: Constraints) Size {
        const p = self.padding;
        if (n.childCount() == 0) return c.constrain(.{ .w = p.horizontal(), .h = p.vertical() });
        const ch = n.child(0);
        const s = ch.layout(c.deflate(p));
        ch.place(p.left, p.top);
        return c.constrain(.{ .w = s.w + p.horizontal(), .h = s.h + p.vertical() });
    }

    pub fn minSize(self: *const Padding, n: *Node, c: Constraints) Size {
        const p = self.padding;
        if (n.childCount() == 0) return c.constrain(.{ .w = p.horizontal(), .h = p.vertical() });
        const s = n.child(0).minSize(c.deflate(p));
        return c.constrain(.{ .w = s.w + p.horizontal(), .h = s.h + p.vertical() });
    }
};
