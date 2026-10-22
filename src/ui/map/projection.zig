//! Where places show in a `MapView`: on the flat map (Web Mercator, the
//! projection map tiles are made in) or, zoomed out, on a globe seen from
//! above, and part way between the two while zooming from one to the
//! other. The globe's size is the zoom's alone (dragging it about does
//! not change it); as it becomes the flat map, it takes the flat map's
//! scale at the centre of the view, so the one turns into the other
//! smoothly.

const std = @import("std");
const math = std.math;

/// A place on the Earth: its latitude and longitude, in degrees.
pub const MapCoordinate = struct {
    /// Degrees north (negative: south).
    lat: f64 = 0,
    /// Degrees east (negative: west).
    lon: f64 = 0,
};

/// What a map view shows: the place at its centre, and how close.
pub const MapCamera = struct {
    /// The place at the middle of the view.
    center: MapCoordinate = .{},
    /// At zoom z the flat map is 256 × 2^z pixels across, and the globe
    /// as far round its equator.
    zoom: f64 = 2,
};

/// How a map view shows the world.
pub const MapProjection = enum {
    /// A globe zoomed out (up to `globe_until`, or further in if the
    /// globe does not cover the view by then), becoming the flat map over
    /// the next zoom level.
    globe,
    /// The flat map at every zoom.
    flat,
};

/// The zoom the globe starts becoming the flat map at, at the earliest.
pub const globe_until = 5.0;

/// The camera's focal length in a view `size` big, in pixels: looking down
/// from as high as a 37° view up and down sees the view's height at the
/// centre.
fn focalOf(size: [2]f64) f64 {
    return 1.5 * @max(size[1], 1);
}

/// How far north and south the flat map goes: where it is as tall as it
/// is wide.
pub const max_lat = 85.051128779806604;

const deg = math.pi / 180.0;

/// Where `p` is on the flat map: 0 to 1 from west to east, and from north
/// to south.
pub fn toWorld(p: MapCoordinate) [2]f64 {
    const lat = math.clamp(p.lat, -max_lat, max_lat) * deg;
    return .{ (p.lon + 180) / 360, (1 - @log(@tan(lat) + 1 / @cos(lat)) / math.pi) / 2 };
}

/// The place at `w` on the flat map (east or west of it are copies).
pub fn fromWorld(w: [2]f64) MapCoordinate {
    return .{ .lat = math.atan(math.sinh(math.pi * (1 - 2 * w[1]))) / deg, .lon = wrapLon(w[0] * 360 - 180) };
}

/// `lon` brought to -180 to 180.
pub fn wrapLon(lon: f64) f64 {
    return @mod(lon + 180, 360) - 180;
}

/// The zoom the globe starts becoming the flat map at in a view `size`
/// big: `globe_until`, or once the globe covers the view (its corners
/// too), if that is further in. Before then, what is turning onto the
/// globe's far side would show (in a wide view, say).
pub fn globeUntil(size: [2]f64) f64 {
    const focal = focalOf(size);
    const corner = @sqrt(size[0] * size[0] + size[1] * size[1]) / 2;
    // The outline's radius is focal / √(d² − 1), with the camera d radii
    // from the globe's centre (d = 1 + focal / radius): at least
    // `corner` (and a tenth more) for a radius at least this.
    const radius = 1.1 * focal / (@sqrt(1 + focal * focal / @max(corner * corner, 1)) - 1);
    return @max(globe_until, math.log2(radius * math.tau / 256));
}

/// Where the sun is overhead at `unix_seconds` (seconds since 1970 UTC):
/// on the tropics between them by the season, and moving west through
/// the day. Within a fraction of a degree (the usual low-precision
/// formulas: the sun's mean orbit, its centre's equation and sidereal
/// time).
pub fn subsolarPoint(unix_seconds: f64) MapCoordinate {
    // Days since noon on the 1st of January 2000 (J2000).
    const d = unix_seconds / 86400 - 10957.5;
    const g = (357.529 + 0.98560028 * d) * deg;
    const q = 280.459 + 0.98564736 * d;
    const l = (q + 1.915 * @sin(g) + 0.020 * @sin(2 * g)) * deg;
    const e = (23.439 - 0.00000036 * d) * deg;
    const ra = math.atan2(@cos(e) * @sin(l), @cos(l)) / deg;
    const dec = math.asin(@sin(e) * @sin(l)) / deg;
    const gmst = 280.46061837 + 360.98564736629 * d;
    return .{ .lat = dec, .lon = wrapLon(ra - gmst) };
}

