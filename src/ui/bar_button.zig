//! BarButton: a round button with an icon, as in a title bar (see
//! title_bar.zig).

const a11y = @import("accessibility.zig");
const gfx = @import("gfx");
const icons = @import("icons");
const geometry = @import("geometry.zig");
const widget = @import("widget.zig");
const Interaction = @import("pressable.zig").Interaction;
const Pressable = @import("pressable.zig").Pressable;
const Painter = @import("painter.zig").Painter;

const Node = widget.Node;
const Context = widget.Context;
const Widget = widget.Widget;
const Constraints = geometry.Constraints;
const Size = geometry.Size;

/// A round button with an icon, highlighted under the pointer.
pub const BarButton = struct {
    on_press: widget.Callback,
    size: f32,
    icon: icons.Icon,

    pub const State = struct {
        interaction: Interaction = .{},
    };

    pub fn accessible(self: *const BarButton, n: *Node) ?a11y.Info {
        return .{ .role = .button, .label = a11y.iconName(n, self.icon), .activate = self.on_press };
    }

    pub fn build(self: *const BarButton, cx: *Context, state: *State) Widget {
        return cx.make(Pressable{ .on_press = self.on_press, .interaction = &state.interaction, .child = cx.make(Mark{
            .icon = self.icon,
            .size = self.size,
            .hovered = state.interaction.hovered,
            .pressed = state.interaction.pressed,
        }) });
    }
};

const Mark = struct {
    icon: icons.Icon,
    size: f32,
    hovered: bool,
    pressed: bool,

    pub fn layout(self: *const Mark, _: *Node, c: Constraints) Size {
        return c.constrain(.{ .w = self.size, .h = self.size });
    }

    pub fn paint(self: *const Mark, n: *Node, p: *Painter) void {
        const t = n.theme();
        const c = p.canvas();
        const mid: gfx.Point = .{ n.size.w / 2, n.size.h / 2 };
        if (self.hovered or self.pressed) c.fillCircle(mid, n.size.w / 2, t.on_surface.withAlpha(if (self.pressed) 0.16 else 0.08));
        const s = @round(n.size.w * 0.6);
        p.icon(self.icon, @round((n.size.w - s) / 2), @round((n.size.h - s) / 2), s, t.on_surface_variant);
    }
};
