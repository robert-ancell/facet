//! IconButton: Material 3's circular icon button, in standard, filled,
//! tonal and outlined variants, with optional toggle (`selected`) state.

const a11y = @import("accessibility.zig");
const Node = @import("widget.zig").WidgetNode;
const gfx = @import("gfx");
const icons = @import("icons");
const widget = @import("widget.zig");
const Center = @import("center.zig").Center;
const Decorated = @import("decorated.zig").Decorated;
const Border = @import("decorated.zig").Border;
const Icon = @import("icon.zig").Icon;
const Interaction = @import("pressable.zig").Interaction;
const Pressable = @import("pressable.zig").Pressable;
const SizedBox = @import("sized_box.zig").SizedBox;

const Widget = widget.Widget;
const Context = widget.Context;
const Callback = widget.Callback;
const Color = gfx.Color;

pub const IconButton = struct {
    /// Material 3's four kinds of icon button.
    pub const Variant = enum {
        /// Only the icon, which takes the primary colour when selected.
        standard,
        /// On a circle of the primary colour.
        filled,
        /// On a circle of the secondary container colour, which becomes the
        /// primary container colour when selected.
        tonal,
        /// With a 1 pixel outline, which is filled with the primary colour
        /// when selected.
        outlined,
    };

    icon: icons.Icon,
    on_press: ?Callback = null,
    size: f32 = 40,
    /// Defaults to 60% of `size` (24px for a 40px button).
    icon_size: ?f32 = null,
    /// Whether it is shown as selected, for a button that toggles (and
    /// reported as pressed).
    selected: bool = false,
    variant: Variant = .standard,

    pub const State = struct {
        interaction: Interaction = .{},
    };

    pub fn accessible(self: *const IconButton, n: *Node) ?a11y.Info {
        // Named by its icon, unless an `Accessible` or a tooltip names it;
        // selected, a toggle button that is pressed.
        return .{ .role = .button, .label = a11y.iconName(n, self.icon), .pressed = if (self.selected) .true else null, .activate = self.on_press, .disabled = self.on_press == null };
    }

    pub fn build(self: *const IconButton, cx: *Context, state: *State) Widget {
        const t = cx.theme();
        const enabled = self.on_press != null;
        const i = state.interaction;
        const layer: f32 = if (!enabled) 0 else if (i.pressed) 0.12 else if (i.hovered) 0.08 else 0;

        const fg: Color = if (!enabled)
            t.on_surface.withAlpha(0.38)
        else switch (self.variant) {
            .standard => if (self.selected) t.primary else t.on_surface_variant,
            .filled => t.on_primary,
            .tonal => if (self.selected) t.on_primary_container else t.on_surface_variant,
            .outlined => if (self.selected) t.on_primary else t.on_surface_variant,
        };

        const base_bg: ?Color = if (!enabled) switch (self.variant) {
            .standard, .outlined => null,
            .filled, .tonal => t.on_surface.withAlpha(0.12),
        } else switch (self.variant) {
            .standard => null,
            .filled => t.primary,
            .tonal => if (self.selected) t.primary_container else t.secondary_container,
            .outlined => if (self.selected) t.primary else null,
        };

        const bg: ?Color = if (base_bg) |b|
            (if (layer > 0) blendOver(b, fg.withAlpha(layer)) else b)
        else if (layer > 0)
            fg.withAlpha(layer)
        else
            null;

        const border: ?Border = if (self.variant == .outlined and !self.selected)
            .{ .width = 1, .color = if (enabled) t.outline else t.on_surface.withAlpha(0.12) }
        else
            null;

        const glyph_size = self.icon_size orelse @round(self.size * 0.6);
        return cx.make(Pressable{
            .on_press = self.on_press,
            .interaction = &state.interaction,
            .child = cx.make(Decorated{
                .color = bg,
                .border = border,
                .radius = .all(self.size / 2),
                .child = cx.make(SizedBox{
                    .width = self.size,
                    .height = self.size,
                    .child = cx.make(Center{
                        .child = cx.make(Icon{
                            .icon = self.icon,
                            .size = glyph_size,
                            .color = fg,
                        }),
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
