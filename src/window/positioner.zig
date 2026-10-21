//! Where a popup goes, as Wayland's `xdg_positioner` says: a size, a
//! rectangle it is placed against (the anchor), the point of it the popup
//! is placed at (`anchor`), which way the popup goes from there
//! (`gravity`), an offset, and how it is moved if it would not fit on the
//! screen (`adjust`: flipped to the other side, or slid along).
//!
//! On Wayland the compositor places popups from these; on macOS and
//! Windows `place` does, by the same rules, so that a `PopupPlacement`
//! means the same on each.

const std = @import("std");

/// An edge or corner of a rectangle, or its centre (`none`), numbered as
/// `xdg_positioner`'s `anchor` and `gravity`.
pub const Edge = enum(u32) {
    none = 0,
    top = 1,
    bottom = 2,
    left = 3,
    right = 4,
    top_left = 5,
    bottom_left = 6,
    top_right = 7,
    bottom_right = 8,

    /// Which way along x (-1 left, 0 the middle, 1 right) and along y (-1
    /// up, 0 the middle, 1 down) it is.
    fn dirs(e: Edge) [2]i32 {
        return switch (e) {
            .none => .{ 0, 0 },
            .top => .{ 0, -1 },
            .bottom => .{ 0, 1 },
            .left => .{ -1, 0 },
            .right => .{ 1, 0 },
            .top_left => .{ -1, -1 },
            .bottom_left => .{ -1, 1 },
            .top_right => .{ 1, -1 },
            .bottom_right => .{ 1, 1 },
        };
    }

    fn ofDirs(d: [2]i32) Edge {
        return switch (d[0]) {
            -1 => switch (d[1]) {
                -1 => .top_left,
                1 => .bottom_left,
                else => .left,
            },
            1 => switch (d[1]) {
                -1 => .top_right,
                1 => .bottom_right,
                else => .right,
            },
            else => switch (d[1]) {
                -1 => .top,
                1 => .bottom,
                else => .none,
            },
        };
    }

    /// Mirrored along `axis` (0: x, 1: y).
    fn flipped(e: Edge, axis: usize) Edge {
        var d = e.dirs();
        d[axis] = -d[axis];
        return ofDirs(d);
    }
};

/// How a popup is moved if it would not fit (`xdg_positioner`'s
/// `constraint_adjustment`, numbered alike; resizing is not done).
pub const Adjust = packed struct(u32) {
    slide_x: bool = false,
    slide_y: bool = false,
    flip_x: bool = false,
    flip_y: bool = false,
    _rest: u28 = 0,
};

/// A rectangle, `[x, y, width, height]`.
pub const Rect = [4]i32;

pub const Positioner = struct {
    size: [2]i32,
    anchor_rect: Rect,
    anchor: Edge,
    gravity: Edge,
    offset: [2]i32 = .{ 0, 0 },
    adjust: Adjust = .{},

    /// Where its top left goes (in the coordinates of `anchor_rect`), kept
    /// within `bounds` (the screen, or the part of it windows may use)
    /// as `adjust` allows.
    pub fn place(p: Positioner, bounds: Rect) [2]i32 {
        var out: [2]i32 = undefined;
        inline for (0..2) |axis| {
            const flip = if (axis == 0) p.adjust.flip_x else p.adjust.flip_y;
            const slide = if (axis == 0) p.adjust.slide_x else p.adjust.slide_y;
            var at = p.along(axis, p.anchor, p.gravity, p.offset[axis]);
            if (flip and p.constrained(axis, at, bounds)) {
                // Flipped, unless that does not fit either.
                const other = p.along(axis, p.anchor.flipped(axis), p.gravity.flipped(axis), -p.offset[axis]);
                if (!p.constrained(axis, other, bounds)) at = other;
            }
            if (slide and p.constrained(axis, at, bounds)) {
                const lo = bounds[axis];
                const hi = bounds[axis] + bounds[axis + 2];
                if (at + p.size[axis] > hi) at = hi - p.size[axis];
                // Too big to fit: against the start edge.
                if (at < lo) at = lo;
            }
            out[axis] = at;
        }
        return out;
    }

    /// Where it starts along `axis`, placed with `anchor` and `gravity`.
    fn along(p: Positioner, comptime axis: usize, anchor: Edge, gravity: Edge, offset: i32) i32 {
        const start = p.anchor_rect[axis];
        const len = p.anchor_rect[axis + 2];
        const point = switch (anchor.dirs()[axis]) {
            -1 => start,
            1 => start + len,
            else => start + @divTrunc(len, 2),
        };
        const s = p.size[axis];
        const from = switch (gravity.dirs()[axis]) {
            // It goes before the point (up, or left), after it, or is
            // centred on it.
            -1 => point - s,
            1 => point,
            else => point - @divTrunc(s, 2),
        };
        return from + offset;
    }

    fn constrained(p: Positioner, comptime axis: usize, at: i32, bounds: Rect) bool {
        return at < bounds[axis] or at + p.size[axis] > bounds[axis] + bounds[axis + 2];
    }
};

