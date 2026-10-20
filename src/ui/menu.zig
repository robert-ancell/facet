//! Menu: Material 3's menu, a list of actions shown above everything else
//! at a point (where the right button was pressed, say): see
//! `Ui.openMenu`. Pressing an item closes the menu and does the action;
//! pressing anywhere else, or Escape, closes it. It goes down and to the
//! right of the point, or up or to the left where there is no room, and
//! stays in the window (`place`).

const a11y = @import("accessibility.zig");
const Node = @import("widget.zig").Node;
const std = @import("std");
const geometry = @import("geometry.zig");
const widget = @import("widget.zig");
const Interaction = @import("pressable.zig").Interaction;
const Pressable = @import("pressable.zig").Pressable;
const Decorated = @import("decorated.zig").Decorated;
const SizedBox = @import("sized_box.zig").SizedBox;
const Padding = @import("padding.zig").Padding;
const Column = @import("flex.zig").Column;
const Row = @import("flex.zig").Row;
const Expanded = @import("expanded.zig").Expanded;
const Text = @import("text.zig").Text;

const Point = geometry.Point;
const Size = geometry.Size;
const Widget = widget.Widget;
const Context = widget.Context;
const Callback = widget.Callback;

pub const Item = struct {
    label: []const u8,
    /// Its keyboard shortcut, shown at the right ("Ctrl+C").
    shortcut: []const u8 = "",
    /// Destructive action (e.g. delete): shown in the theme's error colour
    /// when enabled.
    destructive: bool = false,
    /// Shown dimmed, and not pressable, if not.
    enabled: bool = true,
    on_press: ?Callback = null,
};

pub const width = 220;
pub const item_height = 44;
/// Space above and below the items.
pub const padding = 8;

/// The menu's items, on a surface.
pub const Menu = struct {
    items: []const Item,

    pub fn accessible(_: *const Menu, _: *Node) ?a11y.Info {
        return .{ .role = .menu, .orientation = .vertical };
    }

    pub fn build(self: *const Menu, cx: *Context) Widget {
        const t = cx.theme();
        const rows = cx.ui.arena().alloc(Widget, self.items.len) catch return cx.make(@import("empty.zig").Empty{});
        for (self.items, rows) |item, *row| row.* = cx.make(MenuRow{ .item = item });
        return cx.make(Decorated{
            .color = t.surface_container,
            .border = .{ .width = 1, .color = t.outline_variant },
            .radius = .all(4),
            .child = cx.make(SizedBox{ .width = width, .child = cx.make(Padding{
                .padding = .symmetric(0, padding),
                .child = cx.make(Column{ .main_axis_size = .min, .cross_axis_alignment = .stretch, .children = rows }),
            }) }),
        });
    }

    /// How tall a menu of `n` items is.
    pub fn height(n: usize) f32 {
        return @as(f32, @floatFromInt(n)) * item_height + 2 * padding;
    }
};

/// An item: its label and shortcut, with Material's hover and press tint.
const MenuRow = struct {
    item: Item,

    pub const State = struct {
        interaction: Interaction = .{},
        /// The action, and the UI (whose menu closes), from the last build.
        action: ?Callback = null,
        ui: ?*@import("runtime.zig").Ui = null,

        fn press(s: *State) void {
            // Closed first: the action may open another.
            if (s.ui) |u| u.closeMenu();
            if (s.action) |a| a.call();
        }
    };

    pub fn accessible(self: *const MenuRow, _: *Node) ?a11y.Info {
        return .{ .role = .menuitem, .label = self.item.label, .keyshortcuts = self.item.shortcut, .activate = self.item.on_press, .disabled = !self.item.enabled, .children_presentational = true };
    }

    pub fn build(self: *const MenuRow, cx: *Context, state: *State) Widget {
        const t = cx.theme();
        const enabled = self.item.enabled and self.item.on_press != null;
        state.action = if (enabled) self.item.on_press else null;
        state.ui = cx.ui;
        const i = state.interaction;
        const layer: f32 = if (!enabled) 0 else if (i.pressed) 0.10 else if (i.hovered) 0.08 else 0;
        const accent = if (self.item.destructive) t.@"error" else t.on_surface;
        const label_color = if (enabled) accent else t.on_surface.withAlpha(0.38);
        const hint_color = if (enabled) (if (self.item.destructive) t.@"error" else t.on_surface_variant) else t.on_surface.withAlpha(0.38);
        return cx.make(Pressable{
            .on_press = if (enabled) .of(state, State.press) else null,
            .interaction = &state.interaction,
            .focus_radius = 0,
            .child = cx.make(Decorated{ .color = if (layer > 0) accent.withAlpha(layer) else null, .child = cx.make(SizedBox{
                .height = item_height,
                .child = cx.make(Padding{ .padding = .symmetric(12, 0), .child = cx.make(Row{ .spacing = 12, .children = &.{
                    cx.make(Expanded{ .child = cx.make(Text{ .text = self.item.label, .style = .{ .size = t.label_size, .color = label_color }, .wrap = false, .ellipsis = true }) }),
                    cx.make(Text{ .text = self.item.shortcut, .style = .{ .size = t.label_size, .color = hint_color }, .wrap = false }),
                } }) }),
            }) }),
        });
    }
};

/// Where a menu `size` big goes for a point `at`, in a window `window`
/// big: down and to the right of the point; up or to the left of it where
/// there is no room that way but is the other; and slid into the window
/// if neither way fits.
pub fn place(window: Size, at: Point, size: Size) Point {
    return .{ axis(at[0], size.w, window.w), axis(at[1], size.h, window.h) };
}

fn axis(at: f32, size: f32, room: f32) f32 {
    if (at + size <= room) return at;
    if (at - size >= 0) return at - size;
    return @max(@min(at, room - size), 0);
}

const testing = std.testing;

test "menus go down and right, flipped or slid where there is no room" {
    const win: Size = .{ .w = 800, .h = 600 };
    const sz: Size = .{ .w = 200, .h = 150 };
    try testing.expectEqual(Point{ 100, 50 }, place(win, .{ 100, 50 }, sz));
    // Near the bottom right corner: up and to the left.
    try testing.expectEqual(Point{ 550, 400 }, place(win, .{ 750, 550 }, sz));
    // Too tall to go either way: slid in, its top showing first.
    try testing.expectEqual(Point{ 100, 0 }, place(win, .{ 100, 50 }, .{ .w = 200, .h = 700 }));
    try testing.expectEqual(Point{ 100, 350 }, place(win, .{ 100, 500 }, sz));
}
