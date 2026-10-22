//! AnimatedWidget: a child made afresh each frame of an animation, from how
//! far through it the frame is: `t`, from 0 at the start to 1 at the end of
//! `duration_ns`. Shape `t` with an `Easing`, and turn it into positions,
//! sizes and colours with `Easing.lerp`:
//!
//!     fn slide(state: *State, cx: *Context, t: f32) Widget {
//!         return cx.make(Align{
//!             .alignment = .{ .x = Easing.outCubic.lerp(-1, 1, t), .y = 0 },
//!             .child = ...,
//!         });
//!     }
//!
//!     cx.make(AnimatedWidget{ .duration_ns = 300 * std.time.ns_per_ms, .builder = .of(state, slide) })
//!
//! It starts the first frame it is built, and again whenever `restart`
//! changes; while it runs it asks for frames, and once it is over (if it
//! does not repeat) it asks for no more, its child made with `t` = 1.

const std = @import("std");
const widget = @import("widget.zig");

const Widget = widget.Widget;
const Context = widget.Context;

pub const AnimatedWidget = struct {
    /// How long it takes, from `t` = 0 to 1.
    duration_ns: u64,
    /// Makes the child for each frame, given `t`.
    builder: Builder,
    repeat: Repeat = .once,
    /// Starts it over when this changes: a count of presses of a "Play"
    /// button, say.
    restart: u64 = 0,
    /// Waits this long before starting (with `t` = 0 meanwhile).
    delay_ns: u64 = 0,

    pub const Repeat = enum {
        /// Once, ending at `t` = 1.
        once,
        /// Over and over, from 0 to 1 each time.
        loop,
        /// Back and forth: 0 to 1, then 1 to 0, and so on.
        reverse,
    };

    /// Makes the child (in the frame's arena, with `cx.make`) from `t`.
    pub const Builder = struct {
        ctx: *const anyopaque,
        f: *const fn (*const anyopaque, *Context, f32) Widget,

        /// `f(ptr, cx, t)`: with a pointer, typically to the app's state.
        pub fn of(ptr: anytype, comptime f: fn (@TypeOf(ptr), *Context, f32) Widget) Builder {
            const P = @TypeOf(ptr);
            return .{ .ctx = @ptrCast(ptr), .f = struct {
                fn call(ctx: *const anyopaque, cx: *Context, t: f32) Widget {
                    return f(@as(P, @ptrCast(@alignCast(@constCast(ctx)))), cx, t);
                }
            }.call };
        }

        /// `f(cx, t)`: needing nothing else.
        pub fn func(comptime f: fn (*Context, f32) Widget) Builder {
            return .{ .ctx = &none, .f = struct {
                fn call(_: *const anyopaque, cx: *Context, t: f32) Widget {
                    return f(cx, t);
                }
            }.call };
        }
    };

    const none: u8 = 0;

    pub const State = struct {
        start_ns: ?u64 = null,
        restart: u64 = 0,
    };

    pub fn build(self: *const AnimatedWidget, cx: *Context, state: *State) Widget {
        const now = cx.now();
        if (state.start_ns == null or state.restart != self.restart) {
            state.start_ns = now;
            state.restart = self.restart;
        }
        const elapsed = now -| state.start_ns.?;
        const t, const running = self.progress(elapsed);
        if (running) cx.requestFrame();
        return self.builder.f(self.builder.ctx, cx, t);
    }

    /// How far through it is `elapsed_ns` after it started, and whether it
    /// is still going.
    pub fn progress(self: *const AnimatedWidget, elapsed_ns: u64) struct { f32, bool } {
        if (elapsed_ns < self.delay_ns) return .{ 0, true };
        const into = elapsed_ns - self.delay_ns;
        if (self.duration_ns == 0) return .{ 1, false };
        const cycles = @as(f64, @floatFromInt(into)) / @as(f64, @floatFromInt(self.duration_ns));
        return switch (self.repeat) {
            .once => if (cycles >= 1) .{ 1, false } else .{ @floatCast(cycles), true },
            .loop => .{ @floatCast(cycles - @floor(cycles)), true },
            .reverse => blk: {
                const phase = @mod(cycles, 2);
                break :blk .{ @floatCast(if (phase <= 1) phase else 2 - phase), true };
            },
        };
    }
};
