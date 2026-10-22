//! Expanded: a share of the space the other children of a row or column
//! leave.

const widget = @import("widget.zig");

const Widget = widget.Widget;

/// In a row or column, gives the child a share of the space the others
/// leave (by `flex`). Where the space is unbounded it is like any child.
///
/// ![The Expanded example](images/Expanded.png)
///
/// (`box` stands for any widget: a labelled rounded rectangle.)
///
/// ```zig
/// return cx.make(facet.SizedBox{ .width = 360, .child = cx.make(facet.Row{ .spacing = 8, .children = cx.makeAll(.{
///     box(cx, "Fixed", 72, 48),
///     facet.Expanded{ .child = box(cx, "Expanded", 0, 48) },
///     facet.Expanded{ .flex = 2, .child = box(cx, "Twice as much", 0, 48) },
/// }) }) });
/// ```
pub const Expanded = struct {
    /// Its share of the space, relative to the other `Expanded` children (0: none).
    flex: f32 = 1,
    /// The widget in it.
    child: Widget,
};
