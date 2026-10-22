//! Tooltip: a plain tooltip, shown above (or below, when near
//! the top of the window) its `child` while the pointer hovers over it.

const std = @import("std");
const geometry = @import("geometry.zig");
const widget = @import("widget.zig");
const RoundedBox = @import("rounded_box.zig").RoundedBox;
const Padding = @import("padding.zig").Padding;
const Text = @import("text.zig").Text;

const Point = geometry.Point;
const Size = geometry.Size;
const Rect = geometry.Rect;
const Constraints = geometry.Constraints;
const Widget = widget.Widget;
const Context = widget.BuildContext;
const Node = widget.WidgetNode;
const Event = widget.Event;

/// A plain tooltip: a short hint shown while the pointer is over
/// the child.
///
/// ![The Tooltip example](images/Tooltip.png)
///
/// ```zig
/// return cx.make(kete.Tooltip{
///     .text = "Add to favourites",
///     .child = cx.make(kete.IconButton{ .icon = .favorite, .variant = .tonal, .on_press = .of(state, State.save) }),
/// });
/// ```
pub const Tooltip = struct {
    /// What the tooltip says.
    text: []const u8,
    /// What the tooltip is for: it is shown while the pointer is over it.
    child: ?Widget = null,

    pub fn layout(_: *const Tooltip, n: *Node, c: Constraints) Size {
        if (n.childCount() == 0) return c.smallest();
        return n.child(0).layout(c);
    }

    pub fn minSize(_: *const Tooltip, n: *Node, c: Constraints) Size {
        if (n.childCount() == 0) return c.smallest();
        return n.child(0).minSize(c);
    }

    /// Having an `event` handler puts `Tooltip` in `WindowUi.hovered` whenever
    /// the pointer is over its child, without consuming any events.
    pub fn event(_: *const Tooltip, _: *Node, _: Event) bool {
        return false;
    }
};

/// The floating label shown by `WindowUi` for the hovered `Tooltip`.
pub const Bubble = struct {
    text: []const u8,

    pub fn build(self: *const Bubble, cx: *Context) Widget {
        const t = cx.theme();
        return cx.make(RoundedBox{
            .color = t.surface_container_highest,
            .border_color = t.outline_variant,
            .radius = .all(6),
            .child = cx.make(Padding{
                .padding = .symmetric(10, 6),
                .child = cx.make(Text{
                    .text = self.text,
                    .style = .{ .size = 12, .color = t.on_surface },
                    .wrap = false,
                }),
            }),
        });
    }
};

/// The space between a tooltip and what it is for.
pub const gap = 6;

/// Places a tooltip bubble of `size` above `target` (or below it when there
/// is no room above), clamped to `window`.
pub fn place(window: Size, target: Rect, size: Size) Point {
    const margin = 4;
    const x_ideal = target.x + (target.w - size.w) / 2;
    const x = std.math.clamp(x_ideal, margin, @max(margin, window.w - size.w - margin));
    const above = target.y - size.h - gap;
    const below = target.y + target.h + gap;
    const y = if (above >= margin)
        above
    else if (below + size.h + margin <= window.h)
        below
    else
        std.math.clamp(above, 0, @max(0, window.h - size.h));
    return .{ @round(x), @round(y) };
}
