//! Interactive counter application (`zig build run-hello`).

const std = @import("std");
const kete = @import("kete");

pub const Counter = struct {
    pub const State = struct {
        count: i32 = 0,

        pub fn increment(s: *State) void {
            s.count += 1;
        }

        pub fn decrement(s: *State) void {
            s.count -= 1;
        }
    };

    pub fn build(_: *const Counter, cx: *kete.BuildContext, state: *State) kete.Widget {
        return cx.make(kete.Align.center(cx.make(kete.Column{
            .fill = false,
            .cross_axis_alignment = .center,
            .spacing = 16,
            .children = cx.makeAll(.{
                kete.Text{
                    .text = "Hello, Kete!",
                },
                kete.Text{
                    .text = cx.fmt("Count: {d}", .{state.count}),
                },
                kete.Row{
                    .fill = false,
                    .spacing = 12,
                    .children = cx.makeAll(.{
                        kete.OutlinedButton{
                            .icon = .remove,
                            .on_press = .of(state, State.decrement),
                        },
                        kete.FilledButton{
                            .icon = .add,
                            .on_press = .of(state, State.increment),
                        },
                    }),
                },
            }),
        })));
    }
};

pub fn main(init: std.process.Init) !void {
    const app = try kete.App.init(init.gpa, init.io, init.minimal.environ, .{
        .on_quit_request = .quit,
        .on_last_window_closed = .quit,
    });
    defer app.deinit();

    const root: Counter = .{};
    _ = try app.openWindow(.{
        .title = "Hello Kete",
        .root = .of(&root),
        .size = .{ 480, 320 },
        .on_close_request = .close,
    });
    try app.run();
}
