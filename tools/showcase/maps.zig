//! Maps: a slippy map (`MapView`) of tiles made here: lines of latitude
//! and longitude, labelled, with the tropics and the polar circles. As
//! vector tiles, drawn in a style chosen here, or as images drawn from
//! them in that style (a little at a time, so they come in as a tile
//! server's would). Zoomed out, it is a globe.

const std = @import("std");
const facet = @import("facet");
const common = @import("common.zig");

const gpa = std.heap.smp_allocator;
const Color = facet.Color;
const VectorTile = facet.VectorTile;
const Point = VectorTile.Point;

pub const Kind = enum { vector, images };
pub const Look = enum { theme, atlas, night, blueprint };

const world_view: facet.MapCamera = .{ .center = .{ .lat = 25, .lon = 10 }, .zoom = 2 };

pub const State = struct {
    camera: facet.MapCamera = world_view,
    kind: Kind = .vector,
    look: Look = .theme,
    projection: facet.MapProjection = .globe,
    vector: VectorTiles = .{},
    images: ImageTiles = .{},

    pub fn deinit(s: *State) void {
        s.vector.deinit();
        s.images.deinit();
    }

    fn setKind(s: *State, v: Kind) void {
        s.kind = v;
    }
    fn setLook(s: *State, v: Look) void {
        s.look = v;
    }
    fn setProjection(s: *State, v: facet.MapProjection) void {
        s.projection = v;
    }
    fn zoomIn(s: *State) void {
        s.camera.zoom = @min(s.camera.zoom + 1, max_zoom);
    }
    fn zoomOut(s: *State) void {
        s.camera.zoom = @max(s.camera.zoom - 1, 0);
    }
    fn goWorld(s: *State) void {
        s.camera = world_view;
    }
    fn goNullIsland(s: *State) void {
        s.camera = .{ .center = .{}, .zoom = 4.5 };
    }
};

const max_zoom = 18;

pub fn build(cx: *facet.Context, s: *State) facet.Widget {
    const t = cx.theme();
    const kinds = [_]facet.Select(Kind).Option{
        .{ .value = .vector, .label = "Vector" },
        .{ .value = .images, .label = "Images" },
    };
    const looks = [_]facet.Select(Look).Option{
        .{ .value = .theme, .label = "The theme's" },
        .{ .value = .atlas, .label = "Atlas" },
        .{ .value = .night, .label = "Night" },
        .{ .value = .blueprint, .label = "Blueprint" },
    };
    const projections = [_]facet.Select(facet.MapProjection).Option{
        .{ .value = .globe, .label = "Globe, then flat" },
        .{ .value = .flat, .label = "Flat" },
    };
    const palette = paletteOf(s.look, t);
    const style = cx.arena.create(facet.MapStyle) catch return cx.make(facet.Empty{});
    style.* = styleOf(cx, palette);
    // Images are drawn in the style too (those drawn in another are
    // dropped, and drawn again).
    if (s.kind == .images) s.images.use(palette);
    const source: facet.MapSource = switch (s.kind) {
        .vector => .of(&s.vector, .{ .max_level = max_zoom, .attribution = "Vector tiles made by the showcase" }),
        .images => .of(&s.images, .{ .max_level = max_zoom, .attribution = "Images drawn by the showcase" }),
    };
    const c = s.camera.center;
    const where = cx.fmt("{d:.4}°{s} {d:.4}°{s} · zoom {d:.1}", .{
        @abs(c.lat),   if (c.lat >= 0) "N" else "S",
        @abs(c.lon),   if (c.lon >= 0) "E" else "W",
        s.camera.zoom,
    });

    return common.page(cx, &.{
        common.section(cx, "A slippy map", "Drag it, and zoom with the wheel or a double click; zoomed out, it is a globe", &.{
            cx.make(facet.SizedBox{ .height = 400, .child = cx.make(facet.Overlay{ .children = &.{
                cx.make(facet.Decorated{
                    .border = .{ .width = 1, .color = t.outline_variant },
                    .child = cx.make(facet.Padding{ .padding = .all(1), .child = cx.make(facet.MapView{
                        .source = source,
                        .style = style,
                        .camera = &s.camera,
                        .projection = s.projection,
                        .max_zoom = max_zoom,
                    }) }),
                }),
                cx.make(facet.Align{ .alignment = .top_right, .child = cx.make(facet.Padding{ .padding = .all(10), .child = cx.make(facet.Decorated{
                    .color = t.surface.withAlpha(0.9),
                    .radius = .all(20),
                    .child = cx.make(facet.Column{ .main_axis_size = .min, .children = &.{
                        cx.make(facet.IconButton{ .icon = .add, .on_press = .of(s, State.zoomIn) }),
                        cx.make(facet.IconButton{ .icon = .remove, .on_press = .of(s, State.zoomOut) }),
                    } }),
                }) }) }),
            } }) }),
            common.status(cx, where),
        }),
        common.section(cx, "Tiles", "Made here: vector tiles drawn in a style, or images drawn from them in the same style", &.{
            common.labelled(cx, "Tiles", &.{
                cx.make(facet.Select(Kind){ .options = &kinds, .value = s.kind, .on_changed = .of(s, State.setKind), .width = 180 }),
            }),
            common.labelled(cx, "Style", &.{
                cx.make(facet.Select(Look){ .options = &looks, .value = s.look, .on_changed = .of(s, State.setLook), .width = 180 }),
            }),
            common.labelled(cx, "Projection", &.{
                cx.make(facet.Select(facet.MapProjection){ .options = &projections, .value = s.projection, .on_changed = .of(s, State.setProjection), .width = 180 }),
            }),
            common.labelled(cx, "Go to", &.{
                cx.make(facet.TextButton{ .label = "The world", .icon = .public, .on_press = .of(s, State.goWorld) }),
                cx.make(facet.TextButton{ .label = "0°, 0°", .icon = .my_location, .on_press = .of(s, State.goNullIsland) }),
            }),
        }),
    });
}