/// Which way `p` is from the centre of the earth (a unit vector: x
/// towards 90°E, y towards the north pole, z towards 0°, 0°).
pub fn direction(p: MapCoordinate) [3]f64 {
    const lat = p.lat * deg;
    const lon = p.lon * deg;
    return .{ @cos(lat) * @sin(lon), @sin(lat), @cos(lat) * @cos(lon) };
}

/// How far a camera at `zoom` (in a view `size` big) is from the globe to
/// the flat map: 0 on the globe, 1 on the flat map.
pub fn flatness(zoom: f64, size: [2]f64, projection: MapProjection) f64 {
    if (projection == .flat) return 1;
    const t = math.clamp(zoom - globeUntil(size), 0, 1);
    return t * t * (3 - 2 * t);
}

/// A camera's view of the map in a box `size` big: where places show in
/// it (`project`), and what is where (`unproject`).
pub const View = struct {
    size: [2]f64,
    camera: MapCamera,
    projection: MapProjection,
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

    pub fn init(camera: MapCamera, size: [2]f64, projection: MapProjection) View {
        const lat = math.clamp(camera.center.lat, -max_lat, max_lat);
        const world = 256 * math.exp2(camera.zoom);
        const focal = focalOf(size);
        // The equator as long as the flat map is wide; growing as it
        // becomes the flat map, to that map's scale at the centre (which
        // grows away from the equator).
        const flat = flatness(camera.zoom, size, projection);
        const radius = world / math.tau / math.pow(f64, @cos(lat * deg), flat);
        return .{
            .size = size,
            .camera = camera,
            .projection = projection,
            .flat = flat,
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
    /// facing the camera (if not, on the globe, `pos` is on its edge, in
    /// its direction; part way to the flat map, it is to be left out).
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
        // Part way: from where it is on the globe to where it is on the
        // flat map. What is on the globe's far side still is not shown (it
        // would sweep across the view, from the globe's edge).
        return .{ .pos = .{ g.pos[0] + (flat_pos[0] - g.pos[0]) * v.flat, g.pos[1] + (flat_pos[1] - g.pos[1]) * v.flat }, .visible = g.visible };
    }

    /// Where `p` shows (the copy of it nearest the centre, on the flat
    /// map).
    pub fn projectCoordinate(v: *const View, p: MapCoordinate) Projected {
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

    /// The place at `q` on the globe in the camera's view (a unit vector:
    /// see `onGlobe`).
    pub fn placeAt(v: *const View, q: [3]f64) MapCoordinate {
        const y = q[1] * v.cos_lat + q[2] * v.sin_lat;
        const z = -q[1] * v.sin_lat + q[2] * v.cos_lat;
        return .{
            .lat = math.asin(math.clamp(y, -1, 1)) / deg,
            .lon = wrapLon(v.camera.center.lon + math.atan2(q[0], z) / deg),
        };
    }

    /// How far round the globe from the camera its edge is (radians).
    pub fn horizonAngle(v: *const View) f64 {
        return math.acos(1 / v.dist);
    }

    /// The radius of the globe's outline, around the centre of the view.
    pub fn discRadius(v: *const View) f64 {
        return v.focal / @sqrt(v.dist * v.dist - 1);
    }

    /// What is at `s` in the view: null off the globe, or beyond the flat
    /// map's top or bottom.
    pub fn unproject(v: *const View, s: [2]f64) ?MapCoordinate {
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

    fn unprojectGlobe(v: *const View, s: [2]f64) ?MapCoordinate {
        // Where the ray from the camera through `s` first meets the globe.
        const d: [3]f64 = .{ (s[0] - v.size[0] / 2) / v.focal, -(s[1] - v.size[1] / 2) / v.focal, -1 };
        const a = d[0] * d[0] + d[1] * d[1] + d[2] * d[2];
        const b = -2 * v.dist;
        const c = v.dist * v.dist - 1;
        const disc = b * b - 4 * a * c;
        if (disc < 0) return null;
        const t = (-b - @sqrt(disc)) / (2 * a);
        return v.placeAt(.{ t * d[0], t * d[1], v.dist + t * d[2] });
    }
};

/// Solves `j · x = e` for x, if it can be.
fn solve2(j: [2][2]f64, e: [2]f64) ?[2]f64 {
    const det = j[0][0] * j[1][1] - j[0][1] * j[1][0];
    if (@abs(det) < 1e-12) return null;
    return .{ (e[0] * j[1][1] - e[1] * j[0][1]) / det, (e[1] * j[0][0] - e[0] * j[1][0]) / det };
}

/// `camera` with its centre at `w` on the flat map (and the same zoom).
fn centered(camera: MapCamera, w: [2]f64) MapCamera {
    const lat_limit = toWorld(.{ .lat = max_lat })[1];
    return .{ .center = fromWorld(.{ w[0], math.clamp(w[1], lat_limit, 1 - lat_limit) }), .zoom = camera.zoom };
}

/// The camera, moved from `camera` (in a view `size` big), that shows
/// `place` at `at` in the view: what dragging the map does, the place
/// grabbed staying under the pointer. Off the globe's edge, as near as it
/// can be.
pub fn moveTo(camera: MapCamera, size: [2]f64, projection: MapProjection, place: MapCoordinate, at_in: [2]f64) MapCamera {
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
    if (v.flat >= 1) return centered(camera, w);
    // On the globe: by Newton's method, from there.
    var best = centered(camera, w);
    var best_err = math.inf(f64);
    const h = 1e-7;
    for (0..12) |_| {
        const cam = centered(camera, w);
        const p = View.init(cam, size, projection).project(target).pos;
        const e: [2]f64 = .{ p[0] - at[0], p[1] - at[1] };
        const err = @abs(e[0]) + @abs(e[1]);
        if (err < best_err) {
            best = cam;
            best_err = err;
        }
        if (err < 1e-3) break;
        const px = View.init(centered(camera, .{ w[0] + h, w[1] }), size, projection).project(target).pos;
        const py = View.init(centered(camera, .{ w[0], w[1] + h }), size, projection).project(target).pos;
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
pub fn zoomAbout(camera: MapCamera, size: [2]f64, projection: MapProjection, at: [2]f64, by: f64, min: f64, max: f64) MapCamera {
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
        const c = v.projectCoordinate(v.camera.center);
        try testing.expect(c.visible);
        try testing.expectApproxEqAbs(400, c.pos[0], 1e-6);
        try testing.expectApproxEqAbs(240, c.pos[1], 1e-6);
        // And what is shown somewhere is what shows there.
        for ([_][2]f64{ .{ 380, 250 }, .{ 450, 200 }, .{ 390, 300 } }) |s| {
            const p = v.unproject(s) orelse return error.TestUnexpectedResult;
            const back = v.projectCoordinate(p);
            try testing.expect(back.visible);
            try testing.expectApproxEqAbs(s[0], back.pos[0], 1e-2);
            try testing.expectApproxEqAbs(s[1], back.pos[1], 1e-2);
        }
    }
    // Zoomed out, the globe: beyond its edge is nothing, and its far side
    // is hidden.
    const v = View.init(.{ .zoom = 1 }, size, .globe);
    try testing.expect(v.unproject(.{ 5, 5 }) == null);
    try testing.expect(!v.projectCoordinate(.{ .lon = 180 }).visible);
    try testing.expect(v.projectCoordinate(.{ .lon = 60 }).visible);
}

test "dragging keeps the place grabbed under the pointer" {
    const size: [2]f64 = .{ 800, 480 };
    for ([_]MapProjection{ .globe, .flat }) |proj| for ([_]f64{ 2, 5.5, 9 }) |zoom| {
        var cam: MapCamera = .{ .center = .{ .lat = 20, .lon = 10 }, .zoom = zoom };
        const grab: [2]f64 = .{ 420, 230 };
        const place = View.init(cam, size, proj).unproject(grab).?;
        var at = grab;
        for (0..10) |_| {
            at = .{ at[0] + 9, at[1] + 4 };
            cam = moveTo(cam, size, proj, place, at);
            // The zoom stays as it was.
            try testing.expectEqual(zoom, cam.zoom);
            const p = View.init(cam, size, proj).projectCoordinate(place);
            try testing.expectApproxEqAbs(at[0], p.pos[0], 0.05);
            try testing.expectApproxEqAbs(at[1], p.pos[1], 0.05);
        }
    };
}

test "zooming about a point keeps the place there" {
    const size: [2]f64 = .{ 800, 480 };
    for ([_]f64{ 2, 4.8, 5.6, 7 }) |zoom| {
        const cam: MapCamera = .{ .center = .{ .lat = -30, .lon = 150 }, .zoom = zoom };
        const at: [2]f64 = .{ 500, 300 };
        const place = View.init(cam, size, .globe).unproject(at).?;
        const zoomed = zoomAbout(cam, size, .globe, at, 0.5, 0, 20);
        try testing.expectEqual(zoom + 0.5, zoomed.zoom);
        const p = View.init(zoomed, size, .globe).projectCoordinate(place);
        try testing.expectApproxEqAbs(at[0], p.pos[0], 0.05);
        try testing.expectApproxEqAbs(at[1], p.pos[1], 0.05);
    }
}

test "the globe becomes the flat map only once it covers the view, whatever its shape" {
    for ([_][2]f64{ .{ 800, 480 }, .{ 1740, 430 }, .{ 300, 900 }, .{ 2560, 200 } }) |size| {
        const z = globeUntil(size);
        try testing.expect(z >= globe_until);
        const v = View.init(.{ .center = .{ .lat = 30 }, .zoom = z }, size, .globe);
        try testing.expectEqual(@as(f64, 0), v.flat);
        try testing.expect(v.discRadius() >= @sqrt(size[0] * size[0] + size[1] * size[1]) / 2);
        // Past it, part way, nothing on the far side shows in the view.
        const part = View.init(.{ .center = .{ .lat = 30 }, .zoom = z + 0.5 }, size, .globe);
        try testing.expect(part.flat > 0 and part.flat < 1);
        for (0..9) |j| for (0..9) |i| {
            const at: [2]f64 = .{ size[0] * @as(f64, @floatFromInt(i)) / 8, size[1] * @as(f64, @floatFromInt(j)) / 8 };
            const p = part.unproject(at) orelse return error.TestUnexpectedResult;
            try testing.expect(part.projectCoordinate(p).visible);
        };
    }
    // A wide view at zoom 5.2 is still a globe.
    try testing.expectEqual(@as(f64, 0), flatness(5.2, .{ 1740, 430 }, .globe));
    try testing.expect(flatness(5.5, .{ 800, 480 }, .globe) > 0);
}

test "the sun is overhead where it should be" {
    // The June solstice of 2024 (20 June, 20:51 UTC): over the Tropic of
    // Cancer, and at 20:51 UTC, about 133°W (where it is noon).
    const june = subsolarPoint(1718916660);
    try testing.expectApproxEqAbs(23.44, june.lat, 0.05);
    try testing.expectApproxEqAbs(-133.0, june.lon, 1.5);
    // The March equinox of 2024 (20 March, 03:06 UTC): over the equator.
    const march = subsolarPoint(1710903960);
    try testing.expectApproxEqAbs(0, march.lat, 0.05);
    try testing.expectApproxEqAbs(@as(f64, 1), direction(.{ .lat = 90 })[1], 1e-12);
}
