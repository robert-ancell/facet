//! DropdownMenu and Select: Material 3's dropdown selector, showing the
//! chosen option in an `OutlinedButton` with a trailing arrow and opening
//! a `Menu` below it when pressed.

const a11y = @import("accessibility.zig");
const std = @import("std");
const icons = @import("icons");
const widget = @import("widget.zig");
const ConstrainedBox = @import("constrained_box.zig").ConstrainedBox;
const MenuItem = @import("menu.zig").Item;
const button = @import("button.zig");
const OutlinedButton = button.OutlinedButton;

const Widget = widget.Widget;
const Context = widget.BuildContext;
const Node = widget.WidgetNode;
const ValueCallback = widget.ValueCallback;

/// Material 3's dropdown: a button that opens a menu of choices, by index.
///
/// ![The DropdownMenu example](images/DropdownMenu.png)
///
/// ```zig
/// return cx.make(facet.DropdownMenu{
///     .options = &.{
///         .{ .label = "Light", .leading_icon = .light_mode },
///         .{ .label = "Dark", .leading_icon = .dark_mode },
///         .{ .label = "Automatic", .leading_icon = .settings },
///     },
///     .selected = 1,
///     .on_selected = .of(state, State.select),
///     .width = 180,
/// });
/// ```
pub const DropdownMenu = struct {
    /// The choices, as menu items: their `label`, `leading_icon`,
    /// `trailing_icon`, `shortcut`, `enabled`, `destructive` and `kind`
    /// (a `divider` is no choice, and the others look alike) are used, and
    /// the indices count every item, dividers too. Pressing one calls
    /// `on_selected` with its index; `on_press`, `checked` and `submenu`
    /// are not used.
    options: []const MenuItem,
    /// The index in `options` of the choice made, or null for none (the
    /// `placeholder` shows). The app holds it and shows a change from the
    /// next build. It is marked in the menu.
    selected: ?usize = 0,
    /// Optional button label override (for example, a shorter summary).
    label: ?[]const u8 = null,
    /// Called with the chosen index; without it the dropdown is disabled.
    on_selected: ?ValueCallback(usize) = null,
    /// What the button shows when no choice is made.
    placeholder: []const u8 = "",
    /// An icon before the text on the button (the choice's `leading_icon`
    /// if not given).
    icon: ?icons.IconName = null,
    /// The button's least width, in pixels (as wide as its text needs, if not given).
    width: ?f32 = null,

    pub const height = button.height;

    /// Presses the choice `index`.
    const Pick = struct {
        state: *State,
        index: usize,

        fn choose(p: *Pick) void {
            if (p.state.on_selected) |cb| cb.call(p.index);
        }
    };

    pub const State = struct {
        anchor: widget.WidgetAnchor = .{},
        on_selected: ?ValueCallback(usize) = null,
        /// The choices and the one made, from the last build.
        options: []const MenuItem = &.{},
        selected: ?usize = null,
        /// What pressing each choice does (kept as long as the dropdown is).
        picks: []Pick = &.{},
        gpa: ?std.mem.Allocator = null,

        pub fn deinit(st: *State) void {
            if (st.gpa) |a| a.free(st.picks);
        }

        fn open(st: *State) void {
            if (st.options.len == 0) return;
            // The menu copies the items, so these are only needed for now.
            const a = (st.anchor.node orelse return).ui.gpa;
            const items = a.alloc(MenuItem, st.options.len) catch return;
            defer a.free(items);
            for (st.options, items, st.picks, 0..) |opt, *item, *pick, i| {
                _ = pick;
                item.* = opt;
                item.on_press = .of(&st.picks[i], Pick.choose);
                item.checked = st.selected == i;
                item.submenu = &.{};
                if (opt.kind != .divider) item.kind = .radio;
            }
            st.anchor.openMenu(items);
        }
    };

    pub fn accessible(self: *const DropdownMenu, _: *Node) ?a11y.Info {
        const shown = if (self.selected) |i| if (i < self.options.len) self.options[i].label else "" else self.placeholder;
        return .{ .role = .combobox, .label = self.label orelse "", .placeholder = self.placeholder, .haspopup = .listbox, .expanded = false, .text = shown };
    }

    pub fn build(self: *const DropdownMenu, cx: *Context, state: *State) Widget {
        const enabled = self.on_selected != null and self.options.len > 0;
        state.anchor = cx.anchor();
        state.on_selected = self.on_selected;
        state.options = self.options;
        state.selected = self.selected;
        if (state.picks.len != self.options.len) {
            state.gpa = cx.ui.gpa;
            cx.ui.gpa.free(state.picks);
            state.picks = &.{};
            if (cx.ui.gpa.alloc(Pick, self.options.len)) |picks| {
                state.picks = picks;
                for (picks, 0..) |*pick, i| pick.* = .{ .state = state, .index = i };
            } else |_| state.options = &.{};
        }

        const chosen: ?MenuItem = if (self.selected) |sel| (if (sel < self.options.len) self.options[sel] else null) else null;
        const current_label = self.label orelse if (chosen) |c| c.label else self.placeholder;

        const btn = cx.make(OutlinedButton{
            .label = current_label,
            .icon = self.icon orelse if (chosen) |c| c.leading_icon else null,
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
///
/// ![The Select example](images/Select.png)
///
/// ```zig
/// return cx.make(facet.Select(Quality){
///     .options = &.{
///         .labeled(.low, "Low"),
///         .labeled(.medium, "Medium"),
///         .labeled(.high, "High"),
///     },
///     .value = .medium,
///     .on_changed = .of(state, State.setQuality),
///     .width = 180,
/// });
/// ```
pub fn Select(comptime T: type) type {
    return struct {
        /// One choice: the value it stands for, and how it shows in the menu.
        pub const Option = struct {
            /// The value chosen with it.
            value: T,
            /// How it shows in the menu (see `DropdownMenu.options` for what
            /// of it is used).
            item: MenuItem,

            /// A choice that shows as the text `label`.
            pub fn labeled(value: T, label: []const u8) Option {
                return .{ .value = value, .item = .{ .label = label } };
            }
        };

        /// The choices, each with the text it shows.
        options: []const Option,
        /// The value of the choice made, or null for none (the `placeholder`
        /// shows). The app holds it and shows a change from the next build.
        value: ?T = null,
        /// Optional button label override (for example, a shorter summary).
        label: ?[]const u8 = null,
        /// What the button shows when no choice is made.
        placeholder: []const u8 = "",
        /// Called with the value chosen; without it the dropdown is disabled.
        on_changed: ?ValueCallback(T) = null,
        /// An icon before the text on the button (the choice's `leading_icon`
        /// if not given).
        icon: ?icons.IconName = null,
        /// The button's least width, in pixels (as wide as its text needs, if not given).
        width: ?f32 = null,

        pub const State = struct {
            values: []T = &.{},
            on_changed: ?ValueCallback(T) = null,

            fn pick(st: *State, idx: usize) void {
                if (idx < st.values.len) {
                    if (st.on_changed) |cb| cb.call(st.values[idx]);
                }
            }
        };

        pub fn build(self: *const @This(), cx: *Context, state: *State) Widget {
            const empty = cx.make(@import("sized_box.zig").SizedBox.empty);
            const items = cx.arena.alloc(MenuItem, self.options.len) catch return empty;
            const values = cx.arena.alloc(T, self.options.len) catch return empty;
            state.values = values;
            state.on_changed = self.on_changed;
            var selected: ?usize = null;
            for (self.options, items, values, 0..) |opt, *item, *value, i| {
                item.* = opt.item;
                value.* = opt.value;
                if (self.value) |v| {
                    if (std.meta.eql(opt.value, v)) selected = i;
                }
            }
            return cx.make(DropdownMenu{
                .options = items,
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
