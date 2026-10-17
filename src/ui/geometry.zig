//! Sizes, constraints, insets and alignment for layout. Units are pixels.

const std = @import("std");
const gfx = @import("gfx");

pub const Point = gfx.Point;
pub const Rect = gfx.Rect;

pub const inf = std.math.inf(f32);

pub const Size = struct {
    w: f32 = 0,
    h: f32 = 0,
};

/// The sizes a parent allows a child: from `min` to `max` in each
/// direction. A max may be infinite (unbounded).
pub const Constraints = struct {
    min_w: f32 = 0,
    max_w: f32 = inf,
    min_h: f32 = 0,
    max_h: f32 = inf,

    pub const unbounded: Constraints = .{};

    /// Exactly this size.
    pub fn tight(s: Size) Constraints {
        return .{ .min_w = s.w, .max_w = s.w, .min_h = s.h, .max_h = s.h };
    }

    /// Up to this size.
    pub fn loose(s: Size) Constraints {
        return .{ .max_w = s.w, .max_h = s.h };
    }

    /// Any size up to the maximum.
    pub fn loosen(c: Constraints) Constraints {
        return .{ .max_w = c.max_w, .max_h = c.max_h };
    }

    /// The nearest size to `s` that is allowed.
    pub fn constrain(c: Constraints, s: Size) Size {
        return .{ .w = std.math.clamp(s.w, c.min_w, c.max_w), .h = std.math.clamp(s.h, c.min_h, c.max_h) };
    }

    /// The biggest size allowed, taking the minimum where it is unbounded.
    pub fn biggest(c: Constraints) Size {
        return .{ .w = if (std.math.isFinite(c.max_w)) c.max_w else c.min_w, .h = if (std.math.isFinite(c.max_h)) c.max_h else c.min_h };
    }

    pub fn smallest(c: Constraints) Size {
        return .{ .w = c.min_w, .h = c.min_h };
    }

    pub fn boundedWidth(c: Constraints) bool {
        return std.math.isFinite(c.max_w);
    }

    pub fn boundedHeight(c: Constraints) bool {
        return std.math.isFinite(c.max_h);
    }

    /// Smaller by the insets (never below zero).
    pub fn deflate(c: Constraints, in: Insets) Constraints {
        const h = in.horizontal();
        const v = in.vertical();
        return (Constraints{ .min_w = c.min_w - h, .max_w = c.max_w - h, .min_h = c.min_h - v, .max_h = c.max_h - v }).sanitize();
    }

    /// `other`, kept within these constraints.
    pub fn enforce(c: Constraints, other: Constraints) Constraints {
        return .{
            .min_w = std.math.clamp(other.min_w, c.min_w, c.max_w),
            .max_w = std.math.clamp(other.max_w, c.min_w, c.max_w),
            .min_h = std.math.clamp(other.min_h, c.min_h, c.max_h),
            .max_h = std.math.clamp(other.max_h, c.min_h, c.max_h),
        };
    }

    /// Makes nonsense usable rather than failing: NaN and negative minima
    /// become 0, NaN or negative maxima become their minimum (or 0), and a
    /// minimum above its maximum is lowered to it. Infinite minima become 0.
    pub fn sanitize(c: Constraints) Constraints {
        var out = c;
        inline for (.{ .{ "min_w", "max_w" }, .{ "min_h", "max_h" } }) |f| {
            var lo = @field(out, f[0]);
            var hi = @field(out, f[1]);
            if (!std.math.isFinite(lo) or lo < 0) lo = 0;
            if (std.math.isNan(hi) or hi < 0) hi = 0;
            if (lo > hi) lo = hi;
            @field(out, f[0]) = lo;
            @field(out, f[1]) = hi;
        }
        return out;
    }

    /// A size a widget returned, made usable: NaN or infinite becomes the
    /// biggest size allowed, then it is constrained.
    pub fn sanitizeSize(c: Constraints, s: Size) Size {
        const big = c.biggest();
        return c.constrain(.{ .w = if (std.math.isFinite(s.w)) s.w else big.w, .h = if (std.math.isFinite(s.h)) s.h else big.h });
    }
};

/// Space around a box's sides.
pub const Insets = struct {
    left: f32 = 0,
    top: f32 = 0,
    right: f32 = 0,
    bottom: f32 = 0,

    pub fn all(v: f32) Insets {
        return .{ .left = v, .top = v, .right = v, .bottom = v };
    }

    /// `h` left and right, `v` above and below.
    pub fn symmetric(h: f32, v: f32) Insets {
        return .{ .left = h, .top = v, .right = h, .bottom = v };
    }

    pub fn horizontal(in: Insets) f32 {
        return in.left + in.right;
    }

    pub fn vertical(in: Insets) f32 {
        return in.top + in.bottom;
    }
};

/// A point in a box: -1 is the left or top edge, 0 the centre, 1 the right
/// or bottom edge.
pub const Alignment = struct {
    x: f32,
    y: f32,

    pub const top_left: Alignment = .{ .x = -1, .y = -1 };
    pub const top_center: Alignment = .{ .x = 0, .y = -1 };
    pub const top_right: Alignment = .{ .x = 1, .y = -1 };
    pub const center_left: Alignment = .{ .x = -1, .y = 0 };
    pub const center: Alignment = .{ .x = 0, .y = 0 };
    pub const center_right: Alignment = .{ .x = 1, .y = 0 };
    pub const bottom_left: Alignment = .{ .x = -1, .y = 1 };
    pub const bottom_center: Alignment = .{ .x = 0, .y = 1 };
    pub const bottom_right: Alignment = .{ .x = 1, .y = 1 };

    /// Where a box of size `inner` goes in one of size `outer`.
    pub fn place(a: Alignment, outer: Size, inner: Size) Point {
        return .{ (outer.w - inner.w) * (a.x + 1) / 2, (outer.h - inner.h) * (a.y + 1) / 2 };
    }
};

const testing = std.testing;

test "constraints survive nonsense" {
    const c = (Constraints{ .min_w = std.math.nan(f32), .max_w = -3, .min_h = 50, .max_h = 20 }).sanitize();
    try testing.expectEqual(Constraints{ .min_w = 0, .max_w = 0, .min_h = 20, .max_h = 20 }, c);
    const u = Constraints.unbounded;
    try testing.expectEqual(Size{ .w = 0, .h = 0 }, u.sanitizeSize(.{ .w = inf, .h = std.math.nan(f32) }));
    try testing.expectEqual(Size{ .w = 100, .h = 7 }, (Constraints{ .max_w = 100 }).sanitizeSize(.{ .w = inf, .h = 7 }));
    // Deflating by more than there is leaves nothing, not less.
    const d = Constraints.tight(.{ .w = 10, .h = 10 }).deflate(.all(8));
    try testing.expectEqual(@as(f32, 0), d.max_w);
}
