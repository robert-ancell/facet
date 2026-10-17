//! Hello World example: demonstrates basic layout, interactivity, and
//! widget state management with Facet.
//!
//! Run with:
//!     zig build run-hello

const std = @import("std");
const facet = @import("facet");

pub const Counter = struct {
    greeting: []const u8 = "Hello, Facet!",

    pub const State = struct {
        count: i32 = 0,

        pub fn increment(s: *State) void {
            s.count += 1;
        }

        pub fn decrement(s: *State) void {
            s.count -= 1;
        }

        pub fn reset(s: *State) void {
            s.count = 0;
        }
    };

    pub fn build(self: *const Counter, cx: *facet.Context, state: *State) facet.Widget {
        const t = cx.theme();
        return cx.make(facet.Column{
            .cross_axis_alignment = .stretch,
            .children = &.{
                cx.make(facet.TitleBar{ .title = "Hello Facet" }),
                cx.make(facet.Expanded{
                    .child = cx.make(facet.Center{
                        .child = cx.make(facet.Card{
                            .variant = .elevated,
                            .padding = .all(24),
                            .child = cx.make(facet.Column{
                                .main_axis_size = .min,
                                .cross_axis_alignment = .center,
                                .spacing = 16,
                                .children = &.{
                                    cx.make(facet.Text{
                                        .text = self.greeting,
                                        .style = .{ .size = t.title_size, .color = t.on_surface },
                                    }),
                                    cx.make(facet.Text{
                                        .text = cx.fmt("Count: {d}", .{state.count}),
                                        .style = .{ .size = 32, .color = t.primary },
                                    }),
                                    cx.make(facet.Row{
                                        .main_axis_size = .min,
                                        .spacing = 12,
                                        .children = &.{
                                            cx.make(facet.OutlinedButton{
                                                .label = "−1",
                                                .on_press = .of(state, State.decrement),
                                            }),
                                            cx.make(facet.FilledButton{
                                                .label = "+1",
                                                .icon = .add,
                                                .on_press = .of(state, State.increment),
                                            }),
                                            cx.make(facet.TextButton{
                                                .label = "Reset",
                                                .icon = .restart_alt,
                                                .on_press = if (state.count != 0) .of(state, State.reset) else null,
                                            }),
                                        },
                                    }),
                                },
                            }),
                        }),
                    }),
                }),
            },
        });
    }
};

pub fn main(init: std.process.Init) !void {
    const app = try facet.App.open(init.gpa, init.minimal.environ, .{
        .title = "Hello Facet",
        .size = .{ 480, 320 },
    });
    defer app.close();

    while (try app.step(std.math.maxInt(u64))) {
        app.takeInput();
        try app.draw(facet.window.nowNs(), Counter{});
    }
}

test "Counter example builds and updates state" {
    const ui = try facet.Ui.createDefault(std.testing.allocator);
    defer ui.destroy();

    ui.frame(480, 320, 0, Counter{});
    const st = ui.root.?.state(Counter.State);
    try std.testing.expectEqual(@as(i32, 0), st.count);

    Counter.State.increment(st);
    Counter.State.increment(st);
    ui.frame(480, 320, 1, Counter{});
    try std.testing.expectEqual(@as(i32, 2), st.count);
}
