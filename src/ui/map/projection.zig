//! Where places show in a `MapView`: on the flat map (Web Mercator, the
//! projection map tiles are made in) or, zoomed out, on a globe seen from
//! above, and part way between the two while zooming from one to the
//! other. The globe and the flat map agree at the centre of the view
//! (in where it is, and in scale), so the one turns into the other
//! smoothly.

const std = @import("std");
const math = std.math;

pub const LatLon = struct {
    /// Degrees north (negative: south).
    lat: f64 = 0,
    /// Degrees east (negative: west).
    lon: f64 = 0,
};

/// What a map view shows: the place at its centre, and how close.
pub const Camera = struct {
    center: LatLon = .{},
    /// At zoom z the flat map is 256 × 2^z pixels across. The globe is
    /// drawn to the same scale at the centre of the view, so it is bigger
    /// at the same zoom away from the equator (as the flat map is).
    zoom: f64 = 2,
};

pub const Projection = enum {
    /// A globe zoomed out (up to `globe_until`), becoming the flat map
    /// zoomed in (from `flat_from`).
    globe,
    /// The flat map at every zoom.
    flat,
};

pub const globe_until = 5.0;
pub const flat_from = 6.0;

/// How far north and south the flat map goes: where it is as tall as it
/// is wide.
pub const max_lat = 85.051128779806604;

const deg = math.pi / 180.0;

/// Where `p` is on the flat map: 0 to 1 from west to east, and from north
/// to south.
pub fn toWorld(p: LatLon) [2]f64 {
    const lat = math.clamp(p.lat, -max_lat, max_lat) * deg;
    return .{ (p.lon + 180) / 360, (1 - @log(@tan(lat) + 1 / @cos(lat)) / math.pi) / 2 };
}

/// The place at `w` on the flat map (east or west of it are copies).
pub fn fromWorld(w: [2]f64) LatLon {
    return .{ .lat = math.atan(math.sinh(math.pi * (1 - 2 * w[1]))) / deg, .lon = wrapLon(w[0] * 360 - 180) };
}

/// `lon` brought to -180 to 180.
pub fn wrapLon(lon: f64) f64 {
    return @mod(lon + 180, 360) - 180;
}

/// How far a camera at `zoom` is from the globe to the flat map: 0 on the
/// globe, 1 on the flat map.
pub fn flatness(zoom: f64, projection: Projection) f64 {
    if (projection == .flat) return 1;
    const t = math.clamp((zoom - globe_until) / (flat_from - globe_until), 0, 1);
    return t * t * (3 - 2 * t);
}

