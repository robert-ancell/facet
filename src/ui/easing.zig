//! Easing: functions that reshape an animation's progress `t` (0 at the
//! start, 1 at the end; see `AnimatedWidget`), and interpolation between
//! values by one.
//!
//! Each easing maps 0 to 0 and 1 to 1. Between, `in` starts slowly, `out`
//! ends slowly, and `inOut` does both; `back` and `elastic` overshoot (go
//! outside 0 to 1) on the way.

const std = @import("std");
const gfx = @import("gfx");

/// An easing: progress in, reshaped progress out. The curves are its
/// constants (`Easing.outCubic`), and `lerp` mixes values by one.
pub const Easing = struct {
    f: *const fn (t: f32) f32,

    /// An easing of your own, from a function that maps 0 to 0 and 1 to 1.
    pub fn of(f: *const fn (t: f32) f32) Easing {
        return .{ .f = f };
    }

    /// The reshaped progress for `t`.
    pub fn apply(e: Easing, t: f32) f32 {
        return e.f(t);
    }

    /// From `a` (at `t` = 0) to `b` (at 1), eased: numbers, or vectors such as
    /// points, or colours.
    pub fn lerp(e: Easing, a: anytype, b: @TypeOf(a), t: f32) @TypeOf(a) {
        return mix(a, b, e.f(t));
    }

    /// Goes there and back: 0 to 1 over the first half of `t`, and back to 0
    /// over the second (with this easing each way).
    pub fn pingPong(e: Easing, t: f32) f32 {
        return if (t < 0.5) e.f(t * 2) else e.f((1 - t) * 2);
    }

    /// The easing a CSS `cubic-bezier(x1, y1, x2, y2)` is: a curve from (0, 0)
    /// to (1, 1) with those control points, `t` along x.
    pub fn bezier(comptime x1: f32, comptime y1: f32, comptime x2: f32, comptime y2: f32) Easing {
        return .{ .f = struct {
            fn f(t: f32) f32 {
                return cubicBezier(x1, y1, x2, y2, t);
            }
        }.f };
    }

    /// `steps(n)` jumps from 0 to 1 in `n` equal steps, as on a clock.
    pub fn steps(comptime n: u32) Easing {
        return .{ .f = struct {
            fn f(t: f32) f32 {
                if (t >= 1) return 1;
                const count: f32 = @floatFromInt(n);
                return @floor(@max(t, 0) * count) / count;
            }
        }.f };
    }

    pub const linear: Easing = .{ .f = curves.linear };
    pub const inQuad: Easing = .{ .f = curves.inQuad };
    pub const outQuad: Easing = .{ .f = curves.outQuad };
    pub const inOutQuad: Easing = .{ .f = curves.inOutQuad };
    pub const inCubic: Easing = .{ .f = curves.inCubic };
    pub const outCubic: Easing = .{ .f = curves.outCubic };
    pub const inOutCubic: Easing = .{ .f = curves.inOutCubic };
    pub const inSine: Easing = .{ .f = curves.inSine };
    pub const outSine: Easing = .{ .f = curves.outSine };
    pub const inOutSine: Easing = .{ .f = curves.inOutSine };
    pub const inExpo: Easing = .{ .f = curves.inExpo };
    pub const outExpo: Easing = .{ .f = curves.outExpo };
    pub const inOutExpo: Easing = .{ .f = curves.inOutExpo };
    /// Pulls back a little before going.
    pub const inBack: Easing = .{ .f = curves.inBack };
    /// Goes a little past the end, and comes back.
    pub const outBack: Easing = .{ .f = curves.outBack };
    pub const inOutBack: Easing = .{ .f = curves.inOutBack };
    /// Springs in, swinging about the start.
    pub const inElastic: Easing = .{ .f = curves.inElastic };
    /// Springs out, swinging about the end before it settles.
    pub const outElastic: Easing = .{ .f = curves.outElastic };
    /// Bounces off the start, a little higher each time.
    pub const inBounce: Easing = .{ .f = curves.inBounce };
    /// Drops to the end and bounces there, lower each time.
    pub const outBounce: Easing = .{ .f = curves.outBounce };
    pub const inOutBounce: Easing = .{ .f = curves.inOutBounce };

    /// Material 3's easings (m3.material.io/styles/motion): `standard` for
    /// most motion on screen, and `emphasized` (decelerating as things come
    /// in, accelerating as they leave) for the most noticeable.
    pub const standard: Easing = bezier(0.2, 0, 0, 1);
    pub const standard_decelerate: Easing = bezier(0, 0, 0, 1);
    pub const standard_accelerate: Easing = bezier(0.3, 0, 1, 1);
    pub const emphasized_decelerate: Easing = bezier(0.05, 0.7, 0.1, 1);
    pub const emphasized_accelerate: Easing = bezier(0.3, 0, 0.8, 0.15);
};

