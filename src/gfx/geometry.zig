//! Tessellating 2D shapes on the CPU into triangles with a coverage alpha
//! per vertex: polygons (ear clipping) and polylines (strips with mitred
//! joins). Edges are anti-aliased with a fringe one pixel wide, centred on
//! the edge, whose alpha falls from 1 inside to 0 outside: the same
//! coverage a pixel-wide box filter gives a straight edge.

const std = @import("std");

pub const Point = [2]f32;

/// A triangle corner: a position in pixels and its coverage.
pub const Vertex = struct { x: f32, y: f32, alpha: f32 };

/// Where triangles go (the canvas, or a list in tests).
pub const Sink = struct {
    ptr: *anyopaque,
    triangle: *const fn (ptr: *anyopaque, a: Vertex, b: Vertex, c: Vertex) void,

    fn tri(s: Sink, a: Vertex, b: Vertex, c: Vertex) void {
        s.triangle(s.ptr, a, b, c);
    }

    /// A quad a-b-c-d (in order around it) as two triangles.
    pub fn quad(s: Sink, a: Vertex, b: Vertex, c: Vertex, d: Vertex) void {
        s.tri(a, b, c);
        s.tri(a, c, d);
    }
};

/// How far a mitred corner may stick out, in multiples of the offset;
/// sharper corners are cut off there.
pub const miter_limit = 4;

fn sub(a: Point, b: Point) Point {
    return .{ a[0] - b[0], a[1] - b[1] };
}

fn add(a: Point, b: Point) Point {
    return .{ a[0] + b[0], a[1] + b[1] };
}

fn scale(a: Point, k: f32) Point {
    return .{ a[0] * k, a[1] * k };
}

fn cross(a: Point, b: Point) f32 {
    return a[0] * b[1] - a[1] * b[0];
}

fn dot(a: Point, b: Point) f32 {
    return a[0] * b[0] + a[1] * b[1];
}

fn normalize(a: Point) ?Point {
    const len = @sqrt(dot(a, a));
    if (len < 1e-6) return null;
    return scale(a, 1 / len);
}

/// The unit normal to the left of the direction a -> b (with y down, the
/// right-hand side on screen).
fn leftNormal(a: Point, b: Point) ?Point {
    const d = normalize(sub(b, a)) orelse return null;
    return .{ -d[1], d[0] };
}

/// The offset of a mitred corner between two edges with unit normals n1 and
/// n2: moving the corner by it moves both edges by 1 along their normals.
fn miter(n1: Point, n2: Point) Point {
    const m = add(n1, n2);
    const k = 1 + dot(n1, n2);
    if (k < 1e-4) return n1; // A U-turn: no corner to speak of.
    var out = scale(m, 1 / k);
    const len = @sqrt(dot(out, out));
    if (len > miter_limit) out = scale(out, miter_limit / len);
    return out;
}

/// Twice the polygon's signed area: positive when its points turn the way
/// `leftNormal` points.
pub fn signedArea2(points: []const Point) f32 {
    var a: f32 = 0;
    for (points, 0..) |p, i| a += cross(p, points[(i + 1) % points.len]);
    return a;
}

/// Points without consecutive duplicates (and no closing duplicate).
fn dedupe(buf: []Point, points: []const Point) []Point {
    var n: usize = 0;
    for (points) |p| {
        if (n > 0 and @abs(p[0] - buf[n - 1][0]) < 1e-4 and @abs(p[1] - buf[n - 1][1]) < 1e-4) continue;
        if (n == buf.len) break;
        buf[n] = p;
        n += 1;
    }
    while (n > 1 and @abs(buf[0][0] - buf[n - 1][0]) < 1e-4 and @abs(buf[0][1] - buf[n - 1][1]) < 1e-4) n -= 1;
    return buf[0..n];
}

pub const max_points = 512;

/// Fills a simple polygon (convex or concave, not self-intersecting).
pub fn fillPolygon(out: Sink, points_in: []const Point) void {
    var buf: [max_points]Point = undefined;
    const points = dedupe(&buf, points_in);
    const n = points.len;
    if (n < 3) return;
    const area = signedArea2(points);
    if (@abs(area) < 1e-6) return;
    // Outward is to the right of each edge when the area is positive.
    const outward: f32 = if (area > 0) -1 else 1;

    // Each corner moved half a pixel in (solid inside) and out (where the
    // fringe fades to nothing).
    var inner: [max_points]Point = undefined;
    var outer: [max_points]Point = undefined;
    for (0..n) |i| {
        const prev = points[(i + n - 1) % n];
        const p = points[i];
        const next = points[(i + 1) % n];
        const n1 = leftNormal(prev, p) orelse leftNormal(p, next).?;
        const n2 = leftNormal(p, next) orelse n1;
        const m = scale(miter(n1, n2), outward * 0.5);
        inner[i] = sub(p, m);
        outer[i] = add(p, m);
    }

    triangulate(out, inner[0..n], area > 0);
    for (0..n) |i| {
        const j = (i + 1) % n;
        out.quad(
            .{ .x = inner[i][0], .y = inner[i][1], .alpha = 1 },
            .{ .x = inner[j][0], .y = inner[j][1], .alpha = 1 },
            .{ .x = outer[j][0], .y = outer[j][1], .alpha = 0 },
            .{ .x = outer[i][0], .y = outer[i][1], .alpha = 0 },
        );
    }
}