const testing = std.testing;
const screen: Rect = .{ 0, 0, 1000, 800 };

fn menuAt(x: i32, y: i32, size: [2]i32) Positioner {
    return .{
        .size = size,
        .anchor_rect = .{ x, y, 1, 1 },
        .anchor = .top_left,
        .gravity = .bottom_right,
        .offset = .{ 4, 4 },
        .adjust = .{ .flip_x = true, .flip_y = true, .slide_x = true, .slide_y = true },
    };
}

test "a popup with room goes where its anchor and gravity say" {
    try testing.expectEqual([2]i32{ 104, 54 }, menuAt(100, 50, .{ 200, 300 }).place(screen));
}

test "a popup without room flips to the other side of its anchor" {
    // At the right edge: it goes left of the point instead (its offset too).
    try testing.expectEqual([2]i32{ 950 + 1 - 200 - 4, 54 }, menuAt(950, 50, .{ 200, 300 }).place(screen));
    // At the bottom: above it.
    try testing.expectEqual([2]i32{ 104, 700 + 1 - 300 - 4 }, menuAt(100, 700, .{ 200, 300 }).place(screen));
}

test "a popup that would not fit flipped either slides instead" {
    // 700 tall at y 400 fits neither below (400 to 1100) nor above (-300):
    // slid up to end at the bottom.
    try testing.expectEqual([2]i32{ 104, 100 }, menuAt(100, 400, .{ 200, 700 }).place(screen));
}

test "a popup bigger than the screen is put against its start" {
    try testing.expectEqual([2]i32{ 0, 54 }, menuAt(500, 50, .{ 1200, 300 }).place(screen));
}

test "a popup without the adjustments stays where it is put" {
    var p = menuAt(950, 750, .{ 200, 300 });
    p.adjust = .{};
    try testing.expectEqual([2]i32{ 954, 754 }, p.place(screen));
}

test "a tooltip goes centred above its anchor, or below it if there is no room" {
    const tip: Positioner = .{
        .size = .{ 100, 30 },
        .anchor_rect = .{ 200, 300, 40, 20 },
        .anchor = .top,
        .gravity = .top,
        .offset = .{ 0, -6 },
        .adjust = .{ .flip_y = true, .slide_x = true, .slide_y = true },
    };
    try testing.expectEqual([2]i32{ 170, 264 }, tip.place(screen));
    var low = tip;
    low.anchor_rect = .{ 200, 10, 40, 20 };
    try testing.expectEqual([2]i32{ 170, 36 }, low.place(screen));
    // Near the left edge: slid in.
    var left = tip;
    left.anchor_rect = .{ 0, 300, 40, 20 };
    try testing.expectEqual([2]i32{ 0, 264 }, left.place(screen));
}

test "bounds need not start at the origin" {
    // A second monitor, to the left and above.
    const other: Rect = .{ -1920, -200, 1920, 1080 };
    try testing.expectEqual([2]i32{ -200 + 1 - 300 - 4, 54 }, menuAt(-200, 50, .{ 300, 200 }).place(other));
}

test "the numbers are xdg_positioner's" {
    const p = @import("wayland").protocol.xdg_positioner;
    try testing.expectEqual(@as(u32, p.anchor.top_left), @intFromEnum(Edge.top_left));
    try testing.expectEqual(@as(u32, p.anchor.bottom_right), @intFromEnum(Edge.bottom_right));
    try testing.expectEqual(@as(u32, p.anchor.top), @intFromEnum(Edge.top));
    const a = p.constraint_adjustment;
    try testing.expectEqual(@as(u32, a.slide_x | a.flip_y), @as(u32, @bitCast(Adjust{ .slide_x = true, .flip_y = true })));
}

test "edges flip along one axis" {
    try testing.expectEqual(Edge.top_right, Edge.top_left.flipped(0));
    try testing.expectEqual(Edge.bottom_left, Edge.top_left.flipped(1));
    try testing.expectEqual(Edge.bottom, Edge.top.flipped(1));
    try testing.expectEqual(Edge.top, Edge.top.flipped(0));
}