// --- Styles ------------------------------------------------------------------

const Palette = struct {
    background: Color,
    tropics: Color,
    polar: Color,
    line: Color,
    major: Color,
    circle: Color,
    text: Color,
    halo: Color,
};

const atlas_palette: Palette = .{
    .background = .rgb(0xdfe9f1),
    .tropics = .rgb(0xf3e3bf),
    .polar = .rgb(0xf6fafd),
    .line = .rgb(0x8aa0b4),
    .major = .rgb(0xc0392b),
    .circle = .rgb(0xd38b2a),
    .text = .rgb(0x2e3d4d),
    .halo = .rgb(0xffffff),
};

fn paletteOf(look: Look, t: *const facet.Theme) Palette {
    return switch (look) {
        .theme => .{
            .background = t.surface_container,
            .tropics = t.secondary_container,
            .polar = t.surface_container_highest,
            .line = t.outline,
            .major = t.primary,
            .circle = t.primary.withAlpha(0.6),
            .text = t.on_surface,
            .halo = t.surface_container,
        },
        .atlas => atlas_palette,
        .night => .{
            .background = .rgb(0x14202c),
            .tropics = .rgb(0x2f2a1e),
            .polar = .rgb(0x1d2a37),
            .line = .rgb(0x4a6680),
            .major = .rgb(0xff7a5c),
            .circle = .rgb(0xe0a040),
            .text = .rgb(0xd4e0ec),
            .halo = .rgb(0x14202c),
        },
        .blueprint => .{
            .background = .rgb(0x1d4f91),
            .tropics = .rgb(0x23599f),
            .polar = .rgb(0x2a63aa),
            .line = Color.rgb(0xffffff).withAlpha(0.45),
            .major = .rgb(0xffffff),
            .circle = .rgb(0xffd166),
            .text = .rgb(0xffffff),
            .halo = .rgb(0x1d4f91),
        },
    };
}

