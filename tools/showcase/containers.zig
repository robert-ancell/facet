//! Containers: cards, lists, dividers, tabs, scrolling, and a virtualized
//! grid.

const std = @import("std");
const kete = @import("kete");
const common = @import("common.zig");

const grid_count = 10_000;

pub const State = struct {
    card: usize = 0,
    item: usize = 0,
    wifi: bool = true,
    tab: usize = 0,
    fixed_tab: usize = 1,
    row: ?usize = null,
    cell: ?usize = null,
    log: common.Log = .{},

    fn setWifi(s: *State, v: bool) void {
        s.wifi = v;
    }
    fn setTab(s: *State, v: usize) void {
        s.tab = v;
    }
    fn setFixedTab(s: *State, v: usize) void {
        s.fixed_tab = v;
    }
};

/// A callback setting `slot` to `value`.
fn choose(cx: *kete.BuildContext, slot: anytype, value: usize) kete.Callback {
    const Slot = @TypeOf(slot);
    const Pick = struct {
        slot: Slot,
        value: usize,

        fn pick(p: *const @This()) void {
            p.slot.* = p.value;
        }
    };
    const p = cx.arena.create(Pick) catch unreachable;
    p.* = .{ .slot = slot, .value = value };
    return .of(p, Pick.pick);
}

