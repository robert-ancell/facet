//! Empty: nothing, as small as allowed.

const geometry = @import("geometry.zig");
const widget = @import("widget.zig");

const Size = geometry.Size;
const Constraints = geometry.Constraints;
const Node = widget.Node;

/// Nothing, as small as allowed.
pub const Empty = struct {
    pub fn layout(_: *const Empty, _: *Node, c: Constraints) Size {
        return c.smallest();
    }
};