/// The style for the tiles made here (with its layers in the frame's
/// arena, or `gpa` for a lasting one).
fn styleOf(cx: ?*facet.Context, p: Palette) facet.MapStyle {
    const layers = [_]facet.MapStyle.Layer{
        .{ .source_layer = "zones", .filter = kindIs("tropics"), .draw = .{ .fill = p.tropics } },
        .{ .source_layer = "zones", .filter = kindIs("polar"), .draw = .{ .fill = p.polar } },
        .{ .source_layer = "grid", .filter = .{ .not_equals = .{ .key = "major", .value = .{ .boolean = true } } }, .draw = .{ .line = .{ .color = p.line, .width = 1 } } },
        .{ .source_layer = "grid", .filter = .{ .equals = .{ .key = "major", .value = .{ .boolean = true } } }, .draw = .{ .line = .{ .color = p.major, .width = 1.5 } } },
        .{ .source_layer = "circles", .draw = .{ .line = .{ .color = p.circle, .width = 1.5 } } },
        .{ .source_layer = "circles", .draw = .{ .label = .{ .style = .{ .size = 11, .color = p.circle, .halo = p.halo, .anchor = .bottom, .offset = .{ 0, -2 } } } } },
        .{ .source_layer = "labels", .filter = kindIs("parallel"), .draw = .{ .label = .{ .style = .{ .size = 12, .color = p.text, .halo = p.halo, .anchor = .bottom, .offset = .{ 0, -2 } } } } },
        .{ .source_layer = "labels", .filter = kindIs("meridian"), .draw = .{ .label = .{ .style = .{ .size = 12, .color = p.text, .halo = p.halo, .anchor = .left, .offset = .{ 4, 0 } } } } },
    };
    const copy = if (cx) |c| c.arena.dupe(facet.MapStyle.Layer, &layers) catch &.{} else gpa.dupe(facet.MapStyle.Layer, &layers) catch &.{};
    return .{ .background = p.background, .layers = copy };
}

fn kindIs(comptime kind: []const u8) facet.MapStyle.Filter {
    return .{ .equals = .{ .key = "kind", .value = .{ .string = kind } } };
}

// --- Making tiles --------------------------------------------------------------

const extent = 4096;
const lat_limit = 85.0511287798;

/// How far apart the lines are at a level: the closest of these at
/// least 100 pixels apart (on a tile 256 across).
fn spacing(z: u8) f64 {
    const least = 100.0 / 256.0 * 360 / std.math.exp2(@as(f64, @floatFromInt(z)));
    const steps = [_]f64{ 0.0001, 0.0002, 0.0005, 0.001, 0.002, 0.005, 0.01, 0.02, 0.05, 0.1, 0.2, 0.5, 1, 2, 5, 10, 15, 20, 30, 45 };
    for (steps) |s| if (s >= least) return s;
    return 90;
}

fn mercatorY(lat: f64) f64 {
    const r = std.math.clamp(lat, -lat_limit, lat_limit) * std.math.pi / 180;
    return (1 - @log(@tan(r) + 1 / @cos(r)) / std.math.pi) / 2;
}

fn latOf(y: f64) f64 {
    return std.math.atan(std.math.sinh(std.math.pi * (1 - 2 * y))) * 180 / std.math.pi;
}

/// "40°N", "0.25°W": `v` rounded to what the lines are spaced by.
fn degrees(buf: []u8, v: f64, pos: []const u8, neg: []const u8) []const u8 {
    const r = @round(@abs(v) * 1e6) / 1e6;
    if (r == 0 or r == 180) return std.fmt.bufPrint(buf, "{d}°", .{r}) catch "";
    return std.fmt.bufPrint(buf, "{d}°{s}", .{ r, if (v > 0) pos else neg }) catch "";
}