/// The curves themselves, as the constants of `Easing` hold them.
const curves = struct {
    fn linear(t: f32) f32 {
        return t;
    }

    fn inQuad(t: f32) f32 {
        return t * t;
    }
    fn outQuad(t: f32) f32 {
        return 1 - inQuad(1 - t);
    }
    fn inOutQuad(t: f32) f32 {
        return inOut(inQuad, t);
    }

    fn inCubic(t: f32) f32 {
        return t * t * t;
    }
    fn outCubic(t: f32) f32 {
        return 1 - inCubic(1 - t);
    }
    fn inOutCubic(t: f32) f32 {
        return inOut(inCubic, t);
    }

    fn inSine(t: f32) f32 {
        return 1 - @cos(t * std.math.pi / 2);
    }
    fn outSine(t: f32) f32 {
        return @sin(t * std.math.pi / 2);
    }
    fn inOutSine(t: f32) f32 {
        return (1 - @cos(t * std.math.pi)) / 2;
    }

    fn inExpo(t: f32) f32 {
        return if (t <= 0) 0 else std.math.pow(f32, 2, 10 * t - 10);
    }
    fn outExpo(t: f32) f32 {
        return 1 - inExpo(1 - t);
    }
    fn inOutExpo(t: f32) f32 {
        return inOut(inExpo, t);
    }

    fn inBack(t: f32) f32 {
        const c = 1.70158;
        return t * t * ((c + 1) * t - c);
    }
    fn outBack(t: f32) f32 {
        return 1 - inBack(1 - t);
    }
    fn inOutBack(t: f32) f32 {
        return inOut(inBack, t);
    }

    fn inElastic(t: f32) f32 {
        return 1 - outElastic(1 - t);
    }
    fn outElastic(t: f32) f32 {
        if (t <= 0) return 0;
        if (t >= 1) return 1;
        return std.math.pow(f32, 2, -10 * t) * @sin((t * 10 - 0.75) * std.math.tau / 3) + 1;
    }

    fn inBounce(t: f32) f32 {
        return 1 - outBounce(1 - t);
    }
    fn outBounce(t: f32) f32 {
        const n: f32 = 7.5625;
        const d: f32 = 2.75;
        if (t < 1 / d) return n * t * t;
        if (t < 2 / d) {
            const u = t - 1.5 / d;
            return n * u * u + 0.75;
        }
        if (t < 2.5 / d) {
            const u = t - 2.25 / d;
            return n * u * u + 0.9375;
        }
        const u = t - 2.625 / d;
        return n * u * u + 0.984375;
    }
    fn inOutBounce(t: f32) f32 {
        return inOut(inBounce, t);
    }

    fn inOut(comptime in: fn (f32) f32, t: f32) f32 {
        return if (t < 0.5) in(t * 2) / 2 else 1 - in((1 - t) * 2) / 2;
    }
};

/// The y of a CSS `cubic-bezier(x1, y1, x2, y2)` curve at x = `t`.
fn cubicBezier(x1: f32, y1: f32, x2: f32, y2: f32, t: f32) f32 {
    if (t <= 0) return 0;
    if (t >= 1) return 1;
    // Find the curve's parameter `s` where x is `t`: Newton's method, which
    // is quick, falling back to halving where the slope is flat.
    var s = t;
    for (0..8) |_| {
        const err = curve(x1, x2, s) - t;
        if (@abs(err) < 1e-6) return curve(y1, y2, s);
        const slope = curveSlope(x1, x2, s);
        if (@abs(slope) < 1e-6) break;
        s -= err / slope;
    }
    var lo: f32 = 0;
    var hi: f32 = 1;
    s = t;
    for (0..32) |_| {
        const x = curve(x1, x2, s);
        if (@abs(x - t) < 1e-6) break;
        if (x < t) lo = s else hi = s;
        s = (lo + hi) / 2;
    }
    return curve(y1, y2, s);
}

/// One coordinate of a cubic Bézier from 0 to 1 with controls `a` and `b`.
fn curve(a: f32, b: f32, s: f32) f32 {
    const u = 1 - s;
    return 3 * u * u * s * a + 3 * u * s * s * b + s * s * s;
}

fn curveSlope(a: f32, b: f32, s: f32) f32 {
    const u = 1 - s;
    return 3 * u * u * a + 6 * u * s * (b - a) + 3 * s * s * (1 - b);
}

/// From `a` (at `t` = 0) to `b` (at 1) by `t`.
fn mix(a: anytype, b: @TypeOf(a), t: f32) @TypeOf(a) {
    const T = @TypeOf(a);
    return switch (@typeInfo(T)) {
        .float, .comptime_float => a + (b - a) * t,
        .array => blk: {
            var out: T = undefined;
            for (&out, a, b) |*o, x, y| o.* = mix(x, y, t);
            break :blk out;
        },
        .@"struct" => if (T == gfx.Color) .{
            .r = mix(a.r, b.r, t),
            .g = mix(a.g, b.g, t),
            .b = mix(a.b, b.b, t),
            .a = mix(a.a, b.a, t),
        } else @compileError("Easing.lerp: no way to mix " ++ @typeName(T)),
        else => @compileError("Easing.lerp: no way to mix " ++ @typeName(T)),
    };
}

