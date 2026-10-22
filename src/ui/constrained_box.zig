//! ConstrainedBox: constraints of its own for its child.

const geometry = @import("geometry.zig");
const widget = @import("widget.zig");

const Size = geometry.Size;
const Constraints = geometry.Constraints;
const Widget = widget.Widget;
const Node = widget.WidgetNode;

/// Adds constraints of its own to the child's (within its parent's).
pub const ConstrainedBox = struct {
    /// What it adds to the parent's.
    constraints: Constraints,
    /// The widget in it.
    child: ?Widget = null,

    pub fn layout(self: *const ConstrainedBox, n: *Node, c: Constraints) Size {
        const inner = c.enforce(self.constraints.sanitize());
        if (n.childCount() > 0) return n.child(0).layout(inner);
        return inner.smallest();
    }

    pub fn minSize(self: *const ConstrainedBox, n: *Node, c: Constraints) Size {
        const inner = c.enforce(self.constraints.sanitize());
        if (n.childCount() > 0) return n.child(0).minSize(inner);
        return inner.smallest();
    }
};