/// A camera's view of the map in a box `size` big: where places show in
/// it (`project`), and what is where (`unproject`).
pub const View = struct {
    size: [2]f64,
    camera: Camera,
    projection: Projection,
    /// 0 on the globe, 1 on the flat map; between, part way.
    flat: f64,
    /// The flat map's width in pixels.
    world: f64,
    /// The centre of the view, on the flat map.
    center: [2]f64,
    /// The globe's radius in pixels; how far the camera is from its
    /// centre (in radii); and the camera's focal length in pixels.
    radius: f64,
    dist: f64,
    focal: f64,
    sin_lat: f64,
    cos_lat: f64,

    pub fn init(camera: Camera, size: [2]f64, projection: Projection) View {
        const lat = math.clamp(camera.center.lat, -max_lat, max_lat);
        const world = 256 * math.exp2(camera.zoom);
        // Looking down from as high as a 37° view up and down sees the
        // height of the view at the centre (where the scale is the flat
        // map's).
        const focal = 1.5 * @max(size[1], 1);
        const radius = world / math.tau / @cos(lat * deg);
        return .{
            .size = size,
            .camera = camera,
            .projection = projection,
            .flat = flatness(camera.zoom, projection),
            .world = world,
            .center = toWorld(camera.center),
            .radius = radius,
            .dist = 1 + focal / radius,
            .focal = focal,
            .sin_lat = @sin(lat * deg),
            .cos_lat = @cos(lat * deg),
        };
    }

    /// Where something shows, and whether it is on the side of the globe
    /// facing the camera (if not, `pos` is on the globe's edge, in its
    /// direction).
    pub const Projected = struct { pos: [2]f64, visible: bool };

    /// Where the point `w` on the flat map shows (`w[0]` may be beyond 0
    /// to 1: a copy of the world to the east or west, which on the flat
    /// map shows there).
    pub fn project(v: *const View, w: [2]f64) Projected {
        const flat_pos: [2]f64 = .{
            v.size[0] / 2 + (w[0] - v.center[0]) * v.world,
            v.size[1] / 2 + (w[1] - v.center[1]) * v.world,
        };
        if (v.flat >= 1) return .{ .pos = flat_pos, .visible = true };
        const g = v.globe(w);
        if (v.flat <= 0) return g;
        return .{ .pos = .{ g.pos[0] + (flat_pos[0] - g.pos[0]) * v.flat, g.pos[1] + (flat_pos[1] - g.pos[1]) * v.flat }, .visible = true };
    }

    /// Where `p` shows (the copy of it nearest the centre, on the flat
    /// map).
    pub fn projectLatLon(v: *const View, p: LatLon) Projected {
        var w = toWorld(p);
        w[0] -= @round(w[0] - v.center[0]);
        return v.project(w);
    }

    /// Where `w` is on the globe, in the camera's view (with the globe's
    /// radius 1, its centre at 0, and the camera on the z axis looking
    /// down it).
    fn onGlobe(v: *const View, w: [2]f64) [3]f64 {
        const lat = math.atan(math.sinh(math.pi * (1 - 2 * w[1])));
        const dlon = (w[0] - v.center[0]) * math.tau;
        const x = @cos(lat) * @sin(dlon);
        const y = @sin(lat);
        const z = @cos(lat) * @cos(dlon);
        return .{ x, y * v.cos_lat - z * v.sin_lat, y * v.sin_lat + z * v.cos_lat };
    }

    fn globe(v: *const View, w: [2]f64) Projected {
        const q = v.onGlobe(w);
        const cx = v.size[0] / 2;
        const cy = v.size[1] / 2;
        const horizon = 1 / v.dist;
        if (q[2] > horizon) {
            const k = v.focal / (v.dist - q[2]);
            return .{ .pos = .{ cx + q[0] * k, cy - q[1] * k }, .visible = true };
        }
        // Behind the globe: on its edge, in the same direction.
        const len = @sqrt(q[0] * q[0] + q[1] * q[1]);
        const d: [2]f64 = if (len > 1e-12) .{ q[0] / len, q[1] / len } else .{ 0, 1 };
        const r = v.discRadius();
        return .{ .pos = .{ cx + d[0] * r, cy - d[1] * r }, .visible = false };
    }

    /// The radius of the globe's outline, around the centre of the view.
    pub fn discRadius(v: *const View) f64 {
        return v.focal / @sqrt(v.dist * v.dist - 1);
    }

    /// What is at `s` in the view: null off the globe, or beyond the flat
    /// map's top or bottom.
    pub fn unproject(v: *const View, s: [2]f64) ?LatLon {
        if (v.flat >= 1) {
            const w: [2]f64 = .{ v.center[0] + (s[0] - v.size[0] / 2) / v.world, v.center[1] + (s[1] - v.size[1] / 2) / v.world };
            if (w[1] < 0 or w[1] > 1) return null;
            return fromWorld(w);
        }
        if (v.flat <= 0) return v.unprojectGlobe(s);
        // Part way: found by Newton's method, from the flat map's answer.
        var w: [2]f64 = .{ v.center[0] + (s[0] - v.size[0] / 2) / v.world, v.center[1] + (s[1] - v.size[1] / 2) / v.world };
        const h = 1e-7;
        for (0..8) |_| {
            const p = v.project(w).pos;
            const e: [2]f64 = .{ p[0] - s[0], p[1] - s[1] };
            if (@abs(e[0]) + @abs(e[1]) < 1e-3) break;
            const px = v.project(.{ w[0] + h, w[1] }).pos;
            const py = v.project(.{ w[0], w[1] + h }).pos;
            const j = [2][2]f64{ .{ (px[0] - p[0]) / h, (py[0] - p[0]) / h }, .{ (px[1] - p[1]) / h, (py[1] - p[1]) / h } };
            const step = solve2(j, e) orelse return null;
            w = .{ w[0] - step[0], w[1] - step[1] };
        }
        if (w[1] < 0 or w[1] > 1) return null;
        return fromWorld(w);
    }

    fn unprojectGlobe(v: *const View, s: [2]f64) ?LatLon {
        // Where the ray from the camera through `s` first meets the globe.
        const d: [3]f64 = .{ (s[0] - v.size[0] / 2) / v.focal, -(s[1] - v.size[1] / 2) / v.focal, -1 };
        const a = d[0] * d[0] + d[1] * d[1] + d[2] * d[2];
        const b = -2 * v.dist;
        const c = v.dist * v.dist - 1;
        const disc = b * b - 4 * a * c;
        if (disc < 0) return null;
        const t = (-b - @sqrt(disc)) / (2 * a);
        const q: [3]f64 = .{ t * d[0], t * d[1], v.dist + t * d[2] };
        const y = q[1] * v.cos_lat + q[2] * v.sin_lat;
        const z = -q[1] * v.sin_lat + q[2] * v.cos_lat;
        return .{
            .lat = math.asin(math.clamp(y, -1, 1)) / deg,
            .lon = wrapLon(v.camera.center.lon + math.atan2(q[0], z) / deg),
        };
    }
};

