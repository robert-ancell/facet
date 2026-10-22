//! PillBar and PillButton: a segmented pill bar of connected buttons,
//! for choosing between options.

const a11y = @import("accessibility.zig");
const gfx = @import("gfx");
const icons = @import("icons");
const widget = @import("widget.zig");
const Align = @import("align.zig").Align;
const Decorated = @import("decorated.zig").Decorated;
const Icon = @import("icon.zig").Icon;
const PointerInteraction = @import("pressable.zig").PointerInteraction;
const Padding = @import("padding.zig").Padding;
const Painter = @import("painter.zig").Painter;
const Pressable = @import("pressable.zig").Pressable;
const Row = @import("flex.zig").Row;
const SizedBox = @import("sized_box.zig").SizedBox;
const Text = @import("text.zig").Text;

const Widget = widget.Widget;
const Context = widget.Context;
const Node = widget.WidgetNode;
const Callback = widget.Callback;

/// A connected segmented pill bar: a `Row` of `PillButton` segments with a
/// rounded outline around the bar and vertical dividers between segments.
pub const PillBar = struct {
    children: []const Widget,

    pub fn build(self: *const PillBar, cx: *Context) Widget {
        return cx.make(Row{ .main_axis_size = .min, .children = self.children });
    }

    pub fn paintOver(_: *const PillBar, n: *Node, p: *Painter) void {
        const t = n.theme();
        const c = p.canvas();
        const r: f32 = PillButton.height / 2;
        c.strokeRoundedRect(.{ .x = 0, .y = 0, .w = n.size.w, .h = n.size.h }, .all(r), 1, t.outline);
        if (n.children.items.len > 0) {
            const row = n.children.items[0];
            for (row.children.items[1..]) |seg| {
                c.fillRect(.{ .x = seg.offset[0] - 0.5, .y = 0, .w = 1, .h = n.size.h }, t.outline);
            }
        }
    }
};

/// One segment of a `PillBar`.
pub const PillButton = struct {
    label: []const u8,
    icon: ?icons.IconName = null,
    selected: bool,
    first: bool = false,
    last: bool = false,
    on_press: ?Callback = null,

    pub const State = struct {
        interaction: PointerInteraction = .{},
    };

    pub const height = 36;

    pub fn accessible(self: *const PillButton, _: *Node) ?a11y.Info {
        return .{ .role = .button, .label = self.label, .pressed = .of(self.selected), .activate = self.on_press, .disabled = self.on_press == null };
    }

    pub fn build(self: *const PillButton, cx: *Context, state: *State) Widget {
        const t = cx.theme();
        const color = if (self.selected) t.on_surface else t.on_surface_variant;
        const bg: ?gfx.Color = if (self.selected) t.secondary_container else if (state.interaction.hovered) t.on_surface.withAlpha(0.08) else null;
        const r: f32 = height / 2;
        const radius: gfx.CornerRadii = .{
            .tl = if (self.first) r else 0,
            .bl = if (self.first) r else 0,
            .tr = if (self.last) r else 0,
            .br = if (self.last) r else 0,
        };
        const label_text = cx.make(Text{
            .text = self.label,
            .style = .{ .size = 16, .color = color },
            .wrap = false,
        });
        const inner = if (self.icon) |ic|
            cx.make(Row{
                .main_axis_size = .min,
                .cross_axis_alignment = .center,
                .spacing = 8,
                .children = cx.makeAll(.{
                    Icon{ .icon = ic, .size = 18, .color = color },
                    label_text,
                }),
            })
        else
            label_text;
        return cx.make(Pressable{ .on_press = self.on_press, .interaction = &state.interaction, .child = cx.make(Decorated{
            .color = bg,
            .radius = radius,
            .child = cx.make(SizedBox{ .height = height, .child = cx.make(Padding{
                .padding = .symmetric(18, 0),
                .child = cx.make(Align{ .width_factor = 1, .height_factor = 1, .child = inner }),
            }) }),
        }) });
    }
};
