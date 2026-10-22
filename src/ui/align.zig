//! Align: places the child within itself.

const geometry = @import("geometry.zig");
const widget = @import("widget.zig");

const Size = geometry.Size;
const Constraints = geometry.Constraints;
const Alignment = geometry.Alignment;
const Widget = widget.Widget;
const Node = widget.WidgetNode;

/// Places the child within itself. It is as big as allowed (or a
/// multiple of the child's size, with the factors), or the child's size
/// where unbounded.
///
/// ![The Align example](images/Align.png)
///
/// (`box` stands for any widget: a labelled rounded rectangle.)
///
/// ```zig
/// return cx.make(facet.SizedBox{ .width = 240, .height = 120, .child = cx.make(facet.RoundedBox{
///     .border_color = cx.theme().outline,
///     .child = cx.make(facet.Align{ .alignment = .bottom_right, .child = box(cx, "Corner", 72, 36) }),
/// }) });
/// ```
pub const Align = struct {
    alignment: Alignment = .center,
    width_factor: ?f32 = null,
    height_factor: ?f32 = null,
    child: ?Widget = null,

    /// `child` in the middle of the space.
    pub fn center(child: Widget) Align {
        return .{ .alignment = .center, .child = child };
    }

    pub fn layout(self: *const Align, n: *Node, c: Constraints) Size {
        const s = if (n.childCount() > 0) n.child(0).layout(c.loosen()) else Size{};
        const size = c.constrain(.{
            .w = if (self.width_factor) |f| s.w * f else if (c.boundedWidth()) c.max_w else s.w,
            .h = if (self.height_factor) |f| s.h * f else if (c.boundedHeight()) c.max_h else s.h,
        });
        if (n.childCount() > 0) {
            const at = self.alignment.place(size, s);
            n.child(0).place(at[0], at[1]);
        }
        return size;
    }

    pub fn minSize(self: *const Align, n: *Node, c: Constraints) Size {
        const s = if (n.childCount() > 0) n.child(0).minSize(c.loosen()) else Size{};
        return c.constrain(.{
            .w = if (self.width_factor) |f| s.w * f else s.w,
            .h = if (self.height_factor) |f| s.h * f else s.h,
        });
    }
};
