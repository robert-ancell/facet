//! Grid of 500 items that can be dragged and dropped into a pinned list (`zig build run-lists`).

const std = @import("std");
const facet = @import("facet");

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

    fn buildGridItem(state: *State, cx: *facet.Context, index: usize) facet.Widget {
        const t = cx.theme();
        const selected = state.selected_item == index;
        const press = cx.arena.create(ItemPress) catch unreachable;
        press.* = .{ .state = state, .index = index };
        const label = cx.fmt("Item #{d}", .{index + 1});

        return cx.make(facet.Draggable{
            .data = index,
            .label = label,
            .icon = .description,
            .on_press = .of(press, ItemPress.press),
            .child = cx.make(facet.Card{
                .variant = if (selected) .filled else .outlined,
                .selected = selected,
                .padding = .all(12),
                .child = cx.make(facet.Row{
                    .spacing = 10,
                    .cross_axis_alignment = .center,
                    .children = &.{
                        cx.make(facet.Icon{
                            .icon = .description,
                            .size = 20,
                            .color = if (selected) t.primary else t.on_surface_variant,
                        }),
                        cx.make(facet.Text{
                            .text = label,
                            .wrap = false,
                        }),
                    },
                }),
            }),
        });
    }

    pub fn build(_: *const ListsAndDragDemo, cx: *facet.Context, state: *State) facet.Widget {
        const t = cx.theme();

        var pinned_widgets: [6]facet.Widget = undefined;
        for (state.pinned[0..state.pinned_len], 0..) |idx, i| {
            pinned_widgets[i] = cx.make(facet.Chip{
                .label = cx.fmt("Item #{d}", .{idx + 1}),
                .icon = .folder,
                .selected = true,
            });
        }

        return cx.make(facet.Column{
            .cross_axis_alignment = .stretch,
            .children = &.{
                cx.make(facet.TitleBar{ .title = "LazyGrid & Drag-and-Drop" }),
                cx.make(facet.Expanded{
                    .child = cx.make(facet.Padding{
                        .padding = .all(20),
                        .child = cx.make(facet.Row{
                            .cross_axis_alignment = .stretch,
                            .spacing = 20,
                            .children = &.{
                                cx.make(facet.Expanded{
                                    .flex = 2,
                                    .child = cx.make(facet.Column{
                                        .cross_axis_alignment = .stretch,
                                        .spacing = 8,
                                        .children = &.{
                                            cx.make(facet.Text{
                                                .text = "Virtualized LazyGrid (500 items — drag any card to the right):",
                                                .style = .{ .size = t.body_size, .color = t.on_surface_variant },
                                            }),
                                            cx.make(facet.Expanded{
                                                .child = cx.make(facet.ScrollView{
                                                    .child = cx.make(facet.LazyGrid{
                                                        .count = item_count,
                                                        .cell = .{ .w = 150, .h = 52 },
                                                        .spacing = 10,
                                                        .item = .of(state, buildGridItem),
                                                    }),
                                                }),
                                            }),
                                        },
                                    }),
                                }),
                                cx.make(facet.SizedBox{
                                    .width = 240,
                                    .child = cx.make(facet.DropTarget{
                                        .on_drop = .of(state, State.addPinned),
                                        .child = cx.make(facet.Card{
                                            .variant = .elevated,
                                            .padding = .all(16),
                                            .child = cx.make(facet.Column{
                                                .cross_axis_alignment = .start,
                                                .spacing = 12,
                                                .children = &.{
                                                    cx.make(facet.Text{
                                                        .text = "Drop Zone (Pinned)",
                                                        .style = .{ .size = 18, .color = t.on_surface },
                                                    }),
                                                    cx.make(facet.Text{
                                                        .text = if (state.selected_item) |sel|
                                                            cx.fmt("Last clicked: Item #{d}", .{sel + 1})
                                                        else
                                                            "Drag items here to pin them.",
                                                        .style = .{ .size = t.body_size, .color = t.on_surface_variant },
                                                    }),
                                                    cx.make(facet.Column{
                                                        .cross_axis_alignment = .start,
                                                        .spacing = 8,
                                                        .children = pinned_widgets[0..state.pinned_len],
                                                    }),
                                                    cx.make(facet.TextButton{
                                                        .label = "Clear pinned",
                                                        .on_press = if (state.pinned_len > 0) .of(state, State.clearPinned) else null,
                                                    }),
                                                },
                                            }),
                                        }),
                                    }),
                                }),
                            },
                        }),
                    }),
                }),
            },
        });
    }
};

pub fn main(init: std.process.Init) !void {
    const app = try facet.App.open(init.gpa, init.minimal.environ, .{
        .title = "Facet Lists & Drag",
        .size = .{ 820, 540 },
    });
    defer app.close();

    while (try app.step(std.math.maxInt(u64))) {
        app.takeInput();
        try app.draw(facet.window.nowNs(), ListsAndDragDemo{});
    }
}

test "ListsAndDragDemo virtualizes LazyGrid items" {
    const ui = try facet.Ui.createDefault(std.testing.allocator);
    defer ui.destroy();

    ui.frame(820, 540, 0, ListsAndDragDemo{});
    const st = ui.root.?.state(ListsAndDragDemo.State);
    try std.testing.expectEqual(@as(usize, 3), st.pinned_len);
    ListsAndDragDemo.State.addPinned(st, 99);
    try std.testing.expectEqual(@as(usize, 4), st.pinned_len);
}
