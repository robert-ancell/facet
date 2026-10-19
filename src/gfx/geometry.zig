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

/// Fills what is inside an odd number of `rings` (each closed, of any
/// number of points): a ring inside another is a hole, one inside that is
/// filled again, and so on. Bands between the points' heights are cut into
/// trapezoids; the edges fade out over half a pixel beyond them.
pub fn fillRings(gpa: std.mem.Allocator, out: Sink, rings: []const []const Point) error{OutOfMemory}!void {
    var total: usize = 0;
    for (rings) |r| total += r.len;
    if (total < 3) return;
    const Edge = struct { x0: f32, y0: f32, y1: f32, dxdy: f32 };
    const edges = try gpa.alloc(Edge, total);
    defer gpa.free(edges);
    const ys = try gpa.alloc(f32, total);
    defer gpa.free(ys);
    var ne: usize = 0;
    var ny: usize = 0;
    for (rings) |r| {
        if (r.len < 3) continue;
        for (r, 0..) |a, i| {
            const b = r[(i + 1) % r.len];
            ys[ny] = a[1];
            ny += 1;
            if (a[1] == b[1]) continue;
            const top, const bot = if (a[1] < b[1]) .{ a, b } else .{ b, a };
            edges[ne] = .{ .x0 = top[0], .y0 = top[1], .y1 = bot[1], .dxdy = (bot[0] - top[0]) / (bot[1] - top[1]) };
            ne += 1;
        }
    }
    std.mem.sortUnstable(f32, ys[0..ny], {}, std.sort.asc(f32));
    std.mem.sortUnstable(Edge, edges[0..ne], {}, struct {
        fn lt(_: void, a: Edge, b: Edge) bool {
            return a.y0 < b.y0;
        }
    }.lt);

    // Down the bands, with the edges across each: every edge that starts
    // at or above a band's top and ends below it spans the whole band
    // (the bands are cut at every point's height).
    const Cross = struct { mid: f32, top: f32, bot: f32 };
    const active = try gpa.alloc(u32, ne);
    defer gpa.free(active);
    const crossings = try gpa.alloc(Cross, ne);
    defer gpa.free(crossings);
    var na: usize = 0;
    var next: usize = 0;
    var k: usize = 0;
    while (k + 1 < ny) : (k += 1) {
        const ya = ys[k];
        const yb = ys[k + 1];
        if (yb <= ya) continue;
        var kept: usize = 0;
        for (active[0..na]) |e| if (edges[e].y1 > ya) {
            active[kept] = e;
            kept += 1;
        };
        na = kept;
        while (next < ne and edges[next].y0 <= ya) : (next += 1) if (edges[next].y1 > ya) {
            active[na] = @intCast(next);
            na += 1;
        };
        if (na < 2) continue;
        for (active[0..na], crossings[0..na]) |e, *c| {
            const edge = edges[e];
            const top = edge.x0 + (ya - edge.y0) * edge.dxdy;
            const bot = edge.x0 + (yb - edge.y0) * edge.dxdy;
            c.* = .{ .mid = (top + bot) / 2, .top = top, .bot = bot };
        }
        std.mem.sortUnstable(Cross, crossings[0..na], {}, struct {
            fn lt(_: void, a: Cross, b: Cross) bool {
                return a.mid < b.mid;
            }
        }.lt);
        var i: usize = 0;
        while (i + 1 < na) : (i += 2) {
            const l = crossings[i];
            const r = crossings[i + 1];
            out.quad(
                .{ .x = l.top, .y = ya, .alpha = 1 },
                .{ .x = r.top, .y = ya, .alpha = 1 },
                .{ .x = r.bot, .y = yb, .alpha = 1 },
                .{ .x = l.bot, .y = yb, .alpha = 1 },
            );
        }
    }

    // The fringe, outside each edge: a ring inside an odd number of the
    // others is a hole, so outside is the other way round its edges.
    for (rings, 0..) |r, ri| {
        if (r.len < 3) continue;
        const area = signedArea2(r);
        if (@abs(area) < 1e-6) continue;
        var depth: usize = 0;
        for (rings, 0..) |other, oi| {
            if (oi != ri and other.len >= 3 and insideRing(other, r[0])) depth += 1;
        }
        const flip: f32 = if ((area > 0) == (depth % 2 == 0)) -1 else 1;
        for (r, 0..) |a, i| {
            const b = r[(i + 1) % r.len];
            const n = scale(leftNormal(a, b) orelse continue, flip * 0.5);
            out.quad(
                .{ .x = a[0], .y = a[1], .alpha = 0.5 },
                .{ .x = b[0], .y = b[1], .alpha = 0.5 },
                .{ .x = b[0] + n[0], .y = b[1] + n[1], .alpha = 0 },
                .{ .x = a[0] + n[0], .y = a[1] + n[1], .alpha = 0 },
            );
        }
    }
}