/// Ear clipping: repeatedly cuts off a corner that is convex and has no
/// other point inside it. `positive` is the polygon's winding.
fn triangulate(out: Sink, points: []const Point, positive: bool) void {
    var idx: [max_points]u16 = undefined;
    var n = points.len;
    for (idx[0..n], 0..) |*x, i| x.* = @intCast(i);
    const sign: f32 = if (positive) 1 else -1;
    var guard: usize = 0;
    var i: usize = 0;
    while (n > 3 and guard < 2 * n) {
        const a = points[idx[(i + n - 1) % n]];
        const b = points[idx[i % n]];
        const c = points[idx[(i + 1) % n]];
        const convex = cross(sub(b, a), sub(c, b)) * sign > 0;
        var ear = convex;
        if (ear) for (idx[0..n]) |k| {
            const p = points[k];
            if (std.meta.eql(p, a) or std.meta.eql(p, b) or std.meta.eql(p, c)) continue;
            if (inTriangle(p, a, b, c, sign)) {
                ear = false;
                break;
            }
        };
        if (ear) {
            out.tri(.{ .x = a[0], .y = a[1], .alpha = 1 }, .{ .x = b[0], .y = b[1], .alpha = 1 }, .{ .x = c[0], .y = c[1], .alpha = 1 });
            std.mem.copyForwards(u16, idx[i % n .. n - 1], idx[i % n + 1 .. n]);
            n -= 1;
            guard = 0;
        } else {
            i += 1;
            guard += 1;
        }
        i %= n;
    }
    if (n == 3) {
        const a = points[idx[0]];
        const b = points[idx[1]];
        const c = points[idx[2]];
        out.tri(.{ .x = a[0], .y = a[1], .alpha = 1 }, .{ .x = b[0], .y = b[1], .alpha = 1 }, .{ .x = c[0], .y = c[1], .alpha = 1 });
    }
}

fn inTriangle(p: Point, a: Point, b: Point, c: Point, sign: f32) bool {
    return cross(sub(b, a), sub(p, a)) * sign >= 0 and
        cross(sub(c, b), sub(p, b)) * sign >= 0 and
        cross(sub(a, c), sub(p, c)) * sign >= 0;
}

/// Strokes a polyline `width` pixels wide, centred on it, with mitred joins
/// and butt ends (closing it back to the start if `closed`).
pub fn strokePolyline(out: Sink, points_in: []const Point, closed: bool, width: f32) void {
    var buf: [max_points]Point = undefined;
    const points = dedupe(&buf, points_in);
    const n = points.len;
    if (n < 2 or width <= 0) return;
    // Lines thinner than a pixel are drawn a pixel wide but fainter.
    const alpha: f32 = @min(width, 1);
    const half = @max(width, 1) / 2;
    const segments = if (closed) n else n - 1;

    // The offset (unit distance) at each point, mitred between segments.
    var offset: [max_points]Point = undefined;
    for (0..n) |i| {
        const has_prev = closed or i > 0;
        const has_next = closed or i + 1 < n;
        const prev_n = if (has_prev) leftNormal(points[(i + n - 1) % n], points[i]) else null;
        const next_n = if (has_next) leftNormal(points[i], points[(i + 1) % n]) else null;
        offset[i] = if (prev_n != null and next_n != null) miter(prev_n.?, next_n.?) else (prev_n orelse next_n orelse .{ 0, 0 });
    }

    // Open ends: the solid part stops half a pixel short of the end, and
    // fades out to half a pixel beyond it.
    var pos: [max_points]Point = undefined;
    @memcpy(pos[0..n], points);
    var ends: [2]?struct { inner: Point, outer: Point, at: usize } = .{ null, null };
    if (!closed) {
        for ([_]struct { usize, usize }{ .{ 0, 1 }, .{ n - 1, n - 2 } }, 0..) |e, k| {
            const dir = normalize(sub(points[e[0]], points[e[1]])) orelse continue;
            pos[e[0]] = sub(points[e[0]], scale(dir, 0.5));
            ends[k] = .{ .inner = pos[e[0]], .outer = add(points[e[0]], scale(dir, 0.5)), .at = e[0] };
        }
    }

    // Four rails across the line: faded edge, solid edge, solid edge,
    // faded edge.
    const rails = [4]struct { f32, f32 }{ .{ half + 0.5, 0 }, .{ half - 0.5, alpha }, .{ -(half - 0.5), alpha }, .{ -(half + 0.5), 0 } };
    for (0..segments) |i| {
        const j = (i + 1) % n;
        for (0..3) |r| {
            out.quad(
                railVertex(pos[i], offset[i], rails[r]),
                railVertex(pos[j], offset[j], rails[r]),
                railVertex(pos[j], offset[j], rails[r + 1]),
                railVertex(pos[i], offset[i], rails[r + 1]),
            );
        }
    }
    for (ends) |maybe| {
        const e = maybe orelse continue;
        for (0..3) |r| {
            var a1 = railVertex(e.outer, offset[e.at], rails[r]);
            var b1 = railVertex(e.outer, offset[e.at], rails[r + 1]);
            a1.alpha = 0;
            b1.alpha = 0;
            out.quad(railVertex(e.inner, offset[e.at], rails[r]), a1, b1, railVertex(e.inner, offset[e.at], rails[r + 1]));
        }
    }
}