const testing = std.testing;

const all = [_]Easing{
    .linear,                .inQuad,         .outQuad,             .inOutQuad,           .inCubic,
    .outCubic,              .inOutCubic,     .inSine,              .outSine,             .inOutSine,
    .inExpo,                .outExpo,        .inOutExpo,           .inBack,              .outBack,
    .inOutBack,             .inElastic,      .outElastic,          .inBounce,            .outBounce,
    .inOutBounce,           .standard,       .standard_decelerate, .standard_accelerate, .emphasized_decelerate,
    .emphasized_accelerate, Easing.steps(4),
};

test "every easing starts at 0 and ends at 1" {
    for (all) |ease| {
        try testing.expectApproxEqAbs(@as(f32, 0), ease.apply(0), 1e-3);
        try testing.expectApproxEqAbs(@as(f32, 1), ease.apply(1), 1e-3);
    }
}

test "easings that do not overshoot only go forward" {
    const forward = [_]Easing{
        .linear,              .inQuad,              .outQuad,               .inOutQuad,             .inCubic,        .outCubic,  .inOutCubic,
        .inSine,              .outSine,             .inOutSine,             .inExpo,                .outExpo,        .inOutExpo, .standard,
        .standard_decelerate, .standard_accelerate, .emphasized_decelerate, .emphasized_accelerate, Easing.steps(4),
    };
    for (forward) |ease| {
        var last: f32 = 0;
        for (0..101) |i| {
            const v = ease.apply(@as(f32, @floatFromInt(i)) / 100);
            try testing.expect(v >= last - 1e-4 and v <= 1 + 1e-4);
            last = v;
        }
    }
}

test "in and out mirror each other, and in-out is halfway at the middle" {
    try testing.expectApproxEqAbs(@as(f32, 0.25), Easing.inQuad.apply(0.5), 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0.75), Easing.outQuad.apply(0.5), 1e-6);
    for ([_]Easing{ .inOutQuad, .inOutCubic, .inOutSine, .inOutExpo, .inOutBack, .inOutBounce }) |ease| {
        try testing.expectApproxEqAbs(@as(f32, 0.5), ease.apply(0.5), 1e-4);
    }
    // Back and elastic overshoot.
    try testing.expect(Easing.inBack.apply(0.2) < 0);
    try testing.expect(Easing.outBack.apply(0.8) > 1);
    var over = false;
    for (1..100) |i| over = over or Easing.outElastic.apply(@as(f32, @floatFromInt(i)) / 100) > 1;
    try testing.expect(over);
}

test "a Bézier easing follows its curve" {
    // A straight line is linear.
    for (0..11) |i| {
        const t = @as(f32, @floatFromInt(i)) / 10;
        try testing.expectApproxEqAbs(t, cubicBezier(0.25, 0.25, 0.75, 0.75, t), 1e-4);
    }
    // CSS's `ease-in-out` is symmetric about the middle.
    try testing.expectApproxEqAbs(@as(f32, 0.5), cubicBezier(0.42, 0, 0.58, 1, 0.5), 1e-4);
    try testing.expectApproxEqAbs(1 - cubicBezier(0.42, 0, 0.58, 1, 0.3), cubicBezier(0.42, 0, 0.58, 1, 0.7), 1e-4);
    // Material's standard easing is well along by halfway.
    try testing.expect(Easing.standard.apply(0.5) > 0.8);
}

test "steps, ping-pong and lerp" {
    const four = Easing.steps(4);
    try testing.expectEqual(@as(f32, 0), four.apply(0.2));
    try testing.expectEqual(@as(f32, 0.25), four.apply(0.3));
    try testing.expectEqual(@as(f32, 0.75), four.apply(0.99));
    try testing.expectApproxEqAbs(@as(f32, 1), Easing.linear.pingPong(0.5), 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0.5), Easing.linear.pingPong(0.75), 1e-6);
    try testing.expectEqual(@as(f32, 15), Easing.linear.lerp(@as(f32, 10), 20, 0.5));
    try testing.expectEqual([2]f32{ 5, 10 }, Easing.linear.lerp([2]f32{ 0, 0 }, .{ 10, 20 }, 0.5));
    const c = Easing.linear.lerp(gfx.Color.rgb(0x000000), gfx.Color.rgb(0xffffff), 0.5);
    try testing.expectApproxEqAbs(@as(f32, 0.5), c.r, 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 1), c.a, 1e-6);
    // An easing shapes `t` before mixing.
    try testing.expectEqual(@as(f32, 12.5), Easing.inQuad.lerp(@as(f32, 10), 20, 0.5));
}
