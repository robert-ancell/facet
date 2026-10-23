//! Switch: a switch, its handle sliding between off and on, and
//! `SwitchRow`, one with its label beside it (see control.zig).

const a11y = @import("accessibility.zig");
const std = @import("std");
const gfx = @import("gfx");
const widget = @import("widget.zig");
const geometry = @import("geometry.zig");
const control = @import("control.zig");
const PointerInteraction = @import("pressable.zig").PointerInteraction;
const Painter = @import("painter.zig").Painter;

const Size = geometry.Size;
const Constraints = geometry.Constraints;
const Widget = widget.Widget;
const Context = widget.BuildContext;
const Node = widget.WidgetNode;
const ValueCallback = widget.ValueCallback;
const Latest = control.Latest;
const layerAlpha = control.layerAlpha;
const target = control.target;

const Color = gfx.Color;

/// A switch: a track with a handle that slides between off and on when it is
/// pressed. It is usually used as part of a `SwitchRow`, which adds text
/// beside it that toggles it too, and the information assistive technologies
/// need.
///
/// ![The Switch example](images/Switch.png)
///
/// ```zig
/// return cx.make(kete.Row{ .fill = false, .spacing = 16, .children = cx.makeAll(.{
///     kete.Switch{ .value = true, .on_changed = .of(state, State.setOn) },
///     kete.Switch{ .value = false, .on_changed = .of(state, State.setOn) },
/// }) });
/// ```
pub const Switch = struct {
    /// Whether it is on.
    value: bool,
    /// Called with the new value; without it the switch is disabled.
    on_changed: ?ValueCallback(bool) = null,

    /// How long the handle takes to cross.
    pub const travel_ns = 150 * std.time.ns_per_ms;

    pub const State = struct {
        latest: Latest(bool) = .{},
        /// Where the handle is shown: 0 off, 1 on.
        position: ?f32 = null,
        last_ns: u64 = 0,

        fn press(s: *State) void {
            if (s.latest.on_changed) |f| f.call(!(s.latest.value orelse false));
        }
    };

    pub fn accessible(self: *const Switch, n: *Node) ?a11y.Info {
        return .{ .role = .@"switch", .checked = .of(self.value), .activate = a11y.callWith(n, bool, self.on_changed, !self.value), .disabled = self.on_changed == null };
    }

    pub fn build(self: *const Switch, cx: *Context, state: *State) Widget {
        return buildControl(cx, state, self.value, self.on_changed, "");
    }
};

/// A switch with its label beside it: pressing either toggles it.
///
/// ![The SwitchRow example](images/SwitchRow.png)
///
/// ```zig
/// return cx.make(kete.SwitchRow{ .value = true, .label = "Wi-Fi", .on_changed = .of(state, State.setOn) });
/// ```
pub const SwitchRow = struct {
    /// Whether it is on (see `Switch.value`).
    value: bool,
    /// Called with the new value; without it the switch is disabled.
    on_changed: ?ValueCallback(bool) = null,
    /// The text beside the switch, which also names it for assistive
    /// technologies.
    label: []const u8,

    pub const State = Switch.State;

    pub fn accessible(self: *const SwitchRow, n: *Node) ?a11y.Info {
        return .{ .role = .@"switch", .label = self.label, .checked = .of(self.value), .activate = a11y.callWith(n, bool, self.on_changed, !self.value), .disabled = self.on_changed == null };
    }

    pub fn build(self: *const SwitchRow, cx: *Context, state: *State) Widget {
        return buildControl(cx, state, self.value, self.on_changed, self.label);
    }
};

fn buildControl(cx: *Context, state: *Switch.State, value: bool, on_changed: ?ValueCallback(bool), label: []const u8) Widget {
    state.latest.update(value, on_changed);
    // The handle slides to the value.
    const goal: f32 = if (value) 1 else 0;
    const now = cx.now();
    var pos = state.position orelse goal;
    const step = @as(f32, @floatFromInt(now -| state.last_ns)) / Switch.travel_ns;
    pos = if (pos < goal) @min(pos + step, goal) else @max(pos - step, goal);
    state.position = pos;
    state.last_ns = now;
    if (pos != goal) cx.requestFrame();
    const enabled = on_changed != null;
    return control.control(cx, &state.latest.interaction, if (enabled) .of(state, Switch.State.press) else null, cx.make(SwitchMark{
        .position = pos,
        .enabled = enabled,
        .interaction = state.latest.interaction,
    }), label, 12);
}

/// A switch's track and handle.
pub const SwitchMark = struct {
    /// 0 off, 1 on (between while it slides).
    position: f32,
    enabled: bool = true,
    interaction: PointerInteraction = .{},

    pub const width = 52;
    pub const height = 32;

    pub fn layout(_: *const SwitchMark, _: *Node, c: Constraints) Size {
        return c.constrain(.{ .w = width, .h = target });
    }

    pub fn minSize(_: *const SwitchMark, _: *Node, c: Constraints) Size {
        return c.constrain(.{ .w = width, .h = target });
    }

    pub fn paint(self: *const SwitchMark, n: *Node, p: *Painter) void {
        const t = n.theme();
        const c = p.canvas();
        const k = std.math.clamp(self.position, 0, 1);
        const track: gfx.Rect = .{ .x = (n.size.w - width) / 2, .y = (n.size.h - height) / 2, .w = width, .h = height };
        const disabled: f32 = if (self.enabled) 1 else 0.38;
        // Off: an outlined track, a small handle in the outline colour.
        // On: a filled track, a bigger handle (bigger still when pressed).
        c.fillRoundedRect(track, .all(height / 2), mix(t.surface_container_highest, t.primary, k).withAlpha(if (self.enabled) 1 else 0.12));
        if (k < 1) c.strokeRoundedRect(track, .all(height / 2), 2, t.outline.withAlpha((1 - k) * disabled));
        const pressed = self.enabled and self.interaction.pressed;
        const radius: f32 = if (pressed) 14 else 8 + 4 * k;
        const center: gfx.Point = .{ track.x + 16 + 20 * k, track.y + height / 2 };
        const layer = layerAlpha(self.interaction, self.enabled);
        if (layer > 0) c.fillCircle(center, 20, (if (k > 0.5) t.primary else t.on_surface).withAlpha(layer));
        c.fillCircle(center, radius, mix(t.outline, t.on_primary, k).withAlpha(disabled));
    }
};

fn mix(a: Color, b: Color, k: f32) Color {
    return .{ .r = a.r + (b.r - a.r) * k, .g = a.g + (b.g - a.g) * k, .b = a.b + (b.b - a.b) * k, .a = a.a + (b.a - a.a) * k };
}