/// Makes the shapes of tile `id` in `arena`.
fn makeTile(arena: std.mem.Allocator, id: facet.TileId) !VectorTile {
    const n = std.math.exp2(@as(f64, @floatFromInt(id.z)));
    const fx: f64 = @floatFromInt(id.x);
    const fy: f64 = @floatFromInt(id.y);
    const west = fx / n * 360 - 180;
    const east = (fx + 1) / n * 360 - 180;
    const north = latOf(fy / n);
    const south = latOf((fy + 1) / n);
    const s = spacing(id.z);
    const at = struct {
        n: f64,
        fx: f64,
        fy: f64,
        fn p(self: @This(), lat: f64, lon: f64) Point {
            return .{
                @floatCast(((lon + 180) / 360 * self.n - self.fx) * extent),
                @floatCast((mercatorY(lat) * self.n - self.fy) * extent),
            };
        }
    }{ .n = n, .fx = fx, .fy = fy };

    var grid: std.ArrayList(VectorTile.Feature) = .empty;
    var labels: std.ArrayList(VectorTile.Feature) = .empty;
    var circles: std.ArrayList(VectorTile.Feature) = .empty;
    var zones: std.ArrayList(VectorTile.Feature) = .empty;

    // The lines in the tile: at or east of its west edge, and at or north
    // of its south edge, so each is in one tile.
    var meridians: std.ArrayList(f64) = .empty;
    var k = @ceil(west / s - 1e-9);
    while (k * s < east - 1e-9) : (k += 1) try meridians.append(arena, k * s);
    var parallels: std.ArrayList(f64) = .empty;
    k = @ceil(south / s - 1e-9);
    while (k * s < north - 1e-9) : (k += 1) if (@abs(k * s) < lat_limit) try parallels.append(arena, k * s);

    for (meridians.items) |lon| {
        const line = try arena.dupe(Point, &.{ at.p(north, lon), at.p(south, lon) });
        try grid.append(arena, .{
            .geometry = .{ .lines = try arena.dupe([]const Point, &.{line}) },
            .properties = try arena.dupe(VectorTile.Property, &.{.{ .key = "major", .value = .{ .boolean = @abs(lon) < 1e-9 or @abs(@abs(lon) - 180) < 1e-9 } }}),
        });
    }
    for (parallels.items) |lat| {
        const line = try arena.dupe(Point, &.{ at.p(lat, west), at.p(lat, east) });
        try grid.append(arena, .{
            .geometry = .{ .lines = try arena.dupe([]const Point, &.{line}) },
            .properties = try arena.dupe(VectorTile.Property, &.{.{ .key = "major", .value = .{ .boolean = @abs(lat) < 1e-9 } }}),
        });
    }
    // Labels: in each cell, its parallel above the line, half way along,
    // and its meridian beside the line, half way up.
    for (meridians.items) |lon| for (parallels.items) |lat| {
        var buf: [24]u8 = undefined;
        try labels.append(arena, .{
            .geometry = .{ .points = try arena.dupe(Point, &.{at.p(lat, lon + s / 2)}) },
            .properties = try arena.dupe(VectorTile.Property, &.{
                .{ .key = "kind", .value = .{ .string = "parallel" } },
                .{ .key = "name", .value = .{ .string = try arena.dupe(u8, degrees(&buf, lat, "N", "S")) } },
            }),
        });
        if (lat + s / 2 < lat_limit) try labels.append(arena, .{
            .geometry = .{ .points = try arena.dupe(Point, &.{at.p(lat + s / 2, lon)}) },
            .properties = try arena.dupe(VectorTile.Property, &.{
                .{ .key = "kind", .value = .{ .string = "meridian" } },
                .{ .key = "name", .value = .{ .string = try arena.dupe(u8, degrees(&buf, lon, "E", "W")) } },
            }),
        });
    };

    // The tropics and the polar circles, and the zones between them.
    const tilt = 23.4362;
    for ([_]struct { f64, []const u8 }{
        .{ tilt, "Tropic of Cancer" },
        .{ -tilt, "Tropic of Capricorn" },
        .{ 90 - tilt, "Arctic Circle" },
        .{ tilt - 90, "Antarctic Circle" },
    }) |c| if (c[0] >= south and c[0] < north) {
        const line = try arena.dupe(Point, &.{ at.p(c[0], west), at.p(c[0], east) });
        try circles.append(arena, .{
            .geometry = .{ .lines = try arena.dupe([]const Point, &.{line}) },
            .properties = try arena.dupe(VectorTile.Property, &.{.{ .key = "name", .value = .{ .string = c[1] } }}),
        });
        try circles.append(arena, .{
            .geometry = .{ .points = try arena.dupe(Point, &.{at.p(c[0], (west + east) / 2)}) },
            .properties = try arena.dupe(VectorTile.Property, &.{.{ .key = "name", .value = .{ .string = c[1] } }}),
        });
    };
    for ([_]struct { f64, f64, []const u8 }{
        .{ -tilt, tilt, "tropics" },
        .{ 90 - tilt, 90, "polar" },
        .{ -90, tilt - 90, "polar" },
    }) |z| {
        const lo = @max(z[0], south);
        const hi = @min(z[1], north);
        if (hi <= lo) continue;
        const ring = try arena.dupe(Point, &.{ at.p(hi, west), at.p(hi, east), at.p(lo, east), at.p(lo, west) });
        try zones.append(arena, .{
            .geometry = .{ .polygon = try arena.dupe([]const Point, &.{ring}) },
            .properties = try arena.dupe(VectorTile.Property, &.{.{ .key = "kind", .value = .{ .string = z[2] } }}),
        });
    }

    return .{ .extent = extent, .layers = try arena.dupe(VectorTile.Layer, &.{
        .{ .name = "zones", .features = zones.items },
        .{ .name = "grid", .features = grid.items },
        .{ .name = "circles", .features = circles.items },
        .{ .name = "labels", .features = labels.items },
    }) };
}

