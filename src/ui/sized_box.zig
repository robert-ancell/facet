//! SizedBox: a box of a given width and/or height.

const geometry = @import("geometry.zig");
const widget = @import("widget.zig");

const Size = geometry.Size;
const Constraints = geometry.Constraints;
const Widget = widget.Widget;
const Node = widget.WidgetNode;

/// A box of a given width and/or height (within its constraints); the
/// child, if any, is made to fit it.
pub const SizedBox = struct {
    width: ?f32 = null,
    height: ?f32 = null,
    child: ?Widget = null,

    /// Nothing, as small as allowed.
    pub const empty: SizedBox = .{};

    pub fn layout(self: *const SizedBox, n: *Node, c: Constraints) Size {
        var own: Constraints = .{};
        if (self.width) |w| own = .{ .min_w = w, .max_w = w, .min_h = own.min_h, .max_h = own.max_h };
        if (self.height) |h| own = .{ .min_w = own.min_w, .max_w = own.max_w, .min_h = h, .max_h = h };
        const inner = c.enforce(own);
        if (n.childCount() > 0) return n.child(0).layout(inner);
        return inner.constrain(.{ .w = self.width orelse 0, .h = self.height orelse 0 });
    }

    pub fn minSize(self: *const SizedBox, n: *Node, c: Constraints) Size {
        var own: Constraints = .{};
        if (self.width) |w| own = .{ .min_w = w, .max_w = w, .min_h = own.min_h, .max_h = own.max_h };
        if (self.height) |h| own = .{ .min_w = own.min_w, .max_w = own.max_w, .min_h = h, .max_h = h };
        const inner = c.enforce(own);
        if (n.childCount() > 0) return n.child(0).minSize(inner);
        return inner.constrain(.{ .w = self.width orelse 0, .h = self.height orelse 0 });
    }
};
