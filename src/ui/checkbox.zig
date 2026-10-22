//! Checkbox: Material 3's checkbox, on or off, and `CheckboxRow`, one with
//! its label beside it (see control.zig).

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
const Node = widget.WidgetNode;
const ValueCallback = widget.ValueCallback;
const Latest = control.Latest;
const layerAlpha = control.layerAlpha;
const target = control.target;

/// A checkbox on its own: Material 3 leaves its label to the text beside
/// it (`CheckboxRow` has one), so name it for assistive technologies with
/// `Accessible`.
pub const Checkbox = struct {
    /// Whether it is checked. The app holds it: the checkbox reports a
    /// change through `on_changed` and shows the new value from the next
    /// build.
    value: bool,
    /// Called with the new value; without it the checkbox is disabled.
    on_changed: ?ValueCallback(bool) = null,

    pub const State = struct {
        latest: Latest(bool) = .{},

        fn press(s: *State) void {
            if (s.latest.on_changed) |f| f.call(!(s.latest.value orelse false));
        }
    };

    pub fn accessible(self: *const Checkbox, n: *Node) ?a11y.Info {
        return .{ .role = .checkbox, .checked = .of(self.value), .activate = a11y.callWith(n, bool, self.on_changed, !self.value), .disabled = self.on_changed == null };
    }

    pub fn build(self: *const Checkbox, cx: *Context, state: *State) Widget {
        return buildControl(cx, state, self.value, self.on_changed, "");
    }
};

/// A checkbox with its label beside it: pressing either toggles it.
pub const CheckboxRow = struct {
    /// Whether it is checked (see `Checkbox.value`).
    value: bool,
    /// Called with the new value; without it the checkbox is disabled.
    on_changed: ?ValueCallback(bool) = null,
    /// The text beside the checkbox, which also names it for assistive
    /// technologies.
    label: []const u8,

    pub const State = Checkbox.State;

    pub fn accessible(self: *const CheckboxRow, n: *Node) ?a11y.Info {
        return .{ .role = .checkbox, .label = self.label, .checked = .of(self.value), .activate = a11y.callWith(n, bool, self.on_changed, !self.value), .disabled = self.on_changed == null };
    }

    pub fn build(self: *const CheckboxRow, cx: *Context, state: *State) Widget {
        return buildControl(cx, state, self.value, self.on_changed, self.label);
    }
};

fn buildControl(cx: *Context, state: *Checkbox.State, value: bool, on_changed: ?ValueCallback(bool), label: []const u8) Widget {
    state.latest.update(value, on_changed);
    const enabled = on_changed != null;
    return control.control(cx, &state.latest.interaction, if (enabled) .of(state, Checkbox.State.press) else null, cx.make(CheckboxMark{
        .checked = value,
        .enabled = enabled,
        .interaction = state.latest.interaction,
    }), label, 4);
}

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