/// Tiles kept while they are being shown, and a while after.
fn Cache(comptime Entry: type) type {
    return struct {
        entries: std.AutoHashMapUnmanaged(facet.TileId, *Entry) = .empty,

        const Self = @This();
        const keep = 400;
        const unused_ns = 2 * std.time.ns_per_s;

        fn get(c: *Self, id: facet.TileId, now: u64) ?*Entry {
            const e = c.entries.get(id) orelse return null;
            e.used_ns = now;
            return e;
        }

        fn put(c: *Self, id: facet.TileId, e: *Entry, now: u64) void {
            c.trim(now);
            c.entries.put(gpa, id, e) catch e.deinit();
        }

        /// Lets go of tiles not shown for a while, when there are many.
        fn trim(c: *Self, now: u64) void {
            if (c.entries.count() < keep) return;
            var stale: std.ArrayList(facet.TileId) = .empty;
            defer stale.deinit(gpa);
            var it = c.entries.iterator();
            while (it.next()) |kv| if (now -| kv.value_ptr.*.used_ns > unused_ns) stale.append(gpa, kv.key_ptr.*) catch break;
            for (stale.items) |id| if (c.entries.fetchRemove(id)) |kv| kv.value.deinit();
        }

        fn deinit(c: *Self) void {
            var it = c.entries.valueIterator();
            while (it.next()) |e| e.*.deinit();
            c.entries.deinit(gpa);
        }
    };
}

/// The tiles as vector tiles.
const VectorTiles = struct {
    cache: Cache(Shapes) = .{},

    const Shapes = struct {
        arena: std.heap.ArenaAllocator,
        tile: VectorTile,
        used_ns: u64,

        fn deinit(e: *Shapes) void {
            e.arena.deinit();
            gpa.destroy(e);
        }
    };

    pub fn tile(s: *VectorTiles, req: facet.MapSource.Request) facet.MapTile {
        const now = facet.window.nowNs();
        if (s.cache.get(req.id, now)) |e| return .{ .vector = &e.tile };
        const e = gpa.create(Shapes) catch return .none;
        e.* = .{ .arena = .init(gpa), .tile = undefined, .used_ns = now };
        e.tile = makeTile(e.arena.allocator(), req.id) catch {
            e.deinit();
            return .none;
        };
        s.cache.put(req.id, e, now);
        return .{ .vector = &e.tile };
    }

    fn deinit(s: *VectorTiles) void {
        s.cache.deinit();
    }
};

