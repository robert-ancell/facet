//! Buttons: common buttons in each emphasis, icon buttons, segmented
//! buttons, and a button opening a menu.

const std = @import("std");
const facet = @import("facet");
const common = @import("common.zig");

pub const Range = enum { day, week, month, year };
pub const View = enum { list, grid, board };

pub const State = struct {
    log: common.Log = .{},
    favourite: bool = true,
    bookmarked: bool = false,
    muted: bool = false,
    locked: bool = true,
    range: Range = .week,
    view: View = .list,
    menu: MenuButton.Log = .{},

    fn toggleFavourite(s: *State) void {
        s.favourite = !s.favourite;
    }
    fn toggleBookmarked(s: *State) void {
        s.bookmarked = !s.bookmarked;
    }
    fn toggleMuted(s: *State) void {
        s.muted = !s.muted;
    }
    fn toggleLocked(s: *State) void {
        s.locked = !s.locked;
    }
};

pub fn build(cx: *facet.Context, s: *State) facet.Widget {
    return common.page(cx, &.{
        common.section(cx, "Common buttons", "Filled, tonal, outlined and text buttons, from the most emphasis to the least", &.{
            common.labelled(cx, "Label", cx.makeAll(.{
                facet.FilledButton{ .label = "Filled", .on_press = common.pressed(cx, &s.log, "Filled") },
                facet.TonalButton{ .label = "Tonal", .on_press = common.pressed(cx, &s.log, "Tonal") },
                facet.OutlinedButton{ .label = "Outlined", .on_press = common.pressed(cx, &s.log, "Outlined") },
                facet.TextButton{ .label = "Text", .on_press = common.pressed(cx, &s.log, "Text") },
            })),
            common.labelled(cx, "Leading icon", cx.makeAll(.{
                facet.FilledButton{ .label = "Send", .icon = .send, .on_press = common.pressed(cx, &s.log, "Send") },
                facet.TonalButton{ .label = "Edit", .icon = .edit, .on_press = common.pressed(cx, &s.log, "Edit") },
                facet.OutlinedButton{ .label = "Share", .icon = .share, .on_press = common.pressed(cx, &s.log, "Share") },
                facet.TextButton{ .label = "Add", .icon = .add, .on_press = common.pressed(cx, &s.log, "Add") },
            })),
            common.labelled(cx, "Trailing icon", cx.makeAll(.{
                facet.FilledButton{ .label = "Next", .trailing_icon = .chevron_right, .on_press = common.pressed(cx, &s.log, "Next") },
                facet.OutlinedButton{ .label = "Download", .trailing_icon = .download, .on_press = common.pressed(cx, &s.log, "Download") },
                facet.TextButton{ .label = "More", .trailing_icon = .expand_more, .on_press = common.pressed(cx, &s.log, "More") },
            })),
            common.labelled(cx, "Destructive", cx.makeAll(.{
                facet.OutlinedButton{ .label = "Delete", .icon = .delete, .destructive = true, .on_press = common.pressed(cx, &s.log, "Delete") },
            })),
            common.labelled(cx, "Disabled", cx.makeAll(.{
                facet.FilledButton{ .label = "Filled" },
                facet.TonalButton{ .label = "Tonal" },
                facet.OutlinedButton{ .label = "Outlined" },
                facet.TextButton{ .label = "Text" },
            })),
            common.status(cx, s.log.text("Press a button")),
        }),
        common.section(cx, "Icon buttons", "Icon-only buttons in four styles, which can toggle, each with a tooltip saying what it does", &.{
            common.labelled(cx, "Standard", cx.makeAll(.{
                facet.Tooltip{ .text = "Favourite", .child = cx.make(facet.IconButton{ .icon = .favorite, .selected = s.favourite, .on_press = .of(s, State.toggleFavourite) }) },
                facet.Tooltip{ .text = "Search", .child = cx.make(facet.IconButton{ .icon = .search, .on_press = common.pressed(cx, &s.log, "Search") }) },
                facet.Tooltip{ .text = "Unavailable", .child = cx.make(facet.IconButton{ .icon = .print }) },
            })),
            common.labelled(cx, "Filled", cx.makeAll(.{
                facet.Tooltip{ .text = "Bookmark", .child = cx.make(facet.IconButton{ .icon = .star, .variant = .filled, .selected = s.bookmarked, .on_press = .of(s, State.toggleBookmarked) }) },
                facet.Tooltip{ .text = "Unavailable", .child = cx.make(facet.IconButton{ .icon = .star, .variant = .filled }) },
            })),
            common.labelled(cx, "Tonal", cx.makeAll(.{
                facet.Tooltip{ .text = "Mute", .child = cx.make(facet.IconButton{ .icon = .notifications, .variant = .tonal, .selected = s.muted, .on_press = .of(s, State.toggleMuted) }) },
                facet.Tooltip{ .text = "Unavailable", .child = cx.make(facet.IconButton{ .icon = .notifications, .variant = .tonal }) },
            })),
            common.labelled(cx, "Outlined", cx.makeAll(.{
                facet.Tooltip{ .text = "Lock", .child = cx.make(facet.IconButton{ .icon = .lock, .variant = .outlined, .selected = s.locked, .on_press = .of(s, State.toggleLocked) }) },
                facet.Tooltip{ .text = "Unavailable", .child = cx.make(facet.IconButton{ .icon = .lock, .variant = .outlined }) },
            })),
            common.labelled(cx, "Sizes", cx.makeAll(.{
                facet.IconButton{ .icon = .settings, .size = 32, .icon_size = 18, .on_press = common.pressed(cx, &s.log, "Small settings") },
                facet.IconButton{ .icon = .settings, .on_press = common.pressed(cx, &s.log, "Settings") },
                facet.IconButton{ .icon = .settings, .size = 56, .icon_size = 32, .variant = .tonal, .on_press = common.pressed(cx, &s.log, "Large settings") },
            })),
        }),
        common.section(cx, "Segmented buttons", "A choice of one from a few, as a group of joined buttons", &.{
            common.labelled(cx, "Labels", &.{segmented(Range, cx, &s.range, &.{
                .{ .value = .day, .label = "Day" },
                .{ .value = .week, .label = "Week" },
                .{ .value = .month, .label = "Month" },
                .{ .value = .year, .label = "Year" },
            })}),
            common.labelled(cx, "Icons", &.{segmented(View, cx, &s.view, &.{
                .{ .value = .list, .label = "List", .icon = .view_list },
                .{ .value = .grid, .label = "Grid", .icon = .grid_view },
                .{ .value = .board, .label = "Board", .icon = .dashboard },
            })}),
        }),
        common.section(cx, "Menus", "A list of actions over everything else, from a button; items can show shortcuts, be destructive, or be unavailable", cx.makeAll(.{
            facet.Row{
                .spacing = 12,
                .cross_axis_alignment = .center,
                .children = cx.makeAll(.{
                    MenuButton{ .log = &s.menu },
                    common.status(cx, s.menu.text("Open the menu and choose an action")),
                }),
            },
        })),
    });
}