/// Whether `p` is inside `ring` (crossing its edges an odd number of times
/// going right).
fn insideRing(ring: []const Point, p: Point) bool {
    var inside = false;
    for (ring, 0..) |a, i| {
        const b = ring[(i + 1) % ring.len];
        if ((a[1] > p[1]) != (b[1] > p[1]) and p[0] < a[0] + (p[1] - a[1]) / (b[1] - a[1]) * (b[0] - a[0])) inside = !inside;
    }
    return inside;
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

test "rings fill what is inside an odd number of them" {
    var c: Collect = .{};
    // A 10x10 square with a 4x4 hole, wound either way: 100 - 16, with
    // an eighth of a pixel of fade along each edge.
    const outer = [_]Point{ .{ 0, 0 }, .{ 10, 0 }, .{ 10, 10 }, .{ 0, 10 } };
    const hole = [_]Point{ .{ 3, 3 }, .{ 7, 3 }, .{ 7, 7 }, .{ 3, 7 } };
    try fillRings(std.testing.allocator, c.sink(), &.{ &outer, &hole });
    try std.testing.expectApproxEqAbs(@as(f32, 84 + 0.125 * (40 + 16)), c.area(), 0.5);
    c = .{};
    const hole_back = [_]Point{ .{ 3, 3 }, .{ 3, 7 }, .{ 7, 7 }, .{ 7, 3 } };
    try fillRings(std.testing.allocator, c.sink(), &.{ &outer, &hole_back });
    try std.testing.expectApproxEqAbs(@as(f32, 84 + 0.125 * (40 + 16)), c.area(), 0.5);
    // An island in the hole is filled again.
    c = .{};
    const island = [_]Point{ .{ 4, 4 }, .{ 6, 4 }, .{ 6, 6 }, .{ 4, 6 } };
    try fillRings(std.testing.allocator, c.sink(), &.{ &outer, &hole, &island });
    try std.testing.expectApproxEqAbs(@as(f32, 88 + 0.125 * (40 + 16 + 8)), c.area(), 0.5);
    // Concave, and with more points than a polygon may have.
    c = .{};
    try fillRings(std.testing.allocator, c.sink(), &.{&.{ .{ 0, 0 }, .{ 10, 0 }, .{ 10, 5 }, .{ 5, 5 }, .{ 5, 10 }, .{ 0, 10 } }});
    try std.testing.expectApproxEqAbs(@as(f32, 75 + 0.125 * 40), c.area(), 0.5);
    var circle: [2000]Point = undefined;
    for (&circle, 0..) |*p, i| {
        const a = @as(f32, @floatFromInt(i)) / circle.len * std.math.tau;
        p.* = .{ 50 + 40 * @cos(a), 50 + 40 * @sin(a) };
    }
    var big: Area = .{};
    try fillRings(std.testing.allocator, big.sink(), &.{&circle});
    try std.testing.expectApproxEqAbs(std.math.pi * 40 * 40 + 0.125 * std.math.tau * 40, big.total, 2);
}

/// Sums the coverage-weighted area of however many triangles.
const Area = struct {
    total: f32 = 0,

    fn sink(a: *Area) Sink {
        return .{ .ptr = a, .triangle = add3 };
    }
    fn add3(ptr: *anyopaque, a: Vertex, b: Vertex, cc: Vertex) void {
        const self: *Area = @ptrCast(@alignCast(ptr));
        const a2 = @abs(cross(.{ b.x - a.x, b.y - a.y }, .{ cc.x - a.x, cc.y - a.y }));
        self.total += a2 / 2 * (a.alpha + b.alpha + cc.alpha) / 3;
    }
};

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
