//! What a `MapView` shows: tiles, from a `MapSource`. The world on the
//! flat map (Web Mercator) is cut into 2^z by 2^z tiles at level z, the
//! slippy-map scheme: tile (z, x, y) with x from the west and y from the
//! north. A tile is a picture (pixels, or a PNG, JPEG, GIF or WebP file,
//! URL or bytes, loaded in the background as an `Image` is) or shapes (a
//! `MapVectorTile`, drawn in the map's style).
//!
//! Facet has no source of its own: an app gives the view one, which may
//! make tiles, fetch them from a tile server, or read them from files.
//!
//!     const Osm = struct {
//!         buf: [64]u8 = undefined,
//!         fn tile(s: *Osm, req: ui.MapSource.Request) ui.MapTile {
//!             const url = std.fmt.bufPrint(&s.buf, "https://tile.example.org/{d}/{d}/{d}.png", .{ req.id.z, req.id.x, req.id.y }) catch return .none;
//!             return .{ .image = .{ .url = url } };
//!         }
//!     };
//!     cx.make(ui.MapView{ .source = .of(&state.osm, .{ .max_zoom = 19, .attribution = "© Example" }) })

const std = @import("std");
const gfx = @import("gfx");
const image_loader = @import("../image_loader.zig");
const runtime = @import("../runtime.zig");

/// A tile: its level, and where it is across and down at that level.
pub const MapTileId = struct {
    z: u8,
    x: u32,
    y: u32,

    /// The tile at the next level out that this is a quarter of.
    pub fn parent(t: MapTileId) ?MapTileId {
        if (t.z == 0) return null;
        return .{ .z = t.z - 1, .x = t.x / 2, .y = t.y / 2 };
    }

    /// How many tiles there are across (and down) at its level.
    pub fn count(t: MapTileId) u32 {
        return @as(u32, 1) << @intCast(t.z);
    }
};

/// What a source has for a tile.
pub const MapTile = union(enum) {
    /// Nothing: nothing is drawn there (the map's background shows).
    none,
    /// Not yet: a tile further out is drawn there meanwhile. The source
    /// wakes the UI (with the request's `waker`) when it has it.
    pending,
    /// A picture, shown as an `Image` would be: pixels at once, or a file,
    /// URL or bytes loaded in the background (and kept while it shows).
    image: image_loader.Source,
    /// Shapes, drawn in the map's style (they must last while they show).
    vector: *const MapVectorTile,
};

/// Where a map's tiles come from: anything with a `tile` method.
pub const MapSource = struct {
    ctx: *anyopaque,
    tile_fn: *const fn (ctx: *anyopaque, req: Request) MapTile,
    /// The tiles' width (and height) in pixels: at `MapCamera.zoom` z, tiles
    /// of level z − log2(tile_size / 256) are drawn at about their size.
    tile_size: f32 = 256,
    /// The levels it has tiles for: zoomed further out, it is asked for
    /// these (more of them, smaller); further in, the last level's are
    /// drawn bigger.
    min_level: u8 = 0,
    max_level: u8 = 19,
    /// Who made the map, shown in a corner (tile servers often require it).
    attribution: []const u8 = "",

    pub const Request = struct {
        id: MapTileId,
        /// Wakes the UI for a frame (from any thread), when a tile that
        /// was `.pending` is ready.
        waker: runtime.Waker,
    };

    pub const Info = struct {
        tile_size: f32 = 256,
        min_level: u8 = 0,
        max_level: u8 = 19,
        attribution: []const u8 = "",
    };

    /// A source calling `ptr.tile(request)` for each tile it shows (every
    /// frame it shows it, so it should keep what it makes or fetches).
    pub fn of(ptr: anytype, info: Info) MapSource {
        const P = @TypeOf(ptr);
        return .{
            .ctx = @ptrCast(@constCast(ptr)),
            .tile_fn = struct {
                fn call(ctx: *anyopaque, req: Request) MapTile {
                    return @as(P, @ptrCast(@alignCast(ctx))).tile(req);
                }
            }.call,
            .tile_size = info.tile_size,
            .min_level = info.min_level,
            .max_level = @max(info.min_level, info.max_level),
            .attribution = info.attribution,
        };
    }

    pub fn tile(s: MapSource, req: Request) MapTile {
        return s.tile_fn(s.ctx, req);
    }
};

/// A tile's shapes, in layers (as a Mapbox vector tile has them): points,
/// lines and polygons, each with properties for the style to go by.
pub const MapVectorTile = struct {
    /// Coordinates go from 0 to this across the tile and down it (and may
    /// go a little beyond, for shapes that cross its edges).
    extent: f32 = 4096,
    layers: []const Layer,

    pub const Point = [2]f32;

    pub const Layer = struct {
        name: []const u8,
        features: []const Feature,
    };

    pub const Feature = struct {
        geometry: Geometry,
        properties: []const Property = &.{},

        pub fn get(f: *const Feature, key: []const u8) ?Value {
            for (f.properties) |p| if (std.mem.eql(u8, p.key, key)) return p.value;
            return null;
        }

        /// The property's text (a number's, written out, in `buf`).
        pub fn text(f: *const Feature, key: []const u8, buf: []u8) ?[]const u8 {
            return switch (f.get(key) orelse return null) {
                .string => |s| s,
                .number => |n| std.fmt.bufPrint(buf, "{d}", .{n}) catch null,
                .boolean => |b| if (b) "true" else "false",
            };
        }
    };

    pub const Geometry = union(enum) {
        points: []const Point,
        /// Each a line through its points.
        lines: []const []const Point,
        /// Rings, each closed: what is inside an odd number of them is
        /// the polygon (so a ring inside another is a hole).
        polygon: []const []const Point,
    };

    pub const Property = struct { key: []const u8, value: Value };

    pub const Value = union(enum) {
        string: []const u8,
        number: f64,
        boolean: bool,

        pub fn eql(a: Value, b: Value) bool {
            return switch (a) {
                .string => |s| b == .string and std.mem.eql(u8, s, b.string),
                .number => |n| b == .number and n == b.number,
                .boolean => |v| b == .boolean and v == b.boolean,
            };
        }
    };

    pub fn layer(t: *const MapVectorTile, name: []const u8) ?*const Layer {
        for (t.layers) |*l| if (std.mem.eql(u8, l.name, name)) return l;
        return null;
    }
};

test "tiles' parents, and features' properties" {
    const t: MapTileId = .{ .z = 3, .x = 5, .y = 2 };
    try std.testing.expectEqual(MapTileId{ .z = 2, .x = 2, .y = 1 }, t.parent().?);
    try std.testing.expectEqual(@as(u32, 8), t.count());
    try std.testing.expect((MapTileId{ .z = 0, .x = 0, .y = 0 }).parent() == null);
    const f: MapVectorTile.Feature = .{ .geometry = .{ .points = &.{.{ 1, 2 }} }, .properties = &.{
        .{ .key = "name", .value = .{ .string = "Here" } },
        .{ .key = "rank", .value = .{ .number = 3 } },
    } };
    var buf: [16]u8 = undefined;
    try std.testing.expectEqualStrings("Here", f.text("name", &buf).?);
    try std.testing.expectEqualStrings("3", f.text("rank", &buf).?);
    try std.testing.expect(f.get("none") == null);
    try std.testing.expect(f.get("rank").?.eql(.{ .number = 3 }));
}
