//! Chip: Material 3's compact pill element for filters, selections, tags
//! and quick actions, with optional leading icon, `selected` check state
//! and trailing remove button (`on_remove`).

const a11y = @import("accessibility.zig");
const Node = @import("widget.zig").WidgetNode;
const gfx = @import("gfx");
const icons = @import("icons");
const widget = @import("widget.zig");
const Align = @import("align.zig").Align;
const ConstrainedBox = @import("constrained_box.zig").ConstrainedBox;
const Decorated = @import("decorated.zig").Decorated;
const Border = @import("decorated.zig").Border;
const Icon = @import("icon.zig").Icon;
const PointerInteraction = @import("pressable.zig").PointerInteraction;
const Padding = @import("padding.zig").Padding;
const Pressable = @import("pressable.zig").Pressable;
const Row = @import("flex.zig").Row;
const SizedBox = @import("sized_box.zig").SizedBox;
const Text = @import("text.zig").Text;

const Widget = widget.Widget;
const Context = widget.BuildContext;
const Callback = widget.Callback;
const Color = gfx.Color;

/// Material 3's chip: a small pill to choose, filter or remove with.
pub const Chip = struct {
    /// The text of the chip.
    label: []const u8,
    /// An icon before the label.
    icon: ?icons.IconName = null,
    /// Whether it is shown as selected (and reported as pressed).
    selected: bool = false,
    /// Called when it is pressed; without it, it cannot be.
    on_press: ?Callback = null,
    /// When set, a trailing close button is shown that invokes `on_remove`.
    on_remove: ?Callback = null,

    pub const height = 32;

    pub const State = struct {
        interaction: PointerInteraction = .{},
        remove_interaction: PointerInteraction = .{},
    };

    pub fn accessible(self: *const Chip, _: *Node) ?a11y.Info {
        return .{ .role = .button, .label = self.label, .pressed = .of(self.selected), .activate = self.on_press, .disabled = self.on_press == null };
    }

    pub fn build(self: *const Chip, cx: *Context, state: *State) Widget {
        const t = cx.theme();
        const enabled = self.on_press != null or self.on_remove != null;
        const i = state.interaction;
        const layer: f32 = if (self.on_press == null) 0 else if (i.pressed) 0.12 else if (i.hovered) 0.08 else 0;

        const fg: Color = if (!enabled)
            t.on_surface.withAlpha(0.38)
        else if (self.selected)
            t.on_surface
        else
            t.on_surface_variant;

        const icon_color: Color = if (!enabled)
            t.on_surface.withAlpha(0.38)
        else if (self.selected)
            t.on_surface
        else
            t.primary;

        const base_bg: ?Color = if (self.selected)
            (if (enabled) t.secondary_container else t.on_surface.withAlpha(0.12))
        else
            null;

        const bg: ?Color = if (base_bg) |b|
            (if (layer > 0) blendOver(b, t.on_surface.withAlpha(layer)) else b)
        else if (layer > 0)
            t.on_surface.withAlpha(layer)
        else
            null;

        const border: ?Border = if (self.selected)
            null
        else
            .{ .width = 1, .color = if (enabled) t.outline else t.on_surface.withAlpha(0.12) };

        const leading_icon: ?icons.IconName = if (self.selected) .check else self.icon;

        var parts: [3]Widget = undefined;
        var count: usize = 0;

        if (leading_icon) |ic| {
            parts[count] = cx.make(Icon{ .icon = ic, .size = 18, .color = icon_color });
            count += 1;
        }
        parts[count] = cx.make(Text{
            .text = self.label,
            .style = .{ .size = t.label_size, .color = fg },
            .wrap = false,
        });
        count += 1;

        if (self.on_remove) |on_rem| {
            const rem_hover = state.remove_interaction.hovered or state.remove_interaction.pressed;
            parts[count] = cx.make(Pressable{
                .on_press = on_rem,
                .interaction = &state.remove_interaction,
                .focus_radius = 10,
                .child = cx.make(Decorated{
                    .color = if (rem_hover) t.on_surface.withAlpha(0.12) else null,
                    .radius = .all(10),
                    .child = cx.make(SizedBox{
                        .width = 20,
                        .height = 20,
                        .child = cx.make(Align.center(cx.make(Icon{ .icon = .close, .size = 16, .color = fg }))),
                    }),
                }),
            });
            count += 1;
        }

        const left_pad: f32 = if (leading_icon != null) 8 else 12;
        const right_pad: f32 = if (self.on_remove != null) 6 else 12;

        return cx.make(Pressable{
            .on_press = self.on_press,
            .interaction = &state.interaction,
            .focus_radius = 8,
            .child = cx.make(Decorated{
                .color = bg,
                .border = border,
                .radius = .all(8),
                .child = cx.make(ConstrainedBox{
                    .constraints = .{ .min_h = height },
                    .child = cx.make(Padding{
                        .padding = .{ .left = left_pad, .right = right_pad },
                        .child = cx.make(Align{ .width_factor = 1, .height_factor = 1, .child = cx.make(Row{
                            .spacing = 6,
                            .fill = false,
                            .cross_axis_alignment = .center,
                            .children = parts[0..count],
                        }) }),
                    }),
                }),
            }),
        });
    }
};

fn blendOver(base: Color, top: Color) Color {
    const a = top.a;
    return .{
        .r = base.r * (1 - a) + top.r * a,
        .g = base.g * (1 - a) + top.g * a,
        .b = base.b * (1 - a) + top.b * a,
        .a = base.a,
    };
}
