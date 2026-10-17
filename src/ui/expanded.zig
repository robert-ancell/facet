//! Expanded: a share of the space the other children of a row or column
//! leave.

const widget = @import("widget.zig");

const Widget = widget.Widget;

/// In a row or column, gives the child a share of the space the others
/// leave (by `flex`). Where the space is unbounded it is like any child.
pub const Expanded = struct {
    flex: f32 = 1,
    child: Widget,
};