pub fn build(cx: *kete.BuildContext, s: *State) kete.Widget {
    const t = cx.theme();
    const variants = [_]struct { kete.Card.Variant, []const u8, []const u8 }{
        .{ .filled, "Filled", "A tinted surface, for content set apart from what is around it." },
        .{ .elevated, "Elevated", "Raised over the page with a shadow." },
        .{ .outlined, "Outlined", "A border on the page's surface, for the least emphasis." },
    };
    var cards: [variants.len]kete.Widget = undefined;
    for (&cards, variants, 0..) |*w, v, i| {
        w.* = cx.make(kete.Expanded{ .child = cx.make(kete.Card{
            .variant = v[0],
            .selected = s.card == i,
            .on_press = choose(cx, &s.card, i),
            .child = cx.make(kete.Column{
                .fill = false,
                .cross_axis_alignment = .start,
                .spacing = 6,
                .children = cx.makeAll(.{
                    kete.Text{ .text = v[1], .style = .{ .size = 16, .color = t.on_surface }, .wrap = false },
                    kete.Text{ .text = v[2], .style = .{ .size = 13, .color = t.on_surface_variant } },
                }),
            }),
        }) });
    }

    const tabs = [_]kete.Tab{
        .{ .label = "Photos", .icon = .image },
        .{ .label = "Music", .icon = .bolt, .badge = 4 },
        .{ .label = "Files", .icon = .folder },
    };
    const tab_text = [_][]const u8{ "Your photos would be here.", "Four new songs.", "Your files would be here." };
    const fixed_tabs = [_]kete.Tab{ .{ .label = "Overview" }, .{ .label = "Specifications" }, .{ .label = "Reviews" } };

    return common.page(cx, &.{
        common.section(cx, "Cards", "Surfaces holding related content and actions; press one to select it", cx.makeAll(.{
            kete.Row{ .spacing = 16, .cross_axis_alignment = .start, .children = &cards },
            kete.Card{
                .variant = .outlined,
                .child = cx.make(kete.Row{
                    .spacing = 16,
                    .cross_axis_alignment = .center,
                    .children = cx.makeAll(.{
                        kete.Icon{ .icon = .auto_awesome, .size = 40, .color = t.primary },
                        kete.Expanded{ .child = cx.make(kete.Column{
                            .fill = false,
                            .cross_axis_alignment = .start,
                            .spacing = 4,
                            .children = cx.makeAll(.{
                                kete.Text{ .text = "Cards can hold anything", .style = .{ .size = 16, .color = t.on_surface } },
                                kete.Text{ .text = s.log.text("Here an icon, text, and actions."), .style = .{ .size = 13, .color = t.on_surface_variant } },
                            }),
                        }) },
                        kete.TextButton{ .label = "Later", .on_press = common.pressed(cx, &s.log, "Later") },
                        kete.FilledButton{ .label = "Open", .on_press = common.pressed(cx, &s.log, "Open") },
                    }),
                }),
            },
        })),
        common.section(cx, "Lists", "Rows of one or two lines, with icons, text or controls at either end", cx.makeAll(.{
            kete.Card{
                .variant = .outlined,
                .padding = .all(4),
                .child = cx.make(kete.Column{
                    .fill = false,
                    .cross_axis_alignment = .stretch,
                    .children = cx.makeAll(.{
                        kete.ListItem{ .headline = "One line", .selected = s.item == 0, .on_press = choose(cx, &s.item, 0) },
                        kete.HorizontalDivider{ .inset = 16 },
                        kete.ListItem{
                            .headline = "Leading icon and trailing text",
                            .supporting_text = "With a second line of supporting text",
                            .leading_icon = .mail,
                            .trailing_text = "12:30",
                            .selected = s.item == 1,
                            .on_press = choose(cx, &s.item, 1),
                        },
                        kete.HorizontalDivider{ .inset = 16 },
                        kete.ListItem{
                            .headline = "Trailing icon",
                            .supporting_text = "Goes somewhere else",
                            .leading_icon = .settings,
                            .trailing_icon = .chevron_right,
                            .selected = s.item == 2,
                            .on_press = choose(cx, &s.item, 2),
                        },
                        kete.HorizontalDivider{ .inset = 16 },
                        kete.ListItem{
                            .headline = "Wi-Fi",
                            .supporting_text = if (s.wifi) "Connected" else "Off",
                            .leading = cx.make(kete.Badge{ .show = s.wifi, .child = cx.make(kete.Icon{ .icon = .wifi, .color = t.on_surface_variant }) }),
                            .trailing = cx.make(kete.Switch{ .value = s.wifi, .on_changed = .of(s, State.setWifi) }),
                        },
                    }),
                }),
            },
        })),
        common.section(cx, "Dividers", "Lines between content, across or down, full width or inset", cx.makeAll(.{
            kete.HorizontalDivider{},
            kete.HorizontalDivider{ .inset = 48 },
            kete.HorizontalDivider{ .thickness = 4, .color = t.primary },
            kete.SizedBox{
                .height = 32,
                .child = cx.make(kete.Row{
                    .spacing = 12,
                    .cross_axis_alignment = .stretch,
                    .children = cx.makeAll(.{
                        kete.Align.center(cx.make(kete.Text{ .text = "Left", .style = .{ .color = t.on_surface } })),
                        kete.VerticalDivider{},
                        kete.Align.center(cx.make(kete.Text{ .text = "Middle", .style = .{ .color = t.on_surface } })),
                        kete.VerticalDivider{},
                        kete.Align.center(cx.make(kete.Text{ .text = "Right", .style = .{ .color = t.on_surface } })),
                    }),
                }),
            },
        })),
        common.section(cx, "Tabs", "Switching between views at the same level, filling the width or not", cx.makeAll(.{
            kete.TabBar{ .tabs = &tabs, .selected = s.tab, .on_select = .of(s, State.setTab) },
            kete.Text{ .text = tab_text[@min(s.tab, tab_text.len - 1)], .style = .{ .color = t.on_surface_variant } },
            kete.TabBar{ .tabs = &fixed_tabs, .selected = s.fixed_tab, .on_select = .of(s, State.setFixedTab), .expand = false },
        })),
        common.section(cx, "Scrolling", "A scroll view moves what does not fit, with the wheel or by dragging its bar", cx.makeAll(.{
            kete.SizedBox{
                .height = 180,
                .child = cx.make(kete.RoundedBox{
                    .border_color = t.outline_variant,
                    .radius = .all(8),
                    .child = cx.make(kete.ScrollView{ .child = scrollRows(cx, s) }),
                }),
            },
        })),
        common.section(cx, "Virtualized grid", cx.fmt("A grid of {d} cells, making only those in view", .{grid_count}), cx.makeAll(.{
            kete.SizedBox{
                .height = 200,
                .child = cx.make(kete.ScrollView{ .child = cx.make(kete.Grid{
                    .count = grid_count,
                    .cell = .{ .w = 96, .h = 40 },
                    .spacing = 8,
                    .item = .of(s, gridCell),
                }) }),
            },
            common.status(cx, if (s.cell) |c| cx.fmt("Chose cell {d}", .{c + 1}) else "Press a cell"),
        })),
    });
}

fn scrollRows(cx: *kete.BuildContext, s: *State) kete.Widget {
    const rows = cx.arena.alloc(kete.Widget, 30) catch return cx.make(kete.SizedBox.empty);
    for (rows, 0..) |*r, i| {
        r.* = cx.make(kete.ListItem{
            .headline = cx.fmt("Row {d}", .{i + 1}),
            .leading_icon = .label,
            .selected = s.row == i,
            .on_press = choose(cx, &s.row, i),
        });
    }
    return cx.make(kete.Column{ .fill = false, .cross_axis_alignment = .stretch, .children = rows });
}

fn gridCell(s: *State, cx: *kete.BuildContext, i: usize) kete.Widget {
    const t = cx.theme();
    const selected = s.cell == i;
    return cx.make(kete.Card{
        .variant = if (selected) .filled else .outlined,
        .selected = selected,
        .padding = .all(4),
        .radius = 8,
        .on_press = choose(cx, &s.cell, i),
        .child = cx.make(kete.Align.center(cx.make(kete.Text{
            .text = cx.fmt("{d}", .{i + 1}),
            .style = .{ .size = 13, .color = if (selected) t.on_surface else t.on_surface_variant },
            .wrap = false,
        }))),
    });
}
