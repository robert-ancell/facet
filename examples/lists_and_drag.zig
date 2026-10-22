//! Grid of 500 items that can be dragged and dropped into a pinned list (`zig build run-lists`).

const std = @import("std");
const kete = @import("kete");

pub const ListsAndDragDemo = struct {
    pub const item_count = 500;

    pub const State = struct {
        selected_item: ?usize = null,
        pinned: [6]usize = .{ 0, 7, 42, 0, 0, 0 },
        pinned_len: usize = 3,

        pub fn addPinned(s: *State, item_index: usize) void {
            for (s.pinned[0..s.pinned_len]) |existing| {
                if (existing == item_index) return;
            }
            if (s.pinned_len < s.pinned.len) {
                s.pinned[s.pinned_len] = item_index;
                s.pinned_len += 1;
            }
        }

        pub fn clearPinned(s: *State) void {
            s.pinned_len = 0;
        }
    };

    const ItemPress = struct {
        state: *State,
        index: usize,

        fn press(p: *const ItemPress) void {
            p.state.selected_item = p.index;
        }
    };

    fn buildGridItem(state: *State, cx: *kete.BuildContext, index: usize) kete.Widget {
        const t = cx.theme();
        const selected = state.selected_item == index;
        const press = cx.arena.create(ItemPress) catch unreachable;
        press.* = .{ .state = state, .index = index };
        const label = cx.fmt("Item #{d}", .{index + 1});

        return cx.make(kete.Draggable{
            .data = index,
            .label = label,
            .icon = .description,
            .on_press = .of(press, ItemPress.press),
            .child = cx.make(kete.Card{
                .variant = if (selected) .filled else .outlined,
                .selected = selected,
                .padding = .all(12),
                .child = cx.make(kete.Row{
                    .spacing = 10,
                    .cross_axis_alignment = .center,
                    .children = cx.makeAll(.{
                        kete.Icon{
                            .icon = .description,
                            .size = 20,
                            .color = if (selected) t.primary else t.on_surface_variant,
                        },
                        kete.Text{
                            .text = label,
                            .wrap = false,
                        },
                    }),
                }),
            }),
        });
    }

    pub fn build(_: *const ListsAndDragDemo, cx: *kete.BuildContext, state: *State) kete.Widget {
        const t = cx.theme();

        var pinned_widgets: [6]kete.Widget = undefined;
        for (state.pinned[0..state.pinned_len], 0..) |idx, i| {
            pinned_widgets[i] = cx.make(kete.Chip{
                .label = cx.fmt("Item #{d}", .{idx + 1}),
                .icon = .folder,
                .selected = true,
            });
        }

        return cx.make(kete.Padding{
            .padding = .all(20),
            .child = cx.make(kete.Row{
                .cross_axis_alignment = .stretch,
                .spacing = 20,
                .children = cx.makeAll(.{
                    kete.Expanded{
                        .flex = 2,
                        .child = cx.make(kete.Column{
                            .cross_axis_alignment = .stretch,
                            .spacing = 8,
                            .children = cx.makeAll(.{
                                kete.Text{
                                    .text = "Grid (500 items — drag any card to the right):",
                                    .style = .{ .size = t.body_size, .color = t.on_surface_variant },
                                },
                                kete.Expanded{
                                    .child = cx.make(kete.ScrollView{
                                        .child = cx.make(kete.Grid{
                                            .count = item_count,
                                            .cell = .{ .w = 150, .h = 52 },
                                            .spacing = 10,
                                            .item = .of(state, buildGridItem),
                                        }),
                                    }),
                                },
                            }),
                        }),
                    },
                    kete.SizedBox{
                        .width = 240,
                        .child = cx.make(kete.DropTarget{
                            .on_drop = .of(state, State.addPinned),
                            .child = cx.make(kete.Card{
                                .variant = .elevated,
                                .padding = .all(16),
                                .child = cx.make(kete.Column{
                                    .cross_axis_alignment = .start,
                                    .spacing = 12,
                                    .children = cx.makeAll(.{
                                        kete.Text{
                                            .text = "Drop Zone (Pinned)",
                                            .style = .{ .size = 18, .color = t.on_surface },
                                        },
                                        kete.Text{
                                            .text = if (state.selected_item) |sel|
                                                cx.fmt("Last clicked: Item #{d}", .{sel + 1})
                                            else
                                                "Drag items here to pin them.",
                                            .style = .{ .size = t.body_size, .color = t.on_surface_variant },
                                        },
                                        kete.Column{
                                            .cross_axis_alignment = .start,
                                            .spacing = 8,
                                            .children = pinned_widgets[0..state.pinned_len],
                                        },
                                        kete.TextButton{
                                            .label = "Clear pinned",
                                            .on_press = if (state.pinned_len > 0) .of(state, State.clearPinned) else null,
                                        },
                                    }),
                                }),
                            }),
                        }),
                    },
                }),
            }),
        });
    }
};

pub fn main(init: std.process.Init) !void {
    const app = try kete.App.init(init.gpa, init.io, init.minimal.environ, .{
        .on_quit_request = .quit,
        .on_last_window_closed = .quit,
    });
    defer app.deinit();

    const root = ListsAndDragDemo{};
    _ = try app.openWindow(.{
        .title = "Kete Lists & Drag",
        .root = .of(&root),
        .size = .{ 820, 540 },
        .on_close_request = .close,
    });
    try app.run();
}
