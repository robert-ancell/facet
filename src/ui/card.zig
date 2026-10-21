//! Card: Material 3's surface container for grouping related information
//! and actions, in filled, elevated and outlined variants.

const gfx = @import("gfx");
const geometry = @import("geometry.zig");
const widget = @import("widget.zig");
const Decorated = @import("decorated.zig").Decorated;
const Border = @import("decorated.zig").Border;
const Interaction = @import("pressable.zig").Interaction;
const Padding = @import("padding.zig").Padding;
const Pressable = @import("pressable.zig").Pressable;

const Insets = geometry.Insets;
const Widget = widget.Widget;
const Context = widget.Context;
const Callback = widget.Callback;
const Color = gfx.Color;

pub const Card = struct {
    pub const Variant = enum {
        filled,
        elevated,
        outlined,
    };

    variant: Variant = .filled,
    padding: Insets = .all(16),
    radius: f32 = 12,
    /// Whether it is shown as selected.
    selected: bool = false,
    on_press: ?Callback = null,
    child: ?Widget = null,

    pub const State = struct {
        interaction: Interaction = .{},
    };

    pub fn build(self: *const Card, cx: *Context, state: *State) Widget {
        const t = cx.theme();
        const clickable = self.on_press != null;
        const i = state.interaction;
        const layer: f32 = if (!clickable) 0 else if (i.pressed) 0.12 else if (i.hovered) 0.08 else 0;

        const base_bg: Color = if (self.selected)
            t.secondary_container
        else switch (self.variant) {
            .filled => t.surface_container_highest,
            .elevated => t.surface_container,
            .outlined => t.surface,
        };
        const bg: Color = if (layer > 0) blendOver(base_bg, t.on_surface.withAlpha(layer)) else base_bg;

        const border: ?Border = switch (self.variant) {
            .outlined => .{ .width = 1, .color = if (self.selected) t.primary else t.outline_variant },
            .elevated => .{ .width = 1, .color = t.outline_variant.withAlpha(0.5) },
            .filled => if (self.selected) .{ .width = 1, .color = t.primary } else null,
        };

        const inner = cx.make(Decorated{
            .color = bg,
            .border = border,
            .radius = .all(self.radius),
            .child = cx.make(Padding{
                .padding = self.padding,
                .child = self.child,
            }),
        });
        if (!clickable) return inner;
        return cx.make(Pressable{
            .on_press = self.on_press,
            .interaction = &state.interaction,
            .focus_radius = self.radius,
            .child = inner,
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
