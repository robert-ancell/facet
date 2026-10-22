//! An app with more than one window (`zig build run-windows`): the main
//! window opens others, each with a counter of its own; closing the main
//! window quits. Each window's handle is kept (closed or not) until the
//! app ends.

const std = @import("std");
const kete = @import("kete");

/// The app's windows: the main one, and those it opened.
const Windows = struct {
    gpa: std.mem.Allocator,
    app: *kete.App,
    main: *kete.Window = undefined,
    others: std.ArrayList(*kete.Window) = .empty,
    opened: u32 = 0,

    fn open(w: *Windows) void {
        w.opened += 1;
        const win = w.app.openWindow(.{
            .title = "Another window",
            .root = .of(&counter),
            .size = .{ 360, 240 },
            .parent = w.main,
            .on_close_request = .close,
        }) catch return;
        w.others.append(w.gpa, win) catch win.destroy();
    }

    fn closeMain(w: *Windows, _: *kete.Window) void {
        w.app.quit();
    }

    /// How many of those it opened are open.
    fn openCount(w: *const Windows) usize {
        var n: usize = 0;
        for (w.others.items) |win| {
            if (!win.isClosed()) n += 1;
        }
        return n;
    }
};

const MainView = struct {
    windows: *Windows,

    pub fn build(self: *const MainView, cx: *kete.BuildContext) kete.Widget {
        return cx.make(kete.Align.center(cx.make(kete.Column{
            .fill = false,
            .cross_axis_alignment = .center,
            .spacing = 16,
            .children = cx.makeAll(.{
                kete.Text{
                    .text = cx.fmt("{d} open of {d} opened", .{ self.windows.openCount(), self.windows.opened }),
                },
                kete.FilledButton{
                    .label = "Open a window",
                    .icon = .add,
                    .on_press = .of(self.windows, Windows.open),
                },
            }),
        })));
    }
};

/// What each window opened draws: a count of its own (its state is its
/// window's UI's).
const counter: Counter = .{};

const Counter = struct {
    pub const State = struct {
        count: i32 = 0,

        pub fn increment(s: *State) void {
            s.count += 1;
        }
    };

    pub fn build(_: *const Counter, cx: *kete.BuildContext, state: *State) kete.Widget {
        return cx.make(kete.Align.center(cx.make(kete.Column{
            .fill = false,
            .cross_axis_alignment = .center,
            .spacing = 16,
            .children = cx.makeAll(.{
                kete.Text{ .text = cx.fmt("Count: {d}", .{state.count}) },
                kete.OutlinedButton{
                    .label = "Count",
                    .on_press = .of(state, State.increment),
                },
            }),
        })));
    }
};

pub fn main(init: std.process.Init) !void {
    const app = try kete.App.init(init.gpa, init.io, init.minimal.environ, .{
        .on_quit_request = .quit,
    });
    defer app.deinit();
    var windows: Windows = .{ .gpa = init.gpa, .app = app };
    defer windows.others.deinit(init.gpa);
    const root: MainView = .{ .windows = &windows };
    windows.main = try app.openWindow(.{
        .title = "Windows",
        .root = .of(&root),
        .size = .{ 480, 320 },
        .on_close_request = .{ .call = .of(&windows, Windows.closeMain) },
    });
    try app.run();
}
