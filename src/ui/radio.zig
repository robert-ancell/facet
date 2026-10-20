//! Radio: one of a group of Material 3 radio buttons (see control.zig).

const a11y = @import("accessibility.zig");
const std = @import("std");
const gfx = @import("gfx");
const widget = @import("widget.zig");
const geometry = @import("geometry.zig");
const control = @import("control.zig");
const Interaction = @import("pressable.zig").Interaction;
const Painter = @import("painter.zig").Painter;

const Size = geometry.Size;
const Constraints = geometry.Constraints;
const Widget = widget.Widget;
const Context = widget.Context;
const Node = widget.Node;
const ValueCallback = widget.ValueCallback;
const Latest = control.Latest;
const layerAlpha = control.layerAlpha;
const target = control.target;

/// One of a group of radio buttons: selected when `value` is the group's
/// value, and selecting it reports `value`.
pub fn Radio(comptime T: type) type {
    return struct {
        const Self = @This();

        value: T,
        group_value: T,
        /// Called with `value` when it is selected; without it the button is
        /// disabled.
        on_changed: ?ValueCallback(T) = null,
        label: []const u8 = "",

        pub const State = struct {
            latest: Latest(T) = .{},

            fn press(s: *State) void {
                if (s.latest.on_changed) |f| if (s.latest.value) |v| f.call(v);
            }
        };

        pub fn accessible(self: *const Self, n: *Node) ?a11y.Info {
            return .{ .role = .radio_button, .name = self.label, .action = "select", .activate = a11y.callWith(n, T, self.on_changed, self.value), .states = .{ .checkable = true, .checked = std.meta.eql(self.value, self.group_value), .disabled = self.on_changed == null }, .leaf = true };
        }

        pub fn build(self: *const Self, cx: *Context, state: *State) Widget {
            state.latest.update(self.value, self.on_changed);
            const enabled = self.on_changed != null;
            return control.control(cx, &state.latest.interaction, if (enabled) .of(state, State.press) else null, cx.make(RadioMark{
                .selected = std.meta.eql(self.value, self.group_value),
                .enabled = enabled,
                .interaction = state.latest.interaction,
            }), self.label, 4);
        }
    };
}

/// A radio button's ring and dot, in its touch target.
pub const RadioMark = struct {
    selected: bool,
    enabled: bool = true,
    interaction: Interaction = .{},

    pub fn layout(_: *const RadioMark, _: *Node, c: Constraints) Size {
        return c.constrain(.{ .w = target, .h = target });
    }

    pub fn paint(self: *const RadioMark, n: *Node, p: *Painter) void {
        const t = n.theme();
        const c = p.canvas();
        const mid: gfx.Point = .{ n.size.w / 2, n.size.h / 2 };
        const layer = layerAlpha(self.interaction, self.enabled);
        if (layer > 0) c.fillCircle(mid, target / 2, (if (self.selected) t.primary else t.on_surface).withAlpha(layer));
        const color = if (!self.enabled) t.on_surface.withAlpha(0.38) else if (self.selected) t.primary else t.on_surface_variant;
        c.strokeCircle(mid, 10, 2, color);
        if (self.selected) c.fillCircle(mid, 5, color);
    }
};