/// The tiles as images: the vector tiles drawn in a style, by the
/// software renderer, for a few milliseconds a frame (the rest wait).
const ImageTiles = struct {
    cache: Cache(Picture) = .{},
    drawing: ?Drawing = null,
    /// The style they are drawn in (its layers `gpa`'s), and its colours.
    style: ?facet.MapStyle = null,
    palette: ?Palette = null,
    /// When this frame's drawing started, and how long it has taken.
    window_ns: u64 = 0,
    spent_ns: u64 = 0,

    const size = 256;
    const budget_ns = 6 * std.time.ns_per_ms;

    const Picture = struct {
        pixels: []u32,
        image: facet.gfx.Image,
        used_ns: u64,

        fn deinit(e: *Picture) void {
            gpa.free(e.pixels);
            gpa.destroy(e);
        }
    };

    /// What drawing them needs.
    const Drawing = struct {
        font: facet.font.Font,
        atlas: facet.gfx.Atlas,
        canvas: facet.gfx.Canvas,
    };

    /// Draws them in a style of these colours from now on: those drawn
    /// in another go (before the frame's tiles are asked for, so none is
    /// in use).
    fn use(p: *ImageTiles, palette: Palette) void {
        if (p.palette) |old| if (std.meta.eql(old, palette)) return;
        p.cache.deinit();
        p.cache = .{};
        if (p.style) |st| gpa.free(st.layers);
        p.style = styleOf(null, palette);
        p.palette = palette;
    }

    pub fn tile(p: *ImageTiles, req: facet.MapSource.Request) facet.MapTile {
        const now = facet.window.nowNs();
        if (p.cache.get(req.id, now)) |e| return .{ .image = .{ .image = &e.image } };
        if (now -| p.window_ns > 12 * std.time.ns_per_ms) {
            p.window_ns = now;
            p.spent_ns = 0;
        }
        if (p.spent_ns > budget_ns) {
            req.waker.wake();
            return .pending;
        }
        defer p.spent_ns += facet.window.nowNs() -| now;
        const e = p.draw(req.id, now) catch return .none;
        p.cache.put(req.id, e, now);
        return .{ .image = .{ .image = &e.image } };
    }

    fn draw(p: *ImageTiles, id: facet.TileId, now: u64) !*Picture {
        const style = &(p.style orelse return error.NoStyle);
        if (p.drawing == null) {
            p.drawing = .{
                .font = try facet.font.Font.init(facet.font.default_font_data),
                .atlas = try facet.gfx.Atlas.init(gpa),
                .canvas = facet.gfx.Canvas.init(gpa),
            };
        }
        const d = &p.drawing.?;
        var arena: std.heap.ArenaAllocator = .init(gpa);
        defer arena.deinit();
        const vt = try makeTile(arena.allocator(), id);
        d.canvas.begin(size, size);
        style.paintTile(&d.canvas, arena.allocator(), &d.atlas, &d.font, id, &vt, size);
        const e = try gpa.create(Picture);
        errdefer gpa.destroy(e);
        const pixels = try gpa.alloc(u32, size * size);
        errdefer gpa.free(pixels);
        @memset(pixels, 0xff000000);
        try facet.gfx.software.render(&d.canvas, .{ .pixels = pixels, .width = size, .height = size });
        e.* = .{ .pixels = pixels, .image = .init(pixels, size, size), .used_ns = now };
        return e;
    }

    fn deinit(p: *ImageTiles) void {
        p.cache.deinit();
        if (p.drawing) |*d| {
            d.canvas.deinit();
            d.atlas.deinit();
        }
        if (p.style) |st| gpa.free(st.layers);
    }
};

test "tiles have their lines, labels and zones, each in one tile" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    // The world in one tile: lines every 90°, the equator and the prime
    // meridian major, and both polar zones and the tropics.
    const world = try makeTile(arena.allocator(), .{ .z = 0, .x = 0, .y = 0 });
    try std.testing.expectEqual(@as(usize, 4 + 1), world.layer("grid").?.features.len);
    try std.testing.expectEqual(@as(usize, 3), world.layer("zones").?.features.len);
    var buf: [8]u8 = undefined;
    var found = false;
    for (world.layer("labels").?.features) |*f| {
        if (std.mem.eql(u8, f.text("name", &buf).?, "90°W")) found = true;
    }
    try std.testing.expect(found);
    // Side by side, a line on the edge between two tiles is in only one.
    const a = try makeTile(arena.allocator(), .{ .z = 3, .x = 3, .y = 3 });
    const b = try makeTile(arena.allocator(), .{ .z = 3, .x = 4, .y = 3 });
    var on_edge: usize = 0;
    for ([_]VectorTile{ a, b }, [_]f32{ extent, 0 }) |t, x| for (t.layer("grid").?.features) |f| {
        const line = f.geometry.lines[0];
        if (line[0][0] == line[1][0] and @abs(line[0][0] - x) < 0.01) on_edge += 1;
    };
    try std.testing.expectEqual(@as(usize, 1), on_edge);
    try std.testing.expectEqualStrings("0.2°N", degrees(&buf, 0.2000000001, "N", "S"));
}