/// A segmented button group choosing a `T`.
fn segmented(comptime T: type, cx: *facet.Context, value: *T, options: []const Segment(T)) facet.Widget {
    const Pick = struct {
        value: *T,
        choice: T,

        fn pick(p: *const @This()) void {
            p.value.* = p.choice;
        }
    };
    const buttons = cx.arena.alloc(facet.Widget, options.len) catch return cx.make(facet.SizedBox.empty);
    for (options, buttons, 0..) |opt, *b, i| {
        const p = cx.arena.create(Pick) catch return cx.make(facet.SizedBox.empty);
        p.* = .{ .value = value, .choice = opt.value };
        b.* = cx.make(facet.PillButton{
            .label = opt.label,
            .icon = opt.icon,
            .selected = value.* == opt.value,
            .first = i == 0,
            .last = i + 1 == options.len,
            .on_press = .of(p, Pick.pick),
        });
    }
    return cx.make(facet.PillBar{ .children = buttons });
}

fn Segment(comptime T: type) type {
    return struct { value: T, label: []const u8, icon: ?facet.icons.Icon = null };
}

/// A button opening a menu below it.
const MenuButton = struct {
    log: *Log,

    const Log = common.Log;

    const Action = struct {
        log: *Log,
        name: []const u8,

        fn run(a: *Action) void {
            a.log.set("Chose “{s}” from the menu", .{a.name});
        }
    };

    pub const State = struct {
        anchor: facet.WidgetAnchor = .{},
        log: ?*Log = null,
        actions: [5]Action = undefined,

        fn open(st: *@This()) void {
            const log = st.log orelse return;
            const names = [_][]const u8{ "Cut", "Copy", "Paste", "Share", "Delete" };
            for (&st.actions, names) |*a, name| a.* = .{ .log = log, .name = name };
            st.anchor.openMenu(&.{
                .{ .label = "Cut", .shortcut = "Ctrl+X", .on_press = .of(&st.actions[0], Action.run) },
                .{ .label = "Copy", .shortcut = "Ctrl+C", .on_press = .of(&st.actions[1], Action.run) },
                .{ .label = "Paste", .shortcut = "Ctrl+V", .on_press = .of(&st.actions[2], Action.run) },
                .{ .label = "Share", .enabled = false },
                .{ .label = "Delete", .shortcut = "Del", .destructive = true, .on_press = .of(&st.actions[4], Action.run) },
            });
        }
    };

    pub fn build(self: *const MenuButton, cx: *facet.Context, state: *@This().State) facet.Widget {
        state.anchor = cx.anchor();
        state.log = self.log;
        return cx.make(facet.OutlinedButton{
            .label = "Edit",
            .icon = .edit,
            .trailing_icon = .expand_more,
            .on_press = .of(state, @This().State.open),
        });
    }
};
