//! Checkbox: Material 3's checkbox, on or off (see control.zig).

const a11y = @import("accessibility.zig");
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

pub const Checkbox = struct {
    value: bool,
    /// Called with the new value; without it the checkbox is disabled.
    on_changed: ?ValueCallback(bool) = null,
    label: []const u8 = "",

    pub const State = struct {
        latest: Latest(bool) = .{},

        fn press(s: *State) void {
            if (s.latest.on_changed) |f| f.call(!(s.latest.value orelse false));
        }
    };

    pub fn accessible(self: *const Checkbox, n: *Node) ?a11y.Info {
        return .{ .role = .check_box, .name = self.label, .action = "toggle", .activate = a11y.callWith(n, bool, self.on_changed, !self.value), .states = .{ .checkable = true, .checked = self.value, .disabled = self.on_changed == null }, .leaf = true };
    }

    pub fn build(self: *const Checkbox, cx: *Context, state: *State) Widget {
        state.latest.update(self.value, self.on_changed);
        const enabled = self.on_changed != null;
        return control.control(cx, &state.latest.interaction, if (enabled) .of(state, State.press) else null, cx.make(CheckboxMark{
            .checked = self.value,
            .enabled = enabled,
            .interaction = state.latest.interaction,
        }), self.label, 4);
    }
};

/// A checkbox's box and tick, in its touch target.
pub const CheckboxMark = struct {
    checked: bool,
    enabled: bool = true,
    interaction: Interaction = .{},

    pub const box = 18;

    pub fn layout(_: *const CheckboxMark, _: *Node, c: Constraints) Size {
        return c.constrain(.{ .w = target, .h = target });
    }

    pub fn paint(self: *const CheckboxMark, n: *Node, p: *Painter) void {
        const t = n.theme();
        const c = p.canvas();
        const mid: gfx.Point = .{ n.size.w / 2, n.size.h / 2 };
        const layer = layerAlpha(self.interaction, self.enabled);
        if (layer > 0) c.fillCircle(mid, target / 2, (if (self.checked) t.primary else t.on_surface).withAlpha(layer));
        const r: gfx.Rect = .{ .x = mid[0] - box / 2, .y = mid[1] - box / 2, .w = box, .h = box };
        const disabled = t.on_surface.withAlpha(0.38);
        if (self.checked) {
            c.fillRoundedRect(r, .all(2), if (self.enabled) t.primary else disabled);
            const tick = if (self.enabled) t.on_primary else t.surface;
            c.strokePolyline(&.{ .{ r.x + 3.5, r.y + 9 }, .{ r.x + 7, r.y + 12.5 }, .{ r.x + 14.5, r.y + 5 } }, false, 2, tick);
        } else {
            c.strokeRoundedRect(r, .all(2), 2, if (self.enabled) t.on_surface_variant else disabled);
        }
    }
};