/// Solves `j · x = e` for x, if it can be.
fn solve2(j: [2][2]f64, e: [2]f64) ?[2]f64 {
    const det = j[0][0] * j[1][1] - j[0][1] * j[1][0];
    if (@abs(det) < 1e-12) return null;
    return .{ (e[0] * j[1][1] - e[1] * j[0][1]) / det, (e[1] * j[0][0] - e[0] * j[1][0]) / det };
}

/// `camera` with its centre at `w` on the flat map. On the globe, the zoom
/// changes with the latitude so that the globe stays the same size (its
/// scale is the flat map's, which grows away from the equator).
fn centered(camera: Camera, flat: f64, w: [2]f64) Camera {
    const lat_limit = toWorld(.{ .lat = max_lat })[1];
    const place = fromWorld(.{ w[0], math.clamp(w[1], lat_limit, 1 - lat_limit) });
    const before = @cos(math.clamp(camera.center.lat, -max_lat, max_lat) * deg);
    const after = @cos(place.lat * deg);
    return .{ .center = place, .zoom = camera.zoom + (1 - flat) * math.log2(before / after) };
}

/// The camera, moved from `camera` (in a view `size` big), that shows
/// `place` at `at` in the view: what dragging the map does, the place
/// grabbed staying under the pointer. Off the globe's edge, as near as it
/// can be.
pub fn moveTo(camera: Camera, size: [2]f64, projection: Projection, place: LatLon, at_in: [2]f64) Camera {
    const v = View.init(camera, size, projection);
    var at = at_in;
    if (v.flat <= 0) {
        // Within the globe's outline.
        const r = v.discRadius() * 0.98;
        const dx = at[0] - size[0] / 2;
        const dy = at[1] - size[1] / 2;
        const len = @sqrt(dx * dx + dy * dy);
        if (len > r) at = .{ size[0] / 2 + dx * r / len, size[1] / 2 + dy * r / len };
    }
    var target = toWorld(place);
    target[0] -= @round(target[0] - v.center[0]);
    // On the flat map: exactly.
    var w: [2]f64 = .{ target[0] - (at[0] - size[0] / 2) / v.world, target[1] - (at[1] - size[1] / 2) / v.world };
    if (v.flat >= 1) return centered(camera, 1, w);
    // On the globe: by Newton's method, from there.
    var best = centered(camera, v.flat, w);
    var best_err = math.inf(f64);
    const h = 1e-7;
    for (0..12) |_| {
        const cam = centered(camera, v.flat, w);
        const p = View.init(cam, size, projection).project(target).pos;
        const e: [2]f64 = .{ p[0] - at[0], p[1] - at[1] };
        const err = @abs(e[0]) + @abs(e[1]);
        if (err < best_err) {
            best = cam;
            best_err = err;
        }
        if (err < 1e-3) break;
        const px = View.init(centered(camera, v.flat, .{ w[0] + h, w[1] }), size, projection).project(target).pos;
        const py = View.init(centered(camera, v.flat, .{ w[0], w[1] + h }), size, projection).project(target).pos;
        const j = [2][2]f64{ .{ (px[0] - p[0]) / h, (py[0] - p[0]) / h }, .{ (px[1] - p[1]) / h, (py[1] - p[1]) / h } };
        var step = solve2(j, e) orelse break;
        // No more than a tenth of the world at a time.
        const len = @abs(step[0]) + @abs(step[1]);
        if (len > 0.1) step = .{ step[0] * 0.1 / len, step[1] * 0.1 / len };
        w = .{ w[0] - step[0], w[1] - step[1] };
    }
    return best;
}

