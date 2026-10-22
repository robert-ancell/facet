//! Badge: Material 3's status dot or count indicator, shown standalone or
//! at the top-right corner of a `child` widget.

const gfx = @import("gfx");
const geometry = @import("geometry.zig");
const widget = @import("widget.zig");
const Align = @import("align.zig").Align;
const ConstrainedBox = @import("constrained_box.zig").ConstrainedBox;
const Decorated = @import("decorated.zig").Decorated;
const Padding = @import("padding.zig").Padding;
const SizedBox = @import("sized_box.zig").SizedBox;
const Text = @import("text.zig").Text;

const Size = geometry.Size;
const Constraints = geometry.Constraints;
const Widget = widget.Widget;
const Context = widget.Context;
const Node = widget.WidgetNode;
const Color = gfx.Color;

/// Material 3's badge: a count, a label or a dot on the corner of a widget.
pub const Badge = struct {
    /// When set, shows the count (or "99+" above 99); when null and `label`
    /// is empty, shows a small 8px status dot.
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
            return cx.make(Decorated{
                .color = bg,
                .radius = .all(4),
                .child = cx.make(SizedBox{ .width = 8, .height = 8 }),
            });
        }

        return cx.make(Decorated{
            .color = bg,
            .radius = .all(9),
            .child = cx.make(ConstrainedBox{
                .constraints = .{ .min_w = 18, .min_h = 18 },
                .child = cx.make(Padding{
                    .padding = .symmetric(5, 1),
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

    pub fn layout(_: *const BadgedChild, n: *Node, c: Constraints) Size {
        if (n.childCount() < 2) return c.smallest();
        const ch = n.child(0);
        const pill = n.child(1);
        const cs = ch.layout(c.loosen());
        const ps = pill.layout(c.loosen());
        const w = @max(cs.w, ps.w);
        const h = @max(cs.h, ps.h);
        ch.place(0, @max(0, h - cs.h));
        pill.place(@max(0, w - ps.w), 0);
        return c.constrain(.{ .w = w, .h = h });
    }

    pub fn minSize(_: *const BadgedChild, n: *Node, c: Constraints) Size {
        if (n.childCount() < 2) return c.smallest();
        const cs = n.child(0).minSize(c.loosen());
        const ps = n.child(1).minSize(c.loosen());
        return c.constrain(.{ .w = @max(cs.w, ps.w), .h = @max(cs.h, ps.h) });
    }
};