fn railVertex(p: Point, offset: Point, rail: struct { f32, f32 }) Vertex {
    const q = add(p, scale(offset, rail[0]));
    return .{ .x = q[0], .y = q[1], .alpha = rail[1] };
}

// --- Tests ----------------------------------------------------------------------

const Collect = struct {
    tris: [2048][3]Vertex = undefined,
    n: usize = 0,

    fn sink(c: *Collect) Sink {
        return .{ .ptr = c, .triangle = add3 };
    }
    fn add3(ptr: *anyopaque, a: Vertex, b: Vertex, cc: Vertex) void {
        const c: *Collect = @ptrCast(@alignCast(ptr));
        c.tris[c.n] = .{ a, b, cc };
        c.n += 1;
    }

    /// The coverage-weighted area: the solid parts count fully, the
    /// fringes (which fade linearly) by their average alpha.
    fn area(c: *const Collect) f32 {
        var total: f32 = 0;
        for (c.tris[0..c.n]) |t| {
            const a2 = @abs(cross(.{ t[1].x - t[0].x, t[1].y - t[0].y }, .{ t[2].x - t[0].x, t[2].y - t[0].y }));
            total += a2 / 2 * (t[0].alpha + t[1].alpha + t[2].alpha) / 3;
        }
        return total;
    }
};

test "polygons fill their area, concave ones included" {
    // A 10x10 square, either winding.
    var c: Collect = .{};
    fillPolygon(c.sink(), &.{ .{ 0, 0 }, .{ 10, 0 }, .{ 10, 10 }, .{ 0, 10 } });
    try std.testing.expectApproxEqAbs(@as(f32, 100), c.area(), 0.5);
    c = .{};
    fillPolygon(c.sink(), &.{ .{ 0, 0 }, .{ 0, 10 }, .{ 10, 10 }, .{ 10, 0 } });
    try std.testing.expectApproxEqAbs(@as(f32, 100), c.area(), 0.5);
    // An L shape (concave): 10x10 minus a 5x5 corner.
    c = .{};
    fillPolygon(c.sink(), &.{ .{ 0, 0 }, .{ 10, 0 }, .{ 10, 5 }, .{ 5, 5 }, .{ 5, 10 }, .{ 0, 10 }, .{ 0, 0 } });
    try std.testing.expectApproxEqAbs(@as(f32, 75), c.area(), 0.5);
    // Interior triangles: n - 2 of them, plus two per fringe edge.
    try std.testing.expectEqual(@as(usize, 4 + 12), c.n);
}

test "strokes cover their width along their length" {
    var c: Collect = .{};
    // A 4-pixel line 20 long: 80, plus half a pixel of fade at each end.
    strokePolyline(c.sink(), &.{ .{ 0, 0 }, .{ 20, 0 } }, false, 4);
    try std.testing.expectApproxEqAbs(@as(f32, 80), c.area(), 1.5);
    // A closed square outline, 2 wide, centred on a 10x10 square: 12x12
    // minus 8x8.
    c = .{};
    strokePolyline(c.sink(), &.{ .{ 0, 0 }, .{ 10, 0 }, .{ 10, 10 }, .{ 0, 10 } }, true, 2);
    try std.testing.expectApproxEqAbs(@as(f32, 144 - 64), c.area(), 1);
    // Hairlines are a pixel wide but faint.
    c = .{};
    strokePolyline(c.sink(), &.{ .{ 0, 0 }, .{ 10, 0 } }, false, 0.5);
    try std.testing.expectApproxEqAbs(@as(f32, 5), c.area(), 0.6);
}