/// `camera` zoomed by `by` (in zoom levels, clamped to `min` to `max`)
/// about `at` in the view: the place there stays there (if there is one;
/// otherwise about the centre).
pub fn zoomAbout(camera: Camera, size: [2]f64, projection: Projection, at: [2]f64, by: f64, min: f64, max: f64) Camera {
    const zoom = math.clamp(camera.zoom + by, min, max);
    const place = View.init(camera, size, projection).unproject(at) orelse return .{ .center = camera.center, .zoom = zoom };
    return moveTo(.{ .center = camera.center, .zoom = zoom }, size, projection, place, at);
}

const testing = std.testing;

test "the flat map: places and back" {
    const w = toWorld(.{ .lat = 0, .lon = 0 });
    try testing.expectApproxEqAbs(0.5, w[0], 1e-12);
    try testing.expectApproxEqAbs(0.5, w[1], 1e-12);
    try testing.expectApproxEqAbs(0.0, toWorld(.{ .lat = max_lat })[1], 1e-9);
    const p = fromWorld(toWorld(.{ .lat = 51.5, .lon = -0.12 }));
    try testing.expectApproxEqAbs(51.5, p.lat, 1e-9);
    try testing.expectApproxEqAbs(-0.12, p.lon, 1e-9);
}

test "what shows where is what is there, on the globe, the flat map and between" {
    const size: [2]f64 = .{ 800, 480 };
    for ([_]f64{ 1.5, 3, 5.5, 8 }) |zoom| {
        const v = View.init(.{ .center = .{ .lat = 40, .lon = -100 }, .zoom = zoom }, size, .globe);
        // The centre is at the centre.
        const c = v.projectLatLon(v.camera.center);
        try testing.expect(c.visible);
        try testing.expectApproxEqAbs(400, c.pos[0], 1e-6);
        try testing.expectApproxEqAbs(240, c.pos[1], 1e-6);
        // And what is shown somewhere is what shows there.
        for ([_][2]f64{ .{ 380, 250 }, .{ 450, 200 }, .{ 390, 300 } }) |s| {
            const p = v.unproject(s) orelse return error.TestUnexpectedResult;
            const back = v.projectLatLon(p);
            try testing.expect(back.visible);
            try testing.expectApproxEqAbs(s[0], back.pos[0], 1e-2);
            try testing.expectApproxEqAbs(s[1], back.pos[1], 1e-2);
        }
    }
    // Zoomed out, the globe: beyond its edge is nothing, and its far side
    // is hidden.
    const v = View.init(.{ .zoom = 1 }, size, .globe);
    try testing.expect(v.unproject(.{ 5, 5 }) == null);
    try testing.expect(!v.projectLatLon(.{ .lon = 180 }).visible);
    try testing.expect(v.projectLatLon(.{ .lon = 60 }).visible);
}

test "dragging keeps the place grabbed under the pointer" {
    const size: [2]f64 = .{ 800, 480 };
    for ([_]Projection{ .globe, .flat }) |proj| for ([_]f64{ 2, 5.5, 9 }) |zoom| {
        var cam: Camera = .{ .center = .{ .lat = 20, .lon = 10 }, .zoom = zoom };
        const grab: [2]f64 = .{ 420, 230 };
        const place = View.init(cam, size, proj).unproject(grab).?;
        var at = grab;
        for (0..10) |_| {
            at = .{ at[0] + 9, at[1] + 4 };
            cam = moveTo(cam, size, proj, place, at);
            const p = View.init(cam, size, proj).projectLatLon(place);
            try testing.expectApproxEqAbs(at[0], p.pos[0], 0.05);
            try testing.expectApproxEqAbs(at[1], p.pos[1], 0.05);
        }
    };
}

test "zooming about a point keeps the place there" {
    const size: [2]f64 = .{ 800, 480 };
    for ([_]f64{ 2, 4.8, 5.6, 7 }) |zoom| {
        const cam: Camera = .{ .center = .{ .lat = -30, .lon = 150 }, .zoom = zoom };
        const at: [2]f64 = .{ 500, 300 };
        const place = View.init(cam, size, .globe).unproject(at).?;
        const zoomed = zoomAbout(cam, size, .globe, at, 0.5, 0, 20);
        try testing.expectApproxEqAbs(zoom + 0.5, zoomed.zoom, 0.2);
        const p = View.init(zoomed, size, .globe).projectLatLon(place);
        try testing.expectApproxEqAbs(at[0], p.pos[0], 0.05);
        try testing.expectApproxEqAbs(at[1], p.pos[1], 0.05);
    }
}
