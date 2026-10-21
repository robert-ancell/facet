//! Radio: one of a group of Material 3 radio buttons, and `RadioRow`, one
//! with its label beside it (see control.zig).

const focus = @import("focus.zig");
const keymap = @import("keymap.zig");
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
/// value, and selecting it reports `value`. Material 3 leaves its label to
/// the text beside it (`RadioRow` has one), so name it for assistive
/// technologies with `Accessible`.
pub fn Radio(comptime T: type) type {
    return struct {
        const Self = @This();

        value: T,
        group_value: T,
        /// Called with `value` when it is selected; without it the button is
        /// disabled.
        on_changed: ?ValueCallback(T) = null,

        pub const State = struct {
            latest: Latest(T) = .{},

            fn press(s: *State) void {
                if (s.latest.on_changed) |f| if (s.latest.value) |v| f.call(v);
            }
        };

        pub fn accessible(self: *const Self, n: *Node) ?a11y.Info {
            return .{ .role = .radio, .checked = .of(std.meta.eql(self.value, self.group_value)), .activate = a11y.callWith(n, T, self.on_changed, self.value), .disabled = self.on_changed == null };
        }

        pub fn build(self: *const Self, cx: *Context, state: *State) Widget {
            return buildControl(T, cx, state, self.value, self.group_value, self.on_changed, "");
        }
    };
}

/// A radio button with its label beside it: pressing either selects it.
pub fn RadioRow(comptime T: type) type {
    return struct {
        const Self = @This();

        value: T,
        group_value: T,
        /// Called with `value` when it is selected; without it the button is
        /// disabled.
        on_changed: ?ValueCallback(T) = null,
        label: []const u8,

        pub const State = Radio(T).State;

        pub fn accessible(self: *const Self, n: *Node) ?a11y.Info {
            return .{ .role = .radio, .label = self.label, .checked = .of(std.meta.eql(self.value, self.group_value)), .activate = a11y.callWith(n, T, self.on_changed, self.value), .disabled = self.on_changed == null };
        }

        pub fn build(self: *const Self, cx: *Context, state: *State) Widget {
            return buildControl(T, cx, state, self.value, self.group_value, self.on_changed, self.label);
        }
    };
}

fn buildControl(comptime T: type, cx: *Context, state: *Radio(T).State, value: T, group_value: T, on_changed: ?ValueCallback(T), label: []const u8) Widget {
    state.latest.update(value, on_changed);
    const enabled = on_changed != null;
    return cx.make(RadioKeys{ .child = control.control(cx, &state.latest.interaction, if (enabled) .of(state, Radio(T).State.press) else null, cx.make(RadioMark{
        .selected = std.meta.eql(value, group_value),
        .enabled = enabled,
        .interaction = state.latest.interaction,
    }), label, 4) });
}

/// Around a radio button: the arrow keys move the focus to the next (or
/// the one before) of the radio buttons, and select it.
const RadioKeys = struct {
    child: ?Widget = null,

    pub fn event(_: *const RadioKeys, n: *Node, e: widget.Event) bool {
        const k = switch (e) {
            .key => |k| k,
            else => return false,
        };
        const forward = switch (k.code) {
            keymap.down, keymap.right => true,
            keymap.up, keymap.left => false,
            else => return false,
        };
        if (!k.pressed) return true;
        // The radio buttons in what the focus moves about.
        const ui = n.ui;
        const scope = focus.scope(ui) orelse return true;
        var all: std.ArrayList(*Node) = .empty;
        defer all.deinit(ui.gpa);
        focus.collect(scope, &all, ui.gpa);
        var radios: std.ArrayList(*Node) = .empty;
        defer radios.deinit(ui.gpa);
        for (all.items) |f| if (f.parent) |p| if (p.widget.is(RadioKeys)) radios.append(ui.gpa, f) catch return true;
        const now = std.mem.indexOfScalar(*Node, radios.items, ui.focused orelse return true) orelse return true;
        const count = radios.items.len;
        const next = radios.items[if (forward) (now + 1) % count else (now + count - 1) % count];
        focus.show(ui, next);
        _ = next.widget.vtable.event.?(next.widget.ptr, next, .{ .key = .{ .code = keymap.space, .pressed = true } });
        return true;
    }
};

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
