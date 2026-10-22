//! Badge: a status dot or count indicator, shown standalone or on the
//! top-right corner of a `child` widget, as Material 3 has it: a 6 px dot
//! inside the corner, or a pill at least 16 px across hanging over it (its
//! left edge 12 px in from the child's right edge, its bottom 14 px below
//! the child's top). The child's size is the whole widget's: the pill
//! reaches beyond it.

const gfx = @import("gfx");
const geometry = @import("geometry.zig");
const widget = @import("widget.zig");
const Align = @import("align.zig").Align;
const ConstrainedBox = @import("constrained_box.zig").ConstrainedBox;
const RoundedBox = @import("rounded_box.zig").RoundedBox;
const Padding = @import("padding.zig").Padding;
const SizedBox = @import("sized_box.zig").SizedBox;
const Text = @import("text.zig").Text;

const Size = geometry.Size;
const Constraints = geometry.Constraints;
const Widget = widget.Widget;
const Context = widget.BuildContext;
const Node = widget.WidgetNode;
const Color = gfx.Color;

/// A badge: a count, a label or a dot on the corner of a widget.
///
/// ![The Badge example](images/Badge.png)
///
/// ```zig
/// return cx.make(kete.Row{ .fill = false, .spacing = 24, .children = cx.makeAll(.{
///     kete.Badge{ .count = 3, .child = cx.make(kete.Icon{ .icon = .mail }) },
///     kete.Badge{ .count = 128, .child = cx.make(kete.Icon{ .icon = .notifications }) },
///     kete.Badge{ .label = "", .child = cx.make(kete.Icon{ .icon = .chat }) },
/// }) });
/// ```
pub const Badge = struct {
    /// When set, shows the count (or "99+" above 99); when null and `label`
    /// is empty, shows a small 6px status dot.
    count: ?u32 = null,
    /// Text to show instead of a count.
    label: []const u8 = "",
    /// Whether the badge is shown (if not, only the child).
    show: bool = true,
    /// The badge's fill (the theme's error colour if not given).
    color: ?Color = null,
    /// The text on it (the theme's on-error colour if not given).
    text_color: ?Color = null,
    /// What the badge is on the corner of.
    child: ?Widget = null,

    /// The dot's size, and the pill's least width and height.
    pub const dot_size = 6;
    pub const pill_size = 16;

    pub fn build(self: *const Badge, cx: *Context) Widget {
        if (!self.show) return self.child orelse cx.make(SizedBox.empty);
        const pill = self.makePill(cx);
        const child = self.child orelse return pill;
        return cx.make(BadgedChild{ .children = &.{ child, pill } });
    }

    fn makePill(self: *const Badge, cx: *Context) Widget {
        const t = cx.theme();
        const bg = self.color orelse t.@"error";
        const fg = self.text_color orelse t.on_error;
        const text = if (self.label.len > 0)
            self.label
        else if (self.count) |n|
            (if (n > 99) "99+" else cx.fmt("{d}", .{n}))
        else
            "";

        if (text.len == 0) {
            return cx.make(RoundedBox{
                .color = bg,
                .radius = .all(dot_size / 2),
                .child = cx.make(SizedBox{ .width = dot_size, .height = dot_size }),
            });
        }

        return cx.make(RoundedBox{
            .color = bg,
            .radius = .all(pill_size / 2),
            .child = cx.make(ConstrainedBox{
                .constraints = .{ .min_w = pill_size, .min_h = pill_size },
                .child = cx.make(Padding{
                    .padding = .symmetric(4, 0),
                    .child = cx.make(Align{ .width_factor = 1, .height_factor = 1, .child = cx.make(Text{
                        .text = text,
                        .style = .{ .size = 11, .color = fg },
                        .wrap = false,
                    }) }),
                }),
            }),
        });
    }
};

const BadgedChild = struct {
    children: []const Widget,

    /// The child as it would be without the badge; the badge on its
    /// top-right corner: the dot inside it, the pill hanging over it.
    pub fn layout(_: *const BadgedChild, n: *Node, c: Constraints) Size {
        if (n.childCount() < 2) return c.smallest();
        const ch = n.child(0);
        const pill = n.child(1);
        const cs = ch.layout(c);
        const ps = pill.layout(.unbounded);
        ch.place(0, 0);
        if (ps.w > Badge.dot_size + 0.5) {
            pill.place(cs.w - 12, 14 - ps.h);
        } else {
            pill.place(cs.w - ps.w, 0);
        }
        pill.overhangs = true;
        return cs;
    }

    pub fn minSize(_: *const BadgedChild, n: *Node, c: Constraints) Size {
        if (n.childCount() < 2) return c.smallest();
        return n.child(0).minSize(c);
    }
};
