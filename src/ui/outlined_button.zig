//! OutlinedButton: Material 3's outlined button, with a label, an icon or
//! both.

const widget = @import("widget.zig");
const Center = @import("center.zig").Center;
const ConstrainedBox = @import("constrained_box.zig").ConstrainedBox;
const Decorated = @import("decorated.zig").Decorated;
const Interaction = @import("pressable.zig").Interaction;
const Padding = @import("padding.zig").Padding;
const Pressable = @import("pressable.zig").Pressable;
const Row = @import("flex.zig").Row;
const Text = @import("text.zig").Text;
const Icon = @import("icon.zig").Icon;

const Widget = widget.Widget;
const Context = widget.Context;
const Callback = widget.Callback;

/// A pill-shaped button with an outline: a `Pressable` around a
/// `Decorated` outline (with Material's hover and press tint), sized and
/// padded, with its label in the middle.
pub const OutlinedButton = struct {
    /// The label (or give a `child` instead).
    label: []const u8 = "",
    /// An icon before the label (or alone, without one).
    icon: ?@import("icons").Icon = null,
    /// An icon after the label (for menu or forward buttons).
    trailing_icon: ?@import("icons").Icon = null,
    child: ?Widget = null,
    /// Destructive action (e.g. delete or remove): shown in the theme's
    /// error colour when enabled.
    destructive: bool = false,
    /// Without it the button is disabled.
    on_press: ?Callback = null,

    pub const State = struct {
        interaction: Interaction = .{},
    };

    pub const height = 40;
    pub const padding = 24;
    pub const icon_size = 18;

    pub fn build(self: *const OutlinedButton, cx: *Context, state: *State) Widget {
        const t = cx.theme();
        const enabled = self.on_press != null;
        const i = state.interaction;
        // State layers: the label's colour over the button.
        const layer: f32 = if (!enabled) 0 else if (i.pressed) 0.10 else if (i.hovered) 0.08 else 0;
        const accent = if (self.destructive) t.@"error" else t.primary;
        const label_color = if (enabled) accent else t.on_surface.withAlpha(0.38);
        const border = if (enabled) t.outline else t.on_surface.withAlpha(0.12);
        const label = cx.make(Text{
            .text = self.label,
            .style = .{ .size = t.label_size, .color = label_color },
            .wrap = false,
        });
        const content = self.child orelse if (self.icon != null and self.trailing_icon != null) blk: {
            const lead = cx.make(Icon{ .icon = self.icon.?, .size = icon_size, .color = label_color });
            const trail = cx.make(Icon{ .icon = self.trailing_icon.?, .size = icon_size, .color = label_color });
            break :blk if (self.label.len == 0)
                cx.make(Row{ .spacing = 8, .main_axis_size = .min, .cross_axis_alignment = .center, .children = &.{ lead, trail } })
            else
                cx.make(Row{ .spacing = 8, .main_axis_size = .min, .cross_axis_alignment = .center, .children = &.{ lead, label, trail } });
        } else if (self.icon) |which| blk: {
            const glyph = cx.make(Icon{ .icon = which, .size = icon_size, .color = label_color });
            break :blk if (self.label.len == 0) glyph else cx.make(Row{ .spacing = 8, .main_axis_size = .min, .cross_axis_alignment = .center, .children = &.{ glyph, label } });
        } else if (self.trailing_icon) |which| blk: {
            const glyph = cx.make(Icon{ .icon = which, .size = icon_size, .color = label_color });
            break :blk if (self.label.len == 0) glyph else cx.make(Row{ .spacing = 8, .main_axis_size = .min, .cross_axis_alignment = .center, .children = &.{ label, glyph } });
        } else label;
        const icon_only = self.child == null and self.label.len == 0 and (self.icon == null) != (self.trailing_icon == null);
        const h_pad: f32 = if (icon_only) (height - icon_size) / 2 else padding;
        return cx.make(Pressable{
            .on_press = self.on_press,
            .interaction = &state.interaction,
            .child = cx.make(Decorated{
                .color = if (layer > 0) accent.withAlpha(layer) else null,
                .border = .{ .width = 1, .color = border },
                .radius = .all(height / 2),
                .child = cx.make(ConstrainedBox{
                    .constraints = .{ .min_w = if (icon_only) height else 48, .min_h = height },
                    .child = cx.make(Padding{
                        .padding = .symmetric(h_pad, 0),
                        .child = cx.make(Center{ .width_factor = 1, .height_factor = 1, .child = content }),
                    }),
                }),
            }),
        });
    }
};
