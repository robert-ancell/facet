//! Inbox application with navigation rail, tabs, confirmation dialog, and undo snackbar (`zig build run-navigation`).

const std = @import("std");
const kete = @import("kete");

pub const NavigationDemo = struct {
    pub const State = struct {
        section: usize = 0,
        tab: usize = 0,
        unread: u32 = 3,
        confirm_open: bool = false,
        snackbar_msg: []const u8 = "",

        pub fn selectSection(s: *State, idx: usize) void {
            s.section = idx;
        }

        pub fn selectTab(s: *State, idx: usize) void {
            s.tab = idx;
        }

        pub fn markOneRead(s: *State) void {
            if (s.unread > 0) {
                s.unread -= 1;
                s.snackbar_msg = "Marked 1 message as read";
            }
        }

        pub fn undoRead(s: *State) void {
            s.unread += 1;
            s.snackbar_msg = "";
        }

        pub fn dismissSnackbar(s: *State) void {
            s.snackbar_msg = "";
        }

        pub fn openClearDialog(s: *State) void {
            s.confirm_open = true;
        }

        pub fn confirmClear(s: *State) void {
            s.unread = 0;
            s.confirm_open = false;
            s.snackbar_msg = "Inbox cleared";
        }

        pub fn cancelClear(s: *State) void {
            s.confirm_open = false;
        }
    };

    pub fn build(_: *const NavigationDemo, cx: *kete.BuildContext, state: *State) kete.Widget {
        const rail_items = [_]kete.NavigationRail.Item{
            .{ .label = "Inbox", .icon = .chat, .badge = state.unread },
            .{ .label = "Files", .icon = .folder },
            .{ .label = "Settings", .icon = .settings },
        };
        const tabs = [_]kete.Tab{
            .{ .label = "Primary", .icon = .apps, .badge = state.unread },
            .{ .label = "Updates", .icon = .info },
        };

        const body = cx.make(kete.Row{
            .cross_axis_alignment = .stretch,
            .children = cx.makeAll(.{
                kete.NavigationRail{
                    .items = &rail_items,
                    .selected = state.section,
                    .on_select = .of(state, State.selectSection),
                },
                kete.Divider{ .axis = .vertical },
                kete.Expanded{
                    .child = cx.make(kete.Column{
                        .cross_axis_alignment = .stretch,
                        .children = cx.makeAll(.{
                            kete.TabBar{
                                .tabs = &tabs,
                                .selected = state.tab,
                                .on_select = .of(state, State.selectTab),
                            },
                            kete.Expanded{
                                .child = cx.make(kete.Padding{
                                    .padding = .all(24),
                                    .child = cx.make(kete.Column{
                                        .cross_axis_alignment = .stretch,
                                        .spacing = 12,
                                        .children = cx.makeAll(.{
                                            kete.Row{
                                                .spacing = 12,
                                                .cross_axis_alignment = .center,
                                                .children = cx.makeAll(.{
                                                    kete.Badge{
                                                        .count = state.unread,
                                                        .child = cx.make(kete.Icon{ .icon = .forum, .size = 28 }),
                                                    },
                                                    kete.Text{
                                                        .text = cx.fmt("Section {d} · Tab {d} ({d} unread)", .{ state.section + 1, state.tab + 1, state.unread }),
                                                        .style = .{ .size = 18 },
                                                    },
                                                    kete.Tooltip{
                                                        .text = "Clear all unread items",
                                                        .child = cx.make(kete.IconButton{
                                                            .icon = .delete_sweep,
                                                            .variant = .tonal,
                                                            .on_press = .of(state, State.openClearDialog),
                                                        }),
                                                    },
                                                }),
                                            },
                                            kete.Card{
                                                .variant = .outlined,
                                                .padding = .all(8),
                                                .child = cx.make(kete.Column{
                                                    .cross_axis_alignment = .stretch,
                                                    .children = cx.makeAll(.{
                                                        kete.ListItem{
                                                            .headline = "Welcome to Kete",
                                                            .supporting_text = "Click to mark one message as read",
                                                            .leading_icon = .chat,
                                                            .trailing_icon = .chevron_right,
                                                            .on_press = .of(state, State.markOneRead),
                                                        },
                                                        kete.Divider{},
                                                        kete.ListItem{
                                                            .headline = "System Status",
                                                            .supporting_text = "All rendering backends healthy",
                                                            .leading_icon = .memory,
                                                            .trailing_text = "OK",
                                                        },
                                                    }),
                                                }),
                                            },
                                        }),
                                    }),
                                }),
                            },
                        }),
                    }),
                },
            }),
        });

        const with_snackbar = cx.make(kete.Snackbar{
            .message = state.snackbar_msg,
            .action_label = "Undo",
            .on_action = .of(state, State.undoRead),
            .on_dismiss = .of(state, State.dismissSnackbar),
            .child = body,
        });

        return cx.make(kete.Dialog{
            .open = state.confirm_open,
            .icon = .warning,
            .title = "Clear all messages?",
            .description = "This will reset your unread counter to zero.",
            .dismiss_label = "Cancel",
            .on_dismiss = .of(state, State.cancelClear),
            .confirm_label = "Clear",
            .on_confirm = .of(state, State.confirmClear),
            .child = with_snackbar,
        });
    }
};

pub fn main(init: std.process.Init) !void {
    const app = try kete.App.init(init.gpa, init.io, init.minimal.environ, .{
        .on_quit_request = .quit,
        .on_last_window_closed = .quit,
    });
    defer app.deinit();

    const root = NavigationDemo{};
    _ = try app.openWindow(.{
        .title = "Kete Navigation",
        .root = .of(&root),
        .size = .{ 800, 520 },
        .on_close_request = .close,
    });
    try app.run();
}
