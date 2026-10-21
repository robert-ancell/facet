//! An app with more than one window (`zig build run-windows`): the main
//! window opens others, each with a counter of its own; closing the main
//! window quits.

const std = @import("std");
const facet = @import("facet");

/// The app's windows: the main one, and those it opened.
const Windows = struct {
    gpa: std.mem.Allocator,
    app: *facet.App,
    main: *facet.App.Window = undefined,
    others: std.ArrayList(*facet.App.Window) = .empty,
    opened: u32 = 0,

    fn open(w: *Windows) void {
        w.opened += 1;
        const win = w.app.openWindow(.{
            .title = "Another window",
            .size = .{ 360, 240 },
            .parent = w.main,
            .on_close_request = .close,
        }) catch return;
        w.others.append(w.gpa, win) catch win.destroy();
    }

    fn closeMain(w: *Windows, _: *facet.App.Window) void {
        w.app.quit();
    }

    /// Draws each window opened, and lets go of those closed.
    fn draw(w: *Windows) !void {
        var i: usize = 0;
        while (i < w.others.items.len) {
            const win = w.others.items[i];
            if (win.isClosed()) {
                win.destroy();
                _ = w.others.orderedRemove(i);
                continue;
            }
            try win.draw(Counter{});
            i += 1;
        }
    }
};

const MainView = struct {
    windows: *Windows,

    pub fn build(self: *const MainView, cx: *facet.Context) facet.Widget {
        return cx.make(facet.Center{
            .child = cx.make(facet.Column{
                .main_axis_size = .min,
                .cross_axis_alignment = .center,
                .spacing = 16,
                .children = &.{
                    cx.make(facet.Text{
                        .text = cx.fmt("{d} open of {d} opened", .{ self.windows.others.items.len, self.windows.opened }),
                    }),
                    cx.make(facet.FilledButton{
                        .label = "Open a window",
                        .icon = .add,
                        .on_press = .of(self.windows, Windows.open),
                    }),
                },
            }),
        });
    }
};

/// A window's own count (its state is its window's UI's).
const Counter = struct {
    pub const State = struct {
        count: i32 = 0,

        pub fn increment(s: *State) void {
            s.count += 1;
        }
    };

    pub fn build(_: *const Counter, cx: *facet.Context, state: *State) facet.Widget {
        return cx.make(facet.Center{
            .child = cx.make(facet.Column{
                .main_axis_size = .min,
                .cross_axis_alignment = .center,
                .spacing = 16,
                .children = &.{
                    cx.make(facet.Text{ .text = cx.fmt("Count: {d}", .{state.count}) }),
                    cx.make(facet.OutlinedButton{
                        .label = "Count",
                        .on_press = .of(state, State.increment),
                    }),
                },
            }),
        });
    }
};

pub fn main(init: std.process.Init) !void {
    const app = try facet.App.init(init.gpa, init.io, init.minimal.environ, .{
        .on_quit_request = .quit,
    });
    defer app.deinit();
    var windows: Windows = .{ .gpa = init.gpa, .app = app };
    defer windows.others.deinit(init.gpa);
    windows.main = try app.openWindow(.{
        .title = "Windows",
        .size = .{ 480, 320 },
        .on_close_request = .{ .call = .of(&windows, Windows.closeMain) },
    });

    while (try app.step(std.math.maxInt(u64))) {
        app.takeInput();
        try windows.main.draw(MainView{ .windows = &windows });
        try windows.draw();
    }
}
