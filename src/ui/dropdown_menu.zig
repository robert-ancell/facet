//! DropdownMenu and Select: Material 3's dropdown selector, showing the
//! chosen option in an `OutlinedButton` with a trailing arrow and opening
//! a `Menu` below it when pressed.

const std = @import("std");
const icons = @import("icons");
const widget = @import("widget.zig");
const ConstrainedBox = @import("constrained_box.zig").ConstrainedBox;
const MenuItem = @import("menu.zig").Item;
const OutlinedButton = @import("outlined_button.zig").OutlinedButton;

const Widget = widget.Widget;
const Context = widget.Context;
const Node = widget.Node;
const ValueCallback = widget.ValueCallback;

pub const DropdownMenu = struct {
    options: []const []const u8,
    selected: ?usize = 0,
    /// Optional button label override (for example, a shorter summary).
    label: ?[]const u8 = null,
    /// Called with the chosen index; without it the dropdown is disabled.
    on_selected: ?ValueCallback(usize) = null,
    placeholder: []const u8 = "",
    icon: ?icons.Icon = null,
    width: ?f32 = null,

    pub const height = OutlinedButton.height;
    pub const max_options = 32;

    const Pick = struct {
        state: *State,
        index: usize,

        fn choose(p: *Pick) void {
            if (p.state.on_selected) |cb| cb.call(p.index);
        }
    };

    pub const State = struct {
        node: ?*Node = null,
        on_selected: ?ValueCallback(usize) = null,
        labels: [max_options][]const u8 = undefined,
        picks: [max_options]Pick = undefined,
        len: usize = 0,

        fn open(st: *State) void {
            const n = st.node orelse return;
            if (st.len == 0) return;
            var items: [max_options]MenuItem = undefined;
            for (st.labels[0..st.len], st.picks[0..st.len], items[0..st.len], 0..) |label, *pick, *item, i| {
                pick.* = .{ .state = st, .index = i };
                item.* = .{ .label = label, .on_press = .of(pick, Pick.choose) };
            }
            const pos = n.position();
            n.ui.openMenu(n, .{ pos[0], pos[1] + n.size.h }, items[0..st.len]);
        }
    };

    pub fn build(self: *const DropdownMenu, cx: *Context, state: *State) Widget {
        const enabled = self.on_selected != null and self.options.len > 0;
        state.node = cx.node;
        state.on_selected = self.on_selected;
        state.len = @min(self.options.len, max_options);
        for (self.options[0..state.len], state.labels[0..state.len]) |opt, *dst| dst.* = opt;

        const current_label = self.label orelse if (self.selected) |sel|
            (if (sel < self.options.len) self.options[sel] else self.placeholder)
        else
            self.placeholder;

        const btn = cx.make(OutlinedButton{
            .label = current_label,
            .icon = self.icon,
            .trailing_icon = .expand_more,
            .on_press = if (enabled) .of(state, State.open) else null,
        });
        return if (self.width) |w|
            cx.make(ConstrainedBox{ .constraints = .{ .min_w = w }, .child = btn })
        else
            btn;
    }
};

/// A typed dropdown selector for a value of type `T` (such as an enum).
pub fn Select(comptime T: type) type {
    return struct {
        pub const Option = struct {
            value: T,
            label: []const u8,
        };

        options: []const Option,
        value: ?T = null,
        label: ?[]const u8 = null,
        placeholder: []const u8 = "",
        on_changed: ?ValueCallback(T) = null,
        icon: ?icons.Icon = null,
        width: ?f32 = null,

        pub const State = struct {
            values: [DropdownMenu.max_options]T = undefined,
            len: usize = 0,
            on_changed: ?ValueCallback(T) = null,

            fn pick(st: *State, idx: usize) void {
                if (idx < st.len) {
                    if (st.on_changed) |cb| cb.call(st.values[idx]);
                }
            }
        };

        pub fn build(self: *const @This(), cx: *Context, state: *State) Widget {
            state.len = @min(self.options.len, DropdownMenu.max_options);
            state.on_changed = self.on_changed;
            const labels = cx.arena.alloc([]const u8, state.len) catch return cx.make(@import("empty.zig").Empty{});
            var selected: ?usize = null;
            for (self.options[0..state.len], labels, 0..) |opt, *lbl, i| {
                lbl.* = opt.label;
                state.values[i] = opt.value;
                if (self.value) |v| {
                    if (std.meta.eql(opt.value, v)) selected = i;
                }
            }
            return cx.make(DropdownMenu{
                .options = labels,
                .selected = selected,
                .label = self.label,
                .placeholder = self.placeholder,
                .on_selected = if (self.on_changed != null) .of(state, State.pick) else null,
                .icon = self.icon,
                .width = self.width,
            });
        }
    };
}
