//! Material 3 button variants: `FilledButton` (high emphasis),
//! `TonalButton` (medium emphasis) and `TextButton` (low emphasis).
//! See `outlined_button.zig` for `OutlinedButton`.

const gfx = @import("gfx");
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
const Color = gfx.Color;

/// Material 3's filled button: a primary pill button for the main action on
/// a page or in a dialog.
pub const FilledButton = struct {
    label: []const u8 = "",
    icon: ?@import("icons").Icon = null,
    trailing_icon: ?@import("icons").Icon = null,
    child: ?Widget = null,
    on_press: ?Callback = null,

    pub const State = struct {
        interaction: Interaction = .{},
    };

    pub const height = 40;
    pub const padding = 24;
    pub const icon_size = 18;

    pub fn build(self: *const FilledButton, cx: *Context, state: *State) Widget {
        const t = cx.theme();
        const enabled = self.on_press != null;
        const i = state.interaction;
        const layer: f32 = if (!enabled) 0 else if (i.pressed) 0.12 else if (i.hovered) 0.08 else 0;
        const fg = if (enabled) t.on_primary else t.on_surface.withAlpha(0.38);
        const bg = if (enabled) blendOver(t.primary, t.on_primary.withAlpha(layer)) else t.on_surface.withAlpha(0.12);
        return buildButton(cx, &state.interaction, self.on_press, self.label, self.icon, self.trailing_icon, self.child, fg, bg, padding);
    }
};

/// Material 3's filled tonal button: a secondary container pill button with
/// medium emphasis between `FilledButton` and `OutlinedButton`.
pub const TonalButton = struct {
    label: []const u8 = "",
    icon: ?@import("icons").Icon = null,
    trailing_icon: ?@import("icons").Icon = null,
    child: ?Widget = null,
    on_press: ?Callback = null,

    pub const State = struct {
        interaction: Interaction = .{},
    };

    pub const height = 40;
    pub const padding = 24;
    pub const icon_size = 18;

    pub fn build(self: *const TonalButton, cx: *Context, state: *State) Widget {
        const t = cx.theme();
        const enabled = self.on_press != null;
        const i = state.interaction;
        const layer: f32 = if (!enabled) 0 else if (i.pressed) 0.12 else if (i.hovered) 0.08 else 0;
        const fg = if (enabled) t.on_surface else t.on_surface.withAlpha(0.38);
        const bg = if (enabled) blendOver(t.secondary_container, t.on_surface.withAlpha(layer)) else t.on_surface.withAlpha(0.12);
        return buildButton(cx, &state.interaction, self.on_press, self.label, self.icon, self.trailing_icon, self.child, fg, bg, padding);
    }
};

/// Material 3's text button: a low-emphasis button without an outline or
/// background until hovered or pressed, for secondary dialog actions.
pub const TextButton = struct {
    label: []const u8 = "",
    icon: ?@import("icons").Icon = null,
    trailing_icon: ?@import("icons").Icon = null,
    child: ?Widget = null,
    on_press: ?Callback = null,

    pub const State = struct {
        interaction: Interaction = .{},
    };

    pub const height = 40;
    pub const padding = 16;
    pub const icon_size = 18;

    pub fn build(self: *const TextButton, cx: *Context, state: *State) Widget {
        const t = cx.theme();
        const enabled = self.on_press != null;
        const i = state.interaction;
        const layer: f32 = if (!enabled) 0 else if (i.pressed) 0.12 else if (i.hovered) 0.08 else 0;
        const fg = if (enabled) t.primary else t.on_surface.withAlpha(0.38);
        const bg: ?Color = if (layer > 0) t.primary.withAlpha(layer) else null;
        return buildButton(cx, &state.interaction, self.on_press, self.label, self.icon, self.trailing_icon, self.child, fg, bg, padding);
    }
};

fn buildButton(
    cx: *Context,
    interaction: *Interaction,
    on_press: ?Callback,
    label_text: []const u8,
    leading: ?@import("icons").Icon,
    trailing: ?@import("icons").Icon,
    child: ?Widget,
    fg: Color,
    bg: ?Color,
    pad: f32,
) Widget {
    const t = cx.theme();
    const height = FilledButton.height;
    const icon_size = FilledButton.icon_size;
    const label = cx.make(Text{
        .text = label_text,
        .style = .{ .size = t.label_size, .color = fg },
        .wrap = false,
    });
    const content = child orelse if (leading != null and trailing != null) blk: {
        const lead = cx.make(Icon{ .icon = leading.?, .size = icon_size, .color = fg });
        const trail = cx.make(Icon{ .icon = trailing.?, .size = icon_size, .color = fg });
        break :blk if (label_text.len == 0)
            cx.make(Row{ .spacing = 8, .main_axis_size = .min, .cross_axis_alignment = .center, .children = &.{ lead, trail } })
        else
            cx.make(Row{ .spacing = 8, .main_axis_size = .min, .cross_axis_alignment = .center, .children = &.{ lead, label, trail } });
    } else if (leading) |which| blk: {
        const glyph = cx.make(Icon{ .icon = which, .size = icon_size, .color = fg });
        break :blk if (label_text.len == 0) glyph else cx.make(Row{ .spacing = 8, .main_axis_size = .min, .cross_axis_alignment = .center, .children = &.{ glyph, label } });
    } else if (trailing) |which| blk: {
        const glyph = cx.make(Icon{ .icon = which, .size = icon_size, .color = fg });
        break :blk if (label_text.len == 0) glyph else cx.make(Row{ .spacing = 8, .main_axis_size = .min, .cross_axis_alignment = .center, .children = &.{ label, glyph } });
    } else label;
    const icon_only = child == null and label_text.len == 0 and (leading == null) != (trailing == null);
    const h_pad: f32 = if (icon_only) (height - icon_size) / 2 else pad;
    return cx.make(Pressable{
        .on_press = on_press,
        .interaction = interaction,
        .child = cx.make(Decorated{
            .color = bg,
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

fn blendOver(base: Color, top: Color) Color {
    const a = top.a;
    return .{
        .r = base.r * (1 - a) + top.r * a,
        .g = base.g * (1 - a) + top.g * a,
        .b = base.b * (1 - a) + top.b * a,
        .a = base.a,
    };
}
